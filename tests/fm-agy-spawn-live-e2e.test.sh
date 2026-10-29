#!/usr/bin/env bash
# Opt-in live agy worker guard through the real spawn path on tmux: the
# fallback from a configured orca backend, trust pre-registration, the launch
# readiness gate, a clean fm-control exit, a kept record after a forced
# readiness failure, fm-control relaunch of that record, and teardown.
# Opt-in because it submits real prompts (no echo provider exists for agy).
# FM_AGY_LIVE_MODEL picks the model (gemini-4-argon-high exercises the crew
# dispatch default).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_SPAWN_LIVE agy tmux treehouse

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-agy-spawn-$$"
LAB_LOGICAL=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-spawn.XXXXXX")
LAB=$(cd "$LAB_LOGICAL" && pwd -P)
HOME_DIR="$LAB/home"
PROJECT="$HOME_DIR/projects/scratch"
MODEL=${FM_AGY_LIVE_MODEL:-gemini-3.8-flash-low}

# On macOS the worker keeps the operator's real HOME (see below), so its trust
# pre-registration writes the real store. Remove exactly this lab's entries,
# whatever else happens, and leave every other entry untouched.
drop_lab_trust() {
  [ "${AGY_REAL_STORE:-0}" = 1 ] && [ -f "${STORE:-}" ] || return 0
  node -e '
const fs=require("node:fs");const [store,...prefixes]=process.argv.slice(1);
const j=JSON.parse(fs.readFileSync(store,"utf8"));
if(!Array.isArray(j.trustedWorkspaces))process.exit(0);
const keep=j.trustedWorkspaces.filter(p=>!prefixes.some(x=>p===x||p.startsWith(x+"/")));
if(keep.length===j.trustedWorkspaces.length)process.exit(0);
j.trustedWorkspaces=keep;const tmp=store+".fm-agy-live."+process.pid;
fs.writeFileSync(tmp,JSON.stringify(j,null,2)+"\n");fs.renameSync(tmp,store);
' "$STORE" "$LAB" "$LAB_LOGICAL" || printf '# could not drop the lab trust entries from %s\n' "$STORE" >&2
}

cleanup() {
  drop_lab_trust
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup EXIT

# On Linux the worker runs under a throwaway HOME holding a copy of ~/.gemini,
# so trust pre-registration writes the copy's store and never the operator's
# own. macOS cannot do that: the login keychain that holds agy's sign-in is
# found through HOME, so a throwaway HOME runs agy signed out and makes macOS
# show its "keychain cannot be found" dialog. There the worker keeps the real
# HOME, and drop_lab_trust removes this lab's trust entries on exit.
[ -d "$HOME/.gemini" ] || fail "no ~/.gemini for the agy worker"
mkdir -p "$LAB/shim" "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/config" "$LAB/pool"
if [ "$(uname -s)" = Darwin ]; then
  AGY_HOME=$HOME
  AGY_REAL_STORE=1
else
  AGY_HOME="$LAB/agy-home"
  mkdir -p "$AGY_HOME"
  cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not stage the throwaway agy credential copy"
  [ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$AGY_HOME/.gitconfig"
fi
STORE="$AGY_HOME/.gemini/antigravity-cli/settings.json"
cat >"$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
# The orca fallback prefers herdr, and this guard must never drive the
# operator's own herdr session; a herdr that fails its version check sends the
# fallback to the isolated tmux server instead. The portable suite owns the
# herdr preference.
printf '#!/bin/sh\nexit 1\n' >"$LAB/shim/herdr"
chmod +x "$LAB/shim/tmux" "$LAB/shim/herdr"
export HOME="$AGY_HOME" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TREEHOUSE_ROOT="$LAB/pool"
PATH="$LAB/shim:$PATH"
export PATH

git -C "$PROJECT" init -q || fail "could not initialize the agy smoke repository"
git -C "$PROJECT" -c user.name='Agy Smoke' -c user.email='smoke@example.invalid' \
  commit --allow-empty -qm 'Initialize disposable scout repository' \
  || fail "could not commit the agy smoke repository"

write_brief() {  # <id>
  local id=$1 report="$HOME_DIR/data/$1/report.md"
  mkdir -p "$HOME_DIR/data/$id"
  cat >"$HOME_DIR/data/$id/brief.md" <<EOF
# Current worker role contract
You are a crewmate worker managed by Firstmate, not a supervisor.
Do this bounded smoke task yourself and report through the task report only.

# Task
## Captain's intent
Prove that the agy worker receives its launch brief.

## Firstmate spec
Add 12345 and 67890.
Create a report at the absolute path $report with one line beginning BRIEF_RECEIVED, the sum, and your current working directory, unless the existing report already contains that line.
Then stop and wait.
Do not commit, push, or publish anything.
EOF
}

wait_for() {  # <description> <shell command> [polls]
  local label=$1 command=$2 max=${3:-240} count=0
  while [ "$count" -lt "$max" ]; do
    bash -c "$command" && return 0
    count=$((count + 1))
    sleep 0.5
  done
  fail "$label did not appear within $((max / 2)) seconds"
}

# fm-control proves the idle agy composer empty, types /quit, and proves the
# agent gone; no agy process may outlive its task.
# The pane's own shell stays in the worktree until teardown closes the window,
# so only a process whose command is agy counts as a leak.
agy_in_worktree() {  # <worktree>
  local pid
  for pid in $(lsof -t +D "$1" 2>/dev/null | sort -u); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
      agy|*/agy) return 0 ;;
    esac
  done
  return 1
}

retire() {  # <id>
  local window wt
  window=$(sed -n 's/^window=//p' "$HOME_DIR/state/$1.meta")
  wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$1.meta")
  wait_for "idle agy footer for $1" "tmux capture-pane -p -t '$window' | grep -Fq '? for shortcuts'"
  agy_in_worktree "$wt" || fail "no agy process was found in $wt before exit; the leak check cannot see agy"
  "$ROOT/bin/fm-control.sh" "$1" exit || fail "fm-control could not exit the idle agy worker for $1"
  ! agy_in_worktree "$wt" || fail "an agy process outlived fm-control exit for $1"
  pass "fm-control exit stopped the idle agy worker for $1"
  "$ROOT/bin/fm-captain-hold.sh" complete "$1" --none || fail "agy scout completion inventory failed for $1"
  "$ROOT/bin/fm-teardown.sh" "$1" || fail "agy scout teardown failed for $1"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "agy task metadata survived teardown for $1"
}

ID=agy-live
write_brief "$ID"
printf 'orca\n' >"$HOME_DIR/config/backend"
out=$(FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout \
  --harness agy --model "$MODEL" --effort low 2>&1) \
  || fail "agy scout spawn on a configured orca backend failed"$'\n'"$out"
printf '%s\n' "$out" | grep -Fq 'this agy task runs on backend=tmux' \
  || fail "the agy spawn did not announce its tmux fallback"$'\n'"$out"
rm -f "$HOME_DIR/config/backend"
# Act as a seat on the lab server from here on, so fm-control addresses the
# server the record names rather than the default one.
TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')" || fail "the lab tmux server did not answer"
export TMUX
WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")
[ -n "$WT" ] || fail "the agy record names no worktree"
grep -Fq "\"$WT\"" "$STORE" || fail "the agy worktree was not pre-registered in the trust store"
wait_for 'brief report' "grep -Fq BRIEF_RECEIVED '$HOME_DIR/data/$ID/report.md'"
grep -Fq 80235 "$HOME_DIR/data/$ID/report.md" || fail "the agy report lacks the brief's sum"
grep -Fq "$WT" "$HOME_DIR/data/$ID/report.md" || fail "the agy brief did not run in its worktree"
pass "agy $(agy --version 2>/dev/null | head -n1) fell back from orca to tmux, pre-registered trust, and processed its brief in the worktree"
retire "$ID"

# A readiness gate that gives up at once fails a pane that is still starting,
# which is the custody case: its own window closes and its record stays.
ID=agy-custody
write_brief "$ID"
rc=0
out=$(FM_AGY_READY_POLLS=1 FM_AGY_POLL_INTERVAL=0 FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout \
  --harness agy --model "$MODEL" --effort low --backend tmux 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a one-poll agy readiness gate unexpectedly passed; the custody case was not exercised"$'\n'"$out"
[ -f "$HOME_DIR/state/$ID.meta" ] || fail "a failed agy readiness gate rolled back its record"$'\n'"$out"
WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")
SECOND_WT=$(cd "$PROJECT" && treehouse get --lease --no-fetch) || fail "second dispatch could not allocate a slot"
[ "$SECOND_WT" != "$WT" ] || fail "second dispatch stole the failed AGY task's checkout"
treehouse return "$SECOND_WT" --force || fail "second dispatch slot could not be returned"
WINDOW=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -Fqx "$WINDOW" \
  && fail "a failed agy readiness gate left its window $WINDOW open"
pass "a failed agy readiness gate closed its own window and kept its record"
RELAUNCH_TOKEN="relaunch-$$-$RANDOM-$RANDOM"
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note "The first launch failed its readiness check. Add 12345 and 67890. Overwrite the task report even if it already exists, using this exact format with the computed sum and your actual current working directory:
BRIEF_RECEIVED $RELAUNCH_TOKEN <sum> <current working directory>
Then stop and wait." || fail "fm-control could not relaunch the kept agy record"
[ "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")" = "$WT" ] || fail "relaunch changed the original task worktree"
wait_for 'relaunched brief report with fresh token, sum, and worktree' "grep -Fxq 'BRIEF_RECEIVED $RELAUNCH_TOKEN 80235 $WT' '$HOME_DIR/data/$ID/report.md'"
pass "fm-control relaunched the kept agy record and the worker processed its brief"
retire "$ID"
