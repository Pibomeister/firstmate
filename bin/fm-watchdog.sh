#!/usr/bin/env bash
# fm-watchdog.sh - the per-machine firstmate assistant watchdog.
#
# Usage: FM_HOME=<owner-home> fm-watchdog.sh <command>
#   run [--interval <secs>]       Foreground loop for launchd or systemd; one instance.
#   once [--dry-run] [--home <path>]
#                                 One scan and action pass, then rewrite the status file.
#   scan [--home <path>]          One observation pass; prints each subject; no action.
#   judge <purpose> <answer-ere>  Bounded cheap-model call; prompt on stdin; prints the answer.
#   status                        Print the status file.
#   ack-read                      Record that the status file was read now.
#   pickup <token>                Run by a restarted session to prove it took over.
#   manager-name | manager-status | render-launchd | render-systemd
#
# The watchdog layers above the watcher, the away daemon, and
# bin/fm-monitor-watchdog.sh; it changes none of them. It runs outside every
# agent session, never in a terminal pane. docs/watchdog.md owns the behavior
# contract (subjects, symptoms, the action ladder, hard boundaries, the status
# file) and the config/watchdog keys. This header owns the commands and files.
#
# Files, all under the owner home FM_HOME:
#   config/watchdog              key=value configuration; absent means dry-run defaults.
#   state/watchdog/actions.tsv   action ledger: epoch id home subject symptom action phase detail.
#   state/watchdog/model-calls.tsv  epoch purpose model outcome in-tokens out-tokens answer cost.
#   state/watchdog/subjects/<home-basename>-<path-cksum>   the previous observation of each subject.
#   state/watchdog/escalated/<home-basename>-<path-cksum>  present after a restart loop; remove it to clear.
#   state/watchdog/last-read     epoch of the last ack-read.
#   data/watchdog/status.md      the short status file, rewritten atomically after each pass.
#   data/watchdog/handoffs/, data/watchdog/rulings/  restart handoffs and council rulings.
# A restarted session writes <its home>/state/watchdog/pickups/<token>.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_WD_NOW fixes the clock and
# FM_WD_TEST_COMPOSER replaces the composer verdict for a plain test pane.
#
# Exit status: 0 on success, 2 on a usage error, 1 on any other failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME must name the watchdog owner home}
OWNER_HOME=$FM_HOME
STATE=${FM_STATE_OVERRIDE:-$OWNER_HOME/state}
CONF=$OWNER_HOME/config/watchdog
WD=$STATE/watchdog
OUT=$OWNER_HOME/data/watchdog
LEDGER=$WD/actions.tsv
CALLS=$WD/model-calls.tsv

# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"

die() { printf 'fm-watchdog: %s\n' "$1" >&2; exit "${2:-1}"; }

wd_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WD_NOW:-}" ]; then printf '%s\n' "$FM_WD_NOW"; else date +%s; fi
}
cfg() { fm_wd_conf_get "$CONF" "$1" "$2"; }
cfgi() { fm_wd_conf_int "$CONF" "$1" "$2"; }

wd_mode() {
  case "${WD_FORCE_DRY:-}:$(cfg mode dry-run)" in
    1:*) printf 'dry-run\n' ;;
    *:act) printf 'act\n' ;;
    *) printf 'dry-run\n' ;;
  esac
}

wd_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

wd_tag() { basename "$1"; }

# File names for one home's state: the basename can repeat across homes.
wd_state_key() { printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | cksum | cut -d ' ' -f 1)"; }

# A zombie answers kill -0 but has exited.
wd_pid_alive() {  # <pid>
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
  return 0
}

wd_id() { printf 'wd%s%s' "$(wd_now)" "$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; }

# --- subjects ----------------------------------------------------------------

wd_homes() {
  cfg homes "$OWNER_HOME" | tr ',' '\n' | sed -e 's/^[[:blank:]]*//' -e 's/[[:blank:]]*$//' -e '/^$/d'
}

# Prints home TAB parent TAB secondmate-id; the parent and id are `-` for a primary.
wd_subjects() {
  local h reg
  wd_homes | while IFS= read -r h; do
    [ -d "$h/state" ] || continue
    h=$(cd -P -- "$h" && pwd -P) || continue
    printf '%s\t-\t-\n' "$h"
    reg=$h/data/secondmates.md
    [ -f "$reg" ] || continue
    LC_ALL=C sed -nE 's/^- ([A-Za-z0-9._-]+) - .*\(home: ([^;)]+)[;)].*/\1	\2/p' "$reg" |
      while IFS=$'\t' read -r id sm; do
        [ -d "$sm/state" ] || continue
        sm=$(cd -P -- "$sm" && pwd -P) || continue
        printf '%s\t%s\t%s\n' "$sm" "$h" "$id"
      done
  done | awk -F'\t' '!seen[$1]++'
}

wd_do_not_touch() {  # <home> <target>
  local entry canon
  while IFS= read -r entry; do
    canon=$( [ -d "$entry" ] && cd -P -- "$entry" && pwd -P )
    [ "$canon" = "$1" ] || [ "$entry" = "$2" ] || [ "$entry" = "$(wd_tag "$1")" ] && return 0
  done < <(cfg do-not-touch "" | tr ',' '\n' | sed -e 's/^[[:blank:]]*//' -e 's/[[:blank:]]*$//' -e '/^$/d')
  return 1
}

# --- observation ---------------------------------------------------------------

wd_cpu_seconds() {  # <pid>
  ps -o time= -p "$1" 2>/dev/null | awk '
    NF { s = $1; d = 0; if (index(s, "-")) { split(s, dd, "-"); d = dd[1]; s = dd[2] }
         n = split(s, p, ":"); t = 0; for (i = 1; i <= n; i++) t = t * 60 + p[i]; printf "%.2f\n", t + d * 86400 }'
}

wd_pane_sig() {  # <screen>
  printf '%s\n' "$1" | fm_wd_strip_ansi | LC_ALL=C tr -d '0-9' | LC_ALL=C sed -e 's/[✻✽✶✳✢·*⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●◐◓◑◒]//g' | cksum | awk '{print $1}'
}

wd_capture() {  # <backend> <target> <lines>
  fm_run_timed_fn "$(cfgi call-timeout-secs 20)" fm_backend_capture "$1" "$2" "$3" 2>/dev/null
}

# wd_view: the visible viewport where the backend has a verified viewport-only
# read, so a dialog already dismissed but still in scrollback never reads as
# showing; elsewhere the bounded capture.
wd_view() {  # <backend> <target>
  if fm_backend_visible_capture_supported "$1" 2>/dev/null; then
    fm_run_timed_fn "$(cfgi call-timeout-secs 20)" fm_backend_visible_capture "$1" "$2" 2>/dev/null && return 0
  fi
  wd_capture "$1" "$2" 60
}

wd_turn_running() {  # <backend> <target> <screen> -> 1|0|unknown
  local b=$1 t=$2 screen=$3 v
  if printf '%s\n' "$screen" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = n - 7; i <= n; i++) if (i > 0 && tolower(r[i]) ~ /(esc|ctrl\+c) to (interrupt|cancel)/) f = 1; exit !f }'; then
    printf '1\n'; return 0
  fi
  case "$b" in
    orca)
      if v=$(fm_run_timed 10 orca terminal wait --terminal "$t" --for tui-idle --timeout-ms 500 --json 2>/dev/null); then
        printf '0\n'
      elif printf '%s' "$v" | jq -e '.ok == false and .error.code == "timeout"' >/dev/null 2>&1; then
        printf '1\n'
      else
        printf 'unknown\n'
      fi ;;
    herdr|rex|t3code|tern)
      v=$(fm_run_timed_fn 10 fm_backend_busy_state "$b" "$t" 2>/dev/null)
      case "$v" in busy|working) printf '1\n' ;; idle|done) printf '0\n' ;; *) printf 'unknown\n' ;; esac ;;
    *) printf '0\n' ;;
  esac
}

wd_transcript() {  # <home> <session-id>
  local home=$1 sid=$2 d dirs
  case "$sid" in ''|*/*|*..*) return 1 ;; esac
  dirs="$(cfg claude-config-dirs "" | tr ',' ' ') $(head -n 1 "$home/config/claude-account" 2>/dev/null) ${CLAUDE_CONFIG_DIR:-} $HOME/.claude"
  for d in $dirs; do
    [ -d "$d/projects" ] || continue
    CLAUDE_CONFIG_DIR=$d fm_warm_compact_engine_transcript "$sid" 2>/dev/null && return 0
  done
  return 1
}

# Prints task TAB key TAB verb TAB age TAB summary for each open decision in <state>.
wd_open_decisions() {  # <state> <now>
  local st=$1 now=$2 f task key verb summary at
  for f in "$st"/*.status; do
    [ -f "$f" ] || continue
    task=$(basename "$f" .status)
    { status_open_decisions "$f" 2>/dev/null; printf '\n'; } | while IFS=$'\t' read -r key verb summary; do
      [ -n "$key" ] || continue
      at=$(grep -F "[key=$key]" "$f" 2>/dev/null | tail -n 1 | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p')
      [ -n "$at" ] || at=$(wd_mtime "$f")
      printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$key" "$verb" "$((now - at))" "$(printf '%s' "$summary" | tr '\t' ' ' | cut -c1-500)"
    done
  done
}

# Prints task TAB age TAB line for each task whose latest status is a quota pause or block.
wd_quota_floors() {  # <state> <now>
  local st=$1 now=$2 f last at
  for f in "$st"/*.status; do
    [ -f "$f" ] || continue
    last=$(tail -n 1 "$f" 2>/dev/null)
    case "$last" in paused*|blocked*) ;; *) continue ;; esac
    printf '%s' "$last" | tr '[:upper:]' '[:lower:]' | grep -Eq 'quota (floor|exhausted|is exhausted|at 0|limit|wall)|(hit|reached|at) (the |a |its )?quota|rate.?limited|rate limit (hit|reached)|usage limit (hit|reached)|out of (credits|quota)|credits (are )?(exhausted|at 0|empty)' || continue
    at=$(printf '%s' "$last" | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p')
    [ -n "$at" ] || at=$(wd_mtime "$f")
    printf '%s\t%s\t%s\n' "$(basename "$f" .status)" "$((now - at))" "$(printf '%s' "$last" | cut -c1-300)"
  done
}

wd_read_composer() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WD_TEST_COMPOSER:-}" ]; then
    O_COMPOSER=$FM_WD_TEST_COMPOSER
  else
    O_COMPOSER=$(fm_run_timed_fn 20 fm_backend_composer_state "$O_BACKEND" "$O_TARGET" 2>/dev/null) || O_COMPOSER=unknown
  fi
  [ -n "$O_COMPOSER" ] || O_COMPOSER=unknown
  if [ "$O_COMPOSER" = empty ] && [ "$O_BACKEND" = orca ]; then
    local rc=0
    if fm_backend_source orca >/dev/null 2>&1; then
      fm_run_timed_fn 10 fm_backend_orca_draft_present "$O_TARGET" >/dev/null 2>&1 || rc=$?
    fi
    [ "$rc" = 1 ] || O_COMPOSER=pending-unproven
  fi
  O_DRAFT=''
  O_COMPOSER_TEXT=$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = n - 7; i <= n; i++) if (i > 0) print r[i] }')
  O_COMPOSER_ABOVE=$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = 1; i <= n - 8; i++) print r[i] }')
  if [ "$O_BACKEND" = orca ]; then
    O_DRAFT=$(fm_run_timed 10 orca terminal read --terminal "$O_TARGET" --limit 5 --json 2>/dev/null | jq -r '(.result.terminal.draft // .result.draft // "") | tostring' 2>/dev/null)
    O_COMPOSER_TEXT="$O_COMPOSER_TEXT $O_DRAFT"
  fi
}

# wd_observe <home> <parent> <id>: fills the O_* globals for one subject and
# saves the comparable parts to state/watchdog/subjects/<home-basename>-<path-cksum>.
wd_observe() {
  local home=$1 parent=$2 id=$3 st now hb prev meta row hb_sid ctx dt
  st=$home/state
  now=$(wd_now)
  O_HOME=$home O_PARENT=$parent O_ID=$id O_TAG=$(wd_tag "$home") O_KEY=$(wd_state_key "$home")
  O_BACKEND='' O_TARGET='' O_SESSION='' O_HB_AGE=unknown O_CTX='' O_CTX_SRC=''
  O_PANE='' O_SIG='' O_PANE_STATIC=0 O_DIALOG='' O_COMPOSER=unknown O_TURN=unknown
  O_LOCK_PID='' O_ALIVE=0 O_INSTANCE=unknown O_CPU_BUSY=unknown O_TRANSCRIPT='' O_TR_AGE=unknown
  O_LOOP=none O_LOOP_N=0 O_LOOP_SAMPLE='' O_RESTART_REQ=0 O_OWED_N=0 O_OWED_AGE=0
  O_AFK=0 O_DAEMON=unknown O_PREV_COMPOSER='' O_PREV_SIG='' O_COMPOSER_TEXT='' O_COMPOSER_ABOVE='' O_DRAFT=''
  hb=$st/heartbeat.json
  hb_sid='' ctx=''
  if [ -f "$hb" ] && row=$(jq -r '[.primary.terminal.backend // "-", .primary.terminal.target // "-",
        .primary.session.trusted_id // "-", (.generated_epoch // 0 | tostring),
        (.primary.context_left.remaining.percent // "-" | tostring)] | @tsv' "$hb" 2>/dev/null); then
    IFS=$'\t' read -r O_BACKEND O_TARGET hb_sid row ctx <<EOF
$row
EOF
    [ "$O_BACKEND" != - ] || O_BACKEND=''
    [ "$O_TARGET" != - ] || O_TARGET=''
    [ "$hb_sid" != - ] || hb_sid=''
    [ "$row" -gt 0 ] 2>/dev/null || row=$(wd_mtime "$hb")
    O_HB_AGE=$((now - row))
  fi
  if [ -f "$st/.lock" ]; then
    O_LOCK_PID=$(head -n 1 "$st/.lock" 2>/dev/null | tr -cd '0-9')
    if wd_pid_alive "$O_LOCK_PID"; then O_ALIVE=1; fi
    if fm_session_lock_anchor_instance_matches "$st" 2>/dev/null; then O_INSTANCE=match; else O_INSTANCE=mismatch; fi
  fi
  O_SESSION=$(fm_session_lock_recorded_session_id "$st" 2>/dev/null) || O_SESSION=$hb_sid
  if [ "$ctx" != - ] && [ -n "$ctx" ] && [ "$hb_sid" = "$O_SESSION" ] && [ "$O_HB_AGE" != unknown ] && [ "$O_HB_AGE" -lt "$(cfgi watcher-stale-secs 900)" ]; then
    O_CTX=${ctx%%.*}; O_CTX_SRC=heartbeat
  fi
  # A second mate whose own heartbeat names another session, or none, uses the
  # parent's recorded endpoint for it.
  meta=''
  [ "$parent" = - ] || meta=$parent/state/$id.meta
  if [ -n "$meta" ] && [ -f "$meta" ] && { [ -z "$O_TARGET" ] || [ "$hb_sid" != "$O_SESSION" ]; }; then
    O_BACKEND=$(fm_backend_of_meta "$meta" 2>/dev/null)
    O_TARGET=$(fm_backend_target_of_meta "$meta" 2>/dev/null)
  fi
  prev=$WD/subjects/$O_KEY
  local p_sig='' p_since='' p_cpu='' p_at='' p_comp=''
  if [ -f "$prev" ]; then
    p_sig=$(fm_wd_conf_get "$prev" sig '') p_since=$(fm_wd_conf_get "$prev" since '')
    p_cpu=$(fm_wd_conf_get "$prev" cpu '') p_at=$(fm_wd_conf_get "$prev" cpu_at '')
    p_comp=$(fm_wd_conf_get "$prev" composer '')
  fi
  O_PREV_COMPOSER=$p_comp O_PREV_SIG=$p_sig
  local cpu=''
  if [ "$O_ALIVE" = 1 ]; then
    cpu=$(wd_cpu_seconds "$O_LOCK_PID")
    if [ -n "$cpu" ] && [ -n "$p_cpu" ] && [ -n "$p_at" ] && [ "$now" -gt "$p_at" ]; then
      dt=$((now - p_at))
      O_CPU_BUSY=$(awk -v c="$cpu" -v p="$p_cpu" -v dt="$dt" -v pct="$(cfgi cpu-busy-pct 15)" 'BEGIN { print ((c - p) * 100 >= pct * dt) ? 1 : 0 }')
    fi
  fi
  if [ -n "$O_BACKEND" ] && [ -n "$O_TARGET" ]; then
    O_PANE=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) || O_PANE=''
  fi
  if [ -n "$O_PANE" ]; then
    O_SIG=$(wd_pane_sig "$O_PANE")
    if [ "$O_SIG" = "$p_sig" ] && [ -n "$p_since" ]; then O_PANE_STATIC=$((now - p_since)); else p_since=$now; fi
    O_DIALOG=$(fm_wd_pane_dialog "$(wd_view "$O_BACKEND" "$O_TARGET")") || O_DIALOG=''
    wd_read_composer
    O_TURN=$(wd_turn_running "$O_BACKEND" "$O_TARGET" "$O_PANE")
    ctx=$(fm_wd_footer_percent "$O_PANE")
    if [ -z "$O_CTX" ] && [ -n "$ctx" ]; then O_CTX=$ctx; O_CTX_SRC=pane; fi
  fi
  if O_TRANSCRIPT=$(wd_transcript "$home" "$O_SESSION"); then
    O_TR_AGE=$((now - $(wd_mtime "$O_TRANSCRIPT")))
    local ev
    ev=$(fm_wd_transcript_events "$O_TRANSCRIPT" 400)
    IFS=$'\t' read -r O_LOOP O_LOOP_N O_LOOP_SAMPLE <<EOF
$(printf '%s\n' "$ev" | fm_wd_loop_verdict "$(cfgi rapid-loop-secs 180)")
EOF
  else
    O_TRANSCRIPT=''
  fi
  if [ -f "$st/.watchdog-restart-request" ]; then
    local req_at last_r
    req_at=$(wd_mtime "$st/.watchdog-restart-request")
    last_r=$(fm_wd_last_epoch "$LEDGER" "$home" '*' restart '^(pending|dry-run)$')
    [ "$req_at" -gt "${last_r:-0}" ] && O_RESTART_REQ=1
  fi
  # Owed input: wake rows not yet drained, and captain inbox notes not yet handled.
  local wake_n=0 wake_old='' note_n=0 note_old='' f m
  if [ -s "$st/.wake-queue" ]; then
    wake_n=$(awk 'NF' "$st/.wake-queue" | wc -l | tr -d ' ')
    wake_old=$(awk -F'\t' 'NF && $1 ~ /^[0-9]+$/ { if (m == "" || $1 < m) m = $1 } END { print m }' "$st/.wake-queue")
  fi
  for f in "$st"/inbox/*.note; do
    [ -f "$f" ] || continue
    note_n=$((note_n + 1))
    m=$(wd_mtime "$f")
    if [ -z "$note_old" ] || [ "$m" -lt "$note_old" ]; then note_old=$m; fi
  done
  O_OWED_N=$((wake_n + note_n))
  m=${wake_old:-$now}
  if [ -n "$note_old" ] && [ "$note_old" -lt "$m" ]; then m=$note_old; fi
  O_OWED_AGE=$((now - m))
  [ "$O_OWED_AGE" -ge 0 ] || O_OWED_AGE=0
  if [ -f "$st/.afk" ]; then
    O_AFK=1
    m=$(head -n 1 "$st/.supervise-daemon.pid" 2>/dev/null | tr -cd '0-9')
    if [ -n "$m" ] && kill -0 "$m" 2>/dev/null; then O_DAEMON=1; else O_DAEMON=0; fi
  fi
  mkdir -p "$WD/subjects"
  printf 'sig=%s\nsince=%s\ncpu=%s\ncpu_at=%s\ncomposer=%s\n' "$O_SIG" "${p_since:-$now}" "$cpu" "$now" "$O_COMPOSER" > "$prev.tmp" && mv "$prev.tmp" "$prev"
}

wd_print_observation() {
  printf '%s\n' "subject $O_TAG ($O_HOME)" \
    "  endpoint=${O_BACKEND:-none}:${O_TARGET:-none} session=${O_SESSION:-none} lock_pid=${O_LOCK_PID:-none} alive=$O_ALIVE instance=$O_INSTANCE" \
    "  pane_static=${O_PANE_STATIC}s dialog=${O_DIALOG:-none} composer=$O_COMPOSER turn_running=$O_TURN cpu_busy=$O_CPU_BUSY" \
    "  transcript_age=${O_TR_AGE}s loop=$O_LOOP/$O_LOOP_N restart_requested=$O_RESTART_REQ ctx=${O_CTX:-unknown}${O_CTX_SRC:+ ($O_CTX_SRC)}" \
    "  owed=$O_OWED_N oldest=${O_OWED_AGE}s afk=$O_AFK daemon=$O_DAEMON heartbeat_age=${O_HB_AGE}s"
}

# --- actions -------------------------------------------------------------------

# wd_action_gate <symptom> <action> <rate-secs>: 0 when the action may run now.
wd_rate_open() {
  fm_wd_rate_ok "$LEDGER" "$O_HOME" "$1" "$2" "$3" "$(wd_now)"
}

wd_rec() {  # <id> <symptom> <action> <phase> <detail>
  FM_WD_NOW=$(wd_now) fm_wd_record "$LEDGER" "$1" "$O_HOME" "$O_TAG" "$2" "$3" "$4" "$5"
}

# wd_nudge <symptom> <body>: a record-backed doorbell into the subject's own pane.
wd_nudge() {
  local symptom=$1 body="Watchdog (automated, not the captain or the owner): $2" id doorbell verdict
  if ! fm_wd_text_allowed "$body"; then
    wd_gap "$symptom held; its nudge names a merge, deploy, or release word"
    wd_rate_open "$symptom" nudge "$(cfgi nudge-secs 900)" && wd_rec "$(wd_id)" "$symptom" nudge refused "text names a merge, deploy, or release word"
    return 0
  fi
  if [ "$(wd_mode)" = act ] && [ "$O_COMPOSER" != empty ]; then wd_gap "$symptom held; composer is $O_COMPOSER, so nothing is typed"; fi
  wd_rate_open "$symptom" nudge "$(cfgi nudge-secs 900)" || return 0
  id=$(wd_id)
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" nudge refused "endpoint is on do-not-touch"; return 0; fi
  if [ -z "$O_TARGET" ]; then wd_rec "$id" "$symptom" nudge refused "no recorded endpoint"; return 0; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" nudge dry-run "$body"; return 0; fi
  if [ -n "$O_DIALOG" ] || [ "$O_COMPOSER" != empty ]; then
    wd_rec "$id" "$symptom" nudge held "composer is $O_COMPOSER${O_DIALOG:+, dialog $O_DIALOG}; nothing typed"
    return 0
  fi
  wd_rec "$id" "$symptom" nudge pending "$body"
  doorbell=$(printf '%s\n' "$body" | FM_HOME=$O_HOME "$SCRIPT_DIR/fm-operational-input.sh" record watcher 2>/dev/null) || {
    wd_rec "$id" "$symptom" nudge failed "operational input record failed"; return 0; }
  verdict=$(fm_run_timed_fn 30 fm_backend_send_text_submit "$O_BACKEND" "$O_TARGET" "$doorbell" 2 0.5 1 2>/dev/null) || {
    wd_rec "$id" "$symptom" nudge failed "doorbell submit failed (${verdict:-no verdict})"; return 0; }
}

# wd_key <symptom> <key-or-digit> <why>: one key, then verify its effect; returns 0
# only when the key changed the pane. A dialog that left refreshes the observation.
wd_key() {
  local symptom=$1 key=$2 why=$3 id after
  wd_rate_open "$symptom" key "$(cfgi key-secs 120)" || return 1
  id=$(wd_id)
  # Two keys that did not clear a dialog within the hour stop the presses, so a
  # misread screen never keeps typing into the session.
  if [ "$symptom" = dialog ] && [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" dialog key '^failed$' "$(( $(wd_now) - 3600 ))")" -ge 2 ]; then
    wd_gap "a $O_DIALOG dialog did not clear after two keys this hour; no more keys pressed"
    return 1
  fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" key refused "endpoint is on do-not-touch"; return 1; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" key dry-run "would press $key: $why"; return 1; fi
  wd_rec "$id" "$symptom" key pending "press $key: $why"
  case "$O_BACKEND:$key" in
    orca:[0-9]) fm_run_timed 10 orca terminal send --terminal "$O_TARGET" --text "$key" --json >/dev/null 2>&1 ;;
    tmux:[0-9]) fm_run_timed 10 tmux send-keys -t "$O_TARGET" -l "$key" >/dev/null 2>&1 ;;
    *) fm_run_timed_fn 10 fm_backend_send_key "$O_BACKEND" "$O_TARGET" "$key" >/dev/null 2>&1 ;;
  esac || { wd_rec "$id" "$symptom" key failed "key delivery failed"; return 1; }
  sleep "$(cfgi key-settle-secs 2)"
  case "$symptom" in
    dialog) after=$(wd_view "$O_BACKEND" "$O_TARGET") ;;
    *) after=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) ;;
  esac
  case "$symptom" in
    dialog) if [ -n "$after" ] && ! fm_wd_pane_dialog "$after" >/dev/null; then wd_rec "$id" "$symptom" key "done" "dialog left the pane"; O_DIALOG='' O_PANE=$after; wd_read_composer; else wd_rec "$id" "$symptom" key failed "dialog still showing"; return 1; fi ;;
    *) if [ -n "$after" ] && [ "$(wd_pane_sig "$after")" != "$O_SIG" ]; then wd_rec "$id" "$symptom" key "done" "pane changed"; else wd_rec "$id" "$symptom" key failed "pane unchanged"; return 1; fi ;;
  esac
}

wd_gap() {  # <text>
  printf '%s\n' "- $O_TAG: $1" >> "$WD_GAPS"
}

# --- cheap model judge ---------------------------------------------------------

wd_judge_one() {  # <model> <purpose> <answer-ere> <prompt>  -> prints the answer
  local model=$1 purpose=$2 re=$3 prompt=$4 h m out ans cost='' tin='' tout='' rc=0 spent cap scratch acct
  h=${model%%:*} m=${model#*:}
  spent=$(fm_wd_spent_since "$CALLS" "$(( $(wd_now) - 86400 ))")
  cap=$(cfg daily-max-usd 1.00)
  if awk -v s="$spent" -v c="$cap" 'BEGIN { exit !(s >= c) }'; then
    printf '%s\t%s\t%s\tcap-reached\t\t\t\t\n' "$(wd_now)" "$purpose" "$model" >> "$CALLS"
    return 3
  fi
  scratch=$WD/judge-scratch
  mkdir -p "$scratch"
  prompt=$(printf '%s' "$prompt" | cut -c1-"$(cfgi judge-max-chars 6000)")
  case "$h" in
    claude)
      command -v claude >/dev/null 2>&1 || return 4
      acct=$(cfg claude-config-dir "$(head -n 1 "$OWNER_HOME/config/claude-account" 2>/dev/null)")
      # The timed runner detaches stdin, so the prompt reaches claude through a
      # redirect inside the timed command rather than a pipe into the runner.
      printf '%s' "$prompt" > "$scratch/prompt.txt"
      # shellcheck disable=SC2016  # Expanded by the timed child shell.
      out=$( (cd "$scratch" && CLAUDE_CONFIG_DIR=${acct:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}} \
        fm_run_timed "$(cfgi judge-timeout-secs 120)" bash -c 'f=$1; shift; exec "$@" < "$f"' _ "$scratch/prompt.txt" \
        claude -p --model "$m" --output-format json --tools "" \
        --setting-sources "" --strict-mcp-config --no-session-persistence --max-budget-usd "$(cfg judge-call-max-usd 0.05)") 2>/dev/null) || rc=$?
      ans=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)
      cost=$(printf '%s' "$out" | jq -r '.total_cost_usd // empty' 2>/dev/null)
      tin=$(printf '%s' "$out" | jq -r '.usage.input_tokens // empty' 2>/dev/null)
      tout=$(printf '%s' "$out" | jq -r '.usage.output_tokens // empty' 2>/dev/null) ;;
    agy)
      command -v agy >/dev/null 2>&1 || return 4
      out=$( (cd "$scratch" && fm_run_timed "$(cfgi judge-timeout-secs 120)" agy -p "$prompt" --model "$m" --output-format json \
        --disable-slash-commands --print-timeout "$(cfgi judge-timeout-secs 120)s") 2>/dev/null) || rc=$?
      ans=$(printf '%s' "$out" | jq -r '.response // empty' 2>/dev/null)
      tin=$(printf '%s' "$out" | jq -r '.usage.input_tokens // empty' 2>/dev/null)
      tout=$(printf '%s' "$out" | jq -r '.usage.output_tokens // empty' 2>/dev/null)
      cost=unmetered ;;
    *) return 4 ;;
  esac
  ans=$(printf '%s\n' "$ans" | sed -e 's/^[[:blank:]`*]*//' -e 's/[[:blank:]`*.]*$//' | LC_ALL=C grep -Ex "$re" | head -n 1)
  if [ "$rc" -eq 0 ] && [ -n "$ans" ]; then
    printf '%s\t%s\t%s\tok\t%s\t%s\t%s\t%s\n' "$(wd_now)" "$purpose" "$model" "$tin" "$tout" "$(printf '%s' "$ans" | tr '\t' ' ')" "$cost" >> "$CALLS"
    printf '%s\n' "$ans"
    return 0
  fi
  printf '%s\t%s\t%s\tfailed rc=%s\t%s\t%s\t\t%s\n' "$(wd_now)" "$purpose" "$model" "$rc" "$tin" "$tout" "$cost" >> "$CALLS"
  return 1
}

wd_models() { cfg models "claude:haiku,agy:gemini-3.8-flash-low" | tr ',' '\n' | sed '/^$/d'; }

# wd_judge <purpose> <answer-ere> <prompt>: the first model in order that answers.
wd_judge() {
  local model
  mkdir -p "$WD"
  for model in $(wd_models); do
    wd_judge_one "$model" "$1" "$2" "$3" && return 0
    [ $? -ne 3 ] || return 3
  done
  return 1
}

# --- council -------------------------------------------------------------------

# wd_council <task> <key> <summary>: blind seats; a unanimous PROCEED writes a ruling.
wd_council() {
  local task=$1 key=$2 summary=$3 seats seat i=0 tmp answers='' first='' unanimous=1 ruling prompt
  seats=$(cfg council-seats "$(wd_models | tr '\n' ',')")
  tmp=$(mktemp -d "$WD/council.XXXXXX") || return 1
  prompt="You are one blind seat on a council for an autonomous software team. The owner is away. A worker parked this decision:
task: $task
key: $key
record: $summary
If the record names a merge, release, deploy, money, credentials, security, production data, or deletion, or says the owner reserved it, answer HOLD.
If the record offers options and one is clearly recommended or clearly safest for continuing work, answer PROCEED followed by that option's label (for example PROCEED A or PROCEED 2).
Otherwise answer HOLD.
Reply with exactly one line: PROCEED <label> or HOLD."
  for seat in $(printf '%s' "$seats" | tr ',' ' '); do
    i=$((i + 1))
    ( wd_judge_one "$seat" council '(PROCEED [A-Za-z0-9]{1,3}|HOLD)' "$prompt" > "$tmp/$i" 2>/dev/null || printf 'FAILED\n' > "$tmp/$i" ) &
  done
  wait
  [ "$i" -ge 2 ] || unanimous=0
  for seat in $(seq 1 "$i"); do
    a=$(head -n 1 "$tmp/$seat" 2>/dev/null)
    answers="$answers seat$seat=${a:-FAILED}"
    case "$a" in PROCEED*) ;; *) unanimous=0 ;; esac
    if [ -z "$first" ]; then first=$a; elif [ "$a" != "$first" ]; then unanimous=0; fi
  done
  rm -rf "$tmp"
  if [ "$unanimous" = 1 ]; then
    mkdir -p "$OUT/rulings"
    ruling=$OUT/rulings/$O_KEY-$task-$key.md
    {
      printf '# Watchdog council ruling\n\n'
      printf -- '- home: %s\n- task: %s\n- key: %s\n- ruling: %s (unanimous, %s blind seats)\n- seats:%s\n- at: %s\n\n' \
        "$O_HOME" "$task" "$key" "$first" "$i" "$answers" "$(fm_wd_iso "$(wd_now)")"
      printf 'Record:\n\n%s\n' "$summary"
    } > "$ruling"
    printf 'unanimous\t%s\t%s\t%s\n' "$first" "$ruling" "$answers"
  else
    printf 'no-ruling\t\t\t%s\n' "$answers"
  fi
}

# --- restart -------------------------------------------------------------------

wd_restart_gate() {  # <symptom> <kind>...  -> 0 to proceed; records the refusal otherwise
  local symptom=$1 id now count last
  shift
  id=$(wd_id) now=$(wd_now)
  wd_rate_open "$symptom" restart "$(cfgi restart-secs 7200)" || return 1
  if [ -f "$WD/escalated/$O_KEY" ]; then wd_gap "RESTART LOOP escalated; clear $WD/escalated/$O_KEY after review"; return 1; fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" restart refused "endpoint is on do-not-touch"; return 1; fi
  if ! fm_wd_stall_proof "$O_TURN" "$O_CPU_BUSY" "$@"; then
    wd_gap "$symptom: restart not proven (turn_running=$O_TURN cpu_busy=$O_CPU_BUSY signals=$*)"
    return 1
  fi
  count=$(fm_wd_count_since "$LEDGER" "$O_HOME" '*' restart '^pending$' "$((now - 86400))")
  last=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  if [ "$count" -ge "$(cfgi max-restarts 2)" ]; then
    mkdir -p "$WD/escalated"
    printf '%s\n' "$now" > "$WD/escalated/$O_KEY"
    wd_rec "$id" "$symptom" restart escalated "restart loop: $count restarts in 24h"
    wd_self_heal "restart-loop" "Watchdog restart loop for $O_TAG" "symptom $symptom recurred after $count restarts in 24h"
    return 1
  fi
  if [ -n "$last" ] && [ $((now - last)) -lt "$(cfgi restart-secs 7200)" ]; then
    wd_gap "$symptom: restart held; last restart was $(((now - last) / 60))m ago"
    return 1
  fi
  if [ "$(cfg restart off)" != on ]; then wd_rec "$id" "$symptom" restart refused "restart is off; stall proven by $*"; return 1; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" restart dry-run "would restart; stall proven by $*"; return 1; fi
  return 0
}

wd_restart_available() {
  local last
  if [ "$(cfg restart off)" != on ]; then wd_gap "restart requested or context low, but restart is off; no handoff is asked for"; return 1; fi
  if [ -f "$WD/escalated/$O_KEY" ]; then wd_gap "restart requested or context low, but restarts are escalated; no handoff is asked for"; return 1; fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_gap "restart requested or context low, but this endpoint is on do-not-touch; no handoff is asked for"; return 1; fi
  if [ "$O_TR_AGE" = unknown ]; then wd_gap "restart requested or context low, but no activity source can prove quiet; no handoff is asked for"; return 1; fi
  if [ "$O_PARENT" = - ]; then
    if [ -z "$(cfg restart-command "")" ]; then wd_gap "restart requested or context low, but no restart-command is set; no handoff is asked for"; return 1; fi
    case "$O_BACKEND" in orca|tmux) ;; *) wd_gap "restart requested or context low, but backend ${O_BACKEND:-none} has no restart launcher; no handoff is asked for"; return 1 ;; esac
    if [ -z "$O_LOCK_PID" ]; then wd_gap "restart requested or context low, but no lock holder is recorded; no handoff is asked for"; return 1; fi
    if [ "$O_ALIVE" = 1 ] && [ "$O_INSTANCE" != match ]; then wd_gap "restart requested or context low, but the lock anchor does not match; no handoff is asked for"; return 1; fi
  fi
  last=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  if [ -n "$last" ] && [ $(($(wd_now) - last)) -lt "$(cfgi restart-secs 7200)" ]; then
    wd_gap "restart held; last restart was $((($(wd_now) - last) / 60))m ago, so no handoff is asked for"
    return 1
  fi
}

wd_newest_session_handoff() {
  # shellcheck disable=SC2012  # newest-first by mtime; handoff names are firstmate-written
  ls -t "$O_HOME"/data/handoff-*.md 2>/dev/null | head -n 1
}

wd_write_handoff() {  # <symptom> -> prints path
  local symptom=$1 path latest draft='' lost=0 unseen=0
  local note='Unsent draft at restart, never submitted. Treat it as a note and do not act on it without review:'
  mkdir -p "$OUT/handoffs"
  path=$OUT/handoffs/$O_KEY-$(wd_now).md
  latest=$(wd_newest_session_handoff)
  if [ "$O_COMPOSER" != empty ]; then
    if [ "$O_COMPOSER" != unknown ] && fm_wd_paste_placeholder "$O_COMPOSER_TEXT"; then lost=1
    elif [ -n "$O_DRAFT" ]; then
      draft=$O_DRAFT
      note='Composer field at restart, never submitted. It may be an unsent draft or a harness suggestion. Treat it as a note and do not act on it without review:'
    elif [ "$O_COMPOSER" = pending ] && [ -n "$(printf '%s' "$O_COMPOSER_TEXT" | tr -d '[:space:]')" ]; then
      if fm_wd_draft_readable "$O_COMPOSER_TEXT" "$O_COMPOSER_ABOVE"; then draft=$(fm_wd_draft_rows "$O_COMPOSER_TEXT"); else lost=1; fi
    else
      unseen=1
    fi
  fi
  [ "$lost" = 0 ] || wd_gap "$symptom restart lost an unreadable draft (composer $O_COMPOSER); the handoff records the gap"
  {
    printf '# Watchdog restart handoff - %s\n\n' "$O_TAG"
    printf -- '- home: %s\n- reason: %s\n- at: %s\n- newest session handoff: %s\n' "$O_HOME" "$symptom" "$(fm_wd_iso "$(wd_now)")" "${latest:-none}"
    printf -- '- owed input: %s rows, oldest %ss\n- away mode: %s\n\n' "$O_OWED_N" "$O_OWED_AGE" "$O_AFK"
    printf 'Start with the newest session handoff above when it exists, then run the session-start contract.\n\n'
    [ "$lost" = 0 ] ||
      printf 'GAP: an unsent draft could not be read in full (composer %s), and its hidden text is lost with this restart.\n\n' "$O_COMPOSER"
    [ "$unseen" = 0 ] ||
      printf 'Composer state was unknown at restart (read as %s), and no draft was seen.\n\n' "$O_COMPOSER"
    # shellcheck disable=SC2016  # literal Markdown fences
    [ -z "$draft" ] ||
      printf '%s\n\n```\n%s\n```\n\n' "$note" "$draft"
    # shellcheck disable=SC2016  # literal Markdown fences
    printf 'Pane tail at restart:\n\n```\n%s\n```\n' "$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | tail -n 40)"
  } > "$path"
  printf '%s\n' "$path"
}

wd_restart() {  # <symptom> <kind>...
  local symptom=$1 id handoff token cmd prompt pid i sess
  shift
  wd_restart_gate "$symptom" "$@" || return 0
  id=$(wd_id)
  handoff=$(wd_write_handoff "$symptom")
  if [ "$O_PARENT" != - ]; then
    wd_rec "$id" "$symptom" restart pending "second mate relaunch through its parent; handoff=$handoff"
    WD_RESTARTED=1
    if FM_HOME=$O_PARENT fm_run_timed "$(cfgi relaunch-timeout-secs 900)" "$SCRIPT_DIR/fm-control.sh" "$O_ID" relaunch --note-file "$handoff" >/dev/null 2>&1; then
      wd_rec "$id" "$symptom" restart "done" "relaunched through fm-control"
    else
      wd_rec "$id" "$symptom" restart failed "fm-control relaunch refused or failed"
      wd_self_heal "$symptom" "Watchdog could not relaunch $O_TAG" "fm-control relaunch failed after $symptom"
    fi
    return 0
  fi
  cmd=$(cfg restart-command "")
  if [ -z "$cmd" ]; then wd_rec "$id" "$symptom" restart refused "no restart-command configured"; return 0; fi
  case "$O_BACKEND" in orca|tmux) ;; *) wd_rec "$id" "$symptom" restart refused "no restart launcher for backend $O_BACKEND"; return 0 ;; esac
  if [ -z "$O_LOCK_PID" ]; then wd_rec "$id" "$symptom" restart refused "no lock holder recorded"; return 0; fi
  if [ "$O_ALIVE" = 1 ] && [ "$O_INSTANCE" != match ]; then wd_rec "$id" "$symptom" restart refused "lock anchor does not match its recorded instance"; return 0; fi
  if [ "$O_BACKEND" = tmux ]; then
    sess=$(fm_run_timed 10 tmux display-message -p -t "$O_TARGET" '#{session_name}' 2>/dev/null) || sess=''
    sess=${sess:-firstmate-$O_TAG}
  fi
  token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  pid=$O_LOCK_PID
  wd_rec "$id" "$symptom" restart pending "token=$token old_pid=$pid handoff=$handoff"
  WD_RESTARTED=1
  if [ "$O_ALIVE" = 1 ]; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while wd_pid_alive "$pid" && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
    if wd_pid_alive "$pid"; then
      wd_rec "$id" "$symptom" restart failed "old session pid $pid did not stop on TERM; left running"
      return 0
    fi
  fi
  prompt="Watchdog restart of this firstmate home. Read $handoff first, then take over as the session-start contract says. After you hold the session lock, run: FM_HOME=$O_HOME $SCRIPT_DIR/fm-watchdog.sh pickup $token"
  case "$O_BACKEND" in
    orca) fm_run_timed 60 orca terminal create --worktree "path:$O_HOME" --title "firstmate captain" --command "$cmd $(printf '%q' "$prompt")" --json >/dev/null 2>&1 ;;
    tmux)
      if fm_run_timed 10 tmux has-session -t "=$sess" >/dev/null 2>&1; then
        fm_run_timed 30 tmux new-window -d -t "=$sess:" -c "$O_HOME" -n firstmate "$cmd $(printf '%q' "$prompt")" >/dev/null 2>&1
      else
        fm_run_timed 30 tmux new-session -d -s "$sess" -c "$O_HOME" -n firstmate "$cmd $(printf '%q' "$prompt")" >/dev/null 2>&1
      fi ;;
  esac || { wd_rec "$id" "$symptom" restart failed "new terminal launch failed"; return 0; }
}

# Close each pending row once: nudges by transcript or pane progress, restarts by pickup.
wd_reconcile_pending() {
  local now id home symptom action at tag tok old pick lockpid tr st
  now=$(wd_now)
  fm_wd_open_pending "$LEDGER" | while IFS=$'\t' read -r id home symptom action at; do
    tag=$(wd_tag "$home")
    st=$home/state
    case "$action" in
      nudge)
        tr=$(wd_transcript "$home" "$(fm_session_lock_recorded_session_id "$st" 2>/dev/null)") || tr=''
        if [ -n "$tr" ] && [ "$(wd_mtime "$tr")" -gt "$at" ]; then
          FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" nudge "done" "transcript advanced"
        elif [ $((now - at)) -ge "$(cfgi pickup-secs 600)" ]; then
          if [ -z "$tr" ]; then
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" nudge "done" "delivered; no transcript to confirm"
          else
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" nudge failed "no transcript progress"
          fi
        fi ;;
      restart)
        tok=$(awk -F'\t' -v i="$id" '$2 == i && $7 == "pending" { print $8 }' "$LEDGER" | sed -n 's/.*token=\([0-9a-f]*\).*/\1/p' | tail -n 1)
        old=$(awk -F'\t' -v i="$id" '$2 == i && $7 == "pending" { print $8 }' "$LEDGER" | sed -n 's/.*old_pid=\([0-9]*\).*/\1/p' | tail -n 1)
        if [ -z "$tok" ]; then
          [ $((now - at)) -ge "$(cfgi relaunch-timeout-secs 900)" ] && FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart failed "relaunch recorded no outcome"
          continue
        fi
        pick=$st/watchdog/pickups/$tok
        lockpid=$(head -n 1 "$st/.lock" 2>/dev/null | tr -cd '0-9')
        if [ -f "$pick" ] && [ -n "$lockpid" ] && [ "$lockpid" != "$old" ] && wd_pid_alive "$lockpid"; then
          if [ -f "$st/.afk" ] && ! kill -0 "$(head -n 1 "$st/.supervise-daemon.pid" 2>/dev/null | tr -cd '0-9')" 2>/dev/null; then
            [ $((now - at)) -lt "$(cfgi pickup-secs 600)" ] && continue
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart failed "picked up but the away daemon is not running"
          else
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart "done" "pickup verified; new lock pid $lockpid"
          fi
        elif [ $((now - at)) -ge "$(cfgi pickup-secs 600)" ]; then
          FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart failed "no verified pickup within the window"
          O_TAG=$tag O_HOME=$home wd_self_heal "$symptom" "Watchdog restart of $tag was not picked up" "restart token $tok had no verified pickup"
        fi ;;
      *)
        [ $((now - at)) -ge 3600 ] && FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" "$action" failed "no outcome recorded" ;;
    esac
  done
}

# --- self-heal issue -------------------------------------------------------------

wd_self_heal() {  # <class> <title> <evidence>
  local class="watchdog-$1" id repo
  id=$(wd_id)
  repo=$(cfg issue-repo "")
  if [ -z "$repo" ]; then wd_gap "self-heal issue not filed for $class: no issue-repo configured"; return 0; fi
  [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" "$class" self-heal '^(pending|dry-run)$' "$(( $(wd_now) - 86400 ))")" -eq 0 ] || return 0
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$class" self-heal dry-run "would file: $2"; return 0; fi
  wd_rec "$id" "$class" self-heal pending "$2"
  if out=$(FM_HOME=$OWNER_HOME fm_run_timed 120 "$SCRIPT_DIR/fm-self-heal-issue.sh" --repo "$repo" \
      --failure-class "$class" --title "$2" --evidence "$3" --instance-fix "watchdog action ladder on $O_TAG" 2>&1); then
    wd_rec "$id" "$class" self-heal "done" "$out"
  else
    wd_rec "$id" "$class" self-heal failed "$(printf '%s' "$out" | tail -n 1)"
  fi
}

# --- the ladder ------------------------------------------------------------------

wd_ladder_nudge_then_restart() {  # <symptom> <nudge-body> <kind>...
  local symptom=$1 body=$2 nudges
  shift 2
  if wd_unsent_is_stable; then wd_submit_unsent && return 0; fi
  nudges=$(fm_wd_count_since "$LEDGER" "$O_HOME" "$symptom" nudge '^(pending|dry-run|held)$' "$(( $(wd_now) - 7200 ))")
  if [ "$nudges" -lt "$(cfgi max-nudges 2)" ]; then
    wd_nudge "$symptom" "$body"
  else
    wd_restart "$symptom" "$@"
  fi
}

wd_handle_dialog() {
  local opts pick n text
  case "$O_DIALOG" in
    feedback) wd_key dialog 0 "dismiss the feedback survey" ;;
    permission) wd_gap "permission dialog waiting; the watchdog never answers permission prompts" ;;
    model-switch)
      opts=$(fm_wd_dialog_options "$O_PANE")
      text=$(fm_wd_dialog_text "$O_PANE")
      if fm_wd_reserved "$text"; then wd_gap "model-switch dialog names an owner-reserved category; held"; return 0; fi
      pick=$(wd_judge dialog '(OPTION [0-9]{1,2}|NONE)' "A coding agent's terminal shows this dialog about models or usage limits:
$text
Options:
$opts
Pick the option that keeps work going on another model or account without buying credits, signing in, or spending money. Reply with exactly one line: OPTION <number> or NONE.") || {
        wd_gap "model-switch dialog waiting; no model available to pick an option"; return 0; }
      n=${pick#OPTION }
      case "$pick" in OPTION*) ;; *) wd_gap "model-switch dialog: judge picked none"; return 0 ;; esac
      text=$(printf '%s\n' "$opts" | awk -F'\t' -v n="$n" '$1 == n { print $2 }')
      if [ -z "$text" ] || fm_wd_reserved "$text" || ! fm_wd_text_allowed "$text" || printf '%s' "$text" | grep -Eiq 'buy|purchase|upgrade|credit'; then
        wd_rec "$(wd_id)" dialog key refused "option $n (${text:-unknown}) is reserved or spends money"
        return 0
      fi
      wd_key dialog "$n" "model-switch option $n: $text" ;;
    question) wd_gap "question dialog waiting; its kind is not proven, so no key is sent" ;;
  esac
}

# Aged open decisions get one rolled-up nudge per window; once that nudge has
# had a full window, the oldest decision without a recent council gets one.
wd_handle_decisions() {
  local st=$O_HOME/state now task key verb age summary secs res aged=0 keys='' id cap ran=0 nudged held=0 held_keys=''

  now=$(wd_now)
  secs=$(cfgi decision-secs 1800)
  cap=$(cfgi council-per-pass 1)
  wd_open_decisions "$st" "$now" 2>/dev/null | sort -t "$(printf '\t')" -k4,4nr > "$WD/.decisions"
  : > "$WD/.decisions-aged"
  while IFS=$'\t' read -r task key verb age summary; do
    [ -n "$key" ] || continue
    [ "$age" -ge "$secs" ] || continue
    if case "$key" in captain-hold-*) true ;; *) false ;; esac || fm_wd_reserved "$task $key $summary" ||
       printf ',%s,' "$(cfg reserved-keys '')" | grep -Fq ",$key,"; then
      held=$((held + 1))
      [ "$held" -gt 3 ] || held_keys="$held_keys${held_keys:+, }$task/$key"
      continue
    fi
    aged=$((aged + 1))
    [ "$aged" -gt 5 ] || keys="$keys${keys:+, }$task/$key"
    printf '%s\t%s\t%s\n' "$task" "$key" "$summary" >> "$WD/.decisions-aged"
  done < "$WD/.decisions"
  [ "$held" -eq 0 ] || wd_gap "$held decisions held for the owner (never touched), e.g. $held_keys"
  [ "$aged" -gt 0 ] || return 0
  [ "$O_TURN" = 1 ] && return 0
  nudged=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" decisions nudge '^(pending|dry-run)$')
  if [ -z "$nudged" ] || [ $((now - nudged)) -ge $((3 * secs)) ]; then
    wd_nudge decisions "$aged open decisions have waited over $((secs / 60)) minutes, oldest first: $keys. Answer each, or settle it by council per the captain rules, and record the answer with fm-send --resolve-key."
    return 0
  fi
  [ $((now - nudged)) -ge "$secs" ] || return 0
  while IFS=$'\t' read -r task key summary; do
    [ "$ran" -lt "$cap" ] || break
    fm_wd_rate_ok "$LEDGER" "$O_HOME" "decision:$key" council "$(cfgi council-secs 21600)" "$now" || continue
    ran=$((ran + 1))
    id=$(wd_id)
    if [ "$(wd_mode)" != act ]; then wd_rec "$id" "decision:$key" council dry-run "would convene council on $task $key"; continue; fi
    wd_rec "$id" "decision:$key" council pending "$task $key"
    res=$(wd_council "$task" "$key" "$summary")
    case "$res" in
      unanimous*)
        wd_rec "$id" "decision:$key" council "done" "$(printf '%s' "$res" | cut -f2,4)"
        wd_nudge "ruling:$key" "a unanimous blind council ruled $(printf '%s' "$res" | cut -f2) on decision $key from $task. Ruling file: $(printf '%s' "$res" | cut -f3). Apply it with fm-send --resolve-key if it stands, or record why not." ;;
      *) wd_rec "$id" "decision:$key" council "done" "no ruling;$(printf '%s' "$res" | cut -f4)"; wd_gap "council gave no ruling on $task $key; held" ;;
    esac
  done < "$WD/.decisions-aged"
}

wd_handle_quota() {
  local task age line cands cand snapshot pick
  wd_quota_floors "$O_HOME/state" "$(wd_now)" | while IFS=$'\t' read -r task age line; do
    [ "$age" -ge "$(cfgi quota-secs 600)" ] || continue
    cands=$(cfg reroute-candidates "")
    pick=''
    if [ -n "$cands" ] && command -v quota-axi >/dev/null 2>&1; then
      snapshot=$WD/quota-snapshot.txt
      fm_run_timed 60 quota-axi > "$snapshot" 2>/dev/null || true
      set --
      for cand in $(printf '%s' "$cands" | tr ',' ' '); do set -- "$@" --candidate "$cand"; done
      pick=$("$SCRIPT_DIR/fm-quota-choose.sh" --snapshot "$snapshot" "$@" 2>/dev/null) || pick=''
    fi
    if [ -n "$pick" ] && [ "$pick" != none ]; then
      wd_nudge "quota:$task" "task $task is parked at a quota floor. Reroute it now; quota shows $pick eligible. Never pause or poll for quota."
    else
      wd_nudge "quota:$task" "task $task is parked at a quota floor. Reroute it to another provider or account through quota-array-dispatch; never pause or poll for quota."
    fi
  done
}

wd_unsent_is_stable() {
  [ "$O_COMPOSER" = pending ] && [ "$O_PREV_COMPOSER" = pending ] && [ "$O_SIG" = "$O_PREV_SIG" ] && [ "$O_TURN" = 0 ]
}

wd_enter_spent() {
  [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" pasted-input key '^pending$' "$(( $(wd_now) - 7200 ))")" -gt 0 ]
}

# One Enter per two hours, only for a whole, readable draft that names no merge,
# deploy, or release word; returns 1 when this draft cannot take Enter now.
wd_draft_allowed() {
  fm_wd_text_allowed "$(fm_wd_prompt_tail "$O_COMPOSER_TEXT")"
}

wd_submit_unsent() {
  if ! wd_draft_allowed; then
    wd_gap "unsent draft names a merge, deploy, or release word; Enter not pressed"
    wd_rate_open pasted-input key "$(cfgi enter-secs 300)" &&
      wd_rec "$(wd_id)" pasted-input key refused "the draft names a merge, deploy, or release word; never accepted"
    return 1
  elif ! fm_wd_draft_readable "$O_COMPOSER_TEXT" "$O_COMPOSER_ABOVE"; then
    wd_gap "unsent input is a paste placeholder, or its whole draft boundary is not proven (plain, indented, left-bar, and titled composers are unsupported); Enter not pressed"
    wd_rate_open pasted-input key "$(cfgi enter-secs 300)" &&
      wd_rec "$(wd_id)" pasted-input key refused "the whole draft cannot be read; never accepted"
    return 1
  elif wd_enter_spent; then
    wd_gap "unsent input is still there after Enter; no second Enter inside two hours"
    return 1
  fi
  wd_rate_open pasted-input key "$(cfgi enter-secs 300)" && wd_key pasted-input Enter "submit text left unsent"
  return 0
}

# A low-context ask with no delivered nudge that no later pass can deliver either.
wd_handoff_undeliverable() {
  [ "$O_RESTART_REQ" != 1 ] && [ -z "$(wd_handoff_nudge_epoch)" ] || return 1
  case "$O_COMPOSER" in
    empty) return 1 ;;
    pending) fm_wd_draft_readable "$O_COMPOSER_TEXT" "$O_COMPOSER_ABOVE" && wd_draft_allowed && ! wd_enter_spent && return 1 ;;
  esac
  wd_gap "low context, but composer is $O_COMPOSER, so the handoff nudge cannot be delivered"
  return 0
}

# Prints the epoch of the handoff nudge that counts for this low-context episode:
# delivered, newer than the last restart, and younger than twice handoff-wait-secs.
wd_handoff_nudge_epoch() {
  local e last_r
  e=$(awk -F'\t' -v h="$O_HOME" '$3 == h && $5 == "handoff-request" && $6 == "nudge" {
      if ($7 ~ /^(pending|dry-run)$/) { id = $2; e = $1 }
      else if ($7 == "failed" && $2 == id && $8 !~ /no transcript progress/) e = ""
    } END { print e }' "$LEDGER" 2>/dev/null)
  last_r=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  [ -n "$e" ] && [ "$e" -ge "${last_r:-0}" ] && [ $(($(wd_now) - e)) -lt $((2 * $(cfgi handoff-wait-secs 600))) ] && printf '%s\n' "$e"
  return 0
}

# Low context first asks for a full handoff and a request file; a nudge that gets
# neither within handoff-wait-secs falls back to the lean handoff.
wd_requested_restart() {  # <quiet-secs>
  local quiet=$1 now nudged wait latest timed_out
  now=$(wd_now)
  wait=$(cfgi handoff-wait-secs 600)
  nudged=$(wd_handoff_nudge_epoch)
  if [ -z "$nudged" ] && [ "$O_RESTART_REQ" != 1 ]; then
    if wd_unsent_is_stable; then wd_submit_unsent; return 0; fi
    wd_nudge handoff-request "context is low. Write a full handoff to data/handoff-<name>.md in your home, then create state/.watchdog-restart-request there. The watchdog then restarts this session, and the new session picks up from that handoff."
    [ -n "$(wd_handoff_nudge_epoch)" ] || wd_gap "low context; the handoff nudge was not delivered; no restart yet"
    return 0
  fi
  if [ -n "$nudged" ]; then
    latest=$(wd_newest_session_handoff)
    if [ "$O_RESTART_REQ" != 1 ] || [ -z "$latest" ] || [ "$(wd_mtime "$latest")" -le "$nudged" ]; then
      if [ $((now - nudged)) -lt "$wait" ]; then
        wd_gap "low context; waiting up to ${wait}s for a full handoff and a restart request"
        return 0
      fi
      timed_out=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" handoff-request nudge '^timed-out$')
      [ "${timed_out:-0}" -ge "$nudged" ] || wd_rec "$(wd_id)" handoff-request nudge timed-out "no full handoff and request within ${wait}s"
      wd_gap "no full handoff within ${wait}s; the restart uses the lean handoff"
    fi
  fi
  if [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -ge "$quiet" ]; then
    wd_restart restart-requested filesystem records
  else
    wd_gap "restart requested; waiting for ${quiet}s of quiet"
  fi
}

# wd_handle_subject: one symptom per pass, by precedence, then the side checks.
wd_handle_subject() {
  local symptom='' quiet frozen owed dead=0
  if fm_wd_open_pending "$LEDGER" | awk -F'\t' -v h="$O_HOME" '$2 == h && $4 == "restart" { f = 1 } END { exit !f }'; then
    WD_SYMPTOM=restart-awaiting-pickup
    return 0
  fi
  frozen=$(cfgi frozen-secs 900)
  owed=$(cfgi owed-input-secs 900)
  quiet=$(cfgi restart-quiet-secs 120)
  if [ -n "$O_LOCK_PID" ] && [ "$O_ALIVE" = 0 ]; then dead=1; fi
  if [ "$dead" = 1 ]; then
    symptom=agent-gone
    if [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -ge "$frozen" ]; then
      O_TURN=0 O_CPU_BUSY=0 wd_restart agent-gone kernel filesystem
    else
      wd_gap "lock holder is dead; restart needs ${frozen}s of transcript quiet; nothing typed"
    fi
  elif [ -n "$O_DIALOG" ]; then
    symptom=dialog
    wd_handle_dialog
  elif { [ "$O_RESTART_REQ" = 1 ] || { [ -n "$O_CTX" ] && [ "$O_CTX" -le "$(cfgi restart-at-percent 8)" ]; }; } && wd_restart_available && ! wd_handoff_undeliverable; then
    symptom=restart-requested
    wd_requested_restart "$quiet"
  elif [ "$O_LOOP" = rapid ] || { [ "$O_LOOP" = loop ] && [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ]; }; then
    symptom=timer-loop
    wd_ladder_nudge_then_restart timer-loop "your last $O_LOOP_N replies repeat the same text with no work between them, and input is waiting. Stop re-arming, drain the wake queue, and act on what it shows." filesystem records
  elif [ "$O_LOOP" = near ] && [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ]; then
    local v
    if v=$(wd_judge loop '(LOOP|WORK)' "Recent assistant messages from a supervisor agent, newest last. Does it repeat itself without doing new work (LOOP), or is it doing real work (WORK)? Reply with exactly one word.
$(printf '%s\n' "$O_LOOP_SAMPLE")"); then
      [ "$v" = LOOP ] && { symptom=timer-loop; wd_ladder_nudge_then_restart timer-loop "your recent replies repeat without new work while input waits. Stop re-arming, drain the wake queue, and act on it." filesystem records; }
    else
      wd_gap "possible loop; no model available to judge it"
    fi
  elif [ "$O_PANE_STATIC" -ge "$frozen" ] && [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -ge "$frozen" ] \
       && [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$frozen" ]; then
    symptom=frozen
    if [ "$O_TURN" = 1 ]; then
      wd_gap "pane and transcript static $((O_PANE_STATIC / 60))m during a running turn; treated as busy"
    else
      wd_ladder_nudge_then_restart frozen "nothing changed for $((O_PANE_STATIC / 60)) minutes while $O_OWED_N inputs wait. Drain the wake queue and act on it." rendered filesystem kernel
    fi
  elif wd_unsent_is_stable; then
    symptom=pasted-input
    wd_submit_unsent
  elif [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ] && [ "$O_TURN" != 1 ]; then
    symptom=unread-input
    wd_nudge unread-input "$O_OWED_N inputs have waited $((O_OWED_AGE / 60)) minutes. Drain the wake queue and act on it."
  fi
  # A restart this pass stopped the recorded session, so its old endpoint gets nothing more.
  if [ "$WD_RESTARTED" = 1 ]; then WD_SYMPTOM=$symptom; return 0; fi
  if [ "$dead" = 0 ] && [ "$O_AFK" = 1 ] && [ "$O_DAEMON" = 0 ]; then
    [ -n "$symptom" ] || symptom=daemon-dead
    wd_nudge daemon-dead "away mode is on but the away daemon is not running. Re-arm it with bin/fm-afk-start.sh on this session's own terminal."
  fi
  if [ "$O_HB_AGE" != unknown ] && [ "$O_HB_AGE" -ge "$(cfgi watcher-stale-secs 900)" ]; then
    wd_gap "watcher heartbeat is $((O_HB_AGE / 60))m old"
  fi
  if [ "$dead" = 0 ]; then
    [ "$O_TURN" = 1 ] || wd_handle_decisions
    wd_handle_quota
  fi
  # Recurrence: three real or would-be actions on one symptom in a day files an issue.
  if [ -n "$symptom" ] && [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" "$symptom" '*' '^(pending|dry-run)$' "$(( $(wd_now) - 86400 ))")" -ge 3 ]; then
    wd_self_heal "$symptom" "Watchdog: $symptom recurs on $O_TAG" "$symptom handled 3 or more times in 24h"
  fi
  WD_SYMPTOM=${symptom:-ok}
  if [ "$O_TR_AGE" = unknown ]; then
    wd_gap "no activity source; frozen, dead-holder, and low-context restarts are unavailable"
    WD_SYMPTOM=${symptom:-no-activity-source}
  fi
}

# --- status file -------------------------------------------------------------------

wd_health_line() {
  local s=$WD_SYMPTOM idle=''
  [ "$O_TR_AGE" = unknown ] || idle=", last turn $((O_TR_AGE / 60))m ago"
  case "$s" in
    ok) printf -- '- %s: ok%s, ctx %s\n' "$O_TAG" "$idle" "${O_CTX:-unknown}${O_CTX:+%}" ;;
    *) printf -- '- %s: %s%s, owed %s, ctx %s\n' "$O_TAG" "$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')" "$idle" "$O_OWED_N" "${O_CTX:-unknown}${O_CTX:+%}" ;;
  esac
}

wd_write_status() {  # <health-file> <gaps-file>
  local now interval read_at host tmp spent cap models m ok
  now=$(wd_now)
  interval=$(cfgi interval-secs 120)
  read_at=$(head -n 1 "$WD/last-read" 2>/dev/null | tr -cd '0-9')
  [ -n "$read_at" ] || read_at=$((now - 3600))
  host=$(hostname -s 2>/dev/null || hostname)
  spent=$(fm_wd_spent_since "$CALLS" "$((now - 86400))")
  cap=$(cfg daily-max-usd 1.00)
  models=''
  for m in $(wd_models); do
    ok=$(awk -F'\t' -v m="$m" '$3 == m { o = $4 } END { print (o == "" ? "unused" : (o == "ok" ? "ok" : "failing")) }' "$CALLS" 2>/dev/null)
    models="$models${models:+, }$m ${ok:-unused}"
  done
  mkdir -p "$OUT"
  tmp=$(mktemp "$OUT/.status.XXXXXX") || return 1
  {
    printf '# Firstmate watchdog - %s\n' "$host"
    printf 'updated %s, scan every %ss, mode %s, restart %s\n' "$(fm_wd_iso "$now")" "$interval" "$(wd_mode)" "$(cfg restart off)"
    printf 'STALE IF NOT UPDATED BY %s (watchdog may be down)\n' "$(fm_wd_iso $((now + interval * 3 + 300)))"
    printf 'models: %s; spent 24h $%s of $%s\n\n' "${models:-none}" "$spent" "$cap"
    printf '## Homes\n'
    head -n 12 "$1"
    printf '\n## Actions since last read (%s)\n' "$(fm_wd_iso "$read_at")"
    if [ -f "$LEDGER" ]; then
      awk -F'\t' -v since="$read_at" '$1 >= since && $7 != "pending" { print $1 "\t" $4 "\t" $6 "\t" $5 "\t" $7 }' "$LEDGER" |
        tail -n 10 | while IFS=$'\t' read -r e s a y p; do printf -- '- %s %s %s %s %s\n' "$(fm_wd_iso "$e" | cut -c12-16)" "$s" "$a" "$y" "$p"; done
    fi
    printf '\n## Open gaps\n'
    sort -u "$2" | head -n 8
  } | head -n 39 > "$tmp" && mv "$tmp" "$OUT/status.md"
}

# --- commands ----------------------------------------------------------------------

wd_once() {  # [home-filter]
  local filter=${1:-} health
  mkdir -p "$WD" "$OUT"
  health=$(mktemp "$WD/.health.XXXXXX") || return 1
  WD_GAPS=$(mktemp "$WD/.gaps.XXXXXX") || return 1
  wd_reconcile_pending
  wd_subjects | while IFS=$'\t' read -r home parent id; do
    [ -z "$filter" ] || [ "$home" = "$filter" ] || continue
    wd_observe "$home" "$parent" "$id"
    WD_SYMPTOM=ok WD_RESTARTED=0
    wd_handle_subject
    wd_health_line >> "$health"
  done
  [ -n "$(wd_models)" ] || printf -- '- no model configured; judged symptoms are reported only\n' >> "$WD_GAPS"
  wd_write_status "$health" "$WD_GAPS"
  rm -f "$health" "$WD_GAPS" "$WD/.decisions" "$WD/.decisions-aged"
}

cmd_scan() {
  local filter=${1:-}
  mkdir -p "$WD"
  wd_subjects | while IFS=$'\t' read -r home parent id; do
    [ -z "$filter" ] || [ "$home" = "$filter" ] || continue
    wd_observe "$home" "$parent" "$id"
    wd_print_observation
  done
}

cmd_run() {
  local interval
  interval=$(cfgi interval-secs 120)
  [ "${1:-}" != --interval ] || interval=${2:?--interval needs seconds}
  mkdir -p "$WD"
  fm_lock_try_acquire "$WD/.run.lock" || { echo "fm-watchdog: another watchdog already runs for $OWNER_HOME"; exit 0; }
  trap 'fm_lock_release "$WD/.run.lock"; exit 0' INT TERM HUP
  while :; do
    wd_once || true
    sleep "$interval"
  done
}

cmd_pickup() {
  local token=${1:-} st=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  case "$token" in ''|*[!0-9a-f]*) die "pickup needs the hex token from the restart prompt" 2 ;; esac
  mkdir -p "$st/watchdog/pickups"
  printf 'at=%s\nlock_pid=%s\n' "$(wd_now)" "$(head -n 1 "$st/.lock" 2>/dev/null)" > "$st/watchdog/pickups/$token"
  echo "pickup recorded"
}

canonical_home() { (cd -P -- "$OWNER_HOME" && pwd -P); }

manager_name() {
  local sum _
  read -r sum _ <<EOF
$(canonical_home | tr -d '\n' | cksum)
EOF
  printf 'firstmate-watchdog-%s\n' "$sum"
}

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }

render_launchd() {
  local home label script path
  mkdir -p "$(canonical_home)/state/watchdog"
  home=$(canonical_home | xml_escape)
  label=$(manager_name)
  script=$(printf '%s' "$SCRIPT_DIR/fm-watchdog.sh" | xml_escape)
  path=$(printf '%s' "$PATH" | xml_escape)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$script</string><string>run</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$home</string>
    <key>PATH</key><string>$path</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$home/state/watchdog/run.log</string>
  <key>StandardOutPath</key><string>$home/state/watchdog/run.log</string>
</dict></plist>
EOF
}

render_systemd() {
  cat <<EOF
[Unit]
Description=Firstmate assistant watchdog ($(manager_name))
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="FM_HOME=$(canonical_home)"
Environment="PATH=$PATH"
ExecStart=/bin/bash "$SCRIPT_DIR/fm-watchdog.sh" run
Restart=always
RestartSec=30s

[Install]
WantedBy=default.target
EOF
}

manager_status() {
  local name
  name=$(manager_name)
  case "$(uname -s)" in
    Darwin)
      [ -f "$HOME/Library/LaunchAgents/$name.plist" ] || { echo 'manager: uncovered (unit not installed)'; return 1; }
      launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1 && { echo "manager: enabled ($name)"; return 0; } ;;
    Linux)
      [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$name.service" ] || { echo 'manager: uncovered (unit not installed)'; return 1; }
      systemctl --user is-active --quiet "$name.service" && { echo "manager: enabled ($name)"; return 0; } ;;
    *) echo 'manager: uncovered (unsupported platform)'; return 1 ;;
  esac
  echo "manager: disabled ($name)"
  return 1
}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  run) cmd_run "$@" ;;
  once)
    filter=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dry-run) WD_FORCE_DRY=1 ;;
        --home) filter=$(cd -P -- "${2:?--home needs a path}" && pwd -P) || die "no such home: $2" 2; shift ;;
        *) die "unknown once option: $1" 2 ;;
      esac
      shift
    done
    wd_once "$filter" ;;
  scan)
    filter=''
    if [ "${1:-}" = --home ]; then filter=$(cd -P -- "${2:?--home needs a path}" && pwd -P) || die "no such home: $2" 2; fi
    cmd_scan "$filter" ;;
  judge)
    [ "$#" -eq 2 ] || die "usage: judge <purpose> <answer-ere> < prompt" 2
    mkdir -p "$WD"
    wd_judge "$1" "$2" "$(cat)" ;;
  status) cat "$OUT/status.md" 2>/dev/null || die "no status file yet" ;;
  ack-read) mkdir -p "$WD" && wd_now > "$WD/last-read" ;;
  pickup) cmd_pickup "$@" ;;
  manager-name) manager_name ;;
  manager-status) manager_status ;;
  render-launchd) render_launchd ;;
  render-systemd) render_systemd ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
