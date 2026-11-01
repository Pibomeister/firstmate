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
#       Prints `feedback`, `permission`, `model-switch`, or `question` when the
#       last rows of the screen hold that blocking dialog, else nothing (exit 1).
#       A dialog needs its structure, not its words: the feedback survey needs its
#       heading and its `0: Dismiss` row among the last rows; every other kind
#       needs a selected numbered row and a recorded picker footer as the last
#       non-blank row.
#   fm_wd_dialog_options <screen>
#       Prints `<number>\t<text>` for each numbered option of the dialog.
#   fm_wd_dialog_text <screen>
#       Prints the text a reserved check and the judge read, one line: the rows
#       below a rule above the options, else all the last rows.
#   fm_wd_footer_percent <screen>
#       Prints N from a Claude `N% until auto-compact` or
#       `until auto-compact: N%` footer in the last rows.
#   fm_wd_transcript_events <transcript.jsonl> [lines]
#       Prints `T\t<epoch>\t<text>` for assistant text and `U\t<epoch>\t<tool>\t<arg>`
#       for assistant tool calls from the transcript tail.
#   fm_wd_loop_verdict [rapid-secs]
#       Filter over fm_wd_transcript_events output. Prints
#       `<loop|rapid|near|none>\t<repeats>\t<sample>`. `loop` means at least three
#       of the last five assistant texts are identical after case, digit, and
#       whitespace normalization, with only timer tools between them. `rapid` is
#       a loop whose repeats all fall inside rapid-secs. `near` means three share
#       their first six words but are not identical; that goes to the judge.
#   fm_wd_stall_proof <turn-running 0|1|unknown> <cpu-busy 0|1|unknown> <kind>...
#       Returns 0 when no veto holds and at least two distinct source kinds
#       (rendered, filesystem, kernel, records) are given. A running turn or a
#       busy CPU vetoes; an unknown turn or CPU state also vetoes a restart.
#   fm_wd_record <ledger> <id> <home> <subject> <symptom> <action> <phase> <detail>
#       Appends one ledger row; tabs and newlines in fields become spaces.
#   fm_wd_last_epoch <ledger> <home> <symptom> <action> [phase-regex]
#       Prints the newest epoch of a matching row whose phase is pending,
#       dry-run, refused, or held (or the given regex), else nothing.
#   fm_wd_rate_ok <ledger> <home> <symptom> <action> <secs> <now>
#       Returns 0 when the last attempt is older than secs.
#   fm_wd_count_since <ledger> <home> <symptom|*> <action|*> <phase-regex> <since>
#   fm_wd_open_pending <ledger>
#       Prints `<id>\t<home>\t<symptom>\t<action>\t<epoch>` for every pending
#       row with no later outcome row for the same id.
#   fm_wd_spent_since <model-calls.tsv> <since>
#       Prints the summed numeric cost column, in dollars.
#   fm_wd_iso <epoch>
#       Prints the UTC ISO-8601 time.

FM_WD_REFUSED_TEXT_RE='(^|[^be])merg|[rd]emerg|deploy|releas|publish|(^|[^a-z])force.?push|push.*[[:space:]]["'"'"']?((--force|-[a-z]*f[a-z]*)([^a-z]|$)|\+[^[:space:]])'
FM_WD_RESERVED_RE="$FM_WD_REFUSED_TEXT_RE"'|(^|[^a-z])(spend|spent|money|budget|billing|invoice|payment|sign-?in|log-?in|login|credential|secret|password|api.?key|security|production|pii|delet|destroy|wipe)'
FM_WD_TIMER_TOOL_RE='^(ScheduleWakeup|CronCreate|CronList|CronDelete|Monitor|TaskOutput|BashOutput|Wait)$'
FM_WD_TIMER_BASH_RE='(^|[^a-z])(sleep|fm-watch|fm-wake|wake|timer|until)([^a-z]|$)'

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
  elif _fm_wd_dialog_rows "$1" own | LC_ALL=C grep -Eiq '^[^a-z]*(you( have|.{1,3}ve)? hit your ([a-z0-9-]+ ){0,2}limit|([a-z0-9-]+ )?(usage|rate) limit (hit|reached)|(you( are|.{1,3}re) )?out of credits|switch (to )?((a|another) )?model|switch to another account)'; then
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

fm_wd_footer_percent() {  # <screen>
  _fm_wd_tail_rows "$1" 10 | LC_ALL=C sed -nE \
    -e 's/.*[^0-9]([0-9]{1,3})% until auto-compact.*/\1/p' \
    -e 's/^([0-9]{1,3})% until auto-compact.*/\1/p' \
    -e 's/.*until auto-compact:[ ]*([0-9]{1,3})%.*/\1/p' | tail -n 1
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
      if ($1 == "T") { txt[n] = norm($3); raw[n] = $3 }
      else { tool[n] = $3; arg[n] = tolower($4) } }
    END {
      t = 0
      for (i = n; i >= 1 && t < 5; i--) if (kind[i] == "T" && txt[i] != "") { t++; ti[t] = i }
      if (t < 3) { print "none\t0\t"; exit }
      best = ""; bc = 0; hb = ""; hc = 0
      for (a = 1; a <= t; a++) {
        c = 0; h = 0
        for (b = 1; b <= t; b++) { if (txt[ti[b]] == txt[ti[a]]) c++; if (head6(txt[ti[b]]) == head6(txt[ti[a]])) h++ }
        if (c > bc) { bc = c; best = txt[ti[a]]; bi = ti[a] }
        if (h > hc) { hc = h; hb = head6(txt[ti[a]]); hi = ti[a] }
      }
      if (bc >= 3) { verdict = "loop"; key = best; sample = raw[bi] }
      else if (hc >= 3) { verdict = "near"; key = ""; sample = raw[hi] }
      else { print "none\t" bc "\t"; exit }
      first = 0; lastat = 0; firstat = 0
      for (b = 1; b <= t; b++) {
        i = ti[b]
        same = (verdict == "loop") ? (txt[i] == key) : (head6(txt[i]) == hb)
        if (same) { if (first == 0 || i < first) { first = i; firstat = at[i] }; if (at[i] > lastat) lastat = at[i] }
      }
      for (i = first; i <= n; i++) if (kind[i] == "U") {
        if (tool[i] ~ toolre) continue
        if (tool[i] == "Bash" && arg[i] ~ bashre) continue
        print "none\t" bc "\twork-between"; exit
      }
      if (verdict == "loop" && firstat > 0 && lastat > 0 && lastat - firstat <= rapid) verdict = "rapid"
      gsub(/\t/, " ", sample)
      print verdict "\t" (verdict == "near" ? hc : bc) "\t" substr(sample, 1, 160)
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

fm_wd_last_epoch() {  # <ledger> <home> <symptom> <action> [phase-regex]
  [ -f "$1" ] || return 0
  awk -F'\t' -v h="$2" -v s="$3" -v a="$4" -v p="${5:-^(pending|dry-run|refused|held)$}" '
    $3 == h && ($5 == s || s == "*") && ($6 == a || a == "*") && $7 ~ p { last = $1 }
    END { if (last != "") print last }' "$1"
}

fm_wd_rate_ok() {  # <ledger> <home> <symptom> <action> <secs> <now>
  local last
  last=$(fm_wd_last_epoch "$1" "$2" "$3" "$4")
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
