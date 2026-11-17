#!/usr/bin/env bash
# tests/fm-watchdog-herdr-path.test.sh - which herdr the watchdog resolves under
# a boot-time PATH, and how it reports a herdr protocol mismatch.
#
# A launchd or systemd PATH such as /opt/homebrew/bin:/usr/bin:/bin omits
# ~/.local/bin, where `herdr update` installs, so the watchdog once resolved an
# older package-managed herdr and started a server the fleet could not drive.
# Every herdr here is a PATH fake that logs its calls; no case runs a real
# herdr, and the end-to-end cases keep /opt/homebrew/bin and /usr/local/bin off
# PATH so no installed herdr can be reached even if the fix regresses.
# Optional arguments select test functions; no arguments run the full suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-watchdog-herdr-path-tests)
WD="$ROOT/bin/fm-watchdog.sh"
BASE=1790000000
SYSTEM_BASH=/bin/bash

# A tools directory with jq and nothing else, for a PATH that carries no herdr.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
ln -s "$(command -v jq)" "$TOOLS/jq"

# fake_herdr <dir> <status-json> [log]: a herdr that prints <status-json> for
# `status`, refuses every other command with protocol_mismatch, and logs each
# call to <log>.
fake_herdr() {
  local dir=$1 status=$2 log=${3:-/dev/null}
  mkdir -p "$dir"
  cat > "$dir/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
case "\${1:-}" in
  status) printf '%s\n' '$status' ;;
  *) printf '%s\n' '{"error":{"code":"protocol_mismatch","message":"client and server protocols differ"}}' >&2; exit 1 ;;
esac
SH
  chmod +x "$dir/herdr"
}

user_home() {  # <name> -> a disposable HOME with an empty ~/.local/bin
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/.local/bin"
  printf '%s\n' "$h"
}

path_of() {  # <path> <home>
  bash -c '. "$1/bin/fm-watchdog-lib.sh"; fm_wd_user_bin_path "$2" "$3"' _ "$ROOT" "$1" "$2"
}

test_user_bin_path_order() {
  local h u
  h=$(user_home order)
  u=$h/.local/bin
  assert_equals "$u:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    "$(path_of /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin "$h")" "a boot PATH gains ~/.local/bin ahead of Homebrew"
  assert_equals "/usr/bin:$u:/usr/local/bin:/bin" \
    "$(path_of /usr/bin:/usr/local/bin:/bin "$h")" "the user bin goes just before /usr/local/bin"
  assert_equals "$u:/opt/homebrew/bin:/usr/bin" \
    "$(path_of "/opt/homebrew/bin:$u:/usr/bin" "$h")" "a copy after Homebrew moves ahead of it"
  assert_equals "/over:$u:/opt/homebrew/bin" \
    "$(path_of "/over:$u:/opt/homebrew/bin" "$h")" "a PATH already in order is unchanged"
  assert_equals "/over:$u:/opt/homebrew/bin" \
    "$(path_of "/over:/opt/homebrew/bin" "$h")" "a directory ahead of Homebrew keeps its place"
  assert_equals "/usr/bin:/bin:$u" \
    "$(path_of /usr/bin:/bin "$h")" "with no package directory it is appended"
  assert_equals "/opt/homebrew/bin:/bin" \
    "$(path_of /opt/homebrew/bin:/bin "$TMP_ROOT/no-such-home")" "a home with no ~/.local/bin leaves PATH alone"
  assert_equals "/opt/homebrew/bin:/bin" \
    "$(path_of /opt/homebrew/bin:/bin '')" "an empty HOME leaves PATH alone"
  pass "PATH: ~/.local/bin is placed ahead of /opt/homebrew/bin and /usr/local/bin"
}

# The watchdog itself, under the exact launchd PATH, resolves ~/.local/bin/herdr.
# On a host with Homebrew herdr installed this is a real precedence proof; a
# name lookup only, so no herdr runs.
test_watchdog_resolves_user_local_herdr() {
  local h home got
  h=$(user_home resolve)
  home="$TMP_ROOT/resolve-fm-home"
  mkdir -p "$home/state" "$home/config"
  fake_herdr "$h/.local/bin" '{}'
  got=$(env -i HOME="$h" PATH=/opt/homebrew/bin:/usr/bin:/bin FM_HOME="$home" \
    "$SYSTEM_BASH" -c '. "$1"; command -v herdr' _ "$WD") || fail "the watchdog did not load: $got"
  assert_equals "$h/.local/bin/herdr" "$got" "the watchdog resolves ~/.local/bin/herdr under a launchd PATH"
  fake_herdr "$TMP_ROOT/override" '{}'
  got=$(env -i HOME="$h" PATH="$TMP_ROOT/override:/opt/homebrew/bin:/usr/bin:/bin" FM_HOME="$home" \
    "$SYSTEM_BASH" -c '. "$1"; command -v herdr' _ "$WD") || fail "the watchdog did not load: $got"
  assert_equals "$TMP_ROOT/override/herdr" "$got" "a herdr directory placed first on PATH still wins"
  got=$(env -i HOME="$h" PATH=/opt/homebrew/bin:/usr/bin:/bin FM_HOME="$home" \
    "$SYSTEM_BASH" "$WD" render-launchd) || fail "render-launchd failed: $got"
  case "$got" in
    *"<key>PATH</key><string>$h/.local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>"*) ;;
    *) fail "the rendered launchd unit does not carry ~/.local/bin first: $got" ;;
  esac
  pass "watchdog: a launchd PATH resolves ~/.local/bin/herdr, an explicit PATH override wins, and the rendered unit carries it"
}

mismatch() {  # <path> -> output and exit status of fm_backend_herdr_client_mismatch
  env -i HOME="$TMP_ROOT" PATH="$1" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_client_mismatch fmwd-lab' _ "$ROOT"
}

test_mismatch_diagnostic() {
  local d=$TMP_ROOT/mm out rc
  local stale='{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"compatible":false,"version":"0.7.4","protocol":16}}'
  fake_herdr "$d/new" "$stale"
  rc=0; out=$(mismatch "$d/new:$TOOLS:/usr/bin:/bin") || rc=$?
  assert_equals 0 "$rc" "a stale server is reported"
  case "$out" in
    *"session 'fmwd-lab'"*"$d/new/herdr 0.8.2 (protocol 20)"*"server 0.7.4 (protocol 16)"*"stale server"*) ;;
    *) fail "the stale-server diagnostic names neither versions nor the cause: $out" ;;
  esac
  fake_herdr "$d/behind" '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"protocol":22,"version":"0.9.0"}}'
  rc=0; out=$(mismatch "$d/behind:$TOOLS:/usr/bin:/bin") || rc=$?
  assert_equals 0 "$rc" "an older client is reported"
  case "$out" in *"client is older than the server"*"herdr update"*) ;; *) fail "an older client gets no update advice: $out" ;; esac
  fake_herdr "$d/match" '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true,"compatible":true,"protocol":16}}'
  rc=0; out=$(mismatch "$d/new:$d/match:$TOOLS:/usr/bin:/bin") || rc=$?
  assert_equals "1:" "$rc:$out" "a matching second client on PATH is no mismatch"
  fake_herdr "$d/stopped" '{"client":{"version":"0.8.2","protocol":20},"server":{"running":false}}'
  rc=0; out=$(mismatch "$d/stopped:$TOOLS:/usr/bin:/bin") || rc=$?
  assert_equals "1:" "$rc:$out" "a stopped server is no mismatch"
  fake_herdr "$d/unknown" '{"client":{"version":"0.7.1"},"server":{"running":true}}'
  rc=0; out=$(mismatch "$d/unknown:$TOOLS:/usr/bin:/bin") || rc=$?
  assert_equals "1:" "$rc:$out" "an unknown verdict is no mismatch"
  pass "herdr: a protocol mismatch with no matching client gets one actionable line; a match, a stopped server, or an unknown verdict gets none"
}

# A primary home whose proving heartbeat names a herdr pane.
make_herdr_home() {  # <name> -> sets H
  local sid=00000000-0000-4000-8000-0000000000aa
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/config" "$H/data"
  printf '%s\n' "$$" > "$H/state/.lock"
  printf '%s\n' "$sid" > "$H/state/.lock-session"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
  jq -n --arg s "$sid" --argjson e "$BASE" --argjson p "$$" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"herdr",target:"fmwd-lab:p1",present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  printf 'mode=dry-run\nmodels=\nquota-guard=off\ncall-timeout-secs=10\n' > "$H/config/watchdog"
}

run_boot_wd() {  # <user-home> <args>...
  local u=$1
  shift
  env -i HOME="$u" PATH="$TOOLS:/usr/bin:/bin" FM_HOME="$H" FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER=empty FM_WD_NOW="$BASE" \
    "$SYSTEM_BASH" "$WD" "$@"
}

# End to end: under a boot PATH with no package directory, the watchdog finds
# ~/.local/bin/herdr, and a stale server's refusal is reported with its cause
# in scan output and in the status file, with no server lifecycle call.
test_watchdog_reports_herdr_mismatch() {
  local u log out
  u=$(user_home e2e)
  log="$TMP_ROOT/e2e-herdr.log"
  : > "$log"
  fake_herdr "$u/.local/bin" '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"compatible":false,"version":"0.7.4","protocol":16}}' "$log"
  make_herdr_home e2e-home
  out=$(run_boot_wd "$u" scan 2>&1) || fail "scan failed: $out"
  case "$out" in
    *"endpoint=herdr:fmwd-lab:p1"*"herdr protocol mismatch on session 'fmwd-lab'"*"stale server"*) ;;
    *) fail "scan does not report the herdr mismatch: $out" ;;
  esac
  run_boot_wd "$u" once >/dev/null 2>&1 || fail "once failed"
  assert_grep "herdr protocol mismatch on session 'fmwd-lab'" "$H/data/watchdog/status.md" \
    "the status file names the mismatch: $(cat "$H/data/watchdog/status.md" 2>&1)"
  assert_grep 'pane read p1 ' "$log" "the watchdog read the pane through ~/.local/bin/herdr: $(cat "$log")"
  ! grep -Eq '^server( |$)' "$log" || fail "the watchdog ran a herdr server command: $(cat "$log")"
  pass "watchdog: a boot PATH reaches ~/.local/bin/herdr and a stale herdr server is reported with its cause"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
else
  fm_test_run \
    test_user_bin_path_order \
    test_watchdog_resolves_user_local_herdr \
    test_mismatch_diagnostic \
    test_watchdog_reports_herdr_mismatch
fi
