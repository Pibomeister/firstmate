import pathlib,subprocess,os,re,sys
suite=sys.argv[1]
evidence=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS')
env=dict(os.environ,FM_TEST_SKIP_ORPHAN_REAP='1')
if suite=='watchdog':
 diff=subprocess.check_output(['git','diff','--unified=0','58a34e1c','HEAD','--','tests/fm-watchdog.test.sh'],text=True)
 names=['test_stall_proof_and_text_guards']+re.findall(r'^\+(test_\w+)\(\)',diff,re.M)
elif suite=='crew-state':
 names=['test_captured_axi_status_shapes','test_parked_question_preserves_options_without_minting_components','test_toon_quoted_text_keeps_escapes_and_columns','test_status_snapshot_readonly_and_shared_across_sweep','test_status_snapshot_preserves_parked_question_and_wait']
else:names=[]
cmd=['bash',f'tests/fm-{suite}.test.sh',*names]
with (evidence/(suite+'-retry.log')).open('w',buffering=1) as f:
 f.write('COMMAND: FM_TEST_SKIP_ORPHAN_REAP=1 '+' '.join(cmd)+'\n')
 rc=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
 f.write(f'\nEXIT_STATUS={rc}\n')
print(suite,'exit',rc)
raise SystemExit(rc)
