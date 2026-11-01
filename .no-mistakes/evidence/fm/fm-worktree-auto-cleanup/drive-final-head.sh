#!/usr/bin/env bash
# Final-head live driver. Real cleanup script, real fm-watch.sh, real gh against
# Pibomeister/firstmate (read-only), real git, lsof, tmux, and a real Orca runtime
# isolated under a throwaway HOME. Aborts unless that runtime lists zero worktrees.
set -u
ROOT=$1; OH=/private/tmp/fmo-nm-t3; SECRET=LIVE_SENTINEL_SECRET_93417
rm -rf "$OH"; mkdir -p "$OH"
GHT=$(gh auth token)
PRS=$(gh pr list -R Pibomeister/firstmate --state all --limit 300 --json number,state,headRefName,headRepositoryOwner,isCrossRepository)
pick() { # state index -> "number branch" for a same-repo branch that has exactly one PR
  printf %s "$PRS" | jq -r --arg s "$1" --argjson i "$2" '
    group_by(.headRefName) | map(select(length==1 and .[0].state==$s and .[0].isCrossRepository==false)|.[0])
    | sort_by(-.number) | .[$i] | "\(.number) \(.headRefName)"'; }
LAB=$OH/lab; mkdir -p "$LAB"; "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
HOME=$OH orca serve --no-pairing --port 46973 --json > "$OH/serve.log" 2>&1 & SP=$!
LP=
finish() { [ -z "$LP" ] || kill "$LP" 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" kill-server 2>/dev/null; kill $SP 2>/dev/null; sleep 2; pkill -f "$OH" 2>/dev/null; rm -rf "$OH"; echo "### isolated Orca stopped, lab removed: $([ -e "$OH" ] && echo NO || echo yes)"; }
trap finish EXIT
O() { HOME=$OH orca "$@"; }
for i in $(seq 1 30); do r=$(O worktree list --limit 100000 --json 2>/dev/null); [ "$(printf %s "$r" | jq -r .ok 2>/dev/null)" = true ] && break; r=; sleep 5; done
[ -n "$r" ] && [ "$(printf %s "$r" | jq '.result.worktrees|length')" = 0 ] || { echo "ABORT Orca not isolated or not ready"; exit 1; }
echo "### isolated Orca ready, worktrees=0"
ENVV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE HOME="$OH" GH_TOKEN="$GHT" FM_HOME="$LAB")
S() { sed "s#$OH#\$OH#g"; }
R() { "${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" "$@" 2>&1 | S; }
C=$LAB/projects/firstmate
git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$C"
git -C "$C" remote set-url --push origin no_push
git -C "$C" config user.email t@t; git -C "$C" config user.name t
printf '.env\n.work/\n.omc/\n.worktrees/\n' >> "$C/.git/info/exclude"
W=$LAB/wt; mkdir -p "$W"
HEAD_N=
mk() { # dir state idx
  set -- "$1" $(pick "$2" "$3")
  git -C "$C" fetch -q origin "refs/pull/$2/head" && git -C "$C" worktree add -q -b "$3" "$W/$1" FETCH_HEAD && echo "fixture $1 -> PR #$2 $3"; }
mk m_merged MERGED 0; mk c_closed CLOSED 0; mk open OPEN 0
mk tracked MERGED 1; echo x >> "$W/tracked/README.md"
mk untracked MERGED 2; echo keep > "$W/untracked/notes.txt"
mk i_ignored MERGED 3; echo "TOKEN=$SECRET" > "$W/i_ignored/.env"; mkdir -p "$W/i_ignored/.work" "$W/i_ignored/.omc"; echo "$SECRET" > "$W/i_ignored/.work/a"; echo "$SECRET" > "$W/i_ignored/.omc/b"
mk ahead MERGED 4; git -C "$W/ahead" commit -q --allow-empty -m "local work not on the PR"
mk liveproc MERGED 5; (cd "$W/liveproc" && exec sleep 900) & LP=$!
mk tmuxpane MERGED 6; "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" new-session -d -s w -c "$W/tmuxpane" 'sleep 900'
mk parent MERGED 7; git -C "$C" worktree add -q -b lab-nested-child "$W/parent/.worktrees/child" HEAD; echo childdirt > "$W/parent/.worktrees/child/c.txt"
mk taskrec MERGED 8; printf 'worktree=%s\n' "$W/taskrec" > "$LAB/state/liveowned.meta"
mk locked MERGED 9; git -C "$C" worktree lock "$W/locked"
git -C "$C" worktree add -q -b lab/no-pr-branch "$W/nopr" main
inv() { (cd "$W" && ls -A | tr '\n' ' '); echo; git -C "$C" worktree list | S; }
echo; echo "### 1. BEFORE"; inv
echo; echo "### 2. DRY RUN (several passes cannot move a cursor; one pass, then compare)"
b=$(git -C "$C" worktree list --porcelain | shasum); R --dry-run | tee "$OH/dry.txt"
echo "worktree list unchanged: $([ "$b" = "$(git -C "$C" worktree list --porcelain | shasum)" ] && echo yes || echo NO)  cursor written: $([ -e "$LAB/state/worktree-cleanup.cursor" ] && echo YES || echo no)"
echo; echo "### 3. REAL PASSES, driven until two full rotations"
for p in 1 2 3 4 5 6; do s=$(date +%s); echo "--- pass $p"; R | tee -a "$OH/real.txt"; echo "(pass took $(( $(date +%s)-s ))s, rc=${PIPESTATUS[0]})"; done
echo; echo "### 4. STATE AFTER"
for d in m_merged c_closed i_ignored open tracked untracked ahead liveproc tmuxpane parent parent/.worktrees/child taskrec locked nopr; do printf '%-26s %s\n' "$d" "$([ -d "$W/$d" ] && echo KEPT || echo removed)"; done
echo "tracked edit survives: $(git -C "$W/tracked" status --porcelain)"; echo "untracked survives: $(cat "$W/untracked/notes.txt")"; echo "nested child file survives: $(cat "$W/parent/.worktrees/child/c.txt")"
echo "local branches kept: $(for x in m_merged c_closed i_ignored; do grep -E "remove .*/$x " "$OH/real.txt" >/dev/null && echo -n "$x "; done)"; git -C "$C" branch | wc -l | tr -d ' '
echo "prunable registrations: $(git -C "$C" worktree list --porcelain | grep -c prunable)"
echo "secret in any decision output: $(cat "$OH/dry.txt" "$OH/real.txt" | grep -c "$SECRET")"
echo "secret in state log: $(grep -c "$SECRET" "$LAB/state/worktree-cleanup.log")"
echo "log line per decision sample:"; S < "$LAB/state/worktree-cleanup.log" | sort | uniq -c | sort -rn | head -30
echo; echo "### 5. WATCHER: real fm-watch.sh one-shot cycles"
WATCH() { "${ENVV[@]}" FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off "$@" bash "$ROOT/bin/fm-watch.sh" > "$OH/w.out" 2>&1; echo "rc=$? bytes_printed=$(wc -c < "$OH/w.out" | tr -d ' ')"; }
set -- $(pick MERGED 10); git -C "$C" fetch -q origin "refs/pull/$1/head"; git -C "$C" worktree add -q -b "$2" "$W/z_watcher" FETCH_HEAD; echo "fixture z_watcher -> PR #$1 $2"
LOG=$LAB/state/worktree-cleanup.log; ST=$LAB/state/.last-worktree-cleanup
for c in 1 2 3 4; do rm -f "$ST"; n=$(wc -l < "$LOG"); s=$(date +%s); echo "cycle $c: $(WATCH) secs=$(( $(date +%s)-s )) new_log_lines=$(( $(wc -l < "$LOG")-n )) stamped=$([ -e "$ST" ] && echo yes || echo no)"; [ -d "$W/z_watcher" ] || break; done
echo "z_watcher: $([ -d "$W/z_watcher" ] && echo KEPT || echo removed)"; grep z_watcher "$LOG" | S | tail -2
n=$(wc -l < "$LOG"); s=$(date +%s); echo "fresh stamp, next cycle: $(WATCH) secs=$(( $(date +%s)-s )) new_log_lines=$(( $(wc -l < "$LOG")-n ))"
rm -f "$ST"; n=$(wc -l < "$LOG"); echo "kill switch FM_WORKTREE_CLEANUP=0: $(WATCH FM_WORKTREE_CLEANUP=0) new_log_lines=$(( $(wc -l < "$LOG")-n )) stamped=$([ -e "$ST" ] && echo YES || echo no)"
rm -f "$ST" "$LAB/state/.watch-triage.log"; echo "failed pass, FM_WATCH_HELPER_BUDGET=1: $(WATCH FM_WATCH_HELPER_BUDGET=1) stamped=$([ -e "$ST" ] && echo yes || echo NO)"; grep -h "worktree cleanup" "$LAB/state/.watch-triage.log" | tail -1
n=$(wc -l < "$LOG"); echo "next cycle after failed pass: $(WATCH) new_log_lines=$(( $(wc -l < "$LOG")-n ))"
echo; echo "### 6. PR HEAD ABSENT LOCALLY: fetch from the pull ref"
set -- $(pick CLOSED 1); N=$1; B=$2
F=$LAB/other/full; git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$F"; git -C "$F" remote set-url --push origin no_push
PH=$(gh api "repos/Pibomeister/firstmate/pulls/$N" --jq .head.sha); P=$(gh api "repos/Pibomeister/firstmate/commits/$PH" --jq '.parents[0].sha')
git -C "$F" fetch -q origin "$P" 2>/dev/null; git -C "$F" worktree add -q -b "$B" "$LAB/other/fw" "$P"
echo "PR #$N head present locally: $(git -C "$F" cat-file -e "$PH^{commit}" 2>/dev/null && echo yes || echo no)"
echo "--- fetch blocked (git https transport disabled)"; "${ENVV[@]}" GIT_ALLOW_PROTOCOL=file "$ROOT/bin/fm-worktree-cleanup.sh" "$F" 2>&1 | S; echo "worktree: $([ -d "$LAB/other/fw" ] && echo KEPT || echo removed)"
echo "--- fetch allowed"; R "$F"; echo "head present: $(git -C "$F" cat-file -e "$PH^{commit}" 2>/dev/null && echo yes || echo no)  worktree: $([ -d "$LAB/other/fw" ] && echo KEPT || echo removed)"
echo; echo "### 7. ORCA: isolated real runtime, target clone only"
OC=$LAB/other/oc; git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$OC"; git -C "$OC" remote set-url --push origin no_push
printf '.env\n.work/\n' >> "$OC/.git/info/exclude"
O repo add --path "$OC" --json | jq -c '{repo_added:.ok}'
closeterms() { for H in $(O terminal list --limit 1000 --json | jq -r '.result.terminals[].handle'); do O terminal close --terminal "$H" --json >/dev/null; done; sleep 3; }
ocreate() { # name state idx
  set -- "$1" $(pick "$2" "$3"); git -C "$OC" fetch -q origin "refs/pull/$2/head"; git -C "$OC" branch -f "base-$2" FETCH_HEAD
  O worktree create --name "$1" --repo "path:$OC" --branch "$3" --base-branch "base-$2" --setup skip --json > "$OH/c.json" 2>&1
  jq -c --arg n "$1" '{created:$n,ok,e:.error}' "$OH/c.json"; }
ocreate o1 MERGED 11; OW=$(git -C "$OC" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/o1$'); echo "orca worktree: $OW" | S
echo "--- live Orca terminal"; O terminal list --limit 1000 --json | jq -c '[.result.terminals[].connected]'; R --dry-run "$OC"; R "$OC"; echo "dir: $([ -d "$OW" ] && echo KEPT || echo removed)"
closeterms
echo "--- no terminal, dirty"; echo x >> "$OW/README.md"; R "$OC"; echo "dir: $([ -d "$OW" ] && echo KEPT || echo removed)"; git -C "$OW" checkout -q -- README.md
echo "--- no terminal, dry run"; R --dry-run "$OC"; echo "dir: $([ -d "$OW" ] && echo KEPT || echo removed)"
echo "--- no terminal, clean, ignored .env inside: the regression"; echo "TOKEN=$SECRET" > "$OW/.env"
s=$(date +%s); R "$OC" | tee "$OH/orca.txt"; echo "pass took $(( $(date +%s)-s ))s; right after the pass dir: $([ -e "$OW" ] && echo KEPT || echo removed)"
echo "git registrations: $(git -C "$OC" worktree list --porcelain | grep -c ^worktree)  prunable: $(git -C "$OC" worktree list --porcelain | grep -c prunable)  orca lists: $(O worktree list --limit 1000 --json | jq -c '[.result.worktrees[].path]' | S)"
echo "secret in output: $(grep -c "$SECRET" "$OH/orca.txt")"
echo "--- second pass, no stale line"; R "$OC"
echo "--- runtime stopped: cannot read Orca, nothing removed"
git -C "$OC" fetch -q origin "refs/pull/$(pick MERGED 12 | cut -d' ' -f1)/head"; git -C "$OC" worktree add -q -b "$(pick MERGED 12 | cut -d' ' -f2)" "$LAB/other/odown" FETCH_HEAD
kill $SP 2>/dev/null; sleep 3
( "${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" "$OC" 2>&1 | S ) & RP=$!
( sleep 150; kill $RP 2>/dev/null; echo "watchdog stopped the pass" ) & WD=$!
wait $RP; kill $WD 2>/dev/null
echo "dir: $([ -d "$LAB/other/odown" ] && echo KEPT || echo removed)"
echo "### DONE"
