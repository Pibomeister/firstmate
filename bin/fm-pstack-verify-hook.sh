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
#   Cursor beforeSubmitPrompt -> exactly {"continue":true} on every path,
#     including a miss, a principle match, missing jq, and a --claude
#     stand-down on a Cursor payload. beforeSubmitPrompt is not a permission
#     hook; invalid JSON blocks only the listed permission events, and
#     failClosed false (the default) allows a crash, timeout, or empty
#     stdout through. This helper still prints continue so a miss cannot
#     depend on that default.
#   Cursor afterAgentResponse / afterShellExecution -> no output
#   Claude UserPromptSubmit / PreToolUse / PostToolUse -> additionalContext
# A Cursor speed claim, done-line, or recurring-red seen on
# beforeSubmitPrompt, afterAgentResponse, or afterShellExecution is stored
# as a pending marker keyed by conversation_id and delivered once on the
# next postToolUse or postToolUseFailure in that conversation. No
# conversation_id means no pending store and no delivery.
#
# Triggers, each owned here:
#   completion report  -> principle-prove-it-works
#     status_is_done_verb (bin/fm-classify-lib.sh): status_is_terminal_verb
#     and then the verb is done. blocked:, failed:, and needs-decision: stay
#     out. Lines come from STATUS_APPEND quoted Shell payloads, Write of a
#     *.status file, and assistant or tool text. User prompts are not
#     classified as completions.
#   tests added/changed -> principle-test-behavior-not-implementation
#     Claude PreToolUse Write/Edit of a code test path (file_path/content or
#     path/contents), Cursor postToolUse of the same, or a Shell
#     redirect/heredoc/tee/cp/mv into a code test path. A cwd-relative
#     foo.test.sh Write injects. In-place editors (sed -i) are not covered.
#   speed or perf claim -> principle-explain-the-number
#     An assertion such as "much faster", "got a lot faster", "2x as fast",
#     "the export is faster now", or "X is faster than Y". Questions,
#     "as fast as", and a noun mention of "speedup" stay out.
#     "fast-forward" and "faster path" are dropped locally before matching.
#     "this is faster than main" is kept: a comparison is a claim and is
#     hard to separate from "the export is faster now".
#   same red twice after a claimed fix -> principle-attack-the-premise
#     keyed on conversation_id plus test id in $STATE/pstack-verify-reds.tsv
#     (Claude uses session_id). A missing conversation/session id is not
#     recorded. Claims match the phrases "fixed " and "should now pass ".
#     Cursor TAP is counted from afterShellExecution.output only, once per
#     shell call (conversation + command hash). postToolUse is a successful
#     tool use and is not counted. postToolUseFailure is deduped against
#     that hash so the same failed Shell is not a second red. Recurring-red
#     on Cursor is pending-delivered on the next postToolUse(/Failure).
#     A pytest node id matches the file prefix before ::. Jest FAIL <path>
#     is extracted. A repeated payload token does not increment the streak.
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
LOCK_RETRIES=12
SHELL_CALL_MAX_AGE_SECS=5

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

# Cursor beforeSubmitPrompt must print exactly {"continue":true} without jq.
event_from_payload() {  # <json>
  local raw=$1 name
  name=$(printf '%s' "$raw" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$name" ] || name=$(printf '%s' "$raw" | sed -n 's/.*"hookEventName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  printf '%s' "$name"
}

emit_before_submit_continue() {
  case "${EVENT:-}" in
    beforeSubmitPrompt)
      if [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ]; then
        printf '%s\n' '{"continue":true}'
      fi
      ;;
  esac
}

fail_open() {
  emit_before_submit_continue
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

is_status_path() {  # <path>
  case "$1" in
    *.status|*/state/*|state/*) return 0 ;;
  esac
  return 1
}

# An assertion, not a question or a noun mention.
# "X is faster than Y" is kept: a comparison is a claim.
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

# Redirects, tees (including flags), and cp/mv destinations into a code test
# path segment, not contest/. In-place editors (sed -i) are not covered.
shell_writes_test_path() {  # <command>
  local cmd=$1
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *'>'test/*|*'>'[[:space:]]test/*|*'>'*/test/*) return 0 ;;
    *'>'tests/*|*'>'[[:space:]]tests/*|*'>'*/tests/*) return 0 ;;
    *'>'__tests__/*|*'>'[[:space:]]__tests__/*|*'>'*/__tests__/*) return 0 ;;
    *'>'*/*.test.*|*'>'*/*_test.*|*'>'*/*.spec.*|*'>'*/*_spec.*) return 0 ;;
    *tee[[:space:]]*test/*|*tee[[:space:]]*[[:space:]]*/test/*) return 0 ;;
    *tee[[:space:]]*tests/*|*tee[[:space:]]*[[:space:]]*/tests/*) return 0 ;;
    *tee[[:space:]]*__tests__/*|*tee[[:space:]]*[[:space:]]*/__tests__/*) return 0 ;;
    *cp[[:space:]]*[[:space:]]test/*|*cp[[:space:]]*[[:space:]]*/test/*) return 0 ;;
    *cp[[:space:]]*[[:space:]]tests/*|*cp[[:space:]]*[[:space:]]*/tests/*) return 0 ;;
    *mv[[:space:]]*[[:space:]]test/*|*mv[[:space:]]*[[:space:]]*/test/*) return 0 ;;
    *mv[[:space:]]*[[:space:]]tests/*|*mv[[:space:]]*[[:space:]]*/tests/*) return 0 ;;
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

sanitize_conv_key() {  # <raw> -> filename-safe key
  printf '%s' "$1" | tr -cd 'a-zA-Z0-9._-'
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

calls_file() {
  printf '%s' "$STATE/pstack-verify-calls.tsv"
}

pending_dir() {
  printf '%s' "$STATE/pstack-verify-pending"
}

pending_file_for() {  # <conv>
  printf '%s/%s' "$(pending_dir)" "$1"
}

now_epoch() {
  date +%s 2>/dev/null || printf '0'
}

file_mtime() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf ''
}

# mkdir lock. LOCK_RETRIES is longer than LOCK_STALE_SECS so a leftover
# younger than the stale threshold becomes breakable inside this window.
# The holder must finish the critical section before LOCK_STALE_SECS.
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

release_reds_lock() {  # <lock>
  rmdir "$1" 2>/dev/null || true
}

# Pending marker for Cursor events that cannot emit additional_context.
# One file per conversation_id. Missing conversation_id is not stored.
write_pending() {  # <conversation-id> <principle>
  local conv=$1 principle=$2 file tmp dir
  conv=$(sanitize_conv_key "$conv")
  [ -n "$conv" ] || return 0
  case "$principle" in
    principle-prove-it-works|principle-explain-the-number|principle-attack-the-premise) ;;
    *) return 0 ;;
  esac
  mkdir -p "$(pending_dir)" 2>/dev/null || return 0
  file=$(pending_file_for "$conv")
  tmp="${file}.tmp.$$"
  printf '%s\n' "$principle" > "$tmp" 2>/dev/null || return 0
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

take_pending() {  # <conversation-id> -> principle on stdout
  local conv=$1 file principle
  conv=$(sanitize_conv_key "$conv")
  [ -n "$conv" ] || return 0
  file=$(pending_file_for "$conv")
  [ -f "$file" ] || return 0
  IFS= read -r principle < "$file" || return 0
  case "$principle" in
    principle-prove-it-works|principle-explain-the-number|principle-attack-the-premise) ;;
    *) rm -f "$file"; return 0 ;;
  esac
  rm -f "$file"
  printf '%s' "$principle"
}

shell_call_hash() {  # <conv> <command>
  printf '%s\t%s' "$1" "$2" | cksum 2>/dev/null | awk '{print $1}'
}

# Record conversation+command so a later postToolUseFailure of the same
# shell call is not a second red. afterShellExecution always records.
# 0 if the hash was already present (skip the fallback); 1 if newly noted.
note_shell_call() {  # <conv> <command>
  local conv=$1 command=$2 file tmp lock hash now cutoff chash cepoch
  local found=0
  conv=$(sanitize_field "$conv")
  [ -n "$conv" ] || return 0
  hash=$(shell_call_hash "$conv" "$command")
  [ -n "$hash" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  file=$(calls_file)
  lock="$(reds_file).lock"
  acquire_reds_lock "$lock" || return 0
  tmp="${file}.tmp.$$"
  [ -f "$file" ] || : > "$file"
  now=$(now_epoch)
  cutoff=0
  case "$now" in
    ''|*[!0-9]*) now=0 ;;
    *) cutoff=$((now - SHELL_CALL_MAX_AGE_SECS)) ;;
  esac
  while IFS="$(printf '\t')" read -r cconv chash cepoch || [ -n "${cconv:-}" ]; do
    [ -n "$cconv" ] || continue
    case "${cepoch:-0}" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$cutoff" -gt 0 ] && [ "$cepoch" -lt "$cutoff" ]; then
      continue
    fi
    if [ "$cconv" = "$conv" ] && [ "$chash" = "$hash" ]; then
      found=1
    fi
    printf '%s\t%s\t%s\n' "$cconv" "$chash" "$cepoch"
  done < "$file" > "$tmp" || { rm -f "$tmp"; release_reds_lock "$lock"; return 1; }
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\n' "$conv" "$hash" "$now" >> "$tmp"
  fi
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  release_reds_lock "$lock"
  [ "$found" -eq 1 ]
}

# Record a claimed fix or a red for <conv,id>. Prints the id when streak
# reaches 2 after a claim. A matching token is a no-op. Missing conv is not
# recorded. The holder of the lock must finish before LOCK_STALE_SECS.
record_red_event() {  # <conv> <id> <kind:claim|red> <token>
  local conv=$1 id kind=$3 token=$4 file tmp lock claimed=0 streak=0 last='' epoch=0 found=0
  local cconv cid cclaimed cstreak ctoken cepoch now cutoff
  conv=$(sanitize_field "$conv")
  [ -n "$conv" ] || return 0
  id=$(sanitize_id "$2")
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
  while IFS="$(printf '\t')" read -r cconv cid cclaimed cstreak ctoken cepoch || [ -n "${cconv:-}" ]; do
    [ -n "$cconv" ] && [ -n "$cid" ] || continue
    case "$cid" in *[!a-z0-9._/:@+\ -]*) continue ;; esac
    case "${cepoch:-0}" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$cutoff" -gt 0 ] && [ "$cepoch" -lt "$cutoff" ]; then
      continue
    fi
    if [ "$cconv" = "$conv" ] && [ "$cid" = "$id" ]; then
      found=1
      claimed=$cclaimed
      streak=$cstreak
      last=$ctoken
      epoch=$cepoch
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cconv" "$cid" "$cclaimed" "$cstreak" "$ctoken" "$cepoch"
  done < "$file" > "$tmp" || { rm -f "$tmp"; release_reds_lock "$lock"; return 0; }

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
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$conv" "$id" "$claimed" "$streak" "$last" "$epoch" >> "$tmp"
        mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
        release_reds_lock "$lock"
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
    *) rm -f "$tmp"; release_reds_lock "$lock"; return 0 ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$conv" "$id" "$claimed" "$streak" "$last" "$epoch" >> "$tmp"
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; release_reds_lock "$lock"; return 0; }
  release_reds_lock "$lock"
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

# Cursor: TAP from afterShellExecution.output; postToolUseFailure as fallback
# after the same-call hash. postToolUse is a successful tool use.
cursor_counts_reds() {
  [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ] || return 0
  case "$EVENT" in
    afterShellExecution|postToolUseFailure) return 0 ;;
  esac
  return 1
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
EVENT=$(event_from_payload "$PAYLOAD")
if printf '%s' "$PAYLOAD" | grep -q '"cursor_version"'; then
  CURSOR_OUT=1
fi
command -v jq >/dev/null 2>&1 || fail_open

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh" 2>/dev/null || fail_open
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh" 2>/dev/null || fail_open
set -u

EVENT_JQ=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // .hookEventName // ""' 2>/dev/null) || EVENT_JQ=
[ -n "$EVENT_JQ" ] && EVENT=$EVENT_JQ
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

# Completion from STATUS_APPEND, status-file Write, and assistant/tool text.
# User prompts are not classified as completions.
COMPLETION=
if is_write_tool "$TOOL" && is_status_path "$PATH_VAL"; then
  COMPLETION=$CONTENTS
fi
COMPLETION="$COMPLETION
$QUOTED
$COMMAND"
case "$EVENT" in
  UserPromptSubmit|beforeSubmitPrompt) ;;
  *)
    COMPLETION="$COMPLETION
$TEXT"
    ;;
esac

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
elif is_completion_text "$COMPLETION"; then
  PRINCIPLE="principle-prove-it-works"
fi

CLAIM_IDS=
if [ -n "$CONV" ]; then
  CLAIM_IDS=$(extract_claim_ids "$OBSERVED")
fi
RED_IDS=
if [ -n "$CONV" ] && cursor_counts_reds; then
  cursor_red_source=
  if [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ]; then
    case "$EVENT" in
      afterShellExecution) cursor_red_source=$OUTPUT ;;
      postToolUseFailure) cursor_red_source=$STDERR
        [ -n "$cursor_red_source" ] || cursor_red_source=$OUTPUT
        ;;
    esac
    if [ -n "$cursor_red_source" ]; then
      case "$EVENT" in
        afterShellExecution)
          note_shell_call "$CONV" "$COMMAND" || true
          RED_IDS=$(extract_red_ids "$cursor_red_source")
          ;;
        postToolUseFailure)
          if note_shell_call "$CONV" "$COMMAND"; then
            :
          else
            RED_IDS=$(extract_red_ids "$cursor_red_source")
          fi
          ;;
      esac
    fi
  else
    RED_IDS=$(extract_red_ids "$STREAMS")
    [ -n "$RED_IDS" ] || RED_IDS=$(extract_red_ids "$VISIBLE")
  fi
fi

if [ -n "$CLAIM_IDS" ]; then
  while IFS= read -r cid || [ -n "$cid" ]; do
    [ -n "$cid" ] || continue
    record_red_event "$CONV" "$cid" claim "$TOKEN" >/dev/null
  done <<EOF
$CLAIM_IDS
EOF
fi

RED_HIT=
if [ -n "$RED_IDS" ]; then
  while IFS= read -r rid || [ -n "$rid" ]; do
    [ -n "$rid" ] || continue
    hit=$(record_red_event "$CONV" "$rid" red "$TOKEN" || true)
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
    principle-prove-it-works|principle-explain-the-number|principle-attack-the-premise)
      write_pending "$CONV" "$PRINCIPLE"
      PRINCIPLE=
      ;;
  esac
fi

if [ -z "$PRINCIPLE" ] && cursor_delivers_pending; then
  PRINCIPLE=$(take_pending "$CONV")
fi

if [ -n "$PRINCIPLE" ]; then
  INSTR=$(instruction_for "$PRINCIPLE") || fail_open
  [ -n "$INSTR" ] || fail_open
  [ -n "$EVENT" ] || EVENT=unknown
  emit_context "$EVENT" "$INSTR" || fail_open
fi
emit_before_submit_continue
exit 0
