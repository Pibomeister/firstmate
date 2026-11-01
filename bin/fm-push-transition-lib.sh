#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
FM_WAKE_POST_OUTPUT_ACTION=
# Set only after this watcher has printed a durable actionable reason. The
# watcher's EXIT cleanup uses it to distinguish an ordinary delivered close from
# an interruption that leaves a recovery gap before the next arm.
FM_WATCH_DELIVERED_REASON=
FM_WATCH_DELIVERY_PID=
FM_WATCH_DELIVERY_IDENTITY=
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${FM_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${FM_WATCH_DELIVERY_KEEP_LINES:-64}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

watch_delivery_publish() {
  # Identity/reason cleaning are sequential $(): sibling $() args to one
  # printf are a bash 5.2 parse-error landmine when a CHLD trap is set.
  local reason=$1 i size tmp raw ident cleaned_reason
  [ -n "$FM_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$FM_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  ident=$(watch_delivery_clean_identity "$FM_WATCH_DELIVERY_IDENTITY")
  cleaned_reason=$(watch_delivery_clean_reason "$reason")
  printf '%s\t%s\t%s\n' \
    "$FM_WATCH_DELIVERY_PID" \
    "$ident" \
    "$cleaned_reason" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  size=$(wc -c < "$WATCH_DELIVERY_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$WATCH_DELIVERY_MAX_BYTES" ]; then
        tmp="$WATCH_DELIVERY_LOG.tmp.$FM_WATCH_DELIVERY_PID"
        raw="$tmp.raw"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$WATCH_DELIVERY_LOG" 2>/dev/null \
          | tail -c "$WATCH_DELIVERY_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^[0-9]+\t/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$WATCH_DELIVERY_LOCK"
}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# True for Grok's hold or the watchdog's owned-child hold, except while away
# or quiet mode owns triage.
# docs/watcher-continuity.md owns that continuity; this predicate is the flag check.
fm_watch_hold_active() {
  [ "${FM_WATCH_GROK_HOLD:-}" = 1 ] || [ "${FM_WATCH_MANAGED_HOLD:-}" = 1 ] || return 1
  if declare -F afk_present >/dev/null 2>&1; then
    afk_present && return 1
    return 0
  fi
  [ -n "${STATE:-}" ] && [ -e "$STATE/.afk" ] && return 1
  return 0
}

# The pane environment only names the candidate endpoint, tmux first as in
# fm_backend_detect; fm_watch_pane_binding_proved owns its proof.
fm_watch_pane_candidate() {
  if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
    FM_SM_BACKEND=tmux FM_SM_TARGET=$TMUX_PANE FM_SM_ROUTE=${TMUX%%,*}
  elif [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    FM_SM_BACKEND=herdr FM_SM_TARGET=$HERDR_SESSION:$HERDR_PANE_ID FM_SM_ROUTE=$HERDR_SESSION
  else
    return 1
  fi
}

# Local Codex secondmates keep the existing watcher, not a model tool session,
# alive. The parent binding supplies the existing steering inbox and doorbell.
fm_secondmate_watch_selected() {
  local watcher_pid
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$FM_PUSH_TRANSITION_LIB_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-supervision-engine-lib.sh
  . "$FM_PUSH_TRANSITION_LIB_DIR/fm-supervision-engine-lib.sh"
  fm_root_is_secondmate_home "$FM_HOME" || return 1
  fm_watch_pane_candidate || return 1
  # shellcheck disable=SC2153 # CONFIG is set by bin/fm-watch.sh.
  [ ! -e "$STATE/.afk" ] && ! fm_supervision_host_enabled "$CONFIG" codex || return 1
  FM_SM_INBOX=$(fm_secondmate_home_inbox "$FM_HOME") && [ "${FM_TASK_INBOX:-}" = "$FM_SM_INBOX" ] || return 1
  FM_SM_ID=${FM_SM_INBOX##*/}
  FM_SM_ID=${FM_SM_ID%.inbox}
  if fm_watcher_healthy "$STATE" "$FM_PUSH_TRANSITION_LIB_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then
    watcher_pid=$(cat "$STATE/.watch.lock/pid")
    case "$(ps -o args= -p "$watcher_pid" 2>/dev/null)" in *'/fm-watch.sh --secondmate-hold'*) ;; *) return 1 ;; esac
  fi
}

# The binding file records the session-lock owner pid, its fm_pid_identity,
# the ring target, the server route (tmux socket or Herdr session) and the
# backend; a file without the fifth line is a tmux binding. The owner must
# descend from the pane's shell and sit in its foreground group.
fm_secondmate_watch_binding_valid() {
  fm_secondmate_watch_selected || return 1
  fm_watch_pane_binding_proved
}

# A plain Codex primary's detached hold rings its own steering inbox over the
# same binding file, doorbell and record route as a secondmate hold.
fm_codex_hold_binding_valid() {
  [ ! -e "$STATE/.afk" ] && fm_watch_pane_candidate || return 1
  FM_SM_ID=codex-primary
  FM_SM_INBOX=$STATE/$FM_SM_ID.inbox
  fm_watch_pane_binding_proved
}

fm_hold_bell_binding_valid() {
  if [ "${FM_WATCH_CODEX_HOLD:-}" = 1 ]; then
    fm_codex_hold_binding_valid
  else
    fm_secondmate_watch_binding_valid
  fi
}

fm_watch_pane_binding_write() {
  local pid identity tmp
  pid=$(cat "$STATE/.lock")
  identity=$(fm_pid_identity "$pid") || return 1
  tmp=$(mktemp "$STATE/.secondmate-watch.XXXXXX") || return 1
  printf '%s\n' "$pid" "$identity" "$FM_SM_TARGET" "$FM_SM_ROUTE" "$FM_SM_BACKEND" > "$tmp" && mv "$tmp" "$STATE/.secondmate-watch"
}

fm_codex_hold_bind() {
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$FM_PUSH_TRANSITION_LIB_DIR/fm-session-lock-lib.sh"
  fm_watch_pane_candidate && fm_session_lock_owned_by_self "$STATE" || return 1
  fm_watch_pane_binding_write && fm_codex_hold_binding_valid
}

fm_watch_pane_binding_proved() {
  local target route backend pane_pid fg
  [ ! -L "$STATE/.secondmate-watch" ] && [ -f "$STATE/.secondmate-watch" ] || return 1
  {
    IFS= read -r FM_SM_PID && IFS= read -r FM_SM_IDENTITY && IFS= read -r target && IFS= read -r route \
      && { IFS= read -r backend || :; }
  } < "$STATE/.secondmate-watch" || return 1
  [ "$FM_SM_PID" = "$(cat "$STATE/.lock" 2>/dev/null)" ] || return 1
  [ -n "$FM_SM_IDENTITY" ] && [ "$FM_SM_IDENTITY" = "$(fm_pid_identity "$FM_SM_PID" 2>/dev/null)" ] || return 1
  [ "${backend:-tmux}" = "$FM_SM_BACKEND" ] && [ "$target" = "$FM_SM_TARGET" ] && [ "$route" = "$FM_SM_ROUTE" ] || return 1
  fm_backend_source "$FM_SM_BACKEND" || return 1
  if [ "$FM_SM_BACKEND" = herdr ]; then
    fm_backend_herdr_parse_target "$FM_SM_TARGET" || return 1
    fg=$(fm_backend_herdr_pane_process_pids "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE") || return 1
    pane_pid=${fg%%$'\n'*}
    fg=${fg#"$pane_pid"}
  else
    pane_pid=$(tmux -S "$FM_SM_ROUTE" display-message -p -t "$FM_SM_TARGET" '#{pane_pid}') || return 1
    fg=$(fm_backend_tmux_foreground_pids "$FM_SM_TARGET")
  fi
  fm_pid_descends_from "$FM_SM_PID" "$pane_pid" || return 1
  printf '%s\n' "$fg" | grep -Fx "$FM_SM_PID" >/dev/null
}

fm_secondmate_watch_status() {
  local pid
  fm_secondmate_watch_binding_valid || return 1
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null) || return 1
  case "$(ps -o args= -p "$pid" 2>/dev/null)" in *'/fm-watch.sh --secondmate-hold'*) ;; *) return 1 ;; esac
  fm_watcher_healthy "$STATE" "$FM_PUSH_TRANSITION_LIB_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"
}

fm_secondmate_watch_start() {
  local deadline monitor=0
  fm_secondmate_watch_selected || { echo 'secondmate watcher: unsupported home, route or ownership mode' >&2; return 1; }
  fm_secondmate_watch_status && return 0
  [ "$("$FM_PUSH_TRANSITION_LIB_DIR/fm-harness.sh")" = codex ] || { echo 'secondmate watcher: caller is not Codex' >&2; return 1; }
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$FM_PUSH_TRANSITION_LIB_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" || { echo 'secondmate watcher: session lock is not owned by this caller' >&2; return 1; }
  fm_watcher_healthy "$STATE" "$FM_PUSH_TRANSITION_LIB_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" && { echo 'secondmate watcher: an existing watcher owns supervision' >&2; return 1; }
  fm_watch_pane_binding_write || return 1
  fm_secondmate_watch_binding_valid || return 1
  case $- in *m*) monitor=1 ;; esac
  set -m
  nohup "$FM_PUSH_TRANSITION_LIB_DIR/fm-watch.sh" --secondmate-hold >"$STATE/.secondmate-watch.log" 2>&1 </dev/null &
  disown "$!" 2>/dev/null || true
  [ "$monitor" -eq 1 ] || set +m
  deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    fm_secondmate_watch_status && return 0
    sleep 0.2
  done
  return 1
}

fm_secondmate_watch_notify() {
  local rec body ring_rc=0
  fm_hold_bell_binding_valid || return 1
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$FM_PUSH_TRANSITION_LIB_DIR/fm-task-inbox-lib.sh"
  [ ! -L "$STATE/.secondmate-watch-message" ] || return 1
  rec=$(cat "$STATE/.secondmate-watch-message" 2>/dev/null || true)
  if [ "${rec%/*}" != "$FM_SM_INBOX" ] || [ ! -f "$rec" ]; then
    body=$(printf '%s\n' 'Read state/.supervision-host-park.out if it exists, run bin/fm-wake-drain.sh, handle and acknowledge the durable watcher events, send any resulting actions and parent replies, then end this turn.' | "$FM_PUSH_TRANSITION_LIB_DIR/fm-operational-input.sh" encode watcher) || return 1
    rec=$(fm_task_inbox_write "${FM_SM_INBOX%/*}" "$FM_SM_ID" "$body") || return 1
    printf '%s\n' "$rec" > "$STATE/.secondmate-watch-message" || return 1
  elif [ "${FM_WATCH_CODEX_HOLD:-}" != 1 ] || [ "${FM_SM_NOTIFY_RETRY:-0}" -eq 0 ]; then
    return 0
  fi
  fm_hold_bell_binding_valid || return 1
  fm_task_inbox_ring "$FM_SM_BACKEND" "$FM_SM_TARGET" "$rec" "$FM_SM_ID" || ring_rc=$?
  case "$ring_rc" in
    1|2)
      [ "${FM_WATCH_CODEX_HOLD:-}" != 1 ] || return 1
      fm_task_inbox_mark_retry "${FM_SM_INBOX%/*}" "$FM_SM_ID" "$rec"
      ;;
    3) return 1 ;;
  esac
}

# Exit after reporting one actionable wake. Tests override this callback.
# A hold opt-in returns after the report so the watcher can keep the lock.
# An optional cadence kind lets actionable work retain heartbeat delivery while
# resetting idle backoff; omitted kinds keep the wake reason's existing accounting.
wake() {
  local output_status=0
  case "${2:-$1}" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  trap '' HUP INT TERM
  [ -z "$FM_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if echo "$1"; then
    output_status=0
    watch_delivery_publish "$1" || true
    # shellcheck disable=SC2034 # Read by bin/fm-watch.sh's EXIT cleanup.
    FM_WATCH_DELIVERED_REASON=$1
    # The managed owner keeps this watcher alive after delivery. Its recovery
    # check must not re-announce the same still-queued wake on the next poll.
    if [ "${FM_WATCH_MANAGED_HOLD:-}" = 1 ]; then
      # shellcheck disable=SC2034 # Read by the sourcing fm-watch.sh after wake returns.
      FM_MANAGED_WAKE_DELIVERED=1
    fi
  else
    output_status=1
  fi
  if [ -n "$FM_WAKE_POST_OUTPUT_ACTION" ]; then
    "$FM_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
    FM_WAKE_POST_OUTPUT_ACTION=
  fi
  [ "$output_status" -eq 0 ] || exit "$output_status"
  if [ "${FM_WATCH_SECONDMATE_HOLD:-}" = 1 ] || [ "${FM_WATCH_CODEX_HOLD:-}" = 1 ]; then
    # shellcheck disable=SC2034 # Read by bin/fm-watch.sh's hold loop.
    fm_secondmate_watch_notify || FM_SM_NOTIFY_RETRY=1
  fi
  if fm_watch_hold_active; then
    if declare -F watcher_stop_signals >/dev/null 2>&1; then
      watcher_stop_signals
    else
      trap - HUP INT TERM
    fi
    trap - PIPE
    return 0
  fi
  exit 0
}

_hb_surfaced_path() {
  status_heartbeat_seen_marker_path "$STATE" "$1"
}

# The byte offset in <task>'s status log that the heartbeat backstop has already
# classified, or 0 when it has no usable position. A position rather than an
# event line lets the backstop catch an event the per-wake path missed,
# and comparing the last line cannot see an event a later routine append moved
# past - exactly the masking fm-classify-lib.sh's span read exists to stop. An
# absent or malformed marker (including one an older watcher wrote as a status
# line) reads 0, so the log is re-classified and the backstop errs toward
# surfacing rather than swallowing.
hb_surfaced_offset() {  # <task>
  status_presentation_marker_offset "$(_hb_surfaced_path "$1")" "$STATE/$1.status"
}

# Record a status log as successfully classified through the captured endpoint.
mark_surfaced() {  # <status-file> <captured-end-offset> <captured-identity>
  local f=$1 task
  case "$f" in *.status) ;; *) return 0 ;; esac
  task=$(basename "$f"); task="${task%.status}"
  status_presentation_marker_commit "$(_hb_surfaced_path "$task")" "$f" "$2" "$3"
}

mark_surface_reported() {  # <status-file> <reported-signature>
  local f=$1 task
  task=$(basename "$f"); task="${task%.status}"
  status_presentation_marker_report "$(_hb_surfaced_path "$task")" "$2"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to detail window task reason span_record rest surface_end='' surface_ident='' note
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  detail=$(fm_transition_detail "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window=$(fm_backend_transition_target "$backend" "$session" "$pane_id")
  task=$(window_to_task "$window" "$STATE")
  # A declared wait already names the human this transition would report: an
  # external dependency, or the captain a verified hold transferred the work to.
  # Either way the wait is durably recorded, so absorb the immediate escalation
  # and leave the bounded re-surface to the watcher's own pause cadence.
  if status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared wait, awaiting external or captain): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  span_record=$(status_span_first_actionable_record "$STATE/$task.status" \
    "$(hb_surfaced_offset "$task")")
  case $? in
    0|1) surface_end=${span_record%%$'\t'*}; rest=${span_record#*$'\t'}; surface_ident=${rest%%$'\t'*} ;;
  esac
  note=$(fm_backend_transition_note "$backend" "$record" 2>/dev/null || true)
  reason="stale: $window ($backend: agent $to${detail:+ ($detail)} - waiting on human${note:+: $note}, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status" "$surface_end" "$surface_ident"
  wake "$reason"
}
