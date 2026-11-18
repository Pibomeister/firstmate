#!/usr/bin/env bash
# Live adversarial: real bin/fm-control.sh relaunch of a second mate on a private
# lab tmux server. While the relaunch is in its launch phase, a concurrent actor
# removes the task record and closes the endpoint (the incident's shape). Expect:
# relaunch fails, the open handoff relaunch request stays open, and a durable
# record is left for recovery.
set -u
W=$1
L=$(cd "$(mktemp -d /tmp/fmL.XXXX)" && pwd -P); P="$L/p"; mkdir -p "$P"
"$W/bin/fm-lab-home.sh" create "$P" >/dev/null
TD=$("$W/bin/fm-lab-home.sh" tmux-dir "$P")
UH="$L/uh"; mkdir -p "$UH/.claude" "$UH/Library/Keychains"; : > "$UH/Library/Keychains/login.keychain-db"
cleanup() { "$W/bin/fm-lab-home.sh" tmux "$P" kill-server >/dev/null 2>&1; "$W/bin/fm-lab-home.sh" teardown "$P" >/dev/null 2>&1; chmod -R u+w "$L" 2>/dev/null; rm -rf "$L"; }
trap cleanup EXIT
ID=smlive
# second-mate home: a linked worktree of a lab-owned repo
git init -q "$L/repo"; git -C "$L/repo" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$L/repo" worktree add -q -b sm-branch "$L/sm" >/dev/null
mkdir -p "$L/sm/state" "$L/sm/data" "$L/sm/bin"; printf '%s\n' "$ID" > "$L/sm/.fm-secondmate-home"; printf '# agents\n' > "$L/sm/AGENTS.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$L/sm/.fm-secondmate-parent"
mkdir -p "$P/config" "$P/data/$ID" "$P/state"
printf 'claude default default\n' > "$P/config/secondmate-harness"
printf '# secondmate charter (lab)\nIdle and wait.\n' > "$P/data/$ID/brief.md"
T() { "$W/bin/fm-lab-home.sh" tmux "$P" "$@"; }
T new-session -d -s fmses -n "fm-$ID" -c "$L/sm" /bin/zsh -f
{ echo "window=fmses:fm-$ID"; echo "endpoint_task_id=$ID"; echo "worktree=$L/sm"; echo "project=$L/sm"
  echo "harness=claude"; echo "kind=secondmate"; echo "mode=secondmate"; echo "yolo=off"
  echo "model=default"; echo "effort=default"; echo "home=$L/sm"; echo "backend=tmux"; } > "$P/state/$ID.meta"
cp "$P/state/$ID.meta" "$L/meta.before"
ST="$P/state/$ID.status"
printf 'blocked [key=handoff-relaunch] [at=1]: second mate %s wrote its handoff for a planned fresh start and waits to be relaunched once; handoff=%s/sm/data/handoff.md sha256=0\n' "$ID" "$L" > "$ST"
printf 'done [at=2]: corr=abc reply delivered\n' >> "$ST"
openset() { bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" secondmate' _ "$W" "$ST" 2>/dev/null | cut -f1,2; }
echo "### before: parent open decisions: [$(openset)]"
echo "### pane command before: $(T display-message -p -t "fmses:fm-$ID" '#{pane_current_command}')"
start=$(date +%s)
( for i in $(seq 1200); do
    if grep -q '^phase=launching' "$P/state/$ID.control-relaunch" 2>/dev/null; then
      rm -f "$P/state/$ID.meta"; T kill-window -t "fmses:fm-$ID" >/dev/null 2>&1
      echo "### fault injected at phase=launching after $(( $(date +%s)-start ))s: record removed, endpoint closed"; exit 0
    fi; sleep 0.05; done; echo "### fault NOT injected (never saw phase=launching)" ) &
fp=$!
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
  TMUX_TMPDIR="$TD" FM_HOME="$P" HOME="$UH" CLAUDE_CONFIG_DIR="$UH/.claude" FM_SPAWN_NO_GUARD=1 \
  timeout 600 "$W/bin/fm-control.sh" "$ID" relaunch --note "lab live relaunch"; rc=$?
wait $fp
echo "### fm-control relaunch exit=$rc elapsed=$(( $(date +%s)-start ))s"
echo "### pane command after: $(T display-message -p -t "fmses:fm-$ID" '#{pane_current_command}' 2>&1)"
echo "### after: parent open decisions: [$(openset)]"
echo "### parent status file"; cat "$ST"
echo "### record present after rollback: $([ -f "$P/state/$ID.meta" ] && echo yes || echo NO)"
echo "### restored record equals the checkpoint copy of the prior record: $(cmp -s "$P/state/$ID.meta" "$P/state/$ID.control-relaunch.meta-prior" && echo yes || echo no)"
echo "### journal:"; grep -E '^(phase|rollback)=' "$P/state/$ID.control-relaunch" 2>/dev/null
