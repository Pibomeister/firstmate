import os, pathlib, subprocess, time, signal, shutil
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
case = root / '.test-phase-tmp/manual'
case.mkdir()
log = (evidence / 'live-queue-transcript.log').open('w')
env = dict(os.environ, XDG_STATE_HOME=str(case / 'xdg'), FM_TEST_QUEUE_POLL='0.1')
for name in ('FM_TEST_QUEUE_DIR', 'FM_TEST_QUEUE_HELD', 'FM_TEST_SEAM', 'FM_TEST_QUEUE_LOAD_FILE', 'FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(name, None)
spool = case / 'xdg/firstmate/test-queue'
spool.mkdir(parents=True)
(spool / 'config').write_text('slots=1\nload_ceiling=1000000\n')
queue = ['/bin/bash', str(root / 'bin/fm-test-queue.sh')]
processes = []
def note(s):
    log.write(s + '\n'); log.flush()
def status(label):
    value = subprocess.check_output(queue + ['status'], env=env, text=True)
    note(label + '\n$ bin/fm-test-queue.sh status\n' + value)
    return value
def until(predicate):
    end=time.monotonic()+20
    while not predicate():
        assert time.monotonic()<end, 'timed out'
        time.sleep(.1)
def launch(label, zone):
    home = case / label
    home.mkdir()
    e = dict(env, FM_HOME=str(home), TZ=zone)
    program = 'echo $$ > "$1/child-$2"; printf "start:%s TZ=%s\\n" "$2" "$TZ" >> "$1/events"; while [ ! -f "$1/release-$2" ]; do sleep .05; done; printf "end:%s\\n" "$2" >> "$1/events"'
    args = queue + ['run', '--label', label, '--', '/bin/sh', '-c', program, '_', str(case), label]
    note('$ FM_HOME=' + str(home) + ' TZ=' + zone + ' bin/fm-test-queue.sh run --label ' + label + ' -- <release-controlled workload> &')
    p = subprocess.Popen(args, env=e, stdout=log, stderr=log)
    processes.append(p)
    return p
try:
    status('Initial queue (real host load probe, private XDG state; one configured slot)')
    a=launch('A','UTC')
    until(lambda: (case/'child-A').exists())
    b=launch('B','America/Mexico_City')
    until(lambda: 'waiting position=1 ' in subprocess.check_output(queue+['status'],env=env,text=True))
    c=launch('C','UTC')
    until(lambda: 'waiting position=2 ' in subprocess.check_output(queue+['status'],env=env,text=True))
    s=status('Independent homes share one serving slot and an ordered waiting line')
    assert 'serving=1 waiting=2 stale=0' in s
    assert not (case/'child-B').exists() and not (case/'child-C').exists()
    note('$ kill -KILL '+str(a.pid)+' # kill wrapper A; its workload remains alive')
    a.kill(); assert a.wait()==-signal.SIGKILL
    s=status('Wrapper SIGKILL does not free the surviving child slot')
    assert 'serving=1 waiting=2 stale=0' in s
    time.sleep(.4)
    assert not (case/'child-B').exists()
    (case/'release-A').touch()
    until(lambda: (case/'child-B').exists())
    s=status('After child A exits, B is served before C')
    assert 'serving=1 waiting=1 stale=0' in s and not (case/'child-C').exists()
    (case/'release-B').touch(); assert b.wait(timeout=20)==0
    until(lambda: (case/'child-C').exists())
    (case/'release-C').touch(); assert c.wait(timeout=20)==0
    s=status('After all workloads leave')
    assert 'serving=0 waiting=0 stale=0' in s
    events=(case/'events').read_text(); note('$ cat workload-events\n'+events)
    assert events.splitlines()==['start:A TZ=UTC','end:A','start:B TZ=America/Mexico_City','end:B','start:C TZ=UTC','end:C']
    # Execute the actual queue command emitted by each scaffold from a quoted root.
    foreign=case/"firstmate helper's root"; foreign.mkdir(); (foreign/'bin').symlink_to(root/'bin',target_is_directory=True)
    home=case/'brief-home'; home.mkdir()
    rules=[]
    for mode in ('no-mistakes','direct-PR','local-only','scout'):
        e=dict(env, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(foreign))
        args=[str(root/'bin/fm-brief.sh'),'live-'+mode,'disposable-project']+(['--scout'] if mode=='scout' else ['--mode',mode])
        result=subprocess.run(args,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        note('$ fm-brief.sh live-'+mode+' disposable-project '+(' --scout' if mode=='scout' else '--mode '+mode)+'\n'+result.stdout+result.stderr)
        assert result.returncode==0
        brief=(home/'data'/('live-'+mode)/'brief.md').read_text()
        rule=next(line for line in brief.splitlines() if 'Run heavy test suites only through' in line)
        rules.append(rule); note('Emitted rule: '+rule)
        command=rule.split('`')[1].replace('<command>', "printf 'BRIEF-"+mode+"-WORKLOAD\\n'")
        result=subprocess.run(['/bin/bash','-c',command],env=env,text=True,capture_output=True)
        note('$ '+command+'\n'+result.stdout+result.stderr+'exit='+str(result.returncode))
        assert result.returncode==0 and result.stdout=='BRIEF-'+mode+'-WORKLOAD\n'
    assert len(set(rules))==1
    status('Generated commands used the real queue and left it empty')
    note('All live CLI observations and assertions passed.')
finally:
    for name in ('A','B','C'): (case/('release-'+name)).touch()
    for p in processes:
        if p.poll() is None:
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
    shutil.rmtree(case)
    log.close()
