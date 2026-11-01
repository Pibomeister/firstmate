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
#   state/watchdog/subjects/<tag>   the previous observation of each subject.
#   state/watchdog/escalated/<tag>  present after a restart loop; remove it to clear.
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

# A zombie answers kill -0 but has exited.
wd_pid_alive() {  # <pid>
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
  return 0
}

wd_id() { printf 'wd%s%s' "$(wd_now)" "$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; }

# --- subjects ----------------------------------------------------------------

wd_homes() {
  cfg homes "$OWNER_HOME" | tr ',' '\n' | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//' -e '/^$/d'
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
  local entry
  for entry in $(cfg do-not-touch "" | tr ',' ' '); do
    [ "$entry" = "$1" ] || [ "$entry" = "$2" ] || [ "$entry" = "$(wd_tag "$1")" ] && return 0
  done
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
      fm_backend_source orca >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
      if fm_run_timed_fn 10 fm_backend_orca_turn_running "$t" >/dev/null 2>&1; then printf '1\n'; else printf '0\n'; fi ;;
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

# wd_observe <home> <parent> <id>: fills the O_* globals for one subject and
# saves the comparable parts to state/watchdog/subjects/<tag>.
wd_observe() {
  local home=$1 parent=$2 id=$3 st now hb prev meta row hb_sid ctx dt
  st=$home/state
  now=$(wd_now)
  O_HOME=$home O_PARENT=$parent O_ID=$id O_TAG=$(wd_tag "$home")
  O_BACKEND='' O_TARGET='' O_SESSION='' O_HB_AGE=unknown O_CTX='' O_CTX_SRC=''
  O_PANE='' O_SIG='' O_PANE_STATIC=0 O_DIALOG='' O_COMPOSER=unknown O_TURN=unknown
  O_LOCK_PID='' O_ALIVE=0 O_INSTANCE=unknown O_CPU_BUSY=unknown O_TRANSCRIPT='' O_TR_AGE=unknown
  O_LOOP=none O_LOOP_N=0 O_LOOP_SAMPLE='' O_RESTART_REQ=0 O_OWED_N=0 O_OWED_AGE=0
  O_AFK=0 O_DAEMON=unknown O_PREV_COMPOSER='' O_PREV_SIG='' O_COMPOSER_TEXT=''
  hb=$st/heartbeat.json
  hb_sid=''
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
    if [ "$ctx" != - ] && [ -n "$ctx" ]; then O_CTX=${ctx%%.*}; O_CTX_SRC=heartbeat; fi
  fi
  if [ -f "$st/.lock" ]; then
    O_LOCK_PID=$(head -n 1 "$st/.lock" 2>/dev/null | tr -cd '0-9')
    if wd_pid_alive "$O_LOCK_PID"; then O_ALIVE=1; fi
    if fm_session_lock_anchor_instance_matches "$st" 2>/dev/null; then O_INSTANCE=match; else O_INSTANCE=mismatch; fi
  fi
  O_SESSION=$(fm_session_lock_recorded_session_id "$st" 2>/dev/null) || O_SESSION=$hb_sid
  # A second mate whose own heartbeat names another session, or none, uses the
  # parent's recorded endpoint for it.
  meta=''
  [ "$parent" = - ] || meta=$parent/state/$id.meta
  if [ -n "$meta" ] && [ -f "$meta" ] && { [ -z "$O_TARGET" ] || [ "$hb_sid" != "$O_SESSION" ]; }; then
    O_BACKEND=$(fm_backend_of_meta "$meta" 2>/dev/null)
    O_TARGET=$(fm_backend_target_of_meta "$meta" 2>/dev/null)
  fi
  prev=$WD/subjects/$O_TAG
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
    if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WD_TEST_COMPOSER:-}" ]; then
      O_COMPOSER=$FM_WD_TEST_COMPOSER
    else
      O_COMPOSER=$(fm_run_timed_fn 20 fm_backend_composer_state "$O_BACKEND" "$O_TARGET" 2>/dev/null) || O_COMPOSER=unknown
    fi
    [ -n "$O_COMPOSER" ] || O_COMPOSER=unknown
    O_TURN=$(wd_turn_running "$O_BACKEND" "$O_TARGET" "$O_PANE")
    O_COMPOSER_TEXT=$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = n - 7; i <= n; i++) if (i > 0) print r[i] }')
    if [ "$O_BACKEND" = orca ]; then
      O_COMPOSER_TEXT="$O_COMPOSER_TEXT $(fm_run_timed 10 orca terminal read --terminal "$O_TARGET" --limit 5 --json 2>/dev/null | jq -r '(.result.terminal.draft // .result.draft // "") | tostring' 2>/dev/null)"
    fi
    ctx=$(fm_wd_footer_percent "$O_PANE")
    if [ -z "$O_CTX" ] && [ -n "$ctx" ]; then O_CTX=$ctx; O_CTX_SRC=pane; fi
  fi
  if [ -f "$st/context-burn.tsv" ] && [ -n "$O_SESSION" ]; then
    # bin/fm-context-burn.sh rows: epoch, session, turn_type, percent; only a sample from the last hour counts.
    ctx=$(awk -F'\t' -v s="$O_SESSION" -v since="$((now - 3600))" '$1 >= since && $2 == s && $4 ~ /^[0-9]+$/ { p = $4 } END { if (p != "") print p }' "$st/context-burn.tsv")
    if [ -n "$ctx" ]; then O_CTX=$ctx; O_CTX_SRC=context-burn; fi
  fi
  if O_TRANSCRIPT=$(wd_transcript "$home" "$O_SESSION"); then
    O_TR_AGE=$((now - $(wd_mtime "$O_TRANSCRIPT")))
    local ev last_restart
    ev=$(fm_wd_transcript_events "$O_TRANSCRIPT" 400)
    IFS=$'\t' read -r O_LOOP O_LOOP_N O_LOOP_SAMPLE <<EOF
$(printf '%s\n' "$ev" | fm_wd_loop_verdict "$(cfgi rapid-loop-secs 180)")
EOF
    last_restart=$(fm_wd_last_epoch "$LEDGER" "$home" '*' restart '^(pending|dry-run)$')
    if printf '%s\n' "$ev" | awk -F'\t' -v since="${last_restart:-0}" '$1 == "T" { n++; t[n] = $2; x[n] = $3 } END { for (i = n; i > n - 2 && i > 0; i--) if (t[i] > since && x[i] ~ /RESTART REQUESTED/) f = 1; exit !f }'; then
      O_RESTART_REQ=1
    fi
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
  wd_rate_open "$symptom" nudge "$(cfgi nudge-secs 900)" || return 0
  id=$(wd_id)
  if ! fm_wd_text_allowed "$body"; then wd_rec "$id" "$symptom" nudge refused "text names a merge, deploy, or release word"; return 0; fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" nudge refused "endpoint is on do-not-touch"; return 0; fi
  if [ -z "$O_TARGET" ]; then wd_rec "$id" "$symptom" nudge refused "no recorded endpoint"; return 0; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" nudge dry-run "$body"; return 0; fi
  if [ -n "$O_DIALOG" ] || { [ "$O_COMPOSER" != empty ] && [ "$O_COMPOSER" != unknown ]; }; then
    wd_rec "$id" "$symptom" nudge refused "composer is $O_COMPOSER${O_DIALOG:+, dialog $O_DIALOG}; nothing typed"
    return 0
  fi
  wd_rec "$id" "$symptom" nudge pending "$body"
  doorbell=$(printf '%s\n' "$body" | FM_HOME=$O_HOME "$SCRIPT_DIR/fm-operational-input.sh" record watcher 2>/dev/null) || {
    wd_rec "$id" "$symptom" nudge failed "operational input record failed"; return 0; }
  verdict=$(fm_run_timed_fn 30 fm_backend_send_text_submit "$O_BACKEND" "$O_TARGET" "$doorbell" 2 0.5 1 2>/dev/null) || {
    wd_rec "$id" "$symptom" nudge failed "doorbell submit failed (${verdict:-no verdict})"; return 0; }
}

# wd_key <symptom> <key-or-digit> <why>: one key, then verify the dialog left.
wd_key() {
  local symptom=$1 key=$2 why=$3 id after
  wd_rate_open "$symptom" key "$(cfgi key-secs 120)" || return 0
  id=$(wd_id)
  # Two keys that did not clear a dialog within the hour stop the presses, so a
  # misread screen never keeps typing into the session.
  if [ "$symptom" = dialog ] && [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" dialog key '^failed$' "$(( $(wd_now) - 3600 ))")" -ge 2 ]; then
    wd_gap "a $O_DIALOG dialog did not clear after two keys this hour; no more keys pressed"
    return 0
  fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" key refused "endpoint is on do-not-touch"; return 0; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" key dry-run "would press $key: $why"; return 0; fi
  wd_rec "$id" "$symptom" key pending "press $key: $why"
  case "$O_BACKEND:$key" in
    orca:Escape) fm_run_timed 10 orca terminal send --terminal "$O_TARGET" --text "$(printf '\033')" --json >/dev/null 2>&1 ;;
    orca:[0-9]) fm_run_timed 10 orca terminal send --terminal "$O_TARGET" --text "$key" --json >/dev/null 2>&1 ;;
    tmux:[0-9]) fm_run_timed 10 tmux send-keys -t "$O_TARGET" -l "$key" >/dev/null 2>&1 ;;
    *) fm_run_timed_fn 10 fm_backend_send_key "$O_BACKEND" "$O_TARGET" "$key" >/dev/null 2>&1 ;;
  esac || { wd_rec "$id" "$symptom" key failed "key delivery failed"; return 0; }
  sleep "$(cfgi key-settle-secs 2)"
  case "$symptom" in
    dialog) after=$(wd_view "$O_BACKEND" "$O_TARGET") ;;
    *) after=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) ;;
  esac
  case "$symptom" in
    dialog) if [ -n "$after" ] && ! fm_wd_pane_dialog "$after" >/dev/null; then wd_rec "$id" "$symptom" key "done" "dialog left the pane"; else wd_rec "$id" "$symptom" key failed "dialog still showing"; fi ;;
    *) if [ -n "$after" ] && [ "$(wd_pane_sig "$after")" != "$O_SIG" ]; then wd_rec "$id" "$symptom" key "done" "pane changed"; else wd_rec "$id" "$symptom" key failed "pane unchanged"; fi ;;
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
    cursor)
      command -v cursor-agent >/dev/null 2>&1 || return 4
      out=$( (cd "$scratch" && fm_run_timed "$(cfgi judge-timeout-secs 120)" cursor-agent -p --model "$m" --output-format json "$prompt") 2>/dev/null) || rc=$?
      ans=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)
      cost=unmetered ;;
    *) return 4 ;;
  esac
  ans=$(printf '%s\n' "$ans" | sed -e 's/^[ \t`*]*//' -e 's/[ \t`*.]*$//' | LC_ALL=C grep -Ex "$re" | head -n 1)
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
    ruling=$OUT/rulings/$O_TAG-$task-$key.md
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
  if [ -f "$WD/escalated/$O_TAG" ]; then wd_gap "RESTART LOOP escalated; clear $WD/escalated/$O_TAG after review"; return 1; fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" restart refused "endpoint is on do-not-touch"; return 1; fi
  if ! fm_wd_stall_proof "$O_TURN" "$O_CPU_BUSY" "$@"; then
    wd_gap "$symptom: restart not proven (turn_running=$O_TURN cpu_busy=$O_CPU_BUSY signals=$*)"
    return 1
  fi
  count=$(fm_wd_count_since "$LEDGER" "$O_HOME" '*' restart '^pending$' "$((now - 86400))")
  last=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  if [ "$count" -ge "$(cfgi max-restarts 2)" ] || { [ -n "$last" ] && [ $((now - last)) -lt 7200 ]; }; then
    mkdir -p "$WD/escalated"
    printf '%s\n' "$now" > "$WD/escalated/$O_TAG"
    wd_rec "$id" "$symptom" restart escalated "restart loop: $count restarts in 24h"
    wd_self_heal "restart-loop" "Watchdog restart loop for $O_TAG" "symptom $symptom recurred after $count restarts in 24h"
    return 1
  fi
  if [ "$(cfg restart off)" != on ]; then wd_rec "$id" "$symptom" restart refused "restart is off; stall proven by $*"; return 1; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" restart dry-run "would restart; stall proven by $*"; return 1; fi
  return 0
}

wd_write_handoff() {  # <symptom> -> prints path
  local symptom=$1 path latest
  mkdir -p "$OUT/handoffs"
  path=$OUT/handoffs/$O_TAG-$(wd_now).md
  # shellcheck disable=SC2012  # newest-first by mtime; handoff names are firstmate-written
  latest=$(ls -t "$O_HOME"/data/handoff-*.md 2>/dev/null | head -n 1)
  {
    printf '# Watchdog restart handoff - %s\n\n' "$O_TAG"
    printf -- '- home: %s\n- reason: %s\n- at: %s\n- newest session handoff: %s\n' "$O_HOME" "$symptom" "$(fm_wd_iso "$(wd_now)")" "${latest:-none}"
    printf -- '- owed input: %s rows, oldest %ss\n- away mode: %s\n\n' "$O_OWED_N" "$O_OWED_AGE" "$O_AFK"
    printf 'Start with the newest session handoff above when it exists, then run the session-start contract.\n\n'
    # shellcheck disable=SC2016  # literal Markdown fences
    printf 'Pane tail at restart:\n\n```\n%s\n```\n' "$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | tail -n 40)"
  } > "$path"
  printf '%s\n' "$path"
}

wd_restart() {  # <symptom> <kind>...
  local symptom=$1 id handoff token cmd prompt pid i
  shift
  wd_restart_gate "$symptom" "$@" || return 0
  id=$(wd_id)
  handoff=$(wd_write_handoff "$symptom")
  if [ "$O_PARENT" != - ]; then
    wd_rec "$id" "$symptom" restart pending "second mate relaunch through its parent; handoff=$handoff"
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
  if [ "$O_INSTANCE" != match ] || [ -z "$O_LOCK_PID" ]; then wd_rec "$id" "$symptom" restart refused "lock anchor does not match its recorded instance"; return 0; fi
  token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  pid=$O_LOCK_PID
  wd_rec "$id" "$symptom" restart pending "token=$token old_pid=$pid handoff=$handoff"
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while wd_pid_alive "$pid" && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
  if wd_pid_alive "$pid"; then
    wd_rec "$id" "$symptom" restart failed "old session pid $pid did not stop on TERM; left running"
    return 0
  fi
  prompt="Watchdog restart of this firstmate home. Read $handoff first, then take over as the session-start contract says. After you hold the session lock, run: FM_HOME=$O_HOME $SCRIPT_DIR/fm-watchdog.sh pickup $token"
  case "$O_BACKEND" in
    orca) fm_run_timed 60 orca terminal create --worktree "path:$O_HOME" --title "firstmate captain" --command "$cmd $(printf '%q' "$prompt")" --json >/dev/null 2>&1 ;;
    tmux)
      local sess
      sess=$(fm_run_timed 10 tmux display-message -p -t "$O_TARGET" '#{session_name}' 2>/dev/null) || sess=''
      [ -n "$sess" ] || { wd_rec "$id" "$symptom" restart failed "tmux session of $O_TARGET not found"; return 0; }
      fm_run_timed 30 tmux new-window -d -t "$sess:" -c "$O_HOME" -n firstmate "$cmd $(printf '%q' "$prompt")" >/dev/null 2>&1 ;;
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
        [ -n "$tok" ] || continue
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
  nudges=$(fm_wd_count_since "$LEDGER" "$O_HOME" "$symptom" nudge '^(pending|dry-run)$' "$(( $(wd_now) - 7200 ))")
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
    question)
      text=$(fm_wd_dialog_text "$O_PANE")
      if fm_wd_reserved "$text"; then wd_gap "question dialog names an owner-reserved category; held"; return 0; fi
      wd_key dialog Escape "close the question so the session can settle it by council"
      wd_nudge question "your question dialog was closed so work keeps moving. Settle it by council per the captain rules, record the ruling, and continue." ;;
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
    if case "$key" in captain-hold-*) true ;; *) false ;; esac || fm_wd_reserved "$summary" ||
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

# wd_handle_subject: one symptom per pass, by precedence, then the side checks.
wd_handle_subject() {
  local symptom='' quiet frozen owed
  frozen=$(cfgi frozen-secs 900)
  owed=$(cfgi owed-input-secs 900)
  quiet=$(cfgi restart-quiet-secs 120)
  if [ -n "$O_DIALOG" ]; then
    symptom=dialog
    wd_handle_dialog
  elif [ "$O_RESTART_REQ" = 1 ] || { [ -n "$O_CTX" ] && [ "$O_CTX" -le "$(cfgi restart-at-percent 8)" ]; }; then
    symptom=restart-requested
    if [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -ge "$quiet" ]; then
      wd_restart restart-requested filesystem records
    else
      wd_gap "restart requested; waiting for ${quiet}s of quiet"
    fi
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
  elif [ -n "$O_LOCK_PID" ] && [ "$O_ALIVE" = 0 ] && [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -ge "$frozen" ]; then
    symptom=agent-gone
    O_TURN=0 O_CPU_BUSY=0 wd_restart agent-gone kernel filesystem
  elif [ "$O_COMPOSER" = pending ] && [ "$O_PREV_COMPOSER" = pending ] && [ "$O_SIG" = "$O_PREV_SIG" ] && [ "$O_TURN" = 0 ]; then
    symptom=pasted-input
    if ! fm_wd_text_allowed "$O_COMPOSER_TEXT"; then
      wd_rate_open pasted-input key "$(cfgi enter-secs 300)" &&
        wd_rec "$(wd_id)" pasted-input key refused "pending text names a merge, deploy, or release word; never accepted"
    else
      wd_rate_open pasted-input key "$(cfgi enter-secs 300)" && wd_key pasted-input Enter "submit text left unsent"
    fi
  elif [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ] && [ "$O_TURN" != 1 ]; then
    symptom=unread-input
    wd_nudge unread-input "$O_OWED_N inputs have waited $((O_OWED_AGE / 60)) minutes. Drain the wake queue and act on it."
  fi
  if [ "$O_AFK" = 1 ] && [ "$O_DAEMON" = 0 ]; then
    [ -n "$symptom" ] || symptom=daemon-dead
    wd_nudge daemon-dead "away mode is on but the away daemon is not running. Re-arm it with bin/fm-afk-start.sh on this session's own terminal."
  fi
  if [ "$O_HB_AGE" != unknown ] && [ "$O_HB_AGE" -ge "$(cfgi watcher-stale-secs 900)" ]; then
    wd_gap "watcher heartbeat is $((O_HB_AGE / 60))m old"
  fi
  [ "$O_TURN" = 1 ] || wd_handle_decisions
  wd_handle_quota
  # Recurrence: three real or would-be actions on one symptom in a day files an issue.
  if [ -n "$symptom" ] && [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" "$symptom" '*' '^(pending|dry-run)$' "$(( $(wd_now) - 86400 ))")" -ge 3 ]; then
    wd_self_heal "$symptom" "Watchdog: $symptom recurs on $O_TAG" "$symptom handled 3 or more times in 24h"
  fi
  WD_SYMPTOM=${symptom:-ok}
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
    WD_SYMPTOM=ok
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
