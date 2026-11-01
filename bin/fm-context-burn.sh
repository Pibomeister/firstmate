#!/usr/bin/env bash
# fm-context-burn.sh - record the external auto-compact footer and point at a report.
#
# Usage:
#   fm-context-burn.sh record --turn-type <type> [--percent <0-100>] [--session <id>]
#                              [--footer-file <path>] [--payload-file <path>]
#   fm-context-burn.sh report <file-under-data>
#
# record appends one sample to state/context-burn.tsv:
#   epoch, session, turn_type, percent
# The percent is the external footer ("N% until auto-compact"), never a model's
# self-estimate. Pass --percent or --footer-file only for footer text already
# read from that pane. With neither, record reads the supervisor pane the same
# way bin/fm-heartbeat.sh does, and only inside a genuine primary home.
# No footer means no sample and exit 0. Nothing is invented.
#
# --turn-type auto classifies the turn from a hook payload on stdin, or from
# --payload-file. The payload's transcript_path is tailed, not read whole.
# Startup is tested first: the operating block also contains the other markers.
#   startup     the last user text contains "SUPERVISION OPERATING INSTRUCTIONS"
#   heartbeat   else it contains "heartbeat:"
#   wake        else it contains "signal:", "stale:", "check:", or "Stop hook feedback"
#   captain     any other user text
#   turn        no transcript text
# Any other --turn-type is stored as given when it matches [a-z][a-z0-9-]{0,31}.
#
# A fresh session is one whose first sample is at most FM_CONTEXT_BURN_FRESH
# seconds old (default 7200). When the newest sample in the last
# FM_CONTEXT_BURN_WINDOW seconds (default 900) is at least FM_CONTEXT_BURN_DROP
# points (default 30) below the highest earlier sample in that window, record
# prints one alert line and queues one check wake. That 30 is the concrete
# reading of "more than about 30 points". The wake is not repeated for that
# session until a later sample is no longer such a drop. A session id of
# "unknown" is recorded and never alerts. An identical session, turn type, and
# percent within FM_CONTEXT_BURN_DEDUPE seconds (default 2) is not written again.
#
# FM_CONTEXT_BURN_NOW overrides the clock. Pane capture is skipped when
# FM_TEST_SEAM=1 unless FM_CONTEXT_BURN_CAPTURE=1.
#
# report prints one line, "<home-relative-path> <sha256>", for a regular file
# under data/. That is the pane line for a long report.
#
# Exit 0 on a recorded sample, a duplicate, a missing footer, or a report.
# Exit 1 when report cannot name a file under data/. Exit 2 on bad usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# shellcheck source=bin/fm-context-footer-lib.sh
. "$SCRIPT_DIR/fm-context-footer-lib.sh"

int_or() { # <value> <default>
  case "$1" in
    ''|*[!0-9]*|0) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

WINDOW=$(int_or "${FM_CONTEXT_BURN_WINDOW:-}" 900)
DROP=$(int_or "${FM_CONTEXT_BURN_DROP:-}" 30)
FRESH=$(int_or "${FM_CONTEXT_BURN_FRESH:-}" 7200)
DEDUPE=$(int_or "${FM_CONTEXT_BURN_DEDUPE:-}" 2)
NOW=$(int_or "${FM_CONTEXT_BURN_NOW:-}" 0)
if [ "$NOW" -eq 0 ]; then
  NOW=$(date +%s)
fi

sanitize_id() {
  local safe
  safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_')
  case "$safe" in
    ''|_) printf 'unknown\n' ;;
    *) printf '%s\n' "$safe" ;;
  esac
}

classify_text() {
  local text=$1
  case "$text" in
    *'SUPERVISION OPERATING INSTRUCTIONS'*) printf 'startup\n' ;;
    *'heartbeat:'*) printf 'heartbeat\n' ;;
    *'signal:'*|*'stale:'*|*'check:'*|*'Stop hook feedback'*) printf 'wake\n' ;;
    '') printf 'turn\n' ;;
    *) printf 'captain\n' ;;
  esac
}

last_user_text() { # <transcript>
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tail -n 4000 "$file" 2>/dev/null | jq -Rr '
    fromjson?
    | select(.type? == "user")
    | .message.content? // empty
    | if type == "string" then .
      elif type == "array" then [.[]? | select(.type? == "text") | .text? // empty] | join(" ")
      else empty end
    | gsub("[\r\n]+"; " ")
  ' 2>/dev/null | awk 'NF { last=$0 } END { if (last != "") print last }' | cut -c1-2000
}

classify_payload() { # <json>
  local json=$1 transcript='' text='' session_from_payload=''
  if [ -z "$json" ] || ! command -v jq >/dev/null 2>&1; then
    CLASSIFIED_TURN=turn
    return 0
  fi
  transcript=$(printf '%s' "$json" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  session_from_payload=$(printf '%s' "$json" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)
  if [ -n "$session_from_payload" ]; then
    PAYLOAD_SESSION=$session_from_payload
  fi
  if [ -n "$transcript" ]; then
    text=$(last_user_text "$transcript" || true)
  fi
  CLASSIFIED_TURN=$(classify_text "$text")
}

primary_scope_ok() {
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE"
}

capture_pane_percent() {
  local backend target
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  backend=$(discover_supervisor_backend 2>/dev/null || true)
  target=$(discover_supervisor_target 2>/dev/null || true)
  [ -n "$backend" ] && [ -n "$target" ] || return 0
  fm_backend_capture "$backend" "$target" 5 2>/dev/null \
    | awk 'NF' | tail -n 5 | fm_context_footer_percent_from_text || true
}

read_session_lock() {
  command -v fm_session_lock_recorded_session_id >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
}

alert_for_log() { # <session>
  local session=$1 result high low seconds turn_type
  result=$(awk -F '\t' \
    -v session="$session" -v now="$NOW" -v window="$WINDOW" -v drop="$DROP" -v fresh="$FRESH" '
    $2 == session && $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
      e = $1 + 0
      p = $4 + 0
      if (first_e == 0 || e < first_e) first_e = e
      if (e >= now - window && e <= now) {
        n++
        ep[n] = e
        pc[n] = p
        ty[n] = $3
      }
    }
    END {
      if (first_e == 0 || now - first_e > fresh || n < 2) exit 0
      latest = 1
      for (i = 2; i <= n; i++) if (ep[i] >= ep[latest]) latest = i
      high = -1
      high_e = 0
      for (i = 1; i <= n; i++) {
        if (i == latest || ep[i] > ep[latest]) continue
        if (pc[i] > high || (pc[i] == high && (high_e == 0 || ep[i] < high_e))) {
          high = pc[i]
          high_e = ep[i]
        }
      }
      if (high < 0) exit 0
      delta = high - pc[latest]
      if (delta + 0 >= drop + 0) printf "%s %s %s %s\n", high, pc[latest], ep[latest] - high_e, ty[latest]
    }
  ' "$STATE/context-burn.tsv" 2>/dev/null || true)
  [ -n "$result" ] || return 1
  high=${result%% *}
  result=${result#* }
  low=${result%% *}
  result=${result#* }
  seconds=${result%% *}
  turn_type=${result#* }
  ALERT_HIGH=$high
  ALERT_LOW=$low
  ALERT_SECONDS=$seconds
  ALERT_TURN=$turn_type
  return 0
}

queue_alert() { # <session> <safe>
  local session=$1 safe=$2 marker key payload
  marker="$STATE/.context-burn-alert.$safe"
  key="context-burn-$safe"
  payload="check: context burn session ${session} dropped from ${ALERT_HIGH} to ${ALERT_LOW} in ${ALERT_SECONDS}s turn ${ALERT_TURN}"
  if [ -e "$marker" ]; then
    return 0
  fi
  (set -C; printf '%s\n' "$NOW" > "$marker") 2>/dev/null || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_wake_append check "$key" "$payload"; then
    rm -f "$marker"
    return 0
  fi
  printf 'alert: %s dropped from %s to %s in %ss turn %s\n' \
    "$session" "$ALERT_HIGH" "$ALERT_LOW" "$ALERT_SECONDS" "$ALERT_TURN"
}

clear_alert_marker() { # <safe>
  rm -f "$STATE/.context-burn-alert.$1"
}

cmd_record() {
  local turn_type='' session='' percent='' footer_file='' payload_file='' payload=''
  local safe='' last_epoch='' last_session='' last_type='' last_percent=''
  PAYLOAD_SESSION=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --turn-type)
        [ "$#" -gt 1 ] || { echo 'fm-context-burn: --turn-type requires a value' >&2; exit 2; }
        turn_type=$2
        shift 2
        ;;
      --session)
        [ "$#" -gt 1 ] || { echo 'fm-context-burn: --session requires a value' >&2; exit 2; }
        session=$2
        shift 2
        ;;
      --percent)
        [ "$#" -gt 1 ] || { echo 'fm-context-burn: --percent requires a value' >&2; exit 2; }
        percent=$2
        shift 2
        ;;
      --footer-file)
        [ "$#" -gt 1 ] || { echo 'fm-context-burn: --footer-file requires a value' >&2; exit 2; }
        footer_file=$2
        shift 2
        ;;
      --payload-file)
        [ "$#" -gt 1 ] || { echo 'fm-context-burn: --payload-file requires a value' >&2; exit 2; }
        payload_file=$2
        shift 2
        ;;
      *)
        echo "fm-context-burn: unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done
  [ -n "$turn_type" ] || { echo 'fm-context-burn: --turn-type is required' >&2; exit 2; }

  payload=
  if [ -n "$payload_file" ]; then
    [ -f "$payload_file" ] && [ ! -L "$payload_file" ] || { echo 'fm-context-burn: payload file is not readable' >&2; exit 2; }
    payload=$(cat "$payload_file" 2>/dev/null || true)
  elif [ "$turn_type" = auto ] && [ ! -t 0 ]; then
    payload=$(cat 2>/dev/null || true)
  fi

  if [ "$turn_type" = auto ]; then
    classify_payload "$payload"
    turn_type=$CLASSIFIED_TURN
  fi
  case "$turn_type" in
    [a-z]*) ;;
    *) echo 'fm-context-burn: --turn-type must be a short lowercase word' >&2; exit 2 ;;
  esac
  case "$turn_type" in
    *[!a-z0-9-]*) echo 'fm-context-burn: --turn-type must be a short lowercase word' >&2; exit 2 ;;
  esac
  if [ "${#turn_type}" -gt 32 ]; then
    echo 'fm-context-burn: --turn-type must be a short lowercase word' >&2
    exit 2
  fi

  if [ -z "$session" ] && [ -n "${PAYLOAD_SESSION:-}" ]; then
    session=$PAYLOAD_SESSION
  fi
  if [ -z "$session" ]; then
    read_session_lock || true
    if command -v fm_session_lock_recorded_session_id >/dev/null 2>&1; then
      session=$(fm_session_lock_recorded_session_id "$STATE" 2>/dev/null || true)
    fi
  fi
  [ -n "$session" ] || session=unknown
  session=$(sanitize_id "$session")

  if [ -n "$percent" ]; then
    case "$percent" in
      ''|*[!0-9]*) echo 'fm-context-burn: --percent must be an integer from 0 to 100' >&2; exit 2 ;;
    esac
    percent=$((10#$percent))
    if [ "$percent" -gt 100 ]; then
      echo 'fm-context-burn: --percent must be an integer from 0 to 100' >&2
      exit 2
    fi
  elif [ -n "$footer_file" ]; then
    [ -f "$footer_file" ] && [ ! -L "$footer_file" ] || { echo 'fm-context-burn: footer file is not readable' >&2; exit 2; }
    percent=$(fm_context_footer_percent_from_text < "$footer_file" || true)
  elif [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_CONTEXT_BURN_CAPTURE:-}" != 1 ]; then
    percent=
  elif primary_scope_ok; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    percent=$(fm_run_timed_fn 2 capture_pane_percent 2>/dev/null || true)
  else
    exit 0
  fi
  [ -n "$percent" ] || exit 0
  case "$percent" in
    ''|*[!0-9]*) exit 0 ;;
  esac

  mkdir -p "$STATE"
  if [ -f "$STATE/context-burn.tsv" ]; then
    IFS=$'\t' read -r last_epoch last_session last_type last_percent _ <<EOF
$(tail -n 1 "$STATE/context-burn.tsv")
EOF
    case "$last_epoch" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$last_session" = "$session" ] && [ "$last_type" = "$turn_type" ] \
          && [ "$last_percent" = "$percent" ] && [ $((NOW - last_epoch)) -le "$DEDUPE" ] \
          && [ $((NOW - last_epoch)) -ge 0 ]; then
          exit 0
        fi
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\n' "$NOW" "$session" "$turn_type" "$percent" >> "$STATE/context-burn.tsv"
  safe=$(sanitize_id "$session")
  if [ "$session" = unknown ]; then
    exit 0
  fi
  if alert_for_log "$session"; then
    queue_alert "$session" "$safe"
  else
    clear_alert_marker "$safe"
  fi
}

cmd_report() {
  local file=$1 file_dir file_base file_real data_real rel sum
  [ -n "$file" ] || { echo 'fm-context-burn: report requires a file under data/' >&2; exit 2; }
  if [ ! -f "$file" ] && [ -f "$FM_HOME/$file" ]; then
    file=$FM_HOME/$file
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || { echo 'fm-context-burn: report file is not a regular file under data/' >&2; exit 1; }
  [ -d "$DATA" ] || { echo 'fm-context-burn: report file is not a regular file under data/' >&2; exit 1; }
  data_real=$(cd -P "$DATA" && pwd)
  file_dir=$(cd -P "$(dirname "$file")" && pwd) || { echo 'fm-context-burn: report file is not a regular file under data/' >&2; exit 1; }
  file_base=$(basename "$file")
  file_real=$file_dir/$file_base
  case "$file_real" in
    "$data_real"/*) ;;
    *) echo 'fm-context-burn: report file is not a regular file under data/' >&2; exit 1 ;;
  esac
  rel="data/${file_real#"$data_real"/}"
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$file_real" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum "$file_real" | awk '{print $1}')
  else
    echo 'fm-context-burn: sha256 tool is missing' >&2
    exit 1
  fi
  [ -n "$sum" ] || { echo 'fm-context-burn: sha256 failed' >&2; exit 1; }
  printf '%s %s\n' "$rel" "$sum"
}

PAYLOAD_SESSION=
ALERT_HIGH=
ALERT_LOW=
ALERT_SECONDS=
ALERT_TURN=

mode=${1:-}
[ -n "$mode" ] || { echo 'fm-context-burn: record or report is required' >&2; exit 2; }
shift
case "$mode" in
  record) cmd_record "$@" ;;
  report)
    [ "$#" -eq 1 ] || { echo 'fm-context-burn: report takes one file' >&2; exit 2; }
    cmd_report "$1"
    ;;
  *)
    echo "fm-context-burn: unknown command: $mode" >&2
    exit 2
    ;;
esac
