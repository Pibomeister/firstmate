#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.busy-state   consecutive busy deferrals: "<msg>\t<count>"
#   <task>.inbox/.escalated    names of records already surfaced as stale,
#                              one per line, so later polls suppress another
#                              escalation for them and move to the next record
#   <task>.inbox/.retry-ring   name of a fire-and-forget record still owed its
#                              one retry ring (fm_task_inbox_mark_retry)
#   <task>.inbox/.recover-state  automatic secondmate recovery budget:
#                              "<msg>\t<count>\t<epoch>\t<spawn-gen>"
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#                              (it still gets one retry ring; see below)
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect another draft in a proven pending
# composer; an unsubmitted copy of this doorbell is retried. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: due actions deferred
# by a busy pane consume a separate durable consecutive-poll budget,
# FM_TASK_INBOX_BUSY_MAX. At that bound the same escalation path surfaces a
# stuck-busy reason without typing. A non-busy due check or acknowledgement resets
# this budget. Fire-and-forget retries remain outside escalation. A positively
# dead or missing endpoint skips delivery and the ladder and escalates directly.
# This library owns the schedule, durable budgets, and escalation marker.
#
# Automatic recovery (fm_task_inbox_recover_next): for a local secondmate the
# watcher answers a spent ladder or busy budget with the existing lifecycle
# interrupt plus an ordinary doorbell instead of an alarm, at most
# FM_TASK_INBOX_RECOVER_MAX (2) times for the same ladder record of the same
# worker generation, and never before that record is
# FM_TASK_INBOX_RECOVER_AFTER seconds old (the charter's 5-minute
# acknowledgement allowance, bin/fm-brief.sh). Each recovery is persisted
# before it runs and restarts the ladder, so the acknowledgement stays the
# only progress proof and a crash can never repeat a slot. The first slot
# rings without interrupting when the parent channel already proves an answer
# to that exact record (fm_task_inbox_record_answered). With both slots spent,
# the ordinary single escalation follows. Records are never moved, edited or
# deleted here.
# If delivery-attempt or busy-deferral bookkeeping fails while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Retry ring (fm_task_inbox_mark_retry): only while config/wait-no-turns is
# present. A fire-and-forget record never enters the ladder, but when
# fm-send's ring at enqueue did not land
# (fm_task_inbox_ring returned 1 or 2) it marks the record, and one grace later
# the due action is `retry`: once the worker has no open decision of its own,
# the watcher rings once more and spends the mark
# whatever the result, so the record never rings a third time and never
# escalates. A waiting worker does not poll its inbox (bin/fm-brief.sh), so
# without this retry the record could sit unread until a checkpoint. A pending ordinary record's
# ladder rings the same inbox, so the retry waits behind it, and an
# acknowledged record drops its mark. The remote steer leg has no watcher
# ladder and owes no retry.
#
# Inbox names containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_BUSY_MAX     default 2; consecutive busy-deferred due polls before escalation
#   FM_TASK_INBOX_RECOVER_AFTER  default 300; record age before automatic recovery

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_BUSY_MAX_DEFAULT=2
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5
FM_TASK_INBOX_RECOVER_AFTER_DEFAULT=300

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_recover_after() {
  local a=${FM_TASK_INBOX_RECOVER_AFTER:-$FM_TASK_INBOX_RECOVER_AFTER_DEFAULT}
  case "$a" in ''|*[!0-9]*) a=$FM_TASK_INBOX_RECOVER_AFTER_DEFAULT ;; esac
  printf '%s' "$a"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_busy_max() {
  local m=${FM_TASK_INBOX_BUSY_MAX:-$FM_TASK_INBOX_BUSY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT ;; esac
  # Check the length before numeric comparison so oversized input cannot overflow.
  if [ "${#m}" -gt 9 ] || [ "$m" -eq 0 ]; then
    m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT
  fi
  printf '%s' "$m"
}

# Persist before returning the new count, so a fresh watcher continues the same
# bounded wait. A removed or acknowledged record is a quiet no-op.
fm_task_inbox_record_busy() {  # <state-dir> <task-id> <record-path>
  local dir base previous count
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  { IFS=$(printf '\t') read -r previous count < "$dir/.busy-state"; } 2>/dev/null || true
  [ "${previous:-}" = "$base" ] || count=0
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  [ -f "$3" ] || { printf '0'; return 0; }
  count=$((count + 1))
  if ! { printf '%s\t%s\n' "$base" "$count" > "$dir/.busy-state"; } 2>/dev/null; then
    [ -f "$3" ] || { printf '0'; return 0; }
    return 1
  fi
  printf '%s' "$count"
}

fm_task_inbox_clear_busy() {  # <state-dir> <task-id>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  rm -f "$dir/.busy-state" 2>/dev/null
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# It names the inbox by the literal "$FM_TASK_INBOX", which bin/fm-spawn.sh
# exports into every launch as the inbox's absolute path, so the worker can
# resolve it from its own environment even after losing its brief context.
# The short `<task>.inbox` name follows as the fallback for a worker launched
# before that export, whose brief carries the full path (bin/fm-dod-lib.sh
# role contract, bin/fm-brief.sh inbox section). No absolute path is printed,
# so the line's length never grows with the home's depth: a long line wraps
# past what a harness composer read can prove, and a Herdr submit then reports
# it did not reach the pane on every re-ring. The leading `: ` is the POSIX
# shell no-op, so the same line typed into a pane whose agent has exited (a
# bare shell) runs nothing; see the dead-pane note in the header. A
# non-printable inbox name fails without output so terminal controls never
# reach the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs name quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  name=${abs##*/}
  case "$name" in
    ''|*[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$name" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your '%s' steering inbox, read and act on each in numeric order, then mv each into its handled/." \
    "$quoted"
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, one advisory
# composer pre-check, then the backend's submit machinery with a minimal retry
# budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# other than our own doorbell (the watcher re-rings later), 2 the backend send
# failed, 3 skipped because the endpoint is positively dead or missing (nothing
# typed; recovery owns the record). No return value is delivery proof; the
# acknowledgement move is the only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict can defer,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
# A pending composer holding only whole copies of our own doorbell line is
# earlier rings whose Enter never landed (later rings concatenate onto it), so
# on an agent not reported busy it is submitted rather than skipped; skipping
# it would block every later ring. A busy Codex takes that Enter as a mid-turn
# steer (docs/verification/runtime-backends.md, "Steering-inbox doorbell on a
# busy Codex"), so a task whose record harness is codex submits it while busy
# too. A paste placeholder
# such as Codex's `[Pasted Content N chars]` is opaque and never proves
# ownership, whatever its size. On both paths a lost first Enter gets one
# retry, and only while the composer still holds exactly the owned copies.
# The whole ring is bounded: it runs under fm_run_timed_fn for
# FM_SEND_RING_BUDGET seconds (default 20), and a ring still running then is
# stopped and returns 2, so a hung backend read can never hold its caller - or
# the lease-command lock that caller may hold - and the steer stays durably
# recorded for the watcher's re-ring ladder.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local budget=${FM_SEND_RING_BUDGET:-20} rc=0
  case "$budget" in '' | *[!0-9]* | 0) budget=20 ;; esac
  # shellcheck source=bin/fm-timeout-lib.sh
  command -v fm_run_timed_fn >/dev/null 2>&1 \
    || . "$_FM_TASK_INBOX_LIB_DIR/fm-timeout-lib.sh"
  fm_run_timed_fn "$budget" _fm_task_inbox_ring_once "$@" || rc=$?
  [ "$rc" -ne 124 ] || rc=2
  return "$rc"
}

_fm_task_inbox_ring_once() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending)
      if [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" = busy ]; then
        [ "$(fm_task_inbox_record_harness "$rec")" = codex ] || return 1
      fi
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 1
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      sleep 0.3
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 0
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      return 0
      ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 2 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

# Whether the composer's content, ignoring line wrapping, is one or more whole
# copies of <line> and nothing else.
fm_task_inbox_composer_holds() {  # <backend> <target> <line> [expected-label]
  local cap held line
  fm_backend_source "$1" || return 1
  cap=$(fm_backend_capture "$1" "$2" "$FM_COMPOSER_CAPTURE_LINES" "${4:-}" 2>/dev/null) || return 1
  held=$(fm_composer_extract_selected_content styled=0 "$cap") || return 1
  held=$(printf '%s' "$held" | tr -d '[:space:]')
  line=$(printf '%s' "$3" | tr -d '[:space:]')
  [ -n "$held" ] && [ -n "$line" ] || return 1
  while [ "${held#"$line"}" != "$held" ]; do
    held=${held#"$line"}
  done
  [ -z "$held" ]
}

# The harness recorded for the task that owns <record-path>, from the task's
# own meta beside its inbox; empty when the meta or field is absent.
fm_task_inbox_record_harness() {  # <record-path>
  local dir=${1%/*} task
  dir=${dir%/handled}
  task=${dir##*/}
  task=${task%.inbox}
  fm_meta_get "${dir%/*}/$task.meta" harness
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Every unhandled record name in <inbox-dir>, fire-and-forget included, one
# per line in sequence order.
fm_task_inbox_records_in() {  # <inbox-dir>
  local f n
  for f in "$1"/*.msg; do
    [ -e "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    printf '%s\t%s\n' "$n" "${f##*/}"
  done | sort -n | cut -f2
}

# Whether <record-path> is one its inbox already escalated.
fm_task_inbox_record_is_escalated() {  # <record-path>
  grep -Fqx -- "${1##*/}" "${1%/*}/.escalated" 2>/dev/null
}

# Every unhandled record name in <inbox-dir> its inbox has not escalated,
# fire-and-forget included, one per line in sequence order, read in one pass
# so a caller's work does not grow with the escalated records ahead.
fm_task_inbox_unescalated_in() {  # <inbox-dir>
  fm_task_inbox_records_in "$1" | awk -v f="$1/.escalated" '
    BEGIN { while ((getline n < f) > 0) esc[n] = 1 }
    !($0 in esc)'
}

# The lowest escalation-tracked record path in <inbox-dir> not yet escalated,
# or nothing when every waiting record already escalated.
fm_task_inbox_next_unescalated() {  # <inbox-dir>
  local name
  fm_task_inbox_records_in "$1" | while IFS= read -r name; do
    fm_task_inbox_is_fire_and_forget "$1/$name" && continue
    fm_task_inbox_record_is_escalated "$1/$name" && continue
    printf '%s/%s' "$1" "$name"
    break
  done
}

# Owe a fire-and-forget record its one retry ring (see the header). A newer
# mark replaces an older one: a ring names the whole inbox, not one record.
fm_task_inbox_mark_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  { printf '%s\n' "${3##*/}" > "$dir/.retry-ring"; } 2>/dev/null
}

# Spend the retry mark after its ring, only while it still names that record:
# a newer mark written meanwhile is owed its own retry and survives. Fails only
# when the processed record's mark stays behind.
fm_task_inbox_clear_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ "$(cat "$dir/.retry-ring" 2>/dev/null)" = "${3##*/}" ] || return 0
  rm -f "$dir/.retry-ring" 2>/dev/null
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or every waiting record already escalated)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   retry <record-path>       a fire-and-forget record's one retry ring is due
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.busy-state" "$dir/.recover-state" 2>/dev/null || true
    # The one retry ring exists only while config/wait-no-turns is present.
    # Absent, a mark is left untouched and the inbox stays quiet, as before.
    if [ -e "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/wait-no-turns" ]; then
      base=$(cat "$dir/.retry-ring" 2>/dev/null || true)
      if ! fm_task_inbox_seq_of "$base" >/dev/null || [ ! -f "$dir/$base" ]; then
        rm -f "$dir/.retry-ring" 2>/dev/null || true
      elif [ "$(fm_path_age "$dir/.retry-ring")" -ge "$(fm_task_inbox_grace_secs)" ]; then
        printf 'retry %s' "$dir/$base"
        return 0
      fi
    fi
    printf 'quiet'
    return 0
  fi
  # An escalated record stays with recovery; the ladder moves to the next one,
  # so a stuck record never silences the records behind it.
  oldest=$(fm_task_inbox_next_unescalated "$dir")
  if [ -z "$oldest" ]; then
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

FM_TASK_INBOX_RECOVER_MAX=2

# Recovery slots already claimed for <record-path> in worker generation
# <spawn-gen>; a different record or generation has claimed none.
_fm_task_inbox_recover_count() {  # <state-dir> <task-id> <record-path> <spawn-gen>
  local gen=$4 state rec_base count last rec_gen
  case "$gen" in *[!A-Za-z0-9._:-]*) gen=invalid ;; esac
  state=$(cat "$(fm_task_inbox_dir "$1" "$2")/.recover-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last rec_gen <<EOF
$state
EOF
  { [ "$rec_base" = "${3##*/}" ] && [ "$rec_gen" = "$gen" ]; } || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s' "$count"
}

# Whether both automatic recovery slots for <record-path> are spent.
fm_task_inbox_recover_spent() {  # <state-dir> <task-id> <record-path> <spawn-gen>
  [ "$(_fm_task_inbox_recover_count "$@")" -ge "$FM_TASK_INBOX_RECOVER_MAX" ]
}

# Claim the next automatic recovery slot for <record-path>, the ladder's record:
# persist it, restart that record's ladder and busy budget, and print the slot
# number (1 or 2). A different record or a different worker generation starts
# a fresh budget. Returns 1 when both slots are spent and 2 when the budget or
# ladder cannot be written; neither claims a slot.
fm_task_inbox_recover_next() {  # <state-dir> <task-id> <record-path> <spawn-gen>
  local dir base gen=$4 count now
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  case "$gen" in *[!A-Za-z0-9._:-]*) gen=invalid ;; esac
  count=$(_fm_task_inbox_recover_count "$1" "$2" "$3" "$gen")
  [ "$count" -lt "$FM_TASK_INBOX_RECOVER_MAX" ] || return 1
  now=$(date +%s)
  # The slot is written last, so a failed restart never leaves it claimed.
  { printf '%s\t0\t%s\n' "$base" "$now" > "$dir/.ring-state"; } 2>/dev/null || return 2
  rm -f "$dir/.busy-state" 2>/dev/null || return 2
  { printf '%s\t%s\t%s\t%s\n' "$base" "$((count + 1))" "$now" "$gen" > "$dir/.recover-state"; } 2>/dev/null || return 2
  printf '%s' "$((count + 1))"
}

# Whether the parent status log already holds an answer to this exact record:
# a line carrying the record's own corr token, stamped no earlier than the
# record was enqueued. A record without a token never qualifies.
fm_task_inbox_record_answered() {  # <state-dir> <task-id> <record-path>
  local corr enq
  corr=$(fm_task_inbox_body "$3" 2>/dev/null | grep -o 'corr=[A-Za-z0-9]*' | head -n 1)
  corr=${corr#corr=}
  [ -n "$corr" ] || return 1
  enq=$(( $(date +%s) - $(fm_path_age "$3") ))
  awk -v c="corr=$corr" -v e="$enq" '
    $0 ~ (c "([^A-Za-z0-9]|$)") && match($0, /\[at=[0-9]+\]/) {
      if (substr($0, RSTART + 4, RLENGTH - 5) + 0 >= e) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$1/$2.status" 2>/dev/null
}

# Mark the record as escalated after its stale wake is durably queued,
# suppressing another wake for it on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" >> "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
