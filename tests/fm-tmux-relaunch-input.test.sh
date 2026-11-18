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
: > "$TMP/zdot/.zshrc"
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

wait_child_zsh() {
  local parent=$1 i child
  for ((i = 0; i < 60; i++)); do
    child=$(pgrep -P "$parent" -x zsh | head -1)
    if [ -n "$child" ]; then printf '%s\n' "$child"; return 0; fi
    sleep 0.1
  done
  return 1
}

# A nested zsh has the same executable name as the original pane shell. Its
# different foreground process group must prevent cleanup and launch input.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'zsh -f'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
CHILD_ZSH=$(wait_child_zsh "$PANE_PID") || fail 'nested zsh did not start'
SHELL=/bin/bash fm_backend_tmux_prepare_relaunch "$TARGET" > "$TMP/same-name-guard.out" 2>&1 &
GUARD_PID=$!
sleep 0.4
kill -0 "$GUARD_PID" 2>/dev/null || fail 'guard accepted a foreground child zsh'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'exit'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
wait "$GUARD_PID" || fail 'guard did not continue after nested zsh exited'
printf 'ok - foreground child with the same executable name is not accepted\n'

# A child that never exits must be refused within the ten-second wall clock
# bound. The guard must leave the child running and must never type a launch.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'zsh -f'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
CHILD_ZSH=$(wait_child_zsh "$PANE_PID") || fail 'timeout fixture zsh did not start'
START=$(date +%s)
if fm_backend_tmux_prepare_relaunch "$TARGET" > "$TMP/timeout-guard.out" 2>&1; then
  fail 'guard accepted a still-running foreground child'
fi
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -ge 9 ] && [ "$ELAPSED" -le 11 ] || fail "guard took ${ELAPSED}s instead of about 10s"
kill -0 "$CHILD_ZSH" 2>/dev/null || fail 'guard stopped the foreground child'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'exit'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
printf 'ok - foreground timeout is bounded by the wall clock\n'

# The pane's top process may be a wrapper that keeps a child login shell.
REAL_ZSH=$(command -v zsh)
cat > "$TMP/wrapper" <<SH
#!/bin/bash
"$REAL_ZSH" -f
wait
SH
chmod +x "$TMP/wrapper"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n wrapped "/bin/bash -e $TMP/wrapper" || fail 'wrapper window did not start'
TARGET=repro:wrapped
WRAPPER_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')
wait_child_zsh "$WRAPPER_PID" >/dev/null || fail 'wrapper child shell did not start'
( unset SHELL; fm_backend_tmux_prepare_relaunch "$TARGET" ) || fail 'wrapper top process prevented shell relaunch'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' wrapped-shell"
wait_for 'result:wrapped-shell' || fail 'replacement was not delivered to wrapper child shell'
printf 'ok - wrapper top process is accepted when its shell is foreground\n'

# Without job control a child can share the shell's pgid. In that case the
# guard must still see the live child and refuse the launch.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n nojob || fail 'no-job-control window did not start'
TARGET=repro:nojob
NOJOB_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'unsetopt monitor'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'sleep 60'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
NOJOB_CHILD=$(wait_child "$NOJOB_PID") || fail 'no-job-control child did not start'
SHELL_GROUP=$(ps -p "$NOJOB_PID" -o pgid=)
CHILD_GROUP=$(ps -p "$NOJOB_CHILD" -o pgid=)
[ "$SHELL_GROUP" = "$CHILD_GROUP" ] || fail 'fixture child did not share the shell process group'
if fm_backend_tmux_prepare_relaunch "$TARGET" no-wait > "$TMP/nojob-guard.out" 2>&1; then
  fail 'guard accepted a same-group foreground child'
fi
kill -TERM "$NOJOB_CHILD" 2>/dev/null || fail 'no-job-control child could not be stopped'
printf 'ok - same-group child without job control is refused\n'

# A custom ^U binding must fail closed instead of swallowing the replacement
# command behind input that C-u did not remove.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n rebound "$REAL_ZSH" -f || fail 'custom binding window did not start'
TARGET=repro:rebound
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "bindkey '^U' self-insert"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'stale-input'
if fm_backend_tmux_prepare_relaunch "$TARGET" > "$TMP/rebound-guard.out" 2>&1; then
  fail 'guard accepted a custom ^U binding that did not clear input'
fi
grep -q 'did not clear relaunch input' "$TMP/rebound-guard.out" || fail 'custom binding refusal lacked a clear reason'
printf 'ok - custom ^U binding refuses replacement input\n'

# A ^U binding that submits the line must not execute old input. Interrupt
# the shell directly before sending line-editor keys. The guard must refuse:
# accepting the probe with accept-line is not proof that the editor is clear.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n submit || fail 'submit-binding window did not start'
TARGET=repro:submit
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "bindkey '^U' accept-line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l ": > '$TMP/stale-executed'"
if fm_backend_tmux_prepare_relaunch "$TARGET" > "$TMP/submit-guard.out" 2>&1; then
  fail 'guard accepted a ^U accept-line binding that submits instead of clearing'
fi
[ ! -e "$TMP/stale-executed" ] || fail 'custom ^U submitted stale input before guard refusal'
printf 'ok - custom ^U accept-line binding cannot submit stale input\n'

# wait-only must not type, so leftover editor text is a refusal.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n waitonly || fail 'wait-only window did not start'
TARGET=repro:waitonly
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'leftover-wait-only'
if fm_backend_tmux_prepare_relaunch "$TARGET" wait-only > "$TMP/waitonly-guard.out" 2>&1; then
  fail 'wait-only accepted leftover typed input'
fi
printf 'ok - wait-only refuses leftover typed input\n'

"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n waitclean || fail 'clean wait-only window did not start'
TARGET=repro:waitclean
fm_backend_tmux_prepare_relaunch "$TARGET" wait-only || fail 'wait-only refused a clean prompt'
printf 'ok - wait-only accepts a clean prompt without typing\n'

# An 80-column pane with a long prompt wraps the SIGINT probe with real
# newlines. capture-pane -p -J does not join those, so probe detection must
# still see the marker.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n wrap80 || fail 'wrap window did not start'
TARGET=repro:wrap80
"$REAL_TMUX" -L "$SOCKET" resize-window -t "$TARGET" -x 80 -y 24 || fail 'wrap window could not be resized to 80 columns'
WRAP_WIDTH=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_width}')
[ "$WRAP_WIDTH" = 80 ] || fail "wrap pane width is ${WRAP_WIDTH}, not 80"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "PROMPT='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 %# '"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.3
fm_backend_tmux_prepare_relaunch "$TARGET" || fail 'wrapped SIGINT probe was treated as missing'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' wrap-ok"
wait_for 'result:wrap-ok' || fail 'wrapped-prompt pane did not accept replacement input'
printf 'ok - wrapped SIGINT probe is still detected in an 80-column pane\n'

# A non-shell sibling listed before the child zsh must not stop the walk.
cat > "$TMP/sibling-wrapper" <<SH
#!/bin/bash
sleep 60 &
"$REAL_ZSH" -f
wait
SH
chmod +x "$TMP/sibling-wrapper"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n sibling "/bin/bash -e $TMP/sibling-wrapper" || fail 'sibling-wrapper window did not start'
TARGET=repro:sibling
WRAPPER_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')
wait_child_zsh "$WRAPPER_PID" >/dev/null || fail 'sibling-wrapper child shell did not start'
SIBLING_SLEEP=$(pgrep -P "$WRAPPER_PID" -x sleep | head -1)
[ -n "$SIBLING_SLEEP" ] || fail 'sibling-wrapper sleep child did not start'
[ "$SIBLING_SLEEP" -lt "$(pgrep -P "$WRAPPER_PID" -x zsh | head -1)" ] || fail 'fixture sleep was not listed before zsh'
( unset SHELL; fm_backend_tmux_prepare_relaunch "$TARGET" ) || fail 'non-shell sibling prevented finding the child zsh'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' sibling-ok"
wait_for 'result:sibling-ok' || fail 'replacement was not delivered past a non-shell sibling'
printf 'ok - non-shell sibling does not stop the wrapper child walk\n'

# Linux ps truncates comm to 15 characters, so the advertised wrapper name
# never matches. The truncated form must still be a wrapper.
(
  ps() {
    case "$*" in
      '-p 129 -o comm=') printf 'reattach-to-use\n' ;;
      '-ww -p 129 -o args=') printf 'reattach-to-user-namespace\n' ;;
      *) return 1 ;;
    esac
  }
  fm_backend_tmux_interactive_shell 129
  [ "$?" -eq 1 ]
) || fail 'truncated reattach-to-user-namespace comm was not treated as a wrapper'
printf 'ok - truncated reattach-to-user-namespace comm is a wrapper\n'

# Bash's Terminated notice must refuse when C-l cannot redraw it away.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n bashterm '/bin/bash --norc --noprofile -i' || fail 'bash terminated-notice window did not start'
TARGET=repro:bashterm
BASH_TERM_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "bind '\"\\C-l\":'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "env -u CURSOR_AGENT /bin/sh -c 'sleep 60'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
BASH_CHILD=$(wait_child "$BASH_TERM_PID")
[ -n "$BASH_CHILD" ] || fail 'bash fixture agent did not start'
kill -TERM "$BASH_CHILD" 2>/dev/null || fail 'could not stop bash fixture agent'
wait_for 'Terminated' || fail 'bash fixture did not reproduce the Terminated notice'
if fm_backend_tmux_prepare_relaunch "$TARGET" > "$TMP/bash-term-guard.out" 2>&1; then
  fail 'guard accepted a bash pane that still shows Terminated'
fi
printf 'ok - bash Terminated notice refuses when C-l is a no-op\n'

# A stalled ps/tmux/pgrep call must be killed by the 10s bound, and a stuck
# wall clock must not make the wait unbounded.
mkdir -p "$TMP/hangbin"
cat > "$TMP/hangbin/ps" <<'SH'
#!/usr/bin/env bash
sleep 20
printf '1\n'
SH
chmod +x "$TMP/hangbin/ps"
run_stalled_ps_probe() {
  PATH="$TMP/hangbin:$PATH"
  start=$SECONDS
  fm_backend_tmux_shell_is_foreground 1 1 &
  probe=$!
  while kill -0 "$probe" 2>/dev/null && [ $((SECONDS - start)) -lt 15 ]; do sleep 0.1; done
  if kill -0 "$probe" 2>/dev/null; then
    kill "$probe" 2>/dev/null || true
    wait "$probe" 2>/dev/null || true
    return 1
  fi
  wait "$probe"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -ge 9 ] && [ "$elapsed" -le 12 ]
}
( run_stalled_ps_probe ) || fail 'stalled ps was not killed by the relaunch 10s bound'
printf 'ok - stalled process-group probe is killed within 10s\n'

mkdir -p "$TMP/zerops"
cat > "$TMP/zerops/ps" <<'SH'
#!/usr/bin/env bash
printf '0\n'
SH
chmod +x "$TMP/zerops/ps"
run_monotonic_wait() {
  PATH="$TMP/zerops:$PATH"
  date() { echo 1; }
  date +%s >/dev/null
  start=$SECONDS
  fm_backend_tmux_wait_for_foreground 1 1 $((SECONDS + 10)) &
  probe=$!
  while kill -0 "$probe" 2>/dev/null && [ $((SECONDS - start)) -lt 15 ]; do sleep 0.1; done
  if kill -0 "$probe" 2>/dev/null; then
    kill "$probe" 2>/dev/null || true
    wait "$probe" 2>/dev/null || true
    return 1
  fi
  wait "$probe"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -ge 9 ] && [ "$elapsed" -le 12 ]
}
( run_monotonic_wait ) || fail 'backward date +%s made the foreground wait unbounded'
printf 'ok - foreground wait uses monotonic elapsed time\n'

# Input to the right of the cursor must also be removed before launch text.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n cursorleft || fail 'cursor-left window did not start'
TARGET=repro:cursorleft
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'stale-input'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-b C-b C-b
fm_backend_tmux_prepare_relaunch "$TARGET" || fail 'cursor-left input could not be cleaned'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' cursor-clean"
wait_for 'result:cursor-clean' || fail 'cursor-left stale input corrupted replacement command'
printf 'ok - cursor-left stale input is removed before replacement\n'

# Startup options for an interactive shell must not be mistaken for a script
# or -c wrapper.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n bashopts '/bin/bash --norc --noprofile --posix -i' || fail 'bash options window did not start'
TARGET=repro:bashopts
fm_backend_tmux_prepare_relaunch "$TARGET" || fail 'interactive bash startup options were refused'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' bash-options"
wait_for 'result:bash-options' || fail 'replacement did not reach bash with startup options'
printf 'ok - interactive bash startup options are accepted\n'

"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n bashstdin '/bin/bash -is' || fail 'interactive stdin-shell window did not start'
TARGET=repro:bashstdin
BASH_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/bin/bash -i'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
for ((i = 0; i < 60; i++)); do
  NESTED_BASH=$(pgrep -P "$BASH_PID" -x bash | head -1)
  [ -z "$NESTED_BASH" ] || break
  sleep 0.1
done
[ -n "${NESTED_BASH:-}" ] || fail 'nested bash did not start'
if fm_backend_tmux_prepare_relaunch "$TARGET" no-wait > "$TMP/bashstdin-guard.out" 2>&1; then
  fail 'interactive bash -is pane selected its foreground child instead'
fi
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'exit'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
printf 'ok - interactive bash -is pane does not select a nested shell\n'

# Prompt hooks can briefly run a child after each SIGINT. The final guard
# waits for the prompt to settle within its deadline.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n slowprompt || fail 'slow-prompt window did not start'
TARGET=repro:slowprompt
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'precmd() { sleep 0.3; }'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.5
fm_backend_tmux_prepare_relaunch "$TARGET" no-wait || fail 'prompt hook prevented a settled relaunch'
fm_backend_tmux_send_text_line "$TARGET" "printf 'result:%s\\n' slow-prompt"
wait_for 'result:slow-prompt' || fail 'replacement did not reach shell with a prompt hook'
printf 'ok - prompt hook settles before final relaunch delivery\n'

"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n clockprompt || fail 'clock-prompt window did not start'
TARGET=repro:clockprompt
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "PROMPT='[%*] %# '"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2
fm_backend_tmux_prepare_relaunch "$TARGET" no-wait || fail 'changing clock prompt was refused'
printf 'ok - clock prompt redraw keeps the input check valid\n'

# ps flattens argv, so an rcfile path with spaces must stay ambiguous rather
# than turning a nested Bash into the pane's original shell.
mkdir "$TMP/rc dir" || fail 'rcfile fixture directory could not be created'
: > "$TMP/rc dir/rc"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t repro: -n ambiguous "/bin/bash --rcfile '$TMP/rc dir/rc' -i" || fail 'ambiguous shell window did not start'
TARGET=repro:ambiguous
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/bin/bash -i'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2
if fm_backend_tmux_prepare_relaunch "$TARGET" no-wait > "$TMP/ambiguous-guard.out" 2>&1; then
  fail 'flattened rcfile argv selected a nested shell'
fi
printf 'ok - ambiguous shell argv refuses instead of selecting a child\n'

# ps flattens argv[0] too. A process name with spaces cannot establish the
# identity of the pane's original shell.
(
  ps() {
    case "$*" in
      '-p 123 -o comm=') printf 'zsh\n' ;;
      '-ww -p 123 -o args=') printf 'my zsh -f\n' ;;
      '-p 124 -o comm=') printf 'bash\n' ;;
      '-ww -p 124 -o args=') printf 'bash --init-file /tmp/rc -i\n' ;;
      '-p 125 -o comm=') printf 'bash\n' ;;
      '-ww -p 125 -o args=') printf 'bash -is foo\n' ;;
      '-p 126 -o comm=') printf 'zsh\n' ;;
      '-ww -p 126 -o args=') printf 'zsh +o vi\n' ;;
      '-p 127 -o comm=') printf 'fish\n' ;;
      '-ww -p 127 -o args=') printf 'fish -C source\n' ;;
      '-p 128 -o comm=') printf 'bash\n' ;;
      '-ww -p 128 -o args=') printf 'bash -iO extglob\n' ;;
      *) return 1 ;;
    esac
  }
  fm_backend_tmux_interactive_shell 123
  [ "$?" -eq 2 ] || exit 1
  fm_backend_tmux_interactive_shell 124
  [ "$?" -eq 2 ] || exit 1
  fm_backend_tmux_interactive_shell 125
  [ "$?" -eq 2 ] || exit 1
  fm_backend_tmux_interactive_shell 126
  [ "$?" -eq 2 ] || exit 1
  fm_backend_tmux_interactive_shell 127
  [ "$?" -eq 2 ] || exit 1
  fm_backend_tmux_interactive_shell 128
  [ "$?" -eq 2 ]
) || fail 'flattened shell argv was not treated as ambiguous'
printf 'ok - ambiguous shell argv[0] and option values refuse child selection\n'

bash "$ROOT/tests/fm-control-relaunch.test.sh" test_tmux_guard_refusal_preserves_relaunch_record test_tmux_late_guard_refusal_restores_relaunch_record test_tmux_late_guard_signal_keeps_stop_marker \
  || fail 'guard refusal changed the relaunch record'
