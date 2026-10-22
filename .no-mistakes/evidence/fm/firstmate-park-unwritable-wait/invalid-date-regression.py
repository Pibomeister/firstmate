import os
from pathlib import Path
import shutil
import subprocess as sp
E = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J69ZR1KR6Z67YZ17HJFWEY')
home = Path.cwd() / '.test-park-invalid-date'
env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env['FM_HOME'] = str(home)
lines = []
try:
    sp.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=env,capture_output=True,check=True)
    status = home/'state/task.status'
    (home/'state/task.meta').write_text('kind=ship\nbackend=orca\nwindow=inert-unavailable-endpoint\n')
    status.write_text('working: delivered PR waiting on review\n')
    before = status.read_bytes()
    args = ['bash','bin/fm-park.sh','task','--until','2099-02-30T12:00Z','--reason','quota exhausted; PR awaiting review']
    p = sp.run(args,env=env,text=True,capture_output=True)
    lines += ['$ ' + ' '.join(args),f'exit={p.returncode}',p.stdout,p.stderr,'persisted state after request:',status.read_text()]
    shutil.copyfile(status,E/'invalid-date-regression-status.txt')
    assert p.returncode != 0 and status.read_bytes() == before, 'invalid calendar deadline must be refused without appending a wait'
finally:
    shutil.rmtree(home,ignore_errors=True)
    lines.append('teardown: disposable lab home removed')
    (E/'invalid-date-regression.txt').write_text('\n'.join(lines))
    print('\n'.join(lines))
