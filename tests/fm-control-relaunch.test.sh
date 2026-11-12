#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Relaunch is the only control verb that changes durable records, so these
# tests pin the transaction itself, hermetically (stubbed session provider, no
# real agent):
#   1. A same-harness relaunch keeps every identity axis and reuses the SAME
#      endpoint and worktree - it replaces an agent, it never forks a task.
#   2. A harness switch is one ordinary relaunch: the record follows, the
#      previous harness's per-task wiring is cleared, and profile axes chosen
#      for the old harness do not silently carry to the new one.
#   3. The progress note is required where the replacement needs it, lands in
#      the instructions the replacement reads, and never rewrites a charter.
#   4. A refusal before the agent is stopped changes nothing.
#   5. A launch failure after the agent is stopped keeps the prior record,
#      reports the concrete state, and preserves the work.
#   6. fm-spawn --relaunch refuses on its own: a live agent, a contradicting
#      flag, an extra positional, or a backend that cannot prove the previous
#      agent exited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/treehouse-helpers.sh
. "$ROOT/tests/treehouse-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tasks-axi-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
X_LINK="$ROOT/bin/fm-x-link.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
# An explicit socket (the tmux absence proof and reclaim address the recorded
# one) is recorded and otherwise answered like the ambient server.
SOCK=${TMUX:-}
SOCK=${SOCK%%,*}
if [ "${1:-}" = -S ]; then
  printf '%s\n' "${2:-}" >> "$D/socket-args"
  SOCK=${2:-}
  shift 2
fi
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
    if [ -s "$D/capture" ]; then
      printf '%s\n' "$payload" >> "$D/picker-keys"
    fi
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal-raw"
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
      if { [ "$payload" = Escape ] || [ "$payload" = C-c ]; } \
         && [ -f "$D/capture-after-interrupt" ]; then
        cat "$D/capture-after-interrupt" > "$D/capture"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *socket_path*)
          [ -n "${FM_FAKE_TMUX_SERVER_PID:-}" ] || { printf 'fakepane\n'; exit 0; }
          printf '%s\t%s\n' "$FM_FAKE_TMUX_SOCKET" "$FM_FAKE_TMUX_SERVER_PID"; exit 0 ;;
        '#{window_id}') printf '@9\n'; exit 0 ;;
        '#{pid}')
          if [ -f "$D/server-dead" ]; then echo "no server running on ${FM_FAKE_TMUX_SOCKET:-/tmp/tmux-1000/default}" >&2; exit 1; fi
          printf '%s\n' "${FM_FAKE_TMUX_SERVER_PID:-1}"; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          # A destroyed window has no pane, so there is no cwd to read. An
          # empty inventory must not keep answering the last known path.
          if [ ! -s "$D/windows" ]; then
            echo "can't find pane" >&2
            exit 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/capture" ]; then
      cat "$D/capture"
    elif [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  kill-window)
    rm -f "$D/capture"
    : > "$D/windows"
    printf 'zsh' > "$D/command"
    exit 0 ;;
  list-panes)
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  has-session)
    [ ! -f "$D/server-dead" ] || exit 1
    exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    printf '%s\n' "$SOCK" >> "$D/created-sockets"
    rm -f "$D/server-dead"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '%s\n' "$SOCK" >> "$D/created-sockets"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/literal-raw"
  : > "$dir/fake/keys"
  : > "$dir/fake/picker-keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness] [session]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude} ses=${4:-fmses}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$ses" > "$dir/fake/session-name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

add_pooled_ship_task() {
  local dir=$1 id=$2 harness=$3 wt
  add_ship_task "$dir" "$id" "$harness"
  fm_test_fake_treehouse "$dir/fakebin" "$dir/proj" "$dir/pool"
  wt=$("$dir/fakebin/treehouse" get --lease --no-fetch) || fail "could not allocate the relaunch fixture slot"
  "$dir/fakebin/treehouse" return "$wt" --force || fail "could not return the relaunch fixture slot"
  sed "s|^worktree=.*|worktree=$wt|" "$dir/home/state/$id.meta" > "$dir/pooled.meta"
  mv "$dir/pooled.meta" "$dir/home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  # agy on macOS refuses a HOME with no login keychain, so the throwaway HOME
  # carries a stand-in keychain file.
  mkdir -p "$dir/user-home/Library/Keychains" "$dir/user-home/.claude"
  : > "$dir/user-home/Library/Keychains/login.keychain-db"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_STAMP_TX_READY="${FM_FAKE_STAMP_TX_READY:-}" \
    FM_FAKE_STAMP_TX_RELEASE="${FM_FAKE_STAMP_TX_RELEASE:-}" \
    FM_REAL_MKTEMP="${FM_REAL_MKTEMP:-}" \
    FM_FAKE_MKTEMP_SPAWN_PAUSE_READY="${FM_FAKE_MKTEMP_SPAWN_PAUSE_READY:-}" \
    FM_FAKE_MKTEMP_SPAWN_PAUSE_RELEASE="${FM_FAKE_MKTEMP_SPAWN_PAUSE_RELEASE:-}" \
    FM_FAKE_MKTEMP_SPAWN_CONTINUE="${FM_FAKE_MKTEMP_SPAWN_CONTINUE:-}" \
    FM_REAL_CP="${FM_REAL_CP:-}" FM_FAKE_CP_RESTORE_FAIL="${FM_FAKE_CP_RESTORE_FAIL:-}" \
    FM_FAKE_RESTORE_PAUSE_READY="${FM_FAKE_RESTORE_PAUSE_READY:-}" \
    FM_FAKE_RESTORE_PAUSE_RELEASE="${FM_FAKE_RESTORE_PAUSE_RELEASE:-}" \
    FM_FAKE_RESTORE_PAUSE="${FM_FAKE_RESTORE_PAUSE:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  # agy on macOS refuses a HOME with no login keychain, so the throwaway HOME
  # carries a stand-in keychain file.
  mkdir -p "$dir/user-home/Library/Keychains"
  : > "$dir/user-home/Library/Keychains/login.keychain-db"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_STAMP_TX_READY:-}" ]; then
  case "$source_path" in
    *.meta.tx)
      printf '%s\n' "$source_path" > "$FM_FAKE_STAMP_TX_READY"
      while [ ! -e "$FM_FAKE_STAMP_TX_RELEASE" ]; do /bin/sleep 0.01; done
      ;;
  esac
fi
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_mktemp_spawn_err_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *fm-control-spawn*)
      if [ -n "${FM_FAKE_MKTEMP_SPAWN_PAUSE_READY:-}" ]; then
        : > "$FM_FAKE_MKTEMP_SPAWN_PAUSE_READY"
        while [ ! -e "$FM_FAKE_MKTEMP_SPAWN_PAUSE_RELEASE" ]; do /bin/sleep 0.01; done
      fi
      [ -n "${FM_FAKE_MKTEMP_SPAWN_CONTINUE:-}" ] || exit 1
      ;;
  esac
done
exec "$FM_REAL_MKTEMP" "$@"
SH
  chmod +x "$1/fakebin/mktemp"
}

make_cp_restore_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/cp" <<'SH'
#!/usr/bin/env bash
dest=
for dest in "$@"; do :; done
if [ -n "${FM_FAKE_RESTORE_PAUSE_READY:-}" ] && [ "$dest" = "${FM_FAKE_RESTORE_PAUSE:-}" ]; then
  : > "$FM_FAKE_RESTORE_PAUSE_READY"
  while [ ! -e "$FM_FAKE_RESTORE_PAUSE_RELEASE" ]; do /bin/sleep 0.01; done
fi
if [ -n "${FM_FAKE_CP_RESTORE_FAIL:-}" ] && [ "$dest" = "$FM_FAKE_CP_RESTORE_FAIL" ]; then
  exit 1
fi
exec "$FM_REAL_CP" "$@"
SH
  chmod +x "$1/fakebin/cp"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

# Give a case home a real backlog carrying <id>, so the relaunch path's paired
# backlog transition (bin/fm-backlog-transition-lib.sh) is live rather than
# skipped for want of a backlog file.
seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local dir=$1 id=$2 want=$3 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "relaunch fixture task" --kind ship --file "$file" >/dev/null
  [ "$want" != in_flight ] || tasks-axi start "$id" --file "$file" >/dev/null
}

backlog_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Hold <id>'s backlog item the way a captain hold does.
hold_backlog_item() {  # <case-dir> <id>
  tasks-axi hold "$2" --reason "captain owns publication and merge" --kind captain \
    --file "$1/home/data/backlog.md" >/dev/null
}

backlog_field() {  # <case-dir> <id> <field>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n "s/^  $3: *//p" | head -1
}

# Shadow tasks-axi so every verb that could move or release a row fails and is
# logged, while reads stay real. A relaunch that leaves the hold in force never
# calls one of them.
guard_tasks_axi_mutations() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  start|unhold|hold|reopen|done|block|unblock)
    printf '%s\n' "\$1" >> "$dir/fake/tasks-axi-mutations"
    echo 'error: "mutation refused by test guard"' >&2
    exit 1
    ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

# Shadow tasks-axi so every `start` fails and every other verb is real. A
# relaunch that re-reads the row before acting never calls it; one that assumes
# it must re-run the transition trips over it.
break_tasks_axi_start() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "start refused"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

# --- 1. same-harness relaunch -----------------------------------------------

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after launch worker_env
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  # This fake tmux reports no server pid, so its identity cannot be read: the
  # launch warns and goes on, and the record simply omits the identity.
  assert_contains "$out" "the tmux server identity for" "an unreadable tmux server identity must be warned about, never fatal"
  [ -z "$(meta_field "$dir" rl1 tmux_socket)" ] || fail "a record must omit a tmux server identity it could not read"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement should have been launched"
  cat > "$dir/fakebin/claude" <<'SH'
#!/bin/sh
env | grep '^FM_' | sort
printf 'TEST_CREDENTIAL=%s\n' "${TEST_CREDENTIAL-unset}"
SH
  chmod +x "$dir/fakebin/claude"
  # The staged launch is one multi-line payload (env scrub, agent command,
  # then the OSC 7501 disarm), so take every line typed after the /exit.
  launch=$(awk 'seen { print } $0 == "/exit" { seen = 1 }' "$dir/fake/literal-raw")
  worker_env=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" SHELL=/bin/sh \
    FM_HOME=/synthetic/foreign FM_CREW_STATE_META_OVERRIDE=/synthetic/foreign.meta \
    FM_CREW_STATE_STATUS_OVERRIDE=/synthetic/foreign.status FM_SEND_RETRIES=7 \
    FM_TASK_ID=foreign FM_TASK_INBOX=/synthetic/foreign.inbox TEST_CREDENTIAL=keep \
    /bin/sh -c "$launch") || fail "relaunch command did not execute its replacement worker"
  # The ship works for its own home, so the launch replaces the foreign
  # FM_HOME with the task's home rather than inheriting or dropping it.
  [ "$worker_env" = "$(printf '%s\n' \
    "FM_HOME=$dir/home" 'FM_SEND_RETRIES=7' 'FM_TASK_ID=rl1' "FM_TASK_INBOX=$dir/home/state/rl1.inbox" \
    'TEST_CREDENTIAL=keep')" ] \
    || fail "relaunch inherited foreign FM variables or lost task values: $worker_env"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

# A signed-in agy lists at least one model; fm-spawn reads an empty listing
# as signed out and refuses before any custody check.
write_signed_in_fake_agy() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n'
exit 0
SH
  chmod +x "$1"
}

test_pooled_relaunch_custody_is_agy_only() {
  local dir prior target entry wt lock out rc harness
  . "$ROOT/bin/fm-wake-lib.sh"
  for entry in control spawn; do
    for prior in claude codex agy; do
      for target in claude codex agy; do
        dir=$(new_case "pool-$entry-$prior-$target" rl-pool)
        add_pooled_ship_task "$dir" rl-pool "$prior"
        wt=$(meta_field "$dir" rl-pool worktree)
        printf '%s' "$prior" > "$dir/fake/command"
        printf '%s' "$target" > "$dir/fake/becomes"
        for harness in claude codex; do
          printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/$harness"
          chmod +x "$dir/fakebin/$harness"
        done
        write_signed_in_fake_agy "$dir/fakebin/agy"
        fm_treehouse_pool_slot "$dir/proj" "$wt" || fail "the fixture is not a pooled checkout"
        [ ! -e "$(dirname "$wt")/.fm-slot-owner" ] || fail "the legacy fixture has an owner claim"
        lock=$(FM_HOME="$dir/home" fm_treehouse_project_lock_path "$dir/proj") || fail "could not resolve project lock"
        if [ "$prior" != agy ] && [ "$target" != agy ]; then
          fm_lock_try_acquire "$lock" || fail "could not hold the project lock"
        fi
        rc=0
        if [ "$entry" = control ]; then
          out=$(run_control "$dir" rl-pool relaunch --harness "$target" --note "recover the pooled task") || rc=$?
        else
          printf 'zsh' > "$dir/fake/command"
          out=$(run_spawn "$dir" rl-pool --relaunch --harness "$target") || rc=$?
        fi
        if [ "$prior" = agy ] || [ "$target" = agy ]; then
          expect_code 1 "$rc" "$entry must refuse an AGY transition without custody: $out"
          assert_contains "$out" 'ownership=absent' "$entry did not check AGY custody: $out"
          [ -z "$(cat "$dir/fake/literal")" ] || fail "an AGY custody refusal sent lifecycle bytes"
        else
          fm_lock_release "$lock"
          expect_code 0 "$rc" "$entry broke the legacy $prior to $target relaunch: $out"
          [ "$(meta_field "$dir" rl-pool worktree)" = "$wt" ] || fail "legacy relaunch changed checkout"
          [ "$(meta_field "$dir" rl-pool harness)" = "$target" ] || fail "legacy relaunch lost the replacement harness"
          [ "$(cat "$dir/fake/command")" = "$target" ] || fail "legacy replacement did not launch"
        fi
      done
    done
  done
  pass "pooled relaunches preserve legacy compatibility and require custody for either AGY harness"
}

test_agy_relaunch_requires_treehouse_capabilities_before_stopping() {
  local dir entry capability expected prior target before out rc
  for entry in control spawn; do
    while IFS='|' read -r capability expected prior target; do
      dir=$(new_case "capability-$entry-${capability//:/-}-$prior" rl-capability)
      add_pooled_ship_task "$dir" rl-capability "$prior"
      write_signed_in_fake_agy "$dir/fakebin/agy"
      printf '%s\n' "$capability" > "$dir/fakebin/treehouse.missing"
      before=$(cat "$dir/home/state/rl-capability.meta")
      rc=0
      if [ "$entry" = control ]; then
        printf '%s' "$prior" > "$dir/fake/command"
        out=$(run_control "$dir" rl-capability relaunch --harness "$target" --note "recover the pooled task") || rc=$?
        [ "$(cat "$dir/fake/command")" = "$prior" ] || fail "capability refusal stopped the old worker"
      else
        printf 'zsh' > "$dir/fake/command"
        out=$(run_spawn "$dir" rl-capability --relaunch --harness "$target") || rc=$?
      fi
      expect_code 1 "$rc" "$entry accepted missing Treehouse $expected: $out"
      assert_contains "$out" "AGY custody requires 'treehouse $expected'" "$entry lost the capability refusal: $out"
      [ -z "$(cat "$dir/fake/literal")$(cat "$dir/fake/keys")" ] || fail "capability refusal sent lifecycle bytes"
      [ "$(cat "$dir/home/state/rl-capability.meta")" = "$before" ] || fail "capability refusal changed task metadata"
      assert_absent "$dir/home/state/rl-capability.control-relaunch" "capability refusal opened a relaunch transaction"
    done <<'EOF'
lease|lease --lease-holder|claude|agy
status:json|status --json|claude|agy
return:if-lease-holder|return --if-lease-holder|claude|agy
status:json|status --json|agy|claude
status:json|status --json|agy|agy
EOF
  done
  pass "AGY relaunch checks Treehouse capabilities before stopping or replacing a worker"
}

test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text() {
  local dir out rc
  dir=$(new_case pending-exit rl43)
  add_ship_task "$dir" rl43 claude
  printf 'i' > "$dir/fake/composer"

  out=$(run_control "$dir" rl43 relaunch --note "preserve the pending draft"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command into pending composer text"
  assert_contains "$out" "composer visibly holds pending text" \
    "the refusal should name the pending composer text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pending composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be concatenated onto pending composer text"
  pass "fm-control relaunch: pending composer text refuses before the exit command is typed"
}

test_relaunch_does_not_kill_an_untrusted_usage_limit_endpoint() {
  local dir out rc
  dir=$(new_case untrusted-limit rl85)
  add_ship_task "$dir" rl85 claude
  : > "$dir/fake/windows"
  printf '%s\n' \
    'You have hit your weekly limit for Opus.' \
    '' \
    ' ❯ 1. Switch to Sonnet' \
    '   2. Wait for the limit to reset' \
    '   3. Buy more credits' \
    '' \
    'Enter to confirm · Esc to cancel' > "$dir/fake/capture"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl85 relaunch --harness codex --note "untrusted limit pane"); rc=$?
  expect_code 1 "$rc" "an untrusted usage-limit endpoint must refuse rather than close"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an untrusted usage-limit endpoint must not be killed: $(cat "$dir/fake/command")"
  assert_contains "$out" "cannot trust" "the refusal should name the untrusted address"
  assert_not_contains "$out" "agent was stopped" "an untrusted address must leave the old agent running"
  [ -z "$(cat "$dir/fake/keys")" ] && [ -z "$(cat "$dir/fake/literal")" ] \
    || fail "an untrusted usage-limit endpoint must receive no lifecycle input"
  pass "fm-control relaunch: an untrusted usage-limit endpoint is not killed"
}

test_relaunch_refuses_an_unverified_pane_text_usage_limit() {
  local dir out rc
  dir=$(new_case usage-limit-relaunch rl80)
  add_ship_task "$dir" rl80 claude
  printf '%s\n' \
    'You have hit your weekly limit for Opus.' \
    '' \
    ' ❯ 1. Switch to Sonnet' \
    '   2. Wait for the limit to reset' \
    '   3. Buy more credits' \
    '' \
    'Enter to confirm · Esc to cancel' > "$dir/fake/capture"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl80 relaunch --harness codex --note "move off the limited account"); rc=$?
  expect_code 1 "$rc" "a pane-text usage-limit relaunch must refuse before close"$'\n'"$out"
  assert_contains "$out" "not live-verified" \
    "the refusal should name the unverified pane-text classifier"
  assert_contains "$out" "Queue until reset" \
    "pane-text usage-limit must not send the supervisor to relaunch"
  assert_not_contains "$out" "composer visibly holds pending text" \
    "a usage-limit screen must not be treated as pending composer text"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed into a usage-limit picker"
  [ ! -s "$dir/fake/picker-keys" ] \
    || fail "the live usage-limit picker received keys: $(cat "$dir/fake/picker-keys")"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unverified pane-text usage-limit must not be killed: $(cat "$dir/fake/command")"
  grep -qx 'fm-rl80' "$dir/fake/windows" \
    || fail "an unverified pane-text usage-limit must keep the window: $(cat "$dir/fake/windows")"
  [ "$(meta_field "$dir" rl80 harness)" = claude ] \
    || fail "a refused pane-text usage-limit must keep the prior harness"
  pass "fm-control relaunch: pane-text usage-limit refuses without kill or Enter"
}

test_relaunch_closes_a_grok_weekly_limit_composer_without_typing_enter() {
  local dir out rc sock ident
  dir=$(new_case grok-limit-relaunch rl96)
  add_ship_task "$dir" rl96 grok
  printf 'grok' > "$dir/fake/command"
  sock=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_addressed_socket' _ "$ROOT")
  ident=$(bash -c '. "$1/bin/fm-wake-lib.sh"; printf "%s" "$(fm_pid_identity "$2")" | tr "\t\n" "  "' _ "$ROOT" "$$")
  printf 'tmux_socket=%s\ntmux_server_pid=%s\ntmux_server_identity=%s\ntmux_window_id=%s\n' \
    "$sock" "$$" "$ident" @9 >> "$dir/home/state/rl96.meta"
  printf '%s\n' \
    '                                                                                             █' \
    '' \
    '  ┃' \
    '  ┃  You hit your weekly limit.' \
    '  ┃' \
    '  ┃' \
    '  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build' \
    '  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again' \
    '  ┃' \
    '  ┃  ↑/↓ navigate · y copy                                                  Enter:submit' \
    '  ┃' \
    '' \
    '  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss' > "$dir/fake/capture"
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_TMUX_SOCKET="$sock" FM_FAKE_TMUX_SERVER_PID=$$ \
    run_control "$dir" rl96 relaunch --harness codex --note "move off the limited grok account"); rc=$?
  expect_code 0 "$rc" "a Grok weekly-limit relaunch should close the endpoint and start the replacement"$'\n'"$out"
  assert_not_contains "$out" "composer visibly holds pending text" \
    "a Grok weekly-limit composer must not be treated as pending composer text"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed into a Grok weekly-limit composer"
  [ ! -s "$dir/fake/picker-keys" ] \
    || fail "the live Grok weekly-limit composer received keys before close: $(cat "$dir/fake/picker-keys")"
  [ -s "$dir/fake/literal" ] || [ -s "$dir/fake/keys" ] \
    || fail "replacement launch keys are allowed after the composer closed, but none were recorded"
  assert_contains "$out" "harness=codex from=grok" "the replacement should land on the named harness"
  [ "$(meta_field "$dir" rl96 harness)" = codex ] \
    || fail "the published record should follow the replacement harness"
  pass "fm-control relaunch: a Grok weekly-limit composer is closed without typing Enter"
}

test_busy_relaunch_closes_a_grok_weekly_limit_after_interrupt() {
  local dir out rc sock ident
  dir=$(new_case grok-limit-busy-relaunch rl97)
  add_ship_task "$dir" rl97 grok
  printf 'grok' > "$dir/fake/command"
  sock=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_addressed_socket' _ "$ROOT")
  ident=$(bash -c '. "$1/bin/fm-wake-lib.sh"; printf "%s" "$(fm_pid_identity "$2")" | tr "\t\n" "  "' _ "$ROOT" "$$")
  printf 'tmux_socket=%s\ntmux_server_pid=%s\ntmux_server_identity=%s\ntmux_window_id=%s\n' \
    "$sock" "$$" "$ident" @9 >> "$dir/home/state/rl97.meta"
  printf '%s\n' 'thinking hard' 'Ctrl+c:cancel' > "$dir/fake/capture"
  printf '%s\n' \
    '                                                                                             █' \
    '' \
    '  ┃' \
    '  ┃  You hit your weekly limit.' \
    '  ┃' \
    '  ┃' \
    '  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build' \
    '  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again' \
    '  ┃' \
    '  ┃  ↑/↓ navigate · y copy                                                  Enter:submit' \
    '  ┃' \
    '' \
    '  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss' > "$dir/fake/capture-after-interrupt"
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_TMUX_SOCKET="$sock" FM_FAKE_TMUX_SERVER_PID=$$ \
    run_control "$dir" rl97 relaunch --harness codex --note "move off the limited grok account"); rc=$?
  expect_code 0 "$rc" "a Grok weekly-limit that appears after interrupt should close and start the replacement"$'\n'"$out"
  grep -qx C-c "$dir/fake/keys" \
    || fail "a busy grok pane must receive its interrupt before close: $(cat "$dir/fake/keys")"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed into a Grok weekly-limit composer that appeared after interrupt"
  grep -qx Enter "$dir/fake/picker-keys" 2>/dev/null \
    && fail "the live Grok weekly-limit composer received Enter: $(cat "$dir/fake/picker-keys")"
  assert_contains "$out" "harness=codex from=grok" "the replacement should land on the named harness"
  [ "$(meta_field "$dir" rl97 harness)" = codex ] \
    || fail "the published record should follow the replacement harness"
  pass "fm-control relaunch: a Grok weekly-limit after busy interrupt is closed without typing Enter"
}

test_busy_relaunch_refuses_pane_text_usage_limit_after_interrupt() {
  local dir out rc gen
  dir=$(new_case usage-limit-busy-relaunch rl98)
  add_ship_task "$dir" rl98 claude
  printf '%s\n' \
    'You have hit your weekly limit for Opus.' \
    '' \
    ' ❯ 1. Switch to Sonnet' \
    '   2. Wait for the limit to reset' \
    '   3. Buy more credits' \
    '' \
    'Enter to confirm · Esc to cancel' > "$dir/fake/capture-after-interrupt"
  printf 'codex' > "$dir/fake/becomes"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl98)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/rl98.meta"
  out=$(run_control "$dir" rl98 relaunch --harness codex --note "move off the limited account"); rc=$?
  expect_code 1 "$rc" "a pane-text usage-limit after interrupt must refuse before close"$'\n'"$out"
  assert_contains "$out" "not live-verified" \
    "the refusal should name the unverified pane-text classifier"
  assert_contains "$out" "Queue until reset" \
    "pane-text usage-limit after interrupt must not send the supervisor to relaunch"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed into a usage-limit picker that appeared after interrupt"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unverified pane-text usage-limit after interrupt must not be killed: $(cat "$dir/fake/command")"
  grep -qx 'fm-rl98' "$dir/fake/windows" \
    || fail "an unverified pane-text usage-limit after interrupt must keep the window: $(cat "$dir/fake/windows")"
  [ "$(meta_field "$dir" rl98 harness)" = claude ] \
    || fail "a refused pane-text usage-limit after interrupt must keep the prior harness"
  pass "fm-control relaunch: pane-text usage-limit after busy interrupt refuses without kill or Enter"
}

test_interrupt_refuses_a_usage_limit_screen() {
  local dir out rc
  dir=$(new_case usage-limit-interrupt rl81)
  add_ship_task "$dir" rl81 claude
  printf '%s\n' \
    'You have hit your weekly limit for Opus.' \
    '' \
    ' ❯ 1. Switch to Sonnet' \
    '   2. Wait' \
    '' \
    'Enter to confirm · Esc to cancel' > "$dir/fake/capture"
  out=$(run_control "$dir" rl81 interrupt); rc=$?
  expect_code 1 "$rc" "interrupt must refuse a usage-limit screen"$'\n'"$out"
  assert_contains "$out" "usage-limit screen" "the refusal should name the usage-limit screen"
  assert_contains "$out" "Queue until reset" \
    "pane-text interrupt must not send the supervisor to relaunch"
  assert_not_contains "$out" "Relaunch onto another runtime" \
    "pane-text interrupt must not recommend a refusing relaunch"
  [ -z "$(cat "$dir/fake/keys")" ] || fail "interrupt typed a lifecycle key into a usage-limit screen: $(cat "$dir/fake/keys")"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused interrupt must leave the old agent running"
  pass "fm-control interrupt: a usage-limit screen is not sent a lifecycle key"
}

test_interrupt_refuses_a_grok_weekly_limit_and_names_relaunch() {
  local dir out rc
  dir=$(new_case grok-limit-interrupt rl97)
  add_ship_task "$dir" rl97 grok
  printf 'grok' > "$dir/fake/command"
  printf '%s\n' \
    '                                                                                             █' \
    '' \
    '  ┃' \
    '  ┃  You hit your weekly limit.' \
    '  ┃' \
    '  ┃' \
    '  ┃  1 (○) Buy more credits  Purchase credits to keep using Grok Build' \
    '  ┃  2 (○) Try Again         Resubmit the last prompt once you have usage again' \
    '  ┃' \
    '  ┃  ↑/↓ navigate · y copy                                                  Enter:submit' \
    '  ┃' \
    '' \
    '  Tab:next answer  │  Esc:scrollback  │  Shift+x:dismiss' > "$dir/fake/capture"
  out=$(run_control "$dir" rl97 interrupt); rc=$?
  expect_code 1 "$rc" "interrupt must refuse a Grok weekly-limit composer"$'\n'"$out"
  assert_contains "$out" "usage-limit screen" "the refusal should name the usage-limit screen"
  assert_contains "$out" "Relaunch onto another runtime instead" \
    "a Grok weekly-limit interrupt still names relaunch"
  assert_not_contains "$out" "Queue until reset" \
    "a Grok weekly-limit interrupt must not tell the supervisor to queue"
  [ -z "$(cat "$dir/fake/keys")" ] || fail "interrupt typed a lifecycle key into a Grok weekly-limit composer: $(cat "$dir/fake/keys")"
  [ "$(cat "$dir/fake/command")" = grok ] \
    || fail "a refused interrupt must leave the old agent running"
  pass "fm-control interrupt: a Grok weekly-limit composer names relaunch, not queue"
}

test_control_relaunch_of_a_gone_tmux_endpoint() {
  local dir out rc sock ident
  dir=$(new_case gone-endpoint rl82)
  add_ship_task "$dir" rl82 claude
  sock=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_addressed_socket' _ "$ROOT")
  ident=$(bash -c '. "$1/bin/fm-wake-lib.sh"; printf "%s" "$(fm_pid_identity "$2")" | tr "\t\n" "  "' _ "$ROOT" "$$")
  printf 'tmux_socket=%s\ntmux_server_pid=%s\ntmux_server_identity=%s\ntmux_window_id=%s\n' \
    "$sock" "$$" "$ident" @9 >> "$dir/home/state/rl82.meta"
  strand_endpoint "$dir" rl82
  out=$(FM_FAKE_TMUX_SOCKET="$sock" FM_FAKE_TMUX_SERVER_PID=$$ \
    run_control "$dir" rl82 relaunch --harness claude --note "reclaim a gone pane"); rc=$?
  expect_code 0 "$rc" "a gone tmux endpoint must be rebound rather than refused for an empty pane path"$'\n'"$out"
  assert_not_contains "$out" "not its recorded worktree" \
    "an unreadable gone-pane path must not trip the pre-stop worktree guard"
  [ "$(grep -c '^fm-rl82$' "$dir/fake/created-windows" 2>/dev/null)" = 1 ] \
    || fail "exactly the task's window must be re-created once, got: $(cat "$dir/fake/created-windows" 2>/dev/null)"
  [ "$(meta_field "$dir" rl82 window)" = "fmses:fm-rl82" ] \
    || fail "the record must rebind to the new window"
  pass "fm-control relaunch: a proven-gone tmux endpoint is rebound when its pane path is unreadable"
}

test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven() {
  local dir out rc
  dir=$(new_case unproven-exit rl44)
  add_ship_task "$dir" rl44 claude

  out=$(FM_FAKE_COMPOSER_READ_FAIL=1 \
    run_control "$dir" rl44 relaunch --note "preserve on an unreadable composer"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command when the visible pane cannot be read"
  assert_contains "$out" "could not read the visible pane" \
    "a failed pane read must refuse rather than treat the capture as no usage-limit"
  assert_not_contains "$out" "visibly holds pending text" \
    "an unreadable composer is not the same claim as observed pending text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unproven composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed when the visible pane cannot be read"
  [ ! -s "$dir/fake/keys" ] || fail "no lifecycle key may be sent when the pane cannot be read: $(cat "$dir/fake/keys")"
  pass "fm-control relaunch: an unreadable pane fails closed before the exit command is typed"
}

test_relaunch_refuses_before_exit_when_the_composer_is_not_proven_empty() {
  local dir out rc
  dir=$(new_case unknown-composer-exit rl44b)
  add_ship_task "$dir" rl44b claude
  printf '%s\n' 'a status line without a composer box' > "$dir/fake/capture"

  out=$(run_control "$dir" rl44b relaunch --note "preserve on an unknown composer"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command when the composer is not proven empty"
  assert_contains "$out" "not proven empty" \
    "a readable pane whose composer is unknown must refuse rather than type the exit command"
  assert_not_contains "$out" "could not read the visible pane" \
    "a working capture is not the same claim as a failed pane read"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unknown-composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed when the composer is not proven empty"
  [ ! -s "$dir/fake/keys" ] || fail "no lifecycle key may be sent when the composer is not proven empty: $(cat "$dir/fake/keys")"
  pass "fm-control relaunch: an unknown composer with a working capture refuses before the exit command is typed"
}

test_relaunch_from_linked_home_preserves_recorded_worktree() {
  local dir out rc head fetch_head
  dir=$(new_case linked-home rl42)
  add_ship_task "$dir" rl42 claude
  git -C "$dir/proj" worktree add --quiet --detach "$dir/secondmate" HEAD
  sed "s|^project=.*|project=$dir/secondmate|" "$dir/home/state/rl42.meta" > "$dir/linked.meta"
  mv "$dir/linked.meta" "$dir/home/state/rl42.meta"
  printf 'committed task work\n' > "$dir/wt/task.txt"
  git -C "$dir/wt" add task.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-work
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'unfinished task work\n' >> "$dir/wt/task.txt"
  fetch_head=$(git -C "$dir/wt" rev-parse --git-path FETCH_HEAD)

  out=$(run_control "$dir" rl42 relaunch --note "continue from linked home"); rc=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home relaunch\n'
    printf '$ bin/fm-control.sh rl42 relaunch --note "continue from linked home"\n%s\nexit=%s\n' "$out" "$rc"
    printf 'worker HEAD before=%s after=%s\n' "$head" "$(git -C "$dir/wt" rev-parse HEAD)"
    printf 'saved task metadata:\n'; cat "$dir/home/state/rl42.meta"
    printf 'worker status:\n'; git -C "$dir/wt" status --short
    printf 'preserved task.txt:\n'; cat "$dir/wt/task.txt"
    if [ -e "$fetch_head" ]; then
      printf 'worker FETCH_HEAD:\n'; cat "$fetch_head"
    else
      printf 'worker FETCH_HEAD absent\n'
    fi
    printf '# evidence end\n'
  fi
  expect_code 0 "$rc" "a linked spawning home should relaunch its recorded copy"$'\n'"$out"
  [ "$(meta_field "$dir" rl42 worktree)" = "$dir/wt" ] || fail "relaunch replaced the recorded copy"
  [ "$(meta_field "$dir" rl42 project)" = "$dir/secondmate" ] || fail "relaunch replaced the linked spawning home"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "relaunch reset committed task work"
  assert_grep 'unfinished task work' "$dir/wt/task.txt" "relaunch discarded unfinished task work"
  [ ! -e "$fetch_head" ] || fail "relaunch fetched instead of preserving the recorded copy"
  pass "fm-control relaunch: a linked spawning home preserves committed and unfinished work in the recorded copy"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=0123456789012345678901234567890123456789'
  } >> "$dir/home/state/rl19.meta"
  fm_pr_poll_prepare "$dir/home/state" rl19 github \
    https://github.com/example/repo/pull/19 github.com example/repo 19 \
    "$ROOT/bin/fm-pr-poll.sh" \
    || fail "could not prepare the PR poll fixture for relaunch"
  fm_pr_poll_publish_prepared \
    || fail "could not publish the PR poll fixture for relaunch"
  fm_pr_poll_artifacts_valid "$dir/home/state" rl19 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the PR poll fixture did not authenticate before relaunch"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "0123456789012345678901234567890123456789" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  fm_pr_poll_artifacts_valid "$dir/home/state" rl19 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "relaunch must keep an armed PR poll authenticated"
  pass "fm-control relaunch: an armed PR poll survives replacement launch publication"
}

test_traced_relaunch_keeps_an_armed_pr_poll_authenticated() {
  local dir out rc
  dir=$(new_case traced-pr-poll rl52)
  add_ship_task "$dir" rl52 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/52'
    printf '%s\n' 'pr_head=0123456789012345678901234567890123456789'
    printf '%s\n' 'x_request=request-52'
  } >> "$dir/home/state/rl52.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  fm_pr_poll_prepare "$dir/home/state" rl52 github \
    https://github.com/example/repo/pull/52 github.com example/repo 52 \
    "$ROOT/bin/fm-pr-poll.sh" \
    || fail "could not prepare the PR poll fixture for traced relaunch"
  fm_pr_poll_publish_prepared \
    || fail "could not publish the PR poll fixture for traced relaunch"
  fm_pr_poll_artifacts_valid "$dir/home/state" rl52 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the PR poll fixture did not authenticate before traced relaunch"

  out=$(run_control "$dir" rl52 relaunch --note "continuing traced review"); rc=$?
  expect_code 0 "$rc" "traced relaunch should succeed"$'\n'"$out"
  fm_trace_context_valid "$(meta_field "$dir" rl52 traceparent)" \
    || fail "traced relaunch must record the replacement trace carrier"
  [ "$(grep -c '^traceparent=' "$dir/home/state/rl52.meta")" = 1 ] \
    || fail "traced relaunch must leave exactly one trace carrier"
  [ "$(meta_field "$dir" rl52 x_request)" = request-52 ] \
    || fail "traced relaunch must keep the X request"
  fm_pr_poll_artifacts_valid "$dir/home/state" rl52 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "traced relaunch must keep an armed PR poll authenticated"
  pass "fm-control relaunch: a traced replacement keeps an armed PR poll authenticated"
}

test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare launch_release waiting ready release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  launch_release="$dir/trace-release"
  waiting="$dir/meta-writer-waiting"
  ready="$dir/meta-writer-ready"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_TRACE_RELEASE="$launch_release" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ ! -e "$ready" ] || {
    : > "$launch_release"
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during relaunch delivery"
  }
  : > "$launch_release"
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "durable metadata writer did not resume after relaunch delivery committed"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete before serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  pass "fm-control relaunch: delivery and concurrent task metadata publication serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  grep -q 'unset TRACEPARENT; .*claude' "$dir/fake/literal" \
    || fail "disabled relaunch must clear the pane carrier before replacement launch"
  ! grep -q 'export TRACEPARENT=' "$dir/fake/literal" \
    || fail "disabled relaunch must not export a replacement trace carrier"
  pass "fm-control relaunch: disabling tracing clears metadata and pane context"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief launch_brief first_line role_line task_line
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  cp "$ROOT/AGENTS.md" "$dir/wt/AGENTS.md"
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Exercise relaunch behavior for rl2." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  launch_brief="$dir/home/data/rl2/launch-brief.md"
  first_line=$(sed -n '1p' "$launch_brief")
  [ "$first_line" = '# Current worker role contract' ] ||
    fail "a Firstmate-worktree relaunch did not establish the crewmate identity first"
  role_line=$(grep -n '^# Current worker role contract$' "$launch_brief" | cut -d: -f1)
  task_line=$(grep -n '^# Task$' "$launch_brief" | head -1 | cut -d: -f1)
  [ "$role_line" -lt "$task_line" ] || fail "the relaunched worker identity followed its task content"
  assert_grep "$dir/home/state/rl2.inbox" "$launch_brief" \
    "the Firstmate-worktree relaunch omitted the worker's exact steering inbox"
  assert_grep 'do not reject it as another home' "$launch_brief" \
    "the Firstmate-worktree relaunch did not distinguish its inbox from cross-home state"
  pass "fm-control relaunch: progress and the Firstmate-worktree worker identity reach the replacement"
}

test_relaunch_note_inbox_listing_is_safe_on_empty_inbox() {
  local dir out rc brief cmd inbox shell_name status
  dir=$(new_case notelist rl2b)
  add_ship_task "$dir" rl2b claude
  out=$(run_control "$dir" rl2b relaunch --note "resume"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2b/brief.md"
  # shellcheck disable=SC2016
  cmd=$(sed -n 's/^`\(find [^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$cmd" ] || fail "the progress note does not give a find-based inbox listing command"
  inbox="$dir/home/state/rl2b.inbox"
  for shell_name in bash zsh; do
    command -v "$shell_name" >/dev/null 2>&1 || continue
    rm -rf "$inbox"
    status=0
    out=$("$shell_name" -c "$cmd" 2>&1) || status=$?
    [ "$status" -eq 0 ] && [ -z "$out" ] || fail "$shell_name: absent inbox listing was not silent success (exit $status): $out"
    mkdir -p "$inbox"
    status=0
    out=$("$shell_name" -c "$cmd" 2>&1) || status=$?
    [ "$status" -eq 0 ] && [ -z "$out" ] || fail "$shell_name: empty inbox listing was not silent success (exit $status): $out"
    : > "$inbox/1000.msg"
    : > "$inbox/999.msg"
    out=$("$shell_name" -c "$cmd" 2>&1 | sed 's#.*/##' | tr '\n' ' ')
    [ "$out" = "999.msg 1000.msg " ] || fail "$shell_name: messages not listed in numeric order: $out"
  done
  pass "fm-control relaunch: the progress note's inbox listing is silent on an empty inbox"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

# --- 2. harness switch -------------------------------------------------------

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_refused_relaunch_onto_polytoken_keeps_the_project_hook_layer() {
  local dir out rc
  dir=$(new_case polytokenownhooks rl45)
  add_ship_task "$dir" rl45 claude
  # The project's own polytoken hook layer and a same-named facet, neither
  # generated by firstmate; the refused arm and its abort cleanup must keep both.
  mkdir -p "$dir/wt/.polytoken/facets"
  printf '[{"name":"project-own","event":"stop","handler":{"bash":"/bin/true"}}]\n' \
    > "$dir/wt/.polytoken/hooks.json"
  printf -- '---\nname: firstmate-worker\n---\nproject facet\n' \
    > "$dir/wt/.polytoken/facets/firstmate-worker.md"
  printf 'polytoken' > "$dir/fake/becomes"
  # Profile validation precedes the hook-layer refusal, so the fixture must
  # advertise its explicit pin without requiring a real Polytoken installation.
  cat > "$dir/fakebin/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'print models') printf '%s\n' 'zai/glm-5.3-flash' 'zai/glm-5.3-flash(low)' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/polytoken"
  out=$(run_control "$dir" rl45 relaunch --harness polytoken \
    --model zai/glm-5.3-flash --effort low --note "switching runtime"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch onto polytoken over a project hook layer must refuse"$'\n'"$out"
  assert_contains "$out" "not firstmate's to clobber" \
    "the refusal must come from the polytoken arm"$'\n'"$out"
  assert_contains "$(cat "$dir/wt/.polytoken/hooks.json" 2>/dev/null)" "project-own" \
    "an aborted relaunch must leave the project's own hook layer in place"
  assert_contains "$(cat "$dir/wt/.polytoken/facets/firstmate-worker.md" 2>/dev/null)" "project facet" \
    "an aborted relaunch must leave a facet it did not generate in place"
  [ "$(meta_field "$dir" rl45 harness)" = claude ] \
    || fail "a refused relaunch must keep the prior record"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch onto polytoken must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch onto polytoken must not stop the agent"
  pass "fm-control relaunch: a refused relaunch onto polytoken keeps the project's own hook layer and the running agent"
}

test_refused_polytoken_profile_leaves_the_running_agent() {
  local dir out rc
  dir=$(new_case polytokenprofile rl47)
  add_ship_task "$dir" rl47 claude
  printf 'polytoken' > "$dir/fake/becomes"
  cat > "$dir/fakebin/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'print models') printf '%s\n' 'zai/glm-5.3-flash' 'zai/glm-5.3-flash(low)' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/polytoken"
  out=$(run_control "$dir" rl47 relaunch --harness polytoken --note "switching runtime"); rc=$?
  [ "$rc" -ne 0 ] || fail "a switch onto polytoken with default axes must refuse"$'\n'"$out"
  assert_contains "$out" "requires concrete --model and --effort" \
    "the refusal must name the missing worker profile"$'\n'"$out"
  out=$(run_control "$dir" rl47 relaunch --harness polytoken \
    --model zai/unlisted --effort low --note "switching runtime"); rc=$?
  [ "$rc" -ne 0 ] || fail "a switch onto an unlisted polytoken model must refuse"$'\n'"$out"
  assert_contains "$out" "is not listed by 'polytoken print models'" \
    "the refusal must come from the polytoken catalog"$'\n'"$out"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused polytoken profile must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused polytoken profile must not stop the agent"
  [ "$(meta_field "$dir" rl47 harness)" = claude ] || fail "a refused polytoken profile must keep the prior record"
  [ ! -e "$dir/wt/.polytoken" ] || fail "a refused polytoken profile must write no wiring"
  pass "fm-control relaunch: a refused polytoken profile leaves the running agent untouched"
}

test_relaunch_off_opencode_removes_tracked_wiring() {
  local dir out
  dir=$(new_case opencodetracked rl78)
  add_ship_task "$dir" rl78 opencode
  mkdir -p "$dir/wt/.opencode/plugins"
  printf 'prior busy plugin\n' > "$dir/wt/.opencode/plugins/fm-busy-state.js"
  git -C "$dir/wt" add .opencode/plugins/fm-busy-state.js
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "tracked prior wiring"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl78 --relaunch --harness claude)
  assert_contains "$out" "spawned rl78 harness=claude" "the relaunch off opencode should complete"
  [ ! -e "$dir/wt/.opencode/plugins/fm-busy-state.js" ] \
    || fail "retiring opencode wiring must still remove tracked files as on main"
  pass "fm-spawn --relaunch: tracked opencode wiring is retired as on main"
}

test_relaunch_from_a_raw_polytoken_launch_keeps_the_project_layers() {
  local dir out
  dir=$(new_case polytokenrawprior rl46)
  add_ship_task "$dir" rl46 polytoken
  # A raw-launched polytoken task never had firstmate wiring, so the tracked
  # project hook layer and an untracked facet it did not generate both belong
  # to the project and must outlive the prior-wiring retirement.
  mkdir -p "$dir/wt/.polytoken/facets"
  printf '[{"name":"project-own","event":"stop","handler":{"bash":"/bin/true"}}]\n' \
    > "$dir/wt/.polytoken/hooks.json"
  git -C "$dir/wt" add .polytoken/hooks.json
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "project hook layer"
  printf -- '---\nname: firstmate-worker\n---\nproject facet\n' \
    > "$dir/wt/.polytoken/facets/firstmate-worker.md"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl46 --relaunch --harness claude)
  assert_contains "$out" "spawned rl46 harness=claude" "the relaunch off polytoken should complete"
  assert_contains "$(cat "$dir/wt/.polytoken/hooks.json" 2>/dev/null)" "project-own" \
    "retiring the prior polytoken wiring must keep the project's tracked hook layer"
  assert_contains "$(cat "$dir/wt/.polytoken/facets/firstmate-worker.md" 2>/dev/null)" "project facet" \
    "retiring the prior polytoken wiring must keep a facet firstmate did not generate"
  [ -z "$(git -C "$dir/wt" status --porcelain -- .polytoken/hooks.json)" ] \
    || fail "the tracked project hook layer must be left unmodified"
  pass "fm-spawn --relaunch: retiring a raw polytoken launch's wiring keeps the project's own layers"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = xhigh ] \
    || fail "an effort named for the old harness must be kept when --effort is omitted"
  pass "fm-control relaunch: a harness switch resets model and keeps effort unless effort is named too"
}

test_harness_switch_falls_back_when_the_new_harness_refuses_carried_effort() {
  local dir out rc
  dir=$(new_case effort-fallback rl83)
  add_ship_task "$dir" rl83 claude
  sed 's/^effort=default$/effort=max/' \
    "$dir/home/state/rl83.meta" > "$dir/home/state/rl83.meta.tmp"
  mv "$dir/home/state/rl83.meta.tmp" "$dir/home/state/rl83.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl83 relaunch --harness codex --note "switch off Claude max"); rc=$?
  expect_code 0 "$rc" "a harness switch must not fail when the new harness refuses the carried effort"$'\n'"$out"
  assert_contains "$out" "notice: codex refused effort max; launching at default" \
    "the notice should name the old and new effort"
  [ "$(meta_field "$dir" rl83 effort)" = default ] \
    || fail "the replacement should land at the new harness default, got $(meta_field "$dir" rl83 effort)"
  [ "$(meta_field "$dir" rl83 harness)" = codex ] \
    || fail "the replacement should still land on the named harness"
  pass "fm-control relaunch: a carried effort the new harness refuses falls back to that harness default"
}

test_relaunch_off_claude_refuses_when_tooling_is_present() {
  local dir out rc
  dir=$(new_case tooling-block rl84)
  add_ship_task "$dir" rl84 claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/pin" "$dir/home/config"
  printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$dir/pin/.claude.json"
  : > "$dir/pin/.credentials.json"
  printf '%s\n' "$dir/pin" > "$dir/home/config/claude-account"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl84 relaunch --harness codex --note "move off Claude"); rc=$?
  expect_code 1 "$rc" "moving off Claude must refuse when tooling is present"$'\n'"$out"
  assert_contains "$out" "Claude-specific tooling present" "the refusal should name the tooling gate"
  assert_contains "$out" "MCP servers in $dir/pin/.claude.json" "the refusal should name the blocking signal"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a tooling refusal must leave the old agent running"
  [ "$(meta_field "$dir" rl84 harness)" = claude ] \
    || fail "a tooling refusal must leave the recorded harness"
  pass "fm-control relaunch: moving off Claude refuses when Claude-specific tooling is present"
}

test_relaunch_off_claude_refuses_an_unreadable_account_pin() {
  local dir out rc
  dir=$(new_case pin-unreadable rl86)
  add_ship_task "$dir" rl86 claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config"
  printf 'not-a-path\n' > "$dir/home/config/claude-account"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl86 relaunch --harness codex --note "broken pin"); rc=$?
  expect_code 1 "$rc" "a broken claude-account pin must refuse the move off Claude"$'\n'"$out"
  assert_contains "$out" "config/claude-account" "the refusal should name the pin"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a broken pin must leave the old agent running"
  [ "$(meta_field "$dir" rl86 harness)" = claude ] \
    || fail "a broken pin must leave the recorded harness"
  pass "fm-control relaunch: an unreadable claude-account pin refuses the move off Claude"
}

test_relaunch_off_claude_refuses_when_tooling_check_exits_2() {
  local dir out rc
  dir=$(new_case tooling-exit2 rl87)
  add_ship_task "$dir" rl87 claude
  make_claude_auth_stub "$dir"
  cat > "$dir/fakebin/fm-quota-reroute.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "${0%/*}/ran"
echo "error: injected tooling check crashed" >&2
exit 2
SH
  chmod +x "$dir/fakebin/fm-quota-reroute.sh"
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_TEST_SEAM=1 FM_TEST_QUOTA_REROUTE="$dir/fakebin/fm-quota-reroute.sh" \
    run_control "$dir" rl87 relaunch --harness codex --note "check crashed"); rc=$?
  expect_code 1 "$rc" "a claude-tooling exit 2 must refuse the move off Claude"$'\n'"$out"
  [ "$(cat "$dir/fakebin/ran" 2>/dev/null)" = ran ] \
    || fail "the injected tooling helper must have run"$'\n'"$out"
  assert_contains "$out" "Claude-specific tooling present" "the refusal should name the tooling gate"
  assert_contains "$out" "injected tooling check crashed" "the refusal should name the injected helper's reason"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a tooling-check crash must leave the old agent running"
  [ "$(meta_field "$dir" rl87 harness)" = claude ] \
    || fail "a tooling-check crash must leave the recorded harness"
  pass "fm-control relaunch: a claude-tooling exit 2 refuses the move off Claude"
}

test_relaunch_off_claude_ignores_fm_quota_reroute_override() {
  local dir out rc
  dir=$(new_case tooling-override rl92)
  add_ship_task "$dir" rl92 claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/pin" "$dir/home/config"
  printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$dir/pin/.claude.json"
  : > "$dir/pin/.credentials.json"
  printf '%s\n' "$dir/pin" > "$dir/home/config/claude-account"
  cat > "$dir/fakebin/fm-quota-reroute.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/fm-quota-reroute.sh"
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_QUOTA_REROUTE="$dir/fakebin/fm-quota-reroute.sh" \
    run_control "$dir" rl92 relaunch --harness codex --note "override must not skip tooling"); rc=$?
  expect_code 1 "$rc" "production relaunch must ignore FM_QUOTA_REROUTE"$'\n'"$out"
  assert_contains "$out" "Claude-specific tooling present" "the shipped helper must still refuse"
  assert_contains "$out" "MCP servers in $dir/pin/.claude.json" "the shipped helper must name the signal"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an ignored override must leave the old agent running"
  [ "$(meta_field "$dir" rl92 harness)" = claude ] \
    || fail "an ignored override must leave the recorded harness"
  pass "fm-control relaunch: production ignores FM_QUOTA_REROUTE and uses the shipped helper"
}

seeded_secondmate_case() {  # <case-dir-name> <id> -> case dir with a cloned firstmate home
  local dir id=$2
  dir=$(new_case "$1" "$id")
  git clone --local --quiet "$ROOT" "$dir/smhome" \
    || fail "could not clone a firstmate home for $id"
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/home/config" "$dir/home/data/$id"
  printf '%s\n' "$id" > "$dir/smhome/.fm-secondmate-home"
  printf '# secondmate brief\n' > "$dir/home/data/$id/brief.md"
  make_claude_auth_stub "$dir"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$dir/home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  printf '%s\n' "$dir"
}

test_relaunch_off_claude_allows_an_unchanged_seeded_home() {
  local dir out rc
  dir=$(seeded_secondmate_case seed-allow rl-seed1)
  out=$(run_control "$dir" rl-seed1 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an unchanged seeded home must be allowed to leave Claude"$'\n'"$out"
  [ "$(meta_field "$dir" rl-seed1 harness)" = codex ] \
    || fail "the replacement should land on the named harness"
  pass "fm-control relaunch: an unchanged seeded firstmate home can move off Claude"
}

test_relaunch_off_claude_refuses_seeded_home_user_additions() {
  local dir out rc settings
  dir=$(seeded_secondmate_case seed-hook rl-seed2)
  mkdir -p "$dir/smhome/.claude/hooks"
  printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$dir/smhome/.claude/hooks/hooks.json"
  out=$(run_control "$dir" rl-seed2 relaunch --harness codex); rc=$?
  expect_code 1 "$rc" "a user hook in a seeded home must refuse the move"$'\n'"$out"
  assert_contains "$out" "Claude-specific tooling present" "the refusal should name the tooling gate"
  assert_contains "$out" "worktree .claude/hooks/hooks.json" "the refusal should name the added hook"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a user-hook refusal must leave the old agent running"
  rm -rf "$dir/smhome/.claude/hooks"

  dir=$(seeded_secondmate_case seed-edit rl-seed3)
  settings="$dir/smhome/.claude/settings.json"
  jq 'del(.hooks) | .env.EDITED = "1"' "$settings" > "$dir/settings.edited"
  mv "$dir/settings.edited" "$settings"
  out=$(run_control "$dir" rl-seed3 relaunch --harness codex); rc=$?
  expect_code 1 "$rc" "an edited seeded file must refuse the move"$'\n'"$out"
  assert_contains "$out" "worktree .claude/settings.json" "the refusal should name the edited seed file"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an edited-seed refusal must leave the old agent running"

  dir=$(seeded_secondmate_case seed-mcp rl-seed4)
  printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$dir/smhome/.mcp.json"
  out=$(run_control "$dir" rl-seed4 relaunch --harness codex); rc=$?
  expect_code 1 "$rc" "user MCP in a seeded home must refuse the move"$'\n'"$out"
  assert_contains "$out" "worktree .mcp.json" "the refusal should name the MCP file"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an MCP refusal must leave the old agent running"
  pass "fm-control relaunch: user hooks, seed edits, and MCP in a seeded home still refuse"
}

test_relaunch_off_claude_refuses_seeded_home_committed_file_and_symlinked_root() {
  local dir out rc claude_real claude_evil
  dir=$(seeded_secondmate_case seed-committed rl-seed5)
  mkdir -p "$dir/smhome/.claude/hooks"
  printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$dir/smhome/.claude/hooks/hooks.json"
  git -C "$dir/smhome" add .claude/hooks/hooks.json
  git -C "$dir/smhome" -c user.email=dev@example.test -c user.name=dev \
    -c commit.gpgsign=false commit --quiet -m 'user hook'
  out=$(run_control "$dir" rl-seed5 relaunch --harness codex); rc=$?
  expect_code 1 "$rc" "a hook committed in a seeded home must refuse the move"$'\n'"$out"
  assert_contains "$out" "Claude-specific tooling present" "the refusal should name the tooling gate"
  assert_contains "$out" "worktree .claude/hooks/hooks.json" "the refusal should name the committed hook"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a committed-hook refusal must leave the old agent running"

  dir=$(seeded_secondmate_case seed-symlink rl-seed6)
  claude_real="$dir/claude.real"
  claude_evil="$dir/claude.evil"
  mv "$dir/smhome/.claude" "$claude_real"
  mkdir -p "$claude_evil"
  cp -a "$claude_real/." "$claude_evil/"
  mkdir -p "$claude_evil/hooks"
  printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$claude_evil/hooks/hooks.json"
  ln -s "$claude_evil" "$dir/smhome/.claude"
  out=$(run_control "$dir" rl-seed6 relaunch --harness codex); rc=$?
  expect_code 1 "$rc" "a symlinked .claude root in a seeded home must refuse the move"$'\n'"$out"
  assert_contains "$out" "worktree .claude" "the refusal should name the symlinked root"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a symlinked-root refusal must leave the old agent running"
  pass "fm-control relaunch: a committed seed file and a symlinked .claude root still refuse"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop() {
  local dir out rc id=rl-ultra
  dir=$(new_case native-ultra "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-6-astra|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  out=$(run_control "$dir" "$id" relaunch --model openai-codex/gpt-6-astra --note "invalid native effort transfer"); rc=$?
  expect_code 1 "$rc" "Ultra transferred to ordinary Pi"
  assert_contains "$out" "ultra effort requires pi or pi-signed" "model-aware relaunch refusal missing"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "invalid Ultra relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "invalid Ultra relaunch sent lifecycle input"
  out=$(run_control "$dir" "$id" relaunch --note "preserve explicit native effort"); rc=$?
  expect_code 0 "$rc" "native Ultra relaunch failed: $out"
  [ "$(meta_field "$dir" "$id" effort)" = ultra ] || fail "relaunch lost Ultra metadata"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "relaunch lost native model"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "relaunch lost native flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "--thinking 'ultra'" "relaunch used an invalid Pi level"
  pass "native Ultra relaunch preserves its profile and rejects an unsupported model before stopping"
}

test_codex_max_relaunch_rejects_unadvertised_model_before_stop() {
  local dir out rc id=rl-codex-max catalog
  dir=$(new_case codex-max "$id")
  add_ship_task "$dir" "$id" codex
  printf codex > "$dir/fake/command"
  catalog="$dir/codex-models.json"
  printf '%s\n' '{"models":[{"slug":"gpt-5","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}]}' > "$catalog"
  sed 's/^model=default$/model=gpt-5/; s/^effort=default$/effort=max/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  out=$(FM_CODEX_MODELS_CACHE="$catalog" run_control "$dir" "$id" relaunch --note "unadvertised max"); rc=$?
  expect_code 1 "$rc" "codex max relaunch on a model without max"
  assert_contains "$out" "catalog does not advertise max" "codex max relaunch refusal missing"
  [ "$(cat "$dir/fake/command")" = codex ] || fail "unadvertised codex max relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "unadvertised codex max relaunch sent lifecycle input"
  out=$(FM_CODEX_MODELS_CACHE="$catalog" run_control "$dir" "$id" relaunch --model default --note "no model"); rc=$?
  expect_code 1 "$rc" "codex max relaunch with no model"
  assert_contains "$out" "codex effort max requires an explicit --model" "codex max relaunch without a model refusal missing"
  [ "$(cat "$dir/fake/command")" = codex ] || fail "codex max relaunch without a model stopped the running agent"
  pass "codex max relaunch rejects a model the catalog does not advertise max for before stopping"
}

# A fake claude that answers `claude auth status` the way the real runner
# does: signed in only when the selected config root holds a stored login.
make_claude_auth_stub() {  # <case-dir>
  cat > "$1/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
SH
  chmod +x "$1/fakebin/claude"
}

test_signed_out_worker_account_pin_refuses_before_stop() {
  local dir out rc id=rl-acct-out
  dir=$(new_case acct-out "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_control "$dir" "$id" relaunch --note "account signed out"); rc=$?
  expect_code 1 "$rc" "a relaunch under a signed-out account pin must refuse"
  assert_contains "$out" "config/claude-account pins Claude workers to $dir/work, which is not signed in" \
    "the refusal should name the pin and the signed-out root"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a signed-out pin must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a signed-out pin must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"
  pass "fm-control relaunch: a signed-out worker account pin refuses before the old agent stops"
}

test_worker_account_pin_follows_the_relaunch() {
  local dir out rc id=rl-acct
  dir=$(new_case acct "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(run_control "$dir" "$id" relaunch --note "pinned account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a signed-in account pin should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/work" ] || fail "the relaunched record should carry the pinned account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/work'" \
    "the replacement should launch under the pinned root"
  rm "$dir/home/config/claude-account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "pin removed"); rc=$?
  expect_code 0 "$rc" "a relaunch after the pin is removed should succeed"$'\n'"$out"
  assert_no_grep "account=" "$dir/home/state/$id.meta" "a relaunch without a pin must drop the previous account from the record"
  assert_not_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR=" \
    "an unpinned replacement must launch exactly as before"
  pass "fm-control relaunch: the replacement follows the home's current worker account pin"
}

# add_listed_task <case-dir> <id> <recorded-account>: a live Claude ship
# recorded on <recorded-account> in a home declaring two signed-in accounts,
# first and second, plus a signed-out one.
add_listed_task() {
  local dir=$1 id=$2 recorded=$3
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/first" "$dir/second" "$dir/signed-out"
  : > "$dir/first/.credentials.json"
  : > "$dir/second/.credentials.json"
  printf '%s\n' "$dir/first" "$dir/second" "$dir/signed-out" > "$dir/home/config/claude-accounts"
  [ -z "$recorded" ] || echo "account=$recorded" >> "$dir/home/state/$id.meta"
}

test_account_list_relaunch_reuses_the_recorded_account() {
  local dir out rc id=rl-list
  dir=$(new_case list-reuse "$id")
  add_listed_task "$dir" "$id" "$dir/first"
  out=$(run_control "$dir" "$id" relaunch --note "same account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a list should reuse the recorded account"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/first" ] || fail "the relaunched record should keep the recorded account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/first'" \
    "the replacement should launch under the recorded account"
  : > "$dir/fake/literal"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" "$id" --relaunch); rc=$?
  expect_code 0 "$rc" "a direct fm-spawn --relaunch under a list should reuse the recorded account"$'\n'"$out"
  assert_contains "$out" "account=$dir/first" "the direct relaunch should report the recorded account"
  pass "fm-control relaunch: a declared account list keeps the account the task records"
}

test_account_list_relaunch_moves_only_on_explicit_account() {
  local dir out rc id=rl-list-move
  dir=$(new_case list-move "$id")
  add_listed_task "$dir" "$id" "$dir/first"
  out=$(run_control "$dir" "$id" relaunch --account "$dir/second" --note "first is exhausted"); rc=$?
  expect_code 0 "$rc" "an explicit --account relaunch should move the task"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/second" ] || fail "the relaunched record should name the new account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/second'" \
    "the replacement should launch under the explicitly chosen account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "stay"); rc=$?
  expect_code 0 "$rc" "a later plain relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/second" ] || fail "a later relaunch should keep the moved account"
  pass "fm-control relaunch: only an explicit --account moves a task to another declared account"
}

test_account_list_relaunch_refusals_happen_before_stop() {
  local dir out rc id=rl-list-refuse case_name recorded flag needle
  for case_name in undeclared newline signed-out unrecorded removed wrong-harness; do
    dir=$(new_case "list-refuse-$case_name" "$id")
    recorded="$dir/first"
    flag=()
    case "$case_name" in
      undeclared)
        flag=(--account "$dir/elsewhere")
        needle="account '$dir/elsewhere' is not declared in config/claude-accounts" ;;
      newline)
        flag=(--account "$dir/elsewhere"$'\n'"$dir/second")
        needle="--account must name one config/claude-accounts entry exactly, with no control characters" ;;
      signed-out)
        flag=(--account "$dir/signed-out")
        needle="config/claude-accounts pins Claude workers to $dir/signed-out, which is not signed in" ;;
      unrecorded)
        recorded=
        needle="must name one with --account" ;;
      removed)
        recorded="$dir/retired"
        needle="account '$dir/retired' is not declared in config/claude-accounts" ;;
      wrong-harness)
        flag=(--harness codex --account "$dir/second")
        needle="applies to Claude workers only, not codex" ;;
    esac
    add_listed_task "$dir" "$id" "$recorded"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    out=$(run_control "$dir" "$id" relaunch ${flag[@]+"${flag[@]}"} --note "refuse $case_name"); rc=$?
    expect_code 1 "$rc" "the $case_name relaunch must refuse"$'\n'"$out"
    assert_contains "$out" "$needle" "the $case_name refusal should say why"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "the $case_name refusal must happen before the running agent stops"
    [ ! -s "$dir/fake/literal" ] || fail "the $case_name refusal must send no lifecycle input"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "the $case_name refusal must leave the task record untouched"
  done
  pass "fm-control relaunch: undeclared, newline-split, signed-out, unrecorded, retired, and wrong-runner accounts refuse before the old agent stops"
}
test_secondmate_account_pin_follows_relaunch_and_refuses_before_stop() {
  local dir out rc id=rl-sm-acct harness file variable pin
  for harness in claude pi; do
    dir=$(new_case "sm-account-$harness" "$id")
    add_ship_task "$dir" "$id" "$harness"
    make_claude_auth_stub "$dir"
    cat > "$dir/fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf 'Options: --tui-mode\n' ;;
  auth)
    if grep -qx "$4" "$PI_CODING_AGENT_DIR/signed-in" 2>/dev/null; then
      printf '{"status":"ready"}\n'
    else
      printf '{"status":"not_ready","reason":"credentials_not_configured"}\n'
      exit 1
    fi ;;
esac
SH
    chmod +x "$dir/fakebin/pi"
    file=claude-account; variable=CLAUDE_CONFIG_DIR
    if [ "$harness" = pi ]; then file=pi-account; variable=PI_CODING_AGENT_DIR; fi
    printf '%s' "$harness" > "$dir/fake/command"
    printf '%s' "$harness" > "$dir/fake/becomes"
    mkdir -p "$dir/wt/state" "$dir/wt/data" "$dir/wt/bin" \
      "$dir/home/config/secondmate-accounts/$id" "$dir/primary" "$dir/mate" "$dir/new-mate"
    printf '%s\n' "$id" > "$dir/wt/.fm-secondmate-home"
    printf '# agents\n' > "$dir/wt/AGENTS.md"
    printf '# charter\n' > "$dir/wt/data/charter.md"
    printf '%s openai-codex/gpt-5.5\n' "$harness" > "$dir/home/config/secondmate-harness"
    {
      printf 'window=fmses:fm-%s\nendpoint_task_id=%s\n' "$id" "$id"
      printf 'worktree=%s\nproject=%s\nhome=%s\n' "$dir/wt" "$dir/wt" "$dir/wt"
      printf 'harness=%s\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\n' "$harness"
    } > "$dir/home/state/$id.meta"
    : > "$dir/primary/.credentials.json"
    : > "$dir/mate/.credentials.json"
    : > "$dir/new-mate/.credentials.json"
    printf 'openai-codex\n' > "$dir/primary/signed-in"
    printf 'openai-codex\n' > "$dir/mate/signed-in"
    printf 'openai-codex\n' > "$dir/new-mate/signed-in"
    printf '%s\n' "$dir/primary" > "$dir/home/config/$file"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$dir/home/config/$file"
    pin="$dir/home/config/secondmate-accounts/$id/$file"
    printf '%s\n' "$dir/mate" > "$pin"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$pin"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 0 "$rc" "the secondmate should relaunch on its $harness pin: $out"
    assert_contains "$(cat "$dir/fake/literal")" "$variable='$dir/mate'" "the replacement must use the mate's pin"
    [ "$(meta_field "$dir" "$id" account)" = "$dir/mate" ] || fail "the record must name the mate's account"
    printf '%s\n' "$dir/new-mate" > "$pin"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$pin"
    : > "$dir/fake/literal"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 0 "$rc" "a changed durable pin should govern relaunch: $out"
    assert_contains "$(cat "$dir/fake/literal")" "$variable='$dir/new-mate'" "relaunch must not reuse the old recorded account"
    rm "$dir/new-mate/.credentials.json" "$dir/new-mate/signed-in"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    : > "$dir/fake/literal"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 1 "$rc" "a signed-out mate account must refuse before stop"
    assert_contains "$out" "$pin" "the refusal must name the mate setting"
    assert_contains "$out" 'not signed in' "the refusal must name the reason"
    [ "$(cat "$dir/fake/command")" = "$harness" ] || fail "the running mate must remain alive"
    [ ! -s "$dir/fake/literal" ] || fail "the refused relaunch must send no lifecycle input"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "the refused relaunch must preserve metadata"
    rm "$pin"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 0 "$rc" "removing the mate pin should restore the primary's pin: $out"
    assert_contains "$(cat "$dir/fake/literal")" "$variable='$dir/primary'" "an absent mate setting must restore the primary's pin"
  done
  pass "fm-control relaunch: mate pins are re-read for Claude and Pi, and unusable pins refuse before stopping the agent"
}

test_pi_exclude_tools_follow_the_relaunch() {
  local dir out rc id=rl-pi-excl
  dir=$(new_case pi-exclude "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' '# hide writes' 'mcp__srv__writeTool' 'mcp__srv__adminTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "keep exclusions"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch with exclusions should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/literal")" "--exclude-tools 'mcp__srv__writeTool,mcp__srv__adminTool'" \
    "the relaunched Pi worker must keep the home's tool exclusions"
  rm "$dir/home/config/crew-exclude-tools"
  : > "$dir/fake/literal"
  printf pi > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "exclusions removed"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch after the file is removed should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/literal")" "--exclude-tools" \
    "a relaunch without the file must launch with no exclusions"
  pass "fm-control relaunch: a Pi replacement keeps the home's tool exclusions"
}

test_exclude_tools_refusals_happen_before_the_agent_stops() {
  local dir out rc id=rl-excl-refuse
  dir=$(new_case excl-refuse "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' 'two words' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "bad list"); rc=$?
  expect_code 1 "$rc" "a malformed exclusion list must refuse the relaunch"
  assert_contains "$out" "config/crew-exclude-tools has a malformed entry" "refusal must name the entry"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a malformed exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  printf '%s\n' 'mcp__srv__writeTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --harness codex --note "switch runtime"); rc=$?
  expect_code 1 "$rc" "relaunching onto a runtime that cannot hide tools must refuse"
  assert_contains "$out" "config/crew-exclude-tools" "refusal must name the config file"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an unhonorable exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  pass "fm-control relaunch: exclusion-list refusals happen before the running agent stops"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "Firstmate operational input waiting: read" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

# The relaunch half of the opt-in scope: a pin file that declares no
# "mate <id>:" line is read exactly as it was before that grammar existed, so a
# second default line and a fourth token must not stop the relaunch. The mate
# still lands on the first line's runtime.
test_secondmate_relaunch_with_a_legacy_pin_file_uses_the_first_line() {
  local dir home out rc
  dir=$(new_case smlegacy sml2)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml2"
  printf 'codex some-model high extra\ngrok other-model low\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml2/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sml2\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sml2"
    echo "endpoint_task_id=sml2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml2.meta"
  printf '%s\n' "fm-sml2" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml2 relaunch); rc=$?
  expect_code 0 "$rc" "a legacy pin file must not refuse a secondmate relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sml2 to_harness)" = codex ] \
    || fail "the relaunch should take the first line's harness, got '$(journal_field "$dir" sml2 to_harness)'"
  [ "$(journal_field "$dir" sml2 to_model)" = some-model ] \
    || fail "the relaunch should take the first line's model token, got '$(journal_field "$dir" sml2 to_model)'"
  [ "$(journal_field "$dir" sml2 to_effort)" = high ] \
    || fail "the relaunch should take the first line's effort token, got '$(journal_field "$dir" sml2 to_effort)'"
  pass "fm-control relaunch: a legacy secondmate pin file still relaunches the mate onto its first line"
}

test_secondmate_claude_relaunch_keeps_local_settings() {
  local dir home prior settings out rc
  dir=$(new_case smlocal sml)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml"
  printf 'codex\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-local-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$dir/smhome/.claude"
  printf 'sml\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  prior='{"permissions":{"allow":["Bash(echo hi)"]}}'
  printf '%s\n' "$prior" > "$dir/smhome/.claude/settings.local.json"
  printf '%s\n' '{"feedbackDrafts":"on"}' > "$home/state/sml.claude-settings.json"
  printf 'gen=retired\n' > "$dir/smhome/.fm-busy-stop"
  {
    echo "window=fmses:fm-sml"
    echo "endpoint_task_id=sml"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml.meta"
  printf '%s\n' "fm-sml" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml relaunch); rc=$?
  expect_code 0 "$rc" "a claude secondmate relaunch should retire wiring without touching local settings"$'\n'"$out"
  settings="$dir/smhome/.claude/settings.local.json"
  [ "$(cat "$settings")" = "$prior" ] \
    || fail "relaunch rewrote the mate home's settings.local.json"
  [ ! -e "$home/state/sml.claude-settings.json" ] \
    || fail "relaunch left the retired claude settings file in place"
  [ ! -e "$dir/smhome/.fm-busy-stop" ] \
    || fail "relaunch left the retired Stop pointer in the mate home"
  pass "fm-control relaunch: a claude secondmate keeps settings.local.json and retires the state settings file and the Stop pointer"
}

# The captain's per-mate override line must win at the relaunch decision, so a
# later change to the default pin cannot migrate a mate that has its own runtime
# ruling onto the default. Synthetic mate ids only - no real home's pin values.
test_secondmate_relaunch_lands_on_the_per_mate_pin() {
  local dir home out rc
  dir=$(new_case smpinmate smp1)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp1"
  printf 'codex default-model high\nmate smp1: claude mate-model xhigh\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp1/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp1"
    echo "endpoint_task_id=smp1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp1.meta"
  printf '%s\n' "fm-smp1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'claude' > "$dir/fake/becomes"
  out=$(run_control "$dir" smp1 relaunch); rc=$?
  expect_code 0 "$rc" "a per-mate pin should relaunch that mate onto its own runtime"$'\n'"$out"
  [ "$(journal_field "$dir" smp1 to_harness)" = claude ] \
    || fail "the mate's own override should win over the default pin, got '$(journal_field "$dir" smp1 to_harness)'"
  [ "$(journal_field "$dir" smp1 to_model)" = mate-model ] \
    || fail "the override's model token should be used, got '$(journal_field "$dir" smp1 to_model)'"
  [ "$(journal_field "$dir" smp1 to_effort)" = xhigh ] \
    || fail "the override's effort token should be used, got '$(journal_field "$dir" smp1 to_effort)'"
  pass "fm-control relaunch: a mate with a per-mate override line lands on that override, not the default pin"
}

# A mate with no override line keeps resolving through the default line, so
# adding the override grammar cannot change any other mate's resolution.
test_secondmate_relaunch_uses_the_default_for_an_unpinned_mate() {
  local dir home out rc
  dir=$(new_case smdefault smp2)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp2"
  printf 'codex default-model high\nmate some-other-mate: claude opus max\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp2/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp2\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp2"
    echo "endpoint_task_id=smp2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp2.meta"
  printf '%s\n' "fm-smp2" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" smp2 relaunch); rc=$?
  expect_code 0 "$rc" "an unpinned mate should relaunch onto the default pin"$'\n'"$out"
  [ "$(journal_field "$dir" smp2 to_harness)" = codex ] \
    || fail "a mate with no override must take the default harness, got '$(journal_field "$dir" smp2 to_harness)'"
  [ "$(journal_field "$dir" smp2 to_model)" = default-model ] \
    || fail "the default model token should be used, got '$(journal_field "$dir" smp2 to_model)'"
  [ "$(journal_field "$dir" smp2 to_effort)" = high ] \
    || fail "the default effort token should be used, got '$(journal_field "$dir" smp2 to_effort)'"
  pass "fm-control relaunch: a mate with no override line still resolves the default pin"
}

# A pin file this home cannot parse must stop the relaunch, because the
# alternative is launching the mate onto whatever it happened to run last time -
# the silent migration the override grammar exists to prevent.
test_secondmate_relaunch_refuses_an_unreadable_configured_pin_before_stop() {
  local dir home out rc
  dir=$(new_case smbadminpin smp3)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp3"
  printf 'codex default-model high\nmate smp3: claude mate-model xhigh\nmate smp3: grok other-model max\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp3"
    echo "endpoint_task_id=smp3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp3.meta"
  printf '%s\n' "fm-smp3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" smp3 relaunch); rc=$?
  expect_code 1 "$rc" "an unparseable configured pin must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "config/secondmate-harness" \
    "the refusal should name the pin file the mate cannot be resolved from"
  assert_contains "$out" "line 3" "the refusal should name the offending line"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused relaunch must not stop or replace the running agent"
  [ "$(meta_field "$dir" smp3 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an unparseable secondmate pin refuses before anything is stopped"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = high ] \
    || fail "an explicit secondmate harness without --effort must keep the running effort"
  printf 'claude opus high\nmate sm4: claude opus high\nmate sm4: codex other-model max\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore an unreadable configured pin"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  # The same explicit profile must succeed whatever the file holds, including a
  # legacy file whose later lines and fourth token the strict rules would have
  # rejected, and a file with no usable line at all.
  printf 'claude opus high extra\ngrok other-model low\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore a legacy configured pin"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  printf '# only a comment\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore a configured pin with no usable line"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  pass "fm-control relaunch: explicit secondmate harness keeps running effort and takes named axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# A promoted scout records kind=ship and a custom ship branch in its meta, but
# its brief is the scout scaffold: it never gained a Ship branch line, and a
# relaunch cannot regenerate the brief (--branch-prefix is refused there). The
# recorded branch is authoritative, so the relaunch must proceed on it.
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch() {
  local dir out
  dir=$(new_case promotebranch rl42)
  add_ship_task "$dir" rl42 claude
  printf 'branch=fix/rl42\n' >> "$dir/home/state/rl42.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl42 --relaunch)
  assert_contains "$out" "spawned rl42" "the relaunch should complete on the recorded branch"
  assert_contains "$out" "records no ship branch" "the brief gap should be reported, not silent"
  assert_contains "$out" "recorded branch fix/rl42" "the relaunch should name the branch it adopted"
  [ "$(meta_field "$dir" rl42 branch)" = "fix/rl42" ] \
    || fail "the recorded branch must survive the relaunch"
  pass "fm-spawn --relaunch: a promoted scout with a recorded custom branch relaunches on it instead of being refused"
}

# A no-mistakes ship relaunch whose recorded branch is on origin resyncs the
# worktree before launch, while a direct-PR or local-only branch stays worker-owned.
stale_published_task() {  # <case-dir> <id>: ship task on task-<id>, stale against origin
  local dir=$1 id=$2 pipe="$1/pipe" old
  add_ship_task "$dir" "$id" claude
  printf 'branch=task-%s\n' "$id" >> "$dir/home/state/$id.meta"
  printf 'zsh' > "$dir/fake/command"
  printf 'a\n' > "$dir/wt/a.txt"
  git -C "$dir/wt" add a.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm a
  git -C "$dir/wt" push -q origin "task-$id"
  STALE_SHA=$(git -C "$dir/wt" rev-parse HEAD)
  old=$STALE_SHA
  git clone -q "$dir/proj.origin.git" "$pipe"
  printf 'm2\n' > "$pipe/m2.txt"
  git -C "$pipe" add m2.txt
  git -C "$pipe" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm m2
  git -C "$pipe" push -q origin main
  git -C "$pipe" switch -q "task-$id"
  git -C "$pipe" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' rebase -q main
  printf 'fix\n' > "$pipe/fix.txt"
  git -C "$pipe" add fix.txt
  git -C "$pipe" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fix
  git -C "$pipe" push -q --force-with-lease="task-$id:$old" origin "task-$id"
  PUBLISHED_SHA=$(git -C "$pipe" rev-parse HEAD)
}

test_spawn_relaunch_resyncs_the_recorded_branch_to_its_published_head() {
  local dir out mode local_sha launch
  dir=$(new_case prresync rl90)
  stale_published_task "$dir" rl90
  out=$(run_spawn "$dir" rl90 --relaunch)
  assert_contains "$out" "cannot relaunch: bin/fm-pr-resync.sh exited 1" "a diverged relaunch was not refused"$'\n'"$out"
  assert_not_contains "$out" "spawned rl90" "a diverged relaunch launched"
  assert_contains "$out" "branch was left as-is" "the relaunch refusal did not explain branch custody"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$STALE_SHA" ] \
    || fail "a diverged relaunch moved the worker branch"
  [ -z "$(git -C "$dir/wt" for-each-ref --format='%(refname)' refs/heads/archive/rl90-)" ] \
    || fail "a diverged relaunch created an archive"

  dir=$(new_case prresync-behind rl95)
  add_ship_task "$dir" rl95 claude
  printf 'branch=task-rl95\n' >> "$dir/home/state/rl95.meta"
  printf 'zsh' > "$dir/fake/command"
  printf 'a\n' > "$dir/wt/a.txt"
  git -C "$dir/wt" add a.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm a
  git -C "$dir/wt" push -q origin task-rl95
  git clone -q "$dir/proj.origin.git" "$dir/pipe"
  git -C "$dir/pipe" switch -q task-rl95
  printf 'fix\n' > "$dir/pipe/fix.txt"
  git -C "$dir/pipe" add fix.txt
  git -C "$dir/pipe" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fix
  git -C "$dir/pipe" push -q origin task-rl95
  PUBLISHED_SHA=$(git -C "$dir/pipe" rev-parse HEAD)
  out=$(run_spawn "$dir" rl95 --relaunch)
  assert_contains "$out" "spawned rl95" "a behind relaunch did not launch"$'\n'"$out"
  assert_contains "$out" "result=advanced" "a behind relaunch did not advance"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$PUBLISHED_SHA" ] \
    || fail "a behind relaunch did not reach the published head"

  for mode in direct-PR local-only; do
    dir=$(new_case "prresync-$mode" "rl96-$mode")
    stale_published_task "$dir" "rl96-$mode"
    sed -i.bak "s/^mode=no-mistakes$/mode=$mode/" "$dir/home/state/rl96-$mode.meta"
    git -C "$dir/wt" remote add no-mistakes "$dir/proj.origin.git"
    printf 'local amendment\n' >> "$dir/wt/a.txt"
    git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit --amend --no-edit -aq
    local_sha=$(git -C "$dir/wt" rev-parse HEAD)
    out=$(run_spawn "$dir" "rl96-$mode" --relaunch)
    assert_contains "$out" "spawned rl96-$mode" "$mode worker-owned branch did not relaunch"$'\n'"$out"
    assert_not_contains "$out" "fm-pr-resync:" "$mode relaunch invoked the owner"
    [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$local_sha" ] \
      || fail "$mode relaunch moved the unpushed worker commit"
    [ -z "$(git -C "$dir/wt" for-each-ref --format='%(refname)' "refs/heads/archive/rl96-$mode-")" ] \
      || fail "$mode relaunch created an archive"
  done

  dir=$(new_case prresync-legacy rl97)
  stale_published_task "$dir" rl97
  sed -i.bak '/^mode=/d' "$dir/home/state/rl97.meta"
  git -C "$dir/wt" remote add no-mistakes "$dir/proj.origin.git"
  out=$(run_spawn "$dir" rl97 --relaunch)
  assert_contains "$out" "cannot relaunch: bin/fm-pr-resync.sh exited 1" "a legacy relaunch with a no-mistakes remote skipped the owner"$'\n'"$out"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$STALE_SHA" ] || fail "a refused legacy relaunch moved the branch"

  dir=$(new_case prresync-dirty rl91)
  stale_published_task "$dir" rl91
  printf 'keep\n' > "$dir/wt/uncommitted.txt"
  printf 'edited\n' >> "$dir/wt/a.txt"
  out=$(run_spawn "$dir" rl91 --relaunch)
  assert_contains "$out" "spawned rl91" "a dirty task-owned copy did not relaunch"$'\n'"$out"
  assert_contains "$out" "skipping the published-head resync" "a dirty relaunch did not say it skipped the resync"
  assert_not_contains "$out" "fm-pr-resync:" "a dirty relaunch invoked the network resync owner"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$STALE_SHA" ] || fail "a dirty relaunch moved the branch"
  assert_grep 'keep' "$dir/wt/uncommitted.txt" "a dirty relaunch discarded an untracked file"
  assert_grep 'edited' "$dir/wt/a.txt" "a dirty relaunch discarded a tracked edit"
  [ -z "$(git -C "$dir/wt" stash list)" ] || fail "a dirty relaunch stashed local work"
  launch="$dir/home/data/rl91/launch-brief.md"
  assert_grep '# Dirty-copy relaunch' "$launch" "the replacement was not told its copy is dirty"
  assert_grep 'never stash, reset, check out over, clean, or discard them' "$launch" "the dirty-copy section does not protect the edits"
  assert_grep 'uncommitted.txt' "$launch" "the dirty-copy section does not list the uncommitted paths"
  assert_grep "fm-pr-resync.sh rl91 $dir/wt task-rl91 --refuse-diverged" "$launch" "the dirty-copy section does not name the later resync with its divergence refusal"

  out=$(run_spawn "$dir" rl91 --relaunch --pr-branch task-rl91)
  assert_contains "$out" "--pr-branch and --from-branch apply only to a fresh launch" "--relaunch accepted --pr-branch"

  dir=$(new_case prresync-dirty-other rl98)
  stale_published_task "$dir" rl98
  git -C "$dir/wt" switch -q -c unrelated
  printf 'keep\n' > "$dir/wt/uncommitted.txt"
  out=$(run_spawn "$dir" rl98 --relaunch)
  assert_not_contains "$out" "spawned rl98" "a dirty copy on another branch launched"$'\n'"$out"
  assert_contains "$out" "cannot relaunch" "a dirty copy on another branch was not refused"$'\n'"$out"
  assert_grep 'keep' "$dir/wt/uncommitted.txt" "a refused relaunch discarded local work"
  pass "fm-spawn --relaunch: no-mistakes divergence refuses, behind advances, a dirty task-owned copy relaunches untouched without resync, and explicit worker-owned modes skip resync despite a no-mistakes remote"
}

# A successor launched with --from-branch keeps its brief's Setup "Source
# branch:" line; that agreement binds only the fresh launch, so its relaunch
# proceeds without the flag.
test_spawn_relaunch_of_a_successor_ignores_its_source_line() {
  local dir out
  dir=$(new_case successor rl93)
  add_ship_task "$dir" rl93 claude
  printf '\n# Setup\nSource branch: feature/src\n' >> "$dir/home/data/rl93/brief.md"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl93 --relaunch)
  assert_contains "$out" "spawned rl93" "a successor's Source branch line refused its relaunch"$'\n'"$out"
  pass "fm-spawn --relaunch: a successor relaunches without --from-branch despite its brief's Source branch line"
}

test_spawn_relaunch_under_an_active_run_is_monitoring_only() {
  local dir out launch
  dir=$(new_case prresync-active rl92)
  stale_published_task "$dir" rl92
  git -C "$dir/proj" remote add no-mistakes "$dir/proj.origin.git"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "axi sync" ] || exit 0
printf '%s\n' 'branch_sync:' '  state: pipeline_owned' '  changed: false' '  pipeline:' '    run: "01RUN"' \
  '    status: running' '    current_head: ""' '  relation: diverged' '  safety: pipeline_owned_active' \
  '  next_action:' '    code: continue_active_run' '    command: no-mistakes axi run'
SH
  chmod +x "$dir/fakebin/no-mistakes"
  out=$(run_spawn "$dir" rl92 --relaunch)
  assert_contains "$out" "spawned rl92" "an active-run relaunch should still launch"$'\n'"$out"
  launch="$dir/home/data/rl92/launch-brief.md"
  assert_grep '# Monitoring-only relaunch' "$launch" "the replacement was not told it is monitoring-only"
  assert_grep 'A no-mistakes run holds custody of branch task-rl92.' "$launch" "the owner's monitoring-only contract is missing"
  # shellcheck disable=SC2016 # The rendered contract contains literal backticks.
  assert_grep 'You may reattach the active run with `no-mistakes axi run` (no flags), answer the gates it presents under your brief' "$launch" "monitoring-only reattachment and gate permission missing"
  assert_grep "gate and ask-user rules, and make your brief's CI-ready report through its named-head check." "$launch" "monitoring-only named-head reporting permission missing"
  assert_grep 'Do not edit, commit, start, rerun or abort a run, begin a new phase, or take any other outward action until' "$launch" "monitoring-only prohibitions missing"
  assert_grep "fm-pr-resync.sh rl92 $dir/wt task-rl92" "$launch" "monitoring-only release must name this task's owner invocation"
  assert_grep 'exits 0 against the published head.' "$launch" "monitoring-only fresh successful resync release condition missing"
  assert_no_grep 'fm-pr-resync: monitoring-only:' "$launch" "the owner's output prefix leaked into the instructions"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$STALE_SHA" ] || fail "an active-run relaunch moved the branch"
  pass "fm-spawn --relaunch: under an active run the replacement launches with the owner's monitoring-only contract"
}

# The relaunch caller already treats owner exit 0 as launch. A clean unpublished
# commit with the native local_ahead run_pipeline verdict must use that exit,
# not a new flag or a delivery-mode change, and must not move any ref.
test_spawn_relaunch_keeps_a_clean_local_ahead_commit() {
  local dir out local_sha refs_before refs_after
  dir=$(new_case prresync-ahead rl98)
  add_ship_task "$dir" rl98 claude
  printf 'branch=task-rl98\n' >> "$dir/home/state/rl98.meta"
  printf 'zsh' > "$dir/fake/command"
  printf 'a\n' > "$dir/wt/a.txt"
  git -C "$dir/wt" add a.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm a
  git -C "$dir/wt" push -q origin task-rl98
  printf 'local\n' > "$dir/wt/local.txt"
  git -C "$dir/wt" add local.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local
  local_sha=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/proj" remote add no-mistakes "$dir/proj.origin.git"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "axi sync" ] || exit 0
printf '%s\n' 'branch_sync:' '  state: local_ahead' '  changed: false' '  pipeline:' '    run: "01RUN"' \
  '    status: running' '    current_head: ""' '  relation: ahead' '  safety: blocked_local_ahead' \
  '  next_action:' '    code: run_pipeline' '    command: no-mistakes axi run'
SH
  chmod +x "$dir/fakebin/no-mistakes"
  refs_before=$(git -C "$dir/wt" for-each-ref --format='%(refname) %(objectname)' refs/heads)
  out=$(run_spawn "$dir" rl98 --relaunch)
  refs_after=$(git -C "$dir/wt" for-each-ref --format='%(refname) %(objectname)' refs/heads)
  assert_contains "$out" "spawned rl98" "a clean ahead relaunch did not launch"$'\n'"$out"
  assert_contains "$out" "result=ahead:1" "a clean ahead relaunch did not report the unpublished commit"
  assert_contains "$out" "custody=settled" "a clean ahead relaunch did not settle custody"
  assert_not_contains "$out" "Monitoring-only relaunch" "a run_pipeline relaunch was treated as monitoring-only"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$local_sha" ] || fail "a clean ahead relaunch moved HEAD"
  [ "$refs_before" = "$refs_after" ] || fail "a clean ahead relaunch moved a ref"
  pass "fm-spawn --relaunch: a clean strictly-ahead run_pipeline verdict launches and keeps the local commit"
}

test_spawn_relaunch_origin_probe_timeout_refuses() {
  local dir out before
  dir=$(new_case prprobe-timeout rl94)
  stale_published_task "$dir" rl94
  before=$(git -C "$dir/wt" for-each-ref --format='%(refname) %(objectname)')
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
all="$*"
[ "${1:-}" != -k ] || shift 2
if [ "$1 $2 $3" = '120 git ls-remote' ]; then
  printf '%s\n' "$all" > "$FM_FAKE_DIR/probe-timeout"
  exit 124
fi
shift
exec "$@"
SH
  chmod +x "$dir/fakebin/timeout"
  out=$(run_spawn "$dir" rl94 --relaunch)
  assert_contains "$out" 'git ls-remote exited 124, bounded to 120s' "origin probe must refuse a bounded timeout"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/probe-timeout")" '120 git ls-remote --exit-code --heads origin refs/heads/task-rl94' "origin probe must use the 120s bound"
  assert_equals "$before" "$(git -C "$dir/wt" for-each-ref --format='%(refname) %(objectname)')" "probe timeout changed refs"
  [ ! -s "$dir/fake/literal" ] || fail "probe timeout launched a replacement"
  pass "relaunch refuses a bounded origin pre-probe timeout before launching or changing refs"
}

test_promoted_scout_relaunch_receives_the_current_delivery_contract() {
  local dir home id brief launch out mode rule
  for mode in no-mistakes direct-PR local-only; do
    id="rl-promoted-${mode}"
    dir=$(new_case "promoted-scout-$mode" "$id")
    home="$dir/home"
    fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
    FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null \
      || fail "$mode: could not scaffold the scout brief"
    brief="$home/data/$id/brief.md"
    sed 's/{TASK}/Fix the promotion relaunch contract./; s/{FIRSTMATE_SPEC}/Preserve the current delivery mode./' \
      "$brief" > "$brief.filled"
    mv "$brief.filled" "$brief"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$dir/wt"
      echo "project=$dir/proj"
      echo "harness=claude"
      echo "kind=scout"
      echo "tasktmp=/tmp/fm-$id"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"

    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: scout promotion should succeed: $out"
    assert_grep 'This is a SCOUT task' "$brief" \
      "$mode: the reproduction fixture lost the original scout delivery text"
    assert_grep 'Never push to any remote and never open a PR' "$brief" \
      "$mode: the reproduction fixture lost the stale scout prohibition"

    printf 'zsh' > "$dir/fake/command"
    out=$(run_spawn "$dir" "$id" --relaunch) \
      || fail "$mode: promoted scout relaunch should succeed: $out"
    launch="$home/data/$id/launch-brief.md"
    assert_grep "This task is now kind=ship with mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the promoted task identity"
    assert_grep 'Any earlier "Never push" or scout-only delivery language in this file is superseded' "$launch" \
      "$mode: the replacement launch left the stale scout prohibition readable at face value"
    case "$mode" in
      direct-PR)
        rule="1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR." ;;
      local-only)
        rule="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`." ;;
      *)
        rule='1. Never push to the default branch. Never merge a PR.' ;;
    esac
    assert_grep "$rule" "$launch" \
      "$mode: the replacement launch did not receive the current ship push and merge safety rule"
    assert_grep "git checkout -b fm/$id" "$launch" \
      "$mode: the replacement launch did not receive its promoted branch name"
    assert_grep 'Inventory this worktree' "$launch" \
      "$mode: the replacement launch did not receive the scratch-state inventory step"
    assert_grep 'Carry over only the intended fix changes' "$launch" \
      "$mode: the replacement launch did not receive the carry-over boundary"
    assert_grep "Delivery contract: mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the actual ship delivery mode"
  done
  pass "fm-promote/fm-spawn --relaunch: the current ship contract supersedes stale scout delivery text"
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a task launched
# from a raw command records that command's basename rather than the exact
# adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

# --- 3 and 4. refusals before the agent is touched ---------------------------

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

# A restart must never put a worker back in a primary home or a
# repository's primary checkout; the recorded worktree is the only launch cwd.
test_relaunch_refuses_a_recorded_worktree_that_is_the_primary_home() {
  local dir out rc
  dir=$(new_case homewt rl11)
  add_ship_task "$dir" rl11 claude
  sed -i.bak "s#^worktree=.*#worktree=$dir/home#" "$dir/home/state/rl11.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl11 --relaunch 2>&1); rc=$?
  expect_code 1 "$rc" "a worktree that is the primary home should refuse"
  assert_contains "$out" "primary home or checkout" "the refusal should name the primary home"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must launch nothing"
  pass "fm-spawn --relaunch: a recorded worktree that is the primary home refuses"
}

test_relaunch_refuses_a_recorded_worktree_that_is_the_project_primary_checkout() {
  local dir out rc
  dir=$(new_case projwt rl12)
  add_ship_task "$dir" rl12 claude
  sed -i.bak "s#^worktree=.*#worktree=$dir/proj#" "$dir/home/state/rl12.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl12 --relaunch 2>&1); rc=$?
  expect_code 1 "$rc" "a worktree that is the project primary checkout should refuse"
  assert_contains "$out" "primary home or checkout" "the refusal should name the primary checkout"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must launch nothing"
  pass "fm-spawn --relaunch: a recorded worktree that is the project primary checkout refuses"
}

# Inherited Git location overrides must not disguise the primary checkout:
# a linked worktree's GIT_DIR plus the primary checkout as GIT_WORK_TREE would
# make the git-dir and common-dir probes disagree.
test_relaunch_refuses_the_primary_checkout_under_inherited_git_overrides() {
  local dir out rc linked_gd
  dir=$(new_case projwtenv rl13)
  add_ship_task "$dir" rl13 claude
  linked_gd=$(git -C "$dir/wt" rev-parse --absolute-git-dir)
  sed -i.bak "s#^worktree=.*#worktree=$dir/proj#" "$dir/home/state/rl13.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(GIT_DIR="$linked_gd" GIT_WORK_TREE="$dir/proj" run_spawn "$dir" rl13 --relaunch 2>&1); rc=$?
  expect_code 1 "$rc" "the primary checkout should refuse even under inherited GIT_DIR/GIT_WORK_TREE"
  assert_contains "$out" "primary home or checkout" "the refusal should name the primary checkout"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must launch nothing"
  pass "fm-spawn --relaunch: inherited Git overrides do not hide the project primary checkout"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

# --- 5. failure after the agent is stopped -----------------------------------

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree. That refusal is now
  # pre-stop so the running agent is not killed for a launch that cannot start.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the worktree mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pre-stop cwd refusal must leave the old agent running"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  assert_absent "$dir/home/state/rl13.control-relaunch" \
    "a pre-stop cwd refusal must not open a relaunch transaction"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "a pre-stop cwd refusal must not type an exit command"
  pass "fm-control relaunch: a worktree mismatch refuses before the agent is stopped"
}

test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_out rc i=0
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$dir/cwd-race-ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-stop worktree check"
  }
  link_out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 2>&1); rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-stop worktree mismatch should fail closed"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(meta_field "$dir" rl30 harness)" = claude ] \
    || fail "a pre-stop refusal must leave the live record on the running harness"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pre-stop refusal must leave the old agent running"
  pass "fm-control relaunch: a pre-stop worktree mismatch keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_prepublication_abort_with_busy_gen_restores_the_prior_record() {
  local dir out rc real_rm meta gen hook
  dir=$(new_case prepublishbusy rlbg1)
  add_ship_task "$dir" rlbg1 claude
  meta="$dir/home/state/rlbg1.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rlbg1)
  printf 'busy_gen=%s\n' "$gen" >> "$meta"
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rlbg1 relaunch --note "busy before an unpublished spawn"); rc=$?
  expect_code 1 "$rc" "a spawn refused before publication should fail closed"$'\n'"$out"
  assert_not_contains "$out" "was relaunched on" \
    "an unpublished spawn must not be reported as a relaunched record"
  [ "$(journal_field "$dir" rlbg1 rollback)" = prior-record-kept ] \
    || fail "a cleared busy_gen must not make an unpublished spawn look published"
  [ -z "$(meta_field "$dir" rlbg1 control_relaunch_tx)" ] \
    || fail "the restored record must not keep the stamped relaunch token"
  pass "fm-control relaunch: a cleared busy_gen does not mask an unpublished spawn"
}

test_unpublished_spawn_lock_failure_is_not_published() {
  local dir out rc real_rm meta gen hook
  dir=$(new_case lock-fail-unpublished rl93)
  add_ship_task "$dir" rl93 claude
  meta="$dir/home/state/rl93.meta"
  chmod 640 "$meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl93)
  printf 'busy_gen=%s\n' "$gen" >> "$meta"
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    FM_TEST_RELAUNCH_SPAWN_PUBLISHED_LOCK_FAIL=1 \
    run_control "$dir" rl93 relaunch --note "lock fail must not look published"); rc=$?
  expect_code 1 "$rc" "an unpublished spawn under lock failure should fail closed"$'\n'"$out"
  assert_not_contains "$out" "was relaunched on" \
    "lock failure must not report a published replacement"
  [ "$(journal_field "$dir" rl93 rollback)" = prior-record-kept ] \
    || fail "lock failure must restore the prior record, not keep an unconfirmed publication"
  [ "$(meta_field "$dir" rl93 harness)" = claude ] \
    || fail "lock failure must leave the prior harness"
  [ -z "$(meta_field "$dir" rl93 control_relaunch_tx)" ] \
    || fail "a restored unpublished record must not keep the stamped relaunch token"
  [ "$(stat -c %a "$meta" 2>/dev/null || stat -f %OLp "$meta")" = 640 ] \
    || fail "clearing the relaunch token must keep the record mode"
  pass "fm-control relaunch: spawn-published lock failure is not treated as published"
}

test_stamp_die_before_spawn_restores_the_prior_record() {
  local dir out rc real_mktemp prior
  dir=$(new_case stamp-die rl89)
  add_ship_task "$dir" rl89 claude
  chmod 640 "$dir/home/state/rl89.meta"
  real_mktemp=$(command -v mktemp)
  make_mktemp_spawn_err_failure_stub "$dir"
  out=$(FM_REAL_MKTEMP="$real_mktemp" \
    run_control "$dir" rl89 relaunch --note "die after the stamp"); rc=$?
  expect_code 1 "$rc" "a die after the stamp and before spawn should fail closed"$'\n'"$out"
  assert_contains "$out" "could not record spawn output" \
    "the refusal should name the spawn-output staging failure"
  [ -z "$(meta_field "$dir" rl89 control_relaunch_tx)" ] \
    || fail "a die before spawn must not leave the stamped token on the live record"
  prior="$dir/home/state/rl89.control-relaunch.meta-prior"
  [ -f "$prior" ] || fail "the checkpoint copy of the prior record should still exist"
  cmp -s "$prior" "$dir/home/state/rl89.meta" \
    || fail "prior-record-kept should restore the live record to the checkpoint copy"
  [ "$(stat -c %a "$dir/home/state/rl89.meta" 2>/dev/null || stat -f %Lp "$dir/home/state/rl89.meta")" = 640 ] \
    || fail "restoring the prior record should keep its original mode"
  [ "$(journal_field "$dir" rl89 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-control relaunch: a die after the stamp and before spawn restores the prior record"
}

test_stamp_mv_failure_removes_the_staging_file() {
  local dir out rc real_mv
  dir=$(new_case stamp-mv rl90)
  add_ship_task "$dir" rl90 claude
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/rl90.meta.tx" \
    run_control "$dir" rl90 relaunch --note "stamp mv fails"); rc=$?
  expect_code 1 "$rc" "a failed stamp mv should fail closed"$'\n'"$out"
  assert_contains "$out" "could not record relaunch token" \
    "the refusal should name the stamp mv failure"
  [ ! -e "$dir/home/state/rl90.meta.tx" ] \
    || fail "rollback must remove the leftover stamp staging file"
  [ -z "$(meta_field "$dir" rl90 control_relaunch_tx)" ] \
    || fail "a failed stamp mv must not leave a stamped token on the live record"
  [ "$(journal_field "$dir" rl90 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-control relaunch: a failed stamp mv does not leave META.tx beside the record"
}

test_restore_failure_is_journaled_as_restore_failed() {
  local dir out rc real_mktemp real_cp
  dir=$(new_case restore-fail rl91)
  add_ship_task "$dir" rl91 claude
  real_mktemp=$(command -v mktemp)
  real_cp=$(command -v cp)
  make_mktemp_spawn_err_failure_stub "$dir"
  make_cp_restore_failure_stub "$dir"
  out=$(FM_REAL_MKTEMP="$real_mktemp" FM_REAL_CP="$real_cp" \
    FM_FAKE_CP_RESTORE_FAIL="$dir/home/state/rl91.meta" \
    run_control "$dir" rl91 relaunch --note "restore fails"); rc=$?
  expect_code 1 "$rc" "a failed prior-record restore should fail closed"$'\n'"$out"
  assert_contains "$out" "could not restore" \
    "the refusal should name the restore failure"
  [ -n "$(meta_field "$dir" rl91 control_relaunch_tx)" ] \
    || fail "a failed restore must leave the stamped token on the live record"
  [ "$(journal_field "$dir" rl91 rollback)" = prior-record-restore-failed ] \
    || fail "the journal must record restore-failed, not prior-record-kept"
  pass "fm-control relaunch: a failed prior-record restore is journaled as restore-failed"
}

test_stamp_serializes_a_cooperating_metadata_writer() {
  local dir control_pid link_pid rc i=0 ready release waiting
  dir=$(new_case stamp-race txrace)
  add_ship_task "$dir" txrace claude
  make_mv_failure_stub "$dir"
  ready="$dir/stamp-tx-ready"
  release="$dir/stamp-tx-release"
  waiting="$dir/meta-writer-waiting"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_STAMP_TX_READY="$ready" \
    FM_FAKE_STAMP_TX_RELEASE="$release" \
    run_control "$dir" txrace relaunch --note "keep concurrent routing" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach control_relaunch_tx stamp"
  }
  grep -q '\.meta\.tx$' "$ready" \
    || fail "stamp race must pause on META.tx, not another mv"$'\n'"$(cat "$ready")"
  [ "$(cat "$dir/fake/command")" = zsh ] \
    || fail "stamp race must run after the old agent has stopped, not at the pre-stop cwd check"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" FM_REAL_MKTEMP="$(command -v mktemp)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    "$X_LINK" txrace request-tx --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ -z "$(meta_field "$dir" txrace x_request)" ] || {
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during token stamp"$'\n'"$(cat "$dir/link.out" 2>/dev/null || true)"$'\n'"$(cat "$dir/home/state/txrace.meta")"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete after serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  assert_not_contains "$(cat "$dir/control.out")" "not its recorded worktree" \
    "stamp race must not be the pre-stop cwd refusal"
  [ "$(meta_field "$dir" txrace x_request)" = request-tx ] \
    || fail "token stamp erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" txrace x_followups)" = 1 ] \
    || fail "token stamp erased the concurrent follow-up count"
  [ "$(meta_field "$dir" txrace harness)" = claude ] \
    || fail "serialized stamp must keep the replacement on the recorded harness"
  pass "fm-control relaunch: token stamp serializes with a cooperating metadata writer"
}

test_restore_preserves_a_cooperating_metadata_update() {
  local dir control_pid link_pid rc i=0 ready release waiting
  dir=$(new_case restore-race rbrc)
  add_ship_task "$dir" rbrc claude
  make_mktemp_spawn_err_failure_stub "$dir"
  make_cp_restore_failure_stub "$dir"
  ready="$dir/restore-cp-ready"
  release="$dir/restore-cp-release"
  waiting="$dir/meta-writer-waiting"
  FM_REAL_MKTEMP=$(command -v mktemp) \
    FM_REAL_CP=$(command -v cp) \
    FM_FAKE_RESTORE_PAUSE_READY="$ready" \
    FM_FAKE_RESTORE_PAUSE_RELEASE="$release" \
    FM_FAKE_RESTORE_PAUSE="$dir/home/state/rbrc.meta" \
    run_control "$dir" rbrc relaunch --note "preserve concurrent routing on rollback" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach prior-record restore"
  }
  [ "$(cat "$dir/fake/command")" = zsh ] \
    || fail "rollback race must run after the old agent has stopped, not at the pre-stop cwd check"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MKTEMP="$(command -v mktemp)" FM_REAL_CP="$(command -v cp)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    "$X_LINK" rbrc request-rb --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$(meta_field "$dir" rbrc x_request)" != request-rb ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] || [ "$(meta_field "$dir" rbrc x_request)" = request-rb ] || {
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "cooperating writer neither blocked nor published during restore"$'\n'"$(cat "$dir/link.out" 2>/dev/null || true)"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should succeed"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "a die after the stamp and before spawn should fail closed"$'\n'"$(cat "$dir/control.out")"
  assert_contains "$(cat "$dir/control.out")" "could not record spawn output" \
    "rollback race must die after stamp, not at the pre-stop cwd check"
  assert_not_contains "$(cat "$dir/control.out")" "not its recorded worktree" \
    "rollback race must not be the pre-stop cwd refusal"
  [ "$(meta_field "$dir" rbrc x_request)" = request-rb ] \
    || fail "prior-record restore erased a concurrent X request"
  [ "$(meta_field "$dir" rbrc x_followups)" = 2 ] \
    || fail "prior-record restore erased the concurrent follow-up count"
  [ "$(cat "$dir/fake/command")" = zsh ] \
    || fail "a launching-phase rollback must leave the old agent stopped"
  pass "fm-control relaunch: prior-record restore keeps a concurrent metadata update"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

# --- secondmate child-work safety -------------------------------------------

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable child records fail checkpoint"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-control relaunch: unlistable state check skipped as root (mode 000 does not restrict root)"
    return 0
  fi
  rmdir "$dir/smhome/state/bad.meta"
  printf 'window=x:c1\n' > "$dir/smhome/state/c1.meta"
  chmod 000 "$dir/smhome/state"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  chmod 755 "$dir/smhome/state"
  expect_code 1 "$rc" "an unlistable state directory should refuse"
  assert_contains "$out" "no readable state directory" \
    "the refusal should name the unlistable home state directory"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "unlistable child state must not stop the secondmate"
  pass "fm-control relaunch: unlistable state fails checkpoint"
}

test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk() {
  local dir home out rc real_find
  dir=$(new_case smfindrace sm6)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  : > "$dir/smhome/state/.hash-0"
  : > "$dir/smhome/state/.count-0"
  : > "$dir/smhome/state/.last-0"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  real_find=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$dir/smhome/state" ]; then
    echo "find: \$arg/.hash-0: No such file or directory" >&2
    exit 1
  fi
done
exec "$real_find" "\$@"
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "a vanished watcher scratch file must not refuse relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched sm6" "readable child metas must still allow the replacement launch"
  [ "$(journal_field "$dir" sm6 children)" = 2 ] \
    || fail "readable child metas must still be counted, got '$(journal_field "$dir" sm6 children)'"
  pass "fm-control relaunch: a vanished watcher scratch file does not fail the child-record checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  printf 'held\n' > "$dir/home/state/rl19.composer-dialog"
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  [ "$(cat "$dir/home/state/rl19.composer-dialog" 2>/dev/null)" = held ] \
    || fail "a refused concurrent relaunch must not remove the lock holder's dialog file"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

# shellcheck disable=SC2031
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the lifecycle lock"
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

# shellcheck disable=SC2031
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the promotion lifecycle lock"
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

# --- 6. fm-spawn --relaunch's own refusals -----------------------------------

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  dir=$(new_case symlink-meta rl37)
  add_ship_task "$dir" rl37 claude
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$dir/relaunch-endpoint-inspected"
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  assert_absent "$dir/relaunch-endpoint-inspected" \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_keeps_its_early_meta_lock_continuous() {
  local dir lock out rc
  dir=$(new_case continuous-meta-lock rl38)
  add_ship_task "$dir" rl38 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.meta-rl38.lock"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -d "$lock" ]; then
  if [ ! -e "$dir/lock-observation-started" ]; then
    : > "$dir/lock-observation-started"
    : > "$lock/continuity-sentinel"
  elif [ ! -e "$lock/continuity-sentinel" ]; then
    : > "$dir/meta-lock-was-recreated"
  fi
fi
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with one continuous meta lock should succeed"$'\n'"$out"
  assert_present "$dir/lock-observation-started" \
    "test did not observe the relaunch-held meta lock"
  assert_absent "$dir/meta-lock-was-recreated" \
    "relaunch released or recreated its already-held meta lock"
  pass "fm-spawn --relaunch: keeps its early meta lock continuous"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  dir=$(new_case pending-close rl36)
  add_ship_task "$dir" rl36 claude
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  mkdir -p "$dir/wt/.claude"
  printf 'prior wiring\n' > "$dir/wt/.claude/settings.local.json"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl36 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/wt/.claude/settings.local.json" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  [ ! -s "$dir/fake/keys" ] || fail "a refused tmux relaunch must send nothing to the pane"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding its work"
}

test_herdr_relaunch_refuses_when_cd_does_not_return_to_the_worktree() {
  local dir out rc
  herdr_case_or_skip wrongcwd-herdr rl88 || {
    echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle","agent_session":{"kind":"path","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
    > "$dir/fake/herdr-agent-registration"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl88 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a Herdr pane that does not return to the worktree should refuse"$'\n'"$out"
  assert_contains "$out" "did not return to its recorded worktree" \
    "the refusal should name the failed return"
  pass "fm-spawn --relaunch: a Herdr pane outside the worktree that cannot cd back is refused"
}

# --- 7. reclaiming a task whose endpoint is gone ----------------------------
#
# Before this, `missing` was a terminal state: fm-spawn --relaunch accepted only
# `dead` and told the caller to stop the agent first, while fm-control exit
# refused `missing` outright and told the caller to reconcile the task first -
# and there is no reconcile verb. Each command named the other as its
# prerequisite, so a task whose pane or workspace was destroyed could not be
# reclaimed by anything, and any no-mistakes approval it was parked on had no
# seat left to answer it.

# strand_endpoint <case-dir> <id>: make a tmux endpoint read `missing` the way
# a destroyed window does - a successful session inventory that omits the exact
# window.
strand_endpoint() {  # <case-dir> <id>
  : > "$1/fake/windows"
}

# A tmux `missing` on a record WITHOUT the server identity a tmux spawn now
# records refuses on BOTH verbs, whatever produced it: any inventory describes
# only the server this process happens to address, so a window that is merely
# on a server this seat cannot reach is indistinguishable from one that was
# destroyed, and neither verb will guess.
assert_tmux_missing_refuses() {  # <case-dir> <id> <what-was-staged>
  local dir=$1 id=$2 what=$3 out rc brief_before

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunch must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_absent "$dir/fake/created-windows" "a refused relaunch must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused relaunch must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must send nothing into any pane ($what)"

  brief_before=$(cat "$dir/home/data/$id/brief.md")
  out=$(run_control "$dir" "$id" exit); rc=$?
  expect_code 1 "$rc" "exit must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_not_contains "$out" "endpoint-gone" \
    "exit must not report a stop it cannot see ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused exit must send nothing into any pane ($what)"

  out=$(run_control "$dir" "$id" relaunch --note "this note must never reach a live agent"); rc=$?
  expect_code 1 "$rc" "the relaunch transaction must fail closed ($what)"$'\n'"$out"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused relaunch edited instructions an agent that may still be running is reading ($what)"
  assert_absent "$dir/fake/created-windows" "a refused transaction must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused transaction must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused transaction must launch nothing ($what)"
}

test_tmux_refuses_a_window_missing_from_its_session() {
  local dir
  dir=$(new_case tmux-gone rl60)
  add_ship_task "$dir" rl60 claude
  strand_endpoint "$dir" rl60
  assert_tmux_missing_refuses "$dir" rl60 "window absent from a readable session inventory"
  pass "tmux: a window absent from its session refuses both verbs rather than being assumed gone"
}

test_tmux_refuses_a_session_that_cannot_be_found() {
  local dir
  dir=$(new_case tmux-nosession rl61)
  add_ship_task "$dir" rl61 claude
  # Real tmux's answer to a renamed session, and to a different
  # TMUX_TMPDIR/socket: definitive about the SESSION, silent about whether the
  # window and its agent survived elsewhere.
  : > "$dir/fake/session-missing"
  assert_tmux_missing_refuses "$dir" rl61 "recorded session not found"
  pass "tmux: an unfindable session refuses both verbs, so a live agent is never duplicated"
}

test_tmux_refuses_when_the_server_is_gone() {
  local dir
  dir=$(new_case tmux-noserver rl62)
  add_ship_task "$dir" rl62 claude
  # No server on the socket this process addresses. Another server may still be
  # running the task's window, and the record cannot say which socket is its.
  : > "$dir/fake/server-dead"
  assert_tmux_missing_refuses "$dir" rl62 "no tmux server on this socket"
  pass "tmux: a dead server on this socket refuses both verbs rather than proving absence"
}

# A record that carries its tmux server's identity can be reclaimed once that
# exact server is gone: exit reports the endpoint gone, relaunch re-creates one
# window in the recorded session on the recorded socket and republishes the
# record with the new server's identity. A seat addressing a different socket
# is refused rather than moving the task.
test_tmux_reclaims_a_lost_server_from_its_record() {
  local dir out rc sock dead
  dir=$(new_case tmux-reclaim rl64)
  add_ship_task "$dir" rl64 claude
  sock=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_addressed_socket' _ "$ROOT")
  sleep 0 &
  # shellcheck disable=SC2031 # $! names the job this shell just started
  dead=$!
  wait "$dead"
  printf 'tmux_socket=%s\ntmux_server_pid=%s\ntmux_server_identity=%s\ntmux_window_id=%s\n' \
    "$sock" "$dead" "a server that has exited" @3 >> "$dir/home/state/rl64.meta"
  strand_endpoint "$dir" rl64
  : > "$dir/fake/server-dead"
  out=$(run_control "$dir" rl64 exit); rc=$?
  expect_code 0 "$rc" "exit must succeed once the recorded tmux server is proven gone"$'\n'"$out"
  assert_contains "$out" "endpoint-gone" "exit must report the endpoint gone"
  out=$(FM_FAKE_TMUX_SOCKET="$sock" FM_FAKE_TMUX_SERVER_PID=$$ run_spawn "$dir" rl64 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch must reclaim a task whose recorded tmux server is gone"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/created-sessions" 2>/dev/null)" "fmses" "the recorded session must be re-created"
  [ "$(grep -c '^fm-rl64$' "$dir/fake/created-windows" 2>/dev/null)" = 1 ] \
    || fail "exactly the task's window must be re-created once, got: $(cat "$dir/fake/created-windows" 2>/dev/null)"
  [ "$(sort -u "$dir/fake/created-sockets" 2>/dev/null)" = "$sock" ] \
    || fail "the reclaim must create its session on the recorded socket, got: $(cat "$dir/fake/created-sockets" 2>/dev/null)"
  [ "$(meta_field "$dir" rl64 window)" = "fmses:fm-rl64" ] || fail "the record must rebind to the new window"
  [ "$(meta_field "$dir" rl64 tmux_server_pid)" = "$$" ] || fail "the record must carry the new server's identity"
  [ "$(meta_field "$dir" rl64 tmux_window_id)" = "@9" ] || fail "the record must carry the new window id"

  dir=$(new_case tmux-reclaim-elsewhere rl65)
  add_ship_task "$dir" rl65 claude
  printf 'tmux_socket=%s\ntmux_server_pid=%s\ntmux_server_identity=%s\ntmux_window_id=%s\n' \
    /nonexistent/tmux-other/default "$dead" "a server that has exited" @3 >> "$dir/home/state/rl65.meta"
  strand_endpoint "$dir" rl65
  : > "$dir/fake/server-dead"
  out=$(run_control "$dir" rl65 exit); rc=$?
  expect_code 1 "$rc" "exit from a seat on another tmux server must refuse"$'\n'"$out"
  assert_contains "$out" "never acts on another tmux server" "the exit refusal must say why"
  [ ! -s "$dir/fake/literal" ] || fail "a refused exit must send nothing to the other server"
  out=$(run_spawn "$dir" rl65 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a reclaim from a seat on another tmux server must refuse"$'\n'"$out"
  assert_contains "$out" "never moves a task to another tmux server" "the refusal must say why"
  assert_absent "$dir/fake/created-windows" "a refused reclaim must not create a window"
  pass "tmux: a recorded server proven gone is reclaimed on that server; another server's seat is refused"
}

test_reclaim_refuses_an_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case gone-unreadable rl63)
  add_ship_task "$dir" rl63 claude
  # The inventory itself fails non-definitively. That is not evidence of
  # absence, and reading it as one is exactly how two agents end up in one
  # endpoint.
  : > "$dir/fake/inventory-broken"

  out=$(run_spawn "$dir" rl63 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an unreadable endpoint must still refuse"
  assert_contains "$out" "positively agent-free endpoint" \
    "only a POSITIVELY proven agent-free endpoint may be relaunched into"
  assert_absent "$dir/fake/created-windows" \
    "a refused relaunch must not create an endpoint"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must launch nothing"
  pass "reclaim: an unclassifiable endpoint is still refused, so two agents cannot share one"
}

# --- herdr: a stopped server is not a destroyed endpoint --------------------
#
# Stopping and restarting a named Herdr server preserves workspace, tab, pane
# and label ids; only the harness processes and their registrations die
# (docs/herdr-backend.md "Restart and liveness behavior"). The recovery-grade
# classifier still reads a stopped server as `missing`, so a reclaim that
# believed that verdict would abandon a pane that was about to come back and
# open a second tab beside it.
#
# Canned/stateful fake only - never a real herdr session.
make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  # The herdr server-ensure poll must actually wait between reads, so this case
  # keeps the real sleep rather than the tmux cases' instant stub.
  rm -f "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
  exit 0
fi
if [ "${1:-}" = server ]; then
  [ ! -f "$D/herdr-server-start-fails" ] || exit 1
  rm -f "$D/herdr-stopped"
  [ ! -f "$D/herdr-server-restores-agent" ] || : > "$D/herdr-agent-live"
  exit 0
fi
if [ -f "$D/herdr-stopped" ]; then
  # Every operational call against a stopped server fails at the transport,
  # with no JSON body to classify.
  echo 'error: could not connect to the herdr server' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pane read')
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  'pane get')
    if [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
        "${3:-}" "$(cat "$D/cwd")"
    else
      # Only the pane this case says survived can be read back. Any other pane
      # id is structurally gone, which is herdr's `pane_not_found`.
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-registration" ]; then
      cat "$D/herdr-agent-registration"
    elif [ -f "$D/herdr-agent-live" ]; then
      # The agent came back with its server. Nothing here is reclaimable.
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      # A pane that comes back holding no agent is the adoptable state.
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    # A retained registration with a shell-only pane models an exited agent
    # whose Herdr status authority still belongs to its previous session.
    if [ -f "$D/herdr-agent-registration" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' \
        "$(cat "$D/herdr-pane")"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' \
        "$(cat "$D/herdr-pane")"
    fi
    exit 0 ;;
  'pane send-text')
    # Mirrors the tmux fake's `becomes`: delivering the launch brief is what
    # makes an agent exist on this pane, so the control plane's alive-wait can
    # observe the replacement come up. A launch arrives as a short line sourcing
    # the staged launch file rather than the literal command, so read that file
    # back before deciding what was delivered - exactly as the tmux fake above
    # and tests/fixtures.sh do.
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      /exit) : > "$D/herdr-exit-staged" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'pane send-keys')
    if [ "${4:-}" = enter ] && [ -f "$D/herdr-exit-staged" ]; then
      if [ -f "$D/herdr-exit-closes-pane" ]; then
        printf '%%none' > "$D/herdr-pane"
      elif [ -f "$D/herdr-exit-stops-server" ]; then
        : > "$D/herdr-stopped"
        rm -f "$D/herdr-agent-live"
      fi
    fi
    exit 0 ;;
  'workspace list')
    printf '{"result":{"workspaces":[]}}\n'
    exit 0 ;;
  'workspace create')
    if [ -f "$D/herdr-workspace-create-fails" ]; then
      echo 'error: workspace create failed' >&2
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'
    exit 0 ;;
  'tab list')
    printf '{"result":{"tabs":[]}}\n'
    exit 0 ;;
  'tab create')
    # The re-created endpoint. Recording it lets a case prove the pane the
    # record ends up naming is the one this call minted.
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    # From here on the new pane is the one that reads back.
    printf '%s' '%9' > "$D/herdr-pane"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_FAKE_DIR/herdr-agent-registration" ]; then
  case "$*" in
    '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
    '-p 4242 -o args=') printf 'bash\n' ;;
    *) exec /bin/ps "$@" ;;
  esac
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$fb/ps"
}

# add_herdr_ship_task <case-dir> <id> [session] [surviving-pane]: a ship task
# recorded on the herdr backend, with its server stopped so its endpoint
# classifies `missing`. <surviving-pane> is the pane id the fake will answer for
# once that server is back; default is the recorded one (it survived the
# restart). Pass a different id to model a pane that genuinely did not.
add_herdr_ship_task() {  # <case-dir> <id> [session] [surviving-pane]
  local dir=$1 id=$2 ses=${3:-fmlab} survivor=${4:-'%7'}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a herdr reclaim safely.

## Firstmate spec
Keep the recorded endpoint when it outlives its server.
EOF
  {
    echo "window=$ses:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$ses"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$survivor" > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
  TASK_TMPS+=("/tmp/fm-$id")
}

# Sets HERDR_CASE_DIR rather than echoing it, so callers invoke it as a plain
# statement. A `dir=$(herdr_case_or_skip ...)` would run add_herdr_ship_task in
# a command-substitution subshell, where its TASK_TMPS registration would
# mutate a discarded copy and the EXIT trap would never remove the
# out-of-tmproot /tmp/fm-<id> root the spawn creates.
HERDR_CASE_DIR=
herdr_case_or_skip() {  # <name> <id> [session] [surviving-pane]
  HERDR_CASE_DIR=
  command -v jq >/dev/null 2>&1 || return 1
  HERDR_CASE_DIR=$(new_case "$1" "$2")
  add_herdr_ship_task "$HERDR_CASE_DIR" "$2" "${3:-fmlab}" "${4:-%7}"
  make_herdr_stub "$HERDR_CASE_DIR"
  return 0
}

test_herdr_relaunch_resumes_only_the_registered_pi_session() {
  local dir out rc=0 command registered
  for registered in pi claude; do
    herdr_case_or_skip "resume-$registered" "resume-$registered" || {
      echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
      return 0
    }
    dir=$HERDR_CASE_DIR
    rm -f "$dir/fake/herdr-stopped"
    sed 's/^harness=claude$/harness=pi/' "$dir/home/state/resume-$registered.meta" \
      > "$dir/home/state/resume-$registered.meta.tmp"
    mv "$dir/home/state/resume-$registered.meta.tmp" "$dir/home/state/resume-$registered.meta"
    # Launch delivery is stubbed below; executable discovery must be hermetic too.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/pi"
    chmod +x "$dir/fakebin/pi"
    # Keep the pane's status authority registered to an existing Pi session,
    # while process-info proves that its previous agent has exited.
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","agent_session":{"kind":"path","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
      "$registered" > "$dir/fake/herdr-agent-registration"
    out=$(run_spawn "$dir" "resume-$registered" --relaunch --harness pi) || rc=$?
    expect_code 0 "$rc" "Herdr Pi relaunch should complete ($registered registration)"$'\n'"$out"
    command=$(cat "$dir/fake/launched-command")
    if [ "$registered" = pi ]; then
      assert_contains "$command" "--session '/tmp/pi-bound-session.jsonl'" \
        "the replacement Pi must resume the session that owns Herdr status authority"
    else
      assert_not_contains "$command" "--session" \
        "a Pi replacement must not resume a foreign adapter's conversation"
    fi
    rc=0
  done
  pass "fm-spawn --relaunch: resumes the bound Pi session only for a Pi registration"
}

test_herdr_reclaim_adopts_a_pane_that_outlived_its_server() {
  local dir out rc=0 log stray
  herdr_case_or_skip gone-herdr rl68 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl68 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a pane that outlived its stopped server is adoptable"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "server --session fmlab" \
    "the reclaim must bring the RECORDED session's server back before deciding anything"
  assert_contains "$log" "agent get %7 --session fmlab" \
    "the reclaim must re-read the recorded pane once its server is running"
  assert_not_contains "$log" "workspace create" \
    "adopting a preserved pane must not create a workspace"
  assert_not_contains "$log" "tab create" \
    "adopting a preserved pane must not open a second tab beside it"
  # Every call belongs to the session the record names. A rebind resolves its
  # container from the ambient session instead, which is how the preserved pane
  # ends up orphaned in a workspace nothing points at.
  stray=$(printf '%s\n' "$log" | grep -v -- '--session fmlab$' | grep -v '^status --json$' || true)
  [ -z "$stray" ] || fail "a herdr reclaim touched a session the record does not name: $stray"
  assert_contains "$out" "window=fmlab:%7" "the reclaim should report the adopted endpoint"
  [ "$(meta_field "$dir" rl68 herdr_pane_id)" = '%7' ] \
    || fail "the adopted record's pane id changed, got $(meta_field "$dir" rl68 herdr_pane_id)"
  [ "$(meta_field "$dir" rl68 herdr_tab_id)" = tab1 ] \
    || fail "the adopted record's tab id changed, got $(meta_field "$dir" rl68 herdr_tab_id)"
  [ "$(meta_field "$dir" rl68 window)" = 'fmlab:%7' ] \
    || fail "the adopted record's endpoint moved, got $(meta_field "$dir" rl68 window)"
  assert_contains "$log" "pane send-text %7 " \
    "the replacement's launch brief must be delivered into the adopted pane"
  pass "reclaim: a herdr pane that outlived its stopped server is adopted, never orphaned beside a new tab"
}

test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server() {
  local dir out rc=0
  herdr_case_or_skip gone-herdr-exit rl72 || {
    echo "skip - herdr exit needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_control "$dir" rl72 exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" rl72 window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
}

test_herdr_exit_proves_the_post_command_endpoint_state() {
  local dir out rc outcome id gen
  for outcome in closed idle unreachable alive; do
    id="post-exit-$outcome"
    herdr_case_or_skip "$id" "$id" || {
      echo "skip - Herdr post-exit absence proof needs jq"
      return 0
    }
    dir=$HERDR_CASE_DIR
    rm -f "$dir/fake/herdr-stopped"
    : > "$dir/fake/herdr-agent-live"
    printf 'uncommitted work\n' > "$dir/wt/preserved.txt"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id")
    printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
    case "$outcome" in
      closed) : > "$dir/fake/herdr-exit-closes-pane" ;;
      *) : > "$dir/fake/herdr-exit-stops-server" ;;
    esac
    if [ "$outcome" = unreachable ]; then
      : > "$dir/fake/herdr-server-start-fails"
    elif [ "$outcome" = alive ]; then
      # The server comes back with an agent; absence proof must not stop it.
      : > "$dir/fake/herdr-server-restores-agent"
    fi

    rc=0
    out=$(run_control "$dir" "$id" exit) || rc=$?
    case "$outcome" in
      closed|idle)
        expect_code 0 "$rc" "$outcome endpoint must be proved stopped after the exit command"$'\n'"$out"
        if [ "$outcome" = closed ]; then
          assert_contains "$out" "endpoint-gone $id" "the exact pane was destroyed"
        else
          assert_contains "$out" "stopped $id" "a restored idle pane is stopped"
          assert_not_contains "$out" "endpoint-gone" "the idle pane survived"
        fi
        [ ! -e "$dir/home/state/$id.busy-gen" ] || fail "$outcome exit left a busy generation"
        [ ! -e "$dir/home/state/$id.busy-state" ] || fail "$outcome exit left busy state"
        [ -z "$(meta_field "$dir" "$id" busy_gen)" ] || fail "$outcome exit left its metadata busy generation"
        ;;
      *)
        expect_code 1 "$rc" "$outcome endpoint cannot prove a stopped agent"$'\n'"$out"
        assert_contains "$out" "exit=unconfirmed" "unproved exit must stay unconfirmed"
        [ "$(cat "$dir/home/state/$id.busy-gen")" = "$gen" ] || fail "unproved exit retired its busy generation"
        if [ "$outcome" = unreachable ]; then
          assert_contains "$out" "the recorded herdr session's server could not be started" \
            "the refusal must explain why absence was not proven"
        fi
        ;;
    esac
    assert_contains "$(cat "$dir/fake/herdr-log")" "pane send-keys %7 enter --session fmlab" \
      "the exit command must reach the recorded endpoint"
    [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "exit changed the worktree record"
    [ "$(cat "$dir/wt/preserved.txt")" = 'uncommitted work' ] || fail "exit changed uncommitted work"
  done
  pass "fm-control exit: post-command Herdr absence proof confirms only gone or idle endpoints"
}

test_herdr_rebind_stays_in_the_recorded_session() {
  local dir out rc=0 log
  # The record names session `fmlab`; this seat has no ambient HERDR_SESSION, so
  # the adapter's own default is `default`. The recorded pane does NOT come back
  # with the server, so this reclaim really does rebind - and the rebind must
  # land in `fmlab`, never in `default`.
  herdr_case_or_skip gone-herdr-pin rl73 fmlab '%none' || {
    echo "skip - herdr rebind needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl73 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a herdr pane that did not survive its server should be rebound"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "tab create" "a destroyed pane must be replaced by a fresh tab"
  [ -z "$(grep -v -- '--session fmlab$' <<<"$log" | grep -v '^status --json$' || true)" ] \
    || fail "the rebind used a herdr session the record does not name: $log"
  [ "$(meta_field "$dir" rl73 herdr_session)" = fmlab ] \
    || fail "the rebound record left its recorded herdr session, got $(meta_field "$dir" rl73 herdr_session)"
  [ "$(meta_field "$dir" rl73 window)" = 'fmlab:%9' ] \
    || fail "the rebound endpoint should be the new pane in the recorded session, got $(meta_field "$dir" rl73 window)"
  [ "$(meta_field "$dir" rl73 herdr_pane_id)" = '%9' ] \
    || fail "the rebound record should name the pane the reclaim minted, got $(meta_field "$dir" rl73 herdr_pane_id)"
  pass "reclaim: a herdr rebind is created in the session the record names, never the ambient one"
}

test_herdr_reclaim_refuses_an_agent_that_came_back() {
  local dir out rc log
  herdr_case_or_skip gone-herdr-alive rl74 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  # The server was stopped, so the first read says `missing` - but starting it
  # brings the pane AND its agent back. A rebind here would put a second agent
  # in this task's worktree, which is the whole reason absence is re-proven.
  : > "$dir/fake/herdr-agent-live"

  out=$(run_spawn "$dir" rl74 --relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a returning agent must refuse, never be duplicated"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused reclaim must not mint a second tab"
  assert_not_contains "$log" "workspace create" "a refused reclaim must not create a workspace"
  [ "$(meta_field "$dir" rl74 herdr_pane_id)" = '%7' ] \
    || fail "a refused reclaim rewrote the record's pane id"
  pass "reclaim: a herdr agent that came back with its server refuses, so one worktree keeps one agent"
}

test_herdr_reclaim_keeps_the_task_whole() {
  local dir out rc=0 head_before
  herdr_case_or_skip gone-herdr-work rl75 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'never committed\n' > "$dir/wt/dirty.txt"

  # A reclaim rebinds the ENDPOINT and nothing else. Everything that identifies
  # the task must come through untouched: a record row the reclaim does not
  # own, the armed watcher check and the private binding that authorizes it,
  # and the status log the supervisor reads.
  printf '%s\n' "pr=https://example.invalid/pr/7" >> "$dir/home/state/rl75.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/rl75.check.sh"
  chmod 0700 "$dir/home/state/rl75.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" rl75 >/dev/null \
    || fail "could not arm a custom check for the reclaim fixture"
  printf 'working: parked on an approval nobody can answer\n' >> "$dir/home/state/rl75.status"

  out=$(run_control "$dir" rl75 relaunch --note "the pane was destroyed; pick the work back up") || rc=$?
  expect_code 0 "$rc" "the owning seat should be able to reclaim a task whose pane is gone"$'\n'"$out"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "a reclaim moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "task-rl75" ] \
    || fail "a reclaim changed the worktree's branch"
  assert_contains "$(cat "$dir/wt/dirty.txt")" "never committed" \
    "a reclaim destroyed or rewrote an uncommitted change"
  assert_present "$dir/wt/committed.txt" "a reclaim destroyed committed work"

  [ "$(meta_field "$dir" rl75 worktree)" = "$dir/wt" ] \
    || fail "a reclaim must keep the recorded worktree"
  [ "$(meta_field "$dir" rl75 pr)" = "https://example.invalid/pr/7" ] \
    || fail "a reclaim dropped a record row it does not own"
  assert_present "$dir/home/state/rl75.check.sh" "a reclaim retired the task's armed check"
  assert_present "$dir/home/state/rl75.check-trust" "a reclaim broke the armed check's registration"
  assert_contains "$(cat "$dir/home/state/rl75.status")" "parked on an approval nobody can answer" \
    "a reclaim truncated the status log"
  assert_contains "$(cat "$dir/home/data/rl75/brief.md")" "the pane was destroyed" \
    "the replacement must inherit the progress note"
  [ "$(journal_field "$dir" rl75 exit_result)" = endpoint-gone ] \
    || fail "the transaction should record that the endpoint was already gone"
  pass "reclaim: a herdr reclaim rebinds the endpoint and leaves the whole rest of the task alone"
}

test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause() {
  local dir out rc
  # No HERDR_* env at all, which is how an operator reclaims from ssh or cron.
  # The adapter's ambient session then reads `default` while the record names
  # `fmlab`, but the cross-session launcher guard was never consulted - this
  # seat claims no launcher pane, so placement fell back to the recorded
  # session's labeled container and the container failed for its own reason.
  herdr_case_or_skip gone-herdr-plain rl77 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(run_spawn "$dir" rl77 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a container that cannot be ensured must refuse"$'\n'"$out"
  assert_contains "$out" "fmlab" "the refusal should name the session the reclaim was targeting"
  assert_not_contains "$out" "this seat is running in herdr session" \
    "a seat with no launcher pane never hit the cross-session guard, so the refusal must not blame one"
  assert_not_contains "$out" "a reclaim never moves a task to another session" \
    "the operator must not be sent to re-run from another seat when that would not help"
  pass "reclaim: a rebind refused from a plain shell reports the real cause, not a fabricated session mismatch"
}

test_herdr_reclaim_of_a_secondmate_uses_relaunch() {
  local dir out rc log
  herdr_case_or_skip gone-herdr-secondmate rl76 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  mkdir -p "$dir/wt/bin" "$dir/wt/data" "$dir/wt/state" "$dir/wt/config" "$dir/wt/projects"
  mkdir -p "$dir/home/config"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  printf 'rl76\n' > "$dir/wt/.fm-secondmate-home"
  printf '# agents\n' > "$dir/wt/AGENTS.md"
  printf '# charter\n' > "$dir/wt/data/charter.md"
  printf '%s\n' "kind=secondmate" "home=$dir/wt" "mode=secondmate" >> "$dir/home/state/rl76.meta"

  out=$(run_spawn "$dir" rl76 --relaunch --harness claude); rc=$?
  expect_code 4 "$rc" "direct --relaunch of a gone secondmate must refuse"$'\n'"$out"
  assert_contains "$out" "--secondmate" \
    "direct --relaunch must send a gone secondmate to --secondmate or fm-control"
  [ ! -s "$dir/fake/herdr-log" ] || ! grep -q "tab create" "$dir/fake/herdr-log" \
    || fail "a refused direct --relaunch must not mint a replacement pane"

  out=$(FM_CONTROL_RELAUNCH_TX=forged run_spawn "$dir" rl76 --relaunch --harness claude); rc=$?
  expect_code 4 "$rc" "an env token without a matching recorded token must refuse"$'\n'"$out"
  assert_contains "$out" "--secondmate" \
    "a forged relaunch token must not skip the gone-secondmate owner"
  [ ! -s "$dir/fake/herdr-log" ] || ! grep -q "tab create" "$dir/fake/herdr-log" \
    || fail "a forged relaunch token must not mint a replacement pane"

  out=$(run_control "$dir" rl76 relaunch); rc=$?
  expect_code 4 "$rc" "same-pin fm-control relaunch of a gone secondmate stays with --secondmate"$'\n'"$out"
  assert_contains "$out" "--secondmate" \
    "same-pin gone-endpoint recovery is the respawn path"

  out=$(run_control "$dir" rl76 relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "fm-control relaunch --harness rebinds a gone secondmate endpoint"$'\n'"$out"$'\n'"$log"
  assert_contains "$log" "tab create" "a destroyed secondmate pane must be replaced"
  assert_not_contains "$out" "--secondmate" "a quota or operator replace uses fm-control relaunch, not a secondmate respawn"
  [ "$(meta_field "$dir" rl76 window)" = 'fmlab:%9' ] \
    || fail "the rebound secondmate endpoint should be the new pane, got $(meta_field "$dir" rl76 window)"
  [ "$(meta_field "$dir" rl76 backend)" = herdr ] \
    || fail "the recorded herdr backend must survive the replacement"

  pass "reclaim: fm-control relaunch rebinds a gone secondmate; direct --relaunch does not"
}

# Stopping a herdr secondmate's agent can take its pane with it. The control
# plane cannot launch a replacement into a pane that no longer exists, and the
# reclaim belongs to the secondmate respawn path, so a same-pin relaunch hands
# the mate over with a typed exit status and its prior record intact rather
# than a generic failure its restart caller cannot tell apart from a broken
# launch.
test_herdr_secondmate_relaunch_hands_a_vanished_pane_to_respawn() {
  local dir out rc=0 journal
  herdr_case_or_skip vanish-herdr-secondmate rl79 || {
    echo "skip - herdr secondmate relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  : > "$dir/fake/herdr-agent-live"
  : > "$dir/fake/herdr-exit-closes-pane"
  mkdir -p "$dir/home/config"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  printf '%s\n' "kind=secondmate" "home=$dir/wt" "x_request=keep-me" >> "$dir/home/state/rl79.meta"
  printf 'rl79\n' > "$dir/wt/.fm-secondmate-home"
  mkdir -p "$dir/wt/state" "$dir/wt/data"

  out=$(run_control "$dir" rl79 relaunch) || rc=$?

  expect_code 4 "$rc" "a vanished secondmate pane must be handed to the respawn path with its typed status"$'\n'"$out"
  assert_contains "$out" "bin/fm-spawn.sh rl79 --secondmate" \
    "the refusal must name the respawn path that now owns the mate"
  assert_contains "$(cat "$dir/fake/herdr-log")" "pane send-keys %7 enter --session fmlab" \
    "the agent must actually have been stopped before the hand-over"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "tab create" \
    "relaunch must not mint an endpoint the respawn path owns"
  [ "$(meta_field "$dir" rl79 kind)" = secondmate ] || fail "the hand-over lost the mate's record"
  [ "$(meta_field "$dir" rl79 backend)" = herdr ] \
    || fail "the respawn path needs the recorded backend the hand-over must keep"
  journal="$dir/home/state/rl79.control-relaunch"
  assert_grep 'rollback=prior-record-kept-endpoint-gone' "$journal" \
    "the relaunch journal must record why the prior record was kept"
  [ "$(meta_field "$dir" rl79 x_request)" = keep-me ] \
    || fail "clearing the owned relaunch token must keep unrelated metadata"
  [ -z "$(meta_field "$dir" rl79 control_relaunch_tx)" ] \
    || fail "a gone-endpoint handoff must clear the owned relaunch token"
  token=$(journal_field "$dir" rl79 relaunch_tx)
  [ -n "$token" ] || fail "the gone-endpoint journal should name the transaction that was cleared"
  rc=0
  out=$(FM_CONTROL_RELAUNCH_TX="$token" run_spawn "$dir" rl79 --relaunch --harness claude) || rc=$?
  expect_code 4 "$rc" "a leftover journal token must not authorize later direct relaunch"$'\n'"$out"
  assert_contains "$out" "--secondmate" \
    "a cleared token must still send a gone secondmate to --secondmate"
  [ ! -s "$dir/fake/herdr-log" ] || ! grep -q "tab create" "$dir/fake/herdr-log" \
    || fail "a leftover journal token must not mint a replacement pane"
  pass "relaunch: a herdr secondmate whose pane vanished on stop is handed to respawn with its record kept"
}

test_failed_spawn_keeps_exit_4_when_a_cooperating_writer_updates_meta() {
  local dir control_pid link_pid rc i=0 ready release journal
  herdr_case_or_skip vanish-xlink-secondmate x4sp || {
    echo "skip - herdr secondmate relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  : > "$dir/fake/herdr-agent-live"
  : > "$dir/fake/herdr-exit-closes-pane"
  mkdir -p "$dir/home/config"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  printf '%s\n' "kind=secondmate" "home=$dir/wt" >> "$dir/home/state/x4sp.meta"
  printf 'x4sp\n' > "$dir/wt/.fm-secondmate-home"
  mkdir -p "$dir/wt/state" "$dir/wt/data"
  if grep -q '^spawn_gen=' "$dir/home/state/x4sp.meta"; then
    fail "the gone-secondmate fixture must omit spawn_gen so a missing generation stays a non-publication"
  fi
  make_mktemp_spawn_err_failure_stub "$dir"
  ready="$dir/spawn-mktemp-ready"
  release="$dir/spawn-mktemp-release"
  FM_REAL_MKTEMP=$(command -v mktemp) \
    FM_FAKE_MKTEMP_SPAWN_PAUSE_READY="$ready" \
    FM_FAKE_MKTEMP_SPAWN_PAUSE_RELEASE="$release" \
    FM_FAKE_MKTEMP_SPAWN_CONTINUE=1 \
    run_control "$dir" x4sp relaunch > "$dir/control.out" &
  # shellcheck disable=SC2031 # pid of this background relaunch
  control_pid=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach spawn-output staging, so the writer never ran during a failing spawn"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MKTEMP="$(command -v mktemp)" \
    "$X_LINK" x4sp request-x4 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  # shellcheck disable=SC2031 # pid of this background X writer
  link_pid=$!
  i=0
  while [ "$(meta_field "$dir" x4sp x_request)" != request-x4 ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ "$(meta_field "$dir" x4sp x_request)" = request-x4 ] || {
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "cooperating writer did not publish before spawn"$'\n'"$(cat "$dir/link.out" 2>/dev/null || true)"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should succeed"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 4 "$rc" "a cooperating metadata update must not turn a gone-pane handoff into a generic failure"$'\n'"$(cat "$dir/control.out")"
  assert_contains "$(cat "$dir/control.out")" "bin/fm-spawn.sh x4sp --secondmate" \
    "the refusal must still name the respawn path"
  assert_not_contains "$(cat "$dir/control.out")" "was relaunched" \
    "rollback must not claim a spawn publication that did not happen"
  [ "$(meta_field "$dir" x4sp x_request)" = request-x4 ] \
    || fail "the gone-pane handoff erased the concurrent X request"
  [ "$(meta_field "$dir" x4sp x_followups)" = 1 ] \
    || fail "the gone-pane handoff erased the concurrent follow-up count"
  [ "$(meta_field "$dir" x4sp harness)" = claude ] \
    || fail "a failed unpublished spawn must keep the prior harness"
  [ -z "$(meta_field "$dir" x4sp spawn_gen)" ] \
    || fail "a failed unpublished spawn must not mint a new spawn_gen"
  [ -z "$(meta_field "$dir" x4sp control_relaunch_tx)" ] \
    || fail "a gone-endpoint handoff must clear the owned relaunch token after a cooperating write"
  journal="$dir/home/state/x4sp.control-relaunch"
  assert_grep 'rollback=prior-record-kept-endpoint-gone' "$journal" \
    "the journal must keep the gone-endpoint handoff, not none-new-record-kept"
  pass "relaunch: a cooperating metadata update during a failing spawn still hands a gone secondmate to respawn"
}

test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case reverify rl40)
  add_ship_task "$dir" rl40 claude
  seed_backlog "$dir" rl40 in_flight
  break_tasks_axi_start "$dir"

  out=$(run_control "$dir" rl40 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch must not re-run a transition the row already reflects"$'\n'"$out"
  [ "$(backlog_state "$dir" rl40)" = in_flight ] \
    || fail "a relaunch changed an already In-flight item to $(backlog_state "$dir" rl40)"
  pass "relaunch re-reads the backlog item instead of blindly re-running the transition"
}

test_relaunch_moves_a_drifted_item_back_in_flight() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case drifted rl41)
  add_ship_task "$dir" rl41 claude
  seed_backlog "$dir" rl41 queued

  out=$(run_control "$dir" rl41 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch onto a drifted item should succeed"$'\n'"$out"
  [ "$(backlog_state "$dir" rl41)" = in_flight ] \
    || fail "a relaunch left its item at $(backlog_state "$dir" rl41)"
  pass "relaunch heals an item that drifted out of In flight while the task stayed live"
}

test_away_branch_relaunch_accepts_existing_dispatchable_items() {
  local dir id out rc state
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }

  for state in in_flight queued; do
    id="rl-away-$state"
    dir=$(new_case "away-$state" "$id")
    add_ship_task "$dir" "$id" claude
    seed_backlog "$dir" "$id" "$state"
    FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
      || fail "away entry failed for a $state relaunch"

    rc=0
    out=$(FM_SUPERVISION_ACTOR=branch run_control "$dir" "$id" relaunch \
      --note "continue the existing task under away supervision") || rc=$?
    expect_code 0 "$rc" "the away branch must relaunch an existing $state item"$'\n'"$out"
    assert_contains "$out" "relaunched $id" \
      "the away branch did not complete the existing $state task's relaunch"
    [ "$(backlog_state "$dir" "$id")" = in_flight ] \
      || fail "the away branch left a relaunched $state item at $(backlog_state "$dir" "$id")"
  done
  pass "away supervision relaunches existing In-flight and queued items under the saturated fresh-spawn spend cap"
}

test_relaunch_keeps_a_held_in_flight_item_held() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case held-relaunch rl43)
  add_ship_task "$dir" rl43 claude
  seed_backlog "$dir" rl43 in_flight
  hold_backlog_item "$dir" rl43
  guard_tasks_axi_mutations "$dir"

  out=$(run_control "$dir" rl43 relaunch --note "replace the dead worker") || rc=$?
  expect_code 0 "$rc" "a relaunch of a held In-flight item must replace its worker"$'\n'"$out"
  assert_contains "$out" "relaunched rl43" "the held task's relaunch did not complete"
  [ "$(meta_field "$dir" rl43 worktree)" = "$dir/wt" ] \
    || fail "the held task's relaunch did not reuse its recorded local copy"
  [ "$(backlog_state "$dir" rl43)" = in_flight ] \
    || fail "a held relaunch moved its item to $(backlog_state "$dir" rl43)"
  [ "$(backlog_field "$dir" rl43 held)" = yes ] \
    || fail "a relaunch released the item's hold"
  [ "$(backlog_field "$dir" rl43 hold_kind)" = captain ] \
    || fail "a relaunch changed the hold kind to $(backlog_field "$dir" rl43 hold_kind)"
  [ "$(backlog_field "$dir" rl43 hold_reason)" = "captain owns publication and merge" ] \
    || fail "a relaunch changed the hold reason to $(backlog_field "$dir" rl43 hold_reason)"
  [ ! -s "$dir/fake/tasks-axi-mutations" ] \
    || fail "a held relaunch ran backlog mutations: $(tr '\n' ' ' < "$dir/fake/tasks-axi-mutations")"
  pass "relaunch replaces the worker of a held In-flight item and leaves the hold in force"
}

test_spawn_relaunch_admits_a_held_in_flight_item_with_a_dead_agent() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case held-spawn-relaunch rl44)
  add_ship_task "$dir" rl44 claude
  seed_backlog "$dir" rl44 in_flight
  hold_backlog_item "$dir" rl44
  guard_tasks_axi_mutations "$dir"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl44 --relaunch) || rc=$?
  expect_code 0 "$rc" "fm-spawn --relaunch must admit a held In-flight item"$'\n'"$out"
  assert_contains "$out" "spawned rl44" "the held task's replacement was not launched"
  assert_contains "$out" "worktree=$dir/wt" "the replacement did not reuse the recorded local copy"
  [ "$(backlog_state "$dir" rl44)" = in_flight ] && [ "$(backlog_field "$dir" rl44 held)" = yes ] \
    || fail "fm-spawn --relaunch changed the held item to $(backlog_state "$dir" rl44) held=$(backlog_field "$dir" rl44 held)"
  [ ! -s "$dir/fake/tasks-axi-mutations" ] \
    || fail "fm-spawn --relaunch ran backlog mutations: $(tr '\n' ' ' < "$dir/fake/tasks-axi-mutations")"
  pass "fm-spawn --relaunch replaces a stopped worker of a held In-flight item without touching the hold"
}

test_relaunch_refuses_a_held_queued_item_before_stopping_the_agent() {
  local dir out rc=0 before after
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case held-queued-relaunch rl45)
  add_ship_task "$dir" rl45 claude
  seed_backlog "$dir" rl45 queued
  hold_backlog_item "$dir" rl45
  before=$(cat "$dir/home/state/rl45.meta")

  out=$(run_control "$dir" rl45 relaunch --note "replace the worker") || rc=$?
  expect_code 1 "$rc" "a relaunch of a held Queued item must refuse"$'\n'"$out"
  assert_contains "$out" "state queued yes no" "the refusal did not name the row's actual state"
  assert_contains "$out" "the running agent was not touched" "the refusal did not happen before the agent stopped"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused held relaunch stopped the running agent"
  after=$(cat "$dir/home/state/rl45.meta")
  [ "$before" = "$after" ] || fail "a refused held relaunch changed the durable record"
  [ "$(backlog_state "$dir" rl45)" = queued ] && [ "$(backlog_field "$dir" rl45 held)" = yes ] \
    || fail "a refused held relaunch changed the item to $(backlog_state "$dir" rl45) held=$(backlog_field "$dir" rl45 held)"
  pass "relaunch refuses a held Queued item before the running agent is touched"
}
test_exit_and_relaunch_remove_the_dialog_file() {
  local dir out rc
  dir=$(new_case dialog-file-exit rl70)
  add_ship_task "$dir" rl70 claude
  out=$(run_control "$dir" rl70 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl70.composer-dialog" ] \
    || fail "exit should remove the dialog file"

  dir=$(new_case dialog-file-relaunch rl71)
  add_ship_task "$dir" rl71 claude
  out=$(run_control "$dir" rl71 relaunch --note "replace the agent"); rc=$?
  expect_code 0 "$rc" "relaunch should replace the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl71.composer-dialog" ] \
    || fail "relaunch should remove the dialog file"
  pass "fm-control removes the dialog file after exit and after relaunch"
}

# The lock release removes paths at or under the control lock with rm, so a
# recording rm sees the state directory at the moment of release without a
# second overlapping command.
test_exit_removes_the_dialog_file_before_releasing_the_lock() {
  local dir out rc lock sink trace
  dir=$(new_case dialog-file-order rl72)
  add_ship_task "$dir" rl72 claude
  lock="$dir/home/state/.control-rl72.lock"
  sink="$dir/home/state/rl72.composer-dialog"
  trace="$dir/fake/rm-trace"
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$lock"|"$lock"/*)
      if [ -e "$sink" ]; then echo present; else echo absent; fi >> "$trace"
      break
      ;;
  esac
done
exec "$(command -v rm)" "\$@"
SH
  chmod +x "$dir/fakebin/rm"
  out=$(run_control "$dir" rl72 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$lock" ] || fail "exit should release the control lock"
  [ "$(tail -n 1 "$trace" 2>/dev/null)" = absent ] \
    || fail "the dialog file must be gone when the control lock is released, got: $(cat "$trace" 2>/dev/null)"
  pass "fm-control exit removes the dialog file before it releases the control lock"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi
test_relaunch_off_opencode_removes_tracked_wiring
test_exit_and_relaunch_remove_the_dialog_file
test_exit_removes_the_dialog_file_before_releasing_the_lock
test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_pooled_relaunch_custody_is_agy_only
test_agy_relaunch_requires_treehouse_capabilities_before_stopping
test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text
test_relaunch_does_not_kill_an_untrusted_usage_limit_endpoint
test_relaunch_refuses_an_unverified_pane_text_usage_limit
test_relaunch_closes_a_grok_weekly_limit_composer_without_typing_enter
test_busy_relaunch_closes_a_grok_weekly_limit_after_interrupt
test_busy_relaunch_refuses_pane_text_usage_limit_after_interrupt
test_interrupt_refuses_a_usage_limit_screen
test_interrupt_refuses_a_grok_weekly_limit_and_names_relaunch
test_control_relaunch_of_a_gone_tmux_endpoint
test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven
test_relaunch_refuses_before_exit_when_the_composer_is_not_proven_empty
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_traced_relaunch_keeps_an_armed_pr_poll_authenticated
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_note_inbox_listing_is_safe_on_empty_inbox
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_refused_relaunch_onto_polytoken_keeps_the_project_hook_layer
test_refused_polytoken_profile_leaves_the_running_agent
test_relaunch_from_a_raw_polytoken_launch_keeps_the_project_layers
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_falls_back_when_the_new_harness_refuses_carried_effort
test_relaunch_off_claude_refuses_when_tooling_is_present
test_relaunch_off_claude_refuses_an_unreadable_account_pin
test_relaunch_off_claude_refuses_when_tooling_check_exits_2
test_relaunch_off_claude_ignores_fm_quota_reroute_override
test_relaunch_off_claude_allows_an_unchanged_seeded_home
test_relaunch_off_claude_refuses_seeded_home_user_additions
test_relaunch_off_claude_refuses_seeded_home_committed_file_and_symlinked_root
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop
test_codex_max_relaunch_rejects_unadvertised_model_before_stop
test_signed_out_worker_account_pin_refuses_before_stop
test_worker_account_pin_follows_the_relaunch
test_account_list_relaunch_reuses_the_recorded_account
test_account_list_relaunch_moves_only_on_explicit_account
test_account_list_relaunch_refusals_happen_before_stop
test_secondmate_account_pin_follows_relaunch_and_refuses_before_stop
test_pi_exclude_tools_follow_the_relaunch
test_exclude_tools_refusals_happen_before_the_agent_stops
test_explicit_model_wins_over_the_recorded_one
test_relaunch_onto_an_unverified_harness_is_refused
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_claude_relaunch_keeps_local_settings
test_secondmate_relaunch_lands_on_the_per_mate_pin
test_secondmate_relaunch_uses_the_default_for_an_unpinned_mate
test_secondmate_relaunch_with_a_legacy_pin_file_uses_the_first_line
test_secondmate_relaunch_refuses_an_unreadable_configured_pin_before_stop
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch
test_spawn_relaunch_resyncs_the_recorded_branch_to_its_published_head
test_spawn_relaunch_under_an_active_run_is_monitoring_only
test_spawn_relaunch_keeps_a_clean_local_ahead_commit
test_spawn_relaunch_origin_probe_timeout_refuses
test_spawn_relaunch_of_a_successor_ignores_its_source_line
test_promoted_scout_relaunch_receives_the_current_delivery_contract
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_missing_worktree_refuses_before_stopping_anything
test_relaunch_refuses_a_recorded_worktree_that_is_the_primary_home
test_relaunch_refuses_a_recorded_worktree_that_is_the_project_primary_checkout
test_relaunch_refuses_the_primary_checkout_under_inherited_git_overrides
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_prepublication_abort_with_busy_gen_restores_the_prior_record
test_unpublished_spawn_lock_failure_is_not_published
test_stamp_die_before_spawn_restores_the_prior_record
test_stamp_mv_failure_removes_the_staging_file
test_restore_failure_is_journaled_as_restore_failed
test_stamp_serializes_a_cooperating_metadata_writer
test_restore_preserves_a_cooperating_metadata_update
test_journal_records_the_checkpoint_it_proved
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_spawn_relaunch_refuses_a_live_agent
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_keeps_its_early_meta_lock_continuous
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_herdr_relaunch_refuses_when_cd_does_not_return_to_the_worktree
test_tmux_refuses_a_window_missing_from_its_session
test_tmux_refuses_a_session_that_cannot_be_found
test_tmux_refuses_when_the_server_is_gone
test_tmux_reclaims_a_lost_server_from_its_record
test_reclaim_refuses_an_unreadable_endpoint
test_herdr_relaunch_resumes_only_the_registered_pi_session
test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
test_herdr_exit_proves_the_post_command_endpoint_state
test_herdr_rebind_stays_in_the_recorded_session
test_herdr_reclaim_refuses_an_agent_that_came_back
test_herdr_reclaim_keeps_the_task_whole
test_herdr_reclaim_of_a_secondmate_uses_relaunch
test_herdr_secondmate_relaunch_hands_a_vanished_pane_to_respawn
test_failed_spawn_keeps_exit_4_when_a_cooperating_writer_updates_meta
test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause
test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it
test_relaunch_moves_a_drifted_item_back_in_flight
test_away_branch_relaunch_accepts_existing_dispatchable_items
test_relaunch_keeps_a_held_in_flight_item_held
test_spawn_relaunch_admits_a_held_in_flight_item_with_a_dead_agent
test_relaunch_refuses_a_held_queued_item_before_stopping_the_agent
