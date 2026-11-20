#!/usr/bin/env bash
# fm-captain-nudge-lib.sh - no-AI captain self-nudge decision and log helpers.
#
# Sourced, never executed, with no side effects on source. Nothing here calls a
# model, types into a pane, or mutates git/gh. bin/fm-captain-nudge.sh owns
# observation, send, install, and the outer-guard loop.
#
# The decision procedure, JSONL object, and NUDGE v1 beacon line are owned by
# docs/captain-nudge-spec.md. This file implements that contract.
#
# Public functions:
#   fm_nudge_text [continue|escalate|merge]
#       Prints one of the allowed prompts (default continue). Send paths must
#       compare against these.
#   fm_nudge_iso_ts [epoch]
#       ISO-8601 local timestamp with numeric offset (`2026-11-09T20:56:00-06:00`).
#   fm_nudge_decide <observation-json>
#       Prints one decision JSON object. Exit 0 always on a well-formed
#       observation; exit 2 on usage/parse failure.
#   fm_nudge_jsonl_line <event-json>
#       Prints one JSONL object with the required SPEC fields.
#   fm_nudge_beacon_line <event-json>
#       Prints one NUDGE v1 compact line (no pane text, no secrets).
#   fm_nudge_open_work_summary_flag <summary>
#       Prints 1 when the summary names open work, else 0.
#   fm_nudge_merge_ready_rows <discovery-json>
#       Prints one key<TAB>pr line per merge-ready (ci-ready) run.
#   fm_nudge_lane_stalls <ledger> <now> <min>
#       Prints open worker/secondmate stalls from a home's stall ledger.
#   fm_nudge_lane_table <lane-stalls> / fm_nudge_prompt_text <kind> [table]
#       Build the lane table suffix and the exact text to type.
#
# Observation JSON keys (all required unless noted):
#   idle_min, idle_threshold_min, open_work (bool), open_work_summary,
#   dialog (empty or a kind), composer (empty|pending|pending-unproven|unknown),
#   cooldown_remaining_min, consecutive_no_progress, progress_since_nudge (bool),
#   escalated (bool), max_no_progress (optional, default 2),
#   escalate_min, council_min, stall_tier, lane_age_min, lane_stall_min
#   (optional, default 0; 0 disables a tier or the lane signal). stall_tier is the highest tier already reached in this stall:
#   1 first wake, 2 second wake, 3 council row.
#
# Decision JSON: {event, severity, reason, should_send, prompt}. prompt is the
# fm_nudge_text kind to type when should_send is true, else empty.
#
# Test seam: FM_NUDGE_NOW (epoch) and FM_TEST_SEAM=1 pin the clock.

# The only strings this tool is allowed to type, one per prompt kind. Changing
# one here is a contract change: update docs/captain-nudge-spec.md in the same
# commit.
FM_NUDGE_TEXT_FIXED='Continue open work: pick next item, reroute quota if exhausted, never park self-servable work'
FM_NUDGE_TEXT_ESCALATE='Still stalled with open work: relaunch or replace the stalled worker, then continue open work'
FM_NUDGE_TEXT_MERGE='A PR is merge-ready and unmerged: dispatch the merge or record why'

fm_nudge_text() {  # [continue|escalate|merge]
  case "${1:-continue}" in
    continue) printf '%s\n' "$FM_NUDGE_TEXT_FIXED" ;;
    escalate) printf '%s\n' "$FM_NUDGE_TEXT_ESCALATE" ;;
    merge) printf '%s\n' "$FM_NUDGE_TEXT_MERGE" ;;
    *) return 1 ;;
  esac
}

# Epoch seconds. FM_NUDGE_NOW wins only under the test seam.
fm_nudge_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_NOW:-}" ]; then
    printf '%s\n' "$FM_NUDGE_NOW"
    return 0
  fi
  date +%s
}

# Portable path mtime in epoch seconds.
fm_nudge_mtime() {
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Expand a leading ~/ to $HOME. Other paths pass through.
fm_nudge_expand_path() {
  # shellcheck disable=SC2088 # The patterns match a literal "~/" config value.
  case "$1" in
    # Quoted: bash tilde-expands unquoted case patterns, so ~/* would never
    # match a literal "~/..." config value.
    '~/'*) printf '%s\n' "${HOME}/${1#'~/'}" ;;
    '~') printf '%s\n' "${HOME}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# ISO-8601 with colon in the offset. Optional epoch argument (GNU or BSD date).
fm_nudge_iso_ts() {
  local epoch=${1:-} raw tz
  if [ -n "$epoch" ]; then
    if raw=$(date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null); then
      :
    elif raw=$(date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null); then
      :
    else
      raw=$(date +%Y-%m-%dT%H:%M:%S%z)
    fi
  else
    raw=$(date +%Y-%m-%dT%H:%M:%S%z)
  fi
  tz=${raw: -5}
  case "$tz" in
    [+-][0-9][0-9][0-9][0-9])
      printf '%s%s:%s\n' "${raw%"$tz"}" "${tz%??}" "${tz#???}"
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

fm_nudge_json_get() {  # <json> <jq-filter> [default]
  local json=$1 filter=$2 default=${3-}
  local out
  out=$(printf '%s' "$json" | jq -er "$filter" 2>/dev/null) || {
    printf '%s' "$default"
    return 1
  }
  printf '%s' "$out"
}

fm_nudge_json_bool() {  # <json> <jq-filter>
  local v
  v=$(printf '%s' "$1" | jq -r "$2 | if . == true then \"true\" elif . == false then \"false\" else empty end" 2>/dev/null) || return 1
  [ "$v" = true ]
}

# 1 when the open-work summary names at least one item, else 0.
fm_nudge_open_work_summary_flag() {
  case "${1:-}" in
    ''|none|None|NONE|'0'|false|False) printf '0\n' ;;
    *) printf '1\n' ;;
  esac
}

# Decision procedure. Prints compact JSON:
#   {event, severity, reason, should_send, prompt}
# should_send is true only for a decision that may type the prompt kind named
# by prompt.
fm_nudge_decide() {
  local obs=${1-} idle idle_th open_sum dialog composer cool consec maxn
  local esc_min council_min tier lane_age lane_min stall lane_hit=false
  local open_work=false progress=false escalated=false council_raised=false
  [ -n "$obs" ] || { printf 'fm-captain-nudge-lib: decide needs observation JSON\n' >&2; return 2; }
  printf '%s' "$obs" | jq -e . >/dev/null 2>&1 || {
    printf 'fm-captain-nudge-lib: observation is not JSON\n' >&2
    return 2
  }

  idle=$(fm_nudge_json_get "$obs" '.idle_min' '') || true
  idle_th=$(fm_nudge_json_get "$obs" '.idle_threshold_min' '15') || true
  open_sum=$(fm_nudge_json_get "$obs" '.open_work_summary' 'none') || true
  dialog=$(fm_nudge_json_get "$obs" '.dialog' '') || true
  composer=$(fm_nudge_json_get "$obs" '.composer' 'unknown') || true
  cool=$(fm_nudge_json_get "$obs" '.cooldown_remaining_min' '0') || true
  consec=$(fm_nudge_json_get "$obs" '.consecutive_no_progress' '0') || true
  maxn=$(fm_nudge_json_get "$obs" '.max_no_progress' '2') || true
  esc_min=$(fm_nudge_json_get "$obs" '.escalate_min' '0') || true
  council_min=$(fm_nudge_json_get "$obs" '.council_min' '0') || true
  tier=$(fm_nudge_json_get "$obs" '.stall_tier' '0') || true
  lane_age=$(fm_nudge_json_get "$obs" '.lane_age_min' '0') || true
  lane_min=$(fm_nudge_json_get "$obs" '.lane_stall_min' '0') || true
  fm_nudge_json_bool "$obs" '.open_work' && open_work=true
  fm_nudge_json_bool "$obs" '.progress_since_nudge' && progress=true
  fm_nudge_json_bool "$obs" '.escalated' && escalated=true
  fm_nudge_json_bool "$obs" '.council_raised' && council_raised=true

  case "$idle" in ''|*[!0-9]*) idle=0 ;; esac
  case "$idle_th" in ''|*[!0-9]*) idle_th=15 ;; esac
  case "$cool" in ''|*[!0-9]*) cool=0 ;; esac
  case "$consec" in ''|*[!0-9]*) consec=0 ;; esac
  case "$maxn" in ''|*[!0-9]*) maxn=2 ;; esac
  case "$esc_min" in ''|*[!0-9]*) esc_min=0 ;; esac
  case "$council_min" in ''|*[!0-9]*) council_min=0 ;; esac
  case "$tier" in ''|*[!0-9]*) tier=0 ;; esac
  case "$lane_age" in ''|*[!0-9]*) lane_age=0 ;; esac
  case "$lane_min" in ''|*[!0-9]*) lane_min=0 ;; esac

  # A lane with no progress for lane_stall_min is open work and starts the
  # ladder on its own; the ladder then runs on the older of the two clocks.
  stall=$idle
  if [ "$lane_min" -gt 0 ] && [ "$lane_age" -ge "$lane_min" ]; then
    lane_hit=true
    open_work=true
    [ "$lane_age" -le "$stall" ] || stall=$lane_age
  fi

  _fm_nudge_decision() {  # <event> <severity> <reason> <should_send> [prompt]
    local prompt=${5-}
    if [ "$4" = true ] && [ -z "$prompt" ]; then
      prompt='continue'
    fi
    jq -nc --arg e "$1" --arg s "$2" --arg r "$3" --argjson send "$4" --arg p "$prompt" \
      '{event:$e, severity:$s, reason:$r, should_send:$send, prompt:$p}'
  }

  # Progress since the last nudge clears escalation before any other gate.
  if [ "$progress" = true ]; then
    consec=0
    escalated=false
    tier=0
  fi

  # The council row types nothing, so a modal or typed text cannot block it:
  # a captain that died behind an API error is exactly the case it exists
  # for. It is raised once per stall (council_raised), and the ladder keeps
  # whatever tier was actually typed: the row itself never retires the
  # escalate rung.
  if [ "$council_min" -gt 0 ] && [ "$stall" -ge "$council_min" ] && [ "$open_work" = true ] \
     && [ "$tier" -lt 3 ] && [ "$council_raised" != true ]; then
    _fm_nudge_decision stall_council high \
      "stalled ${stall}m with open work past ${council_min}m; council row raised, nothing typed" false
    return 0
  fi

  if [ -n "$dialog" ]; then
    _fm_nudge_decision blocker medium "modal visible: $dialog" false
    return 0
  fi

  case "$composer" in
    pending)
      _fm_nudge_decision skipped_input_not_empty info 'composer holds typed text' false
      return 0
      ;;
    pending-unproven)
      _fm_nudge_decision blocker medium 'composer text is unproven; refusing to type' false
      return 0
      ;;
    unknown|'')
      _fm_nudge_decision blocker medium 'composer state unknown; refusing to type' false
      return 0
      ;;
    empty) ;;
    *)
      _fm_nudge_decision blocker medium "composer state not recognized: $composer" false
      return 0
      ;;
  esac

  if [ "$idle" -lt "$idle_th" ] && [ "$lane_hit" != true ]; then
    _fm_nudge_decision skip_not_idle info "idle ${idle}m below threshold ${idle_th}m" false
    return 0
  fi

  if [ "$open_work" != true ]; then
    _fm_nudge_decision skip_no_open_work info "no open work (${open_sum:-none})" false
    return 0
  fi

  # The second wake fires once per stall, after a first wake, and ignores the
  # first wake's cooldown so it lands at escalate_min rather than later.
  if [ "$esc_min" -gt 0 ] && [ "$stall" -ge "$esc_min" ] && [ "$tier" -eq 1 ]; then
    _fm_nudge_decision stall_escalate medium \
      "still stalled ${stall}m after a wake; asking to relaunch or replace the stalled worker" true escalate
    return 0
  fi

  if [ "$cool" -gt 0 ]; then
    _fm_nudge_decision skip_cooldown info "cooldown ${cool}m remaining" false
    return 0
  fi

  # Two consecutive nudges with no progress: emit high and stop. Progress
  # already cleared consec above, so this is the no-progress path.
  if [ "$escalated" = true ] || [ "$consec" -ge "$maxn" ]; then
    _fm_nudge_decision nudge_no_progress high \
      "no progress after ${consec} consecutive nudges; stopping until progress resumes" false
    return 0
  fi

  _fm_nudge_decision nudge info 'idle with open work, composer empty, no modal' true
}

# Required JSONL fields from the SPEC. Extra keys on the input are preserved.
fm_nudge_jsonl_line() {
  local event=${1-}
  printf '%s' "$event" | jq -c '
    . as $in |
    {
      ts: ($in.ts // ""),
      host: ($in.host // ""),
      captain: ($in.captain // ""),
      event: ($in.event // ""),
      severity: ($in.severity // "info"),
      owner: ($in.owner // ""),
      reason: ($in.reason // ""),
      idle_min: ($in.idle_min // 0),
      open_work: ($in.open_work // "none")
    } + $in
  '
}

# Compact beacon line. Keys are a fixed list so a pane wrap-join stays parseable.
fm_nudge_beacon_line() {
  local event=${1-} ts host captain ev sev owner idle flag
  ts=$(fm_nudge_json_get "$event" '.beacon_ts // .epoch // empty' '') || true
  [ -n "$ts" ] || ts=$(fm_nudge_now)
  host=$(fm_nudge_json_get "$event" '.host' 'unknown') || true
  captain=$(fm_nudge_json_get "$event" '.captain' 'unknown') || true
  ev=$(fm_nudge_json_get "$event" '.event' 'unknown') || true
  sev=$(fm_nudge_json_get "$event" '.severity' 'info') || true
  owner=$(fm_nudge_json_get "$event" '.owner' 'firstmate') || true
  idle=$(fm_nudge_json_get "$event" '.idle_min' '0') || true
  flag=$(fm_nudge_open_work_summary_flag "$(fm_nudge_json_get "$event" '.open_work' 'none')")
  # Values are tokens: no spaces, no pane text.
  host=${host// /_}
  captain=${captain// /_}
  ev=${ev// /_}
  sev=${sev// /_}
  owner=${owner// /_}
  printf 'NUDGE v1 ts=%s host=%s captain=%s event=%s severity=%s owner=%s idle_min=%s open_work=%s\n' \
    "$ts" "$host" "$captain" "$ev" "$sev" "$owner" "$idle" "$flag"
}

# Extra Yes/No / menu patterns on top of the watchdog dialog classifier.
# Prints a kind or nothing (exit 1). Never returns pane body text.
fm_nudge_modal_kind() {  # <screen>
  local screen=${1-} kind tail
  [ -n "$screen" ] || return 1
  if declare -F fm_wd_observe_dialog >/dev/null 2>&1; then
    kind=$(fm_wd_observe_dialog "$screen") && {
      printf '%s\n' "$kind"
      return 0
    }
  elif declare -F fm_wd_pane_dialog >/dev/null 2>&1; then
    kind=$(fm_wd_pane_dialog "$screen") && {
      printf '%s\n' "$kind"
      return 0
    }
  fi
  if declare -F fm_composer_blocking_dialog >/dev/null 2>&1; then
    kind=$(fm_composer_blocking_dialog "$screen") && {
      printf '%s\n' "$kind"
      return 0
    }
  fi
  tail=$(printf '%s\n' "$screen" | awk 'NF { rows[++n] = $0 } END { s = n - 13; if (s < 1) s = 1; for (i = s; i <= n; i++) print rows[i] }')
  if printf '%s\n' "$tail" | LC_ALL=C grep -Eq 'Do you want to (proceed|continue|allow|run|overwrite)|Allow (this|once|always)|Yes, and don.t ask again|Trust (this|the files)'; then
    printf 'permission\n'
    return 0
  fi
  if printf '%s\n' "$tail" | LC_ALL=C grep -Eqi 'usage limit|weekly limit|out of credits' \
     && printf '%s\n' "$tail" | LC_ALL=C grep -Eq '(^|[[:space:]])(Yes|No)([[:space:]]|$)|❯[[:space:]]*(Yes|No|1\.|2\.)'; then
    printf 'usage-limit\n'
    return 0
  fi
  if printf '%s\n' "$tail" | LC_ALL=C awk '
    /(❯|›)[ \t]*[0-9]+[.)]/ { selected = 1 }
    NF { last = $0 }
    END { exit !(selected && last ~ /(Enter to (confirm|select|submit|continue)|Esc to (cancel|exit)|↑\/↓ to )/) }
  '; then
    printf 'menu\n'
    return 0
  fi
  return 1
}

# Map a composer classifier verdict to the decide vocabulary.
fm_nudge_composer_gate() {  # <verdict>
  case "$1" in
    empty) printf 'empty\n' ;;
    pending) printf 'pending\n' ;;
    pending-unproven) printf 'pending-unproven\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Read-only open-work probes. Prints `true<TAB>summary` or `false<TAB>summary`.
# Never runs a mutating gh/git verb. A failed probe prints `false<TAB>unreadable:...`
# so the caller fail-closes (no nudge without proven open work).
fm_nudge_probe_github_prs() {  # <repo,repo,...>
  local repos=$1 repo out n names='' total=0
  [ -n "$repos" ] || { printf 'false\tnone\n'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf 'false\tunreadable: gh missing\n'; return 0; }
  IFS=,
  for repo in $repos; do
    repo=${repo#"${repo%%[![:space:]]*}"}
    repo=${repo%"${repo##*[![:space:]]}"}
    [ -n "$repo" ] || continue
    case "$repo" in
      */*) ;;
      *) printf 'false\tunreadable: repo %s is not owner/name\n' "$repo"; return 0 ;;
    esac
    out=$(gh pr list --repo "$repo" --state open --limit 20 --json number 2>/dev/null) || {
      printf 'false\tunreadable: gh pr list failed for %s\n' "$repo"
      return 0
    }
    n=$(printf '%s' "$out" | jq 'length' 2>/dev/null) || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      total=$((total + n))
      names="${names:+$names, }${repo}:${n}"
    fi
  done
  unset IFS
  if [ "$total" -gt 0 ]; then
    printf 'true\t%s open PR(s) (%s)\n' "$total" "$names"
  else
    printf 'false\t0 open PRs\n'
  fi
}

fm_nudge_probe_queue_file() {  # <path>
  local path=$1 body
  path=$(fm_nudge_expand_path "$path")
  [ -n "$path" ] || { printf 'false\tnone\n'; return 0; }
  [ -f "$path" ] || { printf 'false\tqueue absent\n'; return 0; }
  body=$(LC_ALL=C grep -Ev '^[[:space:]]*(#|$)' "$path" 2>/dev/null || true)
  if printf '%s\n' "$body" | LC_ALL=C grep -Eq '^- \[ \]|In flight|^queued|^\*\s+queued'; then
    printf 'true\tqueue has open items (%s)\n' "$path"
    return 0
  fi
  if [ -n "$body" ]; then
    printf 'true\tqueue file is non-empty (%s)\n' "$path"
    return 0
  fi
  printf 'false\tqueue empty\n'
}

# Combined probe: open if any configured probe reports work. Unreadable
# github_prs with no other hit fail-closes as unreadable.
fm_nudge_probe_open_work() {  # <captain-json>
  local cap=$1 repos queue cmd hit=false summary='' unread='' line ok rest
  repos=$(fm_nudge_json_get "$cap" '.open_work.repos | if type=="array" then join(",") else ( . // "") end' '') || true
  queue=$(fm_nudge_json_get "$cap" '.open_work.queue_file // ""' '') || true
  cmd=$(fm_nudge_json_get "$cap" '.open_work.command // ""' '') || true

  if [ -n "$repos" ]; then
    line=$(fm_nudge_probe_github_prs "$repos")
    ok=${line%%$'\t'*}
    rest=${line#*$'\t'}
    if [ "$ok" = true ]; then
      hit=true
      summary=$rest
    elif printf '%s' "$rest" | grep -q '^unreadable:'; then
      unread=$rest
    fi
  fi
  if [ -n "$queue" ]; then
    line=$(fm_nudge_probe_queue_file "$queue")
    ok=${line%%$'\t'*}
    rest=${line#*$'\t'}
    if [ "$ok" = true ]; then
      hit=true
      summary="${summary:+$summary; }$rest"
    fi
  fi
  if [ -n "$cmd" ]; then
    case "$cmd" in
      gh\ pr\ list*|gh\ api\ graphql*)
        rest=$(eval "$cmd" 2>/dev/null) || { printf 'false\tunreadable: open-work command failed\n'; return 0; }
        if [ -n "$rest" ] && [ "$rest" != '[]' ]; then
          hit=true
          summary="${summary:+$summary; }command reported work"
        fi
        ;;
      *)
        printf 'false\tunreadable: open-work command not allowlisted\n'
        return 0
        ;;
    esac
  fi
  if [ "$hit" = true ]; then
    printf 'true\t%s\n' "$summary"
    return 0
  fi
  if [ -n "$unread" ]; then
    printf 'false\t%s\n' "$unread"
    return 0
  fi
  printf 'false\tnone\n'
}

# True when argv is a read-only or otherwise allowed external command.
# Send of the fixed prompt is allowed only through fm_nudge_send_allowed_text.
fm_nudge_cmd_allowed() {
  local a1=${1-} a2=${2-} a3=${3-}
  case "$a1 $a2 $a3" in
    'orca terminal list'|'orca terminal read') return 0 ;;
    'herdr pane list'|'herdr pane get'|'herdr pane read') return 0 ;;
    'gh pr list') return 0 ;;
    'gh api graphql')
      case " $* " in
        *' mutation '*|*' --method POST '*|*' --method PATCH '*|*' --method PUT '*|*' --method DELETE '*) return 1 ;;
      esac
      return 0
      ;;
    'git -C '*|'git rev-parse '*|'git log '*) return 0 ;;
  esac
  case "$a1" in
    date|stat|uname|jq|cksum|tail|head|cat|printf|kill|launchctl|systemctl|crontab|id|ps) return 0 ;;
  esac
  return 1
}

# Refuse any send whose text is not one of the fixed prompts, or a continue or
# escalate prompt followed by exactly one lane table.
fm_nudge_send_allowed_text() {
  local got=$1 base rest re entry='[A-Za-z0-9._-]{1,64} [0-9]+m'
  re="^${entry}(, ${entry}){0,4}( \\(\\+[0-9]+ more\\))?\\.\$"
  [ "$got" = "$FM_NUDGE_TEXT_FIXED" ] || [ "$got" = "$FM_NUDGE_TEXT_ESCALATE" ] \
    || [ "$got" = "$FM_NUDGE_TEXT_MERGE" ] && return 0
  for base in "$FM_NUDGE_TEXT_FIXED" "$FM_NUDGE_TEXT_ESCALATE"; do
    case "$got" in
      "$base Stalled lanes: "*)
        rest=${got#"$base Stalled lanes: "}
        [[ "$rest" =~ $re ]] && return 0
        ;;
    esac
  done
  return 1
}
# Open lane stalls from a home's stall ledger (bin/fm-stall-ledger-lib.sh owns
# the row schema): one `<age-min><TAB><subject>` line per worker or secondmate
# stall-open row with no stall-close for the same ref, at least <min> minutes
# old, oldest first.
fm_nudge_lane_stalls() {  # <ledger> <now> <min>
  local ledger=$1 now=$2 min=$3
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 0
  LC_ALL=C awk -F '\t' -v now="$now" -v min="$min" '
    NF == 10 && $2 == "stall-open" && ($3 == "worker" || $3 == "secondmate") && $5 ~ /^[0-9]+$/ {
      subj[$10] = $4; start[$10] = $5
    }
    NF == 10 && $2 == "stall-close" { delete subj[$10]; delete start[$10] }
    END {
      for (r in subj) {
        age = int((now - start[r]) / 60)
        if (age >= min) printf "%d\t%s\n", age, subj[r]
      }
    }
  ' "$ledger" | sort -t "$(printf '\t')" -k1,1nr
}

# The lane table suffix for a wake: at most five `<subject> <age>m` entries
# from fm_nudge_lane_stalls output. Subjects outside [A-Za-z0-9._-] or over 64
# characters are dropped, so the typed text stays inside the send contract.
fm_nudge_lane_table() {  # <lane-stalls>
  local age subj shown=0 more=0 out=''
  while IFS=$'\t' read -r age subj; do
    case "$age" in ''|*[!0-9]*) continue ;; esac
    case "$subj" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#subj}" -le 64 ] || continue
    if [ "$shown" -lt 5 ]; then
      out="${out:+$out, }$subj ${age}m"
      shown=$((shown + 1))
    else
      more=$((more + 1))
    fi
  done <<< "${1-}"
  [ -n "$out" ] || return 0
  if [ "$more" -gt 0 ]; then
    out="$out (+$more more)"
  fi
  printf 'Stalled lanes: %s.\n' "$out"
}

# The exact text for <kind>, with the lane table appended to a continue or
# escalate wake when there is one.
fm_nudge_prompt_text() {  # <kind> [lane-table]
  local base table=${2-}
  base=$(fm_nudge_text "$1") || return 1
  case "$1" in
    continue|escalate)
      if [ -n "$table" ]; then
        printf '%s %s\n' "$base" "$table"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$base"
}

# Merge-ready rows from bin/fm-ready-pr-discovery.sh --json output: one
# `<run_id>@<head><TAB><pr>` line per run parked at the ci step with its PR
# ready. A run parked at an approval gate is a decision, not merge-ready.
fm_nudge_merge_ready_rows() {  # <discovery-json>
  printf '%s' "${1-}" | jq -r '
    (.runs // [])[]
    | select(.kind == "ci-ready" and (.run_id // "") != "")
    | [((.run_id) + "@" + (.head // "-")), (.pr // "-")] | @tsv
  ' 2>/dev/null
}

# Progress fingerprint: output signature, heartbeat epoch, commit sha.
fm_nudge_fingerprint() {  # <output-sig> <hb-epoch> <commit>
  printf '%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}"
}

# Append JSONL and beacon lines. Trims the beacon log to the last 500 lines.
fm_nudge_append_logs() {  # <jsonl-path> <beacon-path> <event-json>
  local jsonl=$1 beacon=$2 event=$3 tmp
  mkdir -p "$(dirname "$jsonl")"
  fm_nudge_jsonl_line "$event" >> "$jsonl"
  if [ -n "$beacon" ]; then
    mkdir -p "$(dirname "$beacon")"
    fm_nudge_beacon_line "$event" >> "$beacon"
    tmp=$(dirname "$beacon")/.nudge-beacon-tmp.$$
    tail -n 500 "$beacon" > "$tmp" && mv "$tmp" "$beacon"
  fi
}
