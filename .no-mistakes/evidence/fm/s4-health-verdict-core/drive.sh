#!/usr/bin/env bash
# Drive fm-heartbeat.sh and fm-health-verdict.sh against a disposable lab home.
set -u
LAB=$1
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
V() { run bin/fm-health-verdict.sh --home "$LAB" "$@"; echo "  (exit=$?)"; }
echo "## S1: empty lab home before any publication (state dir listing, then verdict)"
ls -A "$LAB/state"; V
echo "## S1b: read without --write did not create files"; ls -A "$LAB/state"
echo "## S2: real heartbeat publication (watcher cycle 15s, stale-grace-secs=60)"
mkdir -p "$LAB/config"; printf 'stale-grace-secs=60\n' > "$LAB/config/heartbeat"
run FM_HEARTBEAT_CYCLE_SECS=15 FM_HEARTBEAT_QUOTA_TIMEOUT=2 bin/fm-heartbeat.sh --write; echo "  hb_exit=$?"
jq -c '{schema,generated_epoch,published_epoch,stale_after_secs}' "$LAB/state/heartbeat.json"
echo "  verdict with heartbeat but no watchdog captain record:"; V
echo "## S3: watchdog records lock live, monitor enabled, fresh watcher beat"
mkdir -p "$LAB/state/watchdog"
printf 'alive=live\nchecked_at=%s\n' "$(date +%s)" > "$LAB/state/watchdog/captain"
printf 'status=enabled at=%s\n' "$(date +%s)" > "$LAB/state/monitor-status"
touch "$LAB/state/.last-watcher-beat"; V
echo "## S4: lock dead outranks a fresh heartbeat"
printf 'alive=dead\n' > "$LAB/state/watchdog/captain"; V
echo "## S5: lock unconfirmed -> instance-mismatch"
printf 'alive=unconfirmed\n' > "$LAB/state/watchdog/captain"; V
echo "## S6: lock none, no open work, no away -> ok idle"
printf 'alive=none\n' > "$LAB/state/watchdog/captain"; V
echo "## S7: lock none with away record -> dead none-away"
touch "$LAB/state/.afk"; V; rm -f "$LAB/state/.afk"
echo "## S8: lock live, heartbeat published_epoch aged past stale_after_secs (generated_epoch left fresh)"
printf 'alive=live\n' > "$LAB/state/watchdog/captain"
b=$(jq .stale_after_secs "$LAB/state/heartbeat.json"); old=$(( $(date +%s) - b - 30 ))
jq --argjson p $old --argjson g "$(date +%s)" '.published_epoch=$p | .generated_epoch=$g' "$LAB/state/heartbeat.json" > "$LAB/hb.tmp" && mv "$LAB/hb.tmp" "$LAB/state/heartbeat.json"
V
echo "## S9: inverse: generated_epoch old but published_epoch fresh -> fresh (age from publication stamp)"
jq --argjson p "$(date +%s)" --argjson g $old '.published_epoch=$p | .generated_epoch=$g' "$LAB/state/heartbeat.json" > "$LAB/hb.tmp" && mv "$LAB/hb.tmp" "$LAB/state/heartbeat.json"
V
echo "## S10: heartbeat with no published_epoch -> unknown heartbeat-field-unread, never ok"
jq 'del(.published_epoch)' "$LAB/state/heartbeat.json" > "$LAB/hb.tmp" && mv "$LAB/hb.tmp" "$LAB/state/heartbeat.json"; V
echo "## S11: monitor disabled folds into unknown"
run FM_HEARTBEAT_CYCLE_SECS=15 FM_HEARTBEAT_QUOTA_TIMEOUT=2 bin/fm-heartbeat.sh --write >/dev/null 2>&1
printf 'status=disabled\n' > "$LAB/state/monitor-status"; V
printf 'status=enabled\n' > "$LAB/state/monitor-status"
echo "## S12: corrupt heartbeat.json -> unknown, no crash"
cp "$LAB/state/heartbeat.json" "$LAB/hb.bak"; echo '{not json' > "$LAB/state/heartbeat.json"; V; mv "$LAB/hb.bak" "$LAB/state/heartbeat.json"
echo "## S13: --write records the verdict line atomically"
V --write; cat "$LAB/state/health-verdict"; ls -A "$LAB/state" | grep -c '^\.health-verdict\.' || true
echo "## S14: usage errors"
run bin/fm-health-verdict.sh --bogus; echo "  exit=$?"
run bin/fm-health-verdict.sh --home /nonexistent/x; echo "  exit=$?"
env -u FM_HOME bin/fm-health-verdict.sh; echo "  exit=$?"
