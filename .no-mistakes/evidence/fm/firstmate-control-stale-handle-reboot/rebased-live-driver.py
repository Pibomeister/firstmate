import os, pathlib, subprocess, json, time, signal, shutil, shlex, hashlib, traceback
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5WJ7HCFC7JBC37V8PH112BZ')
selection=json.loads((ev/'rebased-runtime-selection.log').read_text().split('ORCA_SERVE_RUNTIME ',1)[1])
assert selection['kind']=='orcad'
base=root/'.test-phase-tmp'; lab=base/'live-home'; wt=base/'preserved-copy'
(base/'codex-home').mkdir(exist_ok=True)
env=os.environ.copy()
for k in list(env):
 if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TMUX','TMUX_PANE','ORCA_ENVIRONMENT','ORCA_PAIRING_CODE','ORCA_PANE_KEY','ORCA_RUNTIME_ID','ORCA_RUNTIME_METADATA_PATH','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR']:env.pop(k,None)
env.update(ORCA_USER_DATA=str(root/'o'),ORCA_USER_DATA_PATH=str(root/'o'),ORCA_VERSION=selection['version'],HOME=str(base/'orca-user-home'),CODEX_HOME=str(base/'codex-home'),TERM='xterm-256color',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
log=[];scenarios=[];terminals=[];server=None;tmux_started=False
serverlog=open(ev/'rebased-orcad-server.log','w')
def run(args, rc=0, extra=None, timeout=75):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(args,cwd=root,env=e,capture_output=True,text=True,timeout=timeout)
 log.append(dict(command=args,environment=extra or {},exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 (ev/'rebased-live.json').write_text(json.dumps(log,indent=2)+'\n')
 if rc is not None:assert p.returncode==rc,log[-1]
 return p

def scenario(name, fn):
 fn();scenarios.append(dict(name=name,result='pass',live=True))
 (ev/'rebased-scenarios.json').write_text(json.dumps(scenarios,indent=2)+'\n')

def meta_for(task,harness,epoch,worktree=wt,orca_id=None):
 m=lab/'state'/(task+'.meta')
 m.write_text(f'backend=orca\nwindow=fm-{task}\nterminal=term_fm_lab_stale_rebased\nendpoint_task_id={task}\nworktree={worktree}\nproject={worktree}\norca_worktree_id={orca_id or "lab::"+str(worktree)}\nharness={harness}\nkind=scout\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nspawn_gen=s{epoch}.4242.99\n')
 return m
try:
 server=subprocess.Popen([selection['runtime'],selection['entry'],'--bind','127.0.0.1','--port','18747','--no-pairing','--json'],env=env,cwd=root,stdout=serverlog,stderr=subprocess.STDOUT,start_new_session=True)
 for _ in range(80):
  time.sleep(.25)
  if server.poll() is not None:raise RuntimeError('isolated runtime failed: '+(ev/'rebased-orcad-server.log').read_text()[-4500:])
  p=subprocess.run(['orca','status','--json'],env=env,cwd=root,capture_output=True,text=True)
  if p.returncode==0 and json.loads(p.stdout).get('result',{}).get('runtime',{}).get('reachable'):break
 else:raise RuntimeError('isolated runtime not ready')
 run(['orca','status','--json'])
 run(['bash','bin/fm-lab-home.sh','create',str(lab)])
 wt.mkdir();(wt/'uncommitted.txt').write_text('preserved task copy\n')
 boot=int(run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_host_boot_epoch']).stdout)
 extra={'FM_HOME':str(lab)}
 def decode():
  p=run(['orca','terminal','show','--terminal','term_fm_lab_stale_rebased','--json'],1)
  assert json.loads(p.stdout)['error']['code']=='terminal_handle_stale'
  p=run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_terminal_facts term_fm_lab_stale_rebased'])
  assert p.stdout.split('\x1f')[0]=='stale'
 scenario('Decode the real nonzero stale-handle response',decode)
 def recover():
  for h in ['claude','droid']:
   task='recover-'+h;m=meta_for(task,h,boot-3600);before=m.read_bytes()
   p=run(['bash','bin/fm-control.sh',task,'exit'],0,extra)
   assert 'endpoint-gone' in p.stdout
   assert m.read_bytes()==before and (wt/'uncommitted.txt').read_text()=='preserved task copy\n'
   assert not list((lab/'state').glob(task+'*session*'))
  # Legacy records with no generation rely on their own pre-boot mtime.
  m=meta_for('mtime-recover','claude',boot-3600)
  m.write_text('\n'.join(l for l in m.read_text().splitlines() if not l.startswith('spawn_gen='))+'\n');os.utime(m,(boot-3600,boot-3600))
  assert 'endpoint-gone' in run(['bash','bin/fm-control.sh','mtime-recover','exit'],0,extra).stdout
 scenario('Exit pre-boot Claude and Droid records without changing saved work',recover)
 def guard():
  for h in ['claude','droid']:
   task='current-'+h;m=meta_for(task,h,boot+3600);before=m.read_bytes()
   for forged in [False,True]:
    ex=extra.copy()
    if forged:ex['FM_ORCA_BOOT_EPOCH']=str(boot+99999999)
    p=run(['bash','bin/fm-control.sh',task,'exit'],1,ex)
    assert 'does not postdate' in p.stderr and 'endpoint-gone' not in p.stdout
    assert m.read_bytes()==before
  p=run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_endpoint_absence_proof term_fm_lab_stale_rebased "$1"','_',str(wt)])
  assert p.stdout.startswith('unproven\t')
 scenario('Refuse current-boot records, forged boot values and missing metadata',guard)
 # A local disposable repo allows Orca to create its own real linked worktree.
 project=base/'orca-project';project.mkdir();(project/'README.md').write_text('Disposable validation project.\n')
 run(['git','-C',str(project),'init','-b','main'])
 run(['git','-C',str(project),'add','README.md'])
 run(['git','-C',str(project),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-m','Lab baseline'])
 repo=json.loads(run(['orca','repo','add','--path',str(project),'--json']).stdout)['result']['repo']['id']
 run(['orca','project','setup-update','--setup',repo,'--host','local','--worktree-base-path',str(base/'workers'),'--json'])
 created=json.loads(run(['orca','worktree','create','--repo','id:'+repo,'--name','fm-lab-rebased','--no-parent','--setup','skip','--json']).stdout)['result']['worktree']
 rwt=pathlib.Path(created['path']);assert rwt.is_relative_to(root)
 saved=rwt/'uncommitted.txt';saved.write_text('uncommitted task survives endpoint replacement\n')
 (lab/'config/backlog-backend').write_text('manual\n')
 (lab/'config/supervision-host').touch()
 def replacement_guards():
  for h in ['codex','droid']:
   task='current-spawn-'+h;m=meta_for(task,h,boot+3600,rwt,created['id'])
   m.write_text(m.read_text().replace('project='+str(rwt),'project='+str(project)))
   data=lab/'data'/task;data.mkdir();(data/'brief.md').write_text('# Task\n## Captain\'s intent\nKeep saved work.\n## Firstmate spec\nValidate refusal.\n')
   before=m.read_bytes()
   p=run(['bash','bin/fm-spawn.sh',task,'--relaunch','--harness','codex'],1,extra)
   assert 'does not postdate' in p.stderr
   if h=='droid':assert 'SessionEnd proof' in p.stderr
   assert m.read_bytes()==before and saved.read_text()=='uncommitted task survives endpoint replacement\n'
 scenario('Refuse replacement without reboot proof and retain Droid SessionEnd checks',replacement_guards)
 def rebind():
  for prior in ['codex','droid']:
   task='rebind-'+prior;m=meta_for(task,prior,boot-3600,rwt,created['id'])
   # The project and recorded worktree have distinct real Git identities.
   m.write_text(m.read_text().replace('project='+str(rwt),'project='+str(project)))
   data=lab/'data'/task;data.mkdir();(data/'brief.md').write_text('# Task\n## Captain\'s intent\nValidate stale endpoint recovery in this disposable lab.\n## Firstmate spec\nWait without making changes or network requests.\n')
   p=run(['bash','bin/fm-spawn.sh',task,'--relaunch','--harness','codex'],0,extra,120)
   fields=dict(l.split('=',1) for l in m.read_text().splitlines() if '=' in l)
   terminal=fields['terminal'];terminals.append(terminal)
   assert terminal!='term_fm_lab_stale_rebased' and fields['worktree']==str(rwt)
   assert saved.read_text()=='uncommitted task survives endpoint replacement\n'
   time.sleep(2)
   run(['orca','terminal','show','--terminal',terminal,'--json'])
   p=run(['orca','terminal','read','--terminal',terminal,'--json'])
   (ev/('rebased-rebind-'+prior+'-screen.json')).write_text(p.stdout)
   log.append(dict(observation='Replacement allocated in same worktree',prior_harness=prior,persisted_metadata=fields,preserved_copy=saved.read_text()))
   run(['orca','terminal','close','--terminal',terminal,'--json']);terminals.remove(terminal)
 scenario('Replace pre-boot Codex and Droid endpoints in the same preserved worktree',rebind)
 def survivor():
  command='stty rows 30 cols 100; exec env HOME='+shlex.quote(env['HOME'])+' CODEX_HOME='+shlex.quote(env['CODEX_HOME'])+' TERM=xterm-256color codex --no-alt-screen'
  t=json.loads(run(['orca','terminal','create','--worktree','id:'+created['id'],'--command',command,'--json']).stdout)['result']['terminal']['handle'];terminals.append(t)
  time.sleep(3)
  screen=run(['orca','terminal','read','--terminal',t,'--json']).stdout
  (ev/'rebased-survivor-screen.json').write_text(screen)
  shown=json.loads(run(['orca','terminal','show','--terminal',t,'--json']).stdout)['result']['terminal']
  assert shown['connected'] is True,shown
  assert json.loads(screen)['result']['terminal']['tail'],screen
  for h in ['claude','droid']:
   task='survivor-'+h;m=meta_for(task,h,boot-3600,rwt,created['id']);before=m.read_bytes()
   p=run(['bash','bin/fm-control.sh',task,'exit'],1,extra)
   assert 'an agent process still runs' in p.stderr and m.read_bytes()==before
   data=lab/'data'/task;data.mkdir();(data/'brief.md').write_text('# Task\n## Captain\'s intent\nKeep saved work.\n## Firstmate spec\nValidate refusal.\n')
   p=run(['bash','bin/fm-spawn.sh',task,'--relaunch','--harness','codex'],1,extra)
   assert 'an agent process still runs' in p.stderr and m.read_bytes()==before
   assert saved.read_text()=='uncommitted task survives endpoint replacement\n'
  run(['orca','terminal','close','--terminal',t,'--json']);terminals.remove(t)
 scenario('Refuse stale-handle recovery while a real agent remains in the worktree',survivor)
 # Recheck with the disposable Orca stopped; this must not auto-open or address the real app.
 server.terminate();server.wait(timeout=20);server=None
 def offline():
  for h in ['claude','droid']:
   task='offline-'+h;m=meta_for(task,h,boot-3600);before=m.read_bytes()
   p=run(['bash','bin/fm-control.sh',task,'exit'],1,extra)
   assert 'endpoint-gone' not in p.stdout and m.read_bytes()==before
   assert (wt/'uncommitted.txt').read_text()=='preserved task copy\n'
 scenario('Refuse recovery when the isolated Orca runtime is unavailable',offline)
except Exception as ex:
 log.append(dict(error=str(ex),traceback=traceback.format_exc()));raise
finally:
 if server:
  for t in terminals:
   run(['orca','terminal','close','--terminal',t,'--json'],None)
  server.terminate()
  try:server.wait(timeout=20)
  except subprocess.TimeoutExpired:os.killpg(server.pid,signal.SIGKILL);server.wait()
 if tmux_started:run(['tmux','-L','fm-lab','kill-server'],None,{'TMUX_TMPDIR':str(lab/'tmux')})
 serverlog.close()
 (ev/'rebased-live.json').write_text(json.dumps(log,indent=2)+'\n')
 (ev/'rebased-scenarios.json').write_text(json.dumps(scenarios,indent=2)+'\n')
 print(json.dumps(scenarios,indent=2))
