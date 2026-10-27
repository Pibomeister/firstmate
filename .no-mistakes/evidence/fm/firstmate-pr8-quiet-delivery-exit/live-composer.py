import os, pathlib, subprocess, json, time, shutil, signal, shlex
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5Z4KMK1FX0G4B29YQRJKJQG')
# The short evidence path keeps the private macOS Unix socket below its limit.
LAB=E/'c'
LOG=E/'live-composer.log'
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
    call([ROOT/'bin/fm-lab-home.sh','create',LAB]);(LAB/'tmux').mkdir()
    (LAB/'config/supervision-host-off').touch()
    (LAB/'config/wedge-alarm').write_text('command:printf "%s\\n" "$1" >> "$FM_HOME/alarms"\n')
    tenv=dict(base,TMUX_TMPDIR=str(LAB/'tmux'))
    # Process-local trust applies to this known test source; it changes no config.
    tm('new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e','FM_HOME='+str(LAB),'codex','-c','projects.'+json.dumps(str(ROOT))+'.trust_level="trusted"')
    S=LAB/'state';socket=str(LAB/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab')
    env=dict(tenv,FM_HOME=str(LAB),TMUX=socket+',0,0',FM_SUPERVISOR_BACKEND='tmux',FM_SUPERVISOR_TARGET='primary:0',FM_ESCALATE_BATCH_SECS='0',FM_HOUSEKEEPING_TICK='1',FM_MAX_DEFER_SECS='5',FM_POLL='1',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='3600',FM_HEARTBEAT_SCAN_SECS='3600')
    time.sleep(15)
    pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    if 'Continue without trusting' in pane:
        tm('send-keys','-t','primary','3','Enter')
        time.sleep(10)
        pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    (E/'codex-initial-screen.txt').write_text(pane)
    assert ('Codex' in pane or 'codex' in pane),pane
    assert 'trust this' not in pane.lower() and 'sign in' not in pane.lower(),pane
    tm('send-keys','-t','primary','-l','human-draft-quiet-20261027')
    time.sleep(2)
    pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    assert 'human-draft-quiet-20261027' in pane
    (E/'codex-draft-before.txt').write_text(pane)
    enter();run('fm-afk-launch.sh','start-native')
    output=(E/'composer-daemon.log').open('w')
    proc=subprocess.Popen([str(ROOT/'bin/fm-afk-start.sh')],env=dict(env,FM_AFK_STATE_PREPARED='1'),cwd=ROOT,stdout=output,stderr=subprocess.STDOUT)
    waitfor(lambda:(S/'.last-watcher-beat').exists())
    (S/'composer-live.status').write_text('blocked [key=quiet-composer]: composer-secret-live-20261027\n')
    waitfor(lambda:(S/'.subsuper-escalations').exists() and 'composer-secret-live-20261027' in (S/'.subsuper-escalations').read_text(),75)
    waitfor(lambda:'detail retained in durable state' in (S/'.supervise-daemon.log').read_text(),75)
    waitfor(lambda:(LAB/'alarms').exists(),30)
    pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    assert 'human-draft-quiet-20261027' in pane and 'composer-secret-live-20261027' not in pane and 'FIRSTMATE_OP' not in pane
    (E/'codex-draft-after.txt').write_text(pane)
    assert 'composer-secret-live-20261027' not in (S/'.supervise-daemon.log').read_text()
    assert 'composer-secret-live-20261027' not in (LAB/'alarms').read_text()
    record_state('live-codex-composer')
    note('LIVE RESULT: a real ready Codex composer retained an unsubmitted human draft; a classified private status wake reached only durable Firstmate state and summary-only alerts, with no composer escalation.')
    run('fm-afk-return.sh','begin')
    proc.wait(timeout=20);proc=None;output.close()
    pane=tm('capture-pane','-p','-S','-100','-t','primary').stdout
    assert 'human-draft-quiet-20261027' in pane and 'composer-secret-live-20261027' not in pane
    note('LIVE RESULT: quiet shutdown also left the real human draft intact; no model request was submitted.')
except Exception as ex:
    note('LIVE FAILURE: '+repr(ex))
    if 'S' in globals():record_state('composer-failure-state')
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
    note('CLEANUP: disposable composer lab removed.');f.close()
