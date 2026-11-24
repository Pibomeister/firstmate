import contextlib
import datetime as dt
import fcntl
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess as sp
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

ROOT = Path.cwd()
E = Path('~/.no-mistakes/evidence/01M85WPJHSW42PYT79RQP58A6K/round7-test')
W = ROOT / '.test-goal-digest-phase/live'
W.mkdir(parents=True, exist_ok=True)
SCRIPT = ROOT / 'bin/fm-goal-digest.sh'
GH = shutil.which('gh')
CLAUDE = shutil.which('claude')
now = int(time.time())
stamp = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
results = []
requests = []
closed = []
opened = []
fail_page = None

class API(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = parse_qs(urlsplit(self.path).query)
        state, page = q['state'][0], int(q['page'][0])
        requests.append({'method': 'GET', 'path': self.path, 'state': state, 'page': page})
        if state == 'closed' and page == fail_page:
            self.send_response(503); self.end_headers(); self.wfile.write(b'{}'); return
        rows = closed if state == 'closed' else opened
        data = json.dumps(rows[(page-1)*100:page*100]).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
thread = threading.Thread(target=server.serve_forever)
thread.start()
adapter = W / 'gh-local'
adapter.write_text('#!/usr/bin/env python3\nimport os,sys\nassert sys.argv[1] == "api" and len(sys.argv) == 3\nos.execv(' + repr(GH) + ', [' + repr(GH) + ', "api", ' + repr('http://127.0.0.1:%s/' % server.server_port) + ' + sys.argv[2]])\n')
adapter.chmod(0o755)
env = dict(os.environ, FM_TEST_SEAM='1', FM_GOAL_DIGEST_GH=str(adapter), GH_TOKEN='synthetic-local-only', GH_CONFIG_DIR=str(W/'gh-config'))
for key in ('FM_GOAL_DIGEST_CLAUDE', 'GH_HOST', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN'):
    env.pop(key, None)
home = W / 'home'
(home/'config').mkdir(parents=True)
out = home/'data/goal-digest'
status = home/'snapshot.json'
review = home/'review.txt'
eta = home/'eta.txt'
snapshot = {'schema':'fm-fleet-snapshot.v1', 'generated_at':stamp(now-86400),
    'backlog':{'present':True,'records':[
        {'id':'dated','title':'Choose route','captain_actionable':True,'hold_set':'2020-01-01','hold_age_days':2},
        {'id':'hour','title':'Choose date','captain_actionable':True,'hold_set':stamp(now-3*3600)},
        {'id':'done','title':'Answered','captain_actionable':False}]},
    'secondmate_current':{'registry':{'available':True,'complete':True},'truncated':0,'records':[
        {'id':'mate','registered':True,'provenance':{'selected':'structured-home','trust':'complete','summary_source':'remote-ledger'},
         'freshness':{'status':'fresh'},'current':{'state':'captain_decision'},'counts':{'decisions_open':1},'omitted':[],
         'decisions_open':[{'id':'route','verb':'captain-hold','question':'Choose branch'}]}]}}
status.write_text(json.dumps(snapshot))
review.write_text('T1: blocked\nT7: pending\nT5: complete\nT6b: pending\nT10: pending\nT8: complete\nAgentKit: review pending\n')
eta.write_text('eta: 2000-01-01 overdue\nbeta 2000-01-02 irrelevant\neta: 2099-01-01 future\n')
os.utime(eta,(now-72*3600,now-72*3600))
config = home/'config/goal-digest'
config.write_text(f'repo = synthetic/one\nstatus = Fleet | {status}\nreview = Tracks | {review}\nsummarize = off\n')

def save(name, d=None):
    (E/(name+'.json')).write_text(json.dumps(d if d is not None else json.loads((out/'latest.json').read_text()), indent=2)+'\n')
    if (out/'latest.md').exists(): shutil.copyfile(out/'latest.md', E/(name+'.md'))

def run(name, expected=0, extra=None, cwd=W):
    v = dict(env, FM_HOME=str(home))
    if extra: v.update(extra)
    r = sp.run([str(SCRIPT),'run'],env=v,cwd=cwd,text=True,capture_output=True,timeout=180)
    with (E/'live-transcript.log').open('a') as log:
        log.write(f'\n[{name}] {SCRIPT} run\nexit={r.returncode}\n{r.stdout}{r.stderr}')
    assert (r.returncode == 0) == (expected == 0), (name,r)
    return json.loads((out/'latest.json').read_text()) if r.returncode == 0 else r

def passed(name, evidence):
    results.append({'name':name,'result':'pass','live':True,'evidence':evidence,'reason':'Real digest executable in a private home; synthetic inputs only. GitHub traffic uses the real gh CLI against a localhost HTTP API emulator.'})
    print('PASS:',name,flush=True)

try:
    # Oracle: each new merge appears exactly once, including a record after page 10.
    opened[:] = [{'number':7,'title':'Contributor draft','created_at':stamp(now-24*3600),'draft':True,'html_url':'https://example.invalid/pr/7','user':{'login':'synthetic'}}]
    closed[:] = [{'number':1,'title':'First merge','merged_at':stamp(now-3600),'updated_at':stamp(now-3600),'html_url':'https://example.invalid/pr/1','merge_commit_sha':'a'*40}]
    d=run('first'); assert [m['number'] for m in d['new_merges']] == [1] and d['changed']
    save('first-digest',d)
    d=run('unchanged'); assert not d['new_merges'] and not d['changed']
    closed[:] = [{'number':i,'updated_at':stamp(now-i),'merged_at':None} for i in range(2,1002)]
    closed.append({'number':1002,'title':'Page eleven merge','updated_at':stamp(now-1500),'merged_at':stamp(now-1600),'html_url':'https://example.invalid/pr/1002','merge_commit_sha':'b'*40})
    # Simulate an outage: the durable last-complete window is two hours old.
    (out/'.state/since.tsv').write_text(f'synthetic/one\t{now-7200}\n')
    fail_page=2
    before=(out/'.state/since.tsv').read_bytes()
    d=run('page-failure'); assert not d['new_merges'] and d['unreachable_sources']
    assert (out/'.state/since.tsv').read_bytes() == before
    fail_page=None; requests.clear()
    d=run('page-recovery'); assert [m['number'] for m in d['new_merges']] == [1002]
    assert [r['page'] for r in requests if r['state']=='closed'] == list(range(1,12))
    save('page-eleven-recovery',d)
    assert not run('deduplicated')['new_merges']
    passed('Local GitHub CLI collects incremental merges through page 11 and recovers a failed page without losing or repeating merges','page-eleven-recovery.json; live-transcript.log; github-http-requests.json')

    # Independent calendar oracle from the current Mexico City date, not the snapshot age.
    from zoneinfo import ZoneInfo
    expected_days=(dt.datetime.now(ZoneInfo('America/Mexico_City')).date()-dt.date(2020,1,1)).days
    waiting=d['waiting_on_captain']; assert {w['id'] for w in waiting} == {'dated','hour','route'}
    assert next(w for w in waiting if w['id']=='dated')['age_days']==expected_days
    assert next(w for w in waiting if w['id']=='hour')['age_hours']==3
    assert next(w for w in waiting if w['id']=='route')['age_hours'] is None
    assert d['waiting_on_captain_status']=='known' and len(d['open_pull_requests'])==1
    snapshot['secondmate_current']['records'][0]['freshness']['status']='cached'
    status.write_text(json.dumps(snapshot)); d=run('cached-mate')
    assert d['waiting_on_captain_status']=='unknown' and d['changed']
    save('owner-actions-cached',d)
    snapshot['secondmate_current']['records'][0]['freshness']['status']='fresh'
    snapshot['backlog']['records'][0]['captain_actionable']=False
    status.write_text(json.dumps(snapshot)); d=run('resolved-hold')
    assert 'dated' not in {w['id'] for w in d['waiting_on_captain']} and d['waiting_on_captain_status']=='known'
    passed('Local native snapshots distinguish owner holds from drafts, age delayed date-only holds today, disclose cached decisions, and remove resolved holds','owner-actions-cached.json; live-transcript.log')

    config.write_text(config.read_text()+f'status = ETA | {eta}\nstatus = Unreachable | {home}/absent\n')
    d=run('eta-stall-reviews'); assert '-0600 CST' in d['generated_at_local']
    assert [m['eta'] for m in d['missed_etas']]==['2000-01-01']
    assert {s['source'] for s in d['stalls']}=={'ETA'}
    assert len(d['review_convergence'][0]['entries'])==7
    review.write_text(review.read_text().replace('T1: blocked','T1: complete'))
    d=run('early-review-change'); assert d['changed'] and d['review_convergence'][0]['entries'][0]=='T1: complete'
    save('status-and-reviews',d)
    assert list((out/'history').glob('*.md')) and list((out/'history').glob('*.json'))
    passed('Local status files publish CST time, missed ETAs, stalls, unreachable sources, all review tracks, and retained digest history','status-and-reviews.md; status-and-reviews.json')

    # Force the real filesystem archive consumer to fail, without mocks.
    old=(out/'latest.json').read_bytes()
    states={p.name:p.read_bytes() for p in (out/'.state').iterdir() if p.name in ('seen.tsv','since.tsv','content.hash')}
    shutil.rmtree(out/'history'); (out/'history').write_text('blocked history path')
    review.write_text('T1: archive pending\n')
    run('archive-refusal',expected=1)
    assert (out/'latest.json').read_bytes()==old
    assert all((out/'.state'/k).read_bytes()==v for k,v in states.items())
    (out/'history').unlink(); (out/'history').mkdir()
    d=run('archive-recovery'); assert d['changed'] and d['review_convergence'][0]['entries']==['T1: archive pending']
    save('archive-recovery',d)
    passed('A local archive failure preserves the published digest and notification state; the next run recovers','live-transcript.log; archive-recovery.json')

    with (out/'.state/run.flock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        r=run('concurrent-refusal',expected=1); assert 'another run is in progress' in r.stderr
    d=run('lock-release'); assert not d['changed']
    passed('A competing local digest is refused while the kernel lock is held and succeeds after release','live-transcript.log')

    config.write_text(config.read_text().replace('summarize = off','summarize = on')+f'summarize_model = opus\nsummarize_cmd = touch {home}/should-not-exist\n')
    review.write_text('T1: model guard\n'); d=run('cheap-model-guard')
    assert not (home/'should-not-exist').exists() and not (out/'summary.txt').exists()
    assert all(r['method']=='GET' for r in requests)
    passed('The local digest rejects an Opus summary model and ignores a shell-command config entry while collection remains read-only','live-transcript.log; github-http-requests.json')

    # Render install through a local launchctl recorder. This does not claim native launchd execution.
    fake=W/'install-bin'; fake.mkdir()
    recorder=fake/'launchctl'
    recorder.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FM_INSTALL_RECORD"\n')
    recorder.chmod(0o755)
    private_home=W/'install-home'; private_home.mkdir()
    install_env=dict(env,FM_HOME=str(home),HOME=str(private_home),PATH=str(fake)+os.pathsep+os.environ['PATH'],FM_INSTALL_RECORD=str(W/'install.log'))
    r=sp.run([str(SCRIPT),'install'],env=install_env,text=True,capture_output=True); assert r.returncode==0,r
    plist=next((private_home/'Library/LaunchAgents').glob('*.plist'))
    spec=plistlib.loads(plist.read_bytes()); assert spec['StartInterval']==1200 and spec['EnvironmentVariables']['FM_HOME']==str(home)
    shutil.copyfile(plist,E/'rendered-launchagent.plist')
    config.write_text('\n'.join(line for line in config.read_text().replace('summarize = on','summarize = off').splitlines() if not line.startswith('repo ='))+'\n')
    r=sp.run(spec['ProgramArguments'],env=spec['EnvironmentVariables'],text=True,capture_output=True); assert r.returncode==0,r
    (E/'rendered-agent-invocation.log').write_text(r.stdout+r.stderr+'exit='+str(r.returncode)+'\n')
    r=sp.run([str(SCRIPT),'uninstall'],env=install_env,text=True,capture_output=True); assert r.returncode==0 and not plist.exists()
    shutil.copyfile(W/'install.log',E/'install-recorder.log')
    passed('The generated local LaunchAgent has a 1200-second cadence and its declared command/environment executes the digest','rendered-launchagent.plist; rendered-agent-invocation.log; install-recorder.log')

    # Actual fixed native Claude invocation. The recorder forwards argv unchanged.
    native=W/'native-synthetic'; native.mkdir(exist_ok=True)
    (native/'config').mkdir(exist_ok=True)
    (native/'review.txt').write_text('Synthetic project: T1 complete; one owner decision: choose north or south. ETA: 2099-01-01.\n')
    (native/'config/goal-digest').write_text(f'review = Synthetic | {native}/review.txt\nsummarize_model = haiku\n')
    wrapper=W/'native-claude'
    wrapper.write_text('#!/usr/bin/env python3\nimport json,pathlib,subprocess,sys\ne=pathlib.Path('+repr(str(E))+')\n(e/"native-claude-argv.json").write_text(json.dumps(['+repr(CLAUDE)+']+sys.argv[1:]))\nprompt=sys.stdin.read()\n(e/"native-claude-input.txt").write_text(prompt)\nr=subprocess.run(['+repr(CLAUDE)+']+sys.argv[1:],input=prompt,text=True,capture_output=True)\n(e/"native-claude-result.json").write_text(json.dumps({"exit":r.returncode,"stdout":r.stdout,"stderr":r.stderr},indent=2))\nsys.stdout.write(r.stdout);sys.stderr.write(r.stderr);sys.exit(r.returncode)\n')
    wrapper.chmod(0o755)
    r=sp.run([str(SCRIPT),'run'],cwd=native,env=dict(os.environ,FM_HOME=str(native),FM_TEST_SEAM='1',FM_GOAL_DIGEST_CLAUDE=str(wrapper)),text=True,capture_output=True,timeout=150)
    (E/'native-digest-run.log').write_text(r.stdout+r.stderr+'exit='+str(r.returncode)+'\n')
    result=json.loads((E/'native-claude-result.json').read_text()) if (E/'native-claude-result.json').exists() else None
    summary=native/'data/goal-digest/summary.txt'
    if r.returncode==0 and result and result['exit']==0 and summary.exists() and summary.read_text().strip():
        shutil.copyfile(summary,E/'native-summary.txt')
        results.append({'name':'A synthetic changed digest receives a nonempty summary from the actual fixed text-only native Claude haiku runner','result':'pass','live':True,'evidence':'native-claude-argv.json; native-claude-result.json; native-digest-run.log; native-summary.txt','reason':'Actual installed Claude CLI and existing account; argv forwarded unchanged, no tools or settings enabled. Text mode does not expose served-model metadata.'})
    else:
        results.append({'name':'A synthetic changed digest receives a summary from the actual fixed text-only native Claude haiku runner','result':'fail','live':True,'evidence':'native-claude-argv.json; native-digest-run.log','reason':'Actual fixed runner attempted with the normal native account; see retained exact exit/refusal. No account changes, model substitutions, or contract weakening were attempted.'})
    print('NATIVE:',json.dumps(results[-1]),flush=True)
    for name in ('latest.json','latest.md'):
        shutil.copyfile(native/'data/goal-digest'/name,E/('native-'+name))
    if results[-1]['result']=='pass':
        before=(E/'native-claude-result.json').stat().st_mtime_ns
        again=sp.run([str(SCRIPT),'run'],cwd=native,env=dict(os.environ,FM_HOME=str(native),FM_TEST_SEAM='1',FM_GOAL_DIGEST_CLAUDE=str(wrapper)),text=True,capture_output=True,timeout=150)
        (E/'native-unchanged.log').write_text(again.stdout+again.stderr+'exit='+str(again.returncode)+'\n')
        assert again.returncode==0 and 'changed=no' in again.stdout
        assert (E/'native-claude-result.json').stat().st_mtime_ns==before


    rule='Do not modify system state outside the worktree. In particular, do not install or upgrade system packages ... and do not change global or user-level tool configuration.'
    (E/'native-launchd-boundary.txt').write_text('Native registration not executed.\nWorkspace boundary: '+rule+'\nRecorded test fix instruction: If native phase rules prohibit registration, preserve the exact rule/refusal and return no-go without a policy bypass or another run.\nA workspace-local plist and recorder prove rendering and command execution only. Actual launchctl bootstrap changes the per-user launchd domain outside this worktree. A phase-specific authorization permitting an owned temporary launchd job, its execution, and cleanup is required to perform this criterion.\n')
    results.append({'name':'Native macOS launchd registers the owned recurring job, fires the digest, and removes the temporary registration','result':'untested','live':False,'evidence':'native-launchd-boundary.txt; rendered-launchagent.plist','reason':'The current workspace boundary prohibits changing system state outside the worktree. Local rendering and executing the generated command were driven, but neither can prove launchd registration or firing. The recorded fix instruction requires no-go under this exact restriction. Provide phase-specific authority for temporary native launchd registration, execution, and cleanup.'})
finally:
    server.shutdown(); server.server_close(); thread.join()
    (E/'github-http-requests.json').write_text(json.dumps(requests,indent=2)+'\n')
    (E/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    print('HTTP server stopped; completed scenarios:',len(results),flush=True)
