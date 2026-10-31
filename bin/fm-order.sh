#!/usr/bin/env bash
# fm-order.sh - durable captain orders and holds: the shared send, pickup, and leash helper.
#
# An order is work a sender (the box leash, a client-bot routine, a nightly job)
# hands to this home's primary firstmate, the captain session. The order is a
# FILE; typing into the captain's terminal is only a nudge. A captain restart
# therefore cannot lose an order: whichever captain session runs next finds the
# file at session start and acknowledges it before acting.
#
# This is ONE way to send an order, not the only one. Typing straight into the
# captain terminal and `bin/fm-inbox.sh note` keep working unchanged, and the
# captain acts on them as before; nothing here rejects or rewrites them.
#
# Usage:
#   fm-order.sh send [--hold] [--from <sender>] [--no-nudge] [--] <text>... | -
#   fm-order.sh resend [--no-nudge] <id>
#   fm-order.sh status [--json] [<id>]
#   fm-order.sh pickup
#   fm-order.sh ack <id>
#   fm-order.sh show <id>
#   fm-order.sh finish <id> done|parked [--] <outcome>... | -
#   fm-order.sh holds [--relay]
#   fm-order.sh handoff --doc <file>
#   fm-order.sh gate
#   fm-order.sh claim-handle
#   fm-order.sh sweep
#
# LIFECYCLE. An order lives in exactly one directory under data/orders/ and
# moves forward only, by rename:
#   pending/<id>.order   sent, not yet read by any captain session
#   acked/<id>.order     read by a captain session (`ack`), not yet finished
#   done/<id>.order      finished; done/<id>.outcome holds the outcome text
#   parked/<id>.order    deliberately set aside; parked/<id>.outcome says why
# `acked` is receipt and `done`/`parked` is completion, so a sender can tell
# the two apart (`status`). No acknowledgement means not delivered.
#
# ORDER FILE. key=value header lines, a `--` line, then the body bytes:
#   id=<epoch>-<sha8>  sha256=<hex of body>  at=<UTC ISO time>  from=<sender>
#   kind=order|hold
# The id is the send time plus the first 8 hex digits of the body's sha256;
# when that id is already taken (an order and a hold with the same text in the
# same second) the send time moves to the next free second.
#
# HOLDS. `send --hold` records a standing limit such as "close nothing". A hold
# is in force from the moment it is sent until a captain session lifts it with
# `finish <id> done|parked <outcome>`. A hold overrides every OLDER order and
# every council ruling: `ack` and `show` of an order list each hold in force
# and mark the newer ones as overriding it, and `pickup` lists holds first.
# Holds travel with every relayed order. The `holds --relay` block, which
# starts with the line bin/fm-task-inbox-lib.sh names FM_TASK_INBOX_HOLDS_HEAD,
# is appended by bin/fm-send.sh to every text steer (on one line for a typed
# send to an explicit target) and by bin/fm-spawn.sh to every worker launch
# brief and secondmate charter launch. A parser command (a leading "/", or "$"
# to codex) typed straight to an endpoint carries no block. The idempotent
# inbox write ignores the block, so a retried steer still matches its first
# record after a hold changes.
#
# EVENT LOG. data/orders/log.tsv is append-only, one tab-separated row per
# event: <UTC ISO> <epoch> <id> <event> <sha8> <detail>. Events:
#   sent, replay, delivered, resent, redelivered, acked (detail started=<UTC>),
#   skip, done, parked, escalated, escalate-failed.
# Delivery counts, the last delivery time, and the escalation marker are read
# from this log, so they survive any restart.
#
# IDEMPOTENCY. `send` of a body whose sha256 matches an open (pending or
# acked) order of the same kind prints `replay <id>` and creates nothing, so a
# sender retry never makes a second order. `resend <id>` points at the same
# file and only nudges again. `ack <id>` moves the file with one rename: of two
# sessions acking at once, exactly one prints `acked`; every other attempt, and
# any ack of an id already in acked/, done/, or parked/, prints
# `skip <id> <state>` and exits 0. A captain that sees `skip` must not run the
# order again.
#
# NUDGE AND HANDLE. Every send, resend, and re-delivery appends one
# `check: captain order <id>` wake to this home's wake queue (bin/fm-wake-lib.sh)
# and, unless --no-nudge, types one constant doorbell line into the CURRENT
# captain handle. The handle is read from state/captain-handle at send time,
# never cached by a sender: each captain session records its own terminal there
# at session start (`claim-handle`, run by bin/fm-session-start.sh on a locked
# start), so the newest captain always wins. The doorbell rings only when the
# terminal is alive and its composer is proven empty; any other composer state
# defers it, so a draft is never overwritten. The order file and the wake carry
# the order either way. Nudge outcomes print as
#   nudge=sent|deferred|dead|failed|none (none: no handle recorded or --no-nudge).
# FM_ORDER_NUDGE_CMD, when set, replaces the terminal send: it runs as
# `$FM_ORDER_NUDGE_CMD <backend> <target> <line>` (tests and custom transports).
#
# PICKUP. `pickup` prints every hold in force, then every open order, oldest
# first, and the commands to act on them; bin/fm-session-start.sh prints it as
# the CAPTAIN ORDERS section, so a new captain's first digest names each one.
#
# RESTART GATE. The handoff document is the proof. `handoff --doc <file>`
# appends the block of open orders to the session handoff document, at any
# path, and records that path in state/.order-handoff, which marks this session
# as handing off. `gate` reads the recorded document and exits 0 only when it
# names every open order id; otherwise it exits 3 naming the missing ids,
# including when this session recorded no handoff or the document is gone.
# `claim-handle` at session start clears the record, so a document written by
# an earlier session never satisfies a later session's gate. Enforcement:
#   - bin/fm-handoff-trigger.sh, as a Claude Stop hook, runs `gate` once the
#     session is handing off - the early handoff trigger fired in its context
#     cycle, or it ran `handoff --doc` (stow, a restart, or percent-left=0) -
#     and blocks a stop whose document omits an open order (once per turn, so
#     the session is never wedged). An ordinary stop is never gated.
#   - the stow skill and a restarting leash or sender run `gate` and do not
#     reset or restart the captain while it exits 3.
# Limits: the Stop hook is Claude-only, so nothing gates a non-Claude primary,
# a session that never runs `handoff --doc`, a human `/quit`, a crash, or a
# restart by a tool that does not run `gate`. None of those loses an order,
# because the files stay in pending/ or acked/ and the next session's digest
# lists them.
#
# SENDER RE-CHECK AND LEASH. `status` prints, per order, its kind, state, age
# since send, deliveries, re-deliveries against the cap, and `resend_due=yes`
# when it is still pending FM_ORDER_RECHECK_SECS (900) after its last delivery.
# A sender re-checks its order about 15 minutes after sending and runs
# `resend <id>` when it is still pending. `sweep` re-delivers an order still
# pending FM_ORDER_REDELIVER_SECS (1800) after its last delivery or re-delivery
# (a sender's `resend` does not reset that clock) to the newest handle, at most
# twice; at the next due point after the last
# re-delivery it is escalated ONCE through bin/fm-self-heal-issue.sh
# (Pibomeister/firstmate, failure class captain-order-undelivered) and also
# woken as a check. An escalation that fails is logged as escalate-failed and is
# not retried, so the sweep never loops. The issue carries the id, sha, age, and
# delivery counts, never the order body. FM_ORDER_SELF_HEAL_BIN replaces the
# filing command (tests). The supervision watcher (bin/fm-watch.sh) runs
# `sweep` in the background at most once a minute while any order is pending;
# an external leash may run it as well. One sweep runs at a time per home
# (data/orders/.sweep.lock): a sweep that finds another running prints
# `sweep: another sweep is running` and exits 0, so two runners never exceed
# the cap or escalate twice.
#
# Exit status: 0 success; 1 failure; 2 invalid use; 3 `gate` blocked, or a
# send/resend that saved the order but could not append its wake.
#
# Environment:
#   FM_HOME              operational home whose data/ and state/ are used
#   FM_DATA_OVERRIDE, FM_STATE_OVERRIDE  directory overrides
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bash-compat-lib.sh
. "$SELF_DIR/fm-bash-compat-lib.sh"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ORDERS="$DATA/orders"
LOG="$ORDERS/log.tsv"
SHA_DIR="$ORDERS/.sha"
HANDLE_FILE="$STATE/captain-handle"
HANDOFF_RECORD="$STATE/.order-handoff"
STATES='pending acked done parked'
ESCALATION_REPO=Pibomeister/firstmate
# The relay block's first words; bin/fm-task-inbox-lib.sh's
# FM_TASK_INBOX_HOLDS_HEAD must stay equal, because it finds the block by them.
HOLDS_HEAD='Standing captain holds'

num_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
RECHECK_SECS=$(num_or "${FM_ORDER_RECHECK_SECS:-}" 900)
REDELIVER_SECS=$(num_or "${FM_ORDER_REDELIVER_SECS:-}" 1800)
REDELIVER_MAX=2
NUDGE_BUDGET_SECS=20

die() { printf 'fm-order: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'fm-order: %s\n' "$*" >&2; exit 2; }

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha256_of_file() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "neither shasum nor sha256sum is available"
  fi
}

ensure_dirs() {
  local s
  for s in $STATES; do mkdir -p "$ORDERS/$s"; done
  mkdir -p "$SHA_DIR"
}

valid_id() {
  case "$1" in
    [0-9]*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  case "${1%-*}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

log_event() {  # <id> <event> <sha8> [detail]
  local detail=${4:-}
  detail=$(printf '%s' "$detail" | tr '\t\n\r' '   ')
  mkdir -p "$ORDERS"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(now_iso)" "$(now_epoch)" "$1" "$2" "$3" "$detail" >>"$LOG"
}

# Print the state directory name holding <id>, or return 1.
order_state() {  # <id>
  local s
  for s in $STATES; do
    if [ -f "$ORDERS/$s/$1.order" ]; then
      printf '%s\n' "$s"
      return 0
    fi
  done
  return 1
}

order_file() {  # <id>
  local s
  s=$(order_state "$1") || return 1
  printf '%s\n' "$ORDERS/$s/$1.order"
}

header_get() {  # <file> <key>
  sed -n "/^--\$/q;s/^$2=//p" "$1" | head -n 1
}

order_kind() {  # <file>
  case "$(header_get "$1" kind)" in hold) printf 'hold\n' ;; *) printf 'order\n' ;; esac
}

order_body() {  # <file>
  awk 'found { print; next } /^--$/ { found=1 }' "$1"
}

order_oneline() {  # <file>
  order_body "$1" | tr '\n\t' '  ' | sed 's/[[:space:]]*$//'
}

order_summary() {  # <file>
  order_oneline "$1" | cut -c1-100
}

# The idempotency reservation path for a body of <kind> with <sha256>.
reservation() {  # <kind> <sha256>
  if [ "$1" = hold ]; then printf '%s\n' "$SHA_DIR/hold-$2"; else printf '%s\n' "$SHA_DIR/$2"; fi
}

read_body_args() {  # <args...> -> body on stdout (a lone "-" reads stdin)
  if [ "$#" -eq 1 ] && [ "$1" = - ]; then
    local body
    body=$(cat; printf .)
    printf '%s' "${body%.}"
  else
    printf '%s' "$*"
  fi
}

# Write an order file for <body> into <dest-dir>/<id>.order atomically.
write_order() {  # <dest-dir> <id> <sha256> <from> <kind> <body-file>
  local dir=$1 id=$2 sha=$3 from=$4 kind=$5 bodyf=$6 tmp
  tmp=$(mktemp "$ORDERS/.staging-XXXXXX")
  {
    printf 'id=%s\n' "$id"
    printf 'sha256=%s\n' "$sha"
    printf 'at=%s\n' "$(now_iso)"
    printf 'from=%s\n' "$from"
    printf 'kind=%s\n' "$kind"
    printf -- '--\n'
    cat "$bodyf"
    [ -z "$(tail -c 1 "$bodyf")" ] || printf '\n'
  } >"$tmp"
  mv "$tmp" "$dir/$id.order"
}

# Log-derived delivery facts for <id>:
#   "<deliveries> <redeliveries> <last-any-delivery> <last-leash-delivery> <escalation>".
# The leash clock counts only the original delivery and re-deliveries, so a
# sender's resend never postpones a re-delivery or the escalation.
delivery_facts() {  # <id>
  [ -f "$LOG" ] || { printf '0 0 0 0 none\n'; return 0; }
  awk -F '\t' -v id="$1" '
    $3 == id {
      if ($4 == "delivered" || $4 == "resent" || $4 == "redelivered") { d++; last = $2 }
      if ($4 == "delivered" || $4 == "redelivered") leash = $2
      if ($4 == "redelivered") r++
      if ($4 == "escalated" || $4 == "escalate-failed") esc = $4
    }
    END { printf "%d %d %d %d %s\n", d, r, last + 0, leash + 0, (esc == "" ? "none" : esc) }
  ' "$LOG"
}

# ---------------------------------------------------------------- handle

# Record this process's captain terminal as the current handle, and clear the
# previous session's handoff record. Run by bin/fm-session-start.sh on a locked
# start, from inside the captain session.
cmd_claim_handle() {
  local backend target rc=0 tmp
  rm -f "$HANDOFF_RECORD"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SELF_DIR/fm-supervisor-target-lib.sh"
  if [ -r "$SELF_DIR/fm-backend.sh" ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$SELF_DIR/fm-backend.sh" >/dev/null 2>&1 || true
  fi
  target=$(discover_supervisor_target 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$target" ]; then
    rm -f "$HANDLE_FILE"
    printf 'handle: none (this session has no resolvable captain terminal)\n'
    return 0
  fi
  backend=$(discover_supervisor_backend 2>/dev/null) || backend=
  [ -n "$backend" ] || { rm -f "$HANDLE_FILE"; printf 'handle: none\n'; return 0; }
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.captain-handle.XXXXXX")
  printf 'backend=%s\ntarget=%s\nat=%s\n' "$backend" "$target" "$(now_epoch)" >"$tmp"
  mv "$tmp" "$HANDLE_FILE"
  printf 'handle: %s:%s\n' "$backend" "$target"
}

# Print "<backend> <target>" for the current captain handle, or return 1.
current_handle() {
  local backend target
  [ -r "$HANDLE_FILE" ] || return 1
  backend=$(sed -n 's/^backend=//p' "$HANDLE_FILE" | head -n 1)
  target=$(sed -n 's/^target=//p' "$HANDLE_FILE" | head -n 1)
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  printf '%s %s\n' "$backend" "$target"
}

# ---------------------------------------------------------------- nudge

doorbell_line() {  # <id>
  printf ': Firstmate captain order %s waiting: run bin/fm-order.sh pickup, ack it, act on it, then finish it.' "$1"
}

_ring_once() {  # <backend> <target> <line>
  local backend=$1 target=$2 line=$3 verdict
  # shellcheck source=bin/fm-backend.sh
  . "$SELF_DIR/fm-backend.sh" >/dev/null 2>&1 || return 2
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  # Ring only into a composer proven empty: pending, pending-unproven, and
  # unknown may all hold someone's draft, so each defers the doorbell.
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || printf unknown)" = empty ] || return 1
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 2 0.4 0.3 2>/dev/null) || return 2
  [ "$verdict" != send-failed ] || return 2
  return 0
}

# Ring the current handle once, bounded. Prints the nudge outcome word.
nudge() {  # <id> <no-nudge 0|1>
  local h backend target line rc=0
  if [ "$2" -eq 1 ] || ! h=$(current_handle); then
    printf 'none'
    return 0
  fi
  backend=${h%% *}
  target=${h#* }
  line=$(doorbell_line "$1")
  if [ -n "${FM_ORDER_NUDGE_CMD:-}" ]; then
    $FM_ORDER_NUDGE_CMD "$backend" "$target" "$line" >/dev/null 2>&1 || rc=$?
  else
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SELF_DIR/fm-timeout-lib.sh"
    fm_run_timed_fn "$NUDGE_BUDGET_SECS" _ring_once "$backend" "$target" "$line" || rc=$?
  fi
  case "$rc" in
    0) printf 'sent' ;;
    1) printf 'deferred' ;;
    3) printf 'dead' ;;
    *) printf 'failed' ;;
  esac
}

# Append the durable wake for <id>. Returns nonzero when it could not.
wake() {  # <id> <payload>
  local lib="$SELF_DIR/fm-wake-lib.sh"
  [ -r "$lib" ] || return 1
  (
    FM_ROOT_OVERRIDE=$FM_ROOT
    # shellcheck source=bin/fm-wake-lib.sh
    . "$lib"
    mkdir -p "$STATE"
    fm_wake_append check "order:$1" "$2"
  ) >/dev/null 2>&1
}

# Deliver <id> once: wake plus nudge, logged as <event>. Prints the outcome line.
deliver() {  # <id> <event> <no-nudge> <outcome>
  local id=$1 event=$2 no_nudge=$3 outcome=$4 file sha8 from kind summary woke=1 nudged rc=0
  file=$(order_file "$id")
  sha8=${id##*-}
  from=$(header_get "$file" from)
  kind=$(order_kind "$file")
  summary=$(order_summary "$file")
  wake "$id" "check: captain $kind $id from ${from:-unknown} - $summary" || { woke=0; rc=3; }
  nudged=$(nudge "$id" "$no_nudge")
  log_event "$id" "$event" "$sha8" "wake=$woke nudge=$nudged"
  printf '%s %s\n  kind=%s state=%s wake=%s nudge=%s\n' "$outcome" "$id" "$kind" "$(order_state "$id")" \
    "$([ "$woke" -eq 1 ] && printf ok || printf FAILED)" "$nudged"
  [ "$woke" -eq 1 ] || printf 'fm-order: order %s is saved but its wake could not be appended\n' "$id" >&2
  return "$rc"
}

# ---------------------------------------------------------------- send

cmd_send() {
  local from=unknown kind=order no_nudge=0 bodyf sha sha8 id reserved existing state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || usage_die "send: --from needs a value"; from=$2; shift 2 ;;
      --hold) kind=hold; shift ;;
      --no-nudge) no_nudge=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || usage_die "usage: fm-order.sh send [--hold] [--from <sender>] [--no-nudge] [--] <text>... | -"
  case "$from" in *[!A-Za-z0-9._:@/-]*|'') usage_die "send: --from takes A-Za-z0-9._:@/- only" ;; esac
  ensure_dirs
  bodyf=$(mktemp "$ORDERS/.body-XXXXXX")
  read_body_args "$@" >"$bodyf"
  if [ -z "$(tr -d '[:space:]' <"$bodyf")" ]; then
    rm -f "$bodyf"
    usage_die "refusing to send an empty order"
  fi
  sha=$(sha256_of_file "$bodyf")
  sha8=$(printf '%s' "$sha" | cut -c1-8)
  reserved=$(reservation "$kind" "$sha")
  local _attempt ts
  for _attempt in 1 2; do
    # An order and a hold with the same text share a sha8, so claim an id no
    # other order has ever used; a taken second moves to the next one.
    ts=$(now_epoch)
    while ! ( set -C; : >"$SHA_DIR/id-$ts-$sha8" ) 2>/dev/null; do ts=$((ts + 1)); done
    id="$ts-$sha8"
    if ( set -C; printf '%s\n' "$id" >"$reserved" ) 2>/dev/null; then
      write_order "$ORDERS/pending" "$id" "$sha" "$from" "$kind" "$bodyf"
      rm -f "$bodyf"
      log_event "$id" sent "$sha8" "from=$from kind=$kind"
      deliver "$id" delivered "$no_nudge" queued
      return $?
    fi
    rm -f "$SHA_DIR/id-$id"
    existing=$(head -n 1 "$reserved" 2>/dev/null || true)
    if valid_id "$existing" && state=$(order_state "$existing"); then
      case "$state" in
        pending|acked)
          rm -f "$bodyf"
          log_event "$existing" replay "$sha8" "from=$from"
          printf 'replay %s\n  kind=%s state=%s (the same %s is already open; nothing new was created)\n' \
            "$existing" "$kind" "$state" "$kind"
          return 0
          ;;
      esac
    elif valid_id "$existing" && [ "${existing##*-}" = "$sha8" ]; then
      # Reserved but never published (a crash between the two steps): publish
      # it now under the reserved id, which names these same body bytes.
      write_order "$ORDERS/pending" "$existing" "$sha" "$from" "$kind" "$bodyf"
      rm -f "$bodyf"
      log_event "$existing" sent "$sha8" "from=$from kind=$kind recovered-reservation"
      deliver "$existing" delivered "$no_nudge" queued
      return $?
    fi
    # A finished order left its reservation behind: the same text sent again is a new order.
    rm -f "$reserved"
  done
  rm -f "$bodyf"
  die "could not reserve order $sha8; retry"
}

cmd_resend() {
  local no_nudge=0 id state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-nudge) no_nudge=1; shift ;;
      *) break ;;
    esac
  done
  id=${1:-}
  valid_id "$id" || usage_die "usage: fm-order.sh resend [--no-nudge] <id>"
  state=$(order_state "$id") || die "no such order: $id"
  if [ "$state" != pending ]; then
    printf '%s %s\n  already %s; nothing to resend\n' "$state" "$id" "$state"
    return 0
  fi
  deliver "$id" resent "$no_nudge" resent
}

# ---------------------------------------------------------------- holds

# Holds in force (open: pending or acked), newest first, one "<id> <state>" per line.
holds_in_force() {
  local s f
  for s in pending acked; do
    [ -d "$ORDERS/$s" ] || continue
    for f in "$ORDERS/$s"/*.order; do
      [ -f "$f" ] || continue
      [ "$(order_kind "$f")" = hold ] || continue
      f=${f##*/}
      printf '%s %s\n' "${f%.order}" "$s"
    done
  done | sort -t - -k1,1nr
}

cmd_holds() {
  local relay=0 lines id state file now
  case "${1:-}" in
    --relay) relay=1 ;;
    '') ;;
    *) usage_die "usage: fm-order.sh holds [--relay]" ;;
  esac
  lines=$(holds_in_force)
  if [ -z "$lines" ]; then
    [ "$relay" -eq 1 ] || printf 'no holds in force\n'
    return 0
  fi
  if [ "$relay" -eq 1 ]; then
    printf '%s (newest first). Each overrides any older order or council ruling, including anything above that conflicts with it. Carry every hold into any instruction you relay:\n' "$HOLDS_HEAD"
    while read -r id state; do
      [ -n "$id" ] || continue
      file="$ORDERS/$state/$id.order"
      printf -- '- hold %s, set %s: %s\n' "$id" "$(header_get "$file" at)" "$(order_oneline "$file")"
    done <<EOF
$lines
EOF
    return 0
  fi
  now=$(now_epoch)
  printf 'Holds in force, newest first. A hold overrides every older order and every council ruling; relay nothing that contradicts one:\n'
  while read -r id state; do
    [ -n "$id" ] || continue
    file="$ORDERS/$state/$id.order"
    printf '  %s %s age=%s from=%s :: %s\n' "$id" "$state" "$(age_text $((now - ${id%-*})))" \
      "$(header_get "$file" from)" "$(order_summary "$file")"
  done <<EOF
$lines
EOF
  printf 'Lift a hold with: bin/fm-order.sh finish <id> done|parked <outcome>\n'
}

# For the order <id>, list every OTHER hold in force and whether it is newer.
holds_against() {  # <id>
  local self=$1 lines id state file mark
  lines=$(holds_in_force | awk -v self="$self" '$1 != self')
  [ -n "$lines" ] || return 0
  printf 'Holds in force (a newer hold overrides this order; carry every hold when relaying it):\n'
  while read -r id state; do
    [ -n "$id" ] || continue
    file="$ORDERS/$state/$id.order"
    if [ "${id%-*}" -ge "${self%-*}" ]; then mark='NEWER - overrides this order'; else mark='older - still in force'; fi
    printf '  %s %s :: %s\n' "$id" "$mark" "$(order_summary "$file")"
  done <<EOF
$lines
EOF
}

# ---------------------------------------------------------------- captain side

cmd_ack() {
  local id=${1:-} state file kind
  valid_id "$id" || usage_die "usage: fm-order.sh ack <id>"
  ensure_dirs
  if mv "$ORDERS/pending/$id.order" "$ORDERS/acked/$id.order" 2>/dev/null; then
    log_event "$id" acked "${id##*-}" "started=$(now_iso)"
    file="$ORDERS/acked/$id.order"
    kind=$(order_kind "$file")
    printf 'acked %s\n  kind=%s from=%s at=%s\n--\n' "$id" "$kind" "$(header_get "$file" from)" "$(header_get "$file" at)"
    order_body "$file"
    printf -- '--\n'
    holds_against "$id"
    if [ "$kind" = hold ]; then
      printf 'This hold stays in force until lifted: bin/fm-order.sh finish %s done|parked <outcome>\n' "$id"
    else
      printf 'When finished: bin/fm-order.sh finish %s done|parked <outcome>\n' "$id"
    fi
    return 0
  fi
  state=$(order_state "$id") || die "no such order: $id"
  log_event "$id" skip "${id##*-}" "state=$state"
  printf 'skip %s %s\n  already acknowledged by a captain session; do not run it again.\n' "$id" "$state"
  [ "$state" != acked ] || printf '  It is not finished: check whether its work started, then finish it.\n'
  return 0
}

cmd_show() {
  local id=${1:-} file state
  valid_id "$id" || usage_die "usage: fm-order.sh show <id>"
  file=$(order_file "$id") || die "no such order: $id"
  state=$(order_state "$id")
  sed -n '/^--$/q;p' "$file"
  printf 'state=%s\n--\n' "$state"
  order_body "$file"
  if [ -f "${file%.order}.outcome" ]; then
    printf -- '-- outcome\n'
    cat "${file%.order}.outcome"
  fi
  case "$state" in pending|acked) holds_against "$id" ;; esac
}

cmd_finish() {
  local id=${1:-} result=${2:-} state outcome sha file reserved
  valid_id "$id" || usage_die "usage: fm-order.sh finish <id> done|parked [--] <outcome>..."
  case "$result" in done|parked) ;; *) usage_die "finish: result must be done or parked" ;; esac
  shift 2
  [ "${1:-}" != -- ] || shift
  [ "$#" -gt 0 ] || usage_die "finish: an outcome is required"
  outcome=$(read_body_args "$@")
  [ -n "${outcome//[[:space:]]/}" ] || usage_die "finish: an outcome is required"
  state=$(order_state "$id") || die "no such order: $id"
  case "$state" in
    done|parked) printf 'already %s %s\n' "$state" "$id"; return 0 ;;
    pending) die "order $id is not acknowledged yet; run: bin/fm-order.sh ack $id" ;;
  esac
  file="$ORDERS/acked/$id.order"
  sha=$(header_get "$file" sha256)
  reserved=
  [ -z "$sha" ] || reserved=$(reservation "$(order_kind "$file")" "$sha")
  printf '%s\n' "$outcome" >"$ORDERS/$result/$id.outcome"
  mv "$file" "$ORDERS/$result/$id.order"
  # Free the idempotency reservation only when it names this order, so
  # finishing one order never lets a retry duplicate another open one.
  if [ -n "$reserved" ] && [ "$(head -n 1 "$reserved" 2>/dev/null || true)" = "$id" ]; then
    rm -f "$reserved"
  fi
  log_event "$id" "$result" "${id##*-}" "$(printf '%s' "$outcome" | head -c 200)"
  printf '%s %s\n' "$result" "$id"
}

# Open order ids, oldest first, one per line as "<id> <state>".
open_orders() {
  local s f
  for s in pending acked; do
    [ -d "$ORDERS/$s" ] || continue
    for f in "$ORDERS/$s"/*.order; do
      [ -f "$f" ] || continue
      f=${f##*/}
      printf '%s %s\n' "${f%.order}" "$s"
    done
  done | sort -t - -k1,1n
}

age_text() {  # <seconds>
  local s=$1
  if [ "$s" -lt 120 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 7200 ]; then printf '%sm' "$((s / 60))"
  else printf '%sh%sm' "$((s / 3600))" "$((s % 3600 / 60))"
  fi
}

cmd_pickup() {
  local lines id state file now n=0 label kind
  lines=$(open_orders)
  [ -n "$lines" ] || return 0
  now=$(now_epoch)
  [ -z "$(holds_in_force)" ] || { cmd_holds; printf '\n'; }
  while read -r id state; do
    [ -n "$id" ] || continue
    n=$((n + 1))
  done <<EOF
$lines
EOF
  printf '%s open captain order(s) - each is durable; ack it before acting:\n' "$n"
  while read -r id state; do
    [ -n "$id" ] || continue
    file="$ORDERS/$state/$id.order"
    label=$state
    [ "$state" != acked ] || label=acked-unfinished
    kind=$(order_kind "$file")
    printf '  %s %s kind=%s age=%s from=%s :: %s\n' "$id" "$label" "$kind" "$(age_text $((now - ${id%-*})))" \
      "$(header_get "$file" from)" "$(order_summary "$file")"
  done <<EOF
$lines
EOF
  printf 'Pending: bin/fm-order.sh ack <id> reads it (skip means another session already has it - never run it twice).\n'
  printf 'Acked-unfinished: an earlier session read it; bin/fm-order.sh show <id>, check whether its work started, then finish it.\n'
  printf 'Finish each with: bin/fm-order.sh finish <id> done|parked <outcome>\n'
}

cmd_status() {
  local json=0 one='' lines id state file now facts d r last leash esc age due rows=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) one=$1; shift ;;
    esac
  done
  now=$(now_epoch)
  if [ -n "$one" ]; then
    valid_id "$one" || usage_die "status: invalid order id"
    state=$(order_state "$one") || die "no such order: $one"
    lines="$one $state"
  else
    lines=$(open_orders)
  fi
  while read -r id state; do
    [ -n "$id" ] || continue
    file="$ORDERS/$state/$id.order"
    facts=$(delivery_facts "$id")
    read -r d r last leash esc <<EOF
$facts
EOF
    : "$leash"
    age=$((now - ${id%-*}))
    due=no
    if [ "$state" = pending ] && [ "$last" -gt 0 ] && [ $((now - last)) -ge "$RECHECK_SECS" ]; then
      due=yes
    fi
    rows="$rows$id	$state	$age	$d	$r	$esc	$due	$(header_get "$file" from)	$(order_kind "$file")	$(order_summary "$file")
"
  done <<EOF
$lines
EOF
  if [ "$json" -eq 1 ]; then
    printf '%s' "$rows" | python3 -c '
import json, sys
cap = int(sys.argv[1])
out = []
# A summary is cut at a byte or character boundary depending on the platform,
# so decode leniently: one split multibyte character must never fail the call.
for line in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines():
    f = line.split("\t")
    if len(f) < 10:
        continue
    out.append({"id": f[0], "state": f[1], "kind": f[8], "age_secs": int(f[2]),
                "deliveries": int(f[3]), "redeliveries": int(f[4]), "redelivery_cap": cap,
                "escalation": None if f[5] == "none" else f[5],
                "resend_due": f[6] == "yes", "from": f[7], "summary": f[9]})
json.dump({"schema": "fm-order-status.v1", "orders": out}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
' "$REDELIVER_MAX"
    return 0
  fi
  if [ -z "$rows" ]; then
    printf 'no open orders\n'
    return 0
  fi
  printf '%s' "$rows" | while IFS='	' read -r id state age d r esc due from kind summary; do
    printf '%s %s kind=%s age=%s deliveries=%s redeliveries=%s/%s%s resend_due=%s from=%s :: %s\n' \
      "$id" "$state" "$kind" "$(age_text "$age")" "$d" "$r" "$REDELIVER_MAX" \
      "$([ "$esc" = none ] || printf ' %s' "$esc")" "$due" "$from" "$summary"
  done
}

# ---------------------------------------------------------------- restart gate

# The handoff document this session recorded with `handoff --doc`, or nothing.
recorded_handoff_doc() {
  [ -r "$HANDOFF_RECORD" ] || return 0
  sed -n 's/^doc=//p' "$HANDOFF_RECORD" | head -n 1
}

cmd_handoff() {
  local doc block n tmp dir
  [ "$#" -eq 2 ] && [ "$1" = --doc ] && [ -n "$2" ] || usage_die "usage: fm-order.sh handoff --doc <file>"
  doc=$2
  if [ -z "$(open_orders)" ]; then
    block='CAPTAIN ORDERS at handoff: none open.'
  else
    block=$(printf 'CAPTAIN ORDERS at handoff (%s):\n' "$(now_iso)"; cmd_pickup)
  fi
  mkdir -p "$(dirname "$doc")"
  dir=$(cd "$(dirname "$doc")" && pwd)
  doc="$dir/${doc##*/}"
  printf '\n%s\n' "$block" >>"$doc"
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.order-handoff.XXXXXX")
  printf 'doc=%s\nat=%s\n' "$doc" "$(now_epoch)" >"$tmp"
  mv "$tmp" "$HANDOFF_RECORD"
  n=$(open_orders | awk 'NF { n++ } END { print n + 0 }')
  printf 'handoff: wrote %s open order(s) into %s\n' "$n" "$doc"
}

cmd_gate() {
  local doc lines id state missing='' n=0
  [ "$#" -eq 0 ] || usage_die "usage: fm-order.sh gate"
  doc=$(recorded_handoff_doc)
  lines=$(open_orders)
  while read -r id state; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    if [ -z "$doc" ] || [ ! -f "$doc" ] || ! grep -qF -- "$id" "$doc"; then
      missing="$missing $id"
    fi
  done <<EOF
$lines
EOF
  if [ -n "$missing" ]; then
    if [ -z "$doc" ]; then
      printf 'gate: blocked - this session wrote no handoff, so none lists the open order(s):%s\n' "$missing"
    elif [ ! -f "$doc" ]; then
      printf 'gate: blocked - the recorded handoff %s is gone; open order(s):%s\n' "$doc" "$missing"
    else
      printf 'gate: blocked - the handoff %s does not list open order(s):%s\n' "$doc" "$missing"
    fi
    printf '  Run bin/fm-order.sh handoff --doc <handoff file> so the handoff names every open order before restart.\n'
    return 3
  fi
  printf 'gate: clear (%s open order(s), all in the handoff)\n' "$n"
}

# ---------------------------------------------------------------- leash

escalate() {  # <id> <age> <deliveries> <redeliveries>
  local id=$1 bin out rc=0
  bin=${FM_ORDER_SELF_HEAL_BIN:-$SELF_DIR/fm-self-heal-issue.sh}
  out=$("$bin" --repo "$ESCALATION_REPO" --failure-class captain-order-undelivered \
    --title "Captain order $id undelivered after $4 re-deliveries" \
    --instance-fix "Re-delivered $4 time(s) to the newest captain handle; the order stays durable in pending/." \
    --proposed-fix "Find why no captain session acknowledged the order: check the captain handle, the session start pickup, and the leash." \
    --evidence "order=$id sha8=${id##*-} age_secs=$2 deliveries=$3 redeliveries=$4" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_event "$id" escalated "${id##*-}" "$(printf '%s' "$out" | head -n 1)"
    printf 'escalated %s %s\n' "$id" "$(printf '%s' "$out" | head -n 1)"
  else
    log_event "$id" escalate-failed "${id##*-}" "rc=$rc $(printf '%s' "$out" | head -n 1)"
    printf 'escalate-failed %s rc=%s (not retried)\n' "$id" "$rc"
  fi
  wake "$id" "check: captain order $id still unacknowledged after $4 re-deliveries - escalation $([ "$rc" -eq 0 ] && printf filed || printf failed)" || true
}

cmd_sweep() {
  local lines id state now facts d r last leash esc acted=0
  # One sweep at a time per home, so two runners never both read the same
  # re-delivery count and exceed the cap or escalate twice.
  FM_ROOT_OVERRIDE=$FM_ROOT
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SELF_DIR/fm-wake-lib.sh"
  mkdir -p "$ORDERS"
  SWEEP_LOCK="$ORDERS/.sweep.lock"
  if ! fm_lock_try_acquire "$SWEEP_LOCK"; then
    printf 'sweep: another sweep is running\n'
    return 0
  fi
  trap 'fm_lock_release "$SWEEP_LOCK"' EXIT
  lines=$(open_orders)
  now=$(now_epoch)
  while read -r id state; do
    [ -n "$id" ] && [ "$state" = pending ] || continue
    facts=$(delivery_facts "$id")
    read -r d r last leash esc <<EOF
$facts
EOF
    : "$last"
    [ "$leash" -gt 0 ] || leash=${id%-*}
    [ $((now - leash)) -ge "$REDELIVER_SECS" ] || continue
    if [ "$r" -lt "$REDELIVER_MAX" ]; then
      deliver "$id" redelivered 0 redelivered | head -n 1 || true
      acted=1
    elif [ "$esc" = none ]; then
      escalate "$id" "$((now - ${id%-*}))" "$d" "$r"
      acted=1
    fi
  done <<EOF
$lines
EOF
  [ "$acted" -eq 1 ] || printf 'sweep: nothing due\n'
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  send) shift; cmd_send "$@" ;;
  resend) shift; cmd_resend "$@" ;;
  status) shift; cmd_status "$@" ;;
  pickup) shift; cmd_pickup ;;
  ack) shift; cmd_ack "$@" ;;
  show) shift; cmd_show "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  holds) shift; cmd_holds "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  gate) shift; cmd_gate "$@" ;;
  claim-handle) shift; cmd_claim_handle ;;
  sweep) shift; cmd_sweep ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
