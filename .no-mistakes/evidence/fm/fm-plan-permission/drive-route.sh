#!/usr/bin/env bash
# Drive bin/fm-permission-route.sh claude-request as Claude Code's hook would,
# against a disposable state dir. Usage: drive-route.sh <worktree> <label> <command>
set -u
WT=$1; LABEL=$2; CMD=$3
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-route-live.XXXXXX")
printf 'kind=ship\nharness=claude\napproval_mode=bypass\n' > "$S/task.meta"
PAYLOAD=$(jq -cn --arg command "$CMD" '{hook_event_name:"PermissionRequest",permission_mode:"bypassPermissions",tool_name:"Bash",tool_input:{command:$command,description:"d"},permission_suggestions:[],cwd:"/x",session_id:"s"}')
OUT=$(printf '%s' "$PAYLOAD" | AK_LIFECYCLE_POLICY=unattended bash "$WT/bin/fm-permission-route.sh" claude-request "$S" task); RC=$?
echo "=== $LABEL"
echo "--- command:"; printf '%s\n' "$CMD" | sed 's/^/    /'
echo "--- classify: $(printf '%s' "$CMD" | bash "$WT/bin/fm-permission-route.sh" classify)"
echo "--- hook exit=$RC stdout:"; if [ -n "$OUT" ]; then printf '%s' "$OUT" | jq -c '.hookSpecificOutput.decision|{behavior, message:(.message[0:90]+"...")}'; else echo "    (empty: prompt stays for a person)"; fi
echo "--- ledger verdict/category: $(cut -f2,3 "$S/task.permission-route.tsv" 2>/dev/null | tr '\t' ' ')"
echo "--- status: $(cat "$S/task.status" 2>/dev/null | sed 's/^[0-9]* //' || true)"
echo "--- held-keys: $(bash "$WT/bin/fm-permission-route.sh" held-keys "$S" task | tr '\n' ' ')"
rm -rf "$S"
