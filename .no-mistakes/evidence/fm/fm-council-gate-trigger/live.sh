#!/usr/bin/env bash
# Live: drive the real bin/fm-watch.sh (one cycle) in a disposable lab home, with the real `ak` on PATH.
set -u
W={run-worktree}
cd "$W"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 9
echo "LAB=$LAB"
run_watch() {  # label
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off \
    bash bin/fm-watch.sh > "$LAB/out.$1" 2> "$LAB/err.$1"
  echo "--- watcher[$1] exit=$?"; echo "stdout:"; cat "$LAB/out.$1"; echo "stderr:"; grep -i 'council\|watcher:' "$LAB/err.$1" || true
}
setup_gate() {  # task project age-secs
  local t=$1 p=$2 age=$3 now; now=$(date +%s)
  mkdir -p "$LAB/data/$t"
  printf 'project=%s/projects/%s\nkind=ship\n' "$LAB" "$p" > "$LAB/state/$t.meta"
  printf 'F1 finding: the PR lacks a regression test for X\n' > "$LAB/data/$t/nm-r1-findings.txt"
  printf '# Task\n## Captain'"'"'s intent\nship the widget\n## Firstmate spec\nbuild it\n' > "$LAB/data/$t/brief.md"
  printf 'needs-decision [at=%s] [key=nm-r1-review]: ask-user findings=F1 file=%s\n' "$((now-age))" "$LAB/data/$t/nm-r1-findings.txt" > "$LAB/state/$t.status"
}
printf '{}\n' > "$LAB/roster.json"; chmod 600 "$LAB/roster.json"
printf 'roster=%s\nprojects=ShipContent,Casco,AgentKit,firstmate\n' "$LAB/roster.json" > "$LAB/config/gate-council"
echo "== config/gate-council"; cat "$LAB/config/gate-council"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" FM_AFK_MODE=away bash bin/fm-afk-contract.sh enter --words 'away live test' >/dev/null && echo "away record entered"

echo; echo "===== S1: hour-old gate on firstmate (listed); fresh gate on Casco (40 min); gate on Goodword (unlisted, 2h)"
setup_gate fm-old firstmate 4000
setup_gate casco-young Casco 2400
setup_gate goodword-old Goodword 7200
run_watch 1
echo "== claims after cycle 1"; cat "$LAB/state/.away-gate-council-claims" 2>/dev/null || echo "(none)"
dir=$(ls -d "$LAB"/data/fm-old/gate-council-* 2>/dev/null | head -1); echo "run dir: $dir"
for i in $(seq 1 150); do [ -f "$dir/exit" ] && break; sleep 0.2; done
echo "== card.json (sent to real ak)"; cat "$dir/card.json"
echo "== task-intent.md"; cat "$dir/task-intent.md"
echo "== real ak log"; cat "$dir/log"; echo "== exit: $(cat "$dir/exit" 2>/dev/null)"
ls "$LAB"/data/casco-young "$LAB"/data/goodword-old
echo; echo "===== S1b: next cycle surfaces the finished run as one wake"
run_watch 2
echo "== wake queue"; cat "$LAB/state/.wake-queue" 2>/dev/null
echo "== claims"; cat "$LAB/state/.away-gate-council-claims"
run_watch 3
echo "== wake queue after cycle 3 (no repeat expected)"; grep -c 'gate council ruled' "$LAB/state/.wake-queue"

echo; echo "===== S2 (adversarial): roster missing -> watcher must keep running, council skipped"
printf 'roster=%s/nope.json\nprojects=firstmate\n' "$LAB" > "$LAB/config/gate-council"
setup_gate fm-old2 firstmate 5000
run_watch 4
ls -d "$LAB"/data/fm-old2/gate-council-* 2>/dev/null || echo "no council run dir for fm-old2 (expected)"
echo "===== S2b: invalid after-secs"
printf 'roster=%s\nprojects=firstmate\nafter-secs=abc\n' "$LAB/roster.json" > "$LAB/config/gate-council"
run_watch 5
echo "===== S3: present posture (away record cleared) -> no council"
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" bash bin/fm-afk-contract.sh exit >/dev/null 2>&1 || rm -f "$LAB/state/.afk-contract"
printf 'roster=%s\nprojects=firstmate\n' "$LAB/roster.json" > "$LAB/config/gate-council"
run_watch 6
ls -d "$LAB"/data/fm-old2/gate-council-* 2>/dev/null || echo "no council run dir for fm-old2 while present (expected)"
bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; echo "lab removed"
