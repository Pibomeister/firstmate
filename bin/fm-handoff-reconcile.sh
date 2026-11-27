#!/usr/bin/env bash
# fm-handoff-reconcile.sh - end a late successor of a failed handoff attempt.
#
# A handoff attempt that times out revokes its nonce, so a successor that
# finishes starting afterwards is refused by bin/fm-handoff-ack.sh and can
# never own the session lock. Nothing ended that session: its terminal stayed
# open, and the next launch put a second successor beside it. This command
# finds those terminals in this home's own handoff event log and ends each
# one once, with proof, or reports it.
#
# Usage:
#   fm-handoff-reconcile.sh                    dry run: print what would happen
#   fm-handoff-reconcile.sh --apply            act, and record each outcome
#   fm-handoff-reconcile.sh --apply --report   act, then print each outcome
#                                              not yet reported (the watcher
#                                              check uses this form)
#   fm-handoff-reconcile.sh --waiting          print "nonce<TAB>handle" for each
#                                              candidate not yet decided; asks
#                                              Orca nothing and changes nothing
#
# A candidate is the terminal handle of a handoff_reject line whose nonce
# this home launched (a handoff_started or handoff_retry line carries it),
# that no handoff_ack line ever accepted, and that is at most LATE_MAX_AGE
# seconds old; the newest such line of a handle decides its nonce. A
# successor that never ran the acknowledgement leaves no reject line and is
# not covered.
#
# The command does nothing at all while a handoff claim or a lock change is
# in progress (state/.handoff-pending, state/.lock.acquire).
#
# A terminal is never ended, and is recorded as kept, when its handle is:
#   - the session lock owner's terminal (terminal= in state/.lock-session),
#   - this process's own terminal,
#   - the captain handle (state/captain-handle),
#   - a recorded direct report's endpoint (terminal= or window= in state/*.meta),
#   - a handle that ever launched or acknowledged a handoff in this home
#     (any handoff_started, handoff_retry or handoff_ack line).
#
# Only an Orca terminal (term_*) is ended, and only when all of these hold:
#   - the lock owner's own terminal is known, so the first rule can be checked,
#   - Orca describes the terminal as connected (orca terminal show),
#   - a bounded read of the terminal's last lines contains the attempt's nonce
#     (the launch prompt and the refused acknowledgement both print it),
#   - the terminal's live process is proven to be the refused successor: the
#     harness pid its reject line recorded (pid=) is inside the process tree
#     that Orca's process sweep (orca diagnostics memory) roots at the
#     terminal's pty session; a nonce on screen alone never proves it, since a
#     reused terminal can still show it,
#   - the claim and lock guards above still hold just before the close.
# The read is saved first under data/handoff-late/<nonce>.txt (owner-only, the
# newest LATE_KEEP files are kept). After the close Orca is asked again: the
# terminal is retired only when Orca then describes it as closed, or no
# longer knows its handle; the close command's exit status proves nothing.
# Any other backend, and any terminal that fails a proof, is left open and
# reported once; a tmux successor window cannot be told from another
# firstmate window by name.
#
# Outcomes are appended to state/handoff-reconcile.tsv:
#   epoch<TAB>nonce<TAB>handle<TAB>verdict<TAB>reason
# with verdict retired, gone, left or kept. A handle with a row is never
# looked at again. A terminal that Orca describes as closed, or whose handle
# Orca no longer knows, is gone; it is retired instead when its screen was
# already saved, because an earlier run was cut off between the close and
# the record. After an Orca restart a session can run on under a new handle;
# that one is not found. Every answer other than those exact ones (a timeout,
# an error, an unreadable screen) gets no row and is tried again by a later
# run.
#
# The session lock, the claim, the acknowledgement and the HANDOFF v1 event
# log are read and never written. Standard output carries only report lines;
# the command exits 0 unless its arguments are wrong.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?FM_HOME must name the home whose handoff log is reconciled}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-clock-lib.sh
. "$SCRIPT_DIR/fm-clock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$SCRIPT_DIR/fm-handoff-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

EVENTS="$STATE/handoff-events.log"
OUTCOMES="$STATE/handoff-reconcile.tsv"
REPORTED="$STATE/handoff-reconcile.reported"
LOCK="$STATE/.handoff-reconcile.lock"
LATE_DIR="$DATA/handoff-late"
LATE_MAX_AGE=86400   # a reject older than this is no longer acted on
LATE_KEEP=20         # saved terminal reads kept
READ_LINES=200       # terminal lines read to find the nonce
CALL_SECS=5          # bound of one Orca call
RUN_BUDGET=6         # stop starting new candidates after this many seconds
TAB=$(printf '\t')

APPLY=0
REPORT=0
WAITING=0
USAGE='usage: fm-handoff-reconcile.sh [--apply [--report] | --waiting]'
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --report) REPORT=1 ;;
    --waiting) WAITING=1 ;;
    -h | --help)
      sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf '%s\n' "$USAGE" >&2
      exit 2
      ;;
  esac
  shift
done
if { [ "$REPORT" = 1 ] && [ "$APPLY" != 1 ]; } || { [ "$WAITING" = 1 ] && [ "$APPLY" = 1 ]; }; then
  printf '%s\n' "$USAGE" >&2
  exit 2
fi

handle_valid() {
  case "$1" in '' | none | unknown | *[!A-Za-z0-9_.:%-]*) return 1 ;; esac
  return 0
}

# A handoff or a lock change is in progress: this is not the time to act.
handoff_busy() {
  [ -e "$STATE/.handoff-pending" ] || [ -L "$STATE/.handoff-pending" ] \
    || [ -e "$STATE/.lock.acquire" ] || [ -L "$STATE/.lock.acquire" ]
}

owner_terminal() {
  local value
  [ -f "$STATE/.lock-session" ] && [ ! -L "$STATE/.lock-session" ] || return 1
  value=$(sed -n 's/^terminal=//p' "$STATE/.lock-session" | head -n 1)
  handle_valid "$value" || return 1
  printf '%s' "$value"
}

# protected_reason <handle>: prints why the handle must be kept; returns 1
# when no rule protects it.
protected_reason() {
  local handle=$1 value meta
  if value=$(owner_terminal) && [ "$value" = "$handle" ]; then
    printf 'lock_owner'
    return 0
  fi
  if value=$(fm_handoff_endpoint_handle) && [ "$value" = "$handle" ]; then
    printf 'own_terminal'
    return 0
  fi
  if [ -f "$STATE/captain-handle" ] && [ ! -L "$STATE/captain-handle" ]; then
    value=$(sed -n 's/^target=//p' "$STATE/captain-handle" | head -n 1)
    if [ "$value" = "$handle" ]; then
      printf 'captain_handle'
      return 0
    fi
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    if grep -Fxq -e "terminal=$handle" -e "window=$handle" "$meta" 2>/dev/null; then
      printf 'task_endpoint'
      return 0
    fi
  done
  if awk -v h="handle=$handle" '
      $1 == "HANDOFF" && ($4 == "event=handoff_started" || $4 == "event=handoff_retry" || $4 == "event=handoff_ack") {
        for (i = 5; i <= NF; i++) if ($i == h) { found = 1; exit }
      }
      END { exit(found ? 0 : 1) }' "$EVENTS" 2>/dev/null; then
    printf 'handoff_party'
    return 0
  fi
  return 1
}

# candidates <now>: "nonce<TAB>handle<TAB>pid" for every late successor still
# to reconcile, oldest first, one line per handle; pid is the harness pid its
# deciding reject line recorded (0 when none was).
candidates() {
  local handled
  handled=$(mktemp "$STATE/.handoff-reconcile.XXXXXX") || return 1
  [ ! -f "$OUTCOMES" ] || cut -f 3 "$OUTCOMES" > "$handled"
  awk -v now="$1" -v max="$LATE_MAX_AGE" -v handled="$handled" '
    BEGIN { while ((getline line < handled) > 0) done[line] = 1 }
    $1 != "HANDOFF" || $2 != "v1" { next }
    {
      ts = ""; event = ""; nonce = ""; handle = ""; reason = ""; pid = ""
      for (i = 3; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "ts") ts = kv[2]
        else if (kv[1] == "event") event = kv[2]
        else if (kv[1] == "nonce") nonce = kv[2]
        else if (kv[1] == "handle") handle = kv[2]
        else if (kv[1] == "reason") reason = kv[2]
        else if (kv[1] == "pid") pid = kv[2]
      }
      if (nonce == "" || nonce == "none" || nonce !~ /^[a-f0-9]+$/) next
      if (event == "handoff_started" || event == "handoff_retry") launched[nonce] = 1
      else if (event == "handoff_ack") acked[nonce] = 1
      else if (event == "handoff_reject") {
        if (handle == "" || handle == "none" || reason == "predecessor_ack" || reason == "lock_held_unbound") next
        if (ts !~ /^[0-9]+$/ || now - ts > max) next
        if (!launched[nonce]) next
        if (!(handle in first)) order[++n] = handle
        first[handle] = nonce
        rpid[handle] = (pid ~ /^[0-9]+$/) ? pid : 0
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        handle = order[i]; nonce = first[handle]
        if (!acked[nonce] && !(handle in done)) printf "%s\t%s\t%s\n", nonce, handle, rpid[handle]
      }
    }' "$EVENTS"
  rm -f "$handled"
}

record() {  # <nonce> <handle> <verdict> <reason>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(fm_now)" "$1" "$2" "$3" "$4" >> "$OUTCOMES"
}

# terminal_state <handle>: prints open, closed or stale, from Orca's own
# description of the terminal. Returns 2 on any other answer, so a timeout or
# an error is never read as a closed terminal. bin/backends/orca.sh
# (fm_backend_orca_terminal_facts) owns what the three answers mean.
terminal_state() {
  local handle=$1 out
  command -v orca >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 2
  # A refused lookup exits non-zero and still prints its JSON answer.
  out=$(fm_run_timed "$CALL_SECS" orca terminal show --terminal "$handle" --json 2>/dev/null) || true
  printf '%s' "$out" | jq -er --arg h "$handle" '
    if .ok == false then (if .error.code == "terminal_handle_stale" then "stale" else empty end)
    elif .result.terminal.handle != $h then empty
    elif .result.terminal.connected == true then "open"
    elif .result.terminal.connected == false and .result.terminal.writable == false then "closed"
    else empty end' 2>/dev/null || return 2
}

# orca_read <handle> <file>: write the terminal's last lines to <file>.
orca_read() {
  local handle=$1 file=$2 out
  fm_backend_source orca || return 1
  out=$(fm_run_timed "$CALL_SECS" orca terminal read --terminal "$handle" --limit "$READ_LINES" --json 2>/dev/null) \
    && fm_backend_orca_json_text "$out" > "$file" 2>/dev/null
}

orca_close() {  # <handle>: ask for the close; the caller verifies it
  if command -v fm_orca_cli_mutation >/dev/null 2>&1; then
    fm_orca_cli_mutation fm_run_timed "$CALL_SECS" orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
  else
    fm_run_timed "$CALL_SECS" orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
  fi
}

# The 32 hex characters of the nonce survive any line wrap or box border once
# every other character is dropped.
read_names_nonce() {  # <file> <nonce>
  [ "${#2}" -ge 16 ] || return 1
  tr -cd 'a-f0-9' < "$1" | grep -Fq -- "$2"
}

# successor_proven <handle> <pid>: 0 when <pid>, the harness pid the refused
# successor recorded with its reject, is live inside the process tree Orca's
# process sweep roots at <handle>'s pty session. 1 when that is read and
# disproven: no pid was recorded, the sweep lists no such session, or the pid
# lies outside its tree. 2 when Orca or the process table cannot be read, or
# the sweep names the session ambiguously, so a later run tries again.
successor_proven() {
  local handle=$1 pid=$2 out pty root
  case "$pid" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
  out=$(fm_run_timed "$CALL_SECS" orca terminal show --terminal "$handle" --json 2>/dev/null) || true
  pty=$(printf '%s' "$out" | jq -er --arg h "$handle" \
    'select(.result.terminal.handle == $h) | .result.terminal.ptyId | strings | select(. != "")' 2>/dev/null) || return 2
  out=$(fm_run_timed "$CALL_SECS" orca diagnostics memory --json 2>/dev/null) || return 2
  root=$(printf '%s' "$out" | jq -er --arg p "$pty" '
    if .ok == false or (.result.worktrees | type) != "array" then error("unreadable") else . end
    | [.result.worktrees[] | (.sessions // [])[] | select(.sessionId == $p) | .pid]
    | if length == 0 then "none"
      elif length == 1 and (.[0] | type) == "number" and .[0] > 1 then .[0] | tostring
      else error("ambiguous") end' 2>/dev/null) || return 2
  [ "$root" != none ] || return 1
  fm_backend_source orca || return 2
  out=$(fm_backend_orca_process_tree "$root") || return 2
  printf '%s\n' "$out" | cut -f 1 | grep -Fxq -- "$pid" || return 1
  return 0
}

prune_saved() {
  local f n=0
  # shellcheck disable=SC2012  # names are <hex>.txt; ls -t gives newest first
  ls -t "$LATE_DIR" 2>/dev/null | while IFS= read -r f; do
    n=$((n + 1))
    case "$f" in *.txt) [ "$n" -le "$LATE_KEEP" ] || rm -f -- "$LATE_DIR/$f" ;; esac
  done
}

# reconcile_one <nonce> <handle> <pid>: one candidate. Prints a dry-run line
# when not applying. Returns 75 when the candidate must be tried again later.
reconcile_one() {
  local nonce=$1 handle=$2 pid=$3 reason read saved state rc
  if reason=$(protected_reason "$handle"); then
    if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" kept "$reason"; else printf 'keep %s (%s)\n' "$handle" "$reason"; fi
    return 0
  fi
  case "$handle" in
    term_*) ;;
    *)
      if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" left backend_not_orca; else printf 'leave %s (backend_not_orca)\n' "$handle"; fi
      return 0
      ;;
  esac
  if ! owner_terminal >/dev/null; then
    if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" left owner_terminal_unknown; else printf 'leave %s (owner_terminal_unknown)\n' "$handle"; fi
    return 0
  fi
  saved="$LATE_DIR/$nonce.txt"
  state=$(terminal_state "$handle") || return 75
  if [ "$state" != open ]; then
    # Its screen is saved only just before a close, so a saved screen means
    # an earlier run closed this terminal and was cut off before recording.
    if [ "$APPLY" != 1 ]; then
      printf 'gone %s\n' "$handle"
    elif [ -f "$saved" ]; then
      record "$nonce" "$handle" retired nonce_proven
    else
      record "$nonce" "$handle" gone "terminal_$state"
    fi
    return 0
  fi
  read=$(mktemp "$STATE/.handoff-reconcile-read.XXXXXX") || return 75
  if ! orca_read "$handle" "$read"; then
    rm -f "$read"
    return 75
  fi
  if ! read_names_nonce "$read" "$nonce"; then
    rm -f "$read"
    if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" left nonce_not_visible; else printf 'leave %s (nonce_not_visible)\n' "$handle"; fi
    return 0
  fi
  successor_proven "$handle" "$pid"
  rc=$?
  if [ "$rc" = 2 ]; then
    rm -f "$read"
    return 75
  fi
  if [ "$rc" != 0 ]; then
    rm -f "$read"
    if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" left successor_not_proven; else printf 'leave %s (successor_not_proven)\n' "$handle"; fi
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    rm -f "$read"
    printf 'retire %s (nonce %s on its screen, successor pid %s in its session)\n' "$handle" "$nonce" "$pid"
    return 0
  fi
  # Last look before the close: the guards may have changed during the read.
  if handoff_busy || protected_reason "$handle" >/dev/null || ! owner_terminal >/dev/null; then
    rm -f "$read"
    return 75
  fi
  if ! mkdir -p "$LATE_DIR" || ! mv -f -- "$read" "$saved"; then
    rm -f "$read"
    return 75
  fi
  prune_saved
  orca_close "$handle"
  state=$(terminal_state "$handle") || return 75
  case "$state" in
    open) record "$nonce" "$handle" left close_not_verified ;;
    *) record "$nonce" "$handle" retired nonce_proven ;;
  esac
  return 0
}

report() {
  local seen=0 total n=0 nonce handle verdict reason
  [ -f "$OUTCOMES" ] || return 0
  [ ! -f "$REPORTED" ] || seen=$(head -n 1 "$REPORTED" 2>/dev/null)
  case "$seen" in '' | *[!0-9]*) seen=0 ;; esac
  total=$(awk 'END { print NR }' "$OUTCOMES")
  [ "$total" -ge "$seen" ] || seen=0
  [ "$total" -gt "$seen" ] || return 0
  while IFS="$TAB" read -r _ nonce handle verdict reason; do
    n=$((n + 1))
    [ "$n" -gt "$seen" ] || continue
    case "$verdict" in
      retired)
        printf 'handoff reconcile: ended the late successor terminal %s of a failed handoff attempt; its last screen is saved at data/handoff-late/%s.txt\n' \
          "$handle" "$nonce"
        ;;
      left)
        printf 'handoff reconcile: a late successor terminal %s of a failed handoff attempt was left open (%s); it can never own this home, close it by hand when it is not in use\n' \
          "$handle" "$reason"
        ;;
    esac
  done < "$OUTCOMES"
  printf '%s\n' "$total" > "$REPORTED"
}

main() {
  local now start nonce handle pid list
  [ -d "$STATE" ] || return 0
  if [ "$WAITING" = 1 ]; then
    [ ! -f "$EVENTS" ] || [ -L "$EVENTS" ] || candidates "$(fm_now)" | cut -f 1,2
    return 0
  fi
  if [ -f "$EVENTS" ] && [ ! -L "$EVENTS" ] && ! handoff_busy; then
    now=$(fm_now)
    start=$(date +%s)
    list=$(candidates "$now") || list=''
    while IFS="$TAB" read -r nonce handle pid; do
      [ -n "$nonce" ] || continue
      handle_valid "$handle" || continue
      [ $(($(date +%s) - start)) -lt "$RUN_BUDGET" ] || break
      handoff_busy && break
      reconcile_one "$nonce" "$handle" "$pid" || true
    done <<EOF
$list
EOF
  fi
  [ "$REPORT" != 1 ] || report
  return 0
}

if [ "$APPLY" = 1 ]; then
  [ -d "$STATE" ] || exit 0
  # One run at a time; a busy lock means another run is doing this work.
  fm_lock_acquire_wait_max "$LOCK" 2 2>/dev/null || exit 0
  trap 'fm_lock_release "$LOCK" 2>/dev/null || true' EXIT
fi
main
exit 0
