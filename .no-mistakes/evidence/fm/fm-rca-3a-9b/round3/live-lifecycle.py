from pathlib import Path
src=Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8/round3/live-delegated.py').read_text()
exec(compile(src.split('\ntry:\n')[0].replace('timeout=60','timeout=180'),'<live-helpers>','exec'))
original_call=call
contexts={}
servers=[]
def call(h,args,expected=0,extra=None):
    return original_call(h,args,expected,dict(contexts.get(str(h),{}),**(extra or {})))
def tm(h,*args): return call(h,['bash','bin/fm-lab-home.sh','tmux',str(h),*args])[0]
def lifecycle():
    h=home('lifecycle'); servers.append(h)
    (h/'config/backend').write_text('tmux\n')
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    contexts[str(h)]={'TREEHOUSE_ROOT':str(h/'pool'),'XDG_STATE_HOME':str(h/'xdg-state'),'DISABLE_AUTOUPDATER':'1'}
    tm(h,'new-session','-d','-s','lab','-n','primary','-x','120','-y','40','-c',str(ROOT))
    identity=tm(h,'display-message','-p','#{socket_path},#{pid},0').strip()
    contexts[str(h)]={'TMUX':identity,'FM_BACKEND':'tmux','TREEHOUSE_ROOT':str(h/'pool'),'XDG_STATE_HOME':str(h/'xdg-state'),'DISABLE_AUTOUPDATER':'1'}
    proj=h/'projects/toy'
    call(h,['git','init','-q','-b','main',str(proj)])
    call(h,['git','-C',str(proj),'-c','user.name=Live Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','synthetic base'])
    task='nmlive-'+str(os.getpid())+'-scout'
    call(h,['bash','bin/fm-ledger.sh','intake',task,'--project','toy','--title','Synthetic scout launch registration probe','--source','ask:live-lifecycle','--kind','scout'])
    call(h,['bash','bin/fm-brief.sh',task,'toy','--scout'])
    brief=h/'data'/task/'brief.md'
    text=brief.read_text().replace('{TASK}','Validate a disposable launch only. Do not change project files.').replace('{FIRSTMATE_SPEC}','This lab contains synthetic data. No push, PR, or network mutations are requested.')
    brief.write_text(text)
    (E/'emitted-scout-brief.md').write_text(text)
    assert 'heartbeat --task' in text and 'deliver --task' in text
    launch="codex exec --disable hooks --skip-git-repo-check --sandbox read-only 'Reply exactly LAB_READY. Do not run tools.'"
    call(h,['bash','bin/fm-spawn.sh',task,str(proj),'--scout',launch,'--backend','tmux'])
    view=d(h,'view','--task',task)
    assert 'state=dispatched-not-progressing' in view
    record=(h/'state/delegated'/f'{task}.record').read_text()
    say('PERSISTED DELEGATION CONTRACT\n'+record)
    assert 'heartbeat_secs=300\n' in record and 'silence_secs=7200\n' in record
    assert 'artifact_path='+str(h/'data'/task/'report.md') in record
    # Await the real harness's result, rather than treating launch as a completed run.
    deadline=time.monotonic()+120
    found=False
    while time.monotonic()<deadline:
        out=tm(h,'capture-pane','-p','-t','lab:fm-'+task,'-S','-80')
        if '\nLAB_READY\n' in out and (h/'state'/f'{task}.agent-exit').exists(): found=True; break
        time.sleep(1)
    assert found,'real Codex exec did not complete its probe'
    exit_receipt=(h/'state'/f'{task}.agent-exit').read_text(); say('ACTUAL HARNESS EXIT RECEIPT '+exit_receipt)
    assert exit_receipt.strip().endswith('\t0')
    # Re-emitted session digest reads the same local records without starting the deferred network sweep.
    out,err=call(h,['bash','bin/fm-session-start.sh','--reemit'])
    (E/'live-session-start-digest.log').write_text(out+'\nSTDERR\n'+err)
    assert 'DELEGATED PROGRESS' in out and 'task='+task+' state=dispatched-not-progressing' in out
    # Complete the synthetic scout, so its runtime can be cleaned through the normal path.
    report=h/'data'/task/'report.md'; report.write_text('Synthetic launch probe completed with LAB_READY. No project edits.\n')
    d(h,'deliver','--task',task,'--path',report,'--hash',sha(report))
    call(h,['bash','bin/fm-captain-hold.sh','complete',task,'--none'])
    call(h,['bash','bin/fm-teardown.sh',task])
    # A normal watcher process checks an overdue task and routes its escalation to the wake channel.
    reg(h,task='hermes-watcher',window=2)
    d(h,'dispatch','--task','hermes-watcher')
    time.sleep(3.1)
    out,err=call(h,['bash','bin/fm-watch.sh'])
    queue=(h/'state/.wake-queue').read_text(); say('WATCHER QUEUED OUTPUT\n'+queue)
    assert 'escalation task=hermes-watcher' in queue and 'last_receipt=dispatch@' in queue
    assert 'escalation task=hermes-watcher' not in d(h,'check')
    say('Normal watcher completed after routing one delegated escalation.')
try:
    scenario('live-spawn-brief-session-and-watcher',lifecycle)
finally:
    for h in servers:
        if (h/'state/.fm-lab-tmux-dir').exists():
            try: tm(h,'kill-server')
            finally: call(h,['bash','bin/fm-lab-home.sh','teardown',str(h)])
    shutil.rmtree(BASE)
    (E/'live-lifecycle-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
