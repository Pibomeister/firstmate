#!/usr/bin/env bash
# Goal integrity (Eduardo, 2026-11-09). With config/goal-integrity present,
# fm-brief.sh opens ship and scout briefs with "GOAL (Eduardo, verbatim): ..."
# from state/goals/<task-id>.md and puts config/brief-include.md at the top as a
# top-precedence section; fm-spawn.sh refuses to send a brief without a GOAL
# line that matches the goal file. Spawn cases are refusals only, reached before
# any worktree or window side effect. Homes without the flag keep the old shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-goal-integrity)
export FM_BACKEND=tmux
GOAL='Build the Transit Solutions ETA agent through CodeGen V2, zero hand patches'

mkhome() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/data" "$h/state/goals" "$h/config" "$h/projects/alpha"
  git -C "$h/projects/alpha" init -q || fail "could not init project fixture"
  git -c user.name=test -c user.email=test@example.com -C "$h/projects/alpha" commit -q --allow-empty -m init || fail "could not commit project fixture"
  [ "${2:-on}" = on ] && : > "$h/config/goal-integrity"
  printf '%s\n' "$h"
}
brief() {
  local h=$1; shift
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$h" "$ROOT/bin/fm-brief.sh" "$@"
}
spawn() {
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$1" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$2" projects/alpha codex --mode no-mistakes --yolo off 2>&1
}
line_of() { grep -n -F -- "$1" "$2" | head -1 | cut -d: -f1; }

test_ship_and_scout_open_with_goal_and_top_include() {
  local h kind b first inc body
  h=$(mkhome scaffold)
  printf '%s\n' 'Standing include line.' > "$h/config/brief-include.md"
  for kind in ship scout; do
    printf '%s\nDate: 2026-11-09\nSource: test\n' "$GOAL" > "$h/state/goals/eta-$kind.md"
    if [ "$kind" = ship ]; then brief "$h" "eta-$kind" some-proj --mode no-mistakes >/dev/null 2>&1 || fail "ship scaffold failed"
    else brief "$h" "eta-$kind" some-proj --scout >/dev/null 2>&1 || fail "scout scaffold failed"; fi
    b="$h/data/eta-$kind/brief.md"
    first=$(sed -n 1p "$b")
    [ "$first" = "GOAL (Eduardo, verbatim): $GOAL" ] || fail "$kind brief line 1 is not the verbatim GOAL: $first"
    assert_grep 'take precedence over every other section of this brief' "$b" "$kind brief lost the top-precedence line"
    inc=$(line_of 'Standing include line.' "$b"); body=$(line_of 'You are a crewmate' "$b")
    [ -n "$inc" ] && [ -n "$body" ] && [ "$inc" -lt "$body" ] || fail "$kind include is not above the brief body ($inc vs $body)"
  done
  pass "ship and scout briefs open with the verbatim GOAL line and a top-precedence include"
}

test_missing_goal_file_leaves_a_placeholder() {
  local h first
  h=$(mkhome nogoal)
  brief "$h" eta-nogoal some-proj --mode no-mistakes >/dev/null 2>&1 || fail "scaffold failed without a goal file"
  first=$(sed -n 1p "$h/data/eta-nogoal/brief.md")
  [ "$first" = 'GOAL (Eduardo, verbatim): {GOAL}' ] || fail "missing goal file did not leave the {GOAL} placeholder: $first"
  pass "a missing goal file leaves a {GOAL} placeholder"
}

test_include_task_heading_is_refused_at_the_top() {
  local h out status
  h=$(mkhome taskhead)
  printf '%s\n' '# Task' 'shadow' > "$h/config/brief-include.md"
  out=$(brief "$h" eta-shadow some-proj --scout 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an include with a # Task heading was accepted at the top"
  printf '%s\n' "$out" | grep -F "must not carry a '# Task' heading" >/dev/null || fail "refusal did not name the # Task heading"
  pass "an include carrying a # Task heading is refused under goal integrity"
}

test_home_without_flag_keeps_old_shape() {
  local h b
  h=$(mkhome legacy off)
  printf '%s\n' 'Standing include line.' > "$h/config/brief-include.md"
  brief "$h" eta-legacy some-proj --scout >/dev/null 2>&1 || fail "legacy scaffold failed"
  b="$h/data/eta-legacy/brief.md"
  grep -q '^GOAL (Eduardo, verbatim):' "$b" && fail "a home without config/goal-integrity got a GOAL line"
  assert_grep '# Home brief additions' "$b" "legacy include section missing"
  pass "a home without config/goal-integrity keeps the old brief shape"
}

test_spawn_refuses_without_a_matching_goal_line() {
  local h out status label
  h=$(mkhome spawn)
  printf '%s\n' "$GOAL" > "$h/state/goals/eta-spawn.md"
  for label in nogoal placeholder mismatch; do
    mkdir -p "$h/data/eta-spawn"
    case "$label" in
      nogoal) printf '%s\n' 'You are a crewmate.' '# Task' 'Do it.' > "$h/data/eta-spawn/brief.md" ;;
      placeholder) printf '%s\n' 'GOAL (Eduardo, verbatim): {GOAL}' '# Task' 'Do it.' > "$h/data/eta-spawn/brief.md" ;;
      mismatch) printf '%s\n' 'GOAL (Eduardo, verbatim): Get the ETA agent working by tomorrow, whatever is fastest' '# Task' 'Do it.' > "$h/data/eta-spawn/brief.md" ;;
    esac
    out=$(spawn "$h" eta-spawn); status=$?
    [ "$status" -ne 0 ] || fail "$label: spawn did not refuse"
    printf '%s\n' "$out" | grep -F 'refusing to send' >/dev/null || fail "$label: refusal message missing: $out"
  done
  pass "fm-spawn refuses a brief with no GOAL line, a {GOAL} placeholder, or a GOAL that is not Eduardo's verbatim goal"
}

test_ship_and_scout_open_with_goal_and_top_include
test_missing_goal_file_leaves_a_placeholder
test_include_task_heading_is_refused_at_the_top
test_home_without_flag_keeps_old_shape
test_spawn_refuses_without_a_matching_goal_line
