from pathlib import Path
source=Path('.gate-tests/live-monitoring.py').read_text().split("if __name__=='__main__':")[0]
source=source.replace("BASE=ROOT/'.gate-tests/live'", "BASE=ROOT/'.gate-tests/live-rearm'").replace('live-monitoring.txt','live-rearm-rerun.txt').replace('live-scenarios.json','live-rearm-rerun-scenarios.json')
exec(compile(source,'live-monitoring-shared','exec'),globals())
def rearm():
    h,e=home('rearm');ledger=h/'state/heartbeat.json'
    direct=e.copy();direct['FM_HEARTBEAT_CYCLE_SECS']='30'
    run([ROOT/'bin/fm-heartbeat.sh','--write'],direct)
    previous=doc(ledger);previous['generated_epoch']=int(time.time())-60
    ledger.write_text(json.dumps(previous));savedoc(ledger,'rearm-seeded-publication')
    started=time.time();p,out,err=watcher_start(h,e,FM_HOME_SUMMARY_INTERVAL='999999',FM_HEARTBEAT_LEDGER_IDLE_SECS='30')
    try:
        time.sleep(5)
        assert doc(ledger)['generated_epoch']==previous['generated_epoch'],'immediate re-arm unexpectedly rewrote the throttled ledger'
        note('A real watcher re-arm skipped its immediate publication with a 60-second-old launch in a 120-second loaded cycle.')
        waitfor(lambda:doc(ledger).get('generated_epoch',0)>previous['generated_epoch'],150,'publication anchored to prior launch')
        current=savedoc(ledger,'rearm-next-publication')
        gap=current['generated_epoch']-previous['generated_epoch'];elapsed=round(time.time()-started,2)
        note(f'Rearmed real watcher: next generated_epoch gap={gap}s; observed publication after {elapsed}s; prior stale bound={previous["stale_after_secs"]}s.')
        assert gap<=150,'re-arm reset a full loaded interval rather than anchoring to the prior publication'
        assert current['published_epoch']-previous['published_epoch']<previous['stale_after_secs']
    finally:stop(p);out.close();err.close()
try:scenario('Re-arming a real watcher anchors the next loaded publication to the prior ledger after its immediate launch skips',rearm)
finally:
    for p in children:stop(p)
    note('Stopped all re-arm driver process groups; disposable home removed.')
    shutil.rmtree(BASE);transcript.close()
sys.exit(any(r['result']!='pass' for r in results))
