#!/usr/bin/env bash
# Opt-in real Grok-to-Codex secondmate handoff in a guarded, named Herdr lab.
# It proves process replacement and durable file preservation, not a live
# supervision watcher: this fixture has a deliberately minimal home.
# Run with FM_GROK_QUOTA_HANDOFF_LIVE=1 only while Grok credits are exhausted.
set -u

# shellcheck source=tests/lib.sh
. "/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5Z521319WB01Q59P4W9N75G/tests/lib.sh"
fm_live_gate opt-in FM_GROK_QUOTA_HANDOFF_LIVE grok codex herdr jq git tmux quota-axi

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
quota=$(quota-axi --provider grok --json --no-credential-refresh) \
  || fail "Grok quota could not be read before the live test"
credits=$(printf '%s' "$quota" | jq -r \
  '[.providers[]? | select(.provider == "grok") | .windows[]? | select(.id == "credits") | .percentRemaining][0] // empty')
[ "$credits" = 0 ] || {
  printf 'skip: Grok credits are %s%%, so the quota dialog is not reproducible without spending credits\n' "${credits:-unknown}"
  exit 0
}

LAB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-handoff.XXXXXX") || exit 1
FM_HOME="$LAB_ROOT/primary"
SM_HOME="$LAB_ROOT/secondmate"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-pr5-exit-absence-proof) || exit 1
LAB_TMUX_DIR=
HERDR_ATTEMPTED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -d "$LAB_ROOT/codexhome" ]; then
    CODEX_HOME="$LAB_ROOT/codexhome" codex app-server daemon stop >/dev/null 2>&1 || rc=1
  fi
  rm -f "$LAB_ROOT/codexhome/auth.json" || rc=1
  if [ -n "$LAB_TMUX_DIR" ]; then
    "$LAB_HOME_HELPER" tmux "$FM_HOME" kill-server 2>/dev/null || true
  fi
  if [ -f "$FM_HOME/.fm-lab-home" ]; then
    "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  fi
  if [ "$HERDR_ATTEMPTED" = 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fi
  fm_test_cleanup || rc=1
  if [ "$rc" -eq 0 ]; then
    [ ! -d "$FM_HOME/state/labmate.git-hooks" ] \
      || chmod -R u+w "$FM_HOME/state/labmate.git-hooks" || rc=1
    rm -rf -- "$LAB_ROOT" || rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'lab retained for diagnosis: %s\n' "$LAB_ROOT" >&2
  else
    printf 'ok - named Herdr lab %s: disposable files removed\n' "$HERDR_LAB_SESSION"
  fi
  exit "$rc"
}
trap cleanup EXIT

# Keep folder-trust writes and Codex runtime files inside the disposable lab.
# Reuse login material only; never copy the operator's hooks or configuration.
codex_auth="${CODEX_HOME:-$HOME/.codex}/auth.json"
export CODEX_HOME="$LAB_ROOT/codexhome"
mkdir -m 700 "$CODEX_HOME" || fail "could not create the disposable Codex home"
if [ -f "$codex_auth" ]; then
  cp "$codex_auth" "$CODEX_HOME/auth.json" || fail "could not seed the lab Codex login"
  chmod 600 "$CODEX_HOME/auth.json" || fail "could not protect the lab Codex login"
fi

"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null || fail "could not mark the primary lab home"
ln -s "$ROOT/bin" "$FM_HOME/bin" || fail "could not expose the test scripts to the primary lab home"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME") || fail "could not create the private tmux socket directory"
HERDR_ATTEMPTED=1
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision named Herdr lab"
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" || fail "could not attach the lab viewer"

mkdir -p "$SM_HOME/bin" "$SM_HOME/config" "$SM_HOME/data" "$SM_HOME/state" "$SM_HOME/projects"
printf 'labmate\n' > "$SM_HOME/.fm-secondmate-home"
printf '# Isolated secondmate lifecycle lab\n\nRemain in this lab home. Do not touch production state.\n' > "$SM_HOME/AGENTS.md"
printf '# Charter\n\nStay in this isolated home and do not edit files.\n' > "$SM_HOME/data/charter.md"
printf 'window=lab-child\n' > "$SM_HOME/state/child.meta"
printf 'proof of pending child work\n' > "$SM_HOME/state/child.status"
printf '#!/usr/bin/env bash\n' > "$SM_HOME/bin/.keep"
git -C "$SM_HOME" init -q || fail "could not initialize the isolated secondmate checkout"
git -C "$SM_HOME" add .fm-secondmate-home AGENTS.md data/charter.md bin/.keep || fail "could not stage the lab charter"
git -C "$SM_HOME" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial || fail "could not commit the lab secondmate home"
head_before=$(git -C "$SM_HOME" rev-parse HEAD)
charter_before=$(git hash-object "$SM_HOME/data/charter.md")
child_before=$(git hash-object "$SM_HOME/state/child.meta")
printf 'codex\n' > "$FM_HOME/config/secondmate-harness"
mkdir -p "$FM_HOME/state/labmate.inbox/handled"
printf 'schema=fm-task-inbox.v1\nat=2026-10-11T00:00:00Z\n--\nLab inbox preservation sentinel.\n' \
  > "$FM_HOME/state/labmate.inbox/001.msg"
inbox_before=$(git hash-object "$FM_HOME/state/labmate.inbox/001.msg")

BASE_PATH=$PATH
mkdir -p "$LAB_ROOT/transport"
cat > "$LAB_ROOT/transport/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=(); scoped=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$2" = "$TEST_SESSION" ] || exit 1; scoped=$((scoped+1)); shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "$scoped" = 0 ] && [ "${args[*]}" = 'status --json' ]; then scoped=1; fi
[ "$scoped" = 1 ] || exit 1
lab() { PATH="$BASE_PATH" "$HERDR_LAB_HELPER" "$@"; }
if [ "${args[0]}" = server ]; then
  printf 'real server restart requested for %s\n' "$TEST_MODE" >> "$TEST_TRACE"
  lab provision "$TEST_SESSION" || exit 1
  if [ "$TEST_MODE" = alive ]; then
    lab viewer stop "$TEST_SESSION" >/dev/null || exit 1
    lab viewer start "$TEST_SESSION" || exit 1
    lab run "$TEST_SESSION" agent start fm-labmate --kind grok --pane "$TEST_PANE" -- --always-approve --reasoning-effort low || exit 1
    for n in $(seq 1 30); do
      state=$(PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$TEST_SESSION" agent get "$TEST_PANE" 2>/dev/null | jq -r '.result.agent.agent // empty')
      [ "$state" = grok ] && break
      sleep 0.2
    done
    [ "$state" = grok ] || exit 1
  fi
  touch "$TEST_READY"
  exit 0
fi
if [ "${args[*]}" = 'status --json' ] && [ "$TEST_MODE" = alive ] && [ -f "$TEST_SENT" ] && [ ! -f "$TEST_READY" ]; then
  # Give the controlled restart time to finish before exposing its status.
  # Before restart was requested, the actual status must still report stopped.
  if [ -f "$TEST_RESTARTING" ]; then
    for n in $(seq 1 80); do [ ! -f "$TEST_READY" ] || break; sleep 0.2; done
  fi
fi
lab run "$TEST_SESSION" "${args[@]}"
rc=$?; [ "$rc" = 0 ] || exit "$rc"
if [ "${args[0]} ${args[1]:-}" = 'pane send-text' ] && [ "${args[3]:-}" = /exit ]; then
  touch "$TEST_TYPED"
elif [ "${args[0]} ${args[1]:-}" = 'pane send-keys' ] && [ "${args[3]:-}" = enter ] && [ -f "$TEST_TYPED" ] && [ ! -f "$TEST_SENT" ]; then
  touch "$TEST_SENT"
  case "$TEST_MODE" in
    closed) lab run "$TEST_SESSION" pane close "$TEST_PANE" >> "$TEST_TRACE" || exit 1 ;;
    idle|alive) lab stop "$TEST_SESSION" >> "$TEST_TRACE" || exit 1 ;;
  esac
  printf 'after submitted /exit: %s mutated real recorded pane %s\n' "$TEST_MODE" "$TEST_PANE" >> "$TEST_TRACE"
fi
SH
# Mark the restart before provision so asynchronous status reads wait for Grok.
python3 - "$LAB_ROOT/transport/herdr" <<'P'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); s=s.replace('  lab provision "$TEST_SESSION"', '  touch "$TEST_RESTARTING"\n  lab provision "$TEST_SESSION"'); p.write_text(s)
P
chmod 700 "$LAB_ROOT/transport/herdr"
printf 'uncommitted sentinel\n' > "$SM_HOME/preserved.txt"
for outcome in closed idle alive; do
  printf '\nSCENARIO=%s\n' "$outcome"
  "$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" >/dev/null || fail "viewer stop failed"
  "$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" >/dev/null || fail 'viewer start failed'
grok_session=$(uuidgen | tr '[:upper:]' '[:lower:]')
created=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$SM_HOME" --label fm-labmate --no-focus) || fail "could not create the Grok home pane"
pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
workspace=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id // empty')
tab=$(printf '%s' "$created" | jq -r '.result.tab.tab_id // empty')
[ -n "$pane" ] && [ -n "$workspace" ] && [ -n "$tab" ] || fail "Herdr did not identify the Grok endpoint"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start fm-labmate --kind grok --pane "$pane" \
  -- --always-approve --reasoning-effort low --session-id "$grok_session" >/dev/null \
  || fail "could not start Grok in the named Herdr lab"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane zoom "$pane" --on >/dev/null \
  || fail "could not zoom the Grok lab pane"

{
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$pane"
  printf 'endpoint_task_id=labmate\nworktree=%s\nproject=%s\n' "$SM_HOME" "$SM_HOME"
  printf 'harness=grok\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\nbackend=herdr\n'
  printf 'home=%s\nprojects=\n' "$SM_HOME"
  printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
    "$HERDR_LAB_SESSION" "$workspace" "$tab" "$pane"
} > "$FM_HOME/state/labmate.meta"
meta_before=$(git hash-object "$FM_HOME/state/labmate.meta")

# Prove that the real foreground process runs in the home preserved below.
sm_canonical=$(cd "$SM_HOME" && pwd -P) || fail "the secondmate home disappeared"
pane_cwd=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$pane" \
  | jq -r '.result.pane.foreground_cwd // empty') || fail "could not read Grok's pane cwd"
[ -d "$pane_cwd" ] && [ "$(cd "$pane_cwd" && pwd -P)" = "$sm_canonical" ] \
  || fail "Grok pane cwd '$pane_cwd' does not match the preserved home '$sm_canonical'"
printf 'ok - Grok pane cwd matches the isolated secondmate home\n'

# Grok can still be painting its startup view when Herdr returns from agent
# start. Do not type into an unproven composer or a possible trust prompt.
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
caps=$(printf 'styled=1\ncursor=0\nidentity=1')
idle_screen=
grok_trusted=0
for _ in $(seq 1 40); do
  idle_screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source visible --format ansi) \
    || fail "could not read Grok's startup pane"
  [ "$(fm_composer_classify_screen "$caps" "$idle_screen")" = empty ] && break
  if [ "$grok_trusted" = 0 ] \
    && printf '%s' "$idle_screen" | grep -Fq 'Do you trust the contents of this directory?' \
    && printf '%s' "$idle_screen" | grep -Fq 'Yes, proceed'; then
    # This is the isolated git root whose foreground cwd was proved above.
    # Enter is Grok's documented folder-trust choice; never answer other gates.
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" Enter >/dev/null \
      || fail "could not accept Grok's disposable-home folder trust"
    grok_trusted=1
  fi
  sleep 0.5
done
if [ "$(fm_composer_classify_screen "$caps" "$idle_screen")" != empty ]; then
  printf '%s' "$idle_screen" > "$LAB_ROOT/unready-grok-screen.ansi"
  fail "Grok never presented a proven empty composer; capture saved in the retained lab"
fi


  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" labmate) || fail 'could not arm incarnation'
  printf 'busy_gen=%s\n' "$gen" >> "$FM_HOME/state/labmate.meta"
  mkdir -p "$LAB_ROOT/$outcome"
  rc=0
  out=$(env -u TMUX -u TMUX_PANE -u FM_BACKEND_HERDR_BIN -u FM_BACKEND_HERDR_CLIENT_SESSION \
    TMUX_TMPDIR="$LAB_TMUX_DIR" PATH="$LAB_ROOT/transport:$BASE_PATH" BASE_PATH="$BASE_PATH" \
    HERDR_LAB_HELPER="$HERDR_LAB_HELPER" TEST_SESSION="$HERDR_LAB_SESSION" TEST_MODE="$outcome" TEST_PANE="$pane" \
    TEST_TYPED="$LAB_ROOT/$outcome/typed" TEST_SENT="$LAB_ROOT/$outcome/sent" TEST_READY="$LAB_ROOT/$outcome/ready" \
    TEST_RESTARTING="$LAB_ROOT/$outcome/restarting" TEST_TRACE="$TEST_EVIDENCE/endpoint-transport.log" \
    FM_HOME="$FM_HOME" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" labmate exit 2>&1) || rc=$?
  printf 'exit-status=%s\n%s\n' "$rc" "$out"
  [ -f "$LAB_ROOT/$outcome/sent" ] || fail 'exit command did not reach real endpoint'
  case "$outcome" in
    closed) [ "$rc" = 0 ] && [[ "$out" = *'endpoint-gone labmate '* ]] || fail 'closed pane not confirmed' ;;
    idle) [ "$rc" = 0 ] && [[ "$out" = *'stopped labmate '* ]] && [[ "$out" != *endpoint-gone* ]] || fail 'restored idle not confirmed' ;;
    alive) [ "$rc" != 0 ] && [[ "$out" = *exit=unconfirmed* ]] || fail 'returning Grok incorrectly confirmed stopped' ;;
  esac
  if [ "$outcome" = alive ]; then
    [ "$(cat "$FM_HOME/state/labmate.busy-gen")" = "$gen" ] || fail 'unconfirmed exit retired incarnation'
  else
    [ ! -e "$FM_HOME/state/labmate.busy-gen" ] && [ ! -e "$FM_HOME/state/labmate.busy-state" ] || fail 'confirmed exit retained busy files'
    [ -z "$(sed -n 's/^busy_gen=//p' "$FM_HOME/state/labmate.meta")" ] || fail 'confirmed exit retained busy meta'
  fi
  [ "$(cat "$SM_HOME/preserved.txt")" = 'uncommitted sentinel' ] || fail 'uncommitted sentinel changed'
  [ "$(git -C "$SM_HOME" rev-parse HEAD)" = "$head_before" ] || fail 'checkout changed'
  [ "$(git hash-object "$SM_HOME/data/charter.md")" = "$charter_before" ] || fail 'charter changed'
  [ "$(git hash-object "$SM_HOME/state/child.meta")" = "$child_before" ] || fail 'child record changed'
  [ "$(git hash-object "$FM_HOME/state/labmate.inbox/001.msg")" = "$inbox_before" ] || fail 'inbox changed'
  printf 'durable state and uncommitted work preserved; busy-incarnation postcondition holds\n'
done
