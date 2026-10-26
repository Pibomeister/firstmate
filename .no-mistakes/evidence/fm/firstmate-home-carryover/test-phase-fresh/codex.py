import os, pathlib, subprocess, shutil, json, time, shlex
R=pathlib.Path.cwd(); E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5TWX28QV7MK1HBVJB807Z3Q/test-phase-fresh'); L=R/'.c'; L.mkdir(mode=0o700)
for n in ['home','codex','project','tmp']: (L/n).mkdir(mode=0o700)
auth=pathlib.Path.home()/'.codex/auth.json'
if auth.is_file(): shutil.copyfile(auth,L/'codex/auth.json'); (L/'codex/auth.json').chmod(0o600)
(L/'codex/config.toml').write_text('[projects.'+json.dumps(str(L/'project'))+']\ntrust_level = "trusted"\n')
subprocess.run(['git','init','-q',str(L/'project')],check=True)
env=dict(os.environ,HOME=str(L/'home'),CODEX_HOME=str(L/'codex'),TMPDIR=str(L/'tmp'),TERM='xterm-256color')
for k in list(env):
 if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE']: env.pop(k,None)
socket=str(L/'t'); rec=[]
def tm(*args):
 p=subprocess.run(['tmux','-S',socket,*args],cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
 if p.returncode: raise RuntimeError(p.stdout)
 return p.stdout
def capture(name):
 text=tm('capture-pane','-p','-t','fm-lab-codex'); ansi=tm('capture-pane','-e','-p','-t','fm-lab-codex'); (E/(name+'.txt')).write_text(text); (E/(name+'.ansi')).write_text(ansi); return text
try:
 tm('-f','/dev/null','new-session','-d','-s','fm-lab-codex','-x','116','-y','36','-c',str(L/'project'),'codex --no-alt-screen')
 time.sleep(6); text=capture('codex-start'); print(text,flush=True)
 # Wait for parent inspection. This script only starts and captures; a second command drives drafts.
 (E/'codex-running.json').write_text(json.dumps(dict(socket=socket,lab=str(L),env={k:env[k] for k in ['HOME','CODEX_HOME','TMPDIR','TERM']},start_command='codex --no-alt-screen'),indent=2))
except Exception:
 try: tm('kill-server')
 except Exception: pass
 shutil.rmtree(L); raise
