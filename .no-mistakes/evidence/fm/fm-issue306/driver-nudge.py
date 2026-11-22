import pathlib,subprocess,os,json,time,shutil,tempfile,uuid
ROOT=pathlib.Path.cwd();EV=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='nudge-',dir=ROOT/'.test306'))
log=(EV/'live-nudge.log').open('w',buffering=1)
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','NM_','TMUX')):env.pop(k)
env.update(FM_HOME=str(LAB),DISABLE_AUTOUPDATER='1')
def run(cmd,timeout=120):
 p=subprocess.run(list(map(str,cmd)),env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 log.write('$ '+' '.join(map(str,cmd))+'\n'+p.stdout+f'\nEXIT_STATUS={p.returncode}\n');return p
sock=None
try:
 assert run(['bash','bin/fm-lab-home.sh','create',LAB]).returncode==0
 sock=run(['bash','bin/fm-lab-home.sh','tmux-dir',LAB]).stdout.strip()
 env['TMUX_TMPDIR']=sock
 def tmux(*args):return run(['tmux','-f','/dev/null','-L','fm-lab',*args])
 sid=str(uuid.uuid4())
 p=tmux('new-session','-d','-s','primary','-x','160','-y','45','-c',ROOT,'-e','FM_HOME='+str(LAB),'env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','claude','--tools','','--settings','{"disableAllHooks":true}','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--session-id',sid)
 assert p.returncode==0,p.stdout
 pane=tmux('list-panes','-t','primary','-F','#{pane_id} #{pane_pid} #{socket_path} #{pid}').stdout.strip().split()
 target,pid,socket,server= pane
 env['TMUX']=socket+','+server+',0';env['TMUX_PANE']=target
 screen=''
 for i in range(30):
  screen=tmux('capture-pane','-p','-t','primary').stdout
  if 'trust this folder' in screen.lower():tmux('send-keys','-t','primary','Enter')
  if '❯' in screen:break
  time.sleep(1)
 (EV/'live-primary-screen.txt').write_text(screen)
 (LAB/'config/watchdog').write_text('mode=act\nmodels=\ncouncil-seats=\nquota-guard=off\nmemory-guard=off\nrestart=off\nkey-settle-secs=1\n')
 (LAB/'state/.lock').write_text(pid+'\n');(LAB/'state/.lock-session').write_text(sid+'\n')
 now=int(time.time())
 (LAB/'state/heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','generated_epoch':now,'primary':{'terminal':{'backend':'tmux','target':target,'present':True},'session':{'trusted_id':sid},'writer':{'anchor_pid':int(pid),'session_id':sid}}}))
 (LAB/'state/t1.status').write_text(f'needs-decision [at={now-9000}] [key=nm-flake]: G3 Casco #562 no-mistakes test awaiting_approval. A approve the park, B schedule a low-load rerun?\n')
 p=run(['bash','bin/fm-watchdog.sh','once']);assert p.returncode==0,p.stdout
 status=run(['bash','bin/fm-watchdog.sh','status']).stdout
 ledger=LAB/'state/watchdog/actions.tsv'
 if ledger.exists():log.write('\nACTION LEDGER:\n'+ledger.read_text())
 screen=tmux('capture-pane','-p','-t','primary').stdout
 (EV/'live-primary-after-nudge.txt').write_text(screen)
 assert 'PR #562' in status or (ledger.exists() and 'PR #562' in ledger.read_text()),status
 log.write('\nOBSERVED: watchdog status/action names PR #562 from a G3 alias record.\n')
finally:
 if sock:
  run(['tmux','-f','/dev/null','-L','fm-lab','kill-server'])
  run(['bash','bin/fm-lab-home.sh','teardown',LAB])
 shutil.rmtree(LAB)
 log.write('\nTEARDOWN: private primary stopped; disposable lab removed.\n');log.close()
