import os, pathlib, subprocess, time, json, shutil, sys, signal
MODE=sys.argv[1] if len(sys.argv)>1 else "normal"
PREFIX="live" if MODE=="normal" else MODE
if MODE in ('stuck','legacy-stuck'): PREFIX=MODE+'-frozen2'
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5X9S3P63K4EHNJMZQN8M557')
KB=R/('.test-kimi/legacy-bin' if MODE.startswith('legacy') else '.test-kimi/pinned-bin')
S=R/'.test-kimi/base' if MODE=='baseline' else R
B=R/('.test-kimi/'+PREFIX); B.mkdir()
L=B/'home'; subprocess.run(['bin/fm-lab-home.sh','create',str(L)],check=True)
(L/'.kimi-code').mkdir(); (L/'.kimi-code/config.toml').write_text('''default_model = "lab-readiness"
telemetry = false
auto_session_title = false
[providers.lab]
type = "openai"
base_url = "http://127.0.0.1:1/v1"
api_key = "disposable-no-credential"
[models.lab-readiness]
provider = "lab"
model = "lab-readiness"
max_context_size = 262144
capabilities = ["tool_use"]
[loop_control]
max_attempts_per_step = 1
''')
P=B/'project'; P.mkdir(); subprocess.run(['git','init','-b','main',str(P)],check=True,capture_output=True)
subprocess.run(['git','-C',str(P),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-m','disposable readiness lab'],check=True,capture_output=True)
ID='kimi-'+PREFIX+'-831a-'+str(os.getpid()); (B/'task-id').write_text(ID)
D=L/'data'/ID; D.mkdir(); (D/'brief.md').write_text('''# Task
## Captain's intent
Verify Kimi trust readiness in a disposable lab.

## Firstmate spec
Read this brief. Reply LAB_BRIEF_READ. Do not modify any file or run any command.
''')
(L/'state/.last-watcher-beat').touch(); (L/'config/keep-ai-trailers').touch()
env=os.environ.copy()
for key in list(env):
 if key.startswith('FM_') or key in ['TMUX','TMUX_PANE','KIMI_CODE_HOME','KIMI_MODEL_NAME','CLAUDECODE','CURSOR_AGENT','CURSOR_INVOKED_AS','GEMINI_CLI']: env.pop(key,None)
env.update(HOME=str(L),FM_HOME=str(L),PATH=str(KB)+':'+str(R/'.test-kimi/bin')+':'+os.environ['PATH'],SHELL='/bin/bash',TREEHOUSE_ROOT=str(B/'pool'),NO_COLOR='1',TERM='xterm-256color')
helper=[str(R/'bin/fm-lab-home.sh'),'tmux',str(L)]
def tm(*args,check=True):
 return subprocess.run(helper+list(args),env=env,text=True,capture_output=True,check=check).stdout
polls='4' if MODE.startswith('legacy-answered') else ('3' if 'answered' in MODE else '12')
spawn=B/'spawn.sh'; spawn.write_text('#!/bin/bash\ncd '+str(R)+'\nFM_SPAWN_NO_GUARD=1 FM_KIMI_READY_POLLS='+polls+' FM_KIMI_POLL_INTERVAL=1.5 '+str(S/'bin/fm-spawn.sh')+' '+ID+' '+str(P)+' --scout --harness kimi --backend tmux --model lab-readiness --effort high > '+str(E/(PREFIX+'-spawn.log'))+' 2>&1\necho $? > '+str(B/'result')+'\n')
try:
 tm('new-session','-d','-s','fm-lab-kimi','-x',('30' if MODE=='wrapped' else '120'),'-y',('10' if MODE=='clipped' else ('80' if MODE=='wrapped' else '40')),'-c',str(R),'/bin/bash --noprofile --norc')
 tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
 tm('set-option','-g','default-shell','/bin/bash')
 tm('send-keys','-t','fm-lab-kimi:0','bash '+str(spawn),'Enter')
 frames=[]; last=''; frozen=False; deadline=time.time()+70
 while time.time()<deadline:
  wins=tm('list-windows','-t','fm-lab-kimi','-F','#{window_name}',check=False)
  if 'fm-'+ID in wins:
   frame=tm('capture-pane','-p','-t','fm-lab-kimi:fm-'+ID,check=False)
   if frame!=last:
    last=frame; frames.append({'time':time.time(),'pane':frame})
    if 'Trust this folder?' in frame or 'Trust and continue' in frame:
     (E/(PREFIX+'-trust-pane.txt')).write_text(frame)
     if MODE in ('stuck','legacy-stuck') and not frozen:
      pane_pid=int(tm('display-message','-p','-t','fm-lab-kimi:fm-'+ID,'#{pane_pid}').strip())
      processes=[line.split(None,2) for line in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines() if line.strip()]
      descendants={pane_pid}
      for _ in range(8):
       for pid,ppid,comm in processes:
        if int(ppid) in descendants: descendants.add(int(pid))
      for pid,ppid,comm in processes:
       if int(pid) in descendants:
        os.kill(int(pid),signal.SIGSTOP); frozen=True; print('Frozen lab pane process PID',pid,flush=True)
      if not frozen: print('No Kimi PID found in descendants',descendants,flush=True)
  if (B/'result').exists(): break
  time.sleep(.03)
 (E/(PREFIX+'-pane-frames.json')).write_text(json.dumps(frames,indent=2))
 (E/(PREFIX+'-final-pane.txt')).write_text(last)
 (E/(PREFIX+'-result.txt')).write_text('Kimi CLI: '+subprocess.check_output([str(KB/'kimi'),'--version'],text=True,env=env)+'Profile: lab-readiness / high / tmux\nNo production credentials or model were used.\nSpawn exit: '+((B/'result').read_text() if (B/'result').exists() else 'timeout')+'\n')
 print((E/(PREFIX+'-result.txt')).read_text()); print(last)
 if (L/'state'/f'{ID}.meta').exists(): shutil.copyfile(L/'state'/f'{ID}.meta',E/(PREFIX+'-task.meta'))
 if (L/'state'/f'{ID}.status').exists(): shutil.copyfile(L/'state'/f'{ID}.status',E/(PREFIX+'-task.status'))
finally:
 if MODE in ('stuck','legacy-stuck') and frozen:
  for pid,ppid,comm in processes:
   if int(pid) in descendants:
    try: os.kill(int(pid),signal.SIGCONT)
    except ProcessLookupError: pass
 tm('kill-server',check=False)
 subprocess.run([str(R/'bin/fm-lab-home.sh'),'teardown',str(L)],env=env,check=True)
 # Product-owned ephemeral launch/temp locations, named only by this lab task.
 for item in pathlib.Path('/tmp').glob('fm-'+ID+'*'):
  if item.is_dir(): shutil.rmtree(item)
 shutil.rmtree(B)
