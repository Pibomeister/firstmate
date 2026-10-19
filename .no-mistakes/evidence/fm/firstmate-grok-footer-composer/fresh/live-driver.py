import os, pathlib, subprocess as sp, time, json, shutil, shlex, html
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.nm-live'; EVID=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5AFK2TPKC9RPH7650Q60P7C/fresh'); HOME=LAB/'home'; USER=LAB/'user'; SOCK='.nm-live/sock'
log=[]; shots=[]; results=[]
def run(a,env=None,check=True,timeout=120,cwd=ROOT):
 p=sp.run(a,cwd=cwd,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=timeout)
 if check and p.returncode: raise RuntimeError(str(a)+': '+p.stdout)
 return p
base=os.environ.copy()
for k in list(base):
 if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ['TMUX','TMUX_PANE','FM_GATE_REFUSE_BYPASS','HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID']: base.pop(k,None)
# No operator home, trust store, session store, or login store is modified.
run(['bin/fm-lab-home.sh','create',str(HOME)],env=base)
USER.mkdir(); (USER/'.grok').mkdir(); (USER/'.codex').mkdir(); (USER/'.claude').mkdir()
for src,dst in [(pathlib.Path(os.environ['HOME'])/'.grok/auth.json',USER/'.grok/auth.json'),(pathlib.Path(os.environ['HOME'])/'.codex/auth.json',USER/'.codex/auth.json')]:
 if src.is_file(): shutil.copyfile(src,dst); dst.chmod(0o600)
# HOME isolation retains the normal macOS Claude Keychain service when CLAUDE_CONFIG_DIR is unset.
normal_config={}
(USER/'.claude.json').write_text(json.dumps({**{k:normal_config[k] for k in ['oauthAccount','userID'] if k in normal_config},'hasCompletedOnboarding':True,'theme':'dark','hasAcknowledgedCostThreshold':True}))
base.update(HOME=str(USER),FM_HOME=str(HOME),GROK_HOME=str(USER/'.grok'),CODEX_HOME=str(USER/'.codex'),FM_CONTROL_POLL='0.3',FM_CONTROL_EXIT_WAIT='20',FM_CONTROL_LAUNCH_WAIT='45',DISABLE_AUTOUPDATER='1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1')
base.pop('CLAUDE_CONFIG_DIR',None)
# Read the already-authorized normal login without changing any credential store.
credential=run(['security','find-generic-password','-s','Claude Code-credentials','-w'],check=False)
if credential.returncode==0:
 token=json.loads(credential.stdout).get('claudeAiOauth',{}).get('accessToken')
 if token:base['CLAUDE_CODE_OAUTH_TOKEN']=token
(LAB/'bin').mkdir(exist_ok=True)
realtmux=shutil.which('tmux'); (LAB/'bin/tmux').write_text('#!/bin/bash\ncd '+shlex.quote(str(ROOT))+' || exit 90\nexec '+shlex.quote(realtmux)+' -S '+shlex.quote(SOCK)+' "$@"\n'); (LAB/'bin/tmux').chmod(0o755)
base['PATH']=str(LAB/'bin')+':'+base['PATH']
def tm(*a):return run([realtmux,'-S',SOCK,*a],env=base).stdout

def capture(name,target='primary:fm-grok-live'):
 s=tm('capture-pane','-p','-t',target); (EVID/(name+'.txt')).write_text(s); shots.append((name,s));return s

def probe(target='primary:fm-grok-live'):
 return run(['bash','-c','. bin/fm-backend.sh; printf "agent="; fm_backend_agent_state tmux "$1"; printf " composer="; fm_backend_composer_state tmux "$1"; echo','probe',target],env=base).stdout.strip()
def classify(target='primary:fm-grok-live'):
 return run(['bash','-c','. bin/fm-tmux-lib.sh; fm_tmux_composer_state "$1"','probe',target],env=base).stdout.strip()
def wait_empty(target='primary:fm-grok-live',limit=45):
 for i in range(limit):
  s=tm('capture-pane','-p','-t',target)
  if 'trust this folder' in s.lower() or 'trust this directory' in s.lower():
   # Scope is the disposable fixture only; never the operator checkout.
   tm('send-keys','-t',target,'Enter')
  v=classify(target)
  if v=='empty':return
  time.sleep(1)
 raise RuntimeError('composer never empty: '+v+'\n'+s)
def record(s):
 log.append(s);print(s,flush=True);(EVID/'live-lifecycle.log').write_text('\n\n'.join(log)+'\n')
def wait_reply(harness):
 for i in range(90):
  s=tm('capture-pane','-p','-t','primary:fm-grok-live')
  if 'Allow external CLAUDE.md file imports?' in s:
   tm('send-keys','-t','primary:fm-grok-live','Enter')
  if ('• MIGRATION_READY' in s or '⏺ MIGRATION_READY' in s) and 'Working (' not in s:
   return
  time.sleep(1)
 capture(harness+'-readiness-blocker')
 raise RuntimeError(harness+' did not render the requested MIGRATION_READY reply')
PROJ=LAB/'project'; PROJ.mkdir();run(['git','init','-q',str(PROJ)],env=base);(PROJ/'README.md').write_text('Disposable migration validation.\n');run(['git','-C',str(PROJ),'add','.'],env=base);run(['git','-C',str(PROJ),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','Provide isolated migration fixture'],env=base)
WT=LAB/'wt';run(['git','-C',str(PROJ),'worktree','add','-qb','lab-task',str(WT)],env=base)
(USER/'.codex/config.toml').write_text('[projects.'+json.dumps(str(WT))+']\ntrust_level = "trusted"\n')
(HOME/'data/grok-live').mkdir();(HOME/'data/grok-live/brief.md').write_text('# Task\n## Captain\'s intent\nValidate a disposable runtime migration. Reply exactly MIGRATION_READY. Do not use tools, change files, send messages, or run commands. Then wait.\n\n## Firstmate spec\nKeep the same worktree and endpoint. No other work is authorized.\n')
(WT/'preserve.txt').write_text('uncommitted work must survive\n')
meta={'window':'primary:fm-grok-live','endpoint_task_id':'grok-live','worktree':str(WT),'project':str(PROJ),'harness':'grok','kind':'ship','mode':'no-mistakes','yolo':'off','model':'default','effort':'default','backend':'tmux','branch':'lab-task','tasktmp':str(LAB/'tasktmp')}
mp=HOME/'state/grok-live.meta';mp.write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
def control(verb,*args):
 p=run([str(ROOT/'bin/fm-control.sh'),'grok-live',verb,*args],env=base,check=False,timeout=120);record('$ bin/fm-control.sh grok-live '+verb+' '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout);return p

def launch_grok():
 cmd='cd '+shlex.quote(str(WT))+' && grok --always-approve --leader-socket leader.sock'
 tm('send-keys','-t','primary:fm-grok-live','-l',cmd);tm('send-keys','-t','primary:fm-grok-live','Enter');wait_empty()
try:
 tm('new-session','-d','-s','primary','-n','fm-grok-live','-x','72','-y','35','-c',str(ROOT),'bash --noprofile --norc')
 record('grok version: '+run(['grok','--version'],env=base).stdout.strip());record('pty grid: '+tm('display-message','-p','-t','primary:fm-grok-live','#{window_width}x#{window_height}').strip())
 launch_grok();screen=capture('grok-idle');record('real idle: '+probe())
 # Cursorless profile is the input contract used by Herdr and Orca.
 current=run(['bash','-c','. bin/fm-composer-lib.sh; fm_composer_classify_screen "$1" "$2"','probe','styled=0\ncursor=0\nidentity=1\nrows=0',screen],env=base).stdout.strip()
 prior=run(['git','show','f4061c74e2e70e73c5ca9b9283a4efb6daacde4b:bin/fm-composer-lib.sh'],env=base).stdout;(LAB/'base-composer.sh').write_text(prior)
 before=run(['bash','-c','. .nm-live/base-composer.sh; fm_composer_classify_screen "$1" "$2"','probe','styled=0\ncursor=0\nidentity=1\nrows=0',screen],env=base).stdout.strip()
 record('same fresh 72-column idle capture through cursorless public classifier: base='+before+' target='+current)
 assert current=='empty' and before=='unknown'
 tm('send-keys','-t','primary:fm-grok-live','-l','FM_DRAFT_KEEP');time.sleep(0.5);capture('grok-pending');record('typed draft: '+probe());assert classify()=='pending'
 for verb,args in [('exit',[]),('relaunch',['--harness','codex','--note','Disposable validation only.'])]:
  p=control(verb,*args);assert p.returncode!=0 and 'pending text' in p.stdout;assert 'FM_DRAFT_KEEP' in capture('grok-draft-preserved-'+verb);assert 'agent=alive' in probe()
 results.append({'name':'Pending Grok draft refuses both exit and relaunch without losing text','result':'pass','live':True})
 tm('send-keys','-t','primary:fm-grok-live','C-u');wait_empty();capture('grok-cleared');p=control('exit');assert p.returncode==0;record('after exit: '+probe());capture('grok-exited');assert 'agent=dead' in probe();assert (WT/'preserve.txt').read_text()=='uncommitted work must survive\n'
 results.append({'name':'Empty Grok composer permits verified exit and preserves uncommitted work','result':'pass','live':True})
 launch_grok();capture('grok-before-codex');p=control('relaunch','--harness','codex','--note','This is isolated migration validation. Reply MIGRATION_READY and wait. Do not use tools or modify files.');time.sleep(4);capture('codex-startup');wait_empty();wait_reply('codex');capture('codex-after-relaunch');record('after Codex relaunch: '+probe());record('published record:\n'+mp.read_text());assert p.returncode==0 and 'harness=codex' in mp.read_text();assert (WT/'preserve.txt').exists()
 results.append({'name':'Relaunch an empty Grok worker onto Codex in the same endpoint and worktree','result':'pass','live':True})
 # Prove the normal login is available under isolated HOME before trying Claude.
 auth=run(['claude','auth','status'],env=base,check=False);authdata=json.loads(auth.stdout);record('Claude existing login under isolated HOME: loggedIn='+str(authdata.get('loggedIn')))
 p=control('exit');assert p.returncode==0
 meta['harness']='grok';mp.write_text(''.join(k+'='+v+'\n' for k,v in meta.items()))
 launch_grok();capture('grok-before-claude');p=control('relaunch','--harness','claude','--note','This is isolated migration validation. Reply MIGRATION_READY and wait. Do not use tools or modify files.');time.sleep(6);capture('claude-startup');wait_reply('claude');capture('claude-after-relaunch');record('after Claude relaunch: '+probe());record('published Claude record:\n'+mp.read_text());assert p.returncode==0 and 'harness=claude' in mp.read_text();assert (WT/'preserve.txt').read_text()=='uncommitted work must survive\n'
 results.append({'name':'Relaunch an empty Grok worker onto Claude in the same endpoint and worktree','result':'pass','live':True})
except Exception as e:
 record('DRIVER STOP: '+str(e));results.append({'name':'Unfinished live driver step','result':'error','live':False})
finally:
 try:tm('kill-server');record('Private tmux server stopped.')
 except Exception as e:record('teardown: '+str(e))
 (EVID/'scenario-progress.json').write_text(json.dumps(results,indent=2))
 body=''.join('<section><h2>'+html.escape(name)+'</h2><pre>'+html.escape(s)+'</pre></section>' for name,s in shots)
 (EVID/'terminal-captures.html').write_text('<!doctype html><meta charset="utf-8"><title>Real Grok lifecycle captures</title><style>body{background:#171717;color:#eee;font:16px system-ui;padding:24px}section{margin-bottom:36px}pre{font:14px/1.35 monospace;white-space:pre;overflow:auto;background:#222;padding:20px;display:inline-block}</style><h1>Grok 1.0.62: real private terminal captures</h1><p>72 columns × 35 rows. Captured from the real running CLI; no model output is simulated.</p>'+body)
 # Preserve only evidence. Credentials, repository fixture, private socket, and session data are disposable.
 for p in LAB.iterdir():
  if p.name=='driver.py':continue
  if p.is_dir():
   for q in p.rglob('*'):
    if q.is_dir():q.chmod(q.stat().st_mode|0o700)
   shutil.rmtree(p)
  else:p.unlink()

if any(r['result'] != 'pass' for r in results): raise SystemExit(1)
