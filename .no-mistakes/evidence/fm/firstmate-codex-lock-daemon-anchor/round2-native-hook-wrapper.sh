#!/bin/bash
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/state/native-original-stop-payloads.jsonl"
printf '%s' "$payload" | bash -lc 'payload=$(cat 2>/dev/null || true); [ -n "$payload" ] || exit 0; command -v jq >/dev/null 2>&1 || exit 0; root=$(pwd -P) || exit 0; [ -x "$root/bin/fm-turnend-guard.sh" ] || exit 0; [ -f "$root/AGENTS.md" ] || exit 0; [ -f "$root/.codex/hooks.json" ] || exit 0; jq -e "any(.hooks.Stop[]?.hooks[]?.command?; type == \"string\" and contains(\"fm-turnend-guard.sh\"))" "$root/.codex/hooks.json" >/dev/null 2>&1 || exit 0; printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh"' > "$FM_HOME/state/native-original-stop.out" 2> "$FM_HOME/state/native-original-stop.err"
rc=$?
printf '%s\n' "$rc" >> "$FM_HOME/state/native-original-stop-returns.txt"
cat "$FM_HOME/state/native-original-stop.out"
cat "$FM_HOME/state/native-original-stop.err" >&2
exit "$rc"
