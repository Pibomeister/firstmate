#!/usr/bin/env bash
# fm-ready-pr-discovery.sh - read-only discovery of no-mistakes runs parked
# with a PR ready, across every project registered in this home.
#
# Usage:
#   fm-ready-pr-discovery.sh [--json|--compact]
#
# On each heartbeat the supervisor needs to see validation runs that finished
# their substantive work and now wait only on a human merge or gate decision,
# including runs no firstmate task ever owned (for example a direct session in
# a project's own checkout). This script enumerates, for every name in
# data/projects.md that has a local clone under projects/, the live runs in
# that clone's no-mistakes gate and reports the ones parked at the ci step
# with a PR ready ("PR ready, monitoring") or parked at an approval gate.
#
# It reuses only the read-only no-mistakes axi listing/status/log interfaces
# (bin/fm-nm-run-lib.sh's bounded checked calls). It never merges, marks a PR
# ready, responds to a run, or changes any project; merging stays with the
# existing guarded merge path and each repo's registered posture.
#
# Output (compact, the default): one line per discovered run, plus one line
# per unreadable repo, so a heartbeat or decision batch can consume it as-is:
#   ready-pr: repo=<name> branch=<branch> pr=<url|-> head=<sha> waited=<dur> owned=<yes|no> kind=<ci-ready|gate> gate=<step|-> run=<id>
#   ready-pr-unreadable: repo=<name> reason=<text>
# With --json it prints one object:
#   {schema:"fm-ready-pr-discovery.v1",generated_epoch,runs[],unreadable[],warnings[]}
#   runs[]: {repo,gate_repo,branch,pr,head,run_id,kind,gate,waited_seconds,owned,owner_task}
# A repo whose gate cannot be read is reported in unreadable[], never skipped
# silently. Owned means a state/<id>.meta record names the run's branch (or
# its PR URL); anything else is flagged owned=no (an orphan).
#
# FM_READY_PR_NOW (epoch seconds) and FM_READY_PR_NM_TIMEOUT (per-call bound,
# default 5) exist for tests. FM_HOME and the FM_*_OVERRIDE variables select
# the home exactly as in bin/fm-heartbeat.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
NM_TIMEOUT=${FM_READY_PR_NM_TIMEOUT:-5}
case "$NM_TIMEOUT" in ''|*[!0-9]*|0) NM_TIMEOUT=5 ;; esac
NOW=${FM_READY_PR_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

MODE=compact
case "${1:-}" in
  '') ;;
  --json) MODE=json ;;
  --compact) MODE=compact ;;
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'fm-ready-pr-discovery: too many arguments' >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo 'fm-ready-pr-discovery: jq is required' >&2; exit 1; }

# shellcheck source=bin/fm-nm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-ready-pr-discovery.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/runs.jsonl"
: > "$WORK/unreadable.jsonl"
: > "$WORK/warnings"

note_warning() { printf '%s\n' "$1" >> "$WORK/warnings"; }

# Registered project names, one per line, in registry order.
registry_names() {
  [ -f "$DATA/projects.md" ] || return 0
  awk '
    /^- / {
      line = substr($0, 3)
      idx = index(line, " [")
      if (idx > 0) { print substr(line, 1, idx - 1); next }
      idx = index(line, " - ")
      if (idx > 0) { print substr(line, 1, idx - 1); next }
      print line
    }' "$DATA/projects.md"
}

# Live (pending/running) overview rows as TSV: id, branch, status, head, pr.
overview_live_rows() {  # <overview-toon>
  printf '%s\n' "$1" | awk '
    function scalar(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); if (s ~ /^".*"[ \t]*$/) { sub(/^"/, "", s); sub(/"[ \t]*$/, "", s) } return s }
    function row_fields(s, f,    i, ch, n, quoted, escaped) {
      for (i in f) delete f[i]
      n = 1; f[n] = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (escaped) { f[n] = f[n] ch; escaped = 0 }
        else if (quoted && ch == "\\") escaped = 1
        else if (ch == "\"") quoted = !quoted
        else if (!quoted && ch == ",") { n++; f[n] = "" }
        else f[n] = f[n] ch
      }
      for (i = 1; i <= n; i++) f[i] = scalar(f[i])
      return n
    }
    /^runs\[[0-9]+\]\{id,branch,status,head,pr\}:$/ { inrows = 1; next }
    inrows && /^[ \t]+/ {
      n = row_fields($0, f)
      if (n == 5 && (f[3] == "running" || f[3] == "pending")) printf "%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4], f[5]
      next
    }
    inrows { inrows = 0 }
  '
}

# Creation epoch decoded from a ULID run id (first 10 Crockford base32 chars
# are a millisecond timestamp). Prints nothing for a non-ULID id.
ulid_epoch() {  # <run-id>
  local id=${1:0:10} value=0 i ch digit
  [ "${#id}" -eq 10 ] || return 0
  for ((i = 0; i < 10; i++)); do
    ch=${id:i:1}
    case "$ch" in
      [0-9]) digit=$ch ;;
      A) digit=10 ;; B) digit=11 ;; C) digit=12 ;; D) digit=13 ;; E) digit=14 ;;
      F) digit=15 ;; G) digit=16 ;; H) digit=17 ;; J) digit=18 ;; K) digit=19 ;;
      M) digit=20 ;; N) digit=21 ;; P) digit=22 ;; Q) digit=23 ;; R) digit=24 ;;
      S) digit=25 ;; T) digit=26 ;; V) digit=27 ;; W) digit=28 ;; X) digit=29 ;;
      Y) digit=30 ;; Z) digit=31 ;;
      *) return 0 ;;
    esac
    value=$((value * 32 + digit))
  done
  printf '%s\n' $((value / 1000))
}

# Owning task id for a branch/PR from state/*.meta, or empty.
owner_for() {  # <branch> <pr>
  local branch=$1 pr=$2 meta b p
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    b=$(sed -n 's/^branch=//p' "$meta" | head -1)
    if [ -n "$branch" ] && [ "$b" = "$branch" ]; then basename "$meta" .meta; return 0; fi
    if [ -n "$pr" ]; then
      p=$(sed -n 's/^pr=//p' "$meta" | head -1)
      [ "$p" = "$pr" ] && { basename "$meta" .meta; return 0; }
    fi
  done
  return 0
}

# ci log verdict for a run: ready when the most recent recognized marker says
# the monitor is only waiting for merge/close; not-ready while checks run.
ci_log_state() {  # <clone> <run-id>
  local log marker
  log=$(fm_nm_run_checked "$1" "$NM_TIMEOUT" axi logs --step ci --run "$2" --full 2>/dev/null) || log=''
  [ -n "$log" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log" \
    | grep -E 'still monitoring until merged or closed|no CI checks reported yet|checks failed|issues detected|CI checks running' \
    | tail -1)
  case "$marker" in
    *'still monitoring until merged or closed'*) printf 'ready' ;;
    *'no CI checks reported yet'*|*'checks failed'*|*'issues detected'*|*'CI checks running'*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}

discover_repo() {  # <name>
  local name=$1 clone=$PROJECTS/$1 overview rc=0 rows row id branch status head pr
  local detail kind gate run_head run_pr created waited owner gate_repo count_line shown total
  if [ ! -d "$clone" ]; then
    jq -nc --arg repo "$name" --arg reason "no local clone at $clone" \
      '{repo:$repo,reason:$reason}' >> "$WORK/unreadable.jsonl"
    return 0
  fi
  overview=$(fm_nm_run_checked "$clone" "$NM_TIMEOUT" axi </dev/null) || rc=$?
  if [ "$(fm_nm_strip_quotes "$(fm_nm_field "$overview" error)")" = "repo not initialized (run 'no-mistakes init' first)" ]; then
    jq -nc --arg repo "$name" --arg reason "repo has no no-mistakes gate (not initialized)" \
      '{repo:$repo,reason:$reason}' >> "$WORK/unreadable.jsonl"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "$overview" ]; then
    jq -nc --arg repo "$name" --arg reason "no-mistakes gate unreadable (axi exit $rc)" \
      '{repo:$repo,reason:$reason}' >> "$WORK/unreadable.jsonl"
    return 0
  fi
  gate_repo=$(fm_nm_strip_quotes "$(fm_nm_field "$overview" repo)")
  count_line=$(fm_nm_field "$overview" count)
  shown=$(printf '%s' "$count_line" | awk '{print $1}'); total=$(printf '%s' "$count_line" | awk '{print $3}')
  case "$shown" in ''|*[!0-9]*) shown='' ;; esac
  case "$total" in ''|*[!0-9]*) total='' ;; esac
  if [ -n "$shown" ] && [ -n "$total" ] && [ "$shown" -lt "$total" ]; then
    note_warning "repo $name: run inventory truncated ($shown of $total shown); older live runs may be missed"
  fi
  rows=$(overview_live_rows "$overview")
  [ -n "$rows" ] || return 0
  while IFS="$(printf '\t')" read -r id branch status head pr; do
    [ -n "$id" ] || continue
    detail=$(fm_nm_run_checked "$clone" "$NM_TIMEOUT" axi status --run "$id" </dev/null) || detail=''
    if [ -z "$detail" ] || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$detail" id)")" != "$id" ]; then
      note_warning "repo $name: run $id unreadable"
      continue
    fi
    run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$detail" head)")
    [ -n "$run_head" ] || run_head=$head
    run_pr=$(fm_nm_strip_quotes "$(fm_nm_field "$detail" pr)")
    [ -n "$run_pr" ] || run_pr=$pr
    kind=''; gate=''
    if fm_nm_run_is_parked "$detail"; then
      kind=gate
      gate=$(fm_nm_table_column "$detail" active_steps step | head -1)
      [ -n "$gate" ] || gate=$(fm_nm_strip_quotes "$(printf '%s\n' "$detail" | sed -n 's/^[[:space:]]*step:[[:space:]]*//p' | head -1)")
      [ -n "$gate" ] || gate=$(fm_nm_strip_quotes "$(fm_nm_field "$detail" status)")
      case "$gate" in running|pending|fixing|ci|'') gate=gate ;; esac
    elif [ -n "$run_pr" ]; then
      # A live run whose ci step is running/fixing with a PR is a candidate;
      # the ci log decides whether checks are done and only merge is awaited.
      if printf '%s\n' "$detail" | grep -Eq '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' \
        || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$detail" status)")" = ci ]; then
        [ "$(ci_log_state "$clone" "$id")" = not-ready ] && continue
        kind=ci-ready
      fi
    fi
    [ -n "$kind" ] || continue
    created=$(ulid_epoch "$id")
    waited=''
    if [ -n "$created" ]; then waited=$((NOW - created)); [ "$waited" -ge 0 ] || waited=0; fi
    owner=$(owner_for "$branch" "$run_pr")
    jq -nc --arg repo "$name" --arg gate_repo "$gate_repo" --arg branch "$branch" \
      --arg pr "$run_pr" --arg head "$run_head" --arg run_id "$id" --arg kind "$kind" \
      --arg gate "$gate" --arg waited "$waited" --arg owner "$owner" '
      {repo:$repo,gate_repo:(if $gate_repo == "" then null else $gate_repo end),
       branch:$branch,pr:(if $pr == "" then null else $pr end),head:$head,run_id:$run_id,
       kind:$kind,gate:(if $gate == "" then null else $gate end),
       waited_seconds:(if $waited == "" then null else ($waited | tonumber) end),
       owned:($owner != ""),owner_task:(if $owner == "" then null else $owner end)}' \
      >> "$WORK/runs.jsonl"
  done <<EOF
$rows
EOF
}

while IFS= read -r name; do
  [ -n "$name" ] || continue
  discover_repo "$name"
done <<EOF
$(registry_names)
EOF

if [ "$MODE" = json ]; then
  jq -n --argjson epoch "$NOW" --slurpfile runs "$WORK/runs.jsonl" \
    --slurpfile unreadable "$WORK/unreadable.jsonl" --rawfile warnings "$WORK/warnings" '
    {schema:"fm-ready-pr-discovery.v1",generated_epoch:$epoch,
     runs:$runs,unreadable:$unreadable,
     warnings:($warnings | split("\n") | map(select(. != "")))}'
else
  jq -r '
    def dur: if . == null then "unknown"
      elif . >= 86400 then "\(. / 86400 | floor)d\((. % 86400) / 3600 | floor)h"
      elif . >= 3600 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m"
      else "\(. / 60 | floor)m" end;
    "ready-pr: repo=\(.repo) branch=\(.branch) pr=\(.pr // "-") head=\(.head) waited=\(.waited_seconds | dur) owned=\(if .owned then "yes" else "no" end) kind=\(.kind) gate=\(.gate // "-") run=\(.run_id)"' \
    "$WORK/runs.jsonl"
  jq -r '"ready-pr-unreadable: repo=\(.repo) reason=\(.reason)"' "$WORK/unreadable.jsonl"
  while IFS= read -r warning; do
    [ -n "$warning" ] || continue
    printf 'ready-pr-warning: %s\n' "$warning"
  done < "$WORK/warnings"
fi
