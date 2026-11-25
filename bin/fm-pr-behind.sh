#!/usr/bin/env bash
# fm-pr-behind.sh - relaunch a live ship whose local branch fell behind its own
# pull-request head.
#
# Usage: fm-pr-behind.sh scan
#
# The no-mistakes pipeline can push fix commits to a ship's pull-request branch
# while the worker's local copy stays at the older head. A worker that keeps
# going from there builds on stale history. bin/fm-pr-resync.sh owns moving such
# a copy to the published head, and the ship relaunch path
# (bin/fm-control.sh <id> relaunch, then bin/fm-spawn.sh --relaunch) runs it.
# This scan is only the trigger: bin/fm-watch.sh runs it once per merge-poll
# sweep, after the per-task PR polls, so it adds no loop, daemon or poller.
#
# A candidate is a local ship record (state/<id>.meta, kind=ship, no
# remote_host) with a recorded pr= whose merge poll the sweep still follows
# (state/<id>.check.sh), in the delivery mode the relaunch resync supports
# (mode=no-mistakes, or no mode and a `no-mistakes` remote), with an origin
# remote, its recorded branch checked out in its recorded worktree, no
# deliberate stop (state/.crew-stopped-<id>), and no terminal last status.
# Each candidate is probed at most once per FM_PR_BEHIND_INTERVAL seconds
# (default 900): one bounded `git ls-remote` of origin's branch. A head equal to
# the local branch, or one this task already settled, ends the probe there.
# Otherwise `fm-pr-resync.sh --check` (objects-only fetch, no ref change)
# classifies the branch:
#   - exit 3: an active no-mistakes run holds the branch; record `active`, no
#     relaunch;
#   - planned:none (equal or ahead, dirty or not): record `current`;
#   - behind, or a refused check, with uncommitted changes: record `dirty`, no
#     relaunch;
#   - planned:archive-advance (diverged), or any other refusal: record it, no
#     relaunch;
#   - planned:advance (strictly behind, clean): a decision held for the
#     captain records `held`; otherwise request one relaunch.
# A relaunch is requested at most once per new PR head and at most once per
# scan. A dirty or active head is not settled, so the same head is requested
# once the copy is clean and the run is over; its event is reported only once.
# Nothing here discards, resets, moves or forces anything: --check makes no
# ref change, and the relaunch's own resync owns every move.
#
# Ledger: state/.pr-behind-<id>, rows `<epoch>\t<event>\t<head>`, newest last,
# trimmed to the last 64 rows. Events: probe current dirty held active diverged
# refused requested relaunched deferred failed unreadable.
#
# Output: one `<wake-key>\t<check reason>` line per event the supervisor should
# see; bin/fm-watch.sh appends each as a durable check wake. Silence means
# nothing new. Exit 0 unless usage is wrong (2).
#
# Environment:
#   FM_PR_BEHIND_INTERVAL         per-task probe spacing, seconds (900)
#   FM_PR_BEHIND_GIT_TIMEOUT      bound on each git network read, seconds (30)
#   FM_PR_BEHIND_DEADLINE         epoch after which no probe starts (now + 240);
#                                 a relaunch request is bounded to end by it
#   FM_PR_BEHIND_RELAUNCH_TIMEOUT bound on the relaunch request, seconds (220)
#   FM_PR_BEHIND_RELAUNCH_MIN     skip a request with less time left, seconds (60)
#   FM_CONTROL_BIN                relaunch entry point (bin/fm-control.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
[ "$#" -eq 1 ] && [ "$1" = scan ] || { echo "usage: fm-pr-behind.sh scan" >&2; exit 2; }

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

posint() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
INTERVAL=$(posint "${FM_PR_BEHIND_INTERVAL:-}" 900)
GIT_TIMEOUT=$(posint "${FM_PR_BEHIND_GIT_TIMEOUT:-}" 30)
DEADLINE=$(posint "${FM_PR_BEHIND_DEADLINE:-}" $(( $(date +%s) + 240 )))
RELAUNCH_TIMEOUT=$(posint "${FM_PR_BEHIND_RELAUNCH_TIMEOUT:-}" 220)
RELAUNCH_MIN=$(posint "${FM_PR_BEHIND_RELAUNCH_MIN:-}" 60)
CONTROL=${FM_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}

meta_get() {  # <meta> <key>: last value wins, as bin/fm-backend.sh fm_meta_get reads it
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}
short() { printf '%.12s' "$1"; }
emit() {  # <key> <reason>
  printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | LC_ALL=C tr '\t\r\n' '   ')"
}

LEDGER=
record() {  # <event> <head>
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$LEDGER" 2>/dev/null || return 1
  local n
  n=$(wc -l < "$LEDGER" 2>/dev/null | tr -d '[:space:]')
  if [ "${n:-0}" -gt 64 ]; then
    tail -n 64 "$LEDGER" > "$LEDGER.tmp.$$" 2>/dev/null && mv -f "$LEDGER.tmp.$$" "$LEDGER" 2>/dev/null
    rm -f "$LEDGER.tmp.$$"
  fi
  return 0
}
last_probe() { awk -F '\t' '$1 ~ /^[0-9]+$/ { t = $1 } END { print t + 0 }' "$LEDGER" 2>/dev/null || echo 0; }
# The head whose relaunch question is closed: a request, a not-behind reading,
# or a divergence or refusal the relaunch would also refuse. `deferred` (the
# control plane proved nothing was sent) reopens it.
settled_head() {
  awk -F '\t' '
    $2 ~ /^(current|requested|relaunched|failed|diverged|refused)$/ { h = $3 }
    $2 == "deferred" && $3 == h { h = "" }
    END { print h }' "$LEDGER" 2>/dev/null
}
seen_event() { awk -F '\t' -v e="$1" -v h="$2" '$2 == e && $3 == h { f = 1 } END { exit !f }' "$LEDGER" 2>/dev/null; }
# Report an event once per head; the row is recorded either way.
note() {  # <event> <head> <key> <reason>
  local first=1
  ! seen_event "$1" "$2" || first=0
  record "$1" "$2" || return 0
  [ "$first" -eq 0 ] || emit "$3" "$4"
}

requested=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  [ "$requested" -eq 0 ] || break
  [ "$(date +%s)" -lt "$DEADLINE" ] || break
  id=$(basename "$meta" .meta)
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  [ "$(meta_get "$meta" kind)" = ship ] || continue
  [ -z "$(meta_get "$meta" remote_host)" ] || continue
  pr=$(meta_get "$meta" pr)
  [ -n "$pr" ] || continue
  [ -f "$STATE/$id.check.sh" ] || continue
  wt=$(meta_get "$meta" worktree)
  branch=$(meta_get "$meta" branch)
  case "$wt" in /*) [ -d "$wt" ] || continue ;; *) continue ;; esac
  [ -n "$branch" ] || continue
  case "$(meta_get "$meta" mode)" in
    no-mistakes) ;;
    '') git -C "$wt" remote get-url no-mistakes >/dev/null 2>&1 || continue ;;
    *) continue ;;
  esac
  git -C "$wt" remote get-url origin >/dev/null 2>&1 || continue
  [ ! -e "$STATE/.crew-stopped-$id" ] && [ ! -L "$STATE/.crew-stopped-$id" ] || continue
  statusf="$STATE/$id.status"
  ! status_is_terminal_verb "$(last_status_line "$statusf")" || continue
  [ "$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" = "$branch" ] || continue
  LEDGER="$STATE/.pr-behind-$id"
  [ ! -L "$LEDGER" ] || continue
  [ $(( $(date +%s) - $(last_probe) )) -ge "$INTERVAL" ] || continue

  local_head=$(git -C "$wt" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null) || continue
  rc=0
  out=$(fm_nm_bounded "$wt" "$GIT_TIMEOUT" git ls-remote --heads origin "refs/heads/$branch" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then record unreadable - || true; continue; fi
  pub=$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }')
  case "$pub" in
    '') record probe - || true; continue ;;
    *[!0-9a-f]*) record unreadable - || true; continue ;;
  esac
  if [ "$pub" = "$local_head" ]; then record current "$pub" || true; continue; fi
  if [ "$pub" = "$(settled_head)" ]; then record probe "$pub" || true; continue; fi

  # --check fetches objects only and moves no ref, so it classifies a dirty
  # copy too; an ahead copy with uncommitted edits is ordinary work, not news.
  dirty=0
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" ] || dirty=1
  rc=0
  out=$(FM_PR_RESYNC_TIMEOUT=$GIT_TIMEOUT "$SCRIPT_DIR/fm-pr-resync.sh" "$id" "$wt" "$branch" --check 2>&1) || rc=$?
  result=$(printf '%s\n' "$out" | sed -n 's/^fm-pr-resync: result=\([^ ]*\) .*/\1/p' | tail -n 1)
  if [ "$rc" -eq 3 ]; then
    note active "$pub" "pr-behind-active-$id-$(short "$pub")" \
      "check: $id's local branch $branch ($(short "$local_head")) is not at its PR head $(short "$pub") ($pr), and an active no-mistakes run holds the branch, so it was not relaunched; the run owns the branch until it ends"
    continue
  fi
  [ "$rc" -ne 0 ] || [ "$result" != planned:none ] || { record current "$pub" || true; continue; }
  if [ "$dirty" -eq 1 ] && { [ "$rc" -ne 0 ] || [ "$result" = planned:advance ]; }; then
    note dirty "$pub" "pr-behind-dirty-$id-$(short "$pub")" \
      "check: $id's local branch $branch ($(short "$local_head")) is behind its PR head $(short "$pub") ($pr), and its local copy has uncommitted changes, so it was not relaunched; the worker must commit or reconcile them first"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    detail=$(printf '%s\n' "$out" | sed -n 's/^fm-pr-resync: refused: //p' | head -n 1)
    note refused "$pub" "pr-behind-refused-$id-$(short "$pub")" \
      "check: $id's local branch $branch ($(short "$local_head")) is not at its PR head $(short "$pub") ($pr), and the resync check refused (exit $rc): ${detail:-no reason printed}; it was not relaunched - reconcile it by hand"
    continue
  fi
  case "$result" in
    planned:advance) ;;
    planned:archive-advance)
      note diverged "$pub" "pr-behind-diverged-$id-$(short "$pub")" \
        "check: $id's local branch $branch ($(short "$local_head")) diverged from its PR head $(short "$pub") ($pr), so it was not relaunched; the relaunch resync refuses a diverged branch - reconcile it by hand"
      continue
      ;;
    *)
      note refused "$pub" "pr-behind-refused-$id-$(short "$pub")" \
        "check: $id's resync check against its PR head $(short "$pub") ($pr) planned ${result:-nothing}, so it was not relaunched - reconcile it by hand"
      continue
      ;;
  esac
  if status_is_captain_held "$(status_declared_wait_line "$statusf")" \
    || FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --identity >/dev/null 2>&1; then
    record held "$pub" || true
    continue
  fi

  # Leave the request to a later sweep, with nothing recorded, when it could
  # not finish before the deadline; probed tasks are spaced out by then.
  left=$(( DEADLINE - $(date +%s) ))
  [ "$left" -lt "$RELAUNCH_TIMEOUT" ] || left=$RELAUNCH_TIMEOUT
  [ "$left" -ge "$RELAUNCH_MIN" ] || break
  record requested "$pub" || continue
  requested=1
  relaunch_note="Automatic relaunch: the watcher found this task's local branch $branch at $local_head, strictly behind its pull request head $pub on origin ($pr), with a clean local copy and no active no-mistakes run.
It restarted the worker so the relaunch could move the branch to that published head through bin/fm-pr-resync.sh; no local commit was discarded.
Its newest status events, oldest first:
$(tail -n 5 "$statusf" 2>/dev/null | sed 's/^/    /')
Re-read your instructions, check \`git status\` and \`git log\`, check \`no-mistakes axi status\` for any run on this branch, then continue from the published head."
  rc=0
  out=$(FM_HOME=$FM_HOME FM_SPAWN_NO_GUARD=1 FM_CONTROL_EXPECT_SPAWN_GEN=$(meta_get "$meta" spawn_gen) \
    fm_run_timed "$left" "$CONTROL" "$id" relaunch --note "$relaunch_note" </dev/null 2>&1) || rc=$?
  case "$rc" in
    0)
      record relaunched "$pub" || true
      emit "pr-behind-relaunched-$id-$(short "$pub")" \
        "check: $id relaunched because its local branch $branch ($(short "$local_head")) was behind its PR head $(short "$pub") ($pr) - the relaunch resynced it; reconcile its current state rather than relaunching it again"
      ;;
    5|6|7)
      # The control plane proved nothing reached the agent; retry on a later sweep.
      record deferred "$pub" || true
      ;;
    *)
      record failed "$pub" || true
      detail=$(printf '%s\n' "$out" | LC_ALL=C tr -d '\r' | awk 'NF { l = $0 } END { print substr(l, 1, 240) }')
      emit "pr-behind-failed-$id-$(short "$pub")" \
        "check: $id's local branch $branch ($(short "$local_head")) is behind its PR head $(short "$pub") ($pr), and its relaunch failed (exit $rc): ${detail:-no output} - recover it by hand, and check for unlanded work before any cleanup"
      ;;
  esac
done
exit 0
