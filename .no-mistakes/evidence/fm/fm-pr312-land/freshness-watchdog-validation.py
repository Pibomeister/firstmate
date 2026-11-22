import os, json, pathlib, subprocess, time, signal, shutil, traceback
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('~/.no-mistakes/evidence/01M80MFJN8J4DY8PDFAPA9FFHY')
BASE=ROOT/'.gate-testing/live'
BASE.mkdir(parents=True, exist_ok=True)
log=open(EV/'freshness-watchdog-transcript.log','w', buffering=1)
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
    # S4: real publisher with 900s cycle and absent optional grace; drive real ledger CLI using clock seam.
    h=home('freshness'); e=env_for(h,FM_HEARTBEAT_CYCLE_SECS=900)
    run(['bin/fm-heartbeat.sh','--write'],e)
    hb=read(h/'state/heartbeat.json'); assert hb['stale_after_secs']==1371,hb
    (EV/'long-cadence-heartbeat.json').write_text(json.dumps(hb,indent=2))
    base=hb['published_epoch']; samples=[]
    for age in [601,900,1371]:
        e=env_for(h,FM_TEST_SEAM=1,FM_NOW=base+age,FM_STALL_LEDGER_MIN_SECS=0)
        run(['bin/fm-stall-ledger.sh','observe'],e)
        rows=(h/'state/stall-ledger.tsv').read_text()
        opened=[r for r in rows.splitlines() if '\tstall-open\t' in r]
        assert len(opened)==(1 if age==1372 else 0),(age,rows)
        say(f'long-cadence age={age}: stall-open rows={len(opened)}')
    e=env_for(h)
    scored=run(['bin/fm-stall-ledger.sh','score','--since',str(base+601),'--until',str(base+1372)],e)
    assert scored.stdout.strip()=='PASS',scored.stdout
    run(['bin/fm-stall-ledger.sh','observe'],env_for(h,FM_TEST_SEAM=1,FM_NOW=base+1372,FM_STALL_LEDGER_MIN_SECS=0))
    failed=run(['bin/fm-stall-ledger.sh','score','--since',str(base+1372),'--until',str(base+1373)],e,False)
    assert failed.returncode==1 and 'heartbeat-age' in failed.stdout,failed.stdout
    say('healthy score: '+scored.stdout.strip()); say('expired score:\n'+failed.stdout)
    # A synthetic next publication is input to the real observer at its monotonic test clock.
    fresh=hb.copy()
    future=base+1380
    fresh['published_epoch']=future; fresh['generated_epoch']=future
    (h/'state/heartbeat.json').write_text(json.dumps(fresh))
    run(['bin/fm-stall-ledger.sh','observe'],env_for(h,FM_TEST_SEAM=1,FM_NOW=future,FM_STALL_LEDGER_MIN_SECS=0))
    rows=(h/'state/stall-ledger.tsv').read_text(); assert '\tstall-close\t' in rows,rows
    (EV/'stall-ledger.tsv').write_text(rows)
    say('PASS cadence-safe bound, exact expiration, scoring, and recovery through real CLI with synthetic clock inputs')
    # S5: real watchdog dry-run, live process lock, synthetic heartbeat ages; no model or harness substitute.
    h=home('watchdog'); e=env_for(h)
    (h/'state/.lock').write_text(str(os.getpid())+'\n')
    (h/'state/.lock-session').write_text('00000000-0000-4000-8000-000000000001\n')
    now=int(time.time())
    for age in [837,899,900]:
        (h/'state/heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','generated_epoch':now-age,'published_epoch':now-age}))
        ee=env_for(h,FM_TEST_SEAM=1,FM_WD_NOW=now)
        run(['bin/fm-watchdog.sh','once','--dry-run','--home',str(h)],ee)
        ledger=h/'state/watchdog/actions.tsv'
        rows=ledger.read_text() if ledger.exists() else ''
        detects=[r for r in rows.splitlines() if '\theartbeat-frozen\tdetect\t' in r]
        assert len(detects)==(1 if age==900 else 0),(age,rows)
        scan=run(['bin/fm-watchdog.sh','scan','--home',str(h)],ee)
        say(f'watchdog age={age}: detects={len(detects)}\n{scan.stdout}')
    (EV/'watchdog-actions.tsv').write_text(rows)
    say('PASS watchdog default freeze: no detection at 837/899s; detection at 900s; dry-run only')
    say('ALL LIVE SCENARIOS PASSED')
except Exception:
    traceback.print_exc(file=log); traceback.print_exc(); raise
finally:
    for p,out in processes:
        if p.poll() is None: stop(p)
        out.close()
    shutil.rmtree(BASE)
    log.close()
