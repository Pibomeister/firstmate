import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path('{run-worktree}')
LAB = ROOT / '.test-phase-lab'
EVIDENCE = Path('~/.no-mistakes/evidence/01M8038T7GV59P4S4C4H7SYECH')
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'REX_')) or key in ('TMUX', 'TMUX_PANE', 'ORCA_TERMINAL_HANDLE'):
        env.pop(key, None)
env['FM_HOME'] = str(LAB)
env['TMUX'] = (LAB / 'socket').read_text().strip() + ',0,0'


def run(args, label, expected=0):
    p = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    (EVIDENCE / (label + '.txt')).write_text('$ ' + ' '.join(args) + '\n' + p.stdout + p.stderr + '\nexit=' + str(p.returncode) + '\n')
    print(label, 'exit', p.returncode, flush=True)
    assert p.returncode == expected, (p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr


(LAB / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
(LAB / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(LAB / 'state/other.status').write_text('working: independent task continues\n')
(LAB / 'state/auth.status').write_text('blocked [key=human-step-auth]: human-only step: sign in to the test service\nworking: independent documentation continues\n')
(LAB / 'state/.last-watcher-beat').touch()
result = run(['bash', 'bin/fm-watchdog.sh', 'council', '--task', 'auth', '--key', 'human-step-auth'], 'human-step-key-council-held')
assert 'council=held' in result
run(['bash', 'bin/fm-afk-contract.sh', 'enter', '--words', 'Continue independent local work while authentication waits.'], 'return-enter-away')
(LAB / 'state/.afk').write_text(str(int(time.time())) + '\n')
result = run(['bash', 'bin/fm-afk-return.sh', 'begin'], 'return-human-only-does-not-hold')
assert 'human-step-auth' in result and 'human-only step, other work continues' in result
assert 'human-only steps recorded by the watchdog' in result
assert 'worker:auth: verification-code step waiting since' in result
assert not (LAB / 'state/.afk-return-catchup').exists()
record = (LAB / 'state/watchdog/human-steps.tsv').read_text()
assert any('\tworker:auth\tverification-code\t' in r and r.endswith('\tbriefed') for r in record.splitlines())
(EVIDENCE / 'return-persisted-human-steps.txt').write_text(record)
print('PASS real return command publishes the handoff, marks it briefed, and allows independent work', flush=True)

(LAB / 'state/other.status').write_text('blocked [key=ordinary-dependency]: firstmate must repair the local dependency\n')
result = run(['bash', 'bin/fm-afk-return.sh', 'check'], 'return-ordinary-blocker-holds', 3)
assert 'firstmate-actionable blocker: other [key=ordinary-dependency]' in result
assert (LAB / 'state/.afk-return-catchup').exists()
with (LAB / 'state/other.status').open('a') as f:
    f.write('resolved [key=ordinary-dependency]: dependency repaired\n')
with (LAB / 'state/auth.status').open('a') as f:
    f.write('resolved [key=human-step-auth]: the person completed the local step\n')
result = run(['bash', 'bin/fm-afk-return.sh', 'check'], 'return-resolved-blocker-clears')
assert not (LAB / 'state/.afk-return-catchup').exists()
waiting = result.split('Waiting on you:\n', 1)[1].split('Tried and failed, or could not be fixed:', 1)[0]
assert 'human-step-auth' not in waiting
print('PASS ordinary blockers still hold the return gate until resolved', flush=True)
