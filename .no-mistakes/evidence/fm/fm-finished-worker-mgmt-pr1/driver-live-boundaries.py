from pathlib import Path
source=Path('.gate-tests/live-monitoring.py').read_text().split("if __name__=='__main__':")[0]
source=source.replace("BASE=ROOT/'.gate-tests/live'", "BASE=ROOT/'.gate-tests/live-boundaries'").replace('live-monitoring.txt','live-boundaries.txt').replace('live-scenarios.json','live-boundary-scenarios.json')
exec(compile(source,'live-monitoring-shared','exec'),globals())

def stateless():
    notes=[]
    for label,snapshot in [('base',ROOT/'.gate-tests/baseline/bin/fm-fleet-snapshot.sh'),('target',ROOT/'bin/fm-fleet-snapshot.sh')]:
        h=BASE/('stateless-'+label);(h/'data').mkdir(parents=True);(h/'config').mkdir();(h/'projects').mkdir();(h/'user').mkdir()
        (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        e=ENV.copy();e.update(FM_HOME=str(h),HOME=str(h/'user'),CLAUDE_CONFIG_DIR=str(h/'user'),FM_ROOT_OVERRIDE=str(ROOT))
        rc,out,err=run([snapshot,'--json'],e)
        (E/('stateless-'+label+'.json')).write_text(out)
        assert json.loads(out)['schema']=='fm-fleet-snapshot.v1'
        notes.append((label,(h/'state').exists()))
        note(f'{label} real --json against a home without state: exit={rc}, state directory created={(h/"state").exists()}.')
    assert notes==[('base',False),('target',False)],'target read-only snapshot created state/; base preserved the stateless home'

def endpoints():
    h,e=home('endpoint');tmux=shutil.which('tmux');assert tmux,'tmux absent from PATH'
    (TOOLS/'tmux').symlink_to(tmux)
    runner=[ROOT/'bin/fm-lab-home.sh','tmux',h]
    try:
        run(runner+['new-session','-d','-s','endpoint','-x','80','-y','24','sleep 180'],e)
        rc,out,err=run(runner+['display-message','-p','-t','endpoint','#{socket_path},#{pid},0'],e)
        e['TMUX']=out.strip()
        for name in ['lab-one','lab-two','lab-three']:
            (h/'state'/f'{name}.meta').write_text('kind=secondmate\nharness=codex\nbackend=tmux\nwindow=endpoint:0.0\n')
        observations={}
        for label,snapshot in [('base',ROOT/'.gate-tests/baseline/bin/fm-fleet-snapshot.sh'),('target',ROOT/'bin/fm-fleet-snapshot.sh')]:
            rc,out,err=run([snapshot,'--json'],e,timeout=100)
            (E/('real-tmux-snapshot-'+label+'.json')).write_text(out)
            data=json.loads(out);observations[label]=[(task['id'],task['endpoint']) for task in data['tasks']]
            note(f'{label} real snapshot of a private tmux endpoint: {observations[label]}')
        assert all(endpoint['exists'] is True for _,endpoint in observations['target']), 'target lost endpoint presence for a real private tmux pane'
    finally:
        run(runner+['kill-server'],e,check=False)
        run([ROOT/'bin/fm-lab-home.sh','teardown',h],e)
try:
    scenario('A read-only full snapshot preserves a synthetic stateless home without creating operational state',stateless)
    scenario('Full snapshot reports presence of a real private tmux pane for synthetic secondmate records',endpoints)
finally:
    for p in children:stop(p)
    note('Boundary checks stopped all owned process groups and the private tmux server; disposable homes removed.')
    shutil.rmtree(BASE);transcript.close()
sys.exit(any(r['result']!='pass' for r in results))
