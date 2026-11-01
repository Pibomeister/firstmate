echo 'SCENARIO: unsupported Orca backend refuses without task or checkout'
brief agy-orca never
if spawn agy-orca orca; then exit 1; fi
test ! -e "$FM_HOME/state/agy-orca.meta"
test ! -d "$TREEHOUSE_ROOT"
echo 'PASS: refusal before allocation'
true # private session already running
tmux send-keys -t firstmate 'printf "LAB_SHELL_HOME=%s\n" "$HOME"' Enter
echo 'SCENARIO: real tmux AGY receives brief'
brief agy-tmux "fresh-$$"
spawn agy-tmux tmux
export TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-tmux.meta")
wait_report agy-tmux "fresh-$$" "$WT"
tmux capture-pane -p -t fm-agy-tmux > "$EVIDENCE/r3-tmux-pane.txt" || true
echo 'SCENARIO: Treehouse 2.0.1 refuses before fresh endpoint creation and before stopping an existing AGY worker'
brief agy-old-treehouse no-launch
BEFORE=$(tmux list-windows -a -F '#{window_id}')
if PATH="$ROOT/.phase-test/treehouse-2:$PATH" spawn agy-old-treehouse tmux; then exit 1; fi
test ! -e "$FM_HOME/state/agy-old-treehouse.meta"
test "$(tmux list-windows -a -F '#{window_id}')" = "$BEFORE"
PID_BEFORE=$(tmux list-panes -t firstmate:fm-agy-tmux -F '#{pane_pid}')
if PATH="$ROOT/.phase-test/treehouse-2:$PATH" "$ROOT/bin/fm-control.sh" agy-tmux relaunch --note 'Capability guard must preserve this running worker'; then exit 1; fi
test "$(tmux list-panes -t firstmate:fm-agy-tmux -F '#{pane_pid}')" = "$PID_BEFORE"
kill -0 "$PID_BEFORE"
echo "PASS: old Treehouse preflight kept existing pane process $PID_BEFORE and created no endpoint"
echo 'SCENARIO: ownership mismatch refuses before stopping the existing AGY worker'
CLAIM="$(dirname "$WT")/.fm-slot-owner"
cp "$CLAIM" "$BASE/claim-backup"
printf 'task=another-task\nhome=%s\n' "$FM_HOME" > "$CLAIM"
if "$ROOT/bin/fm-control.sh" agy-tmux relaunch --note 'Must refuse reassigned slot'; then exit 1; fi
test "$(tmux list-panes -t firstmate:fm-agy-tmux -F '#{pane_pid}')" = "$PID_BEFORE"
kill -0 "$PID_BEFORE"
cp "$BASE/claim-backup" "$CLAIM"
echo 'PASS: slot ownership refusal preserved existing process'
retire agy-tmux
echo 'SCENARIO: failed readiness keeps record and lease, prevents steal, then relaunch executes fresh note'
brief agy-recover initial
if FM_AGY_READY_POLLS=1 FM_AGY_POLL_INTERVAL=0 spawn agy-recover tmux; then echo 'FAIL: expected readiness timeout'; exit 1; fi
test -f "$FM_HOME/state/agy-recover.meta"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-recover.meta")
cat "$FM_HOME/state/agy-recover.status"
cat "$(dirname "$WT")/.fm-slot-owner"
(cd "$PROJECT" && treehouse status --json)
SECOND=$(cd "$PROJECT" && treehouse get --lease --lease-holder adversary --no-fetch)
test "$SECOND" != "$WT"
echo "Second allocation=$SECOND; preserved worktree=$WT"
(cd "$PROJECT" && treehouse return "$SECOND" --if-lease-holder adversary --force)
TOKEN="relaunch-$$-$RANDOM"
"$ROOT/bin/fm-control.sh" agy-recover relaunch --note "Overwrite the report at $FM_HOME/data/agy-recover/report.md with exactly: BRIEF_RECEIVED $TOKEN 80235 <your actual current working directory>. Then stop and wait."
test "$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-recover.meta")" = "$WT"
wait_report agy-recover "$TOKEN" "$WT"
retire agy-recover
echo 'PASS: real tmux launch and same-checkout recovery'
SECOND=$(cd "$PROJECT" && treehouse get --lease --lease-holder after-teardown --no-fetch)
test "$SECOND" = "$WT"
echo "Teardown released preserved slot: $SECOND"
(cd "$PROJECT" && treehouse return "$SECOND" --if-lease-holder after-teardown --force)

