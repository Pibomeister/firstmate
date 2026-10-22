import os, subprocess, time, pathlib, json, datetime, shutil, signal
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J69ZR1KR6Z67YZ17HJFWEY')
LAB=ROOT/'.l'
assert not LAB.exists(), 'refusing existing .l'
LOG=(EVID/'park-live-transcript.log').open('w')
results=[]
processes=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE')}
env.update(FM_HOME=str(LAB/'home'), FM_BACKEND='tmux', FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_PAUSE_RESURFACE_SECS='240', FM_SECONDMATE_LIVENESS_SECS='999999', FM_CREW_STATE_NO_FORGE='1')
def log(s):
    LOG.write(s+'\n'); LOG.flush(); print(s, flush=True)
def run(args, check=True, timeout=60, extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run([str(a) for a in args],cwd=ROOT,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log('$ '+subprocess.list2cmdline([str(a) for a in args])+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
    if check: assert p.returncode==0, p.stdout
    return p

def ts(offset, minute=False):
    return datetime.datetime.fromtimestamp(time.time()+offset,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M'+('Z' if minute else ':%SZ'))
def scenario(name,fn):
    try:
        fn(); results.append(dict(name=name,result='pass',live=True,evidence='park-live-transcript.log',reason='')); log('SCENARIO PASS: '+name)
    except Exception as exc:
        results.append(dict(name=name,result='fail',live=True,evidence='park-live-transcript.log',reason=str(exc))); log('SCENARIO FAIL: '+name+': '+str(exc)); raise

def watch(name):
    f=(EVID/(name+'.log')).open('w')
    p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
    processes.append((p,f)); log('$ FM_HOME=<disposable lab> bin/fm-watch.sh -> '+name+'.log; pid='+str(p.pid))
    return p

def stop(p):
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
        try: p.wait(timeout=15)
        except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()

def read(path): return path.read_text() if path.exists() else ''
def wait_for(fn,seconds=90):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if fn(): return
        time.sleep(.25)
    raise AssertionError('timed out waiting for product observation')

try:
    LAB.mkdir(); run(['bin/fm-lab-home.sh','create',LAB/'home'])
    state=LAB/'home/state'; status=state/'inert.status'
    run(['tmux','-f','/dev/null','-S',LAB/'s','new-session','-d','-s','fm-lab-park','-n','fm-inert','-x','100','-y','30','-c',ROOT,'/bin/bash --noprofile --norc'])
    tmux=['tmux','-S',str(LAB/'s')]
    identity=run(tmux+['display-message','-p','-t','fm-lab-park','#{socket_path},#{pid},#{session_id}']).stdout.strip()
    env['TMUX']=identity
    (state/'inert.meta').write_text('window=fm-lab-park:fm-inert\nbackend=tmux\nkind=scout\nharness=claude\n')
    status.write_text('')
    run(tmux+['capture-pane','-p','-t','fm-lab-park:fm-inert'])
    deadline=ts(60)
    def park_and_absorb():
        run(['bin/fm-park.sh','inert','--until',deadline,'--reason','agent quota exhausted; delivered PR awaits upstream review'])
        log('Persisted public status log:\n'+status.read_text())
        global watcher
        watcher=watch('watch-before-deadline')
        triage=state/'.watch-triage.log'
        wait_for(lambda: read(triage).count('declared time not reached')>=2,50)
        assert watcher.poll() is None
        assert not read(state/'.wake-queue').strip(), read(state/'.wake-queue')
        log('Actual watcher decisions:\n'+read(triage))
        log('Durable wake queue is empty after repeated stale scans; watcher remains running.')
    scenario('Supervisor parks an inert pane; repeated stale scans stay silent before its deadline',park_and_absorb)
    def expiry():
        watcher.wait(timeout=100)
        assert watcher.returncode==0
        out=read(EVID/'watch-before-deadline.log'); queue=read(state/'.wake-queue')
        log('Watcher deadline output:\n'+out+'Durable wake queue:\n'+queue)
        assert 'declared clearing time has passed' in out
        assert len([l for l in queue.splitlines() if '\tstale\t' in l])==1
        assert 'possible wedge' not in out
        # Consume through the public supervisor interface, including its recovery token.
        drain=run(['bin/fm-wake-drain.sh'],check=False)
        import re
        match=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',drain.stdout)
        assert match, 'missing public acknowledgement command'
        run(['bin/fm-wake-drain.sh','--ack-through',match[1],'--recovery-generation',match[2]],check=False)
        global second
        second=watch('watch-after-deadline')
        n=len(read(state/'.watch-triage.log').splitlines())
        wait_for(lambda: len(read(state/'.watch-triage.log').splitlines())>=n+2,60)
        assert second.poll() is None,read(EVID/'watch-after-deadline.log')
        assert not read(state/'.wake-queue').strip(),read(state/'.wake-queue')
        log('After acknowledging and rearming, repeated scans emit no further wake:\n'+read(state/'.watch-triage.log'))
    scenario('Deadline expiry produces one recheck and rearming does not repeat the stale wake',expiry)
    def resume():
        run(tmux+['send-keys','-t','fm-lab-park:fm-inert',"printf 'working: quota reset, resuming\\n' >> "+str(status),'Enter'])
        second.wait(timeout=90)
        out=read(EVID/'watch-after-deadline.log'); log('Resumption watcher output:\n'+out+'Current status:\n'+status.read_text())
        assert 'signal:' in out and second.returncode==0
        run(['bin/fm-crew-state.sh','inert'],check=False)
    scenario('A worker appends a new event; supervision surfaces it instead of retaining the park',resume)
    def deadlines():
        for minute in (True,False):
            until=ts(86400,minute)
            reason='quota exhausted until 2020-01-01T12:00Z; review until 2020-01-02T12:00:30Z'
            run(['bin/fm-park.sh','inert','--until='+until,'--reason='+reason])
            p=run(['bash','-c','. bin/fm-classify-lib.sh; line=$(status_declared_wait_line "$FM_HOME/state/inert.status"); printf "%s\n" "$line"; status_paused_until "$line"'])
            expected=int(datetime.datetime.fromisoformat(until.replace('Z','+00:00')).timestamp())
            assert p.stdout.splitlines()[-1]==str(expected)
        run(['bin/fm-park.sh','inert','--until',ts(86400),'--reason','waiting'],extra={'FM_CLASSIFY_PAUSED_VERB':'holding'})
        assert status.read_text().splitlines()[-1].startswith('holding [key=fm-park]')
        log('Persisted minute, seconds and configured-verb declarations:\n'+status.read_text())
    scenario('Timestamped reasons preserve the requested deadline and the configured pause verb works',deadlines)
    def refusals():
        before=status.read_bytes()
        cases=[['inert','--until','2099-02-30T12:00Z','--reason','waiting'],['inert','--until','2099-02-30T12:00:30Z','--reason','waiting'],['missing','--until',ts(86400),'--reason','waiting'],['../inert','--until',ts(86400),'--reason','waiting'],['inert','--reason','waiting'],['inert','--until','2099-01-01T00:00','--reason','waiting'],['inert','--until','2020-01-01T00:00Z','--reason','waiting'],['inert','--until',ts(86400),'--reason','  '],['inert','--until',ts(86400),'--reason','x'*240]]
        for args in cases:
            p=run(['bin/fm-park.sh']+args,check=False)
            assert p.returncode!=0
            assert status.read_bytes()==before,'refusal modified status'
        assert not (state/'missing.status').exists()
        log('All refused requests left the status log byte-identical; no unrecorded task log was created.')
    scenario('Invalid dates and unsafe or incomplete requests fail without changing task status',refusals)
finally:
    for p,f in processes:
        stop(p); f.close()
    if LAB.exists():
        for name in ('.watch-triage.log','.wake-queue'):
            f=LAB/'home/state'/name
            if f.exists(): shutil.copyfile(f,EVID/('final'+name))
        subprocess.run(['tmux','-S',str(LAB/'s'),'kill-server'],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        shutil.rmtree(LAB)
    log('Cleanup: private tmux server stopped; disposable home and socket removed.')
    (EVID/'park-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    LOG.close()
