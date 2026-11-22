import pathlib,re,subprocess,concurrent.futures,os,json,time,signal
root=pathlib.Path.cwd();ev=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN')
selection={
'fm-wake-queue':['test_drain_preserves_p0_alarm_before_later_stale','test_drain_preserves_identical_p0_reopenings'],
'fm-watch-triage':['test_p0_blocker_surfaces_exact_text_once_at_ten_minutes','test_p0_alarms_scan_all_workers_before_sibling_signals','test_p0_blocker_fold_preserves_open_keys_and_ages'],
'fm-control-relaunch':['test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it','test_spawn_relaunch_refuses_contradicting_flags']}
def run(item):
 name,tests=item;s=(root/'tests'/f'{name}.test.sh').read_text();m=re.search(r'^fm_test_run\b|^test_[a-z0-9_]+$',s,re.M);assert m
 s=s[:m.start()];s=s.replace('$(dirname "${BASH_SOURCE[0]}")',str(root/'tests'))
 s+='\n'+ '\n'.join(tests)+'\nprintf "FOCUSED_COMPLETE\\n"\n'
 driver=ev/(name+'.focused.sh');driver.write_text(s)
 env=os.environ.copy();env['FM_TEST_SKIP_ORPHAN_REAP']='1';start=time.monotonic()
 with (ev/(name+'.focused.log')).open('w') as f:
  p=subprocess.Popen(['bash',str(driver)],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  print('START',name,p.pid,flush=True)
  try:rc=p.wait(timeout=900)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=20)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   rc=124
 result={'suite':name,'selectors':tests,'exit':rc,'seconds':round(time.monotonic()-start,1)};(ev/(name+'.focused.result.json')).write_text(json.dumps(result,indent=2));print('END',json.dumps(result),flush=True);return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(run,selection.items()))
(ev/'focused-results.json').write_text(json.dumps(results,indent=2));raise SystemExit(0 if all(x['exit']==0 for x in results) else 1)
