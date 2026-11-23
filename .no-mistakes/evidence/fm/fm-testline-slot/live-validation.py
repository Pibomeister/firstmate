import os, sys, json, pathlib, subprocess, time, signal, hashlib, socket
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path('~/.no-mistakes/evidence/01M850BNHVR60SN4NC8WRTAC9V')
WORK=ROOT/'.test-phase'/'live'
WORK.mkdir(parents=True, exist_ok=True)
BASE=os.environ.copy()
for key in list(BASE):
    if key.startswith(('FM_', 'TASKS_AXI_', 'REX_')) or key in ('BASH_ENV','ENV','ORCA_TERMINAL_HANDLE'):
        BASE.pop(key, None)
BASE.update(TMPDIR=str(ROOT/'.test-phase'/'tmp'), FM_TEST_QUEUE_REMOTE_DISABLE='1')
children=[]
handles=[]

def log(message):
    print(message, flush=True)

def call(args, env=None, timeout=180, check=True):
    p=subprocess.run([str(a) for a in args],env=env or BASE, text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if p.stdout: log(p.stdout.rstrip())
    if p.stderr: log('stderr: '+p.stderr.rstrip())
    if check and p.returncode: raise AssertionError('exit %d: %s'%(p.returncode,args))
    return p

def start(args, env, name):
    f=open(WORK/(name+'.log'),'w'); handles.append(f)
    p=subprocess.Popen([str(a) for a in args],env=env,stdout=f,stderr=f,start_new_session=True)
    children.append(p)
    return p

def until(predicate, description, timeout=120):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.15)
    raise AssertionError('timeout: '+description)

def reap(p):
    rc=p.wait(timeout=180)
    assert rc==0, 'child exit '+str(rc)

def queue_scenario():
    qdir=WORK/'queue'; qdir.mkdir()
    (qdir/'config').write_text('slots=2\nload_ceiling=96\n')
    load=WORK/'load'; load.write_text('1000000\n')
    env=BASE|dict(FM_TEST_SEAM='1',FM_TEST_QUEUE_DIR=str(qdir),FM_TEST_QUEUE_LOAD_FILE=str(load),FM_TEST_QUEUE_POLL='0.1')
    q=ROOT/'bin/fm-test-queue.sh'
    def status():
        return call(['/bin/bash',q,'status'],env).stdout
    def held(name):
        return start(['/bin/bash',q,'run','--label',name,'--','/bin/sh','-c',
                      ': > "$1/started-$2"; while [ ! -f "$1/release-$2" ]; do sleep 0.1; done; echo "$2" >> "$1/order"','_',WORK,name], env,name)
    def release(name): (WORK/('release-'+name)).touch()
    log('SCENARIO queue: synthetic load=1000000; slots=2; ceiling=96; remote disabled')
    a=held('oldest'); until(lambda:(WORK/'started-oldest').exists(),'reserved slot admission')
    b=held('second')
    until(lambda:'waiting position=1 ' in status(),'second queued')
    c=held('third')
    until(lambda:'waiting position=2 ' in status(),'third queued behind second')
    assert not (WORK/'started-second').exists() and not (WORK/'started-third').exists()
    release('oldest'); reap(a)
    until(lambda:(WORK/'started-second').exists(),'FIFO transfer at sustained overload')
    assert not (WORK/'started-third').exists()
    log('The second ticket took the reserved slot without load falling:')
    status()
    load.write_text('96\n'); time.sleep(2)
    assert not (WORK/'started-third').exists(), 'ceiling equality admitted second slot'
    log('At exact ceiling=96 the additional slot still waits:'); status()
    load.write_text('95.9\n')
    until(lambda:(WORK/'started-third').exists(),'additional slot below ceiling')
    log('Below ceiling both slots serve:'); status()
    release('second'); release('third'); reap(b); reap(c)
    assert (WORK/'order').read_text().splitlines()[0]=='oldest'
    (qdir/'config').write_text('slots=1\nload_ceiling=96\n'); load.write_text('1000000\n')
    d=held('single-oldest'); until(lambda:(WORK/'started-single-oldest').exists(),'single reserved slot')
    e=held('single-next'); until(lambda:'waiting position=1 ' in status(),'single next queued')
    assert not (WORK/'started-single-next').exists()
    release('single-oldest'); reap(d)
    until(lambda:(WORK/'started-single-next').exists(),'single slot FIFO handoff at overload')
    release('single-next'); reap(e)
    final=status(); assert 'serving=0 waiting=0' in final
    log('PASS queue: FIFO progress at overload, second-slot strict ceiling, one-slot progress, all tickets released')

WRITER=ROOT/'bin/fm-home-summary-refresh.sh'
def make_home(name):
    home=WORK/name
    for d in ('state','config','data','projects'): (home/d).mkdir(parents=True,exist_ok=True)
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return home

def summary_env(home, **kwargs):
    return BASE|dict(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(ROOT),FM_DATA_OVERRIDE=str(home/'data'),FM_STATE_OVERRIDE=str(home/'state'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),FM_TEST_SEAM='1',FM_NOW='1000')|kwargs

def ledger(home): return home/'state/home-summary.json'
def backoff(home): return home/'state/.home-summary-refresh.backoff'
def lock(home): return home/'state/.home-summary-refresh.lock'
def show_summary(home,label):
    doc=json.loads(ledger(home).read_text())
    log(label+': '+json.dumps({k:doc.get(k) for k in ('schema','home','generated','generated_epoch','valid','state','counts')}))
    return doc

def backoff_scenario():
    log('SCENARIO summary backoff: real producer, empty synthetic home, invalid public FM_SNAPSHOT_BUDGET=0 causes dependency-free producer failure')
    home=make_home('backoff-home'); env=summary_env(home)
    call([WRITER],env)
    assert show_summary(home,'Initial real publication')['valid'] is True
    prior=ledger(home).read_bytes()
    epoch=1000
    for count,delay in enumerate((30,60,120,240,480,960,1800,1800),1):
        call([WRITER,'--best-effort'],env|dict(FM_NOW=str(epoch),FM_SNAPSHOT_BUDGET='0'))
        wanted=f'failures={count}\nnext={epoch+delay}\n'
        actual=backoff(home).read_text(); log('After eligible failure: '+actual.replace('\n',' '))
        assert actual==wanted
        assert ledger(home).read_bytes()==prior
        failure_log=(home/'state/.home-summary-refresh.log').read_bytes()
        call([WRITER,'--best-effort'],env|dict(FM_NOW=str(epoch+delay-1),FM_SNAPSHOT_BUDGET='0'))
        assert backoff(home).read_text()==wanted
        assert (home/'state/.home-summary-refresh.log').read_bytes()==failure_log
        epoch+=delay
    log('Last-good ledger remained byte-identical; retries one second before each eligibility boundary produced no new error; cap remained 1800s')
    holder=start(['/bin/bash','-c',
       '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_HOME/state/.home-summary-refresh.lock"; trap \'fm_lock_release "$FM_HOME/state/.home-summary-refresh.lock"\' EXIT; : > "$FM_HOME/held"; while [ ! -f "$FM_HOME/release" ]; do sleep 0.1; done', '_',ROOT],env,'backoff-lock-holder')
    until(lambda:(home/'held').exists(),'real lock owner ready')
    wanted=backoff(home).read_bytes()
    call([WRITER,'--best-effort'],env|dict(FM_NOW=str(epoch),FM_HOME_SUMMARY_IF_IDLE='1'))
    assert backoff(home).read_bytes()==wanted
    log('Busy-lock if-idle skip preserved existing failure count and next eligibility epoch')
    (home/'release').touch(); reap(holder)
    # Bypass an active future backoff via the documented direct diagnostic call.
    call([WRITER],env|dict(FM_SNAPSHOT_NOW='2026-11-23T20:40:00Z',FM_SNAPSHOT_NOW_EPOCH='1795466400'))
    assert not backoff(home).exists() and not os.path.lexists(lock(home))
    show_summary(home,'Direct recovery publication')
    call([WRITER,'--best-effort'],env|dict(FM_NOW='1001',FM_SNAPSHOT_BUDGET='0'))
    assert backoff(home).read_text()=='failures=1\nnext=1031\n'
    log('Reset proved: next failure starts at failures=1 next=1031')
    log((home/'state/.home-summary-refresh.log').read_text())
    (EVIDENCE/'live-recovered-summary.json').write_bytes(ledger(home).read_bytes())
    log('PASS summary backoff: fixed exponential delays, cap, no early retry, last-good preservation, busy skip, direct bypass and reset')

def timeout_scenario():
    log('SCENARIO timeout admission: real producer over 5000 synthetic orphan backlog records; queued refresh must honor lock-held failure recording')
    home=make_home('timeout-home'); env=summary_env(home)
    call([WRITER],env)
    prior=ledger(home).read_bytes()
    (home/'data/backlog.md').write_text('## In flight\n'+''.join(f'- [ ] synthetic-{i} - Missing metadata (repo: firstmate) (kind: ship)\n' for i in range(5000))+'\n## Queued\n\n## Done\n')
    stage_a=home/'state/.home-summary-stage.live-a'
    stage_b=home/'state/.home-summary-stage.live-b'
    a=start([WRITER,'--best-effort'],env|dict(FM_HOME_SUMMARY_TIMEOUT='10',FM_HOME_SUMMARY_STAGE_PATH=str(stage_a)),'timeout-first')
    until(lambda:lock(home).is_dir(),'timeout attempt owns publication lock')
    b=start([WRITER,'--best-effort'],env|dict(FM_HOME_SUMMARY_TIMEOUT='90',FM_HOME_SUMMARY_STAGE_PATH=str(stage_b)),'timeout-queued')
    until(lambda: stage_b.exists() and 'lock-wait' in stage_b.read_text(),'second refresh queued under real lock')
    log('Queued attempt stages while first owns lock: '+stage_b.read_text().strip())
    reap(a); reap(b)
    log('Timeout error log: '+(home/'state/.home-summary-refresh.log').read_text().strip())
    actual=backoff(home).read_text(); log('Backoff before next admission: '+actual.replace('\n',' '))
    assert actual=='failures=1\nnext=1030\n'
    assert ledger(home).read_bytes()==prior
    assert not os.path.lexists(lock(home))
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    call([WRITER],env|dict(FM_SNAPSHOT_NOW='2026-11-23T20:45:00Z',FM_SNAPSHOT_NOW_EPOCH='1795466700'))
    assert not backoff(home).exists()
    replacement=ledger(home).read_bytes()
    time.sleep(3)
    assert ledger(home).read_bytes()==replacement and not backoff(home).exists()
    show_summary(home,'Recovery after queued timeout')
    log('PASS timeout admission: queued trigger did not retry, timeout retained prior ledger and released lock, recovery cleared failure')

def fallback_scenario():
    log('SCENARIO Bash fallback: real producer and writer with FM_TIMEOUT_MECHANISM_OVERRIDE=bash; no replacement of producer or publication logic')
    home=make_home('bash-timer-home'); env=summary_env(home,FM_TIMEOUT_MECHANISM_OVERRIDE='bash')
    mechanism=call(['/bin/bash','-c','. "$1/bin/fm-timeout-lib.sh"; fm_timeout_mechanism','_',ROOT],env).stdout.strip()
    assert mechanism=='bash'
    call([WRITER],env,timeout=180)
    doc=show_summary(home,'Bash-timed real publication')
    assert doc['valid'] is True and doc['schema']=='fm-secondmate-home-summary.v1'
    assert not os.path.lexists(lock(home))
    (EVIDENCE/'live-bash-fallback-summary.json').write_bytes(ledger(home).read_bytes())
    log('PASS Bash fallback: valid complete summary published and lock released')

try:
    log('Source revision: '+call(['git','rev-parse','HEAD']).stdout.strip())
    log('Host: '+socket.gethostname())
    call(['uptime'])
    for scenario in (queue_scenario,backoff_scenario,timeout_scenario,fallback_scenario):
        scenario()
    log('LIVE_VALIDATION_COMPLETE')
finally:
    for p in children:
        if p.poll() is None:
            try: os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError: pass
    for p in children:
        try: p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try: os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            p.wait(timeout=15)
    for f in handles: f.close()
    for p in sorted(WORK.glob('*.log')):
        text=p.read_text()
        if text: log('CHILD '+p.name+':\n'+text)
