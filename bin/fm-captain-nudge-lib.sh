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
#   fm_nudge_text
#       Prints the one allowed prompt. Send paths must compare against this.
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
#
# Observation JSON keys (all required unless noted):
#   idle_min, idle_threshold_min, open_work (bool), open_work_summary,
#   dialog (empty or a kind), composer (empty|pending|pending-unproven|unknown),
#   cooldown_remaining_min, consecutive_no_progress, progress_since_nudge (bool),
#   escalated (bool), max_no_progress (optional, default 2).
#
# Test seam: FM_NUDGE_NOW (epoch) and FM_TEST_SEAM=1 pin the clock.

# The only string this tool is allowed to type. Changing it here is a contract
# change: update docs/captain-nudge-spec.md in the same commit.
FM_NUDGE_TEXT_FIXED='Continue open work: pick next item, reroute quota if exhausted, never park self-servable work'

fm_nudge_text() {
  printf '%s\n' "$FM_NUDGE_TEXT_FIXED"
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
#   {event, severity, reason, should_send}
# should_send is true only for a live nudge that may type the fixed prompt.
fm_nudge_decide() {
  local obs=${1-} idle idle_th open_sum dialog composer cool consec maxn
  local open_work=false progress=false escalated=false
  [ -n "$obs" ] || { printf 'fm-captain-nudge-lib: decide needs observation JSON\n' >&2; return 2; }
  printf '%s' "$obs" | jq -e . >/dev/null 2>&1 || {
    printf 'fm-captain-nudge-lib: observation is not JSON\n' >&2
    return 2
  }

  idle=$(fm_nudge_json_get "$obs" '.idle_min' '') || true
  idle_th=$(fm_nudge_json_get "$obs" '.idle_threshold_min' '20') || true
  open_sum=$(fm_nudge_json_get "$obs" '.open_work_summary' 'none') || true
  dialog=$(fm_nudge_json_get "$obs" '.dialog' '') || true
  composer=$(fm_nudge_json_get "$obs" '.composer' 'unknown') || true
  cool=$(fm_nudge_json_get "$obs" '.cooldown_remaining_min' '0') || true
  consec=$(fm_nudge_json_get "$obs" '.consecutive_no_progress' '0') || true
  maxn=$(fm_nudge_json_get "$obs" '.max_no_progress' '2') || true
  fm_nudge_json_bool "$obs" '.open_work' && open_work=true
  fm_nudge_json_bool "$obs" '.progress_since_nudge' && progress=true
  fm_nudge_json_bool "$obs" '.escalated' && escalated=true

  case "$idle" in ''|*[!0-9]*) idle=0 ;; esac
  case "$idle_th" in ''|*[!0-9]*) idle_th=20 ;; esac
  case "$cool" in ''|*[!0-9]*) cool=0 ;; esac
  case "$consec" in ''|*[!0-9]*) consec=0 ;; esac
  case "$maxn" in ''|*[!0-9]*) maxn=2 ;; esac

  _fm_nudge_decision() {  # <event> <severity> <reason> <should_send>
    jq -nc --arg e "$1" --arg s "$2" --arg r "$3" --argjson send "$4" \
      '{event:$e, severity:$s, reason:$r, should_send:$send}'
  }

  # Progress since the last nudge clears escalation before any other gate.
  if [ "$progress" = true ]; then
    consec=0
    escalated=false
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

  if [ "$idle" -lt "$idle_th" ]; then
    _fm_nudge_decision skip_not_idle info "idle ${idle}m below threshold ${idle_th}m" false
    return 0
  fi

  if [ "$open_work" != true ]; then
    _fm_nudge_decision skip_no_open_work info "no open work (${open_sum:-none})" false
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

# Refuse any send whose text is not the one fixed prompt.
fm_nudge_send_allowed_text() {
  local got=$1
  [ "$got" = "$FM_NUDGE_TEXT_FIXED" ]
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
