import os, pathlib, shlex, shutil, subprocess, time, runpy
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5JW8KCSACJJWWF0BM98FFES')
lab = root / '.nm-test-tmp' / 'live'
lab.mkdir()
queue = root / 'bin/fm-test-queue.sh'
processes = []
env = dict(os.environ)
for key in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TEST_QUEUE_HELD'):
    env.pop(key, None)
env.update(FM_TEST_QUEUE_DIR=str(lab/'spool'), FM_TEST_QUEUE_POLL='0.1', FM_TEST_SEAM='1', FM_TEST_QUEUE_LOAD_FILE=str(lab/'load'))
(lab/'spool').mkdir()
(lab/'spool/config').write_text('slots=1\n')
(lab/'load').write_text('20.5\n')
log = (evidence/'queue-live-transcript.txt').open('w')
def record(text):
    log.write(text+'\n'); log.flush()
def status():
    return subprocess.check_output(['/bin/bash', str(queue), 'status'], env=env, text=True)
def until(name, predicate):
    end = time.monotonic()+20
    while not predicate():
        if time.monotonic()>end: raise AssertionError(name+'\n'+status())
        time.sleep(.1)
def show(title):
    record('\n'+title+'\n$ bin/fm-test-queue.sh status\n'+status().rstrip())
def start(name):
    p = subprocess.Popen(['/bin/bash',str(queue),'run','--label',name,'--','/bin/sh','-c',
        'echo "started $2" >> "$1/events"; while [ ! -e "$1/release-$2" ]; do sleep 0.05; done; echo "$2" >> "$1/order"', '_', str(lab),name],env=env,stdout=log,stderr=log)
    processes.append(p); return p
try:
    record('Real fm-test-queue.sh public CLI; isolated spool; load file drives threshold transitions. Interpreter: macOS /bin/bash 3.2.')
    a=start('A'); until('A enqueued',lambda:'label=A' in status())
    b=start('B'); until('B queued',lambda:'waiting position=2' in status())
    c=start('C'); until('C queued',lambda:'waiting position=3' in status())
    show('High load: all three wait in ticket order; no workload has started.')
    assert not (lab/'events').exists()
    (lab/'load').write_text('1\n')
    until('A started',lambda:(lab/'events').exists())
    show('Low load: A runs; B and C still wait for the single shared slot.')
    assert (lab/'events').read_text()=='started A\n'
    for name,p in [('A',a),('B',b),('C',c)]:
        until(name+' active',lambda name=name:'started '+name+'\n' in (lab/'events').read_text())
        (lab/('release-'+name)).touch()
        assert p.wait(timeout=20)==0
    record('\nWorkload completion order:\n'+(lab/'order').read_text().rstrip())
    assert (lab/'order').read_text()=='A\nB\nC\n'
    show('All runs completed: the line is empty.')
    realenv=dict(env); realenv.pop('FM_TEST_QUEUE_LOAD_FILE'); realenv.pop('FM_TEST_SEAM')
    record('\nReal host load probe (no test seam):\n'+subprocess.check_output(['/bin/bash',str(queue),'status'],env=realenv,text=True).rstrip())
    assert 'load1=unknown' not in subprocess.check_output(['/bin/bash',str(queue),'status'],env=realenv,text=True)
finally:
    for name in ('A','B','C'): (lab/('release-'+name)).touch()
    for p in processes:
        if p.poll() is None: p.terminate()
        p.wait(timeout=20)
    log.close()

foreign = lab / "firstmate helper's root"
(foreign/'bin').mkdir(parents=True)
shutil.copy2(queue,foreign/'bin/fm-test-queue.sh')
home=lab/'home'; (home/'data').mkdir(parents=True)
briefenv=dict(env,FM_HOME=str(home),FM_ROOT_OVERRIDE=str(foreign))
rules=[]
with (evidence/'brief-live-transcript.txt').open('w') as out:
    for mode in ('no-mistakes','direct-PR','local-only','scout','secondmate'):
        task='live-'+mode
        cmd=[str(root/'bin/fm-brief.sh'),task,'alpha']
        thisenv=dict(briefenv)
        if mode=='scout': cmd+=['--scout']
        elif mode=='secondmate': cmd+=['--secondmate']; thisenv['FM_SECONDMATE_CHARTER']='Supervise the disposable lab.'
        else: cmd+=['--mode',mode]
        completed=subprocess.run(cmd,env=thisenv,capture_output=True,text=True)
        assert completed.returncode==0,completed.stderr
        brief=(home/'data'/task/'brief.md').read_text()
        shutil.copy2(home/'data'/task/'brief.md',evidence/(task+'-brief.md'))
        out.write('$ '+shlex.join(cmd)+'\n'+completed.stdout)
        found=[line for line in brief.splitlines() if 'Run heavy test suites only through' in line]
        if mode=='secondmate':
            assert not found
            out.write('Generated secondmate charter has no crewmate queue rule.\n\n'); continue
        assert len(found)==1
        rule=found[0]; rules.append(rule)
        out.write('Generated rule: '+rule+'\n')
        template=rule.split('`')[1]
        assert template.endswith('<command>')
        actual=template[:-len('<command>')]+"printf '%s\\n' 'real queued workload from quoted root'"
        result=subprocess.run(['/bin/bash','-c',actual],env=env,capture_output=True,text=True,timeout=20)
        out.write('$ '+actual+'\n'+result.stdout+result.stderr+'exit='+str(result.returncode)+'\n\n')
        assert result.returncode==0 and result.stdout=='real queued workload from quoted root\n'
    assert len(set(rules))==1

terminal = lab/'terminal'; terminal.mkdir(); (terminal/'spool').mkdir(); (terminal/'spool/config').write_text('slots=1\n')
os.environ.update(env,FM_TEST_QUEUE_DIR=str(terminal/'spool'))
import sys
sys.argv=[str(root/'tests/fm-test-queue-pty.py'),str(queue),'/bin/bash',str(terminal)]
try:
    results=runpy.run_path(sys.argv[0],run_name='__main__')
except Exception:
    raise
else:
    (evidence/'queue-terminal-transcript.txt').write_bytes(results['output'])
print('Captured FIFO/load/status transcript, executed all generated brief queue commands, and captured native terminal interaction transcript.')
