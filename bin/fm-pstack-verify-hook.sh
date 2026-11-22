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
#   Claude UserPromptSubmit -> additionalContext for speed claims
#   Claude PreToolUse -> additionalContext for test-file writes and completions
#   Claude PostToolUse / PostToolUseFailure -> additionalContext for
#     recurring-red only. One Claude tool call is PreToolUse then PostToolUse;
#     non-red principles emit on PreToolUse so they are not printed twice.
# A Cursor speed claim or done-line on beforeSubmitPrompt or
# afterAgentResponse is stored as a pending marker keyed by conversation_id
# and delivered once on the next postToolUse or postToolUseFailure in that
# conversation. afterShellExecution does not defer completions or speed
# claims: postToolUse of the same Shell already sees the command.
# Recurring-red on afterShellExecution is still pending-delivered. No
# conversation_id means no pending store and no delivery.
#
# Triggers, each owned here:
#   completion report  -> principle-prove-it-works
#     status_is_done_verb in bin/fm-classify-lib.sh requires status_is_terminal_verb and then the verb done.
#     blocked:, failed:, and needs-decision: stay out.
#     Lines come from a Shell command that names a status path (the STATUS_APPEND shape), a Write of a *.status file, and assistant or tool text.
#     A command line or quoted string whose trimmed text is exactly done is not a completion report.
#     A done: line and a done [at=...] line still are.
#     User prompts are not classified as completions.
#   tests added/changed -> principle-test-behavior-not-implementation
#     Claude PreToolUse Write/Edit of a code test path (file_path/content or
#     path/contents), Cursor postToolUse of the same, or a Shell
#     redirect/heredoc/tee/cp/mv whose TARGET is a code test path. A cwd-relative
#     foo.test.sh Write or `cat > foo.test.sh` injects. A redirect to /tmp that
#     later names a test path does not. A `>` inside single or double quotes is
#     not a redirect; nested or escaped quotes are not parsed. A `>` inside a
#     heredoc body counts as a test-file write, by design, because bash can
#     execute heredoc bodies (interpreter-fed or unquoted expansion); this is
#     an accepted false positive. Paths whose final extension is .bak, .orig,
#     or .swp stay silent. In-place editors (sed -i) are not covered.
#   speed or perf claim -> principle-explain-the-number
#     An assertion such as "much faster", "got a lot faster", "2x as fast",
#     "the export is faster now", "the export is 2x as fast?", or
#     "X is faster than Y". Questions about whether something is faster
#     ("which is faster", "is it faster?"), "as fast as", and a noun
#     mention of "speedup" stay out. "fast-forward" and "faster path" are
#     dropped locally before matching. "this is faster than main" is kept:
#     a comparison is a claim and is hard to separate from "the export is
#     faster now".
#   same red twice after a claimed fix -> principle-attack-the-premise
#     keyed on conversation_id plus test id in $STATE/pstack-verify-reds.tsv
#     (Claude uses session_id). A missing conversation/session id is not
#     recorded. Claims match the phrases "fixed " and "should now pass ".
#     Dropped premise: one physical shell failure can be uniquely identified
#     across Cursor events using generation_id, tool_use_id, or a
#     conversation+command hash. One red source per host instead. Cursor
#     counts TAP only from afterShellExecution.output; each event is one
#     call. postToolUse and postToolUseFailure never count Cursor reds;
#     they only deliver pending. Claude counts from PostToolUse and
#     PostToolUseFailure, which are mutually exclusive per call. A claim
#     never sets the last token. Cursor counts every afterShellExecution
#     (no payload digest). Claude tokens are tool_use_id, so a repeated
#     delivery of the same tool use is one red. Recurring-red on Cursor
#     is pending-delivered on the next postToolUse(/Failure). A pytest
#     node id matches the file prefix before ::. Jest FAIL <path> is
#     extracted. Pending markers are a per-conversation list; a delivering
#     event that already emits consumes a matching deferred principle.
#     A prove-it-works or explain-the-number principle already emitted on
#     postToolUse or postToolUseFailure in this generation is not stored
#     again, so afterAgentResponse cannot re-queue it. afterAgentResponse
#     then postToolUse still delivers once. Recurring-red
#     (attack-the-premise) is keyed by test id and is not recorded in that
#     emit-once set, so a second test id in the same generation still
#     delivers. A missing generation_id leaves record_emitted a no-op.
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
# Hook timeout is 10s. LOCK_RETRIES sleeps of 1s plus the critical section
# must finish well inside that. A leftover younger than LOCK_STALE_SECS
# becomes breakable inside this window.
LOCK_STALE_SECS=4
LOCK_RETRIES=6

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
    which\ *faster*|what\ *faster*|what\'s\ faster*) return 1 ;;
    is\ *faster\?*|are\ *faster\?*) return 1 ;;
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
    *it\'s\ faster*|*it\ is\ faster*|*now\ faster*|*is\ faster*) return 0 ;;
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
    *.bak|*.orig|*.swp) return 1 ;;
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

# Blank `>` inside simple single or double quotes so it is not a redirect.
# Nested and escaped quotes are not parsed.
_blank_gt_inside_quotes() {  # <command>
  local s=$1 out='' i=0 n c q=
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then
        q=
        out=$out$c
      elif [ "$c" = '>' ]; then
        out=$out' '
      else
        out=$out$c
      fi
    else
      case "$c" in
        \'|\") q=$c; out=$out$c ;;
        *) out=$out$c ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Redirects, tees (including flags), and cp/mv destinations into a code test
# path segment, not contest/. Only the redirect/tee/cp/mv TARGET is matched.
# In-place editors (sed -i) are not covered.
shell_writes_test_path() {  # <command>
  local cmd=$1 word prev='' mode='' last_cp=''
  [ -n "$cmd" ] || return 1
  cmd=$(_blank_gt_inside_quotes "$cmd")
  cmd=$(printf '%s' "$cmd" | sed 's/>>/ __RA__ /g; s/>/ __R__ /g')
  while IFS= read -r word || [ -n "$word" ]; do
    [ -n "$word" ] || continue
    word=${word#\'}; word=${word%\'}; word=${word#\"}; word=${word%\"}
    case "$word" in
      __R__|__RA__)
        prev=$word
        mode=
        last_cp=
        continue
        ;;
      '&&'|'||'|'|'|';'|'&')
        if { [ "$mode" = cp ] || [ "$mode" = mv ]; } && is_test_path "$last_cp"; then
          return 0
        fi
        prev=
        mode=
        last_cp=
        continue
        ;;
    esac
    case "$prev" in
      __R__|__RA__)
        is_test_path "$word" && return 0
        prev=
        continue
        ;;
    esac
    case "$word" in
      tee|*/tee) mode='tee'; prev=; continue ;;
      cp|*/cp) mode='cp'; last_cp=; prev=; continue ;;
      mv|*/mv) mode='mv'; last_cp=; prev=; continue ;;
    esac
    case "$mode" in
      tee)
        case "$word" in
          -*) ;;
          *) is_test_path "$word" && return 0 ;;
        esac
        ;;
      cp|mv)
        case "$word" in
          -*) ;;
          *) last_cp=$word ;;
        esac
        ;;
    esac
    prev=$word
  done <<EOF
$(_split_words "$cmd")
EOF
  if { [ "$mode" = cp ] || [ "$mode" = mv ]; } && is_test_path "$last_cp"; then
    return 0
  fi
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

# One filename component. Paths, '..', and empty keys are not stored.
sanitize_conv_key() {  # <raw> -> filename-safe key
  local s=$1
  case "$s" in
    ''|'.'|'..'|*'..'*|/*|*/*|*\\*) printf ''; return 0 ;;
  esac
  s=$(printf '%s' "$s" | tr -cd 'a-zA-Z0-9._-')
  case "$s" in
    ''|'.'|'..'|*'..'*) printf ''; return 0 ;;
  esac
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
      fixed\ *) rest=${lower#fixed } ;;
      *" fixed "*) rest=${lower#*" fixed "} ;;
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

pending_dir() {
  printf '%s' "$STATE/pstack-verify-pending"
}

pending_file_for() {  # <conv>
  printf '%s/%s' "$(pending_dir)" "$1"
}

emitted_dir() {
  printf '%s' "$STATE/pstack-verify-emitted"
}

emitted_file_for() {  # <conv>
  printf '%s/%s' "$(emitted_dir)" "$1"
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

release_reds_lock() {  # <lock>
  rmdir "$1" 2>/dev/null || true
}

# Pending marker for Cursor events that cannot emit additional_context.
# One file per conversation_id; unique principle lines, FIFO. Missing
# conversation_id is not stored. Take and write share the reds lock.
# A principle already emitted in this generation is not stored.
write_pending() {  # <conversation-id> <principle>
  local conv=$1 principle=$2 file lock line gen efile
  conv=$(sanitize_conv_key "$conv")
  [ -n "$conv" ] || return 0
  case "$principle" in
    principle-prove-it-works|principle-explain-the-number|principle-attack-the-premise) ;;
    *) return 0 ;;
  esac
  mkdir -p "$STATE" "$(pending_dir)" "$(emitted_dir)" 2>/dev/null || return 0
  lock="$(reds_file).lock"
  acquire_reds_lock "$lock" || return 0
  gen=$(sanitize_field "${GEN:-}")
  if [ -n "$gen" ]; then
    efile=$(emitted_file_for "$conv")
    if [ -f "$efile" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$gen	$principle" ]; then
          release_reds_lock "$lock"
          return 0
        fi
      done < "$efile"
    fi
  fi
  file=$(pending_file_for "$conv")
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$principle" ]; then
        release_reds_lock "$lock"
        return 0
      fi
    done < "$file"
  fi
  printf '%s\n' "$principle" >> "$file"
  release_reds_lock "$lock"
}

take_pending() {  # <conversation-id> -> principle on stdout
  local conv=$1 file lock tmp principle line kept=0
  conv=$(sanitize_conv_key "$conv")
  [ -n "$conv" ] || return 0
  mkdir -p "$STATE" "$(pending_dir)" 2>/dev/null || return 0
  lock="$(reds_file).lock"
  acquire_reds_lock "$lock" || return 0
  file=$(pending_file_for "$conv")
  if [ ! -f "$file" ]; then
    release_reds_lock "$lock"
    return 0
  fi
  tmp="${file}.tmp.$$"
  principle=
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      principle-prove-it-works|principle-explain-the-number|principle-attack-the-premise)
        if [ -z "$principle" ]; then
          principle=$line
        else
          printf '%s\n' "$line" >> "$tmp"
          kept=1
        fi
        ;;
    esac
  done < "$file"
  if [ "$kept" -eq 1 ]; then
    mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$file" "$tmp"
  fi
  release_reds_lock "$lock"
  printf '%s' "$principle"
}

drop_pending() {  # <conversation-id> <principle>
  local conv=$1 principle=$2 file lock tmp line kept=0 dropped=0
  conv=$(sanitize_conv_key "$conv")
  [ -n "$conv" ] || return 0
  mkdir -p "$STATE" "$(pending_dir)" 2>/dev/null || return 0
  lock="$(reds_file).lock"
  acquire_reds_lock "$lock" || return 0
  file=$(pending_file_for "$conv")
  if [ ! -f "$file" ]; then
    release_reds_lock "$lock"
    return 0
  fi
  tmp="${file}.tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$dropped" -eq 0 ] && [ "$line" = "$principle" ]; then
      dropped=1
      continue
    fi
    case "$line" in
      principle-prove-it-works|principle-explain-the-number|principle-attack-the-premise)
        printf '%s\n' "$line" >> "$tmp"
        kept=1
        ;;
    esac
  done < "$file"
  if [ "$kept" -eq 1 ]; then
    mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$file" "$tmp"
  fi
  release_reds_lock "$lock"
}

# Record that this generation already emitted <principle> for <conv>.
# Later write_pending of the same pair is a no-op. Other generations
# are dropped so the file cannot grow across turns. Recurring-red is
# not recorded here; it is keyed by test id, not by principle name.
record_emitted() {  # <conversation-id> <principle>
  local conv=$1 principle=$2 file lock tmp line gen kept_gen kept_prin
  conv=$(sanitize_conv_key "$conv")
  [ -n "$conv" ] || return 0
  gen=$(sanitize_field "${GEN:-}")
  [ -n "$gen" ] || return 0
  case "$principle" in
    principle-prove-it-works|principle-explain-the-number) ;;
    *) return 0 ;;
  esac
  mkdir -p "$STATE" "$(emitted_dir)" 2>/dev/null || return 0
  lock="$(reds_file).lock"
  acquire_reds_lock "$lock" || return 0
  file=$(emitted_file_for "$conv")
  tmp="${file}.tmp.$$"
  : > "$tmp"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      kept_gen=${line%%	*}
      kept_prin=${line#*	}
      [ "$kept_gen" = "$gen" ] || continue
      [ "$kept_prin" = "$principle" ] && continue
      printf '%s\n' "$line" >> "$tmp"
    done < "$file"
  fi
  printf '%s\t%s\n' "$gen" "$principle" >> "$tmp"
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  release_reds_lock "$lock"
}

# Record a claimed fix or a red for <conv,id>. Prints the id when streak
# reaches 2 after a claim. A matching red token is a no-op (exact duplicate
# delivery). A claim never writes last. Missing conv is not recorded.
# The holder of the lock must finish before LOCK_STALE_SECS.
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
      last="-"
      epoch=$now
      ;;
    red)
      if [ "$found" -eq 1 ] && [ -n "$last" ] && [ "$last" != "-" ] && [ "$last" = "$token" ]; then
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
      UserPromptSubmit|PreToolUse|PostToolUse|PostToolUseFailure)
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

is_cursor_host() {
  [ "$CURSOR_MODE" = 1 ] || [ "$CURSOR_OUT" = 1 ]
}

# Cursor: afterShellExecution only. Claude: PostToolUse and PostToolUseFailure.
is_red_counting_event() {
  if is_cursor_host; then
    case "$EVENT" in
      afterShellExecution) return 0 ;;
    esac
    return 1
  fi
  case "$EVENT" in
    PostToolUse|PostToolUseFailure) return 0 ;;
  esac
  return 1
}

cursor_defers_inject() {
  is_cursor_host || return 1
  case "$EVENT" in
    beforeSubmitPrompt|afterAgentResponse) return 0 ;;
    afterShellExecution)
      case "$PRINCIPLE" in
        principle-attack-the-premise) return 0 ;;
      esac
      return 1
      ;;
  esac
  return 1
}

cursor_delivers_pending() {
  is_cursor_host || return 1
  case "$EVENT" in
    postToolUse|postToolUseFailure) return 0 ;;
  esac
  return 1
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || fail_open
EVENT=$(event_from_payload "$PAYLOAD")
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
    postToolUse|PostToolUse|postToolUseFailure|PostToolUseFailure|afterShellExecution|afterAgentResponse|beforeSubmitPrompt|UserPromptSubmit|preToolUse|PreToolUse)
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
      error: str(.error // ""),
      token: str(.tool_use_id // .toolUseId // ""),
      conv: str(.conversation_id // .conversationId // .session_id // ""),
      gen: str(.generation_id // .generationId // "")
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
ERROR=$(printf '%s' "$FIELDS" | jq -r '.error' 2>/dev/null) || fail_open
TOKEN=$(printf '%s' "$FIELDS" | jq -r '.token' 2>/dev/null) || fail_open
CONV=$(printf '%s' "$FIELDS" | jq -r '.conv' 2>/dev/null) || fail_open
GEN=$(printf '%s' "$FIELDS" | jq -r '.gen' 2>/dev/null) || fail_open
if is_cursor_host; then
  TOKEN="-"
elif [ -z "$TOKEN" ]; then
  TOKEN=$(printf '%s' "$PAYLOAD" | cksum 2>/dev/null | awk '{print $1}')
fi
[ -n "$TOKEN" ] || TOKEN="-"

QUOTED=
if is_shell_tool "$TOOL" || [ -n "$COMMAND" ]; then
  QUOTED=$(extract_quoted_strings "$COMMAND")
fi

VISIBLE="$TEXT
$CONTENTS
$QUOTED
$COMMAND"

# Drop a line whose trimmed text is exactly done.
# A done: line and a done [at=...] line are not that text, so they stay.
drop_exact_done_lines() {
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [ "$trimmed" = "done" ] && continue
    printf '%s\n' "$line"
  done
}

# Completion from STATUS_APPEND, status-file Write, and assistant/tool text.
# User prompts are not classified as completions.
# A command's lines count only when the command names a status path.
COMPLETION=
if is_write_tool "$TOOL" && is_status_path "$PATH_VAL"; then
  COMPLETION=$CONTENTS
fi
case "$COMMAND" in
  *.status*|*state/*)
    COMPLETION="$COMPLETION
$(printf '%s\n' "$QUOTED" "$COMMAND" | drop_exact_done_lines)"
    ;;
esac
case "$EVENT" in
  UserPromptSubmit|beforeSubmitPrompt) ;;
  *)
    COMPLETION="$COMPLETION
$TEXT"
    ;;
esac

STREAMS="$STDERR
$STDOUT
$OUTPUT
$ERROR"
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
if [ -n "$CONV" ] && is_red_counting_event; then
  if is_cursor_host; then
    RED_IDS=$(extract_red_ids "$OUTPUT")
  else
    RED_IDS=$(extract_red_ids "$STREAMS")
  fi
  # One event is one call: several failing lines that name the same check
  # count as one red.
  RED_IDS=$(printf '%s\n' "$RED_IDS" | awk 'NF && !seen[$0]++')
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

# Claude: one event per trigger. Reds stay on PostToolUse/PostToolUseFailure.
if [ -n "$PRINCIPLE" ] && ! is_cursor_host; then
  case "$PRINCIPLE" in
    principle-attack-the-premise)
      case "$EVENT" in
        PostToolUse|PostToolUseFailure) ;;
        *) PRINCIPLE= ;;
      esac
      ;;
    *)
      case "$EVENT" in
        PreToolUse|UserPromptSubmit) ;;
        *) PRINCIPLE= ;;
      esac
      ;;
  esac
fi

if [ -n "$PRINCIPLE" ]; then
  INSTR=$(instruction_for "$PRINCIPLE") || fail_open
  [ -n "$INSTR" ] || fail_open
  [ -n "$EVENT" ] || EVENT=unknown
  if cursor_delivers_pending; then
    record_emitted "$CONV" "$PRINCIPLE"
    drop_pending "$CONV" "$PRINCIPLE"
  fi
  emit_context "$EVENT" "$INSTR" || fail_open
fi
emit_before_submit_continue
exit 0
