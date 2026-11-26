import os, pathlib, subprocess, time, json, signal, shutil, traceback
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M88XCWJR8SC1QYSSYVX3R5SE')
S=ROOT/'.test-live-watcher-startup'
S.mkdir(exist_ok=False)
results=[]
base=os.environ.copy()
for k in list(base):
    if k.startswith('FM_') or k in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_PANE_ID','CODEX_SESSION_ID','CODEX_THREAD_ID','CLAUDE_PID','CLAUDE_SESSION_ID','CLAUDECODE','GROK_AGENT','PI_CODING_AGENT'):
        base.pop(k,None)
toolbin=S/'tools';toolbin.mkdir()
for name in ('tmux','gtimeout','timeout','jq'):
    p=shutil.which(name)
    if p: (toolbin/name).symlink_to(p)
base.update(PATH=str(toolbin)+':/usr/bin:/bin:/usr/sbin:/sbin',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',NM_HOME=str(S/'nm'),XDG_CONFIG_HOME=str(S/'xdg'))
(S/'nm').mkdir();(S/'xdg').mkdir()

def run(args,env=base,timeout=150):
    return subprocess.run([str(x) for x in args],env=env,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
def marked(name):
    h=S/name
    p=run(['bash','bin/fm-lab-home.sh','create',h]); assert p.returncode==0,p.stdout
    (h/'config'/'backlog-backend').write_text('manual\n')
    (h/'config'/'auto-away').write_text('enabled=off\n')
    return h
def check(ok,msg):
    if not ok: raise AssertionError(msg)
def record(name,fn):
    try:
        fn();results.append({'name':name,'result':'pass','live':True})
    except Exception as e:
        results.append({'name':name,'result':'fail','live':True,'error':str(e)})
        (E/(name+'-error.txt')).write_text(traceback.format_exc())
    (E/'live-results.json').write_text(json.dumps(results,indent=2))

h=marked('secondmate');parent=marked('parent')
(h/'.fm-secondmate-home').write_text('lab-mate\n')
(h/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
inbox=parent/'state/lab-mate.inbox';inbox.mkdir()
(h/'config/supervision-host-off').touch()
env=base|{'FM_HOME':str(h),'FM_TASK_INBOX':str(inbox)}
log=[]
def probe(label,mode,extra,rc,contains=''):
    p=run(['bash','bin/fm-watch.sh',mode],env|extra,30)
    log.append(f'$ fm-watch.sh {mode} [{label}]\nexit={p.returncode}\n{p.stdout}')
    check(p.returncode==rc,f'{label}: exit {p.returncode}: {p.stdout}')
    check(contains in p.stdout,f'{label}: missing {contains}: {p.stdout}')
    return p

def refusal():
    probe('no current endpoint','--secondmate-selected',{},1,'native endpoint registration')
    probe('starter without endpoint','--secondmate',{},1,'native endpoint registration')
    candidate={'TMUX':'/nonexistent-lab-socket,1,0','TMUX_PANE':'%1'}
    probe('foreign inbox','--secondmate-selected',candidate|{'FM_TASK_INBOX':'foreign.inbox'},1,'steering inbox')
    saved=(h/'.fm-secondmate-parent').read_text();(h/'.fm-secondmate-parent').unlink()
    probe('missing parent','--secondmate-selected',candidate,1,'parent')
    (h/'.fm-secondmate-parent').write_text(saved)
    (h/'state/.afk').touch()
    probe('away owner','--secondmate-selected',candidate,1,'away')
    (h/'state/.afk').unlink()
    (h/'.fm-secondmate-home').unlink()
    probe('unmarked home','--secondmate-selected',candidate,1,'secondmate home')
    (h/'.fm-secondmate-home').write_text('lab-mate\n')
    check(not (h/'state/.watch.lock').exists(),'refusal armed a watcher')
    check(not (h/'state/.last-watcher-beat').exists(),'refusal manufactured a beat')
    log.append('No watcher lock or heartbeat was created.\n')
    (E/'refusal-cli.log').write_text('\n'.join(log))
record('actionable-refusals',refusal)

def eligibility():
    candidate={'TMUX':'/nonexistent-lab-socket,1,0','TMUX_PANE':'%1'}
    probe('synthetic endpoint candidate is eligible','--secondmate-selected',candidate,0)
    probe('candidate has no verified binding','--secondmate-status',candidate,1,'not ready')
    check(not (h/'state/.watch.lock').exists(),'selection armed a watcher')
    log.append('Synthetic route eligibility is not native endpoint proof; readiness remained refused.\n')
    (E/'refusal-cli.log').write_text('\n'.join(log))
record('eligibility-is-not-readiness',eligibility)

# Real tmux endpoints in a lab-owned server. No vendor or backend is replaced.
lab=marked('startup')
code=S/'synthetic-code-root';code.mkdir()
p=run(['git','init','-q','-b','main',code]);check(p.returncode==0,p.stdout)
p=run(['git','-C',code,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','lab']);check(p.returncode==0,p.stdout)
server_pid=None
socket=None

def tmux(*args):return run(['bash','bin/fm-lab-home.sh','tmux',lab,*args],timeout=15)
try:
    p=tmux('new-session','-d','-s','primary','-x','120','-y','32','-c',ROOT,'/bin/sh')
    check(p.returncode==0,p.stdout)
    p=tmux('display-message','-p','#{pid}|#{socket_path}|#{pane_id}')
    check(p.returncode==0,p.stdout)
    raw=p.stdout.strip().split('|');server_pid=int(raw[0]);socket=raw[1];pane=raw[2]
    (E/'native-tmux.txt').write_text('Private lab tmux server: '+p.stdout+'Nonzero terminal grid: 120x32\n')
    startenv=base|{'FM_HOME':str(lab),'FM_ROOT_OVERRIDE':str(code),'TMUX':socket+','+str(server_pid)+',0','TMUX_PANE':pane,'FM_HOME_SUMMARY_TIMEOUT':'3','FM_STARTUP_NETWORK_TIMEOUT':'15'}
    (lab/'data/captain.md').write_text('LAB_CONTEXT_SENTINEL: recovery context must remain visible.\n')
    queue=lab/'state/.wake-queue'
    original='123\t1\tcheck\tlab\tpreserve this unhandled lab event\n'
    queue.write_text(original)
    def digest(name,extra):
        t=time.monotonic()
        p=run(['bash','bin/fm-session-start.sh'],startenv|extra,150)
        elapsed=time.monotonic()-t
        (E/(name+'.log')).write_text(p.stdout+f'\nPRODUCT_EXIT={p.returncode}\nWALL_SECONDS={elapsed:.3f}\n')
        check(p.returncode==0,p.stdout[-2000:])
        check('STARTUP TRUNCATED - SESSION START' not in p.stdout,'startup truncated; see '+name+'.log')
        check('NEXT STEP' in p.stdout,'recovery continuation missing')
        check('LAB_CONTEXT_SENTINEL' in p.stdout,'recovery context missing')
        return p
    def bounded():
        for i in range(32):
            (lab/f'state/probe-{i:02}.meta').write_text(f'window=primary:{pane}\nkind=ship\nbackend=tmux\n')
        before={p.name:p.read_bytes() for p in (lab/'state').glob('probe-*.meta')}
        os.kill(server_pid,signal.SIGSTOP)
        try:p=digest('slow-native-endpoints',{'FM_SESSION_START_TIMEOUT':'90','FM_SESSION_START_ENDPOINT_TIMEOUT':'10'})
        finally:os.kill(server_pid,signal.SIGCONT)
        check('READ-ONLY SESSION' not in p.stdout,'locked startup not established')
        check('FLEET OBSERVATION DEFERRED:' in p.stdout,'slow native endpoint observations not deferred')
        check('endpoint observations are unverified' in p.stdout,'unverified endpoint state not disclosed')
        check('SESSION_START_COMPLETION: not recorded' in p.stdout,'completion suppression not disclosed')
        check(not (lab/'state/.session-start-complete').exists(),'partial digest wrote full completion')
        check(not (lab/'state/.session-start-agents-baseline').exists(),'partial digest wrote AGENTS baseline')
        check(original in queue.read_text(),'unhandled event lost')
        check(before=={p.name:p.read_bytes() for p in (lab/'state').glob('probe-*.meta')},'task records modified')
        (E/'preserved-state.txt').write_text('All 32 metadata records are byte-identical.\nOriginal unhandled queue row remains:\n'+original+'Full-startup completion and AGENTS baseline receipts are absent.\n')
    record('bounded-slow-startup',bounded)
    # Complete the deferred worker before deleting or reusing the home.
    p=run(['bash','bin/fm-startup-network.sh','wait','60'],startenv,75)
    (E/'startup-network-wait.log').write_text(p.stdout+f'\nexit={p.returncode}\n')
    for p in (lab/'state').glob('probe-*.meta'):p.unlink()
    def edge():
        p=digest('decimal-empty-fleet',{'FM_SESSION_START_TIMEOUT':'090','FM_SESSION_START_ENDPOINT_TIMEOUT':'120'})
        check('FLEET OBSERVATION DEFERRED:' not in p.stdout,'empty fleet deferred without probe work')
        check((lab/'state/.session-start-complete').exists(),'complete startup lacks completion receipt')
        (lab/'state/probe-edge.meta').write_text(f'window=primary:{pane}\nkind=ship\nbackend=tmux\n')
        os.kill(server_pid,signal.SIGSTOP)
        try:p=digest('unfitting-native-probe',{'FM_SESSION_START_TIMEOUT':'090','FM_SESSION_START_ENDPOINT_TIMEOUT':'120'})
        finally:os.kill(server_pid,signal.SIGCONT)
        check('FLEET OBSERVATION DEFERRED:' in p.stdout,'unfitting endpoint window was queried or undisclosed')
        check('remaining budget cannot safely verify' in p.stdout,'unfitting endpoint was not deferred before query')
        check(not (lab/'state/.session-start-complete').exists(),'deferred startup retained completion receipt')
    record('valid-budget-edge-cases',edge)
    p=run(['bash','bin/fm-startup-network.sh','wait','60'],startenv,75)
    (E/'startup-network-wait.log').write_text((E/'startup-network-wait.log').read_text()+p.stdout+f'\nexit={p.returncode}\n')
finally:
    if server_pid:
        try:os.kill(server_pid,signal.SIGCONT)
        except ProcessLookupError:pass
        p=tmux('kill-server')
        (E/'native-tmux.txt').write_text((E/'native-tmux.txt').read_text()+f'kill-server exit={p.returncode}\n')
        p=run(['bash','bin/fm-lab-home.sh','teardown',lab])
        (E/'native-tmux.txt').write_text((E/'native-tmux.txt').read_text()+f'teardown exit={p.returncode}\n'+p.stdout)
    # Detected detached lab children are not allowed to survive the evidence turn.
    table=run(['ps','-axo','pid=,ppid=,command=']).stdout
    owned=[]
    for row in table.splitlines():
        cells=row.strip().split(None,2)
        if len(cells)==3 and str(S) in cells[2] and int(cells[0])!=os.getpid():
            owned.append((int(cells[0]),cells[2]))
    (E/'lab-cleanup.log').write_text(json.dumps(owned,indent=2))
    for pid,cmd in owned:
        try:os.kill(pid,signal.SIGTERM)
        except ProcessLookupError:pass
    time.sleep(1)
    for pid,cmd in owned:
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
    shutil.rmtree(S)
print(json.dumps(results,indent=2))
