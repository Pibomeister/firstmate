#!/usr/bin/env bash
# fm-wake-ledger-lib.sh - the append-only wake ledger: one durable row for every
# removal from the wake queue, so wakes can still be counted after a drain has
# deleted their queue rows. bin/fm-wake-ledger.sh reads and counts it.
#
# The ledger is <state>/wake-ledger.tsv, one tab-separated row per removal:
#   epoch  event  generation  through  seqs  keys
# epoch is fm_now (bin/fm-clock-lib.sh). event is `ack` (the drain's
# --ack-through acknowledgement), `retired` (unusable rows the drain retires),
# `consumed` (acknowledged rows leaving an actor's claim file) or `pruned`
# (fm_wake_queue_prune_task). generation is the --recovery-generation value and
# through the --ack-through value, `-` when the removal had none. seqs is the
# comma-separated ascending list of the queue sequence numbers the removal took
# out, and keys is a compact JSON array of those rows' key column in the same
# order, `""` for a row too short to carry one. A `consumed` row lists only the
# claimed sequences whose queue row the same acknowledgement removed, so a
# claim whose row an earlier removal already listed is not counted twice.
# A removal that takes out no sequence number writes no row.
# A row's epoch is the time of the removal it describes: every removal except
# `consumed` reads fm_now just before its queue change, and a `consumed` row
# reuses the epoch of the acknowledgement that removed its queue rows, so the
# two land in the same window. The public append reads fm_now on every call.
# A removal row never lists a sequence number that an earlier row already
# lists with another epoch or the same event, and a row left with none is not
# written. So a removal retried after an interruption between its row and its
# queue change writes no second row, and each wake counts once; only the
# `consumed` row an acknowledgement pairs with its own `ack` row shares that
# row's sequences.
#
# Every writer here runs while its caller holds the wake-queue lock
# (fm_wake_queue_lock_acquire in bin/fm-wake-lib.sh) and takes no lock of its own.
# A removal and its row are one change (fm_wake_ledger_commit_removal_locked):
# the row is written first, a row that cannot be computed or written stops the
# removal, which then fails with a stderr report and leaves its rows in place,
# and a removal that fails after its row was written takes the row back out.
# So no wake leaves its file uncounted and none is counted for a removal that
# did not happen.

FM_WAKE_LEDGER_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)"
# shellcheck source=bin/fm-clock-lib.sh
. "$FM_WAKE_LEDGER_LIB_DIR/fm-clock-lib.sh"

# The epoch of the latest removal other than `consumed`, which the next
# `consumed` removal reuses and then clears; never taken from the environment.
_FM_WAKE_LEDGER_REMOVAL_EPOCH=

# fm_wake_ledger_path <state-dir>: the wake ledger of that state directory.
fm_wake_ledger_path() {
  printf '%s/wake-ledger.tsv\n' "$1"
}

# fm_wake_ledger_append_locked <state-dir> <event> <generation> <through> <seqs> <keys-json>
# Append one ledger row stamped with fm_now; write nothing when <seqs> is
# empty. An empty generation or through is recorded as `-`. Exit 2 on a
# malformed field.
fm_wake_ledger_append_locked() {
  local epoch
  epoch=$(fm_now) || return 1
  _fm_wake_ledger_append_at "$epoch" "$@"
}

# _fm_wake_ledger_append_at <epoch> <state-dir> <event> <generation> <through> <seqs> <keys-json>
# fm_wake_ledger_append_locked with the row's epoch given.
_fm_wake_ledger_append_at() {
  local epoch=$1 state=$2 event=$3 generation=${4:--} through=${5:--} seqs=$6 keys=$7
  [ -n "$seqs" ] || return 0
  case "$event" in
    ack|retired|pruned|consumed) ;;
    *) printf 'fm-wake-ledger: invalid event: %s\n' "$event" >&2; return 2 ;;
  esac
  case "$generation" in
    -) ;;
    *[!A-Za-z0-9._-]*) printf 'fm-wake-ledger: invalid generation: %s\n' "$generation" >&2; return 2 ;;
  esac
  case "$through" in
    -) ;;
    *[!0-9]*) printf 'fm-wake-ledger: invalid through: %s\n' "$through" >&2; return 2 ;;
  esac
  case "$seqs" in
    *[!0-9,]*|,*|*,|*,,*) printf 'fm-wake-ledger: invalid sequence list: %s\n' "$seqs" >&2; return 2 ;;
  esac
  case "$keys" in
    \[*\]) ;;
    *) printf 'fm-wake-ledger: keys are not a JSON array\n' >&2; return 2 ;;
  esac
  case "$keys" in
    *$'\t'*|*$'\n'*|*$'\r'*) printf 'fm-wake-ledger: keys carry a row separator\n' >&2; return 2 ;;
  esac
  case "$epoch" in
    ''|*[!0-9]*) printf 'fm-wake-ledger: invalid epoch: %s\n' "$epoch" >&2; return 2 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$event" "$generation" "$through" "$seqs" "$keys" \
    >> "$(fm_wake_ledger_path "$state")"
}

# _fm_wake_ledger_removed_rows <before> <after>: print the queue rows of
# <before> that <after> no longer holds, counting duplicate lines separately.
_fm_wake_ledger_removed_rows() {
  LC_ALL=C awk -v after="$2" '
    BEGIN { while ((getline line < after) > 0) kept[line]++; close(after) }
    kept[$0] > 0 { kept[$0]--; next }
    { print }
  ' "$1"
}

# _fm_wake_ledger_fields <ledger> <epoch> <event> [<seqs-csv>]: read queue rows
# on stdin and print one line `<seqs>\t<keys-json>` for the rows carrying a
# numeric sequence, in ascending sequence order, or nothing when there is none.
# With <seqs-csv>, list only those of its sequences that a row read carries.
# Leave out every sequence that a row of <ledger> already lists with an epoch
# other than <epoch> or with the event <event>. Return non-zero when any stage
# of the extraction fails, so no removal runs on a row that was not computed.
_fm_wake_ledger_fields() (
  set -o pipefail
  _FM_WAKE_LEDGER_PRIOR=$1 _FM_WAKE_LEDGER_AT=$2 _FM_WAKE_LEDGER_EVENT=$3 _FM_WAKE_LEDGER_WANT=${4:-} \
    LC_ALL=C awk -F '\t' '
    function quote(s,   out, c, i, n) {
      out = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c in ctl) out = out ctl[c]
        else out = out c
      }
      return "\"" out "\""
    }
    BEGIN {
      for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
      prior = ENVIRON["_FM_WAKE_LEDGER_PRIOR"]
      at = ENVIRON["_FM_WAKE_LEDGER_AT"] ""
      event = ENVIRON["_FM_WAKE_LEDGER_EVENT"] ""
      while ((getline line < prior) > 0) {
        if (split(line, f, "\t") != 6 || f[5] !~ /^[0-9]+(,[0-9]+)*$/) continue
        if (f[1] "" == at && f[2] "" != event) continue
        n = split(f[5], listed, ",")
        for (i = 1; i <= n; i++) held[listed[i] + 0] = 1
      }
      close(prior)
    }
    NF >= 2 && $2 ~ /^[0-9]+$/ && !($2 in key) && !(($2 + 0) in held) { key[$2] = quote(NF >= 4 ? $4 : "") }
    END {
      want = ENVIRON["_FM_WAKE_LEDGER_WANT"]
      if (want != "") {
        n = split(want, seq, ",")
        for (i = 1; i <= n; i++) if (seq[i] ~ /^[0-9]+$/) if (seq[i] in key) print seq[i] "\t" key[seq[i]]
      } else {
        for (s in key) print s "\t" key[s]
      }
    }
  ' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -u | LC_ALL=C awk -F '\t' '
    { seqs = seqs (NR > 1 ? "," : "") $1; keys = keys (NR > 1 ? "," : "") $2 }
    END { if (NR > 0) print seqs "\t[" keys "]" }
  '
)

# fm_wake_ledger_record_removal_locked <state-dir> <event> <generation> <through> <removed-rows> [<seqs-csv>]
# Append the row, stamped with fm_now, for one removal from the removed queue
# rows it took out (newline-separated, as _fm_wake_ledger_removed_rows prints
# them); with <seqs-csv>, the row lists those of its sequences that
# <removed-rows> carries. Sequences an earlier row already lists are left out
# as the header describes. Report a failed write on stderr and return non-zero.
fm_wake_ledger_record_removal_locked() {
  local epoch
  if ! epoch=$(fm_now); then
    fm_wake_ledger_report_unwritten "$1" "$2"
    return 1
  fi
  _fm_wake_ledger_record_at "$epoch" "$@"
}

# _fm_wake_ledger_record_at <epoch> <state-dir> <event> <generation> <through> <removed-rows> [<seqs-csv>]
# fm_wake_ledger_record_removal_locked with the row's epoch given.
_fm_wake_ledger_record_at() {
  local epoch=$1 state=$2 event=$3 generation=$4 through=$5 removed=$6 want=${7:-} fields status=0
  fields=$(printf '%s' "$removed" \
    | _fm_wake_ledger_fields "$(fm_wake_ledger_path "$state")" "$epoch" "$event" "$want") || status=$?
  if [ "$status" -eq 0 ] && [ -n "$fields" ]; then
    _fm_wake_ledger_append_at "$epoch" "$state" "$event" "$generation" "$through" \
      "${fields%%$'\t'*}" "${fields#*$'\t'}" || status=$?
  fi
  [ "$status" -eq 0 ] || fm_wake_ledger_report_unwritten "$state" "$event"
  return "$status"
}

# fm_wake_ledger_report_unwritten <state-dir> <event>: the one stderr report
# for a removal whose ledger row could not be computed or written.
fm_wake_ledger_report_unwritten() {
  printf 'fm-wake-ledger: the %s row could not be written to %s; the removal it describes did not happen\n' \
    "$2" "$(fm_wake_ledger_path "$1")" >&2
}

# _fm_wake_ledger_size <ledger>: print the ledger's byte length, or `absent`.
_fm_wake_ledger_size() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    [ -f "$1" ] || return 1
    wc -c < "$1" | tr -d ' '
  else
    printf 'absent\n'
  fi
}

# _fm_wake_ledger_restore <ledger> <size>: take the ledger back to the byte
# length _fm_wake_ledger_size printed, removing it when it was absent.
_fm_wake_ledger_restore() {
  local ledger=$1 size=$2 tmp
  if [ "$size" = absent ]; then
    rm -f -- "$ledger"
    return
  fi
  [ -f "$ledger" ] || return 1
  [ "$(wc -c < "$ledger" | tr -d ' ')" != "$size" ] || return 0
  tmp=$(mktemp "$ledger.restore.XXXXXX") || return 1
  if head -c "$size" "$ledger" > "$tmp" && mv -f -- "$tmp" "$ledger"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# fm_wake_ledger_commit_removal_locked <state-dir> <event> <generation> <through> <removed-rows> <seqs-csv> <command> [<arg>...]
# Make one removal and its ledger row a single change. Write the row for
# <removed-rows> first (as fm_wake_ledger_record_removal_locked does, with
# <seqs-csv> empty for every sequence they carry), stamped with fm_now read
# now, or for `consumed` with the epoch of the latest other removal this
# process committed (fm_now when there is none); then run <command>, which makes the
# removal. When the row cannot be written, <command> never runs and the call
# returns non-zero; when <command> fails, the row is taken back out and its
# status is returned. Both failures are reported on stderr.
fm_wake_ledger_commit_removal_locked() {
  local state=$1 event=$2 generation=$3 through=$4 removed=$5 want=$6 ledger size status epoch
  shift 6
  ledger=$(fm_wake_ledger_path "$state")
  if ! size=$(_fm_wake_ledger_size "$ledger"); then
    fm_wake_ledger_report_unwritten "$state" "$event"
    return 1
  fi
  if [ "$event" = consumed ] && [ -n "$_FM_WAKE_LEDGER_REMOVAL_EPOCH" ]; then
    epoch=$_FM_WAKE_LEDGER_REMOVAL_EPOCH
    _FM_WAKE_LEDGER_REMOVAL_EPOCH=
  elif ! epoch=$(fm_now); then
    fm_wake_ledger_report_unwritten "$state" "$event"
    return 1
  fi
  [ "$event" = consumed ] || _FM_WAKE_LEDGER_REMOVAL_EPOCH=$epoch
  if ! _fm_wake_ledger_record_at "$epoch" "$state" "$event" "$generation" "$through" "$removed" "$want"; then
    _fm_wake_ledger_restore "$ledger" "$size" || :
    return 1
  fi
  "$@" && return 0
  status=$?
  _fm_wake_ledger_restore "$ledger" "$size" \
    || printf 'fm-wake-ledger: the %s row in %s could not be taken back after its removal failed\n' \
      "$event" "$ledger" >&2
  return "$status"
}
