#!/usr/bin/env bash
# Live driver: real cleanup script, real gh, git, lsof, tmux, real Orca list calls. Disposable lab home and clone.
set -u
ROOT=$1; SECRET=LIVE_SENTINEL_SECRET_93417
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB"; pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
ENVV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
C=$LAB/projects/firstmate
git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$C"
git -C "$C" remote set-url --push origin no_push
git -C "$C" config user.email t@t; git -C "$C" config user.name t
W=$LAB/wt; mkdir -p "$W"
mk() { # name branch prnum   : worktree at the real PR head
  git -C "$C" fetch -q origin "refs/pull/$3/head" && git -C "$C" worktree add -q -b "$2" "$W/$1" FETCH_HEAD; }
mk merged fm/fm-never-stall-reroute 94
mk closed fm/fm-monitoring-self-heal 60
mk open fm/fm-disk-alarms 97
mk dirty fm/fm-attended-selfwake 87
echo x >> "$W/dirty/README.md"
mk untracked fm/sw-m1d-issue-filing 76
echo x > "$W/untracked/notes.txt"
mk ignored fm/fm-early-handoff-trigger 75
printf '.env\n.work/\n.omc/\n' >> "$C/.git/info/exclude"
echo "TOKEN=$SECRET" > "$W/ignored/.env"; mkdir -p "$W/ignored/.work" "$W/ignored/.omc"; echo "$SECRET" > "$W/ignored/.work/a"; echo "$SECRET" > "$W/ignored/.omc/b"
mk ahead fm/sw-m1b-heartbeat 73
(cd "$W/ahead" && git commit -q --allow-empty -m "local work not on the PR")
mk livep fm/fm-main-park-test-fix 33
(cd "$W/livep" && exec sleep 300) & LIVEP=$!
mk tmuxw fm/fm-bash53-fix 12
TSOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
"$ROOT/bin/fm-lab-home.sh" tmux "$LAB" new-session -d -s w -c "$W/tmuxw" 'sleep 300'
mk nested fm/fm-quiet-recovery 8
git -C "$C" worktree add -q -b nested-child "$W/nested/.worktrees/child" HEAD
echo x > "$W/nested/.worktrees/child/child-untracked.txt"
echo '.worktrees/' >> "$C/.git/info/exclude"
git -C "$C" fetch -q origin refs/pull/95/head 2>/dev/null || true
# task-owned: worktree on merged PR with a task record
mk owned fm/fm-learnings-load 95
printf 'worktree=%s\n' "$W/owned" > "$LAB/state/liveowned.meta"
# unfetched head: a fresh clone with no pull ref, at the parent of PR 92-ish
echo "### status before"; git -C "$C" worktree list | sed "s#$LAB#\$LAB#"
echo; echo "### 1. DRY RUN"
"${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" --dry-run 2>&1 | sed "s#$LAB#\$LAB#" | tee "$LAB/dry.txt"
echo "worktrees still registered after dry run: $(git -C "$C" worktree list | wc -l | tr -d ' ')"; echo "cursor written by dry run: $([ -e "$LAB/state/worktree-cleanup.cursor" ] && echo yes || echo no)"
echo; echo "### 2. REAL RUN"
for pass in 1 2 3 4 5 6 7 8; do echo "--- pass $pass"; S=$(date +%s); "${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" 2>&1 | sed "s#$LAB#\$LAB#" | tee -a "$LAB/real.txt"; echo "(pass took $(( $(date +%s)-S ))s)"; done
echo; echo "### 3. STATE AFTER"
for d in merged closed open dirty untracked ignored ahead livep tmuxw nested nested/.worktrees/child owned; do printf '%-26s %s\n' "$d" "$([ -d "$W/$d" ] && echo KEPT || echo removed)"; done
echo "dirty edit survives: $(git -C "$W/dirty" status --porcelain 2>/dev/null)"
echo "untracked survives: $(cat "$W/untracked/notes.txt")"
echo "child file survives: $(cat "$W/nested/.worktrees/child/child-untracked.txt")"
echo "branches kept: $(git -C "$C" branch --list fm/fm-never-stall-reroute fm/fm-monitoring-self-heal fm/fm-early-handoff-trigger | tr -s ' \n' ' ')"
echo "registered after prune:"; git -C "$C" worktree list --porcelain | grep ^worktree | sed "s#$LAB#\$LAB#"
echo "prunable leftovers: $(git -C "$C" worktree list --porcelain | grep -c prunable)"
echo "secret leaks in stdout or log: $(cat "$LAB/dry.txt" "$LAB/real.txt" "$LAB/state/worktree-cleanup.log" | grep -c "$SECRET")"
echo "log lines: $(wc -l < "$LAB/state/worktree-cleanup.log" | tr -d ' ')"
echo; echo "### 4. LIVE-WORKER RELEASE: stop the process and terminal, run again"
kill $LIVEP 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" kill-server 2>/dev/null; sleep 1
for pass in 1 2 3 4 5 6; do "${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" 2>&1 | grep -E 'livep|tmuxw' | sed "s#$LAB#\$LAB#"; done
echo; echo "### 5. FETCH: single-branch clone, worktree at PR 60 base, PR head absent locally"
P=$(gh api repos/Pibomeister/firstmate/pulls/60/commits --jq '.[0].parents[0].sha'); H=a5b1ab3840870141fdc2d3eae5eb70f6fdc4cd6c
C2=$LAB/projects/second; git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$C2"; git -C "$C2" remote set-url --push origin no_push
git -C "$C2" worktree prune; rm -f "$LAB/state/liveowned.meta"
git -C "$C2" worktree add -q -b fm/fm-monitoring-self-heal "$W/fetchme" "$P"
echo "head present before: $(git -C "$C2" cat-file -e "$H^{commit}" 2>/dev/null && echo yes || echo no)"
"${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" "$C2" 2>&1 | sed "s#$LAB#\$LAB#"
echo "worktree: $([ -d "$W/fetchme" ] && echo KEPT || echo removed)"
echo; echo "### 6. WATCHER: real fm-watch.sh one cycle, FM_WORKTREE_CLEANUP=0 then enabled"
C3=$LAB/projects/third; rm -rf "$C2" "$C"; 
git clone -q --filter=blob:none --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$C3"; git -C "$C3" remote set-url --push origin no_push
git -C "$C3" fetch -q origin refs/pull/94/head; git -C "$C3" worktree add -q -b fm/fm-never-stall-reroute "$W/watched" FETCH_HEAD
rm -f "$LAB/state/worktree-cleanup.log" "$LAB/state/worktree-cleanup.cursor"
"${ENVV[@]}" FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off FM_WORKTREE_CLEANUP=0 "$ROOT/bin/fm-watch.sh" > "$LAB/w0.out" 2>&1; echo "disabled exit=$? worktree: $([ -d "$W/watched" ] && echo KEPT || echo removed) stamp: $([ -e "$LAB/state/.last-worktree-cleanup" ] && echo yes || echo no)"
"${ENVV[@]}" FM_WATCH_ONCE=1 FM_WEDGE_ALARM_CHANNEL=off "$ROOT/bin/fm-watch.sh" > "$LAB/w1.out" 2>&1; echo "enabled exit=$? worktree: $([ -d "$W/watched" ] && echo KEPT || echo removed) stamp: $([ -e "$LAB/state/.last-worktree-cleanup" ] && echo yes || echo no)"
echo "watcher stdout mentions cleanup: $(grep -c worktree-cleanup "$LAB/w1.out")"
sed "s#$LAB#\$LAB#" "$LAB/state/worktree-cleanup.log"
git -C "$C3" worktree list --porcelain | grep ^worktree | sed "s#$LAB#\$LAB#"
kill $LIVEP 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
