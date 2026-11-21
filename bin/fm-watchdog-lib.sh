#!/usr/bin/env bash
# fm-watchdog-lib.sh - pure detectors and the action ledger for bin/fm-watchdog.sh.
#
# Sourced, never executed, with no side effects on source. Nothing here calls a
# model, types into a pane, or touches the network: every function reads its
# arguments or a file it is given and prints a verdict, so tests/fm-watchdog.test.sh
# pins each one on fixtures. bin/fm-watchdog.sh owns observation and action.
#
#   fm_wd_conf_get <file> <key> <default>
#       The last `key=value` line wins; `#` lines and blank lines are ignored.
#   fm_wd_conf_int <file> <key> <default>
#       The same, but a non-integer value falls back to the default.
#   fm_wd_lower <text>
#   fm_wd_reserved <text>
#       Returns 0 when the text names an owner-reserved category (merge, release,
#       deploy, spend, money, sign-in, credential, secret, security, production
#       data, PII, delete, destroy, force-push). Those holds stay held.
#   fm_wd_nm_awaiting_approval <text>
#       Returns 0 when the text names a no-mistakes `awaiting_approval` step.
#       Such a step is a council or captain decision by default; the merge or
#       release it would unblock does not by itself make it the owner's.
#   fm_wd_human_only <text>
#       Returns 0 when the text names a human-only category for an
#       awaiting_approval decision (deploy, publish, force-push, spend,
#       secrets or credentials, sign-in, security, production or
#       shared-database writes, PII, messages to people, deletion, or a
#       failure in the PR's own changed behavior).
#   fm_wd_known_unreachable_timing_flake <text>
#       Returns 0 when the text describes a known timing flake in a test the
#       PR cannot reach: a timing word, a flake word, and an unreachable word.
#   fm_wd_pr_label <text>
#       Prints `PR #<n>` for the PR the text names: its first `/pull/<n>` URL,
#       else its first `PR #<n>`, else its first structured `pr: #<n>` or
#       `pr: <n>` component, else its first bare `#<n>`; prints nothing when
#       it names none.
#   fm_wd_seat_family <harness:model>
#       Prints the model family of one council seat: anthropic, google, openai,
#       or unknown. The model name decides; a name it does not know falls back
#       to the harness's own family; anything else is unknown, and an unknown
#       seat never counts toward the two families a ruling needs.
#   fm_wd_text_allowed <text>
#       Returns 0 only when the watchdog may type or file this text: it refuses
#       merge, deploy, release, publish, and force-push words, so no typed answer
#       or nudge can carry a merge or deploy instruction.
#   fm_wd_draft_rows <composer-window>
#       Prints the draft fm_wd_draft_readable proved, for the handoff note: a
#       closed box's body from its first prompt row, or the rows from the last
#       prompt row down to the last long rule. An unproven draft prints nothing.
#   fm_wd_prompt_tail <composer-window>
#       Prints every row from the first prompt row to the end of the window.
#   fm_wd_draft_readable <composer-window> [rows-above-the-window]
#       Returns 0 only when the whole draft boundary is proven: no paste placeholder
#       hides its text, the last prompt row is inside the window, and that row sits
#       in a closed box whole inside the window, or between two equal rules of 40
#       or more characters at column 0. Plain, indented, left-bar, and titled-rule
#       composers are not proven.
#   fm_wd_strip_ansi
#       Filter: removes ANSI escape sequences and carriage returns.
#   fm_wd_feedback_dialog_dismiss <screen> [<harness>]
#   fm_wd_feedback_dialog_key <screen> [<harness>]
#       Wrap fm_control_feedback_dialog_dismiss (bin/fm-control-lib.sh): print
#       `<dialog-id>\t<key>` or only the skip key for a known feedback or
#       bug-report dialog, else exit 1.
#   fm_wd_pane_dialog <screen> [<harness>]
#       Prints `feedback`, `permission`, `usage-limit`, `model-switch`, or
#       `question` when the last rows of the screen hold that blocking dialog,
#       else nothing (exit 1). A dialog needs its structure, not its words: a
#       feedback or bug-report dialog needs a known signature from
#       fm_control_feedback_dialog_dismiss; every other kind needs a selected numbered row and a recorded picker
#       footer as the last non-blank row. A row that opens by stating a provider
#       limit is `usage-limit`; a same-account model or account switch stays
#       `model-switch`.
#   fm_wd_usage_limit_text <text>
#       Returns 0 when <text> opens by stating a provider weekly, session, usage,
#       rate, or credits limit. Conversation that only mentions those words later
#       in the row is not a match.
#   fm_wd_provider_error_class <text>
#       Prints `billing`, `usage_limit`, or `rate_limit` when a row of <text>
#       opens by stating that provider refusal, checked in that order, else
#       exit 1. Billing covers a credit balance, past-due payment, subscription,
#       extra-usage, or account-hold refusal; usage_limit a limit row naming a
#       reset, retry, upgrade, or purchase; rate_limit an API or stream error
#       row whose status is 429 or that names a rate limit or too many
#       requests. A row announcing an automatic retry is skipped.
#   fm_wd_provider_error_screen <screen>
#       The same verdict for the last FM_WD_PROVIDER_ERROR_ROWS (default 12)
#       non-blank rows of an ANSI screen. bin/fm-failover.sh and the watcher
#       read it only on an idle screen.
#   fm_wd_quota_status_line <line>
#       Returns 0 when a paused or blocked status line names a quota floor or
#       the same provider-limit phrases fm_wd_usage_limit_text accepts.
#   fm_wd_usage_limit_kind <name>
#       Returns 0 for the pane kind `usage-limit` and for the Grok composer
#       name `Grok weekly-limit choice`.
#   fm_wd_observe_dialog <screen>
#       Prints a pane dialog name, or `usage-limit` when the composer detector
#       names a usage-limit kind. Exit 1 when neither matches.
#   fm_wd_usage_limit_autowait <screen>
#       Returns 0 when the composer zone holds Claude's usage-limit auto-wait
#       footer (`Continuing automatically at <reset>`), the state in which a
#       session takes no turn until the reset. Only the last 10 non-blank rows
#       count, and they need a composer prompt row. The phrase alone matches on
#       a row below the last prompt row. Above it, the phrase matches only on a
#       row that opens by stating the usage limit (fm_wd_usage_limit_text), so
#       conversation output that quotes the phrase is not a match.
#   fm_wd_handoff_in_progress <claim-file> <lock-pid> <now> <max-secs>
#       Returns 0 for a bounded pending handoff claim for that lock owner;
#       bin/fm-handoff-lib.sh owns the claim format.
#   fm_wd_codex_dialog <screen>
#       Prints the rows of a recorded Codex CLI 0.151.0 command-approval or
#       hook-review dialog, from its heading through its lowercase footer, when
#       the screen ends in one, else nothing (exit 1). fm_wd_pane_dialog does not
#       read it; bin/fm-permission-prompt.sh and fm_wd_human_step do.
#   fm_wd_human_step <screen>
#       Prints `captcha`, `otp`, `verification-code`, `approval`, or `sign-in`
#       when the last 14 non-blank rows show that human-only step, else nothing
#       (exit 1). On a proven dialog, whose cursor row sits above the picker
#       footer (`Esc to cancel` and the like) as its last non-blank row, only
#       the paragraph just above the options counts; an unnumbered picker's
#       cursor row is its option row. A tool permission dialog
#       (fm_wd_pane_dialog `permission`) and a Codex command-approval or
#       hook-review dialog (fm_wd_codex_dialog) never count. A composer rule or
#       `? for shortcuts` footer below the prompt excludes every later row,
#       including multiline drafts with empty rows. Without a prompt in the
#       window, that same boundary excludes the whole window. Otherwise only
#       rows below the last prompt row count, up to the first blank row, after
#       skipping the indented rows a wrapped draft fills under the prompt.
#       With no composer rule or footer below it, a prompt row followed by an
#       empty row and then output, other than one indented footer row, is an
#       echoed earlier turn, so the rows after that empty row count instead.
#       With neither a prompt row nor a composer boundary, as on a full-screen
#       sign-in view, every one of those rows counts. Conversation above a
#       prompt row does not count, except a row among the 4 just above it
#       that opens by stating a sign-in error
#       such as `Not logged in`, `Please run /login`, `Login expired`, or
#       `Failed to authenticate: OAuth session expired`.
#   fm_wd_dialog_options <screen>
#       Prints `<number>\t<text>` for each numbered option of the dialog.
#   fm_wd_dialog_text <screen>
#       Prints the text a reserved check and the judge read, one line: the rows
#       below a rule above the options, else all the last rows.
#   fm_wd_transcript_events <transcript.jsonl> [lines]
#       Prints `T\t<epoch>\t<text>` for assistant text and `U\t<epoch>\t<tool>\t<arg>`
#       for assistant tool calls from the transcript tail.
#   fm_wd_loop_verdict [rapid-secs]
#       Filter over fm_wd_transcript_events output. Prints
#       `<loop|rapid|near|none>\t<repeats>`. `loop` means at least three
#       of the last five assistant texts are identical after case, digit, and
#       whitespace normalization, with only timer tools between them. `rapid` is
#       a loop whose repeats all fall inside rapid-secs. `near` means three share
#       their first six words but are not identical; that goes to the judge.
#   fm_wd_loop_evidence <max-chars>
#       Filter over fm_wd_transcript_events output. Prints the events from the
#       fifth-last assistant text on, newest last, one per row, as `assistant: <text>`
#       or `tool: <name> <arg>`. Past max-chars the oldest rows are dropped.
#   fm_wd_stall_proof <turn-running 0|1|unknown> <cpu-busy 0|1|unknown> <kind>...
#       Returns 0 when no veto holds and at least two distinct source kinds
#       (rendered, filesystem, kernel, records) are given. A running turn or a
#       busy CPU vetoes; an unknown turn or CPU state also vetoes a restart.
#   fm_wd_record <ledger> <id> <home> <subject> <symptom> <action> <phase> <detail>
#       Appends one ledger row; tabs and newlines in fields become spaces.
#   fm_wd_last_epoch <ledger> <home> <symptom> <action> [phase-regex] [subject]
#       Prints the newest epoch of a matching row whose phase is pending,
#       dry-run, refused, or held (or the given regex), else nothing.
#       An empty subject matches every subject. Any other subject matches that column only.
#   fm_wd_rate_ok <ledger> <home> <symptom> <action> <secs> <now> [subject]
#       Returns 0 when the last attempt is older than secs.
#       The optional subject filter is the same as fm_wd_last_epoch.
#   fm_wd_count_since <ledger> <home> <symptom|*> <action|*> <phase-regex> <since> [subject]
#       Prints the count of matching rows; the optional subject filter is the
#       same as fm_wd_last_epoch.
#   fm_wd_open_pending <ledger>
#       Prints `<id>\t<home>\t<symptom>\t<action>\t<epoch>` for every pending
#       row with no later outcome row for the same id.
#   fm_wd_spent_since <model-calls.tsv> <since>
#       Prints the summed numeric cost column, in dollars.
#   fm_wd_iso <epoch>
#       Prints the UTC ISO-8601 time.
#   fm_wd_epoch_ok <value>
#       Returns 0 for a positive integer in plain decimal digits, 15 at most,
#       with no leading zero.
#   fm_wd_heartbeat_published <heartbeat-file>
#       Prints the published_epoch of a heartbeat and returns 0 only when the
#       file is a regular file, and not a symbolic link, that jq parses as one
#       JSON document: an fm-heartbeat.v1 object whose key published_epoch,
#       spelled with no escape, holds a positive integer written as plain
#       decimal digits, 15 at most, and which holds no other key of that name
#       at any depth. The file is read once. Anything else is unread: it prints
#       nothing and returns 1.
#   fm_wd_supervisor_gap_rows <home> <now> <published-epoch>
#       Prints the supervisor-gap rows of one heartbeat reading (docs/watchdog.md
#       "Supervisor-gap record"): the gap row when now - published-epoch is over
#       600, then the observation row. Prints nothing and returns 1 when now
#       does not have exactly 10 digits, when either epoch is not a positive
#       integer of at most 15 digits with no leading zero, when the age is
#       negative, or when the home is empty or holds a TAB, a newline or a
#       carriage return.
#   fm_wd_last_wake_ack <wake-ledger> <now> [daemon-acks]
#       Prints the epoch of the newest `ack` row (bin/fm-wake-ledger-lib.sh owns
#       the rows) among the last 2000 rows of a wake ledger, skipping a row
#       stamped later than now and a row whose generation and through value
#       the away daemon named in its daemon-acks file
#       (bin/fm-supervise-daemon.sh). Prints nothing and returns 1 when there is
#       none.
#   fm_wd_restart_prompt <handoff> <home> <script-dir> <token>
#       Prints the primary restart prompt. It names the handoff by path and
#       does not include the document. A document longer than the handoff
#       line cap warns on stderr; bin/fm-handoff-lib.sh owns that cap.
#   fm_wd_user_bin_path <path> <home>
#       Prints <path> with <home>/.local/bin ahead of /opt/homebrew/bin and
#       /usr/local/bin, where a self-updated tool such as `herdr update` installs,
#       so a launchd or systemd PATH resolves the same binaries as an interactive
#       Firstmate shell. It is inserted just before the first of those two, or
#       appended when neither is present; a later copy is dropped, and a
#       directory already ahead of them keeps its place. Empty entries, which
#       name the current directory, keep their places too. An empty home or a
#       home with no such directory prints <path> unchanged.

FM_WD_REFUSED_TEXT_RE='(^|[^be])merg|[rd]emerg|deploy|releas|publish|(^|[^a-z])forced?[[:space:]-]?push|push.*[[:space:]]["'"'"']?((--force|-[a-z]*f[a-z]*)([^a-z]|$)|\+[^[:space:]])'
FM_WD_RESERVED_RE="$FM_WD_REFUSED_TEXT_RE"'|(^|[^a-z])(spend|spent|money|budget|billing|invoice|payment|sign-?in|log-?in|login|credential|secret|password|api.?key|security|production|pii|delet|destroy|wipe)'
FM_WD_TIMER_TOOL_RE='^(ScheduleWakeup|CronCreate|CronList|CronDelete|Monitor|TaskOutput|BashOutput|Wait)$'
FM_WD_TIMER_BASH_RE='(^|[^a-z])(sleep|fm-watch|fm-wake|wake|timer|until)([^a-z]|$)'
# A row that opens by stating the limit. Used by the pane picker, by paused or
# blocked status lines, and by fm_wd_provider_error_class. Do not add another
# detector for these phrases.
FM_WD_USAGE_LIMIT_RE='^[^a-z]*(you( have|.{1,3}ve)? (hit your ([a-z0-9-]+ ){0,2}limit|reached your ([a-z0-9-]+ ){0,5}usage limit)|([a-z0-9-]+ )?(usage|rate)[- ]?limit (hit|reached|reset)|(you( are|.{1,3}re) )?out of credits|waiting on a rate[- ]limit)'
FM_WD_MODEL_SWITCH_RE='^[^a-z]*(switch (to )?((a|another) )?model|switch to another account)'
FM_WD_QUOTA_STATUS_RE='quota (floor|exhausted|is exhausted|at 0|limit|wall)|(hit|reached|at) (the |a |its )?quota|rate.?limited|rate limit (hit|reached)|usage limit (hit|reached)|out of (credits|quota)|credits (are )?(exhausted|at 0|empty)'
# Rows that open by reporting a provider refusal the agent cannot work through:
# an HTTP 429 or rate-limit error, or a billing, credit, past-due, subscription,
# or account-hold refusal. The row may open with spaces or glyphs but not a
# digit, `+`, or `-`, so a numbered diff row quoting one is not a match.
# A 429 counts only as the first number after an `api error`, `stream error`,
# or `unexpected status` prefix, set off by a space, `(`, `=`, `_`, or `:`
# (`status=429`, `HTTP_STATUS_429`), so a token count, duration, or line number
# holding those digits is not one. Rate-limit or billing words count only on
# such an error row, except a bare `error:` row whose message opens with a
# rate limit exceeded or reached (OpenAI's insufficient_quota tokens count on
# any error row).
# Usage-limit rows stay with FM_WD_USAGE_LIMIT_RE and, as a refusal, must also
# name a reset, retry, upgrade, or purchase (FM_WD_PROVIDER_LIMIT_HINT_RE).
# A row announcing an automatic retry (FM_WD_PROVIDER_RETRY_RE) is transient.
# fm_wd_provider_error_class is the one reader that joins all of them.
FM_WD_RATE_LIMIT_ERROR_RE='^[^a-z0-9+-]*(((api|stream) error|unexpected status)[^0-9]*(\(|[[:space:]]|[=_:])429([^0-9]|$)|(api|stream) error[[:space:]]*(:|\().*(rate[_ -]?limit|too many requests)|error[[:space:]]*:[[:space:]]*rate[_ -]?limit[_ -]?(exceeded|reached))'
FM_WD_BILLING_ERROR_RE='^[^a-z0-9+-]*(credit balance (is )?too low[[:space:]]*([^a-z[:space:]]|$)|claude code can.t use your claude subscription|you( are|.{1,3}re) out of extra usage|your account is on hold|your org(anization)? is out of usage|((api|stream) )?error[[:space:]]*(:|\().*(insufficient_quota|exceeded your current quota)|((api|stream) error[[:space:]]*(:|\()|unexpected status).*(billing|credit balance|past due))'
FM_WD_PROVIDER_LIMIT_HINT_RE='reset|try again|upgrade|purchase|more credits|extra.usage|rate-limit-options'
FM_WD_PROVIDER_RETRY_RE='retrying in|\(attempt [0-9]+/[0-9]+\)|retry succeeded|retry successful|request succeeded'

fm_wd_user_bin_path() {  # <path> <home>
  local rest=$1 user_bin dir out='' sep='' placed=0 more=1
  user_bin=${2:+$2/.local/bin}
  if [ -z "$user_bin" ] || [ ! -d "$user_bin" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [ -z "$rest" ]; then
    printf ':%s\n' "$user_bin"
    return 0
  fi
  # Split by hand: read -a would drop a trailing empty entry.
  while [ "$more" = 1 ]; do
    case "$rest" in
      *:*) dir=${rest%%:*}; rest=${rest#*:} ;;
      *) dir=$rest; more=0 ;;
    esac
    case "$dir" in
      "$user_bin") [ "$placed" = 0 ] || continue; placed=1 ;;
      /opt/homebrew/bin|/usr/local/bin)
        [ "$placed" = 1 ] || { out="$out$sep$user_bin"; sep=:; placed=1; } ;;
    esac
    out="$out$sep$dir"
    sep=:
  done
  [ "$placed" = 1 ] || out="$out$sep$user_bin"
  printf '%s\n' "$out"
}

fm_wd_conf_get() {  # <file> <key> <default>
  local file=$1 key=$2 def=${3-} v
  if [ -f "$file" ]; then
    v=$(awk -v k="$key" '
      /^[ \t]*#/ { next }
      { i = index($0, "="); if (i == 0) next
        name = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", name)
        if (name != k) next
        val = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", val); found = 1; last = val }
      END { if (found) print last; else exit 1 }
    ' "$file" 2>/dev/null) && { printf '%s\n' "$v"; return 0; }
  fi
  printf '%s\n' "$def"
}

fm_wd_conf_int() {  # <file> <key> <default>
  local v
  v=$(fm_wd_conf_get "$1" "$2" "$3")
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$3" ;; *) printf '%s\n' "$v" ;; esac
}

fm_wd_lower() {  # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# The text as rows, then its rows joined with spaces and with nothing, so a
# continued command, a soft wrap, or a split word still reads as one line.
_fm_wd_guard_view() {  # <text>
  local text rows
  text=$(fm_wd_lower "$1")
  rows=$(printf '%s\n' "$text" | LC_ALL=C sed -E \
    -e $'s/^[[:space:]]*((│|┃|[|])[[:space:]]*)?((❯|›|⟩|→|❭|>)( |\xC2\xA0)*)?//' \
    -e 's/[[:space:]]*(│|┃)?[[:space:]]*$//' -e 's/\\$//' \
    -e '/^[│┃─━╭╮╰╯┌┐└┘|[:space:]-]*$/d')
  printf '%s\n' "$text"
  printf '%s\n' "$rows" | tr '\n' ' '
  printf '\n'
  printf '%s\n' "$rows" | tr -d '\n'
  printf '\n'
}

fm_wd_reserved() {  # <text>
  _fm_wd_guard_view "$1" | LC_ALL=C grep -Eq "$FM_WD_RESERVED_RE"
}

FM_WD_HUMAN_ONLY_RE='deploy|publish|(^|[^a-z])(spend|spent|money|budget|billing|invoice|payment|sign-?in|log-?in|login|credential|secret|password|api.?key|security|production|pii|shared[- ]?(db|database)|e-?mail|sms|messages? to|delet|destroy|wipe|changed behavio|forced?[[:space:]-]?push)|push.*[[:space:]]["'"'"']?((--force|-[a-z]*f[a-z]*)([^a-z]|$)|\+[^[:space:]])'

fm_wd_nm_awaiting_approval() {  # <text>
  local view
  view=$(_fm_wd_guard_view "$1")
  printf '%s\n' "$view" | LC_ALL=C grep -Eq 'awaiting_approval|awaiting approval' || return 1
  # The token alone does not prove a pipeline step: a plain merge decision can
  # mention it. Require a no-mistakes or named-step context, including the
  # nm-<run>-<step> decision key a gate escalation carries.
  printf '%s\n' "$view" | LC_ALL=C grep -Eq 'no-mistakes|(test|review|document|lint|push|pr|ci|intent|rebase)[[:space:]-]*step|step[[:space:]]+awaiting|nm-[^[:space:]]*-(test|review|document|lint|push|pr|ci|intent|rebase)([^a-z]|$)'
}

fm_wd_human_only() {  # <text>
  local view
  view=$(_fm_wd_guard_view "$1")
  printf '%s\n' "$view" | LC_ALL=C grep -Eq "$FM_WD_HUMAN_ONLY_RE" && return 0
  # Formatting alone must not change authority: shared_database and
  # messages-to-people name the same categories as their spaced forms.
  printf '%s\n' "$view" | tr '_-' '  ' | LC_ALL=C grep -Eq "$FM_WD_HUMAN_ONLY_RE"
}

fm_wd_known_unreachable_timing_flake() {  # <text>
  local view
  view=$(_fm_wd_guard_view "$1")
  printf '%s\n' "$view" | LC_ALL=C grep -Eq 'timing|load-sensitive|load shaped' || return 1
  printf '%s\n' "$view" | LC_ALL=C grep -Eq 'flake|flaky' || return 1
  printf '%s\n' "$view" | LC_ALL=C grep -Eq 'cannot reach|can.t reach|could not reach|unreachable|not reachable'
}

fm_wd_pr_label() {  # <text>
  local hit n
  hit=$(printf '%s' "$1" | grep -oE '/pull/[0-9]+' | head -n 1 || true)
  [ -n "$hit" ] || hit=$(printf '%s' "$1" | grep -oiE 'PR #[0-9]+' | head -n 1 || true)
  [ -n "$hit" ] || hit=$(printf '%s' "$1" | grep -oiE '(^|[^A-Za-z])pr:[[:space:]]*#?[0-9]+' | head -n 1 || true)
  [ -n "$hit" ] || hit=$(printf '%s' "$1" | grep -oE '#[0-9]+' | head -n 1 || true)
  [ -n "$hit" ] || return 0
  n=$(printf '%s' "$hit" | grep -oE '[0-9]+$')
  [ -n "$n" ] && printf 'PR #%s\n' "$n"
  return 0
}

fm_wd_text_allowed() {  # <text>
  ! _fm_wd_guard_view "$1" | LC_ALL=C grep -Eq "$FM_WD_REFUSED_TEXT_RE"
}

fm_wd_seat_family() {  # <harness:model>
  local h=${1%%:*} m
  m=$(fm_wd_lower "${1#*:}")
  case "$m" in
    *claude*|*haiku*|*sonnet*|*opus*|*fable*|*mythos*) printf 'anthropic\n'; return 0 ;;
    *gemini*|*flash*|*carbon*) printf 'google\n'; return 0 ;;
    *gpt*|*codex*|o[0-9]*) printf 'openai\n'; return 0 ;;
  esac
  case "$h" in
    claude) printf 'anthropic\n' ;;
    agy) printf 'google\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

fm_wd_paste_placeholder() {  # <composer-window>
  printf '%s\n' "$1" | LC_ALL=C grep -Eiq '\[Pasted (text|content) '
}

FM_WD_PROMPT_RE=$'^((│|┃|[|]) )?(❯|›|⟩|→|❭|>)( |\xC2\xA0|$)'

# The two shapes that prove a draft's boundary. box_closed sets box_top and
# box_bottom around row g of the awk row array; rule_len measures a column-0 rule.
FM_WD_BOUNDARY_AWK='
  function bordered(r) { return r ~ /^(│|┃) / }
  function box_closed(g) {
    for (box_top = g - 1; box_top > 0 && bordered(row[box_top]); box_top--) ;
    for (box_bottom = g + 1; box_bottom <= NR && bordered(row[box_bottom]); box_bottom++) ;
    return row[box_top] ~ /^(╭|┌)/ && row[box_bottom] ~ /^(╰|└)/
  }
  function rule_len(r, t, n) { t = r; n = gsub(/─|━/, "", t); return (t ~ /^[ \t]*$/ && r !~ /^[ \t]/) ? n : 0 }'

fm_wd_prompt_tail() {  # <composer-window>
  printf '%s\n' "$1" | awk -v glyph="$FM_WD_PROMPT_RE" 'found || $0 ~ glyph { found = 1; print }'
}

# The rows of a draft fm_wd_draft_readable proved: a box's body from its first
# prompt row, or the rows from the prompt row down to the last long rule.
fm_wd_draft_rows() {  # <composer-window>
  printf '%s\n' "$1" | awk -v glyph="$FM_WD_PROMPT_RE" "$FM_WD_BOUNDARY_AWK"'
    { row[NR] = $0; if ($0 ~ glyph) last = NR }
    END {
      if (!last) exit
      if (bordered(row[last]) && box_closed(last)) {
        for (i = box_top + 1; row[i] !~ glyph; i++) ;
        for (; i < box_bottom; i++) print row[i]
        exit
      }
      for (stop = NR; stop > last && rule_len(row[stop]) < 40; stop--) ;
      for (i = last; i < stop; i++) print row[i]
    }'
}

# Enter needs the whole draft proven. A bordered last prompt row needs a closed
# box whole inside the window. A plain one needs a pair of equal rules of 40 or
# more characters at column 0 around it: draft rows sit indented under the prompt
# glyph, so such a rule row is the harness's and not typed text.
fm_wd_draft_readable() {  # <composer-window> [rows-above-the-window]
  local above=${2-} above_n=0
  fm_wd_paste_placeholder "$1" && return 1
  [ -z "$above" ] || above_n=$(printf '%s\n' "$above" | wc -l | tr -d ' ')
  { [ -z "$above" ] || printf '%s\n' "$above"; printf '%s\n' "$1"; } | awk -v glyph="$FM_WD_PROMPT_RE" -v above_n="$above_n" "$FM_WD_BOUNDARY_AWK"'
    { row[NR] = $0; if ($0 ~ glyph) g = NR }
    END {
      if (g <= above_n) exit 1
      if (bordered(row[g])) exit !(box_closed(g) && box_top > above_n)
      t = rule_len(row[g - 1])
      if (t >= 40) for (i = g + 1; i <= NR; i++) if (rule_len(row[i]) == t) exit 0
      exit 1
    }'
}

fm_wd_strip_ansi() {
  LC_ALL=C sed -e $'s/\033\\[[0-9;?<>=]*[ -\\/]*[@-~]//g' -e $'s/\033\\][^\a]*\a//g' -e $'s/\r//g'
}

fm_wd_usage_limit_text() {  # <text>
  printf '%s' "$(fm_wd_lower "$1")" | LC_ALL=C grep -Eq "$FM_WD_USAGE_LIMIT_RE"
}

# Prints billing, usage_limit, or rate_limit for the first class any row of
# <text> states, in that order, and returns 1 when no row states one.
fm_wd_provider_error_class() {  # <text>
  local t='' raw line
  raw=$(fm_wd_lower "$1")
  while IFS= read -r line; do
    if printf '%s\n' "$line" | LC_ALL=C grep -Eq "$FM_WD_PROVIDER_RETRY_RE"; then t=''; continue; fi
    t="${t:+$t$'\n'}$line"
  done <<< "$raw"
  [ -n "$t" ] || return 1
  if printf '%s\n' "$t" | LC_ALL=C grep -Eq "$FM_WD_BILLING_ERROR_RE"; then
    printf 'billing\n'
  elif printf '%s\n' "$t" | LC_ALL=C grep -E -A1 "$FM_WD_USAGE_LIMIT_RE" | LC_ALL=C grep -Eq "$FM_WD_PROVIDER_LIMIT_HINT_RE"; then
    printf 'usage_limit\n'
  elif printf '%s\n' "$t" | LC_ALL=C grep -Eq "$FM_WD_RATE_LIMIT_ERROR_RE"; then
    printf 'rate_limit\n'
  else
    return 1
  fi
}

# The provider-error class stated in the last FM_WD_PROVIDER_ERROR_ROWS (12)
# non-blank rows of a screen, where a harness leaves the error that ended its
# turn above its prompt. Callers judge only an idle screen.
fm_wd_provider_error_screen() {  # <screen>
  local n=${FM_WD_PROVIDER_ERROR_ROWS:-12}
  [ -n "${1-}" ] || return 1
  case "$n" in ''|0|*[!0-9]*) n=12 ;; esac
  fm_wd_provider_error_class "$(_fm_wd_tail_rows "$1" "$n")"
}

fm_wd_usage_limit_autowait() {  # <screen>
  local tag row
  [ -n "${1-}" ] || return 1
  while IFS=$'\t' read -r tag row; do
    [ "$tag" = below ] && return 0
    fm_wd_usage_limit_text "$row" && return 0
  done < <(_fm_wd_tail_rows "$1" 10 | awk -v glyph="$FM_WD_PROMPT_RE" '
    { row[NR] = $0; if ($0 ~ glyph) g = NR }
    END {
      if (!g) exit
      for (i = 1; i <= NR; i++) {
        if (tolower(row[i]) !~ /continuing automatically( at|:)[ \t]*[^ \t]/) continue
        print (i > g ? "below" : "above") "\t" row[i]
      }
    }')
  return 1
}

fm_wd_handoff_in_progress() {  # <claim-file> <lock-pid> <now> <max-secs>
  local claim=$1 pid=$2 now=$3 max=$4 deadline
  [ -n "$pid" ] && [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  deadline=$(jq -er --arg p "$pid" 'select(.version == 1 and (.predecessor_pid | tostring) == $p) | .deadline | numbers | floor' "$claim" 2>/dev/null) || return 1
  [ "$deadline" -gt "$now" ] && [ $((deadline - now)) -le "$max" ]
}

fm_wd_quota_status_line() {  # <line>
  local last body
  last=$(printf '%s' "$1")
  case "$last" in paused*|blocked*) ;; *) return 1 ;; esac
  body=$(printf '%s' "$last" | sed 's/^[^:]*:[[:space:]]*//')
  printf '%s' "$(fm_wd_lower "$body")" | LC_ALL=C grep -Eq "$FM_WD_QUOTA_STATUS_RE" && return 0
  fm_wd_usage_limit_text "$body"
}

fm_wd_usage_limit_kind() {  # <name>
  case "$1" in
    usage-limit|'Grok weekly-limit choice') return 0 ;;
  esac
  return 1
}

# Pane dialog first. If that misses, reuse fm_composer_blocking_dialog and
# normalize a usage-limit kind to the pane name `usage-limit`. No extra regex.
fm_wd_observe_dialog() {  # <screen> [<harness>]
  local dialog
  dialog=$(fm_wd_pane_dialog "$1" "${2-}") || dialog=''
  if [ -n "$dialog" ]; then
    printf '%s\n' "$dialog"
    return 0
  fi
  if declare -F fm_composer_blocking_dialog >/dev/null 2>&1; then
    dialog=$(fm_composer_blocking_dialog "$1") || return 1
    if fm_wd_usage_limit_kind "$dialog"; then
      printf 'usage-limit\n'
      return 0
    fi
  fi
  return 1
}

# The last <n> non-blank rows of a screen, ANSI-stripped.
_fm_wd_tail_rows() {  # <screen> <n>
  printf '%s\n' "$1" | fm_wd_strip_ansi | awk 'NF { rows[++n] = $0 } END { s = n - '"$2"' + 1; if (s < 1) s = 1; for (i = s; i <= n; i++) print rows[i] }'
}

if ! declare -F fm_control_feedback_dialog_dismiss >/dev/null 2>&1; then
  # shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"
fi

fm_wd_feedback_dialog_dismiss() {  # <screen> [<harness>]
  fm_control_feedback_dialog_dismiss "${2-}" "${1-}"
}

fm_wd_feedback_dialog_key() {  # <screen> [<harness>]
  local spec
  spec=$(fm_control_feedback_dialog_dismiss "${2-}" "${1-}") || return 1
  printf '%s\n' "${spec#*$'\t'}"
}

FM_WD_PICKER_FOOTER_RE='(Enter to (confirm|select|submit|continue)|Esc to (cancel|exit|go back)|↑/↓ to (navigate|select)|Tab:next answer)'

# The screen rows of a picker from the top of the paragraph that holds its
# first option row through the end of the screen, read from it because the
# prompt rows drop blank rows. The option rows are found the way main's
# `_fm_wd_dialog_rows` finds them: the last cursor row within the last 14
# non-blank rows, then the last `1.` or `1)` row at or above it, or the cursor
# row itself for an unnumbered picker. When the option rows open their own
# paragraph, the paragraph above them is the picker's title and is included.
# Empty when no option row is found.
_fm_wd_picker_rows() {  # <screen>
  printf '%s\n' "${1-}" | fm_wd_strip_ansi | awk '
    { r[NR] = $0 }
    END {
      last = NR
      while (last > 0 && r[last] !~ /[^ \t]/) last--
      seen = 0; floor = 1
      for (i = last; i > 0; i--) if (r[i] ~ /[^ \t]/ && ++seen == 14) { floor = i; break }
      sel = 0
      for (i = last; i >= floor; i--) if (r[i] ~ /(❯|›)[ \t]*[^ \t]/ || r[i] ~ />[ \t]*[0-9]+[.)][ \t]/) { sel = i; break }
      first = 0
      for (i = (sel ? sel : last); i >= floor; i--) if (r[i] ~ /^[^0-9A-Za-z]*1[.)][ \t]/) { first = i; break }
      if (!first) first = sel
      if (!first) exit 0
      top = first
      while (top > 1 && r[top - 1] ~ /[^ \t]/) top--
      # Options that open their own paragraph take the paragraph above them
      # as the picker title, the way Claude draws `Select login method:`.
      if (top == first) {
        while (top > 1 && r[top - 1] !~ /[^ \t]/) top--
        while (top > 1 && r[top - 1] ~ /[^ \t]/) top--
      }
      for (i = top; i <= NR; i++) print r[i]
    }'
}

fm_wd_pane_dialog() {  # <screen> [<harness>]
  local tail
  [ -n "${1-}" ] || return 1
  if fm_wd_feedback_dialog_dismiss "$1" "${2-}" >/dev/null; then
    printf 'feedback\n'
    return 0
  fi
  tail=$(_fm_wd_tail_rows "$1" 14)
  # A picker: its last non-blank row is the recorded footer and a selected
  # row sits above it. Claude Code 2.1.316's folder-trust picker has no
  # numbers, so a cursor glyph before any text counts; a bare `>` needs a number.
  printf '%s\n' "$tail" | awk -v footer="$FM_WD_PICKER_FOOTER_RE" '
    /(❯|›)[ \t]*[^ \t]/ || />[ \t]*[0-9]+[.)][ \t]/ { selected = 1 }
    NF { last = $0 }
    END { exit !(selected && last ~ footer) }
  ' || return 1
  if _fm_wd_picker_rows "$1" | LC_ALL=C grep -Eiq "do you want to (proceed|make this edit|create|allow|run|overwrite|delete)|allow (this|once|always)|yes, and don.t ask again|background work is running|trust (this|the files)"; then
    printf 'permission\n'
  elif _fm_wd_dialog_rows "$1" own | LC_ALL=C grep -Eiq "$FM_WD_USAGE_LIMIT_RE"; then
    printf 'usage-limit\n'
  elif _fm_wd_dialog_rows "$1" own | LC_ALL=C grep -Eiq "$FM_WD_MODEL_SWITCH_RE"; then
    printf 'model-switch\n'
  else
    printf 'question\n'
  fi
}

# Rows of the dialog at the bottom of a screen. Below a rule row above the first
# option, everything is the dialog. With no such rule the boundary is unproven:
# scope `own` takes the paragraph above the options and `all` takes every tail row.
# Scope `own` always stops above the first option row, so a label proves nothing.
# Scope `options` takes only the option rows.
_fm_wd_dialog_rows() {  # <screen> <own|all|options>
  printf '%s\n' "$1" | fm_wd_strip_ansi | awk -v scope="$2" '
    function blank(r) { gsub(/[ \t│┃|─━╭╮╰╯┌┐└┘-]/, "", r); return r == "" }
    function rule(r) { return blank(r) && (index(r, "─") || index(r, "━")) }
    { rows[NR] = $0 }
    END {
      last = NR
      while (last > 0 && blank(rows[last])) last--
      seen = 0; floor = 1
      for (i = last; i > 0; i--) if (rows[i] ~ /[^ \t]/ && ++seen == 14) { floor = i; break }
      for (i = last; i >= floor; i--) if (rows[i] ~ /(❯|›)[ \t]*[^ \t]/ || rows[i] ~ />[ \t]*[0-9]+[.)][ \t]/) { sel = i; break }
      top = floor
      stop = last
      if (sel) {
        first = sel
        for (i = sel; i >= floor; i--) if (rows[i] ~ /^[^0-9A-Za-z]*1[.)][ \t]/) { first = i; break }
        ruled = 0
        for (i = first - 1; i >= floor; i--) if (rule(rows[i])) { ruled = i; break }
        if (scope == "own") stop = first - 1
        if (scope == "options") top = first
        else if (ruled) top = ruled + 1
        else if (scope == "own") {
          top = first
          i = first - 1
          while (i >= floor && blank(rows[i])) i--
          while (i >= floor && !blank(rows[i])) { top = i; i-- }
        }
      }
      for (i = top; i <= stop; i++) if (rows[i] ~ /[^ \t]/) print rows[i]
    }'
}

# Human-only steps, matched on lowercased rows. The order is the order the
# kinds are tried, so a row naming a one-time code is `otp` before it is a code.
FM_WD_HS_CAPTCHA_RE='captcha|verify (that )?you.{0,4}(are|re) (a )?human|i.{0,3}m not a robot'
FM_WD_HS_OTP_RE='one.?time (pass(word|code)|code)|(^|[^a-z0-9])(otp|2fa|mfa)([^a-z0-9]|$)|two.?factor|multi.?factor|authenticator app'
FM_WD_HS_CODE_RE='(verification|confirmation|security|authori[sz]ation|device|login|sign.?in|pairing) code|(^|[^a-z])(enter|paste|type|input) (the |your |this )?([0-9]+.digit )?code|code sent to'
FM_WD_HS_APPROVAL_RE='waiting for (your |the )?approval|approve (this|the|your) (sign.?in|log.?in|login|request|device|session|connection)|(sign.?in|log.?in|login|device) approval|approval (is )?required|(check|open) your (phone|device|email|inbox|app) to (approve|confirm|continue|sign)'
FM_WD_HS_SIGNIN_RE='(^|[^a-z])(sign|log).?in (to|with|required|again|via|using)|(^|[^a-z])signing in|(not|no longer) (signed|logged) in|log.?in required|authenticat(e|ion) (is )?required|authenticate to continue|waiting for (the )?(browser )?(authentication|auth|sign.?in|log.?in)|select (a |your )?login method|run /login'
FM_WD_HS_AUTH_ERROR_RE='^[^a-z]*(not logged in|invalid api key|oauth token (has )?expired|please run /login|login expired|failed to authenticate: oauth session expired|api error: 401|authentication (error|failed))'

# A recorded Codex CLI 0.151.0 dialog, which fm_wd_pane_dialog does not read:
# its command-approval question or hook-review heading, a numbered cursor row
# (`›` or `>`) below it, and its whole lowercase footer as the last row.
fm_wd_codex_dialog() {  # <screen>
  local rows
  rows=$(printf '%s\n' "${1-}" | fm_wd_strip_ansi | LC_ALL=C awk '
    { r[NR] = $0 }
    END {
      last = NR
      while (last > 0 && r[last] !~ /[^ \t]/) last--
      if (r[last] !~ /^[ \t]*Press enter to confirm or esc to (cancel|go back)[ \t]*$/) exit 1
      floor = last - 40; if (floor < 1) floor = 1
      head = 0
      for (i = last - 1; i >= floor; i--) if (r[i] ~ /^[ \t]*(Would you like to run the following command\?|Hooks need review)[ \t]*$/) { head = i; break }
      if (!head) exit 1
      cursor = 0
      for (i = head + 1; i < last; i++) if (r[i] ~ /^[ \t]*(›|>)[ \t]*[0-9]+\.[ \t]/) cursor++
      if (cursor != 1) exit 1
      for (i = head; i <= last; i++) print r[i]
    }') || return 1
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
}

fm_wd_human_step() {  # <screen>
  local tag row kind re
  [ -n "${1-}" ] || return 1
  # A tool permission dialog names the command or file it asks about, and that
  # text is not a human-only step; permission handling owns it. A Codex
  # approval dialog is one too, though fm_wd_pane_dialog does not read it.
  [ "$(fm_wd_pane_dialog "$1")" != permission ] || return 1
  ! fm_wd_codex_dialog "$1" >/dev/null || return 1
  while IFS=$'\t' read -r tag row; do
    row=$(fm_wd_lower "$row")
    printf '%s' "$row" | LC_ALL=C grep -Eq "$FM_WD_HS_AUTH_ERROR_RE" && { printf 'sign-in\n'; return 0; }
    [ "$tag" != above ] || continue
    for kind in captcha otp verification-code approval sign-in; do
      case "$kind" in
        captcha) re=$FM_WD_HS_CAPTCHA_RE ;;
        otp) re=$FM_WD_HS_OTP_RE ;;
        verification-code) re=$FM_WD_HS_CODE_RE ;;
        approval) re=$FM_WD_HS_APPROVAL_RE ;;
        *) re=$FM_WD_HS_SIGNIN_RE ;;
      esac
      printf '%s' "$row" | LC_ALL=C grep -Eq "$re" && { printf '%s\n' "$kind"; return 0; }
    done
  done < <(printf '%s\n' "$1" | fm_wd_strip_ansi | awk -v glyph="$FM_WD_PROMPT_RE" -v footer="$FM_WD_PICKER_FOOTER_RE" '
    function blank(r) { gsub(/[ \t│┃|─━╭╮╰╯┌┐└┘-]/, "", r); return r == "" }
    { row[NR] = $0 }
    END {
      last = NR
      while (last > 0 && row[last] !~ /[^ \t]/) last--
      seen = 0; floor = 1
      for (i = last; i > 0; i--) if (row[i] ~ /[^ \t]/ && ++seen == 14) { floor = i; break }
      # A picker cursor, as fm_wd_pane_dialog reads it: a cursor glyph before
      # any text, or a bare `>` before a number. An unnumbered picker has no
      # `1.` row, so its cursor row stands for its options.
      if (row[last] ~ footer) for (i = last; i >= floor; i--) if (row[i] ~ /(❯|›)[ \t]*[^ \t]/ || row[i] ~ />[ \t]*[0-9]+[.)][ \t]/) { opt = i; break }
      if (opt) {
        if (row[opt] ~ /(❯|›|>)[ \t]*[0-9]+[.)][ \t]/) for (i = opt; i >= floor; i--) if (row[i] ~ /^[^0-9A-Za-z]*1[.)][ \t]/) { opt = i; break }
        i = opt - 1
        while (i >= floor && blank(row[i])) i--
        for (; i >= floor && !blank(row[i]); i--) print "rows\t" row[i]
        exit
      }
      for (i = last; i >= floor; i--) if (row[i] ~ glyph) { g = i; break }
      for (i = last; i >= floor && i > g; i--) if ((blank(row[i]) && (index(row[i], "─") || index(row[i], "━"))) || row[i] ~ /\? for shortcuts/) { composer = 1; break }
      if (!g && composer) exit
      if (!g) { for (i = floor; i <= last; i++) if (row[i] ~ /[^ \t]/) print "rows\t" row[i]; exit }
      for (i = g - 1; i >= floor && n < 4; i--) if (row[i] ~ /[^ \t]/) { print "above\t" row[i]; n++ }
      if (composer) exit
      # A typed draft wraps onto rows indented under the glyph, inside the
      # composer body; only a row at column 0 belongs to the harness.
      for (i = g + 1; i <= last && !blank(row[i]) && row[i] ~ /^(│|┃|[|])?[ \t]/; i++) ;
      for (; i <= last && !blank(row[i]); i++) print "below\t" row[i]
      # An empty row, not a border, and then output below the prompt row: the
      # prompt row is an echoed earlier turn and no composer shows below it.
      # One indented row there is a footer, as under a Codex composer.
      if (i > last || row[i] ~ /[^ \t]/) exit
      n = 0
      for (j = i; j <= last; j++) if (row[j] ~ /[^ \t]/) { n++; one = row[j] }
      if (n == 0 || (n == 1 && one ~ /^[ \t]/)) exit
      for (; i <= last; i++) if (row[i] ~ /[^ \t]/) print "rows\t" row[i]
    }')
  return 1
}

fm_wd_dialog_options() {  # <screen>
  _fm_wd_dialog_rows "$1" options | LC_ALL=C sed -nE 's/^[^0-9]*(❯|›|>)?[[:blank:]]*([0-9]+)[.)][[:blank:]]+(.*[^[:blank:]│┃|])[[:blank:]│┃|]*$/\2	\3/p'
}

fm_wd_dialog_text() {  # <screen>
  _fm_wd_dialog_rows "$1" all | tr -s ' \t' '  ' | tr '\n' ' '
}

fm_wd_transcript_events() {  # <transcript.jsonl> [lines]
  local f=$1 n=${2:-400}
  [ -f "$f" ] || return 1
  tail -n "$n" "$f" 2>/dev/null | jq -rR '
    fromjson? | select(type == "object" and .type == "assistant")
    | ((.timestamp // "") | tostring | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) as $t
    | (.message.content // [])[]?
    | if .type == "text" then "T\t\($t)\t" + ((.text // "") | gsub("[\t\r\n]+"; " ") | .[0:400])
      elif .type == "tool_use" then "U\t\($t)\t\(.name // "")\t" + (((.input.command // .input.prompt // .input.description // "") | tostring) | gsub("[\t\r\n]+"; " ") | .[0:200])
      else empty end
  ' 2>/dev/null
}

fm_wd_loop_verdict() {  # [rapid-secs]  (stdin: fm_wd_transcript_events)
  awk -F'\t' -v rapid="${1:-180}" -v toolre="$FM_WD_TIMER_TOOL_RE" -v bashre="$FM_WD_TIMER_BASH_RE" '
    function norm(s,   w, k, j, out) { s = tolower(s); gsub(/[*_`"]+/, "", s); k = split(s, w, /[ \t]+/); out = ""
      for (j = 1; j <= k; j++) { if (w[j] == "") continue; if (w[j] ~ /[0-9]/) w[j] = "#"; out = out (out == "" ? "" : " ") w[j] }
      return out }
    function head6(s,   a, k, out) { k = split(s, a, " "); out = ""; for (j = 1; j <= k && j <= 6; j++) out = out " " a[j]; return out }
    { n++; kind[n] = $1; at[n] = $2 + 0
      if ($1 == "T") txt[n] = norm($3)
      else { tool[n] = $3; arg[n] = tolower($4) } }
    END {
      t = 0
      for (i = n; i >= 1 && t < 5; i--) if (kind[i] == "T" && txt[i] != "") { t++; ti[t] = i }
      if (t < 3) { print "none\t0"; exit }
      best = ""; bc = 0; hb = ""; hc = 0
      for (a = 1; a <= t; a++) {
        c = 0; h = 0
        for (b = 1; b <= t; b++) { if (txt[ti[b]] == txt[ti[a]]) c++; if (head6(txt[ti[b]]) == head6(txt[ti[a]])) h++ }
        if (c > bc) { bc = c; best = txt[ti[a]] }
        if (h > hc) { hc = h; hb = head6(txt[ti[a]]) }
      }
      if (bc >= 3) { verdict = "loop"; key = best }
      else if (hc >= 3) { verdict = "near"; key = "" }
      else { print "none\t" bc; exit }
      first = 0; lastat = 0; firstat = 0
      for (b = 1; b <= t; b++) {
        i = ti[b]
        same = (verdict == "loop") ? (txt[i] == key) : (head6(txt[i]) == hb)
        if (same) { if (first == 0 || i < first) { first = i; firstat = at[i] }; if (at[i] > lastat) lastat = at[i] }
      }
      for (i = first; i <= n; i++) if (kind[i] == "U") {
        if (tool[i] ~ toolre) continue
        if (tool[i] == "Bash" && arg[i] ~ bashre) continue
        print "none\t" bc; exit
      }
      if (verdict == "loop" && firstat > 0 && lastat > 0 && lastat - firstat <= rapid) verdict = "rapid"
      print verdict "\t" (verdict == "near" ? hc : bc)
    }'
}

fm_wd_loop_evidence() {  # <max-chars>  (stdin: fm_wd_transcript_events)
  awk -F'\t' -v max="$1" '
    { row[++n] = ($1 == "T") ? "assistant: " $3 : "tool: " $3 " " substr($4, 1, 80)
      if ($1 == "T") at[++t] = n }
    END {
      first = (t > 5) ? at[t - 4] : 1
      start = n + 1; used = 0
      for (i = n; i >= first; i--) { used += length(row[i]) + 1; if (used > max) break; start = i }
      for (i = start; i <= n; i++) print row[i]
    }'
}

fm_wd_stall_proof() {  # <turn-running> <cpu-busy> <kind>...
  local turn=$1 cpu=$2 kinds k distinct=0 seen=' '
  shift 2
  [ "$turn" = 0 ] || return 1
  [ "$cpu" = 0 ] || return 1
  for k in "$@"; do
    case "$k" in rendered|filesystem|kernel|records) ;; *) continue ;; esac
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "
    distinct=$((distinct + 1))
  done
  kinds=$distinct
  [ "$kinds" -ge 2 ]
}

_fm_wd_field() {  # <text>
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-600
}

fm_wd_record() {  # <ledger> <id> <home> <subject> <symptom> <action> <phase> <detail>
  local ledger=$1 now
  now=${FM_WD_NOW:-$(date +%s)}
  mkdir -p "$(dirname "$ledger")" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$(_fm_wd_field "$2")" "$(_fm_wd_field "$3")" \
    "$(_fm_wd_field "$4")" "$(_fm_wd_field "$5")" "$(_fm_wd_field "$6")" "$(_fm_wd_field "$7")" \
    "$(_fm_wd_field "$8")" >> "$ledger"
}

fm_wd_last_epoch() {  # <ledger> <home> <symptom> <action> [phase-regex] [subject]
  [ -f "$1" ] || return 0
  awk -F'\t' -v h="$2" -v s="$3" -v a="$4" -v p="${5:-^(pending|dry-run|refused|held)$}" -v subj="${6:-}" '
    $3 == h && ($5 == s || s == "*") && ($6 == a || a == "*") && $7 ~ p && (subj == "" || $4 == subj) { last = $1 }
    END { if (last != "") print last }' "$1"
}

fm_wd_rate_ok() {  # <ledger> <home> <symptom> <action> <secs> <now> [subject]
  local last
  last=$(fm_wd_last_epoch "$1" "$2" "$3" "$4" "" "${7:-}")
  [ -z "$last" ] || [ $(( $6 - last )) -ge "$5" ]
}

fm_wd_count_since() {  # <ledger> <home> <symptom|*> <action|*> <phase-regex> <since> [subject]
  [ -f "$1" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v h="$2" -v s="$3" -v a="$4" -v p="$5" -v since="$6" -v subj="${7:-}" '
    $1 >= since && $3 == h && ($5 == s || s == "*") && ($6 == a || a == "*") && $7 ~ p && (subj == "" || $4 == subj) { c++ }
    END { print c + 0 }' "$1"
}

fm_wd_open_pending() {  # <ledger>
  [ -f "$1" ] || return 0
  awk -F'\t' '
    $7 == "pending" { if (!($2 in pend)) order[++n] = $2; pend[$2] = $3 "\t" $5 "\t" $6 "\t" $1; closed[$2] = 0; next }
    $2 in pend { closed[$2] = 1 }
    END { for (i = 1; i <= n; i++) { id = order[i]; if (!closed[id]) print id "\t" pend[id] } }' "$1"
}

fm_wd_spent_since() {  # <model-calls.tsv> <since>
  [ -f "$1" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v since="$2" '$1 >= since && $8 ~ /^[0-9.]+$/ { s += $8 } END { printf "%.4f\n", s + 0 }' "$1"
}

fm_wd_iso() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# A positive decimal integer that shell arithmetic can hold: no sign, no leading
# zero (bash would read it as octal), at most 15 digits. The digits are listed
# one by one, because a range can match other characters in some locales.
fm_wd_epoch_ok() {  # <value>
  case "$1" in ''|0*|*[!0123456789]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

fm_wd_heartbeat_published() {  # <heartbeat-file>
  local v
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  # One read of the raw text: the watcher replaces the file by rename, so a
  # second open could see another stamp. jq may print 1.7e9 or 1700000000.0 as
  # the same integer, so the text must also hold the stamp as those plain
  # digits. In valid JSON a quote that follows { or , opens a string or closes
  # one, and a closing quote is followed only by whitespace, a colon, a comma, a
  # bracket, a brace or the end of the text. So neither pattern can match from
  # inside a string, and an array element is never followed by a colon: the two
  # patterns see key tokens only, which are one key of that name in the whole
  # text, spelled plainly or with \u escapes, and the plain spelling with the
  # plain digits as its value. The first pattern also matches another key only
  # when that key holds a \u escape and no character outside a-z and _, which
  # keeps a large heartbeat fast.
  v=$(jq -Rrs '. as $text
    | (try fromjson catch null)
    | if type == "object" and .schema == "fm-heartbeat.v1" then .published_epoch else empty end
    | select(type == "number" and . > 0 and . == floor and . < 1e15) | floor | tostring
    | select(. as $v | $text
        | ([scan("[{,][ \t\r\n]*(\"published_epoch\"|\"[a-z_]*(?:\\\\u[0-9a-fA-F]{4}[a-z_]*)+\")[ \t\r\n]*:")[0]
            | fromjson | select(. == "published_epoch")] | length == 1)
          and test("[{,][ \t\r\n]*\"published_epoch\"[ \t\r\n]*:[ \t\r\n]*" + $v + "[ \t\r\n]*[,}]"))' "$1" 2>/dev/null) || return 1
  fm_wd_epoch_ok "$v" || return 1
  printf '%s\n' "$v"
}

fm_wd_supervisor_gap_rows() {  # <home> <now> <published-epoch>
  local home=$1 now=$2 pub=$3 age
  case "$home" in ''|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  # A row starts with exactly 10 digits, so the last digits of a cut epoch can
  # never read as an epoch. A clock of another length prints no row.
  fm_wd_epoch_ok "$now" && [ "${#now}" -eq 10 ] && fm_wd_epoch_ok "$pub" || return 1
  age=$((now - pub))
  [ "$age" -ge 0 ] || return 1
  [ "$age" -le 600 ] || printf '%s\t%s\theartbeat_age=%s\n' "$now" "$home" "$age"
  printf '%s\tobserved\t%s\n' "$now" "$home"
}

# Names the handoff by path. Warns through fm-handoff-lib.sh when the file
# exceeds that lib's line cap, and still prints only the path.
fm_wd_restart_prompt() { # <handoff> <home> <script-dir> <token>
  local lib
  if ! declare -F fm_handoff_warn_line_cap >/dev/null 2>&1; then
    lib=${BASH_SOURCE[0]%/*}
    # shellcheck source=bin/fm-handoff-lib.sh
    . "$lib/fm-handoff-lib.sh"
  fi
  fm_handoff_warn_line_cap "$1"
  printf 'Watchdog restart of this firstmate home. Read %s first, then take over as the session-start contract says. After you hold the session lock, run: FM_HOME=%s %s/fm-watchdog.sh pickup %s' \
    "$1" "$2" "$3" "$4"
}

fm_wd_last_wake_ack() {  # <wake-ledger> <now> [daemon-acks]
  local v acks=${3:-}
  [ -f "$1" ] || return 1
  fm_wd_epoch_ok "$2" || return 1
  [ -n "$acks" ] && [ -f "$acks" ] && [ -r "$acks" ] || acks=/dev/null
  v=$(tail -n 2000 "$1" 2>/dev/null | LC_ALL=C awk -F'\t' -v now="$2" -v acks="$acks" '
    BEGIN { while ((getline line < acks) > 0) daemon[line] = 1 }
    $2 == "ack" && !(($3 "\t" $4) in daemon) && $1 ~ /^[1-9][0-9]*$/ && length($1) <= 15 && $1 + 0 <= now + 0 && $1 + 0 > m + 0 { m = $1 }
    END { if (m != "") print m }')
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}
