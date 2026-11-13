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
#   fm_wd_pane_dialog <screen>
#       Prints `feedback`, `permission`, `usage-limit`, `model-switch`, or
#       `question` when the last rows of the screen hold that blocking dialog,
#       else nothing (exit 1). A dialog needs its structure, not its words: the
#       feedback survey needs its heading and its `0: Dismiss` row among the last
#       rows; every other kind needs a selected numbered row and a recorded picker
#       footer as the last non-blank row. A row that opens by stating a provider
#       limit is `usage-limit`; a same-account model or account switch stays
#       `model-switch`.
#   fm_wd_usage_limit_text <text>
#       Returns 0 when <text> opens by stating a provider weekly, session, usage,
#       rate, or credits limit. Conversation that only mentions those words later
#       in the row is not a match.
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
#   fm_wd_count_since <ledger> <home> <symptom|*> <action|*> <phase-regex> <since>
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

FM_WD_REFUSED_TEXT_RE='(^|[^be])merg|[rd]emerg|deploy|releas|publish|(^|[^a-z])force.?push|push.*[[:space:]]["'"'"']?((--force|-[a-z]*f[a-z]*)([^a-z]|$)|\+[^[:space:]])'
FM_WD_RESERVED_RE="$FM_WD_REFUSED_TEXT_RE"'|(^|[^a-z])(spend|spent|money|budget|billing|invoice|payment|sign-?in|log-?in|login|credential|secret|password|api.?key|security|production|pii|delet|destroy|wipe)'
FM_WD_TIMER_TOOL_RE='^(ScheduleWakeup|CronCreate|CronList|CronDelete|Monitor|TaskOutput|BashOutput|Wait)$'
FM_WD_TIMER_BASH_RE='(^|[^a-z])(sleep|fm-watch|fm-wake|wake|timer|until)([^a-z]|$)'
# A row that opens by stating the limit. Used by the pane picker and by paused
# or blocked status lines. Do not add a fourth detector for these phrases.
FM_WD_USAGE_LIMIT_RE='^[^a-z]*(you( have|.{1,3}ve)? hit your ([a-z0-9-]+ ){0,2}limit|([a-z0-9-]+ )?(usage|rate)[- ]?limit (hit|reached|reset)|(you( are|.{1,3}re) )?out of credits|waiting on a rate[- ]limit)'
FM_WD_MODEL_SWITCH_RE='^[^a-z]*(switch (to )?((a|another) )?model|switch to another account)'
FM_WD_QUOTA_STATUS_RE='quota (floor|exhausted|is exhausted|at 0|limit|wall)|(hit|reached|at) (the |a |its )?quota|rate.?limited|rate limit (hit|reached)|usage limit (hit|reached)|out of (credits|quota)|credits (are )?(exhausted|at 0|empty)'

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

fm_wd_text_allowed() {  # <text>
  ! _fm_wd_guard_view "$1" | LC_ALL=C grep -Eq "$FM_WD_REFUSED_TEXT_RE"
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
fm_wd_observe_dialog() {  # <screen>
  local dialog
  dialog=$(fm_wd_pane_dialog "$1") || dialog=''
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

fm_wd_pane_dialog() {  # <screen>
  local tail
  [ -n "${1-}" ] || return 1
  tail=$(_fm_wd_tail_rows "$1" 14)
  if printf '%s\n' "$tail" | LC_ALL=C grep -Eq 'How is Claude doing' \
     && printf '%s\n' "$tail" | LC_ALL=C grep -Eq '(^|[^0-9])0:[ ]*Dismiss'; then
    printf 'feedback\n'
    return 0
  fi
  # A picker: its last non-blank row is the recorded footer and a selected
  # row sits above it. Claude Code 2.1.316's folder-trust picker has no
  # numbers, so a cursor glyph before any text counts; a bare `>` needs a number.
  printf '%s\n' "$tail" | awk '
    /(❯|›)[ \t]*[^ \t]/ || />[ \t]*[0-9]+[.)][ \t]/ { selected = 1 }
    NF { last = $0 }
    END { exit !(selected && last ~ /(Enter to (confirm|select|submit|continue)|Esc to (cancel|exit|go back)|↑\/↓ to (navigate|select)|Tab:next answer)/) }
  ' || return 1
  if _fm_wd_dialog_rows "$1" all | LC_ALL=C grep -Eiq "do you want to (proceed|make this edit|create|allow|run|overwrite|delete)|allow (this|once|always)|yes, and don.t ask again|background work is running|trust (this|the files)"; then
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

fm_wd_count_since() {  # <ledger> <home> <symptom|*> <action|*> <phase-regex> <since>
  [ -f "$1" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v h="$2" -v s="$3" -v a="$4" -v p="$5" -v since="$6" '
    $1 >= since && $3 == h && ($5 == s || s == "*") && ($6 == a || a == "*") && $7 ~ p { c++ }
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
