#!/usr/bin/env bash
# Single owner of the external "% until auto-compact" formula for a Claude
# session, used by bin/fm-handoff-trigger.sh and bin/fm-context-burn.sh.
# bin/fm-handoff-trigger.sh's header documents the formula and the window
# resolution. Sourced, never executed. Callers set FM_ROOT and source
# bin/fm-warm-compact-lib.sh for the token count.

FM_COMPACT_OUTPUT_RESERVE=20000
FM_COMPACT_BUFFER=13000

# Print the window CLAUDE_CODE_AUTO_COMPACT_WINDOW value $1 means in tokens,
# clamped to Claude's limits; fail when Claude would ignore the value.
fm_compact_env_window() {
  awk -v raw="$1" 'BEGIN {
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", raw)
    if (raw !~ /^[0-9]+(\.[0-9]+)?[kKmM]?$/) exit 1
    n = raw + 0
    unit = tolower(substr(raw, length(raw)))
    if (unit == "m") n *= 1000000
    else if (unit == "k") n *= 1000
    if (n < 1) exit 1
    if (n < 100000) n = 100000
    if (n > 1000000) n = 1000000
    printf "%d\n", n + 0.5
  }'
}

# Print the window Claude applies to model $1; fail when it is "auto" or unset.
fm_compact_auto_window() {
  local model=$1 file value project
  fm_compact_env_window "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" && return 0
  project=${CLAUDE_PROJECT_DIR:-$FM_ROOT}
  for file in "$project/.claude/settings.local.json" "$project/.claude/settings.json" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
    [ -r "$file" ] || continue
    value=$(jq -r --arg m "$model" '
        def canon: ascii_downcase | sub("\\[1m\\]$"; "") | sub("-[0-9]{8}$"; "");
        def size: select(type == "number" and . == floor and . >= 100000 and . <= 1000000) | tostring;
        def entry: if . == "auto" then . else size end;
        ($m | canon) as $c
        | first(
            ([.modelSettings | objects | to_entries[]
              | select(.key | canon == $c)
              | {exact: (.key == $c), window: (.value | objects | .autoCompactWindow | entry)}]
             | sort_by(.exact | not) | .[].window),
            (.autoCompactWindow | size)
          )
      ' "$file" 2>/dev/null)
    case "$value" in
      '') ;;
      auto) return 1 ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  done
  return 1
}

# fm_compact_at_tokens <transcript> <config-file>: print the auto-compact point
# in tokens, from a pinned compact-at-tokens in config/handoff-trigger or else
# derived from Claude's settings; fail when neither resolves.
fm_compact_at_tokens() {
  local transcript=$1 config=$2 line key value pinned='' model window effective at pct pct_at
  if [ -f "$config" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      value=${line#*=}
      case "$value" in '' | 0* | *[!0-9]*) continue ;; esac
      [ "$key" = compact-at-tokens ] && pinned=$value
    done < "$config"
  fi
  if [ -n "$pinned" ]; then
    printf '%s\n' "$pinned"
    return 0
  fi
  model=$(tail -n 400 "$transcript" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "assistant") | .message.model // empty | strings
    ' 2>/dev/null | tail -n 1)
  window=$(fm_compact_auto_window "$model") || return 1
  effective=$((window - FM_COMPACT_OUTPUT_RESERVE))
  at=$((effective - FM_COMPACT_BUFFER))
  pct=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}
  case "$pct" in
    '' | *[!0-9.]* | *.*.*) ;;
    *)
      pct_at=$(awk -v w="$effective" -v p="$pct" 'BEGIN { if (p > 0 && p <= 100) printf "%d", w * p / 100 }')
      [ -n "$pct_at" ] && [ "$pct_at" -lt "$at" ] && at=$pct_at
      ;;
  esac
  [ "$at" -gt 0 ] || return 1
  printf '%s\n' "$at"
}

# fm_compact_left_percent <tokens> <compact-at>: floored, never below 0.
fm_compact_left_percent() {
  local left=$((($2 - $1) * 100 / $2))
  [ "$left" -ge 0 ] || left=0
  printf '%s\n' "$left"
}
