#!/usr/bin/env bash
set -u
. "$PWD/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-row-probe)
EVIDENCE=~/.no-mistakes/evidence/01M818HHAPS034DN81WTZ21CV8/validation-r4/row-probe
mkdir -p "$EVIDENCE"
trap 'rc=$?; cp "$TMP_ROOT"/rows-* "$TMP_ROOT"/slide-*json "$TMP_ROOT"/row-events.log "$EVIDENCE"/ 2>/dev/null || true; fm_test_cleanup; exit "$rc"' EXIT
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
 display-message) printf '%%1\n' ;;
 capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
REAL_JQ=$(command -v jq)
NOW_ONE=2026-08-28T10:00:00Z
EPOCH_ONE=1787911200
# The producer reads current state for every task through a sliding window, not
# in barriers. Five tasks run behind two slots: the first task's read cannot end
# until the other four have, so it only finishes if the window refills a slot the
# moment a fast task ends. A barrier, or serial reads, strand that read until the
# fake gives up, and the event order below fails. The assertion counts reads and
# their overlap, never elapsed time. Give the intentionally blocked read enough
# budget for all four peer reads, rather than the production per-read timeout.
SLIDE_HOME="$TMP_ROOT/slide-home"
mkdir -p "$SLIDE_HOME/state" "$SLIDE_HOME/data" "$SLIDE_HOME/config" "$SLIDE_HOME/projects"
SLIDE_HOME=$(cd "$SLIDE_HOME" && pwd -P)
printf '# Seeded Firstmate home\n' > "$SLIDE_HOME/AGENTS.md"
printf 'mate\n' > "$SLIDE_HOME/.fm-secondmate-home"
{
  printf '## In flight\n'
  n=1
  while [ "$n" -le 5 ]; do
    printf -- '- [ ] slide-%s - Window task %s (repo: firstmate) (kind: ship) (since 2026-08-28)\n' "$n" "$n"
    fm_git_init_commit "$SLIDE_HOME/projects/slide-$n"
    git -C "$SLIDE_HOME/projects/slide-$n" checkout -q -b "fm/slide-$n"
    fm_write_meta "$SLIDE_HOME/state/slide-$n.meta" \
      "window=fmtest:fm-slide-$n" "worktree=$SLIDE_HOME/projects/slide-$n" \
      "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" \
      "spawn_gen=fm.slide$n"
    printf 'working: window fixture\n' > "$SLIDE_HOME/state/slide-$n.status"
    n=$((n + 1))
  done
  printf '\n## Queued\n\n## Done\n'
} > "$SLIDE_HOME/data/backlog.md"
SLIDEBIN="$TMP_ROOT/slide-bin"
mkdir -p "$SLIDEBIN"
cat > "$SLIDEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_SLIDE_LOG:-}" ] && [ "$*" = "axi status" ] || exit 0
id=$(basename "$PWD")
case "$id" in slide-*) ;; *) exit 0 ;; esac
printf 'start %s\n' "$id" >> "$FM_TEST_SLIDE_LOG"
if [ "$id" = slide-1 ]; then
  n=0
  while [ "$(grep -c '^end ' "$FM_TEST_SLIDE_LOG")" -lt 4 ] && [ "$n" -lt 600 ]; do
    sleep 0.05
    n=$((n + 1))
  done
fi
printf 'end %s\n' "$id" >> "$FM_TEST_SLIDE_LOG"
exit 0
SH
chmod +x "$SLIDEBIN/no-mistakes"
run_slide() {  # <concurrency> [log]
  PATH="$SLIDEBIN:$FAKEBIN:$PATH" FM_TEST_SLIDE_LOG="${2:-}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SLIDE_HOME" \
    FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="$1" \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=120 FM_CREW_STATE_NM_TIMEOUT=90 \
    "$SNAPSHOT" --secondmate-home-summary
}
SLIDE_LOG="$TMP_ROOT/slide-events.log"
: > "$SLIDE_LOG"
run_slide 2 "$SLIDE_LOG" > "$TMP_ROOT/slide-window.json" \
  || fail "the sliding-window producer run failed"
[ "$(grep -c '^start ' "$SLIDE_LOG")" -eq 5 ] \
  || fail "the window did not read all five tasks once: $(tr '\n' ' ' < "$SLIDE_LOG")"
[ "$(tail -n 1 "$SLIDE_LOG")" = "end slide-1" ] \
  || fail "a free slot was not refilled while the slow read ran (barrier or serial reads): $(tr '\n' ' ' < "$SLIDE_LOG")"
max_inflight=$(awk '/^start /{n++; if (n>m) m=n} /^end /{n--} END{print m+0}' "$SLIDE_LOG")
[ "$max_inflight" -eq 2 ] \
  || fail "the window ran $max_inflight reads at once instead of its limit of 2: $(tr '\n' ' ' < "$SLIDE_LOG")"
# The composed summary must not depend on how many reads overlapped.
run_slide 1 > "$TMP_ROOT/slide-serial.json" || fail "the serial producer run failed"
run_slide 16 > "$TMP_ROOT/slide-wide.json" || fail "the wide producer run failed"
jq -S . "$TMP_ROOT/slide-serial.json" > "$TMP_ROOT/slide-serial.norm"
jq -S . "$TMP_ROOT/slide-window.json" > "$TMP_ROOT/slide-window.norm"
jq -S . "$TMP_ROOT/slide-wide.json" > "$TMP_ROOT/slide-wide.norm"
cmp -s "$TMP_ROOT/slide-serial.norm" "$TMP_ROOT/slide-window.norm" \
  || fail "overlapping reads changed the summary: $(diff "$TMP_ROOT/slide-serial.norm" "$TMP_ROOT/slide-window.norm" | head -5)"
cmp -s "$TMP_ROOT/slide-serial.norm" "$TMP_ROOT/slide-wide.norm" \
  || fail "a wide window changed the summary"
jq -e '(.invalidity.ids | sort) == ["slide-1","slide-2","slide-3","slide-4","slide-5"] and .counts.endpoints == 5' \
  "$TMP_ROOT/slide-window.json" >/dev/null \
  || fail "the window summary lost a task row: $(jq -c '[.invalidity, .counts]' "$TMP_ROOT/slide-window.json")"
pass "current-state reads refill a free slot and never change the summary"

# Row composition goes through the same window. The fake jq stands in for the
# row builder's final compose step (the only jq call that carries both the task
# id and the observation time): slide-1's compose cannot end until the other four
# composes have, so a serial row builder strands it and the event order fails.
# Reads here are instant, so only row composition can overlap. The comparison is
# on complete task rows from --json, because the summary projection drops fields.
ROWBIN="$TMP_ROOT/row-bin"
mkdir -p "$ROWBIN"
cat > "$ROWBIN/jq" <<'SH'
#!/usr/bin/env bash
id=
saw_observed=0
prev=
for arg in "$@"; do
  [ "$prev" = id ] && [ -z "$id" ] && id=$arg
  [ "$arg" = observed_at ] && saw_observed=1
  prev=$arg
done
case "$id" in slide-*) ;; *) id= ;; esac
if [ -n "${FM_TEST_ROW_LOG:-}" ] && [ -n "$id" ] && [ "$saw_observed" -eq 1 ]; then
  printf 'start %s\n' "$id" >> "$FM_TEST_ROW_LOG"
  if [ "$id" = slide-1 ]; then
    n=0
    while [ "$(grep -c '^end ' "$FM_TEST_ROW_LOG")" -lt 4 ] && [ "$n" -lt 600 ]; do
      sleep 0.05
      n=$((n + 1))
    done
  fi
  "$FM_TEST_REAL_JQ" "$@"
  rc=$?
  printf 'end %s\n' "$id" >> "$FM_TEST_ROW_LOG"
  exit "$rc"
fi
exec "$FM_TEST_REAL_JQ" "$@"
SH
chmod +x "$ROWBIN/jq"
run_rows() {  # <concurrency> [log]
  PATH="$ROWBIN:$SLIDEBIN:$FAKEBIN:$PATH" FM_TEST_REAL_JQ="$REAL_JQ" FM_TEST_ROW_LOG="${2:-}" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SLIDE_HOME" \
    FM_SNAPSHOT_NOW="$NOW_ONE" FM_SNAPSHOT_NOW_EPOCH="$EPOCH_ONE" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="$1" \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=120 FM_CREW_STATE_NM_TIMEOUT=90 \
    "$SNAPSHOT" --json
}
ROW_LOG="$TMP_ROOT/row-events.log"
: > "$ROW_LOG"
run_rows 2 "$ROW_LOG" > "$TMP_ROOT/rows-window.json" \
  || fail "the windowed row-composition run failed"
[ "$(grep -c '^start ' "$ROW_LOG")" -eq 5 ] \
  || fail "row composition did not run once per task: $(tr '\n' ' ' < "$ROW_LOG")"
[ "$(tail -n 1 "$ROW_LOG")" = "end slide-1" ] \
  || fail "row composition did not overlap behind the window (serial rows): $(tr '\n' ' ' < "$ROW_LOG")"
max_rows=$(awk '/^start /{n++; if (n>m) m=n} /^end /{n--} END{print m+0}' "$ROW_LOG")
[ "$max_rows" -eq 2 ] \
  || fail "row composition ran $max_rows at once instead of the window limit of 2: $(tr '\n' ' ' < "$ROW_LOG")"
run_rows 1 > "$TMP_ROOT/rows-serial.json" || fail "the serial row run failed"
run_rows 16 > "$TMP_ROOT/rows-wide.json" || fail "the wide row run failed"
jq -S '.tasks' "$TMP_ROOT/rows-serial.json" > "$TMP_ROOT/rows-serial.norm"
jq -S '.tasks' "$TMP_ROOT/rows-window.json" > "$TMP_ROOT/rows-window.norm"
jq -S '.tasks' "$TMP_ROOT/rows-wide.json" > "$TMP_ROOT/rows-wide.norm"
[ "$(jq 'length' "$TMP_ROOT/rows-serial.norm")" -eq 5 ] \
  || fail "the serial run did not produce five task rows"
cmp -s "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-window.norm" \
  || fail "overlapping row composition changed a task row: $(diff "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-window.norm" | head -5)"
cmp -s "$TMP_ROOT/rows-serial.norm" "$TMP_ROOT/rows-wide.norm" \
  || fail "a wide window changed a task row"
pass "row composition overlaps behind the window and keeps every task row identical"

