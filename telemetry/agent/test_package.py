import io
import plistlib
from pathlib import Path
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'packaging/scripts'))
from importlib import import_module
members = import_module('generate-apt-repo').read_ar_members(sys.argv[1])
for name in ('control.tar.gz', 'data.tar.gz'):
    with tarfile.open(fileobj=io.BytesIO(members[name])) as archive:
        for item in archive:
            assert not item.pax_headers
            assert item.type not in (tarfile.XHDTYPE, tarfile.XGLTYPE)
            if item.name.endswith('diagnostics.plist'):
                job = plistlib.loads(archive.extractfile(item).read())
                assert job['UserName'] == 'mobile'
                assert job['StartInterval'] >= 180
                assert not job.get('KeepAlive')
            assert 'MobileSubstrate' not in item.name
print('PASS: USTAR archives, non-root scheduled worker, no SpringBoard injection')
