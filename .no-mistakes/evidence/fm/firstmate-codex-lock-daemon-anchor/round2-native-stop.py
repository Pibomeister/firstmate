import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path.cwd()/'.live-check'))
from protocol import Client

ROOT = Path.cwd()
LAB = ROOT/'.live-check/primary'
HOME = ROOT/'.live-check/native-home'
HOME.mkdir()
requests = []
release = threading.Event()

class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        count = len(requests)
        print('LOCAL_PROVIDER_REQUEST', count, self.path, flush=True)
        if count == 2:
            release.wait(35)
        message = {'id': 'msg-'+str(count), 'type': 'message', 'role': 'assistant',
                   'status': 'completed', 'content': [{'type':'output_text','text':'OK','annotations':[]}]}
        response = {'id':'resp-'+str(count),'object':'response','status':'completed',
                    'model':'live-fixture','output':[message],
                    'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
        events = [
            {'type':'response.created','response':dict(response,status='in_progress',output=[])},
            {'type':'response.output_item.added','output_index':0,'item':dict(message,status='in_progress',content=[])},
            {'type':'response.output_text.delta','item_id':message['id'],'output_index':0,'content_index':0,'delta':'OK'},
            {'type':'response.output_item.done','output_index':0,'item':message},
            {'type':'response.completed','response':response},
        ]
        data = ''.join('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n' for event in events).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Type','text/event-stream')
            self.send_header('Content-Length',str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider)
server.daemon_threads=True
threading.Thread(target=server.serve_forever,daemon=True).start()
config = '\n'.join([
    'model = "live-fixture"', 'model_provider = "live"',
    '[model_providers.live]', 'name = "Loopback protocol fixture"',
    'base_url = "http://127.0.0.1:'+str(server.server_port)+'/v1"',
    'wire_api = "responses"', 'requires_openai_auth = false',
    'request_max_retries = 0', 'stream_max_retries = 0',
    '[projects.'+json.dumps(str(LAB))+']', 'trust_level = "trusted"',
])+'\n'
(HOME/'config.toml').write_text(config)
env=os.environ.copy()
for key in ['FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE',
            'FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CODEX_THREAD_ID','CODEX_SESSION_ID',
            'CLAUDECODE','CLAUDE_CODE_SESSION_ID']:
    env.pop(key,None)
env.update(CODEX_HOME=str(HOME),FM_HOME=str(LAB),NO_MISTAKES_GATE='test')
launch = ['bash','bin/fm-lab-home.sh','tmux',str(LAB),'new-session','-d','-x','120','-y','40',
          '-s','native','-c',str(LAB),
          'codex --dangerously-bypass-hook-trust app-server --listen unix://'+str(ROOT/'.s.sock')+' --managed-daemon']
print('DAEMON_LAUNCH',json.dumps(launch),flush=True)
subprocess.run(launch,env=env,check=True)
end=time.monotonic()+15
while not (ROOT/'.s.sock').exists() and time.monotonic()<end: time.sleep(.1)

class Observer(Client):
    def receive(self):
        msg=super().receive()
        if msg.get('method','').startswith(('hook/','turn/','error')):
            print('NATIVE_EVENT',json.dumps(msg),flush=True)
        return msg

def execute(c, thread, cmd, seconds=45):
    return c.rpc('command/exec',{'command':['/bin/bash','-c',cmd],'cwd':str(LAB),
        'env':{'FM_HOME':str(LAB),'CODEX_THREAD_ID':thread,'CODEX_SESSION_ID':thread},
        'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':seconds*1000})

def wait_ready(c, thread):
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        result=execute(c,thread,'bin/fm-inbox.sh ready')
        if result['exitCode']==0 and json.loads(result['stdout'])['can_receive'] is True:return
        time.sleep(.2)
    raise AssertionError('native watcher readiness timed out')

c=Observer()
c.rpc('hooks/list',{'cwds':[str(LAB)]})
owner=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access',
    'baseInstructions':'Reply OK only.'})['thread']['id']
other=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access',
    'baseInstructions':'Reply OK only.'})['thread']['id']
assert execute(c,owner,'bin/fm-lock.sh')['exitCode']==0
with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
    for phase,thread in [('own',owner),('foreign',other)]:
        checkpoint_client=Client()
        checkpoint=pool.submit(execute,checkpoint_client,thread,'bin/fm-watch-checkpoint.sh --seconds 28',40)
        wait_ready(c,owner)
        result=c.rpc('turn/start',{'threadId':owner,'input':[{'type':'text','text':'Reply OK.'}]})
        turn_id=result['turn']['id']
        hook=None
        completed=False
        deadline=time.monotonic()+22
        while time.monotonic()<deadline:
            event=c.receive()
            if event.get('method')=='hook/completed' and event['params']['run']['eventName']=='stop':
                hook=event['params']['run']
                if phase=='own':break
            if event.get('method')=='turn/completed':
                completed=True
                break
        assert hook is not None, 'no native Stop notification'
        if phase=='own':
            assert hook['status']=='blocked',hook
            assert 'foreground checkpoint is still running' in json.dumps(hook),hook
            assert not completed
            c.rpc('turn/interrupt',{'threadId':owner,'turnId':turn_id})
            release.set()
        else:
            assert hook['status']=='completed',hook
            assert completed
        print('NATIVE_STOP_VERDICT',phase,hook['status'],'turn_completed',completed,flush=True)
        assert checkpoint.result(timeout=40)['exitCode']==124
        checkpoint_client.s.close()
        time.sleep(.3)
print('PASS native Stop: own checkpoint blocks; foreign checkpoint permits completed turn',flush=True)
server.shutdown()
