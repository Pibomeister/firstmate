import os, pathlib, subprocess, json, shutil
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5WJ7HCFC7JBC37V8PH112BZ')
lab = root / '.test-phase-tmp' / 'live-home'
wt = root / '.test-phase-tmp' / 'preserved-copy'
lab.mkdir(); wt.mkdir()
(wt / 'uncommitted.txt').write_text('task copy must survive refusal\n')
env = os.environ.copy()
env['ORCA_USER_DATA_PATH']=str(root/'o')
env['HOME']=str(root/'.test-phase-tmp'/'orca-user-home')
for key in list(env):
    if key.startswith('FM_') and key.endswith('_OVERRIDE') or key in ('FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM'):
        env.pop(key, None)
transcript=[]
def run(args, expected=0, extra=None):
    use=env.copy(); use.update(extra or {})
    p=subprocess.run(args, cwd=root, env=use, text=True, capture_output=True, timeout=45)
    transcript.append({'command':args,'environment':extra or {},'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode == expected, transcript[-1]
    return p.stdout
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    handle='term_fm_lab_stale_01M5WJ7HCFC7JBC37V8PH112BZ'
    raw=run(['orca','terminal','show','--terminal',handle,'--json'],1)
    assert json.loads(raw)['error']['code']=='terminal_handle_stale'
    facts=run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_terminal_facts "$1"','_',handle])
    assert facts.split('\x1f')[0]=='stale'
    boot=int(run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_host_boot_epoch']))
    for harness in ['claude','droid']:
        task='live-'+harness
        meta=lab/'state'/(task+'.meta')
        record=f'backend=orca\nwindow=fm-{task}\nterminal={handle}\nendpoint_task_id={task}\nworktree={wt}\nproject={wt}\norca_worktree_id=wt-lab::{wt}\nharness={harness}\nkind=scout\nspawn_gen=s{boot+3600}.4242.99\n'
        meta.write_text(record)
        before=meta.read_bytes()
        for forged in [False,True]:
            extra={'FM_HOME':str(lab)}
            if forged: extra['FM_ORCA_BOOT_EPOCH']=str(boot+99999999)
            out=run(['bash','bin/fm-control.sh',task,'exit'],1,extra)
            assert 'does not postdate' in out or 'does not postdate' in transcript[-1]['stderr'], transcript[-1]
            assert 'endpoint-gone' not in out
            assert meta.read_bytes()==before
            assert (wt/'uncommitted.txt').read_text()=='task copy must survive refusal\n'
        # The fallback uses the record mtime, without a spawn generation.
        meta.write_text(record.rsplit('spawn_gen=',1)[0])
        out=run(['bash','bin/fm-control.sh',task,'exit'],1,{'FM_HOME':str(lab)})
        assert 'does not postdate' in transcript[-1]['stderr'], transcript[-1]
    for harness in ['claude','droid']:
        task='live-'+harness
        meta=lab/'state'/(task+'.meta')
        record=f'backend=orca\nwindow=fm-{task}\nterminal={handle}\nendpoint_task_id={task}\nworktree={wt}\nproject={wt}\norca_worktree_id=wt-lab::{wt}\nharness={harness}\nkind=scout\nspawn_gen=s{boot-3600}.4242.99\n'
        meta.write_text(record)
        before=meta.read_bytes()
        out=run(['bash','bin/fm-control.sh',task,'exit'],0,{'FM_HOME':str(lab)})
        assert 'endpoint-gone' in out, transcript[-1]
        assert meta.read_bytes()==before
        assert (wt/'uncommitted.txt').read_text()=='task copy must survive refusal\n'
    out=run(['bash','-c','. bin/backends/orca.sh; fm_backend_orca_endpoint_absence_proof "$1" "$2"','_',handle,str(wt)])
    assert out.startswith('unproven\t')
    transcript.append({'observation':'Both Claude and Droid exit refused current-boot records; a forged boot environment value did not change either verdict; mtime fallback refused; task metadata and uncommitted task copy survived. Exact nonzero Orca stale response decoded successfully. Both Claude and Droid pre-boot records reported endpoint-gone without a SessionEnd marker, using real kernel boot and isolated Orca sweep, and preserved metadata and copy.'})
finally:
    shutil.rmtree(lab)
    shutil.rmtree(wt)
    (evidence/'live-isolated.json').write_text(json.dumps(transcript,indent=2)+'\n')
