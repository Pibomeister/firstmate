import pathlib,subprocess,os,json
root=pathlib.Path.cwd();home=root/'.test-306/council'; env=os.environ.copy();env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'))
for x in ['FM_ROOT_OVERRIDE','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS']:env.pop(x,None)
cases={
 'changed-behavior':'PR #577 no-mistakes test awaiting_approval. The once-rerun failed on changed behavior in this PR. A approve the park, B wait.',
 'run-changed':'PR #577 no-mistakes test awaiting_approval. The test run changed behavior. A approve, B wait.',
 'deploy':'PR #577 no-mistakes ci awaiting_approval. A deploy to production, B wait.',
 'force-dot-push':'PR #577 no-mistakes push awaiting_approval. A force.push the rebased branch, B wait.',
 'force-flag':'PR #577 no-mistakes push awaiting_approval. A git push origin --force, B wait.',
 'pii':'PR #577 no-mistakes test awaiting_approval. A reveal PII, B wait.',
 'db-write':'PR #577 no-mistakes test awaiting_approval. A write to the shared database, B wait.',
 'messages':'PR #577 no-mistakes test awaiting_approval. A send messages-to-people, B wait.',
 'signin':'PR #577 no-mistakes test awaiting_approval. A sign_in with an account, B wait.',
 'spend':'PR #577 no-mistakes test awaiting_approval. A spend money, B wait.',
 'plain-merge':'no-mistakes run green; PR #600 awaiting approval to merge. A merge now, B wait.',
 'plain-release':'PR #600 awaiting approval to release. A release now, B wait.'
}
before=(home/'state/watchdog/model-calls.tsv').read_bytes()
for key,record in cases.items():
 f=home/'guard.txt';f.write_text(record+'\n')
 p=subprocess.run(['bash','bin/fm-watchdog.sh','council','--task','boundaries','--key',key,'--record-file',str(f)],env=env,capture_output=True,text=True,timeout=30)
 print(record+'\n'+p.stdout.strip(),flush=True)
 assert p.returncode==0 and p.stdout.startswith('council=held answer=none'),p
assert (home/'state/watchdog/model-calls.tsv').read_bytes()==before,'a reserved record reached a model'
print('Every reserved case stayed held; no model was called.',flush=True)
