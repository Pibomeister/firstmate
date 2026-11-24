"""Execute the real digest and gh against a disposable local HTTP API.

Oracles: the supplied goal-digest intent and the approved recovery decisions.
The API emulates GitHub's external boundary; the collector, gh, clock, locks,
filesystem, and configured summarizer are real processes. No vendor account.
"""
import copy
import datetime as dt
import fcntl
import http.server
import json
import os
import pathlib
import shlex
import shutil
import signal
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = pathlib.Path.cwd()
LAB = ROOT / '.test-goal-digest/live'
EVIDENCE = pathlib.Path(__file__).parent
SCRIPT = ROOT / 'bin/fm-goal-digest.sh'
LAB.mkdir(parents=True, exist_ok=True)
REQUESTS = []
RESULTS = []
STATE = {'rows': [], 'open': [], 'fail_page': None, 'delay': False}


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        page = int(query.get('page', ['1'])[0])
        state = query.get('state', ['closed'])[0]
        REQUESTS.append({'method': self.command, 'path': self.path})
        if STATE['delay']:
            time.sleep(2)
        if state == 'closed' and page == STATE['fail_page']:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b'{"message":"synthetic outage"}')
            return
        rows = STATE['rows'] if state == 'closed' else STATE['open']
        body = json.dumps(rows[(page-1)*100:page*100]).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def stamp(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


NOW = int(time.time())


def merged(number, epoch=NOW-60):
    return {'number': number, 'title': f'Synthetic merge {number}',
            'html_url': f'https://synthetic.invalid/demo/pull/{number}',
            'merge_commit_sha': ('a' if number == 1 else 'b')*40,
            'merged_at': stamp(epoch), 'updated_at': stamp(NOW),
            'created_at': stamp(NOW-86400)}


def home(name, config=''):
    path = LAB / name
    (path / 'config').mkdir(parents=True)
    if config:
        (path / 'config/goal-digest').write_text(config)
    return path


def run(path, name, ok=True):
    env = dict(ENV, FM_HOME=str(path))
    result = subprocess.run([str(SCRIPT), 'run'], env=env, capture_output=True, text=True, timeout=90)
    (EVIDENCE / (name+'.log')).write_text(f'$ FM_HOME=<isolated-{path.name}> bin/fm-goal-digest.sh run\nexit={result.returncode}\n'+result.stdout+result.stderr)
    print(name, 'exit', result.returncode, result.stdout.strip(), flush=True)
    assert (result.returncode == 0) == ok, result.stderr
    if ok:
        data = json.loads((path/'data/goal-digest/latest.json').read_text())
        shutil.copyfile(path/'data/goal-digest/latest.json', EVIDENCE/(name+'.json'))
        shutil.copyfile(path/'data/goal-digest/latest.md', EVIDENCE/(name+'.md'))
        return data


def record(name, detail):
    RESULTS.append({'name': name, 'result': 'pass', 'live': True, 'detail': detail})
    print('PASS:', name, detail, flush=True)


def wait_file(path, proc=None):
    deadline = time.monotonic()+30
    while not path.exists() and time.monotonic() < deadline:
        if proc and proc.poll() is not None:
            break
        time.sleep(.05)
    assert path.exists(), str(path)


sock = '.test-goal-digest/digest-api.sock'
configdir = LAB/'gh-config'
configdir.mkdir()
(configdir/'config.yml').write_text('http_unix_socket: '+sock+'\n')
# Documented gh transport setting: https://cli.github.com/manual/gh_config
ENV = dict(os.environ, GH_HOST='synthetic.invalid', GH_ENTERPRISE_TOKEN='synthetic-only',
           GH_CONFIG_DIR=str(configdir), GH_NO_UPDATE_NOTIFIER='1',
           GH_NO_EXTENSION_UPDATE_NOTIFIER='1', GH_PROMPT_DISABLED='1')
for key in ('FM_TEST_SEAM', 'FM_GOAL_DIGEST_GH', 'GH_TOKEN', 'GITHUB_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
    ENV.pop(key, None)
server = Server(sock, Handler)
thread = threading.Thread(target=server.serve_forever)
thread.start()
try:
    status_home = home('main')
    snapshot = {'schema':'fm-fleet-snapshot.v1',
                'backlog':{'present':True,'records':[
                    {'id':'route','title':'Choose route','captain_actionable':True,'hold_set':stamp(NOW-7200)},
                    {'id':'done','title':'Answered','captain_actionable':False}]},
                'secondmate_current':{'registry':{'available':True,'complete':True},'records':[
                    {'id':'mate-a','registered':True,
                     'provenance':{'selected':'structured-home','trust':'complete','summary_source':'remote-ledger'},
                     'freshness':{'status':'fresh'},'current':{'state':'captain_decision'},
                     'decisions_open':[{'id':'deploy-choice','verb':'captain-hold','question':'Choose a date'}]}]}}
    (status_home/'status.json').write_text(json.dumps(snapshot))
    (status_home/'progress.txt').write_text('eta: 2020-01-01 deliver\nETA: 2099-12-31 future\nbeta 2020-01-01 unrelated\n')
    os.utime(status_home/'progress.txt', (NOW-259200, NOW-259200))
    ledger = ['T1: blocked','T7: pending','T5: complete','T6b: pending','T10: pending','T8: complete','AgentKit: review round 2']
    (status_home/'review.txt').write_text('\n'.join(ledger)+'\n')
    summary = status_home/'summarize.py'
    summary.write_text('import pathlib,sys\nhome=pathlib.Path(sys.argv[1])\ntext=sys.stdin.read()\nwith (home/"summary-calls").open("a") as f:f.write("called\\n")\nprint("Summary of",len(text),"bytes")\n')
    (status_home/'config/goal-digest').write_text(
        'repo = synthetic/demo\n'+
        f'status = Fleet | {status_home}/status.json\nstatus = Progress | {status_home}/progress.txt\n'+
        f'review = Reviews | {status_home}/review.txt\n'+
        'summarize_cmd = '+shlex.join([sys.executable,str(summary),str(status_home)])+'\n')
    STATE['rows'] = [merged(1),merged(9,NOW-172800)]
    STATE['open'] = [{'number':7,'title':'Contributor draft','html_url':'https://synthetic.invalid/demo/pull/7',
                      'created_at':stamp(NOW-10800),'user':{'login':'synthetic-author'},'draft':True}]
    first = run(status_home,'01-first-digest')
    assert first['changed'] is True
    assert [m['number'] for m in first['new_merges']] == [1]
    assert first['new_merges'][0]['sha'] == 'a'*12
    assert first['new_merges'][0]['url'].endswith('/1')
    assert '-0600 CST' in first['generated_at_local']
    waits = {w['id']:w for w in first['waiting_on_captain']}
    assert set(waits) == {'route','deploy-choice'} and waits['route']['age_hours'] == 2
    assert waits['deploy-choice']['age_hours'] is None
    assert first['open_pull_requests'][0]['draft'] is True
    assert [m['eta'] for m in first['missed_etas']] == ['2020-01-01']
    assert first['stalls'] == [{'source':'Progress','age_hours':72}]
    assert first['review_convergence'][0]['entries'] == ledger
    assert len(list((status_home/'data/goal-digest/history').glob('*.json'))) == 1
    empty = run(home('no-config'),'01-no-config')
    assert empty['waiting_on_captain_status'] == 'unknown'
    record('Local synthetic digest publishes required fields and defaults', 'Real collector, gh and clock; CST, merges, owner waits, ETAs, stalls, ledgers and history inspected.')

    second = run(status_home,'02-unchanged')
    assert second['changed'] is False and second['new_merges'] == []
    assert (status_home/'summary-calls').read_text().splitlines() == ['called']
    ledger[0]='T1: complete'
    (status_home/'review.txt').write_text('\n'.join(ledger)+'\n')
    STATE['rows'].insert(0,merged(2))
    third = run(status_home,'02-new-merge-review')
    assert third['changed'] and [m['number'] for m in third['new_merges']] == [2]
    assert third['review_convergence'][0]['entries'][0] == 'T1: complete'
    assert len((status_home/'summary-calls').read_text().splitlines()) == 2
    previous_summary=(status_home/'data/goal-digest/summary.txt').read_bytes()
    summary.write_text('import sys\nsys.exit(4)\n')
    ledger[0]='T1: pending'
    (status_home/'review.txt').write_text('\n'.join(ledger)+'\n')
    run(status_home,'02-failed-summary')
    assert (status_home/'data/goal-digest/summary.txt').read_bytes() == previous_summary
    record('Unchanged run skips summary; new content triggers it; failed summary preserves output', 'Call ledger, deduplicated merges, early review entry and preserved summary checked.')

    snapshot['secondmate_current']['records'][0]['freshness']['status']='cached'
    (status_home/'status.json').write_text(json.dumps(snapshot))
    cached=run(status_home,'03-cached-coverage')
    assert cached['changed'] and any('cached' in u['detail'] for u in cached['waiting_on_captain_unknown_sources'])
    assert len(cached['waiting_on_captain']) == 2
    (status_home/'status.json').unlink()
    missing=run(status_home,'03-missing-source')
    assert missing['changed'] and any(u['source']=='Fleet' for u in missing['unreachable_sources'])
    assert missing['waiting_on_captain_status']=='unknown'
    record('Cached or unreachable local snapshot discloses unknown owner coverage', 'Cached holds retained with warning; missing source reported without aborting publication.')

    STATE['open']=[]
    for mode in ('resumed','bootstrap-truncated','bootstrap-failed'):
        h=home(mode,'repo = synthetic/demo\n')
        out=h/'data/goal-digest'
        STATE['rows']=[]
        if mode=='resumed':
            run(h,'04-resumed-baseline')
            # Persisted state is an owned public contract. Simulate an outage.
            (out/'.state/since.tsv').write_text(f'synthetic/demo\t{NOW-172800}\n')
        STATE['rows']=[{'number':i,'merged_at':None,'updated_at':stamp(NOW-10)} for i in range(1,1001)]
        STATE['rows'][0]=merged(1)
        late=merged(1001,NOW-43200)
        STATE['rows'].append(late)
        STATE['fail_page']=2 if mode=='bootstrap-failed' else None
        incomplete=run(h,'04-'+mode+'-incomplete')
        baseline=(out/'.state/since.tsv').read_bytes()
        assert any(u['kind']=='repo' for u in incomplete['unreachable_sources'])
        assert 1001 not in [m['number'] for m in incomplete['new_merges']]
        STATE['fail_page']=None
        STATE['rows']=[late]+STATE['rows'][:-1]
        recovered=run(h,'04-'+mode+'-retry')
        assert [m['number'] for m in recovered['new_merges']].count(1001)==1
        assert (out/'.state/since.tsv').read_bytes()==baseline
        STATE['rows']=[late]
        complete=run(h,'04-'+mode+'-complete')
        assert complete['new_merges']==[] and not complete['unreachable_sources']
        assert int((out/'.state/since.tsv').read_text().split('\t')[1])>=NOW-300
    record('Real gh pagination preserves unreported merges after cap or failed page', 'Resumed and first-fetch outages retain watermark; omitted merge recovered exactly once; complete fetch advances window.')

    STATE['rows']=[]
    h=home('archive','repo = synthetic/demo\n')
    run(h,'05-archive-baseline')
    out=h/'data/goal-digest'
    before={n:(out/n).read_bytes() for n in ('latest.json','latest.md','.state/seen.tsv','.state/since.tsv','.state/content.hash')}
    shutil.rmtree(out/'history')
    (out/'history').symlink_to('/dev/null')
    STATE['rows']=[merged(2)]
    run(h,'05-archive-failure',ok=False)
    assert all((out/n).read_bytes()==v for n,v in before.items())
    (out/'history').unlink();(out/'history').mkdir()
    recovered=run(h,'05-archive-retry')
    assert [m['number'] for m in recovered['new_merges']]==[2]
    record('Archive failure preserves published documents and notification state', 'Real filesystem refusal returns nonzero; previous files and state intact; retry reports the merge.')

    # The checked-in focused regression itself executes real competing processes,
    # real fcntl locks, SIGKILL and delayed writes; retain its transcript separately.
    STATE['rows']=[]
    h=home('locks')
    review=h/'review';review.write_text('pending\n')
    helper=h/'summary.py'
    helper.write_text('import os,pathlib,sys,time\nh=pathlib.Path(sys.argv[1])\nif sys.argv[2]=="old":\n print("old start",flush=True)\n (h/"ready").write_text(str(os.getpid()))\n while not (h/"release").exists():time.sleep(.05)\n print("old delayed write",flush=True)\n (h/"done").touch()\nelse:print("replacement summary",flush=True)\n')
    def configure(mode):
        (h/'config/goal-digest').write_text(f'review = Track | {review}\nsummarize_cmd = '+shlex.join([sys.executable,str(helper),str(h),mode])+'\n')
    configure('old')
    first=None;child=None;monitor=None;stop_monitor=threading.Event();read_errors=[]
    try:
        with (EVIDENCE/'06-killed-owner.log').open('w') as log:
            first=subprocess.Popen([str(SCRIPT),'run'],env=dict(ENV,FM_HOME=str(h)),stdout=log,stderr=log,start_new_session=True)
            wait_file(h/'ready',first);child=int((h/'ready').read_text())
            run(h,'06-concurrent-refused',ok=False)
            first.kill();first.wait()
            configure('new');review.write_text('complete\n')
            run(h,'06-replacement')
            replacement=(h/'data/goal-digest/summary.txt').read_bytes()
            (h/'release').touch();wait_file(h/'done')
            assert (h/'data/goal-digest/summary.txt').read_bytes()==replacement==b'replacement summary\n'
            # Continuously read public JSON while several real refreshes publish.
            def reader():
                while not stop_monitor.is_set():
                    try:json.loads((h/'data/goal-digest/latest.json').read_text())
                    except Exception as exc:read_errors.append(repr(exc))
                    time.sleep(.002)
            monitor=threading.Thread(target=reader);monitor.start()
            for index in range(3):
                review.write_text(f'round {index}\n');run(h,f'06-atomic-refresh-{index}')
            stop_monitor.set();monitor.join();assert not read_errors,read_errors
    finally:
        stop_monitor.set()
        if monitor:monitor.join()
        if first:
            try:os.killpg(first.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            first.wait()
        if child:
            try:os.kill(child,signal.SIGKILL)
            except ProcessLookupError:pass
    record('Concurrent and killed owners cannot corrupt replacement or partial JSON', 'Active lock rejects overlap; SIGKILL releases it; orphan delayed write leaves replacement unchanged; concurrent JSON readers observe complete documents.')

    # Exercise real timeout with a real gh child and stalled local server.
    h=home('timeout','repo = synthetic/demo\ntimeout_seconds = 1\n')
    STATE['delay']=True
    before=time.monotonic();timeout_digest=run(h,'07-network-timeout');elapsed=time.monotonic()-before
    STATE['delay']=False
    assert len(timeout_digest['unreachable_sources'])==2 and elapsed<20,elapsed
    record('Stalled local API is bounded and publishes unavailable coverage', f'Real gh timed out for closed and open reads; collector finished in {elapsed:.1f}s.')
    assert all(r['method']=='GET' for r in REQUESTS)
    (EVIDENCE/'api-requests.json').write_text(json.dumps(REQUESTS,indent=2)+'\n')
finally:
    server.shutdown();server.server_close();thread.join()
    pathlib.Path(sock).unlink(missing_ok=True)
    (EVIDENCE/'live-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
