#!/usr/bin/env python3
"""Exercise maintainer-script outcomes with a fake launchctl, never touching iOS or host paths."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='showcase-v3-maintainer-') as tmp:
    root = Path(tmp)
    bindir, data = root/'bin', root/'data'
    bindir.mkdir()
    (bindir/'chown').write_text('#!/bin/sh\nexit 0\n')
    (bindir/'sleep').write_text('#!/bin/sh\nexit 0\n')
    launch = bindir/'launchctl'
    launch.write_text('''#!/bin/sh
case "$1" in
  load) [ "${TEST_MODE:-}" = loadfail ] && exit 1; : > "$TEST_STATE"; exit 0;;
  unload) [ "${TEST_MODE:-}" = unloadfail ] && exit 1; rm -f "$TEST_STATE"; exit 0;;
  list) if [ "$#" -eq 1 ]; then
          [ "${TEST_MODE:-}" = managerfail ] && exit 1
          echo 'PID Status Label'
          [ -f "$TEST_STATE" ] && echo '123 0 tr.net.kcs.showcase.powerd'
          exit 0
        fi
        [ "${TEST_MODE:-}" = specificfail ] && exit 1
        [ -f "$TEST_STATE" ] || exit 1; [ "${TEST_MODE:-}" = nopid ] && { echo '{}'; exit 0; }; echo '{ "PID" = 123; }'; exit 0;;
esac
exit 1
''')
    fake_daemon = bindir/'showcase-powerd'
    fake_daemon.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_NOTIFICATIONS"\n')
    for file in bindir.iterdir(): file.chmod(0o755)
    env = {**os.environ, 'PATH':str(bindir)+':'+os.environ['PATH'],
           'TEST_STATE':str(root/'loaded'), 'TEST_NOTIFICATIONS':str(root/'notifications')}
    def run(name, arg, mode=''):
        text = (source/name).read_text().replace('/var/lib/showcase-power', str(data))
        text = text.replace('/bin/launchctl', str(launch)).replace('/usr/libexec/showcase-powerd', str(fake_daemon))
        script = root/name
        script.write_text(text)
        return subprocess.run(['sh',str(script),arg], env={**env,'TEST_MODE':mode}, capture_output=True, text=True)
    result = run('postinst','configure')
    assert result.returncode == 0, result.stderr
    assert (data/'enabled').exists() and (data/'lock').exists() and (root/'loaded').exists()
    inode = (data/'lock').stat().st_ino
    result = run('postinst','configure')
    assert result.returncode == 0 and (data/'lock').stat().st_ino == inode
    assert (root/'notifications').read_text().splitlines().count('--reset') == 1
    result = run('prerm','remove','managerfail')
    assert result.returncode != 0 and (data/'enabled').exists()
    (data/'enabled').unlink()
    result = run('prerm','remove','managerfail')
    assert result.returncode != 0 and not (data/'enabled').exists()
    (data/'enabled').touch()
    result = run('prerm','remove','unloadfail')
    assert result.returncode != 0 and (data/'enabled').exists()
    assert '--disable' in (root/'notifications').read_text()
    result = run('prerm','remove')
    assert result.returncode == 0 and not (root/'loaded').exists()
    assert run('postinst','configure').returncode == 0
    result = run('prerm','remove','specificfail')
    assert result.returncode == 0 and not (root/'loaded').exists()
    result = run('postinst','configure','loadfail')
    assert result.returncode != 0 and not (data/'enabled').exists()
    result = run('postinst','configure','nopid')
    assert result.returncode != 0 and not (data/'enabled').exists() and not (root/'loaded').exists()
print('PASS: service install, reload, failure, removal and marker handling')
