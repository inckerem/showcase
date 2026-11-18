#!/usr/bin/env python3
"""Republish Showcase Arac Modu against a new Showcase version.

The Arac Modu package pins the exact Showcase versions it accepts:

    Depends: ..., com.rostane.showcase (= 1.0~beta5-15) | ... (= 1.0~beta5-15+mirror) | ...

so every Showcase release needs a matching Arac Modu release, otherwise Cydia
sees an unsatisfiable dependency and offers to remove Arac Modu instead of
upgrading Showcase. Only the control file changes — the dylib, the launch
plist, and the whole data.tar.gz are carried over byte for byte, which keeps
the published runtime identical to the one already on devices.

Usage:
  bump-autopower-dependency.py IN.deb OUT.deb \
      --version 0.1~beta4-8 --showcase 1.0~beta5-16 \
      [--source-control autopower-v3/control]
"""
import argparse
import gzip
import hashlib
import io
import pathlib
import sys
import tarfile

DEPENDS_MARKER = b'Depends: '
MAINTAINER_SCRIPTS = ('postinst', 'prerm', 'postrm')
REPO_AUTOPOWER_DIR = pathlib.Path(__file__).resolve().parents[2] / 'autopower-v3'


def ar_members(raw: bytes) -> dict:
    if raw[:8] != b'!<arch>\n':
        raise SystemExit('not an ar archive')
    members, pos = {}, 8
    while pos + 60 <= len(raw):
        header = raw[pos:pos + 60]
        if header[58:60] != b'`\n':
            raise SystemExit('invalid ar member header')
        name = header[:16].decode('ascii').strip().rstrip('/')
        size = int(header[48:58].decode('ascii').strip())
        pos += 60
        members[name] = raw[pos:pos + size]
        pos += size + size % 2
    return members


def ar_member(name: str, body: bytes) -> bytes:
    header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(body):<10}`\n'.encode('ascii')
    assert len(header) == 60
    return header + body + (b'\n' if len(body) % 2 else b'')


def control_scripts(blob: bytes) -> dict:
    """Return {name: bytes} for the maintainer scripts in a control.tar.gz."""
    scripts = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as tar:
        for member in tar.getmembers():
            name = member.name
            while name.startswith('./'):
                name = name[2:]
            if name in MAINTAINER_SCRIPTS and member.isfile():
                scripts[name] = tar.extractfile(member).read()
    return scripts


def verify_maintainer_scripts(control_blob: bytes, repo_dir: pathlib.Path) -> None:
    """Refuse to republish a deb whose maintainer scripts differ from the repo.

    This tool carries control.tar.gz over except for ./control, so a deb built
    before the scripts in autopower-v3/ changed would ship stale scripts under
    a new version. Those releases must be rebuilt with build.sh instead.
    """
    in_deb = control_scripts(control_blob)
    problems = []
    for name in MAINTAINER_SCRIPTS:
        repo_path = repo_dir / name
        repo_bytes = repo_path.read_bytes() if repo_path.is_file() else None
        deb_bytes = in_deb.get(name)
        if repo_bytes is None and deb_bytes is None:
            continue
        if repo_bytes is None:
            problems.append(f'{name}: in the input deb but missing from {repo_path}')
        elif deb_bytes is None:
            problems.append(f'{name}: in {repo_path} but missing from the input deb')
        elif repo_bytes != deb_bytes:
            problems.append(f'{name}: input deb differs from {repo_path}')
    if problems:
        for problem in problems:
            print(f'error: maintainer script mismatch: {problem}', file=sys.stderr)
        print('error: the input deb carries stale maintainer scripts; rebuild the '
              'package with autopower-v3/build.sh instead of bumping it', file=sys.stderr)
        sys.exit(1)


def rewrite_control(blob: bytes, expected: bytes, replacement: bytes, source_path: pathlib.Path) -> bytes:
    """Return a new control.tar.gz with only ./control replaced.

    The input deb's ./control must equal the unpatched source control, and the
    replacement is the patched source control itself, so the published deb and
    autopower-v3/control can never diverge (e.g. an older deb silently dropping
    Showcase versions the repo control still accepts).
    """
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as old:
        items = [(m, old.extractfile(m).read() if m.isfile() else None) for m in old.getmembers()]
    out = io.BytesIO()
    seen = False
    with tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as new:
        for member, content in items:
            if member.name.lstrip('./') == 'control':
                if content != expected:
                    print(f'error: the input deb\'s ./control differs from {source_path}',
                          file=sys.stderr)
                    print('error: bump from the deb built from the current source control, '
                          'or rebuild the package with autopower-v3/build.sh', file=sys.stderr)
                    sys.exit(1)
                content = replacement
                seen = True
            member.size = len(content) if content is not None else 0
            new.addfile(member, io.BytesIO(content) if content is not None else None)
    if not seen:
        raise SystemExit('control.tar.gz has no ./control member')
    return gzip.compress(out.getvalue(), compresslevel=9, mtime=0)


def extend_depends(value: str, showcase_versions: list) -> str:
    """Add the new Showcase versions to the alternative group that pins it.

    Depends is a comma-separated list of groups, each a `|`-alternation. The
    Showcase pin lives in its own group; extending the line instead of that
    group would fold `firmware (>= 12.0)` into the same alternation and let the
    package install with no Showcase at all.
    """
    groups = [g.strip() for g in value.split(',')]
    for index, group in enumerate(groups):
        if 'com.rostane.showcase' not in group:
            continue
        alternatives = [a.strip() for a in group.split('|')]
        added = [f'com.rostane.showcase (= {v})' for v in showcase_versions]
        stale = [a for a in added if a in alternatives]
        if stale:
            raise SystemExit(f'Depends already lists {stale}')
        groups[index] = ' | '.join(added + alternatives)
        return ', '.join(groups)
    raise SystemExit('Depends does not pin com.rostane.showcase')


def patch_control(control: bytes, version: str, showcase_versions: list) -> bytes:
    lines = control.decode('utf-8').splitlines()
    seen_version = seen_depends = False
    for index, line in enumerate(lines):
        if line.startswith('Version: '):
            lines[index] = f'Version: {version}'
            seen_version = True
        elif line.startswith('Depends: '):
            lines[index] = 'Depends: ' + extend_depends(line[len('Depends: '):], showcase_versions)
            seen_depends = True
    if not seen_version or not seen_depends:
        raise SystemExit('control is missing Version or Depends')
    return ('\n'.join(lines) + '\n').encode('utf-8')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--version', required=True, help='new Arac Modu version')
    parser.add_argument('--showcase', required=True, action='append',
                        help='Showcase version to accept; repeat for the +mirror variant')
    parser.add_argument('--source-control', type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[2] / 'autopower-v3' / 'control',
                        help='source control file to keep in sync (default: autopower-v3/control)')
    args = parser.parse_args()

    members = ar_members(args.source.read_bytes())
    if set(members) != {'debian-binary', 'control.tar.gz', 'data.tar.gz'}:
        raise SystemExit(f'unexpected deb members: {sorted(members)}')
    verify_maintainer_scripts(members['control.tar.gz'], REPO_AUTOPOWER_DIR)
    # Patch the source control in memory first so a stale or already-bumped
    # source fails before anything is written, then ship exactly that control.
    original_control = args.source_control.read_bytes()
    source_control = patch_control(original_control, args.version, args.showcase)
    control = rewrite_control(members['control.tar.gz'], original_control, source_control,
                              args.source_control)
    deb = (b'!<arch>\n' + ar_member('debian-binary', members['debian-binary'])
           + ar_member('control.tar.gz', control) + ar_member('data.tar.gz', members['data.tar.gz']))
    args.output.write_bytes(deb)
    print(f'{args.output}')
    print(f'SHA256: {hashlib.sha256(deb).hexdigest()}')
    print(f'data.tar.gz unchanged: {ar_members(deb)["data.tar.gz"] == members["data.tar.gz"]}')
    args.source_control.write_bytes(source_control)
    print(f'Updated source control: {args.source_control}')


if __name__ == '__main__':
    main()
