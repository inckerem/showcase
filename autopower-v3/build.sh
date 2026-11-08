#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-/tmp/showcase-autopower-v3}"
SDK="${SHOWCASE_IOS12_SDK:-$(cat /tmp/showcase-ios12-sdk-path)}"
mkdir -p "$OUT/root/Library/MobileSubstrate/DynamicLibraries" "$OUT/root/Library/LaunchDaemons" "$OUT/root/usr/libexec" "$OUT/root/var/lib/showcase-power"
DYLIB="$OUT/root/Library/MobileSubstrate/DynamicLibraries/ShowcasePower.dylib"
clang -target arm64-apple-ios12.0 -isysroot "$SDK" -fobjc-arc -fblocks -DSHOWCASE_APP_ONLY=1 '-DSHOWCASE_POWER_ENABLED_PATH=@"/var/lib/showcase-power/enabled"' -dynamiclib \
  -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type-mismatch -Werror \
  -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/ShowcasePower.dylib \
  -framework UIKit -framework Foundation -framework CoreFoundation -o "$DYLIB" "$ROOT/autopower/ShowcasePower.m"
ldid -S "$DYLIB"
clang -target arm64-apple-ios12.0 -isysroot "$SDK" -fobjc-arc -fblocks \
  -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type-mismatch -Werror \
  -framework Foundation -framework CoreFoundation -framework IOKit -o "$OUT/root/usr/libexec/showcase-powerd" "$HERE/PowerDaemon.m"
ldid -S"$HERE/entitlements.xml" "$OUT/root/usr/libexec/showcase-powerd"
cp "$HERE/ShowcasePower.plist" "$OUT/root/Library/MobileSubstrate/DynamicLibraries/ShowcasePower.plist"
cp "$HERE/tr.net.kcs.showcase.powerd.plist" "$OUT/root/Library/LaunchDaemons/tr.net.kcs.showcase.powerd.plist"
python3 - "$HERE" "$OUT" <<'PY'
import gzip, io, pathlib, sys, tarfile, time
here, out = map(pathlib.Path, sys.argv[1:])
def archive(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for name, path, mode in entries:
            item = tarfile.TarInfo(name); item.mode = mode; item.mtime = int(time.time())
            item.uid = item.gid = 0; item.uname = item.gname = 'root'
            if path.is_dir(): item.type = tarfile.DIRTYPE; tar.addfile(item)
            else:
                data = path.read_bytes(); item.size = len(data); tar.addfile(item, io.BytesIO(data))
    return gzip.compress(buf.getvalue(), compresslevel=9, mtime=0)
root = out/'root'
control = archive([('./'+n, here/n, mode) for n, mode in [('control',0o644),('postinst',0o755),('prerm',0o755),('postrm',0o755)]])
items = [('var/lib/showcase-power',0o755),('usr/libexec/showcase-powerd',0o755),('Library/LaunchDaemons/tr.net.kcs.showcase.powerd.plist',0o644),('Library/MobileSubstrate/DynamicLibraries/ShowcasePower.dylib',0o755),('Library/MobileSubstrate/DynamicLibraries/ShowcasePower.plist',0o644)]
data = archive([('./'+n,root/n,mode) for n,mode in items])
def member(name, body):
    header=f'{name + "/":<16}{int(time.time()):<12}{0:<6}{0:<6}{"100644":<8}{len(body):<10}`\n'.encode('ascii')
    assert len(header)==60
    return header+body+(b'\n' if len(body)%2 else b'')
fields = dict(line.split(': ', 1) for line in (here/'control').read_text().splitlines()
              if line and not line[0].isspace())
deb = out / f"{fields['Package']}_{fields['Version']}_{fields['Architecture']}.deb"
deb.write_bytes(b'!<arch>\n'+member('debian-binary',b'2.0\n')+member('control.tar.gz',control)+member('data.tar.gz',data))
print(deb)
PY
