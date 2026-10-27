from live_probe import *
def afk_note(h):
    (h/'config/supervision-host').write_text('claude\n')
    rc,out,err=command(h,'fm-lock.sh',tag='session-lock');assert rc==0,(rc,out,err)
    rc,out,err=command(h,'fm-afk-launch.sh',['enter','--words','live test; merge nothing'],tag='away-before-checkpoint')
    assert rc==0 and 'Away supervision is not running yet:' in out,(rc,out,err)
    assert (h/'state/.afk-contract').exists() and not (h/'state/.watch.lock').exists() and not (h/'state/.supervision-host').exists()
    p=start(h,[str(ROOT/'bin/fm-watch-checkpoint.sh'),'--seconds','5'],'foreground-checkpoint',FM_CODEX_WATCH_CHECKPOINT_AWAY=5)
    waitfor(lambda:(h/'state/.last-watcher-beat').exists(),35)
    rc,out,err=command(h,'fm-afk-launch.sh',['enter','--words','live test refresh; merge nothing'],tag='away-while-supervising')
    assert rc==0 and 'Away supervision is not running yet:' not in out,(rc,out,err)
    assert p.wait(timeout=20)==0
    command(h,'fm-afk-contract.sh',['archive'],tag='archive')
    rc,out,err=command(h,'fm-afk-launch.sh',['enter','--words','quiet test'],tag='quiet-entry',FM_AFK_MODE='quiet')
    assert rc==0 and 'Away supervision is not running yet:' not in out,(rc,out,err)
    return 'Real Codex detection: away entry without a watcher prints the foreground-checkpoint warning and creates no cycle; a healthy real foreground checkpoint suppresses it; quiet entry does not print the away warning.'
try:scenario('live-codex-away-checkpoint-note',afk_note)
finally:
    for p in processes:
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError:pass
        try:p.wait(timeout=8)
        except sp.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    (E/'live-afk-results.json').write_text(json.dumps(results,indent=2)+'\n')
    for h in homes:shutil.rmtree(h)
