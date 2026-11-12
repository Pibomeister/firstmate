#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read docs/learnings/overnight-learnings.md,
# data/projects.md, data/secondmates.md, data/captain.md,
# data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status. The digest now prints one line per live task and
# points at bin/fm-crew-state.sh for full detail.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# fm-wake-drain.sh, and fm-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   0. bash check    - one warning when this bash, or the bash PATH selects,
#                       has the Darwin here-document hang; it runs before the
#                       lock and bootstrap skips its own copy
#                       (bin/fm-bash-compat-lib.sh owns the check).
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   1b. home role    - the resolved firstmate-repository role line
#                      (bin/fm-role.sh report), purely local, no network.
#                      After it, a full locked start that is not a re-emit
#                      runs the watchdog's monitor read once when this home's
#                      watchdog unit is not enabled (docs/watchdog.md).
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run, including
#                       `SHARED_STATE: global git config changed since the last
#                       session start (<detail>) - ...` and
#                       `SHARED_STATE: shared no-mistakes database schema
#                       changed since the last session start (<detail>) - ...`
#                       against state/.session-start-shared-baseline for global
#                       git config and the shared no-mistakes state database
#                       schema (sqlite_master excluding sqlite_* internal
#                       objects, plus PRAGMA user_version) since the last
#                       locked session start. Only a full locked start whose
#                       git and database snapshots both succeed updates the
#                       baseline; system git config and per-clone .git/config
#                       files are not watched, although the brief rule forbids
#                       all four git config locations. Bootstrap's seven
#                       MUTATING sweeps
#                       (same-home backlog reconciliation, home code drift,
#                       secondmate convergence, secondmate liveness, pending remote
#                       handoff retry, X-mode artifact writes, fleet sync) also run only when
#                       locked; the five network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. wake-drain     - presents durable wakes and advances recovery handling
#                       state, so it only runs when locked. The local bounded
#                       inactive-outcome startup scan runs in the deferred worker.
#                       First, on every harness and away posture, it seeds the
#                       outcome store's display tail copy when that is absent
#                       (bin/fm-branch-outcome.sh seed-tail). Every locked
#                       start, including a clear or compact, then records this
#                       session as the current captain handle and clears the
#                       handoff record, and every start prints a CAPTAIN ORDERS section
#                       when durable orders are open (bin/fm-order.sh).
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       one line per live task (id, project, last recorded
#                       state, recorded PR URL, age, and a bounded per-task
#                       endpoint-liveness read folded into that same line),
#                       one line per orphan status log, the away posture
#                       (state/.afk-contract and the legacy state/.afk daemon
#                       flag): read-only, always runs. Full per-task detail
#                       stays on demand (bin/fm-crew-state.sh <id> for the
#                       reconciled state; the raw state/<id>.meta and
#                       state/<id>.status files for the records). The
#                       per-task endpoint reads run serially, so with a
#                       wedged backend the stage's ceiling is tasks x the
#                       per-read bound (FM_SESSION_START_ENDPOINT_TIMEOUT,
#                       default 10s) and can itself reach the digest's
#                       runtime bound. It ends with the dispatch ledger's
#                       `overdue` lines, when any (bin/fm-dispatch-log.sh).
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - docs/learnings/overnight-learnings.md, data/projects.md,
#                       data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md, each in full
#                       when small and indexed when large (see SIZE BUDGET):
#                       read-only, always safe, always runs.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# Those ten names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran - and the parent banners
# EVERY nonzero child exit, not only the bound: a child that dies or is killed
# mid-stage must never truncate the digest silently.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the captain
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote secondmate could burn the
# entire FM_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The ones that did - `gh auth status`, the home code drift fetch and
# guarded fast-forward (bin/fm-bootstrap.sh home_code_drift, reusing
# bin/fm-ff-lib.sh origin mode), secondmate liveness, secondmate
# convergence, pending remote handoff delivery, and the fleet-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 7 without ever blocking on it. The bounded inactive-outcome
# startup scan joins that worker because its local current-state reads can also
# be slow. bin/fm-startup-network.sh owns that stage and its safety argument;
# bin/fm-bootstrap.sh and bin/fm-inactive-reconcile.sh remain the owners of the
# work itself and still run it.
# The digest is therefore composed from bounded local reads and local
# subprocesses only, while slow network or inactive-state reconciliation delays
# a reported check rather than startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# ORDERING, and why FLEET STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a captain-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live fleet identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So fleet state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes and receiver wakes, writing
# X-mode artifacts, and fetching or fast-forwarding every project clone - before
# ever discovering another session already holds the lock. Two sessions racing
# those sweeps is exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, tasks-axi and quota-axi
# tool checks, and tasks-axi availability - none of which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the seven bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - `done` rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/fm-bearings-snapshot.sh, /ahoy), and at startup it
#     is pure weight - 10 done rows cost 3.3KB in an observed main-home digest.
#   - Every held and blocked row is listed, with its hold_kind/hold_reason and
#     blocked_by. Those are the rows AGENTS.md sections 7 and 10 make
#     actionable at startup, so they are never bounded away. A hold reason is
#     captain-decision context, so these rows are cut only past
#     BACKLOG_DECISION_ROW_MAX characters, with a [truncated] marker; the id
#     that leads each row always survives.
#   - A field tasks-axi already cut keeps a short [truncated] marker in place of
#     the tool's long show-command note, which the listing header names once.
#   - An in-flight row is listed once: one the held group already lists, or a
#     plain one (no hold, no blocked_by) whose state/<id>.meta exists, is left
#     out of the in-flight group, and its id is named in a disclosure line,
#     because the held group or Work under way prints it.
#   - Only the plain queued (dispatchable-now) listing is bounded, by
#     FM_SESSION_START_QUEUED_LIMIT, default 5. Anything it omits is disclosed
#     with an exact remainder count and the command that shows the rest, so a
#     deep queue costs a counter rather than kilobytes.
#     (This replaces FM_SESSION_START_BACKLOG_LIMIT, which bounded the whole
#     listing indiscriminately and so could drop a held or blocked row.)
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body. The groups are the tool's own filters
# (`--state in_flight`, `--state held`, `--state queued --blocked`, and
# `tasks-axi ready`), so this script never reimplements task state; an
# in-flight item that is also held is printed under held only.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest; the same never-bound-a-held-or-blocked-row
# rule applies, recognized there from the title line's own hold/blocked-by
# markers, and the same BACKLOG_DECISION_ROW_MAX / BACKLOG_ROW_MAX cuts apply.
# Full bodies are targeted follow-up only: `bin/fm-tasks-axi.sh show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# WORK-UNDER-WAY LINES: the fleet digest prints exactly one line per live
# task - id, project, last recorded state word, recorded PR URL, age, and the
# endpoint verdict - instead of the full meta body plus a status tail it used
# to re-print. A status line is a wake EVENT rather than current state
# (AGENTS.md section 8), so the state word is only the last recorded event;
# bin/fm-crew-state.sh <id> owns the reconciled current state, and the raw
# state/<id>.meta and state/<id>.status files hold the full records. The
# section header prints that pointer once, so no per-task tail is needed.
# A stale task - endpoint dead or unknown, no recorded PR, and at least
# STALE_TASK_DAYS old - is condensed to an id:state:age:endpoint entry on one
# shared line, so long-dead work costs a few words while staying visible to
# recovery.
#
# SIZE BUDGET: every primary handoff pays this digest, so on a large home it
# stays under 30 KB (tests/fm-session-start.test.sh pins that on a fixture
# home). Nothing safety-relevant is cut to get there: the lock verdict, CAPTAIN
# ORDERS, every wake record, OPEN DECISIONS, UNREAD STATUS, the
# WAKE_ACK_REQUIRED line, actionable diagnostics, and every live task id print
# in every case. Long, stable material is summarized or pointed at instead:
#   - A CONTEXT file over FM_SESSION_START_CONTEXT_INLINE_MAX bytes (default
#     2048) is INDEXED: its absolute path, size, and a line-numbered outline of
#     its headings, or of its list items when it has at most a title heading,
#     print instead of its text; the outline stops at CONTEXT_OUTLINE_MAX bytes.
#     The two learnings files print the pointer line alone.
#   - A wake presentation over FM_SESSION_START_WAKE_INLINE_MAX bytes (default
#     8000) is saved whole to state/.session-start-wake-presentation first, and
#     only then does the inline copy keep one non-historical latest-event
#     `wake annotation:` line per status file (capped at 320 characters), leave
#     out the earlier unread, repeated, and historical annotation lines and all
#     but the first five OPEN DECISIONS and STATUS OUTCOME BACKSTOP items, with
#     their counts and that path; if the save fails, nothing is left out.
#   - The backlog and Work under way bounds are the BACKLOG DIGEST and
#     WORK-UNDER-WAY notes above.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/fm-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes and the backlog
# listing are unbounded subprocesses, while each per-task endpoint read runs
# in its own crash-isolated child under FM_SESSION_START_ENDPOINT_TIMEOUT
# (default 10s). So the whole digest still runs as ONE bounded child of this
# script (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the child stopped is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner on ANY nonzero child exit - the runtime bound
# or an unexpected child death, named with its exit status - naming the stage
# that did not finish and the sections that were therefore never emitted, and
# still exits 0. The child
# records its progress in FM_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: fm-session-start.sh [--reemit] [--source <source>]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (fleet
#             sync, same-home backlog reconciliation, secondmate convergence and
#             liveness, pending remote handoff retry, X-mode
#             artifact writes) - and
#             re-emit the rest. Wake-queue presentation is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             handle and acknowledge them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: fm-lock.sh
#             already treats a lock owned through shared ancestry or a trusted
#             same-session Claude id as its own, so the re-emit proceeds, while
#             a lock another live session took meanwhile still produces the
#             ordinary read-only path. A re-emit prints a short RE-EMIT CUE
#             first, so a harness that spills a large output and shows only its
#             head still tells the model to read the saved full output.
#
#   --source  The native session-open source, supplied only by
#             fm-sessionstart-run.sh. A genuine `startup` that owns the active
#             session lock records AGENTS.md's SHA-256 baseline only after the
#             digest completion record is published, keyed to that lock's
#             harness pid. No resume, clear, reset, compact, or other rebuild
#             creates or replaces it. Pi and pi-signed compaction are the only
#             supported stale-cache rebuild pair: a missing baseline, a baseline
#             for another harness pid, or a changed hash causes the complete
#             current AGENTS.md to print before the bulky digest. The baseline
#             remains immutable so every later drifted compaction refreshes
#             again, while an equal baseline emits no instruction refresh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"
SHARED_BASELINE_FILE="$STATE/.session-start-shared-baseline"

REEMIT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock role bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${FM_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ -z "${FM_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*) SESSION_START_BUDGET=120 ;; esac
  [ "$SESSION_START_BUDGET" -gt 0 ] 2>/dev/null || SESSION_START_BUDGET=120
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  if [ "$REEMIT" -eq 1 ]; then
    if [ -n "$SESSION_SOURCE" ]; then
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SESSION_SOURCE"
    else
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit
    fi
  elif [ -n "$SESSION_SOURCE" ]; then
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SESSION_SOURCE"
  else
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh"
  fi
  SESSION_START_RC=$?
  # ANY nonzero child exit is a truncation: the banner contract promises that
  # a stage that cannot print is named. Exit 124 is the bound firing; any
  # other status means the child died or was killed mid-stage, which truncates
  # silently when unbanned - the parent must banner it, never exit 0 around it.
  if [ "$SESSION_START_RC" -ne 0 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    else
      printf '●  STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit %s, not its runtime bound)\n' "$SESSION_START_RC"
    fi
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
      printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    else
      printf '●  again, report the exit status and the stage - raising the runtime bound\n'
      printf '●  cannot help a digest that died, and a stage that dies is a fleet problem.\n'
    fi
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the fm-bootstrap.sh child, which reports
# an incompatible build as OUTDATED. Computing it once and handing it, with the
# reason behind it, to that child collapses six subprocesses to three; the reason
# travels too so the child's OUTDATED requirement text names a missing capability
# without running the child's own `--help` probes over again. fm-tasks-axi-lib.sh
# owns both reuse layers and the one-hop consumption rule that keeps them out of
# any agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi
TASKS_AXI_CHECK_REASON=$(fm_tasks_axi_check_reason)

QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-5}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=5 ;; esac
# SIZE BUDGET knobs (see this file's SIZE BUDGET note). A context file at or
# under CONTEXT_INLINE_MAX bytes prints in full; a larger one is indexed. A wake
# presentation over WAKE_INLINE_MAX bytes is saved to a file, and its inline
# copy is bounded (print_wake_presentation). Invalid or zero values fall back to
# the defaults.
CONTEXT_INLINE_MAX=${FM_SESSION_START_CONTEXT_INLINE_MAX:-2048}
case "$CONTEXT_INLINE_MAX" in ''|*[!0-9]*|0) CONTEXT_INLINE_MAX=2048 ;; esac
CONTEXT_OUTLINE_MAX=560
WAKE_INLINE_MAX=${FM_SESSION_START_WAKE_INLINE_MAX:-8000}
case "$WAKE_INLINE_MAX" in ''|*[!0-9]*|0) WAKE_INLINE_MAX=8000 ;; esac
WAKE_PRESENTATION_FILE="$STATE/.session-start-wake-presentation"
WAKE_SECTION_ITEMS=5
WAKE_ANNOTATION_MAX=320
BACKLOG_ROW_MAX=180
# Held and blocked rows carry the hold reason and blocker the captain decides
# on, so they get a wider cut that keeps an ordinary reason whole.
BACKLOG_DECISION_ROW_MAX=320
# One per-task endpoint read may never outlive this bound: a hung backend CLI
# becomes that task's endpoint=error field instead of the digest's whole
# runtime budget.
ENDPOINT_TIMEOUT=${FM_SESSION_START_ENDPOINT_TIMEOUT:-10}
case "$ENDPOINT_TIMEOUT" in ''|*[!0-9]*) ENDPOINT_TIMEOUT=10 ;; esac
[ "$ENDPOINT_TIMEOUT" -gt 0 ] 2>/dev/null || ENDPOINT_TIMEOUT=10
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_context_outline <path>: a bounded, line-numbered outline of one indexed
# context file. Markdown headings (#, ##, ###) are the outline when the file has
# more than one; a list file with at most a title heading (the project and
# secondmate registries) is outlined by each top-level item's label, the text
# before its first " - ". The outline is bounded at CONTEXT_OUTLINE_MAX bytes in
# every encoding: awk counts bytes, and each row is charged its byte length, or
# 400 bytes for a label cut at 100 characters. A long registry shows only its
# first names, and the remaining items are counted in a closing line.
print_context_outline() {
  local path=$1 outline
  outline=$(LC_ALL=C awk -v max="$CONTEXT_OUTLINE_MAX" '
    /^```/ { fence = !fence; next }
    fence { next }
    /^#[ \t]|^##[ \t]|^###[ \t]/ { hn++; hline[hn] = NR; htext[hn] = $0; next }
    /^[-*][ \t]/ {
      label = $0
      sub(/ - .*/, "", label)
      in_++; iline[in_] = NR; itext[in_] = label
    }
    END {
      if (hn > 1 || in_ == 0) { n = hn; kind = "heading" } else { n = in_; kind = "item" }
      if (n == 0) { print "  (no headings or list items to outline)"; exit }
      used = 0
      for (i = 1; i <= n; i++) {
        if (kind == "heading") { ln = hline[i]; t = htext[i] } else { ln = iline[i]; t = itext[i] }
        prefix = "  L" ln " "
        row = prefix t
        cost = length(prefix) + (length(t) > 400 ? 400 : length(t))
        if (used + cost + 1 > max) {
          printf "  (+%d more %s(s) - read the file for the rest)\n", n - i + 1, kind
          exit
        }
        printf "\037%d\037%s\n", length(prefix) + 100, row
        used += cost + 1
      }
    }
  ' "$path" 2>/dev/null) || { printf '  (outline unavailable - read the file)\n'; return 0; }
  printf '%s\n' "$outline" | cap_marked_lines
}

# print_context_file <path> <label> [pointer]: one context source under a labeled
# subsection. Absence is semantically meaningful for every one of these files
# (captain.md absent = firstmate repo built-in defaults, projects.md absent =
# rebuild from clones, etc. - AGENTS.md section 3) and must never be confused
# with an empty-but-present file, so the two cases print differently. A file at
# or under CONTEXT_INLINE_MAX bytes prints in full; a larger one prints an INDEXED
# pointer line (absolute path, size) plus its outline instead of its contents;
# with `pointer`, a large file prints the pointer line alone (the learnings
# files, which a turn reads only when it needs a specific lesson).
print_context_file() {
  local path=$1 label=$2 mode=${3:-} bytes lines
  subsection "$label"
  if [ ! -f "$path" ]; then
    printf 'ABSENT\n'
    return 0
  fi
  if [ ! -s "$path" ]; then
    printf '(present, empty)\n'
    return 0
  fi
  bytes=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || bytes=
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  if [ "$bytes" -le "$CONTEXT_INLINE_MAX" ]; then
    cat "$path"
    return 0
  fi
  lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ') || lines='?'
  if [ "$mode" = pointer ]; then
    printf 'INDEXED, not printed (%s bytes, %s lines): read %s when this turn needs a lesson from it.\n' \
      "$bytes" "$lines" "$path"
    return 0
  fi
  printf 'INDEXED, not printed (%s bytes, %s lines): read %s, or one section at its line number, when this turn needs it.\n' \
    "$bytes" "$lines" "$path"
  print_context_outline "$path"
}

# cap_marked_lines: copy stdin to stdout, cutting each line that awk marked as
# "\037<max>\037<line>" to <max> characters with the shared fm_cap_line_var cut.
# awk's length and substr count bytes on some platforms, so a cut made there can
# split a multibyte character; the shared cut counts characters under a UTF-8
# locale and, under any other, drops a trailing incomplete sequence, so it never
# does.
cap_marked_lines() {
  local line rest max
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      $'\037'*)
        rest=${line#$'\037'}
        max=${rest%%$'\037'*}
        rest=${rest#*$'\037'}
        fm_cap_line_var "$rest" "$max"
        printf '%s\n' "$FM_LINE_CAP_LINE"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# print_wake_presentation <drain-output>: the drain's own output, bounded. Within
# WAKE_INLINE_MAX bytes it prints verbatim. Over it, the complete presentation is
# first saved to WAKE_PRESENTATION_FILE, and only then is the inline copy bounded.
# It keeps each non-historical `wake annotation: latest wake-EVENT observed at
# drain` line, only the first per signalled status file, cut to WAKE_ANNOTATION_MAX
# characters with the shared line cut. It leaves out the earlier unread, repeated,
# and historical `wake annotation:` lines and every OPEN DECISIONS or STATUS OUTCOME
# BACKSTOP item past the first WAKE_SECTION_ITEMS of its section, each omission
# disclosed with its count and the saved path. A bounded section ends
# at a blank line, a guard banner, a warning, a `wake drain:` diagnostic, or any
# all-capitals drain heading followed by ` (` or `:`, so every later section
# (UNREAD STATUS, RECORD DIVERGENCE, BRANCH OUTCOMES, section tails, the
# acknowledgement line) always prints inline. Both bounded sections are refolded
# from the durable status logs at every drain. If the save fails, nothing is
# left out.
print_wake_presentation() {
  local out=$1 tmp='' bytes=''
  # Count bytes, not characters: under a UTF-8 locale ${#out} counts characters,
  # so multibyte text would slip past the byte budget.
  bytes=$(printf '%s\n' "$out" | LC_ALL=C wc -c | tr -d ' ')
  if [ "$bytes" -le "$WAKE_INLINE_MAX" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  # A directory at the save path would swallow the copy and still let mv
  # succeed, so it counts as a failed save.
  if [ ! -d "$WAKE_PRESENTATION_FILE" ] \
    && tmp=$(mktemp "$WAKE_PRESENTATION_FILE.XXXXXX" 2>/dev/null) \
    && printf '%s\n' "$out" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$WAKE_PRESENTATION_FILE" 2>/dev/null; then
    printf '%s\n' "$out" | awk -v keep="$WAKE_SECTION_ITEMS" -v saved="$WAKE_PRESENTATION_FILE" -v bullet='●' \
      -v amax="$WAKE_ANNOTATION_MAX" \
      -v latest_prefix='wake annotation: latest wake-EVENT observed at drain, not current state: ' '
      function close_section() {
        if (section != "" && cut > 0)
          printf "(%d more %s line(s) left out here; the saved presentation at %s lists them)\n", cut, section, saved
        section = ""; shown = 0; cut = 0
      }
      # The drain labels every unread event whose text equals the newest one
      # "latest", so keep only the first per status file; repeats count as left out.
      /^wake annotation: latest wake-EVENT observed at drain, not current state: / {
        key = substr($0, length(latest_prefix) + 1)
        key = substr(key, 1, index(key, ": ") - 1)
        if (seen[key]++) { annotations++; next }
        printf "\037%d\037%s\n", amax, $0
        next
      }
      /^wake annotation:/ { annotations++; next }
      /^OPEN DECISIONS \(/ { close_section(); print; section = "OPEN DECISIONS"; next }
      /^STATUS OUTCOME BACKSTOP \(/ { close_section(); print; section = "STATUS OUTCOME BACKSTOP"; next }
      section != "" && $0 != "" && index($0, bullet) != 1 \
        && $0 !~ /^([A-Z][A-Z_, ]*( [(]|:)|WARNING|wake drain:)/ {
        if (shown < keep) { shown++; print } else cut++
        next
      }
      { close_section(); print }
      END {
        close_section()
        if (annotations > 0)
          printf "WAKE ANNOTATIONS: %d earlier unread, repeated, and historical wake-event annotation line(s) left out to bound this digest; the complete presentation is saved at %s - read it before handling a signal record above.\n", annotations, saved
      }' | cap_marked_lines
    return 0
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
  printf '%s\n' "$out"
}

print_backlog_pointer() {
  printf 'Full task bodies and any row cut with [truncated] remain available on demand: bin/fm-tasks-axi.sh show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

# Hold reasons are decoded before the cut, so a cut never splits an encoded
# payload; each title line is then cut with the shared [truncated] marker
# (cap_marked_lines):
# held and blocked queued lines at BACKLOG_DECISION_ROW_MAX, every other line
# at BACKLOG_ROW_MAX. Every in-flight, held, and blocked line still prints.
print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; held and blocked lines capped at %s characters, other lines at %s; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$BACKLOG_DECISION_ROW_MAX" "$BACKLOG_ROW_MAX" "$QUEUED_LIMIT"
  fm_hold_reason_decode_stream markdown < "$path" | awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" \
    -v cap="$BACKLOG_ROW_MAX" -v decision_cap="$BACKLOG_DECISION_ROW_MAX" '
    # Mark the line for cap_marked_lines, which makes the character-safe cut.
    function cut(line, limit) { return sprintf("\037%d\037%s", limit, line) }
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; print cut($0, cap); next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; print cut($0, decision_cap); next }
      if (plain_shown < max) { plain_shown++; print cut($0, cap) }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight, gated, plain_shown, plain_total, done_total
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' | cap_marked_lines
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# shorten_axi_cut_notes: tasks-axi marks a field it cut with a ~90-character
# note naming `show <id> --full`; the listing header already names that command,
# so each note becomes the same short [truncated] marker the row cut uses.
shorten_axi_cut_notes() {
  sed -E 's/\\n\.\.\. \(truncated, [0-9]+ chars total - use show [^ ]+ --full to see complete text\)/ [truncated]/g'
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly.
print_ready_queued_bounded() {
  local ready=$1
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" -v cap="$BACKLOG_ROW_MAX" '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) {
        printf "\037%d\037%s\n", cap, $0
        shown++
      }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d ready queued item(s))\n", shown, total
        if (total > shown) {
          printf "(%d more queued - bin/fm-tasks-axi.sh ready)\n", total - shown
        }
      }
    }
  ' | cap_marked_lines
}

# compact_backlog_rows [in_flight|decision]: cap every tasks-axi row (the
# indented lines under a tasks[N]{...} header) at BACKLOG_ROW_MAX characters
# with the shared line cut, so one long title costs a bounded line and the id
# that leads it stays intact. With `decision` (the held and blocked groups,
# whose hold reasons and blockers are decision context), the cap is the wider
# BACKLOG_DECISION_ROW_MAX. With `in_flight`, a plain row - no blocked_by, no
# hold - whose task has a state/<id>.meta is left out here, because Work under
# way prints that task's line below; its id is still named in the disclosure.
# An in-flight row whose id the held group lists (the space-separated ids in
# BACKLOG_HELD_IDS) is left out here too, because the held group prints that
# same row under its own cap; its id is named in a second disclosure. A blocked in-flight
# row, or a plain one with no live record, always prints.
compact_backlog_rows() {
  local mode=${1:-} line id omitted='' count=0 held_dup='' held_count=0 cap=$BACKLOG_ROW_MAX
  [ "$mode" = decision ] && cap=$BACKLOG_DECISION_ROW_MAX
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '  '*)
        if [ "$mode" = in_flight ]; then
          id=${line#"${line%%[![:space:]]*}"}
          id=${id%%,*}
          case " ${BACKLOG_HELD_IDS:-} " in
            *" $id "*)
              if [ -n "$id" ]; then
                held_dup="$held_dup $id"
                held_count=$((held_count + 1))
                continue
              fi
              ;;
          esac
          case "$line" in
            *',none,"-","-"'|*',none,-,-')
              if [ -n "$id" ] && [ -f "$STATE/$id.meta" ]; then
                omitted="$omitted $id"
                count=$((count + 1))
                continue
              fi
              ;;
          esac
        fi
        fm_cap_line_var "$line" "$cap"
        printf '%s\n' "$FM_LINE_CAP_LINE"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
  if [ "$held_count" -gt 0 ]; then
    printf '(%d held in-flight row(s) are left out here; the held group below prints each one:%s)\n' \
      "$held_count" "$held_dup"
  fi
  if [ "$count" -gt 0 ]; then
    printf '(%d plain in-flight row(s) with a live task record are left out here; Work under way below lists each one:%s)\n' \
      "$count" "$omitted"
  fi
}

# backlog_row_ids: the leading id of every indented tasks-axi row on stdin, one
# space-separated line.
backlog_row_ids() {
  awk '/^  [^ ]/ { id = $0; sub(/^ +/, "", id); sub(/,.*/, "", id); if (id != "") printf "%s ", id }'
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; every held and blocked row shown, and every in-flight row not already listed under held or Work under way; held and blocked rows capped at %s characters, other rows at %s; ready queued bounded to %s; task bodies omitted)\n' \
      "$BACKLOG_DECISION_ROW_MAX" "$BACKLOG_ROW_MAX" "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    printf '%s\n' "$in_flight" | fm_hold_reason_decode_stream | strip_axi_help | shorten_axi_cut_notes \
      | BACKLOG_HELD_IDS=$(printf '%s\n' "$held" | strip_axi_help | backlog_row_ids) compact_backlog_rows in_flight
    printf '\nheld (captain- or time-gated; an in-flight item that is also held is listed here only):\n'
    printf '%s\n' "$held" | fm_hold_reason_decode_stream | strip_axi_help | shorten_axi_cut_notes | compact_backlog_rows decision
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | fm_hold_reason_decode_stream | strip_axi_help | shorten_axi_cut_notes | compact_backlog_rows decision
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$(printf '%s\n' "$ready" | shorten_axi_cut_notes)"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# fm_task_state_word <status-file>: the leading state word of the last
# recorded status event (working, done, paused, ...), or "unknown" when the
# task has no status file yet. This is the last EVENT word, not reconciled
# current state - bin/fm-crew-state.sh owns that.
fm_task_state_word() {  # <status-file>
  local status=$1 word
  [ -f "$status" ] || { printf 'unknown'; return 0; }
  word=$(tail -n 1 "$status" 2>/dev/null | awk 'NR==1 { w=$1; sub(/:$/, "", w); sub(/^\[/, "", w); print w }')
  case "$word" in ''|*[!a-z-]*) printf 'unknown' ;; *) printf '%s' "$word" ;; esac
}

# fm_task_pr_url <meta> <status-file>: the recorded PR URL - pr= in the meta
# when present, otherwise the last PR URL on the task's latest done: (ready)
# status line, or "-". Other status lines never supply it: a working: or
# paused: line may name someone else's PR.
fm_task_pr_url() {  # <meta> <status-file>
  local meta=$1 status=$2 pr line verb ready=
  pr=$(fm_meta_get "$meta" pr)
  if [ -z "$pr" ] && [ -f "$status" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      status_line_verb "$line" verb
      [ "$verb" = "done" ] && ready=$line
    done < "$status"
    [ -z "$ready" ] || pr=$(printf '%s\n' "$ready" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | tail -n 1 || true)
  fi
  [ -n "$pr" ] && printf '%s' "$pr" || printf '-'
}

# fm_task_age <meta>: age since spawn (spawn_gen epoch, else the meta file's
# mtime) as Nd/Nh/Nm, or "-" when neither is readable.
fm_task_age() {  # <meta>
  local meta=$1 gen epoch now secs mtime
  gen=$(fm_meta_get "$meta" spawn_gen)
  epoch=${gen#s}
  epoch=${epoch%%.*}
  case "$epoch" in ''|*[!0-9]*) epoch= ;; esac
  if [ -z "$epoch" ]; then
    mtime=$(stat -f %m "$meta" 2>/dev/null || stat -c %Y "$meta" 2>/dev/null || true)
    case "$mtime" in ''|*[!0-9]*) printf '-'; return 0 ;; esac
    epoch=$mtime
  fi
  now=$(date +%s 2>/dev/null || printf '')
  case "$now" in ''|*[!0-9]*) printf '-'; return 0 ;; esac
  secs=$((now - epoch))
  [ "$secs" -ge 0 ] 2>/dev/null || secs=0
  if [ "$secs" -ge 86400 ]; then printf '%dd' $((secs / 86400));
  elif [ "$secs" -ge 3600 ]; then printf '%dh' $((secs / 3600));
  elif [ "$secs" -ge 60 ]; then printf '%dm' $((secs / 60));
  else printf '%ds' "$secs"; fi
}

# is_stale_task <endpoint> <pr> <age>: true for a task whose endpoint is dead or
# unknown, that has no recorded PR, and that is at least STALE_TASK_DAYS old.
# Work under way condenses such a task to one short id:state:age:endpoint entry
# instead of a full line; every live, errored, young, or PR-bearing task keeps its
# full line.
STALE_TASK_DAYS=3
is_stale_task() {  # <endpoint> <pr> <age>
  local endpoint=$1 pr=$2 age=$3 days
  case "$endpoint" in dead|unknown) ;; *) return 1 ;; esac
  [ "$pr" = '-' ] || return 1
  case "$age" in *d) days=${age%d} ;; *) return 1 ;; esac
  case "$days" in ''|*[!0-9]*) return 1 ;; esac
  [ "$days" -ge "$STALE_TASK_DAYS" ]
}

# fm_task_project_label <meta>: the recorded project's basename, or "-".
fm_task_project_label() {  # <meta>
  local meta=$1 project
  project=$(fm_meta_get "$meta" project)
  project=${project%/}
  [ -n "$project" ] && printf '%s' "${project##*/}" || printf '-'
}

# fm_session_start_endpoint_read <backend> <target> [expected-label]: ONE
# bounded, crash-isolated endpoint-liveness read. The read runs in its own
# bash under fm_run_timed's bound instead of in this digest process, because
# a per-task backend liveness read that dies mid-read would otherwise take
# every later stage with it. Isolation turns any death, hang, or nonzero
# surprise in one task's read into that task's own endpoint line - never a
# silently missing rest of digest. The inner bash re-sources fm-backend.sh
# per read; that cost is a few milliseconds per task and buys the isolation.
fm_session_start_endpoint_read() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 label=${3:-}
  # shellcheck disable=SC2016  # Positional parameters expand inside the child bash, not here.
  fm_run_timed "$ENDPOINT_TIMEOUT" bash -c '
    . "$1"
    fm_backend_target_exists "$2" "$3" "$4"
  ' _ "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$label"
}

hash_file_sha256() {
  local file=$1 raw digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    if raw=$(shasum -a 256 "$file" 2>/dev/null) \
      && digest=$(printf '%s\n' "$raw" | awk '
        length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
        END { if (!found) exit 1 }
      ') && [ -n "$digest" ]; then
      printf '%s\n' "$digest"
      return 0
    fi
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    if raw=$(sha256sum "$file" 2>/dev/null) \
      && digest=$(printf '%s\n' "$raw" | awk '
        length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
        END { if (!found) exit 1 }
      ') && [ -n "$digest" ]; then
      printf '%s\n' "$digest"
      return 0
    fi
  fi
  return 1
}

# Called only when [ ! -e "$path" ] && [ ! -L "$path" ].
# Distinguishes confirmed absence (ENOENT -> 0) from permission or traversal blocks
# (EACCES/EPERM/ENOTDIR/ELOOP -> 2, non-recordable unreadable) and transient or
# unclassified lookup errors (any other errno, or missing perl/python3 without a
# proven ancestor block -> 1, skip without alarming or updating baseline).
classify_missing_path() {
  local path=$1 verdict='' cur parent
  if command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # Perl code uses its own @ARGV/$!, not shell expansion.
    verdict=$(perl -MErrno=ENOENT,EACCES,EPERM,ENOTDIR,ELOOP -e '
      my @s = lstat($ARGV[0]);
      if (@s) { print "transient\n"; exit 0; }
      if ($!{ENOENT}) { print "absent\n"; exit 0; }
      if ($!{EACCES} || $!{EPERM} || $!{ENOTDIR} || $!{ELOOP}) { print "unreadable\n"; exit 0; }
      print "transient\n";
    ' "$path" 2>/dev/null) || verdict=''
    case "$verdict" in
      absent) return 0 ;;
      unreadable) return 2 ;;
      transient) return 1 ;;
    esac
  fi
  if command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # Python code uses its own sys.argv, not shell expansion.
    verdict=$(python3 -c '
import errno, os, sys
try:
    os.lstat(sys.argv[1])
    print("transient")
except FileNotFoundError:
    print("absent")
except PermissionError:
    print("unreadable")
except OSError as exc:
    print("unreadable" if exc.errno in (errno.ENOTDIR, errno.ELOOP) else "transient")
' "$path" 2>/dev/null) || verdict=''
    case "$verdict" in
      absent) return 0 ;;
      unreadable) return 2 ;;
      transient) return 1 ;;
    esac
  fi
  cur=$path
  while :; do
    parent=$(dirname "$cur" 2>/dev/null) || return 1
    [ -n "$parent" ] && [ "$parent" != "$cur" ] || return 1
    if [ -L "$parent" ] || [ -e "$parent" ]; then
      if [ -d "$parent" ] && [ -x "$parent" ]; then
        return 1
      fi
      return 2
    fi
    cur=$parent
  done
}

git_config_slot_state() {  # <path> -> absent | sha256:<hex> (rc 0), unreadable (rc 2), or lookup/hash failure (rc 1)
  local path=$1 digest miss_rc=0
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    classify_missing_path "$path" || miss_rc=$?
    if [ "$miss_rc" -eq 0 ]; then
      printf 'absent\n'
      return 0
    fi
    if [ "$miss_rc" -eq 2 ]; then
      printf 'unreadable\n'
      return 2
    fi
    return 1
  fi
  if [ -f "$path" ] && [ -r "$path" ]; then
    digest=$(hash_file_sha256 "$path" 2>/dev/null) || return 1
    [ -n "$digest" ] || return 1
    printf '%s\n' "$digest"
    return 0
  fi
  printf 'unreadable\n'
  return 2
}

# Prints two lines: <slots-key>, <state-value>.
# Returns 0 when every watched slot is absent, devnull, or hashed cleanly;
# returns 2 when at least one slot is unreadable (so drift can still alarm without
# overwriting the baseline); returns 1 when lookup or hashing fails transiently.
global_git_config_snapshot() {
  local slot_state slot_rc=0 xdg_file home_file home_dir xdg_state xdg_rc=0 home_state home_rc=0
  if [ "${GIT_CONFIG_GLOBAL+x}" = x ]; then
    if [ -z "$GIT_CONFIG_GLOBAL" ] || [ "$GIT_CONFIG_GLOBAL" = /dev/null ]; then
      printf 'env:%s\ndevnull\n' "$GIT_CONFIG_GLOBAL"
      return 0
    fi
    slot_state=$(git_config_slot_state "$GIT_CONFIG_GLOBAL") || slot_rc=$?
    [ "$slot_rc" -eq 0 ] || [ "$slot_rc" -eq 2 ] || return 1
    printf 'env:%s\n%s\n' "$GIT_CONFIG_GLOBAL" "$slot_state"
    return "$slot_rc"
  fi
  home_dir=${HOME:-}
  [ -n "$home_dir" ] || home_dir=~
  xdg_file="${XDG_CONFIG_HOME:-$home_dir/.config}/git/config"
  home_file="$home_dir/.gitconfig"
  xdg_state=$(git_config_slot_state "$xdg_file") || xdg_rc=$?
  [ "$xdg_rc" -eq 0 ] || [ "$xdg_rc" -eq 2 ] || return 1
  home_state=$(git_config_slot_state "$home_file") || home_rc=$?
  [ "$home_rc" -eq 0 ] || [ "$home_rc" -eq 2 ] || return 1
  printf 'xdg:%s|home:%s\n%s|%s\n' "$xdg_file" "$home_file" "$xdg_state" "$home_state"
  if [ "$xdg_rc" -eq 2 ] || [ "$home_rc" -eq 2 ]; then
    return 2
  fi
  return 0
}

# Prints two lines: <db-path>, <schema-state>.
# Returns 0 on recordable states (absent | sha256:<hex>), 2 on actionable non-recordable
# states (corrupt | unreadable) so they alarm without overwriting the baseline, and 1 on
# transient OperationalError/OSError, lookup error, timeout, or missing python3 so no
# false alarm or baseline mutation occurs.
nm_db_schema_snapshot() {
  local db_path out rc miss_rc=0
  db_path=$(fm_nm_state_db "$FM_HOME")
  [ -n "$db_path" ] || return 1
  if [ ! -e "$db_path" ] && [ ! -L "$db_path" ]; then
    classify_missing_path "$db_path" || miss_rc=$?
    if [ "$miss_rc" -eq 0 ]; then
      printf '%s\nabsent\n' "$db_path"
      return 0
    fi
    if [ "$miss_rc" -eq 2 ]; then
      printf '%s\nunreadable\n' "$db_path"
      return 2
    fi
    return 1
  fi
  if [ ! -f "$db_path" ] || [ ! -r "$db_path" ]; then
    printf '%s\nunreadable\n' "$db_path"
    return 2
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  rc=0
  # shellcheck disable=SC2016  # Python code uses its own sys.argv, not shell expansion.
  out=$(fm_run_timed 5 python3 -c '
import hashlib, sqlite3, sys
from contextlib import closing
from pathlib import Path
p = Path(sys.argv[1])
try:
    with closing(sqlite3.connect(p.as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
        uv = db.execute("PRAGMA user_version").fetchone()
        rows = db.execute(
            "SELECT type, name, tbl_name, COALESCE(sql, ?) "
            "FROM sqlite_master WHERE substr(name, 1, 7) != ? "
            "ORDER BY type, name, tbl_name",
            ("", "sqlite_"),
        ).fetchall()
except sqlite3.OperationalError:
    sys.exit(3)
except sqlite3.DatabaseError:
    print("corrupt")
    sys.exit(2)
except OSError:
    sys.exit(3)
h = hashlib.sha256()
h.update(("user_version=%s\n" % (uv[0] if uv else 0)).encode("utf-8"))
for row in rows:
    h.update(("%s\x1f%s\x1f%s\x1f%s\x1e" % row).encode("utf-8"))
print("sha256:" + h.hexdigest())
' "$db_path" 2>/dev/null) || rc=$?
  case "$out" in
    sha256:*)
      if [ "$rc" -eq 0 ]; then
        printf '%s\n%s\n' "$db_path" "$out"
        return 0
      fi
      ;;
  esac
  if [ "$rc" -eq 2 ] && [ "$out" = corrupt ]; then
    printf '%s\ncorrupt\n' "$db_path"
    return 2
  fi
  return 1
}

# Scope and line-format contract: see step 2 of the file header above.
check_shared_state_since_last_start() {
  local prev_git_slots='' prev_git_state='' prev_nm_path='' prev_nm_schema='' baseline_raw='' baseline_ok=0 baseline_miss_rc=0
  local git_snap='' git_rc=0 git_ok=0 curr_git_slots='' curr_git_state=''
  local nm_snap='' nm_rc=0 nm_ok=0 curr_nm_path='' curr_nm_schema=''
  local git_alarm=0 nm_alarm=0
  local report_label xdg_path home_path xdg_label home_label prev_xdg prev_home curr_xdg curr_home xdg_bad home_bad nm_detail tmp
  if [ ! -e "$SHARED_BASELINE_FILE" ] && [ ! -L "$SHARED_BASELINE_FILE" ]; then
    classify_missing_path "$SHARED_BASELINE_FILE" || baseline_miss_rc=$?
    [ "$baseline_miss_rc" -eq 0 ] && baseline_ok=1
  elif [ -f "$SHARED_BASELINE_FILE" ] && [ ! -L "$SHARED_BASELINE_FILE" ] && [ -r "$SHARED_BASELINE_FILE" ]; then
    if baseline_raw=$(cat "$SHARED_BASELINE_FILE" 2>/dev/null) \
      && prev_git_slots=$(printf '%s\n' "$baseline_raw" | sed -n '1p') \
      && prev_git_state=$(printf '%s\n' "$baseline_raw" | sed -n '2p') \
      && prev_nm_path=$(printf '%s\n' "$baseline_raw" | sed -n '3p') \
      && prev_nm_schema=$(printf '%s\n' "$baseline_raw" | sed -n '4p') \
      && [ -z "$(printf '%s\n' "$baseline_raw" | sed -n '5p')" ] \
      && [ -n "$prev_git_slots" ] && [ -n "$prev_git_state" ] \
      && [ -n "$prev_nm_path" ] && [ -n "$prev_nm_schema" ]; then
      baseline_ok=1
    else
      prev_git_slots=''
      prev_git_state=''
      prev_nm_path=''
      prev_nm_schema=''
    fi
  fi
  git_snap=$(global_git_config_snapshot) || git_rc=$?
  if [ "$git_rc" -eq 0 ] || [ "$git_rc" -eq 2 ]; then
    if curr_git_slots=$(printf '%s\n' "$git_snap" | sed -n '1p') \
      && curr_git_state=$(printf '%s\n' "$git_snap" | sed -n '2p') \
      && [ -n "$curr_git_slots" ] && [ -n "$curr_git_state" ]; then
      [ "$git_rc" -eq 0 ] && git_ok=1
    else
      curr_git_slots=''
      curr_git_state=''
      git_rc=1
    fi
  fi
  nm_snap=$(nm_db_schema_snapshot) || nm_rc=$?
  if [ "$nm_rc" -eq 0 ] || [ "$nm_rc" -eq 2 ]; then
    if curr_nm_path=$(printf '%s\n' "$nm_snap" | sed -n '1p') \
      && curr_nm_schema=$(printf '%s\n' "$nm_snap" | sed -n '2p') \
      && [ -n "$curr_nm_path" ] && [ -n "$curr_nm_schema" ]; then
      [ "$nm_rc" -eq 0 ] && nm_ok=1
    else
      curr_nm_path=''
      curr_nm_schema=''
      nm_rc=1
    fi
  fi
  if [ -n "$prev_git_slots" ] && [ -n "$prev_git_state" ] \
    && [ "$curr_git_slots" = "$prev_git_slots" ] && [ -n "$curr_git_state" ] \
    && [ "$curr_git_state" != "$prev_git_state" ]; then
    git_alarm=1
  elif [ "$git_rc" -eq 2 ] && [ -n "$curr_git_slots" ]; then
    git_alarm=1
  fi
  if [ "$git_alarm" -eq 1 ]; then
    case "$curr_git_slots" in
      env:*)
        report_label=${curr_git_slots#env:}
        [ -n "$report_label" ] || report_label='<empty>'
        [ "$curr_git_state" = unreadable ] && report_label="$report_label: unreadable"
        ;;
      xdg:*'|home:'*)
        xdg_path=${curr_git_slots#xdg:}
        xdg_path=${xdg_path%%|home:*}
        home_path=${curr_git_slots#*|home:}
        curr_xdg=${curr_git_state%%|*}
        curr_home=${curr_git_state#*|}
        xdg_label=$xdg_path
        home_label=$home_path
        [ "$curr_xdg" = unreadable ] && xdg_label="$xdg_path: unreadable"
        [ "$curr_home" = unreadable ] && home_label="$home_path: unreadable"
        if [ -n "$prev_git_state" ] && [ "$curr_git_slots" = "$prev_git_slots" ]; then
          prev_xdg=${prev_git_state%%|*}
          prev_home=${prev_git_state#*|}
          xdg_bad=0
          home_bad=0
          { [ "$curr_xdg" != "$prev_xdg" ] || [ "$curr_xdg" = unreadable ]; } && xdg_bad=1
          { [ "$curr_home" != "$prev_home" ] || [ "$curr_home" = unreadable ]; } && home_bad=1
          if [ "$xdg_bad" -eq 1 ] && [ "$home_bad" -eq 1 ]; then
            report_label="$xdg_label, $home_label"
          elif [ "$xdg_bad" -eq 1 ]; then
            report_label="$xdg_label"
          else
            report_label="$home_label"
          fi
        elif [ "$curr_xdg" = unreadable ] && [ "$curr_home" = unreadable ]; then
          report_label="$xdg_label, $home_label"
        elif [ "$curr_xdg" = unreadable ]; then
          report_label="$xdg_label"
        else
          report_label="$home_label"
        fi
        ;;
      *)
        report_label="$curr_git_slots"
        ;;
    esac
    printf 'SHARED_STATE: global git config changed since the last session start (%s) - workers must never edit shared git config; inspect recent changes and restore any unintended setting\n' "$report_label"
  fi
  if [ "$nm_rc" -eq 2 ] && [ -n "$curr_nm_path" ]; then
    nm_alarm=1
  elif [ -n "$prev_nm_path" ] && [ -n "$prev_nm_schema" ] && [ "$prev_nm_schema" != absent ] \
    && [ "$curr_nm_path" = "$prev_nm_path" ] && [ -n "$curr_nm_schema" ] \
    && [ "$curr_nm_schema" != "$prev_nm_schema" ]; then
    nm_alarm=1
  fi
  if [ "$nm_alarm" -eq 1 ]; then
    nm_detail="$curr_nm_path"
    case "$curr_nm_schema" in
      absent) nm_detail="$curr_nm_path: removed" ;;
      corrupt) nm_detail="$curr_nm_path: corrupt or unreadable SQLite schema" ;;
      unreadable) nm_detail="$curr_nm_path: unreadable" ;;
    esac
    printf 'SHARED_STATE: shared no-mistakes database schema changed since the last session start (%s) - workers must never alter shared databases; inspect no-mistakes version and state database before dispatching pipeline runs\n' "$nm_detail"
  fi
  if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ] && [ "$baseline_ok" -eq 1 ] \
    && [ "$git_ok" -eq 1 ] && [ "$nm_ok" -eq 1 ]; then
    tmp=$(mktemp "$STATE/.session-start-shared-baseline.XXXXXX" 2>/dev/null || true)
    if [ -n "$tmp" ]; then
      if ! { printf '%s\n%s\n%s\n%s\n' \
        "$curr_git_slots" "$curr_git_state" "$curr_nm_path" "$curr_nm_schema" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$SHARED_BASELINE_FILE" 2>/dev/null; }; then
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid baseline_hash current_hash
  [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ] || return 0
  baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  current_hash=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
  [ -n "$current_hash" ] || return 0
  [ "$baseline_pid" = "$lock_pid" ] && [ "$baseline_hash" = "$current_hash" ] && return 1
  return 0
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Firstmate delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  agents_refresh_required "$lock_pid" || return 0
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  if [ -f "$FM_ROOT/AGENTS.md" ]; then
    cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    cat "$FM_ROOT/AGENTS.md"
  else
    printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
  fi
}

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

if [ "$REEMIT" -eq 1 ]; then
  # First in the output on purpose: a harness that spills a large hook output
  # delivers only a short head inline (Claude: about 2,000 characters), and
  # CONTEXT prints last, so this cue is the part that must survive the spill.
  printf 'RE-EMIT CUE: if this output ends with "Output too large ... Full output saved to <path>",\n'
  printf 'read that whole file now, before acting. Otherwise read data/captain.md, data/captain-shared.md,\n'
  printf 'data/learnings.md under %s, and docs/learnings/overnight-learnings.md under the code root now if\n' "$DATA"
  printf 'any of them is missing below.\n'
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'secondmate convergence and liveness, pending remote handoff\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $FM_HOME"
fi
# Before any lock or role work, and once: bootstrap below skips its copy of
# this check (bin/fm-bash-compat-lib.sh owns it).
fm_bash_heredoc_startup_warnings
export FM_BASH_HEREDOC_WARNED=1
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
REBUILDING_SESSION_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"

# --- 1b. home role -------------------------------------------------------
# This home's firstmate-repository role: user/operator unless an explicit
# local or receipt-proven inherited grant says otherwise (bin/fm-role-lib.sh).
# Purely local resolution - no network, no gh call.
stage role
subsection "HOME ROLE"
FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-role.sh" report 2>/dev/null \
  || printf 'fm-role: unknown (bin/fm-role.sh report failed)\n'

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # A full locked start publishes this home's current structured summary.
  # Publication is side-band and best-effort, so it can never change the
  # session-start result. A context re-emit is not another session start.
  if [ "$REEMIT" -eq 0 ]; then
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  fi
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  # Home code drift (issue #93) therefore self-heals only for this lock-owning
  # mutable session: the deferred worker's bootstrap network pass fast-forwards
  # FM_ROOT when it is behind origin's default branch, clean, and
  # fast-forwardable, and otherwise prints one HOME_DRIFT digest line naming
  # how many commits behind and why it did not fast-forward. Its fetch stays
  # on that deferred path, so a network failure never blocks this digest.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
  # With no enabled watchdog to read the monitor unit each pass, a full
  # locked start runs the watchdog's one read itself (docs/watchdog.md),
  # after the network stage is launched so the read never delays it.
  if [ "$REEMIT" -eq 0 ]; then
    case "$(fm_run_timed 10 env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-watchdog.sh" manager-status 2>/dev/null)" in
      'manager: enabled'*) ;;
      *) fm_run_timed 20 env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-watchdog.sh" monitor-read >/dev/null 2>&1 || true ;;
    esac
  fi
fi

# --- 2. bootstrap --------------------------------------------------------
# FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
    FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      FM_TASKS_AXI_CHECK_REASON="$TASKS_AXI_CHECK_REASON" \
      "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
SHARED_STATE_OUT=$(check_shared_state_since_last_start)
if [ -n "$SHARED_STATE_OUT" ]; then
  if [ -n "$BOOT_OUT" ]; then
    BOOT_OUT="$BOOT_OUT"$'\n'"$SHARED_STATE_OUT"
  else
    BOOT_OUT="$SHARED_STATE_OUT"
  fi
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-branch-outcome.sh" seed-tail >/dev/null 2>&1 || true
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    print_wake_presentation "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
  # A new captain session records its own terminal as the handle senders
  # resolve at send time, and a clear or compact starts a new context that has
  # written no handoff yet (bin/fm-order.sh owns the handle and order contract).
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-order.sh" claim-handle >/dev/null 2>&1 || true
fi
# Durable captain orders still open are this session's to pick up; the list is
# read-only, so a read-only session sees it too (bin/fm-order.sh pickup).
ORDERS_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-order.sh" pickup 2>&1) || ORDERS_OUT=
if [ -n "$ORDERS_OUT" ]; then
  subsection "CAPTAIN ORDERS"
  printf '%s\n' "$ORDERS_OUT"
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_MODE=$(fm_afk_mode "$STATE")
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(fm_pi_extension_version "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(fm_pi_extension_version "$PI_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" active \
    || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
# omp (Oh My Pi) has no project-trust gate: it auto-discovers <cwd>/.omp/extensions
# with no dialog, so the only ways both tracked primary extensions fail to load
# are a session started outside this home, an extension disabled in the omp
# config, or a build older than the tracked file. The markers carry the loaded
# build plus the loading pid, exactly as the Pi ones do (bin/fm-wake-lib.sh).
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
  OMP_TURNEND_EXT="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
  OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
  OMP_LOCK="$STATE/.lock"
  OMP_WATCH_VERSION=$(fm_pi_extension_version "$OMP_EXT" || printf '')
  OMP_TURNEND_VERSION=$(fm_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
    || ! fm_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
    OMP_HOME_PHYS=$(cd -P "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")
    OMP_ROOT_PHYS=$(cd -P "$FM_ROOT" 2>/dev/null && pwd -P || printf '%s' "$FM_ROOT")
    if [ "$OMP_HOME_PHYS" = "$OMP_ROOT_PHYS" ]; then
      printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT"
    else
      # shellcheck disable=SC2016  # backticks are literal text in the diagnostic
      printf 'OMP_WATCH_EXTENSION: not loaded - exit omp and relaunch through `fm <project>` (the launcher sets FM_HOME and --cwd) so %s and %s auto-load for this home; a bare omp or /resume from the firstmate checkout does not register the extensions for this home\n' "$OMP_TURNEND_EXT" "$OMP_EXT"
    fi
    # Warning only: name the cause when existing facts establish it.
    OMP_MARKER_PID=$(sed -n '2p' "$OMP_WATCH_MARKER" 2>/dev/null || true)
    OMP_CURRENT_PID=${REBUILDING_SESSION_PID:-$(sed -n '1p' "$OMP_LOCK" 2>/dev/null || true)}
    if [ -n "$OMP_MARKER_PID" ] && [ -n "$OMP_CURRENT_PID" ] && [ "$OMP_MARKER_PID" != "$OMP_CURRENT_PID" ]; then
      printf 'OMP_WATCH_CAUSE: the extension marker %s names pid %s, which is not this session (pid %s)\n' "$OMP_WATCH_MARKER" "$OMP_MARKER_PID" "$OMP_CURRENT_PID"
    fi
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --afk-mode "$AFK_MODE" \
  --x-mode "$X_MODE_PRESENT"

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
cat <<'EOF'
Everything below prints once for this session start: a compact
data/backlog.md listing, one line per live task and per orphan status log,
and the CONTEXT files (data/projects.md, data/secondmates.md, data/captain.md,
data/captain-shared.md, data/learnings.md, and the tracked
docs/learnings/overnight-learnings.md under the code root), each in full when
small or INDEXED with its path, size, and outline when large.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status.

Go to a source directly only when:
  - CONTEXT marked it INDEXED and this turn needs it (read the file, or the
    section at the line its outline names),
  - WAKE QUEUE named a saved presentation file (read it before handling a
    signal record or reconciling the items it left out),
  - this digest flagged it ABSENT (rebuild or create it per AGENTS.md), or its
    contents looked unparseable or corrupt,
  - one task's detail is needed (bin/fm-crew-state.sh <id> for reconciled
    state; state/<id>.meta and state/<id>.status for raw records),
  - a full task body, or a backlog row the listing omitted or cut, is needed
    (bin/fm-tasks-axi.sh show <id> --full, bin/fm-tasks-axi.sh ready, or
    data/backlog.md),
  - NETWORK CHECKS reported checks still IN PROGRESS and this turn needs their
    verdict (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it,
    or a context re-emit opened with a read cue because the harness cut the
    digest short: that stage's sources were never emitted and must be
    reconciled.
EOF

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
stage fleet-state
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Work under way (state/*.meta)"
printf 'One line per live task: id, project, last recorded state, PR URL, age, endpoint.\n'
printf 'Full detail: bin/fm-crew-state.sh <id> (reconciled state); raw records: state/<id>.meta and state/<id>.status.\n'
META_FOUND=0
STALE_COUNT=0
STALE_ENTRIES=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  status="$STATE/$id.status"
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    endpoint_rc=0
    fm_session_start_endpoint_read "$backend" "${target:-$window}" "fm-$id" || endpoint_rc=$?
    # Only the timeout owner's own statuses mean the read itself failed: 124 is
    # the bound firing and >=128 is a signal death. Every other nonzero status
    # is the probe's own verdict that the endpoint is gone.
    if [ "$endpoint_rc" -eq 0 ]; then
      endpoint='alive'
    elif [ "$endpoint_rc" -eq 124 ] || [ "$endpoint_rc" -ge 128 ]; then
      endpoint='error'
    else
      endpoint='dead'
    fi
  else
    endpoint='unknown'
  fi
  task_state=$(fm_task_state_word "$status")
  task_pr=$(fm_task_pr_url "$meta" "$status")
  task_age=$(fm_task_age "$meta")
  if is_stale_task "$endpoint" "$task_pr" "$task_age"; then
    STALE_COUNT=$((STALE_COUNT + 1))
    STALE_ENTRIES="$STALE_ENTRIES $id:$task_state:$task_age:$endpoint"
    continue
  fi
  printf '%s project=%s state=%s pr=%s age=%s endpoint=%s\n' \
    "$id" "$(fm_task_project_label "$meta")" "$task_state" "$task_pr" "$task_age" "$endpoint"
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'
if [ "$STALE_COUNT" -gt 0 ]; then
  printf '%d stale task(s) (endpoint dead or unknown, at least %d days old, no recorded PR), condensed to id:state:age:endpoint:%s\n' \
    "$STALE_COUNT" "$STALE_TASK_DAYS" "$STALE_ENTRIES"
fi

subsection "Orphan status logs (state/*.status without matching .meta)"
printf 'One line per orphan log: id and last recorded state. Full log: state/<id>.status.\n'
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '%s state=%s\n' "$id" "$(fm_task_state_word "$status")"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
# The away posture is the record (bin/fm-afk-contract.sh); the legacy flag
# still marks a running daemon on the harnesses that launch one.
# A quiet record (bin/fm-afk-contract.sh mode) is a present captain: it holds
# nothing for a return.
if [ -f "$STATE/.afk-contract" ]; then
  if [ "$("$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = quiet ]; then
    printf 'present - quiet mode recorded at %s (the captain is present and nothing is held for a return: requested actions proceed under ordinary attended authority; only an explicit /quiet off exits it)' \
      "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  else
    printf 'present - away posture recorded at %s (hold-for-return only; bin/fm-afk-contract.sh readback for the mandate)' \
      "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  fi
  if [ -e "$STATE/.afk" ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '; the quiet daemon owns the watcher.\n'
    else
      printf '; the away daemon owns the watcher.\n'
    fi
  else
    printf '; no daemon runs, the ordinary supervision session continues.\n'
  fi
elif [ -e "$STATE/.afk" ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf 'present - quiet-mode supervision is active; the daemon owns the watcher, only an explicit /quiet off exits it (legacy flag with no posture record).\n'
  else
    printf 'present - away-mode supervision is active; the daemon owns the watcher (legacy flag with no posture record).\n'
  fi
else
  printf 'absent\n'
fi

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
    printf 'Reconcile terminal results with %s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh retire <id> --reason "...". Load fmx-respond for the procedure.\n' "$FM_ROOT"
  fi
fi

# Captain goals past the dispatch SLA (bin/fm-dispatch-log.sh owns the ledger).
# A read-only `overdue` call, so it runs for lock-refused sessions too; a home
# with no ledger prints nothing.
if [ -f "$STATE/dispatch-log.tsv" ]; then
  DISPATCH_OVERDUE=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-dispatch-log.sh" overdue 2>&1) || true
  if [ -n "$DISPATCH_OVERDUE" ]; then
    subsection "Dispatch ledger (fm-dispatch-log.sh overdue)"
    printf '%s\n' "$DISPATCH_OVERDUE"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '\nInformation only: the session holding the lock owns these goals.\n'
    else
      printf '\nDispatch or block each OVERDUE goal this turn and report it to the captain, because it still needs action. Each LATE goal is already resolved: include it in the next batched update or morning report rather than on each heartbeat.\n'
    fi
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# secondmate that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
section "CONTEXT"
printf 'A file over %s bytes is INDEXED: its path, size, and outline print instead of its text.\n' "$CONTEXT_INLINE_MAX"
printf 'Before the first dispatch, merge, or escalation call this session, read each INDEXED captain file,\n'
printf 'or at least the sections its outline names for that call.\n'
print_context_file "$FM_ROOT/docs/learnings/overnight-learnings.md" \
  "docs/learnings/overnight-learnings.md (tracked fleet learnings)" pointer
print_context_file "$DATA/projects.md" "data/projects.md"
print_context_file "$DATA/secondmates.md" "data/secondmates.md"
print_context_file "$DATA/captain.md" "data/captain.md"
print_context_file "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_context_file "$DATA/learnings.md" "data/learnings.md" pointer

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
  cat <<'EOF'
Quiet mode is active. Follow the supervision operating instructions block
above: load /quiet and ensure the daemon is running, because the daemon owns
watcher supervision. Ordinary captain chat does not exit it; only an
explicit /quiet off does.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  fm_session_pid_valid "$COMPLETION_PID" || COMPLETION_PID=
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
