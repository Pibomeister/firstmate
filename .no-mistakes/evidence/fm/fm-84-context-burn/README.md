Live lab primary (Claude Code 2.1.316, sonnet) on private tmux socket fm-lab, FM_HOME=disposable lab home,
FM_ROOT=disposable plain clone of 07cf00ee (a linked worktree is exempted by fm_primary_scope_matches),
CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 set only in that tmux session.

live-primary-context-burn.tsv: rows written by the real Stop hook (fm-turnend-guard.sh -> fm-context-burn.sh record --turn-type auto)
  rows 1-6 from real turns: startup 57, captain 57, wake 57 (check:), heartbeat 57 (heartbeat:), captain 17 (4 large reads), captain 17, captain 0
  later rows (epoch 1793530200/260) are manual --percent CLI probes.
  57 cross-checked: fm_warm_compact_context_tokens=70635, compact point=167000 -> 57.
live-primary-wake-queue.txt: one check wake "dropped from 57 to 17 in 74s turn captain" (second live turn at 17 did not repeat it);
  second line is from the manual 90->10 probe after a non-drop row re-armed the marker.
live-primary-pane.txt: pane showing "0% until auto-compact" footer above the input box, with the OMC HUD statusLine below it.
  fm_backend_capture <pane> 5 | awk NF | tail -n 5 does NOT contain the footer (parsed empty); 6 lines parses 0.
