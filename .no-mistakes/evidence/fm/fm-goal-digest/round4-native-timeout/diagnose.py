import json, os, pathlib, shutil, signal, subprocess, time
w=pathlib.Path(__file__).resolve().parent
args=[shutil.which("claude"),"-p","--model","haiku","--tools","","--setting-sources","","--strict-mcp-config","--no-session-persistence","--debug-file",str(w/"native-debug.log")]
prompt="Summarize this goal digest for its owner in at most 12 short lines: new merges, items waiting, missed ETAs, stalls and anything blocked. Use only the input below.\n"+(w/"native/data/goal-digest/latest.md").read_text()
(w/"diagnostic-argv.json").write_text(json.dumps(args))
start=time.monotonic()
with (w/"diagnostic-stdout.log").open("w") as out, (w/"diagnostic-stderr.log").open("w") as err:
    p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=out,stderr=err,start_new_session=True,cwd=w/"native")
    try:
        p.communicate(prompt.encode(),timeout=120)
        rc=p.returncode
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL)
        p.communicate()
        rc=124
receipt={"exit":rc,"elapsed_seconds":round(time.monotonic()-start,2),"pid":p.pid,"nonempty_stdout":bool((w/"diagnostic-stdout.log").read_text().strip())}
(w/"diagnostic-result.json").write_text(json.dumps(receipt,indent=2))
print(json.dumps(receipt))
