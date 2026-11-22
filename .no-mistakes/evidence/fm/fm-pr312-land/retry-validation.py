import os, json, pathlib, subprocess, time, signal, shutil, traceback
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('~/.no-mistakes/evidence/01M80MFJN8J4DY8PDFAPA9FFHY')
BASE=ROOT/'.gate-testing/retry-live'
BASE.mkdir(parents=True, exist_ok=True)
log=open(EV/'retry-transcript.log','w', buffering=1)
processes=[]
def say(s):
    print(s, flush=True); print(s,file=log,flush=True)
def env_for(home, **extra):
    e=os.environ.copy()
    for k in list(e):
        if k.startswith(('FM_','TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_PANE_ID','REX_SESSION','REX_BLOCK','ORCA_TERMINAL_HANDLE','CLAUDE_CONFIG_DIR'):
            e.pop(k,None)
    e.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(home), FM_HOME=str(home), TMPDIR=str(BASE), CLAUDE_CONFIG_DIR=str(home/'claude'))
    e.update({k:str(v) for k,v in extra.items()})
    return e
def run(args, env, check=True):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
    if p.returncode and check:
        raise RuntimeError(f'{args}: rc={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p
def home(name):
    p=BASE/name
    run(['bin/fm-lab-home.sh','create',str(p)],env_for(p))
    (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (p/'config/watchdog').write_text('mode=dry-run\nmodels=\nquota-guard=off\nmemory-guard=off\n')
    return p
def read(p):
    try: return json.loads(p.read_text())
    except (FileNotFoundError,json.JSONDecodeError): return None
def wait(pred, secs=30):
    end=time.monotonic()+secs
    while time.monotonic()<end:
        v=pred()
        if v: return v
        time.sleep(.1)
    raise AssertionError('timed out waiting for published state')
def start(home, interval, jitter=0, **extra):
    e=env_for(home,FM_POLL=.2,FM_SIGNAL_GRACE=0,FM_CHECK_INTERVAL=999999,FM_HEARTBEAT=999999,
              FM_HEARTBEAT_LEDGER_IDLE_SECS=interval,FM_HEARTBEAT_LEDGER_JITTER=jitter,
              FM_HOME_SUMMARY_INTERVAL=interval,FM_HOME_SUMMARY_JITTER=0,
              FM_WATCH_MANAGED_HOLD=1,**extra)
    out=open(EV/f'{home.name}-watcher.log','w')
    p=subprocess.Popen(['bin/fm-watch.sh'],cwd=ROOT,env=e,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    processes.append((p,out))
    return p,e
def stop(p):
    # Managed-hold deliberately survives TERM. Stop this disposable process group.
    # The product starts bounded helpers in their own groups. Capture its full
    # descendant tree before stopping it; do not leave those helpers detached.
    rows=subprocess.check_output(['ps','-axo','pid=,ppid='],text=True)
    pairs=[tuple(map(int,r.split())) for r in rows.splitlines() if len(r.split())==2]
    owned={p.pid}
    while True:
        added={pid for pid,ppid in pairs if ppid in owned}-owned
        if not added: break
        owned |= added
    for pid in sorted(owned-{p.pid},reverse=True):
        try: os.kill(pid,signal.SIGKILL)
        except ProcessLookupError: pass
    try: os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError: pass
    p.wait(timeout=15)
    say(f'stopped disposable watcher group {p.pid}; rc={p.returncode}')
def observe(home,e,seconds):
    end=time.monotonic()+seconds; hbs=[]; sums=[]; beats=[]
    while time.monotonic()<end:
        for file, seq, key in [('heartbeat.json',hbs,'published_epoch'),('home-summary.json',sums,'generated_epoch')]:
            d=read(home/'state'/file)
            if d and (not seq or seq[-1][key]!=d[key]):
                seq.append(d); say(f'{home.name} {file}: generated={d.get("generated_epoch")} published={d.get("published_epoch")} stale_after={d.get("stale_after_secs")}')
        try:
            mt=(home/'state/.last-watcher-beat').stat().st_mtime_ns
            if not beats or beats[-1]!=mt: beats.append(mt)
        except FileNotFoundError: pass
        time.sleep(.1)
    assert len(beats)>=3, ('watcher beat stopped',len(beats))
    return hbs,sums,beats
try:
    h=home('failed-summary')
    p,e=start(h,10,FM_HOME_SUMMARY_TIMEOUT=1)
    wait(lambda:(h/'state/.last-watcher-beat').exists())
    end=time.monotonic()+34
    beats=[]
    while time.monotonic()<end:
        try:
            mt=(h/'state/.last-watcher-beat').stat().st_mtime_ns
            if not beats or beats[-1]!=mt: beats.append(mt)
        except FileNotFoundError: pass
        time.sleep(.2)
    err=h/'state/.home-summary-refresh.log'
    text=err.read_text() if err.exists() else ''
    failures=[line for line in text.splitlines() if 'refresh exceeded its 1-second deadline' in line]
    say(text)
    assert not (h/'state/home-summary.json').exists(), 'the forced-timeout producer unexpectedly published'
    assert 2<=len(failures)<=5, (len(failures),text)
    assert len(beats)>len(failures), (len(beats),len(failures))
    say(f'PASS missing summary under repeated real 1s deadline failures: {len(failures)} failure reports and {len(beats)} cheap beats over 34s with 10s retry interval')
    (EV/'failed-summary-refresh.log').write_text(text)
finally:
    for p,out in processes:
        if p.poll() is None: stop(p)
        out.close()
    time.sleep(1)
    shutil.rmtree(BASE)
    log.close()
