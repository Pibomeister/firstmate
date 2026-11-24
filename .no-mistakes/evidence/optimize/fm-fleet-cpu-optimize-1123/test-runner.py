import os, subprocess, json, time
from pathlib import Path
root=Path.cwd(); ev=Path("~/.no-mistakes/evidence/01M87HDDK5H17G11VP6A2ZZE3D")
env=os.environ.copy(); env["TMPDIR"]=str(root/".nm-validation/tmp")
for key in ("FM_HOME", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"):
    env.pop(key,None)
checks=[("fork-free", "tests/fm-fork-free-helpers.test.sh",None), ("backend-metadata", "tests/fm-backend.test.sh","test_meta_get_and_backend_of_meta"), ("classify-decisions", "tests/fm-classify-decision-key.test.sh",None), ("classify-correlations", "tests/fm-classify-corr-token.test.sh",None), ("fleet-snapshot", "tests/fm-fleet-snapshot-view.test.sh",None), ("contribution-input", "tests/fm-fleet-snapshot-contribution-input.test.sh",None), ("cursor-drain", "tests/fm-wake-drain-open-decisions-cursor.test.sh",None), ("crew-state", "tests/fm-crew-state.test.sh",None)]
results=[]
for label,script,selector in checks:
    e=env.copy()
    if selector:e["FM_TEST_ONLY"]=selector
    t=time.monotonic()
    with (ev/(label+".log")).open("w") as f:
        p=subprocess.run(["/bin/bash",script],env=e,stdout=f,stderr=subprocess.STDOUT)
    row={"label":label,"command":("FM_TEST_ONLY="+selector+" " if selector else "")+"/bin/bash "+script,"exit":p.returncode,"seconds":round(time.monotonic()-t,2)}
    results.append(row); (ev/"targeted-tests.json").write_text(json.dumps(results,indent=2)); print(json.dumps(row),flush=True)
raise SystemExit(any(r["exit"] for r in results))
