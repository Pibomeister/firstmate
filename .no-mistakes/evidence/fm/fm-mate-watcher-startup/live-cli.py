import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
LAB = pathlib.Path(tempfile.mkdtemp(prefix='.fm-test-live-', dir=ROOT))
base = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TMUX', 'HERDR_', 'REX_', 'ORCA_', 'TASKS_AXI_'))}
for key in ('CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_SESSION_ID', 'CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'PI_CODING_AGENT', 'GROK_AGENT'):
    base.pop(key, None)
base.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', NM_HOME=str(LAB / 'nm'),
            XDG_CONFIG_HOME=str(LAB / 'xdg-config'), XDG_STATE_HOME=str(LAB / 'xdg-state'),
            XDG_CACHE_HOME=str(LAB / 'xdg-cache'), TMPDIR=str(LAB / 'tmp'))
(LAB / 'tmp').mkdir()
(LAB / 'tools').mkdir()
for tool in ('bash', 'tmux', 'timeout', 'jq'):
    resolved = shutil.which(tool)
    if resolved:
        (LAB / 'tools' / tool).symlink_to(resolved)
base['PATH'] = str(LAB / 'tools') + ':/usr/bin:/bin:/usr/sbin:/sbin'
transcript = []
results = []
server_pid = None
tmux_env = None
socket_root = None

def run(args, env=None, timeout=100):
    start = time.monotonic()
    child = subprocess.Popen(args, cwd=ROOT, env=env or base, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            output, _ = child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            output, _ = child.communicate()
        raise RuntimeError(f'command exceeded {timeout}s: {args}: {output[-1000:]}')
    elapsed = time.monotonic() - start
    transcript.append(f'$ {" ".join(map(str, args))}\nexit={child.returncode} elapsed={elapsed:.3f}s\n{output}')
    return child.returncode, output, elapsed

def home(name):
    path = LAB / name
    rc, _, _ = run(['bin/fm-lab-home.sh', 'create', str(path)])
    assert rc == 0
    (path / 'config/backlog-backend').write_text('manual\n')
    (path / 'config/supervision-host-off').touch()
    return path

def probe(h, mode, updates=None):
    env = base | {'FM_HOME': str(h), 'FM_TASK_INBOX': str(LAB / 'parent/state/lab-mate.inbox')}
    if updates:
        env.update(updates)
    return run(['bin/fm-watch.sh', mode], env)

try:
    h = home('secondmate')
    parent = LAB / 'parent'
    (parent / 'state/lab-mate.inbox').mkdir(parents=True)
    (h / '.fm-secondmate-home').write_text('lab-mate\n')
    (h / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
    # A stale binding is deliberately present, but no terminal identity is supplied.
    (h / 'state/.secondmate-watch').write_text('1\nstale-identity\n%999\n/stale/socket\ntmux\n')
    for mode in ('--secondmate-selected', '--secondmate'):
        rc, out, _ = probe(h, mode)
        assert rc == 1 and 'native endpoint registration' in out, out
    assert not (h / 'state/.watch.lock').exists()
    assert not (h / 'state/.last-watcher-beat').exists()
    results.append({'scenario': 'missing registration and stale binding', 'result': 'pass'})

    # A real tmux pane supplies the candidate route, but is not a verified binding.
    socket_root = pathlib.Path(tempfile.mkdtemp(prefix='fml.', dir='/tmp'))
    tmux_env = base | {'TMUX_TMPDIR': str(socket_root)}
    rc, pane, _ = run(['tmux', '-f', '/dev/null', '-L', 'fm-lab', 'new-session', '-d', '-s', 'primary',
                       '-x', '120', '-y', '40', '-c', str(ROOT), '-P', '-F', '#{pane_id}', 'sleep 600'], tmux_env)
    assert rc == 0, pane
    pane = pane.strip()
    rc, identity, _ = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', pane, '#{socket_path},#{pid},0'], tmux_env)
    assert rc == 0
    identity = identity.strip()
    server_pid = int(identity.split(',')[1])
    candidate = {'TMUX': identity, 'TMUX_PANE': pane}
    rc, out, _ = probe(h, '--secondmate-selected', candidate)
    assert rc == 0, out
    rc, out, _ = probe(h, '--secondmate-status', candidate)
    assert rc == 1 and 'not ready' in out, out
    for updates, reason in (({'FM_TASK_INBOX': 'foreign.inbox'}, 'steering inbox'),):
        rc, out, _ = probe(h, '--secondmate-selected', candidate | updates)
        assert rc == 1 and reason in out, out
    (h / 'state/.afk').touch()
    rc, out, _ = probe(h, '--secondmate-selected', candidate)
    assert rc == 1 and 'away' in out, out
    (h / 'state/.afk').unlink()
    (h / 'config/supervision-host-off').unlink()
    (h / 'config/supervision-host').touch()
    rc, out, _ = probe(h, '--secondmate-selected', candidate)
    assert rc == 1 and 'supervision host' in out, out
    (h / 'config/supervision-host-off').touch()
    (h / '.fm-secondmate-parent').rename(h / 'parent.saved')
    rc, out, _ = probe(h, '--secondmate-selected', candidate)
    assert rc == 1 and 'parent' in out, out
    (h / 'parent.saved').rename(h / '.fm-secondmate-parent')
    (h / '.fm-secondmate-home').unlink()
    rc, out, _ = probe(h, '--secondmate-selected', candidate)
    assert rc == 1 and 'secondmate home' in out, out
    assert not (h / 'state/.watch.lock').exists()
    assert not (h / 'state/.last-watcher-beat').exists()
    results.append({'scenario': 'real tmux candidate remains unready and ownership guards refuse', 'result': 'pass'})

    def startup(name, endpoint_budget, total_budget, records, stalled=False):
        case = home(name)
        # A directory at the lock path makes acquisition fail without impersonating a harness.
        (case / 'state/.lock').mkdir()
        queue = b'123\t1\tcheck\tlab\tpreserve this unhandled event\n'
        (case / 'state/.wake-queue').write_bytes(queue)
        (case / 'data/captain.md').write_text('LAB-CONTEXT-SENTINEL\n')
        for i in range(records):
            (case / f'state/probe-{i:02d}.meta').write_text(f'window={pane}\nkind=ship\nbackend=tmux\n')
        (case / 'state/orphan.status').write_text('working: retained orphan\n')
        original = {p.name: p.read_bytes() for p in (case / 'state').iterdir() if p.is_file()}
        env = base | {'FM_HOME': str(case), 'TMUX': identity, 'TMUX_PANE': pane,
                      'FM_SESSION_START_TIMEOUT': str(total_budget),
                      'FM_SESSION_START_ENDPOINT_TIMEOUT': str(endpoint_budget)}
        stopped = threading.Event()
        monitor_done = threading.Event()
        def stall_at_observation():
            while not monitor_done.wait(0.005):
                for marker in (LAB / 'tmp').glob('fm-session-start-stage.*'):
                    try:
                        if marker.read_text().strip() == 'fleet-state':
                            os.kill(server_pid, signal.SIGSTOP)
                            stopped.set()
                            return
                    except FileNotFoundError:
                        pass
        monitor = threading.Thread(target=stall_at_observation) if stalled else None
        if monitor:
            monitor.start()
        try:
            rc, out, elapsed = run(['bin/fm-session-start.sh'], env, timeout=150)
        finally:
            monitor_done.set()
            if monitor:
                monitor.join()
            if stalled:
                os.kill(server_pid, signal.SIGCONT)
        (EVIDENCE / f'{name}.log').write_text(out)
        assert rc == 0 and 'READ-ONLY SESSION' in out, out[-3000:]
        assert 'LAB-CONTEXT-SENTINEL' in out and 'NEXT STEP' in out, out[-3000:]
        assert 'STARTUP TRUNCATED - SESSION START' not in out, out[-3000:]
        for filename, value in original.items():
            assert (case / 'state' / filename).read_bytes() == value, filename
        assert (case / 'state/.lock').is_dir()
        assert not (case / 'state/.session-start-complete').exists()
        assert not (case / 'state/.session-start-agents-baseline').exists()
        if stalled:
            assert stopped.is_set(), 'real tmux server was never stopped at observation'
        if stalled or (records and int(endpoint_budget) > int(total_budget)):
            assert 'FLEET OBSERVATION DEFERRED:' in out, out
            assert 'endpoint observations are unverified' in out, out
            assert 'The digest above is complete' not in out, out
        else:
            assert 'FLEET OBSERVATION DEFERRED:' not in out, out
            if records:
                assert 'endpoint=alive' in out, out
            assert 'orphan state=working' in out, out
        return elapsed

    startup('healthy-decimal-startup', 10, '090', 1)
    startup('empty-fleet-large-window', 120, 90, 0)
    results.append({'scenario': 'live tmux endpoint and no-probe decimal startup retain complete context', 'result': 'pass'})
    startup('unfitting-window', 120, 90, 1)
    startup('stalled-real-tmux', 2, 35, 32, stalled=True)
    results.append({'scenario': 'unfitting and stopped real tmux observations defer while preserving recovery inputs', 'result': 'pass'})
finally:
    if server_pid:
        try:
            os.kill(server_pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
    if tmux_env:
        run(['tmux', '-L', 'fm-lab', 'kill-server'], tmux_env, timeout=10)
    if socket_root:
        shutil.rmtree(socket_root)
    (EVIDENCE / 'live-cli-transcript.log').write_text('\n'.join(transcript))
    (EVIDENCE / 'live-cli-results.json').write_text(json.dumps(results, indent=2))
    shutil.rmtree(LAB)
    print(json.dumps(results, indent=2))
