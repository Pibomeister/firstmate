import os,pathlib,subprocess,json,time,shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5WJ7HCFC7JBC37V8PH112BZ')
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE') or k in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM'): env.pop(k,None)
env.update(ORCA_USER_DATA_PATH=str(root/'o'),HOME=str(root/'.test-phase-tmp/orca-user-home'),CODEX_HOME=str(root/'.test-phase-tmp/codex-home'))
wt=root/'.test-phase-tmp/orca-project'; lab=root/'.test-phase-tmp/survivor-home'; log=[]; terminal=None
lab.mkdir(); (wt/'uncommitted.txt').write_text('preserved task data\n')
def run(args,rc=0,extra=None):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(args,env=e,cwd=root,capture_output=True,text=True,timeout=50)
 log.append(dict(command=args,environment=extra or {},exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 assert p.returncode==rc,log[-1]
 return p.stdout
try:
 run(['bash','bin/fm-lab-home.sh','create',str(lab)])
 repo=json.load(open(ev/'isolated-repo.json'))['result']['repo']['id']
 command=f'stty rows 30 cols 100; exec env HOME={env["HOME"]} CODEX_HOME={env["CODEX_HOME"]} TERM=xterm-256color /opt/homebrew/bin/codex --no-alt-screen'
 response=json.loads(run(['orca','terminal','create','--worktree',f'id:{repo}::{wt}','--command',command,'--json']))
 (ev/'isolated-terminal-create.json').write_text(json.dumps(response,indent=2)+'\n')
 terminal=response['result']['terminal']['handle']
 time.sleep(4)
 show=run(['orca','terminal','show','--terminal',terminal,'--json'])
 (ev/'survivor-terminal-show.json').write_text(show)
 screen=run(['orca','terminal','read','--terminal',terminal,'--json'])
 (ev/'survivor-screen.json').write_text(screen)
 boot=int(run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_host_boot_epoch']))
 for harness in ['claude','droid']:
  task='survivor-'+harness
  meta=lab/'state'/(task+'.meta')
  meta.write_text(f'backend=orca\nwindow=fm-{task}\nterminal=term_fm_lab_stale_survivor\nendpoint_task_id={task}\nworktree={wt}\nproject={wt}\norca_worktree_id={repo}::{wt}\nharness={harness}\nkind=scout\nspawn_gen=s{boot-3600}.4242.99\n')
  before=meta.read_bytes()
  out=run(['bash','bin/fm-control.sh',task,'exit'],1,{'FM_HOME':str(lab)})
  assert 'an agent process still runs' in log[-1]['stderr'],log[-1]
  assert 'endpoint-gone' not in out
  assert meta.read_bytes()==before
  assert (wt/'uncommitted.txt').read_text()=='preserved task data\n'
 log.append({'observation':'Actual Codex TUI remained in the isolated recorded worktree; both Claude and Droid stale-endpoint exit calls refused because the real process scan found it. No login or model request was submitted.'})
finally:
 if terminal: run(['orca','terminal','close','--terminal',terminal,'--json'])
 shutil.rmtree(lab)
 (ev/'live-survivor.json').write_text(json.dumps(log,indent=2)+'\n')
