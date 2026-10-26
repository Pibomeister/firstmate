import os,pathlib,subprocess,json,shutil,signal,time
root=pathlib.Path.cwd();ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5WJ7HCFC7JBC37V8PH112BZ');env=os.environ.copy()
for k in list(env):
 if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM'):env.pop(k,None)
env.update(ORCA_USER_DATA_PATH=str(root/'o'),HOME=str(root/'.test-phase-tmp/orca-user-home'))
log=[]
def run(args,rc=0,extra=None):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(args,env=e,cwd=root,capture_output=True,text=True,timeout=45)
 log.append(dict(command=args,environment=extra or {},exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 if rc is not None:assert p.returncode==rc,log[-1]
 return p
status=json.loads(run(['orca','status','--json']).stdout)
pid=status['result']['app']['pid']
args=run(['ps','-p',str(pid),'-o','args=']).stdout
assert '--user-data-dir='+str(root/'o') in args,args
os.kill(pid,signal.SIGTERM)
log.append({'observation':f'Sent SIGTERM only to isolated Orca pid {pid}, after verifying its --user-data-dir matches this worktree.'})
for _ in range(40):
 try:os.kill(pid,0)
 except ProcessLookupError:break
 time.sleep(.25)
else:raise RuntimeError('isolated runtime did not stop')
lab=root/'.test-phase-tmp/offline-home';lab.mkdir();wt=root/'.test-phase-tmp/offline-copy';wt.mkdir();(wt/'saved.txt').write_text('saved\n')
try:
 run(['bash','bin/fm-lab-home.sh','create',str(lab)])
 boot=int(run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_host_boot_epoch']).stdout)
 for harness in ['claude','droid']:
  task='offline-'+harness;meta=lab/'state'/(task+'.meta')
  meta.write_text(f'backend=orca\nwindow=fm-{task}\nterminal=term_fm_lab_stale_offline\nendpoint_task_id={task}\nworktree={wt}\nproject={wt}\norca_worktree_id=wt-lab::{wt}\nharness={harness}\nkind=scout\nspawn_gen=s{boot-3600}.4242.99\n')
  before=meta.read_bytes()
  p=run(['bash','bin/fm-control.sh',task,'exit'],1,{'FM_HOME':str(lab)})
  assert 'endpoint-gone' not in p.stdout
  assert meta.read_bytes()==before
  assert (wt/'saved.txt').read_text()=='saved\n'
 log.append({'observation':'With the disposable runtime stopped, both Claude and Droid exits refuse despite pre-boot metadata. Neither claims endpoint-gone or changes the task record or saved copy.'})
finally:
 shutil.rmtree(lab);shutil.rmtree(wt)
 (ev/'live-unreachable.json').write_text(json.dumps(log,indent=2)+'\n')
