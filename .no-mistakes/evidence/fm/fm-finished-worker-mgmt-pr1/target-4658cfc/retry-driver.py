import os, sys, subprocess, time, signal, shutil, json, stat
from pathlib import Path
ROOT=Path.cwd()
E=Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY/target-4658cfc')
BASE=ROOT/'.test-validation/live'; BASE.mkdir(exist_ok=True)
TOOLS=BASE/'tools'; TOOLS.mkdir(exist_ok=True)
# Only standard tools are available. No live fleet, forge, quota, or harness tool is reachable.
for name in 'bash sh env awk sed grep tr cut head tail wc sort uniq cat date uname sysctl jq python3 dirname basename mkdir mktemp rm rmdir mv cp chmod touch stat ps kill sleep readlink realpath find xargs cksum dd ln tee timeout gtimeout perl id hostname seq od expr which git true false printf stty'.split():
    resolved=shutil.which(name)
    if resolved and not (TOOLS/name).exists(): (TOOLS/name).symlink_to(resolved)
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith(('FM_','TASKS_AXI_','HERDR_','REX_','ORCA_')) or k in ('BASH_ENV','TMUX','TMUX_PANE'): ENV.pop(k,None)
ENV.update(PATH=str(TOOLS), TMPDIR=str(BASE), FM_TEST_SEAM='1')
children=[]; results=[]; transcript=(E/'live-retry.txt').open('w',buffering=1)
def note(msg):
    transcript.write(time.strftime('%H:%M:%S')+' '+msg+'\n'); print(msg,flush=True)
def run(args,env=None,timeout=120,check=True):
    p=subprocess.Popen([str(x) for x in args],env=env or ENV,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(p)
    try: out,err=p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL); out,err=p.communicate(); raise RuntimeError('timeout: '+str(args))
    if check and p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}: {err[-1500:]}')
    return p.returncode,out,err

def home(name):
    h=BASE/name
    run([ROOT/'bin/fm-lab-home.sh','create',h])
    (h/'user').mkdir();(h/'config').mkdir(exist_ok=True)
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (h/'load').write_text('300 0 0\n')
    e=ENV.copy(); e.update(FM_HOME=str(h),HOME=str(h/'user'),XDG_CONFIG_HOME=str(h/'user'),CLAUDE_CONFIG_DIR=str(h/'user'),FM_LOAD_FILE=str(h/'load'))
    return h,e

def savedoc(path,label):
    dest=E/(label+'.json');shutil.copyfile(path,dest);return json.loads(dest.read_text())
def waitfor(pred,seconds,what):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if pred(): return
        time.sleep(.15)
    raise RuntimeError('timed out waiting for '+what)
def doc(p):
    try:return json.loads(p.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}
def stop(p):
    if p.poll() is None:
        try: os.killpg(p.pid,signal.SIGTERM)
        except (ProcessLookupError,PermissionError):
            if p.poll() is None: p.terminate()
        try:p.wait(12)
        except subprocess.TimeoutExpired:
            try: os.killpg(p.pid,signal.SIGKILL)
            except (ProcessLookupError,PermissionError):
                if p.poll() is None:p.kill()
            p.wait(15)
    try:os.killpg(p.pid,signal.SIGKILL)
    except (ProcessLookupError,PermissionError):pass

def scenario(name,fn):
    try:
        fn();result='pass';reason='Real local commands in a marked disposable home; synthetic load and task state.'
    except Exception as exc:
        result='fail';reason=str(exc);note('FAIL '+name+': '+reason)
    results.append(dict(name=name,result=result,live=True,evidence=str(E/'live-retry.txt'),reason=reason))
    (E/'live-retry-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')

def locks():
    h,e=home('locks'); lock=h/'state/.fleet-snapshot.lock'
    out=(E/'snapshot-first.json').open('w');err=(E/'snapshot-first.stderr').open('w')
    p=subprocess.Popen([str(ROOT/'bin/fm-fleet-snapshot.sh'),'--json'],env=e,stdout=out,stderr=err,start_new_session=True);children.append(p)
    waitfor(lambda:lock.exists() or p.poll() is not None,40,'first snapshot lock')
    assert lock.exists(), 'snapshot completed before overlap could be driven'
    os.kill(p.pid,signal.SIGSTOP)
    e2=e.copy();e2['FM_SNAPSHOT_SINGLE_FLIGHT_WAIT']='1'
    rc,txt,errtxt=run([ROOT/'bin/fm-fleet-snapshot.sh','--secondmate-home-summary'],e2,check=False)
    note(f'Concurrent full snapshot: exit={rc}, stdout={txt!r}, stderr={errtxt.strip()}')
    assert rc==75 and not txt and 'already running' in errtxt
    rc,txt,_=run([ROOT/'bin/fm-fleet-snapshot.sh','--contribution-input'],e)
    (E/'contribution-during-full-snapshot.json').write_text(txt)
    note(f'Cheap contribution read while full snapshot is stopped: exit={rc}, nonempty={bool(txt)}')
    assert txt
    os.kill(p.pid,signal.SIGCONT);assert p.wait(120)==0
    out.close();err.close()
    assert not lock.exists(), 'normal exit left snapshot lock behind'
    assert doc(E/'snapshot-first.json')['schema']=='fm-fleet-snapshot.v1'
    note('First real snapshot resumed, printed valid JSON, and released its lock.')
    # Actual second full snapshot waits for a stopped real holder, then completes after it resumes.
    out=(E/'snapshot-holder.json').open('w')
    p=subprocess.Popen([str(ROOT/'bin/fm-fleet-snapshot.sh'),'--json'],env=e,stdout=out,stderr=subprocess.DEVNULL,start_new_session=True);children.append(p)
    waitfor(lambda:lock.exists() or p.poll() is not None,40,'second snapshot lock');assert lock.exists()
    os.kill(p.pid,signal.SIGSTOP)
    out2=(E/'snapshot-waiter.json').open('w')
    q=subprocess.Popen([str(ROOT/'bin/fm-fleet-snapshot.sh'),'--json'],env=e,stdout=out2,stderr=subprocess.DEVNULL,start_new_session=True);children.append(q)
    time.sleep(3);assert q.poll() is None
    os.kill(p.pid,signal.SIGCONT);assert p.wait(120)==0;assert q.wait(120)==0
    out.close();out2.close();assert not lock.exists()
    note('Second real snapshot waited while the holder was stopped; both completed after resume with no lock left.')

def heartbeat():
    h,e=home('heartbeat');ledger=h/'state/heartbeat.json'
    e['FM_HEARTBEAT_CYCLE_SECS']='100'
    (h/'load').write_text('200 0 0\n')
    run([ROOT/'bin/fm-heartbeat.sh','--write'],e)
    calm=savedoc(ledger,'heartbeat-at-threshold');assert calm['throttled'] is False
    (h/'load').write_text('300 0 0\n')
    run([ROOT/'bin/fm-heartbeat.sh','--write'],e)
    hot=savedoc(ledger,'heartbeat-hot');assert hot['throttled'] is True and hot['snapshot']['ok'] is True
    assert hot['stale_after_secs']==calm['stale_after_secs']+300
    note(f'Real snapshot-backed heartbeat: load 200 bound={calm["stale_after_secs"]}, load 300 bound={hot["stale_after_secs"]}, throttled={hot["throttled"]}.')
    old=ledger.read_bytes();run([ROOT/'bin/fm-heartbeat.sh','--write'],e)
    assert ledger.read_bytes()==old;note('Repeated hot launch inside skip window preserved the published ledger byte-for-byte.')
    # Inject a prior publication launch, leaving the real collection and publish path intact.
    hot['generated_epoch']=int(time.time())-399;ledger.write_text(json.dumps(hot))
    run([ROOT/'bin/fm-heartbeat.sh','--write'],e)
    due=savedoc(ledger,'heartbeat-due-with-jitter');assert due['generated_epoch']>hot['generated_epoch']
    note('Hot heartbeat one second short of the 400-second interval published again; no doubled skip gap.')
    (h/'load').write_text('10 0 0\n');e['FM_HEARTBEAT_LOAD_FACTOR']='4'
    # Force a first publication while preserving calm load, to exercise the scheduling-factor contract.
    ledger.unlink();run([ROOT/'bin/fm-heartbeat.sh','--write'],e)
    crossing=savedoc(ledger,'heartbeat-calm-probe-hot-launch');assert crossing['throttled'] is True and crossing['stale_after_secs']==hot['stale_after_secs']
    note('Watcher-passed factor 4 with a calm load file still published the extended stale bound.')
    del e['FM_HEARTBEAT_LOAD_FACTOR'];run([ROOT/'bin/fm-heartbeat.sh','--write'],e)
    recovered=savedoc(ledger,'heartbeat-calm-recovered');assert recovered['throttled'] is False and recovered['stale_after_secs']==calm['stale_after_secs']
    note('Calm direct launch resumed publication immediately and restored the ordinary bound.')

def watcher_start(h,e,**options):
    e=e.copy();e.update(FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WATCH_MANAGED_HOLD='1',FM_HEARTBEAT_LEDGER_IDLE_SECS='10',FM_HEARTBEAT_LEDGER_JITTER='0',FM_HOME_SUMMARY_INTERVAL='8',FM_HOME_SUMMARY_JITTER='0')
    e.update(options)
    out=(E/(h.name+'-watch.out')).open('w');err=(E/(h.name+'-watch.err')).open('w')
    p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=e,stdout=out,stderr=err,start_new_session=True);children.append(p)
    return p,out,err

def ticker():
    h,e=home('ticker');ledger=h/'state/heartbeat.json'
    p,out,err=watcher_start(h,e)
    try:
        waitfor(lambda:bool(doc(ledger).get('published_epoch')),100,'first real heartbeat')
        first=savedoc(ledger,'ticker-first');note(f'Watcher first publication: generated={first["generated_epoch"]}, published={first["published_epoch"]}, bound={first["stale_after_secs"]}.')
        run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_append check lab-change "synthetic change under load"','_',ROOT],e)
        time.sleep(5);assert doc(ledger)['generated_epoch']==first['generated_epoch']
        note('Injected a durable wake under load; no early heartbeat publication followed.')
        waitfor(lambda:doc(ledger).get('generated_epoch',0)>first['generated_epoch'],110,'throttled ticker publication')
        second=savedoc(ledger,'ticker-second');gap=second['generated_epoch']-first['generated_epoch']
        assert gap>=39 and second['published_epoch']-first['published_epoch']<first['stale_after_secs']
        note(f'Real watcher with base idle 10s and load 300 published again after {gap}s; prior bound covered the gap.')
        (h/'load').write_text('10 0 0\n')
        run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_append check lab-calm "synthetic change after load fell"','_',ROOT],e)
        waitfor(lambda:doc(ledger).get('generated_epoch',0)>second['generated_epoch'],70,'calm wake publication')
        third=savedoc(ledger,'ticker-calm');assert third['throttled'] is False
        note(f'Load fell and a durable wake triggered calm publication; generated gap={third["generated_epoch"]-second["generated_epoch"]}s.')
    finally:stop(p);out.close();err.close()

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
        assert (h/'state/.last-watcher-beat').stat().st_mtime_ns>beat
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
        p,outf,errf=watcher_start(h,e,FM_HEARTBEAT_LEDGER_IDLE_SECS='15',FM_HOME_SUMMARY_INTERVAL='999999')
        seen={};starts=[];deadline=time.monotonic()+300
        try:
            while time.monotonic()<deadline and len(starts)<3:
                for work in (h/'state').glob('.heartbeat-work.*'):
                    if work.name not in seen:
                        seen[work.name]=time.time();starts.append(time.time());note('Observed real heartbeat collection attempt at '+str(round(starts[-1],3)))
                assert p.poll() is None,'watcher exited during failed-publication retry observation'
                time.sleep(.1)
            assert len(starts)>=3, 'fewer than three real collection attempts were observed'
            gaps=[round(b-a,2) for a,b in zip(starts,starts[1:])]
            assert all(gap>=59 for gap in gaps),f'publication failure caused a retry storm instead of 60-second pacing: {gaps}'
            assert doc(ledger)['generated_epoch']==old
            (E/'failed-publication-attempts.json').write_text(json.dumps(dict(starts=starts,gaps=gaps,configured_base=15,loaded_interval=60),indent=2)+'\n')
            note(f'Failed publication retries kept loaded interval 60s; actual collection gaps={gaps}; old ledger remained intact.')
        finally:stop(p);outf.close();errf.close()
    finally:os.chflags(ledger,0)

def stateless():
    h=BASE/'stateless'
    for part in ['data','config','projects','user']: (h/part).mkdir(parents=True,exist_ok=True)
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    e=ENV.copy();e.update(FM_HOME=str(h),HOME=str(h/'user'),CLAUDE_CONFIG_DIR=str(h/'user'))
    for mode, schema in [('json','fm-fleet-snapshot.v1'),('secondmate-home-summary','fm-secondmate-home-summary.v1')]:
        rc,txt,err=run([ROOT/'bin/fm-fleet-snapshot.sh','--'+mode],e)
        (E/('stateless-'+mode+'.json')).write_text(txt)
        assert json.loads(txt)['schema']==schema and not (h/'state').exists()
        note('Real snapshot --'+mode+' returned valid JSON and preserved absent state/.')

try:
    scenario('Local watcher retries filesystem-rejected heartbeat publications at loaded spacing without a storm',failed_publish)
finally:
    for p in children: stop(p)
    for ledger in BASE.glob('*/state/heartbeat.json'):
        try: os.chflags(ledger,0)
        except OSError: pass
    note('All driver-owned process groups stopped; disposable homes removed.')
    shutil.rmtree(BASE);transcript.close()
sys.exit(any(r['result']!='pass' for r in results))
