import io
import plistlib
from pathlib import Path
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'packaging/scripts'))
from importlib import import_module
members = import_module('generate-apt-repo').read_ar_members(sys.argv[1])
expected = {
    'control.tar.gz': {'control': 0o644, 'postinst': 0o755, 'prerm': 0o755},
    'data.tar.gz': {
        'Library/LaunchDaemons/tr.net.kcs.showcase.diagnostics.plist': 0o644,
        'usr/libexec/showcase-diagnostics': 0o755,
    },
}
for name in ('control.tar.gz', 'data.tar.gz'):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(members[name])) as archive:
        for item in archive:
            assert (item.uid, item.gid) == (0, 0), item.name
            assert not item.pax_headers
            assert item.type not in (tarfile.XHDTYPE, tarfile.XGLTYPE)
            if item.isfile():
                files[item.name.removeprefix('./')] = item.mode
            if item.name.endswith('diagnostics.plist'):
                job = plistlib.loads(archive.extractfile(item).read())
                assert job['UserName'] == 'mobile'
                assert job['StartInterval'] >= 180
                assert not job.get('KeepAlive')
            assert 'MobileSubstrate' not in item.name
    assert files == expected[name], files
print('PASS: root-owned USTAR payload and control files, mobile-user scheduled worker')
