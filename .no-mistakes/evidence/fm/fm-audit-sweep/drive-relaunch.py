import pathlib,subprocess,os,tempfile,time,shutil,json,threading,traceback
R=pathlib.Path.cwd();E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE');W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-relaunch-',dir=str(R)));h=W/'home';log=(E/'live-relaunch-transcript.log').open('w');started=False;result={};old=None
def say(x):log.write(str(x)+'\n');log.flush();print(x,flush=True)
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_')) or k in ('TMUX','TMUX_PANE'):e.pop(k,None)
e['FM_HOME']=str(h)
def run(cmd,ee=None):
 p=subprocess.run(cmd,env=ee or e,text=True,capture_output=True,timeout=40);say('$ '+' '.join(cmd)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode));assert p.returncode==0;return p.stdout.strip()
def tm(*a):return run(['bash','bin/fm-lab-home.sh','tmux',str(h)]+list(a))
try:
 run(['bash','bin/fm-lab-home.sh','create',str(h)]);z=W/'zsh';z.mkdir();(z/'.zshrc').write_text('PS1="lab> "\n');e['ZDOTDIR']=str(z)
 tm('new-session','-d','-s','primary','-x','140','-y','40','-c',str(R),'/bin/zsh','-f');started=True;target=tm('display-message','-p','#{pane_id}');sock=tm('display-message','-p','#{socket_path}');ee=e.copy();ee.update(TMUX=sock+',1,0',TMUX_PANE=target)
 pidfile=W/'old.pid';tm('send-keys','-t',target,'-l',f'/bin/sh -c \'echo $$ > "{pidfile}"; exec sleep 120\'');tm('send-keys','-t',target,'Enter')
 deadline=time.monotonic()+10
 while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.1)
 old=int(pidfile.read_text());tm('send-keys','-t',target,'-l','stale-input')
 say('BEFORE PREPARATION:\n'+tm('capture-pane','-p','-t',target))
 # The real old foreground process exits while the real adapter waits.
 killer=threading.Timer(.6,lambda:os.kill(old,15));killer.start()
 try:run(['bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_prepare_relaunch "$2"; fm_backend_tmux_send_text_line "$2" "printf \'result:%s\\n\' replacement-ready"','local-proof',str(R),target],ee)
 finally:killer.join()
 deadline=time.monotonic()+10;screen=''
 while time.monotonic()<deadline:
  screen=tm('capture-pane','-p','-t',target)
  if 'result:replacement-ready' in screen:break
  time.sleep(.1)
 say('AFTER PREPARATION AND REPLACEMENT:\n'+screen);assert 'result:replacement-ready' in screen and 'stale-input' not in screen and 'zsh: terminated' not in screen
 result={'name':'real tmux/zsh relaunch preparation waits for foreground exit, clears stale input, and executes replacement','pass':True}
except Exception:
 say(traceback.format_exc());result={'name':'relaunch live driver','pass':False}
finally:
 if started:
  try:tm('kill-server');run(['bash','bin/fm-lab-home.sh','teardown',str(h)])
  except Exception as ex:say(str(ex))
 shutil.rmtree(W);(E/'live-relaunch-results.json').write_text(json.dumps(result,indent=2));log.close()
if not result.get('pass'):raise SystemExit(1)
