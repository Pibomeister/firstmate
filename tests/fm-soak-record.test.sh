#!/usr/bin/env bash
# tests/fm-soak-record.test.sh - bin/fm-soak-record.sh records a soak run's
# inputs and never writes inside the soak home. readable-harnesses names the
# harnesses whose transcripts the measurement reads; inventory and start refuse
# an unreadable harness with exit 3; start writes soak.json; sample appends one
# load row (live workers from bin/fm-crew-state.sh, acknowledged wakes from
# bin/fm-wake-ledger.sh, status lines of the last hour, the recorded primary
# session id); finish keeps transcripts, handoff documents, watchdog rows and
# wake-ledger rows of the window, counts handoffs by the one rule (handoff
# document modification events plus completed watchdog restart ids, except a
# restart-requested one with such an event in its restart episode), refuses an
# --out that contains or sits inside the home, a --home other than the run's,
# and a session id that is not a plain name as a path, and lists harness
# violations. Every verb leaves the soak home byte-for-byte and
# mtime-for-mtime unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SOAK="$ROOT/bin/fm-soak-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-soak-record-tests)
T0=1800000000

# soak <now> <args...>: run the recorder under a fixed clock, with the fake
# no-mistakes and tmux first on PATH.
soak() {
  local now=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_HOME PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_TEST_SEAM=1 FM_NOW="$now" bash "$SOAK" "$@"
}

# snapshot <dir>: one line per path under <dir> with its type, mtime, size and
# content checksum, so any write, create, delete or touch changes the output.
snapshot() {
  ( cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then
        printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -f "$p" ]; then
        printf 'F %s %s %s\n' "$p" "$(perl -MTime::HiRes=lstat -e 'print((lstat $ARGV[0])[9])' "$p")" "$(cksum < "$p")"
      else
        printf 'D %s %s\n' "$p" "$(perl -MTime::HiRes=lstat -e 'print((lstat $ARGV[0])[9])' "$p")"
      fi
    done )
}

names() {  # <dir>: the entry names in <dir>, sorted
  ( cd "$1" && for n in *; do [ -e "$n" ] && printf '%s\n' "$n"; done ) | LC_ALL=C sort
}

assert_home_unchanged() {  # <home> <before> <label>
  local after
  after=$(snapshot "$1")
  [ "$after" = "$2" ] || fail "$3 wrote inside the soak home:"$'\n'"$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$after"))"
}

# The fake no-mistakes answers `axi status` with the run file named after the
# branch checked out in its working directory, so each task copy gets its own
# run; tmux reports a quiet pane, and lists the windows named in
# FM_FAKE_TMUX_WINDOWS, so a task window only exists where a test names it.
# When FM_FAKE_TMUX_HOOK names a script, tmux runs it first, so a test can act
# during task classification.
make_fakebin() {
  local fb="$TMP_ROOT/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "axi status"|"axi ")
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
    f="$FM_FAKE_NM_RUNS/$(printf '%s' "$branch" | tr '/' '_')"
    [ -f "$f" ] && cat "$f"
    exit 0 ;;
  "daemon status"|"daemon ")
    printf '  ● daemon running (pid 4242)\n'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TMUX_HOOK:-}" ] || bash "$FM_FAKE_TMUX_HOOK"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  list-windows) [ -z "${FM_FAKE_TMUX_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_TMUX_WINDOWS" ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  FM_FAKE_NM_RUNS="$TMP_ROOT/runs"
  mkdir -p "$FM_FAKE_NM_RUNS"
  export FM_FAKE_NM_RUNS
}

# task_copy <name> <branch>: a throwaway git repo on <branch>; leaves its path
# in TASK_DIR and its HEAD in TASK_HEAD.
task_copy() {
  local dir="$TMP_ROOT/copies/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$2"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  TASK_HEAD=$(git -C "$dir" rev-parse HEAD)
  TASK_DIR=$dir
}

write_run() {  # <branch> <status-word> <head>
  local f
  f="$FM_FAKE_NM_RUNS/$(printf '%s' "$1" | tr '/' '_')"
  if [ "$2" = running ]; then
    cat > "$f" <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "$3"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
  else
    cat > "$f" <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$3"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
  fi
}

# make_home <name>: a soak home that is a git repository, with three task
# records: feat-a with a running run (working), feat-c parked at a gate
# (parked), feat-z with no run and a quiet pane (not live). feat-c runs a
# harness outside the declared set.
make_home() {
  local home="$TMP_ROOT/$1" wt
  mkdir -p "$home/state" "$home/data" "$home/config"
  git -C "$home" init -q
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m home
  task_copy "$1-a" fm/feat-a
  wt=$TASK_DIR
  write_run fm/feat-a running "$TASK_HEAD"
  fm_write_meta "$home/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$wt" "kind=ship" "backend=tmux" "harness=claude"
  task_copy "$1-c" fm/feat-c
  wt=$TASK_DIR
  write_run fm/feat-c parked "$TASK_HEAD"
  fm_write_meta "$home/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$wt" "kind=ship" "backend=tmux" "harness=codex"
  printf 'needs-decision [at=%s]: review gate\n' $((T0 - 30)) > "$home/state/feat-c.status"
  task_copy "$1-z" fm/feat-z
  wt=$TASK_DIR
  fm_write_meta "$home/state/feat-z.meta" "window=fm:fm-feat-z" "worktree=$wt" "kind=ship" "backend=tmux" "harness=codex"
  printf '%s\n' "$home"
}

test_readable_harnesses_and_inventory() {
  local home out rc before
  home=$(make_home inv)
  before=$(snapshot "$home")
  out=$(soak "$T0" readable-harnesses) || fail "readable-harnesses failed"
  assert_equals claude "$out" "readable-harnesses names exactly claude"
  out=$(soak "$T0" inventory --home "$home" --harness claude); rc=$?
  assert_equals 0 "$rc" "an all-readable inventory exits 0"
  assert_equals 'claude readable' "$out" "inventory of claude"
  out=$(soak "$T0" inventory --home "$home" --harness claude --harness codex); rc=$?
  assert_equals 3 "$rc" "an inventory with an unreadable harness exits 3"
  assert_equals $'claude readable\ncodex unreadable' "$out" "inventory lists each declared harness"
  soak "$T0" inventory --home "$home" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "inventory with no --harness is a usage error"
  soak "$T0" inventory --home "$TMP_ROOT/no-such-home" --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "inventory of a missing home is a usage error"
  assert_home_unchanged "$home" "$before" "inventory"
  pass "readable-harnesses names claude and inventory exits 3 on an unreadable harness"
}

test_start_records_the_run_and_refuses_unreadable() {
  local home out before rc json
  home=$(make_home start)
  out="$TMP_ROOT/start-out"
  before=$(snapshot "$home")
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude --harness codex > /dev/null 2>&1; rc=$?
  assert_equals 3 "$rc" "start refuses an unreadable harness with exit 3"
  [ ! -e "$out/soak.json" ] || fail "a refused start wrote soak.json"
  soak "$T0" start --home "$home" --out "$out" --label nightly --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses a label other than baseline or post-change"
  soak "$T0" start --home "$home" --out "$home/data/soak" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses an --out inside the soak home"
  ln -s "$home/data" "$TMP_ROOT/start-link"
  soak "$T0" start --home "$home" --out "$TMP_ROOT/start-link" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses an --out that is a symlink into the soak home"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON"
  assert_equals baseline "$(jq -r .label <<<"$json")" "soak.json label"
  assert_equals "$home" "$(jq -r .home <<<"$json")" "soak.json home"
  assert_equals "$(git -C "$home" rev-parse HEAD)" "$(jq -r .revision <<<"$json")" "soak.json revision is the home HEAD"
  assert_equals "$T0" "$(jq -r .started_at <<<"$json")" "soak.json started_at is fm_now"
  assert_equals '["claude"]' "$(jq -c .harnesses <<<"$json")" "soak.json harnesses"
  assert_equals '[]' "$(jq -c .session_ids <<<"$json")" "soak.json session_ids starts empty"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 1 "$rc" "start refuses to overwrite a started run"
  assert_home_unchanged "$home" "$before" "start"
  pass "start records label, home, revision, started_at and harnesses, and refuses an unreadable harness"
}

test_sample_appends_one_load_row() {
  local home out before row rc now=$((T0 + 4000))
  home=$(make_home sample)
  out="$TMP_ROOT/sample-out"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  # Wake ledger: one ack before the hour, two inside it, one at now (outside).
  {
    printf '%s\tack\tg1\t3\t1,2,3\t["a","b","c"]\n' $((now - 4000))
    printf '%s\tack\tg1\t5\t4,5\t["d","e"]\n' $((now - 3600))
    printf '%s\tpruned\t-\t-\t6\t["f"]\n' $((now - 10))
    printf '%s\tack\tg1\t7\t7\t["g"]\n' "$now"
  } > "$home/state/wake-ledger.tsv"
  # Status lines: two inside the hour, one before it, one at now, one undated.
  {
    printf 'working [at=%s]: old\n' $((now - 3601))
    printf 'paused [at=%s]: edge\n' $((now - 3600))
    printf 'done [at=%s]: recent\n' $((now - 1))
    printf 'done [at=%s]: now\n' "$now"
    printf 'done: undated\n'
  } > "$home/state/feat-a.status"
  printf 'sess-1\nanchor_pid=1\n' > "$home/state/.lock-session"
  before=$(snapshot "$home")
  soak "$now" sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  assert_home_unchanged "$home" "$before" "sample"
  # feat-c.status carries one line at T0-30, outside [now-3600, now).
  row=$(sed -n '1p' "$out/load.tsv")
  assert_equals "$now"$'\t'2$'\t'3$'\t'2$'\t'sess-1 "$row" "load row: epoch, live workers, wake acks, status lines, session id"
  rm "$home/state/.lock-session"
  before=$(snapshot "$home")
  soak $((now + 600)) sample --home "$home" --out "$out" > /dev/null || fail "second sample failed"
  assert_home_unchanged "$home" "$before" "second sample"
  assert_equals 2 "$(wc -l < "$out/load.tsv" | tr -d ' ')" "a second sample appends a second row"
  assert_equals '-' "$(sed -n '2p' "$out/load.tsv" | cut -f5)" "no recorded session id samples as -"
  soak "$now" sample --home "$home" --out "$TMP_ROOT/never-started" > /dev/null 2>&1 && fail "sample without start succeeded"
  # A kept file that is a symlink into the home is refused, not followed.
  mv "$out/load.tsv" "$TMP_ROOT/sample-load.tsv"
  ln -s "$home/state/feat-a.status" "$out/load.tsv"
  before=$(snapshot "$home")
  soak $((now + 1200)) sample --home "$home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "sample refuses a load.tsv that is a symlink"
  assert_home_unchanged "$home" "$before" "sample through a symlinked load.tsv"
  pass "sample appends epoch, live workers, acknowledged wakes, status lines and the session id"
}

# finish_fixture <name> <label>: a started and sampled run with transcripts,
# handoff documents, watchdog rows and wake-ledger rows inside and outside the
# window [T0, T0+1000]. Sets HOME_DIR, OUT_DIR, WD_DIR, TR_DIR.
finish_fixture() {
  local name=$1 label=$2 other
  HOME_DIR=$(make_home "$name")
  OUT_DIR="$TMP_ROOT/$name-out"
  WD_DIR="$TMP_ROOT/$name-watchdog"
  TR_DIR="$TMP_ROOT/$name-transcripts"
  mkdir -p "$WD_DIR/handoffs" "$TR_DIR"
  soak "$T0" start --home "$HOME_DIR" --out "$OUT_DIR" --label "$label" --harness claude > /dev/null || fail "start failed"
  printf 'sess-1\n' > "$HOME_DIR/state/.lock-session"
  soak $((T0 + 100)) sample --home "$HOME_DIR" --out "$OUT_DIR" > /dev/null || fail "sample failed"
  printf 'sess-gone\n' > "$HOME_DIR/state/.lock-session"
  soak $((T0 + 200)) sample --home "$HOME_DIR" --out "$OUT_DIR" > /dev/null || fail "sample failed"
  # Transcripts: sess-1 and sess-2 changed in the window, sess-old before it.
  printf '{"t":1}\n' > "$TR_DIR/sess-1.jsonl"; fm_touch_epoch $((T0 + 500)) "$TR_DIR/sess-1.jsonl"
  printf '{"t":2}\n' > "$TR_DIR/sess-2.jsonl"; fm_touch_epoch $((T0 + 600)) "$TR_DIR/sess-2.jsonl"
  printf '{"t":0}\n' > "$TR_DIR/sess-old.jsonl"; fm_touch_epoch $((T0 - 100)) "$TR_DIR/sess-old.jsonl"
  # Handoff documents: handoff-a in the window and named again by the order
  # record (one document, counted once), handoff-b in the window, handoff-old
  # before it.
  printf 'a\n' > "$HOME_DIR/data/handoff-a.md"; fm_touch_epoch $((T0 + 300)) "$HOME_DIR/data/handoff-a.md"
  printf 'b\n' > "$HOME_DIR/data/handoff-b.md"; fm_touch_epoch $((T0 + 400)) "$HOME_DIR/data/handoff-b.md"
  printf 'old\n' > "$HOME_DIR/data/handoff-old.md"; fm_touch_epoch $((T0 - 50)) "$HOME_DIR/data/handoff-old.md"
  printf 'doc=%s\nat=%s\nowner=1\n' "$HOME_DIR/data/handoff-a.md" $((T0 + 300)) > "$HOME_DIR/state/.order-handoff"
  # Watchdog rows: epoch id home subject symptom action phase detail.
  other="$TMP_ROOT/other-home"
  {
    printf '%s\tn1\t%s\tprimary\thandoff-request\tnudge\tpending\tcontext is low\n' $((T0 + 250)) "$HOME_DIR"
    printf '%s\tw1\t%s\tprimary\trestart-requested\trestart\tpending\ttoken=1\n' $((T0 + 700)) "$HOME_DIR"
    printf '%s\tw1\t%s\tprimary\trestart-requested\trestart\tdone\tpickup verified\n' $((T0 + 710)) "$HOME_DIR"
    printf '%s\tw2\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' $((T0 + 720)) "$HOME_DIR"
    printf '%s\tw3\t%s\tprimary\tagent-gone\trestart\tfailed\tno pickup\n' $((T0 + 730)) "$HOME_DIR"
    printf '%s\tw4\t%s\tprimary\tfrozen\trestart\tdone\tother home\n' $((T0 + 740)) "$other"
    printf '%s\tw5\t%s\tprimary\tfrozen\trestart\tdone\tbefore\n' $((T0 - 10)) "$HOME_DIR"
    printf '%s\tw6\t%s\tprimary\tfrozen\tnudge\tdone\tnudged\n' $((T0 + 750)) "$HOME_DIR"
  } > "$WD_DIR/actions.tsv"
  printf 'wd\n' > "$WD_DIR/handoffs/primary-1.md"; fm_touch_epoch $((T0 + 705)) "$WD_DIR/handoffs/primary-1.md"
  printf 'wd-old\n' > "$WD_DIR/handoffs/primary-0.md"; fm_touch_epoch $((T0 - 500)) "$WD_DIR/handoffs/primary-0.md"
  # Wake ledger: one row before the window, two inside it, one after it.
  {
    printf '%s\tack\tg1\t1\t1\t["a"]\n' $((T0 - 1))
    printf '%s\tack\tg1\t2\t2\t["b"]\n' "$T0"
    printf '%s\tpruned\t-\t-\t3\t["c"]\n' $((T0 + 1000))
    printf '%s\tack\tg1\t4\t4\t["d"]\n' $((T0 + 1001))
  } > "$HOME_DIR/state/wake-ledger.tsv"
}

test_finish_keeps_the_window_and_counts_handoffs() {
  local before json ids
  finish_fixture fin baseline
  before=$(snapshot "$HOME_DIR")
  soak $((T0 + 1000)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null || fail "finish failed"
  assert_home_unchanged "$HOME_DIR" "$before" "finish"
  json=$(jq -c . "$OUT_DIR/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals $((T0 + 1000)) "$(jq -r .finished_at <<<"$json")" "finished_at is fm_now"
  ids=$(jq -c '[.session_ids[] | [.id, .transcript]]' <<<"$json")
  assert_equals '[["sess-1","transcripts/sess-1.jsonl"],["sess-2","transcripts/sess-2.jsonl"],["sess-gone","missing-transcript"]]' \
    "$ids" "session ids are the sampled ids plus the window's transcripts"
  cmp -s "$TR_DIR/sess-1.jsonl" "$OUT_DIR/transcripts/sess-1.jsonl" || fail "sess-1 transcript not kept"
  cmp -s "$TR_DIR/sess-2.jsonl" "$OUT_DIR/transcripts/sess-2.jsonl" || fail "sess-2 transcript not kept"
  [ ! -e "$OUT_DIR/transcripts/sess-old.jsonl" ] || fail "a transcript from before the window was kept"
  assert_equals $'handoff-a.md\nhandoff-b.md' "$(names "$OUT_DIR/handoffs")" \
    "the window's handoff documents are kept once each"
  assert_equals $'n1\nw1\nw1\nw2\nw3\nw6' "$(cut -f2 "$OUT_DIR/watchdog/actions.tsv")" \
    "watchdog rows of this home inside the window are kept"
  assert_equals primary-1.md "$(names "$OUT_DIR/watchdog/handoffs")" "the window's watchdog handoff files are kept"
  assert_equals $'2\n3' "$(cut -f5 "$OUT_DIR/wake-ledger.tsv")" "the window's wake-ledger rows are kept"
  # handoff-a and handoff-b, plus the frozen restart w2; the requested restart
  # w1 had both documents written in its episode (from the nudge n1), and the
  # failed restart w3 and the watchdog's own handoff file do not count.
  assert_equals 3 "$(jq -r .handoff_count <<<"$json")" "handoff count"
  assert_equals '[{"kind":"undeclared-harness","task":"feat-c","harness":"codex"}]' "$(jq -c .violations <<<"$json")" \
    "a live task on an undeclared harness is a violation and a non-live one is not"
  pass "finish keeps the window's transcripts, handoffs, watchdog and wake-ledger rows and counts handoffs once"
}

test_finish_post_change_names_missing_activity_sources() {
  local before json
  finish_fixture post post-change
  # The order record names a document outside data/: kept and counted too.
  printf 'order\n' > "$TMP_ROOT/post-order-doc.md"; fm_touch_epoch $((T0 + 800)) "$TMP_ROOT/post-order-doc.md"
  printf 'doc=%s\nat=%s\nowner=1\n' "$TMP_ROOT/post-order-doc.md" $((T0 + 800)) > "$HOME_DIR/state/.order-handoff"
  before=$(snapshot "$HOME_DIR")
  soak $((T0 + 1000)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null || fail "finish failed"
  assert_home_unchanged "$HOME_DIR" "$before" "post-change finish"
  json=$(jq -c . "$OUT_DIR/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 4 "$(jq -r .handoff_count <<<"$json")" "an order document outside data/ counts as its own handoff"
  [ -f "$OUT_DIR/handoffs/order-post-order-doc.md" ] || fail "the order record's document was not kept"
  if [ -e "$ROOT/bin/fm-activity-sources.sh" ]; then
    assert_contains "$(jq -c .violations <<<"$json")" '"kind":"no-activity-source"' "post-change activity-source check"
  else
    assert_contains "$(jq -c .violations <<<"$json")" '{"kind":"activity-sources-unavailable","harness":"claude"}' \
      "post-change names the missing activity-source owner"
  fi
  soak $((T0 + 1100)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null 2>&1 && fail "a second finish succeeded"
  pass "post-change finish names each declared harness without an activity source"
}

# rewrite_handoff <home> <epoch> <text>: rewrite data/handoff-main.md at <epoch>.
rewrite_handoff() {
  printf '%s\n' "$3" > "$1/data/handoff-main.md"
  fm_touch_epoch "$2" "$1/data/handoff-main.md"
}

test_finish_counts_a_lean_handoff_restart() {
  local home out wd tr json
  home=$(make_home lean)
  out="$TMP_ROOT/lean-out"; wd="$TMP_ROOT/lean-watchdog"; tr="$TMP_ROOT/lean-transcripts"
  mkdir -p "$wd/handoffs" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  # Low context: the handoff nudge times out with no session handoff document,
  # and the restart goes ahead on the watchdog's lean handoff.
  {
    printf '%s\tn1\t%s\tprimary\thandoff-request\tnudge\tpending\tcontext is low\n' $((T0 + 100)) "$home"
    printf '%s\tn1\t%s\tprimary\thandoff-request\tnudge\ttimed-out\tno full handoff\n' $((T0 + 700)) "$home"
    printf '%s\tr1\t%s\tprimary\trestart-requested\trestart\tpending\thandoff=%s\n' $((T0 + 710)) "$home" "$wd/handoffs/lean.md"
    printf '%s\tr1\t%s\tprimary\trestart-requested\trestart\tdone\tpickup verified\n' $((T0 + 720)) "$home"
  } > "$wd/actions.tsv"
  printf 'lean\n' > "$wd/handoffs/lean.md"; fm_touch_epoch $((T0 + 710)) "$wd/handoffs/lean.md"
  soak $((T0 + 400)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 1 "$(jq -r .handoff_count <<<"$json")" "a lean-handoff restart counts as one handoff"
  pass "a low-context restart on the watchdog's lean handoff counts"
}

test_finish_counts_each_rewrite_of_one_handoff_document() {
  local home out wd tr json before i at
  home=$(make_home rewrite)
  out="$TMP_ROOT/rewrite-out"; wd="$TMP_ROOT/rewrite-watchdog"; tr="$TMP_ROOT/rewrite-transcripts"
  mkdir -p "$wd/handoffs" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  # Three low-context episodes in the watchdog's order: the handoff nudge, the
  # session's full handoff rewritten into the same document, the restart
  # request, then the restart's pending and done rows.
  : > "$wd/actions.tsv"
  for i in 1 2 3; do
    at=$((T0 + i * 200))
    printf '%s\tn%s\t%s\tprimary\thandoff-request\tnudge\tpending\tcontext is low\n' "$at" "$i" "$home" >> "$wd/actions.tsv"
    rewrite_handoff "$home" $((at + 20)) "handoff $i"
    printf '%s\tr%s\t%s\tprimary\trestart-requested\trestart\tpending\ttoken=%s\n' $((at + 40)) "$i" "$home" "$i" >> "$wd/actions.tsv"
    printf '%s\tr%s\t%s\tprimary\trestart-requested\trestart\tdone\tpickup verified\n' $((at + 60)) "$i" "$home" >> "$wd/actions.tsv"
    before=$(snapshot "$home")
    soak $((at + 80)) sample --home "$home" --out "$out" > /dev/null || fail "sample $i failed"
    assert_home_unchanged "$home" "$before" "sample $i"
  done
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 3 "$(jq -r .handoff_count <<<"$json")" "each full handoff counts once, and once per rewrite"
  assert_equals handoff-main.md "$(names "$out/handoffs")" "the rewritten document is kept once"
  pass "the same handoff document rewritten across restarts counts once per restart"
}

test_finish_counts_a_late_full_handoff_once() {
  local home out wd tr json
  home=$(make_home late-full)
  out="$TMP_ROOT/late-full-out"; wd="$TMP_ROOT/late-full-watchdog"; tr="$TMP_ROOT/late-full-transcripts"
  mkdir -p "$wd/handoffs" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  # The nudge times out, then the session writes its full handoff before the
  # restart's pending row.
  {
    printf '%s\tn1\t%s\tprimary\thandoff-request\tnudge\tpending\tcontext is low\n' $((T0 + 100)) "$home"
    printf '%s\tn1\t%s\tprimary\thandoff-request\tnudge\ttimed-out\tno full handoff\n' $((T0 + 700)) "$home"
    printf '%s\tr1\t%s\tprimary\trestart-requested\trestart\tpending\ttoken=1\n' $((T0 + 710)) "$home"
    printf '%s\tr1\t%s\tprimary\trestart-requested\trestart\tdone\tpickup verified\n' $((T0 + 720)) "$home"
  } > "$wd/actions.tsv"
  rewrite_handoff "$home" $((T0 + 705)) "late handoff"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 1 "$(jq -r .handoff_count <<<"$json")" "a late full handoff before the restart counts once"
  pass "a full handoff written after the nudge timed out but before the restart counts once"
}

test_sample_records_each_handoff_document_event() {
  local home out wd tr json
  home=$(make_home events)
  out="$TMP_ROOT/events-out"; wd="$TMP_ROOT/events-watchdog"; tr="$TMP_ROOT/events-transcripts"
  mkdir -p "$wd/handoffs" "$tr"
  : > "$wd/actions.tsv"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  # The same document rewritten twice, each rewrite sampled, with no restart.
  rewrite_handoff "$home" $((T0 + 100)) "first"
  soak $((T0 + 150)) sample --home "$home" --out "$out" > /dev/null || fail "sample 1 failed"
  assert_equals 1 "$(wc -l < "$out/handoff-events.tsv" | tr -d ' ')" "the first sample records the document event"
  rewrite_handoff "$home" $((T0 + 300)) "second"
  soak $((T0 + 350)) sample --home "$home" --out "$out" > /dev/null || fail "sample 2 failed"
  soak $((T0 + 400)) sample --home "$home" --out "$out" > /dev/null || fail "sample 3 failed"
  assert_equals 2 "$(wc -l < "$out/handoff-events.tsv" | tr -d ' ')" "each new event is recorded once"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 2 "$(jq -r .handoff_count <<<"$json")" "two sampled rewrites with no restart count 2"
  pass "sample records each handoff-document modification event"
}

test_sample_after_finish_is_refused() {
  local home out wd tr rc
  home=$(make_home late)
  out="$TMP_ROOT/late-out"; wd="$TMP_ROOT/late-watchdog"; tr="$TMP_ROOT/late-transcripts"
  mkdir -p "$wd" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  soak $((T0 + 1100)) sample --home "$home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 1 "$rc" "sample refuses a finished run"
  assert_equals 1 "$(wc -l < "$out/load.tsv" | tr -d ' ')" "a refused sample appends no row"
  pass "sample after finish is refused"
}


test_finish_counts_a_document_then_a_frozen_restart() {
  local home out wd tr json
  home=$(make_home doc-frozen)
  out="$TMP_ROOT/doc-frozen-out"; wd="$TMP_ROOT/doc-frozen-watchdog"; tr="$TMP_ROOT/doc-frozen-transcripts"
  mkdir -p "$wd/handoffs" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  # A full handoff, then a frozen-session restart that no handoff request led
  # to: the restart is its own handoff, so both count.
  rewrite_handoff "$home" $((T0 + 100)) "handoff"
  {
    printf '%s\tf1\t%s\tprimary\tfrozen\trestart\tpending\ttoken=1\n' $((T0 + 200)) "$home"
    printf '%s\tf1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' $((T0 + 210)) "$home"
  } > "$wd/actions.tsv"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 2 "$(jq -r .handoff_count <<<"$json")" "one document then a completed frozen restart"
  pass "a completed restart whose symptom is not restart-requested always counts"
}

test_out_that_contains_the_home_is_refused() {
  local home parent rc before
  parent="$TMP_ROOT/contain"
  mkdir -p "$parent"
  home=$(make_home contain/home)
  before=$(snapshot "$home")
  soak "$T0" start --home "$home" --out "$parent" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses an --out that contains the soak home"
  [ ! -e "$parent/soak.json" ] || fail "a refused start wrote soak.json above the home"
  ln -s "$parent" "$TMP_ROOT/contain-link"
  soak "$T0" start --home "$home" --out "$TMP_ROOT/contain-link" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses a symlink to a directory that contains the soak home"
  soak "$T0" sample --home "$home" --out "$parent" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "sample refuses an --out that contains the soak home"
  [ ! -e "$parent/load.tsv" ] || fail "a refused sample wrote load.tsv above the home"
  assert_home_unchanged "$home" "$before" "an --out that contains the home"
  pass "an --out that contains the soak home is refused like one inside it"
}

test_root_out_is_refused_as_containing_the_home() {
  local home rc out
  home=$(make_home root-out/home)
  for out in / //; do
    soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null 2>&1; rc=$?
    assert_equals 2 "$rc" "start refuses --out $out, which contains every home"
    soak "$T0" sample --home "$home" --out "$out" > /dev/null 2>&1; rc=$?
    assert_equals 2 "$rc" "sample refuses --out $out, which contains every home"
  done
  pass "a root --out is refused as containing the soak home"
}

# bash keeps a leading // from `pwd -P`, so //<dir> and /<dir> must still be
# treated as one tree by every containment check and by the home check.
test_double_slash_spelling_is_one_tree() {
  local parent home before rc out tr rows
  mkdir -p "$TMP_ROOT/dslash"
  parent="$TMP_ROOT/dslash"
  home=$(make_home dslash/home)
  before=$(snapshot "$home")
  soak "$T0" start --home "$home" --out "/$parent" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses --out //<dir> when <dir> contains the soak home"
  [ ! -e "$parent/soak.json" ] || fail "a refused start wrote soak.json above the home"
  assert_home_unchanged "$home" "$before" "a // spelling of an --out that contains the home"
  out="$TMP_ROOT/dslash-out"; tr="$TMP_ROOT/dslash-transcripts"
  mkdir -p "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  soak $((T0 + 100)) sample --home "/$home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "sample accepts the // spelling of the started soak home"
  mkdir -p "$out/watchdog"
  printf '%s\trestart\t%s\tw1\tdone\n' $((T0 + 10)) "$home" > "$out/watchdog/actions.tsv"
  rows=$(cat "$out/watchdog/actions.tsv")
  soak $((T0 + 1000)) finish --home "$home" --out "/$out" --watchdog-dir "$out/watchdog" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a --watchdog-dir inside a // spelling of --out"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "/$out/watchdog" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a // spelling of a --watchdog-dir inside --out"
  assert_equals "$rows" "$(cat "$out/watchdog/actions.tsv")" "a refused finish left the staged watchdog rows intact"
  pass "a // spelling of a directory is the same tree to every containment check"
}

# On a case-insensitive filesystem a differently cased spelling names the same
# directory, and `pwd -P` keeps the case as typed; containment is decided by
# directory identity, so the alias is still refused.
test_case_alias_spelling_is_one_tree() {
  local base home alias_home out alias_out tr rc rows before
  mkdir -p "$TMP_ROOT/CaseProbe"
  if [ ! -d "$TMP_ROOT/caseprobe" ]; then
    pass "case-alias containment: not applicable on a case-sensitive filesystem"
    return 0
  fi
  base="$TMP_ROOT/casealias"
  home=$(make_home casealias/Home)
  alias_home="$base/HOME"
  before=$(snapshot "$home")
  soak "$T0" start --home "$home" --out "$alias_home/out" --label baseline --harness claude > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "start refuses an --out inside a case alias of the soak home"
  assert_home_unchanged "$home" "$before" "an --out inside a case alias of the home"
  out="$TMP_ROOT/casealias-Out"; alias_out="$TMP_ROOT/casealias-OUT"; tr="$TMP_ROOT/casealias-transcripts"
  mkdir -p "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  mkdir -p "$out/watchdog"
  printf '%s\trestart\t%s\tw1\tdone\n' $((T0 + 10)) "$home" > "$out/watchdog/actions.tsv"
  rows=$(cat "$out/watchdog/actions.tsv")
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$alias_out/watchdog" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a --watchdog-dir that is a case alias of a directory inside --out"
  assert_equals "$rows" "$(cat "$out/watchdog/actions.tsv")" "a refused finish left the staged watchdog rows intact"
  pass "a case alias of a directory is the same tree to every containment check"
}

test_case_alias_order_document_is_one_handoff() {
  local home out wd tr json
  mkdir -p "$TMP_ROOT/CaseProbe2"
  if [ ! -d "$TMP_ROOT/caseprobe2" ]; then
    pass "case-alias order document: not applicable on a case-sensitive filesystem"
    return 0
  fi
  home=$(make_home aliasdoc/Home)
  out="$TMP_ROOT/aliasdoc-out"; wd="$TMP_ROOT/aliasdoc-watchdog"; tr="$TMP_ROOT/aliasdoc-transcripts"
  mkdir -p "$wd" "$tr"
  : > "$wd/actions.tsv"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  rewrite_handoff "$home" $((T0 + 100)) "first"
  printf 'doc=%s\nat=%s\nowner=1\n' "$TMP_ROOT/aliasdoc/HOME/data/handoff-main.md" $((T0 + 100)) > "$home/state/.order-handoff"
  soak $((T0 + 150)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  assert_equals 1 "$(wc -l < "$out/handoff-events.tsv" | tr -d ' ')" "a case-alias order document is not a second event"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 'handoff-main.md' "$(names "$out/handoffs")" "the case-alias order document is kept once, under its own name"
  assert_equals 1 "$(jq -r .handoff_count <<<"$json")" "a case-alias order document counts once"
  pass "an order document that is a case alias of a data handoff document is one handoff"
}

# On a case-insensitive filesystem a case alias of the soak home is that home:
# sample and finish accept it, and watchdog rows whose home column spells the
# home differently are still the home's rows.
test_case_alias_home_is_the_run_home() {
  local home alias_home out wd tr rc json
  mkdir -p "$TMP_ROOT/CaseProbe3"
  if [ ! -d "$TMP_ROOT/caseprobe3" ]; then
    pass "case-alias soak home: not applicable on a case-sensitive filesystem"
    return 0
  fi
  home=$(make_home aliashome/Home)
  alias_home="$TMP_ROOT/aliashome/HOME"
  out="$TMP_ROOT/aliashome-out"; wd="$TMP_ROOT/aliashome-watchdog"; tr="$TMP_ROOT/aliashome-transcripts"
  mkdir -p "$wd" "$tr"
  printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' $((T0 + 500)) "$alias_home" > "$wd/actions.tsv"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  soak $((T0 + 100)) sample --home "$alias_home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "sample accepts a case alias of the run's home"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 1 "$(awk 'END { print NR }' "$out/watchdog/actions.tsv")" "a watchdog row spelling the home as a case alias is kept"
  assert_equals 1 "$(jq -r .handoff_count <<<"$json")" "a frozen restart recorded under a case alias of the home counts"
  pass "a case alias of the soak home is the run's home to sample, finish and the watchdog rows"
}

# One rewrite of a handoff document, sampled under the started spelling and
# then under a case alias of the home, is one handoff event.
test_case_alias_home_samples_count_one_handoff() {
  local home alias_home out wd tr json
  mkdir -p "$TMP_ROOT/CaseProbe4"
  if [ ! -d "$TMP_ROOT/caseprobe4" ]; then
    pass "case-alias home samples: not applicable on a case-sensitive filesystem"
    return 0
  fi
  home=$(make_home aliassample/Home)
  alias_home="$TMP_ROOT/aliassample/HOME"
  out="$TMP_ROOT/aliassample-out"; wd="$TMP_ROOT/aliassample-watchdog"; tr="$TMP_ROOT/aliassample-transcripts"
  mkdir -p "$wd" "$tr"
  : > "$wd/actions.tsv"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  rewrite_handoff "$home" $((T0 + 100)) "first"
  soak $((T0 + 150)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  soak $((T0 + 200)) sample --home "$alias_home" --out "$out" > /dev/null || fail "alias sample failed"
  assert_equals 1 "$(wc -l < "$out/handoff-events.tsv" | tr -d ' ')" "a sample under a case alias of the home adds no second event"
  soak $((T0 + 1000)) finish --home "$alias_home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 1 "$(jq -r .handoff_count <<<"$json")" "one rewrite sampled under two spellings of the home counts once"
  pass "samples under two spellings of the soak home count one handoff"
}

# Two requested restarts with no handoff nudge between them: a document written
# in the same second the first restart finished belongs to the first, so the
# second restart, which left no document of its own, still counts.
test_finish_counts_a_requested_restart_after_a_boundary_document() {
  local home out wd tr json
  home=$(make_home boundary)
  out="$TMP_ROOT/boundary-out"; wd="$TMP_ROOT/boundary-watchdog"; tr="$TMP_ROOT/boundary-transcripts"
  mkdir -p "$wd/handoffs" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  rewrite_handoff "$home" $((T0 + 300)) "first"
  {
    printf '%s\tr1\t%s\tprimary\trestart-requested\trestart\tpending\ttoken=1\n' $((T0 + 290)) "$home"
    printf '%s\tr1\t%s\tprimary\trestart-requested\trestart\tdone\tpickup verified\n' $((T0 + 300)) "$home"
    printf '%s\tr2\t%s\tprimary\trestart-requested\trestart\tpending\ttoken=2\n' $((T0 + 600)) "$home"
    printf '%s\tr2\t%s\tprimary\trestart-requested\trestart\tdone\tpickup verified\n' $((T0 + 610)) "$home"
  } > "$wd/actions.tsv"
  soak $((T0 + 400)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals 2 "$(jq -r .handoff_count <<<"$json")" "the boundary document counts once and the second requested restart counts"
  pass "a document in the second a requested restart finished is not reused by the next requested restart"
}

# The private state copy never lands in the soak home, even when the inherited
# TMPDIR points inside it.
test_tmpdir_inside_the_home_is_never_written() {
  local home out wd tr before
  home=$(make_home tmpdir-home)
  out="$TMP_ROOT/tmpdir-out"; wd="$TMP_ROOT/tmpdir-watchdog"; tr="$TMP_ROOT/tmpdir-transcripts"
  mkdir -p "$home/tmp" "$wd" "$tr"
  before=$(snapshot "$home")
  TMPDIR="$home/tmp" soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  assert_home_unchanged "$home" "$before" "start with TMPDIR inside the home"
  TMPDIR="$home/tmp" soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  assert_home_unchanged "$home" "$before" "sample with TMPDIR inside the home"
  TMPDIR="$home/state" soak $((T0 + 200)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  assert_home_unchanged "$home" "$before" "sample with TMPDIR at the home state directory"
  TMPDIR="$home/tmp" soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" > /dev/null || fail "finish failed"
  assert_home_unchanged "$home" "$before" "finish with TMPDIR inside the home"
  assert_equals 2 "$(awk 'END { print NR }' "$out/load.tsv")" "both samples still recorded their load rows"
  pass "a TMPDIR inside the soak home never receives the private state copy"
}

test_order_document_at_a_path_suffix_is_kept() {
  local inner json
  mkdir -p "$TMP_ROOT/sfx-inner/data"
  inner=$(cd -P "$TMP_ROOT/sfx-inner" && pwd -P)
  # The home's data/handoff-a.md ends with the order document's whole path, but
  # the two are distinct files: the order document must still be kept.
  finish_fixture "sfx-outer$inner" baseline
  printf 'order\n' > "$inner/data/handoff-a.md"; fm_touch_epoch $((T0 + 800)) "$inner/data/handoff-a.md"
  printf 'doc=%s\nat=%s\nowner=1\n' "$inner/data/handoff-a.md" $((T0 + 800)) > "$HOME_DIR/state/.order-handoff"
  soak $((T0 + 1000)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null || fail "finish failed"
  json=$(jq -c . "$OUT_DIR/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals $'handoff-a.md\nhandoff-b.md\norder-handoff-a.md' "$(names "$OUT_DIR/handoffs")" \
    "a distinct order document whose path is a suffix of a data handoff path is kept"
  assert_equals 'order' "$(cat "$OUT_DIR/handoffs/order-handoff-a.md")" "the kept order document is the order record's file"
  assert_equals 4 "$(jq -r .handoff_count <<<"$json")" "the distinct order document counts as its own handoff"
  pass "an order document whose path is a suffix of a data handoff path is kept and counted"
}

test_sample_and_finish_refuse_another_home() {
  local home other out wd tr rc
  home=$(make_home own)
  other=$(make_home stranger)
  out="$TMP_ROOT/own-out"; wd="$TMP_ROOT/own-watchdog"; tr="$TMP_ROOT/own-transcripts"
  mkdir -p "$wd" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  soak $((T0 + 100)) sample --home "$other" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "sample refuses a --home that is not the run's home"
  [ ! -e "$out/load.tsv" ] || fail "a refused sample appended a load row"
  [ ! -e "$out/handoff-events.tsv" ] || fail "a refused sample recorded handoff events"
  soak $((T0 + 1000)) finish --home "$other" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a --home that is not the run's home"
  assert_equals '' "$(jq -r '.finished_at // empty' "$out/soak.json")" "a refused finish did not finish the run"
  [ ! -e "$out/watchdog" ] || fail "a refused finish kept watchdog rows"
  soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null || fail "sample of the run's own home failed"
  pass "sample and finish refuse a --home other than the one the run started on"
}

test_unsafe_session_ids_never_become_paths() {
  local home out wd tr json rc
  home=$(make_home unsafe)
  out="$TMP_ROOT/unsafe-out"; wd="$TMP_ROOT/unsafe-watchdog"; tr="$TMP_ROOT/unsafe-transcripts"
  mkdir -p "$wd" "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  printf '../../escape\n' > "$home/state/.lock-session"
  soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  assert_equals '-' "$(cut -f5 "$out/load.tsv")" "an unsafe recorded session id samples as -"
  # A load row written before this check carries an id that walks out of
  # transcripts/; a transcript sits where that walk lands.
  printf '%s\t0\t0\t0\t../escape\n' $((T0 + 200)) >> "$out/load.tsv"
  printf '{"t":9}\n' > "$TMP_ROOT/escape.jsonl"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "finish skips an unsafe session id rather than failing"
  json=$(jq -c . "$out/soak.json") || fail "soak.json is not JSON after finish"
  assert_equals '[]' "$(jq -c .session_ids <<<"$json")" "an unsafe session id is not recorded"
  [ ! -e "$out/escape.jsonl" ] || fail "an unsafe session id copied a transcript outside transcripts/"
  pass "a session id that is not a plain name never becomes a path component"
}

# A Muse task with a live window and no running validation, whose session
# cache is stale: classifying it deletes and rewrites the cache, so the
# recorder must classify against a scratch copy of the home state, never
# against the home.
test_stale_muse_cache_leaves_the_home_unchanged() {
  local home out wd tr before root
  home=$(make_home musecache)
  out="$TMP_ROOT/musecache-out"; wd="$TMP_ROOT/musecache-watchdog"; tr="$TMP_ROOT/musecache-transcripts"
  root="$TMP_ROOT/musecache-sessions"
  mkdir -p "$wd" "$tr" "$root"
  task_copy musecache-m fm/feat-m
  fm_write_meta "$home/state/feat-m.meta" "window=fm:fm-feat-m" "worktree=$TASK_DIR" "kind=ship" "backend=tmux" "harness=muse"
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=current\n' "$root" "$TASK_DIR" > "$home/state/feat-m.muse-session"
  printf 'binding_id=retired\nsession_log=%s/old/session.jsonl\n' "$root" > "$home/state/feat-m.muse-session-current"
  FM_FAKE_TMUX_WINDOWS=fm-feat-m soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  before=$(snapshot "$home")
  FM_FAKE_TMUX_WINDOWS=fm-feat-m soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  assert_home_unchanged "$home" "$before" "sample with a stale Muse session cache"
  FM_FAKE_TMUX_WINDOWS=fm-feat-m soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" > /dev/null || fail "finish failed"
  assert_home_unchanged "$home" "$before" "finish with a stale Muse session cache"
  pass "a stale Muse session cache in the home is never deleted or rewritten"
}

# A --watchdog-dir that is --out or lies inside it would make finish read the
# watchdog rows it is about to write; it is refused before any write.
test_watchdog_dir_inside_out_is_refused() {
  local home out tr rc rows
  home=$(make_home wdalias)
  out="$TMP_ROOT/wdalias-out"; tr="$TMP_ROOT/wdalias-transcripts"
  mkdir -p "$tr"
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  mkdir -p "$out/watchdog"
  printf '%s\trestart\t%s\tw1\tdone\n' $((T0 + 10)) "$home" > "$out/watchdog/actions.tsv"
  rows=$(cat "$out/watchdog/actions.tsv")
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$out/watchdog" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a --watchdog-dir inside --out"
  assert_equals "$rows" "$(cat "$out/watchdog/actions.tsv")" "a refused finish left the staged watchdog rows intact"
  assert_equals '' "$(jq -r '.finished_at // empty' "$out/soak.json")" "a refused finish did not finish the run"
  soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$out" --transcript-dir "$tr" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a --watchdog-dir equal to --out"
  pass "a --watchdog-dir that is --out or inside it is refused before any write"
}

# cp_shim <dir> <mode>: a cp first on PATH that, only for the copy of a home's
# state directory, either removes the state entry .vanishing.tmp and then
# copies and exits 1 (mode vanish), copies and then renames .vanishing.tmp to
# the new name .renamed-in and exits 1 (mode rename), or copies nothing and
# exits 1 (mode fail).
cp_shim() {
  mkdir -p "$1"
  cat > "$1/cp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */state/.)
      case "$2" in
        vanish) rm -f "\${a%/.}/.vanishing.tmp"; /bin/cp "\$@"; exit 1 ;;
        rename) /bin/cp "\$@"; mv "\${a%/.}/.vanishing.tmp" "\${a%/.}/.renamed-in"; exit 1 ;;
        fail) exit 1 ;;
      esac ;;
  esac
done
exec /bin/cp "\$@"
SH
  chmod +x "$1/cp"
}

# A live home creates and removes short-lived state files; one that vanishes
# while the private copy runs is not a copy failure, but an entry that still
# exists and is missing from the copy is.
test_sample_tolerates_a_state_entry_that_vanishes_during_the_copy() {
  local home out rc shim="$TMP_ROOT/cpshim-vanish"
  home=$(make_home vanish)
  out="$TMP_ROOT/vanish-out"
  cp_shim "$shim" vanish
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  printf 'tmp\n' > "$home/state/.vanishing.tmp"
  PATH="$shim:$PATH" soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "sample exits 0 when a state entry vanishes during the copy"
  assert_equals 1 "$(wc -l < "$out/load.tsv" | tr -d ' ')" "sample appended its load row"
  pass "a state entry that vanishes during the private copy does not stop sample"
}

test_sample_tolerates_a_state_entry_renamed_in_during_the_copy() {
  local home out rc shim="$TMP_ROOT/cpshim-rename"
  home=$(make_home renamein)
  out="$TMP_ROOT/renamein-out"
  cp_shim "$shim" rename
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  printf 'tmp\n' > "$home/state/.vanishing.tmp"
  PATH="$shim:$PATH" soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "sample exits 0 when a state entry is renamed to a new name during the copy"
  assert_equals 1 "$(wc -l < "$out/load.tsv" | tr -d ' ')" "sample appended its load row"
  pass "a state entry renamed into place during the private copy does not stop sample"
}

test_sample_refuses_a_failed_copy_of_existing_state() {
  local home out rc shim="$TMP_ROOT/cpshim-fail"
  home=$(make_home cpfail)
  out="$TMP_ROOT/cpfail-out"
  cp_shim "$shim" fail
  soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  PATH="$shim:$PATH" soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null 2>&1; rc=$?
  assert_equals 1 "$rc" "sample exits 1 when the copy misses a state entry that still exists"
  [ ! -e "$out/load.tsv" ] || fail "a failed copy still appended a load row"
  pass "a copy that misses existing home state stops sample"
}

test_hard_linked_output_is_refused() {
  local before rc wd_before
  finish_fixture hard baseline
  # A load.tsv hard-linked to a home file is refused, not appended through.
  mv "$OUT_DIR/load.tsv" "$TMP_ROOT/hard-load.tsv"
  ln "$HOME_DIR/state/feat-c.status" "$OUT_DIR/load.tsv"
  before=$(snapshot "$HOME_DIR")
  soak $((T0 + 300)) sample --home "$HOME_DIR" --out "$OUT_DIR" > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "sample refuses a load.tsv that is a hard link"
  assert_home_unchanged "$HOME_DIR" "$before" "sample through a hard-linked load.tsv"
  rm "$OUT_DIR/load.tsv"; mv "$TMP_ROOT/hard-load.tsv" "$OUT_DIR/load.tsv"
  # A watchdog copy hard-linked to the watchdog's own ledger is refused before
  # it is truncated.
  mkdir -p "$OUT_DIR/watchdog"
  ln "$WD_DIR/actions.tsv" "$OUT_DIR/watchdog/actions.tsv"
  wd_before=$(cat "$WD_DIR/actions.tsv")
  soak $((T0 + 1000)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a watchdog copy that is a hard link"
  assert_equals "$wd_before" "$(cat "$WD_DIR/actions.tsv")" "the watchdog ledger is unchanged"
  rm "$OUT_DIR/watchdog/actions.tsv"
  # A kept handoff copy hard-linked to another home file is refused.
  mkdir -p "$OUT_DIR/handoffs"
  ln "$HOME_DIR/state/feat-c.status" "$OUT_DIR/handoffs/handoff-b.md"
  before=$(snapshot "$HOME_DIR")
  soak $((T0 + 1000)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a handoff copy that is a hard link"
  assert_home_unchanged "$HOME_DIR" "$before" "finish through a hard-linked handoff copy"
  pass "a hard link where the recorder writes is refused and nothing behind it changes"
}

test_directory_at_a_copy_destination_is_refused() {
  local before rc
  finish_fixture dirdest baseline
  # A directory where a kept copy goes would make cp write inside it, past the
  # link checks, here through a symlink into the home.
  mkdir -p "$OUT_DIR/handoffs/handoff-a.md"
  ln -s "$HOME_DIR/state/feat-c.status" "$OUT_DIR/handoffs/handoff-a.md/handoff-a.md"
  before=$(snapshot "$HOME_DIR")
  soak $((T0 + 1000)) finish --home "$HOME_DIR" --out "$OUT_DIR" --watchdog-dir "$WD_DIR" --transcript-dir "$TR_DIR" \
    > /dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "finish refuses a directory where a handoff copy goes"
  assert_home_unchanged "$HOME_DIR" "$before" "finish with a directory at a copy destination"
  pass "a directory where a copy goes is refused and nothing behind it changes"
}

# Firstmate lock links name their owner directory by absolute path inside the
# home state. Lock recovery run on the private copy during classification, as
# stale-lock recovery does, must reach only the copy, never the home.
test_lock_recovery_on_the_state_copy_leaves_the_home_unchanged() {
  local home out wd tr before hook ran
  home=$(make_home lockcopy)
  out="$TMP_ROOT/lockcopy-out"; wd="$TMP_ROOT/lockcopy-watchdog"; tr="$TMP_ROOT/lockcopy-transcripts"
  mkdir -p "$wd" "$tr" "$home/state/.control-feat-a.lock.owner.AbC123"
  printf '99999\n' > "$home/state/.control-feat-a.lock.owner.AbC123/pid"
  ln -s "$home/state/.control-feat-a.lock.owner.AbC123" "$home/state/.control-feat-a.lock"
  # Any other link into the home is cut off from it too.
  ln -s "$home/config" "$home/state/config-link"
  hook="$TMP_ROOT/lockcopy-hook.sh"; ran="$TMP_ROOT/lockcopy-ran"
  cat > "$hook" <<SH
[ -n "\${FM_STATE_OVERRIDE:-}" ] || exit 0
[ -L "\$FM_STATE_OVERRIDE/.control-feat-a.lock" ] || exit 0
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_remove_path "\$FM_STATE_OVERRIDE/.control-feat-a.lock"
: 2> /dev/null > "\$FM_STATE_OVERRIDE/config-link/written"
: > "$ran"
SH
  FM_FAKE_TMUX_WINDOWS=fm-feat-a soak "$T0" start --home "$home" --out "$out" --label baseline --harness claude > /dev/null || fail "start failed"
  before=$(snapshot "$home")
  FM_FAKE_TMUX_HOOK=$hook FM_FAKE_TMUX_WINDOWS=fm-feat-a soak $((T0 + 100)) sample --home "$home" --out "$out" > /dev/null || fail "sample failed"
  [ -e "$ran" ] || fail "lock recovery did not run on the copy during sample"
  assert_home_unchanged "$home" "$before" "sample with lock recovery on the state copy"
  rm -f "$ran"
  FM_FAKE_TMUX_HOOK=$hook FM_FAKE_TMUX_WINDOWS=fm-feat-a soak $((T0 + 1000)) finish --home "$home" --out "$out" --watchdog-dir "$wd" --transcript-dir "$tr" > /dev/null || fail "finish failed"
  [ -e "$ran" ] || fail "lock recovery did not run on the copy during finish"
  assert_home_unchanged "$home" "$before" "finish with lock recovery on the state copy"
  pass "lock recovery on the private state copy never reaches the home"
}

make_fakebin
fm_test_run \
  test_lock_recovery_on_the_state_copy_leaves_the_home_unchanged \
  test_directory_at_a_copy_destination_is_refused \
  test_hard_linked_output_is_refused \
  test_sample_tolerates_a_state_entry_that_vanishes_during_the_copy \
  test_sample_tolerates_a_state_entry_renamed_in_during_the_copy \
  test_sample_refuses_a_failed_copy_of_existing_state \
  test_stale_muse_cache_leaves_the_home_unchanged \
  test_watchdog_dir_inside_out_is_refused \
  test_finish_counts_a_document_then_a_frozen_restart \
  test_out_that_contains_the_home_is_refused \
  test_root_out_is_refused_as_containing_the_home \
  test_order_document_at_a_path_suffix_is_kept \
  test_double_slash_spelling_is_one_tree \
  test_case_alias_spelling_is_one_tree \
  test_case_alias_order_document_is_one_handoff \
  test_case_alias_home_is_the_run_home \
  test_case_alias_home_samples_count_one_handoff \
  test_finish_counts_a_requested_restart_after_a_boundary_document \
  test_tmpdir_inside_the_home_is_never_written \
  test_sample_and_finish_refuse_another_home \
  test_unsafe_session_ids_never_become_paths \
  test_finish_counts_a_lean_handoff_restart \
  test_finish_counts_each_rewrite_of_one_handoff_document \
  test_finish_counts_a_late_full_handoff_once \
  test_sample_records_each_handoff_document_event \
  test_sample_after_finish_is_refused \
  test_readable_harnesses_and_inventory \
  test_start_records_the_run_and_refuses_unreadable \
  test_sample_appends_one_load_row \
  test_finish_keeps_the_window_and_counts_handoffs \
  test_finish_post_change_names_missing_activity_sources
