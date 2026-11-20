# shellcheck shell=bash
# fm-failover-lib.sh - the provider failover order and the provider-error
# record, shared by bin/fm-failover.sh and the watcher (bin/fm-watch.sh).
# Sourced, never executed, with no side effects on source: every function
# reads its arguments or the files it is given.
#
# Order (config/failover-order; docs/configuration.md "Provider failover" owns
# the operator contract): one entry per line, `#` lines and blank lines
# ignored. An entry is `<harness>[:<model>][@<account>] [host=<ssh-host>]`:
#   <account>  `next` (every other declared config/claude-accounts entry, in
#              file order), `ordinary`, or one absolute declared path; Claude
#              only, and an account path holds no whitespace.
#   host=      the entry runs on that host. Ordinary workers are not remotely
#              placeable and a primary successor launches locally, so this
#              side skips it; the host's own home fails over its own lanes.
# Two setting lines may appear among the entries:
#   off             automatic failover is off: the watcher and the Claude
#                   hooks record a refusal without relaunching anything, and
#                   `fm-failover.sh worker` and `captain` refuse.
#   min-5h <0-100>  the preflight excludes an account with less than this
#                   percent of its five-hour window left (default 30).
# Without the file the order is FM_FAILOVER_DEFAULT_ORDER: codex, then droid,
# then another declared Claude account.
#
# Record: state/<task-id>.provider-error, or state/captain.provider-error for
# the primary session, one line replaced atomically:
#   v1<TAB><epoch><TAB><class><TAB><source><TAB><gen><TAB><detail>
# class is rate_limit, usage_limit, or billing; source and gen are tokens
# (gen is the task's busy generation, `-` when none); detail is one safe token.

FM_FAILOVER_DEFAULT_ORDER='codex
droid
claude@next'
FM_FAILOVER_RECORD_MAX_AGE=${FM_FAILOVER_RECORD_MAX_AGE:-1800}
# Field separator of an order row: not whitespace, so `read` keeps an empty
# field instead of folding it into the next one.
FM_FO_SEP=$'\037'

# fm_failover_order_load <config-dir>
# Sets FM_FO_ENTRIES (array of `<harness> <model> <account> <host>` joined by
# FM_FO_SEP, empty fields for an unnamed axis), FM_FO_OFF (0|1), FM_FO_MIN_5H, and
# FM_FO_SOURCE (the file, or `default`). Prints one error and returns 1 for a
# malformed file.
# shellcheck disable=SC2034  # FM_FO_* are read by the sourcing script.
fm_failover_order_load() {
  local cfg="$1/failover-order" body line runtime host extra harness model account has_at n=0
  FM_FO_ENTRIES=()
  FM_FO_OFF=0
  FM_FO_MIN_5H=30
  FM_FO_SOURCE=default
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    [ -f "$cfg" ] && [ -r "$cfg" ] || { printf 'error: config/failover-order must be a readable regular file: %s\n' "$cfg"; return 1; }
    body=$(cat "$cfg") || { printf 'error: cannot read %s\n' "$cfg"; return 1; }
    FM_FO_SOURCE=$cfg
  else
    body=$FM_FAILOVER_DEFAULT_ORDER
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in *[[:cntrl:]]*) printf 'error: config/failover-order line %s holds a control character\n' "$n"; return 1 ;; esac
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$line" in ''|'#'*) continue ;; esac
    if [ "$line" = off ]; then
      FM_FO_OFF=1
      continue
    fi
    runtime='' host='' extra=''
    read -r runtime host extra <<< "$line"
    if [ "$runtime" = min-5h ]; then
      case "$host" in ''|*[!0-9]*) printf 'error: config/failover-order line %s: min-5h needs a whole percent\n' "$n"; return 1 ;; esac
      [ -z "$extra" ] && [ "$((10#$host))" -le 100 ] || { printf 'error: config/failover-order line %s: min-5h needs one percent from 0 to 100\n' "$n"; return 1; }
      FM_FO_MIN_5H=$((10#$host))
      continue
    fi
    [ -z "$extra" ] || { printf 'error: config/failover-order line %s: expected <harness>[:<model>][@<account>] [host=<ssh-host>]\n' "$n"; return 1; }
    case "$host" in
      '') ;;
      host=?*) host=${host#host=} ;;
      *) printf 'error: config/failover-order line %s: unknown field %s\n' "$n" "$host"; return 1 ;;
    esac
    case "$host" in *[!A-Za-z0-9._@-]*) printf 'error: config/failover-order line %s: invalid host\n' "$n"; return 1 ;; esac
    account='' has_at=0
    case "$runtime" in *@*) has_at=1; account=${runtime#*@}; runtime=${runtime%%@*} ;; esac
    harness=${runtime%%:*}
    model=''
    [ "$harness" = "$runtime" ] || model=${runtime#*:}
    case "$harness" in ''|*[!a-z0-9-]*) printf 'error: config/failover-order line %s: invalid harness\n' "$n"; return 1 ;; esac
    if [ "$harness" != "$runtime" ]; then
      case "$model" in ''|-*|*[!A-Za-z0-9._/:-]*) printf 'error: config/failover-order line %s: invalid model\n' "$n"; return 1 ;; esac
    fi
    if [ "$has_at" = 1 ]; then
      [ "$harness" = claude ] || { printf 'error: config/failover-order line %s: only claude entries name an account\n' "$n"; return 1; }
      case "$account" in next|ordinary|/*) ;; *) printf 'error: config/failover-order line %s: account must be next, ordinary, or an absolute path\n' "$n"; return 1 ;; esac
    fi
    FM_FO_ENTRIES+=("$harness$FM_FO_SEP$model$FM_FO_SEP$account$FM_FO_SEP$host")
  done <<< "$body"
  return 0
}

# fm_failover_label <harness> <model> <account>
# One safe token naming a runtime, as the dispatch log and records print it:
# <harness>[:<model>][@<account>], an account path folded to its last segment;
# bin/fm-failover.sh refuses an order in which two runtimes share a label.
fm_failover_label() {
  local label=$1 account=${3:-}
  [ -z "${2:-}" ] || [ "$2" = default ] || label="$label:$2"
  if [ -n "$account" ]; then
    case "$account" in /*) account=${account%/}; account=${account##*/} ;; esac
    label="$label@$account"
  fi
  label=${label//[^A-Za-z0-9_.:\/@-]/_}
  printf '%s\n' "$label"
}

fm_failover_class_valid() {
  case "${1:-}" in rate_limit|usage_limit|billing) return 0 ;; esac
  return 1
}

fm_failover_record_path() {  # <state-dir> <task-id|captain>
  printf '%s/%s.provider-error\n' "$1" "$2"
}

# fm_failover_record_write <state-dir> <id> <class> <source> <gen> <detail>
fm_failover_record_write() {
  local path tmp gen=${5:-} detail=${6:-}
  fm_failover_class_valid "$3" || return 1
  path=$(fm_failover_record_path "$1" "$2")
  [ -n "$gen" ] || gen=-
  detail=${detail//[^A-Za-z0-9_.:\/@-]/_}
  tmp="$path.tmp.$$"
  if printf 'v1\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$3" "${4//[^A-Za-z0-9_.:-]/_}" "${gen//[^A-Za-z0-9._-]/_}" "${detail:--}" > "$tmp" \
    && mv -f "$tmp" "$path"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# fm_failover_record_class <state-dir> <id>
# Prints the class of a record that still describes the agent's last turn:
# its gen matches the task's busy generation and the busy record still names
# a stop-failure turn end, or, for an id with no busy generation, the record
# is younger than FM_FAILOVER_RECORD_MAX_AGE seconds. Returns 1 otherwise.
# Callers source bin/fm-busy-lib.sh.
fm_failover_record_class() {
  local path line ver epoch class _source gen _detail current busy now max=$FM_FAILOVER_RECORD_MAX_AGE
  path=$(fm_failover_record_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r line < "$path" 2>/dev/null || return 1
  IFS=$'\t' read -r ver epoch class _source gen _detail <<< "$line"
  [ "$ver" = v1 ] && fm_failover_class_valid "$class" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  if current=$(fm_busy_current_gen "$1" "$2" 2>/dev/null); then
    [ "$gen" = "$current" ] || return 1
    busy=$(fm_busy_record_read "$1" "$2" 2>/dev/null) || return 1
    case " $busy " in *" stop-failure "*) ;; *) return 1 ;; esac
  else
    case "$max" in ''|*[!0-9]*) max=1800 ;; esac
    now=$(date +%s)
    [ $((now - epoch)) -le "$max" ] || return 1
  fi
  printf '%s\n' "$class"
}

# fm_failover_turn_end_known <state-dir> <id>
# Returns 0 when the task's armed busy record comes from the Claude hook and
# names an idle turn end other than stop-failure: Claude reports every API
# refusal as a stop-failure, so its screen is not read for one after an
# ordinary stop. Any other source, or no valid record, returns 1.
# Callers source bin/fm-busy-lib.sh.
fm_failover_turn_end_known() {
  local busy st src ev _seq
  busy=$(fm_busy_record_read "$1" "$2" 2>/dev/null) || return 1
  read -r st src ev _seq <<< "$busy"
  [ "$st" = idle ] && [ "$src" = claude-hook ] && [ "$ev" != stop-failure ]
}
# fm_failover_hook_class <stop-failure-json>
# Maps a Claude StopFailure payload to a class: rate_limit (usage_limit when
# the last message states a usage limit), billing_error or account_on_hold to
# billing. Any other error, or an unreadable payload, returns 1. Callers
# source bin/fm-watchdog-lib.sh.
fm_failover_hook_class() {
  local err msg
  err=$(printf '%s' "$1" | jq -r '.error // empty' 2>/dev/null) || return 1
  case "$err" in
    rate_limit)
      msg=$(printf '%s' "$1" | jq -r '.last_assistant_message // empty' 2>/dev/null) || msg=
      if [ -n "$msg" ] && fm_wd_usage_limit_text "$msg"; then printf 'usage_limit\n'; else printf 'rate_limit\n'; fi
      ;;
    billing_error|account_on_hold) printf 'billing\n' ;;
    *) return 1 ;;
  esac
}
