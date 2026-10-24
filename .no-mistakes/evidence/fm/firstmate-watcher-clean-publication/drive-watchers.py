import os, pathlib, subprocess, time, signal, shutil, json, re
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5P9MH9YHZ7098T3VRGQQMR0')
BASE=ROOT/'.test-live-tmp/live'
BASE.mkdir()
log=(EVID/'watcher-live-transcript.log').open('w',buffering=1)
results=[]
procs=[]
def note(text):
    print(text,flush=True);log.write(text+'\n')
def env(home,**extra):
    e=os.environ.copy()
    for k in list(e):
        if k.startswith('FM_') or k in ('PI_CODING_AGENT','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
            e.pop(k)
    e.update(FM_HOME=str(home),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_ARM_CONFIRM_TIMEOUT='30')
    e.update(extra)
    return e
def home(name):
    h=BASE/name
    subprocess.run(['bin/fm-lab-home.sh','create',str(h)],check=True,capture_output=True)
    return h
def run(h,args,**extra):
    note('$ FM_HOME='+str(h)+' '+' '.join(args))
    r=subprocess.run(args,env=env(h,**extra),text=True,capture_output=True,timeout=60)
    note('stdout:\n'+r.stdout+'stderr:\n'+r.stderr+'exit='+str(r.returncode))
    return r
def waitfor(fn,timeout=35):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if fn():return
        time.sleep(.1)
    raise AssertionError('condition did not become true')
def start(h,args,label):
    out=(h/(label+'.out')).open('w');err=(h/(label+'.err')).open('w')
    p=subprocess.Popen(args,env=env(h),stdout=out,stderr=err,start_new_session=True)
    procs.append(p)
    note('$ '+' '.join(args)+' [pid='+str(p.pid)+']')
    waitfor(lambda:(h/'state/.last-watcher-beat').exists() and (h/'state/.watch.lock/pid').exists())
    return p
def contents(p):return p.read_text() if p.exists() else '<absent>'
def record(name,fn):
    note('\nSCENARIO: '+name)
    try:fn(); results.append(dict(name=name,result='pass',live=True))
    except Exception as ex:
        note('FAIL: '+repr(ex));results.append(dict(name=name,result='fail',live=True,reason=repr(ex)))
def quiet():
    h=home('quiet')
    for i in range(3):
        r=run(h,['bin/fm-watch-checkpoint.sh','--seconds','5'])
        assert r.returncode==0 and r.stdout=='checkpoint: no actionable wake within 5s\n'
        assert not (h/'state/.watch.lock/pid').exists()
        note('durable marker: '+contents(h/'state/.watcher-down'))
def rearm():
    h=home('rearm')
    for i,mode in enumerate(('TERM','KILL','APPEND')):
        p=start(h,['bin/fm-watch-arm.sh'],'arm'+str(i))
        waitfor(lambda:'watcher: started' in contents(h/('arm'+str(i)+'.out')))
        time.sleep(3)
        assert p.poll() is None,'rearm produced a premature close'
        note('arm output: '+contents(h/('arm'+str(i)+'.out')))
        note('marker while armed: '+contents(h/'state/.watcher-down'))
        if mode=='APPEND':
            r=run(h,['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check late "check: actionable row appended after silent rearm"'])
            assert r.returncode==0
            assert p.wait(timeout=35)==0
            text=contents(h/('arm'+str(i)+'.out'))
            note('delivered output: '+text)
            assert text.count('check: rearm-resurface')==1
            note('durable queue:\n'+contents(h/'state/.wake-queue'))
            assert 'actionable row appended' in contents(h/'state/.wake-queue')
        else:
            wp=int((h/'state/.watch.lock/pid').read_text())
            note('send '+mode+' to lab watcher '+str(wp))
            os.kill(wp,signal.SIGTERM if mode=='TERM' else signal.SIGKILL)
            p.wait(timeout=40)
            note('closed arm output:\n'+contents(h/('arm'+str(i)+'.out')))
            if mode=='TERM':assert contents(h/'state/.watcher-down').startswith('pending:downtime:')
def durable():
    h=home('durable')
    r=run(h,['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check buried "check: original durable work"'])
    assert r.returncode==0
    first=run(h,['bin/fm-watch-checkpoint.sh','--seconds','8'])
    assert first.returncode==0 and first.stdout.count('check: rearm-resurface')==1
    second=run(h,['bin/fm-watch-checkpoint.sh','--seconds','5'])
    assert second.returncode==0 and second.stdout=='checkpoint: no actionable wake within 5s\n'
    drained=run(h,['bin/fm-wake-drain.sh'])
    assert 'original durable work' in drained.stdout
    ack=re.search(r'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh (.+)',drained.stderr)
    assert ack,'no acknowledgement provided'
    r=run(h,['bin/fm-wake-drain.sh']+ack.group(1).split())
    assert r.returncode==0 and not (h/'state/.wake-queue').stat().st_size
    r=run(h,['bin/fm-watch-checkpoint.sh','--seconds','5'])
    assert r.returncode==0 and r.stdout=='checkpoint: no actionable wake within 5s\n'
def custom():
    h=home('custom-check')
    f=h/'state/orchestration.check.sh'
    f.write_text('#!/usr/bin/env bash\nprintf "work ready; interval=%s\\n" "$FM_CHECK_INTERVAL"\n')
    f.chmod(0o700)
    r=run(h,['bin/fm-check-register.sh','orchestration']);assert r.returncode==0
    r=run(h,['bin/fm-watch-checkpoint.sh','--seconds','15'],FM_CHECK_INTERVAL='1')
    assert r.returncode==0 and 'check:' in r.stdout and 'work ready; interval=1' in r.stdout
    r=run(h,['bin/fm-wake-drain.sh']);assert 'work ready; interval=1' in r.stdout
def fail_closed():
    h=home('failed-cleanup')
    holder=subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh; fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit; touch "$FM_HOME/held"; while [ ! -e "$FM_HOME/release" ]; do sleep .1; done; fm_lock_release "$FM_HOME/state/.watcher-down.lock"'],env=env(h),start_new_session=True)
    procs.append(holder)
    try:
        waitfor(lambda:(h/'held').exists())
        r=run(h,['bin/fm-watch-checkpoint.sh','--seconds','1'],FM_WATCHER_CLEANUP_LOCK_BOUND='2')
        assert r.returncode!=0 and 'recovery state could not be persisted' in r.stderr and 'no actionable wake' not in r.stdout
        assert (h/'state/.watch.lock/pid').exists()
        note('retained failed watcher pid: '+contents(h/'state/.watch.lock/pid'))
    finally:
        (h/'release').touch();holder.wait(timeout=10)
try:
    record('Repeated empty checkpoints finish cleanly without bookkeeping wakes',quiet)
    record('Graceful and abrupt empty-queue rearm stay silent; a later durable row wakes once',rearm)
    record('Buried work surfaces once, survives drain, and stops replaying after acknowledgement',durable)
    record('Registered work checks execute with caller environment and deliver durable work',custom)
    record('Interrupted startup with blocked recovery persistence reports a real failure',fail_closed)
finally:
    for p in procs:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=15)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    (EVID/'watcher-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(BASE)
    log.close()
assert all(r['result']=='pass' for r in results),results
