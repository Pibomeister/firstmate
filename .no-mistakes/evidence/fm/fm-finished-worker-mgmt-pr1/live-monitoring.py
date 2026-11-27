import os, sys, time, json, signal, shutil, subprocess
from pathlib import Path
ROOT=Path.cwd()
E=Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY')
LAB=ROOT/'.test-live-monitoring'
LAB.mkdir(exist_ok=False)
children=[]
results=[]
log=(E/'live-monitoring.log').open('w', buffering=1)
def say(s):
    print(s, flush=True); print(s,file=log,flush=True)
def home(name):
    p=LAB/name
    subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(p)],check=True,capture_output=True)
    (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (p/'.fm-secondmate-home').write_text('synthetic-lab\n')
    return p
def env(p,**extra):
    e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','REX_SESSION','REX_BLOCK','ORCA_TERMINAL_HANDLE')}
    e.update(HOME=str(p),FM_HOME=str(p),XDG_CONFIG_HOME=str(p/'xdg-config'),XDG_DATA_HOME=str(p/'xdg-data'),XDG_CACHE_HOME=str(p/'xdg-cache'),CLAUDE_CONFIG_DIR=str(p/'claude'),FM_TEST_SEAM='1',FM_LOAD_FILE=str(p/'load'),FM_HEARTBEAT_QUOTA_TIMEOUT='1',FM_HEARTBEAT_DISCOVERY_TIMEOUT='10')
    e.update({k:str(v) for k,v in extra.items()})
    return e
def spawn(p,label,script,*args,**extra):
    out=(E/(label+'.out')).open('w'); err=(E/(label+'.err')).open('w')
    c=subprocess.Popen([str(ROOT/'bin'/script),*args],env=env(p,**extra),stdout=out,stderr=err,start_new_session=True)
    children.append((c,out,err)); return c
def stop(c):
    try: os.killpg(c.pid,signal.SIGCONT)
    except ProcessLookupError: pass
    try: os.killpg(c.pid,signal.SIGTERM)
    except ProcessLookupError: pass
    try: c.wait(timeout=12)
    except subprocess.TimeoutExpired:
        os.killpg(c.pid,signal.SIGKILL); c.wait(timeout=10)
def finish(c,label,timeout=150,rc=0):
    try: actual=c.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        stop(c); raise AssertionError(label+' timed out')
    say(f'{label}: exit={actual}')
    assert actual==rc,(label,actual,(E/(label+'.err')).read_text()[-2000:])
    return (E/(label+'.out')).read_text()
def run(p,label,script,*args,rc=0,**extra):
    return finish(spawn(p,label,script,*args,**extra),label,rc=rc)
def waitfor(f,timeout=90):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        v=f()
        if v:return v
        time.sleep(.1)
    raise AssertionError('condition timeout')
def scenario(name,f):
    say('SCENARIO '+name)
    try:f(); results.append(dict(name=name,result='pass',live=True,evidence='live-monitoring.log',reason='Real local CLI on disposable synthetic lab homes.'))
    except Exception as e:
        say('FAIL '+repr(e)); results.append(dict(name=name,result='fail',live=True,evidence='live-monitoring.log',reason=str(e)))
def heartbeat():
    p=home('heartbeat'); load=p/'load'; ledger=p/'state/heartbeat.json'
    epoch=1795194000
    opts=dict(FM_HEARTBEAT_CYCLE_SECS=100,FM_HEARTBEAT_NOW='2026-11-20T17:00:00Z')
    def publish(label,load_value,**kw):
        load.write_text(load_value+' 0 0\n')
        run(p,label,'fm-heartbeat.sh','--write',**dict(opts,**kw))
        d=json.loads(ledger.read_text()); (E/(label+'.json')).write_text(json.dumps(d,indent=2)+'\n')
        say(label+': '+json.dumps({k:d.get(k) for k in ('generated_epoch','throttled','stale_after_secs','snapshot','failure')}))
        assert d['snapshot']['ok'] is True
        return d
    calm=publish('hb-threshold','200.00'); assert calm['throttled'] is False
    hot=publish('hb-hot','200.01'); assert hot['throttled'] is True
    assert hot['stale_after_secs']-calm['stale_after_secs']==300
    before=ledger.read_bytes()
    run(p,'hb-skip','fm-heartbeat.sh','--write',**opts)
    assert ledger.read_bytes()==before
    say('hot immediate repeat: ledger bytes unchanged; no duplicate collection')
    d=dict(hot); d['generated_epoch']=epoch-399; ledger.write_text(json.dumps(d))
    jitter=publish('hb-jitter','300.00'); assert jitter['generated_epoch']==epoch
    calm2=publish('hb-recovered','10.00'); assert calm2['throttled'] is False
    launch=publish('hb-launch-factor','10.00',FM_HEARTBEAT_LOAD_FACTOR=4)
    assert launch['throttled'] is True and launch['stale_after_secs']==hot['stale_after_secs']
    broken=publish('hb-unreadable','not-a-load'); assert broken['throttled'] is False

def snapshots():
    p=home('snapshot'); lock=p/'state/.fleet-snapshot.lock'
    c=spawn(p,'snapshot-holder','fm-fleet-snapshot.sh','--json')
    waitfor(lambda:lock.exists())
    os.kill(c.pid,signal.SIGSTOP)
    say('real snapshot holder stopped after acquiring home lock: '+str(c.pid))
    run(p,'snapshot-refused','fm-fleet-snapshot.sh','--json',rc=75,FM_SNAPSHOT_SINGLE_FLIGHT_WAIT=1)
    assert (E/'snapshot-refused.out').stat().st_size==0
    assert 'already running' in (E/'snapshot-refused.err').read_text()
    run(p,'summary-refused','fm-fleet-snapshot.sh','--secondmate-home-summary',rc=75,FM_SNAPSHOT_SINGLE_FLIGHT_WAIT=1)
    # Cheap reads and another home remain independent of the held full snapshot.
    cheap=json.loads(run(p,'contribution-independent','fm-fleet-snapshot.sh','--contribution-input'))
    assert 'tasks' in cheap
    q=home('other-home'); other=json.loads(run(q,'snapshot-other-home','fm-fleet-snapshot.sh','--json'))
    assert other['schema']=='fm-fleet-snapshot.v1'
    os.kill(c.pid,signal.SIGCONT)
    first=json.loads(finish(c,'snapshot-holder'))
    assert first['schema']=='fm-fleet-snapshot.v1' and not lock.exists()
    say('same-home full reads refused with exit 75; contribution and other-home reads succeeded; normal exit released lock')
    # The real producer dies while owning the lock; the next producer must reclaim it.
    c=spawn(p,'snapshot-crashed','fm-fleet-snapshot.sh','--json')
    waitfor(lambda:lock.exists()); os.killpg(c.pid,signal.SIGKILL); c.wait(timeout=15)
    recovered=json.loads(run(p,'snapshot-reclaimed','fm-fleet-snapshot.sh','--json'))
    assert recovered['schema']=='fm-fleet-snapshot.v1' and not lock.exists()
    say('killed holder left dead ownership; next real producer reclaimed it and released cleanly')

def stateless():
    p=LAB/'stateless'; p.mkdir(); (p/'data').mkdir(); (p/'config').mkdir(); (p/'projects').mkdir()
    for flag,label in [('--json','stateless-json'),('--secondmate-home-summary','stateless-summary')]:
        d=json.loads(run(p,label,'fm-fleet-snapshot.sh',flag))
        assert not (p/'state').exists()
        say(label+': schema='+d['schema']+'; state directory remains absent')

try:
    scenario('Heartbeat follows load threshold, skips duplicate hot reads, tolerates launch jitter, restores calm cadence, and preserves launch-factor freshness',heartbeat)
    scenario('Full snapshots serialize per synthetic home, refuse contention, release normal locks, and recover a killed real holder',snapshots)
    scenario('Read-only JSON and home-summary snapshots preserve a synthetic stateless home',stateless)
finally:
    for c,out,err in children:
        stop(c); out.close(); err.close()
    shutil.rmtree(LAB)
    (E/'live-monitoring-results.json').write_text(json.dumps(results,indent=2)+'\n')
    say('All owned command groups stopped; disposable homes removed.')
    log.close()
sys.exit(0 if all(x['result']=='pass' for x in results) else 1)
