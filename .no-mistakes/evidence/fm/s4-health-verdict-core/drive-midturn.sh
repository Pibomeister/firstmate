#!/usr/bin/env bash
set -u
W=$1 LAB=$2; cd "$W"
E="env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE -u NO_MISTAKES_GATE FM_HOME=$LAB FM_GUARD_GRACE=300"
ago() { date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S; }
mon() { printf 'status=enabled at=%s\n' "$(date +%s)" > "$LAB/state/monitor-status"; }
( sleep 100000 >/dev/null 2>&1 & echo $! > "$LAB/lockpid" ); P=$(cat "$LAB/lockpid"); echo $P > "$LAB/state/.lock"
$E bin/fm-watchdog.sh once --dry-run --home "$LAB" >/dev/null 2>&1; mon
echo "  [watchdog] $(grep ^alive= "$LAB/state/watchdog/captain")"
echo "== S12 auto-arm turn proven 50s ago, watcher beat 100s old (inside 300s grace), heartbeat 100s old (bound 75) -> unknown mid-turn"
jq ".generated_epoch = $(( $(date +%s) - 100 ))" "$LAB/state/heartbeat.json" > "$LAB/hb.tmp" && mv "$LAB/hb.tmp" "$LAB/state/heartbeat.json"
printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=lab-gen\n' "$P" > "$LAB/state/.claude-autoarm-epoch"
printf 'acked:handling:lab-gen\n' > "$LAB/state/.watcher-down"
touch -t "$(ago 100)" "$LAB/state/.last-watcher-beat"; touch -t "$(ago 50)" "$LAB/state/.claude-autoarm-epoch"
echo "  [auto-arm model]";  $E FM_SUPERVISION_MODEL=autoarm bin/fm-health-verdict.sh --home "$LAB" | sed 's/^/  > /'
echo "  [persistent model, same records: no auto-arm proof applies]"; $E FM_SUPERVISION_MODEL=persistent bin/fm-health-verdict.sh --home "$LAB" | sed 's/^/  > /'
echo "== S13 watcher beats after the turn proof -> between turns, the same old heartbeat is stale"
touch "$LAB/state/.last-watcher-beat"; $E FM_SUPERVISION_MODEL=autoarm bin/fm-health-verdict.sh --home "$LAB" | sed 's/^/  > /'
echo "== S14 a dead lock outranks mid-turn"
touch -t "$(ago 100)" "$LAB/state/.last-watcher-beat"; kill $P; sleep 1
$E bin/fm-watchdog.sh once --dry-run --home "$LAB" >/dev/null 2>&1; mon; echo "  [watchdog] $(grep ^alive= "$LAB/state/watchdog/captain")"
$E FM_SUPERVISION_MODEL=autoarm bin/fm-health-verdict.sh --home "$LAB" | sed 's/^/  > /'
