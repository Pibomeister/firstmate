import os, pathlib, subprocess, tempfile, shutil, signal
root=pathlib.Path('{run-worktree}')
ev=pathlib.Path('~/.no-mistakes/evidence/01M8764W99QCM2DVV8CGDR9PCQ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.gotmp-live-',dir=root))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('PI_CODING_AGENT','TMUX','TMUX_PANE'): env.pop(k,None)
env['FM_HOME']=str(lab)
log=[]; server=False; socket_created=False

def run(args, timeout=240):
 p=subprocess.Popen(args,cwd=root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
 try: out=p.communicate(timeout=timeout)[0]
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM)
  try: out=p.communicate(timeout=10)[0]
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGKILL); out=p.communicate()[0]
  log.append('TIMEOUT\n'+out); raise
 log.append('$ '+' '.join(args)+'\n'+out+f'exit_status={p.returncode}\n');print(log[-1],flush=True)
 return p.returncode,out

try:
 assert run(['bash','bin/fm-lab-home.sh','create',str(lab)])[0]==0
 code,socket=run(['bash','bin/fm-lab-home.sh','tmux-dir',str(lab)])
 assert code==0
 socket_created=True; socket=socket.strip()
 assert run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'new-session','-d','-s','fm-lab-gotmp','-x','100','-y','30','sleep 900'])[0]==0
 server=True
 code,tmuxval=run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'display-message','-p','-t','fm-lab-gotmp','#{socket_path},#{pid},#{session_id}'])
 assert code==0
 # tmux clients select this exact lab socket from the first TMUX field.
 env['TMUX']=tmuxval.strip().replace('$',''); env['TMUX_TMPDIR']=socket
 (lab/'config'/'supervision-host-off').touch(); (lab/'config'/'backlog-backend').write_text('manual\n')
 for idx,(actor,kind) in enumerate([(None,'populated'),(None,'absent-field'),(None,'missing-dir'),('main','populated')]):
  if actor: env['FM_SUPERVISION_ACTOR']=actor
  else: env.pop('FM_SUPERVISION_ACTOR',None)
  task=f'gotmp-live-{idx}'; tmp=lab/('fm-'+task); meta=lab/'state'/(task+'.meta')
  sentinel=lab/'unrelated-gotmp-artifact'; sentinel.write_text('preserve\n')
  if kind=='populated':
   (tmp/'gotmp').mkdir(parents=True); (tmp/'gotmp'/'build-artifact').write_text('leftover\n')
  data=f'window=fm-lab-gotmp:fm-{task}\nbackend=tmux\nworktree={lab}/nonexistent-worktree-{idx}\nproject={lab}/nonexistent-project\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\nspawn_gen=s1795539000.12345.{idx}\n'
  if kind!='absent-field': data+=f'tasktmp={tmp}\n'
  meta.write_text(data)
  log.append(f'CASE actor={actor or "UNSET"}; PI_CODING_AGENT=UNSET; tasktmp={kind}; metadata_exists={meta.exists()}; tasktmp_exists={tmp.exists()}\n');print(log[-1],flush=True)
  code,_=run(['bash','bin/fm-teardown.sh',task])
  state=f'AFTER metadata_exists={meta.exists()}; tasktmp_exists={tmp.exists()}; unrelated_content={sentinel.read_text().strip()}\n'
  log.append(state);print(state,flush=True)
  assert code==0 and not meta.exists() and not tmp.exists() and sentinel.read_text()=='preserve\n'
 log.append('All four local CLI filesystem postconditions satisfied; real helpers and tmux backend, no stubs.\n')
finally:
 if server:
  assert run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'kill-server'])[0]==0
 if socket_created:
  assert run(['bash','bin/fm-lab-home.sh','teardown',str(lab)])[0]==0
 shutil.rmtree(lab)
 log.append(f'Disposable lab removed={not lab.exists()}\n')
 (ev/'live-teardown.log').write_text(''.join(log))
