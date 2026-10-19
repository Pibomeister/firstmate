import os, subprocess, time, pathlib, shutil, json
root=pathlib.Path.cwd(); work=root/'.nm-live'; ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5ANWPANR7DV27YPXEKK8Q4R'); lab=work/'home'; gh=work/'grok'
env=os.environ.copy()
for k in list(env):
 if k in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE') or (k.startswith('FM_') and k.endswith('_OVERRIDE')): env.pop(k,None)
env.update(FM_HOME=str(lab),GROK_HOME=str(gh),GROK_AUTH_PATH=os.environ['HOME']+'/.grok/auth.json',GROK_DISABLE_AUTOUPDATER='1',FM_CONTROL_POLL='0.2',FM_CONTROL_EXIT_WAIT='15')
log=[]
def run(args,check=True,timeout=35):
 p=subprocess.run(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n')
 (ev/'control-live.log').write_text('\n'.join(log))
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p

def tm(*args,**kw): return run(['tmux','-S','.nm-live/s',*args],**kw)
def capture(name):
 p=tm('capture-pane','-p','-t','primary:fm-grok'); (ev/(name+'.txt')).write_text(p.stdout);return p.stdout
try:
 run(['bin/fm-lab-home.sh','create',str(lab)]); (lab/'tmux').mkdir(); gh.mkdir(exist_ok=True)
 tm('-f','/dev/null','new-session','-d','-s','primary','-n','fm-grok','-x','72','-y','24','-c',str(root),'-e','FM_HOME='+str(lab),'-e','GROK_HOME='+str(gh),'grok --leader-socket .nm-live/leader.sock; exec bash --noprofile --norc')
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
 (lab/'state/grok.meta').write_text(f'window=primary:fm-grok\nendpoint_task_id=grok\nworktree={root}\nproject={root}\nharness=grok\nkind=scout\nmode=local-only\nmodel=default\neffort=default\nyolo=off\n')
 run(['bash','-c','. bin/fm-tmux-lib.sh; printf "tmux verdict: "; fm_tmux_composer_state primary:fm-grok; printf "\\ncursorless verdict: "; screen=$(fm_tmux_composer_capture primary:fm-grok); fm_composer_classify_screen "styled=1" "$screen"; echo'])
 base=run(['git','show','f4061c74e2e70e73c5ca9b9283a4efb6daacde4b:bin/fm-composer-lib.sh']).stdout
 (work/'base-composer.sh').write_text(base)
 run(['bash','-c','. .nm-live/base-composer.sh; screen=$(tmux capture-pane -e -p -t primary:fm-grok -S 0 -E -); printf "base verdict: "; fm_composer_classify_screen "styled=1" "$screen"; echo'])
 tm('send-keys','-t','primary:fm-grok','-l','draft must survive');time.sleep(0.7);capture('grok-pending')
 p=run(['bin/fm-control.sh','grok','exit'],check=False)
 assert p.returncode !=0 and 'pending text' in p.stdout,p.stdout
 assert 'draft must survive' in capture('grok-after-refused-exit')
 tm('send-keys','-t','primary:fm-grok','C-u');time.sleep(0.5)
 p=run(['bin/fm-control.sh','grok','exit']);assert 'stopped grok harness=grok' in p.stdout,p.stdout
 capture('grok-stopped')
 (ev/'control-live-results.json').write_text(json.dumps({'idle':'pass','base_reproduction':'see transcript','pending_refusal':'pass','exit':'pass'},indent=2))
finally:
 tm('kill-server',check=False)
 for path in (lab,gh): shutil.rmtree(path,ignore_errors=True)
 for name in ('s','leader.sock','base-composer.sh'):
  p=work/name
  if p.exists(): p.unlink()
