import pathlib, os, subprocess, time, shutil, json, threading, http.server
root=pathlib.Path.cwd();ev=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN');scratch=root/('.test-live-retry-'+str(os.getpid()));lab=scratch/'home';project=scratch/'project'
scratch.mkdir(); log=(ev/'live-retry-harness-transcript.log').open('w',buffering=1);requests=[]
class H(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers.get('content-length') or 0)) or b'{}');requests.append({'path':self.path,'model':data.get('model')});
  if self.path=='/v1/systemone':code=200;payload={'model':'local-routing-oracle','answers':{'rule':{'type':'choice','choice':'rule_1','confidence':1,'probabilities':{'rule_1':1,'default':0}}},'usage':{'input_tokens':0,'output_tokens':0}}
  else:code=429;payload={'type':'error','error':{'type':'rate_limit_error','message':'Local disposable test endpoint refuses inference. No model tokens spent.'}}
  body=json.dumps(payload).encode();self.send_response(code);self.send_header('content-type','application/json');self.send_header('content-length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);thread=threading.Thread(target=server.serve_forever);thread.start()
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_','GIT_','ANTHROPIC_','CLAUDE_','TYPESAFE_','OPENROUTER_','OPENAI_','CODEX_')) or k in ['TMUX','TMUX_PANE','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK','CLAUDECODE']:env.pop(k,None)
env.update(FM_HOME=str(lab),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1',HOME=str(scratch/'user-home'),SHELL='/bin/bash',TREEHOUSE_ROOT=str(scratch/'pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid',CODEX_HOME=str(scratch/'codex-config'),CLAUDE_CONFIG_DIR=str(scratch/'claude-config'),ANTHROPIC_API_KEY='local-disposable-key-no-account',ANTHROPIC_BASE_URL=f'http://127.0.0.1:{server.server_port}',CLAUDE_CODE_SIMPLE='1',CLAUDE_CODE_MAX_RETRIES='0',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',DISABLE_AUTOUPDATER='1',FM_DISPATCH_PROVIDER='systemone',FM_DISPATCH_MODEL='local-routing-oracle',FM_DISPATCH_BASE_URL=f'http://127.0.0.1:{server.server_port}')
def run(args,expected=0,timeout=360):
 log.write('$ '+' '.join(map(str,args))+'\n');p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);log.write(p.stdout+f'EXIT {p.returncode}\n');assert p.returncode==expected,p.stdout;return p.stdout
def tm(*a):return run(['bash','bin/fm-lab-home.sh','tmux',lab,*a])
def meta(task):
 text=(lab/'state'/f'{task}.meta').read_text();log.write('PERSISTED TASK\n'+text);return dict(x.split('=',1) for x in text.splitlines() if '=' in x)
def brief(task,p,kind):
 d=lab/'data'/task;d.mkdir();(d/'brief.md').write_text('# Task\n## Captain\'s intent\nObserve this disposable local endpoint refusal. Do not edit files or make network calls.\n\n## Firstmate spec\nThis is a no-spend lifecycle proof.\n\n# Definition of done\nDelivery contract: mode=local-only\n');run(['tasks-axi','add',task,'Disposable local retry','--kind',kind,'--priority',str(p),'--file',lab/'data/backlog.md'])
try:
 pinned=root/'.test-codex-tool/node_modules/.bin';env['PATH']=str(pinned)+os.pathsep+env['PATH'];shell=scratch/'fixture-shell';shell.write_text('#!/bin/bash\nexport PATH='+str(pinned)+':\"$PATH\"\nexec /bin/bash --noprofile --norc \"$@\"\n');shell.chmod(0o755);env['SHELL']=str(shell);run([pinned/'codex','--version'])
 run(['bash','bin/fm-lab-home.sh','create',lab]);(scratch/'user-home').mkdir();cfg=scratch/'claude-config';cfg.mkdir();(cfg/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'dark','bypassPermissionsModeAccepted':True,'hasAcceptedBypassPermissionsMode':True,'customApiKeyResponses':{'approved':['local-disposable-key-no-account'[-20:]],'rejected':[]},'projects':{str(project):{'hasTrustDialogAccepted':True},str(root):{'hasTrustDialogAccepted':True},str(lab/'state/operational-inbox'):{'hasTrustDialogAccepted':True}}}))
 codexcfg=scratch/'codex-config';codexcfg.mkdir();(codexcfg/'config.toml').write_text('model_provider = \"local-test\"\nproject_doc_max_bytes = 0\n[model_providers.local-test]\nname = \"Local test\"\nbase_url = \"http://127.0.0.1:'+str(server.server_port)+'/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = false\nrequest_max_retries = 0\nstream_max_retries = 0\n')
 project.mkdir();run(['git','init','-q','-b','main',project]);(project/'README.md').write_text('Disposable retry lifecycle fixture.\n');run(['git','-C',project,'add','README.md']);run(['git','-C',project,'commit','-qm','Fixture']);run(['git','clone','--bare','-q',project,scratch/'origin.git']);run(['git','-C',project,'remote','add','origin',scratch/'origin.git']);run(['git','-C',project,'fetch','-q','origin']);run(['git','-C',project,'remote','set-head','origin','main'])
 (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n');(lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n');(lab/'config/crew-harness').write_text('codex\n');(lab/'config/crew-dispatch.json').write_text(json.dumps({'shared_quota':True,'rules':[{'when':'Disposable local retry check','use':{'harness':'codex'}}],'default':{'harness':'codex'}}));(lab/'state/.last-watcher-beat').touch()
 tm('new-session','-d','-s','proof','-n','primary','-x','120','-y','40','/bin/bash --noprofile --norc');tm('set-option','-g','default-shell','/bin/bash');tm('set-option','-g','default-command','/bin/bash --noprofile --norc');socket=(lab/'state/.fm-lab-tmux-dir').read_text().strip()+f'/tmux-{os.getuid()}/default';pid=tm('display-message','-p','#{pid}').strip();env['TMUX']=f'{socket},{pid},0'
 for p,kind,form in [(0,'ship','split'),(4,'scout','equals')]:
  task=f'retry-{p}';brief(task,p,kind);args=[task,str(project)]
  args+=['--priority',str(p)] if form=='split' else [f'--priority={p}'];args+=['--mode','local-only','--yolo','off'] if kind=='ship' else ['--scout'];args+=['--harness','codex']
  run(['bash','bin/fm-disk-retry.sh','record',task,*args]);assert (lab/'state/disk-refused'/task).exists()
  result=run(['bash','bin/fm-disk-retry.sh','scan'],timeout=600);assert f're-dispatched by bin/fm-spawn.sh: {task}' in result
  m=meta(task);assert m['priority']==str(p);assert m['harness']=='codex';assert not (lab/'state/disk-refused'/task).exists();(ev/f'retry-{p}.meta.txt').write_text((lab/'state'/f'{task}.meta').read_text());log.write('LIVE CODEX TERMINAL\n'+tm('capture-pane','-p','-t',m['window']))
 # Pin the original native process by the public raw-launch interface.
 brief('native-0',0,'ship')
 raw=str(pinned/'codex')+' --dangerously-bypass-approvals-and-sandbox --disable hooks'
 run(['bash','bin/fm-spawn.sh','native-0',project,raw,'--mode','local-only','--yolo','off','--priority','0'])
 # Verify a priority cannot be changed via relaunch before touching the live worker.
 run(['bash','bin/fm-spawn.sh','native-0','--relaunch','--priority','1'],expected=1)
 old=meta('native-0');oldgen=old['spawn_gen'];oldwork=old['worktree'];
 # Wait for the real TUI and its production composer consumer to report empty.
 deadline=time.monotonic()+360
 while True:
  pane=tm('capture-pane','-p','-t',old['window'])
  if 'Trust this folder?' in pane:
   tm('send-keys','-t',old['window'],'Enter');time.sleep(2);continue
  probe=subprocess.run(['bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux "$2"','_',str(root),old['window']],env=env,text=True,capture_output=True,timeout=30)
  log.write('COMPOSER '+probe.stdout.strip()+'\n')
  if probe.returncode==0 and probe.stdout.strip()=='empty':break
  if time.monotonic()>deadline:raise AssertionError('native Codex TUI did not reach an empty composer within the bounded setup window')
  time.sleep(2)
 log.write('READY TERMINAL\n'+pane)
 result=run(['bash','bin/fm-control.sh','native-0','relaunch','--note','Continue observing the local disposable refusal without editing files.'],timeout=600)
 new=meta('native-0');assert new['priority']=='0';assert new['worktree']==oldwork;assert new['window']==old['window'];assert new['spawn_gen']!=oldgen
 row=run(['tasks-axi','show','native-0','--file',lab/'data/backlog.md']);assert 'state: in_flight' in row and 'priority: 0' in row
 tx=(lab/'state/native-0.control-relaunch').read_text();assert 'phase=complete' in tx;(ev/'relaunch-transaction.txt').write_text(tx);(ev/'relaunch-before.meta.txt').write_text(json.dumps(old,indent=2));(ev/'relaunch-after.meta.txt').write_text(json.dumps(new,indent=2));log.write('AFTER RELAUNCH TERMINAL\n'+tm('capture-pane','-p','-t',new['window']))
 assert any(x['path']=='/v1/systemone' for x in requests)
 (ev/'live-retry-harness-result.json').write_text(json.dumps({'result':'pass','surface':'real retry, resolver, spawn, control, treehouse, tmux, workspace-local Codex 0.162.1 CLI against a localhost refusal endpoint and routing emulator; no production login or model execution','requests':requests},indent=2))
finally:
 try:tm('kill-server')
 except Exception as e:log.write('cleanup '+str(e)+'\n')
 # Reap native children from this exact disposable home before removing its files.
 def owned_table():
  rows={}
  for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,command='],text=True).splitlines():
   a=line.strip().split(None,3)
   if len(a)==4:rows[int(a[0])]=(int(a[1]),int(a[2]),a[3])
  return rows
 import signal
 rows=owned_table();native={p for p,(parent,pg,cmd) in rows.items() if (cmd.startswith('/opt/homebrew/lib/node_modules/@openai/codex/') or cmd.startswith(str(root/'.test-codex-tool'))) and str(scratch) in cmd};parents={rows[p][0] for p in native if rows[p][0] in rows and 'codex' in rows[rows[p][0]][2]};owned=native|parents
 for p in native:
  try:os.killpg(rows[p][1],signal.SIGTERM)
  except ProcessLookupError:pass
 for p in parents:
  try:os.kill(p,signal.SIGTERM)
  except ProcessLookupError:pass
 time.sleep(2);now=owned_table()
 for p in owned:
  if p in now and now[p][2]==rows[p][2]:
   try:os.kill(p,signal.SIGKILL)
   except ProcessLookupError:pass
 time.sleep(1);remaining={p:v for p,v in owned_table().items() if p in owned and '<defunct>' not in v[2]};log.write('NATIVE CHILD CLEANUP '+json.dumps({'owned':sorted(owned),'remaining':remaining})+'\n');assert not remaining
 server.shutdown();server.server_close();thread.join();(ev/'localhost-api-requests.json').write_text(json.dumps(requests,indent=2))
 try:run(['bash','bin/fm-lab-home.sh','teardown',lab])
 finally:
  for d,_,_ in os.walk(scratch,followlinks=False):
   q=pathlib.Path(d)
   if not q.is_symlink():q.chmod(q.stat().st_mode|0o700)
  shutil.rmtree(scratch);log.close()
