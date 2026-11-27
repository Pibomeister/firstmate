#!/usr/bin/env bash
# fm-failover.sh - move a worker or the captain off a provider that refused it
# onto the next provider in this home's failover order, and measure that order.
# A refusal is an HTTP 429 or rate limit, a usage limit, or a billing, credit,
# past-due, subscription, or account-hold refusal. The stall check
# (bin/fm-stall-watch.sh) also passes --reason api_error for another API error
# that ended the turn, and --reason stalled for an agent left idle with open
# work after one nudge.
#
# Usage:
#   fm-failover.sh plan
#   fm-failover.sh preflight
#   fm-failover.sh hook <task-id|captain> [--gen <token>] [--state <dir>]
#   fm-failover.sh worker <task-id> [--reason <class>]
#   fm-failover.sh captain [--reason <class>]
#
# This is the one entry point for provider failover; bin/fm-failover-lib.sh
# owns the order file and the provider-error record, and docs/configuration.md
# "Provider failover" owns the operator contract.
#
#   plan       The order with the newest preflight verdict of every runtime it
#              expands to, one `plan runtime=<label> verdict=<eligible|
#              excluded|unmeasured> ...` line each; this is the night plan, and
#              worker and captain skip what it excludes.
#   preflight  For every runtime the order expands to (each declared Claude
#              account for claude@next), makes one real one-line call through
#              that runtime's own CLI (claude -p, codex exec, droid exec) and
#              reads its five-hour and weekly percent left from quota-axi
#              (a Claude read passes --allow-claude-inference, one more small
#              call). A runtime whose call fails, whose weekly window reads 0,
#              or whose five-hour window reads below 30% is excluded; an
#              unreadable window is disclosed and does not exclude.
#              Rewrites state/failover-preflight.tsv:
#              <epoch> <runtime> <verdict> <call> <five_hour> <weekly> <why>.
#              A verdict older than FM_FAILOVER_PREFLIGHT_MAX_AGE (43200s) is
#              ignored. Sends one short prompt per runtime and account, each
#              a full non-interactive CLI session, plus one quota-axi read;
#              buys nothing.
#   hook       The Claude StopFailure hook: maps the payload on stdin to a
#              class and records it. For `captain` it then runs `captain` in
#              the hook's own process, only in a genuine primary checkout whose
#              session holds the lock; anywhere else, and for any other error,
#              it does nothing. Always exits 0.
#   worker     Relaunches a ship, scout, or second mate in its same local copy,
#              branch, and gates on the first eligible runtime after its
#              current one, through bin/fm-control.sh relaunch --harness
#              [--model] [--account] --provider-failover --note, which closes a
#              usage-limit picker without typing into it. A second mate moved
#              to another declared Claude account runs on it for that launch
#              only; its own account pin file is never edited. A runtime is
#              skipped when it is the current one (an unpinned Claude worker
#              counts as this home's inherited account), excluded by the plan,
#              not verified for the task's kind (bin/fm-control-lib.sh), not a
#              supervisor runtime for a second mate
#              (bin/fm-supervisor-failover-lib.sh), a move
#              off Claude that bin/fm-quota-reroute.sh claude-tooling refuses,
#              missing its executable, an undeclared or signed-out Claude
#              account, or exhausted by quota-axi (unmeasured quota is
#              disclosed and does not skip). Those skips spend no attempt. A
#              failed relaunch moves on to the next runtime.
#              Records each switch with bin/fm-dispatch-log.sh failover and in
#              state/.failover-<task-id>, and removes the task's record.
#   captain    Writes a handoff with bin/fm-ledger.sh handoff and starts a
#              successor on the first eligible primary runtime (claude, codex,
#              or agy; a Claude account switch on tmux only) through
#              bin/fm-handoff-launch.sh, which verifies the lock transfer;
#              the successor then closes this session's terminal through
#              bin/fm-handoff-close.sh. Runs only when this session holds the
#              lock and the home needs supervision (bin/fm-supervision-lib.sh).
#              Records the switch like worker, in state/.failover-captain.
#
# Output: one `candidate runtime=<label> ...` line per evaluated runtime, then
# `switched task=<id> from=<label> to=<label> reason=<class>`, or `none ...`.
# Exit 0 on a switch, 1 when no runtime took over,
# 2 for a usage or configuration error, 3 when the attempt bound holds
# (FM_FAILOVER_MAX_ATTEMPTS, default 3, captain 2, inside
# FM_FAILOVER_WINDOW_SECS, default 3600), 5 when
# another failover of the same target holds its lock, 6 when the target needs
# none (a finished, stopped, or not ship/scout task, or a captain with no
# lock or no open work).
# Bounds: each relaunch FM_FAILOVER_RELAUNCH_TIMEOUT (300s), each handoff
# FM_FAILOVER_HANDOFF_TIMEOUT (900s), each preflight call
# FM_FAILOVER_CALL_TIMEOUT (90s). FM_FAILOVER_DEADLINE (an epoch, set by the
# watcher) caps each relaunch at the time left and starts none with less than
# FM_FAILOVER_MIN_RELAUNCH_SECS (up to 30s) left, so the whole walk ends on time.
# FM_CONTROL_BIN overrides the fm-control.sh it calls, as for the watcher.
# Test-only: FM_TEST_SEAM=1 enables FM_FAILOVER_TEST_BIN (a directory holding
# the fm-control.sh, fm-handoff-launch.sh, and fm-ledger.sh to call),
# FM_TEST_QUOTA_REROUTE (the claude-tooling check to run, as fm-control.sh),
# FM_FAILOVER_TEST_HARNESS (the captain's current harness), and
# FM_FAILOVER_TEST_LOCK_OWNER=1 (treat this process as the lock owner), and
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 2; }

CMD=${1:-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  plan|preflight|hook|worker|captain) shift ;;
  *) usage >&2; exit 2 ;;
esac
TARGET=''
case "$CMD" in
  hook|worker)
    TARGET=${1:-}
    [ -n "$TARGET" ] || die "$CMD needs its target"
    shift
    ;;
esac
CLASS='' GEN='' STATE_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) [ -n "${2:-}" ] || die "$1 needs a value"; CLASS=$2; shift 2 ;;
    --gen) [ -n "${2:-}" ] || die '--gen needs a token'; GEN=$2; shift 2 ;;
    --state) [ -n "${2:-}" ] || die '--state needs a directory'; STATE_ARG=$2; shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${STATE_ARG:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

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
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-failover-lib.sh
. "$SCRIPT_DIR/fm-failover-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

tok() { fm_failover_token "$1"; }
now() { date +%s; }
iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
int_or() { case "${1:-}" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$((10#$1))" ;; esac; }

DELEGATE_BIN=$SCRIPT_DIR
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_FAILOVER_TEST_BIN:-}" ]; then
  DELEGATE_BIN=$FM_FAILOVER_TEST_BIN
fi
CONTROL_BIN=${FM_CONTROL_BIN:-$DELEGATE_BIN/fm-control.sh}
RELAUNCH_TIMEOUT=$(int_or "${FM_FAILOVER_RELAUNCH_TIMEOUT:-}" 300)
HANDOFF_TIMEOUT=$(int_or "${FM_FAILOVER_HANDOFF_TIMEOUT:-}" 900)
CALL_TIMEOUT=$(int_or "${FM_FAILOVER_CALL_TIMEOUT:-}" 90)
WINDOW_SECS=$(int_or "${FM_FAILOVER_WINDOW_SECS:-}" 3600)
PREFLIGHT_MAX_AGE=$(int_or "${FM_FAILOVER_PREFLIGHT_MAX_AGE:-}" 43200)
PREFLIGHT_FILE="$STATE/failover-preflight.tsv"
DEADLINE=$(int_or "${FM_FAILOVER_DEADLINE:-}" '')
min_relaunch_default=30
if [ -n "$DEADLINE" ]; then
  min_relaunch_default=$(( (DEADLINE - $(now)) / 4 ))
  [ "$min_relaunch_default" -ge 1 ] || min_relaunch_default=1
  [ "$min_relaunch_default" -le 30 ] || min_relaunch_default=30
fi
MIN_RELAUNCH_SECS=$(int_or "${FM_FAILOVER_MIN_RELAUNCH_SECS:-}" "$min_relaunch_default")

load_order() {
  local err
  if ! err=$(fm_failover_order_load "$CONFIG"); then
    die "${err#error: }"
  fi
  fm_failover_order_load "$CONFIG" >/dev/null
  # Preflight verdicts and log lines name a runtime by its label, and a label
  # keeps only an account path's last segment, so two such paths would answer
  # for each other.
  err=$(expand_entries 1 '' | awk -F "$FM_FO_SEP" '($5 in acct) && acct[$5] != $3 { print $5; exit } { acct[$5] = $3 }')
  [ -z "$err" ] || die "two Claude accounts in the failover order share the label $err; give each declared account directory a distinct last path segment"
}

# expand_entries <include-current-account:0|1> <current-claude-account>
# Prints `<harness> <model> <account> <host> <label>`, joined by FM_FO_SEP, per
# runtime, with
# claude@next expanded to every declared account other than the current one
# (all of them when the first argument is 1).
expand_entries() {
  local all=$1 current=$2 entry harness model account host listed a
  listed=$(fm_worker_account_list claude "$CONFIG" 2>/dev/null) || listed=''
  for entry in ${FM_FO_ENTRIES[@]+"${FM_FO_ENTRIES[@]}"}; do
    IFS=$FM_FO_SEP read -r harness model account host <<< "$entry"
    if [ "$account" = next ]; then
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        [ "$all" = 1 ] || ! same_account "$a" "$current" || continue
        printf "%s$FM_FO_SEP%s$FM_FO_SEP%s$FM_FO_SEP%s$FM_FO_SEP%s\n" "$harness" "$model" "$a" "$host" "$(fm_failover_label "$harness" "$model" "$a")"
      done <<< "$listed"
    else
      printf "%s$FM_FO_SEP%s$FM_FO_SEP%s$FM_FO_SEP%s$FM_FO_SEP%s\n" "$harness" "$model" "$account" "$host" "$(fm_failover_label "$harness" "$model" "$account")"
    fi
  done
}

# preflight_verdict <label>: prints `<verdict>\t<why>` from a fresh preflight.
preflight_verdict() {
  local cutoff
  [ -f "$PREFLIGHT_FILE" ] || return 1
  cutoff=$(( $(now) - PREFLIGHT_MAX_AGE ))
  awk -F '\t' -v l="$1" -v c="$cutoff" '
    $2 == l && $1 + 0 >= c + 0 {
      v = $3 "\t" $7
      if ($5 ~ /^[0-9]+(\.[0-9]+)?$/ && $5 + 0 < 30) v = "excluded\tfive_hour_below_30"
    }
    END { if (v == "") exit 1; print v }
  ' "$PREFLIGHT_FILE"
}

claude_root() {  # <account-entry> -> config root for quota reads
  case "$1" in
    ''|ordinary) printf '%s\n' "${HOME:?HOME is required}/.claude" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# same_account <account-entry> <account-entry>: true when both name one Claude
# config root (`ordinary` and $HOME/.claude are the same account); an empty
# entry names no account and matches nothing.
same_account() {
  local x y
  [ -n "$1" ] && [ -n "$2" ] || return 1
  x=$(claude_root "$1") y=$(claude_root "$2")
  [ "${x%/}" = "${y%/}" ]
}

claude_signed_in() {  # <account-entry>
  local root=$1 bin
  bin=$(command -v claude 2>/dev/null) || return 1
  [ "$root" != ordinary ] || root=''
  fm_worker_account_check claude "$1" "$root" "$bin" '' config/claude-accounts >/dev/null 2>&1
}

account_declared() {  # <account-entry>
  local listed
  listed=$(fm_worker_account_list claude "$CONFIG" 2>/dev/null) || return 1
  printf '%s\n' "$listed" | grep -Fxq -- "$1"
}

# leaving_claude_refused <worktree> <kind> <id>: true when fm-control.sh would
# refuse moving this task off Claude, by the same claude-tooling check it runs
# before it stops anything (any exit other than 1 is a refusal).
LEAVING_CLAUDE_VERDICT=''
leaving_claude_refused() {
  local helper=$SCRIPT_DIR/fm-quota-reroute.sh rc=0
  local -a args=(claude-tooling --worktree "$1")
  if [ -n "$LEAVING_CLAUDE_VERDICT" ]; then
    [ "$LEAVING_CLAUDE_VERDICT" = refused ]
    return
  fi
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_QUOTA_REROUTE:-}" ]; then
    helper=$FM_TEST_QUOTA_REROUTE
  fi
  [ "$2" != secondmate ] || args+=(--mate "$3")
  LEAVING_CLAUDE_VERDICT=refused
  [ -n "$1" ] || return 0
  "$helper" "${args[@]}" >/dev/null 2>&1 </dev/null || rc=$?
  [ "$rc" -ne 1 ] || LEAVING_CLAUDE_VERDICT=allowed
  [ "$LEAVING_CLAUDE_VERDICT" = refused ]
}

# --- candidate evaluation ------------------------------------------------------
CAND=()
# Worker scope only: the task's kind, local copy, and id, which decide whether
# fm-control.sh would refuse a runtime before it stops anything.
EVAL_KIND='' EVAL_WT=''
# evaluate <scope worker|primary> <from-harness> <from-model> <from-account> <backend> <ledger>
# Fills CAND with eligible `<harness> <model> <account> <label> <quota>` rows,
# joined by FM_FO_SEP, in order, and prints one candidate line per runtime.
evaluate() {
  local scope=$1 from_h=$2 from_m=$3 from_a=$4 backend=$5 ledger=$6 h m a host label pv why quota rc root rows current=0 index=0
  CAND=()
  FM_EVALUATE_DEADLINE=''
  rows=$(expand_entries 1 '')
  while IFS=$FM_FO_SEP read -r h m a host label; do
    [ -n "$h" ] || continue
    index=$((index + 1))
    [ -z "$host" ] && [ "$h" = "$from_h" ] && [ "${m:-default}" = "${from_m:-default}" ] || continue
    if [ "$h" != claude ] || { [ -n "$a" ] && same_account "$a" "$from_a"; }; then
      current=$index
      break
    fi
  done <<< "$rows"
  if [ "$current" -gt 0 ]; then
    rows=$(printf '%s\n' "$rows" | awk -v c="$current" 'NR > c { print } NR <= c { earlier[NR] = $0 } END { for (i = 1; i <= c; i++) print earlier[i] }')
  fi
  while IFS=$FM_FO_SEP read -r h m a host label; do
    [ -n "$h" ] || continue
    if [ -f "$ledger" ] && awk -F '\t' -v l="$label" -v c="$(( $(now) - WINDOW_SECS ))" \
      '$1 >= c && (($2 == "attempt" && ($3 == l || $4 == l)) || ($2 == "failed" && $4 == l)) { found = 1 } END { exit !found }' "$ledger"; then
      printf 'candidate runtime=%s skip=refused_in_window\n' "$label"
      continue
    fi
    if [ "$h" = claude ] && [ -n "$a" ] && same_account "$a" "$from_a"; then
      continue
    fi
    if [ -n "$host" ]; then
      host_skip "${TARGET:-captain}" "$from" "$label" "$host"
      why=$FM_HOST_SKIP_REASON
      printf 'candidate runtime=%s host=%s skip=%s\n' "$label" "$(tok "$host")" "$(tok "$why")"
      continue
    fi
    if [ "$h" = "$from_h" ] && { [ "$h" != claude ] || [ -z "$a" ] || same_account "$a" "$from_a"; }; then
      printf 'candidate runtime=%s skip=same_runtime_as_current\n' "$label"
      continue
    fi
    if pv=$(preflight_verdict "$label"); then
      if [ "${pv%%$'\t'*}" = excluded ]; then
        printf 'candidate runtime=%s skip=preflight_excluded why=%s\n' "$label" "$(tok "${pv#*$'\t'}")"
        continue
      fi
    fi
    if [ "$scope" = worker ]; then
      if ! fm_control_harness_supports_kind "$h" "$EVAL_KIND"; then
        printf 'candidate runtime=%s skip=not_verified_for_%s\n' "$label" "$(tok "$EVAL_KIND")"
        continue
      fi
      if [ "$EVAL_KIND" = secondmate ] && ! why=$(fm_failover_runtime_supported "$h" secondmate); then
        printf 'candidate runtime=%s skip=refused why=%s\n' "$label" "$(tok "$why")"
        continue
      fi
      if [ "$from_h" = claude ] && [ "$h" != claude ] && leaving_claude_refused "$EVAL_WT" "$EVAL_KIND" "$TARGET"; then
        printf 'candidate runtime=%s skip=claude_tooling_blocks_leaving_claude\n' "$label"
        continue
      fi
    fi
    if [ "$scope" = primary ]; then
      if ! why=$(fm_failover_runtime_supported "$h" primary); then
        printf 'candidate runtime=%s skip=refused why=%s\n' "$label" "$(tok "$why")"
        continue
      fi
      if [ -n "$a" ] && [ "$backend" != tmux ]; then
        printf 'candidate runtime=%s skip=%s_cannot_select_account\n' "$label" "$(tok "$backend")"
        continue
      fi
      if [ "$h" = agy ] && { [ "$backend" != tmux ] || ! fm_failover_agy_trusted "$FM_HOME"; }; then
        printf 'candidate runtime=%s skip=agy_needs_tmux_and_a_trusted_home\n' "$label"
        continue
      fi
    fi
    case "$backend" in
      tmux|herdr)
        if ! command -v "$h" >/dev/null 2>&1; then
          printf 'candidate runtime=%s skip=executable_missing\n' "$label"
          continue
        fi
        ;;
    esac
    root=''
    if [ -n "$a" ]; then
      if ! account_declared "$a"; then
        printf 'candidate runtime=%s skip=account_not_declared\n' "$label"
        continue
      fi
      if ! claude_signed_in "$a"; then
        printf 'candidate runtime=%s skip=not_signed_in\n' "$label"
        continue
      fi
      root=$(claude_root "$a")
    fi
    if [ -n "$DEADLINE" ] && [ $(( DEADLINE - $(now) )) -lt "$MIN_RELAUNCH_SECS" ]; then
      printf 'candidate runtime=%s skip=deadline\n' "$label"
      FM_EVALUATE_DEADLINE=$label
      break
    fi
    rc=0
    quota=$(fm_failover_quota_check "$h" "${m:-default}" "$root") || rc=$?
    if [ "$rc" -eq 1 ]; then
      printf 'candidate runtime=%s skip=quota_exhausted %s\n' "$label" "$quota"
      continue
    fi
    printf 'candidate runtime=%s eligible %s\n' "$label" "$quota"
    CAND+=("$h$FM_FO_SEP$m$FM_FO_SEP$a$FM_FO_SEP$label$FM_FO_SEP$quota")
    break
  done <<< "$rows"
}

# --- attempt ledger and lock ---------------------------------------------------
ledger_attempts() {  # <ledger>
  local cutoff
  [ -f "$1" ] || { printf '0\n'; return 0; }
  cutoff=$(( $(now) - WINDOW_SECS ))
  awk -F '\t' -v c="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= c && $2 == "attempt" { n++ } END { print n + 0 }' "$1"
}
ledger_add() {  # <ledger> <event> <from> <to> <reason>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$2" "$3" "$4" "$5" >> "$1"
}
LOCK=''
take_lock() {  # <lockdir>
  # shellcheck source=bin/fm-wake-lib.sh
  command -v fm_lock_try_acquire >/dev/null 2>&1 || . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$STATE"
  fm_lock_try_acquire "$1" || return 1
  LOCK=$1
  trap 'fm_lock_release "$LOCK" 2>/dev/null || true' EXIT
}

dispatch_record() {  # <task> <from> <to> <reason>
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE bash "$SCRIPT_DIR/fm-dispatch-log.sh" failover \
    --task "$1" --from "$2" --to "$3" --reason "$4" >/dev/null 2>&1 \
    || printf 'warning: the dispatch log did not record the switch of %s\n' "$1" >&2
}

dispatch_skip() {
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE bash "$SCRIPT_DIR/fm-dispatch-log.sh" failover-skip \
    --task "$1" --from "$2" --to "$3" --reason "$4" >/dev/null 2>&1 \
    || printf 'warning: the dispatch log did not record the skip of %s\n' "$3" >&2
}

host_skip() {
  local task=$1 from=$2 label=$3 host=$4
  FM_HOST_SKIP_REASON='host worktree handoff not implemented'
  dispatch_skip "$task" "$from" "$label@$host" "$FM_HOST_SKIP_REASON"
}

reason_or_record() {  # <id>
  if [ -n "$CLASS" ]; then
    fm_failover_class_valid "$CLASS" || die '--reason must be rate_limit, usage_limit, billing, api_error, or stalled'
    printf '%s\n' "$CLASS"
    return 0
  fi
  fm_failover_record_class "$STATE" "$1" 2>/dev/null || printf 'rate_limit\n'
}

why_text() {  # <class>: what ended the previous runtime's turn, for the notes
  case "$1" in
    api_error) printf 'ended its turn on an API error from its provider' ;;
    stalled) printf 'stayed idle with open work after a stall-check nudge' ;;
    *) printf 'ended its turn on a %s refusal from its provider' "$1" ;;
  esac
}

# --- plan ---------------------------------------------------------------------
cmd_plan() {
  local h m a host label pv rows
  load_order
  rows=$(expand_entries 1 '')
  while IFS=$FM_FO_SEP read -r h m a host label; do
    [ -n "$h" ] || continue
    if [ -n "$host" ]; then
      printf 'plan runtime=%s host=%s verdict=unmeasured why=host_worktree_handoff_not_implemented\n' "$label" "$(tok "$host")"
    elif pv=$(preflight_verdict "$label"); then
      printf 'plan runtime=%s verdict=%s why=%s\n' "$label" "${pv%%$'\t'*}" "$(tok "${pv#*$'\t'}")"
    else
      printf 'plan runtime=%s verdict=unmeasured why=no_fresh_preflight\n' "$label"
    fi
  done <<< "$rows"
}

# --- preflight -----------------------------------------------------------------
PROBE_PROMPT='Reply with the single word OK.'
# probe_call <harness> <model> <account>: prints ok, or fail:<why>.
probe_call() {
  local h=$1 m=$2 a=$3 dir out rc=0 class var
  local -a cmd=() envs=(env -u CLAUDECODE)
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-failover-probe.XXXXXX") || { printf 'fail:no_scratch_dir\n'; return 0; }
  case "$h" in
    claude)
      if [ -n "$a" ]; then
        for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do envs+=(-u "$var"); done
        [ "$a" = ordinary ] && envs+=(-u CLAUDE_CONFIG_DIR) || envs+=("CLAUDE_CONFIG_DIR=$a")
      fi
      cmd=(claude -p "$PROBE_PROMPT")
      [ -z "$m" ] || cmd+=(--model "$m")
      ;;
    codex)
      cmd=(codex exec --skip-git-repo-check)
      [ -z "$m" ] || cmd+=(-m "$m")
      cmd+=("$PROBE_PROMPT")
      ;;
    droid)
      cmd=(droid exec)
      [ -z "$m" ] || cmd+=(-m "$m")
      cmd+=("$PROBE_PROMPT")
      ;;
    *) rm -rf "$dir"; printf 'unsupported\n'; return 0 ;;
  esac
  if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
    rm -rf "$dir"
    printf 'fail:executable_missing\n'
    return 0
  fi
  out=$( (cd "$dir" && fm_run_timed "$CALL_TIMEOUT" "${envs[@]}" "${cmd[@]}" </dev/null 2>&1) ) || rc=$?
  rm -rf "$dir"
  if class=$(fm_wd_provider_error_class "$out"); then
    printf 'fail:%s\n' "$class"
  elif [ "$rc" -eq 124 ]; then
    printf 'fail:timeout\n'
  elif [ "$rc" -ne 0 ]; then
    printf 'fail:exit_%s\n' "$rc"
  elif ! printf '%s' "$out" | grep -q '[^[:space:]]'; then
    printf 'fail:empty_reply\n'
  else
    printf 'ok\n'
  fi
}

# probe_quota <harness> <account>: prints `<five_hour> <weekly>` percents left,
# `unknown` for an unreadable window.
probe_quota() {
  local h=$1 a=$2 provider snap
  local -a cmd=(quota-axi)
  provider=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || { printf 'unknown unknown\n'; return 0; }
  command -v quota-axi >/dev/null 2>&1 || { printf 'unknown unknown\n'; return 0; }
  snap=$(mktemp "${TMPDIR:-/tmp}/fm-failover-quota.XXXXXX") || { printf 'unknown unknown\n'; return 0; }
  cmd+=(--provider "$provider" --json)
  [ "$provider" != claude ] || cmd+=(--allow-claude-inference)
  if [ "$provider" = claude ] && [ -n "$a" ]; then
    fm_run_timed "$CALL_TIMEOUT" env -u QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR="$(claude_root "$a")" "${cmd[@]}" --profile-only > "$snap" 2>/dev/null </dev/null || true
  else
    fm_run_timed "$CALL_TIMEOUT" "${cmd[@]}" > "$snap" 2>/dev/null </dev/null || true
  fi
  jq -r --arg p "$provider" '
    def pct(f): ([.[] | select(f) | .percentRemaining | numbers] | min) // "unknown";
    [.providers[]? | select(.provider == $p) | select((.state.stale // false) != true) | .windows[]?] as $w
    | "\($w | pct((.kind // "") == "session" or ((.id // "") | test("five_hour|5h"))) | tostring) \($w | pct((.kind // "") == "weekly" or ((.id // "") | test("seven_day|weekly"))) | tostring)"
  ' "$snap" 2>/dev/null || printf 'unknown unknown\n'
  rm -f "$snap"
}

cmd_preflight() {
  local h m a host label call fh wk verdict why rows tmp t
  load_order
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.failover-preflight.XXXXXX") || die 'cannot stage state/failover-preflight.tsv'
  rows=$(expand_entries 1 '')
  while IFS=$FM_FO_SEP read -r h m a host label; do
    [ -n "$h" ] || continue
    t=$(now)
    if [ -n "$host" ]; then
      host_skip captain preflight "$label" "$host"
      call=skipped fh=unknown wk=unknown verdict=unmeasured why=${FM_HOST_SKIP_REASON// /_}
    else
      call=$(probe_call "$h" "$m" "$a")
      read -r fh wk <<< "$(probe_quota "$h" "$a")"
      fh=${fh:-unknown} wk=${wk:-unknown}
      verdict=eligible why=ok
      case "$call" in
        unsupported) verdict=unmeasured why=no_probe_for_harness ;;
        fail:*) verdict=excluded why="call_${call#fail:}" ;;
        *)
          case "$wk" in ''|unknown|*[!0-9.]*) ;; *) if awk -v v="$wk" 'BEGIN { exit !(v < 1) }'; then verdict=excluded why=weekly_exhausted; fi ;; esac
          if [ "$verdict" = eligible ]; then
            case "$fh" in ''|unknown|*[!0-9.]*) why=five_hour_unmeasured ;;
              *) if awk -v v="$fh" 'BEGIN { exit !(v < 30) }'; then verdict=excluded why=five_hour_below_30; fi ;;
            esac
          fi
          ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$label" "$verdict" "$(tok "$call")" "$fh" "$wk" "$why" >> "$tmp"
    printf 'preflight runtime=%s verdict=%s call=%s five_hour=%s weekly=%s why=%s\n' "$label" "$verdict" "$(tok "$call")" "$fh" "$wk" "$why"
  done <<< "$rows"
  mv -f "$tmp" "$PREFLIGHT_FILE"
}

# --- hook ---------------------------------------------------------------------
valid_target() {
  [ "$1" = captain ] && return 0
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_task_id_creation_valid "$1"
}

cmd_hook() {
  local payload class
  payload=$(cat 2>/dev/null || true)
  valid_target "$TARGET" 2>/dev/null || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  fm_hook_payload_is_foreign_host "$payload" && exit 0
  if [ -n "$payload" ] && printf '%s' "$payload" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1; then
    exit 0
  fi
  class=$(fm_failover_hook_class "$payload") || exit 0
  if [ "$TARGET" = captain ]; then
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
    captain_lock_owner || exit 0
  fi
  [ -d "$STATE" ] || exit 0
  fm_failover_record_write "$STATE" "$TARGET" "$class" claude-hook "$GEN" "$(printf '%s' "$payload" | jq -r '.error // empty' 2>/dev/null)" || exit 0
  if [ "$TARGET" = captain ]; then
    CLASS=$class
    ( cmd_captain ) >> "$STATE/failover-captain.log" 2>&1 || true
  fi
  exit 0
}

# --- worker --------------------------------------------------------------------
cmd_worker() {
  local meta kind wt from_h from_m from_a run_a pin backend from gen published_gen published_h reason ledger max attempts statusf last branch note row h m a label quota out rc detail rto left why
  valid_target "$TARGET" && [ "$TARGET" != captain ] || die "invalid task id: $TARGET"
  load_order
  meta="$STATE/$TARGET.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "no regular record for $TARGET in $STATE"
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    ship|scout|secondmate) ;;
    *) printf 'skip task=%s reason=not_a_ship_scout_or_secondmate\n' "$TARGET"; exit 6 ;;
  esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { printf 'skip task=%s reason=remote_task\n' "$TARGET"; exit 6; }
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  statusf="$STATE/$TARGET.status"
  last=$(last_status_line "$statusf")
  # A second mate outlives every request it finishes, so its last done line
  # does not mean it is gone.
  if [ "$kind" != secondmate ] && status_is_terminal_verb "$last"; then
    printf 'skip task=%s reason=task_reported_terminal_status\n' "$TARGET"
    exit 6
  fi
  if [ -e "$STATE/.crew-stopped-$TARGET" ] || [ -L "$STATE/.crew-stopped-$TARGET" ]; then
    printf 'skip task=%s reason=stopped_on_purpose\n' "$TARGET"
    exit 6
  fi
  wt=$(fm_meta_get "$meta" worktree)
  from_h=$(fm_meta_get "$meta" harness)
  from_m=$(fm_meta_get "$meta" model)
  from_a=$(fm_meta_get "$meta" account)
  backend=$(fm_backend_of_meta "$meta" 2>/dev/null) || backend=$(fm_meta_get "$meta" backend)
  backend=${backend:-tmux}
  gen=$(fm_meta_get "$meta" spawn_gen)
  from=$(fm_failover_label "$from_h" "$from_m" "$from_a")
  reason=$(reason_or_record "$TARGET")
  take_lock "$STATE/.failover-$TARGET.lock" || { printf 'busy task=%s reason=another_failover_holds_the_lock\n' "$TARGET"; exit 5; }
  ledger="$STATE/.failover-$TARGET"
  max=$(int_or "${FM_FAILOVER_MAX_ATTEMPTS:-}" 3)
  attempts=$(ledger_attempts "$ledger")
  if [ "$attempts" -ge "$max" ]; then
    printf 'bound task=%s from=%s attempts=%s window=%ss\n' "$TARGET" "$from" "$attempts" "$WINDOW_SECS"
    exit 3
  fi
  # fm-spawn records account= only for a pinned account; an unpinned Claude
  # worker is taken to run on the account this process inherits, which holds
  # only while the worker was spawned under the same CLAUDE_CONFIG_DIR, so that
  # one is excluded too. Only a Claude worker has a Claude account to exclude.
  # A second mate with no recorded account runs on its own pin, so that pin is
  # the account to exclude, read without editing it.
  run_a=''
  if [ "$from_h" = claude ] && [ "$kind" = secondmate ] && [ -z "$from_a" ] \
    && pin=$(fm_worker_account_read claude "$CONFIG/secondmate-accounts/$TARGET/claude-account" 2>/dev/null); then
    from_a=${pin%%$'\t'*}
  fi
  [ "$from_h" != claude ] || run_a=${from_a:-${CLAUDE_CONFIG_DIR:-ordinary}}
  EVAL_KIND=$kind EVAL_WT=$wt
  evaluate worker "$from_h" "$from_m" "$run_a" "$backend" "$ledger"
  if [ "${#CAND[@]}" -eq 0 ]; then
    ledger_add "$ledger" none "$from" - "$reason"
    why=${FM_EVALUATE_DEADLINE:+deadline_before_$FM_EVALUATE_DEADLINE}
    printf 'none task=%s from=%s reason=%s why=%s\n' "$TARGET" "$from" "$reason" "${why:-no_eligible_runtime}"
    exit 1
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=$(fm_meta_get "$meta" branch)
  while [ "${#CAND[@]}" -gt 0 ]; do
    row=${CAND[0]}
    IFS=$FM_FO_SEP read -r h m a label quota <<< "$row"
    note="Provider failover: your previous runtime ($from) $(why_text "$reason") at $(iso "$(now)"), so firstmate relaunched this task on $label in the same local copy.
The local copy, its branch ${branch:-unknown}, its commits, and any uncommitted changes are exactly as the previous worker left them.
Its newest status events, oldest first:
$(tail -n 5 "$statusf" 2>/dev/null | sed 's/^/    /')
Re-read your instructions, check \`git status\` and \`git log\`, check \`no-mistakes axi status\` for any run on this branch, whose gates carry over, then continue from that checkpoint."
    if [ "$kind" = secondmate ]; then
      note="Provider failover: your previous runtime ($from) $(why_text "$reason") at $(iso "$(now)"), so your parent relaunched you on $label in your same home.
Your home, backlog, and work records are exactly as you left them.
Its newest status events, oldest first:
$(tail -n 5 "$statusf" 2>/dev/null | sed 's/^/    /')
Re-read your charter, reconcile the work already under way in your home, and continue it."
    fi
    local -a args=("$TARGET" relaunch --harness "$h")
    [ -z "$m" ] || args+=(--model "$m")
    [ -z "$a" ] || args+=(--account "$a")
    args+=(--provider-failover --note "$note")
    rto=$RELAUNCH_TIMEOUT
    if [ -n "$DEADLINE" ]; then
      left=$(( DEADLINE - $(now) ))
      if [ "$left" -lt "$MIN_RELAUNCH_SECS" ]; then
        printf 'none task=%s from=%s reason=%s why=deadline_before_%s\n' "$TARGET" "$from" "$reason" "$label"
        exit 1
      fi
      [ "$left" -ge "$rto" ] || rto=$left
    fi
    ledger_add "$ledger" attempt "$from" "$label" "$reason"
    rc=0
    out=$(FM_HOME=$FM_HOME FM_CONTROL_EXPECTED_SPAWN_GEN=$gen fm_run_timed "$rto" "$CONTROL_BIN" "${args[@]}" </dev/null 2>&1) || rc=$?
    published_gen=$(fm_meta_get "$meta" spawn_gen)
    published_h=$(fm_meta_get "$meta" harness)
    if [ "$rc" -eq 0 ] || { [ -n "$published_gen" ] && [ "$published_gen" != "$gen" ] && [ "$published_h" = "$h" ]; }; then
      ledger_add "$ledger" switched "$from" "$label" "$reason"
      rm -f "$(fm_failover_record_path "$STATE" "$TARGET")"
      dispatch_record "$TARGET" "$from" "$label" "$reason"
      printf 'switched task=%s from=%s to=%s reason=%s\n' "$TARGET" "$from" "$label" "$reason"
      exit 0
    fi
    if [ -n "$published_gen" ] && [ "$published_gen" != "$gen" ]; then
      printf 'none task=%s from=%s reason=%s why=unexpected_published_runtime\n' "$TARGET" "$from" "$reason"
      exit 1
    fi
    detail=$(printf '%s\n' "$out" | LC_ALL=C tr -d '\r' | awk 'NF { line = $0 } END { print substr(line, 1, 200) }')
    ledger_add "$ledger" failed "$from" "$label" "rc=$rc"
    printf 'failed task=%s to=%s rc=%s detail=%s\n' "$TARGET" "$label" "$rc" "$(tok "$detail")"
    # A refusal before the old agent stopped changes nothing; any other exit
    # still leaves the record fm-control kept, so the next runtime may try.
    # A usage-limit screen fm-control could not close without typing into it
    # stays that way whatever runtime follows, so that refusal ends the walk.
    [ "$rc" -ne 7 ] || break
    case "$out" in *'at a usage-limit screen'*) break ;; esac
    [ "$(ledger_attempts "$ledger")" -lt "$max" ] || break
    evaluate worker "$from_h" "$from_m" "$run_a" "$backend" "$ledger"
  done
  printf 'none task=%s from=%s reason=%s why=every_relaunch_failed\n' "$TARGET" "$from" "$reason"
  exit 1
}

# --- captain -------------------------------------------------------------------
captain_lock_owner() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_FAILOVER_TEST_LOCK_OWNER:-}" = 1 ]; then
    return 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  command -v fm_lock_try_acquire >/dev/null 2>&1 || . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_handoff_actor_authorized "$STATE" "$FM_HOME" "$SCRIPT_DIR/fm-watch.sh"
}

cmd_captain() {
  local from_h from_a backend from reason ledger max attempts doc stamp row h m a label quota rc out note owner_pid owner_runtime rto left why
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_root_is_secondmate_home "$FM_HOME" && { printf 'skip task=captain reason=secondmate_home_parent_fails_it_over\n'; exit 6; }
  load_order
  captain_lock_owner || { printf 'skip task=captain reason=not_the_session_lock_owner\n'; exit 6; }
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  fm_supervision_needed "$STATE" || { printf 'skip task=captain reason=no_open_work\n'; exit 6; }
  owner_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  from_h=${FM_SESSION_LOCK_OWNER_HARNESS:-}
  if [ -z "$from_h" ]; then
    owner_runtime=$("$SCRIPT_DIR/fm-harness.sh" process "$owner_pid" 2>/dev/null) || owner_runtime=
    from_h=${owner_runtime##* }
  fi
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_FAILOVER_TEST_HARNESS:-}" ]; then from_h=$FM_FAILOVER_TEST_HARNESS; fi
  [ -n "$from_h" ] || { printf 'none task=captain reason=unknown_lock_owner_runtime\n'; exit 1; }
  from_a=${CLAUDE_CONFIG_DIR:-ordinary}
  [ "$from_h" = claude ] || from_a=''
  backend=$(fm_backend_name 2>/dev/null) || backend=unknown
  from=$(fm_failover_label "$from_h" '' "$from_a")
  reason=$(reason_or_record captain)
  take_lock "$STATE/.failover-captain.lock" || { printf 'busy task=captain reason=another_failover_holds_the_lock\n'; exit 5; }
  ledger="$STATE/.failover-captain"
  max=$(int_or "${FM_FAILOVER_CAPTAIN_MAX_ATTEMPTS:-}" 2)
  attempts=$(ledger_attempts "$ledger")
  if [ "$attempts" -ge "$max" ]; then
    printf 'bound task=captain from=%s attempts=%s window=%ss\n' "$from" "$attempts" "$WINDOW_SECS"
    exit 3
  fi
  evaluate primary "$from_h" '' "$from_a" "$backend" "$ledger"
  if [ "${#CAND[@]}" -eq 0 ]; then
    ledger_add "$ledger" none "$from" - "$reason"
    fm_failover_log "event=provider_failover_none scope=primary from=$from reason=$reason"
    why=${FM_EVALUATE_DEADLINE:+deadline_before_$FM_EVALUATE_DEADLINE}
    printf 'none task=captain from=%s reason=%s why=%s\n' "$from" "$reason" "${why:-no_eligible_runtime}"
    exit 1
  fi
  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  doc="$DATA/handoffs/handoff-$stamp-failover.md"
  note="Provider failover: the previous captain session on $from $(why_text "$reason") at $(iso "$(now)"), so this home started a successor on the next runtime in its failover order (bin/fm-failover.sh). Resume supervision from the ledger above; the previous session keeps running but no longer holds the lock."
  rc=0
  out=$(FM_HOME=$FM_HOME fm_run_timed 120 bash "$DELEGATE_BIN/fm-ledger.sh" handoff --doc "$doc" --note "$note" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    ledger_add "$ledger" none "$from" - "handoff_doc_rc=$rc"
    fm_failover_log "event=provider_failover_none scope=primary from=$from reason=$reason why=handoff_doc_failed"
    printf 'none task=captain from=%s reason=%s why=handoff_doc_failed rc=%s detail=%s\n' "$from" "$reason" "$rc" "$(tok "$(printf '%s' "$out" | tail -n 1)")"
    exit 1
  fi
  printf 'handoff doc=%s\n' "$doc"
  while [ "${#CAND[@]}" -gt 0 ]; do
    row=${CAND[0]}
    IFS=$FM_FO_SEP read -r h m a label quota <<< "$row"
    local -a args=(--harness "$h" --reason "failover_$reason")
    [ -z "$m" ] || args+=(--model "$m")
    [ -z "$a" ] || args+=(--account "$a")
    rto=$HANDOFF_TIMEOUT
    if [ -n "$DEADLINE" ]; then
      left=$(( DEADLINE - $(now) ))
      if [ "$left" -lt "$MIN_RELAUNCH_SECS" ]; then
        printf 'none task=captain from=%s reason=%s why=deadline_before_%s\n' "$from" "$reason" "$label"
        exit 1
      fi
      [ "$left" -ge "$rto" ] || rto=$left
    fi
    ledger_add "$ledger" attempt "$from" "$label" "$reason"
    fm_failover_log "event=provider_failover_choice scope=primary from=$from to=$label reason=$reason $quota"
    rc=0
    out=$(FM_HOME=$FM_HOME fm_run_timed "$rto" bash "$DELEGATE_BIN/fm-handoff-launch.sh" "${args[@]}" "$doc" </dev/null 2>&1) || rc=$?
    printf '%s\n' "$out" | sed 's/^/  handoff: /'
    if [ "$rc" -eq 0 ]; then
      ledger_add "$ledger" switched "$from" "$label" "$reason"
      rm -f "$(fm_failover_record_path "$STATE" captain)"
      fm_failover_log "event=provider_failover_result scope=primary from=$from to=$label result=replaced"
      dispatch_record captain "$from" "$label" "$reason"
      printf 'switched task=captain from=%s to=%s reason=%s\n' "$from" "$label" "$reason"
      exit 0
    fi
    ledger_add "$ledger" failed "$from" "$label" "rc=$rc"
    fm_failover_log "event=provider_failover_result scope=primary from=$from to=$label result=failed rc=$rc"
    printf 'failed task=captain to=%s rc=%s\n' "$label" "$rc"
    # Exit 4 is an open captain order missing from the handoff: no successor
    # may start without it, whatever its runtime.
    [ "$rc" -ne 4 ] || break
    [ "$(ledger_attempts "$ledger")" -lt "$max" ] || break
    evaluate primary "$from_h" '' "$from_a" "$backend" "$ledger"
  done
  printf 'none task=captain from=%s reason=%s why=every_handoff_failed\n' "$from" "$reason"
  exit 1
}

case "$CMD" in
  plan) cmd_plan ;;
  preflight) cmd_preflight ;;
  hook) cmd_hook ;;
  worker) cmd_worker ;;
  captain) cmd_captain ;;
esac
