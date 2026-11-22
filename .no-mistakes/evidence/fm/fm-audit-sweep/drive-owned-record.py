import pathlib,subprocess,os,time,json,traceback
E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE');log=(E/'live-owned-record-transcript.log').open('w'); root=None;child=None;result={}
def say(s):log.write(str(s)+'\n');log.flush();print(s,flush=True)
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_','XDG_')):e.pop(k,None)
def run(*args,want=0):
 p=subprocess.run(['bash','bin/fm-herdr-lab.sh']+list(args),env=e,text=True,capture_output=True,timeout=40);say('$ bin/fm-herdr-lab.sh '+' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode));assert p.returncode==want;return p.stdout.strip()
try:
 root=pathlib.Path(run('fixture','create'));child=subprocess.Popen(['/bin/sleep','120']);start=subprocess.check_output(['ps','-p',str(child.pid),'-o','lstart='],text=True).strip();token=(root/'.fm-herdr-owned').read_text().strip()
 record=root/'owned.record';record.write_text(f'schema=fm-herdr-owned-xdg.v1\nxdg_root={root}\nmarker_token={token}\npid={child.pid}\npid_start={start}\n');before=record.read_text()
 say('Synthetic ownership record names a live local sleep PID with matching start time, but cannot prove Herdr/XDG ownership.')
 run('fixture','start',str(root),want=1);assert record.read_text()==before;assert child.poll() is None
 run('fixture','cleanup',str(root),want=1);assert root.exists() and record.read_text()==before and child.poll() is None
 say('PID and exact ownership record retained; second start and cleanup both refused without signalling the unproven process.')
 child.terminate();child.wait();run('fixture','cleanup',str(root));assert not root.exists();root=None
 result={'name':'real fixture CLI refuses to forget or signal a live unprovable recorded PID','pass':True}
except Exception:
 say(traceback.format_exc());result={'name':'owned record live driver','pass':False}
finally:
 if child and child.poll() is None:child.terminate();child.wait()
 if root:run('fixture','cleanup',str(root))
 (E/'live-owned-record-results.json').write_text(json.dumps(result,indent=2));log.close()
if not result.get('pass'):raise SystemExit(1)
