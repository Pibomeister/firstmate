import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import termios
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5TWX28QV7MK1HBVJB807Z3Q/test-followup-3')
LAB = ROOT / '.t3'
LAB.mkdir(mode=0o700)
RECORDS = []


def command(argv, label, env=None, timeout=25):
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    proc = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, start_new_session=True)
    timed_out = False
    try:
        output, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            output, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            output, _ = proc.communicate()
    (EVIDENCE / (label + '.log')).write_text(output)
    record = dict(label=label, command=shlex.join(argv), started=started,
                  exit_code=proc.returncode, timed_out=timed_out,
                  output_sha256=hashlib.sha256(output.encode()).hexdigest())
    RECORDS.append(record)
    print(json.dumps(record), flush=True)
    print(output[-3500:], flush=True)
    return record


for scenario in ['orca-exit-relaunch', 'orca-refuse-duplicate']:
    lab = LAB / scenario
    lab.mkdir()
    policy = lab / 'boundary.sb'
    # File writes outside the worktree and service-mediated writes are blocked.
    policy.write_text('(version 1)\n(allow default)\n(deny file-write*)\n'
                      f'(allow file-write* (subpath "{ROOT}"))\n'
                      '(deny mach-lookup)\n(deny network*)\n'
                      '(allow network-outbound (remote ip "localhost:*"))\n'
                      '(allow network-inbound (local ip "localhost:*"))\n')
    env = dict(os.environ, HOME=str(lab), XDG_CONFIG_HOME=str(lab / 'config'),
               XDG_DATA_HOME=str(lab / 'data'), XDG_CACHE_HOME=str(lab / 'cache'),
               TMPDIR=str(ROOT / '.test-validation/tmp'))
    command(['sandbox-exec', '-f', str(policy), 'orca', 'serve',
             '--project-root', str(lab), '--no-pairing', '--json'], scenario, env)

command(['orca', 'serve', '--help'], 'orca-serve-help')
command(['orca', 'terminal', 'create', '--help'], 'orca-terminal-create-help')

# Use only the credential path already supported by the repository's live guard.
auth = Path(os.environ.get('FM_GROK_AUTH_FILE', str(Path.home() / '.grok/auth.json')))
credential = {'source': str(auth), 'readable': auth.is_file() and os.access(auth, os.R_OK)}
original_digest = hashlib.sha256(auth.read_bytes()).hexdigest() if credential['readable'] else None
grok_lab = LAB / 'grok'
grok_lab.mkdir()
for name in ['home', 'gh', 'config', 'data', 'cache']:
    (grok_lab / name).mkdir(mode=0o700)
if credential['readable']:
    shutil.copyfile(auth, grok_lab / 'gh/auth.json')
    (grok_lab / 'gh/auth.json').chmod(0o600)
env = dict(os.environ, HOME=str(grok_lab / 'home'), GROK_HOME=str(grok_lab / 'gh'),
           XDG_CONFIG_HOME=str(grok_lab / 'config'), XDG_DATA_HOME=str(grok_lab / 'data'),
           XDG_CACHE_HOME=str(grok_lab / 'cache'), TMPDIR=str(ROOT / '.test-validation/tmp'),
           TERM='xterm-256color', GROK_AGENT='1')
for key in ['TMUX', 'TMUX_PANE', 'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_TASK_ID',
            'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE']:
    env.pop(key, None)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 116, 0, 0))
argv = ['grok', '--cwd', str(grok_lab), '--no-alt-screen', '--leader-socket', 'g.sock']
proc = subprocess.Popen(argv, cwd=grok_lab, env=env, stdin=slave,
                        stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
raw = bytearray()
deadline = time.monotonic() + 25
try:
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.25)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            raw.extend(chunk)
        if proc.poll() is not None:
            break
finally:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)
    os.close(master)
text = raw.decode(errors='replace')
text = re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)', '', text)
text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text).replace('\r', '')
text = re.sub(r'https?://[^\s\x1b]+', '<URL REDACTED>', text)
(EVIDENCE / 'grok-existing-auth-start.txt').write_text(text)
credential['source_bytes_unchanged'] = not credential['readable'] or hashlib.sha256(auth.read_bytes()).hexdigest() == original_digest
record = dict(label='grok-existing-auth', command=shlex.join(argv), cwd=str(grok_lab),
              exit_code=proc.returncode, no_input_sent=True, observed_seconds=25,
              credential=credential,
              output_sha256=hashlib.sha256(text.encode()).hexdigest())
RECORDS.append(record)
print(json.dumps(record), flush=True)
print(text[-6000:], flush=True)
(EVIDENCE / 'commands.json').write_text(json.dumps(RECORDS, indent=2) + '\n')
