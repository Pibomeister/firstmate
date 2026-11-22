import pathlib,subprocess,tempfile,os,time,shutil,json,traceback,uuid,signal
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE');W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-watchdog-',dir=str(R)));h=W/'home';log=(E/'live-watchdog-transcript.log').open('w');result={};started=False
class SetupUnavailable(Exception):pass
def say(x):log.write(str(x)+'\n');log.flush();print(x,flush=True)
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_')) or k in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):e.pop(k,None)
e['FM_HOME']=str(h)
def run(cmd,ee=None,want=0,timeout=60):
 p=subprocess.run(cmd,env=ee or e,text=True,capture_output=True,timeout=timeout);say('$ '+' '.join(cmd)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode));
 if want is not None:assert p.returncode==want
 return p.stdout.strip()
def tm(*args):return run(['bash','bin/fm-lab-home.sh','tmux',str(h)]+list(args))
try:
 run(['bash','bin/fm-lab-home.sh','create',str(h)]);sid=str(uuid.uuid4());config=W/'claude-config';config.mkdir();(config/'.claude.json').write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'light'}))
 # Bare mode reads no OAuth/keychain. No fake API key, login, or model service is supplied.
 launch=['env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','-u','ANTHROPIC_API_KEY','-u','CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_CONFIG_DIR='+str(config),'FM_HOME='+str(h),shutil.which('claude'),'--bare','--session-id',sid]
 tm('new-session','-d','-s','primary','-x','160','-y','45','-c',str(R),*launch);started=True
 target=tm('display-message','-p','#{pane_id}');sock=tm('display-message','-p','#{socket_path}');ee=e.copy();ee.update(TMUX=sock+',1,0',TMUX_PANE=target)
 deadline=time.monotonic()+40;screen=''
 while time.monotonic()<deadline:
  try:screen=tm('capture-pane','-p','-t',target)
  except Exception:break
  if 'Allow external CLAUDE.md file imports?' in screen:
   tm('send-keys','-t',target,'Enter');time.sleep(1);continue
  if 'Yes, I trust this folder' in screen:
   tm('send-keys','-t',target,'Down','Enter');time.sleep(1);continue
  if 'Claude Code v' in screen and any(line.strip()=='❯' for line in screen.splitlines()):break
  time.sleep(1)
 say('ACTUAL CLAUDE SCREEN:\n'+screen)
 if not ('Claude Code v' in screen and any(line.strip()=='❯' for line in screen.splitlines())):raise SetupUnavailable('Installed Claude --bare did not expose a composer without authentication; actual terminal screen retained.')
 # A tty input fault, rather than a mocked tmux transport, swallows CR before the real TUI reads it.
 tty=tm('display-message','-p','-t',target,'#{pane_tty}');run(['stty','-f',tty,'igncr'])
 pid=int(tm('display-message','-p','-t',target,'#{pane_pid}'));st=h/'state';(st/'.lock').write_text(str(pid)+'\n');(st/'.lock-session').write_text(sid+'\n');base=int(time.time())
 (st/'heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','published_epoch':base,'generated_epoch':base,'primary':{'terminal':{'backend':'tmux','target':target,'present':True},'session':{'trusted_id':sid},'writer':{'anchor_pid':pid,'session_id':sid}}}))
 transcripts=h/'claude/projects/p';transcripts.mkdir(parents=True);tfile=transcripts/(sid+'.jsonl');tfile.write_text(json.dumps({'type':'assistant','timestamp':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(base-3000)),'message':{'content':[{'type':'text','text':'Synthetic last progress for local heartbeat proof.'}]}})+'\n');os.utime(tfile,(base-3000,base-3000))
 (h/'config/watchdog').write_text('mode=act\nmodels=\ncouncil-seats=\nquota-guard=off\nclaude-config-dirs='+str(h/'claude')+'\nheartbeat-frozen-secs=600\nrestart=on\nrestart-command=/bin/false\n')
 for off in [0,700,1000]:
  we=ee.copy();we.update(FM_TEST_SEAM='1',FM_WD_NOW=str(base+off));run(['bash','bin/fm-watchdog.sh','once'],we,timeout=120)
  actions=st/'watchdog/actions.tsv';say('PERSISTED WATCHDOG ACTIONS:\n'+(actions.read_text() if actions.exists() else '<none>'))
 actions=(st/'watchdog/actions.tsv').read_text();say('ACTUAL CLAUDE COMPOSER AFTER SWALLOWED ENTER:\n'+tm('capture-pane','-p','-t',target))
 rows=[r.split('\t') for r in actions.splitlines()];assert any(r[4:7]==['heartbeat-frozen','nudge','pending'] for r in rows)
 assert not any(r[4:7]==['heartbeat-frozen','nudge','done'] for r in rows)
 assert not any(r[4]=='heartbeat-frozen' and r[5]=='restart' and r[6]=='pending' for r in rows)
 result={'name':'real watchdog and Claude TUI: tty ignores Enter, pending composer earns no delivery receipt or restart','result':'pass','live':True}
except SetupUnavailable as ex:
 say(str(ex));result={'name':'real watchdog heartbeat delivery against Claude TUI','result':'untested','live':False,'reason':str(ex)}
except Exception:
 say(traceback.format_exc());result={'name':'watchdog live driver','result':'setup-failed','live':False}
finally:
 if started:
  try:tm('kill-server');run(['bash','bin/fm-lab-home.sh','teardown',str(h)])
  except Exception as ex:say('cleanup error: '+str(ex))
 shutil.rmtree(W);say('Stopped real Claude and private tmux server; disposed local state');(E/'live-watchdog-results.json').write_text(json.dumps(result,indent=2));log.close()
