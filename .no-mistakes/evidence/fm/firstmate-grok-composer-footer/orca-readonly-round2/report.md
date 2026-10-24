# Read-only Orca validation supplement

The outstanding test-1 decision authorized one read-only check of the existing protected terminal. The exact current pipeline source reports an empty composer through the real Orca adapter. The baseline reports unknown on those same captured bytes. No source fix is needed for this finding. No decision is requested here; this report is evidence for the outer test executor.

## Scope and provenance

- Pipeline revision: a761a455249e6dfc3ebcea6fd6a971b00af87c2c.
- Baseline revision: d3e208cc674c1b6486e0ee50827ddd9eb5f53781.
- Terminal: term_da54e1ca-45ea-477d-8f2f-b4a86cfd2f81.
- Source: the assigned pipeline worktree only. The three sourced libraries have unchanged before/after SHA-256 manifests.
- `probe.sh` records the actual `fm_backend_orca_composer_state` call. `adapter.stderr.txt` is the complete Bash 3.2 execution trace, including the raw Orca command, JSON response, contiguous capture, capabilities, and classifier output. Bash 3.2 does not support BASH_XTRACEFD, so `adapter.xtrace.txt` is empty; the trace resides in the retained stderr file.
- `adapter.response.json` is the first JSON response extracted byte-for-byte from that trace. `adapter.capture.txt` is its complete joined tail. `stream.json` preserves an independent subsequent read using the adapter's exact capture primitive. `viewport.json` preserves the explicit `--screen` read. Both responses identify the requested terminal and report `source: screen`.
- Each direct command has its command or script, exit-status file, stderr, and output. The final artifact manifest hashes all evidence.

## Reproduction and result

The actual live terminal now renders four contiguous rows: a complete Grok box with an empty glyph-bearing input row, its titled bottom border, then `Shift+Tab:mode  │  Ctrl+x:shortcuts` immediately below it. There is no blank separator. Both full captures and separately derived four-row excerpts are retained.

The actual adapter returned `empty`, exit 0. The `compare.sh` counterfactual uses the same live capture bytes with the baseline and candidate shared classifiers: baseline `unknown`, candidate `empty`. It produces that result independently for both the adapter capture and the explicit viewport. This reproduces the missing contiguous-footer boundary on the authorized real Orca path.

The initiating trigger is a hint row directly adjacent to a completed composer box. The baseline's cursorless selector rejects that row as unexplained lower activity. A blank separator masks the defect; that was the limit of the prior disposable tmux proof. The candidate recognizes one hint row at this boundary, allowing an affirmative empty verdict. This is composer safety evidence only: it does not prove a handoff was performed or that any background runner survives exit.

The live terminal no longer displays `Enter:send now` or `Ctrl+;:queue`. Exact-token cases remain saved-capture checks, including each token independently. They are not newly claimed native emissions. The controlled saved ordinary draft and footer-like draft both remain `pending`. An incomplete bottom border and unexplained lower activity remain `unknown`. No text was typed into the protected terminal, so this report does not claim typed-native draft proof. An empty composer permits further guarded evaluation; it does not establish any other lifecycle or permission guard.

## Preserved evidence and limits

All five previously passed live scenarios remain supported by the unchanged parent-directory artifacts: queued-empty, draft refusal, trust refusal, clipped-viewport refusal, and dead-shell refusal. `prior-evidence.sha256.json` records those files without rewriting them. The previous inconclusive Orca result remains in the preceding round's report; this supplement supplies the previously missing read-only path evidence.

The first evidence-extraction attempt failed because the full Bash trace contains byte-sliced intermediate strings that are not valid UTF-8. The initial comparison then failed because its derived capture did not exist. `extraction-attempt1.txt` and `compare.attempt1.*` retain these failures. Decoding only the original JSON response corrected the evidence extraction; the subsequent comparison passed. These were evidence-processing failures, not suppressed product failures.

No prompt, key, interrupt, model request, setting/authentication change, service action, or protected-worker lifecycle action was performed. No intentional writes occurred outside the assigned worktree and authorized evidence directory. No source, test, memory-file, or documentation changes were made. The transient baseline file was removed by its exit trap. Linters, formatters, static analysis, and the full suite were not run.

## Focused verification completed

`bash bin/fm-test-run.sh tests/fm-composer-lib.test.sh tests/fm-composer-ghost.test.sh` exited 0: two scripts, zero failures, zero gate skips. `targeted-tests.log` retains every assertion and runner receipt. The baseline comparison exited 0 with the expected unknown-to-empty transitions and controlled draft/refusal results. Final Git status is clean. Prior evidence digests are unchanged.
