import pathlib,subprocess,tempfile,shutil,os,json
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE');W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-phantom-red-',dir=str(R)))
try:
 shutil.copytree(R/'bin',W/'bin');shutil.copytree(R/'tests',W/'tests');(W/'bin/fm-stall-ledger-lib.sh').write_bytes(subprocess.check_output(['git','show','ffc2994f8:bin/fm-stall-ledger-lib.sh']))
 e=os.environ.copy();e['FM_TEST_SKIP_ORPHAN_REAP']='1'
 with (E/'regression-before-phantom.log').open('w') as f:
  f.write('Current installation-boundary regression against immediate pre-fix ffc2994f8 stall library\n$ bash tests/fm-stall-ledger.test.sh\n');f.flush();p=subprocess.run(['bash','tests/fm-stall-ledger.test.sh'],cwd=W,env=e,stdout=f,stderr=subprocess.STDOUT,timeout=300);f.write('\nEXIT_STATUS='+str(p.returncode)+'\n')
 text=(E/'regression-before-phantom.log').read_text();result={'exit':p.returncode,'expected_failure_observed':p.returncode==1 and 'an unconfirmed completion must not create a phantom stall' in text};(E/'regression-before-phantom-results.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
finally:shutil.rmtree(W)
