#!/usr/bin/env bash
# fm-rsi-instrument.sh - read-only producer of the RSI instrument fields.
#
# Usage:
#   fm-rsi-instrument.sh --input <json> --home <fm-home> [--nm-db <state.sqlite>]
#   fm-rsi-instrument.sh --help
#
# The input is the JSON object bin/fm-rsi-measure.sh reads. On each merged
# row, review_rounds may hold a forge-submission count or null. This command
# prints the same object on stdout with review_rounds,
# interventions_before_green, and reached_green filled, plus
# review_rounds_source on each merged row. Open rows pass through unchanged.
# It never contacts a forge and never writes a file outside its temp dir.
#
# A merged row's pull request is https://github.com/<repo>/pull/<number>.
#
# review_rounds. With --nm-db, the no-mistakes state database is opened with
# SQLite mode=ro. A run whose pr_url is the pull request counts only when its
# review step ran, so a skipped or pending review step is not a measured
# review. When such a run exists, the count is every step_rounds row of those
# review steps, and review_rounds_source is "no-mistakes". Otherwise a numeric input
# review_rounds stays as the forge fallback with source "forge". Otherwise
# both are null.
#
# Task. The task is the one state/<task>.meta under --home with the line
# pr=<pull request>. No such meta, or more than one, leaves both
# intervention fields null.
#
# reached_green is true when state/<task>.status has a done line that
# contains "PR <pull request> checks green". Otherwise it is null, because a
# merged pull request without that line is unknown, not failed.
#
# interventions_before_green counts, before the first such done line:
#   - status lines whose verb is needs-decision or blocked, in file order
#     before that line, excluding a line stamped before dispatch;
#   - steering records state/<task>.inbox/*.msg and handled/*.msg whose at=
#     is at or after dispatch and before the done line's [at=] time.
# Dispatch is the newest state/dispatch-log.tsv dispatched line naming
# task=<task> at or before the done line; with none, no lower bound applies.
# A stale wake leaves no status line, so it is outside this count.
# An unstamped done line or an unreadable record time leaves the count null.
#
# Exit 0 on output, 2 on a usage or input refusal.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }

die() {
  printf 'fm-rsi-instrument: %s\n' "$*" >&2
  exit 2
}

INPUT=
HOME_DIR=
NM_DB=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input) INPUT=${2:-}; shift ;;
    --home) HOME_DIR=${2:-}; shift ;;
    --nm-db) NM_DB=${2:-}; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -n "$INPUT" ] && [ -n "$HOME_DIR" ] || die "usage: fm-rsi-instrument.sh --input <json> --home <fm-home> [--nm-db <state.sqlite>]"
[ -f "$INPUT" ] || die "no such input: $INPUT"
[ -d "$HOME_DIR/state" ] || die "no state directory under home: $HOME_DIR"
if [ -n "$NM_DB" ]; then
  [ -f "$NM_DB" ] || die "no such no-mistakes database: $NM_DB"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for --nm-db"
fi
command -v jq >/dev/null 2>&1 || die "jq is required"

STATE=$HOME_DIR/state
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-rsi-instrument.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if ! jq -r '
  def assert(ok; msg): if ok then . else (msg | halt_error(5)) end;
  if type != "object" then ("input must be an object" | halt_error(5)) else . end
  | assert(has("merged") and (.merged | type == "array"); "merged must be an array")
  | assert(has("open") and (.open | type == "array"); "open must be an array")
  | .merged[]
  | assert(.repo | type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"); "merged repo must be owner/name")
  | assert(.number | type == "number" and floor == . and . >= 1; "merged number must be a positive integer")
  | "https://github.com/\(.repo)/pull/\(.number)"
' "$INPUT" >"$TMP/urls" 2>"$TMP/jq.err"; then
  die "$(tr '\n' ' ' <"$TMP/jq.err" | sed 's/[[:space:]]*$//')"
fi

: >"$TMP/nm-rounds"
if [ -n "$NM_DB" ] && [ -s "$TMP/urls" ]; then
  python3 - "$NM_DB" "$TMP/urls" >"$TMP/nm-rounds" <<'PY' || die "could not read the no-mistakes database: $NM_DB"
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

with open(sys.argv[2], encoding="utf-8") as handle:
    urls = [line.strip() for line in handle if line.strip()]
uri = Path(sys.argv[1]).resolve().as_uri() + "?mode=ro"
with closing(sqlite3.connect(uri, uri=True, timeout=30)) as db:
    for url in urls:
        steps, rounds = db.execute(
            "SELECT COUNT(*), COALESCE(SUM((SELECT COUNT(*) FROM step_rounds sr WHERE sr.step_result_id = s.id)), 0)"
            " FROM step_results s JOIN runs r ON r.id = s.run_id"
            " WHERE r.pr_url = ? AND s.step_name = 'review'"
            " AND s.status NOT IN ('skipped', 'pending')",
            (url,),
        ).fetchone()
        if steps == 0:
            continue
        print(f"{url}\t{rounds}")
PY
fi

task_for_url() {  # <url> -> task id, or nonzero
  local found='' meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qxF "pr=$1" "$meta" || continue
    [ -z "$found" ] || return 1
    found=$(basename "$meta" .meta)
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

dispatch_epoch() {  # <task> <green-epoch> -> newest dispatch epoch at or before green
  local log=$STATE/dispatch-log.tsv
  [ -f "$log" ] || return 1
  awk -F '\t' -v task="$1" -v green="$2" '
    $3 == "dispatched" && $2 ~ /^[0-9]+$/ && $2 + 0 <= green + 0 {
      n = split($5, words, " ")
      for (i = 1; i <= n; i++) if (words[i] == "task=" task) { best = $2 }
    }
    END { if (best == "") exit 1; print best }
  ' "$log"
}

# Prints "<reached_green> <interventions>" for one task, each true/null or a
# count/null.
task_instruments() {  # <task> <url>
  local task=$1 url=$2 status=$STATE/$1.status line verb at green_line=0 n=0
  local green_at='' lower=0 count=0 msg stamp epoch
  [ -f "$status" ] || { printf 'null null\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    status_line_verb "$line" verb
    [ "$verb" = "done" ] || continue
    case "$line" in *"PR $url checks green"*) ;; *) continue ;; esac
    green_line=$n
    at=
    status_line_at_epoch "$line" at || true
    green_at=$at
    break
  done <"$status"
  [ "$green_line" -gt 0 ] || { printf 'null null\n'; return 0; }
  [ -n "$green_at" ] || { printf 'true null\n'; return 0; }
  lower=$(dispatch_epoch "$task" "$green_at") || lower=0
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -lt "$green_line" ] || break
    status_line_verb "$line" verb
    case "$verb" in needs-decision|blocked) ;; *) continue ;; esac
    at=
    if status_line_at_epoch "$line" at && [ "$at" -lt "$lower" ]; then
      continue
    fi
    count=$((count + 1))
  done <"$status"
  for msg in "$STATE/$task.inbox"/*.msg "$STATE/$task.inbox/handled"/*.msg; do
    [ -f "$msg" ] || continue
    stamp=$(sed -n 's/^at=//p;/^--$/q' "$msg" | head -n 1)
    epoch=$(fm_utc_iso_to_epoch "$stamp") || { printf 'true null\n'; return 0; }
    if [ "$epoch" -ge "$lower" ] && [ "$epoch" -lt "$green_at" ]; then
      count=$((count + 1))
    fi
  done
  printf 'true %s\n' "$count"
}

: >"$TMP/fill"
while IFS= read -r url; do
  [ -n "$url" ] || continue
  rounds=$(awk -F '\t' -v u="$url" '$1 == u { print $2; exit }' "$TMP/nm-rounds")
  green=null
  interventions=null
  if task=$(task_for_url "$url"); then
    read -r green interventions <<<"$(task_instruments "$task" "$url")"
  fi
  printf '%s\t%s\t%s\t%s\n' "$url" "${rounds:--}" "$green" "$interventions" >>"$TMP/fill"
done <"$TMP/urls"

jq --rawfile fill "$TMP/fill" '
  ($fill | split("\n") | map(select(length > 0) | split("\t"))
    | map({key: .[0], value: {rounds: .[1], green: (.[2] | fromjson), interventions: (.[3] | fromjson)}})
    | from_entries) as $by
  | .merged |= map(
      $by["https://github.com/\(.repo)/pull/\(.number)"] as $f
      | if $f.rounds != "-" then .review_rounds = ($f.rounds | tonumber) | .review_rounds_source = "no-mistakes"
        elif (.review_rounds | type) == "number" then .review_rounds_source = "forge"
        else .review_rounds = null | .review_rounds_source = null
        end
      | .reached_green = $f.green
      | .interventions_before_green = $f.interventions
    )
' "$INPUT"
