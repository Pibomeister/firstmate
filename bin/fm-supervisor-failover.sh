#!/usr/bin/env bash
# fm-supervisor-failover.sh - relaunch a supervisor whose pool ran out onto a
# comparable model on another verified runtime, keeping its home and work.
#
# Usage:
#   fm-supervisor-failover.sh primary <handoff-file> [options]
#   FM_HOME=<owning-home> fm-supervisor-failover.sh secondmate <id> [options]
# Options:
#   --candidate <harness:model>  a comparable runtime, in preference order;
#                                repeatable. Without one, the candidates come
#                                from config/supervisor-failover-candidates
#                                (docs/configuration.md "Supervisor failover"),
#                                and without that file from the local entries
#                                of the provider failover order other than
#                                claude (bin/fm-failover-lib.sh).
#   --reason <token>             why the supervisor needs replacing
#                                (default: <current harness>_pool_exhausted)
#
# The captain declares which models are comparable: a candidate must keep the
# supervisor's reasoning class, so this script never invents one, and an empty
# list leaves only the Claude account step.
# Candidates are judged in this order, and the first with measured headroom
# wins (bin/fm-supervisor-failover-lib.sh owns the quota verdict):
#   1. each other config/claude-accounts entry that is already signed in
#      (claude auth status), on a claude successor; a secondmate takes this
#      step only while it runs on Claude. For a primary, Orca agent
#      launch cannot select an account, so on Orca this step is skipped, and
#      the current account is CLAUDE_CONFIG_DIR, or ordinary when it is unset.
#      A secondmate's current account is the one its record names, else its
#      pin; it moves to the new entry for that relaunch only, through
#      fm-control.sh relaunch --account --provider-failover, and its pin file
#      is never edited.
#   2. each candidate whose harness is claude, codex, or agy and differs from
#      the current one. Muse and every other adapter are refused. For a
#      primary, agy needs the tmux backend and a home agy already trusts, as
#      the handoff launcher requires. A secondmate is judged on the backend its
#      record names, where fm-control relaunches agy on tmux or herdr only.
# A candidate with exhausted or unmeasured quota, a missing executable, no
# sign-in, or a secondmate Claude launch that fm-control's account rules would
# refuse (a missing, unresolvable, or signed-out pin) is skipped with its
# reason; nothing here signs in, spends, or edits
# config/claude-account, config/claude-accounts, config/pi-account, or any
# secondmate pin.
# A primary hands off through bin/fm-handoff-launch.sh --harness --model
# [--account] --reason, which re-runs the preflight and owns the verified lock
# transfer, so the home, state/<id>.meta records, backlog, and checks carry
# over unchanged. Run it in the background like the launcher.
# A secondmate is relaunched in its own home through bin/fm-control.sh <id>
# relaunch --harness --model --note (plus --account --provider-failover for
# the account step), which owns the stop, the checkpoint, and every pre-stop
# refusal. Its harness pin is left unchanged, so a later
# relaunch without --harness, such as the watcher's automatic one, returns the
# secondmate to its configured runtime.
#
# Output (stdout): one `candidate ...` line per evaluated candidate, then
# `choice ...`, then the delegate's own output and `replaced ...` or
# `failed rc=<n> ...`. The choice and result are also appended to
# state/supervisor-failover.log.
# Exit 0 on a replacement, 1 when no candidate is eligible,
# 2 for a usage or configuration error, otherwise the delegate's exit status,
# which can also be 1; the final `none` or `failed` line tells them apart.
# Test-only: FM_TEST_SEAM=1 enables FM_HANDOFF_TEST_HARNESS (the primary's
# current harness) and FM_SUPERVISOR_FAILOVER_TEST_BIN (a directory holding
# the fm-handoff-launch.sh and fm-control.sh to delegate to).
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 2; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  primary|secondmate) SCOPE=$1 ;;
  *) die 'expected primary <handoff-file> or secondmate <id>; see --help' ;;
esac
[ $# -ge 2 ] || die "$SCOPE needs its target"
TARGET=$2
shift 2
CANDIDATES=()
REASON=''
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) [ -n "${2:-}" ] || die '--candidate needs <harness:model>'; CANDIDATES+=("$2"); shift 2 ;;
    --reason) [ -n "${2:-}" ] || die '--reason needs a token'; REASON=$2; shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
case "$REASON" in *[!A-Za-z0-9_.:-]*) die '--reason must be one token of letters, digits, _ . : -' ;; esac

if [ "$SCOPE" = secondmate ]; then
  [ -n "${FM_HOME:-}" ] || die 'FM_HOME must explicitly name the home that owns the secondmate'
else
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
fi
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-supervisor-failover-lib.sh
. "$SCRIPT_DIR/fm-supervisor-failover-lib.sh"
# shellcheck source=bin/fm-failover-lib.sh
. "$SCRIPT_DIR/fm-failover-lib.sh"

DELEGATE_BIN=$SCRIPT_DIR
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SUPERVISOR_FAILOVER_TEST_BIN:-}" ]; then
  DELEGATE_BIN=$FM_SUPERVISOR_FAILOVER_TEST_BIN
fi

if [ "${#CANDIDATES[@]}" -eq 0 ] && [ -e "$CONFIG/supervisor-failover-candidates" ]; then
  [ -f "$CONFIG/supervisor-failover-candidates" ] && [ -r "$CONFIG/supervisor-failover-candidates" ] \
    || die 'config/supervisor-failover-candidates must be a readable regular file'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    CANDIDATES+=("$line")
  done < "$CONFIG/supervisor-failover-candidates"
fi
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  # The provider failover order is the captain's comparable-model list too:
  # its local non-Claude entries, in order (Claude accounts are step 1).
  err=$(fm_failover_order_load "$CONFIG") || die "${err#error: }"
  fm_failover_order_load "$CONFIG" >/dev/null
  for entry in ${FM_FO_ENTRIES[@]+"${FM_FO_ENTRIES[@]}"}; do
    IFS=$FM_FO_SEP read -r fo_harness fo_model _fo_account fo_host <<< "$entry"
    [ "$fo_harness" != claude ] && [ -z "$fo_host" ] || continue
    CANDIDATES+=("$fo_harness:${fo_model:-default}")
  done
fi
for c in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  case "$c" in
    ''|:*|*:-*|*[!A-Za-z0-9._/:-]*) die "invalid candidate '$c': expected <harness:model>" ;;
  esac
done

BACKEND=$(fm_backend_name 2>/dev/null) || BACKEND=unknown
if [ "$SCOPE" = primary ]; then
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_root_is_secondmate_home "$FM_HOME" && die 'a second mate asks its parent to relaunch it'
  case "$BACKEND" in orca|tmux) ;; *) die "the handoff launcher has no successor launcher for backend '$BACKEND'" ;; esac
  [ -f "$TARGET" ] && [ -r "$TARGET" ] || die 'supply a readable handoff document'
  FROM_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || FROM_HARNESS=unknown
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HANDOFF_TEST_HARNESS:-}" ]; then FROM_HARNESS=$FM_HANDOFF_TEST_HARNESS; fi
  FROM_MODEL=default
  FROM_ACCOUNT=${CLAUDE_CONFIG_DIR:-ordinary}
else
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_task_id_creation_valid "$TARGET" || die "invalid secondmate id: $TARGET"
  META="$STATE/$TARGET.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || die "no regular record for $TARGET in $STATE"
  [ "$(fm_meta_get "$META" kind)" = secondmate ] || die "$TARGET is not a secondmate"
  [ -z "$(fm_meta_get "$META" remote_host)" ] || die "$TARGET runs on another host; run failover in the home that hosts it"
  FROM_HARNESS=$(fm_meta_get "$META" harness)
  FROM_MODEL=$(fm_meta_get "$META" model)
  FROM_MODEL=${FROM_MODEL:-default}
  FROM_ACCOUNT=$(fm_meta_get "$META" account)
  FROM_ACCOUNT=${FROM_ACCOUNT:-pin}
  BACKEND=$(fm_meta_get "$META" backend)
  BACKEND=${BACKEND:-tmux}
fi
[ -n "$REASON" ] || REASON="$(fm_failover_token "$FROM_HARNESS")_pool_exhausted"
FROM="$(fm_failover_token "$FROM_HARNESS"):$(fm_failover_token "$FROM_MODEL"):$(fm_failover_token "$FROM_ACCOUNT")"
LOG_SCOPE=$SCOPE
[ "$SCOPE" = primary ] || LOG_SCOPE="secondmate:$TARGET"

CHOICE_HARNESS='' CHOICE_MODEL='' CHOICE_ACCOUNT='' CHOICE_REPORT_ACCOUNT='' CHOICE_VIA='' CHOICE_QUOTA=''
report() { # <harness> <model> <account> <result>
  printf 'candidate harness=%s model=%s account=%s %s\n' "$1" "$(fm_failover_token "$2")" "$(fm_failover_token "$3")" "$4"
}
take() { # <harness> <model> <launch-account> <report-account> <via> <quota>
  CHOICE_HARNESS=$1 CHOICE_MODEL=$2 CHOICE_ACCOUNT=$3 CHOICE_REPORT_ACCOUNT=$4 CHOICE_VIA=$5 CHOICE_QUOTA=$6
}

# Step 1: another signed-in Claude account. A secondmate takes it only while
# it runs on Claude; a mate on another runtime returns to Claude on its pin.
ACCOUNT_STEP=1
[ "$SCOPE" = primary ] || [ "$FROM_HARNESS" = claude ] || ACCOUNT_STEP=0
if [ "$SCOPE" = secondmate ] && [ "$ACCOUNT_STEP" = 1 ] && [ "$FROM_ACCOUNT" = pin ]; then
  # An unrecorded account is the mate's pin; name it so it is not re-chosen.
  if selection=$(fm_worker_account_select claude "$CONFIG" default claude '' "$TARGET" 2>/dev/null) && [ -n "$selection" ]; then
    FROM_ACCOUNT=${selection%%$'\t'*}
  fi
fi
listed=''
[ "$ACCOUNT_STEP" = 0 ] || listed=$(fm_worker_account_list claude "$CONFIG") || exit 2
claude_bin=$(command -v claude 2>/dev/null) || claude_bin=''
while IFS= read -r entry; do
  [ -n "$entry" ] && [ -z "$CHOICE_HARNESS" ] || continue
  if { [ "$FROM_HARNESS" = claude ] || [ "$SCOPE" = secondmate ]; } && [ "$entry" = "$FROM_ACCOUNT" ]; then
    report claude default "$entry" 'skip=current_account'
    continue
  fi
  if [ "$SCOPE" = primary ] && [ "$BACKEND" != tmux ]; then
    report claude default "$entry" "skip=${BACKEND}_cannot_select_account"
    continue
  fi
  root=$entry
  [ "$root" != ordinary ] || root=''
  if [ -z "$claude_bin" ] || ! fm_worker_account_check claude "$entry" "$root" "$claude_bin" '' config/claude-accounts 2>/dev/null; then
    report claude default "$entry" 'skip=not_signed_in'
    continue
  fi
  [ -n "$root" ] || root="${HOME:?HOME is required to measure the ordinary account}/.claude"
  if quota=$(fm_failover_quota_check claude default "$root"); then
    report claude default "$entry" "$quota"
    take claude default "$entry" "$entry" account_switch "$quota"
  else
    report claude default "$entry" "$quota"
  fi
done <<< "$listed"

# Step 2: a comparable model on another verified runtime.
for c in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  [ -z "$CHOICE_HARNESS" ] || break
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" != "$c" ] && [ -n "$model" ] || model=default
  if ! why=$(fm_failover_runtime_supported "$harness" "$SCOPE"); then
    report "$(fm_failover_token "$harness")" "$model" none "skip=refused why=$(fm_failover_token "$why")"
    continue
  fi
  if [ "$harness" = "$FROM_HARNESS" ]; then
    report "$harness" "$model" none 'skip=same_runtime_as_current'
    continue
  fi
  if [ "$harness" = agy ]; then
    case "$SCOPE:$BACKEND" in
      primary:tmux | secondmate:tmux | secondmate:herdr) ;;
      *)
        report "$harness" "$model" none "skip=agy_unverified_on_$(fm_failover_token "$BACKEND")"
        continue
        ;;
    esac
    if [ "$SCOPE" = primary ] && ! fm_failover_agy_trusted "$FM_HOME"; then
      report "$harness" "$model" none 'skip=agy_untrusted_home'
      continue
    fi
  fi
  if { [ "$BACKEND" = tmux ] || [ "$BACKEND" = herdr ]; } && ! command -v "$harness" >/dev/null 2>&1; then
    report "$harness" "$model" none 'skip=executable_missing'
    continue
  fi
  root=''
  account=ambient
  if [ "$harness" = claude ] && [ "$SCOPE" = secondmate ]; then
    # fm-control applies these launch account rules before it stops the
    # secondmate, so a candidate they refuse must not win here.
    if ! selection=$(fm_worker_account_select claude "$CONFIG" "$model" claude '' "$TARGET" 2>&1); then
      report "$harness" "$model" pin "skip=pin_unresolved why=$(fm_failover_token "$selection")"
      continue
    fi
    if [ -n "$selection" ]; then
      account=pin
      root=${selection#*$'\t'}
      root=${root%%$'\t'*}
      [ -n "$root" ] || root="${HOME:?HOME is required}/.claude"
    fi
  fi
  if quota=$(fm_failover_quota_check "$harness" "$model" "$root"); then
    report "$harness" "$model" "$account" "$quota"
    take "$harness" "$model" '' "$account" runtime_switch "$quota"
  else
    report "$harness" "$model" "$account" "$quota"
  fi
done

if [ -z "$CHOICE_HARNESS" ]; then
  fm_failover_log "event=failover_none scope=$LOG_SCOPE from=$FROM reason=$REASON"
  printf 'none scope=%s from=%s reason=no_eligible_runtime\n' "$LOG_SCOPE" "$FROM"
  exit 1
fi
CHOICE="scope=$LOG_SCOPE from=$FROM harness=$CHOICE_HARNESS model=$(fm_failover_token "$CHOICE_MODEL") account=$(fm_failover_token "$CHOICE_REPORT_ACCOUNT") via=$CHOICE_VIA reason=$REASON $CHOICE_QUOTA"
printf 'choice %s\n' "$CHOICE"
fm_failover_log "event=failover_choice $CHOICE"

rc=0
if [ "$SCOPE" = primary ]; then
  args=(--harness "$CHOICE_HARNESS" --reason "$REASON")
  [ "$CHOICE_MODEL" = default ] || args+=(--model "$CHOICE_MODEL")
  [ -z "$CHOICE_ACCOUNT" ] || args+=(--account "$CHOICE_ACCOUNT")
  bash "$DELEGATE_BIN/fm-handoff-launch.sh" "${args[@]}" "$TARGET" || rc=$?
else
  args=(--harness "$CHOICE_HARNESS")
  [ "$CHOICE_MODEL" = default ] || args+=(--model "$CHOICE_MODEL")
  [ -z "$CHOICE_ACCOUNT" ] || args+=(--account "$CHOICE_ACCOUNT" --provider-failover)
  note="Supervisor failover: $FROM_HARNESS pool ran out ($REASON); relaunched on $CHOICE_HARNESS $CHOICE_MODEL ($CHOICE_QUOTA)."
  bash "$DELEGATE_BIN/fm-control.sh" "$TARGET" relaunch "${args[@]}" --note "$note" || rc=$?
fi
if [ "$rc" -eq 0 ]; then
  fm_failover_log "event=failover_result result=replaced $CHOICE"
  printf 'replaced %s\n' "$CHOICE"
else
  fm_failover_log "event=failover_result result=failed rc=$rc $CHOICE"
  printf 'failed rc=%s %s\n' "$rc" "$CHOICE"
fi
exit "$rc"
