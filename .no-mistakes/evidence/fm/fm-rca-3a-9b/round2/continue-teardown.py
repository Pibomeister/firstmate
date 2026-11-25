from pathlib import Path
import os, json, subprocess, concurrent.futures, time, signal
root=Path.cwd(); e=Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8/round2')
s=(root/'tests/fm-teardown.test.sh').read_text()
defs, calls=s.split('\ntest_hidden_untracked_work_refuses_before_return\n',1)
defs=defs.replace('\ntest_teardown_preserves_opencode_busy_plugin_on_pool_return\n','\n')
all_calls=['test_hidden_untracked_work_refuses_before_return']+calls.splitlines()
all_calls=[x for x in all_calls if x.startswith('test_') and x.replace('_','').isalnum()]
remaining=all_calls[all_calls.index('test_record_export_archives_before_teardown_or_preserves_sources_on_failure'):]
shards=[remaining[i::3] for i in range(3)]
(e/'teardown-continuation-selectors.json').write_text(json.dumps({'completed_before_setup_failure':['test_teardown_preserves_opencode_busy_plugin_on_pool_return']+all_calls[:all_calls.index(remaining[0])],'remaining_shards':shards},indent=2)+'\n')
def run(i):
 path=root/f'tests/.nm-teardown-remaining-{i+1}.sh'
 path.write_text(defs+'\n'+''.join('printf "BEGIN '+t+'\\n"\n'+t+'\n' for t in shards[i])+'\nprintf "FM_TEST_COMPLETE\\n"\n')
 env=os.environ.copy()
 for k in list(env):
  if k.startswith('FM_') or k.startswith('TASKS_AXI_') or k in ['TMUX','TMUX_PANE','HERDR_SESSION','HERDR_SOCKET_PATH','ORCA_TERMINAL_HANDLE']:env.pop(k,None)
 env['TMPDIR']='/tmp'
 start=time.monotonic()
 with (e/f'teardown-remaining-{i+1}.log').open('w') as f:
  p=subprocess.Popen(['bash',str(path)],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try: rc=p.wait(timeout=2100)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try: p.wait(timeout=30)
   except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
   rc=124
 result={'command':f'TMPDIR=/tmp bash tests/.nm-teardown-remaining-{i+1}.sh','selectors':shards[i],'exit_code':rc,'seconds':round(time.monotonic()-start,1)}
 (e/f'teardown-remaining-{i+1}.result.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result),flush=True)
 return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(run,range(3)))
(e/'teardown-continuation-results.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(any(r['exit_code'] for r in results))
