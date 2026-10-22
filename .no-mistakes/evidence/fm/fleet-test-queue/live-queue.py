import os, pathlib, subprocess, time, signal, json, shutil
root=pathlib.Path.cwd()
base=root/'.test-phase-scratch'/'live-product2'
base.mkdir()
evidence=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5JW8KCSACJJWWF0BM98FFES')
queue=root/'bin/fm-test-queue.sh'
spool=base/'shared-state'/'firstmate'/'test-queue'
spool.mkdir(parents=True)
(spool/'config').write_text('slots=1\nload_ceiling=100000\n')
env=dict(os.environ, XDG_STATE_HOME=str(base/'shared-state'),FM_TEST_QUEUE_POLL='0.1')
for key in ('FM_TEST_QUEUE_DIR','FM_TEST_QUEUE_HELD','FM_TEST_SEAM','FM_TEST_QUEUE_LOAD_FILE'):
    env.pop(key,None)
log=[]
processes=[]
handles=[]
def note(text):
    log.append(text)
    print(text,flush=True)
def run(args,custom=None):
    p=subprocess.run(['/bin/bash',str(queue)]+args,env=custom or env,capture_output=True,text=True)
    note('$ fm-test-queue.sh '+ ' '.join(args)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]')
    return p

def status(custom=None):
    p=subprocess.run(['/bin/bash',str(queue),'status'],env=custom or env,capture_output=True,text=True)
    assert p.returncode==0,p.stderr
    return p.stdout

def snapshot(label,custom=None):
    value=status(custom)
    note(label+'\n$ fm-test-queue.sh status\n'+value)
    return value

def until(fn):
    deadline=time.monotonic()+20
    while not fn():
        if time.monotonic()>deadline:
            raise AssertionError('timed out\n'+status())
        time.sleep(.05)

def spawn(label,custom=None,held=True):
    own=dict(custom or env, FM_HOME=str(base/('home-'+label)))
    pathlib.Path(own['FM_HOME']).mkdir(exist_ok=True)
    (base/label).mkdir(exist_ok=True)
    out=open(base/label/'stdout','w'); err=open(base/label/'stderr','w')
    handles.extend([out,err])
    script='echo $$ > "$1/child"; echo "START $2 TZ=${TZ-unset}"; : > "$1/started"; '
    if held:
        script+='while [ ! -e "$1/release" ]; do sleep 0.05; done; '
    script+='echo "END $2"'
    p=subprocess.Popen(['/bin/bash',str(queue),'run','--label',label,'--','/bin/sh','-c',script,'_',str(base/label),label],env=own,stdout=out,stderr=err)
    processes.append(p)
    note(f'$ FM_HOME=<isolated-{label}> fm-test-queue.sh run --label {label} -- <held workload>; wrapper pid={p.pid}')
    return p

def release(label):
    (base/label/'release').touch()

def completed(p,label):
    rc=p.wait(timeout=20)
    note(f'{label}: exit={rc}\nstdout:\n'+(base/label/'stdout').read_text()+'stderr:\n'+(base/label/'stderr').read_text())
    assert rc==0

try:
    note('Revision: '+subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    note('SCENARIO: independent homes share one FIFO line using the default XDG spool; actual host load probe')
    a=spawn('A'); until(lambda:(base/'A'/'started').exists())
    b=spawn('B'); until(lambda:'waiting position=1 ' in status())
    c=spawn('C'); until(lambda:'waiting position=2 ' in status())
    s=snapshot('A runs; B then C wait across independent FM_HOME values')
    assert 'label=A' in s and 'label=B' in s and 'label=C' in s and 'serving=1 waiting=2' in s
    release('C'); release('B'); time.sleep(.25)
    assert not (base/'B'/'started').exists() and not (base/'C'/'started').exists()
    release('A')
    for p,label in ((a,'A'),(b,'B'),(c,'C')): completed(p,label)
    assert 'serving=0 waiting=0 stale=0' in snapshot('All workloads have left')

    note('SCENARIO: high load holds the head; falling load serves it (documented disposable load seam)')
    (spool/'config').write_text('slots=1\nload_ceiling=16\n')
    load=base/'load-probe';load.write_text('20.5\n')
    loadenv=dict(env,FM_TEST_SEAM='1',FM_TEST_QUEUE_LOAD_FILE=str(load))
    p=spawn('load',loadenv,held=False)
    until(lambda:'load 20.5 is not below 16' in (base/'load'/'stderr').read_text())
    snapshot('Load above ceiling: command has not started',loadenv)
    assert not (base/'load'/'started').exists()
    load.write_text('15.9\n');completed(p,'load')
    assert 'serving=0 waiting=0 stale=0' in snapshot('Load fell below ceiling: command completed',loadenv)

    note('SCENARIO: a killed wrapper keeps its slot through a surviving child, seen by another timezone')
    utc=dict(loadenv,TZ='UTC');mexico=dict(loadenv,TZ='America/Mexico_City')
    a=spawn('survivor',utc); until(lambda:(base/'survivor'/'started').exists())
    child=int((base/'survivor'/'child').read_text())
    os.kill(a.pid,signal.SIGKILL); assert a.wait(timeout=10)==-signal.SIGKILL
    note(f'Killed only wrapper {a.pid}; direct workload {child} remains alive')
    os.kill(child,0)
    b=spawn('follower',mexico,held=False)
    until(lambda:'serving=1 waiting=1 stale=0' in status(mexico))
    snapshot('Mexico-timezone follower waits for UTC survivor after SIGKILL',mexico)
    assert not (base/'follower'/'started').exists()
    release('survivor'); completed(b,'follower')
    note('Survivor output:\n'+(base/'survivor'/'stdout').read_text())
    assert 'TZ=UTC' in (base/'survivor'/'stdout').read_text()
    assert 'TZ=America/Mexico_City' in (base/'follower'/'stdout').read_text()
    assert 'serving=0 waiting=0 stale=0' in snapshot('Survivor exited; follower ran; queue empty',mexico)

    note('SCENARIO: command stdio and exit status survive wrapping; malformed config fails before workload')
    p=run(['run','--','/bin/sh','-c','read line; echo "stdout:$line"; echo stderr >&2; exit 7'],loadenv) if False else subprocess.run(['/bin/bash',str(queue),'run','--','/bin/sh','-c','read line; echo "stdout:$line"; echo stderr >&2; exit 7'],env=loadenv,input='input-value\n',capture_output=True,text=True)
    note('$ printf input-value | fm-test-queue.sh run -- <stdio workload>\n'+p.stdout+p.stderr+f'[exit {p.returncode}]')
    assert p.returncode==7 and p.stdout=='stdout:input-value\n' and p.stderr=='stderr\n'
    (spool/'config').write_text('slots=0\n')
    p=run(['run','--','/bin/sh','-c','touch "$1"','_',str(base/'forbidden-workload')],loadenv)
    assert p.returncode==125 and not (base/'forbidden-workload').exists()
    note('All live CLI assertions passed.')
finally:
    for path in base.iterdir():
        if path.is_dir() and path.name not in ('shared-state',):
            (path/'release').touch()
    for p in processes:
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
    for h in handles:h.close()
    (evidence/'live-queue-transcript.log').write_text('\n\n'.join(log)+'\n')
