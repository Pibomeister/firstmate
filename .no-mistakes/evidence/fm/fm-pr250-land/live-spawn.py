import pathlib, os, subprocess, time, shutil, json
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN'); scratch=root/'.test-live-spawn'; lab=scratch/'home'; project=scratch/'project'
scratch.mkdir(); log=(ev/'live-spawn-transcript.log').open('w',buffering=1)
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
 brief('ordinary');out=spawn('ordinary',expected=75);assert 'deferred:' in out;assert not (lab/'state/ordinary.launch-brief.md').exists()
 brief('missing',p=2);out=spawn('missing',expected=1);assert 'pass --priority 2' in out;assert not (lab/'state/missing.meta').exists()
 brief('mismatch',p=1);out=spawn('mismatch',p=0,expected=1);assert 'priority mismatch' in out;assert not (lab/'state/mismatch.meta').exists()
 brief('unreadable',p=0);f=lab/'config/lane-capacity';f.chmod(0)
 try:out=spawn('unreadable',p=0,expected=1);assert 'lane capacity admission failed' in out;assert not (lab/'state/unreadable.meta').exists()
 finally:f.chmod(0o644)
 for p in range(5):
  task=f'priority-{p}';kind='scout' if p==4 else 'ship';brief(task,kind,p);out=spawn(task,p,kind);assert 'deferred:' not in out
  meta=snapshot(task);assert meta['priority']==str(p);assert meta['worktree']!=str(project);assert pathlib.Path(meta['worktree']).is_dir()
  pane=tm('capture-pane','-p','-t',meta['window']);assert 'REAL-SHELL-WORKER-READY' in pane;log.write('LIVE TERMINAL\n'+pane)
  row=run(['tasks-axi','show',task,'--file',lab/'data/backlog.md']);assert 'state: in_flight' in row
  assert tm('has-session','-t','proof')==''
 assert (scratch/'progress').read_text().count('\n')>before
 (ev/'live-spawn-result.json').write_text(json.dumps({'result':'pass','surface':'real fm-spawn, tasks-axi, treehouse, tmux; supported raw shell workers; no model run'},indent=2))
finally:
 try:tm('kill-server')
 except Exception as e:log.write('cleanup '+str(e)+'\n')
 try:run(['bash','bin/fm-lab-home.sh','teardown',lab])
 finally:
  for d,_,_ in os.walk(scratch,followlinks=False):
   q=pathlib.Path(d)
   if not q.is_symlink():q.chmod(q.stat().st_mode|0o700)
  shutil.rmtree(scratch);log.close()
