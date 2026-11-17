#!/usr/bin/env bash
# Credentialed Claude payload probe, no live home or worker launch.
# The active continuation is ended by the lab wrapper after capturing its real
# payload; monitoring continuity is exercised by the portable auto-arm drill.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_STOP_POLICY_LIVE_E2E claude
TMP_ROOT=$(fm_test_tmproot fm-stop-policy-live)
recovery_owner=
trap '[ -z "$recovery_owner" ] || kill "$recovery_owner" 2>/dev/null || true; fm_test_cleanup' EXIT
VERSION=$(claude --version)
printf 'claude version: %s\n' "$VERSION"
for scenario in parked active; do
  LAB="$TMP_ROOT/$scenario"
  mkdir -p "$LAB/bin" "$LAB/state" "$LAB/.claude" "$LAB/config"
  git init -q "$LAB"
  : > "$LAB/AGENTS.md"
  : > "$LAB/state/task.meta"
  if [ "$scenario" = parked ]; then
    printf 'captain-held [at=1]: owner decision\n' > "$LAB/state/task.status"
    # The portable auto-arm drill covers watcher continuity. This payload
    # probe gives the guard a live recovery owner while Claude ends its turn.
    sleep 300 &
    recovery_owner=$!
    mkdir -p "$LAB/state/.claude-autoarm.lock"
    printf '%s\n' "$recovery_owner" > "$LAB/state/.claude-autoarm.lock/pid"
    printf 'autoarm\n' > "$LAB/state/.claude-autoarm.lock/role"
  else
    printf 'working [at=1]: executable work\n' > "$LAB/state/task.status"
  fi
  cat > "$LAB/hook.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/payloads.jsonl"
printf '%s' "$payload" | jq -e '.stop_hook_active == true' >/dev/null && exit 0
printf '%s' "$payload" | bash "$POLICY_ROOT/bin/fm-turnend-guard.sh" --claude
SH
  # No hook timeout, matching the production guard registration in
  # .claude/settings.json: a loaded host can need more than 10s, and an expired
  # hook makes Claude stop after one payload instead of continuing.
  jq -nc --arg command "bash '$LAB/hook.sh'" \
    '{hooks:{Stop:[{hooks:[{type:"command",command:$command}]}]}}' > "$LAB/.claude/settings.json"
  (
    cd "$LAB" || exit 1
    env -u CLAUDECODE FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
      FM_CONFIG_OVERRIDE="$LAB/config" POLICY_ROOT="$ROOT" FM_TEST_SEAM=1 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
      claude -p 'Reply with exactly SHIPSHAPE and end the turn. Repeat that reply after any hook feedback.' \
      --system-prompt 'Follow the requested exact reply.' --effort low --tools '' \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources project \
      --no-session-persistence --output-format stream-json --verbose
  ) > "$LAB/claude.jsonl" 2>&1 || fail "$VERSION $scenario Claude run failed: $(tail -10 "$LAB/claude.jsonl")"
  if [ "$scenario" = parked ]; then
    kill "$recovery_owner" 2>/dev/null || true
    wait "$recovery_owner" 2>/dev/null || true
    recovery_owner=
  fi
  if [ "$scenario" = parked ]; then
    [ "$(wc -l < "$LAB/payloads.jsonl" | tr -d ' ')" -eq 1 ] || fail "$VERSION parked session did not stop in one turn"
    rg -q 'status=parked ' "$LAB/state/stop-hook.log" || fail "$VERSION parked event absent"
  else
    jq -se 'length == 2 and .[0].stop_hook_active == false and .[1].stop_hook_active == true' "$LAB/payloads.jsonl" >/dev/null \
      || fail "$VERSION changed its Stop continuation payload: $(cat "$LAB/payloads.jsonl")"
  fi
  printf 'ok - %s: %s stopped after %s real Stop payload(s)\n' "$VERSION" "$scenario" "$(wc -l < "$LAB/payloads.jsonl" | tr -d ' ')"
  cat "$LAB/state/stop-hook.log"
done
