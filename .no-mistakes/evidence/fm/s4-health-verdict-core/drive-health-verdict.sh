#!/usr/bin/env bash
# Live driver: real fm-watchdog.sh once, real fm-heartbeat.sh --write, real
# fm-dispatch-log.sh, then the real fm-health-verdict.sh, on a disposable lab home.
set -u
W=$1 LAB=$2
cd "$W"
E="env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u NO_MISTAKES_GATE FM_HOME=$LAB FM_SUPERVISION_MODEL=persistent"
wd() { $E bin/fm-watchdog.sh once --dry-run --home "$LAB" >/dev/null 2>&1; echo "  [watchdog] $(grep ^alive= "$LAB/state/watchdog/captain") monitor-read=$(cut -d' ' -f1 "$LAB/state/monitor-status")"; [ -z "${KEEP_MON:-}" ] || mon_enabled; }
hb() { $E FM_HEARTBEAT_CYCLE_SECS=15 bin/fm-heartbeat.sh --write >/dev/null 2>&1; echo "  [heartbeat] $(jq -c '{generated_epoch,stale_after_secs}' "$LAB/state/heartbeat.json")"; }
beat() { touch "$LAB/state/.last-watcher-beat"; [ -z "${1:-}" ] || touch -t "$(date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S)" "$LAB/state/.last-watcher-beat"; }
hv() { echo "  \$ fm-health-verdict.sh --home LAB $*"; $E bin/fm-health-verdict.sh --home "$LAB" "$@" | sed 's/^/  > /'; }
mon_enabled() { printf 'status=enabled at=%s\n' "$(date +%s)" > "$LAB/state/monitor-status"; }
snap() { (cd "$1" && find . -print0 | sort -z | xargs -0 stat -f '%N %m %z' | shasum | cut -c1-16); }

echo "== S1 live lock, no stale-grace config, real monitor read (uncovered in a lab)"
( sleep 100000 >/dev/null 2>&1 & echo $! > "$LAB/lockpid" ); echo "$(cat "$LAB/lockpid")" > "$LAB/state/.lock"
wd; hb; beat; hv
KEEP_MON=1
echo "== S2 stale-grace-secs=60 configured, monitor enabled -> expect ok fresh"
printf 'stale-grace-secs=60\n' > "$LAB/config/heartbeat"
hb; wd; mon_enabled; beat; hv
echo "== S3 --write records the same line"
hv --write; echo "  [state/health-verdict] $(cat "$LAB/state/health-verdict")"; ls -a "$LAB/state" | grep -c '^\.health-verdict\.' | sed 's/^/  [temp files left] /'
echo "== S4 read-only: a read without --write changes nothing in the home"
b=$(snap "$LAB"); hv >/dev/null; a=$(snap "$LAB"); echo "  [tree hash before] $b  [after] $a"
NS=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-nostate.XXXXXX"); mkdir "$NS/config"
$E FM_HOME=$NS bin/fm-health-verdict.sh --home "$NS" | sed 's/^/  > /'; echo "  [home with no state dir, after read] $(cd "$NS" && find . -mindepth 1 | tr '\n' ' ')"; rm -rf "$NS"
echo "== S5 heartbeat older than its bound (generated 200s ago, bound 75) -> stale"
jq ".generated_epoch = $(( $(date +%s) - 200 ))" "$LAB/state/heartbeat.json" > "$LAB/hb.tmp" && mv "$LAB/hb.tmp" "$LAB/state/heartbeat.json"; beat; hv
hb
echo "== S6 open work (real dispatch-log received goal) with a watcher beat 1000s old (bound 900) -> stale watcher-stale"
$E bin/fm-dispatch-log.sh received lab-hv-202611080000 --summary "lab health verdict goal" >/dev/null
tail -1 "$LAB/state/dispatch-log.tsv" | sed 's/^/  [dispatch-log] /'
beat 1000; hv
beat
echo "== S7 lock owner dies; real watchdog pass records dead -> dead lock-dead even with fresh heartbeat"
kill "$(cat "$LAB/lockpid")"; sleep 1; wd; hb; beat; hv
echo "== S8 no lock: watchdog records none; open goal -> dead none-open-work"
rm -f "$LAB/state/.lock"; wd; hb; beat; hv
echo "== S9 no lock, goal dispatched (resolved), away record -> dead none-away; then no away -> ok idle"
gid=$(tail -1 "$LAB/state/dispatch-log.tsv" | cut -f4)
$E bin/fm-dispatch-log.sh dispatched "$gid" --task lab-task >/dev/null
tail -1 "$LAB/state/dispatch-log.tsv" | sed 's/^/  [dispatch-log] /'
touch "$LAB/state/.afk"; hv; rm -f "$LAB/state/.afk"; hv
echo "== S10 mismatched lock instance (captain record alive=unconfirmed) -> unconfirmed"
sed -i '' 's/^alive=.*/alive=unconfirmed/' "$LAB/state/watchdog/captain"; hv
echo "== S11 usage errors"
$E bin/fm-health-verdict.sh --bogus >/dev/null 2>&1; echo "  [unknown arg exit] $?"
env -u FM_HOME bin/fm-health-verdict.sh >/dev/null 2>&1; echo "  [no home exit] $?"
