#!/usr/bin/env bash
# Opt-in live guard for the usage-limit pane-text classifier.
# Default off. When requested, capture a real Claude pane and classify it.
# Pass only when that pane is a usage-limit picker. Never types Enter.
# Without a real picker, fail closed. Codex pane-text is not covered here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_USAGE_LIMIT_PANE_LIVE claude tmux jq

TMP_ROOT=$(fm_test_tmproot fm-usage-limit-pane-live)
REAL_TMUX=$(command -v tmux)
REAL_CLAUDE=$(command -v claude)
CLAUDE_VERSION=$("$REAL_CLAUDE" --version 2>/dev/null | head -n 1)
[ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION=unknown
SOCKET="fm-usage-limit-pane-live-$$"

cleanup_live() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_live EXIT

LAB_CONFIG="$TMP_ROOT/claude-config"
LAB_KEY="sk-ant-fm-usage-limit-pane-live-not-a-real-key"
WORK="$TMP_ROOT/untrusted-folder"
mkdir -p "$LAB_CONFIG" "$WORK"
jq -n --arg k "${LAB_KEY: -20}" '{hasCompletedOnboarding:true, customApiKeyResponses:{approved:[$k], rejected:[]}}' \
  > "$LAB_CONFIG/.claude.json"

"$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s ul -x 160 -y 45 -c "$WORK" \
  env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$LAB_CONFIG" ANTHROPIC_API_KEY="$LAB_KEY" \
  ANTHROPIC_BASE_URL=http://127.0.0.1:9 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$REAL_CLAUDE" ||
  fail "claude $CLAUDE_VERSION: could not start in a private tmux socket"
T=$("$REAL_TMUX" -L "$SOCKET" list-panes -t ul -F '#{pane_id}' | head -n 1)

screen() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null; }
classify() {
  bash -c '. "$1/bin/fm-watchdog-lib.sh"; fm_wd_pane_dialog "$2"' _ "$ROOT" "$1"
}

wait_screen() {  # <ere> <tries>
  local i
  for i in $(seq 1 "$2"); do
    screen | grep -Eiq -- "$1" && return 0
    sleep 1
  done
  return 1
}

wait_screen 'trust this folder|for shortcuts|auto mode|bypass permissions|weekly limit|usage limit|❯' 40 ||
  fail "claude $CLAUDE_VERSION: no pane rendered; last screen: $(screen | tail -n 5)"

kind=
i=0
while [ "$i" -lt 10 ]; do
  kind=$(classify "$(screen)") || kind=
  [ "$kind" = usage-limit ] && break
  sleep 1
  i=$((i + 1))
done

if [ "$kind" = usage-limit ]; then
  pass "claude $CLAUDE_VERSION: a real usage-limit picker classified with no Enter"
  exit 0
fi

printf 'not ok - usage-limit pane-text classification is not live-verified for %s (classified %s)\n' \
  "$CLAUDE_VERSION" "${kind:-none}" >&2
printf 'captured a real Claude pane and never typed Enter; fail closed until a dated usage-limit capture exists\n' >&2
exit 1
