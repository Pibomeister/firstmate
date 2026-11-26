from pathlib import Path
import subprocess,json,time,os,signal
exec(Path('.gate-tests/run-targeted.py').read_text().split('checks=')[0])
# The repository's helper intentionally falls back to /tmp when TMPDIR contains .git.
# Its test-owned ephemeral directories and registries are removed by tests/lib.sh.
env['TMPDIR']=str(root)
results=[]
for name in ['fm-home-summary-refresh','fm-fleet-snapshot-view']:
 h=root/'.gate-tests'/('rerun-user-'+name);h.mkdir(exist_ok=True);e=env.copy();e.update(HOME=str(h),XDG_CONFIG_HOME=str(h),CLAUDE_CONFIG_DIR=str(h))
 cmd=['bash','tests/'+name+'.test.sh'];t=time.time()
 with (ev/(name+'-normal-tmp.log')).open('w') as f:
  p=subprocess.Popen(cmd,env=e,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(1400)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);rc=p.wait()
  try:os.killpg(p.pid,signal.SIGTERM)
  except (ProcessLookupError,PermissionError):pass
 r=dict(command=cmd,exit=rc,seconds=round(time.time()-t,2));results.append(r);(ev/'normal-tmp-results.json').write_text(json.dumps(results,indent=2));print(r,flush=True)
print('COMPLETE',flush=True)
