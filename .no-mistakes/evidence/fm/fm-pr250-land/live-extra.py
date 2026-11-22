import pathlib, os, subprocess, time, shutil, json, threading
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN'); scratch=root/'.test-live-extra'; lab=scratch/'home'; project=scratch/'project'
scratch.mkdir(); log=(ev/'live-extra-transcript.log').open('w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_','GIT_')) or k in ['TMUX','TMUX_PANE','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK']:env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1',HOME=str(scratch/'user-home'),SHELL='/bin/bash',TREEHOUSE_ROOT=str(scratch/'pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid',DISABLE_AUTOUPDATER='1')
def run(args,expected=0,timeout=300,cwd=None):
 log.write('$ '+' '.join(map(str,args))+'\n'); p=subprocess.run(list(map(str,args)),env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);log.write(p.stdout+f'EXIT {p.returncode}\n');assert p.returncode==expected,p.stdout;return p.stdout
def tm(*a):return run(['bash',root/'bin/fm-lab-home.sh','tmux',lab,*a])
def brief(task,kind='ship',p=None):
 d=lab/'data'/task;d.mkdir();(d/'brief.md').write_text('# Task\n## Captain\'s intent\nStart a local terminal worker for a disposable admission check.\n\n## Firstmate spec\nUse only the disposable fixture.\n\n# Definition of done\nDelivery contract: mode=local-only\n')
 args=['tasks-axi','add',task,'Disposable admission proof','--kind',kind,'--file',lab/'data/backlog.md']
 if p is not None:args+=['--priority',str(p)]
 run(args)
def spawn(task,p=None,kind='ship',expected=0,raw=True):
 args=['bash','bin/fm-spawn.sh',task,project]
 if raw:args+=['/bin/bash -c \'echo REAL-SHELL-WORKER-READY; while read -r line; do echo shell-received; done\'']
 if kind=='ship':args+=['--mode','local-only','--yolo','off']
 else:args+=['--scout']
 if p is not None:args+=['--priority',str(p)]
 return run(args,expected,timeout=400)
def snapshot(task):
 text=(lab/'state'/f'{task}.meta').read_text();(ev/f'spawn-{task}.meta.txt').write_text(text);log.write('PERSISTED TASK\n'+text);return dict(x.split('=',1) for x in text.splitlines() if '=' in x)
try:
 run(['bash','bin/fm-lab-home.sh','create',lab]);(scratch/'user-home').mkdir();project.mkdir()
 run(['git','init','-q','-b','main',project]);(project/'README.md').write_text('Disposable local admission fixture.\n');run(['git','-C',project,'add','README.md']);run(['git','-C',project,'commit','-qm','Fixture']);run(['git','clone','--bare','-q',project,scratch/'origin.git']);run(['git','-C',project,'remote','add','origin',scratch/'origin.git']);run(['git','-C',project,'fetch','-q','origin']);run(['git','-C',project,'remote','set-head','origin','main'])
 (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n');(lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n');(lab/'config/crew-harness').write_text('codex\n');(lab/'config/project-capacity').write_text('project 1\n');(lab/'config/lane-capacity').write_text('1\nmax-load1 0.01\n');(lab/'state/.last-watcher-beat').touch()
 tm('new-session','-d','-s','proof','-n','fm-ordinary','-x','120','-y','40',f'/bin/bash -c "while :; do echo progress >> {scratch}/progress; sleep 1; done"');tm('set-option','-g','default-shell','/bin/bash');tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
 socket=(lab/'state/.fm-lab-tmux-dir').read_text().strip()+f'/tmux-{os.getuid()}/default';server=tm('display-message','-p','#{pid}').strip();env['TMUX']=f'{socket},{server},0'
 (lab/'state/holder.meta').write_text(f'window=proof:fm-ordinary\nbackend=tmux\nkind=ship\nharness=bash\nproject={project}\nworktree={project}\n')
 before=(scratch/'progress').read_text().count('\n')
 brief('race',p=0);results={}
 def launch():
  try:results['out']=spawn('race',0)
  except BaseException as e:results['error']=repr(e)
 t=threading.Thread(target=launch);t.start()
 try:
  for i in range(120):
   windows=tm('list-windows','-t','proof','-F','#{window_name}')
   if 'fm-race' in windows.splitlines():break
   time.sleep(0.5)
  else:raise AssertionError('race endpoint did not start')
  run(['tasks-axi','update','race','--priority','3','--file',lab/'data/backlog.md'])
 finally:t.join(timeout=450)
 assert not t.is_alive();assert 'error' not in results,results
 assert 'priority changed while its worker started' in results['out']
 m=snapshot('race');assert m['priority']=='3';assert 'REAL-SHELL-WORKER-READY' in tm('capture-pane','-p','-t',m['window'])
 row=run(['tasks-axi','show','race','--file',lab/'data/backlog.md']);assert 'state: in_flight' in row
 run(['bash','bin/fm-afk-contract.sh','enter','--words','Run the disposable prioritized order only.','--spend','1'])
 brief('ordinary-away');out=spawn('ordinary-away',expected=1);assert 'caps concurrent workers' in out;assert not (lab/'state/ordinary-away.meta').exists()
 brief('priority-away',p=1);out=spawn('priority-away',1);assert 'caps concurrent workers' not in out;m=snapshot('priority-away');assert m['priority']=='1';assert 'REAL-SHELL-WORKER-READY' in tm('capture-pane','-p','-t',m['window'])
 assert (scratch/'progress').read_text().count('\n')>before
 (ev/'live-extra-result.json').write_text(json.dumps({'result':'pass','surface':'real tasks-axi reprioritization concurrent with real spawn; real away spend contract and real raw shell workers'},indent=2))

finally:
 try:tm('kill-server')
 except Exception as e:log.write('cleanup '+str(e)+'\n')
 try:run(['bash','bin/fm-lab-home.sh','teardown',lab])
 finally:
  for d,_,_ in os.walk(scratch,followlinks=False):
   q=pathlib.Path(d)
   if not q.is_symlink():q.chmod(q.stat().st_mode|0o700)
  shutil.rmtree(scratch);log.close()
