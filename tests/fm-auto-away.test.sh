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
at "$NEXT_MORNING" arm --session-start >/dev/null
at "$NEXT_MORNING" check
at "$((NEXT_MORNING + 7199))" check
assert_absent "$FM_HOME/state/.wake-queue" 'session open entered away mode on a stale stamp or missed 23:00'
at "$((NEXT_MORNING + 7200))" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'silence after session open did not fire'

world handoff-successor
at "$((EARLY - 7200))" captain-message
printf '4242\n' > "$FM_HOME/state/.lock"
printf 'pid=4242\nhandoff=%s\n' "$FM_HOME/data/handoff.md" > "$FM_HOME/state/.handoff-successor"
at "$((EARLY - 600))" arm --session-start >/dev/null
assert_present "$FM_HOME/state/auto-away.check-trust" 'handoff successor did not register the check'
at "$EARLY" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'handoff successor start counted as captain activity'

world watchdog-restart
ln -s "$FM_HOME" "$TMP_ROOT/watchdog-restart-link"
canonical=$(cd -P "$FM_HOME" && pwd -P)
FM_HOME="$TMP_ROOT/watchdog-restart-link"
at "$((EARLY - 7200))" captain-message
mkdir -p "$FM_HOME/state/watchdog"
printf '1\tid1\t%s\tsubj\tstuck\trestart\tpending\ttoken=ab\n' "$canonical" > "$FM_HOME/state/watchdog/actions.tsv"
at "$((EARLY - 600))" arm --session-start >/dev/null
at "$EARLY" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'watchdog restart through a symlinked home counted as captain activity'

world watched-home-restart
at "$((EARLY - 7200))" captain-message
bash -c 'sleep 60; :' 'Watchdog restart of this firstmate home. Read the handoff first.' >/dev/null 2>&1 &
restarted=$!
printf '%s\n' "$restarted" > "$FM_HOME/state/.lock"
at "$((EARLY - 600))" arm --session-start >/dev/null
pkill -P "$restarted" 2>/dev/null || true
kill "$restarted" 2>/dev/null || true
wait "$restarted" 2>/dev/null || true
at "$EARLY" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'restart by another home watchdog counted as captain activity'

world captain-after-successor
at "$((EARLY - 7200))" captain-message
printf '4243\n' > "$FM_HOME/state/.lock"
printf 'pid=4242\n' > "$FM_HOME/state/.handoff-successor"
mkdir -p "$FM_HOME/state/watchdog"
canonical=$(cd -P "$FM_HOME" && pwd -P)
printf '1\tid1\t%s\tsubj\tstuck\trestart\tpending\tx\n2\tid1\t%s\tsubj\tstuck\trestart\tdone\ty\n' "$canonical" "$canonical" > "$FM_HOME/state/watchdog/actions.tsv"
at "$((EARLY - 600))" arm --session-start >/dev/null
at "$EARLY" check
assert_absent "$FM_HOME/state/.wake-queue" 'captain-opened start after an old successor did not count as activity'

world compact-silence
printf 'time=off\n' >> "$FM_HOME/config/auto-away"
at "$((EARLY - 7200))" captain-message
at "$((EARLY - 600))" arm >/dev/null
at "$EARLY" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'compaction re-arm moved the silence window'

world compact-night
printf 'silence-seconds=0\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
at "$((NIGHT + 300))" arm >/dev/null
at "$((NIGHT + 600))" check
assert_grep 'auto-away clock' "$FM_HOME/state/.wake-queue" 'compaction re-arm cancelled the nightly trigger'

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

world gnu-date
# GNU date reads -r as a reference file; only -d @epoch converts an epoch.
REAL_DATE=$(command -v date)
mkdir -p "$FM_HOME/bin"
cat > "$FM_HOME/bin/date" <<STUB
#!/usr/bin/env bash
[ "\$1" != -r ] || { echo "date: \$2: No such file or directory" >&2; exit 1; }
if [ "\$1" = -d ] && [[ "\$2" = @* ]]; then
  e=\${2#@}; shift 2
  "$REAL_DATE" -r "\$e" "\$@" 2>/dev/null || exec "$REAL_DATE" -d "@\$e" "\$@"
  exit
fi
exec "$REAL_DATE" "\$@"
STUB
chmod +x "$FM_HOME/bin/date"
printf 'silence-seconds=0\n' >> "$FM_HOME/config/auto-away"
at "$EARLY" captain-message
out=$(PATH="$FM_HOME/bin:$PATH" at "$NIGHT" check)
[ -z "$out" ] || fail "GNU date check reported a failure: $out"
assert_grep 'auto-away clock' "$FM_HOME/state/.wake-queue" 'GNU date on a Darwin-style host missed the clock trigger'

world broken-date
mkdir -p "$FM_HOME/bin"
printf '#!/usr/bin/env bash\ncase " $* " in *" -r "*|*" -d "*) exit 1 ;; esac\nexec %q "$@"\n' "$REAL_DATE" > "$FM_HOME/bin/date"
chmod +x "$FM_HOME/bin/date"
at "$EARLY" captain-message
out=$(PATH="$FM_HOME/bin:$PATH" at "$((EARLY + 7200))" check || true)
assert_contains "$out" 'auto-away check failed: cannot convert epoch' 'clock conversion failure was not reported on stdout'
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'clock conversion failure blocked the silence trigger'

world shim-failure
at "$EARLY" arm >/dev/null
[ -z "$(FM_AUTO_AWAY_NOW="$((EARLY + 60))" bash "$FM_HOME/state/auto-away.check.sh" 2>/dev/null)" ] || fail 'successful scheduled check was not silent'
printf 'silence-seconds=oops\n' >> "$FM_HOME/config/auto-away"
out=$(FM_AUTO_AWAY_NOW="$NIGHT" bash "$FM_HOME/state/auto-away.check.sh" 2>/dev/null || true)
assert_contains "$out" 'auto-away check failed: silence-seconds must be' 'scheduled check failure was not reported on stdout'
# The watcher wakes on any check stdout, so a persistent failure must print once.
for sweep in 1 2 3; do
  out=$(FM_AUTO_AWAY_NOW="$((NIGHT + sweep * 300))" bash "$FM_HOME/state/auto-away.check.sh" 2>/dev/null || true)
  [ -z "$out" ] || fail "persistent check failure was reported again on sweep $sweep: $out"
done
printf 'timezone=UTC\n' > "$FM_HOME/config/auto-away"
FM_AUTO_AWAY_NOW="$((NIGHT + 1200))" bash "$FM_HOME/state/auto-away.check.sh" >/dev/null 2>&1 || fail 'repaired check failed'
printf 'silence-seconds=oops\n' >> "$FM_HOME/config/auto-away"
out=$(FM_AUTO_AWAY_NOW="$((NIGHT + 1500))" bash "$FM_HOME/state/auto-away.check.sh" 2>/dev/null || true)
assert_contains "$out" 'auto-away check failed: silence-seconds must be' 'a failure that returned after a clean check was not reported'

world failed-entry
cp -R "$ROOT/bin" "$FM_HOME/failbin"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nerr=$(cat %q 2>/dev/null || true)\n[ -n "$err" ] || exec %q "$@"\nprintf "%%s\\n" "$err" >&2\nexit 1\n' \
  "$FM_HOME/launch-error" "$ROOT/bin/fm-afk-launch.sh" > "$FM_HOME/failbin/fm-afk-launch.sh"
failing_enter() { FM_AUTO_AWAY_NOW="$1" "$FM_HOME/failbin/fm-auto-away.sh" enter "$EARLY" 2>/dev/null; }
queued() { wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' '; }
at "$EARLY" captain-message
at "$NIGHT" check
printf 'launch lock busy\n' > "$FM_HOME/launch-error"
if out=$(failing_enter "$NIGHT"); then fail 'failed automatic entry reported success'; fi
assert_contains "$out" 'auto-away entry failed: exit 1: launch lock busy' 'first entry failure was not reported'
at "$((NIGHT + 60))" check
[ "$(queued)" = 2 ] || fail 'failed entry stranded its receipt and blocked a retry'
out=$(failing_enter "$((NIGHT + 60))") || fail 'an unchanged entry failure exited nonzero after it was reported'
[ -z "$out" ] || fail "an unchanged entry failure was reported again: $out"
at "$((NIGHT + 360))" check
[ "$(queued)" = 3 ] || fail 'an unchanged entry failure permanently suppressed retries'
printf 'cannot write away record\n' > "$FM_HOME/launch-error"
if out=$(failing_enter "$((NIGHT + 360))"); then fail 'changed entry failure reported success'; fi
assert_contains "$out" 'auto-away entry failed: exit 1: cannot write away record' 'a changed entry failure was not reported'
at "$((NIGHT + 660))" check
[ "$(queued)" = 4 ] || fail 'a changed entry failure blocked its retry'
rm -f "$FM_HOME/launch-error"
out=$(failing_enter "$((NIGHT + 660))")
assert_contains "$out" 'hold-for-return only' 'entry did not recover once the failure cleared without new activity'
assert_present "$FM_HOME/state/.afk-contract" 'recovered entry did not write the away record'
assert_absent "$FM_HOME/state/.auto-away-entry-failure" 'successful entry kept the failure record'

world off-start
printf 'enabled=off\n' >> "$FM_HOME/config/auto-away"
at "$((EARLY - 172800))" captain-message
at "$EARLY" arm --session-start >/dev/null
printf 'timezone=UTC\n' > "$FM_HOME/config/auto-away"
at "$((EARLY + 300))" arm >/dev/null
at "$((EARLY + 600))" check
assert_absent "$FM_HOME/state/.wake-queue" 'a captain-opened start with automatic entry off kept a days-old stamp'

world off-successor
printf 'enabled=off\n' >> "$FM_HOME/config/auto-away"
at "$((EARLY - 7200))" captain-message
printf '4242\n' > "$FM_HOME/state/.lock"
printf 'pid=4242\n' > "$FM_HOME/state/.handoff-successor"
at "$((EARLY - 600))" arm --session-start >/dev/null
printf 'timezone=UTC\n' > "$FM_HOME/config/auto-away"
at "$EARLY" check
assert_grep 'auto-away silence' "$FM_HOME/state/.wake-queue" 'a handoff successor with automatic entry off counted as captain activity'

world zone-data
for data in zone.tab tzdata.zi; do
  [ -f "/usr/share/zoneinfo/$data" ] || continue
  printf 'timezone=%s\n' "$data" > "$FM_HOME/config/auto-away"
  out=$(at "$EARLY" check || true)
  assert_contains "$out" "unknown timezone: $data" "non-zone file $data was accepted as a timezone"
  rm -f "$FM_HOME/state/.auto-away-failure"
done

world idle-supervision
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-stop-policy-lib.sh"
mkdir -p "$FM_HOME/data/orders/parked"
printf 'kind=hold\n' > "$FM_HOME/data/orders/parked/one.order"
fm_stop_policy_parked "$FM_HOME/state" "$FM_HOME" "$ROOT/bin" || fail 'fixture home did not park before arming'
at "$EARLY" arm --session-start >/dev/null
fm_supervision_status "$FM_HOME/state"
[ "$FM_SUP_NEEDED" = true ] || fail 'an armed idle home reported no supervision need'
if fm_stop_policy_parked "$FM_HOME/state" "$FM_HOME" "$ROOT/bin"; then fail 'an armed idle home parked'; fi
printf 'enabled=off\n' >> "$FM_HOME/config/auto-away"
at "$((EARLY + 60))" arm --session-start >/dev/null
fm_supervision_status "$FM_HOME/state"
[ "$FM_SUP_NEEDED" = false ] || fail 'a disabled idle home still reported supervision need'
fm_stop_policy_parked "$FM_HOME/state" "$FM_HOME" "$ROOT/bin" || fail 'a disabled idle home did not park'

world entry-arguments
if FM_AFK_MODE=away "$ROOT/bin/fm-afk-launch.sh" enter-auto --words 'ship it' >/dev/null 2>&1; then
  fail 'enter-auto accepted arguments'
fi
assert_absent "$FM_HOME/state/.afk-contract" 'enter-auto with arguments wrote an away record'

world instructions
for harness in claude codex cursor grok pi pi-signed opencode omp agy muse unknown; do
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness")
  assert_contains "$out" 'bin/fm-auto-away.sh captain-message' "$harness lacks the activity instruction"
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness" --read-only 1)
  if [[ "$out" = *'bin/fm-auto-away.sh captain-message'* ]]; then fail "$harness read-only mode asks for activity writes"; fi
done
touch "$FM_HOME/.fm-secondmate-home"
for harness in claude pi; do
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness")
  if [[ "$out" = *'bin/fm-auto-away.sh captain-message'* ]]; then fail "$harness secondmate home asks for activity writes"; fi
done
at "$EARLY" arm >/dev/null
assert_absent "$FM_HOME/state/auto-away.check.sh" 'secondmate armed primary-only automatic entry'

pass 'fm-auto-away'
