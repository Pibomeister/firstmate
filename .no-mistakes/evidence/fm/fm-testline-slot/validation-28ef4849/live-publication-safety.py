import json,os,pathlib,shutil,signal,subprocess,tempfile,time,traceback
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M818HHAPS034DN81WTZ21CV8/validation-28ef4849')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.nm-safety-',dir=ROOT/'.phase-test-tmp')); home=lab/'home'
log=(E/'live-publication-safety.log').open('w',buffering=1); procs=[]; results=[]
empty='## In flight\n\n## Queued\n\n## Done\n'
def say(x):log.write(x+'\n'); print(x,flush=True)
def env(**extra):
 e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_')) and k not in ('BASH_ENV','TMUX','TMUX_PANE','REX_SESSION','REX_BLOCK','ORCA_TERMINAL_HANDLE')}
 e.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(ROOT),TMPDIR=str(lab),FM_TEST_SEAM='1',FM_NOW='1000',FM_HOME_SUMMARY_TIMEOUT='120'); e.update(extra); return e
writer=ROOT/'bin/fm-home-summary-refresh.sh'
def run(args,**kw):
 p=subprocess.run([str(x) for x in args],env=env(**kw),capture_output=True,text=True,timeout=200)
 say('$ '+' '.join(map(str,args))+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr); assert p.returncode==0; return p

def start(name,**kw):
 f=(E/(name+'.log')).open('w'); p=subprocess.Popen([str(writer),'--best-effort'],env=env(**kw),stdout=f,stderr=subprocess.STDOUT,start_new_session=True); procs.append((p,f)); return p

def wait_for(fn,what,timeout=120):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if fn():return
  time.sleep(.05)
 raise AssertionError('timed out: '+what)

def finish(p):
 rc=p.wait(timeout=200); say('refresh pid '+str(p.pid)+' exit='+str(rc)); assert rc==0

def state():
 p=home/'state/.home-summary-refresh.backoff'; s=p.read_text() if p.exists() else None
 say('backoff='+str(s)); return s

def stage_has(path,text):return path.exists() and text in path.read_text()

def record(name,fn):
 say('\nSCENARIO '+name)
 try:
  fn(); results.append(dict(name=name,result='pass',live=True,evidence=str(E/'live-publication-safety.log'),reason='Real refresh, real snapshot producer, synthetic backlog, and OS process signals; no replaced dependencies.'))
 except Exception as ex:
  say(traceback.format_exc()); results.append(dict(name=name,result='fail',live=True,evidence=str(E/'live-publication-safety.log'),reason=str(ex)))

def large_backlog():
 (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n'+''.join(f'- [ ] queued-{i} - Synthetic backlog work (repo: firstmate) (kind: ship)\n' for i in range(100000))+'\n## Done\n')

def timeout_scenario():
 before=(home/'state/home-summary.json').read_bytes(); large_backlog()
 a_stage=home/'state/.home-summary-stage.timeout-live'; b_stage=home/'state/.home-summary-stage.timeout-sibling'
 started=time.monotonic(); a=start('live-timeout-A',FM_HOME_SUMMARY_TIMEOUT='20',FM_HOME_SUMMARY_STAGE_PATH=str(a_stage))
 wait_for(lambda:stage_has(a_stage,'producer'),'real slow producer begins',timeout=15)
 say('A stage while active:\n'+a_stage.read_text())
 b=start('live-timeout-B',FM_HOME_SUMMARY_STAGE_PATH=str(b_stage),FM_SNAPSHOT_BUDGET='0')
 wait_for(lambda:stage_has(b_stage,'lock-wait'),'B queues behind slow producer',timeout=15)
 say('B is waiting on the real lock:\n'+b_stage.read_text()); finish(a); finish(b)
 elapsed=time.monotonic()-started; say('both callers completed in '+str(round(elapsed,2))+' seconds (20-second attempt plus bounded diagnostics)')
 assert state()=='failures=1\nnext=1030\n'
 assert (home/'state/home-summary.json').read_bytes()==before
 errors=(home/'state/.home-summary-refresh.log').read_text(); say('failure diagnostics:\n'+errors)
 assert 'deadline' in errors and 'FM_SNAPSHOT_BUDGET must' not in errors
 (home/'data/backlog.md').write_text(empty); run([writer]); assert state() is None
 say('Timeout preserved last good ledger; queued sibling skipped instead of retrying; direct recovery published and reset backoff.')

def interruption_scenario():
 # Stop the process named by the actual publication lock, kill its worker group,
 # then let the prior real producer finish after a replacement has published.
 large_backlog(); stage=home/'state/.home-summary-stage.interrupt-live'
 before=(home/'state/home-summary.json').read_bytes()
 a=start('live-interrupted-A',FM_HOME_SUMMARY_STAGE_PATH=str(stage),FM_HOME_SUMMARY_TIMEOUT='45')
 lock=home/'state/.home-summary-refresh.lock'
 wait_for(lambda:stage_has(stage,'producer') and (lock/'pid').exists(),'worker owns lock and starts real producer',timeout=20)
 owner=int((lock/'pid').read_text().strip()); group=os.getpgid(owner)
 assert group!=os.getpgrp() and owner!=os.getpid()
 os.kill(owner,signal.SIGSTOP); say('Stopped actual lock owner pid='+str(owner)+' pgid='+str(group)+' stage=\n'+stage.read_text())
 os.killpg(group,signal.SIGKILL); finish(a)
 assert (home/'state/home-summary.json').read_bytes()==before
 (home/'data/backlog.md').write_text(empty)
 run([writer],FM_SNAPSHOT_NOW='2026-11-22T12:00:00Z',FM_SNAPSHOT_NOW_EPOCH='1795348800')
 ledger=home/'state/home-summary.json'; newer=ledger.read_bytes(); doc=json.loads(newer)
 assert doc['generated_epoch']==1795348800
 (E/'replacement-home-summary.json').write_bytes(newer)
 # The interrupted producer's own 45-second deadline must expire before judging
 # whether it can overwrite its replacement.
 end=time.monotonic()+50; reads=0
 while time.monotonic()<end:
  assert ledger.read_bytes()==newer,'interrupted attempt overwrote replacement'
  json.loads(ledger.read_bytes()); reads+=1; time.sleep(.2)
 say('Replacement generation stayed '+str(doc['generated_epoch'])+' through '+str(reads)+' complete JSON reads and past the old producer deadline.')
 assert not lock.exists(); say('Publication lock released; no delayed older ledger replacement observed.')
try:
 run([ROOT/'bin/fm-lab-home.sh','create',home]); (home/'data/backlog.md').write_text(empty); run([writer])
 record('Local slow real producer times out without losing the ledger or letting a queued trigger bypass backoff',timeout_scenario)
 record('Local killed lock owner cannot overwrite a newer real publication after its older producer deadline',interruption_scenario)
finally:
 for p,f in procs:
  if p.poll() is None:
   try:os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  f.close()
 shutil.rmtree(lab); say('All driver parents reaped; disposable home removed.')
 (E/'safety-scenarios.json').write_text(json.dumps(results,indent=2));log.close()
