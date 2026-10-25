import pathlib,json,subprocess,time
E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5SR4CY3DAZS9MTQQYD0FDZG')
l=pathlib.Path((E/'lab-path.txt').read_text());p=next((l/'xdgdata/muse/sessions').glob('*/*/*/*/session.jsonl'))
rows=[json.loads(s) for s in p.read_text().splitlines()]
runs={}; calls=[]; results=[]
for x in rows:
 q=x.get('payload',{});ev=q.get('event',{});kind=ev.get('kind');rid=q.get('run_id');at=x.get('recorded_at')
 if q.get('kind')=='run' and kind in ('started','terminal'):
  runs.setdefault(rid,{})[kind]={'at':at,'event':ev}
 if kind=='assistant_tool_calls_committed':
  for c in ev['tool_calls']:
   calls.append({'run':rid,'at':at,'name':c['name'],'args':json.loads(c['args'])})
 if kind=='tool_result_batch_committed':
  for r in ev['results']:
   try: results.append({'run':rid,'at':at,'result':json.loads(r['text'])})
   except ValueError: pass
completed=[(rid,r) for rid,r in runs.items() if 'terminal' in r]
wakes=[(rid,r) for rid,r in completed if r['started']['event'].get('prompt')=='']
assert len(wakes)==3, ('expected two custom check completions plus monitor failure',len(wakes))
cycle_details=[]
for rid,r in wakes:
 rc=[x for x in calls if x['run']==rid];commands=[x['args'].get('command') for x in rc if x['name']=='bash']
 assert commands[0]=='bin/fm-wake-drain.sh',commands
 assert len([c for c in commands if c and c.startswith('bin/fm-wake-drain.sh --ack-through ')])==1,commands
 assert commands[-1]=='bin/fm-watch-arm.sh',commands
 assert len([c for c in commands if c=='bin/fm-watch-arm.sh'])==1,commands
 assert not any(x['name']=='bash_input' for x in rc),rc
 arm=next(x for x in rc if x['args'].get('command')=='bin/fm-watch-arm.sh')
 assert arm['args'].get('yield_time_ms',0)<=15000,arm
 cycle_details.append({'run':rid,'seconds':round((r['terminal']['at']-r['started']['at'])/1e6,3),'commands':commands})
background=[x for x in results if x['result'].get('execution_state')=='background_running' and x['result'].get('command')=='bin/fm-watch-arm.sh']
assert len(background)==4, len(background)
assert all('watcher: started pid=' in x['result'].get('output','') for x in background),background
assert not (l/'state/.wake-queue').read_text().strip(), 'Wake queue not acknowledged'
lock_pid=int((l/'state/.lock').read_text());watch_pid=int((l/'state/.watch.lock/pid').read_text())
ps=subprocess.check_output(['ps','-p',str(lock_pid)+','+str(watch_pid),'-o','pid,ppid,command'],text=True)
assert 'muse-bin-1.4.13' in ps and '/bin/fm-watch.sh' in ps,ps
chat=[r for rid,r in completed if r['started']['event'].get('prompt','').startswith('Captain message')]
assert len(chat)==1
follow=[r for rid,r in completed if r['started']['event'].get('prompt','').startswith('Captain follow-up')]
assert len(follow)==1,'Post-recovery follow-up has not finished'
pane=(E/'final-proof-pane.txt').read_text()
assert '◆ Captain, CAPTAIN_MSG_OK' in pane,pane
assert '◆ Captain, CAPTAIN_AFTER_RECOVERY_OK' in pane,pane
assert 'LAB_EVENT_ONE handled and acknowledged' in pane and 'LAB_EVENT_TWO handled and acknowledged' in pane,pane
startup=[x for x in calls if 'bin/fm-session-start.sh' in x['args'].get('command','')]
assert len(startup)==1,startup
assert 'Exit status: 1' in (E/'secondmate-refusal.txt').read_text()
report={'revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'muse':'1.4.13-R6996.1','terminal':'140x45 private tmux fm-lab','session_start_calls':1,'background_cycle_starts':len(background),'completed_notification_cycles':cycle_details,'captain_message_turn_seconds':round((chat[0]['terminal']['at']-chat[0]['started']['at'])/1e6,3),'followup_turn_seconds':round((follow[0]['terminal']['at']-follow[0]['started']['at'])/1e6,3),'unacknowledged_wakes':0,'lock_pid':lock_pid,'healthy_watcher_pid':watch_pid,'processes':ps,'result':'All live observations verified'}
(E/'live-observations.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
