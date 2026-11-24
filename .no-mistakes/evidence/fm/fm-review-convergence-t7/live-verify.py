import os, sys, subprocess, pathlib, json, hashlib, signal, time, shutil
ROOT = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M852Q02C839WMBGSST6MQG1V')
F = E / 'live-fixtures'
F.mkdir()
REPO = F / 'repo'
REPO.mkdir()
SCRATCH = F / 'scratch'
SCRATCH.mkdir()
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'AK_', 'GIT_'))}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_COUNT='0', FM_HOME=str(F/'home'), FM_TASK_ID='review-live', TMPDIR=str(SCRATCH))
(F/'home').mkdir()
records=[]
children=[]
log = (E/'live-transcript.txt').open('w', buffering=1)
def sh(args, cwd=REPO):
    return subprocess.check_output(args, cwd=cwd, env=ENV, stderr=subprocess.STDOUT, text=True).strip()
def git(*args): return sh(['git', *args])
def commit(msg):
    git('add', '.')
    git('-c', 'user.name=Live Test', '-c', 'user.email=live@example.invalid', 'commit', '-qm', msg)
    return git('rev-parse','HEAD')
def save(path, text):
    dest=REPO/path
    dest.parent.mkdir(exist_ok=True, parents=True)
    dest.write_text(text)
git('init','-q','--template=')
save('bin/tool.sh', '. bin/helper.sh || exit 1\ngreet\n')
save('bin/helper.sh', 'greet() { echo hello; }\nold_fn() { return 0; }\n')
save('tests/kept.test.sh', 'exit 0\n')
save('.gitattributes','bin/helper.sh export-ignore\n')
BASE=commit('working tool')
git('update-ref','refs/remotes/origin/main',BASE)
git('symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/main')
save('bin/tool.sh', '. bin/helpers.sh || exit 1\ngreet\n')
save('bin/helper.sh', 'greet() { echo hello; }\nold_fn() { return 0; }\nnew_fn() { return 1; }\n')
save('bin/new-tool.sh','echo broken-new-tool; exit 1\n')
HEAD=commit('introduce wrong helper path and new failing code')
original=git('status','--porcelain')
def command(name,body,path='tests/review-live.test.sh',extra=(),env=None):
    repro=F/(name+'.sh')
    repro.write_text('#!/usr/bin/env bash\n'+body+'\n')
    out=E/('live-'+name)
    args=[str(ROOT/'bin/fm-merge-review.sh'),'verify-finding','--repo',str(REPO),'--head',HEAD,'--repro',str(repro),'--path',path,'--out',str(out),'--timeout','5',*extra]
    runenv=ENV.copy()
    if env: runenv.update(env)
    return args,runenv,out,repro

def execute(name,body,classification=None,head=None,base=None,path='tests/review-live.test.sh',extra=(),env=None,rc=0):
    args,runenv,out,repro=command(name,body,path,extra,env)
    p=subprocess.run(args,env=runenv,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
    log.write('\nCASE '+name+'\nCOMMAND '+repr(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    for fn in ('head.log','base.log'):
        if (out/fn).exists(): log.write(fn+':\n'+(out/fn).read_text())
    assert p.returncode==rc, (name,p.returncode,p.stderr)
    if classification:
        parts=p.stdout.strip().split()
        assert parts[:2]==['verify-finding:', classification], (name,p.stdout)
        fields=dict(x.split('=',1) for x in parts[2:])
        assert fields['head_result']==head and fields['base_result']==base,(name,fields)
        assert fields['head']==HEAD and fields['base']==BASE
        assert fields['repro_sha256']==hashlib.sha256(repro.read_bytes()).hexdigest()
        assert (out/'result').read_text()==p.stdout
        assert (out/'base.log').exists()==(base!='skipped')
    else: assert not (out/'result').exists(), name
    assert git('status','--porcelain')==original, 'source mutated'
    assert not list(SCRATCH.iterdir()), 'scratch leaked'
    records.append(dict(name=name,result='pass',exit=p.returncode,stdout=p.stdout,stderr=p.stderr))
    return out

def alive(pid):
    p=subprocess.run(['ps','-o','stat=','-p',str(pid)],text=True,stdout=subprocess.PIPE)
    return bool(p.stdout.strip()) and 'Z' not in p.stdout

def assert_children_gone():
    for pid in children:
        assert not alive(pid), 'child outlived verification: '+str(pid)
        log.write('child '+str(pid)+' stopped before return\n')

try:
    execute('wrong-path-introduced','bash bin/tool.sh || exit 1','introduced','red','green')
    execute('red-at-both','echo same-observed-failure; exit 1','red-at-both','red','red')
    execute('new-file','bash bin/new-tool.sh || exit 1','red-at-both','red','red')
    execute('new-function','. bin/helper.sh; new_fn 2>/dev/null || exit 1','red-at-both','red','red')
    execute('missing-git-history','git rev-parse HEAD','red-at-both','red','red')
    execute('green','echo assertion-passed; exit 0','no-evidence','green','skipped')
    execute('cannot-run','exit 127','no-evidence','error','skipped')
    execute('timeout','echo waiting; sleep 120','no-evidence','timeout','skipped',extra=('--timeout','1'))
    execute('write-outside','echo changed > bin/helper.sh; exit 1','no-evidence','wrote-outside','skipped')
    execute('chmod-outside','chmod +x bin/helper.sh; exit 1','no-evidence','wrote-outside','skipped')
    execute('tests-write','mkdir -p tests/scratch; echo fixture > tests/scratch/input; exit 0','no-evidence','green','skipped')
    execute('scope-isolation', '''[ -z "${FM_HOME:-}${FM_TASK_ID:-}${FM_TASK_INBOX:-}${FM_STATE_OVERRIDE:-}${AK_LIFECYCLE_POLICY:-}" ] || exit 1
if read -r input; then exit 1; fi
[ ! -e .git ] || exit 1
. bin/helper.sh || exit 1
[ "$(greet)" = hello ] || exit 1
echo isolated-scope-closed-stdin-committed-helper-present''','no-evidence','green','skipped',env={'FM_TASK_INBOX':'private-inbox','FM_STATE_OVERRIDE':str(F/'sentinel-state'),'AK_LIFECYCLE_POLICY':'unattended'})
    for name,path in [('path-traversal','tests/../bin/live.test.sh'),('existing-path','tests/kept.test.sh'),('case-collision','tests/Kept.test.sh')]:
        execute(name,'echo should-not-run',path=path,rc=2)
    execute('supervisor','echo should-not-run',env={'FM_TASK_ID':''},rc=2)
    execute('contained-head','echo should-not-run',extra=('--base',HEAD),rc=2)
    args,env,out,_=command('green','echo should-not-replace')
    before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir()}
    p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=60)
    log.write('\nCASE evidence-reuse\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
    assert p.returncode==2
    assert before=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir()}
    records.append(dict(name='evidence-reuse',result='pass',exit=2))
    for status in (0,1):
        pidfile=F/('background-'+str(status)+'.pids')
        body=f"sleep 120 & echo $! >> '{pidfile}'\nbash -c 'sleep 120 & echo $!' >> '{pidfile}'\nexit {status}"
        execute('background-'+str(status),body,'no-evidence' if status==0 else 'red-at-both','green' if status==0 else 'red','skipped' if status==0 else 'red',extra=('--timeout','1'))
        children.extend(int(x) for x in pidfile.read_text().split())
        assert_children_gone()
    execute('termination-write', '''(trap 'echo changed > bin/helper.sh; exit 0' TERM
echo ready > tests/ready
while :; do sleep 1; done) &
while [ ! -e tests/ready ]; do sleep 0.02; done
exit 0''','no-evidence','wrote-outside','skipped')
    for group in (False,True):
        name='interrupt-group' if group else 'interrupt-pid'
        pidfile=F/(name+'.pid')
        args,env,out,_=command(name,f"echo $$ > '{pidfile}'\nsleep 120")
        with (E/(name+'.stdout')).open('w') as stdout,(E/(name+'.stderr')).open('w') as stderr:
            p=subprocess.Popen(args,env=env,stdout=stdout,stderr=stderr,start_new_session=True)
            try:
                deadline=time.monotonic()+45
                while not pidfile.exists() and p.poll() is None and time.monotonic()<deadline: time.sleep(.05)
                assert pidfile.exists(), name+' reproduction did not start'
                child=int(pidfile.read_text())
                children.append(child)
                if group: os.killpg(p.pid,signal.SIGTERM)
                else: p.terminate()
                code=p.wait(timeout=25)
                assert code!=0
                assert not alive(child)
                assert not list(SCRATCH.iterdir())
                assert not (out/'result').exists()
                log.write(f'\nCASE {name}\nreal CLI exit={code}; reproduction pid={child} stopped; scratch removed; no partial result published\n')
                records.append(dict(name=name,result='pass',exit=code,child=child))
            finally:
                if p.poll() is None:
                    os.killpg(p.pid,signal.SIGKILL)
                    p.wait()
    assert_children_gone()
    assert git('status','--porcelain')==original
    log.write('\nSource repository is unchanged. All owned child PIDs are stopped. Scratch is empty.\n')
except BaseException as err:
    log.write('\nDRIVER FAILURE '+repr(err)+'\n')
    raise
finally:
    for pid in children:
        if alive(pid):
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
    (E/'live-results.json').write_text(json.dumps(records,indent=2)+'\n')
    shutil.rmtree(F)
    log.close()
