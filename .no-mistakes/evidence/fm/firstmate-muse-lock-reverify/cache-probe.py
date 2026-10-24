import pathlib,subprocess,json,datetime
root=pathlib.Path.cwd(); lab=root/'.nm-muse-lab'; ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5QN6B0CPGQ68QX3AK7G69KK')
source=next(p for p in (lab/'data/muse/sessions').glob('*/*/*/*/session.jsonl') if any(json.loads(l).get('payload',{}).get('record',{}).get('workspace_root')==str(lab/'ws-lock') for l in p.read_text().splitlines()))
rows=[json.loads(l) for l in source.read_text().splitlines()]
prefix=rows[0]; metadata=next(r for r in rows if r.get('payload_type')=='runtime.session.metadata')
events=[r for r in rows if r.get('payload_type')=='runtime.session' and r.get('payload',{}).get('kind')=='run' and r['payload'].get('event',{}).get('kind') in ['started','terminal']]
assert len(events)==2 and events[1]['payload']['event']['terminal']=='completed'
assert 'retained_frame' in prefix
(ev/'muse-completed-lifecycle.json').write_text(json.dumps({'session':source.parent.name,'tool_batches':sum(r.get('payload_type')=='tool_batch.effect.started' for r in rows),'lifecycle':[r['payload'] for r in events],'smoke_file':(lab/'ws-lock/smoke.txt').read_text()},indent=2))
assert (lab/'ws-lock/smoke.txt').read_text().splitlines()==['line one','line two']
state=lab/'cache-state'; state.mkdir(); sessions=lab/'cache-sessions'; workspace=metadata['payload']['record']['workspace_root']
today=datetime.date.today(); yesterday=today-datetime.timedelta(days=1)
a=sessions/today.strftime('%Y/%m/%d')/'settled'/ 'session.jsonl'; b=sessions/yesterday.strftime('%Y/%m/%d')/'delayed'/ 'session.jsonl'
a.parent.mkdir(parents=True);b.parent.mkdir(parents=True)
def encode(r):return json.dumps(r,separators=(',',':'))+'\n'
a.write_text(encode(prefix)+encode(metadata)+''.join(map(encode,events)))
(state/'cache.muse-session').write_text(f'sessions_root={sessions}\nworkspace_root={workspace}\nbinding_id=metadata-staging\n')
def run(expr):return subprocess.check_output(['bash','-c','. "$1/bin/fm-busy-lib.sh"; '+expr,'probe',str(root),str(state),str(sessions),workspace],text=True)
def classify():return run('fm_busy_classify tmux isolated muse cache "$2"')
def signature():return run('fm_busy_muse_namespace_signature "$3" "$4"')
log=[]
def check(label,expected):
 got=classify(); log.append(f'{label}: {got}');assert got==expected,(label,got)
check('Native retained-frame metadata binds a completed turn','idle muse-session-log')
sig=signature(); cached=(state/'cache.muse-session-current').read_bytes()
b.write_text(encode(prefix)); check('Yesterday competing session has only retained prefix','idle muse-session-log')
text=encode(metadata)
with b.open('a') as f:f.write(text[:-3])
check('Yesterday competing session has incomplete metadata','idle muse-session-log')
assert signature()==sig
with b.open('a') as f:f.write(text[-3:]+encode(events[0]))
check('Yesterday metadata becomes ready and its run opens','unknown muse-session-log')
assert signature()!=sig
b.unlink(); check('Competing session removed','idle muse-session-log')
cache=(state/'cache.muse-session-current').read_bytes();sig=signature()
with a.open('a') as f:f.write(encode(events[0]))
check('Unique session receives next run append','busy muse-session-log')
assert signature()==sig and (state/'cache.muse-session-current').read_bytes()==cache
log.append('Run append preserved namespace signature and cached binding bytes')
with a.open('a') as f:f.write(encode(events[1]))
check('Next run closes','idle muse-session-log')
(ev/'muse-cache-boundary.txt').write_text('Real Firstmate classifier, staged native Muse output records as disposable session data.\n'+'\n'.join(log)+'\n')
print('\n'.join(log))
