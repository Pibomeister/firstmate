import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path('{run-worktree}')
LAB = ROOT / '.test-phase-lab'
EVIDENCE = Path('~/.no-mistakes/evidence/01M8038T7GV59P4S4C4H7SYECH')
TM = [str(ROOT / 'bin/fm-lab-home.sh'), 'tmux', str(LAB)]
ENV = os.environ.copy()
for key in list(ENV):
    if key.startswith(('FM_', 'HERDR_', 'REX_')) or key in ('TMUX', 'TMUX_PANE', 'ORCA_TERMINAL_HANDLE'):
        ENV.pop(key, None)
ENV['FM_HOME'] = str(LAB)
ENV['TMUX'] = (LAB / 'socket').read_text().strip() + ',0,0'


def run(args, label=None, expected=0):
    result = subprocess.run(args, cwd=ROOT, env=ENV, text=True, capture_output=True, timeout=240)
    if label:
        (EVIDENCE / (label + '.txt')).write_text('$ ' + ' '.join(args) + '\n' + result.stdout + result.stderr + '\nexit=' + str(result.returncode) + '\n')
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout


def tm(*args):
    return run(TM + list(args))


def wd(label, command='once'):
    run(['bash', 'bin/fm-watchdog.sh', command], label + '-command')
    for name, path in [('status', 'data/watchdog/status.md'), ('actions', 'state/watchdog/actions.tsv'), ('human-steps', 'state/watchdog/human-steps.tsv'), ('pages', 'pages.log')]:
        p = LAB / path
        if p.exists():
            (EVIDENCE / (label + '-' + name + '.txt')).write_text(p.read_text())
    print(label, 'completed', flush=True)


def text(path):
    p = LAB / path
    return p.read_text() if p.exists() else ''


def actions(action=None, phase=None, subject=None):
    rows = [line.split('\t') for line in text('state/watchdog/actions.tsv').splitlines()]
    return [r for r in rows if len(r) >= 8 and r[4] == 'human-step' and (action is None or r[5] == action) and (phase is None or r[6] == phase) and (subject is None or r[3] == subject)]


def write(path, value):
    (LAB / path).parent.mkdir(parents=True, exist_ok=True)
    (LAB / path).write_text(value)


def cfg(extra=''):
    write('config/watchdog', 'mode=act\nmodels=\ncouncil-seats=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=0\nrestart=off\nhuman-step-secs=0\nnudge-secs=0\n' + extra)


def screen(session, value, worker=False, harness='codex'):
    write(session + '.screen', value)
    write(session + '.keys', '')
    command = 'python3 ' + str(LAB / 'terminal-input.py') + ' ' + str(LAB / session)
    exists = subprocess.run(TM + ['has-session', '-t', '=' + session], capture_output=True).returncode == 0
    if exists:
        tm('respawn-pane', '-k', '-t', session, command)
    else:
        tm('new-session', '-d', '-s', session, '-x', '140', '-y', '38', '-c', str(ROOT), command)
    for _ in range(60):
        drawn = tm('capture-pane', '-p', '-t', session)
        if value.splitlines()[0].rstrip() in drawn:
            break
        time.sleep(.2)
    else:
        raise AssertionError('terminal did not draw: ' + session)
    target, pid = tm('list-panes', '-t', session, '-F', '#{pane_id} #{pane_pid}').strip().split()
    if worker:
        write('state/' + session + '.meta', 'kind=ship\nbackend=tmux\nwindow=' + target + '\nharness=' + harness + '\nendpoint_task_id=' + session + '\n')
    else:
        sid = '11111111-1111-4111-8111-111111111111'
        write('state/.lock', pid + '\n')
        write('state/.lock-session', sid + '\n')
        write('state/heartbeat.json', json.dumps({'schema': 'fm-heartbeat.v1', 'generated_epoch': int(time.time()), 'primary': {'terminal': {'backend': 'tmux', 'target': target, 'present': True}, 'session': {'trusted_id': sid}, 'writer': {'anchor_pid': int(pid), 'session_id': sid}}}))
    return drawn


def no_keys(*sessions):
    for session in sessions:
        assert not (LAB / (session + '.keys')).read_bytes(), 'unexpected terminal input: ' + session


# Oracle: docs/watchdog.md requires an untouched login picker, a 600-second
# default wait, quiet-hours handoff, and a once-only page when daytime resumes.
before = tm('capture-pane', '-p', '-t', 'primary')
assert 'Select login method:' in before
assert 'human_step=sign-in' in (EVIDENCE / 'real-claude-scan.log').read_text()
assert 'escalated after 10m' in text('data/watchdog/status.md')
cfg()
wd('real-cli-weekend-handoff')
assert '\tmorning-handoff' in text('state/watchdog/human-steps.tsv')
assert not text('pages.log')
assert 'Select login method:' in tm('capture-pane', '-p', '-t', 'primary')
# The documented unreadable-clock policy is daytime. This exercises it at
# the real wall clock on Saturday without replacing date or the product clock.
write('config/escalation', 'quiet-hours-zone=Lab/Unavailable\n')
wd('real-cli-daytime-fallback-page')
assert len(actions('page', 'done')) == 1
assert 'human-only sign-in step' in text('pages.log')
assert 'Select login method' not in text('pages.log')
assert 'Anthropic Console' not in text('pages.log')
wd('real-cli-page-deduplicated')
assert len(actions('page', 'done')) == 1
assert 'Select login method:' in tm('capture-pane', '-p', '-t', 'primary')
assert not [r for r in text('state/watchdog/actions.tsv').splitlines() if '\tkey\t' in r or '\tnudge\t' in r]
print('PASS real Claude picker: default grace, quiet handoff, local page, redaction, deduplication, no keys', flush=True)

# External boundary input terminal; the real watchdog, tmux backend,
# permission classifier, alert command, ledger and filesystem stay unchanged.
write('terminal-input.py', "import os,sys,tty\np=sys.argv[1]\ntty.setraw(0)\nos.write(1,b'\\x1b[2J\\x1b[H'+open(p+'.screen','rb').read().replace(b'\\n',b'\\r\\n'))\nwith open(p+'.keys','ab',buffering=0) as f:\n while True:\n  b=os.read(0,4096)\n  if not b: break\n  f.write(b)\n")
screen('primary', 'Local supervisor\n❯ \n  ? for shortcuts')
approval = 'Would you like to run the following command?\n\n  $ gh auth login\n\n  › 1. Yes, proceed (y)\n    2. No, and tell Codex what to do differently (esc)\n\n  Press enter to confirm or esc to cancel'
screen('auth', approval, True)
screen('other', 'Independent task output\n❯ \n ? for shortcuts', True)
wd('worker-tool-approval')
assert 'permission-prompt-hardstop' in text('state/auth.status')
assert not actions(subject='worker:auth')
no_keys('auth', 'other')
login = 'Earlier: Do you want to proceed?\n\nSign in to continue:\n\n ❯ 1. Open the browser\n   2. Paste a token\n\n Enter to confirm · Esc to cancel'
screen('auth', login, True)
wd('worker-transition-to-login')
assert any(r.startswith('resolved ') and '[key=permission-prompt-hardstop]' in r for r in text('state/auth.status').splitlines())
assert len(actions('page', 'done', 'worker:auth')) == 1
scan = run(['bash', 'bin/fm-watchdog.sh', 'scan'], 'other-worker-remains-observed')
assert 'worker other endpoint=tmux:' in scan
assert 'human_step=sign-in' in scan
no_keys('primary', 'auth', 'other')
print('PASS worker approval becomes login: stale blocker clears and independent worker remains observed', flush=True)

# Adversarial drafts and synthetic expired-session screens use the product scan
# entrypoint. Expected labels come from the documented contract and recorded
# accepted regressions, independently of detector internals.
cases = [
 ('multiline-draft', 'Working on tests\n────────────────────────────\n❯ check auth\n\n Also update 2FA tests\n────────────────────────────\n  ? for shortcuts', 'none'),
 ('cropped-long-draft', 'Working\n────────────────────────────\n❯ check authentication\n' + '\n'.join(' More draft text' for _ in range(17)) + '\n Update OTP tests\n────────────────────────────\n ? for shortcuts', 'none'),
 ('status-and-conversation', 'Earlier: sign in to GitHub\n────────────────────────────\n❯ \n────────────────────────────\n fm/fm-mfa-enroll · ? for shortcuts', 'none'),
 ('numbered-draft', 'GitHub needs you to sign in to continue\n────────────────────────────\n❯ 1. merge it\n────────────────────────────\n ? for shortcuts', 'none'),
 ('expired-login', 'Login expired · Please run /login\n────────────────────────────\n❯ \n────────────────────────────\n ? for shortcuts', 'sign-in'),
 ('expired-oauth', 'Failed to authenticate: OAuth session expired and could not be refreshed\n────────────────────────────\n❯ \n────────────────────────────\n ? for shortcuts', 'sign-in'),
 ('otp', 'Enter the one-time code from your authenticator app:', 'otp'),
 ('verification-code', 'Paste code here if prompted > ', 'verification-code'),
 ('captcha', 'Verify you are a human: CAPTCHA required', 'captcha'),
 ('approval', 'Check your phone to approve this request', 'approval'),
]
for name, value, expected in cases:
    captured = screen('auth', value, True)
    (EVIDENCE / ('input-' + name + '.txt')).write_text(captured)
    result = run(['bash', 'bin/fm-watchdog.sh', 'scan'], 'scan-' + name)
    row = next(r for r in result.splitlines() if 'worker auth endpoint=' in r)
    assert ('human_step=' + expected) in row, (name, row)
    no_keys('auth')
    print('PASS scan', name, expected, flush=True)

# Real write-permission failures: no substituted writer or failed-command stub.
screen('auth', 'Task resumed\n❯ \n ? for shortcuts', True)
wd('worker-reset-between-episodes')
screen('auth', 'Enter the one-time code from your authenticator app:', True)
write('config/escalation', 'quiet-hours-zone=America/Costa_Rica\n')
wd('worker-weekend-handoff')
record = LAB / 'state/watchdog/human-steps.tsv'
assert 'worker:auth\totp' in record.read_text()
record.chmod(0o444)
screen('auth', 'Task resumed\n❯ \n ? for shortcuts', True)
wd('closure-write-failure')
assert 'morning-handoff record could not be cleared' in text('data/watchdog/status.md')
assert list((LAB / 'state/watchdog/human-step').glob('*worker_auth'))
record.chmod(0o644)
wd('closure-write-recovered')
assert not list((LAB / 'state/watchdog/human-step').glob('*worker_auth'))
assert any('\tworker:auth\totp\t' in r and r.endswith('\tcleared') for r in record.read_text().splitlines())

write('config/escalation', 'quiet-hours-zone=Lab/Unavailable\n')
write('config/wedge-alarm', 'off\n')
screen('auth', 'Paste code here if prompted > ', True)
record.chmod(0o444)
wd('page-and-handoff-write-failure')
assert 'morning-handoff record could not be written' in text('data/watchdog/status.md')
record.chmod(0o644)
wd('page-failed-handoff-recovered')
assert any('\tworker:auth\tverification-code\t' in r and r.endswith('\tmorning-handoff') for r in record.read_text().splitlines())
write('config/wedge-alarm', "command:cat >> '" + str(LAB / 'pages.log') + "'\n")
wd('page-channel-recovered')
assert any(r[7] == 'owner paged' for r in actions('page', 'done', 'worker:auth'))
no_keys('primary', 'auth', 'other')
print('PASS append failure retains closure; undelivered page and failed append recover with real permissions', flush=True)

# Orphan worker cleanup closes its previously persisted handoff.
write('config/escalation', 'quiet-hours-zone=America/Costa_Rica\n')
screen('orphan', 'CAPTCHA: verify you are human', True)
wd('orphan-before-removal')
assert any('\tworker:orphan\tcaptcha\t' in r and r.endswith('\tmorning-handoff') for r in record.read_text().splitlines())
(LAB / 'state/orphan.meta').unlink()
wd('orphan-after-removal')
assert any('\tworker:orphan\tcaptcha\t' in r and r.endswith('\tcleared') for r in record.read_text().splitlines())
no_keys('orphan')
print('PASS removed worker closes its handoff', flush=True)

# Emitted public worker instructions, generated through the real CLI.
for kind, args in [('ship', ['evidence-ship', 'example', '--mode', 'local-only']), ('scout', ['evidence-scout', 'example', '--scout'])]:
    result = run(['bash', 'bin/fm-brief.sh'] + args, 'generated-' + kind + '-brief')
    emitted = (LAB / 'data' / args[0] / 'brief.md').read_text()
    (EVIDENCE / ('generated-' + kind + '-brief.md')).write_text(emitted)
    assert 'human-step-' in emitted and 'sign-in' in emitted
print('PASS generated ship and scout brief interfaces', flush=True)
