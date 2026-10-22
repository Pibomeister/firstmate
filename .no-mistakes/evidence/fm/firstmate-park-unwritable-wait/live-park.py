import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess as sp
import time

ROOT = Path.cwd()
E = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J69ZR1KR6Z67YZ17HJFWEY')
SOCKET = E / 'fm-lab-park.sock'
BASE = ROOT / '.test-park-live'
BASE.mkdir(exist_ok=True)
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and k not in ['TMUX', 'TMUX_PANE', 'HERDR_ENV', 'CMUX_WORKSPACE_ID', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND']}
transcript = []
watchers = []
results = []

def log(s):
    print(s, flush=True)
    transcript.append(s)

def run(args, env=None, check=True):
    p = sp.run([str(a) for a in args], cwd=ROOT, env=env or ENV, text=True, stdout=sp.PIPE, stderr=sp.PIPE, timeout=30)
    log('$ ' + ' '.join(str(a) for a in args))
    log(f'exit={p.returncode}\n{p.stdout}{p.stderr}'.rstrip())
    if check and p.returncode:
        raise AssertionError(f'command failed: {args}')
    return p

def tmux(*args):
    return run(['tmux', '-S', SOCKET, *args])

def iso(seconds):
    return dt.datetime.fromtimestamp(int(time.time()) + seconds, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def case(name, verb=None):
    home = BASE / name
    run(['bash', 'bin/fm-lab-home.sh', 'create', home])
    env = dict(ENV, FM_HOME=str(home), FM_BACKEND='tmux', TMUX=tmux_env,
               FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999',
               FM_HEARTBEAT='999999', FM_PAUSE_RESURFACE_SECS='120',
               FM_SECONDMATE_LIVENESS_SECS='99999999')
    if verb:
        env['FM_CLASSIFY_PAUSED_VERB'] = verb
    (home / 'state/task.meta').write_text('window=fm-lab-park:fm-inert\nkind=ship\nharness=claude\nbackend=tmux\n')
    (home / 'state/task.status').write_text('working: delivered PR; quota exhausted; waiting on review\n')
    run(['bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/task.status"'], env)
    return home, env

def park(env, deadline, reason, extra=()):
    return run(['bash', 'bin/fm-park.sh', 'task', '--until', deadline, '--reason', reason, *extra], env)

def start(home, env, label):
    out = open(E / f'{label}-watch.txt', 'w')
    p = sp.Popen(['bash', 'bin/fm-watch.sh'], cwd=ROOT, env=env, stdout=out, stderr=sp.STDOUT)
    watchers.append((p, out))
    return p

def content(path):
    return path.read_text() if path.exists() else ''

def wait_for(predicate, p, seconds=40):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        if p.poll() is not None:
            raise AssertionError(f'watcher exited early: {p.returncode}')
        time.sleep(.2)
    raise AssertionError('observable condition timed out')

def snapshot(home, label):
    dest = E / label
    dest.mkdir(exist_ok=True)
    for f in (home / 'state').iterdir():
        if f.is_file() and (f.name in ['task.status', 'task.meta', '.watch-triage.log', '.wake-queue'] or f.name.startswith('.paused-')):
            shutil.copyfile(f, dest / f.name)
    log(f'persisted product state -> {dest}')

def stop(p):
    if p.poll() is None:
        p.terminate()
        p.wait(timeout=20)

try:
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'fm-lab-park', '-n', 'fm-inert', '-x', '120', '-y', '30', '-c', ROOT,
         "printf 'Delivered PR; quota exhausted; awaiting external review.\\n'; exec sleep 600")
    tmux('set-window-option', '-t', 'fm-lab-park:fm-inert', 'automatic-rename', 'off')
    tmux_env = tmux('display-message', '-p', '-t', 'fm-lab-park:fm-inert', '#{socket_path},#{pid},0').stdout.strip()
    tmux('capture-pane', '-p', '-t', 'fm-lab-park:fm-inert')

    # Control: the real watcher reports this same unparked inert endpoint stale.
    home, env = case('control')
    p = start(home, env, 'control')
    p.wait(timeout=45)
    snapshot(home, 'control-state')
    assert 'stale: fm-lab-park:fm-inert' in (E / 'control-watch.txt').read_text()
    results.append({'scenario': 'unparked inert pane control', 'result': 'pass'})
    log('PASS control: inert pane produces a stale wake without parking')

    home, env = case('deadline')
    deadline = iso(28)
    park(env, deadline, 'quota exhausted until 2020-01-01T12:00Z; delivered PR awaiting review')
    log('parked status: ' + (home / 'state/task.status').read_text())
    p = start(home, env, 'deadline')
    triage = home / 'state/.watch-triage.log'
    wait_for(lambda: content(triage).count('declared time not reached') >= 3, p)
    assert not content(home / 'state/.wake-queue').strip()
    assert p.poll() is None
    log('PASS active wait: three real stale checks absorbed, watcher alive, wake queue empty')
    snapshot(home, 'before-deadline-state')
    p.wait(timeout=50)
    assert 'declared clearing time has passed' in (E / 'deadline-watch.txt').read_text()
    log('PASS expiry: watcher emitted ' + (E / 'deadline-watch.txt').read_text().strip())
    snapshot(home, 'expired-state')
    drain = run(['bash', 'bin/fm-wake-drain.sh'], env)
    ack = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', drain.stderr)
    assert ack, 'drain did not provide acknowledgement token'
    run(['bash', 'bin/fm-wake-drain.sh', '--ack-through', ack[1], '--recovery-generation', ack[2]], env)
    p = start(home, env, 'after-ack')
    wait_for(lambda: content(triage).count('declared time reached') >= 3, p)
    assert not content(home / 'state/.wake-queue').strip()
    log('PASS cadence: after consuming the expiry wake, repeated stale checks stay silent')
    snapshot(home, 'after-ack-state')
    stop(p)
    results.append({'scenario': 'park suppresses stale wakes, expiry rechecks once then holds cadence', 'result': 'pass'})

    home, env = case('override', 'holding')
    park(env, iso(120), 'quota exhausted until 2020-01-01T12:00:30Z')
    p = start(home, env, 'override')
    triage = home / 'state/.watch-triage.log'
    wait_for(lambda: content(triage).count('declared time not reached') >= 3, p)
    assert not content(home / 'state/.wake-queue').strip()
    log('PASS configured holding verb: repeated stale checks absorbed')
    # Worker status logs are the public append interface; a new event ends a park.
    with (home / 'state/task.status').open('a') as f:
        f.write('working: quota reset, resuming\n')
    log('worker appended working: quota reset, resuming')
    p.wait(timeout=40)
    assert 'signal:' in (E / 'override-watch.txt').read_text() or 'stale:' in (E / 'override-watch.txt').read_text()
    snapshot(home, 'resumed-state')
    log('PASS resumption: worker event ended the park and supervision surfaced it: ' + (E / 'override-watch.txt').read_text().strip())
    results.append({'scenario': 'configured wait verb absorbs until a worker event resumes supervision', 'result': 'pass'})

except Exception as ex:
    log('FAIL: ' + repr(ex))
    results.append({'scenario': 'live driver', 'result': 'fail', 'reason': repr(ex)})
    raise
finally:
    for p, out in watchers:
        stop(p)
        out.close()
    sp.run(['tmux', '-S', str(SOCKET), 'kill-server'], env=ENV, stdout=sp.PIPE, stderr=sp.PIPE)
    SOCKET.unlink(missing_ok=True)
    for home in BASE.iterdir():
        if home.is_dir():
            snapshot(home, 'final-' + home.name)
    shutil.rmtree(BASE)
    log('teardown: all owned watchers stopped, private tmux server killed, disposable lab homes removed')
    (E / 'live-park-transcript.txt').write_text('\n'.join(transcript) + '\n')
    (E / 'live-park-results.json').write_text(json.dumps(results, indent=2) + '\n')
