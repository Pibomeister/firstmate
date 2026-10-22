#!/usr/bin/env bash
# tests/fm-park.test.sh - bin/fm-park.sh records a supervisor-side declared
# wait that the shared paused vocabulary (bin/fm-classify-lib.sh) reads as the
# task's current wait with its until time, ends when a later event lands, and
# refuses every malformed request without writing. The watcher-side absorb of a
# parked pane is pinned in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

PARK="$ROOT/bin/fm-park.sh"
TMP_ROOT=$(fm_test_tmproot fm-park-tests)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
printf 'window=test:fm-t1\n' > "$STATE/t1.meta"
printf 'working: delivered the PR\n' > "$STATE/t1.status"

park() {
  FM_STATE_OVERRIDE="$STATE" bash "$PARK" "$@"
}

future_epoch=$(( $(date +%s) + 86400 ))
future=$(date -u -r "$future_epoch" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d "@$future_epoch" '+%Y-%m-%dT%H:%MZ')
future_min_epoch=$(fm_utc_iso_to_epoch "$future")

out=$(park t1 --until "$future" --reason 'agent quota exhausted; PR awaiting upstream review') \
  || fail "fm-park refused a recorded task with a future until time"
case "$out" in "parked t1 until $future:"*) ;; *) fail "unexpected confirmation: $out" ;; esac
last=$(tail -n 1 "$STATE/t1.status")
status_is_paused "$last" || fail "the park line is not a paused declaration: $last"
case "$last" in "paused [key=fm-park] [at="*"]: "*) ;; *) fail "the park line is not keyed fm-park: $last" ;; esac
status_line_at_epoch "$last" >/dev/null || fail "the park line carries no emission time: $last"
[ "$(status_declared_wait_line "$STATE/t1.status")" = "$last" ] \
  || fail "the park line is not the task's current declared wait"
[ "$(status_paused_until "$last")" = "$future_min_epoch" ] \
  || fail "the park line's until time does not read back as $future: $last"
pass "fm-park appends a keyed paused declaration that reads back as the current wait with its until time"

printf 'working: quota reset, resuming\n' >> "$STATE/t1.status"
[ -z "$(status_declared_wait_line "$STATE/t1.status")" ] \
  || fail "a later worker event did not end the firstmate park"
pass "fm-park's wait ends as soon as the worker's next event lands"

before=$(cat "$STATE/t1.status")
refuse() {  # <description> <args...>
  local what=$1
  shift
  if park "$@" >/dev/null 2>&1; then
    fail "fm-park accepted $what"
  fi
  [ "$(cat "$STATE/t1.status")" = "$before" ] || fail "fm-park wrote to the status log while refusing $what"
}
refuse 'an unrecorded task' t2 --until "$future" --reason waiting
refuse 'a path-shaped task id' ../t1 --until "$future" --reason waiting
refuse 'a missing until time' t1 --reason waiting
refuse 'a non-UTC until time' t1 --until 2099-01-01T00:00 --reason waiting
refuse 'a date without a time' t1 --until 2099-01-01 --reason waiting
refuse 'a past until time' t1 --until 2020-01-01T00:00Z --reason waiting
refuse 'a blank reason' t1 --until "$future" --reason '   '
refuse 'a missing reason' t1 --until "$future"
refuse 'an unknown flag' t1 --until "$future" --reason waiting --key other
refuse 'a reason that would push the until time past the line cap' \
  t1 --until "$future" --reason "$(printf 'x%.0s' $(seq 1 240))"
[ ! -e "$STATE/t2.status" ] || fail "fm-park created a status log for an unrecorded task"
pass "fm-park refuses malformed requests and writes nothing"

park t1 --until "$future" --reason $'quota\nexhausted' >/dev/null || fail "fm-park refused a multi-line reason"
[ "$(tail -n 1 "$STATE/t1.status" | grep -c 'quota exhausted (parked by firstmate)')" = 1 ] \
  || fail "a multi-line reason was not flattened onto one status line: $(tail -n 2 "$STATE/t1.status")"
pass "fm-park flattens a multi-line reason onto one status line"
