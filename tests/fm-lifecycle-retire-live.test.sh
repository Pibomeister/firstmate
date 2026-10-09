#!/usr/bin/env bash
# Live session-absent retirement against one generated Herdr lab.
# The lab helper owns provision and teardown. The library inventory command
# is the real inspector; a PATH shim only records its argv and execs herdr.
# This file must not embed a machine-specific home or call Herdr directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_LIFECYCLE_RETIRE_LIVE herdr jq

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
HERDR_ORIGINAL_HOME=$HOME
REAL_HERDR=$(command -v herdr)
TMP_ROOT=$(fm_test_tmproot fm-lifecycle-retire-live)
USER_HOME=$TMP_ROOT/user-home
FAKEBIN=$TMP_ROOT/fakebin
ARGV_LOG=$TMP_ROOT/herdr-argv.log
mkdir -p "$USER_HOME" "$FAKEBIN"
export REAL_HERDR ARGV_LOG HERDR_ORIGINAL_HOME
: > "$ARGV_LOG"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-lifecycle-resume)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
cleaned=0

save_argv() {
  [ -n "${FM_LIFECYCLE_RETIRE_LIVE_EVIDENCE:-}" ] || return 0
  [ -f "$ARGV_LOG" ] || return 0
  mkdir -p "$FM_LIFECYCLE_RETIRE_LIVE_EVIDENCE"
  cp -- "$ARGV_LOG" "$FM_LIFECYCLE_RETIRE_LIVE_EVIDENCE/herdr-argv.log" || true
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP QUIT
  save_argv
  if [ "$cleaned" != 1 ]; then
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
    cleaned=1
  fi
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'cleanup' INT
trap 'cleanup' TERM
trap 'cleanup' HUP
trap 'cleanup' QUIT

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${ARGV_LOG:?}"
# Herdr 0.7.4 reads its server from HOME/.config/herdr. The lifecycle command
# keeps a private HOME; this process restores the operator HOME so the
# inventory is the same server the lab helper provisioned against.
exec env HOME="${HERDR_ORIGINAL_HOME:?}" "${REAL_HERDR:?}" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab_list() {
  env -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_ENV \
    PATH="$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" session list --json
}

default_object() {
  local raw rc=0
  raw=$(lab_list) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'helper session list exited %s\n' "$rc" >&2
    return "$rc"
  fi
  if [ -z "$raw" ]; then
    printf 'helper session list returned an empty body\n' >&2
    return 1
  fi
  printf '%s' "$raw" | jq -c '
    [.sessions[]? | select(.name == "default" and .default == true)]
    | if length == 1 and .[0].running == true
      then .[0] | {name, default, running, socket_path, session_dir}
      else error("default session is not one running default")
      end
  ' || {
    printf 'helper session list body: %s\n' "$raw" >&2
    return 1
  }
}

session_count() {
  local raw rc=0
  raw=$(lab_list) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$raw" | jq -r --arg name "$HERDR_LAB_SESSION" \
    '[.sessions[]? | select(.name == $name)] | length'
}

argv_lines() {
  wc -l < "$ARGV_LOG" | tr -d ' '
}

assert_argv_shape() {
  local line
  [ -s "$ARGV_LOG" ] || fail "the inventory command did not call herdr"
  while IFS= read -r line; do
    [ "$line" = "session list --json --session $HERDR_LAB_SESSION" ] \
      || fail "unexpected herdr argv: $line"
  done < "$ARGV_LOG"
  if grep -E 'server|pane|workspace|eventwait|workspace-move' "$ARGV_LOG" >/dev/null; then
    fail "inventory argv included a forbidden Herdr operation: $(cat "$ARGV_LOG")"
  fi
}

ver=$(env PATH="$HERDR_ORIGINAL_PATH" herdr --version 2>&1) || ver='unknown'
printf 'herdr-version %s\n' "$ver"
printf 'lab-session %s\n' "$HERDR_LAB_SESSION"

pre_rc=0
pre=$(default_object) || pre_rc=$?
if [ "$pre_rc" -eq 0 ]; then
  [ "$(session_count)" = 0 ] || fail "session list before provision created $HERDR_LAB_SESSION"
else
  printf 'note: pre-provision helper session list exited %s\n' "$pre_rc"
  pre=
fi

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "lab provision failed for $HERDR_LAB_SESSION"
[ "$(session_count)" = 1 ] || fail "provisioned lab session is not present once"
running=$(lab_list | jq -r --arg name "$HERDR_LAB_SESSION" \
  '.sessions[]? | select(.name == $name) | .running')
[ "$running" = true ] || fail "provisioned lab session is not running"
mid=$(default_object) || fail "could not read the default session after provision"
if [ -n "$pre" ]; then
  [ "$mid" = "$pre" ] || fail "default session changed during provision: before=$pre after=$mid"
fi

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "lab teardown failed for $HERDR_LAB_SESSION"
cleaned=1
[ "$(session_count)" = 0 ] || fail "lab session remains after helper teardown"
after=$(default_object) || fail "could not read the default session after teardown"
[ "$after" = "$mid" ] || fail "default session changed across teardown: before=$mid after=$after"
pass "helper deleted $HERDR_LAB_SESSION and the default session stayed $after"

: > "$ARGV_LOG"

BOOT=$(bash -c '. "$1"; fm_lifecycle_retire_boot_id' _ "$ROOT/bin/fm-lifecycle-retire-lib.sh") \
  || fail "could not read the boot id"
dead_pid() {
  local pid=4194301 i=0
  while [ "$i" -lt 80 ]; do
    if ! kill -0 "$pid" 2>/dev/null && ! ps -p "$pid" >/dev/null 2>&1; then
      printf '%s\n' "$pid"
      return 0
    fi
    pid=$((pid + 1))
    i=$((i + 1))
  done
  return 1
}
DEAD_PID=$(dead_pid) || fail "could not find an unused pid"
DEAD_PID_2=$(dead_pid) || fail "could not find a second unused pid"
[ "$DEAD_PID" != "$DEAD_PID_2" ] || DEAD_PID_2=$((DEAD_PID + 1))
GEN=s1.2.3
GONE_IDENT='lstart=gone-for-live'

abs_dir() {
  mkdir -p "$1"
  (cd -P -- "$1" && pwd -P)
}

parent=$(abs_dir "$TMP_ROOT/parent")
inst=$(abs_dir "$TMP_ROOT/installed")
mkdir -p "$parent/state" "$parent/data" "$parent/config" "$parent/projects"
printf 'manual\n' > "$parent/config/backlog-backend"
printf '%s\n' mate1 > "$inst/.fm-secondmate-home"
printf '%s\n' 'schema=fm-secondmate-parent.v1' 'route=local' "parent_home=$parent" \
  > "$inst/.fm-secondmate-parent"
mkdir -p "$inst/config/agent-kit" "$inst/state" "$inst/data" "$inst/projects"
printf 'panes-sentinel\n' > "$inst/config/agent-kit/herdr-panes"
git -C "$inst" init -q
git -C "$inst" add config/agent-kit/herdr-panes
git -C "$inst" -c user.email=t@example.com -c user.name=tester commit -q -m sentinel
head_before=$(git -C "$inst" rev-parse HEAD)
printf '%s\n' "- mate1 - Lab mate (home: $inst; scope: local work; projects: alpha; added 2026-01-01)" \
  > "$parent/data/secondmates.md"
cat > "$parent/state/mate1.meta" <<EOF
kind=secondmate
spawn_gen=$GEN
backend=herdr
session=$HERDR_LAB_SESSION
window=$HERDR_LAB_SESSION:p1
home=$inst
harness=claude
EOF
jq -n \
  --arg home "$parent" --arg session "$HERDR_LAB_SESSION" --arg gen "$GEN" \
  --arg ident "$GONE_IDENT" --arg boot "$BOOT" \
  --argjson pid "$DEAD_PID" --argjson spid "$DEAD_PID_2" \
  '{schema_version:1, operation_id:"op-live", parent_home:$home,
    absence_mode:"session-absent",
    consumer:{installation_id:"lab", group_id:"g", generation:"1", request_digest:"recorded"},
    endpoints:[{home:$home, task_id:"mate1", kind:"secondmate", spawn_gen:$gen,
      backend:"herdr", session:$session, window:($session + ":p1"), pane_id:"pane-1",
      workspace_id:"w", tab_id:"t", parent_task_id:"", retain_home:true,
      process:{pid:$pid, identity:$ident, boot_id:$boot},
      server:{socket_path:"/tmp/fm-lifecycle-retire-live-sock", pid:$spid,
        identity:$ident, boot_id:$boot}}]}' > "$TMP_ROOT/request.json"

life() {
  local errfile=$1
  shift
  LIFE_RC=0
  LIFE_OUT=$(env -u FM_HOME -u STATE -u FM_STATE_OVERRIDE -u FM_ROOT -u FM_ROOT_OVERRIDE \
    -u FM_PROC_ROOT_OVERRIDE -u FM_LIFECYCLE_INVENTORY_COMMAND -u FM_LIFECYCLE_ENDPOINT_COMMAND \
    -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_ENV \
    HOME="$USER_HOME" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    "$ROOT/bin/fm-lifecycle.sh" "$@" 2>"$errfile") || LIFE_RC=$?
}

json_get() { printf '%s\n' "$LIFE_OUT" | jq -r "$1"; }

life "$TMP_ROOT/inspect.err" inspect --request "$TMP_ROOT/request.json" --out "$TMP_ROOT/inspect.json"
assert_equals 0 "$LIFE_RC" "inspect exited 0: $(cat "$TMP_ROOT/inspect.err")"
assert_equals ready "$(json_get .status)" "inspect reports ready"
assert_equals false "$(json_get .authority)" "inspect grants no authority"
assert_absent "$parent/state/lifecycle-retire" "inspect writes no retirement journal"
assert_equals 1 "$(argv_lines)" "inspect reads the session inventory once"
assert_argv_shape
pass "inspect of the deleted lab session read one session list and wrote nothing"

life "$TMP_ROOT/retire.err" retire --request "$TMP_ROOT/request.json" --out "$TMP_ROOT/retire.json"
assert_equals 0 "$LIFE_RC" "retire exited 0: $(cat "$TMP_ROOT/retire.err")"
assert_equals complete "$(json_get .status)" "retire stores complete"
assert_equals 3 "$(argv_lines)" "retire reads the session inventory twice more and does not call herdr again"
assert_argv_shape
assert_absent "$parent/state/mate1.meta" "the retired task record is removed"
assert_present "$parent/state/mate1.endpoint-retired" "the endpoint retirement record stays"
assert_grep 'retain_home=true' "$parent/state/mate1.endpoint-retired" "the retirement record retains the home"
assert_grep "installed_home=$inst" "$parent/state/mate1.endpoint-retired" "the retirement record names the installed home"
assert_grep "session=$HERDR_LAB_SESSION" "$parent/state/mate1.endpoint-retired" "the retirement record names the deleted session"
assert_present "$inst/.fm-secondmate-home" "the installed secondmate home stays"
assert_grep 'mate1' "$inst/.fm-secondmate-home" "the home marker still names mate1"
assert_present "$parent/data/secondmates.md" "the registry binding stays"
assert_grep "$inst" "$parent/data/secondmates.md" "the registry still points at the installed home"
assert_equals "$head_before" "$(git -C "$inst" rev-parse HEAD)" "the installed home git history stays"
assert_grep 'panes-sentinel' "$inst/config/agent-kit/herdr-panes" "the installed home sentinel stays"
[ "$(session_count)" = 0 ] || fail "retire recreated $HERDR_LAB_SESSION"
post=$(default_object) || fail "could not read the default session after retire"
[ "$post" = "$after" ] || fail "default session changed during retire: before=$after after=$post"
pass "retire preserved the installed home after the lab session was already gone"

retired_sum=$(shasum -a 256 "$parent/state/mate1.endpoint-retired" | awk '{print $1}')
life "$TMP_ROOT/result.err" result --home "$parent" --operation-id op-live --out "$TMP_ROOT/result.json"
assert_equals 0 "$LIFE_RC" "result exited 0: $(cat "$TMP_ROOT/result.err")"
assert_equals complete "$(json_get .status)" "result returns the stored complete record"
assert_equals 3 "$(argv_lines)" "result does not call herdr"
life "$TMP_ROOT/replay.err" retire --request "$TMP_ROOT/request.json" --out "$TMP_ROOT/replay.json"
assert_equals 0 "$LIFE_RC" "replay exited 0: $(cat "$TMP_ROOT/replay.err")"
assert_equals already-retired "$(json_get .status)" "replay reports already-retired"
assert_equals 3 "$(argv_lines)" "replay does not read the inventory again"
assert_equals "$retired_sum" "$(shasum -a 256 "$parent/state/mate1.endpoint-retired" | awk '{print $1}')" \
  "replay does not rewrite the retirement record"
assert_present "$inst/.fm-secondmate-home" "replay leaves the installed home"
[ "$(session_count)" = 0 ] || fail "replay recreated $HERDR_LAB_SESSION"
final=$(default_object) || fail "could not read the default session after replay"
[ "$final" = "$after" ] || fail "default session changed during retirement: before=$after after=$final"
pass "result and replay left the inventory argv unchanged"
printf 'ARGV_LOG_BEGIN\n'
cat "$ARGV_LOG"
printf 'ARGV_LOG_END\n'
printf 'default-session %s\n' "$final"
printf 'ok - lifecycle retirement live suite\n'
save_argv
