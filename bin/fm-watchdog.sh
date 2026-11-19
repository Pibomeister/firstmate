#!/usr/bin/env bash
# fm-watchdog.sh - the per-machine firstmate assistant watchdog.
#
# Usage: FM_HOME=<owner-home> fm-watchdog.sh <command>
#   run [--interval <secs>]       Foreground loop for launchd or systemd; one instance.
#   once [--dry-run] [--home <path>]
#                                 One scan and action pass, then rewrite the status file.
#   scan [--home <path>]          One observation pass; prints each subject and its workers' dialog reads; no action.
#   judge <purpose> <answer-ere>  Bounded cheap-model call; prompt on stdin; prints the answer.
#   council --task <id> --key <key> [--home <path>] [--record-file <file>]
#                                 One blind council on one decision, now. The record is the
#                                 complete file, else its complete open decision; records over
#                                 2000 characters are refused. Dry-run never returns an answer. Prints
#                                 council=<ruled|no-ruling|held|dry-run|refused|busy|failed>
#                                 answer=<PROCEED x|none> record=<path|none> prior=<0|1> seats=<answers>.
#   status                        Print the status file.
#   ack-read                      Record that the status file was read now.
#   pickup <token>                Run by a restarted session to prove it took over.
#   monitor-read                  Record FM_HOME's monitor unit status.
#   manager-name | manager-status | render-launchd | render-systemd
#
# The watchdog layers above the watcher, the away daemon, and
# bin/fm-monitor-watchdog.sh; it changes none of them. It runs outside every
# agent session, never in a terminal pane. docs/watchdog.md owns the behavior
# contract (subjects, symptoms, the action ladder, hard boundaries, the status
# file) and the config/watchdog keys. This header owns the commands and files.
#
# Files, all under the owner home FM_HOME:
#   config/watchdog              key=value configuration; absent means dry-run defaults.
#   state/watchdog/actions.tsv   action ledger: epoch id home subject symptom action phase detail.
#   state/watchdog/model-calls.tsv  epoch purpose model outcome in-tokens out-tokens answer cost.
#   state/watchdog/subjects/<home-basename>-<path-cksum>   the previous observation of each subject.
#   state/watchdog/near-loop/<home-basename>-<path-cksum>  epoch, evidence cksum, and answer of the last near-loop judgment.
#   state/watchdog/escalated/<home-basename>-<path-cksum>  present after a restart loop; remove it to clear.
#   state/watchdog/permission/<home-basename>-<path-cksum>-<task>.open      key and prompt checksum of the
#                                worker prompt this watchdog reported as blocked and has not yet resolved.
#   state/watchdog/permission/<home-basename>-<path-cksum>-<task>.declined  checksums of the worker prompts it declined.
#   state/watchdog/last-read     epoch of the last ack-read.
#   state/night-score/supervisor-gap.tsv  append-only supervisor-gap record of every watched home; docs/watchdog.md owns its rows.
#   state/night-score/supervisor-activity.tsv  append-only activity-source record of every watched home; docs/watchdog.md owns its rows.
#   <watched home>/state/quota-guard/, <watched home>/state/quota-limit-dialogs.tsv
#                                written by bin/fm-quota-guard.sh, whose header owns them.
#   state/memory-guard*.tsv      the owner home's host memory and swap samples,
#                                written by bin/fm-memory-guard.sh, whose header owns them.
#   data/watchdog/status.md      the short status file, rewritten atomically after each pass.
#   data/watchdog/handoffs/, data/watchdog/rulings/  restart handoffs and council rulings.
#   data/watchdog/no-rulings/    the record of each council that gave no ruling.
#   state/watchdog/council-locks/  one owner-identity lock per running council.
# Council locators are Git blob IDs of NUL-separated home/task/key tuples;
# authenticated legacy filenames remain readable. Hashing uses the code root.
# A restarted session writes <its home>/state/watchdog/pickups/<token>.
#   <watched home>/state/watchdog/captain  key=value record of that home's live
#                                captain, rewritten each pass and by pickup.
#   <watched home>/state/monitor-status  one-line record of that home's monitor
#                                unit status, rewritten atomically each pass and by monitor-read.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_WD_NOW fixes the clock,
# FM_WD_TEST_COMPOSER replaces the composer verdict for a plain test pane, and
# FM_WD_TEST_CONTROL replaces bin/fm-control.sh for the trust-dialog relaunch.
#
# Exit status: 0 on success, 2 on a usage error, 1 on any other failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME must name the watchdog owner home}
OWNER_HOME=$FM_HOME
STATE=${FM_STATE_OVERRIDE:-$OWNER_HOME/state}
CONF=$OWNER_HOME/config/watchdog
WD=$STATE/watchdog
OUT=$OWNER_HOME/data/watchdog
LEDGER=$WD/actions.tsv
CALLS=$WD/model-calls.tsv
WD_COUNCIL_MAX_CHARS=2000

# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"
# A boot-time launchd or systemd PATH can omit ~/.local/bin, where a
# self-updated herdr lives, and then resolve an older package-managed copy that
# starts a server the rest of the fleet cannot drive. Every command, including
# render-launchd and render-systemd, uses the same normalized PATH, so any tool
# in ~/.local/bin, not only herdr, wins over a package-managed copy, as it does
# in an interactive Firstmate shell.
PATH=$(fm_wd_user_bin_path "$PATH" "${HOME:-}")
export PATH
# shellcheck source=bin/fm-permission-prompt.sh
. "$SCRIPT_DIR/fm-permission-prompt.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-secret-lib.sh
. "$SCRIPT_DIR/fm-secret-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Direct `orca` execs below cannot see a shell function. Invalidate after a
# send or create so a cached supervision read is not served past that mutation.
# shellcheck source=bin/fm-orca-cli-cache.sh
. "$SCRIPT_DIR/fm-orca-cli-cache.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
# shellcheck source=bin/fm-context-footer-lib.sh
. "$SCRIPT_DIR/fm-context-footer-lib.sh"
# shellcheck source=bin/fm-context-reading-lib.sh
. "$SCRIPT_DIR/fm-context-reading-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

die() { printf 'fm-watchdog: %s\n' "$1" >&2; exit "${2:-1}"; }

wd_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WD_NOW:-}" ]; then printf '%s\n' "$FM_WD_NOW"; else date +%s; fi
}
cfg() { fm_wd_conf_get "$CONF" "$1" "$2"; }
cfgi() { fm_wd_conf_int "$CONF" "$1" "$2"; }

wd_mode() {
  case "${WD_FORCE_DRY:-}:$(cfg mode dry-run)" in
    1:*) printf 'dry-run\n' ;;
    *:act) printf 'act\n' ;;
    *) printf 'dry-run\n' ;;
  esac
}

# The decision path has its own switch: the decision nudge, the council, and the
# ruling nudge. An unset `decisions` follows `mode`; any value but `act` is a dry run.
wd_decisions_mode() {
  case "${WD_FORCE_DRY:-}:$(cfg decisions '')" in
    1:*) printf 'dry-run\n' ;;
    *:) wd_mode ;;
    *:act) printf 'act\n' ;;
    *) printf 'dry-run\n' ;;
  esac
}

# Worker permission prompts have their own switch. An unset `permission-route`
# follows `mode`, `off` runs no classifier and keeps the report-only gap and
# page for the dialogs fm_wd_pane_dialog reads, `act` acts even when `mode` is
# dry-run, and any other value is a dry run.
wd_permission_mode() {
  case "${WD_FORCE_DRY:-}:$(cfg permission-route '')" in
    *:off) printf 'off\n' ;;
    1:*) printf 'dry-run\n' ;;
    *:) wd_mode ;;
    *:act) printf 'act\n' ;;
    *) printf 'dry-run\n' ;;
  esac
}

WD_CONTROL=$SCRIPT_DIR/fm-control.sh
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WD_TEST_CONTROL:-}" ]; then WD_CONTROL=$FM_WD_TEST_CONTROL; fi

# The mode one nudge runs under: the decision path sets WD_NUDGE_MODE for its own.
wd_nudge_mode() { printf '%s\n' "${WD_NUDGE_MODE:-$(wd_mode)}"; }

# GNU stat's -f writes filesystem data, so select the platform dialect once.
if [ "$(uname -s)" = Darwin ]; then
  wd_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  wd_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

wd_tag() { basename "$1"; }

# File names for one home's state: the basename can repeat across homes.
wd_state_key() { printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | cksum | cut -d ' ' -f 1)"; }

# A zombie answers kill -0 but has exited.
wd_pid_alive() {  # <pid>
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
  return 0
}

wd_id() { printf 'wd%s%s' "$(wd_now)" "$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; }

# --- subjects ----------------------------------------------------------------

wd_homes() {
  cfg homes "$OWNER_HOME" | tr ',' '\n' | sed -e 's/^[[:blank:]]*//' -e 's/[[:blank:]]*$//' -e '/^$/d'
}

# Prints home TAB parent TAB secondmate-id; the parent and id are `-` for a primary.
wd_subjects() {
  local h reg
  wd_homes | while IFS= read -r h; do
    [ -d "$h/state" ] || continue
    h=$(cd -P -- "$h" && pwd -P) || continue
    printf '%s\t-\t-\n' "$h"
    reg=$h/data/secondmates.md
    [ -f "$reg" ] || continue
    LC_ALL=C sed -nE 's/^- ([A-Za-z0-9._-]+) - .*\(home: ([^;)]+)[;)].*/\1	\2/p' "$reg" |
      while IFS=$'\t' read -r id sm; do
        [ -d "$sm/state" ] || continue
        sm=$(cd -P -- "$sm" && pwd -P) || continue
        printf '%s\t%s\t%s\n' "$sm" "$h" "$id"
      done
  done | awk -F'\t' '!seen[$1]++'
}

wd_do_not_touch() {  # <home> <target>
  local entry canon
  while IFS= read -r entry; do
    canon=$( [ -d "$entry" ] && cd -P -- "$entry" && pwd -P )
    [ "$canon" = "$1" ] || [ "$entry" = "$2" ] || [ "$entry" = "$(wd_tag "$1")" ] && return 0
  done < <(cfg do-not-touch "" | tr ',' '\n' | sed -e 's/^[[:blank:]]*//' -e 's/[[:blank:]]*$//' -e '/^$/d')
  return 1
}

# --- observation ---------------------------------------------------------------

wd_cpu_seconds() {  # <pid>
  ps -o time= -p "$1" 2>/dev/null | awk '
    NF { s = $1; d = 0; if (index(s, "-")) { split(s, dd, "-"); d = dd[1]; s = dd[2] }
         n = split(s, p, ":"); t = 0; for (i = 1; i <= n; i++) t = t * 60 + p[i]; printf "%.2f\n", t + d * 86400 }'
}

wd_pane_sig() {  # <screen>
  printf '%s\n' "$1" | fm_wd_strip_ansi | LC_ALL=C tr -d '0-9' | LC_ALL=C sed -e 's/[✻✽✶✳✢·*⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●◐◓◑◒]//g' | cksum | awk '{print $1}'
}

wd_capture() {  # <backend> <target> <lines>
  fm_run_timed_fn "$(cfgi call-timeout-secs 20)" fm_backend_capture "$1" "$2" "$3" 2>/dev/null
}

# The cause of a failed herdr read when it is a client and server protocol
# mismatch on the target's session, else nothing (bin/backends/herdr.sh
# fm_backend_herdr_client_mismatch). It never starts or stops a server.
wd_herdr_mismatch() {  # <herdr-target>
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_client_mismatch "$FM_BACKEND_HERDR_SESSION"
}

# Match fm-control.sh usage_limit_dialog_name: a viewport read is expected
# only on backends in FM_BACKEND_VISIBLE_CAPTURE, or Orca with a recorded
# Droid frame. Callers that need history keep using wd_capture.
wd_visible_capture_expected() {  # <backend> <target> [expected-label]
  fm_backend_visible_capture_supported "$1" 2>/dev/null && return 0
  [ "$1" = orca ] || return 1
  fm_backend_source orca >/dev/null 2>&1 || return 1
  fm_backend_orca_recorded_droid "$2" "${3:-}" 2>/dev/null
}

# wd_view: the visible viewport where a viewport read is expected.
# A successful blank screen stays success (exit 0). A failed expected
# read stays failure. Unsupported backends never attempt a viewport
# primitive; they do not fall back to scrollback here, so a dismissed
# Grok frame in history cannot look like a live close.
wd_view() {  # <backend> <target> [expected-label]
  local b=$1 t=$2 label=${3-}
  if [ -z "$label" ]; then
    case "${O_ID:-}" in ''|-) ;; *) label=fm-$O_ID ;; esac
  fi
  wd_visible_capture_expected "$b" "$t" "$label" || return 1
  fm_run_timed_fn "$(cfgi call-timeout-secs 20)" fm_backend_visible_capture "$b" "$t" ${label:+"$label"} 2>/dev/null
}

# Permission from scrollback (main). Remaining dialogs use the viewport
# when a viewport read is expected: a failed read is unknown (no dialog
# action, no quota pick), and a successful blank screen is none.
# Backends without a viewport keep classifying from scrollback.
wd_observe_dialog() {  # <backend> <target> [expected-label] [harness]
  local b=$1 t=$2 label=${3-} harness=${4-} scroll view dialog
  if [ -z "$label" ]; then
    case "${O_ID:-}" in ''|-) ;; *) label=fm-$O_ID ;; esac
  fi
  scroll=$(wd_capture "$b" "$t" 60) || scroll=
  dialog=$(fm_wd_observe_dialog "$scroll" "$harness") || dialog=
  case "$dialog" in
    permission)
      printf '%s\n' permission
      return 0
      ;;
  esac
  if wd_visible_capture_expected "$b" "$t" "$label"; then
    view=$(wd_view "$b" "$t" "$label") || {
      printf '%s\n' unknown
      return 0
    }
    fm_wd_observe_dialog "$view" "$harness"
    return
  fi
  [ -n "$dialog" ] || return 1
  printf '%s\n' "$dialog"
}

wd_turn_running() {  # <backend> <target> <screen> -> 1|0|unknown
  local b=$1 t=$2 screen=$3 v
  if printf '%s\n' "$screen" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = n - 7; i <= n; i++) if (i > 0 && tolower(r[i]) ~ /(esc|ctrl\+c) to (interrupt|cancel)/) f = 1; exit !f }'; then
    printf '1\n'; return 0
  fi
  case "$b" in
    orca)
      if v=$(fm_run_timed 10 orca terminal wait --terminal "$t" --for tui-idle --timeout-ms 500 --json 2>/dev/null); then
        printf '0\n'
      elif printf '%s' "$v" | jq -e '.ok == false and .error.code == "timeout"' >/dev/null 2>&1; then
        printf '1\n'
      else
        printf 'unknown\n'
      fi ;;
    herdr|rex|t3code|tern)
      v=$(fm_run_timed_fn 10 fm_backend_busy_state "$b" "$t" 2>/dev/null)
      case "$v" in busy|working) printf '1\n' ;; idle|done) printf '0\n' ;; *) printf 'unknown\n' ;; esac ;;
    *) printf '0\n' ;;
  esac
}

wd_transcript() {  # <home> <session-id>
  local home=$1 sid=$2 d dirs
  case "$sid" in ''|*/*|*..*) return 1 ;; esac
  dirs="$(cfg claude-config-dirs "" | tr ',' ' ') $(head -n 1 "$home/config/claude-account" 2>/dev/null) ${CLAUDE_CONFIG_DIR:-} $HOME/.claude"
  for d in $dirs; do
    [ -d "$d/projects" ] || continue
    CLAUDE_CONFIG_DIR=$d fm_warm_compact_engine_transcript "$sid" 2>/dev/null && return 0
  done
  return 1
}

# Prints task TAB key TAB verb TAB age TAB summary for each open decision in <state>.
wd_open_decisions() {  # <state> <now>
  local st=$1 now=$2 f task key verb summary at
  for f in "$st"/*.status; do
    [ -f "$f" ] || continue
    task=$(basename "$f" .status)
    { status_open_decisions "$f" 2>/dev/null; printf '\n'; } | while IFS=$'\t' read -r key verb summary; do
      [ -n "$key" ] || continue
      at=$(grep -F "[key=$key]" "$f" 2>/dev/null | tail -n 1 | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p')
      [ -n "$at" ] || at=$(wd_mtime "$f")
      printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$key" "$verb" "$((now - at))" "$(printf '%s' "$summary" | tr '\t' ' ')"
    done
  done
}

# Prints task TAB age TAB line for each task whose latest status is a quota pause or block.
wd_quota_floors() {  # <state> <now>
  local st=$1 now=$2 f last at
  for f in "$st"/*.status; do
    [ -f "$f" ] || continue
    last=$(tail -n 1 "$f" 2>/dev/null)
    fm_wd_quota_status_line "$last" || continue
    at=$(printf '%s' "$last" | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p')
    [ -n "$at" ] || at=$(wd_mtime "$f")
    printf '%s\t%s\t%s\n' "$(basename "$f" .status)" "$((now - at))" "$(printf '%s' "$last" | cut -c1-300)"
  done
}

wd_read_composer() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WD_TEST_COMPOSER:-}" ]; then
    O_COMPOSER=$FM_WD_TEST_COMPOSER
  else
    O_COMPOSER=$(fm_run_timed_fn 20 fm_backend_composer_state "$O_BACKEND" "$O_TARGET" 2>/dev/null) || O_COMPOSER=unknown
  fi
  [ -n "$O_COMPOSER" ] || O_COMPOSER=unknown
  if [ "$O_COMPOSER" = empty ] && [ "$O_BACKEND" = orca ]; then
    local rc=0
    if fm_backend_source orca >/dev/null 2>&1; then
      fm_run_timed_fn 10 fm_backend_orca_draft_present "$O_TARGET" >/dev/null 2>&1 || rc=$?
    fi
    [ "$rc" = 1 ] || O_COMPOSER='pending-unproven'
  fi
  O_DRAFT=''
  O_COMPOSER_TEXT=$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = n - 7; i <= n; i++) if (i > 0) print r[i] }')
  O_COMPOSER_ABOVE=$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | awk 'NF { r[++n] = $0 } END { for (i = 1; i <= n - 8; i++) print r[i] }')
  if [ "$O_BACKEND" = orca ]; then
    O_DRAFT=$(fm_run_timed 10 orca terminal read --terminal "$O_TARGET" --limit 5 --json 2>/dev/null | jq -r '(.result.terminal.draft // .result.draft // "") | tostring' 2>/dev/null)
    O_COMPOSER_TEXT="$O_COMPOSER_TEXT $O_DRAFT"
  fi
}

# wd_read_owner <state-dir>: fills O_LOCK_PID, O_ALIVE, O_INSTANCE, O_SESSION,
# and O_OWNER (live, dead, unconfirmed, or none) for the recorded lock owner.
# A running pid whose recorded instance matches is live. Otherwise the shared
# lock contract (fm_session_lock_recorded_owner_live) decides, which also
# proves a Codex owner whose line-1 pid has exited; that proof sets O_ALIVE=1
# and leaves O_INSTANCE unmatched, so a restart refuses and no signal reaches
# a pid that is not the owner. A running pid the contract cannot prove is
# unconfirmed: the pid may now belong to another process.
wd_read_owner() {
  local st=$1
  O_LOCK_PID='' O_ALIVE=0 O_INSTANCE=unknown O_OWNER=none
  if [ -f "$st/.lock" ]; then
    O_LOCK_PID=$(head -n 1 "$st/.lock" 2>/dev/null | tr -cd '0-9')
    if wd_pid_alive "$O_LOCK_PID"; then O_ALIVE=1; fi
    if fm_session_lock_anchor_instance_matches "$st" 2>/dev/null; then O_INSTANCE=match; else O_INSTANCE=mismatch; fi
  fi
  O_SESSION=$(fm_session_lock_recorded_session_id "$st" 2>/dev/null) || O_SESSION=''
  [ -n "$O_LOCK_PID" ] || return 0
  if [ "$O_ALIVE" = 1 ] && [ "$O_INSTANCE" = match ]; then
    O_OWNER=live
  elif fm_session_lock_recorded_owner_live "$st" >/dev/null 2>&1; then
    O_OWNER=live
    [ "$O_ALIVE" = 1 ] || O_ALIVE=1 O_INSTANCE=mismatch
  elif [ "$O_ALIVE" = 1 ]; then
    O_OWNER=unconfirmed
  else
    O_OWNER=dead
  fi
}

# wd_same_live_owner <state-dir>: the lock still names the owner wd_read_owner
# observed (same pid and recorded session, and the same anchor instance when it
# matched), and that owner is still live.
wd_same_live_owner() {
  local st=$1 pid sess
  pid=$(head -n 1 "$st/.lock" 2>/dev/null | tr -cd '0-9')
  [ -n "$pid" ] && [ "$pid" = "$O_LOCK_PID" ] || return 1
  sess=$(fm_session_lock_recorded_session_id "$st" 2>/dev/null) || sess=''
  [ "$sess" = "$O_SESSION" ] || return 1
  if [ "$O_INSTANCE" = match ]; then fm_session_lock_anchor_instance_matches "$st" 2>/dev/null || return 1; fi
  wd_pid_alive "$pid" || fm_session_lock_recorded_owner_live "$st" >/dev/null 2>&1
}

# wd_lock_at <state-dir>: the newest mtime of the session lock files, else 0.
wd_lock_at() {
  local f t at=0
  for f in "$1/.lock" "$1/.lock-session"; do
    [ -f "$f" ] || continue
    t=$(wd_mtime "$f")
    [ "${t:-0}" -le "$at" ] || at=$t
  done
  printf '%s\n' "$at"
}

# wd_publish_captain <state-dir> <source> <backend> <target> <last> <last-owner> [move]:
# rewrites <state-dir>/watchdog/captain from the O_* owner and the proven
# terminal <backend>:<target>. <last> is the last proven terminal, which counts
# only when <last-owner> is the current owner. The owner is
# the recorded session, or the lock pid when no session is recorded. A new
# owner or the move argument stamps moved_at, and so does a proven terminal
# that differs from the last proven one. An unchanged owner whose terminal is
# not proven now keeps the recorded terminal only while the lock is unchanged;
# a terminal that only becomes known is not a move. docs/watchdog.md owns the
# record's meaning.
wd_publish_captain() {
  local st=$1 source=$2 backend=$3 target=$4 last=$5 last_owner=$6 move=${7:-} rec now owner prev='' moved='' lock_at rb rt tmp
  rec=$st/watchdog/captain
  now=$(wd_now)
  lock_at=$(wd_lock_at "$st")
  if [ -n "$O_SESSION" ]; then owner=session:$O_SESSION; elif [ -n "$O_LOCK_PID" ]; then owner=pid:$O_LOCK_PID; else owner=none; fi
  if [ -f "$rec" ]; then prev=$(fm_wd_conf_get "$rec" owner ''); fi
  [ "$last_owner" = "$owner" ] || last=''
  [ -n "$backend" ] && [ -n "$target" ] || backend='' target=''
  if [ -z "$move" ] && [ "$owner" = "$prev" ]; then
    moved=$(fm_wd_conf_get "$rec" moved_at '' | tr -cd '0-9')
    rb=$(fm_wd_conf_get "$rec" backend '') rt=$(fm_wd_conf_get "$rec" target '')
    if [ -n "$rb" ] && [ -n "$rt" ] && [ "$(fm_wd_conf_get "$rec" lock_at '')" = "$lock_at" ]; then
      last=$rb:$rt
      [ -n "$target" ] || backend=$rb target=$rt
    fi
    if [ -n "$target" ] && [ -n "$last" ] && [ "$backend:$target" != "$last" ]; then moved=$now; fi
  fi
  if [ -z "$moved" ] && [ -z "$move" ]; then
    # The lock files' own time dates a move the watchdog notices a pass late.
    moved=$lock_at
    [ "$moved" -gt 0 ] && [ "$moved" -le "$now" ] || moved=$now
  fi
  moved=${moved:-$now}
  C_BACKEND=$backend C_TARGET=$target C_MOVED=$moved C_OWNER=$owner
  mkdir -p "$st/watchdog" 2>/dev/null || return 0
  tmp=$(mktemp "$st/watchdog/.captain.XXXXXX" 2>/dev/null) || return 0
  if printf 'owner=%s\nlock_pid=%s\nsession=%s\nalive=%s\nusage_limit_autowait=%s\nbackend=%s\ntarget=%s\nmoved_at=%s\nlock_at=%s\nchecked_at=%s\nsource=%s\n' \
    "$owner" "$O_LOCK_PID" "$O_SESSION" "$O_OWNER" "${O_AUTOWAIT:-0}" "$backend" "$target" "$moved" "$lock_at" "$now" "$source" > "$tmp"; then
    mv "$tmp" "$rec" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# wd_lock_endpoint <state-dir> <home>
# Prints the concrete backend and terminal from state/.lock-session, one per
# line, when both name this home. unknown, empty, an illegal token, and a
# different worktree are not addresses.
wd_lock_endpoint() {
  local side=$1/.lock-session backend terminal worktree home_phys side_phys
  [ -f "$side" ] && [ ! -L "$side" ] || return 1
  backend=$(sed -n 's/^backend=//p' "$side")
  terminal=$(sed -n 's/^terminal=//p' "$side")
  worktree=$(sed -n 's/^worktree=//p' "$side")
  # The subject home is the physical path. The lock records the FM_HOME it was
  # given, which may be a symlink or a doubled slash for that same directory.
  home_phys=$(cd -P -- "$2" 2>/dev/null && pwd -P) || return 1
  side_phys=$(cd -P -- "$worktree" 2>/dev/null && pwd -P) || return 1
  [ "$side_phys" = "$home_phys" ] || return 1
  case "$backend" in ''|unknown|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$terminal" in ''|unknown|*[!A-Za-z0-9_.:%-]*) return 1 ;; esac
  printf '%s\n%s\n' "$backend" "$terminal"
}

# _wd_act_take <epoch> <source>: wd_activity's step; keeps the newest stamp that
# is not later than the clock in the caller's at and src.
_wd_act_take() {
  fm_wd_epoch_ok "$1" || return 0
  [ "$1" -le "$now" ] && [ "$1" -gt "$at" ] || return 0
  at=$1 src=$2
}

# wd_activity <now>: sets O_ACT_AGE and O_ACT_SRC from the newest activity
# source of the subject wd_observe is reading. docs/watchdog.md owns the sources.
wd_activity() {
  local now=$1 at=0 src='' ps
  [ -z "$O_TRANSCRIPT" ] || _wd_act_take "$(wd_mtime "$O_TRANSCRIPT")" transcript
  _wd_act_take "$(fm_wd_last_wake_ack "$O_HOME/state/wake-ledger.tsv" "$now" "$O_HOME/state/.supervise-daemon.acks")" wake-ack
  if [ "$O_PARENT" != - ]; then
    ps=$O_PARENT/state
    _wd_act_take "$(fm_busy_record_ts "$ps" "$O_ID" "$O_HARNESS" 2>/dev/null)" busy-state
    [ ! -f "$ps/$O_ID.turn-ended" ] || _wd_act_take "$(wd_mtime "$ps/$O_ID.turn-ended")" turn-ended
    _wd_act_take "$(wd_lock_at "$O_HOME/state")" session-lock
  fi
  [ -z "$src" ] || O_ACT_AGE=$((now - at)) O_ACT_SRC=$src
}

# wd_observe <home> <parent> <id>: fills the O_* globals for one subject and
# saves the comparable parts to state/watchdog/subjects/<home-basename>-<path-cksum>.
wd_observe() {
  local home=$1 parent=$2 id=$3 st now hb prev meta row hb_sid hb_wpid='' hb_wsid='' ctx dt hb_at=0 cb='' ct=''
  local lock_ep='' lock_backend='' lock_target=''
  local footer_text='' footer_src='' reading
  st=$home/state
  now=$(wd_now)
  O_HOME=$home O_PARENT=$parent O_ID=$id O_TAG=$(wd_tag "$home") O_KEY=$(wd_state_key "$home")
  O_BACKEND='' O_TARGET='' O_HARNESS='' O_SESSION='' O_HB_AGE=unknown O_CTX='' O_CTX_SRC='' O_CTX_READING='' O_CTX_RESET=''
  O_PANE='' O_HERDR_MISMATCH='' O_DIALOG_PANE='' O_SIG='' O_PANE_STATIC=0 O_DIALOG='' O_AUTOWAIT=0 O_LIMIT_FOOTER=0 O_COMPOSER=unknown O_TURN=unknown
  O_LOCK_PID='' O_ALIVE=0 O_INSTANCE=unknown O_OWNER=none O_CPU_BUSY=unknown O_TRANSCRIPT='' O_TR_AGE=unknown O_ACT_AGE=unknown O_ACT_SRC=''
  C_BACKEND='' C_TARGET='' C_MOVED=''
  O_LOOP=none O_LOOP_N=0 O_EVENTS='' O_RESTART_REQ=0 O_OWED_N=0 O_OWED_AGE=0
  O_AFK=0 O_DAEMON=unknown O_PREV_COMPOSER='' O_PREV_SIG='' O_COMPOSER_TEXT='' O_COMPOSER_ABOVE='' O_DRAFT=''
  hb=$st/heartbeat.json
  hb_sid='' ctx=''
  if [ -f "$hb" ] && row=$(jq -r 'def known: if type == "object" then "-" else . end;
        [(.primary.terminal.backend // "-" | known), (.primary.terminal.target // "-" | known),
        (.primary.session.trusted_id // "-" | known), (.generated_epoch // 0 | tostring),
        (.primary.context_left.remaining.percent // "-" | tostring),
        (.primary.writer.anchor_pid // "-" | known | tostring), (.primary.writer.session_id // "-" | known)] | @tsv' "$hb" 2>/dev/null); then
    IFS=$'\t' read -r O_BACKEND O_TARGET hb_sid row ctx hb_wpid hb_wsid <<EOF
$row
EOF
    [ "$O_BACKEND" != - ] || O_BACKEND=''
    [ "$O_TARGET" != - ] || O_TARGET=''
    [ "$O_BACKEND" != unknown ] || O_BACKEND=''
    [ "$O_TARGET" != unknown ] || O_TARGET=''
    [ "$hb_sid" != - ] || hb_sid=''
    [ "$hb_wpid" != - ] || hb_wpid=''
    [ "$hb_wsid" != - ] || hb_wsid=''
    [ "$row" -gt 0 ] 2>/dev/null || row=$(wd_mtime "$hb")
    O_HB_AGE=$((now - row)) hb_at=$row
  fi
  wd_read_owner "$st"
  if [ -n "$O_SESSION" ] && [ "$ctx" != - ] && [ -n "$ctx" ] && [ "$hb_sid" = "$O_SESSION" ] && [ "$O_HB_AGE" != unknown ] && [ "$O_HB_AGE" -lt "$(cfgi watcher-stale-secs 900)" ]; then
    # The heartbeat's percent is the same footer, read by the same parser.
    footer_text="${ctx%%.*}% until auto-compact" footer_src=heartbeat
  fi
  # A second mate whose own heartbeat names another session, or none, uses the
  # parent's recorded endpoint for it.
  meta=''
  [ "$parent" = - ] || meta=$parent/state/$id.meta
  if [ -n "$meta" ] && [ -f "$meta" ]; then
    O_HARNESS=$(fm_meta_get "$meta" harness 2>/dev/null) || O_HARNESS=''
  fi
  if [ -z "$O_HARNESS" ] && [ -n "${FM_SESSION_LOCK_OWNER_HARNESS:-}" ]; then
    O_HARNESS=$FM_SESSION_LOCK_OWNER_HARNESS
  fi
  if [ -z "$O_HARNESS" ] && [ -n "$O_LOCK_PID" ] && declare -F fm_ps_comm >/dev/null 2>&1 && declare -F fm_harness_path_name >/dev/null 2>&1; then
    O_HARNESS=$(fm_harness_path_name "$(fm_ps_comm "$O_LOCK_PID" 2>/dev/null)" 2>/dev/null) || O_HARNESS=''
  fi
  if [ -n "$meta" ] && [ -f "$meta" ] && { [ -z "$O_TARGET" ] || [ -z "$O_SESSION" ] || [ "$hb_sid" != "$O_SESSION" ]; }; then
    O_BACKEND=$(fm_backend_of_meta "$meta" 2>/dev/null)
    O_TARGET=$(fm_backend_target_of_meta "$meta" 2>/dev/null)
    cb=$O_BACKEND ct=$O_TARGET
  elif [ -z "$O_SESSION" ] || [ "$hb_sid" != "$O_SESSION" ]; then
    O_BACKEND='' O_TARGET=''
  elif [ "$hb_at" -ge "$(wd_lock_at "$st")" ] \
    && { { [ -n "$hb_wpid" ] && [ "$hb_wpid" = "$O_LOCK_PID" ]; } || { [ -n "$hb_wsid" ] && [ "$hb_wsid" = "$O_SESSION" ]; }; }; then
    # Only a heartbeat written inside the lock owner names the owner's terminal.
    cb=$O_BACKEND ct=$O_TARGET
  fi
  # A primary heartbeat that does not prove a terminal must not keep that pane
  # for capture. The endpoint recorded when this session took the lock is the
  # address. A second mate stays on the parent meta path above.
  if [ "$parent" = - ] && { [ -z "$cb" ] || [ -z "$ct" ]; }; then
    O_BACKEND=''
    O_TARGET=''
    cb=''
    ct=''
    lock_ep=$(wd_lock_endpoint "$st" "$home" 2>/dev/null) || lock_ep=''
    if [ -n "$lock_ep" ]; then
      lock_backend=${lock_ep%%$'\n'*}
      lock_target=${lock_ep#*$'\n'}
      lock_target=${lock_target%%$'\n'*}
      if [ -n "$lock_backend" ] && [ -n "$lock_target" ]; then
        O_BACKEND=$lock_backend
        O_TARGET=$lock_target
        cb=$lock_backend
        ct=$lock_target
      fi
    fi
  fi
  prev=$WD/subjects/$O_KEY
  local p_sig='' p_since='' p_cpu='' p_at='' p_comp='' p_term='' p_term_owner=''
  if [ -f "$prev" ]; then
    p_sig=$(fm_wd_conf_get "$prev" sig '') p_since=$(fm_wd_conf_get "$prev" since '')
    p_cpu=$(fm_wd_conf_get "$prev" cpu '') p_at=$(fm_wd_conf_get "$prev" cpu_at '')
    p_comp=$(fm_wd_conf_get "$prev" composer '')
    p_term=$(fm_wd_conf_get "$prev" term '') p_term_owner=$(fm_wd_conf_get "$prev" term_owner '')
  fi
  O_PREV_COMPOSER=$p_comp O_PREV_SIG=$p_sig
  local cpu=''
  if [ "$O_ALIVE" = 1 ]; then
    cpu=$(wd_cpu_seconds "$O_LOCK_PID")
    if [ -n "$cpu" ] && [ -n "$p_cpu" ] && [ -n "$p_at" ] && [ "$now" -gt "$p_at" ]; then
      dt=$((now - p_at))
      O_CPU_BUSY=$(awk -v c="$cpu" -v p="$p_cpu" -v dt="$dt" -v pct="$(cfgi cpu-busy-pct 15)" 'BEGIN { print ((c - p) * 100 >= pct * dt) ? 1 : 0 }')
    fi
  fi
  if [ -n "$O_BACKEND" ] && [ -n "$O_TARGET" ]; then
    O_PANE=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) || O_PANE=''
    if [ -z "$O_PANE" ] && [ "$O_BACKEND" = herdr ]; then
      O_HERDR_MISMATCH=$(fm_run_timed_fn "$(cfgi call-timeout-secs 20)" wd_herdr_mismatch "$O_TARGET" 2>/dev/null) || O_HERDR_MISMATCH=''
    fi
  fi
  if [ -n "$O_PANE" ]; then
    local view
    O_SIG=$(wd_pane_sig "$O_PANE")
    if [ "$O_SIG" = "$p_sig" ] && [ -n "$p_since" ]; then O_PANE_STATIC=$((now - p_since)); else p_since=$now; fi
    O_DIALOG=$(wd_observe_dialog "$O_BACKEND" "$O_TARGET" "" "$O_HARNESS") || O_DIALOG=''
    view=$(wd_view "$O_BACKEND" "$O_TARGET") || view=$O_PANE
    O_DIALOG_PANE=$view
    if fm_wd_usage_limit_autowait "$view"; then
      if [ "$parent" = - ]; then O_AUTOWAIT=1; else O_LIMIT_FOOTER=1; fi
    fi
    wd_read_composer
    O_TURN=$(wd_turn_running "$O_BACKEND" "$O_TARGET" "$O_PANE")
    [ -n "$footer_text" ] || { footer_text=$(_fm_wd_tail_rows "$O_PANE" 10); footer_src=pane; }
  fi
  if O_TRANSCRIPT=$(wd_transcript "$home" "$O_SESSION"); then
    O_TR_AGE=$((now - $(wd_mtime "$O_TRANSCRIPT")))
    O_EVENTS=$(fm_wd_transcript_events "$O_TRANSCRIPT" 400)
    IFS=$'\t' read -r O_LOOP O_LOOP_N <<EOF
$(printf '%s\n' "$O_EVENTS" | fm_wd_loop_verdict "$(cfgi rapid-loop-secs 180)")
EOF
  else
    O_TRANSCRIPT=''
  fi
  wd_activity "$now"
  # One shared context reading (bin/fm-context-reading-lib.sh): the derived
  # percentage owns the restart decision when it exists, else the footer; the
  # full-window status percentage is never read.
  reading=$(fm_context_reading "$home" "$O_SESSION" "$O_TRANSCRIPT" <(printf '%s\n' "$footer_text"))
  O_CTX_READING=$reading
  case "$reading" in
    *' owner=derived '*) O_CTX=$(printf '%s\n' "$reading" | sed -n 's/.* derived=\([0-9]*\) .*/\1/p'); O_CTX_SRC=derived ;;
    *' owner=footer '*) O_CTX=$(printf '%s\n' "$reading" | sed -n 's/^footer=\([0-9]*\) .*/\1/p'); O_CTX_SRC=$footer_src ;;
  esac
  # How this cycle ends, as the session's trigger published it: compaction
  # means low context is the routine run-up to auto-compaction.
  O_CTX_RESET=$(fm_context_reset_for_session "$home" "$O_SESSION")
  if [ -f "$st/.watchdog-restart-request" ]; then
    local req_at last_r
    req_at=$(wd_mtime "$st/.watchdog-restart-request")
    last_r=$(fm_wd_last_epoch "$LEDGER" "$home" '*' restart '^(pending|dry-run)$')
    [ "$req_at" -gt "${last_r:-0}" ] && O_RESTART_REQ=1
  fi
  # Owed input: wake rows not yet drained, and captain inbox notes not yet handled.
  local wake_n=0 wake_old='' note_n=0 note_old='' f m
  if [ -s "$st/.wake-queue" ]; then
    wake_n=$(awk 'NF' "$st/.wake-queue" | wc -l | tr -d ' ')
    wake_old=$(awk -F'\t' 'NF && $1 ~ /^[0-9]+$/ { if (m == "" || $1 < m) m = $1 } END { print m }' "$st/.wake-queue")
  fi
  for f in "$st"/inbox/*.note; do
    [ -f "$f" ] || continue
    note_n=$((note_n + 1))
    m=$(wd_mtime "$f")
    if [ -z "$note_old" ] || [ "$m" -lt "$note_old" ]; then note_old=$m; fi
  done
  O_OWED_N=$((wake_n + note_n))
  m=${wake_old:-$now}
  if [ -n "$note_old" ] && [ "$note_old" -lt "$m" ]; then m=$note_old; fi
  O_OWED_AGE=$((now - m))
  [ "$O_OWED_AGE" -ge 0 ] || O_OWED_AGE=0
  if [ -f "$st/.afk" ]; then
    O_AFK=1
    m=$(head -n 1 "$st/.supervise-daemon.pid" 2>/dev/null | tr -cd '0-9')
    if [ -n "$m" ] && kill -0 "$m" 2>/dev/null; then O_DAEMON=1; else O_DAEMON=0; fi
  fi
  wd_publish_captain "$st" watchdog "$cb" "$ct" "$p_term" "$p_term_owner"
  [ -z "$C_TARGET" ] || p_term=$C_BACKEND:$C_TARGET p_term_owner=$C_OWNER
  mkdir -p "$WD/subjects"
  printf 'sig=%s\nsince=%s\ncpu=%s\ncpu_at=%s\ncomposer=%s\nterm=%s\nterm_owner=%s\n' "$O_SIG" "${p_since:-$now}" "$cpu" "$now" "$O_COMPOSER" "$p_term" "$p_term_owner" > "$prev.tmp" && mv "$prev.tmp" "$prev"
}

wd_print_observation() {
  printf '%s\n' "subject $O_TAG ($O_HOME)" \
    "  endpoint=${O_BACKEND:-none}:${O_TARGET:-none} session=${O_SESSION:-none} lock_pid=${O_LOCK_PID:-none} alive=$O_ALIVE instance=$O_INSTANCE owner=$O_OWNER" \
    "  captain=${C_BACKEND:-none}:${C_TARGET:-none} moved_at=${C_MOVED:-none}" \
    "  pane_static=${O_PANE_STATIC}s dialog=${O_DIALOG:-none} usage_limit_autowait=$O_AUTOWAIT composer=$O_COMPOSER turn_running=$O_TURN cpu_busy=$O_CPU_BUSY" \
    "  activity_age=${O_ACT_AGE}s${O_ACT_SRC:+ ($O_ACT_SRC)} loop=$O_LOOP/$O_LOOP_N restart_requested=$O_RESTART_REQ ctx=${O_CTX:-unknown}${O_CTX_SRC:+ ($O_CTX_SRC)}${O_CTX_READING:+ [$O_CTX_READING]}${O_CTX_RESET:+ reset=$O_CTX_RESET}" \
    "  owed=$O_OWED_N oldest=${O_OWED_AGE}s afk=$O_AFK daemon=$O_DAEMON heartbeat_age=${O_HB_AGE}s"
  [ -z "$O_HERDR_MISMATCH" ] || printf '  %s\n' "$O_HERDR_MISMATCH"
}

# --- actions -------------------------------------------------------------------

# wd_action_gate <symptom> <action> <rate-secs>: 0 when the action may run now.
wd_rate_open() {  # <symptom> <action> <rate-secs> [subject]
  fm_wd_rate_ok "$LEDGER" "$O_HOME" "$1" "$2" "$3" "$(wd_now)" "${4-}"
}

wd_rec() {  # <id> <symptom> <action> <phase> <detail>
  # O_REC_SUBJECT selects one worker's ledger rows. Unset, the row stays the home's.
  FM_WD_NOW=$(wd_now) fm_wd_record "$LEDGER" "$1" "$O_HOME" "${O_REC_SUBJECT:-$O_TAG}" "$2" "$3" "$4" "$5"
}

# wd_nudge <symptom> <body>: a record-backed doorbell into the subject's own pane.
wd_nudge() {
  local symptom=$1 body="Watchdog (automated, not the captain or the owner): $2" id doorbell verdict heartbeat_owner=''
  if [ "$symptom" = heartbeat-frozen ]; then
    heartbeat_owner=$(wd_heartbeat_owner) || { wd_gap "heartbeat nudge held; current owner is unproven"; return 0; }
  fi
  if ! fm_wd_text_allowed "$body"; then
    wd_gap "$symptom held; its nudge names a merge, deploy, or release word"
    wd_rate_open "$symptom" nudge "$(cfgi nudge-secs 900)" && wd_rec "$(wd_id)" "$symptom" nudge refused "text names a merge, deploy, or release word"
    return 0
  fi
  if [ "$(wd_nudge_mode)" = act ] && [ "$O_COMPOSER" != empty ]; then wd_gap "$symptom held; composer is $O_COMPOSER, so nothing is typed"; fi
  wd_rate_open "$symptom" nudge "$(cfgi nudge-secs 900)" || return 0
  id=$(wd_id)
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" nudge refused "endpoint is on do-not-touch"; return 0; fi
  if [ -z "$O_TARGET" ]; then wd_rec "$id" "$symptom" nudge refused "no recorded endpoint"; return 0; fi
  if [ "$(wd_nudge_mode)" != act ]; then wd_rec "$id" "$symptom" nudge dry-run "$body"; return 0; fi
  if [ -n "$O_DIALOG" ] || [ "$O_COMPOSER" != empty ]; then
    wd_rec "$id" "$symptom" nudge held "composer is $O_COMPOSER${O_DIALOG:+, dialog $O_DIALOG}; nothing typed"
    return 0
  fi
  wd_rec "$id" "$symptom" nudge pending "$body"
  doorbell=$(printf '%s\n' "$body" | FM_HOME=$O_HOME "$SCRIPT_DIR/fm-operational-input.sh" record watcher 2>/dev/null) || {
    wd_rec "$id" "$symptom" nudge failed "operational input record failed"; return 0; }
  verdict=$(fm_run_timed_fn 30 fm_backend_send_text_submit "$O_BACKEND" "$O_TARGET" "$doorbell" 2 0.5 1 2>/dev/null) || {
    wd_rec "$id" "$symptom" nudge failed "doorbell submit failed (${verdict:-no verdict})"; return 0; }
  if [ "$symptom" = heartbeat-frozen ] && wd_same_live_owner "$O_HOME/state" \
    && [ "$(wd_heartbeat_owner)" = "$heartbeat_owner" ]; then
    wd_rec "$id" "$symptom" nudge "done" "$heartbeat_owner" || wd_gap "heartbeat delivery receipt could not be written"
  fi
  return 0
}

# wd_key <symptom> <key-or-digit> <why>: one key, then verify its effect; returns 0
# only when the key changed the pane. A dialog that left refreshes the observation.
wd_key() {
  local symptom=$1 key=$2 why=$3 id after
  wd_rate_open "$symptom" key "$(cfgi key-secs 120)" "${O_REC_SUBJECT:-$O_TAG}" || return 1
  id=$(wd_id)
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" key refused "endpoint is on do-not-touch"; return 1; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" key dry-run "would press $key: $why"; return 1; fi
  wd_rec "$id" "$symptom" key pending "press $key: $why"
  case "$O_BACKEND:$key" in
    orca:[0-9]) fm_orca_cli_mutation fm_run_timed 10 orca terminal send --terminal "$O_TARGET" --text "$key" --json >/dev/null 2>&1 ;;
    tmux:[0-9]) fm_run_timed 10 tmux send-keys -t "$O_TARGET" -l "$key" >/dev/null 2>&1 ;;
    *) fm_run_timed_fn 10 fm_backend_send_key "$O_BACKEND" "$O_TARGET" "$key" >/dev/null 2>&1 ;;
  esac || { wd_rec "$id" "$symptom" key failed "key delivery failed"; return 1; }
  sleep "$(cfgi key-settle-secs 2)"
  if [ "$symptom" = dialog ] && wd_visible_capture_expected "$O_BACKEND" "$O_TARGET"; then
    after=$(wd_view "$O_BACKEND" "$O_TARGET")
  else
    after=$(wd_capture "$O_BACKEND" "$O_TARGET" 60)
  fi
  case "$symptom" in
    dialog) if [ -n "$after" ] && ! fm_wd_pane_dialog "$after" >/dev/null; then wd_rec "$id" "$symptom" key "done" "dialog left the pane"; O_DIALOG='' O_PANE=$after; wd_read_composer; else wd_rec "$id" "$symptom" key failed "dialog still showing"; return 1; fi ;;
    *) if [ -n "$after" ] && [ "$(wd_pane_sig "$after")" != "$O_SIG" ]; then wd_rec "$id" "$symptom" key "done" "pane changed"; else wd_rec "$id" "$symptom" key failed "pane unchanged"; return 1; fi ;;
  esac
}

wd_gap() {  # <text>
  printf '%s\n' "- $O_TAG: $1" >> "$WD_GAPS"
}

# wd_score_gap: appends the supervisor-gap rows of the subject wd_observe just
# read (docs/watchdog.md "Supervisor-gap record"). A heartbeat that is not read
# writes nothing, and a clock that does not have exactly 10 digits writes
# nothing. Each append starts with a line of three TABs, which is not a row: it
# closes whatever a cut append left, with no check of the last byte, so no other
# pass can put bytes between a check and the rows. A child process writes the
# record, so a failed write leaves no row bytes in this shell's output buffer
# for the next builtin write to send to another file. The two report lines are
# builtin writes, like every other report of the pass.
wd_score_gap() {
  local f=$STATE/night-score/supervisor-gap.tsv pub now rows
  pub=$(fm_wd_heartbeat_published "$O_HOME/state/heartbeat.json") || return 0
  now=$(wd_now)
  rows=$(fm_wd_supervisor_gap_rows "$O_HOME" "$now" "$pub") || return 0
  if ! { mkdir -p "${f%/*}" && cat >> "$f" <<< $'\t\t\t\n'"$rows"; } 2>/dev/null; then
    wd_gap "supervisor-gap record append failed"
    printf 'fm-watchdog: supervisor-gap record append failed for %s: %s\n' "$O_TAG" "$f" >&2
  fi
}

# wd_score_activity: appends the supervisor-activity row of the subject
# wd_observe just read (docs/watchdog.md "Supervisor-activity record"). A child
# process writes the row, as in wd_score_gap.
wd_score_activity() {
  local f=$STATE/night-score/supervisor-activity.tsv now src=none age=-
  now=$(wd_now)
  fm_wd_epoch_ok "$now" && [ "${#now}" -eq 10 ] || return 0
  case "$O_HOME" in ''|*$'\t'*|*$'\n'*|*$'\r'*) return 0 ;; esac
  [ "$O_ACT_AGE" = unknown ] || src=$O_ACT_SRC age=$O_ACT_AGE
  if ! { mkdir -p "${f%/*}" && cat >> "$f" <<< "$now"$'\t'"$O_HOME"$'\t'"$src"$'\t'"$age"; } 2>/dev/null; then
    wd_gap "supervisor-activity record append failed"
  fi
}

# --- cheap model judge ---------------------------------------------------------

# A council sets WD_CALL_MAX_USD and WD_CALL_TIMEOUT for its seats; every other
# call keeps the judge's own budget and time limit.
wd_judge_one() {  # <model> <purpose> <answer-ere> <prompt>  -> prints the answer
  local model=$1 purpose=$2 re=$3 prompt=$4 h m out ans cost='' tin='' tout='' rc=0 spent cap scratch acct pin secs usd prompt_file
  secs=${WD_CALL_TIMEOUT:-$(cfgi judge-timeout-secs 120)}
  usd=${WD_CALL_MAX_USD:-$(cfg judge-call-max-usd 0.05)}
  h=${model%%:*} m=${model#*:}
  # The daily cap gates only models that spend money; an unmetered host (agy,
  # whose calls log cost=unmetered) still answers once the cap is spent, so a
  # daily-max-usd of 0 runs only unmetered models.
  case "$h" in
    agy) ;;
    *)
      spent=$(fm_wd_spent_since "$CALLS" "$(( $(wd_now) - 86400 ))")
      cap=$(cfg daily-max-usd 1.00)
      if awk -v s="$spent" -v c="$cap" 'BEGIN { exit !(s >= c) }'; then
        printf '%s\t%s\t%s\tcap-reached\t\t\t\t\n' "$(wd_now)" "$purpose" "$model" >> "$CALLS"
        return 3
      fi ;;
  esac
  scratch=$WD/judge-scratch
  mkdir -p "$scratch"
  if [ "$purpose" = council ]; then
    [ "${#prompt}" -le "$(cfgi judge-max-chars 6000)" ] || return 1
  else
    prompt=$(printf '%s' "$prompt" | cut -c1-"$(cfgi judge-max-chars 6000)")
  fi
  case "$h" in
    claude)
      command -v claude >/dev/null 2>&1 || return 4
      acct=$(cfg claude-config-dir '')
      if [ -z "$acct" ]; then
        if ! pin=$(fm_worker_account_resolve claude "$OWNER_HOME/config" config/claude-account 2>/dev/null); then
          printf '%s\t%s\t%s\tfailed account\t\t\t\t\n' "$(wd_now)" "$purpose" "$model" >> "$CALLS"
          return 4
        fi
        acct=${pin%%$'\t'*}
      fi
      # The timed runner detaches stdin, so the prompt reaches claude through a
      # redirect inside the timed command rather than a pipe into the runner.
      prompt_file=$(mktemp "$scratch/prompt.XXXXXX") || return 1
      printf '%s' "$prompt" > "$prompt_file" || { rm -f "$prompt_file"; return 1; }
      # shellcheck disable=SC2016  # Expanded by the timed child shell.
      # With no account set, the CLI's own default stays in force: naming the default
      # directory explicitly makes the real CLI report that it is not logged in.
      # An ordinary account means the variable is unset.
      out=$( (cd "$scratch" && { if [ "$acct" = ordinary ]; then unset CLAUDE_CONFIG_DIR; elif [ -n "$acct" ]; then export CLAUDE_CONFIG_DIR="$acct"; fi; } && \
        fm_run_timed "$secs" bash -c 'f=$1; shift; exec "$@" < "$f"' _ "$prompt_file" \
        claude -p --model "$m" --output-format json --tools "" \
        --setting-sources "" --strict-mcp-config --no-session-persistence --max-budget-usd "$usd") 2>/dev/null) || rc=$?
      rm -f "$prompt_file"
      ans=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)
      cost=$(printf '%s' "$out" | jq -r '.total_cost_usd // empty' 2>/dev/null)
      tin=$(printf '%s' "$out" | jq -r '.usage.input_tokens // empty' 2>/dev/null)
      tout=$(printf '%s' "$out" | jq -r '.usage.output_tokens // empty' 2>/dev/null) ;;
    agy)
      command -v agy >/dev/null 2>&1 || return 4
      out=$( (cd "$scratch" && fm_run_timed "$secs" agy -p "$prompt" --model "$m" --output-format json \
        --disable-slash-commands --print-timeout "${secs}s") 2>/dev/null) || rc=$?
      ans=$(printf '%s' "$out" | jq -r '.response // empty' 2>/dev/null)
      tin=$(printf '%s' "$out" | jq -r '.usage.input_tokens // empty' 2>/dev/null)
      tout=$(printf '%s' "$out" | jq -r '.usage.output_tokens // empty' 2>/dev/null)
      cost=unmetered ;;
    *) return 4 ;;
  esac
  ans=$(printf '%s\n' "$ans" | sed -e 's/^[[:blank:]`*]*//' -e 's/[[:blank:]`*.]*$//' | LC_ALL=C grep -Ex "$re" | head -n 1)
  if [ "$rc" -eq 0 ] && [ -n "$ans" ]; then
    printf '%s\t%s\t%s\tok\t%s\t%s\t%s\t%s\n' "$(wd_now)" "$purpose" "$model" "$tin" "$tout" "$(printf '%s' "$ans" | tr '\t' ' ')" "$cost" >> "$CALLS"
    printf '%s\n' "$ans"
    return 0
  fi
  printf '%s\t%s\t%s\tfailed rc=%s\t%s\t%s\t\t%s\n' "$(wd_now)" "$purpose" "$model" "$rc" "$tin" "$tout" "$cost" >> "$CALLS"
  return 1
}

wd_models() { cfg models "claude:haiku,agy:gemini-3.8-flash-low" | tr ',' '\n' | sed '/^$/d'; }

# wd_judge <purpose> <answer-ere> <prompt>: the first model in order that answers.
# A model stopped by the daily cap does not end the attempt, because a later
# model may be unmetered and still answer; the last failure is the return code.
wd_judge() {
  local model rc=1
  mkdir -p "$WD"
  for model in $(wd_models); do
    wd_judge_one "$model" "$1" "$2" "$3" && return 0
    rc=$?
  done
  return "$rc"
}

# --- council -------------------------------------------------------------------

# 0 when a decision is the owner's: never nudged, put to council, or answered.
wd_decision_reserved() {  # <task> <key> <summary>
  # A permission-prompt hard stop is a credential, sign-in, spend, or
  # destructive prompt, so it is the owner's whatever its summary says.
  case "$2" in captain-hold-*|permission-prompt-hardstop) return 0 ;; esac
  fm_wd_reserved "$1 $2 $3" || fm_secret_like "$1 $2 $3" ||
    printf ',%s,' "$(cfg reserved-keys '')" | grep -Fq ",$2,"
}

wd_council_key() {  # <task> <key>: portable locator; record metadata authenticates identity.
  local digest
  digest=$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
    printf '%s\0%s\0%s' "$O_HOME" "$1" "$2" | git -C "$SCRIPT_DIR" hash-object --stdin) || return 1
  printf 'council-%s\n' "$digest"
}

# wd_council_record <task> <key>: the final council record of one decision, as
# `ruled|no-ruling TAB answer TAB path TAB seats`; nothing when it has none.
wd_council_record() {
  local name f kind header answer locator
  locator=$(wd_council_key "$1" "$2") || return 1
  for name in "$locator.md" "$O_KEY-$1:$2.md" "$O_KEY-$1-$2.md"; do
    for f in "$OUT/rulings/$name" "$OUT/no-rulings/$name"; do
      [ -f "$f" ] || continue
      case "$f" in "$OUT/rulings/"*) kind=ruled ;; *) kind=no-ruling ;; esac
      header=$(sed '/^Record:$/,$d' "$f")
      FM_WD_RECORD_HOME="$O_HOME" FM_WD_RECORD_TASK="$1" FM_WD_RECORD_KEY="$2" FM_WD_RECORD_KIND="$kind" awk '
        /^[[:space:]]*$/ { if (meta) ended=1; next }
        ended { bad=1 }
        /^# Watchdog council ruling$/ {
          title++; if (meta || ENVIRON["FM_WD_RECORD_KIND"] != "ruled") bad=1; next
        }
        /^# Watchdog council record - no ruling$/ {
          title++; if (meta || ENVIRON["FM_WD_RECORD_KIND"] != "no-ruling") bad=1; next
        }
        /^- / { meta=1 }
        /^- home: / { h++; if (substr($0,9) != ENVIRON["FM_WD_RECORD_HOME"]) bad=1; next }
        /^- task: / { t++; if (substr($0,9) != ENVIRON["FM_WD_RECORD_TASK"]) bad=1; next }
        /^- key: / { k++; if (substr($0,8) != ENVIRON["FM_WD_RECORD_KEY"]) bad=1; next }
        /^- ruling: / { r++; ruling=substr($0,11); next }
        /^- seats: / { s++; seats=substr($0,10); next }
        /^- seat models: .+$/ { model_fields++; next }
        /^- at: .+$/ { at_fields++; next }
        { bad=1 }
        END {
          if (bad || h != 1 || t != 1 || k != 1 || r != 1 || s != 1 || title > 1 || model_fields > 1 || at_fields > 1) exit 1
          kind=ENVIRON["FM_WD_RECORD_KIND"]
          if (kind == "ruled") {
            if (ruling !~ /^PROCEED [A-Za-z0-9]{1,3} \(unanimous, [0-9]+ blind seats\)$/) exit 1
            answer=ruling; sub(/ \(.*/, "", answer)
          } else if (ruling !~ /^none \(not unanimous, [0-9]+ blind seats; held for the owner\)$/) exit 1
          count=ruling; sub(/^.*unanimous, /, "", count); sub(/ blind seats.*$/, "", count); count+=0
          n=split(seats, votes, / seat/)
          if (count < 2 || n != count) exit 1
          agreed=1; answered=0
          for (i=1; i<=n; i++) {
            prefix=(i == 1 ? "seat" i "=" : i "=")
            if (index(votes[i], prefix) != 1) exit 1
            vote=substr(votes[i],length(prefix)+1)
            if (vote !~ /^(PROCEED [A-Za-z0-9]{1,3}|HOLD|FAILED)$/) exit 1
            if (vote != "FAILED") answered++
            if (i == 1) first=vote; else if (vote != first) agreed=0
            if (kind == "ruled" && vote != answer) exit 1
          }
          if (kind == "no-ruling" && (!answered || (agreed && first ~ /^PROCEED /))) exit 1
        }
      ' <<< "$header" || continue
      answer=$(sed -n 's/^- ruling: \(PROCEED [A-Za-z0-9]*\) (.*/\1/p' <<< "$header")
      case "$kind:$answer" in ruled:|no-ruling:?*) continue ;; esac
      printf '%s\t%s\t%s\t%s\n' "$kind" "$answer" "$f" "$(sed -n 's/^- seats://p' <<< "$header")"
      return 0
    done
  done
}

# wd_council <task> <key> <summary>: blind seats; prints
# `outcome TAB answer TAB record TAB seats`.
#   unanimous  every seat gave the same PROCEED; a ruling file is written.
#   no-ruling  a seat answered and the seats did not all agree; a record is written.
#   failed     no seat answered or publication failed; a later convening may run.
#   refused    the seats span fewer than two model families; no seat is called.
#   busy       another convening of this decision is running.
# A ruling or no-ruling record is final for its task and key: the caller checks
# wd_council_record first, and this function never overwrites one.
wd_council() {
  local task=$1 key=$2 summary=$3 seats seat i=0 tmp answers='' first='' unanimous=1 answered=0 record prompt a fams lock dir locator
  local WD_CALL_MAX_USD WD_CALL_TIMEOUT
  if [ "${#summary}" -gt "$WD_COUNCIL_MAX_CHARS" ]; then
    printf 'refused\t\t\trecord exceeds %s characters\n' "$WD_COUNCIL_MAX_CHARS"
    return 0
  fi
  seats=$(cfg council-seats "$(wd_models | tr '\n' ',')")
  fams=$(for seat in $(printf '%s' "$seats" | tr ',' ' '); do fm_wd_seat_family "$seat"; done | grep -v '^unknown$' | sort -u | wc -l | tr -d ' ')
  if [ "$fams" -lt 2 ]; then printf 'refused\t\t\tcouncil seats span fewer than two model families\n'; return 0; fi
  WD_CALL_MAX_USD=$(cfg council-call-max-usd "$(cfg judge-call-max-usd 0.05)")
  WD_CALL_TIMEOUT=$(cfgi council-timeout-secs "$(cfgi judge-timeout-secs 120)")
  # Shared owner-identity locking serializes stale reclamation without expiring live owners.
  locator=$(wd_council_key "$task" "$key") || return 1
  lock=$WD/council-locks/$locator
  mkdir -p "$WD/council-locks"
  if ! fm_lock_try_acquire "$lock"; then printf 'busy\t\t\t\n'; return 0; fi
  if [ -n "$(wd_council_record "$task" "$key")" ]; then fm_lock_release "$lock"; printf 'busy\t\t\t\n'; return 0; fi
  tmp=$(mktemp -d "$WD/council.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  prompt="You are one blind seat on a council for an autonomous software team. The owner is away. A worker parked this decision:
task: $task
key: $key
record: $summary
If the record names a merge, release, deploy, money, credentials, security, production data, or deletion, or says the owner reserved it, answer HOLD.
If the record offers options and one is clearly recommended or clearly safest for continuing work, answer PROCEED followed by that option's label (for example PROCEED A or PROCEED 2).
Otherwise answer HOLD.
Reply with exactly one line: PROCEED <label> or HOLD."
  for seat in $(printf '%s' "$seats" | tr ',' ' '); do
    i=$((i + 1))
    ( wd_judge_one "$seat" council '(PROCEED [A-Za-z0-9]{1,3}|HOLD)' "$prompt" > "$tmp/$i" 2>/dev/null || printf 'FAILED\n' > "$tmp/$i" ) &
  done
  wait
  [ "$i" -ge 2 ] || unanimous=0
  for seat in $(seq 1 "$i"); do
    a=$(head -n 1 "$tmp/$seat" 2>/dev/null)
    a=${a:-FAILED}
    answers="$answers seat$seat=$a"
    case "$a" in
      PROCEED*) answered=$((answered + 1)) ;;
      HOLD) answered=$((answered + 1)); unanimous=0 ;;
      *) unanimous=0 ;;
    esac
    if [ -z "$first" ]; then first=$a; elif [ "$a" != "$first" ]; then unanimous=0; fi
  done
  rm -rf "$tmp"
  if [ "$answered" -eq 0 ]; then fm_lock_release "$lock"; printf 'failed\t\t\t%s\n' "$answers"; return 0; fi
  if [ "$unanimous" = 1 ]; then dir=$OUT/rulings; else dir=$OUT/no-rulings; fi
  mkdir -p "$dir"
  record=$dir/$locator.md
  if {
    if [ "$unanimous" = 1 ]; then
      printf '# Watchdog council ruling\n\n' &&
      printf -- '- home: %s\n- task: %s\n- key: %s\n- ruling: %s (unanimous, %s blind seats)\n' "$O_HOME" "$task" "$key" "$first" "$i"
    else
      printf '# Watchdog council record - no ruling\n\n' &&
      printf -- '- home: %s\n- task: %s\n- key: %s\n- ruling: none (not unanimous, %s blind seats; held for the owner)\n' "$O_HOME" "$task" "$key" "$i"
    fi &&
    printf -- '- seats:%s\n- seat models: %s\n- at: %s\n\n' "$answers" "$seats" "$(fm_wd_iso "$(wd_now)")" &&
    printf 'Record:\n\n%s\n' "$summary"
  } > "$record.tmp" && [ ! -d "$record" ] && mv "$record.tmp" "$record"; then
    fm_lock_release "$lock"
  else
    rm -f "$record.tmp" 2>/dev/null
    fm_lock_release "$lock"
    printf 'failed\t\t\t%s\n' "$answers"
    return 0
  fi
  if [ "$unanimous" = 1 ]; then
    printf 'unanimous\t%s\t%s\t%s\n' "$first" "$record" "$answers"
  else
    printf 'no-ruling\t\t%s\t%s\n' "$record" "$answers"
  fi
}

# One ledger row for a council result, closing the pending row of the same id.
wd_council_ledger() {  # <id> <task> <key> <result>
  case "$4" in
    unanimous*) wd_rec "$1" "decision:$3" council "done" "$(printf '%s' "$4" | cut -f2,4)" ;;
    no-ruling*) wd_rec "$1" "decision:$3" council "done" "no ruling;$(printf '%s' "$4" | cut -f4)" ;;
    refused*) wd_rec "$1" "decision:$3" council refused "$(printf '%s' "$4" | cut -f4)" ;;
    busy*) wd_rec "$1" "decision:$3" council held "another council on $2 $3 is running" ;;
    *) wd_rec "$1" "decision:$3" council failed "no final council record;$(printf '%s' "$4" | cut -f4)" ;;
  esac
}

wd_council_line() {  # <outcome> <answer> <record> <prior> <seats>
  printf 'council=%s answer=%s record=%s prior=%s seats=%s\n' "$1" "${2:-none}" "${3:-none}" "$4" "${5:-none}"
}

# cmd_council: one convening on demand, for a supervisor that needs a ruling now.
# Prints `council=<outcome> answer=<PROCEED x|none> record=<path|none> prior=<0|1> seats=<answers>`.
# It types nothing and nudges nobody; the caller applies the result.
cmd_council() {
  local task='' key='' home='' file='' summary res id rec
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:?--task needs a task id}; shift ;;
      --key) key=${2:?--key needs a decision key}; shift ;;
      --home) home=$(cd -P -- "${2:?--home needs a path}" && pwd -P) || die "no such home: $2" 2; shift ;;
      --record-file) file=${2:?--record-file needs a path}; shift ;;
      *) die "unknown council option: $1" 2 ;;
    esac
    shift
  done
  [ -n "$task" ] && [ -n "$key" ] || die "usage: council --task <id> --key <key> [--home <path>] [--record-file <file>]" 2
  case "$task$key" in *[!A-Za-z0-9._-]*) die "task and key may hold only letters, digits, dot, underscore, and dash" 2 ;; esac
  [ -n "$home" ] || home=$(cd -P -- "$OWNER_HOME" && pwd -P)
  wd_subjects | awk -F'\t' -v h="$home" '$1 == h { f = 1 } END { exit !f }' || die "not a watched home: $home" 2
  mkdir -p "$WD"
  O_HOME=$home O_TAG=$(wd_tag "$home") O_KEY=$(wd_state_key "$home")
  if [ -n "$file" ]; then
    [ -f "$file" ] || die "no such record file: $file" 2
    summary=$(cat "$file") || die "cannot read record file: $file"
  else
    summary=$(wd_open_decisions "$home/state" "$(wd_now)" 2>/dev/null | awk -F'\t' -v t="$task" -v k="$key" '$1 == t && $2 == k { print $5; exit }')
  fi
  [ -n "$summary" ] || die "no record: $task has no open decision $key and no --record-file was given"
  id=$(wd_id)
  if wd_decision_reserved "$task" "$key" "$summary"; then
    if fm_secret_like "$task $key $summary"; then
      wd_rec "$id" "decision" council held "an owner-reserved or secret-looking record; no seat saw it"
    else
      wd_rec "$id" "decision:$key" council held "$task $key is the owner's; no seat saw it"
    fi
    wd_council_line held '' '' 0 ''
    return 0
  fi
  summary=$(printf '%s' "$summary" | tr '\t\r\n' '   ')
  if [ "${#summary}" -gt "$WD_COUNCIL_MAX_CHARS" ]; then
    wd_rec "$id" "decision:$key" council refused "record exceeds $WD_COUNCIL_MAX_CHARS characters"
    wd_council_line refused '' '' 0 ''
    return 0
  fi
  if [ "$(wd_decisions_mode)" != act ]; then
    wd_rec "$id" "decision:$key" council dry-run "would convene council on $task $key"
    wd_council_line dry-run '' '' 0 ''
    return 0
  fi
  rec=$(wd_council_record "$task" "$key")
  if [ -n "$rec" ]; then
    wd_council_line "$(printf '%s' "$rec" | cut -f1)" "$(printf '%s' "$rec" | cut -f2)" "$(printf '%s' "$rec" | cut -f3)" 1 "$(printf '%s' "$rec" | cut -f4 | sed 's/^ //')"
    return 0
  fi
  wd_rec "$id" "decision:$key" council pending "$task $key (on demand)"
  res=$(wd_council "$task" "$key" "$summary")
  wd_council_ledger "$id" "$task" "$key" "$res"
  case "$res" in
    unanimous*) wd_council_line ruled "$(printf '%s' "$res" | cut -f2)" "$(printf '%s' "$res" | cut -f3)" 0 "$(printf '%s' "$res" | cut -f4 | sed 's/^ //')" ;;
    no-ruling*) wd_council_line no-ruling '' "$(printf '%s' "$res" | cut -f3)" 0 "$(printf '%s' "$res" | cut -f4 | sed 's/^ //')" ;;
    refused*) wd_council_line refused '' '' 0 '' ;;
    busy*) wd_council_line busy '' '' 0 '' ;;
    *) wd_council_line failed '' '' 0 "$(printf '%s' "$res" | cut -f4 | sed 's/^ //')" ;;
  esac
}

# --- restart -------------------------------------------------------------------

# Print the configured command, with --yolo inserted after its first muse word
# in command position when it starts muse and carries none of --yolo, --disable-approval, or
# --approval-mode never. Any other command prints unchanged. Words split on
# whitespace only; the prompt appended at launch is not part of the check.
wd_restart_command_yolo() {
  local cmd=$1 rest word bare lead prev='' out='' at='' approved=0 cmdpos=1
  rest=$cmd
  while [ -n "$rest" ]; do
    lead=${rest%%[![:space:]]*}
    out+=$lead
    rest=${rest#"$lead"}
    [ -n "$rest" ] || break
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
    out+=$word
    bare=$word
    case "$bare" in \"*\") bare=${bare#\"}; bare=${bare%\"} ;; \'*\') bare=${bare#\'}; bare=${bare%\'} ;; esac
    if [ "$cmdpos" = 1 ]; then
      case "$bare" in
        [A-Za-z_]*=*|env|exec|command) ;;
        muse|*/muse|muse-bin|*/muse-bin|muse-bin-*|*/muse-bin-*) [ -n "$at" ] || at=${#out}; cmdpos=0 ;;
        *) cmdpos=0 ;;
      esac
    fi
    case "$word" in '&&'|'||'|';'|'|'|*';') cmdpos=1 ;; esac
    case "$bare" in
      --yolo|--disable-approval|--approval-mode=never) approved=1 ;;
    esac
    if [ "$prev" = "--approval-mode" ] && [ "$bare" = never ]; then approved=1; fi
    prev=$bare
  done
  if [ -n "$at" ] && [ "$approved" = 0 ]; then
    printf '%s --yolo%s\n' "${cmd:0:$at}" "${cmd:$at}"
  else
    printf '%s\n' "$cmd"
  fi
}

wd_restart_gate() {  # <symptom> <kind>...  -> 0 to proceed; records the refusal otherwise
  local symptom=$1 id now count last
  shift
  id=$(wd_id) now=$(wd_now)
  wd_rate_open "$symptom" restart "$(cfgi restart-secs 7200)" || return 1
  if [ -f "$WD/escalated/$O_KEY" ]; then wd_gap "RESTART LOOP escalated; clear $WD/escalated/$O_KEY after review"; return 1; fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" "$symptom" restart refused "endpoint is on do-not-touch"; return 1; fi
  if [ "$O_PARENT" = - ] && [ "$(cfg restart-scope all)" = second-mates ]; then
    wd_rec "$id" "$symptom" restart refused "restart-scope is second-mates; a primary is never restarted"
    return 1
  fi
  if ! fm_wd_stall_proof "$O_TURN" "$O_CPU_BUSY" "$@"; then
    wd_gap "$symptom: restart not proven (turn_running=$O_TURN cpu_busy=$O_CPU_BUSY signals=$*)"
    return 1
  fi
  count=$(fm_wd_count_since "$LEDGER" "$O_HOME" '*' restart '^pending$' "$((now - 86400))")
  last=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  if [ "$count" -ge "$(cfgi max-restarts 2)" ]; then
    mkdir -p "$WD/escalated"
    printf '%s\n' "$now" > "$WD/escalated/$O_KEY"
    wd_rec "$id" "$symptom" restart escalated "restart loop: $count restarts in 24h"
    wd_self_heal "restart-loop" "Watchdog restart loop for $O_TAG" "symptom $symptom recurred after $count restarts in 24h"
    return 1
  fi
  if [ -n "$last" ] && [ $((now - last)) -lt "$(cfgi restart-secs 7200)" ]; then
    wd_gap "$symptom: restart held; last restart was $(((now - last) / 60))m ago"
    return 1
  fi
  if [ "$(cfg restart off)" != on ]; then wd_rec "$id" "$symptom" restart refused "restart is off; stall proven by $*"; return 1; fi
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$symptom" restart dry-run "would restart; stall proven by $*"; return 1; fi
  return 0
}

wd_restart_available() {
  local last
  if [ "$(cfg restart off)" != on ]; then wd_gap "restart requested or context low, but restart is off; no handoff is asked for"; return 1; fi
  if [ "$O_PARENT" = - ] && [ "$(cfg restart-scope all)" = second-mates ]; then wd_gap "restart requested or context low, but restart-scope is second-mates; no handoff is asked for"; return 1; fi
  if [ -f "$WD/escalated/$O_KEY" ]; then wd_gap "restart requested or context low, but restarts are escalated; no handoff is asked for"; return 1; fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_gap "restart requested or context low, but this endpoint is on do-not-touch; no handoff is asked for"; return 1; fi
  if [ "$O_ACT_AGE" = unknown ]; then wd_gap "restart requested or context low, but no activity source can prove quiet; no handoff is asked for"; return 1; fi
  if [ "$O_PARENT" = - ]; then
    if [ -z "$(cfg restart-command "")" ]; then wd_gap "restart requested or context low, but no restart-command is set; no handoff is asked for"; return 1; fi
    case "$O_BACKEND" in orca|tmux) ;; *) wd_gap "restart requested or context low, but backend ${O_BACKEND:-none} has no restart launcher; no handoff is asked for"; return 1 ;; esac
    if [ -z "$O_LOCK_PID" ]; then wd_gap "restart requested or context low, but no lock holder is recorded; no handoff is asked for"; return 1; fi
    if [ "$O_ALIVE" = 1 ] && [ "$O_INSTANCE" != match ]; then wd_gap "restart requested or context low, but the lock anchor does not match; no handoff is asked for"; return 1; fi
  fi
  last=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  if [ -n "$last" ] && [ $(($(wd_now) - last)) -lt "$(cfgi restart-secs 7200)" ]; then
    wd_gap "restart held; last restart was $((($(wd_now) - last) / 60))m ago, so no handoff is asked for"
    return 1
  fi
}

wd_newest_session_handoff() {
  # shellcheck disable=SC2012  # newest-first by mtime; handoff names are firstmate-written
  ls -t "$O_HOME"/data/handoff-*.md 2>/dev/null | head -n 1
}

wd_write_handoff() {  # <symptom> -> prints path
  local symptom=$1 path latest draft='' lost=0 unseen=0
  local note='Unsent draft at restart, never submitted. Treat it as a note and do not act on it without review:'
  mkdir -p "$OUT/handoffs"
  path=$OUT/handoffs/$O_KEY-$(wd_now).md
  latest=$(wd_newest_session_handoff)
  if [ "$O_COMPOSER" != empty ]; then
    if [ "$O_COMPOSER" != unknown ] && fm_wd_paste_placeholder "$O_COMPOSER_TEXT"; then lost=1
    elif [ -n "$O_DRAFT" ]; then
      draft=$O_DRAFT
      note='Composer field at restart, never submitted. It may be an unsent draft or a harness suggestion. Treat it as a note and do not act on it without review:'
    elif [ "$O_COMPOSER" = pending ] && [ -n "$(printf '%s' "$O_COMPOSER_TEXT" | tr -d '[:space:]')" ]; then
      if fm_wd_draft_readable "$O_COMPOSER_TEXT" "$O_COMPOSER_ABOVE"; then draft=$(fm_wd_draft_rows "$O_COMPOSER_TEXT"); else lost=1; fi
    else
      unseen=1
    fi
  fi
  [ "$lost" = 0 ] || wd_gap "$symptom restart lost an unreadable draft (composer $O_COMPOSER); the handoff records the gap"
  {
    printf '# Watchdog restart handoff - %s\n\n' "$O_TAG"
    printf -- '- home: %s\n- reason: %s\n- at: %s\n- newest session handoff: %s\n' "$O_HOME" "$symptom" "$(fm_wd_iso "$(wd_now)")" "${latest:-none}"
    printf -- '- owed input: %s rows, oldest %ss\n- away mode: %s\n\n' "$O_OWED_N" "$O_OWED_AGE" "$O_AFK"
    printf 'Start with the newest session handoff above when it exists, then run the session-start contract.\n\n'
    [ "$lost" = 0 ] ||
      printf 'GAP: an unsent draft could not be read in full (composer %s), and its hidden text is lost with this restart.\n\n' "$O_COMPOSER"
    [ "$unseen" = 0 ] ||
      printf 'Composer state was unknown at restart (read as %s), and no draft was seen.\n\n' "$O_COMPOSER"
    # shellcheck disable=SC2016  # literal Markdown fences
    [ -z "$draft" ] ||
      printf '%s\n\n```\n%s\n```\n\n' "$note" "$draft"
    # shellcheck disable=SC2016  # literal Markdown fences
    printf 'Pane tail at restart:\n\n```\n%s\n```\n' "$(printf '%s\n' "$O_PANE" | fm_wd_strip_ansi | tail -n 40)"
  } > "$path"
  printf '%s\n' "$path"
}

wd_restart() {  # <symptom> <kind>...
  local symptom=$1 launch_lock='' rc=0
  shift
  wd_restart_gate "$symptom" "$@" || return 0
  # A low-context restart rests on the reset observed earlier in this pass.
  # The fresh-start launcher records a failure while it holds its launch lock,
  # so hold that lock from the reset's re-read through the restart: no launch
  # is under way, and one that failed has already left auto-compaction as the
  # surviving session's reset. Both refusals are gaps, not restart rows, so
  # they never hold a later restart behind the restart rate.
  if [ "$symptom" = restart-requested ] && [ "$O_RESTART_REQ" != 1 ]; then
    if ! fm_lock_try_acquire "$O_HOME/state/.handoff-launch.lock"; then
      wd_gap "$symptom held; a fresh-start launch is under way"
      return 0
    fi
    launch_lock=$O_HOME/state/.handoff-launch.lock
    if [ "$(fm_context_reset_for_session "$O_HOME" "$O_SESSION")" = compaction ]; then
      fm_lock_release "$launch_lock"
      wd_gap "$symptom held; a failed fresh-start launch left this cycle to auto-compaction"
      return 0
    fi
  elif [ "$symptom" = heartbeat-frozen ]; then
    if ! fm_lock_try_acquire "$O_HOME/state/.handoff-launch.lock"; then
      wd_gap "$symptom held; a fresh-start launch is under way"
      return 0
    fi
    launch_lock=$O_HOME/state/.handoff-launch.lock
    if fm_wd_handoff_in_progress "$O_HOME/state/.handoff-pending" "$O_LOCK_PID" "$(wd_now)" 600 \
      || ! wd_same_live_owner "$O_HOME/state" \
      || [ "$(wd_heartbeat_owner)" != "${WD_HEARTBEAT_OWNER:-}" ]; then
      fm_lock_release "$launch_lock"
      wd_gap "$symptom held; handoff or owner changed before the serialized restart"
      return 0
    fi
  fi
  wd_restart_run "$symptom" || rc=$?
  [ -z "$launch_lock" ] || fm_lock_release "$launch_lock"
  return "$rc"
}

wd_restart_run() {  # <symptom>
  local symptom=$1 id handoff token cmd yolo_cmd yolo_note prompt pid i sess
  id=$(wd_id)
  handoff=$(wd_write_handoff "$symptom")
  if [ "$O_PARENT" != - ]; then
    # The handoff never reaches a second mate, so it cannot run pickup; its own
    # session start proves the takeover instead, and wd_reconcile_pending closes the row.
    wd_rec "$id" "$symptom" restart pending "second mate relaunch through its parent; pickup=session-start old_pid=$O_LOCK_PID handoff=$handoff"
    WD_RESTARTED=1
    if ! FM_HOME=$O_PARENT fm_run_timed "$(cfgi relaunch-timeout-secs 900)" "$SCRIPT_DIR/fm-control.sh" "$O_ID" relaunch --note-file "$handoff" >/dev/null 2>&1; then
      wd_rec "$id" "$symptom" restart failed "fm-control relaunch refused or failed"
      wd_self_heal "$symptom" "Watchdog could not relaunch $O_TAG" "fm-control relaunch failed after $symptom"
    fi
    return 0
  fi
  cmd=$(cfg restart-command "")
  if [ -z "$cmd" ]; then wd_rec "$id" "$symptom" restart refused "no restart-command configured"; return 0; fi
  yolo_cmd=$(wd_restart_command_yolo "$cmd")
  yolo_note=''
  if [ "$yolo_cmd" != "$cmd" ]; then cmd=$yolo_cmd; yolo_note=' restart-command: --yolo added by default'; fi
  case "$O_BACKEND" in orca|tmux) ;; *) wd_rec "$id" "$symptom" restart refused "no restart launcher for backend $O_BACKEND"; return 0 ;; esac
  if [ -z "$O_LOCK_PID" ]; then wd_rec "$id" "$symptom" restart refused "no lock holder recorded"; return 0; fi
  if [ "$O_ALIVE" = 1 ] && [ "$O_INSTANCE" != match ]; then wd_rec "$id" "$symptom" restart refused "lock anchor does not match its recorded instance"; return 0; fi
  if [ "$O_BACKEND" = tmux ]; then
    sess=$(fm_run_timed 10 tmux display-message -p -t "$O_TARGET" '#{session_name}' 2>/dev/null) || sess=''
    sess=${sess:-firstmate-$O_TAG}
  fi
  token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  pid=$O_LOCK_PID
  wd_rec "$id" "$symptom" restart pending "token=$token old_pid=$pid handoff=$handoff$yolo_note"
  WD_RESTARTED=1
  if [ "$O_ALIVE" = 1 ]; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while wd_pid_alive "$pid" && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
    if wd_pid_alive "$pid"; then
      wd_rec "$id" "$symptom" restart failed "old session pid $pid did not stop on TERM; left running"
      return 0
    fi
  fi
  prompt="Watchdog restart of this firstmate home. Read $handoff first, then take over as the session-start contract says. After you hold the session lock, run: FM_HOME=$O_HOME $SCRIPT_DIR/fm-watchdog.sh pickup $token"
  case "$O_BACKEND" in
    orca) fm_orca_cli_mutation fm_run_timed 60 orca terminal create --worktree "path:$O_HOME" --title "firstmate captain" --command "$cmd $(printf '%q' "$prompt")" --json >/dev/null 2>&1 ;;
    tmux)
      if fm_run_timed 10 tmux has-session -t "=$sess" >/dev/null 2>&1; then
        fm_run_timed 30 tmux new-window -d -t "=$sess:" -c "$O_HOME" -n firstmate "$cmd $(printf '%q' "$prompt")" >/dev/null 2>&1
      else
        fm_run_timed 30 tmux new-session -d -s "$sess" -c "$O_HOME" -n firstmate "$cmd $(printf '%q' "$prompt")" >/dev/null 2>&1
      fi ;;
  esac || { wd_rec "$id" "$symptom" restart failed "new terminal launch failed"; return 0; }
}

# Close each pending row once: nudges by transcript or pane progress, restarts by pickup.
# A second mate's pickup is its session start: bin/fm-session-start.sh writes
# state/.session-start-complete with the lock pid once it holds the lock.
wd_reconcile_pending() {
  local now id home symptom action at tag tok old pick lockpid tr st detail picked done_note miss_note started
  now=$(wd_now)
  fm_wd_open_pending "$LEDGER" | while IFS=$'\t' read -r id home symptom action at; do
    tag=$(wd_tag "$home")
    st=$home/state
    case "$action" in
      nudge)
        tr=$(wd_transcript "$home" "$(fm_session_lock_recorded_session_id "$st" 2>/dev/null)") || tr=''
        if [ -n "$tr" ] && [ "$(wd_mtime "$tr")" -gt "$at" ]; then
          FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" nudge "done" "transcript advanced"
        elif [ $((now - at)) -ge "$(cfgi pickup-secs 600)" ]; then
          if [ -z "$tr" ]; then
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" nudge "done" "delivered; no transcript to confirm"
          else
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" nudge failed "no transcript progress"
          fi
        fi ;;
      restart)
        detail=$(awk -F'\t' -v i="$id" '$2 == i && $7 == "pending" { print $8 }' "$LEDGER" | tail -n 1)
        tok=$(printf '%s\n' "$detail" | sed -n 's/.*token=\([0-9a-f]*\).*/\1/p')
        old=$(printf '%s\n' "$detail" | sed -n 's/.*old_pid=\([0-9]*\).*/\1/p')
        lockpid=$(head -n 1 "$st/.lock" 2>/dev/null | tr -cd '0-9')
        picked=0
        if [ -n "$tok" ]; then
          pick=$st/watchdog/pickups/$tok
          [ -f "$pick" ] && picked=1
          done_note="pickup verified; new lock pid $lockpid"
          miss_note="restart token $tok had no verified pickup"
        else
          case "$detail" in
            *pickup=session-start*) ;;
            *)
              [ $((now - at)) -ge "$(cfgi relaunch-timeout-secs 900)" ] && FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart failed "relaunch recorded no outcome"
              continue ;;
          esac
          pick=$st/.session-start-complete
          started=$(wd_mtime "$pick" | tr -cd '0-9')
          if [ -n "$started" ] && [ "$(head -n 1 "$pick" 2>/dev/null | tr -cd '0-9')" = "$lockpid" ] &&
            [ "$started" -ge "$at" ] && [ "$started" -le $((at + $(cfgi pickup-secs 600))) ]; then picked=1; fi
          done_note="session start verified; new lock pid $lockpid"
          miss_note="second mate relaunch had no verified session start under a new lock"
        fi
        if [ "$picked" = 1 ] && [ -n "$lockpid" ] && [ "$lockpid" != "$old" ] && wd_pid_alive "$lockpid"; then
          if [ -f "$st/.afk" ] && ! kill -0 "$(head -n 1 "$st/.supervise-daemon.pid" 2>/dev/null | tr -cd '0-9')" 2>/dev/null; then
            [ $((now - at)) -lt "$(cfgi pickup-secs 600)" ] && continue
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart failed "picked up but the away daemon is not running"
          else
            FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart "done" "$done_note"
          fi
        elif [ $((now - at)) -ge "$(cfgi pickup-secs 600)" ]; then
          FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" restart failed "no verified pickup within the window"
          O_TAG=$tag O_HOME=$home wd_self_heal "$symptom" "Watchdog restart of $tag was not picked up" "$miss_note"
        fi ;;
      *)
        [ $((now - at)) -ge 3600 ] && FM_WD_NOW=$now fm_wd_record "$LEDGER" "$id" "$home" "$tag" "$symptom" "$action" failed "no outcome recorded" ;;
    esac
  done
}

# --- self-heal issue -------------------------------------------------------------

wd_self_heal() {  # <class> <title> <evidence>
  local class="watchdog-$1" id repo
  id=$(wd_id)
  repo=$(cfg issue-repo "")
  if [ -z "$repo" ]; then wd_gap "self-heal issue not filed for $class: no issue-repo configured"; return 0; fi
  [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" "$class" self-heal '^(pending|dry-run)$' "$(( $(wd_now) - 86400 ))")" -eq 0 ] || return 0
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" "$class" self-heal dry-run "would file: $2"; return 0; fi
  wd_rec "$id" "$class" self-heal pending "$2"
  if out=$(FM_HOME=$OWNER_HOME fm_run_timed 120 "$SCRIPT_DIR/fm-self-heal-issue.sh" --repo "$repo" \
      --failure-class "$class" --title "$2" --evidence "$3" --instance-fix "watchdog action ladder on $O_TAG" 2>&1); then
    wd_rec "$id" "$class" self-heal "done" "$out"
  else
    wd_rec "$id" "$class" self-heal failed "$(printf '%s' "$out" | tail -n 1)"
  fi
}

# --- the ladder ------------------------------------------------------------------

wd_heartbeat_owner() {
  local start
  wd_same_live_owner "$O_HOME/state" || return 1
  start=$(fm_session_process_start "$O_LOCK_PID") || return 1
  printf 'heartbeat-owner=%s:%s:%s\n' "$O_LOCK_PID" "${O_SESSION:-none}" "$start"
}

wd_heartbeat_frozen() {
  local secs
  secs=$(cfgi heartbeat-frozen-secs 600)
  [ "$O_OWNER" = live ] && [ "$secs" -gt 0 ] && [ "$O_HB_AGE" != unknown ] && [ "$O_HB_AGE" -ge "$secs" ]
}

wd_handle_heartbeat_frozen() {
  local now stale_at last since kinds owner
  now=$(wd_now)
  stale_at=$((now - O_HB_AGE))
  wd_rate_open heartbeat-frozen detect "$(cfgi nudge-secs 900)" &&
    wd_rec "$(wd_id)" heartbeat-frozen detect held "heartbeat ${O_HB_AGE}s old; lock pid $O_LOCK_PID live"
  if fm_wd_handoff_in_progress "$O_HOME/state/.handoff-pending" "$O_LOCK_PID" "$now" 600; then
    wd_gap "heartbeat is stale during a pending handoff; nothing typed"
    return 0
  fi
  if [ "$O_TURN" = 1 ] || [ "$O_CPU_BUSY" = 1 ]; then
    wd_gap "heartbeat is stale during active work; treated as busy"
    return 0
  fi
  if [ "$O_COMPOSER" != empty ] || [ "$O_AUTOWAIT" = 1 ] || [ "${O_LIMIT_FOOTER:-0}" = 1 ]; then
    wd_gap "heartbeat is stale but the existing composer or quota guard takes precedence"
    return 0
  fi
  if [ "$O_ACT_AGE" = unknown ]; then
    wd_gap "heartbeat recovery held; no verified session activity source"
    return 0
  fi
  owner=$(wd_heartbeat_owner) || { wd_gap "heartbeat recovery held; owner identity is unproven"; return 0; }
  last=$(awk -F'\t' -v h="$O_HOME" -v owner="$owner" '
    $3 == h && $5 == "heartbeat-frozen" && $6 == "nudge" && $7 == "done" && $8 == owner { at = $1 }
    END { print at }
  ' "$LEDGER" 2>/dev/null)
  if [ -z "$last" ] || [ "$last" -lt "$stale_at" ]; then
    wd_nudge heartbeat-frozen "this session's heartbeat is stale while its lock is live. Re-arm supervision, then drain the wake queue and act on it."
    return 0
  fi
  since=$((now - last))
  if [ "$since" -lt "$(cfgi heartbeat-restart-secs 240)" ]; then
    wd_gap "heartbeat is stale; waiting after the delivered nudge"
    return 0
  fi
  if [ "$O_ACT_AGE" -lt "$since" ]; then
    wd_rate_open heartbeat-frozen responsive "$(cfgi nudge-secs 900)" &&
      wd_rec "$(wd_id)" heartbeat-frozen responsive held "verified $O_ACT_SRC activity advanced after the nudge; no restart"
    wd_nudge heartbeat-frozen "the heartbeat is still stale after this session responded. Re-arm supervision, then drain the wake queue and act on it."
    return 0
  fi
  kinds='records filesystem'
  if [ -n "$O_PANE" ] && [ "$O_PANE_STATIC" -ge $((since - $(cfgi interval-secs 120))) ]; then kinds="$kinds rendered"; fi
  if ! wd_same_live_owner "$O_HOME/state" || [ "$(wd_heartbeat_owner)" != "$owner" ]; then
    wd_gap "heartbeat recovery held; owner changed after its delivery receipt was read"
    return 0
  fi
  # shellcheck disable=SC2086 # kinds is a word list accepted by the restart proof.
  WD_HEARTBEAT_OWNER=$owner wd_restart heartbeat-frozen $kinds
}

wd_ladder_nudge_then_restart() {  # <symptom> <nudge-body> <kind>...
  local symptom=$1 body=$2 nudges
  shift 2
  if wd_unsent_is_stable; then wd_submit_unsent && return 0; fi
  nudges=$(fm_wd_count_since "$LEDGER" "$O_HOME" "$symptom" nudge '^(pending|dry-run|held)$' "$(( $(wd_now) - 7200 ))")
  if [ "$nudges" -lt "$(cfgi max-nudges 2)" ]; then
    wd_nudge "$symptom" "$body"
  else
    wd_restart "$symptom" "$@"
  fi
}

wd_rearm_feedback_dialog() {  # <backend> <target> <harness> <screen> [expected-label]
  local backend=$1 target=$2 harness=$3 screen=$4 label=${5-}
  [ -n "$screen" ] && [ "$(wd_mode)" = act ] || return 0
  wd_do_not_touch "$O_HOME" "$target" && return 0
  fm_control_feedback_dialog_dismiss "$harness" "$screen" >/dev/null 2>&1 && return 0
  if [ -z "$label" ]; then
    case "${O_ID:-}" in ''|-) ;; *) label=fm-$O_ID ;; esac
  fi
  fm_control_dismiss_feedback_dialog "$O_HOME/state" "$backend" "$target" "$harness" "$screen" "$label" 0 "$(cfgi call-timeout-secs 20)" >/dev/null 2>&1 || true
}

wd_handle_dialog() {
  local opts pick n text key dialog_pane id label='' rc=0
  # Two keys that did not clear a dialog within the hour stop the presses, so a
  # misread screen never keeps typing into the session and no model is asked.
  case "$O_DIALOG" in
    feedback|model-switch)
      if [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" dialog key '^failed$' "$(( $(wd_now) - 3600 ))" "${O_REC_SUBJECT:-$O_TAG}")" -ge 2 ]; then
        wd_gap "a $O_DIALOG dialog did not clear after two keys this hour; no more keys pressed"
        return 0
      fi ;;
  esac
  case "$O_DIALOG" in
    feedback)
      dialog_pane=${O_DIALOG_PANE:-$O_PANE}
      if ! key=$(fm_wd_feedback_dialog_key "$dialog_pane" "${O_HARNESS:-}" 2>/dev/null) || [ -z "$key" ]; then
        wd_gap "feedback dialog key could not be resolved; no key pressed"
        return 0
      fi
      wd_rate_open dialog key "$(cfgi key-secs 120)" "${O_REC_SUBJECT:-$O_TAG}" || return 0
      id=$(wd_id)
      if wd_do_not_touch "$O_HOME" "$O_TARGET"; then wd_rec "$id" dialog key refused "endpoint is on do-not-touch"; return 0; fi
      if [ "$(wd_mode)" != act ]; then wd_rec "$id" dialog key dry-run "would press $key: dismiss the feedback survey"; return 0; fi
      case "${O_ID:-}" in ''|-) ;; *) label=fm-$O_ID ;; esac
      fm_control_dismiss_feedback_dialog "$O_HOME/state" "$O_BACKEND" "$O_TARGET" "${O_HARNESS:-}" "$dialog_pane" "$label" "$(cfgi key-settle-secs 2)" "$(cfgi call-timeout-secs 20)" || rc=$?
      case "$rc" in
        0)
          wd_rec "$id" dialog key pending "press $FM_CONTROL_FEEDBACK_DISMISS_KEY: dismiss the feedback survey"
          wd_rec "$id" dialog key "done" "dialog left the pane"
          O_DIALOG=''
          O_PANE=$FM_CONTROL_FEEDBACK_AFTER_PANE
          O_DIALOG_PANE=$FM_CONTROL_FEEDBACK_AFTER_PANE
          [ -n "${O_REC_SUBJECT:-}" ] || wd_read_composer
          ;;
        1)
          return 0
          ;;
        2)
          wd_gap "feedback dialog still showing after an earlier dismiss key; no second key pressed"
          return 0
          ;;
        3)
          wd_rec "$id" dialog key pending "press $FM_CONTROL_FEEDBACK_DISMISS_KEY: dismiss the feedback survey"
          wd_rec "$id" dialog key failed "key delivery failed"
          return 1
          ;;
        *)
          wd_rec "$id" dialog key pending "press $FM_CONTROL_FEEDBACK_DISMISS_KEY: dismiss the feedback survey"
          wd_rec "$id" dialog key failed "dialog still showing"
          return 1
          ;;
      esac ;;
    permission)
      wd_gap "permission dialog waiting; the watchdog never answers permission prompts"
      wd_page_permission ;;
    usage-limit)
      wd_quota_name_pick_rated "$(wd_id)" "${O_ID:-$O_TAG}"
      ;;
    model-switch)
      opts=$(fm_wd_dialog_options "$O_PANE")
      text=$(fm_wd_dialog_text "$O_PANE")
      if fm_wd_reserved "$text"; then wd_gap "model-switch dialog names an owner-reserved category; held"; return 0; fi
      if fm_secret_like "$text"; then wd_gap "model-switch dialog text looks like a secret; held"; return 0; fi
      if ! wd_rate_open dialog judge "$(cfgi nudge-secs 900)"; then wd_gap "model-switch dialog waiting; the next judge call waits for nudge-secs"; return 0; fi
      wd_rec "$(wd_id)" dialog judge held "model-switch judge call"
      pick=$(wd_judge dialog '(OPTION [0-9]{1,2}|NONE)' "A coding agent's terminal shows this dialog about models or usage limits:
$text
Options:
$opts
Pick the option that keeps work going on another model or account without buying credits, signing in, or spending money. Reply with exactly one line: OPTION <number> or NONE.") || {
        wd_gap "model-switch dialog waiting; no model available to pick an option"; return 0; }
      n=${pick#OPTION }
      case "$pick" in OPTION*) ;; *) wd_gap "model-switch dialog: judge picked none"; return 0 ;; esac
      text=$(printf '%s\n' "$opts" | awk -F'\t' -v n="$n" '$1 == n { print $2 }')
      if [ -z "$text" ] || fm_wd_reserved "$text" || ! fm_wd_text_allowed "$text" || printf '%s' "$text" | grep -Eiq 'buy|purchase|upgrade|credit'; then
        wd_rec "$(wd_id)" dialog key refused "option $n (${text:-unknown}) is reserved or spends money"
        return 0
      fi
      wd_key dialog "$n" "model-switch option $n: $text" ;;
    question) wd_gap "question dialog waiting; its kind is not proven, so no key is sent" ;;
  esac
}

# A permission dialog on an away session has nobody to answer it, so the owner
# is paged through the home's own alert channels at most once per nudge-secs.
# O_REC_SUBJECT, when set, is the worker this page belongs to, and that subject
# has its own window so one pane does not consume another's or the home's.
# The page carries no dialog text; the ledger row records which dialog fired,
# withheld for a credential or sign-in prompt or when it looks like a secret. A
# dashed rule is shortened before the text is cut at 300 characters, so a pane-wide
# rule does not push the command out of the row. Quiet mode is not paged: the owner is
# watching the session there.
wd_page_permission() {
  local text id summary out rc subject who
  [ "$O_AFK" = 1 ] && [ "$(fm_afk_mode "$O_HOME/state")" = away ] || return 0
  subject=${O_REC_SUBJECT:-$O_TAG}
  fm_wd_rate_ok "$LEDGER" "$O_HOME" dialog page "$(cfgi nudge-secs 900)" "$(wd_now)" "$subject" || return 0
  text=$(fm_wd_dialog_text "$O_PANE")
  # A credential or sign-in stop may already hold a typed value the secret
  # detector cannot recognize, so its text is never recorded.
  if case "${WD_PP_REASON:-}" in credential|sign-in) true ;; *) false ;; esac; then
    text='[withheld: a credential or sign-in prompt]'
  elif fm_secret_like "$text"; then text='[withheld: the dialog text looks like a secret]'; fi
  text=$(printf '%s' "$text" | sed -E 's/(╌)+/╌╌╌/g')
  text=${text:0:300}
  id=$(wd_id)
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" dialog page dry-run "would page the owner; permission: $text"; return 0; fi
  wd_rec "$id" dialog page pending "permission: $text"
  who=$O_TAG
  if [ -n "${O_REC_SUBJECT:-}" ] && [ "$O_REC_SUBJECT" != "$O_TAG" ]; then
    who="$O_TAG worker ${O_REC_SUBJECT#worker:}"
  fi
  summary="Firstmate watchdog: a permission dialog blocks the away session of $who, and nothing will answer it. Its text is recorded in $LEDGER."
  out=$(FM_HOME=$O_HOME FM_STATE_OVERRIDE=$O_HOME/state FM_CONFIG_OVERRIDE=$O_HOME/config \
    fm_run_timed 60 bash "$SCRIPT_DIR/fm-supervise-daemon.sh" page "$summary" "$LEDGER" 2>/dev/null)
  rc=$?
  case "$rc:$out" in
    '0:page: sent') wd_rec "$id" dialog page "done" "owner paged" ;;
    2:*)
      wd_rec "$id" dialog page refused "alerts are off or no alert channel is configured"
      wd_gap "permission dialog not paged: alerts are off or no alert channel is configured" ;;
    *)
      wd_rec "$id" dialog page failed "no alert channel delivered the page (exit $rc)"
      wd_gap "permission dialog page failed on every alert channel" ;;
  esac
}

# --- worker permission prompts ------------------------------------------------
# bin/fm-permission-prompt.sh owns the verdicts; docs/watchdog.md owns the
# contract. A worker runs unattended, so a prompt on its pane has nobody to
# answer it. These functions never select a Yes option and never press Enter.

wd_pp_mark() { printf '%s/permission/%s-%s' "$WD" "$O_KEY" "$1"; }

# wd_pp_status <id> <state> <key> <text>: one keyed line in the worker's own
# status file, with the same best-effort fleet-ledger hook a worker uses.
wd_pp_status() {
  local f=$O_HOME/state/$1.status
  printf '%s [at=%s] [key=%s]: %s\n' "$2" "$(wd_now)" "$3" "$4" >> "$f" 2>/dev/null || return 1
  if [ -e "$O_HOME/config/fleet-ledger" ]; then
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$O_HOME/config" "$f" >/dev/null 2>&1 || true
  fi
}

# wd_pp_stop <id> <key> <prompt-hash> <text>: report a prompt nothing will
# answer as blocked, once per key while that line stays open, so a prompt whose
# rows keep changing (a spinner or a clock) does not append a line every pass.
wd_pp_stop() {
  local id=$1 key=$2 hash=$3 text=$4 mark prev
  WD_PP_STOPPED=1
  mark=$(wd_pp_mark "$id")
  prev=$(cat "$mark.open" 2>/dev/null) || prev=
  # A key another writer resolved, such as an fm-send --resolve-key answer, is
  # no longer open, so the marker no longer de-duplicates it.
  if [ -n "$prev" ] && ! status_open_decisions "$O_HOME/state/$id.status" 2>/dev/null \
    | awk -F'\t' -v k="${prev%% *}" '$1 == k { f = 1 } END { exit !f }'; then
    rm -f "$mark.open"
    prev=
  fi
  [ "${prev%% *}" != "$key" ] || return 0
  if [ "$(wd_permission_mode)" != act ]; then
    wd_rate_open permission-prompt report "$(cfgi nudge-secs 900)" "$O_REC_SUBJECT" \
      && wd_rec "$(wd_id)" permission-prompt report dry-run "would write blocked [key=$key]: $text"
    return 0
  fi
  if [ -n "$prev" ] && [ "${prev%% *}" != "$key" ]; then
    wd_pp_status "$id" resolved "${prev%% *}" "worker $id shows a different prompt now" || true
  fi
  mkdir -p "$WD/permission"
  if ! wd_pp_status "$id" blocked "$key" "$text"; then
    wd_rec "$(wd_id)" permission-prompt report failed "the blocked line could not be appended"
    return 0
  fi
  if ! printf '%s %s\n' "$key" "$hash" 2>/dev/null > "$mark.open"; then
    wd_rec "$(wd_id)" permission-prompt report failed "the blocked line was appended but its marker could not be written"
    return 0
  fi
  wd_rec "$(wd_id)" permission-prompt report "done" "blocked [key=$key]: $text"
}

# wd_pp_clear <id>: the worker's pane shows no reported prompt any more.
wd_pp_clear() {
  local id=$1 mark prev
  mark=$(wd_pp_mark "$id")
  prev=$(cat "$mark.open" 2>/dev/null) || return 0
  [ "$(wd_permission_mode)" = act ] || return 0
  wd_pp_status "$id" resolved "${prev%% *}" "worker $id no longer shows the prompt" || return 0
  rm -f "$mark.open"
  wd_rec "$(wd_id)" permission-prompt report "done" "resolved [key=${prev%% *}]"
}

# wd_pp_steer <id> <prompt-hash>: the declined worker reads why, durably.
wd_pp_steer() {
  local id=$1 hash=$2 text rid
  text="Watchdog (automated, not the owner): a permission prompt on your pane was declined automatically, because no person can approve prompts during unattended work. Do not repeat the same call. If it was a Bash command the harness could not check, rewrite it in a form it can check: quote heredoc delimiters (<<'EOF'), avoid unescaped backticks, or write the file with the Write or Edit tool. If the action is truly needed and no other form works, append a blocked: status line that names it instead of waiting for approval."
  rid=$(wd_id)
  # The watched home's own state, data, and config are bound explicitly, so an
  # owner override exported to this pass never resolves the id in another home.
  if FM_HOME=$O_HOME FM_STATE_OVERRIDE=$O_HOME/state FM_DATA_OVERRIDE=$O_HOME/data FM_CONFIG_OVERRIDE=$O_HOME/config \
    fm_run_timed 60 "$SCRIPT_DIR/fm-send.sh" "$id" "$text" </dev/null >/dev/null 2>&1; then
    wd_rec "$rid" permission-prompt steer "done" "rewrite instruction recorded in the worker's inbox"
    return 0
  fi
  wd_rec "$rid" permission-prompt steer failed "the rewrite instruction could not be recorded"
  wd_pp_stop "$id" permission-prompt-held "steer-$hash" "worker $id had a tool-approval prompt declined, but the rewrite instruction could not be recorded, so it may wait at its composer"
  return 1
}

# wd_pp_decline <id> <harness> <prompt-hash>: Escape on a proven Claude
# tool-approval prompt, verified gone, then the rewrite instruction. A repeated
# prompt, the hourly cap, or a do-not-touch endpoint holds instead.
wd_pp_decline() {
  local id=$1 harness=$2 hash=$3 mark cap n rid live after after_dialog verdict tries=0
  mark=$(wd_pp_mark "$id")
  if grep -Fxq -- "$hash" "$mark.declined" 2>/dev/null; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows a tool-approval prompt that already had its one Escape attempt; nothing more is pressed"
    return 1
  fi
  cap=$(cfgi permission-decline-cap 3)
  # Every attempt counts, so a failed or unconfirmed Escape uses the cap too.
  n=$(fm_wd_count_since "$LEDGER" "$O_HOME" permission-prompt decline '^pending$' "$(( $(wd_now) - 3600 ))" "$O_REC_SUBJECT")
  if [ "$n" -ge "$cap" ]; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id had $n permission prompts declined within an hour, the cap; nothing more is answered"
    return 1
  fi
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows a tool-approval prompt, and its endpoint is on do-not-touch; nothing was answered"
    return 1
  fi
  wd_rate_open permission-prompt decline "$(cfgi key-secs 120)" "$O_REC_SUBJECT" || return 1
  rid=$(wd_id)
  if [ "$(wd_permission_mode)" != act ]; then
    wd_rec "$rid" permission-prompt decline dry-run "would press Escape on a claude tool-approval prompt and send the rewrite instruction"
    return 1
  fi
  live=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) || live=
  verdict=$(fm_pp_classify "$live" "$harness") || verdict=
  if [ "$verdict" != "$(printf 'route\ttool-approval')" ] || [ "$(fm_pp_hash "$live")" != "$hash" ]; then
    wd_rec "$rid" permission-prompt decline refused "the prompt changed before the key; nothing was pressed"
    return 1
  fi
  # The checksum and the attempt are kept before the key, so one prompt gets at
  # most one Escape even when delivery or the check after it fails. A record
  # that cannot be kept presses nothing.
  # The attempt is recorded first, so a checksum on file always means the
  # Escape was about to be sent.
  if ! wd_rec "$rid" permission-prompt decline pending "press Escape on a claude tool-approval prompt"; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows a tool-approval prompt, and the attempt could not be recorded; nothing was answered"
    return 1
  fi
  if ! { mkdir -p "$WD/permission" && printf '%s\n' "$hash" >> "$mark.declined"; } 2>/dev/null; then
    wd_rec "$rid" permission-prompt decline failed "the prompt checksum could not be saved; nothing was pressed"
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows a tool-approval prompt, and its checksum could not be saved; nothing was answered"
    return 1
  fi
  if ! fm_run_timed_fn 10 fm_control_send_feedback_dismiss "$O_BACKEND" "$O_TARGET" Escape "fm-$id" >/dev/null 2>&1; then
    wd_rec "$rid" permission-prompt decline failed "key delivery failed"
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows a tool-approval prompt, and the Escape key could not be delivered; nothing was answered"
    return 1
  fi
  # A slow redraw gets three looks before the decline counts as failed; no
  # second key is pressed.
  sleep "$(cfgi key-settle-secs 2)"
  while :; do
    after=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) || after=
    if [ -n "$after" ] && ! { fm_pp_classify "$after" "$harness" >/dev/null && [ "$(fm_pp_hash "$after")" = "$hash" ]; }; then
      break
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || break
    sleep 1
  done
  if [ -z "$after" ] || { fm_pp_classify "$after" "$harness" >/dev/null && [ "$(fm_pp_hash "$after")" = "$hash" ]; }; then
    wd_rec "$rid" permission-prompt decline failed "the prompt still shows after Escape"
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id still shows a tool-approval prompt after one Escape; nothing more is pressed"
    return 1
  fi
  wd_rec "$rid" permission-prompt decline "done" "the prompt left the pane"
  # The steer's doorbell types a line and Enter, so it rings only when the
  # screen after Escape shows no dialog and no prompt of any kind.
  after_dialog=$(fm_wd_pane_dialog "$after" "$harness") || after_dialog=
  if verdict=$(fm_pp_classify "$after" "$harness" "${after_dialog:-none}"); then
    case "$verdict" in
      hardstop*) wd_pp_reason "${verdict#*$'\t'}"; wd_pp_stop "$id" permission-prompt-hardstop "after-$hash" "worker $id shows a ${verdict#*$'\t'} prompt after a declined tool call; nothing was answered, and no instruction was sent" ;;
      *) wd_pp_stop "$id" permission-prompt-held "after-$hash" "worker $id shows another permission prompt after a declined tool call (${verdict#*$'\t'}); nothing was answered, and no instruction was sent" ;;
    esac
    return 1
  fi
  if [ -n "$after_dialog" ]; then
    wd_pp_stop "$id" permission-prompt-held "after-$hash" "worker $id shows a $after_dialog dialog after a declined tool call; nothing was answered, and no instruction was sent"
    return 1
  fi
  # The doorbell types into the composer, so the instruction goes only when
  # the composer after Escape is proven empty, never on an unread screen.
  # The read runs in a subshell so the pass's own composer reading stays.
  local composer
  composer=$(wd_read_composer; printf '%s' "$O_COMPOSER")
  if [ "$composer" != empty ]; then
    wd_pp_stop "$id" permission-prompt-held "after-$hash" "worker $id shows no proven empty composer after a declined tool call (it reads $composer); nothing was answered, and no instruction was sent"
    return 1
  fi
  wd_pp_steer "$id" "$hash" || return 1
  # The prompt is handled once the instruction is recorded, so a ledger write
  # that fails after it never turns the decline into a waiting prompt.
  wd_pp_clear "$id" || true
  return 0
}

# wd_pp_relaunch <id> <prompt-hash>: a workspace-trust dialog gets no key.
# bin/fm-control.sh relaunches the worker, and its spawn pre-registers the
# worktree's trust entry. Only an Orca worker is relaunched: there fm-control
# closes the recorded terminal without a key (orca_relaunch_close), while on
# any other backend its stop can press the harness's interrupt key into a
# worker still recorded as busy, so that dialog is held. fm-control refuses
# rather than typing into a dialog it cannot close, and that refusal holds.
wd_pp_relaunch() {
  local id=$1 hash=$2 rid err note
  if wd_do_not_touch "$O_HOME" "$O_TARGET"; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows the workspace-trust dialog, and its endpoint is on do-not-touch; nothing was answered"
    return 1
  fi
  if [ "$O_BACKEND" != orca ]; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows the workspace-trust dialog, and a relaunch on the $O_BACKEND backend can press a key into it first; nothing was relaunched"
    return 1
  fi
  if ! wd_rate_open permission-prompt relaunch "$(cfgi permission-relaunch-secs 3600)" "$O_REC_SUBJECT"; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows the workspace-trust dialog again after a relaunch inside the window; nothing was answered"
    return 1
  fi
  rid=$(wd_id)
  if [ "$(wd_permission_mode)" != act ]; then
    wd_rec "$rid" permission-prompt relaunch dry-run "would relaunch the worker so its launch pre-registers workspace trust"
    return 1
  fi
  # The pending row is what keeps the next relaunch outside its window, so a
  # relaunch that cannot be recorded is never started.
  if ! wd_rec "$rid" permission-prompt relaunch pending "workspace-trust dialog: controlled relaunch"; then
    wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows the workspace-trust dialog, and the relaunch could not be recorded; nothing was relaunched"
    return 1
  fi
  note="The previous launch stopped on the workspace-trust dialog before it could work. The watchdog relaunched this worker so its launch pre-registers the worktree's trust entry; no key was typed into the dialog. Continue the task from these instructions."
  # Bound to the watched home, as the instruction in wd_pp_steer is.
  if err=$(FM_HOME=$O_HOME FM_STATE_OVERRIDE=$O_HOME/state FM_DATA_OVERRIDE=$O_HOME/data FM_CONFIG_OVERRIDE=$O_HOME/config \
    fm_run_timed "$(cfgi relaunch-timeout-secs 900)" "$WD_CONTROL" "$id" relaunch --note "$note" </dev/null 2>&1 >/dev/null); then
    wd_rec "$rid" permission-prompt relaunch "done" "worker relaunched"
    wd_pp_clear "$id"
    return 0
  fi
  err=$(printf '%s\n' "$err" | sed '/^[[:space:]]*$/d' | tail -n 1 | cut -c1-200)
  wd_rec "$rid" permission-prompt relaunch failed "relaunch refused: ${err:-no reason given}"
  wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id shows the workspace-trust dialog, and a controlled relaunch was refused; nothing was answered"
  return 1
}

# wd_pp_lock <id>: one pass at a time may press a key on, relaunch, or write
# the open marker of one worker, so overlapping run and once passes never both
# send an Escape or both write a blocked line. It is the shared pid lock
# (fm_lock_try_acquire in bin/fm-wake-lib.sh): a lock whose holder process is
# gone is reclaimed under its steal mutex, so two passes reclaiming one stale
# lock never both hold it, and a release never removes another pass's lock.
wd_pp_lock() {
  mkdir -p "$WD/permission" 2>/dev/null || return 1
  fm_lock_try_acquire "$(wd_pp_mark "$1").lock"
}

wd_pp_unlock() {
  fm_lock_release "$(wd_pp_mark "$1").lock" || true
}

# wd_pp_reason <reason>: the stop reason the page reads. A credential or
# sign-in reason already set by an earlier read of this pass is never
# replaced, because the page still carries that read's pane.
wd_pp_reason() {
  case "${WD_PP_REASON:-}" in credential|sign-in) return 0 ;; esac
  WD_PP_REASON=$1
}

# wd_permission_prompt <id> <harness> <screen> <dialog>: the unattended route
# for one worker pane. 0 = the prompt left the pane; 1 = a prompt still waits;
# 2 = no prompt verdict, or `permission-route=off`.
wd_permission_prompt() {
  local id=$1 harness=$2 screen=$3 dialog=$4 verdict kind reason hash rc live live_dialog
  # Every read below, including the checks before and after a key, must see
  # the pane as it is now, never a shared Orca reply cached a moment earlier.
  local -x FM_ORCA_CLI_CACHE=0
  WD_PP_STOPPED=
  WD_PP_REASON=
  [ "$(wd_permission_mode)" != off ] || return 2
  if ! verdict=$(fm_pp_classify "$screen" "$harness" "$dialog"); then
    # No verdict and no reported prompt leaves nothing to write.
    [ -e "$(wd_pp_mark "$id").open" ] || return 2
    kind=none
  else
    kind=${verdict%%$'\t'*}
    reason=${verdict#*$'\t'}
    case "$kind" in hardstop|hold|trust|route) ;; *) return 2 ;; esac
    # The reason is set before the lock, so a busy lock never lets a
    # credential or sign-in page record the pane text.
    [ "$kind" != hardstop ] || wd_pp_reason "$reason"
  fi
  # Every marker write for one worker runs under its lock, so overlapping run
  # and once passes never both write a blocked line or both send an Escape.
  if ! wd_pp_lock "$id"; then
    [ "$kind" != none ] || return 2
    wd_rec "$(wd_id)" permission-prompt report refused "another watchdog pass is acting on worker $id; nothing was pressed"
    # A held prompt or hard stop still gets its waiting gap and away page;
    # only the marker write waits for the lock.
    case "$kind" in hardstop|hold) WD_PP_STOPPED=1 ;; esac
    return 1
  fi
  # This pass's screen can predate a prompt another pass reported, so the
  # pane is read again under the lock and only that fresh verdict is acted
  # on: an older screen never resolves or replaces a newer report. A failed
  # read, including a dialog read that returns `unknown`, writes nothing.
  live=$(wd_capture "$O_BACKEND" "$O_TARGET" 60) || live=
  live_dialog=$(wd_observe_dialog "$O_BACKEND" "$O_TARGET" "fm-$id" "${harness:-unknown}") || live_dialog=
  if [ -z "$live" ] || [ "$live_dialog" = unknown ]; then
    wd_pp_unlock "$id"
    [ "$kind" != none ] || return 2
    wd_rec "$(wd_id)" permission-prompt report refused "worker $id could not be read again under its lock; nothing was pressed or written"
    case "$kind" in hardstop|hold) WD_PP_STOPPED=1 ;; esac
    return 1
  fi
  if ! verdict=$(fm_pp_classify "$live" "$harness" "${live_dialog:-none}"); then
    wd_pp_clear "$id"
    wd_pp_unlock "$id"
    return 2
  fi
  kind=${verdict%%$'\t'*}
  reason=${verdict#*$'\t'}
  case "$kind" in hardstop|hold|trust|route) ;; *) wd_pp_unlock "$id"; return 2 ;; esac
  # A credential or sign-in reason from either read is kept, so neither
  # read's pane text is recorded on the page.
  [ "$kind" != hardstop ] || wd_pp_reason "$reason"
  hash=$(fm_pp_hash "$live")
  case "$kind" in
    hardstop)
      wd_pp_stop "$id" permission-prompt-hardstop "$hash" "worker $id shows a $reason prompt; nothing was answered, and the watchdog never answers credential, sign-in, spend, destructive, or reserved prompts"
      rc=1 ;;
    hold)
      wd_pp_stop "$id" permission-prompt-held "$hash" "worker $id waits on a permission prompt the watchdog does not answer ($reason); nothing was answered"
      rc=1 ;;
    trust) wd_pp_relaunch "$id" "$hash"; rc=$? ;;
    route) wd_pp_decline "$id" "$harness" "$hash"; rc=$? ;;
  esac
  wd_pp_unlock "$id"
  return "$rc"
}

# A primary on Claude's usage-limit auto-wait takes no turn until the reset,
# so no nudge, key, or in-pane action can move it and the watchdog never kills
# or relaunches a primary. The owner is paged through the same alert channels
# as the away permission page, at most once per nudge-secs, with no pane text.
# The page and the gap name the worker reroute path for a manual successor:
# bin/fm-quota-reroute.sh suggest names the pick.
wd_page_captain_autowait() {
  local id summary out rc
  fm_wd_rate_ok "$LEDGER" "$O_HOME" usage-limit-autowait page "$(cfgi nudge-secs 900)" "$(wd_now)" "$O_TAG" || return 0
  id=$(wd_id)
  if [ "$(wd_mode)" != act ]; then wd_rec "$id" usage-limit-autowait page dry-run "would page the owner; the captain session is on a usage-limit auto-wait"; return 0; fi
  wd_rec "$id" usage-limit-autowait page pending "the captain session is on a usage-limit auto-wait; run bin/fm-quota-reroute.sh suggest for a successor pick"
  summary="Firstmate watchdog: the captain session of $O_TAG is on a Claude usage-limit auto-wait (Continuing automatically at reset) and takes no turns until the reset. It has not been killed or relaunched. Run bin/fm-quota-reroute.sh suggest, then launch a successor on the named pick manually. Its captain record is $O_HOME/state/watchdog/captain and the ledger is $LEDGER."
  out=$(FM_HOME=$O_HOME FM_STATE_OVERRIDE=$O_HOME/state FM_CONFIG_OVERRIDE=$O_HOME/config \
    fm_run_timed 60 bash "$SCRIPT_DIR/fm-supervise-daemon.sh" page "$summary" "$LEDGER" 2>/dev/null)
  rc=$?
  case "$rc:$out" in
    '0:page: sent') wd_rec "$id" usage-limit-autowait page "done" "owner paged" ;;
    2:*)
      wd_rec "$id" usage-limit-autowait page refused "alerts are off or no alert channel is configured"
      wd_gap "usage-limit auto-wait on $O_TAG not paged: alerts are off or no alert channel is configured" ;;
    *)
      wd_rec "$id" usage-limit-autowait page failed "no alert channel delivered the page (exit $rc)"
      wd_gap "usage-limit auto-wait page failed on every alert channel for $O_TAG" ;;
  esac
}

wd_handle_captain_autowait() {
  wd_gap "usage-limit auto-wait on $O_TAG; the primary takes no turns until the reset. The watchdog does not kill or relaunch the primary. Run bin/fm-quota-reroute.sh suggest, then launch a successor on the named pick manually."
  wd_page_captain_autowait
  wd_quota_guard_warning
}

# Aged open decisions get one rolled-up nudge per window; once that nudge has
# had a full window, the oldest decision without a recent council gets one.
wd_handle_decisions() {
  local st=$O_HOME/state now task key verb age summary secs res aged=0 keys='' id cap ran=0 nudged held=0 held_keys=''
  local oversized=0 refused_at
  local rec split=0 split_keys='' ruled=0 ruled_keys='' WD_NUDGE_MODE

  WD_NUDGE_MODE=$(wd_decisions_mode)
  now=$(wd_now)
  secs=$(cfgi decision-secs 1800)
  cap=$(cfgi council-per-pass 1)
  wd_open_decisions "$st" "$now" 2>/dev/null | sort -t "$(printf '\t')" -k4,4nr > "$WD/.decisions"
  : > "$WD/.decisions-aged"
  while IFS=$'\t' read -r task key verb age summary; do
    [ -n "$key" ] || continue
    [ "$age" -ge "$secs" ] || continue
    if wd_decision_reserved "$task" "$key" "$summary"; then
      held=$((held + 1))
      [ "$held" -gt 3 ] || fm_secret_like "$task/$key" || held_keys="$held_keys${held_keys:+, }$task/$key"
      continue
    fi
    if [ "${#summary}" -gt "$WD_COUNCIL_MAX_CHARS" ]; then
      oversized=$((oversized + 1))
      refused_at=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" "decision:$key" council '^refused$')
      if [ -z "$refused_at" ] || [ $((now - refused_at)) -ge "$(cfgi council-secs 21600)" ]; then
        wd_rec "$(wd_id)" "decision:$key" council refused "record exceeds $WD_COUNCIL_MAX_CHARS characters"
      fi
      continue
    fi
    rec=$(wd_council_record "$task" "$key")
    case "$rec" in
      no-ruling*)
        split=$((split + 1))
        [ "$split" -gt 3 ] || split_keys="$split_keys${split_keys:+, }$task/$key"
        continue ;;
      ruled*)
        ruled=$((ruled + 1))
        [ "$ruled" -gt 3 ] || ruled_keys="$ruled_keys${ruled_keys:+, }$task/$key" ;;
    esac
    aged=$((aged + 1))
    [ "$aged" -gt 5 ] || keys="$keys${keys:+, }$task/$key"
    printf '%s\t%s\t%s\n' "$task" "$key" "$summary" >> "$WD/.decisions-aged"
  done < "$WD/.decisions"
  [ "$held" -eq 0 ] || wd_gap "$held decisions held for the owner (never touched)${held_keys:+, e.g. $held_keys}"
  [ "$split" -eq 0 ] || wd_gap "$split decisions held for the owner after a council gave no ruling (records under data/watchdog/no-rulings/), e.g. $split_keys"
  [ "$ruled" -eq 0 ] || wd_gap "$ruled open decisions have an unapplied council ruling (under data/watchdog/rulings/), e.g. $ruled_keys"
  [ "$oversized" -eq 0 ] || wd_gap "$oversized decisions refused: record exceeds $WD_COUNCIL_MAX_CHARS characters"
  [ "$aged" -gt 0 ] || return 0
  [ "$O_TURN" = 1 ] && return 0
  nudged=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" decisions nudge '^(pending|dry-run)$')
  if [ -z "$nudged" ] || [ $((now - nudged)) -ge $((3 * secs)) ]; then
    wd_nudge decisions "$aged open decisions have waited over $((secs / 60)) minutes, oldest first: $keys. Answer each, or settle it by council per the captain rules, and record the answer with fm-send --resolve-key."
    return 0
  fi
  [ $((now - nudged)) -ge "$secs" ] || return 0
  while IFS=$'\t' read -r task key summary; do
    [ "$ran" -lt "$cap" ] || break
    if [ "${#summary}" -gt "$WD_COUNCIL_MAX_CHARS" ]; then
      wd_gap "council refused: record exceeds $WD_COUNCIL_MAX_CHARS characters"
      continue
    fi
    [ -z "$(wd_council_record "$task" "$key")" ] || continue
    fm_wd_rate_ok "$LEDGER" "$O_HOME" "decision:$key" council "$(cfgi council-secs 21600)" "$now" || continue
    ran=$((ran + 1))
    id=$(wd_id)
    if [ "$WD_NUDGE_MODE" != act ]; then wd_rec "$id" "decision:$key" council dry-run "would convene council on $task $key"; continue; fi
    wd_rec "$id" "decision:$key" council pending "$task $key"
    res=$(wd_council "$task" "$key" "$summary")
    wd_council_ledger "$id" "$task" "$key" "$res"
    case "$res" in
      unanimous*)
        wd_nudge "ruling:$key" "a unanimous blind council ruled $(printf '%s' "$res" | cut -f2) on decision $key from $task. Ruling file: $(printf '%s' "$res" | cut -f3). Apply it with fm-send --resolve-key if it stands, or record why not." ;;
      no-ruling*) wd_gap "council gave no ruling on $task $key; held for the owner, record $(printf '%s' "$res" | cut -f3)" ;;
      refused*) wd_gap "no council on $task $key: $(printf '%s' "$res" | cut -f4); held" ;;
      busy*) ;;
      *) wd_gap "council did not publish a final record on $task $key; held" ;;
    esac
  done < "$WD/.decisions-aged"
}

# Snapshot once and name a quota-eligible pick. Never relaunches. The
# supervisor runs fm-control relaunch after a stale wake that names this pick.
# A secondmate's meta lives in the parent home's state, not in O_HOME.
# The Claude config dir comes from the task's account pin, never from
# claude-config-dirs.
wd_quota_meta() {  # [task-id]
  local task=${1-}
  if [ -n "$task" ] && [ -f "$O_HOME/state/$task.meta" ]; then
    printf '%s\n' "$O_HOME/state/$task.meta"
    return 0
  fi
  if [ "${O_PARENT:-}" != - ] && [ -n "${O_ID:-}" ] && [ "$O_ID" != - ] \
     && [ -f "$O_PARENT/state/$O_ID.meta" ]; then
    printf '%s\n' "$O_PARENT/state/$O_ID.meta"
    return 0
  fi
  if [ -n "${O_ID:-}" ] && [ "$O_ID" != - ] && [ -f "$O_HOME/state/$O_ID.meta" ]; then
    printf '%s\n' "$O_HOME/state/$O_ID.meta"
    return 0
  fi
  return 1
}

wd_quota_pick() {  # [task-id]
  local cands cand snapshot pick harness kind model wt mate meta task=${1-} judge reason rec_home
  rm -f "$WD/.quota-none-reason"
  cands=$(cfg reroute-candidates "")
  [ -n "$cands" ] || { printf 'none\n'; return 1; }
  snapshot=$WD/quota-snapshot.txt
  if [ -f "$WD/quota-snapshot.failed" ]; then
    printf 'none\n'; return 1
  fi
  if [ ! -s "$snapshot" ]; then
    if ! command -v quota-axi >/dev/null 2>&1; then
      printf 'none\n'; return 1
    fi
    if ! fm_run_timed 60 quota-axi > "$snapshot" 2>/dev/null; then
      rm -f "$snapshot"
      : > "$WD/quota-snapshot.failed"
      printf 'none\n'; return 1
    fi
  fi
  [ -s "$snapshot" ] || { printf 'none\n'; return 1; }
  harness=
  kind=ship
  model=
  wt=
  mate=
  judge=$task
  if [ -z "$judge" ] && [ -n "${O_ID:-}" ] && [ "$O_ID" != - ]; then
    judge=$O_ID
  fi
  rec_home=$O_HOME
  if meta=$(wd_quota_meta "$judge"); then
    rec_home=${meta%/state/*}
    harness=$(fm_meta_get "$meta" harness 2>/dev/null) || harness=
    kind=$(fm_meta_get "$meta" kind 2>/dev/null) || kind=ship
    model=$(fm_meta_get "$meta" model 2>/dev/null) || model=
    wt=$(fm_meta_get "$meta" worktree 2>/dev/null) || wt=
    [ -n "$wt" ] || wt=$(fm_meta_get "$meta" home 2>/dev/null) || wt=
  elif [ "${O_PARENT:-}" != - ] && [ -n "${O_ID:-}" ] && [ "$O_ID" != - ]; then
    kind=secondmate
  fi
  if [ -z "$harness" ]; then
    printf '%s\n' "Unknown harness" > "$WD/.quota-none-reason"
    printf 'none\n'
    return 1
  fi
  if [ "$harness" = claude ] && [ "$kind" = secondmate ] && [ -n "$judge" ] && [ "$judge" != - ]; then
    mate=$judge
  fi
  set -- suggest --snapshot "$snapshot"
  set -- "$@" --from-harness "$harness"
  [ -z "$model" ] || set -- "$@" --from-model "$model"
  [ -z "$kind" ] || set -- "$@" --kind "$kind"
  [ -z "$wt" ] || set -- "$@" --worktree "$wt"
  [ -z "$mate" ] || set -- "$@" --mate "$mate"
  for cand in $(printf '%s' "$cands" | tr ',' ' '); do set -- "$@" --candidate "$cand"; done
  pick=$(FM_HOME=$rec_home FM_CONFIG_OVERRIDE=$rec_home/config \
    "$SCRIPT_DIR/fm-quota-reroute.sh" "$@" 2>"$WD/.quota-none-stderr") || pick=none
  [ -n "$pick" ] || pick=none
  if [ "$pick" = none ]; then
    reason=$(awk 'sub(/^error: /, "") { print; exit }' "$WD/.quota-none-stderr" 2>/dev/null || true)
    [ -z "$reason" ] || printf '%s\n' "$reason" > "$WD/.quota-none-reason"
  fi
  rm -f "$WD/.quota-none-stderr"
  printf '%s\n' "$pick"
  [ "$pick" != none ]
}

wd_quota_none_reason() {
  cat "$WD/.quota-none-reason" 2>/dev/null || printf '%s\n' "No eligible reroute candidate"
}

wd_quota_relaunch_closes() {
  local name screen=
  # Same viewport as the dialog. Scrollback can still hold a dismissed Grok frame.
  [ -n "${O_BACKEND:-}" ] && [ -n "${O_TARGET:-}" ] || return 1
  screen=$(wd_view "$O_BACKEND" "$O_TARGET") || return 1
  [ -n "$screen" ] || return 1
  name=$(fm_composer_blocking_dialog "$screen" 2>/dev/null) || name=
  [ "$name" = 'Grok weekly-limit choice' ]
}

wd_quota_name_pick() {  # <id> <subject> [task-id]
  local pick reason
  pick=$(wd_quota_pick "${3-}") || pick=none
  if [ -n "$pick" ] && [ "$pick" != none ]; then
    if wd_quota_relaunch_closes; then
      wd_rec "$1" quota suggest held "quota shows $pick eligible; supervisor relaunches, watchdog does not"
      wd_gap "usage-limit on $2. Suggested pick: $pick. Supervisor relaunches. The watchdog does not change the runtime."
    else
      wd_rec "$1" quota suggest held "quota shows $pick eligible; queued until reset"
      wd_gap "usage-limit on $2. Suggested pick: $pick. Queue until reset. Relaunch closes only a verified Grok weekly-limit composer. The watchdog does not change the runtime."
    fi
  else
    reason=$(wd_quota_none_reason)
    wd_rec "$1" quota suggest held "$reason; queued until reset"
    wd_gap "usage-limit on $2. $reason. Queue until reset; never pause in a poll loop."
  fi
}

wd_quota_name_pick_rated() {  # <id> <subject-label> [task-id]
  wd_quota_guard_warning "${3-}"
  if fm_wd_rate_ok "$LEDGER" "$O_HOME" quota suggest "$(cfgi nudge-secs 900)" "$(wd_now)" "${O_REC_SUBJECT:-$O_TAG}"; then
    wd_quota_name_pick "$1" "$2" "${3-}"
  else
    wd_gap "usage-limit on $2; next pick waits for nudge-secs"
  fi
}

wd_handle_quota() {
  local task age line pick
  wd_quota_floors "$O_HOME/state" "$(wd_now)" | while IFS=$'\t' read -r task age line; do
    [ "$age" -ge "$(cfgi quota-secs 600)" ] || continue
    pick=$(wd_quota_pick "$task") || pick=none
    if [ -n "$pick" ] && [ "$pick" != none ]; then
      wd_nudge "quota:$task" "task $task is parked at a quota floor. Suggested pick: $pick. Supervisor relaunches; the watchdog does not. Never pause or poll for quota."
    else
      wd_nudge "quota:$task" "task $task is parked at a quota floor. $(wd_quota_none_reason). Queue until reset; never pause or poll for quota."
    fi
  done
}

# --- quota guard (bin/fm-quota-guard.sh) -------------------------------------

wd_quota_guard_on() { [ "$(cfg quota-guard on)" != off ]; }

# wd_quota_guard <home> <command> [args...]: one bounded guard call for that
# home with this watchdog's config and candidates. Sets WD_QG_LINE to the
# result line it printed, if any, and returns its exit status.
wd_quota_guard() {
  local home=$1 cand out rc=0
  shift
  for cand in $(cfg reroute-candidates "" | tr ',' ' '); do set -- "$@" --candidate "$cand"; done
  out=$(fm_run_timed "$(cfgi quota-guard-timeout-secs 300)" env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$home" FM_QUOTA_GUARD_CONF="$CONF" FM_NOW="$(wd_now)" \
    "$SCRIPT_DIR/fm-quota-guard.sh" "$@" 2>/dev/null </dev/null) || rc=$?
  WD_QG_LINE=$(printf '%s\n' "$out" | sed -n '1{/^quota-guard: /p;}')
  return "$rc"
}

# wd_primary_account: the Claude account root that holds the primary's
# transcript, or ordinary for ~/.claude; fails when no transcript was read.
wd_primary_account() {
  local root
  [ -n "$O_TRANSCRIPT" ] || return 1
  root=${O_TRANSCRIPT%/projects/*}
  [ -n "$root" ] && [ "$root" != "$O_TRANSCRIPT" ] || return 1
  if [ "$(cd -P -- "$root" 2>/dev/null && pwd -P)" = "$(cd -P -- "${HOME:-}/.claude" 2>/dev/null && pwd -P)" ]; then
    printf 'ordinary\n'
  else
    printf '%s\n' "$root"
  fi
}

# wd_quota_guard_nudged_since <epoch>: 0 when a quota-guard nudge to this
# subject was delivered or recorded as a dry run at or after that time. A nudge
# whose record or submit failed does not count; one that only saw no transcript
# progress afterward was delivered.
wd_quota_guard_nudged_since() {
  [ -f "$LEDGER" ] || return 1
  awk -F'\t' -v h="$O_HOME" -v subj="${O_REC_SUBJECT:-$O_TAG}" -v at="$1" '
    $3 == h && $4 == subj && $5 == "quota-guard" && $6 == "nudge" {
      if (($7 == "pending" || $7 == "dry-run") && $1 + 0 >= at + 0) ok[$2] = 1
      else if ($7 == "failed" && $8 !~ /no transcript progress/) delete ok[$2]
    }
    END { for (id in ok) exit 0; exit 1 }' "$LEDGER"
}

# wd_quota_guard_nudge_text <result-line>: the nudge for a check that named
# moves. A worker moves on its named pick, while a supervisor goes through
# bin/fm-supervisor-failover.sh, which owns the verified handoff and makes its
# own choice among the comparable models the captain declared. A count the
# line does not carry names both ways.
wd_quota_guard_nudge_text() {
  local result=$1 text steer fail qhome
  steer=$(printf '%s\n' "$result" | sed -n 's/.* steer=\([0-9][0-9]*\).*/\1/p')
  fail=$(printf '%s\n' "$result" | sed -n 's/.* failover=\([0-9][0-9]*\).*/\1/p')
  qhome=$(printf '%q' "$O_HOME")
  text="$result. The moves are in $O_HOME/state/quota-guard/report.txt."
  [ "$steer" = 0 ] || text="$text Move each steered worker with bin/fm-control.sh relaunch on its named pick."
  [ "$fail" = 0 ] || text="$text Fail each supervisor over with bin/fm-supervisor-failover.sh, which chooses from config/supervisor-failover-candidates: for the primary, write a handoff document and run bin/fm-supervisor-failover.sh primary <handoff-file> --reason quota_guard in the background; for a second mate, run FM_HOME=$qhome bin/fm-supervisor-failover.sh secondmate <id> --reason quota_guard."
  printf '%s Never change an account pin, sign in, or spend.\n' "$text"
}

# wd_quota_guard_pass: a primary home's kickoff and periodic quota check, then
# the standing verdict of its last check as a gap while it is not ok. A check
# that named moves, whichever pass or warning ran it, nudges a live primary
# until one nudge after that check is delivered or recorded as a dry run.
wd_quota_guard_pass() {
  local rc=0 rec=$O_HOME/state/quota-guard/last acct at
  wd_quota_guard_on || return 0
  set -- tick
  # Only a live primary is named, so a dead one is never kept as a supervisor.
  if [ "$O_ALIVE" = 1 ]; then
    [ -z "$O_HARNESS" ] || set -- "$@" --primary-harness "$O_HARNESS"
    if acct=$(wd_primary_account); then set -- "$@" --primary-account "$acct"; fi
  fi
  wd_quota_guard "$O_HOME" "$@" || rc=$?
  # A check that printed its result but could not save it is still a failure.
  if [ -n "$WD_QG_LINE" ] && { [ "$rc" = 0 ] || [ "$rc" = 3 ]; }; then
    wd_rec "$(wd_id)" quota-guard check "done" "$WD_QG_LINE"
  elif [ "$rc" != 0 ]; then
    wd_gap "quota guard check failed (exit $rc)"
  fi
  case "$(fm_wd_conf_get "$rec" verdict '')" in
    act|unknown) wd_gap "$(fm_wd_conf_get "$rec" result '') (checked $(fm_wd_iso "$(fm_wd_conf_get "$rec" at 0)"))" ;;
  esac
  at=$(fm_wd_conf_get "$rec" at '' | tr -cd '0-9')
  # The check can run long, so the owner observed before it must still hold the
  # lock and be live before a nudge is sent.
  if [ "$(fm_wd_conf_get "$rec" verdict '')" = act ] && [ -n "$at" ] && [ "$O_ALIVE" = 1 ] &&
     [ "$WD_RESTARTED" != 1 ] && [ "$WD_SYMPTOM" != usage-limit-autowait ] &&
     wd_same_live_owner "$O_HOME/state"; then
    if ! wd_quota_guard_nudged_since "$at"; then
      wd_nudge quota-guard "$(wd_quota_guard_nudge_text "$(fm_wd_conf_get "$rec" result '')")"
    fi
  fi
}

# wd_quota_guard_warning [task-id]: records the limit dialog this pass saw on
# the subject or its worker, once per nudge-secs, and unless quota-guard=off
# checks quota now. A second mate's dialog is recorded in its parent home. Only
# a recorded dialog starts the window, so a failed record is tried again on the
# next pass; a check that fails after the record is a gap, not a failed record.
wd_quota_guard_warning() {
  local task=${1-} home=$O_HOME subject rc=0 last acct=''
  last=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" quota-guard warning '^done$' "${O_REC_SUBJECT:-$O_TAG}")
  [ -z "$last" ] || [ $(( $(wd_now) - last )) -ge "$(cfgi nudge-secs 900)" ] || return 0
  if [ "${O_PARENT:-}" != - ] && [ -n "${O_ID:-}" ] && [ "$O_ID" != - ]; then
    home=$O_PARENT
    if [ -n "$task" ]; then subject=$O_ID/$task; else subject=$O_ID; fi
  elif [ -n "$task" ]; then subject=$task
  else subject=primary
  fi
  set -- record-dialog --subject "$subject"
  [ "${O_PARENT:-}" != - ] || acct=$(wd_primary_account) || acct=''
  if [ "$subject" = primary ] && [ -n "${O_HARNESS:-}" ]; then set -- "$@" --harness "$O_HARNESS"; fi
  if [ "$subject" = primary ] && [ -n "$acct" ]; then set -- "$@" --account "$acct"; fi
  wd_quota_guard "$home" "$@" || rc=$?
  if [ "$rc" != 0 ]; then
    wd_rec "$(wd_id)" quota-guard warning failed "limit dialog on $subject not recorded (exit $rc)"
    wd_gap "limit dialog on $subject not recorded (exit $rc)"
    return 0
  fi
  # A home whose restart awaits pickup gets no check; its dialog is still
  # recorded. A second mate's warning checks its parent, so the parent's hold
  # is the one that counts.
  if ! wd_quota_guard_on || wd_home_awaits_restart "$home"; then
    wd_rec "$(wd_id)" quota-guard warning "done" "limit dialog on $subject recorded"
    return 0
  fi
  set -- check --trigger warning
  # Only a live primary is named, so a dead one is never kept as a supervisor.
  if [ "$home" = "$O_HOME" ] && [ "${O_PARENT:-}" = - ] && [ "${O_ALIVE:-0}" = 1 ]; then
    [ -z "${O_HARNESS:-}" ] || set -- "$@" --primary-harness "$O_HARNESS"
    [ -z "$acct" ] || set -- "$@" --primary-account "$acct"
  fi
  rc=0
  wd_quota_guard "$home" "$@" || rc=$?
  case "$rc" in 0|3) ;; *) WD_QG_LINE= ;; esac
  wd_rec "$(wd_id)" quota-guard warning "done" "limit dialog on $subject recorded${WD_QG_LINE:+; $WD_QG_LINE}"
  case "$rc" in
    0) ;;
    3) [ -z "$WD_QG_LINE" ] || wd_gap "$WD_QG_LINE" ;;
    *) wd_gap "quota guard check after the limit dialog on $subject failed (exit $rc)" ;;
  esac
}
wd_unsent_is_stable() {
  [ "$O_COMPOSER" = pending ] && [ "$O_PREV_COMPOSER" = pending ] && [ "$O_SIG" = "$O_PREV_SIG" ] && [ "$O_TURN" = 0 ]
}

wd_enter_spent() {
  [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" pasted-input key '^pending$' "$(( $(wd_now) - 7200 ))")" -gt 0 ]
}

# One Enter per two hours, only for a whole, readable draft that names no merge,
# deploy, or release word; returns 1 when this draft cannot take Enter now.
wd_draft_allowed() {
  fm_wd_text_allowed "$(fm_wd_prompt_tail "$O_COMPOSER_TEXT")"
}

wd_submit_unsent() {
  if ! wd_draft_allowed; then
    wd_gap "unsent draft names a merge, deploy, or release word; Enter not pressed"
    wd_rate_open pasted-input key "$(cfgi enter-secs 300)" &&
      wd_rec "$(wd_id)" pasted-input key refused "the draft names a merge, deploy, or release word; never accepted"
    return 1
  elif ! fm_wd_draft_readable "$O_COMPOSER_TEXT" "$O_COMPOSER_ABOVE"; then
    wd_gap "unsent input is a paste placeholder, or its whole draft boundary is not proven (plain, indented, left-bar, and titled composers are unsupported); Enter not pressed"
    wd_rate_open pasted-input key "$(cfgi enter-secs 300)" &&
      wd_rec "$(wd_id)" pasted-input key refused "the whole draft cannot be read; never accepted"
    return 1
  elif wd_enter_spent; then
    wd_gap "unsent input is still there after Enter; no second Enter inside two hours"
    return 1
  fi
  wd_rate_open pasted-input key "$(cfgi enter-secs 300)" && wd_key pasted-input Enter "submit text left unsent"
  return 0
}

# Low context asks for a restart: context left at or below restart-at-percent,
# unless the session's published reset is compaction (compaction-first: the
# Claude trigger's capture step, not a handoff, serves that cycle).
wd_low_context() {
  [ -n "$O_CTX" ] && [ "$O_CTX" -le "$(cfgi restart-at-percent 8)" ] && [ "$O_CTX_RESET" != compaction ]
}

# A low-context ask with no delivered nudge that no later pass can deliver either.
wd_handoff_undeliverable() {
  [ "$O_RESTART_REQ" != 1 ] && [ -z "$(wd_handoff_nudge_epoch)" ] || return 1
  case "$O_COMPOSER" in
    empty) return 1 ;;
    pending) fm_wd_draft_readable "$O_COMPOSER_TEXT" "$O_COMPOSER_ABOVE" && wd_draft_allowed && ! wd_enter_spent && return 1 ;;
  esac
  wd_gap "low context, but composer is $O_COMPOSER, so the handoff nudge cannot be delivered"
  return 0
}

# Prints the epoch of the handoff nudge that counts for this low-context episode:
# delivered, newer than the last restart, and younger than twice handoff-wait-secs.
wd_handoff_nudge_epoch() {
  local e last_r
  e=$(awk -F'\t' -v h="$O_HOME" '$3 == h && $5 == "handoff-request" && $6 == "nudge" {
      if ($7 ~ /^(pending|dry-run)$/) { id = $2; e = $1 }
      else if ($7 == "failed" && $2 == id && $8 !~ /no transcript progress/) e = ""
    } END { print e }' "$LEDGER" 2>/dev/null)
  last_r=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" '*' restart '^pending$')
  [ -n "$e" ] && [ "$e" -ge "${last_r:-0}" ] && [ $(($(wd_now) - e)) -lt $((2 * $(cfgi handoff-wait-secs 600))) ] && printf '%s\n' "$e"
  return 0
}

# Low context first asks for a full handoff and a request file; a nudge that gets
# neither within handoff-wait-secs falls back to the lean handoff.
wd_requested_restart() {  # <quiet-secs>
  local quiet=$1 now nudged wait latest timed_out
  now=$(wd_now)
  wait=$(cfgi handoff-wait-secs 600)
  nudged=$(wd_handoff_nudge_epoch)
  if [ -z "$nudged" ] && [ "$O_RESTART_REQ" != 1 ]; then
    if wd_unsent_is_stable; then wd_submit_unsent; return 0; fi
    wd_nudge handoff-request "context is low (${O_CTX_READING:-reading unknown}). Write a full handoff to data/handoff-<name>.md in your home, then create state/.watchdog-restart-request there. The watchdog then restarts this session, and the new session picks up from that handoff."
    [ -n "$(wd_handoff_nudge_epoch)" ] || wd_gap "low context (${O_CTX_READING:-reading unknown}); the handoff nudge was not delivered; no restart yet"
    return 0
  fi
  if [ -n "$nudged" ]; then
    latest=$(wd_newest_session_handoff)
    if [ "$O_RESTART_REQ" != 1 ] || [ -z "$latest" ] || [ "$(wd_mtime "$latest")" -le "$nudged" ]; then
      if [ $((now - nudged)) -lt "$wait" ]; then
        wd_gap "low context; waiting up to ${wait}s for a full handoff and a restart request"
        return 0
      fi
      timed_out=$(fm_wd_last_epoch "$LEDGER" "$O_HOME" handoff-request nudge '^timed-out$')
      [ "${timed_out:-0}" -ge "$nudged" ] || wd_rec "$(wd_id)" handoff-request nudge timed-out "no full handoff and request within ${wait}s"
      wd_gap "no full handoff within ${wait}s; the restart uses the lean handoff"
    fi
  fi
  if [ "$O_ACT_AGE" != unknown ] && [ "$O_ACT_AGE" -ge "$quiet" ]; then
    wd_restart restart-requested filesystem records
  else
    wd_gap "restart requested; waiting for ${quiet}s of quiet"
  fi
}

# wd_near_loop_confirmed: true only on a LOOP answer. An answer stands for
# owed-input-secs, and after that for as long as the evidence stays the same.
wd_near_loop_confirmed() {
  local f=$WD/near-loop/$O_KEY at='' sum='' ans='' evidence new now
  evidence=$(printf '%s\n' "$O_EVENTS" | fm_wd_loop_evidence "$(( $(cfgi judge-max-chars 6000) - 200 ))")
  if fm_secret_like "$evidence" || fm_wd_reserved "$evidence"; then
    wd_gap "possible loop; its evidence is withheld from the judge, so it stays unconfirmed"
    return 1
  fi
  new=$(printf '%s' "$evidence" | cksum | cut -d ' ' -f 1)
  now=$(wd_now)
  if [ -f "$f" ]; then IFS=$'\t' read -r at sum ans < "$f" || true; fi
  if [ -z "$at" ] || { [ $((now - at)) -ge "$(cfgi owed-input-secs 900)" ] && { [ "$sum" != "$new" ] || [ -z "$ans" ]; }; }; then
    ans=$(wd_judge loop '(LOOP|WORK)' "Recent events from a supervisor agent, newest last. Does it repeat itself without doing new work (LOOP), or is it doing real work (WORK)? Reply with exactly one word.
$evidence") || ans=''
    mkdir -p "$WD/near-loop"
    printf '%s\t%s\t%s\n' "$now" "$new" "$ans" > "$f"
  fi
  [ -n "$ans" ] || wd_gap "possible loop; no judge answer, so it stays unconfirmed"
  [ "$ans" = LOOP ]
}

# Ship and scout task records. Prints task-id TAB meta path. Other kinds, including
# a second mate record in the same directory, are not worker panes.
wd_worker_metas() {  # <home>
  local f id kind
  [ -d "$1/state" ] || return 0
  for f in "$1"/state/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=$(basename "$f" .meta)
    case "$id" in
      ''|.*|*[!A-Za-z0-9._-]*) continue ;;
    esac
    kind=$(fm_meta_get "$f" kind)
    case "$kind" in
      ship|scout) printf '%s\t%s\n' "$id" "$f" ;;
    esac
  done
}

# Read each recorded worker pane with the home dialog detector.
# mode=page dismisses a known feedback or bug-report dialog, routes a
# permission, trust, or sign-in prompt through wd_permission_prompt, pages a
# permission dialog that still waits through wd_page_permission, and
# names a usage-limit pick. Escape on a proven tool-approval prompt is its only
# other key. mode=print reports the read and does not act. A gone endpoint is
# not a dialog.
wd_visit_worker_dialogs() {
  local mode=$1 id meta backend target harness screen dialog mismatch prompt
  local saved_pane saved_dialog_pane saved_backend saved_target saved_harness saved_dialog saved_id
  local saved_composer saved_composer_text saved_composer_above saved_draft
  saved_pane=$O_PANE
  saved_dialog_pane=${O_DIALOG_PANE:-}
  saved_backend=$O_BACKEND
  saved_target=$O_TARGET
  saved_harness=${O_HARNESS:-}
  saved_dialog=$O_DIALOG
  saved_id=${O_ID:-}
  saved_composer=${O_COMPOSER:-}
  saved_composer_text=${O_COMPOSER_TEXT:-}
  saved_composer_above=${O_COMPOSER_ABOVE:-}
  saved_draft=${O_DRAFT:-}
  while IFS=$'\t' read -r id meta; do
    [ -n "$id" ] || continue
    # A stop reason belongs to one worker's pass, including its page, never
    # to the next pane.
    WD_PP_REASON=
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    harness=$(fm_meta_get "$meta" harness 2>/dev/null) || harness=
    if [ -z "$backend" ] || [ -z "$target" ]; then
      [ "$mode" = print ] && printf '  worker %s endpoint=none dialog=none\n' "$id"
      continue
    fi
    # The home pane is already on the home path. Reading it again would page twice.
    if [ -n "$saved_target" ] && [ "$backend" = "$saved_backend" ] && [ "$target" = "$saved_target" ]; then
      continue
    fi
    if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
      # A herdr server that refuses every client looks like a gone pane; say so.
      mismatch=''
      if [ "$backend" = herdr ]; then
        mismatch=$(fm_run_timed_fn "$(cfgi call-timeout-secs 20)" wd_herdr_mismatch "$target" 2>/dev/null) || mismatch=''
      fi
      if [ "$mode" = print ]; then
        if [ -n "$mismatch" ]; then
          printf '  worker %s endpoint=%s:%s dialog=unknown\n' "$id" "$backend" "$target"
          printf '    %s\n' "$mismatch"
        else
          printf '  worker %s endpoint=%s:%s dialog=gone\n' "$id" "$backend" "$target"
        fi
      elif [ -n "$mismatch" ]; then
        wd_gap "worker $id pane could not be read: $mismatch"
      else
        wd_gap "worker $id endpoint is gone; its pane is not read"
      fi
      continue
    fi
    screen=$(wd_capture "$backend" "$target" 60) || screen=''
    dialog=$(wd_observe_dialog "$backend" "$target" "fm-$id" "${harness:-unknown}") || dialog=''
    if [ "$mode" = print ]; then
      printf '  worker %s endpoint=%s:%s dialog=%s\n' "$id" "$backend" "$target" "${dialog:-none}"
      continue
    fi
    wd_rearm_feedback_dialog "$backend" "$target" "${harness:-unknown}" "$screen" "fm-$id"
    if [ -z "$dialog" ] && fm_wd_usage_limit_autowait "$screen"; then
      O_REC_SUBJECT="worker:$id"
      wd_quota_guard_warning "$id"
      unset O_REC_SUBJECT
    fi
    prompt=2
    case "$dialog" in
      permission|question|usage-limit|model-switch|'')
        if [ -n "$screen" ]; then
          O_BACKEND=$backend
          O_TARGET=$target
          O_REC_SUBJECT="worker:$id"
          wd_permission_prompt "$id" "$harness" "$screen" "${dialog:-none}"
          prompt=$?
          unset O_REC_SUBJECT
        fi
        ;;
    esac
    # A held prompt or hard stop on a screen the dialog reader did not label
    # permission, such as a Codex dialog or a declining picker, still gets
    # the waiting gap and the away page. A decline that only waits for its
    # next pass, with no blocked line, does not.
    if [ "$prompt" = 1 ] && [ "$dialog" != permission ] && [ -n "${WD_PP_STOPPED:-}" ]; then
      O_BACKEND=$backend
      O_TARGET=$target
      O_PANE=$screen
      O_DIALOG=permission
      O_REC_SUBJECT="worker:$id"
      wd_gap "permission prompt waiting on worker $id; the watchdog does not answer it"
      wd_page_permission
      O_DIALOG=$saved_dialog
      unset O_REC_SUBJECT
    fi
    case "$dialog" in
      feedback)
        O_BACKEND=$backend
        O_TARGET=$target
        O_HARNESS=${harness:-unknown}
        O_PANE=$screen
        O_DIALOG_PANE=$(wd_view "$backend" "$target" "fm-$id") || O_DIALOG_PANE=$screen
        O_DIALOG=$dialog
        O_ID=$id
        O_REC_SUBJECT="worker:$id"
        wd_handle_dialog || true
        O_ID=$saved_id
        O_HARNESS=$saved_harness
        unset O_REC_SUBJECT
        ;;
      permission)
        O_BACKEND=$backend
        O_TARGET=$target
        O_PANE=$screen
        O_DIALOG=$dialog
        O_REC_SUBJECT="worker:$id"
        if [ "$prompt" != 0 ]; then
          wd_gap "permission dialog waiting on worker $id; the watchdog does not select an answer, and this one was neither declined nor relaunched"
          wd_page_permission
        fi
        unset O_REC_SUBJECT
        ;;
      usage-limit)
        O_BACKEND=$backend
        O_TARGET=$target
        O_PANE=$screen
        O_DIALOG=$dialog
        O_REC_SUBJECT="worker:$id"
        wd_quota_name_pick_rated "$(wd_id)" "worker $id" "$id"
        unset O_REC_SUBJECT
        ;;
    esac
  done < <(wd_worker_metas "$O_HOME")
  O_PANE=$saved_pane
  O_DIALOG_PANE=$saved_dialog_pane
  O_BACKEND=$saved_backend
  O_TARGET=$saved_target
  O_HARNESS=$saved_harness
  O_DIALOG=$saved_dialog
  O_ID=$saved_id
  O_COMPOSER=$saved_composer
  O_COMPOSER_TEXT=$saved_composer_text
  O_COMPOSER_ABOVE=$saved_composer_above
  O_DRAFT=$saved_draft
  unset O_REC_SUBJECT WD_PP_REASON
}

# wd_home_awaits_restart <home>: a restart of that home is still pending pickup.
wd_home_awaits_restart() {
  fm_wd_open_pending "$LEDGER" | awk -F'\t' -v h="$1" '$2 == h && $4 == "restart" { f = 1 } END { exit !f }'
}

# wd_handle_subject: one symptom per pass, by precedence, then the side checks.
wd_handle_subject() {
  local symptom='' quiet frozen owed dead=0 reachable=1
  wd_rearm_feedback_dialog "$O_BACKEND" "$O_TARGET" "${O_HARNESS:-}" "$O_PANE"
  if wd_home_awaits_restart "$O_HOME"; then
    WD_SYMPTOM='restart-awaiting-pickup'
    return 0
  fi
  frozen=$(cfgi frozen-secs 900)
  owed=$(cfgi owed-input-secs 900)
  quiet=$(cfgi restart-quiet-secs 120)
  if [ -n "$O_LOCK_PID" ] && [ "$O_ALIVE" = 0 ]; then dead=1; fi
  if [ "$O_DIALOG" = unknown ]; then
    wd_gap "the visible pane could not be read; dialog unknown"
  fi
  [ -z "$O_HERDR_MISMATCH" ] || wd_gap "$O_HERDR_MISMATCH"
  if [ "$dead" = 1 ]; then
    symptom='agent-gone'
    if [ "$O_ACT_AGE" != unknown ] && [ "$O_ACT_AGE" -ge "$frozen" ]; then
      O_TURN=0 O_CPU_BUSY=0 wd_restart agent-gone kernel filesystem
    else
      wd_gap "lock holder is dead; restart needs ${frozen}s of activity quiet; nothing typed"
    fi
  elif [ "$O_PARENT" = - ] && [ "$O_AUTOWAIT" = 1 ]; then
    symptom='usage-limit-autowait'
    wd_handle_captain_autowait
  elif [ "$O_PARENT" != - ] && [ "$O_LIMIT_FOOTER" = 1 ]; then
    # A second mate on the auto-wait takes no turn until the reset either, so
    # nothing is typed into it; its footer is a limit warning, not a page.
    symptom='usage-limit-autowait'
    wd_quota_guard_warning
  elif [ -n "$O_DIALOG" ] && [ "$O_DIALOG" != unknown ]; then
    symptom=dialog
    wd_handle_dialog
  elif { [ "$O_RESTART_REQ" = 1 ] || wd_low_context; } && wd_restart_available && ! wd_handoff_undeliverable; then
    symptom='restart-requested'
    wd_requested_restart "$quiet"
  elif { [ "$O_LOOP" = rapid ] && [ "$O_TR_AGE" != unknown ] && [ "$O_TR_AGE" -le "$(cfgi rapid-loop-secs 180)" ]; } \
       || { { [ "$O_LOOP" = loop ] || [ "$O_LOOP" = rapid ]; } && [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ]; }; then
    symptom='timer-loop'
    wd_ladder_nudge_then_restart timer-loop "your last $O_LOOP_N replies repeat the same text with no work between them. Stop re-arming, drain the wake queue, and act on what it shows." filesystem records
  elif [ "$O_LOOP" = near ] && [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ] && wd_near_loop_confirmed; then
    symptom='timer-loop'
    wd_ladder_nudge_then_restart timer-loop "your recent replies repeat without new work while input waits. Stop re-arming, drain the wake queue, and act on it." filesystem records
  elif [ "$O_PANE_STATIC" -ge "$frozen" ] && [ "$O_ACT_AGE" != unknown ] && [ "$O_ACT_AGE" -ge "$frozen" ] \
       && [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$frozen" ]; then
    symptom=frozen
    if [ "$O_TURN" = 1 ]; then
      wd_gap "pane and activity static $((O_PANE_STATIC / 60))m during a running turn; treated as busy"
    else
      wd_ladder_nudge_then_restart frozen "nothing changed for $((O_PANE_STATIC / 60)) minutes while $O_OWED_N inputs wait. Drain the wake queue and act on it." rendered filesystem kernel
    fi
  elif wd_unsent_is_stable; then
    symptom='pasted-input'
    wd_submit_unsent
  elif [ "$O_OWED_N" -gt 0 ] && [ "$O_OWED_AGE" -ge "$owed" ] && [ "$O_TURN" != 1 ]; then
    symptom='unread-input'
    wd_nudge unread-input "$O_OWED_N inputs have waited $((O_OWED_AGE / 60)) minutes. Drain the wake queue and act on it."
  elif wd_heartbeat_frozen; then
    symptom='heartbeat-frozen'
    wd_handle_heartbeat_frozen
  fi
  # A restart this pass stopped the recorded session, so its old endpoint gets nothing more.
  if [ "$WD_RESTARTED" = 1 ]; then WD_SYMPTOM=$symptom; return 0; fi
  if [ "$dead" = 1 ] || [ "$symptom" = usage-limit-autowait ]; then reachable=0; fi
  if [ "$reachable" = 1 ] && [ "$O_AFK" = 1 ] && [ "$O_DAEMON" = 0 ]; then
    [ -n "$symptom" ] || symptom='daemon-dead'
    wd_nudge daemon-dead "away mode is on but the away daemon is not running. Re-arm it with bin/fm-afk-start.sh on this session's own terminal."
  fi
  if [ "$O_HB_AGE" != unknown ] && [ "$O_HB_AGE" -ge "$(cfgi watcher-stale-secs 900)" ]; then
    wd_gap "watcher heartbeat is $((O_HB_AGE / 60))m old"
  fi
  if [ "$reachable" = 1 ]; then
    [ "$O_TURN" = 1 ] || wd_handle_decisions
    wd_handle_quota
  fi
  # Recurrence: three real or would-be actions on one symptom in a day files an issue.
  if [ -n "$symptom" ] && [ "$symptom" != usage-limit-autowait ] && [ "$(fm_wd_count_since "$LEDGER" "$O_HOME" "$symptom" '*' '^(pending|dry-run)$' "$(( $(wd_now) - 86400 ))")" -ge 3 ]; then
    wd_self_heal "$symptom" "Watchdog: $symptom recurs on $O_TAG" "$symptom handled 3 or more times in 24h"
  fi
  WD_SYMPTOM=${symptom:-ok}
  if [ "$O_ACT_AGE" = unknown ]; then
    wd_gap "no activity source; frozen, dead-holder, and low-context restarts are unavailable"
    WD_SYMPTOM=${symptom:-no-activity-source}
  fi
  if [ -z "$O_BACKEND" ] || [ -z "$O_TARGET" ]; then
    wd_gap "no recorded terminal endpoint; the pane cannot be read or typed into"
    WD_SYMPTOM=${symptom:-no-endpoint}
  fi
}

# --- status file -------------------------------------------------------------------

wd_health_line() {
  local s=$WD_SYMPTOM idle='' captain='no lock holder' term='an unknown terminal'
  [ "$O_ACT_AGE" = unknown ] || idle=", last turn $((O_ACT_AGE / 60))m ago via $O_ACT_SRC"
  if [ -n "$O_LOCK_PID" ]; then
    [ -z "$C_TARGET" ] || term=$C_BACKEND:$C_TARGET
    captain="captain pid $O_LOCK_PID $O_OWNER on $term${C_MOVED:+, moved $(fm_wd_iso "$C_MOVED")}"
  fi
  case "$s" in
    ok) printf -- '- %s: ok%s, ctx %s; %s\n' "$O_TAG" "$idle" "${O_CTX:-unknown}${O_CTX:+%}" "$captain" ;;
    *) printf -- '- %s: %s%s, owed %s, ctx %s; %s\n' "$O_TAG" "$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')" "$idle" "$O_OWED_N" "${O_CTX:-unknown}${O_CTX:+%}" "$captain" ;;
  esac
}

wd_write_status() {  # <health-file> <gaps-file>
  local now interval read_at host tmp spent cap models m ok restart_word
  now=$(wd_now)
  interval=$(cfgi interval-secs 120)
  restart_word=$(cfg restart off)
  [ "$restart_word" = on ] && [ "$(cfg restart-scope all)" = second-mates ] && restart_word='on (second mates only)'
  read_at=$(head -n 1 "$WD/last-read" 2>/dev/null | tr -cd '0-9')
  [ -n "$read_at" ] || read_at=$((now - 3600))
  host=$(hostname -s 2>/dev/null || hostname)
  spent=$(fm_wd_spent_since "$CALLS" "$((now - 86400))")
  cap=$(cfg daily-max-usd 1.00)
  models=''
  for m in $(wd_models); do
    ok=$(awk -F'\t' -v m="$m" '$3 == m { o = $4 } END { print (o == "" ? "unused" : (o == "ok" ? "ok" : "failing")) }' "$CALLS" 2>/dev/null)
    models="$models${models:+, }$m ${ok:-unused}"
  done
  mkdir -p "$OUT"
  tmp=$(mktemp "$OUT/.status.XXXXXX") || return 1
  {
    printf '# Firstmate watchdog - %s\n' "$host"
    printf 'updated %s, scan every %ss, mode %s, restart %s\n' "$(fm_wd_iso "$now")" "$interval" "$(wd_mode)" "$restart_word"
    printf 'STALE IF NOT UPDATED BY %s (watchdog may be down)\n' "$(fm_wd_iso $((now + interval * 3 + 300)))"
    printf 'models: %s; spent 24h $%s of $%s\n\n' "${models:-none}" "$spent" "$cap"
    printf '## Homes\n'
    head -n 12 "$1"
    printf '\n## Actions since last read (%s)\n' "$(fm_wd_iso "$read_at")"
    if [ -f "$LEDGER" ]; then
      awk -F'\t' -v since="$read_at" '$1 >= since && $7 != "pending" { print $1 "\t" $4 "\t" $6 "\t" $5 "\t" $7 }' "$LEDGER" |
        tail -n 10 | while IFS=$'\t' read -r e s a y p; do printf -- '- %s %s %s %s %s\n' "$(fm_wd_iso "$e" | cut -c12-16)" "$s" "$a" "$y" "$p"; done
    fi
    printf '\n## Open gaps\n'
    sort -u "$2" | head -n 8
  } | head -n 39 > "$tmp" && mv "$tmp" "$OUT/status.md"
}

# --- commands ----------------------------------------------------------------------

# One home's monitor unit status, from bin/fm-monitor-watchdog.sh manager-status.
# A read that prints no `manager:` line, including one that times out, is unreadable.
wd_monitor_read() {  # <home>
  local home=$1 out word tmp
  out=$(fm_run_timed 10 env FM_HOME="$home" bash "$SCRIPT_DIR/fm-monitor-watchdog.sh" manager-status 2>/dev/null) || true
  word=$(printf '%s\n' "$out" | sed -n 's/^manager: \([a-z]*\).*/\1/p' | head -n 1)
  case "$word" in enabled|disabled|uncovered) ;; *) word=unreadable ;; esac
  tmp=$(mktemp "$home/state/.monitor-status.XXXXXX" 2>/dev/null) || return 1
  if printf 'status=%s at=%s\n' "$word" "$(wd_now)" > "$tmp" && mv -f "$tmp" "$home/state/monitor-status"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- memory guard (bin/fm-memory-guard.sh) --------------------------------------

# wd_memory_guard_pass: one host memory and swap sample per pass, never per
# home. It runs in observe mode unless this watchdog's mode is act. An alarm in
# force is an open gap on every pass; a sample that fails is a gap and never
# stops the pass.
wd_memory_guard_pass() {
  local out rc=0 summary
  [ "$(cfg memory-guard on)" != off ] || return 0
  set -- check
  [ "$(wd_mode)" = act ] || set -- "$@" --observe
  # Its config is the owner home's; its state follows this watchdog's own.
  out=$(fm_run_timed 30 env -u FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE="$STATE" FM_HOME="$OWNER_HOME" FM_MEMORY_GUARD_NOW="$(wd_now)" \
    "$SCRIPT_DIR/fm-memory-guard.sh" "$@" 2>/dev/null </dev/null) || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) ;;
    *) printf -- '- host: memory guard sample failed (exit %s)\n' "$rc" >> "$WD_GAPS"; return 0 ;;
  esac
  # At most three host lines a pass, so other homes' gaps stay visible.
  summary=$(printf '%s\n' "$out" | sed -n '1s/^memory-guard: status=alarm //p')
  {
    [ -z "$summary" ] || printf -- '- host: memory alarm %s\n' "$summary"
    printf '%s\n' "$out" | sed -n 's/^MEMORY_GUARD_ALARM: /- host: /p'
  } | head -n 3 >> "$WD_GAPS"
  return 0
}

wd_once() {  # [home-filter]
  local filter=${1:-} health
  mkdir -p "$WD" "$OUT"
  rm -f "$WD/quota-snapshot.txt" "$WD/quota-snapshot.failed"
  health=$(mktemp "$WD/.health.XXXXXX") || return 1
  WD_GAPS=$(mktemp "$WD/.gaps.XXXXXX") || return 1
  wd_reconcile_pending
  wd_subjects | while IFS=$'\t' read -r home parent id; do
    [ -z "$filter" ] || [ "$home" = "$filter" ] || continue
    wd_monitor_read "$home"
    wd_observe "$home" "$parent" "$id"
    wd_score_gap
    wd_score_activity
    WD_SYMPTOM=ok WD_RESTARTED=0
    wd_handle_subject
    # A home whose restart awaits pickup gets no action, quota checks included,
    # and the ledger is read again so that holds from the pass that starts it.
    if [ "$parent" = - ] && ! wd_home_awaits_restart "$home"; then
      wd_quota_guard_pass
    fi
    wd_visit_worker_dialogs page
    wd_health_line >> "$health"
  done
  wd_memory_guard_pass
  [ -n "$(wd_models)" ] || printf -- '- no model configured; judged symptoms are reported only\n' >> "$WD_GAPS"
  wd_write_status "$health" "$WD_GAPS"
  rm -f "$health" "$WD_GAPS" "$WD/.decisions" "$WD/.decisions-aged"
}

cmd_scan() {
  local filter=${1:-}
  mkdir -p "$WD"
  wd_subjects | while IFS=$'\t' read -r home parent id; do
    [ -z "$filter" ] || [ "$home" = "$filter" ] || continue
    wd_observe "$home" "$parent" "$id"
    wd_print_observation
    wd_visit_worker_dialogs print
  done
}

cmd_run() {
  local interval
  interval=$(cfgi interval-secs 120)
  [ "${1:-}" != --interval ] || interval=${2:?--interval needs seconds}
  mkdir -p "$WD"
  fm_lock_try_acquire "$WD/.run.lock" || { echo "fm-watchdog: another watchdog already runs for $OWNER_HOME"; exit 0; }
  trap 'fm_lock_release "$WD/.run.lock"; exit 0' INT TERM HUP
  while :; do
    wd_once || true
    sleep "$interval"
  done
}

# The restarted session runs pickup in its own terminal, so the terminal it
# discovers there is the captain's new one; the record is moved at once.
cmd_pickup() {
  local token=${1:-} st=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  case "$token" in ''|*[!0-9a-f]*) die "pickup needs the hex token from the restart prompt" 2 ;; esac
  mkdir -p "$st/watchdog/pickups"
  printf 'at=%s\nlock_pid=%s\n' "$(wd_now)" "$(head -n 1 "$st/.lock" 2>/dev/null)" > "$st/watchdog/pickups/$token"
  local backend target
  wd_read_owner "$st"
  backend=$(discover_supervisor_backend 2>/dev/null) || backend=''
  target=$(discover_supervisor_target 2>/dev/null) || target=''
  wd_publish_captain "$st" pickup "$backend" "$target" '' '' move
  echo "pickup recorded"
}

canonical_home() { (cd -P -- "$OWNER_HOME" && pwd -P); }

manager_name() {
  local sum _
  read -r sum _ <<EOF
$(canonical_home | tr -d '\n' | cksum)
EOF
  printf 'firstmate-watchdog-%s\n' "$sum"
}

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }

render_launchd() {
  local home label script path
  mkdir -p "$(canonical_home)/state/watchdog"
  home=$(canonical_home | xml_escape)
  label=$(manager_name)
  script=$(printf '%s' "$SCRIPT_DIR/fm-watchdog.sh" | xml_escape)
  path=$(printf '%s' "$PATH" | xml_escape)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$script</string><string>run</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$home</string>
    <key>PATH</key><string>$path</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$home/state/watchdog/run.log</string>
  <key>StandardOutPath</key><string>$home/state/watchdog/run.log</string>
</dict></plist>
EOF
}

render_systemd() {
  cat <<EOF
[Unit]
Description=Firstmate assistant watchdog ($(manager_name))
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="FM_HOME=$(canonical_home)"
Environment="PATH=$PATH"
ExecStart=/bin/bash "$SCRIPT_DIR/fm-watchdog.sh" run
Restart=always
RestartSec=30s

[Install]
WantedBy=default.target
EOF
}

manager_status() {
  local name
  name=$(manager_name)
  case "$(uname -s)" in
    Darwin)
      [ -f "$HOME/Library/LaunchAgents/$name.plist" ] || { echo 'manager: uncovered (unit not installed)'; return 1; }
      launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1 && { echo "manager: enabled ($name)"; return 0; } ;;
    Linux)
      [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$name.service" ] || { echo 'manager: uncovered (unit not installed)'; return 1; }
      systemctl --user is-active --quiet "$name.service" && { echo "manager: enabled ($name)"; return 0; } ;;
    *) echo 'manager: uncovered (unsupported platform)'; return 1 ;;
  esac
  echo "manager: disabled ($name)"
  return 1
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  run) cmd_run "$@" ;;
  once)
    filter=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dry-run) WD_FORCE_DRY=1 ;;
        --home) filter=$(cd -P -- "${2:?--home needs a path}" && pwd -P) || die "no such home: $2" 2; shift ;;
        *) die "unknown once option: $1" 2 ;;
      esac
      shift
    done
    wd_once "$filter" ;;
  scan)
    filter=''
    if [ "${1:-}" = --home ]; then filter=$(cd -P -- "${2:?--home needs a path}" && pwd -P) || die "no such home: $2" 2; fi
    cmd_scan "$filter" ;;
  judge)
    [ "$#" -eq 2 ] || die "usage: judge <purpose> <answer-ere> < prompt" 2
    mkdir -p "$WD"
    wd_judge "$1" "$2" "$(cat)" ;;
  council) cmd_council "$@" ;;
  status) cat "$OUT/status.md" 2>/dev/null || die "no status file yet" ;;
  ack-read) mkdir -p "$WD" && wd_now > "$WD/last-read" ;;
  pickup) cmd_pickup "$@" ;;
  monitor-read)
    [ -d "$OWNER_HOME/state" ] || die "no state directory in $OWNER_HOME" 2
    wd_monitor_read "$OWNER_HOME" ;;
  manager-name) manager_name ;;
  manager-status) manager_status ;;
  render-launchd) render_launchd ;;
  render-systemd) render_systemd ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
