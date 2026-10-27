import os, pathlib, subprocess, json, time, shutil, signal, shlex
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5Z4KMK1FX0G4B29YQRJKJQG')
# The short evidence path keeps the private macOS Unix socket below its limit.
LAB=E/'l'
LOG=E/'live-quiet.log'
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

try:
    assert not LAB.exists()
    call([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    (LAB/'config/supervision-host-off').touch()
    (LAB/'config/wedge-alarm').write_text('command:printf \"%s\\n\" \"$1\" >> \"$FM_HOME/alarms\"\n')
    tenv=dict(base,TMUX_TMPDIR=str(LAB/'tmux'))
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),'claude')
    S=LAB/'state'
    env=dict(tenv,FM_HOME=str(LAB),FM_SUPERVISOR_BACKEND='tmux',FM_SUPERVISOR_TARGET='primary:0',FM_ESCALATE_BATCH_SECS='0',FM_HOUSEKEEPING_TICK='1',FM_MAX_DEFER_SECS='8',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='3600',FM_HEARTBEAT_SCAN_SECS='3600')
    # Let all unqualified product tmux calls inherit this exact private socket.
    socket=str(LAB/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab')
    env['TMUX']=socket+',0,0'
    time.sleep(3)
    tm('capture-pane','-p','-t','primary')
    # A command channel is the product's supported non-composer notifier.
    alarm=ROOT/'.test-tmp/alarm-recorder.sh'
    alarm.write_text('#!/bin/sh\nprintf "%s|%s\\n" "$1" "$2" >> "$FM_HOME/alarms"\n')
    alarm.chmod(0o755)
    env.update(FM_WEDGE_ALARM_EXEC=str(alarm),FM_WEDGE_ALARM_CHANNEL='command:evidence')
    enter()
    (S/'.subsuper-escalations').write_text('prelaunch-retained-detail\n')
    (S/'.subsuper-escalations.since').write_text(str(int(time.time())-20000)+'\n')
    run('fm-afk-launch.sh','start')
    waitfor(lambda:(S/'.supervise-daemon.pid').exists())
    waitfor(lambda:(S/'.last-watcher-beat').exists())
    time.sleep(2)
    # This is real watcher input, not a watcher replacement.
    (S/'live-task.status').write_text('blocked [key=quiet-live]: private-live-status-nonce-20261027\n')
    waitfor(lambda: 'private-live-status-nonce-20261027' in (S/'.subsuper-escalations').read_text(),75)
    waitfor(lambda:(LAB/'alarms').exists(),90)
    waitfor(lambda:'detail retained in durable state' in (S/'.supervise-daemon.log').read_text(),100)
    time.sleep(2)
    pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    assert 'private-live-status-nonce' not in pane and 'FIRSTMATE_OP' not in pane
    log=(S/'.supervise-daemon.log').read_text()
    assert 'private-live-status-nonce' not in log
    assert 'daemon starting' in log and 'detail retained in durable state' in log
    assert not (S/'.subsuper-inject-wedged').exists()
    assert 'private-live-status-nonce' not in (LAB/'alarms').read_text()
    assert 'prelaunch-retained-detail' in (S/'.subsuper-escalations').read_text()
    note('LIVE RESULT: real status watcher retained private nonce, diagnostics redacted it, non-composer alarm fired, primary received no escalation.')
    record_state('live-daemon')
    shutil.copyfile(LAB/'alarms',E/'live-alarms.log')
    # Crash only the lab daemon. Launcher must close its exact dead terminal,
    # retain prior detail, and pass PREPARED through its production env scrub.
    pid=int((S/'.supervise-daemon.pid').read_text())
    os.kill(pid,signal.SIGTERM)
    waitfor(lambda:not (S/'.supervise-daemon.pid').exists())
    run('fm-afk-launch.sh','start')
    waitfor(lambda:(S/'.supervise-daemon.pid').exists())
    time.sleep(3)
    assert 'private-live-status-nonce' in (S/'.subsuper-escalations').read_text()
    note('LIVE RESULT: terminal launcher restart preserved full retained status detail.')
    pid=int((S/'.supervise-daemon.pid').read_text()); os.kill(pid,signal.SIGTERM)
    waitfor(lambda:not (S/'.supervise-daemon.pid').exists())
    run('fm-afk-launch.sh','start-native')
    assert 'private-live-status-nonce' in (S/'.subsuper-escalations').read_text()
    # Native path's foreground entry uses its prepared state exactly as documented.
    nenv=dict(env,FM_AFK_STATE_PREPARED='1')
    nativeout=(E/'native-daemon.log').open('w')
    native=subprocess.Popen([str(ROOT/'bin/fm-afk-start.sh')],cwd=ROOT,env=nenv,stdout=nativeout,stderr=subprocess.STDOUT)
    waitfor(lambda:(S/'.supervise-daemon.pid').exists())
    time.sleep(3)
    assert 'private-live-status-nonce' in (S/'.subsuper-escalations').read_text()
    run('fm-afk-return.sh','guard')
    expected=(S/'.subsuper-escalations').read_bytes()
    out=exitquiet().stdout
    native.wait(timeout=20); nativeout.close()
    receipt=json.loads((S/'.quiet-exit-receipt').read_text())
    assert pathlib.Path(receipt['archive']).read_bytes()==expected
    assert receipt['count']==len(expected.splitlines())
    assert out.strip()=='Quiet exit detail: archive='+receipt['archive']+' events='+str(receipt['count'])
    assert not (S/'.subsuper-escalations').exists() and not (S/'.afk-return-catchup').exists()
    assert exitquiet().stdout==out
    note('LIVE RESULT: native restart retained detail; quiet exit stopped real daemon, archived exact bytes, and printed only receipt; repeat was idempotent.')
    record_state('live-exit')
    # Archive, receipt, and presentation interruption proofs use real filesystem
    # failures and closed stdout. Every lifecycle call remains unmodified.
    for kind in ['archive','receipt','presentation-retained','presentation-empty']:
        enter(); run('fm-afk-launch.sh','start-native')
        (S/'.subsuper-escalations').write_text('interruption-secret-'+kind+'\n')
        before=(S/'.subsuper-escalations').read_bytes()
        if kind=='archive':
            dig=S/'.subsuper-digests'; saved=S/'.saved-digests'; dig.rename(saved); dig.touch()
            r=exitquiet(ok=None); assert r.returncode!=0
            assert (S/'.subsuper-escalations').read_bytes()==before
            dig.unlink(); saved.rename(dig)
        elif kind=='receipt':
            receiptpath=S/'.quiet-exit-receipt'; receiptpath.unlink(); receiptpath.mkdir()
            r=exitquiet(ok=None); assert r.returncode!=0
            assert (S/'.subsuper-escalations').read_bytes()==before
            receiptpath.rmdir()
        else:
            # Close fd 1 before exec, producing a genuine presentation error.
            r=call(['bash','-c','exec 1>&-; exec "$1" begin','_',ROOT/'bin/fm-afk-return.sh'],env=env,ok=None)
            assert r.returncode!=0 and (S/'.quiet-exit-pending').exists()
            assert not (S/'.subsuper-escalations').exists()
        pending=(S/'.quiet-exit-pending').read_text()
        for mode in ['quiet','away']:
            for script,command in [('fm-afk-contract.sh','enter'),('fm-afk-launch.sh','enter'),('fm-afk-launch.sh','start'),('fm-afk-launch.sh','start-native')]:
                r=call([ROOT/'bin'/script,command],env=dict(env,FM_AFK_MODE=mode),ok=None)
                assert r.returncode!=0 and (S/'.quiet-exit-pending').read_text()==pending
        out=exitquiet('check').stdout
        first=json.loads((S/'.quiet-exit-receipt').read_text())
        assert pathlib.Path(first['archive']).read_bytes()==before
        assert not (S/'.quiet-exit-pending').exists()
        if kind.startswith('presentation'):
            enter();run('fm-afk-launch.sh','start-native')
            second=b'' if kind.endswith('empty') else b'new-session-detail\nnew-session-extra\n'
            if second:(S/'.subsuper-escalations').write_bytes(second)
            out=exitquiet().stdout
            fresh=json.loads((S/'.quiet-exit-receipt').read_text())
            assert first['id']!=fresh['id'] and first['archive']!=fresh['archive']
            assert pathlib.Path(fresh['archive']).read_bytes()==second
            assert fresh['count']==len(second.splitlines())
            assert pathlib.Path(first['archive']).read_bytes()==before
        note('LIVE RESULT: '+kind+' failure retained authoritative detail; unfinished exit refused quiet/away re-entry through every launcher; retry recovered correctly.')
        record_state('live-'+kind)
    note('CORE LIVE SCENARIOS PASSED')
except Exception as ex:
    note('LIVE FAILURE: '+repr(ex))
    if 'S' in globals():record_state('failure-state')
    raise
finally:
    if 'env' in globals():
        try:run('fm-afk-launch.sh','stop',ok=None)
        except Exception as ex:note('stop cleanup: '+repr(ex))
    if 'tenv' in globals():
        try:tm('kill-server',ok=None)
        except Exception as ex:note('tmux cleanup: '+repr(ex))
    if LAB.exists():shutil.rmtree(LAB)
    note('CLEANUP: disposable home removed; only published evidence remains.')
    f.close()
