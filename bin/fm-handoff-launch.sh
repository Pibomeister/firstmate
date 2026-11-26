#!/usr/bin/env bash
# fm-handoff-launch.sh [options] <handoff-file> - verified primary handoff.
# Only the current lock owner can prepare a claim. Launches via Orca agent
# argv (never a shell command string), or tmux's direct argv execution.
# Options, each optional, choose the successor runtime without touching any
# account pin:
#   --harness claude|codex|agy  successor runtime (default: this session's)
#   --model <id>|default        successor model (default: the predecessor's)
#   --effort <level>|default    successor reasoning effort (default: the
#                               predecessor's): low, medium, high, xhigh, max,
#                               or ultra for claude; minimal, low, medium,
#                               high, or xhigh for codex. claude and codex
#                               only, and on Orca only together with a model
#   --setting-sources <list>|default
#                               claude settings sources, such as project,local
#                               (default: the predecessor's); tmux only
#   --account <entry>           a config/claude-accounts entry for a claude
#                               successor; tmux only, because Orca agent launch
#                               cannot select a Claude account. The entry must
#                               already be signed in (claude auth status); no
#                               sign-in is opened.
#   --reason <token>            why this runtime was chosen (default: handoff)
# By default the successor keeps the predecessor's runtime: on the same
# harness, the model, effort, and claude setting sources come from the lock
# holder's own launch argv (/proc/<pid>/cmdline, else ps). A value the
# predecessor did not record, or that cannot be read as one value, is not
# guessed: that flag is omitted, as before, and the record says why. A named
# option, `default` included, wins over the predecessor's value, so a quota
# reroute that picks another model or effort names it with --reason. A harness
# change carries nothing. stderr states each value and where it came from, and
# the successor record adds effort=, setting_sources=, <field>_from=
# (explicit, predecessor, unrecorded, unreadable, harness_change, or
# unsupported), and predecessor_<field>= (the value read, none, or unknown).
# First, `bin/fm-order.sh covers --doc <handoff-file>` must find every open
# captain order named in the document. A handoff that omits one, or coverage
# that cannot be read, is refused with exit 4 and a diagnostic before any
# preflight, claim, or record, so no order is dropped across the session
# boundary and this session keeps the lock and its gate unchanged.
# Before any claim, a quota preflight (bin/fm-supervisor-failover-lib.sh)
# reads the successor's own quota. A successor whose pool is exhausted_now or
# at 0% is refused with exit 3 before anything launches; an unmeasured pool is
# disclosed and does not block. The choice and verdict are appended to
# state/supervisor-failover.log and kept in the pending claim and in
# state/.handoff-successor as successor=.
# codex follows config/codex-approval-mode and config/codex-permission-mode on
# tmux, and starts through bin/fm-codex-launch.sh as fm-spawn's Codex launches
# do, so its tool shells keep TMUX_PANE for the acknowledgement; on Orca, Orca
# owns the agent's posture, so a non-bypass setting refuses.
# agy launches on tmux only, and only into a home agy already trusts.
# A tmux pane does not inherit this session's environment, so without
# --account a claude successor gets this session's CLAUDE_CONFIG_DIR when set,
# and a codex successor gets its CODEX_HOME, or has it cleared when unset.
# Two fresh terminals share a total 600-second deadline. After acquiring the
# initial claim lock, the first gets half the remaining time, up to 300 seconds,
# and the retry gets the rest.
# Setup and cleanup add to that budget, so a foreground tool timeout of 600
# seconds cannot cover it. Run in the background and collect the exit status
# and output before reporting readiness.
# A successor must read the document and call fm-handoff-ack.sh with its nonce
# and digest. fm-lock.sh validates that ack before moving the live lock.
# The launch prompt names the handoff by path and never includes its text.
# bin/fm-handoff-lib.sh owns the warning when that document is longer than 60 lines.
# Each claim records the predecessor's own endpoint from state/.lock-session.
# After a committed verified transfer, the successor's fm-handoff-ack.sh runs
# bin/fm-handoff-close.sh, which closes only that endpoint once it proves the
# endpoint still hosts this predecessor; its header owns the proof and the one
# event it records. This launcher never signals the predecessor itself. A
# failed, expired, or unresolved handoff closes nothing: the predecessor and,
# on Orca, failed attempts' panes stay for diagnosis. A failed attempt's nonce
# expires and cannot take ownership.
# Every unfinished exit after handoff_started emits one handoff_failed event,
# unless the lock already moved to a successor with a valid ack: that exit
# records completion instead. Completion and failure are decided only while
# holding .lock.acquire, so an uncommitted transfer is never reported. An exit
# waits for that lock until 10 seconds past the claim deadline. If the lock is
# still busy then, a successor transaction may yet commit, so the exit emits
# handoff_failed reason=unresolved: not final, settled by a later handoff_ack
# reason=lock_transferred for the same nonce.
# Each handoff_failed also rewrites state/.handoff-launch-failed, as does an
# unfinished exit once clearing an earlier record has begun, and a launch
# removes it once it holds the launch lock; bin/fm-handoff-lib.sh owns the record and
# how it releases a planned fresh start's Stop gate for the surviving session.
# Outputs only the versioned events owned by fm-handoff-lib.sh. Other errors
# go to stderr. state/.handoff-successor is written only after lock verification.
# Test-only: FM_TEST_SEAM=1 enables FM_HANDOFF_TEST_HARNESS and
# FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS (total budget, minimum 4 seconds).
# Test-only: FM_TEST_SEAM=1 also enables FM_HANDOFF_TEST_PROC_ROOT, a stand-in
# for /proc when reading the predecessor's argv.
# Usage: fm-handoff-launch.sh [--harness <h>] [--model <id>] [--effort <level>]
#        [--setting-sources <list>] [--account <entry>] [--reason <token>]
#        <handoff-file> | --help
set -eu
umask 077
case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
SUCC_HARNESS='' SUCC_MODEL='' SUCC_ACCOUNT='' SUCC_REASON=handoff
SUCC_EFFORT='' SUCC_SETTING_SOURCES=''
GIVEN_MODEL=0 GIVEN_EFFORT=0 GIVEN_SETTING_SOURCES=0
while [ $# -gt 1 ]; do
  case "$1" in
    --harness|--model|--effort|--setting-sources|--account|--reason)
      [ -n "${2:-}" ] || die "$1 requires a value"
      case "$1" in
        --harness) SUCC_HARNESS=$2 ;;
        --model) SUCC_MODEL=$2 GIVEN_MODEL=1 ;;
        --effort) SUCC_EFFORT=$2 GIVEN_EFFORT=1 ;;
        --setting-sources) SUCC_SETTING_SOURCES=$2 GIVEN_SETTING_SOURCES=1 ;;
        --account) SUCC_ACCOUNT=$2 ;;
        --reason) SUCC_REASON=$2 ;;
      esac
      shift 2
      ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] && [ -r "$1" ] && [ -f "$1" ] || die 'supply a readable handoff document'
HANDOFF=$1
case "$HANDOFF" in /*) ;; *) HANDOFF="$(pwd -P)/$HANDOFF" ;; esac
case "$HANDOFF" in *$'\n'*|*$'\r'*) die 'handoff path must be one line' ;; esac
# Runtime value shapes, shared by the options and the predecessor's argv.
valid_model() { case "$1" in ''|-*|*[!][A-Za-z0-9._/:-]*) return 1 ;; esac; }
effort_levels() { # <harness>
  case "$1" in
    claude) printf 'low medium high xhigh max ultra' ;;
    codex) printf 'minimal low medium high xhigh' ;;
  esac
}
valid_effort() { # <harness> <level>
  case "$2" in ''|*[!a-z]*) return 1 ;; esac
  case " $(effort_levels "$1") " in *" $2 "*) return 0 ;; esac
  return 1
}
valid_setting_sources() { case "$1" in *[!a-z,]*) return 1 ;; esac; }
case "$SUCC_MODEL" in
  default) SUCC_MODEL= ;;
  *) [ "$GIVEN_MODEL" = 0 ] || valid_model "$SUCC_MODEL" || die '--model must be one model id' ;;
esac
[ "$SUCC_EFFORT" != default ] || SUCC_EFFORT=
case "$SUCC_SETTING_SOURCES" in
  default) SUCC_SETTING_SOURCES= ;;
  *) [ "$GIVEN_SETTING_SOURCES" = 0 ] || valid_setting_sources "$SUCC_SETTING_SOURCES" \
    || die '--setting-sources must be default or a comma list of lowercase sources, such as project,local' ;;
esac
case "$SUCC_REASON" in *[!A-Za-z0-9_.:-]*) die '--reason must be one token of letters, digits, _ . : -' ;; esac
case "$SUCC_ACCOUNT" in *[[:cntrl:]]*) die '--account must name one config/claude-accounts entry exactly' ;; esac
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_root_is_secondmate_home "$FM_HOME" && die 'a second mate asks its parent to relaunch it'
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-handoff-lib.sh
. "$SCRIPT_DIR/fm-handoff-lib.sh"
fm_handoff_warn_line_cap "$HANDOFF"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-orca-cli-cache.sh
. "$SCRIPT_DIR/fm-orca-cli-cache.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-supervisor-failover-lib.sh
. "$SCRIPT_DIR/fm-supervisor-failover-lib.sh"
fm_session_lock_handoff_actor_authorized "$STATE" "$FM_HOME" "$SCRIPT_DIR/fm-watch.sh" || die 'only the current session lock owner or its watcher can launch its successor'
# Open-order coverage: a handoff that omits an open captain order would drop it
# across the session boundary, so refuse before any preflight, claim, or record.
cover_rc=0
COVER_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" covers --doc "$HANDOFF" 2>&1) || cover_rc=$?
if [ "$cover_rc" -ne 0 ]; then
  if [ "$cover_rc" -eq 3 ]; then
    printf 'error: the handoff does not list every open captain order, so no successor is launched and this session keeps the lock; rewrite it with bin/fm-ledger.sh handoff or bin/fm-order.sh handoff --doc, then launch again: %s\n' "$(printf '%s' "$COVER_OUT" | tr '\n' ' ')" >&2
  else
    printf 'error: cannot verify that the handoff lists every open captain order, so no successor is launched and this session keeps the lock: %s\n' "$(printf '%s' "$COVER_OUT" | tr '\n' ' ')" >&2
  fi
  exit 4
fi
PRED_PID=$(cat "$STATE/.lock")
case "$PRED_PID" in ''|*[!0-9]*) die 'verified successor launch currently requires a POSIX process anchor' ;; esac
PRED_START=$(fm_session_process_start "$PRED_PID") || die 'cannot identify predecessor instance'
HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || HARNESS=
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HANDOFF_TEST_HARNESS:-}" ]; then HARNESS=$FM_HANDOFF_TEST_HARNESS; fi
[ -n "$SUCC_HARNESS" ] || SUCC_HARNESS=$HARNESS
case "$SUCC_HARNESS" in
  claude|codex|agy) ;;
  *) die "successor launcher serves claude, codex, and agy, resolved '$SUCC_HARNESS'" ;;
esac
BACKEND=$(fm_backend_name) || die 'cannot determine backend'
case "$BACKEND" in orca|tmux) command -v "$BACKEND" >/dev/null || die "missing backend $BACKEND" ;; *) die "no successor launcher for backend '$BACKEND'" ;; esac
if [ "$BACKEND" = tmux ]; then
  command -v "$SUCC_HARNESS" >/dev/null || die "missing successor runtime $SUCC_HARNESS"
fi
# Predecessor runtime. The lock holder's own launch argv is its recorded
# launch: /proc's NUL-separated cmdline is exact; ps joins words with blanks,
# so a value it cannot delimit (an empty one) reads as unreadable, never as a
# guess. Scanning stops at a `--` word.
PRED_ARGV=()
read_predecessor_argv() {
  local proc_root=/proc w args
  [ "${FM_TEST_SEAM:-}" != 1 ] || proc_root=${FM_HANDOFF_TEST_PROC_ROOT:-/proc}
  PRED_ARGV_EXACT=0
  if [ -r "$proc_root/$PRED_PID/cmdline" ]; then
    while IFS= read -r -d '' w || [ -n "$w" ]; do PRED_ARGV+=("$w"); done < "$proc_root/$PRED_PID/cmdline"
    PRED_ARGV_EXACT=1
  elif args=$(COLUMNS=10000 LC_ALL=C ps -ww -o args= -p "$PRED_PID" 2>/dev/null) && [ -n "$args" ]; then
    read -r -a PRED_ARGV <<< "$args"
  fi
}
# pred_scan <value-prefix> <flag>...: the last value given to a named flag,
# `--flag value` or `--flag=value`, whose value starts with the prefix (which
# is removed). Sets PV and PV_STATE to found, absent, or unreadable.
pred_scan() {
  local prefix=$1 i=1 n=${#PRED_ARGV[@]} w f v ok
  shift
  PV='' PV_STATE=absent
  while [ "$i" -lt "$n" ]; do
    w=${PRED_ARGV[$i]}
    [ "$w" != -- ] || break
    for f; do
      ok=1
      case "$w" in
        "$f")
          if [ $((i + 1)) -lt "$n" ]; then
            v=${PRED_ARGV[$((i + 1))]}
            i=$((i + 1))
            case "$v" in -*) [ "$PRED_ARGV_EXACT" = 1 ] || ok=0 ;; esac
          else
            v='' ok=0
          fi
          ;;
        "$f"=*) v=${w#"$f"=} ;;
        *) continue ;;
      esac
      if [ "$ok" = 0 ]; then
        # An undelimited value is this field's only when every value is.
        [ -z "$prefix" ] || continue
        PV='' PV_STATE=unreadable
      else
        case "$v" in "$prefix"*) PV=${v#"$prefix"} PV_STATE=found ;; esac
      fi
    done
    i=$((i + 1))
  done
}
# pred_lookup <field>: the predecessor's value for one field, by its harness.
pred_lookup() {
  PV='' PV_STATE=absent
  [ "${#PRED_ARGV[@]}" -gt 0 ] || { PV_STATE=unreadable; return 0; }
  case "$HARNESS:$1" in
    claude:model|agy:model) pred_scan '' --model ;;
    codex:model) pred_scan '' --model -m ;;
    claude:effort) pred_scan '' --effort ;;
    codex:effort) pred_scan model_reasoning_effort= -c --config ;;
    claude:setting_sources) pred_scan '' --setting-sources ;;
  esac
  [ "$PV_STATE" = found ] || return 0
  case "$1" in
    model) valid_model "$PV" || PV_STATE=unreadable ;;
    effort)
      PV=${PV#\"} PV=${PV%\"}
      valid_effort "$HARNESS" "$PV" || PV_STATE=unreadable
      ;;
    setting_sources) valid_setting_sources "$PV" || PV_STATE=unreadable ;;
  esac
  [ "$PV_STATE" = found ] || PV=
}
# What the successor launch can carry: <field> -> 0 or 1.
successor_supports() {
  case "$1:$SUCC_HARNESS:$BACKEND" in
    model:*) return 0 ;;
    effort:claude:*|effort:codex:*) return 0 ;;
    setting_sources:claude:tmux) return 0 ;;
  esac
  return 1
}
# resolve_field <field> <var> <given>: sets <var>, <FIELD>_SET, <FIELD>_FROM,
# and PRED_<FIELD> (the predecessor's value, none, or unknown).
resolve_field() {
  local field=$1 var=$2 given=$3 upper from set=0 shown
  upper=$(printf '%s' "$field" | tr '[:lower:]' '[:upper:]')
  pred_lookup "$field"
  case "$PV_STATE" in
    found) shown=${PV:-empty} ;;
    absent) shown=none ;;
    *) shown=unknown ;;
  esac
  if [ "$given" = 1 ]; then
    successor_supports "$field" || die "--$(printf '%s' "$field" | tr _ -) cannot be carried by a $SUCC_HARNESS successor on $BACKEND"
    [ "$field" != effort ] || [ -z "${!var}" ] || valid_effort "$SUCC_HARNESS" "${!var}" \
      || die "--effort for a $SUCC_HARNESS successor must be default or one of: $(effort_levels "$SUCC_HARNESS")"
    from=explicit
    [ -z "${!var}" ] || set=1
  elif [ "$SUCC_HARNESS" != "$HARNESS" ]; then
    from=harness_change
  elif [ "$PV_STATE" != found ]; then
    from=$([ "$PV_STATE" = absent ] && echo unrecorded || echo unreadable)
  elif ! successor_supports "$field"; then
    from=unsupported
  else
    from=predecessor set=1
    printf -v "$var" '%s' "$PV"
  fi
  printf -v "${upper}_SET" '%s' "$set"
  printf -v "${upper}_FROM" '%s' "$from"
  printf -v "PRED_${upper}" '%s' "$shown"
}
case "$HARNESS" in claude|codex|agy) read_predecessor_argv ;; esac
resolve_field model SUCC_MODEL "$GIVEN_MODEL"
resolve_field effort SUCC_EFFORT "$GIVEN_EFFORT"
resolve_field setting_sources SUCC_SETTING_SOURCES "$GIVEN_SETTING_SOURCES"
if [ "$BACKEND" = orca ] && [ "$EFFORT_SET" = 1 ] && [ "$MODEL_SET" = 0 ]; then
  # orca agent launch takes --effort only together with --model.
  [ "$EFFORT_FROM" != explicit ] || die '--effort on Orca needs --model too'
  EFFORT_SET=0 EFFORT_FROM=unsupported SUCC_EFFORT=
fi
[ "$EFFORT_SET" = 1 ] || SUCC_EFFORT=
[ "$SETTING_SOURCES_SET" = 1 ] || SUCC_SETTING_SOURCES=
MODEL_ARGS=()
[ -z "$SUCC_MODEL" ] || MODEL_ARGS=(--model "$SUCC_MODEL")
if [ "$EFFORT_SET" = 1 ]; then
  if [ "$SUCC_HARNESS" = codex ] && [ "$BACKEND" = tmux ]; then
    MODEL_ARGS+=(-c "model_reasoning_effort=\"$SUCC_EFFORT\"")
  else
    MODEL_ARGS+=(--effort "$SUCC_EFFORT")
  fi
fi
[ "$SETTING_SOURCES_SET" = 0 ] || MODEL_ARGS+=(--setting-sources "$SUCC_SETTING_SOURCES")
runtime_line() { # <field> <value> <from> <predecessor value>
  local shown=${2:-default}
  case "$3" in
    predecessor) printf '%s %s, from the predecessor' "$1" "$shown" ;;
    explicit) printf '%s %s, named explicitly (reason=%s); the predecessor had %s' "$1" "$shown" "$SUCC_REASON" "$4" ;;
    unrecorded) printf "%s default: the predecessor's launch recorded none, so the runtime's own applies" "$1" ;;
    unreadable) printf "%s default: the predecessor's launch value could not be read, so the runtime's own applies" "$1" ;;
    harness_change) printf '%s %s: the successor runtime differs from %s, so nothing is carried' "$1" "$shown" "${HARNESS:-unknown}" ;;
    unsupported) printf '%s default: a %s successor on %s cannot carry the predecessor'"'"'s %s' "$1" "$SUCC_HARNESS" "$BACKEND" "$4" ;;
  esac
}
printf 'successor runtime: %s; %s; %s\n' \
  "$(runtime_line model "$SUCC_MODEL" "$MODEL_FROM" "$PRED_MODEL")" \
  "$(runtime_line effort "$SUCC_EFFORT" "$EFFORT_FROM" "$PRED_EFFORT")" \
  "$(runtime_line setting-sources "$([ "$SETTING_SOURCES_SET" = 1 ] && echo "${SUCC_SETTING_SOURCES:-empty}")" "$SETTING_SOURCES_FROM" "$PRED_SETTING_SOURCES")" >&2
# Foreign primary markers would let bin/fm-harness.sh read a non-Claude
# successor as Claude; fm-spawn clears the same set for agy workers.
MARKER_ENV=(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS)
LAUNCH_ENV=()
read_mode() { # <file> <default>
  if [ -e "$1" ]; then tr -d '[:space:]' < "$1"; else printf '%s' "$2"; fi
}
case "$SUCC_HARNESS" in
  claude)
    PERMISSION_MODE=$(read_mode "$CONFIG/claude-permission-mode" bypass)
    case "$PERMISSION_MODE" in
      bypass) PERM_ARGS=(--dangerously-skip-permissions) ;;
      auto) PERM_ARGS=(--permission-mode auto) ;;
      *) die 'invalid config/claude-permission-mode' ;;
    esac
    # Orca owns its agent permission configuration; do not substitute a terminal
    # shell command to carry permission flags that agent launch does not expose.
    if [ "$BACKEND" = orca ] && [ "$PERMISSION_MODE" != bypass ]; then
      die 'Orca agent launch owns permission posture; explicit auto mode needs an Orca agent configured for auto before handoff'
    fi
    ;;
  codex)
    CODEX_APPROVAL=$(read_mode "$CONFIG/codex-approval-mode" bypass)
    CODEX_PERMISSION=$(read_mode "$CONFIG/codex-permission-mode" bypass)
    case "$CODEX_APPROVAL" in
      bypass) PERM_ARGS=(--dangerously-bypass-approvals-and-sandbox) ;;
      approve-for-me) PERM_ARGS=(--approve-for-me) ;;
      *) die 'invalid config/codex-approval-mode' ;;
    esac
    case "$CODEX_PERMISSION" in
      bypass) ;;
      restricted) PERM_ARGS=(--sandbox workspace-write --ask-for-approval on-request) ;;
      *) die 'invalid config/codex-permission-mode' ;;
    esac
    if [ "$BACKEND" = orca ] && { [ "$CODEX_APPROVAL" != bypass ] || [ "$CODEX_PERMISSION" != bypass ]; }; then
      die 'Orca agent launch owns permission posture; a non-bypass Codex setting needs an Orca agent configured for it before handoff'
    fi
    ;;
  agy)
    [ "$BACKEND" = tmux ] || die "agy successor launch readiness is verified on tmux only, not $BACKEND"
    fm_failover_agy_trusted "$FM_HOME" \
      || die "agy does not trust $FM_HOME yet, and its folder-trust dialog would park the successor; trust the home in agy first"
    PERM_ARGS=(--dangerously-skip-permissions)
    ;;
esac
ACCOUNT_ROOT=
if [ -n "$SUCC_ACCOUNT" ]; then
  [ "$SUCC_HARNESS" = claude ] || die '--account names a Claude account and applies to a claude successor only'
  [ "$BACKEND" = tmux ] || die 'Orca agent launch cannot select a Claude account, so --account needs the tmux backend'
  listed=$(fm_worker_account_list claude "$CONFIG") || exit 1
  printf '%s\n' "$listed" | grep -Fxq -- "$SUCC_ACCOUNT" \
    || die "account '$SUCC_ACCOUNT' is not declared in config/claude-accounts"
  root=$SUCC_ACCOUNT
  [ "$root" != ordinary ] || root=
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    die "config/claude-accounts entry is not a readable, searchable directory: $root"
  fi
  fm_worker_account_check claude "$SUCC_ACCOUNT" "$root" "$(command -v claude)" '' config/claude-accounts || exit 1
  read -r -a LAUNCH_ENV <<< "$(fm_worker_account_claude_shed)"
  if [ -n "$root" ]; then
    LAUNCH_ENV+=("CLAUDE_CONFIG_DIR=$root")
    ACCOUNT_ROOT=$root
  else
    LAUNCH_ENV+=(-u CLAUDE_CONFIG_DIR)
    ACCOUNT_ROOT="${HOME:?HOME is required to measure the ordinary account}/.claude"
  fi
else
  case "$SUCC_HARNESS" in
    claude) [ -z "${CLAUDE_CONFIG_DIR:-}" ] || LAUNCH_ENV=(env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR") ;;
    codex)
      if [ -n "${CODEX_HOME:-}" ]; then LAUNCH_ENV=("CODEX_HOME=$CODEX_HOME"); else LAUNCH_ENV=(-u CODEX_HOME); fi
      ;;
  esac
fi
quota_rc=0
QUOTA_LINE=$(fm_failover_quota_check "$SUCC_HARNESS" "${SUCC_MODEL:-default}" "$ACCOUNT_ROOT") || quota_rc=$?
SUCC_SOURCES_SHOWN=default
[ "$SETTING_SOURCES_SET" = 0 ] || SUCC_SOURCES_SHOWN=${SUCC_SETTING_SOURCES:-empty}
SUCC_RECORD="harness=$SUCC_HARNESS model=$(fm_failover_token "${SUCC_MODEL:-default}") account=$(fm_failover_token "${SUCC_ACCOUNT:-ambient}") reason=$SUCC_REASON $QUOTA_LINE"
SUCC_RECORD="$SUCC_RECORD effort=${SUCC_EFFORT:-default} setting_sources=$SUCC_SOURCES_SHOWN model_from=$MODEL_FROM effort_from=$EFFORT_FROM setting_sources_from=$SETTING_SOURCES_FROM"
SUCC_RECORD="$SUCC_RECORD predecessor_model=$PRED_MODEL predecessor_effort=$PRED_EFFORT predecessor_setting_sources=$PRED_SETTING_SOURCES"
if [ "$quota_rc" -eq 1 ]; then
  fm_failover_log "event=successor_vetoed $SUCC_RECORD"
  printf 'error: successor quota is exhausted (%s); choose another account or runtime, for example with bin/fm-supervisor-failover.sh\n' "$SUCC_RECORD" >&2
  exit 3
fi
fm_failover_log "event=successor_preflight $SUCC_RECORD"
printf 'successor: %s\n' "$SUCC_RECORD" >&2
TIMEOUT=600
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  case "${FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS:-}" in
    ''|*[!0-9]*) ;; *) TIMEOUT=$FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS ;;
  esac
fi
[ "$TIMEOUT" -ge 4 ] || die 'handoff budget must be at least four seconds'
SHA256=$(fm_handoff_hash "$HANDOFF") || die 'cannot hash handoff'
mkdir -p "$FM_HOME/data"
fm_lock_try_acquire "$STATE/.handoff-launch.lock" || die 'a handoff launcher already owns this home'
NONCE=
CLAIM_HELD=0
HANDOFF_STARTED=0
FAILED_RECORD_CLEARED=0
HANDOFF_COMPLETE=0
HANDOFF_FAIL_REQUESTED=0
HANDOFF_FAILURE_REASON=error
attempt=0
# A signal may arrive inside a call whose stdout is redirected to the backend
# receipt. Keep the event stream on its original descriptor, out of that receipt.
exec 9>&1
# Keep the existing hard-bound timeout mechanism. The constant exec wrapper
# closes our event descriptor in the backend process; all launch data stays argv.
# shellcheck disable=SC2016 # Expansion belongs to the fixed child wrapper.
BACKEND_EXEC=(bash -c 'exec 9>&-; exec "$@"' handoff-launch)
cleanup() {
  local rc=$? wait=10
  trap - EXIT
  trap '' HUP INT TERM
  set +e
  if [ -n "$NONCE" ] && [ "$CLAIM_HELD" != 1 ]; then
    [ $(( ${CLAIM_DEADLINE:-0} - $(date +%s) + 10 )) -le "$wait" ] || wait=$(( CLAIM_DEADLINE - $(date +%s) + 10 ))
    if fm_lock_acquire_wait_max "$STATE/.lock.acquire" "$wait"; then
      CLAIM_HELD=1
    else
      HANDOFF_FAILURE_REASON=unresolved
    fi
  fi
  if [ "$HANDOFF_COMPLETE" -eq 0 ] && [ "$CLAIM_HELD" = 1 ] && [ -n "$NONCE" ] \
    && transfer_committed && record_completion; then
    rc=0
  fi
  if [ "$HANDOFF_COMPLETE" -eq 0 ] \
    && { [ "$HANDOFF_STARTED" -eq 1 ] || [ "$HANDOFF_FAIL_REQUESTED" -eq 1 ]; }; then
    fm_handoff_event handoff_failed "$NONCE" "$attempt" "$PRED_PID" none "$HANDOFF_FAILURE_REASON" >&9
    fm_handoff_record_launch_failed "$PRED_PID" "$NONCE" "$attempt" "$HANDOFF_FAILURE_REASON" \
      || printf 'error: cannot record the failed launch in state/.handoff-launch-failed\n' >&2
  elif [ "$HANDOFF_COMPLETE" -eq 0 ] && [ "$rc" -ne 0 ] && [ "$FAILED_RECORD_CLEARED" = 1 ]; then
    # This launch removed an earlier failure record but stopped before any
    # attempt started, so the session still holds the lock: record that too.
    fm_handoff_record_launch_failed "$PRED_PID" "$NONCE" "${attempt:-0}" "$HANDOFF_FAILURE_REASON" \
      || printf 'error: cannot record the failed launch in state/.handoff-launch-failed\n' >&2
  fi
  if [ "$CLAIM_HELD" = 1 ] && [ -n "$NONCE" ] \
    && [ "$(jq -r '.nonce // ""' "$STATE/.handoff-pending" 2>/dev/null)" = "$NONCE" ]; then
    rm -f "$STATE/.handoff-pending"
  fi
  if [ "$CLAIM_HELD" = 1 ]; then fm_lock_release "$STATE/.lock.acquire"; fi
  fm_lock_release "$STATE/.handoff-launch.lock"
  exec 9>&-
  exit "$rc"
}
trap cleanup EXIT
trap 'HANDOFF_FAILURE_REASON=interrupted; exit 1' HUP INT TERM
# Mark the record cleared before removing it, so a signal during the removal
# still leaves this launch's own failure record for the surviving session.
FAILED_RECORD_CLEARED=1
rm -f "$STATE/.handoff-successor" "$STATE/.handoff-launch-failed"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
MONO_DEADLINE=$((SECONDS + TIMEOUT))

fail_handoff() {
  HANDOFF_FAILURE_REASON=$1
  HANDOFF_FAIL_REQUESTED=1
  exit 1
}

take_claim() {
  local left=$((MONO_DEADLINE - SECONDS))
  if [ "$left" -gt 0 ]; then
    fm_lock_acquire_wait_max "$STATE/.lock.acquire" "$left" || return 1
  else
    fm_lock_try_acquire "$STATE/.lock.acquire" || return 1
  fi
  CLAIM_HELD=1
}

transfer_committed() {
  local pid
  pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$pid" != "$PRED_PID" ] && fm_handoff_ack_valid "$NONCE" "$HANDOFF" "$SHA256" "$pid" \
    && fm_session_lock_anchor_instance_matches "$STATE"
}

record_completion() {
  local record_tmp
  record_tmp=$(mktemp "$STATE/.handoff-successor.XXXXXX")
  printf 'pid=%s\nnonce=%s\nhandoff=%s\nsha256=%s\nsuccessor=%s\n' "$(cat "$STATE/.lock")" "$NONCE" "$HANDOFF" "$SHA256" "$SUCC_RECORD" > "$record_tmp"
  if ! fm_handoff_completed "$record_tmp"; then rm -f "$record_tmp"; return 1; fi
  mv "$record_tmp" "$STATE/.handoff-successor" || return 1
  HANDOFF_COMPLETE=1
  fm_failover_log "event=successor_ready pid=$(cat "$STATE/.lock") $SUCC_RECORD" || true
}

# The predecessor's own endpoint, for bin/fm-handoff-close.sh after a committed
# transfer. Read under the claim lock from the sidecar fm-lock.sh wrote for
# this exact instance in this home; anything less concrete records none.
predecessor_endpoint() {
  local session="$STATE/.lock-session" backend terminal
  PRED_BACKEND='' PRED_TERMINAL=''
  [ -f "$session" ] && [ ! -L "$session" ] || return 0
  [ "$(sed -n 's/^anchor_pid=//p' "$session")" = "$PRED_PID" ] \
    && [ "$(sed -n 's/^anchor_start=//p' "$session")" = "$PRED_START" ] \
    && [ "$(sed -n 's/^worktree=//p' "$session")" = "${FM_HOME%/}" ] || return 0
  backend=$(sed -n 's/^backend=//p' "$session")
  terminal=$(sed -n 's/^terminal=//p' "$session")
  case "$backend" in ''|unknown|*[!A-Za-z0-9_-]*) return 0 ;; esac
  case "$terminal" in ''|unknown|*[!A-Za-z0-9_.:%-]*) return 0 ;; esac
  PRED_BACKEND=$backend PRED_TERMINAL=$terminal
}

# The successor's argv for this attempt's prompt; launch data stays argv.
successor_argv() {
  case "$SUCC_HARNESS" in
    claude) SUCC_ARGV=(${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} claude "${PERM_ARGS[@]}" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "$PROMPT") ;;
    codex) SUCC_ARGV=("${MARKER_ENV[@]}" "${LAUNCH_ENV[@]}" FM_CODEX_BIN= "$SCRIPT_DIR/fm-codex-launch.sh" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "${PERM_ARGS[@]}" "$PROMPT") ;;
    agy) SUCC_ARGV=("${MARKER_ENV[@]}" agy --prompt-interactive "$PROMPT" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "${PERM_ARGS[@]}") ;;
  esac
}

for attempt in 1 2; do
  if ! take_claim; then
    fail_handoff claim_busy
  fi
  if [ "$(cat "$STATE/.lock")" != "$PRED_PID" ] || ! fm_session_lock_handoff_actor_authorized "$STATE" "$FM_HOME" "$SCRIPT_DIR/fm-watch.sh"; then
    die 'predecessor no longer owns the lock'
  fi
  predecessor_endpoint
  NONCE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  remaining=$((MONO_DEADLINE - SECONDS))
  [ "$remaining" -gt 0 ] || fail_handoff deadline
  ATTEMPT_END=$((SECONDS + remaining / 2))
  [ "$attempt" = 1 ] || ATTEMPT_END=$MONO_DEADLINE
  [ "$ATTEMPT_END" -le "$MONO_DEADLINE" ] || ATTEMPT_END=$MONO_DEADLINE
  CLAIM_DEADLINE=$(( $(date +%s) + ATTEMPT_END - SECONDS ))
  [ "$CLAIM_DEADLINE" -le "$DEADLINE" ] || CLAIM_DEADLINE=$DEADLINE
  tmp=$(mktemp "$STATE/.handoff-pending.XXXXXX")
  jq -n --arg nonce "$NONCE" --arg doc "$HANDOFF" --arg sha "$SHA256" \
    --arg start "$PRED_START" --argjson pid "$PRED_PID" --argjson deadline "$CLAIM_DEADLINE" --arg successor "$SUCC_RECORD" \
    --arg pbackend "$PRED_BACKEND" --arg pterminal "$PRED_TERMINAL" \
    '{version:1,nonce:$nonce,handoff:$doc,sha256:$sha,predecessor_pid:$pid,predecessor_start:$start,deadline:$deadline,successor:$successor,
      predecessor_backend:($pbackend | if . == "" then null else . end),
      predecessor_terminal:($pterminal | if . == "" then null else . end)}' > "$tmp"
  mv "$tmp" "$STATE/.handoff-pending"
  fm_lock_release "$STATE/.lock.acquire"
  CLAIM_HELD=0
  event=handoff_started
  [ "$attempt" = 1 ] || event=handoff_retry
  printf -v ACK_CMD 'FM_HOME=%q bash %q %q %q' "$FM_HOME" "$SCRIPT_DIR/fm-handoff-ack.sh" "$NONCE" "$SHA256"
  printf -v START_CMD 'FM_HOME=%q bash %q' "$FM_HOME" "$SCRIPT_DIR/fm-session-start.sh"
  PROMPT=$(fm_handoff_successor_prompt "$HANDOFF" "$SHA256" "$ACK_CMD" "$START_CMD" "$NONCE")
  remaining=$((ATTEMPT_END - SECONDS))
  if [ "$remaining" -gt 0 ]; then
    case "$BACKEND" in
      orca)
        HANDOFF_STARTED=1
        fm_handoff_event "$event" "$NONCE" "$attempt" "$PRED_PID" "$(fm_handoff_endpoint_handle || true)" awaiting_ack
        fm_orca_cli_mutation fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" orca agent launch --agent "$SUCC_HARNESS" --worktree "path:$FM_HOME" \
          --surface terminal ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} --prompt "$PROMPT" --json > "$STATE/.handoff-launch-result" 2>&1 || true
        ;;
      tmux)
        SESS=
        if [ -n "${TMUX:-}" ]; then
          SESS=$(fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" tmux display-message -p '#{session_name}' 2>/dev/null) || SESS=
        fi
        SESS=${SESS:-firstmate-$(basename "$FM_HOME")}
        TMUX_TARGET=(new-session -d -s "$SESS")
        remaining=$((ATTEMPT_END - SECONDS))
        if [ "$remaining" -gt 0 ] && fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" tmux has-session -t "=$SESS" >/dev/null 2>&1; then
          TMUX_TARGET=(new-window -d -t "=$SESS:")
        fi
        remaining=$((ATTEMPT_END - SECONDS))
        if [ "$remaining" -gt 0 ]; then
          HANDOFF_STARTED=1
          fm_handoff_event "$event" "$NONCE" "$attempt" "$PRED_PID" "$(fm_handoff_endpoint_handle || true)" awaiting_ack
          successor_argv
          fm_run_timed "$remaining" "${BACKEND_EXEC[@]}" tmux "${TMUX_TARGET[@]}" -c "$FM_HOME" -n firstmate "${SUCC_ARGV[@]}" > "$STATE/.handoff-launch-result" 2>&1 || true
        fi
        ;;
    esac
  else
    fail_handoff deadline
  fi
  while :; do
    # Check success before the deadline: a transfer that committed just before
    # expiry must be accepted even if the parent was scheduled after expiry.
    if transfer_committed; then
      take_claim || fail_handoff claim_busy
      if transfer_committed && record_completion; then exit 0; fi
      fm_lock_release "$STATE/.lock.acquire"
      CLAIM_HELD=0
    fi
    [ "$SECONDS" -lt "$ATTEMPT_END" ] || break
    sleep 0.2
  done
  # Revoke the attempt under the very same lock the successor uses for CAS.
  if ! take_claim; then
    fail_handoff claim_busy
  fi
  if [ "$(cat "$STATE/.lock")" != "$PRED_PID" ]; then
    # A transfer may have raced the final inspection; do not launch another.
    if record_completion; then exit 0; fi
    fail_handoff ownership_changed
  fi
  rm -f "$STATE/.handoff-pending"
  fm_lock_release "$STATE/.lock.acquire"
  CLAIM_HELD=0
done
fail_handoff deadline
