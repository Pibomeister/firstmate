import hashlib
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = pathlib.Path.cwd()
E = pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5QN6B0CPGQ68QX3AK7G69KK')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='muse-credentialed-', dir=ROOT / '.test-temp'))
SOCKET = ROOT / '.muse-test.sock'
AUTH = pathlib.Path('/Users/eduardopicazo/.config/muse/auth.json')
auth_before = hashlib.sha256(AUTH.read_bytes()).digest()
env = os.environ.copy()
for k in ['NO_COLOR', 'TMUX', 'TMUX_PANE', 'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'GROK_AGENT', 'CURSOR_AGENT', 'CURSOR_INVOKED_AS', 'GEMINI_CLI', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'NO_MISTAKES_GATE']:
    env.pop(k, None)
env.update(XDG_CONFIG_HOME=str(LAB / 'config'), XDG_DATA_HOME=str(LAB / 'data'), FM_HOME=str(LAB / 'home'), MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL='on', TERM='xterm-256color', COLORTERM='truecolor', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
notes = []

def note(s):
    notes.append(s)
    print(s, flush=True)

def run(args, check=True, cwd=ROOT):
    p = subprocess.run(list(map(str, args)), env=env, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    if check and p.returncode:
        raise RuntimeError(str(args) + '\n' + p.stdout)
    return p

def tm(*args, **kw):
    return run(['tmux', '-f', '/dev/null', '-S', SOCKET, *args], **kw)

def until(fn, predicate, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if predicate(value):
            return value
        time.sleep(.3)
    raise RuntimeError('timeout; last result=' + str(value))

def records(log):
    out = []
    for line in log.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out

def lifecycle(log):
    return [r['payload'] for r in records(log) if r.get('payload_type') == 'runtime.session' and r.get('payload', {}).get('kind') == 'run' and r['payload'].get('event', {}).get('kind') in ['started', 'terminal']]

def batches(log):
    return sum(r.get('payload_type') == 'tool_batch.effect.started' for r in records(log))

def logs():
    return list((LAB / 'data/muse/sessions').glob('*/*/*/*/session.jsonl'))

def state(log):
    return run(['bash', '-c', '. "$1/bin/fm-busy-lib.sh"; fm_busy_muse_run_state "$2"', '_', ROOT, log]).stdout.strip()

try:
    assert not SOCKET.exists(), 'refusing existing socket'
    note('Revision: ' + run(['git', 'rev-parse', 'HEAD']).stdout.strip())
    note('Muse: ' + run(['muse', '--version']).stdout.strip())
    run(['bash', 'bin/fm-lab-home.sh', 'create', LAB / 'home'])
    (LAB / 'config/muse').mkdir(parents=True)
    # This document contains Keychain lookup metadata, not a credential value.
    auth = json.loads(AUTH.read_text())
    assert auth['providers']['meta']['storage'] == 'keychain'
    assert set(auth['providers']['meta']) == {'mechanism', 'storage', 'obtained_via', 'api_base_url', 'subs_active', 'user_full_name', 'user_email'}
    (LAB / 'config/muse/auth.json').write_text(json.dumps(auth))
    note('Using existing Keychain login through isolated non-secret provider metadata; no key exported.')
    for name in ['complete', 'interrupt']:
        (LAB / name).mkdir()
        run(['git', 'init', '-q', LAB / name])
    proof = LAB / 'complete/proof.sh'
    proof.write_text('''#!/bin/bash
set -eu
exec > >(tee tool-proof.txt) 2>&1
ROOT=''' + shlex.quote(str(ROOT)) + '''
printf 'tool shell pid=%s parent=%s\\n' "$$" "$PPID"
harness=$(bash "$ROOT/bin/fm-harness.sh")
printf 'detected harness=%s\\n' "$harness"
[ "$harness" = muse ]
bash "$ROOT/bin/fm-lock.sh"
pid=$(head -1 "$FM_HOME/state/.lock")
printf 'recorded lock pid=%s\\n' "$pid"
ps -o pid=,ppid=,comm= -p "$pid"
bash "$ROOT/bin/fm-lock.sh" status
printf 'LOCK-PROOF-PASS\\n'
''')
    prompt = 'Run bash ' + str(proof) + ' exactly once using a shell tool. Then use separate sequential tool calls to create smoke.txt containing line one, read smoke.txt, append line two, and read it again. Do all steps and reply DONE-LOCK-SMOKE. Work only in this workspace and the scratch FM_HOME; no delegation or other changes.'
    command = ['env', *[k + '=' + env[k] for k in ['XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'FM_HOME', 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM']], 'muse', '--yolo', '--model', 'muse-wonder-1.0', '--reasoning-effort', 'low', prompt]
    tm('new-session', '-d', '-s', 'muse-proof', '-n', 'complete', '-x', '120', '-y', '40', '-c', LAB / 'complete', *command)
    log = until(logs, bool)[0]
    note('Completion log: ' + str(log))
    until(lambda: lifecycle(log), lambda v: any(p['event']['kind'] == 'terminal' for p in v))
    life = lifecycle(log)
    terminal = tm('capture-pane', '-p', '-t', 'muse-proof:complete', '-S', '-300').stdout
    (E / 'credentialed-complete-terminal.txt').write_text(terminal)
    (E / 'credentialed-complete-session.jsonl').write_bytes(log.read_bytes())
    note('Completion lifecycle: ' + json.dumps(life))
    note('Completion tool batches: ' + str(batches(log)))
    assert len(life) == 2 and life[-1]['event'].get('terminal') == 'completed'
    assert batches(log) >= 4
    assert (LAB / 'complete/smoke.txt').read_text().splitlines() == ['line one', 'line two']
    proof_text = (LAB / 'complete/tool-proof.txt').read_text()
    note(proof_text)
    (E / 'muse-origin-lock-proof.txt').write_text(proof_text)
    assert 'LOCK-PROOF-PASS' in proof_text
    lock_pid = (LAB / 'home/state/.lock').read_text().splitlines()[0]
    pane_pid = tm('display-message', '-p', '-t', 'muse-proof:complete', '#{pane_pid}').stdout.strip()
    assert lock_pid == pane_pid, (lock_pid, pane_pid)
    note('Lock pid equals live Muse pane process: ' + lock_pid)
    assert state(log) == 'settled'
    decoys = LAB / 'decoys'
    decoys.mkdir()
    for name in ['amuse', 'musescore']:
        executable = decoys / name
        executable.symlink_to('/bin/bash')
        child = subprocess.Popen([str(executable), '-c', 'while :; do sleep 1; done'], env=env)
        try:
            time.sleep(.15)
            (decoys / 'state').mkdir(exist_ok=True)
            (decoys / 'state/.lock').write_text(str(child.pid) + '\n')
            p = run(['env', 'FM_HOME=' + str(decoys), 'bash', ROOT / 'bin/fm-lock.sh', 'status'])
            note(name + ': ' + p.stdout.strip())
            assert 'stale' in p.stdout
        finally:
            child.terminate()
            child.wait()
    prompt2 = 'Use shell tools for a long sequential task. Create part01.txt through part20.txt one at a time. For EACH file run a separate shell tool to write its number, read it back, then sleep 2 seconds. Do not combine all files into one tool call. Finish only after all 20 files. Work only in this workspace; no delegation.'
    command[-1] = prompt2
    tm('new-window', '-d', '-t', 'muse-proof:', '-n', 'interrupt', '-c', LAB / 'interrupt', *command)
    log2 = until(lambda: [p for p in logs() if p != log], bool)[0]
    until(lambda: (batches(log2), len(list((LAB / 'interrupt').glob('part*.txt'))), state(log2)), lambda v: v[0] >= 2 and 1 <= v[1] < 20 and v[2] == 'busy')
    note('Before interrupt: busy; tool batches=' + str(batches(log2)) + '; files=' + str(len(list((LAB / 'interrupt').glob('part*.txt')))))
    (E / 'credentialed-interrupt-before.txt').write_text(tm('capture-pane', '-p', '-t', 'muse-proof:interrupt', '-S', '-300').stdout)
    tm('send-keys', '-t', 'muse-proof:interrupt', 'Escape')
    until(lambda: lifecycle(log2), lambda v: any(p['event']['kind'] == 'terminal' for p in v), 40)
    life2 = lifecycle(log2)
    note('Interrupted lifecycle: ' + json.dumps(life2))
    assert len(life2) == 2 and life2[-1]['event'].get('terminal') == 'cancelled'
    assert life2[0]['run_id'] == life2[-1]['run_id']
    assert state(log2) == 'settled'
    (E / 'credentialed-interrupted-session.jsonl').write_bytes(log2.read_bytes())
    (E / 'credentialed-interrupt-after.txt').write_text(tm('capture-pane', '-p', '-t', 'muse-proof:interrupt', '-S', '-300').stdout)
    assert hashlib.sha256(AUTH.read_bytes()).digest() == auth_before
    note('PASS: real Muse-origin lock acquisition, lookalike rejection, authenticated multi-step completion and mid-loop cancellation.')
finally:
    tm('kill-server', check=False)
    if SOCKET.exists():
        SOCKET.unlink()
    shutil.rmtree(LAB)
    note('Private tmux stopped and scratch data removed.')
    (E / 'credentialed-muse-transcript.txt').write_text('\n\n'.join(notes) + '\n')
