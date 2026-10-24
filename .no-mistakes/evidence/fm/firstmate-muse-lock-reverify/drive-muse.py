import os, pathlib, subprocess, tempfile, time, json, shlex, html, re, shutil
ROOT = pathlib.Path.cwd()
E = pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5QN6B0CPGQ68QX3AK7G69KK')
lab = pathlib.Path(tempfile.mkdtemp(prefix='live-muse-', dir=ROOT / '.test-temp'))
socket = 'fm-muse-check-' + str(os.getpid())
env = os.environ.copy()
for k in ['NO_COLOR','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE']:
    env.pop(k, None)
env.update(FM_HOME=str(lab / 'home'), XDG_CONFIG_HOME=str(lab / 'config'), XDG_DATA_HOME=str(lab / 'data'), MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL='on', TERM='xterm-256color', COLORTERM='truecolor', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
transcript = []
def run(args, check=True, cwd=ROOT, timeout=30):
    p = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if check and p.returncode: raise RuntimeError(str(args) + '\n' + p.stdout)
    return p

def tm(*args, **kwargs): return run([shutil.which('tmux'), '-L', socket, *args], **kwargs)
def shell(body, *args): return run(['bash','-c',body,'_',*map(str,args)]).stdout.strip()
def note(s):
    transcript.append(s); print(s, flush=True)
def expect(actual, wanted, label):
    note(f'{label}: {actual}')
    assert actual == wanted, (label, actual, wanted)
def until(fn, predicate, seconds=20):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=fn()
        if predicate(value): return value
        time.sleep(.15)
    raise RuntimeError('timed out; last value: '+str(value))
def classify(): return shell('. bin/fm-busy-lib.sh; fm_busy_classify tmux "$1" muse live "$2"', 'muse-check:fm-live', lab/'home/state')
def signature(): return shell('. bin/fm-busy-lib.sh; fm_busy_muse_namespace_signature "$1" "$2"', lab/'data/muse/sessions', lab/'workspace')
def capture(label):
    plain=tm('capture-pane','-p','-t','muse-check:fm-live','-S','0','-E','-').stdout
    ansi=tm('capture-pane','-e','-p','-t','muse-check:fm-live','-S','0','-E','-').stdout
    (E / (label+'.ansi')).write_text(ansi)
    (E / (label+'.txt')).write_text(plain)
    return plain
try:
    note(run(['bin/fm-lab-home.sh','create',str(lab/'home')]).stdout.strip())
    for path in ['config','data','workspace','bin']: (lab/path).mkdir()
    run(['git','init','-q',str(lab/'workspace')])
    wrapper=lab/'bin/tmux'
    wrapper.write_text('#!/bin/bash\nexec '+shlex.quote(shutil.which('tmux'))+' -L '+shlex.quote(socket)+' "$@"\n')
    wrapper.chmod(0o755)
    env['PATH']=str(lab/'bin')+':'+env['PATH']
    for model in ['muse-wonder-1.0','muse-spark-1.3']:
        p=run(['muse','model-profile','show',model])
        (E / (model+'-profile.txt')).write_text(p.stdout)
        note(p.stdout.strip())
    root=lab/'data/muse/sessions'
    state=lab/'home/state'
    (state/'live.muse-session').write_text(f'sessions_root={root}\nworkspace_root={lab / "workspace"}\nbinding_id=live-check\n')
    (state/'live.meta').write_text(f'backend=tmux\nwindow=muse-check:fm-live\nendpoint_task_id=live\nworktree={lab / "workspace"}\nproject={lab / "workspace"}\nharness=muse\nkind=scout\nmode=no-mistakes\nyolo=off\n')
    # tmux allocates and drains a 120x40 pty before starting Muse.
    tm('new-session','-d','-s','muse-check','-n','fm-live','-x','120','-y','40','-c',str(lab/'workspace'),
       'env', 'XDG_CONFIG_HOME='+env['XDG_CONFIG_HOME'],'XDG_DATA_HOME='+env['XDG_DATA_HOME'],
       'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on','muse','--provider','echo','--yolo','--echo-delay-ms','7000','live firstmate metadata and cache verification')
    logs=until(lambda:list(root.glob('*/*/*/*/session.jsonl')),bool)
    log=logs[0]
    until(classify,lambda x:x=='busy muse-session-log')
    expect(classify(),'busy muse-session-log','real TUI turn in flight')
    first_sig=signature()
    capture('muse-busy')
    pid=tm('display-message','-p','-t','muse-check:fm-live','#{pane_pid}').stdout.strip()
    note('live process: '+run(['ps','-o','comm=','-p',pid]).stdout.strip())
    expect(shell('bin/fm-harness.sh ancestry "$1"',pid),'comm muse','real binary ancestry')
    (state/'.lock').write_text(pid+'\n')
    held=run(['bin/fm-lock.sh','status']).stdout.strip()
    expect(held,'lock: held by live harness pid '+pid,'lock recognizes real Muse process')
    (state/'.lock').unlink()
    until(classify,lambda x:x=='idle muse-session-log')
    expect(classify(),'idle muse-session-log','real TUI completed turn')
    expect(signature(),first_sig,'run append does not invalidate metadata namespace')
    capture('muse-idle')
    records=[json.loads(x) for x in log.read_text().splitlines() if x]
    note('first record retained_frame='+str(records[0].get('retained_frame')))
    assert records[0].get('retained_frame')
    meta_index=next(i for i,r in enumerate(records) if r.get('payload',{}).get('record',{}).get('workspace_root'))
    note('workspace metadata line='+str(meta_index+1)); assert meta_index>0
    # Submit a second real turn and interrupt through the production control plane.
    tm('send-keys','-t','muse-check:fm-live','-l','a second turn to cancel while busy')
    time.sleep(.5)
    tm('send-keys','-t','muse-check:fm-live','Enter')
    time.sleep(.2)
    capture('muse-submitted')
    until(classify,lambda x:x=='busy muse-session-log')
    active=shell('. bin/fm-busy-lib.sh; fm_busy_muse_active_run_id "$1"', log)
    note('active run resolvable for interrupt='+active); assert active
    control=run(['bin/fm-control.sh','live','interrupt'])
    note(control.stdout.strip())
    assert 'cancel=confirmed' in control.stdout
    until(classify,lambda x:x=='idle muse-session-log')
    expect(classify(),'idle muse-session-log','interrupted turn settled')
    time.sleep(.5)
    capture('muse-interrupted')
    # Current product protocol, preserved as evidence. No operator sessions are read.
    (E/'live-session.jsonl').write_bytes(log.read_bytes())
    life=[r['payload'] for r in map(json.loads,log.read_text().splitlines()) if r.get('payload_type')=='runtime.session' and r.get('payload',{}).get('kind')=='run' and r.get('payload',{}).get('event',{}).get('kind') in ['started','terminal']]
    note('live lifecycle='+json.dumps(life))
    assert len(life)==4 and life[-1]['event'].get('terminal')=='cancelled'
    # Adversarial live fault injection into the second real Muse writer's disposable log.
    # Move current logs across date directories; leave process handles open.
    import datetime, signal
    yesterday=datetime.date.today()-datetime.timedelta(days=1)
    previous=root/yesterday.strftime('%Y/%m/%d')
    previous.mkdir(parents=True,exist_ok=True)
    old_dir=previous/log.parent.name
    shutil.move(str(log.parent),str(old_dir)); log=old_dir/'session.jsonl'
    expect(classify(),'idle muse-session-log','cached session survives prior-date relocation')
    tm('new-window','-d','-t','muse-check:','-n','competing','-c',str(lab/'workspace'),
       'env','XDG_CONFIG_HOME='+env['XDG_CONFIG_HOME'],'XDG_DATA_HOME='+env['XDG_DATA_HOME'],
       'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on','muse','--provider','echo','--yolo','--echo-delay-ms','12000','competing live session')
    second=until(lambda:[p for p in root.glob('*/*/*/*/session.jsonl') if p != log],bool)[0]
    until(lambda:second.read_text(),lambda x:'"kind":"started"' in x)
    second_pid=int(tm('display-message','-p','-t','muse-check:competing','#{pane_pid}').stdout.strip())
    os.kill(second_pid,signal.SIGSTOP)
    try:
        second_dir=previous/second.parent.name
        shutil.move(str(second.parent),str(second_dir)); second=second_dir/'session.jsonl'
        raw=second.read_bytes(); first_line,remaining=raw.split(b'\n',1)
        metadata_line,rest=remaining.split(b'\n',1)
        second.write_bytes(first_line+b'\n')
        expect(classify(),'idle muse-session-log','other prior-date retained prefix has no workspace metadata')
        cached=(state/'live.muse-session-current').read_bytes()
        with second.open('ab') as f: f.write(metadata_line[:-1])
        expect(classify(),'idle muse-session-log','partial prior-date metadata cannot bind')
        assert (state/'live.muse-session-current').read_bytes()==cached
        with second.open('ab') as f: f.write(metadata_line[-1:]+b'\n'+rest)
        expect(classify(),'unknown muse-session-log','ready metadata in prior-date competitor invalidates cached idle')
        assert second.read_bytes().split(b'\n',1)[0]==first_line
        note('competing real session first line unchanged throughout staged metadata append')
    finally:
        os.kill(second_pid,signal.SIGCONT)
    # Keep the live writer open but remove it from the candidate namespace.
    shutil.move(str(second.parent),str(lab/'excluded-competitor'))
    expect(classify(),'idle muse-session-log','removing competitor restores unique binding')
    # Catalog is local; this run has no delegated Meta credential. Confirm the isolated error.
    p=run(['muse','exec','--yolo','--model','muse-wonder-1.0','--no-foreign-personal-context','--max-model-steps','1','Reply with OK.'],check=False,cwd=lab/'workspace',timeout=20)
    note('isolated real-provider attempt exit='+str(p.returncode)+' output='+p.stdout.strip())
    (E/'meta-provider-attempt.txt').write_text(p.stdout)
    # Real running non-harness process must never appear as a lock owner.
    decoy=subprocess.Popen(['/bin/sleep','15'])
    try:
        (state/'.lock').write_text(str(decoy.pid)+'\n')
        p=run(['bin/fm-lock.sh','status'])
        note('non-harness lock status: '+p.stdout.strip())
        assert 'stale' in p.stdout
    finally:
        decoy.terminate(); decoy.wait()
    tm('kill-server')
    note('private tmux server stopped; disposable home removed')
finally:
    tm('kill-server',check=False)
    shutil.rmtree(lab)
    (E/'muse-live-transcript.txt').write_text('\n\n'.join(transcript)+'\n')
    # Render the actual captured terminal cells as portable review evidence.
    panes=[]
    for label in ['muse-busy','muse-idle','muse-interrupted']:
        p=E/(label+'.txt')
        if p.exists(): panes.append('<h2>'+html.escape(label)+'</h2><pre>'+html.escape(p.read_text().rstrip())+'</pre>')
    (E/'muse-live-terminal.html').write_text('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Muse live terminal evidence</title><style>body{background:#FAF9F5;color:#141413;font:17px system-ui;margin:32px}p{max-width:68ch;line-height:1.6}pre{background:#1f1e1d;color:#FAF9F5;padding:24px;overflow:auto;font:12px/1.4 monospace;border-radius:8px}h1,h2{font-family:Georgia,serif}</style><h1>Muse 1.4.13 live terminal</h1><p>TL;DR: Captures from the real Muse echo-provider TUI in an isolated workspace. They show the turn in flight, its completion, and a second turn cancelled through Firstmate. No decision is required.</p>'+''.join(panes))
