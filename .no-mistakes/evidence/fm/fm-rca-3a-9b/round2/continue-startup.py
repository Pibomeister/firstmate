from pathlib import Path
import os,json,subprocess,concurrent.futures,time,signal
root=Path.cwd(); e=Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8/round2')
s=(root/'tests/fm-session-start.test.sh').read_text()
defs,calls=s.split('\ntest_context_digest_absent_empty_present\n',1)
all_calls=['test_context_digest_absent_empty_present']+calls.splitlines()
all_calls=[x for x in all_calls if x.startswith('test_') and x.replace('_','').isalnum()]
remaining=all_calls[all_calls.index('test_session_start_relaunches_missing_pi_secondmate'):]
shards=[remaining[i::3] for i in range(3)]
(e/'startup-continuation-selectors.json').write_text(json.dumps({'completed_before_continuation':all_calls[:all_calls.index(remaining[0])],'remaining_shards':shards},indent=2)+'\n')
def run(i):
 path=root/f'tests/.nm-startup-remaining-{i+1}.sh'
 path.write_text(defs+'\n'+''.join('printf "BEGIN '+t+'\\n"\n'+t+'\n' for t in shards[i])+'\nprintf "FM_TEST_COMPLETE\\n"\n')
 env=os.environ.copy()
 for k in list(env):
  if k.startswith('FM_') or k.startswith('TASKS_AXI_') or k in ['TMUX','TMUX_PANE','HERDR_SESSION','HERDR_SOCKET_PATH','ORCA_TERMINAL_HANDLE']:env.pop(k,None)
 env['TMPDIR']='/tmp'
 start=time.monotonic()
 with (e/f'startup-remaining-{i+1}.log').open('w') as f:
  p=subprocess.Popen(['bash',str(path)],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(timeout=1800)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=30)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   rc=124
 result={'command':f'TMPDIR=/tmp bash tests/.nm-startup-remaining-{i+1}.sh','selectors':shards[i],'exit_code':rc,'seconds':round(time.monotonic()-start,1)}
 (e/f'startup-remaining-{i+1}.result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True);return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(run,range(3)))
(e/'startup-continuation-results.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(any(r['exit_code'] for r in results))
