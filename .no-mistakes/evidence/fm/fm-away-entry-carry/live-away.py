import os, pathlib, subprocess, json, time, shutil, traceback
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M87XC201TK1ENP8GG60A85AH')
BASE=ROOT/'.test-away-live'; BASE.mkdir(exist_ok=False)
results=[]
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE','CLAUDECODE','PI_CODING_AGENT')}
class Lab:
 def __init__(self,name):
  self.name=name; self.home=BASE/name; self.log=open(E/(name+'.log'),'w'); self.env=env|{'FM_HOME':str(self.home)}
  self.run('fm-lab-home.sh','create',str(self.home))
  self.state=self.home/'state'; self.gate=self.state/'.afk-return-catchup'
  (self.home/'config/supervision-host-off').touch()
  (self.home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
  (self.home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
  (self.state/'.last-watcher-beat').touch()
 def run(self,script,*args,rc=0,extra=None):
  cmd=[str(ROOT/'bin'/script),*args]
  p=subprocess.run(cmd,cwd=ROOT,env=self.env|(extra or {}),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
  self.log.write('$ '+ ' '.join(cmd)+'\n'+p.stdout+f'\n[exit {p.returncode}]\n'); self.log.flush()
  if rc is not None: assert p.returncode==rc,(script,args,p.returncode,p.stdout[-4000:])
  return p.stdout
 def entry(self,words): return self.run('fm-afk-launch.sh','enter','--words',words)
 def field(self,name): return self.run('fm-afk-contract.sh','field',name).strip()
 def blocker(self,key,reason):
  (self.state/'demo.meta').write_text('project=demo\nwindow=lab-demo\nbackend=tmux\nkind=ship\n')
  with (self.state/'demo.status').open('a') as f: f.write(f'blocked [key={key}]: {reason}\n')
 def resolve(self,key):
  with (self.state/'demo.status').open('a') as f:f.write(f'resolved [key={key}]: local dependency repaired\n')
 def snap(self,label):
  for name in ('.afk-contract','.afk-return-catchup','.afk-carried-retained'):
   p=self.state/name
   if p.is_file():self.log.write(f'PERSISTED {label} {name}\n'+p.read_text()+'\n')
  self.log.flush()
 def close(self):self.log.close()
def scenario(name,fn):
 l=Lab(name)
 try:
  fn(l);results.append({'name':name,'result':'pass','live':True,'evidence':str(E/(name+'.log')),'reason':'Real unmodified CLI entrypoints executed against a marked disposable lab home with synthetic status and recovery records.'})
 except Exception as e:
  l.log.write(traceback.format_exc());l.log.flush();results.append({'name':name,'result':'fail','live':True,'evidence':str(E/(name+'.log')),'reason':str(e)})
 finally:l.close(); (E/'live-results.json').write_text(json.dumps(results,indent=2))
 print(name,results[-1]['result'],flush=True)

def carry(l):
 l.entry('Observe the local fleet. Merge nothing.'); epoch=l.field('entered_epoch')
 l.blocker('artifact','local artifact is unavailable');l.blocker('token','local token needs repair')
 l.run('fm-afk-return.sh','begin',rc=3); before=l.gate.read_bytes()
 out=l.run('fm-afk-launch.sh','enter','--words','new mandate','--grant','retired',rc=2)
 assert '--grant was retired' in out and before==l.gate.read_bytes() and not (l.state/'.afk-contract').exists()
 time.sleep(1.1);out=l.entry('Continue observing. Merge nothing.')
 assert 'demo [key=artifact] local artifact is unavailable' in out
 assert 'demo [key=token] local token needs repair' in out
 assert not l.gate.exists();l.snap('entry with carried blockers')
 out=l.run('fm-afk-return.sh','begin',rc=3)
 assert 'Carried from the previous return:' in out and 'demo [key=artifact]' in out and 'demo [key=token]' in out
 l.resolve('artifact');out=l.run('fm-afk-return.sh','check',rc=3)
 assert 'blocker\tdemo\ttoken\t' in l.gate.read_text() and 'blocker\tdemo\tartifact\t' not in l.gate.read_text()
 l.resolve('token');l.run('fm-afk-return.sh','check');assert not l.gate.exists();l.run('fm-afk-return.sh','guard')

def refresh(l):
 l.gate.write_text('schema\tfm-afk-return.v1\nphase\tblocked\nblocker\tdemo\tbuild\toriginal reason\n')
 l.entry('Keep this mandate and spending cap.');epoch=l.field('entered_epoch'); words=l.run('fm-afk-contract.sh','words');spend=l.field('spend_max_concurrent_workers')
 l.gate.write_text('schema\tfm-afk-return.v1\nphase\tblocked\nblocker\tdemo\tbuild\tupdated reason\nblocker\tsecond\tdeploy\tlocal deployment waits\n')
 l.run('fm-afk-launch.sh','enter');assert l.field('entered_epoch')==epoch and l.run('fm-afk-contract.sh','words')==words and l.field('spend_max_concurrent_workers')==spend
 rows=l.run('fm-afk-contract.sh','carried').splitlines();assert rows==['demo\tbuild\tupdated reason','second\tdeploy\tlocal deployment waits'];l.snap('refresh')
 assert not list((l.state/'afk-contracts').glob('*superseded*'))
 l.run('fm-afk-return.sh','begin')

def repeated(l):
 l.entry('Recovery window A');epoch=l.field('entered_epoch');valid=(l.state/'.afk-contract').read_bytes();l.run('fm-afk-return.sh','begin')
 missing=l.state/'afk-contracts'/f'{epoch}.afk-contract';missing.unlink()
 l.gate.write_text(f'schema\tfm-afk-return.v1\nphase\tblocked\nretained-record\t{missing}\n')
 for n in (1,2,3):
  time.sleep(1.1);l.entry(f'Recovery window {n}');l.snap(f'cycle {n} entry');out=l.run('fm-afk-return.sh','begin',rc=3)
  assert f'retained away-posture record missing: {missing}' in out
 missing.write_text('version: 1\n');out=l.run('fm-afk-return.sh','check',rc=3);assert 'retained away-posture record unreadable:' in out
 missing.write_bytes(valid);l.run('fm-afk-return.sh','check');assert not l.gate.exists()

def rollback(l):
 l.run('fm-afk-contract.sh','enter',extra={'FM_AFK_MODE':'quiet'});l.run('fm-afk-return.sh','begin');assert (l.state/'.quiet-exit-receipt').exists()
 missing=l.state/'afk-contracts/1700000000.afk-contract';sup=l.state/'afk-contracts/1700000000-superseded-1.afk-contract'
 l.gate.write_text(f'schema\tfm-afk-return.v1\nphase\tblocked\nretained-record\t{missing}\nsuperseded\t{sup}\n')
 time.sleep(1.1);l.entry('Observe after rollback; merge nothing.');valid=(l.state/'.afk-contract').read_bytes()
 # Unsupported terminal backend is an exact unsafe launch, not a posture refusal.
 l.run('fm-afk-launch.sh','start',rc=1,extra={'FM_SUPERVISOR_BACKEND':'unsupported','FM_SUPERVISOR_TARGET':'isolated-lab'})
 l.run('fm-afk-launch.sh','stop');assert not (l.state/'.afk-contract').exists() and not l.gate.exists()
 l.snap('no contract after rollback');out=l.run('fm-afk-return.sh','guard',rc=4);assert str(missing) in out
 assert str(missing) in l.run('fm-afk-return.sh','catchup-summary')
 out=l.run('fm-afk-return.sh','begin',rc=3);assert 'retained away-posture record missing:' in out and 'superseded away-posture record missing:' in out
 missing.write_bytes(valid);sup.write_text('version: 1\n');l.run('fm-afk-return.sh','check',rc=3)
 sup.write_bytes(valid);l.run('fm-afk-return.sh','check');l.run('fm-afk-return.sh','guard');assert (l.state/'.quiet-exit-receipt').exists()

def interrupted(l):
 for stage in ('before-retain','before-delete'):
  l.entry('Earlier mandate for '+stage);old=l.field('entered_epoch');l.blocker(stage,'local handoff remains open')
  l.run('fm-afk-return.sh','begin',rc=3);saved=l.gate.read_bytes();arc=l.state/'afk-contracts'/f'{old}.afk-contract';valid=arc.read_bytes();arc.unlink()
  time.sleep(1.1);l.entry('Current mandate for '+stage);new=l.field('entered_epoch');assert old!=new
  l.gate.write_bytes(saved)
  if stage=='before-retain':(l.state/'.afk-carried-retained').unlink()
  (l.state/'.watcher-down').touch();out=l.run('fm-afk-return.sh','begin',rc=3);l.snap(stage)
  instr=out.split('Your instructions:')[1].split('Waiting on you:')[0]
  assert 'Current mandate for '+stage in instr and 'Earlier mandate for '+stage not in instr
  assert 'GAP: watcher downtime' in out.split('Supervisor health:')[1].split('Your instructions:')[0]
  assert f'contract\t{new}\n' in l.gate.read_text() and f'window\t{new}\n' in l.gate.read_text()
  assert f'retained away-posture record missing: {arc}' in out
  arc.write_bytes(valid);l.resolve(stage);l.run('fm-afk-return.sh','check');(l.state/'.watcher-down').unlink();time.sleep(1.1)

def health(l):
 l.entry('Healthy window');l.blocker('health','local dependency waits');out=l.run('fm-afk-return.sh','begin',rc=3);assert 'no detected gap' in out
 time.sleep(1.1);l.entry('Window with outage');(l.state/'.watcher-down').touch();now=int(time.time())
 # The ledger is the real engine snapshot input, containing a synthetic latch.
 (l.state/'.supervision-host.log').write_text(f'{now}\tlatch\terrors=2\tcooldown=300s\n')
 out=l.run('fm-afk-return.sh','begin',rc=3);l.snap('new window outage')
 h=out.split('Supervisor health:')[1].split('Your instructions:')[0];assert 'GAP: watcher downtime' in h and 'no detected gap' not in h
 assert 'catch-up retained-health: supervision ran' in out and 'after 2 consecutive engine errors' in out
 (l.state/'.watcher-down').unlink();(l.state/'.supervision-host.log').unlink();out=l.run('fm-afk-return.sh','check',rc=3);assert 'GAP: watcher downtime' in out and 'after 2 consecutive engine errors' in out
 time.sleep(1.1);l.entry('Recovered window');l.resolve('health');(l.state/'.last-watcher-beat').touch();out=l.run('fm-afk-return.sh','begin')
 h=out.split('Supervisor health:')[1].split('Your instructions:')[0];assert 'no detected gap' in h and 'GAP:' not in h
 assert 'catch-up retained-health: GAP: watcher downtime' in out and 'catch-up retained-engine: the supervision session latched' in out
try:
 for name,fn in [('entry-carry-and-key-resolution',carry),('refresh-carried-keys',refresh),('repeated-archive-recovery',repeated),('rollback-without-contract',rollback),('interrupted-handoff',interrupted),('fresh-window-health',health)]:scenario(name,fn)
finally:
 shutil.rmtree(BASE)
