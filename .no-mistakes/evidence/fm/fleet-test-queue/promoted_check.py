import os
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
evidence = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
source = (root / 'tests/fm-test-queue-pty.py').read_text()
prefix = source[:source.index('\ntry:\n')]
body = source[source.index('    promoted = background('):source.index('    (case / "grandchild.sh").write_text(')]
body = body.replace('    send(\'fg; printf', '    before_fg = (case / "heartbeat").read_text()\n    send(\'fg; printf')
body = body.replace('    os.write(terminal, b"\\x03")', '    until("foreground workload heartbeat", lambda: (case / "heartbeat").read_text() not in ("", before_fg))\n    os.write(terminal, b"\\x03")')
body = body.replace('    assert "serving=0 waiting=0 stale=0 " in status()', '    final_status = status()\n    print(final_status, flush=True)\n    assert "serving=0 waiting=0 stale=0 " in final_status')
suffix = source[source.index('\nfinally:\n'):]
suffix = suffix.replace('finally:\n', '''finally:
    if sys.exc_info()[0]:
        print("FAILURE STATE", status(), flush=True)
''', 1)
for n in range(3):
    case = root / f'.queue-validation-tmp/promoted-{n}'
    (case / 'spool').mkdir(parents=True)
    (case / 'spool/config').write_text('slots=1\nload_ceiling=100000\n')
    os.environ['FM_TEST_QUEUE_DIR'] = str(case / 'spool')
    os.environ['FM_TEST_QUEUE_POLL'] = '.1'
    os.environ.pop('FM_TEST_QUEUE_HELD', None)
    os.environ.pop('FM_TEST_SEAM', None)
    sys.argv = [str(root / 'tests/fm-test-queue-pty.py'), str(root / 'bin/fm-test-queue.sh'), '/bin/bash', str(case)]
    scope = {'__name__': '__main__'}
    print(f'TRIAL {n}: wait for workload heartbeat after fg before Ctrl-C', flush=True)
    try:
        exec(compile(prefix + '\ntry:\n    receive(prompt)\n' + body + suffix, sys.argv[0], 'exec'), scope)
    finally:
        (evidence / f'promoted-synchronized-{n}.txt').write_text(bytes(scope.get('output', b'')).decode(errors='replace'))
