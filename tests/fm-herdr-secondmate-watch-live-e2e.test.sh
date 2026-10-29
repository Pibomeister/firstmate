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
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
rc=0; . "$FM_HOME/bin/fm-push-transition-lib.sh" && fm_secondmate_watch_start > "$FM_T_DIR/start.out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$FM_T_DIR/start.rc"
i=0; while [ "$i" -lt 180 ]; do sleep 1; i=$((i + 1)); done
SH
ENVS=("FM_HOME=$L/home" "STATE=$L/home/state" "CONFIG=$L/home/config" "FM_T_DIR=$L"
  "FM_TASK_INBOX=$L/parent/state/sm-lab-1.inbox" "TMUX_TMPDIR=$L/tmux" FM_POLL=1 "PATH=$L/shim:$PATH")
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

sm_call fm_secondmate_watch_binding_valid >/dev/null 2>&1 && fail "a missing binding file validated"
: > "$L/start"
i=0; while [ ! -s "$L/start.rc" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(cat "$L/start.rc" 2>/dev/null)" = 0 ] || fail "production fm_secondmate_watch_start failed: $(cat "$L/start.out" 2>/dev/null)"
[ "$(sed -n 5p "$L/home/state/.secondmate-watch")" = herdr ] || fail "the binding does not record backend herdr"
[ "$(sed -n 3p "$L/home/state/.secondmate-watch")" = "$LAB_SESSION:$HERDR_PANE_ID" ] || fail "the binding does not record the pane target"
sm_call fm_secondmate_watch_binding_valid >/dev/null 2>&1 || fail "the binding production wrote did not validate against real process-info"
sm_call HERDR_PANE_ID=w9:p9 fm_secondmate_watch_binding_valid >/dev/null 2>&1 && fail "the binding validated for another pane"
sm_call fm_secondmate_watch_status >/dev/null 2>&1 || fail "the secondmate watcher is not healthy"
pass "$HERDR_VERSION: production watch start binds a Codex-named owner in a real Herdr pane, proven from real process-info, refused for another pane"

sm_call fm_secondmate_watch_notify >/dev/null 2>&1 || fail "notification failed"
REC=$(cat "$L/home/state/.secondmate-watch-message" 2>/dev/null)
[ -f "$REC" ] || fail "notification wrote no parent inbox record"
i=0
until "$LAB_HELPER" run "$LAB_SESSION" pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -Fq "sm-lab-1.inbox" || [ "$i" -ge 20 ]; do
  sleep 0.5; i=$((i + 1))
done
[ "$i" -lt 20 ] || fail "the doorbell never appeared in the real pane"
pass "$HERDR_VERSION: notification wrote durable record ${REC##*/} and its doorbell reached the real Herdr pane"
