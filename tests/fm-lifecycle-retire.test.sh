#!/usr/bin/env bash
# shellcheck disable=SC2016 # Expressions in bash -c belong to the child shell.
# Behavior tests for endpoint retirement (bin/fm-lifecycle.sh).
# Each refusal is a command plus its exit status, and the assertion is the
# protected record or process, not the source text.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lifecycle-retire)
USER_HOME=$TMP_ROOT/user-home
mkdir -p "$USER_HOME"
export HOME=$USER_HOME
PIDS=""
BODY=$TMP_ROOT/inv-body.json
SOCK=/tmp/fm-lifecycle-retire-sock
SESSION=fm-lab-retire1
GEN=s1.2.3
GONE_IDENT='lstart=gone-for-test'
FAKEBIN=$TMP_ROOT/fakebin

track() { PIDS="$PIDS $1"; }

cleanup_all() {
  local pid
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM
trap 'cleanup_all; exit 129' HUP
trap 'cleanup_all; exit 131' QUIT

mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "session list --json")
    printf '%s\n' "$*" >> "${FM_RETIRE_INV_LOG:?}"
    case "${FM_RETIRE_INV_MODE:-body}" in
      sleep)
        printf '%s\n' "$$" > "${FM_RETIRE_SLEEP_MARK:?}"
        sleep 60
        ;;
      counter)
        n=0
        [ -f "${FM_RETIRE_INV_COUNT:?}" ] && n=$(cat "$FM_RETIRE_INV_COUNT")
        n=$((n + 1))
        printf '%s\n' "$n" > "$FM_RETIRE_INV_COUNT"
        if [ "$n" -eq 1 ]; then
          printf '%s\n' '{"sessions":[]}'
        else
          printf '%s\n' '{"sessions":[{"name":"fm-lab-retire1","running":true,"socket_path":"/tmp/fm-lifecycle-retire-sock"}]}'
        fi
        exit 0
        ;;
    esac
    cat "${FM_RETIRE_INV_BODY:?}"
    ;;
  "pane get "*)
    printf '%s\n' "$*" >> "${FM_RETIRE_EP_LOG:?}"
    if [ -n "${FM_RETIRE_EP_BODY:-}" ]; then
      printf '%s\n' "$FM_RETIRE_EP_BODY"
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    fi
    ;;
  "pane process-info --pane")
    printf '%s\n' "$*" >> "${FM_RETIRE_EP_LOG:?}"
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s}}}\n' \
      "$4" "${FM_RETIRE_CAPTURE_SHELL_PID:?}"
    ;;
  *)
    printf 'unexpected herdr argv: %s\n' "$*" >&2
    exit 64
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

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

BOOT=$(bash -c '. "$1"; fm_lifecycle_retire_boot_id' _ "$ROOT/bin/fm-lifecycle-retire-lib.sh") \
  || fail "could not read the boot id"
DEAD_PID=$(dead_pid) || fail "could not find an unused pid"
DEAD_PID_2=$(dead_pid) || fail "could not find a second unused pid"
[ "$DEAD_PID" != "$DEAD_PID_2" ] || DEAD_PID_2=$((DEAD_PID + 1))

file_sum() { shasum -a 256 "$1" | awk '{print $1}'; }

life() {
  local errfile=$1
  shift
  # Leading NAME=value words are the command environment. The rest are arguments.
  local -a prefix=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) prefix+=("$1"); shift ;;
      *) break ;;
    esac
  done
  LIFE_RC=0
  if [ "$#" -eq 0 ]; then
    LIFE_OUT=$(env -u FM_HOME -u STATE -u FM_STATE_OVERRIDE -u FM_ROOT -u FM_ROOT_OVERRIDE \
      -u FM_PROC_ROOT_OVERRIDE -u FM_LIFECYCLE_INVENTORY_COMMAND -u FM_LIFECYCLE_ENDPOINT_COMMAND \
      HOME="$USER_HOME" PATH="$FAKEBIN:$PATH" ${prefix[@]+"${prefix[@]}"} \
      "$ROOT/bin/fm-lifecycle.sh" 2>"$errfile") || LIFE_RC=$?
  else
    LIFE_OUT=$(env -u FM_HOME -u STATE -u FM_STATE_OVERRIDE -u FM_ROOT -u FM_ROOT_OVERRIDE \
      -u FM_PROC_ROOT_OVERRIDE -u FM_LIFECYCLE_INVENTORY_COMMAND -u FM_LIFECYCLE_ENDPOINT_COMMAND \
      HOME="$USER_HOME" PATH="$FAKEBIN:$PATH" ${prefix[@]+"${prefix[@]}"} \
      "$ROOT/bin/fm-lifecycle.sh" "$@" 2>"$errfile") || LIFE_RC=$?
  fi
}

json_get() { printf '%s\n' "$LIFE_OUT" | jq -r "$1"; }

abs_dir() {
  mkdir -p "$1"
  (cd -P -- "$1" && pwd -P)
}

mk_parent() {
  local home
  home=$(abs_dir "$TMP_ROOT/$1")
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' "$home"
}

write_mate() {
  local parent=$1 id=$2 inst=$3
  printf '%s\n' "$id" > "$inst/.fm-secondmate-home"
  printf '%s\n' 'schema=fm-secondmate-parent.v1' 'route=local' "parent_home=$parent" \
    > "$inst/.fm-secondmate-parent"
  mkdir -p "$inst/config/agent-kit" "$inst/state" "$inst/data" "$inst/projects"
  printf 'panes-sentinel\n' > "$inst/config/agent-kit/herdr-panes"
  if [ ! -d "$inst/.git" ]; then
    git -C "$inst" init -q
    git -C "$inst" add config/agent-kit/herdr-panes
    git -C "$inst" -c user.email=t@example.com -c user.name=tester commit -q -m sentinel
  fi
  printf '%s\n' "- $id - Lab mate (home: $inst; scope: local work; projects: alpha; added 2026-01-01)" \
    > "$parent/data/secondmates.md"
  cat > "$parent/state/$id.meta" <<EOF
kind=secondmate
spawn_gen=$GEN
backend=herdr
session=$SESSION
window=$SESSION:p1
home=$inst
harness=claude
herdr_pane_id=pane-1
herdr_workspace_id=w
herdr_tab_id=t
lifecycle_process_pid=$DEAD_PID
lifecycle_process_identity=$GONE_IDENT
lifecycle_process_boot_id=$BOOT
lifecycle_server_socket_path=$SOCK
lifecycle_server_pid=$DEAD_PID
lifecycle_server_identity=$GONE_IDENT
lifecycle_server_boot_id=$BOOT
EOF
}

mk_installed() {
  local parent=$1 id=$2 inst
  inst=$(abs_dir "$TMP_ROOT/$3")
  write_mate "$parent" "$id" "$inst"
  printf '%s\n' "$inst"
}

one_ep() {
  jq -n \
    --arg home "$1" --arg id "$2" --arg kind "$3" --arg gen "$4" \
    --argjson retain "$5" --argjson pid "$6" --arg ident "$7" --arg boot "$8" \
    --argjson spid "$9" --arg sident "${10}" --arg sboot "${11}" --arg sock "${12}" \
    --arg pane "${13}" --arg parent "${14}" --arg session "${15}" \
    '{home:$home, task_id:$id, kind:$kind, spawn_gen:$gen, backend:"herdr",
      session:$session, window:($session + ":p1"), pane_id:$pane,
      workspace_id:"w", tab_id:"t", parent_task_id:$parent, retain_home:$retain,
      process:{pid:$pid, identity:$ident, boot_id:$boot},
      server:{socket_path:$sock, pid:$spid, identity:$sident, boot_id:$sboot}}'
}

ship_ep() {
  one_ep "$1" "$2" ship "${3:-$GEN}" false "$DEAD_PID" "$GONE_IDENT" "$BOOT" \
    "$DEAD_PID" "$GONE_IDENT" "$BOOT" "$SOCK" pane-1 "${4:-}" "$SESSION"
}

mate_ep() {
  one_ep "$1" "$2" secondmate "${3:-$GEN}" true "$DEAD_PID" "$GONE_IDENT" "$BOOT" \
    "$DEAD_PID" "$GONE_IDENT" "$BOOT" "$SOCK" pane-1 "${4:-}" "$SESSION"
}

write_ship_meta() {
  local home=$1 id=$2 gen=${3:-$GEN} mode=${4:-no-mistakes}
  cat > "$home/state/$id.meta" <<EOF
kind=ship
spawn_gen=$gen
backend=herdr
session=$SESSION
window=$SESSION:p1
mode=$mode
harness=claude
herdr_pane_id=pane-1
herdr_workspace_id=w
herdr_tab_id=t
lifecycle_process_pid=$DEAD_PID
lifecycle_process_identity=$GONE_IDENT
lifecycle_process_boot_id=$BOOT
lifecycle_server_socket_path=$SOCK
lifecycle_server_pid=$DEAD_PID
lifecycle_server_identity=$GONE_IDENT
lifecycle_server_boot_id=$BOOT
EOF
}

set_meta_runtime() {
  local meta=$1 pid=$2 ident=$3 boot=$4 spid=$5 sident=$6 sboot=$7 pane=${8:-pane-1}
  awk -F= '
    $1!="herdr_pane_id" && $1!="herdr_workspace_id" && $1!="herdr_tab_id" &&
    $1!="lifecycle_process_pid" && $1!="lifecycle_process_identity" &&
    $1!="lifecycle_process_boot_id" && $1!="lifecycle_server_socket_path" &&
    $1!="lifecycle_server_pid" && $1!="lifecycle_server_identity" &&
    $1!="lifecycle_server_boot_id"
  ' "$meta" > "$meta.runtime"
  {
    cat "$meta.runtime"
    printf 'herdr_pane_id=%s\n' "$pane"
    printf 'herdr_workspace_id=w\n'
    printf 'herdr_tab_id=t\n'
    printf 'lifecycle_process_pid=%s\n' "$pid"
    printf 'lifecycle_process_identity=%s\n' "$ident"
    printf 'lifecycle_process_boot_id=%s\n' "$boot"
    printf 'lifecycle_server_socket_path=%s\n' "$SOCK"
    printf 'lifecycle_server_pid=%s\n' "$spid"
    printf 'lifecycle_server_identity=%s\n' "$sident"
    printf 'lifecycle_server_boot_id=%s\n' "$sboot"
  } > "$meta.runtime.new"
  mv "$meta.runtime.new" "$meta"
  rm -f "$meta.runtime"
}

write_request() {
  jq -n --arg op "$2" --arg parent "$3" --arg mode "$4" --slurpfile eps "$5" \
    '{schema_version:1, operation_id:$op, parent_home:$parent, absence_mode:$mode,
      consumer:{installation_id:"lab", group_id:"g", generation:"1", request_digest:"recorded"},
      endpoints:$eps[0]}' > "$1"
}

absent_body() { printf '%s\n' '{"sessions":[]}'; }
present_body() {
  printf '%s\n' '{"sessions":[{"name":"fm-lab-retire1","running":true,"socket_path":"/tmp/fm-lifecycle-retire-sock"}]}'
}
stopped_body() {
  printf '%s\n' '{"sessions":[{"name":"fm-lab-retire1","running":false,"socket_path":"/tmp/fm-lifecycle-retire-sock"}]}'
}

capture_bin=$(abs_dir "$TMP_ROOT/capture-bin")
ln -s "$FAKEBIN/herdr" "$capture_bin/herdr"
cat > "$capture_bin/lsof" <<'SH'
#!/usr/bin/env bash
[ "$*" = "-nP -t -U ${FM_RETIRE_CAPTURE_SOCKET:?}" ] || exit 1
printf '%s\n' "${FM_RETIRE_CAPTURE_SERVER_PID:?}"
SH
chmod +x "$capture_bin/lsof"
sleep 300 &
capture_shell_pid=$!
track "$capture_shell_pid"
sleep 300 &
capture_server_pid=$!
track "$capture_server_pid"
capture_shell_identity=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; fm_lifecycle_process_identity "$2"' \
  _ "$ROOT" "$capture_shell_pid") || fail "could not read capture shell identity"
capture_server_identity=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; fm_lifecycle_process_identity "$2"' \
  _ "$ROOT" "$capture_server_pid") || fail "could not read capture server identity"
present_body > "$BODY"
capture_record=$(env PATH="$capture_bin:$PATH" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/capture-inv.log" FM_RETIRE_EP_LOG="$TMP_ROOT/capture-ep.log" \
  FM_RETIRE_CAPTURE_SHELL_PID="$capture_shell_pid" FM_RETIRE_CAPTURE_SERVER_PID="$capture_server_pid" \
  FM_RETIRE_CAPTURE_SOCKET="$SOCK" \
  bash -c '. "$1/bin/fm-nm-run-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; fm_lifecycle_retire_capture_herdr_identity "$2" pane-1' \
  _ "$ROOT" "$SESSION") || fail "could not capture recorded Herdr identity"
assert_contains "$capture_record" "lifecycle_process_pid=$capture_shell_pid" "capture records the pane shell pid"
assert_contains "$capture_record" "lifecycle_process_identity=$capture_shell_identity" "capture binds the pane shell start identity"
assert_contains "$capture_record" "lifecycle_server_pid=$capture_server_pid" "capture records the server pid"
assert_contains "$capture_record" "lifecycle_server_identity=$capture_server_identity" "capture binds the server start identity"

base_env() {
  printf '%s\n' \
    "FM_RETIRE_INV_BODY=$BODY" \
    "FM_RETIRE_INV_LOG=$1" \
    "FM_RETIRE_EP_LOG=$2"
}

# --- startup and usage -------------------------------------------------------
before_state=absent
[ -e "$ROOT/state" ] && before_state=present
err=$TMP_ROOT/usage.err
life "$err"
assert_equals 3 "$LIFE_RC" "fm-lifecycle.sh with no arguments exits 3"
[ "$before_state" = absent ] && assert_absent "$ROOT/state" \
  "sourcing the lifecycle command created no state directory"
pass "negative control: fm-lifecycle.sh (no arguments) exited 3 and created no state"

req=$TMP_ROOT/missing-request.json
out=$TMP_ROOT/missing-out.json
err=$TMP_ROOT/missing.err
life "$err" retire --request "$req" --out "$out"
assert_equals 1 "$LIFE_RC" "retire of a missing request exits 1"
assert_equals refused "$(json_get .status)" "a missing request is refused"
assert_equals false "$(json_get .authority)" "a refusal carries no authority"
pass "negative control: fm-lifecycle.sh retire --request missing exited $LIFE_RC; nothing was retired"

# --- schema refusals ---------------------------------------------------------
parent=$(mk_parent schema-home)
write_ship_meta "$parent" ship1
before=$(file_sum "$parent/state/ship1.meta")
ship_ep "$parent" ship1 > "$TMP_ROOT/schema-ep.json"
jq '.session = "default" | .window = "default:p1"' "$TMP_ROOT/schema-ep.json" | jq -s '.' > "$TMP_ROOT/schema-eps.json"
write_request "$TMP_ROOT/schema-req.json" op-default "$parent" session-absent "$TMP_ROOT/schema-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/schema.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/schema.log" FM_RETIRE_EP_LOG="$TMP_ROOT/schema-ep.log" \
  retire --request "$TMP_ROOT/schema-req.json" --out "$TMP_ROOT/schema-out.json"
assert_equals 1 "$LIFE_RC" "the default session is refused"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a default session leaves the task record unchanged"
assert_absent "$parent/state/lifecycle-retire" "a schema refusal writes no journal"
pass "negative control: fm-lifecycle.sh retire default-session exited $LIFE_RC; meta unchanged"

jq '.session = "crew-alpha" | .window = "crew-alpha:p1"' "$TMP_ROOT/schema-ep.json" | jq -s '.' > "$TMP_ROOT/crewalpha-eps.json"
write_request "$TMP_ROOT/crewalpha-req.json" op-crewalpha "$parent" session-absent "$TMP_ROOT/crewalpha-eps.json"
life "$TMP_ROOT/crewalpha.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/crewalpha.log" FM_RETIRE_EP_LOG="$TMP_ROOT/crewalpha-ep.log" \
  retire --request "$TMP_ROOT/crewalpha-req.json" --out "$TMP_ROOT/crewalpha-out.json"
assert_equals 2 "$LIFE_RC" "a helper-unselectable named session is incomplete"
assert_equals inventory-unavailable "$(json_get '.reasons[0].code')" "the result reports the helper capability gap"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a non-lab session leaves the task record unchanged"
assert_present "$parent/state/lifecycle-retire/op-crewalpha/request.json" "the incomplete request remains recoverable"
pass "negative control: fm-lifecycle.sh retire helper-unselectable-session exited $LIFE_RC; capability gap reported"

jq '.kind = "secondmate" | .retain_home = false' "$TMP_ROOT/schema-ep.json" | jq -s '.' > "$TMP_ROOT/retainfalse-eps.json"
write_request "$TMP_ROOT/retainfalse-req.json" op-retainfalse "$parent" session-absent "$TMP_ROOT/retainfalse-eps.json"
life "$TMP_ROOT/retainfalse.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/retainfalse.log" FM_RETIRE_EP_LOG="$TMP_ROOT/schema-ep.log" \
  retire --request "$TMP_ROOT/retainfalse-req.json" --out "$TMP_ROOT/retainfalse-out.json"
assert_equals 1 "$LIFE_RC" "retain_home false on a secondmate is refused"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "retain_home false leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire retain_home=false exited $LIFE_RC; meta unchanged"

printf '%s\n' '{"schema_version":1,"schema_version":1}' > "$TMP_ROOT/dup.json"
life "$TMP_ROOT/dup.err" retire --request "$TMP_ROOT/dup.json" --out "$TMP_ROOT/dup-out.json"
assert_equals 1 "$LIFE_RC" "a duplicate key is refused"
assert_equals bad-request "$(json_get '.reasons[0].code')" "a duplicate key is a bad request"
pass "negative control: fm-lifecycle.sh retire duplicate-key exited $LIFE_RC"

# Inspection must still work when temporary-file allocation is forbidden.
parent=$(mk_parent inspect-memory-home)
write_ship_meta "$parent" ship1
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/inspect-memory-eps.json"
write_request "$TMP_ROOT/inspect-memory-req.json" op-inspect-memory "$parent" session-absent "$TMP_ROOT/inspect-memory-eps.json"
absent_body > "$BODY"
no_scratch_bin=$TMP_ROOT/no-scratch-bin
mkdir -p "$no_scratch_bin"
cat > "$no_scratch_bin/mktemp" <<'SH'
#!/usr/bin/env bash
printf 'inspection attempted temporary allocation\n' >&2
exit 97
SH
chmod +x "$no_scratch_bin/mktemp"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/inspect-memory.err" PATH="$no_scratch_bin:$PATH" \
  FM_RETIRE_INV_BODY="$BODY" FM_RETIRE_INV_LOG="$TMP_ROOT/inspect-memory.log" \
  FM_RETIRE_EP_LOG="$TMP_ROOT/inspect-memory-ep.log" \
  inspect --request "$TMP_ROOT/inspect-memory-req.json" --out "$TMP_ROOT/inspect-memory-out.json"
assert_equals 0 "$LIFE_RC" "inspection succeeds without allocating temporary files"
assert_equals ready "$(json_get .status)" "in-memory inspection runs the shared validators"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "inspection preserves authoritative metadata"
assert_absent "$parent/state/lifecycle-retire" "inspection creates no journal"
pass "inspection reports readiness with temporary allocation forbidden"

# --- absence discrimination --------------------------------------------------
parent=$(mk_parent absent-home)
write_ship_meta "$parent" ship1
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/abs-eps.json"
write_request "$TMP_ROOT/abs-req.json" op-absent "$parent" session-absent "$TMP_ROOT/abs-eps.json"
present_body > "$BODY"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/present.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/present.log" FM_RETIRE_EP_LOG="$TMP_ROOT/present-ep.log" \
  retire --request "$TMP_ROOT/abs-req.json" --out "$TMP_ROOT/present-out.json"
assert_equals 1 "$LIFE_RC" "a present session is refused"
assert_equals session-present "$(json_get '.reasons[0].code')" "the refusal names the present session"
assert_equals same-request "$(json_get .retry)" "a present session can be retried"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a present session leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire session-present exited $LIFE_RC; meta unchanged"

override=$TMP_ROOT/override-inventory.sh
cat > "$override" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"sessions":[]}'
SH
chmod +x "$override"
life "$TMP_ROOT/override.err" FM_LIFECYCLE_INVENTORY_COMMAND="$override" \
  FM_RETIRE_INV_BODY="$BODY" FM_RETIRE_INV_LOG="$TMP_ROOT/override.log" FM_RETIRE_EP_LOG="$TMP_ROOT/override-ep.log" \
  retire --request "$TMP_ROOT/abs-req.json" --out "$TMP_ROOT/override-out.json"
assert_equals 1 "$LIFE_RC" "an inventory override cannot replace the trusted read"
assert_equals session-present "$(json_get '.reasons[0].code')" "the trusted read still sees the present session"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "an ignored inventory override leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire ignored-inventory-override exited $LIFE_RC; meta unchanged"

rm -rf -- "$parent/state/lifecycle-retire"
life "$TMP_ROOT/inspect-present.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/inspect-present.log" FM_RETIRE_EP_LOG="$TMP_ROOT/present-ep.log" \
  inspect --request "$TMP_ROOT/abs-req.json" --out "$TMP_ROOT/inspect-present-out.json"
assert_equals 0 "$LIFE_RC" "inspect exits 0 when it reports a refusal"
assert_equals refused "$(json_get .status)" "inspect reports the present session as refused"
assert_equals false "$(json_get .authority)" "inspect grants no authority"
assert_absent "$parent/state/lifecycle-retire" "inspect writes no journal"
pass "negative control: fm-lifecycle.sh inspect session-present exited $LIFE_RC; no journal"

stopped_body > "$BODY"
life "$TMP_ROOT/stopped.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/stopped.log" FM_RETIRE_EP_LOG="$TMP_ROOT/stopped-ep.log" \
  retire --request "$TMP_ROOT/abs-req.json" --out "$TMP_ROOT/stopped-out.json"
assert_equals 1 "$LIFE_RC" "a stopped session is refused"
assert_equals session-stopped "$(json_get '.reasons[0].code')" "the refusal names the stopped session"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a stopped session leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire session-stopped exited $LIFE_RC; meta unchanged"

printf '%s\n' 'not-json' > "$BODY"
life "$TMP_ROOT/badinv.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/badinv.log" FM_RETIRE_EP_LOG="$TMP_ROOT/badinv-ep.log" \
  retire --request "$TMP_ROOT/abs-req.json" --out "$TMP_ROOT/badinv-out.json"
assert_equals 2 "$LIFE_RC" "an unreadable inventory is incomplete"
assert_equals inventory-unreadable "$(json_get '.reasons[0].code')" "the refusal names the unreadable inventory"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "an unreadable inventory leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire malformed-inventory exited $LIFE_RC; meta unchanged"

life "$TMP_ROOT/noresult.err" result --home "$parent" --operation-id op-missing --out "$TMP_ROOT/noresult-out.json"
assert_equals 2 "$LIFE_RC" "a missing result is incomplete"
assert_equals result-absent "$(json_get '.reasons[0].code')" "the missing result is named"
assert_equals same-request "$(json_get .retry)" "a missing result can be retried"
pass "negative control: fm-lifecycle.sh result missing exited $LIFE_RC"

# --- a live recorded process is not retired -----------------------------------
parent=$(mk_parent live-home)
write_ship_meta "$parent" ship1
sleep 300 &
live_pid=$!
track "$live_pid"
live_ident=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; fm_lifecycle_process_identity "$2"' _ "$ROOT" "$live_pid") \
  || fail "could not read the live process identity"
one_ep "$parent" ship1 ship "$GEN" false "$live_pid" "$live_ident" "$BOOT" \
  "$DEAD_PID" "$GONE_IDENT" "$BOOT" "$SOCK" pane-1 "" "$SESSION" | jq -s '.' > "$TMP_ROOT/live-eps.json"
write_request "$TMP_ROOT/live-req.json" op-live "$parent" session-absent "$TMP_ROOT/live-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/live.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/live.log" FM_RETIRE_EP_LOG="$TMP_ROOT/live-ep.log" \
  retire --request "$TMP_ROOT/live-req.json" --out "$TMP_ROOT/live-out.json"
assert_equals 1 "$LIFE_RC" "a live process is refused"
assert_equals process-alive "$(json_get '.reasons[0].code')" "the refusal names the live process"
kill -0 "$live_pid" 2>/dev/null || fail "the live process was killed"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a live process leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire process-alive exited $LIFE_RC; process $live_pid still alive"
kill "$live_pid" 2>/dev/null || true

# --- a changed boot id is absence and does not kill --------------------------
parent=$(mk_parent boot-home)
inst=$(mk_installed "$parent" mate1 boot-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/boot-eps.json"
# Replace the recorded boot id with a value this machine is not running.
jq '.[0].process.boot_id = "wrong-boot" | .[0].server.boot_id = "wrong-boot" | .[0].process.pid = '"$live_pid"' | .[0].server.pid = '"$live_pid" \
  "$TMP_ROOT/boot-eps.json" > "$TMP_ROOT/boot-eps2.json"
sleep 300 &
boot_pid=$!
track "$boot_pid"
jq '.[0].process.pid = '"$boot_pid"' | .[0].server.pid = '"$boot_pid" \
  "$TMP_ROOT/boot-eps2.json" > "$TMP_ROOT/boot-eps3.json"
set_meta_runtime "$parent/state/mate1.meta" "$boot_pid" "$GONE_IDENT" wrong-boot \
  "$boot_pid" "$GONE_IDENT" wrong-boot
write_request "$TMP_ROOT/boot-req.json" op-boot "$parent" session-absent "$TMP_ROOT/boot-eps3.json"
absent_body > "$BODY"
panes_before=$(file_sum "$inst/config/agent-kit/herdr-panes")
life "$TMP_ROOT/boot.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/boot.log" FM_RETIRE_EP_LOG="$TMP_ROOT/boot-ep.log" \
  retire --request "$TMP_ROOT/boot-req.json" --out "$TMP_ROOT/boot-out.json"
assert_equals 0 "$LIFE_RC" "a changed boot id retires the recorded actor: $(cat "$TMP_ROOT/boot.err")"
kill -0 "$boot_pid" 2>/dev/null || fail "a changed boot id killed the reused pid"
assert_equals "$panes_before" "$(file_sum "$inst/config/agent-kit/herdr-panes")" "a changed boot id leaves the retained home unchanged"
assert_present "$inst" "a changed boot id keeps the installed home"
pass "negative control: fm-lifecycle.sh retire boot-changed exited $LIFE_RC; process $boot_pid still alive; home retained"
kill "$boot_pid" 2>/dev/null || true

# --- pid reuse is absence and does not kill ----------------------------------
parent=$(mk_parent reuse-home)
inst=$(mk_installed "$parent" mate1 reuse-inst)
sleep 300 &
reuse_pid=$!
track "$reuse_pid"
reuse_ident=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; fm_lifecycle_process_identity "$2"' _ "$ROOT" "$reuse_pid") \
  || fail "could not read the reused pid identity"
proc=$TMP_ROOT/procroot
mkdir -p "$proc/$reuse_pid"
printf '%s\n' "1 (sleep) S 1 1 1 1 0 0 0 0 0 0 0 0 0 0 20 0 1 0 4242" > "$proc/$reuse_pid/stat"
one_ep "$parent" mate1 secondmate "$GEN" true "$reuse_pid" "$reuse_ident" "$BOOT" \
  "$DEAD_PID" "$GONE_IDENT" "$BOOT" "$SOCK" pane-1 "" "$SESSION" | jq -s '.' > "$TMP_ROOT/reuse-eps.json"
set_meta_runtime "$parent/state/mate1.meta" "$reuse_pid" "$reuse_ident" "$BOOT" \
  "$DEAD_PID" "$GONE_IDENT" "$BOOT"
write_request "$TMP_ROOT/reuse-req.json" op-reuse "$parent" session-absent "$TMP_ROOT/reuse-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/reuse.err" FM_PROC_ROOT_OVERRIDE="$proc" \
  FM_RETIRE_INV_BODY="$BODY" FM_RETIRE_INV_LOG="$TMP_ROOT/reuse.log" FM_RETIRE_EP_LOG="$TMP_ROOT/reuse-ep.log" \
  retire --request "$TMP_ROOT/reuse-req.json" --out "$TMP_ROOT/reuse-out.json"
assert_equals 0 "$LIFE_RC" "a reused pid retires: $(cat "$TMP_ROOT/reuse.err")"
kill -0 "$reuse_pid" 2>/dev/null || fail "pid reuse killed the live process"
assert_present "$inst/.fm-secondmate-home" "pid reuse keeps the secondmate marker"
pass "negative control: fm-lifecycle.sh retire pid-reused exited $LIFE_RC; process $reuse_pid still alive"
kill "$reuse_pid" 2>/dev/null || true

# --- retained secondmate success, inspect, and replay ------------------------
parent=$(mk_parent keep-home)
inst=$(mk_installed "$parent" mate1 keep-inst)
write_ship_meta "$parent" ship1
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/keep-eps.json"
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/keep-ship-eps.json"
# Success case is the secondmate alone first.
write_request "$TMP_ROOT/keep-req.json" op-keep "$parent" session-absent "$TMP_ROOT/keep-eps.json"
absent_body > "$BODY"
: > "$TMP_ROOT/keep.log"
head_before=$(git -C "$inst" rev-parse HEAD)
reg_before=$(file_sum "$parent/data/secondmates.md")
life "$TMP_ROOT/keep-inspect.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/keep.log" FM_RETIRE_EP_LOG="$TMP_ROOT/keep-ep.log" \
  inspect --request "$TMP_ROOT/keep-req.json" --out "$TMP_ROOT/keep-inspect.json"
assert_equals 0 "$LIFE_RC" "inspect of an absent session is ready: $(cat "$TMP_ROOT/keep-inspect.err")"
assert_equals ready "$(json_get .status)" "inspect reports ready"
assert_equals false "$(json_get .authority)" "ready is not authority to mutate"
assert_absent "$parent/state/lifecycle-retire" "inspect writes no retirement journal"
pass "fm-lifecycle.sh inspect ready exited $LIFE_RC; authority false; no journal"

life "$TMP_ROOT/keep.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/keep.log" FM_RETIRE_EP_LOG="$TMP_ROOT/keep-ep.log" \
  retire --request "$TMP_ROOT/keep-req.json" --out "$TMP_ROOT/keep-out.json"
assert_equals 0 "$LIFE_RC" "session-absent retirement completed: $(cat "$TMP_ROOT/keep.err")"
assert_equals complete "$(json_get .status)" "retirement reports complete"
assert_equals false "$(json_get .authority)" "complete carries no extra authority"
assert_equals "$inst" "$(json_get '.retained_homes[0]')" "retained_homes is the installed directory"
assert_equals 1 "$(json_get '.retained_homes | length')" "retained_homes lists only the installed directory"
assert_absent "$parent/state/mate1.meta" "the secondmate task record is removed"
assert_present "$parent/state/mate1.endpoint-retired" "the endpoint-retired record is published"
assert_grep "installed_home=$inst" "$parent/state/mate1.endpoint-retired" "the retired record names the installed home"
assert_grep "retain_home=true" "$parent/state/mate1.endpoint-retired" "the retired record keeps the home"
assert_equals "$head_before" "$(git -C "$inst" rev-parse HEAD)" "the retained checkout is unchanged"
assert_equals "$reg_before" "$(file_sum "$parent/data/secondmates.md")" "the registry binding is unchanged"
assert_present "$inst/.fm-secondmate-parent" "the parent binding remains"
retired_sum=$(file_sum "$parent/state/mate1.endpoint-retired")
lines_before=$(wc -l < "$TMP_ROOT/keep.log" | tr -d ' ')
life "$TMP_ROOT/keep-replay.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/keep.log" FM_RETIRE_EP_LOG="$TMP_ROOT/keep-ep.log" \
  retire --request "$TMP_ROOT/keep-req.json" --out "$TMP_ROOT/keep-replay.json"
assert_equals 0 "$LIFE_RC" "replaying a completed request exits 0: $(cat "$TMP_ROOT/keep-replay.err")"
assert_equals already-retired "$(json_get .status)" "replay reports already-retired"
assert_equals "$lines_before" "$(wc -l < "$TMP_ROOT/keep.log" | tr -d ' ')" "replay does not inventory again"
assert_equals "$retired_sum" "$(file_sum "$parent/state/mate1.endpoint-retired")" "replay does not rewrite the retired record"
life "$TMP_ROOT/keep-result.err" result --home "$parent" --operation-id op-keep --out "$TMP_ROOT/keep-result.json"
assert_equals 0 "$LIFE_RC" "reading the stored result exits 0"
assert_equals complete "$(json_get .status)" "the stored result reads back as complete"
pass "fm-lifecycle.sh retire retained-home exited 0; replay exited 0 without a new inventory"

parent=$(mk_parent twohomes-home)
inst1=$(mk_installed "$parent" mate1 twohomes-inst1)
inst2=$(mk_installed "$parent" mate2 twohomes-inst2)
printf '%s\n' \
  "- mate1 - Lab mate (home: $inst1; scope: local work; projects: alpha; added 2026-01-01)" \
  "- mate2 - Lab mate (home: $inst2; scope: local work; projects: alpha; added 2026-01-01)" \
  > "$parent/data/secondmates.md"
set_meta_runtime "$parent/state/mate2.meta" "$DEAD_PID" "$GONE_IDENT" "$BOOT" \
  "$DEAD_PID" "$GONE_IDENT" "$BOOT" pane-2
mate_ep "$parent" mate1 > "$TMP_ROOT/twohomes-mate1.json"
mate_ep "$parent" mate2 | jq '.pane_id = "pane-2"' > "$TMP_ROOT/twohomes-mate2.json"
jq -s '.' "$TMP_ROOT/twohomes-mate1.json" "$TMP_ROOT/twohomes-mate2.json" > "$TMP_ROOT/twohomes-eps.json"
write_request "$TMP_ROOT/twohomes-req.json" op-twohomes "$parent" session-absent "$TMP_ROOT/twohomes-eps.json"
absent_body > "$BODY"
sum1=$(file_sum "$inst1/config/agent-kit/herdr-panes")
sum2=$(file_sum "$inst2/config/agent-kit/herdr-panes")
life "$TMP_ROOT/twohomes.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/twohomes.log" FM_RETIRE_EP_LOG="$TMP_ROOT/twohomes-ep.log" \
  retire --request "$TMP_ROOT/twohomes-req.json" --out "$TMP_ROOT/twohomes-out.json"
assert_equals 0 "$LIFE_RC" "two retained homes retire together: $(cat "$TMP_ROOT/twohomes.err")"
assert_present "$inst1/.fm-secondmate-home" "the first retained home marker stays"
assert_present "$inst2/.fm-secondmate-home" "the second retained home marker stays"
assert_equals "$sum1" "$(file_sum "$inst1/config/agent-kit/herdr-panes")" "the first retained home bytes stay"
assert_equals "$sum2" "$(file_sum "$inst2/config/agent-kit/herdr-panes")" "the second retained home bytes stay"
assert_grep "$inst1" "$parent/data/secondmates.md" "the first registry binding stays"
assert_grep "$inst2" "$parent/data/secondmates.md" "the second registry binding stays"
pass "fm-lifecycle.sh retire two retained homes exited $LIFE_RC; both homes and registry bindings stayed"

# --- child before parent, and a child that blocks the parent -----------------
parent=$(mk_parent order-home)
inst=$(mk_installed "$parent" mate1 order-inst)
printf 'manual\n' > "$inst/config/backlog-backend"
write_ship_meta "$inst" ship1 "$GEN" direct-PR
printf '%s\n' 'done: shipped' > "$inst/state/ship1.status"
printf 'DECOY\n' > "$parent/state/ship1.status"
printf 'CHILD-COPY\n' > "$inst/state/mate1.status"
ship_ep "$inst" ship1 "$GEN" mate1 > "$TMP_ROOT/order-ship.json"
mate_ep "$parent" mate1 > "$TMP_ROOT/order-mate.json"
jq -s '.' "$TMP_ROOT/order-mate.json" "$TMP_ROOT/order-ship.json" > "$TMP_ROOT/order-eps.json"
write_request "$TMP_ROOT/order-req.json" op-order "$parent" session-absent "$TMP_ROOT/order-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/order.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/order.log" FM_RETIRE_EP_LOG="$TMP_ROOT/order-ep.log" \
  retire --request "$TMP_ROOT/order-req.json" --out "$TMP_ROOT/order-out.json"
assert_equals 0 "$LIFE_RC" "child and parent retirement completed: $(cat "$TMP_ROOT/order.err")"
assert_equals ship1 "$(jq -r '.completed[0].task_id' "$parent/state/lifecycle-retire/op-order/progress.json")" \
  "the child is recorded before the parent"
assert_equals mate1 "$(jq -r '.completed[1].task_id' "$parent/state/lifecycle-retire/op-order/progress.json")" \
  "the parent is recorded after the child"
assert_equals 'DECOY' "$(tr -d '\n' < "$parent/state/ship1.status")" "a same-basename decoy was not delivered into"
assert_equals 'CHILD-COPY' "$(tr -d '\n' < "$inst/state/mate1.status")" "the child home copy of the mate status was not delivered into"
assert_absent "$inst/state/ship1.meta" "the child task record is removed"
assert_absent "$parent/state/mate1.meta" "the parent task record is removed after the child"
assert_present "$inst" "the parent retirement keeps the installed home"
pass "fm-lifecycle.sh retire child-before-parent exited $LIFE_RC; decoy status unchanged"

parent=$(mk_parent blocked-home)
inst=$(mk_installed "$parent" mate1 blocked-inst)
printf '%s\n' 'kind=ship' 'spawn_gen=s1.2.3' 'backend=herdr' 'session=fm-lab-retire1' 'home='"$inst" \
  > "$inst/state/extra.meta"
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/blocked-eps.json"
write_request "$TMP_ROOT/blocked-req.json" op-blocked "$parent" session-absent "$TMP_ROOT/blocked-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/mate1.meta")
life "$TMP_ROOT/blocked.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/blocked.log" FM_RETIRE_EP_LOG="$TMP_ROOT/blocked-ep.log" \
  retire --request "$TMP_ROOT/blocked-req.json" --out "$TMP_ROOT/blocked-out.json"
assert_equals 1 "$LIFE_RC" "an undeclared child blocks the parent"
assert_equals obligation-children "$(json_get '.reasons[0].code')" "the refusal names the remaining child"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a blocked parent task record stays"
assert_present "$inst/state/extra.meta" "the undeclared child record stays"
pass "negative control: fm-lifecycle.sh retire undeclared-child exited $LIFE_RC; parent meta unchanged"

parent=$(mk_parent foreign-home)
inst=$(mk_installed "$parent" mate1 foreign-inst)
other=$(abs_dir "$TMP_ROOT/foreign-other")
mkdir -p "$other/state" "$other/config"
printf 'manual\n' > "$other/config/backlog-backend"
write_ship_meta "$other" ship1
ship_ep "$other" ship1 "$GEN" mate1 > "$TMP_ROOT/foreign-ship.json"
mate_ep "$parent" mate1 > "$TMP_ROOT/foreign-mate.json"
jq -s '.' "$TMP_ROOT/foreign-mate.json" "$TMP_ROOT/foreign-ship.json" > "$TMP_ROOT/foreign-eps.json"
write_request "$TMP_ROOT/foreign-req.json" op-foreign "$parent" session-absent "$TMP_ROOT/foreign-eps.json"
before=$(file_sum "$parent/state/mate1.meta")
ship_before=$(file_sum "$other/state/ship1.meta")
life "$TMP_ROOT/foreign.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/foreign.log" FM_RETIRE_EP_LOG="$TMP_ROOT/foreign-ep.log" \
  retire --request "$TMP_ROOT/foreign-req.json" --out "$TMP_ROOT/foreign-out.json"
assert_equals 1 "$LIFE_RC" "a child outside the installed home is refused"
assert_equals foreign-descendant "$(json_get '.reasons[0].code')" "the refusal names the foreign child"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a foreign child leaves the parent record unchanged"
assert_equals "$ship_before" "$(file_sum "$other/state/ship1.meta")" "a foreign child leaves the child record unchanged"
assert_absent "$parent/state/lifecycle-retire" "a foreign child writes no journal"
pass "negative control: fm-lifecycle.sh retire foreign-descendant exited $LIFE_RC; both records unchanged"

parent=$(mk_parent root-owner-home)
other=$(mk_parent root-foreign-home)
write_ship_meta "$other" ship1
ship_ep "$other" ship1 | jq -s '.' > "$TMP_ROOT/root-foreign-eps.json"
write_request "$TMP_ROOT/root-foreign-req.json" op-root-foreign "$parent" session-absent "$TMP_ROOT/root-foreign-eps.json"
absent_body > "$BODY"
before=$(file_sum "$other/state/ship1.meta")
life "$TMP_ROOT/root-foreign-inspect.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/root-foreign-inspect.log" FM_RETIRE_EP_LOG="$TMP_ROOT/root-foreign-inspect-ep.log" \
  inspect --request "$TMP_ROOT/root-foreign-req.json" --out "$TMP_ROOT/root-foreign-inspect.json"
assert_equals 0 "$LIFE_RC" "inspect reports a foreign root refusal"
assert_equals refused "$(json_get .status)" "inspect refuses a root owned by another home"
life "$TMP_ROOT/root-foreign-retire.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/root-foreign-retire.log" FM_RETIRE_EP_LOG="$TMP_ROOT/root-foreign-retire-ep.log" \
  retire --request "$TMP_ROOT/root-foreign-req.json" --out "$TMP_ROOT/root-foreign-retire.json"
assert_equals 1 "$LIFE_RC" "retirement refuses a root owned by another home"
assert_equals identity-mismatch "$(json_get '.reasons[0].code')" "the refusal names root ownership"
assert_equals "$before" "$(file_sum "$other/state/ship1.meta")" "a foreign root task record stays unchanged"
assert_absent "$parent/state/lifecycle-retire" "a foreign root request writes no journal"

# --- obligation refusals -----------------------------------------------------
parent=$(mk_parent dirty-home)
write_ship_meta "$parent" ship1
wt=$(abs_dir "$TMP_ROOT/dirty-wt")
git -C "$wt" init -q
printf 'a\n' > "$wt/a.txt"
git -C "$wt" add a.txt
git -C "$wt" -c user.email=t@example.com -c user.name=tester commit -q -m a
printf 'dirty\n' > "$wt/b.txt"
printf 'worktree=%s\n' "$wt" >> "$parent/state/ship1.meta"
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/dirty-eps.json"
write_request "$TMP_ROOT/dirty-req.json" op-dirty "$parent" session-absent "$TMP_ROOT/dirty-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/dirty.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/dirty.log" FM_RETIRE_EP_LOG="$TMP_ROOT/dirty-ep.log" \
  retire --request "$TMP_ROOT/dirty-req.json" --out "$TMP_ROOT/dirty-out.json"
assert_equals 1 "$LIFE_RC" "a dirty worktree is refused"
assert_equals obligation-unlanded "$(json_get '.reasons[0].code')" "the refusal names unlanded work"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a dirty worktree leaves the task record unchanged"
assert_present "$wt/b.txt" "a dirty worktree leaves the uncommitted file"
pass "negative control: fm-lifecycle.sh retire dirty-worktree exited $LIFE_RC; meta and dirty file unchanged"

parent=$(mk_parent reply-home)
inst=$(mk_installed "$parent" mate1 reply-inst)
mkdir -p "$parent/state/pending-replies"
printf '%s\n' 'task_id=mate1' 'phase=open' > "$parent/state/pending-replies/one"
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/reply-eps.json"
write_request "$TMP_ROOT/reply-req.json" op-reply "$parent" session-absent "$TMP_ROOT/reply-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/mate1.meta")
life "$TMP_ROOT/reply.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/reply.log" FM_RETIRE_EP_LOG="$TMP_ROOT/reply-ep.log" \
  retire --request "$TMP_ROOT/reply-req.json" --out "$TMP_ROOT/reply-out.json"
assert_equals 1 "$LIFE_RC" "an unresolved pending reply is refused"
assert_equals obligation-pending-reply "$(json_get '.reasons[0].code')" "the refusal names the pending reply"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a pending reply leaves the task record unchanged"
assert_present "$parent/state/pending-replies/one" "a pending reply record stays"
pass "negative control: fm-lifecycle.sh retire pending-reply exited $LIFE_RC; meta unchanged"

parent=$(mk_parent scout-home)
cat > "$parent/state/scout1.meta" <<EOF
kind=scout
spawn_gen=$GEN
backend=herdr
session=$SESSION
window=$SESSION:p1
mode=no-mistakes
harness=claude
herdr_pane_id=pane-1
herdr_workspace_id=w
herdr_tab_id=t
lifecycle_process_pid=$DEAD_PID
lifecycle_process_identity=$GONE_IDENT
lifecycle_process_boot_id=$BOOT
lifecycle_server_socket_path=$SOCK
lifecycle_server_pid=$DEAD_PID
lifecycle_server_identity=$GONE_IDENT
lifecycle_server_boot_id=$BOOT
EOF
one_ep "$parent" scout1 scout "$GEN" false "$DEAD_PID" "$GONE_IDENT" "$BOOT" \
  "$DEAD_PID" "$GONE_IDENT" "$BOOT" "$SOCK" pane-1 "" "$SESSION" | jq -s '.' > "$TMP_ROOT/scout-eps.json"
write_request "$TMP_ROOT/scout-req.json" op-scout "$parent" session-absent "$TMP_ROOT/scout-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/scout1.meta")
life "$TMP_ROOT/scout.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/scout.log" FM_RETIRE_EP_LOG="$TMP_ROOT/scout-ep.log" \
  retire --request "$TMP_ROOT/scout-req.json" --out "$TMP_ROOT/scout-out.json"
assert_equals 1 "$LIFE_RC" "a scout with no report is refused"
assert_equals obligation-scout "$(json_get '.reasons[0].code')" "the refusal names the scout report"
assert_equals "$before" "$(file_sum "$parent/state/scout1.meta")" "a missing scout report leaves the task record unchanged"
assert_absent "$parent/data/scout1/report.md" "the missing report was not invented"
pass "negative control: fm-lifecycle.sh retire missing-scout-report exited $LIFE_RC; meta unchanged"

parent=$(mk_parent badparent-home)
inst=$(mk_installed "$parent" mate1 badparent-inst)
printf 'manual\n' > "$inst/config/backlog-backend"
printf 'bogus\n' > "$inst/.fm-secondmate-parent"
write_ship_meta "$inst" ship1
ship_ep "$inst" ship1 "$GEN" mate1 > "$TMP_ROOT/badparent-ship.json"
mate_ep "$parent" mate1 > "$TMP_ROOT/badparent-mate.json"
jq -s '.' "$TMP_ROOT/badparent-mate.json" "$TMP_ROOT/badparent-ship.json" > "$TMP_ROOT/badparent-eps.json"
write_request "$TMP_ROOT/badparent-req.json" op-badparent "$parent" session-absent "$TMP_ROOT/badparent-eps.json"
absent_body > "$BODY"
before=$(file_sum "$inst/state/ship1.meta")
life "$TMP_ROOT/badparent.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/badparent.log" FM_RETIRE_EP_LOG="$TMP_ROOT/badparent-ep.log" \
  retire --request "$TMP_ROOT/badparent-req.json" --out "$TMP_ROOT/badparent-out.json"
assert_equals 1 "$LIFE_RC" "an unreadable parent binding is refused"
assert_equals obligation-followup "$(json_get '.reasons[0].code')" "the refusal names the parent binding"
assert_equals "$before" "$(file_sum "$inst/state/ship1.meta")" "an unreadable parent binding leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire invalid-parent exited $LIFE_RC; meta unchanged"

parent=$(mk_parent deliver-home)
inst=$(mk_installed "$parent" mate1 deliver-inst)
printf 'manual\n' > "$inst/config/backlog-backend"
write_ship_meta "$inst" ship1 "$GEN" direct-PR
deliver_url=https://github.com/Pibomeister/firstmate/pull/1
printf 'pr=%s\n' "$deliver_url" >> "$inst/state/ship1.meta"
printf 'done: PR %s\n' "$deliver_url" > "$inst/state/ship1.status"
printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com Pibomeister/firstmate 1 \
  > "$inst/state/ship1.pr-poll-merge-notified"
chmod 600 "$inst/state/ship1.pr-poll-merge-notified"
mkdir -p "$parent/state/mate1.status"
ship_ep "$inst" ship1 "$GEN" mate1 > "$TMP_ROOT/deliver-ship.json"
mate_ep "$parent" mate1 > "$TMP_ROOT/deliver-mate.json"
jq -s '.' "$TMP_ROOT/deliver-mate.json" "$TMP_ROOT/deliver-ship.json" > "$TMP_ROOT/deliver-eps.json"
write_request "$TMP_ROOT/deliver-req.json" op-deliver "$parent" session-absent "$TMP_ROOT/deliver-eps.json"
absent_body > "$BODY"
before=$(file_sum "$inst/state/ship1.meta")
life "$TMP_ROOT/deliver.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/deliver.log" FM_RETIRE_EP_LOG="$TMP_ROOT/deliver-ep.log" \
  retire --request "$TMP_ROOT/deliver-req.json" --out "$TMP_ROOT/deliver-out.json"
assert_equals 2 "$LIFE_RC" "a failed parent delivery is incomplete: $(cat "$TMP_ROOT/deliver.err")"
assert_equals outcome-undelivered "$(json_get '.reasons[0].code')" "the refusal names the undelivered outcome"
assert_equals "$before" "$(file_sum "$inst/state/ship1.meta")" "a failed delivery leaves the task record unchanged"
assert_present "$parent/state/mate1.status" "the blocked parent channel stays"
pass "negative control: fm-lifecycle.sh retire outcome-undelivered exited $LIFE_RC; meta unchanged"

# --- locks, generation swap, session recreate --------------------------------
parent=$(mk_parent lock-home)
inst=$(mk_installed "$parent" mate1 lock-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/lock-eps.json"
write_request "$TMP_ROOT/lock-req.json" op-lock "$parent" session-absent "$TMP_ROOT/lock-eps.json"
absent_body > "$BODY"
: > "$TMP_ROOT/lock.log"
before=$(file_sum "$parent/state/mate1.meta")
env -u FM_HOME -u STATE -u FM_STATE_OVERRIDE -u FM_LIFECYCLE_INVENTORY_COMMAND -u FM_LIFECYCLE_ENDPOINT_COMMAND \
  HOME="$USER_HOME" PATH="$FAKEBIN:$PATH" \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/lock.log" FM_RETIRE_EP_LOG="$TMP_ROOT/lock-ep.log" \
  FM_RETIRE_INV_MODE=sleep FM_RETIRE_SLEEP_MARK="$TMP_ROOT/lock-mark" \
  "$ROOT/bin/fm-lifecycle.sh" retire --request "$TMP_ROOT/lock-req.json" --out "$TMP_ROOT/lock-out.json" \
  >"$TMP_ROOT/lock.out" 2>"$TMP_ROOT/lock.err" &
lock_pid=$!
track "$lock_pid"
i=0
while [ "$i" -lt 50 ] && [ ! -s "$TMP_ROOT/lock-mark" ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -s "$TMP_ROOT/lock-mark" ] || fail "the retirement holding the lock did not reach its inventory"
life "$TMP_ROOT/lock2.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/lock2.log" FM_RETIRE_EP_LOG="$TMP_ROOT/lock2-ep.log" \
  retire --request "$TMP_ROOT/lock-req.json" --out "$TMP_ROOT/lock2-out.json"
assert_equals 1 "$LIFE_RC" "a second retirement is refused while the lock is held"
assert_equals lock-held "$(json_get '.reasons[0].code')" "the refusal names the held lock"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "the contending retirement leaves the task record unchanged"
kill "$(cat "$TMP_ROOT/lock-mark")" "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true
pass "negative control: fm-lifecycle.sh retire lock-held exited $LIFE_RC; meta unchanged"

parent=$(mk_parent swap-home)
inst=$(mk_installed "$parent" mate1 swap-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/swap-eps.json"
write_request "$TMP_ROOT/swap-req.json" op-swap "$parent" session-absent "$TMP_ROOT/swap-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/swap-fault.err" FM_LIFECYCLE_FAULT_AT=journal-proof \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/swap.log" FM_RETIRE_EP_LOG="$TMP_ROOT/swap-ep.log" \
  retire --request "$TMP_ROOT/swap-req.json" --out "$TMP_ROOT/swap-fault-out.json"
assert_equals 86 "$LIFE_RC" "a fault before the proof returns 86"
assert_absent "$parent/state/lifecycle-retire/op-swap/result.json" "the fault writes no result"
assert_present "$parent/state/lifecycle-retire/op-swap/request.json" "the request was recorded before the fault"
perl -pi -e 's/^spawn_gen=s1\.2\.3$/spawn_gen=s9.9.9/' "$parent/state/mate1.meta"
life "$TMP_ROOT/swap.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/swap2.log" FM_RETIRE_EP_LOG="$TMP_ROOT/swap2-ep.log" \
  retire --request "$TMP_ROOT/swap-req.json" --out "$TMP_ROOT/swap-out.json"
assert_equals 1 "$LIFE_RC" "a generation changed after the request is refused"
assert_equals generation-mismatch "$(json_get '.reasons[0].code')" "the refusal names the generation"
assert_grep 'spawn_gen=s9.9.9' "$parent/state/mate1.meta" "the replacement generation stays"
pass "negative control: fm-lifecycle.sh retire generation-mismatch exited $LIFE_RC; new meta kept"

parent=$(mk_parent recreate-home)
inst=$(mk_installed "$parent" mate1 recreate-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/recreate-eps.json"
write_request "$TMP_ROOT/recreate-req.json" op-recreate "$parent" session-absent "$TMP_ROOT/recreate-eps.json"
: > "$TMP_ROOT/recreate.count"
before=$(file_sum "$parent/state/mate1.meta")
life "$TMP_ROOT/recreate.err" FM_RETIRE_INV_MODE=counter FM_RETIRE_INV_COUNT="$TMP_ROOT/recreate.count" \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/recreate.log" FM_RETIRE_EP_LOG="$TMP_ROOT/recreate-ep.log" \
  retire --request "$TMP_ROOT/recreate-req.json" --out "$TMP_ROOT/recreate-out.json"
assert_equals 1 "$LIFE_RC" "a session that reappears before the member is refused: $(cat "$TMP_ROOT/recreate.err")"
assert_equals session-present "$(json_get '.reasons[0].code')" "the recreated session is present"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a recreated session leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire session-recreated exited $LIFE_RC; meta unchanged"

# --- crash and retry ---------------------------------------------------------
parent=$(mk_parent fault-home)
inst=$(mk_installed "$parent" mate1 fault-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/fault-eps.json"
write_request "$TMP_ROOT/fault-req.json" op-fault "$parent" session-absent "$TMP_ROOT/fault-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/fault-req.err" FM_LIFECYCLE_FAULT_AT=journal-request \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/fault.log" FM_RETIRE_EP_LOG="$TMP_ROOT/fault-ep.log" \
  retire --request "$TMP_ROOT/fault-req.json" --out "$TMP_ROOT/fault-out.json"
assert_equals 86 "$LIFE_RC" "a fault before the journal returns 86"
assert_absent "$parent/state/lifecycle-retire" "a fault before the journal creates no journal"
assert_present "$parent/state/mate1.meta" "a fault before the journal leaves the task record"
pass "negative control: fm-lifecycle.sh retire fault journal-request exited $LIFE_RC; no journal"

fault_parent_case() {
  local boundary=$1 name=$2
  FAULT_PARENT=$(mk_parent "$name-home")
  FAULT_INST=$(mk_installed "$FAULT_PARENT" mate1 "$name-inst")
  mate_ep "$FAULT_PARENT" mate1 | jq -s '.' > "$TMP_ROOT/$name-eps.json"
  write_request "$TMP_ROOT/$name-req.json" "op-$name" "$FAULT_PARENT" session-absent "$TMP_ROOT/$name-eps.json"
  absent_body > "$BODY"
  life "$TMP_ROOT/$name.err" FM_LIFECYCLE_FAULT_AT="$boundary" \
    FM_RETIRE_INV_BODY="$BODY" \
    FM_RETIRE_INV_LOG="$TMP_ROOT/$name.log" FM_RETIRE_EP_LOG="$TMP_ROOT/$name-ep.log" \
    retire --request "$TMP_ROOT/$name-req.json" --out "$TMP_ROOT/$name-out.json"
  assert_equals 86 "$LIFE_RC" "a fault at $boundary returns 86"
  assert_absent "$FAULT_PARENT/state/lifecycle-retire/op-$name/result.json" "a fault at $boundary writes no final result"
  assert_present "$FAULT_INST" "a fault at $boundary leaves the installed home"
}

fault_parent_case journal-proof fault-proof
assert_present "$FAULT_PARENT/state/mate1.meta" "the journal-proof fault leaves the task record"
pass "negative control: fm-lifecycle.sh retire fault journal-proof exited $LIFE_RC; meta remains"

fault_parent_case parent-retirement fault-parent
assert_present "$FAULT_PARENT/state/mate1.meta" "the parent-retirement fault leaves the task record"
assert_absent "$FAULT_PARENT/state/mate1.endpoint-retired" "the parent-retirement fault writes no retirement record"
pass "negative control: fm-lifecycle.sh retire fault parent-retirement exited $LIFE_RC; meta remains"

fault_parent_case backlog-transition fault-backlog
assert_present "$FAULT_PARENT/state/mate1.meta" "the backlog-transition fault leaves the task record"
assert_present "$FAULT_PARENT/state/mate1.endpoint-retired" "the backlog-transition fault records the retired endpoint"
pass "negative control: fm-lifecycle.sh retire fault backlog-transition exited $LIFE_RC; endpoint record recoverable"

fault_parent_case final-receipt fault-final
assert_absent "$FAULT_PARENT/state/mate1.meta" "the final-receipt fault has completed the task mutation"
assert_present "$FAULT_PARENT/state/mate1.endpoint-retired" "the final-receipt fault keeps the endpoint record"
life "$TMP_ROOT/fault-final-retry.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/fault-final-retry.log" FM_RETIRE_EP_LOG="$TMP_ROOT/fault-final-retry-ep.log" \
  retire --request "$TMP_ROOT/fault-final-req.json" --out "$TMP_ROOT/fault-final-retry-out.json"
assert_equals 0 "$LIFE_RC" "retry after final receipt fault completes"
assert_equals complete "$(json_get .status)" "retry after final receipt fault returns complete"
pass "fm-lifecycle.sh retire fault final-receipt exited 86; retry exited $LIFE_RC"

parent=$(mk_parent meta-fault-home)
inst=$(mk_installed "$parent" mate1 meta-fault-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/metafault-eps.json"
write_request "$TMP_ROOT/metafault-req.json" op-meta "$parent" session-absent "$TMP_ROOT/metafault-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/metafault.err" FM_LIFECYCLE_FAULT_AT=metadata-transition \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/metafault.log" FM_RETIRE_EP_LOG="$TMP_ROOT/metafault-ep.log" \
  retire --request "$TMP_ROOT/metafault-req.json" --out "$TMP_ROOT/metafault-out.json"
assert_equals 86 "$LIFE_RC" "a fault at metadata transition returns 86"
assert_present "$parent/state/mate1.meta" "the task record remains after the metadata fault"
assert_present "$parent/state/mate1.endpoint-retired" "the retired record was published before the fault"
assert_absent "$parent/state/lifecycle-retire/op-meta/result.json" "the metadata fault writes no final result"
pass "negative control: fm-lifecycle.sh retire fault metadata-transition exited $LIFE_RC; meta remains"

parent=$(mk_parent partial-home)
inst=$(mk_installed "$parent" mate1 partial-inst)
write_ship_meta "$parent" ship1
mate_ep "$parent" mate1 > "$TMP_ROOT/partial-mate.json"
ship_ep "$parent" ship1 > "$TMP_ROOT/partial-ship.json"
jq -s '.' "$TMP_ROOT/partial-mate.json" "$TMP_ROOT/partial-ship.json" > "$TMP_ROOT/partial-eps.json"
write_request "$TMP_ROOT/partial-req.json" op-partial "$parent" session-absent "$TMP_ROOT/partial-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/partial-fault.err" FM_LIFECYCLE_FAULT_AT=outcome-handoff \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/partial.log" FM_RETIRE_EP_LOG="$TMP_ROOT/partial-ep.log" \
  retire --request "$TMP_ROOT/partial-req.json" --out "$TMP_ROOT/partial-fault-out.json"
assert_equals 86 "$LIFE_RC" "a fault after one member returns 86: $(cat "$TMP_ROOT/partial-fault.err")"
assert_absent "$parent/state/mate1.meta" "the completed secondmate record is removed"
assert_present "$parent/state/ship1.meta" "the ship record remains for retry"
assert_present "$inst" "the completed secondmate home stays"
assert_absent "$parent/state/lifecycle-retire/op-partial/result.json" "the partial fault writes no final result"
retired_sum=$(file_sum "$parent/state/mate1.endpoint-retired")
life "$TMP_ROOT/partial.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/partial2.log" FM_RETIRE_EP_LOG="$TMP_ROOT/partial2-ep.log" \
  retire --request "$TMP_ROOT/partial-req.json" --out "$TMP_ROOT/partial-out.json"
assert_equals 0 "$LIFE_RC" "retry after the partial fault completes: $(cat "$TMP_ROOT/partial.err")"
assert_equals complete "$(json_get .status)" "retry reports complete"
assert_absent "$parent/state/ship1.meta" "retry removes the remaining ship record"
assert_equals "$retired_sum" "$(file_sum "$parent/state/mate1.endpoint-retired")" "retry does not rewrite the completed record"
pass "fm-lifecycle.sh retire fault outcome-handoff exited 86; retry exited $LIFE_RC"

parent=$(mk_parent receipt-fault-home)
inst=$(mk_installed "$parent" mate1 receipt-fault-inst)
printf 'manual\n' > "$inst/config/backlog-backend"
write_ship_meta "$inst" ship1 "$GEN" direct-PR
receipt_url=https://github.com/Pibomeister/firstmate/pull/1
printf 'pr=%s\n' "$receipt_url" >> "$inst/state/ship1.meta"
printf 'done: PR %s\n' "$receipt_url" > "$inst/state/ship1.status"
printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com Pibomeister/firstmate 1 \
  > "$inst/state/ship1.pr-poll-merge-notified"
chmod 600 "$inst/state/ship1.pr-poll-merge-notified"
ship_ep "$inst" ship1 "$GEN" mate1 > "$TMP_ROOT/receipt-fault-ship.json"
mate_ep "$parent" mate1 > "$TMP_ROOT/receipt-fault-mate.json"
jq -s '.' "$TMP_ROOT/receipt-fault-mate.json" "$TMP_ROOT/receipt-fault-ship.json" > "$TMP_ROOT/receipt-fault-eps.json"
write_request "$TMP_ROOT/receipt-fault-req.json" op-receipt-fault "$parent" session-absent "$TMP_ROOT/receipt-fault-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/receipt-fault.err" FM_LIFECYCLE_FAULT_AT=outcome-receipt \
  FM_RETIRE_INV_BODY="$BODY" FM_RETIRE_INV_LOG="$TMP_ROOT/receipt-fault.log" \
  FM_RETIRE_EP_LOG="$TMP_ROOT/receipt-fault-ep.log" \
  retire --request "$TMP_ROOT/receipt-fault-req.json" --out "$TMP_ROOT/receipt-fault-out.json"
assert_equals 86 "$LIFE_RC" "a fault after outcome delivery returns 86"
assert_present "$inst/state/ship1.meta" "the child task remains after receipt failure"
assert_equals 1 "$(grep -c 'child-outcome-ship1-done' "$parent/state/mate1.status")" "the first delivery reached the parent once"
life "$TMP_ROOT/receipt-fault-retry.err" FM_LIFECYCLE_FAULT_AT=parent-retirement FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/receipt-fault-retry.log" FM_RETIRE_EP_LOG="$TMP_ROOT/receipt-fault-retry-ep.log" \
  retire --request "$TMP_ROOT/receipt-fault-req.json" --out "$TMP_ROOT/receipt-fault-retry.json"
assert_equals 86 "$LIFE_RC" "retry reaches the parent after recording the child"
assert_equals 1 "$(grep -c 'child-outcome-ship1-done' "$parent/state/mate1.status")" "retry does not redeliver the child outcome"
life "$TMP_ROOT/receipt-fault-final.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/receipt-fault-final.log" FM_RETIRE_EP_LOG="$TMP_ROOT/receipt-fault-final-ep.log" \
  retire --request "$TMP_ROOT/receipt-fault-req.json" --out "$TMP_ROOT/receipt-fault-final.json"
assert_equals 0 "$LIFE_RC" "final retry after receipt failure completes"

parent=$(mk_parent childfault-home)
inst=$(mk_installed "$parent" mate1 childfault-inst)
printf 'manual\n' > "$inst/config/backlog-backend"
write_ship_meta "$inst" ship1 "$GEN" direct-PR
printf 'done\n' > "$inst/state/ship1.status"
ship_ep "$inst" ship1 "$GEN" mate1 > "$TMP_ROOT/childfault-ship.json"
mate_ep "$parent" mate1 > "$TMP_ROOT/childfault-mate.json"
jq -s '.' "$TMP_ROOT/childfault-mate.json" "$TMP_ROOT/childfault-ship.json" > "$TMP_ROOT/childfault-eps.json"
write_request "$TMP_ROOT/childfault-req.json" op-childfault "$parent" session-absent "$TMP_ROOT/childfault-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/childfault.err" FM_LIFECYCLE_FAULT_AT=child-cleanup \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/childfault.log" FM_RETIRE_EP_LOG="$TMP_ROOT/childfault-ep.log" \
  retire --request "$TMP_ROOT/childfault-req.json" --out "$TMP_ROOT/childfault-out.json"
assert_equals 86 "$LIFE_RC" "a fault at child cleanup returns 86"
assert_present "$inst/state/ship1.meta" "the child-cleanup fault leaves the child record"
assert_present "$parent/state/mate1.meta" "the child-cleanup fault leaves the parent record"
assert_absent "$parent/state/lifecycle-retire/op-childfault/result.json" "the child-cleanup fault writes no result"
pass "negative control: fm-lifecycle.sh retire fault child-cleanup exited $LIFE_RC; both records remain"

# --- endpoint-absent proof, without killing the server -----------------------
parent=$(mk_parent pane-home)
inst=$(mk_installed "$parent" mate1 pane-inst)
sleep 300 &
server_pid=$!
track "$server_pid"
server_ident=$(bash -c '. "$1/bin/fm-nm-run-lib.sh"; . "$1/bin/fm-lifecycle-lib.sh"; fm_lifecycle_process_identity "$2"' _ "$ROOT" "$server_pid") \
  || fail "could not read the server identity"
one_ep "$parent" mate1 secondmate "$GEN" true "$DEAD_PID_2" "$GONE_IDENT" "$BOOT" \
  "$server_pid" "$server_ident" "$BOOT" "$SOCK" pane-missing "" "$SESSION" | jq -s '.' > "$TMP_ROOT/pane-eps.json"
set_meta_runtime "$parent/state/mate1.meta" "$DEAD_PID_2" "$GONE_IDENT" "$BOOT" \
  "$server_pid" "$server_ident" "$BOOT" pane-missing
write_request "$TMP_ROOT/pane-req.json" op-pane "$parent" endpoint-absent "$TMP_ROOT/pane-eps.json"
present_body > "$BODY"
: > "$TMP_ROOT/pane-ep.log"
life "$TMP_ROOT/pane.err" \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/pane.log" FM_RETIRE_EP_LOG="$TMP_ROOT/pane-ep.log" \
  retire --request "$TMP_ROOT/pane-req.json" --out "$TMP_ROOT/pane-out.json"
assert_equals 0 "$LIFE_RC" "endpoint-absent retirement completed: $(cat "$TMP_ROOT/pane.err")"
kill -0 "$server_pid" 2>/dev/null || fail "endpoint-absent killed the server process"
assert_grep 'pane-missing' "$TMP_ROOT/pane-ep.log" "endpoint-absent probed the pane"
assert_present "$inst" "endpoint-absent keeps the installed home"
pass "fm-lifecycle.sh retire endpoint-absent exited $LIFE_RC; server $server_pid still alive"
kill "$server_pid" 2>/dev/null || true

# --- identity mismatches -----------------------------------------------------
parent=$(mk_parent ident-home)
write_ship_meta "$parent" ship1 s9.9.9
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/ident-eps.json"
write_request "$TMP_ROOT/ident-req.json" op-ident "$parent" session-absent "$TMP_ROOT/ident-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/ident.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/ident.log" FM_RETIRE_EP_LOG="$TMP_ROOT/ident-ep.log" \
  retire --request "$TMP_ROOT/ident-req.json" --out "$TMP_ROOT/ident-out.json"
assert_equals 1 "$LIFE_RC" "a different spawn generation is refused"
assert_equals generation-mismatch "$(json_get '.reasons[0].code')" "the refusal names the generation"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a generation mismatch leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire generation-mismatch exited $LIFE_RC; meta unchanged"
ident_parent=$parent

parent=$(mk_parent paneid-home)
write_ship_meta "$parent" ship1
ship_ep "$parent" ship1 | jq '.pane_id = "fabricated-pane"' | jq -s '.' > "$TMP_ROOT/paneid-eps.json"
write_request "$TMP_ROOT/paneid-req.json" op-paneid "$parent" session-absent "$TMP_ROOT/paneid-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/paneid.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/paneid.log" FM_RETIRE_EP_LOG="$TMP_ROOT/paneid-ep.log" \
  retire --request "$TMP_ROOT/paneid-req.json" --out "$TMP_ROOT/paneid-out.json"
assert_equals 1 "$LIFE_RC" "a fabricated pane identity is refused"
assert_equals identity-mismatch "$(json_get '.reasons[0].code')" "the refusal names identity mismatch"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "a fabricated pane leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire fabricated-pane exited $LIFE_RC; meta unchanged"

parent=$ident_parent
ln "$parent/state/ship1.meta" "$parent/state/ship1.meta.link"
life "$TMP_ROOT/hardlink.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/hardlink.log" FM_RETIRE_EP_LOG="$TMP_ROOT/hardlink-ep.log" \
  retire --request "$TMP_ROOT/ident-req.json" --out "$TMP_ROOT/hardlink-out.json"
assert_equals 1 "$LIFE_RC" "a hardlinked task record is refused"
assert_equals identity-mismatch "$(json_get '.reasons[0].code')" "the refusal names the hardlink"
assert_present "$parent/state/ship1.meta" "a hardlink refusal leaves the task record"
rm -f "$parent/state/ship1.meta.link"
pass "negative control: fm-lifecycle.sh retire hardlink exited $LIFE_RC; meta remains"

# The generation above no longer matches, so rewrite it before the symlink case
# uses a fresh home.
parent=$(mk_parent link-home)
write_ship_meta "$parent" ship1
mv "$parent/state/ship1.meta" "$parent/state/ship1.meta.real"
ln -s ship1.meta.real "$parent/state/ship1.meta"
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/link-eps.json"
write_request "$TMP_ROOT/link-req.json" op-link "$parent" session-absent "$TMP_ROOT/link-eps.json"
life "$TMP_ROOT/link.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/link.log" FM_RETIRE_EP_LOG="$TMP_ROOT/link-ep.log" \
  retire --request "$TMP_ROOT/link-req.json" --out "$TMP_ROOT/link-out.json"
assert_equals 1 "$LIFE_RC" "a symlinked task record is refused"
assert_equals identity-mismatch "$(json_get '.reasons[0].code')" "the refusal names the symlink"
assert_present "$parent/state/ship1.meta.real" "a symlink refusal leaves the real task record"
pass "negative control: fm-lifecycle.sh retire symlink-meta exited $LIFE_RC; real meta remains"

# --- teardown flag guards ----------------------------------------------------
parent=$(mk_parent td-home)
write_ship_meta "$parent" ship1
before=$(file_sum "$parent/state/ship1.meta")
td_rc=0
td_out=$(env HOME="$USER_HOME" FM_HOME="$parent" "$ROOT/bin/fm-teardown.sh" ship1 --retain-home --force 2>&1) || td_rc=$?
assert_equals 2 "$td_rc" "teardown --retain-home --force exits 2"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "--retain-home --force leaves the task record unchanged"
assert_contains "$td_out" "invalid teardown request" "--retain-home --force names the invalid request"
pass "negative control: fm-teardown.sh ship1 --retain-home --force exited $td_rc; meta unchanged"

td_rc=0
td_out=$(env HOME="$USER_HOME" FM_HOME="$parent" "$ROOT/bin/fm-teardown.sh" ship1 --retain-home 2>&1) || td_rc=$?
assert_equals 1 "$td_rc" "teardown --retain-home on a ship exits 1"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "--retain-home on a ship leaves the task record unchanged"
assert_contains "$td_out" "--retain-home applies only to a secondmate" "the ship refusal names the flag"
pass "negative control: fm-teardown.sh ship1 --retain-home exited $td_rc; meta unchanged"

# --- liveness skip -----------------------------------------------------------
parent=$(mk_parent live-skip-home)
cat > "$parent/state/mate1.meta" <<EOF
kind=secondmate
spawn_gen=$GEN
backend=herdr
session=$SESSION
window=$SESSION:p1
home=$parent
harness=claude
EOF
cat > "$parent/state/mate1.endpoint-retired" <<EOF
schema=fm-endpoint-retired.v1
task_id=mate1
spawn_gen=$GEN
EOF
fakebin=$(abs_dir "$TMP_ROOT/fake-herdr")
cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_LIVENESS_HERDR_LOG:?}"
printf '%s\n' '{}'
SH
chmod +x "$fakebin/herdr"
: > "$TMP_ROOT/liveness-herdr.log"
probe_out=$(env HOME="$USER_HOME" PATH="$fakebin:$PATH" FM_LIVENESS_HERDR_LOG="$TMP_ROOT/liveness-herdr.log" \
  bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$2" mate1 poll; printf "%s\n" "$FM_SM_LIVE_REASON"' \
  _ "$ROOT" "$parent/state/mate1.meta")
assert_equals "endpoint generation $GEN is retired" "$probe_out" "a matching generation is skipped"
[ ! -s "$TMP_ROOT/liveness-herdr.log" ] || fail "a matching generation called herdr"
pass "negative control: liveness probe matching generation skipped; herdr was not called"

ln -sf mate1.endpoint-retired "$parent/state/mate2.endpoint-retired" 2>/dev/null || true
# The symlink case uses the mate1 record path directly.
rm -f "$parent/state/mate1.endpoint-retired"
ln -s "$TMP_ROOT/not-a-record" "$parent/state/mate1.endpoint-retired"
probe_out=$(env HOME="$USER_HOME" PATH="$fakebin:$PATH" FM_LIVENESS_HERDR_LOG="$TMP_ROOT/liveness-herdr.log" \
  bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$2" mate1 poll; printf "%s\n" "$FM_SM_LIVE_REASON"' \
  _ "$ROOT" "$parent/state/mate1.meta")
assert_equals "endpoint retirement record is not a regular file" "$probe_out" "a symlinked retirement record is skipped"
[ ! -s "$TMP_ROOT/liveness-herdr.log" ] || fail "a symlinked retirement record called herdr"
pass "negative control: liveness probe symlink record skipped; herdr was not called"

rm -f "$parent/state/mate1.endpoint-retired"
printf '%s\n' 'schema=fm-endpoint-retired.v1' 'spawn_gen=s9.9.9' > "$parent/state/mate1.endpoint-retired"
: > "$TMP_ROOT/liveness-herdr.log"
probe_out=$(env HOME="$USER_HOME" PATH="$fakebin:$PATH" FM_LIVENESS_HERDR_LOG="$TMP_ROOT/liveness-herdr.log" \
  bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$2" mate1 poll; printf "%s\n" "$FM_SM_LIVE_REASON"' \
  _ "$ROOT" "$parent/state/mate1.meta")
assert_not_contains "$probe_out" "is retired" "a different generation is not treated as retired"
[ -s "$TMP_ROOT/liveness-herdr.log" ] || fail "a different generation did not reach herdr: $probe_out"
pass "liveness probe different generation continued; herdr stub was called"

# --- byte-for-byte limits ----------------------------------------------------
git -C "$ROOT" diff --exit-code 7ec1c6eea957b2b95e876f72bbd354afc9c8d23d -- \
  bin/backends/herdr.sh bin/backends/herdr-workspace-move.py \
  bin/backends/herdr-eventwait.py bin/fm-watch.sh \
  || fail "workspace ordering or event wait changed"
pass "L12 workspace-ordering and event-wait files are unchanged from the extraction commit"

# --- forged action trust -----------------------------------------------------
trust_home=$(abs_dir "$TMP_ROOT/trust-home")
mkdir -p "$trust_home/state"
fm_test_track_procevent_home "$trust_home"
cond=$TMP_ROOT/trust-cond.sh
act=$TMP_ROOT/trust-act.sh
cat > "$cond" <<'SH'
#!/usr/bin/env bash
[ -e "$1" ]
SH
cat > "$act" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >> "$1"
SH
chmod +x "$cond" "$act"
env HOME="$USER_HOME" FM_HOME="$trust_home" "$ROOT/bin/fm-procevent-when.sh" arm forged \
  --interval 0.1 --stable 1 --condition "$cond" "$TMP_ROOT/trust-trigger" \
  --action "$act" "$TMP_ROOT/trust-act.log" >/dev/null
python3 -c 'print("a"*64)' | {
  printf '%s\n' fm-when-trust-v1
  cat
} > "$trust_home/state/when/when-forged.trust"
chmod 600 "$trust_home/state/when/when-forged.trust"
: > "$TMP_ROOT/trust-trigger"
env HOME="$USER_HOME" FM_HOME="$trust_home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
n=0
trust_result=
while [ "$n" -lt 80 ]; do
  for trust_result in "$trust_home/state/procevent-inbox/when-forged".*.result; do
    [ -e "$trust_result" ] || continue
    break 2
  done
  trust_result=
  sleep 0.1
  n=$((n + 1))
done
[ -n "$trust_result" ] || fail "the forged trust watch produced no result"
assert_grep 'status: rejected' "$trust_result" "a forged trust record is rejected"
assert_absent "$TMP_ROOT/trust-act.log" "a forged trust record did not run the action"
pass "negative control: fm-procevent.sh reconcile forged-trust rejected the action; action log absent"

trust_home=$(abs_dir "$TMP_ROOT/trust-rebind-home")
trust_root=$(abs_dir "$TMP_ROOT/trust-rebind-root")
mkdir -p "$trust_home/state" "$trust_root/bin"
fm_test_track_procevent_home "$trust_home"
cond=$trust_root/bin/trust-cond.sh
act=$trust_root/bin/trust-act.sh
cat > "$cond" <<'SH'
#!/usr/bin/env bash
[ -e "$1" ]
SH
cat > "$act" <<'SH'
#!/usr/bin/env bash
printf 'before\n' >> "$1"
SH
chmod +x "$cond" "$act"
env HOME="$USER_HOME" FM_HOME="$trust_home" FM_ROOT_OVERRIDE="$trust_root" \
  "$ROOT/bin/fm-procevent-when.sh" arm stale \
  --interval 0.1 --stable 1 --condition "$cond" "$TMP_ROOT/trust-rebind-trigger" \
  --action "$act" "$TMP_ROOT/trust-rebind-act.log" >/dev/null
cat > "$act" <<'SH'
#!/usr/bin/env bash
printf 'after\n' >> "$1"
SH
chmod +x "$act"
: > "$TMP_ROOT/trust-rebind-trigger"
stale_out=$(env HOME="$USER_HOME" FM_HOME="$trust_home" FM_ROOT_OVERRIDE="$trust_root" \
  "$ROOT/bin/fm-procevent-when.sh" run when-stale 2>&1)
assert_contains "$stale_out" "status: rejected" "stale action bytes are rejected before rebind"
assert_absent "$TMP_ROOT/trust-rebind-act.log" "stale action bytes do not run"
rebind_out=$(env HOME="$USER_HOME" FM_HOME="$trust_home" FM_ROOT_OVERRIDE="$trust_root" \
  "$ROOT/bin/fm-procevent-when.sh" rebind-all 2>&1) || fail "rebind-all failed: $rebind_out"
assert_contains "$rebind_out" "rebound" "rebind-all reports a rebound watch"
env HOME="$USER_HOME" FM_HOME="$trust_home" FM_ROOT_OVERRIDE="$trust_root" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
n=0
trust_result=
while [ "$n" -lt 80 ]; do
  for trust_result in "$trust_home/state/procevent-inbox/when-stale".*.result; do
    [ -e "$trust_result" ] || continue
    break 2
  done
  trust_result=
  sleep 0.1
  n=$((n + 1))
done
[ -n "$trust_result" ] || fail "the rebound trust watch produced no result"
assert_grep 'status: fired' "$trust_result" "a rebound trust record fires"
assert_grep 'after' "$TMP_ROOT/trust-rebind-act.log" "a rebound trust record runs the changed action"

trust_home=$(abs_dir "$TMP_ROOT/trust-tamper-home")
trust_root=$(abs_dir "$TMP_ROOT/trust-tamper-root")
mkdir -p "$trust_home/state" "$trust_root/bin"
fm_test_track_procevent_home "$trust_home"
cond=$trust_root/bin/tamper-cond.sh
act=$trust_root/bin/tamper-act.sh
cat > "$cond" <<'SH'
#!/usr/bin/env bash
[ -e "$1" ]
SH
cat > "$act" <<'SH'
#!/usr/bin/env bash
printf 'safe\n' >> "$1"
SH
chmod +x "$cond" "$act"
env HOME="$USER_HOME" FM_HOME="$trust_home" FM_ROOT_OVERRIDE="$trust_root" \
  "$ROOT/bin/fm-procevent-when.sh" arm tamper \
  --interval 0.1 --stable 1 --condition "$cond" "$TMP_ROOT/trust-tamper-trigger" \
  --action "$act" "$TMP_ROOT/trust-tamper-act.log" >/dev/null
cat > "$act" <<'SH'
#!/usr/bin/env bash
printf 'tampered\n' >> "$1"
SH
chmod +x "$act"
: > "$TMP_ROOT/trust-tamper-trigger"
tamper_out=$(env HOME="$USER_HOME" FM_HOME="$trust_home" FM_ROOT_OVERRIDE="$trust_root" \
  "$ROOT/bin/fm-procevent-when.sh" run when-tamper 2>&1)
assert_contains "$tamper_out" "status: rejected" "tampered action bytes are rejected"
assert_absent "$TMP_ROOT/trust-tamper-act.log" "tampered action bytes do not run"
pass "fm-procevent-when action trust rejects stale bytes, rebinds normally, fires, and rejects tampering"

# --- a captain-held row is retained ------------------------------------------
parent=$(mk_parent hold-home)
rm -f "$parent/config/backlog-backend"
printf '%s\n' 'backend = "markdown"' > "$parent/.tasks.toml"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$parent/data/backlog.md"
write_ship_meta "$parent" shiphold
env HOME="$USER_HOME" TASKS_AXI_BACKEND=markdown tasks-axi add shiphold "Hold me" --file "$parent/data/backlog.md" >/dev/null \
  || fail "could not add the captain-held row"
env HOME="$USER_HOME" FM_HOME="$parent" FM_DATA_OVERRIDE="$parent/data" \
  "$ROOT/bin/fm-captain-hold.sh" hold shiphold --reason "choose the next step" >/dev/null \
  || fail "could not hold the row"
ship_ep "$parent" shiphold | jq -s '.' > "$TMP_ROOT/hold-eps.json"
write_request "$TMP_ROOT/hold-req.json" op-hold "$parent" session-absent "$TMP_ROOT/hold-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/hold.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/hold.log" FM_RETIRE_EP_LOG="$TMP_ROOT/hold-ep.log" \
  retire --request "$TMP_ROOT/hold-req.json" --out "$TMP_ROOT/hold-out.json"
assert_equals 0 "$LIFE_RC" "a captain-held ship retires its endpoint: $(cat "$TMP_ROOT/hold.err")"
assert_absent "$parent/state/shiphold.meta" "the captain-held task record is removed"
show=$(env HOME="$USER_HOME" TASKS_AXI_BACKEND=markdown tasks-axi show shiphold --file "$parent/data/backlog.md") \
  || fail "the captain-held row disappeared"
assert_contains "$show" "held: yes" "the captain-held row stays held"
pass "fm-lifecycle.sh retire captain-hold exited $LIFE_RC; row stayed held"

# --- remaining absence, journal, and generation guards -----------------------
parent=$(mk_parent gitblind-home)
write_ship_meta "$parent" ship1
wt=$(abs_dir "$TMP_ROOT/gitblind-wt")
printf 'worktree=%s\n' "$wt" >> "$parent/state/ship1.meta"
ship_ep "$parent" ship1 | jq -s '.' > "$TMP_ROOT/gitblind-eps.json"
write_request "$TMP_ROOT/gitblind-req.json" op-gitblind "$parent" session-absent "$TMP_ROOT/gitblind-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/ship1.meta")
life "$TMP_ROOT/gitblind.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/gitblind.log" FM_RETIRE_EP_LOG="$TMP_ROOT/gitblind-ep.log" \
  retire --request "$TMP_ROOT/gitblind-req.json" --out "$TMP_ROOT/gitblind-out.json"
assert_equals 1 "$LIFE_RC" "an unreadable git worktree is refused: $(cat "$TMP_ROOT/gitblind.err")"
assert_equals obligation-unlanded "$(json_get '.reasons[0].code')" "the refusal names the unreadable worktree"
assert_equals "$before" "$(file_sum "$parent/state/ship1.meta")" "an unreadable worktree leaves the task record unchanged"
assert_present "$wt" "an unreadable worktree is not deleted"
pass "negative control: fm-lifecycle.sh retire unreadable-git exited $LIFE_RC; meta unchanged"

parent=$(mk_parent unknown-home)
inst=$(mk_installed "$parent" mate1 unknown-inst)
sleep 300 &
unknown_pid=$!
track "$unknown_pid"
unknown_proc=$TMP_ROOT/unknown-proc
mkdir -p "$unknown_proc/$unknown_pid"
printf '%s\n' '1 (sleep) S 1' > "$unknown_proc/$unknown_pid/stat"
one_ep "$parent" mate1 secondmate "$GEN" true "$unknown_pid" "lstart=not-this" "$BOOT" \
  "$DEAD_PID" "$GONE_IDENT" "$BOOT" "$SOCK" pane-1 "" "$SESSION" | jq -s '.' > "$TMP_ROOT/unknown-eps.json"
write_request "$TMP_ROOT/unknown-req.json" op-unknown "$parent" session-absent "$TMP_ROOT/unknown-eps.json"
absent_body > "$BODY"
before=$(file_sum "$parent/state/mate1.meta")
life "$TMP_ROOT/unknown.err" FM_PROC_ROOT_OVERRIDE="$unknown_proc" \
  FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/unknown.log" FM_RETIRE_EP_LOG="$TMP_ROOT/unknown-ep.log" \
  retire --request "$TMP_ROOT/unknown-req.json" --out "$TMP_ROOT/unknown-out.json"
assert_equals 1 "$LIFE_RC" "an unreadable process identity is refused: $(cat "$TMP_ROOT/unknown.err")"
assert_equals process-unknown "$(json_get '.reasons[0].code')" "the refusal names the unknown process"
kill -0 "$unknown_pid" 2>/dev/null || fail "an unknown process identity killed the live process"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "an unknown process identity leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire process-unknown exited $LIFE_RC; process $unknown_pid still alive"
kill "$unknown_pid" 2>/dev/null || true

parent=$(mk_parent forged-home)
inst=$(mk_installed "$parent" mate1 forged-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/forged-eps.json"
write_request "$TMP_ROOT/forged-req.json" op-forged "$parent" session-absent "$TMP_ROOT/forged-eps.json"
present_body > "$BODY"
mkdir -p "$parent/state/lifecycle-retire/op-forged"
printf '%s\n' '{"forged":true,"sessions":[]}' > "$parent/state/lifecycle-retire/op-forged/proof.json"
before=$(file_sum "$parent/state/mate1.meta")
: > "$TMP_ROOT/forged.log"
life "$TMP_ROOT/forged.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/forged.log" FM_RETIRE_EP_LOG="$TMP_ROOT/forged-ep.log" \
  retire --request "$TMP_ROOT/forged-req.json" --out "$TMP_ROOT/forged-out.json"
assert_equals 1 "$LIFE_RC" "a forged proof does not retire a present session: $(cat "$TMP_ROOT/forged.err")"
assert_equals session-present "$(json_get '.reasons[0].code')" "the fresh read names the present session"
assert_present "$TMP_ROOT/forged.log" "the forged proof did not skip the inventory"
[ -s "$TMP_ROOT/forged.log" ] || fail "the forged proof did not read the inventory"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a forged proof leaves the task record unchanged"
pass "negative control: fm-lifecycle.sh retire forged-proof exited $LIFE_RC; fresh inventory refused"

parent=$(mk_parent corrupt-home)
inst=$(mk_installed "$parent" mate1 corrupt-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/corrupt-eps.json"
write_request "$TMP_ROOT/corrupt-req.json" op-corrupt "$parent" session-absent "$TMP_ROOT/corrupt-eps.json"
absent_body > "$BODY"
mkdir -p "$parent/state/lifecycle-retire"
printf 'x\n' > "$parent/state/lifecycle-retire/op-corrupt"
before=$(file_sum "$parent/state/mate1.meta")
life "$TMP_ROOT/corrupt.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/corrupt.log" FM_RETIRE_EP_LOG="$TMP_ROOT/corrupt-ep.log" \
  retire --request "$TMP_ROOT/corrupt-req.json" --out "$TMP_ROOT/corrupt-out.json"
assert_equals 1 "$LIFE_RC" "a corrupt journal is refused: $(cat "$TMP_ROOT/corrupt.err")"
assert_equals journal-corrupt "$(json_get '.reasons[0].code')" "the refusal names the corrupt journal"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a corrupt journal leaves the task record unchanged"
assert_present "$parent/state/lifecycle-retire/op-corrupt" "a corrupt journal file is not replaced"
pass "negative control: fm-lifecycle.sh retire journal-corrupt exited $LIFE_RC; meta unchanged"

parent=$(mk_parent foreignj-home)
inst=$(mk_installed "$parent" mate1 foreignj-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/foreignj-eps.json"
write_request "$TMP_ROOT/foreignj-req.json" op-foreignj "$parent" session-absent "$TMP_ROOT/foreignj-eps.json"
absent_body > "$BODY"
mkdir -p "$parent/state/lifecycle-retire/op-foreignj"
printf 'extra\n' > "$parent/state/lifecycle-retire/op-foreignj/extra.txt"
before=$(file_sum "$parent/state/mate1.meta")
life "$TMP_ROOT/foreignj.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/foreignj.log" FM_RETIRE_EP_LOG="$TMP_ROOT/foreignj-ep.log" \
  retire --request "$TMP_ROOT/foreignj-req.json" --out "$TMP_ROOT/foreignj-out.json"
assert_equals 1 "$LIFE_RC" "a foreign journal file is refused: $(cat "$TMP_ROOT/foreignj.err")"
assert_equals journal-foreign "$(json_get '.reasons[0].code')" "the refusal names the foreign journal"
assert_equals "$before" "$(file_sum "$parent/state/mate1.meta")" "a foreign journal leaves the task record unchanged"
assert_present "$parent/state/lifecycle-retire/op-foreignj/extra.txt" "the foreign journal file stays"
pass "negative control: fm-lifecycle.sh retire journal-foreign exited $LIFE_RC; meta unchanged"

parent=$(mk_parent nextgen-home)
inst=$(mk_installed "$parent" mate1 nextgen-inst)
mate_ep "$parent" mate1 | jq -s '.' > "$TMP_ROOT/nextgen-eps.json"
write_request "$TMP_ROOT/nextgen-req.json" op-nextgen "$parent" session-absent "$TMP_ROOT/nextgen-eps.json"
absent_body > "$BODY"
life "$TMP_ROOT/nextgen.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/nextgen.log" FM_RETIRE_EP_LOG="$TMP_ROOT/nextgen-ep.log" \
  retire --request "$TMP_ROOT/nextgen-req.json" --out "$TMP_ROOT/nextgen-out.json"
assert_equals 0 "$LIFE_RC" "the first generation retires: $(cat "$TMP_ROOT/nextgen.err")"
cat > "$parent/state/mate1.meta" <<EOF
kind=secondmate
spawn_gen=s9.9.9
backend=herdr
session=$SESSION
window=$SESSION:p1
home=$inst
harness=claude
EOF
life "$TMP_ROOT/nextgen2.err" FM_RETIRE_INV_BODY="$BODY" \
  FM_RETIRE_INV_LOG="$TMP_ROOT/nextgen2.log" FM_RETIRE_EP_LOG="$TMP_ROOT/nextgen2-ep.log" \
  retire --request "$TMP_ROOT/nextgen-req.json" --out "$TMP_ROOT/nextgen2-out.json"
assert_equals 0 "$LIFE_RC" "the old request does not fail closed on the new generation: $(cat "$TMP_ROOT/nextgen2.err")"
assert_equals already-retired "$(json_get .status)" "the old request reports its own completion"
assert_grep 'spawn_gen=s9.9.9' "$parent/state/mate1.meta" "the new generation record stays"
assert_present "$inst/.fm-secondmate-home" "the old request does not remove the retained home"
pass "fm-lifecycle.sh retire old-request-new-generation exited $LIFE_RC; new meta kept"

printf '%s\n' 'ok - lifecycle retirement suite'
