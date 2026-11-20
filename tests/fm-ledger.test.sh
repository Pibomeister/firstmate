#!/usr/bin/env bash
# tests/fm-ledger.test.sh - bin/fm-ledger.sh reads the home's real tasks-axi
# backlog as the mission ledger: intake files each approved proposal or order
# as its own item, plan and next show the per-project plan and the next ready
# item without changing anything, depth reports thin ready queues once per
# scheduled time, and handoff writes a self-contained document from the ledger
# plus a short in-flight note, refusing delta chains and unfiled orders.
# Opt-in claims cover concurrent spawn, changed authority and crash recovery.
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

LEDGER="$ROOT/bin/fm-ledger.sh"
TASKS="$ROOT/bin/fm-tasks-axi.sh"
ORDER="$ROOT/bin/fm-order.sh"
DISPATCH="$ROOT/bin/fm-dispatch-log.sh"
TMP_ROOT=$(fm_test_tmproot fm-ledger)
SLOT_1700=1794416400 # 2026-11-11T17:00:00Z

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_DATA_OVERRIDE \
  FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_NOW FM_TEST_SEAM

if ! command -v tasks-axi >/dev/null 2>&1; then
  printf '1..0 # SKIP tasks-axi is not installed\n'
  exit 0
fi

HOME_DIR=
new_home() {  # <name>: a fresh home with an empty backlog, checks in UTC
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  printf 'quiet-hours-zone=UTC\n' > "$HOME_DIR/config/escalation"
}

ledger() { FM_HOME="$HOME_DIR" bash "$LEDGER" "$@"; }
ledger_at() { local now=$1; shift; FM_HOME="$HOME_DIR" FM_TEST_SEAM=1 FM_NOW="$now" bash "$LEDGER" "$@"; }
tasks() { FM_HOME="$HOME_DIR" bash "$TASKS" "$@"; }
order() { FM_HOME="$HOME_DIR" bash "$ORDER" "$@"; }

# A small fleet: alpha has one in-flight, three ready (priorities 2, -, 0), one
# blocked, and one held item; beta has only a held item (parked); gamma has
# one ready item; and one ready item has no project.
seed_fleet() {
  tasks add a-fly "alpha in flight" --repo alpha --queue >/dev/null || fail "seed add failed"
  tasks start a-fly >/dev/null || fail "seed start failed"
  tasks add a-two "alpha priority two" --repo alpha --priority 2 >/dev/null
  tasks add a-none "alpha no priority" --repo alpha >/dev/null
  tasks add a-zero "alpha priority zero" --repo alpha --priority 0 >/dev/null
  tasks add a-wait "alpha waits on a-fly" --repo alpha --blocked-by a-fly >/dev/null
  tasks add a-held "alpha held" --repo alpha >/dev/null
  tasks hold a-held --reason "captain call" >/dev/null
  tasks add b-held "beta held" --repo beta >/dev/null
  tasks hold b-held --reason "captain call" >/dev/null
  tasks add g-one "gamma ready" --repo gamma >/dev/null
  tasks add loose "no project" >/dev/null
}

test_intake_files_one_item_per_ask_and_replays() {
  new_home intake
  local out rc oid
  out=$(ledger intake --mint --project alpha --title "Build the ledger" --source proposal:velocity-S2 --priority 1) \
    || fail "intake refused a well-formed proposal: $out"
  case "$out" in "filed "*" project=alpha source=proposal:velocity-S2") ;; *) fail "unexpected intake output: $out" ;; esac
  local id=${out#filed }
  id=${id%% *}
  out=$(tasks show "$id" --full)
  assert_contains "$out" "state: queued" "the filed item is queued"
  assert_contains "$out" "repo: alpha" "the filed item carries its project"
  assert_contains "$out" "priority: 1" "the filed item carries its priority"
  assert_contains "$out" "Ledger source: proposal:velocity-S2" "the body names the source"
  out=$(ledger intake --mint --project alpha --title "Build the ledger" --source proposal:velocity-S2)
  expect_code 0 $? "a replayed intake"
  [ "$out" = "replay $id" ] || fail "a retry filed again instead of replaying: $out"
  [ "$(grep -c "" "$HOME_DIR/data/ledger-intake.tsv")" = 1 ] || fail "a replay appended an intake record"

  oid=$(order send --from test -- "ship widget and fix gadget" | awk '/^queued / { print $2 }')
  [ -n "$oid" ] || fail "could not send a test order"
  ledger intake w-1 --project alpha --title "Ship widget" --source "order:$oid" >/dev/null || fail "first ask of the order was refused"
  ledger intake g-1 --project beta --title "Fix gadget" --source "order:$oid" >/dev/null || fail "second ask of the order was refused"
  tasks show w-1 >/dev/null || fail "one order with two asks did not become two items (w-1)"
  tasks show g-1 >/dev/null || fail "one order with two asks did not become two items (g-1)"
  out=$(ledger intake w-3 --project alpha --title "Widget follow-up" --source ask:chat --blocked-by w-1 --body "after the widget") \
    || fail "intake with a dependency was refused: $out"
  out=$(tasks show w-3 --full)
  assert_contains "$out" "blocked_by: w-1" "intake passes the dependency through"
  assert_contains "$out" "after the widget" "intake keeps the given body after the source line"

  out=$(ledger intake --mint --project alpha --title x --source order:1-deadbeef 2>&1); rc=$?
  expect_code 1 "$rc" "intake from a missing order"
  assert_contains "$out" "no captain order 1-deadbeef" "the refusal names the missing order"
  out=$(ledger intake --mint --project alpha --title x --source rumor:x 2>&1); rc=$?
  expect_code 2 "$rc" "intake from an unknown source kind"
  out=$(ledger intake --mint --project alpha --title x --source goal:nope 2>&1); rc=$?
  expect_code 1 "$rc" "intake from a goal the dispatch ledger lacks"
  [ "$(grep -c "" "$HOME_DIR/data/ledger-intake.tsv")" = 4 ] || fail "a refused intake wrote an intake record"
  pass "intake files each ask as its own queued item, replays retries, and refuses unknown sources"
}

test_intake_replay_key_and_existing_ids() {
  new_home intake-key
  local out rc rows
  ledger intake s-a --project alpha --title "Share the widget" --source ask:chat >/dev/null || fail "first intake refused"
  out=$(ledger intake s-b --project beta --title "Share the widget" --source ask:chat) \
    || fail "the same ask for another project was refused: $out"
  [ "$out" = "filed s-b project=beta source=ask:chat" ] || fail "the same ask for another project replayed instead of filing: $out"
  out=$(ledger intake s-c --project alpha --title "Share the widget" --source ask:chat) \
    || fail "the same ask under another explicit id was refused: $out"
  [ "$out" = "filed s-c project=alpha source=ask:chat" ] || fail "an explicit new id replayed an item with another id: $out"
  out=$(ledger intake s-a --project alpha --title "Share the widget" --source ask:chat)
  [ "$out" = "replay s-a" ] || fail "an exact retry did not replay: $out"
  out=$(ledger intake --mint --project alpha --title 'Escape a\tb\\c' --source ask:chat) || fail "a title with backslashes was refused: $out"
  local bid=${out#filed }
  bid=${bid%% *}
  out=$(ledger intake --mint --project alpha --title 'Escape a\tb\\c' --source ask:chat)
  [ "$out" = "replay $bid" ] || fail "a retry of a title with backslashes did not replay: $out"

  tasks add taken "someone else's item" --repo alpha >/dev/null || fail "seed add failed"
  rows=$(grep -c "" "$HOME_DIR/data/ledger-intake.tsv")
  out=$(ledger intake taken --project alpha --title "A new ask" --source ask:chat 2>&1); rc=$?
  expect_code 1 "$rc" "intake under an id that already names an item"
  assert_contains "$out" "item taken already exists" "the refusal names the existing item"
  [ "$(grep -c "" "$HOME_DIR/data/ledger-intake.tsv")" = "$rows" ] || fail "a refused intake wrote an intake record"
  out=$(tasks show taken --full)
  assert_contains "$out" "title: someone else's item" "a refused intake left the existing item unchanged"

  # An intake that filed its item but stopped before writing its record.
  rm -f "$HOME_DIR/data/ledger-intake.tsv"
  out=$(ledger intake s-a --project alpha --title "Share the widget" --source ask:chat) \
    || fail "a retry after a lost intake record was refused: $out"
  [ "$out" = "replay s-a" ] || fail "a retry after a lost intake record did not replay: $out"
  assert_contains "$(cat "$HOME_DIR/data/ledger-intake.tsv")" "s-a" "the replay rewrote the lost intake record"
  pass "intake replays only the same source, project, title, and id, and refuses an id that names another item"
}

test_plan_groups_orders_and_marks_short() {
  new_home plan
  seed_fleet
  local out
  out=$(ledger plan) || fail "plan failed: $out"
  out=$(printf '%s\n' "$out" | sed 1d)
  local want
  want=$(cat <<'EOF'
project alpha active ready=3 in_flight=1 blocked=1 held=1
  in_flight a-fly  kind=task priority=-  alpha in flight
  ready     a-zero  kind=task priority=0  alpha priority zero
  ready     a-two  kind=task priority=2  alpha priority two
  ready     a-none  kind=task priority=-  alpha no priority
  blocked   a-wait  kind=task priority=-  alpha waits on a-fly
  held      a-held  kind=task priority=-  alpha held
project beta parked ready=0 in_flight=0 blocked=0 held=1
  held      b-held  kind=task priority=-  beta held
project gamma active ready=1 in_flight=0 blocked=0 held=0 SHORT
  ready     g-one  kind=task priority=-  gamma ready
project - active ready=1 in_flight=0 blocked=0 held=0
  ready     loose  kind=task priority=-  no project
EOF
)
  [ "$out" = "$want" ] || fail "plan output differs:"$'\n'"$out"
  out=$(ledger plan --limit 1 --project alpha | sed 1d)
  want=$(cat <<'EOF'
project alpha active ready=3 in_flight=1 blocked=1 held=1
  in_flight a-fly  kind=task priority=-  alpha in flight
  ready     a-zero  kind=task priority=0  alpha priority zero
  (2 more ready)
  blocked: a-wait
  held: a-held
EOF
)
  [ "$out" = "$want" ] || fail "compact plan output differs:"$'\n'"$out"
  local long
  long=$(printf 'long title %.0s' $(seq 1 12))
  tasks add g-long "$long" --repo gamma >/dev/null || fail "seed add failed"
  out=$(ledger plan --limit 3 --project gamma | grep 'g-long')
  [ "$(printf '%s' "$out" | grep -o 'truncate' | grep -c '')" = 1 ] \
    || fail "a long title is cut more than once in the compact plan: $out"
  case "$out" in *' [truncated]') ;; *) fail "a long title does not end in one cut note: $out" ;; esac
  pass "plan groups each project's items by in flight, ready by priority, blocked, and held, and marks short projects"
}

test_next_is_read_only_and_exits_3_when_empty() {
  new_home next
  seed_fleet
  local before out rc
  before=$(cat "$HOME_DIR/data/backlog.md")
  out=$(ledger next) || fail "next failed: $out"
  assert_contains "$out" "NEXT a-zero project=alpha kind=task priority=0" "next picks the highest-priority ready item"
  assert_contains "$out" "title: alpha priority zero" "next prints the full item"
  out=$(ledger next --project gamma)
  assert_contains "$out" "NEXT g-one project=gamma" "next honors --project"
  out=$(ledger next --project beta); rc=$?
  expect_code 3 "$rc" "next for a project with nothing ready"
  assert_contains "$out" "nothing ready for project beta" "next says nothing is ready"
  [ "$(cat "$HOME_DIR/data/backlog.md")" = "$before" ] || fail "next changed the backlog"
  [ ! -e "$HOME_DIR/data/ledger-intake.tsv" ] || fail "next wrote an intake record"
  pass "next prints the next ready item without changing the ledger and exits 3 when nothing is ready"
}

test_depth_reports_short_active_projects() {
  new_home depth
  seed_fleet
  local out rc
  out=$(ledger depth); rc=$?
  expect_code 3 "$rc" "depth with a short project"
  [ "$out" = "SHORT gamma ready=1 min=3 in_flight=0 blocked=0 held=0" ] \
    || fail "depth must report only gamma (beta is parked and the unnamed project is never short): $out"
  printf 'exclude=gamma\n' > "$HOME_DIR/config/mission-ledger"
  out=$(ledger depth); rc=$?
  expect_code 3 "$rc" "depth with an unsupported exclude line"
  assert_contains "$out" "SHORT gamma ready=1" "every active project is checked; no project can be skipped"
  printf 'min-ready=4\nmin-ready=junk\n' > "$HOME_DIR/config/mission-ledger"
  out=$(ledger depth); rc=$?
  expect_code 3 "$rc" "depth with a higher target"
  assert_contains "$out" "SHORT alpha ready=3 min=4" "a configured target applies and an unusable value keeps it"
  pass "depth reports every active project below the ready target"
}

test_done_items_are_history_not_work() {
  new_home done-only
  local out rc
  tasks add z-done "zeta finished" --repo zeta >/dev/null || fail "seed add failed"
  tasks start z-done >/dev/null || fail "seed start failed"
  tasks 'done' z-done >/dev/null || fail "seed done failed"
  out=$(ledger plan) || fail "plan failed: $out"
  case "$out" in *zeta* | *z-done*) fail "plan lists a project whose only item is done: $out" ;; esac
  out=$(ledger depth); rc=$?
  expect_code 0 "$rc" "depth with only a done item"
  case "$out" in *zeta*) fail "depth reports a project whose only item is done: $out" ;; esac
  pass "done items are not counted as active or blocked work"
}

# fake_tasks_axi <mode>: put a tasks-axi first on PATH that runs the real one,
# then for `ready` appends a public-followup table naming a-wait (mode
# followups), or fails every call (mode broken).
FAKE_BIN=
fake_tasks_axi() {
  local real
  real=$(command -v tasks-axi)
  FAKE_BIN="$TMP_ROOT/fake-bin-$1"
  mkdir -p "$FAKE_BIN"
  case "$1" in
    followups)
      cat > "$FAKE_BIN/tasks-axi" <<EOF
#!/usr/bin/env bash
"$real" "\$@" || exit \$?
[ "\${1:-}" = ready ] || exit 0
printf 'ready_public_followups[1]{id,state,kind,repo,title}:\n  a-wait,ready,followup,alpha,promised final reply\n'
EOF
      ;;
    broken)
      printf '#!/usr/bin/env bash\necho "backlog unavailable" >&2\nexit 1\n' > "$FAKE_BIN/tasks-axi"
      ;;
  esac
  chmod +x "$FAKE_BIN/tasks-axi"
}

test_public_followups_are_not_ready_work() {
  new_home followups
  seed_fleet
  fake_tasks_axi followups
  local out
  out=$(PATH="$FAKE_BIN:$PATH" ledger plan --project alpha) || fail "plan failed: $out"
  assert_contains "$out" "blocked   a-wait" "a public follow-up row does not make a blocked item ready"
  assert_contains "$out" "project alpha active ready=3 in_flight=1 blocked=1 held=1" "public follow-ups are not counted as ready"
  pass "public-followup obligations in the ready listing are never counted as ready work"
}

test_failed_scheduled_evaluation_is_retried() {
  new_home retry
  seed_fleet
  fake_tasks_axi broken
  local out
  out=$(PATH="$FAKE_BIN:$PATH" ledger_at $((SLOT_1700 + 60)) depth --scheduled)
  assert_contains "$out" "ready-depth 17:00: the depth check failed" "a failed evaluation is reported"
  [ ! -e "$HOME_DIR/state/.ready-depth-slot" ] || fail "a failed evaluation recorded the slot"
  out=$(PATH="$FAKE_BIN:$PATH" ledger_at $((SLOT_1700 + 120)) depth --scheduled)
  [ -z "$out" ] || fail "the same failure was reported twice: $out"
  out=$(ledger_at $((SLOT_1700 + 180)) depth --scheduled)
  assert_contains "$out" "ready-depth 17:00: 1 active project(s) below 3 ready: gamma(ready=1)" "the next sweep retries the slot"
  [ "$(cat "$HOME_DIR/state/.ready-depth-slot")" = "$SLOT_1700" ] || fail "the completed evaluation did not record the slot"
  pass "a failed scheduled evaluation is reported once and retried on the next sweep"
}

test_scheduled_depth_fires_once_per_slot() {
  new_home scheduled
  seed_fleet
  local out
  out=$(ledger_at $((SLOT_1700 - 60)) depth --scheduled)
  [ -z "$out" ] || fail "the check spoke before 17:00 for a slot older than the grace window: $out"
  out=$(ledger_at $((SLOT_1700 + 300)) depth --scheduled)
  [ "$out" = "ready-depth 17:00: 1 active project(s) below 3 ready: gamma(ready=1); refill each ready queue (bin/fm-ledger.sh plan)" ] \
    || fail "unexpected 17:00 wake line: $out"
  out=$(ledger_at $((SLOT_1700 + 600)) depth --scheduled)
  [ -z "$out" ] || fail "the 17:00 slot fired twice: $out"
  out=$(ledger_at $((SLOT_1700 + 6 * 3600 + 60)) depth --scheduled)
  assert_contains "$out" "ready-depth 23:00:" "the 23:00 slot fires"
  rm -f "$HOME_DIR/state/.ready-depth-slot"
  out=$(ledger_at $((SLOT_1700 + 13 * 3600)) depth --scheduled)
  [ -z "$out" ] || fail "a slot more than 6 hours old fired: $out"
  printf 'at=09:15\n' > "$HOME_DIR/config/mission-ledger"
  rm -f "$HOME_DIR/state/.ready-depth-slot"
  out=$(ledger_at $((SLOT_1700 - 7 * 3600 + 15 * 60)) depth --scheduled)
  [ -z "$out" ] || fail "the check times are fixed at 17:00 and 23:00, but an at= line moved them: $out"
  printf 'min-ready=0\n' > "$HOME_DIR/config/mission-ledger"
  rm -f "$HOME_DIR/state/.ready-depth-slot"
  out=$(ledger_at $((SLOT_1700 + 60)) depth --scheduled)
  [ -z "$out" ] || fail "min-ready=0 still reported: $out"
  rm -f "$HOME_DIR/config/mission-ledger"
  printf 'quiet-hours-zone=Nowhere/Atlantis\n' > "$HOME_DIR/config/escalation"
  out=$(ledger_at $((SLOT_1700 + 60)) depth --scheduled)
  assert_contains "$out" "could not compute the scheduled times in zone Nowhere/Atlantis" "an unknown zone is reported"
  out=$(ledger_at $((SLOT_1700 + 120)) depth --scheduled)
  [ -z "$out" ] || fail "the same zone failure was reported twice: $out"
  pass "the scheduled check reports a thin ready queue once per check time in the captain's zone"
}

test_unfiled_lists_open_orders_without_items() {
  new_home unfiled
  local out rc filed mentioned loose tricky short
  out=$(ledger unfiled); rc=$?
  expect_code 0 "$rc" "unfiled with no orders"
  filed=$(order send --from test -- "filed through intake" | awk '/^queued / { print $2 }')
  mentioned=$(order send --from test -- "filed before the ledger" | awk '/^queued / { print $2 }')
  loose=$(order send --from test -- "never filed" | awk '/^queued / { print $2 }')
  order send --hold --from test -- "hold merges" >/dev/null
  tricky=$(order send --from test -- "summary says kind=hold" | awk '/^queued / { print $2 }')
  ledger intake --mint --project alpha --title "filed through intake" --source "order:$filed" >/dev/null || fail "intake failed"
  tasks add old-item "old item for order $mentioned" --repo alpha >/dev/null
  short=$(order send --from test -- "named by its short hash" | awk '/^queued / { print $2 }')
  tasks add short-item "item for order ${short##*-}" --repo alpha >/dev/null
  out=$(ledger unfiled); rc=$?
  expect_code 3 "$rc" "unfiled with one unfiled order"
  # Orders sent in the same second sort by their random id suffix, so compare as a set.
  [ "$(printf '%s\n' "$out" | LC_ALL=C sort)" = "$(printf '%s\n' "UNFILED $loose pending :: never filed" "UNFILED $tricky pending :: summary says kind=hold" | LC_ALL=C sort)" ] \
    || fail "unfiled must list only the never-filed orders, whatever their summary says: $out"
  pass "unfiled lists only open orders that no ledger item records"
}

test_handoff_writes_from_ledger_and_refuses_chains() {
  new_home handoff
  seed_fleet
  local out rc oid doc="$HOME_DIR/data/handoff-next.md"
  oid=$(order send --from test -- "build the night queue" | awk '/^queued / { print $2 }')
  FM_HOME="$HOME_DIR" bash "$DISPATCH" received alpha-202611111700 --summary "night queue" --project alpha >/dev/null

  out=$(ledger handoff --doc "$doc" --note "a-fly is building" 2>&1); rc=$?
  expect_code 3 "$rc" "handoff with an unfiled order"
  assert_contains "$out" "UNFILED $oid" "the refusal names the unfiled order"
  [ ! -e "$doc" ] || fail "a refused handoff wrote the document"
  ledger intake --mint --project alpha --title "build the night queue" --source "order:$oid" >/dev/null || fail "intake failed"

  out=$(ledger handoff --doc "$doc" --note "continue from data/handoff-20261111T1405Z.md" 2>&1); rc=$?
  expect_code 1 "$rc" "handoff whose note names an earlier handoff"
  assert_contains "$out" "never continues another one" "the refusal explains the delta chain"
  out=$(seq 1 61 | ledger handoff --doc "$doc" --note-file - 2>&1); rc=$?
  expect_code 1 "$rc" "handoff with an oversized note"
  out=$(ledger handoff --doc "$doc" --note "   " 2>&1); rc=$?
  expect_code 1 "$rc" "handoff with an empty note"
  [ ! -e "$doc" ] || fail "a refused handoff wrote the document"

  out=$(ledger handoff --doc "$doc" --note "a-fly is building; its PR is not open yet") || fail "handoff failed: $out"
  out=$(cat "$doc")
  assert_contains "$out" "never continues an earlier handoff" "the document says it stands alone"
  assert_contains "$out" "a-fly is building; its PR is not open yet" "the document carries the in-flight note"
  assert_contains "$out" "project alpha active ready=4 in_flight=1 blocked=1 held=1" "the document carries the ledger plan"
  assert_contains "$out" "OPEN alpha-202611111700 event=received" "the document lists open captain goals"
  assert_contains "$out" "$oid" "the document lists the open captain order"
  FM_HOME="$HOME_DIR" bash "$ORDER" gate >/dev/null || fail "the order gate does not accept the ledger handoff"
  out=$(ledger handoff --doc "$doc" --note x 2>&1); rc=$?
  expect_code 1 "$rc" "handoff over an existing document"
  pass "handoff writes a self-contained document from the ledger and refuses unfiled orders and delta chains"
}

test_arm_registers_the_scheduled_check() {
  new_home arm
  seed_fleet
  local out
  out=$(ledger arm) || fail "arm failed: $out"
  [ -x "$HOME_DIR/state/ready-depth.check.sh" ] || fail "arm did not install an executable check"
  [ -e "$HOME_DIR/state/ready-depth.check-trust" ] || fail "arm did not register the check"
  out=$(FM_TEST_SEAM=1 FM_NOW=$((SLOT_1700 + 60)) "$HOME_DIR/state/ready-depth.check.sh")
  assert_contains "$out" "ready-depth 17:00: 1 active project(s)" "the installed check runs the scheduled depth check"
  printf 'min-ready=0\n' > "$HOME_DIR/config/mission-ledger"
  ledger arm --if-enabled >/dev/null || fail "arm --if-enabled failed"
  [ ! -e "$HOME_DIR/state/ready-depth.check.sh" ] && [ ! -e "$HOME_DIR/state/ready-depth.check-trust" ] \
    || fail "arm --if-enabled with min-ready=0 left the check armed"
  pass "arm installs and registers the scheduled check, and min-ready=0 disarms it"
}

test_arm_never_replaces_a_task_check_of_the_same_name() {
  new_home arm-owner
  local out rc monitor="$HOME_DIR/state/ready-depth.check.sh" before
  ledger arm >/dev/null || fail "first arm failed"
  ledger arm >/dev/null || fail "re-arming the ledger's own check failed"
  ledger disarm >/dev/null || fail "disarm failed"
  # A worker task whose id is ready-depth owns the same path for its PR monitor.
  printf '#!/usr/bin/env bash\necho "PR monitor for task ready-depth"\n' > "$monitor"
  chmod 700 "$monitor"
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-check-register.sh" ready-depth >/dev/null || fail "could not register the task check"
  before=$(cat "$monitor" "$HOME_DIR/state/ready-depth.check-trust")
  out=$(ledger arm 2>&1); rc=$?
  expect_code 1 "$rc" "arm over a task's check of the same name"
  assert_contains "$out" "is not the mission ledger's check" "the refusal says the check belongs to something else"
  out=$(ledger arm --if-enabled 2>&1); rc=$?
  expect_code 1 "$rc" "session-start arming over a task's check of the same name"
  printf 'min-ready=0\n' > "$HOME_DIR/config/mission-ledger"
  ledger arm --if-enabled >/dev/null 2>&1 || fail "arm --if-enabled with min-ready=0 failed over a task check"
  ledger disarm >/dev/null 2>&1 || fail "disarm failed over a task check"
  [ "$(cat "$monitor" "$HOME_DIR/state/ready-depth.check-trust")" = "$before" ] \
    || fail "the ledger replaced or removed a task's check of the same name"
  pass "arm and disarm never replace or remove a task's check that shares the ready-depth name"
}

test_claim_reserves_once_and_resumes() {
  new_home claim
  local out rc token
  ledger intake claim-one --project alpha --title 'approved work' --source proposal:V12 >/dev/null
  mkdir -p "$HOME_DIR/projects/alpha" "$HOME_DIR/data/claim-one"
  printf 'approved brief\n' > "$HOME_DIR/data/claim-one/brief.md"
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 1 "$rc" 'claim is off by default'
  printf 'claim-project=alpha\n' > "$HOME_DIR/config/mission-ledger"
  out=$(ledger claim --project alpha) || fail "claim failed: $out"
  assert_contains "$out" 'CLAIM claim-one project=alpha phase=reserved token=' 'claim returns a reservation'
  token=${out##*token=}
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 3 "$rc" 'a reserved item is not claimable again'
  out=$(ledger claim --project alpha --resume claim-one) || fail "resume failed: $out"
  assert_contains "$out" "token=$token" 'lost claim response reuses the same token'
  tasks hold claim-one --reason 'new decision' >/dev/null
  out=$(ledger claim --project alpha --resume claim-one 2>&1); rc=$?
  expect_code 1 "$rc" 'a changed hold refuses recovery'
  pass 'claim is opt-in, exclusive and resumable without replacing its identity'
}

claim_fixture() {
  new_home "$1"
  mkdir -p "$HOME_DIR/projects/alpha"
  printf 'claim-project=alpha\n' > "$HOME_DIR/config/mission-ledger"
  ledger intake claim-one --project alpha --title 'approved work' --source proposal:V12 >/dev/null || fail 'intake failed'
  fm_test_spawn_brief "$HOME_DIR" claim-one
}

test_claim_refusals_and_changed_approval() {
  local variant out rc token
  for variant in brief scope dependency decision quota source; do
    claim_fixture "claim-$variant"
    out=$(ledger claim --project alpha) || fail "initial $variant claim: $out"
    token=${out##*token=}
    case "$variant" in
      brief) printf '\nNew, unapproved work\n' >> "$HOME_DIR/data/claim-one/brief.md" ;;
      scope) printf 'claim-project=beta\n' > "$HOME_DIR/config/mission-ledger" ;;
      dependency)
        tasks add dependency 'unfinished dependency' --repo alpha >/dev/null
        tasks block claim-one --by dependency >/dev/null || fail 'cannot add dependency'
        ;;
      decision) printf 'needs-decision [key=approval]: unresolved approval\nworking: still open\n' > "$HOME_DIR/state/claim-one.status" ;;
      quota) printf 'budget_inclusive_hard=100\nbudget_folded_unknown=child@FM_BUDGET_LAUNCH_unknown\n' > "$HOME_DIR/state/lane-budget" ;;
      source) rm "$HOME_DIR/data/ledger-intake.tsv" ;;
    esac
    out=$(ledger claim --project alpha --resume claim-one 2>&1); rc=$?
    expect_code 1 "$rc" "changed $variant refuses a reserved claim: $out"
    [ "$(jq -r .token "$HOME_DIR/state/ledger-claims/claim-one.json")" = "$token" ] || fail 'refusal replaced the receipt'
    [ "$(jq -r .phase "$HOME_DIR/state/ledger-claims/claim-one.json")" = reserved ] || fail 'refusal consumed the claim'
  done
  for variant in prefix prose; do
    new_home "claim-source-$variant"
    mkdir -p "$HOME_DIR/projects/alpha"
    printf 'claim-project=alpha\n' > "$HOME_DIR/config/mission-ledger"
    ledger intake claim-one --project alpha --title 'approved work' --source proposal:V1 --body 'Approved detail' >/dev/null || fail 'intake failed'
    fm_test_spawn_brief "$HOME_DIR" claim-one
    out=$(ledger claim --project alpha) || fail "initial $variant claim: $out"
    case "$variant" in
      prefix) tasks update claim-one --body 'Ledger source: proposal:V12' >/dev/null || fail 'body update failed' ;;
      prose) tasks update claim-one --body $'Edited note\nLedger source: proposal:V1' >/dev/null || fail 'body update failed' ;;
    esac
    out=$(ledger claim --project alpha --resume claim-one 2>&1); rc=$?
    expect_code 1 "$rc" "source $variant mismatch refuses claim: $out"
    assert_contains "$out" 'approval source changed' "source $variant mismatch explains refusal"
  done
  claim_fixture claim-owned
  tasks start claim-one >/dev/null
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 3 "$rc" 'main-owned in-flight work is not adopted'
  claim_fixture claim-holds
  order send --hold --from test -- 'hold dispatch' >/dev/null
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 3 "$rc" 'standing holds refuse fresh claims'
  claim_fixture claim-bad-config
  printf 'claim-project=../other-home\n' >> "$HOME_DIR/config/mission-ledger"
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 1 "$rc" 'invalid scope fails closed even after a valid grant'
  claim_fixture claim-symlink-config
  printf 'claim-project=alpha\n' > "$HOME_DIR/real-ledger"
  ln -sf "$HOME_DIR/real-ledger" "$HOME_DIR/config/mission-ledger"
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 1 "$rc" 'symlinked mission-ledger refuses claims'
  pass 'approval, scope, dependencies, decisions, quota and standing holds refuse claims; in-flight work stays owned'
}

test_claim_concurrent_spawn_and_lost_reply() {
  claim_fixture claim-spawn
  local one two r1=0 r2=0 out token fakebin wt
  ledger claim --project alpha > "$HOME_DIR/one.out" 2> "$HOME_DIR/one.err" & one=$!
  ledger claim --project alpha > "$HOME_DIR/two.out" 2> "$HOME_DIR/two.err" & two=$!
  wait "$one" || r1=$?
  wait "$two" || r2=$?
  [ "$(( (r1 == 0) + (r2 == 0) ))" = 1 ] || fail "two claimants must produce one reservation ($r1,$r2)"
  out=$(ledger claim --project alpha --resume claim-one) || fail "cannot recover lost claim reply: $out"
  token=${out##*token=}
  wt="$HOME_DIR/test-worktree"
  fm_git_worktree "$HOME_DIR/projects/alpha" "$wt" claim-fixture
  fakebin=$(fm_test_make_spawn_fakebin "$HOME_DIR/fake" codex)
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  touch "$HOME_DIR/state/.last-watcher-beat"
  out=$(FM_BACKEND=tmux fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout) && fail 'spawn without token admitted a reserved item'
  assert_contains "$out" 'claim token is required' 'ordinary dispatch cannot bypass the reservation'
  FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$HOME_DIR/launch.log" fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout --claim "$token" > "$HOME_DIR/spawn-one.out" & one=$!
  FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$HOME_DIR/launch.log" fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout --claim "$token" > "$HOME_DIR/spawn-two.out" & two=$!
  r1=0; r2=0
  wait "$one" || r1=$?
  wait "$two" || r2=$?
  [ "$(( (r1 == 0) + (r2 == 0) ))" = 1 ] || fail "two spawn calls must launch one worker ($r1,$r2): $(cat "$HOME_DIR"/spawn-*.out)"
  out=$(ledger claim --project alpha --resume claim-one) || fail "cannot read completed receipt: $out"
  assert_contains "$out" 'phase=launched' 'lost spawn reply recovers the completed receipt'
  assert_contains "$(tasks show claim-one --full)" 'state: in_flight' 'one worker owns the backlog item'
  out=$(FM_BACKEND=tmux fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout --claim "$token") && fail 'a late replay launched twice'
  [ "$(grep -c 'export FM_TASK_INBOX=' "$HOME_DIR/launch.log")" = 1 ] || fail 'the backend received more than one worker launch'
  pass 'two claimants and two launch calls produce one worker; a lost response and late replay do not duplicate it'
}

test_claim_crash_fence() {
  claim_fixture claim-crash
  local out token next_token wt fakebin rc=0
  out=$(ledger claim --project alpha) || fail "initial claim: $out"
  token=${out##*token=}
  # Use the spawn-owned public transition under a real lock, then kill its
  # holder. No endpoint evidence exists, so recovery must retain uncertainty.
  FM_HOME="$HOME_DIR" bash -c '
    source "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$FM_HOME/state/.spawn-claim-one.lock" || exit 1
    "$1/bin/fm-ledger.sh" claim-begin claim-one "$2" "$FM_HOME/projects/alpha" || exit 1
    kill -KILL "$$"
  ' _ "$ROOT" "$token" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 137 ] || fail "crash fixture did not cross the dispatch fence: $rc"
  out=$(ledger claim --project alpha --resume claim-one 2>&1); rc=$?
  expect_code 4 "$rc" 'a crash after the fence is uncertain, not retryable'
  assert_contains "$out" 'phase=dispatching' 'the uncertain dispatch remains durable'
  out=$(ledger claim --project alpha 2>&1); rc=$?
  expect_code 3 "$rc" 'a crashed claim is never reissued'
  out=$( (unset FM_TASK_ID; ledger claim-release claim-one --token "$token") 2>&1) || fail "prelaunch crash cannot be released: $out"
  out=$(ledger claim --project alpha) || fail "released item cannot be claimed again: $out"
  next_token=${out##*token=}
  [ "$next_token" != "$token" ] || fail 'release reused the retired token'
  wt="$HOME_DIR/test-worktree"
  fm_git_worktree "$HOME_DIR/projects/alpha" "$wt" recovered-claim
  fakebin=$(fm_test_make_spawn_fakebin "$HOME_DIR/fake" codex)
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  touch "$HOME_DIR/state/.last-watcher-beat"
  out=$(FM_BACKEND=tmux fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout --claim "$token") && fail 'retired token launched a worker'
  assert_contains "$out" 'claim token is required' 'the old delayed spawn remains fenced'
  out=$(FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$HOME_DIR/recovered-launch.log" fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout --claim "$next_token") || fail "recovered claim failed to launch: $out"
  [ "$(grep -c 'export FM_TASK_INBOX=' "$HOME_DIR/recovered-launch.log")" = 1 ] || fail 'recovery did not deliver exactly one worker'
  pass 'a killed prelaunch dispatcher can be released without reusing its dispatch identity'
}

test_claim_parked_order_revokes_authority() {
  new_home claim-order
  mkdir -p "$HOME_DIR/projects/alpha"
  printf 'claim-project=alpha\n' > "$HOME_DIR/config/mission-ledger"
  local oid out token rc
  oid=$(order send --from test -- 'approved order to claim' | awk '/^queued / {print $2}')
  ledger intake claim-one --project alpha --title 'order work' --source "order:$oid" >/dev/null || fail 'order intake failed'
  fm_test_spawn_brief "$HOME_DIR" claim-one
  out=$(ledger claim --project alpha) || fail "order claim failed: $out"
  token=${out##*token=}
  order ack "$oid" >/dev/null || fail 'order ack failed'
  order finish "$oid" parked -- 'defer this work' >/dev/null || fail 'order park failed'
  out=$(ledger claim --project alpha --resume claim-one 2>&1); rc=$?
  expect_code 1 "$rc" 'parking the source order revokes a reserved claim'
  assert_contains "$out" 'parked' 'refusal identifies the revoked source order'
  [ "$(jq -r .token "$HOME_DIR/state/ledger-claims/claim-one.json")" = "$token" ] || fail 'revocation changed receipt identity'
  pass 'a parked source order revokes the claim even when backlog and brief are unchanged'
}

test_claim_project_symlink_cannot_cross_home() {
  claim_fixture claim-containment
  local out rc
  mkdir -p "$TMP_ROOT/foreign-home/projects/alpha"
  rmdir "$HOME_DIR/projects/alpha"
  ln -s "$TMP_ROOT/foreign-home/projects/alpha" "$HOME_DIR/projects/alpha"
  out=$(ledger claim --project alpha 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail 'claim followed a project symlink into another home'
  assert_absent "$HOME_DIR/state/ledger-claims/claim-one.json" 'foreign project got no receipt'
  claim_fixture claim-symlink-after-reserve
  out=$(ledger claim --project alpha) || fail 'cannot reserve contained project'
  rmdir "$HOME_DIR/projects/alpha"
  ln -s "$TMP_ROOT/foreign-home/projects/alpha" "$HOME_DIR/projects/alpha"
  out=$(ledger claim --project alpha --resume claim-one 2>&1); rc=$?
  expect_code 1 "$rc" 'retargeting the project symlink refuses a reserved claim'
  pass 'claim rejects a project symlink outside the home projects root'
}

claim_transition_for_test() { # <token> <begin|launch|finish>
  FM_HOME="$HOME_DIR" bash -c '
    source "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$FM_HOME/state/.spawn-claim-one.lock" || exit 1
    trap '\''fm_lock_release "$FM_HOME/state/.spawn-claim-one.lock"'\'' EXIT
    "$1/bin/fm-ledger.sh" "claim-$3" claim-one "$2" "$FM_HOME/projects/alpha"
  ' _ "$ROOT" "$1" "$2"
}

test_claim_rechecks_hold_at_publication() {
  claim_fixture claim-hold-publication
  local out token fakebin rc real_sha
  out=$(ledger claim --project alpha) || fail 'cannot reserve hold fixture'
  token=${out##*token=}
  fakebin=$(fm_fakebin "$HOME_DIR/hold-fake")
  real_sha=$(command -v shasum)
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
# Inject an external order after snapshot hashing starts, after the earlier
# holds read. The marker proves the race occurred rather than a timing guess.
if [ "$#" = 2 ] && [ "$1" = -a ] && [ "$2" = 256 ]; then
  input=$(cat)
  if [ -f "$FM_HOLD_TRIGGER" ] && printf '%s\n' "$input" | grep -Fq 'Ledger source: proposal:V12'; then
    mv "$FM_HOLD_TRIGGER" "$FM_HOLD_TRIGGER.fired"
    FM_HOME="$FM_HOLD_HOME" "$FM_HOLD_ROOT/bin/fm-order.sh" send --hold --from test -- 'stop this dispatch' >/dev/null || exit 1
  fi
  printf '%s\n' "$input" | "$FM_HOLD_REAL_SHA" "$@"
else
  exec "$FM_HOLD_REAL_SHA" "$@"
fi
SH
  chmod +x "$fakebin/shasum"
  touch "$HOME_DIR/inject-hold"
  out=$(PATH="$fakebin:$PATH" FM_HOLD_TRIGGER="$HOME_DIR/inject-hold" FM_HOLD_HOME="$HOME_DIR" FM_HOLD_ROOT="$ROOT" FM_HOLD_REAL_SHA="$real_sha" claim_transition_for_test "$token" begin 2>&1); rc=$?
  expect_code 1 "$rc" "late hold must prevent publication: $out"
  [ -f "$HOME_DIR/inject-hold.fired" ] || fail 'late hold fixture did not reach the hashing boundary'
  assert_contains "$out" 'standing holds' 'the final authority read observes the late hold'
  [ "$(jq -r .phase "$HOME_DIR/state/ledger-claims/claim-one.json")" = reserved ] || fail 'dispatching receipt published despite late hold'
  pass 'a hold arriving after snapshot validation refuses receipt publication'
}

test_claim_refusals_leave_no_staging_files() {
  claim_fixture claim-stage-cleanup
  local out token fakebin rc real_sha orphans
  fakebin=$(fm_fakebin "$HOME_DIR/stage-fake")
  real_sha=$(command -v shasum)
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
# Inject a standing hold after snapshot hashing, once staging is under way,
# so publication refuses after the receipt temp file exists.
if [ "$#" = 2 ] && [ "$1" = -a ] && [ "$2" = 256 ]; then
  input=$(cat)
  if [ -f "$FM_STAGE_TRIGGER" ] && printf '%s\n' "$input" | grep -Fq 'Ledger source: proposal:V12'; then
    mv "$FM_STAGE_TRIGGER" "$FM_STAGE_TRIGGER.fired"
    FM_HOME="$FM_STAGE_HOME" "$FM_STAGE_ROOT/bin/fm-order.sh" send --hold --from test -- 'stop this dispatch' >/dev/null || exit 1
  fi
  printf '%s\n' "$input" | "$FM_STAGE_REAL_SHA" "$@"
else
  exec "$FM_STAGE_REAL_SHA" "$@"
fi
SH
  chmod +x "$fakebin/shasum"
  touch "$HOME_DIR/inject-stage-hold"
  out=$(PATH="$fakebin:$PATH" FM_STAGE_TRIGGER="$HOME_DIR/inject-stage-hold" FM_STAGE_HOME="$HOME_DIR" FM_STAGE_ROOT="$ROOT" FM_STAGE_REAL_SHA="$real_sha" ledger claim --project alpha 2>&1); rc=$?
  expect_code 1 "$rc" "late hold refuses the fresh claim: $out"
  [ -f "$HOME_DIR/inject-stage-hold.fired" ] || fail 'staging fixture did not reach the hashing boundary'
  orphans=$(find "$HOME_DIR/state/ledger-claims" -maxdepth 1 -name '.receipt.*' -print)
  [ -z "$orphans" ] || fail "refused fresh claim left staging files behind: $orphans"
  claim_fixture claim-stage-cleanup-spawn
  out=$(ledger claim --project alpha) || fail 'cannot reserve spawn staging fixture'
  token=${out##*token=}
  fakebin=$(fm_fakebin "$HOME_DIR/stage-spawn-fake")
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
if [ "$#" = 2 ] && [ "$1" = -a ] && [ "$2" = 256 ]; then
  input=$(cat)
  if [ -f "$FM_STAGE_TRIGGER" ] && printf '%s\n' "$input" | grep -Fq 'Ledger source: proposal:V12'; then
    mv "$FM_STAGE_TRIGGER" "$FM_STAGE_TRIGGER.fired"
    FM_HOME="$FM_STAGE_HOME" "$FM_STAGE_ROOT/bin/fm-order.sh" send --hold --from test -- 'stop this dispatch' >/dev/null || exit 1
  fi
  printf '%s\n' "$input" | "$FM_STAGE_REAL_SHA" "$@"
else
  exec "$FM_STAGE_REAL_SHA" "$@"
fi
SH
  chmod +x "$fakebin/shasum"
  touch "$HOME_DIR/inject-stage-hold"
  out=$(PATH="$fakebin:$PATH" FM_STAGE_TRIGGER="$HOME_DIR/inject-stage-hold" FM_STAGE_HOME="$HOME_DIR" FM_STAGE_ROOT="$ROOT" FM_STAGE_REAL_SHA="$real_sha" claim_transition_for_test "$token" begin 2>&1); rc=$?
  expect_code 1 "$rc" "late hold refuses the dispatch transition: $out"
  [ -f "$HOME_DIR/inject-stage-hold.fired" ] || fail 'spawn staging fixture did not reach the hashing boundary'
  [ "$(jq -r .phase "$HOME_DIR/state/ledger-claims/claim-one.json")" = reserved ] || fail 'refused transition published a dispatching receipt'
  orphans=$(find "$HOME_DIR/state/ledger-claims" -maxdepth 1 -name '.receipt.*' -print)
  [ -z "$orphans" ] || fail "refused claim transition left staging files behind: $orphans"
  pass 'refused claim publications remove their receipt staging files'
}

test_claim_release_requires_proven_retirement() {
  claim_fixture claim-release-proof
  local out token rc fakebin dead_pid next_token
  out=$(ledger claim --project alpha) || fail 'cannot reserve release fixture'
  token=${out##*token=}
  out=$(FM_TASK_ID=worker ledger claim-release claim-one --token "$token" 2>&1); rc=$?
  expect_code 1 "$rc" 'workers cannot release claims'
  out=$(ledger claim-release claim-one --token stale 2>&1); rc=$?
  expect_code 1 "$rc" 'release binds the current token'
  claim_transition_for_test "$token" begin || fail 'begin failed'
  mkdir -p "$HOME_DIR/worker-copy"
  bash -c 'exit 0' & dead_pid=$!
  wait "$dead_pid"
  cat > "$HOME_DIR/state/claim-one.meta" <<EOF
window=firstmate:fm-claim-one
endpoint_task_id=claim-one
project=$HOME_DIR/projects/alpha
worktree=$HOME_DIR/worker-copy
harness=codex
kind=scout
spawn_gen=release-test
tmux_socket=$HOME_DIR/private.sock
tmux_server_pid=$dead_pid
tmux_server_identity=terminated fixture process
tmux_window_id=@1
EOF
  claim_transition_for_test "$token" launch || fail 'launch fence failed'
  claim_transition_for_test "$token" finish || fail 'finish failed'
  out=$(ledger claim-release claim-one --token "$token" 2>&1); rc=$?
  expect_code 1 "$rc" 'release refuses a current task record'
  rm "$HOME_DIR/state/claim-one.meta"
  fakebin=$(fm_fakebin "$HOME_DIR/proof-fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_RELEASE_UNCERTAIN" ]; then echo 'transport error'; else echo 'no server running'; fi
exit 1
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p1\nfcwd\nn/\n'
SH
  chmod +x "$fakebin/tmux" "$fakebin/lsof"
  touch "$HOME_DIR/uncertain"
  out=$(PATH="$fakebin:$PATH" FM_RELEASE_UNCERTAIN="$HOME_DIR/uncertain" ledger claim-release claim-one --token "$token" 2>&1); rc=$?
  expect_code 1 "$rc" 'unreachable endpoint does not prove safe release'
  rm "$HOME_DIR/uncertain"
  out=$(PATH="$fakebin:$PATH" FM_RELEASE_UNCERTAIN="$HOME_DIR/uncertain" ledger claim-release claim-one --token "$token" 2>&1) || fail "proven retired claim cannot be released: $out"
  [ -f "$HOME_DIR/state/ledger-claims/released/claim-one-$token.json" ] || fail 'release lost its receipt history'
  out=$(ledger claim --project alpha) || fail 'retired item cannot be claimed again'
  next_token=${out##*token=}
  [ "$next_token" != "$token" ] || fail 'new reservation reused the retired token'
  out=$(ledger claim-release claim-one --token "$token" 2>&1); rc=$?
  expect_code 1 "$rc" 'a stale release cannot retire the new reservation'
  touch "$HOME_DIR/state/claim-one.backlog-close"
  out=$(ledger claim-release claim-one --token "$next_token" 2>&1); rc=$?
  expect_code 1 "$rc" 'pending close prevents release'
  pass 'supervisor release preserves current ownership and requires proof that a delivered endpoint is gone'
}

test_claim_skips_unprepared_work_and_scopes_charter_guidance() {
  claim_fixture claim-skip
  local out rc
  tasks add unapproved 'not sourced from an approved ask' --repo alpha --priority 0 >/dev/null
  ledger intake undecided --project alpha --title 'pending choice' --source proposal:pending --priority 0 >/dev/null
  fm_test_spawn_brief "$HOME_DIR" undecided
  printf 'needs-decision [key=choice]: pending\n' > "$HOME_DIR/state/undecided.status"
  out=$(ledger claim --project alpha 2>/dev/null) || fail "ready work after parked items was not claimed: $out"
  assert_contains "$out" 'CLAIM claim-one' 'an unprepared or undecided item does not stall the queue'
  # Source-only library API: no subprocess or harness-specific behavior.
  # shellcheck source=bin/fm-secondmate-charter-lib.sh
  . "$ROOT/bin/fm-secondmate-charter-lib.sh"
  out=$(fm_secondmate_claim_guidance "$HOME_DIR/config") || fail 'valid scope guidance refused'
  assert_contains "$out" 'grants within this charter are: alpha.' 'the charter advertises only local grants'
  mkdir -p "$HOME_DIR/other-config"
  out=$(fm_secondmate_claim_guidance "$HOME_DIR/other-config") || fail 'default-off guidance failed'
  [ -z "$out" ] || fail 'another home inherited a claim grant'
  printf 'claim-project=../alpha\n' > "$HOME_DIR/other-config/mission-ledger"
  out=$(fm_secondmate_claim_guidance "$HOME_DIR/other-config"); rc=$?
  expect_code 1 "$rc" 'charter refuses an invalid grant'
  printf 'claim-project=alpha\n' > "$HOME_DIR/real-mission-ledger"
  ln -sf "$HOME_DIR/real-mission-ledger" "$HOME_DIR/other-config/mission-ledger"
  out=$(fm_secondmate_claim_guidance "$HOME_DIR/other-config"); rc=$?
  expect_code 1 "$rc" 'charter refuses a symlinked mission-ledger'
  pass 'unprepared items do not stall ready work and claim guidance stays inside one home'
}

test_claim_spawn_waits_for_concurrent_claim_lock() {
  claim_fixture claim-wait-lock
  local out token wt fakebin holder rc=0
  out=$(ledger claim --project alpha) || fail "initial claim: $out"
  token=${out##*token=}
  wt="$HOME_DIR/test-worktree"
  fm_git_worktree "$HOME_DIR/projects/alpha" "$wt" claim-wait-lock
  fakebin=$(fm_test_make_spawn_fakebin "$HOME_DIR/fake" codex)
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  touch "$HOME_DIR/state/.last-watcher-beat"
  # Hold the home claim lock across spawn to simulate a concurrent claim scan.
  FM_HOME="$HOME_DIR" bash -c '
    source "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$FM_HOME/state/.ledger-claim.lock" || exit 1
    sleep 1
    fm_lock_release "$FM_HOME/state/.ledger-claim.lock"
  ' _ "$ROOT" &
  holder=$!
  sleep 0.2
  out=$(ledger claim-check claim-one "$token" "$HOME_DIR/projects/alpha" 2>&1); rc=$?
  expect_code 1 "$rc" 'unauthorized claim-check without spawn lock refuses immediately'
  out=$(FM_BACKEND=tmux fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" claim-one "$HOME_DIR/projects/alpha" --scout --claim "$token" 2>&1) \
    || fail "spawn failed under concurrent claim lock: $out"
  wait "$holder" || fail 'lock holder helper failed'
  out=$(ledger claim --project alpha --resume claim-one) || fail "cannot read launched receipt: $out"
  assert_contains "$out" 'phase=launched' 'spawn waited on the claim lock and completed launch'
  pass 'spawn claim transitions wait for concurrent claim lock without losing launch completion'
}

if [ "${FM_TEST_ONLY:-}" = claims ]; then
  fm_test_run test_claim_reserves_once_and_resumes test_claim_refusals_and_changed_approval test_claim_concurrent_spawn_and_lost_reply test_claim_crash_fence test_claim_skips_unprepared_work_and_scopes_charter_guidance test_claim_spawn_waits_for_concurrent_claim_lock
  exit
fi

if [ "${FM_TEST_ONLY:-}" = claim-recovery ]; then
  fm_test_run test_claim_crash_fence test_claim_parked_order_revokes_authority test_claim_project_symlink_cannot_cross_home test_claim_rechecks_hold_at_publication test_claim_refusals_leave_no_staging_files test_claim_release_requires_proven_retirement
  exit
fi

fm_test_run \
  test_claim_reserves_once_and_resumes \
  test_claim_refusals_and_changed_approval \
  test_claim_concurrent_spawn_and_lost_reply \
  test_claim_crash_fence \
  test_claim_parked_order_revokes_authority \
  test_claim_project_symlink_cannot_cross_home \
  test_claim_rechecks_hold_at_publication \
  test_claim_refusals_leave_no_staging_files \
  test_claim_release_requires_proven_retirement \
  test_claim_skips_unprepared_work_and_scopes_charter_guidance \
  test_claim_spawn_waits_for_concurrent_claim_lock \
  test_intake_files_one_item_per_ask_and_replays \
  test_intake_replay_key_and_existing_ids \
  test_public_followups_are_not_ready_work \
  test_failed_scheduled_evaluation_is_retried \
  test_plan_groups_orders_and_marks_short \
  test_next_is_read_only_and_exits_3_when_empty \
  test_depth_reports_short_active_projects \
  test_done_items_are_history_not_work \
  test_scheduled_depth_fires_once_per_slot \
  test_unfiled_lists_open_orders_without_items \
  test_handoff_writes_from_ledger_and_refuses_chains \
  test_arm_registers_the_scheduled_check \
  test_arm_never_replaces_a_task_check_of_the_same_name
