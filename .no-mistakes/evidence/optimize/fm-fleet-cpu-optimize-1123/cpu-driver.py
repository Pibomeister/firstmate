import os, subprocess, json, shutil, time, statistics, signal
from pathlib import Path
root=Path.cwd(); tmp=root/".nm-validation"; ev=Path("~/.no-mistakes/evidence/01M87HDDK5H17G11VP6A2ZZE3D"); lab=tmp/"cpu-home"
env=os.environ.copy()
for k in list(env):
    if k.startswith("FM_") or k in ["TASKS_AXI_FILE","TASKS_AXI_BACKEND","TMUX","TMUX_PANE","REX_SESSION","REX_BLOCK","ORCA_TERMINAL_HANDLE"]:env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(tmp/"tmp"),FM_SNAPSHOT_NOW="2026-11-24T12:00:00Z",FM_SNAPSHOT_NOW_EPOCH="1795521600",FM_CREW_STATE_NO_FORGE="1",FM_SNAPSHOT_CREW_STATE_TIMEOUT="120")
versions={"base":tmp/"base","target":root}
results=[]; expected=None
try:
    for pair in range(3):
        for version in (["base","target"] if pair%2==0 else ["target","base"]):
            shutil.rmtree(lab,ignore_errors=True)
            for d in ["state","data","config","projects/local"]:(lab/d).mkdir(parents=True,exist_ok=True)
            (lab/".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
            (lab/"data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
            for i in range(8):
                id="task-%02d"%i
                (lab/"state"/(id+".meta")).write_text("kind=scout\nharness=codex\nmode=scout\nyolo=off\nproject=synthetic\nworktree="+str(lab/"projects/local")+"\n")
                lines=[]
                for j in range(20):
                    lines.extend(["needs-decision [key=k%d]: question %d"%(j,j),"working: unrelated progress","resolved [key=k%d]: answered"%j])
                lines.append("blocked [key=remaining] [at=1795521500]: needs token")
                (lab/"state"/(id+".status")).write_text("\n".join(lines)+"\n")
            out=ev/("cpu-%d-%s.json"%(pair+1,version));err=ev/("cpu-%d-%s.stderr"%(pair+1,version))
            load_before=os.getloadavg(); start=time.monotonic()
            with out.open("w") as f,err.open("w") as e,(ev/("cpu-%d-%s.stages"%(pair+1,version))).open("w") as stage:
                env["FM_SNAPSHOT_STAGE_FD"]=str(stage.fileno())
                p=subprocess.Popen(["/bin/bash",str(versions[version]/"bin/fm-fleet-snapshot.sh"),"--json"],cwd=root,env=env,stdout=f,stderr=e,pass_fds=(stage.fileno(),),start_new_session=True)
                def expired(sig, frame): raise TimeoutError("snapshot exceeded 180s")
                signal.signal(signal.SIGALRM,expired);signal.alarm(180)
                try:
                    _,status,usage=os.wait4(p.pid,0);p.returncode=os.waitstatus_to_exitcode(status)
                except BaseException:
                    os.killpg(p.pid,signal.SIGKILL);os.wait4(p.pid,0);p.returncode=137;raise
                finally:signal.alarm(0)
            row={"pair":pair+1,"version":version,"exit":p.returncode,"pid":p.pid,"cpu_user_seconds":usage.ru_utime,"cpu_system_seconds":usage.ru_stime,"cpu_seconds":usage.ru_utime+usage.ru_stime,"wall_seconds":time.monotonic()-start,"load1_before":load_before[0],"load1_after":os.getloadavg()[0]}
            assert p.returncode==0,row
            obj=json.loads(out.read_text());assert len(obj["tasks"])==8
            for r in obj["tasks"]:assert r["hints"]["open_decisions"]==[{"key":"remaining","verb":"blocked","summary":"needs token"}]
            # Full output must remain identical; only the executable code revision differs.
            if expected is None:expected=json.loads(json.dumps(obj).replace(str(tmp/"base"),str(root)))
            else:assert json.loads(json.dumps(obj).replace(str(tmp/"base"),str(root)))==expected,"Snapshot JSON differs across revisions/runs"
            results.append(row);(ev/"cpu-samples.json").write_text(json.dumps(results,indent=2));print(json.dumps(row),flush=True)
    base=[r["cpu_seconds"] for r in results if r["version"]=="base"]; target=[r["cpu_seconds"] for r in results if r["version"]=="target"]
    improvement=1-statistics.median(target)/statistics.median(base)
    paired=[1-next(r["cpu_seconds"] for r in results if r["pair"]==i and r["version"]=="target")/next(r["cpu_seconds"] for r in results if r["pair"]==i and r["version"]=="base") for i in [1,2,3]]
    result={"base_median_cpu":statistics.median(base),"target_median_cpu":statistics.median(target),"base_range":[min(base),max(base)],"target_range":[min(target),max(target)],"median_cpu_improvement":improvement,"paired_improvements":paired,"decision":"local CPU reduction established" if min(paired)>0 and improvement>.10 and max(target)<min(base) else "local CPU reduction not established","scope":"synthetic local snapshot; not fleet supervision or host-load attribution","outputs":"all six complete JSON outputs identical after normalizing only the extracted baseline code-root prefix"}
    (ev/"cpu-result.json").write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
finally:shutil.rmtree(lab,ignore_errors=True)
