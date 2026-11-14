#!/usr/bin/env bash
# Synthetic worker integration: real private terminals, watcher, inbox and
# relaunch; no vendor model, shared watcher, daemon or Herdr session is used.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_PRIORITY_WORKER_LIVE_E2E tmux python3 tasks-axi
# The stand-in uses Linux prctl to expose its kernel process identity.
[ "$(uname -s)" = Linux ] || { echo "skip: synthetic Codex process identity requires Linux"; exit 0; }
REAL_TMUX=$(command -v tmux)
TMP_ROOT=$(fm_test_tmproot fm-priority-worker)
mkdir -p "$TMP_ROOT"
SOCKET="$ROOT/.priority-$$.sock"
ID="priority-proof-$$"
cleanup() {
  local rc=$?
  trap - EXIT
  "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
unset TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/user-home"
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/worker" worker
fm_test_spawn_home "$TMP_ROOT/home" codex
fm_test_spawn_brief "$TMP_ROOT/home" "$ID" 'Read README.md and report its value.'
printf 'project 1\n' > "$TMP_ROOT/home/config/project-capacity"
fm_test_tasks_toml "$TMP_ROOT/home/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$TMP_ROOT/home/data/backlog.md"
tasks-axi add "$ID" 'Synthetic dedicated order' --kind ship --priority 0 --file "$TMP_ROOT/home/data/backlog.md" >/dev/null
cat > "$TMP_ROOT/fakebin/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = -S ]; then
  [ "\${2:-}" = '$SOCKET' ] || exit 97
  shift 2
fi
exec '$REAL_TMUX' -S '$SOCKET' "\$@"
SHIM
cat > "$TMP_ROOT/fakebin/treehouse" <<SHIM
#!/usr/bin/env bash
[ "\${1:-}" = get ] || exit 97
if [ "\${2:-}" = --lease ]; then
  printf '%s\n' '$TMP_ROOT/worker'
else
  cd '$TMP_ROOT/worker'
  exec bash --noprofile --norc
fi
SHIM
# A deterministic terminal worker; its composer is a fixture, not evidence of
# any vendor's UI. The exercised contract is lifecycle and durable state.
cat > "$TMP_ROOT/fakebin/codex" <<'PY'
#!/usr/bin/env python3
import ctypes, os, pathlib, subprocess, sys, termios
ctypes.CDLL(None).prctl(15, b"codex", 0, 0, 0)
root = pathlib.Path(os.environ["PROOF_ROOT"])
state = root / "home/state"
task = os.environ["FM_TASK_ID"]
status = state / (task + ".status")
def append(text):
    with status.open("a") as out: out.write(text + "\n")
with (root / "starts").open("a") as out: out.write(str(os.getpid()) + "\n")
if not (root / "question").exists():
    (root / "question").touch()
    append("needs-decision [key=local-answer]: where can I find the fixture answer?")
else:
    # Replacements must consume the real generated relaunch instructions.
    launch = " ".join(sys.argv[1:])
    if "Continue the dedicated order" not in launch:
        sys.exit("replacement did not receive its progress note")
    (root / "replacement").write_text(str(os.getpid()))
    append("working: replacement resumed the dedicated order")
attrs = termios.tcgetattr(sys.stdin)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(sys.stdin, termios.TCSANOW, attrs)
def prompt():
    print("\033[2J\033[H╭────╮\n│    │\n╰────╯\033[2;3H", flush=True)
prompt()
for line in sys.stdin:
    if line.strip() == "/quit": break
    inbox = pathlib.Path(os.environ["FM_TASK_INBOX"])
    for record in sorted(inbox.glob("*.msg")):
        body = subprocess.check_output(["bash", "-c", '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_body "$2"', "_", os.environ["PROOF_CODE"], str(record)], text=True)
        if "Inspect README.md yourself" in body:
            answer = pathlib.Path("README.md").read_text().strip()
            (root / "result").write_text(answer)
            append("resolved [key=local-answer]: read README.md myself: " + answer)
            append("working: dedicated order completed; ready for continuation")
        (inbox / "handled").mkdir(exist_ok=True)
        record.rename(inbox / "handled" / record.name)
    prompt()
PY
chmod +x "$TMP_ROOT/fakebin/"*
export PATH="$TMP_ROOT/fakebin:$PATH" PROOF_ROOT="$TMP_ROOT" PROOF_CODE="$ROOT"
export FM_HOME="$TMP_ROOT/home" HOME="$TMP_ROOT/user-home" FM_SPAWN_NO_GUARD=1
# The private server inherits the synthetic binary path for replacement shells.
"$REAL_TMUX" -S "$SOCKET" -f /dev/null new-session -d -s proof -n fm-ordinary -x 120 -y 40 \
  "while :; do echo progress >> '$TMP_ROOT/progress'; sleep 1; done"
printf 'window=proof:fm-ordinary\nbackend=tmux\nkind=ship\nharness=codex\nproject=%s\nworktree=%s\n' \
  "$TMP_ROOT/project" "$TMP_ROOT/project" > "$FM_HOME/state/ordinary.meta"
export TMUX="$SOCKET,$("$REAL_TMUX" -S "$SOCKET" display-message -p '#{pid}'),0"
wait_file() {
  local i
  for ((i=0; i<300; i++)); do [ ! -s "$1" ] || return 0; sleep 0.1; done
  fail "timed out waiting for $1"
}
watch_cycle() {
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_WATCH_ONCE=1 FM_POLL=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_WORKTREE_CLEANUP=0 bash "$ROOT/bin/fm-watch.sh"
}
ack_cycle() {
  bash "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain.out" 2> "$TMP_ROOT/drain.err"
  local sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$TMP_ROOT/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$TMP_ROOT/drain.err")
  bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation"
}
bash "$ROOT/bin/fm-spawn.sh" "$ID" "$TMP_ROOT/project" "$TMP_ROOT/fakebin/codex --fixture" \
  --mode no-mistakes --yolo off --priority 0 > "$TMP_ROOT/spawn.log" 2>&1 || { cat "$TMP_ROOT/spawn.log"; fail 'priority spawn failed'; }
wait_file "$TMP_ROOT/starts"
watch_cycle > "$TMP_ROOT/watch.out"
assert_contains "$(cat "$TMP_ROOT/watch.out")" "$ID.status" 'watcher lost the dedicated worker signal'
ack_cycle
assert_contains "$(cat "$TMP_ROOT/drain.out")" 'where can I find the fixture answer?' 'wake drain lost the worker question'
before=$(wc -l < "$TMP_ROOT/progress")
bash "$ROOT/bin/fm-send.sh" "$ID" 'Inspect README.md yourself and complete the dedicated order.'
wait_file "$TMP_ROOT/result"
assert_equals "$(cat "$TMP_ROOT/project/README.md")" "$(cat "$TMP_ROOT/result")" 'worker did not execute its order'
# A second cycle must observe the resolution rather than leave the worker parked.
watch_cycle > "$TMP_ROOT/watch-resolved.out"
. "$ROOT/bin/fm-classify-lib.sh"
assert_equals '' "$(status_open_decisions "$FM_HOME/state/$ID.status")" 'self-servable decision stayed open'
[ "$(wc -l < "$TMP_ROOT/progress")" -gt "$before" ] || fail 'ordinary lane stopped'
pass 'dedicated worker processes its order and resolves a self-servable question under continued supervision'
old_pid=$(head -1 "$TMP_ROOT/starts")
cp "$FM_HOME/state/$ID.meta" "$TMP_ROOT/before.meta"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue the dedicated order from its completed local answer.' \
  > "$TMP_ROOT/relaunch.log" 2>&1 || { cat "$TMP_ROOT/relaunch.log"; fail 'priority relaunch failed'; }
wait_file "$TMP_ROOT/replacement"
new_pid=$(cat "$TMP_ROOT/replacement")
[ "$new_pid" != "$old_pid" ] || fail 'worker process was not replaced'
! kill -0 "$old_pid" 2>/dev/null || fail 'old worker survived relaunch'
for field in priority worktree project window endpoint_task_id; do
  assert_equals "$(sed -n "s/^$field=//p" "$TMP_ROOT/before.meta")" \
    "$(sed -n "s/^$field=//p" "$FM_HOME/state/$ID.meta")" "relaunch changed $field"
done
assert_grep 'priority=0' "$FM_HOME/state/$ID.meta" 'P0 priority was lost'
row=$(tasks-axi show "$ID" --file "$FM_HOME/data/backlog.md")
assert_contains "$row" 'state: in_flight' 'relaunch lost In-flight ownership'
assert_contains "$row" 'priority: 0' 'backlog lost P0 priority'
assert_grep 'phase=complete' "$FM_HOME/state/$ID.control-relaunch" 'relaunch transaction did not complete'
pass 'prioritized worker is replaced with priority, endpoint, worktree and In-flight ownership intact'
