import pathlib,subprocess,json,time,os
root=pathlib.Path.cwd(); lab=root/'.nm-muse-lab'; ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5QN6B0CPGQ68QX3AK7G69KK'); sock=(lab/'socket').read_text()
def tm(*args):return subprocess.check_output(['tmux','-L',sock,*args],text=True)
ws=lab/'ws-long'; subprocess.run(['git','init','-q',str(ws)],check=True)
prompt='This is an isolated integration test. Do not read user files, do not start subagents, do not read parent instructions. Create part01.txt through part20.txt in this workspace one at a time. For EACH file use a separate shell command to write its index, run sleep 3, then a separate tool call to read it. Continue through all twenty. Reply DONE-LONG.'
tm('new-window','-d','-t','fm-lab-muse:','-n','long','-c',str(ws),'muse','--yolo','--model','muse-wonder-1.0',prompt)
state=lab/'home/state'; (state/'long.muse-session').write_text(f'sessions_root={lab}/data/muse/sessions\nworkspace_root={ws}\nbinding_id=live-long\n')
def classify():return subprocess.check_output(['bash','-c','. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux fm-lab-muse:long muse long "$2"','probe',str(root),str(state)],text=True)
def records():
 for p in (lab/'data/muse/sessions').glob('*/*/*/*/session.jsonl'):
  rows=[]
  for line in p.read_text().splitlines():
   try:rows.append(json.loads(line))
   except:pass
  if any(r.get('payload',{}).get('record',{}).get('workspace_root')==str(ws) for r in rows): return p,rows
 return None,[]
seen=[]; t=time.time(); log=None
while time.time()-t<160:
 log,rows=records(); verdict=classify()
 if verdict not in seen: seen.append(verdict); print('long:',verdict,flush=True)
 batches=sum(r.get('payload_type')=='tool_batch.effect.started' for r in rows)
 if batches>=3 and len(list(ws.glob('part*.txt')))>=1:break
 time.sleep(.4)
else:raise RuntimeError('No multi-step tool activity within 160 seconds')
assert verdict=='busy muse-session-log',verdict
(ev/'muse-interrupt-before.txt').write_text(tm('capture-pane','-p','-t','fm-lab-muse:long','-S','-100'))
tm('send-keys','-t','fm-lab-muse:long','Escape');print('Sent Escape during multi-step tool loop',flush=True)
for _ in range(100):
 verdict=classify()
 if verdict=='idle muse-session-log':break
 time.sleep(.2)
assert verdict=='idle muse-session-log',verdict
log,rows=records(); lifecycle=[r['payload'] for r in rows if r.get('payload_type')=='runtime.session' and r.get('payload',{}).get('kind')=='run' and r['payload'].get('event',{}).get('kind') in ['started','terminal']]
assert len(lifecycle)==2,lifecycle
assert lifecycle[0]['run_id']==lifecycle[1]['run_id']
assert lifecycle[1]['event']['terminal']=='cancelled'
print('long:',verdict, 'one matched bracket, terminal cancelled, tool batches',batches,flush=True)
(ev/'muse-interrupt-after.txt').write_text(tm('capture-pane','-p','-t','fm-lab-muse:long','-S','-100'))
(ev/'muse-interrupt-lifecycle.json').write_text(json.dumps({'session':log.parent.name,'observed_states':seen+[verdict],'tool_batches_before_escape':batches,'partial_files':len(list(ws.glob('part*.txt'))),'lifecycle':lifecycle},indent=2))
tm('send-keys','-t','fm-lab-muse:long','C-u')
print('Cleared restored composer with Ctrl+U',flush=True)
