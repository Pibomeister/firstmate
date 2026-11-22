import subprocess,os,pathlib,signal,time
E=pathlib.Path('~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ'); active=None

def stop(sig,frame):
 if active and active.poll() is None:
  os.killpg(active.pid,signal.SIGTERM)
  try: active.wait(timeout=20)
  except subprocess.TimeoutExpired: os.killpg(active.pid,signal.SIGKILL);active.wait()
 raise SystemExit(143)
signal.signal(signal.SIGTERM,stop)
for name in ['fm-control-relaunch','fm-handoff-launch']:
 started=time.monotonic()
 with (E/(name+'-priority.log')).open('w') as log:
  log.write('COMMAND: FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/'+name+'.test.sh\n');log.flush()
  active=subprocess.Popen(['bash','tests/'+name+'.test.sh'],stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=dict(os.environ,FM_TEST_SKIP_ORPHAN_REAP='1'))
  try: rc=active.wait(timeout=1500)
  except subprocess.TimeoutExpired:
   os.killpg(active.pid,signal.SIGTERM)
   try: active.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(active.pid,signal.SIGKILL);active.wait()
   rc=124
  log.write('\nEXIT_STATUS: '+str(rc)+'\n')
 with (E/'priority-results.tsv').open('a') as out:out.write(name+'\t'+str(rc)+'\n')
 print(name,rc,round(time.monotonic()-started),flush=True)
