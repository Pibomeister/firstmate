#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_FAILOVER_RELAUNCH_E2E tmux git

LAB=$(fm_test_tmproot fm-failover-relaunch)
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)
SOCK="fm-failover-relaunch-$$"
ID=fo-real
SES="fo-real-$$"
cleanup() {
  env -u TMUX -u TMUX_PANE tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$LAB/home/state" "$LAB/home/config" "$LAB/home/data/$ID" "$LAB/fakebin" "$LAB/user-home/.claude"
printf 'tmux\n' > "$LAB/home/config/backend"
fm_git_worktree "$LAB/project" "$LAB/worktree" "fm/$ID" >/dev/null 2>&1 || fail 'could not make the task worktree'
printf 'unfinished work\n' > "$LAB/worktree/unfinished.txt"
printf 'gate receipt\n' > "$LAB/worktree/gate-receipt.txt"
cat > "$LAB/home/data/$ID/brief.md" <<'BRIEF'
# Task
## Captain's intent
Continue the task after provider refusal.

## Firstmate spec
Mode: no-mistakes.
Gates remain attached to this task.
BRIEF

cat > "$LAB/fakebin/claude" <<'SH'
#!/usr/bin/env bash
while IFS= read -r line; do
  [ "$line" != /exit ] || exit 0
done
SH
cat > "$LAB/fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'codex 1.0'; exit 0; fi
while IFS= read -r line; do
  [ "$line" != /exit ] || exit 0
done
SH
chmod +x "$LAB/fakebin/claude" "$LAB/fakebin/codex"

cat > "$LAB/home/state/$ID.meta" <<META
window=$SES:fm-$ID
endpoint_task_id=$ID
worktree=$LAB/worktree
project=$LAB/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$LAB/tasktmp
model=default
effort=default
spawn_gen=s1.$ID
branch=fm/$ID
META
printf 'working: unfinished gate work\n' > "$LAB/home/state/$ID.status"

env -u TMUX -u TMUX_PANE tmux -L "$SOCK" new-session -d -s "$SES" -n "fm-$ID" -c "$LAB/worktree" /bin/bash --noprofile --norc \
  || fail 'could not start the isolated tmux session'
SOCKET=$(env -u TMUX -u TMUX_PANE tmux -L "$SOCK" display-message -p -t "$SES:fm-$ID" '#{socket_path}')
SERVER_PID=$(env -u TMUX -u TMUX_PANE tmux -L "$SOCK" display-message -p -t "$SES:fm-$ID" '#{pid}')
env -u TMUX -u TMUX_PANE tmux -L "$SOCK" send-keys -t "$SES:fm-$ID" "$LAB/fakebin/claude" Enter
sleep 1

export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" FM_CONFIG_OVERRIDE="$LAB/home/config"
export FM_DATA_OVERRIDE="$LAB/home/data" HOME="$LAB/user-home" PATH="$LAB/fakebin:$PATH"
export TMUX="$SOCKET,$SERVER_PID,0" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.1
export CLAUDE_CONFIG_DIR=''
export FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=5 FM_FAILOVER_RELAUNCH_TIMEOUT=30
printf 'codex\n' > "$LAB/home/config/failover-order"

out=$(bash "$ROOT/bin/fm-failover.sh" worker "$ID" --reason rate_limit 2>&1); rc=$?
expect_code 0 "$rc" "real relaunch failed: $out"
assert_contains "$out" "switched task=$ID from=claude to=codex" 'the replacement starts on Codex'
assert_equals "$LAB/worktree" "$(sed -n 's/^worktree=//p' "$LAB/home/state/$ID.meta")" 'the same worktree remains registered'
assert_equals "fm/$ID" "$(git -C "$LAB/worktree" branch --show-current)" 'the same branch remains checked out'
assert_equals 'unfinished work' "$(cat "$LAB/worktree/unfinished.txt")" 'uncommitted work remains'
assert_equals 'gate receipt' "$(cat "$LAB/worktree/gate-receipt.txt")" 'gate files remain'
assert_equals no-mistakes "$(sed -n 's/^mode=//p' "$LAB/home/state/$ID.meta")" 'the task retains its delivery gate'
assert_contains "$(cat "$LAB/home/data/$ID/brief.md")" 'Continue the task after provider refusal.' 'the brief remains available'
assert_contains "$(cat "$LAB/home/state/dispatch-log.tsv")" "task=$ID from=claude to=codex reason=rate_limit" 'the real switch is logged'
printf '1..1\n'
pass 'real relaunch keeps the task worktree, branch, brief, work, and gates'
printf 'FM_TEST_COMPLETE\n'
