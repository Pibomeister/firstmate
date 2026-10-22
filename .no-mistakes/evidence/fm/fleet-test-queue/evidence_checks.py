import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys

root = Path.cwd()
tmp = root / '.queue-validation-tmp'
evidence = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
case = tmp / 'terminal-evidence'
case.mkdir()
(case / 'spool').mkdir()
(case / 'spool/config').write_text('slots=1\nload_ceiling=100000\n')
os.environ['FM_TEST_QUEUE_DIR'] = str(case / 'spool')
os.environ['FM_TEST_QUEUE_POLL'] = '0.1'
os.environ.pop('FM_TEST_QUEUE_HELD', None)
os.environ.pop('FM_TEST_SEAM', None)
sys.argv = [str(root / 'tests/fm-test-queue-pty.py'), str(root / 'bin/fm-test-queue.sh'), '/bin/bash', str(case)]
scope = {'__name__': '__main__'}
try:
    exec(compile((root / 'tests/fm-test-queue-pty.py').read_text(), sys.argv[0], 'exec'), scope)
finally:
    (evidence / 'queue-live-terminal.txt').write_text(bytes(scope.get('output', b'')).decode(errors='replace'))

home = tmp / 'brief-home'
(home / 'data').mkdir(parents=True)
foreign = tmp / "firstmate helper's root"
(foreign / 'bin').mkdir(parents=True)
shutil.copy2(root / 'bin/fm-test-queue.sh', foreign / 'bin/fm-test-queue.sh')
spool = tmp / 'brief-spool'
spool.mkdir()
(spool / 'config').write_text('slots=1\nload_ceiling=100000\n')
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(foreign), FM_TEST_QUEUE_DIR=str(spool))
rules = []
with (evidence / 'brief-live-cli.txt').open('w') as log:
    log.write('Actual fm-brief.sh output; emitted commands execute the real fm-test-queue.sh copied into a root with spaces and an apostrophe.\n')
    for mode in ('no-mistakes', 'direct-PR', 'local-only', 'scout'):
        args = ['/bin/bash', str(root / 'bin/fm-brief.sh'), mode, 'sample-project']
        args += ['--scout'] if mode == 'scout' else ['--mode', mode]
        generated = subprocess.run(args, env=env, text=True, capture_output=True)
        assert generated.returncode == 0, generated.stderr
        brief = (home / f'data/{mode}/brief.md').read_text()
        rule = next(line for line in brief.splitlines() if 'Run heavy test suites only through' in line)
        rules.append(rule)
        log.write(f'\n{mode}:\n{rule}\n')
        command = rule.split('`')[1].replace('<command>', "printf '%s\\n' 'real queue workload completed'")
        result = subprocess.run(['/bin/bash', '-c', command], env=env, text=True, capture_output=True)
        log.write('$ ' + command + '\n' + result.stdout + result.stderr + f'[exit {result.returncode}]\n')
        assert result.returncode == 0 and result.stdout == 'real queue workload completed\n'
    assert len(set(rules)) == 1
    final = subprocess.check_output(['/bin/bash', str(foreign / 'bin/fm-test-queue.sh'), 'status'], env=env, text=True)
    log.write('\nAll four emitted rules are identical.\n' + final)
    assert 'serving=0 waiting=0 stale=0' in final
print('PTY and real generated-command evidence captured.')
