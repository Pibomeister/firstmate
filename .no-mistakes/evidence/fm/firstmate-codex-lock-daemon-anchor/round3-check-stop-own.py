import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path.cwd()
LAB = ROOT / '.live-check/primary'
spec = importlib.util.spec_from_file_location('protocol', ROOT / '.live-check/protocol.py')
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)

def execute(client, thread, command, seconds=45):
    env = {k: None for k in ['NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE',
           'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
           'CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_PID', 'FM_SUPERVISION_MODEL']}
    env.update(FM_HOME=str(LAB), CODEX_THREAD_ID=thread, CODEX_SESSION_ID=thread)
    return client.rpc('command/exec', {'command': ['/bin/bash', '-c', command], 'cwd': str(LAB),
        'env': env, 'sandboxPolicy': {'type': 'dangerFullAccess'}, 'timeoutMs': seconds*1000,
        'outputBytesCap': 16000})

def wait_for(predicate, label):
    end = time.monotonic()+20
    while time.monotonic()<end:
        if predicate(): return
        time.sleep(.2)
    raise AssertionError('timed out: '+label)

client = protocol.Client()
saved = ROOT / '.live-check/stop-threads.json'
if saved.exists():
    for previous in json.loads(saved.read_text()):
        client.rpc('thread/archive', {'threadId': previous})
threads = [client.rpc('thread/start', {'cwd': str(LAB), 'approvalPolicy': 'never',
           'sandbox': 'danger-full-access'})['thread']['id'] for _ in range(2)]
(ROOT / '.live-check/stop-threads.json').write_text(json.dumps(threads))
owner, other = threads
print('REAL_THREADS', json.dumps(threads), flush=True)
result = execute(client, owner, 'bin/fm-lock.sh; bin/fm-harness.sh; cat state/.lock-session')
assert result['exitCode']==0
(LAB / 'state/probe.meta').write_text('kind=ship\n')
hook = json.loads((LAB / '.codex/hooks.json').read_text())['hooks']['Stop'][0]['hooks'][0]['command']

def stop(thread, turn, active=False):
    payload = json.dumps({'session_id': thread, 'turn_id': turn, 'stop_hook_active': active})
    return execute(client, thread, 'printf %s '+shlex.quote(payload)+' | '+hook)

with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
    for phase, checkpoint_thread, expected in [('own', owner, 2)]:
        checkpoint_client = protocol.Client()
        checkpoint = pool.submit(execute, checkpoint_client, checkpoint_thread,
                                'bin/fm-watch-checkpoint.sh --seconds 20', 52)
        wait_for(lambda: (LAB/'state/.watch.lock/pid').exists() and
                 (LAB/'state/.last-watcher-beat').exists(), 'real watcher '+phase)
        def healthy():
            result = execute(client, owner, 'bin/fm-inbox.sh ready')
            assert result['exitCode']==0
            ready = json.loads(result['stdout'])
            return ready['wake_consumer']['state']=='healthy' and ready['can_receive'] is True
        wait_for(healthy, 'public readiness '+phase)
        result = stop(owner, 'live-'+phase)
        print('STOP_RESULT', phase, json.dumps(result), flush=True)
        assert result['exitCode']==expected, result
        if phase=='own':
            assert 'foreground checkpoint is still running' in result['stderr']
            result = stop(owner, 'live-'+phase, True)
            assert result['exitCode']==2, result
        else:
            assert result['stdout']=='' and result['stderr']=='', result
        outcome = checkpoint.result(timeout=52)
        print('CHECKPOINT_RESULT', phase, json.dumps(outcome), flush=True)
        assert outcome['exitCode']==124, outcome
        checkpoint_client.s.close()
        wait_for(lambda: not (LAB/'state/.watch.lock').exists(), 'watcher cleanup')
        (LAB/'state/.last-watcher-beat').unlink(missing_ok=True)
print('PASS real daemon + real own-thread checkpoint + unmodified registered Stop command: own=2, repeated Stop=2; checkpoint quiet timeout=124', flush=True)
