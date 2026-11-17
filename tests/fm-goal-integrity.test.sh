#!/usr/bin/env bash
# Goal-line enforcement (config/goal-integrity). fm-brief.sh opens ship and
# scout briefs with GOAL (<owner>, verbatim): from state/goals/<task-id>.md line 1;
# fm-spawn.sh refuses briefs without a matching goal line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-goal-integrity)
export FM_BACKEND=tmux
OWNER=fixture
GOAL='Deliver the sample widget through codegen with zero manual edits'
FAKEBIN="$TMP_ROOT/fakebin"

mkhome() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/data" "$h/state/goals" "$h/config" "$h/projects/alpha"
  git -C "$h/projects/alpha" init -q || fail "could not init project fixture"
  git -c user.name=test -c user.email=test@example.com -C "$h/projects/alpha" commit -q --allow-empty -m init || fail "could not commit project fixture"
  if [ "${2:-on}" = on ]; then
    printf '%s\n' "$OWNER" > "$h/config/goal-integrity"
  fi
  printf '%s\n' "$h"
}
brief() {
  local h=$1; shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$h" "$ROOT/bin/fm-brief.sh" "$@"
}
spawn() {
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$1" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$2" projects/alpha codex --mode direct-PR --yolo off 2>&1
}
line_of() { grep -n -F -- "$1" "$2" | head -1 | cut -d: -f1; }

mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"

test_ship_and_scout_open_with_goal_and_top_include() {
  local h kind b first inc body expect
  h=$(mkhome scaffold)
  expect="GOAL ($OWNER, verbatim): $GOAL"
  printf '%s\n' 'Standing include line.' > "$h/config/brief-include.md"
  for kind in ship scout; do
    printf '%s\n' "$GOAL" > "$h/state/goals/eta-$kind.md"
    if [ "$kind" = ship ]; then brief "$h" "eta-$kind" some-proj --mode direct-PR >/dev/null 2>&1 || fail "ship scaffold failed"
    else brief "$h" "eta-$kind" some-proj --scout >/dev/null 2>&1 || fail "scout scaffold failed"; fi
    b="$h/data/eta-$kind/brief.md"
    first=$(sed -n '1p' "$b")
    [ "$first" = "$expect" ] || fail "$kind brief line 1 is not the verbatim GOAL: $first"
    assert_grep 'take precedence over every other section of this brief' "$b" "$kind brief lost the top-precedence line"
    inc=$(line_of 'Standing include line.' "$b"); body=$(line_of 'You are a crewmate' "$b")
    [ -n "$inc" ] && [ -n "$body" ] && [ "$inc" -lt "$body" ] || fail "$kind include is not above the brief body ($inc vs $body)"
  done
  pass "ship and scout briefs open with the verbatim GOAL line and a top-precedence include"
}

test_missing_goal_file_leaves_a_placeholder() {
  local h first expect
  h=$(mkhome nogoal)
  expect="GOAL ($OWNER, verbatim): {GOAL}"
  brief "$h" eta-nogoal some-proj --mode direct-PR >/dev/null 2>&1 || fail "scaffold failed without a goal file"
  first=$(sed -n '1p' "$h/data/eta-nogoal/brief.md")
  [ "$first" = "$expect" ] || fail "missing goal file did not leave the {GOAL} placeholder: $first"
  pass "a missing goal file leaves a {GOAL} placeholder"
}

test_include_task_heading_is_refused_at_the_top() {
  local h out status
  h=$(mkhome taskhead)
  printf '%s\n' '# Task' 'shadow' > "$h/config/brief-include.md"
  out=$(brief "$h" eta-shadow some-proj --scout 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an include with a # Task heading was accepted at the top"
  printf '%s\n' "$out" | grep -F "must not carry a '# Task' heading" >/dev/null || fail "refusal did not name the # Task heading"
  pass "an include carrying a # Task heading is refused under goal-line enforcement"
}

test_home_without_flag_keeps_old_shape() {
  local h b first
  h=$(mkhome legacy off)
  printf '%s\n' 'Standing include line.' > "$h/config/brief-include.md"
  brief "$h" eta-legacy some-proj --scout >/dev/null 2>&1 || fail "legacy scaffold failed"
  b="$h/data/eta-legacy/brief.md"
  first=$(sed -n '1p' "$b")
  case "$first" in
    'GOAL ('*) fail "a home without config/goal-integrity got a GOAL line on line 1: $first" ;;
  esac
  assert_grep '# Home brief additions' "$b" "legacy include section missing"
  pass "a home without config/goal-integrity keeps the old brief shape"
}

test_spawn_refuses_without_a_matching_goal_line() {
  local h out status label prefix
  h=$(mkhome spawn)
  prefix="GOAL ($OWNER, verbatim): "
  printf '%s\n' "$GOAL" > "$h/state/goals/eta-spawn.md"
  for label in nogoal placeholder mismatch; do
    mkdir -p "$h/data/eta-spawn"
    case "$label" in
      nogoal) printf '%s\n' 'You are a crewmate.' '# Task' 'Do it.' > "$h/data/eta-spawn/brief.md" ;;
      placeholder) printf '%s\n' "${prefix}{GOAL}" '# Task' 'Do it.' > "$h/data/eta-spawn/brief.md" ;;
      mismatch) printf '%s\n' "${prefix}Ship by tomorrow with shortcuts" '# Task' 'Do it.' > "$h/data/eta-spawn/brief.md" ;;
    esac
    out=$(spawn "$h" eta-spawn); status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn did not refuse"
    printf '%s\n' "$out" | grep -F 'refusing to send' >/dev/null || fail "$label: refusal message missing: $out"
  done
  pass "fm-spawn refuses a brief with no GOAL line, a {GOAL} placeholder, or a mismatched goal"
}

test_spawn_passes_goal_gate_on_a_filled_brief() {
  local h out status b
  h=$(mkhome passgate)
  printf '%s\n' "$GOAL" > "$h/state/goals/eta-pass.md"
  brief "$h" eta-pass some-proj --mode direct-PR >/dev/null 2>&1 || fail "scaffold failed"
  b="$h/data/eta-pass/brief.md"
  sed -i '' -e 's/{TASK}/Fix the widget./' -e 's/{FIRSTMATE_SPEC}/Run the test suite./' "$b" 2>/dev/null || \
    sed -i -e 's/{TASK}/Fix the widget./' -e 's/{FIRSTMATE_SPEC}/Run the test suite./' "$b"
  out=$(spawn "$h" eta-pass); status=$?
  printf '%s\n' "$out" | grep -F 'refusing to send' >/dev/null && fail "goal gate refused a valid brief: $out"
  [ "$status" -ne 0 ] || fail "expected spawn to stop at fake tmux, not at goal gate"
  pass "fm-spawn accepts a scaffolded brief whose GOAL line matches the goal file"
}

fm_test_run \
  test_ship_and_scout_open_with_goal_and_top_include \
  test_missing_goal_file_leaves_a_placeholder \
  test_include_task_heading_is_refused_at_the_top \
  test_home_without_flag_keeps_old_shape \
  test_spawn_refuses_without_a_matching_goal_line \
  test_spawn_passes_goal_gate_on_a_filled_brief