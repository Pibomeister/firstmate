#!/usr/bin/env bash
# fm-afk-preallow.sh - the one owner of the away-mode pre-allow list: the
# candidate list derived from recorded permission dialogs, the owner's
# approval record bound to that exact list, and the one reader that returns
# approved entries.
#
# Nothing is pre-allowed until the owner approves one exact list. `derive` and
# `page` only write a candidate and its review page; they change no worker.
# `approved` is the only way an entry leaves this script, and it prints
# nothing unless the approval record names the checksum of the list on disk.
#
#   fm-afk-preallow.sh derive [--ledger <actions.tsv>]
#       Reads the watchdog action ledger (bin/fm-watchdog-lib.sh owns its
#       rows; default state/watchdog/actions.tsv) and writes, under
#       state/afk-preallow/:
#         candidate.list   one entry per line, sorted; the bytes that are hashed
#         candidate.tsv    entry, count, first epoch, last epoch, sources, command
#         excluded.tsv     reason, count, first epoch, last epoch, sources, sample
#       Prints `sha256=<hash> entries=<n> excluded=<n>`.
#   fm-afk-preallow.sh page --out <file.html>
#       Writes the owner's review page for the current candidate.
#   fm-afk-preallow.sh approve --sha256 <hash> --ref <text>
#       Records the owner's approval. Refuses unless <hash> is the checksum of
#       the current candidate.list, the list is not empty, and every entry is
#       valid. Copies the list to config/afk-preallow.list and writes
#       config/afk-preallow.approval (version, sha256, approved_epoch, ref).
#       Only the owner's own approval of the page showing that hash
#       authorizes running this; <ref> names where that approval is recorded.
#   fm-afk-preallow.sh approved
#       Prints the approved entries, one per line, and exits 0. Exits 1 and
#       prints nothing when no approval record or no list exists. Exits 3,
#       prints nothing on stdout, and names the reason on stderr when the
#       record does not match the list or any entry is invalid.
#   fm-afk-preallow.sh revoke
#       Removes the approval record, so `approved` prints nothing again.
#   fm-afk-preallow.sh status
#       Prints the candidate and approval state.
#
# SOURCE ROWS. A ledger row counts when its symptom is `dialog`, its action is
# `page`, its phase is `pending` or `dry-run`, and its detail carries
# `permission: <dialog text>`. The watchdog writes that row for a permission
# dialog on an away session, shortens each dashed rule, and cuts the text at
# 300 characters.
#
# ENTRIES. An entry is `Bash(<command>)`: the exact command of a recorded
# Claude Bash prompt, which Claude Code matches as that command only. There
# is no prefix or wildcard entry. A row gives no entry, and is listed in
# excluded.tsv with its reason, when its text was withheld, it is not a Bash
# command prompt, its command was cut off, the command names a hard-stop
# category (fm_pp_hardstop_category in bin/fm-permission-prompt.sh), looks
# like a secret, or holds a character outside the plain set (shell operators,
# substitutions, parentheses, backslashes, `*`, or control characters). The
# same checks run again in `approve` and in every `approved` read, so a list
# edited by hand never passes a destructive, credential, sign-in, spend,
# release, or reserved command, whatever the approval record says.
#
# CONSUMER. bin/fm-spawn.sh adds the approved entries to a Claude ship or
# scout worker's own settings as `permissions.allow`, only for a worker
# launched while a valid away record is in force. A failed `approved` read
# changes nothing.
#
# Exit status: 0 success, 1 nothing approved, 2 usage error, 3 refused.
set -u

FM_PREALLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_PREALLOW_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_PREALLOW_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_PREALLOW_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_PREALLOW_WORK="$FM_PREALLOW_STATE/afk-preallow"
FM_PREALLOW_LIST="$FM_PREALLOW_CONFIG/afk-preallow.list"
FM_PREALLOW_APPROVAL="$FM_PREALLOW_CONFIG/afk-preallow.approval"
FM_PREALLOW_MAX_COMMAND=300

# shellcheck source=bin/fm-permission-prompt.sh
. "$FM_PREALLOW_DIR/fm-permission-prompt.sh"

fm_preallow_die() { printf 'fm-afk-preallow: %s\n' "$*" >&2; exit "${FM_PREALLOW_DIE_CODE:-3}"; }
fm_preallow_usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

fm_preallow_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# fm_preallow_command_reason <command>: prints why a command gives no entry.
# Exit 1 (and no output) when the command is acceptable.
fm_preallow_command_reason() {
  local cmd=$1 cat
  if [ -z "$cmd" ]; then printf 'the command is empty\n'; return 0; fi
  if [ "${#cmd}" -gt "$FM_PREALLOW_MAX_COMMAND" ]; then printf 'the command is too long\n'; return 0; fi
  if fm_secret_like "$cmd"; then printf 'the command looks like a secret\n'; return 0; fi
  if cat=$(fm_pp_hardstop_category "$cmd"); then printf 'the command names a hard-stop category: %s\n' "$cat"; return 0; fi
  if printf '%s' "$cmd" | LC_ALL=C grep -q '[^A-Za-z0-9 _./:=,@%+~"'"'"'-]'; then
    printf 'the command holds a shell operator or another character outside the plain set\n'
    return 0
  fi
  return 1
}

# fm_preallow_entry_ok <entry>: 0 when the entry is one valid `Bash(<command>)`.
fm_preallow_entry_ok() {
  local entry=$1 cmd
  case "$entry" in 'Bash('*')') ;; *) return 1 ;; esac
  cmd=${entry#Bash\(}
  cmd=${cmd%\)}
  ! fm_preallow_command_reason "$cmd" >/dev/null
}

# fm_preallow_rows <ledger>: one line per source row,
# `<kind>\t<epoch>\t<source>\t<text>`, where kind is `bash` (text is the
# command) or `skip` (text is `<reason>\t<sample>`).
fm_preallow_rows() {
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F'\t' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/[ \t]+/, " ", s); return s }
    $5 == "dialog" && $6 == "page" && ($7 == "pending" || $7 == "dry-run") {
      at = index($8, "permission: ")
      if (!at) next
      text = substr($8, at + 12)
      n = split($3, hp, "/")
      src = hp[n] "/" $4
      if (text ~ /^\[withheld/) { print "skip\t" $1 "\t" src "\tthe dialog text was withheld\t-"; next }
      seps = gsub(/(╌)+/, "\001", text)
      split(text, part, "\001")
      head = trim(part[1])
      if (head !~ /^Bash command/) { print "skip\t" $1 "\t" src "\tnot a Bash command prompt\t" substr(head, 1, 80); next }
      if (seps < 2) { print "skip\t" $1 "\t" src "\tthe command was cut off in the ledger\t" substr(trim(part[2]), 1, 80); next }
      print "bash\t" $1 "\t" src "\t" trim(part[2])
    }' "$1"
}

# fm_preallow_group: stdin `<key>\t<epoch>\t<source>\t<extra>` sorted by key;
# stdout `<key>\t<count>\t<first>\t<last>\t<sources>\t<extra>` per key.
fm_preallow_group() {
  LC_ALL=C awk -F'\t' '
    function flush() { if (key != "") print key "\t" c "\t" first "\t" last "\t" srcs "\t" extra }
    $1 != key { flush(); key = $1; c = 0; first = $2; last = $2; srcs = ""; extra = $4; split("", seen) }
    { c++; if ($2 < first) first = $2; if ($2 > last) last = $2
      if (!($3 in seen)) { seen[$3] = 1; srcs = srcs (srcs == "" ? "" : ", ") $3 } }
    END { flush() }'
}

fm_preallow_derive() {
  local ledger="$FM_PREALLOW_STATE/watchdog/actions.tsv" tmp kind epoch src text reason sample
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) [ $# -ge 2 ] || FM_PREALLOW_DIE_CODE=2 fm_preallow_die "--ledger needs a path"; ledger=$2; shift 2 ;;
      *) FM_PREALLOW_DIE_CODE=2 fm_preallow_die "unknown derive argument: $1" ;;
    esac
  done
  [ -f "$ledger" ] || fm_preallow_die "no ledger at $ledger"
  mkdir -p "$FM_PREALLOW_WORK" || fm_preallow_die "cannot create $FM_PREALLOW_WORK"
  tmp=$(mktemp -d "$FM_PREALLOW_WORK/.derive.XXXXXX") || fm_preallow_die "cannot create a work directory"
  if ! { : > "$tmp/ok" && : > "$tmp/skip"; }; then rm -rf "$tmp"; fm_preallow_die "cannot write under $FM_PREALLOW_WORK"; fi
  while IFS=$'\t' read -r kind epoch src text sample; do
    if [ "$kind" = bash ]; then
      if reason=$(fm_preallow_command_reason "$text"); then
        # A hard-stop or secret-like command is never copied into the report.
        printf '%s\t%s\t%s\t%s\n' "$reason" "$epoch" "$src" "[not shown]" >> "$tmp/skip"
      else
        printf 'Bash(%s)\t%s\t%s\t%s\n' "$text" "$epoch" "$src" "$text" >> "$tmp/ok"
      fi
    else
      if fm_secret_like "$sample" || fm_pp_hardstop_category "$sample" >/dev/null; then sample='[not shown]'; fi
      printf '%s\t%s\t%s\t%s\n' "$text" "$epoch" "$src" "$sample" >> "$tmp/skip"
    fi
  done < <(fm_preallow_rows "$ledger")
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -s "$tmp/ok" | fm_preallow_group > "$tmp/candidate.tsv"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -s "$tmp/skip" | fm_preallow_group > "$tmp/excluded.tsv"
  cut -f1 "$tmp/candidate.tsv" > "$tmp/candidate.list"
  printf '%s\n' "$ledger" > "$tmp/source"
  mv "$tmp/candidate.tsv" "$tmp/excluded.tsv" "$tmp/candidate.list" "$tmp/source" "$FM_PREALLOW_WORK/" \
    || { rm -rf "$tmp"; fm_preallow_die "cannot write the candidate under $FM_PREALLOW_WORK"; }
  rm -rf "$tmp"
  printf 'sha256=%s entries=%s excluded=%s\n' "$(fm_preallow_sha256 "$FM_PREALLOW_WORK/candidate.list")" \
    "$(wc -l < "$FM_PREALLOW_WORK/candidate.list" | tr -d ' ')" \
    "$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$FM_PREALLOW_WORK/excluded.tsv")"
}

# fm_preallow_checked_list <list-file>: prints the entries when the file is a
# non-empty list of valid entries; otherwise names the first problem on stderr
# and returns 3.
fm_preallow_checked_list() {
  local f=$1 entry n=0
  [ -s "$f" ] || { printf 'fm-afk-preallow: the list at %s is empty or missing\n' "$f" >&2; return 3; }
  while IFS= read -r entry || [ -n "$entry" ]; do
    n=$((n + 1))
    fm_preallow_entry_ok "$entry" || { printf 'fm-afk-preallow: line %s of %s is not a valid entry\n' "$n" "$f" >&2; return 3; }
  done < "$f"
  cat "$f"
}

fm_preallow_approval_field() {  # <field>
  sed -n "s/^$1: //p" "$FM_PREALLOW_APPROVAL" 2>/dev/null | head -n 1
}

fm_preallow_approve() {
  local want='' ref='' have tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha256) [ $# -ge 2 ] || FM_PREALLOW_DIE_CODE=2 fm_preallow_die "--sha256 needs a hash"; want=$2; shift 2 ;;
      --ref) [ $# -ge 2 ] || FM_PREALLOW_DIE_CODE=2 fm_preallow_die "--ref needs text"; ref=$2; shift 2 ;;
      *) FM_PREALLOW_DIE_CODE=2 fm_preallow_die "unknown approve argument: $1" ;;
    esac
  done
  [ -n "$want" ] && [ -n "$ref" ] || FM_PREALLOW_DIE_CODE=2 fm_preallow_die "approve needs --sha256 <hash> and --ref <text>"
  case "$ref" in *$'\n'*) FM_PREALLOW_DIE_CODE=2 fm_preallow_die "--ref must be one line" ;; esac
  fm_preallow_checked_list "$FM_PREALLOW_WORK/candidate.list" >/dev/null || exit 3
  have=$(fm_preallow_sha256 "$FM_PREALLOW_WORK/candidate.list") || fm_preallow_die "no sha256 tool"
  [ "$have" = "$want" ] || fm_preallow_die "the candidate list is $have, not the approved $want; nothing recorded"
  mkdir -p "$FM_PREALLOW_CONFIG" || fm_preallow_die "cannot create $FM_PREALLOW_CONFIG"
  # The record is removed first, so no moment pairs the new list with the old record.
  rm -f "$FM_PREALLOW_APPROVAL" || fm_preallow_die "cannot replace $FM_PREALLOW_APPROVAL"
  tmp=$(mktemp "$FM_PREALLOW_CONFIG/.afk-preallow.XXXXXX") || fm_preallow_die "cannot write under $FM_PREALLOW_CONFIG"
  if ! { cat "$FM_PREALLOW_WORK/candidate.list" > "$tmp" && mv "$tmp" "$FM_PREALLOW_LIST"; }; then rm -f "$tmp"; fm_preallow_die "cannot write $FM_PREALLOW_LIST"; fi
  [ "$(fm_preallow_sha256 "$FM_PREALLOW_LIST")" = "$want" ] || fm_preallow_die "the written list does not match $want; nothing recorded"
  tmp=$(mktemp "$FM_PREALLOW_CONFIG/.afk-preallow.XXXXXX") || fm_preallow_die "cannot write under $FM_PREALLOW_CONFIG"
  if ! { printf 'version: 1\nsha256: %s\napproved_epoch: %s\nref: %s\n' "$want" "$(date +%s)" "$ref" > "$tmp" \
    && mv "$tmp" "$FM_PREALLOW_APPROVAL"; }; then rm -f "$tmp"; fm_preallow_die "cannot write $FM_PREALLOW_APPROVAL"; fi
  printf 'approved sha256=%s entries=%s\n' "$want" "$(wc -l < "$FM_PREALLOW_LIST" | tr -d ' ')"
}

fm_preallow_approved() {
  local want have out
  [ -f "$FM_PREALLOW_APPROVAL" ] && [ -f "$FM_PREALLOW_LIST" ] || return 1
  [ "$(fm_preallow_approval_field version)" = 1 ] || { printf 'fm-afk-preallow: the approval record has no known version\n' >&2; return 3; }
  want=$(fm_preallow_approval_field sha256)
  have=$(fm_preallow_sha256 "$FM_PREALLOW_LIST") || have=
  if [ -z "$want" ] || [ "$want" != "$have" ]; then
    printf 'fm-afk-preallow: the approval record does not match the list on disk; nothing is pre-allowed\n' >&2
    return 3
  fi
  out=$(fm_preallow_checked_list "$FM_PREALLOW_LIST") || return 3
  printf '%s\n' "$out"
}

fm_preallow_status() {
  local rc=0
  if [ -f "$FM_PREALLOW_WORK/candidate.list" ]; then
    printf 'candidate: sha256=%s entries=%s\n' "$(fm_preallow_sha256 "$FM_PREALLOW_WORK/candidate.list")" \
      "$(wc -l < "$FM_PREALLOW_WORK/candidate.list" | tr -d ' ')"
  else
    printf 'candidate: none derived\n'
  fi
  fm_preallow_approved >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'approval: in force, sha256=%s ref=%s\n' "$(fm_preallow_approval_field sha256)" "$(fm_preallow_approval_field ref)" ;;
    1) printf 'approval: none; nothing is pre-allowed\n' ;;
    *) printf 'approval: refused (the record does not match a valid list); nothing is pre-allowed\n' ;;
  esac
}

fm_preallow_html() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
fm_preallow_day() {  # <epoch>
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d 2>/dev/null || printf '%s' "$1"
}

# fm_preallow_table <tsv> <first-heading> <last-heading>: the rows of one table.
fm_preallow_table() {
  local key count first last srcs extra
  printf '<div class="scroll"><table><thead><tr><th>%s</th><th>Count</th><th>First seen</th><th>Last seen</th><th>Source</th>%s</tr></thead><tbody>\n' \
    "$2" "${3:+<th>$3</th>}"
  while IFS=$'\t' read -r key count first last srcs extra; do
    printf '<tr><td><code>%s</code></td><td class="num">%s</td><td>%s</td><td>%s</td><td>%s</td>' \
      "$(printf '%s' "$key" | fm_preallow_html)" "$count" "$(fm_preallow_day "$first")" "$(fm_preallow_day "$last")" \
      "$(printf '%s' "$srcs" | fm_preallow_html)"
    [ -z "${3:-}" ] || printf '<td><code>%s</code></td>' "$(printf '%s' "$extra" | fm_preallow_html)"
    printf '</tr>\n'
  done < "$1"
  printf '</tbody></table></div>\n'
}

fm_preallow_page() {
  local out='' sha entries excluded rows ledger tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || FM_PREALLOW_DIE_CODE=2 fm_preallow_die "--out needs a file"; out=$2; shift 2 ;;
      *) FM_PREALLOW_DIE_CODE=2 fm_preallow_die "unknown page argument: $1" ;;
    esac
  done
  [ -n "$out" ] || FM_PREALLOW_DIE_CODE=2 fm_preallow_die "page needs --out <file.html>"
  [ -f "$FM_PREALLOW_WORK/candidate.list" ] || fm_preallow_die "no candidate; run derive first"
  sha=$(fm_preallow_sha256 "$FM_PREALLOW_WORK/candidate.list") || fm_preallow_die "no sha256 tool"
  entries=$(wc -l < "$FM_PREALLOW_WORK/candidate.list" | tr -d ' ')
  excluded=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$FM_PREALLOW_WORK/excluded.tsv")
  rows=$((excluded + $(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$FM_PREALLOW_WORK/candidate.tsv")))
  ledger=$(cat "$FM_PREALLOW_WORK/source" 2>/dev/null) || ledger=
  tmp=$(mktemp "$out.XXXXXX") || fm_preallow_die "cannot write $out"
  {
    cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Away-mode pre-allow list</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&family=JetBrains+Mono:wght@400&family=Source+Serif+4:wght@600&display=swap" rel="stylesheet">
<style>
:root { --page: #FAF9F5; --surface: #F0EEE6; --border: #E8E6DC; --text: #141413; --muted: #5E5D59; --accent: #D97757; }
@media (prefers-color-scheme: dark) {
  :root { --page: #1F1E1D; --surface: #262624; --border: #3D3D3A; --text: #FAF9F5; --muted: #B7B5A9; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--text); font: 16px/1.6 Inter, system-ui, sans-serif; }
main { max-width: 960px; margin: 0 auto; padding: 48px 16px 64px; }
h1, h2 { font-family: "Source Serif 4", Georgia, serif; font-weight: 600; line-height: 1.25; margin: 0 0 16px; text-wrap: balance; }
h1 { font-size: 34px; }
h2 { font-size: 24px; margin-top: 56px; }
p, li { max-width: 68ch; }
p { margin: 0 0 16px; }
.eyebrow { color: var(--muted); font-size: 14px; letter-spacing: 0.04em; text-transform: uppercase; margin-bottom: 8px; }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 24px; margin: 24px 0; }
.card.key { border-left: 4px solid var(--accent); }
.card p:last-child { margin-bottom: 0; }
.muted { color: var(--muted); }
code { font: 14px/1.5 "JetBrains Mono", ui-monospace, monospace; overflow-wrap: anywhere; }
pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 14px/1.5 "JetBrains Mono", ui-monospace, monospace; }
.scroll { overflow-x: auto; border: 1px solid var(--border); border-radius: 12px; }
table { border-collapse: collapse; width: 100%; font-size: 15px; }
th, td { text-align: left; vertical-align: top; padding: 12px 16px; border-bottom: 1px solid var(--border); }
th { background: var(--surface); font-weight: 600; white-space: nowrap; }
tr:last-child td { border-bottom: 0; }
.num { font-variant-numeric: tabular-nums; }
.facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin: 24px 0; }
.fact { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 16px 24px; }
.fact b { display: block; font: 600 28px/1.2 "Source Serif 4", Georgia, serif; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
<main>
<div class="eyebrow">Firstmate - decision page</div>
<h1>Away-mode pre-allow list</h1>
HTML
    printf '<div class="card key"><p><b>TL;DR.</b> You chose to build the away-mode pre-allow list from past permission dialogs and to approve it once. This page is that list, built from the recorded dialogs. '
    if [ "$entries" -gt 0 ]; then
      printf 'It holds %s exact command(s). <b>Decision requested:</b> approve this exact list, or reject it. Nothing is pre-allowed until you approve, and your approval covers only the list with the checksum shown below.</p></div>\n' "$entries"
    else
      printf 'The list is empty: the record holds no permission dialog that can become an entry. <b>No decision is required.</b> Nothing is pre-allowed, and an empty list cannot be approved.</p></div>\n'
    fi
    printf '<div class="facts"><div class="fact"><b>%s</b>entries on the list</div><div class="fact"><b>%s</b>recorded permission dialogs read</div><div class="fact"><b>%s</b>dialogs left off the list</div></div>\n' \
      "$entries" "$rows" "$excluded"
    printf '<h2>What approval does</h2>\n<ul>\n'
    printf '<li>Each entry is one exact command. A worker may run that command, and only that command, without a prompt.</li>\n'
    printf '<li>It applies to Claude ship and scout workers started while you are away. It does not change a session that is already running, and it does not change your own session.</li>\n'
    printf '<li>Commands that delete, release, spend, sign in, or touch credentials are never put on the list, and are refused even if someone adds one by hand.</li>\n'
    printf '<li>If the list changes by one byte after you approve, the approval stops counting and nothing is pre-allowed.</li>\n</ul>\n'
    printf '<h2>The list</h2>\n'
    if [ "$entries" -gt 0 ]; then
      fm_preallow_table "$FM_PREALLOW_WORK/candidate.tsv" Entry
    else
      printf '<div class="card"><p>No entries.</p></div>\n'
    fi
    printf '<h2>Left off the list</h2>\n'
    if [ -s "$FM_PREALLOW_WORK/excluded.tsv" ]; then
      printf '<p>These recorded dialogs gave no entry. Each row shows the reason.</p>\n'
      fm_preallow_table "$FM_PREALLOW_WORK/excluded.tsv" Reason Sample
    else
      printf '<div class="card"><p>No recorded dialog was left off.</p></div>\n'
    fi
    printf '<h2>Record</h2>\n<div class="card"><p class="muted">Source ledger</p><pre>%s</pre></div>\n' "$(printf '%s' "$ledger" | fm_preallow_html)"
    printf '<div class="card"><p class="muted">List checksum (sha256)</p><pre>%s</pre></div>\n' "$sha"
    if [ "$entries" -gt 0 ]; then
      printf '<div class="card"><p class="muted">Command that records your approval, run only after you approve</p><pre>bin/fm-afk-preallow.sh approve --sha256 %s --ref "&lt;where the approval is recorded&gt;"</pre></div>\n' "$sha"
    fi
    printf '</main>\n</body>\n</html>\n'
  } > "$tmp" || { rm -f "$tmp"; fm_preallow_die "cannot write $out"; }
  mv "$tmp" "$out" || { rm -f "$tmp"; fm_preallow_die "cannot write $out"; }
  printf 'page=%s sha256=%s entries=%s\n' "$out" "$sha" "$entries"
}

fm_preallow_main() {
  local cmd=${1:-}
  [ $# -eq 0 ] || shift
  case "$cmd" in
    derive) fm_preallow_derive "$@" ;;
    page) fm_preallow_page "$@" ;;
    approve) fm_preallow_approve "$@" ;;
    approved) fm_preallow_approved ;;
    revoke) rm -f "$FM_PREALLOW_APPROVAL" || fm_preallow_die "cannot remove $FM_PREALLOW_APPROVAL"; printf 'approval removed; nothing is pre-allowed\n' ;;
    status) fm_preallow_status ;;
    -h | --help | help) fm_preallow_usage ;;
    *) fm_preallow_usage >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_preallow_main "$@"
fi
