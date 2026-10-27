import base64
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys

ROOT = Path.cwd()
LAB = ROOT / '.live-check/lab'

class Client:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(50)
        self.s.connect(str(ROOT / '.s.sock'))
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+'\r\n\r\n').encode())
        self.buf = b''
        while b'\r\n\r\n' not in self.buf:
            self.buf += self.s.recv(65536)
        h, self.buf = self.buf.split(b'\r\n\r\n',1)
        assert h.startswith(b'HTTP/1.1 101'), h
        self.i = 0
        self.rpc('initialize', {'clientInfo':{'name':'firstmate_live_test','version':'1.0'},'capabilities':{'experimentalApi':True}})
        self.send({'method':'initialized'})
    def read(self,n):
        while len(self.buf)<n:
            data = self.s.recv(65536)
            if not data: raise EOFError()
            self.buf += data
        a,self.buf = self.buf[:n],self.buf[n:]
        return a
    def frame(self,op,data):
        n=len(data)
        header=bytes([128|op,128|n]) if n<126 else bytes([128|op,254])+struct.pack('!H',n)
        mask=os.urandom(4)
        self.s.sendall(header+mask+bytes(c^mask[i%4] for i,c in enumerate(data)))
    def send(self,msg): self.frame(1,json.dumps(msg).encode())
    def receive(self):
        message=b''
        while True:
            a,b=self.read(2); n=b&127; op=a&15
            if n==126: n=struct.unpack('!H',self.read(2))[0]
            if n==127: n=struct.unpack('!Q',self.read(8))[0]
            data=self.read(n)
            if op==9: self.frame(10,data); continue
            if op==8: raise EOFError(data)
            if op==10: continue
            message+=data
            if a&128: return json.loads(message)
    def rpc(self,method,params):
        self.i+=1; ident=self.i
        self.send({'id':ident,'method':method,'params':params})
        while True:
            msg=self.receive()
            if msg.get('id')==ident:
                print('RPC',method,json.dumps(msg),flush=True)
                if 'error' in msg: raise RuntimeError(msg)
                return msg['result']

def tool(client, thread, command):
    env={k:None for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDE_CODE_SESSION_ID','CLAUDE_PID','FM_SUPERVISION_MODEL']}
    env.update({'FM_HOME':str(LAB),'CODEX_THREAD_ID':thread,'CODEX_SESSION_ID':thread})
    return client.rpc('command/exec',{'command':['/bin/bash','-c',command],'cwd':str(ROOT),'env':env,'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':45000,'outputBytesCap':20000})

if __name__=='__main__':
    c=Client()
    mode=sys.argv[1]
    if mode=='start':
        a=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
        b=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
        Path('.live-check/ids.json').write_text(json.dumps({'a':a,'b':b}))
        print('THREADS',a,b,flush=True)
        result=tool(c,a,'echo shell=$$ parent=$PPID; ps -o pid=,ppid=,comm= -p $$,$PPID; bin/fm-lock.sh; cat "$FM_HOME/state/.lock-session"')
        assert result['exitCode']==0, result
    elif mode=='tool':
        ids=json.loads(Path('.live-check/ids.json').read_text())
        r=tool(c,ids[sys.argv[2]],sys.argv[3])
        sys.exit(r['exitCode'])
    elif mode=='read':
        ids=json.loads(Path('.live-check/ids.json').read_text())
        for name,tid in ids.items(): c.rpc('thread/read',{'threadId':tid,'includeTurns':False})
    elif mode=='unsubscribe':
        ids=json.loads(Path('.live-check/ids.json').read_text())
        c.rpc('thread/unsubscribe',{'threadId':ids[sys.argv[2]]})
    elif mode=='archive':
        ids=json.loads(Path('.live-check/ids.json').read_text())
        c.rpc('thread/archive',{'threadId':ids[sys.argv[2]]})
        c.rpc('thread/read',{'threadId':ids[sys.argv[2]],'includeTurns':False})
    elif mode=='active':
        ids=json.loads(Path('.live-check/ids.json').read_text())
        t=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access',
            'model':'network-unavailable-probe','modelProvider':'live_probe',
            'config':{'model_providers.live_probe':{'name':'Unavailable loopback provider','base_url':'http://127.0.0.1:9/v1','wire_api':'responses','requires_openai_auth':False,'request_max_retries':4,'stream_max_retries':4}}})['thread']['id']
        ids['c']=t
        Path('.live-check/ids.json').write_text(json.dumps(ids))
        assert tool(c,t,'bin/fm-lock.sh')['exitCode']==0
        turn=c.rpc('turn/start',{'threadId':t,'input':[{'type':'text','text':'Reply OK.'}]})
        print('ACTIVE_OBSERVATION',c.rpc('thread/read',{'threadId':t,'includeTurns':False})['thread']['status'],flush=True)
        r=tool(c,ids['b'],'bin/fm-lock.sh')
        print('FOREIGN_DURING_TURN',json.dumps(r),flush=True)
        assert r['exitCode']==1, r
        c.rpc('turn/interrupt',{'threadId':t,'turnId':turn['turn']['id']})
    elif mode=='legacy':
        LAB=ROOT/'.live-check/legacy'
        tid=c.rpc('thread/start',{'cwd':str(LAB),'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
        daemon=Path('.live-check/lab/state/.lock-session').read_text().split('codex_daemon_pid=')[1].splitlines()[0]
        (LAB/'state/.lock').write_text(daemon+'\n')
        (LAB/'state/existing-worker.meta').write_text('kind=ship\nstatus=working\n')
        before=(LAB/'state/existing-worker.meta').read_bytes()
        r=tool(c,tid,'set -e; bin/fm-lock.sh status; bin/fm-lock.sh; bin/fm-lock.sh status; cat "$FM_HOME/state/.lock-session"; cat "$FM_HOME/state/existing-worker.meta"')
        assert r['exitCode']==0
        assert (LAB/'state/.lock').read_text().strip()!=daemon
        assert (LAB/'state/existing-worker.meta').read_bytes()==before
        print('EXISTING_WORKER_RECORD_UNCHANGED true',flush=True)
