import json,os,pathlib,shutil,signal,subprocess,time
root=pathlib.Path.cwd(); e=root/'.test-goal-digest-repair'; home=e/'home'; claude=shutil.which('claude')
prompt='Summarize this goal digest for its owner in at most 12 short lines: new merges, items waiting, missed ETAs, stalls and anything blocked. Use only the input below.\n'+(home/'data/goal-digest/latest.md').read_text()
args=[claude,'-p','--model','haiku','--tools','','--setting-sources','','--strict-mcp-config','--no-session-persistence','--safe-mode','--debug-file',str(e/'safe-debug.log')]
(e/'safe-argv.json').write_text(json.dumps(args)); start=time.monotonic()
with (e/'safe-out.txt').open('w') as out,(e/'safe-err.txt').open('w') as err:
 p=subprocess.Popen(args,cwd=home,stdin=subprocess.PIPE,stdout=out,stderr=err,start_new_session=True,text=True)
 (e/'safe.pid').write_text(str(p.pid))
 try: p.communicate(prompt,timeout=120)
 except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
record=dict(exit=p.returncode,elapsed=time.monotonic()-start,nonempty_stdout=bool((e/'safe-out.txt').read_text().strip()))
(e/'safe-result.json').write_text(json.dumps(record,indent=2));print(record)
