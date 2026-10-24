import os, pathlib, subprocess, time
root=pathlib.Path.cwd(); lab=root/'.nm-test-tmp/cross-home'; lab.mkdir()
evidence=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5JW8KCSACJJWWF0BM98FFES')
queue=root/'bin/fm-test-queue.sh'
env=dict(os.environ)
for key in ('FM_TEST_QUEUE_DIR','FM_TEST_QUEUE_HELD','FM_TEST_QUEUE_LOAD_FILE','FM_TEST_SEAM'):
    env.pop(key,None)
env.update(XDG_STATE_HOME=str(lab/'xdg-state'),FM_TEST_QUEUE_POLL='0.1')
spool=lab/'xdg-state/firstmate/test-queue'; spool.mkdir(parents=True); (spool/'config').write_text('slots=1\n')
for home in ('home-a','home-b'): (lab/home).mkdir()
p1=p2=None
with (evidence/'cross-home-crash-transcript.txt').open('w') as log:
    def status(): return subprocess.check_output(['/bin/bash',str(queue),'status'],env=env,text=True)
    def until(name,predicate):
        end=time.monotonic()+30
        while not predicate():
            if time.monotonic()>end: raise AssertionError(name+'\n'+status())
            time.sleep(.1)
    def show(name): log.write('\n'+name+'\n$ bin/fm-test-queue.sh status\n'+status()); log.flush()
    try:
        log.write('Real load probe and default XDG spool resolution; two independent FM_HOME values and two timezones. No FM_TEST_QUEUE_DIR or test seams.\n')
        p1=subprocess.Popen(['/bin/bash',str(queue),'run','--label','home-a-UTC','--','/bin/sh','-c','echo $$ > "$1/child"; echo "$TZ" > "$1/child-tz"; while [ ! -e "$1/release" ]; do sleep 0.05; done','_',str(lab)],env=dict(env,FM_HOME=str(lab/'home-a'),TZ='UTC'),stdout=log,stderr=log)
        until('real-load admission',lambda:(lab/'child').exists())
        child=int((lab/'child').read_text())
        p2=subprocess.Popen(['/bin/bash',str(queue),'run','--label','home-b-Mexico','--','/bin/sh','-c','echo "$TZ" > "$1/follower-tz"; echo follower-ran > "$1/follower"','_',str(lab)],env=dict(env,FM_HOME=str(lab/'home-b'),TZ='America/Mexico_City'),stdout=log,stderr=log)
        until('other home waiting',lambda:'serving=1 waiting=1 stale=0 ' in status())
        show('Different homes share the same default spool: home B waits behind home A.')
        p1.kill(); assert p1.wait(timeout=5)==-9
        log.write(f'Killed wrapper pid {p1.pid} with SIGKILL; direct workload child pid {child} remains.\n')
        os.kill(child,0)
        time.sleep(.4)
        assert 'serving=1 waiting=1 stale=0 ' in status()
        assert not (lab/'follower').exists()
        show('After SIGKILL: surviving workload keeps the slot despite the contender timezone difference.')
        (lab/'release').touch()
        assert p2.wait(timeout=30)==0
        assert (lab/'follower').read_text()=='follower-ran\n'
        assert (lab/'child-tz').read_text()=='UTC\n'
        assert (lab/'follower-tz').read_text()=='America/Mexico_City\n'
        show('Child exits: home B runs, then leaves an empty queue.')
        log.write('Workload timezones preserved: UTC and America/Mexico_City.\n')
    finally:
        (lab/'release').touch()
        for p in (p1,p2):
            if p is not None:
                if p.poll() is None: p.terminate()
                p.wait(timeout=30)
print('Real load, shared default spool across two homes, cross-timezone SIGKILL survival, reclamation, and command environments passed.')
