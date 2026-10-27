from live_probe import *
def interrupted_takeover(h):
    owner=start(h,[str(ROOT/'bin/fm-watch-arm.sh')],'owner',FM_WATCHER_CLEANUP_LOCK_BOUND=2)
    waitfor(lambda:'watcher: started' in read(h/'owner.out'),35)
    watcher=int(read(h/'state/.watch.lock/pid'))
    holder=lock(h,'.watcher-down.lock','snapshot-barrier')
    taker=start(h,[str(ROOT/'bin/fm-watch-arm.sh'),'--take-over',str(owner.pid)],'takeover',FM_WATCHER_CLEANUP_LOCK_BOUND=2)
    waitfor(lambda:read(h/'state/.wake-queue.lock/pid').strip()==str(taker.pid))
    (h/'observation.out').write_text('original_watcher_pid=%d\noriginal_arm_pid=%d\ninterrupted_taker_pid=%d\nqueue_lock_owner_at_interruption=%s\n'%(watcher,owner.pid,taker.pid,read(h/'state/.wake-queue.lock/pid').strip()))
    time.sleep(1) # Let the bounded lock helper start before pausing its caller.
    os.kill(taker.pid,signal.SIGSTOP)
    unlock(h,'snapshot-barrier',holder)
    waitfor(lambda:read(h/'state/.watcher-down.lock/pid').strip()==str(taker.pid))
    (h/'observation.out').open('a').write('recovery_lock_owner_after_external_release='+read(h/'state/.watcher-down.lock/pid').strip()+'\n')
    os.kill(taker.pid,signal.SIGTERM);os.kill(taker.pid,signal.SIGCONT)
    rc=taker.wait(timeout=20);owner_rc=owner.wait(timeout=15)
    err=read(h/'takeover.err');(h/'observation.out').open('a').write('taker_exit=%d\noriginal_arm_exit=%d\nretained_watcher_lock=%s\n'%(rc,owner_rc,read(h/'state/.watch.lock/pid').strip()))
    assert 'recovery state could not be persisted' not in err, 'The interrupted take-over arm stopped the original watcher while still owning the handed-off recovery lock; it emitted a cleanup-failure diagnostic after the external recovery-lock holder had released. taker exit=%s; original arm exit=%s'%(rc,owner_rc)
    return 'Interrupted takeover preserved its predecessor cycle without a cleanup failure.'
try:scenario('live-interrupted-takeover',interrupted_takeover)
finally:
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError:pass
        try:p.wait(timeout=5)
        except sp.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    (E/'live-takeover-results.json').write_text(json.dumps(results,indent=2)+'\n')
    for h in homes:shutil.rmtree(h)
