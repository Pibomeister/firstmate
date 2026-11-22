import os,pathlib,tempfile,subprocess,json,shutil,time,traceback
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE'); W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-cli-',dir=str(R)))
log=(E/'live-cli-transcript.log').open('w'); results=[]
def say(x): log.write(x+'\n'); log.flush(); print(x,flush=True)
def home(name):
 p=W/name
 subprocess.run(['bash','bin/fm-lab-home.sh','create',str(p)],check=True,stdout=subprocess.DEVNULL)
 return p
def env(h):
 e=os.environ.copy()
 for k in list(e):
  if k.startswith(('FM_','HERDR_')) or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): e.pop(k,None)
 e['FM_HOME']=str(h); return e
def run(h,cmd,data=None,extra=None,expected=0):
 e=env(h); e.update(extra or {})
 say('$ FM_HOME=<disposable '+h.name+'> '+' '.join(cmd))
 p=subprocess.run(cmd,input=data,text=True,capture_output=True,env=e,timeout=90)
 say(p.stdout.rstrip() or '<empty stdout>')
 if p.stderr: say('stderr: '+p.stderr.rstrip())
 say('exit='+str(p.returncode))
 if expected is not None: assert p.returncode==expected,(cmd,p.returncode,expected)
 return p
try:
 h=home('hook')
 def hook(event): return run(h,['bash','bin/fm-pstack-verify-hook.sh','--claude'],json.dumps(event),{'FM_ROOT_OVERRIDE':str(h),'FM_STATE_OVERRIDE':str(h/'state')})
 for cmd in ['for f in state/*.status; do\n echo "$f"\ndone','echo "done" >> state/notes.txt']:
  say('INPUT command='+repr(cmd)); p=hook({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':cmd}}); assert not p.stdout
 for cmd in ['echo "done: completed export" >> state/task.status','echo "done [at=1731880000]: completed export" >> state/task.status']:
  say('INPUT command='+repr(cmd)); p=hook({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':cmd}}); assert 'principle-prove-it-works' in json.loads(p.stdout)['hookSpecificOutput']['additionalContext']
 results.append({'name':'hook bare done versus actual status completion','pass':True})
 # One failing execution with two failed nodes is one red; a second execution triggers the attack principle.
 def cur(event):
  event.update(cursor_version='x',conversation_id='live-c1')
  return run(h,['bash','bin/fm-pstack-verify-hook.sh','--cursor'],json.dumps(event),{'FM_ROOT_OVERRIDE':str(h),'FM_STATE_OVERRIDE':str(h/'state')})
 cur({'hook_event_name':'afterAgentResponse','text':'fixed tests/sample_test.py','generation_id':'g1'})
 for gen in ['g1','g2']:
  cur({'hook_event_name':'afterShellExecution','command':'pytest tests/sample_test.py','output':'FAILED tests/sample_test.py::test_a - assert\nFAILED tests/sample_test.py::test_b - assert\n','duration':900,'generation_id':gen})
  p=cur({'hook_event_name':'postToolUse','tool_name':'Read','tool_input':{'path':'src/a.py'},'tool_output':'{"exitCode":0}','generation_id':gen})
  if gen=='g1': assert not p.stdout
  else: assert 'principle-attack-the-premise' in json.loads(p.stdout)['additional_context']
 results.append({'name':'hook counts one red per execution','pass':True})
 h=home('permission')
 # Public classifier consumes synthetic prompt text, never a fake classifier.
 def prompt(cmd): return '─'*40+'\n Bash command\n'+'╌'*40+'\n '+cmd+'\n'+'╌'*40+'\n Do you want to proceed?\n ❯ 1. Yes\n  2. No\n Esc to cancel\n'
 for cmd in ['export','export -p','declare -p','typeset -p','declare -px','export | cat','declare -p | grep HOME']:
  say('INPUT proposed command='+repr(cmd)); p=run(h,['bash','bin/fm-permission-prompt.sh','classify','--harness','claude'],prompt(cmd)); assert p.stdout.strip()=='hardstop\tcredential'
 p=run(h,['bash','bin/fm-permission-prompt.sh','classify','--harness','claude'],prompt('export FOO=bar')); assert p.stdout.strip()=='route\ttool-approval'
 for cmd,want in [('cat <<EOF\n'+'─'*40+'\n'+'─'*40+'\n'+'╌'*40+'\n EOF','hold\tunproven'),('rm -rf build && cat <<EOF\n'+'─'*40+'\n'+'─'*40+'\n'+'╌'*40+'\n EOF','hardstop\tdestructive')]:
  say('INPUT nested command preview='+repr(cmd)); p=run(h,['bash','bin/fm-permission-prompt.sh','classify','--harness','claude'],prompt(cmd)); assert p.stdout.strip()==want
 results.append({'name':'permission dumps hardstop; nested boundaries cannot hide command','pass':True})
 h=home('memory'); (h/'config/memory-guard').write_text('swap_warn_mb=999999999\nproc_rss_mb=999999999\n')
 run(h,['bash','bin/fm-memory-guard.sh','check','--observe'])
 os.chmod(h/'state',0o500)
 try: p=run(h,['bash','bin/fm-memory-guard.sh','check','--observe'],expected=1)
 finally: os.chmod(h/'state',0o700)
 assert 'cannot write' in p.stderr
 say('persisted sample rows='+str(len((h/'state/memory-guard.tsv').read_text().splitlines())))
 assert len((h/'state/memory-guard.tsv').read_text().splitlines())==2
 results.append({'name':'memory guard reports state-save failure despite appendable sample log','pass':True})
 h=home('ladder'); (h/'config/hung-ladder').write_text('mode=observe\nactor=local-test\n')
 ep=h/'state/hung-ladder/episodes'; ep.mkdir(parents=True); (ep/'removed.ep').write_text('state=open\nactions=\n'); lock=ep.parent/'.lock'; lock.mkdir()
 run(h,['bash','bin/fm-hung-ladder.sh','prune']); assert (ep/'removed.ep').exists() and lock.exists(); say('fresh lock and episode both retained')
 old=time.time()-601; os.utime(lock,(old,old)); run(h,['bash','bin/fm-hung-ladder.sh','prune']); assert not (ep/'removed.ep').exists() and not lock.exists(); say('stale lock reclaimed; orphaned episode removed; lock released')
 results.append({'name':'ladder prune respects a fresh lock and reclaims a stale lock','pass':True})
 # Real ledger CLI with synthetic time and serialized watchdog/heartbeat inputs.
 for installation in (False,True):
  h=home('ledger-install' if installation else 'ledger-open'); st=h/'state'; (st/'watchdog').mkdir(); acts=st/'watchdog/actions.tsv'; base=1800000000
  def observe(now,pub):
   (st/'heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','published_epoch':pub,'generated_epoch':pub}))
   run(h,['bash','bin/fm-stall-ledger.sh','observe'],extra={'FM_TEST_SEAM':'1','FM_NOW':str(now),'FM_STALL_LEDGER_MIN_SECS':'0'})
   say('LEDGER:\n'+(st/'stall-ledger.tsv').read_text())
  def row(epoch,phase,detail): return f'{epoch}\twd-local\t\tprimary\tfrozen\tnudge\t{phase}\t{detail}\n'
  if installation:
   acts.write_text(row(base,'pending','Watchdog (automated): frozen 12 minutes')); observe(base+120,base-600)
  else:
   observe(base-100,base-105); acts.write_text(row(base,'pending','Watchdog (automated): frozen 12 minutes')); observe(base,base-5)
  with acts.open('a') as f:f.write(row(base+600,'done','delivered; no transcript to confirm'))
  observe(base+600,base+600)
  rows=[r.split('\t') for r in (st/'stall-ledger.tsv').read_text().splitlines()]; close=[r for r in rows if r[1]=='stall-close']
  if installation: assert len(close)==1 and close[0][6]=='firstmate'
  else: assert not close
  observe(base+660,base+660)
  rows=[r.split('\t') for r in (st/'stall-ledger.tsv').read_text().splitlines()]; assert len([r for r in rows if r[1]=='stall-open'])==1
  if not installation:
   with acts.open('a') as f:f.write(row(base+900,'done','transcript advanced'))
   observe(base+900,base+900); rows=[r.split('\t') for r in (st/'stall-ledger.tsv').read_text().splitlines()]; assert any(r[1]=='stall-close' and r[6]=='watchdog' for r in rows)
 results.append({'name':'unconfirmed nudges neither recover an open stall nor create a phantom episode at installation','pass':True})
except Exception:
 say(traceback.format_exc()); results.append({'name':'driver failure','pass':False})
finally:
 shutil.rmtree(W); say('Disposable CLI homes removed'); (E/'live-cli-results.json').write_text(json.dumps(results,indent=2)); log.close()
if any(not x['pass'] for x in results): raise SystemExit(1)
