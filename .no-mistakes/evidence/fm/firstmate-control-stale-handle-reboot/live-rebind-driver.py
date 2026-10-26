import os,pathlib,subprocess,json,time,shutil
root=pathlib.Path.cwd();ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5WJ7HCFC7JBC37V8PH112BZ')
env=os.environ.copy()
for k in list(env):
 if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TMUX','TMUX_PANE'): env.pop(k,None)
env.update(ORCA_USER_DATA_PATH=str(root/'o'),HOME=str(root/'.test-phase-tmp/orca-user-home'),CODEX_HOME=str(root/'.test-phase-tmp/codex-home'),TERM='xterm-256color')
created=json.load(open(ev/'isolated-worktree-create.json'))['result']['worktree'];wt=pathlib.Path(created['path']);assert wt.is_relative_to(root)
lab=root/'.test-phase-tmp/rebind-home';lab.mkdir();log=[];terminal=None; started=False

def run(args,rc=0,extra=None,timeout=120):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(args,env=e,cwd=root,capture_output=True,text=True,timeout=timeout)
 log.append(dict(command=args,environment=extra or {},exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
 if rc is not None: assert p.returncode==rc,log[-1]
 return p
try:
 run(['bash','bin/fm-lab-home.sh','create',str(lab)])
 # The lab helper owns the private socket; its teardown removes it.
 run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'new-session','-d','-s','primary','-x','100','-y','30','-c',str(root),'codex']);started=True
 for key in ['HOME','PATH','CODEX_HOME','TERM']:
  run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'set-environment','-t','primary',key,env[key]])
 sock=run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'display-message','-p','#{socket_path}']).stdout.strip()
 extra={'FM_HOME':str(lab),'TMUX':sock+',0,0'}
 (lab/'config/launch-env-allowlist').write_text('HOME\nPATH\nCODEX_HOME\nTERM\n')
 (lab/'config/launch-env-tmux-session').write_text('primary\n')
 (lab/'config/backlog-backend').write_text('manual\n')
 boot=int(run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_host_boot_epoch']).stdout)
 (wt/'uncommitted.txt').write_text('uncommitted task survives endpoint replacement\n')
 for prior in ['codex','droid']:
  task='rebind-'+prior
  data=lab/'data'/task;data.mkdir()
  (data/'brief.md').write_text('# Task\n## Captain\'s intent\nValidate stale endpoint recovery in this disposable lab.\n\n## Firstmate spec\nWait without making changes or network requests.\n')
  meta=lab/'state'/(task+'.meta')
  meta.write_text(f'backend=orca\nwindow=fm-{task}\nterminal=term_fm_lab_stale_rebind\nendpoint_task_id={task}\nworktree={wt}\nproject={root / ".test-phase-tmp/orca-project"}\norca_worktree_id={created["id"]}\nharness={prior}\nkind=scout\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nspawn_gen=s{boot-3600}.4242.99\n')
  p=run(['bash','bin/fm-spawn.sh',task,'--relaunch','--harness','codex'],rc=None,extra=extra)
  fields=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
  terminal=fields.get('terminal')
  log.append({'persisted_metadata':fields,'preserved_copy':(wt/'uncommitted.txt').read_text()})
  if terminal and terminal != 'term_fm_lab_stale_rebind':
   time.sleep(2)
   show=run(['orca','terminal','show','--terminal',terminal,'--json'])
   screen=run(['orca','terminal','read','--terminal',terminal,'--json'])
   (ev/('rebind-'+prior+'-screen.json')).write_text(screen.stdout)
   run(['orca','terminal','close','--terminal',terminal,'--json']);terminal=None
  assert p.returncode==0,log[-1]
  assert fields.get('worktree')==str(wt)
  assert fields.get('terminal')!='term_fm_lab_stale_rebind'
  assert (wt/'uncommitted.txt').read_text()=='uncommitted task survives endpoint replacement\n'
 log.append({'observation':'Both recorded Codex and Droid stale handles admitted a real replacement terminal in the same linked worktree. No current-generation Droid SessionEnd was present. The real replacement Codex CLI has no login in this disposable home; productive task resumption is not proven.'})
finally:
 if terminal and terminal!='term_fm_lab_stale_rebind':run(['orca','terminal','close','--terminal',terminal,'--json'],rc=None)
 if started:run(['bash','bin/fm-lab-home.sh','tmux',str(lab),'kill-server'],rc=None)
 run(['bash','bin/fm-lab-home.sh','teardown',str(lab)],rc=None)
 (ev/'live-rebind.json').write_text(json.dumps(log,indent=2)+'\n')
 for directory, subdirs, files in os.walk(lab):
  os.chmod(directory,0o700)
 shutil.rmtree(lab)
