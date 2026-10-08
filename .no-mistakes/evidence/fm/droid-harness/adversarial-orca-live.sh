#!/usr/bin/env bash
# Adversarial live Orca scenarios for the Droid-only contribution, driven
# against real Orca terminals and real droid/claude CLIs in a disposable home.
# Usage: ROOT=<worktree> bash adversarial-orca-live.sh
set -u
ROOT=${ROOT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-adv-orca.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
PROJECT="${TMPDIR:-/tmp}/fm-droid-orca-scratch-repo-$(id -u)"
HOME_DIR="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || exit 1
export FM_HOME="$HOME_DIR"
D="droid-adv-$$" C="claude-adv-$$"
rc=0
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; rc=1; }
wait_for() { local n=0; while [ $n -lt "${2:-240}" ]; do bash -c "$1" && return 0; n=$((n+1)); sleep 0.5; done; return 1; }

mkdir -p "$PROJECT" "$HOME_DIR/data/$D" "$HOME_DIR/data/$C" "$HOME_DIR/state" "$HOME_DIR/config"
PROJECT=$(cd "$PROJECT" && pwd -P)
[ -e "$PROJECT/.git" ] || { git -C "$PROJECT" init -qb main && git -C "$PROJECT" -c user.name=s -c user.email=s@example.invalid commit --allow-empty -qm init; }
for id in "$D" "$C"; do
  cat >"$HOME_DIR/data/$id/brief.md" <<EOF
# Current worker role contract
You are a crewmate worker managed by Firstmate, not a supervisor.
# Task
Write BRIEF_RECEIVED to $HOME_DIR/data/$id/report.md, then finish your turn and wait. Do not commit or push.
EOF
done

say "spawn real Droid scout on Orca"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$D" "$PROJECT" --scout --harness droid \
  --model "${FM_DROID_LIVE_MODEL:-gpt-5.6-luna}" --effort low --backend orca 2>&1 | tail -2
DM="$HOME_DIR/state/$D.meta"; DT=$(sed -n 's/^terminal=//p' "$DM")
wait_for "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$D.busy-state'" 360 && ok "droid settled first turn" || bad "droid never settled"

say "spawn real Claude scout on Orca"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$C" "$PROJECT" --scout --harness claude --model haiku --backend orca 2>&1 | tail -2
CM="$HOME_DIR/state/$C.meta"; CT=$(sed -n 's/^terminal=//p' "$CM")
echo "droid terminal=$DT claude terminal=$CT"
wait_for "test -f '$HOME_DIR/data/$C/report.md'" 360 && ok "claude received brief" || echo "note: claude report not seen"

say "Scenario: --screen viewport read is scoped to the exact recorded Droid task"
. "$ROOT/bin/fm-backend.sh"
if out=$(fm_backend_visible_capture orca "$DT" "fm-$D" 2>&1); then ok "droid task viewport read returned $(printf '%s\n' "$out" | wc -l | tr -d ' ') lines"; printf '%s\n' "$out" | tail -4; else bad "droid viewport read refused: $out"; fi
if out=$(fm_backend_visible_capture orca "$CT" "fm-$C" 2>&1); then bad "claude task got a viewport read"; else ok "claude-on-Orca viewport refused: $out"; fi
if out=$(fm_backend_visible_capture orca "$CT" "fm-$D" 2>&1); then bad "droid label on claude terminal got a viewport read"; else ok "droid label + foreign terminal refused: $out"; fi
fm_backend_visible_capture_supported orca && bad "orca added to shared FM_BACKEND_VISIBLE_CAPTURE" || ok "orca not in shared FM_BACKEND_VISIBLE_CAPTURE ($FM_BACKEND_VISIBLE_CAPTURE)"

say "Scenario: non-Droid Orca relaunch stays refused"
if out=$("$ROOT/bin/fm-control.sh" "$C" relaunch 2>&1); then bad "claude-on-Orca relaunch admitted: $out"; else ok "claude-on-Orca relaunch refused: $(printf '%s' "$out" | tail -2)"; fi
grep -q '^harness=claude' "$CM" && ok "claude task record intact after refusal" || bad "claude meta changed"

say "Scenario: Orca Droid exit, second exit, then relaunch"
g0=$(sed -n 's/^busy_gen=//p' "$DM")
out=$("$ROOT/bin/fm-control.sh" "$D" exit 2>&1); e=$?; echo "first exit rc=$e: $out"
[ $e = 0 ] && [ "$(cat "$HOME_DIR/state/$D.droid-session-end" 2>/dev/null)" = "$g0" ] && ok "first exit proved SessionEnd for gen $g0" || bad "first exit"
[ "$(sed -n 's/^busy_gen=//p' "$DM")" = "$g0" ] && ok "busy_gen retained after exit" || bad "busy_gen cleared after exit"
out=$("$ROOT/bin/fm-control.sh" "$D" exit 2>&1); e=$?; echo "second exit rc=$e: $out"
[ $e = 0 ] && ok "second exit is idempotent success" || bad "second exit failed"
out=$("$ROOT/bin/fm-control.sh" "$D" relaunch --note 'Wait for a new steer.' 2>&1); e=$?; echo "relaunch rc=$e: $(printf '%s' "$out" | tail -3)"
g1=$(sed -n 's/^busy_gen=//p' "$DM")
[ $e = 0 ] && [ -n "$g1" ] && [ "$g1" != "$g0" ] && [ "$(sed -n 's/^terminal=//p' "$DM")" = "$DT" ] \
  && ok "relaunch after exit admitted: gen $g0 -> $g1, terminal kept" || bad "relaunch after exit"
wait_for "grep -q 'state=idle source=droid-hook' '$HOME_DIR/state/$D.busy-state'" 360 && ok "relaunched droid settled" || bad "relaunched droid did not settle"

say "teardown"
"$ROOT/bin/fm-control.sh" "$D" exit 2>&1 | tail -1
for id in "$D" "$C"; do
  "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null 2>&1
  out=$("$ROOT/bin/fm-teardown.sh" "$id" 2>&1) && echo "teardown $id ok" || echo "teardown $id: $(printf '%s' "$out" | tail -2)"
done
ls "$HOME_DIR/state" | grep -E "^($D|$C)\.meta$" && echo "LEFTOVER meta: lab kept at $LAB" || rm -rf "$LAB"
echo "RESULT rc=$rc"
exit $rc
