import os, subprocess as sp, pathlib as P, time, signal, json, traceback, shutil
ROOT=P.Path.cwd(); E=P.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5WPXNZDE1WCTBNY9HZY8TTC')
BASE=ROOT/'.test-phase'; results=[]; processes=[]; homes=[]
def read(p):
    try:return P.Path(p).read_text()
    except FileNotFoundError:return ''
def waitfor(fn, seconds=20):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if fn():return
        time.sleep(.04)
    raise AssertionError('observable condition timed out')
def home(name):
    h=BASE/name; sp.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(h)],check=True,stdout=sp.DEVNULL); homes.append(h)
    (h/'config/backend').write_text('tmux\n'); return h
def env(h, **extra):
    e={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TMUX_PANE'))}
    e.update(FM_HOME=str(h),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(BASE/'tmp'),TMUX_TMPDIR=str(E/'l/tmux'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WEDGE_ALARM_EXEC='discard')
    # All tmux calls address this private named server, never the operator server.
    e['TMUX']=str(E/'l/tmux'/('tmux-'+str(os.getuid()))/'fm-lab')+',0,0'
    e.update({k:str(v) for k,v in extra.items()});return e
def start(h, command, tag, **extra):
    out=open(h/(tag+'.out'),'w'); err=open(h/(tag+'.err'),'w')
    p=sp.Popen(command,env=env(h,**extra),stdout=out,stderr=err,start_new_session=True);out.close();err.close(); processes.append(p);return p
def command(h, name, args=(), tag=None, **extra):
    p=start(h,[str(ROOT/'bin'/name),*args],tag or name,**extra);rc=p.wait(timeout=50); return rc,read(h/((tag or name)+'.out')),read(h/((tag or name)+'.err'))
def lock(h, name, tag):
    p=start(h,['bash','-c','. "$1"; fm_lock_acquire_wait "$STATE/$2" || exit 1; touch "$FM_HOME/$3.ready"; while [ ! -e "$FM_HOME/$3.release" ]; do sleep 0.05; done; fm_lock_release "$STATE/$2"','_',str(ROOT/'bin/fm-wake-lib.sh'),name,tag],tag)
    waitfor(lambda:(h/(tag+'.ready')).exists());return p
def unlock(h, tag, p):
    (h/(tag+'.release')).touch();assert p.wait(timeout=8)==0

def log(h, name, detail):
    chunks=[name,detail]
    for p in sorted(h.glob('*.out'))+sorted(h.glob('*.err')):
        t=read(p)
        if t:chunks+=['\n$ '+p.name,t]
    for n in ('.watcher-down','.wake-queue','.watch-deliveries.log','.supervision-host.log','.supervision-host-left'):
        if (h/'state'/n).exists():chunks+=['\nPersisted '+n,read(h/'state'/n)]
    (E/(name+'.log')).write_text('\n'.join(chunks)+'\n')
def scenario(name, fn):
    h=home(name)
    try:
        detail=fn(h);log(h,name,detail);results.append(dict(name=name,result='pass',detail=detail))
    except Exception as ex:
        log(h,name,traceback.format_exc());results.append(dict(name=name,result='fail',detail=str(ex)))
    print(json.dumps(results[-1]),flush=True)

def quiet(h):
    rc,out,err=command(h,'fm-watch-checkpoint.sh',['--seconds','2'],tag='checkpoint')
    assert rc==0 and 'checkpoint: no actionable wake within 2s' in out and not err,(rc,out,err)
    assert not (h/'state/.watch.lock/pid').exists();assert not read(h/'state/.wake-queue')
    gen=read(h/'state/.watcher-down').strip().split(':')[-1]
    p=start(h,[str(ROOT/'bin/fm-watch-checkpoint.sh'),'--seconds','4'],'successor')
    waitfor(lambda:read(h/'state/.watcher-down').strip()=='acked:downtime:'+gen)
    assert p.poll() is None and not read(h/'state/.wake-queue')
    (h/'retired-while-running.out').write_text('marker='+read(h/'state/.watcher-down')+'successor_running=true\nqueue_empty=true\n')
    rc=p.wait(timeout=12);out=read(h/'successor.out')
    assert rc==0 and 'checkpoint: no actionable wake' in out and 'rearm-resurface' not in out
    return 'Two real foreground checkpoints returned 0 without wakes. Ordinary downtime was retired on the same generation; the singleton lock was released.'

def recovery(h):
    rc,out,err=command(h,'fm-watch-checkpoint.sh',['--seconds','1'],tag='initial');assert rc==0
    p=start(h,['bash','-c','. "$1"; fm_wake_append check live-probe "check: durable work during downtime"','_',str(ROOT/'bin/fm-wake-lib.sh')],'append');assert p.wait(timeout=10)==0
    rc,out,err=command(h,'fm-watch-checkpoint.sh',['--seconds','5'],tag='recover');assert rc==0 and 'check: rearm-resurface' in out
    marker=read(h/'state/.watcher-down');queue=read(h/'state/.wake-queue');assert 'durable work during downtime' in queue
    rc,out,err=command(h,'fm-watch-checkpoint.sh',['--seconds','2'],tag='next');assert rc==0 and 'checkpoint: no actionable wake' in out and 'rearm-resurface' not in out
    assert read(h/'state/.watcher-down')==marker and read(h/'state/.wake-queue')==queue
    rc,out,err=command(h,'fm-wake-drain.sh',tag='drain');assert rc==0 and 'durable work during downtime' in out
    import re
    m=re.search(r'--ack-through (\d+) --recovery-generation ([\w.-]+)',err);assert m,(out,err)
    rc,out,err=command(h,'fm-wake-drain.sh',['--ack-through',m[1],'--recovery-generation',m[2]],tag='ack');assert rc==0 and not read(h/'state/.wake-queue')
    return 'A real queued wake resurfaced once, survived a second quiet checkpoint unchanged, and was removed only by the drain acknowledgement printed by the product.'

def signal_checkpoint(h):
    p=start(h,[str(ROOT/'bin/fm-watch-checkpoint.sh'),'--seconds','12'],'checkpoint')
    waitfor(lambda:(h/'state/.last-watcher-beat').exists())
    (h/'state/demo.status').write_text('done: live checkpoint status delivery\n')
    assert p.wait(timeout=20)==0
    out=read(h/'checkpoint.out');assert out.count('signal: ')==1 and 'demo.status' in out
    assert 'demo.status' in read(h/'state/.wake-queue')
    return 'Writing a real status file closed the foreground checkpoint with one signal line, exit 0, and a durable wake row.'

def interrupted(h):
    holder=lock(h,'.watcher-down.lock','recovery-lock');beg=time.monotonic()
    rc,out,err=command(h,'fm-watch-checkpoint.sh',['--seconds','1'],tag='checkpoint',FM_WATCHER_CLEANUP_LOCK_BOUND=2)
    elapsed=time.monotonic()-beg;unlock(h,'recovery-lock',holder)
    assert rc==1 and 'recovery state could not be persisted; retaining stale lock evidence' in err,(rc,out,err)
    assert elapsed<6.5 and not (h/'state/.last-watcher-beat').exists() and (h/'state/.watch.lock/pid').exists(),elapsed
    return 'Interrupted real startup returned failure in %.2fs (1s checkpoint plus 2s cleanup, below the 5s kill grace), retained the identity-bound lock, and never published a beacon.'%elapsed

def stalled(h,mode):
    kw=dict(FM_GUARD_GRACE=5,FM_WATCHER_STALL_BOUND=12,FM_WATCHER_CLEANUP_LOCK_BOUND=30,FM_ARM_ATTACH_POLL='.1')
    owner=start(h,[str(ROOT/'bin/fm-watch-arm.sh')],'owned',**kw)
    waitfor(lambda:'watcher: started' in read(h/'owned.out'),35)
    observer=None
    if mode=='attached':
        observer=start(h,[str(ROOT/'bin/fm-watch-arm.sh')],'attached',**kw)
        waitfor(lambda:'watcher: attached' in read(h/'attached.out'))
    delivery=lock(h,'.watch-deliveries.lock','delivery-lock')
    (h/'state/demo.status').write_text('done: live stalled cleanup preserves this wake\n')
    capture=next(h/'state'/p.name for p in (h/'state').glob('.watch-arm-output.*'))
    waitfor(lambda:'signal:' in read(capture),20)
    holder=lock(h,'.watcher-down.lock','recovery-lock')
    unlock(h,'delivery-lock',delivery)
    waitfor(lambda:'signal:' in read(h/'state/.watch-deliveries.log'))
    queue=read(h/'state/.wake-queue');assert 'demo.status' in queue
    target=observer or owner;rc=target.wait(timeout=40)
    if observer:owner.wait(timeout=12)
    unlock(h,'recovery-lock',holder)
    out=read(h/(mode+'.out'));assert rc==1 and out.count('signal: ')==1 and 'watcher: FAILED' in out,(rc,out)
    assert read(h/'state/.wake-queue')==queue
    return 'The real %s arm returned nonzero for a watcher stalled on the recovery lock, printed the already-delivered signal exactly once, and retained the durable queue byte for byte.'%mode

if __name__=='__main__':
 try:
    scenario('live-quiet-and-empty-recovery',quiet)
    scenario('live-durable-recovery-ack',recovery)
    scenario('live-checkpoint-signal',signal_checkpoint)
    scenario('live-interrupted-startup',interrupted)
    scenario('live-owned-stall',lambda h:stalled(h,'owned'))
    scenario('live-attached-stall',lambda h:stalled(h,'attached'))
 finally:
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError:pass
    time.sleep(.5)
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        try:p.wait(timeout=3)
        except sp.TimeoutExpired:pass
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    for h in homes:shutil.rmtree(h)
