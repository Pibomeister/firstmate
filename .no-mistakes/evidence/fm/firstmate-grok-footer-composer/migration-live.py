import os, subprocess, time, pathlib, shutil, json, shlex
root=pathlib.Path.cwd(); work=root/'.nm-live'; ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5ANWPANR7DV27YPXEKK8Q4R'); lab=work/'home'; gh=work/'grok'
env=os.environ.copy()
for k in list(env):
 if k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE') or (k.startswith('FM_') and k.endswith('_OVERRIDE')): env.pop(k,None)
env.update(FM_HOME=str(lab),GROK_HOME=str(gh),GROK_AUTH_PATH=os.environ['HOME']+'/.grok/auth.json',GROK_DISABLE_AUTOUPDATER='1',FM_CONTROL_POLL='0.2',FM_CONTROL_EXIT_WAIT='15')
env['PATH']=str(work/'bin')+os.pathsep+env['PATH']
env['BASH_FUNC_tmux%%']='() { (cd '+str(root)+'; command tmux -S .nm-live/s "$@"); }'
log=[]
def run(args,check=True,timeout=35):
 p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n')
 (ev/'migration-live.log').write_text('\n'.join(log))
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p

def tm(*args,**kw): return run(['tmux','-S','.nm-live/s',*args],**kw)
def capture(name):
 p=tm('capture-pane','-p','-t','primary:fm-grok'); (ev/(name+'.txt')).write_text(p.stdout);return p.stdout
try:
 proj=work/'fixture-project'; wt=work/'fixture-worktree'
 run(['git','init',str(proj)]); run(['git','-C',str(proj),'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','core.hooksPath=/dev/null','commit','--allow-empty','-m','Create disposable migration fixture'])
 run(['git','-C',str(proj),'worktree','add','-b','lab-migration',str(wt)])
 (wt/'draft.txt').write_text('must survive migration\n')
 run(['bin/fm-lab-home.sh','create',str(lab)]); (lab/'tmux').mkdir(); gh.mkdir(exist_ok=True)
 tm('-f','/dev/null','new-session','-d','-s','primary','-n','fm-grok','-x','120','-y','40','-c',str(wt),'-e','FM_HOME='+str(lab),'-e','GROK_HOME='+str(gh),'export PATH='+shlex.quote(env['PATH'])+'; grok --cwd '+str(wt)+' --leader-socket '+str(work/'leader.sock')+'; exec bash --noprofile --norc')
 tm('set-option','-t','primary:fm-grok','automatic-rename','off')
 env['TMUX']=tm('display-message','-p','-t','primary:fm-grok','#{socket_path},#{pid},0').stdout.strip()
 for i in range(35):
  s=tm('capture-pane','-p','-t','primary:fm-grok').stdout
  if 'Do you trust the contents' in s: tm('send-keys','-t','primary:fm-grok','y'); time.sleep(1)
  if 'Grok 4.' in s and '╰' in s: break
  time.sleep(1)
 else: capture('grok-startup-blocker');raise RuntimeError('Grok did not reach composer')
 capture('grok-idle')
 styled=tm('capture-pane','-e','-p','-t','primary:fm-grok','-S','0','-E','-').stdout
 (ev/'grok-idle.ansi').write_text(styled)
 (lab/'state/grok.meta').write_text(f'window=primary:fm-grok\nendpoint_task_id=grok\nworktree={wt}\nproject={proj}\nharness=grok\nkind=scout\nmode=local-only\nmodel=default\neffort=default\nyolo=off\n')
 (lab/'data/grok').mkdir()
 (lab/'data/grok/brief.md').write_text('# Task\n\nReply READY and stop. Do not use tools. Do not edit files.\n')
 p=run(['bin/fm-control.sh','grok','relaunch','--harness','codex','--note','Disposable validation only. Reply READY and stop. Do not use tools or change files.'],check=False,timeout=120)
 capture('codex-migration-result')
 (ev/'migration-meta.txt').write_text((lab/'state/grok.meta').read_text())
 assert (wt/'draft.txt').read_text()=='must survive migration\n'
 assert p.returncode==0 and 'relaunched grok harness=codex from=grok' in p.stdout,p.stdout
 for i in range(35):
  screen=tm('capture-pane','-p','-t','primary:fm-grok').stdout
  if 'READY' in screen:break
  time.sleep(1)
 capture('codex-after-migration')
 (ev/'migration-live-results.json').write_text(json.dumps({'codex_migration':'pass','draft_preserved':'pass'},indent=2))
finally:
 pane=tm('display-message','-p','-t','primary:fm-grok','#{pane_pid}',check=False).stdout.strip()
 if pane.isdigit():
  pairs=[line.split() for line in subprocess.check_output(['ps','-Ao','pid=,ppid='],text=True).splitlines()]
  owned={int(pane)}
  while True:
   expanded=owned|{int(pid) for pid,ppid in pairs if int(ppid) in owned}
   if expanded==owned:break
   owned=expanded
  for pid in sorted(owned,reverse=True):
   try:os.kill(pid,15)
   except ProcessLookupError:pass
 tm('kill-server',check=False)
 time.sleep(2)
 for path in (lab,gh,proj,wt):
  if path.exists():
   for d,dirs,files in os.walk(path):os.chmod(d,0o700)
   shutil.rmtree(path)
 for name in ('s','leader.sock','base-composer.sh'):
  p=work/name
  if p.exists(): p.unlink()
