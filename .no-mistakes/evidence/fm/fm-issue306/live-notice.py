import pathlib,subprocess,os,time,json,signal
root=pathlib.Path.cwd();lab=root/'.test-306/status';home=root/'.test-306/noticehome2';ev=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS')
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True)
(home/'state'/'park.status').write_text('paused: waiting for the parked test step\n')
socketdir=subprocess.check_output(['bin/fm-lab-home.sh','tmux-dir',str(home)],text=True).strip()
env=os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','CLAUDECODE']:env.pop(key,None)
env.update(FM_HOME=str(home),TMUX_TMPDIR=socketdir,NM_HOME=str(lab/'nm'),FM_POLL='1',FM_STALE_ESCALATE_SECS='2',FM_SIGNAL_GRACE='0',FM_TASK_INBOX_GRACE_SECS='99999',FM_CREW_STATE_NM_TIMEOUT='60',FM_PARKED_GATE_READ_TIMEOUT='60',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
def tmux(*args,check=True):return subprocess.run(['tmux','-L','fm-lab',*args],env=env,capture_output=True,text=True,check=check)
watch=None
try:
 tmux('new-session','-d','-s','primary','-n','fm-park','-x','160','-y','45','-c',str(root),'-e','FM_HOME='+str(home),'claude')
 socketpath=socketdir+'/tmux-'+str(os.getuid())+'/fm-lab';env['TMUX']=socketpath+',0,0'
 (home/'state'/'park.meta').write_text(f'worktree={lab/"repo"}\nkind=ship\nbackend=tmux\nwindow=primary:fm-park\nharness=claude\n')
 for i in range(30):
  screen=tmux('capture-pane','-p','-t','primary').stdout
  if '❯' in screen or 'trust' in screen.lower():break
  time.sleep(1)
 (ev/'notice-pane-before.txt').write_text(screen)
 print('Real Claude pane before watcher:\n'+screen,flush=True)
 # No trust choice is persisted by this check. The watcher must leave a dialog alone.
 subprocess.run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/park.status"'],env=env,check=True)
 (home/'state'/'.last-heartbeat').touch()
 (home/'state'/'.last-check').touch()
 log=open(ev/'live-watcher.log','w')
 watch=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 deadline=time.monotonic()+70;count=0
 while time.monotonic()<deadline:
  count=len(list((home/'state'/'park.inbox').glob('*.msg')))
  if count>=1:break
  if watch.poll() is not None:
   assert watch.returncode==0, 'watcher failed'
   print('Restarting one-shot watcher after surfaced status event',flush=True)
   watch=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  time.sleep(1)
 print('watcher first observation: inbox records='+str(count)+' process='+str(watch.poll()),flush=True)
 if count!=1:
  print((ev/'live-watcher.log').read_text(),flush=True)
  raise RuntimeError('watcher did not issue one parked notice')
 # Force an elapsed-time change at the actual database boundary, then let the
 # unchanged paused declaration be reread by a later watcher poll.
 import sqlite3
 with sqlite3.connect(lab/'nm/state.sqlite') as db:db.execute('UPDATE runs SET awaiting_agent_since=awaiting_agent_since-300')
 (home/'state'/'.nm-status-snapshot.json').unlink(missing_ok=True)
 time.sleep(12)
 count2=len(list((home/'state'/'park.inbox').glob('*.msg')))
 print('after parked duration grew by five minutes: inbox records='+str(count2),flush=True)
 assert count2==1,count2
 for f in sorted((home/'state'/'park.inbox').glob('*.msg')):print('Persisted steering record:\n'+f.read_text(),flush=True)
 print('Marker:\n'+'\n'.join(f.read_text() for f in (home/'state').glob('.paused-gate-*')),flush=True)
 print('Real Claude pane after watcher:\n'+tmux('capture-pane','-p','-t','primary').stdout,flush=True)
finally:
 if watch is not None and watch.poll() is None:
  os.killpg(watch.pid,signal.SIGTERM)
  try:watch.wait(timeout=12)
  except subprocess.TimeoutExpired:os.killpg(watch.pid,signal.SIGKILL);watch.wait()
 if watch is not None:print('watcher stopped exit='+str(watch.returncode),flush=True)
 tmux('kill-server',check=False)
 subprocess.run(['bin/fm-lab-home.sh','teardown',str(home)],check=True)
