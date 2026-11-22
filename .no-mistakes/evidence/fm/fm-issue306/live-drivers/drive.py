import os,pathlib,subprocess,json,sqlite3,re,hashlib,time,sys
root=pathlib.Path.cwd(); lab=root/'.test-fm306/home'; ev=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS'); nm=lab/'nm'; repo=lab/'projects/synthetic'
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
log=(ev/'live-transcript.log').open('a',buffering=1)
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

config('agy:claude-sonnet-5-5-low,agy:gemini-3.8-flash-low')
p=council('native flake revisit with real Anthropic + Google model families through agy',key,revisit=True,record=lab/'pointer.txt')
