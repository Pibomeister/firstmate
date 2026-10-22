import os,pathlib,subprocess,shutil
root=pathlib.Path.cwd()
base=root/'.test-phase-scratch'/'brief-product'
base.mkdir()
foreign=base/"firstmate helper's root"
(foreign/'bin').mkdir(parents=True)
shutil.copy2(root/'bin/fm-test-queue.sh',foreign/'bin/fm-test-queue.sh')
home=base/'isolated-home';(home/'data').mkdir(parents=True)
spool=base/'spool';spool.mkdir();(spool/'config').write_text('slots=1\nload_ceiling=100000\n')
env=dict(os.environ,FM_HOME=str(home),FM_ROOT_OVERRIDE=str(foreign),FM_TEST_QUEUE_DIR=str(spool),TMPDIR=str(root/'.test-phase-scratch'))
for k in ('FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_QUEUE_HELD','FM_TEST_SEAM','FM_TEST_QUEUE_LOAD_FILE'):env.pop(k,None)
log=[]
def note(s):log.append(s);print(s,flush=True)
try:
    note('Revision: '+subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    rules=[]
    for mode in ('no-mistakes','direct-PR','local-only','scout'):
        task='queue-evidence-'+mode
        args=['--scout'] if mode=='scout' else ['--mode',mode]
        cmd=['/bin/bash','bin/fm-brief.sh',task,'alpha']+args
        p=subprocess.run(cmd,env=env,capture_output=True,text=True)
        note('$ '+ ' '.join(cmd)+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]')
        assert p.returncode==0
        brief=(home/'data'/task/'brief.md').read_text()
        rule=next(line for line in brief.splitlines() if 'Run heavy test suites only through' in line)
        rules.append(rule)
        note('Generated public brief rule:\n'+rule)
        command=rule.split('`')[1].replace('<command>',"printf '%s\\n' 'actual queued workload'")
        p=subprocess.run(['/bin/bash','-c',command],env=env,capture_output=True,text=True)
        note('$ '+command+'\n'+p.stdout+p.stderr+f'[exit {p.returncode}]')
        assert p.returncode==0 and p.stdout=='actual queued workload\n'
    assert len(set(rules))==1
    p=subprocess.run(['/bin/bash',str(foreign/'bin/fm-test-queue.sh'),'status'],env=env,capture_output=True,text=True)
    note('$ fm-test-queue.sh status\n'+p.stdout)
    assert 'serving=0 waiting=0 stale=0' in p.stdout
    note('All ship/scout rules are identical; each emitted command executed the real queue from a path containing spaces and an apostrophe.')
finally:
    pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5JW8KCSACJJWWF0BM98FFES/live-brief-transcript.log').write_text('\n\n'.join(log)+'\n')
