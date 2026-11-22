import pathlib,re,subprocess,os,json,concurrent.futures,time,signal
root=pathlib.Path.cwd();ev=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN')
cases={'fm-backlog-atomicity':'test_deferred_signal_verification_outlives_an_unresponsive_tasks_axi','fm-watch-open-decisions':'test_watcher_loop'}
def run(item):
 name,test=item;s=(root/'tests'/f'{name}.test.sh').read_text();m=re.search(r'^fm_test_run\b|^test_[a-z0-9_]+$',s,re.M);assert m;s=s[:m.start()].replace('$(dirname "${BASH_SOURCE[0]}")',str(root/'tests'));s+='\n'+test+'\nprintf "FOCUSED_COMPLETE\\n"\n';d=ev/(name+'.timing-rerun.sh');d.write_text(s);env=os.environ.copy();env['FM_TEST_SKIP_ORPHAN_REAP']='1';start=time.monotonic()
 with (ev/(name+'.timing-rerun.log')).open('w') as f:
  p=subprocess.Popen(['bash',str(d)],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(timeout=300)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   rc=124
 r={'suite':name,'selector':test,'exit':rc,'seconds':round(time.monotonic()-start,1)};(ev/(name+'.timing-rerun.result.json')).write_text(json.dumps(r,indent=2));print(json.dumps(r),flush=True);return r
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,cases.items()))
raise SystemExit(0 if all(x['exit']==0 for x in results) else 1)
