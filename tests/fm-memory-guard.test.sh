#!/usr/bin/env bash
# Behavioral coverage for bin/fm-memory-guard.sh: the macOS and Linux readers,
# the sustained window, the swap alarm and its deduplication, the bounded
# sample log, observe as the default, and the reap-scratch allowlist that
# spares live agents, supervisors, multiplexers, and desktop apps.
# ps and sysctl are PATH fakes that print fixture tables; every process the
# reaper may signal is a real sleep this suite started.
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
# reap_fixture sets one P_<name> per fixture row; these are the ones read by name.
P_runner='' P_claude='' P_wrapped='' P_exe='' P_nodeagent='' P_execd='' P_reused='' P_moved=''

# Fixture programs under the temp root are real files, as a scratch program must be.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/live/bin" "$TMP_ROOT/work dir"
for f in runaway.sh leak.js wrap.sh foreign.sh turns.sh again.sh first.sh second.sh a.sh bootstrap.js bin/leaky live/bin/fm-watchdog.sh; do
  : > "$TMP_ROOT/$f"
done

cat > "$FAKE/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_PS_LOG"
case "$*" in
  *'-p '*) PATH=$FM_FAKE_BASE_PATH exec ps "$@" ;;
esac
[ "${FM_FAKE_PS_MODE:-ok}" = ok ] || exit 1
# A later read in the same pass serves table2 or comm2 when one exists, so a
# case can change a process between the sample and the signal.
case "$*" in
  *comm=*) f=comm ;;
  *) f=table ;;
esac
n=$(cat "$FM_FAKE_PS_DIR/$f.reads" 2>/dev/null)
printf '%s\n' "$(( ${n:-0} + 1 ))" > "$FM_FAKE_PS_DIR/$f.reads"
if [ "${n:-0}" -ge 1 ] && [ -f "$FM_FAKE_PS_DIR/${f}2" ]; then cat "$FM_FAKE_PS_DIR/${f}2"; else cat "$FM_FAKE_PS_DIR/$f"; fi
SH
cat > "$FAKE/sysctl" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_SWAP_MODE:-ok}" = ok ] || exit 1
printf 'total = 32768.00M  used = %s  free = 1.00M  (encrypted)\n' "$FM_FAKE_SWAP_USED"
SH
chmod +x "$FAKE/ps" "$FAKE/sysctl"

cleanup_sleeps() {
  local p
  for p in $SLEEPS; do kill "$p" 2>/dev/null || true; done
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
  printf '0\n' > "$H/ps/table.reads"
  printf '0\n' > "$H/ps/comm.reads"
  OUT=$(PATH="$FAKE:$BASE_PATH" FM_FAKE_BASE_PATH="$BASE_PATH" FM_FAKE_PS_DIR="$H/ps" FM_FAKE_PS_LOG="$H/ps.log" \
    FM_FAKE_PS_MODE="${PS_MODE:-ok}" FM_FAKE_SWAP_MODE="${SWAP_MODE:-ok}" FM_FAKE_SWAP_USED="$SWAP_USED" \
    FM_TEST_SEAM=1 FM_HOME="$H" FM_MEMORY_GUARD_NOW="$now" FM_MEMORY_GUARD_OS="${OS:-Darwin}" \
    FM_MEMORY_GUARD_MEMINFO="$H/meminfo" "$GUARD" check "$@" 2>&1) || RC=$?
}

summary() { printf '%s\n' "$OUT" | grep '^memory-guard: status=' | head -n 1; }
alarms() { printf '%s\n' "$OUT" | grep -c '^MEMORY_GUARD_ALARM: ' | tr -d ' '; }
# action_has <token>: the summary's action list holds exactly that token.
action_has() { summary | sed -n 's/.* action=//p' | tr ',' '\n' | grep -Fxq -- "$1"; }

start_sleep() {  # -> pid of a real, detached sleep this suite owns
  local f="$TMP_ROOT/sleep.$RANDOM.pid"
  ( sleep 100000 >/dev/null 2>&1 & printf '%s\n' "$!" > "$f" )
  SLEEP_PID=$(cat "$f")
  SLEEPS="$SLEEPS $SLEEP_PID"
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
  assert_contains "$OUT" "memory-guard: config: mode=kill is not observe or reap-scratch; using observe" "bad mode note"
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
    if [ -z "$pid" ]; then start_sleep; pid=$SLEEP_PID; eval "P_$name=$pid"; fi
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
  new_home 'mode=reap-scratch'
  sustain --observe
  assert_contains "$(summary)" "mode=observe action=none" "--observe overrides reap-scratch"
  alive "$P_scratch" || fail "--observe signaled a scratch process"
  pass "observe is the default and --observe always wins"
}

test_reap_scratch_spares_live_agents_and_operator_apps() {
  local name
  new_home 'mode=reap-scratch'
  for name in scratch runner testchild nodetmp claude codex agy tmux orca nodeout app watch plain other wrapper wrapped; do eval "P_$name="; done
  REAP_ROWS="scratch|bash|me|1|bash $TMP_ROOT/runaway.sh
runner|bash|me|1|bash tests/fm-example.test.sh
testchild|python3|me|P_runner|python3 -c pass
nodetmp|node|me|1|node $TMP_ROOT/leak.js
claude|claude|me|1|claude --print $TMP_ROOT/x
codex|exec-helper|me|1|/opt/homebrew/bin/codex exec $TMP_ROOT/y
agy|agy|me|1|agy -p hello
tmux|tmux|me|1|tmux -L fm-test-$CASE_N new-session $TMP_ROOT/z
orca|orca|me|1|orca serve
nodeout|node|me|1|node /srv/server.js
app|Cursor Helper|me|1|/Applications/Cursor.app/Contents/MacOS/Cursor Helper $TMP_ROOT/w
watch|bash|me|1|bash /opt/firstmate/bin/fm-watch.sh
plain|python3|me|1|python3 /srv/big.py
other|bash|0|1|bash $TMP_ROOT/foreign.sh
wrapper|bash|me|1|bash $TMP_ROOT/wrap.sh
wrapped|claude|me|P_wrapper|claude"
  # The test runner itself stays small, so only its child is a candidate.
  RUNNER_SMALL=1 sustain
  assert_equals 3 "$RC" "reap pass alarms: $OUT"
  for name in scratch testchild nodetmp; do
    eval "pid=\$P_$name"
    wait_gone "$pid" || fail "scratch process $name (pid $pid) was not stopped: $OUT"
    action_has "term:$pid" || fail "action does not name the stopped $name: $(summary)"
  done
  for name in runner claude codex agy tmux orca nodeout app watch plain other wrapper wrapped; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "protected process $name (pid $pid) was signaled: $OUT"
    ! action_has "term:$pid" || fail "SIGTERM recorded for $name: $(summary)"
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
  pass "reap-scratch stops only scratch processes and spares every live agent and operator process"
}

test_reap_scratch_needs_a_scratch_program() {
  local name
  new_home 'mode=reap-scratch'
  for name in exe nodeagent watchtmp prodlog dotdot inline preload livewatch prodlink runner brave renderer mailer nmd gimp spaced missing; do eval "P_$name="; done
  ln -s "$BASE_PATH_FIRST" "$TMP_ROOT/prodlink"
  REAP_ROWS="exe|leaky|me|1|$TMP_ROOT/bin/leaky --size 9
nodeagent|node|me|1|node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js --add-dir $TMP_ROOT/p
watchtmp|bash|me|1|bash /opt/firstmate/bin/fm-watch.sh --state $TMP_ROOT/home
prodlog|python3|me|1|python3 /srv/production.py --log $TMP_ROOT/fm-production.log
dotdot|bash|me|1|bash $TMP_ROOT/../../srv/job.sh
inline|bash|me|1|bash -c run $TMP_ROOT/a.sh
preload|node|me|1|node --require $TMP_ROOT/bootstrap.js /srv/server.js
livewatch|bash|me|1|bash $TMP_ROOT/live/bin/fm-watchdog.sh run
prodlink|python3|me|1|python3 $TMP_ROOT/prodlink/server.py
runner|bash|me|1|bash tests/ui.test.sh
brave|brave|me|P_runner|/opt/brave.com/brave/brave
mailer|python3|me|P_runner|python3 /opt/firstmate/bin/fm-mail.py
nmd|no-mistakes-daemon|me|P_runner|/opt/bin/no-mistakes-daemon serve
gimp|gimp|me|P_runner|/usr/bin/gimp /srv/large.xcf
spaced|python3|me|1|python3 $TMP_ROOT/work dir/../../srv/server.py
missing|bash|me|1|bash $TMP_ROOT/missing.sh
renderer|helper|me|P_runner|/opt/app/helper --type=renderer"
  RUNNER_SMALL=1 sustain
  wait_gone "$P_exe" || fail "a program under a temp root was not stopped: $OUT"
  action_has "term:$P_exe" || fail "action does not name the stopped program: $(summary)"
  for name in nodeagent watchtmp prodlog dotdot inline preload livewatch prodlink brave renderer mailer nmd gimp spaced missing; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "$name (pid $pid) was signaled: $OUT"
    action_has "spared:$pid" || fail "action does not name the spared $name: $(summary)"
  done
  assert_contains "$OUT" "pid $P_nodeagent (node) has held" "the interpreted agent alarms"
  assert_contains "$OUT" "spared (protected claude)" "an agent run by an interpreter is protected by its script path"
  assert_contains "$OUT" "spared (firstmate supervisor script)" "a supervisor stays protected when an argument names a temp path"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (not scratch)')" = 5 ] || fail "a temp-path argument, a .. path, inline code, or a desktop app under a test runner counted as scratch: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (node outside a disposable temp root)')" = 1 ] || fail "a node preload under a temp root made node scratch: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (firstmate supervisor script)')" = 3 ] || fail "a supervisor script under a temp root lost its protection: $OUT"
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (program is not a regular file under a disposable temp root)')" = 2 ] || fail "a symlink out of the temp root or a missing program counted as scratch: $OUT"
  assert_contains "$OUT" "spared (protected no-mistakes)" "a hyphenated protected name protects a longer name it starts"
  assert_contains "$OUT" "spared (protected brave)" "a browser under a test runner is protected"
  assert_contains "$OUT" "spared (browser or Electron helper)" "a Chromium helper under a test runner is protected"
  pass "reap-scratch needs the program itself under a temp root, not an argument that names one"
}

test_reap_scratch_rechecks_before_signaling() {
  local name
  new_home 'mode=reap-scratch'
  for name in execd reused moved; do eval "P_$name="; done
  REAP_ROWS="execd|bash|me|1|bash $TMP_ROOT/turns.sh
reused|bash|me|1|bash $TMP_ROOT/again.sh
moved|bash|me|1|bash $TMP_ROOT/first.sh"
  for t in 0 300 600 900; do
    CLOCK=$((NOW0 + t)) reap_fixture
    # Between the sample and the signal, execd becomes an agent and the
    # reused pid is a new process with the same command line.
    # moved still judges eligible after the change, so only the identity
    # comparison spares it.
    awk -v e="$P_execd" -v r="$P_reused" -v m="$P_moved" -v nxt="$TMP_ROOT/second.sh" '$1 == e { $NF = ""; $(NF - 1) = "claude" } $1 == r { $6 = "00:01" } $1 == m { $NF = nxt } { print }' "$H/ps/table" > "$H/ps/table2"
    awk -v e="$P_execd" '$1 == e { $2 = "claude" } { print }' "$H/ps/comm" > "$H/ps/comm2"
    guard $((NOW0 + t))
  done
  for name in execd reused moved; do
    eval "pid=\$P_$name"
    alive "$pid" || fail "$name (pid $pid) was signaled after it changed: $OUT"
    action_has "spared:$pid" || fail "action does not name the spared $name: $(summary)"
  done
  [ "$(printf '%s\n' "$OUT" | grep -c 'spared (changed since the sample)')" = 3 ] || fail "a changed process was not spared as changed: $OUT"
  pass "reap-scratch rereads the process just before the signal and spares one that changed"
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
  test_json_output \
  test_observe_default_never_signals \
  test_reap_scratch_spares_live_agents_and_operator_apps \
  test_reap_scratch_needs_a_scratch_program \
  test_reap_scratch_rechecks_before_signaling
