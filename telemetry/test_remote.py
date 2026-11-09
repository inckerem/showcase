"""Run with Python and a PHP CLI: test_remote.py /path/to/php /path/to/api."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

with tempfile.TemporaryDirectory(prefix='showcase-api-test-') as temp:
    root = Path(temp)
    api = root / 'www/repo/api'
    api.mkdir(parents=True)
    storage = root / 'private/showcase/remote'
    storage.mkdir(parents=True)
    for name in ('common.php', 'diagnostics.php'):
        shutil.copy(Path(sys.argv[2]) / name, api / name)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    server = subprocess.Popen([sys.argv[1], '-S', f'127.0.0.1:{port}', '-t', str(root / 'www')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f'http://127.0.0.1:{port}/repo/api/diagnostics.php'
    def send(payload=None, method='POST', content_type='application/json'):
        body = json.dumps(payload).encode() if isinstance(payload, dict) else payload
        req = urllib.request.Request(url, data=body, method=method, headers={'Content-Type': content_type})
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code
    try:
        for _ in range(40):
            try:
                if send(method='GET') == 405:
                    break
            except OSError:
                time.sleep(.05)
        else:
            raise AssertionError('test PHP server unavailable')
        payload = dict(schema=1, installation='11111111-1111-4111-8111-111111111111', model='iPad-test', os='12.5.8', version='test', freeMB=1000, reports=[dict(process='Showcase', time=12345, excerpt='Exception Type: EXC_CRASH')])
        assert send(payload, content_type='text/plain') == 415
        assert send(b'x' * 262145) == 413
        assert send(dict(payload, installation='../../escape')) == 400
        assert send(dict(payload, reports=[dict(process='WhatsApp', time=1, excerpt='secret')])) == 400
        assert send(dict(payload, unexpected='must not persist')) == 201
        latest = storage / (payload['installation'] + '-latest.json')
        crash = storage / (payload['installation'] + '-crash.json')
        assert 'unexpected' not in json.loads(latest.read_text())
        assert latest.stat().st_mode & 0o777 == 0o600
        assert send(payload) == 429
        os.utime(latest, (time.time()-181, time.time()-181))
        assert send(dict(payload, reports=[])) == 201
        assert json.loads(crash.read_text())['reports']
        assert not json.loads(latest.read_text())['reports']
        stale = storage / 'stale.json'
        stale.write_text('{}')
        os.utime(stale, (time.time()-15*86400, time.time()-15*86400))
        os.utime(latest, (time.time()-181, time.time()-181))
        assert send(payload) == 201
        assert not stale.exists()
        print('PASS: HTTP ingestion, validation, size limit, rate limit, private storage, retention, heartbeat preserves crash')
    finally:
        server.terminate()
        server.wait(timeout=5)
