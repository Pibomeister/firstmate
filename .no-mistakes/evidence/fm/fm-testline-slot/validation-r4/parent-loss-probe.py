import pathlib,os,subprocess as sp,time,json,signal,shutil
root=pathlib.Path.cwd();h=root/'.validation-r4/parent-loss-probe'
for d in ['state','data','config','projects','shim']:(h/d).mkdir(parents=True,exist_ok=True)
(h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
shim=h/'shim/mkdir';shim.write_text('''#!/bin/bash
if [ -n "${FM_HOME_SUMMARY_STAGE_FILE:-}" ] && [ ! -e "$FM_PROBE_MARK" ]; then
 printf '%s\\n' "$PPID" > "$FM_PROBE_MARK"
 sleep 3
fi
exec /bin/mkdir "$@"
''');shim.chmod(0o755)
en=os.environ.copy()
for k in list(en):
 if k.startswith('FM_') or k=='BASH_ENV':en.pop(k,None)
en.update(FM_HOME=str(h),FM_ROOT_OVERRIDE=str(root),FM_PROBE_MARK=str(h/'mark'),PATH=str(h/'shim')+':'+en['PATH'])
p=sp.Popen([str(root/'bin/fm-home-summary-refresh.sh'),'--best-effort'],env=en,stdout=sp.PIPE,stderr=sp.PIPE,text=True,start_new_session=True)
deadline=time.monotonic()+30
while not (h/'mark').exists():
 assert time.monotonic()<deadline
 time.sleep(.05)
worker=int((h/'mark').read_text());pg=os.getpgid(worker)
os.kill(p.pid,signal.SIGKILL);p.communicate(timeout=5)
start=time.monotonic();observations=[]
for i in range(100):
 q=sp.run(['ps','-p',str(worker),'-o','stat='],capture_output=True,text=True)
 live=q.returncode==0 and bool(q.stdout.strip()) and not q.stdout.strip().startswith('Z')
 stages=[f.name for f in (h/'state').glob('.home-summary-stage.*')]
 observations.append(dict(seconds=round(time.monotonic()-start,3),worker_live=live,stages=stages))
 if not live:break
 time.sleep(.1)
print(json.dumps(dict(parent_exit=p.returncode,worker=worker,observations=observations),indent=2))
assert not observations[-1]['worker_live'] and not observations[-1]['stages']
try:os.killpg(pg,signal.SIGKILL)
except ProcessLookupError:pass
shutil.rmtree(h)
