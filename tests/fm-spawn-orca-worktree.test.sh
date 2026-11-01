#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# The relaunch side runs only after the Orca agent-state classifier
# (bin/backends/orca.sh, read through fm_control_agent_state) proves the
# recorded terminal agent-free. The relaunch cases below drive that proof with
# Orca's reads faked and every other fact real: a closed terminal with no agent
# left rebinds a new terminal in the recorded worktree, a dead terminal is
# adopted in place, and a live agent or any unprovable read refuses before a
# terminal is created.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" "${FM_TEST_ORCA_START_REF:-HEAD}" >&2 || exit 1
    if [ "${FM_TEST_ORCA_NEW_COMMIT:-0}" = 1 ]; then
      git -C "$wt" -c user.name=Tests -c user.email=tests@example.invalid \
        commit --allow-empty -qm 'uncontained Orca work' || exit 1
    fi
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    [ -z "${FM_TEST_ORCA_TERMINAL_FAIL:-}" ] || exit 1
    printf '%s\n' "$*" >> "$DIR/terminal-create.log"
    printf '{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"%s\"}}}\n' "${FM_TEST_ORCA_NEW_TERMINAL:-term-1}"
    exit 0
    ;;
  "terminal show")
    # show-<handle>.json is the case's answer for that terminal; none is a CLI failure.
    prev=
    for a in "$@"; do
      [ "$prev" != --terminal ] || handle=$a
      prev=$a
    done
    [ -f "$DIR/show-${handle:-}.json" ] || exit 1
    cat "$DIR/show-$handle.json"
    exit "$(cat "$DIR/show-$handle.exit" 2>/dev/null || echo 0)"
    ;;
  "diagnostics memory")
    [ -f "$DIR/memory.json" ] || exit 1
    cat "$DIR/memory.json"
    exit 0
    ;;
  "worktree rm")
    [ -z "${FM_TEST_ORCA_RM_FAIL:-}" ] || exit 1
    id=${4#id:wt-}
    git -C "$DIR/project" worktree remove --force "$DIR/orca-worktrees/$id" >&2 || exit 1
    printf '{"ok":true}\n'
    exit 0
    ;;
  "terminal close")
    touch "$DIR/terminal-closed"
    exit 0
    ;;
  "terminal read")
    printf '{"ok":true,"result":{"terminal":{"tail":["shell"]}}}\n'
    exit 0
    ;;
  "terminal send")
    printf '%s\n' "$*" >> "$DIR/terminal-send.log"
    # An unwritable recorded endpoint remains readable in Orca,
    # but cannot receive the relaunch's worktree-entry command.
    prev=
    handle=
    for a in "$@"; do
      [ "$prev" != --terminal ] || handle=$a
      prev=$a
    done
    if [ -f "$DIR/show-$handle.json" ] && node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1])).result?.terminal;
process.exit(t?.writable === false ? 0 : 1);
' "$DIR/show-$handle.json"; then
      printf '{"ok":false,"error":{"code":"terminal_not_writable"}}\n'
      exit 1
    fi
    if [ -n "${FM_TEST_ORCA_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != --text ] || printf '%s\n' "$a" >> "$FM_TEST_ORCA_LOG"
        prev=$a
      done
    fi
    # FM_TEST_ORCA_HOLD_TEXT holds the source-text delivery open after the
    # text arrived, so a test can interrupt the spawn before it sends Enter.
    if [ "${FM_TEST_ORCA_HOLD_TEXT:-0}" = 1 ]; then
      case "$*" in
        */launch.*)
          touch "$DIR/text-delivered"
          i=0
          while [ ! -e "$DIR/release" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
          ;;
      esac
    fi
    if [ "${FM_TEST_ORCA_SEND_FAIL:-0}" = 1 ]; then
      case "$*" in */launch.*) exit 1 ;; esac
    fi
    # FM_TEST_ORCA_CONSUME acts as the pane: it captures the staged file and its
    # mode, then unlinks it as the real launch line does, optionally after a delay.
    if [ "${FM_TEST_ORCA_CONSUME:-0}" = 1 ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = --text ]; then
          case "$a" in
            *"'"*/launch.*)
              f=${a#*"'"}; f=${f%%"'"*}
              (
                sleep "${FM_TEST_ORCA_CONSUME_DELAY:-0}"
                { stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f"; } > "$f.mode"
                cp "$f" "$f.copy" && rm -f "$f"
              ) >/dev/null 2>&1 &
              ;;
          esac
        fi
        prev=$a
      done
    fi
    # FM_TEST_ORCA_RM_FAIL acts as a pane that sources the staged file with an
    # rm that always fails, then keeps running.
    if [ "${FM_TEST_ORCA_RM_FAIL:-0}" = 1 ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = --text ]; then
          case "$a" in
            *"'"*/launch.*)
              f=${a#*"'"}; f=${f%%"'"*}
              mkdir -p "$DIR/rmfail"
              printf '#!/bin/sh\nexit 1\n' > "$DIR/rmfail/rm"
              chmod +x "$DIR/rmfail/rm"
              # shellcheck disable=SC2016 # The pane shell expands its own arguments.
              PATH="$DIR/rmfail:$PATH" sh -c '. "$1"; echo "source-status=$?"; echo SHELL-STILL-ALIVE' _ "$f" > "$DIR/pane.out" 2>&1 &
              ;;
          esac
        fi
        prev=$a
      done
    fi
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  # The working-directory scan answers from lsof.out, or fails when it is absent.
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
[ -f "${FM_TEST_ORCA_DIR:?}/lsof.out" ] || exit 1
cat "$FM_TEST_ORCA_DIR/lsof.out"
SH
  chmod +x "$fb/lsof"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

test_orca_aborted_spawn_safe_deletes_or_records_its_created_branch() {
  local variant case_dir home id fb out status rm_fail start_ref old_main base_setup base_args
  for variant in removed removed-contained-ahead removed-unmerged removed-base rm-fails rm-fails-base; do
    id="orca-abort-$variant"
    case_dir="$TMP_ROOT/abort-$variant"
    home="$case_dir/home"
    rm_fail=
    case "$variant" in rm-fails*) rm_fail=1 ;; esac
    # A recorded base equal to the Orca-created branch must reach the helper
    # (removed-base) and the recovery record (rm-fails-base).
    base_setup=
    base_args=()
    case "$variant" in
      *-base)
        base_setup="# Setup
You are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.
Base branch: orca-fm-$id
"
        base_args=(--base-branch "orca-fm-$id")
        ;;
    esac
    mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
    touch "$home/state/.last-watcher-beat"
    printf 'codex\n' > "$home/config/crew-harness"
    printf 'manual\n' > "$home/config/backlog-backend"
    fm_git_init_commit "$case_dir/project"
    git -C "$case_dir/project" update-ref refs/remotes/origin/main main
    start_ref=HEAD
    if [ "$variant" = removed-contained-ahead ]; then
      old_main=$(git -C "$case_dir/project" rev-parse main)
      git -C "$case_dir/project" -c user.name=Tests -c user.email=tests@example.invalid \
        commit --allow-empty -qm 'remote ahead of local main'
      git -C "$case_dir/project" update-ref refs/remotes/origin/main main
      git -C "$case_dir/project" reset --hard -q "$old_main"
      start_ref=refs/remotes/origin/main
    fi
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an aborted Orca-backed spawn for $id.

## Firstmate spec
Confirm the abort does not leak the branch Orca created.

$base_setup
EOF
    fb=$(make_orca_fakebin "$case_dir")
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
      FM_TEST_ORCA_TERMINAL_FAIL=1 FM_TEST_ORCA_RM_FAIL="$rm_fail" \
      FM_TEST_ORCA_NEW_COMMIT="$([ "$variant" = removed-unmerged ] && echo 1 || echo 0)" \
      FM_TEST_ORCA_START_REF="$start_ref" \
      "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca \
      ${base_args[@]+"${base_args[@]}"} 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$variant: spawn should fail when Orca terminal creation fails"$'\n'"$out"
    case "$variant" in
      removed|removed-contained-ahead)
        git -C "$case_dir/project" show-ref --verify --quiet "refs/heads/orca-fm-$id" \
          && fail "aborted spawn leaked the Orca-created branch"$'\n'"$out"
        assert_absent "$home/state/$id.meta" "a cleaned-up abort should not record metadata"
        ;;
      removed-unmerged)
        git -C "$case_dir/project" show-ref --verify --quiet "refs/heads/orca-fm-$id" \
          || fail "aborted spawn force-deleted uncontained Orca work: $out"
        git -C "$case_dir/project" merge-base --is-ancestor "orca-fm-$id" main \
          && fail 'uncontained fixture became merged into main'
        assert_contains "$out" "warning: kept Orca-created branch orca-fm-$id" \
          'aborted spawn must warn when it preserves uncontained work'
        ;;
      removed-base)
        git -C "$case_dir/project" show-ref --verify --quiet "refs/heads/orca-fm-$id" \
          || fail "aborted spawn deleted its recorded base branch: $out"
        assert_contains "$out" "warning: kept Orca-created branch orca-fm-$id (protected" \
          'aborted spawn must protect its recorded base branch'
        ;;
      rm-fails-base)
        assert_grep "base_branch=orca-fm-$id" "$home/state/$id.meta" \
          "recovery metadata must record the base branch for teardown"
        ;;
      rm-fails)
        git -C "$case_dir/project" show-ref --verify --quiet "refs/heads/orca-fm-$id" \
          || fail "a branch still checked out in an unremoved worktree must be kept"
        assert_grep "orca_created_branch=orca-fm-$id" "$home/state/$id.meta" \
          "recovery metadata must record the Orca-created branch for teardown"
        ;;
    esac
  done
  pass "an aborted Orca spawn deletes only contained work, retains uncontained commits and its recorded base, or records recovery metadata with the base"
}
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run() {
  local case_dir home proj wt id=orca-relaunch-a2 out status
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch attempt against a recorded Orca task.

## Firstmate spec
Confirm the relaunch is refused before any worktree re-entry logic runs.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-1"
  } > "$home/state/$id.meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?

  expect_code 1 "$status" "a relaunch against a recorded Orca task should refuse"$'\n'"$out"
  assert_contains "$out" "cannot be proven absent" \
    "the refusal should name the unproven endpoint, proving relaunch never reaches the worktree carve-out"
  pass "a relaunch against an Orca-backed task whose agent is not proven stopped is refused before the RELAUNCH+orca worktree carve-out could run"
}
# orca_relaunch_case <name>: a recorded Orca ship task whose terminal term-old
# belonged to its real worktree, with Orca's reads left for the case to write.
# Sets CASE_DIR, HOME_DIR, WT, TASK and FB.
orca_relaunch_case() {
  local proj
  CASE_DIR="$TMP_ROOT/relaunch-$1"
  HOME_DIR="$CASE_DIR/home"
  proj="$CASE_DIR/proj"
  WT="$CASE_DIR/wt"
  TASK="orca-relaunch-$1"
  mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$CASE_DIR/user-home"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  fm_git_worktree "$proj" "$WT" "task-$TASK"
  WT=$(cd -P "$WT" && pwd -P)
  cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch against a recorded Orca task.

## Firstmate spec
Confirm the relaunch proves the old terminal agent-free before it launches.
EOF
  {
    echo "window=fm-$TASK"
    echo "endpoint_task_id=$TASK"
    echo "worktree=$WT"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$WT"
    echo "terminal=term-old"
  } > "$HOME_DIR/state/$TASK.meta"
  FB=$(make_orca_fakebin "$CASE_DIR")
  printf 'p%s\nn%s\n' "$$" "$CASE_DIR" > "$CASE_DIR/lsof.out"
  printf '{"ok":true,"result":{"worktrees":[{"sessions":[]}]}}\n' > "$CASE_DIR/memory.json"
}

orca_relaunch_show() {  # <connected> <exit-kind|''> [worktree-path]
  local cause=null writable=$1
  [ -z "$2" ] || cause="{\"kind\":\"$2\"}"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-old","ptyId":"pty-old","connected":%s,"writable":%s,"exitCause":%s,"executionHostId":"local","worktreePath":"%s"}}}\n' \
    "$1" "$writable" "$cause" "${3:-$WT}" > "$CASE_DIR/show-term-old.json"
}

orca_relaunch() {  # [spawn args...] -> sets OUT and STATUS
  OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$CASE_DIR" FM_TEST_ORCA_NEW_TERMINAL=term-new FM_TEST_ORCA_BOOT_EPOCH="${FM_TEST_ORCA_BOOT_EPOCH:-2000}" PATH="$FB:$PATH" \
    "$SPAWN" "$TASK" --relaunch "$@" 2>&1)
  STATUS=$?
}

orca_relaunch_boot() {
  cat > "$FB/awk" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$2" = /proc/stat ]; then
  printf '%s\n' "${FM_TEST_ORCA_BOOT_EPOCH:-2000}"
  exit 0
fi
SH
  printf 'exec %q "$@"\n' "$(command -v awk)" >> "$FB/awk"
  cat > "$FB/sysctl" <<'SH'
#!/usr/bin/env bash
[ "$*" = '-n kern.boottime' ] || exit 1
printf '{ sec = %s, usec = 0 }\n' "${FM_TEST_ORCA_BOOT_EPOCH:-2000}"
SH
  chmod +x "$FB/awk" "$FB/sysctl"
}

orca_meta_field() {  # <key>
  grep "^$1=" "$HOME_DIR/state/$TASK.meta" | tail -1 | cut -d= -f2-
}

test_orca_relaunch_rebinds_a_closed_terminal_in_the_recorded_worktree() {
  orca_relaunch_case closed
  orca_relaunch_show false operator_close
  orca_relaunch --harness claude
  expect_code 0 "$STATUS" "a relaunch of a closed, agent-free Orca terminal should succeed"$'\n'"$OUT"
  [ -f "$CASE_DIR/terminal-create.log" ] || fail "the relaunch should create a new terminal"$'\n'"$OUT"
  assert_contains "$(cat "$CASE_DIR/terminal-create.log")" "--worktree id:wt-1::$WT" \
    "the new terminal must be created in the recorded worktree"
  [ "$(orca_meta_field terminal)" = term-new ] || fail "the task record should name the new terminal, got '$(orca_meta_field terminal)'"
  [ "$(orca_meta_field harness)" = claude ] || fail "the task record should name the new harness, got '$(orca_meta_field harness)'"
  [ "$(orca_meta_field worktree)" = "$WT" ] || fail "the task record must keep its worktree, got '$(orca_meta_field worktree)'"
  [ -d "$WT" ] || fail "the relaunch must keep the recorded worktree"
  [ ! -e "$CASE_DIR/terminal-closed" ] || fail "a successful relaunch must not close the terminal it created"
  pass "an Orca relaunch of a closed, agent-free terminal creates a new terminal in the recorded worktree"
}

test_orca_relaunch_rebinds_a_stale_terminal_after_reboot() {
  local harness
  for harness in codex droid; do
    orca_relaunch_case "$harness"-reboot
    orca_relaunch_boot
    echo "harness=$harness" >> "$HOME_DIR/state/$TASK.meta"
    printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n' > "$CASE_DIR/show-term-old.json"
    echo 1 > "$CASE_DIR/show-term-old.exit"
    echo "spawn_gen=s1000.4242.99" >> "$HOME_DIR/state/$TASK.meta"
    FM_TEST_ORCA_BOOT_EPOCH=2000 orca_relaunch --harness claude
    expect_code 0 "$STATUS" "a relaunch of a pre-boot stale Orca terminal with no agent left should succeed"$'\n'"$OUT"
    [ -f "$CASE_DIR/terminal-create.log" ] || fail "the relaunch should create a new terminal"$'\n'"$OUT"
    [ "$(orca_meta_field terminal)" = term-new ] || fail "the task record should name the new terminal, got '$(orca_meta_field terminal)'"
    [ "$(orca_meta_field worktree)" = "$WT" ] || fail "the task record must keep its worktree, got '$(orca_meta_field worktree)'"
  done
  pass "an Orca relaunch rebinds a stale terminal recorded before the host reboot in the recorded worktree"
}

test_orca_droid_relaunch_keeps_non_reboot_prerequisites() {
  local state
  for state in closed stale; do
    orca_relaunch_case "droid-$state-no-marker"
    echo 'harness=droid' >> "$HOME_DIR/state/$TASK.meta"
    if [ "$state" = closed ]; then
      orca_relaunch_show false operator_close
    else
      orca_relaunch_boot
      printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n' > "$CASE_DIR/show-term-old.json"
      echo 1 > "$CASE_DIR/show-term-old.exit"
      echo 'spawn_gen=s3000.4242.99' >> "$HOME_DIR/state/$TASK.meta"
    fi
    orca_relaunch --harness claude
    expect_code 1 "$STATUS" "Droid replacement without reboot or SessionEnd proof must refuse"$'\n'"$OUT"
    assert_contains "$OUT" "SessionEnd proof" "non-reboot Droid replacements must keep their original stop proof"
    [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "an unproven Droid replacement must create no terminal"
  done
  pass "Orca Droid relaunch retains non-reboot SessionEnd prerequisites"
}

test_orca_relaunch_refuses_a_stale_terminal_with_a_surviving_agent_after_reboot() {
  local harness
  local standin agent
  standin=$(fm_agent_standin "$TMP_ROOT/relaunch-standin") \
    || { pass "SKIP: Orca reboot surviving-agent relaunch (no agent stand-in survives here)"; return 0; }
  for harness in codex droid; do
    orca_relaunch_case "$harness"-reboot-survivor
    orca_relaunch_boot
    echo "harness=$harness" >> "$HOME_DIR/state/$TASK.meta"
    printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n' > "$CASE_DIR/show-term-old.json"
    echo 1 > "$CASE_DIR/show-term-old.exit"
    echo "spawn_gen=s1000.4242.99" >> "$HOME_DIR/state/$TASK.meta"
    ln -sf "$standin" "$CASE_DIR/claude"
    "$CASE_DIR/claude" 600 >/dev/null 2>&1 &
    agent=$!
    printf 'p%s\nn%s\n' "$agent" "$WT" >> "$CASE_DIR/lsof.out"
    FM_TEST_ORCA_BOOT_EPOCH=2000 orca_relaunch --harness claude
    kill "$agent" 2>/dev/null || true
    expect_code 1 "$STATUS" "a reboot-stale relaunch with an agent surviving in the worktree must refuse"$'\n'"$OUT"
    assert_contains "$OUT" "an agent process still runs in" "a surviving agent must be named as the reason"
    [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "the refusal must come before any terminal is created"$'\n'"$OUT"
    [ "$(orca_meta_field terminal)" = term-old ] || fail "the refusal must leave the task record unchanged"
  done
  pass "an Orca relaunch refuses a stale terminal while an agent survives in the recorded worktree after a reboot"
}

test_orca_relaunch_adopts_a_dead_connected_terminal() {
  local shell_pid fifo
  orca_relaunch_case dead
  fifo="$CASE_DIR/hold"
  mkfifo "$fifo"
  bash -c 'exec 3<>"$0"; read -r _ <&3' "$fifo" >/dev/null 2>&1 &
  shell_pid=$!
  orca_relaunch_show true ''
  printf '{"ok":true,"result":{"worktrees":[{"sessions":[{"sessionId":"pty-old","pid":%s}]}]}}\n' "$shell_pid" > "$CASE_DIR/memory.json"
  orca_relaunch --harness claude
  kill "$shell_pid" 2>/dev/null || true
  expect_code 0 "$STATUS" "a relaunch into a dead Orca terminal should succeed"$'\n'"$OUT"
  [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "a dead terminal must be adopted, not replaced"$'\n'"$OUT"
  [ "$(orca_meta_field terminal)" = term-old ] || fail "an adopted terminal keeps its handle, got '$(orca_meta_field terminal)'"
  pass "an Orca relaunch adopts a connected terminal whose agent is proven stopped"
}

test_orca_droid_relaunch_connected_shell_without_marker() {
  local variant shell_pid fifo gen
  for variant in positive wrong-gen live-scan scan-fails; do
    orca_relaunch_case "droid-shell-$variant"
    echo 'harness=droid' >> "$HOME_DIR/state/$TASK.meta"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$TASK")
    "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$TASK" idle \
      --gen "$gen" --source droid-hook --event stop >/dev/null
    echo "busy_gen=$gen" >> "$HOME_DIR/state/$TASK.meta"
    case "$variant" in
      wrong-gen) printf 'g-other-generation\n' > "$HOME_DIR/state/$TASK.droid-session-end" ;;
      live-scan) printf 'p999\nn%s\n' "$WT" >> "$CASE_DIR/lsof.out" ;;
      scan-fails)
        printf '#!/usr/bin/env bash\nexit 2\n' > "$FB/lsof"
        chmod +x "$FB/lsof"
        ;;
    esac
    mv "$FB/orca" "$FB/orca-base"
    cat > "$FB/orca" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "terminal read" ]; then
  printf '{"ok":true,"result":{"terminal":{"tail":["shell"]}}}\n'
  exit 0
fi
exec "$(dirname "$0")/orca-base" "$@"
SH
    chmod +x "$FB/orca"
    fifo="$CASE_DIR/hold-$variant"
    mkfifo "$fifo"
    bash -c 'exec 3<>"$0"; read -r _ <&3' "$fifo" >/dev/null 2>&1 &
    shell_pid=$!
    orca_relaunch_show true ''
    printf '{"ok":true,"result":{"worktrees":[{"sessions":[{"sessionId":"pty-old","pid":%s}]}]}}\n' \
      "$shell_pid" > "$CASE_DIR/memory.json"
    orca_relaunch --harness claude
    kill "$shell_pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
    if [ "$variant" = positive ]; then
      expect_code 0 "$STATUS" "a Droid relaunch from a connected owned shell with no marker, a dead tree, an idle current record, and a clean scan should succeed"$'\n'"$OUT"
      [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "a connected-shell Droid relaunch must adopt its terminal, not replace it"$'\n'"$OUT"
      [ "$(orca_meta_field terminal)" = term-old ] || fail "an adopted Droid terminal keeps its handle, got '$(orca_meta_field terminal)'"
      [ ! -e "$HOME_DIR/state/$TASK.droid-session-end" ] || fail "the connected-shell proof must not synthesize a SessionEnd marker"
    else
      expect_code 1 "$STATUS" "the '$variant' Droid connected-shell relaunch must refuse"$'\n'"$OUT"
      assert_contains "$OUT" "absence proof" "the '$variant' refusal must name the missing absence proof"
      [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "the '$variant' refusal must come before any terminal is created"$'\n'"$OUT"
      [ "$(orca_meta_field terminal)" = term-old ] || fail "the '$variant' refusal must leave the task record unchanged"
    fi
  done
  pass "an Orca Droid relaunch adopts a connected owned shell without a marker, and refuses a wrong generation, a live worktree process, and a failed scan"
}

test_orca_droid_relaunch_rebinds_only_after_stop_and_terminal_proof() {
  local variant gen before
  for variant in closed stop-unverifiable unwritable wrong-gen live-scan scan-fails unreadable stale remote other-worktree unknown-writable; do
    orca_relaunch_case "droid-stopped-$variant"
    echo 'harness=droid' >> "$HOME_DIR/state/$TASK.meta"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$TASK")
    echo "busy_gen=$gen" >> "$HOME_DIR/state/$TASK.meta"
    printf '%s\n' "$gen" > "$HOME_DIR/state/$TASK.droid-session-end"
    orca_relaunch_show false operator_close
    case "$variant" in
      stop-unverifiable)
        printf '{"ok":true,"result":{"terminal":{"handle":"term-old","ptyId":"pty-old","connected":false,"writable":false,"exitCause":{"kind":"unknown","reason":"stop_unverified"},"executionHostId":"local","worktreePath":"%s"}}}\n' \
          "$WT" > "$CASE_DIR/show-term-old.json"
        ;;
      unwritable)
        printf '{"ok":true,"result":{"terminal":{"handle":"term-old","ptyId":"pty-old","connected":true,"writable":false,"exitCause":null,"executionHostId":"local","worktreePath":"%s"}}}\n' \
          "$WT" > "$CASE_DIR/show-term-old.json"
        ;;
      wrong-gen) printf 'another-generation\n' > "$HOME_DIR/state/$TASK.droid-session-end" ;;
      live-scan) printf 'p999\nn%s\n' "$WT" >> "$CASE_DIR/lsof.out" ;;
      scan-fails)
        printf '#!/usr/bin/env bash\nexit 2\n' > "$FB/lsof"
        chmod +x "$FB/lsof"
        ;;
      unreadable) rm "$CASE_DIR/show-term-old.json" ;;
      remote)
        sed 's/"executionHostId":"local"/"executionHostId":"remote"/' "$CASE_DIR/show-term-old.json" > "$CASE_DIR/show-remote.json"
        mv "$CASE_DIR/show-remote.json" "$CASE_DIR/show-term-old.json"
        ;;
      other-worktree) orca_relaunch_show false operator_close "$CASE_DIR/proj" ;;
      unknown-writable)
        printf '{"ok":true,"result":{"terminal":{"handle":"term-old","ptyId":"pty-old","connected":true,"executionHostId":"local","worktreePath":"%s"}}}\n' \
          "$WT" > "$CASE_DIR/show-term-old.json"
        ;;
      stale)
        orca_relaunch_boot
        echo 'spawn_gen=s3000.4242.99' >> "$HOME_DIR/state/$TASK.meta"
        printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n' > "$CASE_DIR/show-term-old.json"
        echo 1 > "$CASE_DIR/show-term-old.exit"
        ;;
    esac
    printf 'uncommitted task work\n' > "$WT/keep.txt"
    before=$(cat "$HOME_DIR/state/$TASK.meta")
    orca_relaunch --harness claude
    case "$variant" in
      closed|stop-unverifiable)
        expect_code 0 "$STATUS" "a stopped Droid task with a proven $variant terminal must rebind"$'\n'"$OUT"
        assert_contains "$(cat "$CASE_DIR/terminal-create.log")" "--worktree id:wt-1::$WT" \
          "the replacement terminal must use the recorded worktree"
        [ "$(orca_meta_field terminal)" = term-new ] || fail "the stopped Droid task must record the new endpoint"
        [ "$(orca_meta_field worktree)" = "$WT" ] || fail "the stopped Droid task must keep its worktree"
        assert_contains "$(cat "$CASE_DIR/terminal-send.log")" "cd -- '$WT'" \
          "the replacement must enter the recorded worktree"
        assert_not_contains "$(cat "$CASE_DIR/terminal-send.log")" '--terminal term-old' \
          "a closed terminal must receive no relaunch input"
        ;;
      *)
        expect_code 1 "$STATUS" "a $variant Droid stop or terminal proof must refuse"$'\n'"$OUT"
        [ "$variant" != unwritable ] || assert_contains "$OUT" "not proven writable or closed" \
          "a connected unwritable terminal must refuse at the terminal check"
        [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "an unproven relaunch must create no endpoint"
        [ "$(cat "$HOME_DIR/state/$TASK.meta")" = "$before" ] || fail "a refused relaunch must preserve the task record"
        ;;
    esac
    [ "$(cat "$WT/keep.txt")" = 'uncommitted task work' ] || fail "relaunch must preserve unlanded work"
  done
  pass "a stopped Orca Droid task replaces only a proven closed terminal, refuses a connected unwritable one, and preserves unlanded work"
}

# orca_droid_pane: turns the fake Orca into a replacement terminal whose pane
# really sources the staged launch, runs the generated Droid UserPromptSubmit
# hook through a `droid` stand-in, stays up, and shows Droid's captured idle screen.
orca_droid_pane() {
  node -e 'const fs = require("fs");
process.stdout.write(JSON.stringify({ ok: true, result: { terminal: {
  source: "screen", tail: fs.readFileSync(process.argv[1], "utf8").replace(/\n$/, "").split("\n") } } }));' \
    "$ROOT/tests/fixtures/droid/idle-orca-0.230.0.txt" > "$CASE_DIR/screen.json"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-new","ptyId":"pty-new","connected":true,"writable":true,"exitCause":null,"executionHostId":"local","worktreePath":"%s"}}}\n' \
    "$WT" > "$CASE_DIR/show-term-new.json"
  cat > "$FB/droid" <<'SH'
#!/usr/bin/env bash
pwd -P > "$FM_TEST_ORCA_DIR/droid-cwd"
prev=
for a in "$@"; do
  [ "$prev" != --settings ] || settings=$a
  prev=$a
done
printf '%s\n' "$settings" > "$FM_TEST_ORCA_DIR/droid-settings-path"
jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings" > "$FM_TEST_ORCA_DIR/submit-hook"
printf '{"hook_event_name":"UserPromptSubmit","prompt":"brief"}' | bash "$FM_TEST_ORCA_DIR/submit-hook"
exec sleep 120
SH
  chmod +x "$FB/droid"
  mv "$FB/orca" "$FB/orca-base"
  cat > "$FB/orca" <<'SH'
#!/usr/bin/env bash
DIR=$FM_TEST_ORCA_DIR
case "$*" in
  "terminal read --help"*)
    echo '--screen'
    exit 0
    ;;
  "terminal read --terminal term-new --screen"*)
    cat "$DIR/screen.json"
    exit 0
    ;;
  "terminal send --terminal term-new --text "*/launch.*)
    "$(dirname "$0")/orca-base" "$@" || exit
    text=$6
    f=${text#*"'"}
    f=${f%%"'"*}
    # shellcheck disable=SC2016 # The pane shell expands its own argument.
    (cd "$(cat "$DIR/wt-path")" && exec bash -c '. "$1"' _ "$f") </dev/null >"$DIR/pane.out" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$DIR/pane.pid"
    printf '{"ok":true,"result":{"worktrees":[{"sessions":[{"sessionId":"pty-new","pid":%s}]}]}}\n' "$pid" > "$DIR/memory.json"
    exit 0
    ;;
esac
exec "$(dirname "$0")/orca-base" "$@"
SH
  chmod +x "$FB/orca"
  printf '%s\n' "$WT" > "$CASE_DIR/wt-path"
}

test_orca_droid_relaunch_stays_on_droid_through_fm_control() {
  local variant gen new_gen settings pane rc=0 out
  for variant in closed stop-unverifiable; do
    orca_relaunch_case "droid-to-droid-$variant"
    echo 'harness=droid' >> "$HOME_DIR/state/$TASK.meta"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$TASK")
    echo "busy_gen=$gen" >> "$HOME_DIR/state/$TASK.meta"
    printf '%s\n' "$gen" > "$HOME_DIR/state/$TASK.droid-session-end"
    orca_relaunch_show false operator_close
    [ "$variant" != stop-unverifiable ] || \
      printf '{"ok":true,"result":{"terminal":{"handle":"term-old","ptyId":"pty-old","connected":false,"writable":false,"exitCause":{"kind":"unknown","reason":"stop_unverified"},"executionHostId":"local","worktreePath":"%s"}}}\n' \
        "$WT" > "$CASE_DIR/show-term-old.json"
    orca_droid_pane
    rc=0
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$CASE_DIR" FM_TEST_ORCA_NEW_TERMINAL=term-new \
      FM_TEST_ORCA_BOOT_EPOCH=2000 FM_DROID_POLL_INTERVAL=0.1 PATH="$FB:$PATH" \
      "$ROOT/bin/fm-control.sh" "$TASK" relaunch --harness droid --note 'terminal closed' 2>&1) || rc=$?
    pane=$(cat "$CASE_DIR/pane.pid" 2>/dev/null || true)
    expect_code 0 "$rc" "fm-control must relaunch the $variant Droid task on Droid"$'\n'"$out"$'\n'"$(cat "$CASE_DIR/pane.out" 2>/dev/null)"
    assert_contains "$out" "relaunched $TASK harness=droid from=droid" "fm-control must report a Droid-to-Droid relaunch"
    [ "$(orca_meta_field harness)" = droid ] || fail "the $variant task must stay on Droid"
    [ "$(orca_meta_field terminal)" = term-new ] || fail "the $variant task must bind the replacement terminal"
    [ "$(orca_meta_field worktree)" = "$WT" ] || fail "the $variant task must keep its worktree"
    [ "$(cat "$CASE_DIR/droid-cwd")" = "$WT" ] || fail "the replacement Droid must start in the recorded worktree"
    assert_not_contains "$(cat "$CASE_DIR/terminal-send.log")" '--terminal term-old' \
      "the closed terminal must receive no relaunch input"
    new_gen=$(orca_meta_field busy_gen)
    [ -n "$new_gen" ] && [ "$new_gen" != "$gen" ] || fail "the replacement must arm a new busy generation, got '$new_gen'"
    assert_contains "$(cat "$HOME_DIR/state/$TASK.busy-state")" "gen=$new_gen" \
      "the replacement's hook must write the current generation"
    assert_contains "$(cat "$HOME_DIR/state/$TASK.busy-state")" 'state=busy source=droid-hook event=user-prompt-submit' \
      "readiness must rest on the replacement's prompt hook"
    [ ! -e "$HOME_DIR/state/$TASK.droid-session-end" ] || fail "the old SessionEnd marker must not survive into the replacement"
    settings=$(cat "$CASE_DIR/droid-settings-path")
    jq -r '.hooks.SessionEnd[0].hooks[0].command' "$settings" > "$CASE_DIR/end-hook"
    printf '{"reason":"other"}' | bash "$CASE_DIR/end-hook"
    [ "$(cat "$HOME_DIR/state/$TASK.droid-session-end")" = "$new_gen" ] \
      || fail "the replacement's re-armed SessionEnd hook must mark the current generation"
    if [ -n "$pane" ]; then
      pkill -P "$pane" 2>/dev/null || true
      kill "$pane" 2>/dev/null || true
    fi
  done
  pass "fm-control relaunches a closed or stop-unverifiable Orca Droid task on Droid in a new terminal with re-armed hooks"
}

test_orca_relaunch_refuses_without_proof_of_a_stopped_agent() {
  local name agent='' standin
  standin=$(fm_agent_standin "$TMP_ROOT/relaunch-standin") || standin=
  for name in live-agent agent-in-worktree unreadable ambiguous scan-fails; do
    orca_relaunch_case "$name"
    case "$name" in
      live-agent|agent-in-worktree|ambiguous)
        [ -n "$standin" ] || continue
        if [ "$name" = ambiguous ]; then
          ln -sf "$standin" "$CASE_DIR/notaharness"
        else
          ln -sf "$standin" "$CASE_DIR/claude"
        fi
        ;;
    esac
    case "$name" in
      live-agent|ambiguous)
        bash -c '"$0" 600 & wait' "$CASE_DIR/$( [ "$name" = ambiguous ] && echo notaharness || echo claude )" >/dev/null 2>&1 &
        agent=$!
        for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(pgrep -P "$agent" 2>/dev/null)" ] && break; sleep 0.1; done
        orca_relaunch_show true ''
        printf '{"ok":true,"result":{"worktrees":[{"sessions":[{"sessionId":"pty-old","pid":%s}]}]}}\n' "$agent" > "$CASE_DIR/memory.json"
        ;;
      agent-in-worktree)
        "$CASE_DIR/claude" 600 >/dev/null 2>&1 &
        agent=$!
        orca_relaunch_show false operator_close
        printf 'p%s\nn%s\n' "$agent" "$WT" >> "$CASE_DIR/lsof.out"
        ;;
      unreadable) ;;
      scan-fails)
        orca_relaunch_show false operator_close
        rm -f "$CASE_DIR/lsof.out"
        ;;
    esac
    orca_relaunch --harness claude
    if [ -n "$agent" ]; then
      pkill -P "$agent" 2>/dev/null || true
      kill "$agent" 2>/dev/null || true
      agent=
    fi
    expect_code 1 "$STATUS" "the '$name' relaunch has no proof of a stopped agent and must refuse"$'\n'"$OUT"
    [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "the '$name' refusal must come before any terminal is created"$'\n'"$OUT"
    [ "$(orca_meta_field terminal)" = term-old ] || fail "the '$name' refusal must leave the task record unchanged"
    [ "$(orca_meta_field harness)" = codex ] || fail "the '$name' refusal must keep the recorded harness"
    case "$name" in
      live-agent) assert_contains "$OUT" "reads 'alive'" "a live agent must be named as the reason" ;;
      ambiguous) assert_contains "$OUT" "reads 'ambiguous'" "an unrecognized process must be named as the reason" ;;
      unreadable) assert_contains "$OUT" "reads 'unreadable'" "an unreadable terminal must be named as the reason" ;;
      agent-in-worktree) assert_contains "$OUT" "an agent process still runs in" "a surviving agent must be named as the reason" ;;
      scan-fails) assert_contains "$OUT" "could not be read" "a failed scan must be named as the reason" ;;
    esac
  done
  [ -n "$standin" ] || pass "SKIP: Orca relaunch live-agent cases (no agent stand-in survives here)"
  pass "an Orca relaunch refuses a live agent, an agent left in the worktree, and any unprovable read"
}

test_orca_relaunch_takes_values_from_the_scoped_source() {
  local setting staged
  for setting in available unavailable; do
    orca_relaunch_case "env-$setting"
    orca_relaunch_show false operator_close
    printf 'scoped-source\n' > "$HOME_DIR/config/launch-env-tmux-session"
    printf 'GH_TOKEN\n' > "$HOME_DIR/config/launch-env-allowlist"
    cat > "$FB/tmux" <<'EOF'
#!/usr/bin/env bash
[ "${FM_TEST_SOURCE_UNAVAILABLE:-0}" != 1 ] || exit 1
case "$*" in
  "-u show-environment -t =scoped-source"|"-u show-environment -t =scoped-source GH_TOKEN") ;;
  *) exit 2 ;;
esac
printf 'GH_TOKEN=scoped-relaunch-token\n'
EOF
    chmod +x "$FB/tmux"
    OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$CASE_DIR" FM_TEST_ORCA_NEW_TERMINAL=term-new \
      FM_TEST_ORCA_LOG="$CASE_DIR/terminal.log" FM_TEST_ORCA_CONSUME=1 \
      FM_TEST_SOURCE_UNAVAILABLE="$([ "$setting" = unavailable ] && echo 1 || echo 0)" \
      PATH="$FB:$PATH" "$SPAWN" "$TASK" --relaunch --harness claude 2>&1)
    STATUS=$?
    if [ "$setting" = unavailable ]; then
      expect_code 1 "$STATUS" "a relaunch whose scoped source cannot be read must refuse"$'\n'"$OUT"
      [ ! -e "$CASE_DIR/terminal-create.log" ] || fail "an unreadable source must refuse before a terminal is created"
      [ "$(orca_meta_field terminal)" = term-old ] || fail "an unreadable source must leave the task record unchanged"
      continue
    fi
    expect_code 0 "$STATUS" "a relaunch with a scoped source should succeed"$'\n'"$OUT"
    assert_not_contains "$OUT" "warning: backend=orca" "a relaunch with a scoped source must not fall back to the Orca terminal's values"
    staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$CASE_DIR/terminal.log" | tail -1)
    [ -f "$staged.copy" ] || fail "the relaunch did not stage its launch through a private file"$'\n'"$OUT"
    assert_contains "$(cat "$staged.copy")" scoped-relaunch-token "the replacement must take the allowlisted value from the scoped source"
    assert_contains "$(cat "$staged.copy")" GIT_CONFIG_NOSYSTEM=1 "the replacement must keep the system credential helper off"
    assert_not_contains "$(cat "$CASE_DIR/terminal.log")" scoped-relaunch-token "source values must stay off terminal input"
  done
  pass "an Orca relaunch takes allowlisted values from the scoped source, and refuses when it cannot be read"
}

# Source values are synthetic and deliberately include shell syntax and trailing
# newlines. Removing the source overlay, ambient clearing, or quoting breaks
# these executions of the real staged spawn command.
test_orca_launch_uses_controlled_tmux_environment() {
  local setting case_dir home id fb out status staged staged_content result expected value pane_shell failbin delivered
  for setting in absent enabled empty unavailable malformed nonregular missing sendfail; do
    id="orca-env-$setting"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'manual\n' > "$home/config/backlog-backend"
    printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
    if [ "$setting" = malformed ]; then printf 'wrong:selector\n' > "$home/config/launch-env-tmux-session"; fi
    if [ "$setting" = nonregular ]; then rm "$home/config/launch-env-tmux-session"; mkdir "$home/config/launch-env-tmux-session"; fi
    case "$setting" in
      enabled|missing|sendfail) printf 'GH_TOKEN\nGH_CONFIG_DIR\nFM_TEST_NOT_SET\nLANG\n' > "$home/config/launch-env-allowlist" ;;
      empty) : > "$home/config/launch-env-allowlist" ;;
      absent) ;;
      *) printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist" ;;
    esac
    [ "$setting" != missing ] || printf 'FM_TEST_ABSENT\n' >> "$home/config/launch-env-allowlist"
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Verify the controlled Orca environment source.

## Firstmate spec
Execute read-only environment checks.
EOF
    cat > "$case_dir/probe.sh" <<'EOF'
#!/bin/sh
launch_file=$(cat "$1")
[ ! -e "$launch_file" ] || { echo 'launch file still contains credentials when the worker starts' >&2; exit 1; }
printf '%s\n' "${GH_TOKEN-unset}" "${GH_CONFIG_DIR-unset}" "${DATABASE_URL-unset}" "${FM_TEST_NOT_SET-unset}" "${FM_TEST_PERSONAL-unset}" "${GIT_CONFIG_NOSYSTEM-unset}" "${LANG-unset}"
EOF
    value="synthetic-' \$(touch $case_dir/injected) \`false\`"$'\nline\n\n'
    VALUE="$value" python3 - "$case_dir/source.json" <<'PY'
import json,os,sys
with open(sys.argv[1], 'w') as f:
 json.dump({'GH_TOKEN':os.environ['VALUE'], 'GH_CONFIG_DIR':'scoped-gh', 'DATABASE_URL':'readonly-db', 'FM_TEST_NOT_SET':None, 'LANG':None}, f)
PY
    fb=$(make_orca_fakebin "$case_dir")
    cat > "$fb/tmux" <<'EOF'
#!/usr/bin/env python3
import json,os,sys
if os.environ.get('FM_TEST_SOURCE_UNAVAILABLE') == '1': sys.exit(1)
if sys.argv[1:5] != ['-u','show-environment','-t','=scoped-source']: sys.exit(2)
with open(os.environ['FM_TEST_ORCA_DIR']+'/source.json') as f: data=json.load(f)
names=[sys.argv[5]] if len(sys.argv)>5 else data
for name in names:
 if name not in data: sys.exit(1)
 value=data[name]
 print('-'+name if value is None else name+'='+value)
EOF
    chmod +x "$fb/tmux"
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
      FM_TEST_SOURCE_UNAVAILABLE="$([ "$setting" = unavailable ] && echo 1 || echo 0)" \
      FM_TEST_ORCA_SEND_FAIL="$([ "$setting" = sendfail ] && echo 1 || echo 0)" \
      FM_TEST_ORCA_CONSUME=1 \
      PATH="$fb:$PATH" "$SPAWN" "$id" "$case_dir/project" \
      --mode direct-PR --yolo off --backend orca --harness "/bin/sh '$case_dir/probe.sh' '$case_dir/stage-path'" 2>&1)
    status=$?
    if [ "$setting" = absent ] || [ "$setting" = unavailable ] || [ "$setting" = malformed ] || [ "$setting" = nonregular ] || [ "$setting" = missing ]; then
      expect_code 1 "$status" "unavailable source must refuse: $out"
      [ ! -d "$case_dir/orca-worktrees" ] || fail "source refusal allocated a worktree"
      [ ! -f "$home/state/$id.meta" ] || fail "source refusal published metadata"
      assert_not_contains "$out" synthetic "source refusal leaked a source value"
      pass "Orca refuses source=$setting before allocating resources"
      continue
    fi
    if [ "$setting" = sendfail ]; then
      expect_code 1 "$status" "undelivered controlled-source launch must fail: $out"
      for staged in /tmp/fm-"$id"+*/launch.*.sh; do
        [ ! -e "$staged" ] || fail "undelivered launch left credentials in $staged"
      done
      pass "Orca removes the credential launch file when the launch cannot be delivered"
      continue
    fi
    expect_code 0 "$status" "controlled-source spawn should succeed: $out"
    assert_not_contains "$out" "warning: backend=orca" "a configured source must not warn about ambient Orca values"
    staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
    [ -f "$staged.copy" ] || fail "Orca did not receive the staged launch path"
    [ ! -e "$staged" ] || fail "spawn returned before the pane consumed the launch file"
    [ "$(cat "$staged.mode")" = 600 ] || fail "credential launch file is not private"
    [ "$(stat -c '%a' "$(dirname "$staged")" 2>/dev/null || stat -f '%Lp' "$(dirname "$staged")")" = 700 ] || fail "credential launch directory is not private"
    assert_not_contains "$(cat "$case_dir/terminal.log")" synthetic "source values leaked into terminal input"
    staged_content=$(cat "$staged.copy")
    printf '%s\n' "$staged" > "$case_dir/stage-path"
    failbin=$(fm_fakebin "$case_dir/delete-refusal")
    printf '#!/bin/sh\nexit 1\n' > "$failbin/rm"
    chmod +x "$failbin/rm"
    case "$setting" in
      enabled) expected="$value"$'\nscoped-gh\nunset\nunset\nunset\n1\nunset' ;;
      empty) expected=$'unset\nunset\nunset\nunset\nunset\n1\npersonal-lang' ;;
    esac
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      (umask 077; printf '%s\n' "$staged_content" > "$staged")
      # shellcheck disable=SC2016 # The child pane expands the source path and its failure status.
      result=$(env -i HOME="$case_dir/user-home" PATH="$failbin:$PATH" TERM=xterm \
        "$pane_shell" -i -c '. "$1"; fm_status=$?; [ "$fm_status" -ne 0 ] || exit 2; printf "\nSHELL-STILL-ALIVE\n"' _ "$staged" 2>&1)
      expect_code 0 "$?" "failed deletion must preserve the interactive $pane_shell pane"
      assert_contains "$result" 'cannot remove private launch file' "deletion failure must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "deletion refusal killed the interactive $pane_shell pane"
      [ -f "$staged" ] || fail "failed deletion unexpectedly removed the private launch file"
      mv "$staged" "$staged.reclaimed"
      # shellcheck disable=SC2016 # The child pane expands the source path and its failure status.
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        "$pane_shell" -i -c '. "$1"; fm_status=$?; [ "$fm_status" -ne 0 ] || exit 2; printf "\nSHELL-STILL-ALIVE\n"' _ "$staged.reclaimed" 2>&1)
      expect_code 0 "$?" "a launch file reclaimed before the pane unlinked it must refuse the worker in $pane_shell"
      assert_contains "$result" 'cannot remove private launch file' "a reclaimed launch file must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "a reclaimed launch file killed the interactive $pane_shell pane"
      mv "$staged.reclaimed" "$staged"
      # The line Orca actually received must keep an errexit pane open both when
      # its unlink fails and when the file was reclaimed before the pane opened it.
      delivered=$(grep "/launch\." "$case_dir/terminal.log" | tail -1)
      result=$(env -i HOME="$case_dir/user-home" PATH="$failbin:$PATH" TERM=xterm \
        "$pane_shell" -i -c "set -e; $delivered; printf '\nSHELL-STILL-ALIVE\n'" 2>&1)
      expect_code 0 "$?" "failed deletion must preserve an errexit $pane_shell pane"
      assert_contains "$result" 'cannot remove private launch file' "deletion failure under errexit must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "deletion refusal killed the errexit $pane_shell pane"
      assert_not_contains "$result" 'launch file still contains credentials' "deletion refusal under errexit ran the worker in $pane_shell"
      mv "$staged" "$staged.reclaimed"
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        "$pane_shell" -i -c "set -e; $delivered; printf '\nSHELL-STILL-ALIVE\n'" 2>&1)
      expect_code 0 "$?" "a launch file reclaimed before the pane opened it must preserve an errexit $pane_shell pane"
      assert_contains "$result" SHELL-STILL-ALIVE "a launch file reclaimed before sourcing killed the errexit $pane_shell pane"
      mv "$staged.reclaimed" "$staged"
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        GH_TOKEN=personal-token GH_CONFIG_DIR=personal-gh FM_TEST_PERSONAL=personal-value \
        FM_TEST_NOT_SET=personal-value GIT_CONFIG_NOSYSTEM=0 LANG=personal-lang \
        "$pane_shell" -c ". '$staged'") || fail "controlled-source launch failed in $pane_shell"
      [ "$result" = "$expected" ] || fail "Orca source/allowlist=$setting lost isolation or values in $pane_shell"$'\n'"actual: $result"
      [ ! -e "$case_dir/injected" ] || fail "source value executed shell syntax"
      [ ! -e "$staged" ] || fail "secret-bearing launch file survived sourcing in $pane_shell"
    done
    pass "Orca source/allowlist=$setting preserves controlled values, clears ambient credentials and keeps values off terminal input"
  done
}

# A spawn that fails after Orca accepted the launch leaves the terminal open,
# and that pane may still be about to source the launch file, so abort cleanup
# must not delete it out from under the pending source. The fake Orca accepts
# input without executing it, and a failed backlog transition aborts the spawn
# after delivery.
test_orca_spawn_waits_for_a_slow_pane_before_a_later_failure() {
  local case_dir home id=orca-env-unsourced fb out status staged real_axi
  real_axi=$(command -v tasks-axi) || { pass "skipped live-terminal launch file case (tasks-axi is not installed)"; return 0; }
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  "$real_axi" add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a failed Orca spawn after launch delivery.

## Firstmate spec
Confirm a slow pane still receives the staged launch file before the spawn fails later.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real_axi" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/tasks-axi"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" FM_TEST_ORCA_CONSUME=1 FM_TEST_ORCA_CONSUME_DELAY=3 \
    PATH="$fb:$PATH" "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose backlog transition failed reported success: $out"
  assert_contains "$out" "could not be moved to In flight" "the spawn did not fail at the backlog transition"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ -f "$staged.copy" ] || fail "spawn removed the launch file before a slow pane ran it: $staged"
  [ ! -e "$staged" ] || fail "the consumed launch file is still present: $staged"
  pass "an Orca spawn waits for a slow pane to consume its launch file before a later failure"
}

# A pane that accepts the source command but never runs it cannot unlink the
# credential-bearing file itself, so the spawn reclaims it and fails visibly.
test_orca_unrun_launch_file_is_reclaimed() {
  local case_dir home id=orca-env-unrun fb out status staged
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca pane that never runs the launch command.

## Firstmate spec
Confirm the staged credential file is reclaimed.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_ORCA_LAUNCH_CONSUME_POLLS=2 \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 1 "$status" "a spawn whose pane never ran the launch command must fail: $out"
  assert_contains "$out" "did not run the launch command" "the failure must name the unrun launch command"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ ! -e "$staged" ] || fail "an unrun launch left credentials in $staged"
  assert_contains "$(cat "$home/state/$id.status")" "did not run the launch command" "the failure must reach the task status"
  [ ! -e "$case_dir/terminal-closed" ] || fail "an unrun launch closed the Orca terminal"
  pass "an Orca spawn reclaims a launch file its pane never ran and fails visibly"
}

# A pane that unlinks the launch file after the spawn's last existence check but
# before its reclaim wins the race and launches the worker, so the spawn must
# treat the launch as consumed. The fake rm stands in for that pane.
test_orca_pane_wins_launch_file_race_at_deadline() {
  local case_dir home id=orca-env-race fb out status staged real_rm
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca pane that unlinks the launch file at the reclaim deadline.

## Firstmate spec
Confirm the spawn treats the launch as consumed.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  real_rm=$(command -v rm)
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  cat > "$fb/rm" <<SH
#!/bin/sh
if [ "\$#" -eq 2 ] && [ "\$1" = -- ]; then
  case "\$2" in
    /tmp/fm-$id+*/launch.*.sh) "$real_rm" -f -- "\$2"; exit 1 ;;
  esac
fi
exec "$real_rm" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/rm"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_ORCA_LAUNCH_CONSUME_POLLS=2 \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 0 "$status" "a spawn whose pane won the launch-file race must succeed: $out"
  assert_contains "$out" "spawned $id" "the spawn must report success when the pane consumed the launch file"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ ! -e "$staged" ] || fail "the launch file survived the race: $staged"
  assert_not_contains "$(cat "$home/state/$id.status" 2>/dev/null)" "refused the worker launch" "the spawn refused a launch the pane consumed"
  pass "an Orca spawn treats a launch file the pane unlinked at the deadline as consumed"
}

# A pane that sources the launch file but cannot unlink it refuses the worker
# and stays interactive; the spawn reclaims the file, fails, and must leave the
# Orca terminal open.
test_orca_launch_file_delete_failure_keeps_terminal() {
  local case_dir home id=orca-env-rmfail fb out status staged
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca pane that cannot remove the launch file.

## Firstmate spec
Confirm the worker is refused and the terminal stays open.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_ORCA_LAUNCH_CONSUME_POLLS=10 \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" FM_TEST_ORCA_RM_FAIL=1 PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 1 "$status" "a spawn whose pane could not remove the launch file must fail: $out"
  assert_contains "$(cat "$case_dir/pane.out")" 'cannot remove private launch file' "the pane must refuse the worker launch"
  assert_contains "$(cat "$case_dir/pane.out")" SHELL-STILL-ALIVE "the deletion refusal must keep the pane shell running"
  assert_contains "$(cat "$home/state/$id.status")" "could not remove the launch file" "the failure must reach the task status"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ ! -e "$staged" ] || fail "the spawn did not reclaim the launch file: $staged"
  [ ! -e "$case_dir/terminal-closed" ] || fail "a launch-file deletion failure closed the Orca terminal"
  pass "an Orca pane that cannot remove its launch file refuses the worker and keeps its terminal"
}

# A spawn interrupted after delivering the launch command is the last owner of
# the credential-bearing file, so it must reclaim it with the same arbitration
# as the consume deadline and leave the terminal open. Each case interrupts the
# real spawn either while it waits for the pane to consume the file or while the
# source text has been delivered but Enter has not. The copy taken before the
# signal stands in for a pane that opened the file just before the reclaim.
test_orca_interrupted_spawn_reclaims_launch_file() {
  local phase sig id case_dir home fb pid status staged i want delivered result
  for phase in consume enter; do
    for sig in TERM HUP INT; do
      id="orca-env-interrupt-$phase-$sig"
      case_dir="$TMP_ROOT/$id"
      home="$case_dir/home"
      mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
      touch "$home/state/.last-watcher-beat"
      printf 'manual\n' > "$home/config/backlog-backend"
      printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
      printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
      fm_git_init_commit "$case_dir/project"
      cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an interrupted Orca spawn after launch delivery.

## Firstmate spec
Confirm the staged credential file is reclaimed.
EOF
      fb=$(make_orca_fakebin "$case_dir")
      printf '#!/bin/sh\necho "GH_TOKEN=synthetic-interrupt-token"\n' > "$fb/tmux"
      chmod +x "$fb/tmux"
      # A background job ignores SIGINT on entry; restore the default so the
      # spawn receives INT as an interactive caller would deliver it.
      FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
        FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
        FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
        FM_TEST_ORCA_HOLD_TEXT="$([ "$phase" = enter ] && echo 1 || echo 0)" \
        PATH="$fb:$PATH" python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
        "$SPAWN" "$id" "$case_dir/project" --mode direct-PR --yolo off --backend orca \
        --harness "touch '$case_dir/worker-ran'" > "$case_dir/spawn.log" 2>&1 &
      pid=$!
      for ((i = 0; i < 300; i++)); do
        if [ "$phase" = enter ]; then
          [ ! -e "$case_dir/text-delivered" ] || break
        elif [ -f "$case_dir/terminal.log" ] &&
          [ "$(grep -A1 "/launch\." "$case_dir/terminal.log" | sed -n 2p)" = '' ] &&
          [ "$(grep -A1 "/launch\." "$case_dir/terminal.log" | wc -l | tr -d ' ')" = 2 ]; then
          break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      staged=
      [ ! -f "$case_dir/terminal.log" ] || staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
      if [ -z "$staged" ] || [ ! -f "$staged" ] || ! kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        touch "$case_dir/release"
        wait "$pid"
        fail "$phase/$sig: the spawn was not waiting on a delivered launch file: $(cat "$case_dir/spawn.log")"
      fi
      cp "$staged" "$case_dir/opened-launch.sh"
      kill -"$sig" "$pid"
      touch "$case_dir/release"
      wait "$pid"
      status=$?
      case "$sig" in TERM) want=143 ;; HUP) want=129 ;; INT) want=130 ;; esac
      expect_code "$want" "$status" "$phase/$sig: interrupted spawn must exit with the signal status: $(cat "$case_dir/spawn.log")"
      [ ! -e "$staged" ] || fail "$phase/$sig: interrupted spawn left credentials in $staged"
      [ ! -e "$case_dir/terminal-closed" ] || fail "$phase/$sig: interrupted spawn closed the Orca terminal"
      assert_contains "$(cat "$home/state/$id.status" 2>/dev/null)" "refused the worker launch" "$phase/$sig: the reclaim must reach the task status"
      if [ "$phase" = enter ]; then
        [ "$(grep -A1 "/launch\." "$case_dir/terminal.log" | wc -l | tr -d ' ')" = 1 ] || fail "$phase/$sig: spawn sent Enter after the interrupt"
      fi
      delivered=$(grep "/launch\." "$case_dir/terminal.log" | tail -1)
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        /bin/sh -c "set -e; $delivered; echo SHELL-STILL-ALIVE" 2>&1)
      assert_contains "$result" SHELL-STILL-ALIVE "$phase/$sig: the delivered line killed the pane after the reclaim"
      # shellcheck disable=SC2016 # The pane shell expands its own argument.
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        /bin/sh -c '. "$1" || true; echo SHELL-STILL-ALIVE' _ "$case_dir/opened-launch.sh" 2>&1)
      assert_contains "$result" 'cannot remove private launch file' "$phase/$sig: a pane that opened the file before the reclaim must refuse"
      assert_contains "$result" SHELL-STILL-ALIVE "$phase/$sig: the refusal killed the pane"
      [ ! -e "$case_dir/worker-ran" ] || fail "$phase/$sig: the worker ran after the spawn reclaimed its launch file"
      pass "an Orca spawn interrupted by $sig during the $phase step reclaims its launch file and refuses the worker"
    done
  done
}

# The spawn owns the credential-bearing file from the moment it publishes it, so
# an interrupt before the launch command is sent must still remove it. A fake
# sleep holds the spawn in the pause right after publishing.
test_orca_interrupted_spawn_before_send_removes_launch_file() {
  local sig id case_dir home fb pid status staged i want
  for sig in TERM HUP INT; do
    id="orca-env-interrupt-publish-$sig"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'manual\n' > "$home/config/backlog-backend"
    printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
    printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca spawn interrupted before launch delivery.

## Firstmate spec
Confirm the staged credential file is removed.
EOF
    fb=$(make_orca_fakebin "$case_dir")
    printf '#!/bin/sh\necho "GH_TOKEN=synthetic-interrupt-token"\n' > "$fb/tmux"
    cat > "$fb/sleep" <<SH
#!/bin/sh
if [ "\$1" = 0.3 ] && [ ! -e '$case_dir/published' ]; then
  for f in /tmp/fm-$id+*/launch.*.sh; do
    [ -f "\$f" ] || continue
    printf '%s\n' "\$f" > '$case_dir/published'
    i=0
    while [ ! -e '$case_dir/release' ] && [ "\$i" -lt 100 ]; do /bin/sleep 0.1; i=\$((i + 1)); done
  done
fi
exec /bin/sleep "\$@"
SH
    chmod +x "$fb/tmux" "$fb/sleep"
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
      PATH="$fb:$PATH" python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
      "$SPAWN" "$id" "$case_dir/project" --mode direct-PR --yolo off --backend orca \
      --harness "touch '$case_dir/worker-ran'" > "$case_dir/spawn.log" 2>&1 &
    pid=$!
    for ((i = 0; i < 300; i++)); do
      [ ! -s "$case_dir/published" ] || break
      kill -0 "$pid" 2>/dev/null || break
      /bin/sleep 0.1
    done
    staged=$(cat "$case_dir/published" 2>/dev/null)
    if [ -z "$staged" ] || [ ! -f "$staged" ] || ! kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      touch "$case_dir/release"
      wait "$pid"
      fail "$sig: the spawn was not paused after publishing its launch file: $(cat "$case_dir/spawn.log")"
    fi
    kill -"$sig" "$pid"
    touch "$case_dir/release"
    wait "$pid"
    status=$?
    case "$sig" in TERM) want=143 ;; HUP) want=129 ;; INT) want=130 ;; esac
    expect_code "$want" "$status" "publish/$sig: interrupted spawn must exit with the signal status: $(cat "$case_dir/spawn.log")"
    [ ! -e "$staged" ] || fail "publish/$sig: interrupted spawn left credentials in $staged"
    ! grep -q "/launch\." "$case_dir/terminal.log" 2>/dev/null || fail "publish/$sig: spawn sent the launch command after the interrupt"
    [ ! -e "$case_dir/worker-ran" ] || fail "publish/$sig: the worker ran after the interrupt"
    pass "an Orca spawn interrupted by $sig before sending the launch command removes its launch file"
  done
}

# tmux versions differ on whether they keep invalid UTF-8, so pin the adapter
# itself: whatever bytes tmux reports must reach the shell assignment unchanged.
test_orca_snapshot_keeps_raw_bytes_tmux_reports() {
  local case_dir fb assignments
  case_dir="$TMP_ROOT/raw-bytes"
  mkdir -p "$case_dir"
  fb=$(fm_fakebin "$case_dir")
  cat > "$fb/tmux" <<'EOF'
#!/bin/sh
[ "$#" -ge 5 ] || exit 0
printf 'GH_TOKEN=raw-\377\376-'"'"'q\n'
EOF
  chmod +x "$fb/tmux"
  printf 'raw-\377\376-'"'"'q' > "$case_dir/expected"
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  assignments=$(PATH="$fb:$PATH" bash -c '. "$1"; fm_backend_orca_launch_env_args scoped GH_TOKEN' _ "$ROOT/bin/backends/orca.sh") \
    || fail "snapshot refused a value with bytes that are not valid UTF-8"
  # shellcheck disable=SC2016 # The child shell expands the exported value.
  sh -c "export $assignments; printf %s \"\$GH_TOKEN\"" > "$case_dir/observed"
  cmp -s "$case_dir/expected" "$case_dir/observed" || fail "snapshot altered bytes tmux reported"
  pass "the Orca snapshot passes through bytes tmux reports even when they are not valid UTF-8"
}

# Without a configured source, a nonempty allowlist on Orca still resolves from
# the Orca terminal; the spawn proceeds unchanged but says so on stderr.
test_orca_allowlist_without_source_warns() {
  local allowlist case_dir home id fb out status
  for allowlist in named empty; do
    id="orca-warn-$allowlist"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'codex\n' > "$home/config/crew-harness"
    printf 'manual\n' > "$home/config/backlog-backend"
    if [ "$allowlist" = named ]; then
      printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
    else
      : > "$home/config/launch-env-allowlist"
    fi
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca allowlist without a configured source.

## Firstmate spec
Confirm the spawn reports where allowlisted values come from.
EOF
    fb=$(make_orca_fakebin "$case_dir")
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
      "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
    status=$?
    expect_code 0 "$status" "an Orca allowlist without a source should still spawn"$'\n'"$out"
    if [ "$allowlist" = named ]; then
      assert_contains "$out" "warning: backend=orca resolves config/launch-env-allowlist names from the Orca terminal" \
        "a named allowlist without a source must not fall back silently"
    else
      assert_not_contains "$out" "warning: backend=orca" "an empty allowlist forwards no credentials and must not warn"
    fi
  done
  pass "Orca warns when allowlisted names would resolve from the Orca terminal, and stays quiet for an empty allowlist"
}

# The real tmux client sanitizes control characters without UTF-8 mode. A
# private socket and synthetic environment catch corruption the stub cannot.
test_orca_source_preserves_values_without_utf8_locale() {
  local real_tmux case_dir
  real_tmux=$(command -v tmux) || fail "tmux is required for the Orca source locale regression"
  case_dir=$(TMPDIR=/tmp fm_test_tmproot oenv)
  if ! python3 - "$real_tmux" "$case_dir" "$ROOT/bin/backends/orca.sh" <<'PY'
import os, pathlib, shlex, shutil, subprocess, sys
tmux, directory, adapter = sys.argv[1:]
root = pathlib.Path(directory)
socket = str(root / 'tmux.sock')
env = {'PATH': os.environ['PATH'], 'HOME': directory, 'TERM': 'xterm'}
value = "synthetic-' $(false) `false`\nFM_TEST_PHANTOM=evil-é\n\n"
snapshot = '. "$1"; fm_backend_orca_launch_env_args scoped-source "$2"'
def call(args, environment=env):
    return subprocess.run(args, env=environment, capture_output=True, text=True,
                          check=True, timeout=10).stdout
try:
    call([tmux, '-S', socket, '-f', '/dev/null', 'new-session', '-d',
          '-s', 'scoped-source', 'sleep 60'], dict(env, SSH_AUTH_SOCK='/tmp/fm-test-personal-agent'))
    call([tmux, '-S', socket, 'set-environment', '-t', '=scoped-source', 'GH_TOKEN', value])
    call([tmux, '-S', socket, 'set-environment', '-r', '-t', '=scoped-source', 'FM_TEST_NOT_SET'])
    raw = b"synthetic-\xff\xfe-'not-utf8"
    subprocess.run([tmux, '-S', socket, 'set-environment', '-t', '=scoped-source', 'FM_TEST_RAW', raw],
                   env=env, check=True, timeout=10)
    call([tmux, '-S', socket, 'set-environment', '-g', 'FM_TEST_ABSENT', 'personal-global'])
    if call([tmux, '-u', '-S', socket, 'show-environment', '-t', '=scoped-source', 'SSH_AUTH_SOCK']) != 'SSH_AUTH_SOCK=/tmp/fm-test-personal-agent\n':
        raise AssertionError('real tmux did not automatically populate the synthetic personal agent')
    fakebin = root / 'bin'
    fakebin.mkdir()
    wrapper = fakebin / 'tmux'
    wrapper.write_text('#!/bin/sh\nexec '+shlex.quote(tmux)+' -S '+shlex.quote(socket)+' "$@"\n')
    wrapper.chmod(0o755)
    for locale in ['absent', 'C']:
        source_env = dict(env, PATH=str(fakebin)+os.pathsep+env['PATH'])
        if locale == 'C':
            source_env.update(LANG='C', LC_ALL='C', LC_CTYPE='C')
        for names in ['GH_TOKEN', 'GH_TOKEN\nFM_TEST_NOT_SET']:
            assignments = call(['bash', '-c', snapshot, '_', adapter, names], source_env)
            for shell in ['sh', 'bash', 'zsh']:
                if shell == 'zsh' and not shutil.which(shell):
                    continue
                observed = call([shell, '-c', 'export '+assignments+'; test "${SSH_AUTH_SOCK-unset}" = unset && test "${FM_TEST_NOT_SET-unset}" = unset && printf %s "$GH_TOKEN"'], env)
                if observed != value:
                    raise AssertionError('tmux source corrupted the synthetic value: locale='+locale+', shell='+shell)
        raw_assignments = subprocess.run(['bash', '-c', snapshot, '_', adapter, 'FM_TEST_RAW'], env=source_env,
                                         capture_output=True, check=True, timeout=10).stdout
        # tmux versions differ on invalid UTF-8, so compare against the exact
        # bytes this tmux reports rather than the bytes that were set.
        record = subprocess.run(['tmux', '-u', 'show-environment', '-t', '=scoped-source', 'FM_TEST_RAW'],
                                env=source_env, capture_output=True, check=True, timeout=10).stdout
        if not record.startswith(b'FM_TEST_RAW=') or not record.endswith(b'\n'):
            raise AssertionError('real tmux did not report the synthetic raw value')
        reported = record[len(b'FM_TEST_RAW='):-1]
        for shell in ['sh', 'bash', 'zsh']:
            if shell == 'zsh' and not shutil.which(shell):
                continue
            observed = subprocess.run([shell, '-c', b'export '+raw_assignments+b'; printf %s "$FM_TEST_RAW"'], env=env,
                                      capture_output=True, check=True, timeout=10).stdout
            if observed != reported:
                raise AssertionError('tmux source altered the bytes tmux reported: locale='+locale+', shell='+shell)
        for names in ['FM_TEST_ABSENT', 'FM_TEST_PHANTOM']:
            result = subprocess.run(['bash', '-c', snapshot, '_', adapter, names],
                                    env=source_env, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                raise AssertionError('missing session-local name was accepted: '+names)
            if 'evil' in result.stderr or 'personal-global' in result.stderr:
                raise AssertionError('snapshot refusal echoed a source value')
finally:
    subprocess.run([tmux, '-S', socket, 'kill-server'], env=env,
                   capture_output=True, timeout=10, check=False)
PY
  then fail "real-tmux source must preserve exact values and refuse missing names"; fi
  pass "real tmux preserves absent/C locale values and reported raw bytes, rejects missing/phantom names and excludes the automatic SSH agent"
}

test_orca_source_preserves_values_without_utf8_locale
test_orca_droid_relaunch_connected_shell_without_marker
test_orca_droid_relaunch_rebinds_only_after_stop_and_terminal_proof
test_orca_droid_relaunch_stays_on_droid_through_fm_control
test_orca_launch_uses_controlled_tmux_environment
test_orca_allowlist_without_source_warns
test_orca_spawn_waits_for_a_slow_pane_before_a_later_failure
test_orca_unrun_launch_file_is_reclaimed
test_orca_interrupted_spawn_reclaims_launch_file
test_orca_interrupted_spawn_before_send_removes_launch_file
test_orca_launch_file_delete_failure_keeps_terminal
test_orca_pane_wins_launch_file_race_at_deadline
test_orca_snapshot_keeps_raw_bytes_tmux_reports
test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_aborted_spawn_safe_deletes_or_records_its_created_branch
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run
test_orca_relaunch_rebinds_a_closed_terminal_in_the_recorded_worktree
test_orca_relaunch_rebinds_a_stale_terminal_after_reboot
test_orca_droid_relaunch_keeps_non_reboot_prerequisites
test_orca_relaunch_refuses_a_stale_terminal_with_a_surviving_agent_after_reboot
test_orca_relaunch_adopts_a_dead_connected_terminal
test_orca_relaunch_refuses_without_proof_of_a_stopped_agent
test_orca_relaunch_takes_values_from_the_scoped_source

echo "# all fm-spawn-orca-worktree tests passed"
