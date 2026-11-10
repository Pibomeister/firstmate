# shellcheck shell=bash
# Shared primary Stop continuation policy. Source, then call
# fm_stop_policy_allows_stop <payload-json> [check|charge]. Return 0 means stop;
# 1 means retain the caller's existing supervision behavior. check runs before
# any watcher/repair work; charge runs immediately before requesting a turn.
# All Claude Stop writers and the shared turn-end guard use this owner.
#
# A typed true stopHookActive (preferred) or stop_hook_active always stops.
# Parked means every metadata task's reconciled current status is a declared
# pause or captain-held transfer, or only parked orders remain. Pending/acked
# executable orders, received/queued intake, queued wakes, registered sources,
# custom checks and relay polling prevent this shortcut. Unknown tasks do too.
# No task, order, decision or wake is resolved or acknowledged by this policy.
#
# state/.stop-hook.<session>.json holds a rolling 3600-second continuation
# ledger, last event, reply hash, tool count, commit and repeat streak. The three
# parallel Claude hooks charge a transcript snapshot
# once, under the existing identity-aware lock. Without a transcript, each charge
# consumes budget conservatively. Without a safe session id no ledger is used.
# Three consecutive charged attempts with the same case/whitespace-normalized
# nonempty final reply and no tool count/HEAD change allow stop. Six actual
# continuation reservations in the rolling hour prevent a seventh. A new tool
# call, commit or reply resets the streak; user turns stay subject to the hour
# cap. Transcript parsing streams JSONL and retains only the latest reply and
# total tool calls (Claude tool_use and Codex function/custom tool calls).
#
# Watchdog wire format, appended only to state/stop-hook.log (never hook stdout):
# STOPHOOK v1 ts=<epoch> session=<safe-id> status=<status> turns=<n> repeat=<n>
# status: parked, hook_active, hook_loop, hook_budget, continue, policy_error.
# ts is UTC Unix seconds; turns is the rolling-hour reservation count; repeat
# is the current identical no-progress streak. Early parked/active/error exits
# use zero counts. Repeated readers of one charged event emit no duplicate.
# A policy read/lock/write failure allows stop with policy_error, bounding quota
# consumption while preserving all durable work for the next external wake.

fm_stop_policy_parked() { # <state> <home>
  local state=$1 home=$2 meta line seen=0 order check data
  data=${FM_DATA_OVERRIDE:-$home/data}
  [ ! -s "$state/.wake-queue" ] || return 1
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
    line=$(status_current_line "${meta%.meta}.status") || return 1
    status_is_paused_or_captain_held "$line" || return 1
  done
  if [ "$seen" -eq 0 ]; then
    for order in "$data"/orders/parked/*.order; do
      [ ! -f "$order" ] || seen=1
    done
  fi
  [ "$seen" -eq 1 ]
}

fm_stop_policy_allows_stop() ( # subshell confines lock trap and sourced globals
  local payload=$1 mode=${2:-check} session active state home script_dir now record lock
  local old snapshot event reply tools commit decision count streak tmp human turn_tools
  script_dir=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" && pwd)
  state=${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}}
  home=${FM_HOME:?}
  command -v jq >/dev/null 2>&1 || return 1
  session=$(printf '%s' "$payload" | jq -er '.session_id | strings | select(test("^[A-Za-z0-9_-]{1,128}$"))' 2>/dev/null) || session=
  # Keep competing sessions read-only, including the new log/ledger writes.
  # The caller retains its existing foreign-owner diagnostic exit.
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$script_dir/fm-session-lock-lib.sh"
  fm_session_lock_foreign_owner_live "$state" && return 1
  now=$(date +%s)
  fm_stop_policy_log() {
    printf 'STOPHOOK v1 ts=%s session=%s status=%s turns=%s repeat=%s\n' \
      "$now" "$session" "$1" "${2:-0}" "${3:-0}" >> "$state/stop-hook.log"
  }
  active=$(printf '%s' "$payload" | jq -r 'if has("stopHookActive") then .stopHookActive == true else .stop_hook_active == true end' 2>/dev/null)
  if [ "$active" = true ]; then
    [ -z "$session" ] || fm_stop_policy_log hook_active
    return 0
  fi
  [ -n "$session" ] || return 1
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$script_dir/fm-supervision-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$script_dir/fm-classify-lib.sh"
  if fm_stop_policy_parked "$state" "$home"; then fm_stop_policy_log parked; return 0; fi

  record="$state/.stop-hook.$session.json"
  lock="$record.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$script_dir/fm-wake-lib.sh"
  # Parallel Stop hooks must serialize, not turn brief lock contention into an
  # allow/deny disagreement. Wait only for this small local ledger section.
  for count in 1 2 3 4 5 6 7 8 9 10; do
    fm_lock_try_acquire "$lock" && break
    sleep 0.05
  done
  if [ "${FM_LOCK_OWNER_DIR:-}" = '' ]; then fm_stop_policy_log policy_error; return 0; fi
  trap 'fm_lock_release "$lock"' EXIT
  old='{"times":[],"streak":0}'
  if [ -e "$record" ]; then
    old=$(jq -ce 'select(.times | type == "array")' "$record" 2>/dev/null) || { fm_stop_policy_log policy_error; return 0; }
  fi
  snapshot=$(printf '%s' "$payload" | jq -r '.transcript_path // empty | strings' 2>/dev/null)
  event=
  reply=
  tools=unknown
  human=unknown
  turn_tools=unknown
  if [ -n "$snapshot" ] && [ -f "$snapshot" ] && [ -r "$snapshot" ]; then
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
        | if $text != "" then .reply = $text else . end
      elif $r.type == "response_item" then
        if ($r.payload.type == "function_call" or $r.payload.type == "custom_tool_call") then .tools += 1 | .turn_tools += 1
        elif $r.payload.type == "message" and $r.payload.role == "user" then
          .turn_tools=0 | .human+=1
        elif $r.payload.type == "message" and $r.payload.role == "assistant" then
          .reply = ([$r.payload.content[]? | .text // empty] | join(" "))
        else . end
      else . end) | .reply |= (ascii_downcase | gsub("\\s+";" ") | sub("^ +";"") | sub(" +$";""))' "$snapshot" 2>/dev/null) || snapshot='{}'
    reply=$(printf '%s' "$snapshot" | jq -r '.reply // ""')
    if [ -n "$reply" ]; then
      reply=$(printf '%s' "$reply" | shasum -a 256) || reply=
      reply=${reply%% *}
    fi
    tools=$(printf '%s' "$snapshot" | jq -r '.tools // "unknown"')
    human=$(printf '%s' "$snapshot" | jq -r '.human // "unknown"')
    turn_tools=$(printf '%s' "$snapshot" | jq -r '.turn_tools // "unknown"')
  fi
  commit=$(git -C "${FM_ROOT:-$home}" rev-parse HEAD 2>/dev/null || true)
  if [ -n "$event" ] && [ "$(printf '%s' "$old" | jq -r '.event // empty')" = "$event|$commit" ]; then
    [ "$(printf '%s' "$old" | jq -r '.allow')" = true ]; return $?
  fi
  count=$(printf '%s' "$old" | jq --argjson now "$now" '[.times[] | select(. > ($now - 3600))] | length')
  if [ "$count" -ge 6 ]; then fm_stop_policy_log hook_budget "$count"; return 0; fi
  [ "$mode" = charge ] || return 1
  decision=$(printf '%s' "$old" | jq -c --argjson now "$now" --arg event "$event|$commit" \
    --arg reply "$reply" --arg tools "$tools" --arg commit "$commit" --arg human "$human" --arg turn_tools "$turn_tools" '
      .times |= map(select(. > ($now - 3600)))
      | .streak = (if $turn_tools != "0" or (has("tools") and (.tools != $tools or .commit != $commit)) then 0
          elif $reply != "" and $tools != "unknown" and .reply == $reply and .human == $human then (.streak + 1) else 1 end)
      | .allow = (.streak >= 3 and $reply != "" and $tools != "unknown")
      | if .allow then . else .times += [$now] end
      | .event=$event | .reply=$reply | .tools=$tools | .commit=$commit | .human=$human') || { fm_stop_policy_log policy_error; return 0; }
  tmp=$(mktemp "$record.XXXXXX") || { fm_stop_policy_log policy_error; return 0; }
  if ! { printf '%s\n' "$decision" > "$tmp" && mv -f "$tmp" "$record"; }; then
    rm -f "$tmp"; fm_stop_policy_log policy_error; return 0
  fi
  count=$(printf '%s' "$decision" | jq '.times | length')
  streak=$(printf '%s' "$decision" | jq '.streak')
  if [ "$(printf '%s' "$decision" | jq '.allow')" = true ]; then
    fm_stop_policy_log hook_loop "$count" "$streak"; return 0
  fi
  fm_stop_policy_log continue "$count" "$streak"
  return 1
)
