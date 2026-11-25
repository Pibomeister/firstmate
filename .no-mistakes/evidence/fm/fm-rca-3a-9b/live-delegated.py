import os, subprocess, pathlib, tempfile, shutil, hashlib, time, json, re, shlex
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8')
BASE=pathlib.Path(tempfile.mkdtemp(prefix='.nm-delegated-live-',dir=ROOT))
results=[]
log=None
def say(s):
    
    if log is None or log.closed:
        with (E/'live-cleanup-operations.log').open('a') as f: f.write(s+'\n')
    else:
        log.write(s+'\n'); log.flush()
def call(h,args,expected=0,extra=None):
    env=os.environ.copy()
    for k in list(env):
        if k.startswith('FM_') or k in ('TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID'): env.pop(k,None)
    env['FM_HOME']=str(h)
    if extra: env.update(extra)
    say('$ '+shlex.join(args))
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
    if p.stdout: say(p.stdout.rstrip())
    if p.stderr: say('stderr: '+p.stderr.rstrip())
    say('exit='+str(p.returncode))
    assert p.returncode==expected,(args,p.returncode,expected,p.stdout,p.stderr)
    return p.stdout,p.stderr
def d(h,*args,**kw): return call(h,['bash','bin/fm-delegated.sh',*map(str,args)],**kw)[0]
def home(name):
    h=BASE/name
    call(h,['bash','bin/fm-lab-home.sh','create',str(h)])
    (h/'art').mkdir()
    (h/'art/report.md').write_text('Synthetic overnight investigation outcome.\n')
    return h
def reg(h,task='hermes-lab',supervisor='firstmate',window=2):
    return d(h,'register','--task',task,'--deliverable','report','--artifact',h/'art/report.md','--heartbeat-secs','1','--silence-secs',str(window),'--supervisor',supervisor)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def hand(h,id='answer',receiver='worker',location='alt',path=None):
    path=path or h/'art/report.md'
    return d(h,'handoff','--task','hermes-lab','--id',id,'--receiver',receiver,'--path',path,'--hash',sha(path),'--alt-dir',h/'hosted-answers','--location',location)
def ack_primary(h):
    out,err=call(h,['bash','bin/fm-wake-drain.sh'])
    token=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',err)
    assert token,(out,err)
    call(h,['bash','bin/fm-wake-drain.sh','--ack-through',token[1],'--recovery-generation',token[2]])
    return out
def body(h,p):
    return call(h,['bash','-c','. "$1"; fm_task_inbox_body "$2"','_',str(ROOT/'bin/fm-task-inbox-lib.sh'),str(p)])[0]
def scenario(name,fn):
    global log
    with (E/(name+'.log')).open('w') as log:
        say('revision='+subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
        say('Real product CLI; isolated synthetic home; wall clock; no fake tools or injected clock.')
        try:
            fn()
            say('SCENARIO PASS')
            results.append(dict(name=name,result='pass',live=True,evidence=str(E/(name+'.log')),reason='Real local CLI with a disposable marked home and synthetic artifacts.'))
        except Exception as e:
            say('SCENARIO FAIL '+repr(e))
            results.append(dict(name=name,result='fail',live=True,evidence=str(E/(name+'.log')),reason=repr(e)))
            raise

def progress():
    h=home('progress'); (h/'state/supervisor.meta').touch()
    reg(h,supervisor='supervisor',window=30)
    d(h,'dispatch','--task','hermes-lab')
    assert 'state=dispatched-not-progressing' in d(h,'view')
    assert d(h,'check')==''
    d(h,'heartbeat','--task','hermes-lab')
    assert 'state=progressing' in d(h,'view')
    assert d(h,'check')==''
    time.sleep(31.1)
    out=d(h,'check')
    assert re.search(r'escalation task=hermes-lab age=\d+ last_receipt=heartbeat@\d+',out)
    msg=h/'state/supervisor.inbox/001.msg'
    assert 'supervisor=supervisor' in body(h,msg)
    assert d(h,'check')==''
    assert len(list((h/'state/supervisor.inbox').glob('*.msg')))==1
    say('Observable supervisor inbox has exactly one notification after two overdue checks.')

def artifacts():
    h=home('artifacts'); reg(h,window=60); p=h/'art/report.md'; good=sha(p)
    d(h,'dispatch','--task','hermes-lab')
    d(h,'deliver','--task','hermes-lab','--path',p,'--hash','0'*64,expected=1)
    assert 'state=dispatched-not-progressing' in d(h,'view')
    saved=p.read_bytes(); p.unlink()
    d(h,'deliver','--task','hermes-lab','--path',p,'--hash',good,expected=1)
    assert 'state=closed' not in d(h,'view')
    p.write_bytes(saved); other=h/'art/other.md'; other.write_bytes(saved)
    d(h,'deliver','--task','hermes-lab','--path',other,'--hash',good,expected=1)
    assert 'state=closed' not in d(h,'view')
    d(h,'deliver','--task','hermes-lab','--path',p,'--hash',good)
    assert 'state=closed' in d(h,'view')
    before=(h/'state/delegated/hermes-lab.record').read_bytes()
    d(h,'dispatch','--task','hermes-lab'); d(h,'heartbeat','--task','hermes-lab')
    d(h,'deliver','--task','hermes-lab','--path',p,'--hash',good)
    assert before==(h/'state/delegated/hermes-lab.record').read_bytes()
    say('Completed path-and-hash receipt preserved across repeated delivery, redispatch, and heartbeat.')

def hidden():
    for receiver in ['worker','firstmate']:
        h=home('hidden-'+receiver); reg(h)
        if receiver=='worker': (h/'state/worker.meta').touch()
        hand(h,receiver=receiver)
        time.sleep(3.1)
        out=d(h,'check'); assert 'delivery-failure handoff=answer' in out and 'escalation task=' not in out
        out=d(h,'check'); assert 'delivery-failure handoff=answer' in out and 'escalation task=' not in out
        d(h,'mirror','--id','answer'); assert 'handoff=answer state=mirrored' in d(h,'view')
        if receiver=='worker':
            msg=h/'state/worker.inbox/001.msg'
            received=body(h,msg); assert 'artifact='+str(h/'art/report.md') in received and 'hash='+sha(h/'art/report.md') in received
            msg.rename(msg.parent/'handled'/msg.name)
        else:
            assert not (h/'state/firstmate.inbox').exists()
            assert 'handoff=answer task=hermes-lab receiver=firstmate' in ack_primary(h)
        assert 'handoff=answer state=read' in d(h,'view')
        out=d(h,'check'); assert 'delivery-failure' not in out and 'escalation task=hermes-lab' in out
        shutil.rmtree(h/'art')
        if receiver=='worker': shutil.rmtree(h/'state/worker.inbox')
        assert 'handoff=answer state=read' in d(h,'view')
        say('Read receipt survives artifact and receiver inbox cleanup: '+receiver)

def adversarial():
    h=home('adversarial'); reg(h,window=60); (h/'state/worker.meta').touch()
    p=h/'art/report.md'
    hand(h,id='tampered',location='read')
    p.write_text('altered after placement\n')
    msg=h/'state/worker.inbox/001.msg'; body(h,msg); msg.rename(msg.parent/'handled'/msg.name)
    assert 'handoff=tampered state=delivery-failure' in d(h,'view')
    d(h,'mirror','--id','tampered',expected=1)
    hand(h,id='retired',location='alt')
    (h/'state/worker.meta').unlink()
    d(h,'mirror','--id','retired',expected=1)
    assert not list((h/'state/worker.inbox').glob('*.msg'))
    (h/'state/worker.meta').write_text('kind=secondmate\nremote_host=example.invalid\n')
    d(h,'mirror','--id','retired',expected=1)
    hand(h,id='remote-hidden',location='alt')
    hand_args=['handoff','--task','hermes-lab','--id','remote-direct','--receiver','worker','--path',str(p),'--hash',sha(p),'--alt-dir',str(h/'hosted-answers'),'--location','read']
    d(h,*hand_args,expected=1)
    assert 'handoff=remote-direct ' not in d(h,'view')
    say('Tampered artifacts, retired receivers, and remote routes cannot receive false read/mirror claims.')

def retention():
    h=home('retention'); reg(h,window=60); (h/'state/worker.meta').touch()
    persistent=h/'persistent'; persistent.mkdir(); (persistent/'support.md').write_text('supporting evidence\n')
    wt=h/'worktree'; wt.mkdir(); (wt/'evidence').symlink_to(persistent,target_is_directory=True)
    path=wt/'evidence/support.md'
    hand(h,id='supporting',location='read',path=path)
    d(h,'receipt','--before-remove',wt,expected=1)
    assert path.exists()
    msg=h/'state/worker.inbox/001.msg'; body(h,msg); msg.rename(msg.parent/'handled'/msg.name)
    d(h,'receipt','--before-remove',wt)
    shutil.rmtree(wt)
    assert (persistent/'support.md').exists() and not path.exists()
    assert 'handoff=supporting state=read' in d(h,'view')
    say('Bound lookup path retained until consumption; durable read survives symlink-ancestor removal.')

try:
    scenario('live-progress-and-exactly-once-escalation',progress)
    scenario('live-artifact-validation-and-final-receipt',artifacts)
    scenario('live-hidden-handoffs-and-read-receipts',hidden)
    scenario('live-tamper-retired-and-remote-guards',adversarial)
    scenario('live-symlink-retention-until-consumption',retention)
finally:
    shutil.rmtree(BASE)
    (E/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
