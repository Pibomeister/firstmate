import json, os, pathlib, shutil, subprocess, time, sys
ROOT = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M82EA4TGMDESVM46CSV93B53')
LAB = ROOT / '.stall-validation-lab'
LAB.mkdir()
selected=set(sys.argv[1:])
results=json.loads((E/'live-results.json').read_text()) if selected else []
log=(E/'live-watchdog.log').open('a' if selected else 'w', buffering=1)

def emit(text):
    print(text, flush=True); print(text, file=log, flush=True)

def run(argv, env=None):
    p=subprocess.run(argv, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    if p.returncode: raise RuntimeError(f'{argv}: exit {p.returncode}: {p.stdout}')
    return p.stdout

def home(name, extra=''):
    h=LAB/name
    run(['bash','bin/fm-lab-home.sh','create',str(h)])
    env=os.environ.copy()
    for k in list(env):
        if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_CONFIG_DIR','TMUX','TMUX_PANE','XDG_CONFIG_HOME','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK'):
            env.pop(k)
    env.update(FM_HOME=str(h), HOME=str(h), CLAUDE_CONFIG_DIR=str(h/'claude'))
    (h/'config/watchdog').write_text('mode=act\nmodels=\nquota-guard=off\nmemory-guard=off\nrestart=off\nheartbeat-frozen-secs=0\ncall-timeout-secs=5\n'+extra+'\n')
    (h/'config/wedge-alarm').write_text(f"command:cat >> '{h}/pages.txt'\n")
    (h/'state/.lock').write_text(str(os.getpid())+'\n')
    (h/'state/.lock-session').write_text('stall-lab-session\n')
    (h/'state/heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','generated_epoch':int(time.time()),'primary':{'session':{'trusted_id':'stall-lab-session'},'writer':{'anchor_pid':os.getpid(),'session_id':'stall-lab-session'}}}))
    return h,env

def task(h,id,verb='working',note='implementing',age=1000,kind='ship',yolo='off',mode='direct-PR',closer=''):
    (h/f'state/{id}.meta').write_text(f'kind={kind}\nbackend=tmux\nyolo={yolo}\nmode={mode}\nendpoint_task_id={id}\n')
    (h/f'state/{id}.status').write_text(f'{verb} [at={int(time.time())-age}]: {note}\n'+closer)

def wake(h,age=1000,key='inbox'):
    (h/'state/.wake-queue').write_text(f'{int(time.time())-age}\t1\tcheck\t{key}\tPRIVATE INPUT MUST NOT LEAK\n')

def rows(h,symptom,phase='done'):
    p=h/'state/watchdog/actions.tsv'
    return [r.split('\t') for r in p.read_text().splitlines() if len(r.split('\t'))>=8 and r.split('\t')[4]==symptom and r.split('\t')[6]==phase] if p.exists() else []

def pages(h):
    p=h/'pages.txt'; return p.read_text() if p.exists() else ''

def wd(h,env,label):
    ledger=h/'state/watchdog/actions.tsv'
    restarts_before=[r for r in ledger.read_text().splitlines() if r.split('\t')[5]=='restart'] if ledger.exists() else []
    before=[(h/'state'/n).read_bytes() for n in ('.lock','.lock-session')]
    emit(f'RUN {h.name}/{label}: FM_HOME=<disposable lab> bash bin/fm-watchdog.sh once')
    started=time.monotonic(); out=run(['bash','bin/fm-watchdog.sh','once'],env)
    emit(f'EXIT 0 ({time.monotonic()-started:.1f}s) {out.strip()}')
    assert before==[(h/'state'/n).read_bytes() for n in ('.lock','.lock-session')], 'lock mutation'
    for filename in ('state/watchdog/actions.tsv','data/watchdog/status.md','pages.txt'):
        p=h/filename
        if p.exists():
            emit(f'--- {label}: {filename} ---\n{p.read_text()}')
            (E/f'{h.name}-{label}-{p.name}').write_bytes(p.read_bytes())
    p=h/'state/watchdog/actions.tsv'
    if p.exists(): assert restarts_before==[r for r in p.read_text().splitlines() if r.split('\t')[5]=='restart'], 'unexpected restart'
    assert 'PRIVATE INPUT' not in pages(h), 'input leaked into page'

def scenario(name,fn):
    if selected and fn.__name__ not in selected: return
    results[:]=[r for r in results if r['name']!=name]
    emit('\nSCENARIO '+name)
    try:
        fn(); results.append(dict(name=name,result='pass',live=True)); emit('RESULT pass')
    except Exception as exc:
        results.append(dict(name=name,result='fail',live=True,reason=str(exc))); emit('RESULT fail '+str(exc))
    (E/'live-results.json').write_text(json.dumps(results,indent=2))

URL='https://github.com/synthetic/repo/pull/7'
OLD='https://github.com/synthetic/repo/pull/6'

def input_rate():
    h,e=home('input','stall-page-secs=2')
    task(h,'working'); wake(h,600); wd(h,e,'below-threshold'); assert not pages(h)
    wake(h); wd(h,e,'aged'); assert len(rows(h,'stall-input'))==1
    # Default window first: repeat under the production 3600s limit.
    with (h/'config/watchdog').open('a') as f: f.write('stall-page-secs=3600\n')
    wd(h,e,'repeat'); assert len(rows(h,'stall-input'))==1
    with (h/'config/watchdog').open('a') as f: f.write('stall-page-secs=2\n')
    time.sleep(2); wd(h,e,'expired-local-window'); assert len(rows(h,'stall-input'))==2
scenario('Synthetic local input crosses 900 seconds; live holder and fresh heartbeat do not suppress the page; repeats are limited',input_rate)

def prs():
    h,e=home('pr'); task(h,'pr','done',f'PR {URL} checks green; replaces {OLD}',yolo='on')
    wd(h,e,'delivered'); assert URL in pages(h) and OLD not in pages(h)
    wd(h,e,'repeat'); assert len(rows(h,'stall-pr'))==1
    marker=h/'state/pr.pr-poll-merge-notified'
    marker.write_text('fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nsynthetic/repo\n7\n'); marker.chmod(0o600)
    wd(h,e,'landed'); assert 'ready PRs unlanded' not in (h/'data/watchdog/status.md').read_text()
    h,e=home('forgejo'); u='https://git.example.test/o/r/pulls/9'; task(h,'pr','done',f'PR {u} checks green',yolo='on')
    m=h/'state/pr.pr-poll-merge-notified'; m.write_text('fm-pr-poll-merge-notified-v1\nforgejo\nother.example.test\no/r\n9\n'); m.chmod(0o600)
    wd(h,e,'wrong-host'); assert u in pages(h)
    m.write_text('fm-pr-poll-merge-notified-v1\nforgejo\ngit.example.test\no/r\n9\n')
    wd(h,e,'matching-host'); assert 'ready PRs unlanded' not in (h/'data/watchdog/status.md').read_text()
scenario('Synthetic local ready GitHub and Forgejo PRs page once using the delivered PR and exact merge-marker identity',prs)

def quiet():
    h,e=home('quiet'); task(h,'wait','paused','waiting on CI'); wake(h,key='wait.status'); wd(h,e,'declared-wait'); assert not pages(h)
    task(h,'wait','done',f'PR {URL} checks green',closer=f'resolved [at={int(time.time())}]: question closed\n'); wake(h); wd(h,e,'finished'); assert not pages(h)
    task(h,'wait','failed','build failed'); wd(h,e,'failed'); assert not pages(h)
    task(h,'active'); wd(h,e,'mixed'); assert 'while 1 tasks are in flight' in pages(h)
scenario('Synthetic local declared waits and done/failed-only homes stay quiet; active work beside finished work still pages',quiet)

def handoffs():
    h,e=home('handoff'); task(h,'ship','done','implemented the fix',mode='no-mistakes'); wake(h)
    wd(h,e,'pipeline'); assert len(rows(h,'stall-input'))==1
    h,e=home('empty-mode'); task(h,'ship','done','implemented the fix',mode=''); wake(h)
    wd(h,e,'default-pipeline'); assert len(rows(h,'stall-input'))==1
    for mode in ('direct-PR','local-only'):
        h,e=home('finished-'+mode); task(h,'ship','done','implemented the fix',mode=mode); wake(h)
        wd(h,e,'finished'); assert not pages(h)
    h,e=home('closers'); task(h,'ship','done',f'PR {URL} checks green',yolo='on',closer=f'captain-held [at={int(time.time())}]: owner wait\n')
    wd(h,e,'declared-owner-wait'); assert not pages(h)
    with (h/'state/ship.status').open('a') as f: f.write(f'resolved [at={int(time.time())}]: close question\n')
    wd(h,e,'ready'); assert len(rows(h,'stall-pr'))==1
scenario('Synthetic local no-mistakes handoffs remain in flight while direct-PR/local-only done reports finish; decision closers preserve delivered PRs',handoffs)

def holds():
    h,e=home('held'); task(h,'pr','done',f'PR {URL} checks green',yolo='on')
    emit(run(['bash','bin/fm-tasks-axi.sh','add','pr','Held merge','--kind','ship','--repo','example'],e))
    emit(run(['bash','bin/fm-captain-hold.sh','hold','pr','--reason','merge approval pending'],e))
    wd(h,e,'owner-wait'); assert not pages(h)
    h,e=home('unheld'); task(h,'pr','done',f'PR {URL} checks green',yolo='on')
    emit(run(['bash','bin/fm-tasks-axi.sh','add','pr','Unheld merge','--kind','ship','--repo','example'],e))
    wd(h,e,'no-hold'); assert len(rows(h,'stall-pr'))==1
    h,e=home('hold-read-error'); task(h,'pr','done',f'PR {URL} checks green',yolo='on')
    (h/'.tasks.toml').write_text('this is invalid toml = [\n')
    wd(h,e,'unreadable'); assert len(rows(h,'stall-pr'))==1
scenario('Synthetic local backlog captain hold suppresses ready PR paging; unheld and unreadable holds do not hide stalls',holds)

def exclusion():
    h,e=home('excluded'); task(h,'off','done',f'PR {URL} checks green',yolo='off'); task(h,'gerrit','done','PR https://review.example.test/c/proj/+/123 published',yolo='on'); task(h,'scout','done',f'PR {URL} checks green',yolo='on',kind='scout'); task(h,'young','done',f'PR {URL} checks green',yolo='on',age=400)
    wd(h,e,'quiet'); assert not pages(h)
scenario('Synthetic local owner-merge waits, Gerrit, scouts, and PRs below 900 seconds stay quiet',exclusion)

def channels():
    h,e=home('dry','mode=dry-run'); task(h,'active'); wake(h); wd(h,e,'dry'); assert not pages(h) and len(rows(h,'stall-input','dry-run'))==1
    h,e=home('off'); task(h,'active'); wake(h); (h/'config/wedge-alarm').write_text('off\n'); wd(h,e,'refused'); assert not pages(h) and len(rows(h,'stall-input','refused'))==1
scenario('Synthetic local dry-run records without sending; disabled alerts report a refused page',channels)


def pickup():
    h,e=home('pickup')
    task(h,'active'); task(h,'ready','done',f'PR {URL} checks green',yolo='on'); wake(h)
    (h/'state/watchdog').mkdir(exist_ok=True)
    (h/'state/watchdog/actions.tsv').write_text(f'{int(time.time())}\tlab-pending\t{h}\t{h.name}\tagent-gone\trestart\tpending\ttoken=abc old_pid=999999\n')
    wd(h,e,'pending'); assert len(rows(h,'stall-input'))==1 and len(rows(h,'stall-pr'))==1
    assert 'RESTART-AWAITING-PICKUP' in (h/'data/watchdog/status.md').read_text()
    wd(h,e,'repeat'); assert len(rows(h,'stall-input'))==1 and len(rows(h,'stall-pr'))==1
scenario('Synthetic local persisted restart-pickup state still pages both stalls once without an added restart or lock change',pickup)

try:
    pass
finally:
    shutil.rmtree(LAB)
    log.close()
if any(r['result']=='fail' for r in results): raise SystemExit(1)
