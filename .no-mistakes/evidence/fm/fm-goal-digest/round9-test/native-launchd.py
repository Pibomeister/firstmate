import json, os, pathlib, plistlib, shutil, subprocess as sp, time, traceback
R=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M85WPJHSW42PYT79RQP58A6K/round9-test')
W=R/'.test-goal-digest-current/launchd'
H=W/'home'
F=W/'fixture'
S=R/'bin/fm-goal-digest.sh'
(F/'config').mkdir(parents=True)
H.mkdir()
(F/'review.txt').write_text('T1: synthetic scheduler verification complete\n')
(F/'config/goal-digest').write_text(f'summarize = off\nreview = Synthetic scheduler | {F}/review.txt\n')
env=dict(os.environ,HOME=str(H),FM_HOME=str(F),TMPDIR=str(R/'.test-goal-digest-current/tmp'))
for k in ('FM_TEST_SEAM','FM_GOAL_DIGEST_CLAUDE','FM_GOAL_DIGEST_GH'):
    env.pop(k,None)
log=(E/'native-launchd-transcript.log').open('w',buffering=1)
def run(argv, **kwargs):
    r=sp.run(list(map(str,argv)),env=env,text=True,capture_output=True,timeout=30,**kwargs)
    log.write(json.dumps({'argv':list(map(str,argv)),'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\n')
    return r
label=None
verdict={'result':'fail','head':sp.check_output(['git','rev-parse','HEAD'],text=True).strip(),'oracle':'The installed 1200-second LaunchAgent must fire without kickstart or a manual product invocation, publish the synthetic review, exit 0, and be fully removed.'}
try:
    start=time.monotonic()
    r=run([S,'install'])
    plists=list((H/'Library/LaunchAgents').glob('*.plist'))
    assert len(plists)==1, r
    plist=plists[0]
    data=plistlib.loads(plist.read_bytes())
    label=data['Label']
    target=f'gui/{os.getuid()}/{label}'
    assert data['StartInterval']==1200
    assert data['EnvironmentVariables']['FM_HOME']==str(F)
    assert data['ProgramArguments']==[str(S),'run']
    shutil.copyfile(plist,E/'native-launchagent.plist')
    assert r.returncode==0,r
    r=run(['launchctl','print',target])
    (E/'native-launchd-registered.txt').write_text(r.stdout+r.stderr)
    assert r.returncode==0,r
    assert not (F/'data/goal-digest/latest.json').exists()
    print(f'REGISTERED {label}; waiting for the real 1200-second timer',flush=True)
    deadline=time.monotonic()+1290
    while time.monotonic()<deadline:
        r=run(['launchctl','print',target])
        assert r.returncode==0,r
        latest=F/'data/goal-digest/latest.json'
        if latest.exists() and 'last exit code = 0' in r.stdout:
            d=json.loads(latest.read_text())
            assert d['review_convergence'][0]['entries']==['T1: synthetic scheduler verification complete']
            assert d['changed'] is True
            assert list((F/'data/goal-digest/history').glob('*.json'))
            (E/'native-launchd-fired.txt').write_text(r.stdout)
            for name in ('latest.json','latest.md','launchd.log'):
                shutil.copyfile(F/'data/goal-digest'/name,E/('scheduled-'+name))
            verdict.update(result='pass',label=label,elapsed_seconds=round(time.monotonic()-start,3),cadence_seconds=1200,manual_start=False)
            print('PASS natural launchd timer fired the product and exited 0',flush=True)
            break
        time.sleep(5)
    else:
        raise AssertionError('No completed scheduled invocation within 1290 seconds')
except BaseException as ex:
    verdict['error']=repr(ex)
    traceback.print_exc()
finally:
    if label:
        r=run([S,'uninstall'])
        check=run(['launchctl','print',f'gui/{os.getuid()}/{label}'])
        verdict['cleanup']={'uninstall_exit':r.returncode,'absent_exit':check.returncode,'plist_absent':not (H/'Library/LaunchAgents'/f'{label}.plist').exists()}
        (E/'native-launchd-removed.txt').write_text(check.stdout+check.stderr)
        if r.returncode!=0 or check.returncode==0 or not verdict['cleanup']['plist_absent']:
            verdict['result']='fail'
    (E/'native-launchd-result.json').write_text(json.dumps(verdict,indent=2)+'\n')
    log.close()
    if verdict.get('cleanup',{}).get('absent_exit',0)!=0:
        shutil.rmtree(W)
raise SystemExit(0 if verdict['result']=='pass' else 1)
