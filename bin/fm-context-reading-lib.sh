#!/usr/bin/env bash
# fm-context-reading-lib.sh - the one shared context reading for a Claude
# session read from outside it. Sourced, never executed. Callers source
# bin/fm-context-footer-lib.sh and bin/fm-warm-compact-lib.sh first.
#
# TWO READINGS.
#   footer   the harness's own "N% until auto-compact" pane text, parsed by
#            fm_context_footer_percent_from_text (the one footer parser)
#   derived  100 - used*100/window, floored at 0, where used is the last
#            request's context tokens (fm_warm_compact_context_tokens) and
#            window is the session's auto-compact point
# The full-window status percentage is never a reading here.
#
# THE WINDOW. The early handoff trigger (bin/fm-handoff-trigger.sh) resolves
# the auto-compact point inside the session and publishes it on each run to
# <home>/state/compact-point; that hook's header owns the record's format.
# A reader outside the session takes compact_at only when that record names
# the session it reads. Otherwise, or with no record, the compact-at-tokens
# pin of <home>/config/handoff-trigger is the fallback. With neither there is
# no window and no derived reading.
#
# THE OWNER. derived when a derived reading exists, footer when only the footer
# exists, none otherwise. A caller decides on the owner's value; owner none
# reports unknown and never drives a decision by itself.
#
# DISAGREEMENT (config/context-reading, optional; docs/configuration.md
# "Context reading" owns the schema). While disagreement-points is unset the
# flag is `-`. Once set it is 1 when both readings exist and differ by more
# than that many points, else 0.
#
#   fm_context_window_for_session <home> <session-id>
#   fm_context_derived_percent <transcript> <window-tokens>
#   fm_context_reading <home> <session-id> <transcript> <pane-text-file>
#       the pane text file may be any readable path, such as a process
#       substitution; it is parsed in the C locale, so stray bytes in pane
#       text never break the parse
#       prints footer=<pct|unknown> derived=<pct|unknown>
#       owner=derived|footer|none disagreement=<0|1|->

# _fm_context_config_value <file> <key> [zero-ok]: print the last usable
# integer for <key>. A value with a non-digit or a leading zero counts as
# unset; a bare 0 counts only with zero-ok.
_fm_context_config_value() {
  local file=$1 want=$2 zero=${3:-} line key value found=''
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$value:$zero" = 0:zero-ok ] || case "$value" in '' | 0* | *[!0-9]*) continue ;; esac
    [ "$key" = "$want" ] && found=$value
  done < "$file"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_context_window_for_session() {  # <home> <session-id>
  local home=$1 session=$2 line rec_session rec_at
  if [ -n "$session" ] && [ -f "$home/state/compact-point" ]; then
    IFS= read -r line < "$home/state/compact-point" || [ -n "$line" ] || line=''
    rec_session=$(printf '%s\n' "$line" | sed -n 's/^session=\([^ ]*\) compact_at=[0-9][0-9]* at=[0-9]*$/\1/p')
    rec_at=$(printf '%s\n' "$line" | sed -n 's/^session=[^ ]* compact_at=\([1-9][0-9]*\) at=[0-9]*$/\1/p')
    if [ -n "$rec_at" ] && [ "$rec_session" = "$session" ]; then
      printf '%s\n' "$rec_at"
      return 0
    fi
  fi
  _fm_context_config_value "$home/config/handoff-trigger" compact-at-tokens
}

fm_context_derived_percent() {  # <transcript> <window-tokens>
  local transcript=$1 window=$2 used left
  case "$window" in '' | 0* | *[!0-9]*) return 1 ;; esac
  [ -n "$transcript" ] || return 1
  used=$(fm_warm_compact_context_tokens "$transcript") || return 1
  case "$used" in '' | *[!0-9]*) return 1 ;; esac
  left=$((100 - used * 100 / window))
  [ "$left" -ge 0 ] || left=0
  printf '%s\n' "$left"
}

fm_context_reading() {  # <home> <session-id> <transcript> <pane-text-file>
  local home=$1 session=$2 transcript=$3 pane=$4 footer='' derived='' window owner=none flag=- bound gap
  if [ -n "$pane" ] && [ -r "$pane" ]; then
    footer=$(LC_ALL=C fm_context_footer_percent_from_text < "$pane") || footer=''
  fi
  window=$(fm_context_window_for_session "$home" "$session") || window=''
  [ -z "$window" ] || derived=$(fm_context_derived_percent "$transcript" "$window") || derived=''
  if [ -n "$derived" ]; then owner=derived; elif [ -n "$footer" ]; then owner=footer; fi
  if bound=$(_fm_context_config_value "$home/config/context-reading" disagreement-points zero-ok); then
    flag=0
    if [ -n "$footer" ] && [ -n "$derived" ]; then
      gap=$((footer - derived))
      [ "$gap" -ge 0 ] || gap=$((-gap))
      [ "$gap" -le "$bound" ] || flag=1
    fi
  fi
  printf 'footer=%s derived=%s owner=%s disagreement=%s\n' "${footer:-unknown}" "${derived:-unknown}" "$owner" "$flag"
}
