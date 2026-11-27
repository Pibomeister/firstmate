import os,sys,time,json,signal,subprocess,shutil
from pathlib import Path
ROOT=Path.cwd(); E=Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY'); LAB=ROOT/'.test-live-watcher'; LAB.mkdir()
log=(E/('live-watcher-retry.log' if sys.argv[1:]==['retry'] else 'live-watcher.log')).open('w',buffering=1); children=[]; results=[]
def say(s): print(s,flush=True); print(s,file=log,flush=True)
def home(n):
 p=LAB/n; subprocess.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(p)],check=True,capture_output=True)
 (p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n'); (p/'.fm-secondmate-home').write_text('synthetic\n'); (p/'load').write_text('300 0 0\n'); return p
def env(p,**kw):
 e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK')}
 e.update(HOME=str(p),FM_HOME=str(p),XDG_CONFIG_HOME=str(p/'xdg-config'),XDG_DATA_HOME=str(p/'xdg-data'),XDG_CACHE_HOME=str(p/'xdg-cache'),CLAUDE_CONFIG_DIR=str(p/'claude'),FM_TEST_SEAM='1',FM_LOAD_FILE=str(p/'load'),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_WATCH_MANAGED_HOLD='1',FM_HEARTBEAT_LEDGER_IDLE_SECS='10',FM_HEARTBEAT_LEDGER_JITTER='0',FM_HOME_SUMMARY_INTERVAL='10',FM_HOME_SUMMARY_JITTER='0',FM_HOME_SUMMARY_TIMEOUT='120',FM_HEARTBEAT_QUOTA_TIMEOUT='1',FM_HEARTBEAT_DISCOVERY_TIMEOUT='10',FM_HEARTBEAT_READ_TIMEOUT='10')
 e.update({k:str(v) for k,v in kw.items()});return e
def start(p,n,**kw):
 o=(E/(n+'.out')).open('w');r=(E/(n+'.err')).open('w');c=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=env(p,**kw),stdout=o,stderr=r,start_new_session=True);children.append((c,o,r));return c
def stop(c):
 for s,timeout in [(signal.SIGTERM,8),(signal.SIGKILL,5)]:
  try:os.killpg(c.pid,s)
  except ProcessLookupError:pass
  try:c.wait(timeout=timeout)
  except subprocess.TimeoutExpired:continue
  # Main exit alone does not prove detached descendants stopped.
  try:os.killpg(c.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  break

def read(p):
 try:return json.loads(p.read_text())
 except (FileNotFoundError,json.JSONDecodeError):return None

def waitfor(f,t=150):
 end=time.monotonic()+t
 while time.monotonic()<end:
  v=f()
  if v:return v
  time.sleep(.2)
 raise AssertionError('timed out waiting for product state')

def append_wake(p):
 subprocess.run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_append check synthetic-live "synthetic monitoring change"','_',str(ROOT)],env=env(p),check=True,capture_output=True)

def cadence():
 p=home('cadence');c=start(p,'watch-cadence'); hb=p/'state/heartbeat.json'; su=p/'state/home-summary.json'; beat=p/'state/.last-watcher-beat'
 first=waitfor(lambda:read(hb)); sfirst=waitfor(lambda:read(su)); h0=first['generated_epoch'];s0=sfirst['generated_epoch'];say(f'Initial real heartbeat launch={h0}, summary launch={s0}, stale bound={first["stale_after_secs"]}')
 assert first['throttled'] is True
 (E/'watch-heartbeat-initial.json').write_text(json.dumps(first,indent=2)+'\n');(E/'watch-summary-initial.json').write_text(json.dumps(sfirst,indent=2)+'\n')
 append_wake(p); say('Appended a real wake-queue event under synthetic load 300')
 hb_gens=[h0];su_gens=[s0];beats=set();stop_at=time.monotonic()+170
 while time.monotonic()<stop_at:
  assert c.poll() is None,'watcher exited unexpectedly'
  h=read(hb);s=read(su)
  if h and h['generated_epoch']!=hb_gens[-1]:hb_gens.append(h['generated_epoch']);say('heartbeat publication '+str(h['generated_epoch']))
  if s and s['generated_epoch']!=su_gens[-1]:su_gens.append(s['generated_epoch']);say('summary publication '+str(s['generated_epoch']))
  if beat.exists():beats.add(beat.stat().st_mtime_ns)
  if len(hb_gens)>=2 and len(su_gens)>=2:break
  time.sleep(.2)
 assert len(hb_gens)>=2 and len(su_gens)>=2,'loaded monitoring did not publish again'
 assert hb_gens[1]-h0>=39,('early loaded heartbeat',hb_gens)
 assert su_gens[1]-s0>=39,('early loaded summary',su_gens)
 assert hb_gens[1]-first['published_epoch']<first['stale_after_secs'],'healthy heartbeat exceeded its published freshness bound'
 assert len(beats)>=3,'watcher did not keep advancing its cheap liveness beat'
 say(f'Hot gaps: heartbeat={hb_gens[1]-h0}s; summary={su_gens[1]-s0}s; cheap beat advanced {len(beats)} times')
 # Restore calm load and inject another real event. No restart or new scheduler.
 (p/'load').write_text('10 0 0\n'); changed=time.time();append_wake(p)
 calm=waitfor(lambda:(lambda d:d if d and not d['throttled'] else None)(read(hb)),100)
 scalm=waitfor(lambda:(lambda d:d if d and d['generated_epoch']>su_gens[-1] else None)(read(su)),100)
 assert calm['generated_epoch']-hb_gens[-1]<40,'calm heartbeat waited out the hot interval'
 assert scalm['generated_epoch']-su_gens[-1]<40,'calm summary waited out the hot interval'
 (E/'watch-heartbeat-calm.json').write_text(json.dumps(calm,indent=2)+'\n');(E/'watch-summary-calm.json').write_text(json.dumps(scalm,indent=2)+'\n')
 say(f'Calm recovery: heartbeat launch gap={calm["generated_epoch"]-hb_gens[-1]}s; summary gap={scalm["generated_epoch"]-su_gens[-1]}s')
 stop(c)
 results.extend([dict(name='Real local watcher defers hot-load changes, publishes before its freshness deadline, and restores calm heartbeat cadence while cheap beats advance',result='pass',live=True,evidence='live-watcher.log; watch-heartbeat-initial.json; watch-heartbeat-calm.json',reason='Actual watcher, heartbeat and snapshot executables; synthetic load file and wake-queue events in a disposable home.'),dict(name='Real local home-summary snapshots slow to the loaded interval and resume ordinary publication after load falls',result='pass',live=True,evidence='live-watcher.log; watch-summary-initial.json; watch-summary-calm.json',reason='Actual watcher and home-summary writer with synthetic load; no replacement producer.')])

def retry():
 p=home('retry'); now=int(time.time());old=now-120
 ledger=dict(schema='fm-heartbeat.v1',generated_epoch=old,published_epoch=old,throttled=True,stale_after_secs=200)
 (p/'state/heartbeat.json').write_text(json.dumps(ledger));c=start(p,'watch-retry',FM_HEARTBEAT_LEDGER_IDLE_SECS=3,FM_HOME_SUMMARY_INTERVAL=999999)
 seen=set();starts=[];deadline=time.monotonic()+150
 while time.monotonic()<deadline and len(starts)<3:
  rows=subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,args='],text=True)
  parsed=[]
  for row in rows.splitlines():
   bits=row.strip().split(None,3)
   if len(bits)==4:parsed.append((int(bits[0]),int(bits[1]),int(bits[2]),bits[3]))
  for pid,ppid,pgid,args in parsed:
   parent_args=next((a for q,parent,g,a in parsed if q==ppid),'')
   if pgid==c.pid and str(ROOT/'bin/fm-heartbeat.sh') in args and args.endswith('--write') and parent_args.endswith('/bin/fm-watch.sh') and pid not in seen:
    seen.add(pid);starts.append(time.monotonic());say(f'Observed real heartbeat attempt {len(starts)} pid={pid}; inject process failure before publication')
    # Stop only this lab publication and its existing descendants, leaving the ticker running.
    owned={pid};changed=True
    while changed:
     before=len(owned);owned.update(q for q,parent,g,a in parsed if parent in owned);changed=len(owned)!=before
    for q in reversed(sorted(owned)):
     try:os.kill(q,signal.SIGKILL)
     except ProcessLookupError:pass
    break
  time.sleep(.25)
 assert len(starts)==3,'failing publications did not retry'
 gaps=[round(starts[i]-starts[i-1],2) for i in range(1,3)];say('Real crashed-publication retry gaps: '+str(gaps))
 assert all(g>=10 for g in gaps),('publication failure caused a retry storm',gaps)
 assert read(p/'state/heartbeat.json')['generated_epoch']==old,'crashed publication replaced prior ledger'
 stop(c);results.append(dict(name='Real local watcher retains a throttled retry interval after actual heartbeat processes fail against an overdue synthetic ledger',result='pass',live=True,evidence='live-watcher.log; watch-retry.err',reason='Real heartbeat processes were observed and killed in the disposable watcher process group; scheduler and prior ledger remained live.'))
try:
 for name,f in ([('failed publication retries',retry)] if sys.argv[1:]==['retry'] else [('watcher and summary load pacing',cadence),('failed publication retries',retry)]):
  say('SCENARIO '+name)
  try:f()
  except Exception as e:
   say('FAIL '+repr(e));results.append(dict(name=name,result='fail',live=True,evidence='live-watcher.log',reason=str(e)))
finally:
 for c,o,r in children:stop(c);o.close();r.close()
 shutil.rmtree(LAB);(E/('live-watcher-retry-results.json' if sys.argv[1:]==['retry'] else 'live-watcher-results.json')).write_text(json.dumps(results,indent=2)+'\n');say('All owned watcher groups stopped; disposable homes removed.');log.close()
sys.exit(0 if all(r['result']=='pass' for r in results) else 1)
