#!/usr/bin/env bash
# fm-host-cleanup.sh - periodic host disk hygiene (scale plan S3): report free
# space and the biggest worktrees, and delete only whole old regenerable cache
# and log entries so a full disk never blocks the fleet.
#
# Usage:
#   fm-host-cleanup.sh report
#       Print free space, each cache and log root's size and whole-entry
#       reclaim estimate, and the size of every directory directly under
#       each worktree root. Deletes nothing.
#   fm-host-cleanup.sh clean
#       Dry run: print what clean --apply would delete and the same
#       worktree size lines report prints. Deletes nothing.
#   fm-host-cleanup.sh clean --apply
#       Delete every old entry under the cache and log roots, print the
#       worktree size lines, and append one before/after line to the log.
#       This is the mode a launchd or cron job runs.
#   fm-host-cleanup.sh render-launchd
#       Print a home-scoped LaunchAgent plist that runs clean --apply every
#       6 hours (21600 seconds) with RunAtLoad and no KeepAlive retry loop,
#       capturing HOME, PATH, and any FM_CLEANUP_* overrides. Its stdout and
#       stderr, the whole disk and worktree report of each run, go to
#       cleanup-run.log beside the log below. It only renders XML and never
#       installs, starts, or restarts a service. Create the log directory
#       (mkdir -p), save the output as ~/Library/LaunchAgents/<Label>.plist,
#       then explicitly activate:
#         launchctl bootstrap gui/$(id -u) <absolute-plist-path>
#       Rollback: launchctl bootout gui/$(id -u)/<Label>
#   fm-host-cleanup.sh --help
#
# What may be deleted, and nothing else: whole entries. An entry is one
# immediate child of a cache or log root (a directory such as
# ~/.cache/pre-commit, or a regular file directly under the root). An entry
# is old only when the newest mtime of anything inside it, the entry itself
# included, is older than the age limit: FM_CLEANUP_AGE_DAYS days (default
# 7) under a cache root, FM_CLEANUP_LOG_AGE_DAYS days (default 14) under a
# log root. An old entry is removed whole; any other entry is left fully
# intact, old files included, so a cache whose index is still fresh is never
# half-deleted. An entry that cannot be fully read is never treated as old.
# report and clean count entries by this same rule.
# Default cache roots: $HOME/Library/Caches, $HOME/.cache, and
# $HOME/.npm, so npm's _cacache (content-v2 with its index-v5) is one entry.
# Default log roots: $HOME/Library/Logs.
# FM_CLEANUP_CACHE_ROOTS and FM_CLEANUP_LOG_ROOTS replace them (colon list).
# Worktree roots (default $HOME/orca/workspaces, FM_CLEANUP_WORKTREE_ROOTS)
# are measured for the report and never deleted from: project files, tracked
# or untracked, are out of this script's reach by construction. Docker and
# OrbStack volumes are never touched; pruning them stays a separate,
# explicit step.
#
# Free space is read on FM_CLEANUP_VOLUME (default /System/Volumes/Data, or /
# where that path is absent). FM_CLEANUP_TARGET_GIB (default 100) is the
# health line: report and clean exit 3 while free space is under it, so the
# periodic job's log shows the blocker instead of looking healthy. Usage
# errors exit 2. An entry whose delete fails is counted in
# remaining_old_entries, never hidden.
#
# Log: ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/host-cleanup/cleanup.log
# FM_CLEANUP_DIR overrides that directory. Only clean --apply writes it.
# FM_TEST_SEAM=1 lets tests replace the volume with FM_CLEANUP_VOLUME and df
# with a PATH stub; no other mode reads FM_CLEANUP_VOLUME.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_DIR=${FM_CLEANUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/host-cleanup}
AGE_DAYS=${FM_CLEANUP_AGE_DAYS:-7}
LOG_AGE_DAYS=${FM_CLEANUP_LOG_AGE_DAYS:-14}
TARGET_GIB=${FM_CLEANUP_TARGET_GIB:-100}
CACHE_ROOTS=${FM_CLEANUP_CACHE_ROOTS:-$HOME/Library/Caches:$HOME/.cache:$HOME/.npm}
LOG_ROOTS=${FM_CLEANUP_LOG_ROOTS:-$HOME/Library/Logs}
WORKTREE_ROOTS=${FM_CLEANUP_WORKTREE_ROOTS:-$HOME/orca/workspaces}

if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_CLEANUP_VOLUME:-}" ]; then
  VOLUME=$FM_CLEANUP_VOLUME
else
  VOLUME=/System/Volumes/Data
  [ -d "$VOLUME" ] || VOLUME=/
fi

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  echo "usage: fm-host-cleanup.sh report|clean [--apply]|render-launchd|--help" >&2
  exit 2
}

free_kib_read() {
  df -Pk "$VOLUME" 2>/dev/null | awk 'NR==2 { print $4 }'
}

gib_of() {
  awk -v k="$1" 'BEGIN { if (k ~ /^[0-9]+$/) printf "%.1f", k / 1048576; else print "unknown" }'
}

under_target() {  # <free_kib>: true when a known reading is under the target
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  awk -v k="$1" -v t="$TARGET_GIB" 'BEGIN { exit !(k < t * 1048576) }'
}

old_entries() {  # <root> <days>: print NUL-separated old entries of root
  local root=$1 days=$2 entry scratch
  [ -d "$root" ] || return 0
  scratch=$(mktemp) || return 0
  find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
    | while IFS= read -r -d '' entry; do
        # No -quit: it is not in every find. A failed read keeps the entry.
        if find "$entry" ! -mtime +"$days" -print > "$scratch" 2>/dev/null \
          && [ ! -s "$scratch" ]; then
          printf '%s\0' "$entry"
        fi
      done
  rm -f "$scratch"
}

# Prints "<entries> <kib>" for the old entries under root $1 (age $2 days).
old_entries_stats() {
  old_entries "$1" "$2" \
    | while IFS= read -r -d '' entry; do
        du -sk "$entry" 2>/dev/null | awk '{ print $1; exit }'
      done \
    | awk '{ n++; s += $1 } END { printf "%d %d\n", n + 0, s + 0 }'
}

root_size_kib() {
  [ -d "$1" ] || { printf '0\n'; return 0; }
  du -sk "$1" 2>/dev/null | awk '{ print $1 }'
}

each_root() {  # <colon-list>: print one existing-or-not root per line
  printf '%s\n' "$1" | tr ':' '\n'
}

worktree_report() {
  local root child
  each_root "$WORKTREE_ROOTS" | while IFS= read -r root; do
    [ -d "$root" ] || continue
    for child in "$root"/*; do
      [ -d "$child" ] || continue
      printf 'host-cleanup worktrees: root=%s size_kib=%s\n' "$child" "$(root_size_kib "$child")"
    done
  done
}

cmd_report() {
  local free root stats
  free=$(free_kib_read)
  printf 'host-cleanup report: free_kib=%s free_gib=%s target_gib=%s volume=%s\n' \
    "${free:-unknown}" "$(gib_of "${free:-}")" "$TARGET_GIB" "$VOLUME"
  each_root "$CACHE_ROOTS" | while IFS= read -r root; do
    [ -n "$root" ] || continue
    stats=$(old_entries_stats "$root" "$AGE_DAYS")
    printf 'host-cleanup cache: root=%s size_kib=%s old_entries=%s old_kib=%s age_days=%s\n' \
      "$root" "$(root_size_kib "$root")" \
      "$(printf '%s' "$stats" | awk '{ print $1 }')" \
      "$(printf '%s' "$stats" | awk '{ print $2 }')" "$AGE_DAYS"
  done
  each_root "$LOG_ROOTS" | while IFS= read -r root; do
    [ -n "$root" ] || continue
    stats=$(old_entries_stats "$root" "$LOG_AGE_DAYS")
    printf 'host-cleanup logs: root=%s size_kib=%s old_entries=%s old_kib=%s age_days=%s\n' \
      "$root" "$(root_size_kib "$root")" \
      "$(printf '%s' "$stats" | awk '{ print $1 }')" \
      "$(printf '%s' "$stats" | awk '{ print $2 }')" "$LOG_AGE_DAYS"
  done
  worktree_report
  if under_target "$free"; then
    echo "host-cleanup: free space is under the ${TARGET_GIB} GiB target" >&2
    exit 3
  fi
}

# Removes the old entries under $1 (older than $2 days) when $3 is 1.
# Prints "<entries_before> <kib_before> <entries_after>".
clean_root() {
  local root=$1 days=$2 apply=$3 before after entry
  before=$(old_entries_stats "$root" "$days")
  if [ "$apply" = 1 ]; then
    old_entries "$root" "$days" \
      | while IFS= read -r -d '' entry; do rm -rf -- "$entry" 2>/dev/null; done
  fi
  after=$(old_entries_stats "$root" "$days")
  printf '%s %s\n' "$before" "$(printf '%s' "$after" | awk '{ print $1 }')"
}

cmd_clean() {
  local apply=0
  case "${1:-}" in
    --apply) apply=1 ;;
    '') : ;;
    *) die_usage ;;
  esac
  [ $# -le 1 ] || die_usage
  local free_before free_after root result mode_word
  free_before=$(free_kib_read)
  if [ "$apply" = 1 ]; then mode_word=apply; else mode_word=dry-run; fi
  printf 'host-cleanup clean: mode=%s free_before_kib=%s free_before_gib=%s\n' \
    "$mode_word" "${free_before:-unknown}" "$(gib_of "${free_before:-}")"
  each_root "$CACHE_ROOTS:$LOG_ROOTS" | while IFS= read -r root; do
    [ -n "$root" ] || continue
    case ":$LOG_ROOTS:" in
      *":$root:"*) result=$(clean_root "$root" "$LOG_AGE_DAYS" "$apply") ;;
      *) result=$(clean_root "$root" "$AGE_DAYS" "$apply") ;;
    esac
    printf 'host-cleanup clean: root=%s old_entries=%s old_kib=%s remaining_old_entries=%s\n' \
      "$root" \
      "$(printf '%s' "$result" | awk '{ print $1 }')" \
      "$(printf '%s' "$result" | awk '{ print $2 }')" \
      "$(printf '%s' "$result" | awk '{ print $3 }')"
  done
  worktree_report
  free_after=$(free_kib_read)
  printf 'host-cleanup clean: mode=%s free_after_kib=%s free_after_gib=%s target_gib=%s\n' \
    "$mode_word" "${free_after:-unknown}" "$(gib_of "${free_after:-}")" "$TARGET_GIB"
  if [ "$apply" = 1 ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null && \
      printf '%s clean free_before_kib=%s free_after_kib=%s target_gib=%s volume=%s\n' \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" "${free_before:-unknown}" "${free_after:-unknown}" \
        "$TARGET_GIB" "$VOLUME" >> "$STATE_DIR/cleanup.log"
  fi
  if under_target "$free_after"; then
    echo "host-cleanup: free space is still under the ${TARGET_GIB} GiB target after clean" >&2
    exit 3
  fi
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

cmd_render_launchd() {
  local sum key
  read -r sum _ <<EOF
$(printf '%s' "$HOME" | cksum)
EOF
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.firstmate.host-cleanup-$sum</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$(printf '%s' "$SCRIPT_DIR/fm-host-cleanup.sh" | xml_escape)</string><string>clean</string><string>--apply</string>
  </array>
  <key>EnvironmentVariables</key><dict>
EOF
  for key in HOME PATH FM_CLEANUP_DIR FM_CLEANUP_AGE_DAYS FM_CLEANUP_LOG_AGE_DAYS FM_CLEANUP_TARGET_GIB \
    FM_CLEANUP_CACHE_ROOTS FM_CLEANUP_LOG_ROOTS FM_CLEANUP_WORKTREE_ROOTS; do
    case "$key" in HOME|PATH) ;; *) [ -n "${!key:-}" ] || continue ;; esac
    printf '    <key>%s</key><string>%s</string>\n' "$key" "$(printf '%s' "${!key:-}" | xml_escape)"
  done
  cat <<EOF
  </dict>
  <key>StandardOutPath</key><string>$(printf '%s' "$STATE_DIR/cleanup-run.log" | xml_escape)</string>
  <key>StandardErrorPath</key><string>$(printf '%s' "$STATE_DIR/cleanup-run.log" | xml_escape)</string>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>21600</integer>
</dict></plist>
EOF
}

case "${1:-}" in
  report) shift; [ $# -eq 0 ] || die_usage; cmd_report ;;
  render-launchd) shift; [ $# -eq 0 ] || die_usage; cmd_render_launchd ;;
  clean) shift; cmd_clean "$@" ;;
  --help|-h) usage ;;
  *) die_usage ;;
esac
