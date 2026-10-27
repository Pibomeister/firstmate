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
assert run(launch).returncode==0
end=time.monotonic()+20
while not (ROOT/'.s.sock').exists() and time.monotonic()<end:time.sleep(.1)
c=Client()
def rpc(method,params):return c.rpc(method,params)
def tool(t,command):
 e={k:None for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID']}
 e.update(FM_HOME=str(LAB),CODEX_THREAD_ID=t,CODEX_SESSION_ID=t,FM_SESSION_ENDPOINT_META=str(LAB/'endpoint.meta'),ORCA_USER_DATA_PATH=str(ROOT/'o'))
 return rpc('command/exec',{'command':['/bin/bash','-c',command],'cwd':str(ROOT),'env':e,'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':45000,'outputBytesCap':16000})
def state(t):return rpc('thread/read',{'threadId':t,'includeTurns':False})['thread']['status']['type']
owner=rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
foreign=rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
command='exec env CODEX_HOME='+shlex.quote(str(CH))+' FM_HOME='+shlex.quote(str(LAB))+' codex --dangerously-bypass-hook-trust --remote '+shlex.quote('unix://'+str(ROOT/'.s.sock'))+' --no-alt-screen -C '+shlex.quote(str(LAB))+' resume '+owner
p=run(['orca','terminal','create','--worktree','path:'+str(LAB),'--title','fm-lab-retained-owner','--command',command,'--json']);assert p.returncode==0
handle=json.loads(p.stdout)['result']['terminal']['handle'];(ROOT/'.live-check/retention-handle').write_text(handle)
(LAB/'endpoint.meta').write_text('backend=orca\nterminal='+handle+'\nworktree='+str(LAB)+'\nspawn_gen=s'+str(int(time.time()))+'.1.1\n')
time.sleep(2)
run(['orca','terminal','read','--terminal',handle,'--limit','10000','--json'])
proof='. bin/backends/orca.sh; fm_backend_orca_endpoint_absence_proof '+shlex.quote(handle)+' '+shlex.quote(str(LAB))+' '+shlex.quote(str(LAB/'state/.lock-session'))
assert tool(owner,'bin/fm-lock.sh; cat "$FM_HOME/state/.lock-session"')['exitCode']==0
anchor=int((LAB/'state/.lock').read_text());assert anchor!=int((LAB/'state/.lock-session').read_text().split('codex_daemon_pid=')[1].splitlines()[0])
try:os.kill(anchor,0);raise AssertionError('acquiring process remains alive')
except ProcessLookupError:pass
assert state(owner)=='idle'
p=tool(foreign,proof);assert p['stdout'].startswith('alive\t'),p
before=(LAB/'state/.lock-session').read_bytes()
r=tool(foreign,'bin/fm-lock.sh');assert r['exitCode']==1,r
assert (LAB/'state/.lock-session').read_bytes()==before
print('PASS idle-retained + live Orca Codex endpoint refuses foreign acquisition; acquiring PID dead',flush=True)
# End the actual subscribed frontend. Its shell was exec-replaced, so Orca retains exit metadata.
run(['orca','terminal','send','--terminal',handle,'--text','/quit','--enter','--json'])
end=time.monotonic()+20
while time.monotonic()<end:
 p=run(['orca','terminal','show','--terminal',handle,'--json']); facts=json.loads(p.stdout)
 if facts.get('result',{}).get('terminal',{}).get('connected') is False:break
 time.sleep(.5)
else:raise AssertionError('Orca endpoint did not exit')
assert state(owner)=='idle'
r=tool(foreign,proof);assert r['stdout'].startswith('gone\t'),r
r=tool(foreign,'bin/fm-lock.sh; cat "$FM_HOME/state/.lock-session"');assert r['exitCode']==0,r
assert (LAB/'state/.lock-session').read_text().splitlines()[0]==foreign
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
