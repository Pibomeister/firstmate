import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import traceback

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M88ESZEM0X1FSQ08VFD3QR76')
WORK = Path(tempfile.mkdtemp(prefix='.postmortem-live-', dir=ROOT))
TODAY = dt.date.today().isoformat()
ROSTER = ['M3', 'Studio', 'Hetzner', 'local']
BASE = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'REX_', 'ORCA_')) and k not in ('TMUX', 'TMUX_PANE')}
RESULTS = []
log = None

def run(home, script, *args, expected=(0,), cwd=None, extra=None):
    env = dict(BASE, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'), FM_PROJECTS_OVERRIDE=str(home/'projects'))
    if extra:
        env.update(extra)
    cmd = [str(ROOT/'bin'/script), *map(str,args)]
    log.write('$ FM_HOME=' + str(home) + ' ' + shlex.join(cmd) + '\n')
    log.flush()
    proc = subprocess.Popen(cmd, cwd=cwd or ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, _ = proc.communicate()
        log.write(out + '\nTIMEOUT (process group stopped)\n')
        log.flush()
        raise AssertionError('CLI timed out: ' + shlex.join(cmd))
    log.write(out + f'EXIT {proc.returncode}\n\n')
    log.flush()
    assert proc.returncode in expected, (script, proc.returncode, out)
    return out

def home(name):
    h = WORK/name
    run(h, 'fm-lab-home.sh', 'create', h)
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (h/'artifacts').mkdir()
    return h

def artifact(h, machine):
    p = h/'artifacts'/f'{machine}.md'
    p.write_text(f'Synthetic pre-existing {machine} postmortem artifact\n')
    return p, hashlib.sha256(p.read_bytes()).hexdigest()

def checklist(h, *args, **kw):
    return run(h, 'fm-postmortem-checklist.sh', *args, **kw)

def receipt(h, machine, path, digest, night=TODAY, **kw):
    return checklist(h, 'receipt', '--machine', machine, '--path', path, '--hash', digest, '--night', night, **kw)

def note(h, machine, p, digest, night=TODAY):
    out = run(h, 'fm-inbox.sh', 'note', '--json', '--', '\t'.join(['postmortem-receipt', night, machine, str(p), digest]))
    data = json.loads(out)
    return data['id']

def s1():
    h = home('automatic-checklist')
    out = checklist(h, 'collect')
    assert [r.split('\t')[0] for r in out.splitlines()] == ROSTER
    assert all(f'{m}\topen\t{TODAY}: no artifact receipt recorded' in out for m in ROSTER)
    ledger = (h/'state/postmortem-checklist.tsv').read_text()
    checklist(h, 'collect')
    assert ledger == (h/'state/postmortem-checklist.tsv').read_text()
    log.write('Saved ledger:\n' + ledger)

def s2():
    h = home('receipt-verification')
    checklist(h, 'start')
    for m in ROSTER:
        p, sha = artifact(h, m)
        out = receipt(h, m, Path('artifacts')/p.name, sha, cwd=h)
        assert f'{m}\tclosed\t' in out
    out = checklist(h, 'check', cwd=ROOT)
    assert len(out.splitlines()) == 4 and all('\tclosed\t' in r for r in out.splitlines())
    p = h/'artifacts/M3.md'
    original = p.read_bytes()
    p.write_text('Changed after receipt\n')
    out = checklist(h, 'check', expected=(1,))
    assert 'M3\topen\tartifact hash mismatch' in out
    p.write_bytes(original)
    (h/'artifacts/local.md').unlink()
    out = checklist(h, 'open')
    assert 'local\topen\tartifact missing at recorded path:' in out
    assert 'M3\topen\t' not in out

def s3():
    h = home('inbox-receipts')
    p, sha = artifact(h, 'M3')
    ident = note(h, 'M3', p, sha)
    assert 'M3\topen\t' not in checklist(h, 'collect')
    run(h, 'fm-inbox.sh', 'drain', '--ack', ident)
    assert (h/'state/inbox/handled'/f'{ident}.note').exists()
    assert 'M3\topen\t' not in checklist(h, 'open')
    # Seed two same-second receipt records in the inbox's persisted public format.
    # They represent conflicting ingress with no provable ordering; the product
    # itself reads, arbitrates, and verifies them.
    epoch = str(int(time.time()) + 2)
    for suffix, digest in [('a', sha), ('z', '0'*64)]:
        (h/'state/inbox'/f'{epoch}-{suffix}.note').write_text(f'id={epoch}-{suffix}\n--\npostmortem-receipt\t{TODAY}\tM3\t{p}\t{digest}\n')
    assert 'M3\topen\tartifact receipt could not be verified' in checklist(h, 'open')
    while int(time.time()) <= int(epoch):
        time.sleep(0.1)
    note(h, 'M3', p, sha)
    assert 'M3\topen\t' not in checklist(h, 'collect')

def s4():
    h = home('retained-mornings')
    old = (dt.date.today() - dt.timedelta(days=2)).isoformat()
    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    for m in ['M3', 'Studio', 'local']:
        p, sha = artifact(h, m)
        receipt(h, m, p, sha, night=old)
    since = int(dt.datetime.combine(dt.date.today()-dt.timedelta(days=2), dt.time(20)).timestamp())
    out = checklist(h, 'collect', '--since', since)
    assert f'Hetzner\topen\t{old}:' in out
    assert all(f'{m}\topen\t{yesterday}:' in out and f'{m}\topen\t{TODAY}:' in out for m in ROSTER)
    out = checklist(h, 'collect', '--since', int(time.time()))
    assert f'Hetzner\topen\t{old}:' in out and f'Hetzner\topen\t{TODAY}:' in out
    p, sha = artifact(h, 'Hetzner')
    receipt(h, 'Hetzner', p, sha, night=old)
    assert old not in checklist(h, 'collect', '--since', int(time.time()))

def s5():
    h = home('calendar-validation')
    p, sha = artifact(h, 'M3')
    for bad in ['2026-11-31', '2026-02-29', '0000-01-01']:
        checklist(h, 'start', '--night', bad, expected=(2,))
        receipt(h, 'M3', p, sha, night=bad, expected=(2,))
    assert not (h/'state/postmortem-checklist.tsv').exists()
    # Serialized legacy state is a fixture, never executable product code.
    (h/'state/postmortem-checklist.tsv').write_text('2026-11-31\t-\topened\t\t\t1\n')
    out = checklist(h, 'collect')
    assert all(f'{m}\topen\t{TODAY}:' in out for m in ROSTER)
    checklist(h, 'start', '--night', '2024-02-29')

def s6():
    h = home('no-hash-tool')
    for m in ROSTER:
        p, sha = artifact(h, m)
        receipt(h, m, p, sha)
    limited = h/'tool-path'
    limited.mkdir()
    for tool in ['bash', 'dirname', 'awk', 'cut', 'tr', 'date', 'mkdir', 'sed', 'python3']:
        found = shutil.which(tool)
        assert found, tool
        (limited/tool).symlink_to(found)
    out = checklist(h, 'check', extra={'PATH':str(limited)}, expected=(1,))
    assert all(f'{m}\topen\tartifact hash verification failed' in out for m in ROSTER)
    out = checklist(h, 'open', extra={'PATH':str(limited)})
    assert len(out.splitlines()) == 4

def s7():
    h = home('return-brief')
    run(h, 'fm-afk-contract.sh', 'enter', '--words', 'Observe receipts; do not write postmortem content.')
    for m in ['M3', 'Studio', 'local']:
        p, sha = artifact(h, m)
        if m == 'local':
            note(h, m, p, sha)
        else:
            receipt(h, m, p, sha if m == 'M3' else '0'*64)
    before = {p.name:p.read_bytes() for p in (h/'artifacts').iterdir()}
    out = run(h, 'fm-afk-return.sh', 'begin', expected=(0,3))
    waiting = out.split('Waiting on you:',1)[1].split('Tried and failed, or could not be fixed:',1)[0]
    assert f'- Hetzner: {TODAY}: no artifact receipt recorded' in waiting
    assert f'- Studio: {TODAY}: artifact hash mismatch' in waiting
    assert '- M3:' not in waiting and '- local:' not in waiting
    assert before == {p.name:p.read_bytes() for p in (h/'artifacts').iterdir()}
    out = run(h, 'fm-afk-return.sh', 'check', expected=(0,3))
    assert f'- Hetzner: {TODAY}:' in out
    log.write('Persisted checklist:\n' + (h/'state/postmortem-checklist.tsv').read_text())

def s8():
    h = home('malformed-posture')
    checklist(h, 'start', '--night', '2000-01-01')
    p = h/'state/.afk-contract'
    original = 'version: 1\nentered: 2026-09-08T08:00:00Z\nentered_epoch: 123\nwords: |-\n  retained recovery words\n'
    p.write_text(original)
    for action in ['begin', 'check']:
        out = run(h, 'fm-afk-return.sh', action, expected=(3,))
        assert 'away-posture record unreadable:' in out
        assert '- Hetzner: 2000-01-01: no artifact receipt recorded' in out
        assert p.read_text() == original
        assert (h/'state/.afk-return-catchup').exists()
        nights = {r.split('\t')[0] for r in (h/'state/postmortem-checklist.tsv').read_text().splitlines()}
        assert nights == {'2000-01-01', TODAY}, nights
    run(h, 'fm-afk-return.sh', 'guard', expected=(3,4))
    log.write('Persisted checklist (only seeded history plus current morning):\n' + (h/'state/postmortem-checklist.tsv').read_text())
    log.write('Retained recovery gate:\n' + (h/'state/.afk-return-catchup').read_text())

SCENARIOS = [
    ('morning-checklist', 'Local collection after 07:45 creates all four missing-machine rows once', s1),
    ('artifact-verification', 'Local receipts close matching artifacts across working directories and reopen changed or missing files', s2),
    ('inbox-arbitration', 'Local inbox receipts survive acknowledgement; conflicting same-second receipts remain open until a newer valid receipt', s3),
    ('retained-mornings', 'Local collection backfills due mornings and retains unresolved machines across later away windows', s4),
    ('calendar-validation', 'Local checklist rejects impossible dates and isolates malformed historical state', s5),
    ('hash-unavailable', 'Local checklist keeps every machine open when SHA tools are unavailable', s6),
    ('return-brief', 'Local morning return names missing and bad-hash machines while preserving existing artifact content', s7),
    ('malformed-posture', 'Local malformed-posture return stays gated without creating 1970 checklists or hiding retained rows', s8),
]
try:
    for slug, name, fn in SCENARIOS:
        path = EVIDENCE/f'live-{slug}.log'
        with path.open('w') as log:
            log.write(f'{name}\nRevision: b9d741afed1767f49eaea97d32c3bad0a8fca2a8\nReal worktree CLI; disposable marked FM_HOME; synthetic artifacts and local native clock.\n\n')
            try:
                fn()
            except Exception as exc:
                traceback.print_exc(file=log)
                RESULTS.append(dict(name=name,result='fail',live=True,evidence=str(path),reason=str(exc)))
                print('FAIL', slug, str(exc), flush=True)
            else:
                RESULTS.append(dict(name=name,result='pass',live=True,evidence=str(path),reason='Executed real CLI against isolated synthetic lab data.'))
                print('PASS', slug, flush=True)
finally:
    shutil.rmtree(WORK)
    (EVIDENCE/'live-results.json').write_text(json.dumps(RESULTS, indent=2)+'\n')
    print('Disposable lab homes removed.', flush=True)
raise SystemExit(1 if any(r['result']=='fail' for r in RESULTS) else 0)
