import json,os,pathlib,shutil,subprocess,time
root=pathlib.Path.cwd(); evidence=root/'.test-goal-digest-repair'; home=evidence/'home'
(home/'review.txt').write_text('Synthetic project: T1 complete. One owner decision: choose north or south. ETA: 2099-01-01.\n')
(home/'config/goal-digest').write_text(f'review = Synthetic | {home}/review.txt\nsummarize_model = haiku\n')
claude=shutil.which('claude')
wrapper=evidence/'native-claude'
wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execv('+repr(claude)+', ['+repr(claude)+']+sys.argv[1:]+["--debug-file",'+repr(str(evidence/'native-debug.log'))+'])\n')
wrapper.chmod(0o755)
start=time.monotonic()
r=subprocess.run([str(root/'bin/fm-goal-digest.sh'),'run'],cwd=home,env=dict(os.environ,FM_HOME=str(home),FM_TEST_SEAM='1',FM_GOAL_DIGEST_CLAUDE=str(wrapper),TMPDIR=str(evidence/'tmp')),capture_output=True,text=True)
record=dict(exit=r.returncode,elapsed=time.monotonic()-start,stdout=r.stdout,stderr=r.stderr,summary_exists=(home/'data/goal-digest/summary.txt').exists())
(evidence/'reproduction.json').write_text(json.dumps(record,indent=2)); print(json.dumps(record))
