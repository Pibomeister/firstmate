import json, os, pathlib, shutil, signal, subprocess, tempfile, time, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M818HHAPS034DN81WTZ21CV8/validation-28ef4849')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='.nm-live-',dir=ROOT/'.phase-test-tmp'))
log=(E/'live-validation.log').open('w',buffering=1)
children=[]
results=[]
def say(s):
    log.write(s+'\n'); print(s,flush=True)
def env_for(home=None):
    e=dict(os.environ)
    for k in list(e):
        if k.startswith(('FM_','TASKS_AXI_')) or k in ('BASH_ENV','TMUX','TMUX_PANE','REX_SESSION','REX_BLOCK','ORCA_TERMINAL_HANDLE'):
            e.pop(k,None)
    if home:
        e.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(LAB),FM_HOME_SUMMARY_TIMEOUT='120')
    return e
base=env_for()
def run(args,env=None,timeout=200,check=True):
    p=subprocess.run([str(x) for x in args],env=env or base,capture_output=True,text=True,timeout=timeout)
    say('$ '+' '.join(str(x) for x in args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    if check: assert p.returncode==0,(args,p.returncode,p.stderr)
    return p

def wait_for(fn,what,timeout=120):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if fn(): return
        time.sleep(.1)
    raise AssertionError('timed out: '+what)

def start(args,env,name):
    f=(E/(name+'.log')).open('w')
    p=subprocess.Popen([str(x) for x in args],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
    children.append((p,f)); return p

def finish(p,timeout=200):
    rc=p.wait(timeout=timeout); say('child '+str(p.pid)+' exit='+str(rc)); assert rc==0,rc

def record(name,fn):
    say('\nSCENARIO '+name)
    try:
        fn(); results.append(dict(name=name,result='pass',live=True,evidence=str(E/'live-validation.log'),reason='Real repository CLI with disposable local inputs; no product or dependency replacements.'))
    except Exception as exc:
        say(traceback.format_exc()); results.append(dict(name=name,result='fail',live=True,evidence=str(E/'live-validation.log'),reason=str(exc)))

def queue_scenario():
    q=ROOT/'bin/fm-test-queue.sh'; d=LAB/'queue'; d.mkdir(); spool=d/'spool'; spool.mkdir()
    (spool/'config').write_text('slots=2\nload_ceiling=96\n')
    load=d/'load'; load.write_text('400\n')
    e=env_for(); e.update(FM_TEST_SEAM='1',FM_TEST_QUEUE_DIR=str(spool),FM_TEST_QUEUE_LOAD_FILE=str(load),FM_TEST_QUEUE_POLL='0.1',FM_TEST_QUEUE_REMOTE_DISABLE='1')
    def status(label):
        s=run([q,'status'],e).stdout; say('CHECKPOINT '+label); return s
    def job(n):
        program='import pathlib,sys,time; d=pathlib.Path(sys.argv[1]); n=sys.argv[2]; (d/("started-"+n)).write_text(n); print("receipt started "+n,flush=True)\nwhile not (d/("release-"+n)).exists(): time.sleep(.1)\nprint("receipt completed "+n,flush=True)'
        return start([q,'run','--label',n,'--','python3','-c',program,d,n],e,'queue-'+n)
    a=job('A'); wait_for(lambda:(d/'started-A').exists(),'A starts at load 400')
    b=job('B'); wait_for(lambda:'label=B' in subprocess.run([str(q),'status'],env=e,capture_output=True,text=True).stdout,'B enqueued')
    c=job('C'); wait_for(lambda:'label=C' in subprocess.run([str(q),'status'],env=e,capture_output=True,text=True).stdout,'C enqueued')
    s=status('high load: one serving, B then C waiting'); assert 'serving=1 waiting=2' in s; assert 'waiting position=1' in s and 'label=B' in s
    assert not (d/'started-B').exists() and not (d/'started-C').exists()
    (d/'release-A').touch(); finish(a); wait_for(lambda:(d/'started-B').exists(),'oldest B replaces A at high load')
    assert not (d/'started-C').exists(); s=status('reserved slot makes FIFO progress at load 400'); assert 'serving=1 waiting=1' in s
    load.write_text('95\n'); wait_for(lambda:(d/'started-C').exists(),'second slot opens below 96')
    s=status('load 95 admits second slot'); assert 'serving=2 waiting=0' in s
    fourth=job('D'); wait_for(lambda:'label=D' in subprocess.run([str(q),'status'],env=e,capture_output=True,text=True).stdout,'D queued')
    s=status('configured two-slot limit'); assert 'serving=2 waiting=1' in s and not (d/'started-D').exists()
    (d/'release-B').touch(); finish(b); wait_for(lambda:(d/'started-D').exists(),'D takes freed slot')
    for n in ('C','D'): (d/('release-'+n)).touch()
    finish(c); finish(fourth)
    load.write_text('400\n'); (spool/'config').write_text('slots=1\nload_ceiling=96\n')
    r=run([q,'run','--label','single-slot','--','sh','-c','echo receipt-at-load-400; exit 7'],e,check=False)
    assert r.returncode==7 and r.stdout.strip()=='receipt-at-load-400'
    assert 'serving=0 waiting=0' in status('all receipts finished; private spool empty')

home=LAB/'home'
def seed():
    run([ROOT/'bin/fm-lab-home.sh','create',home])
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')

def writer(now=1000,bad=False,direct=False,extra=None):
    e=env_for(home); e.update(FM_TEST_SEAM='1',FM_NOW=str(now))
    if bad: e['FM_SNAPSHOT_BUDGET']='0'
    if extra: e.update(extra)
    return run([ROOT/'bin/fm-home-summary-refresh.sh']+([] if direct else ['--best-effort']),e)

def backoff_state():
    p=home/'state/.home-summary-refresh.backoff'
    if not p.exists(): return None
    s=p.read_text(); say('persisted backoff:\n'+s)
    return dict(x.split('=',1) for x in s.splitlines())

def schedule_scenario():
    seed(); writer(direct=True)
    ledger=home/'state/home-summary.json'; before=ledger.read_bytes(); say('initial ledger: '+json.dumps(json.loads(before),sort_keys=True))
    now=1000
    for count,delay in enumerate((30,60,120,240,480,960,1800,1800),1):
        writer(now,bad=True); assert backoff_state()==dict(failures=str(count),next=str(now+delay))
        assert ledger.read_bytes()==before
        failure_log=(home/'state/.home-summary-refresh.log').read_bytes()
        writer(now+delay-1,bad=True); assert (home/'state/.home-summary-refresh.log').read_bytes()==failure_log
        say('retry suppressed until epoch '+str(now+delay)+'; previous complete ledger preserved')
        now+=delay
    writer(1000,direct=True); assert backoff_state() is None
    writer(1001,bad=True); assert backoff_state()==dict(failures='1',next='1031')
    writer(1002,direct=True); assert backoff_state() is None
    say('direct diagnostic refresh bypassed active backoff, published valid JSON, and reset failure count')

def lock_scenario():
    # Real lock owner holds both queued triggers until both have entered lock-wait.
    holder=LAB/'holder-ready'; release=LAB/'holder-release'
    program=""". "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"; trap 'fm_lock_release "$2/state/.home-summary-refresh.lock"' EXIT; touch "$3"; while [ ! -e "$4" ]; do sleep .1; done"""
    e=env_for(home)
    p=start(['bash','-c',program,'_',ROOT,home,holder,release],e,'lock-holder')
    wait_for(holder.exists,'real refresh lock held')
    f=home/'state/.home-summary-refresh.backoff'; f.write_text('failures=2\nnext=900\n')
    writer(1000,bad=True,extra={'FM_HOME_SUMMARY_IF_IDLE':'1'}); assert backoff_state()==dict(failures='2',next='900')
    f.unlink()
    pending=[]
    for name in ('queued-A','queued-B'):
        stage=home/('state/.home-summary-stage.'+name)
        we=env_for(home); we.update(FM_TEST_SEAM='1',FM_NOW='1000',FM_SNAPSHOT_BUDGET='0',FM_HOME_SUMMARY_STAGE_PATH=str(stage))
        pending.append(start([ROOT/'bin/fm-home-summary-refresh.sh','--best-effort'],we,name))
        wait_for(lambda s=stage:s.exists() and 'lock-wait' in s.read_text(),'queued refresh reaches lock-wait')
        say(name+' reached real lock-wait')
    release.touch(); finish(p)
    for child in pending: finish(child)
    assert backoff_state()==dict(failures='1',next='1030')
    say('two queued triggers caused one failure; second trigger honored the locked backoff recheck; idle skip preserved prior count')

try:
    record('Local queue at synthetic load 400 preserves FIFO progress, load gating, slot cap, and receipt status',queue_scenario)
    record('Local real-producer configuration failures back off 30–1800 seconds, preserve the ledger, and reset after direct publication',schedule_scenario)
    if home.exists(): record('Local overlapping refresh triggers preserve idle-skip state and recheck backoff after lock acquisition',lock_scenario)
finally:
    for p,f in children:
        if p.poll() is None:
            try: os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL); p.wait()
        f.close()
    shutil.rmtree(LAB)
    say('All live-driver children reaped; disposable workspace removed.')
    (E/'live-scenarios.json').write_text(json.dumps(results,indent=2))
    log.close()
