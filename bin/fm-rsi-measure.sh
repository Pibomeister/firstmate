#!/usr/bin/env bash
# fm-rsi-measure.sh - read-only RSI loop measurement.
#
# Usage:
#   fm-rsi-measure.sh --input <json> --now <epoch> --window-start <iso> --window-end <iso>
#   fm-rsi-measure.sh --help
#
# This command never contacts a forge, lands a pull request, or writes a
# repository. The caller supplies one JSON object. docs/rsi/loop-1.md owns the
# baseline window and the summary figures. This header owns the calculation.
#
# --now is ten digits, the snapshot instant.
# --window-start is inclusive and --window-end is exclusive. Both are UTC
# ISO-8601 instants that fm_utc_iso_to_epoch accepts (bin/fm-classify-lib.sh).
# Start must be earlier than end.
#
# JSON:
#   merged: array of objects with repo, number, created_at, merged_at,
#     review_rounds, interventions_before_green, and reached_green.
#   open: array of objects with repo, number, created_at, is_draft,
#     failing_checks, pending_checks, changes_requested, reported_checks,
#     and conflict.
# repo is owner/name. number is a positive integer. Timestamps are UTC
# ISO-8601. Counts are integers at least 0, or null when unknown. Flags are
# true, false, or null. A null instrument field is missing, not zero.
# The same repo and number twice is a duplicate and is refused.
#
# Open-to-land duration is merged_at minus created_at, in hours, for merged
# rows whose merged_at is inside the window. The median is the middle value
# when the count is odd, and the mean of the two middle values when it is even.
# Aged open rows are open rows whose created_at is more than 24 hours before
# --now. The denominator is every open row.
#
# An aged open row's class is the first match: draft, failing-checks,
# changes-requested, conflict, pending-checks, green-waiting. pending-checks
# also covers a row whose reported_checks is 0. unexplained is used only when
# a class field is null, so a complete row is never unexplained.
#
# review_rounds median and max use in-window merged rows whose review_rounds
# is a number. intervention-free counts in-window merged rows with
# reached_green true and interventions_before_green 0. A true reached_green
# with a null intervention count is missing, and is neither free nor completed.
# A false reached_green is not completed and not missing.
#
# Prints, per repository, median, aged, review_rounds, intervention_free,
# then one class line per aged open row ordered by number. Hours use two
# decimals. Exit 0 on a reading, 2 on a usage or input refusal.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }

die() {
  printf 'fm-rsi-measure: %s\n' "$*" >&2
  exit 2
}

INPUT=
NOW=
WINDOW_START=
WINDOW_END=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT=${2:-}; shift ;;
    --now) NOW=${2:-}; shift ;;
    --window-start) WINDOW_START=${2:-}; shift ;;
    --window-end) WINDOW_END=${2:-}; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -n "$INPUT" ] && [ -n "$NOW" ] && [ -n "$WINDOW_START" ] && [ -n "$WINDOW_END" ] || die "usage: fm-rsi-measure.sh --input <json> --now <epoch> --window-start <iso> --window-end <iso>"
[ -f "$INPUT" ] || die "no such input: $INPUT"
case "$NOW" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) die "now must be a 10-digit epoch" ;;
esac
START_EPOCH=$(fm_utc_iso_to_epoch "$WINDOW_START") || die "window-start is not a UTC ISO-8601 instant"
END_EPOCH=$(fm_utc_iso_to_epoch "$WINDOW_END") || die "window-end is not a UTC ISO-8601 instant"
[ "$START_EPOCH" -lt "$END_EPOCH" ] || die "window-start must be earlier than window-end"
command -v jq >/dev/null 2>&1 || die "jq is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-rsi-measure.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# jq validates the object and emits one TSV row per pull request. halt_error's
# text is the refusal the caller sees. A null count or flag is the cell "-",
# never an empty field: tab is IFS whitespace, so consecutive empty cells
# would collapse, and a null must not be readable as zero. The names
# cell_count and cell_flag avoid jq's builtin count.
JQ_PROGRAM='
def repo_ok: type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$");
def number_ok: type == "number" and floor == . and . >= 1 and . <= 1000000000;
def stamp_ok: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$");
def count_ok: . == null or (type == "number" and floor == . and . >= 0 and . <= 1000000);
def flag_ok: . == null or type == "boolean";
def cell_count: if . == null then "-" else tostring end;
def cell_flag: if . == null then "-" elif . == true then "1" else "0" end;
def assert(ok; msg): if ok then . else (msg | halt_error(5)) end;
def ident: (.repo | tostring) + "#" + (.number | tostring);
if type != "object" then ("input must be an object" | halt_error(5)) else . end
| assert(has("merged") and (.merged | type == "array"); "merged must be an array")
| assert(has("open") and (.open | type == "array"); "open must be an array")
| if ([.merged[]?, .open[]?] | group_by(ident) | map(select(length > 1)) | length) > 0
  then ("duplicate pull request" | halt_error(5))
  else .
  end
| (
    .merged[]?
    | assert(.repo | repo_ok; "merged repo must be owner/name")
    | assert(.number | number_ok; "merged number must be a positive integer")
    | assert(.created_at | stamp_ok; "merged created_at must be UTC ISO-8601")
    | assert(.merged_at | stamp_ok; "merged merged_at must be UTC ISO-8601")
    | assert(.review_rounds | count_ok; "review_rounds must be a count or null")
    | assert(.interventions_before_green | count_ok; "interventions_before_green must be a count or null")
    | assert(.reached_green | flag_ok; "reached_green must be true, false, or null")
    | ["M", .repo, (.number | tostring), .created_at, .merged_at, (.review_rounds | cell_count), (.interventions_before_green | cell_count), (.reached_green | cell_flag)]
    | @tsv
  ),
  (
    .open[]?
    | assert(.repo | repo_ok; "open repo must be owner/name")
    | assert(.number | number_ok; "open number must be a positive integer")
    | assert(.created_at | stamp_ok; "open created_at must be UTC ISO-8601")
    | assert(.is_draft | flag_ok; "is_draft must be true, false, or null")
    | assert(.failing_checks | count_ok; "failing_checks must be a count or null")
    | assert(.pending_checks | count_ok; "pending_checks must be a count or null")
    | assert(.changes_requested | flag_ok; "changes_requested must be true, false, or null")
    | assert(.reported_checks | count_ok; "reported_checks must be a count or null")
    | assert(.conflict | flag_ok; "conflict must be true, false, or null")
    | ["O", .repo, (.number | tostring), .created_at, (.is_draft | cell_flag), (.failing_checks | cell_count), (.pending_checks | cell_count), (.changes_requested | cell_flag), (.reported_checks | cell_count), (.conflict | cell_flag)]
    | @tsv
  )
'

if ! jq -r "$JQ_PROGRAM" "$INPUT" >"$TMP/rows" 2>"$TMP/jq.err"; then
  err=$(tr '\n' ' ' <"$TMP/jq.err" | sed 's/[[:space:]]*$//')
  die "${err:-unreadable input}"
fi

awk -F '\t' 'NF { print $2 }' "$TMP/rows" >"$TMP/repo-raw"
sort -u "$TMP/repo-raw" >"$TMP/repos"

missing_cell() {
  [ -z "$1" ] || [ "$1" = "-" ]
}

classify_open() {
  draft=$1
  failing=$2
  pending=$3
  changes=$4
  reported=$5
  conflict=$6
  if missing_cell "$draft" || missing_cell "$failing" || missing_cell "$pending" || missing_cell "$changes" || missing_cell "$reported" || missing_cell "$conflict"; then
    printf 'unexplained\n'
    return 0
  fi
  if [ "$draft" = 1 ]; then printf 'draft\n'; return 0; fi
  if [ "$failing" -gt 0 ]; then printf 'failing-checks\n'; return 0; fi
  if [ "$changes" = 1 ]; then printf 'changes-requested\n'; return 0; fi
  if [ "$conflict" = 1 ]; then printf 'conflict\n'; return 0; fi
  if [ "$pending" -gt 0 ] || [ "$reported" -eq 0 ]; then printf 'pending-checks\n'; return 0; fi
  printf 'green-waiting\n'
}

median_line() {
  src=$1
  if [ ! -s "$src" ]; then
    printf 'none 0\n'
    return 0
  fi
  awk '
    { a[NR] = $1 + 0 }
    END {
      n = NR
      for (i = 2; i <= n; i++) {
        v = a[i]
        j = i - 1
        while (j >= 1 && a[j] > v) { a[j + 1] = a[j]; j-- }
        a[j + 1] = v
      }
      if (n % 2 == 1) m = a[(n + 1) / 2]
      else m = (a[n / 2] + a[n / 2 + 1]) / 2
      printf "%.2f %d\n", m, n
    }
  ' "$src"
}

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  : >"$TMP/hours"
  : >"$TMP/rounds"
  : >"$TMP/classes"
  open_n=0
  aged_n=0
  missing_rounds=0
  free_n=0
  completed_n=0
  missing_interventions=0
  max_rounds=
  awk -F '\t' -v repo="$repo" '$2 == repo { print }' "$TMP/rows" >"$TMP/one"
  while IFS=$'\t' read -r kind _repo number c1 c2 c3 c4 c5 c6 c7; do
    [ -n "${kind:-}" ] || continue
    case "$kind" in
      M)
        created_epoch=$(fm_utc_iso_to_epoch "$c1") || die "bad created_at for $repo#$number"
        merged_epoch=$(fm_utc_iso_to_epoch "$c2") || die "bad merged_at for $repo#$number"
        if [ "$merged_epoch" -lt "$created_epoch" ]; then
          die "merged_at is before created_at for $repo#$number"
        fi
        if [ "$merged_epoch" -ge "$START_EPOCH" ] && [ "$merged_epoch" -lt "$END_EPOCH" ]; then
          awk -v a="$created_epoch" -v b="$merged_epoch" 'BEGIN { printf "%.6f\n", (b - a) / 3600 }' >>"$TMP/hours"
          if missing_cell "$c3"; then
            missing_rounds=$((missing_rounds + 1))
          else
            printf '%s\n' "$c3" >>"$TMP/rounds"
            if [ -z "$max_rounds" ] || [ "$c3" -gt "$max_rounds" ]; then
              max_rounds=$c3
            fi
          fi
          if [ "$c5" = 1 ] && ! missing_cell "$c4"; then
            completed_n=$((completed_n + 1))
            if [ "$c4" -eq 0 ]; then
              free_n=$((free_n + 1))
            fi
          elif missing_cell "$c5" || { [ "$c5" = 1 ] && missing_cell "$c4"; }; then
            missing_interventions=$((missing_interventions + 1))
          fi
        fi
        ;;
      O)
        created_epoch=$(fm_utc_iso_to_epoch "$c1") || die "bad created_at for $repo#$number"
        open_n=$((open_n + 1))
        age_secs=$((NOW - created_epoch))
        if [ "$age_secs" -gt 86400 ]; then
          aged_n=$((aged_n + 1))
          class=$(classify_open "$c2" "$c3" "$c4" "$c5" "$c6" "$c7")
          age_hours=$(awk -v s="$age_secs" 'BEGIN { printf "%.2f", s / 3600 }')
          printf '%s\tclass repo=%s number=%s class=%s age_hours=%s\n' "$number" "$repo" "$number" "$class" "$age_hours" >>"$TMP/classes"
        fi
        ;;
      *)
        die "bad row kind for $repo#$number"
        ;;
    esac
  done <"$TMP/one"
  read -r median_hours median_n <<<"$(median_line "$TMP/hours")"
  read -r round_median round_n <<<"$(median_line "$TMP/rounds")"
  if [ -z "$max_rounds" ]; then
    max_rounds=none
  fi
  printf 'median repo=%s hours=%s n=%s\n' "$repo" "$median_hours" "$median_n"
  printf 'aged repo=%s numerator=%s denominator=%s\n' "$repo" "$aged_n" "$open_n"
  printf 'review_rounds repo=%s median=%s max=%s n=%s missing=%s\n' "$repo" "$round_median" "$max_rounds" "$round_n" "$missing_rounds"
  printf 'intervention_free repo=%s free=%s completed=%s missing=%s\n' "$repo" "$free_n" "$completed_n" "$missing_interventions"
  if [ -s "$TMP/classes" ]; then
    sort -n -k1,1 "$TMP/classes" | cut -f2-
  fi
done <"$TMP/repos"
