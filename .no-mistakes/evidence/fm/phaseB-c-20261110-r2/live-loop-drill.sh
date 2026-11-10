#!/usr/bin/env bash
# Live drill: real Claude Code primary on an actionable lab home with no watcher.
# The real fm-turnend-guard.sh --claude is the Stop hook (no active short-circuit).
# Expect: continuation turns 1-2 blocked (exit 2), turn 3 identical reply -> hook_loop allow.
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-loop.XXXXXX")
L=$T/home
mkdir -p "$L/bin" "$L/state" "$L/.claude" "$L/config"
git init -q "$L"; git -C "$L" -c user.name=t -c user.email=t@example.invalid commit -qm init --allow-empty
: > "$L/AGENTS.md"; : > "$L/state/task.meta"
printf 'working [at=1]: executable work\n' > "$L/state/task.status"
cat > "$L/hook.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/payloads.jsonl"
rc=0; printf '%s' "$payload" | bash "$POLICY_ROOT/bin/fm-turnend-guard.sh" --claude 2>>"$FM_HOME/guard.err" || rc=$?
printf 'guard_rc=%s active=%s\n' "$rc" "$(printf '%s' "$payload" | jq -r .stop_hook_active)" >> "$FM_HOME/rcs.txt"
[ "$rc" -eq 2 ] && { echo 'Stop hook: supervision missing; reply again.' >&2; exit 2; }
exit 0
SH
jq -nc --arg command "bash '$L/hook.sh'" '{hooks:{Stop:[{hooks:[{type:"command",command:$command,timeout:20}]}]}}' > "$L/.claude/settings.json"
( cd "$L" && env -u CLAUDECODE -u NO_MISTAKES_GATE FM_HOME="$L" FM_ROOT_OVERRIDE="$L" FM_STATE_OVERRIDE="$L/state" \
  FM_CONFIG_OVERRIDE="$L/config" POLICY_ROOT="$ROOT" FM_TEST_SEAM=1 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
  timeout 300 claude -p 'Reply with exactly SHIPSHAPE and end the turn. Repeat exactly that reply after any hook feedback; never use tools.' \
  --system-prompt 'Follow the requested exact reply.' --effort low --tools '' \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources project \
  --output-format stream-json --verbose ) > "$L/claude.jsonl" 2>&1
echo "claude_rc=$?"
echo "--- Stop payloads seen: $(wc -l < "$L/payloads.jsonl" | tr -d ' ')"
cat "$L/rcs.txt"
echo "--- assistant replies:"; jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$L/claude.jsonl"
echo "--- transcript_path readable: $(jq -r .transcript_path "$L/payloads.jsonl" | head -1 | xargs test -r && echo yes || echo no)"; echo "--- state/stop-hook.log:"; cat "$L/state/stop-hook.log"
rm -rf "$T"
