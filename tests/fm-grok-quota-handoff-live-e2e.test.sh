#!/usr/bin/env bash
# Opt-in real Grok-to-Codex secondmate handoff in a guarded, named Herdr lab.
# It proves process replacement and durable file preservation, not a live
# supervision watcher: this fixture has a deliberately minimal home.
# Run with FM_GROK_QUOTA_HANDOFF_LIVE=1 only while Grok credits are exhausted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_GROK_QUOTA_HANDOFF_LIVE grok codex herdr jq git tmux quota-axi

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
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
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-grok-quota-recovery) || exit 1
LAB_TMUX_DIR=
HERDR_ATTEMPTED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L fm-grok-handoff kill-server 2>/dev/null || true
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

grok_session=$(uuidgen | tr '[:upper:]' '[:lower:]')
started=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start fm-labmate \
  --cwd "$ROOT" -- grok --always-approve --reasoning-effort low --session-id "$grok_session") \
  || fail "could not start Grok in the named Herdr lab"
pane=$(printf '%s' "$started" | jq -r '.result.agent.pane_id // empty')
workspace=$(printf '%s' "$started" | jq -r '.result.agent.workspace_id // empty')
tab=$(printf '%s' "$started" | jq -r '.result.agent.tab_id // empty')
[ -n "$pane" ] && [ -n "$workspace" ] && [ -n "$tab" ] || fail "Herdr did not identify the Grok endpoint"
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

# Grok can still be painting its startup view when Herdr returns from agent
# start. Do not type into an unproven composer or a possible trust prompt.
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
caps=$(printf 'styled=1\ncursor=0\nidentity=1')
idle_screen=
for _ in $(seq 1 40); do
  idle_screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source visible --format ansi) \
    || fail "could not read Grok's startup pane"
  [ "$(fm_composer_classify_screen "$caps" "$idle_screen")" = empty ] && break
  sleep 0.5
done
if [ "$(fm_composer_classify_screen "$caps" "$idle_screen")" != empty ]; then
  printf '%s' "$idle_screen" > "$LAB_ROOT/unready-grok-screen.ansi"
  fail "Grok never presented a proven empty composer; capture saved in the retained lab"
fi

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$pane" 'Reply with one word: OK.' >/dev/null \
  || fail "could not type the Grok quota probe"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" Enter >/dev/null \
  || fail "could not submit the Grok quota probe"
paywall=
for _ in $(seq 1 60); do
  paywall=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source visible --format ansi) \
    || fail "could not read the Grok lab pane"
  printf '%s' "$paywall" | grep -Fq 'You hit your weekly limit.' && break
  sleep 0.5
done
if ! printf '%s' "$paywall" | grep -Fq 'You hit your weekly limit.'; then
  printf '%s' "$paywall" > "$LAB_ROOT/missing-paywall-screen.ansi"
  fail "Grok did not present the quota dialog; capture saved in the retained lab"
fi
printf '%s' "$paywall" | grep -Fq 'Buy more credits' || fail "the quota dialog had no purchase choice"
usage=$(grok usage "$grok_session") || fail "the Grok token meter was unavailable after the probe"
printf '%s' "$usage" | jq -e '.session | .inputTokens == 0 and .cachedReadTokens == 0 and .outputTokens == 0 and .modelCalls == 0' \
  >/dev/null || fail "the quota probe unexpectedly spent model tokens"

control() {
  FM_HOME="$FM_HOME" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=15 \
    FM_CONTROL_LAUNCH_WAIT=90 "$ROOT/bin/fm-control.sh" labmate "$@"
}
refused=$(control relaunch 2>&1) && fail "relaunch typed into the purchase dialog: $refused"
printf '%s' "$refused" | grep -Fq 'composer visibly holds pending text' \
  || fail "relaunch did not name the pending dialog: $refused"
[ "$(git hash-object "$FM_HOME/state/labmate.meta")" = "$meta_before" ] \
  || fail "the refused relaunch changed its task record"
[ "$(git hash-object "$SM_HOME/data/charter.md")" = "$charter_before" ] \
  || fail "the refused relaunch changed its charter"
[ "$(git hash-object "$FM_HOME/state/labmate.inbox/001.msg")" = "$inbox_before" ] \
  || fail "the refused relaunch changed its pending inbox message"
printf 'ok - named Herdr lab %s: paywall relaunch refused without changing the home or inbox\n' "$HERDR_LAB_SESSION"

interrupted=$(control interrupt 2>&1) || fail "the guarded Grok interrupt failed: $interrupted"
printf '%s' "$interrupted" | grep -Fq 'verified=agent-alive' \
  || fail "the interrupt did not prove Grok survived: $interrupted"
after_interrupt=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source visible --format ansi) \
  || fail "could not inspect the dismissed dialog"
[ "$(fm_composer_classify_screen "$caps" "$after_interrupt")" = empty ] \
  || fail "Grok's post-interrupt composer was not proven empty"
printf 'ok - named Herdr lab %s: exhausted quota dialog classified and dismissed; token meter stayed zero\n' \
  "$HERDR_LAB_SESSION"

stopped=$(control exit 2>&1) || fail "the guarded Grok exit failed: $stopped"
printf '%s' "$stopped" | grep -Fq 'endpoint-gone labmate' \
  || fail "the exit did not prove the Grok endpoint gone: $stopped"
# A secondmate with a gone endpoint uses its one recovery owner, not the
# relaunch rebind path reserved for ordinary tasks.
spawned=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_HOME" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
  "$ROOT/bin/fm-spawn.sh" labmate --secondmate --backend herdr 2>&1) \
  || fail "the guarded Codex secondmate respawn failed: $spawned"
printf '%s' "$spawned" | grep -Fq 'spawned labmate harness=codex kind=secondmate' \
  || fail "the respawn did not report the Codex replacement: $spawned"
meta="$FM_HOME/state/labmate.meta"
[ "$(sed -n 's/^harness=//p' "$meta" | tail -1)" = codex ] || fail "the task record did not select Codex"
recorded_home=$(sed -n 's/^home=//p' "$meta" | tail -1)
recorded_worktree=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
sm_canonical=$(cd "$SM_HOME" && pwd -P) || fail "the secondmate home disappeared"
[ -d "$recorded_home" ] && [ "$(cd "$recorded_home" && pwd -P)" = "$sm_canonical" ] \
  || fail "the secondmate home changed"
[ -d "$recorded_worktree" ] && [ "$(cd "$recorded_worktree" && pwd -P)" = "$sm_canonical" ] \
  || fail "the secondmate checkout changed"
[ "$(git -C "$SM_HOME" rev-parse HEAD)" = "$head_before" ] || fail "respawn moved the lab checkout despite sync being disabled"
[ "$(git hash-object "$SM_HOME/data/charter.md")" = "$charter_before" ] || fail "respawn changed the charter"
[ "$(git hash-object "$SM_HOME/state/child.meta")" = "$child_before" ] || fail "respawn changed the child task record"
inbox="$FM_HOME/state/labmate.inbox/001.msg"
[ -f "$inbox" ] || inbox="$FM_HOME/state/labmate.inbox/handled/001.msg"
[ -f "$inbox" ] && [ "$(git hash-object "$inbox")" = "$inbox_before" ] \
  || fail "respawn lost or changed the queued inbox message"
agents=
for _ in $(seq 1 40); do
  agents=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent list) || fail "could not read the replacement agent"
  printf '%s' "$agents" | jq -e '.result.agents[]? | select(.agent == "codex")' >/dev/null && break
  sleep 0.5
done
if ! printf '%s' "$agents" | jq -e '.result.agents[]? | select(.agent == "codex")' >/dev/null; then
  replacement_pane=$(sed -n 's/^herdr_pane_id=//p' "$meta" | tail -1)
  replacement_screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$replacement_pane" --source visible --format ansi 2>&1 || true)
  printf '%s' "$replacement_screen" > "$LAB_ROOT/failed-codex-screen.ansi"
  fail "Herdr did not report a live Codex agent: $agents; replacement pane captured in the retained lab"
fi
replacement_pane=$(sed -n 's/^herdr_pane_id=//p' "$meta" | tail -1)
for _ in $(seq 1 40); do
  replacement_screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$replacement_pane" --source visible --format ansi) \
    || fail "could not read the Codex replacement pane"
  printf '%s' "$replacement_screen" | grep -Fq 'Trust this folder?' && break
  sleep 0.5
done
if printf '%s' "$replacement_screen" | grep -Fq 'Trust this folder?'; then
  case "${CODEX_HOME:-}" in
    "$ROOT"/*) ;;
    *) fail "Codex trust requires CODEX_HOME inside the disposable worktree" ;;
  esac
  printf '%s' "$replacement_screen" | grep -Fq '1. Trust and continue' \
    || fail "Codex did not visibly select the lab-only trust choice"
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$replacement_pane" Enter >/dev/null \
    || fail "could not answer the disposable Codex trust prompt"
fi
printf 'ok - named Herdr lab %s: Codex replaced Grok through guarded respawn; checkout, charter, child record, and inbox survived\n' \
  "$HERDR_LAB_SESSION"

# Drop only this lab's server immediately after the exit key lands, then make
# its restart fail. This keeps the recorded pane unreachable for the proof read.
HERDR_REAL=$(command -v herdr)
cat > "$LAB_ROOT/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  server)
    [ ! -f "$HERDR_TEST_EXIT_SENT" ] || exit 1
    ;;
esac
"$HERDR_REAL" "$@"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
if [ "${1:-} ${2:-}" = 'pane send-text' ] && [ "${4:-}" = /quit ]; then
  : > "$HERDR_TEST_EXIT_TYPED"
elif [ "${1:-} ${2:-}" = 'pane send-keys' ] && [ "${4:-}" = enter ] && [ -f "$HERDR_TEST_EXIT_TYPED" ]; then
  "$HERDR_REAL" session stop "$HERDR_TEST_SESSION" --json --session "$HERDR_TEST_SESSION" >/dev/null || exit 1
  : > "$HERDR_TEST_EXIT_SENT"
fi
EOF
chmod 700 "$LAB_ROOT/herdr"
meta_before_unreachable=$(git hash-object "$meta")
unreachable=
for _ in $(seq 1 40); do
  unreachable=$(PATH="$LAB_ROOT:$PATH" HERDR_REAL="$HERDR_REAL" \
    HERDR_TEST_SESSION="$HERDR_LAB_SESSION" HERDR_TEST_EXIT_TYPED="$LAB_ROOT/exit-typed" \
    HERDR_TEST_EXIT_SENT="$LAB_ROOT/exit-sent" control exit 2>&1) \
    && fail "an unreachable recorded Herdr endpoint was reported stopped: $unreachable"
  [ -f "$LAB_ROOT/exit-sent" ] && break
  printf '%s' "$unreachable" | grep -Fq 'composer visibly holds pending text' \
    || fail "the guarded Codex exit refused before the lab server became unreachable: $unreachable"
  sleep 0.5
done
if [ ! -f "$LAB_ROOT/exit-sent" ]; then
  replacement_pane=$(sed -n 's/^herdr_pane_id=//p' "$meta" | tail -1)
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$replacement_pane" --source visible --format ansi \
    > "$LAB_ROOT/pending-codex-screen.ansi" 2>&1 || true
  fail "the exit key did not reach the real Herdr endpoint: $unreachable; Codex pane captured in the retained lab"
fi
printf '%s' "$unreachable" | grep -Fq 'exit=unconfirmed' \
  || fail "the unreachable endpoint was not marked unconfirmed: $unreachable"
printf '%s' "$unreachable" | grep -Fq "the recorded herdr session's server could not be started" \
  || fail "the refusal did not identify the unreachable recorded session: $unreachable"
[ "$(git hash-object "$meta")" = "$meta_before_unreachable" ] \
  || fail "the unconfirmed exit changed the secondmate task record"
printf 'ok - named Herdr lab %s: unreachable post-exit pane refused a stopped claim\n' "$HERDR_LAB_SESSION"
