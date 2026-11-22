import pathlib,subprocess,tempfile,os,shutil,json,traceback
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE'); W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-handoff-',dir=str(R))); h=W/'home'; log=(E/'live-handoff-transcript.log').open('w'); result={}
def say(x):log.write(str(x)+'\n');log.flush();print(x,flush=True)
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_')) or k in ('TMUX','TMUX_PANE'):e.pop(k,None)
e['FM_HOME']=str(h)
def run(cmd,extra=None):
 say('$ '+' '.join(cmd));p=subprocess.run(cmd,env=dict(e,**(extra or {})),text=True,capture_output=True,timeout=100);say(p.stdout);say(p.stderr);say('exit='+str(p.returncode));return p
try:
 assert run(['bash','bin/fm-lab-home.sh','create',str(h)]).returncode==0
 tools=W/'tools';tools.mkdir()
 for name in ('tmux','codex'): (tools/name).symlink_to(shutil.which(name))
 # An isolated PATH with actual executables keeps quota-axi absent, so no operator quota store is read.
 e['PATH']=str(tools)+':/usr/bin:/bin:/usr/sbin:/sbin';e['FM_BACKEND']='tmux';e['TMUX_TMPDIR']=str(W/'tmux');(W/'tmux').mkdir()
 # No server is needed: the injected TERM is before any endpoint launch.
 (h/'config/crew-harness').write_text('codex\n'); (h/'data/handoff.md').write_text('# Local handoff proof\nThere are no open orders in this disposable home.\n')
 assert run(['bash','bin/fm-lock.sh']).returncode==0
 (h/'state/.handoff-launch-failed').write_text('at=1 pid=1 nonce=none attempt=0 reason=old-record\n')
 fault=W/'fault.sh'; fault.write_text('''trap 'case "$BASH_COMMAND" in rm\\ -f*handoff-successor*handoff-launch-failed*) printf "TERM at failure-record removal boundary\\n" > "$FM_HOME/state/fault-delivered"; kill -TERM "$$" ;; esac' DEBUG
''')
 p=run(['bash','bin/fm-handoff-launch.sh','--harness','codex',str(h/'data/handoff.md')],{'BASH_ENV':str(fault)})
 assert p.returncode!=0
 delivered=(h/'state/fault-delivered').read_text();record=(h/'state/.handoff-launch-failed').read_text();say(delivered);say('PERSISTED FAILURE RECORD: '+record)
 assert 'reason=interrupted' in record and 'attempt=0' in record and 'pid=1 ' not in record
 assert not (h/'state/.handoff-pending').exists(); say('No handoff attempt started; predecessor still owns disposable home lock '+(h/'state/.lock').read_text())
 result={'name':'interrupt handoff at failure-record removal boundary retains current failure and predecessor lock','pass':True}
except Exception:
 say(traceback.format_exc());result={'name':'handoff live driver','pass':False}
finally:
 shutil.rmtree(W);say('Disposed lab home and fault-injection environment');(E/'live-handoff-results.json').write_text(json.dumps(result,indent=2));log.close()
if not result.get('pass'): raise SystemExit(1)
