#!/usr/bin/env bash
# fm-stall-ledger-lib.sh - append-only stall ledger for one supervision home.
# bin/fm-stall-ledger.sh owns the command contract, the score bars, and which
# human-intervention events count. This file owns the row schema and the
# observe sources.
#
# The ledger is <state>/stall-ledger.tsv. Each row has ten tab-separated fields:
#   epoch event class subject start detect recoverer recover duration ref
# event is hb, stall-open, stall-close, handoff, or intervention.
# class is primary, secondmate, or worker.
# subject is a task id, or - for the primary session. Tabs, newlines, and any
# character outside [A-Za-z0-9._-] are replaced, and the value is cut at 200
# characters, so a ref of class:subject:start stays one field.
# recoverer is firstmate, agentkit, watchdog, human, or -.
# epoch, start, detect, recover, and duration are decimal whole seconds or -.
# duration is informational. Scoring recomputes stall duration as end minus
# start and handoff duration as detect minus start, and recomputes a heartbeat
# age as epoch minus start. start on an hb row is the heartbeat published_epoch.
# ref is class:subject:start for a stall, the handoff nonce, order:<id>,
# note:<id>, or - for an hb row.
#
# Rows are appended and never rewritten. A reader skips a row that does not have
# ten fields, a decimal epoch, a known event, and a known class. An hb,
# stall-open, stall-close, or handoff row whose start is not decimal is skipped,
# as is a stall or handoff row whose detect is not decimal. An absent ledger
# reads as empty.
#
# Observe reads sources the supervision poll already writes. It does not start
# a poll. The first observe records <state>/.stall-ledger-born and ignores
# order, note, handoff, and watchdog rows older than that epoch, so installing
# the ledger does not import history. A live heartbeat, the current wake queue,
# and a current secondmate progress marker are read on every observe. A second
# observe inside FM_STALL_LEDGER_MIN_SECS (default 60, 0 disables) exits 0
# before it takes the lock. The lock is <state>/.stall-ledger.lock, taken with
# fm_lock_acquire_wait for the reconcile only.
#
# Status lines are not stall evidence. One open stall is kept per class and
# subject. Heartbeat evidence wins over a progress marker, then a stale wake,
# then a watchdog row, and the earliest start wins a tie.

FM_STALL_LEDGER_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)"
# shellcheck source=bin/fm-clock-lib.sh
. "$FM_STALL_LEDGER_LIB_DIR/fm-clock-lib.sh"

# fm_stall_ledger_path <state-dir>
fm_stall_ledger_path() {
  printf '%s/stall-ledger.tsv\n' "$1"
}

# fm_stall_ledger_until <kickoff-epoch>
# Print the next 08:00 America/Chicago strictly after <kickoff-epoch>.
# A kickoff of exactly 08:00 resolves to the next civil day. The day step is a
# civil date, so a DST change is not a fixed 86400 seconds.
fm_stall_ledger_until() {
  local kick=$1 civil eight
  if date -j -f '%Y-%m-%d %H:%M:%S' '2020-01-01 00:00:00' +%s >/dev/null 2>&1; then
    civil=$(TZ=America/Chicago date -r "$kick" +%Y-%m-%d) || return 1
    eight=$(TZ=America/Chicago date -j -f '%Y-%m-%d %H:%M:%S' "$civil 08:00:00" +%s) || return 1
    if [ "$eight" -le "$kick" ]; then
      eight=$(TZ=America/Chicago date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$civil 08:00:00" +%s) || return 1
    fi
  else
    civil=$(TZ=America/Chicago date -d "@$kick" +%Y-%m-%d) || return 1
    eight=$(TZ=America/Chicago date -d "$civil 08:00:00" +%s) || return 1
    if [ "$eight" -le "$kick" ]; then
      eight=$(TZ=America/Chicago date -d "$civil 08:00:00 + 1 day" +%s) || return 1
    fi
  fi
  printf '%s\n' "$eight"
}

_fm_stall_is_num() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

_fm_stall_subject() {
  local s
  s=$(printf '%s' "$1" | tr '\t\r\n' '   ' | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C cut -c1-200)
  [ -n "$s" ] || s=-
  printf '%s' "$s"
}

_fm_stall_json_epoch() { # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -v k="$key" '
    {
      needle = "\"" k "\""
      p = index($0, needle)
      if (p == 0) next
      s = substr($0, p + length(needle))
      sub(/^[^0-9]*/, "", s)
      if (match(s, /^[0-9]+/)) { print substr(s, RSTART, RLENGTH); exit }
    }
  ' "$file"
}

_fm_stall_meta_value() { # <meta> <key>
  local meta=$1 key=$2 line value=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#"$key="} ;;
    esac
  done < "$meta"
  value=${value%$'\r'}
  printf '%s' "$value"
}

_fm_stall_mtime() { # <file>
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || return 1
  _fm_stall_is_num "$m" || return 1
  printf '%s\n' "$m"
}

_fm_stall_append() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >> "$FM_STALL_LEDGER" || return 1
}

_fm_stall_ref_exists() {
  local ref=$1
  [ -f "$FM_STALL_LEDGER" ] || return 1
  awk -F '\t' -v r="$ref" '
    NF == 10 && $10 == r { found = 1; exit }
    END { exit !found }
  ' "$FM_STALL_LEDGER"
}

_fm_stall_have_hb() { # <class> <subject> <epoch>
  [ -f "$FM_STALL_LEDGER" ] || return 1
  awk -F '\t' -v c="$1" -v s="$2" -v e="$3" '
    NF == 10 && $2 == "hb" && $3 == c && $4 == s && $1 == e { found = 1; exit }
    END { exit !found }
  ' "$FM_STALL_LEDGER"
}

_fm_stall_opens() {
  [ -f "$FM_STALL_LEDGER" ] || return 0
  awk -F '\t' '
    NF == 10 && $2 == "stall-open" && $10 != "" && $10 != "-" {
      if (!($10 in seen)) { order[++n] = $10; seen[$10] = 1 }
      cls[$10] = $3; subj[$10] = $4; st[$10] = $5; det[$10] = $6
    }
    NF == 10 && $2 == "stall-close" { closed[$10] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        r = order[i]
        if (!closed[r]) print cls[r] "\t" subj[r] "\t" r "\t" st[r] "\t" det[r]
      }
    }
  ' "$FM_STALL_LEDGER"
}

_fm_stall_open_for() { # <class> <subject>
  _fm_stall_opens | awk -F '\t' -v c="$1" -v s="$2" '
    $1 == c && $2 == s { found = 1; exit }
    END { exit !found }
  '
}

_fm_stall_self() {
  local id
  FM_STALL_SELF_CLASS=primary
  FM_STALL_SELF_SUBJECT=-
  if [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ]; then
    id=$(_fm_stall_subject "$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)")
    FM_STALL_SELF_CLASS=secondmate
    FM_STALL_SELF_SUBJECT=$id
  fi
}

_fm_stall_prepare() {
  local min stamp
  FM_STALL_NOW=$(fm_now) || return 1
  _fm_stall_is_num "$FM_STALL_NOW" || return 1
  min=${FM_STALL_LEDGER_MIN_SECS:-60}
  case "$min" in ''|*[!0-9]*) min=60 ;; esac
  if [ "$min" -gt 0 ] && [ -f "$STATE/.stall-ledger-observed" ] && [ ! -L "$STATE/.stall-ledger-observed" ]; then
    stamp=$(cat "$STATE/.stall-ledger-observed" 2>/dev/null || true)
    case "$stamp" in
      ''|*[!0-9]*) ;;
      *)
        [ $((FM_STALL_NOW - stamp)) -ge "$min" ] || return 2
        ;;
    esac
  fi
  if ! command -v fm_lock_acquire_wait >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_STALL_LEDGER_LIB_DIR/fm-wake-lib.sh" || return 1
  fi
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$STATE/.stall-ledger.lock" || return 1
  _fm_stall_lock=$STATE/.stall-ledger.lock
  FM_STALL_WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stall.XXXXXX") || return 1
  _fm_stall_work=$FM_STALL_WORK
  : > "$FM_STALL_WORK/signals.tsv" || return 1
  : > "$FM_STALL_WORK/done.tsv" || return 1
  mkdir -p "$FM_STALL_WORK/ep" || return 1
  FM_STALL_LEDGER=$(fm_stall_ledger_path "$STATE")
  if [ -L "$FM_STALL_LEDGER" ] || [ -L "$STATE/.stall-ledger-born" ] || [ -L "$STATE/.stall-ledger-observed" ]; then
    return 1
  fi
  if [ ! -f "$STATE/.stall-ledger-born" ]; then
    printf '%s\n' "$FM_STALL_NOW" > "$STATE/.stall-ledger-born" || return 1
  fi
  FM_STALL_BORN=$(cat "$STATE/.stall-ledger-born" 2>/dev/null || true)
  _fm_stall_is_num "$FM_STALL_BORN" || return 1
  if [ ! -e "$FM_STALL_LEDGER" ]; then
    : > "$FM_STALL_LEDGER" || return 1
  fi
  _fm_stall_self
  return 0
}

_fm_stall_record_hb() { # <file> <class> <subject>
  local file=$1 cls=$2 sub=$3 published age detect
  published=$(_fm_stall_json_epoch "$file" published_epoch)
  if ! _fm_stall_is_num "$published"; then
    published=$(_fm_stall_json_epoch "$file" generated_epoch)
  fi
  _fm_stall_is_num "$published" || return 0
  if ! _fm_stall_have_hb "$cls" "$sub" "$FM_STALL_NOW"; then
    _fm_stall_append "$FM_STALL_NOW" hb "$cls" "$sub" "$published" - - - - - || return 1
  fi
  if [ "$FM_STALL_NOW" -ge "$published" ]; then
    age=$((FM_STALL_NOW - published))
  else
    age=0
  fi
  if [ "$age" -gt 600 ]; then
    detect=$((published + 601))
    printf '1\t%s\t%s\t%s\t%s\n' "$cls" "$sub" "$published" "$detect" >> "$FM_STALL_WORK/signals.tsv" || return 1
  fi
}

_fm_stall_heartbeats() {
  local meta kind home id marker got
  _fm_stall_record_hb "$STATE/heartbeat.json" "$FM_STALL_SELF_CLASS" "$FM_STALL_SELF_SUBJECT" || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(_fm_stall_meta_value "$meta" kind)
    [ "$kind" = secondmate ] || continue
    home=$(_fm_stall_meta_value "$meta" home)
    case "$home" in
      /*) ;;
      *) continue ;;
    esac
    case "$home" in
      *[[:cntrl:]]*) continue ;;
    esac
    [ "$home" = "$FM_HOME" ] && continue
    [ -d "$home" ] || continue
    id=${meta##*/}
    id=$(_fm_stall_subject "${id%.meta}")
    [ "$id" = - ] && continue
    marker=$home/.fm-secondmate-home
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || continue
      got=$(_fm_stall_subject "$(cat "$marker" 2>/dev/null || true)")
      [ "$got" = "$id" ] || continue
    fi
    _fm_stall_record_hb "$home/state/heartbeat.json" secondmate "$id" || return 1
  done
}

_fm_stall_interventions() {
  local data log note mtime base sub ref iso epoch id event sha detail
  data=${DATA:-${FM_DATA_OVERRIDE:-$FM_HOME/data}}
  log=$data/orders/log.tsv
  if [ -f "$log" ] && [ ! -L "$log" ]; then
    while IFS=$(printf '\t') read -r iso epoch id event sha detail || [ -n "${iso:-}" ]; do
      : "$iso" "$sha" "$detail"
      _fm_stall_is_num "$epoch" || continue
      [ "$epoch" -ge "$FM_STALL_BORN" ] || continue
      [ "$event" = sent ] || continue
      sub=$(_fm_stall_subject "$id")
      ref="order:$sub"
      if _fm_stall_ref_exists "$ref"; then
        continue
      fi
      _fm_stall_append "$epoch" intervention "$FM_STALL_SELF_CLASS" "$sub" \
        "$epoch" "$epoch" human - - "$ref" || return 1
    done < "$log"
  fi
  for note in "$STATE/inbox"/*.note; do
    [ -f "$note" ] && [ ! -L "$note" ] || continue
    mtime=$(_fm_stall_mtime "$note") || continue
    [ "$mtime" -ge "$FM_STALL_BORN" ] || continue
    base=${note##*/}
    base=${base%.note}
    sub=$(_fm_stall_subject "$base")
    ref="note:$sub"
    if _fm_stall_ref_exists "$ref"; then
      continue
    fi
    _fm_stall_append "$mtime" intervention "$FM_STALL_SELF_CLASS" "$sub" \
      "$mtime" "$mtime" human - - "$ref" || return 1
  done
}

_fm_stall_handoffs() {
  local log start ack nonce dur
  log=$STATE/handoff-events.log
  [ -f "$log" ] && [ ! -L "$log" ] || return 0
  awk -v born="$FM_STALL_BORN" '
    $1 != "HANDOFF" || $2 != "v1" { next }
    {
      ts = ""; ev = ""; nonce = ""; reason = ""
      for (i = 3; i <= NF; i++) {
        eq = index($i, "=")
        if (eq == 0) continue
        k = substr($i, 1, eq - 1)
        v = substr($i, eq + 1)
        if (k == "ts") ts = v
        else if (k == "event") ev = v
        else if (k == "nonce") nonce = v
        else if (k == "reason") reason = v
      }
      if (ts !~ /^[0-9]+$/ || nonce == "" || nonce == "none" || nonce ~ /[^a-f0-9]/) next
      m++
      ets[m] = ts; eev[m] = ev; en[m] = nonce; er[m] = reason
    }
    END {
      for (a = 1; a <= m; a++) {
        if (eev[a] != "handoff_ack" || er[a] != "lock_transferred") continue
        if (ets[a] + 0 < born + 0) continue
        nonce = en[a]
        if (seen[nonce]) continue
        st = ""
        for (b = 1; b <= a; b++) {
          if (en[b] != nonce) continue
          if (eev[b] != "handoff_started" && eev[b] != "handoff_retry") continue
          if (ets[b] + 0 <= ets[a] + 0) st = ets[b]
        }
        if (st == "") continue
        seen[nonce] = 1
        print st "\t" ets[a] "\t" nonce
      }
    }
  ' "$log" > "$FM_STALL_WORK/handoffs.tsv" || return 1
  while IFS=$(printf '\t') read -r start ack nonce || [ -n "${start:-}" ]; do
    _fm_stall_is_num "$start" || continue
    _fm_stall_is_num "$ack" || continue
    [ "$ack" -ge "$start" ] || continue
    nonce=$(_fm_stall_subject "$nonce")
    [ "$nonce" = - ] && continue
    if _fm_stall_ref_exists "$nonce"; then
      continue
    fi
    dur=$((ack - start))
    _fm_stall_append "$ack" handoff "$FM_STALL_SELF_CLASS" "$FM_STALL_SELF_SUBJECT" \
      "$start" "$ack" - - "$dur" "$nonce" || return 1
  done < "$FM_STALL_WORK/handoffs.tsv"
}

_fm_stall_progress() {
  local marker task line observed idle detect
  for marker in "$STATE"/.secondmate-wake-progress-*; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    task=${marker##*/}
    task=$(_fm_stall_subject "${task#.secondmate-wake-progress-}")
    [ "$task" = - ] && continue
    IFS= read -r line < "$marker" || continue
    observed=${line%%[[:space:]]*}
    _fm_stall_is_num "$observed" || continue
    if [ "$FM_STALL_NOW" -ge "$observed" ]; then
      idle=$((FM_STALL_NOW - observed))
    else
      idle=0
    fi
    [ "$idle" -gt 600 ] || continue
    detect=$((observed + 601))
    printf '2\tsecondmate\t%s\t%s\t%s\n' "$task" "$observed" "$detect" >> "$FM_STALL_WORK/signals.tsv" || return 1
  done
}

_fm_stall_wakes() {
  local queue epoch idle key subject kind start detect
  queue=${FM_WAKE_QUEUE:-$STATE/.wake-queue}
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    NF >= 5 && $3 == "stale" && $1 ~ /^[0-9]+$/ && match($5, "idle [0-9]+s") {
      tok = substr($5, RSTART, RLENGTH)
      sub("^idle ", "", tok)
      sub("s$", "", tok)
      if (tok + 0 > 600) print $1 "\t" (tok + 0) "\t" $4
    }
  ' "$queue" > "$FM_STALL_WORK/wakes.tsv" || return 1
  while IFS=$(printf '\t') read -r epoch idle key || [ -n "${epoch:-}" ]; do
    _fm_stall_is_num "$epoch" || continue
    _fm_stall_is_num "$idle" || continue
    [ "$idle" -gt 600 ] || continue
    subject=$(_fm_stall_subject "$key")
    [ "$subject" = - ] && continue
    kind=$(_fm_stall_meta_value "$STATE/$subject.meta" kind)
    if [ "$kind" = secondmate ]; then
      kind=secondmate
    else
      kind=worker
    fi
    if [ "$idle" -gt "$epoch" ]; then
      start=0
    else
      start=$((epoch - idle))
    fi
    detect=$epoch
    printf '3\t%s\t%s\t%s\t%s\n' "$kind" "$subject" "$start" "$detect" >> "$FM_STALL_WORK/signals.tsv" || return 1
  done < "$FM_STALL_WORK/wakes.tsv"
}

_fm_stall_wd_extra() {
  local n
  n=$(printf '%s\n' "$1" | LC_ALL=C awk '
    {
      if (match($0, "[0-9]+ minutes")) {
        s = substr($0, RSTART, RLENGTH)
        sub(" minutes", "", s)
        print (s + 0) * 60
        exit
      }
      if (match($0, "[0-9]+m old")) {
        s = substr($0, RSTART, RLENGTH)
        sub("m old", "", s)
        print (s + 0) * 60
        exit
      }
      print 600
    }
  ')
  _fm_stall_is_num "$n" || n=600
  printf '%s\n' "$n"
}

_fm_stall_wd_norm() { # <home> <subject> <symptom> -> prints "class subject"
  local home=$1 subject=$2 symptom=$3 norm base meta kind
  norm=$(_fm_stall_subject "$subject")
  base=${FM_HOME%/}
  base=$(_fm_stall_subject "${base##*/}")
  if [ "$symptom" = usage-limit-autowait ]; then
    printf 'primary -\n'
    return 0
  fi
  if [ "$norm" = primary ] || [ "$norm" = - ] || [ "$norm" = "$base" ]; then
    if [ -z "$home" ] || [ "$home" = "$FM_HOME" ]; then
      printf 'primary -\n'
      return 0
    fi
  fi
  meta=$STATE/$norm.meta
  kind=$(_fm_stall_meta_value "$meta" kind)
  if [ "$kind" = secondmate ]; then
    printf 'secondmate %s\n' "$norm"
  else
    printf 'worker %s\n' "$norm"
  fi
}

_fm_stall_wd_symptom() {
  case "$1" in
    frozen|timer-loop|usage-limit|usage-limit-autowait|quota|quota:*) return 0 ;;
  esac
  return 1
}

_fm_stall_wd_terminates() {
  [ "$1" = "done" ] || return 1
  case "$2" in
    restart|nudge|key) return 0 ;;
  esac
  return 1
}

# actions.tsv has an empty home on a primary row. A tab is IFS whitespace, so a
# tab read would collapse that field and shift the symptom. Unit separator is
# not whitespace, so the empty home stays empty.
_fm_stall_wd_rows() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -F '\t' '{
    detail = ""
    for (i = 8; i <= NF; i++) {
      if (i > 8) detail = detail "\t" $i
      else detail = $i
    }
    printf "%s\036%s\036%s\036%s\036%s\036%s\036%s\036%s\n", $1, $2, $3, $4, $5, $6, $7, detail
  }' "$file"
}

_fm_stall_watchdog() {
  local file epoch _id home subject symptom action phase detail
  local cls sub key extra start detect estart edetect norm
  file=$STATE/watchdog/actions.tsv
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS=$'\036' read -r epoch _id home subject symptom action phase detail || [ -n "${epoch:-}" ]; do
    : "$_id"
    _fm_stall_is_num "$epoch" || continue
    [ "$epoch" -ge "$FM_STALL_BORN" ] || continue
    _fm_stall_wd_symptom "$symptom" || continue
    norm=$(_fm_stall_wd_norm "$home" "$subject" "$symptom")
    cls=${norm%% *}
    sub=${norm#* }
    [ -n "$cls" ] && [ -n "$sub" ] || continue
    key=$FM_STALL_WORK/ep/${cls}__${sub}
    if _fm_stall_wd_terminates "$phase" "$action"; then
      if [ -f "$key" ]; then
        read -r estart edetect < "$key" || true
        rm -f -- "$key"
        if _fm_stall_is_num "$estart" && _fm_stall_is_num "$edetect" && [ "$epoch" -gt "$estart" ]; then
          if [ $((epoch - estart)) -gt 600 ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$cls" "$sub" "$estart" "$edetect" "$epoch" >> "$FM_STALL_WORK/done.tsv" || return 1
          fi
        fi
      fi
      continue
    fi
    if [ ! -f "$key" ]; then
      extra=$(_fm_stall_wd_extra "$detail")
      if [ "$extra" -gt "$epoch" ]; then
        start=0
      else
        start=$((epoch - extra))
      fi
      detect=$epoch
      printf '%s %s\n' "$start" "$detect" > "$key" || return 1
    fi
  done < <(_fm_stall_wd_rows "$file")
  for key in "$FM_STALL_WORK/ep"/*; do
    [ -f "$key" ] || continue
    read -r estart edetect < "$key" || continue
    _fm_stall_is_num "$estart" || continue
    _fm_stall_is_num "$edetect" || continue
    [ $((FM_STALL_NOW - estart)) -gt 600 ] || continue
    cls=${key##*/}
    sub=${cls#*__}
    cls=${cls%%__*}
    printf '4\t%s\t%s\t%s\t%s\n' "$cls" "$sub" "$estart" "$edetect" >> "$FM_STALL_WORK/signals.tsv" || return 1
  done
}

_fm_stall_signal_has() { # <class> <subject> [prio]
  local cls=$1 sub=$2 prio=${3:-}
  [ -f "$FM_STALL_WORK/signals.tsv" ] || return 1
  awk -F '\t' -v c="$cls" -v s="$sub" -v p="$prio" '
    NF == 5 && $2 == c && $3 == s && (p == "" || $1 == p) { found = 1; exit }
    END { exit !found }
  ' "$FM_STALL_WORK/signals.tsv"
}

_fm_stall_attribute() { # <class> <subject> <detect> <now>
  local cls=$1 sub=$2 detect=$3 now=$4
  if [ -f "$FM_STALL_LEDGER" ] && awk -F '\t' -v c="$cls" -v s="$sub" -v lo="$detect" -v hi="$now" '
      NF == 10 && $2 == "intervention" && $1 ~ /^[0-9]+$/ && $1 + 0 > lo + 0 && $1 + 0 <= hi + 0 &&
        $3 == c && ($4 == s || $4 == "-" || s == "-") { found = 1; exit }
      END { exit !found }
    ' "$FM_STALL_LEDGER"; then
    printf 'human\n'
    return 0
  fi
  if _fm_stall_wd_done_for "$cls" "$sub" "$detect" "$now"; then
    printf 'watchdog\n'
    return 0
  fi
  if [ "$cls" = secondmate ]; then
    printf 'agentkit\n'
    return 0
  fi
  printf 'firstmate\n'
}

_fm_stall_wd_done_for() { # <class> <subject> <detect> <now>
  local cls=$1 sub=$2 detect=$3 now=$4 file epoch _id home subject symptom action phase detail ncls nsub norm
  file=$STATE/watchdog/actions.tsv
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS=$'\036' read -r epoch _id home subject symptom action phase detail || [ -n "${epoch:-}" ]; do
    : "$_id" "$detail"
    _fm_stall_is_num "$epoch" || continue
    [ "$epoch" -ge "$detect" ] && [ "$epoch" -le "$now" ] || continue
    _fm_stall_wd_terminates "$phase" "$action" || continue
    _fm_stall_wd_symptom "$symptom" || continue
    norm=$(_fm_stall_wd_norm "$home" "$subject" "$symptom")
    ncls=${norm%% *}
    nsub=${norm#* }
    [ "$ncls" = "$cls" ] && [ "$nsub" = "$sub" ] && return 0
  done < <(_fm_stall_wd_rows "$file")
  return 1
}

_fm_stall_choose_signals() {
  awk -F '\t' '
    NF == 5 && $1 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
      key = $2 "\t" $3
      if (!(key in prio) || $1 + 0 < prio[key] + 0 || ($1 + 0 == prio[key] + 0 && $4 + 0 < start[key] + 0)) {
        prio[key] = $1 + 0
        start[key] = $4 + 0
        row[key] = $0
        order[key] = NR
      }
    }
    END {
      n = 0
      for (k in row) { n++; keys[n] = k }
      for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
          if (order[keys[j]] + 0 < order[keys[i]] + 0) {
            tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp
          }
        }
      }
      for (i = 1; i <= n; i++) print row[keys[i]]
    }
  ' "$FM_STALL_WORK/signals.tsv"
}

_fm_stall_reconcile() {
  local cls sub start detect ended ref dur rec prio
  if [ -s "$FM_STALL_WORK/done.tsv" ]; then
    while IFS=$(printf '\t') read -r cls sub start detect ended || [ -n "${cls:-}" ]; do
      _fm_stall_is_num "$start" || continue
      _fm_stall_is_num "$detect" || continue
      _fm_stall_is_num "$ended" || continue
      [ $((ended - start)) -gt 600 ] || continue
      ref="$cls:$sub:$start"
      if _fm_stall_ref_exists "$ref"; then
        continue
      fi
      if _fm_stall_open_for "$cls" "$sub"; then
        continue
      fi
      if _fm_stall_signal_has "$cls" "$sub" 1; then
        continue
      fi
      dur=$((ended - start))
      _fm_stall_append "$FM_STALL_NOW" stall-open "$cls" "$sub" "$start" "$detect" - - - "$ref" || return 1
      _fm_stall_append "$FM_STALL_NOW" stall-close "$cls" "$sub" "$start" "$detect" watchdog "$ended" "$dur" "$ref" || return 1
    done < "$FM_STALL_WORK/done.tsv"
  fi
  _fm_stall_opens > "$FM_STALL_WORK/opens.tsv" || return 1
  while IFS=$(printf '\t') read -r cls sub ref start detect || [ -n "${cls:-}" ]; do
    if _fm_stall_signal_has "$cls" "$sub"; then
      continue
    fi
    _fm_stall_is_num "$start" || continue
    _fm_stall_is_num "$detect" || continue
    rec=$(_fm_stall_attribute "$cls" "$sub" "$detect" "$FM_STALL_NOW")
    if [ "$FM_STALL_NOW" -ge "$start" ]; then
      dur=$((FM_STALL_NOW - start))
    else
      dur=0
    fi
    _fm_stall_append "$FM_STALL_NOW" stall-close "$cls" "$sub" "$start" "$detect" "$rec" "$FM_STALL_NOW" "$dur" "$ref" || return 1
  done < "$FM_STALL_WORK/opens.tsv"
  if [ -s "$FM_STALL_WORK/signals.tsv" ]; then
    _fm_stall_choose_signals > "$FM_STALL_WORK/chosen.tsv" || return 1
    while IFS=$(printf '\t') read -r prio cls sub start detect || [ -n "${prio:-}" ]; do
      _fm_stall_is_num "$start" || continue
      _fm_stall_is_num "$detect" || continue
      [ $((FM_STALL_NOW - start)) -gt 600 ] || continue
      ref="$cls:$sub:$start"
      if _fm_stall_ref_exists "$ref"; then
        continue
      fi
      if _fm_stall_open_for "$cls" "$sub"; then
        continue
      fi
      _fm_stall_append "$FM_STALL_NOW" stall-open "$cls" "$sub" "$start" "$detect" - - - "$ref" || return 1
    done < "$FM_STALL_WORK/chosen.tsv"
  fi
}

_fm_stall_stamp() {
  printf '%s\n' "$FM_STALL_NOW" > "$STATE/.stall-ledger-observed" || return 1
}

_fm_stall_observe_cleanup() {
  if [ -n "${_fm_stall_lock:-}" ]; then
    if command -v fm_lock_release >/dev/null 2>&1; then
      fm_lock_release "$_fm_stall_lock" || true
    fi
  fi
  if [ -n "${_fm_stall_work:-}" ]; then
    rm -rf -- "$_fm_stall_work" || true
  fi
}

# fm_stall_ledger_observe
# Append rows for this home. Exit 0 when throttled or written, 1 on a write
# or lock failure. Return 2 is internal for the throttle and becomes 0.
fm_stall_ledger_observe() {
  local rc=0 _fm_stall_lock='' _fm_stall_work=''
  local FM_STALL_LEDGER='' FM_STALL_BORN='' FM_STALL_NOW='' FM_STALL_WORK=''
  local FM_STALL_SELF_CLASS='' FM_STALL_SELF_SUBJECT=''
  _fm_stall_prepare || rc=$?
  if [ "$rc" -eq 2 ]; then
    _fm_stall_observe_cleanup
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    _fm_stall_observe_cleanup
    return 1
  fi
  _fm_stall_interventions || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_handoffs || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_heartbeats || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_progress || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_wakes || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_watchdog || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_reconcile || rc=$?
  [ "$rc" -ne 0 ] || _fm_stall_stamp || rc=$?
  _fm_stall_observe_cleanup
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# fm_stall_ledger_score_paths
# Print this home's ledger, then each registered secondmate home's ledger.
fm_stall_ledger_score_paths() {
  local main meta kind home ledger mates=
  main=$(fm_stall_ledger_path "$STATE")
  if [ -f "$main" ] && [ ! -L "$main" ]; then
    printf '%s\n' "$main"
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(_fm_stall_meta_value "$meta" kind)
    [ "$kind" = secondmate ] || continue
    home=$(_fm_stall_meta_value "$meta" home)
    case "$home" in
      /*) ;;
      *) continue ;;
    esac
    [ "$home" = "$FM_HOME" ] && continue
    ledger=$home/state/stall-ledger.tsv
    [ -f "$ledger" ] && [ ! -L "$ledger" ] || continue
    [ "$ledger" = "$main" ] && continue
    mates="$mates$ledger"$'\n'
  done
  if [ -n "$mates" ]; then
    printf '%s' "$mates" | LC_ALL=C sort -u
  fi
}

# fm_stall_ledger_rows <since> <until>
# until empty means no upper bound. since empty means 0. Window is
# since <= epoch < until.
fm_stall_ledger_rows() {
  local since=${1:-0} until=${2:-} line
  set --
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done < <(fm_stall_ledger_score_paths)
  [ "$#" -gt 0 ] || return 0
  LC_ALL=C awk -F '\t' -v since="$since" -v until="$until" '
    function keep() {
      if (NF != 10 || $1 !~ /^[0-9]+$/) return 0
      if ($2 != "hb" && $2 != "stall-open" && $2 != "stall-close" && $2 != "handoff" && $2 != "intervention") return 0
      if ($3 != "primary" && $3 != "secondmate" && $3 != "worker") return 0
      if ($5 !~ /^[0-9]+$/) return 0
      if (($2 == "stall-open" || $2 == "stall-close" || $2 == "handoff") && $6 !~ /^[0-9]+$/) return 0
      return 1
    }
    {
      if (!keep()) next
      if ($1 + 0 < since + 0) next
      if (until != "" && $1 + 0 >= until + 0) next
      print
    }
  ' "$@"
}

# fm_stall_ledger_score <since> <until>
# Print PASS or FAIL, then one citation per failing bar. Exit 0 on PASS, 1 on FAIL.
# stall-duration, stall-open, and stall-recovery cite the open row.
# stall-recoverer cites the close row. A human close also cites intervention.
fm_stall_ledger_score() {
  local since=$1 until=$2 line rc=0
  set --
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- "$@" "$line"
  done < <(fm_stall_ledger_score_paths)
  [ "$#" -gt 0 ] || set -- /dev/null
  LC_ALL=C awk -F '\t' -v since="$since" -v until="$until" '
    function keep() {
      if (NF != 10 || $1 !~ /^[0-9]+$/) return 0
      if ($2 != "hb" && $2 != "stall-open" && $2 != "stall-close" && $2 != "handoff" && $2 != "intervention") return 0
      if ($3 != "primary" && $3 != "secondmate" && $3 != "worker") return 0
      if ($5 !~ /^[0-9]+$/) return 0
      if (($2 == "stall-open" || $2 == "stall-close" || $2 == "handoff") && $6 !~ /^[0-9]+$/) return 0
      return 1
    }
    function add(reason, row) {
      ncite++
      cite[ncite] = reason "\t" row
    }
    function exempt(cls, subject, epoch,    i) {
      for (i = 1; i <= nh; i++) {
        if (hc[i] == cls && hs[i] == subject && h0[i] <= epoch && epoch <= h1[i]) return 1
      }
      return 0
    }
    BEGIN { n = 0; ncite = 0; nh = 0; pcount = 0; ngap = 0 }
    {
      if (!keep()) next
      n++
      line[n] = $0
      ep[n] = $1 + 0
      ev[n] = $2
      cls[n] = $3
      subj[n] = $4
      st[n] = $5 + 0
      det[n] = $6 + 0
      who[n] = $7
      rend[n] = $8
      ref[n] = $10
      if ($2 == "stall-open" && !($10 in open_at)) open_at[$10] = n
      if ($2 == "stall-close") close_at[$10] = n
      if ($2 == "handoff") {
        span = ($6 + 0) - ($5 + 0)
        if (span >= 0 && span <= 600) {
          nh++
          hc[nh] = $3
          hs[nh] = $4
          h0[nh] = $5 + 0
          h1[nh] = $6 + 0
        }
      }
      if ($2 == "hb" && $3 == "primary" && ep[n] >= since + 0 && ep[n] < until + 0) {
        pcount++
        ptime[pcount] = ep[n]
      }
    }
    END {
      for (i = 2; i <= pcount; i++) {
        v = ptime[i]
        j = i - 1
        while (j >= 1 && ptime[j] > v) { ptime[j + 1] = ptime[j]; j-- }
        ptime[j + 1] = v
      }
      for (i = 1; i <= n; i++) {
        if (ev[i] == "intervention" && ep[i] >= since + 0 && ep[i] < until + 0) add("intervention", line[i])
        if (ev[i] == "stall-close" && who[i] == "human" && rend[i] ~ /^[0-9]+$/ && rend[i] + 0 >= since + 0 && rend[i] + 0 < until + 0) {
          add("intervention", line[i])
        }
        if (ev[i] == "hb" && ep[i] >= since + 0 && ep[i] < until + 0) {
          age = ep[i] - st[i]
          if (age > 600 && !exempt(cls[i], subj[i], ep[i])) add("heartbeat-age", line[i])
        }
        if (ev[i] != "stall-open") continue
        if (seen[ref[i]]) continue
        seen[ref[i]] = 1
        start = st[i]
        detect = det[i]
        recovered = 0
        recover = until + 0
        who_r = "-"
        if (ref[i] in close_at) {
          c = close_at[ref[i]]
          if (rend[c] ~ /^[0-9]+$/ && rend[c] + 0 < until + 0) {
            recovered = 1
            recover = rend[c] + 0
            who_r = who[c]
          }
        }
        end = recovered ? recover : (until + 0)
        if (!(start < until + 0 && end > since + 0)) continue
        dur = end - start
        if (dur <= 600) continue
        if (dur > 1800) add("stall-duration", line[i])
        if (!recovered) {
          add("stall-open", line[i])
          if (detect >= until + 0 || (until + 0) - detect > 1200) add("stall-recovery", line[i])
        } else {
          if (detect >= until + 0 || recover - detect > 1200) add("stall-recovery", line[i])
          if (who_r != "firstmate" && who_r != "agentkit" && who_r != "watchdog") add("stall-recoverer", line[c])
        }
      }
      if (pcount == 0) {
        ngap = 0
      } else {
        if (ptime[1] - (since + 0) > 600) {
          ngap++
          gap[ngap] = sprintf("heartbeat-gap\tprimary\t%d\t%d", since + 0, ptime[1])
        }
        for (i = 2; i <= pcount; i++) {
          if (ptime[i] - ptime[i - 1] > 600) {
            ngap++
            gap[ngap] = sprintf("heartbeat-gap\tprimary\t%d\t%d", ptime[i - 1], ptime[i])
          }
        }
        if ((until + 0) - ptime[pcount] > 600) {
          ngap++
          gap[ngap] = sprintf("heartbeat-gap\tprimary\t%d\t%d", ptime[pcount], until + 0)
        }
      }
      fails = (pcount == 0) || ncite > 0 || ngap > 0
      if (fails) print "FAIL"
      else print "PASS"
      if (pcount == 0) print "heartbeat-missing\tprimary"
      for (i = 1; i <= ncite; i++) print cite[i]
      for (i = 1; i <= ngap; i++) print gap[i]
      exit (fails ? 1 : 0)
    }
  ' "$@" || rc=$?
  return "$rc"
}
