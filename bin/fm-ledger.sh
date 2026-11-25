#!/usr/bin/env bash
# fm-ledger.sh - the mission ledger: the per-project plan, ready queue, intake,
# and handoff view over THIS home's existing backlog.
#
# Usage:
#   fm-ledger.sh intake (<id> | --mint) --project <name> --title <text>
#                --source <kind>:<ref> [--kind <kind>] [--priority <0-4>]
#                [--blocked-by <id>]... [--body <text> | --body-file <path>]
#   fm-ledger.sh unfiled
#   fm-ledger.sh plan [--project <name>] [--limit <n>]
#   fm-ledger.sh next [--project <name>]
#   fm-ledger.sh claim --project <name> [--resume <id>]
#   fm-ledger.sh claim-release <id> --token <nonce>
#   fm-ledger.sh depth [--scheduled]
#   fm-ledger.sh handoff --doc <file> (--note <text> | --note-file <path> | --note-file -)
#   fm-ledger.sh arm [--if-enabled]
#   fm-ledger.sh disarm
#
# The ledger is the backlog. Backlog reads and writes go through
# bin/fm-tasks-axi.sh, so the configured tasks-axi backend owns task state.
# Claims reserve dispatch identity without creating another backlog.
# <data>/ledger-intake.tsv records where each filed item came from (see INTAKE),
# never task state. Opt-in dispatch receipts are described under CLAIM.
#
# INTAKE. `intake` files one approved proposal, one captain order, or one ask
# as its own queued backlog item the moment it arrives. The source names its
# origin:
#   order:<order-id>     a captain order (bin/fm-order.sh); it must exist
#   proposal:<ref>       an approved proposal, such as a report's item S2
#   goal:<goal-id>       a captain goal in bin/fm-dispatch-log.sh; it must exist
#   ask:<ref>            any other captain ask
# <ref> matches [A-Za-z0-9._:/#-]+. An order or proposal with several asks is
# filed once per ask, each with the same source and its own title.
# The item is added with `fm-tasks-axi.sh add --queue` (or `--mint`), its body
# starts with the line `Ledger source: <source>`, and one TSV row is appended
# to <data>/ledger-intake.tsv:
#   <utc-iso>\t<epoch>\t<source>\t<item-id>\t<project>\t<title>
# A retry with the same source, project, and title (and the same id, when one
# is given) prints `replay <item-id>` and files nothing, so intake is safe to
# repeat. Success prints `filed <item-id> project=<name> source=<source>`.
# An explicit <id> that already names a backlog item is refused (exit 1) and
# nothing is filed, unless that item is this same ask from an intake that
# stopped before writing its record; then the record is written and the result
# is `replay <item-id>`.
#
# UNFILED. `unfiled` lists every open captain order (pending or acked, kind
# order; holds are standing limits, not work) that no ledger item records:
#   UNFILED <order-id> <state> :: <summary>
# An order counts as filed when an intake row names it as its source, or when an
# open or kept-done backlog item mentions its id, or the id's 8-hex suffix as a
# whole word, in its id, title, or the visible part of its body (items filed
# before this command existed). It exits
# 3 when any order is unfiled and 0 otherwise.
#
# PLAN. `plan` prints the per-project plan from the backlog: one `project`
# line per project, then its items grouped as
#   in_flight   being worked now (not held)
#   ready       dispatchable now: exactly `tasks-axi ready`, ordered by
#               priority (0 first, no priority last), then backlog order
#   blocked     queued and not ready: blocked by another item, or otherwise
#               not dispatchable
#   held        held for the captain or a date, in any state
# A project is active when it has any in-flight, ready, or blocked item; a
# project whose only open items are held is parked. The project line is
#   project <name> active|parked ready=<n> in_flight=<n> blocked=<n> held=<n>[ SHORT]
# where SHORT marks an active project below the ready target (see DEPTH).
# Items with no project are listed under the name `-`.
# `--project` limits the plan to one project. `--limit <n>` is the compact
# form the handoff uses: every in-flight row, at most n ready rows with the
# remainder counted, and blocked and held items as one id list each.
#
# NEXT. `next` is read-only and needs no supervisor: it prints the
# highest-priority ready item across every project (of one project with
# --project), with backlog order breaking ties, as
#   NEXT <id> project=<name> kind=<kind> priority=<p>
# followed by `fm-tasks-axi.sh show <id> --full`. A worker or second mate runs
# it to see what comes next; it dispatches nothing. It exits 3 when nothing is
# ready.
#
# CLAIM. Opt-in via config/mission-ledger claim-project (see docs/configuration.md).
# Claims only this home's queued, ready, ledger-sourced items with a prepared
# brief and a project clone under this home's projects directory. An exact
# project grant is the operator's machine-readable charter scope, never inferred
# from another home's registry. Main-owned/in-flight tasks are never adopted.
# Selection and receipt publication hold the home claim lock and the selected
# task's spawn lock. An existing claim, metadata, or pending close is excluded.
# Success prints CLAIM <id> project=<name> phase=reserved token=<nonce>.
# Pass the id and --claim <nonce> to fm-spawn with its normal arguments.
# next remains read-only and includes reserved items; claim skips them.
#
# state/ledger-claims/<id>.json is a dispatch receipt, not a second backlog.
# It binds the home, project path, source, complete item and brief. Spawn checks
# these again, together with readiness, standing holds, open status decisions
# and the current lane budget, before any endpoint allocation. All ordinary
# spawn profile, disk, capacity and budget gates still apply. Standing holds
# conservatively refuse claims until the owner reconciles them.
# --resume recovers a lost claim reply with the SAME token. A reserved receipt
# is reusable only while its approval inputs match; changed inputs refuse and
# require owner reconciliation, never automatic reapproval. Receipts never expire.
# A dispatching receipt is written before endpoint allocation. A crash after
# that fence returns exit 4 on resume. Before worker delivery, spawn records
# launching and saves the exact endpoint metadata in the receipt. With metadata
# still present use fm-control; without it, the supervisor uses claim-release.
# A launched receipt returns its identity without starting anything.
# Source orders must remain pending or acked; done/parked revokes approval.
# Project paths are physically contained within this home's projects root.
# Order authority and standing holds are rechecked under the claim lock as the
# last authority reads before publishing a reservation or dispatch transition.
#
# RELEASE. claim-release is supervisor-only (no FM_TASK_ID and main actor),
# binds the exact current token, and takes the claim, spawn and metadata locks.
# It refuses while dispatch/lifecycle work, a task record or a backlog close
# remains. Reserved/dispatching receipts prove no worker delivery was
# attempted and may be released after a pre-metadata crash. After delivery, the
# saved endpoint must be proven gone by fm-control's existing backend classifier,
# and no process may retain the recorded worktree as cwd. Unknown/unsupported
# absence proof refuses; there is no override.
# Release never destroys an endpoint, worktree or backlog item. It archives the
# receipt under released/<id>-<token>.json; claiming again rechecks current
# authority and issues a different token, so stale spawn calls remain fenced.
# Any pre-launch allocations left by a crash still use normal owner cleanup.
#
# Spawn-only entry points: claim-check, claim-begin, claim-launch, claim-fence, claim-finish <id> <token>
# <canonical-project-path>. They require the direct caller to hold .spawn-<id>.lock.
# begin changes reserved -> dispatching; launch saves the endpoint and changes
# dispatching -> launching after metadata publication and before worker delivery;
# fence re-reads claim authority at the delivery point without moving the receipt;
# finish changes launching -> launched after delivery and backlog commit.
# A missing token refuses an existing claim. Relaunch of a launched receipt is
# the recovery path after delivery. Relaunch of a launching receipt re-runs fence
# and may finish; a claim that has not launched still refuses.
#
# DEPTH. `depth` reports every active project whose ready queue is below the
# target, so the night always has work:
#   SHORT <name> ready=<n> min=<m> in_flight=<n> blocked=<n> held=<n>
# It exits 3 when any project is short; otherwise it prints one
# `ready-depth: ok` line and exits 0. The project `-` is never short.
# `depth --scheduled` is what the watcher's ready-depth check runs every check
# sweep. The scheduled times are fixed at 17:00 and 23:00. It does nothing
# until a scheduled time has passed, then evaluates once per scheduled time and prints one line only when a project is short, which the
# watcher queues as a `check:` wake for the supervisor:
#   ready-depth <HH:MM>: <k> active project(s) below <m> ready: <name>(ready=<n>) ...
# A scheduled time counts as passed for 6 hours after it; one that passed
# longer ago (the watcher was down) is skipped. The last evaluated time is
# recorded in <state>/.ready-depth-slot only after its evaluation completes,
# so a failed or interrupted evaluation is retried on the next sweep. Times are the captain's local wall
# clock: the zone is bin/fm-quiet-hours-lib.sh's configured quiet-hours zone.
# A failed evaluation prints one diagnostic line, recorded in
# <state>/.ready-depth-error so the same failure is reported once, not on
# every sweep, while each sweep keeps retrying.
#
# HANDOFF. `handoff` writes a new session handoff document from the ledger
# plus a short note of what is in flight right now, and never continues an
# earlier handoff. It refuses, writing nothing, when:
#   - the document already exists (exit 1);
#   - the note is missing, empty, longer than 60 lines or 6000 bytes, or names
#     an earlier handoff document (a file name like handoff-20261111T1405Z):
#     durable facts belong in the ledger, not a chain of handoffs (exit 1);
#   - `unfiled` reports an open order with no ledger item (exit 3, listing
#     each); file it with `intake --source order:<id>` and retry.
# The document holds the note, the compact plan (`plan --limit 3`), and the
# open captain goals (`bin/fm-dispatch-log.sh open`); then bin/fm-order.sh
# `handoff --doc` appends the open captain orders and records the document for
# its restart gate, which that script owns.
#
# ARM. `arm` installs <state>/ready-depth.check.sh, a shim that runs
# `depth --scheduled` with this home's directories, and registers it with
# bin/fm-check-register.sh. The shim's second line marks it as the ledger's;
# `ready-depth` is also a valid task id, so `arm` refuses (exit 1) to replace a
# check at that path without the mark, and `disarm` leaves such a file alone. `arm --if-enabled` arms only when min-ready is not
# 0, and otherwise disarms; bin/fm-bootstrap.sh runs it at session start when a
# tasks-axi backlog is available. `disarm` unregisters the check through
# bin/fm-check-unregister.sh.
#
# CONFIG (config/mission-ledger, optional; docs/configuration.md "Mission
# ledger" owns the schema). Absent means the defaults.
#   min-ready=<n>         ready items each active project needs (default 3; 0
#                         turns the scheduled check off)
#   claim-project=<slug>  repeatable exact project grant for claim (see CLAIM)
# Blank lines and lines starting with # are ignored; an unusable min-ready
# keeps its default, while unsafe files or malformed claim-project grants
# refuse claims.
#
# Exit status: 0 success; 1 refusal or failure; 2 usage error; 3 a result to
# act on (unfiled order, short project, nothing ready, handoff refused for an
# unfiled order); 4 an uncertain claimed dispatch requiring task recovery.
#
# Environment: FM_HOME selects the home; FM_DATA_OVERRIDE, FM_STATE_OVERRIDE,
# and FM_CONFIG_OVERRIDE override its directories. With FM_TEST_SEAM=1, FM_NOW
# pins the clock (bin/fm-clock-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
# shellcheck source=bin/fm-quiet-hours-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quiet-hours-lib.sh"

INTAKE_LOG="$DATA/ledger-intake.tsv"
SLOT_FILE="$STATE/.ready-depth-slot"
ERROR_FILE="$STATE/.ready-depth-error"
CHECK_ID='ready-depth'
CHECK_MARK='# fm-ledger: mission ledger ready-depth check'
SLOT_GRACE=21600
NOTE_MAX_LINES=60
NOTE_MAX_BYTES=6000

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-ledger: %s\n' "$*" >&2
  exit 1
}

usage_die() {
  printf 'fm-ledger: %s\n' "$*" >&2
  exit 2
}

tasks() {
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" "$@"
}

iso_of() {
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# --- configuration -----------------------------------------------------------

MIN_READY=3
SLOTS="17:00,23:00"  # fixed scheduled check times, captain-local

load_config() {
  local conf="$CONFIG/mission-ledger" line key val
  [ -f "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$key" in
      min-ready)
        case "$val" in '' | *[!0-9]*) ;; *) MIN_READY=$((10#$val)) ;; esac
        ;;
    esac
  done < "$conf"
}

# --- backlog reads -------------------------------------------------------------

# toon_rows <col>...: read a tasks-axi TOON listing on stdin and print the named
# columns of each table row, tab-separated, with quoting and escapes decoded and
# a tasks-axi cut note shortened to " [truncated]". With TOON_TABLE set, only
# rows of the table of that name are read.
toon_rows() {
  awk -v want="$*" -v table="${TOON_TABLE:-}" '
    function parse(line, f,   n, i, c, nx, inq, cur) {
      n = 0; cur = ""; inq = 0
      sub(/^ +/, "", line)
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\\") {
            nx = substr(line, i + 1, 1)
            cur = cur (nx == "n" ? " " : (nx == "t" ? " " : nx))
            i++
            continue
          }
          if (c == "\"") { inq = 0; continue }
          cur = cur c
        } else if (c == "\"") {
          inq = 1
        } else if (c == ",") {
          f[++n] = cur; cur = ""
        } else {
          cur = cur c
        }
      }
      f[++n] = cur
      return n
    }
    BEGIN { nw = split(want, w, " ") }
    /^[A-Za-z_]+\[[0-9]+\]\{.*\}:$/ {
      name = $0
      sub(/\[.*/, "", name)
      if (table != "" && name != table) { rows = 0; next }
      hdr = $0
      sub(/^[^{]*\{/, "", hdr); sub(/\}:$/, "", hdr)
      nc = split(hdr, cols, ",")
      delete idx
      for (i = 1; i <= nc; i++) idx[cols[i]] = i
      rows = 1
      next
    }
    rows && /^  [^ -]/ {
      delete f
      parse($0, f)
      out = ""
      for (i = 1; i <= nw; i++) {
        v = (w[i] in idx) ? f[idx[w[i]]] : ""
        gsub(/\t/, " ", v)
        gsub(/ \.\.\. \(truncated, [0-9]+ chars total[^)]*\)/, " [truncated]", v)
        out = out (i > 1 ? "\t" : "") v
      }
      print out
      next
    }
    { rows = 0 }
  '
}

# load_backlog: fill OPEN_ROWS (id state kind repo title priority held) and
# READY_IDS from the backlog; fail with tasks-axi's own diagnostic.
OPEN_ROWS=
READY_IDS=
load_backlog() {
  local out
  out=$(tasks list --fields priority,held 2>&1) || die "backlog read failed: $(clean "$out")"
  OPEN_ROWS=$(printf '%s\n' "$out" | toon_rows id state kind repo title priority held)
  out=$(tasks ready 2>&1) || die "backlog ready read failed: $(clean "$out")"
  # Only the `ready` table is dispatchable work; tasks-axi lists public-followup
  # obligations in a separate ready_public_followups table that is never work.
  READY_IDS=" $(printf '%s\n' "$out" | TOON_TABLE=ready toon_rows id | tr '\n' ' ')"
}

# classified_rows: print `<project>\t<group>\t<rank>\t<seq>\t<id>\t<kind>\t<priority>\t<title>`
# for every open item, where group is in_flight, ready, blocked, or held.
classified_rows() {
  printf '%s\n' "$OPEN_ROWS" | awk -F '\t' -v ready="$READY_IDS" '
    NF < 5 || $2 == "done" { next }
    {
      id = $1; state = $2; kind = $3; repo = $4; title = $5; pri = $6; held = $7
      if (repo == "") repo = "-"
      if (held == "yes") g = "held"
      else if (state == "in_flight") g = "in_flight"
      else if (index(ready, " " id " ")) g = "ready"
      else g = "blocked"
      rank = (pri ~ /^[0-4]$/) ? pri : 5
      gord = (g == "in_flight") ? 1 : (g == "ready") ? 2 : (g == "blocked") ? 3 : 4
      # Decorated with a project sort key (`-` last) and the group order, then stripped.
      printf "%s\t%d\t%s\t%s\t%s\t%06d\t%s\t%s\t%s\t%s\n", (repo == "-" ? "~" : repo), gord, repo, g, rank, NR, id, kind, (pri == "" ? "-" : pri), title
    }
  ' | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -k5,5n -k6,6n | cut -f 3-
}

# project_counts: `<project>\t<ready>\t<in_flight>\t<blocked>\t<held>` per project.
project_counts() {
  classified_rows | awk -F '\t' '
    { p[$1] = 1; c[$1, $2]++ }
    END { for (k in p) printf "%s\t%d\t%d\t%d\t%d\n", k, c[k, "ready"], c[k, "in_flight"], c[k, "blocked"], c[k, "held"] }
  ' | LC_ALL=C sort
}

# short_lines: the SHORT lines for every active project below MIN_READY.
short_lines() {
  local name ready inflight blocked held
  while IFS="$(printf '\t')" read -r name ready inflight blocked held; do
    [ -n "$name" ] || continue
    [ "$name" != - ] || continue
    [ $((ready + inflight + blocked)) -gt 0 ] || continue
    [ "$ready" -lt "$MIN_READY" ] || continue
    printf 'SHORT %s ready=%s min=%s in_flight=%s blocked=%s held=%s\n' \
      "$name" "$ready" "$MIN_READY" "$inflight" "$blocked" "$held"
  done <<EOF
$(project_counts)
EOF
}

# --- plan ----------------------------------------------------------------------

print_plan() {  # <project-or-empty> <limit-or-empty>
  local only=$1 limit=$2 counts shorts
  counts=$(project_counts)
  shorts=$(short_lines)
  classified_rows | FM_LEDGER_COUNTS=$counts FM_LEDGER_SHORTS=$shorts awk -F '\t' -v only="$only" -v limit="$limit" '
    function header(p,   st) {
      st = (ready[p] + inf[p] + blk[p] > 0) ? "active" : "parked"
      printf "project %s %s ready=%d in_flight=%d blocked=%d held=%d%s\n", p, st, ready[p], inf[p], blk[p], hld[p], (p in short) ? " SHORT" : ""
    }
    function flush(p,   g) {
      if (p == "") return
      if (limit != "") {
        if (more > 0) printf "  (%d more ready)\n", more
        if (ids["blocked"] != "") printf "  blocked:%s\n", ids["blocked"]
        if (ids["held"] != "") printf "  held:%s\n", ids["held"]
      }
      delete ids; more = 0; shown = 0
    }
    BEGIN {
      n = split(ENVIRON["FM_LEDGER_COUNTS"], cl, "\n")
      for (i = 1; i <= n; i++) {
        split(cl[i], c, "\t")
        ready[c[1]] = c[2]; inf[c[1]] = c[3]; blk[c[1]] = c[4]; hld[c[1]] = c[5]
      }
      n = split(ENVIRON["FM_LEDGER_SHORTS"], sl, "\n")
      for (i = 1; i <= n; i++) { split(sl[i], s, " "); if (s[2] != "") short[s[2]] = 1 }
      cur = ""
    }
    only != "" && $1 != only { next }
    {
      if ($1 != cur) { flush(cur); cur = $1; header(cur); found = 1 }
      g = $2
      title = $8
      if (limit != "") {
        if (length(title) > 90 && title !~ / \[truncated\]$/) title = substr(title, 1, 90) " [truncated]"
        if (g == "blocked" || g == "held") { ids[g] = ids[g] " " $5; next }
        if (g == "ready") { if (shown >= limit + 0) { more++; next } shown++ }
      }
      printf "  %-9s %s  kind=%s priority=%s  %s\n", g, $5, $6, $7, title
    }
    END {
      flush(cur)
      if (!found) {
        if (only != "") printf "project %s: no open items\n", only
        else print "plan: no open items"
      }
    }
  '
}

cmd_plan() {
  local project='' limit=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) [ "$#" -ge 2 ] || usage_die "--project needs a value"; project=$2; shift 2 ;;
      --limit)
        [ "$#" -ge 2 ] || usage_die "--limit needs a value"
        case "$2" in '' | *[!0-9]*) usage_die "--limit must be a whole number" ;; esac
        limit=$2; shift 2
        ;;
      *) usage_die "plan: unknown argument: $1" ;;
    esac
  done
  load_config
  load_backlog
  printf 'PLAN at %s (ready target %s per active project; live view: bin/fm-ledger.sh plan)\n' \
    "$(iso_of "$(fm_now)")" "$MIN_READY"
  print_plan "$project" "$limit"
}

# --- next ----------------------------------------------------------------------

cmd_next() {
  local project='' row id kind pri repo
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) [ "$#" -ge 2 ] || usage_die "--project needs a value"; project=$2; shift 2 ;;
      *) usage_die "next: unknown argument: $1" ;;
    esac
  done
  load_backlog
  row=$(classified_rows | awk -F '\t' -v only="$project" '$2 == "ready" && (only == "" || $1 == only)' \
    | LC_ALL=C sort -t "$(printf '\t')" -k3,3n -k4,4n | head -n 1)
  if [ -z "$row" ]; then
    if [ -n "$project" ]; then
      printf 'next: nothing ready for project %s\n' "$project"
    else
      printf 'next: nothing ready\n'
    fi
    exit 3
  fi
  IFS="$(printf '\t')" read -r repo _ _ _ id kind pri _ <<EOF
$row
EOF
  printf 'NEXT %s project=%s kind=%s priority=%s\n' "$id" "$repo" "$kind" "$pri"
  tasks show "$id" --full
}

# --- claims --------------------------------------------------------------------

claim_init() {
  # Receipts bind the physical home spelling spawn resolves, never a
  # relative FM_HOME the caller happened to use.
  FM_HOME=$(cd "$FM_HOME" && pwd -P) || die "claim home is unavailable"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  # shellcheck source=bin/fm-secondmate-charter-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-charter-lib.sh"
  CLAIM_DIR="$STATE/ledger-claims"
  CLAIM_TASK_LOCK=
  CLAIM_META_LOCK=
  CLAIM_RELEASE_TMP=
  CLAIM_STAGE_TMP=
  [ ! -L "$CLAIM_DIR" ] || die "claim directory is a symlink"
  mkdir -p "$CLAIM_DIR" || die "cannot create claim directory"
  CLAIM_LOCK="$STATE/.ledger-claim.lock"
  fm_lock_acquire_wait "$CLAIM_LOCK" || die "cannot acquire claim lock"
  trap 'if [ -n "$CLAIM_RELEASE_TMP" ]; then rm -f "$CLAIM_RELEASE_TMP"; fi; if [ -n "$CLAIM_STAGE_TMP" ]; then rm -f "$CLAIM_STAGE_TMP" "$CLAIM_STAGE_TMP.next"; fi; if [ -n "$CLAIM_META_LOCK" ]; then fm_lock_release "$CLAIM_META_LOCK"; fi; if [ -n "$CLAIM_TASK_LOCK" ]; then fm_lock_release "$CLAIM_TASK_LOCK"; fi; fm_lock_release "$CLAIM_LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

claim_slug() {
  case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) die "invalid claim id or project: $1" ;; esac
}

claim_scope() {
  local projects home cfg
  # The grant must come from this home's own config directory: a config
  # path that resolves outside the physical home borrows another grant.
  home=$(cd "$FM_HOME" && pwd -P) || die "claim home is unavailable"
  cfg=$(cd "$CONFIG" && pwd -P) || die "claim config directory is unavailable"
  case "$cfg/" in "$home/"*) ;; *) die "claim config directory is outside this home" ;; esac
  projects=$(fm_secondmate_claim_projects "$CONFIG") || die "invalid claim-project configuration"
  printf '%s\n' "$projects" | grep -Fx -- "$1" >/dev/null || die "claims are not enabled for project $1 in this home"
}

claim_project_path() { # <project>: both the projects root and clone stay in this home
  local home projects path
  claim_slug "$1"
  home=$(cd "$FM_HOME" && pwd -P) || die "claim home is unavailable"
  projects=$(cd "${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}" && pwd -P) || die "claim projects root is unavailable"
  case "$projects/" in "$home/"*) ;; *) die "claim projects root is outside this home" ;; esac
  path=$(cd "$projects/$1" && pwd -P) || die "claim project is unavailable"
  case "$path/" in "$projects/"?*) ;; *) die "claim project escapes this home's projects root" ;; esac
  printf '%s\n' "$path"
}

claim_order_active() { # <source>
  local out rc=0
  case "$1" in
    order:*)
      out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" verify "${1#order:}") || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "claim source order cannot be read"
      case "$out" in
        "unacked ${1#order:} state=pending "*|"acked ${1#order:} state=acked") ;;
        *) die "claim source order is no longer active (done or parked): $out" ;;
      esac
      ;;
  esac
}

claim_holds_clear() {
  local holds
  holds=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-order.sh" holds --relay) || die "cannot read standing holds"
  [ -z "$holds" ] || die "standing holds require owner reconciliation before claiming"
}

claim_publication_authorized() { # <id> <project>; caller holds the claim lock
  local source
  source=$(awk -F '\t' -v id="$1" -v p="$2" '$4 == id && $5 == p { print $3 }' "$INTAKE_LOG") || die "cannot read claim source"
  valid_source "$source" || die "claim source changed before publication"
  claim_order_active "$source"
  # Keep this the final authority read before the atomic receipt publication.
  claim_holds_clear
}

claim_snapshot() { # <id> <project>; prints the exact approval-input digest
  local id=$1 project=$2 row source item body first open brief="$DATA/$1/brief.md"
  claim_scope "$project"
  claim_project_path "$project" >/dev/null || return 1
  load_backlog
  row=$(classified_rows | awk -F '\t' -v id="$id" -v p="$project" '$1 == p && $2 == "ready" && $5 == id { print }')
  [ -n "$row" ] || die "claim $id is no longer queued and ready in project $project"
  # tasks-axi ready may include an In-flight row; never adopt it.
  printf '%s\n' "$OPEN_ROWS" | awk -F '\t' -v id="$id" '$1 == id && $2 == "queued" { found=1 } END { exit !found }' || die "claim $id is not queued"
  row=$(awk -F '\t' -v id="$id" -v p="$project" '$4 == id && $5 == p { print }' "$INTAKE_LOG" 2>/dev/null) || die "claim $id has no ledger source"
  [ -n "$row" ] && [ "$(printf '%s\n' "$row" | wc -l | tr -d ' ')" = 1 ] || die "claim $id has no unique ledger source"
  source=$(printf '%s\n' "$row" | cut -f3)
  valid_source "$source" || die "claim $id has an invalid approval source"
  claim_order_active "$source"
  item=$(tasks show "$id" --full) || die "cannot read claim $id"
  body=$(printf '%s\n' "$item" | sed -n 's/^  body: //p' | head -n 1)
  case "$body" in
    \"*\") body=$(printf '%s' "$body" | jq -r 'if type == "string" then . else "" end' 2>/dev/null) || body='' ;;
  esac
  first=${body%%$'\n'*}
  [ "$first" = "Ledger source: $source" ] || die "claim $id approval source changed"
  [ -f "$brief" ] && [ -s "$brief" ] && [ -r "$brief" ] && [ ! -L "$brief" ] || die "claim $id needs a prepared brief"
  if [ -e "$STATE/$id.status" ] || [ -L "$STATE/$id.status" ]; then
    [ -f "$STATE/$id.status" ] && [ -r "$STATE/$id.status" ] && [ ! -L "$STATE/$id.status" ] || die "claim $id status is unreadable"
    open=$(status_open_decisions "$STATE/$id.status") || die "cannot read claim decisions"
    [ -z "$open" ] || die "claim $id has an open decision or blocker"
  fi
  claim_holds_clear
  "$SCRIPT_DIR/fm-task-budget.sh" prelaunch "$FM_HOME" >&2 || die "claim budget refused"
  { printf '%s\n' "$row" "$item"; cat "$brief"; } | shasum -a 256 | awk '{print $1}'
}

claim_read() {
  local file="$CLAIM_DIR/$1.json"
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || die "missing or unsafe claim receipt for $1"
  jq -e --arg id "$1" --arg home "$FM_HOME" '
    .version == 2 and .id == $id and .home == $home and
    (.token | type == "string" and test("^[a-f0-9]{32}$")) and
    (.snapshot | type == "string" and test("^[a-f0-9]{64}$")) and
    (.project | type == "string") and (.path | type == "string") and
    (.phase == "reserved" or .phase == "dispatching" or .phase == "launching" or .phase == "launched") and
    (if .phase == "reserved" or .phase == "dispatching" then .launch_attempted == false
     else .launch_attempted == true and (.endpoint_meta | type == "string" and length > 0) end)
  ' "$file" >/dev/null || die "invalid claim receipt for $1"
  CLAIM_PROJECT=$(jq -r .project "$file")
  CLAIM_TOKEN=$(jq -r .token "$file")
  CLAIM_PHASE=$(jq -r .phase "$file")
  CLAIM_PATH=$(jq -r .path "$file")
  CLAIM_SNAPSHOT=$(jq -r .snapshot "$file")
}

claim_print() {
  printf 'CLAIM %s project=%s phase=%s token=%s\n' "$1" "$CLAIM_PROJECT" "$CLAIM_PHASE" "$CLAIM_TOKEN"
}

claim_validate() {
  local snapshot path
  claim_slug "$CLAIM_PROJECT"
  path=$(claim_project_path "$CLAIM_PROJECT") || return 1
  [ "$path" = "$CLAIM_PATH" ] || die "claim project path changed"
  snapshot=$(claim_snapshot "$1" "$CLAIM_PROJECT") || return 1
  [ "$snapshot" = "$CLAIM_SNAPSHOT" ] || die "claim $1 approval inputs changed; owner reconciliation required"
}

cmd_claim() {
  local project='' resume='' id row path snapshot token file tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project|--resume)
        [ "$#" -ge 2 ] || usage_die "$1 needs a value"
        case "$1" in --project) project=$2 ;; --resume) resume=$2 ;; esac
        shift 2 ;;
      *) usage_die "claim: unknown argument: $1" ;;
    esac
  done
  claim_slug "$project"
  claim_init
  if [ -n "$resume" ]; then
    claim_slug "$resume"
    claim_read "$resume"
    [ "$project" = "$CLAIM_PROJECT" ] || die "claim belongs to another project"
    # A dispatch that never launched re-runs every authority check before
    # recovery may deliver its first worker; a launched dispatch is fenced
    # by its saved endpoint evidence instead.
    if [ "$CLAIM_PHASE" = reserved ] || [ "$CLAIM_PHASE" = dispatching ]; then claim_validate "$resume" || return 1; fi
    claim_print "$resume"
    if [ "$CLAIM_PHASE" = dispatching ] || [ "$CLAIM_PHASE" = launching ]; then
      printf 'claim %s: dispatch incomplete; use claim-release with the token if no task record remains, otherwise recover the existing task\n' "$resume" >&2
      return 4
    fi
    return 0
  fi
  claim_scope "$project"
  path=$(claim_project_path "$project") || return 1
  load_backlog
  while IFS=$'\t' read -r _ _ _ _ id _; do
    [ -n "$id" ] || continue
    claim_slug "$id"
    file="$CLAIM_DIR/$id.json"
    [ ! -e "$file" ] && [ ! -L "$file" ] || continue
    fm_lock_try_acquire "$STATE/.spawn-$id.lock" || continue
    CLAIM_TASK_LOCK="$STATE/.spawn-$id.lock"
    if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ] ||
      [ -e "$STATE/$id.backlog-close" ] || [ -L "$STATE/$id.backlog-close" ]; then
      fm_lock_release "$CLAIM_TASK_LOCK"; CLAIM_TASK_LOCK=; continue
    fi
    # Missing preparation or a held item parks only that item.
    if ! snapshot=$(claim_snapshot "$id" "$project"); then
      fm_lock_release "$CLAIM_TASK_LOCK"; CLAIM_TASK_LOCK=; continue
    fi
    path=$(claim_project_path "$project") || return 1
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#token}" = 32 ] || die "cannot create claim nonce"
    tmp=$(mktemp "$CLAIM_DIR/.receipt.XXXXXX") || die "cannot stage claim"
    CLAIM_STAGE_TMP=$tmp
    jq -n --arg id "$id" --arg home "$FM_HOME" --arg project "$project" --arg path "$path" --arg token "$token" --arg snapshot "$snapshot" \
      '{version:2,id:$id,home:$home,project:$project,path:$path,token:$token,snapshot:$snapshot,phase:"reserved",launch_attempted:false}' > "$tmp" || die "cannot stage claim"
    claim_publication_authorized "$id" "$project" || return 1
    mv "$tmp" "$file" || die "cannot publish claim"
    CLAIM_STAGE_TMP=
    claim_read "$id"
    claim_print "$id"
    return 0
  done <<EOF
$(classified_rows | awk -F '\t' -v p="$project" '$1 == p && $2 == "ready"' | LC_ALL=C sort -t "$(printf '\t')" -k3,3n -k4,4n)
EOF
  printf 'claim: nothing claimable for project %s\n' "$project"
  return 3
}

cmd_claim_spawn() { # <check|begin|launch|fence|finish> <id> <token> <project-path>
  local action=$1 id=$2 token=$3 path=$4 tmp
  claim_slug "$id"
  [ "$(cat "$STATE/.spawn-$id.lock/pid" 2>/dev/null)" = "$PPID" ] || die "claim transition requires the caller's spawn lock"
  claim_init
  if [ ! -e "$CLAIM_DIR/$id.json" ] && [ ! -L "$CLAIM_DIR/$id.json" ]; then
    [ -z "$token" ] && [ "$action" = check ] && return 0
    die "no claim receipt for $id"
  fi
  claim_read "$id"
  [ -n "$token" ] && [ "$token" = "$CLAIM_TOKEN" ] || die "task $id is reserved; its claim token is required"
  path=$(cd "$path" && pwd -P) || die "claim project is unavailable"
  [ "$path" = "$CLAIM_PATH" ] || die "task $id claim belongs to another project path"
  [ "$(claim_project_path "$CLAIM_PROJECT")" = "$path" ] || die "claim project path is outside its approved home"
  if [ "$action" = fence ]; then
    # Final authority read at the point of delivery: a hold or revocation
    # published after the launch fence still refuses the worker launch.
    # Read-only under the claim lock; the receipt does not move.
    [ "$CLAIM_PHASE" = launching ] || die "claim $id is not launching"
    claim_publication_authorized "$id" "$CLAIM_PROJECT" || return 1
    return 0
  fi
  if [ "$action" = finish ]; then
    [ "$CLAIM_PHASE" = launching ] || die "claim $id is not launching"
    [ -f "$STATE/$id.meta" ] || die "claim $id has no task record"
    CLAIM_PHASE=launched
  elif [ "$action" = launch ]; then
    [ "$CLAIM_PHASE" = dispatching ] || die "claim $id is not dispatching"
    [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || die "claim $id needs its endpoint record before launch"
    claim_validate "$id" || return 1
    CLAIM_PHASE=launching
  else
    [ "$CLAIM_PHASE" = reserved ] || die "claim $id is $CLAIM_PHASE; use task recovery, never repeat fresh spawn"
    claim_validate "$id" || return 1
    [ "$action" = begin ] || return 0
    CLAIM_PHASE=dispatching
  fi
  tmp=$(mktemp "$CLAIM_DIR/.receipt.XXXXXX") || die "cannot stage claim transition"
  CLAIM_STAGE_TMP=$tmp
  jq --arg phase "$CLAIM_PHASE" '.phase=$phase' "$CLAIM_DIR/$id.json" > "$tmp" || die "cannot stage claim transition"
  if [ "$action" = launch ]; then
    jq --rawfile endpoint "$STATE/$id.meta" '.launch_attempted=true | .endpoint_meta=$endpoint' "$tmp" > "$tmp.next" || die "cannot stage launch fence"
    mv "$tmp.next" "$tmp" || die "cannot publish launch fence stage"
  fi
  if [ "$action" != finish ]; then claim_publication_authorized "$id" "$CLAIM_PROJECT" || return 1; fi
  mv "$tmp" "$CLAIM_DIR/$id.json" || die "cannot publish claim transition"
  CLAIM_STAGE_TMP=
}

cmd_claim_release() { # <id> --token <nonce>
  [ "$#" = 3 ] && [ "$2" = --token ] || usage_die "claim-release <id> --token <nonce>"
  local id=$1 token=$3 attempted saved backend target wt absence pids archive
  [ -z "${FM_TASK_ID:-}" ] && [ "${FM_SUPERVISION_ACTOR:-main}" = main ] || die "claim-release is supervisor-only"
  claim_slug "$id"
  claim_init
  fm_lock_try_acquire "$STATE/.spawn-$id.lock" || die "claim $id has an active dispatcher"
  CLAIM_TASK_LOCK="$STATE/.spawn-$id.lock"
  fm_lock_try_acquire "$STATE/.meta-$id.lock" || die "claim $id has an active lifecycle operation"
  CLAIM_META_LOCK="$STATE/.meta-$id.lock"
  claim_read "$id"
  [ "$token" = "$CLAIM_TOKEN" ] || die "claim-release token does not match the current reservation"
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || die "claim $id still has a task record; use normal task recovery or teardown"
  [ ! -e "$STATE/$id.backlog-close" ] && [ ! -L "$STATE/$id.backlog-close" ] || die "claim $id has a pending backlog close"
  attempted=$(jq -r .launch_attempted "$CLAIM_DIR/$id.json")
  if [ "$attempted" != false ]; then
    # Preserve uncertain delivery. Only the existing backend absence proof plus
    # the worktree-process check can retire a receipt after worker delivery.
    saved=$(mktemp "$CLAIM_DIR/.release-$id.XXXXXX") || die "cannot stage endpoint proof"
    CLAIM_RELEASE_TMP=$saved
    jq -er '.endpoint_meta | select(type == "string" and length > 0)' "$CLAIM_DIR/$id.json" > "$saved" || die "claim has no endpoint evidence"
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    # shellcheck source=bin/fm-control-lib.sh
    . "$SCRIPT_DIR/fm-control-lib.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    fm_backend_validate_task_endpoint "$saved" "$id" >/dev/null || die "claim endpoint evidence is invalid"
    backend=$FM_BACKEND_VALIDATED_BACKEND target=$FM_BACKEND_VALIDATED_TARGET
    wt=$(fm_backend_meta_exact_value "$saved" worktree) || die "claim worktree evidence is missing"
    if [ "$backend" = orca ]; then
      absence=$(fm_control_endpoint_absence_verdict "$backend" "$target" "$wt" "$saved")
    else
      absence=$(fm_control_endpoint_absence_verdict "$backend" "$target" "$saved")
    fi
    rm -f "$saved"
    CLAIM_RELEASE_TMP=
    case "$absence" in gone$'\t'*) ;; *) die "claim endpoint absence is not proven: $absence" ;; esac
    # shellcheck disable=SC2016 # parameters belong to the bounded child
    pids=$(fm_run_timed 20 bash -c '. "$1/fm-bash-compat-lib.sh"; . "$1/fm-control-lib.sh"; fm_control_pids_with_cwd_under "$2"' _ "$SCRIPT_DIR" "$wt") || die "claim worktree process absence is not proven"
    [ -z "$pids" ] || die "claim worktree still has processes"
  fi
  archive="$CLAIM_DIR/released"
  [ ! -L "$archive" ] || die "claim release archive is a symlink"
  mkdir -p "$archive" || die "cannot create claim release archive"
  [ ! -e "$archive/$id-$token.json" ] && [ ! -L "$archive/$id-$token.json" ] || die "claim release archive already exists"
  mv "$CLAIM_DIR/$id.json" "$archive/$id-$token.json" || die "cannot archive released claim"
  printf 'RELEASED %s token=%s; claim again to recheck approval with a new token\n' "$id" "$token"
}

# --- intake --------------------------------------------------------------------

valid_source() {
  case "$1" in
    order:* | proposal:* | goal:* | ask:*) ;;
    *) return 1 ;;
  esac
  case "${1#*:}" in '' | *[!A-Za-z0-9._:/#-]*) return 1 ;; esac
  return 0
}

# intake_replay_id <source> <project> <title> <id-or-empty>: an existing item
# filed from this source for this project with this title (and this id, when
# one is given). The values reach awk through ENVIRON so backslashes stay literal.
intake_replay_id() {
  local id
  [ -f "$INTAKE_LOG" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    tasks show "$id" >/dev/null 2>&1 || continue
    printf '%s\n' "$id"
    return 0
  done <<EOF
$(FM_LEDGER_S=$1 FM_LEDGER_P=$2 FM_LEDGER_T=$(clean "$3") FM_LEDGER_I=$4 awk -F '\t' '
  $3 == ENVIRON["FM_LEDGER_S"] && $5 == ENVIRON["FM_LEDGER_P"] && $6 == ENVIRON["FM_LEDGER_T"] &&
    (ENVIRON["FM_LEDGER_I"] == "" || $4 == ENVIRON["FM_LEDGER_I"]) { print $4 }' "$INTAKE_LOG")
EOF
  return 1
}

record_intake() {  # <source> <item-id> <project> <title>
  local now
  now=$(fm_now)
  mkdir -p "$DATA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(iso_of "$now")" "$now" "$1" "$2" "$3" "$(clean "$4")" >> "$INTAKE_LOG"
}

cmd_intake() {
  # The intake log is the recorded approval a claim later verifies against,
  # so only a supervisor session may write it; a worker filing its own
  # proposal reference would be supplying its own approval evidence.
  [ -z "${FM_TASK_ID:-}" ] || die "intake is supervisor-only"
  local id='' mint=0 project='' title='' source='' kind='' priority='' body='' body_file='' have_body=0
  local -a blocked=() args=()
  local out new_id tmp already first repo got_title
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mint) mint=1; shift ;;
      --project | --title | --source | --kind | --priority | --blocked-by | --body | --body-file)
        [ "$#" -ge 2 ] || usage_die "$1 needs a value"
        case "$1" in
          --project) project=$2 ;;
          --title) title=$2 ;;
          --source) source=$2 ;;
          --kind) kind=$2 ;;
          --priority) priority=$2 ;;
          --blocked-by) blocked+=("$2") ;;
          --body) body=$2; have_body=$((have_body + 1)) ;;
          --body-file) body_file=$2; have_body=$((have_body + 1)) ;;
        esac
        shift 2
        ;;
      -*) usage_die "intake: unknown argument: $1" ;;
      *)
        [ -z "$id" ] || usage_die "intake: more than one item id"
        id=$1; shift
        ;;
    esac
  done
  { [ -n "$id" ] && [ "$mint" = 0 ]; } || { [ -z "$id" ] && [ "$mint" = 1 ]; } \
    || usage_die "intake needs exactly one of <id> or --mint"
  [ -z "$id" ] || case "$id" in *[!A-Za-z0-9._-]*) usage_die "intake: item id must match [A-Za-z0-9._-]+" ;; esac
  case "$project" in '' | *[!A-Za-z0-9._-]*) usage_die "intake needs --project <name> matching [A-Za-z0-9._-]+" ;; esac
  case "$title" in *[![:space:]]*) ;; *) usage_die "intake needs a non-empty --title" ;; esac
  valid_source "$source" || usage_die "intake needs --source order:|proposal:|goal:|ask:<ref> with <ref> matching [A-Za-z0-9._:/#-]+"
  [ -z "$priority" ] || case "$priority" in [0-4]) ;; *) usage_die "--priority must be 0-4" ;; esac
  [ "$have_body" -le 1 ] || usage_die "intake takes at most one of --body or --body-file"
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] && [ -r "$body_file" ] || die "body file is unreadable: $body_file"
    body=$(cat "$body_file") || die "body file is unreadable: $body_file"
  fi
  case "$source" in
    order:*)
      FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-order.sh" status "${source#order:}" >/dev/null 2>&1 \
        || die "no captain order ${source#order:} in this home"
      ;;
    goal:*)
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-dispatch-log.sh" show "${source#goal:}" >/dev/null 2>&1 \
        || die "no captain goal ${source#goal:} in the dispatch ledger"
      ;;
  esac
  if new_id=$(intake_replay_id "$source" "$project" "$title" "$id"); then
    printf 'replay %s\n' "$new_id"
    return 0
  fi
  if [ -n "$id" ]; then args=(add "$id" "$title"); else args=(add "$title" --mint); fi
  args+=(--queue --repo "$project")
  [ -z "$kind" ] || args+=(--kind "$kind")
  [ -z "$priority" ] || args+=(--priority "$priority")
  if [ "${#blocked[@]}" -gt 0 ]; then
    for b in "${blocked[@]}"; do args+=(--blocked-by "$b"); done
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-ledger-body.XXXXXX") || die "could not stage the item body"
  if [ -n "$body" ]; then
    printf 'Ledger source: %s\n%s\n' "$source" "$body" > "$tmp"
  else
    printf 'Ledger source: %s\n' "$source" > "$tmp"
  fi
  args+=(--body-file "$tmp" --json)
  out=$(tasks "${args[@]}" 2>&1)
  local rc=$?
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || die "backlog add failed: $(clean "$out")"
  new_id=$(printf '%s' "$out" | jq -r '.id // .task.id // empty' 2>/dev/null)
  [ -n "$new_id" ] || new_id=$id
  [ -n "$new_id" ] || die "backlog add printed no item id: $(clean "$out")"
  already=$(printf '%s' "$out" | jq -r '.already // false' 2>/dev/null)
  if [ "$already" = true ]; then
    # tasks-axi left an existing item unchanged. It is this ask only when an
    # earlier intake filed it and stopped before its intake record was written:
    # same project, same title, and a body that starts with this source.
    repo=$(printf '%s' "$out" | jq -r '.task.repo // empty' 2>/dev/null)
    got_title=$(printf '%s' "$out" | jq -r '.task.title // empty' 2>/dev/null)
    first=$(printf '%s' "$out" | jq -r '.task.body // empty' 2>/dev/null | sed -n 1p)
    if [ "$repo" = "$project" ] && [ "$(clean "$got_title")" = "$(clean "$title")" ] \
      && [ "$first" = "Ledger source: $source" ]; then
      record_intake "$source" "$new_id" "$project" "$title" \
        || die "item $new_id exists, but the intake record could not be written to $INTAKE_LOG"
      printf 'replay %s\n' "$new_id"
      return 0
    fi
    die "item $new_id already exists and was left unchanged, so this ask is not filed; use another id or --mint"
  fi
  record_intake "$source" "$new_id" "$project" "$title" \
    || die "item $new_id was filed, but the intake record could not be written to $INTAKE_LOG"
  printf 'filed %s project=%s source=%s\n' "$new_id" "$project" "$source"
}

# --- unfiled orders ------------------------------------------------------------

unfiled_lines() {
  local status known id state kind summary out suffix
  status=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-order.sh" status 2>&1) || die "captain order read failed: $(clean "$status")"
  [ "$status" != 'no open orders' ] || return 0
  known=
  if [ -f "$INTAKE_LOG" ]; then
    known=$(awk -F '\t' '$3 ~ /^order:/ { sub(/^order:/, "", $3); print $3 }' "$INTAKE_LOG")
  fi
  out=$(tasks list --fields body 2>&1) || die "backlog read failed: $(clean "$out")"
  known="$known
$out"
  printf '%s\n' "$status" | while IFS= read -r line; do
    id=${line%% *}
    case "$id" in *[!0-9a-f-]* | '') continue ;; esac
    state=$(printf '%s' "$line" | awk '{ print $2 }')
    kind=$(printf '%s' "${line%% :: *}" | sed -n 's/.* kind=\([a-z]*\).*/\1/p')
    [ "$kind" = order ] || continue
    printf '%s\n' "$known" | grep -qF -- "$id" && continue
    # Items written before the ledger often name an order by its 8-hex suffix alone.
    suffix=${id##*-}
    case "$suffix" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        printf '%s\n' "$known" | grep -qE "(^|[^0-9a-f])$suffix([^0-9a-f]|\$)" && continue
        ;;
    esac
    summary=${line#* :: }
    [ "$summary" != "$line" ] || summary=
    printf 'UNFILED %s %s :: %s\n' "$id" "$state" "$summary"
  done
}

cmd_unfiled() {
  local out
  [ "$#" -eq 0 ] || usage_die "usage: fm-ledger.sh unfiled"
  out=$(unfiled_lines) || exit 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  exit 3
}

# --- depth ---------------------------------------------------------------------

cmd_depth() {
  local out
  load_config
  load_backlog
  out=$(short_lines)
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 3
  fi
  printf 'ready-depth: ok (every active project has at least %s ready)\n' "$MIN_READY"
}

# latest_slot <now>: print "<epoch> <HH:MM>" of the newest scheduled time at or
# before now, looking at today and yesterday in the captain's zone.
latest_slot() {
  local now=$1 zone file day d s rest best=0 label='' e
  zone=$(_fm_qh_zone)
  # The same zoneinfo check bin/fm-quiet-hours-lib.sh applies: an unknown zone
  # would otherwise read silently as UTC.
  file="${TZDIR:-/usr/share/zoneinfo}/$zone"
  case "$zone" in /* | *..*) return 1 ;; esac
  [ -f "$file" ] && [ "$(head -c 4 "$file" 2>/dev/null)" = TZif ] || return 1
  for d in 0 -1; do
    day=$(_fm_qh_day "$zone" "$now" "$d") || return 1
    rest=$SLOTS
    while [ -n "$rest" ]; do
      s=${rest%%,*}
      case "$rest" in *,*) rest=${rest#*,} ;; *) rest= ;; esac
      e=$(_fm_qh_epoch "$zone" "$day" "$s:00") || return 1
      if [ "$e" -le "$now" ] && [ "$e" -gt "$best" ]; then
        best=$e
        label=$s
      fi
    done
  done
  printf '%s %s\n' "$best" "$label"
}

report_error_once() {  # <message>
  local msg=$1
  [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ] && return 0
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf '%s\n' "$msg"
}

cmd_depth_scheduled() {
  local now slot epoch label last out rc names count
  load_config
  [ "$MIN_READY" -gt 0 ] || return 0
  [ -d "$STATE" ] || return 0
  now=$(fm_now)
  if ! slot=$(latest_slot "$now" 2>/dev/null) || [ -z "$slot" ]; then
    report_error_once "ready-depth: could not compute the scheduled times in zone $(_fm_qh_zone); check quiet-hours-zone in config/escalation"
    return 0
  fi
  epoch=${slot%% *}
  label=${slot#* }
  [ "$epoch" -gt 0 ] || return 0
  last=$(cat "$SLOT_FILE" 2>/dev/null)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ "$last" -lt "$epoch" ] || return 0
  if [ $((now - epoch)) -gt "$SLOT_GRACE" ]; then
    printf '%s\n' "$epoch" > "$SLOT_FILE"
    return 0
  fi
  # The slot is recorded only once an evaluation completes, so a failed or
  # interrupted one is retried on the next sweep instead of being lost.
  rc=0
  out=$("$0" depth 2>&1) || rc=$?
  case "$rc" in
    0 | 3) ;;
    *) report_error_once "ready-depth $label: the depth check failed: $(clean "$out")"; return 0 ;;
  esac
  printf '%s\n' "$epoch" > "$SLOT_FILE" || return 0
  rm -f "$ERROR_FILE"
  [ "$rc" -eq 3 ] || return 0
  count=$(printf '%s\n' "$out" | grep -c '^SHORT ')
  names=$(printf '%s\n' "$out" | awk '/^SHORT / { sub(/^ready=/, "", $3); printf " %s(ready=%s)", $2, $3 }')
  printf 'ready-depth %s: %s active project(s) below %s ready:%s; refill each ready queue (bin/fm-ledger.sh plan)\n' \
    "$label" "$count" "$MIN_READY" "$names"
}

# --- handoff -------------------------------------------------------------------

cmd_handoff() {
  local doc='' note='' note_file='' have_note=0 lines bytes unfiled goals plan dir tmp rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --doc) [ "$#" -ge 2 ] || usage_die "--doc needs a value"; doc=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || usage_die "--note needs a value"; note=$2; have_note=$((have_note + 1)); shift 2 ;;
      --note-file) [ "$#" -ge 2 ] || usage_die "--note-file needs a value"; note_file=$2; have_note=$((have_note + 1)); shift 2 ;;
      *) usage_die "handoff: unknown argument: $1" ;;
    esac
  done
  [ -n "$doc" ] || usage_die "handoff needs --doc <file>"
  [ "$have_note" -eq 1 ] || usage_die "handoff needs exactly one of --note or --note-file"
  if [ -n "$note_file" ]; then
    if [ "$note_file" = - ]; then
      note=$(cat) || die "could not read the note from stdin"
    else
      [ -f "$note_file" ] && [ -r "$note_file" ] || die "note file is unreadable: $note_file"
      note=$(cat "$note_file") || die "note file is unreadable: $note_file"
    fi
  fi
  case "$note" in *[![:space:]]*) ;; *) die "the in-flight note is empty; say what is in flight right now" ;; esac
  lines=$(printf '%s\n' "$note" | awk 'END { print NR }')
  bytes=$(printf '%s' "$note" | wc -c | tr -d ' ')
  [ "$lines" -le "$NOTE_MAX_LINES" ] && [ "$bytes" -le "$NOTE_MAX_BYTES" ] \
    || die "the in-flight note is $lines lines and $bytes bytes; keep it within $NOTE_MAX_LINES lines and $NOTE_MAX_BYTES bytes and file durable facts as ledger items (bin/fm-ledger.sh intake, or bin/fm-tasks-axi.sh update)"
  if printf '%s' "$note" | grep -Eq 'handoff-[0-9]{8}T?[0-9]{2,6}Z?'; then
    die "the in-flight note names an earlier handoff document; a handoff never continues another one - file what that document still carries as ledger items and drop the reference"
  fi
  [ ! -e "$doc" ] && [ ! -L "$doc" ] || die "the handoff document already exists: $doc; write a new one"
  rc=0
  unfiled=$(unfiled_lines) || rc=$?
  [ "$rc" -eq 0 ] || exit 1
  if [ -n "$unfiled" ]; then
    printf '%s\n' "$unfiled"
    printf 'fm-ledger: handoff refused: file each open order above as its own ledger item first (bin/fm-ledger.sh intake <id> --project <name> --title <text> --source order:<order-id>)\n' >&2
    exit 3
  fi
  plan=$("$0" plan --limit 3 2>&1) || die "the plan could not be read: $(clean "$plan")"
  goals=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-dispatch-log.sh" open 2>&1) \
    || die "the dispatch ledger could not be read: $(clean "$goals")"
  [ -n "$goals" ] || goals='none open'
  mkdir -p "$(dirname "$doc")" || die "could not create the handoff directory"
  dir=$(cd "$(dirname "$doc")" && pwd) || die "could not resolve the handoff directory"
  doc="$dir/${doc##*/}"
  tmp=$(mktemp "$dir/.fm-ledger-handoff.XXXXXX") || die "could not stage the handoff document"
  {
    printf '# Session handoff %s (%s)\n\n' "$(iso_of "$(fm_now)")" "${FM_HOME##*/}"
    printf 'Written by bin/fm-ledger.sh handoff from the mission ledger.\n'
    printf 'The ledger is authoritative and this document is complete on its own: it never continues an earlier handoff.\n'
    printf 'Read live state with bin/fm-ledger.sh plan, bin/fm-dispatch-log.sh open, and bin/fm-order.sh pickup.\n\n'
    printf '## In flight now\n\n%s\n\n' "$note"
    printf '## Ledger plan at handoff\n\n%s\n\n' "$plan"
    printf '## Open captain goals at handoff\n\n%s\n' "$goals"
  } > "$tmp" || { rm -f "$tmp"; die "could not write the handoff document"; }
  mv "$tmp" "$doc" || { rm -f "$tmp"; die "could not place the handoff document"; }
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-order.sh" handoff --doc "$doc" \
    || die "wrote $doc, but bin/fm-order.sh handoff --doc failed, so the open orders are not recorded in it"
  # The reset audit's "before" snapshot is taken now, while the ledger is
  # current. It never fails the handoff.
  if [ -x "$SCRIPT_DIR/fm-reset-audit.sh" ]; then
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-reset-audit.sh" refresh >/dev/null 2>&1 || true
  fi
  printf 'handoff: wrote %s from the ledger\n' "$doc"
}

# --- arm -----------------------------------------------------------------------

cmd_arm() {
  local device staged
  local -a shim
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  if [ "${1:-}" = --if-enabled ]; then
    load_config
    if [ "$MIN_READY" -eq 0 ]; then
      if [ -e "$STATE/$CHECK_ID.check.sh" ] || [ -e "$STATE/$CHECK_ID.check-trust" ]; then
        cmd_disarm
      fi
      return 0
    fi
  elif [ "$#" -gt 0 ]; then
    usage_die "usage: fm-ledger.sh arm [--if-enabled]"
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable: $STATE"
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable: $STATE"
  fm_pr_regular_destination_on_device_or_absent "$STATE/$CHECK_ID.check.sh" "$device" \
    || die "unsafe check destination: $STATE/$CHECK_ID.check.sh"
  ledger_check_owned_or_absent \
    || die "$STATE/$CHECK_ID.check.sh exists and is not the mission ledger's check (a task named $CHECK_ID may own it); left unchanged"
  shim=('#!/usr/bin/env bash'
    "$CHECK_MARK"
    "export FM_HOME=$(printf '%q' "$FM_HOME")"
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")"
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")"
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")"
    "exec $(printf '%q' "$SCRIPT_DIR/fm-ledger.sh") depth --scheduled")
  staged=$(umask 077; mktemp "$STATE/.ready-depth-check.XXXXXX") || die "could not stage the check"
  if ! { printf '%s\n' "${shim[@]}" > "$staged" && chmod 700 "$staged" \
    && mv -f -- "$staged" "$STATE/$CHECK_ID.check.sh"; }; then
    rm -f "$staged"
    die "could not install the check"
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID"
}

# ledger_check_owned_or_absent: true when state/<check>.check.sh is absent or
# carries this command's ownership mark. The check id is also a valid task id,
# so a task's own check (such as its PR monitor) may hold the same path.
ledger_check_owned_or_absent() {
  local check="$STATE/$CHECK_ID.check.sh"
  [ -e "$check" ] || [ -L "$check" ] || return 0
  [ -f "$check" ] && [ ! -L "$check" ] && sed -n 2p "$check" 2>/dev/null | grep -qxF -- "$CHECK_MARK"
}

cmd_disarm() {
  if ! ledger_check_owned_or_absent; then
    printf 'fm-ledger: %s is not the mission ledger check; left unchanged\n' "$STATE/$CHECK_ID.check.sh" >&2
    return 0
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID"
}

# --- dispatch ------------------------------------------------------------------

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  intake) shift; cmd_intake "$@" ;;
  unfiled) shift; cmd_unfiled "$@" ;;
  plan) shift; cmd_plan "$@" ;;
  next) shift; cmd_next "$@" ;;
  claim) shift; cmd_claim "$@" ;;
  claim-release) shift; cmd_claim_release "$@" ;;
  claim-check|claim-begin|claim-launch|claim-fence|claim-finish)
    action=${1#claim-}; shift
    [ "$#" -eq 3 ] || usage_die "claim transition needs id, token and project path"
    cmd_claim_spawn "$action" "$@"
    ;;
  depth)
    shift
    case "$*" in
      '') cmd_depth ;;
      --scheduled) cmd_depth_scheduled ;;
      *) usage_die "usage: fm-ledger.sh depth [--scheduled]" ;;
    esac
    ;;
  handoff) shift; cmd_handoff "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  disarm) shift; [ "$#" -eq 0 ] || usage_die "usage: fm-ledger.sh disarm"; cmd_disarm ;;
  *) usage >&2; exit 2 ;;
esac
