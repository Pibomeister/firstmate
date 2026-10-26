import os,pathlib,subprocess,json,time,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5TWX28QV7MK1HBVJB807Z3Q/test-phase-fresh'); C=json.loads((E/'codex-running.json').read_text()); L=pathlib.Path(C['lab']); env=dict(os.environ,**C['env']); socket=C['socket']; target='fm-lab-codex:fm-codexcheck'; rows=[]
for k in list(env):
 if k.startswith('FM_') or k in ['TMUX','TMUX_PANE']: env.pop(k,None)
def tm(*args):
 p=subprocess.run(['tmux','-S',socket,*args],env=env,cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
 if p.returncode: raise RuntimeError(p.stdout)
 return p.stdout
try:
 tm('rename-window','-t','fm-lab-codex','fm-codexcheck')
 pid=tm('display-message','-p','-t',target,'#{pid}').strip(); env['TMUX']=socket+','+pid+',0'
 def cap(name):
  text=tm('capture-pane','-p','-t',target); ansi=tm('capture-pane','-e','-p','-t',target); (E/(name+'.txt')).write_text(text); (E/(name+'.ansi')).write_text(ansi)
  cmd='''. bin/fm-tmux-lib.sh; . bin/fm-composer-lib.sh
for mode in 0 1; do
 caps=$(printf 'styled=%s\\ncursor=0\\nidentity=0\\nrows=160' "$mode")
 file=$1; [ "$mode" = 0 ] || file=$2
 screen=$(cat "$file")
 verdict=$(fm_composer_classify_screen "$caps" "$screen")
 content=$(fm_composer_extract_selected_content "$caps" "$screen")
 printf 'styled=%s verdict=%s content=%s\\n' "$mode" "$verdict" "$content"
done
printf 'tmux='; fm_tmux_composer_state "$3"; printf '\\n'
'''
  p=subprocess.run(['bash','-c',cmd,'_',str(E/(name+'.txt')),str(E/(name+'.ansi')),target],env=env,cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
  (E/(name+'-result.log')).write_text(p.stdout); row=dict(name=name,command='real Codex paste; capture-pane; fm_composer_classify_screen / fm_composer_extract_selected_content / fm_tmux_composer_state',result=p.stdout,exit_code=p.returncode); rows.append(row); print(json.dumps(row),flush=True); return text
 cap('codex-idle')
 for name,draft in [('codex-footer-prefix','\n? for shortcuts is my first question\nexplain them'),('codex-footer-row','\n? for shortcuts\nexplain them'),('codex-duplicate-footer','\n? for shortcuts'),('codex-status-draft','\nContext 77% left'),('codex-placeholder-extension','Ask Codex to do anything now')]:
  tm('set-buffer','--',draft); tm('paste-buffer','-p','-t',target); time.sleep(1); cap(name)
  if name=='codex-status-draft':
   lab=L/'lab'; subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],cwd=R,check=True,stdout=subprocess.PIPE)
   meta='task_id=codexcheck\nbackend=tmux\nwindow='+target+'\nharness=codex\nkind=ship\nworktree='+str(L/'project')+'\nproject='+str(L/'project')+'\ntmux_socket='+socket+'\n'
   (lab/'state/codexcheck.meta').write_text(meta)
   ce=dict(env,FM_HOME=str(lab),FM_CONTROL_EXIT_WAIT='2',FM_CONTROL_POLL='0.1')
   p=subprocess.run(['bin/fm-control.sh','codexcheck','exit'],env=ce,cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
   (E/'codex-control-refusal.log').write_text('exit_code='+str(p.returncode)+'\n'+p.stdout); after=cap('codex-after-refusal'); rows.append(dict(name='control-refusal',exit_code=p.returncode,output=p.stdout,draft_retained='Context 77% left' in after,quit_inserted='/quit' in after)); print(json.dumps(rows[-1]),flush=True)
  tm('send-keys','-t',target,'C-c'); time.sleep(1)
finally:
 try: tm('kill-server')
 except Exception: pass
 (E/'codex-receipt.json').write_text(json.dumps(rows,indent=2)); shutil.rmtree(L)
