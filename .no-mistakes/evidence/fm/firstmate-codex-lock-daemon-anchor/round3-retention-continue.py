import concurrent.futures, http.server, json, os, shlex, subprocess, sys, threading, time
from pathlib import Path
from protocol import Client
ROOT=Path.cwd(); LAB=ROOT/'.live-check/primary'; CH=ROOT/'.live-check/native-home'
CH.mkdir(exist_ok=True)
release=threading.Event(); received=threading.Event()
class Provider(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_POST(self):
  body=self.rfile.read(int(self.headers['Content-Length'])); received.set(); release.wait(120)
  self.send_response(500); self.end_headers(); self.wfile.write(b'{"error":{"message":"disposable provider error"}}')
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider);s.daemon_threads=True
threading.Thread(target=s.serve_forever,daemon=True).start()
(CH/'config.toml').write_text('model="live-fixture"\nmodel_provider="live"\n[model_providers.live]\nname="Loopback fixture"\nbase_url="http://127.0.0.1:'+str(s.server_port)+'/v1"\nwire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n[projects.'+json.dumps(str(LAB))+']\ntrust_level="trusted"\n')
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CODEX_THREAD_ID','CODEX_SESSION_ID','CLAUDE_PID','CLAUDE_CODE_SESSION_ID','ORCA_PAIRING_CODE','ORCA_ENVIRONMENT']:
 env.pop(k,None)
env.update(FM_HOME=str(LAB),CODEX_HOME=str(CH),ORCA_USER_DATA_PATH=str(ROOT/'o'))
def run(args,**kwargs):
 p=subprocess.run(args,env=env,text=True,capture_output=True,**kwargs)
 print('COMMAND',shlex.join(args),'EXIT',p.returncode,'STDOUT',p.stdout,'STDERR',p.stderr,flush=True);return p
launch=['bash','bin/fm-lab-home.sh','tmux',str(LAB),'new-session','-d','-x','120','-y','40','-s','primary','-c',str(ROOT),'codex app-server --listen unix://'+str(ROOT/'.s.sock')+' --managed-daemon']
print('REUSE private daemon already launched through fm-lab-home.sh',flush=True)
end=time.monotonic()+20
while not (ROOT/'.s.sock').exists() and time.monotonic()<end:time.sleep(.1)
c=Client()
def rpc(method,params):return c.rpc(method,params)
def tool(t,command):
 e={k:None for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID']}
 e.update(FM_HOME=str(LAB),CODEX_THREAD_ID=t,CODEX_SESSION_ID=t,FM_SESSION_ENDPOINT_META=str(LAB/'endpoint.meta'),ORCA_USER_DATA_PATH=str(ROOT/'o'))
 return rpc('command/exec',{'command':['/bin/bash','-c',command],'cwd':str(ROOT),'env':e,'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':45000,'outputBytesCap':16000})
def state(t):return rpc('thread/read',{'threadId':t,'includeTurns':False})['thread']['status']['type']
handle=(ROOT/'.live-check/retention-handle').read_text()
owner=(LAB/'state/.lock-session').read_text().splitlines()[0]
foreign=rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access','config':{'model_providers.live':{'name':'Loopback fixture','base_url':'http://127.0.0.1:'+str(s.server_port)+'/v1','wire_api':'responses','requires_openai_auth':False,'request_max_retries':0,'stream_max_retries':0}}})['thread']['id']
proof='. bin/backends/orca.sh; fm_backend_orca_endpoint_absence_proof '+shlex.quote(handle)+' '+shlex.quote(str(LAB))+' '+shlex.quote(str(LAB/'state/.lock-session'))
assert state(owner)=='idle'
p=run(['orca','terminal','show','--terminal',handle,'--json']); assert json.loads(p.stdout)['result']['terminal']['connected'] is False
r=tool(foreign,proof);assert r['stdout'].startswith('gone\t'),r
r=tool(foreign,'bin/fm-lock.sh; cat "$FM_HOME/state/.lock-session"');assert r['exitCode']==0,r
assert (LAB/'state/.lock-session').read_text().splitlines()[0]==foreign
assert state(owner)=='idle'
print('PASS idle-retained + positively gone Orca endpoint permits replacement while daemon and retained thread stay alive',flush=True)
# Same stopped endpoint, active thread must still refuse.
turn=rpc('turn/start',{'threadId':foreign,'input':[{'type':'text','text':'Reply OK.'}]})['turn']['id']
assert received.wait(15)
assert state(foreign)=='active'
r=tool(owner,'bin/fm-lock.sh');assert r['exitCode']==1,r
print('PASS active owner refuses replacement even with positively gone endpoint',flush=True)
release.set()
end=time.monotonic()+20
while time.monotonic()<end:
 current=state(foreign)
 if current!='active':break
 time.sleep(.5)
print('ERROR_TURN_RESULTING_STATUS',current,flush=True)
if current=='systemError':
 r=tool(owner,'bin/fm-lock.sh'); assert r['exitCode']==0,r
 print('PASS systemError + positively gone endpoint permits replacement',flush=True)
else:print('SYSTEM_ERROR_NOT_EMITTED provider HTTP 500 produced '+current,flush=True)
(ROOT/'.live-check/retention-ids.json').write_text(json.dumps({'owner':owner,'foreign':foreign,'handle':handle}))
s.shutdown()
