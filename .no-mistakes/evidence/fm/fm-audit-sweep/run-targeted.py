import concurrent.futures, json, os, pathlib, signal, subprocess, time
E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE')
suites=['fm-watchdog','fm-stall-ledger','fm-hung-ladder','fm-handoff-launch','fm-herdr-lab','fm-herdr-owned-xdg','fm-memory-guard','fm-permission-prompt','fm-pstack-verify-hook','fm-control-relaunch','fm-daemon','fm-tmux-relaunch-input','fm-handoff-launch-runtime','fm-herdr-owned-xdg-live-e2e']
results=[]
def run(s):
    cmd=['bash',f'tests/{s}.test.sh']; start=time.monotonic()
    print('START '+s,flush=True)
    with (E/(s+'.log')).open('w') as f:
        f.write('$ '+' '.join(cmd)+'\n'); f.flush()
        env=os.environ.copy(); env['FM_TEST_SKIP_ORPHAN_REAP']='1'
        p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT,start_new_session=True,env=env)
        timed=False
        try: rc=p.wait(timeout=1500)
        except subprocess.TimeoutExpired:
            timed=True; os.killpg(p.pid,signal.SIGTERM)
            try: rc=p.wait(timeout=20)
            except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); rc=p.wait()
        f.write('\nEXIT_STATUS='+str(rc)+' TIMEOUT='+str(timed)+'\n')
    r={'suite':s,'command':' '.join(cmd),'exit':rc,'timeout':timed,'seconds':round(time.monotonic()-start,2)}
    print(json.dumps(r),flush=True)
    return r
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
    for future in concurrent.futures.as_completed([ex.submit(run,s) for s in suites]):
        results.append(future.result()); (E/'targeted-results.json').write_text(json.dumps(results,indent=2))
print('ALL_REQUIRED_TARGETED_CHECKS_FINISHED',flush=True)
