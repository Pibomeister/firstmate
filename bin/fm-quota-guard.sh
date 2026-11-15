#!/usr/bin/env bash
# fm-quota-guard.sh - read quota for every pool this home's supervisors and
# workers run on, judge each pool against the night window, and name the moves
# that keep the supervisors running.
#
# Usage: FM_HOME=<home> fm-quota-guard.sh <command> [options]
#   check [--trigger kickoff|periodic|warning|manual]
#                      One read and verdict now; the trigger defaults to manual.
#   tick               Run check only when one is due: kickoff when this home has
#                      no check on record or a supervisor's session-lock holder
#                      changed since the last check, periodic once
#                      quota-guard-every-secs passed. Otherwise print nothing.
#   warning --subject <id> [--harness <h>] [--account <a>] [--model <m>]
#                      Record one limit dialog, then check with trigger warning.
#   record-dialog --subject <id> [--harness <h>] [--account <a>] [--model <m>]
#                      Record one limit dialog only.
# Options for check, tick, and warning:
#   --window-secs <n>            Horizon a pool must last; default from config.
#   --snapshot <file>            A captured quota-axi --json snapshot for the
#                                pools that are not Claude accounts.
#   --primary-harness <name>     This home's primary harness; default the one
#                                the last check recorded for the same live
#                                session-lock holder, else that holder's
#                                harness.
#   --primary-account <entry>    The primary's Claude account, `ordinary` or a
#                                config root; default the one the last check
#                                recorded for the same live session-lock
#                                holder, else ordinary. The watchdog passes
#                                the root that holds the primary's transcript,
#                                and a check a second mate's or worker's
#                                warning runs keeps both.
#   --candidate <harness:model>  Reroute candidate, repeatable; default the
#                                reroute-candidates key of config/watchdog.
#
# Members. The supervisors are this home's primary, when its session lock has a
# live holder, and every second mate registered in data/secondmates.md whose
# home exists. Only the pools the supervisors run on are read. The workers are
# the ship and scout records (state/<id>.meta) of this home and of each
# registered second mate's home that are on one of those pools and whose
# recorded endpoint still exists (fm_backend_target_exists). A member's pool is its
# quota provider (fm_quota_provider_for_harness in bin/fm-quota-axi-lib.sh)
# plus its account: the recorded account= for Claude (ordinary when absent),
# the quota_lane of FM_QUOTA_ROW_JQ for Codex and Pi, otherwise default. A
# second mate's harness, model, and account come from this home's
# state/<id>.meta. A harness with no quota provider is an unmeasured pool.
#
# Reads. Every Claude account in use, declared in config/claude-accounts, or
# named by a pin a Claude relaunch would read is read in one quota-axi --provider claude --json --full --no-credential-refresh
# call with QUOTA_AXI_CLAUDE_PROFILES naming each account root, and with
# QUOTA_AXI_SNAPSHOT, CLAUDE_CONFIG_DIR, and the credentials Claude ranks above a
# stored login (FM_WORKER_ACCOUNT_CLAUDE_SHED) removed, so the selected lane is
# the ordinary account (~/.claude). Each account binds only to the lane whose
# accountLocator.path is its root; no lane is an unknown account, never another
# account's row. Every other pool binds to its quota_row of one quota-axi --json
# --no-credential-refresh snapshot, or of --snapshot. Each read is bounded by
# FM_QUOTA_GUARD_READ_SECS (default 60). A read that fails but still prints a
# valid snapshot is kept, so a rate-limited account reads as its own stale row.
#
# Verdict. Each member is judged on the scopes quota_applicable binds to its
# model, and a pool takes the worst verdict of its members:
#   exhausted  a scope's runway is exhausted_now, on fresh data.
#   short      a known scope's usableRunwaySeconds is under the window.
#   unknown    no row, a failed read, stale data (state.stale, or a
#              state.status other than fresh), an attention entry naming stale
#              or headroom_unknown, an unknown scope, or a runway with no time.
#              A member with no recorded model is also unknown when any model
#              or product scope of its row is short or exhausted, because it
#              may run on that model. Unknown is never counted as headroom.
#   ok         every scope runs through its reset or past the window.
# The window is --window-secs, else quota-guard-window-secs, else the seconds
# until the next quota-guard-window-until local time (default 08:00).
#
# Moves. A worker on a short or exhausted supervisor pool gets a steer line, so
# the pool is kept for its supervisors. A supervisor on an exhausted pool gets a failover
# line. Each move names one pick: first, for a Claude worker or the primary,
# another config/claude-accounts entry of its own home whose own read is ok and
# whose pool is not short, exhausted, or unknown (a second mate relaunches on
# its own pin, so it never gets an account pick);
# then the bin/fm-quota-reroute.sh suggest pick among the candidates whose own
# read is ok and that are not on that pool or on another pool that is short,
# exhausted, or unknown, with --kind secondmate for a supervisor; else none. A
# Claude candidate's pool is the account the relaunching home's pin names (for
# a second mate, its config/secondmate-accounts pin first), never assumed to be
# the ordinary account. Firstmate, or the second mate that owns a worker,
# relaunches through bin/fm-control.sh <id> relaunch --account <entry>, or
# --harness and --model; this script never relaunches anything.
#
# Output, first line the result line the main session reads:
#   quota-guard: <ok|unknown|act> trigger=<t> window=<n>s pools=<n> ok=<n> unknown=<n> short=<n> exhausted=<n> steer=<n> failover=<n>
#   pool: <provider>:<account> status=<s> runway=<secs|through_reset|-> supervisors=<ids|-> workers=<ids|-> why=<text>
#   steer: <id|mate/id> pool=<pool> pick=<account <entry>|<harness> <model>|none> why=<text>
#   failover: <id> pool=<pool> pick=<account <entry>|<harness> <model>|none> why=<text>
# act means at least one steer or failover line. The primary's id is primary.
#
# Files, under FM_HOME:
#   state/quota-guard/last        key=value: at, trigger, verdict, locks,
#                                 primary_lock, primary_harness,
#                                 primary_account, result.
#   state/quota-guard/report.txt  the full output of the last check.
#   state/quota-guard/checks.tsv  append-only: epoch, trigger, verdict, result line.
#   state/quota-limit-dialogs.tsv append-only: epoch, subject, account, model,
#                                 harness, one row per recorded limit dialog;
#                                 a field the caller and the records cannot
#                                 name is `-`.
# Config, in config/watchdog or the file FM_QUOTA_GUARD_CONF names
# (docs/watchdog.md owns the keys): quota-guard-every-secs,
# quota-guard-window-secs, quota-guard-window-until, reroute-candidates.
#
# Boundaries: this never writes config/claude-account, config/pi-account, or any
# credential, never passes --allow-keychain-prompt or opens a sign-in, never
# launches or relaunches an agent, and spends nothing.
#
# Test seam: FM_TEST_SEAM=1 with FM_NOW fixes the clock (bin/fm-clock-lib.sh).
#
# Exit status: 0 for ok, unknown, or a tick that is not due; 3 for act; 2 for a
# usage error; 1 for any other failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME must name the home to guard}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
GUARD=$STATE/quota-guard
DIALOGS=$STATE/quota-limit-dialogs.tsv

# shellcheck source=bin/fm-clock-lib.sh
. "$SCRIPT_DIR/fm-clock-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

READ_SECS=${FM_QUOTA_GUARD_READ_SECS:-60}
WD_CONF=${FM_QUOTA_GUARD_CONF:-$CONFIG/watchdog}

die() { printf 'fm-quota-guard: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}
flat() { printf '%s' "$1" | tr '\t\r\n' '   '; }

TRIGGER=manual WINDOW='' SNAPSHOT='' PRIMARY_HARNESS='' PRIMARY_ACCOUNT=''
SUBJECT='' D_HARNESS='' D_ACCOUNT='' D_MODEL=''
CANDIDATES=''

parse_opts() {  # <command> <args...>
  local cmd=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger)
        [ "$cmd" = check ] || die "--trigger is only for check"
        case "${2-}" in kickoff|periodic|warning|manual) TRIGGER=$2 ;; *) die "--trigger must be kickoff, periodic, warning, or manual" ;; esac
        shift 2 ;;
      --window-secs)
        case "${2-}" in ''|*[!0-9]*|0) die "--window-secs needs a positive number of seconds" ;; esac
        WINDOW=$2; shift 2 ;;
      --snapshot)
        [ -n "${2-}" ] && [ -f "$2" ] || die "--snapshot needs a readable file"
        SNAPSHOT=$2; shift 2 ;;
      --primary-harness)
        [ -n "${2-}" ] || die "--primary-harness needs a name"
        PRIMARY_HARNESS=$2; shift 2 ;;
      --primary-account)
        [ -n "${2-}" ] || die "--primary-account needs an account"
        PRIMARY_ACCOUNT=$2; shift 2 ;;
      --candidate)
        case "${2-}" in *:*) ;; *) die "--candidate needs harness:model" ;; esac
        CANDIDATES="$CANDIDATES${CANDIDATES:+,}$2"; shift 2 ;;
      --subject|--harness|--account|--model)
        case "$cmd" in warning|record-dialog) ;; *) die "$1 is only for warning and record-dialog" ;; esac
        [ -n "${2-}" ] || die "$1 needs a value"
        case "$1" in
          --subject) SUBJECT=$2 ;;
          --harness) D_HARNESS=$2 ;;
          --account) D_ACCOUNT=$2 ;;
          --model) D_MODEL=$2 ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$CANDIDATES" ] || CANDIDATES=$(fm_wd_conf_get "$WD_CONF" reroute-candidates '')
  primary_defaults
}

# --- members -----------------------------------------------------------------

# Prints id TAB home for each registered second mate whose home exists.
mates() {
  local reg=$FM_HOME/data/secondmates.md id home
  [ -f "$reg" ] || return 0
  LC_ALL=C sed -nE 's/^- ([A-Za-z0-9._-]+) - .*\(home: ([^;)]+)[;)].*/\1	\2/p' "$reg" |
    while IFS=$'\t' read -r id home; do
      [ -d "$home/state" ] || continue
      printf '%s\t%s\n' "$id" "$home"
    done | awk -F'\t' '!seen[$1]++'
}

lock_pid() {  # <home>
  head -n 1 "$1/state/.lock" 2>/dev/null | tr -cd '0-9'
}

pid_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
}

# The supervisors' lock holders, so a new session reads as a kickoff.
lock_fingerprint() {
  local id home out
  out="primary=$(lock_pid "$FM_HOME")"
  while IFS=$'\t' read -r id home; do
    out="$out,$id=$(lock_pid "$home")"
  done < <(mates)
  printf '%s\n' "$out"
}

# primary_defaults: a command that names no primary harness or account keeps
# the ones the last check recorded while the same session-lock holder is live,
# so a check a second mate's or worker's warning runs judges the primary as the
# primary's own check did.
primary_defaults() {
  local rec=$GUARD/last pid
  pid=$(lock_pid "$FM_HOME")
  if pid_alive "$pid" && [ "$(fm_wd_conf_get "$rec" primary_lock '')" = "$pid" ]; then
    [ -n "$PRIMARY_HARNESS" ] || PRIMARY_HARNESS=$(fm_wd_conf_get "$rec" primary_harness '')
    [ -n "$PRIMARY_ACCOUNT" ] || PRIMARY_ACCOUNT=$(fm_wd_conf_get "$rec" primary_account '')
  fi
  [ -n "$PRIMARY_ACCOUNT" ] || PRIMARY_ACCOUNT=ordinary
}

primary_harness() {
  local pid
  if [ -n "$PRIMARY_HARNESS" ]; then printf '%s\n' "$PRIMARY_HARNESS"; return 0; fi
  pid=$(lock_pid "$FM_HOME")
  pid_alive "$pid" || return 1
  fm_harness_path_name "$(fm_ps_comm "$pid" 2>/dev/null)" 2>/dev/null || printf 'unknown\n'
}

# member_pool <harness> <model> <account>: prints provider TAB account.
member_pool() {
  local harness=$1 model=$2 account=$3 provider lane
  if provider=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null) ||
     provider=$(fm_quota_single_provider_for_harness "$harness" 2>/dev/null); then :
  else
    printf 'unmeasured\t%s\n' "${harness:-unknown}"
    return 0
  fi
  if [ "$provider" = claude ]; then
    printf 'claude\t%s\n' "${account:-ordinary}"
    return 0
  fi
  lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"' quota_lane($h; $m)' 2>/dev/null) || lane=
  printf '%s\t%s\n' "$provider" "${lane:-default}"
}

# Prints role TAB label TAB id TAB home TAB harness TAB model TAB kind TAB
# account TAB worktree TAB mate, one line per supervisor.
supervisors() {
  local h id home meta harness model account
  if h=$(primary_harness); then
    printf 'supervisor\tprimary\tprimary\t%s\t%s\tdefault\tsecondmate\t%s\t%s\t-\n' "$FM_HOME" "$h" "$PRIMARY_ACCOUNT" "$FM_HOME"
  fi
  while IFS=$'\t' read -r id home; do
    meta=$STATE/$id.meta
    harness=unknown model=default account=
    if [ -f "$meta" ]; then
      harness=$(fm_meta_get "$meta" harness 2>/dev/null) || harness=
      model=$(fm_meta_get "$meta" model 2>/dev/null) || model=
      account=$(fm_meta_get "$meta" account 2>/dev/null) || account=
    fi
    printf 'supervisor\t%s\t%s\t%s\t%s\t%s\tsecondmate\t%s\t%s\t%s\n' "$id" "$id" "$FM_HOME" "${harness:-unknown}" "${model:-default}" "${account:-ordinary}" "$home" "$id"
  done < <(mates)
}

# Prints label TAB id TAB home TAB harness TAB model TAB kind TAB account TAB
# worktree TAB meta for each ship and scout record of this home and its mates.
workers() {
  local id home harness model account kind wt f label label_id
  {
    printf '%s\t-\n' "$FM_HOME"
    mates | awk -F'\t' '{ print $2 "\t" $1 }'
  } | while IFS=$'\t' read -r home label; do
    for f in "$home"/state/*.meta; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      id=$(basename "$f" .meta)
      case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
      kind=$(fm_meta_get "$f" kind 2>/dev/null) || kind=
      case "$kind" in ship|scout) ;; *) continue ;; esac
      harness=$(fm_meta_get "$f" harness 2>/dev/null) || harness=
      model=$(fm_meta_get "$f" model 2>/dev/null) || model=
      account=$(fm_meta_get "$f" account 2>/dev/null) || account=
      wt=$(fm_meta_get "$f" worktree 2>/dev/null) || wt=
      if [ "$label" = - ]; then label_id=$id; else label_id=$label/$id; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label_id" "$id" "$home" "${harness:-unknown}" "${model:-default}" "$kind" "${account:-ordinary}" "${wt:--}" "$f"
    done
  done
}

# worker_live <meta>: the recorded endpoint still exists.
worker_live() {
  local backend target
  backend=$(fm_backend_of_meta "$1" 2>/dev/null) || backend=
  target=$(fm_backend_target_of_meta "$1" 2>/dev/null) || target=
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  fm_backend_target_exists "$backend" "$target" 2>/dev/null
}
# --- reads -------------------------------------------------------------------

read_main() {  # -> sets MAIN_SNAP, or MAIN_ERR
  MAIN_SNAP=$WORK/main.json MAIN_ERR=
  if [ -n "$SNAPSHOT" ]; then
    cp "$SNAPSHOT" "$MAIN_SNAP" 2>/dev/null || { MAIN_ERR="snapshot unreadable"; return 0; }
  elif ! command -v quota-axi >/dev/null 2>&1; then
    MAIN_ERR="quota-axi not installed"; return 0
  else
    fm_run_timed "$READ_SECS" quota-axi --json --no-credential-refresh > "$MAIN_SNAP" 2>/dev/null </dev/null || true
  fi
  fm_quota_json_valid < "$MAIN_SNAP" || MAIN_ERR="quota-axi gave no valid snapshot"
}

claude_root() {  # <account>
  if [ "$1" = ordinary ]; then printf '%s/.claude\n' "${HOME:-}"; else printf '%s\n' "$1"; fi
}

# read_claude <account>...: one read of every named Claude account; sets
# CLAUDE_SNAP, or CLAUDE_ERR when no valid snapshot came back.
read_claude() {
  local a roots='' v
  CLAUDE_SNAP=$WORK/claude.json CLAUDE_ERR=
  for a in "$@"; do
    [ "$a" = ordinary ] || roots="$roots${roots:+:}$a"
  done
  if ! command -v quota-axi >/dev/null 2>&1; then CLAUDE_ERR="quota-axi not installed"; return 0; fi
  set -- env -u QUOTA_AXI_SNAPSHOT -u CLAUDE_CONFIG_DIR -u QUOTA_AXI_CLAUDE_PROFILES
  for v in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do set -- "$@" -u "$v"; done
  [ -z "$roots" ] || set -- "$@" QUOTA_AXI_CLAUDE_PROFILES="$roots"
  fm_run_timed "$READ_SECS" "$@" quota-axi --provider claude --json --full --no-credential-refresh \
    > "$CLAUDE_SNAP" 2>/dev/null </dev/null || true
  fm_quota_json_valid < "$CLAUDE_SNAP" || CLAUDE_ERR="quota-axi gave no valid Claude snapshot"
}

# claude_snap <account>: prints the path of a one-row snapshot holding that
# account's own lane, or returns 1 with the reason on stdout.
claude_snap() {
  local root key file
  [ -z "$CLAUDE_ERR" ] || { printf '%s\n' "$CLAUDE_ERR"; return 1; }
  root=$(claude_root "$1")
  key=claude-$(printf '%s' "$1" | cksum | cut -d ' ' -f 1)
  file=$WORK/$key.json
  if [ ! -e "$file" ]; then
    jq -c --arg root "${root%/}" '
      [.providers[]? | select(.provider == "claude" and
        (((.accountLocator.path // "") | sub("/+$"; "")) == $root))] |
      if length == 1 then {schemaVersion: 5, providers: .} else empty end
    ' "$CLAUDE_SNAP" > "$file" 2>/dev/null || : > "$file"
  fi
  [ -s "$file" ] || { printf 'no quota lane for Claude account %s\n' "$1"; return 1; }
  printf '%s\n' "$file"
}

# shellcheck disable=SC2016  # jq program text
CLASSIFY_JQ='
  def secs($s): if ($s | type) == "number" then ($s | floor | tostring) + "s" else "-" end;
  quota_row($snap[0]; $provider; $lane) as $p |
  ([($snap[0].attention // [])[]?, ($p.attention // [])[]?
    | select(type == "object" and ((.provider // $provider) == $provider)
      and (((.kind // "") | tostring) | test("stale|headroom_unknown")))]) as $att |
  if $p == null then ["unknown", "-", "no \($provider) quota row"]
  elif $p.state.stale == true then ["unknown", "-", "stale quota data (\($p.state.error // $p.state.status // "no fresh read"))"]
  elif (($p.state.status // "fresh") != "fresh") then ["unknown", "-", "quota \($p.state.status) (\($p.state.error // "no reason"))"]
  elif ($att | length) > 0 then ["unknown", "-", "quota attention \($att[0].kind)"]
  else
    quota_applicable($p; $model) as $rows |
    ([$rows[] | select(.status == "known") | .runway.usableRunwaySeconds | numbers] | min) as $min |
    ((($model // "") | sub("^model:"; "")) as $mt |
      if $mt == "" or $mt == "default" then
        [($p.quotaSemantics.effectiveAvailability // [])[]
          | select(((.scope // "") | tostring | test("^(model|product):")) and
            (.runway.status == "exhausted_now" or
             ((.runway.usableRunwaySeconds | type) == "number" and .runway.usableRunwaySeconds < $window)))
          | .scope]
      else [] end) as $hidden |
    if ($rows | length) == 0 then ["unknown", "-", "no applicable quota scope"]
    elif any($rows[]; .runway.status == "exhausted_now") then
      ([$rows[] | select(.runway.status == "exhausted_now") | .scope] | first) as $s |
      ["exhausted", "0", "\($s) exhausted now"]
    elif $min != null and $min < $window then
      ([$rows[] | select(.runway.usableRunwaySeconds == $min) | .scope] | first) as $s |
      ["short", ($min | floor | tostring), "\($s) runs out in \(secs($min)), inside the \($window)s window"]
    elif ($hidden | length) > 0 then ["unknown", "-", "model not recorded, and \($hidden[0]) is short or exhausted"]
    elif any($rows[]; .status != "known") then
      ["unknown", "-", "headroom unknown on \([$rows[] | select(.status != "known") | .scope] | first)"]
    elif any($rows[]; (.runway.status == "through_reset" or ((.runway.usableRunwaySeconds | type) == "number")) | not) then
      ["unknown", "-", "runway unknown on \([$rows[] | select((.runway.status == "through_reset" or ((.runway.usableRunwaySeconds | type) == "number")) | not) | .scope] | first)"]
    elif $min == null then ["ok", "through_reset", "every scope runs through its reset"]
    else ["ok", ($min | floor | tostring), "lasts past the window"]
    end
  end | @tsv'

# classify <provider> <account> <model>: prints status TAB runway TAB why.
classify() {
  local provider=$1 account=$2 model=$3 snap lane=
  case "$provider" in
    unmeasured) printf 'unknown\t-\tno quota provider for harness %s\n' "$account"; return 0 ;;
    claude)
      if ! snap=$(claude_snap "$account"); then
        printf 'unknown\t-\t%s\n' "$snap"
        return 0
      fi ;;
    *)
      if [ -n "$MAIN_ERR" ]; then printf 'unknown\t-\t%s\n' "$MAIN_ERR"; return 0; fi
      snap=$MAIN_SNAP
      [ "$account" = default ] || lane=$account ;;
  esac
  # A provider-prefixed model (OMP's openai-codex/gpt-5.4) names its scope by
  # the bare model, as bin/fm-dispatch-resolve.sh reads it.
  jq -r --slurpfile snap "$snap" --arg provider "$provider" --arg lane "$lane" \
    --arg model "${model##*/}" --argjson window "$WINDOW" -n "$FM_QUOTA_ROW_JQ$CLASSIFY_JQ" 2>/dev/null ||
    printf 'unknown\t-\tquota row could not be judged\n'
}

pool_status() {  # <pool>
  awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$WORK/pools.tsv"
}

# home_config <home>: the config directory a home launches its workers from.
home_config() {
  if [ "$1" = "$FM_HOME" ]; then printf '%s\n' "$CONFIG"; else printf '%s/config\n' "$1"; fi
}

# dest_claude_account <home> <mate|->: the Claude account a relaunch in that
# home uses, from the pin the launch reads (a second mate's own pin first);
# ordinary when the home has no pin. Fails when the pin cannot be read.
dest_claude_account() {
  local cfg row mate=
  [ "$2" = - ] || mate=$2
  cfg=$(fm_worker_account_config claude "$(home_config "$1")" "$mate" 2>/dev/null) || return 1
  row=$(fm_worker_account_resolve claude "$cfg" config/claude-account 2>/dev/null) || return 1
  if [ -z "$row" ]; then printf 'ordinary\n'; else printf '%s\n' "${row%%$'\t'*}"; fi
}

# claude_pins: every account a Claude relaunch from this home or a second mate
# home would land on, so each candidate destination has its own read.
claude_pins() {
  local id home
  dest_claude_account "$FM_HOME" - || true
  while IFS=$'\t' read -r id home; do
    dest_claude_account "$FM_HOME" "$id" || true
    dest_claude_account "$home" - || true
  done < <(mates)
}

# pick <provider> <account> <pool> <harness> <model> <kind> <worktree> <mate> <home>
# A second mate relaunches on its own pin, so it never gets an account pick; a
# worker gets only an account its own home declares.
pick() {
  local provider=$1 account=$2 pool=$3 harness=$4 model=$5 kind=$6 wt=$7 mate=$8 home=$9
  local entry st cand cprov cacct cpool cstat out err listed dacct
  if [ "$provider" = claude ] && [ "$mate" = - ]; then
    listed=$(fm_worker_account_list claude "$(home_config "$home")" 2>/dev/null) || listed=
    while IFS= read -r entry; do
      [ -n "$entry" ] && [ "$entry" != "$account" ] || continue
      # Another member's model can leave the account's pool short or unknown.
      case "$(pool_status "claude:$entry")" in short|exhausted|unknown) continue ;; esac
      st=$(classify claude "$entry" "$model" | cut -f 1)
      if [ "$st" = ok ]; then printf 'account %s\n' "$entry"; return 0; fi
    done <<< "$listed"
  fi
  [ -z "$MAIN_ERR" ] || { printf 'none (%s)\n' "$MAIN_ERR"; return 0; }
  set -- suggest --snapshot "$MAIN_SNAP" --from-harness "$harness" --kind "$kind"
  [ "$model" = default ] || set -- "$@" --from-model "$model"
  [ "$wt" = - ] || set -- "$@" --worktree "$wt"
  if [ "$harness" = claude ] && [ "$kind" = secondmate ] && [ "$mate" != - ]; then set -- "$@" --mate "$mate"; fi
  local n=0
  for cand in $(printf '%s' "$CANDIDATES" | tr ',' ' '); do
    # A Claude candidate lands on the pin of the home that relaunches it.
    dacct=
    if [ "${cand%%:*}" = claude ]; then dacct=$(dest_claude_account "$home" "$mate") || continue; fi
    IFS=$'\t' read -r cprov cacct <<< "$(member_pool "${cand%%:*}" "${cand#*:}" "$dacct")"
    cpool=$cprov:$cacct
    [ "$cpool" != "$pool" ] || continue
    case "$(pool_status "$cpool")" in short|exhausted|unknown) continue ;; esac
    # Only a candidate whose own read is ok is headroom; stale or unmeasured is not.
    cstat=$(classify "$cprov" "$cacct" "${cand#*:}" | cut -f 1)
    [ "$cstat" = ok ] || continue
    set -- "$@" --candidate "$cand"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { printf 'none (no reroute candidate off this pool)\n'; return 0; }
  out=$(FM_HOME=$home FM_CONFIG_OVERRIDE=$home/config "$SCRIPT_DIR/fm-quota-reroute.sh" "$@" 2>"$WORK/reroute.err") || out=none
  if [ -z "$out" ] || [ "$out" = none ]; then
    err=$(awk 'sub(/^error: /, "") { print; exit }' "$WORK/reroute.err" 2>/dev/null)
    printf 'none (%s)\n' "${err:-no eligible reroute candidate}"
    return 0
  fi
  printf '%s\n' "$out"
}

window_secs() {
  local v until
  if [ -n "$WINDOW" ]; then printf '%s\n' "$WINDOW"; return 0; fi
  v=$(fm_wd_conf_int "$WD_CONF" quota-guard-window-secs '')
  if [ -n "$v" ] && [ "$v" -gt 0 ]; then printf '%s\n' "$v"; return 0; fi
  until=$(fm_wd_conf_get "$WD_CONF" quota-guard-window-until 08:00)
  case "$until" in
    [0-2][0-9]:[0-5][0-9]) ;;
    *) die "quota-guard-window-until must be HH:MM: $until" 1 ;;
  esac
  perl -MPOSIX -e '
    my ($h, $m, $now) = @ARGV;
    die "bad hour\n" if $h > 23;
    my @t = localtime($now);
    my $end = mktime(0, $m, $h, $t[3], $t[4], $t[5], 0, 0, -1);
    $end = mktime(0, $m, $h, $t[3] + ++$d, $t[4], $t[5], 0, 0, -1) while $end <= $now;
    print $end - $now, "\n";
  ' "${until%%:*}" "${until#*:}" "$NOW" 2>/dev/null || die "quota-guard-window-until must be HH:MM: $until" 1
}

# --- commands ----------------------------------------------------------------

cmd_check() {
  local role label id home harness model kind account wt mate provider pacct pool st runway why
  local npools=0 nok=0 nunk=0 nshort=0 nexh=0 nsteer=0 nfail=0 verdict result line p
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-guard.XXXXXX") || die "cannot create a scratch directory" 1
  trap 'rm -rf "$WORK"' EXIT
  NOW=$(fm_now)
  WINDOW=$(window_secs) || exit 1
  read_main
  : > "$WORK/members.tsv"
  : > "$WORK/raw.tsv"
  supervisors | while IFS=$'\t' read -r role label id home harness model kind account wt mate; do
    IFS=$'\t' read -r provider pacct <<< "$(member_pool "$harness" "$model" "$account")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$role" "$label" "$id" "$home" "$harness" "$model" "$kind" "$account" "$wt" "$mate" \
      "$provider" "$pacct" >> "$WORK/raw.tsv"
  done
  awk -F'\t' '{ print $11 ":" $12 }' "$WORK/raw.tsv" > "$WORK/sup-pools"
  workers | while IFS=$'\t' read -r label id home harness model kind account wt meta; do
    IFS=$'\t' read -r provider pacct <<< "$(member_pool "$harness" "$model" "$account")"
    grep -qxF "$provider:$pacct" "$WORK/sup-pools" || continue
    worker_live "$meta" || continue
    printf 'worker\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
      "$label" "$id" "$home" "$harness" "$model" "$kind" "$account" "$wt" \
      "$provider" "$pacct" >> "$WORK/raw.tsv"
  done
  # shellcheck disable=SC2046  # one account root per word; roots hold no blanks
  read_claude $( { awk -F'\t' '$11 == "claude" { print $12 }' "$WORK/raw.tsv"
    fm_worker_account_list claude "$CONFIG" 2>/dev/null
    mates | while IFS=$'\t' read -r _ home; do fm_worker_account_list claude "$home/config" 2>/dev/null; done
    claude_pins
    } | awk 'NF && !seen[$0]++')
  while IFS=$'\t' read -r role label id home harness model kind account wt mate provider pacct; do
    IFS=$'\t' read -r st runway why <<< "$(classify "$provider" "$pacct" "$model")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$role" "$label" "$id" "$home" "$harness" "$model" "$kind" "$account" "$wt" "$mate" \
      "$provider" "$pacct" "$st" "$runway" "$(flat "$why")" >> "$WORK/members.tsv"
  done < "$WORK/raw.tsv"
  # One row per pool: the worst member verdict, its runway and reason, and the
  # supervisors and workers on it.
  awk -F'\t' '
    function rank(s) { return s == "exhausted" ? 3 : s == "short" ? 2 : s == "unknown" ? 1 : 0 }
    {
      p = $11 ":" $12
      if (!(p in seen)) { seen[p] = 1; order[++n] = p; st[p] = $13; rw[p] = $14; why[p] = $15 }
      else if (rank($13) > rank(st[p])) { st[p] = $13; rw[p] = $14; why[p] = $15 }
      if ($1 == "supervisor") sup[p] = sup[p] (sup[p] == "" ? "" : ",") $2
      else wrk[p] = wrk[p] (wrk[p] == "" ? "" : ",") $2
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", p, st[p], rw[p], (sup[p] == "" ? "-" : sup[p]), (wrk[p] == "" ? "-" : wrk[p]), why[p]
      }
    }' "$WORK/members.tsv" > "$WORK/pools.tsv"
  : > "$WORK/moves.txt"
  while IFS=$'\t' read -r role label id home harness model kind account wt mate provider pacct st runway why; do
    pool=$provider:$pacct
    p=$(pool_status "$pool")
    if [ "$role" = worker ]; then
      case "$p" in short|exhausted) ;; *) continue ;; esac
      line=$(pick "$provider" "$pacct" "$pool" "$harness" "$model" "$kind" "$wt" - "$home")
      printf 'steer: %s pool=%s pick=%s why=keep %s pool for its supervisors\n' "$label" "$pool" "$line" "$p" >> "$WORK/moves.txt"
    else
      [ "$p" = exhausted ] || continue
      line=$(pick "$provider" "$pacct" "$pool" "$harness" "$model" "$kind" "$wt" "$mate" "$FM_HOME")
      printf 'failover: %s pool=%s pick=%s why=supervisor pool exhausted\n' "$label" "$pool" "$line" >> "$WORK/moves.txt"
    fi
  done < "$WORK/members.tsv"
  while IFS=$'\t' read -r pool st runway _ _ _; do
    npools=$((npools + 1))
    case "$st" in ok) nok=$((nok + 1)) ;; short) nshort=$((nshort + 1)) ;; exhausted) nexh=$((nexh + 1)) ;; *) nunk=$((nunk + 1)) ;; esac
  done < "$WORK/pools.tsv"
  nsteer=$(grep -c '^steer: ' "$WORK/moves.txt" || true)
  nfail=$(grep -c '^failover: ' "$WORK/moves.txt" || true)
  if [ "$((nsteer + nfail))" -gt 0 ]; then verdict=act
  elif [ "$((nunk + nshort + nexh))" -gt 0 ]; then verdict=unknown
  else verdict=ok
  fi
  [ "$npools" -gt 0 ] || verdict=unknown
  result="quota-guard: $verdict trigger=$TRIGGER window=${WINDOW}s pools=$npools ok=$nok unknown=$nunk short=$nshort exhausted=$nexh steer=$nsteer failover=$nfail"
  {
    printf '%s\n' "$result"
    awk -F'\t' '{ printf "pool: %s status=%s runway=%s supervisors=%s workers=%s why=%s\n", $1, $2, $3, $4, $5, $6 }' "$WORK/pools.tsv"
    cat "$WORK/moves.txt"
  } > "$WORK/report.txt"
  cat "$WORK/report.txt"
  mkdir -p "$GUARD" || die "cannot create $GUARD" 1
  { cp "$WORK/report.txt" "$GUARD/.report.tmp" && mv -f "$GUARD/.report.tmp" "$GUARD/report.txt"; } || die "cannot write $GUARD/report.txt" 1
  { printf 'at=%s\ntrigger=%s\nverdict=%s\nlocks=%s\nprimary_lock=%s\nprimary_harness=%s\nprimary_account=%s\nresult=%s\n' \
      "$NOW" "$TRIGGER" "$verdict" "$(lock_fingerprint)" "$(lock_pid "$FM_HOME")" "$PRIMARY_HARNESS" "$PRIMARY_ACCOUNT" "$result" > "$GUARD/.last.tmp" &&
    mv -f "$GUARD/.last.tmp" "$GUARD/last"; } || die "cannot write $GUARD/last" 1
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$TRIGGER" "$verdict" "$result" >> "$GUARD/checks.tsv" || die "cannot append $GUARD/checks.tsv" 1
  [ "$verdict" != act ] || return 3
  return 0
}

cmd_tick() {
  local last_at every now
  now=$(fm_now)
  every=$(fm_wd_conf_int "$WD_CONF" quota-guard-every-secs 7200)
  last_at=$(fm_wd_conf_get "$GUARD/last" at '' | tr -cd '0-9')
  if [ -z "$last_at" ]; then TRIGGER=kickoff
  elif [ "$(fm_wd_conf_get "$GUARD/last" locks '')" != "$(lock_fingerprint)" ]; then TRIGGER=kickoff
  elif [ $((now - last_at)) -ge "$every" ]; then TRIGGER=periodic
  else return 0
  fi
  cmd_check
}

# record_dialog: one row per limit dialog; the subject's own record fills what
# the caller did not name.
record_dialog() {
  local meta='' id home now
  case "$SUBJECT" in ''|*[!A-Za-z0-9._/-]*) die "--subject must name a task, a second mate, or primary" ;; esac
  if [ "$SUBJECT" != primary ]; then
    if [ -f "$STATE/$SUBJECT.meta" ]; then meta=$STATE/$SUBJECT.meta
    else
      while IFS=$'\t' read -r id home; do
        case "$SUBJECT" in */*) [ "$id" = "${SUBJECT%%/*}" ] || continue ;; esac
        if [ -f "$home/state/${SUBJECT#*/}.meta" ]; then meta=$home/state/${SUBJECT#*/}.meta; break; fi
      done < <(mates)
    fi
  fi
  if [ -n "$meta" ]; then
    [ -n "$D_HARNESS" ] || D_HARNESS=$(fm_meta_get "$meta" harness 2>/dev/null) || D_HARNESS=
    [ -n "$D_MODEL" ] || D_MODEL=$(fm_meta_get "$meta" model 2>/dev/null) || D_MODEL=
    [ -n "$D_ACCOUNT" ] || D_ACCOUNT=$(fm_meta_get "$meta" account 2>/dev/null) || D_ACCOUNT=
  fi
  if [ -z "$D_ACCOUNT" ] && [ "$D_HARNESS" = claude ]; then
    if [ "$SUBJECT" = primary ]; then D_ACCOUNT=$PRIMARY_ACCOUNT; else D_ACCOUNT=ordinary; fi
  fi
  if [ -z "$D_ACCOUNT" ] && [ -n "$D_HARNESS" ]; then
    D_ACCOUNT=$(member_pool "$D_HARNESS" "${D_MODEL:-default}" "" | cut -f 2)
  fi
  now=$(fm_now)
  mkdir -p "$STATE" || die "cannot create $STATE" 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$(flat "$SUBJECT")" "$(flat "${D_ACCOUNT:--}")" "$(flat "${D_MODEL:--}")" "$(flat "${D_HARNESS:--}")" >> "$DIALOGS" ||
    die "cannot append $DIALOGS" 1
}

command -v jq >/dev/null 2>&1 || die "jq is required" 1
CMD=${1-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  check) parse_opts check "$@"; cmd_check ;;
  tick) parse_opts tick "$@"; cmd_tick ;;
  warning)
    parse_opts warning "$@"
    record_dialog
    TRIGGER=warning
    cmd_check ;;
  record-dialog) parse_opts record-dialog "$@"; record_dialog ;;
  -h|--help|help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command: $CMD" ;;
esac
