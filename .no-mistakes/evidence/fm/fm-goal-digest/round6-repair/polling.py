import json,os,pathlib,shutil,signal,subprocess,time
root=pathlib.Path.cwd(); e=root/'.test-goal-digest-repair'; home=e/'home'
prompt='Summarize this goal digest for its owner in at most 12 short lines: new merges, items waiting, missed ETAs, stalls and anything blocked. Use only the input below.\n'+(home/'data/goal-digest/latest.md').read_text()
args=[shutil.which('claude'),'-p','--model','haiku','--tools','','--setting-sources','','--strict-mcp-config','--no-session-persistence','--debug-file',str(e/'polling-debug.log')]
(e/'polling-argv.json').write_text(json.dumps(args)); start=time.monotonic()
with (e/'polling-out.txt').open('w') as out,(e/'polling-err.txt').open('w') as err:
 p=subprocess.Popen(args,cwd=home,env=dict(os.environ,CHOKIDAR_USEPOLLING='1'),stdin=subprocess.PIPE,stdout=out,stderr=err,start_new_session=True,text=True)
 (e/'polling.pid').write_text(str(p.pid))
 try: p.communicate(prompt,timeout=120)
 except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
record=dict(exit=p.returncode,elapsed=time.monotonic()-start,nonempty_stdout=bool((e/'polling-out.txt').read_text().strip()))
(e/'polling-result.json').write_text(json.dumps(record,indent=2));print(record)
