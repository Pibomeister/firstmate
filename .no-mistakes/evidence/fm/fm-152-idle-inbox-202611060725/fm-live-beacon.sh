#!/usr/bin/env bash
set -u
LAB=$1
E=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
echo '$ fm-inbox.sh ready   # empty inbox'
"${E[@]}" bin/fm-inbox.sh ready | jq '.wake_consumer'
echo '$ fm-inbox.sh note "stalled captain note"'
out=$("${E[@]}" bin/fm-inbox.sh note "stalled captain note" 2>&1); echo "$out"; id=$(printf '%s' "$out" | sed -n 's/^queued //p')
echo '$ wake queue line written by note:'; grep -rh 'captain inbox note' "$LAB/state" 2>/dev/null | head -3
echo "$ (backdate note mtime by 300s)"; touch -t "$(date -v-300S +%Y%m%d%H%M.%S)" "$LAB/state/inbox/$id.note"
echo '$ fm-inbox.sh ready'; "${E[@]}" bin/fm-inbox.sh ready | jq '.wake_consumer'
echo '$ fm-heartbeat.sh --write'
"${E[@]}" bin/fm-heartbeat.sh --write >/dev/null 2>&1; echo "heartbeat exit $?"
L=$(ls "$LAB"/state/*heartbeat*.json 2>/dev/null | head -1); echo "ledger: ${L#$LAB/}"
jq '.primary | {unread_inbox_age_seconds}' "$L"
echo "$ fm-inbox.sh drain --ack $id"; "${E[@]}" bin/fm-inbox.sh drain --ack "$id" | head -3
echo '$ fm-inbox.sh ready  (after ack)'; "${E[@]}" bin/fm-inbox.sh ready | jq '.wake_consumer.unread_inbox_age_seconds'
"${E[@]}" bin/fm-heartbeat.sh --write >/dev/null 2>&1; echo '$ heartbeat after ack'; jq '.primary.unread_inbox_age_seconds' "$L"
