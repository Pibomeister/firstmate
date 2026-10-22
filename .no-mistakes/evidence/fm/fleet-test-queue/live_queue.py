import os
from pathlib import Path
import shlex
import signal
import subprocess
import time

root = Path.cwd()
case = root / '.queue-validation-tmp/manual'
case.mkdir()
evidence = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
log = (evidence / 'queue-live-cli.txt').open('w')
env = dict(os.environ, FM_TEST_QUEUE_DIR=str(case / 'spool'), FM_TEST_QUEUE_POLL='0.1')
env.pop('FM_TEST_QUEUE_HELD', None)
env.pop('FM_TEST_SEAM', None)
env.pop('FM_TEST_QUEUE_LOAD_FILE', None)
(case / 'spool').mkdir()
queue = ['/bin/bash', str(root / 'bin/fm-test-queue.sh')]
processes = []

def write(value):
    print(value, file=log, flush=True)

def run(args, extra=None, input=None):
    p = subprocess.run(queue + args, env=dict(env, **(extra or {})), input=input, text=True, capture_output=True)
    write('$ ' + shlex.join(['bin/fm-test-queue.sh'] + args))
    write(p.stdout + p.stderr + f'[exit {p.returncode}]')
    return p

def status(extra=None):
    return run(['status'], extra).stdout

def until(predicate):
    deadline = time.monotonic() + 20
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError('timed out waiting for product state')
        time.sleep(.1)

def start(label, program, extra=None):
    err = (case / f'{label}.stderr').open('w')
    args = ['run', '--label', label, '--', '/bin/bash', '-c', program, '_', str(case)]
    write('$ ' + shlex.join(['bin/fm-test-queue.sh'] + args) + ' &')
    p = subprocess.Popen(queue + args, env=dict(env, **(extra or {})), stdout=subprocess.DEVNULL, stderr=err)
    err.close()
    processes.append(p)
    return p

def finish(p, label, rc=0):
    assert p.wait(timeout=20) == rc
    write(f'{label}: exit {rc}\n' + (case / f'{label}.stderr').read_text())

try:
    write('Revision: 7326bef65be8ed34a2d0165d6dbc78336a73b119; macOS /bin/bash 3.2.57')
    write('SCENARIO: FIFO and load guard, private spool with deterministic load input')
    (case / 'spool/config').write_text('slots=1\n')
    (case / 'load').write_text('20.5\n')
    loadenv = dict(FM_TEST_SEAM='1', FM_TEST_QUEUE_LOAD_FILE=str(case / 'load'))
    for label in ('A', 'B', 'C'):
        start(label, 'echo "$0" >/dev/null; echo START-' + label + ' >> "$1/order"; while [ ! -e "$1/release-' + label + '" ]; do sleep .05; done; echo END-' + label + ' >> "$1/order"', loadenv)
        until(lambda: f'label={label}' in subprocess.check_output(queue + ['status'], env=dict(env, **loadenv), text=True))
    s = status(loadenv)
    assert 'serving=0 waiting=3 stale=0' in s
    assert not (case / 'order').exists()
    (case / 'load').write_text('15.9\n')
    for p, label in zip(processes[:], ('A', 'B', 'C')):
        until(lambda: (case / 'order').exists() and f'START-{label}' in (case / 'order').read_text())
        s = status(loadenv)
        assert f'label={label}' in s and 'serving=1' in s
        (case / f'release-{label}').touch()
        finish(p, label)
    order = (case / 'order').read_text()
    write('Workload output:\n' + order)
    assert order == 'START-A\nEND-A\nSTART-B\nEND-B\nSTART-C\nEND-C\n'
    assert 'serving=0 waiting=0 stale=0' in status(loadenv)

    write('SCENARIO: two shared slots, real OS load probe, independent caller homes')
    (case / 'spool/config').write_text('slots=2\nload_ceiling=100000\n')
    ps = []
    for label in ('one', 'two', 'three'):
        home = case / f'home-{label}'
        home.mkdir()
        p = start(label, ': > "$1/started-' + label + '"; while [ ! -e "$1/release-' + label + '" ]; do sleep .05; done', dict(FM_HOME=str(home)))
        ps.append(p)
        until(lambda: f'label={label}' in subprocess.check_output(queue + ['status'], env=env, text=True))
    until(lambda: (case / 'started-one').exists() and (case / 'started-two').exists())
    assert 'serving=2 waiting=1 stale=0' in status()
    assert not (case / 'started-three').exists()
    (case / 'release-one').touch()
    finish(ps[0], 'one')
    until(lambda: (case / 'started-three').exists())
    assert 'serving=2 waiting=0 stale=0' in status()
    for p, label in zip(ps[1:], ('two', 'three')):
        (case / f'release-{label}').touch()
        finish(p, label)
    assert 'serving=0 waiting=0 stale=0' in status()

    write('SCENARIO: cross-timezone ownership survives wrapper SIGKILL until child exits')
    (case / 'spool/config').write_text('slots=1\nload_ceiling=100000\n')
    holder = start('UTC-owner', 'echo $$ > "$1/child-pid"; echo "$TZ" > "$1/child-tz"; while [ ! -e "$1/release-survivor" ]; do sleep .05; done', dict(TZ='UTC'))
    until(lambda: (case / 'child-pid').exists())
    follower = start('Mexico-follower', 'echo "$TZ" > "$1/follower-tz"', dict(TZ='America/Mexico_City'))
    until(lambda: 'waiting=1' in subprocess.check_output(queue + ['status'], env=env, text=True))
    assert 'serving=1 waiting=1 stale=0' in status(dict(TZ='America/Mexico_City'))
    holder.kill()
    finish(holder, 'UTC-owner', -signal.SIGKILL)
    assert 'serving=1 waiting=1 stale=0' in status(dict(TZ='America/Mexico_City'))
    time.sleep(.4)
    assert not (case / 'follower-tz').exists()
    write('Follower output absent while orphaned workload is alive.')
    (case / 'release-survivor').touch()
    finish(follower, 'Mexico-follower')
    write('Caller environments: ' + (case / 'child-tz').read_text().strip() + ', ' + (case / 'follower-tz').read_text().strip())
    assert (case / 'child-tz').read_text().strip() == 'UTC'
    assert (case / 'follower-tz').read_text().strip() == 'America/Mexico_City'
    assert 'serving=0 waiting=0 stale=0' in status()

    write('SCENARIO: stdin/stdout/stderr and exit contracts; invalid config prevents execution')
    p = run(['run', '--', '/bin/bash', '-c', 'read line; echo "OUT:$line"; echo ERR:preserved >&2; exit 23'], input='from-stdin\n')
    assert p.returncode == 23 and p.stdout == 'OUT:from-stdin\n' and p.stderr == 'ERR:preserved\n'
    for sig, code in (('INT', 130), ('TERM', 143)):
        assert run(['run', '--', '/bin/sh', '-c', f'kill -{sig} $$']).returncode == code
    assert run(['run', '--']).returncode == 2
    (case / 'spool/config').write_text('slots=0\n')
    assert run(['run', '--', 'touch', str(case / 'must-not-run')]).returncode == 125
    assert not (case / 'must-not-run').exists()
    (case / 'spool/config').write_text('slots=1\nload_ceiling=100000\n')
    write('SCENARIO: nested wrapper runs within occupied single slot')
    nested = run(['run', '--', '/bin/bash', str(root / 'bin/fm-test-queue.sh'), 'run', '--', 'printf', 'nested workload completed\n'])
    assert nested.returncode == 0 and nested.stdout == 'nested workload completed\n'
    assert 'serving=0 waiting=0 stale=0' in status()
    write('All manual CLI scenarios passed.')
finally:
    for path in ('A', 'B', 'C', 'one', 'two', 'three', 'survivor'):
        (case / f'release-{path}').touch()
    for p in processes:
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=20)
    log.close()
