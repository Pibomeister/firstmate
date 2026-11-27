import os,sys,subprocess,time,signal,json,pathlib
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY')
label=sys.argv[1]; timeout=int(sys.argv[2]); cmd=sys.argv[3:]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID','REX_SESSION','REX_BLOCK','BASH_ENV','ORCA_TERMINAL_HANDLE')}
env.update(TMPDIR=str(root/'.test-validation/tmp'),HOME=str(root/'.test-validation/user'),FM_TEST_SKIP_ORPHAN_REAP='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
start=time.time()
with (evidence/(label+'.log')).open('w') as log:
 log.write('$ '+' '.join(cmd)+'\n');log.flush()
 p=subprocess.Popen(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 try: rc=p.wait(timeout=timeout)
 except subprocess.TimeoutExpired: rc=124
 finally:
  try: os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError: pass
  try: p.wait(timeout=5)
  except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
  try: os.killpg(p.pid,signal.SIGKILL)
  except ProcessLookupError: pass
 log.write('\nEXIT '+str(rc)+' elapsed '+str(round(time.time()-start,1))+'s\n')
result=dict(command=cmd,exit=rc,seconds=round(time.time()-start,1))
(evidence/(label+'.result.json')).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(label=label,**result)),flush=True)
sys.exit(rc)
