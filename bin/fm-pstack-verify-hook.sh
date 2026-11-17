#!/usr/bin/env bash
# fm-pstack-verify-hook.sh - inject four pstack verification principles when
# their trigger events fire.
#
# Source: pstack 0.15.43, MIT, Copyright (c) 2026 Lauren Tan
# https://github.com/cursor/plugins/tree/main/pstack
# License text: .cursor/licenses/provenance/licenses/pstack.LICENSE
#
# Registered from tracked Cursor and Claude hook files. Each invocation reads
# one hook payload on stdin, classifies at most the four events below, and
# prints hook additionalContext when a trigger matches. It never blocks a
# turn: every error path, including missing jq, empty stdin, and a corrupt
# state file, exits 0 with no stdout.
#
# Triggers, each owned here:
#   completion report  -> principle-prove-it-works
#     Cursor afterAgentResponse .text, Claude UserPromptSubmit .prompt,
#     and a Write/Shell payload whose text is a done: status line
#     (bin/fm-classify-lib.sh status_is_terminal_verb).
#   tests added/changed -> principle-test-behavior-not-implementation
#     PreToolUse Write/Edit/StrReplace of a test path.
#   speed or perf claim -> principle-explain-the-number
#     beforeSubmitPrompt / UserPromptSubmit / afterAgentResponse text.
#   same red twice after a claimed fix -> principle-attack-the-premise
#     keyed on a stable check or test id in $STATE/pstack-verify-reds.tsv;
#     a repeated payload token does not increment the streak.
#
# Usage:
#   <hook JSON on stdin> | bin/fm-pstack-verify-hook.sh [--claude|--cursor]
#   --claude stands down on a Cursor-delivered payload so the native
#   .cursor/hooks.json registration is the one injector.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CLAUDE_MODE=0
CURSOR_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1; shift ;;
    --cursor) CURSOR_MODE=1; shift ;;
    --help|-h)
      awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

fail_open() {
  exit 0
}

# One sentence that names the skill and the path firstmate actually vendors.
instruction_for() {  # <principle-id>
  case "$1" in
    principle-prove-it-works)
      printf '%s' "Load and follow principle-prove-it-works at .cursor/skills/principle-prove-it-works/SKILL.md (mirrored at .agents/skills/principle-prove-it-works/SKILL.md). A completion report is not proof; verify against the real artifact with a check you can rerun."
      ;;
    principle-test-behavior-not-implementation)
      printf '%s' "Load and follow principle-test-behavior-not-implementation at .cursor/skills/principle-test-behavior-not-implementation/SKILL.md (mirrored at .agents/skills/principle-test-behavior-not-implementation/SKILL.md). Keep only tests that fail when the behavior breaks and still pass when only internals change."
      ;;
    principle-explain-the-number)
      printf '%s' "Load and follow principle-explain-the-number at .cursor/skills/principle-explain-the-number/SKILL.md (mirrored at .agents/skills/principle-explain-the-number/SKILL.md). Write the judgment threshold and noise range before measuring, then name the bottleneck from a profile taken during the run."
      ;;
    principle-attack-the-premise)
      printf '%s' "Load and follow principle-attack-the-premise at .cursor/skills/principle-attack-the-premise/SKILL.md (mirrored at .agents/skills/principle-attack-the-premise/SKILL.md). The same red returned after a claimed fix; write the shared assumption in one sentence and take one observation that would change the outcome if it were false, before the next fix."
      ;;
    *) return 1 ;;
  esac
}

# Leading status verb done:, including the stamped form done [at=<epoch>]:.
is_completion_text() {  # <text>
  local text=$1 line trimmed
  [ -n "$text" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$line
    while [ -n "$trimmed" ]; do
      case "$trimmed" in
        [[:space:]]*) trimmed=${trimmed#?} ;;
        *) break ;;
      esac
    done
    case "$trimmed" in
      done:*|done\[*|done\ \[*) return 0 ;;
      *"checks green"*|*"implementation complete"*) return 0 ;;
    esac
    case "$trimmed" in
      *"PR "*" ready"*|*"pr "*" ready"*) return 0 ;;
    esac
  done <<EOF
$text
EOF
  return 1
}

# Speed claims only. fast-forward and firstmate's "faster path" stay out.
is_speed_claim_text() {  # <text>
  local text=$1 lower
  [ -n "$text" ] || return 1
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *fast-forward*|*faster\ path*) return 1 ;;
  esac
  case "$lower" in
    *it\'s\ faster*|*it\ is\ faster*|*got\ faster*|*now\ faster*|*is\ faster*) return 0 ;;
    *speedup*|*speed-up*|*speed\ up*) return 0 ;;
    *[0-9]x\ faster*|*times\ faster*|*%\ faster*) return 0 ;;
  esac
  return 1
}

is_test_path() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  path=${path//\\//}
  case "$path" in
    tests/*|*/tests/*|test/*|*/test/*) return 0 ;;
    __tests__/*|*/__tests__/*) return 0 ;;
    *.test.*|*_test.*|*.spec.*|*_spec.*) return 0 ;;
    */test_*) return 0 ;;
  esac
  return 1
}

is_write_tool() {  # <tool>
  local tool=$1
  case "$tool" in
    Write|Edit|StrReplace|NotebookEdit|EditNotebook) return 0 ;;
  esac
  return 1
}

_ltrim() {  # <string-name>
  local _s
  eval "_s=\$$1"
  while [ -n "$_s" ]; do
    case "$_s" in
      [[:space:]]*) _s=${_s#?} ;;
      *) break ;;
    esac
  done
  eval "$1=\$_s"
}

_first_token() {  # <string-name>
  local _s
  eval "_s=\$$1"
  _s=${_s%% *}
  _s=${_s%:}
  eval "$1=\$_s"
}

# Stable ids from FAIL / FAILED / not ok / failed: lines. Paths preferred.
extract_red_ids() {  # <text>
  local text=$1 line rest
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    rest=
    case "$line" in
      *FAILED\ *) rest=${line#*FAILED} ;;
      *FAIL:\ *) rest=${line#*FAIL:} ;;
      *failed:*) rest=${line#*failed:} ;;
      *"not ok "*) rest=${line#*"not ok "} ;;
      *) continue ;;
    esac
    _ltrim rest
    while :; do
      case "$rest" in
        [0-9]*) rest=${rest#[0-9]} ;;
        *) break ;;
      esac
    done
    _ltrim rest
    case "$rest" in
      -*) rest=${rest#-}
        _ltrim rest
        ;;
    esac
    _first_token rest
    [ -n "$rest" ] || continue
    printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
  done <<EOF
$text
EOF
}

extract_claim_ids() {  # <text>
  local text=$1 line rest lower
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    rest=
    case "$lower" in
      *fixed\ *) rest=${lower#*fixed } ;;
      *"should now pass "*) rest=${lower#*should now pass } ;;
      *) continue ;;
    esac
    _ltrim rest
    _first_token rest
    case "$rest" in
      ''|the|this|it|a|an) continue ;;
    esac
    printf '%s\n' "$rest"
  done <<EOF
$text
EOF
}

reds_file() {
  printf '%s' "$STATE/pstack-verify-reds.tsv"
}

# Record a claimed fix or a red for <id>. Prints the id on stdout when the
# streak reaches 2 after a claim. A matching token is a no-op.
record_red_event() {  # <id> <kind:claim|red> <token>
  local id kind=$2 token=$3 file tmp claimed=0 streak=0 last='' found=0
  local cid cclaimed cstreak ctoken
  id=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ -n "$id" ] || return 0
  [ -n "$token" ] || token="-"
  mkdir -p "$STATE" 2>/dev/null || return 0
  file=$(reds_file)
  tmp="${file}.tmp.$$"
  [ -f "$file" ] || : > "$file"
  while IFS="$(printf '\t')" read -r cid cclaimed cstreak ctoken || [ -n "${cid:-}" ]; do
    [ -n "$cid" ] || continue
    if [ "$cid" = "$id" ]; then
      found=1
      claimed=$cclaimed
      streak=$cstreak
      last=$ctoken
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$cid" "$cclaimed" "$cstreak" "$ctoken"
  done < "$file" > "$tmp" || { rm -f "$tmp"; return 0; }

  case "$kind" in
    claim)
      claimed=1
      streak=0
      last=$token
      ;;
    red)
      if [ "$found" -eq 1 ] && [ "$last" = "$token" ]; then
        printf '%s\t%s\t%s\t%s\n' "$id" "$claimed" "$streak" "$last" >> "$tmp"
        mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
        return 0
      fi
      if [ "$claimed" = 1 ]; then
        streak=$((streak + 1))
      else
        streak=0
      fi
      last=$token
      ;;
    green)
      rm -f "$tmp"
      if [ -s "$file" ]; then
        mv "$file" "$tmp" 2>/dev/null || return 0
        : > "$file"
        while IFS="$(printf '\t')" read -r cid cclaimed cstreak ctoken || [ -n "${cid:-}" ]; do
          [ "$cid" = "$id" ] && continue
          [ -n "$cid" ] || continue
          printf '%s\t%s\t%s\t%s\n' "$cid" "$cclaimed" "$cstreak" "$ctoken" >> "$file"
        done < "$tmp"
        rm -f "$tmp"
      fi
      return 0
      ;;
    *) rm -f "$tmp"; return 0 ;;
  esac

  printf '%s\t%s\t%s\t%s\n' "$id" "$claimed" "$streak" "$last" >> "$tmp"
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 0; }
  if [ "$kind" = red ] && [ "$claimed" = 1 ] && [ "$streak" -ge 2 ]; then
    printf '%s\n' "$id"
  fi
}

emit_context() {  # <event> <instruction> <cursor:0|1>
  local event=$1 instruction=$2 cursor=$3 out
  command -v jq >/dev/null 2>&1 || return 0
  if [ "$cursor" = 1 ]; then
    out=$(jq -n --arg c "$instruction" --arg e "$event" \
      '{additional_context:$c, hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}' 2>/dev/null) || return 0
  else
    out=$(jq -n --arg c "$instruction" --arg e "$event" \
      '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}' 2>/dev/null) || return 0
  fi
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || fail_open
command -v jq >/dev/null 2>&1 || fail_open

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh" 2>/dev/null || fail_open
if [ "$CLAUDE_MODE" -eq 1 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  fail_open
fi

FIELDS=$(printf '%s' "$PAYLOAD" | jq -c '
  def str(v):
    if v == null then ""
    elif (v|type) == "string" then v
    elif (v|type) == "number" then (v|tostring)
    else (v|tostring)
    end;
  {
    event: str(.hook_event_name // .hookEventName // ""),
    tool: str(.tool_name // .toolName // ""),
    text: str(
      .prompt // .text // .message // .tool_input.command // .toolInput.command // .command // ""
    ),
    path: str(
      .tool_input.path // .tool_input.file_path // .toolInput.path // .toolInput.file_path // .file_path // .path // ""
    ),
    output: str(
      .tool_response // .tool_output // .output // .stdout // ""
    ),
    token: str(.tool_use_id // .toolUseId // .generation_id // .prompt_id // "")
  }
' 2>/dev/null) || fail_open
[ -n "$FIELDS" ] || fail_open

EVENT=$(printf '%s' "$FIELDS" | jq -r '.event' 2>/dev/null) || fail_open
TOOL=$(printf '%s' "$FIELDS" | jq -r '.tool' 2>/dev/null) || fail_open
TEXT=$(printf '%s' "$FIELDS" | jq -r '.text' 2>/dev/null) || fail_open
PATH_VAL=$(printf '%s' "$FIELDS" | jq -r '.path' 2>/dev/null) || fail_open
OUTPUT=$(printf '%s' "$FIELDS" | jq -r '.output' 2>/dev/null) || fail_open
TOKEN=$(printf '%s' "$FIELDS" | jq -r '.token' 2>/dev/null) || fail_open
[ -n "$TOKEN" ] || TOKEN=$(printf '%s' "$PAYLOAD" | cksum 2>/dev/null | awk '{print $1}')
CURSOR_OUT=$CURSOR_MODE
if [ "$CURSOR_OUT" -eq 0 ] && printf '%s' "$PAYLOAD" | jq -e 'has("cursor_version")' >/dev/null 2>&1; then
  CURSOR_OUT=1
fi

COMBINED="$TEXT
$OUTPUT"
PRINCIPLE=

if is_write_tool "$TOOL" && is_test_path "$PATH_VAL"; then
  PRINCIPLE=principle-test-behavior-not-implementation
elif is_speed_claim_text "$TEXT"; then
  PRINCIPLE=principle-explain-the-number
elif is_completion_text "$TEXT"; then
  PRINCIPLE=principle-prove-it-works
fi

# Recurring red is independent and wins when it fires, because a second
# identical failure after a claimed fix is the stronger verification event.
RED_HIT=
CLAIM_IDS=$(extract_claim_ids "$TEXT")
RED_IDS=$(extract_red_ids "$COMBINED")
[ -n "$RED_IDS" ] || RED_IDS=$(extract_red_ids "$TEXT")

if [ -n "$CLAIM_IDS" ]; then
  while IFS= read -r cid || [ -n "$cid" ]; do
    [ -n "$cid" ] || continue
    record_red_event "$cid" claim "$TOKEN" >/dev/null
  done <<EOF
$CLAIM_IDS
EOF
fi

if [ -n "$RED_IDS" ]; then
  while IFS= read -r rid || [ -n "$rid" ]; do
    [ -n "$rid" ] || continue
    hit=$(record_red_event "$rid" red "$TOKEN" || true)
    [ -n "$hit" ] && RED_HIT=$hit
  done <<EOF
$RED_IDS
EOF
fi

if [ -n "$RED_HIT" ]; then
  PRINCIPLE=principle-attack-the-premise
fi

[ -n "$PRINCIPLE" ] || fail_open
INSTR=$(instruction_for "$PRINCIPLE") || fail_open
[ -n "$INSTR" ] || fail_open
[ -n "$EVENT" ] || EVENT=unknown
emit_context "$EVENT" "$INSTR" "$CURSOR_OUT" || fail_open
exit 0
