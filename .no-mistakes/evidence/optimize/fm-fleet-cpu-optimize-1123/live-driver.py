import os, subprocess, json, shutil
from pathlib import Path
root=Path.cwd(); tmp=root/'.nm-validation'; ev=Path('~/.no-mistakes/evidence/01M87HDDK5H17G11VP6A2ZZE3D')
lab=tmp/'live-home'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE','REX_SESSION','REX_BLOCK','ORCA_TERMINAL_HANDLE']: env.pop(k,None)
env.update(FM_HOME=str(lab),TMPDIR=str(tmp/'tmp'),FM_SNAPSHOT_NOW='2026-11-24T12:00:00Z',FM_SNAPSHOT_NOW_EPOCH='1795521600',FM_CREW_STATE_NO_FORGE='1')
trans=[]
def run(label,args):
    p=subprocess.run(args,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=90)
    (ev/(label+'.stdout')).write_text(p.stdout); (ev/(label+'.stderr')).write_text(p.stderr)
    trans.append({'label':label,'command':args,'exit':p.returncode})
    (ev/'live-commands.json').write_text(json.dumps(trans,indent=2))
    assert p.returncode==0,(label,p.returncode,p.stderr)
    return p.stdout
def meta(id,lines,status=None):
    (lab/'state'/(id+'.meta')).write_text('\n'.join(lines)+'\n')
    if status is not None:(lab/'state'/(id+'.status')).write_text(status)
def snapshot(label):return json.loads(run(label,['/bin/bash','bin/fm-fleet-snapshot.sh','--json']))
def rows(s):return {r['id']:r for r in s['tasks']}
try:
    run('lab-create',['/bin/bash','bin/fm-lab-home.sh','create',str(lab)])
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    wt=lab/'projects/local'; wt.mkdir()
    (lab/'data/alpha').mkdir();(lab/'data/alpha/report.md').write_text('# Synthetic scout report\n')
    meta('alpha',['kind=scout','harness=codex','project=old','project=synthetic=project','mode=scout','yolo=off','worktree='+str(wt),'spawn_gen=live-one','pr=https://example.invalid/pull/42','pr_head=synthetic-head'], 'needs-decision [key=api] [at=1795521500]: choose REST\nblocked: [key=token] missing token\nworking: unrelated update\n')
    meta('missing',['kind=scout','harness=codex','worktree='+str(lab/'projects/absent')])
    meta('remote',['kind=ship','harness=codex','remote_host=synthetic.invalid','remote_backend=tmux','remote_target=fm-lab:unused','home=/synthetic/remote-home','worktree=/synthetic/remote-worktree'])
    s=snapshot('snapshot-open');r=rows(s)
    assert s['schema']=='fm-fleet-snapshot.v1'
    assert r['alpha']['project']=='synthetic=project'
    assert r['alpha']['pr']['url']=='https://example.invalid/pull/42'
    assert r['alpha']['pr']['head']=='synthetic-head'
    assert r['alpha']['hints']['pending_decision'] is True and r['alpha']['hints']['blocked_event'] is True
    assert r['alpha']['hints']['open_decisions']==[{'key':'api','verb':'needs-decision','summary':'choose REST'},{'key':'token','verb':'blocked','summary':'missing token'}]
    assert r['alpha']['paths']['worktree']['present'] is True and r['alpha']['paths']['report']['present'] is True
    assert r['alpha']['hints']['last_event_text']=='working: unrelated update'
    assert r['missing']['paths']['status_log']['present'] is False
    assert r['missing']['paths']['status_log']['last_event']['age_seconds'] is None
    assert r['missing']['paths']['worktree']['present'] is False
    assert r['remote']['paths']['home']['present'] is None and r['remote']['remote']['host']=='synthetic.invalid'
    assert any(x['id']=='alpha' and x['path']==str(lab/'data/alpha/report.md') and x['kind']=='scout' for x in s['scout_reports'])
    v=run('fleet-view',['/bin/bash','bin/fm-fleet-view.sh']);assert 'alpha' in v and 'missing' in v
    c=json.loads(run('contribution-input',['/bin/bash','bin/fm-fleet-snapshot.sh','--contribution-input']))
    assert any(t['id']=='alpha' and t['pr']['url']=='https://example.invalid/pull/42' for t in c['tasks'])
    d=run('drain-open',['/bin/bash','bin/fm-wake-drain.sh']);assert 'OPEN DECISIONS' in d and '[key=api]' in d and '[key=token]' in d
    with (lab/'state/alpha.status').open('a') as f:f.write('resolved [key=api]: REST selected\nresolved [key=other]: unrelated resolution\nblocked [key=pending-reply-abc]: copied reserved key\n')
    d=run('drain-resolved-api',['/bin/bash','bin/fm-wake-drain.sh']);section=d.split('OPEN DECISIONS',1)[1];assert '[key=token]' in section and '[key=api]' not in section and '[key=pending-reply-abc]' not in section
    s=snapshot('snapshot-resolved-api');a=rows(s)['alpha'];assert a['hints']['pending_decision'] is False and a['hints']['blocked_event'] is True
    assert a['hints']['open_decisions']==[{'key':'token','verb':'blocked','summary':'missing token'}]
    # Same-file truncation must discard cached decisions rather than resurrect api/token.
    (lab/'state/alpha.status').write_text('needs-decision [key=new] [at=1795521500]: new question\n')
    d=run('drain-truncated',['/bin/bash','bin/fm-wake-drain.sh']);section=d.split('OPEN DECISIONS',1)[1];assert '[key=new]' in section and '[key=token]' not in section and '[key=api]' not in section
    s=snapshot('snapshot-truncated');a=rows(s)['alpha'];assert a['paths']['status_log']['last_event']['age_seconds']==100
    assert a['hints']['open_decisions']==[{'key':'new','verb':'needs-decision','summary':'new question'}]
    with (lab/'state/alpha.status').open('a') as f:f.write('done: report ready\n')
    d=run('drain-terminal',['/bin/bash','bin/fm-wake-drain.sh']);assert 'OPEN DECISIONS' not in d
    s=snapshot('snapshot-terminal');assert rows(s)['alpha']['hints']['open_decisions']==[]
    (ev/'live-result.json').write_text(json.dumps({'snapshot':'pass','decision_lifecycle':'pass','inputs':'synthetic metadata, report, and append/truncate status histories; no live fleet or endpoint contacted','assertions':'independent documented snapshot schema, key isolation, reserved-key guard, 100-second event age, terminal close'},indent=2))
    print('Live snapshot and decision lifecycle assertions passed',flush=True)
finally:
    shutil.rmtree(lab,ignore_errors=True)
