#!/usr/bin/env bash
# Live driver: real bin/fm-watchdog.sh once against a disposable home whose
# session's last request used <tokens> of a 100000 compact point.
# usage: drive-watchdog-91500.sh <repo-root> <tokens> <pane-footer-pct>
set -u
ROOT=$1 TOKENS=$2 FOOT=$3
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-ctx-live); BASE=$(date +%s); CASE_N=0; LOCK_PIDS=''
trap 'for p in $LOCK_PIDS; do kill $p 2>/dev/null; done; fm_test_cleanup' EXIT
eval "$(sed -n '/^usage_transcript()/,/^}/p;/^new_home()/,/^}/p;/^wd_home()/,/^}/p;/^run_wd()/,/^}/p;/^handoff_rows()/,/^}/p' /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M6Y74ZZQGKFDF0AABM6FAY63/tests/fm-context-reading.test.sh)"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\ncase "$1" in capture-pane) cat "$FM_CTX_TEST_PANE";; list-panes) printf "%%%%1\\n";; *) exit 0;; esac\n' > "$FAKEBIN/tmux"; chmod +x "$FAKEBIN/tmux"
for t in gh gh-axi osascript terminal-notifier say mail sendmail curl claude agy; do printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$t"; chmod +x "$FAKEBIN/$t"; done
wd_home $'Captain session\n> \n  '"$FOOT"'% until auto-compact' "$TOKENS"
printf 'session=%s compact_at=100000 at=%s\n' "$SID" "$BASE" > "$H/state/compact-point"
run_wd
echo "root=$ROOT tokens=$TOKENS"
echo "handoff-request rows:"; handoff_rows | cut -f5- || true
grep -o 'ctx=[^]]*]' "$H/data/watchdog/status.md" "$H"/state/watchdog/*.log 2>/dev/null | head -3
