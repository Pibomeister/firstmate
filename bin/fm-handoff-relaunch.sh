#!/usr/bin/env bash
# fm-handoff-relaunch.sh - a second mate's planned-fresh-start relaunch request.
#
# A second mate never launches its own successor: its parent relaunches it. This
# script is the single owner of how that request is made durable, how the mate's
# restart gate reads it, and when it closes.
#
# THE REQUEST. One keyed line on the mate's parent channel
# (bin/fm-parent-channel-lib.sh resolves it, local and remote routes alike):
#   blocked [key=handoff-relaunch]: second mate <id> wrote its handoff for a
#     planned fresh start and waits to be relaunched once; handoff=<path>
#     sha256=<hash>
# It is a keyed blocker, so the parent's decision fold (bin/fm-classify-lib.sh)
# wakes the parent as needing action and keeps the request in its open set
# until a resolved line for the same key, whatever the mate reports afterwards.
# Routine status prose asking for a relaunch is not this record and opens
# nothing. The parent answers it by relaunching the mate once with its ordinary
# lifecycle command (bin/fm-control.sh <id> relaunch, or
# bin/fm-remote-secondmate-relaunch.sh for a remote mate); nothing here
# relaunches a mate on its own.
#
# Usage:
#   fm-handoff-relaunch.sh request <handoff-file>
#       Run by the second mate, in its own home, after it wrote its handoff.
#       `bin/fm-order.sh covers --doc <handoff-file>` must find every open
#       captain order named in the document; a handoff that omits one, or
#       coverage that cannot be read, is refused with exit 4 and nothing is
#       published. The line is then appended to the parent channel, once: a
#       repeat for the same document and digest appends nothing. Only after
#       that append succeeds is state/.handoff-relaunch-request written, one
#       line, `at=<epoch> handoff=<path> sha256=<hash>`. Exit 1 when this home
#       is not a second mate or the channel cannot be written.
#   fm-handoff-relaunch.sh requested <epoch>
#       Exit 0 when this home's state/.handoff-relaunch-request was written at
#       or after <epoch>, 1 otherwise. bin/fm-handoff-trigger.sh uses it for a
#       second mate's restart gate.
#   fm-handoff-relaunch.sh close <mate-id> <how>
#       Run in the parent home by the lifecycle owners only, after a relaunch
#       of <mate-id> is done: bin/fm-control.sh relaunch once the replacement
#       agent is confirmed, bin/fm-spawn.sh after a successful fresh
#       --secondmate spawn that started a new agent (a remote spawn whose host
#       only reused an already live agent closes nothing), and
#       bin/fm-remote-secondmate-relaunch.sh after the host confirmed a remote
#       relaunch. When the request is open in
#       state/<mate-id>.status it appends
#       `resolved [key=handoff-relaunch]: second mate <mate-id> was relaunched
#       (<how>)`; with no open request it does nothing. Exit 1 only when that
#       append fails, so a failed or refused relaunch never closes the request
#       and a caller can report an unrecorded close.
#   fm-handoff-relaunch.sh -h|--help
set -eu
umask 077
case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KEY='handoff-relaunch'
RECORD="$STATE/.handoff-relaunch-request"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { printf 'usage: fm-handoff-relaunch.sh request <handoff-file> | requested <epoch> | close <mate-id> <how> | --help\n' >&2; exit 2; }

do_request() {
  local handoff=$1 cover_out cover_rc=0 id sha line tmp rc=0
  [ -r "$handoff" ] && [ -f "$handoff" ] || die 'supply a readable handoff document'
  case "$handoff" in /*) ;; *) handoff="$(pwd -P)/$handoff" ;; esac
  case "$handoff" in *[[:cntrl:]]*) die 'handoff path must be one line' ;; esac
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_root_is_secondmate_home "$FM_HOME" \
    || die 'only a second mate asks its parent for a relaunch; a primary launches its successor with bin/fm-handoff-launch.sh'
  cover_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" covers --doc "$handoff" 2>&1) || cover_rc=$?
  if [ "$cover_rc" -ne 0 ]; then
    if [ "$cover_rc" -eq 3 ]; then
      printf 'error: the handoff does not list every open captain order, so no relaunch is requested; rewrite it with bin/fm-ledger.sh handoff or bin/fm-order.sh handoff --doc, then request again: %s\n' "$(printf '%s' "$cover_out" | tr '\n' ' ')" >&2
    else
      printf 'error: cannot verify that the handoff lists every open captain order, so no relaunch is requested: %s\n' "$(printf '%s' "$cover_out" | tr '\n' ' ')" >&2
    fi
    exit 4
  fi
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$SCRIPT_DIR/fm-parent-channel-lib.sh"
  # shellcheck source=bin/fm-handoff-lib.sh
  . "$SCRIPT_DIR/fm-handoff-lib.sh"
  id=$(fm_parent_channel_home_id "$FM_HOME") || die "this home's second-mate identity is unusable, so its parent cannot be asked"
  sha=$(fm_handoff_hash "$handoff") || die 'cannot digest the handoff document'
  case "$sha" in ''|*[!a-f0-9]*) die 'cannot digest the handoff document' ;; esac
  line="blocked [key=$KEY]: second mate $id wrote its handoff for a planned fresh start and waits to be relaunched once; handoff=$handoff sha256=$sha"
  fm_parent_channel_report "$FM_HOME" "$STATE" "$line" "$KEY" || rc=$?
  [ "$rc" -eq 0 ] \
    || die "the relaunch request could not be written to the parent channel (bin/fm-parent-channel-lib.sh return $rc), so the parent has not been asked"
  tmp=$(mktemp "$RECORD.XXXXXX") || die "the relaunch request reached the parent, but $RECORD could not be written"
  if ! { printf 'at=%s handoff=%s sha256=%s\n' "$(date +%s)" "$handoff" "$sha" > "$tmp" && mv -f "$tmp" "$RECORD"; }; then
    rm -f "$tmp"
    die "the relaunch request reached the parent, but $RECORD could not be written"
  fi
  printf 'relaunch requested: the parent is asked to relaunch second mate %s once from %s; end this turn and wait\n' "$id" "$handoff"
}

do_requested() {
  local since=$1 line at
  case "$since" in ''|*[!0-9]*) usage ;; esac
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS= read -r line < "$RECORD" || [ -n "$line" ] || return 1
  at=${line%% *}
  case "$at" in at=*) at=${at#at=} ;; *) return 1 ;; esac
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$at" -ge "$since" ]
}

do_close() {
  local id=$1 how=$2 status open rc=0
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid second mate id: $id" ;; esac
  status="$STATE/$id.status"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  open=$(status_open_decisions "$status" secondmate) || open=
  case $'\n'"$open" in
    *$'\n'"$KEY"$'\t'*) ;;
    *) return 0 ;;
  esac
  how=$(printf '%s' "$how" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-200)
  fm_wake_status_append_self_announced "$STATE" "$status" \
    "resolved [key=$KEY]: second mate $id was relaunched ($how)" || rc=$?
  [ "$rc" -ne 2 ] || die "second mate $id was relaunched, but its open relaunch request could not be closed in $status"
}

case "${1:-}" in
  request) [ $# -eq 2 ] || usage; do_request "$2" ;;
  requested) [ $# -eq 2 ] || usage; do_requested "$2" ;;
  close) [ $# -eq 3 ] || usage; do_close "$2" "$3" ;;
  *) usage ;;
esac
