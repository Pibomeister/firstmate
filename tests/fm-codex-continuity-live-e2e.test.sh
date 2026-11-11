#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the continuity changes preserve
# Codex's bounded foreground-checkpoint supervision path.
# A second phase proves a blocked initial Stop and an allowed active
# continuation that keeps its queued wake durable.
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
  if [ -x "$PROJECT/bin/fm-watch-arm.sh" ] && [ -d "$HOME_DIR/state" ]; then
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" "$PROJECT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  fi
  if [ -n "${FM_CODEX_LIVE_E2E_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_CODEX_LIVE_E2E_EVIDENCE_DIR"
    cp "$LAB"/*.jsonl "$LAB"/stop-hook.log "$FM_CODEX_LIVE_E2E_EVIDENCE_DIR/" 2>/dev/null || true
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
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" fm_run_timed 600 codex exec \
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

# Held turn: an initial Stop with work in flight and a queued wake blocks and
# asks for handling. Its stop_hook_active=true continuation, outside any open
# checkpoint, is allowed while the queued wake stays durable. A test-owned
# wrapper around the clone's guard records each real Stop payload and exit.
# The wrapper seeds the in-flight work and queued wake at the first Stop: the
# real session start drains any wake queued before the run.
HELD_TRANSCRIPT="$LAB/codex-held.jsonl"
DECISIONS="$LAB/stop-decisions.jsonl"
QUEUED='1790000000 1 signal held-task.status needs-decision live-probe'
rm -rf "$HOME_DIR/state"
mkdir -p "$HOME_DIR/state"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
mv "$PROJECT/bin/fm-turnend-guard.sh" "$PROJECT/bin/fm-turnend-guard.real.sh"
cat > "$PROJECT/bin/fm-turnend-guard.sh" <<WRAP
#!/usr/bin/env bash
payload=\$(cat)
if [ ! -e "$LAB/seeded" ]; then
  : > "$HOME_DIR/state/held-task.meta"
  printf '%s\\n' '$QUEUED' > "$HOME_DIR/state/.wake-queue"
  : > "$LAB/seeded"
fi
printf '%s' "\$payload" | "\$(dirname "\$0")/fm-turnend-guard.real.sh" "\$@" >"$LAB/guard.out" 2>"$LAB/guard.err"
code=\$?
jq -cn --arg payload "\$payload" --argjson code "\$code" '{code:\$code,payload:(\$payload | fromjson? // \$payload)}' >> "$DECISIONS"
cat "$LAB/guard.out"
cat "$LAB/guard.err" >&2
exit "\$code"
WRAP
chmod +x "$PROJECT/bin/fm-turnend-guard.sh"
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" fm_run_timed 600 codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    'Reply with the single word ok immediately. This is an isolated lab probe. If a Stop hook blocks you, do not run any command or tool and do not drain or acknowledge wakes; reply with the single word ok again.'
) > "$HELD_TRANSCRIPT" 2>&1 || fail "Codex held-turn run failed: $(tail -20 "$HELD_TRANSCRIPT")"
cp "$HOME_DIR/state/stop-hook.log" "$LAB/stop-hook.log" 2>/dev/null || true

active='(.payload | if type != "object" then null elif has("stopHookActive") then .stopHookActive else (.stop_hook_active // false) end)'
[ -s "$DECISIONS" ] || fail "the Codex run reached no Stop hook"
jq -se "length >= 2 and (.[0] | $active == false and .code == 2)" "$DECISIONS" >/dev/null \
  || fail "the initial Codex Stop was not blocked while a wake was queued: $(cat "$DECISIONS")"
jq -se "(.[-1] | $active == true and .code == 0) and all(.[1:][]; $active == true)" "$DECISIONS" >/dev/null \
  || fail "the active Codex continuation was not allowed to stop: $(cat "$DECISIONS")"
grep -Fx "$QUEUED" "$HOME_DIR/state/.wake-queue" >/dev/null \
  || fail "the allowed active continuation did not retain the queued wake"
grep -E '^STOPHOOK v1 .* status=hook_active ' "$LAB/stop-hook.log" >/dev/null \
  || fail "the active continuation wrote no hook_active watchdog line: $(cat "$LAB/stop-hook.log" 2>/dev/null)"

printf 'ok - %s live E2E blocked the initial queued-wake Stop and allowed its active continuation\n' "$CODEX_VERSION"
printf 'ok - %s live E2E retained the queued wake across the allowed continuation\n' "$CODEX_VERSION"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" "$PROJECT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
rm -f "$HOME_DIR/state/held-task.meta" "$HOME_DIR/state/.wake-queue"

# Resume the exact held conversation after it becomes idle, proving the earlier
# block leaves nothing that prevents a quiet foreground checkpoint and turn end.
held_session=$(jq -Rr 'fromjson? | select(.type == "thread.started") | .thread_id' "$HELD_TRANSCRIPT" | head -1)
[ -n "$held_session" ] || fail "the held Codex run reported no session id"
RESUME_TRANSCRIPT="$LAB/codex-resume.jsonl"
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" fm_run_timed 600 codex exec resume \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json "$held_session" "$PROMPT"
) > "$RESUME_TRANSCRIPT" 2>&1 || fail "Codex idle resume failed: $(tail -20 "$RESUME_TRANSCRIPT")"
grep -F 'checkpoint: no actionable wake within 1s' "$RESUME_TRANSCRIPT" >/dev/null \
  || fail "the resumed Codex session omitted its foreground checkpoint result"
printf 'ok - %s live E2E resumed the held session and ended after a quiet checkpoint\n' "$CODEX_VERSION"
