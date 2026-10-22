import os
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
evidence = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
original = subprocess.check_output
log = (evidence / 'terminal-cleanup-diagnosis.txt').open('w')

def observed(*args, **kwargs):
    result = original(*args, **kwargs)
    if args[0][-1] == 'status':
        log.write(result + '\n')
        log.flush()
        if 'serving=0 waiting=0 stale=1 ' in result:
            log.write('Observed no occupied slot; one dead ticket awaits next run reclamation.\n')
            follow = subprocess.run(['/bin/bash', str(root / 'bin/fm-test-queue.sh'), 'run', '--', 'printf', 'followup-admitted\n'], env=kwargs.get('env'), capture_output=True, text=True, timeout=20)
            log.write(follow.stdout + follow.stderr + f'followup exit={follow.returncode}\n')
            log.write(original(*args, **kwargs))
            log.flush()
    return result

subprocess.check_output = observed
try:
    for n in range(3, 6):
        case = root / f'.queue-validation-tmp/diagnose-{n}'
        (case / 'spool').mkdir(parents=True)
        (case / 'spool/config').write_text('slots=1\nload_ceiling=100000\n')
        os.environ['FM_TEST_QUEUE_DIR'] = str(case / 'spool')
        os.environ['FM_TEST_QUEUE_POLL'] = '.1'
        os.environ.pop('FM_TEST_QUEUE_HELD', None)
        os.environ.pop('FM_TEST_SEAM', None)
        sys.argv = [str(root / 'tests/fm-test-queue-pty.py'), str(root / 'bin/fm-test-queue.sh'), '/bin/bash', str(case)]
        scope = {'__name__': '__main__'}
        log.write(f'RUN {n}\n')
        try:
            source = (root / 'tests/fm-test-queue-pty.py').read_text()
            source = source.replace('    (case / "release-background").touch()\n    (case / "release-grandchild").touch()', '''    if sys.exc_info()[0]:
        print("FAILURE STATE", file=sys.stderr)
        print(status(), file=sys.stderr)
        for item in tickets():
            print(item, file=sys.stderr)
            if item.get("pgid"):
                members = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,stat=,command="], text=True)
                for row in members.splitlines():
                    if row.split()[2] == item["pgid"]:
                        print(row, file=sys.stderr)
    (case / "release-background").touch()
    (case / "release-grandchild").touch()''')
            exec(compile(source, sys.argv[0], 'exec'), scope)
        except AssertionError as exc:
            log.write(f'Original assertion failed: {exc}\n')
            raise
        finally:
            (evidence / f'terminal-diagnostic-{n}.txt').write_text(bytes(scope.get('output', b'')).decode(errors='replace'))
finally:
    log.close()
