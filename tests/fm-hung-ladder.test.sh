#!/usr/bin/env bash
# Hung-worker ladder stage 1 (observe) through bin/fm-hung-ladder.sh.
# Every case runs the real script against a private home, with a fake clock,
# real sleeping processes as agents, and tripwires in place of every command
# that could steer, interrupt, exit, relaunch, or tear down a worker.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_BASH=${FM_TEST_BASH:-${BASH:-bash}}
TMP_ROOT=$(fm_test_tmproot fm-hung-ladder)
export TZ=UTC

# A copy of bin/ whose action commands are tripwires: any call is logged.
CODE="$TMP_ROOT/code"
TRIP="$TMP_ROOT/tripwire.log"
mkdir -p "$CODE"
cp -R "$ROOT/bin" "$CODE/bin"
for t in fm-send.sh fm-control.sh fm-spawn.sh fm-teardown.sh fm-pr-merge.sh; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> %q\nexit 0\n' "$t" "$TRIP" > "$CODE/bin/$t"
  chmod +x "$CODE/bin/$t"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$CODE/bin/fm-captain-hold.sh"
chmod +x "$CODE/bin/fm-captain-hold.sh"
LADDER="$CODE/bin/fm-hung-ladder.sh"

# Fake terminal tools: any call at all is a tripwire hit.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
for t in tmux orca herdr; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> %q\nexit 1\n' "$t" "$TRIP" > "$FAKEBIN/$t"
  chmod +x "$FAKEBIN/$t"
done

PROBE="$TMP_ROOT/probe"
cat > "$PROBE" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  agent) cat "$FM_TEST_PROBE_DIR/$2.agent" ;;
  composer) cat "$FM_TEST_PROBE_DIR/$2.composer" 2>/dev/null || printf empty ;;
  draft) cat "$FM_TEST_PROBE_DIR/$2.draft" 2>/dev/null || printf none ;;
esac
EOF
CREW="$TMP_ROOT/crew-state"
cat > "$CREW" <<'EOF'
#!/usr/bin/env bash
if [ -s "$FM_TEST_PROBE_DIR/$1.validating" ]; then
  cat "$FM_TEST_PROBE_DIR/$1.validating"
elif [ -e "$FM_TEST_PROBE_DIR/$1.validating" ]; then
  echo "state: working · source: run-step · validating (running) · run: r1"
else
  echo "state: working · source: pane · idle"
fi
EOF
TESTQ="$TMP_ROOT/test-queue"
cat > "$TESTQ" <<'EOF'
#!/usr/bin/env bash
[ "$1" = status ] || exit 2
[ ! -e "$FM_TEST_PROBE_DIR/testq-fail" ] || exit 1
cat "$FM_TEST_PROBE_DIR/testq" 2>/dev/null || true
EOF
chmod +x "$PROBE" "$CREW" "$TESTQ"

AGENTS=''
cleanup_agents() {
  local p
  for p in $AGENTS; do kill "$p" 2>/dev/null || true; done
}
trap 'cleanup_agents; fm_test_cleanup' EXIT

# 22:05 UTC on a fixed day, so the night window is known.
B=$(( (1794700000 / 86400) * 86400 + 22 * 3600 + 300 ))

new_home() {  # <name> -> home path
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/probe"
  printf 'mode=observe\nactor=test\n' > "$h/config/hung-ladder"
  printf '%s\n' "$h"
}

new_agent() {  # sets AGENT_PID to a live, idle stand-in agent process
  sleep 3600 >/dev/null 2>&1 &
  AGENT_PID=$!
  AGENTS="$AGENTS $AGENT_PID"
}

new_task() {  # <home> <task> [kind]
  local h=$1 task=$2 kind=${3:-ship} wt
  wt="$h/wt-$task"
  fm_git_init_commit "$wt" >/dev/null
  fm_write_meta "$h/state/$task.meta" "window=fm:fm-$task" "worktree=$wt" "kind=$kind" "backend=tmux" "harness=claude"
  printf 'working: started [at=%s]\n' "$B" > "$h/state/$task.status"
  new_agent
  printf 'alive %s' "$AGENT_PID" > "$h/probe/$task.agent"
}

agent_pid() { local s; s=$(cat "$1/probe/$2.agent"); printf '%s' "${s#* }"; }

perm_of() {  # <path> -> octal permissions
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# An agent whose child writes a little every 20 seconds and uses almost no CPU.
WRITER="$TMP_ROOT/writer-agent"
cat > "$WRITER" <<'EOF'
#!/usr/bin/env bash
perl -e 'while (1) { open(my $f, ">>", $ARGV[0]) or die; print $f "x" x 4096; close $f; sleep 20 }' "$1" &
wait
EOF
chmod +x "$WRITER"

PANE_STYLE=busy
pane_for() {  # <now>
  case "$PANE_STYLE" in
    busy) printf '● Running the build\n\n✻ Thinking… (%ss · ↓ 180 tokens · esc to interrupt)\n' "$(( $1 - B ))" ;;
    streaming) printf '● Running the build\n\n✻ Thinking… (%ss · ↓ %s tokens · esc to interrupt)\n' "$(( $1 - B ))" "$(( ($1 - B) * 3 ))" ;;
    pager) printf 'commit abc\nAuthor: x\n\n    message\n(END)\n' ;;
    token) printf 'export GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123\n❯ \n' ;;
    *) printf '%s\n' "$PANE_STYLE" ;;
  esac
}

tick() {  # <home> <task> <now>
  local h=$1 task=$2 now=$3
  pane_for "$now" | env -u FM_TASK_ID FM_HOME="$h" FM_HUNG_LADDER_NOW="$now" \
    FM_HUNG_LADDER_LOAD="${LOAD:-0.50}" FM_HUNG_LADDER_PROBE="$PROBE" FM_TEST_PROBE_DIR="$h/probe" \
    FM_CREW_STATE_BIN="$CREW" FM_TEST_QUEUE_BIN="$TESTQ" PATH="$FAKEBIN:$PATH" \
    "$TEST_BASH" "$LADDER" tick --task "$task" --kind "${KIND:-ship}" --busy "${BUSY:-1}" --dialog "${DIALOG:-}"
}

ticks() {  # <home> <task> <from> <to>
  local n=$3
  while [ "$n" -le "$4" ]; do
    tick "$1" "$2" "$n"
    n=$((n + 60))
  done
}

ledger() { cat "$1/state/hung-ladder/actions.tsv" 2>/dev/null || true; }

# rows <home> <task> <decision> [rung] -> count
rows() {
  ledger "$1" | awk -F'\t' -v t="$2" -v d="$3" -v r="${4:-}" '$4 == t && $6 == d && (r == "" || $5 == r) { n++ } END { print n + 0 }'
}

reason_of() {  # <home> <task> <decision> <rung>
  ledger "$1" | awk -F'\t' -v t="$2" -v d="$3" -v r="$4" '$4 == t && $6 == d && $5 == r { print $11 }'
}

verify() {
  env FM_HOME="$1" "$TEST_BASH" "$LADDER" verify
}

progress() {  # <home> <task> <now> <text>
  printf '%s [at=%s]\n' "$4" "$3" >> "$1/state/$2.status"
}

assert_no_actions() {  # <context>
  if [ -s "$TRIP" ]; then
    fail "$1: an action command or terminal tool was called: $(cat "$TRIP")"
  fi
}

assert_agents_alive() {  # <context>
  local p
  for p in $AGENTS; do
    kill -0 "$p" 2>/dev/null || fail "$1: agent process $p was stopped"
  done
}

test_observe_rungs_and_self_progress() {
  local h pid snap
  h=$(new_home observe)
  new_task "$h" t1
  pid=$(agent_pid "$h" t1)
  # The pane renders busy the whole time, with a moving elapsed counter: the
  # busy-turn deferral must not hide it (T9).
  ticks "$h" t1 "$B" $((B + 1440))
  assert_equals 1 "$(rows "$h" t1 observe 0)" 'rung 0 records one episode'
  assert_equals 1 "$(rows "$h" t1 would-act 1)" 'one rung-1 would-act row'
  assert_equals 1 "$(rows "$h" t1 would-act 2)" 'one rung-2 would-act row'
  assert_equals 1 "$(rows "$h" t1 would-act 3)" 'one rung-3 would-act row'
  assert_equals 1 "$(rows "$h" t1 would-act 4)" 'one rung-4 would-act row'
  ledger "$h" | awk -F'\t' '$6 == "would-act" && $5 == "2" { exit !($2 == '"$((B + 480))"') }' \
    || fail 'rung 2 fires at T0+6 and not before'
  ledger "$h" | awk -F'\t' '$6 == "would-act" && $5 == "3" { exit !($2 == '"$((B + 1080))"') }' \
    || fail 'rung 3 fires at T0+16 and 8 minutes after rung 2'
  case "$(ledger "$h" | awk -F'\t' '$5 == "4" { print $8 }')" in
    *rendered=quiet*fs=quiet*kernel=quiet*busy=1*live=alive*) ;;
    *) fail 'the rung-4 row records each signal reading' ;;
  esac
  case "$(ledger "$h" | awk -F'\t' '$5 == "4" { print $9 }')" in
    *task_hour=0/1*shared_hour=0/2*home_night=0/6*) ;;
    *) fail 'the rung-4 row records the cap state' ;;
  esac
  case "$(ledger "$h" | awk -F'\t' '$5 == "4" { print $10 }')" in
    *tripped=0*) ;;
    *) fail 'the rung-4 row records the breaker state' ;;
  esac
  progress "$h" t1 $((B + 1500)) 'working: tests pass'
  tick "$h" t1 $((B + 1500))
  assert_equals 5 "$(rows "$h" t1 resolve)" 'every episode row gets a resolve row'
  assert_equals 5 "$(ledger "$h" | awk -F'\t' '$6 == "resolve" && $13 == "yes" && $11 ~ /net-advance:status/ { n++ } END { print n + 0 }')" \
    'each resolve row records later_self_progressed=yes'
  assert_equals 0 "$(ledger "$h" | awk -F'\t' '$6 == "would-act" && $13 != "pending" { n++ } END { print n + 0 }')" \
    'would-act rows are never edited; the follow-up is a new row'
  assert_no_actions 'observe mode'
  assert_agents_alive 'observe mode'
  [ ! -e "$h/state/t1.inbox" ] || fail 'observe mode wrote no steering message'
  verify "$h" >/dev/null || fail 'the ledger chain verifies'
  assert_equals "700" "$(perm_of "$h/state/hung-ladder")" 'ladder directory is owner-only'
  assert_equals "600" "$(perm_of "$h/state/hung-ladder/actions.tsv")" 'ledger is owner-only'
  snap=$(find "$h/state/hung-ladder/snapshots/t1" -name '*.tree' | head -n 1)
  [ -n "$snap" ] || fail 'rung 4 saved a content snapshot'
  grep -q "^head	$(git -C "$h/wt-t1" rev-parse HEAD)" "$snap" || fail 'the content snapshot records the head'
  kill -0 "$pid" || fail 'the agent survived'
  pass 'observe records would-act rows for rungs 1-4, then later_self_progressed=yes, with zero actions'
}

test_death_resolves_no() {
  local h
  h=$(new_home death)
  new_task "$h" td
  ticks "$h" td "$B" $((B + 480))
  assert_equals 1 "$(rows "$h" td would-act 2)" 'episode reached rung 2'
  printf 'dead -' > "$h/probe/td.agent"
  tick "$h" td $((B + 540))
  assert_equals 3 "$(ledger "$h" | awk -F'\t' '$6 == "resolve" && $13 == "no" && $11 ~ /not-live:dead/ { n++ } END { print n + 0 }')" \
    'a death closes the episode with later_self_progressed=no'
  assert_no_actions 'death'
  pass 'a worker that dies closes its episode with later_self_progressed=no'
}

hang_episode() {  # <home> <task> <start>: progress at start, rung 4 due at start+1440
  progress "$1" "$2" "$3" "working: step at $3"
  ticks "$1" "$2" "$3" $(( $3 + 1440 ))
}

test_caps_hold_escalations() {
  local h
  # One hang replacement per task per hour; the second episode parks.
  h=$(new_home cap-task-hour)
  new_task "$h" ca
  hang_episode "$h" ca "$B"
  hang_episode "$h" ca $((B + 1500))
  assert_equals 1 "$(rows "$h" ca would-act 4)" 'the second hang inside an hour gets no second rung 4'
  case "$(reason_of "$h" ca would-act 5)" in *'park cap:task-hour'*) ;; *) fail 'it parks on the per-task hourly cap' ;; esac

  # The shared counter includes the dead-worker recovery's attempts.
  h=$(new_home cap-shared)
  new_task "$h" cs
  printf '%s\tattempt\n%s\tattempt\n' $((B - 600)) $((B - 300)) > "$h/state/.crew-relaunch-cs"
  hang_episode "$h" cs "$B"
  assert_equals 0 "$(rows "$h" cs would-act 4)" 'two recent automatic relaunches leave no room'
  case "$(reason_of "$h" cs would-act 5)" in *'park cap:shared-hour'*) ;; *) fail 'it parks on the shared hourly cap' ;; esac

  # Two hang replacements per task per night, even an hour apart.
  h=$(new_home cap-task-night)
  new_task "$h" cn
  hang_episode "$h" cn "$B"
  hang_episode "$h" cn $((B + 3700))
  hang_episode "$h" cn $((B + 7400))
  assert_equals 2 "$(rows "$h" cn would-act 4)" 'two rung-4 rows in one night'
  case "$(reason_of "$h" cn would-act 5)" in *'park cap:task-night'*) ;; *) fail 'the third parks on the per-task nightly cap' ;; esac

  # Two hang replacements per home per hour, across tasks.
  h=$(new_home cap-home-hour)
  new_task "$h" ha
  new_task "$h" hb
  new_task "$h" hc
  hang_episode "$h" ha "$B"
  progress "$h" ha $((B + 1440)) 'working: a resumed'
  tick "$h" ha $((B + 1440))
  hang_episode "$h" hb $((B + 1440))
  progress "$h" hb $((B + 2880)) 'working: b resumed'
  tick "$h" hb $((B + 2880))
  hang_episode "$h" hc $((B + 2880))
  assert_equals 1 "$(rows "$h" ha would-act 4)" 'first task reaches rung 4'
  assert_equals 1 "$(rows "$h" hb would-act 4)" 'second task reaches rung 4'
  assert_equals 0 "$(rows "$h" hc would-act 4)" 'a third replacement in the hour is suppressed'
  case "$(reason_of "$h" hc would-act 5)" in *'park cap:home-hour'*) ;; *) fail 'it parks on the per-home hourly cap' ;; esac
  assert_no_actions 'caps'
  pass 'the per-task, shared, nightly, and per-home caps suppress rung 4'
}

seed_live() {  # <home> <count> <now>: other live workers for the breaker's N
  local i=0
  mkdir -p "$1/state/hung-ladder/seen"
  while [ "$i" -lt "$2" ]; do
    printf '%s\n' "$3" > "$1/state/hung-ladder/seen/other-$i"
    i=$((i + 1))
  done
}

parallel_ticks() {  # <home> <from> <to> <seed-count> <task>...
  local h=$1 n=$2 to=$3 seed=$4 t
  shift 4
  while [ "$n" -le "$to" ]; do
    [ "$seed" = 0 ] || seed_live "$h" "$seed" "$n"
    for t in "$@"; do tick "$h" "$t" "$n"; done
    n=$((n + 60))
  done
}

test_breaker_formula_and_load() {
  local h t
  # N=3: max(3, ceil(3/4)) = 3 open episodes trip the breaker.
  h=$(new_home breaker-small)
  for t in b1 b2 b3; do new_task "$h" "$t"; done
  parallel_ticks "$h" "$B" $((B + 1200)) 0 b1 b2 b3
  assert_equals 1 "$(rows "$h" - alarm)" 'one systemic alarm for the home'
  case "$(ledger "$h" | awk -F'\t' '$6 == "alarm" { print $11 }')" in
    *'systemic-breaker open=3 threshold=3'*) ;;
    *) fail 'the alarm names the count and the threshold' ;;
  esac
  for t in b1 b2 b3; do
    assert_equals 1 "$(rows "$h" "$t" would-act 2)" "rung 2 still runs under the breaker ($t)"
    assert_equals 0 "$(rows "$h" "$t" would-act 3)" "rung 3 holds under the breaker ($t)"
    assert_equals 1 "$(ledger "$h" | awk -F'\t' -v t="$t" '$4 == t && $6 == "hold" && $11 == "breaker" { n++ } END { print n + 0 }')" "a breaker hold row ($t)"
  done

  # N=16: max(3, ceil(16/4)) = 4, so three open episodes do not trip it.
  h=$(new_home breaker-large)
  for t in c1 c2 c3; do new_task "$h" "$t"; done
  parallel_ticks "$h" "$B" $((B + 1200)) 13 c1 c2 c3
  assert_equals 0 "$(rows "$h" - alarm)" 'no systemic alarm below max(3, ceil(N/4))'
  for t in c1 c2 c3; do
    assert_equals 1 "$(rows "$h" "$t" would-act 3)" "rung 3 proceeds below the threshold ($t)"
  done

  # Host load above the configured ceiling trips it too, and it clears.
  h=$(new_home breaker-load)
  printf 'mode=observe\nactor=test\nload_ceiling=50\n' > "$h/config/hung-ladder"
  new_task "$h" l1
  ticks "$h" l1 "$B" $((B + 900))
  assert_equals 1 "$(rows "$h" l1 would-act 2)" 'rung 2 under normal load'
  LOAD=60 ticks "$h" l1 $((B + 960)) $((B + 1200))
  case "$(ledger "$h" | awk -F'\t' '$6 == "alarm" { print $11 }')" in
    *'load=60 ceiling=50'*) ;;
    *) fail 'a load above the ceiling raises the systemic alarm' ;;
  esac
  assert_equals 0 "$(rows "$h" l1 would-act 3)" 'rung 3 holds while load is above the ceiling'
  assert_equals 1 "$(rows "$h" l1 observe 0)" 'the hold kept the episode and its T0'
  ticks "$h" l1 $((B + 1260)) $((B + 1500))
  assert_equals 1 "$(rows "$h" l1 would-act 3)" 'rung 3 continues after the load clears and a fresh proof'
  assert_no_actions 'breaker'
  pass 'the breaker trips at max(3, ceil(N/4)) open episodes or above the load ceiling, holding rungs 3-4'
}

no_escalation() {  # <home> <task> <context>
  assert_equals 0 "$(rows "$1" "$2" would-act 3)" "$3: no rung-3 row"
  assert_equals 0 "$(rows "$1" "$2" would-act 4)" "$3: no rung-4 row"
}

test_healthy_waits_and_screens() {
  local h live
  h=$(new_home waits)
  # An active fm-test-queue ticket.
  new_task "$h" tq
  new_agent
  live=$AGENT_PID
  printf 'paused: waiting on fm-test-queue ticket=7 for the full suite [at=%s]\n' "$B" >> "$h/state/tq.status"
  printf 'serving ticket=7 pid=%s age=1m task=tq label=suite\n' "$live" > "$h/probe/testq"
  ticks "$h" tq "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" tq would-act)" 'a live test-queue ticket protects the worker'
  assert_equals 0 "$(rows "$h" tq observe)" 'and opens no episode'
  # Once the ticket is gone the wait is dead: rung 2 comes at once.
  : > "$h/probe/testq"
  ticks "$h" tq $((B + 1860)) $((B + 2040))
  case "$(reason_of "$h" tq would-act 1)" in *test-queue-ticket-gone*) ;; *) fail 'rung 1 records the verified dead wait' ;; esac
  assert_equals 1 "$(rows "$h" tq would-act 2)" 'a proven dead wait steers at once'
  no_escalation "$h" tq 'dead wait inside its first minutes'

  # A live background shell named by pid.
  new_task "$h" bg
  new_agent
  live=$AGENT_PID
  printf 'paused: waiting on background shell pid=%s running the build [at=%s]\n' "$live" "$B" >> "$h/state/bg.status"
  ticks "$h" bg "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" bg would-act)" 'a live background shell protects the worker'

  # A recognised dialog parks with the pane saved, never rung 3 or 4.
  new_task "$h" dl
  DIALOG='Claude background-task exit picker' ticks "$h" dl "$B" $((B + 1800))
  no_escalation "$h" dl 'dialog'
  assert_equals 1 "$(rows "$h" dl would-act 5)" 'a dialog that lasts 4 minutes parks once'
  case "$(reason_of "$h" dl would-act 5)" in *'screen-block dialog:Claude background-task exit picker'*) ;; *) fail 'the park names the dialog' ;; esac

  # A non-empty composer.
  new_task "$h" cp
  printf pending > "$h/probe/cp.composer"
  ticks "$h" cp "$B" $((B + 1800))
  no_escalation "$h" cp 'non-empty composer'
  case "$(reason_of "$h" cp would-act 5)" in *'composer:pending'*) ;; *) fail 'a non-empty composer parks' ;; esac

  # A pager.
  new_task "$h" pg
  PANE_STYLE=pager ticks "$h" pg "$B" $((B + 1800))
  no_escalation "$h" pg 'pager'
  case "$(reason_of "$h" pg would-act 5)" in *'screen-block pager'*) ;; *) fail 'a pager parks' ;; esac

  # A validation run in flight, in each state the crew state reports.
  new_task "$h" nm
  : > "$h/probe/nm.validating"
  ticks "$h" nm "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" nm would-act)" 'a validating worker is out of scope'
  new_task "$h" ci
  echo "state: working · source: run-step · ci running · run: r2" > "$h/probe/ci.validating"
  ticks "$h" ci "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" ci would-act)" 'a run waiting on CI is out of scope'
  new_task "$h" pk
  echo "state: parked · source: run-step · parked at review: 2 finding(s) · run: r3" > "$h/probe/pk.validating"
  ticks "$h" pk "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" pk would-act)" 'a run parked at a gate is out of scope'

  # A test-queue wait whose queue cannot be read is unknown, never dead.
  new_task "$h" qf
  printf 'paused: waiting on fm-test-queue ticket=9 [at=%s]\n' "$B" >> "$h/state/qf.status"
  : > "$h/probe/testq-fail"
  ticks "$h" qf "$B" $((B + 1800))
  rm -f "$h/probe/testq-fail"
  assert_equals 0 "$(rows "$h" qf would-act)" 'an unreadable queue proves nothing about the wait'

  # A composer that cannot be read is an unknown sensor.
  new_task "$h" cu
  printf unknown > "$h/probe/cu.composer"
  ticks "$h" cu "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" cu would-act)" 'an unreadable composer holds every rung'

  # Orca keeps prompt-row text in a draft field the composer read leaves out.
  new_task "$h" od
  fm_write_meta "$h/state/od.meta" "terminal=term-od" "worktree=$h/wt-od" "kind=ship" "backend=orca" "harness=claude"
  printf present > "$h/probe/od.draft"
  ticks "$h" od "$B" $((B + 1800))
  no_escalation "$h" od 'Orca draft'
  case "$(reason_of "$h" od would-act 5)" in *'composer:draft'*) ;; *) fail 'an Orca draft parks' ;; esac

  # Streaming tokens are native progress, even when nothing else moves.
  new_task "$h" st
  PANE_STYLE=streaming ticks "$h" st "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" st observe)" 'a turn that streams tokens opens no episode'

  # A ticket that names no test queue is an ordinary bounded wait, never a dead one.
  new_task "$h" tk
  printf 'paused: waiting for approval on ticket PROJ-123 [at=%s]\n' "$B" >> "$h/state/tk.status"
  ticks "$h" tk "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" tk would-act)" 'a ticket outside the test queue is not a dead wait'

  # A worktree the write probe cannot walk reads as unknown, never quiet.
  if [ "$(id -u)" != 0 ]; then
    new_task "$h" ur
    mkdir "$h/wt-ur/locked"
    chmod 000 "$h/wt-ur/locked"
    ticks "$h" ur "$B" $((B + 1800))
    chmod 755 "$h/wt-ur/locked"
    assert_equals 0 "$(rows "$h" ur would-act)" 'an unreadable worktree proves nothing quiet'
  fi

  # A descendant that keeps writing with almost no CPU is a working child.
  if [ -r /proc/self/io ]; then
    new_task "$h" io
    "$WRITER" "$h/io-out" </dev/null >/dev/null 2>&1 &
    AGENTS="$AGENTS $!"
    printf 'alive %s' "$!" > "$h/probe/io.agent"
    ticks "$h" io "$B" $((B + 1800))
    assert_equals 0 "$(rows "$h" io observe)" 'a descendant whose I/O moves vetoes the proof'
  fi

  # The crew-state reader's lock is held elsewhere: the read never waits, and holds.
  new_task "$h" lk
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 900' \
    "$h/state/.nm-status-snapshot.json.lock" </dev/null >/dev/null 2>&1 &
  AGENTS="$AGENTS $!"
  sleep 1
  ticks "$h" lk "$B" $((B + 1800))
  assert_equals 0 "$(rows "$h" lk would-act)" 'a held crew-state lock holds every rung'
  assert_no_actions 'waits and screens'
  assert_agents_alive 'waits and screens'
  pass 'healthy declared waits and blocked screens give no rung-3 or rung-4 rows'
}

test_unverified_wait_cap_cannot_be_renewed() {
  local h n
  h=$(new_home capwait)
  printf 'mode=observe\nactor=test\nunverified_wait_max_secs=600\n' > "$h/config/hung-ladder"
  # The same wait, re-stamped every minute.
  new_task "$h" rw
  n=$B
  while [ "$n" -le $((B + 1500)) ]; do
    printf 'paused: waiting on the release window [at=%s]\n' "$n" >> "$h/state/rw.status"
    tick "$h" rw "$n"
    n=$((n + 60))
  done
  assert_equals 1 "$(rows "$h" rw observe 0)" 'a re-stamped wait still runs out'
  case "$(reason_of "$h" rw would-act 1)" in *unverified-wait-cap*) ;; *) fail 'rung 1 names the wait cap' ;; esac
  ledger "$h" | awk -F'\t' '$4 == "rw" && $6 == "observe" { exit !($2 >= '"$((B + 600))"') }' \
    || fail 'the cap counts from the first sighting of the wait'
  # A wait with no stamp at all.
  new_task "$h" ns
  printf 'paused: waiting on the release window\n' >> "$h/state/ns.status"
  ticks "$h" ns "$B" $((B + 1500))
  assert_equals 1 "$(rows "$h" ns observe 0)" 'an unstamped wait runs out too'
  # Alternating the wait with a status line that says nothing new.
  local i=0
  new_task "$h" al
  n=$B
  while [ "$n" -le $((B + 1500)) ]; do
    if [ $((i % 2)) = 0 ]; then
      printf 'paused: waiting on the release window [at=%s]\n' "$n" >> "$h/state/al.status"
    else
      printf 'working: still waiting [at=%s]\n' "$n" >> "$h/state/al.status"
    fi
    tick "$h" al "$n"
    n=$((n + 60)) i=$((i + 1))
  done
  [ "$(rows "$h" al observe 0)" -ge 1 ] || fail 'alternating status lines buy no unlimited hold'
  ledger "$h" | awk -F'\t' '$4 == "al" && $6 == "alarm" && $11 ~ /status-drip/ { f = 1 } END { exit !f }' \
    || fail 'recurring status lines raise the drip alarm'
  # A live pid this user does not run is not the worker's own job.
  if [ "$(id -u)" != 0 ]; then
    new_task "$h" p1
    printf 'paused: waiting on pid=1 [at=%s]\n' "$B" >> "$h/state/p1.status"
    ticks "$h" p1 "$B" $((B + 1500))
    assert_equals 1 "$(rows "$h" p1 observe 0)" 'another user'"'"'s pid buys only the bounded hold'
    case "$(reason_of "$h" p1 would-act 1)" in *pid-not-own*) ;; *) fail 'rung 1 names the foreign pid' ;; esac
  fi
  assert_no_actions 'wait cap'
  pass 'the unverified-wait hold is capped from first sighting and cannot be renewed'
}

test_live_mode_refused_without_gate() {
  local h out rc before
  h="$TMP_ROOT/refuse"
  mkdir -p "$h/state" "$h/config" "$h/probe"
  new_task "$h" r1
  # set-mode with no approval: refused, nothing written anywhere.
  rc=0
  out=$(env -u FM_TASK_ID FM_HOME="$h" "$TEST_BASH" "$LADDER" set-mode steer --actor captain 2>&1) || rc=$?
  assert_equals 3 "$rc" 'a live mode without approval is refused'
  assert_contains "$out" 'nothing was changed' 'the refusal says nothing changed'
  [ ! -e "$h/config/hung-ladder" ] || fail 'the refused set-mode wrote no config'
  [ ! -e "$h/state/hung-ladder" ] || fail 'the refused set-mode created no state'
  # A hand-written live mode: the tick does nothing at all.
  printf 'mode=relaunch\nactor=someone\n' > "$h/config/hung-ladder"
  ticks "$h" r1 "$B" $((B + 1500))
  [ ! -e "$h/state/hung-ladder" ] || fail 'an unapproved live mode writes no ledger or state'
  # An existing observe ledger is left byte-identical.
  printf 'mode=observe\nactor=test\n' > "$h/config/hung-ladder"
  ticks "$h" r1 $((B + 1560)) $((B + 1800))
  before=$(ledger "$h" | fhl_test_sha)
  printf 'mode=interrupt\nactor=someone\n' > "$h/config/hung-ladder"
  ticks "$h" r1 $((B + 1860)) $((B + 2400))
  assert_equals "$before" "$(ledger "$h" | fhl_test_sha)" 'an unapproved raise leaves the ledger untouched'
  # A worker can never set the mode.
  rc=0
  printf 'mode=observe\nactor=test\n' > "$h/config/hung-ladder"
  out=$(env FM_TASK_ID=r1 FM_HOME="$h" "$TEST_BASH" "$LADDER" set-mode off --actor r1 2>&1) || rc=$?
  assert_equals 2 "$rc" 'a worker is refused'
  grep -qx 'mode=observe' "$h/config/hung-ladder" || fail 'the worker refusal changed nothing'
  # An approval that is readable by others is not owner-only.
  printf 'mode=steer\napproved_by=captain\napproved_at=%s\nledger_head=%s\n' "$B" \
    "$(ledger "$h" | tail -n 1 | awk -F'\t' '{ print $15 }')" > "$h/config/hung-ladder-approval"
  chmod 644 "$h/config/hung-ladder-approval"
  rc=0
  env -u FM_TASK_ID FM_HOME="$h" "$TEST_BASH" "$LADDER" set-mode steer --actor captain >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" 'an approval readable by others is refused'
  # A valid, bound approval is accepted, and still nothing live runs.
  chmod 600 "$h/config/hung-ladder-approval"
  out=$(env -u FM_TASK_ID FM_HOME="$h" "$TEST_BASH" "$LADDER" set-mode steer --actor captain 2>&1) \
    || fail 'a valid approval is accepted'
  assert_contains "$out" 'mode: observe' 'the effective mode stays observe'
  tick "$h" r1 $((B + 2460))
  case "$(ledger "$h" | awk -F'\t' '$6 == "mode" { r = $11 } END { print r }')" in
    *'configured=steer actor=captain why=approved-live-path-not-built'*) ;;
    *) fail 'a mode change is a ledger row with its actor' ;;
  esac
  printf 'mode=steer\napproved_by=captain\napproved_at=%s\nledger_head=%064d\n' "$B" 7 > "$h/config/hung-ladder-approval"
  chmod 600 "$h/config/hung-ladder-approval"
  rc=0
  env -u FM_TASK_ID FM_HOME="$h" "$TEST_BASH" "$LADDER" set-mode steer --actor captain >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" 'an approval not bound to a ledger row is refused'
  assert_no_actions 'mode gate'
  assert_agents_alive 'mode gate'
  pass 'a live mode without the owner approval gate is refused with zero side effects'
}

fhl_test_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | awk '{ print $1 }'; }

test_chain_and_escaping() {
  local h before out rc
  h=$(new_home chain)
  new_task "$h" e1
  # A dead wait whose text carries tabs that try to forge ledger fields.
  printf 'paused: waiting pid=999999\t7\tforged\t4\twould-act [at=%s]\n' "$B" >> "$h/state/e1.status"
  ticks "$h" e1 "$B" $((B + 600))
  assert_equals 0 "$(ledger "$h" | awk -F'\t' 'NF != 15 { n++ } END { print n + 0 }')" 'every row keeps exactly 15 fields'
  assert_equals 0 "$(rows "$h" forged would-act)" 'no row was forged for another task'
  case "$(reason_of "$h" e1 would-act 1)" in *'pid=999999\t7\tforged'*) ;; *) fail 'tabs in recorded text are escaped' ;; esac
  # A task id that is not a slug is refused before anything is written.
  rc=0
  printf 'x' | env -u FM_TASK_ID FM_HOME="$h" "$TEST_BASH" "$LADDER" tick --task $'e1\tforged' --kind ship 2>/dev/null || rc=$?
  assert_equals 2 "$rc" 'a task id that is not a slug is refused'
  verify "$h" >/dev/null || fail 'the untouched chain verifies'
  # Editing a row breaks the chain and stops further appends.
  cp "$h/state/hung-ladder/actions.tsv" "$TMP_ROOT/chain-backup.tsv"
  perl -i -pe 's/^2\t(\d+)/2\t1$1/ if $. == 2' "$h/state/hung-ladder/actions.tsv"
  rc=0
  out=$(verify "$h") || rc=$?
  assert_equals 3 "$rc" 'an edited row is detected'
  assert_contains "$out" 'line 2 hash does not recompute' 'verify names the edited row'
  # Removing the last row is detected at the next append, which refuses.
  cp "$TMP_ROOT/chain-backup.tsv" "$h/state/hung-ladder/actions.tsv"
  perl -i -ne 'print unless eof' "$h/state/hung-ladder/actions.tsv"
  before=$(ledger "$h" | fhl_test_sha)
  progress "$h" e1 $((B + 660)) 'working: resumed'
  tick "$h" e1 $((B + 660)) 2>/dev/null
  assert_equals "$before" "$(ledger "$h" | fhl_test_sha)" 'a truncated ledger takes no new rows'
  [ -s "$h/state/hung-ladder/ledger-refused" ] || fail 'the refusal is recorded'
  rc=0
  verify "$h" >/dev/null || rc=$?
  assert_equals 3 "$rc" 'verify reports the truncation'
  # A spoofed row appended with a made-up hash is detected.
  cp "$TMP_ROOT/chain-backup.tsv" "$h/state/hung-ladder/actions.tsv"
  printf '%s\t%s\thl-x\te1\t4\twould-act\tobserve\t-\t-\t-\tforged\t-\tpending\t%064d\t%064d\n' 99 "$B" 0 0 >> "$h/state/hung-ladder/actions.tsv"
  rc=0
  verify "$h" >/dev/null || rc=$?
  assert_equals 3 "$rc" 'a spoofed row is detected'
  # Emptying the ledger while its head record stays is a deletion.
  : > "$h/state/hung-ladder/actions.tsv"
  rc=0
  verify "$h" >/dev/null || rc=$?
  assert_equals 3 "$rc" 'an emptied ledger is reported broken'

  # An edit to an earlier row holds rung 4, whose caps read that history.
  local h2
  h2=$(new_home chain-history)
  new_task "$h2" e2
  ticks "$h2" e2 "$B" $((B + 1380))
  assert_equals 1 "$(rows "$h2" e2 would-act 3)" 'the episode reached rung 3'
  perl -i -pe 's/\tepisode-open /\tepisode-0pen / if $. == 2' "$h2/state/hung-ladder/actions.tsv"
  ticks "$h2" e2 $((B + 1440)) $((B + 1500))
  assert_equals 0 "$(rows "$h2" e2 would-act 4)" 'rung 4 never reads an edited history'
  assert_equals 1 "$(rows "$h2" e2 hold)" 'the hold is recorded once'
  ledger "$h2" | grep -q 'ledger-unverified' || fail 'the hold names the broken chain'

  # A skip list that others can write is not trusted.
  local h3
  h3=$(new_home chain-skip)
  new_task "$h3" k1
  printf 'k1\n' > "$h3/config/hung-ladder-skip"
  chmod 666 "$h3/config/hung-ladder-skip"
  tick "$h3" k1 "$B"
  [ -s "$h3/state/hung-ladder/episodes/k1.sample" ] || fail 'a skip list others can write does not skip'
  chmod 644 "$h3/config/hung-ladder-skip"
  rm -f "$h3/state/hung-ladder/episodes/k1.sample"
  tick "$h3" k1 $((B + 60))
  [ ! -e "$h3/state/hung-ladder/episodes/k1.sample" ] || fail 'an owner-only skip list skips'
  assert_no_actions 'chain'
  pass 'the hash chain and field escaping expose spoofed, edited, and removed rows'
}

test_snapshots_redact_and_exclude_secrets() {
  local h snap rc
  h=$(new_home secrets)
  new_task "$h" s1
  printf 'API_KEY=supersecretvalue\n' > "$h/wt-s1/.env"
  printf 'cache/\n' > "$h/wt-s1/.gitignore"
  mkdir -p "$h/wt-s1/cache"
  printf 'API_KEY=ignoredsecretvalue\n' > "$h/wt-s1/cache/.env"
  printf 'data\n' > "$h/wt-s1/cache/data.txt"
  printf 'TOKEN=first\n' > "$h/wt-s1/private key.env"
  printf 'TOKEN=first\n' > "$h/wt-s1/clé-secret.txt"
  git -C "$h/wt-s1" add 'private key.env' 'clé-secret.txt'
  git -C "$h/wt-s1" -c user.name=t -c user.email=t@example.invalid commit -qm secrets
  printf 'TOKEN=quotedsecretvalue\n' > "$h/wt-s1/private key.env"
  printf 'TOKEN=quotedsecretvalue\n' > "$h/wt-s1/clé-secret.txt"
  printf 'change\n' >> "$h/wt-s1/README.md"
  PANE_STYLE=token ticks "$h" s1 "$B" $((B + 1440))
  assert_equals 1 "$(rows "$h" s1 would-act 4)" 'the episode reached rung 4'
  snap=$(find "$h/state/hung-ladder/snapshots/s1" -name '*.pane' | head -n 1)
  [ -n "$snap" ] || fail 'pane text was saved'
  ! grep -q 'ghp_abcdefghijklmnopqrstuvwxyz0123' "$snap" || fail 'tokens are removed from saved pane text'
  grep -q 'gh_\[REDACTED\]' "$snap" || fail 'the redaction is visible'
  snap=$(find "$h/state/hung-ladder/snapshots/s1" -name '*.tree' | head -n 1)
  grep -q '^present-secret	.env$' "$snap" || fail 'a secret-pattern file is recorded as present'
  ! grep -rq supersecretvalue "$h/state/hung-ladder" || fail 'secret file content is never saved'
  ! grep -rq quotedsecretvalue "$h/state/hung-ladder" || fail 'a secret file whose name Git quotes is still left out'
  grep -q '^present-secret	private key.env$' "$snap" || fail 'a quoted secret path is recorded as present'
  grep -q '^present-secret	clé-secret.txt$' "$snap" || fail 'a non-ASCII secret path is recorded as present'
  grep -q 'README.md' "$snap" || fail 'an ordinary dirty file is hashed'
  grep -q '^present-ignored	cache/.env$' "$snap" || fail 'each ignored file is recorded, not only its directory'
  grep -q '^present-ignored	cache/data.txt$' "$snap" || fail 'every ignored file is recorded as present'
  ! grep -rq ignoredsecretvalue "$h/state/hung-ladder" || fail 'ignored file content is never saved'
  assert_equals "600" "$(perm_of "$snap")" 'snapshots are owner-only'
  ! ledger "$h" | grep -q 'API_KEY' || fail 'patch bodies never reach the ledger'
  rm -f "$h/state/s1.meta"
  rc=0
  env FM_TASK_ID=s1 FM_HOME="$h" "$TEST_BASH" "$LADDER" prune 2>/dev/null || rc=$?
  assert_equals 2 "$rc" 'a worker cannot prune'
  [ -e "$h/state/hung-ladder/snapshots/s1" ] || fail 'the refused prune removed nothing'
  env -u FM_TASK_ID FM_HOME="$h" "$TEST_BASH" "$LADDER" prune || fail 'prune runs'
  [ ! -e "$h/state/hung-ladder/snapshots/s1" ] || fail 'snapshots go with task cleanup'
  assert_no_actions 'snapshots'
  pass 'snapshots redact tokens, leave secret contents out, and go with task cleanup'
}

test_mode_off_and_absent_do_nothing() {
  local h
  h="$TMP_ROOT/off"
  mkdir -p "$h/state" "$h/config" "$h/probe"
  new_task "$h" o1
  ticks "$h" o1 "$B" $((B + 600))
  [ ! -e "$h/state/hung-ladder" ] || fail 'an absent config means off'
  assert_contains "$(env FM_HOME="$h" "$TEST_BASH" "$LADDER" mode)" 'mode: off' 'mode reports off by default'
  printf 'mode=off\n' > "$h/config/hung-ladder"
  ticks "$h" o1 $((B + 660)) $((B + 1200))
  [ ! -e "$h/state/hung-ladder" ] || fail 'mode off writes nothing'
  pass 'an absent config or mode off observes nothing'
}

fm_test_run \
  test_observe_rungs_and_self_progress \
  test_death_resolves_no \
  test_caps_hold_escalations \
  test_breaker_formula_and_load \
  test_healthy_waits_and_screens \
  test_unverified_wait_cap_cannot_be_renewed \
  test_live_mode_refused_without_gate \
  test_chain_and_escaping \
  test_snapshots_redact_and_exclude_secrets \
  test_mode_off_and_absent_do_nothing
