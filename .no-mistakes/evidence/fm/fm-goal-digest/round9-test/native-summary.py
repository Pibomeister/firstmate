import json, os, pathlib, shutil, subprocess as sp, time
R=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M85WPJHSW42PYT79RQP58A6K/round9-test')
W=R/'.test-goal-digest-current/native'
(W/'config').mkdir(parents=True)
(W/'review.txt').write_text('Synthetic project: T1 complete. Owner decision: choose a route. ETA: 2099-01-01.\n')
(W/'config/goal-digest').write_text(f'review = Synthetic | {W}/review.txt\nsummarize_model = haiku\n')
C=shutil.which('claude')
assert C, 'claude not on PATH'
wrapper=W/'claude-recorder'
wrapper.write_text('''#!/usr/bin/env python3
import json,pathlib,subprocess,sys,time
E=pathlib.Path('''+repr(str(E))+''')
argv=['''+repr(C)+''']+sys.argv[1:]
prompt=sys.stdin.read()
(E/'native-claude-argv.json').write_text(json.dumps(argv))
(E/'native-claude-input.txt').write_text(prompt)
t=time.monotonic()
r=subprocess.run(argv,input=prompt,text=True,capture_output=True)
(E/'native-claude-result.json').write_text(json.dumps({'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'elapsed_seconds':round(time.monotonic()-t,3),'prompt_bytes':len(prompt.encode()),'CHOKIDAR_USEPOLLING':__import__('os').environ.get('CHOKIDAR_USEPOLLING'),'served_model_metadata':'not exposed by text mode'},indent=2))
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
sys.exit(r.returncode)
''')
wrapper.chmod(0o755)
env=dict(os.environ,FM_HOME=str(W),FM_TEST_SEAM='1',FM_GOAL_DIGEST_CLAUDE=str(wrapper),TMPDIR=str(R/'.test-goal-digest-current/tmp'))
S=R/'bin/fm-goal-digest.sh'
result={'result':'fail','head':sp.check_output(['git','rev-parse','HEAD'],text=True).strip()}
try:
    t=time.monotonic()
    r=sp.run([str(S),'run'],cwd=W,env=env,text=True,capture_output=True,timeout=150)
    (E/'native-digest-run.log').write_text(r.stdout+r.stderr+f'\nexit={r.returncode} elapsed={time.monotonic()-t:.3f}\n')
    p=E/'native-claude-result.json'
    native=json.loads(p.read_text()) if p.exists() else None
    summary=W/'data/goal-digest/summary.txt'
    assert r.returncode==0 and native and native['exit']==0 and summary.exists() and summary.read_text().strip(), (r,native)
    for name in ('latest.json','latest.md','summary.txt'):
        shutil.copyfile(W/'data/goal-digest'/name,E/('native-'+name))
    before=p.stat().st_mtime_ns
    again=sp.run([str(S),'run'],cwd=W,env=env,text=True,capture_output=True,timeout=150)
    (E/'native-unchanged.log').write_text(again.stdout+again.stderr+f'\nexit={again.returncode}\n')
    assert again.returncode==0 and 'changed=no' in again.stdout
    assert p.stat().st_mtime_ns==before
    result.update(result='pass',runner_exit=native['exit'],elapsed_seconds=native['elapsed_seconds'],unchanged_skipped_model=True)
    print('PASS actual fixed Haiku invocation and unchanged skip',flush=True)
except BaseException as ex:
    result['error']=repr(ex)
    raise
finally:
    (E/'native-summary-result.json').write_text(json.dumps(result,indent=2)+'\n')
    shutil.rmtree(W)
