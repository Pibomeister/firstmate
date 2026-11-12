#!/usr/bin/env bash
# tests/fm-ledger.test.sh - bin/fm-ledger.sh reads the home's real tasks-axi
# backlog as the mission ledger: intake files each approved proposal or order
# as its own item, plan and next show the per-project plan and the next ready
# item without changing anything, depth reports thin ready queues once per
# scheduled time, and handoff writes a self-contained document from the ledger
# plus a short in-flight note, refusing delta chains and unfiled orders.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  local out rc filed mentioned loose tricky
  out=$(ledger unfiled); rc=$?
  expect_code 0 "$rc" "unfiled with no orders"
  filed=$(order send --from test -- "filed through intake" | awk '/^queued / { print $2 }')
  mentioned=$(order send --from test -- "filed before the ledger" | awk '/^queued / { print $2 }')
  loose=$(order send --from test -- "never filed" | awk '/^queued / { print $2 }')
  order send --hold --from test -- "hold merges" >/dev/null
  tricky=$(order send --from test -- "summary says kind=hold" | awk '/^queued / { print $2 }')
  ledger intake --mint --project alpha --title "filed through intake" --source "order:$filed" >/dev/null || fail "intake failed"
  tasks add old-item "old item for order $mentioned" --repo alpha >/dev/null
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

fm_test_run \
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
  test_arm_registers_the_scheduled_check
