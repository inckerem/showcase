"""Run with Python and a PHP CLI: test_remote.py /path/to/php /path/to/api."""
import json
import io
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import tarfile
import time
import urllib.request
import urllib.error

with tempfile.TemporaryDirectory(prefix='showcase-api-test-') as temp:
    root = Path(temp)
    api = root / 'www/repo/api'
    api.mkdir(parents=True)
    storage = root / 'private/showcase/remote'
    storage.mkdir(parents=True)
    logs = storage.parent / 'logs'
    logs.mkdir()
    for name in ('common.php', 'diagnostics.php', 'logs.php', 'ping.php'):
        shutil.copy(Path(sys.argv[2]) / name, api / name)
    # Same endpoint with a tiny install cap, so eviction is testable without 50000 rows.
    ping_source = (api / 'ping.php').read_text()
    assert 'const MAX_INSTALLS = 50000;' in ping_source
    (api / 'ping_small.php').write_text(ping_source.replace('const MAX_INSTALLS = 50000;', 'const MAX_INSTALLS = 3;'))
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    server = subprocess.Popen([sys.argv[1], '-S', f'127.0.0.1:{port}', '-t', str(root / 'www')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f'http://127.0.0.1:{port}/repo/api/diagnostics.php'
    def send(payload=None, method='POST', content_type='application/json', endpoint=url, headers=None):
        body = json.dumps(payload).encode() if isinstance(payload, dict) else payload
        req = urllib.request.Request(endpoint, data=body, method=method, headers={'Content-Type': content_type, **(headers or {})})
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
        # Per-client new-id limit: 5 new installations per client per hour (1 used above).
        def install(n):
            return f'{n:08x}-2222-4222-8222-222222222222'
        for n in range(4):
            assert send(dict(payload, installation=install(n))) == 201
        assert send(dict(payload, installation=install(4))) == 429
        assert not (storage / (install(4) + '-latest.json')).exists()
        # R3-07: a forged CF-Connecting-IP from a non-Cloudflare peer must not open a new bucket.
        for fake in ('203.0.113.9', '2001:db8::1'):
            assert send(dict(payload, installation=install(5)), headers={'CF-Connecting-IP': fake}) == 429
        assert not (storage / (install(5) + '-latest.json')).exists()
        stale_client = storage / '.clients' / 'stale-client'
        stale_client.write_text('1\n')
        os.utime(stale_client, (time.time()-3601, time.time()-3601))
        assert send(dict(payload, installation=install(6))) == 429
        assert not stale_client.exists()
        # R3-17: the client hashing key is private, fixed-size, outside the web root, and stable.
        client_key = storage.parent / 'client-key'
        key_bytes = client_key.read_bytes()
        assert len(key_bytes) == 32
        assert client_key.stat().st_mode & 0o777 == 0o600
        assert not list((root / 'www').rglob('client-key'))
        upload = url.replace('diagnostics.php', 'logs.php')
        assert send(b'x', content_type='application/x-tar', endpoint=upload) == 400
        assert not list(logs.glob('*.tar'))
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w', format=tarfile.USTAR_FORMAT) as tar:
            info = tarfile.TarInfo('smoke.txt')
            info.size = 4
            tar.addfile(info, io.BytesIO(b'test'))
        assert send(archive.getvalue(), content_type='application/x-tar', endpoint=upload) == 201
        stored, = logs.glob('*.tar')
        assert stored.read_bytes() == archive.getvalue()
        assert stored.stat().st_mode & 0o777 == 0o600
        assert client_key.read_bytes() == key_bytes
        ping = url.replace('diagnostics.php', 'ping.php')
        ping_small = url.replace('diagnostics.php', 'ping_small.php')
        database = storage.parent / 'usage.sqlite'
        def ping_id(n):
            return f'{n:08x}-3333-4333-8333-333333333333'
        def stamp(age):
            return time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime(time.time() - age))
        def sql(query, *args):
            with sqlite3.connect(database) as db:
                return db.execute(query, args).fetchall()
        assert send(dict(id=ping_id(0)), content_type='text/plain', endpoint=ping) == 415
        assert send(dict(id='../escape'), endpoint=ping) == 400
        assert send(dict(id=ping_id(0), model='iPad-test'), endpoint=ping) == 204
        # MIN_PING_INTERVAL: a second ping within 10 s is rejected, after it accepted.
        assert send(dict(id=ping_id(0)), endpoint=ping) == 429
        sql('UPDATE installs SET last_seen = ? WHERE id = ?', stamp(11), ping_id(0))
        assert send(dict(id=ping_id(0)), endpoint=ping) == 204
        # MAX_NEW_INSTALLS_PER_CLIENT_HOUR: the 21st new id from one client is rejected.
        for n in range(1, 20):
            assert send(dict(id=ping_id(n)), endpoint=ping) == 204
        assert send(dict(id=ping_id(20)), endpoint=ping) == 429
        assert not sql('SELECT id FROM installs WHERE id = ?', ping_id(20))
        # R3-07 regression for ping: forged Cloudflare headers do not bypass the limit.
        for fake in ('203.0.113.9', '2001:db8::1'):
            assert send(dict(id=ping_id(21)), endpoint=ping, headers={'CF-Connecting-IP': fake}) == 429
        assert not sql('SELECT id FROM installs WHERE id = ?', ping_id(21))
        # Known installations keep pinging while the client's new-id budget is exhausted.
        sql('UPDATE installs SET last_seen = ? WHERE id = ?', stamp(11), ping_id(0))
        assert send(dict(id=ping_id(0)), endpoint=ping) == 204
        # Expired new-id stamps free the budget again.
        sql('UPDATE new_install_sources SET created = ?', stamp(3601))
        assert send(dict(id=ping_id(20)), endpoint=ping) == 204
        # INSTALL_RETENTION_DAYS: rows unseen for more than 180 days are removed.
        sql('INSERT INTO installs (id, first_seen, last_seen) VALUES (?, ?, ?)', ping_id(100), stamp(181*86400), stamp(181*86400))
        sql('INSERT INTO installs (id, first_seen, last_seen) VALUES (?, ?, ?)', ping_id(101), stamp(179*86400), stamp(179*86400))
        sql('UPDATE installs SET last_seen = ? WHERE id = ?', stamp(11), ping_id(0))
        assert send(dict(id=ping_id(0)), endpoint=ping) == 204
        assert not sql('SELECT id FROM installs WHERE id = ?', ping_id(100))
        assert sql('SELECT id FROM installs WHERE id = ?', ping_id(101))
        # MAX_INSTALLS (R5-11): an id is established once seen across at least one
        # day, so fake ids re-pinged every 10 s are not. When full, young ids go first
        # (oldest first_seen, so re-pinging buys nothing), then established ids silent
        # for over 30 days (oldest last_seen); active established ids are never evicted
        # and a store full of them rejects new ids.
        day = 86400
        def fill(*rows):
            sql('DELETE FROM installs')
            sql('DELETE FROM new_install_sources')
            for n, first, last in rows:
                sql('INSERT INTO installs (id, first_seen, last_seen) VALUES (?, ?, ?)', ping_id(n), stamp(first), stamp(last))
        def ids():
            return sorted(row[0] for row in sql('SELECT id FROM installs'))
        fill((200, 3000, 3000), (201, 2*day, 100), (202, 5000, 20))
        assert send(dict(id=ping_id(203)), endpoint=ping_small) == 204
        assert ids() == [ping_id(n) for n in (200, 201, 203)]
        fill((205, 60*day, 31*day), (206, 40*day, 32*day), (207, 2*day, 100))
        assert send(dict(id=ping_id(208)), endpoint=ping_small) == 204
        assert ids() == [ping_id(n) for n in (205, 207, 208)]
        fill((210, 2*day, 100), (211, 2*day, 100), (212, 2*day, 100))
        assert send(dict(id=ping_id(213)), endpoint=ping_small) == 507
        assert ids() == [ping_id(n) for n in (210, 211, 212)]
        # Diagnostics store full (1000 installations): the least recently heard
        # installation is evicted (latest and crash) instead of refusing a new one.
        for old in storage.glob('*.json'):
            old.unlink()
        for n in range(1000):
            entry = storage / f'{n:08x}-4444-4444-8444-444444444444-latest.json'
            entry.write_text('{}')
            os.utime(entry, (time.time() - 1000 + n, time.time() - 1000 + n))
        oldest = storage / '00000000-4444-4444-8444-444444444444'
        Path(str(oldest) + '-crash.json').write_text('{}')
        for stamp_file in (storage / '.clients').iterdir():
            stamp_file.unlink()
        assert send(dict(payload, installation='55555555-5555-4555-8555-555555555555')) == 201
        assert not Path(str(oldest) + '-latest.json').exists() and not Path(str(oldest) + '-crash.json').exists()
        assert (storage / '00000001-4444-4444-8444-444444444444-latest.json').exists()
        assert len(list(storage.glob('*-latest.json'))) == 1000
        # R12-11: the hourly new-id quota is checked before eviction (a limited
        # client evicts nothing) and after the 507 refusal (which spends nothing).
        for n in range(4):
            assert send(dict(payload, installation=f'{n:08x}-6666-4666-8666-666666666666')) == 201
        assert send(dict(payload, installation='77777777-7777-4777-8777-777777777777')) == 429
        assert (storage / '00000005-4444-4444-8444-444444444444-latest.json').exists()
        for stamp_file in (storage / '.clients').iterdir():
            stamp_file.unlink()
        established = {p.name[:-len('-latest.json')]: int(time.time()) - 2*86400 for p in storage.glob('*-latest.json')}
        (storage / '.first-seen').write_text(json.dumps(established))
        for n in range(6):
            assert send(dict(payload, installation=f'{n:08x}-8888-4888-8888-888888888888')) == 507
        assert not (storage / '.clients').exists() or not list((storage / '.clients').iterdir())
        print('PASS: HTTP ingestion, validation, size limit, rate limit, per-client new-id limits, forged CF header, client key, ping interval/retention/eviction, diagnostics full-store eviction, private storage, retention, heartbeat preserves crash')
    finally:
        server.terminate()
        server.wait(timeout=5)
