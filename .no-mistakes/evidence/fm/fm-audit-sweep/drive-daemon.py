import pathlib,subprocess,tempfile,os,time,shutil,json,traceback,signal
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE');W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-daemon-',dir=str(R))); homes=[];p=None;log=(E/'live-daemon-transcript.log').open('w');results=[]
def say(x):log.write(str(x)+'\n');log.flush();print(x,flush=True)
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_')) or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):e.pop(k,None)
def run(cmd,ee=None):
 p=subprocess.run(cmd,env=ee or e,text=True,capture_output=True,timeout=30);say('$ '+' '.join(cmd)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode));assert p.returncode==0;return p.stdout.strip()
def tm(h,*args):return run(['bash','bin/fm-lab-home.sh','tmux',str(h)]+list(args))
try:
 for n in ('own','other'):
  h=W/n;run(['bash','bin/fm-lab-home.sh','create',str(h)]);homes.append(h);tm(h,'new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'/bin/cat')
 h,other=homes; st=h/'state';sock=tm(h,'display-message','-p','#{socket_path}');foreign=tm(other,'display-message','-p','#{socket_path}');target=tm(h,'display-message','-p','#{pane_id}')
 task='paused-proof'; win='foreign:fm-'+task
 (st/(task+'.status')).write_text('paused: awaiting local synthetic service\n')
 meta=st/(task+'.meta')
 def metadata(socket):meta.write_text('kind=ship\nbackend=tmux\nharness=claude\nwindow='+win+'\ntmux_socket='+socket+'\n')
 metadata(foreign); marker=st/('.subsuper-paused-'+task);marker.write_text(str(int(time.time())-100)+'\n')
 ee=e.copy();ee.update(FM_HOME=str(h),TMUX=sock+',1,0',TMUX_PANE=target,FM_SUPERVISOR_BACKEND='tmux',FM_SUPERVISOR_TARGET=target,FM_DAEMON_PRIMARY_HARNESS='claude',FM_HOUSEKEEPING_TICK='1',FM_PAUSE_RESURFACE_SECS='1',FM_ESCALATE_BATCH_SECS='999999',FM_HEARTBEAT_SCAN_SECS='999999',FM_MAX_DEFER_SECS='0',FM_WEDGE_ALARM_EXEC='discard',FM_POLL='1',FM_INTERVAL='1')
 out=(E/'live-daemon-process.log').open('w');p=subprocess.Popen(['bash','bin/fm-supervise-daemon.sh'],env=ee,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 buf=st/'.subsuper-escalations';dl=st/'.supervise-daemon.log'
 deadline=time.monotonic()+180
 while time.monotonic()<deadline:
  text=buf.read_text() if buf.exists() else ''
  if not marker.exists() or 'awaiting local synthetic' in text:break
  assert p.poll() is None, 'daemon exited before classification';time.sleep(.5)
 say('FOREIGN SERVER BUFFER:\n'+text);say('DAEMON LOG:\n'+(dl.read_text() if dl.exists() else 'absent'))
 say('foreign-server pause marker after housekeeping='+str(marker.exists())); assert 'paused worker gone' not in text and not marker.exists()
 results.append({'name':'running daemon preserves external wait for task recorded on another private tmux server','pass':True})
 metadata(sock);marker.write_text(str(int(time.time())-100)+'\n')
 deadline=time.monotonic()+180
 while time.monotonic()<deadline:
  text=buf.read_text() if buf.exists() else ''
  if 'paused worker gone' in text:break
  assert p.poll() is None;time.sleep(.5)
 say('SAME SERVER MISSING ENDPOINT BUFFER:\n'+text);assert 'paused worker gone' in text and 'agent missing' in text
 results.append({'name':'running daemon surfaces a missing paused task on its own private tmux server','pass':True})
except Exception:
 say(traceback.format_exc());results.append({'name':'daemon live driver','pass':False})
finally:
 if p and p.poll() is None:
  p.terminate()
  try:p.wait(timeout=30)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 if p:say('daemon child exit='+str(p.returncode))
 for h in homes:
  try:tm(h,'kill-server');run(['bash','bin/fm-lab-home.sh','teardown',str(h)])
  except Exception as ex:say('cleanup error '+str(ex));results.append({'name':'daemon cleanup','pass':False})
 shutil.rmtree(W);say('Disposed daemon, watcher and both private tmux servers');(E/'live-daemon-results.json').write_text(json.dumps(results,indent=2));log.close()
if any(not x['pass'] for x in results):raise SystemExit(1)
