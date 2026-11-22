import os,json,subprocess,pathlib
p=pathlib.Path.cwd()/'.test-phase-tmp/hook-reds';(p/'state').mkdir(parents=True,exist_ok=True)
env=dict(os.environ,FM_HOME=str(p),FM_STATE_OVERRIDE=str(p/'state'),FM_ROOT_OVERRIDE=str(p))
def hook(payload):
 r=subprocess.run(['bash','bin/fm-pstack-verify-hook.sh','--cursor'],input=json.dumps(payload),env=env,text=True,capture_output=True)
 print('INPUT',json.dumps(payload));print('OUTPUT',r.stdout,'EXIT',r.returncode);assert r.returncode==0
 return r.stdout
common={'cursor_version':'x','conversation_id':'independent-red-run'}
hook(dict(common,hook_event_name='afterAgentResponse',text='fixed tests/a_test.py',generation_id='g1'))
for generation in ['g1','g2']:
 hook(dict(common,hook_event_name='afterShellExecution',command='pytest tests/a_test.py',output='FAILED tests/a_test.py::test_one - assert\nFAILED tests/a_test.py::test_two - assert\n',duration=900,generation_id=generation))
 out=hook(dict(common,hook_event_name='postToolUse',tool_name='Read',tool_input={'path':'src/a.py'},tool_output='{"exitCode":0}',generation_id=generation))
 assert (not out.strip()) if generation=='g1' else ('principle-attack-the-premise' in out)
print('RESULT: two failures in one run count once; a second failing run triggers the premise check.')
