#!/usr/bin/env bash
# Default-on live guard for a local Codex secondmate's outside-turn watcher on a
# real Herdr pane.
#
# The binding proof reads Herdr's own `pane process-info` (shell pid and
# foreground processes), a vendor-emitted surface no fake herdr can prove, so
# tests/fm-turnend-guard.test.sh's portable regression is backed here by the real
# backend. In a named non-default lab session a Codex-named lock owner inside a
# real pane runs the production fm_secondmate_watch_start; from outside, the
# production binding proof, watcher status and notification run against the real
# server, and the doorbell must appear in the pane.
#
# The lock owner is a bash symlinked as `codex`, the same stand-in the portable
# regression uses: this proves the Herdr backend route, not a genuine Codex
# session. A run submits no prompt, so the shared live gate runs it by default
# wherever herdr and jq exist. It refreshes the docs/verification/runtime-backends.md
# "Codex secondmate watcher on Herdr" entry.
#
# Every Herdr call goes through bin/fm-herdr-lab.sh against the lab session: the
# production code reaches herdr through a PATH shim that forwards only calls
# carrying that session's `--session` and refuses everything else.
set -u

# shellcheck source=tests/lib.sh
. "$FM_W/tests/lib.sh"

ROOT=$FM_W
MODE=${MODE:-takeover}
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s (herdr %s)\n' "$1" "${HERDR_VERSION:-unknown}" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_SECONDMATE_WATCH_LIVE_E2E herdr jq

[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

HERDR_VERSION=$(herdr --version 2>/dev/null | head -n 1)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-sm-watch.XXXXXX")
LAB_SESSION=$("$LAB_HELPER" name fm-herdr-sm-watch) || fail "could not name a lab session"
cleanup() {
  local status=$?
  local f
  for f in "$TMP_ROOT/home/state/.watch.lock/pid" "$TMP_ROOT/owner.pid"; do
    [ -s "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  "$LAB_HELPER" teardown "$LAB_SESSION" >/dev/null 2>&1 || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

"$LAB_HELPER" provision "$LAB_SESSION" >/dev/null 2>&1 || fail "lab provision failed"
"$LAB_HELPER" run "$LAB_SESSION" workspace create >/dev/null 2>&1 || fail "lab workspace create failed"
PANE=$("$LAB_HELPER" run "$LAB_SESSION" pane list 2>/dev/null | jq -r '(.result.panes // .result)[0].pane_id // empty')
[ -n "$PANE" ] || fail "lab pane id unreadable"

L=$TMP_ROOT
mkdir -p "$L/home/state" "$L/home/config" "$L/parent/state" "$L/shim" "$L/codex-harness" "$L/tmux"
git init -q "$L/home" && git -C "$L/home" commit -q --allow-empty -m init && : > "$L/home/AGENTS.md"
cp -R "$ROOT/bin" "$L/home/bin"
printf 'sm-lab-1\n' > "$L/home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$L/parent" > "$L/home/.fm-secondmate-parent"
ln -s "$(command -v bash)" "$L/codex-harness/codex"
{
  printf '#!/usr/bin/env bash\nsession=%q helper=%q path=%q\n' "$LAB_SESSION" "$LAB_HELPER" "$PATH"
  cat <<'SH'
a=() seen=0
while [ $# -gt 0 ]; do
  if [ "$1" = --session ]; then [ "${2:-}" = "$session" ] || exit 97; seen=1; shift 2; continue; fi
  a+=("$1"); shift
done
[ "$seen" = 1 ] || exit 97
PATH=$path exec "$helper" run "$session" "${a[@]}"
SH
} > "$L/shim/herdr"
chmod +x "$L/shim/herdr"
cat > "$L/owner.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/.lock"; printf '%s\n' "$$" > "$FM_T_DIR/owner.pid"
printf 'HERDR_SESSION=%q\nHERDR_PANE_ID=%q\n' "${HERDR_SESSION:-}" "${HERDR_PANE_ID:-}" > "$FM_T_DIR/owner.env"
i=0; while [ ! -e "$FM_T_DIR/start" ] && [ "$i" -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
[ "${FM_T_DROP_SESSION:-}" = 1 ] && unset HERDR_SESSION
rc=0; . "$FM_HOME/bin/fm-push-transition-lib.sh" && fm_secondmate_watch_start > "$FM_T_DIR/start.out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$FM_T_DIR/start.rc"
i=0; while [ "$i" -lt 180 ]; do sleep 1; i=$((i + 1)); done
SH
ENVS=("FM_HOME=$L/home" "STATE=$L/home/state" "CONFIG=$L/home/config" "FM_T_DIR=$L"
  "FM_TASK_INBOX=$L/parent/state/sm-lab-1.inbox" "FM_T_DROP_SESSION=${FM_T_DROP_SESSION:-}" "TMUX_TMPDIR=$L/tmux" FM_POLL=1 "PATH=$L/shim:$PATH")
{
  printf '#!/usr/bin/env bash\nexec env -u TMUX -u TMUX_PANE'
  printf ' %q' "${ENVS[@]}" "$L/codex-harness/codex" "$L/owner.sh"
  printf '\n'
} > "$L/launch.sh"
chmod +x "$L/launch.sh"

# The owner runs in the real pane, so HERDR_SESSION and HERDR_PANE_ID are what Herdr itself set there.
i=0
until "$LAB_HELPER" run "$LAB_SESSION" pane read "$PANE" --source recent --lines 5 2>/dev/null | grep -q '[^[:space:]]' || [ "$i" -ge 60 ]; do
  sleep 0.5; i=$((i + 1))
done
"$LAB_HELPER" run "$LAB_SESSION" pane run "$PANE" "$L/launch.sh" >/dev/null 2>&1 || fail "pane run failed"
i=0; while [ ! -s "$L/owner.env" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$L/owner.env" ] || fail "the lock owner never started in the lab pane"
# shellcheck source=/dev/null
. "$L/owner.env"
# shellcheck disable=SC2153 # sourced from owner.env above.
[ "$HERDR_SESSION" = "$LAB_SESSION" ] || fail "the pane reported HERDR_SESSION '$HERDR_SESSION', not the lab session"

sm_call() {  # [VAR=value...] <function>
  local -a over=()
  while [[ $1 == *=* ]]; do over+=("$1"); shift; done
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env -u TMUX -u TMUX_PANE "${ENVS[@]}" HERDR_SESSION="$HERDR_SESSION" HERDR_PANE_ID="$HERDR_PANE_ID" \
    ${over[@]+"${over[@]}"} bash -c '. "$FM_HOME/bin/fm-push-transition-lib.sh" && "$@"' _ "$@"
}


# Real leftover: the same detached --grok-hold the Codex Stop hook's --detach-hold starts.
env -u TMUX -u TMUX_PANE "${ENVS[@]}" FM_WATCH_HANDLING_SUCCESSOR=1 FM_WATCH_GROK_HOLD=1 \
  nohup "$L/home/bin/fm-watch.sh" --grok-hold >"$L/grok.log" 2>&1 </dev/null &
i=0; while [ ! -s "$L/home/state/.watch.lock/pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
GROK=$(cat "$L/home/state/.watch.lock/pid" 2>/dev/null)
[ -n "$GROK" ] || fail "the real --grok-hold leftover never took the watch lock: $(cat "$L/grok.log")"
touch "$L/home/state/.last-watcher-beat"
echo "leftover watcher pid $GROK: $(ps -ww -o args= -p "$GROK")"
rc=0; env -u TMUX -u TMUX_PANE "${ENVS[@]}" HERDR_SESSION="$HERDR_SESSION" HERDR_PANE_ID="$HERDR_PANE_ID" \
  "$L/home/bin/fm-watch.sh" --secondmate-selected || rc=$?
echo "--secondmate-selected (pane env, healthy leftover --grok-hold) rc=$rc"
[ "$rc" = 0 ] || fail "a leftover --grok-hold deselected this Herdr secondmate"
rc=0; env -u TMUX -u TMUX_PANE "${ENVS[@]}" HERDR_PANE_ID="$HERDR_PANE_ID" "$L/home/bin/fm-watch.sh" --secondmate-selected || rc=$?
echo "--secondmate-selected (pane env without HERDR_SESSION) rc=$rc"
[ "$rc" = 0 ] || fail "a Herdr pane without HERDR_SESSION was not selected"
: > "$L/start"
i=0; while [ ! -s "$L/start.rc" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
echo "production start rc=$(cat "$L/start.rc" 2>/dev/null) output: $(cat "$L/start.out" 2>/dev/null)"
if [ "$MODE" = takeover ]; then
  [ "$(cat "$L/start.rc" 2>/dev/null)" = 0 ] || fail "production start failed behind the leftover"
  sleep 1
  kill -0 "$GROK" 2>/dev/null && fail "the leftover --grok-hold is still running"
  echo "leftover pid $GROK: gone"
  NEW=$(cat "$L/home/state/.watch.lock/pid")
  echo "new watcher pid $NEW: $(ps -ww -o args= -p "$NEW")"
  ps -ww -o args= -p "$NEW" | grep -q -- '--secondmate-hold' || fail "the new owner is not the secondmate hold"
  echo "binding: $(tr '\n' ' ' < "$L/home/state/.secondmate-watch")"
  sm_call fm_secondmate_watch_status >/dev/null 2>&1 || fail "the secondmate watcher is not healthy after takeover"
  echo "--secondmate-status: healthy"
  sm_call fm_secondmate_watch_notify >/dev/null 2>&1 || fail "notification failed"
  i=0
  until "$LAB_HELPER" run "$LAB_SESSION" pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -Fq "sm-lab-1.inbox" || [ "$i" -ge 20 ]; do sleep 0.5; i=$((i+1)); done
  [ "$i" -lt 20 ] || fail "doorbell never reached the pane"
  echo "pane shows doorbell: $("$LAB_HELPER" run "$LAB_SESSION" pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -F "sm-lab-1.inbox" | tail -1)"
  pass "$HERDR_VERSION: real leftover --grok-hold taken over by --secondmate-hold in a real Herdr pane; doorbell rang"
else
  [ "$(cat "$L/start.rc" 2>/dev/null)" != 0 ] || fail "start without HERDR_SESSION in a named session succeeded"
  kill -0 "$GROK" 2>/dev/null || fail "a failed proof stopped the leftover watcher"
  echo "leftover pid $GROK still alive: $(ps -ww -o args= -p "$GROK")"
  kill "$GROK" 2>/dev/null
  pass "$HERDR_VERSION: pane in a named session without HERDR_SESSION fails the proof and leaves the leftover watcher running"
fi
