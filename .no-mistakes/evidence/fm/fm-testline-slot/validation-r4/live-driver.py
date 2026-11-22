import os, sys, subprocess as sp, time, json, pathlib, shutil, signal, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M818HHAPS034DN81WTZ21CV8/validation-r4')
D=ROOT/'.validation-r4/live'
D.mkdir(parents=True,exist_ok=True)
BASE=os.environ.copy()
for k in list(BASE):
    if k.startswith('FM_') or k.startswith('TASKS_AXI') or k in ['BASH_ENV','TMUX','REX_SESSION','REX_BLOCK','ORCA_TERMINAL_HANDLE']:
        BASE.pop(k,None)
BASE.update(FM_ROOT_OVERRIDE=str(ROOT),FM_TEST_SEAM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_HEARTBEAT_BIN='/usr/bin/true')
children=[]
results=[]
def emit(label,**fields):
    print(json.dumps(dict(event=label,**fields)),flush=True)
def home(name):
    h=D/name
    for p in ['state','data','config','projects']:(h/p).mkdir(parents=True,exist_ok=True)
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (h/'.fm-secondmate-home').write_text(name+'\n')
    return h

def env(h,**extra):
    return dict(BASE,FM_HOME=str(h),**{k:str(v) for k,v in extra.items()})

def run(args,en,timeout=150):
    start=time.monotonic()
    p=sp.Popen([str(x) for x in args],env=en,stdout=sp.PIPE,stderr=sp.PIPE,text=True,start_new_session=True)
    children.append(p)
    try: out,err=p.communicate(timeout=timeout)
    except sp.TimeoutExpired:
        stop(p);raise
    emit('command',argv=[str(x) for x in args],home=en.get('FM_HOME'),exit=p.returncode,seconds=round(time.monotonic()-start,3),stdout=out,stderr=err)
    return p.returncode,out,err

def launch(args,en,label):
    out=open(E/(label+'.stdout'),'w');err=open(E/(label+'.stderr'),'w')
    p=sp.Popen([str(x) for x in args],env=en,stdout=out,stderr=err,start_new_session=True)
    out.close();err.close();children.append(p);return p

def waitfor(fn,desc,seconds=90):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if fn():return
        time.sleep(.1)
    raise AssertionError('timed out: '+desc)

def stop(p):
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
        try:p.wait(timeout=8)
        except sp.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=8)

def record(h):
    p=h/'state/.home-summary-refresh.backoff'
    return p.read_text() if p.exists() else None

def snapshot(h,name):
    target=E/name
    target.mkdir(exist_ok=True)
    for p in (h/'state').iterdir():
        if p.is_file() and p.name in ['home-summary.json','.home-summary-refresh.backoff','.home-summary-refresh.log']:
            shutil.copyfile(p,target/p.name.lstrip('.'))

W=ROOT/'bin/fm-home-summary-refresh.sh';Q=ROOT/'bin/fm-test-queue.sh'

def queue():
    h=home('queue'); spool=h/'spool';spool.mkdir();load=h/'load';load.write_text('200\n')
    (spool/'config').write_text('slots=2\nload_ceiling=96\n')
    en=env(h,FM_TEST_QUEUE_DIR=spool,FM_TEST_QUEUE_LOAD_FILE=load,FM_TEST_QUEUE_POLL='.1')
    def status():
        rc,out,err=run([Q,'status'],en);assert rc==0;return out
    def job(name):
        return launch([Q,'run','--label',name,'--','bash','-c','printf "%s\\n" "$2" >> "$1/order"; touch "$1/started-$2"; while [ ! -e "$1/release-$2" ]; do sleep .1; done', '_',h,name],en,'queue-'+name)
    a=job('oldest');waitfor(lambda:(h/'started-oldest').exists(),'reserved admission')
    b=job('second');waitfor(lambda:'waiting position=1' in status(),'second in queue')
    c=job('third');waitfor(lambda:'waiting position=2' in status(),'third in queue')
    s=status();assert 'serving=1 waiting=2' in s
    assert not (h/'started-second').exists() and not (h/'started-third').exists()
    (h/'release-oldest').touch();assert a.wait(timeout=60)==0
    waitfor(lambda:(h/'started-second').exists(),'next receipt gets reserved slot at high load')
    assert not (h/'started-third').exists()
    load.write_text('95\n');waitfor(lambda:(h/'started-third').exists(),'second slot below ceiling')
    assert 'serving=2' in status()
    for n in ['second','third']:(h/('release-'+n)).touch()
    assert b.wait(timeout=60)==0 and c.wait(timeout=60)==0
    assert (h/'order').read_text().splitlines()==['oldest','second','third']
    (spool/'config').write_text('slots=1\nload_ceiling=96\n');load.write_text('1000\n')
    rc,out,err=run([Q,'run','--label','single-reserved','--','printf','single slot proceeds\n'],en)
    assert rc==0 and out=='single slot proceeds\n';assert 'serving=0 waiting=0' in status()
    emit('queue-oracle',order=(h/'order').read_text(),high_load=200,ceiling=96,single_slot_load=1000)

def backoff():
    h=home('backoff');en=env(h,FM_NOW=1000)
    assert run([W],en)[0]==0
    before=(h/'state/home-summary.json').read_bytes()
    (h/'data/backlog.md').chmod(0)
    epoch=1000
    for failures,delay in enumerate([30,60,120,240,480,960,1800,1800],1):
        assert run([W,'--best-effort'],env(h,FM_NOW=epoch))[0]==0
        expected=f'failures={failures}\nnext={epoch+delay}\n'
        assert record(h)==expected,(record(h),expected)
        assert (h/'state/home-summary.json').read_bytes()==before
        log=(h/'state/.home-summary-refresh.log').read_bytes()
        assert run([W,'--best-effort'],env(h,FM_NOW=epoch+delay-1))[0]==0
        assert record(h)==expected and (h/'state/.home-summary-refresh.log').read_bytes()==log
        emit('backoff-state',failures=failures,delay=delay,record=record(h),ledger_unchanged=True,early_retry_skipped=True)
        epoch+=delay
    snapshot(h,'backoff-at-cap')
    (h/'data/backlog.md').chmod(0o600)
    assert run([W],env(h,FM_NOW=1000))[0]==0 and record(h) is None
    (h/'data/backlog.md').chmod(0)
    assert run([W,'--best-effort'],env(h,FM_NOW=1001))[0]==0
    assert record(h)=='failures=1\nnext=1031\n'
    (h/'data/backlog.md').chmod(0o600)
    emit('backoff-reset',record=record(h),direct_bypass_published=True)
    snapshot(h,'backoff-reset')

HOOK=D/'faults.sh'
HOOK.write_text('''mkdir() {
 if [ "${HOME_SUMMARY_MODE:-}" = worker ] && [ "${HOME_SUMMARY_LOCK_HELD:-0}" = 1 ] && [ "${FAULT:-}" = hold ] && [ ! -e "$MARKER" ]; then
   builtin printf '%s\\n' "$$" > "$MARKER"
   while [ ! -e "$RELEASE" ]; do sleep .1; done
 fi
 command mkdir "$@"
}
mv() {
 if [ "${HOME_SUMMARY_MODE:-}" = worker ] && [ "${HOME_SUMMARY_LOCK_HELD:-0}" = 1 ] && [ "${FAULT:-}" = replace ] && [ "${@: -1}" = "$LEDGER" ]; then
   builtin printf '%s\\n' "$$" > "$MARKER"
   sleep 120
 fi
 command mv "$@"
}
''')

def contention():
    h=home('contention');(h/'data/backlog.md').chmod(0)
    marker=h/'held';release=h/'release'
    a=launch([W,'--best-effort'],env(h,FM_NOW=1000,FM_HOME_SUMMARY_TIMEOUT=120,BASH_ENV=HOOK,FAULT='hold',MARKER=marker,RELEASE=release),'contention-first')
    waitfor(marker.exists,'first writer lock held')
    f=h/'state/.home-summary-refresh.backoff';f.write_text('failures=2\nnext=900\n')
    assert run([W,'--best-effort'],env(h,FM_NOW=1000,FM_HOME_SUMMARY_IF_IDLE=1))[0]==0
    assert record(h)=='failures=2\nnext=900\n'
    emit('busy-skip',record=record(h))
    f.unlink();stage=h/'state/.home-summary-stage.queued'
    b=launch([W,'--best-effort'],env(h,FM_NOW=1000,FM_HOME_SUMMARY_TIMEOUT=120,FM_HOME_SUMMARY_STAGE_PATH=stage),'contention-second')
    waitfor(lambda:stage.exists() and 'lock-wait' in stage.read_text(),'second writer queued')
    emit('queued-stage',stage=stage.read_text());release.touch()
    assert a.wait(timeout=120)==0 and b.wait(timeout=120)==0
    assert record(h)=='failures=1\nnext=1030\n'
    emit('queued-failure-state',record=record(h),failures=(h/'state/.home-summary-refresh.log').read_text())
    (h/'data/backlog.md').chmod(0o600);snapshot(h,'contention-result')

def deadline():
    h=home('deadline');assert run([W],env(h))[0]==0
    before=(h/'state/home-summary.json').read_bytes();marker=h/'stalled'
    start=time.monotonic()
    a=launch([W,'--best-effort'],env(h,FM_NOW=1000,FM_HOME_SUMMARY_TIMEOUT=30,BASH_ENV=HOOK,FAULT='replace',MARKER=marker),'deadline-writer')
    waitfor(marker.exists,'real producer and validator reach replacement',seconds=28)
    assert a.wait(timeout=45)==0
    elapsed=time.monotonic()-start
    assert elapsed<50 and record(h)=='failures=1\nnext=1030\n'
    assert (h/'state/home-summary.json').read_bytes()==before
    assert run([W,'--best-effort'],env(h,FM_NOW=1001))[0]==0
    assert record(h)=='failures=1\nnext=1030\n'
    emit('deadline-state',elapsed=round(elapsed,3),record=record(h),ledger_unchanged=True,log=(h/'state/.home-summary-refresh.log').read_text())
    assert run([W],env(h,FM_NOW=1001))[0]==0 and record(h) is None
    snapshot(h,'deadline-recovered')

def interruption():
    h=home('interruption');assert run([W],env(h,FM_SNAPSHOT_NOW='2026-11-22T10:00:00Z'))[0]==0
    prior=(h/'state/home-summary.json').read_bytes();marker=h/'stalled'
    a=launch([W],env(h,FM_SNAPSHOT_NOW='2026-11-22T10:01:00Z',FM_HOME_SUMMARY_TIMEOUT=120,BASH_ENV=HOOK,FAULT='replace',MARKER=marker),'interrupted-writer')
    waitfor(marker.exists,'old writer reaches replacement')
    worker=int(marker.read_text());pg=os.getpgid(worker);assert pg!=os.getpgrp() and pg!=a.pid
    os.killpg(pg,signal.SIGKILL);old_rc=a.wait(timeout=30);assert old_rc!=0
    assert (h/'state/home-summary.json').read_bytes()==prior
    assert run([W],env(h,FM_SNAPSHOT_NOW='2026-11-22T10:02:00Z'))[0]==0
    new=(h/'state/home-summary.json').read_bytes();assert json.loads(new)['generated']=='2026-11-22T10:02:00Z'
    time.sleep(3);assert (h/'state/home-summary.json').read_bytes()==new
    emit('interrupted-publication',old_exit=old_rc,old_worker=worker,killed_group=pg,prior_preserved=True,replacement=json.loads(new))
    snapshot(h,'interruption-replacement')

def watcher():
    h=home('watcher');marker=h/'stalled'
    p=launch([ROOT/'bin/fm-watch.sh'],env(h,FM_POLL=1,FM_HOME_SUMMARY_INTERVAL=1,FM_HOME_SUMMARY_JITTER=0,FM_HOME_SUMMARY_TIMEOUT=60,FM_SIGNAL_GRACE=0,FM_CHECK_INTERVAL=9999999,FM_HEARTBEAT=9999999,BASH_ENV=HOOK,FAULT='replace',MARKER=marker),'watcher')
    waitfor(marker.exists,'watcher launches real publisher stalled at replacement')
    beat=h/'state/.last-watcher-beat';waitfor(beat.exists,'watcher beacon')
    stamps=[beat.stat().st_mtime_ns]
    for i in range(3):
        waitfor(lambda:beat.stat().st_mtime_ns!=stamps[-1],'watcher beacon advances',seconds=20)
        stamps.append(beat.stat().st_mtime_ns)
    assert p.poll() is None
    emit('watcher-beacons',stamps=stamps,publisher_lock_present=(h/'state/.home-summary-refresh.lock').exists(),publisher_still_waiting=True)
    worker=int(marker.read_text());pg=os.getpgid(worker)
    stop(p)
    try:os.killpg(pg,signal.SIGKILL)
    except ProcessLookupError:pass
    emit('watcher-stopped',exit=p.returncode)

try:
    for name,fn in [('queue',queue),('backoff',backoff),('contention',contention),('deadline',deadline),('interruption',interruption),('watcher',watcher)]:
        try:fn();results.append(dict(name=name,result='pass'))
        except Exception as e:
            traceback.print_exc();results.append(dict(name=name,result='fail',reason=str(e)))
        (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    for p in children:stop(p)
    # Only the disposable fixtures owned by this driver are eligible for cleanup.
    rows=sp.check_output(['ps','-axo','pid=,command='],text=True)
    victims=[]
    for row in rows.splitlines():
        pid_s,_,command=row.strip().partition(' ')
        if str(D) in command and int(pid_s)!=os.getpid():victims.append(int(pid_s))
    for pid in victims:
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
    shutil.rmtree(D)
    emit('cleanup',children=[dict(pid=p.pid,exit=p.poll()) for p in children],fixture_processes_stopped=victims,fixture_removed=not D.exists())
sys.exit(0 if len(results)==6 and all(x['result']=='pass' for x in results) else 1)
