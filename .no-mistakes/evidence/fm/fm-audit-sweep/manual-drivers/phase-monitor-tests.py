import subprocess,os,pathlib,signal
E=pathlib.Path('~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ'); active=None

def stop(sig,frame):
 if active and active.poll() is None:
  os.killpg(active.pid,signal.SIGTERM)
  try: active.wait(timeout=20)
  except subprocess.TimeoutExpired: os.killpg(active.pid,signal.SIGKILL);active.wait()
 raise SystemExit(143)
signal.signal(signal.SIGTERM,stop)
for name,args in [('hung-prune-focused',['bash','tests/.phase-hung-focused.test.sh']),('watchdog-send-focused',['bash','tests/fm-watchdog.test.sh','test_heartbeat_failed_send_never_counts_as_delivery'])]:
 with (E/(name+'.log')).open('w') as log:
  log.write('COMMAND: FM_TEST_SKIP_ORPHAN_REAP=1 '+' '.join(args)+'\n');log.flush()
  active=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=dict(os.environ,FM_TEST_SKIP_ORPHAN_REAP='1'))
  try:rc=active.wait(timeout=600)
  except subprocess.TimeoutExpired:
   os.killpg(active.pid,signal.SIGTERM)
   try: active.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(active.pid,signal.SIGKILL);active.wait()
   rc=124
  log.write('\nEXIT_STATUS: '+str(rc)+'\n')
 with (E/'focused-monitor-results.tsv').open('a') as f:f.write(name+'\t'+str(rc)+'\n')
 print(name,rc,flush=True)
