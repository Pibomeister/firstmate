#!/usr/bin/env bash
# Real Orca runtime isolated under a throwaway HOME. Aborts unless it lists zero worktrees.
set -u
ROOT=$1; OH=/private/tmp/fmo-nm-orca-01M69; rm -rf /private/tmp/fmo-nm-orca-01M69; mkdir -p $OH
GHT=$(gh auth token)
LAB=$OH/lab; mkdir -p $LAB; "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
HOME=$OH orca serve --no-pairing --port 46971 --json > $OH/serve.log 2>&1 & SP=$!
finish() { kill $SP 2>/dev/null; sleep 2; pkill -f "$OH" 2>/dev/null; rm -rf /private/tmp/fmo-nm-orca-01M69; echo "isolated Orca stopped, home removed"; }
trap finish EXIT
O() { HOME=$OH orca "$@"; }
ok=0; for i in $(seq 1 30); do r=$(O worktree list --limit 100000 --json 2>/dev/null); [ "$(printf %s "$r" | jq -r .ok 2>/dev/null)" = true ] && { ok=1; break; }; perl -e 'select(undef,undef,undef,5)'; done
echo "runtime ready=$ok after ${i} polls; worktrees=$(printf %s "$r" | jq '.result.worktrees|length')"
[ $ok = 1 ] && [ "$(printf %s "$r" | jq '.result.worktrees|length')" = 0 ] || { echo "ABORT not isolated or not ready"; O worktree list --json 2>&1 | cut -c1-400; cut -c1-300 $OH/serve.log | tail -5; exit 1; }
C=$LAB/projects/repo; git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$C"; git -C "$C" remote set-url --push origin no_push
git -C "$C" fetch -q origin refs/pull/60/head; git -C "$C" branch pr60base FETCH_HEAD
O repo add --path "$C" --json | jq -c '{ok}'
O worktree create --name iso60 --repo "path:$C" --branch fm/fm-monitoring-self-heal --base-branch pr60base --setup skip --json > $OH/c.json 2>&1; jq -c '{ok,e:.error}' $OH/c.json 2>/dev/null || cut -c1-400 $OH/c.json
WT=$(git -C "$C" worktree list --porcelain | grep ^worktree | sed 's/worktree //' | grep -v "^$C$" | head -1); echo "linked: ${WT#$OH}"; git -C "$WT" rev-parse --short HEAD; git -C "$WT" branch --show-current
R() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE HOME=$OH GH_TOKEN=$GHT FM_HOME="$LAB" "$ROOT/bin/fm-worktree-cleanup.sh" "$@" "$C" 2>&1 | sed "s#$OH#\$OH#"; }
echo "orca terminals now: $(O terminal list --limit 1000 --json | jq -c '[.result.terminals[].worktreePath]' | sed "s#$OH#\$OH#g")"
echo "### live Orca terminal"; T=$(O terminal create --worktree "path:$WT" --json 2>&1); printf %s "$T" | jq -c '{ok,h:.result.terminal.handle,e:.error}' 2>/dev/null || printf %s "$T" | cut -c1-300
echo "orca terminals now: $(O terminal list --limit 1000 --json | jq -c '[.result.terminals[].worktreePath]' | sed "s#$OH#\$OH#g")"
R --dry-run
echo "terminal state: $(O terminal list --limit 1000 --json | jq -c '[.result.terminals[]|{connected,orphaned}]')"
for H in $(O terminal list --limit 1000 --json | jq -r '.result.terminals[].handle'); do O terminal close --terminal "$H" --json | jq -c '{closed:.ok}'; done
perl -e 'select(undef,undef,undef,3)'
echo "### after terminal closed, dirty"; echo x >> "$WT/README.md"; R; echo "kept: $([ -d "$WT" ] && echo yes || echo no)"; git -C "$WT" checkout -q -- README.md
echo "### direct: same command the script runs, three separate trials"
try() {
  n=$1
  [ "$n" = 1 ] || { O worktree create --name iso$n --repo "path:$C" --branch fm/fm-monitoring-self-heal --base-branch pr60base --setup skip --json >/dev/null 2>&1; 
    WT=$(git -C "$C" worktree list --porcelain | grep ^worktree | sed 's/worktree //' | grep -v "^$C$" | head -1); for H in $(O terminal list --limit 1000 --json | jq -r '.result.terminals[].handle'); do O terminal close --terminal "$H" --json >/dev/null; done; perl -e 'select(undef,undef,undef,3)'; }
  S=$(date +%s); out=$(O worktree rm --worktree "path:$WT" --json 2>&1); rc=$?
  echo "trial $n rc=$rc took=$(( $(date +%s)-S ))s out=$(printf %s "$out" | jq -c '{ok,e:.error,w:.warning}' 2>/dev/null || printf %s "$out" | cut -c1-300)"
  for t in 0 10 30 60; do perl -e "select(undef,undef,undef,$t)"; echo "  +${t}s dir=$([ -d "$WT" ] && echo present || echo gone) contents=$(ls -A "$WT" 2>/dev/null | wc -l | tr -d ' ') gitlist=$(git -C "$C" worktree list --porcelain | grep -c ^worktree) orca=$(O worktree list --limit 1000 --json 2>/dev/null | jq -c '.result.worktrees|length') branch=$(git -C "$C" branch --list fm/fm-monitoring-self-heal | wc -l | tr -d ' ')"; done
  [ -d "$WT" ] && git -C "$C" worktree remove --force "$WT" 2>/dev/null; git -C "$C" worktree prune; git -C "$C" branch -q -D fm/fm-monitoring-self-heal 2>/dev/null
}
try 1; try 2; try 3
echo "### through the script, wait, then second pass"
O worktree create --name iso4 --repo "path:$C" --branch fm/fm-monitoring-self-heal --base-branch pr60base --setup skip --json >/dev/null 2>&1
WT=$(git -C "$C" worktree list --porcelain | grep ^worktree | sed 's/worktree //' | grep -v "^$C$" | head -1); for H in $(O terminal list --limit 1000 --json | jq -r '.result.terminals[].handle'); do O terminal close --terminal "$H" --json >/dev/null; done; perl -e 'select(undef,undef,undef,3)'
R; echo "dir now: $([ -d "$WT" ] && echo KEPT || echo removed)"
perl -e 'select(undef,undef,undef,30)'; echo "after 30s dir: $([ -d "$WT" ] && echo KEPT || echo removed) orca=$(O worktree list --limit 1000 --json | jq -c '[.result.worktrees[].path]' | sed "s#$OH#\$OH#g")"; git -C "$C" worktree list --porcelain | grep ^worktree | sed "s#$OH#\$OH#"
echo "--- second pass"; R; echo "dir: $([ -d "$WT" ] && echo KEPT || echo removed)"; git -C "$C" worktree list --porcelain | grep ^worktree | sed "s#$OH#\$OH#"
echo "branch: $(git -C "$C" branch --list fm/fm-monitoring-self-heal | tr -d ' +')"
