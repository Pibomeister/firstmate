Round 2 live validation at c70e72d7, run as a lab primary: Claude Code 2.1.316 (sonnet) on the private tmux socket fm-lab, 200x50,
FM_HOME=a disposable lab home, FM_ROOT=a disposable plain clone of c70e72d7 (a linked worktree is exempt from fm_primary_scope_matches),
CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 set only in that tmux session, and the operator's OMC HUD statusLine active.

r2-live-primary-context-burn.tsv. Rows written by the real Stop hook (fm-turnend-guard.sh -> fm-context-burn.sh record --turn-type auto):
  session 49e37fc7: startup 57, captain 57, wake 57 (check:), heartbeat 57 (heartbeat:), captain 22 (3x600-line reads),
                    captain 22, captain 9 (700-line read; the pane footer then showed "9% until auto-compact")
  paneprobe_fixed 9: manual pane-only record (no payload) -> the footer was read above the input box, under the statusLine.
  session 920451cc startup 57: after /clear. The model replied "88% until auto-compact" and the hook recorded 57, not 88.
r2-live-primary-wake-queue.txt: exactly one check wake, "dropped from 57 to 22 in 46s turn captain". The next turn at 22 did not repeat it.
r2-pane-quoted-footer-no-footer.txt: raw pane after the quoted-footer reply with no real footer; a pane-only probe wrote no row.
r2-report-cli.txt: report gives the path and sha256 for a file under data/ and refuses outside paths, a symlink, ".." and bad record args.
r2-supervision-lines.txt: the five new operating-instruction lines as emitted by fm-supervision-instructions.sh for the lab home.
r2-fm-context-burn.test.log: tests/fm-context-burn.test.sh at c70e72d7, exit 0.
