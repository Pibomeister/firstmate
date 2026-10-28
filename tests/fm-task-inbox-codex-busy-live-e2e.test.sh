#!/usr/bin/env bash
# tests/fm-task-inbox-codex-busy-live-e2e.test.sh - the live guard for the
# steering-inbox doorbell on a busy Codex (live-harness-optin family).
#
# bin/fm-task-inbox-lib.sh submits a composer that holds only whole copies of
# our own doorbell line, and on a task whose record harness is codex it does
# so while the agent is busy, because a busy Codex takes that Enter as a
# mid-turn steer. That is a key the vendor binds, so per
# .agents/skills/firstmate-coding-guidelines the stub in
# tests/fm-task-inbox.test.sh is not enough: this guard launches the INSTALLED
# codex in an isolated tmux server, has it start a long tool loop, waits until
# that loop's process is running, leaves one copy of the doorbell line in the
# composer without Enter, and calls fm_task_inbox_ring on that pane. It
# requires ring status 0 and the doorbell to reach the model inside the
# running turn.
#
# The proof is the Codex session rollout, the most structural record of what
# the model received. Codex writes it under the operator's own Codex home,
# which this guard never copies or changes, so the rollout is found by its
# content rather than by a private location: the session file written since
# this run started that holds this run's unique lab path, which only the
# prompt names. The doorbell, which names this run's unique task inbox, must
# appear there as a user message before the first task_complete event of the
# prompt's turn; a queued message that only starts a later turn appears after
# it and fails. The busy proof is the loop's own process writing its start
# marker and not yet its done marker. On tmux the backend busy read for Codex
# is unknown, so the ring takes the ownership-proven submit path; what this
# guard pins is the vendor binding the busy branch relies on.
#
# A second surface pins the payload bin/fm-secondmate-inbox-guard.sh reads:
# one non-interactive `codex exec` in the repository root, with hooks on, runs
# a shell command through this checkout's existing PreToolUse registration in
# .codex/hooks.json, and bin/fm-arm-pretool-check.sh's capture switch
# (FM_PRETOOL_PAYLOAD_KEYS_FILE) records only that payload's top-level key
# names, never a value. It requires tool_input, session_id and turn_id. The
# guard never grants or bypasses hook trust: an untrusted registration runs no
# hook, records nothing and fails the surface.
#
# The guard submits prompts and spends model tokens, so it is opt-in
# (fm_live_gate): FM_TASK_INBOX_CODEX_BUSY_LIVE=1 or FM_LIVE=1 runs it, and an
# absent codex then fails rather than skips. It fails naming codex and
# `codex --version`, and refuses a pass that checked nothing. Refresh
# docs/verification/runtime-backends.md ("Steering-inbox doorbell on a busy
# Codex") from its output after any codex upgrade.
#
# Codex runs as the operator's own login and configuration: nothing is copied
# into or out of the operator's Codex home and no Codex daemon is stopped;
# cleanup kills only the private tmux server and removes the lab. It launches
# the way tests/fm-send-inbox-doorbell-live-e2e.test.sh launches codex, with
# approvals and the sandbox bypassed so the lab's tool loop needs no prompt,
# and with --disable hooks so no hook-trust modal opens and no project hook
# runs. Folder trust: it starts in the repository root, which the operator's
# machine has normally already trusted; a trust dialog fails the guard rather
# than being accepted, because accepting it would write the operator's Codex
# configuration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_TASK_INBOX_CODEX_BUSY_LIVE codex tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOCKET="fm-codex-busy-$$"
SESSION="codexbusy"
WIN="codex"
TARGET="$SESSION:$WIN"
CHECKED=0
SESSIONS="${CODEX_HOME:-$HOME/.codex}/sessions"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-busy-live.XXXXXX") || exit 1
LAB=$(cd "$LAB" && pwd -P)
TASK="codex-busy-${LAB##*.}"
REAL_TMUX=$(command -v tmux)

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

VERSION=$(codex --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
mkdir -p "$LAB/shim" "$LAB/state"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

# The tool loop's own process proves the turn is busy: it writes the start
# marker when it begins and the done marker only when it ends, both in the lab.
cat > "$LAB/busy-loop.sh" <<SH
#!/usr/bin/env bash
: > "$LAB/loop.started"
i=0
while [ "\$i" -lt 60 ]; do echo "tick \$i"; sleep 1; i=\$((i + 1)); done
: > "$LAB/loop.done"
SH
chmod +x "$LAB/busy-loop.sh"

printf 'harness=codex\n' > "$LAB/state/$TASK.meta"
REC=$(fm_task_inbox_write "$LAB/state" "$TASK" "live busy-codex doorbell probe; no action is needed") \
  || fail "codex ($VERSION): could not write the lab steering record"
LINE=$(fm_task_inbox_doorbell_line "$REC") || fail "could not build the doorbell line"
: > "$LAB/run.start"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$ROOT"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$ROOT" -- \
  env FM_TASK_INBOX="$LAB/state/$TASK.inbox" codex --dangerously-bypass-approvals-and-sandbox --disable hooks \
  || fail "codex ($VERSION): could not launch in the isolated tmux server"

# Reach an empty composer. A trust dialog fails; one other startup modal (an
# update prompt) is dismissed once with Escape, the one key that submits
# nothing.
i=0
dismissed=0
while [ "$i" -lt 60 ]; do
  [ "$(fm_tmux_composer_state "$TARGET")" != empty ] || break
  screen=$(tmux capture-pane -p -t "$TARGET" 2>/dev/null)
  if printf '%s\n' "$screen" | grep -Eq 'Trust this folder\?|Do you trust the contents of this directory\?'; then
    fail "codex ($VERSION): a trust dialog opened in $ROOT; trust the folder in an ordinary session first"
  fi
  if [ "$dismissed" -eq 0 ] && [ "$i" -ge 20 ]; then
    printf '%s\n' "$screen" | grep -qi 'trust' || tmux send-keys -t "$TARGET" Escape
    dismissed=1
  fi
  sleep 1
  i=$((i + 1))
done
[ "$(fm_tmux_composer_state "$TARGET")" = empty ] \
  || fail "codex ($VERSION): never reached an empty composer; pane tail: $(tmux capture-pane -p -t "$TARGET" | grep '[^[:space:]]' | tail -4 | tr '\n' '|')"

tmux send-keys -t "$TARGET" -l "Run the shell command $LAB/busy-loop.sh exactly once and wait for it to finish, then reply with the single word DONE."
sleep 0.5
tmux send-keys -t "$TARGET" Enter

i=0
while [ "$i" -lt 120 ] && [ ! -e "$LAB/loop.started" ]; do sleep 0.5; i=$((i + 1)); done
[ -e "$LAB/loop.started" ] || fail "codex ($VERSION): the tool loop never started"
[ ! -e "$LAB/loop.done" ] || fail "codex ($VERSION): the tool loop ended before the doorbell could be placed"

tmux send-keys -t "$TARGET" -l "$LINE"
sleep 1
rc=0
fm_task_inbox_ring tmux "$TARGET" "$REC" || rc=$?
[ ! -e "$LAB/loop.done" ] || note "codex ($VERSION): the tool loop had ended by the time the ring returned"
[ "$rc" -eq 0 ] || fail "codex ($VERSION): fm_task_inbox_ring on a busy Codex returned $rc, not 0"

ROLLOUT=
TASK_LINE=
i=0
while [ "$i" -lt 240 ]; do
  ROLLOUT=$(find "$SESSIONS" -name 'rollout-*.jsonl' -type f -newer "$LAB/run.start" -exec grep -lF "$LAB/busy-loop.sh" {} + 2>/dev/null | head -n 1)
  if [ -n "$ROLLOUT" ]; then
    TASK_LINE=$(grep -n '"task_complete"' "$ROLLOUT" | head -n 1 | cut -d: -f1)
    [ -z "$TASK_LINE" ] || break
  fi
  sleep 1
  i=$((i + 1))
done
[ -n "$ROLLOUT" ] || fail "codex ($VERSION): no session rollout under $SESSIONS written since this run started names its lab"
[ -n "$TASK_LINE" ] || fail "codex ($VERSION): the prompt's turn never recorded task_complete in $ROLLOUT"
DOOR_LINE=$(grep -nF "'$TASK.inbox' steering inbox" "$ROLLOUT" | grep -E '"user_message"|"role":"user"' | head -n 1 | cut -d: -f1)
[ -n "$DOOR_LINE" ] || fail "codex ($VERSION): the submitted doorbell never reached the model as a user message"
[ "$DOOR_LINE" -lt "$TASK_LINE" ] \
  || fail "codex ($VERSION): the doorbell reached the model only after the turn completed (rollout line $DOOR_LINE, task_complete line $TASK_LINE), so Enter queued it rather than steering"
CHECKED=$((CHECKED + 1))
pass "codex ($VERSION): an owned doorbell submitted into a busy Codex composer reached the model inside the running turn"

KEYS="$LAB/pretool-keys"
( cd "$ROOT" && FM_PRETOOL_PAYLOAD_KEYS_FILE="$KEYS" codex exec --skip-git-repo-check -s read-only \
    "Run exactly one shell command, true, and then reply DONE." < /dev/null > "$LAB/exec.out" 2>&1 ) \
  || fail "codex ($VERSION): codex exec failed: $(tail -n 5 "$LAB/exec.out")"
[ -s "$KEYS" ] || fail "codex ($VERSION): no Bash PreToolUse payload reached this checkout's hook; its .codex/hooks.json registration runs only once trusted in an ordinary session, which this guard never does"
jq -se 'length > 0 and all(.[]; index("tool_input") != null and index("session_id") != null and index("turn_id") != null)' "$KEYS" >/dev/null \
  || fail "codex ($VERSION): a real Bash PreToolUse payload lacks a key the inbox guard reads: $(cat "$KEYS")"
CHECKED=$((CHECKED + 1))
pass "codex ($VERSION): a real Bash PreToolUse payload carries tool_input, session_id and turn_id ($(head -n 1 "$KEYS"))"

[ "$CHECKED" -gt 0 ] || fail "live busy-Codex doorbell guard verified nothing; refusing a vacuous pass"
pass "live busy-Codex doorbell guard verified $CHECKED live surface(s)"
