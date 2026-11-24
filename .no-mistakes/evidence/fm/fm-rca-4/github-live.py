#!/usr/bin/env python3
"""Actual gh/gh-axi plus Firstmate against a localhost HTTPS GitHub emulator.
Synthetic inventories test overflow refusals; no requests leave this process.
"""
import json,os,pathlib,subprocess,threading,http.server,ssl,re,time,socketserver
R=pathlib.Path.cwd(); W=R/'.v'; E=pathlib.Path('~/.no-mistakes/evidence/01M87EAG2SQWQNV3FGB93ETHV4')
L=(E/'github-live-transcript.log').open('w',buffering=1); Q=(E/'github-local-requests.jsonl').open('w',buffering=1)
S={'labels':[],'pulls':[],'prlimit':21,'mutations':[]}
def note(x): print(x,flush=True);L.write(str(x)+'\n')
def run(args,env=None,cwd=R,check=False):
 p=subprocess.run([str(x) for x in args],env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
 note('$ '+' '.join(str(x) for x in args)); note('exit='+str(p.returncode)); note(p.stdout.rstrip()); note(p.stderr.rstrip())
 if check and p.returncode: raise RuntimeError('command failed')
 return p
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*a): pass
 def do_CONNECT(self):
  if self.path not in ['api.github.com:443','github.com:443']:
   self.send_error(403);return
  self.send_response(200);self.end_headers()
  self.connection=ctx.wrap_socket(self.connection,server_side=True)
  self.rfile=self.connection.makefile('rb');self.wfile=self.connection.makefile('wb')
  self.close_connection=True
  self.handle_one_request()
 def reply(self,obj,status=200):
  data=json.dumps(obj).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_GET(self):
  Q.write(json.dumps({'method':'GET','path':self.path})+'\n')
  if '/pulls?' in self.path:
   self.reply(S['pulls'][:100])
  else:self.reply({'message':'unexpected local GET'},404)
 def do_PATCH(self): self.mutation()
 def do_PUT(self): self.mutation()
 def mutation(self):
  S['mutations'].append((self.command,self.path)); self.reply({'message':'unexpected local mutation'},409)
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}')
  Q.write(json.dumps({'method':'POST','path':self.path,'body':body})+'\n')
  if self.path!='/graphql':self.mutation();return
  query=body.get('query','');v=body.get('variables',{})
  repo={'id':'R_LAB','name':'firstmate','nameWithOwner':'Pibomeister/firstmate','owner':{'id':'O_LAB','login':'Pibomeister'},'hasIssuesEnabled':True,'isArchived':False,'isFork':False,'isPrivate':False,'url':'https://github.com/Pibomeister/firstmate','defaultBranchRef':{'name':'main'}}
  if 'labels(' in query:
   cursor=v.get('endCursor') or v.get('after') or ''; pos=int(cursor or 0)
   size=v.get('limit',v.get('first',100));size=min(int(size),100)
   rows=S['labels'][pos:pos+size];end=pos+len(rows)
   repo['labels']={'nodes':[{'id':'L_'+str(pos+i),'name':x,'color':'aaaaaa','description':''} for i,x in enumerate(rows)],'totalCount':len(S['labels']),'pageInfo':{'hasNextPage':end<len(S['labels']),'endCursor':str(end)}}
  if 'pullRequests(' in query:
   size=int(v.get('limit',20));nodes=[]
   for i in range(min(S['prlimit'],size)):
    nodes.append({'id':'P_'+str(i),'number':i+1,'state':'MERGED','headRefOid':S.get('head','0'*40),'url':'https://github.com/Pibomeister/firstmate/pull/'+str(i+1),'headRepositoryOwner':{'login':'Pibomeister'}})
   repo['pullRequests']={'nodes':nodes,'totalCount':S['prlimit'],'pageInfo':{'hasNextPage':len(nodes)<S['prlimit'],'endCursor':str(len(nodes))}}
  if 'mutation' in query:
   S['mutations'].append(('graphql',query));self.reply({'errors':[{'message':'mutations forbidden in local overflow scenario'}]});return
  self.reply({'data':{'repository':repo}})
if (W/'g').exists(): (W/'g').unlink()
server=socketserver.ThreadingUnixStreamServer(str(W/'g'),Handler); server.daemon_threads=True
(W/'gh').mkdir(exist_ok=True)
(W/'gh/config.yml').write_text('http_unix_socket: '+json.dumps(str(W/'g'))+'\n')
t=threading.Thread(target=server.serve_forever,daemon=True);t.start()
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','GH_','GITHUB_','TASKS_AXI_')) or k in ['GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR']:env.pop(k,None)
env.update(GH_CONFIG_DIR=str(W/'gh'),GH_TOKEN='synthetic-local-token',GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1',NO_PROXY='*',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(W),FM_DISK_ALARM_VOLUME='/nonexistent/fm-local-test')
if 'ORCA_PROFILE' in globals(): env.update(ORCA_USER_DATA_PATH=ORCA_PROFILE,FM_ORCA_CLI_CACHE='0')
try:
 S['labels']=['other-'+str(i) for i in range(500)]+['self-heal']
 p=run(['gh','label','list','--repo','Pibomeister/firstmate','--limit','500','--json','name','--jq','length'],env)
 assert p.returncode==0 and p.stdout.strip()=='500',p
 h=W/'label-home';(h/'config').mkdir(parents=True,exist_ok=True);(h/'code').mkdir(exist_ok=True)
 run(['git','init','-q',h/'code'],env,check=True);run(['git','-C',h/'code','remote','add','origin','https://github.com/Pibomeister/firstmate.git'],env,check=True)
 (h/'config/firstmate-role').write_text('maintainer github.com/pibomeister/firstmate\n')
 for name in ['self-heal','failure-class:demo']:
  S['labels']=(['self-heal'] if name!='self-heal' else [])+['other-'+str(i) for i in range(500)]+[name]
  p=run(['bash','bin/fm-self-heal-issue.sh','--repo','Pibomeister/firstmate','--failure-class','demo','--title','Synthetic enumeration lab'],dict(env,FM_HOME=str(h),FM_ROOT_OVERRIDE=str(h/'code')))
  assert p.returncode==1 and 'label enumeration incomplete; presence of '+name+' is unknown' in p.stderr
  assert not S['mutations']
 note('SCENARIO PASS: actual gh pagination reaches 500 labels; self-heal visibly refuses labels past the bound without mutations')
 h=W/'reconcile-home'; project=h/'projects/demo'
 for d in [project,h/'data',h/'state',h/'config']: d.mkdir(parents=True,exist_ok=True)
 (h/'data/projects.md').write_text('- demo [no-mistakes] - local enumeration lab\n')
 (h/'data/backlog.md').write_text('- [ ] task - local enumeration lab\n')
 run(['git','init','-q','-b','main',project],env,check=True)
 (project/'change.txt').write_text('base\n')
 run(['git','-C',project,'add','change.txt'],env,check=True)
 run(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','base'],env,check=True)
 run(['git','-C',project,'remote','add','origin','https://github.com/Pibomeister/firstmate.git'],env,check=True)
 run(['git','-C',project,'update-ref','refs/remotes/origin/main','HEAD'],env,check=True)
 run(['git','-C',project,'symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/main'],env,check=True)
 run(['git','-C',project,'checkout','-qb','fm/task'],env,check=True)
 (project/'change.txt').write_text('local change\n')
 run(['git','-C',project,'add','change.txt'],env,check=True)
 run(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','task'],env,check=True)
 head=run(['git','-C',project,'rev-parse','HEAD'],env,check=True).stdout.strip()
 (h/'state/task.meta').write_text('project='+str(project)+'\nbranch=fm/task\nkind=ship\nmode=no-mistakes\n')
 S['prlimit']=0
 S['pulls']=[{'merged_at':'2026-11-24T00:00:00Z','head':{'sha':'0'*39+'1'}} for i in range(100)]+[{'merged_at':'2026-11-24T00:00:00Z','head':{'sha':head}}]
 scanenv=dict(env,FM_HOME=str(h),FM_UNPUSHED_TIMEOUT_SECS='120',TASKS_AXI_FILE=str(h/'data/backlog.md'),TASKS_AXI_BACKEND='markdown')
 p=run(['bash','bin/fm-unpushed-reconcile.sh','scan'],scanenv)
 assert p.returncode==0 and 'branch=fm/task' in p.stdout and 'merged=unknown' in p.stdout
 S['pulls']=S['pulls'][-1:]
 p=run(['bash','bin/fm-unpushed-reconcile.sh','scan'],scanenv)
 assert p.returncode==0 and not p.stdout.strip(),p
 note('SCENARIO PASS: actual gh-axi/gh refuse closed-PR page with matching merged head at row 101; complete exact-head page proves landing')
 if 'ORCA_PROFILE' in globals():
  h=W/'prcleanup-home'; repo=h/'repo'; wt=h/'linked'
  for d in [repo,h/'state',h/'projects']:d.mkdir(parents=True,exist_ok=True)
  run(['git','init','-q','-b','main',repo],env,check=True)
  run(['git','-C',repo,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','base','--allow-empty'],env,check=True)
  run(['git','-C',repo,'remote','add','origin','https://github.com/Pibomeister/firstmate.git'],env,check=True)
  run(['git','-C',repo,'worktree','add','-qb','feature',wt],env,check=True)
  S['head']=run(['git','-C',repo,'rev-parse','HEAD'],env,check=True).stdout.strip();S['prlimit']=21
  p=run(['bash','bin/fm-worktree-cleanup.sh','--dry-run',repo],dict(env,FM_HOME=str(h)))
  assert p.returncode==0 and 'pull request lookup failed' in p.stdout and wt.is_dir(),p
  S['prlimit']=1
  p=run(['bash','bin/fm-worktree-cleanup.sh','--dry-run',repo],dict(env,FM_HOME=str(h)))
  assert p.returncode==0 and 'pull request MERGED' in p.stdout and 'dry-run' in p.stdout and wt.is_dir(),p
  note('SCENARIO PASS: actual gh 20-row PR list cannot authorize cleanup; complete merged-PR control reaches dry-run removal')
 assert not S['mutations']
except Exception as ex:
 note('LIVE DRIVER ERROR: '+repr(ex));raise
finally:
 server.shutdown();server.server_close();t.join(timeout=5);L.close();Q.close()
