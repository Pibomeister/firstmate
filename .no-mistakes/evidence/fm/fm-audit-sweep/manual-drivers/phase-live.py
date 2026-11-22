import os, pathlib, subprocess, json, tempfile, shutil, time
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ')
D=pathlib.Path(tempfile.mkdtemp(prefix='.phase-live-',dir=R))
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ['NO_MISTAKES_GATE','TMUX','TMUX_PANE']: env.pop(k,None)
env.update(FM_HOME=str(D),FM_STATE_OVERRIDE=str(D/'state'),FM_CONFIG_OVERRIDE=str(D/'config'),FM_DATA_OVERRIDE=str(D/'data'))
for p in ['state','data','config']: (D/p).mkdir()
log=(E/'local-cli-behavior.log').open('w',buffering=1)
def run(args,inp=None,extra=None,expect=0):
 p=subprocess.run(args,input=inp,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(env,**(extra or {})),timeout=90)
 log.write('$ '+' '.join(args)+'\n'+(p.stdout or '<silent stdout>\n')+p.stderr+'exit='+str(p.returncode)+'\n')
 assert p.returncode==expect,(args,p.returncode,p.stdout,p.stderr)
 return p.stdout
try:
 # Real host sampling, with high thresholds to isolate persistence errors.
 (D/'config/memory-guard').write_text('swap_warn_mb=999999999\nproc_rss_mb=999999999\n')
 run(['bash','bin/fm-memory-guard.sh','check','--json'])
 os.chmod(D/'state',0o500)
 try: out=run(['bash','bin/fm-memory-guard.sh','check','--json'],expect=1)
 finally: os.chmod(D/'state',0o700)
 assert len((D/'state/memory-guard.tsv').read_text().splitlines())==2
 log.write('OBSERVED: state save failed, sample row persisted, and command exited 1.\n')
 # Public hook protocol using synthetic host payloads; no model or host stub.
 def hook(payload,mode='--claude'):
  return run(['bash','bin/fm-pstack-verify-hook.sh',mode],json.dumps(payload))
 for cmd in ['for f in state/*.status; do\n echo "$f"\ndone','echo "done" >> state/notes.txt']:
  log.write('INPUT command='+repr(cmd)+'\n')
  assert not hook({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':cmd}}).strip()
 for txt in ['done: finished','done [at=1731880000]: finished']:
  out=hook({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':'echo "'+txt+'" >> state/task.status'}})
  assert 'principle-prove-it-works' in out
 log.write('OBSERVED: loop/quoted bare done is silent; both real status report shapes emit context.\n')
 base={'cursor_version':'x','conversation_id':'manual-cursor'}
 hook(dict(base,hook_event_name='afterAgentResponse',text='fixed tests/a_test.py',generation_id='g1'),'--cursor')
 for i in [1,2]:
  hook(dict(base,hook_event_name='afterShellExecution',command='pytest tests/a_test.py',output='FAILED tests/a_test.py::test_one - assert\nFAILED tests/a_test.py::test_two - assert\n',duration=900,generation_id='g'+str(i)),'--cursor')
  out=hook(dict(base,hook_event_name='postToolUse',tool_name='Read',tool_input={'path':'src/a.py'},tool_output='{"exitCode":0}',generation_id='g'+str(i)),'--cursor')
  assert ('principle-attack-the-premise' in out)==(i==2)
 log.write('OBSERVED: two failing nodes in one Cursor event count once; second independent event triggers premise context.\n')
 # Real ledger CLI with a stale heartbeat and a pending row older than installation.
 now=int(time.time()); (D/'state/watchdog').mkdir()
 actions=D/'state/watchdog/actions.tsv'
 actions.write_text(f'{now-120}\twd1\t\tprimary\tfrozen\tnudge\tpending\tWatchdog (automated): frozen 12 minutes\n')
 hb=D/'state/heartbeat.json'; hb.write_text(json.dumps({'schema':'fm-heartbeat.v1','published_epoch':now-720,'generated_epoch':now-720}))
 run(['bash','bin/fm-stall-ledger.sh','observe'],extra={'FM_STALL_LEDGER_MIN_SECS':'0'})
 ledger=D/'state/stall-ledger.tsv'
 assert '\tstall-open\tprimary\t' in ledger.read_text()
 time.sleep(1); now=int(time.time())
 with actions.open('a') as f: f.write(f'{now}\twd1\t\tprimary\tfrozen\tnudge\tdone\tdelivered; no transcript to confirm\n')
 hb.write_text(json.dumps({'schema':'fm-heartbeat.v1','published_epoch':now,'generated_epoch':now}))
 run(['bash','bin/fm-stall-ledger.sh','observe'],extra={'FM_STALL_LEDGER_MIN_SECS':'0'})
 rows=[x.split('\t') for x in ledger.read_text().splitlines() if '\tstall-close\t' in x]
 assert len(rows)==1 and rows[0][6]=='firstmate',rows
 log.write('PERSISTED stall-ledger.tsv:\n'+ledger.read_text())
 log.write('OBSERVED: fresh heartbeat closes installation stall as firstmate; delivery-only nudge receives no credit.\n')
 # Actual prune entry point, no clock seam, protected fresh lock then stale lock.
 (D/'config/hung-ladder').write_text('mode=observe\nactor=manual\n')
 hl=D/'state/hung-ladder'; hl.mkdir(); lock=hl/'.lock'; lock.mkdir()
 run(['bash','bin/fm-hung-ladder.sh','prune']); assert lock.exists()
 os.utime(lock,(1577836800,1577836800))
 run(['bash','bin/fm-hung-ladder.sh','prune']); assert not lock.exists()
 run(['bash','bin/fm-hung-ladder.sh','verify'])
 log.write('OBSERVED: fresh lock preserved, stale lock reclaimed and released; ledger verifies.\n')
 log.write('ALL LOCAL CLI SCENARIOS PASSED\n')
finally:
 os.chmod(D/'state',0o700); shutil.rmtree(D); log.close()
