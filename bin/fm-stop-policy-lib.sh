# shellcheck shell=bash
# Primary Stop continuation policy. Monitoring never uses this as an arm gate.
# fm_stop_policy_allows_stop <payload-json> [check|supervise|charge|repair|rewake]
# returns 0 to suppress a model continuation, 1 to retain existing behavior.
# check honors stop_hook_active and parked work; supervise checks parked work
# but leaves Claude's missing-supervision recovery intact. Neither check mode
# parses transcripts, reads HEAD, acquires a lock or spends continuation budget.
# charge reserves a continuation; repair ignores the active-hook shortcut so
# missing monitoring can recover; rewake also ignores the parked shortcut,
# because its caller has just observed a real watcher close. All state and
# transcript evidence is read at invocation time, never cached at hook startup.
#
# Parked means every metadata task's reconciled status is a declared pause or
# captain-held transfer, or only parked orders remain. Executable orders,
# received/queued intake, queued wakes, sources, trusted checks and relay polling
# prevent this shortcut. Unknown tasks do too. No work or wake is acknowledged.
#
# state/.stop-hook.<session>.json stores a rolling 3600-second reservation
# ledger, transcript event, normalized reply SHA-256, tool count, HEAD, wake
# fingerprint and repeat streak. Transcript parsing and HEAD reads precede the
# small locked read-modify-write. Parallel writers charge one transcript event
# once. Without a transcript, each charge conservatively consumes budget.
# Three identical case/whitespace-normalized replies without tools or commits
# suppress continuation. New external wake state starts a fresh streak so an
# old hook loop cannot hide a later real event. Six reservations per rolling
# hour prevent a seventh. Unsafe session ids do not create ledger paths.
# Policy errors suppress model turns, never monitoring. The auto-arm retains
# its generation and retries tokenlessly until fresh state permits a rewake.
#
# Watchdog format, appended to state/stop-hook.log, never hook stdout:
# STOPHOOK v1 ts=<epoch> session=<safe-id> status=<status> turns=<n> repeat=<n>
# status: parked, hook_active, hook_loop, hook_budget, continue, policy_error.
# ts is UTC Unix seconds; safe-id matches [A-Za-z0-9_-]{1,128}; turns counts
# rolling-hour reservations; repeat counts identical no-progress replies.
# Early parked/active/error exits use zero counts. Cached events do not emit
# duplicate records. Check-mode uncertainty preserves existing behavior.

fm_stop_policy_parked() { # <state> <home> <script-dir>
  local state=$1 home=$2 script_dir=$3 meta line seen=0 order check data
  data=${FM_DATA_OVERRIDE:-$home/data}
  [ ! -s "$state/.wake-queue" ] || return 1
  if ! declare -F fm_sup_open_goal >/dev/null; then
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$script_dir/fm-supervision-lib.sh"
  fi
  fm_sup_open_goal "$state" && return 1
  for order in "$data"/orders/{pending,acked}/*.order; do
    [ -f "$order" ] || continue
    grep -qx 'kind=hold' "$order" || return 1
  done
  for check in "$state"/procevent/*.source "$state"/*.check-trust "$state"/x-watch.check.sh; do
    [ ! -e "$check" ] || return 1
  done
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    seen=1
    [ -s "${meta%.meta}.status" ] || return 1
    if ! declare -F status_current_line >/dev/null; then
      # shellcheck source=bin/fm-classify-lib.sh
      . "$script_dir/fm-classify-lib.sh"
    fi
    line=$(last_status_line "${meta%.meta}.status")
    status_is_paused_or_captain_held "$line" || return 1
    line=$(status_current_line "${meta%.meta}.status" '') || return 1
    status_is_paused_or_captain_held "$line" || return 1
  done
  if [ "$seen" -eq 0 ]; then
    for order in "$data"/orders/parked/*.order; do
      [ ! -f "$order" ] || seen=1
    done
  fi
  [ "$seen" -eq 1 ]
}

fm_stop_policy_allows_stop() (
  local payload=$1 mode=${2:-check} session active state home script_dir now record lock
  local old snapshot event='' reply='' tools=unknown human=unknown turn_tools=unknown
  local commit wake decision count streak tmp result allow reason cached fields
  script_dir=${BASH_SOURCE[0]%/*}
  state=${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}}
  home=${FM_HOME:?}
  command -v jq >/dev/null 2>&1 || return 1
  fields=$(printf '%s' "$payload" | jq -er '
    if type != "object" then error("payload") else . end
    | [(.session_id // "" | strings | if test("^[A-Za-z0-9_-]{1,128}$") then . else "" end),
       (if has("stopHookActive") then .stopHookActive == true else .stop_hook_active == true end)] | @tsv' 2>/dev/null) || return 1
  session=${fields%%$'\t'*}
  active=${fields#*$'\t'}
  # The guard and auto-arm already verified ownership. Other Stop writers must
  # remain read-only when a known competing session owns the home.
  if [ "${FM_STOP_POLICY_OWNER_CHECKED:-0}" != 1 ] && [ -s "$state/.lock" ]; then
    if ! declare -F fm_session_lock_foreign_owner_live >/dev/null; then
      # shellcheck source=bin/fm-session-lock-lib.sh
      . "$script_dir/fm-session-lock-lib.sh"
    fi
    fm_session_lock_foreign_owner_live "$state" && return 1
  fi
  fm_stop_policy_log() {
    printf 'STOPHOOK v1 ts=%s session=%s status=%s turns=%s repeat=%s\n' \
      "${now:-$(date +%s)}" "$session" "$1" "${2:-0}" "${3:-0}" >> "$state/stop-hook.log"
  }
  case "$mode" in
    check|charge)
      if [ "$active" = true ]; then
        [ -z "$session" ] || fm_stop_policy_log hook_active
        return 0
      fi ;;
  esac
  [ -n "$session" ] || return 1
  if [ "$mode" != rewake ] && fm_stop_policy_parked "$state" "$home" "$script_dir"; then
    fm_stop_policy_log parked; return 0
  fi
  case "$mode" in check|supervise) return 1 ;; esac

  # All expensive reads happen before taking the ledger lock.
  now=$(date +%s)
  snapshot=$(printf '%s' "$payload" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
  if [ -n "$snapshot" ] && [ -r "$snapshot" ] && [ -f "$snapshot" ]; then
    event=$(cksum < "$snapshot")
    snapshot=$(jq -nc 'reduce inputs as $r ({reply:"",tools:0,human:0,turn_tools:0};
      if $r.type == "user" then
        ($r.message.content | if type == "string" then . else [.[]? | objects | select(.type == "text") | .text] | join(" ") end) as $text
        | if $text != "" then .turn_tools=0
          | if ($text | test("Stop hook feedback|stop.hook";"i")) then . else .human+=1 end
          else . end
      elif $r.type == "assistant" then
        ([$r.message.content[]? | objects | select(.type == "tool_use")] | length) as $n
        | .tools += $n | .turn_tools += $n
        | ($r.message.content | if type == "string" then . else [.[]? | objects | select(.type == "text") | .text] | join(" ") end) as $text
        | if $text != "" then .reply=$text else . end
      elif $r.type == "response_item" then
        if ($r.payload.type == "function_call" or $r.payload.type == "custom_tool_call") then .tools+=1 | .turn_tools+=1
        elif $r.payload.type == "message" and $r.payload.role == "user" then .turn_tools=0 | .human+=1
        elif $r.payload.type == "message" and $r.payload.role == "assistant" then .reply=([$r.payload.content[]? | .text // empty] | join(" "))
        else . end
      else . end) | .reply |= (ascii_downcase | gsub("\\s+";" ") | sub("^ +";"") | sub(" +$";""))' "$snapshot" 2>/dev/null) || snapshot='{}'
    reply=$(printf '%s' "$snapshot" | jq -r '.reply // ""')
    if [ -n "$reply" ]; then reply=$(printf '%s' "$reply" | shasum -a 256) || reply=; reply=${reply%% *}; fi
    fields=$(printf '%s' "$snapshot" | jq -r '[(.tools // "unknown"),(.human // "unknown"),(.turn_tools // "unknown")] | @tsv')
    IFS=$'\t' read -r tools human turn_tools <<< "$fields"
  fi
  commit=$(git -C "${FM_ROOT:-$home}" rev-parse HEAD 2>/dev/null || true)
  wake=none
  [ ! -f "$state/.wake-queue" ] || wake=$(cksum < "$state/.wake-queue") || wake=none
  record="$state/.stop-hook.$session.json"
  lock="$record.lock"
  if ! declare -F fm_lock_try_acquire >/dev/null; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$script_dir/fm-wake-lib.sh"
  fi
  for count in 1 2 3 4 5 6 7 8 9 10; do
    fm_lock_try_acquire "$lock" && break
    sleep 0.05
  done
  if [ "${FM_LOCK_OWNER_DIR:-}" = '' ]; then fm_stop_policy_log policy_error; return 0; fi
  trap 'fm_lock_release "$lock"' EXIT
  old='{"times":[],"streak":0}'
  if [ -e "$record" ]; then
    old=$(cat "$record") || { fm_stop_policy_log policy_error; return 0; }
  fi
  decision=$(printf '%s' "$old" | jq -ce --argjson now "$now" --arg event "$event|$commit|$wake" --arg raw_event "$event" \
    --arg reply "$reply" --arg tools "$tools" --arg commit "$commit" --arg human "$human" --arg turn_tools "$turn_tools" --arg wake "$wake" '
      select(.times | type == "array") | .times |= map(select(. > ($now-3600)))
      | if $raw_event != "" and .event == $event and .reason != "hook_budget" then .cached=true
        else .cached=false
          | if (.times|length) >= 6 then .allow=true | .reason="hook_budget"
            else .streak=(if $turn_tools != "0" or (has("tools") and (.tools != $tools or .commit != $commit)) then 0
              elif $reply != "" and .reply == $reply and .human == $human and .wake == $wake then (.streak+1) else 1 end)
              | .allow=(.streak >= 3 and $reply != "" and $tools != "unknown")
              | if .allow then .reason="hook_loop" else .reason="continue" | .times+=[$now] end
            end
          | .event=$event | .reply=$reply | .tools=$tools | .commit=$commit | .human=$human | .wake=$wake
        end') || { fm_stop_policy_log policy_error; return 0; }
  tmp=$(mktemp "$record.XXXXXX") || { fm_stop_policy_log policy_error; return 0; }
  if ! { printf '%s\n' "$decision" > "$tmp" && mv -f "$tmp" "$record"; }; then
    rm -f "$tmp"; fm_stop_policy_log policy_error; return 0
  fi
  fm_lock_release "$lock"
  trap - EXIT
  result=$(printf '%s' "$decision" | jq -r '[.allow,.reason,(.times|length),.streak,.cached] | @tsv')
  IFS=$'\t' read -r allow reason count streak cached <<< "$result"
  [ "$cached" = true ] || fm_stop_policy_log "$reason" "$count" "$streak"
  [ "$allow" = true ]
)
