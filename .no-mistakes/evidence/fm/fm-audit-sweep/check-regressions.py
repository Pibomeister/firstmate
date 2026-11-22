import pathlib,tempfile,shutil,subprocess,os,concurrent.futures,time,json,signal
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE');W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-regressions-',dir=str(R)))
checks=[('stall', 'fm-stall-ledger-lib.sh',['bash','tests/fm-stall-ledger.test.sh'],'an unconfirmed nudge closed the stall'),('receipt','fm-watchdog.sh',['bash','tests/fm-watchdog.test.sh','test_heartbeat_swallowed_enter_never_counts_as_delivery'],'was recorded as a delivery'),('prune','fm-hung-ladder.sh',['bash','tests/fm-hung-ladder.test.sh','test_prune_reclaims_a_crashed_lock'],'reclaims a crashed lock')]
def run(c):
 name,product,cmd,oracle=c;d=W/name;d.mkdir();shutil.copytree(R/'bin',d/'bin');shutil.copytree(R/'tests',d/'tests');(d/'bin'/product).write_bytes(subprocess.check_output(['git','show','c81b71352a0b4d4636a7e46962134e25fa214d48:bin/'+product],cwd=R))
 env=os.environ.copy();env['FM_TEST_SKIP_ORPHAN_REAP']='1'
 log=E/('regression-before-'+name+'.log')
 with log.open('w') as f:
  f.write('Current regression test against base version of bin/'+product+'\n$ '+' '.join(cmd)+'\n');f.flush();p=subprocess.Popen(cmd,cwd=d,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(timeout=600)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:rc=p.wait(timeout=20)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);rc=p.wait()
  f.write('\nEXIT_STATUS='+str(rc)+'\n')
 text=log.read_text();result={'regression':name,'exit':rc,'expected_failure_observed':rc==1 and oracle in text,'oracle':oracle};print(json.dumps(result),flush=True);return result
try:
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:results=list(ex.map(run,checks))
 (E/'regression-before-results.json').write_text(json.dumps(results,indent=2))
finally:shutil.rmtree(W)
