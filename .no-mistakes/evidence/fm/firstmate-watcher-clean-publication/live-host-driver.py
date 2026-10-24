import os,pathlib,subprocess,time,signal,shlex
r=pathlib.Path.cwd();h=r/'.test-tmp/live-host-final';s=h/'state';ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5P9MH9YHZ7098T3VRGQQMR0')
e=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM']:e.pop(k,None)
e.update(FM_HOME=str(h),FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0',TMPDIR=str(r/'.test-tmp'))
f=(ev/'live-host-recovery.txt').open('w',buffering=1);procs=[]
def log(x): f.write(str(x)+'\n')
def run(args):
 p=subprocess.run(args,env=e,capture_output=True,text=True,timeout=35);log('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}');return p
def wait(pred,seconds=35):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  try:
   if pred():return
  except (OSError,ValueError,IndexError):pass
  time.sleep(.1)
 raise AssertionError('condition timed out')
def text(p):return p.read_text() if p.exists() else ''
def alive(pid):
 try:os.kill(int(pid),0);return True
 except (ProcessLookupError,ValueError):return False
def record(role):return [line.split('\t')[1] for line in text(s/'.supervision-host').splitlines() if line.startswith(role+'\t')]
def start(n,bound):
 out=(ev/f'live-host-{n}.out').open('w');err=(ev/f'live-host-{n}.err').open('w')
 p=subprocess.Popen(['bin/fm-watch-checkpoint.sh','--seconds',str(bound)],env=e,stdout=out,stderr=err);procs.append(p);return p
try:
 log('Real session-lock writer: '+text(s/'.lock').strip()+'; caller is the live Codex gate harness, confined to a marked disposable home. No CLI or engine stub.')
 assert run(['bin/fm-afk-contract.sh','archive']).returncode==0
 p=start(1,60);wait(lambda:(s/'.watch.lock/pid').exists() and (s/'.last-watcher-beat').exists())
 assert run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check lab "check: lab actionable handback"']).returncode==0
 assert p.wait(timeout=40)==0
 log('first handback:\n'+text(ev/'live-host-1.out'))
 leftwatch=int(text(s/'.watch.lock/pid'));leftarm=int(subprocess.check_output(['ps','-o','ppid=','-p',str(leftwatch)],text=True).strip())
 log(f'successor preserved: arm={leftarm}, watcher={leftwatch}')
 assert alive(leftwatch) and alive(leftarm)
 drain=run(['bin/fm-wake-drain.sh']);assert drain.returncode==0
 ack=[x for x in (drain.stdout+drain.stderr).splitlines() if x.startswith('WAKE_ACK_REQUIRED:')][0].split('run bin/fm-wake-drain.sh ',1)[1]
 assert run(['bin/fm-wake-drain.sh',*shlex.split(ack)]).returncode==0
 holder=subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh; fm_lock_acquire_wait "$FM_HOME/state/.watcher-down.lock" || exit; touch "$FM_HOME/marker-held"; while [ ! -e "$FM_HOME/marker-release" ]; do sleep .1; done; fm_lock_release "$FM_HOME/state/.watcher-down.lock"'],env=e);procs.append(holder)
 wait(lambda:(h/'marker-held').exists())
 previous=text(s/'.supervision-host.log');p2=start(2,60)
 wait(lambda:'take-over' in text(s/'.supervision-host.log')[len(previous):])
 wait(lambda:len(record('host'))==1 and len(record('arm'))>=1)
 host=int(record('host')[0]);arm=int(record('arm')[0]);log(f'interrupting takeover host={host}, arm={arm}')
 time.sleep(.3);assert alive(leftwatch)
 os.kill(arm,signal.SIGSTOP);(h/'marker-release').touch();assert holder.wait(timeout=10)==0
 os.kill(host,signal.SIGTERM);os.kill(arm,signal.SIGTERM);os.kill(arm,signal.SIGCONT)
 rc=p2.wait(timeout=35);log(f'interrupted checkpoint exit={rc}\n'+text(ev/'live-host-2.out')+text(ev/'live-host-2.err'))
 assert rc!=0
 p3=start(3,30)
 def owns():
  host=record('host')[0];arm=record('arm')[0];watch=text(s/'.watch.lock/pid').strip()
  if not watch or not alive(watch):return False
  parents=subprocess.check_output(['ps','-o','pid=,ppid=','-p',arm+','+watch],text=True)
  rows={a:b for a,b in (line.split() for line in parents.splitlines())}
  return rows.get(arm)==host and rows.get(watch)==arm and not alive(leftarm) and not alive(leftwatch)
 wait(owns,45);log('next park owns a single fresh arm/watcher; predecessor arm and watcher are gone')
 assert p3.wait(timeout=60)==0
 result=text(ev/'live-host-3.out');log('next checkpoint:\n'+result+text(ev/'live-host-3.err'))
 assert 'no actionable wake' in result and 'rearm-resurface' not in result
 log('host event ledger:\n'+text(s/'.supervision-host.log'));log('cycle exit ledger:\n'+text(s/'.watch-cycle-exits.log'))
 log('PASS: interruption recovered with singleton supervision and no bookkeeping notification')
finally:
 for p in procs:
  if p.poll() is None:p.terminate()
 for p in procs:
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 run(['bin/fm-watch-arm.sh','--stop'])
