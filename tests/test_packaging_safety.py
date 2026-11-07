"""Device-free regression checks for package staging and compatibility."""
import gzip
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


def archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for name, contents in files.items():
            info = tarfile.TarInfo('./' + name)
            info.size = len(contents)
            tar.addfile(info, io.BytesIO(contents))
    return gzip.compress(output.getvalue())


def deb_bytes(data):
    control = archive({'control': b'Package: sample\nArchitecture: iphoneos-arm\n'})
    members = [('debian-binary', b'2.0\n'), ('control.tar.gz', control), ('data.tar.gz', archive(data))]
    out = b'!<arch>\n'
    for name, body in members:
        out += (f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(body):<10}`\n').encode()
        out += body + (b'\n' if len(body) % 2 else b'')
    return out


class PackagingSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.scripts = self.base / 'packaging/scripts'
        self.scripts.mkdir(parents=True)
        for name in ('fetch-installed-app.sh', 'inspect-deb-on-ipad.sh'):
            shutil.copy2(ROOT / 'packaging/scripts' / name, self.scripts / name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        REMOTE_BASE=str(self.base / 'inspect-stage'), MOCK_LOG=str(self.base / 'ssh.log'))
        executable(self.bin / 'sshpass', '#!/bin/sh\nshift 2\nexec "$@"\n')
        executable(self.bin / 'ssh', '''#!/bin/sh
[ "${FAIL_SSH:-0}" = 0 ] || exit 1
for last do :; done
if [ "${MOCK_INSPECT:-0}" = 1 ]; then
  printf '%s\\n' "$last" >> "$MOCK_LOG"
  exec /bin/sh -c "$last"
fi
exit 0
''')
        executable(self.bin / 'dpkg-deb', '''#!/bin/sh
printf 'dpkg %s %s\\n' "$1" "$2" >> "$MOCK_LOG"
[ -f "$2" ] && [ "${FAIL_INSPECT:-0}" = 0 ]
''')
        executable(self.bin / 'scp', '''#!/bin/sh
for arg do previous="$last"; last="$arg"; done
case "$last" in
  *:*)
    target="${last#*:}"
    if [ "${FAIL_SCP:-0}" != 0 ]; then touch "$target"; exit 1; fi
    cp "$previous" "$target"
    exit $? ;;
esac
if [ "${FAIL_SCP:-0}" != 0 ]; then exit 1; fi
mkdir -p "$last"
for f in Showcase carplay_bt carplay_services; do
  [ "${MISSING_BINARY:-}" = "$f" ] || { touch "$last/$f"; chmod +x "$last/$f"; }
done
''')

    def run_script(self, name, *args, env=None):
        return subprocess.run(['bash', str(self.scripts / name), *map(str, args)],
                              env=env or self.env, capture_output=True, text=True)

    def test_fetch_failure_preserves_previous_payload(self):
        app = self.base / 'packaging/payload/Applications/Showcase.app'
        app.mkdir(parents=True)
        (app / 'marker').write_text('old')
        for variable in ('FAIL_SSH', 'FAIL_SCP'):
            with self.subTest(variable=variable):
                result = self.run_script('fetch-installed-app.sh', env=dict(self.env, **{variable: '1'}))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((app / 'marker').read_text(), 'old')
        result = self.run_script('fetch-installed-app.sh', env=dict(self.env, MISSING_BINARY='carplay_bt'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((app / 'marker').read_text(), 'old')

    def test_fetch_success_keeps_backup(self):
        app = self.base / 'packaging/payload/Applications/Showcase.app'
        app.mkdir(parents=True)
        (app / 'marker').write_text('old')
        result = self.run_script('fetch-installed-app.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((app / 'carplay_bt').is_file())
        backups = list(app.parent.glob('.showcase-fetch.*/previous.app/marker'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'old')

    def test_fetch_restores_previous_payload_if_final_move_fails(self):
        app = self.base / 'packaging/payload/Applications/Showcase.app'
        app.mkdir(parents=True)
        (app / 'marker').write_text('old')
        executable(self.bin / 'mv', '''#!/bin/sh
case "$1" in */.showcase-fetch.*/Showcase.app) exit 1;; esac
exec /bin/mv "$@"
''')
        result = self.run_script('fetch-installed-app.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((app / 'marker').read_text(), 'old')

    def test_inspect_requires_explicit_package_when_ambiguous(self):
        build = self.base / 'packaging/build'
        build.mkdir()
        older = build / 'pkg_1.0~beta5-9_iphoneos-arm.deb'
        newer = build / 'pkg_1.0~beta5-10_iphoneos-arm.deb'
        older.touch()
        newer.touch()
        result = self.run_script('inspect-deb-on-ipad.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('specify the package path', result.stderr)
        env = dict(self.env, MOCK_INSPECT='1')
        self.assertEqual(self.run_script('inspect-deb-on-ipad.sh', newer, env=env).returncode, 0)
        older.unlink()
        self.assertEqual(self.run_script('inspect-deb-on-ipad.sh', env=env).returncode, 0)
        newer.unlink()
        self.assertNotEqual(self.run_script('inspect-deb-on-ipad.sh').returncode, 0)

    def test_inspect_uses_unique_staging_and_preserves_existing_paths(self):
        package = self.base / 'sample.deb'
        package.write_bytes(b'package')
        existing = Path(self.env['REMOTE_BASE'])
        existing.mkdir()
        marker = existing / 'do-not-delete'
        marker.write_text('safe')
        env = dict(self.env, MOCK_INSPECT='1')
        for failure in (None, 'FAIL_SCP', 'FAIL_INSPECT'):
            with self.subTest(failure=failure):
                run_env = dict(env)
                if failure:
                    run_env[failure] = '1'
                result = self.run_script('inspect-deb-on-ipad.sh', package, env=run_env)
                self.assertEqual(result.returncode == 0, failure is None, result.stderr)
                self.assertEqual(marker.read_text(), 'safe')
                self.assertEqual(list(self.base.glob('inspect-stage.??????')), [])
        log = (self.base / 'ssh.log').read_text()
        self.assertNotIn('rm -rf', log)
        self.assertEqual(log.count('mktemp -d'), 3)
        self.assertEqual(log.count('rmdir '), 3)
        staged = [line.split(' ', 2)[-1] for line in log.splitlines() if line.startswith('dpkg -I ')]
        self.assertEqual(len(staged), 2)
        self.assertNotEqual(staged[0], staged[1])

    def test_inspect_rejects_unsafe_prefix_before_ssh(self):
        package = self.base / 'sample.deb'
        package.touch()
        for prefix in ('/', '/tmp/../etc', '/tmp/name;touch /tmp/bad', 'relative'):
            with self.subTest(prefix=prefix):
                result = self.run_script('inspect-deb-on-ipad.sh', package,
                                         env=dict(self.env, MOCK_INSPECT='1', REMOTE_BASE=prefix))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('REMOTE_BASE', result.stderr)
        self.assertFalse((self.base / 'ssh.log').exists())

    def test_all_five_binary_slices_checked(self):
        executable(self.bin / 'lipo', '''#!/bin/sh
case "$(basename "$3")" in "$BAD_BINARY") exit 1;; esac
exit 0
''')
        executable(self.bin / 'otool', '''#!/bin/sh
if [ "$1" = -L ]; then printf 'binary:\\n /usr/lib/libSystem.B.dylib (compatibility version 1.0)\\n';
else printf 'version 12.0\\nsdk 12.4\\n'; fi
''')
        data = {f'Applications/Showcase.app/{n}': b'fake Mach-O' for n in ('Showcase', 'carplay_bt', 'carplay_services')}
        data.update({'usr/bin/BTdaemon': b'fake Mach-O', 'usr/lib/libBTstack.dylib': b'fake Mach-O',
                     'Applications/Showcase.app/tr.lproj/Localizable.strings': 'Ayarlar'.encode()})
        path = self.base / 'sample.deb'
        path.write_bytes(deb_bytes(data))
        def check(env):
            return subprocess.run(['python3', str(ROOT / 'tests/test_deb_compatibility.py'), str(path)],
                                  env=env, capture_output=True, text=True)
        result = check(self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('Showcase', 'carplay_bt', 'carplay_services', 'BTdaemon', 'libBTstack.dylib'):
            with self.subTest(binary=name):
                result = check(dict(self.env, BAD_BINARY=name))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'{name}: missing arm64', result.stderr)
        for member in ('usr/bin/BTdaemon', 'usr/lib/libBTstack.dylib'):
            with self.subTest(missing=member):
                incomplete = dict(data)
                del incomplete[member]
                path.write_bytes(deb_bytes(incomplete))
                result = check(self.env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'missing {member}', result.stderr)


if __name__ == '__main__':
    unittest.main()
