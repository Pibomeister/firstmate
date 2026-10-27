from live_probe import *
def forced(h):
    holder=lock(h,'.watcher-down.lock','recovery-lock');beg=time.monotonic()
    p=start(h,[str(ROOT/'bin/fm-watch-checkpoint.sh'),'--seconds','3'],'checkpoint',FM_WATCHER_CLEANUP_LOCK_BOUND=8)
    waitfor(lambda:bool(read(h/'state/.watch.lock/pid')))
    watcher=int(read(h/'state/.watch.lock/pid'))
    time.sleep(max(0,4-(time.monotonic()-beg)))
    os.kill(watcher,signal.SIGSTOP)
    rc=p.wait(timeout=20);out=read(h/'checkpoint.out');err=read(h/'checkpoint.err')
    elapsed=time.monotonic()-beg;unlock(h,'recovery-lock',holder)
    assert rc==137 and 'forced KILL ended the checkpoint before clean shutdown' in err,(rc,out,err)
    assert 'checkpoint: no actionable wake' not in out and (h/'state/.watch.lock/pid').exists()
    return 'A real watcher frozen with SIGSTOP during contended shutdown outlasted the kill grace: the real checkpoint returned 137 after %.2fs, printed the forced-KILL diagnostic, and retained stale lock evidence.'%elapsed

def refused(h):
    rc,out,err=command(h,'fm-watch-arm.sh',tag='arm',FM_ARM_CONFIRM_TIMEOUT=5,FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS='5s')
    assert rc==1 and 'watcher: FAILED' in out+err and not (h/'state/.watch.lock/pid').exists(),(rc,out,err)
    return 'A real arm with an unusable startup confirmation budget failed before publishing a singleton, with its typed launch diagnostic.'
try:
    scenario('live-forced-kill-checkpoint',forced)
    scenario('live-startup-refusal',refused)
finally:
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError:pass
        try:p.wait(timeout=5)
        except sp.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL);p.wait()
    (E/'live-additional-results.json').write_text(json.dumps(results,indent=2)+'\n')
    for h in homes:shutil.rmtree(h)
