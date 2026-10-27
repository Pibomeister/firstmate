#!/usr/bin/env bash
# Public adapter/runner regression: one detached attachment delivers an advisory
# gate or CI-ready return to its task inbox, without worker-side polling.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pipeline-wait)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
FAKE=$(fm_fakebin "$TMP_ROOT/fake")
fm_test_fake_tmux_send "$FAKE"
export PATH="$FAKE:$PATH"
cat > "$FAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NM_FIXTURE_ROOT/calls"
[ "$*" = 'axi run --wait 24h' ] || exit 90
if [ -e "$NM_FIXTURE_ROOT/timeout" ]; then
  rm -f "$NM_FIXTURE_ROOT/timeout"
  printf 'run:\n  id: fixture\n  status: running\n'
  exit 0
fi
while [ ! -e "$NM_FIXTURE_ROOT/trigger" ]; do
  [ "$SECONDS" -lt 60 ] || exit 75
  sleep 0.05
done
cat "$NM_FIXTURE_ROOT/return"
exit "$(cat "$NM_FIXTURE_ROOT/exit")"
SH
chmod +x "$FAKE/no-mistakes"

adapter() { FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent-no-mistakes.sh" "$@"; }
runner() { FM_HOME="$HOME_FIXTURE" "$ROOT/bin/fm-procevent.sh" "$@"; }
prepare() {
  HOME_FIXTURE="$TMP_ROOT/$1"
  export NM_FIXTURE_ROOT="$HOME_FIXTURE"
  mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/workdir"
  printf 'window=fmtest:fm-ship\nworktree=%s/workdir\nproject=fmtest\n' "$HOME_FIXTURE" > "$HOME_FIXTURE/state/ship.meta"
  printf '0\n' > "$HOME_FIXTURE/exit"
  fm_test_track_procevent_home "$HOME_FIXTURE"
}
await_result() {
  local i=0
  while [ "$i" -lt 1000 ]; do
    for RESULT in "$HOME_FIXTURE/state/procevent-inbox/"*.result; do
      [ -f "$RESULT" ] && return 0
    done
    i=$((i + 1)); sleep 0.05
  done
  fail 'attachment did not capture its return'
}

prepare gate
printf 'gate: review\nfindings[1]{id,action,description}:\n  r1,ask-user,decision required\n' > "$HOME_FIXTURE/return"
out=$(adapter arm ship 2>&1) || fail "arm did not confirm a listener: $out"
case "$out" in *'armed: '*) ;; *) fail "arm returned no confirmed listener: $out" ;; esac
adapter arm ship > "$TMP_ROOT/rearm.out" 2>&1 && fail 'duplicate arm started a second attachment'
FM_HOME="$HOME_FIXTURE/" "$ROOT/bin/fm-procevent-no-mistakes.sh" arm ship \
  > "$TMP_ROOT/alias.out" 2>&1 && fail 'equivalent home spelling started a second attachment'
for f in "$HOME_FIXTURE/state/procevent-inbox/"*.result; do
  [ ! -e "$f" ] || fail 'result appeared before the external condition cleared'
done
: > "$HOME_FIXTURE/trigger"
await_result
[ "$(adapter classify "$RESULT")" = gate ] || fail 'gate was not classified'
adapter read "$RESULT" | grep 'r1,ask-user,decision required' >/dev/null || fail 'finding changed in capture'
SOURCE=${RESULT##*/}; SOURCE=${SOURCE%.*.result}
SEQ=${RESULT%.result}; SEQ=${SEQ##*.}
runner reconcile >/dev/null 2>&1
runner reconcile >/dev/null 2>&1
[ "$(wc -l < "$HOME_FIXTURE/calls" | tr -d ' ')" = 1 ] || fail 'reconcile repeated an attachment with an open result'
set -- "$HOME_FIXTURE/state/ship.inbox/"*.msg
[ "$#" = 1 ] && [ -f "$1" ] || fail 'result did not reach exactly one task inbox record'
REC=$1
grep 'advisory' "$REC" >/dev/null || fail 'completion was not identified as advisory'
[ ! -e "${RESULT%.result}.handled" ] || fail 'capture was acknowledged before worker handling'
# A response-not-sent crash leaves both records recoverable; a later durable
# handling/escalation may acknowledge the source while the inbox still survives.
runner handled "$SOURCE" "$SEQ" >/dev/null || fail 'source acknowledgement failed'
[ -f "$REC" ] || fail 'source acknowledgement removed the unhandled inbox record'
runner reconcile >/dev/null 2>&1
[ -f "$REC" ] || fail 'partial acknowledgement lost the inbox recovery record'
mv "$REC" "$HOME_FIXTURE/state/ship.inbox/handled/"
runner handled "$SOURCE" "$SEQ" >/dev/null || fail 'repeat source acknowledgement failed'
runner reconcile >/dev/null 2>&1
for f in "$HOME_FIXTURE/state/ship.inbox/"*.msg; do [ ! -e "$f" ] || fail 'handled inbox record was resurrected'; done
pass 'gate capture remains recoverable until explicit handling; reconciliation and acknowledgements are idempotent'

prepare timeout-ci
: > "$HOME_FIXTURE/timeout"
printf 'outcome: checks-passed\nhelp[1]:\n  PR https://example.test/owner/repo/pull/1\n' > "$HOME_FIXTURE/return"
out=$(adapter arm ship 2>&1) || fail "CI attachment failed: $out"
: > "$HOME_FIXTURE/trigger"
await_result
[ "$(adapter classify "$RESULT")" = checks-passed ] || fail 'CI readiness waited for a terminal run instead'
[ "$(wc -l < "$HOME_FIXTURE/calls" | tr -d ' ')" = 2 ] || fail 'elapsed hold did not reattach inside the listener'
pass 'elapsed hold reattaches without a worker turn and CI-ready returns before merge'

for shape in error unknown empty; do
  prepare "$shape"
  case "$shape" in
    error) printf 'error: daemon unavailable\n' > "$HOME_FIXTURE/return"; printf '1\n' > "$HOME_FIXTURE/exit" ;;
    unknown) printf 'unrecognized response\n' > "$HOME_FIXTURE/return" ;;
    empty) : > "$HOME_FIXTURE/return" ;;
  esac
  : > "$HOME_FIXTURE/trigger"
  out=$(adapter arm ship 2>&1) || fail "completed $shape attachment did not arm/capture: $out"
  await_result
  expected=unknown; [ "$shape" != error ] || expected=error
  [ "$(adapter classify "$RESULT")" = "$expected" ] || fail "$shape result was silently treated as running or successful"
  grep 'attachment-exit:' "$RESULT" >/dev/null || fail 'capture omitted the CLI return status'
done
pass 'CLI errors, unknown and empty returns wake visibly with the return status'

prepare invalid
adapter arm missing > "$TMP_ROOT/missing.out" 2>&1 && fail 'missing task endpoint was accepted'
rm -f "$HOME_FIXTURE/state/ship.meta"
printf 'window=fmtest:fm-ship\nworktree=/nonexistent/fm-l3\nproject=fmtest\n' > "$HOME_FIXTURE/state/ship.meta"
adapter arm ship > "$TMP_ROOT/missing-dir.out" 2>&1 && fail 'missing worktree was accepted'
pass 'unusable task routing refuses before a successful wait'

# Run the real watcher reconciliation between registration and readiness, so
# the attachment has already completed when ensure-listening takes its stamp.
prepare precompleted
printf 'outcome: checks-passed\n' > "$HOME_FIXTURE/return"
: > "$HOME_FIXTURE/trigger"
export FM_TEST_REAL_BASH
FM_TEST_REAL_BASH=$(command -v bash)
export FM_TEST_CODE_ROOT="$ROOT"
cat > "$FAKE/bash" <<'SH'
#!/bin/bash
if [ "${1-}" = "$FM_TEST_CODE_ROOT/bin/fm-procevent.sh" ] && [ "${2-}" = ensure-listening ]; then
  "$FM_TEST_REAL_BASH" "$1" reconcile >/dev/null 2>&1 || exit 91
  ready=0
  for ignored in $(seq 1 200); do
    for result in "$NM_FIXTURE_ROOT/state/procevent-inbox/"*.result; do
      [ ! -f "$result" ] || ready=1
    done
    if [ "$ready" -eq 1 ] && [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/${3-}.claim" ]; then break; fi
    ready=0
    sleep 0.05
  done
  [ "$ready" -eq 1 ] || exit 92
  : > "$NM_FIXTURE_ROOT/captured-before-readiness"
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
chmod +x "$FAKE/bash"
out=$(adapter arm ship 2>&1) || fail "an already-captured completion failed readiness: $out"
[ -e "$HOME_FIXTURE/captured-before-readiness" ] || fail 'readiness race fixture did not complete before the check'
[ "$(wc -l < "$HOME_FIXTURE/calls" | tr -d ' ')" = 1 ] || fail 'readiness restarted a completed attachment'
pass 'a watcher-captured result confirms readiness without starting another attachment'
