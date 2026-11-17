#!/usr/bin/env bash
# Exercise the relaunch handoff in an isolated real tmux pane with a login zsh.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'skip: tmux unavailable'; exit 0; }
command -v zsh >/dev/null 2>&1 || { echo 'skip: zsh unavailable'; exit 0; }
REAL_TMUX=$(command -v tmux)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-relaunch.XXXXXX") || exit 1
SOCKET="fm-relaunch-input-$$"
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
cat > "$TMP/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$TMP/tmux"
PATH="$TMP:$PATH"
export PATH
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || exit 1
mkdir "$TMP/zdot" || exit 1
ZDOTDIR="$TMP/zdot" SHELL=$(command -v zsh) "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -s repro -x 180 -y 40 || exit 1
TARGET=repro:0
PANE_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')

fail() {
  printf 'not ok - %s\n' "$1" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -0 >&2 || true
  exit 1
}
wait_for() {
  local wanted=$1 i output
  for ((i = 0; i < 60; i++)); do
    output=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -0)
    case "$output" in *"$wanted"*) return 0 ;; esac
    sleep 0.1
  done
  return 1
}
wait_child() {
  local parent=$1 i child
  for ((i = 0; i < 60; i++)); do
    child=$(pgrep -P "$parent" -f 'sleep 60' | head -1)
    if [ -n "$child" ]; then printf '%s\n' "$child"; return 0; fi
    sleep 0.1
  done
  return 1
}

# SIGTERM on the pane's foreground agent produces zsh's notice.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "env -u CURSOR_AGENT /bin/sh -c 'sleep 60'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
OLD_PID=$(wait_child "$PANE_PID")
[ -n "$OLD_PID" ] || fail 'fixture agent did not start'
kill -TERM "$OLD_PID" 2>/dev/null || fail 'could not stop fixture agent'
wait_for 'zsh: terminated' || fail 'fixture did not reproduce the termination notice'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'stale-input'
fm_backend_tmux_prepare_relaunch "$TARGET" || fail 'relaunch did not wait for shell and clear its input'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' replacement-ready" || fail 'replacement command could not be sent'
wait_for 'result:replacement-ready' || fail 'replacement command did not execute'
VISIBLE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -0)
case "$VISIBLE" in
  *'zsh: terminated'*|*'stale-input'*) fail 'old notice or input remained visible after relaunch preparation' ;;
esac
printf 'ok - relaunch waits for zsh and clears the old input and notice\n'

# Preparation must wait while the old foreground process is still running.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/bin/sh -c 'sleep 60'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
WAIT_PID=$(wait_child "$PANE_PID")
[ -n "$WAIT_PID" ] || fail 'second fixture agent did not start'
( sleep 0.4; kill -TERM "$WAIT_PID" 2>/dev/null ) &
KILLER=$!
fm_backend_tmux_prepare_relaunch "$TARGET" || fail 'preparation returned before the old agent exited'
! kill -0 "$WAIT_PID" 2>/dev/null || fail 'preparation returned while the old agent was still running'
wait "$KILLER" || fail 'delayed fixture stop failed'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "printf 'result:%s\\n' waited-for-exit"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait_for 'result:waited-for-exit' || fail 'replacement did not run after waiting for the old agent'
printf 'ok - relaunch preparation waits for foreground exit\n'
