# Reuse the disposable-home driver, with separate evidence outputs.
import runpy, os, sys, time, json, stat, shutil
from pathlib import Path
source=Path('.gate-tests/live-monitoring.py').read_text().split("if __name__=='__main__':")[0]
source=source.replace("BASE=ROOT/'.gate-tests/live'", "BASE=ROOT/'.gate-tests/live-secondary'")
source=source.replace("live-monitoring.txt", "live-secondary-rerun.txt").replace("live-scenarios.json", "live-secondary-rerun-scenarios.json")
exec(compile(source,'live-monitoring-shared','exec'),globals())

def summaries():
    h,e=home('summary');ledger=h/'state/home-summary.json'
    p,out,err=watcher_start(h,e,FM_HOME_SUMMARY_INTERVAL='8',FM_HEARTBEAT_LEDGER_IDLE_SECS='300')
    try:
        waitfor(lambda:bool(doc(ledger).get('generated_epoch')),100,'first real home summary')
        first=savedoc(ledger,'summary-first');beat=(h/'state/.last-watcher-beat').stat().st_mtime_ns
        note(f'Watcher published real home summary: generated={first["generated_epoch"]}, load=300, base interval=8s, loaded interval=32s.')
        # A synthetic metadata/status record is the user-visible status trigger; no terminal exists or is driven.
        (h/'state/lab-task.meta').write_text('kind=ship\nharness=codex\nbackend=tmux\nwindow=fm-lab:absent\n')
        (h/'state/lab-task.status').write_text('working: synthetic status update\n')
        time.sleep(4)
        assert doc(ledger)['generated_epoch']==first['generated_epoch'], 'status signal bypassed the hot minimum gap'
        note('A synthetic task/status append did not bypass the loaded summary gap.')
        waitfor(lambda:doc(ledger).get('generated_epoch',0)>first['generated_epoch'],110,'loaded summary idle due')
        second=savedoc(ledger,'summary-second');gap=second['generated_epoch']-first['generated_epoch']
        assert gap>=31, f'loaded summary gap {gap}s was shorter than the 32s contract'
        waitfor(lambda:(h/'state/.last-watcher-beat').stat().st_mtime_ns>beat,100,'next liveness beat after summary publication')
        note(f'Real home-summary producer ran again after {gap}s; watcher liveness beat advanced during throttling.')
        # Status activity is coalesced under load but returns to prompt refresh when calm.
        (h/'load').write_text('10 0 0\n')
        with (h/'state/lab-task.status').open('a') as f:f.write('working: calm synthetic status update\n')
        waitfor(lambda:doc(ledger).get('generated_epoch',0)>second['generated_epoch'],80,'calm summary status refresh')
        third=savedoc(ledger,'summary-calm');note(f'Calm status append published a new real summary after {third["generated_epoch"]-second["generated_epoch"]}s.')
    finally:stop(p);out.close();err.close()

def cap():
    h,e=home('open-work');state=h/'state';now=int(time.time())
    (state/'dispatch-log.tsv').write_text(f'2026-11-26T00:00:00Z\t{now}\treceived\tlab-goal\tsummary=synthetic open goal\n')
    (state/'.last-heartbeat').touch();os.utime(state/'.last-heartbeat',(now-901,now-901))
    (state/'.heartbeat-streak').write_text('3\n')
    e.update(FM_WATCH_ONCE='1',FM_WATCH_NOW=str(now),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='600',FM_HEARTBEAT_LEDGER_IDLE_SECS='300')
    rc,out,err=run([ROOT/'bin/fm-watch.sh'],e,timeout=100)
    (E/'open-work-wake.txt').write_text(out)
    queue=(state/'.wake-queue').read_text()
    (E/'open-work-wake-queue.tsv').write_text(queue)
    note(f'One real watcher cycle at load 300, heartbeat age 901s and open goal: exit={rc}, stdout={out.strip()!r}, durable wake={queue.strip()!r}')
    assert 'heartbeat' in out and any(line.split('\t')[2:4]==['heartbeat','heartbeat'] for line in queue.splitlines())

def failed_publish():
    h,e=home('failed-publication');ledger=h/'state/heartbeat.json'
    old=int(time.time())-120
    ledger.write_text(json.dumps(dict(schema='fm-heartbeat.v1',generated_epoch=old,published_epoch=old,throttled=True,stale_after_secs=1000)))
    # Refuse atomic replacement at the filesystem boundary while leaving valid old JSON readable.
    os.chflags(ledger,stat.UF_IMMUTABLE)
    try:
        direct=e.copy();direct['FM_HEARTBEAT_CYCLE_SECS']='3'
        rc,out,err=run([ROOT/'bin/fm-heartbeat.sh','--write'],direct,timeout=100,check=False)
        (E/'failed-publication-diagnostic.txt').write_text(err)
        assert 'could not write' in err and doc(ledger)['generated_epoch']==old
        note(f'Filesystem-protected ledger rejected a real heartbeat publication: {err.strip()}')
        p,outf,errf=watcher_start(h,e,FM_HEARTBEAT_LEDGER_IDLE_SECS='5',FM_HOME_SUMMARY_INTERVAL='999999')
        seen={};starts=[];deadline=time.monotonic()+70
        try:
            while time.monotonic()<deadline and len(starts)<3:
                for work in (h/'state').glob('.heartbeat-work.*'):
                    if work.name not in seen:
                        seen[work.name]=time.time();starts.append(time.time());note('Observed real heartbeat collection attempt at '+str(round(starts[-1],3)))
                assert p.poll() is None,'watcher exited during failed-publication retry observation'
                time.sleep(.1)
            assert len(starts)>=3, 'fewer than three real collection attempts were observed'
            gaps=[round(b-a,2) for a,b in zip(starts,starts[1:])]
            assert all(gap>=19 for gap in gaps),f'publication failure caused a retry storm instead of 20-second pacing: {gaps}'
            assert doc(ledger)['generated_epoch']==old
            (E/'failed-publication-attempts.json').write_text(json.dumps(dict(starts=starts,gaps=gaps,configured_base=5,loaded_interval=20),indent=2)+'\n')
            note(f'Failed publication retries kept loaded interval 20s; actual collection gaps={gaps}; old ledger remained intact.')
        finally:stop(p);outf.close();errf.close()
    finally:os.chflags(ledger,0)

try:
    scenario('Real home summaries coalesce synthetic status activity above load 200, keep liveness beats, and resume calm publication',summaries)
finally:
    for p in children:stop(p)
    # Safety cleanup if a scenario failed while a protected ledger was present.
    for ledger in BASE.glob('*/state/heartbeat.json'):
        try:os.chflags(ledger,0)
        except OSError:pass
    note('All secondary driver-owned process groups stopped; disposable homes removed.')
    shutil.rmtree(BASE);transcript.close()
sys.exit(any(r['result']!='pass' for r in results))
