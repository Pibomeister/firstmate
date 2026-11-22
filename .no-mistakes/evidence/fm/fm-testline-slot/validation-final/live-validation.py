import os, sys, time, json, signal, shutil, subprocess, tempfile
from pathlib import Path
ROOT=Path.cwd()
EVID=Path('~/.no-mistakes/evidence/01M818HHAPS034DN81WTZ21CV8/validation-final')
LAB=Path(tempfile.mkdtemp(prefix='live-',dir=ROOT/'.validation-tmp'))
BASE=os.environ.copy()
for k in list(BASE):
    if k.startswith(('FM_', 'TMUX', 'GIT_', 'TASKS_AXI', 'REX_', 'ORCA_')) or k=='BASH_ENV': BASE.pop(k,None)
BASE.update(TMPDIR=str(LAB),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_ROOT_OVERRIDE=str(ROOT),FM_TEST_SEAM='1')
children=[]; results=[]
log=open(EVID/('watcher-retry.log' if len(sys.argv)>1 else 'live-transcript.log'),'w',buffering=1)
def say(s): print(s,file=log,flush=True)
def launch(args,env,name):
    f=open(EVID/(name+'.log'),'w')
    p=subprocess.Popen([str(a) for a in args],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
    children.append((p,f)); return p
def run(args,env,limit=60):
    p=launch(args,env,'command-'+str(len(children)))
    rc=p.wait(timeout=limit); say('$ '+' '.join(str(a) for a in args)+' => '+str(rc)); return rc
def waitfor(fn,what,limit=45):
    end=time.monotonic()+limit
    while time.monotonic()<end:
        if fn(): return
        time.sleep(.15)
    raise AssertionError('timed out: '+what)
def read(p):
    try:return p.read_text()
    except FileNotFoundError:return ''
def stop(p):
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
        try:p.wait(timeout=8)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=8)
def home(name):
    h=LAB/name
    for d in ['state','data','config','projects']: (h/d).mkdir(parents=True,exist_ok=True)
    (h/'AGENTS.md').write_text('# Disposable validation home\n')
    (h/'.fm-secondmate-home').write_text(name+'\n')
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return h,dict(BASE,FM_HOME=str(h))
W=ROOT/'bin/fm-home-summary-refresh.sh'; Q=ROOT/'bin/fm-test-queue.sh'
def scenario(name,fn):
    say('\nSCENARIO '+name)
    try:fn();results.append(dict(name=name,result='pass'));say('RESULT pass')
    except Exception as e:results.append(dict(name=name,result='fail',error=str(e)));say('RESULT fail: '+repr(e))

def queue():
    d=LAB/'queue';d.mkdir();sp=d/'spool';sp.mkdir();(sp/'config').write_text('slots=2\nload_ceiling=96\n');(d/'load').write_text('200\n')
    env=dict(BASE,FM_TEST_QUEUE_DIR=str(sp),FM_TEST_QUEUE_LOAD_FILE=str(d/'load'),FM_TEST_QUEUE_POLL='0.1',FM_TEST_QUEUE_REMOTE_DISABLE='1')
    def status():
        r=subprocess.run([str(Q),'status'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30);return r.stdout
    def start(n):return launch([Q,'run','--label',n,'--','sh','-c',': > "$1/started-$2"; while [ ! -e "$1/release-$2" ]; do sleep 0.2; done; echo "$2" >> "$1/order"','_',d,n],env,'queue-'+n)
    a=start('A');waitfor(lambda:(d/'started-A').exists(),'reserved slot starts A')
    b=start('B');waitfor(lambda:'label=B' in status(),'B waiting')
    c=start('C');waitfor(lambda:'label=C' in status(),'C waiting')
    s=status();say('load=200, ceiling=96\n'+s)
    assert 'serving=1 waiting=2' in s and not (d/'started-B').exists() and not (d/'started-C').exists()
    (d/'release-A').touch();assert a.wait(timeout=30)==0
    waitfor(lambda:(d/'started-B').exists(),'oldest waiter takes reserved slot at high load')
    assert not (d/'started-C').exists();say('A released; B takes reserved slot; C remains queued\n'+status())
    (d/'load').write_text('95\n');waitfor(lambda:(d/'started-C').exists(),'second slot starts below ceiling')
    say('load lowered to 95\n'+status())
    for n in ['B','C']:(d/('release-'+n)).touch()
    assert b.wait(timeout=30)==0 and c.wait(timeout=30)==0
    say('completion order: '+read(d/'order'));say(status())

h,e=home('backoff');ledger=h/'state/home-summary.json';bf=h/'state/.home-summary-refresh.backoff'
def backoff():
    assert run([W],e)==0;original=ledger.read_bytes();epoch=1000
    for i,delay in enumerate([30,60,120,240,480,960,1800,1800],1):
        bad=dict(e,FM_SNAPSHOT_BUDGET='invalid',FM_NOW=str(epoch))
        assert run([W,'--best-effort'],bad)==0
        expected=f'failures={i}\nnext={epoch+delay}\n';assert read(bf)==expected,read(bf)
        say('persisted '+read(bf).strip().replace('\n',' '))
        assert ledger.read_bytes()==original
        before=read(h/'state/.home-summary-refresh.log')
        assert run([W,'--best-effort'],dict(bad,FM_NOW=str(epoch+delay-1)))==0
        assert read(bf)==expected and read(h/'state/.home-summary-refresh.log')==before
        epoch+=delay
    assert run([W],dict(e,FM_NOW='1000'))==0 and not bf.exists()
    published=json.loads(ledger.read_text());assert published['schema']=='fm-secondmate-home-summary.v1'
    shutil.copyfile(ledger,EVID/'recovered-ledger.json');say('direct recovery publishes complete schema and clears backoff')

def queued():
    qh,qe=home('queued');qb=qh/'state/.home-summary-refresh.backoff';lock=qh/'state/.home-summary-refresh.lock';ready=qh/'ready';release=qh/'release'
    holder=launch(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; touch "$3"; while [ ! -e "$4" ]; do sleep .2; done; fm_lock_release "$2"','_',ROOT,lock,ready,release],qe,'lock-holder')
    waitfor(ready.exists,'holder ready')
    bad=dict(qe,FM_NOW='1000',FM_SNAPSHOT_BUDGET='invalid',FM_HOME_SUMMARY_TIMEOUT='45')
    ps=[]
    for n in ['one','two']:
        stage=qh/('state/.home-summary-stage.'+n)
        ps.append(launch([W,'--best-effort'],dict(bad,FM_HOME_SUMMARY_STAGE_PATH=str(stage)),'queued-'+n))
        waitfor(lambda:'lock-wait' in read(stage),'refresh '+n+' queued')
    qb.write_text('failures=2\nnext=900\n')
    assert run([W,'--best-effort'],dict(bad,FM_HOME_SUMMARY_IF_IDLE='1'))==0
    assert read(qb)=='failures=2\nnext=900\n';say('busy if-idle attempt preserved failures=2 next=900')
    qb.unlink();release.touch();assert holder.wait(timeout=30)==0
    for p in ps:assert p.wait(timeout=60)==0
    assert read(qb)=='failures=1\nnext=1030\n',read(qb)
    say('two queued failures admitted only one producer: '+read(qb).strip().replace('\n',' '));say(read(qh/'state/.home-summary-refresh.log'))

def deadline():
    dh,de=home('deadline');dl=dh/'state/home-summary.json';db=dh/'state/.home-summary-refresh.backoff';err=dh/'state/.home-summary-refresh.log'
    assert run([W],de)==0;prior=dl.read_bytes();os.mkfifo(err)
    start=time.monotonic();assert run([W,'--best-effort'],dict(de,FM_NOW='1000',FM_SNAPSHOT_BUDGET='invalid',FM_HOME_SUMMARY_TIMEOUT='8'),30)==0
    elapsed=time.monotonic()-start
    say(f'unread FIFO failure-log deadline returned best-effort success in {elapsed:.2f}s');say(read(db))
    assert elapsed<24 and read(db)=='failures=1\nnext=1030\n' and dl.read_bytes()==prior
    assert not (dh/'state/.home-summary-refresh.lock').exists()
    err.unlink();assert run([W],de)==0 and not db.exists();say('recovery cleared backoff and released publication lock')

def interrupted():
    ih,ie=home('interrupted');il=ih/'state/home-summary.json';err=ih/'state/.home-summary-refresh.log';lock=ih/'state/.home-summary-refresh.lock'
    assert run([W],ie)==0;prior=il.read_bytes();os.mkfifo(err)
    stage=ih/'state/.home-summary-stage.interrupted'
    p=launch([W,'--best-effort'],dict(ie,FM_SNAPSHOT_BUDGET='invalid',FM_HOME_SUMMARY_STAGE_PATH=str(stage),FM_HOME_SUMMARY_TIMEOUT='45'),'interrupted-writer')
    waitfor(lambda:'producer' in read(stage) and (lock/'pid').exists(),'worker owns publication lock')
    time.sleep(2);owner=int((lock/'pid').read_text());pg=os.getpgid(owner);assert pg!=os.getpgrp()
    os.killpg(pg,signal.SIGKILL);p.wait(timeout=30);assert il.read_bytes()==prior
    err.unlink();assert run([W],ie)==0;new=il.read_bytes();time.sleep(3);assert il.read_bytes()==new
    say('killed publication lock owner; prior ledger stayed complete; replacement survives old attempt exit')

def watcher():
    wh,we=home('watcher');socket=ROOT/'.v.sock'
    assert run(['tmux','-S',socket,'new-session','-d','-s','fm-lab-watch','sleep 180'],we)==0
    try:
        tmuxenv=subprocess.check_output(['tmux','-S',str(socket),'display-message','-p','#{socket_path},#{pid},0'],env=we,text=True).strip()
        we.update(TMUX=tmuxenv,FM_BACKEND='tmux',FM_POLL='1',FM_HOME_SUMMARY_INTERVAL='1',FM_HOME_SUMMARY_JITTER='0',FM_SIGNAL_GRACE='0',FM_HEARTBEAT_BIN='/usr/bin/true',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
        bf=wh/'state/.home-summary-refresh.backoff';bf.write_text('failures=2\nnext=9999999999\n')
        p=launch([ROOT/'bin/fm-watch.sh'],we,'watcher');beat=wh/'state/.last-watcher-beat'
        waitfor(beat.exists,'watcher initial beat');seen=[beat.stat().st_mtime_ns]
        for _ in range(3):
            waitfor(lambda:beat.stat().st_mtime_ns!=seen[-1],'watcher advances beat',20);seen.append(beat.stat().st_mtime_ns)
        assert not (wh/'state/home-summary.json').exists() and read(bf)=='failures=2\nnext=9999999999\n'
        say('real watcher beats during active failure backoff: '+json.dumps(seen));stop(p)
    finally:run(['tmux','-S',socket,'kill-server'],we)

try:
    for name,fn in [('High-load reserved slot, FIFO turnover, and second-slot ceiling',queue),('Real producer failures back off 30 to 1800 seconds and direct publication resets',backoff),('Concurrent refreshes recheck backoff and busy if-idle skips preserve it',queued),('Lock-held filesystem stall records bounded backoff and preserves ledger',deadline),('Killed lock owner cannot replace a recovered ledger',interrupted),('Real watcher keeps liveness beats while failure backoff suppresses publication',watcher)]:
        if len(sys.argv)==1 or fn.__name__==sys.argv[1]: scenario(name,fn)
finally:
    for p,f in children:stop(p);f.close()
    shutil.rmtree(LAB)
    (EVID/('watcher-retry-results.json' if len(sys.argv)>1 else 'live-results.json')).write_text(json.dumps(results,indent=2)+'\n');say('all directly owned children reaped; disposable homes removed');log.close()
sys.exit(any(r['result']!='pass' for r in results))
