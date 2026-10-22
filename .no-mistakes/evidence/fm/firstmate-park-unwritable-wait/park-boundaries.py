import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess as sp
import time
ROOT = Path.cwd()
E = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J69ZR1KR6Z67YZ17HJFWEY')
HOME = ROOT / '.test-park-boundaries'
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND']}
env['FM_HOME'] = str(HOME)
log = []
def invoke(args, ok):
    p = sp.run(['bash','bin/fm-park.sh',*args], env=env, text=True, capture_output=True)
    log.append('$ bin/fm-park.sh ' + repr(args) + '\n' + f'exit={p.returncode}\n' + p.stdout + p.stderr)
    assert (p.returncode == 0) == ok
    return p
try:
    sp.run(['bash','bin/fm-lab-home.sh','create',str(HOME)],env=env,check=True,capture_output=True)
    state = HOME / 'state'
    (state/'task.meta').write_text('backend=orca\nkind=ship\nwindow=unavailable-inert-endpoint\n')
    (state/'task.status').write_text('working: delivered PR waiting on review\n')
    future = dt.datetime.fromtimestamp(time.time()+86400,dt.timezone.utc).strftime('%Y-%m-%dT%H:%MZ')
    initial = (state/'task.status').read_bytes()
    cases = {
       'unknown task':['missing','--until',future,'--reason','waiting'],
       'traversal':['../task','--until',future,'--reason','waiting'],
       'no deadline':['task','--reason','waiting'],
       'non-UTC':['task','--until','2099-01-01T12:00+01:00','--reason','waiting'],
       'past':['task','--until','2020-01-01T12:00Z','--reason','waiting'],
       'blank reason':['task','--until',future,'--reason',' \n\t '],
       'no reason':['task','--until',future],
       'over limit':['task','--until',future,'--reason','x'*240],
       'unknown flag':['task','--until',future,'--reason','waiting','--key','other'],
    }
    for label,args in cases.items():
        invoke(args,False)
        assert (state/'task.status').read_bytes() == initial
        assert not (state/'missing.status').exists()
        log.append('PASS ' + label + ': refused; persisted task status byte-for-byte unchanged')
    expected = future[:-1]+':30Z'
    invoke(['task','--until',expected,'--reason','quota exhausted until 2020-01-01T12:00Z'],True)
    epoch = int(dt.datetime.strptime(expected,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp())
    parser = ['bash','-c','. bin/fm-classify-lib.sh; line=$(status_declared_wait_line "$FM_HOME/state/task.status"); printf "%s\\n" "$line"; status_paused_until "$line"']
    p = sp.run(parser,env=env,text=True,capture_output=True,check=True)
    log.append('Public persisted wait and shared consumer:\n'+p.stdout)
    assert p.stdout.strip().splitlines()[-1] == str(epoch)
    # Re-park with minute precision and a seconds timestamp in the reason.
    invoke(['task','--until='+future,'--reason=review until 2020-01-01T12:00:30Z\nquota reset later'],True)
    p = sp.run(parser,env=env,text=True,capture_output=True,check=True)
    log.append('Re-parked persisted wait and shared consumer:\n'+p.stdout)
    expected_epoch = int(dt.datetime.strptime(future,'%Y-%m-%dT%H:%MZ').replace(tzinfo=dt.timezone.utc).timestamp())
    assert p.stdout.strip().splitlines()[-1] == str(expected_epoch)
    assert len((state/'task.status').read_text().splitlines()) == 3
    log.append('PASS unavailable Orca endpoint: supervisor-side park and re-park succeeded without worker cooperation; requested seconds/minute deadlines won over reason timestamps; multiline reason stayed one event')
    shutil.copyfile(state/'task.status',E/'orca-park-status.txt')
    before_bad = (state/'task.status').read_bytes()
    invoke(['task','--until','2099-02-30T12:00Z','--reason','waiting'],True)
    p = sp.run(parser,env=env,text=True,capture_output=True,check=True)
    log.append('FAIL invalid calendar date accepted and persisted as a different date:\n'+p.stdout)
    assert (state/'task.status').read_bytes() != before_bad
    shutil.copyfile(state/'task.status',E/'invalid-date-status.txt')
finally:
    shutil.rmtree(HOME,ignore_errors=True)
    log.append('teardown: disposable lab home removed')
    (E/'park-boundaries-transcript.txt').write_text('\n'.join(log)+'\n')
    print('\n'.join(log))
