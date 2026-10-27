from live_probe import *
def prep(h):
    (h/'config/supervision-host').touch()
    rc,out,err=command(h,'fm-lock.sh',tag='session-lock')
    assert rc==0,(rc,out,err)
    rc,out,err=command(h,'fm-lock.sh',['status'],tag='session-status')
    assert 'held by live harness' in out,(rc,out,err)
def host(h, tag='host', **kw):
    return start(h,[str(ROOT/'bin/fm-supervision-host.sh'),'park'],tag,FM_SUPERVISION_HOST_PRIMARY='codex',FM_SUPERVISION_HOST_PARK_SECONDS='120',FM_WATCHER_CLEANUP_LOCK_BOUND='8',FM_ARM_CONFIRM_TIMEOUT='30',**kw)
def acknowledge(h):
    import re
    rc,out,err=command(h,'fm-wake-drain.sh',tag='drain');assert rc==0
    m=re.search(r'--ack-through (\d+) --recovery-generation ([\w.-]+)',err);assert m,(out,err)
    rc,out,err=command(h,'fm-wake-drain.sh',['--ack-through',m[1],'--recovery-generation',m[2]],tag='ack');assert rc==0

def successor(h):
    prep(h)
    for cycle in (1,2):
        p=host(h,'host'+str(cycle));waitfor(lambda:'watcher:' in read(h/('host'+str(cycle)+'.out')),45)
        waitfor(lambda:(h/'state/.last-watcher-beat').exists())
        with open(h/'state/demo.status','a') as f:f.write('done [at=%d]: live attended cycle %d\n'%(cycle,cycle))
        rc=p.wait(timeout=45);out=read(h/('host'+str(cycle)+'.out'));assert rc==0 and out.count('signal: ')==1,(rc,out,read(h/('host'+str(cycle)+'.err')))
        waitfor(lambda:(h/'state/.supervision-host-left').exists(),15)
        watcher=int(read(h/'state/.watch.lock/pid'));os.kill(watcher,0)
        left=read(h/'state/.supervision-host-left');(h/('successor'+str(cycle)+'.out')).write_text('retained_live_watcher='+str(watcher)+'\n'+left)
        acknowledge(h);assert not read(h/'state/.wake-queue')
        assert read(h/'state/.watch.lock/pid').strip()==str(watcher)
    rc,out,err=command(h,'fm-watch-arm.sh',['--stop'],tag='stop');assert rc==0,(rc,out,err)
    return 'Two attended wakes from a real Codex primary reached main exactly once, each retained a live successor across acknowledgement, and the second host took over the previous cycle. Explicit stop succeeded.'

def quiet_host(h):
    prep(h)
    rc,out,err=command(h,'fm-watch-checkpoint.sh',['--seconds','3'],tag='checkpoint',FM_SUPERVISION_HOST_PRIMARY='codex')
    assert rc==0 and 'checkpoint: no actionable wake within 3s' in out and not (h/'state/.watch.lock/pid').exists(),(rc,out,err)
    assert '\tboundary\t' in read(h/'state/.supervision-host.log')
    return 'The opted-in real Codex primary ran a host checkpoint to its park boundary, returned quiet exit 0, and left no watcher singleton.'

def predecessor(h,delivered):
    prep(h);locks=[]
    if not delivered:locks.append(('recovery-lock',lock(h,'.watcher-down.lock','recovery-lock')))
    p=host(h,'predecessor')
    if delivered:
        waitfor(lambda:'watcher: started' in read(h/'predecessor.out'),45)
        locks.append(('delivery-lock',lock(h,'.watch-deliveries.lock','delivery-lock')))
        (h/'state/demo.status').write_text('done: live predecessor delivered wake\n')
        def capture():
            return any('signal:' in read(f) for f in (h/'state').glob('.watch-arm-output.*'))
        waitfor(capture,25)
        locks.append(('recovery-lock',lock(h,'.watcher-down.lock','recovery-lock')))
        unlock(h,'delivery-lock',locks.pop(0)[1])
        waitfor(lambda:'signal:' in read(h/'state/.watch-deliveries.log'))
    else:
        waitfor(lambda:bool(read(h/'state/.watch.lock/pid-identity')),35)
        assert not (h/'state/.last-watcher-beat').exists()
    identity=read(h/'state/.watch.lock/pid-identity');watcher=read(h/'state/.watch.lock/pid')
    p.kill();p.wait(timeout=5)
    replacement=host(h,'replacement');rc=replacement.wait(timeout=40)
    out=read(h/'replacement.out')+read(h/'replacement.err')
    assert rc==1 and 'recovery state could not be persisted; retaining stale lock evidence' in out,(rc,out)
    if delivered:assert out.count('signal: ')==1,out
    assert read(h/'state/.watch.lock/pid')==watcher and read(h/'state/.watch.lock/pid-identity')==identity
    assert not (h/'state/.supervision-host-left').exists()
    for tag,holder in locks:unlock(h,tag,holder)
    return 'Replacement activation after a real host KILL returned 1, reported forced-cleanup failure, retained the same watcher identity, and '+('surfaced its delivered wake once.' if delivered else 'did not accept interrupted pre-beacon startup as healthy.')

try:
    scenario('live-host-quiet-boundary',quiet_host)
    scenario('live-host-attended-successors',successor)
    scenario('live-host-predecessor-delivery',lambda h:predecessor(h,True))
    scenario('live-host-preconfirmation-retirement',lambda h:predecessor(h,False))
finally:
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError:pass
    time.sleep(1)
    for h in homes:
        # Explicitly retire any detached successor before removing its lab.
        command(h,'fm-watch-arm.sh',['--stop'],tag='final-stop')
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        try:p.wait(timeout=4)
        except sp.TimeoutExpired:pass
    (E/'live-host-results.json').write_text(json.dumps(results,indent=2)+'\n')
    for h in homes:shutil.rmtree(h)
