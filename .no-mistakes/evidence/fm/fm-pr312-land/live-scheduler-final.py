import os, json, time, subprocess, pathlib, signal, threading, shutil, traceback
R=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M816SJHG88GY66TXQVTDXJXE')
L=R/'.test-idle-live'
log=(E/'scheduler-final-transcript.log').open('w', buffering=1)
results=[]
children=[]
def say(s):
 print(s,flush=True); print(s,file=log,flush=True)
def env(home, **kw):
 e={k:v for k,v in os.environ.items() if not k.startswith(('FM_','ORCA_','REX_','HERDR_','CLAUDE_','CODEX_')) and k not in ('TMUX','TMUX_PANE','BASH_ENV','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
 e.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',FM_HOME=str(home),CLAUDE_CONFIG_DIR=str(home/'claude'),NM_HOME=str(home/'nm'))
 e.update({k:str(v) for k,v in kw.items()}); return e
def run(args,home,check=True,**kw):
 p=subprocess.run([str(x) for x in args],cwd=R,env=env(home,**kw),capture_output=True,text=True,timeout=90)
 say('$ '+' '.join(str(x).replace(str(R),'$WORKTREE') for x in args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode))
 if check: assert p.returncode==0
 return p

def home(name):
 h=L/name
 run(['bin/fm-lab-home.sh','create',h],h)
 (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
 return h

def atomic(p,obj):
 q=p.with_suffix('.next'); q.write_text(json.dumps(obj)); os.replace(q,p)
def rows(h):
 p=h/'state/stall-ledger.tsv'
 return [r.split('\t') for r in p.read_text().splitlines() if len(r.split('\t'))==10] if p.exists() else []
def observe(h,n): return run(['bin/fm-stall-ledger.sh','observe'],h,FM_TEST_SEAM=1,FM_NOW=n,FM_STALL_LEDGER_MIN_SECS=0)
def record(name,fn):
 try: fn(); results.append(dict(name=name,result='pass',live=True)); say('SCENARIO PASS: '+name)
 except Exception as e: results.append(dict(name=name,result='fail',live=True,reason=str(e))); say('SCENARIO FAIL: '+name+'\n'+traceback.format_exc())
 (E/'scheduler-final-results.json').write_text(json.dumps(results,indent=2))

def fresh_boundary():
 h=home('freshness')
 run(['bin/fm-heartbeat.sh','--write'],h,FM_HEARTBEAT_CYCLE_SECS=900)
 doc=json.loads((h/'state/heartbeat.json').read_text())
 say('actual published heartbeat: '+json.dumps({k:doc[k] for k in ['schema','generated_epoch','published_epoch','stale_after_secs','failure']}))
 assert doc['stale_after_secs']==1371 and doc['failure'] is None
 shutil.copy(h/'state/heartbeat.json',E/'real-heartbeat.json')
 p=doc['published_epoch']; b=doc['stale_after_secs']
 for age in [601,900,b]:
  observe(h,p+age)
  assert not any(r[1]=='stall-open' for r in rows(h))
  say('age '+str(age)+': no stall through inclusive bound '+str(b))
 observe(h,p+b+1)
 assert any(r[1]=='stall-open' and int(r[5])==p+b+1 for r in rows(h))
 bad=run(['bin/fm-stall-ledger.sh','score','--since',str(p+b+1),'--until',str(p+b+2)],h,check=False,FM_TEST_SEAM=1,FM_NOW=p+b+2)
 assert bad.returncode==1 and 'heartbeat-age' in bad.stdout
 doc['published_epoch']=p+b+2; doc['generated_epoch']=p+b+2
 atomic(h/'state/heartbeat.json',doc); observe(h,p+b+2)
 assert any(r[1]=='stall-close' and int(r[7])==p+b+2 for r in rows(h))
 shutil.copy(h/'state/stall-ledger.tsv',E/'freshness-ledger.tsv')
 for cls,bound in [('legacy',None),('short-bound',30)]:
  q=home(cls); atomic(q/'state/heartbeat.json',dict(published_epoch=p,stale_after_secs=bound))
  observe(q,p+600); assert not any(r[1]=='stall-open' for r in rows(q))
  observe(q,p+601); assert any(r[1]=='stall-open' for r in rows(q))
  say(cls+': 600-second floor passes at 600 and expires at 601')


def coherent():
 n=int(time.time()); h=home('atomic-owner'); m=home('atomic-mate')
 (h/'state/mate.meta').write_text('kind=secondmate\nhome='+str(m)+'\n')
 expected={n+801,n+772}
 for key in ['published_epoch','generated_epoch']:
  stop=threading.Event(); counts=[0]
  def writer():
   while not stop.is_set():
    for target in [h,m]:
     atomic(target/'state/heartbeat.json',{key:n-1000,'stale_after_secs':1800})
     atomic(target/'state/heartbeat.json',{'published_epoch':n,'generated_epoch':n,'stale_after_secs':771})
    counts[0]+=1; time.sleep(.002)
  t=threading.Thread(target=writer); t.start()
  try:
   for i in range(8): observe(h,n+i)
  finally: stop.set(); t.join()
  for r in rows(h):
   if r[1]=='hb': assert int(r[5]) in expected, r
  assert not any(r[1]=='stall-open' for r in rows(h))
  say(key+': '+str(counts[0])+' pairs of real atomic replacements; primary and secondmate samples retain one valid timestamp/deadline pair')
  # clear only generated local output so the fallback variant gets fresh samples
  shutil.copy(h/'state/stall-ledger.tsv',E/('atomic-'+key+'.tsv'))
  for f in ['stall-ledger.tsv','.stall-ledger-last-observe']:
   (h/'state'/f).unlink(missing_ok=True)


def scheduler():
 h=home('scheduler-final'); pubs=[]; summaries=[]; beats=set(); seen=set(); sumseen=set()
 out=(E/'watcher-stdout.log').open('w'); err=(E/'watcher-stderr.log').open('w')
 e=env(h,FM_POLL='.2',FM_SIGNAL_GRACE=30,FM_HEARTBEAT_LEDGER_IDLE_SECS=24,FM_HEARTBEAT_LEDGER_JITTER=0,FM_HOME_SUMMARY_INTERVAL=24,FM_HOME_SUMMARY_JITTER=0,FM_CHECK_INTERVAL=9999999,FM_HEARTBEAT=9999999,FM_WATCH_MANAGED_HOLD=1)
 p=subprocess.Popen(['bin/fm-watch.sh'],cwd=R,env=e,stdout=out,stderr=err,start_new_session=True); children.append(p)
 start=time.monotonic()
 def sample(seconds,until=None):
  deadline=time.monotonic()+seconds
  while time.monotonic()<deadline:
   assert p.poll() is None,'watcher exited '+str(p.returncode)
   for file,arr,keys in [('heartbeat.json',pubs,seen),('home-summary.json',summaries,sumseen)]:
    try:
     doc=json.loads((h/'state'/file).read_text()); k=doc.get('published_epoch',doc.get('generated_epoch'))
     if k not in keys:
      keys.add(k); arr.append((time.monotonic()-start,doc)); say(file+' '+json.dumps({x:doc.get(x) for x in ['generated_epoch','published_epoch','stale_after_secs','failure']}))
    except (OSError,ValueError): pass
   try: beats.add((h/'state/.last-watcher-beat').stat().st_mtime_ns)
   except OSError: pass
   if until and until(): return
   time.sleep(.1)
  if until: assert until(),'timed out waiting for real publication'
 try:
  sample(240,lambda:len(pubs)>=3 and len(summaries)>=2)
  gaps=[pubs[i][1]['generated_epoch']-pubs[i-1][1]['generated_epoch'] for i in range(1,len(pubs))]
  say('real collection start gaps='+str(gaps)+'; independently observed liveness beats='+str(len(beats)))
  (E/'idle-publications.json').write_text(json.dumps(dict(heartbeats=[dict(observed_seconds=round(t,3),document=d) for t,d in pubs],summaries=[dict(observed_seconds=round(t,3),document=d) for t,d in summaries],distinct_beats=len(beats)),indent=2))
  assert min(gaps)>=23, gaps
  assert len(beats)>2,len(beats)
  say('unchanged home: collection start gaps='+str(gaps)+'; distinct watcher beats='+str(len(beats)))
 finally:
  p.terminate()
  try: p.wait(timeout=15)
  except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
  # Finish any collector already launched, then terminate only this disposable process group.
  time.sleep(12)
  try: os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError: pass
  out.close(); err.close()
  say('watcher stopped and reaped, exit='+str(p.returncode))

record("Real watcher and real collectors retain fractional polling and collect on idle deadlines",scheduler)
log.close()
