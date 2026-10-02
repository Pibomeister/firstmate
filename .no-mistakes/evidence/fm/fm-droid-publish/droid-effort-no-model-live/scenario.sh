#!/usr/bin/env bash
# Live: spawn a real Droid scout with --effort but no --model in a marked lab home;
# Droid's runtime settings must omit reasoningEffort while metadata keeps the request.
set -u
ROOT=$1
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
TT=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export FM_HOME="$LAB" TMUX_TMPDIR="$TT" TREEHOUSE_ROOT="$LAB/pool"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
ID=droid-eff; P="$LAB/projects/scratch"; mkdir -p "$P" "$LAB/data/$ID" "$LAB/pool"
git -C "$P" init -q && git -C "$P" -c user.name=x -c user.email=x@example.invalid commit --allow-empty -qm init
printf '# Task\nReply DONE and stop. Do not edit files.\n' >"$LAB/data/$ID/brief.md"
echo "== droid version: $(droid --version)"
echo "== fm-spawn.sh $ID <repo> --scout --harness droid --effort xhigh --backend tmux   (no --model)"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$P" --scout --harness droid --effort xhigh --backend tmux 2>&1; echo "spawn exit=$?"
echo "== Droid runtime settings: state/$ID.droid-settings.json"; jq . "$LAB/state/$ID.droid-settings.json"
echo "== keys"; jq '{has_model: has("model"), has_reasoningEffort: has("reasoningEffort")}' "$LAB/state/$ID.droid-settings.json"
echo "== task metadata"; grep -E '^(harness|model|effort)=' "$LAB/state/$ID.meta"
for i in $(seq 1 30); do T=$(sed -n 's/^window=//p' "$LAB/state/$ID.meta"); tmux capture-pane -p -t "$T" 2>/dev/null | grep -q . && break; sleep 1; done
sleep 10
echo "== Droid pane (live TUI)"; tmux capture-pane -p -t "$T" | sed '/^[[:space:]]*$/d' | head -20
"$ROOT/bin/fm-control.sh" "$ID" exit 2>&1 | tail -1
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null 2>&1
"$ROOT/bin/fm-teardown.sh" "$ID" >/dev/null 2>&1; echo "teardown exit=$?"
tmux kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
chmod -R u+w "$LAB"; rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
