import copy, datetime as dt, fcntl, http.server, json, os, pathlib, plistlib, shutil, signal, socket, socketserver, ssl, subprocess, sys, threading, time, urllib.parse
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.test-goal-digest-tmp/live'
EVID=pathlib.Path('~/.no-mistakes/evidence/01M855C215WA26T6GGYS0503Y6')
LAB.mkdir(parents=True,exist_ok=True)
SCRIPT=ROOT/'bin/fm-goal-digest.sh'
BASE_ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GH_', 'GITHUB_'))}
BASE_ENV.update(HOME=str(LAB/'user'), TMPDIR=str(LAB), GH_CONFIG_DIR=str(LAB/'gh'), GH_ENTERPRISE_TOKEN='synthetic-local-only', GH_TOKEN='synthetic-local-only', GH_PROMPT_DISABLED='1', GH_NO_UPDATE_NOTIFIER='1', GH_NO_EXTENSION_UPDATE_NOTIFIER='1')
for folder in ('user','gh'): (LAB/folder).mkdir(exist_ok=True)
results=[]
log=open(EVID/'live-transcript.log','w',buffering=1)
def say(msg):
    print(msg,flush=True); print(msg,file=log,flush=True)
def run(args, env=None, timeout=90):
    res=subprocess.run([str(a) for a in args],env=env or BASE_ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    say(f'$ {" ".join(str(a) for a in args)}\nexit={res.returncode}\n{res.stdout}{res.stderr}')
    return res
def home(name,extra=''):
    h=LAB/name; (h/'config').mkdir(parents=True,exist_ok=True)
    (h/'config/goal-digest').write_text(extra)
    return h
def digest(h,extra=None,timeout=90):
    env=dict(BASE_ENV,FM_HOME=str(h)); env.update(extra or {})
    return run([SCRIPT,'run'],env,timeout)
def data(h): return json.loads((h/'data/goal-digest/latest.json').read_text())
def keep(h,name):
    for suffix in ('json','md'):
        shutil.copyfile(h/f'data/goal-digest/latest.{suffix}',EVID/f'{name}.{suffix}')
def scenario(name,fn):
    try:
        fn(); results.append(dict(name=name,result='pass',live=True,evidence='live-transcript.log',reason='Executed the real digest CLI in a disposable home with synthetic inputs.'))
        say('PASS '+name)
    except Exception as e:
        results.append(dict(name=name,result='fail',live=True,evidence='live-transcript.log',reason=str(e)))
        say('FAIL '+name+': '+repr(e))
        raise

# Real gh uses a workspace-local Unix-socket GitHub API emulator. All service data
# is synthetic; GET is the only method accepted. This is not GitHub validation.
now=lambda:dt.datetime.now(dt.timezone.utc)
stamp=lambda d:d.strftime('%Y-%m-%dT%H:%M:%SZ')
api={'closed':[], 'open':[], 'fail_page':None, 'delay':0}
requests=[]
class API(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p=urllib.parse.urlsplit(self.path); q=urllib.parse.parse_qs(p.query)
        state=q.get('state',[''])[0]; page=int(q.get('page',['1'])[0]); requests.append({'method':'GET','path':self.path})
        if api['delay']: time.sleep(api['delay'])
        if api['fail_page']==(state,page):
            self.send_error(503); return
        rows=api.get(state,[])[(page-1)*100:page*100]
        encoded=json.dumps(rows).encode()
        try:
            self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
        except (BrokenPipeError,ssl.SSLEOFError): pass
    def log_message(self,*args): pass
class LocalServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads=True
socket_path='.test-goal-digest-tmp/local-api.sock'
server=LocalServer(socket_path,API)
thread=threading.Thread(target=server.serve_forever);thread.start()
BASE_ENV.update(GH_HOST='synthetic.example.invalid')
(LAB/'gh/config.yml').write_text('http_unix_socket: '+socket_path+'\n')

def local_owner():
    h=home('owner')
    snap={'schema':'fm-fleet-snapshot.v1','backlog':{'present':True,'records':[{'id':'ask','title':'Choose release window','captain_actionable':True,'hold_set':stamp(now()-dt.timedelta(hours=3,minutes=5))},{'id':'work','title':'Worker task','captain_actionable':False}]},'secondmate_current':{'registry':{'available':True,'complete':True},'records':[{'id':'mate','registered':True,'provenance':{'selected':'structured-home','trust':'complete','summary_source':'home-ledger'},'freshness':{'status':'fresh'},'decisions_open':[{'id':'route','verb':'captain-hold','question':'Choose route'},{'id':'other','verb':'working','question':'No action'}],'counts':{'decisions_open':2},'current':{'state':'ready'}}],'truncated':0}}
    (h/'fleet.json').write_text(json.dumps(snap))
    (h/'status.txt').write_text('eta: 2020-01-01 overdue\nbeta 2020-01-01 not an ETA\nshipped 2020-01-01 (eta: 2099-01-01)\n')
    os.utime(h/'status.txt',(time.time()-72*3600,)*2)
    ledger=['T1: blocked','T7: pending','T5: done','T6b: pending','T10: pending','T8: done','AgentKit: 2 unresolved']
    (h/'review.txt').write_text('\n'.join(ledger)+'\n')
    (h/'config/goal-digest').write_text(f'status = Fleet | {h}/fleet.json\nstatus = M4 | {h}/status.txt\nstatus = Offline | {h}/missing\nreview = Reviews | {h}/review.txt\n')
    assert digest(h).returncode==0
    d=data(h)
    assert [(w['id'],w['age_hours']) for w in d['waiting_on_captain']]==[('ask',3),('route',None)],d
    assert d['waiting_on_captain_status']=='unknown'
    assert [e['eta'] for e in d['missed_etas']]==['2020-01-01']
    assert d['stalls']==[{'source':'M4','age_hours':72}]
    assert d['review_convergence']==[{'source':'Reviews','entries':ledger}]
    assert d['generated_at_local'].endswith('-0600 CST')
    keep(h,'owner-first')
    assert digest(h).returncode==0 and data(h)['changed'] is False
    snap['secondmate_current']['records'][0]['freshness']['status']='cached'
    (h/'fleet.json').write_text(json.dumps(snap))
    assert digest(h).returncode==0
    d=data(h); assert d['changed'] and len(d['waiting_on_captain'])==2
    assert any('cached' in s['detail'] for s in d['waiting_on_captain_unknown_sources'])
    keep(h,'owner-cached')
    assert digest(h).returncode==0 and data(h)['changed'] is False
    snap['secondmate_current']['records'][0]['freshness']['status']='fresh'
    (h/'fleet.json').write_text(json.dumps(snap))
    assert digest(h).returncode==0 and data(h)['changed']
    snap['backlog']['records'][0]['captain_actionable']=False
    snap['secondmate_current']['records'][0]['decisions_open']=[]
    (h/'fleet.json').write_text(json.dumps(snap))
    assert digest(h).returncode==0 and data(h)['waiting_on_captain']==[] and data(h)['changed']
    keep(h,'owner-resolved')

def pr(number,merged=None,title=None):
    return dict(number=number,title=title or f'PR {number}',html_url=f'https://synthetic.invalid/pulls/{number}',merge_commit_sha=f'{number:040x}',merged_at=stamp(merged) if merged else None,created_at=stamp(now()-dt.timedelta(days=2)),updated_at=stamp(now()),user={'login':'synthetic-user'},draft=number==7)

def network_prs():
    h=home('prs','repo = synthetic/project\n')
    api.update(closed=[pr(1,now()-dt.timedelta(minutes=10)),pr(2,now()-dt.timedelta(days=100))],open=[pr(7)])
    probe=run(['gh','api','repos/synthetic/project/pulls?state=open'])
    assert probe.returncode==0,probe.stderr
    assert digest(h).returncode==0
    d=data(h); assert [x['number'] for x in d['new_merges']]==[1] and d['new_merges'][0]['sha']=='000000000000'
    assert d['new_merges'][0]['url']=='https://synthetic.invalid/pulls/1'
    assert d['waiting_on_captain']==[] and d['open_pull_requests'][0]['draft']
    keep(h,'prs-first')
    assert digest(h).returncode==0 and data(h)['changed'] is False and data(h)['new_merges']==[]
    api['closed'].insert(0,pr(3,now()))
    api['closed'].append(pr(4,now()-dt.timedelta(days=300)))
    assert digest(h).returncode==0 and [x['number'] for x in data(h)['new_merges']]==[3]
    keep(h,'prs-new-merge')
    api['closed']=[pr(i,now()) for i in range(1000,1101)]
    start=len(requests)
    assert digest(h).returncode==0 and len(data(h)['new_merges'])==101
    assert any('page=2' in x['path'] for x in requests[start:])
    keep(h,'prs-paginated')
    old=(h/'data/goal-digest/.state/since.tsv').read_bytes()
    api['closed']=[pr(i,now()) for i in range(2000,2101)];api['fail_page']=('closed',2)
    assert digest(h).returncode==0
    d=data(h);assert d['new_merges']==[] and any(u['kind']=='repo' for u in d['unreachable_sources'])
    assert (h/'data/goal-digest/.state/since.tsv').read_bytes()==old
    keep(h,'prs-partial-unavailable')
    api['fail_page']=None
    assert digest(h).returncode==0 and len(data(h)['new_merges'])==101
    keep(h,'prs-recovered')
    assert all(x['method']=='GET' for x in requests)

# Real changed-only summarizer: this local command records invocations.
def changed_summary():
    h=home('summary')
    summary=h/'summarize.py';summary.write_text('import pathlib,sys\np=pathlib.Path(sys.argv[1]);p.write_text(p.read_text()+"call\\n" if p.exists() else "call\\n");print(sys.stdin.read())\n')
    (h/'review').write_text('T1: blocked\nT8: complete\n')
    (h/'config/goal-digest').write_text(f'review = Ledger | {h}/review\nsummarize_cmd = /usr/bin/python3 {summary} {h}/calls\n')
    assert digest(h).returncode==0
    assert (h/'calls').read_text()=='call\n'
    assert digest(h).returncode==0 and data(h)['changed'] is False
    assert (h/'calls').read_text()=='call\n'
    (h/'review').write_text('T1: complete\nT8: complete\n')
    assert digest(h).returncode==0 and data(h)['changed']
    assert (h/'calls').read_text()=='call\ncall\n'
    keep(h,'summary-ledger-change')
    shutil.copyfile(h/'data/goal-digest/summary.txt',EVID/'summary.txt')
    assert len(list((h/'data/goal-digest/history').glob('*.json')))>=1

def publication():
    h=home('publication','repo = synthetic/project\n')
    api.update(closed=[pr(9001,now()-dt.timedelta(minutes=3))],open=[],fail_page=None)
    assert digest(h).returncode==0
    saved={n:(h/f'data/goal-digest/{n}').read_bytes() for n in ('latest.json','latest.md','.state/seen.tsv','.state/since.tsv','.state/content.hash')}
    api['closed'].insert(0,pr(9002,now()))
    # A directory at every possible next archive's .tmp path forces an actual
    # filesystem failure with no fake Python or patched product.
    paths=[]
    for i in range(180):
        s=(now()+dt.timedelta(seconds=i)).strftime('%Y%m%dT%H%M%SZ')
        p=h/f'data/goal-digest/history/{s}.json.tmp';p.mkdir(exist_ok=True);paths.append(p)
    assert digest(h).returncode!=0
    assert all((h/f'data/goal-digest/{n}').read_bytes()==v for n,v in saved.items())
    for p in paths:p.rmdir()
    failures=[];reads=[0];stop=threading.Event()
    def reader():
        while not stop.is_set():
            try: json.loads((h/'data/goal-digest/latest.json').read_text());reads[0]+=1
            except Exception as e:failures.append(repr(e))
    t=threading.Thread(target=reader);t.start()
    try: assert digest(h).returncode==0
    finally:stop.set();t.join()
    assert not failures and reads[0]>0,(reads,failures)
    assert [m['number'] for m in data(h)['new_merges']]==[9002]
    keep(h,'publication-recovery')
    say(f'Concurrent reader parsed {reads[0]} complete latest.json documents; no partial publication observed.')
    say('Archive failure left latest JSON/Markdown, seen set, watermark and changed hash byte-identical; recovered merge 9002 remained reportable.')

owned=[]
extra_groups=set()
def concurrency_timeout():
    h=home('locks')
    helper=h/'blocking.py';helper.write_text('import os,pathlib,sys,time\npathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\ntime.sleep(300)\n')
    (h/'config/goal-digest').write_text(f'summarize_cmd = /usr/bin/python3 {helper} {h}/ready\n')
    env=dict(BASE_ENV,FM_HOME=str(h))
    p=subprocess.Popen([str(SCRIPT),'run'],env=env,cwd=ROOT,stdout=open(h/'first.log','w'),stderr=subprocess.STDOUT,start_new_session=True);owned.append(p)
    deadline=time.time()+60
    while not (h/'ready').exists() and time.time()<deadline and p.poll() is None:time.sleep(.1)
    assert (h/'ready').exists(),'first run never reached summarizer'
    extra_groups.add(os.getpgid(int((h/'ready').read_text())))
    r=digest(h);assert r.returncode!=0 and 'another run is in progress' in r.stderr
    os.kill(p.pid,signal.SIGKILL);p.wait()
    # A live summarizer descendant must not retain the parent digest's lock.
    (h/'config/goal-digest').write_text('')
    assert digest(h).returncode==0
    os.killpg(p.pid,signal.SIGKILL)
    for group in extra_groups:
        try:os.killpg(group,signal.SIGKILL)
        except ProcessLookupError:pass
    say('Killed digest parent; subsequent run acquired its lock while the old summarizer process group still existed.')
    # Per-call network deadline, using the real gh CLI against a slow API.
    api.update(closed=[],open=[],delay=3)
    net=home('network-timeout','repo = synthetic/project\ntimeout_seconds = 1\n')
    started=time.monotonic(); assert digest(net).returncode==0
    elapsed=time.monotonic()-started
    assert len(data(net)['unreachable_sources'])==2 and elapsed<30
    api['delay']=0;keep(net,'network-timeout')
    say(f'Slow localhost API was bounded by 1-second per-call deadlines; digest returned after {elapsed:.1f}s with explicit unavailable sources.')
    # Real summarizer deadline is 120 seconds: do not shorten production logic.
    timedhome=home('summarizer-timeout')
    sleeper=timedhome/'sleep.py';sleeper.write_text('import os,pathlib,subprocess,sys\np=subprocess.Popen(["/bin/sleep","300"]);pathlib.Path(sys.argv[1]).write_text(str(p.pid));p.wait()\n')
    (timedhome/'config/goal-digest').write_text(f'summarize_cmd = /usr/bin/python3 {sleeper} {timedhome}/child\n')
    started=time.monotonic();r=digest(timedhome,timeout=180);elapsed=time.monotonic()-started
    assert r.returncode==0 and 'summarize_cmd failed' in r.stderr and elapsed>=120
    pid=int((timedhome/'child').read_text());ps=run(['ps','-o','stat=','-p',str(pid)])
    assert not ps.stdout.strip() or 'Z' in ps.stdout,ps.stdout
    assert not (timedhome/'data/goal-digest/summary.txt.tmp').exists()
    assert digest(timedhome).returncode==0
    keep(timedhome,'summarizer-timeout')
    say(f'Production 120-second summarizer deadline elapsed after {elapsed:.1f}s; descendant {pid} exited and next run succeeded.')

# Schedule generation omits launchctl from PATH to avoid system mutations.
# Its saved ProgramArguments/EnvironmentVariables are then executed for real.
def schedule():
    shim=LAB/'schedule-bin';shim.mkdir()
    for name in ('bash','dirname','sed','cksum','mkdir','cat','id','python3','date','mktemp','rm','cut','shasum','awk','sort','mv'):
        target=shutil.which(name);assert target,name;(shim/name).symlink_to(target)
    # No launchctl on PATH: installation emits a plist without registration.
    h=home('scheduled & home','interval_seconds = 1\n')
    other=home('scheduled-other')
    env=dict(BASE_ENV,FM_HOME=str(h),PATH=str(shim),HOME=str(LAB/'schedule-user'))
    assert run([SCRIPT,'install'],env).returncode==0
    assert run([SCRIPT,'install'],dict(env,FM_HOME=str(other))).returncode==0
    files=list((LAB/'schedule-user/Library/LaunchAgents').glob('*.plist'));assert len(files)==2
    plists=[plistlib.loads(p.read_bytes()) for p in files]
    spec=next(d for d in plists if d['EnvironmentVariables']['FM_HOME']==str(h))
    assert spec['StartInterval']==1200 and spec['EnvironmentVariables']['HOME']==env['HOME']
    assert len({d['Label'] for d in plists})==2
    scheduled_env=spec['EnvironmentVariables']
    assert run(spec['ProgramArguments'],scheduled_env).returncode==0
    assert (h/'data/goal-digest/latest.json').is_file()
    keep(h,'scheduled-first-digest')
    for p in files:shutil.copyfile(p,EVID/p.name)
    say('Generated plist parsed; fixed StartInterval=1200, two home-scoped labels, escaped home path, and declared clean environment executed the real digest successfully. No LaunchAgent registered.')
    assert run([SCRIPT,'uninstall'],env).returncode==0
    assert run([SCRIPT,'uninstall'],dict(env,FM_HOME=str(other))).returncode==0
    assert not list((LAB/'schedule-user/Library/LaunchAgents').glob('*.plist'))

try:
    scenario('Generate local CST digest with explicit owner holds, ETA/stall/review records and cached coverage transitions',local_owner)
    scenario('Real gh CLI against synthetic local Unix-socket API: paginate PRs, report new merge once, discard partial fetch and recover',network_prs)
    scenario('Run real local summarizer only for content changes and preserve every review-ledger entry',changed_summary)
    scenario('Reject failed archival without consuming notifications and publish complete JSON to concurrent readers',publication)
    scenario('Reject concurrent run, recover after killed owner, and terminate network and summarizer descendants at deadlines',concurrency_timeout)
    scenario('Generate home-scoped 20-minute LaunchAgent configuration and execute its declared environment locally',schedule)
finally:
    for group in extra_groups:
        try:os.killpg(group,signal.SIGKILL)
        except ProcessLookupError:pass
    for p in owned:
        try:os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        if p.poll() is None:p.wait()
    server.shutdown();server.server_close();thread.join();pathlib.Path(socket_path).unlink(missing_ok=True)
    (EVID/'api-requests.json').write_text(json.dumps(requests,indent=2))
    (EVID/'live-results.json').write_text(json.dumps(results,indent=2))
    log.close()
