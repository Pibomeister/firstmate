#!/usr/bin/env bash
# tests/fm-codex-shell-env.test.sh - a Codex launch must carry the pane's
# endpoint and inbox variables into Codex tool shells.
#
# The operator's global Codex config may set
# [shell_environment_policy] inherit="core", which strips HERDR_PANE_ID,
# HERDR_SESSION, TMUX, TMUX_PANE and FM_TASK_INBOX from tool shells even
# though the pane shell carries them. fm_secondmate_watch_selected then
# refuses the secondmate watcher. The launch therefore carries one
# -c shell_environment_policy.set.<VAR>="<value>" override per variable the
# pane shell actually has, expanded in the pane at launch.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real
# spawn against a fake pane, EXECUTE the emitted launch under a synthetic
# pane environment with a probe as the codex binary, and read the argv the
# probe received. The secondmate case then applies exactly those captured
# overrides as the whole tool-shell environment (the inherit="core" shape)
# and asks the real bin/fm-watch.sh --secondmate-selected for its verdict.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-shell-env)

# make_case <name> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 case_dir home proj wt fakebin launchlog panelog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The probe records its argv, one argument per line, to $FM_CODEX_ARGV_LOG.
install_argv_probe() {  # <fakebin>
  cat > "$1/codex" <<'SH'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$FM_CODEX_ARGV_LOG"
SH
  chmod +x "$1/codex"
}

# emitted_launch_argv <fakebin> <launch-log> <pane-log> <argv-log> [VAR=value...]
# Replays the pane exports and then the launch itself under a synthetic pane
# environment holding exactly the given endpoint variables.
emitted_launch_argv() {
  local fakebin=$1 launchlog=$2 panelog=$3 argvlog=$4
  shift 4
  local launch preamble
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog" || true)
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    FM_CODEX_ARGV_LOG="$argvlog" "$@" \
    /bin/sh -c "$preamble
$launch"
}

assert_override() {  # <argv-log> <var> <value>
  grep -Fxq "shell_environment_policy.set.$2=\"$3\"" "$1" \
    || fail "the codex launch carried no shell_environment_policy.set.$2 override for value $3:"$'\n'"$(cat "$1")"
}

assert_no_override() {  # <argv-log> <var>
  if grep -Fq "shell_environment_policy.set.$2=" "$1"; then
    fail "the codex launch carried a shell_environment_policy.set.$2 override for a variable the pane did not have:"$'\n'"$(cat "$1")"
  fi
}

test_ship_tmux_launch_carries_overrides() {
  local rec out status argvlog want_inbox
  rec=$(make_case ship-tmux ship-tmux-a1)
  read_case "$rec"
  out=$(run_case_spawn ship-tmux-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed: $out"
  install_argv_probe "$FAKEBIN_DIR"
  argvlog="$CASE_DIR/argv.log"
  emitted_launch_argv "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$argvlog" \
    'TMUX=/tmp/fm-cx-test-sock,1,0' 'TMUX_PANE=%27' \
    || fail "ship: the emitted launch failed to run"
  want_inbox="$(cd "$HOME_DIR/state" && pwd -P)/ship-tmux-a1.inbox"
  assert_override "$argvlog" TMUX '/tmp/fm-cx-test-sock,1,0'
  assert_override "$argvlog" TMUX_PANE '%27'
  assert_override "$argvlog" FM_TASK_INBOX "$want_inbox"
  assert_no_override "$argvlog" HERDR_PANE_ID
  assert_no_override "$argvlog" HERDR_SESSION
  pass "a Codex ship launch carries TMUX, TMUX_PANE and FM_TASK_INBOX overrides, and no Herdr overrides the pane lacks"
}

test_secondmate_herdr_launch_selects_watcher() {
  local rec sm out status argvlog want_inbox parent_home line var value
  local -a tool_env=()
  rec=$(make_case secondmate-herdr sm-codex-env-1)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/state" "$sm/config"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "sm-codex-env-1" > "$sm/.fm-secondmate-home"
  printf 'charter for sm-codex-env-1\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-codex-env-1 "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  install_argv_probe "$FAKEBIN_DIR"
  argvlog="$CASE_DIR/argv.log"
  emitted_launch_argv "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" "$argvlog" \
    'HERDR_PANE_ID=w1:p9' 'HERDR_SESSION=lab' \
    || fail "secondmate: the emitted launch failed to run"
  want_inbox="$(cd "$HOME_DIR/state" && pwd -P)/sm-codex-env-1.inbox"
  assert_override "$argvlog" HERDR_PANE_ID 'w1:p9'
  assert_override "$argvlog" HERDR_SESSION 'lab'
  assert_override "$argvlog" FM_TASK_INBOX "$want_inbox"
  assert_no_override "$argvlog" TMUX
  assert_no_override "$argvlog" TMUX_PANE

  # Simulate the Codex tool shell under inherit="core": it starts from
  # nothing and receives only what the captured set overrides name. The
  # watcher selection must accept that environment for this secondmate.
  parent_home=$(cd "$HOME_DIR" && pwd -P)
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent_home" \
    > "$sm/.fm-secondmate-parent"
  while IFS= read -r line; do
    case "$line" in
      shell_environment_policy.set.*)
        line=${line#shell_environment_policy.set.}
        var=${line%%=*}
        value=${line#*=}
        value=${value#\"}
        value=${value%\"}
        tool_env+=("$var=$value")
        ;;
    esac
  done < "$argvlog"
  [ "${#tool_env[@]}" -eq 3 ] \
    || fail "expected exactly the three captured overrides to form the tool-shell environment, got: ${tool_env[*]:-none}"
  status=0
  env -i PATH="$PATH" HOME="$TMP_ROOT/tool-home" FM_HOME="$sm" \
    "${tool_env[@]}" "$ROOT/bin/fm-watch.sh" --secondmate-selected || status=$?
  expect_code 0 "$status" "watcher selection refused the environment the Codex launch overrides deliver"
  pass "a Codex secondmate launch carries Herdr and inbox overrides, and watcher selection accepts the tool-shell environment they produce"
}

test_ship_tmux_launch_carries_overrides
test_secondmate_herdr_launch_selects_watcher
