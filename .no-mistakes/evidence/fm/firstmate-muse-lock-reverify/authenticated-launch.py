import os, pathlib, subprocess, json, time
root=pathlib.Path.cwd(); lab=root/'.nm-muse-lab'
evidence=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5QN6B0CPGQ68QX3AK7G69KK')
sock='fm-lab-muse-gate-01M5QN'
def tm(*args,check=True):
 return subprocess.run(['tmux','-L',sock,*args],capture_output=True,text=True,check=check).stdout
clean=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID','PI_CODING_AGENT','GROK_AGENT','FM_PI_HARNESS','CURSOR_AGENT','CURSOR_INVOKED_AS']:
 clean.pop(k,None)
clean.update(XDG_CONFIG_HOME=str(lab/'config'),XDG_DATA_HOME=str(lab/'data'),FM_HOME=str(lab/'home'),MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL='on')
prompt=f'''This is an authorized disposable integration test. Do not read user files or run firstmate session-start. Use shell tools to execute bash {lab}/lock-probe.sh exactly once, then read lock-proof.txt at {lab}/lock-proof.txt. Next create smoke.txt containing line one, read it, append line two, read it again, and list the workspace files, using separate tool steps. Do not start subagents. Reply DONE-SMOKE.'''
ws=lab/'ws-lock'
subprocess.run(['git','init','-q',str(ws)],check=True)
subprocess.run(['tmux','-L',sock,'new-session','-d','-s','fm-lab-muse','-x','120','-y','40','-c',str(ws),'muse','--yolo','--model','muse-wonder-1.0',prompt],env=clean,check=True)
(lab/'socket').write_text(sock)
print('Launched real Muse with 120x40 terminal; stored login metadata with Keychain lookup, isolated config/data.',flush=True)
