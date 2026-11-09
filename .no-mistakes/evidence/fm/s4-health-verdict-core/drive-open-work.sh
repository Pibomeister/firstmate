#!/usr/bin/env bash
set -u
LAB=$1
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
V() { run bin/fm-health-verdict.sh --home "$LAB"; }
echo "## S15: a real captain goal received via fm-dispatch-log.sh opens work"
run bin/fm-dispatch-log.sh received g-lab-1 --summary "lab goal"; echo "  log_exit=$?"
printf 'alive=none\n' > "$LAB/state/watchdog/captain"
echo "  lock none + open work:"; V
printf 'alive=live\n' > "$LAB/state/watchdog/captain"
echo "## S16: lock live, open work, watcher beat older than watcher-stale-secs=60"
printf 'watcher-stale-secs=60\n' > "$LAB/config/watchdog"
touch -t "$(date -v-10M +%Y%m%d%H%M.%S)" "$LAB/state/.last-watcher-beat"; V
echo "## S17: goal dispatched closes it; same stale beat no longer matters"
run bin/fm-dispatch-log.sh dispatched g-lab-1 --task lab-t1; echo "  log_exit=$?"; V
