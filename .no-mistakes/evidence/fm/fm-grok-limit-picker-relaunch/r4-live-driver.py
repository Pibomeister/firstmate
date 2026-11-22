import os,sys,pathlib,subprocess,time,json,threading,http.server,signal,html
root=pathlib.Path.cwd(); scratch=root/'.test-r4'; ev=pathlib.Path('~/.no-mistakes/evidence/01M7ZW57ECDC5EVWGNK2YVCK3E')
lab=scratch/'lab-b'; project=scratch/'project'; home=scratch/'user-home'; gh=scratch/'grok-home'
for p in [project,home,gh]:p.mkdir(exist_ok=True)
subprocess.run(['git','init','-q',str(project)],check=True)
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.DEVNULL)
(lab/'config/supervision-host').touch()
requests=[]; current={'status':402,'code':'usage_limit_reached'}
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  requests.append(['GET',self.path]);self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
  if 'models' in self.path:obj={'object':'list','data':[{'id':'grok-code-fast-1','object':'model','created':0,'owned_by':'xai'}]}
  else:obj={'api_key_id':'local-synthetic','name':'local-synthetic','team_id':'local','disabled':False,'redacted_api_key':'synthetic'}
  self.wfile.write(json.dumps(obj).encode())
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length',0)));requests.append(['POST',self.path,dict(current)])
  self.send_response(current['status']);self.send_header('Content-Type','application/json');self.end_headers()
  code=current['code'];self.wfile.write(json.dumps({'code':code,'message':'You hit your weekly limit.','error':{'code':code,'type':code,'message':'You hit your weekly limit.'}}).encode())
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever);thread.start()
url=f'http://127.0.0.1:{server.server_port}/v1'
env=os.environ.copy()
for k in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_PANE_ID','HERDR_SOCKET_PATH','NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','XAI_API_KEY','GROK_API_KEY','GROK_AUTH','GROK_AUTH_PATH']:env.pop(k,None)
env.update(HOME=str(home),GROK_HOME=str(gh),FM_HOME=str(lab),XAI_API_KEY='xai-local-synthetic-key',GROK_XAI_API_BASE_URL=url,GROK_MODELS_BASE_URL=url,GROK_MODELS_LIST_URL=url+'/models',GROK_CLI_CHAT_PROXY_BASE_URL=url,GROK_LOG_FILE=str(scratch/'grok-debug.log'),TERM='xterm-256color')
# Relative socket keeps macOS's Unix socket path below its limit. Every tmux call uses this socket.
sock='.test-r4/live.sock'; tm=['tmux','-f','/dev/null','-S',sock]
def run(args,timeout=20,env_=None):return subprocess.run(args,env=env_ or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
def mux(*args):return run(tm+list(args))
def cap(name):
 r=mux('capture-pane','-p','-t','primary:fm-guard');(ev/f'r4-{name}.txt').write_text(r.stdout);return r.stdout
frames=[];result={}
try:
 r=mux('new-session','-d','-s','primary','-n','fm-guard','-x','120','-y','40','-c',str(root),'grok --cwd '+str(project)+' --no-memory --no-subagents --disable-web-search --model grok-code-fast-1 --debug')
 result['launch_rc']=r.returncode
 if r.returncode:raise RuntimeError(r.stdout)
 time.sleep(4);s=cap('grok-startup');frames.append(('Startup',s))
 if 'trust' in s.lower():mux('send-keys','-t','primary:fm-guard','Enter');time.sleep(3)
 s=cap('grok-ready');frames.append(('Isolated synthetic API session',s))
 mux('send-keys','-t','primary:fm-guard','-l','Keep this unsent draft intact.');time.sleep(1)
 before=cap('draft-before');frames.append(('Draft before exit request',before))
 ident=mux('display-message','-p','-t','primary:fm-guard','#{socket_path}\t#{pid}').stdout.strip().split('\t')
 (lab/'state/guard.meta').write_text(f'window=primary:fm-guard\nendpoint_task_id=guard\nworktree={project}\nproject={project}\nharness=grok\nkind=scout\nmode=no-mistakes\ntmux_socket={root/sock}\ntmux_server_pid={ident[1]}\n')
 controlenv=env.copy();controlenv['TMUX']=f'{sock},{ident[1]},0';controlenv['FM_CONTROL_POLL']='0.05'
 r=run(['bash','bin/fm-control.sh','guard','exit'],env_=controlenv);(ev/'r4-draft-control.txt').write_text(r.stdout)
 after=cap('draft-after');frames.append(('Draft after refused exit request',after));result.update(draft_control_rc=r.returncode,draft_unchanged=before==after,draft_refusal=('refusing to type' in r.stdout and 'pending' in r.stdout))
 mux('send-keys','-t','primary:fm-guard','C-u');time.sleep(.3)
 for status,code in [(402,'usage_limit_reached'),(429,'usage_limit_reached'),(429,'usage_pool_exhausted'),(403,'usage_limit_reached')]:
  current.update(status=status,code=code)
  mux('send-keys','-t','primary:fm-guard','-l','Reply OK.');mux('send-keys','-t','primary:fm-guard','Enter');time.sleep(8)
  s=cap(f'quota-{status}-{code}');frames.append((f'Local API: HTTP {status}, {code}',s))
  if 'Buy more credits' in s and 'Try Again' in s:
   result['picker_reached']=True
   result['picker_exact_two_choices']=('1 (○) Buy more credits' in s and '2 (○) Try Again' in s)
   r=run(['bash','-c','. bin/fm-composer-lib.sh; fm_composer_blocking_dialog "$(cat "$1")"','_',str(ev/f'r4-quota-{status}-{code}.txt')]);(ev/'r4-picker-classification.txt').write_text(r.stdout);result['picker_classification_rc']=r.returncode
   r=run(['bash','bin/fm-control.sh','guard','interrupt'],env_=controlenv);(ev/'r4-picker-interrupt.txt').write_text(r.stdout);result['picker_interrupt_rc']=r.returncode
   break
  mux('send-keys','-t','primary:fm-guard','C-c');time.sleep(.4)
 result.setdefault('picker_reached',False)
except Exception as e:result['error']=str(e)
finally:
 cleanup=mux('kill-server');result['tmux_stop_rc']=cleanup.returncode
 server.shutdown();server.server_close();thread.join()
 (ev/'r4-live-result.json').write_text(json.dumps(result,indent=2));(ev/'r4-local-api-requests.json').write_text(json.dumps(requests,indent=2))
 doc='<!doctype html><meta charset="utf-8"><title>Grok isolated terminal evidence</title><style>body{background:#191919;color:#eee;font:15px monospace;margin:24px}pre{padding:20px;border:1px solid #666;overflow:auto}h2{font:20px sans-serif}</style><h1>Grok 1.0.92 — captured live terminal frames</h1><p>Real Grok CLI. Disposable home. Synthetic key and localhost API responses. Text captured from its 120 × 40 tmux viewport.</p>'
 for title,frame in frames:doc+='<h2>'+html.escape(title)+'</h2><pre>'+html.escape(frame)+'</pre>'
 (ev/'r4-grok-terminal.html').write_text(doc)
 print(json.dumps(result,indent=2))
