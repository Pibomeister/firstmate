import os,pty,fcntl,termios,struct,subprocess,select,time,pathlib,signal,json
root=pathlib.Path.cwd(); lab=root/'.test-validation/live-control-final'; evidence=pathlib.Path(__file__).parent
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
wt=lab/'worktree'; other=lab/'unrelated-worktree'; userhome=lab/'user-home'
for d in (wt,other,userhome): d.mkdir()
id='live-droid-absence'
runenv=os.environ.copy()
for k in ('FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE'):
 runenv.pop(k,None)
runenv['FM_HOME']=str(lab)
gen=subprocess.check_output(['bin/fm-busy-event.sh','arm',str(lab/'state'),id],text=True).strip()
subprocess.run(['bin/fm-busy-event.sh','apply',str(lab/'state'),id,'idle','--gen',gen,'--source','droid-hook','--event','stop'],check=True,capture_output=True)
meta=lab/'state'/f'{id}.meta'; marker=lab/'state'/f'{id}.droid-session-end'
terminal='fm-lab-unregistered-01M61NZTJEF70VE1TJK1B32GGY'
def write_meta(path):
 meta.write_text(f'backend=orca\nendpoint_task_id={id}\nharness=droid\nkind=scout\nwindow=fm-{id}\nterminal={terminal}\norca_worktree_id=fm-lab-unregistered::{path}\nworktree={path}\nproject={path}\nbusy_gen={gen}\n')
write_meta(wt); marker.write_text(gen+'\n')
settings=lab/'settings.json'; settings.write_text('{"statusLine":{"type":"command","command":"printf firstmate"}}\n')
env=runenv.copy(); env.update(HOME=str(userhome),XDG_CONFIG_HOME=str(userhome/'config'),XDG_DATA_HOME=str(userhome/'data'),XDG_CACHE_HOME=str(userhome/'cache'),TERM='xterm-256color',FACTORY_DROID_AUTO_UPDATE_ENABLED='false')
for k in ('TMUX','TMUX_PANE'): env.pop(k,None)
master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
p=subprocess.Popen(['droid','--settings',str(settings)],env=env,cwd=wt,stdin=slave,stdout=slave,stderr=slave,start_new_session=True); os.close(slave)
buf=bytearray(); log=[]; results=[]
def drain(seconds):
 start=time.time()
 while time.time()-start<seconds:
  ready,_,_=select.select([master],[],[],.1)
  if ready:
   try: data=os.read(master,65536)
   except OSError: return
   if not data: return
   buf.extend(data)
def control(name,expect,phrase):
 before=meta.read_bytes(); busy=(lab/'state'/f'{id}.busy-state').read_bytes()
 # Drain the live TUI continuously while the real control CLI reads Orca and lsof.
 command=['bin/fm-control.sh',id,'exit']
 c=subprocess.Popen(command,env=runenv,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 start=time.time()
 while c.poll() is None and time.time()-start<30: drain(.1)
 if c.poll() is None: c.kill(); raise RuntimeError('control timed out')
 out=c.communicate()[0]
 log.append(f'CASE: {name}\nCOMMAND: FM_HOME=<disposable-lab> bin/fm-control.sh {id} exit\n{out}exit_status={c.returncode}\n')
 assert c.returncode==expect and phrase in out,(name,c.returncode,out)
 assert meta.read_bytes()==before
 assert (lab/'state'/f'{id}.busy-state').read_bytes()==busy
 results.append({'case':name,'exit_status':c.returncode,'state_preserved':True})
try:
 drain(8)
 assert p.poll() is None
 ls=subprocess.run(['lsof','-w','-a','-p',str(p.pid),'-d','cwd','-Fn'],text=True,capture_output=True,check=True)
 assert '\nn'+str(wt)+'\n' in ls.stdout
 log.append(f'Real Droid PID={p.pid}; PTY=40x120; no model prompt or login submitted.\n'+ls.stdout)
 control('current SessionEnd marker with surviving Droid in exact worktree',1,'cannot prove the agent stopped')
 write_meta(other)
 control('Droid in another worktree does not block current marker proof',0,'already-stopped')
 write_meta(wt)
 marker.write_text('g-stale-generation\n')
 control('stale SessionEnd marker refuses while Droid survives',1,'cannot prove the agent stopped')
 os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=5); drain(.3)
 control('stale SessionEnd marker also refuses after the real Droid exits',1,'cannot prove the agent stopped')
 marker.write_text(gen+'\n')
 control('current marker and genuinely absent Droid reports already stopped',0,'already-stopped')
 marker.unlink()
 control('missing marker and unreadable real Orca endpoint refuses',1,'cannot prove the agent stopped')
finally:
 if p.poll() is None:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 os.close(master)
 (evidence/'live-control.txt').write_text('\n'.join(log))
 (evidence/'live-control-results.json').write_text(json.dumps(results,indent=2)+'\n')
 (evidence/'live-control-tui.ansi').write_bytes(buf)
print(json.dumps(results,indent=2))
