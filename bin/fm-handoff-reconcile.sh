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
#
# A candidate is the terminal handle of a handoff_reject line whose nonce
# this home launched (a handoff_started or handoff_retry line carries it),
# that no handoff_ack line ever accepted, and that is at most LATE_MAX_AGE
# seconds old. A successor that never ran the acknowledgement leaves no
# reject line and is not covered.
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
#   - a bounded read of the terminal's last lines contains the attempt's nonce
#     (the launch prompt and the refused acknowledgement both print it),
#   - the claim and lock guards above still hold just before the close.
# The read is saved first under data/handoff-late/<nonce>.txt (owner-only, the
# newest LATE_KEEP files are kept). After the close the terminal is read
# again: the close command's exit status proves nothing. Any other backend,
# and any terminal that fails a proof, is left open and reported once; a tmux
# successor window cannot be told from another firstmate window by name.
#
# Outcomes are appended to state/handoff-reconcile.tsv:
#   epoch<TAB>nonce<TAB>handle<TAB>verdict<TAB>reason
# with verdict retired, gone, left or kept. A handle with a row is never
# looked at again. A terminal that cannot be read while Orca itself does not
# answer gets no row and is tried again by a later run.
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
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --report) REPORT=1 ;;
    -h | --help)
      sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'usage: fm-handoff-reconcile.sh [--apply [--report]]\n' >&2
      exit 2
      ;;
  esac
  shift
done
if [ "$REPORT" = 1 ] && [ "$APPLY" != 1 ]; then
  printf 'usage: fm-handoff-reconcile.sh [--apply [--report]]\n' >&2
  exit 2
fi

handle_valid() {
  case "$1" in '' | none | unknown | *[!A-Za-z0-9_.:%-]*) return 1 ;; esac
  return 0
}

# A handoff or a lock change is in progress: this is not the time to act.
handoff_busy() {
  [ -e "$STATE/.handoff-pending" ] || [ -L "$STATE/.handoff-pending" ] || [ -e "$STATE/.lock.acquire" ]
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

# candidates <now>: "nonce<TAB>handle" for every late successor still to
# reconcile, oldest first, one line per handle.
candidates() {
  local handled
  handled=$(mktemp "$STATE/.handoff-reconcile.XXXXXX") || return 1
  [ ! -f "$OUTCOMES" ] || cut -f 3 "$OUTCOMES" > "$handled"
  awk -v now="$1" -v max="$LATE_MAX_AGE" -v handled="$handled" '
    BEGIN { while ((getline line < handled) > 0) done[line] = 1 }
    $1 != "HANDOFF" || $2 != "v1" { next }
    {
      ts = ""; event = ""; nonce = ""; handle = ""; reason = ""
      for (i = 3; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "ts") ts = kv[2]
        else if (kv[1] == "event") event = kv[2]
        else if (kv[1] == "nonce") nonce = kv[2]
        else if (kv[1] == "handle") handle = kv[2]
        else if (kv[1] == "reason") reason = kv[2]
      }
      if (nonce == "" || nonce == "none" || nonce !~ /^[a-f0-9]+$/) next
      if (event == "handoff_started" || event == "handoff_retry") launched[nonce] = 1
      else if (event == "handoff_ack") acked[nonce] = 1
      else if (event == "handoff_reject") {
        if (handle == "" || handle == "none" || reason == "predecessor_ack" || reason == "lock_held_unbound") next
        if (ts !~ /^[0-9]+$/ || now - ts > max) next
        if (!(handle in first)) { order[++n] = handle; first[handle] = nonce }
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        handle = order[i]; nonce = first[handle]
        if (launched[nonce] && !acked[nonce] && !(handle in done)) printf "%s\t%s\n", nonce, handle
      }
    }' "$EVENTS"
  rm -f "$handled"
}

record() {  # <nonce> <handle> <verdict> <reason>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(fm_now)" "$1" "$2" "$3" "$4" >> "$OUTCOMES"
}

# orca_read <handle> <file>: write the terminal's last lines to <file>.
# Returns 0 on a read, 1 when the terminal is gone while Orca answers, and 2
# when Orca itself cannot be asked.
orca_read() {
  local handle=$1 file=$2 out
  command -v orca >/dev/null 2>&1 || return 2
  fm_backend_source orca || return 2
  if out=$(fm_run_timed "$CALL_SECS" orca terminal read --terminal "$handle" --limit "$READ_LINES" --json 2>/dev/null) \
    && fm_backend_orca_json_text "$out" > "$file" 2>/dev/null; then
    return 0
  fi
  : > "$file"
  fm_run_timed "$CALL_SECS" orca status --json >/dev/null 2>&1 || return 2
  return 1
}

# The 32 hex characters of the nonce survive any line wrap or box border once
# every other character is dropped.
read_names_nonce() {  # <file> <nonce>
  [ "${#2}" -ge 16 ] || return 1
  tr -cd 'a-f0-9' < "$1" | grep -Fq -- "$2"
}

prune_saved() {
  local f n=0
  # shellcheck disable=SC2012  # names are <hex>.txt; ls -t gives newest first
  ls -t "$LATE_DIR" 2>/dev/null | while IFS= read -r f; do
    n=$((n + 1))
    case "$f" in *.txt) [ "$n" -le "$LATE_KEEP" ] || rm -f -- "$LATE_DIR/$f" ;; esac
  done
}

# reconcile_one <nonce> <handle>: one candidate. Prints a dry-run line when
# not applying. Returns 75 when the candidate must be tried again later.
reconcile_one() {
  local nonce=$1 handle=$2 reason read rc=0 saved
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
  read=$(mktemp "$STATE/.handoff-reconcile-read.XXXXXX") || return 75
  orca_read "$handle" "$read" || rc=$?
  case "$rc" in
    0) ;;
    1)
      rm -f "$read"
      if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" gone terminal_not_found; else printf 'gone %s\n' "$handle"; fi
      return 0
      ;;
    *)
      rm -f "$read"
      return 75
      ;;
  esac
  if ! read_names_nonce "$read" "$nonce"; then
    rm -f "$read"
    if [ "$APPLY" = 1 ]; then record "$nonce" "$handle" left nonce_not_visible; else printf 'leave %s (nonce_not_visible)\n' "$handle"; fi
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    rm -f "$read"
    printf 'retire %s (nonce %s proven on its screen)\n' "$handle" "$nonce"
    return 0
  fi
  # Last look before the close: the guards may have changed during the read.
  if handoff_busy || protected_reason "$handle" >/dev/null || ! owner_terminal >/dev/null; then
    rm -f "$read"
    return 75
  fi
  saved="$LATE_DIR/$nonce.txt"
  if ! mkdir -p "$LATE_DIR" || ! mv -f -- "$read" "$saved"; then
    rm -f "$read"
    return 75
  fi
  prune_saved
  fm_run_timed "$CALL_SECS" orca terminal close --terminal "$handle" --json >/dev/null 2>&1 || true
  read=$(mktemp "$STATE/.handoff-reconcile-read.XXXXXX") || return 75
  rc=0
  orca_read "$handle" "$read" || rc=$?
  rm -f "$read"
  case "$rc" in
    1) record "$nonce" "$handle" retired "nonce_proven" ;;
    0) record "$nonce" "$handle" left close_not_verified ;;
    *) return 75 ;;
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
  local now start nonce handle list
  [ -d "$STATE" ] || return 0
  if [ -f "$EVENTS" ] && [ ! -L "$EVENTS" ] && ! handoff_busy; then
    now=$(fm_now)
    start=$(date +%s)
    list=$(candidates "$now") || list=''
    while IFS="$TAB" read -r nonce handle; do
      [ -n "$nonce" ] || continue
      handle_valid "$handle" || continue
      [ $(($(date +%s) - start)) -lt "$RUN_BUDGET" ] || break
      handoff_busy && break
      reconcile_one "$nonce" "$handle" || true
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
