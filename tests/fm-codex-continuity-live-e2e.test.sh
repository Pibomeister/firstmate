#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the continuity changes preserve
# Codex's bounded foreground-checkpoint supervision path.
# A second phase proves a blocked Stop, a handled and acknowledged crew
# wake, one successor checkpoint, and release once work clears.
# FM_CODEX_LIVE_E2E_EVIDENCE_DIR optionally retains the lab receipts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
CODEX_VERSION=$(codex --version)

cleanup() {
  if [ -n "${releaser:-}" ]; then
    kill "$releaser" 2>/dev/null || true
    wait "$releaser" 2>/dev/null || true
  fi
  if [ -n "${FM_CODEX_LIVE_E2E_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_CODEX_LIVE_E2E_EVIDENCE_DIR"
    cp "$LAB"/*.jsonl "$LAB"/held-record "$LAB"/wake-receipt "$FM_CODEX_LIVE_E2E_EVIDENCE_DIR/" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" fm_run_timed 120 codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

printf 'ok - %s live E2E preserved the one-second foreground checkpoint path\n' "$CODEX_VERSION"

# Held turn: with work in flight the turn-end guard keeps one Codex turn running
# checkpoints across repeated blocked stops (stop_hook_active true after the
# first), and lets it end once nothing needs supervision. The releaser clears
# the in-flight task only after a crew wake is resolved, acknowledged, and a
# successor watcher owns the lock.
HELD_TRANSCRIPT="$LAB/codex-held.jsonl"
rm -rf "$HOME_DIR/state"
mkdir -p "$HOME_DIR/state"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
: > "$HOME_DIR/state/held-task.meta"
(
  first='' blocks=0 probe_identity=''
  for _ in $(seq 1 1800); do
    record=$(cat "$HOME_DIR"/state/.turnend-codex-block.* 2>/dev/null)
    if [ -n "$record" ] && [ "$record" != "$first" ]; then
      blocks=$((blocks + 1))
      first=$record
    fi
    identity=$(cat "$HOME_DIR/state/.watch.lock/pid-identity" 2>/dev/null)
    watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null)
    if [ "$blocks" -ge 1 ] && [ -n "$identity" ] && kill -0 "$watcher" 2>/dev/null; then
      if [ -z "$probe_identity" ]; then
        probe_identity=$identity
        printf 'needs-decision [key=live-probe] [at=%s]: acknowledge the isolated crew probe\n' "$(date +%s)" >> "$HOME_DIR/state/held-task.status"
      elif [ "$identity" != "$probe_identity" ] \
        && [ "$(tail -1 "$HOME_DIR/state/held-task.status" | grep -Ec '^resolved[ :].*\[key=live-probe\]')" -eq 1 ] \
        && [ ! -s "$HOME_DIR/state/.wake-queue" ]; then
        cp "$HOME_DIR"/state/.turnend-codex-block.* "$LAB/held-record" 2>/dev/null
        cp "$HOME_DIR/state/held-task.status" "$LAB/wake-receipt"
        rm -f "$HOME_DIR/state/held-task.meta"
        exit 0
      fi
    fi
    sleep 0.2
  done
) &
releaser=$!
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" FM_CODEX_WATCH_CHECKPOINT=2 fm_run_timed 420 codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    'Reply with the single word ok immediately. If a Stop hook blocks you, follow its instruction literally. Only after receiving the isolated held-task live-probe decision, resolve it by appending "resolved [key=live-probe] [at=EPOCH]: approved isolated probe" using the current numeric epoch. Drain and handle wakes, execute the exact printed acknowledgement command, and run one successor foreground checkpoint while the task remains in flight.'
) > "$HELD_TRANSCRIPT" 2>&1 || fail "Codex held-turn run failed: $(tail -20 "$HELD_TRANSCRIPT")"
kill "$releaser" 2>/dev/null || true
wait "$releaser" 2>/dev/null || true

[ -s "$LAB/held-record" ] || fail "the guard did not block the Codex turn while work was in flight"
[ -s "$LAB/wake-receipt" ] || fail "the crew wake was not resolved and acknowledged before a successor checkpoint"
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "the Codex turn ended with unacknowledged wakes"
grep -E '^turn=.+' "$LAB/held-record" >/dev/null \
  || fail "the Codex Stop payload carried no turn_id: $(cat "$LAB/held-record")"
checkpoints=$(jq -R 'fromjson? | select(.type == "item.completed" and .item.type == "command_execution" and (.item.command | contains("fm-watch-checkpoint.sh")))' "$HELD_TRANSCRIPT" | jq -s length)
[ "$checkpoints" -ge 2 ] \
  || fail "the held Codex turn ran $checkpoints checkpoint commands, expected at least 2"
grep -F -- '--ack-through' "$HELD_TRANSCRIPT" >/dev/null \
  || fail "the held Codex turn omitted wake acknowledgement"

printf 'ok - %s live E2E held one turn after a guard block and ended once work cleared\n' "$CODEX_VERSION"
printf 'ok - %s live E2E resolved and acknowledged a crew wake before one successor checkpoint\n' "$CODEX_VERSION"

# Resume the exact held conversation after it becomes idle, proving the saved
# per-session block cannot prevent a quiet foreground checkpoint and turn end.
held_session=$(jq -Rr 'fromjson? | select(.type == "thread.started") | .thread_id' "$HELD_TRANSCRIPT" | head -1)
[ -n "$held_session" ] || fail "the held Codex run reported no session id"
RESUME_TRANSCRIPT="$LAB/codex-resume.jsonl"
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" fm_run_timed 120 codex exec resume \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json "$held_session" "$PROMPT"
) > "$RESUME_TRANSCRIPT" 2>&1 || fail "Codex idle resume failed: $(tail -20 "$RESUME_TRANSCRIPT")"
grep -F 'checkpoint: no actionable wake within 1s' "$RESUME_TRANSCRIPT" >/dev/null \
  || fail "the resumed Codex session omitted its foreground checkpoint result"
printf 'ok - %s live E2E resumed the held session and ended after a quiet checkpoint\n' "$CODEX_VERSION"
