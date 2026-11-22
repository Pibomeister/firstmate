import pathlib,subprocess,os,tempfile,shutil,time,json,traceback,signal
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M80Q1H69WDB36Z47FP9D0CPE'); W=pathlib.Path(tempfile.mkdtemp(prefix='.gate-herdr-',dir=str(R))); lab=R/'bin/fm-herdr-lab.sh'; log=(E/'live-herdr-transcript.log').open('w'); root=None; names=[]; results=[]
def say(x):log.write(str(x)+'\n');log.flush();print(x,flush=True)
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_','XDG_')):e.pop(k,None)
e['FM_HERDR_LAB_STATE_DIR']=str(W/'tripwires')
def run(args,env=None,want=0,timeout=180):
 say('$ bin/fm-herdr-lab.sh '+' '.join(args)); p=subprocess.run(['bash',str(lab)]+args,env=env or e,text=True,capture_output=True,timeout=timeout); say(p.stdout.strip() or '<empty stdout>');say('stderr: '+p.stderr.strip());say('exit='+str(p.returncode));assert p.returncode==want;return p.stdout.strip()
try:
 root=run(['fixture','create']); apply=run(['fixture','apply',root]);
 # Let the helper interpret its shell export protocol, then capture only the isolated XDG env.
 a=subprocess.run(['bash','-c',apply+'\n/usr/bin/python3 -c "import os,json; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith(\'XDG_\')}))"'],env=e,text=True,capture_output=True,check=True)
 e.update(json.loads(a.stdout));run(['fixture','start',root]);run(['fixture','check',root])
 name=run(['name','gate-proof']);names.append(name);run(['provision',name]);status=run(['run',name,'status','--json']); assert json.loads(status)['server']['running'];run(['teardown',name]);names.remove(name)
 results.append({'name':'real named Herdr lab provisions and tears down inside an owned private XDG tree','pass':True})
 # Delay, then exec the installed Herdr. This injects launch latency without faking the server or CLI responses.
 real=shutil.which('herdr'); b=W/'delayed';b.mkdir();release=W/'release'; marker=W/'delayed.pid'
 wrapper=b/'herdr';wrapper.write_text('#!/usr/bin/python3\nimport sys,os,time\nif sys.argv[1:2]==["server"]:\n open(os.environ["DELAY_PID"],"w").write(str(os.getpid()))\n while not os.path.exists(os.environ["DELAY_RELEASE"]): time.sleep(.05)\nos.execv(os.environ["REAL_HERDR"],[os.environ["REAL_HERDR"]]+sys.argv[1:])\n');wrapper.chmod(0o755)
 delayed=e.copy();delayed.update(PATH=str(b)+os.pathsep+e['PATH'],DELAY_PID=str(marker),DELAY_RELEASE=str(release),REAL_HERDR=real)
 name=run(['name','late-proof']);names.append(name);run(['provision',name],delayed,want=1,timeout=360)
 pid=int(marker.read_text());alive=True
 try: os.kill(pid,0)
 except ProcessLookupError:alive=False
 say('delayed server launch pid='+str(pid)+' alive after timeout='+str(alive));assert not alive
 run(['teardown',name]);names.remove(name);release.touch();time.sleep(.5)
 listing=json.loads(run(['run',name,'session','list','--json']));assert not any(x['name']==name for x in listing['sessions']);say('released delayed launch after teardown: named session remains absent')
 results.append({'name':'timed-out real Herdr launch is cancelled and cannot start after release and teardown','pass':True})
except Exception:
 say(traceback.format_exc());results.append({'name':'Herdr live driver','pass':False})
finally:
 for name in names:
  try:run(['teardown',name])
  except Exception as x:say('teardown exception: '+str(x))
 if root:
  try:run(['fixture','cleanup',root])
  except Exception as x:say('fixture cleanup exception: '+str(x));results.append({'name':'Herdr cleanup','pass':False})
 shutil.rmtree(W);say('Disposed named sessions, server fixture and local launch-delay files');(E/'live-herdr-results.json').write_text(json.dumps(results,indent=2));log.close()
if any(not r['pass'] for r in results):raise SystemExit(1)
