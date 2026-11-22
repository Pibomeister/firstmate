import os, pathlib, subprocess, json, time, signal, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M80NZYVR53SZKKBMXS7ZM9VE')
L=ROOT/'.test-priority-extra'; L.mkdir()
H=L/'home'; U=L/'user'; U.mkdir()
env=os.environ.copy()
for k in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','ORCA_TERMINAL_HANDLE','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID','TMUX','TMUX_PANE','FM_TASK_ID']:
 env.pop(k,None)
env.update(FM_HOME=str(H),HOME=str(U),SHELL='/bin/bash',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Local Validation',GIT_AUTHOR_EMAIL='validation@example.test',GIT_COMMITTER_NAME='Local Validation',GIT_COMMITTER_EMAIL='validation@example.test',FM_SPAWN_NO_GUARD='1',TREEHOUSE_ROOT=str(L/'pool'),CODEX_HOME=str(U/'.codex'),XDG_CONFIG_HOME=str(U/'.config'),XDG_CACHE_HOME=str(U/'.cache'),XDG_DATA_HOME=str(U/'.local/share'))
log=(E/'live-priority-extra-transcript.log').open('w',buffering=1)
results=[]; sock=None

def run(args,expect=0,cwd=ROOT,timeout=600,extra=None):
 log.write('\n$ '+' '.join(map(str,args))+'\n')
 e=env.copy();e.update(extra or {})
 p=subprocess.Popen(list(map(str,args)),cwd=cwd,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try: output=p.communicate(timeout=timeout)[0]
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM)
  try: output=p.communicate(timeout=20)[0]
  except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);output=p.communicate()[0]
  log.write(output+'\nTIMEOUT\n');raise RuntimeError('timeout: '+str(args))
 log.write(output+'\nexit='+str(p.returncode)+'\n')
 if expect is not None and p.returncode!=expect: raise RuntimeError('unexpected exit '+str(p.returncode)+': '+str(args))
 return p.returncode,output

def mark(name,detail):
 results.append(dict(name=name,result='pass',evidence='live-priority-extra-transcript.log',detail=detail)); log.write('\nOBSERVED '+name+': '+detail+'\n')
def task(id,priority=None):
 d=H/'data'/id;d.mkdir(parents=True)
 (d/'brief.md').write_text('# Task\n## Captain\'s intent\nShow the installed CLI help without making a model request.\n\n## Firstmate spec\nExercise local priority admission with a help-only process.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n')
 args=['tasks-axi','add',id,'Local CLI help probe','--kind','ship','--file',H/'data/backlog.md']
 if priority is not None: args+=['--priority',str(priority)]
 run(args)
def spawn(id,priority=None,expect=0):
 args=['bash','bin/fm-spawn.sh',id,L/'project','codex --help','--mode','no-mistakes','--yolo','off','--backend','tmux']
 if priority is not None: args+=['--priority',str(priority)]
 return run(args,expect=expect,timeout=900)
try:
 run(['bash','bin/fm-lab-home.sh','create',H])
 run(['git','init','-b','main',L/'project'])
 (L/'project/README.md').write_text('Synthetic local priority admission project\n')
 run(['git','add','README.md'],cwd=L/'project');run(['git','commit','-m','Seed isolated validation project'],cwd=L/'project')
 run(['git','clone','--bare',L/'project',L/'origin.git'])
 run(['git','remote','add','origin',L/'origin.git'],cwd=L/'project')
 run(['git','fetch','origin'],cwd=L/'project')
 (H/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
 (H/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
 # The helper owns the short private socket and the only tmux server used here.
 _,socketdir=run(['bash','bin/fm-lab-home.sh','tmux-dir',H]);socketdir=socketdir.strip()
 sock=pathlib.Path(socketdir)/('tmux-'+str(os.getuid()))/'default'
 ordinary="while :; do echo alive >> '"+str(L/'progress')+"'; sleep 1; done"
 run(['bash','bin/fm-lab-home.sh','tmux',H,'new-session','-d','-s','proof','-n','fm-ordinary','-x','120','-y','40',ordinary])
 _,pid=run(['tmux','-S',sock,'display-message','-p','#{pid}'])
 env['TMUX']=str(sock)+','+pid.strip()+',0'
 (H/'state/ordinary.meta').write_text('window=proof:fm-ordinary\nbackend=tmux\nkind=ship\nharness=codex\nproject='+str(L/'project')+'\nworktree='+str(L/'project')+'\n')
 (H/'state/.last-watcher-beat').touch()
 (H/'config/lane-capacity').write_text('1\nmax-load1 1\n')
 task('ordinary-probe')
 _,output=spawn('ordinary-probe',expect=75)
 assert 'deferred:' in output and not (H/'state/ordinary-probe.meta').exists()
 run(['tasks-axi','show','ordinary-probe','--file',H/'data/backlog.md'])
 mark('ordinary-full-lane','Real spawn exits 75 without metadata; synthetic backlog remains queued.')
 # Full project plus away spend cap; every explicit priority still launches.
 (H/'config/project-capacity').write_text('project 1\n')
 task('project-ordinary')
 _,output=spawn('project-ordinary',expect=75)
 assert 'project' in output and not (H/'state/project-ordinary.meta').exists()
 run(['bash','bin/fm-afk-contract.sh','enter','--words','Run only these local help probes.','--spend','1'])
 task('away-ordinary')
 _,output=spawn('away-ordinary',expect=1)
 assert 'away-posture record caps concurrent workers' in output
 mark('ordinary-project-and-away-caps','Ordinary spawn defers under project cap; away cap refuses an additional ordinary worker.')
 for priority in range(5):
  id='level-'+str(priority);task(id,priority)
  _,output=spawn(id,priority)
  assert 'deferred:' not in output and ('priority='+str(priority)+'\n') in (H/'state'/f'{id}.meta').read_text()
  row=run(['tasks-axi','show',id,'--file',H/'data/backlog.md'])[1]
  assert 'state: in_flight' in row
  before=(L/'progress').stat().st_size
  time.sleep(1.1)
  assert (L/'progress').stat().st_size>before
 mark('all-priorities-project-lane-away','Real help-only launches for priorities 0-4 bypass full project/lane/load/away caps; each In-flight row and metadata retains its priority; existing process continues.')
 task('bad-project',0);(H/'config/project-capacity').write_text('project nonsense\n')
 _,output=spawn('bad-project',0,1)
 assert 'project capacity declaration is unreadable' in output and not (H/'state/bad-project.meta').exists()
 (H/'config/project-capacity').write_text('project 1\n')
 task('bad-load',0);(H/'config/load-relief').write_text('ceiling not-a-number\n')
 _,output=spawn('bad-load',0,1)
 assert 'lane capacity admission failed' in output and not (H/'state/bad-load.meta').exists()
 (H/'config/load-relief').unlink()
 mark('malformed-independent-limits','Explicit P0 still refuses malformed project-capacity and load-relief limits before publishing worker metadata.')
 # Reprioritize through the real backlog CLI after the real endpoint appears.
 import concurrent.futures
 task('race-priority',1)
 def change_row():
  deadline=time.monotonic()+300
  while time.monotonic()<deadline:
   q=subprocess.run(['tmux','-S',str(sock),'list-windows','-t','proof','-F','#{window_name}'],env=env,stdout=subprocess.PIPE,text=True)
   if 'fm-race-priority' in q.stdout.splitlines():
    return subprocess.run(['tasks-axi','update','race-priority','--priority','3','--file',str(H/'data/backlog.md')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
   time.sleep(.05)
  raise RuntimeError('race endpoint never appeared')
 with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
  update=pool.submit(change_row)
  _,output=spawn('race-priority',1)
  updated=update.result();log.write('CONCURRENT BACKLOG UPDATE\n'+updated.stdout+'\nexit='+str(updated.returncode)+'\n')
  assert updated.returncode==0
 assert 'priority changed while its worker started' in output
 assert 'priority=3\n' in (H/'state/race-priority.meta').read_text()
 row=run(['tasks-axi','show','race-priority','--file',H/'data/backlog.md'])[1]
 assert 'state: in_flight' in row and 'priority: 3' in row
 mark('startup-priority-race','Actual tmux endpoint starts under priority 1; concurrent tasks-axi reprioritization to 3 is adopted with a warning, keeping the worker record and In-flight row.')
except Exception as exc:
 log.write('\nLIVE PROBE ERROR '+repr(exc)+'\n');results.append(dict(name='remaining-local-lifecycle',result='error',detail=str(exc)))
finally:
 if sock:
  run(['tmux','-S',sock,'kill-server'],expect=None,timeout=30)
  run(['bash','bin/fm-lab-home.sh','teardown',H],expect=None,timeout=30)
 for d in L.rglob("*"):
  if d.is_dir() and not d.is_symlink():d.chmod(d.stat().st_mode|0o700)
 shutil.rmtree(L)
 log.write('\nCLEANUP disposable lab removed.\n');log.close()
 (E/'live-priority-extra-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print(json.dumps(results,indent=2))
