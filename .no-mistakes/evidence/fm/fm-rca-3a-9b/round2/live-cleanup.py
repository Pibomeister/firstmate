from pathlib import Path
src=Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8/round2/live-delegated.py').read_text()
exec(compile(src.split('\ntry:\n')[0].replace('timeout=60','timeout=240'),'<live-helpers>','exec'))
original_call=call
contexts={}
servers=[]
cleaned=set()
def call(h,args,expected=0,extra=None):
    extra=dict(contexts.get(str(h),{}),**(extra or {}))
    if len(args)>1 and args[1]=='bin/fm-teardown.sh':
        env=os.environ.copy()
        for k in list(env):
            if k.startswith('FM_') or k in ('TMUX','TMUX_PANE'): env.pop(k,None)
        env.update(extra); env['FM_HOME']=str(h)
        say('$ '+shlex.join(args))
        with (E/'live-optional-teardown.stdout').open('w') as out, (E/'live-optional-teardown.trace.log').open('w') as err:
            p=subprocess.Popen(['bash','-x',*args[1:]],env=env,stdout=out,stderr=err,start_new_session=True)
            try:
                rc=p.wait(timeout=600)
                (E/'live-optional-teardown.result.json').write_text(json.dumps({'command':shlex.join(args),'exit_code':rc})+'\n')
            except BaseException:
                import signal
                os.killpg(p.pid,signal.SIGTERM)
                try: p.wait(timeout=10)
                except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
                raise
        stdout=(E/'live-optional-teardown.stdout').read_text()
        stderr=(E/'live-optional-teardown.trace.log').read_text(errors='replace')
        say(stdout)
        say('stderr diagnostics retained in live-optional-teardown.trace.log')
        say('exit='+str(rc))
        assert rc==expected,(rc,expected)
        return stdout,stderr
    return original_call(h,args,expected,extra)
def tm(h,*args): return call(h,['bash','bin/fm-lab-home.sh','tmux',str(h),*args])[0]
def setup(name,task):
    h=home(name)
    tm(h,'new-session','-d','-s','lab','-n','primary','-x','120','-y','40','-c',str(ROOT))
    identity=tm(h,'display-message','-p','#{socket_path},#{pid},0').strip()
    servers.append(h)
    contexts[str(h)]={'TMUX':identity,'FM_BACKEND':'tmux','TREEHOUSE_ROOT':str(h/'pool')}
    proj=h/'projects/toy'
    call(h,['git','init','-q','-b','main',str(proj)])
    call(h,['git','-C',str(proj),'-c','user.name=Live Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','synthetic base'])
    out,_=call(h,['bash','-c','cd "$1" && treehouse get --lease --no-fetch --json','_',str(proj)])
    lease=json.loads(out); say('LEASE '+json.dumps(lease))
    # Treehouse prints a path key on its public JSON allocation contract.
    wt=pathlib.Path(lease.get('path') or lease.get('worktree_path') or lease.get('worktree',{}).get('path'))
    tm(h,'new-window','-d','-t','lab:','-n','fm-'+task,'-c',str(wt),"perl -e 'sleep'")
    (h/'state'/f'{task}.meta').write_text(f'window=lab:fm-{task}\nendpoint_task_id={task}\nbackend=tmux\nworktree={wt}\nproject={proj}\nkind=ship\nmode=local-only\nyolo=off\nharness=codex\nspawn_gen=1795580000.1234\n')
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    call(h,['bash','bin/fm-ledger.sh','intake',task,'--project','toy','--title','Synthetic completed task','--source','ask:live-cleanup','--kind','ship'])
    (h/'state/receiver.meta').touch()
    return h,wt

def cleanup_server(h):
    if str(h) in cleaned: return
    try: tm(h,'kill-server')
    finally:
        call(h,['bash','bin/fm-lab-home.sh','teardown',str(h)])
        cleaned.add(str(h))

def runtime_and_optional():
    for mode in ['runtime', 'optional']:
        h=None
        try:
            task='producer' if mode=='runtime' else 'unrelated'
            h,wt=setup(mode,task)
            (h/'config/status-archive').touch()
            (h/'state'/f'{task}.status').write_text('done: synthetic completed task\n')
            if mode=='runtime': artifact=h/'state/producer.status'
            else:
                artifact=h/'data/older-task/status.log'; artifact.parent.mkdir(); artifact.write_text('done: earlier task evidence\n'); os.utime(artifact,(1577836800,1577836800))
            d(h,'register','--task','evidence-owner','--deliverable','report','--artifact',h/'data/final-report.md','--heartbeat-secs','60','--silence-secs','7200')
            d(h,'handoff','--task','evidence-owner','--id','evidence','--receiver','receiver','--path',artifact,'--hash',sha(artifact),'--alt-dir',h/'hosted','--location','read')
            if mode=='runtime':
                out,err=call(h,['bash','bin/fm-teardown.sh',task],expected=1)
                assert 'cleanup deferred: handoff evidence' in err and artifact.exists() and (h/'state'/f'{task}.meta').exists()
                say('Real teardown preserved runtime evidence and task record while consumption is pending.')
                msg=h/'state/receiver.inbox/001.msg'; body(h,msg); msg.rename(msg.parent/'handled'/msg.name)
                call(h,['bash','bin/fm-teardown.sh',task])
                assert not artifact.exists() and not (h/'state'/f'{task}.meta').exists()
                assert 'handoff=evidence state=read' in d(h,'view')
            else:
                out,err=call(h,['bash','bin/fm-teardown.sh',task])
                assert 'warning: could not prune status archive:' in err and artifact.exists()
                assert not (h/'state'/f'{task}.meta').exists() and not (h/'state'/f'{task}.status').exists()
                say('Optional unread archive retained with warning; unrelated task fully finalized.')
                msg=h/'state/receiver.inbox/001.msg'; body(h,msg); msg.rename(msg.parent/'handled'/msg.name)
                d(h,'receipt','--before-remove',artifact)
        finally:
            if h: cleanup_server(h)
try:
    scenario('live-runtime-retention-and-optional-pruning',runtime_and_optional)
finally:
    for h in servers:
        if str(h) not in cleaned: cleanup_server(h)
    shutil.rmtree(BASE)
    (E/'live-cleanup-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
