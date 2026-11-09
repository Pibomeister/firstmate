#!/usr/bin/env bash
# Optional process-event adapter and model preflight for a Mastra Factory
# (@mastra/factory) project's attention inbox. It is inert until an operator
# writes config/factory and arms a project; it has no default URL, host, port
# or project, and reads only routes and fields of stock @mastra/factory 0.23.0.
#
# Usage:
#   fm-procevent-factory.sh arm --project <id> [--interval <secs>]
#   fm-procevent-factory.sh poll --project <id> [--interval <secs>]
#   fm-procevent-factory.sh preflight --project <id>
#   fm-procevent-factory.sh classify <result-file>
#   fm-procevent-factory.sh terminal <result-file>
#   fm-procevent-factory.sh summary <result-file>
#   fm-procevent-factory.sh source-id --project <id>
#   fm-procevent-factory.sh retire --project <id>
#
# arm        Register a watch on one Factory project's attention inbox through
#            `bin/fm-procevent.sh register`; source id `factory-<project-id>`.
#            Refuses unless config/factory is present and valid.
# poll       The blocking child the generic runner executes; never run this
#            in a conversational turn. Every <interval> seconds (default 60) it
#            reads `GET <url>/web/factory/projects/<id>/attention?kind=automation-failed&view=open&limit=50`,
#            following `nextCursor` for up to 200 pages (more ends the watch
#            with a diagnostic rather than miss a failure; a repeated cursor is
#            malformed), and exits with a
#            `status: failed` result once an item appears whose key no earlier
#            captured result of this source reported. The result carries one
#            `item:` line (key, failure code, error text, occurredAt) for the
#            oldest such item, so each failure gets its own result and wake;
#            failures already open at arm time are reported too, oldest first.
#            The captured results are the dedup record, so a crash before
#            capture re-detects instead of losing the failure. A failure result
#            is not terminal: the watcher's reconcile restarts the watch.
#            Three consecutive unreachable reads (connection failure, timeout,
#            or HTTP 5xx; a good read resets the count), one 401 or 403, any
#            other unexpected HTTP status, or a malformed or empty body or
#            cursor end the watch with one terminal `status: error` result
#            naming the cause, so a down Factory wakes once, not forever.
# preflight  Read-only. Report whether a newly prepared run session in the
#            project would get a usable model: the project's `defaultModelId`
#            and `modelScope` (hybrid resolves to factory for runs) from
#            `GET /web/factory/projects/<id>`, checked against
#            `GET /web/config/models?factoryId=<id>`, which lists only models
#            whose provider has a credential in the project's scope. That
#            catalog proves a credential is present, not that it is still valid.
#            Exit 0 usable, 1 not usable (no default model, model not in the
#            catalog, project not found), 3 cannot determine (user model scope,
#            no catalog exposed, Factory unreachable or auth refused), 2 usage.
# classify   Print failed, error, or unknown for a captured result.
# terminal   Exit 0 only for an error result.
# summary    Print one bounded line for the wake reason: the failure's error
#            text, or the reason the watch stopped.
# source-id  Print the canonical source id.
# retire     Stop the project's watch and retire its registration.
#
# Operator config lives in the private, gitignored `config/factory`, one
# `key=value` per line: `url=` (required, http or https base URL) and
# `token_file=` (optional path to a private file holding one bearer
# token line). A URL with embedded credentials, a query string or a fragment
# is refused, so nothing secret rides it into argv or wakes. The token is passed
# to curl on stdin, never on its argv, curl ignores any host .curlrc, and the
# token never enters the registration. docs/configuration.md owns the schema.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="$FM_HOME/config/factory"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

DEFAULT_INTERVAL=60
MAX_CONSECUTIVE_READ_FAILURES=3
READ_TIMEOUT=20
# Pages read per poll before the watch stops rather than miss a failure. A
# Factory page holds at most 50 open items but scans at most 200 failed
# decisions, archived ones included, so this bounds failure history, not open
# items. FM_FACTORY_MAX_PAGES overrides it for tests.
MAX_PAGES=${FM_FACTORY_MAX_PAGES:-200}
DETAIL_MAX=512

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

PROJECT=
INTERVAL=$DEFAULT_INTERVAL
URL=
TOKEN=

parse_project_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)  [ -n "${2-}" ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
      --interval) [ -n "${2-}" ] || die "--interval needs a value"; INTERVAL=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$PROJECT" ] || die "--project is required"
  [[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,55}$ ]] || die "invalid project id: $PROJECT"
  [[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ ! "$INTERVAL" =~ ^0+(\.0+)?$ ]] \
    || die "--interval needs a positive number"
  SOURCE_ID="factory-$PROJECT"
  fm_procevent_source_id_valid "$SOURCE_ID" || die "source id is not path-safe: $SOURCE_ID"
}

# Load config/factory into URL and TOKEN. Returns 1 with CONFIG_ERROR set.
load_config() {
  local key value token_file=''
  CONFIG_ERROR=
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || { CONFIG_ERROR='missing operator config: config/factory'; return 1; }
  URL=
  while IFS='=' read -r key value; do
    case "$key" in
      url) URL=$value ;;
      token_file) token_file=$value ;;
      ''|'#'*) ;;
    esac
  done < "$CONFIG"
  URL=${URL%/}
  [[ "$URL" =~ ^https?://[^[:space:]\"\\]+$ ]] || { CONFIG_ERROR='config/factory url= must be an http or https URL'; return 1; }
  # The URL is echoed into diagnostics and wakes, so it must not carry credentials.
  [[ ! "$URL" =~ ^https?://[^/]*@ ]] || { CONFIG_ERROR='config/factory url= must not embed credentials; use token_file='; return 1; }
  # API paths are appended to the base URL, so a query or fragment is never
  # usable there and could carry a credential into argv and wakes.
  [[ "$URL" != *[?#]* ]] || { CONFIG_ERROR='config/factory url= must not carry a query string or fragment; use token_file= for credentials'; return 1; }
  TOKEN=
  if [ -n "$token_file" ]; then
    [ -f "$token_file" ] && [ -r "$token_file" ] || { CONFIG_ERROR='config/factory token_file is not a readable file'; return 1; }
    IFS= read -r TOKEN < "$token_file" || [ -n "$TOKEN" ] || { CONFIG_ERROR='config/factory token_file is empty'; return 1; }
    [[ "$TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || { CONFIG_ERROR='config/factory token_file must hold one bearer token line'; return 1; }
  fi
}

# http_get <path-and-query>: sets HTTP_STATUS and HTTP_BODY. Returns 0 when an
# HTTP answer arrived, 1 on a transport failure with HTTP_ERROR set.
http_get() {
  local body status rc=0
  body=$(mktemp "${TMPDIR:-/tmp}/fm-factory.XXXXXX") || { HTTP_ERROR="cannot create a temporary file"; return 1; }
  # The token reaches curl through its stdin config, so it never sits on argv;
  # -q (which must come first) keeps a host .curlrc from adding a proxy or
  # weakening TLS for the authenticated request.
  status=$( { [ -z "$TOKEN" ] || printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"; } \
    | curl -q -sS -K - --max-time "$READ_TIMEOUT" -o "$body" -w '%{http_code}' -- "$URL$1" 2>"$body.err") || rc=$?
  HTTP_BODY=$(cat "$body" 2>/dev/null)
  HTTP_ERROR=$(head -1 "$body.err" 2>/dev/null)
  rm -f -- "$body" "$body.err"
  HTTP_STATUS=$status
  if [ "$rc" -ne 0 ] || [ -z "$status" ] || [ "$status" = 000 ]; then
    HTTP_ERROR=${HTTP_ERROR:-curl exit $rc}
    return 1
  fi
  return 0
}

one_line() { tr '\t\r\n' '   ' | cut -c "1-$DETAIL_MAX"; }

# Keys every earlier captured result of this source already reported.
reported_keys() {
  local inbox result
  inbox=$(fm_procevent_inbox_dir "$STATE")
  for result in "$inbox/$SOURCE_ID".*.result; do
    [ -f "$result" ] || continue
    awk -F '\t' '/^item: / { sub(/^item: /, "", $1); print $1 }' "$result"
  done
}

emit_error() {  # <polls> <detail>
  printf 'factory: %s\nstatus: error\nproject: %s\ndetail: %s\ncondition_polls: %s\n' \
    "$SOURCE_ID" "$PROJECT" "$(printf '%s' "$2" | one_line)" "$1"
  exit 0
}

# read_failures: read every page of open automation-failed items, newest
# first, into ITEMS as tab-separated key, failure code, error text, occurredAt.
# Returns 1 on a transient failure with READ_ERROR set; ends the watch through
# emit_error on a terminal one.
read_failures() {
  local cursor='' pages=0 page next
  ITEMS=
  while :; do
    pages=$((pages + 1))
    http_get "/web/factory/projects/$PROJECT/attention?kind=automation-failed&view=open&limit=50${cursor:+&before=$cursor}" \
      || { READ_ERROR=$HTTP_ERROR; return 1; }
    case "$HTTP_STATUS" in
      200) ;;
      401|403) emit_error "$POLLS" "Factory at $URL refused the attention read: HTTP $HTTP_STATUS (check config/factory token_file)" ;;
      5??) READ_ERROR="HTTP $HTTP_STATUS"; return 1 ;;
      *) emit_error "$POLLS" "Factory at $URL answered the attention read with HTTP $HTTP_STATUS" ;;
    esac
    # -n with input fails on an empty body, which a bare filter would read as no items.
    page=$(printf '%s' "$HTTP_BODY" | jq -nr 'input
      | .items | if type == "array" then . else error("no items") end
      | .[] | select(.kind == "automation-failed" and (.key | type) == "string")
      | [.key, (.failureCode // "" | tostring), (.detail // .title // "" | tostring), (.occurredAt // "" | tostring)] | @tsv' 2>/dev/null) \
      || emit_error "$POLLS" "Factory at $URL returned a malformed attention response"
    [ -z "$page" ] || ITEMS+="$page"$'\n'
    [ "$(printf '%s' "$HTTP_BODY" | jq -r '.hasMore == true' 2>/dev/null)" = true ] || return 0
    next=$(printf '%s' "$HTTP_BODY" | jq -r '.nextCursor // ""' 2>/dev/null)
    [[ "$next" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$next" != "$cursor" ] \
      || emit_error "$POLLS" "Factory at $URL returned a malformed attention cursor"
    # Stopping loudly at the bound, rather than treating it as the end of the
    # inbox, is what keeps a failure past it from being silently never reported.
    [ "$pages" -lt "$MAX_PAGES" ] \
      || emit_error "$POLLS" "Factory at $URL has more than $MAX_PAGES pages of automation-failed history; the watch stopped rather than miss a failure"
    cursor=$next
  done
}

cmd_poll() {
  parse_project_args "$@"
  local failures=0 seen new
  POLLS=0
  [[ "$MAX_PAGES" =~ ^[1-9][0-9]{0,3}$ ]] || emit_error 1 "FM_FACTORY_MAX_PAGES must be a whole number from 1 to 9999"
  load_config || emit_error 1 "$CONFIG_ERROR"
  while :; do
    POLLS=$((POLLS + 1))
    if ! read_failures; then
      failures=$((failures + 1))
      [ "$failures" -lt "$MAX_CONSECUTIVE_READ_FAILURES" ] && { sleep "$INTERVAL"; continue; }
      emit_error "$POLLS" "Factory at $URL unreachable: $failures consecutive failed reads; last: $READ_ERROR"
    fi
    failures=0
    seen=$(reported_keys)
    # Items arrive newest first; report only the oldest unreported one, so every
    # failure gets its own result and wake. awk keeps empty fields, unlike read,
    # which would merge the tabs around a null failure code. @tsv already
    # escaped tabs and newlines inside each field.
    new=$(printf '%s' "$ITEMS" | FM_FACTORY_SEEN="$seen" awk -F '\t' -v max="$DETAIL_MAX" '
      BEGIN { n = split(ENVIRON["FM_FACTORY_SEEN"], s, "\n"); for (i = 1; i <= n; i++) known[s[i]] = 1 }
      $1 != "" && !($1 in known) { line = "item: " $1 "\t" $2 "\t" substr($3, 1, max) "\t" $4 }
      END { if (line != "") print line }')
    if [ -n "$new" ]; then
      printf 'factory: %s\nstatus: failed\nproject: %s\n%s\ncondition_polls: %s\n' \
        "$SOURCE_ID" "$PROJECT" "$new" "$POLLS"
      exit 0
    fi
    sleep "$INTERVAL"
  done
}

cmd_arm() {
  parse_project_args "$@"
  load_config || die "$CONFIG_ERROR"
  "$SCRIPT_DIR/fm-procevent.sh" register factory "$SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-factory.sh" poll --project "$PROJECT" --interval "$INTERVAL" || exit 1
  printf 'armed: %s\ninterval: %ss\n' "$SOURCE_ID" "$INTERVAL"
}

preflight_undetermined() { printf 'cannot determine: %s\n' "$1"; exit 3; }
preflight_unusable() { printf 'not usable: %s\n' "$1"; exit 1; }

cmd_preflight() {
  parse_project_args "$@"
  local scope model listed
  load_config || preflight_undetermined "$CONFIG_ERROR"
  http_get "/web/factory/projects/$PROJECT" \
    || preflight_undetermined "Factory at $URL unreachable: $HTTP_ERROR"
  case "$HTTP_STATUS" in
    200) ;;
    401|403) preflight_undetermined "Factory at $URL refused the project read: HTTP $HTTP_STATUS" ;;
    404) preflight_unusable "project $PROJECT not found" ;;
    *) preflight_undetermined "Factory at $URL answered the project read with HTTP $HTTP_STATUS" ;;
  esac
  scope=$(printf '%s' "$HTTP_BODY" | jq -r '.project.modelScope // empty' 2>/dev/null)
  model=$(printf '%s' "$HTTP_BODY" | jq -r '.project.defaultModelId // empty' 2>/dev/null)
  case "$scope" in
    factory|hybrid) ;;
    user) preflight_undetermined "project $PROJECT uses per-user model scope; a run session takes its owner's default model, which this read cannot see" ;;
    *) preflight_undetermined "Factory exposes no modelScope for project $PROJECT" ;;
  esac
  [ -n "$model" ] || preflight_unusable "project $PROJECT has no default model; a run session would fall back to an unpinned mode default"
  http_get "/web/config/models?factoryId=$PROJECT" \
    || preflight_undetermined "Factory at $URL unreachable: $HTTP_ERROR"
  if [ "$HTTP_STATUS" != 200 ] || ! printf '%s' "$HTTP_BODY" | jq -e '.models | type == "array"' >/dev/null 2>&1; then
    preflight_undetermined "Factory at $URL exposes no model catalog for admission (HTTP $HTTP_STATUS)"
  fi
  listed=$(printf '%s' "$HTTP_BODY" | jq -r --arg m "$model" 'any(.models[]; .id == $m)')
  [ "$listed" = true ] \
    || preflight_unusable "default model $model is not in the Factory's credentialed model catalog for project $PROJECT"
  printf 'usable: %s (scope %s; provider credential present, validity not checked)\n' "$model" "$scope"
}

result_status() {
  awk '/^status: / { sub(/^status: /, ""); print; exit }' "$1"
}

cmd_classify() {
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  case "$(result_status "$1")" in
    failed) echo failed ;;
    error) echo error ;;
    *) echo unknown ;;
  esac
}

cmd_terminal() {
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  [ "$(result_status "$1")" = error ]
}

cmd_summary() {
  local file=${1-}
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(result_status "$file")" in
    failed)
      awk -F '\t' '/^item: / { printf "Factory automation failed at %s: %s\n", ($4 == "" ? "unknown time" : $4), $3; exit }' "$file" | cut -c 1-300
      ;;
    error)
      printf 'Factory watch stopped: %s\n' "$(awk '/^detail: / { sub(/^detail: /, ""); print; exit }' "$file")" | cut -c 1-300
      ;;
    *) return 1 ;;
  esac
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  summary)   shift; cmd_summary "$@" ;;
  source-id) shift; parse_project_args "$@"; printf '%s\n' "$SOURCE_ID" ;;
  retire)    shift; parse_project_args "$@"; "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
