#!/usr/bin/env bash
# Behavioral coverage for bin/fm-memory-guard.sh: the macOS and Linux readers,
# the sustained window, the swap alarm and its deduplication, the bounded
# sample log, observe as the default, the reap-scratch allowlist that
# spares live agents, supervisors, multiplexers, and desktop apps, and the
# stop-scratch stop of a real scratch process.
# ps and sysctl are PATH fakes that print fixture tables; every process a
# fixture row names is a real sleep this suite started, so a test can prove
# the guard left it running. The stop cases use the real ps and the real
# clock instead, with the table cut down to processes this suite started.
# Optional arguments select test functions; no arguments run the full suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
BASE_PATH_FIRST=${BASE_PATH%%:*}
TMP_ROOT=$(fm_test_tmproot fm-memory-guard)
GUARD="$ROOT/bin/fm-memory-guard.sh"
FAKE=$(fm_fakebin "$TMP_ROOT")
MYUID=$(id -u)
NOW0=1800000000
OUT=
RC=0
H=
CASE_N=0
SLEEPS=''
# One row per holder this suite starts: pid, then its hold_identity.
HOLDS_FILE="$TMP_ROOT/holds.tsv"
# reap_fixture sets one P_<name> per fixture row; these are the ones read by name.
D_runner='' D_testscript='' D_bareopt='' D_barename='' D_bunrun='' D_runner4='' P_runner='' P_claude='' P_wrapped='' P_exe='' P_nodeagent='' P_execd='' P_reused='' P_moved='' P_padded=''

# Fixture programs under the temp root are real files, as a scratch program must be.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/live/bin" "$TMP_ROOT/work dir" "$TMP_ROOT/job" "$TMP_ROOT/claude-code"
for f in runaway.sh grow.pl leak.js wrap.sh wrap2.sh foreign.sh turns.sh again.sh first.sh second.sh a.sh bootstrap.js bin/leaky live/bin/fm-watchdog.sh job/work claude-code/cli.js; do
  : > "$TMP_ROOT/$f"
done
# Checkout-like fixtures live outside every disposable temp root, so none of
# them, or of the processes started from them, may ever be named as scratch.
OUT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/memory-guard-outside.XXXXXX")
mkdir -p "$OUT_ROOT/repo/tests" "$OUT_ROOT/tests" "$OUT_ROOT/bin" "$OUT_ROOT/claude-code/tests"
for f in repo/tests/fm-example.test.sh repo/tests/ui.test.sh repo/helper.sh tests/service.test.sh "tests/service.test.sh live.sh" bin/fm-watchdog.sh claude-code/cli.py claude-code/tests/ui.test.sh; do
  : > "$OUT_ROOT/$f"
done
ln -s "$OUT_ROOT/bin/fm-watchdog.sh" "$OUT_ROOT/run-loop.sh"
ln -s "$OUT_ROOT/claude-code" "$OUT_ROOT/pkg2"

cat > "$FAKE/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_PS_LOG"
case "$*" in
  *'-p '*) PATH=$FM_FAKE_BASE_PATH exec ps "$@" ;;
esac
case "${FM_FAKE_PS_MODE:-ok}" in
  ok) ;;
  live)
    # The real table, cut down to the pids this suite listed.
    PATH=$FM_FAKE_BASE_PATH ps "$@" | awk -v f="$FM_FAKE_PS_DIR/allow" 'BEGIN { while ((getline l < f) > 0) a[l] = 1 } ($1 in a)'
    exit 0 ;;
  *) exit 1 ;;
esac
case "$*" in
  *comm=*) cat "$FM_FAKE_PS_DIR/comm" ;;
  *)
    cat "$FM_FAKE_PS_DIR/table"
    # A slow read: the test clock moves on while the table is read.
    if [ -n "${FM_FAKE_PS_ADVANCE:-}" ] && [ -n "${FM_FAKE_CLOCK:-}" ]; then
      c=$(head -n 1 "$FM_FAKE_CLOCK")
      printf '%s\n' "$((c + FM_FAKE_PS_ADVANCE))" > "$FM_FAKE_CLOCK"
    fi ;;
esac
SH
cat > "$FAKE/sysctl" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_SWAP_MODE:-ok}" = ok ] || exit 1
printf 'total = 32768.00M  used = %s  free = 1.00M  (encrypted)\n' "$FM_FAKE_SWAP_USED"
SH
chmod +x "$FAKE/ps" "$FAKE/sysctl"

# hold_identity <pid>: that pid's start time and command line, read with the
# system ps so the fake ps on PATH cannot answer; empty once the pid is gone.
hold_identity() { command -p ps -o lstart= -o args= -p "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# kill_owned_holds <record>: KILL each recorded holder only while its pid still
# names the process this suite started (same start time and command line). A
# stopped holder's pid can be reused on a busy host, and KILL must never reach
# the unrelated process that now holds it.
kill_owned_holds() {
  local pid ident
  [ -f "$1" ] || return 0
  while IFS=$'\t' read -r pid ident; do
    [ -n "$pid" ] && [ -n "$ident" ] || continue
    [ "$(hold_identity "$pid")" = "$ident" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done < "$1"
}

cleanup_sleeps() {
  local p
  for p in $SLEEPS; do kill "$p" 2>/dev/null || true; done
  # A holder can ignore TERM, so a failed stop case must not leave one behind.
  kill_owned_holds "$HOLDS_FILE"
  # A holder's own child is not in SLEEPS when a case fails early.
  for p in "$TMP_ROOT"/stopme/*.kid; do
    [ -f "$p" ] || continue
    kill "$(cat "$p")" 2>/dev/null || true
  done
  rm -rf "$OUT_ROOT"
  fm_test_cleanup
}
trap cleanup_sleeps EXIT

new_home() {  # [config-lines]
  CASE_N=$((CASE_N + 1))
  H="$TMP_ROOT/home$CASE_N"
  mkdir -p "$H/state" "$H/config" "$H/ps"
  : > "$H/ps/table"
  : > "$H/ps/comm"
  : > "$H/ps.log"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$H/config/memory-guard"
  SWAP_USED=0.00M
}

# etime_of <secs>: [[dd-]hh:]mm:ss as ps prints it.
etime_of() {
  local s=$1 d h m
  d=$((s / 86400)); s=$((s % 86400)); h=$((s / 3600)); s=$((s % 3600)); m=$((s / 60)); s=$((s % 60))
  if [ "$d" -gt 0 ]; then printf '%02d-%02d:%02d:%02d' "$d" "$h" "$m" "$s"
  elif [ "$h" -gt 0 ]; then printf '%02d:%02d:%02d' "$h" "$m" "$s"
  else printf '%02d:%02d' "$m" "$s"
  fi
}

# proc <pid> <uid> <ppid> <rss-mb> <age-secs> <comm> <args>: one fixture
# process, right-aligned like real ps output, with comm on its own table.
proc() {
  printf '%5s %5s %5s %5s %8s %11s %s\n' "$1" "$2" "$3" "$1" "$(( $4 * 1024 ))" "$(etime_of "$5")" "$7" >> "$H/ps/table"
  printf '%5s %s\n' "$1" "$6" >> "$H/ps/comm"
}

guard() {  # <now> [check args...]
  local now=$1
  shift
  RC=0
  OUT=$(PATH="$FAKE:$BASE_PATH" FM_FAKE_BASE_PATH="$BASE_PATH" FM_FAKE_PS_DIR="$H/ps" FM_FAKE_PS_LOG="$H/ps.log" \
    FM_FAKE_PS_MODE="${PS_MODE:-ok}" FM_FAKE_SWAP_MODE="${SWAP_MODE:-ok}" FM_FAKE_SWAP_USED="$SWAP_USED" \
    FM_FAKE_CLOCK="${CLOCK_FILE:-}" FM_FAKE_PS_ADVANCE="${PS_ADVANCE:-}" \
    FM_TEST_SEAM=1 FM_HOME="$H" FM_MEMORY_GUARD_NOW="$now" FM_MEMORY_GUARD_OS="${OS:-Darwin}" \
    FM_MEMORY_GUARD_CLOCK="${CLOCK_FILE:-}" FM_MEMORY_GUARD_ELAPSED="${ELAPSED:-}" \
    FM_MEMORY_GUARD_MEMINFO="$H/meminfo" "$GUARD" check "$@" 2>&1) || RC=$?
}

# guard_slow <now> <read-secs>: one pass whose process read takes <read-secs>
# on the test clock.
guard_slow() {
  printf '%s\n' "$1" > "$H/clock"
  CLOCK_FILE=$H/clock PS_ADVANCE=$2 guard "$1"
}

# guard_live [check args...]: one pass on the real clock and the real ps,
# which shows only the pids listed in $H/ps/allow. No test seam is set.
guard_live() {
  RC=0
  OUT=$(PATH="$FAKE:$BASE_PATH" FM_FAKE_BASE_PATH="$BASE_PATH" FM_FAKE_PS_DIR="$H/ps" FM_FAKE_PS_LOG="$H/ps.log" \
    FM_FAKE_PS_MODE=live FM_FAKE_SWAP_USED=0.00M FM_HOME="$H" "$GUARD" check "$@" 2>&1) || RC=$?
}

# guard_live_stop: guard_live for a pass that must reach its stops. On a
# loaded host a pass can use up the 15 s stop-start budget and defer a stop;
# such a pass is run again, a bounded number of times, and the case fails when
# the last attempt still deferred. A pass may stop one process and defer the
# next, so OUT keeps every attempt's output and RC is the last attempt's. The
# stop cases set alarm_repeat_secs=1, so a retry prints its alarms again.
guard_live_stop() {
  local attempt all=''
  for attempt in 1 2 3 4 5; do
    guard_live
    all="$all${all:+$'\n'}$OUT"
    printf '%s\n' "$OUT" | grep '^memory-guard: status=' | sed -n 's/.* action=//p' | tr ',' '\n' | grep -q '^stop-deferred:' || { OUT=$all; return 0; }
  done
  OUT=$all
  fail "the last of $attempt passes still deferred a stop (the pass had no time left): $OUT"
}

# summary: the status line of each pass in OUT (one, except after a retry).
summary() { printf '%s\n' "$OUT" | grep '^memory-guard: status='; }
alarms() { printf '%s\n' "$OUT" | grep -c '^MEMORY_GUARD_ALARM: ' | tr -d ' '; }
# action_has <token>: an action list in the summary holds exactly that token.
action_has() { summary | sed -n 's/.* action=//p' | tr ',' '\n' | grep -Fxq -- "$1"; }

start_sleep() {  # [cwd] -> pid of a real, detached sleep this suite owns
  local f="$TMP_ROOT/sleep.$RANDOM.pid"
  ( cd "${1:-$TMP_ROOT}" || exit 1; sleep 100000 >/dev/null 2>&1 & printf '%s\n' "$!" > "$f" )
  SLEEP_PID=$(cat "$f")
  SLEEPS="$SLEEPS $SLEEP_PID"
}

# A holder wait that lets a TERM trap run at once on every bash: a read with
# a timeout on a fifo this holder holds open itself, so it never has a child.
# shellcheck disable=SC2016 # the holder expands these, not this suite
TRAP_WAIT='exec 3<>"$0.fifo"; while :; do read -r -t 1 _ <&3; done'
# shellcheck disable=SC2016 # the holder expands these, not this suite
PLAIN_WAIT='read -r _ < "$0.fifo"'

# start_hold <script-path> [first-line] [wait-line] -> HOLD_PID: a real bash
# this suite owns that runs <script-path>, holds a few MB, has no child of
# its own, and waits on a fifo nothing writes to. [first-line] runs before it
# waits, and [wait-line] replaces the wait.
start_hold() {
  local script=$1 i
  mkdir -p "${script%/*}"
  rm -f "$script.fifo" "$script.ready"
  mkfifo "$script.fifo"
  # shellcheck disable=SC2016 # the holder expands these, not this suite
  printf '%s\n' "${2:-:}" 'printf -v pad "%*s" 4000000 ""' ': > "$0.ready"' "${3:-$PLAIN_WAIT}" > "$script"
  ( cd "$TMP_ROOT" || exit 1; bash "$script" >/dev/null 2>&1 & printf '%s\n' "$!" > "$script.pid" )
  HOLD_PID=$(cat "$script.pid")
  # Record the identity once the holder runs its script, not while it may
  # still be the forked subshell that has not yet exec'd bash.
  for i in $(seq 1 50); do
    [ ! -e "$script.ready" ] || break
    sleep 0.1
  done
  printf '%s\t%s\n' "$HOLD_PID" "$(hold_identity "$HOLD_PID")" >> "$HOLDS_FILE"
  [ -e "$script.ready" ] || fail "the holder $script did not start"
}

alive() { kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -q '^Z'; }

wait_gone() {  # <pid>
  local i
  for i in $(seq 1 50); do
    alive "$1" || return 0
    sleep 0.1
  done
  return 1
}

# stop_rows <pid>: that pid's rows in the stop record, as "event detail" lines.
stop_rows() { awk -F'\t' -v p="$1" '$2 == p { print $5 " " $6 }' "${2:-$H/state/memory-guard-stops.tsv}" 2>/dev/null; }

test_help_and_usage() {
  new_home
  RC=0
  OUT=$(FM_HOME="$H" "$GUARD" --help 2>&1) || RC=$?
  assert_equals 0 "$RC" "--help exits 0"
  assert_contains "$OUT" "fm-memory-guard.sh check [--json] [--observe]" "--help prints the usage"
  RC=0
  OUT=$(FM_HOME="$H" "$GUARD" check --bogus 2>&1) || RC=$?
  assert_equals 2 "$RC" "an unknown flag is a usage error"
  RC=0
  OUT=$(FM_HOME="$H" "$GUARD" 2>&1) || RC=$?
  assert_equals 2 "$RC" "a missing command is a usage error"
  assert_absent "$H/state/memory-guard.tsv" "a usage error records no sample"
  pass "help and usage errors take no sample"
}

test_macos_reader() {
  new_home
  SWAP_USED=17000.50M
  proc 1 0 0 30 400000 launchd /sbin/launchd
  proc 4242 "$MYUID" 1 9000 93784 'Google Chrome Helper (Renderer)' '/Applications/Google Chrome.app/Contents/Frameworks/Helper --type=renderer'
  proc 77 "$MYUID" 1 12 306 bash 'bash -c echo hi'
  guard "$NOW0"
  assert_equals 3 "$RC" "swap over the limit exits 3: $OUT"
  assert_contains "$(summary)" "status=alarm swap_used_mb=17000 top_pid=4242 top_rss_mb=9000 top_comm=Google_Chrome_Helper_(Renderer) mode=observe action=none" "macOS summary"
  assert_contains "$OUT" "MEMORY_GUARD_ALARM: swap used 17000 MB is at or over 16384 MB; the largest process is pid 4242 (Google Chrome Helper (Renderer)) at 9000 MB" "swap alarm line"
  assert_grep '-axo pid=,uid=,ppid=,pgid=,rss=,etime=,args=' "$H/ps.log" "macOS reads every process with -axo"
  assert_equals "$NOW0	17000	4242	9000	Google Chrome Helper (Renderer)	alarm	none" "$(cat "$H/state/memory-guard.tsv")" "sample row"
  new_home
  SWAP_USED=17.50G
  proc 5 "$MYUID" 1 10 5 sh sh
  guard "$NOW0"
  assert_contains "$(summary)" "swap_used_mb=17920 " "a gigabyte swap reading converts to MB"
  assert_contains "$(summary)" "status=alarm" "17920 MB is over the default limit"
  pass "the macOS reader parses swap, etime, and comm with spaces"
}

test_linux_reader() {
  new_home
  OS=Linux
  printf 'MemTotal:       65000000 kB\nSwapTotal:       8388608 kB\nSwapFree:        4194304 kB\n' > "$H/meminfo"
  proc 1 0 0 10 400000 systemd /sbin/init
  proc 900 "$MYUID" 1 2048 7200 python3 'python3 /srv/app.py'
  guard "$NOW0"
  OS=
  assert_equals 0 "$RC" "Linux under every limit exits 0: $OUT"
  assert_contains "$(summary)" "status=ok swap_used_mb=4096 top_pid=900 top_rss_mb=2048 top_comm=python3" "Linux summary"
  assert_grep '-eo pid=,uid=,ppid=,pgid=,rss=,etime=,args=' "$H/ps.log" "Linux reads every process with -eo"
  new_home
  OS=Linux
  printf 'MemTotal: 1 kB\n' > "$H/meminfo"
  proc 7 "$MYUID" 1 10 5 sh sh
  guard "$NOW0"
  OS=
  assert_equals 0 "$RC" "a meminfo without swap rows still samples the processes"
  assert_contains "$(summary)" "swap_used_mb=unknown " "missing swap rows read as unknown"
  pass "the Linux reader parses /proc/meminfo and ps -eo"
}

test_unreadable_sources() {
  new_home
  SWAP_MODE=fail PS_MODE=fail guard "$NOW0"
  assert_equals 1 "$RC" "both reads failing exits 1"
  assert_contains "$(summary)" "status=unreadable swap_used_mb=unknown top_pid=- " "unreadable summary"
  assert_contains "$OUT" "memory-guard: swap could not be read on Darwin" "swap failure note"
  assert_contains "$OUT" "memory-guard: the process table could not be read" "process failure note"
  assert_contains "$(cat "$H/state/memory-guard.tsv")" "unknown	-	-	-	unreadable	none" "an unreadable pass is still recorded"
  new_home
  SWAP_USED=10.00M PS_MODE=fail guard "$NOW0"
  assert_equals 1 "$RC" "a failed process read alone exits 1, so the loss of process watching is visible"
  assert_contains "$(summary)" "status=ok swap_used_mb=10 top_pid=- " "the swap reading still stands"
  pass "a failed read is reported and recorded, never guessed"
}

test_sustained_window() {
  local start=$((NOW0 - 5000)) big=9000
  new_home
  at() { : > "$H/ps/table"; : > "$H/ps/comm"; proc 1 0 0 10 400000 launchd /sbin/launchd
    proc 4242 "$MYUID" 1 "$2" $(( $1 - ${3:-$start} )) node 'node /srv/build.js'; guard "$1"; }
  at "$NOW0" "$big"
  assert_equals 0 "$RC" "a new large process is watched, not an alarm: $OUT"
  assert_contains "$(summary)" "status=watch" "first sight is watch"
  at $((NOW0 + 600)) "$big"
  assert_contains "$(summary)" "status=watch" "600 s is under the window"
  assert_equals 0 "$(alarms)" "no alarm inside the window"
  at $((NOW0 + 900)) "$big"
  assert_equals 3 "$RC" "a 900 s hold is an alarm"
  assert_contains "$OUT" "MEMORY_GUARD_ALARM: pid 4242 (node) has held 9000 MB, at or over 8192 MB, for 900 s (limit 900 s). Mode observe: nothing was stopped." "sustained alarm line"
  at $((NOW0 + 1020)) "$big"
  assert_contains "$(summary)" "status=alarm" "the alarm stays in force"
  assert_equals 0 "$(alarms)" "an alarm in force is not printed again"
  local t
  for t in 1320 1620 1920 2220 2520 2820 3120 3420 3720 4020 4320; do
    at $((NOW0 + t)) "$big"
    assert_equals 0 "$(alarms)" "no repeat inside alarm_repeat_secs at +$t"
  done
  at $((NOW0 + 900 + 3600)) "$big"
  assert_equals 1 "$(alarms)" "the alarm repeats after alarm_repeat_secs"
  at $((NOW0 + 4620)) 100
  assert_contains "$(summary)" "status=ok" "a process under the limit clears the watch"
  at $((NOW0 + 4740)) "$big"
  assert_contains "$(summary)" "status=watch" "dropping under the limit restarts the window"
  at $((NOW0 + 5700)) "$big"
  assert_contains "$(summary)" "status=watch" "a sample gap over 600 s restarts the window"
  at $((NOW0 + 6000)) "$big" $((NOW0 + 5990))
  assert_contains "$(summary)" "status=watch" "a reused pid with a new start time restarts the window"
  at $((NOW0 + 6300)) "$big" $((NOW0 + 5990))
  at $((NOW0 + 6600)) "$big" $((NOW0 + 5990))
  assert_equals 0 "$(alarms)" "the new process is still inside its window"
  at $((NOW0 + 6900)) "$big" $((NOW0 + 5990))
  assert_equals 1 "$(alarms)" "the new process alarms after its own full window"
  pass "a process alarms only after holding the limit for the whole window"
}

test_swap_threshold_and_config() {
  new_home
  proc 5 "$MYUID" 1 10 5 sh sh
  SWAP_USED=16383.99M
  guard "$NOW0"
  assert_contains "$(summary)" "status=ok swap_used_mb=16383 " "just under the swap limit is ok"
  SWAP_USED=16384.00M
  guard $((NOW0 + 120))
  assert_equals 3 "$RC" "exactly the swap limit is an alarm"
  assert_equals 1 "$(alarms)" "the swap alarm prints once"
  guard $((NOW0 + 240))
  assert_equals 0 "$(alarms)" "the swap alarm is deduplicated"
  SWAP_USED=10.00M
  guard $((NOW0 + 360))
  assert_contains "$(summary)" "status=ok" "swap under the limit clears"
  SWAP_USED=16384.00M
  guard $((NOW0 + 480))
  assert_equals 1 "$(alarms)" "a cleared alarm prints again when it returns"
  new_home $'# local limits\nswap_warn_mb=100\nswap_warn_mb=1000\nproc_rss_mb=abc\nmode=kill'
  proc 5 "$MYUID" 1 9000 5 sh sh
  SWAP_USED=999.00M
  guard "$NOW0"
  assert_contains "$(summary)" "status=watch swap_used_mb=999 " "the last swap_warn_mb wins and a bad proc_rss_mb keeps 8192"
  assert_contains "$OUT" "memory-guard: config: proc_rss_mb=abc is not a positive integer; using 8192" "bad number note"
  assert_contains "$OUT" "memory-guard: config: mode=kill is not observe, reap-scratch, or stop-scratch; using observe" "bad mode note"
  assert_contains "$(summary)" "mode=observe" "an unknown mode is observe"
  pass "the swap limit is inclusive, deduplicated, and configurable"
}

test_log_is_bounded() {
  local i
  new_home 'log_max_rows=5'
  proc 5 "$MYUID" 1 10 5 sh sh
  for i in 1 2 3 4 5 6 7 8; do guard $((NOW0 + i)); done
  assert_equals 5 "$(wc -l < "$H/state/memory-guard.tsv" | tr -d ' ')" "the log keeps log_max_rows rows"
  assert_equals $((NOW0 + 4)) "$(head -n 1 "$H/state/memory-guard.tsv" | cut -f 1)" "the oldest rows are dropped"
  assert_equals $((NOW0 + 8)) "$(tail -n 1 "$H/state/memory-guard.tsv" | cut -f 1)" "the newest row is kept"
  new_home
  proc 5 "$MYUID" 1 10 5 sh sh
  for i in 1 2 3; do guard $((NOW0 + i)); done
  assert_equals 3 "$(wc -l < "$H/state/memory-guard.tsv" | tr -d ' ')" "the default cap leaves a short log alone"
  pass "the sample log stays bounded"
}

test_alarm_survives_a_failed_record() {
  new_home 'swap_warn_mb=5'
  SWAP_USED=7.00M
  mkdir "$H/state/memory-guard.tsv"
  guard "$NOW0"
  assert_equals 3 "$RC" "an alarm still exits 3 when the sample cannot be recorded"
  assert_contains "$OUT" "MEMORY_GUARD_ALARM: swap used 7 MB" "the alarm line is still printed"
  assert_contains "$OUT" "cannot record the sample" "the record failure is reported"
  new_home 'swap_warn_mb=999999'
  mkdir "$H/state/memory-guard.tsv"
  guard "$NOW0"
  assert_equals 1 "$RC" "a record failure with no alarm exits 1"
  pass "an alarm is never hidden by a sample that cannot be recorded"
}

test_state_save_failure_exits_1() {
  if [ "$MYUID" = 0 ]; then
    pass "a state save failure exits 1 (skipped: root ignores directory permissions)"
    return 0
  fi
  new_home 'swap_warn_mb=999999'
  proc 4242 "$MYUID" 1 9000 60 node 'node /srv/build.js'
  guard "$NOW0"
  assert_equals 0 "$RC" "the first sample is recorded: $OUT"
  # The sample log stays appendable while the state directory refuses the
  # renames that save the sustained-process and alarm state.
  chmod 500 "$H/state"
  guard $((NOW0 + 60))
  chmod 700 "$H/state"
  assert_contains "$OUT" "cannot write $H/state/memory-guard-seen.tsv" "the failed save is reported"
  assert_equals 2 "$(wc -l < "$H/state/memory-guard.tsv" | tr -d ' ')" "the sample itself was still recorded"
  assert_equals 1 "$RC" "a pass that cannot save its state exits 1"
  pass "a pass that cannot save its sustained-process or alarm state exits 1"
}

test_json_output() {
  command -v jq >/dev/null 2>&1 || { pass "json output (skip: jq not found)"; return 0; }
  new_home
  SWAP_USED=20000.00M
  proc 4242 "$MYUID" 1 9000 5 'say "hi"' 'say "hi"'
  guard "$NOW0" --json
  assert_equals 3 "$RC" "json keeps the exit status"
  assert_equals alarm "$(printf '%s' "$OUT" | jq -r .status)" "json status"
  assert_equals 20000 "$(printf '%s' "$OUT" | jq -r .swap_used_mb)" "json swap"
  assert_equals 'say "hi"' "$(printf '%s' "$OUT" | jq -r .top.comm)" "json escapes quotes"
  assert_equals 1 "$(printf '%s' "$OUT" | jq '.alarms | length')" "json alarm list"
  pass "--json prints one valid object"
}

# One sustained 9000 MB process per row, each a real sleep, judged twice
# 900 s apart. Sets P_<name> to the real pid of each.
reap_fixture() {
  local name args comm uid parent
  : > "$H/ps/table"; : > "$H/ps/comm"
  proc 1 0 0 10 400000 launchd /sbin/launchd
  while IFS='|' read -r name comm uid parent args; do
    [ -n "$name" ] || continue
    eval "pid=\${P_$name:-}"
    if [ -z "$pid" ]; then eval "start_sleep \"\${D_$name:-}\""; pid=$SLEEP_PID; eval "P_$name=$pid"; fi
    case "$parent" in P_*) eval "parent=\$$parent" ;; esac
    [ "$uid" != me ] || uid=$MYUID
    proc "$pid" "$uid" "$parent" "${RSS:-9000}" $(( ${CLOCK:-$NOW0} - NOW0 + 5000 )) "$comm" "$args"
  done <<EOF
$REAP_ROWS
EOF
}

# sustain [check args...]: judge the REAP_ROWS fixture every 300 s from NOW0
# to NOW0 + 900, so each row holds its RSS for the whole default window.
sustain() {
  local t
  for t in 0 300 600 900; do
    CLOCK=$((NOW0 + t)) reap_fixture
    [ -z "${RUNNER_SMALL:-}" ] || { awk -v p="$P_runner" '$1 == p { $5 = 1024 } { print }' "$H/ps/table" > "$H/ps/t" && mv "$H/ps/t" "$H/ps/table"; }
    guard $((NOW0 + t)) "$@"
  done
}

test_observe_default_never_signals() {
  new_home
  REAP_ROWS="scratch|bash|me|1|bash $TMP_ROOT/runaway.sh"
  P_scratch=
  sustain
  assert_equals 3 "$RC" "a sustained process alarms"
  assert_contains "$OUT" "Mode observe: nothing was stopped." "observe says nothing was stopped"
  assert_contains "$(summary)" "action=none" "observe takes no action"
  alive "$P_scratch" || fail "observe mode signaled a scratch process"
  ! grep -q 'ppid= -p' "$H/ps.log" || fail "observe mode ran the reap-scratch classification"
  new_home 'mode=reap-scratch'
  sustain --observe
  assert_contains "$(summary)" "mode=observe action=none" "--observe overrides reap-scratch"
  alive "$P_scratch" || fail "--observe signaled a scratch process"
  ! grep -q 'ppid= -p' "$H/ps.log" || fail "--observe ran the reap-scratch classification"
  pass "observe is the default, does no classification work, and --observe always wins"
}

# agents_fixture: one scratch process, one scratch node program, and every
# kind of live agent, supervisor, multiplexer, and operator process.
AGENT_NAMES='runner testchild testscript claude codex agy tmux orca nodeout app watch plain other wrapper wrapped'
agents_fixture() {
  local name
  for name in scratch runner testchild testscript nodetmp claude codex agy tmux orca nodeout app watch plain other wrapper wrapped; do eval "P_$name="; done
  # shellcheck disable=SC2034 # read by reap_fixture through eval
  D_runner=$OUT_ROOT/repo D_testscript=$OUT_ROOT/repo
  REAP_ROWS="scratch|bash|me|1|bash $TMP_ROOT/runaway.sh
runner|bash|me|1|bash $OUT_ROOT/repo/tests/fm-example.test.sh
testchild|sleep|me|P_runner|sleep 5
testscript|bash|me|P_runner|bash ./helper.sh
nodetmp|node|me|1|node $TMP_ROOT/leak.js
claude|claude|me|1|claude --print $TMP_ROOT/x
codex|exec-helper|me|1|/opt/homebrew/bin/codex exec $TMP_ROOT/y
agy|agy|me|1|agy -p hello
tmux|tmux|me|1|tmux -L fm-test-$CASE_N new-session $TMP_ROOT/z
orca|orca|me|1|orca serve
nodeout|node|me|1|node /srv/server.js
app|Preview Helper|me|1|/Applications/Preview.app/Contents/MacOS/Preview Helper $TMP_ROOT/w
watch|bash|me|1|bash /opt/firstmate/bin/fm-watch.sh
plain|python3|me|1|python3 /srv/big.py
other|bash|0|1|bash $TMP_ROOT/foreign.sh
wrapper|bash|me|1|bash $TMP_ROOT/wrap.sh
wrapped|claude|me|P_wrapper|claude"
}

test_reap_scratch_spares_live_agents_and_operator_apps() {
  local name
  new_home 'mode=reap-scratch'
  agents_fixture
  # The test runner itself stays small, so only its child is a candidate.
  RUNNER_SMALL=1 sustain
  assert_equals 3 "$RC" "reap pass alarms: $OUT"
  for name in scratch nodetmp; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "scratch process $name (pid $pid) was signaled: $OUT"
    action_has "would-stop:$pid" || fail "action does not name $name as would-stop: $(summary)"
  done
  for name in $AGENT_NAMES; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "protected process $name (pid $pid) was signaled: $OUT"
    ! action_has "would-stop:$pid" || fail "$name was named as would-stop: $(summary)"
    action_has "spared:$pid" || [ "$name" = runner ] || fail "action does not name the spared $name: $(summary)"
  done
  assert_contains "$OUT" "pid $P_claude (claude) has held" "a protected agent still alarms"
  assert_contains "$OUT" "spared (protected claude)" "an agent harness is protected by name"
  assert_contains "$OUT" "spared (protected codex)" "an agent harness is protected by its argv[0] path"
  assert_contains "$OUT" "spared (protected tmux)" "a multiplexer is protected even in a temp root"
  assert_contains "$OUT" "spared (node outside a disposable temp root)" "node outside a temp root is protected"
  assert_contains "$OUT" "spared (desktop app)" "an app bundle is protected"
  assert_contains "$OUT" "spared (firstmate supervisor script)" "a supervisor script is protected"
  assert_contains "$OUT" "spared (not scratch)" "an ordinary large process is not scratch"
  assert_contains "$OUT" "spared (another user)" "another user's process is never signaled"
  assert_contains "$OUT" "spared (ancestor of protected pid $P_wrapped)" "the parent of a live agent is protected"
  assert_contains "$OUT" "disposable scratch that would be stopped; this mode never signals, so nothing was stopped." "a scratch alarm says it would be stopped and was not"
  pass "reap-scratch names only scratch processes as would-stop and spares every live agent and operator process"
}

test_reap_scratch_needs_a_scratch_program() {
  local name
  new_home 'mode=reap-scratch'
  for name in exe nodeagent watchtmp prodlog dotdot inline preload livewatch prodlink runner brave renderer mailer nmd gimp spaced missing linkfile spacewrap pkgagent relsup agent2 agentkid symkid pkgkid runner2 fakekid pkgwrap pkgwrapkid noname runner3 aliaskid errexit inlinepath bareopt barename bunrun ddkid meld caseup runner4 relkid hardlink; do eval "P_$name="; done
  ln -s "$BASE_PATH_FIRST" "$TMP_ROOT/prodlink"
  ln -s "$TMP_ROOT/runaway.sh" "$TMP_ROOT/link.sh"
  ln -s "$BASE_PATH_FIRST" "$TMP_ROOT/job/work dir"
  ln -s "$TMP_ROOT/claude-code" "$TMP_ROOT/pkg"
  ln "$OUT_ROOT/claude-code/cli.py" "$TMP_ROOT/hard.js"
  # shellcheck disable=SC2034 # read by reap_fixture through eval
  D_runner=$OUT_ROOT/repo D_bareopt=$OUT_ROOT D_barename=$OUT_ROOT/repo D_bunrun=$OUT_ROOT/repo D_runner4=$OUT_ROOT/repo
  REAP_ROWS="exe|leaky|me|1|$TMP_ROOT/bin/leaky --size 9
nodeagent|node|me|1|node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js --add-dir $TMP_ROOT/p
watchtmp|bash|me|1|bash /opt/firstmate/bin/fm-watch.sh --state $TMP_ROOT/home
prodlog|python3|me|1|python3 /srv/production.py --log $TMP_ROOT/fm-production.log
dotdot|bash|me|1|bash $TMP_ROOT/../../srv/job.sh
inline|bash|me|1|bash -c run $TMP_ROOT/a.sh
preload|node|me|1|node --require $TMP_ROOT/bootstrap.js /srv/server.js
livewatch|bash|me|1|bash $TMP_ROOT/live/bin/fm-watchdog.sh run
prodlink|python3|me|1|python3 $TMP_ROOT/prodlink/server.py
runner|bash|me|1|bash $OUT_ROOT/repo/tests/ui.test.sh
brave|brave|me|P_runner|/opt/brave.com/brave/brave
mailer|python3|me|P_runner|python3 /opt/firstmate/bin/fm-mail.py
nmd|no-mistakes-daemon|me|P_runner|/opt/bin/no-mistakes-daemon serve
gimp|gimp|me|P_runner|/usr/bin/gimp /srv/large.xcf
spaced|python3|me|1|python3 $TMP_ROOT/work dir/../../srv/server.py
missing|bash|me|1|bash $TMP_ROOT/missing.sh
linkfile|bash|me|1|bash $TMP_ROOT/link.sh
spacewrap|python3|me|1|python3 $TMP_ROOT/job/work dir/server.py
pkgagent|node|me|1|node $TMP_ROOT/pkg/cli.js
relsup|bash|me|P_runner|bash fm-watchdog.sh run
agent2|claude|me|P_runner|claude
agentkid|python3|me|P_agent2|python3 -c run
symkid|bash|me|P_runner|bash $OUT_ROOT/run-loop.sh
pkgkid|python3|me|P_runner|python3 $OUT_ROOT/pkg2/cli.py
runner2|bash|me|1|bash $OUT_ROOT/tests/service.test.sh live.sh
fakekid|sleep|me|P_runner2|sleep 5
pkgwrap|bash|me|1|bash $TMP_ROOT/wrap2.sh
pkgwrapkid|node|me|P_pkgwrap|node $TMP_ROOT/pkg/cli.js
noname||me|P_runner|sleep 5
runner3|bash|me|1|bash $OUT_ROOT/pkg2/tests/ui.test.sh
aliaskid|sleep|me|P_runner3|sleep 5
errexit|bash|me|P_runner|bash -e $OUT_ROOT/run-loop.sh
inlinepath|bash|me|P_runner|bash -c . $OUT_ROOT/run-loop.sh
bareopt|bash|me|P_runner|bash -e run-loop.sh
barename|bash|me|P_runner|bash helper.sh
bunrun|bun|me|P_runner|bun run ./helper.sh
ddkid|dd|me|P_runner|dd if=production.db of=backup.db bs=8G
meld|python3|me|P_runner|python3 /usr/bin/meld
caseup|bash|me|1|bash $OUT_ROOT/BIN/FM-WATCHDOG.SH run
runner4|bash|me|1|bash tests/ui.test.sh
relkid|sleep|me|P_runner4|sleep 5
hardlink|node|me|1|node $TMP_ROOT/hard.js
renderer|helper|me|P_runner|/opt/app/helper --type=renderer"
  RUNNER_SMALL=1 sustain
  for name in exe nodeagent watchtmp prodlog dotdot inline preload livewatch prodlink brave renderer mailer nmd gimp spaced missing linkfile spacewrap pkgagent relsup agent2 agentkid symkid pkgkid runner2 fakekid pkgwrap pkgwrapkid noname runner3 aliaskid errexit inlinepath bareopt barename bunrun ddkid meld caseup runner4 relkid hardlink; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "$name (pid $pid) was signaled: $OUT"
    action_has "spared:$pid" || fail "action does not name the spared $name: $(summary)"
  done
  assert_contains "$OUT" "pid $P_nodeagent (node) has held" "the interpreted agent alarms"
  assert_contains "$OUT" "spared (protected claude)" "an agent run by an interpreter is protected by its script path"
  assert_contains "$OUT" "spared (firstmate supervisor script)" "a supervisor stays protected when an argument names a temp path"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (not scratch)')" = 19 ] || fail "a temp-path argument, a .. path, inline code, or a test-runner child counted as scratch: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (node outside a disposable temp root)')" = 1 ] || fail "a node preload under a temp root made node scratch: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (firstmate supervisor script)')" = 5 ] || fail "a supervisor script under a temp root lost its protection: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (program is not a regular file under a disposable temp root)')" = 3 ] || fail "a symlink out of the temp root or a missing program counted as scratch: $OUT"
  assert_contains "$OUT" "spared (protected no-mistakes)" "a hyphenated protected name protects a longer name it starts"
  assert_contains "$OUT" "spared (program path is ambiguous)" "a sibling that extends the program name with a space makes it ambiguous"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (resolved program: protected claude)')" = 2 ] || fail "a symlink to an agent package lost its protection: $OUT"
  assert_contains "$OUT" "spared (program has another hard link)" "a hard link into the temp root never makes a program scratch"
  assert_contains "$OUT" "pid $P_exe (leaky) has held" "a native binary under a temp root still alarms"
  assert_contains "$OUT" "spared (executable name unknown)" "a process whose executable name was not read is never named as would-stop"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (has child processes)')" = 4 ] || fail "a process with children counted as scratch: $OUT"
  assert_contains "$OUT" "spared (protected brave)" "a browser under a test runner is protected"
  assert_contains "$OUT" "spared (browser or Electron helper)" "a Chromium helper under a test runner is protected"
  pass "reap-scratch needs an interpreter running a single-link temp-root script"
}

test_reap_scratch_never_signals() {
  new_home 'mode=reap-scratch'
  P_scratch=
  REAP_ROWS="scratch|bash|me|1|bash $TMP_ROOT/runaway.sh"
  sustain
  assert_equals 3 "$RC" "a sustained scratch process alarms"
  action_has "would-stop:$P_scratch" || fail "the scratch process is not named as would-stop: $(summary)"
  grep -q 'ppid= -p' "$H/ps.log" || fail "reap-scratch did not run its classification"
  CLOCK=$((NOW0 + 1200)) reap_fixture
  guard $((NOW0 + 1200))
  alive "$P_scratch" || fail "a would-stop process was signaled"
  action_has "would-stop:$P_scratch" || fail "the next pass does not name it again: $(summary)"
  assert_equals 0 "$(alarms)" "a would-stop alarm inside the repeat time is not printed again"
  # A fixture row never survives the check before a signal, so the proof that
  # reap-scratch sends none is a real scratch process a stop would end.
  new_home 'mode=reap-scratch
proc_rss_mb=2
swap_warn_mb=99999999
proc_sustained_secs=1
scratch_stop_secs=1'
  start_hold "$TMP_ROOT/stopme/reaponly.sh"
  printf '%s\n' "$HOLD_PID" > "$H/ps/allow"
  guard_live
  sleep 2
  guard_live
  assert_equals 3 "$RC" "a sustained real scratch process alarms in reap-scratch: $OUT"
  action_has "would-stop:$HOLD_PID" || fail "the real scratch process is not named as would-stop: $OUT"
  alive "$HOLD_PID" || fail "reap-scratch signaled a real scratch process: $OUT"
  assert_absent "$H/state/memory-guard-stops.tsv" "reap-scratch records no stop"
  pass "reap-scratch only reports would-stop, never signals, and deduplicates the alarm"
}

test_padded_executable_name() {
  new_home 'mode=reap-scratch'
  P_padded=
  # macOS pads ucomm to 16 characters.
  REAP_ROWS="padded|perl            |me|1|perl $TMP_ROOT/grow.pl"
  sustain
  assert_equals 3 "$RC" "a sustained padded-name process alarms: $OUT"
  action_has "would-stop:$P_padded" || fail "a padded interpreter name is not scratch: $(summary)"
  assert_contains "$OUT" "pid $P_padded (perl) has held" "the alarm names the executable without its padding"
  assert_contains "$(summary)" "top_comm=perl mode=" "the summary names the executable without its padding"
  pass "an executable name padded by ps still matches its interpreter"
}

test_slow_process_read_keeps_the_window() {
  local start=$((NOW0 - 5000))
  new_home
  # etime is as old as the start of the read, the worst case for a slow read.
  one() { : > "$H/ps/table"; : > "$H/ps/comm"; proc 1 0 0 10 400000 launchd /sbin/launchd
    proc 4242 "$MYUID" 1 9000 $(( $1 - ${3:-$start} )) node 'node /srv/build.js'; guard_slow "$1" "$2"; }
  one "$NOW0" 9
  assert_contains "$(summary)" "status=watch" "first sight on a slow read is watch: $OUT"
  one $((NOW0 + 300)) 0
  one $((NOW0 + 600)) 12
  one $((NOW0 + 890)) 0
  assert_contains "$(summary)" "status=watch" "the window runs from the end of the first read"
  one $((NOW0 + 909)) 0
  assert_equals 3 "$RC" "slow and fast reads of one process keep one window: $OUT"
  assert_contains "$OUT" "pid 4242 (node) has held 9000 MB, at or over 8192 MB, for 900 s (limit 900 s)." "the hold is counted from the end of the first read"
  one $((NOW0 + 1200)) 0 $((start + 30))
  assert_contains "$(summary)" "status=watch" "a start 30 s away is a new process even after slow reads"
  pass "a slow process read neither restarts the window nor hides a reused pid"
}

test_stop_scratch_does_not_signal_a_changed_process() {
  local t
  new_home 'mode=stop-scratch'
  P_scratch=
  # The table calls this pid a scratch script, but the real process behind
  # it is a sleep, as after a pid was reused between the sample and the stop.
  REAP_ROWS="scratch|bash|me|1|bash $TMP_ROOT/runaway.sh"
  for t in 0 300; do CLOCK=$((NOW0 + t)) reap_fixture; guard $((NOW0 + t)); done
  assert_equals 0 "$RC" "a scratch process inside scratch_stop_secs is only watched: $OUT"
  assert_contains "$(summary)" "status=watch swap_used_mb=0 top_pid=$P_scratch top_rss_mb=9000 top_comm=bash mode=stop-scratch action=none" "nothing is due before scratch_stop_secs"
  CLOCK=$((NOW0 + 430)) reap_fixture
  ELAPSED=16 guard $((NOW0 + 430))
  assert_equals 0 "$RC" "a deferred stop is not an alarm: $OUT"
  action_has "stop-deferred:$P_scratch" || fail "a pass with no time left does not defer the stop: $(summary)"
  assert_equals 0 "$(alarms)" "a deferred stop inside the sustained window prints no alarm"
  ! grep -q "etime=.* -p $P_scratch\$" "$H/ps.log" || fail "a deferred stop still read the process"
  CLOCK=$((NOW0 + 480)) reap_fixture
  guard $((NOW0 + 480))
  grep -q "etime=.* -p $P_scratch\$" "$H/ps.log" || fail "the stop did not read the process again before the signal"
  assert_equals 0 "$RC" "a changed process inside the sustained window is not an alarm: $OUT"
  assert_contains "$(summary)" "status=watch" "a changed process stays watched"
  assert_contains "$(summary)" "action=none" "a changed process is not named as stopped"
  alive "$P_scratch" || fail "a process that changed after the sample was signaled"
  CLOCK=$((NOW0 + 900)) reap_fixture
  guard $((NOW0 + 900))
  assert_equals 3 "$RC" "the changed process alarms once it is sustained: $OUT"
  action_has "spared:$P_scratch" || fail "the changed process is not spared: $(summary)"
  assert_contains "$OUT" "for 900 s (limit 900 s). Mode stop-scratch: spared (changed before the stop); nothing was stopped." "the alarm says why nothing was stopped"
  alive "$P_scratch" || fail "a process that changed after the sample was signaled at the sustained pass"
  new_home 'mode=stop-scratch'
  sustain --observe
  assert_contains "$(summary)" "mode=observe action=none" "--observe overrides stop-scratch"
  ! grep -q -- "-p $P_scratch\$" "$H/ps.log" || fail "--observe ran the stop-scratch checks"
  alive "$P_scratch" || fail "--observe signaled a scratch process"
  pass "stop-scratch signals nothing when the process changed, the pass ran out of time, or --observe is set"
}

test_stop_scratch_spares_live_agents_and_operator_apps() {
  local name
  new_home 'mode=stop-scratch'
  agents_fixture
  RUNNER_SMALL=1 sustain
  assert_equals 3 "$RC" "stop pass alarms: $OUT"
  assert_not_contains "$(summary)" "stopped:" "no fixture process is named as stopped"
  assert_not_contains "$(summary)" "stop-failed:" "no fixture process is named as a failed stop"
  for name in scratch nodetmp $AGENT_NAMES; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "process $name (pid $pid) was signaled in stop-scratch: $OUT"
    action_has "spared:$pid" || [ "$name" = runner ] || fail "action does not name the spared $name: $(summary)"
  done
  assert_contains "$OUT" "Mode stop-scratch: spared (protected claude); nothing was stopped." "an agent harness stays alarm-only"
  assert_contains "$OUT" "Mode stop-scratch: spared (firstmate supervisor script); nothing was stopped." "a supervisor script stays alarm-only"
  assert_contains "$OUT" "Mode stop-scratch: spared (ancestor of protected pid $P_wrapped); nothing was stopped." "the parent of a live agent stays alarm-only"
  assert_contains "$OUT" "Mode stop-scratch: spared (another user); nothing was stopped." "another user's process stays alarm-only"
  pass "stop-scratch leaves every live agent, supervisor, and operator process alarm-only"
}

LIVE_CONF='mode=stop-scratch
proc_rss_mb=2
swap_warn_mb=99999999
alarm_repeat_secs=1'

test_stop_scratch_stops_only_real_scratch() {
  local scratch worker parent kid sneaky sneakykid named p
  new_home "$LIVE_CONF
proc_sustained_secs=1
scratch_stop_secs=1"
  # On TERM the scratch job keeps a copy of the stop record as it stood then.
  start_hold "$TMP_ROOT/stopme/job.sh" "trap 'cp \"$H/state/memory-guard-stops.tsv\" \"\$0.at-term\" 2>/dev/null; exit 0' TERM" "$TRAP_WAIT"; scratch=$HOLD_PID
  start_hold "$OUT_ROOT/repo/worker.sh"; worker=$HOLD_PID
  # shellcheck disable=SC2016 # the holder expands these, not this suite
  start_hold "$TMP_ROOT/stopme/parent.sh" 'sleep 100000 & printf "%s\n" "$!" > "$0.kid"'; parent=$HOLD_PID
  kid=$(cat "$TMP_ROOT/stopme/parent.sh.kid")
  # shellcheck disable=SC2016 # the holder expands these, not this suite
  start_hold "$TMP_ROOT/stopme/sneaky.sh" 'sleep 100000 & printf "%s\n" "$!" > "$0.kid"'; sneaky=$HOLD_PID
  sneakykid=$(cat "$TMP_ROOT/stopme/sneaky.sh.kid")
  start_hold "$TMP_ROOT/claude-code/session.sh"; named=$HOLD_PID
  SLEEPS="$SLEEPS $kid $sneakykid"
  # The sneaky child is left out of the table, as a child is that starts
  # after the sample was read.
  printf '%s\n' "$scratch" "$worker" "$parent" "$kid" "$sneaky" "$named" > "$H/ps/allow"
  guard_live
  assert_equals 0 "$RC" "first sight of the real processes is watch: $OUT"
  assert_contains "$(summary)" "status=watch" "first sight is watch"
  assert_contains "$(summary)" "mode=stop-scratch action=none" "nothing is stopped at first sight"
  alive "$scratch" || fail "the scratch process was signaled at first sight"
  sleep 2
  guard_live_stop
  assert_equals 3 "$RC" "a stop is an alarm: $OUT"
  action_has "stopped:$scratch" || fail "the real scratch process is not named as stopped: $OUT"
  wait_gone "$scratch" || fail "the real scratch process is still running: $OUT"
  assert_contains "$OUT" "pid $scratch (bash) has held" "the stop alarm names the process"
  assert_contains "$OUT" "s (limit 1 s). Mode stop-scratch: disposable scratch, stopped with TERM." "the stop alarm names the signal"
  assert_not_contains "$OUT" "stop-failed" "no stop failed"
  assert_equals "signal TERM" "$(stop_rows "$scratch" "$TMP_ROOT/stopme/job.sh.at-term")" "the stop record named the signal before the process received it"
  assert_equals "signal TERM
stopped TERM" "$(stop_rows "$scratch")" "the stop record holds the signal and then the outcome"
  for p in "$worker" "$parent" "$kid" "$sneaky" "$sneakykid" "$named"; do
    alive "$p" || fail "pid $p is not scratch and was signaled: $OUT"
    assert_equals "" "$(stop_rows "$p")" "a process that was not signaled has no stop record"
  done
  for p in "$worker" "$parent" "$sneaky" "$named"; do
    action_has "spared:$p" || fail "pid $p is not named as spared: $(summary)"
  done
  assert_contains "$OUT" "pid $worker (bash) has held" "a script outside a temp root still alarms"
  assert_contains "$OUT" "spared (not scratch)" "a script outside a temp root is not scratch"
  assert_contains "$OUT" "spared (has child processes)" "a scratch script with a child is spared"
  assert_contains "$OUT" "spared (changed before the stop)" "a child found right before the signal stops the stop"
  assert_contains "$OUT" "spared (protected claude)" "a protected name in the script path is spared"
  guard_live
  assert_not_contains "$(summary)" "$scratch" "the stopped process is gone from the next pass"
  for p in "$worker" "$parent" "$sneaky" "$named"; do
    alive "$p" || fail "pid $p was signaled on the next pass: $OUT"
  done
  pass "stop-scratch stops a real scratch process with TERM and nothing else"
}

test_stop_scratch_escalates_to_kill() {
  local stubborn
  # scratch_stop_secs over proc_sustained_secs counts as proc_sustained_secs.
  new_home "$LIVE_CONF
proc_sustained_secs=1
scratch_stop_secs=600"
  start_hold "$TMP_ROOT/stopme/stubborn.sh" 'trap "" TERM'; stubborn=$HOLD_PID
  printf '%s\n' "$stubborn" > "$H/ps/allow"
  guard_live
  assert_equals 0 "$RC" "first sight is watch: $OUT"
  sleep 2
  # A stop that cannot be recorded first is not started.
  mkdir "$H/state/memory-guard-stops.tsv"
  guard_live_stop
  assert_equals 3 "$RC" "a stop that cannot be recorded is an alarm: $OUT"
  action_has "stop-failed:$stubborn" || fail "an unrecorded stop is not named as failed: $OUT"
  assert_contains "$OUT" "the stop failed (the stop could not be recorded" "the alarm says the record could not be written"
  alive "$stubborn" || fail "a stop that could not be recorded still signaled the process"
  rmdir "$H/state/memory-guard-stops.tsv"
  guard_live --observe
  assert_contains "$(summary)" "mode=observe action=none" "--observe overrides stop-scratch on a real scratch process: $OUT"
  alive "$stubborn" || fail "--observe signaled the real scratch process"
  guard_live_stop
  assert_equals 3 "$RC" "a stop by KILL is an alarm: $OUT"
  action_has "stopped:$stubborn" || fail "the stubborn process is not named as stopped: $OUT"
  wait_gone "$stubborn" || fail "the stubborn process is still running: $OUT"
  assert_contains "$OUT" "Mode stop-scratch: disposable scratch, stopped with KILL after it ignored TERM." "the stop alarm names the escalation"
  assert_equals "signal TERM
signal KILL
stopped KILL" "$(stop_rows "$stubborn")" "the stop record holds each signal and then the outcome"
  pass "stop-scratch sends KILL when a scratch process ignores TERM, and --observe sends nothing"
}

test_stop_scratch_does_not_kill_after_a_new_child() {
  local spawner kid
  new_home "$LIVE_CONF
proc_sustained_secs=1
scratch_stop_secs=1"
  # This scratch job answers TERM by starting a child and running on.
  # shellcheck disable=SC2016 # the holder expands these, not this suite
  start_hold "$TMP_ROOT/stopme/spawner.sh" 'trap '\''sleep 100000 & printf "%s\n" "$!" > "$0.kid"'\'' TERM' "$TRAP_WAIT"; spawner=$HOLD_PID
  printf '%s\n' "$spawner" > "$H/ps/allow"
  guard_live
  assert_equals 0 "$RC" "first sight is watch: $OUT"
  sleep 2
  guard_live_stop
  [ -s "$TMP_ROOT/stopme/spawner.sh.kid" ] || fail "the scratch job did not receive TERM: $OUT"
  kid=$(cat "$TMP_ROOT/stopme/spawner.sh.kid")
  SLEEPS="$SLEEPS $kid"
  alive "$spawner" || fail "a process that started a child after TERM was killed: $OUT"
  alive "$kid" || fail "the child of a signaled process was signaled: $OUT"
  assert_equals 3 "$RC" "a failed stop is an alarm: $OUT"
  action_has "stop-failed:$spawner" || fail "the stop is not named as failed: $OUT"
  assert_contains "$OUT" "the stop failed (it started a child after TERM and was not signalled again)" "the alarm says why KILL was not sent"
  assert_equals "signal TERM
stop-failed it started a child after TERM and was not signalled again" "$(stop_rows "$spawner")" "the stop record holds TERM and no KILL"
  printf '%s\n' "$spawner" "$kid" > "$H/ps/allow"
  guard_live
  action_has "spared:$spawner" || fail "a scratch job with a child is not spared on the next pass: $OUT"
  alive "$spawner" || fail "a scratch job with a child was signaled on the next pass: $OUT"
  pass "stop-scratch never sends KILL to a process that started a child after TERM"
}

test_cleanup_kills_only_its_own_holders() {
  local rec victim held
  rec="$TMP_ROOT/holds-check.tsv"
  # A recorded holder pid that an unrelated process now holds: same pid, a
  # different start time and command line.
  start_sleep; victim=$SLEEP_PID
  printf '%s\t%s\n' "$victim" "Thu Jan  1 00:00:00 1970     bash $TMP_ROOT/stopme/gone.sh" > "$rec"
  kill_owned_holds "$rec"
  sleep 0.2
  alive "$victim" || fail "cleanup sent KILL to a process that reused a stopped holder's pid"
  # A TERM-ignoring holder this suite started is still stopped by KILL.
  start_hold "$TMP_ROOT/stopme/owned.sh" 'trap "" TERM'; held=$HOLD_PID
  awk -F'\t' -v p="$held" '$1 == p' "$HOLDS_FILE" > "$rec"
  [ -s "$rec" ] || fail "start_hold did not record the holder $held"
  kill_owned_holds "$rec"
  wait_gone "$held" || fail "cleanup did not KILL a TERM-ignoring holder this suite started"
  pass "exit cleanup KILLs only holders whose pid still names the process this suite started"
}

# A doubled slash names the same file, as macOS TMPDIR's trailing slash gives
# in "$TMPDIR/fm-x/job.pl", so it is judged as the single-slash path.
test_doubled_slash_script_path() {
  local dbl_tmp dbl_out name pid
  new_home 'mode=reap-scratch'
  dbl_tmp="${TMP_ROOT%/*}//${TMP_ROOT##*/}"
  dbl_out="${OUT_ROOT%/*}//${OUT_ROOT##*/}"
  P_dbl='' P_dblsup='' P_dblagent='' P_dblout='' P_dbldot=''
  REAP_ROWS="dbl|bash|me|1|bash $dbl_tmp//runaway.sh
dblsup|bash|me|1|bash $dbl_tmp/live//bin/fm-watchdog.sh run
dblagent|node|me|1|node $dbl_tmp//claude-code/cli.js
dblout|bash|me|1|bash $dbl_out//repo/helper.sh
dbldot|bash|me|1|bash $dbl_tmp//.//runaway.sh"
  sustain
  assert_equals 3 "$RC" "the sustained rows alarm: $OUT"
  action_has "would-stop:$P_dbl" || fail "a doubled-slash scratch script under a temp root is not named as would-stop: $OUT"
  for name in dblsup dblagent dblout dbldot; do
    eval "pid=\$P_$name"
    action_has "spared:$pid" || fail "the doubled-slash $name is not spared: $(summary)"
    alive "$pid" || fail "reap-scratch signaled $name"
  done
  assert_contains "$OUT" "Mode reap-scratch: spared (firstmate supervisor script)" "a doubled slash keeps a supervisor protected"
  assert_contains "$OUT" "Mode reap-scratch: spared (protected claude)" "a doubled slash keeps an agent protected"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (not scratch)')" = 2 ] || fail "a doubled slash let an out-of-root or . path count as scratch: $OUT"
  alive "$P_dbl" || fail "reap-scratch signaled the scratch row"
  # A real holder started through a doubled-slash path is stopped.
  new_home "$LIVE_CONF
proc_sustained_secs=1
scratch_stop_secs=1"
  start_hold "$dbl_tmp/stopme//dbl.sh"
  printf '%s\n' "$HOLD_PID" > "$H/ps/allow"
  guard_live
  assert_equals 0 "$RC" "first sight is watch: $OUT"
  sleep 2
  guard_live_stop
  assert_equals 3 "$RC" "a stop is an alarm: $OUT"
  action_has "stopped:$HOLD_PID" || fail "a real scratch process run through a doubled-slash path is not stopped: $OUT"
  wait_gone "$HOLD_PID" || fail "the doubled-slash scratch process is still running: $OUT"
  assert_equals "signal TERM
stopped TERM" "$(stop_rows "$HOLD_PID")" "the stop record holds the signal and the outcome"
  pass "a doubled slash in a script path is judged as one slash, for scratch and for protection"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit 0
fi

fm_test_run \
  test_help_and_usage \
  test_macos_reader \
  test_linux_reader \
  test_unreadable_sources \
  test_sustained_window \
  test_swap_threshold_and_config \
  test_log_is_bounded \
  test_alarm_survives_a_failed_record \
  test_state_save_failure_exits_1 \
  test_json_output \
  test_observe_default_never_signals \
  test_reap_scratch_spares_live_agents_and_operator_apps \
  test_reap_scratch_needs_a_scratch_program \
  test_reap_scratch_never_signals \
  test_padded_executable_name \
  test_slow_process_read_keeps_the_window \
  test_stop_scratch_does_not_signal_a_changed_process \
  test_stop_scratch_spares_live_agents_and_operator_apps \
  test_stop_scratch_stops_only_real_scratch \
  test_stop_scratch_escalates_to_kill \
  test_stop_scratch_does_not_kill_after_a_new_child \
  test_cleanup_kills_only_its_own_holders \
  test_doubled_slash_script_path
