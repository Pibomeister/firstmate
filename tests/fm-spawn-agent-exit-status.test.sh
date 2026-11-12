#!/usr/bin/env bash
# tests/fm-spawn-agent-exit-status.test.sh - the launch frame records how the
# agent command ended, and a new incarnation ends a deliberate stop.
#
# The watcher's automatic relaunch (bin/fm-watch.sh crew_auto_relaunch) relaunches
# a dead worker only on a crash or signal death, never on a clean exit, and never
# a worker `fm-control.sh <id> exit` stopped on purpose. These cases drive the
# real spawn and relaunch against a fake tmux pane, then EXECUTE the launch the
# pane received with the harness binary replaced by a probe that exits 0 or
# kills itself with SIGTERM, and read back state/<id>.agent-exit. The oracle is
# POSIX shell semantics: a command killed by SIGTERM reports status 128+15.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agent-exit)
trap fm_test_cleanup EXIT

make_case() {  # <name> <id> -> "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>"
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

# The probe stands in for codex and ends the way <how> names.
install_probe() {  # <fakebin> <clean|sigterm>
  if [ "$2" = sigterm ]; then
    printf '#!/bin/sh\nkill -TERM $$\nsleep 5\n' > "$1/codex"
  else
    printf '#!/bin/sh\nexit 0\n' > "$1/codex"
  fi
  chmod +x "$1/codex"
}

run_launch() {  # <fakebin> <launch-file>
  env -i HOME="$TMP_ROOT/pane-home" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$(cat "$2")" >/dev/null 2>&1 || true
}

meta_field() {  # <home> <id> <key>
  sed -n "s/^$3=//p" "$1/state/$2.meta" | tail -1
}

test_launch_records_clean_and_signal_exit_with_the_incarnation() {
  local setting how id rec out status gen
  for setting in absent enabled; do
    for how in clean sigterm; do
      id="exit-$setting-$how-a1"
      rec=$(make_case "exit-$setting-$how" "$id")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      : > "$LAUNCH_LOG"; : > "$PANE_LOG"
      out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
        fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      status=$?
      expect_code 0 "$status" "spawn with allowlist=$setting should succeed: $out"
      gen=$(meta_field "$HOME_DIR" "$id" spawn_gen)
      [ -n "$gen" ] || fail "the spawned record carries no spawn_gen"
      [ ! -e "$HOME_DIR/state/$id.agent-exit" ] || fail "an exit status was recorded before the agent ran"
      install_probe "$FAKEBIN_DIR" "$how"
      run_launch "$FAKEBIN_DIR" "$LAUNCH_LOG"
      if [ "$how" = clean ]; then
        assert_equals "$gen	0" "$(cat "$HOME_DIR/state/$id.agent-exit" 2>&1)" \
          "allowlist=$setting: a clean agent exit must be recorded as status 0 for this incarnation"
      else
        assert_equals "$gen	143" "$(cat "$HOME_DIR/state/$id.agent-exit" 2>&1)" \
          "allowlist=$setting: an agent killed by SIGTERM must be recorded as status 143 for this incarnation"
      fi
    done
  done
  pass "the launch records the agent's clean or SIGTERM exit status with its spawn_gen in both allowlist postures"
}

test_fresh_spawn_clears_an_intentional_stop_marker() {
  local id=fresh-stop-a1 rec out status
  rec=$(make_case fresh-stop "$id")
  read_case "$rec"
  printf '1\texit\n' > "$HOME_DIR/state/.crew-stopped-$id"
  : > "$LAUNCH_LOG"; : > "$PANE_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed: $out"
  [ ! -e "$HOME_DIR/state/.crew-stopped-$id" ] || fail "a fresh spawn kept the previous intentional-stop marker"
  pass "a fresh spawn clears the intentional-stop marker"
}

# Enough pane lifecycle for fm-control relaunch's exit-then-launch transaction.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || { payload=$(cat "$staged"); printf '%s\n' "$payload" > "$D/launch"; }
          ;;
      esac
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
}

test_exit_records_the_stop_and_relaunch_clears_it() {
  local id=relaunch-stop-a1 dir home proj wt out status
  dir="$TMP_ROOT/relaunch-stop"
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" "wt-relaunch-stop"
  fm_test_spawn_brief "$home" "$id"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  ctl() {
    env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" "$@" 2>&1
  }
  out=$(ctl exit); status=$?
  expect_code 0 "$status" "exit should succeed: $out"
  [ -f "$home/state/.crew-stopped-$id" ] || fail "exit did not record the intentional stop"
  printf 'codex' > "$dir/fake/command"
  out=$(ctl relaunch --note 'replacement continues the same task'); status=$?
  expect_code 0 "$status" "relaunch should succeed: $out"
  [ ! -e "$home/state/.crew-stopped-$id" ] || fail "a relaunch kept the intentional-stop marker"
  pass "fm-control exit records the intentional stop and a later relaunch clears it"
}

test_launch_records_clean_and_signal_exit_with_the_incarnation
test_fresh_spawn_clears_an_intentional_stop_marker
test_exit_records_the_stop_and_relaunch_clears_it
