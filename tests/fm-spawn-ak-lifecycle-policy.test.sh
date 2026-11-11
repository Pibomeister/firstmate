#!/usr/bin/env bash
# tests/fm-spawn-ak-lifecycle-policy.test.sh - every agent this fleet launches
# must start under agent-kit's unattended lifecycle policy with Firstmate named
# as the supervisor, whatever values the spawn or pane environment inherited.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake tmux pane and a real isolated git worktree, then EXECUTE the
# launch command the pane received, under a synthetic pane environment that
# carries contrary values, with the harness binary replaced by a probe. The
# Codex launch template runs the real bin/fm-codex-launch.sh, so the probe also
# reports the tool-shell overrides a Codex configured with inherit = "core"
# would receive. Orca, Tern, Herdr and T3 Code launch paths are covered in their
# own backend suites; the remote second-mate route in
# tests/fm-spawn-compact-adviser-disable-remote.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-ak-lifecycle)

# The cases must not depend on the runner's own environment, which is itself a
# Firstmate launch carrying these names; the inherited-value case sets its own.
unset AK_LIFECYCLE_POLICY AK_LIFECYCLE_SUPERVISOR

DEFAULT_REPORT='policy=unattended
supervisor=firstmate
codex-set=shell_environment_policy.set.AK_LIFECYCLE_POLICY="unattended"
codex-set=shell_environment_policy.set.AK_LIFECYCLE_SUPERVISOR="firstmate"'

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
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

make_secondmate_home() {  # <dir> <id>
  mkdir -p "$1/bin" "$1/data"
  printf '# Firstmate\n' > "$1/AGENTS.md"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf 'charter for %s\n' "$2" > "$1/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$1/.gitignore"
  git -C "$1" init -q -b main
}

# The probe stands in for codex. It prints the two variables the agent process
# started with, then every tool-shell override bin/fm-codex-launch.sh passed it.
install_probe() {  # <fakebin>
  cat > "$1/codex" <<'SH'
#!/bin/sh
printf 'policy=%s\n' "${AK_LIFECYCLE_POLICY-unset}"
printf 'supervisor=%s\n' "${AK_LIFECYCLE_SUPERVISOR-unset}"
for arg do
  case "$arg" in
    shell_environment_policy.set.AK_*) printf 'codex-set=%s\n' "$arg" ;;
  esac
done
SH
  chmod +x "$1/codex"
}

# Run the emitted launch in a synthetic pane shell whose own values contradict
# the expected ones, so a launch that merely inherited the pane is caught.
#   emitted_report <fakebin> <launch-log> [pane-log]
emitted_report() {
  local fakebin=$1 launch preamble=''
  launch=$(cat "$2")
  [ -z "${3:-}" ] || preamble=$(grep '^export ' "$3")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    AK_LIFECYCLE_POLICY=pane-value AK_LIFECYCLE_SUPERVISOR=pane-supervisor \
    /bin/sh -c "$preamble
$launch"
}

test_ship_and_scout_launches() {
  local kind setting rec id out status seen
  for kind in ship scout; do
    for setting in absent enabled; do
      id="$kind-$setting-a1"
      rec=$(make_case "$kind-$setting" codex "$id")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      [ "$setting" = absent ] || assert_contains "$(cat "$LAUNCH_LOG")" '/usr/bin/env -i' \
        "an enabled allowlist should launch under a cleared environment"
      install_probe "$FAKEBIN_DIR"
      seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
        || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_equals "$DEFAULT_REPORT" "$seen" \
        "a $kind launched with allowlist=$setting must start unattended with Firstmate as supervisor, in the agent and its Codex tool shells"
    done
  done
  pass "ship and scout launches carry the unattended policy and Firstmate supervisor in both allowlist postures, overriding contrary pane values"
}

test_secondmate_launch() {
  local rec sm out status seen
  rec=$(make_case secondmate codex sm-ak)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_secondmate_home "$sm" sm-ak
  out=$(run_case_spawn sm-ak "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  install_probe "$FAKEBIN_DIR"
  seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "secondmate: the emitted launch failed to run"
  assert_equals "$DEFAULT_REPORT" "$seen" \
    "a secondmate must start unattended with Firstmate as supervisor, so its own spawns inherit the same values"
  pass "a secondmate launch carries the unattended policy and Firstmate supervisor"
}

# The launch command alone must establish the values: a pane that never ran any
# pre-launch export still starts its agent with them.
test_launch_command_alone_carries_the_values() {
  local rec out status seen
  rec=$(make_case nopane codex nopane-a1)
  read_case "$rec"
  out=$(run_case_spawn nopane-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed: $out"
  install_probe "$FAKEBIN_DIR"
  seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG") \
    || fail "the emitted launch failed to run without the pane exports"
  assert_equals "$DEFAULT_REPORT" "$seen" "the launch command alone must set both values"
  pass "the launch command sets the unattended policy on its own"
}

# The values are fixed: an inherited empty policy or a different supervisor in
# the spawn's own environment never replaces them, in the agent process or in
# its Codex tool shells.
test_inherited_values_never_replace_the_pair() {
  local setting parent rec id out status seen
  for setting in absent enabled; do
    for parent in empty contrary; do
      id="inherited-$setting-$parent-a1"
      rec=$(make_case "inherited-$setting-$parent" codex "$id")
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$parent" = empty ]; then
        out=$(AK_LIFECYCLE_POLICY='' AK_LIFECYCLE_SUPERVISOR='' \
          run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(AK_LIFECYCLE_POLICY=attended AK_LIFECYCLE_SUPERVISOR="night desk's \"shift\"" \
          run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      fi
      status=$?
      expect_code 0 "$status" "spawn with $parent inherited values should succeed: $out"
      install_probe "$FAKEBIN_DIR"
      seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
        || fail "inherited $parent values, allowlist $setting: the emitted launch failed to run"
      assert_equals "$DEFAULT_REPORT" "$seen" \
        "allowlist=$setting: $parent inherited values must not replace unattended and firstmate"
    done
  done
  pass "inherited empty or contrary values never replace the unattended policy and Firstmate supervisor"
}

# A raw command that starts Codex runs through bin/fm-codex-launch.sh with its
# own arguments and assignments kept, so its tool shells receive both names. A
# raw command that starts Codex behind another command word refuses.
install_raw_probe() {  # <path> <marker>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<SH
#!/bin/sh
printf 'ran=%s\n' '$2'
SH
  cat >> "$1" <<'SH'
printf 'policy=%s\n' "${AK_LIFECYCLE_POLICY-unset}"
printf 'supervisor=%s\n' "${AK_LIFECYCLE_SUPERVISOR-unset}"
printf 'codex-home=%s\n' "${CODEX_HOME-unset}"
printf 'codex-bin-env=%s\n' "${FM_CODEX_BIN-unset}"
skip=0
for arg do
  if [ "$skip" = 1 ]; then
    skip=0
    case "$arg" in shell_environment_policy.set.AK_*) printf 'codex-set=%s\n' "$arg" ;; esac
    continue
  fi
  case "$arg" in
    -c) skip=1 ;;
    *) printf 'argv=<%s>\n' "$arg" ;;
  esac
done
SH
  chmod +x "$1"
}

test_raw_codex_launch_uses_the_launcher() {
  local form rec id raw out status seen expected
  for form in bare path; do
    id="raw-codex-$form-a1"
    rec=$(make_case "raw-codex-$form" codex "$id")
    read_case "$rec"
    if [ "$form" = bare ]; then
      raw='codex --disable hooks'
    else
      raw="CODEX_HOME=$CASE_DIR/codex-home $CASE_DIR/by-path/codex --disable hooks"
    fi
    out=$(run_case_spawn "$id" "$PROJ_DIR" --scout "$raw")
    status=$?
    expect_code 0 "$status" "raw $form Codex spawn should succeed: $out"
    assert_contains "$(cat "$LAUNCH_LOG")" "fm-codex-launch.sh' --disable hooks" \
      "a raw $form Codex command must run through the Codex launcher with its arguments kept"
    install_raw_probe "$FAKEBIN_DIR/codex" path-lookup
    install_raw_probe "$CASE_DIR/by-path/codex" named-path
    seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
      || fail "raw $form Codex: the emitted launch failed to run"
    if [ "$form" = bare ]; then
      expected="ran=path-lookup
policy=unattended
supervisor=firstmate
codex-home=unset"
    else
      expected="ran=named-path
policy=unattended
supervisor=firstmate
codex-home=$CASE_DIR/codex-home"
    fi
    expected="$expected
codex-bin-env=unset
codex-set=shell_environment_policy.set.AK_LIFECYCLE_POLICY=\"unattended\"
codex-set=shell_environment_policy.set.AK_LIFECYCLE_SUPERVISOR=\"firstmate\"
argv=<--disable>
argv=<hooks>"
    assert_equals "$expected" "$seen" \
      "a raw $form Codex command must start the named Codex with both tool-shell overrides and its own arguments"
  done

  id='raw-codex-behind-env-a1'
  rec=$(make_case raw-codex-behind-env codex "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --scout 'env -u FOO codex --disable hooks' 2>&1)
  status=$?
  expect_code 1 "$status" "a raw command that starts Codex behind env must refuse: $out"
  assert_contains "$out" 'cannot carry the launch environment into its tool shells' \
    "the refusal must say why the raw Codex form is unsupported"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw Codex command still launched"

  local n=0
  for raw in 'codex --disable hooks; codex resume' 'env -C /w codex x' 'exec -a n codex' "bash -o pipefail -c 'codex x'"; do
    n=$((n + 1))
    id="raw-codex-hidden-$n-a1"
    rec=$(make_case "raw-codex-hidden-$n" codex "$id")
    read_case "$rec"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --scout "$raw" 2>&1)
    status=$?
    expect_code 1 "$status" "raw command '$raw' starts Codex the launcher cannot take over and must refuse: $out"
    assert_contains "$out" 'cannot carry the launch environment into its tool shells' \
      "the refusal for '$raw' must say why the raw form is unsupported"
    [ ! -s "$LAUNCH_LOG" ] || fail "refused raw command '$raw' still launched"
  done
  pass "raw Codex commands run through the Codex launcher, and a Codex hidden behind another command refuses"
}

# A raw non-Codex command that only mentions codex as an argument, quoted text
# or a path segment is not a Codex launch and must spawn.
test_raw_command_mentioning_codex_spawns() {
  local form rec id raw out status probe_dir
  for form in path-segment argument quoted; do
    id="raw-mention-$form-a1"
    rec=$(make_case "raw-mention-$form" claude "$id")
    read_case "$rec"
    probe_dir="$CASE_DIR/work/codex"
    mkdir -p "$probe_dir"
    printf '#!/bin/sh\nexit 0\n' > "$probe_dir/probe"
    chmod +x "$probe_dir/probe"
    case "$form" in
    path-segment) raw="cd $probe_dir && ./probe" ;;
    argument) raw="$probe_dir/probe --model codex" ;;
    quoted) raw="$probe_dir/probe \"use codex to review\"" ;;
    esac
    out=$(run_case_spawn "$id" "$PROJ_DIR" --scout "$raw" 2>&1)
    status=$?
    expect_code 0 "$status" "a raw non-Codex command mentioning codex as $form must spawn: $out"
    assert_contains "$(cat "$LAUNCH_LOG")" "probe" \
      "the raw $form command must reach the pane"
  done
  pass "a raw non-Codex command that only mentions codex still spawns"
}

# A raw compound launch: an export statement, not a command-prefix assignment,
# is what reaches a command after `cd ... &&`.
test_raw_compound_launch() {
  local rec out status seen probe_dir
  rec=$(make_case raw-compound claude raw-compound-a1)
  read_case "$rec"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  mkdir -p "$HOME_DIR/data/raw-compound-a1"
  printf '%s\n' '{"task":"raw-compound-a1","status":"off","profile":null}' > "$HOME_DIR/data/raw-compound-a1/dispatch-resolution.json"
  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  cat > "$probe_dir/probe" <<'SH'
#!/bin/sh
printf 'policy=%s\nsupervisor=%s\n' "${AK_LIFECYCLE_POLICY-unset}" "${AK_LIFECYCLE_SUPERVISOR-unset}"
SH
  chmod +x "$probe_dir/probe"
  out=$(run_case_spawn raw-compound-a1 "$PROJ_DIR" --mode no-mistakes --yolo off "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound launch spawn should succeed: $out"
  seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG") \
    || fail "raw compound launch: the emitted launch failed to run"
  assert_equals "policy=unattended
supervisor=firstmate" "$seen" "a raw compound launch must carry both values past cd"
  pass "a compound raw launch carries the unattended policy and Firstmate supervisor"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch rebuilds the launch through bin/fm-spawn.sh
# --relaunch. The stub models just enough pane lifecycle for that transaction.
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

test_relaunch_rebuilds_the_values() {
  local setting dir home proj wt id out status seen
  for setting in absent enabled; do
    id="relaunch-$setting-a1"
    dir="$TMP_ROOT/relaunch-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
    touch "$home/state/.last-watcher-beat"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$setting"
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
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"
    [ -s "$dir/fake/launch" ] || fail "relaunch with allowlist=$setting sent no replacement launch command"
    install_probe "$dir/fakebin"
    seen=$(emitted_report "$dir/fakebin" "$dir/fake/launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_equals "$DEFAULT_REPORT" "$seen" \
      "a relaunched agent with allowlist=$setting must start unattended with Firstmate as supervisor, exactly as a fresh spawn does"
  done
  pass "relaunch rebuilds the unattended policy and Firstmate supervisor in both allowlist postures"
}

test_ship_and_scout_launches
test_secondmate_launch
test_launch_command_alone_carries_the_values
test_inherited_values_never_replace_the_pair
test_raw_compound_launch
test_raw_codex_launch_uses_the_launcher
test_raw_command_mentioning_codex_spawns
test_relaunch_rebuilds_the_values
