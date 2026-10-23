import contextlib, datetime, json, os, pathlib, shlex, shutil, subprocess, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J69ZR1KR6Z67YZ17HJFWEY')
LAB = ROOT / 'l'
BASE = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
BASE['FM_CREW_STATE_NO_FORGE'] = '1'
results = []
log = (EVIDENCE / 'live-park-transcript.log').open('w', buffering=1)
def emit(s):
    print(s, flush=True); log.write(s+'\n')
def run(args, env=None, check=True):
    emit('$ '+shlex.join([str(a) for a in args]))
    p = subprocess.run(args, cwd=ROOT, env=env or BASE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=35)
    emit(p.stdout.rstrip()+'\n[exit '+str(p.returncode)+']')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def utc(seconds, precision='seconds'):
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).isoformat(timespec=precision).replace('+00:00','Z')

class Home:
    def __enter__(self):
        if LAB.exists(): raise RuntimeError('lab path already exists')
        run(['bash','bin/fm-lab-home.sh','create',str(LAB)])
        self.state = LAB/'state'; self.status = self.state/'worker.status'
        (LAB/'t').mkdir()
        self.env = BASE | {'FM_HOME':str(LAB), 'TMUX_TMPDIR':str(LAB/'t'), 'FM_BACKEND':'tmux'}
        run(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-x','100','-y','30','-s','fm-lab-park','-n','fm-worker','-c',str(LAB),"printf 'Inert worker: delivered PR; unable to declare a wait.\\n'; exec sleep 240"],self.env)
        socket = run(['tmux','-L','fm-lab','display-message','-p','#{socket_path}'],self.env).stdout.strip()
        self.env['TMUX'] = socket+',0,0'
        (self.state/'worker.meta').write_text('window=fm-lab-park:fm-worker\nkind=ship\nbackend=tmux\nharness=claude\n')
        self.status.write_text('working: delivered PR; quota exhausted\n')
        run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/worker.status"'],self.env)
        self.watch = None; self.out = None
        return self
    def __exit__(self,*exc):
        self.stop()
        run(['tmux','-L','fm-lab','kill-server'],self.env,False)
        shutil.rmtree(LAB)
        emit('CLEANUP: private tmux server stopped; disposable lab removed.')
    def park(self,deadline,reason='quota exhausted; delivered PR awaiting upstream review',**opts):
        return run(['bash','bin/fm-park.sh','worker','--until',deadline,'--reason',reason],self.env | opts)
    def start(self,name,cadence=240):
        self.outpath=EVIDENCE/(name+'-watcher.log'); self.out=self.outpath.open('w')
        env=self.env | {'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_PAUSE_RESURFACE_SECS':str(cadence)}
        emit('$ FM_HOME=<disposable lab> FM_POLL=1 FM_PAUSE_RESURFACE_SECS='+str(cadence)+' bash bin/fm-watch.sh')
        self.watch=subprocess.Popen(['bash','bin/fm-watch.sh'],cwd=ROOT,env=env,stdout=self.out,stderr=subprocess.STDOUT)
    def stop(self):
        if self.watch is not None and self.watch.poll() is None:
            self.watch.terminate(); self.watch.wait(timeout=12)
        if self.out: self.out.close()
    def wait_exit(self,timeout=25):
        self.watch.wait(timeout=timeout)
        self.out.flush()
        text=self.outpath.read_text(); emit(text.rstrip())
        assert self.watch.returncode==0, 'watcher failed: '+text
        return text
    def quiet_cycles(self,cycles=3,timeout=35):
        count=self.state/'.count-fm-lab-park_fm-worker'
        limit=time.monotonic()+timeout
        while time.monotonic()<limit:
            if self.watch.poll() is not None:
                raise AssertionError('watcher exited unexpectedly: '+self.outpath.read_text())
            try: n=int(count.read_text().strip())
            except (FileNotFoundError,ValueError): n=0
            triage=self.state/'.watch-triage.log'
            if n>=cycles and triage.exists() and 'declared time not reached' in triage.read_text():
                assert not (self.state/'.wake-queue').exists() or not (self.state/'.wake-queue').read_text().strip(), 'unexpected queued wake'
                emit('OBSERVED: '+str(n)+' stable-pane polls; no queued wake.\n'+triage.read_text().rstrip())
                return
            time.sleep(.2)
        raise AssertionError('no completed quiet polls: '+self.outpath.read_text())
    def snapshot(self,name):
        for item in ('worker.status','.watch-triage.log','.wake-queue'):
            path=self.state/item
            if path.exists():
                text=path.read_text(); (EVIDENCE/(name+'-'+item.lstrip('.'))).write_text(text)
                emit('STATE '+item+':\n'+text.rstrip())

def scenario(name, fn):
    emit('\nSCENARIO: '+name)
    try:
        fn(); results.append({'name':name,'result':'pass','live':True})
        emit('RESULT: PASS')
    except Exception as exc:
        results.append({'name':name,'result':'fail','live':True,'error':repr(exc)})
        emit('RESULT: FAIL '+repr(exc))
    (EVIDENCE/'live-park-results.json').write_text(json.dumps(results,indent=2)+'\n')

def baseline():
    with Home() as h:
        h.start('baseline')
        text=h.wait_exit()
        assert 'stale: fm-lab-park:fm-worker' in text
        h.snapshot('baseline')

def park_and_resume():
    with Home() as h:
        h.park(utc(time.time()+120))
        h.start('park-resume')
        h.quiet_cycles(4)
        h.snapshot('park-before-resume')
        with h.status.open('a') as f: f.write('working: quota reset; resuming\n')
        emit('WORKER EVENT: working: quota reset; resuming')
        text=h.wait_exit()
        assert 'signal:' in text and 'worker.status' in text
        p=run(['bash','-c','. bin/fm-classify-lib.sh; status_declared_wait_line "$FM_HOME/state/worker.status"'],h.env)
        assert not p.stdout.strip(), 'old wait still active'
        h.snapshot('park-after-resume')

def expiry():
    with Home() as h:
        deadline=time.time()+20
        h.park(utc(deadline))
        h.start('expiry')
        h.quiet_cycles(3)
        text=h.wait_exit(30)
        assert time.time()>=int(deadline)
        assert 'declared clearing time has passed' in text and 'possible wedge' not in text
        h.snapshot('expiry')

def cadence():
    with Home() as h:
        h.park(utc(time.time()+86400))
        h.start('cadence',cadence=7)
        text=h.wait_exit()
        assert 'declared time is beyond the recheck cadence' in text
        assert 'declared clearing time has passed' not in text
        h.snapshot('cadence')

def invalid():
    with Home() as h:
        h.park('2099-10-24T12:00:30Z')
        before=h.status.read_bytes()
        cases=[('February 30, minutes',['worker','--until','2099-02-30T12:00Z','--reason','waiting']),('February 30, seconds',['worker','--until','2099-02-30T12:00:30Z','--reason','waiting']),('non-leap February 29',['worker','--until','2099-02-29T12:00Z','--reason','waiting']),('unknown task',['unknown','--until','2099-10-24T12:00Z','--reason','waiting']),('path traversal',['../worker','--until','2099-10-24T12:00Z','--reason','waiting']),('non-UTC',['worker','--until','2099-10-24T12:00+01:00','--reason','waiting']),('past deadline',['worker','--until','2020-10-24T12:00Z','--reason','waiting']),('missing deadline',['worker','--reason','waiting']),('blank reason',['worker','--until','2099-10-24T12:00Z','--reason','  ']),('oversized reason',['worker','--until','2099-10-24T12:00Z','--reason','x'*240])]
        for name,args in cases:
            emit('INVALID REQUEST: '+name)
            p=run(['bash','bin/fm-park.sh']+args,h.env,False)
            assert p.returncode!=0, 'accepted '+name
            assert h.status.read_bytes()==before, 'changed status for '+name
            assert not (h.state/'unknown.status').exists()
            emit('OBSERVED: refusal; status bytes unchanged.')
        h.snapshot('refusals')

def options():
    with Home() as h:
        for ts in ('2099-10-24T12:00Z','2099-10-24T12:00:30Z'):
            h.park(ts,'quota exhausted until 2020-01-01T12:00Z; upstream review until 2020-01-02T12:00:30Z')
            p=run(['bash','-c','. bin/fm-classify-lib.sh; line=$(status_declared_wait_line "$FM_HOME/state/worker.status"); printf "%s\\n" "$line"; status_paused_until "$line"'],h.env)
            assert p.stdout.splitlines()[-1]==str(int(datetime.datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp()))
        p=h.park('2099-10-24T12:00:30Z','quota\nexhausted\tupstream review',FM_CLASSIFY_PAUSED_VERB='holding')
        env=h.env | {'FM_CLASSIFY_PAUSED_VERB':'holding'}
        p=run(['bash','-c','. bin/fm-classify-lib.sh; line=$(status_declared_wait_line "$FM_HOME/state/worker.status"); printf "%s\\n" "$line"; status_paused_until "$line"'],env)
        assert p.stdout.startswith('holding [key=fm-park]')
        assert 'quota exhausted upstream review' in p.stdout
        assert p.stdout.splitlines()[-1]=='4096526430'
        h.env['FM_CLASSIFY_PAUSED_VERB']='holding'
        h.start('custom-verb')
        h.quiet_cycles(3)
        h.snapshot('options')

emit('REVISION '+run(['git','rev-parse','HEAD']).stdout.strip())
scenario('Unparked inert worker produces a stale wake (control)',baseline)
scenario('Parking an inert worker suppresses repeated stale wakes; a later worker event cancels the park',park_and_resume)
scenario('Park expires at its deadline and surfaces a recheck',expiry)
scenario('Distant deadline remains bounded by the normal recheck cadence',cadence)
scenario('Invalid requests, including impossible calendar dates, refuse without status changes',invalid)
scenario('Replacement parks honor explicit deadline despite reason timestamps, custom verb, and multiline reason',options)
emit(json.dumps(results,indent=2))
