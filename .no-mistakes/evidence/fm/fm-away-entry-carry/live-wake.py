import os,pathlib,tempfile,subprocess,time,json,shutil,shlex,traceback
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M87XC201TK1ENP8GG60A85AH');lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir='/tmp')).resolve();log=open(E/'natural-wake.log','w')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('NO_MISTAKES_GATE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','PI_CODING_AGENT','HERDR_SESSION','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID','ORCA_TERMINAL_HANDLE')}
env|={'FM_HOME':str(lab),'TMUX_TMPDIR':str(lab/'tmux'),'FM_POLL':'1','FM_SIGNAL_GRACE':'0','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_SUPERVISION_HOST_PRIMARY':'claude','FM_SUPERVISION_HOST_PARK_SECONDS':'60','FM_SUPERVISION_HOST_PARK_LIMIT':'400','FM_SUPERVISION_HOST_TURN_TIMEOUT':'180'}
def run(cmd,check=True):
 p=subprocess.run(cmd,cwd=R,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
 log.write('$ '+shlex.join(cmd)+'\n'+p.stdout+f'\n[exit {p.returncode}]\n');log.flush()
 if check:assert p.returncode==0,p.stdout
 return p
T=['tmux','-L','fm-lab']
started=False
result={'name':'natural-wake','live':False,'result':'untested','evidence':str(E/'natural-wake.log'),'reason':''}
try:
 run([str(R/'bin/fm-lab-home.sh'),'create',str(lab)]);(lab/'tmux').mkdir()
 (lab/'config/supervision-host').write_text('claude sonnet\n')
 (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
 (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 (lab/'state/demo.meta').write_text('project=demo\nwindow=fm-lab-demo\nbackend=tmux\nharness=claude\nkind=scout\n')
 run([str(R/'bin/fm-afk-launch.sh'),'enter','--words','Watch the isolated local demo status. When demo finishes, inspect and record that outcome. Merge nothing, dispatch nothing, send nothing, and leave the demo records for this test to inspect.'])
 prompt='This is an assigned isolated live product Test, not a supervisor session. FM_HOME is the disposable marked lab home. Do not run fm-session-start or any fleet intake. Run exactly this one Bash command from the current directory and wait for it to finish: bin/fm-lock.sh && bin/fm-supervision-host.sh park > "$FM_HOME/host.out" 2>&1; result=$?; printf "%s\\n" "$result" > "$FM_HOME/host.rc". After it finishes reply only with its exit status. Do not run other commands or edit anything.'
 cmd=['claude','-p','--model','sonnet','--dangerously-skip-permissions','--setting-sources','','--settings','{"disableAllHooks":true}','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','Bash','--system-prompt','You are a test execution assistant. Execute only the user-specified command against the disposable FM_HOME and wait for its result. Do not read unrelated files, start agents, or run session startup. Never modify real fleet data.',prompt]
 run(T+['new-session','-d','-s','primary','-x','140','-y','40','-c',str(R),'-e','FM_HOME='+str(lab),shlex.join(cmd)+' > '+shlex.quote(str(lab/'primary.out'))+' 2>&1']);started=True
 deadline=time.time()+100
 while time.time()<deadline:
  if (lab/'state/.last-watcher-beat').exists():break
  if (lab/'host.rc').exists():raise RuntimeError('Primary host exited before watcher readiness')
  time.sleep(1)
 else:raise RuntimeError('Real Claude primary did not start watcher within 100 seconds')
 result['live']=True
 with (lab/'state/demo.status').open('a') as f:f.write(f'done [at={int(time.time())}]: local demo verification completed; no work remains\n')
 log.write('NATURAL INPUT: appended done status after real watcher readiness.\n');log.flush()
 deadline=time.time()+260
 while time.time()<deadline:
  ledger=lab/'state/.supervision-host.log'
  text=ledger.read_text() if ledger.exists() else ''
  if '\thandled\t' in text or '\tfailed\t' in text or (lab/'host.rc').exists():break
  time.sleep(1)
 ledger=lab/'state/.supervision-host.log';text=ledger.read_text() if ledger.exists() else ''
 assert '\thandled\t' in text and 'posture=away' in text,'No completed handled away turn: '+text
 outcomes=(lab/'state/branch-outcomes.jsonl').read_text();assert any(json.loads(line)['task']=='demo' for line in outcomes.splitlines()),outcomes
 queue=lab/'state/.wake-queue';assert not queue.exists() or 'demo.status' not in queue.read_text(),'Wake remained queued'
 assert not (lab/'host.rc').exists(),'Handled wake reached primary before park boundary'
 result|={'result':'pass','reason':'Real Claude primary on private fm-lab tmux socket; real watcher observed a synthetic done status, real Claude supervision engine handled it under the recorded away mandate, recorded an outcome and acknowledged its wake.'}
 # Await the bounded real host so all its watcher and engine descendants are reaped.
 deadline=time.time()+180
 while not (lab/'host.rc').exists() and time.time()<deadline:time.sleep(1)
 assert (lab/'host.rc').exists(),'Host did not finish its configured park boundary'
 assert (lab/'host.rc').read_text().strip()=='0','Host exit was not clean'
except Exception as e:
 log.write(traceback.format_exc());log.flush();result['reason']=str(e)
 result['result']='fail' if result['live'] else 'untested'
finally:
 for name in ('primary.out','host.out','host.rc','state/.supervision-host.log','state/branch-outcomes.jsonl','state/.wake-queue','state/.supervision-host-turn','state/.supervision-host-engine'):
  p=lab/name
  if p.is_file():log.write('\nPERSISTED '+name+'\n'+p.read_text(errors='replace')+'\n')
 if started:
  run(T+['capture-pane','-p','-t','primary'],False)
  # Stop the lab host before its harness, then stop only the private tmux server.
  p=lab/'state/.supervision-host'
  if p.exists():
   for line in p.read_text().splitlines():
    row=line.split('\t')
    if row[0]=='host':
     try:os.kill(int(row[1]),15)
     except ProcessLookupError:pass
   time.sleep(3)
  run(T+['kill-server'],False)
 log.flush();log.close();(E/'natural-wake-result.json').write_text(json.dumps(result,indent=2))
 shutil.rmtree(lab)
 print(json.dumps(result),flush=True)
