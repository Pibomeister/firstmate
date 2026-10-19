import os, subprocess, time, pathlib, shutil, json
root=pathlib.Path.cwd(); work=root/'.nm-live'; ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5ANWPANR7DV27YPXEKK8Q4R'); lab=work/'home'; gh=work/'grok'
env=os.environ.copy()
for k in list(env):
 if k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE') or (k.startswith('FM_') and k.endswith('_OVERRIDE')): env.pop(k,None)
env.update(FM_HOME=str(lab),GROK_HOME=str(gh),GROK_AUTH_PATH=os.environ['HOME']+'/.grok/auth.json',GROK_DISABLE_AUTOUPDATER='1',FM_CONTROL_POLL='0.2',FM_CONTROL_EXIT_WAIT='15')
env['CLAUDE_CONFIG_DIR']=str(work/'claude')
env['DISABLE_AUTOUPDATER']='1'
auth=subprocess.run(['security','find-generic-password','-s','Claude Code-credentials','-w'],capture_output=True,text=True,timeout=8)
if auth.returncode==0:
 try:
  token=json.loads(auth.stdout).get('claudeAiOauth',{}).get('accessToken')
  if token:env['CLAUDE_CODE_OAUTH_TOKEN']=token
 except (ValueError,TypeError):pass
print('Existing Claude login reused in memory:',bool(env.get('CLAUDE_CODE_OAUTH_TOKEN')),flush=True)

env['BASH_FUNC_tmux%%']='() { (cd '+str(root)+'; command tmux -S .nm-live/s "$@"); }'
log=[]
def run(args,check=True,timeout=35):
 p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n')
 (ev/'claude-migration-live.log').write_text('\n'.join(log))
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
 tm('-f','/dev/null','new-session','-d','-s','primary','-n','fm-grok','-x','120','-y','40','-c',str(wt),'-e','FM_HOME='+str(lab),'-e','GROK_HOME='+str(gh),'grok --cwd '+str(wt)+' --leader-socket '+str(work/'leader.sock')+'; exec bash --noprofile --norc')
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
 p=run(['bin/fm-control.sh','grok','relaunch','--harness','claude','--note','Disposable validation only. Reply READY and stop. Do not use tools or change files.'],check=False,timeout=120)
 capture('claude-migration-result')
 (ev/'claude-migration-meta.txt').write_text((lab/'state/grok.meta').read_text())
 assert (wt/'draft.txt').read_text()=='must survive migration\n'
 assert p.returncode==0 and 'relaunched grok harness=claude from=grok' in p.stdout,p.stdout
 for i in range(40):
  screen=tm('capture-pane','-p','-t','primary:fm-grok').stdout
  if 'Choose the text style' in screen:tm('send-keys','-t','primary:fm-grok','Enter')
  elif 'Security notes' in screen or 'Press Enter to continue' in screen:tm('send-keys','-t','primary:fm-grok','Enter')
  elif 'Yes, I accept' in screen and 'Bypass' in screen:tm('send-keys','-t','primary:fm-grok','Down','Enter')
  elif 'READY' in screen:break
  time.sleep(1)
 capture('claude-after-migration')
 status=run(['claude','auth','status','--json'],check=False)
 (ev/'claude-isolated-auth-status.json').write_text(status.stdout)

 (ev/'claude-migration-live-results.json').write_text(json.dumps({'claude_process_migration':'pass','draft_preserved':'pass'},indent=2))
finally:
 tm('kill-server',check=False)
 time.sleep(2)
 for path in (lab,gh,proj,wt):
  if path.exists():
   for d,dirs,files in os.walk(path):os.chmod(d,0o700)
   shutil.rmtree(path)
 for name in ('s','leader.sock','base-composer.sh'):
  p=work/name
  if p.exists(): p.unlink()
