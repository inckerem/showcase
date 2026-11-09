#!/usr/bin/env python3
"""Validate the beta package without installing it on a device."""
import gzip
import io
import json
import pathlib
import plistlib
import subprocess
import sys
import tarfile
import tempfile

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
assert data[:8] == b'!<arch>\n'
parts, pos = {}, 8
while pos + 60 <= len(data):
    header = data[pos:pos+60]
    assert header[58:60] == b'`\n'
    name, size = header[:16].decode('ascii').strip().rstrip('/'), int(header[48:58])
    pos += 60
    parts[name] = data[pos:pos+size]
    pos += size + size % 2
assert set(parts) == {'debian-binary', 'control.tar.gz', 'data.tar.gz'}
assert parts['debian-binary'] == b'2.0\n'
archives = {}
for name in ('control.tar.gz', 'data.tar.gz'):
    raw = gzip.decompress(parts[name])
    offset = 0
    while offset + 512 <= len(raw) and raw[offset:offset+512] != bytes(512):
        header = raw[offset:offset+512]
        assert header[156:157] in (b'0', b'\0', b'5'), (name, header[156:157])
        size = int(header[124:136].strip(b'\0 ') or b'0', 8)
        offset += 512 + ((size + 511) // 512) * 512
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as tar:
        entries = tar.getmembers()
        assert all(e.uid == e.gid == 0 for e in entries)
        archives[name] = {e.name: (e, tar.extractfile(e).read() if e.isfile() else None) for e in entries}
control, payload = archives['control.tar.gz'], archives['data.tar.gz']
metadata = control['./control'][1]
expected_control = pathlib.Path(__file__).with_name('control').read_bytes()
assert metadata == expected_control
assert all(control['./'+name][0].mode == 0o755 for name in ('postinst', 'prerm', 'postrm'))
prefix = './Library/MobileSubstrate/DynamicLibraries/ShowcasePower'
assert prefix+'.dylib' in payload and prefix+'.plist' in payload
with tempfile.TemporaryDirectory(prefix='showcase-v3-package-') as tmp:
    root = pathlib.Path(tmp)
    filt = root/'filter.plist'; filt.write_bytes(payload[prefix+'.plist'][1])
    converted = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(filt)])
    assert json.loads(converted)['Filter']['Bundles'] == ['com.rostane.showcase']
    daemon = root/'daemon'; daemon.write_bytes(payload['./usr/libexec/showcase-powerd'][1])
    lib = root/'library'; lib.write_bytes(payload[prefix+'.dylib'][1])
    job = plistlib.loads(payload['./Library/LaunchDaemons/tr.net.kcs.showcase.powerd.plist'][1])
    assert job['ProgramArguments'] == ['/usr/libexec/showcase-powerd'] and job['RunAtLoad'] is True
    assert job['KeepAlive'] is True and job['ThrottleInterval'] == 30
    for binary in (daemon, lib):
        subprocess.run(['lipo', '-verify_arch', 'arm64', str(binary)], check=True)
        commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        assert 'minos 12.0' in commands and 'sdk 12.0' in commands and 'LC_CODE_SIGNATURE' in commands
    ent = plistlib.loads(subprocess.check_output(['ldid', '-e', str(daemon)]))
    assert ent['platform-application'] and ent['com.apple.private.security.no-sandbox']
print('PASS: iOS 12 arm64 signed package, legacy tar, app-only filter and daemon job')
