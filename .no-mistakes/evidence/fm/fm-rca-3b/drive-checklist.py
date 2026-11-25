import os, pathlib, tempfile, subprocess, shutil, hashlib, datetime, json, shlex
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M88ESZEM0X1FSQ08VFD3QR76')
TMP=pathlib.Path(tempfile.mkdtemp(prefix='.checklist-live-',dir=ROOT))
base={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK')}
log=(E/'live-checklist.txt').open('w'); results=[]
def record(s):
 print(s,flush=True); log.write(s+'\n'); log.flush()
def env_for(h):
 e=base.copy(); e.update(FM_HOME=str(h),FM_HEARTBEAT_BIN='true',PATH=str(TMP/'clock')+':'+base['PATH'],LIVE_CLOCK=str(TMP/'epoch')); return e
def run(h,script,*args,expect=0,cwd=None,extra=None):
 e=env_for(h); e.update(extra or {})
 cmd=['/bin/bash',str(ROOT/'bin'/script),*map(str,args)]
 p=subprocess.run(cmd,env=e,cwd=cwd or ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 record('$ FM_HOME='+str(h)+' '+shlex.join([script,*map(str,args)])+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
 assert p.returncode==expect,(script,p.returncode,expect,p.stdout)
 return p.stdout

def clock(s):
 epoch=int(datetime.datetime.fromisoformat(s).timestamp()); (TMP/'epoch').write_text(str(epoch)); record('Synthetic local clock: '+s); return epoch

def home(n):
 h=TMP/n;run(h,'fm-lab-home.sh','create',h)
 (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
 (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 (h/'artifacts').mkdir(); return h

def artifact(h,m):
 p=h/'artifacts'/f'{m}.md';p.write_text('Synthetic artifact supplied by test operator for '+m+'\n');return p,hashlib.sha256(p.read_bytes()).hexdigest()
def receipt(h,m,p,hash,night=None):
 args=['receipt','--machine',m,'--path',str(p),'--hash',hash]
 if night:args+=['--night',night]
 return run(h,'fm-postmortem-checklist.sh',*args)
def passed(name):results.append({'name':name,'result':'pass'});record('SCENARIO PASS: '+name)
def waiting(out): return out.split('Waiting on you:',1)[1].split('Tried and failed, or could not be fixed:',1)[0]
try:
 (TMP/'clock').mkdir(); real_date=shutil.which('date')
 (TMP/'clock/date').write_text('#!/bin/bash\ncase "$*" in\n+%s) cat "$LIVE_CLOCK" ;;\n+%F) '+shlex.quote(shutil.which('python3'))+' -c \'import datetime,os;print(datetime.datetime.fromtimestamp(int(open(os.environ["LIVE_CLOCK"]).read())).date())\' ;;\n*) exec '+shlex.quote(real_date)+' "$@" ;;\nesac\n');(TMP/'clock/date').chmod(0o755)
 clock('2026-11-24T07:44:59'); h=home('due')
 out=run(h,'fm-postmortem-checklist.sh','collect'); assert not out
 clock('2026-11-24T07:45:00');out=run(h,'fm-postmortem-checklist.sh','collect')
 assert all(m+'\topen\t2026-11-24: no artifact receipt recorded' in out for m in ['M3','Studio','Hetzner','local'])
 assert len((h/'state/postmortem-checklist.tsv').read_text().splitlines())==1
 run(h,'fm-postmortem-checklist.sh','collect');assert len((h/'state/postmortem-checklist.tsv').read_text().splitlines())==1
 passed('Local CLI creates four named missing rows at 07:45, never early, without duplicate opening')

 clock('2026-11-23T20:00:00'); h=home('return')
 run(h,'fm-afk-contract.sh','enter','--words','collect overnight postmortem receipts')
 clock('2026-11-24T07:45:00'); p,hash=artifact(h,'M3'); receipt(h,'M3',p,hash)
 p,hash=artifact(h,'local');note=run(h,'fm-inbox.sh','note',f'postmortem-receipt\t2026-11-24\tlocal\t{p}\t{hash}')
 p,hash=artifact(h,'Studio');run(h,'fm-inbox.sh','note',f'postmortem-receipt\t2026-11-24\tStudio\t{p}\t'+('0'*64))
 out=run(h,'fm-afk-return.sh','begin');w=waiting(out)
 assert 'Hetzner: 2026-11-24: no artifact receipt recorded' in w and 'Studio: 2026-11-24: artifact hash mismatch' in w
 assert '    - M3:' not in w and '    - local:' not in w
 passed('Real local return CLI consumes ledger and inbox receipts across midnight; brief names missing Hetzner and bad-hash Studio')
 clock('2026-11-24T08:30:00');run(h,'fm-afk-contract.sh','enter','--words','continue supervision')
 clock('2026-11-24T09:00:00');out=run(h,'fm-afk-return.sh','begin');w=waiting(out)
 assert 'Hetzner: 2026-11-24:' in w and 'Studio: 2026-11-24: artifact hash mismatch' in w
 clock('2026-11-25T09:00:00');out=run(h,'fm-postmortem-checklist.sh','collect','--since',int(datetime.datetime(2026,11,25,8,30).timestamp()))
 assert 'Hetzner\topen\t2026-11-24:' in out and 'M3\topen\t2026-11-25:' in out
 passed('Local CLI retains unresolved machines across away re-entry and later mornings')

 h=home('verification');clock('2026-11-24T08:00:00')
 for m in ['M3','Studio','Hetzner','local']:
  p,hash=artifact(h,m)
  run(h,'fm-postmortem-checklist.sh','receipt','--machine',m,'--path','artifacts/'+m+'.md','--hash',hash,cwd=h)
 out=run(h,'fm-postmortem-checklist.sh','check');assert out.count('\tclosed\t')==4
 assert not run(h,'fm-postmortem-checklist.sh','open',cwd=h/'artifacts')
 (h/'artifacts/Hetzner.md').unlink();(h/'artifacts/Studio.md').write_text('changed after receipt')
 out=run(h,'fm-postmortem-checklist.sh','check',expect=1)
 assert 'Hetzner\topen\tartifact missing' in out and 'Studio\topen\tartifact hash mismatch' in out
 passed('Local CLI closes only verified artifacts, preserves relative receipts across directories, and reopens missing or changed files')

 h=home('conflict');clock('2026-11-24T08:00:00');p,hash=artifact(h,'M3')
 run(h,'fm-inbox.sh','note',f'postmortem-receipt\t2026-11-24\tM3\t{p}\t{hash}')
 run(h,'fm-inbox.sh','note',f'postmortem-receipt\t2026-11-24\tM3\t{p}\t'+('0'*64))
 out=run(h,'fm-postmortem-checklist.sh','open');assert 'M3\topen\tartifact receipt could not be verified' in out
 ids=[f.stem for f in (h/'state/inbox').glob('*.note')];run(h,'fm-inbox.sh','drain','--ack',*ids)
 out=run(h,'fm-postmortem-checklist.sh','collect');assert 'M3\topen\t2026-11-24: artifact receipt could not be verified' in out
 clock('2026-11-24T08:00:01');out=receipt(h,'M3',p,hash);assert 'M3\tclosed\t' in out
 out=run(h,'fm-postmortem-checklist.sh','collect');assert 'M3\topen\t' not in out
 passed('Real inbox CLI acknowledgement preserves conflicting ties; strictly newer valid receipt closes M3')

 h=home('invalid');clock('2026-11-24T08:00:00');p,hash=artifact(h,'M3')
 run(h,'fm-postmortem-checklist.sh','start','--night','2026-11-31',expect=2)
 run(h,'fm-postmortem-checklist.sh','receipt','--machine','M3','--path',p,'--hash',hash,'--night','2026-02-29',expect=2)
 assert not (h/'state/postmortem-checklist.tsv').exists()
 (h/'state/postmortem-checklist.tsv').write_text('2026-11-31\t-\topened\t\t\t1\n')
 out=run(h,'fm-postmortem-checklist.sh','collect');assert '2026-11-31:' not in out and 'Hetzner\topen\t2026-11-24:' in out
 passed('Local CLI refuses calendar-invalid input and keeps valid collection visible despite invalid legacy history')

 h=home('no-hash');clock('2026-11-24T08:00:00')
 for m in ['M3','Studio','Hetzner','local']:
  p,hash=artifact(h,m);receipt(h,m,p,hash)
 restricted=TMP/'no-hash-bin';restricted.mkdir()
 for c in ['dirname','python3','awk','cut','tr','date','cat']:
  (restricted/c).symlink_to(str(TMP/'clock/date') if c=='date' else shutil.which(c))
 out=run(h,'fm-postmortem-checklist.sh','check',expect=1,extra={'PATH':str(restricted)})
 assert out.count('\topen\tartifact hash verification failed')==4
 passed('Real checklist CLI fails open for all four machines when SHA tools are unavailable')
 record('All listed local product scenarios passed. No harness or production fleet was accessed.')
finally:
 shutil.rmtree(TMP)
 (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
 record('Disposable worktree lab removed.')
 log.close()
