#!/usr/bin/env python3
"""Run actual Firstmate, Orca CLI, gh and gh-axi against disposable local protocol endpoints.
Oracle: overflow cannot prove absence or authorize mutations; complete inventories can.
The endpoint data are synthetic, not operator fleet or GitHub validation.
"""
import json, os, pathlib, socketserver, http.server, ssl, subprocess, threading, re, time, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M87EAG2SQWQNV3FGB93ETHV4')
W=ROOT/'.v'
W.mkdir(exist_ok=True); W.chmod(0o700)
LOG=(E/'live-transcript.log').open('w',buffering=1)
RPC=(E/'local-endpoint-requests.jsonl').open('w',buffering=1)
state={'truncated':True,'count':200,'total':211,'labels':[],'prs':[],'calls':[]}
def note(x): print(x,flush=True); LOG.write(str(x)+'\n')
def run(args,env=None,cwd=ROOT,check=False):
    p=subprocess.run([str(a) for a in args],env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
    note('$ '+' '.join(str(a) for a in args)); note('exit='+str(p.returncode)); note(p.stdout.rstrip()); note(p.stderr.rstrip())
    if check and p.returncode: raise RuntimeError('command failed')
    return p
base=dict(os.environ)
for k in list(base):
    if k.startswith(('FM_','ORCA_','GH_','GITHUB_','TASKS_AXI_')) or k in ['GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','TMUX']: base.pop(k,None)
base.update(FM_ORCA_CLI_CACHE='0',FM_DISK_ALARM_VOLUME='/nonexistent/fm-enumeration-lab',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(W),GH_CONFIG_DIR=str(W/'gh'),GH_TOKEN='synthetic-local-token',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',NO_COLOR='1',ORCA_USER_DATA_PATH=str(W/'orca'))
(W/'orca').mkdir(exist_ok=True)
(W/'orca/orca-runtime.json').write_text(json.dumps({'runtimeId':'enum-lab','authToken':'synthetic-local-token','transports':[{'kind':'unix','endpoint':str(W/'s')}]}))
class UnixServer(socketserver.ThreadingUnixStreamServer): daemon_threads=True
class OrcaHandler(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            q=json.loads(line); method=q['method']; RPC.write(json.dumps({'kind':'orca','method':method,'params':q.get('params')})+'\n')
            if method=='status.get': result={'runtimeId':'enum-lab','hostDescriptor':{'installationId':'enum-lab'}}
            elif 'list' in method.lower() and 'terminal' in method.lower():
                terms=[{'handle':'term-'+str(i),'title':'T'+str(i),'lastOutputAt':int(time.time()*1000),'worktreePath':str(W/'foreign')} for i in range(state['count'])]
                if not state['truncated'] and state['count']==211: terms[-1].update(handle='term-captain',title='captain')
                result={'terminals':terms,'truncated':state['truncated'],'totalCount':state['total']}
            elif 'read' in method.lower() and 'terminal' in method.lower(): result={'terminal':{'tail':'❯ ','draft':''}}
            elif 'memory' in method.lower(): result={'worktrees':[]}
            elif 'list' in method.lower() and ('worktree' in method.lower() or 'workspace' in method.lower()): result={'worktrees':[],'truncated':state['truncated']}
            else:
                self.wfile.write((json.dumps({'id':q['id'],'ok':False,'error':{'code':'unsupported_lab_call','message':method},'_meta':{'runtimeId':'enum-lab'}})+'\n').encode()); continue
            self.wfile.write((json.dumps({'id':q['id'],'ok':True,'result':result,'_meta':{'runtimeId':'enum-lab'}})+'\n').encode())
servers=[]; threads=[]
def start(s):
    t=threading.Thread(target=s.serve_forever,daemon=True); t.start(); servers.append(s); threads.append(t)
try:
    if (W/'s').exists(): (W/'s').unlink()
    start(UnixServer(str(W/'s'),OrcaHandler))
    p=run(['orca','terminal','list','--limit','200','--json'],base)
    if p.returncode: raise RuntimeError('Orca CLI local endpoint not usable')
    home=W/'nudge'; (home/'state').mkdir(parents=True,exist_ok=True)
    cfg={'schema':'fm-captain-nudge.v1','host':'local-enum-lab','state_dir':str(home/'state'),'jsonl_log':str(home/'events.jsonl'),'beacon_log':str(home/'beacon.log'),'mode':'dry-run','captains':[{'id':'alpha','owner':'firstmate','backend':'orca','handle':'term-captain'}]}
    (home/'config.json').write_text(json.dumps(cfg))
    for trunc,total,count,expected in [(True,211,200,'skip_enumeration_incomplete'),(False,211,200,'skip_enumeration_incomplete'),(False,211,211,'skip_not_idle')]:
        state.update(truncated=trunc,total=total,count=count)
        p=run(['bash','bin/fm-captain-nudge.sh','once','--config',home/'config.json'],base)
        event=json.loads((home/'events.jsonl').read_text().splitlines()[-1]); note(json.dumps(event))
        assert p.returncode==0 and event['event']==expected,(event,expected)
    note('SCENARIO PASS: local captain-nudge refuses truncated and total-mismatch inventories; complete 211-row list finds captain')
    state.update(truncated=True,total=211,count=200)
    rh=W/'reaper'; (rh/'state').mkdir(parents=True,exist_ok=True); (rh/'data').mkdir(exist_ok=True)
    p=run(['bash','bin/fm-terminal-reap.sh','--min-age','0','--no-browsers'],dict(base,FM_HOME=str(rh)))
    assert p.returncode==1 and 'enumeration incomplete' in p.stderr and not p.stdout
    note('SCENARIO PASS: local terminal-reap visibly refuses truncated inventory and closes nothing')
    lh=W/'lane-home'; (lh/'state').mkdir(parents=True,exist_ok=True); (lh/'projects').mkdir(exist_ok=True)
    repo=lh/'repo'; repo.mkdir(exist_ok=True)
    run(['git','init','-q','-b','main',repo],base,check=True)
    run(['git','-C',repo,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','base','--allow-empty'],base,check=True)
    run(['bash','bin/fm-lane-register.sh','enum-lane','--repo',repo,'--terminal','term-lane'],dict(base,FM_HOME=str(lh)),check=True)
    rec=lh/'state/external-lanes/enum-lane.lane'; before=rec.read_bytes()
    for mode in [[],['scan']]:
        p=run(['bash','bin/fm-worktree-cleanup.sh']+mode,dict(base,FM_HOME=str(lh)))
        visible=p.stdout if not mode else (lh/'state/worktree-cleanup.log').read_text()
        note(visible)
        assert p.returncode==0 and 'lane terminal term-lane inventory is unreadable or incomplete' in visible
        assert rec.read_bytes()==before
    state.update(truncated=False,count=0,total=0)
    p=run(['bash','bin/fm-worktree-cleanup.sh'],dict(base,FM_HOME=str(lh)))
    assert p.returncode==0 and 'forget lane enum-lane' in p.stdout and not rec.exists()
    note('SCENARIO PASS: local cleanup reports incomplete terminal inventory in direct and scan logs, preserves lane, then retires it only with complete absence proof')
    import runpy
    runpy.run_path(str(E/'github-live.py'),init_globals={'ORCA_PROFILE':str(W/'orca')})
except Exception as ex:
    note('LIVE DRIVER ERROR: '+repr(ex)); raise
finally:
    for s in servers: s.shutdown(); s.server_close()
    for t in threads: t.join(timeout=5)
    RPC.close(); LOG.close()
