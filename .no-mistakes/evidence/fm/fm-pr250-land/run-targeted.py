import concurrent.futures, subprocess, os, signal, time, json, pathlib
out=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN')
os.environ['FM_TEST_SKIP_ORPHAN_REAP']='1'
suites=['fm-project-capacity','fm-watch-open-decisions','fm-disk-alarm','fm-backlog-atomicity','fm-branch-supervision','fm-capacity','fm-classify-decision-key','fm-daemon','fm-wake-queue','fm-watch-triage','fm-failover','fm-control-relaunch','fm-afk-contract','fm-spawn-batch','fm-priority-worker-live-e2e']
def run(name):
 start=time.monotonic()
 with (out/(name+'.log')).open('w') as f:
  p=subprocess.Popen(['bash','tests/'+name+'.test.sh'],stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  print('START',name,p.pid,flush=True)
  try: rc=p.wait(timeout=1800)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try: p.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
   rc=124
  result={'suite':name,'exit':rc,'seconds':round(time.monotonic()-start,1)}
  (out/(name+'.result.json')).write_text(json.dumps(result))
  print('END',json.dumps(result),flush=True)
  return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 results=list(pool.map(run,suites))
(out/'targeted-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(x['exit']==0 for x in results) else 1)
