#!/usr/bin/env bash
# fm-permission-route.sh - route a Claude Code permission prompt on an
# unattended ship or scout worker. bin/fm-spawn.sh wires it as that worker's
# PermissionRequest, PostToolUse, PostToolUseFailure, and SessionEnd hooks.
#
# The route never grants a permission. It has two outcomes:
#
#   refuse  Answer the prompt "no" with a fix instruction, so the worker
#           reissues a command the harness can check. Given only for the one
#           prompt class whose cause is established: under
#           --dangerously-skip-permissions, Claude Code still asks when it
#           cannot check a Bash command for a dangerous removal because the
#           command holds an unquoted heredoc whose body carries a backtick.
#   hold    Print nothing, so the prompt stays for a person, and wake the
#           supervisor with one keyed `blocked` status line. Every other
#           request is held, including every request that names a reserved
#           category: credential, sign-in, spend, security, destructive,
#           production, release, or reserved.
#
# The watchdog reads the same prompt from the worker pane
# (bin/fm-permission-prompt.sh, docs/watchdog.md "Worker permission prompts").
# This hook is the earlier of the two reports: it runs before the prompt is
# drawn, on every backend, and whether or not a watchdog runs. Both write the
# same two status keys, so one prompt is one open decision.
#
# Usage:
#   fm-permission-route.sh claude-request <state-dir> <id>
#       PermissionRequest hook. Reads the hook payload on stdin. Prints the
#       refusal decision, or nothing for a hold. Always exits 0.
#   fm-permission-route.sh claude-settled <state-dir> <id> tool-finished|session-end|pane-clear
#       Closes an open hold: tool-finished (PostToolUse or PostToolUseFailure
#       payload on stdin) when the held request itself finished, session-end
#       always, and pane-clear when the caller has proven that the worker pane
#       shows no permission prompt. pane-clear is the watchdog's call. It
#       closes nothing while the newest hold is younger than
#       FM_PERMISSION_ROUTE_PANE_CLEAR_SECS (default 15), because the hold is
#       written a moment before the prompt is drawn, and it never closes the
#       owner-reserved key. It ends only the requests of the read it checked
#       that age on, so a request held after that read stays held. Always
#       exits 0.
#       A finished request closes its row under each key that holds one:
#       under the owner-reserved key only a call with the same whole input.
#   fm-permission-route.sh held-keys <state-dir> <id>
#       Prints each status key this route still holds open, one per row.
#       Exits 1 when the task cannot be named, or when a held set exists and
#       it, or the status log, cannot be read or folded.
#   fm-permission-route.sh classify
#       Reads one command on stdin and prints `refuse` or `hold <category>`
#       for the command-text checks alone. Exits 0.
#   fm-permission-route.sh --help
#
# claude-request holds, in this order, when:
#   attended      AK_LIFECYCLE_POLICY is not `unattended`. Nothing is recorded
#                 and nobody is woken, because a person is at the session.
#   posture       state/<id>.meta is not a ship or scout Claude worker launched
#                 with approval_mode=bypass, or the payload is not a
#                 PermissionRequest in bypassPermissions mode.
#   tool          The request is not for the Bash tool.
#   input         The Bash input asks to leave the sandbox or carries a key
#                 other than command, description, timeout, run_in_background.
#   shape         The command is empty, longer than FM_PERMISSION_ROUTE_MAX_BYTES
#                 (default 65536), or holds a control byte other than newline
#                 and tab.
#   <reserved>    The command text names a reserved category. The text is read
#                 as written and again with quotes, backslashes, and line
#                 continuations removed. The scan is the union of the word
#                 lists below and the watchdog's hard-stop vocabulary
#                 (fm_pp_hardstop_category in bin/fm-permission-prompt.sh, its
#                 owner); a match in either one holds the request.
#   unidentified  The command is not the established prompt class: it has no
#                 closed heredoc with a plain unquoted delimiter and an
#                 unescaped backtick in its body, or it has a heredoc of any
#                 other form.
#   computed      Outside the heredoc bodies, a word in command position holds
#                 `$` or a glob character, or a backtick stands anywhere, so
#                 the text does not show which command runs. A command word
#                 built by brace expansion is not detected; it is refused,
#                 which runs nothing. The same holds when a leading
#                 assignment or redirection target is quoted, when a command
#                 word ends in a line continuation, and when more than 64
#                 words lead a command.
#   wrapper       Outside the heredoc bodies, a word in command position runs
#                 other text as a command (eval, source, sh, env, xargs, an
#                 interpreter such as python, node, perl, ruby, or php, including a
#                 versioned or distro name such as python3.13t or nodejs, ...).
#   repeat        The same command was already refused once.
#   ceiling       FM_PERMISSION_ROUTE_MAX_REFUSALS (default 5) refusals are
#                 already recorded for this worker.
#   record        The ledger row could not be written.
# A missing jq, an unreadable record, or a malformed payload is also a hold.
#
# Records, all in <state-dir>:
#   <id>.permission-route.tsv  One row per routed request: epoch, verdict
#       (refuse or hold), category, tool, SHA-256 of the command, command
#       bytes, request hash (for a hold, the hash a finished tool call is
#       matched by; an ordinary request past the limit below is still named
#       by its own hash here). The command text is never written. The row is
#       written before the answer is printed.
#   <id>.permission-held       The held set, a journal that lasts from the
#       first hold until the session ends. Each write appends one row and
#       nothing replaces the file, so a hook that cannot take the lock loses
#       no row of another hook. A held row is tab-separated: its status key,
#       its request hash (the SHA-256 over the tool name with, for Bash, its
#       command and every other input field except the description, the
#       timeout, and the background flag, or with its whole input for any
#       other tool or under the owner-reserved key; `-` for a payload that
#       cannot be read, which every such request shares), the epoch it was
#       asked, and a token. A request asked again appends a new row, and the
#       newest row of a key and hash is that request. A row with a fifth
#       field `done` ends the request whose newest row carries the same
#       token. The ordinary key takes at most FM_PERMISSION_ROUTE_MAX_HELD
#       (default 20, never below 1) distinct requests, and every request past
#       that limit shares one row with the hash `+`, which no finished tool
#       call closes; the owner-reserved key has no limit, so every such
#       distinct request is reported.
#   <id>.permission-lock       Directory lock around the two records above.
#       A hook that cannot take it still holds its request.
#   <id>.status                `blocked [at=<epoch>] [key=<key>]` for each newly
#       held request, and `resolved` with the same key when the last request
#       held under that key finishes, the session ends, or the pane is proven
#       clear. The key is one of the watchdog's two:
#         permission-prompt-hardstop  the request names a reserved category,
#             or its text could not be read whole (a missing jq, an unreadable
#             payload, a command past the size limit). The watchdog reserves
#             this key for the owner, so no council or judge seat rules on it.
#         permission-prompt-held      every other hold.
#       A request that is held for another reason is still scanned for a
#       reserved category, over its tool name and its whole tool input, so a
#       file write to a credential path is owner-reserved too. One key covers every prompt
#       waiting under it on that worker, because the payload carries no
#       tool-use id. A prompt a person answers "no" reports no end. Its
#       ordinary key stays open until a watchdog in act mode proves the pane
#       clear, and its owner-reserved key until the supervisor closes it with
#       its own answer, or the session ends: an open key that is stale costs
#       one look, a closed key over a waiting prompt costs the wait this route
#       exists to end.
#
# Unattended policy seam. The only policy this route reads is
# AK_LIFECYCLE_POLICY=unattended, which agent-kit publishes for lifecycle
# runs. agent-kit publishes no permission-prompt policy (its Claude Code
# adapter contract puts permission prompts outside its guarantees), so this
# route has no allow outcome. An allow outcome needs such a published policy
# first, and it would be read in claude_request where the refusal is decided.
#
# Test seam, honoured only with FM_TEST_SEAM=1: FM_PERMISSION_ROUTE_PAUSE_AT
# names one point (pane-clear-close, before a pane-clear close ends its rows,
# or hold-recheck, before a hold's last look at its key) and
# FM_PERMISSION_ROUTE_PAUSE_DIR a directory. The hook makes <point>.reached
# there and waits up to 30 seconds for <point>.go.
#
# The reserved scan decides hold against refuse, never whether a command runs.
# A reserved command the word lists miss is refused, not held; it still does
# not run, and a reissued command meets the harness's own checks again.
# docs/watchdog.md "The worker's own permission hook" owns the operator contract.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secret-lib.sh
. "$SCRIPT_DIR/fm-secret-lib.sh"
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"

# The watchdog's two status keys (wd_permission_prompt in bin/fm-watchdog.sh).
FM_PERMISSION_ROUTE_HELD_KEY='permission-prompt-held'
FM_PERMISSION_ROUTE_HARDSTOP_KEY='permission-prompt-hardstop'
case "${FM_PERMISSION_ROUTE_MAX_HELD:-}" in
  '' | *[!0-9]*) FM_PERMISSION_ROUTE_MAX_HELD=20 ;;
esac
[ "$FM_PERMISSION_ROUTE_MAX_HELD" -ge 1 ] 2>/dev/null || FM_PERMISSION_ROUTE_MAX_HELD=20
FM_PERMISSION_ROUTE_MESSAGE="Firstmate permission route: refused, and the command did not run. No person will answer this prompt. The command holds an unquoted heredoc. The shell expands the body of such a heredoc, and a backtick in that body runs as a command, so the harness could not check the command. Correct the heredoc and run the command again: escape each backtick in the body as \\\` when the body needs shell expansion, or quote the delimiter (for example <<'EOF') when the body is literal text. Do not retry the command unchanged."

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

int_or() {  # <value> <default>
  case "${1:-}" in
    '' | *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  else
    sha256sum 2>/dev/null | cut -d' ' -f1
  fi
}

# Word lists for the reserved categories. Each is matched against lowercased
# text, bounded so a longer identifier does not match by accident.
FM_PR_B='(^|[^a-z0-9_])'
FM_PR_E='([^a-z0-9_]|$)'
FM_PR_CREDENTIAL_RE="${FM_PR_B}(credentials?|secrets?|passwords?|passwd|passphrase|tokens?|api[_-]?keys?|private[_-]?keys?|keychains?|keyring|id_rsa|id_ed25519|gpg|ssh-add|ssh-keygen|cookies?|oauth|bearer|vault|kinit)${FM_PR_E}|\.(ssh|aws|kube|docker|npmrc|pypirc|netrc|pgpass|env)${FM_PR_E}|\.config/(gh|gcloud)|git-credentials"
FM_PR_SIGNIN_RE="${FM_PR_B}(log-?in|log-?out|sign-?in|sign-?out|sign-?up|adduser|auth|sso|2fa|mfa|otp)${FM_PR_E}|authenticat|authoriz"
FM_PR_SPEND_RE="${FM_PR_B}(spend|spent|money|budget|billing|invoice|payment|purchase|buy|subscribe|subscription|upgrade|credits?|pricing|stripe|paypal)${FM_PR_E}"
FM_PR_SECURITY_RE="${FM_PR_B}(sudo|doas|su|chmod|chown|chgrp|chflags|xattr|setfacl|spctl|csrutil|pfctl|firewall|launchctl|crontab|osascript|security|trust|permissions?|sandbox|bypass|hooks?|curl|wget|ncat|socat|scp|sftp|rsync|ssh)${FM_PR_E}|dangerously|--no-verify|\.claude${FM_PR_E}|\.git${FM_PR_E}|\.gitconfig|\.gitmodules|\.mcp\.json|\.(bashrc|bash_profile|zshrc|zshenv|zprofile|profile)${FM_PR_E}|claude\.md|agents\.md|settings(\.local)?\.json"
FM_PR_DESTRUCTIVE_RE="${FM_PR_B}(rm|rmdir|unlink|shred|srm|trash|truncate|mkfs|diskutil|kill|pkill|killall|mv)${FM_PR_E}|${FM_PR_B}dd[[:space:]]+(if|of)=|rmsync|rmtree|rimraf|delet|destroy|wipe|purg|prun|eras|remov|overwrit|clobber|--force|--hard|${FM_PR_B}-(rf|fr)${FM_PR_E}|${FM_PR_B}(sed|perl)[[:space:]]+-[a-z]*i|${FM_PR_B}drop[[:space:]]+(table|database|schema|index)|${FM_PR_B}git${FM_PR_E}[^;|&]*${FM_PR_B}(clean|reset|restore|checkout|stash|rebase|branch|tag|worktree|update-ref|filter-branch|push|gc)${FM_PR_E}"
FM_PR_PRODUCTION_RE="${FM_PR_B}(terraform|pulumi|aws|gcloud|gsutil|bq|az|kubectl|helm|fly|flyctl|vercel|wrangler|supabase|heroku|psql|mysql|redis-cli|gh|glab|production|prod)${FM_PR_E}"

# Print the reserved category the text names, or return 1 when it names none.
reserved_category() {  # <text>
  local raw stripped view
  raw=$(fm_wd_lower "$1")
  stripped=$(printf '%s' "$raw" | awk 'BEGIN { ORS = "" } { if (sub(/\\$/, "")) print; else print $0 "\n" }' | tr -d "'\"\\\\")
  for view in "$raw" "$stripped"; do
    if fm_secret_like "$view" || printf '%s\n' "$view" | grep -Eq "$FM_PR_CREDENTIAL_RE"; then
      printf 'credential'; return 0
    fi
    if printf '%s\n' "$view" | grep -Eq "$FM_PR_SIGNIN_RE"; then printf 'sign-in'; return 0; fi
    if printf '%s\n' "$view" | grep -Eq "$FM_PR_SPEND_RE"; then printf 'spend'; return 0; fi
    if printf '%s\n' "$view" | grep -Eq "$FM_PR_SECURITY_RE"; then printf 'security'; return 0; fi
    if printf '%s\n' "$view" | grep -Eq "$FM_PR_DESTRUCTIVE_RE"; then printf 'destructive'; return 0; fi
    if printf '%s\n' "$view" | grep -Eq "$FM_PR_PRODUCTION_RE" || fm_wd_reserved "$view"; then
      printf 'production'; return 0
    fi
  done
  # The watchdog's hard-stop vocabulary, read last: it names its own category
  # (release or reserved) for text the lists above do not match. It is loaded
  # here, off the path every finished tool call takes, and a load that fails
  # reserves the request.
  if ! declare -F fm_pp_hardstop_category >/dev/null 2>&1; then
    # shellcheck source=bin/fm-permission-prompt.sh
    . "$SCRIPT_DIR/fm-permission-prompt.sh" || { printf 'reserved'; return 0; }
  fi
  for view in "$1" "$stripped"; do
    if view=$(fm_pp_hardstop_category "$view"); then printf '%s' "$view"; return 0; fi
  done
  return 1
}

# Read the command as written, never the stripped projection, and print:
#   unidentified  not the established prompt class. The class needs every
#                 heredoc to use a plain unquoted delimiter and to be closed,
#                 and at least one body to hold an unescaped backtick. A
#                 here-string (<<<) is not a heredoc.
#   computed      a command-position word outside the bodies holds `$` or a
#                 glob character, or a backtick stands anywhere outside them.
#   wrapper       a command-position word outside the bodies runs other text.
#   class         the established class, with none of the above.
# Command positions are found without reading quotes, so a separator inside a
# quoted string also starts one. That only adds holds. A space inside a quoted
# leading assignment or redirection target would hide the command word, so a
# quote or backslash in either one is `computed`, and so is a command word a
# trailing backslash continues on the next line.
command_shape() {  # <text>
  printf '%s\n' "$1" | awk -v quote="'" '
    function scan_segment(seg,    tok, base, guard) {
      for (guard = 0; guard < 64; guard++) {
        sub(/^[ \t]+/, "", seg)
        if (seg == "") return
        tok = seg
        sub(/[ \t].*$/, "", tok)
        seg = substr(seg, length(tok) + 1)
        if (tok ~ /^[0-9]*[<>]/) {
          if (tok ~ /^[0-9]*[<>]+$/) {
            sub(/^[ \t]+/, "", seg)
            tok = seg
            sub(/[ \t].*$/, "", tok)
            seg = substr(seg, length(tok) + 1)
          }
          if (tok ~ quoted) { computed = 1; return }
          continue
        }
        if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) {
          if (tok ~ quoted) { computed = 1; return }
          continue
        }
        if (tok == "if" || tok == "then" || tok == "else" || tok == "elif" || tok == "do" || tok == "while" || tok == "until" || tok == "!" || tok == "time") continue
        if (tok == "for" || tok == "case" || tok == "select" || tok == "function" || tok == "in" || tok == "done" || tok == "fi" || tok == "esac" || tok == "[" || tok == "[[" || tok ~ /^#/) return
        if (tok ~ /[$*?\[]/ || tok ~ /\\$/) { computed = 1; return }
        base = tolower(tok)
        gsub("[\"" quote "\\\\]", "", base)
        sub(/^.*\//, "", base)
        if (base ~ /^(eval|exec|source|\.|command|builtin|env|xargs|sh|bash|zsh|dash|ksh|fish|python[0-9.]*[tw]?|nodejs|node|perl[0-9.]*|ruby[0-9.]*|php[0-9.]*|nohup|nice|timeout|watch|find|parallel|open|nc|op)$/) wrapper = 1
        return
      }
      # More leading words than this scan reads: the command word is unknown.
      computed = 1
    }
    BEGIN { quoted = "[\"" quote "\\\\]" }
    !inbody {
      line = $0
      out = ""
      while (match(line, /<<-?[ \t]*/)) {
        pre = substr(line, 1, RSTART - 1)
        op = substr(line, RSTART, RLENGTH)
        rest = substr(line, RSTART + RLENGTH)
        if (rest ~ /^</) { out = out pre " "; sub(/^<+/, "", rest); line = rest; continue }
        if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) { bad = 1; break }
        delim = substr(rest, 1, RLENGTH)
        rest = substr(rest, RLENGTH + 1)
        if (rest != "" && rest !~ /^[ \t;|&)<>]/) { bad = 1; break }
        n++
        delims[n] = delim
        dashes[n] = (op ~ /^<<-/)
        out = out pre " "
        line = rest
      }
      outer[++lines] = out line
      if (n > 0) { inbody = 1; cur = 1; pending = 0 }
      next
    }
    {
      row = $0
      if (dashes[cur]) sub(/^\t+/, "", row)
      if (row == delims[cur]) {
        if (pending) found = 1
        pending = 0
        cur++
        if (cur > n) { inbody = 0; n = 0 }
        next
      }
      body = $0
      gsub(/\\\\/, "", body)
      gsub(/\\`/, "", body)
      if (index(body, "`")) pending = 1
    }
    END {
      if (bad || inbody || !found) { print "unidentified"; exit }
      for (i = 1; i <= lines; i++) {
        if (index(outer[i], "`")) computed = 1
        count = split(outer[i], segs, /[;&|(){}`]/)
        for (j = 1; j <= count; j++) scan_segment(segs[j])
      }
      if (computed) print "computed"
      else if (wrapper) print "wrapper"
      else print "class"
    }'
}

# The command-text verdict: shape, then reserved category, then class.
classify_command() {  # <command>
  local command=$1 max category shape
  max=$(int_or "${FM_PERMISSION_ROUTE_MAX_BYTES:-}" 65536)
  if [ -z "$command" ] || [ "${#command}" -gt "$max" ]; then
    printf 'hold shape'; return 0
  fi
  if printf '%s' "$command" | tr -d '\n\t' | grep -q '[[:cntrl:]]'; then
    printf 'hold shape'; return 0
  fi
  if category=$(reserved_category "$command"); then
    printf 'hold %s' "$category"; return 0
  fi
  shape=$(command_shape "$command")
  case "$shape" in
    class) printf 'refuse' ;;
    computed | wrapper) printf 'hold %s' "$shape" ;;
    *) printf 'hold unidentified' ;;
  esac
}

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

ledger_row() {  # <verdict> <category> [<request hash>]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$TOOL" "$COMMAND_SHA" "$COMMAND_BYTES" "${3-$REQUEST_HASH}" >>"$LEDGER" 2>/dev/null
}

status_append() {  # <line>
  printf '%s\n' "$1" >>"$STATUS" 2>/dev/null || return 1
  if [ -e "$CONFIG/fleet-ledger" ]; then
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATUS" >/dev/null 2>&1 || true
  fi
}

# 0 when the status log holds that key open, 1 when it does not, and 2 when
# the fold cannot be loaded or run. bin/fm-classify-lib.sh owns that fold; it
# is loaded only on the hold and settle paths.
key_open() {  # <key>
  local open
  if ! command -v status_open_decisions >/dev/null 2>&1; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh" || return 2
  fi
  [ -e "$STATUS" ] || return 1
  open=$(status_open_decisions "$STATUS" 2>/dev/null) || return 2
  printf '%s\n' "$open" | grep -q "^$1"$'\t'
}

# The status key for a hold. Only a request whose text was read whole and
# names no reserved category is held under the key a council seat may see.
hold_key() {  # <category>
  case "$1" in
    credential | sign-in | spend | security | destructive | production | release | reserved | shape)
      printf '%s' "$FM_PERMISSION_ROUTE_HARDSTOP_KEY"; return 0 ;;
  esac
  if [ "${SCAN_OK:-0}" -eq 1 ] && ! reserved_category "$SCAN_TEXT" >/dev/null; then
    printf '%s' "$FM_PERMISSION_ROUTE_HELD_KEY"
  else
    printf '%s' "$FM_PERMISSION_ROUTE_HARDSTOP_KEY"
  fi
}

# The held set is a journal. A hook only ever appends one whole row to it, so
# no writer replaces the set and no append is lost, with the lock or without.
#   held row  <key> <request hash> <epoch> <token>
#   done row  <key> <request hash> <epoch> <token> done
# The newest held row of a key and hash is that request. A done row ends the
# request only while its token is still the newest one, so a writer never ends
# a request that was asked again after the writer read the set.

# Read the open requests into HELD, one `<key> <hash> <epoch> <token>` per row.
# Fails, with HELD empty, when the set exists and cannot be read.
marker_read() {
  HELD=
  [ -e "$MARKER" ] || return 0
  HELD=$(awk -F '\t' '
    $1 == "" { next }
    { k = $1 SUBSEP $2 }
    $5 == "done" { if ((k in token) && token[k] == $4) { delete token[k]; delete at[k] } next }
    { token[k] = $4; at[k] = $3 }
    END { for (k in token) { split(k, part, SUBSEP); printf "%s\t%s\t%s\t%s\n", part[1], part[2], at[k], token[k] } }
    ' "$MARKER" 2>/dev/null) || { HELD=; return 1; }
}

held_rows() {  # <key> [<request hash>]: the open requests of that key in HELD, or that one
  printf '%s\n' "$HELD" | awk -F '\t' -v key="$1" -v hash="${2-}" '
    $1 == key && (hash == "" || $2 == hash) { n++ }
    END { print n + 0 }'
}

# Append one held row for a request under the current time.
marker_put() {  # <key> <request hash>
  local now
  PUT_SEQ=$((${PUT_SEQ:-0} + 1))
  now=$(date +%s)
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$now" "$now.$$.$RANDOM.$PUT_SEQ" >>"$MARKER" 2>/dev/null
}

# End the open requests of a key, or that one request, as HELD shows them.
# Each done row is its own append.
marker_end() {  # <key> [<request hash>]
  local key hash at token now
  now=$(date +%s)
  while IFS=$'\t' read -r key hash at token; do
    [ "$key" = "$1" ] || continue
    [ -z "${2-}" ] || [ "$hash" = "$2" ] || continue
    printf '%s\t%s\t%s\t%s\tdone\n' "$key" "$hash" "$now" "$token" >>"$MARKER" 2>/dev/null || true
  done <<EOF_HELD
$HELD
EOF_HELD
}

# End the requests of a key that another writer already resolved, such as the
# supervisor's own answer, so they never stand for a new hold. Only a hook
# that holds the lock does this, and only when the status log says the key is
# closed. A hook without the lock can open the key at the same moment: then no
# row was stale for certain, and every row ended here is held again.
marker_prune() {
  local key hash
  [ "${LOCKED:-0}" -eq 1 ] || return 0
  for key in "$FM_PERMISSION_ROUTE_HELD_KEY" "$FM_PERMISSION_ROUTE_HARDSTOP_KEY"; do
    [ "$(held_rows "$key")" -gt 0 ] || continue
    key_open "$key"
    [ "$?" -eq 1 ] || continue
    marker_end "$key"
    if key_open "$key"; then
      while IFS=$'\t' read -r _ hash _; do
        [ -z "$hash" ] || marker_put "$key" "$hash" || true
      done <<EOF_ENDED
$(printf '%s\n' "$HELD" | awk -F '\t' -v key="$key" '$1 == key')
EOF_ENDED
    fi
  done
  marker_read || true
}

pause_at() {  # <point>: the test seam the header names
  local n=0
  [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_PERMISSION_ROUTE_PAUSE_AT:-}" = "$1" ] || return 0
  [ -d "${FM_PERMISSION_ROUTE_PAUSE_DIR:-}" ] || return 0
  : >"$FM_PERMISSION_ROUTE_PAUSE_DIR/$1.reached" 2>/dev/null || return 0
  while [ ! -e "$FM_PERMISSION_ROUTE_PAUSE_DIR/$1.go" ] && [ "$n" -lt 300 ]; do
    sleep 0.1
    n=$((n + 1))
  done
}

hold_note() {  # <key>: who answers a prompt held under that key
  if [ "$1" = "$FM_PERMISSION_ROUTE_HARDSTOP_KEY" ]; then
    printf 'it names or may name an owner-reserved category, so only the owner answers it in the worker terminal'
  else
    printf 'a person or the supervisor must answer it in the worker terminal'
  fi
}

# Close a key in the status log when the set holds no open request under it.
# The set is read again after the close: a hook without the lock can hold a
# request under the key at the same moment, and then the key is opened again.
settle_key() {  # <key> <why>
  marker_read || return 0
  [ "$(held_rows "$1")" -eq 0 ] || return 0
  if key_open "$1"; then
    status_append "resolved [at=$(date +%s)] [key=$1]: permission prompt no longer waiting: $2" || true
  fi
  marker_read || return 0
  if [ "$(held_rows "$1")" -gt 0 ] && ! key_open "$1"; then
    status_append "blocked [at=$(date +%s)] [key=$1]: permission prompt waiting on a request held while this key was closing; nothing was answered, and $(hold_note "$1")" || true
  fi
}

# End every open request of a key, as HELD shows them, and close the key.
close_key() {  # <key> <why>
  [ "$(held_rows "$1")" -gt 0 ] || return 0
  marker_end "$1"
  settle_key "$1" "$2"
}

# A directory lock around the ledger and the held set. A lock older than one
# minute is abandoned, because every hook that takes it ends within seconds.
lock_acquire() {
  local tries=0
  LOCKED=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || return 1
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
  LOCKED=1
}

lock_release() {
  [ "${LOCKED:-0}" -eq 1 ] || return 0
  rmdir "$LOCK" 2>/dev/null || true
  LOCKED=0
}

# Record a hold and wake the supervisor for each newly held request. A wake
# is still written when the lock or the ledger is unavailable. A request is
# new under a key when that key has no open row for it, so a request first
# held as ordinary and asked again as owner-reserved still gets its reserved
# line. Every hold appends its row under the current time, also a request
# asked again, so the quiet period before a pane-clear close starts again with
# each request. The ordinary key takes at most FM_PERMISSION_ROUTE_MAX_HELD
# requests, because a declined request never reports that it ended. Every
# request past the limit shares one row with the hash `+`. No finished tool
# call matches that row, so the key then stays open until the session ends,
# the pane is proven clear, or the supervisor answers.
# The owner-reserved key has no limit: each such request gets its row and line.
# The row is appended before the line, and both are checked after they are
# written: a request that is not new still gets a line when its key is not
# open, and a row that another hook ended in the same moment is held again.
# The key is read once more at the end, so a close written by another writer
# while this hold ran, the watchdog's among them, is answered with a new line.
hold() {  # <category> [nolock]: nolock when the caller just failed to lock
  local key hash=$REQUEST_HASH new=0 line
  key=$(hold_key "$1")
  [ "$key" != "$FM_PERMISSION_ROUTE_HARDSTOP_KEY" ] || hash=$REQUEST_FULL_HASH
  [ "${2-}" = nolock ] || lock_acquire || true
  ledger_row hold "$1" "$hash" || true
  marker_read || true
  marker_prune
  if [ "$(held_rows "$key" "$hash")" -eq 0 ]; then
    if [ "$key" = "$FM_PERMISSION_ROUTE_HELD_KEY" ] \
      && [ "$(( $(held_rows "$key") - $(held_rows "$key" +) ))" -ge "$FM_PERMISSION_ROUTE_MAX_HELD" ]; then
      hash=+
    else
      new=1
    fi
  fi
  marker_put "$key" "$hash" || true
  line="[key=$key]: permission prompt waiting on a $TOOL request, held as $1; nothing was answered, and $(hold_note "$key")"
  if [ "$new" -eq 1 ] || ! key_open "$key"; then
    status_append "blocked [at=$(date +%s)] $line" || true
  fi
  if marker_read && [ "$(held_rows "$key" "$hash")" -eq 0 ]; then
    marker_put "$key" "$hash" || true
  fi
  pause_at hold-recheck
  key_open "$key"
  if [ "$?" -eq 1 ]; then
    status_append "blocked [at=$(date +%s)] $line" || true
  fi
  lock_release
}

bind_task() {  # <state-dir> <id>
  STATE=${1:-}
  ID=${2:-}
  case "$ID" in '' | *[!A-Za-z0-9._-]* | .*) return 1 ;; esac
  [ -n "$STATE" ] && [ -d "$STATE" ] || return 1
  META="$STATE/$ID.meta"
  LEDGER="$STATE/$ID.permission-route.tsv"
  MARKER="$STATE/$ID.permission-held"
  LOCK="$STATE/$ID.permission-lock"
  STATUS="$STATE/$ID.status"
  CONFIG="$(dirname "$STATE")/config"
  LOCKED=0
  TOOL=unknown
  COMMAND_SHA=-
  COMMAND_BYTES=0
  REQUEST_HASH=-
  REQUEST_FULL_HASH=-
  SCAN_TEXT=
  SCAN_OK=0
}

# Read the tool name and the two request hashes from a hook payload. The full
# hash covers the tool name and the whole tool input, and names a request
# under the owner-reserved key, so only a finished call with that same input
# closes such a row: the reserved scan reads every field, the description
# among them. The other hash names a request under the ordinary key. For Bash
# it covers the command and every other input field except the description,
# the timeout, and the background flag, so a changed description still names
# one request there, and a sandbox escape or a field this route does not know
# names another. A payload that cannot be read, or that names no tool, has
# the hash `-` for both, which no finished tool call ever matches.
bind_request() {  # <payload>
  local canon
  TOOL=$(printf '%s' "$1" | jq -r '.tool_name // "" | tostring' 2>/dev/null | tr -cd 'A-Za-z0-9_.-' | cut -c1-64)
  [ -n "$TOOL" ] || TOOL=unknown
  REQUEST_HASH=-
  if canon=$(printf '%s' "$1" | jq -cS '
      if (.tool_name | type) != "string" or .tool_name == "" then error("no tool name")
      elif .tool_name == "Bash" and (.tool_input.command | type) == "string"
      then ["Bash", .tool_input.command, (.tool_input | del(.command, .description, .timeout, .run_in_background))]
      else [.tool_name, .tool_input] end' 2>/dev/null) && [ -n "$canon" ]; then
    REQUEST_HASH=$(printf '%s' "$canon" | sha256_stdin)
    [ -n "$REQUEST_HASH" ] || REQUEST_HASH=-
  fi
  REQUEST_FULL_HASH=-
  if [ "$REQUEST_HASH" != - ] && canon=$(printf '%s' "$1" | jq -cS '[.tool_name, .tool_input]' 2>/dev/null) \
    && [ -n "$canon" ]; then
    REQUEST_FULL_HASH=$(printf '%s' "$canon" | sha256_stdin)
    [ -n "$REQUEST_FULL_HASH" ] || REQUEST_FULL_HASH=-
  fi
  # The tool name, every key path of the tool input, and every scalar under
  # it, decoded, for the reserved scan that picks the status key. The tool
  # name is given a second time with each run of `_` as a space, so a listed
  # word inside `mcp__server__some_tool` is read as a word. A false or null
  # value still gives its key path. An input that cannot be read whole, an
  # empty payload among them, leaves SCAN_OK at 0.
  SCAN_OK=0
  if SCAN_TEXT=$(printf '%s' "$1" | jq -rs '
      if length != 1 then error("not one value") else .[0] end
      | if (.tool_input | type) == "object"
      then [(.tool_name | tostring), (.tool_name | tostring | split("_") | map(select(. != "")) | join(" ")),
            (.tool_input | paths as $p | ($p | map(tostring) | join(".")),
             (getpath($p) | if type == "object" or type == "array" then empty else tostring end))] | join("\n")
      else error("no tool input") end' 2>/dev/null) \
    && [ "${#SCAN_TEXT}" -le "$(int_or "${FM_PERMISSION_ROUTE_MAX_BYTES:-}" 65536)" ]; then
    SCAN_OK=1
  fi
}

claude_request() {  # <state-dir> <id>
  local payload event mode keys_ok command verdict max kind harness approval
  [ "${AK_LIFECYCLE_POLICY:-}" = unattended ] || return 0
  bind_task "$@" || return 0
  payload=$(cat) || payload=
  command -v jq >/dev/null 2>&1 || { hold record; return 0; }
  bind_request "$payload"
  command=$(printf '%s' "$payload" | jq -r 'if (.tool_input.command | type) == "string" then .tool_input.command else "" end' 2>/dev/null) || command=
  COMMAND_SHA=$(printf '%s' "$command" | sha256_stdin)
  [ -n "$COMMAND_SHA" ] || COMMAND_SHA=-
  COMMAND_BYTES=${#command}

  kind=$(meta_value "$META" kind)
  harness=$(meta_value "$META" harness)
  approval=$(meta_value "$META" approval_mode)
  event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)
  mode=$(printf '%s' "$payload" | jq -r '.permission_mode // ""' 2>/dev/null)
  case "$kind" in ship | scout) ;; *) hold posture; return 0 ;; esac
  case "$harness" in claude*) ;; *) hold posture; return 0 ;; esac
  if [ "$approval" != bypass ] || [ "$event" != PermissionRequest ] || [ "$mode" != bypassPermissions ]; then
    hold posture; return 0
  fi
  [ "$TOOL" = Bash ] || { hold tool; return 0; }
  keys_ok=$(printf '%s' "$payload" | jq -r '
    (.tool_input | type) == "object"
    and ((.tool_input | keys) - ["command", "description", "timeout", "run_in_background"] | length) == 0' 2>/dev/null)
  [ "$keys_ok" = true ] || { hold input; return 0; }

  verdict=$(classify_command "$command")
  if [ "$verdict" != refuse ]; then
    verdict=${verdict#hold }
    hold "${verdict:-record}"; return 0
  fi
  max=$(int_or "${FM_PERMISSION_ROUTE_MAX_REFUSALS:-}" 5)
  lock_acquire || { hold record nolock; return 0; }
  verdict=$(awk -F '\t' -v sha="$COMMAND_SHA" -v max="$max" '
    $2 == "refuse" { n++; if ($5 == sha) again = 1 }
    END { if (again) print "repeat"; else if (n + 0 >= max + 0) print "ceiling"; else print "refuse" }' "$LEDGER" 2>/dev/null) || verdict=refuse
  if [ "$verdict" = refuse ] && ledger_row refuse class; then
    lock_release
    jq -cn --arg message "$FM_PERMISSION_ROUTE_MESSAGE" \
      '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $message}}}' >&3 2>/dev/null
    return 0
  fi
  lock_release
  [ "$verdict" != refuse ] || verdict=record
  hold "$verdict"
}

claude_settled() {  # <state-dir> <id> <event>
  local event=${3:-} payload key hash newest quiet
  bind_task "${1:-}" "${2:-}" || return 0
  [ -e "$MARKER" ] || return 0
  case "$event" in
    session-end)
      # The session is over, so nothing it asked can still wait: each key
      # with an open request closes, and the set goes with the session.
      lock_acquire || true
      marker_read || true
      for key in "$FM_PERMISSION_ROUTE_HELD_KEY" "$FM_PERMISSION_ROUTE_HARDSTOP_KEY"; do
        if [ "$(held_rows "$key")" -gt 0 ] && key_open "$key"; then
          status_append "resolved [at=$(date +%s)] [key=$key]: permission prompt no longer waiting: the session ended" || true
        fi
      done
      rm -f -- "$MARKER" 2>/dev/null || true
      ;;
    pane-clear)
      # The caller proved an empty composer with no prompt on the worker pane.
      # The owner-reserved key is never closed from the pane: only requests
      # another writer already resolved are ended. The prune reads the set
      # again, so it runs first: the quiet period is checked on the read whose
      # rows the close ends, and a request held after that read stays held.
      quiet=$(int_or "${FM_PERMISSION_ROUTE_PANE_CLEAR_SECS:-}" 15)
      marker_read && [ -n "$HELD" ] || return 0
      lock_acquire || return 0
      if marker_read; then
        marker_prune
        newest=$(printf '%s\n' "$HELD" | awk -F '\t' '$3 + 0 > n { n = $3 + 0 } END { print n + 0 }')
        if [ "$(( $(date +%s) - $(int_or "$newest" 0) ))" -ge "$quiet" ]; then
          pause_at pane-clear-close
          close_key "$FM_PERMISSION_ROUTE_HELD_KEY" 'the worker pane shows an empty composer and no permission prompt'
        fi
      fi
      ;;
    tool-finished)
      # The set outlives its last request, so most finished calls end here.
      marker_read && [ -n "$HELD" ] || return 0
      payload=$(cat) || payload=
      bind_request "$payload"
      [ "$REQUEST_HASH" != - ] || return 0
      lock_acquire || return 0
      for key in "$FM_PERMISSION_ROUTE_HELD_KEY" "$FM_PERMISSION_ROUTE_HARDSTOP_KEY"; do
        hash=$REQUEST_HASH
        [ "$key" != "$FM_PERMISSION_ROUTE_HARDSTOP_KEY" ] || hash=$REQUEST_FULL_HASH
        marker_read || break
        [ "$hash" != - ] && [ "$(held_rows "$key" "$hash")" -gt 0 ] || continue
        marker_end "$key" "$hash"
        settle_key "$key" 'the held request was answered and finished'
      done
      ;;
    *) return 0 ;;
  esac
  lock_release
}

# The keys this route still holds open, one per row, for the watchdog.
held_keys() {  # <state-dir> <id>
  local key open
  # A task that cannot be named, a held set or a status log that cannot be
  # read, or a status fold that cannot be loaded or run, exits non-zero, so
  # the caller never reads it as no hold.
  bind_task "${1:-}" "${2:-}" || return 1
  [ -s "$MARKER" ] || return 0
  [ -r "$MARKER" ] && marker_read || return 1
  [ -n "$HELD" ] || return 0
  [ -f "$STATUS" ] && [ ! -L "$STATUS" ] && [ -r "$STATUS" ] || return 1
  if ! command -v status_open_decisions >/dev/null 2>&1; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  fi
  open=$(status_open_decisions "$STATUS" 2>/dev/null) || return 1
  open=$(printf '%s\n' "$open" | cut -f1)
  for key in "$FM_PERMISSION_ROUTE_HARDSTOP_KEY" "$FM_PERMISSION_ROUTE_HELD_KEY"; do
    if [ "$(held_rows "$key")" -gt 0 ] && printf '%s\n' "$open" | grep -qx "$key"; then
      printf '%s\n' "$key"
    fi
  done
  return 0
}

main() {
  case "${1:-}" in
    claude-request)
      shift
      exec 3>&1 >/dev/null 2>&1
      claude_request "$@" || true
      ;;
    claude-settled)
      shift
      exec >/dev/null 2>&1
      claude_settled "$@" || true
      ;;
    held-keys)
      shift
      held_keys "$@" 2>/dev/null || return 1
      ;;
    classify) classify_command "$(cat)"; printf '\n' ;;
    -h | --help) usage ;;
    *) usage >&2; return 2 ;;
  esac
  return 0
}

main "$@"
