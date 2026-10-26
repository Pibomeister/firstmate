import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd()
evidence = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5TWX28QV7MK1HBVJB807Z3Q/test-phase-fresh')
selections = {
    'fm-spawn-orca-worktree': [
        'test_orca_relaunch_rebinds_a_closed_terminal_in_the_recorded_worktree',
        'test_orca_relaunch_adopts_a_dead_connected_terminal',
        'test_orca_relaunch_refuses_without_proof_of_a_stopped_agent',
    ],
    'fm-control': [
        'test_closed_orca_terminal_exit_reports_endpoint_gone',
        'test_closed_orca_terminal_exit_refuses_without_the_worktree_scan',
    ],
    'fm-backend-orca': [
        'test_orca_agent_state_reads_the_session_tree',
        'test_orca_agent_state_unprovable_reads_are_unreadable',
        'test_orca_absence_proof_refuses_without_every_fact',
        'test_composer_state_grok_middle_dot_title',
        'test_composer_state_grok_flush_hint_row',
    ],
    'fm-composer-lib': [
        'test_matrix_codex_0162_placeholder_on_plain_capture',
        'test_codex_footer_requires_complete_rows',
        'test_codex_footer_run_preserves_following_draft',
        'test_codex_footer_order_and_multiplicity',
        'test_matrix_grok_middle_dot_title',
        'test_matrix_grok_hint_row_flush_under_box',
        'test_grok_weekly_limit_choice_is_named_only_in_its_recorded_structure',
    ],
}
results = []
for suite, functions in selections.items():
    original = root / 'tests' / (suite + '.test.sh')
    runner = root / 'tests' / ('.phase-' + suite + '.sh')
    # Preserve every definition and helper. Select existing behavioral test
    # entrypoints rather than running unrelated cases. No assertion inspects source.
    lines = original.read_text().splitlines(keepends=True)
    content = ''.join(line for line in lines
                      if not re.fullmatch(r'test_[A-Za-z0-9_]+\s*\n?', line)
                      and not line.startswith('echo "# all '))
    runner.write_text(content + '\n' + '\n'.join(functions) + '\n')
    env = dict(os.environ, TMPDIR=str(root / '.test-validation/tmp'))
    try:
        result = subprocess.run(['bash', str(runner)], cwd=root, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=150)
        log = result.stdout
        (evidence / (suite + '-focused.log')).write_text(log)
        record = dict(suite=str(original.relative_to(root)), entrypoints=functions,
                      command='TMPDIR="$PWD/.test-validation/tmp" bash ' + str(runner.relative_to(root)),
                      exit_code=result.returncode,
                      output_sha256=hashlib.sha256(log.encode()).hexdigest())
        results.append(record)
        print(json.dumps(record), flush=True)
        print(log[-4000:], flush=True)
    finally:
        runner.unlink(missing_ok=True)
(evidence / 'focused-tests.json').write_text(json.dumps(results, indent=2) + '\n')
