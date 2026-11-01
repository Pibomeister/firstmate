#!/usr/bin/env bash
# tests/fm-watchdog-live.test.sh - token-free live guard for bin/fm-watchdog.sh
# against the installed Claude Code TUI in a private tmux socket.
#
# It never submits a prompt: the watchdog runs with no judge models, every
# model CLI it could reach is a logging fake, and the only text typed is a
# `merge #12` draft the watchdog must refuse to submit. It proves the rendered
# signals the watchdog reads from a real Claude pane: the folder-trust picker
# is a permission dialog that gets no key, the composer verdict sees a draft,
# and Enter is never pressed on merge text. Runs by default where claude, tmux,
# and jq are installed; FM_WATCHDOG_LIVE=0 or FM_LIVE=0 turns it off, and
# FM_WATCHDOG_LIVE=1 makes an absent tool a failure.
# Accepting the trust picker records the disposable folder in the Claude
# config's trusted list; the folder itself is removed on exit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_WATCHDOG_LIVE claude tmux jq

TMP_ROOT=$(fm_test_tmproot fm-watchdog-live)
REAL_TMUX=$(command -v tmux)
REAL_CLAUDE=$(command -v claude)
CLAUDE_VERSION=$("$REAL_CLAUDE" --version 2>/dev/null | head -n 1)
SOCKET="fm-watchdog-live-$$"
WD="$ROOT/bin/fm-watchdog.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS_LOG="$TMP_ROOT/model-calls.log"
: > "$CALLS_LOG"
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
for tool in claude agy cursor-agent gh gh-axi osascript; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$CALLS_LOG"
exit 1
SH
done
chmod +x "$FAKEBIN"/*

cleanup_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_live EXIT

H="$TMP_ROOT/home"
WORK="$TMP_ROOT/untrusted-folder"
SID="22222222-2222-4222-8222-$(printf '%012d' "$$")"
mkdir -p "$H/state" "$H/config" "$H/data" "$WORK"

"$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s wd -x 160 -y 45 -c "$WORK" "$REAL_CLAUDE" ||
  fail "claude $CLAUDE_VERSION: could not start in a private tmux socket"
T=$("$REAL_TMUX" -L "$SOCKET" list-panes -t wd -F '#{pane_id}' | head -n 1)
PANE_PID=$("$REAL_TMUX" -L "$SOCKET" list-panes -t wd -F '#{pane_pid}' | head -n 1)
printf '%s\n' "$PANE_PID" > "$H/state/.lock"
printf '%s\n' "$SID" > "$H/state/.lock-session"
jq -n --arg t "$T" --arg s "$SID" --argjson e "$(date +%s)" \
  '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s}}}' \
  > "$H/state/heartbeat.json"
printf 'mode=act\nmodels=\ncouncil-seats=\nkey-settle-secs=1\n' > "$H/config/watchdog"

screen() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null; }
wd() { PATH="$FAKEBIN:$PATH" FM_HOME="$H" bash "$WD" "$@"; }
lib() { bash -c '. "$1/bin/fm-watchdog-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
composer() { PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux "$2"' _ "$ROOT" "$T"; }
key_rows() { awk -F'\t' '$6 == "key" && $7 != "refused"' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' '; }

wait_screen() {  # <ere> <tries>
  local i
  for i in $(seq 1 "$2"); do
    screen | grep -Eiq -- "$1" && return 0
    sleep 1
  done
  return 1
}

wait_screen 'trust this folder|for shortcuts|auto mode|bypass permissions|❯' 40 ||
  fail "claude $CLAUDE_VERSION: neither the trust picker nor the composer rendered; last screen: $(screen | tail -n 5)"

# 1. The folder-trust picker is a permission dialog, and the watchdog presses nothing.
if screen | grep -Eiq 'trust this folder'; then
  sleep 2
  assert_equals permission "$(lib fm_wd_pane_dialog "$(screen)")" \
    "claude $CLAUDE_VERSION: the folder-trust picker reads as a permission dialog"
  wd once > /dev/null 2>&1 || fail "claude $CLAUDE_VERSION: watchdog pass failed on the trust picker"
  sleep 2
  assert_equals 0 "$(key_rows)" "claude $CLAUDE_VERSION: no key is sent to a permission dialog"
  screen | grep -Eiq 'trust this folder' || fail "claude $CLAUDE_VERSION: the trust picker changed under the watchdog"
  grep -Fq 'permission dialog waiting' "$H/data/watchdog/status.md" ||
    fail "claude $CLAUDE_VERSION: the waiting permission dialog is not reported as a gap"
  pass "claude $CLAUDE_VERSION: the folder-trust picker is left alone and reported"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$T" Down
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$T" Enter
else
  printf 'note: claude %s showed no folder-trust picker for a new folder; that check did not run\n' "$CLAUDE_VERSION"
fi

# 2. Clear any further startup pickers by hand until the composer is empty.
state=unknown
for _ in $(seq 1 20); do
  sleep 1
  if [ -n "$(lib fm_wd_pane_dialog "$(screen)")" ]; then
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$T" Escape
    continue
  fi
  state=$(composer)
  [ "$state" = empty ] && break
done
assert_equals empty "$state" "claude $CLAUDE_VERSION: the tmux composer verdict reads an empty composer; last screen: $(screen | tail -n 4)"

# 3. A merge draft in the real composer is seen, and Enter is never pressed.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$T" -l 'merge #12'
for _ in $(seq 1 10); do
  sleep 1
  state=$(composer)
  [ "$state" = pending ] && break
done
assert_equals pending "$state" "claude $CLAUDE_VERSION: the tmux composer verdict sees the typed draft"
rm -f "$H/state/watchdog/actions.tsv"
# Unsent text needs two passes over one unchanged pane; Claude can still be
# repainting just after the draft lands, so allow a few passes to settle.
for _ in $(seq 1 6); do
  wd once > /dev/null 2>&1 || fail "claude $CLAUDE_VERSION: watchdog pass failed"
  sleep 1
done
refused=$(awk -F'\t' '$5 == "pasted-input" && $6 == "key" && $7 == "refused"' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' ')
assert_equals 1 "$refused" "claude $CLAUDE_VERSION: the merge draft is refused once per window; scan: $(wd scan 2>&1 | tr -s ' \n' '  '); ledger: $(cat "$H/state/watchdog/actions.tsv" 2>/dev/null | cut -f5-8 | tr '\n\t' '; ')"
assert_equals 0 "$(key_rows)" "claude $CLAUDE_VERSION: no key reaches the pane holding merge text"
sleep 2
screen | grep -Fq 'merge #12' || fail "claude $CLAUDE_VERSION: the merge draft left the composer"
assert_equals pending "$(composer)" "claude $CLAUDE_VERSION: the merge draft is still unsent"
assert_equals "" "$(cat "$CALLS_LOG")" "claude $CLAUDE_VERSION: no model, forge, or notifier CLI was called"
pass "claude $CLAUDE_VERSION: a real merge draft is seen and never submitted, with no model call"
