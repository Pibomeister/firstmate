import hashlib,json,os,pathlib,shutil,subprocess,time
root=pathlib.Path.cwd(); e=root/'.test-goal-digest-repair'; home=e/'verified-home'
(home/'config').mkdir(parents=True,exist_ok=True)
(home/'review.txt').write_text('Synthetic project: T1 complete. One owner decision: choose north or south. ETA: 2099-01-01.\n')
(home/'config/goal-digest').write_text(f'review = Synthetic | {home}/review.txt\nsummarize_model = haiku\n')
claude=shutil.which('claude'); wrapper=e/'verified-native-claude'
wrapper.write_text('#!/usr/bin/env python3\nimport json,os,pathlib,sys\ne=pathlib.Path('+repr(str(e))+')\n(e/"verified-argv.json").write_text(json.dumps({"argv":['+repr(claude)+']+sys.argv[1:],"CHOKIDAR_USEPOLLING":os.getenv("CHOKIDAR_USEPOLLING"),"pid":os.getpid()}))\nos.execv('+repr(claude)+', ['+repr(claude)+']+sys.argv[1:]+["--debug-file",str(e/"verified-debug.log")])\n')
wrapper.chmod(0o755);start=time.monotonic()
r=subprocess.run([str(root/'bin/fm-goal-digest.sh'),'run'],cwd=home,env=dict(os.environ,FM_HOME=str(home),FM_TEST_SEAM='1',FM_GOAL_DIGEST_CLAUDE=str(wrapper),CHOKIDAR_USEPOLLING='0',TMPDIR=str(e/'tmp')),capture_output=True,text=True)
summary=home/'data/goal-digest/summary.txt'
record=dict(exit=r.returncode,elapsed=time.monotonic()-start,stdout=r.stdout,stderr=r.stderr,summary_exists=summary.exists(),summary=summary.read_text() if summary.exists() else None,head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),source_sha256=hashlib.sha256((root/'bin/fm-goal-digest.sh').read_bytes()).hexdigest())
(e/'verified-result.json').write_text(json.dumps(record,indent=2));print(json.dumps(record))
if r.returncode!=0 or not summary.exists() or not summary.read_text().strip() or 'model runner failed' in r.stderr:raise SystemExit(1)
