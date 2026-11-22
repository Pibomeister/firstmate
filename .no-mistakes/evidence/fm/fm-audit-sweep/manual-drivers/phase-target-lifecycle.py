import subprocess,os,pathlib,signal,time
E=pathlib.Path('~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ'); active=None

def stop(sig,frame):
 if active and active.poll() is None:
  os.killpg(active.pid,signal.SIGTERM)
  try: active.wait(timeout=20)
  except subprocess.TimeoutExpired: os.killpg(active.pid,signal.SIGKILL);active.wait()
 raise SystemExit(143)
signal.signal(signal.SIGTERM,stop)
commands=[('control-relaunch-focused',['bash','tests/fm-control-relaunch.test.sh','test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint'],300),('handoff-launch-full',['bash','tests/fm-handoff-launch.test.sh'],1200)]
for name,args,budget in commands:
 with (E/(name+'.log')).open('w') as log:
  log.write('COMMAND: FM_TEST_SKIP_ORPHAN_REAP=1 '+' '.join(args)+'\n');log.flush()
  active=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=dict(os.environ,FM_TEST_SKIP_ORPHAN_REAP='1'))
  try: rc=active.wait(timeout=budget)
  except subprocess.TimeoutExpired:
   os.killpg(active.pid,signal.SIGTERM)
   try: active.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(active.pid,signal.SIGKILL);active.wait()
   rc=124
  log.write('\nEXIT_STATUS: '+str(rc)+'\n')
 with (E/'focused-lifecycle-results.tsv').open('a') as out:out.write(name+'\t'+str(rc)+'\n')
 print(name,rc,flush=True)
