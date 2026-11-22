import subprocess,pathlib,os,time,json,signal,concurrent.futures
E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE')
checks=[['bash','tests/fm-watchdog.test.sh','test_heartbeat_failed_send_never_counts_as_delivery','test_heartbeat_swallowed_enter_never_counts_as_delivery','test_heartbeat_dryrun_never_counts_as_delivery','test_heartbeat_recovery_preserves_account_pins','test_heartbeat_response_cannot_suppress_recovery_forever'],['bash','tests/fm-hung-ladder.test.sh','test_prune_reclaims_a_crashed_lock']]
def run(cmd):
 name=pathlib.Path(cmd[1]).name;start=time.monotonic();env=os.environ.copy();env['FM_TEST_SKIP_ORPHAN_REAP']='1'
 with (E/(name+'.focused.log')).open('w') as f:
  f.write('$ FM_TEST_SKIP_ORPHAN_REAP=1 '+' '.join(cmd)+'\n');f.flush();p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT,env=env,start_new_session=True)
  try:rc=p.wait(timeout=1200)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:rc=p.wait(timeout=20)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);rc=p.wait()
  f.write('\nEXIT_STATUS='+str(rc)+'\n')
 return {'command':' '.join(cmd),'exit':rc,'seconds':round(time.monotonic()-start,2)}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
 res=list(ex.map(run,checks))
(E/'focused-results.json').write_text(json.dumps(res,indent=2));print(json.dumps(res),flush=True)
