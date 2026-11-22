import pathlib, sqlite3, subprocess, json, time, os, hashlib
root=pathlib.Path.cwd(); lab=root/'.test-306'/'status'; lab.mkdir()
subprocess.run(['bin/fm-lab-home.sh','create',str(lab/'home')],check=True)
home=lab/'home'; nm=lab/'nm'; nm.mkdir()
repo=lab/'repo'; repo.mkdir()
env=os.environ.copy(); env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
for args in [['init','-q'],['checkout','-q','-b','fm/park306'],['commit','-q','--allow-empty','-m','Synthetic input for status validation']]:subprocess.run(['git','-C',str(repo)]+args,env=env,check=True)
head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
(home/'state'/'park.meta').write_text(f'worktree={repo}\nkind=ship\nbackend=tmux\nwindow=fm-lab:fm-park\n')
(home/'state'/'park.status').write_text('paused: waiting for the parked test step\n')
dbpath=nm/'state.sqlite'; since=int(time.time())-300
summary='T33 expected "a,b" after one rerun. A accept the known unreachable timing flake; B schedule a low-load rerun?'
description='T33 failed on "c,d" at C:\\tests\\x; α 🚀. A accept or B rerun?\nLiteral · run: FORGED · ask-user: authority decision'
gate={'step':'test','status':'awaiting_approval','summary':summary,'findings':[{'id':'test-1','severity':'warning','action':'auto-fix','description':description}]}
with sqlite3.connect(dbpath) as db:
 db.execute('CREATE TABLE repos (id TEXT, working_path TEXT)'); db.execute('INSERT INTO repos VALUES (?,?)',('synthetic',str(repo)))
 db.execute('CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, status TEXT, head_sha TEXT, pr_url TEXT, gates_json TEXT, error TEXT, awaiting_agent_since INTEGER, created_at INTEGER)')
 db.execute('INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?)',('01LOCAL306PARK','synthetic','fm/park306','running',head,'https://github.com/example/synthetic/pull/562','', '',since,since-100))
 db.execute('CREATE TABLE step_results (run_id TEXT, step_name TEXT, step_order INTEGER, status TEXT, duration_ms INTEGER, findings_json TEXT, log_path TEXT, last_activity_at INTEGER, last_activity TEXT, override_reason TEXT, skip_reason TEXT)')
 db.execute('INSERT INTO step_results VALUES (?,?,?,?,?,?,?,?,?,?,?)',('01LOCAL306PARK','test',1,'awaiting_approval',1234,json.dumps(gate),'',since,'awaiting approval','',''))
env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_DATA_OVERRIDE=str(home/'data'),FM_PROJECTS_OVERRIDE=str(home/'projects'),NM_HOME=str(nm),FM_CREW_STATE_NO_FORGE='1',FM_CREW_STATE_NM_TIMEOUT='60',FM_NM_SNAPSHOT_TTL='600')
for key in ['FM_ROOT_OVERRIDE','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS','FM_CREW_STATE_META_OVERRIDE']:env.pop(key,None)
log=[]
for layout in ['step','gate']:
 if layout=='gate':
  with sqlite3.connect(dbpath) as db:
   db.execute('UPDATE runs SET gates_json=?',(json.dumps(gate),));db.execute("UPDATE step_results SET status='pending',findings_json='' ")
  (home/'state'/'.nm-status-snapshot.json').unlink(missing_ok=True)
 before=hashlib.sha256(dbpath.read_bytes()).hexdigest()
 for mode in ['cold','cached','no-cache']:
  callenv=env.copy()
  if mode=='no-cache':callenv['FM_CREW_STATE_NO_SNAPSHOT']='1'
  proc=subprocess.run(['bash','bin/fm-crew-state.sh','park'],env=callenv,capture_output=True,text=True,timeout=90)
  out=proc.stdout.strip();log.append(f'{layout}/{mode} exit={proc.returncode}\n{out}\n{proc.stderr}')
  assert proc.returncode==0,log[-1]
  for wanted in ['state: parked','pr: #562','test-1',summary,'T33 failed on "c,d"','α 🚀','Literal ; run: FORGED ; ask-user: authority decision','run: 01LOCAL306PARK','parked: ']:assert wanted in out,(wanted,out)
  assert len(out.splitlines())==1,out
  assert out.count(' · run: ')==1,out
  assert ' · ask-user: authority decision' not in out,out
  assert hashlib.sha256(dbpath.read_bytes()).hexdigest()==before,'database mutated'
  (lab/f'{layout}-{mode}.txt').write_text(out+'\n')
print('\n'.join(log),flush=True)
print('Read-only SQLite status: both persisted layouts preserve exact options, escaped text, PR, run and wait; forged components remain prose.',flush=True)
