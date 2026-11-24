"""Drive remote-source collection through isolated real local SSH processes."""
import json, os, pathlib, pwd, shlex, shutil, socket, subprocess, time
root=pathlib.Path.cwd()
lab=root/'.test-goal-digest/ssh'
lab.mkdir()
evidence=pathlib.Path(__file__).parent
for name in ('host','client'):
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(lab/name)],check=True)
shutil.copyfile(lab/'client.pub',lab/'authorized_keys')
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
user=pwd.getpwuid(os.getuid()).pw_name
(lab/'sshd_config').write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {lab}/host
PidFile {lab}/sshd.pid
AuthorizedKeysFile {lab}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {user}
LogLevel VERBOSE
''')
(lab/'ssh_config').write_text(f'''Host synthetic-digest
 HostName 127.0.0.1
 Port {port}
 User {user}
 IdentityFile {lab}/client
 IdentitiesOnly yes
 StrictHostKeyChecking no
 UserKnownHostsFile {lab}/known_hosts
''')
commands=lab/'commands';commands.mkdir()
(commands/'ssh').write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+shlex.quote(str(lab/'ssh_config'))+' "$@"\n')
(commands/'ssh').chmod(0o700)
home=lab/'home';(home/'config').mkdir(parents=True)
status=lab/"it's status.txt"
status.write_text('ETA: 2020-01-01 deliver\nprogress: started\n')
os.utime(status,(time.time()-259200,time.time()-259200))
review=lab/'review';review.write_text('T1: complete\nT8: pending\nAgentKit: round 3\n')
(home/'config/goal-digest').write_text(f'status = Local SSH status | ssh:synthetic-digest:{status}\nreview = Local SSH review | ssh:synthetic-digest:{review}\ntimeout_seconds = 3\n')
env=dict(os.environ,FM_HOME=str(home),PATH=str(commands)+':'+os.environ['PATH'])
sshd=None
with (evidence/'ssh-server.log').open('w') as log:
    try:
        sshd=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(lab/'sshd_config')],stdout=log,stderr=log,start_new_session=True)
        time.sleep(.5)
        probe=subprocess.run(['/usr/bin/ssh','-F',str(lab/'ssh_config'),'synthetic-digest','true'],text=True,capture_output=True,timeout=10)
        (evidence/'ssh-probe.log').write_text(f'exit={probe.returncode}\n'+probe.stdout+probe.stderr)
        if probe.returncode:
            print('UNTESTED: disposable sshd could not authenticate the workspace-only test key; inspect ssh-server.log and ssh-probe.log.')
        else:
            result=subprocess.run([str(root/'bin/fm-goal-digest.sh'),'run'],env=env,text=True,capture_output=True,timeout=30)
            (evidence/'ssh-digest.log').write_text(f'exit={result.returncode}\n'+result.stdout+result.stderr)
            assert result.returncode==0,result.stderr
            value=json.loads((home/'data/goal-digest/latest.json').read_text())
            assert not value['unreachable_sources'],value
            assert value['missed_etas'][0]['eta']=='2020-01-01'
            assert value['stalls'][0]['age_hours']==72
            assert value['review_convergence'][0]['entries']==['T1: complete','T8: pending','AgentKit: round 3']
            shutil.copyfile(home/'data/goal-digest/latest.md',evidence/'ssh-digest.md')
            shutil.copyfile(home/'data/goal-digest/latest.json',evidence/'ssh-digest.json')
            print('PASS: real localhost SSH reads an apostrophe-containing path, mtime, ETA and complete review ledger with disposable keys.')
    finally:
        if sshd:
            sshd.terminate()
            try:sshd.wait(timeout=10)
            except subprocess.TimeoutExpired:sshd.kill();sshd.wait()
