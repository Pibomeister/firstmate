import os, pathlib, subprocess as sp, shutil, time, shlex
R=pathlib.Path.cwd(); D=R/'.nm-herdr'; E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5AFK2TPKC9RPH7650Q60P7C/fresh'); S=(D/'session').read_text().strip(); H=R/'bin/fm-herdr-lab.sh'
env=os.environ.copy(); env['FM_HERDR_LAB_STATE_DIR']=str(D)
for k in list(env):
 if k.startswith('HERDR_') or (k.startswith('FM_') and k.endswith('_OVERRIDE')): env.pop(k,None)
def run(args,check=True):
 p=sp.run(args,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=30)
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p.stdout
def lab(*a): return run([str(H),'run',S,*a])
log=[]
run([str(H),'provision',S])
try:
 U=D/'user'; (U/'.grok').mkdir(parents=True,exist_ok=True)
 shutil.copyfile(pathlib.Path(os.environ['HOME'])/'.grok/auth.json',U/'.grok/auth.json'); (U/'.grok/auth.json').chmod(0o600)
 P=D/'project'; P.mkdir(exist_ok=True); run(['git','init','-q',str(P)])
 import json
 ws=json.loads(lab('workspace','create','--cwd',str(P),'--label','grok-footer-lab','--env','HOME='+str(U),'--env','GROK_HOME='+str(U/'.grok'),'--no-focus'))
 pane=ws['result']['root_pane']['pane_id']; target=S+':'+pane
 lab('pane','run',pane,'grok --always-approve --leader-socket leader.sock')
 B=D/'bin'; B.mkdir(exist_ok=True); wrapper=B/'herdr'; original=os.environ['PATH']
 wrapper.write_text('#!/bin/bash\nargs=("$@")\nn=${#args[@]}\nif [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = '+shlex.quote(S)+' ]; then\nargs=("${args[@]:0:$((n-2))}")\nelse exit 98; fi\nexec env PATH='+shlex.quote(original)+' '+shlex.quote(str(H))+' run '+shlex.quote(S)+' "${args[@]}"\n'); wrapper.chmod(0o755)
 def classify():
  env['PATH']=str(B)+':'+original
  try: return run(['bash','-c','. bin/backends/herdr.sh; fm_backend_herdr_composer_state "$1"','probe',target]).strip()
  finally: env['PATH']=original
 for _ in range(30):
  v=classify()
  if v=='empty':break
  time.sleep(1)
 screen=lab('pane','read',pane,'--source','visible'); (E/'herdr-grok-idle.txt').write_text(screen)
 log.append('Real Herdr Grok idle composer='+v); assert v=='empty',screen
 lab('pane','send-text',pane,'FM_HERDR_DRAFT_KEEP'); time.sleep(.5)
 v=classify(); log.append('Real Herdr Grok typed composer='+v); (E/'herdr-grok-draft.txt').write_text(lab('pane','read',pane,'--source','visible')); assert v=='pending'
 lab('pane','send-keys',pane,'ctrl+u'); time.sleep(.5); v=classify(); log.append('Real Herdr Grok cleared composer='+v); assert v=='empty'
 log.append('PASS: real named Herdr lab idle/draft/cleared classification.')
finally:
 log.append(run([str(H),'teardown',S])); (E/'herdr-live.log').write_text('\n'.join(log)); print('\n'.join(log),flush=True)
