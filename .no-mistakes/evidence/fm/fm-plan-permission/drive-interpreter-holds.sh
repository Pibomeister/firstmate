#!/usr/bin/env bash
# Drive bin/fm-permission-route.sh claude-request as the Claude hook runs it,
# one disposable state dir per command, and print the observable answer.
set -u
ROUTE="$1/bin/fm-permission-route.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-route-drive.XXXXXX")
BT='`'
n=0
drive() {  # <label> <command>
  n=$((n+1)); local st="$TMP/h$n/state"; mkdir -p "$st"
  printf 'kind=ship\nharness=claude\napproval_mode=bypass\n' > "$st/task.meta"
  local payload out verdict key
  payload=$(jq -cn --arg c "$2" '{hook_event_name:"PermissionRequest",permission_mode:"bypassPermissions",tool_name:"Bash",tool_input:{command:$c,description:"d"},permission_suggestions:[],cwd:"/x",session_id:"s"}')
  out=$(printf '%s' "$payload" | AK_LIFECYCLE_POLICY=unattended bash "$ROUTE" claude-request "$st" task); rc=$?
  if [ -z "$out" ]; then verdict="HOLD (no answer printed; prompt stays for a person)"; else verdict="REFUSE: $(printf '%s' "$out" | jq -r '.hookSpecificOutput.decision.behavior')"; fi
  key=$(grep -o 'key=[a-z-]*' "$st/task.status" 2>/dev/null | tr '\n' ' ')
  printf '%-44s rc=%s  %-52s ledger=%s  status=%s\n' "$1" "$rc" "$verdict" "$(cut -f2,3 "$st/task.permission-route.tsv" | tr '\t' ':')" "${key:-none}"
}
for w in python3.13t pythonw python3.12 nodejs node perl5.34 perl ruby3.2 /usr/local/bin/ruby3.3 php8.2 php; do
  drive "heredoc into $w" "$w <<EOF
${BT}date${BT}
EOF"
done
for w in python3.13t nodejs perl5.34 ruby3.2 php8.2; do
  drive "later '$w -e 1' after class heredoc" "cat <<EOF
${BT}t${BT}
EOF
$w -e 1"
done
echo "--- adversarial lookalikes (must NOT be treated as interpreters) ---"
for w in perlx nodex rubyist phpx python3x; do
  drive "lookalike $w after class heredoc" "cat <<EOF
${BT}t${BT}
EOF
$w -e 1"
done
echo "--- baseline established class ---"
drive "plain class heredoc then echo" "N=/n; cat <<EOF
${BT}true${BT}
EOF
echo \$N"
rm -rf "$TMP"
