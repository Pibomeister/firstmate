import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

root = Path.cwd()
lab = root / '.t3/grok'
evidence = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5TWX28QV7MK1HBVJB807Z3Q/test-followup-3')
socket = str(root / '.t3/t')
leader = str(root / '.t3/g')
tmux = shutil.which('tmux')
env = dict(os.environ, HOME=str(lab / 'home'), GROK_HOME=str(lab / 'gh'),
           XDG_CONFIG_HOME=str(lab / 'config'), XDG_DATA_HOME=str(lab / 'data'),
           XDG_CACHE_HOME=str(lab / 'cache'), TMPDIR=str(root / '.test-validation/tmp'),
           TERM='xterm-256color')
for key in list(env):
    if key.startswith('FM_') or key in ['TMUX', 'TMUX_PANE', 'GROK_AGENT']:
        env.pop(key, None)
argv = ['grok', '--cwd', str(lab), '--no-alt-screen', '--leader-socket', leader]
auth = Path(os.environ.get('FM_GROK_AUTH_FILE', str(Path.home() / '.grok/auth.json')))
original_digest = hashlib.sha256(auth.read_bytes()).hexdigest()
subprocess.run(['git', 'init', '-q', str(lab)], check=True, capture_output=True)

def call(args, **kwargs):
    return subprocess.run([tmux, '-S', socket, *args], cwd=root, env=env,
                          capture_output=True, text=True, timeout=10, **kwargs)

record = {'command': shlex.join(argv), 'terminal': {'columns': 116, 'rows': 36},
          'input_sent': [], 'auth': 'copy of existing supported auth.json', 'captures': []}
try:
    started = call(['-f', '/dev/null', 'new-session', '-d', '-s', 'test3',
                    '-x', '116', '-y', '36', '-c', str(lab), shlex.join(argv)])
    record['tmux_start_exit'] = started.returncode
    if started.returncode:
        raise RuntimeError(started.stderr)
    for second in [3, 10, 20]:
        time.sleep(second - (0 if second == 3 else 3 if second == 10 else 10))
        capture = call(['capture-pane', '-p', '-t', 'test3:0', '-S', '-100'])
        text = re.sub(r'https?://[^\s]+', '<URL REDACTED>', capture.stdout)
        if ('Do you trust the contents of this directory?' in text
                and str(lab) in text and not record['input_sent']):
            (evidence / 'grok-lab-directory-trust.txt').write_text(text)
            approved = call(['send-keys', '-t', 'test3:0', 'y'])
            record['input_sent'].append({'key': 'y', 'purpose': 'trust disposable lab directory only',
                                         'exit_code': approved.returncode})
        path = evidence / f'grok-existing-auth-{second}s.txt'
        path.write_text(text)
        record['captures'].append({'after_seconds': second, 'path': str(path),
                                   'exit_code': capture.returncode,
                                   'sha256': hashlib.sha256(text.encode()).hexdigest()})
        if capture.returncode:
            record['capture_error'] = capture.stderr
            break
        print(text, flush=True)
    content = (evidence / 'grok-existing-auth-20s.txt').read_text()
    result = subprocess.run(['bash', '-c',
                             '. bin/fm-composer-lib.sh; fm_composer_classify_screen "styled=0" "$(cat "$1")"',
                             '_', str(evidence / 'grok-existing-auth-20s.txt')],
                            cwd=root, capture_output=True, text=True, env=env, timeout=10)
    record['production_classifier'] = {'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
finally:
    stopped = call(['kill-server'])
    record['cleanup_exit_code'] = stopped.returncode
    record['original_auth_bytes_unchanged'] = hashlib.sha256(auth.read_bytes()).hexdigest() == original_digest
    (evidence / 'grok-tmux.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2), flush=True)
