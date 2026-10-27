#!/usr/bin/env bash
# Opt-in native Codex counters and real interruption guard.
# Run: FM_LIVE=1 bash bin/fm-test-run.sh tests/fm-task-budget-live-e2e.test.sh
# Uses a marked disposable home and its private tmux server; never a fleet endpoint.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_TASK_BUDGET_LIVE_E2E tmux codex

TMP_ROOT=$(fm_test_tmproot fm-task-budget-live)
LAB="$TMP_ROOT/home"
LAB_TOOL="$ROOT/bin/fm-lab-home.sh"
CHECKED=0
STOP_CHECKED=0
CODEX_TRUST_SENT=0
"$LAB_TOOL" create "$LAB" >/dev/null
TMUX_TMPDIR=$("$LAB_TOOL" tmux-dir "$LAB")
export TMUX_TMPDIR
unset TMUX TMUX_PANE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
cleanup() {
  "$LAB_TOOL" tmux "$LAB" kill-server >/dev/null 2>&1 || true
  "$LAB_TOOL" teardown "$LAB" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

seed_case() {
  local harness=$1 native=$2
  mkdir -p "$LAB/$harness"
  printf 'harness=%s\nkind=scout\nspawn_gen=live-%s\nwindow=budget-live:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' \
    "$harness" "$harness" "$harness" "$harness" "$LAB/$harness" "$LAB/$harness" > "$LAB/state/$harness.meta"
  "$ROOT/bin/fm-task-budget.sh" seed - "$harness" "$LAB/$harness" "$native" \
    "FM_BUDGET_LAUNCH_live$harness" 40000000 1 1500000 1 >> "$LAB/state/$harness.meta"
}

wait_usage() {
  local harness=$1 deadline out target
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$harness" = codex ] && [ "$CODEX_TRUST_SENT" = 0 ]; then
      if "$LAB_TOOL" tmux "$LAB" capture-pane -p -t budget-live:fm-codex -S -100 | grep -Fq 'Do you trust the contents of this directory?'; then
        "$LAB_TOOL" tmux "$LAB" send-keys -t budget-live:fm-codex Enter
        CODEX_TRUST_SENT=1
      fi
    fi
    out=$("$ROOT/bin/fm-task-budget.sh" measure "$LAB/state/$harness.meta")
    if printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="ok"' 2>/dev/null; then
      printf '%s\n' "$out" > "$LAB/$harness-measured.json"
      return 0
    fi
    sleep 1
  done
  case "$harness" in codex) target=budget-live:fm-codex ;; *) target=firstmate:fm-claude ;; esac
  "$LAB_TOOL" tmux "$LAB" capture-pane -p -t "$target" -S -80 >&2 || true
  printf '%s\n' "$out" >&2
  fail "$harness native usage was not measurable within 90 seconds"
}

if command -v codex >/dev/null 2>&1; then
  printf '# codex version: %s\n' "$(codex --version)"
  seed_case codex "${CODEX_HOME:-$HOME/.codex}/sessions"
  cat > "$LAB/run-codex.sh" <<'SH'
#!/usr/bin/env bash
unset CLAUDECODE FM_TASK_ID
codex --no-daemon -a never -s read-only --disable hooks -c project_doc_max_bytes=0 \
  -C "$FM_BUDGET_LIVE_WORKSPACE" \
  $'FM_BUDGET_LAUNCH_livecodex\nRun exactly sleep 120 using a shell tool once, then reply NATIVE_BUDGET_DONE. Do not inspect files or use any other tools.'
exec /bin/bash --noprofile --norc
SH
  chmod +x "$LAB/run-codex.sh"
  FM_BUDGET_LIVE_WORKSPACE="$LAB/codex" "$LAB_TOOL" tmux "$LAB" new-session -d -s budget-live -n fm-codex \
    -c "$LAB/codex" "$LAB/run-codex.sh"
  sleep 2
  pane=$("$LAB_TOOL" tmux "$LAB" capture-pane -p -t budget-live:fm-codex -S -100)
  if printf '%s\n' "$pane" | grep -Fq 'Do you trust the contents of this directory?'; then
    "$LAB_TOOL" tmux "$LAB" send-keys -t budget-live:fm-codex Enter
    CODEX_TRUST_SENT=1
  fi
  wait_usage codex
  "$ROOT/bin/fm-task-budget.sh" tick "$LAB/state/codex.meta" "$LAB/config" "$LAB" > "$LAB/dry-run.out" 2>&1
  assert_grep 'budget-would-pause' "$LAB/dry-run.out" 'live dry-run detects native usage'
  [ ! -e "$LAB/state/codex.status" ] || fail 'live dry-run raised a decision'
  printf 'enforce\n' > "$LAB/config/budget-enforcement"
  FM_HOME="$LAB" "$ROOT/bin/fm-task-budget.sh" tick "$LAB/state/codex.meta" "$LAB/config" "$LAB"
  if ! grep -Fq 'interrupt-delivered' "$LAB/state/codex.status"; then
    cat "$LAB/state/codex.status" >&2
    "$LAB_TOOL" tmux "$LAB" capture-pane -p -t budget-live:fm-codex -S -80 >&2 || true
    fail 'live exact-task interruption delivered'
  fi
  python3 - "$LAB" <<'PY'
import json,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);sample=json.loads((p/'codex-measured.json').read_text())
log=pathlib.Path(sample['source']);usage=None;aborted=False;history=set();types=set()
for _ in range(20):
 for line in log.read_text().splitlines():
  try:row=json.loads(line)
  except ValueError:continue
  event=row.get('payload',{})
  types.add((row.get('type'),event.get('type')))
  if row.get('type')=='event_msg' and event.get('type')=='turn_aborted':aborted=True
  if row.get('type')=='event_msg' and event.get('type')=='token_count' and event.get('info'):
   usage=event['info']['total_token_usage']
  if row.get('type')=='token_usage_record':usage=event['thread_token_usage']
  if usage:history.add((usage['total_tokens'],usage['total_tokens']-usage['cached_input_tokens']))
 if aborted:break
 time.sleep(.25)
state=json.loads((p/'state/codex.budget').read_text());episode=state['episode'];actual=episode['sample']
print('control '+episode['attempt']['outcome'])
assert usage and aborted,('native Codex turn_aborted acknowledgement missing',sorted(map(str,types)))
assert (sample['inclusive'],sample['fresh']) in history,(sample,history)
assert (actual['inclusive'],actual['fresh']) in history,(actual,history)
print('codex native inclusive=%d fresh=%d stop=1 overshoot=%d turn_aborted=true' % (actual['inclusive'],actual['fresh'],actual['inclusive']-1))
PY
  FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" codex exit
  STOP_CHECKED=$((STOP_CHECKED + 1))
  CHECKED=$((CHECKED + 1))
else
  printf '# absent harness: codex\n'
fi

if command -v claude >/dev/null 2>&1; then
  printf '# claude version: %s; live path not exercised; deterministic carrier/counter coverage only\n' "$(claude --version)"
else
  printf '# absent harness: claude; deterministic carrier/counter coverage only\n'
fi
[ "$CHECKED" -gt 0 ] || fail 'no supported installed harness exercised'
[ "$STOP_CHECKED" -gt 0 ] || fail 'no disposable endpoint interruption verified'
pass "native budget guard exercised $CHECKED supported harnesses and $STOP_CHECKED interruption"
