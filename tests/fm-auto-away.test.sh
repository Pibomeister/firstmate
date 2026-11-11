#!/usr/bin/env bash
# Automatic away triggers through the authenticated check and normal AFK entry.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-auto-away)
AUTO="$ROOT/bin/fm-auto-away.sh"

world() {
  FM_HOME="$TMP_ROOT/$1"
  export FM_HOME FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
  mkdir -p "$FM_HOME/state" "$FM_HOME/config"
  printf 'timezone=UTC\n' > "$FM_HOME/config/auto-away"
  export FM_TEST_HARNESS=pi FM_TEST_SEAM=1
}

at() { FM_AUTO_AWAY_NOW="$1" "$AUTO" "${@:2}"; }
# 2026-11-11 22:00, 23:00, and 2026-11-12 00:00 UTC.
EARLY=1794434400
NIGHT=1794438000
MIDNIGHT=1794441600

world clock
at "$EARLY" captain-message
[ -z "$(at "$((NIGHT - 1))" check)" ] || fail 'early check produced output'
assert_absent "$FM_HOME/state/.wake-queue" 'clock fired before 23:00'
at "$NIGHT" check
assert_grep 'auto-away clock' "$FM_HOME/state/.wake-queue" 'night trigger did not queue entry'
at "$NIGHT" check
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" = 1 ] || fail 'duplicate check queued entry twice'
out=$(at "$NIGHT" enter "$EARLY")
assert_contains "$out" 'hold-for-return only' 'entry omitted the normal AFK announcement'
assert_present "$FM_HOME/state/.afk-contract" 'entry did not write the normal away record'
[ -z "$(at "$NIGHT" enter "$EARLY")" ] || fail 'duplicate entry announced twice'
[ -z "$(at "$NIGHT" check)" ] || fail 'away check produced another request'
[ "$(FM_HOME="$FM_HOME" "$ROOT/bin/fm-afk-contract.sh" words)" = '' ] || fail 'automatic entry invented away instructions'
# Return records activity before archiving the posture (the real return owner
# is exercised by fm-afk-return.test.sh).
at "$((NIGHT + 1))" captain-message
"$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
at "$((NIGHT + 2))" check
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" = 1 ] || fail 'return immediately requested another entry'

world silence
printf 'time=off\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$((EARLY + 7199))" check
assert_absent "$FM_HOME/state/.wake-queue" 'silence fired before two hours'
at "$((EARLY + 7200))" check
assert_grep 'silence' "$FM_HOME/state/.wake-queue" 'silence did not fire at two hours'
at "$((EARLY + 7200))" enter "$EARLY" >/dev/null
assert_present "$FM_HOME/state/.afk-contract" 'silence did not enter away mode'

world both
at "$((EARLY - 7200))" captain-message
at "$EARLY" check
at "$NIGHT" check
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" = 1 ] || fail 'second trigger duplicated the pending request'

world concurrent
at "$EARLY" captain-message
at "$NIGHT" enter "$EARLY" > "$FM_HOME/one.out" &
one=$!
at "$NIGHT" enter "$EARLY" > "$FM_HOME/two.out" &
two=$!
wait "$one"
wait "$two"
announcements=0
for output in "$FM_HOME/one.out" "$FM_HOME/two.out"; do
  if [ -s "$output" ]; then announcements=$((announcements + 1)); fi
done
[ "$announcements" = 1 ] || fail 'concurrent entry did not announce exactly once'

world stale
at "$EARLY" captain-message
at "$NIGHT" check
at "$((NIGHT + 1))" captain-message
[ -z "$(at "$((NIGHT + 1))" enter "$EARLY")" ] || fail 'stale request announced entry'
assert_absent "$FM_HOME/state/.afk-contract" 'new captain message did not cancel queued entry'
at "$((NIGHT + 2))" check
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" = 1 ] || fail 'night immediately overrode captain return'

world timezone
printf 'timezone=America/Mexico_City\nsilence-seconds=0\n' > "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$NIGHT" check
assert_absent "$FM_HOME/state/.wake-queue" 'clock used UTC instead of configured local zone'
at "$((NIGHT + 21600))" check
assert_present "$FM_HOME/state/.wake-queue" 'clock missed 23:00 in configured local zone'

world midnight
printf 'silence-seconds=0\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$MIDNIGHT" check
assert_present "$FM_HOME/state/.wake-queue" 'missed night trigger did not survive midnight'

world quiet
at "$EARLY" captain-message
FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null
at "$NIGHT" check
assert_absent "$FM_HOME/state/.wake-queue" 'automatic entry replaced explicit quiet mode'

world disabled
printf 'enabled=off\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$NIGHT" check
assert_absent "$FM_HOME/state/.wake-queue" 'disabled trigger queued entry'

world changed-settings
at "$EARLY" captain-message
at "$NIGHT" check
printf 'time=off\nsilence-seconds=7200\n' >> "$FM_HOME/config/auto-away"
[ -z "$(at "$NIGHT" enter "$EARLY")" ] || fail 'changed setting did not obsolete queued entry'
at "$MIDNIGHT" check
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" = 2 ] || fail 'obsolete request suppressed the next real crossing'

world configured
printf 'time=off\nsilence-seconds=60\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$((EARLY + 59))" check
assert_absent "$FM_HOME/state/.wake-queue" 'custom silence window fired early'
at "$((EARLY + 60))" check
assert_present "$FM_HOME/state/.wake-queue" 'custom silence window was ignored'

world session-open
# The previous session ended at 18:00 with no away mode; a new one opens 09:00.
at "$((EARLY - 14400))" captain-message
NEXT_MORNING=$((EARLY + 39600))
at "$NEXT_MORNING" arm >/dev/null
at "$NEXT_MORNING" check
at "$((NEXT_MORNING + 7199))" check
assert_absent "$FM_HOME/state/.wake-queue" 'session open entered away mode on a stale stamp or missed 23:00'
at "$((NEXT_MORNING + 7200))" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'silence after session open did not fire'

world custom-clock
printf 'time=22:30\nsilence-seconds=0\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$((EARLY + 1799))" check
assert_absent "$FM_HOME/state/.wake-queue" 'custom clock fired early'
at "$((EARLY + 1800))" check
assert_present "$FM_HOME/state/.wake-queue" 'custom clock was ignored'

world arm
at "$EARLY" arm >/dev/null
assert_present "$FM_HOME/state/auto-away.check-trust" 'arm did not authenticate scheduled check'
# Check execution must stay pinned to its home when the caller uses another home.
FM_HOME="$TMP_ROOT/foreign" FM_STATE_OVERRIDE="$TMP_ROOT/foreign/state" FM_CONFIG_OVERRIDE="$TMP_ROOT/foreign/config" \
  FM_AUTO_AWAY_NOW="$NIGHT" bash "$TMP_ROOT/arm/state/auto-away.check.sh"
assert_present "$TMP_ROOT/arm/state/.wake-queue" 'registered check lost its pinned home'
assert_absent "$TMP_ROOT/foreign/state/.wake-queue" 'registered check wrote into the caller home'

world invalid
printf 'silence-seconds=oops\n' >> "$FM_HOME/config/auto-away"
if at "$EARLY" check >/dev/null 2>&1; then fail 'invalid configuration was accepted'; fi
assert_absent "$FM_HOME/state/.wake-queue" 'invalid configuration queued entry'

world instructions
for harness in claude codex cursor grok pi pi-signed opencode omp agy muse unknown; do
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness")
  assert_contains "$out" 'bin/fm-auto-away.sh captain-message' "$harness lacks the activity instruction"
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness" --read-only 1)
  if [[ "$out" = *'bin/fm-auto-away.sh captain-message'* ]]; then fail "$harness read-only mode asks for activity writes"; fi
done
touch "$FM_HOME/.fm-secondmate-home"
at "$EARLY" arm >/dev/null
assert_absent "$FM_HOME/state/auto-away.check.sh" 'secondmate armed primary-only automatic entry'

pass 'fm-auto-away'
