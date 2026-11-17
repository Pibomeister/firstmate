#!/usr/bin/env bash
# fm-escalate.sh - the escalation gate: the one writer of the incident ledger
# and the one place that decides whether a transition is sent.
#
# Usage:
#   fm-escalate.sh report --subject <subject> --signal <signal> --state <state>
#                         [--cause <incident-key>] [--text <text> | --text-file <file>]
#                         [--wake] [--detail <detail>]
#
# A signal owner reports each transition of one subject. The gate reads the
# incident ledger (bin/fm-incident-ledger-lib.sh) under its lock, decides, and
# prints one line:
#   transition=<id|none> action=<action|none> wake=<seq|none> send=<sent|failed|pending|held|none>
# docs/escalation-gate.md owns the rules; this header owns the mechanics.
#
# The home is the resolved FM_HOME. The class of a state comes from
# bin/fm-escalation-class-map.tsv; a state the map does not name is routine, and
# a class other than routine and closure is an exception class.
#
# Decision, against the latest ledger row of (home, subject, signal):
#   same state, suppressed   append nothing; print transition=none action=none.
#                            Suppressed means the state is routine, or the open
#                            episode already escalated this state, or
#                            a cause rule below still holds.
#   same state, released     the exception state repeats, its open episode holds
#                            no escalation of this state, and no cause rule holds
#                            any more: append an escalate row, or a delta from
#                            the last sent state when the episode already sent another state.
#   any other report         append one row. A routine state closes an open
#                            episode (action closure, one closure record sent) or
#                            is a record row; the first exception of an episode
#                            opens episode e<N>; its first send is an escalation,
#                            and later states not yet escalated are deltas from
#                            the last escalated state; every other case is a record row.
# Cause rules. --cause names an incident key (home|subject|signal|state). A
# report is a record row when that key is open (its latest row has that state
# and belongs to an open episode), or when an open episode of another
# (home, subject, signal) holds a row whose cause column is this report's key
# and an escalate or delta row. Both rules read only the incident ledger, so
# either arrival order and a restart between the reports give one escalation.
# A producer that reports a cause and its effect reports the cause first, and
# passes --cause on the effect.
#
# --text or --text-file is a caller body appended to an escalate message (at
# most 500 characters, on one line); --detail is appended to any sent message.
# The gate adds only key fields, states, class names, counts and times.
#
# --wake enqueues one wake of kind incident, key incident-<transition-id> and
# payload transition=<id> for the appended row, or for the latest row of a
# repeated state, unless the wake queue or the wake ledger already holds that
# key (then wake=none). A producer passes --wake the same way on every report
# of one signal.
#
# Nothing calls this gate yet, and no consumer handles an incident wake yet:
# the away-mode daemon loop skips a row of that kind and its acknowledgement
# consumes it, and the supervisor contract names no handling for it. No
# producer may call the gate with --wake until that handling lands, so it comes
# before any existing sender is routed through the gate.
#
# A send goes through wedge_alarm_notify (bin/fm-notify-lib.sh). send=pending
# when no channel was attempted (the channel list is off or empty).
#
# Exit 0 after a decision, 1 on a refused flag, a missing state directory or a
# failed write, 2 on an unknown subcommand. -h or --help prints this header.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state
# directory. With FM_TEST_SEAM=1: FM_ESCALATE_DELIVER names a command that
# receives the message as $1 instead of any channel (exit 0 reads as sent), and
# FM_ESCALATE_CRASH_AT=after-append|after-enqueue kills this process right after
# that step.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME STATE
CLASS_MAP="$SCRIPT_DIR/fm-escalation-class-map.tsv"
# Sourcing the libraries below creates the state directory, so refuse a missing one first.
if [ "${1:-}" = report ] && [ ! -d "$STATE" ]; then
  printf 'fm-escalate: state directory not found: %s\n' "$STATE" >&2
  exit 1
fi
# shellcheck source=bin/fm-incident-ledger-lib.sh
. "$SCRIPT_DIR/fm-incident-ledger-lib.sh"
# shellcheck source=bin/fm-notify-lib.sh
. "$SCRIPT_DIR/fm-notify-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-escalate: %s\n' "$*" >&2
  exit 1
}

crash_at() {  # <point>: test-only kill point
  [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_ESCALATE_CRASH_AT:-}" = "$1" ] || return 0
  kill -KILL "$$"
}

# class_of <signal> <state>: the mapped class; routine when the map has no row.
class_of() {
  local class=
  if [ "$2" != cleared ] && [ -f "$CLASS_MAP" ]; then
    class=$(awk -F '\t' -v sig="$1" -v st="$2" '$1 !~ /^#/ && $1 == sig && $2 == st { print $3; exit }' "$CLASS_MAP")
  fi
  case "$class" in
    ''|closure) printf 'routine\n' ;;
    *) printf '%s\n' "$class" ;;
  esac
}

# Fields of the latest row, filled by split_row.
R_ID='' R_STATE='' R_EPISODE=''
split_row() {  # <row>
  local _e _h _s _g _c _cause _res _act
  IFS=$'\t' read -r R_ID _e _h _s _g R_STATE _c R_EPISODE _cause _res _act <<< "$1"
}

# open_episode <row>: 0 when the row belongs to an open episode.
open_episode() {
  local id ep action
  id=$(printf '%s' "$1" | cut -f1)
  ep=$(printf '%s' "$1" | cut -f8)
  action=$(printf '%s' "$1" | cut -f11)
  [ -n "$id" ] && [ "$ep" != - ] && [ "$action" != closure ]
}

# episode_has <home> <subject> <signal> <episode> <regex-of-actions> [<state>]
episode_has() {
  fm_incident_ledger_episode_rows "$STATE" "$1" "$2" "$3" "$4" \
    | awk -F '\t' -v re="^($5)\$" -v st="${6:-}" '$11 ~ re && (st == "" || $6 == st) { f = 1 } END { exit !f }'
}

# key_open <incident-key>: 0 when the key is open in the ledger.
key_open() {
  local h s g st latest
  IFS='|' read -r h s g st <<< "$1"
  [ -n "$h" ] && [ -n "$s" ] && [ -n "$g" ] && [ -n "$st" ] || return 1
  latest=$(fm_incident_ledger_latest "$STATE" "$h" "$s" "$g")
  [ -n "$latest" ] || return 1
  open_episode "$latest" || return 1
  [ "$(printf '%s' "$latest" | cut -f6)" = "$(_fm_incident_field "$st")" ]
}

# effect_escalated <key>: 0 when an open episode of another (home, subject,
# signal) holds a row whose cause is <key> and an escalate or delta row.
effect_escalated() {
  local key=$1 h s g ep latest lep
  while IFS=$'\t' read -r h s g ep; do
    [ -n "$h" ] || continue
    latest=$(fm_incident_ledger_latest "$STATE" "$h" "$s" "$g")
    open_episode "$latest" || continue
    lep=$(printf '%s' "$latest" | cut -f8)
    [ "$lep" = "$ep" ] || continue
    episode_has "$h" "$s" "$g" "$ep" 'escalate|delta' && return 0
  done < <(_fm_incident_select "$STATE" rows - - - 0 \
    | awk -F '\t' -v key="$key" -v h="$HOME_F" -v s="$SUBJECT_F" -v g="$SIGNAL_F" \
      '$9 == key && !($3 == h && $4 == s && $5 == g) && !seen[$3 "\t" $4 "\t" $5 "\t" $8]++ { print $3 "\t" $4 "\t" $5 "\t" $8 }')
  return 1
}

# cause_holds: 0 when this report meets a cause rule.
cause_holds() {
  if [ -n "$CAUSE" ] && key_open "$CAUSE"; then
    return 0
  fi
  effect_escalated "$(fm_incident_key "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$STATE_ARG")"
}

next_episode() {
  local n
  n=$(_fm_incident_select "$STATE" rows - - - 0 \
    | awk -F '\t' -v h="$HOME_F" -v s="$SUBJECT_F" -v g="$SIGNAL_F" \
      '$3 == h && $4 == s && $5 == g && $8 ~ /^e[0-9]+$/ { v = substr($8, 2) + 0; if (v > max) max = v } END { print max + 1 }')
  printf 'e%s\n' "$n"
}

oneline() {  # <max> <text>: one line, at most <max> characters
  printf '%s' "$2" | tr '\t\r\n' '   ' | cut -c1-"$1"
}

# wake_step <transition-id>: print the queue sequence, or none.
wake_step() {
  local tid=$1 key payload seq status=0
  key="incident-$tid"
  payload="transition=$tid"
  if ! fm_wake_queue_lock_acquire; then
    printf 'fm-escalate: cannot take the wake-queue lock\n' >&2
    return 1
  fi
  seq=none
  if fm_wake_queued_keys_locked incident | grep -Fxq -- "$key" \
    || { [ -f "$STATE/wake-ledger.tsv" ] \
      && awk -F '\t' -v k="\"$key\"" 'index($6, k) { f = 1 } END { exit !f }' "$STATE/wake-ledger.tsv"; }; then
    :
  elif fm_wake_append_locked incident "$key" "$payload"; then
    seq=$(cat "$STATE/.wake-queue.seq" 2>/dev/null || echo none)
  else
    status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$seq"
}

# send_message <message>: print sent, failed or pending.
send_message() {
  local msg=$1 rc=0
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_ESCALATE_DELIVER:-}" ]; then
    "$FM_ESCALATE_DELIVER" "$msg" > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && printf 'sent\n' || printf 'failed\n'
    return 0
  fi
  wedge_alarm_notify "$msg" incident-ledger strict > /dev/null 2>&1 || rc=$?
  case "${WEDGE_ALARM_PAGE_RESULT:-pending}" in
    sent|failed) printf '%s\n' "$WEDGE_ALARM_PAGE_RESULT" ;;
    *) printf 'pending\n' ;;
  esac
}

report() {
  local latest tid action episode prev_state cmsg send=none wake=none exc=0 class
  local count=0 suppressed=0 reuse_wake=0 out_tid=none out_action=none

  class=$(class_of "$SIGNAL_F" "$STATE_ARG")
  case "$class" in routine) ;; *) exc=1 ;; esac

  [ -d "$STATE" ] || fail "state directory not found: $STATE"
  fm_incident_ledger_lock "$STATE" || fail 'cannot take the incident-ledger lock'

  latest=$(fm_incident_ledger_latest "$STATE" "$HOME_F" "$SUBJECT_F" "$SIGNAL_F")
  action=''
  episode=-
  prev_state=''
  if [ -n "$latest" ]; then
    split_row "$latest"
    prev_state=$R_STATE
  fi

  if [ -n "$latest" ] && [ "$prev_state" = "$(_fm_incident_field "$STATE_ARG")" ]; then
    # Same state.
    if [ "$exc" -eq 0 ]; then
      suppressed=1
    elif episode_has "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$R_EPISODE" 'escalate|delta' "$(_fm_incident_field "$STATE_ARG")"; then
      suppressed=1
    elif cause_holds; then
      suppressed=1
    fi
    if [ "$suppressed" -eq 1 ]; then
      fm_incident_ledger_unlock "$STATE"
      if [ "$WAKE" = 1 ]; then
        reuse_wake=1
        out_tid=$R_ID
      fi
    else
      action=escalate
      episode=$R_EPISODE
      if episode_has "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$episode" 'escalate|delta'; then
        action='delta'
      fi
    fi
  else
    if [ "$exc" -eq 0 ]; then
      if [ -n "$latest" ] && open_episode "$latest"; then
        action=closure
        episode=$R_EPISODE
      else
        action=record
        episode=-
      fi
    elif [ -n "$latest" ] && open_episode "$latest"; then
      episode=$R_EPISODE
      if cause_holds; then
        action=record
      elif episode_has "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$episode" 'escalate|delta' "$(_fm_incident_field "$STATE_ARG")"; then
        action=record
      elif episode_has "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$episode" 'escalate|delta'; then
        action='delta'
      else
        action=escalate
      fi
    else
      episode=$(next_episode)
      if cause_holds; then
        action=record
      else
        action=escalate
      fi
    fi
  fi

  if [ "$suppressed" -eq 0 ]; then
    if [ "$action" = delta ]; then
      prev_state=$(fm_incident_ledger_episode_rows "$STATE" "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$episode" \
        | awk -F '\t' '$11 == "escalate" || $11 == "delta" { s = $6 } END { print s }')
    fi
    tid=$(fm_incident_ledger_append_locked "$STATE" "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$STATE_ARG" "$class" "$episode" "$CAUSE" "" "$action") || {
      fm_incident_ledger_unlock "$STATE"
      fail 'cannot append the incident-ledger row'
    }
    count=$(fm_incident_ledger_episode_rows "$STATE" "$HOME_F" "$SUBJECT_F" "$SIGNAL_F" "$episode" \
      | awk -F '\t' '$11 == "escalate" || $11 == "delta" { n++ } END { print n + 0 }')
    out_tid=$tid
    out_action=$action
    crash_at after-append
  else
    tid=$out_tid
  fi

  if [ "$WAKE" = 1 ] && { [ "$suppressed" -eq 0 ] || [ "$reuse_wake" -eq 1 ]; }; then
    wake=$(wake_step "$tid") || fail 'cannot enqueue the wake'
    crash_at after-enqueue
  fi

  if [ "$suppressed" -eq 0 ]; then
    case "$action" in
      escalate)
        cmsg="escalation: signal=$SIGNAL_F subject=$SUBJECT_F state=$STATE_ARG class=$class episode=$episode id=$tid"
        [ -z "$BODY" ] || cmsg="$cmsg - $(oneline 500 "$BODY")"
        ;;
      delta)
        cmsg="escalation delta: signal=$SIGNAL_F subject=$SUBJECT_F old=$prev_state new=$STATE_ARG class=$class episode=$episode id=$tid"
        ;;
      closure)
        cmsg="incident closed: signal=$SIGNAL_F subject=$SUBJECT_F state=$STATE_ARG episode=$episode escalations=$count id=$tid"
        ;;
      *) cmsg='' ;;
    esac
    if [ -n "$cmsg" ]; then
      [ -z "$DETAIL" ] || cmsg="$cmsg ($(oneline 200 "$DETAIL"))"
      send=$(send_message "$cmsg")
    fi
  fi
  if [ "$suppressed" -eq 0 ]; then fm_incident_ledger_unlock "$STATE"; fi
  printf 'transition=%s action=%s wake=%s send=%s\n' "$out_tid" "$out_action" "$wake" "$send"
}

cmd_report() {
  SUBJECT_ARG='' SIGNAL_ARG='' STATE_ARG='' CAUSE='' BODY='' DETAIL='' WAKE=0
  local have_subject='' have_signal='' have_state='' have_text='' have_file='' have_cause='' have_detail=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --subject|--signal|--state|--cause|--text|--text-file|--detail)
        [ "$#" -ge 2 ] || fail "$1 needs a value"
        ;;
    esac
    case "$1" in
      --subject) [ -z "$have_subject" ] || fail '--subject given twice'; have_subject=1; SUBJECT_ARG=$2; shift 2 ;;
      --signal) [ -z "$have_signal" ] || fail '--signal given twice'; have_signal=1; SIGNAL_ARG=$2; shift 2 ;;
      --state) [ -z "$have_state" ] || fail '--state given twice'; have_state=1; STATE_ARG=$2; shift 2 ;;
      --cause) [ -z "$have_cause" ] || fail '--cause given twice'; have_cause=1; CAUSE=$2; shift 2 ;;
      --text) [ -z "$have_text$have_file" ] || fail '--text and --text-file are one choice'; have_text=1; BODY=$2; shift 2 ;;
      --text-file)
        [ -z "$have_text$have_file" ] || fail '--text and --text-file are one choice'
        have_file=1
        [ -r "$2" ] || fail "cannot read --text-file: $2"
        BODY=$(cat "$2")
        shift 2 ;;
      --detail) [ -z "$have_detail" ] || fail '--detail given twice'; have_detail=1; DETAIL=$2; shift 2 ;;
      --wake) WAKE=1; shift ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  [ -n "$SUBJECT_ARG" ] || fail '--subject is required'
  [ -n "$SIGNAL_ARG" ] || fail '--signal is required'
  [ -n "$STATE_ARG" ] || fail '--state is required'
  if [ -n "$CAUSE" ]; then
    local h s g st extra
    IFS='|' read -r h s g st extra <<< "$CAUSE"
    [ -n "$h" ] && [ -n "$s" ] && [ -n "$g" ] && [ -n "$st" ] && [ -z "$extra" ] \
      || fail '--cause must be an incident key: home|subject|signal|state'
  fi
  HOME_F=$(_fm_incident_field "$FM_HOME")
  SUBJECT_F=$(_fm_incident_field "$SUBJECT_ARG")
  SIGNAL_F=$(_fm_incident_field "$SIGNAL_ARG")
  report
}

case "${1:-}" in
  report) shift; cmd_report "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
