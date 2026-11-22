import os,json,time,pathlib,subprocess,signal,traceback,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M816SJHG88GY66TXQVTDXJXE'); L=R/'.test-idle-live'
log=(E/'adversarial-transcript.log').open('w',buffering=1); results=[]
def say(s): print(s,flush=True); print(s,file=log)
def env(h,**kw):
 e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','ORCA_','REX_','HERDR_','CLAUDE_','CODEX_')) and k not in ('TMUX','TMUX_PANE','BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
 e.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',FM_HOME=str(h),CLAUDE_CONFIG_DIR=str(h/'claude'),NM_HOME=str(h/'nm')); e.update({k:str(v) for k,v in kw.items()});return e
def run(args,h,**kw):
 p=subprocess.run([str(x) for x in args],env=env(h,**kw),cwd=R,capture_output=True,text=True,timeout=90)
 say('$ '+' '.join(str(x).replace(str(R),'$WORKTREE') for x in args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode));assert p.returncode==0;return p.stdout
def home(name):
 h=L/name;run(['bin/fm-lab-home.sh','create',h],h);(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n');return h
def atomic(p,obj):q=p.with_suffix('.next');q.write_text(json.dumps(obj));os.replace(q,p)
def record(name,fn):
 try:fn();results.append(dict(name=name,result='pass',live=True));say('SCENARIO PASS: '+name)
 except Exception as e:results.append(dict(name=name,result='fail',live=True,reason=str(e)));say('SCENARIO FAIL: '+name+'\n'+traceback.format_exc())
 (E/'adversarial-results.json').write_text(json.dumps(results,indent=2))
def watchdog():
 base=int(time.time())-3000
 for variant,probes,expect in [('derived',[1300,2671,2672],[False,False,True]),('override',[599,600],[False,True]),('disabled',[3400],[False]),('invalid',[899,900],[False,True])]:
  h=home('watchdog-'+variant);(h/'state/.lock').write_text(str(os.getpid())+'\n');(h/'state/.lock-session').write_text('synthetic-local-session\n')
  cfg='mode=dry-run\nquota-guard=off\nmemory-guard=off\nmodels=\nclaude-config-dirs='+str(h/'claude')+'\n'
  if variant=='override':cfg+='heartbeat-frozen-secs=600\nwatcher-stale-secs=600\n'
  if variant=='disabled':cfg+='heartbeat-frozen-secs=0\n'
  (h/'config/watchdog').write_text(cfg)
  d=dict(schema='fm-heartbeat.v1',generated_epoch=base,published_epoch=base+400,stale_after_secs=2271,primary={})
  if variant=='invalid':d['stale_after_secs']='2271'
  atomic(h/'state/heartbeat.json',d)
  for offset,wanted in zip(probes,expect):
   run(['bin/fm-watchdog.sh','once','--dry-run'],h,FM_TEST_SEAM=1,FM_WD_NOW=base+offset)
   ledger=h/'state/watchdog/actions.tsv';text=ledger.read_text() if ledger.exists() else ''
   detected=any('\theartbeat-frozen\tdetect\theld\t' in r for r in text.splitlines())
   status=(h/'data/watchdog/status.md').read_text()
   say(variant+' generated-age='+str(offset)+' detected='+str(detected)+'\n'+status)
   assert detected==wanted,(variant,offset,wanted,detected)
   if variant=='derived':assert ('watcher heartbeat is' in status)==wanted
   if variant=='override' and wanted:assert 'watcher heartbeat is' in status
   shutil.copy(h/'data/watchdog/status.md',E/('watchdog-'+variant+'-'+str(offset)+'.md'))
  assert (h/'config/watchdog').read_text()==cfg

def timed_collections():
 for mode in ['jitter','slow']:
  h=home('collections-'+mode);launch=h/'snapshot-starts.log'; wrapper=h/'snapshot-delay.sh'
  delay=12 if mode=='slow' else 0
  wrapper.write_text('#!/bin/bash\ndate +%s >> "'+str(launch)+'"\nsleep '+str(delay)+'\nexec "'+str(R/'bin/fm-fleet-snapshot.sh')+'" "$@"\n');wrapper.chmod(0o755)
  kwargs=dict(FM_POLL='.2',FM_SIGNAL_GRACE=0,FM_HEARTBEAT_LEDGER_IDLE_SECS=24 if mode=='jitter' else 2,FM_HEARTBEAT_LEDGER_JITTER=16 if mode=='jitter' else 0,FM_HOME_SUMMARY_INTERVAL=999,FM_HOME_SUMMARY_JITTER=0,FM_HEARTBEAT_SNAPSHOT_SCRIPT=wrapper,FM_HEARTBEAT_SNAPSHOT_TIMEOUT=60,FM_CHECK_INTERVAL=9999999,FM_HEARTBEAT=9999999,FM_WATCH_MANAGED_HOLD=1,FM_TEST_SEAM=1,FM_WATCH_RANDOM_SEED=42)
  out=(E/(mode+'-watcher.log')).open('w');p=subprocess.Popen(['bin/fm-watch.sh'],cwd=R,env=env(h,**kwargs),stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  def starts():return [int(s) for s in launch.read_text().splitlines()] if launch.exists() else []
  try:
   deadline=time.monotonic()+90
   while not starts() and time.monotonic()<deadline:time.sleep(.1)
   assert starts(),'no real collector started'
   if mode=='slow':
    # Three wake producers arrive while a real snapshot call is deliberately slow.
    for i in range(3):run(['/bin/bash','-c','STATE="$FM_HOME/state"; . bin/fm-wake-lib.sh; fm_wake_append check producer "synthetic change"'],h)
    time.sleep(5);assert len(starts())==1,starts()
    say('while first real collection is delayed: three queued changes, one collector launch')
   while len(starts())<3 and time.monotonic()<deadline:
    assert p.poll() is None,'watcher exited';time.sleep(.2)
   assert len(starts())>=3,starts()
   times=starts();gaps=[b-a for a,b in zip(times,times[1:])]
   say(mode+' actual real snapshot invocation epochs='+str(times)+' gaps='+str(gaps))
   if mode=='slow':assert min(gaps)>=12,gaps
   else:assert min(gaps)>=7 and min(gaps)<23 and max(gaps)<=28,gaps
   shutil.copy(launch,E/(mode+'-snapshot-starts.log'))
  finally:
   p.terminate()
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   # Allow the in-flight real publisher to finish its bounded snapshot.
   time.sleep(22)
   try:os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   out.close();say(mode+' watcher stopped and reaped, exit='+str(p.returncode))
record('Real watchdog CLI honors publication deadlines, duration offset, explicit overrides and malformed-bound fallback',watchdog)
record('Real watcher jitter shortens idle gaps and slow real collection coalesces changes without overlap',timed_collections)
log.close()
