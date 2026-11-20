#!/usr/bin/env bash
set -u
W={run-worktree}
cd "$W"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 9
S=/tmp/fmgc-scripts/seat.sh
cat > "$LAB/roster.json" <<J
{"pair":[{"seat":"a","chain":[{"actor":"local-a","lineage":["local-a"],"command":["$S"]}]},
         {"seat":"b","chain":[{"actor":"local-b","lineage":["local-b"],"command":["$S"]}]}],
 "veto":{"seat":"veto","chain":[{"actor":"local-v","lineage":["local-v"],"command":["$S"]}]}}
J
chmod 600 "$LAB/roster.json"
printf 'roster=%s\nprojects=ShipContent,Casco,AgentKit,firstmate\n' "$LAB/roster.json" > "$LAB/config/gate-council"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" FM_AFK_MODE=away bash bin/fm-afk-contract.sh enter --words 'away live test' >/dev/null
now=$(date +%s); t=fm-old; mkdir -p "$LAB/data/$t"
printf 'project=%s/projects/firstmate\nkind=ship\n' "$LAB" > "$LAB/state/$t.meta"
printf 'F1 finding: the PR lacks a regression test for X\n' > "$LAB/data/$t/nm-r1-findings.txt"
printf '# Task\n## Captain'"'"'s intent\nship the widget\n' > "$LAB/data/$t/brief.md"
printf 'needs-decision [at=%s] [key=nm-r1-review]: ask-user findings=F1 file=%s\n' "$((now-3700))" "$LAB/data/$t/nm-r1-findings.txt" > "$LAB/state/$t.status"
cp "$LAB/state/$t.status" "$LAB/status.before"
w() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off bash bin/fm-watch.sh 2>"$LAB/err.$1"; echo "watcher[$1] exit=$?"; grep -i council "$LAB/err.$1"; }
w 1
dir=$(ls -d "$LAB"/data/$t/gate-council-*); for i in $(seq 1 300); do [ -f "$dir/exit" ] && break; sleep 0.2; done
echo "== real ak log"; cat "$dir/log"; echo "== exit=$(cat "$dir/exit")"
echo "== record.json (top-level fields)"; grep -E '^  "(schema|outcome|choice|card_id|id)"' "$dir/record.json" 2>/dev/null || head -40 "$dir/record.json"
w 2
echo "== council wake"; grep 'gate council ruled' "$LAB/state/.wake-queue"
echo "== status log unchanged (gate not answered)?"; cmp "$LAB/status.before" "$LAB/state/$t.status" && echo "yes, unchanged"
bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; echo lab removed
