import json
import os
from pathlib import Path
import signal
import subprocess
import time

root = Path.cwd()
scratch = root / '.test-session-lock'
binary = '/home/ryzengrind/.claude/remote/ccd-cli/2.1.321-3fb3e6595884'
hook = str(scratch / 'live-hook.sh')
settings = scratch / 'live-settings.json'
settings.write_text(json.dumps({'hooks': {'SessionStart': [{'hooks': [
    {'type': 'command', 'command': 'bash ' + hook, 'timeout': 100}
]}]}}))
processes = []

def wait_for(path, seconds=35):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Timed out waiting for ' + str(path))
        time.sleep(0.1)

def launch(role, state, executable=binary):
    folder = scratch / role
    folder.mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('CLAUDE', 'ANTHROPIC', 'HERDR', 'FM_'))}
    env.update(HOME=str(scratch / 'home'), CLAUDE_CONFIG_DIR=str(folder / 'config'),
               DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
               LOCK_TEST_ROLE=role, LOCK_TEST_STATE=state)
    command = [executable, '--init-only', '--setting-sources', '',
               '--settings', str(settings)]
    subprocess.run(['bash', '-c',
        '"$@" </dev/null >"$LOCK_TEST_LOG" 2>&1 & echo $! >"$LOCK_TEST_PID"',
        'bash', *command], env={**env, 'LOCK_TEST_LOG':str(folder/'cli.log'),
        'LOCK_TEST_PID':str(folder/'launcher.pid')}, check=True, start_new_session=True)
    pid = int((folder/'launcher.pid').read_text())
    processes.append(pid)
    wait_for(folder/'ready')
    print((folder/'transcript.log').read_text(), flush=True)
    return folder

def assert_exit(folder, expected):
    actual = int((folder/'acquire.rc').read_text())
    assert actual == expected, (folder.name, actual, expected)

def wait_exit(pid):
    deadline = time.monotonic()+20
    while Path(f'/proc/{pid}').exists():
        if time.monotonic()>deadline:
            raise RuntimeError('Process still alive: '+str(pid))
        time.sleep(0.1)

try:
    baseline = launch('baseline', 'baseline-state')
    assert_exit(baseline, 1)
    assert 'cannot locate harness process in ancestry' in (baseline/'transcript.log').read_text()
    assert not (scratch/'baseline-state/.lock').exists()
    owner = launch('owner', 'shared-state')
    assert_exit(owner, 0)
    owner_pid = int((owner/'pid').read_text())
    assert (scratch/'shared-state/.lock').read_text().strip() == str(owner_pid)
    assert (owner/'confirm.rc').read_text().strip() == '0'
    owner_lock = (scratch/'shared-state/.lock').read_bytes()
    owner_id = (scratch/'shared-state/.lock-session').read_bytes()
    competitor = launch('competitor', 'shared-state')
    assert_exit(competitor, 1)
    assert 'another live firstmate session holds the lock' in (competitor/'transcript.log').read_text()
    assert (scratch/'shared-state/.lock').read_bytes() == owner_lock
    assert (scratch/'shared-state/.lock-session').read_bytes() == owner_id
    sibling_binary = scratch/'.claude/remote/srv/test/server'
    sibling_binary.parent.mkdir(parents=True)
    sibling_binary.symlink_to(binary)
    sibling = launch('sibling', 'sibling-state', str(sibling_binary))
    assert_exit(sibling, 1)
    assert 'Desktop process recognized as harness: rc=1' in (sibling/'transcript.log').read_text()
    assert not (scratch/'sibling-state/.lock').exists()
    (owner/'release').touch()
    wait_exit(owner_pid)
    reclaim = launch('reclaim', 'shared-state')
    assert_exit(reclaim, 0)
    assert (scratch/'shared-state/.lock').read_bytes() != owner_lock
    assert (scratch/'shared-state/.lock-session').read_bytes() != owner_id
    assert (scratch/'shared-state/.lock').read_text().strip() == (reclaim/'pid').read_text().strip()
    print('LIVE RESULT: baseline reproduced; acquisition, confirmation, contention, sibling rejection, and dead-owner reclaim passed.', flush=True)
finally:
    (scratch/'owner/release').touch(exist_ok=True) if (scratch/'owner').exists() else None
    for pid in processes:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
