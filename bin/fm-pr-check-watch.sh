#!/usr/bin/env bash
# Bind a named GitHub CheckRun to one PR head and one trusted App ID.
# The generic condition->action runner owns polling and terminal delivery.
#
# Usage: fm-pr-check-watch.sh arm <task> <pr-url> <check> --producer-app <id>
#        fm-pr-check-watch.sh status|retire|rearm <watch-ref>
#        fm-pr-check-watch.sh --help
#
# arm requires a real ship task whose private metadata already binds pr=<pr-url>.
# It binds the current head and explicit numeric GitHub App ID, then prints
# state=live, watch_ref, task, pr, head, check, and producer as key-value lines.
# A live, unhandled, or unhealthy generation for the same task/check refuses a
# duplicate arm. The generated watch_ref is never reused.
# status prints the bound identity and state=live|result-unhandled|ended|unhealthy;
# a captured result also prints result_source, result_sequence and result_handled.
# retire refuses an unhandled result; rearm requires a handled terminal result
# and keeps the same task/PR/check/App binding while allocating a new generation.
# A changed trusted producer requires retire plus a fresh explicit arm.
# The condition polls every 30 seconds until stable success or a 24-hour deadline;
# FM_PR_CHECK_WATCH_INTERVAL and FM_PR_CHECK_WATCH_DEADLINE may override those
# positive values for a private bounded fixture.
# Re-runs of the bound check within one check suite resolve to the newest attempt;
# the same check from the same App in more than one suite is ambiguous.
# Any forge read error ends the watch with condition-error at once; re-arm it.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
WATCH_DIR=$STATE/pr-check-watch

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'fm-pr-check-watch: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0"; }
valid_ref() { [[ ${1-} =~ ^when-prcheck-[0-9a-f]{12}-[0-9a-f]{12}$ ]]; }
record_path() { printf '%s/%s.json\n' "$WATCH_DIR" "$1"; }

check_record_hash() {
  local ref=$1 expected=$2 actual
  valid_ref "$ref" && [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die 'invalid bound watch identity'
  actual=$(fm_pr_sha256 "$(record_path "$ref")") || die 'watch record is unavailable'
  [ "$actual" = "$expected" ] || die 'watch record changed since registration'
}

load_record() {
  local ref=$1 file
  valid_ref "$ref" || die "invalid watch reference: $ref"
  file=$(record_path "$ref")
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(fm_pr_file_link_count "$file")" = 1 ] \
    || die "state=absent watch_ref=$ref"
  RECORD=$(cat "$file")
  printf '%s' "$RECORD" | jq -e --arg ref "$ref" \
    '.version == 1 and .watch_ref == $ref and (.task|type)=="string" and (.pr|type)=="string" and (.head|type)=="string" and (.check|type)=="string" and (.producer_app|type)=="number"' >/dev/null \
    || die "invalid watch record: $ref"
}

record_field() { printf '%s' "$RECORD" | jq -r --arg k "$1" '.[$k]'; }

local_state() {
  local ref=$1 result handled pending=0 captured=0
  for result in "$STATE/procevent-inbox/$ref".*.result; do
    [ ! -L "$result" ] || { printf 'unhealthy\n'; return; }
    [ -f "$result" ] || continue
    captured=$((captured + 1))
    [ "$captured" -eq 1 ] || { printf 'unhealthy\n'; return; }
    handled=${result%.result}.handled
    if [ -e "$handled" ] || [ -L "$handled" ]; then
      [ -f "$handled" ] && [ ! -L "$handled" ] || { printf 'unhealthy\n'; return; }
      continue
    fi
    pending=$((pending + 1))
    [ "$pending" -eq 1 ] || { printf 'unhealthy\n'; return; }
  done
  if [ "$pending" -eq 1 ]; then
    printf 'result-unhandled\n'
    return
  fi
  if [ -e "$STATE/procevent/.$ref.launch-failed" ] || [ -L "$STATE/procevent/.$ref.launch-failed" ] \
    || [ -e "$STATE/procevent/.$ref.stranded" ] || [ -L "$STATE/procevent/.$ref.stranded" ]; then
    printf 'unhealthy\n'
    return
  fi
  if [ -f "$STATE/procevent/$ref.source" ]; then
    printf 'live\n'
    return
  fi
  printf 'ended\n'
}

print_record() {
  local ref=$1 state=$2 result seq handled
  printf 'state=%s\nwatch_ref=%s\ntask=%s\npr=%s\nhead=%s\ncheck=%s\nproducer=app:%s\n' \
    "$state" "$ref" "$(record_field task)" "$(record_field pr)" \
    "$(record_field head)" "$(record_field check)" "$(record_field producer_app)"
  if [ "$state" = result-unhandled ] || [ "$state" = ended ]; then
    for result in "$STATE/procevent-inbox/$ref".*.result; do
      [ -f "$result" ] && [ ! -L "$result" ] || continue
      seq=${result%.result}; seq=${seq##*.}
      case "$seq" in ''|*[!0-9]*) die 'captured result sequence is malformed' ;; esac
      handled=false
      [ ! -f "${result%.result}.handled" ] || handled=true
      printf 'result_source=%s\nresult_sequence=%s\nresult_handled=%s\n' "$ref" "$seq" "$handled"
      break
    done
  fi
}

current_head() {
  local url=$1 head
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 2
  head=$(gh-axi api GET "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" --jq '.head.sha // empty' 2>/dev/null) || return 2
  fm_pr_head_valid "$head" || return 2
  printf '%s\n' "$head"
}

# 0: current success; 1: pending or missing; 2: actionable failure.
check_current() {
  local url=$1 expected_head=$2 check=$3 app=$4 head verdict
  head=$(current_head "$url") || { echo 'forge-error: cannot read PR head'; return 2; }
  [ "$head" = "$expected_head" ] || { printf 'head-moved: bound=%s current=%s\n' "$expected_head" "$head"; return 2; }
  fm_pr_url_parse "$url" || return 2
  # shellcheck disable=SC2016 # jq variables must remain literal for gh-axi --jq.
  verdict=$(FM_CHECK_NAME="$check" FM_APP_ID="$app" gh-axi api GET \
    "/repos/$FM_PR_PATH/commits/$head/check-runs?filter=all&per_page=100" --jq '
    if (.check_runs|type) != "array" then "invalid"
    elif (.total_count // (.check_runs|length)) > (.check_runs|length) then "incomplete"
    else
      ([.check_runs[] | select(.name == env.FM_CHECK_NAME and .app.id == (env.FM_APP_ID|tonumber))]
        | group_by(.check_suite.id) | map(max_by(.id))) as $bound
      | if ($bound|length) > 1 then "ambiguous"
        elif ($bound|length) == 1 then
          if $bound[0].status == "completed" then
            if $bound[0].conclusion == "success" then "success" else "failed" end
          else "pending" end
        elif any(.check_runs[]; .name == env.FM_CHECK_NAME) then "producer-mismatch"
        else "missing" end
    end' 2>/dev/null) || { echo 'forge-error: cannot read check runs'; return 2; }
  case "$verdict" in
    success) return 0 ;;
    pending|missing) return 1 ;;
    *) printf '%s\n' "$verdict"; return 2 ;;
  esac
}

cmd_arm() {
  [ "$#" -eq 5 ] && [ "$4" = --producer-app ] || die 'usage: arm <task> <pr-url> <check> --producer-app <id>'
  local task=$1 url=$2 check=$3 app=$5 head hash nonce name ref file tmp other other_ref lock record_hash interval deadline meta device kind_count
  fm_pr_task_id_valid "$task" || die 'invalid task id'
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || die 'expected canonical GitHub PR URL'
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'state directory is unavailable'
  meta=$STATE/$task.meta
  device=$(fm_pr_file_device "$STATE") || die 'cannot inspect state directory'
  if ! fm_pr_private_file_valid "$meta" 600 "$device" || ! fm_pr_metadata_identity_parse "$meta"; then
    die 'task metadata is unavailable or bound to another PR'
  fi
  kind_count=$(grep -c '^kind=' "$meta" || true)
  if [ "$FM_PR_META_PROVIDER" != github ] || [ "$FM_PR_META_URL" != "$url" ] \
    || [ "$kind_count" -ne 1 ] || ! grep -qxF 'kind=ship' "$meta"; then
    die 'task metadata is unavailable or bound to another PR'
  fi
  [ -n "$check" ] && [ "${#check}" -le 200 ] && [[ "$check" != *$'\n'* ]] || die 'invalid check name'
  [[ "$app" =~ ^[1-9][0-9]*$ ]] || die 'expected numeric GitHub App ID'
  if ! command -v gh-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    die 'gh-axi and jq are required'
  fi
  (umask 077; mkdir -p "$WATCH_DIR") || die 'cannot create watch directory'
  [ -d "$WATCH_DIR" ] && [ ! -L "$WATCH_DIR" ] || die 'watch directory is unavailable'
  lock=$STATE/.pr-check-watch-$task.lock
  fm_lock_acquire_wait_max "$lock" 10 || die 'cannot lock task watch'
  trap 'fm_lock_release "$lock"' EXIT
  for other in "$WATCH_DIR"/*.json; do
    [ -f "$other" ] || continue
    [ ! -L "$other" ] && [ "$(fm_pr_file_link_count "$other")" = 1 ] || die 'invalid existing watch record'
    if jq -e --arg task "$task" --arg check "$check" \
      '.task == $task and .check == $check' "$other" >/dev/null 2>&1; then
      other_ref=${other##*/}; other_ref=${other_ref%.json}
      case "$(local_state "$other_ref")" in
        live|result-unhandled|unhealthy) die "watch already exists: $other_ref" ;;
      esac
    fi
  done
  head=$(current_head "$url") || die 'cannot read current PR head'
  hash=$(printf '%s' "$task" | shasum -a 256 | cut -c1-12)
  nonce=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
  name=prcheck-$hash-$nonce
  ref=when-$name
  file=$(record_path "$ref")
  [ ! -e "$file" ] && [ ! -L "$file" ] || die 'watch generation collision'
  tmp=$(umask 077; mktemp "$WATCH_DIR/.record.XXXXXX") || die 'cannot stage watch record'
  jq -n --arg ref "$ref" --arg task "$task" --arg pr "$url" --arg head "$head" \
    --arg check "$check" --argjson app "$app" \
    '{version:1,watch_ref:$ref,task:$task,pr:$pr,head:$head,check:$check,producer_app:$app}' > "$tmp" \
    || { rm -f "$tmp"; die 'cannot write watch record'; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; die 'cannot secure watch record'; }
  mv "$tmp" "$file" || die 'cannot publish watch record'
  record_hash=$(fm_pr_sha256 "$file") || die 'cannot hash watch record'
  interval=${FM_PR_CHECK_WATCH_INTERVAL:-30}
  deadline=${FM_PR_CHECK_WATCH_DEADLINE:-86400}
  if ! "$SCRIPT_DIR/fm-procevent-when.sh" arm "$name" --interval "$interval" --stable 2 --deadline "$deadline" \
      --error-budget 1 --condition "$SCRIPT_DIR/fm-pr-check-watch.sh" condition "$ref" "$record_hash" \
      --action "$SCRIPT_DIR/fm-pr-check-watch.sh" action "$ref" "$record_hash" >/dev/null; then
    rm -f "$file"
    die 'cannot register condition watch'
  fi
  load_record "$ref"
  print_record "$ref" live
  fm_lock_release "$lock"
  trap - EXIT
}

cmd_status() {
  [ "$#" -eq 1 ] || die 'usage: status <watch-ref>'
  load_record "$1"
  print_record "$1" "$(local_state "$1")"
}

cmd_condition() {
  [ "$#" -eq 2 ] || die 'usage: condition <watch-ref> <bound-record-hash>'
  check_record_hash "$1" "$2"
  load_record "$1"
  check_current "$(record_field pr)" "$(record_field head)" "$(record_field check)" "$(record_field producer_app)"
}

cmd_action() {
  [ "$#" -eq 2 ] || die 'usage: action <watch-ref> <bound-record-hash>'
  check_record_hash "$1" "$2"
  load_record "$1"
  check_current "$(record_field pr)" "$(record_field head)" "$(record_field check)" "$(record_field producer_app)" \
    || die 'check is no longer green at action boundary'
  printf 'watch_ref=%s\nhead=%s\nobserved_at=%s\ncheck=%s\nproducer=app:%s\n' \
    "$1" "$(record_field head)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(record_field check)" "$(record_field producer_app)"
}

cmd_retire() {
  [ "$#" -eq 1 ] || die 'usage: retire <watch-ref>'
  local ref=$1 name
  valid_ref "$ref" || die 'invalid watch reference'
  [ -f "$(record_path "$ref")" ] || { printf 'state=absent\nwatch_ref=%s\n' "$ref"; return 0; }
  load_record "$ref"
  [ "$(local_state "$ref")" != result-unhandled ] || die 'handle the terminal result before retiring'
  name=${ref#when-}
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$name" >/dev/null
  rm -f "$(record_path "$ref")"
  printf 'state=retired\nwatch_ref=%s\n' "$ref"
}

cmd_rearm() {
  [ "$#" -eq 1 ] || die 'usage: rearm <watch-ref>'
  local ref=$1 task url check app next
  load_record "$ref"
  [ "$(local_state "$ref")" = ended ] || die 'handle the terminal result before re-arming'
  task=$(record_field task); url=$(record_field pr); check=$(record_field check); app=$(record_field producer_app)
  next=$($0 arm "$task" "$url" "$check" --producer-app "$app") || die 'new generation could not be armed'
  cmd_retire "$ref" >/dev/null
  printf '%s\n' "$next"
}

verb=${1-}
[ "$#" -gt 0 ] || die 'usage: arm|status|retire|rearm <args>'
shift
case "$verb" in
  --help|-h) usage ;;
  arm) cmd_arm "$@" ;;
  status) cmd_status "$@" ;;
  retire) cmd_retire "$@" ;;
  rearm) cmd_rearm "$@" ;;
  condition) cmd_condition "$@" ;;
  action) cmd_action "$@" ;;
  *) die 'usage: arm|status|retire|rearm <args>' ;;
esac
