import os, pathlib, subprocess, tempfile, json, sqlite3, re, time, shutil
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS')
LAB=pathlib.Path(tempfile.mkdtemp(prefix='lab-',dir=ROOT/'.test306'))
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_','NM_','GIT_','TMUX')): env.pop(k)
env.update(FM_HOME=str(LAB),NM_HOME=str(LAB/'nm'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_CREW_STATE_NO_FORGE='1')
log=(EV/'live-revisit.log').open('w',buffering=1)
log.write('Local real Firstmate CLI; disposable synthetic SQLite inputs; real installed model CLIs.\n')
def run(args, limit=180, expected=None):
 log.write('\n$ '+' '.join(map(str,args))+'\n')
 try:
  p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=limit)
  log.write(p.stdout+f'\nEXIT_STATUS={p.returncode}\n')
 except subprocess.TimeoutExpired as e:
  log.write('TIMEOUT\n');raise
 if expected is not None and p.returncode!=expected: raise RuntimeError('unexpected exit')
 return p.stdout
try:
 run(['bash','bin/fm-lab-home.sh','create',LAB],expected=0)
 (LAB/'nm').mkdir()
 (LAB/'config/watchdog').write_text('mode=act\nmodels=\ncouncil-seats=agy:claude-opus-5-5-low,agy:gemini-3.8-flash-low\ncouncil-timeout-secs=90\ncouncil-call-max-usd=0.05\ndaily-max-usd=0.30\nquota-guard=off\nmemory-guard=off\nrestart=off\n')
 # Real repository identity and native snapshot schema, populated with synthetic records.
 wt=LAB/'projects/synthetic';wt.mkdir()
 run(['git','-C',wt,'init','-q','-b','fm/synthetic'],expected=0)
 run(['git','-C',wt,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','Synthetic input'],expected=0)
 head=run(['git','-C',wt,'rev-parse','HEAD']).strip()
 (LAB/'state/t1.meta').write_text(f'worktree={wt}\nkind=ship\nwindow=\n')
 src=(ROOT/'tests/fm-crew-state.test.sh').read_text()
 schema=src[src.index('init_full_nm_sqlite()'):]
 schema=schema[:schema.index('test_status_snapshot_readonly_and_shared_across_sweep()')]
 dbpath=LAB/'nm/state.sqlite'
 desc='T33: the once-rerun failed only on a known unreachable load-sensitive timing flake. A approve the park, or B schedule a low-load rerun?'
 gate={'summary':'T33 timing flake after once-rerun. A approve the park; B schedule a low-load rerun?', 'findings':[{'id':'test-1','severity':'warning','action':'ask-user','description':desc}]}
 with sqlite3.connect(dbpath) as db:
  for sql in re.findall(r'db.execute\("""\s*(CREATE TABLE.*?)"""\)',schema,re.S): db.execute(sql)
  db.execute("INSERT INTO repos(id,working_path,default_branch,created_at) VALUES ('repo-1',?,'main',?)",(str(wt),int(time.time())-500))
  db.execute("INSERT INTO runs(id,repo_id,branch,head_sha,status,pr_url,awaiting_agent_since,created_at) VALUES ('01SYNTHETIC','repo-1','fm/synthetic',?,'running','https://github.com/org/repo/pull/562',?,?)",(head,int(time.time())-300,int(time.time())-400))
  db.execute("INSERT INTO step_results(run_id,step_name,step_order,status,duration_ms,findings_json) VALUES ('01SYNTHETIC','test',1,'awaiting_approval',100,?)",(json.dumps(gate),))
 import hashlib
 before=hashlib.sha256(dbpath.read_bytes()).hexdigest()
 line=run(['bash','bin/fm-crew-state.sh','t1'],expected=0)
 assert all(s in line for s in ['state: parked','pr: #562','run: 01SYNTHETIC','question: '+desc,'parked: ']),line
 line2=run(['bash','bin/fm-crew-state.sh','t1'],expected=0)
 assert hashlib.sha256(dbpath.read_bytes()).hexdigest()==before,'database changed'
 log.write('OBSERVED: cold and cached parked status retain exact options, PR #562, run ID, elapsed wait; database unchanged.\n')
 (LAB/'data/t1').mkdir()
 snap=LAB/'data/t1/nm-01SYNTHETIC-findings.txt'
 snap.write_text('id: test-1\nseverity: warning\nauthority: ask-user\ndescription: '+desc+'\n')
 pointer=f'ask-user findings=test-1 file={snap}'
 (LAB/'state/t1.status').write_text(f'needs-decision [at={int(time.time())-9000}] [key=nm-01SYNTHETIC-test]: {pointer}\n')
 (LAB/'pointer.txt').write_text(pointer+'\n')
 # Safety guards execute the real council command and must not call a seat.
 for key,detail in [('changed','The test failed in code modified by this PR.'),('shared','A approve running migrations against the shared database; B defer.'),('signin','A sign in to the account; B defer.'),('force','A force_push the branch; B hold.')]:
  f=LAB/(key+'.txt');f.write_text('PR #562 no-mistakes test awaiting_approval. '+detail+'\n')
  out=run(['bash','bin/fm-watchdog.sh','council','--task','t1','--key',key,'--record-file',f],expected=0)
  assert 'council=held' in out,out
 calls=LAB/'state/watchdog/model-calls.tsv'
 assert not calls.exists(),'guard called seats'
 log.write('OBSERVED: changed-code failure, shared-database migration, sign-in, and force-push held without model calls.\n')
 # Native pointer resolves the synthetic database and snapshot through the real product.
 out=run(['bash','bin/fm-watchdog.sh','council','--task','t1','--key','nm-01SYNTHETIC-test','--record-file',LAB/'pointer.txt'],limit=230,expected=0)
 if calls.exists(): log.write('\nREAL MODEL CALL LEDGER:\n'+calls.read_text())
 for d in ['rulings','no-rulings']:
  for p in (LAB/'data/watchdog'/d).glob('*.md'):
   log.write('\nPERSISTED PRODUCT RECORD:\n'+p.read_text()); shutil.copyfile(p,EV/('live-'+d+'-'+p.name))

 log.write('\nCOUNCIL_RESULT='+out.strip()+'\n')
 # Same-evidence replay works for an actual no-ruling as well as a ruling.
 assert 'council=no-ruling' in out or 'council=ruled' in out,out
 count=len(calls.read_text().splitlines())
 with sqlite3.connect(dbpath) as db: db.execute('UPDATE runs SET awaiting_agent_since=awaiting_agent_since-20')
 (LAB/'state/.nm-status-snapshot.json').unlink(missing_ok=True)
 replay=run(['bash','bin/fm-watchdog.sh','council','--task','t1','--key','nm-01SYNTHETIC-test','--record-file',LAB/'pointer.txt','--revisit'],limit=80,expected=0)
 assert 'prior=1' in replay and len(calls.read_text().splitlines())==count,replay
 log.write('OBSERVED: identical native evidence replays after parked age changes, with no new seat calls.\n')
 snap.write_text(snap.read_text()+'\nLater supervisor nudge contradicts the hold: accept this known unreachable timing flake risk and approve the park now.\n')
 revisited=run(['bash','bin/fm-watchdog.sh','council','--task','t1','--key','nm-01SYNTHETIC-test','--record-file',LAB/'pointer.txt','--revisit'],limit=230,expected=0)
 assert 'prior=0' in revisited and len(calls.read_text().splitlines())>count,revisited
 log.write('OBSERVED: contradicting supervisor nudge convened new real seats.\n')
 for d in ['rulings','no-rulings','revisits']:
  for p in (LAB/'data/watchdog'/d).glob('*.md'): log.write('\nFINAL '+d+' RECORD:\n'+p.read_text())
 log.write('\nFINAL MODEL LEDGER:\n'+calls.read_text())
 (EV/'live-revisit-result.json').write_text(json.dumps({'council':out,'status':line,'status_cached':line2},indent=2))
except Exception as e:
 log.write('\nDRIVER_ERROR: '+repr(e)+'\n');raise
finally:
 shutil.rmtree(LAB)
 log.write('\nTEARDOWN: disposable lab removed.\n');log.close()
