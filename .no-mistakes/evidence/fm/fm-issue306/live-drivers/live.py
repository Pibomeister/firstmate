import os,pathlib,subprocess,json,sqlite3,re,hashlib,time,sys
root=pathlib.Path.cwd(); lab=root/'.test-fm306/home'; ev=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS')
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True)
repo=lab/'projects/synthetic'; repo.mkdir(parents=True)
for args in [['init','-q'],['-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','synthetic input'],['checkout','-q','-b','fm/ship-a']]: subprocess.run(['git','-C',str(repo),*args],check=True)
head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
nm=lab/'nm';nm.mkdir(); (lab/'data/t1').mkdir(); (lab/'claude').mkdir()
src=(root/'tests/fm-crew-state.test.sh').read_text(); script=src.split('init_full_nm_sqlite() {',1)[1].split("<<'PY'\n",1)[1].split('\nPY\n}',1)[0]
subprocess.run(['python3','-',str(nm/'state.sqlite'),str(repo),head,''],input=script,text=True,check=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','NO_MISTAKES')) and k not in ['NM_HOME','TMUX','TMUX_PANE']}
env.update(FM_HOME=str(lab),NM_HOME=str(nm),FM_CREW_STATE_NO_FORGE='1',FM_NM_SNAPSHOT_TTL='1')
(lab/'state/t1.meta').write_text(f'window=fm-lab:worker\nbackend=tmux\nworktree={repo}\nkind=ship\n')
run='01M7SNAPSHOTA0000000000001'; key='nm-'+run+'-review'
flake='After the once-rerun, the only failure left was a known load-sensitive timing flake in a test the PR cannot reach. Equivalent park: https://github.com/org/repo/pull/577. A approve the park now; B schedule a low-load rerun?'
def seed(description=flake,summary='T33 timing flake. A approve the park; B schedule a low-load rerun?',age=300):
 g={'step':'review','status':'awaiting_approval','summary':summary,'findings':[{'id':'test-1','severity':'warning','action':'ask-user','description':description}]}
 with sqlite3.connect(nm/'state.sqlite') as db:
  db.execute("UPDATE runs SET pr_url=?,awaiting_agent_since=?",('https://github.com/org/repo/pull/562',int(time.time())-age))
  db.execute("UPDATE step_results SET findings_json=? WHERE step_name='review'",(json.dumps(g),))
 (lab/'state/.nm-status-snapshot.json').unlink(missing_ok=True)
def snapshot(description=flake,note=''):
 (lab/f'data/t1/nm-{run}-findings.txt').write_text('id: test-1\nseverity: warning\nauthority: ask-user\ndescription: '+description+'\n'+note)
def config(seats='claude:haiku,agy:gemini-3.8-flash-low'):
 (lab/'config/watchdog').write_text(f'mode=act\ndecisions=act\nmodels=\ncouncil-seats={seats}\ncouncil-timeout-secs=90\ncouncil-call-max-usd=0.10\ndaily-max-usd=1.00\nquota-guard=off\nmemory-guard=off\nrestart=off\nclaude-config-dirs={lab}/claude\n')
log=(ev/'live-transcript.log').open('w',buffering=1)
def call(label,args,timeout=220):
 log.write('\n$ '+label+'\n'); print(label,flush=True)
 p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write(p.stdout+f'\nexit={p.returncode}\n'); print(p.stdout[:1000],flush=True)
 return p
wd=['bash','bin/fm-watchdog.sh','council','--task','t1']
def council(label,k,record=None,revisit=False):
 args=wd+['--key',k]
 if record: args+=['--record-file',str(record)]
 if revisit: args+=['--revisit']
 return call(label,args)
def check(value,msg):
 log.write(('PASS ' if value else 'FAIL ')+msg+'\n'); print(('PASS ' if value else 'FAIL ')+msg,flush=True)
 if not value: raise AssertionError(msg)
def records(folder='rulings'):return sorted((lab/f'data/watchdog/{folder}').glob('*.md'))
seed();snapshot();config()
(lab/'state/t1.status').write_text(f'needs-decision [at={int(time.time())-9000}] [key={key}]: ask-user findings=test-1 file={lab}/data/t1/nm-{run}-findings.txt\n')
p=call('FM_HOME=<lab> NM_HOME=<synthetic SQLite> bin/fm-crew-state.sh t1',['bash','bin/fm-crew-state.sh','t1'])
check(p.returncode==0 and all(s in p.stdout for s in ['state: parked','pr: #562',run,'A approve','B schedule','parked: 3']), 'native SQLite status exposes PR, run, failure, options and elapsed wait')
(ev/'parked-status.txt').write_text(p.stdout)
p=council('native flake: real Claude + Gemini council',key)
(ev/'initial-council-result.txt').write_text(p.stdout)
print('INITIAL_DONE',flush=True)
# Further steps are driven by follow-up script after actual results are inspected.
log.close()
