import subprocess, os, pathlib, time, signal, concurrent.futures, threading
E=pathlib.Path('~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ'); children=set(); lock=threading.Lock()
def cancel(sig,frame):
 with lock:
  for p in children:
   try: os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
 raise SystemExit(143)
signal.signal(signal.SIGTERM,cancel)
tests=['fm-herdr-lab','fm-herdr-owned-xdg','fm-memory-guard','fm-stall-ledger','fm-permission-prompt','fm-pstack-verify-hook','fm-hung-ladder','fm-watchdog','fm-daemon','fm-control-relaunch','fm-handoff-launch','fm-herdr-owned-xdg-live-e2e']
(E/'targeted-results.tsv').write_text('')
def run(name):
 start=time.monotonic()
 with (E/(name+'.log')).open('w') as log:
  log.write('COMMAND: FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/'+name+'.test.sh\n'); log.flush()
  p=subprocess.Popen(['bash','tests/'+name+'.test.sh'],stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=dict(os.environ,FM_TEST_SKIP_ORPHAN_REAP='1'))
  with lock: children.add(p)
  try: rc=p.wait(timeout=1500)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try: p.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
   rc=124
  with lock: children.discard(p)
  log.write('\nEXIT_STATUS: %s\n'%rc)
 print(name,'exit='+str(rc),'elapsed='+str(round(time.monotonic()-start)),flush=True)
 with lock:
  with (E/'targeted-results.tsv').open('a') as summary: summary.write(name+'\t'+str(rc)+'\n')
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: list(pool.map(run,tests))
