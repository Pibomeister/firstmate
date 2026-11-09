#!/usr/bin/env bash
# fm-soak-record.sh - record the inputs of one baseline or post-change soak run.
#
# Usage:
#   fm-soak-record.sh readable-harnesses
#   fm-soak-record.sh inventory --home <dir> --harness <h> [--harness <h>...]
#   fm-soak-record.sh start  --home <dir> --out <dir> --label baseline|post-change --harness <h> [--harness <h>...]
#   fm-soak-record.sh sample --home <dir> --out <dir>
#   fm-soak-record.sh finish --home <dir> --out <dir> --watchdog-dir <dir> --transcript-dir <dir>
#
# The recorder never writes inside the soak home <home>; it writes only under
# --out, and refuses an --out that resolves inside <home> or contains it, and a
# symlink at any path it writes under --out. sample and finish refuse a --home
# other than the home soak.json records. Every time is fm_now
# (bin/fm-clock-lib.sh).
#
# readable-harnesses prints one harness per line whose transcripts the
# startup-token measurement reads: `claude`.
# inventory prints `<h> readable` or `<h> unreadable` for each --harness, in the
# order given, and exits 3 when any is unreadable.
# start runs the inventory and refuses with exit 3 on an unreadable harness,
# then writes <out>/soak.json: label, home, revision (`git -C <home> rev-parse
# HEAD`), started_at, harnesses, and an empty session_ids list. It refuses an
# --out that already holds soak.json.
# sample appends one tab-separated row to <out>/load.tsv:
#   epoch  live_workers  wake_acks_last_hour  status_lines_last_hour  session_id
# The last hour is [epoch-3600, epoch). live_workers counts the task ids with a
# <home>/state/<id>.meta whose bin/fm-crew-state.sh line, read with
# FM_HOME=<home> FM_CREW_STATE_NO_FORGE=1 and FM_STATE_OVERRIDE set to a
# private temporary copy of <home>/state made under --out (with TMPDIR pointed
# inside it) once per sample or finish and removed on exit, is `state: working` or `state: parked`.
# wake_acks_last_hour is the count value of `bin/fm-wake-ledger.sh count` over
# the hour. status_lines_last_hour counts the lines of
# <home>/state/*.status whose first `[at=<epoch>]` falls in the hour.
# session_id is fm_session_lock_recorded_session_id
# (bin/fm-session-lock-lib.sh) of <home>/state when it is a plain name (letters,
# digits, `.`, `_` and `-`, not starting with `.`), else `-`. sample also appends to
# <out>/handoff-events.tsv one `<mtime>\t<path>` row for each handoff document
# (each <home>/data/handoff-*.md and the document named by the doc= line of
# <home>/state/.order-handoff) whose current modification it has not recorded
# yet, so each rewrite seen between samples is one modification event. sample
# refuses a run that is not started or is already finished.
# finish sets finished_at; the window is [started_at, finished_at]. It writes:
#   session_ids     the union of the sampled session ids and the ids of the
#                   <transcript-dir>/<id>.jsonl files modified in the window
#                   that are plain names (as for sample; any other id is
#                   skipped), ascending, each {id, transcript}: the kept copy's path
#                   under <out>, or `missing-transcript` when the id has none.
#   transcripts/    a copy of each of those transcripts.
#   handoffs/       each <home>/data/handoff-*.md modified in the window, and
#                   the document named by the doc= line of
#                   <home>/state/.order-handoff, as order-<name> unless it is
#                   one of the data/ documents already kept.
#   watchdog/       actions.tsv: the <watchdog-dir>/actions.tsv rows whose home
#                   is <home> and whose epoch is in the window
#                   (bin/fm-watchdog.sh owns its columns); handoffs/: the
#                   <watchdog-dir>/handoffs/ files modified in the window.
#   wake-ledger.tsv the window's wake-ledger rows (bin/fm-wake-ledger.sh rows).
#   handoff_count   the handoff-document modification events in the window
#                   (the distinct `<mtime> <path>` pairs sample recorded, plus
#                   each document's modification at finish), plus each distinct
#                   watchdog id with a kept `restart` row in phase `done`,
#                   except a `restart-requested` restart (the symptom column)
#                   for which a handoff-document modification event
#                   falls in that restart's episode: from the latest kept
#                   `handoff-request` `nudge` `pending` row before its first
#                   `restart` row, else the previous restart's `done` row, else
#                   started_at (whichever is latest), to its `done` row. A
#                   restart with any other symptom always counts one. The
#                   watchdog's own handoff files are not counted.
#   violations      {kind: undeclared-harness, task, harness} for each live
#                   task meta whose harness is outside the declared set and,
#                   for post-change only, {kind: no-activity-source, harness}
#                   for each declared harness bin/fm-activity-sources.sh names
#                   no source for (it is asked `FM_HOME=<home>
#                   fm-activity-sources.sh <harness>`; empty output or a
#                   non-zero exit is none), or
#                   {kind: activity-sources-unavailable, harness} for each
#                   declared harness when that script is absent.
# finish refuses a run that is not started or is already finished, and refuses
# with exit 2, before any write, a --watchdog-dir that is --out or inside it.
#
# Exit status: 0 on success, 3 on an unreadable harness, 2 on a usage error, a
# refused --out or a --home that is not the run's, and 1 on any other failure. -h or --help prints this usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-clock-lib.sh
. "$SCRIPT_DIR/fm-clock-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

READABLE_HARNESSES='claude'

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {  # <status> <message>
  printf 'fm-soak-record: %s\n' "$2" >&2
  exit "$1"
}

mtime() {
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

canon_dir() {  # <dir>: the physical absolute path of an existing directory, one leading slash
  local d
  d=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  while [ "${d#//}" != "$d" ]; do d=${d#/}; done   # bash keeps a leading // from pwd -P
  printf '%s\n' "$d"
}

canon_file() {  # <file>: the physical absolute path of an existing file
  local dir
  dir=$(canon_dir "$(dirname -- "$1")") || return 1
  printf '%s/%s\n' "${dir%/}" "$(basename -- "$1")"
}

within() {  # <path> <dir>: <path> is <dir> or lies inside it; a root <dir> (/ or //) holds every absolute path
  local dir=$2
  while [ "${dir%/}" != "$dir" ]; do dir=${dir%/}; done
  case "$1/" in "$dir"/*) return 0 ;; esac
  return 1
}

in_window() {  # <epoch>
  [ "$1" -ge "$STARTED" ] && [ "$1" -le "$NOW" ]
}

HOME_DIR=''
HOME_GIVEN=''
OUT=''
LABEL=''
WATCHDOG_DIR=''
TRANSCRIPT_DIR=''
HARNESSES=()

parse() {  # <allowed-flags> <args...>
  local allowed=$1
  shift
  while [ "$#" -gt 0 ]; do
    case " $allowed " in *" $1 "*) ;; *) die 2 "unknown argument: $1" ;; esac
    [ "$#" -ge 2 ] && [ -n "$2" ] || die 2 "$1 needs a value"
    case "$1" in
      --home) [ -z "$HOME_DIR" ] || die 2 "--home given twice"; HOME_DIR=$2 ;;
      --out) [ -z "$OUT" ] || die 2 "--out given twice"; OUT=$2 ;;
      --label) [ -z "$LABEL" ] || die 2 "--label given twice"; LABEL=$2 ;;
      --watchdog-dir) [ -z "$WATCHDOG_DIR" ] || die 2 "--watchdog-dir given twice"; WATCHDOG_DIR=$2 ;;
      --transcript-dir) [ -z "$TRANSCRIPT_DIR" ] || die 2 "--transcript-dir given twice"; TRANSCRIPT_DIR=$2 ;;
      --harness) HARNESSES+=("$2") ;;
    esac
    shift 2
  done
  local flag
  for flag in $allowed; do
    case "$flag" in
      --home) [ -n "$HOME_DIR" ] || die 2 "--home is required" ;;
      --out) [ -n "$OUT" ] || die 2 "--out is required" ;;
      --label) [ -n "$LABEL" ] || die 2 "--label is required" ;;
      --watchdog-dir) [ -n "$WATCHDOG_DIR" ] || die 2 "--watchdog-dir is required" ;;
      --transcript-dir) [ -n "$TRANSCRIPT_DIR" ] || die 2 "--transcript-dir is required" ;;
      --harness) [ "${#HARNESSES[@]}" -gt 0 ] || die 2 "--harness is required" ;;
    esac
  done
  HOME_GIVEN=$HOME_DIR
  HOME_DIR=$(canon_dir "$HOME_DIR") || die 2 "the soak home is not a directory"
  case " $allowed " in *' --out '*) prepare_out ;; esac
}

# prepare_out: resolve --out to its physical absolute path, refuse one inside
# the soak home, and refuse any symlink where the recorder writes, so no write
# can follow a link into the home.
prepare_out() {
  local parent p
  if [ -e "$OUT" ] || [ -L "$OUT" ]; then
    OUT=$(canon_dir "$OUT") || die 2 "--out is not a directory: $OUT"
  else
    parent=$(canon_dir "$(dirname -- "$OUT")") || die 2 "the parent of --out does not exist: $OUT"
    OUT="${parent%/}/$(basename -- "$OUT")"
  fi
  ! within "$OUT" "$HOME_DIR" || die 2 "--out is inside the soak home: $OUT"
  ! within "$HOME_DIR" "$OUT" || die 2 "--out contains the soak home: $OUT"
  for p in soak.json load.tsv handoff-events.tsv wake-ledger.tsv transcripts handoffs watchdog watchdog/actions.tsv watchdog/handoffs; do
    [ ! -L "$OUT/$p" ] || die 2 "refusing to write through a symlink: $OUT/$p"
  done
}

# require_run_home: refuse a --home other than the one the started run in
# --out records, before anything is written.
require_run_home() {
  [ "$(jq -r .home "$OUT/soak.json")" = "$HOME_DIR" ] \
    || die 2 "--home is not the home this soak run started on: $HOME_DIR"
}

# safe_session_id <id>: a session id that is safe as one path component.
safe_session_id() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# keep <source> <destination>: copy one input under --out, never through a
# symlink at the destination.
keep() {
  [ ! -L "$2" ] || die 2 "refusing to write through a symlink: $2"
  cp -p "$1" "$2"
}

is_readable() {  # <harness>
  case " $READABLE_HARNESSES " in *" $1 "*) return 0 ;; esac
  return 1
}

run_inventory() {
  local h status=0
  for h in "${HARNESSES[@]}"; do
    if is_readable "$h"; then
      printf '%s readable\n' "$h"
    else
      printf '%s unreadable\n' "$h"
      status=3
    fi
  done
  return "$status"
}

STATE_SNAPSHOT=''

# snapshot_state: copy <home>/state once into a private temporary directory
# under --out, removed on exit, and point TMPDIR inside it, so neither this
# copy nor any temporary file the recorder or its children make can land in the
# home through an inherited TMPDIR. Classifying a task can rewrite files under
# its state directory (a stale Muse session cache is deleted and rewritten), so
# crew_state reads this copy and the home is never written.
snapshot_state() {
  [ -z "$STATE_SNAPSHOT" ] || return 0
  STATE_SNAPSHOT=$(mktemp -d "$OUT/.fm-soak-state.XXXXXX") \
    || die 1 "cannot create a private copy of the home state"
  trap 'rm -rf "$STATE_SNAPSHOT"' EXIT
  mkdir "$STATE_SNAPSHOT/state" "$STATE_SNAPSHOT/tmp" \
    || die 1 "cannot create a private copy of the home state"
  TMPDIR="$STATE_SNAPSHOT/tmp"
  export TMPDIR
  if [ -d "$HOME_DIR/state" ]; then
    : > "$STATE_SNAPSHOT/copy-started" \
      || die 1 "cannot create a private copy of the home state"
    cp -RP "$HOME_DIR/state/." "$STATE_SNAPSHOT/state/" 2>/dev/null \
      || state_copy_complete \
      || die 1 "cannot copy the home state: $HOME_DIR/state"
  fi
}

# state_copy_complete: true when every entry of <home>/state that existed
# before the copy started and still exists is in the private copy, so an entry
# the live home removed, created or renamed into place while cp ran is not a
# copy failure.
state_copy_complete() {
  local p
  while IFS= read -r p; do
    { [ -e "$HOME_DIR/state/$p" ] || [ -L "$HOME_DIR/state/$p" ]; } || continue
    [ -e "$STATE_SNAPSHOT/state/$p" ] || [ -L "$STATE_SNAPSHOT/state/$p" ] || return 1
  done < <(cd "$HOME_DIR/state" && find . -mindepth 1 ! -cnewer "$STATE_SNAPSHOT/copy-started" -print)
}

# crew_state <id>: the soak home's current-state line for one task, classified
# against the private copy of the home state that snapshot_state made.
crew_state() {
  FM_STATE_OVERRIDE="$STATE_SNAPSHOT/state" FM_HOME="$HOME_DIR" FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null || :
}

# live_tasks: one `<id>\t<harness>` line per task whose meta exists and whose
# current state is working or parked.
live_tasks() {
  local meta id harness
  for meta in "$HOME_DIR"/state/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename -- "$meta" .meta)
    case "$(crew_state "$id")" in
      'state: working '*|'state: parked '*)
        harness=$(sed -n 's/^harness=//p' "$meta" | tail -n 1)
        printf '%s\t%s\n' "$id" "$harness" ;;
    esac
  done
}

wake_ledger() {  # <verb> <since> <until>
  env -u FM_STATE_OVERRIDE FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-wake-ledger.sh" "$1" --since "$2" --until "$3"
}

write_json() {  # <jq-filter> [jq-args...]: rewrite soak.json through jq
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$OUT/.soak.json.XXXXXX")
  if ! jq "$@" "$filter" "$OUT/soak.json" > "$tmp"; then
    rm -f "$tmp"
    die 1 "could not update $OUT/soak.json"
  fi
  mv "$tmp" "$OUT/soak.json"
}

cmd_start() {
  local revision status=0 harnesses
  parse '--home --out --label --harness' "$@"
  case "$LABEL" in baseline|post-change) ;; *) die 2 "--label must be baseline or post-change: $LABEL" ;; esac
  run_inventory || status=$?
  [ "$status" -eq 0 ] || die 3 "refusing to start: a declared harness is unreadable"
  [ ! -e "$OUT/soak.json" ] || die 1 "a soak run is already recorded in $OUT"
  revision=$(git -C "$HOME_DIR" rev-parse HEAD) || die 1 "cannot read the soak home revision"
  mkdir -p "$OUT"
  harnesses=$(printf '%s\n' "${HARNESSES[@]}" | jq -R . | jq -sc .)
  jq -n --arg label "$LABEL" --arg home "$HOME_DIR" --arg revision "$revision" \
    --argjson started "$(fm_now)" --argjson harnesses "$harnesses" \
    '{label: $label, home: $home, revision: $revision, started_at: $started,
      harnesses: $harnesses, session_ids: []}' > "$OUT/soak.json"
}

# handoff_docs: the soak home's handoff documents, one path per line: each
# data/handoff-*.md, then the document the order record names.
handoff_docs() {
  local doc
  for doc in "$HOME_DIR"/data/handoff-*.md; do
    [ -f "$doc" ] && printf '%s\n' "$doc"
  done
  doc=
  [ ! -f "$HOME_DIR/state/.order-handoff" ] || doc=$(sed -n 's/^doc=//p' "$HOME_DIR/state/.order-handoff" | head -n 1)
  [ -z "$doc" ] || [ ! -f "$doc" ] || printf '%s\n' "$doc"
}

# handoff_events: one `<mtime>\t<physical path>` line per handoff document as
# it is now.
handoff_events() {
  local doc canon
  while IFS= read -r doc; do
    canon=$(canon_file "$doc") || continue
    printf '%s\t%s\n' "$(mtime "$doc")" "$canon"
  done < <(handoff_docs)
}

cmd_sample() {
  local now since live acks lines session events
  parse '--home --out' "$@"
  [ -f "$OUT/soak.json" ] || die 1 "no soak run is started in $OUT"
  [ "$(jq -r '.finished_at // empty' "$OUT/soak.json")" = '' ] || die 1 "the soak run in $OUT is already finished"
  require_run_home
  snapshot_state
  now=$(fm_now)
  since=$((now - 3600))
  live=$(live_tasks | awk 'END { print NR }')
  acks=$(wake_ledger count "$since" "$now" | sed -n 's/.* count=\([0-9][0-9]*\)$/\1/p')
  [ -n "$acks" ] || die 1 "cannot count the soak home's wake ledger"
  lines=$(cat /dev/null "$HOME_DIR"/state/*.status 2>/dev/null | awk -v since="$since" -v now="$now" '
    match($0, /\[at=[0-9]+\]/) {
      at = substr($0, RSTART + 4, RLENGTH - 5) + 0
      if (at >= since && at < now) n++
    }
    END { print n + 0 }')
  session=$(fm_session_lock_recorded_session_id "$HOME_DIR/state") || session=-
  safe_session_id "$session" || session=-
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$live" "$acks" "$lines" "$session" >> "$OUT/load.tsv"
  touch "$OUT/handoff-events.tsv"
  events=$(handoff_events | awk -F '\t' 'FILENAME == ARGV[1] { seen[$0]; next } !($0 in seen) { seen[$0]; print }' \
    "$OUT/handoff-events.tsv" -)
  [ -z "$events" ] || printf '%s\n' "$events" >> "$OUT/handoff-events.tsv"
}

# keep_handoff <source> <name>: copy one handoff document under handoffs/ as
# <name>.
keep_handoff() {
  mkdir -p "$OUT/handoffs"
  keep "$1" "$OUT/handoffs/$2"
}

cmd_finish() {
  local doc canon id t sessions ids seen='' events restarts docs total violations h named
  parse '--home --out --watchdog-dir --transcript-dir' "$@"
  [ -d "$WATCHDOG_DIR" ] || die 2 "the watchdog directory does not exist: $WATCHDOG_DIR"
  WATCHDOG_DIR=$(canon_dir "$WATCHDOG_DIR") || die 2 "the watchdog directory does not exist: $WATCHDOG_DIR"
  ! within "$WATCHDOG_DIR" "$OUT" || die 2 "--watchdog-dir is --out or inside it: $WATCHDOG_DIR"
  [ -d "$TRANSCRIPT_DIR" ] || die 2 "the transcript directory does not exist: $TRANSCRIPT_DIR"
  [ -f "$OUT/soak.json" ] || die 1 "no soak run is started in $OUT"
  [ "$(jq -r '.finished_at // empty' "$OUT/soak.json")" = '' ] || die 1 "the soak run in $OUT is already finished"
  require_run_home
  snapshot_state
  STARTED=$(jq -r .started_at "$OUT/soak.json")
  LABEL=$(jq -r .label "$OUT/soak.json")
  HARNESSES=()
  while IFS= read -r h; do HARNESSES+=("$h"); done < <(jq -r '.harnesses[]' "$OUT/soak.json")
  NOW=$(fm_now)

  # Session ids and their transcripts.
  sessions=$( {
      [ ! -f "$OUT/load.tsv" ] || awk -F '\t' '$5 != "" && $5 != "-" { print $5 }' "$OUT/load.tsv"
      for t in "$TRANSCRIPT_DIR"/*.jsonl; do
        [ -f "$t" ] || continue
        in_window "$(mtime "$t")" && basename -- "$t" .jsonl
      done
    } | LC_ALL=C sort -u)
  ids='[]'
  while IFS= read -r id; do
    safe_session_id "$id" || continue
    if [ -f "$TRANSCRIPT_DIR/$id.jsonl" ]; then
      mkdir -p "$OUT/transcripts"
      keep "$TRANSCRIPT_DIR/$id.jsonl" "$OUT/transcripts/$id.jsonl"
      t="transcripts/$id.jsonl"
    else
      t=missing-transcript
    fi
    ids=$(jq -c --arg id "$id" --arg t "$t" '. + [{id: $id, transcript: $t}]' <<<"$ids")
  done <<<"$sessions"

  # Handoff documents: kept once by physical path, counted by modification event.
  for doc in "$HOME_DIR"/data/handoff-*.md; do
    [ -f "$doc" ] || continue
    in_window "$(mtime "$doc")" || continue
    canon=$(canon_file "$doc") || continue
    keep_handoff "$doc" "$(basename -- "$doc")"
    seen="$seen$canon"$'\n'
  done
  doc=
  [ ! -f "$HOME_DIR/state/.order-handoff" ] || doc=$(sed -n 's/^doc=//p' "$HOME_DIR/state/.order-handoff" | head -n 1)
  if [ -n "$doc" ] && [ -f "$doc" ] && canon=$(canon_file "$doc"); then
    case $'\n'"$seen" in
      *$'\n'"$canon"$'\n'*) ;;
      *) keep_handoff "$doc" "order-$(basename -- "$doc")" ;;
    esac
  fi
  events=$( { [ ! -f "$OUT/handoff-events.tsv" ] || cat "$OUT/handoff-events.tsv"; handoff_events; } |
    awk -F '\t' -v s="$STARTED" -v n="$NOW" '$1 ~ /^[0-9]+$/ && $1 + 0 >= s + 0 && $1 + 0 <= n + 0' | LC_ALL=C sort -u)
  docs=$(printf '%s' "$events" | awk 'END { print NR }')

  # Watchdog rows and the watchdog's own handoff files.
  mkdir -p "$OUT/watchdog"
  : > "$OUT/watchdog/actions.tsv"
  if [ -f "$WATCHDOG_DIR/actions.tsv" ]; then
    awk -F '\t' -v h="$HOME_DIR" -v given="$HOME_GIVEN" -v s="$STARTED" -v n="$NOW" '
      ($3 == h || $3 == given) && $1 ~ /^[0-9]+$/ && $1 + 0 >= s + 0 && $1 + 0 <= n + 0
    ' "$WATCHDOG_DIR/actions.tsv" > "$OUT/watchdog/actions.tsv"
  fi
  for doc in "$WATCHDOG_DIR"/handoffs/*; do
    [ -f "$doc" ] || continue
    in_window "$(mtime "$doc")" || continue
    mkdir -p "$OUT/watchdog/handoffs"
    keep "$doc" "$OUT/watchdog/handoffs/$(basename -- "$doc")"
  done
  restarts=$(printf '%s\n' "$events" | awk -F '\t' -v s="$STARTED" '
    NR == FNR { if ($1 != "") ev[NR] = $1 + 0; next }
    $5 == "handoff-request" && $6 == "nudge" && $7 == "pending" { nudge = $1 + 0; next }
    $6 != "restart" || ($7 != "pending" && $7 != "done") || ($2 in done) { next }
    !($2 in from) {
      from[$2] = s + 0
      if (prev > from[$2]) from[$2] = prev
      if (nudge > from[$2]) from[$2] = nudge
    }
    $7 == "done" {
      done[$2] = $1 + 0
      prev = $1 + 0
      dropped = 0
      if ($5 == "restart-requested")
        for (e in ev) if (ev[e] >= from[$2] && ev[e] <= done[$2]) dropped = 1
      if (!dropped) n++
    }
    END { print n + 0 }' - "$OUT/watchdog/actions.tsv")

  # Wake-ledger rows of the window.
  wake_ledger rows "$STARTED" $((NOW + 1)) > "$OUT/wake-ledger.tsv"

  # Violations.
  violations=$(live_tasks | while IFS="$(printf '\t')" read -r id h; do
      is_declared "$h" || jq -cn --arg task "$id" --arg harness "$h" \
        '{kind: "undeclared-harness", task: $task, harness: $harness}'
    done | jq -sc .)
  if [ "$LABEL" = post-change ]; then
    for h in "${HARNESSES[@]}"; do
      if [ -e "$SCRIPT_DIR/fm-activity-sources.sh" ]; then
        named=$(env -u FM_STATE_OVERRIDE FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-activity-sources.sh" "$h" 2>/dev/null) || named=
        [ -n "$named" ] && continue
        violations=$(jq -c --arg h "$h" '. + [{kind: "no-activity-source", harness: $h}]' <<<"$violations")
      else
        violations=$(jq -c --arg h "$h" '. + [{kind: "activity-sources-unavailable", harness: $h}]' <<<"$violations")
      fi
    done
  fi

  total=$((docs + restarts))
  # shellcheck disable=SC2016  # jq variables, bound by the --argjson flags below
  write_json '.finished_at = $finished | .session_ids = $ids | .handoff_count = $count | .violations = $violations' \
    --argjson finished "$NOW" --argjson ids "$ids" --argjson count "$total" --argjson violations "$violations"
}

is_declared() {  # <harness>
  local h
  for h in "${HARNESSES[@]}"; do [ "$h" = "$1" ] && return 0; done
  return 1
}

cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  readable-harnesses)
    [ "$#" -eq 0 ] || die 2 "readable-harnesses takes no arguments"
    printf '%s\n' $READABLE_HARNESSES ;;
  inventory)
    parse '--home --harness' "$@"
    run_inventory ;;
  start) cmd_start "$@" ;;
  sample) cmd_sample "$@" ;;
  finish) cmd_finish "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
