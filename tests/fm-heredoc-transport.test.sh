#!/usr/bin/env bash
# tests/fm-heredoc-transport.test.sh - firstmate's bash entrypoints must feed
# here-documents and here-strings through temp files, never pipes.
#
# Bash 5.1 and later write a here-document or here-string of up to 64 KiB into
# a pipe before its reader starts. macOS cannot report a pipe's capacity, so
# when the kernel hands out small pipe buffers under memory pressure (512
# bytes was observed) that write blocks forever: the watcher, drains, sends,
# and crew-state reads hung after printing. Bash 3.2 always uses a temp file,
# and Bash 5.2 and later do too at compatibility level 50, which every bash
# script in bin/ and bin/backends/ sets at its top. Bash 5.1 ignores that level
# for here-documents, so on 5.1 alone its transport is reported and skipped;
# any later Bash that still pipes at level 50 fails.
#
# The hang itself needs host-wide pipe exhaustion that a test must never
# cause, but the transport Bash picks is deterministic, so each case runs a
# real entrypoint under every available Bash with shell functions shadowing
# common external commands. Each shadow records whether a
# here-string inside that same process reaches its reader as a pipe or a
# file, then runs the real command. Every case also carries more than 512
# bytes of real input and runs under a timeout, so a hang fails instead of
# stalling the suite.
set -u

# An inherited level would mask the scripts' own guard.
unset BASH_COMPAT

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heredoc-transport)
CASE_TIMEOUT=60

# A drain over a home that does not run the supervision host keeps its
# BRANCH OUTCOMES section out of these cases.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# More than the 512 bytes a small pipe holds, in one status-safe line.
LONG=$(printf 'heredoc-transport-%04d ' $(seq 1 40))

# Shell functions shadowing common external commands, loaded through BASH_ENV
# so every Bash process in a case - the entrypoint and each shebang child -
# defines them from a file before its script runs. (Exported functions would
# also reach children, but Bash 3.2 loses BASH_SOURCE after a script function
# calls one.) Each shadow appends "pipe" or "file", then the process's $0, for
# a here-string read under that process's own transport, then runs the real
# command.
PROBE_ENV="$TMP_ROOT/transport-probe.bash"
{
  # shellcheck disable=SC2016 # Expanded by the probed interpreter.
  printf '%s\n' 'fm_test_transport_probe() {' \
    '  { if [ -p /dev/stdin ]; then printf "pipe %s\n" "$0"; else printf "file %s\n" "$0"; fi; } <<< probe >> "$FM_TEST_TRANSPORT_LOG"' \
    '}'
  for c in cat mkdir mv rm sed awk grep tr head tail sort cut wc touch; do
    # shellcheck disable=SC2016 # Expanded by the probed interpreter.
    printf '%s() { fm_test_transport_probe; command %s "$@"; }\n' "$c" "$c"
  done
} > "$PROBE_ENV"

# Run <command...> with the shadows loaded and <interp> first on PATH as
# `bash`, so every shebang child runs under it too. Exit status is the
# command's, or 124 when it outlives CASE_TIMEOUT.
run_probed() {  # <interp> <log> <command...>
  local interp=$1 log=$2 shim
  shift 2
  shim="$TMP_ROOT/shim-$(printf '%s' "$interp" | cksum | cut -d' ' -f1)"
  mkdir -p "$shim"
  ln -sf "$interp" "$shim/bash"
  : > "$log"
  PATH="$shim:$PATH" BASH_ENV="$PROBE_ENV" FM_TEST_TRANSPORT_LOG="$log" \
    fm_run_timed "$CASE_TIMEOUT" "$@"
}

# The transport <interp> gives its own here-strings, at its default level or
# at compatibility level 50.
interp_transport() {  # <interp> [compat]
  # shellcheck disable=SC2016 # Expanded by the probed interpreter.
  "$1" -c '[ -z "$1" ] || BASH_COMPAT=$1
    { if [ -p /dev/stdin ]; then echo pipe; else echo file; fi; } <<< probe' _ "${2:-}"
}

# Fail unless <log> shows the probe ran in firstmate's own scripts, including
# the case's <entrypoint> itself, and, when CHECK_TRANSPORT is 1, never saw a
# pipe there. Fixture stand-ins such as fake tmux are not firstmate code.
assert_file_transport() {  # <log> <label> <entrypoint>
  local log=$1 label=$2 entry=$3 files pipes
  files=$(grep -cF "file $ROOT/bin/" "$log")
  pipes=$(grep -cF "pipe $ROOT/bin/" "$log")
  grep -qF " $ROOT/bin/$entry" "$log" || fail "$label: the transport probe never ran in $entry"
  [ "$CHECK_TRANSPORT" = 1 ] || return 0
  [ "$pipes" -eq 0 ] || fail "$label: $pipes of $((files + pipes)) here-strings reached their reader through a pipe, in: $(grep -F "pipe $ROOT/bin/" "$log" | sort -u | tr '\n' ' ')"
}

test_wake_drain() {  # <interp>
  local interp=$1 dir state out log rc
  dir=$(make_case "drain-$2"); state="$dir/state"; out="$dir/drain.out"; log="$dir/transport.log"
  printf 'note: bootstrap cursor line\n' > "$state/t1.status"
  FM_STATE_OVERRIDE="$state" fm_run_timed "$CASE_TIMEOUT" "$interp" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "drain under $interp: the bootstrap drain failed"
  printf 'note: %s\n' "$LONG" >> "$state/t1.status"
  printf 'note: second %s\n' "$LONG" >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" run_probed "$interp" "$log" "$interp" "$ROOT/bin/fm-wake-drain.sh" > "$out" 2>/dev/null
  rc=$?
  [ "$rc" -ne 124 ] || fail "drain under $interp: timed out after ${CASE_TIMEOUT}s"
  expect_code 0 "$rc" "drain under $interp"
  grep -F "t1 note: second $LONG" "$out" >/dev/null || fail "drain under $interp: the long unread note was not surfaced"
  assert_file_transport "$log" "drain under $interp" fm-wake-drain.sh
  pass "drain under $interp surfaces long status $TRANSPORT_NOTE"
}

test_send() {  # <interp>
  local interp=$1 dir home log rc body
  dir="$TMP_ROOT/send-$2"; home="$dir/home"; log="$dir/transport.log"
  mkdir -p "$home/state" "$dir/fakebin"
  fm_test_fake_tmux_send "$dir/fakebin"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    run_probed "$interp" "$log" "$interp" "$ROOT/bin/fm-send.sh" t1 "$LONG" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 124 ] || fail "send under $interp: timed out after ${CASE_TIMEOUT}s"
  expect_code 0 "$rc" "send under $interp"
  set -- "$home/state/t1.inbox/"*.msg
  [ "$#" -eq 1 ] && [ -f "$1" ] || fail "send under $interp: expected one inbox record, found: $*"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  body=$(fm_run_timed "$CASE_TIMEOUT" bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1")
  [ "$body" = "$LONG" ] || fail "send under $interp: the recorded body differs: $body"
  assert_file_transport "$log" "send under $interp" fm-send.sh
  pass "send under $interp records a long steer $TRANSPORT_NOTE"
}

test_watch_cycle() {  # <interp>
  local interp=$1 dir state out log rc i
  dir=$(make_case "watch-$2"); state="$dir/state"; out="$dir/watch.out"; log="$dir/transport.log"
  # Long task names push the surfaced signal list past 512 bytes.
  for i in 1 2 3 4 5 6 7 8; do
    : > "$state/task-$i-with-a-deliberately-long-name-for-the-signal-list.turn-ended"
  done
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    run_probed "$interp" "$log" "$interp" "$ROOT/bin/fm-watch.sh" > "$out" 2> "$dir/watch.err"
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher under $interp: timed out after ${CASE_TIMEOUT}s"
  expect_code 0 "$rc" "watcher under $interp: $(cat "$out" "$dir/watch.err")"
  grep '^signal: ' "$out" | grep -F "$state/task-8-with-a-deliberately-long-name-for-the-signal-list.turn-ended" >/dev/null \
    || fail "watcher under $interp: the long signal list was not surfaced: $(cat "$out")"
  assert_file_transport "$log" "watcher under $interp" fm-watch.sh
  pass "a watcher cycle under $interp surfaces a long signal list $TRANSPORT_NOTE"
}

test_crew_state() {  # <interp>
  local interp=$1 dir state wt out log rc
  dir=$(make_case "crew-state-$2"); state="$dir/state"; wt="$dir/wt"; out="$dir/crew-state.out"; log="$dir/transport.log"
  fm_git_init_commit "$wt" >/dev/null 2>&1 || fail "crew-state under $interp: fixture repo setup failed"
  fm_write_meta "$state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" "worktree=$wt"
  printf 'working: started\nnote: %s\n' "$LONG" > "$state/t1.status"
  printf 'some output\n' > "$dir/capture"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/no-mistakes"
  chmod +x "$dir/fakebin/no-mistakes"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW=sess:fm-t1 \
    FM_FAKE_TMUX_CAPTURE="$dir/capture" FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    run_probed "$interp" "$log" "$interp" "$ROOT/bin/fm-crew-state.sh" t1 > "$out" 2>/dev/null
  rc=$?
  [ "$rc" -ne 124 ] || fail "crew-state under $interp: timed out after ${CASE_TIMEOUT}s"
  expect_code 0 "$rc" "crew-state under $interp"
  grep '^state: ' "$out" >/dev/null || fail "crew-state under $interp: no state line: $(cat "$out")"
  assert_file_transport "$log" "crew-state under $interp" fm-crew-state.sh
  pass "crew-state under $interp reads a long status log $TRANSPORT_NOTE"
}

# The scripts in bin/ that print their own header as usage text. The guard
# must never show up there; add a script here when its help reads its header.
HELP_SCRIPTS=(
  fm-afk-contract.sh fm-afk-launch.sh fm-afk-return.sh fm-afk-start.sh
  fm-backlog-receive.sh fm-bearings-board.sh fm-branch-report.sh fm-brief.sh
  fm-captain-hold.sh fm-contributions.sh fm-control.sh fm-decision-hold.sh
  fm-devin-config.sh fm-dispatch-resolve.sh fm-herdr-lab.sh
  fm-home-summary-refresh.sh fm-host-mirror.sh fm-inactive-reconcile.sh
  fm-inbox.sh fm-kimi-turnend-hook.sh fm-lint-workflows.sh fm-lint.sh
  fm-live-lab.sh fm-on.sh fm-pipeline-spend.sh fm-pr-reviewers.sh
  fm-pr-state.sh fm-procevent-lavish.sh fm-procevent-quota.sh
  fm-procevent-remote-reply.sh fm-procevent-when.sh fm-procevent.sh
  fm-public-followup-collect.sh fm-public-followup-emit.sh
  fm-public-followup.sh fm-quota-choose.sh fm-remote-delta-read.sh
  fm-remote-doctor.sh fm-remote-file.sh fm-remote-herdr-guard.sh
  fm-remote-home-seed.sh fm-remote-inherit.sh fm-remote-secondmate-control.sh
  fm-remote-secondmate-relaunch.sh fm-role.sh fm-secondmate-restart.sh
  fm-session-start.sh fm-spawn.sh fm-startup-growth-check.sh
  fm-startup-memory-budget.sh fm-startup-network.sh fm-stow-cascade.sh
  fm-supervision-host.sh fm-tasks-axi.sh fm-test-isolation-proof.sh
  fm-test-run.sh
)

test_help_omits_guard() {
  local home f out rc
  home="$TMP_ROOT/help-home"
  mkdir -p "$home/state" "$home/config" "$home/tmp"
  for f in "${HELP_SCRIPTS[@]}"; do
    [ -f "$ROOT/bin/$f" ] || fail "help script bin/$f is missing"
    out=$(cd "$home" && HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" TMPDIR="$home/tmp" fm_run_timed 20 bash "$ROOT/bin/$f" --help </dev/null 2>&1)
    rc=$?
    [ "$rc" -ne 124 ] || fail "help for bin/$f timed out"
    [ -n "$out" ] || fail "help for bin/$f printed nothing"
    case "$out" in
      *BASH_COMPAT* | *"pipes here-documents"*) fail "help for bin/$f prints the compatibility guard" ;;
    esac
  done
  pass "help printed by ${#HELP_SCRIPTS[@]} scripts from their own headers never shows the compatibility guard"
}

test_help_omits_guard

n=0
piping=0
while IFS= read -r interp; do
  n=$((n + 1))
  [ "$(interp_transport "$interp")" = file ] || piping=1
  CHECK_TRANSPORT=1
  TRANSPORT_NOTE="through temp-file here-documents"
  if [ "$(interp_transport "$interp" 50)" = pipe ]; then
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    [ "$("$interp" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" = 5.1 ] \
      || fail "$interp still pipes here-documents at compatibility level 50"
    CHECK_TRANSPORT=0
    TRANSPORT_NOTE="with its transport unchecked"
    pass "SKIP (Bash 5.1 ignores compatibility level 50 for here-documents in $interp): transport assertions"
  fi
  test_wake_drain "$interp" "$n"
  test_send "$interp" "$n"
  test_watch_cycle "$interp" "$n"
  test_crew_state "$interp" "$n"
done < <(fm_test_bash_interpreters)
[ "$n" -gt 0 ] || fail "no Bash interpreter found"
[ "$piping" = 1 ] || pass "SKIP (no Bash here pipes here-documents by default): the old hang cannot be reproduced on this host"
