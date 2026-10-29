#!/usr/bin/env bash
# Shared fixtures for the steering-inbox suites, tests/fm-task-inbox.test.sh and
# tests/fm-watch-inbox-recovery.test.sh: the library runner, the fake tmux, and
# the watcher case setup both drive bin/fm-watch.sh through. The sourcing suite
# sources tests/wake-helpers.sh first and sets TMP_ROOT and WATCH.

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row, and every literal send-keys is
# logged to FM_SEND_LOG so a doorbell ring is observable. With
# FM_FAKE_TMUX_AGENT set, the inventory lists window fm-t1 and its
# #{pane_current_command} answers with that value, so `zsh` makes
# fm_backend_tmux_agent_state read the pane as a dead bare shell.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    if [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ]; then
      printf 'send failed\n' >> "${FM_SEND_LOG:-/dev/null}"
      exit 1
    fi
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
      # A concurrent fire-and-forget send marking its newer record mid-ring.
      if [ -n "${FM_RING_MARKS_RETRY:-}" ]; then
        printf '%s\n' "${FM_RING_MARKS_RETRY##*/}" > "${FM_RING_MARKS_RETRY%/*}/.retry-ring"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
        *pane_tty*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '\n'; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  printf '%s\n' "$dir"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

# A fresh process for each check proves the busy budget survives watcher restarts.
busy_steer_check() {  # <case-dir> [capture] [busy-max]
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_SEND_LOG="$1/send.log" \
    FM_FAKE_TMUX_CAPTURE="${2:-$1/busy.capture}" FM_BUSY_REGEX=BUSYTOKEN \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX="${3-2}" \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" > "$1/check.out" 2>&1
}

busy_case() {
  local dir rec
  dir=$(setup_watch_case "$1")
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  age_path "$rec"
  printf '%s' "$dir"
}
