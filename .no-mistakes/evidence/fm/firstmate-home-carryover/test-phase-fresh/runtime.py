import os, subprocess, pathlib, json, shlex, shutil, time, signal, hashlib
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5TWX28QV7MK1HBVJB807Z3Q/test-phase-fresh'); L=R/'.r'; L.mkdir(mode=0o700)
records=[]
def run(args, env=None, timeout=25):
 p=subprocess.Popen(args,cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try: o=p.communicate(timeout=timeout)[0]
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM)
  try: o=p.communicate(timeout=5)[0]
  except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); o=p.communicate()[0]
 return p.returncode,o
for name in ['fm-lab-exit-relaunch','fm-lab-refuse-duplicate']:
 lab=L/name; lab.mkdir(); run(['bin/fm-lab-home.sh','create',str(lab)])
 policy=lab/'boundary.sb'; policy.write_text('(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath "'+str(R)+'"))\n(allow file-write* (literal "/dev/null"))\n(deny mach-lookup)\n(deny network*)\n(allow network-outbound (remote ip "localhost:*"))\n(allow network-inbound (local ip "localhost:*"))\n')
 (E/(name+'.sb')).write_text(policy.read_text())
 env=dict(os.environ,HOME=str(lab),XDG_CONFIG_HOME=str(lab/'config'),XDG_DATA_HOME=str(lab/'data'),XDG_CACHE_HOME=str(lab/'cache'),TMPDIR=str(R/'.test-validation/tmp'))
 args=['sandbox-exec','-f',str(policy),'orca','serve','--project-root',str(lab),'--no-pairing','--json']
 rc,out=run(args,env); (E/(name+'.log')).write_text(out)
 rec=dict(scenario=name,command=shlex.join(args),exit_code=rc,output=out,isolated_home=str(lab)); records.append(rec); print(json.dumps(rec),flush=True)
# Copy only supported credentials. Never publish them or submit a model request.
auth=pathlib.Path(os.environ.get('FM_GROK_AUTH_FILE',str(pathlib.Path.home()/'.grok/auth.json')))
g=L/'grok'; g.mkdir(); run(['git','init','-q',str(g)])
for n in ['home','gh','config','data','cache']: (g/n).mkdir(mode=0o700)
cred=auth.is_file() and os.access(auth,os.R_OK)
if cred:
 digest=hashlib.sha256(auth.read_bytes()).hexdigest(); shutil.copyfile(auth,g/'gh/auth.json'); (g/'gh/auth.json').chmod(0o600)
env=dict(os.environ,HOME=str(g/'home'),GROK_HOME=str(g/'gh'),XDG_CONFIG_HOME=str(g/'config'),XDG_DATA_HOME=str(g/'data'),XDG_CACHE_HOME=str(g/'cache'),TMPDIR=str(R/'.test-validation/tmp'),TERM='xterm-256color')
for k in list(env):
 if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','GROK_AGENT']: env.pop(k,None)
socket=str(L/'t'); args=['grok','--cwd',str(g),'--no-alt-screen','--leader-socket',str(L/'g')]
def tm(args): return run(['tmux','-S',socket,*args],env,10)
rec=dict(scenario='grok-idle-and-weekly-choice',command=shlex.join(args),rows=36,columns=116,credentials_available=cred,input_sent=[])
try:
 rc,out=tm(['-f','/dev/null','new-session','-d','-s','fm-lab-grok','-x','116','-y','36','-c',str(g),shlex.join(args)]); rec['start_exit']=rc
 if rc: raise RuntimeError(out)
 for i in range(4):
  time.sleep(4)
  rc,screen=tm(['capture-pane','-p','-t','fm-lab-grok','-S','-100'])
  if 'Do you trust the contents of this directory?' in screen and str(g) in screen and not rec['input_sent']:
   (E/'grok-lab-trust.txt').write_text(screen); tm(['send-keys','-t','fm-lab-grok','y']); rec['input_sent'].append('y: trust disposable directory only')
 (E/'grok-idle.txt').write_text(screen)
 _,ansi=tm(['capture-pane','-e','-p','-t','fm-lab-grok','-S','-100']); (E/'grok-idle.ansi').write_text(ansi)
 cmd=['bash','-c','. bin/fm-composer-lib.sh; screen=$(cat "$1"); printf "classifier="; fm_composer_classify_screen "styled=0" "$screen"; printf "dialog="; fm_composer_blocking_dialog "$screen"; printf "dialog_exit=%s\\n" "$?"','_',str(E/'grok-idle.txt')]
 rc,out=run(cmd,env); rec['classification']=out; rec['capture_exit']=rc
 (E/'grok-result.log').write_text(out); print(screen,flush=True); print(out,flush=True)
finally:
 rec['cleanup']=tm(['kill-server'])[0]; rec['original_auth_unchanged']=not cred or hashlib.sha256(auth.read_bytes()).hexdigest()==digest; records.append(rec)
 (E/'runtime-receipt.json').write_text(json.dumps(records,indent=2))
 shutil.rmtree(L)
