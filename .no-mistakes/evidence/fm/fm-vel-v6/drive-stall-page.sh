#!/usr/bin/env bash
# Drive bin/fm-watchdog.sh once against disposable homes. Records product output.
# Clock seam is used only to step past stall-page-secs; the first page of each
# trigger uses the wall clock and records that are already older than stall-secs.
set -u
ROOT={run-worktree}
EVID=~/.no-mistakes/evidence/01M7R2ZFJFRPP8E2BZJBJRS14F
WD="$ROOT/bin/fm-watchdog.sh"
REAL_TMUX=$(command -v tmux) || { echo "tmux is not on PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is not on PATH"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stall-live.XXXXXX")
SOCKET="fm-stall-live-$$"
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN" "$EVID"
CALLS="$WORK/external-calls.log"
: > "$CALLS"
cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
EOF
chmod +x "$FAKEBIN/tmux"
for tool in gh gh-axi osascript terminal-notifier say mail sendmail curl; do
  cat > "$FAKEBIN/$tool" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$CALLS"
exit 1
EOF
  chmod +x "$FAKEBIN/$tool"
done
export PATH="$FAKEBIN:$PATH"

LOCK_PIDS=""
CASE_N=0
FAILS=0
H="" LOCKPID="" T="" SID=""
TRANSCRIPT="$EVID/stall-live-transcript.txt"
: > "$TRANSCRIPT"

say() { printf '%s\n' "$*" | tee -a "$TRANSCRIPT"; }

cleanup() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  FAILS=$((FAILS + 1))
  say "FAIL: $*"
}

ok() { say "OK: $*"; }

now() { date +%s; }

age_file() { # <epoch> <path>
  python3 -c 'import os,sys; t=int(sys.argv[1]); os.utime(sys.argv[2], (t, t))' "$1" "$2"
}

ledger() { cat "$H/state/watchdog/actions.tsv" 2>/dev/null || true; }

page_count() { # <symptom> <phase>
  ledger | awk -F '\t' -v s="$1" -v p="$2" '$5 == s && $6 == "page" && $7 == p { c++ } END { print c + 0 }'
}

stall_count() {
  ledger | awk -F '\t' '$5 ~ /^stall-/ { c++ } END { print c + 0 }'
}

restart_count() {
  ledger | awk -F '\t' '$6 == "restart" { c++ } END { print c + 0 }'
}

check_no_restart() { # <label> [allow-dead]
  local label=$1 allow_dead=${2:-}
  local n
  n=$(restart_count)
  [ "$n" = 0 ] || fail "$label: restart rows=$n"
  cmp -s "$H/state/.lock" "$H/lock.before" || fail "$label: session lock file changed"
  cmp -s "$H/state/.lock-session" "$H/lock-session.before" || fail "$label: lock session record changed"
  if [ -z "$allow_dead" ]; then
    kill -0 "$LOCKPID" 2>/dev/null || fail "$label: live lock holder is gone"
  fi
  if grep -E 'merge|deploy|osascript|terminal-notifier|^mail |^sendmail ' "$CALLS" >/dev/null 2>&1; then
    fail "$label: an outward merge, deploy, or owner-notifier call was logged"
  fi
}

save_case() { # <name>
  local dest="$EVID/$1"
  mkdir -p "$dest"
  cp "$H/paged.log" "$dest/paged.log" 2>/dev/null || : > "$dest/paged.log"
  ledger > "$dest/actions.tsv"
  awk -F '\t' '$5 ~ /^stall-/ || $6 == "restart"' "$dest/actions.tsv" > "$dest/stall-and-restart.tsv" || true
  if [ -f "$H/data/watchdog/status.md" ]; then
    cp "$H/data/watchdog/status.md" "$dest/status.md"
  else
    : > "$dest/status.md"
  fi
  cp "$CALLS" "$dest/external-calls.log" 2>/dev/null || true
  {
    echo "lock_holder_alive=$(kill -0 "$LOCKPID" 2>/dev/null && echo yes || echo no)"
    echo "lock_unchanged=$(cmp -s "$H/state/.lock" "$H/lock.before" && echo yes || echo no)"
    echo "restart_rows=$(restart_count)"
    echo "stall_rows=$(stall_count)"
    echo "stall-input pending=$(page_count stall-input pending) done=$(page_count stall-input done) dry-run=$(page_count stall-input dry-run) refused=$(page_count stall-input refused)"
    echo "stall-pr pending=$(page_count stall-pr pending) done=$(page_count stall-pr done) dry-run=$(page_count stall-pr dry-run) refused=$(page_count stall-pr refused)"
  } > "$dest/summary.txt"
  say "---- $1 ----"
  cat "$dest/summary.txt" | tee -a "$TRANSCRIPT"
  say "-- page --"
  cat "$dest/paged.log" | tee -a "$TRANSCRIPT"
  say "-- stall ledger --"
  cat "$dest/stall-and-restart.tsv" | tee -a "$TRANSCRIPT"
  say "-- status stall lines --"
  grep -n -i -E 'stall|unhandled|ready PR' "$dest/status.md" | tee -a "$TRANSCRIPT" || true
}

make_home() { # [extra-config]
  local extra=${1:-} n
  CASE_N=$((CASE_N + 1))
  H="$WORK/home$CASE_N"
  SID="00000000-0000-4000-8000-$(printf '%012d' "$CASE_N")"
  mkdir -p "$H/state/inbox" "$H/config" "$H/data" "$H/claude/projects/p"
  printf 'Captain session\n> \n' > "$H/screen.txt"
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
: > "$H/agent.ready"
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  : > "$H/typed.log"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "wd$CASE_N" -x 160 -y 40 "$H/agent.sh"
  T=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "wd$CASE_N" -F '#{pane_id}' | head -n 1)
  [ -n "$T" ] || { fail "make_home: no pane id"; return 1; }
  ( sleep 100000 >/dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$SID" > "$H/state/.lock-session"
  n=$(now)
  age_file "$((n - 2))" "$H/state/.lock"
  age_file "$((n - 2))" "$H/state/.lock-session"
  jq -n --arg t "$T" --arg s "$SID" --argjson e "$n" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=0\n%s\n' \
    "$H/claude" "$extra" > "$H/config/watchdog"
  printf "command:cat >> '%s'\n" "$H/paged.log" > "$H/config/wedge-alarm"
  local drawn=0
  while [ ! -e "$H/agent.ready" ]; do
    drawn=$((drawn + 1))
    [ "$drawn" -le 100 ] || { fail "make_home: captain pane never started"; return 1; }
    sleep 0.1
  done
  local f="$H/claude/projects/p/$SID.jsonl" iso
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg ts "$iso" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:"Working."}]}}' > "$f"
  cp "$H/state/.lock" "$H/lock.before"
  cp "$H/state/.lock-session" "$H/lock-session.before"
  say "home $H pane $T lock $LOCKPID"
}

stall_task() { # <id> <yolo> <status-line> [kind]
  local kind=${4:-ship}
  printf 'kind=%s\nbackend=tmux\nwindow=%%9%s\nterminal=term_%s\nyolo=%s\nendpoint_task_id=%s\n' \
    "$kind" "$CASE_N" "$1" "$2" "$1" > "$H/state/$1.meta"
  printf '%s\n' "$3" > "$H/state/$1.status"
}

owe_wake() { # <age-secs>
  printf '%s\t1\tcheck\tinbox\tcaptain note waiting\n' "$(( $(now) - $1 ))" > "$H/state/.wake-queue"
}

run_wd() { # [epoch-override]
  local start end rc pinned=${1:-}
  start=$(now)
  say "watchdog once start=$start pinned=${pinned:-wall}"
  if [ -n "$pinned" ]; then
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      -u TMUX -u TMUX_PANE \
      FM_TEST_SEAM=1 FM_WD_NOW="$pinned" FM_HOME="$H" bash "$WD" once > "$H/wd.out" 2>&1
  else
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      -u TMUX -u TMUX_PANE \
      -u FM_TEST_SEAM -u FM_WD_NOW -u FM_WD_TEST_COMPOSER \
      FM_HOME="$H" bash "$WD" once > "$H/wd.out" 2>&1
  fi
  rc=$?
  end=$(now)
  say "watchdog once exit=$rc elapsed=$((end - start))s"
  if [ "$rc" -ne 0 ]; then
    fail "watchdog once exited $rc"
    tail -n 40 "$H/wd.out" | tee -a "$TRANSCRIPT" || true
  fi
  return 0
}

expect_eq() { # <got> <want> <label>
  [ "$1" = "$2" ] || fail "$3: got '$1' want '$2'"
  [ "$1" = "$2" ] && ok "$3 = $1"
}

expect_grep() { # <file> <needle> <label>
  grep -F -q -- "$2" "$1" 2>/dev/null || fail "$3: missing [$2]"
  grep -F -q -- "$2" "$1" 2>/dev/null && ok "$3"
}

expect_no_grep() { # <file> <needle> <label>
  if [ -f "$1" ] && grep -F -q -- "$2" "$1" 2>/dev/null; then
    fail "$3: unexpectedly found [$2]"
  else
    ok "$3"
  fi
}

# --- scenario: unhandled input with work in flight ---
say "===== S1 unhandled input pages once, rate-limits, restarts nothing ====="
make_home 'stall-page-secs=900'
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 1000
run_wd
expect_eq "$(page_count stall-input done)" 1 "S1 first page delivered"
expect_eq "$(page_count stall-pr pending)" 0 "S1 no PR page"
expect_grep "$H/paged.log" "unhandled inputs" "S1 page names unhandled input"
expect_grep "$H/paged.log" "in flight" "S1 page names work in flight"
expect_no_grep "$H/paged.log" "captain note waiting" "S1 page omits the input text"
check_no_restart "S1 first"
run_wd
expect_eq "$(page_count stall-input pending)" 1 "S1 second pass stays inside the page window"
check_no_restart "S1 second"
# Step the watchdog clock past stall-page-secs. Records stay as they are.
run_wd "$(( $(now) + 1000 ))"
expect_eq "$(page_count stall-input pending)" 2 "S1 a stall still standing after the window pages again"
check_no_restart "S1 third"
save_case s1-unhandled-input

say "===== S1b input younger than 15 minutes stays quiet ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 600
run_wd
expect_eq "$(stall_count)" 0 "S1b under stall-secs"
expect_no_grep "$H/paged.log" "unhandled" "S1b no page file text"
[ ! -s "$H/paged.log" ] || fail "S1b wrote a page: $(cat "$H/paged.log")"
check_no_restart "S1b"
save_case s1b-input-too-young

say "===== S1c old input with nothing in flight stays quiet ====="
make_home
owe_wake 2000
run_wd
expect_eq "$(stall_count)" 0 "S1c no work in flight"
[ ! -s "$H/paged.log" ] || fail "S1c wrote a page: $(cat "$H/paged.log")"
check_no_restart "S1c"
save_case s1c-no-work-in-flight

say "===== S1d an old captain inbox note with work in flight pages ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
printf 'secret-captain-note-body\n' > "$H/state/inbox/captain.note"
age_file "$((n - 1000))" "$H/state/inbox/captain.note"
run_wd
expect_eq "$(page_count stall-input done)" 1 "S1d inbox note pages"
expect_no_grep "$H/paged.log" "secret-captain-note-body" "S1d page omits the note body"
check_no_restart "S1d"
save_case s1d-inbox-note

say "===== S2 declared waits stay quiet ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
stall_task fm-w off "paused [at=$((n - 2000))]: waiting on the machine-wide test queue"
printf '%s\t1\tsignal\tfm-w.status\tsignal: fm-w\n' "$((n - 2000))" > "$H/state/.wake-queue"
printf '%s\t2\tstale\tterm_fm-w\tstale: term_fm-w\n' "$((n - 1900))" >> "$H/state/.wake-queue"
run_wd
expect_eq "$(stall_count)" 0 "S2 wakes about a declared wait"
[ ! -s "$H/paged.log" ] || fail "S2 declared wait paged: $(cat "$H/paged.log")"
check_no_restart "S2 waits"
save_case s2a-declared-wait-rows

say "===== S2b a home whose only task is a declared wait ====="
make_home
n=$(now)
stall_task fm-w off "paused [at=$((n - 2000))]: waiting on the machine-wide test queue"
owe_wake 2000
run_wd
expect_eq "$(stall_count)" 0 "S2b only a declared wait"
check_no_restart "S2b"
save_case s2b-only-declared-wait

say "===== S2c a working-task row still pages beside a declared wait ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
stall_task fm-w off "paused [at=$((n - 2000))]: waiting on the machine-wide test queue"
printf '%s\t1\tsignal\tfm-w.status\tsignal\n' "$((n - 2000))" > "$H/state/.wake-queue"
printf '%s\t2\tsignal\tfm-a.status\tsignal\n' "$((n - 1000))" >> "$H/state/.wake-queue"
run_wd
expect_eq "$(page_count stall-input done)" 1 "S2c working row pages"
expect_grep "$H/paged.log" "1 unhandled inputs" "S2c only the working row counts"
check_no_restart "S2c"
save_case s2c-working-beside-wait

say "===== S2d a resolved wait is no longer quiet ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
stall_task fm-w off "paused [at=$((n - 3000))]: waiting on CI"
printf 'resolved [at=%s]: CI finished\n' "$((n - 2500))" >> "$H/state/fm-w.status"
printf '%s\t1\tsignal\tfm-w.status\tsignal\n' "$((n - 2000))" > "$H/state/.wake-queue"
run_wd
expect_eq "$(page_count stall-input done)" 1 "S2d resolved wait pages"
check_no_restart "S2d"
save_case s2d-resolved-wait

say "===== S2e t3code wait and a leading-zero timestamp stay quiet ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
printf 'kind=ship\nbackend=t3code\nt3_thread_id=thr-wait-1\nyolo=off\nendpoint_task_id=fm-t3\n' > "$H/state/fm-t3.meta"
printf 'paused [at=%s]: waiting on CI\n' "$((n - 2000))" > "$H/state/fm-t3.status"
printf '08\t1\tsignal\tbad-octal\tsignal\n' > "$H/state/.wake-queue"
printf '%s\t2\tstale\tthr-wait-1\tstale: thr-wait-1\n' "$((n - 1900))" >> "$H/state/.wake-queue"
run_wd
expect_eq "$(stall_count)" 0 "S2e t3code wait and leading zero"
check_no_restart "S2e"
save_case s2e-t3code-and-leading-zero

say "===== S3 finished tasks are not in flight ====="
make_home
n=$(now)
stall_task fm-d off "done [at=$((n - 2000))]: PR https://github.com/o/r/pull/7 checks green"
owe_wake 1000
run_wd
expect_eq "$(stall_count)" 0 "S3 done-only is not in flight"
expect_no_grep "$H/data/watchdog/status.md" "inputs unhandled" "S3 no stall gap"
[ ! -s "$H/paged.log" ] || fail "S3 done-only paged: $(cat "$H/paged.log")"
check_no_restart "S3 done"
save_case s3a-done-only

say "===== S3b a failed task is not in flight ====="
make_home
n=$(now)
stall_task fm-f off "failed [at=$((n - 2000))]: the build broke"
owe_wake 1000
run_wd
expect_eq "$(stall_count)" 0 "S3b failed-only is not in flight"
[ ! -s "$H/paged.log" ] || fail "S3b failed-only paged: $(cat "$H/paged.log")"
check_no_restart "S3b"
save_case s3b-failed-only

say "===== S3c a working task beside a finished one still pages once ====="
make_home
n=$(now)
stall_task fm-d off "done [at=$((n - 2000))]: PR https://github.com/o/r/pull/7 checks green"
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 1000
run_wd
expect_eq "$(page_count stall-input done)" 1 "S3c mixed home pages once"
expect_grep "$H/paged.log" "while 1 tasks are in flight" "S3c only the working task counts"
check_no_restart "S3c"
save_case s3c-working-beside-done

say "===== S4 a ready PR under standing authority pages until it lands ====="
URL=https://github.com/o/r/pull/7
make_home 'stall-page-secs=900'
n=$(now)
stall_task fm-p on "done [at=$((n - 1000))]: PR $URL checks green"
run_wd
expect_eq "$(page_count stall-pr done)" 1 "S4 ready PR pages"
expect_grep "$H/paged.log" "$URL" "S4 page names the PR"
expect_grep "$H/paged.log" "ready PRs" "S4 page names ready PRs"
expect_grep "$H/data/watchdog/status.md" "ready PRs unlanded" "S4 gap records the PR"
check_no_restart "S4 first"
run_wd
expect_eq "$(page_count stall-pr pending)" 1 "S4 second pass stays inside the page window"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n7\n' > "$H/state/fm-p.pr-poll-merge-notified"
chmod 600 "$H/state/fm-p.pr-poll-merge-notified"
run_wd "$(( $(now) + 1000 ))"
expect_eq "$(page_count stall-pr pending)" 1 "S4 a matching merge record stops another page"
expect_no_grep "$H/data/watchdog/status.md" "ready PRs unlanded" "S4 landed PR leaves the gaps"
check_no_restart "S4 landed"
save_case s4-ready-pr

say "===== S4b a marker for a different PR does not count as landed ====="
make_home
n=$(now)
stall_task fm-p on "done [at=$((n - 1000))]: PR $URL checks green"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\no/r\n6\n' > "$H/state/fm-p.pr-poll-merge-notified"
chmod 600 "$H/state/fm-p.pr-poll-merge-notified"
run_wd
expect_eq "$(page_count stall-pr done)" 1 "S4b other PR number still pages"
check_no_restart "S4b"
save_case s4b-other-number

say "===== S4c Forgejo /pulls/ URL and a marker for another host ====="
FURL=https://git.example.com/o/r/pulls/9
make_home 'stall-page-secs=900'
n=$(now)
stall_task fm-p on "done [at=$((n - 1000))]: PR $FURL checks green"
printf 'fm-pr-poll-merge-notified-v1\nforgejo\nother.example.com\no/r\n9\n' > "$H/state/fm-p.pr-poll-merge-notified"
chmod 600 "$H/state/fm-p.pr-poll-merge-notified"
run_wd
expect_eq "$(page_count stall-pr done)" 1 "S4c Forgejo PR pages despite another host"
expect_grep "$H/paged.log" "$FURL" "S4c page names the Forgejo URL"
check_no_restart "S4c"
printf 'fm-pr-poll-merge-notified-v1\nforgejo\ngit.example.com\no/r\n9\n' > "$H/state/fm-p.pr-poll-merge-notified"
chmod 600 "$H/state/fm-p.pr-poll-merge-notified"
run_wd "$(( $(now) + 1000 ))"
expect_eq "$(page_count stall-pr pending)" 1 "S4c matching Forgejo marker stops another page"
check_no_restart "S4c landed"
save_case s4c-forgejo

say "===== S4d a wrong marker version does not count as landed ====="
make_home
n=$(now)
stall_task fm-p on "done [at=$((n - 1000))]: PR $FURL checks green"
printf 'fm-pr-poll-merge-notified-v0\nforgejo\ngit.example.com\no/r\n9\n' > "$H/state/fm-p.pr-poll-merge-notified"
chmod 600 "$H/state/fm-p.pr-poll-merge-notified"
run_wd
expect_eq "$(page_count stall-pr done)" 1 "S4d wrong version still pages"
check_no_restart "S4d"
save_case s4d-wrong-version

say "===== S4e quiet PR cases ====="
make_home
n=$(now)
printf 'kind=scout\nbackend=tmux\nwindow=%%9%s\nterminal=term_fm-s\nyolo=on\nendpoint_task_id=fm-s\n' "$CASE_N" > "$H/state/fm-s.meta"
printf 'done [at=%s]: reviewed %s\n' "$((n - 1000))" "$URL" > "$H/state/fm-s.status"
run_wd
expect_eq "$(stall_count)" 0 "S4e scout naming a PR does not page"
check_no_restart "S4e scout"
save_case s4e-scout

make_home
n=$(now)
stall_task fm-p off "done [at=$((n - 1000))]: PR $URL checks green"
run_wd
expect_eq "$(stall_count)" 0 "S4e yolo off stays quiet"
check_no_restart "S4e yolo-off"
save_case s4e-yolo-off

make_home
n=$(now)
stall_task fm-p on "done [at=$((n - 600))]: PR $URL checks green"
run_wd
expect_eq "$(page_count stall-pr pending)" 0 "S4e PR younger than stall-secs"
check_no_restart "S4e young"
save_case s4e-young-pr

make_home
n=$(now)
stall_task fm-p on "paused [at=$((n - 1000))]: PR $URL held as a draft"
run_wd
expect_eq "$(stall_count)" 0 "S4e a PR in a declared wait stays quiet"
check_no_restart "S4e paused"
save_case s4e-paused-pr

say "===== S5 a live holder and a fresh heartbeat do not hide the stall ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 1000
# Heartbeat was just written and the lock pid is this shell's sleep. Prove both
# are live at the moment the pass starts, then again after it returns.
hb_age=$(( $(now) - $(jq -r '.generated_epoch' "$H/state/heartbeat.json") ))
say "S5 heartbeat age before pass=${hb_age}s holder=$(kill -0 "$LOCKPID" && echo alive)"
[ "$hb_age" -lt 120 ] || fail "S5 heartbeat was not fresh before the pass"
kill -0 "$LOCKPID" 2>/dev/null || fail "S5 holder was not alive before the pass"
run_wd
expect_eq "$(page_count stall-input done)" 1 "S5 live holder and fresh heartbeat still page"
check_no_restart "S5 live"
save_case s5-live-holder

say "===== S5b a dead holder still pages and the lock is not taken ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 1000
kill "$LOCKPID" 2>/dev/null || true
sleep 0.3
kill -0 "$LOCKPID" 2>/dev/null && fail "S5b holder did not die"
run_wd
expect_eq "$(page_count stall-input done)" 1 "S5b dead holder still pages"
check_no_restart "S5b" allow-dead
save_case s5b-dead-holder

say "===== S5c dry-run records the page and does not send it ====="
make_home 'mode=dry-run'
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 1000
run_wd
expect_eq "$(page_count stall-input dry-run)" 1 "S5c dry-run records the page"
expect_eq "$(page_count stall-input done)" 0 "S5c dry-run does not deliver"
[ ! -s "$H/paged.log" ] || fail "S5c dry-run sent a page: $(cat "$H/paged.log")"
check_no_restart "S5c"
save_case s5c-dry-run

say "===== S5d alerts turned off refuse the page and record the gap ====="
make_home
n=$(now)
stall_task fm-a off "working [at=$((n - 100))]: implementing"
owe_wake 1000
printf 'off\n' > "$H/config/wedge-alarm"
run_wd
expect_eq "$(page_count stall-input refused)" 1 "S5d alerts off refuse the page"
expect_grep "$H/data/watchdog/status.md" "stall-input not paged" "S5d the unpaged stall is a gap"
[ ! -s "$H/paged.log" ] || fail "S5d alerts off sent a page: $(cat "$H/paged.log")"
check_no_restart "S5d"
save_case s5d-alerts-off

say "===== RESULT fails=$FAILS ====="
exit "$FAILS"
