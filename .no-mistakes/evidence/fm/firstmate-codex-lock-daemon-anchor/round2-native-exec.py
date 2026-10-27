import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.path.insert(0,str(Path.cwd()/'.live-check'))
from protocol import Client
ROOT=Path.cwd()
LAB=ROOT/'.live-check/primary'
HOME=ROOT/'.live-check/exec-home'
HOME.mkdir(exist_ok=True)
mode=sys.argv[1]
requests=[]
continuation=threading.Event()
release=threading.Event()

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        count=len(requests)
        tools=[t.get('name',t.get('type')) for t in body.get('tools',[])]
        print('REQUEST',count,'TOOLS',json.dumps(tools)[:6000],flush=True)
        if mode=='own' and count>=4:
            assert 'foreground checkpoint is still running' in json.dumps(body.get('input',[]))
            print('NATIVE_CONTINUATION',json.dumps(body.get('input',[]))[-10000:],flush=True)
            continuation.set()
            release.wait(35)
        if mode=='own' and count in (1,2):
            command='bin/fm-lock.sh' if count==1 else 'bin/fm-watch-checkpoint.sh --seconds 25'
            item={'type':'function_call','id':'fc'+str(count),'call_id':'call'+str(count),'name':'exec_command',
                  'arguments':json.dumps({'cmd':command,'yield_time_ms':1000,'max_output_tokens':200})}
        else:
            item={'id':'msg-'+str(count),'type':'message','role':'assistant','status':'completed',
                  'content':[{'type':'output_text','text':'OK','annotations':[]}]}
        response={'id':'resp-'+str(count),'object':'response','status':'completed','model':'live-fixture',
                  'output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
        events=[{'type':'response.created','response':dict(response,status='in_progress',output=[])},
                {'type':'response.output_item.done','output_index':0,'item':item},
                {'type':'response.completed','response':response}]
        data=''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
        try:
            self.send_response(200);self.send_header('Content-Type','text/event-stream')
            self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass

server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
server.daemon_threads=True
threading.Thread(target=server.serve_forever,daemon=True).start()
config=(ROOT/'.live-check/native-home/config.toml').read_text()
config='\n'.join('base_url = "http://127.0.0.1:'+str(server.server_port)+'/v1"' if s.startswith('base_url') else s for s in config.splitlines())+'\n'
(HOME/'config.toml').write_text(config)
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE',
          'FM_GATE_REFUSE_BYPASS','CODEX_THREAD_ID','CODEX_SESSION_ID','CLAUDECODE','CLAUDE_CODE_SESSION_ID']:
    env.pop(k,None)
env.update(CODEX_HOME=str(HOME),FM_HOME=str(LAB),NO_MISTAKES_GATE='test')
args=['codex','--no-daemon','exec','--json','--dangerously-bypass-hook-trust',
      '-s','danger-full-access','-C',str(LAB),'Reply OK.']
print('NATIVE_CLI',json.dumps(args),flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
    future=None
    if mode=='foreign':
        c=Client()
        thread=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
        future=pool.submit(c.rpc,'command/exec',{'command':['/bin/bash','-c','bin/fm-watch-checkpoint.sh --seconds 24'],
            'cwd':str(LAB),'env':{'FM_HOME':str(LAB),'CODEX_THREAD_ID':thread,'CODEX_SESSION_ID':thread},
            'timeoutMs':36000,'sandboxPolicy':{'type':'dangerFullAccess'}})
        end=time.monotonic()+15
        while not (LAB/'state/.watch.lock/pid-identity').exists() and time.monotonic()<end:time.sleep(.1)
        time.sleep(.3)
    with (ROOT/('.live-check/native-'+mode+'.jsonl')).open('w') as out, (ROOT/('.live-check/native-'+mode+'.stderr')).open('w') as err:
        proc=subprocess.Popen(args,env=env,cwd=str(LAB),stdout=out,stderr=err,start_new_session=True)
        if mode=='own':
            assert continuation.wait(20),'no native blocked-Stop continuation'
            assert proc.poll() is None,'turn ended over checkpoint'
            watcher=int((LAB/'state/.watch.lock/pid').read_text())
            os.kill(watcher,0)
            print('OWN_STOP_BLOCKED_CLI_STILL_RUNNING watcher='+str(watcher),flush=True)
            proc.send_signal(2)
            release.set()
        try:rc=proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill();rc=proc.wait();raise
        print('NATIVE_EXIT',rc,flush=True)
        if mode=='foreign':
            assert rc==0
            assert (LAB/'state/native-original-stop-returns.txt').read_text().splitlines()[-1]=='0'
            payload=json.loads((LAB/'state/native-original-stop-payloads.jsonl').read_text().splitlines()[-1])
            assert payload['session_id']!=thread
            watcher=int((LAB/'state/.watch.lock/pid').read_text())
            os.kill(watcher,0)
            print('NATIVE_FOREIGN_STOP_ALLOWED',json.dumps({'native_session':payload['session_id'],
                  'checkpoint_thread':thread,'watcher_still_alive':watcher,'stop_exit':0}),flush=True)
    output=(ROOT/('.live-check/native-'+mode+'.jsonl')).read_text()
    errors=(ROOT/('.live-check/native-'+mode+'.stderr')).read_text()
    print('STDOUT',output,flush=True);print('STDERR',errors,flush=True)
    if mode=='foreign':assert rc==0
    if future:assert future.result(timeout=36)['exitCode']==124
server.shutdown()
