#!/usr/bin/env bash
# Credentialed Claude guard: real Stop payloads, no live home or worker launch.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_STOP_POLICY_LIVE_E2E claude
TMP_ROOT=$(fm_test_tmproot fm-stop-policy-live)
trap fm_test_cleanup EXIT
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
  else
    printf 'working [at=1]: executable work\n' > "$LAB/state/task.status"
  fi
  cat > "$LAB/hook.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/payloads.jsonl"
printf '%s' "$payload" | bash "$POLICY_ROOT/bin/fm-turnend-guard.sh" --claude
SH
  jq -nc --arg command "bash '$LAB/hook.sh'" \
    '{hooks:{Stop:[{hooks:[{type:"command",command:$command,timeout:10}]}]}}' > "$LAB/.claude/settings.json"
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
    [ "$(wc -l < "$LAB/payloads.jsonl" | tr -d ' ')" -eq 1 ] || fail "$VERSION parked session did not stop in one turn"
    rg -q 'status=parked ' "$LAB/state/stop-hook.log" || fail "$VERSION parked event absent"
  else
    jq -se 'length == 2 and .[0].stop_hook_active == false and .[1].stop_hook_active == true' "$LAB/payloads.jsonl" >/dev/null \
      || fail "$VERSION changed its Stop continuation payload: $(cat "$LAB/payloads.jsonl")"
    rg -q 'status=hook_active ' "$LAB/state/stop-hook.log" || fail "$VERSION active-hook event absent"
  fi
  printf 'ok - %s: %s stopped after %s real Stop payload(s)\n' "$VERSION" "$scenario" "$(wc -l < "$LAB/payloads.jsonl" | tr -d ' ')"
  cat "$LAB/state/stop-hook.log"
done
