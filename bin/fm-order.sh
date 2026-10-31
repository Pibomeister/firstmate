#!/usr/bin/env bash
# fm-order.sh - durable captain orders: the shared send, pickup, and leash helper.
#
# An order is work a sender (the box leash, a client-bot routine, a nightly job)
# hands to this home's primary firstmate, the captain session. The order is a
# FILE; typing into the captain's terminal is only a nudge. A captain restart
# therefore cannot lose an order: whichever captain session runs next finds the
# file at session start and acknowledges it before acting.
#
# This is ONE way to send an order, not the only one. Typing straight into the
# captain terminal and `bin/fm-inbox.sh note` keep working unchanged, and the
# captain acts on them as before. `record-legacy` lets the captain give such a
# legacy order an id when it reads one, which makes it durable from then on.
#
# Usage:
#   fm-order.sh send [--from <sender>] [--no-nudge] [--json] [--] <text>... | -
#   fm-order.sh resend [--no-nudge] [--json] <id>
#   fm-order.sh status [--json] [<id>]
#   fm-order.sh pickup
#   fm-order.sh ack <id>
#   fm-order.sh show <id>
#   fm-order.sh finish <id> done|parked [--] <outcome>... | -
#   fm-order.sh record-legacy [--source <key>] [--] <text>... | -
#   fm-order.sh handoff
#   fm-order.sh gate
#   fm-order.sh claim-handle
#   fm-order.sh handle
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
#   id=<epoch>-<sha8>   sha256=<hex of body>   at=<UTC ISO time>   from=<sender>
# The id is the send time plus the first 8 hex digits of the body's sha256.
#
# EVENT LOG. data/orders/log.tsv is append-only, one tab-separated row per
# event: <UTC ISO> <epoch> <id> <event> <sha8> <detail>. Events:
#   sent, replay, delivered, resent, redelivered, acked (detail started=<UTC>),
#   skip, done, parked, legacy-recorded, escalated, escalate-failed.
# Delivery counts, the last delivery time, and the escalation marker are read
# from this log, so they survive any restart.
#
# IDEMPOTENCY. `send` of a body whose sha256 matches an order that is still
# pending or acked prints `replay <id>` and creates nothing, so a sender retry
# never makes a second order. `resend <id>` points at the same file and only
# nudges again. `ack <id>` moves the file with one rename: of two sessions
# acking at once, exactly one prints `acked`; every other attempt, and any ack
# of an id already in acked/, done/, or parked/, prints `skip <id> <state>` and
# exits 0. A captain that sees `skip` must not run the order again.
#
# NUDGE AND HANDLE. Every send, resend, and re-delivery appends one
# `check: captain order <id>` wake to this home's wake queue (bin/fm-wake-lib.sh)
# and, unless --no-nudge, types one constant doorbell line into the CURRENT
# captain handle. The handle is read from state/captain-handle at send time,
# never cached by a sender: each captain session records its own terminal there
# at session start (`claim-handle`, run by bin/fm-session-start.sh on a locked
# start), so the newest captain always wins. The doorbell is skipped, never
# forced, when the terminal is dead or its composer holds someone's draft; the
# order file and the wake carry the order either way. Nudge outcomes print as
#   nudge=sent|deferred|dead|failed|none (none: no handle recorded or --no-nudge).
# FM_ORDER_NUDGE_CMD, when set, replaces the terminal send: it runs as
# `$FM_ORDER_NUDGE_CMD <backend> <target> <line>` (tests and custom transports).
#
# PICKUP. `pickup` prints every open (pending or acked) order, oldest first,
# and the commands to act on it; bin/fm-session-start.sh prints it as the
# CAPTAIN ORDERS section, so a new captain's first digest names each one.
#
# RESTART GATE. `handoff` writes data/orders/handoff, the manifest of every open
# order at that moment, and prints the block to copy into the session handoff.
# `gate` exits 0 when every open order is named in that manifest and 3, naming
# the missing ids, when one is not. bin/fm-handoff-trigger.sh writes the
# manifest when it fires. What the gate can and cannot stop: a restarting
# sender or leash that runs `gate` first can refuse to restart a captain whose
# handoff omits an order; nothing here can intercept a human `/quit` or a
# crash. Neither of those loses an order, because the files stay in pending/
# or acked/ and the next session's pickup lists them.
#
# SENDER RE-CHECK AND LEASH. `status` prints, per order, its state, age since
# send, deliveries, re-deliveries against the cap, and `resend_due=yes` when it
# is still pending FM_ORDER_RECHECK_SECS (900) after its last delivery. A sender
# re-checks its order about 15 minutes after sending and runs `resend <id>` when
# it is still pending. The leash runs `sweep` every few minutes: an order still
# pending FM_ORDER_REDELIVER_SECS (1800) after its last delivery is re-delivered
# to the newest handle, at most FM_ORDER_REDELIVER_MAX (2) times; at the next
# due point after the last re-delivery it is escalated ONCE through
# bin/fm-self-heal-issue.sh (failure class captain-order-undelivered, repository
# from config/order-escalation-repo, else Pibomeister/firstmate) and also woken
# as a check. An escalation that fails is logged as escalate-failed and is not
# retried, so the sweep never loops. The issue carries the id, sha, age, and
# delivery counts, never the order body. FM_ORDER_SELF_HEAL_BIN replaces the
# filing command (tests).
#
# Exit status: 0 success; 1 failure; 2 invalid use; 3 `gate` blocked, or a
# send/resend that saved the order but could not append its wake.
#
# Environment:
#   FM_HOME              operational home whose data/, state/, config/ are used
#   FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE  directory overrides
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bash-compat-lib.sh
. "$SELF_DIR/fm-bash-compat-lib.sh"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ORDERS="$DATA/orders"
LOG="$ORDERS/log.tsv"
MANIFEST="$ORDERS/handoff"
SHA_DIR="$ORDERS/.sha"
LEGACY_DIR="$ORDERS/.legacy"
HANDLE_FILE="$STATE/captain-handle"
STATES='pending acked done parked'

num_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
RECHECK_SECS=$(num_or "${FM_ORDER_RECHECK_SECS:-}" 900)
REDELIVER_SECS=$(num_or "${FM_ORDER_REDELIVER_SECS:-}" 1800)
REDELIVER_MAX=$(num_or "${FM_ORDER_REDELIVER_MAX:-}" 2)

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
  mkdir -p "$SHA_DIR" "$LEGACY_DIR"
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

order_body() {  # <file>
  awk 'found { print; next } /^--$/ { found=1 }' "$1"
}

order_summary() {  # <file>
  order_body "$1" | tr '\n\t' '  ' | sed 's/[[:space:]]*$//' | cut -c1-100
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
write_order() {  # <dest-dir> <id> <sha256> <from> <body-file>
  local dir=$1 id=$2 sha=$3 from=$4 bodyf=$5 tmp
  tmp=$(mktemp "$ORDERS/.staging-XXXXXX")
  {
    printf 'id=%s\n' "$id"
    printf 'sha256=%s\n' "$sha"
    printf 'at=%s\n' "$(now_iso)"
    printf 'from=%s\n' "$from"
    printf -- '--\n'
    cat "$bodyf"
    [ -z "$(tail -c 1 "$bodyf")" ] || printf '\n'
  } >"$tmp"
  mv "$tmp" "$dir/$id.order"
}

# Log-derived delivery facts for <id>: "<deliveries> <redeliveries> <last-epoch> <escalation>".
delivery_facts() {  # <id>
  [ -f "$LOG" ] || { printf '0 0 0 none\n'; return 0; }
  awk -F '\t' -v id="$1" '
    $3 == id {
      if ($4 == "delivered" || $4 == "resent" || $4 == "redelivered") { d++; last = $2 }
      if ($4 == "redelivered") r++
      if ($4 == "escalated" || $4 == "escalate-failed") esc = $4
    }
    END { printf "%d %d %d %s\n", d, r, last + 0, (esc == "" ? "none" : esc) }
  ' "$LOG"
}

# ---------------------------------------------------------------- handle

# Record this process's captain terminal as the current handle. Run by
# bin/fm-session-start.sh on a locked start, from inside the captain session.
cmd_claim_handle() {
  local backend target rc=0 tmp
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

cmd_handle() {
  local h
  if h=$(current_handle); then
    printf '%s:%s\n' "${h%% *}" "${h#* }"
  else
    printf 'none\n'
    return 1
  fi
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
  case "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || printf unknown)" in
    pending) return 1 ;;
  esac
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
    fm_run_timed_fn "$(num_or "${FM_ORDER_NUDGE_BUDGET:-}" 20)" _ring_once "$backend" "$target" "$line" || rc=$?
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
deliver() {  # <id> <event> <no-nudge> <json> <outcome>
  local id=$1 event=$2 no_nudge=$3 json=$4 outcome=$5 file sha8 from summary woke=1 nudged rc=0
  file=$(order_file "$id")
  sha8=${id##*-}
  from=$(header_get "$file" from)
  summary=$(order_summary "$file")
  wake "$id" "check: captain order $id from ${from:-unknown} - $summary" || { woke=0; rc=3; }
  nudged=$(nudge "$id" "$no_nudge")
  log_event "$id" "$event" "$sha8" "wake=$woke nudge=$nudged"
  if [ "$json" -eq 1 ]; then
    python3 - "$outcome" "$id" "$(order_state "$id")" "$woke" "$nudged" "$file" <<'PY'
import json, sys
outcome, oid, state, woke, nudged, path = sys.argv[1:7]
json.dump({"schema": "fm-order-send.v1", "outcome": outcome, "id": oid,
           "state": state, "woke": woke == "1", "nudge": nudged, "path": path},
          sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
  else
    printf '%s %s\n  state=%s wake=%s nudge=%s\n' "$outcome" "$id" "$(order_state "$id")" \
      "$([ "$woke" -eq 1 ] && printf ok || printf FAILED)" "$nudged"
  fi
  [ "$woke" -eq 1 ] || printf 'fm-order: order %s is saved but its wake could not be appended\n' "$id" >&2
  return "$rc"
}

# ---------------------------------------------------------------- send

cmd_send() {
  local from=${FM_ORDER_FROM:-unknown} no_nudge=0 json=0 body bodyf sha sha8 id reserved existing state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || usage_die "send: --from needs a value"; from=$2; shift 2 ;;
      --no-nudge) no_nudge=1; shift ;;
      --json) json=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || usage_die "usage: fm-order.sh send [--from <sender>] [--no-nudge] [--json] [--] <text>... | -"
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
  reserved="$SHA_DIR/$sha"
  local _attempt
  for _attempt in 1 2; do
    id="$(now_epoch)-$sha8"
    if ( set -C; printf '%s\n' "$id" >"$reserved" ) 2>/dev/null; then
      write_order "$ORDERS/pending" "$id" "$sha" "$from" "$bodyf"
      rm -f "$bodyf"
      log_event "$id" sent "$sha8" "from=$from"
      deliver "$id" delivered "$no_nudge" "$json" queued
      return $?
    fi
    existing=$(head -n 1 "$reserved" 2>/dev/null || true)
    if valid_id "$existing" && state=$(order_state "$existing"); then
      case "$state" in
        pending|acked)
          rm -f "$bodyf"
          log_event "$existing" replay "$sha8" "from=$from"
          if [ "$json" -eq 1 ]; then
            python3 - "$existing" "$state" <<'PY'
import json, sys
json.dump({"schema": "fm-order-send.v1", "outcome": "replay", "id": sys.argv[1],
           "state": sys.argv[2], "woke": None, "nudge": "none"}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
          else
            printf 'replay %s\n  state=%s (the same order is already open; nothing new was created)\n' "$existing" "$state"
          fi
          return 0
          ;;
      esac
    elif valid_id "$existing" && [ "${existing##*-}" = "$sha8" ]; then
      # Reserved but never published (a crash between the two steps): publish
      # it now under the reserved id, which names these same body bytes.
      write_order "$ORDERS/pending" "$existing" "$sha" "$from" "$bodyf"
      rm -f "$bodyf"
      log_event "$existing" sent "$sha8" "from=$from recovered-reservation"
      deliver "$existing" delivered "$no_nudge" "$json" queued
      return $?
    fi
    # A finished order left its reservation behind: the same text sent again is a new order.
    rm -f "$reserved"
  done
  rm -f "$bodyf"
  die "could not reserve order $sha8; retry"
}

cmd_resend() {
  local no_nudge=0 json=0 id state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-nudge) no_nudge=1; shift ;;
      --json) json=1; shift ;;
      *) break ;;
    esac
  done
  id=${1:-}
  valid_id "$id" || usage_die "usage: fm-order.sh resend [--no-nudge] [--json] <id>"
  state=$(order_state "$id") || die "no such order: $id"
  if [ "$state" != pending ]; then
    printf '%s %s\n  already %s; nothing to resend\n' "$state" "$id" "$state"
    return 0
  fi
  deliver "$id" resent "$no_nudge" "$json" resent
}

# ---------------------------------------------------------------- captain side

cmd_ack() {
  local id=${1:-} state file
  valid_id "$id" || usage_die "usage: fm-order.sh ack <id>"
  ensure_dirs
  if mv "$ORDERS/pending/$id.order" "$ORDERS/acked/$id.order" 2>/dev/null; then
    log_event "$id" acked "${id##*-}" "started=$(now_iso)"
    file="$ORDERS/acked/$id.order"
    printf 'acked %s\n  from=%s at=%s\n--\n' "$id" "$(header_get "$file" from)" "$(header_get "$file" at)"
    order_body "$file"
    printf -- '--\nWhen finished: bin/fm-order.sh finish %s done|parked <outcome>\n' "$id"
    return 0
  fi
  state=$(order_state "$id") || die "no such order: $id"
  log_event "$id" skip "${id##*-}" "state=$state"
  printf 'skip %s %s\n  already acknowledged by a captain session; do not run it again.\n' "$id" "$state"
  [ "$state" != acked ] || printf '  It is not finished: check whether its work started, then finish it.\n'
  return 0
}

cmd_show() {
  local id=${1:-} file
  valid_id "$id" || usage_die "usage: fm-order.sh show <id>"
  file=$(order_file "$id") || die "no such order: $id"
  sed -n '/^--$/q;p' "$file"
  printf 'state=%s\n--\n' "$(order_state "$id")"
  order_body "$file"
  if [ -f "${file%.order}.outcome" ]; then
    printf -- '-- outcome\n'
    cat "${file%.order}.outcome"
  fi
}

cmd_finish() {
  local id=${1:-} result=${2:-} state outcome sha
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
  printf '%s\n' "$outcome" >"$ORDERS/$result/$id.outcome"
  sha=$(header_get "$ORDERS/acked/$id.order" sha256)
  mv "$ORDERS/acked/$id.order" "$ORDERS/$result/$id.order"
  [ -z "$sha" ] || rm -f "$SHA_DIR/$sha"
  log_event "$id" "$result" "${id##*-}" "$(printf '%s' "$outcome" | head -c 200)"
  printf '%s %s\n' "$result" "$id"
}

# A legacy order (typed into the terminal, or an inbox note) recorded as a
# durable order that is acknowledged at once, because the captain is reading it.
cmd_record_legacy() {
  local source='' bodyf sha sha8 id key existing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || usage_die "record-legacy: --source needs a value"; source=$2; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || usage_die "usage: fm-order.sh record-legacy [--source <key>] [--] <text>... | -"
  case "$source" in *[!A-Za-z0-9._:@-]*) usage_die "record-legacy: --source takes A-Za-z0-9._:@- only" ;; esac
  ensure_dirs
  if [ -n "$source" ]; then
    key="$LEGACY_DIR/$source"
    existing=$(head -n 1 "$key" 2>/dev/null || true)
    if valid_id "$existing" && order_state "$existing" >/dev/null; then
      printf 'replay %s %s\n' "$existing" "$(order_state "$existing")"
      return 0
    fi
  fi
  bodyf=$(mktemp "$ORDERS/.body-XXXXXX")
  read_body_args "$@" >"$bodyf"
  if [ -z "$(tr -d '[:space:]' <"$bodyf")" ]; then
    rm -f "$bodyf"
    usage_die "refusing to record an empty order"
  fi
  sha=$(sha256_of_file "$bodyf")
  sha8=$(printf '%s' "$sha" | cut -c1-8)
  id="$(now_epoch)-$sha8"
  while order_state "$id" >/dev/null; do id="$(( ${id%-*} + 1 ))-$sha8"; done
  write_order "$ORDERS/acked" "$id" "$sha" "legacy${source:+:$source}" "$bodyf"
  rm -f "$bodyf"
  [ -z "$source" ] || printf '%s\n' "$id" >"$key"
  log_event "$id" legacy-recorded "$sha8" "source=${source:-terminal}"
  log_event "$id" acked "$sha8" "started=$(now_iso)"
  printf 'recorded %s acked\n  When finished: bin/fm-order.sh finish %s done|parked <outcome>\n' "$id" "$id"
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
  local lines id state file now n=0
  lines=$(open_orders)
  [ -n "$lines" ] || return 0
  now=$(now_epoch)
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
    if [ "$state" = acked ]; then
      printf '  %s acked-unfinished age=%s from=%s :: %s\n' "$id" "$(age_text $((now - ${id%-*})))" \
        "$(header_get "$file" from)" "$(order_summary "$file")"
    else
      printf '  %s pending age=%s from=%s :: %s\n' "$id" "$(age_text $((now - ${id%-*})))" \
        "$(header_get "$file" from)" "$(order_summary "$file")"
    fi
  done <<EOF
$lines
EOF
  printf 'Pending: bin/fm-order.sh ack <id> reads it (skip means another session already has it - never run it twice).\n'
  printf 'Acked-unfinished: an earlier session read it; bin/fm-order.sh show <id>, check whether its work started, then finish it.\n'
  printf 'Finish each with: bin/fm-order.sh finish <id> done|parked <outcome>\n'
}

cmd_status() {
  local json=0 one='' lines id state file now facts d r last esc age due rows=''
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
    read -r d r last esc <<EOF
$facts
EOF
    age=$((now - ${id%-*}))
    due=no
    if [ "$state" = pending ] && [ "$last" -gt 0 ] && [ $((now - last)) -ge "$RECHECK_SECS" ]; then
      due=yes
    fi
    rows="$rows$id	$state	$age	$d	$r	$esc	$due	$(header_get "$file" from)	$(order_summary "$file")
"
  done <<EOF
$lines
EOF
  if [ "$json" -eq 1 ]; then
    printf '%s' "$rows" | python3 -c '
import json, sys
cap = int(sys.argv[1])
out = []
for line in sys.stdin.read().splitlines():
    f = line.split("\t")
    if len(f) < 9:
        continue
    out.append({"id": f[0], "state": f[1], "age_secs": int(f[2]), "deliveries": int(f[3]),
                "redeliveries": int(f[4]), "redelivery_cap": cap,
                "escalation": None if f[5] == "none" else f[5],
                "resend_due": f[6] == "yes", "from": f[7], "summary": f[8]})
json.dump({"schema": "fm-order-status.v1", "orders": out}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
' "$REDELIVER_MAX"
    return 0
  fi
  if [ -z "$rows" ]; then
    printf 'no open orders\n'
    return 0
  fi
  printf '%s' "$rows" | while IFS='	' read -r id state age d r esc due from summary; do
    printf '%s %s age=%s deliveries=%s redeliveries=%s/%s%s resend_due=%s from=%s :: %s\n' \
      "$id" "$state" "$(age_text "$age")" "$d" "$r" "$REDELIVER_MAX" \
      "$([ "$esc" = none ] || printf ' %s' "$esc")" "$due" "$from" "$summary"
  done
}

# ---------------------------------------------------------------- restart gate

cmd_handoff() {
  local lines tmp
  mkdir -p "$ORDERS"
  lines=$(open_orders)
  tmp=$(mktemp "$ORDERS/.handoff-XXXXXX")
  {
    printf 'at=%s\n' "$(now_iso)"
    printf '%s\n' "$lines" | sed '/^$/d'
  } >"$tmp"
  mv "$tmp" "$MANIFEST"
  if [ -z "$lines" ]; then
    printf 'CAPTAIN ORDERS for the handoff: none open.\n'
    return 0
  fi
  printf 'CAPTAIN ORDERS for the handoff (copy this block into it):\n'
  cmd_pickup | sed '1d'
}

cmd_gate() {
  local lines id state missing='' n=0
  lines=$(open_orders)
  while read -r id state; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    if [ ! -f "$MANIFEST" ] || ! awk -v id="$id" '$1 == id { f = 1 } END { exit !f }' "$MANIFEST"; then
      missing="$missing $id"
    fi
  done <<EOF
$lines
EOF
  if [ -n "$missing" ]; then
    printf 'gate: blocked - open order(s) not in the handoff:%s\n' "$missing"
    printf '  The captain must run bin/fm-order.sh handoff and carry its block before restart.\n'
    return 3
  fi
  printf 'gate: clear (%s open order(s), all in the handoff)\n' "$n"
}

# ---------------------------------------------------------------- leash

escalate() {  # <id> <age> <deliveries> <redeliveries>
  local id=$1 repo bin out rc=0
  repo=${FM_ORDER_ESCALATION_REPO:-}
  if [ -z "$repo" ] && [ -r "$CONFIG/order-escalation-repo" ]; then
    repo=$(sed -n '/^[[:space:]]*#/d;/[^[:space:]]/{p;q;}' "$CONFIG/order-escalation-repo" | tr -d '[:space:]')
  fi
  repo=${repo:-Pibomeister/firstmate}
  bin=${FM_ORDER_SELF_HEAL_BIN:-$SELF_DIR/fm-self-heal-issue.sh}
  out=$("$bin" --repo "$repo" --failure-class captain-order-undelivered \
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
  local lines id state now facts d r last esc acted=0
  lines=$(open_orders)
  now=$(now_epoch)
  while read -r id state; do
    [ -n "$id" ] && [ "$state" = pending ] || continue
    facts=$(delivery_facts "$id")
    read -r d r last esc <<EOF
$facts
EOF
    [ "$last" -gt 0 ] || last=${id%-*}
    [ $((now - last)) -ge "$REDELIVER_SECS" ] || continue
    if [ "$r" -lt "$REDELIVER_MAX" ]; then
      deliver "$id" redelivered 0 0 redelivered | head -n 1 || true
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
  record-legacy) shift; cmd_record_legacy "$@" ;;
  handoff) shift; cmd_handoff ;;
  gate) shift; cmd_gate ;;
  claim-handle) shift; cmd_claim_handle ;;
  handle) shift; cmd_handle ;;
  sweep) shift; cmd_sweep ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
