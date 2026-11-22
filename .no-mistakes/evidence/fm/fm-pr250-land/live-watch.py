import os,pathlib,subprocess,json,signal,shutil,time,re
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M80NZYVR53SZKKBMXS7ZM9VE'); L=R/'.test-watch-live'; H=L/'home'; L.mkdir()
e=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','ORCA_TERMINAL_HANDLE','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']:
 e.pop(k,None)
e.update(FM_HOME=str(H),FM_WATCH_HANDLING_SUCCESSOR='1',FM_WATCH_ONCE='1',FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WORKTREE_CLEANUP='0',FM_WEDGE_ALARM_CHANNEL='off',SHELL='/bin/bash')
log=(E/'live-watch-transcript.log').open('w',buffering=1);sock=None;results=[]
def run(args,extra=None,limit=180):
 log.write('\n$ '+' '.join(map(str,args))+'\n'); env=e.copy();env.update(extra or {})
 p=subprocess.Popen(list(map(str,args)),cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try: out=p.communicate(timeout=limit)[0]
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM)
  try:out=p.communicate(timeout=15)[0]
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);out=p.communicate()[0]
  log.write(out+'\nTIMEOUT\n');raise RuntimeError('timeout '+str(args))
 log.write(out+'\nexit='+str(p.returncode)+'\n')
 if p.returncode:raise RuntimeError('exit '+str(p.returncode)+' '+str(args))
 return out

def record(id,priority,status):
 (H/'state'/f'{id}.meta').write_text(f'window=watch:fm-{id}\nbackend=tmux\nkind=ship\nharness=codex\npriority={priority}\n')
 (H/'state'/f'{id}.status').write_text(status)
 run(['tmux','-S',sock,'new-window','-d','-t','watch','-n','fm-'+id,'/bin/bash --noprofile --norc'])
def prime():
 for f in (H/'state').glob('*.status'):
  if os.access(f,os.R_OK):run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$3"','_',R,H/'state',f])
def alarms():
 f=H/'state/.wake-queue'
 return [line for line in f.read_text().splitlines() if ' (P0 blocker ' in line] if f.exists() else []
def tick(now,want):
 prime();before=len(alarms());out=run(['bash','bin/fm-watch.sh'],{'FM_WATCH_NOW':str(now)},limit=240)
 after=alarms();log.write('\nPERSISTED P0 WAKE ROWS\n'+'\n'.join(after)+'\n')
 assert len(after)-before==want,(now,before,len(after),want)
 return out
try:
 run(['bash','bin/fm-lab-home.sh','create',H]);(L/'user').mkdir();e['HOME']=str(L/'user')
 sd=run(['bash','bin/fm-lab-home.sh','tmux-dir',H]).strip();sock=pathlib.Path(sd)/('tmux-'+str(os.getuid()))/'default'
 run(['bash','bin/fm-lab-home.sh','tmux',H,'new-session','-d','-s','watch','-n','primary','-x','120','-y','40','/bin/bash --noprofile --norc'])
 pid=run(['tmux','-S',sock,'display-message','-p','#{pid}']).strip();e['TMUX']=str(sock)+','+pid+',0'
 record('p0',0,'blocked [key=deploy] [at=1000]: synthetic deployment key missing\nblocked [key=network] [at=1000]: synthetic network route missing\n')
 for p in range(1,5):record('p'+str(p),p,'blocked [at=1000]: lower-priority synthetic blocker\n')
 record('question',0,'needs-decision [key=region] [at=1000]: synthetic region choice\n')
 tick(1599,0)
 with (H/'state/p0.status').open('a') as f:f.write('blocked [key=deploy] [at=1500]: synthetic deployment key still missing\n')
 out=tick(1600,2)
 assert 'open for 600s: blocked [key=deploy] [at=1500]' in out
 assert 'open for 600s: blocked [key=network] [at=1000]' in out
 results.append(dict(name='local-p0-boundary-and-exclusions',result='pass',detail='Full real watcher queues both synthetic P0 blockers at 600s, none at 599s; updated note keeps opening age; P1-P4 and needs-decision create no alarm.'))
 # Replace the recorded endpoint with another real shell, retain task/status.
 run(['tmux','-S',sock,'new-window','-d','-t','watch','-n','fm-p0-replacement','/bin/bash --noprofile --norc'])
 mp=H/'state/p0.meta';mp.write_text(mp.read_text().replace('watch:fm-p0\n','watch:fm-p0-replacement\n'))
 tick(1700,0)
 marker=H/'state/.p0-blocker-surfaced-p0';saved=marker.read_bytes();sf=H/'state/p0.status'
 sf.chmod(0);tick(1800,0);assert marker.read_bytes()==saved;sf.chmod(0o644)
 tick(1900,0)
 with sf.open('a') as f:f.write('resolved [key=deploy] [at=1950]: synthetic key supplied\nblocked [key=deploy] [at=2000]: synthetic key missing again\n')
 tick(2599,0);out=tick(2600,1);assert 'open for 600s: blocked [key=deploy] [at=2000]' in out
 results.append(dict(name='local-p0-once-per-opening',result='pass',detail='Full watcher retains marker across real endpoint replacement and chmod-000 status; same opening queues no repeat; resolved/reopened blocker queues exactly one new alarm.'))
 # Real queue drain must retain different P0 payloads sharing one endpoint.
 drained=run(['bash','bin/fm-wake-drain.sh'])
 assert 'synthetic deployment key still missing' in drained and 'synthetic network route missing' in drained
 results.append(dict(name='local-p0-queue-delivery',result='pass',detail='Real wake drain presents both distinct P0 alarm payloads for the same task; no alarm is collapsed.'))
except Exception as exc:
 log.write('\nLIVE PROBE ERROR '+repr(exc)+'\n');results.append(dict(name='remaining-local-watcher',result='error',detail=str(exc)))
finally:
 if sock:
  try:run(['tmux','-S',sock,'kill-server'],limit=30)
  except Exception as ex:log.write('cleanup tmux '+str(ex)+'\n')
  try:run(['bash','bin/fm-lab-home.sh','teardown',H],limit=30)
  except Exception as ex:log.write('cleanup socket '+str(ex)+'\n')
 shutil.rmtree(L);log.write('\nCLEANUP disposable watcher lab removed.\n');log.close()
 (E/'live-watch-results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
