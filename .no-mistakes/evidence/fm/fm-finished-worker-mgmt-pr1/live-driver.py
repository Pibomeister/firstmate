import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY')
LABS = ROOT / '.test-phase/live-homes'
LABS.mkdir(exist_ok=True)
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_')) and k not in
       ('TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION', 'REX_SESSION',
        'REX_BLOCK', 'ORCA_TERMINAL_HANDLE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'BASH_ENV')}
ENV.update(FM_TEST_SEAM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           TMPDIR=str(ROOT / '.test-phase/tmp'))
USER_HOME = ROOT / '.test-phase/isolated-user'
USER_HOME.mkdir(exist_ok=True)
ENV.update(HOME=str(USER_HOME), XDG_CONFIG_HOME=str(USER_HOME / 'config'),
           XDG_CACHE_HOME=str(USER_HOME / 'cache'), XDG_DATA_HOME=str(USER_HOME / 'data'),
           CLAUDE_CONFIG_DIR=str(USER_HOME / 'claude'))
resume = '--resume' in sys.argv
results = json.loads((EVIDENCE / 'live-results.json').read_text()) if resume else []
log = (EVIDENCE / 'live-product-transcript.log').open('a' if resume else 'w', buffering=1)


def note(message):
    text = f'{time.strftime("%H:%M:%S")} {message}'
    print(text, flush=True)
    log.write(text + '\n')


def run(args, env=None, timeout=180, check=True):
    e = ENV.copy()
    e.update(env or {})
    p = subprocess.run([str(x) for x in args], env=e, text=True, capture_output=True, timeout=timeout)
    if check and p.returncode:
        raise AssertionError(f'{args}: exit={p.returncode} stdout={p.stdout[-1500:]} stderr={p.stderr[-1500:]}')
    return p


def home(name):
    h = LABS / name
    run(['bin/fm-lab-home.sh', 'create', h])
    (h / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return h


def envhome(h, **kw):
    return dict(FM_HOME=str(h), FM_LOAD_FILE=str(h / 'load'), **{k: str(v) for k, v in kw.items()})


def load(h, value):
    (h / 'load').write_text(f'{value} 0.00 0.00\n')


def waitfor(predicate, timeout=120, description='condition'):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError(f'timed out waiting for {description}')


def ledger(h, name='heartbeat.json'):
    try:
        return json.loads((h / 'state' / name).read_text())
    except (OSError, ValueError):
        return None


def save(h, label, name='heartbeat.json'):
    data = ledger(h, name)
    (EVIDENCE / f'{label}.json').write_text(json.dumps(data, indent=2) + '\n')
    note(f'{label}: ' + json.dumps({k: data.get(k) for k in ('schema', 'generated_epoch', 'published_epoch', 'throttled', 'stale_after_secs', 'failure')}))
    return data


def scenario(name, fn):
    results[:] = [item for item in results if item['name'] != name]
    note('START ' + name)
    try:
        fn()
        results.append(dict(name=name, result='pass', live=True, evidence='live-product-transcript.log', reason='Real local CLI; disposable synthetic lab homes.'))
        note('PASS ' + name)
    except Exception as exc:
        results.append(dict(name=name, result='fail', live=True, evidence='live-product-transcript.log', reason=str(exc)))
        note('FAIL ' + name + ': ' + str(exc))
    (EVIDENCE / 'live-results.json').write_text(json.dumps(results, indent=2) + '\n')


def thresholds():
    h = home('thresholds')
    for value, expected in [('200.00', '15'), ('200.01', '60'), ('300', '60'), ('199', '15'), ('bad', '15')]:
        load(h, value)
        p = run(['bash', '-c', '. bin/fm-load-lib.sh; fm_load_interval 15'], envhome(h))
        note(f'load={value}, base=15s, actual interval={p.stdout.strip()}s; expected={expected}s (intent: above 200 -> four times)')
        assert p.stdout.strip() == expected
    (h / 'load').unlink()
    p = run(['bash', '-c', '. bin/fm-load-lib.sh; fm_load_interval 15'], envhome(h))
    assert p.stdout.strip() == '15'
    note('Missing load input preserves 15s interval.')


def snapshots():
    h = home('snapshot-lock')
    e = ENV | envhome(h)
    firstout = (EVIDENCE / 'snapshot-first.json').open('w')
    firsterr = (EVIDENCE / 'snapshot-first.stderr').open('w')
    first = subprocess.Popen(['bin/fm-fleet-snapshot.sh', '--json'], env=e, stdout=firstout, stderr=firsterr, start_new_session=True)
    try:
        lock = h / 'state/.fleet-snapshot.lock'
        waitfor(lambda: (lock / 'pid').exists(), description='real snapshot lock')
        os.kill(first.pid, signal.SIGSTOP)
        note(f'Stopped actual snapshot pid={first.pid} while its per-home lock was held.')
        for mode in ['--json', '--secondmate-home-summary']:
            p = run(['bin/fm-fleet-snapshot.sh', mode], envhome(h, FM_SNAPSHOT_SINGLE_FLIGHT_WAIT=1), check=False)
            note(f'Concurrent {mode}: exit={p.returncode}, stdout bytes={len(p.stdout)}, stderr={p.stderr.strip()}')
            assert p.returncode == 75 and not p.stdout and str(first.pid) in p.stderr
        p = run(['bin/fm-fleet-snapshot.sh', '--contribution-input'], envhome(h))
        assert p.stdout.strip()
        (EVIDENCE / 'snapshot-contribution-input.txt').write_text(p.stdout)
        note('Contribution-input succeeds while full snapshot is stopped.')
        waiter = subprocess.Popen(['bin/fm-fleet-snapshot.sh', '--json'], env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        time.sleep(2)
        assert waiter.poll() is None, 'second real snapshot did not wait'
        os.kill(first.pid, signal.SIGCONT)
        assert first.wait(timeout=180) == 0
        out, err = waiter.communicate(timeout=180)
        assert waiter.returncode == 0 and json.loads(out)['schema'] == 'fm-fleet-snapshot.v1', err
        assert not lock.exists(), 'normal completion left snapshot lock'
        note('Resumed holder and waiting real snapshot both exited 0; lock absent after normal completion.')
        killed = subprocess.Popen(['bin/fm-fleet-snapshot.sh', '--json'], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        waitfor(lambda: (lock / 'pid').exists(), description='second real snapshot lock')
        killed.kill()
        killed.wait()
        p = run(['bin/fm-fleet-snapshot.sh', '--json'], envhome(h))
        assert json.loads(p.stdout)['schema'] == 'fm-fleet-snapshot.v1' and not lock.exists()
        note('SIGKILLed holder: next actual snapshot reclaimed stale lock, emitted valid JSON, and removed the lock.')
    finally:
        for child in [first, locals().get('waiter'), locals().get('killed')]:
            if child and child.poll() is None:
                os.killpg(child.pid, signal.SIGCONT)
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        firstout.close()
        firsterr.close()


def stateless():
    h = home('stateless')
    shutil.rmtree(h / 'state')
    for mode, schema in [('--json', 'fm-fleet-snapshot.v1'), ('--secondmate-home-summary', 'fm-secondmate-home-summary.v1')]:
        p = run(['bin/fm-fleet-snapshot.sh', mode], envhome(h))
        data = json.loads(p.stdout)
        assert data['schema'] == schema and not (h / 'state').exists()
        (EVIDENCE / ('stateless-' + mode[2:] + '.json')).write_text(p.stdout)
        note(f'{mode}: exit=0, schema={schema}, state directory remains absent.')


def heartbeat():
    h = home('heartbeat')
    e = envhome(h, FM_HEARTBEAT_CYCLE_SECS=100)
    load(h, '200')
    run(['bin/fm-heartbeat.sh', '--write'], e)
    calm = save(h, 'heartbeat-at-threshold')
    assert calm['throttled'] is False and calm['snapshot']['ok'] is True
    load(h, '300')
    run(['bin/fm-heartbeat.sh', '--write'], e)
    hot = save(h, 'heartbeat-first-hot')
    assert hot['throttled'] is True and hot['stale_after_secs'] == calm['stale_after_secs'] + 300
    before = (h / 'state/heartbeat.json').read_bytes()
    run(['bin/fm-heartbeat.sh', '--write'], e)
    assert (h / 'state/heartbeat.json').read_bytes() == before
    note('Immediate second hot heartbeat exits 0 and preserves prior ledger byte-for-byte (no collection).')
    # A one-second scheduling jitter below the 400s loaded cycle must still publish.
    data = ledger(h)
    data['generated_epoch'] = int(time.time()) - 399
    (h / 'state/heartbeat.json').write_text(json.dumps(data))
    run(['bin/fm-heartbeat.sh', '--write'], e)
    due = save(h, 'heartbeat-due-with-jitter')
    assert due['generated_epoch'] > data['generated_epoch'] and due['snapshot']['ok'] is True
    load(h, '10')
    run(['bin/fm-heartbeat.sh', '--write'], e)
    recovered = save(h, 'heartbeat-calm-recovery')
    assert recovered['throttled'] is False and recovered['stale_after_secs'] == calm['stale_after_secs']
    run(['bin/fm-heartbeat.sh', '--write'], e | {'FM_HEARTBEAT_LOAD_FACTOR': '4'})
    pinned = save(h, 'heartbeat-pinned-hot-factor-on-calm-load')
    assert pinned['throttled'] is True and pinned['stale_after_secs'] == hot['stale_after_secs']
    load(h, '300')
    run(['bin/fm-heartbeat.sh', '--write'], e | {'FM_HEARTBEAT_LOAD_FACTOR': '1'})
    pinnedcalm = save(h, 'heartbeat-pinned-calm-factor-on-hot-load')
    assert pinnedcalm['throttled'] is False and pinnedcalm['stale_after_secs'] == calm['stale_after_secs']
    note('Both load-crossing directions obey watcher-passed launch factor instead of re-probing.')


class Watcher:
    def __init__(self, h, **overrides):
        self.h = h
        self.events = []
        self.stamp = time.monotonic()
        self.epoch = time.time()
        self.launch_files = {kind: EVIDENCE / f'{h.name}-{kind}-starts.tsv' for kind in ('heartbeat', 'summary')}
        for path in self.launch_files.values():
            path.write_text('')
        hook = h / 'observe-start.sh'
        hook.write_text('''fm_live_observe_start() {
  trap - DEBUG
  local observation_key="$$:$0:${1:-}"
  [ "${FM_LIVE_OBSERVED_KEY:-}" != "$observation_key" ] || return 0
  export FM_LIVE_OBSERVED_KEY="$observation_key"
  case "$0:${1:-}" in
    */fm-heartbeat.sh:--write)
      printf '%s\\t%s\\t%s\\n' "$(date +%s)" "$$" "$0 $*" >> "$FM_LIVE_HEARTBEAT_STARTS" ;;
    */fm-home-summary-refresh.sh:--best-effort)
      printf '%s\\t%s\\t%s\\n' "$(date +%s)" "$$" "$0 $*" >> "$FM_LIVE_SUMMARY_STARTS" ;;
  esac
}
trap 'fm_live_observe_start "$@"' DEBUG
''')
        e = ENV | envhome(h, FM_POLL=1, FM_SIGNAL_GRACE=0, FM_CHECK_INTERVAL=999999,
                          FM_HEARTBEAT=999999, FM_HEARTBEAT_LEDGER_IDLE_SECS=30,
                          FM_HEARTBEAT_LEDGER_JITTER=0, FM_HOME_SUMMARY_INTERVAL=30,
                          FM_HOME_SUMMARY_JITTER=0, FM_WATCH_MANAGED_HOLD=1)
        e.update({k: str(v) for k, v in overrides.items()})
        e.update(BASH_ENV=str(hook), FM_LIVE_HEARTBEAT_STARTS=str(self.launch_files['heartbeat']),
                 FM_LIVE_SUMMARY_STARTS=str(self.launch_files['summary']))
        self.out = (EVIDENCE / f'{h.name}-watch.stdout').open('w')
        self.trace = (EVIDENCE / f'{h.name}-watch-launches.log').open('w', buffering=1)
        self.p = subprocess.Popen(['bash', 'bin/fm-watch.sh'], env=e, stdout=self.out, stderr=subprocess.PIPE, text=True, errors='replace', start_new_session=True)
        self.reader = threading.Thread(target=self.drain)
        self.reader.start()

    def drain(self):
        for line in self.p.stderr:
            relative = round(time.monotonic() - self.stamp, 3)
            self.trace.write(f'{relative:.3f}s STDERR {line}')

    @property
    def launches(self):
        observed = {}
        for kind, path in self.launch_files.items():
            seen = set()
            observed[kind] = []
            for line in path.read_text().splitlines():
                fields = line.split('\t')
                if len(fields) < 2 or not fields[0].isdigit() or fields[1] in seen:
                    continue
                seen.add(fields[1])
                observed[kind].append(round(int(fields[0])-self.epoch, 3))
        return observed

    def stop(self):
        # TERM asks the product to stop its detached ticker and current publication.
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
        # Also reap the exact disposable process group, including held-mode children.
        try:
            os.killpg(self.p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.p.wait()
        self.reader.join(timeout=30)
        assert not self.reader.is_alive(), 'watcher stderr still open after teardown'
        self.trace.close()
        self.out.close()
        note(f'{self.h.name}: watcher stopped (exit={self.p.returncode}); real launches={self.launches}')


def watcher_cadence():
    h = home('watch-cadence')
    load(h, '300')
    w = Watcher(h)
    try:
        waitfor(lambda: ledger(h) and ledger(h, 'home-summary.json'), 180, 'both actual ledgers')
        save(h, 'watch-cadence-first-heartbeat')
        save(h, 'watch-cadence-first-summary', 'home-summary.json')
        waitfor(lambda: len(w.launches['heartbeat']) == 1 and len(w.launches['summary']) == 1)
        beat = (h / 'state/.last-watcher-beat').stat().st_mtime_ns
        # Wake tokens are the product's actual local durable protocol, not a publisher stub.
        run(['bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_append check live-change "synthetic change under load"'], envhome(h))
        (h / 'state/probe.status').write_text('working: synthetic status for summary pacing\n')
        note('Appended real durable wake and synthetic status while loaded; observing unchanged launch counts before 120s deadline.')
        waitfor(lambda: (h / 'state/.last-watcher-beat').stat().st_mtime_ns > beat, 70, 'a completed real poll after the change')
        target = w.stamp + min(w.launches['heartbeat'][0], w.launches['summary'][0]) + 80
        while time.monotonic() < target:
            time.sleep(.2)
        assert len(w.launches['heartbeat']) == 1 and len(w.launches['summary']) == 1, w.launches
        assert (h / 'state/.last-watcher-beat').stat().st_mtime_ns > beat
        note('Before loaded deadline: one launch each; watcher liveness beat advanced despite deferred collection.')
        waitfor(lambda: len(w.launches['heartbeat']) >= 2 and len(w.launches['summary']) >= 2, 180, '120s throttled collections')
        for kind in w.launches:
            gap = w.launches[kind][1] - w.launches[kind][0]
            assert 118 <= gap <= 180, (kind, gap)
            note(f'{kind}: real loaded launch gap={gap:.3f}s, configured base=30s, loaded=120s.')
        waitfor(lambda: ledger(h)['generated_epoch'] > json.loads((EVIDENCE / 'watch-cadence-first-heartbeat.json').read_text())['generated_epoch'], 100, 'second real heartbeat publication')
        save(h, 'watch-cadence-second-heartbeat')
        load(h, '10')
        (h / 'state/probe.status').write_text('working: calm status for summary recovery\n')
        run(['bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_append check calm-change "synthetic calm change"'], envhome(h))
        switched = time.monotonic() - w.stamp
        hb_before = len(w.launches['heartbeat'])
        summary_before = len(w.launches['summary'])
        waitfor(lambda: len(w.launches['heartbeat']) > hb_before and len(w.launches['summary']) > summary_before, 90, 'calm change-driven collections')
        note(f'Calm change at {switched:.3f}s: next heartbeat={w.launches["heartbeat"][-1]:.3f}s; summary={w.launches["summary"][-1]:.3f}s.')
        waitfor(lambda: ledger(h) and ledger(h)['throttled'] is False, 120, 'calm heartbeat bound')
        save(h, 'watch-cadence-calm-heartbeat')
    finally:
        w.stop()


def failed_retry():
    h = home('watch-failed-publication')
    load(h, '300')
    # Persisted ledger is intentionally old, so a failed publish must not pull the
    # next retry back to an already expired deadline.
    original = {'schema': 'fm-heartbeat.v1', 'generated_epoch': int(time.time()) - 200,
                'published_epoch': int(time.time()) - 200, 'throttled': True, 'stale_after_secs': 500}
    (h / 'state/heartbeat.json').write_text(json.dumps(original))
    # Real filesystem permission failure, using this user's actual permissions.
    (h / 'state').chmod(0o555)
    w = None
    try:
        p = run(['bin/fm-heartbeat.sh', '--write'], envhome(h, FM_HEARTBEAT_CYCLE_SECS=3), check=False)
        note(f'Real unwritable-state heartbeat: exit={p.returncode}, stderr={p.stderr.strip()}')
        assert 'cannot create a work directory' in p.stderr and ledger(h) == original
        # The watcher requires writable state for its own lock. Restrict only the
        # publication work path through a filename collision instead below.
    finally:
        (h / 'state').chmod(0o755)
    # Use a real write failure at atomic publication: replacing a file that is
    # in an unwritable state directory after the watcher has acquired its lock.
    w = Watcher(h, FM_HEARTBEAT_LEDGER_IDLE_SECS=3, FM_HOME_SUMMARY_INTERVAL=999999)
    try:
        waitfor(lambda: (h / 'state/.last-watcher-beat').exists(), 90, 'watcher start')
        waitfor(lambda: ledger(h)['generated_epoch'] > original['generated_epoch'], 150, 'initial successful publication')
        stable = ledger(h)
        (h / 'state').chmod(0o555)
        baseline = len(w.launches['heartbeat'])
        waitfor(lambda: len(w.launches['heartbeat']) >= baseline + 3, 140, 'three real failed retry launches')
        times = w.launches['heartbeat'][baseline:]
        gaps = [b-a for a,b in zip(times, times[1:])]
        note(f'Actual unwritable-state retry launch times={times}, gaps={gaps}; expected loaded interval=12s, not per-poll retries.')
        assert all(g >= 10 for g in gaps), gaps
        assert ledger(h) == stable, 'failed publication changed prior ledger'
        save(h, 'failed-publication-preserved-ledger')
    finally:
        (h / 'state').chmod(0o755)
        w.stop()


def open_work_cap():
    h = home('open-work-cap')
    load(h, '300')
    now = int(time.time())
    (h / 'state/dispatch-log.tsv').write_text(f'2026-11-26T16:00:00Z\t{now}\treceived\tlive-open-goal\tsummary=synthetic pending work\n')
    (h / 'state/.heartbeat-streak').write_text('3\n')
    last = h / 'state/.last-heartbeat'
    last.touch()
    os.utime(last, (now-901, now-901))
    p = run(['bin/fm-watch.sh'], envhome(h, FM_WATCH_ONCE=1, FM_WATCH_NOW=now, FM_POLL=1,
                                      FM_CHECK_INTERVAL=999999, FM_HEARTBEAT=600), timeout=180)
    note('Real one-shot loaded watcher stdout=' + p.stdout.strip())
    queue = (h / 'state/.wake-queue').read_text()
    note('Durable wake queue=' + queue.strip())
    (EVIDENCE / 'loaded-open-work-wake.tsv').write_text(queue)
    assert 'heartbeat' in p.stdout.splitlines()
    assert any(row.split('\t')[2:4] == ['heartbeat', 'heartbeat'] for row in queue.splitlines())


try:
    for name, fn in [
        ('Synthetic load crosses 200 and monitoring returns to its ordinary interval', thresholds),
        ('Concurrent real snapshots wait or refuse; contribution reads, normal release, and dead-holder recovery remain available', snapshots),
        ('Both real read-only snapshot modes preserve a stateless synthetic home', stateless),
        ('Real heartbeat extends freshness once, suppresses early collection, tolerates jitter, and restores calm cadence', heartbeat),
        ('Real watcher defers heartbeat and summary collections under load while polling and resumes calm changes', watcher_cadence),
        ('Real publication write failures preserve the prior ledger and retain loaded retry spacing', failed_retry),
        ('Loaded watcher with synthetic open work emits its overdue supervision wake within the existing cap', open_work_cap),
    ]:
        if any(item['name'] == name and item['result'] == 'pass' for item in results):
            continue
        scenario(name, fn)
finally:
    shutil.rmtree(LABS)
    note('Removed all live disposable homes.')
    log.close()
sys.exit(1 if any(x['result'] != 'pass' for x in results) else 0)
