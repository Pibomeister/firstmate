import os, pathlib, subprocess, concurrent.futures, json, time, signal
root=pathlib.Path.cwd()
e=pathlib.Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8')
names=['fm-session-start','fm-teardown','fm-teardown-endpoint-safety','fm-delegated','fm-brief','fm-spawn-agent-exit-status']
def run(name):
    env=os.environ.copy()
    for k in list(env):
        if k.startswith('FM_') or k.startswith('TASKS_AXI_') or k in ['TMUX','TMUX_PANE','HERDR_SESSION','HERDR_SOCKET_PATH','ORCA_TERMINAL_HANDLE']: env.pop(k,None)
    env['TMPDIR']=str(root/'.nm-test-tmp'); env['GIT_CONFIG_GLOBAL']='/dev/null'; env['GIT_CONFIG_NOSYSTEM']='1'
    cmd=['bash',f'tests/{name}.test.sh']; start=time.monotonic()
    with (e/f'round2-{name}.log').open('w') as f:
        f.write('revision=221e24e90ba26044c46bb73f3f834624d678b53e\n'); f.flush()
        p=subprocess.Popen(cmd,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        (e/f'round2-{name}.pid').write_text(str(p.pid))
        try: rc=p.wait(timeout=2900)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGTERM)
            try: p.wait(timeout=30)
            except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
            rc=124
    result={'command':' '.join(cmd),'exit_code':rc,'seconds':round(time.monotonic()-start,1)}
    (e/f'round2-{name}.result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    results=list(pool.map(run,names))
(e/'round2-baselines.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(any(r['exit_code']!=0 for r in results))
