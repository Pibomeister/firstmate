"""Verify actual generated LaunchAgent command and archive publication failure.

The isolated PATH deliberately omits launchctl, so this cannot alter the host's
service registry. This does not claim launchd activation or a timed daemon run.
"""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess

root=pathlib.Path.cwd()
lab=root/'.test-goal-digest/schedule-archive'
lab.mkdir()
evidence=pathlib.Path(__file__).parent
commands=lab/'commands'
commands.mkdir()
for name in ('bash','dirname','mkdir','sed','cksum','cat','python3','date','rm','mktemp',
             'sort','mv','shasum','awk','cut','grep','head','tr','stat'):
    binary=shutil.which(name)
    assert binary, name
    (commands/name).symlink_to(binary)
home=lab/'home'
(home/'config').mkdir(parents=True)
review=home/'review'
review.write_text('T1: pending\nT8: complete\n')
(home/'config/goal-digest').write_text(f'review = Review | {review}\ninterval_seconds = 1\n')
env=dict(os.environ,FM_HOME=str(home),HOME=str(home),PATH=str(commands))
script=root/'bin/fm-goal-digest.sh'
logs=[]
def execute(args,expected=0):
    result=subprocess.run(args,env=env,text=True,capture_output=True,timeout=60)
    logs.append({'command':args,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    assert (result.returncode==0)==(expected==0),result.stderr
    return result
execute([str(script),'install'])
plist=next((home/'Library/LaunchAgents').glob('*.plist'))
definition=plistlib.loads(plist.read_bytes())
assert definition['StartInterval']==1200
assert definition['ProgramArguments']==[str(script),'run']
assert definition['EnvironmentVariables']['FM_HOME']==str(home)
shutil.copyfile(plist,evidence/'08-launchagent.plist')
(evidence/'08-launchagent.json').write_text(json.dumps(definition,indent=2)+'\n')
# Execute exactly the emitted program and declared environment, as launchd will.
env=definition['EnvironmentVariables']
execute(definition['ProgramArguments'])
out=home/'data/goal-digest'
assert json.loads((out/'latest.json').read_text())['review_convergence'][0]['entries']==['T1: pending','T8: complete']
shutil.copyfile(out/'latest.md',evidence/'08-scheduled-command-digest.md')
before={n:(out/n).read_bytes() for n in ('latest.json','latest.md','.state/seen.tsv','.state/since.tsv','.state/content.hash')}
review.write_text('T1: complete\nT8: complete\n')
(out/'history').chmod(0o500)
try:
    execute([str(script),'run'],expected=1)
    assert all((out/n).read_bytes()==v for n,v in before.items())
finally:
    (out/'history').chmod(0o700)
execute([str(script),'run'])
assert json.loads((out/'latest.json').read_text())['changed'] is True
shutil.copyfile(out/'latest.md',evidence/'05-archive-permissions-recovered.md')
execute([str(script),'uninstall'])
assert not plist.exists()
(evidence/'schedule-archive-transcript.json').write_text(json.dumps(logs,indent=2)+'\n')
print('PASS: 1200-second generated LaunchAgent; exact declared command writes isolated digest.')
print('PASS: unwritable archive rejects publication and preserves both latest files and all notification state; retry publishes change.')
print('UNTESTED: actual launchd activation/20-minute firing; host service mutations forbidden by workspace boundary.')
