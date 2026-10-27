import os, pathlib, subprocess, json, time, shutil, signal, shlex
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5Z4KMK1FX0G4B29YQRJKJQG')
# The short evidence path keeps the private macOS Unix socket below its limit.
LAB=E/'b'
LOG=E/'live-boundaries.log'
base={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k not in ('NO_MISTAKES_GATE','TMUX','TMUX_PANE')}
base['TMPDIR']=str(ROOT/'.test-tmp')
f=LOG.open('w',buffering=1)
def note(s): print(s, file=f, flush=True); print(s,flush=True)
def call(args,env=None,ok=(0,),stdout=None):
    r=subprocess.run([str(x) for x in args],cwd=ROOT,env=env or base,text=True,stdout=stdout or subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
    note('$ '+' '.join(shlex.quote(str(x)) for x in args)+'\nexit='+str(r.returncode)+'\n'+(r.stdout or '')+r.stderr)
    if ok is not None: assert r.returncode in ok, (args,r.returncode,r.stdout,r.stderr)
    return r

def waitfor(pred,timeout=40):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if pred(): return
        time.sleep(.3)
    raise AssertionError('timed out waiting for observable product state')

def tm(*args,**kw): return call(['tmux','-L','fm-lab',*args],env=tenv,**kw)

def run(script,*args,**kw): return call([ROOT/'bin'/script,*args],env=env,**kw)

def record_state(label):
    dest=E/label
    dest.mkdir(exist_ok=True)
    for p in S.iterdir():
        if p.is_file() and p.name in ('.subsuper-escalations','.quiet-exit-receipt','.quiet-exit-pending','.supervise-daemon.log','.supervise-daemon.watcher.err','.afk-contract','.afk-return-catchup','live-task.status'):
            shutil.copyfile(p,dest/p.name)
    if (S/'.subsuper-digests').is_dir(): shutil.copytree(S/'.subsuper-digests',dest/'digests',dirs_exist_ok=True)

def enter():
    run('fm-afk-contract.sh','enter',env_override=True) if False else None
    q=dict(env,FM_AFK_MODE='quiet')
    call([ROOT/'bin/fm-afk-contract.sh','enter'],env=q)
    # The launcher creates the compatibility flag from the validated contract.

def exitquiet(mode='begin',**kw): return run('fm-afk-return.sh',mode,**kw)
proc=None
try:
    assert not LAB.exists()
    call([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir();(LAB/'config/supervision-host-off').touch()
    (LAB/'config/wedge-alarm').write_text('command:printf "%s|%s\\n" "$(date +%s)" "$1" >> "$FM_HOME/alarms"\n')
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (LAB/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    tenv=dict(base,TMUX_TMPDIR=str(LAB/'tmux'))
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),'claude')
    S=LAB/'state'
    socket=str(LAB/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab')
    env=dict(tenv,FM_HOME=str(LAB),TMUX=socket+',0,0',FM_SUPERVISOR_BACKEND='tmux',FM_SUPERVISOR_TARGET='primary:0',FM_ESCALATE_BATCH_SECS='0',FM_HOUSEKEEPING_TICK='1',FM_MAX_DEFER_SECS='5',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='3600',FM_HEARTBEAT_SCAN_SECS='3600')
    enter();quietrecord=(S/'.afk-contract').read_bytes()
    call([ROOT/'bin/fm-afk-contract.sh','enter'],env=dict(env,FM_AFK_MODE='away'));awayrecord=(S/'.afk-contract').read_bytes()
    for posture in ['flag-only','invalid-record','record-only','validated-quiet','contradictory-away','contradictory-quiet','malformed-flag','directory-flag','duplicate-mode']:
        for name in ['.afk','.afk-contract']:
            p=S/name
            if p.is_dir():p.rmdir()
            elif p.exists():p.unlink()
        if posture=='flag-only':(S/'.afk').write_text('quiet\n')
        elif posture=='invalid-record':(S/'.afk-contract').write_text('mode: quiet\n')
        elif posture=='contradictory-quiet':
            (S/'.afk-contract').write_bytes(awayrecord);(S/'.afk').write_text('quiet\n')
        else:
            (S/'.afk-contract').write_bytes(quietrecord)
            if posture=='validated-quiet':(S/'.afk').write_text('quiet\n')
            elif posture=='contradictory-away':(S/'.afk').write_text('away\n')
            elif posture=='malformed-flag':(S/'.afk').write_text('garbage\n')
            elif posture=='directory-flag':(S/'.afk').mkdir()
            elif posture=='duplicate-mode':(S/'.afk-contract').write_bytes(b'mode: quiet\n'+quietrecord)
        secret='preserved-private-nonce-'+posture
        (S/'.subsuper-escalations').write_text(secret+'\n')
        (S/'.subsuper-escalations.since').write_text(str(int(time.time())-100)+'\n')
        oldcount=len((LAB/'alarms').read_text().splitlines()) if (LAB/'alarms').exists() else 0
        (S/'.subsuper-last-housekeep').unlink(missing_ok=True)
        fout=(E/('daemon-'+posture+'.log')).open('w')
        proc=subprocess.Popen([str(ROOT/'bin/fm-supervise-daemon.sh')],cwd=ROOT,env=env,stdout=fout,stderr=subprocess.STDOUT)
        waitfor(lambda:(S/'.supervise-daemon.pid').exists())
        waitfor(lambda:(S/'.subsuper-last-housekeep').exists(),30)
        time.sleep(2)
        assert proc.poll() is None
        guard=run('fm-afk-return.sh','guard',ok=None)
        assert guard.returncode==(0 if posture in ['record-only','validated-quiet'] else 3)
        assert secret in (S/'.subsuper-escalations').read_text()
        assert not (S/'.subsuper-inject-wedged').exists()
        assert secret not in (S/'.supervise-daemon.log').read_text()
        if posture=='validated-quiet':
            # Real time, real notifier, real daemon: timestamps must remain at
            # least one full configured defer window apart.
            waitfor(lambda:len((LAB/'alarms').read_text().splitlines())>=oldcount+3,25)
            times=[int(x.split('|')[0]) for x in (LAB/'alarms').read_text().splitlines()[oldcount:]]
            assert all(b-a>=5 for a,b in zip(times,times[1:])),times
            note('LIVE RESULT: summary-only command notifications throttled across real defer windows: '+repr(times))
        proc.send_signal(signal.SIGTERM);proc.wait(timeout=20);proc=None;fout.close()
        assert secret in (S/'.subsuper-escalations').read_text()
        pane=tm('capture-pane','-p','-S','-80','-t','primary').stdout
        assert secret not in pane and 'FIRSTMATE_OP' not in pane
        note('LIVE RESULT: '+posture+' retained detail and blocked composer; guard '+('accepted validated quiet' if guard.returncode==0 else 'refused invalid/contradictory posture'))
        record_state('boundary-'+posture)
    for name in ['.afk','.afk-contract']:
        p=S/name
        if p.is_dir():p.rmdir()
        elif p.exists():p.unlink()
    (S/'.afk-contract').write_bytes(quietrecord)
    run('fm-afk-launch.sh','start-native')
    exitquiet()
    # Real-away return must outrank the previous quiet receipt and must close
    # after the durable blocker is resolved, through the unmodified return owner.
    call([ROOT/'bin/fm-afk-contract.sh','enter','--words','real-away boundary'],env=dict(env,FM_AFK_MODE='away'))
    run('fm-afk-launch.sh','start-native')
    (S/'repair.meta').write_text('window=primary:0\nbackend=tmux\nkind=ship\n')
    (S/'repair.status').write_text('blocked [key=real-away]: disposable dependency needs repair\n')
    (S/'.last-watcher-beat').touch()
    r=exitquiet(ok=None);assert r.returncode==3 and (S/'.afk-return-catchup').exists()
    note('LIVE RESULT: an old quiet receipt did not bypass the real-away blocker.')
    record_state('away-blocked')
    with (S/'repair.status').open('a') as out:out.write('resolved [key=real-away]: disposable dependency repaired\n')
    r=exitquiet('check',ok=None)
    assert r.returncode==0 and not (S/'.afk-return-catchup').exists(),r.stdout+r.stderr
    assert (S/'.quiet-exit-receipt').exists()
    record_state('away-resolved')
    note('LIVE RESULT: real-away reconciliation closed after durable resolution and preserved the prior quiet receipt.')
    # A flag-only /quiet off remains on legacy catch-up reconciliation.
    (S/'.afk').write_text('quiet\n'+str(int(time.time()))+'\n')
    (S/'repair.status').write_text('blocked [key=legacy]: compatibility must not bypass return\n')
    r=exitquiet(ok=None)
    assert r.returncode==3 and (S/'.afk-return-catchup').exists()
    with (S/'repair.status').open('a') as out:out.write('resolved [key=legacy]: dependency resolved\n')
    r=exitquiet('check',ok=None)
    assert r.returncode==0 and not (S/'.afk-return-catchup').exists()
    note('LIVE RESULT: flag-only legacy quiet used catch-up reconciliation and required blocker resolution.')
    shutil.copyfile(LAB/'alarms',E/'boundary-alarms.log')
    note('ALL BOUNDARY LIVE SCENARIOS PASSED')
except Exception as ex:
    note('LIVE FAILURE: '+repr(ex))
    if 'S' in globals():record_state('boundary-failure-state')
    raise
finally:
    if proc is not None:
        proc.send_signal(signal.SIGTERM)
        try:proc.wait(timeout=20)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
    if 'env' in globals():
        try:run('fm-afk-launch.sh','stop',ok=None)
        except Exception as ex:note('stop cleanup: '+repr(ex))
    if 'tenv' in globals():
        try:tm('kill-server',ok=None)
        except Exception as ex:note('tmux cleanup: '+repr(ex))
    if LAB.exists():shutil.rmtree(LAB)
    note('CLEANUP: disposable boundary lab removed.')
    f.close()
