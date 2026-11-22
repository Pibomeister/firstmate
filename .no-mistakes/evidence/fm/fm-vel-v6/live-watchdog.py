import os, pathlib, subprocess, time, json, shutil, sys
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M82609JHVFPBH4E557YD2MJV')
LAB=ROOT/'.test-stall-live'
LAB.mkdir(exist_ok=False)
log=(E/'live-watchdog.log').open('a',buffering=1)
results=json.loads((E/'live-results.json').read_text()) if '--pr-only' in sys.argv else []
base=os.environ.copy()
for k in list(base):
    if k.startswith(('FM_','TASKS_AXI_','CLAUDE_','ORCA_','REX_')) or k in ('TMUX','TMUX_PANE'):
        base.pop(k,None)
base.update(HOME=str(LAB/'user'),XDG_CONFIG_HOME=str(LAB/'user/config'),XDG_CACHE_HOME=str(LAB/'user/cache'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
(LAB/'user').mkdir()
holder=subprocess.Popen(['sleep','3000'])
count=0

def write(p,s):
    p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)

def fresh(extra=''):
    global count,h,env,locks
    count+=1;h=LAB/str(count)
    subprocess.run(['bin/fm-lab-home.sh','create',str(h)],env=base,check=True,stdout=subprocess.DEVNULL)
    env=base.copy();env['FM_HOME']=str(h)
    write(h/'config/watchdog','mode=act\nmodels=\nquota-guard=off\nmemory-guard=off\nrestart=off\nheartbeat-frozen-secs=0\n'+extra+'\n')
    write(h/'config/wedge-alarm',"command:cat >> '"+str(h/'pages.log')+"'\n")
    write(h/'state/.lock',str(holder.pid)+'\n');write(h/'state/.lock-session','00000000-0000-4000-8000-000000000001\n')
    write(h/'state/heartbeat.json',json.dumps({'schema':'fm-heartbeat.v1','generated_epoch':int(time.time()),'primary':{'session':{'trusted_id':'00000000-0000-4000-8000-000000000001'},'writer':{'anchor_pid':holder.pid,'session_id':'00000000-0000-4000-8000-000000000001'}}}))
    locks=[(h/'state/.lock').read_bytes(),(h/'state/.lock-session').read_bytes()]

def task(id='a',verb='working',note='implementing',age=1000,yolo='off',mode='',kind='ship',closer=''):
    write(h/('state/'+id+'.meta'),f'kind={kind}\nyolo={yolo}\nmode={mode}\n')
    write(h/('state/'+id+'.status'),f'{verb} [at={int(time.time())-age}]: {note}\n'+closer)

def wake(age=1000,key='inbox'):
    write(h/'state/.wake-queue',f'{int(time.time())-age}\t1\tcheck\t{key}\tSECRET INPUT MUST NOT LEAK\n')

def rows(symptom):
    p=h/'state/watchdog/actions.tsv'
    return [r.split('\t') for r in p.read_text().splitlines() if len(r.split('\t'))>=8 and r.split('\t')[4]==symptom] if p.exists() else []

def pages(symptom):return sum(r[6]=='done' for r in rows(symptom))

def run(label,expected):
    log.write('\n=== '+label+' ===\n')
    p=subprocess.run(['bash','bin/fm-watchdog.sh','once'],env=env,capture_output=True,text=True,timeout=180)
    log.write('command: FM_HOME=<disposable lab> bash bin/fm-watchdog.sh once\nexit: '+str(p.returncode)+'\n'+p.stdout+p.stderr)
    for name in ('pages.log','data/watchdog/status.md','state/watchdog/actions.tsv'):
        f=h/name
        if f.exists():log.write('\n'+name+':\n'+f.read_text())
    assert p.returncode==0,(label,p.stderr)
    for symptom,n in expected.items():assert pages(symptom)==n,(label,symptom,pages(symptom),n)
    assert locks==[(h/'state/.lock').read_bytes(),(h/'state/.lock-session').read_bytes()],label+' lock changed'
    assert holder.poll() is None
    assert 'SECRET INPUT MUST NOT LEAK' not in (h/'pages.log').read_text() if (h/'pages.log').exists() else True
    log.write('OBSERVED: expected page deliveries; session lock bytes unchanged; live holder survives.\n')

def scenario(name,fn):
    results[:]=[r for r in results if r['name']!=name]
    try:fn();results.append({'name':name,'result':'pass'})
    except Exception as e:results.append({'name':name,'result':'fail','error':repr(e)});log.write('FAIL '+repr(e)+'\n')
    (E/'live-results.json').write_text(json.dumps(results,indent=2))

url='https://github.com/acme/repo/pull/42'
def input_case():
    fresh();task();wake(600);run('input below 15 minutes',{'stall-input':0})
    wake();run('old input with live holder and fresh beacon',{'stall-input':1})
    run('repeat pass is rate limited',{'stall-input':1})
    # Configurable window exercises actual clock expiry without a clock seam.
    with (h/'config/watchdog').open('a') as f:f.write('stall-page-secs=1\n')
    time.sleep(1.1);run('configured page window expires',{'stall-input':2})
    (h/'state/.wake-queue').unlink();write(h/'state/inbox/local.note','SECRET INPUT MUST NOT LEAK\n');os.utime(h/'state/inbox/local.note',(time.time()-1000,)*2)
    time.sleep(1.1);run('old inbox note also pages',{'stall-input':3})

def finished_case():
    for verb,note,mode,closer,expected in [('done','PR '+url+' checks green','','resolved [key=permission-prompt-hardstop]: cleared\n',0),('failed','unable to finish','','',0),('done','implementation complete','','',1),('done','implementation complete','no-mistakes','',1),('done','implementation complete','direct-PR','',0),('done','implementation complete','local-only','',0)]:
        fresh();task(verb=verb,note=note,mode=mode,closer=closer);wake();run('finished/handoff '+verb+' '+mode+' '+note,{'stall-input':expected,'stall-pr':0})

def pr_case():
    fresh();task(verb='done',note='PR '+url+' checks green; replaces https://github.com/acme/repo/pull/41',yolo='on',closer='resolved [key=pp-1]: cleared\ncaptain-held [key=x]: decision closed\n');run('latest captain-held status is a declared owner wait',{'stall-pr':0})
    with (h/'state/a.status').open('a') as f:f.write('resolved [key=x]: decision resolved\n')
    run('delivered PR before other URL after decision closers',{'stall-pr':1})
    assert 'pull/41' not in (h/'pages.log').read_text()
    run('PR page rate limited',{'stall-pr':1})
    fresh();task(verb='done',note='PR '+url+' checks green; replaces https://github.com/acme/repo/pull/41',yolo='on')
    write(h/'state/a.pr-poll-merge-notified','fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/repo\n42\n');(h/'state/a.pr-poll-merge-notified').chmod(0o600)
    run('landed delivered PR stays quiet despite second URL',{'stall-pr':0})
    forge='https://forge.example/acme/repo/pulls/42'
    for marker,expected in [('fm-pr-poll-merge-notified-v1\nforgejo\nother.example\nacme/repo\n42\n',1),('invalid-version\nforgejo\nforge.example\nacme/repo\n42\n',1),('fm-pr-poll-merge-notified-v1\nforgejo\nforge.example\nacme/repo\n42\n',0)]:
        fresh();task(verb='done',note='PR '+forge+' checks green',yolo='on');write(h/'state/a.pr-poll-merge-notified',marker);(h/'state/a.pr-poll-merge-notified').chmod(0o600);run('Forgejo marker identity '+marker.replace('\n',' '),{'stall-pr':expected})
    for note,yolo,kind,age in [('PR '+url+' checks green','off','ship',1000),('PR https://review.example/c/proj/+/123 published','on','ship',1000),('PR '+url+' checks green','on','scout',1000),('see '+url,'on','ship',1000),('PR '+url+' checks green','on','ship',600)]:
        fresh();task(verb='done',note=note,yolo=yolo,kind=kind,age=age);run('PR authority/readiness guard '+note+' '+yolo+' '+kind+str(age),{'stall-pr':0})

def wait_case():
    fresh();task(id='active');task(id='wait',verb='paused',note='waiting on CI');wake(key='wait.status');run('declared wait wake ignored beside active work',{'stall-input':0})
    fresh();task(id='wait',verb='paused',note='waiting on CI');wake();run('only declared wait has no work in flight',{'stall-input':0})
    fresh();task();task(id='wait',verb='paused',note='waiting on CI');write(h/'state/wait.meta','kind=ship\nbackend=t3code\nt3_thread_id=thread-wait\n');wake(key='thread-wait.stale');
    with (h/'state/.wake-queue').open('a') as f:f.write('0009\t1\tcheck\tinbox\tbad timestamp\n')
    run('t3code wait endpoint and leading-zero timestamp ignored',{'stall-input':0})

def hold_case():
    fresh();task(verb='done',note='PR '+url+' checks green',yolo='on')
    for args in [['bin/fm-tasks-axi.sh','add','a','Held merge','--kind','ship','--repo','example'],['bin/fm-captain-hold.sh','hold','a','--reason','merge approval pending']]:
        p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=60);log.write(str(args)+'\n'+p.stdout+p.stderr);assert p.returncode==0
    p=subprocess.run(['bin/fm-captain-hold.sh','open','a','--distinguish-absent'],env=env,capture_output=True,text=True);assert p.returncode==0
    run('real captain hold keeps ready PR quiet',{'stall-pr':0})
    fresh();task(verb='done',note='PR '+url+' checks green',yolo='on');write(h/'.tasks.toml','backend = "invalid-backend"\n')
    p=subprocess.run(['bin/fm-captain-hold.sh','open','a','--distinguish-absent'],env=env,capture_output=True,text=True);log.write('unreadable hold result '+str(p.returncode)+'\n'+p.stderr);assert p.returncode!=0
    run('failed real hold read does not conceal PR',{'stall-pr':1})

def pickup_case():
    fresh();task();task(id='p',verb='done',note='PR '+url+' checks green',yolo='on');wake()
    write(h/'state/watchdog/actions.tsv',f'{int(time.time())}\tlab-pending\t{h}\tprimary\tagent-gone\trestart\tpending\ttoken=abcdef old_pid=999999\n')
    run('both stalls while restart awaits pickup',{'stall-input':1,'stall-pr':1})
    assert 'RESTART-AWAITING-PICKUP' in (h/'data/watchdog/status.md').read_text()
    run('both triggers remain rate limited during pickup',{'stall-input':1,'stall-pr':1})
    rs=[r for r in (h/'state/watchdog/actions.tsv').read_text().splitlines() if r.split('\t')[5]=='restart'];assert len(rs)==1

try:
    if '--pr-only' in sys.argv:log.write('\nSETUP CORRECTION: the initial probe incorrectly expected a latest captain-held event to page. The declared-wait contract says it must stay quiet. Re-drive that case, then append resolved to end that wait and check delivered-PR parsing. No product change.\n')
    for name,fn in [('Input threshold, live holder, fresh beacon, rate limit and inbox',input_case),('Finished statuses, decision closers and no-mistakes handoff',finished_case),('Delivered PR identity, merge markers and authority guards',pr_case),('Declared waits and malformed timestamps',wait_case),('Owner hold and failed hold read',hold_case),('Stall pages during pending restart pickup',pickup_case)]:
        if '--pr-only' not in sys.argv or fn==pr_case:scenario(name,fn)
finally:
    holder.terminate();holder.wait();shutil.rmtree(LAB);log.write('\nCLEANUP: disposable homes removed and lock holder reaped.\n');log.close()
print(json.dumps(results,indent=2))
raise SystemExit(any(r['result']=='fail' for r in results))
