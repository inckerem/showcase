#!/usr/bin/env python3
"""Check a rootful deb for iOS 12 package and dynamic-loader compatibility.

Run on macOS: python3 tests/test_deb_compatibility.py /path/to/package.deb
This checks the package, not actual execution on a jailbroken device.
"""
import gzip
import hashlib
import io
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

if len(sys.argv) < 2 or sys.argv[2:] not in ([], ['--require-autopower']):
    raise SystemExit('usage: test_deb_compatibility.py package.deb [--require-autopower]')
require_autopower = '--require-autopower' in sys.argv[2:]

deb = Path(sys.argv[1]).read_bytes()
if deb[:8] != b'!<arch>\n':
    raise SystemExit('invalid deb ar header')
members = {}
pos = 8
while pos + 60 <= len(deb):
    header = deb[pos:pos + 60]
    if header[58:60] != b'`\n':
        raise SystemExit('invalid ar member header')
    name = header[:16].decode('ascii').strip().rstrip('/')
    size = int(header[48:58].decode('ascii').strip())
    pos += 60
    members[name] = deb[pos:pos + size]
    pos += size + size % 2
if members.keys() != {'debian-binary', 'control.tar.gz', 'data.tar.gz'}:
    raise SystemExit(f'unexpected deb members: {list(members)}')
if members['debian-binary'] != b'2.0\n':
    raise SystemExit('unsupported deb version')

archives = {}
for name in ('control.tar.gz', 'data.tar.gz'):
    raw = gzip.decompress(members[name])
    offset = 0
    while offset + 512 <= len(raw):
        header = raw[offset:offset + 512]
        if header == bytes(512):
            break
        kind = header[156:157]
        if kind not in (b'0', b'\0', b'5', b'2'):
            raise SystemExit(f'{name}: unsupported tar header type {kind!r}')
        size = int(header[124:136].strip(b'\0 ') or b'0', 8)
        offset += 512 + ((size + 511) // 512) * 512
    archives[name] = tarfile.open(fileobj=io.BytesIO(raw), mode='r:')

control = archives['control.tar.gz']
data = archives['data.tar.gz']
def extract_member(archive, name):
    for member in archive:
        if member.name.removeprefix('./') == name:
            return archive.extractfile(member).read()
    raise SystemExit(f'missing {name}')

metadata = extract_member(control, 'control').decode()
if 'Architecture: iphoneos-arm\n' not in metadata:
    raise SystemExit('wrong architecture for rootful iOS')
tr = extract_member(data, 'Applications/Showcase.app/tr.lproj/Localizable.strings')
if 'Türkçe'.encode() not in tr and 'Ayarlar'.encode() not in tr:
    raise SystemExit('Turkish localization appears empty')

allowed = ('/System/Library/Frameworks/', '/usr/lib/libobjc.A.dylib',
           '/usr/lib/libSystem.B.dylib', '/usr/lib/libBTstack.dylib')
with tempfile.TemporaryDirectory(prefix='showcase-compat-') as tmp:
    binaries = {
        name: f'Applications/Showcase.app/{name}'
        for name in ('Showcase', 'carplay_bt', 'carplay_services')
    }
    binaries.update({'BTdaemon': 'usr/bin/BTdaemon', 'libBTstack.dylib': 'usr/lib/libBTstack.dylib'})
    for name, member in binaries.items():
        binary = Path(tmp) / name
        binary.write_bytes(extract_member(data, member))
        result = subprocess.run(['lipo', '-verify_arch', 'arm64', str(binary)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f'{name}: missing arm64 slice or invalid Mach-O')
        if name in ('BTdaemon', 'libBTstack.dylib'):
            continue
        commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        libraries = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
        optional_power = '/Library/MobileSubstrate/DynamicLibraries/ShowcasePower.dylib'
        found_power = False
        for line in libraries:
            path = line.strip().split(' (compatibility version')[0]
            if name == 'Showcase' and path == optional_power:
                found_power = True
                load_commands = re.split(r'(?m)^Load command \d+\s*$', commands)
                matching = [command for command in load_commands if f'name {optional_power} ' in command]
                if len(matching) != 1 or not re.search(r'\bcmd LC_LOAD_WEAK_DYLIB\b', matching[0]):
                    raise SystemExit('Showcase: optional power dylib must be a weak dependency')
                if not re.search(r'(?m)^compatibility version 0\.0\.0\s*$', matching[0]):
                    raise SystemExit('Showcase: optional power dylib must accept compatibility version 0.0.0')
                continue
            if not any(path.startswith(prefix) for prefix in allowed):
                raise SystemExit(f'{name}: unexpected dependency {path}')
        expects_power = require_autopower or re.search(r'(?m)^Version: 1\.0~beta5-7\s*$', metadata)
        if name == 'Showcase' and expects_power and not found_power:
            raise SystemExit('Showcase: missing its optional power dependency')
        if 'LC_DYLD_CHAINED_FIXUPS' in commands:
            raise SystemExit(f'{name}: chained fixups can be incompatible with iOS 12')
        if not re.search(r'(?:minos|version) 12\.0\b', commands):
            raise SystemExit(f'{name}: iOS 12 minimum version not found')
        sdk = re.search(r'\bsdk (\d+)\.(\d+)', commands)
        if not sdk or int(sdk.group(1)) > 12:
            raise SystemExit(f'{name}: expected an iOS 12 or older SDK, got {sdk.group(0) if sdk else "unknown"}')
print('PASS: rootful deb, tar headers, arm64 slices, app iOS 12 loader checks, Turkish files')
print('SHA256:', hashlib.sha256(deb).hexdigest())
