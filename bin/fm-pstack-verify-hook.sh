#!/usr/bin/env bash
# fm-pstack-verify-hook.sh - inject four pstack verification principles when
# their trigger events fire.
#
# Source: pstack 0.15.43, MIT, Copyright (c) 2026 Lauren Tan
# https://github.com/cursor/plugins/tree/main/pstack
# License text: .cursor/licenses/provenance/licenses/cursor_plugins.LICENSE
# (NOTICE already records pstack under that file; no second copy.)
# Provenance rows: .cursor/licenses/provenance/adaptations.yaml
#
# Registered from tracked Cursor and Claude hook files. Each invocation reads
# one hook payload on stdin, classifies at most the four events below, and
# prints the host's documented hook output when a trigger matches. It never
# blocks a turn: every error path, including missing jq, empty stdin, and a
# corrupt state file, exits 0.
#
# Host emit schema (https://cursor.com/docs/hooks; Claude hookSpecificOutput):
#   Cursor postToolUse / postToolUseFailure / sessionStart -> additional_context
#   Cursor beforeSubmitPrompt -> exactly {"continue":true}
#   Cursor afterAgentResponse / afterShellExecution -> no output
#   Claude UserPromptSubmit / PreToolUse / PostToolUse -> additionalContext
# A Cursor speed claim or done-line seen on beforeSubmitPrompt,
# afterAgentResponse, or afterShellExecution is stored as a pending marker
# and delivered once on the next postToolUse or postToolUseFailure in the
# same conversation.
#
# Triggers, each owned here:
#   completion report  -> principle-prove-it-works
#     status_is_done_verb (bin/fm-classify-lib.sh): status_is_terminal_verb
#     and then the verb is done. blocked:, failed:, and needs-decision: stay
#     out. Lines come from Write/Edit contents, quoted payloads in Shell/Bash
#     commands (the fm-brief STATUS_APPEND shape), and assistant/prompt text.
#   tests added/changed -> principle-test-behavior-not-implementation
#     Claude PreToolUse Write/Edit of a code test path, Cursor postToolUse of
#     the same, or a Shell redirect/heredoc/tee into a code test path.
#     In-place editors (sed -i) and a cwd-relative foo.test.sh with no
#     tests/ prefix are not covered.
#   speed or perf claim -> principle-explain-the-number
#     An assertion such as "much faster", "got a lot faster", "2x as fast",
#     or "the export is faster now". Questions, "as fast as", and a noun
#     mention of "speedup" stay out. "fast-forward" and "faster path" are
#     dropped locally before matching.
#   same red twice after a claimed fix -> principle-attack-the-premise
#     keyed on a stable check or test id in $STATE/pstack-verify-reds.tsv;
#     claims are taken from assistant-visible text and tool output; reds are
#     taken from stdout, stderr, and error_message on postToolUse /
#     PostToolUse / postToolUseFailure (Cursor afterShellExecution is not
#     counted, so one failed Shell is one red). A pytest node id matches the
#     file prefix before ::. Jest FAIL <path> is extracted. A repeated
#     payload token does not increment the streak.
#
# Usage:
#   <hook JSON on stdin> | bin/fm-pstack-verify-hook.sh [--claude|--cursor]
#   --claude stands down on a Cursor-delivered payload when the native
#   .cursor/hooks.json registration covers that event, or when emitting would
#   hit Cursor preToolUse (which is not an additional_context consumer).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REDS_MAX_AGE_SECS=1209600
LOCK_STALE_SECS=8
LOCK_RETRIES=8

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

EVENT=
CURSOR_OUT=$CURSOR_MODE

# Cursor beforeSubmitPrompt output is continue (https://cursor.com/docs/hooks).
emit_noop() {
  command -v jq >/dev/null 2>&1 || return 0
  case "${EVENT:-}" in
    beforeSubmitPrompt)
      [ "$CURSOR_MODE" = 1 ] || return 0
      jq -n '{continue:true}' 2>/dev/null || true
      ;;
  esac
}

fail_open() {
  emit_noop
  exit 0
}

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

extract_quoted_strings() {  # <command>
  local s=$1 q
  [ -n "$s" ] || return 0
  while [ -n "$s" ]; do
    case "$s" in
      *\"*)
        s=${s#*\"}
        case "$s" in
          *\"*) q=${s%%\"*}; s=${s#*\"}; printf '%s\n' "$q" ;;
          *) break ;;
        esac
        ;;
      *) break ;;
    esac
  done
}

# status_is_done_verb is the completion classifier (terminal and verb done).
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
    [ -n "$trimmed" ] || continue
    status_is_done_verb "$trimmed" && return 0
  done <<EOF
$text
EOF
  return 1
}

# An assertion, not a question or a noun mention.
is_speed_claim_text() {  # <text>
  local text=$1 lower cleaned
  [ -n "$text" ] || return 1
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *\?*) return 1 ;;
    which\ *faster*|what\ *faster*|what\'s\ faster*) return 1 ;;
  esac
  cleaned=$lower
  while :; do
    case "$cleaned" in
      *fast-forward*) cleaned=${cleaned%%fast-forward*}${cleaned#*fast-forward} ;;
      *faster\ path*) cleaned=${cleaned%%faster\ path*}${cleaned#*faster\ path} ;;
      *) break ;;
    esac
  done
  case "$cleaned" in
    *[0-9]x\ as\ fast*|[0-9]\ times\ as\ fast*|*[0-9]\ times\ as\ fast*) return 0 ;;
    *as\ fast\ as*) return 1 ;;
  esac
  case "$cleaned" in
    *it\'s\ faster*|*it\ is\ faster*|*got\ faster*|*now\ faster*|*is\ faster*) return 0 ;;
    *much\ faster*|*a\ lot\ faster*|*lot\ faster*) return 0 ;;
    *[0-9]x\ faster*|[0-9]\ times\ faster*|*[0-9]\ times\ faster*|*%\ faster*) return 0 ;;
  esac
  return 1
}

is_test_path() {  # <path>
  local path=$1 base
  [ -n "$path" ] || return 1
  path=${path//\\//}
  case "$path" in
    *.md|*.txt|*.rst|*.markdown) return 1 ;;
  esac
  case "$path" in
    tests/*|*/tests/*|test/*|*/test/*) return 0 ;;
    __tests__/*|*/__tests__/*) return 0 ;;
    *.test.*|*_test.*|*.spec.*|*_spec.*) return 0 ;;
  esac
  base=${path##*/}
  case "$base" in
    test_*.py|test_*.sh|test_*.go|test_*.rb|test_*.js|test_*.ts) return 0 ;;
  esac
  return 1
}

# Redirects and tees into a code test path segment, not contest/.
shell_writes_test_path() {  # <command>
  local cmd=$1
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *'>'test/*|*'>'[[:space:]]test/*|*'>'*/test/*) return 0 ;;
    *'>'tests/*|*'>'[[:space:]]tests/*|*'>'*/tests/*) return 0 ;;
    *'>'__tests__/*|*'>'[[:space:]]__tests__/*|*'>'*/__tests__/*) return 0 ;;
    *'>'*/*.test.*|*'>'*/*_test.*|*'>'*/*.spec.*|*'>'*/*_spec.*) return 0 ;;
    *tee[[:space:]]test/*|*tee[[:space:]]*/test/*) return 0 ;;
    *tee[[:space:]]tests/*|*tee[[:space:]]*/tests/*) return 0 ;;
    *tee[[:space:]]__tests__/*|*tee[[:space:]]*/__tests__/*) return 0 ;;
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

is_shell_tool() {  # <tool>
  case "$1" in
    Shell|Bash) return 0 ;;
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

sanitize_field() {  # <raw> -> stdout, no tab/newline
  printf '%s' "$1" | tr -d '\t\n\r'
}

sanitize_id() {  # <raw> -> stdout
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._/:@+ -')
  case "$s" in
    *::*) s=${s%%::*} ;;
  esac
  s=${s# };
  s=${s% }
  printf '%s' "$s"
}

_split_words() {  # <text> -> words on stdout, noglob
  local text=$1 restore=0 word
  [ -n "$text" ] || return 0
  case $- in *f*) restore=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  for word in $text; do
    printf '%s\n' "$word"
  done
  [ "$restore" -eq 1 ] || set +f
}

extract_red_ids() {  # <text>
  local text=$1 line rest word found
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    rest=
    case "$line" in
      *FAILED\ *) rest=${line#*FAILED} ;;
      *FAIL:\ *) rest=${line#*FAIL:} ;;
      *failed:*) rest=${line#*failed:} ;;
      FAIL\ *) rest=${line#FAIL} ;;
      *"FAIL "*) rest=${line#*"FAIL "} ;;
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
    [ -n "$rest" ] || continue
    found=
    while IFS= read -r word || [ -n "$word" ]; do
      [ -n "$word" ] || continue
      word=${word#\'}; word=${word%\'}; word=${word#\"}; word=${word%\"}
      if is_test_path "$word"; then
        found=$(sanitize_id "$word")
        break
      fi
    done <<EOF
$(_split_words "$rest")
EOF
    [ -n "$found" ] || found=$(sanitize_id "$rest")
    [ -n "$found" ] || continue
    printf '%s\n' "$found"
  done <<EOF
$text
EOF
}

extract_claim_ids() {  # <text>
  local text=$1 line rest lower word found
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
    found=
    while IFS= read -r word || [ -n "$word" ]; do
      [ -n "$word" ] || continue
      word=${word#\'}; word=${word%\'}; word=${word#\"}; word=${word%\"}
      if is_test_path "$word"; then
        found=$(sanitize_id "$word")
        break
      fi
    done <<EOF
$(_split_words "$rest")
EOF
    if [ -z "$found" ]; then
      found=${rest%% *}
      case "$found" in
        ''|the|this|it|a|an) continue ;;
      esac
      found=$(sanitize_id "$found")
    fi
    [ -n "$found" ] || continue
    printf '%s\n' "$found"
  done <<EOF
$text
EOF
}

reds_file() {
  printf '%s' "$STATE/pstack-verify-reds.tsv"
}

pending_file() {
  printf '%s' "$STATE/pstack-verify-pending"
}

now_epoch() {
  date +%s 2>/dev/null || printf '0'
}

file_mtime() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf ''
}

acquire_reds_lock() {
  local lock=$1 i=0 m now age
  while [ "$i" -lt "$LOCK_RETRIES" ]; do
    mkdir "$lock" 2>/dev/null && return 0
    m=$(file_mtime "$lock")
    now=$(now_epoch)
    case "$m" in ''|*[!0-9]*) ;; *)
      case "$now" in ''|*[!0-9]*) ;; *)
        age=$((now - m))
        if [ "$age" -ge "$LOCK_STALE_SECS" ]; then
          rmdir "$lock" 2>/dev/null
          mkdir "$lock" 2>/dev/null && return 0
        fi
        ;;
      esac
      ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  return 1
}

write_pending() {  # <conversation-id> <principle>
  local conv=$1 principle=$2 file tmp
  conv=$(sanitize_field "$conv")
  [ -n "$conv" ] || conv="-"
  case "$principle" in
    principle-prove-it-works|principle-explain-the-number) ;;
    *) return 0 ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || return 0
  file=$(pending_file)
  tmp="${file}.tmp.$$"
  printf '%s\t%s\n' "$conv" "$principle" > "$tmp" 2>/dev/null || return 0
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

take_pending() {  # <conversation-id> -> principle on stdout
  local conv=$1 file pconv principle
  conv=$(sanitize_field "$conv")
  [ -n "$conv" ] || conv="-"
  file=$(pending_file)
  [ -f "$file" ] || return 0
  IFS="$(printf '\t')" read -r pconv principle < "$file" || return 0
  pconv=$(sanitize_field "$pconv")
  [ -n "$pconv" ] || pconv="-"
  case "$principle" in
    principle-prove-it-works|principle-explain-the-number) ;;
    *) rm -f "$file"; return 0 ;;
  esac
  if [ "$pconv" = "$conv" ] || [ "$pconv" = "-" ] || [ "$conv" = "-" ]; then
    rm -f "$file"
    printf '%s' "$principle"
  fi
}

# Record a claimed fix or a red for <id>. Prints the id when streak reaches 2
# after a claim. A matching token is a no-op. The row is kept across later reds.
record_red_event() {  # <id> <kind:claim|red> <token>
  local id kind=$2 token=$3 file tmp lock claimed=0 streak=0 last='' epoch=0 found=0
  local cid cclaimed cstreak ctoken cepoch now cutoff
  id=$(sanitize_id "$1")
  [ -n "$id" ] || return 0
  token=$(sanitize_id "${token:--}")
  [ -n "$token" ] || token="-"
  mkdir -p "$STATE" 2>/dev/null || return 0
  file=$(reds_file)
  lock="${file}.lock"
  acquire_reds_lock "$lock" || return 0
  tmp="${file}.tmp.$$"
  [ -f "$file" ] || : > "$file"
  now=$(now_epoch)
  cutoff=0
  case "$now" in
    ''|*[!0-9]*) now=0 ;;
    *) cutoff=$((now - REDS_MAX_AGE_SECS)) ;;
  esac
  while IFS="$(printf '\t')" read -r cid cclaimed cstreak ctoken cepoch || [ -n "${cid:-}" ]; do
    [ -n "$cid" ] || continue
    case "$cid" in *[!a-z0-9._/:@+\ -]*) continue ;; esac
    case "${cepoch:-0}" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$cutoff" -gt 0 ] && [ "$cepoch" -lt "$cutoff" ]; then
      continue
    fi
    if [ "$cid" = "$id" ]; then
      found=1
      claimed=$cclaimed
      streak=$cstreak
      last=$ctoken
      epoch=$cepoch
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$cid" "$cclaimed" "$cstreak" "$ctoken" "$cepoch"
  done < "$file" > "$tmp" || { rm -f "$tmp"; rmdir "$lock" 2>/dev/null; return 0; }

  case "$claimed" in
    0|1) ;;
    *) claimed=0 ;;
  esac
  case "$streak" in
    ''|*[!0-9]*) streak=0 ;;
  esac

  case "$kind" in
    claim)
      claimed=1
      streak=0
      last=$token
      epoch=$now
      ;;
    red)
      if [ "$found" -eq 1 ] && [ "$last" = "$token" ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$claimed" "$streak" "$last" "$epoch" >> "$tmp"
        mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
        rmdir "$lock" 2>/dev/null
        return 0
      fi
      if [ "$claimed" = 1 ]; then
        streak=$((streak + 1))
      else
        streak=0
      fi
      last=$token
      epoch=$now
      ;;
    *) rm -f "$tmp"; rmdir "$lock" 2>/dev/null; return 0 ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$claimed" "$streak" "$last" "$epoch" >> "$tmp"
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; rmdir "$lock" 2>/dev/null; return 0; }
  rmdir "$lock" 2>/dev/null
  if [ "$kind" = red ] && [ "$claimed" = 1 ] && [ "$streak" -ge 2 ]; then
    printf '%s\n' "$id"
  fi
}

# Cursor docs (https://cursor.com/docs/hooks): postToolUse, postToolUseFailure,
# and sessionStart output additional_context. beforeSubmitPrompt output is
# continue. afterAgentResponse and afterShellExecution have no output fields.
emit_context() {  # <event> <instruction>
  local event=$1 instruction=$2 out
  command -v jq >/dev/null 2>&1 || return 0
  if [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ]; then
    case "$event" in
      postToolUse|postToolUseFailure|sessionStart)
        out=$(jq -n --arg c "$instruction" '{additional_context:$c}' 2>/dev/null) || return 0
        ;;
      *)
        return 0
        ;;
    esac
  else
    case "$event" in
      UserPromptSubmit|PreToolUse|PostToolUse)
        out=$(jq -n --arg c "$instruction" --arg e "$event" \
          '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}' 2>/dev/null) || return 0
        ;;
      *)
        return 0
        ;;
    esac
  fi
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

cursor_counts_reds() {
  case "$EVENT" in
    afterShellExecution) return 1 ;;
  esac
  return 0
}

cursor_defers_inject() {
  [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ] || return 1
  case "$EVENT" in
    beforeSubmitPrompt|afterAgentResponse|afterShellExecution) return 0 ;;
  esac
  return 1
}

cursor_delivers_pending() {
  [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ] || return 1
  case "$EVENT" in
    postToolUse|postToolUseFailure) return 0 ;;
  esac
  return 1
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || fail_open
command -v jq >/dev/null 2>&1 || fail_open

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh" 2>/dev/null || fail_open
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh" 2>/dev/null || fail_open
set -u

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // .hookEventName // ""' 2>/dev/null) || EVENT=
if printf '%s' "$PAYLOAD" | jq -e 'has("cursor_version")' >/dev/null 2>&1; then
  CURSOR_OUT=1
fi

if [ "$CLAUDE_MODE" -eq 1 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  case "$EVENT" in
    postToolUse|PostToolUse|postToolUseFailure|afterShellExecution|afterAgentResponse|beforeSubmitPrompt|UserPromptSubmit|preToolUse|PreToolUse)
      fail_open
      ;;
  esac
fi

FIELDS=$(printf '%s' "$PAYLOAD" | jq -c '
  def str(v):
    if v == null then ""
    elif (v|type) == "string" then v
    elif (v|type) == "number" then (v|tostring)
    else (v|tostring)
    end;
  def as_obj(v):
    if v == null then {}
    elif (v|type) == "object" then v
    elif (v|type) == "string" then (try (v|fromjson) catch {})
    else {}
    end;
  (.tool_input // .toolInput // {}) as $in
  | as_obj(.tool_output // .toolOutput // "") as $to
  | as_obj(.tool_response // .toolResponse // "") as $tr
  | {
      event: str(.hook_event_name // .hookEventName // ""),
      tool: str(.tool_name // .toolName // ""),
      text: str(.prompt // .text // .message // ""),
      command: str($in.command // .command // ""),
      path: str($in.path // $in.file_path // .file_path // .path // ""),
      contents: str($in.contents // $in.new_string // $in.content // ""),
      stderr: str($to.stderr // $tr.stderr // .stderr // .error_message // ""),
      stdout: str($to.stdout // $tr.stdout // .stdout // ""),
      output: str(.output // $to.output // $tr.output // ""),
      token: str(.tool_use_id // .toolUseId // .generation_id // .prompt_id // ""),
      conv: str(.conversation_id // .conversationId // .session_id // "")
    }
' 2>/dev/null) || fail_open
[ -n "$FIELDS" ] || fail_open

EVENT=$(printf '%s' "$FIELDS" | jq -r '.event' 2>/dev/null) || fail_open
TOOL=$(printf '%s' "$FIELDS" | jq -r '.tool' 2>/dev/null) || fail_open
TEXT=$(printf '%s' "$FIELDS" | jq -r '.text' 2>/dev/null) || fail_open
COMMAND=$(printf '%s' "$FIELDS" | jq -r '.command' 2>/dev/null) || fail_open
PATH_VAL=$(printf '%s' "$FIELDS" | jq -r '.path' 2>/dev/null) || fail_open
CONTENTS=$(printf '%s' "$FIELDS" | jq -r '.contents' 2>/dev/null) || fail_open
STDERR=$(printf '%s' "$FIELDS" | jq -r '.stderr' 2>/dev/null) || fail_open
STDOUT=$(printf '%s' "$FIELDS" | jq -r '.stdout' 2>/dev/null) || fail_open
OUTPUT=$(printf '%s' "$FIELDS" | jq -r '.output' 2>/dev/null) || fail_open
TOKEN=$(printf '%s' "$FIELDS" | jq -r '.token' 2>/dev/null) || fail_open
CONV=$(printf '%s' "$FIELDS" | jq -r '.conv' 2>/dev/null) || fail_open
[ -n "$TOKEN" ] || TOKEN=$(printf '%s' "$PAYLOAD" | cksum 2>/dev/null | awk '{print $1}')

QUOTED=
if is_shell_tool "$TOOL" || [ -n "$COMMAND" ]; then
  QUOTED=$(extract_quoted_strings "$COMMAND")
fi

VISIBLE="$TEXT
$CONTENTS
$QUOTED
$COMMAND"
STREAMS="$STDERR
$STDOUT
$OUTPUT"
OBSERVED="$VISIBLE
$STREAMS"
PRINCIPLE=

if is_write_tool "$TOOL" && is_test_path "$PATH_VAL"; then
  PRINCIPLE="principle-test-behavior-not-implementation"
elif { is_shell_tool "$TOOL" || [ -n "$COMMAND" ]; } && shell_writes_test_path "$COMMAND"; then
  PRINCIPLE="principle-test-behavior-not-implementation"
elif is_speed_claim_text "$VISIBLE"; then
  PRINCIPLE="principle-explain-the-number"
elif is_completion_text "$VISIBLE"; then
  PRINCIPLE="principle-prove-it-works"
fi

CLAIM_IDS=$(extract_claim_ids "$OBSERVED")
RED_IDS=
if cursor_counts_reds; then
  RED_IDS=$(extract_red_ids "$STREAMS")
  [ -n "$RED_IDS" ] || RED_IDS=$(extract_red_ids "$VISIBLE")
fi

if [ -n "$CLAIM_IDS" ]; then
  while IFS= read -r cid || [ -n "$cid" ]; do
    [ -n "$cid" ] || continue
    record_red_event "$cid" claim "$TOKEN" >/dev/null
  done <<EOF
$CLAIM_IDS
EOF
fi

RED_HIT=
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
  PRINCIPLE="principle-attack-the-premise"
fi

if cursor_defers_inject; then
  case "$PRINCIPLE" in
    principle-prove-it-works|principle-explain-the-number)
      write_pending "$CONV" "$PRINCIPLE"
      PRINCIPLE=
      ;;
  esac
fi

if [ -z "$PRINCIPLE" ] && cursor_delivers_pending; then
  PRINCIPLE=$(take_pending "$CONV")
fi

[ -n "$PRINCIPLE" ] || fail_open
INSTR=$(instruction_for "$PRINCIPLE") || fail_open
[ -n "$INSTR" ] || fail_open
[ -n "$EVENT" ] || EVENT=unknown
emit_context "$EVENT" "$INSTR" || fail_open
exit 0
