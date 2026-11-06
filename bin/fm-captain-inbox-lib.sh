#!/usr/bin/env bash
# fm-captain-inbox-lib.sh - the one owner of the unread captain inbox age rule.
#
# fm_captain_inbox_unread_age_seconds <inbox-dir>
#   Print the age in seconds of the oldest pending captain inbox note (a
#   *.note file still in <inbox-dir>; handled notes live elsewhere and no
#   longer count), measured with one mtime helper and one clock. Print
#   nothing when no note is pending. Callers render that empty result as
#   their surface's null. bin/fm-inbox.sh ready and bin/fm-heartbeat.sh both
#   publish this value, so the two surfaces cannot drift apart.

fm_captain_inbox_note_mtime() {  # <file>
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

fm_captain_inbox_unread_age_seconds() {  # <inbox-dir>
  local dir=$1 f m oldest='' now age
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.note; do
    [ -f "$f" ] || continue
    m=$(fm_captain_inbox_note_mtime "$f") || continue
    if [ -z "$oldest" ] || [ "$m" -lt "$oldest" ]; then
      oldest=$m
    fi
  done
  [ -n "$oldest" ] || return 0
  now=$(date +%s)
  age=$((now - oldest))
  [ "$age" -ge 0 ] || age=0
  printf '%s\n' "$age"
}
