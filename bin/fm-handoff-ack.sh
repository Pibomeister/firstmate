#!/usr/bin/env bash
# fm-handoff-ack.sh <nonce> <sha256-read-from-document>
# Run by the successor after reading the handoff, BEFORE session-start.
# Writes the ack owned by fm-handoff-lib.sh, then requests the serialized
# one-time transfer in fm-lock.sh. Every rejection emits handoff_reject.
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?FM_HOME must name the handoff home}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$SCRIPT_DIR/fm-handoff-lib.sh"
nonce=${1:-}
reject() {
  fm_handoff_event handoff_reject "$nonce" 0 0 "${ORCA_TERMINAL_HANDLE:-${TMUX_PANE:-}}" "$1"
  exit 1
}
case "$nonce" in ''|*[!a-f0-9]*) reject invalid_nonce ;; esac
claim="$STATE/.handoff-pending"
[ -f "$claim" ] && [ ! -L "$claim" ] || reject missing_claim
[ "$(jq -r .nonce "$claim")" = "$nonce" ] || reject stale_nonce
[ "$(date +%s)" -lt "$(jq -r .deadline "$claim")" ] || reject expired_claim
[ "$(cat "$STATE/.lock")" = "$(jq -r .predecessor_pid "$claim")" ] || reject ownership_changed
sha=$(jq -er .sha256 "$claim") || reject invalid_claim
doc=$(jq -er .handoff "$claim") || reject invalid_claim
[ "${2:-}" = "$sha" ] && [ "$(fm_handoff_hash "$doc")" = "$sha" ] || reject hash_mismatch
pid=$(fm_session_lock_anchor_pid) || reject no_harness
[ "$pid" != "$(jq -r .predecessor_pid "$claim")" ] || reject predecessor_ack
fm_harness_pid_alive "$pid" || reject no_harness
handle=${ORCA_TERMINAL_HANDLE:-${TMUX_PANE:-}}
case "$handle" in ''|*[!A-Za-z0-9_.:%-]*) reject no_terminal ;; esac
start=$(fm_session_process_start "$pid") || reject no_harness
tmp=$(mktemp "$FM_HOME/data/.handoff-ack.XXXXXX") || reject write_failed
jq -n --arg nonce "$nonce" --arg sha "$sha" --arg handle "$handle" \
  --arg start "$start" --argjson pid "$pid" \
  '{version:1,nonce:$nonce,sha256:$sha,harness_pid:$pid,fm_lock_pid:$pid,harness_start:$start,terminal_handle:$handle}' > "$tmp"
mv "$tmp" "$FM_HOME/data/handoff-ack-$nonce.json"
FM_HANDOFF_NONCE="$nonce" bash "$SCRIPT_DIR/fm-lock.sh" >/dev/null || reject lock_refused
fm_handoff_event handoff_ack "$nonce" 0 "$pid" "$handle" lock_transferred
