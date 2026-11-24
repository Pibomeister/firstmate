import hashlib, json, os, pathlib, shutil, signal, subprocess, time
root=pathlib.Path.cwd()
lab=root/'.goal-digest-recheck'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M85WPJHSW42PYT79RQP58A6K/recheck')
home=lab/'fixture'
(home/'config').mkdir(parents=True)
review=home/'synthetic-review.txt'
review.write_text('Synthetic validation only: T1 complete; T8 waiting for a synthetic review.\n')
(home/'config/goal-digest').write_text('review = Synthetic review | '+str(review)+'\nsummarize = on\nsummarize_model = haiku\n')
claude=shutil.which('claude')
assert claude, 'claude missing from PATH'
observer=lab/'claude-observer.py'
observer.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
out=pathlib.Path(os.environ['DIGEST_RECHECK_EVIDENCE'])
prompt=sys.stdin.buffer.read()
(out/'model-input.txt').write_bytes(prompt)
(out/'model-command.json').write_text(json.dumps({'argv':[os.environ['DIGEST_RECHECK_CLAUDE']]+sys.argv[1:],'safe_mode':os.environ.get('CLAUDE_CODE_SAFE_MODE'),'started':time.time()},indent=2))
with (out/'model-stdout.txt').open('wb') as stdout, (out/'model-stderr.txt').open('wb') as stderr:
 p=subprocess.Popen([os.environ['DIGEST_RECHECK_CLAUDE']]+sys.argv[1:],stdin=subprocess.PIPE,stdout=stdout,stderr=stderr)
 (out/'model-pid.txt').write_text(str(p.pid))
 p.communicate(prompt)
 (out/'model-exit.txt').write_text(str(p.returncode))
 sys.stdout.buffer.write((out/'model-stdout.txt').read_bytes())
 raise SystemExit(p.returncode)
''')
observer.chmod(0o755)
env=dict(os.environ, FM_HOME=str(home), FM_TEST_SEAM='1',FM_GOAL_DIGEST_CLAUDE=str(observer),DIGEST_RECHECK_EVIDENCE=str(evidence),DIGEST_RECHECK_CLAUDE=claude,CLAUDE_CODE_SAFE_MODE='1')
# Safe mode excludes repository/user instructions, hooks and plugins while retaining
# the existing native auth. Fixed model/tools/MCP/persistence argv stays unchanged.
started=time.monotonic()
p=subprocess.Popen([str(root/'bin/fm-goal-digest.sh'),'run'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
try:
 stdout,stderr=p.communicate(timeout=140)
except subprocess.TimeoutExpired:
 os.killpg(p.pid,signal.SIGKILL)
 stdout,stderr=p.communicate()
try:
 # Stop any owned command descendants even if the collector already exited.
 os.killpg(p.pid,signal.SIGKILL)
except ProcessLookupError:
 pass
out=home/'data/goal-digest'
for name in ('latest.json','latest.md','summary.txt'):
 if (out/name).is_file(): shutil.copyfile(out/name,evidence/name)
result={'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),'source_sha256':hashlib.sha256((root/'bin/fm-goal-digest.sh').read_bytes()).hexdigest(),'command':['bin/fm-goal-digest.sh','run'],'claude_version':subprocess.check_output([claude,'--version'],text=True).strip(),'elapsed_seconds':round(time.monotonic()-started,2),'exit':p.returncode,'stdout':stdout,'stderr':stderr,'summary_present':(out/'summary.txt').is_file(),'launchd':'not executed: Workspace boundary forbids modifying system state outside the worktree; previous test finding explicitly says to preserve this refusal without a bypass.'}
(evidence/'result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2),flush=True)
