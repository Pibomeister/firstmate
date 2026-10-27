#!/usr/bin/env bash
set -eu
printf 'claude sonnet\n' > "$FM_HOME/config/supervision-host"
printf 'tmux\n' > "$FM_HOME/config/backend"
mkdir -p "$FM_HOME/claude-config"
export CLAUDE_CONFIG_DIR="$FM_HOME/claude-config"
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export ANTHROPIC_BASE_URL=http://127.0.0.1:9
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
export FM_POLL=1 FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_TURN_TIMEOUT=3
export FM_SUPERVISION_ENGINE_GRACE=1 FM_SUPERVISION_HOST_PARK_SECONDS=20
export FM_SUPERVISION_HOST_READY_TIMEOUT=6 FM_SUPERVISION_HOST_RELEASE_BUDGET=3
bin/fm-afk-contract.sh enter --words 'Disposable validation only; merge nothing and spawn no workers.' >/dev/null
for round in 1 2; do
  bin/fm-lock.sh
  out=$(bin/fm-wake-drain.sh 2>&1)
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  if [ -n "$ack" ]; then bin/fm-wake-drain.sh $ack >/dev/null; fi
  bin/fm-supervision-host.sh park > "$FM_HOME/state/host-round-$round.log" 2>&1 &
  host_pid=$!
  sleep 3
  bin/fm-inbox.sh note "Disposable validation event $round; no work is requested." >/dev/null
  wait "$host_pid"
  echo "ROUND $round"
  cat "$FM_HOME/state/host-round-$round.log"
  cat "$FM_HOME/state/.supervision-host-health"
done
test "$(sed -n 's/^errors=//p' "$FM_HOME/state/.supervision-host-health")" -ge 2
test "$(sed -n 's/^cooldown=//p' "$FM_HOME/state/.supervision-host-health")" -gt 0
bin/fm-afk-contract.sh archive >/dev/null
