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
# would receive. One case starts a real tmux server on a private socket to show
# that a server created by a process carrying the pair never publishes it.
# Orca, Tern, Herdr and T3 Code launch paths are covered in their own backend
# suites; the remote second-mate route in
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
# the expected ones, so a launch that merely inherited the pane is caught. The
# pane also carries a stray FM_CODEX_BIN naming no executable, so a Codex
# launch that let it redirect the launcher fails to run.
#   emitted_report <fakebin> <launch-log> [pane-log]
emitted_report() {
  local fakebin=$1 launch preamble=''
  launch=$(cat "$2")
  [ -z "${3:-}" ] || preamble=$(grep '^export ' "$3")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    AK_LIFECYCLE_POLICY=pane-value AK_LIFECYCLE_SUPERVISOR=pane-supervisor \
    FM_CODEX_BIN="$TMP_ROOT/stray-codex-bin-must-not-run" \
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

# A raw command routes through bin/fm-codex-launch.sh, with its own arguments
# and assignments kept, only in the one safe form: plain NAME=value words, then
# codex or /path/to/codex as the only word naming codex. Every other raw form
# that names codex refuses before launch.
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

RAW_CODEX_REFUSAL='names codex outside the one raw form bin/fm-codex-launch.sh can take over'

test_raw_codex_launch_uses_the_launcher() {
  local form rec id raw out status seen expected
  for form in bare prefixed path; do
    id="raw-codex-$form-a1"
    rec=$(make_case "raw-codex-$form" codex "$id")
    read_case "$rec"
    case "$form" in
    bare) raw='codex --disable hooks' ;;
    prefixed) raw="FOO=bar CODEX_HOME=$CASE_DIR/codex-home codex --disable hooks" ;;
    path) raw="CODEX_HOME=$CASE_DIR/codex-home $CASE_DIR/by-path/codex --disable hooks" ;;
    esac
    out=$(run_case_spawn "$id" "$PROJ_DIR" --scout "$raw")
    status=$?
    expect_code 0 "$status" "raw $form Codex spawn should succeed: $out"
    assert_contains "$(cat "$LAUNCH_LOG")" "fm-codex-launch.sh' --disable hooks" \
      "a raw $form Codex command must run through the Codex launcher with its arguments kept"
    install_raw_probe "$FAKEBIN_DIR/codex" path-lookup
    install_raw_probe "$CASE_DIR/by-path/codex" named-path
    seen=$(emitted_report "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
      || fail "raw $form Codex: the emitted launch failed to run"
    case "$form" in
    bare) expected="ran=path-lookup
policy=unattended
supervisor=firstmate
codex-home=unset" ;;
    prefixed) expected="ran=path-lookup
policy=unattended
supervisor=firstmate
codex-home=$CASE_DIR/codex-home" ;;
    path) expected="ran=named-path
policy=unattended
supervisor=firstmate
codex-home=$CASE_DIR/codex-home" ;;
    esac
    expected="$expected
codex-bin-env=unset
codex-set=shell_environment_policy.set.AK_LIFECYCLE_POLICY=\"unattended\"
codex-set=shell_environment_policy.set.AK_LIFECYCLE_SUPERVISOR=\"firstmate\"
argv=<--disable>
argv=<hooks>"
    assert_equals "$expected" "$seen" \
      "a raw $form Codex command must start the named Codex with both tool-shell overrides and its own arguments"
  done

  local n=0 template
  # shellcheck disable=SC2016 # Literal $HOME words are raw-command test data.
  for template in \
    "CODEX_HOME='@DIR@/account name' codex --disable hooks" \
    'CODEX_HOME="@DIR@/account name" codex --disable hooks' \
    'CODEX_HOME=@DIR@/account\ name codex --disable hooks' \
    'CODEX_HOME=$HOME/.codex-alt codex --disable hooks' \
    '$HOME/bin/codex --disable hooks' \
    'time codex --disable hooks' \
    'npx @openai/codex --disable hooks' \
    'true;codex --disable hooks' \
    '{ codex --disable hooks; }' \
    "echo ready
codex --disable hooks" \
    "codex exec 'review the codex config'" \
    'env -u FOO codex --disable hooks' \
    'codex --disable hooks; codex resume' \
    'env -C /w codex x' \
    'exec -a n codex' \
    "bash -o pipefail -c 'codex x'" \
    "bash --norc -c 'codex x'"; do
    n=$((n + 1))
    id="raw-codex-refused-$n-a1"
    rec=$(make_case "raw-codex-refused-$n" codex "$id")
    read_case "$rec"
    raw=${template//@DIR@/$CASE_DIR}
    out=$(run_case_spawn "$id" "$PROJ_DIR" --scout "$raw" 2>&1)
    status=$?
    expect_code 1 "$status" "raw command '$raw' is not the safe Codex form and must refuse: $out"
    assert_contains "$out" "$RAW_CODEX_REFUSAL" \
      "the refusal for '$raw' must name the one supported raw Codex form"
    assert_contains "$out" '--harness codex' \
      "the refusal for '$raw' must point at --harness codex"
    [ ! -s "$LAUNCH_LOG" ] || fail "refused raw command '$raw' still launched"
  done
  pass "only the safe raw Codex form runs through the Codex launcher, and every other raw Codex form refuses"
}

# A raw non-Codex command that names codex as a word refuses like any other
# unsafe form; one that never names codex as a word spawns.
test_raw_non_codex_commands() {
  local form rec id raw out status work_dir
  for form in path-segment argument quoted quoted-separator assignment near-miss-dir near-miss-arg; do
    id="raw-noncodex-$form-a1"
    rec=$(make_case "raw-noncodex-$form" claude "$id")
    read_case "$rec"
    case "$form" in
    near-miss-dir) work_dir="$CASE_DIR/work/codexes" ;;
    *) work_dir="$CASE_DIR/work/codex" ;;
    esac
    mkdir -p "$work_dir"
    printf '#!/bin/sh\nexit 0\n' > "$work_dir/probe"
    chmod +x "$work_dir/probe"
    case "$form" in
    path-segment | near-miss-dir) raw="cd $work_dir && ./probe" ;;
    argument) raw="$work_dir/probe --model codex" ;;
    quoted) raw="$work_dir/probe \"use codex to review\"" ;;
    quoted-separator) raw="$work_dir/probe 'a | codex'" ;;
    assignment) raw="DIR=$work_dir $work_dir/probe" ;;
    near-miss-arg) raw="$CASE_DIR/work/codex-free/probe --model codex-mini"
      mkdir -p "$CASE_DIR/work/codex-free"
      cp "$work_dir/probe" "$CASE_DIR/work/codex-free/probe" ;;
    esac
    out=$(run_case_spawn "$id" "$PROJ_DIR" --scout "$raw" 2>&1)
    status=$?
    case "$form" in
    near-miss-*)
      expect_code 0 "$status" "a raw command that never names codex as a word ($form) must spawn: $out"
      assert_contains "$(cat "$LAUNCH_LOG")" "probe" "the raw $form command must reach the pane"
      ;;
    *)
      expect_code 1 "$status" "a raw non-Codex command naming codex as $form must refuse: $out"
      assert_contains "$out" "$RAW_CODEX_REFUSAL" "the $form refusal must name the one supported raw Codex form"
      [ ! -s "$LAUNCH_LOG" ] || fail "refused raw $form command still launched"
      ;;
    esac
  done
  pass "a raw non-Codex command that names codex refuses, and one that never names it spawns"
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

# A tmux server copies its creator's environment into its global environment,
# which every later session and pane inherits. A process that carries the pair,
# such as a secondmate outside tmux spawning its first tmux-backed worker, must
# therefore start the server without it, or an unrelated later session would
# run under the unattended policy. Drives the real tmux backend against a real
# server on a private socket inside this suite's temp dir.
SCRUB_REAL_TMUX=
SCRUB_TMUX_SOCKET=
cleanup_scrub_tmux() {
  [ -z "$SCRUB_TMUX_SOCKET" ] ||
    env -u TMUX -u TMUX_PANE "$SCRUB_REAL_TMUX" -S "$SCRUB_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
}
trap 'cleanup_scrub_tmux; fm_test_cleanup' EXIT

test_new_tmux_server_never_publishes_the_pair() {
  local dir shim dump later out status global leaked i
  SCRUB_REAL_TMUX=$(command -v tmux) || {
    echo 'ok - skipped: tmux is not installed, so the new-server scrub case cannot run'
    return 0
  }
  dir="$TMP_ROOT/scrub-tmux"
  shim="$dir/bin"
  dump="$dir/dump.sh"
  later="$dir/later-session.env"
  mkdir -p "$shim"
  SCRUB_TMUX_SOCKET="$dir/s"
  cat > "$shim/tmux" <<SH
#!/bin/sh
exec "$SCRUB_REAL_TMUX" -f /dev/null -S "$SCRUB_TMUX_SOCKET" "\$@"
SH
  chmod +x "$shim/tmux"
  cat > "$dump" <<SH
#!/bin/sh
env > "$later.tmp" && mv "$later.tmp" "$later"
SH
  chmod +x "$dump"

  # shellcheck disable=SC2016 # The bash -c script expands its own variables.
  out=$(env -u TMUX -u TMUX_PANE PATH="$shim:$PATH" SHELL=/bin/sh \
    AK_LIFECYCLE_POLICY=unattended AK_LIFECYCLE_SUPERVISOR=firstmate AK_SCRUB_CREATOR_MARKER=creator \
    bash -c '. "$1/bin/fm-backend.sh" && fm_backend_source tmux && fm_backend_tmux_container_ensure &&
      printf "\ncreator=%s|%s\n" "${AK_LIFECYCLE_POLICY-unset}" "${AK_LIFECYCLE_SUPERVISOR-unset}"' _ "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "the tmux backend should create its server: $out"
  assert_contains "$out" 'creator=unattended|firstmate' \
    "the process that created the server must still carry the pair, so this case cannot pass vacuously"

  global=$(env -u TMUX -u TMUX_PANE "$SCRUB_REAL_TMUX" -S "$SCRUB_TMUX_SOCKET" show-environment -g 2>&1) \
    || fail "show-environment -g failed on the new server: $global"
  printf '%s\n' "$global" | grep -qx 'AK_SCRUB_CREATOR_MARKER=creator' ||
    fail "the new server must hold its creator's other variables, so the pair's absence is the scrub's doing"
  leaked=$(printf '%s\n' "$global" | grep -E '^AK_LIFECYCLE_(POLICY|SUPERVISOR)=' || true)
  [ -z "$leaked" ] || fail "a server created by a pair-carrying process must not publish the pair globally: $leaked"

  env -i PATH="$PATH" HOME="$TMP_ROOT/pane-home" \
    "$SCRUB_REAL_TMUX" -f /dev/null -S "$SCRUB_TMUX_SOCKET" new-session -d -s unrelated /bin/sh "$dump" \
    || fail "a later client with neither name could not open a session on the server"
  i=0
  while [ ! -f "$later" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$later" ] || fail "the later session never reported its environment"
  grep -qx 'AK_SCRUB_CREATOR_MARKER=creator' "$later" ||
    fail "a later session must inherit the server's global environment, so the check below is meaningful"
  leaked=$(grep -E '^AK_LIFECYCLE_(POLICY|SUPERVISOR)=' "$later" || true)
  [ -z "$leaked" ] || fail "an unrelated later session must not inherit the pair from the server: $leaked"
  cleanup_scrub_tmux
  SCRUB_TMUX_SOCKET=
  pass "a tmux server started by a process carrying the pair publishes neither name to later sessions"
}

test_ship_and_scout_launches
test_secondmate_launch
test_launch_command_alone_carries_the_values
test_inherited_values_never_replace_the_pair
test_raw_compound_launch
test_raw_codex_launch_uses_the_launcher
test_raw_non_codex_commands
test_relaunch_rebuilds_the_values
test_new_tmux_server_never_publishes_the_pair
