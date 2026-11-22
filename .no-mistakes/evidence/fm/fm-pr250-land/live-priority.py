import os, pathlib, subprocess, json, time, signal, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M80NZYVR53SZKKBMXS7ZM9VE')
L=ROOT/'.test-priority-live'; L.mkdir()
H=L/'home'; U=L/'user'; U.mkdir()
env=os.environ.copy()
for k in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','ORCA_TERMINAL_HANDLE','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID','TMUX','TMUX_PANE','FM_TASK_ID']:
 env.pop(k,None)
env.update(FM_HOME=str(H),HOME=str(U),SHELL='/bin/bash',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Local Validation',GIT_AUTHOR_EMAIL='validation@example.test',GIT_COMMITTER_NAME='Local Validation',GIT_COMMITTER_EMAIL='validation@example.test',FM_SPAWN_NO_GUARD='1',TREEHOUSE_ROOT=str(L/'pool'),CODEX_HOME=str(U/'.codex'),XDG_CONFIG_HOME=str(U/'.config'),XDG_CACHE_HOME=str(U/'.cache'),XDG_DATA_HOME=str(U/'.local/share'))
log=(E/'live-priority-transcript.log').open('w',buffering=1)
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
 results.append(dict(name=name,result='pass',evidence='live-priority-transcript.log',detail=detail)); log.write('\nOBSERVED '+name+': '+detail+'\n')
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
 task('priority-probe',0)
 _,output=spawn('priority-probe',0)
 assert 'deferred:' not in output and 'spawned priority-probe' in output
 meta=H/'state/priority-probe.meta';text=meta.read_text();log.write('\nPERSISTED TASK RECORD\n'+text)
 assert 'priority=0\n' in text
 run(['tasks-axi','show','priority-probe','--file',H/'data/backlog.md'])
 run(['tmux','-S',sock,'capture-pane','-p','-t','proof:fm-priority-probe'])
 assert (H/'state/ordinary.meta').exists() and (L/'progress').stat().st_size>0
 mark('priority-full-lane','P0 launches through real tmux/Treehouse despite cap=1 and max-load1=1; metadata records priority=0; no deferred line; ordinary process continues.')
 task('bad-lane',0);(H/'config/lane-capacity').write_text('1\nbogus 1\n')
 _,output=spawn('bad-lane',0,1);assert 'lane capacity admission failed' in output and not (H/'state/bad-lane.meta').exists()
 mark('malformed-lane-refuses','Explicit P0 exits 1 for malformed lane capacity before a worker record exists.')
 (H/'config/lane-capacity').write_text('1\nmax-load1 1\n')
 task('missing-priority',2);_,output=spawn('missing-priority',expect=1);assert 'pass --priority 2' in output and 'deferred:' not in output
 task('mismatch-priority',1);_,output=spawn('mismatch-priority',0,1);assert 'priority mismatch' in output and 'deferred:' not in output
 assert not (H/'state/missing-priority.meta').exists() and not (H/'state/mismatch-priority.meta').exists()
 mark('backlog-priority-guards','Missing and mismatched priorities refuse before capacity can mask the error; no worker records created.')
 # Help exited naturally. Relaunch starts the actual help CLI again, no inference.
 before=meta.read_text()
 run(['bash','bin/fm-spawn.sh','priority-probe','--relaunch','--harness','codex --help'],timeout=900)
 after=meta.read_text();log.write('\nRELAUNCHED TASK RECORD\n'+after)
 def fields(t):return dict(line.split('=',1) for line in t.splitlines() if '=' in line)
 a,b=fields(before),fields(after)
 for key in ['priority','project','worktree','window']:
  assert a[key]==b[key],key
 run(['tasks-axi','show','priority-probe','--file',H/'data/backlog.md'])
 _,output=run(['bash','bin/fm-spawn.sh','priority-probe','--relaunch','--priority','1'],expect=1)
 assert 'priority' in output
 mark('priority-relaunch','Real help-only CLI relaunch retains priority/project/worktree/window and In-flight row; --priority override refuses.')
except Exception as exc:
 log.write('\nLIVE PROBE ERROR '+repr(exc)+'\n');results.append(dict(name='remaining-local-lifecycle',result='error',detail=str(exc)))
finally:
 if sock:
  run(['tmux','-S',sock,'kill-server'],expect=None,timeout=30)
  run(['bash','bin/fm-lab-home.sh','teardown',H],expect=None,timeout=30)
 shutil.rmtree(L)
 log.write('\nCLEANUP disposable lab removed.\n');log.close()
 (E/'live-priority-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print(json.dumps(results,indent=2))
