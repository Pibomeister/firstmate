import hashlib, json, os, pathlib, signal, subprocess, time

ROOT = pathlib.Path.cwd()
EV = pathlib.Path('~/.no-mistakes/evidence/01M84MSFJVVKGQQDE4HC3SV54G')
LAB = ROOT / '.test-phase/live'
LAB.mkdir(parents=True, exist_ok=True)
(ROOT / '.test-phase/tmp').mkdir(parents=True, exist_ok=True)
BASE = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
BASE.update(TMPDIR=str(ROOT / '.test-phase/tmp'), FM_ROOT_OVERRIDE=str(ROOT), FM_TEST_QUEUE_REMOTE_DISABLE='1')
children=[]
known={}
handles=[]
results=[]
log=open(EV/'live-transcript.log','w', buffering=1)
def facts():
    rows=subprocess.check_output(['ps','-axo','pid=,ppid=,lstart='],text=True).splitlines()
    out={}
    for row in rows:
        parts=row.split(None,2)
        if len(parts)==3: out[int(parts[0])]=(int(parts[1]),parts[2])
    return out
def remember_tree(root):
    current=facts(); ids={root}
    for _ in range(30):
        expanded=ids|{pid for pid,(ppid,_) in current.items() if ppid in ids}
        if expanded==ids: break
        ids=expanded
    known.update({pid:current[pid][1] for pid in ids if pid in current})
def say(s):
    print(s, flush=True); print(s,file=log,flush=True)
def start(label,args,extra=None):
    env=BASE.copy(); env.update(extra or {})
    f=open(EV/(label+'.log'),'w'); handles.append(f)
    p=subprocess.Popen([str(a) for a in args],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
    children.append(p)
    say(f'RUN {label}: {args}; inputs={extra or {}}; pid={p.pid}')
    return p
def finish(label,p,timeout=120,expected=0):
    rc=p.wait(timeout=timeout)
    say(f'EXIT {label}: {rc}')
    assert rc==expected, (label,rc,expected)
    return rc
def waitfor(desc,fn,timeout=60):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if fn(): return
        time.sleep(.05)
    raise AssertionError('timeout: '+desc)
def text(p):
    try: return p.read_text()
    except FileNotFoundError: return ''
def save(name,p):
    data=p.read_bytes(); (EV/name).write_bytes(data)
    return hashlib.sha256(data).hexdigest()
def home(name):
    h=LAB/name
    for d in ('state','data','config','projects'): (h/d).mkdir(parents=True,exist_ok=True)
    (h/'.fm-secondmate-home').write_text('disposable local validation\n')
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return h
def refresh(label,h,best=True,**env):
    e={'FM_HOME':str(h),'FM_HOME_SUMMARY_TIMEOUT':'90'}; e.update({k:str(v) for k,v in env.items()})
    return start(label,[ROOT/'bin/fm-home-summary-refresh.sh']+(['--best-effort'] if best else []),e)
def lock(h,label):
    ready=LAB/(label+'.ready'); release=LAB/(label+'.release')
    code='. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"; : > "$3"; while [ ! -e "$4" ]; do sleep 0.05; done; fm_lock_release "$2/state/.home-summary-refresh.lock"'
    p=start(label,['bash','-c',code,'_',ROOT,h,ready,release],{'FM_HOME':str(h)})
    waitfor('real lock acquired',ready.exists)
    return p,release

def queue_scenario():
    q=LAB/'queue'; q.mkdir(); (q/'config').write_text('slots=2\nload_ceiling=96\n')
    load=LAB/'load'; load.write_text('300\n')
    env={'FM_TEST_QUEUE_DIR':str(q),'FM_TEST_QUEUE_LOAD_FILE':str(load),'FM_TEST_SEAM':'1','FM_TEST_QUEUE_POLL':'0.1'}
    def job(name):
        return start('queue-'+name,[ROOT/'bin/fm-test-queue.sh','run','--label',name,'--','bash','-c',': > "$1/start-$2"; while [ ! -e "$1/release-$2" ]; do sleep .05; done; printf "%s\\n" "$2" >> "$1/order"','_',LAB,name],env)
    a=job('oldest'); waitfor('oldest starts above ceiling',(LAB/'start-oldest').exists)
    b=job('second'); waitfor('second queues',lambda: len(list((q/'tickets').glob('*')))>=2)
    c=job('third'); waitfor('third queues',lambda: len(list((q/'tickets').glob('*')))>=3)
    def status(label):
        p=start(label,[ROOT/'bin/fm-test-queue.sh','status'],env); finish(label,p)
        s=(EV/(label+'.log')).read_text(); say(s.strip()); return s
    s=status('queue-high-status'); assert 'serving=1 waiting=2' in s
    assert not (LAB/'start-second').exists() and not (LAB/'start-third').exists()
    (LAB/'release-oldest').touch(); finish('queue-oldest',a)
    waitfor('second inherits reserved slot',(LAB/'start-second').exists)
    assert not (LAB/'start-third').exists()
    s=status('queue-high-turnover'); assert 'serving=1 waiting=1' in s and 'label=second' in s
    load.write_text('95\n'); waitfor('second slot opens below ceiling',(LAB/'start-third').exists)
    s=status('queue-low-status'); assert 'serving=2 waiting=0' in s
    (LAB/'release-second').touch(); finish('queue-second',b)
    (LAB/'release-third').touch(); finish('queue-third',c)
    s=status('queue-empty-status'); assert 'serving=0 waiting=0' in s
    say('OBSERVED: synthetic load 300 admitted only oldest, FIFO turnover preserved one slot; load 95 admitted second slot; every ticket drained.')

def backoff_scenario():
    h=home('backoff'); ledger=h/'state/home-summary.json'; back=h/'state/.home-summary-refresh.backoff'; errors=h/'state/.home-summary-refresh.log'
    p=refresh('backoff-seed',h,best=False); finish('backoff-seed',p)
    original=ledger.read_bytes(); epoch=1000
    (h/'data/backlog.md').chmod(0)
    say('INPUT: real synthetic backlog file is unreadable (mode 000); real producer and jq remain unchanged.')
    for n,delay in enumerate((30,60,120,240,480,960,1800,1800),1):
        # Unreadable synthetic data goes through the real producer and real jq; no executable is replaced.
        label=f'backoff-fail-{n}'; p=refresh(label,h,FM_TEST_SEAM=1,FM_NOW=epoch); finish(label,p)
        record=back.read_text(); assert record==f'failures={n}\nnext={epoch+delay}\n',record
        assert ledger.read_bytes()==original
        before=errors.read_bytes(); p=refresh(f'backoff-skip-{n}',h,FM_TEST_SEAM=1,FM_NOW=epoch+delay-1); finish(f'backoff-skip-{n}',p)
        assert errors.read_bytes()==before and back.read_text()==record
        say(f'OBSERVED failure={n} retry_delay={delay}s, best-effort exit=0, last-good ledger unchanged, pre-deadline retry skipped; record={record.strip()!r}')
        epoch+=delay
    save('backoff-before-recovery.txt',back); save('backoff-product-errors.log',errors)
    (h/'data/backlog.md').chmod(0o600)
    p=refresh('backoff-direct-recovery',h,best=False,FM_TEST_SEAM=1,FM_NOW=1000); finish('backoff-direct-recovery',p)
    assert not back.exists(); doc=json.loads(ledger.read_text()); assert doc['schema']=='fm-secondmate-home-summary.v1'
    save('backoff-recovered-summary.json',ledger)
    (h/'data/backlog.md').chmod(0)
    p=refresh('backoff-reset-failure',h,FM_TEST_SEAM=1,FM_NOW=1001); finish('backoff-reset-failure',p)
    assert back.read_text()=='failures=1\nnext=1031\n'
    say('OBSERVED: direct refresh bypassed active backoff, published a complete ledger and reset next failure to 30s.')

def contention_scenario():
    h=home('contention'); back=h/'state/.home-summary-refresh.backoff'; errors=h/'state/.home-summary-refresh.log'
    holder,release=lock(h,'contention-lock')
    back.write_text('failures=2\nnext=900\n')
    p=refresh('busy-lock-skip',h,FM_TEST_SEAM=1,FM_NOW=1000,FM_HOME_SUMMARY_IF_IDLE=1); finish('busy-lock-skip',p)
    assert back.read_text()=='failures=2\nnext=900\n'
    back.unlink()
    (h/'data/backlog.md').chmod(0)
    stages=[]; queued=[]
    for i in range(2):
        stage=h/f'state/.home-summary-stage.live-{i}'; stages.append(stage)
        p=refresh(f'queued-failure-{i}',h,FM_TEST_SEAM=1,FM_NOW=1000,FM_HOME_SUMMARY_STAGE_PATH=stage)
        queued.append(p); waitfor('queued worker entered lock-wait',lambda stage=stage:'lock-wait' in text(stage))
    release.touch(); finish('contention-lock',holder)
    for i,p in enumerate(queued): finish(f'queued-failure-{i}',p)
    assert back.read_text()=='failures=1\nnext=1030\n'
    assert errors.read_text().count('summary producer failed')==1,errors.read_text()
    save('contention-backoff.txt',back); save('contention-product-errors.log',errors)
    say('OBSERVED: if-idle skip retained failures=2; two queued real producers resulted in one failure and one backoff skip.')
    # An actual expensive input exercises the real lock-held deadline; no shim or mock replaces the producer.
    h=home('deadline'); p=refresh('deadline-seed',h,best=False); finish('deadline-seed',p)
    ledger=h/'state/home-summary.json'; before=ledger.read_bytes()
    with (h/'data/backlog.md').open('w') as f:
        f.write('## In flight\n\n## Queued\n')
        for i in range(40000): f.write(f'- [ ] pending-{i} - Synthetic queued validation item (repo: firstmate) (kind: ship)\n')
        f.write('\n## Done\n')
    p=refresh('real-producer-deadline',h,FM_HOME_SUMMARY_TIMEOUT=4,FM_TEST_SEAM=1,FM_NOW=1000); finish('real-producer-deadline',p,timeout=30)
    back=h/'state/.home-summary-refresh.backoff'; assert back.read_text()=='failures=1\nnext=1030\n'
    assert ledger.read_bytes()==before
    errors=h/'state/.home-summary-refresh.log'; save('deadline-product-errors.log',errors)
    before_error=errors.read_bytes(); p=refresh('deadline-immediate-retry',h,FM_HOME_SUMMARY_TIMEOUT=4,FM_TEST_SEAM=1,FM_NOW=1001); finish('deadline-immediate-retry',p,timeout=30)
    assert errors.read_bytes()==before_error and back.read_text()=='failures=1\nnext=1030\n'
    say('OBSERVED: real 40,000-row producer exceeded 4s budget; best-effort returned 0, preserved ledger and recorded backoff; immediate retry skipped.')

def interruption_scenario():
    h=home('interruption'); p=refresh('interruption-seed',h,best=False); finish('interruption-seed',p)
    ledger=h/'state/home-summary.json'; before=ledger.read_bytes()
    with (h/'data/backlog.md').open('w') as f:
        f.write('## In flight\n\n## Queued\n')
        for i in range(40000): f.write(f'- [ ] old-{i} - Older interrupted input (repo: firstmate) (kind: ship)\n')
        f.write('\n## Done\n')
    stage=h/'state/.home-summary-stage.interrupted'
    p=refresh('interrupted-older-writer',h,FM_HOME_SUMMARY_TIMEOUT=10,FM_HOME_SUMMARY_STAGE_PATH=stage)
    waitfor('old real producer started',lambda:'producer' in text(stage))
    owner=int((h/'state/.home-summary-refresh.lock/pid').read_text())
    say(f'OBSERVED: old producer started while publication lock owned by pid={owner}; killing only the lock owner.')
    remember_tree(owner)
    os.kill(owner,signal.SIGKILL)
    finish('interrupted-older-writer',p)
    assert ledger.read_bytes()==before
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n- [ ] replacement - Newer input (repo: firstmate) (kind: ship)\n\n## Done\n')
    p=refresh('replacement-writer',h,best=False); finish('replacement-writer',p)
    doc=json.loads(ledger.read_text()); assert any(r['id']=='replacement' for r in doc['queued'])
    replacement=ledger.read_bytes()
    # Let the old attempt's 10s deadline plus 3s kill grace expire before checking for delayed overwrite.
    time.sleep(14)
    assert ledger.read_bytes()==replacement
    save('interruption-replacement-summary.json',ledger)
    say('OBSERVED: killed lock owner left prior ledger intact; replacement recovered lock and remained byte-identical after old deadline plus grace.')

try:
    say('REVISION '+subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    say('HOST '+subprocess.check_output(['hostname'],text=True).strip())
    for name,fn in [('high-load queue admission and FIFO turnover',queue_scenario),('real producer failure backoff and recovery',backoff_scenario),('busy lock, queued triggers and real producer deadline',contention_scenario),('interrupted owner cannot overwrite newer publication',interruption_scenario)]:
        try:
            fn(); results.append({'name':name,'result':'pass','live':True}); say('SCENARIO PASS '+name)
        except Exception as e:
            results.append({'name':name,'result':'fail','live':True,'error':repr(e)}); say('SCENARIO FAIL '+name+': '+repr(e)); break
finally:
    # Only inspect process identities to clean descendants of commands this driver owns.
    rows=subprocess.check_output(['ps','-axo','pid=,ppid='],text=True).splitlines()
    pairs=[tuple(map(int,r.split())) for r in rows if len(r.split())==2]
    owned={p.pid for p in children if p.poll() is None}
    for _ in range(30):
        expanded=owned|{pid for pid,ppid in pairs if ppid in owned}
        if expanded==owned: break
        owned=expanded
    current=facts()
    owned|={pid for pid,identity in known.items() if pid in current and current[pid][1]==identity}
    for pid in reversed(sorted(owned)):
        try: os.kill(pid,signal.SIGKILL)
        except ProcessLookupError: pass
    for p in children:
        if p.poll() is None: p.wait(timeout=20)
    for f in handles: f.close()
    (EV/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
if any(x['result']!='pass' for x in results): raise SystemExit(1)
