import os, pathlib, subprocess, time, signal
root=pathlib.Path.cwd()
ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5P9MH9YHZ7098T3VRGQQMR0')
base=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','TMUX']:
    base.pop(k,None)
base.update(FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',TMPDIR=str(root/'.test-tmp'))
f=(ev/'live-product-transcript.log').open('w',buffering=1)
def log(s):
    print(s,flush=True); f.write(s+'\n')
def home(name):
    h=root/'.test-tmp'/name
    subprocess.run(['bin/fm-lab-home.sh','create',str(h)],check=True,env=base,stdout=subprocess.DEVNULL)
    e=dict(base,FM_HOME=str(h)); return h,e
def run(args,e):
    p=subprocess.run(args,env=e,capture_output=True,text=True,timeout=45)
    log('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}')
    return p
def checkpoint(e,n=5): return run(['bin/fm-watch-checkpoint.sh','--seconds',str(n)],e)
def queued(h,e):
    return run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check lab "check: lab actionable work"'],dict(e,FM_STATE_OVERRIDE=str(h/'state')))
def ready(h,p):
    for _ in range(300):
        if (h/'state/.last-watcher-beat').exists() and (h/'state/.watch.lock/pid').exists(): return
        if p.poll() is not None: raise AssertionError('watcher exited before readiness')
        time.sleep(.05)
    raise AssertionError('no live beacon')
h,e=home('live-quiet')
for cycle in range(2):
    log(f'SCENARIO quiet checkpoint and empty rearm, cycle {cycle+1}')
    p=checkpoint(e)
    assert p.returncode==0 and 'checkpoint: no actionable wake within 5s' in p.stdout and not p.stderr
    assert not (h/'state/.watch.lock/pid').exists()
    log('queue='+repr((h/'state/.wake-queue').read_text() if (h/'state/.wake-queue').exists() else ''))
h,e=home('live-recovery')
assert queued(h,e).returncode==0
log('SCENARIO durable work resurfaces once and survives quiet checkpoint')
p=checkpoint(e); assert p.returncode==0 and 'check: rearm-resurface' in p.stdout
marker=(h/'state/.watcher-down').read_text(); queue=(h/'state/.wake-queue').read_text()
log('recovery='+marker+'durable queue='+queue)
p=checkpoint(e); assert p.returncode==0 and 'no actionable wake' in p.stdout and 'rearm-resurface' not in p.stdout
assert (h/'state/.watcher-down').read_text()==marker and (h/'state/.wake-queue').read_text()==queue
log('same recovery generation and queued row retained')
log('SCENARIO new work arriving during a quiet checkpoint is delivered')
h,e=home('live-concurrent')
out=(ev/'concurrent-checkpoint.out').open('w'); err=(ev/'concurrent-checkpoint.err').open('w')
p=subprocess.Popen(['bin/fm-watch-checkpoint.sh','--seconds','20'],env=e,stdout=out,stderr=err)
ready(h,p); assert queued(h,e).returncode==0
rc=p.wait(timeout=35); out.close(); err.close()
text=(ev/'concurrent-checkpoint.out').read_text(); log(text+f'exit={rc}'); assert rc==0 and 'check: rearm-resurface' in text
log('durable queue='+(h/'state/.wake-queue').read_text())
log('SCENARIO real status completion reaches the waiting primary')
h,e=home('live-signal')
run(['bin/fm-home-summary-refresh.sh'],e)
out=(ev/'status-checkpoint.out').open('w'); err=(ev/'status-checkpoint.err').open('w')
p=subprocess.Popen(['bin/fm-watch-checkpoint.sh','--seconds','20'],env=e,stdout=out,stderr=err)
ready(h,p); (h/'state/demo.status').write_text('done: lab deliverable ready\n')
rc=p.wait(timeout=35); out.close();err.close()
text=(ev/'status-checkpoint.out').read_text();log(text+f'exit={rc}');assert rc==0 and 'signal:' in text
log('durable queue='+(h/'state/.wake-queue').read_text())
log('ALL MANUAL PRODUCT ASSERTIONS PASSED')
log('SCENARIO dead holder with empty queue recovers silently')
h,e=home('live-dead-holder')
out=(ev/'dead-first-arm.out').open('w'); err=(ev/'dead-first-arm.err').open('w')
p=subprocess.Popen(['bin/fm-watch-arm.sh'],env=e,stdout=out,stderr=err)
ready(h,p); old=int((h/'state/.watch.lock/pid').read_text());os.kill(old,signal.SIGKILL)
try: p.wait(timeout=15)
except subprocess.TimeoutExpired:
    p.terminate();p.wait(timeout=15)
out.close();err.close()
log('killed watcher='+str(old)+'\n'+(ev/'dead-first-arm.out').read_text())
p=checkpoint(e)
assert p.returncode==0 and 'checkpoint: no actionable wake' in p.stdout and 'rearm-resurface' not in p.stdout
log('dead lock recovered; empty queue stayed quiet')
