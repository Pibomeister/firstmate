#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting), fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment), fm-dod-lib.sh
# (the custody check a Gerrit no-mistakes ready report must pass), and
# fm-heartbeat.sh (read-only fleet ledger). Crew-state binds
# an EXECUTING run (pending, running, fixing or ci) on the task's branch
# regardless of head (fm_nm_run_is_executing); every other run still needs
# strict branch-and-head identity. Both callers then recognize a provable
# pipeline-owned continuation through fm_nm_runs_status_for_worktree below:
# crew-state for an ACTIVE run - parked, or executing with the daemon answered
# down - so a fix round never reads as an older
# failed run, and teardown for a run PARKED at a gate, so cleanup concludes it
# instead of orphaning it. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to an arbitrary command in dir $1, timeout $2 seconds, and its
# `no-mistakes "$@"` specialization. Every branch is a hard limit: a child
# that ignores TERM is killed one second after the bound (timeout -k 1, or the
# perl branch's TERM then KILL), which the heartbeat run cap relies on. Any
# timed-out call exits 124, including one that needed the KILL. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
# The no-mistakes forms route host reads through the opt-in home resolver below.
fm_nm_bounded() {  # <dir> <timeout_secs> <command> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout|gtimeout)
      # timeout leads its own process group. A wrapper that exits on TERM
      # while a TERM-ignoring descendant holds the output open gets no KILL
      # from timeout, so a timed-out call reaps that leftover group itself.
      # Standard input is passed explicitly, never the background default.
      ( cd "$dir" || exit 1
        "$have_timeout" -k 1 "$timeout_secs" "$@" <&0 &
        runner=$!
        rc=0
        wait "$runner" || rc=$?
        # A KILL escalation (137) is still a timeout: report 124, as the perl
        # branch does, so no caller reads a killed probe as an answer.
        case "$rc" in 124|137) kill -KILL -- "-$runner" 2>/dev/null || true; rc=124 ;; esac
        exit "$rc" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" "$@" ) ;;
    *)        return 1 ;;
  esac
}

# Opt-in no-mistakes home resolver for sites that run one no-mistakes daemon
# per isolated workspace, each against its own NM_HOME. The home cannot be
# derived from the worktree's `no-mistakes` remote, because every workspace of
# a project shares one gate URL, so the site provides a resolver and Firstmate
# only calls it. The resolver is the executable whose absolute path is the
# first line of this home's config/nm-home-resolver; it is called with the
# worktree path as its only argument, bounded by 5 seconds, and its stdout,
# when it exits 0 with exactly one line naming an existing directory by
# absolute path, is the no-mistakes home for that worktree. The directory
# must already exist because the CLI creates a fresh home's skeleton on first
# read, so a wrong answer must not plant one.
# An explicit non-empty NM_HOME always wins and the resolver is not called.
# With no config file, a config file naming no absolute executable, or a
# resolver that fails, times out, or prints anything else, nothing is resolved
# and every read uses the ambient home exactly as without the hook.
# Prints the resolved home, or nothing. Never starts a daemon.
fm_nm_home_resolver_home() {  # <worktree>
  local wt=$1 cfg cmd out
  [ -z "${NM_HOME:-}" ] || return 0
  cfg=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/config}/nm-home-resolver
  [ -f "$cfg" ] || return 0
  IFS= read -r cmd < "$cfg" || [ -n "$cmd" ] || return 0
  cmd=$(fm_nm_trim "$cmd")
  case "$cmd" in /*) ;; *) return 0 ;; esac
  [ -f "$cmd" ] && [ -x "$cmd" ] || return 0
  out=$(fm_nm_bounded "$wt" 5 "$cmd" "$wt" 2>/dev/null </dev/null) || return 0
  case "$out" in
    /*) ;;
    *) return 0 ;;
  esac
  case "$out" in *$'\n'*) return 0 ;; esac
  [ -d "$out" ] || return 0
  printf '%s\n' "$out"
}

# 0 when the `no-mistakes` arguments are a host read or a run-targeted abort,
# the only calls the home resolver above may redirect: the bare `axi`
# overview, `axi status`, `axi logs`, `runs`, `daemon status`, and
# `axi abort --run <id>`. Anything else, such as starting or driving a run,
# keeps the ambient home.
fm_nm_home_resolver_applies() {  # <no-mistakes args...>
  case "${1:-}" in
    axi)
      [ "$#" -eq 1 ] && return 0
      case "${2:-}" in
        status|logs) return 0 ;;
        abort) [ "${3:-}" = --run ] && [ -n "${4:-}" ] && return 0 ;;
      esac ;;
    runs) return 0 ;;
    daemon) [ "${2:-}" = status ] && return 0 ;;
  esac
  return 1
}

fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 home=''
  shift 2
  if fm_nm_home_resolver_applies "$@"; then
    home=$(fm_nm_home_resolver_home "$dir")
  fi
  if [ -n "$home" ]; then
    NM_HOME=$home fm_nm_bounded "$dir" "$timeout_secs" no-mistakes "$@"
  else
    fm_nm_bounded "$dir" "$timeout_secs" no-mistakes "$@"
  fi
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

# ONE bounded `daemon status` call answering `up`, `unanswered` (the bounded
# call's own 124), or `down`. A clean stop also exits 0, with
# "○ daemon not running".
fm_nm_daemon_answer() {  # <dir> <timeout_secs>
  local rc=0 daemon_status
  daemon_status=$(fm_nm_run_checked "$1" "$2" daemon status) || rc=$?
  case "$rc" in
    0)
      if printf '%s\n' "$daemon_status" | grep -Eq '(^|[[:space:]])daemon running([[:space:]]|$)'; then
        printf 'up\n'
      else
        printf 'down\n'
      fi ;;
    124) printf 'unanswered\n' ;;
    *)   printf 'down\n' ;;
  esac
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Path of no-mistakes' local state database as the CLI would see it from
# worktree $1: <NM_HOME>/state.sqlite, with NM_HOME falling back to the home
# resolver above and then to ~/.no-mistakes, and a relative NM_HOME resolving
# from that worktree. Readers open it with SQLite's mode=ro, so a missing
# database is never created.
fm_nm_state_db() {  # <worktree>
  local root=${NM_HOME:-}
  [ -n "$root" ] || root=$(fm_nm_home_resolver_home "$1")
  [ -n "$root" ] || root=~/.no-mistakes
  case "$root" in
    /*) ;;
    *) root="$1/$root" ;;
  esac
  printf '%s/state.sqlite\n' "$root"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Full commit sha for sha-ish $2 as seen from worktree $1's own object store;
# empty when the object is absent or ambiguous. Read-only: never fetches,
# never moves refs or custody.
fm_nm_resolve_commit() {  # <worktree> <sha-ish>
  git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null || true
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# A run head whose object this copy does not have cannot be proven here and is
# rejected; fm_nm_runs_status_for_worktree below owns the one ledger-anchored
# recognition for that case, fm_nm_run_is_executing below is the current-state
# exemption for a live run on this branch regardless of head, and
# fm_nm_run_is_pipeline_owned_active below carries the custody exemption: ANY
# active run - executing or parked - whose pipeline currently owns the branch
# binds without head equality.
#
# This predicate binds one run at a time, and MORE THAN ONE recorded run can
# bind to the same worktree at once: a run that died at the worktree's exact
# commit still binds by the equal-commit rule while its live successor binds by
# the ancestor rule (observed 2026-08: a crashed validation daemon left a failed
# run at the worktree's own commit while the live run that replaced it validated
# a descendant commit on the same branch).
# Head compatibility alone does not establish precedence between runs.
# fm_nm_select_run below owns identity-aware selection for current-state reads;
# fm_nm_runs_status_for_worktree owns the coarse ledger fallback.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(fm_nm_resolve_commit "$wt" "$run_head")
  [ -n "$run_full" ] || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Liveness class of a recorded ledger status word.
# The coarse `no-mistakes runs` ledger emits database status words; an
# `axi status` run object reports its terminal result through its own outcome
# field as well, which fm_nm_run_is_active below checks directly.
fm_nm_run_status_class() {  # <status_word>
  case "${1:-}" in
    completed|failed|cancelled) printf 'terminal' ;;
    pending|running)            printf 'live' ;;
    *)                          printf 'unknown' ;;
  esac
}

# 0 when the status identity with $3 is newer than the same-branch candidate
# run with $2; 2 means same-head ULIDs share a creation timestamp. The runs
# ledger $6 is read only for different heads.
fm_nm_run_is_newer_than() {  # <branch> <candidate-id> <reported-id> <candidate-head> <reported-head> <runs-list>
  local branch=$1 selected_id=$2 reported_id=$3 selected_head=$4 reported_head=$5 runs=$6 first_match
  if [ -n "$selected_head" ] && [ "${selected_head:0:7}" = "${reported_head:0:7}" ]; then
    [[ "$selected_id" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ && "$reported_id" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || return 1
    [ "${selected_id:0:10}" = "${reported_id:0:10}" ] && return 2
    [[ "${reported_id:0:10}" > "${selected_id:0:10}" ]] && return 0
    return 1
  fi
  [ -n "$selected_head" ] && [ -n "$reported_head" ] \
    && [ "${selected_head:0:7}" != "${reported_head:0:7}" ] || return 1
  first_match=$(printf '%s\n' "$runs" | awk -v branch="$branch" \
    -v selected="${selected_head:0:7}" -v reported="${reported_head:0:7}" '
    $2 == branch {
      if (index($3, selected) == 1) { selected_count++; if (first == "") first = "selected" }
      else if (index($3, reported) == 1) { reported_count++; if (first == "") first = "reported" }
    }
    END {
      if (selected_count == 1 && reported_count == 1) print first
    }')
  [ "$first_match" = reported ]
}

# Select from a complete `no-mistakes axi` overview with the existing awk
# toolchain. A capped overview requires an optional Python 3 sqlite3 reader
# for a read-only same-branch query of the state database fm_nm_state_db
# locates for the worktree.
# Repo identity is the overview's own top-level `repo:` line, which every axi
# release emits: it is the `working_path` the CLI itself resolved for the
# queried worktree. That is NOT the task worktree path in general - a linked
# git worktree resolves to its main clone's registered path (observed
# 2026-09-22 on v1.79.0: every task copy of a firstmate home reports
# `repo: <home clone>`, and looking the repo up by the task worktree path
# matched no row, so every capped read reported the inventory unreadable).
# The recorded spelling is matched exactly, so an overview without exactly one
# absolute `repo:` line, or with one the inventory does not record, reads as
# unreadable rather than guessed among candidates.
# The reader subprocess is bounded by $4 seconds (default 10), so a contended
# database can never outlast the caller's per-read budget.
# If that reader or inventory is unavailable, report unknown with available
# candidate ids rather than treating the displayed window as complete.
# Structural completeness applies to the whole table; semantic validation
# applies only to the requested branch, after complete identity lookup when
# capped. Branch names are matched exactly without a character whitelist.
# Its rows are ordered by creation time descending (not last update), then id.
# The newest same-branch row is the candidate regardless of outcome: an older
# live run must not hide a newer failure. If the newest is live and another
# same-branch live run exists, neither has exclusive authority: report all
# candidate ids as unknown. A newer live row can replace cancelled history,
# but the caller must fetch its full status BY ID and prove branch/head,
# executing status, or active pipeline custody before using its steps.
# Never reuse another run's gate detail.
# This is a read-only selection, not teardown authorization.
#
# Prints selected|id|status|candidate-ids, unknown|reason, absent (no row
# for this branch), or unavailable (CLI has no overview table). Malformed or
# structurally truncated tables report unknown, retaining every readable
# same-branch candidate id.
fm_nm_select_run() {  # <branch> <axi-overview> <worktree> [timeout_secs]
  local selection inventory available_ids timeout_secs=${4:-10}
  case "$timeout_secs" in ''|*[!0-9]*) timeout_secs=10 ;; esac
  selection=$(printf '%s\n' "$2" | awk -v branch="$1" '
    function scalar(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^".*"$/) s = substr(s, 2, length(s)-2)
      return s
    }
    function row_fields(s, f, i, ch, n, quoted, escaped) {
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
      if (quoted || escaped) return 0
      for (i = 1; i <= n; i++) {
        sub(/^[ \t]+/, "", f[i]); sub(/[ \t]+$/, "", f[i])
      }
      return n
    }
    /^count: / {
      if (counts++) bad = 1
      count = scalar(substr($0, 8))
      if (count !~ /^[0-9]+ of [0-9]+ total$/) bad = 1
      split(count, c, " "); shown = c[1]; total = c[3]
    }
    /^runs\[[0-9]+\]\{id,branch,status,head,pr\}:$/ {
      if (found++) bad = 1
      expected = $0; sub(/^runs\[/, "", expected); sub(/\].*$/, "", expected)
      inrows = 1; next
    }
    /^runs\[/ { bad = 1; found = 1 }
    inrows && /^[ \t]+/ {
      seen++
      n = row_fields($0, f)
      if (n != 5) bad = 1
      id = f[1]; br = f[2]; st = f[3]; head = f[4]
      if (br != branch) next
      if (id ~ /^[A-Za-z0-9_-]+$/) {
        if (known[id]++) invalid_run = 1
        else ids = ids (ids == "" ? "" : ", ") id
      }
      if (n != 5) next
      if (id !~ /^[A-Za-z0-9_-]+$/ ||
          st !~ /^[a-z_-]+$/ || head !~ /^[a-fA-F0-9]+$/ || length(head) < 7 || length(head) > 40) {
        invalid_run = 1; next
      }
      if (first == "") { first = id; first_status = st }
      if (st == "running" || st == "pending") live++
      if (st !~ /^(pending|running|completed|failed|cancelled)$/) unknown_status = 1
      next
    }
    inrows { inrows = 0 }
    END {
      if (!found) print "unavailable"
      else if (bad || counts != 1 || (seen+0) != (expected+0) || (seen+0) != (shown+0) || (total+0) < (shown+0))
        print "unknown|unreadable runs table; run ids: " ids
      else if ((shown+0) < (total+0)) print "incomplete|" ids
      else if (invalid_run) print "unknown|unreadable runs table; run ids: " ids
      else if (unknown_status) print "unknown|unrecognized run status; run ids: " ids
      else if (first == "") print "absent"
      else if ((first_status == "running" || first_status == "pending") && live > 1)
        print "unknown|competing live runs; run ids: " ids
      else print "selected|" first "|" first_status "|" ids
    }
  ')
  case "$selection" in
    incomplete\|*) available_ids=${selection#*|} ;;
    *) printf '%s\n' "$selection"; return ;;
  esac
  if ! inventory=$(fm_nm_bounded "$3" "$timeout_secs" python3 - "$1" "$2" "$available_ids" "$(fm_nm_state_db "$3")" 2>/dev/null <<'PY'
import json
import os
import re
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

branch, overview, available_ids, database = sys.argv[1:]
ids = available_ids.split(", ") if available_ids else []
try:
    repos = [line[6:].strip() for line in overview.splitlines() if line.startswith("repo: ")]
    if len(repos) != 1:
        raise ValueError
    repo_path = json.loads(repos[0]) if repos[0].startswith('"') else repos[0]
    if not isinstance(repo_path, str) or not os.path.isabs(repo_path):
        raise ValueError
    with closing(sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
        db.execute("BEGIN")
        repo = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo_path,)).fetchall()
        if len(repo) != 1:
            raise ValueError
        rows = db.execute(
            "SELECT id, branch, status, head_sha FROM runs WHERE repo_id = ? AND branch = ? "
            "ORDER BY created_at DESC, id DESC", (repo[0][0], branch)
        ).fetchall()
    displayed_ids = set(ids)
    for row in rows:
        if isinstance(row[0], str) and re.fullmatch(r"[A-Za-z0-9_-]+", row[0]) and row[0] not in ids:
            ids.append(row[0])
    if not displayed_ids.issubset(row[0] for row in rows):
        raise ValueError
    for row in rows:
        if (not all(isinstance(value, str) for value in row)
                or not re.fullmatch(r"[A-Za-z0-9_-]+", row[0]) or row[1] != branch
                or not re.fullmatch(r"[a-z_-]+", row[2]) or not re.fullmatch(r"[a-fA-F0-9]{7,40}", row[3])):
            raise ValueError
    print("count: %d of %d total" % (len(rows), len(rows)))
    print("runs[%d]{id,branch,status,head,pr}:" % len(rows))
    for row in rows:
        print("  " + ",".join(json.dumps(value, ensure_ascii=False) for value in row) + ',""')
except (ValueError, OSError, sqlite3.Error):
    print("unknown|complete same-branch run inventory unreadable; run ids: " + ", ".join(ids))
PY
  ); then
    printf 'unknown|complete same-branch run inventory reader unavailable; run ids: %s\n' "$available_ids"
    return
  fi
  case "$inventory" in
    unknown\|*) selection=$inventory ;;
    *) selection=$(fm_nm_select_run "$1" "$inventory" "$3" "$timeout_secs") ;;
  esac
  case "$selection" in
    selected\|*|unknown\|*|absent) printf '%s\n' "$selection" ;;
    *) printf 'unknown|complete same-branch run inventory unreadable; run ids: %s\n' "$available_ids" ;;
  esac
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# One scalar from a nested block of the top-level `branch_sync:` block in
# captured `axi status` TOON $1: `<sub>.<key>` such as `next_action.code` or
# `pipeline.current_head`. Empty when either block or the key is absent.
# Indentation bounds each block, so a same-named key in a sibling sub-block
# (every sub-block of branch_sync carries its own `head`-like keys) is never
# read in its place.
fm_nm_branch_sync_nested() {  # <toon-output> <sub-block> <key>
  local s
  s=$(printf '%s\n' "$1" | awk -v sub_block="$2" -v key="$3" '
    function indent(line) { match(line, /[^ ]/); return RSTART - 1 }
    /^[^[:space:]]/ { in_sync = ($0 ~ /^branch_sync:[[:space:]]*$/); in_sub = 0; next }
    !in_sync { next }
    {
      ind = indent($0)
      if (in_sub && ind <= sub_ind) in_sub = 0
      if (!in_sub && $0 ~ ("^[[:space:]]+" sub_block ":[[:space:]]*$")) { in_sub = 1; sub_ind = ind; next }
      if (in_sub && ind > sub_ind && $0 ~ ("^[[:space:]]+" key ":")) {
        sub(("^[[:space:]]+" key ":[[:space:]]*"), "")
        print
        exit
      }
    }')
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The custody exemption to the head rule above: while the pipeline OWNS the
# branch (branch_sync.state=pipeline_owned), the daemon's own branch
# attribution IS the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# The gate evidence in an `axi status` TOON, as ONE set of patterns. Both
# readers must agree exactly: fm_nm_run_is_parked below decides whether a run
# keeps the strict head rule, and fm-crew-state.sh's nm_gate_step_row /
# nm_gate_status / nm_has_gate render the `parked at <gate>` detail from the
# same evidence. If a new parked marker is added to one reader only, an
# unverified run's gate detail reaches the crew report.
FM_NM_GATE_LINE_RE='^[[:space:]]*gate:[[:space:]]*'
FM_NM_AWAITING_AGENT_RE='^[[:space:]]*awaiting_agent:'
FM_NM_GATE_SCALAR_RE='^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$'
FM_NM_GATE_ROW_RE='^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,'

# 0 if the run in captured `axi status` TOON $1 carries any of those PARKED
# markers. The top-level `status:` word alone does NOT decide this: the CLI
# leaves it at `running` while a run waits at a gate, so the word and the gate
# markers routinely disagree.
fm_nm_run_is_parked() {  # <toon-output>
  printf '%s\n' "$1" | grep -Eq \
    "$FM_NM_GATE_LINE_RE|$FM_NM_AWAITING_AGENT_RE|$FM_NM_GATE_SCALAR_RE|$FM_NM_GATE_ROW_RE"
}

# 0 if the run in captured `axi status` TOON $1 is EXECUTING: in flight and
# actively working (pending, running, fixing, or ci), not parked at a gate.
# Read-only current-state reporting (fm-crew-state.sh) treats an executing run
# on the task's own branch as authoritative REGARDLESS of head: the pipeline
# rebases the branch and commits fix rounds in its own checkout, so a live run's
# head routinely differs from the task worktree's local head, and falling back
# to an older run that matches the local head reads a working crew as failed.
# A run parked at a gate keeps the strict head rule, and no destructive caller
# uses this predicate: teardown stays on fm_nm_head_matches_worktree and the
# ledger rule below.
# This predicate reads the RECORD only; it cannot tell a live run from one whose
# daemon died still saying `running`. The head-free route through it is the
# caller's to license, and fm-crew-state.sh pairs it with an explicit
# daemon-down probe for exactly that reason.
# All four accepted words reach here on BOTH surfaces. The overview table
# fm_nm_select_run validates carries a narrower column
# (pending|running|completed|failed|cancelled, its unknown_status check), but that column is not
# what this predicate reads: the selected-run route re-reads the run by id and
# passes that DETAIL object, whose own vocabulary check admits `fixing` and `ci`
# as live, and the legacy bare-status route passes the same detail shape.
# Dropping them would report a fix round or a ci wait as idle, which is the
# misreport this predicate exists to prevent.
fm_nm_run_is_executing() {  # <toon-output>
  fm_nm_run_is_active "$1" || return 1
  fm_nm_run_is_parked "$1" && return 1
  case "$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")" in
    pending|running|fixing|ci) return 0 ;;
  esac
  return 1
}

# Structural validation for one ledger row, already split into its columns.
# Both readers of the `no-mistakes runs` listing apply exactly this rule, so a
# row one of them rejects is never evidence for the other.
fm_nm_runs_row_valid() {  # <status> <branch> <sha> <day> <clock> <pr> <extra>
  local st=$1 br=$2 sha=$3 day=$4 clock=$5 pr=$6 extra=$7
  local year_num month_num day_num max_day
  [ -n "$st" ] && [ -n "$br" ] && [ -n "$sha" ] && [ -n "$day" ] && [ -n "$clock" ] || return 1
  [ -z "$extra" ] || return 1
  case "$st" in *[!a-z_-]*) return 1 ;; esac
  case "$br" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$sha" in *[!A-Fa-f0-9]*) return 1 ;; esac
  case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) return 1 ;; esac
  case "$pr" in ''|https://*) ;; *) return 1 ;; esac
  [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || return 1
  year_num=$((10#${day%%-*}))
  month_num=${day#*-}; month_num=${month_num%%-*}; month_num=$((10#$month_num))
  day_num=$((10#${day##*-}))
  [ "$year_num" -gt 0 ] && [ "$month_num" -ge 1 ] && [ "$month_num" -le 12 ] || return 1
  case "$month_num" in
    1|3|5|7|8|10|12) max_day=31 ;;
    4|6|9|11) max_day=30 ;;
    2)
      if (( year_num % 400 == 0 || (year_num % 4 == 0 && year_num % 100 != 0) )); then
        max_day=29
      else
        max_day=28
      fi
      ;;
  esac
  [ "$day_num" -ge 1 ] && [ "$day_num" -le "$max_day" ] || return 1
  return 0
}

# ONE owner for attribution from the pipeline's own runs ledger, replacing a
# per-row scan-and-skip. The ledger is the real top-level `no-mistakes runs
# --limit N` listing (plain text, no run id, no quoting, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]"; the `axi` surface has no
# runs-listing subcommand - verified against the installed CLI). Prints the
# status word of the branch's CURRENT run row, or nothing when the ledger
# cannot prove attribution. When optional expected head $4 is supplied, its
# abbreviated commit identity must match the newest row. The branch's NEWEST
# row alone decides; older rows are history and never answer for the present:
#   - newest row's head resolves and matches the worktree (fm_nm_head_matches_worktree):
#     its status word
#   - newest row's head resolves but does not match: nothing (a newer run that
#     is not this worktree's makes every older row stale history)
#   - newest row's head does not resolve in this copy (the pipeline committed
#     its fix round in its own checkout and the task copy never fetched it):
#     recognized ONLY as a provable pipeline-owned continuation of the
#     submitted head, which requires ALL of: the row is ACTIVE (status
#     running), and the immediately older row for the SAME branch resolves to
#     EXACTLY the worktree HEAD. The pipeline's own ledger then proves an
#     unbroken run sequence from a run that ended at the submitted head to an
#     active run on the same branch - the anchored active row's status word is
#     printed. Anything else (no anchor row, an anchor that is merely an
#     ancestor, a terminal unresolvable row) prints nothing, so branch-name
#     coincidence, arbitrary remote state, and other tasks' runs never match.
# An older live row never displaces a newer terminal result.
# There is no branch-name-only acceptance here: a live row whose head this copy
# cannot tie to the worktree is not this worktree's run just because the branch
# name matches. The one live bind is the EXECUTING record on the `axi status`
# route (fm_nm_run_is_executing above), which the caller pairs with its own
# liveness evidence.
# Read-only: git reads resolve objects in place; custody never changes.
fm_nm_runs_status_for_worktree() {  # <worktree> <branch> <runs-list-output> [expected-head]
  local wt=$1 branch=$2 list=$3 expected_head=${4:-}
  local local_full row_full row st br sha day clock pr extra pending_st=''
  local decided=''
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    fm_nm_runs_row_valid "$st" "$br" "$sha" "$day" "$clock" "$pr" "$extra" || break
    [ "$br" = "$branch" ] || continue
    if [ -n "$pending_st" ]; then
      # This is the row immediately older than the active unresolvable row:
      # the only admissible anchor, and only exact head equality proves the
      # worktree still sits at the submitted head.
      if [ "$(fm_nm_resolve_commit "$wt" "$sha")" = "$local_full" ]; then
        decided=$pending_st
      fi
      break
    fi
    if [ -n "$expected_head" ]; then
      case "$expected_head" in *[!A-Fa-f0-9]*|'') break ;; esac
      [ "${#expected_head}" -ge 7 ] && [ "${#expected_head}" -le 40 ] || break
      case "$expected_head" in
        "$sha"*) ;;
        *) case "$sha" in "$expected_head"*) ;; *) break ;; esac ;;
      esac
    fi
    row_full=$(fm_nm_resolve_commit "$wt" "$sha")
    if [ -n "$row_full" ]; then
      if fm_nm_head_matches_worktree "$wt" "$sha"; then
        decided=$st
      fi
      break
    fi
    [ "$st" = running ] || break
    pending_st=$st
  done <<< "$list"
  printf '%s' "$decided"
  return 0
}

# Values of column $3 in table $2 (for example `steps` or `active_steps`) of
# captured `axi status` TOON $1, one line per row, quotes stripped. The column
# is found by name in the table's own header, so column order is never
# assumed; a quoted cell may hold commas. Prints nothing when the table or
# column is absent.
fm_nm_table_column() {  # <toon-output> <table> <column>
  printf '%s\n' "$1" | awk -v table="$2" -v column="$3" '
    function cells(line, out,    n, i, c, q, cur) {
      n = 0; cur = ""; q = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") { q = !q; continue }
        if (c == "," && !q) { out[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      out[++n] = cur
      return n
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    !inblock {
      if (match($0, "^[ \t]*" table "\\[[0-9]+\\]\\{[^}]*\\}:")) {
        hdr = index($0, table)
        cols = substr($0, index($0, "{") + 1)
        cols = substr(cols, 1, index(cols, "}") - 1)
        ncol = split(cols, names, ",")
        want = 0
        for (i = 1; i <= ncol; i++) if (trim(names[i]) == column) want = i
        if (!want) exit
        inblock = 1
      }
      next
    }
    {
      if ($0 ~ /^[ \t]*$/) exit
      match($0, /[^ \t]/)
      if (RSTART <= hdr) exit
      n = cells(trim($0), row)
      print (want <= n ? trim(row[want]) : "")
    }
  '
}

# Validation progress of the run in captured `axi status` TOON $1, as
# "<percent>\t<position>\t<total>\t<step>\t<round>": <total> is the number of
# rows in the run's steps[] table, completed and skipped steps count as done,
# <percent> is done*100/total, <step> is the active step (from active_steps[],
# else the first step not yet done) at 1-based <position>, and <round> is the
# active step's round, such as `auto-fix 1/3`. Fails when the run has no steps
# table. Display only: it does not decide which run is the task's.
fm_nm_run_progress() {  # <toon-output>
  local names=() statuses=() total done=0 position=0 step='' round='' active i
  while IFS= read -r i; do names+=("$i"); done < <(fm_nm_table_column "$1" steps step)
  while IFS= read -r i; do statuses+=("$i"); done < <(fm_nm_table_column "$1" steps status)
  total=${#names[@]}
  [ "$total" -gt 0 ] || return 1
  for ((i = 0; i < total; i++)); do
    case "${statuses[i]:-}" in
      completed | skipped) done=$((done + 1)) ;;
      *) [ -n "$step" ] || { step=${names[i]}; position=$((i + 1)); } ;;
    esac
  done
  active=$(fm_nm_table_column "$1" active_steps step | head -1)
  if [ -n "$active" ]; then
    for ((i = 0; i < total; i++)); do
      [ "${names[i]}" = "$active" ] || continue
      step=$active
      position=$((i + 1))
      round=$(fm_nm_table_column "$1" active_steps round | head -1)
      break
    done
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$((done * 100 / total))" "$position" "$total" "$step" "$round"
}

# The branch's NEWEST ledger row as "<status>|<short-sha>|<pr>", or nothing when
# the branch has no row. The ledger is newest-first and its newest row for a branch
# IS that branch's current run, which is the same rule
# fm_nm_runs_status_for_worktree applies; this accessor exists because a caller
# holding a TERMINAL run answer needs to know whether a LATER run has since
# superseded it, which the status word alone cannot say. The ledger has no run
# ID, so these fields can expose disagreement with a full run answer but cannot
# establish identity; BINDING a run still needs the strict rules above.
fm_nm_runs_newest_for_branch() {  # <branch> <runs-list-output>
  local branch=$1 list=$2 row st br sha day clock pr extra
  [ -n "$list" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    IFS=$' \t' read -r st br sha day clock pr extra <<< "$row"
    fm_nm_runs_row_valid "$st" "$br" "$sha" "$day" "$clock" "$pr" "$extra" || break
    [ "$br" = "$branch" ] || continue
    printf '%s|%s|%s' "$st" "$sha" "$pr"
    return 0
  done <<< "$list"
  return 0
}

# --- read-only SQLite status snapshot (one snapshot per supervision sweep) --
# Reads <NM_HOME>/state.sqlite strictly read-only (?mode=ro + PRAGMA
# query_only=ON) behind a schema-version and column-contract guard, caching
# one short-lived snapshot across crewmate reads in a supervision sweep and
# failing closed (returning 1) when the database is absent, unreadable,
# corrupt, or uses an unknown schema version so callers fall back to the
# daemon/CLI calls. Never creates or writes state.sqlite.
FM_NM_SNAPSHOT_SCHEMA_VERSION=1
FM_NM_SQLITE_USER_VERSION=${FM_NM_SQLITE_USER_VERSION:-0}
FM_NM_SNAPSHOT_TTL=${FM_NM_SNAPSHOT_TTL:-5}

fm_nm_status_snapshot_path() {  # [state_dir]
  if [ -n "${FM_NM_STATUS_SNAPSHOT:-}" ]; then
    printf '%s\n' "$FM_NM_STATUS_SNAPSHOT"
  elif [ -n "${1:-}" ]; then
    printf '%s/.nm-status-snapshot.json\n' "$1"
  elif [ -n "${STATE:-}" ]; then
    printf '%s/.nm-status-snapshot.json\n' "$STATE"
  fi
}

# Populate NM_SNAPSHOT_STATUS_OUT, NM_SNAPSHOT_OVERVIEW_OUT,
# NM_SNAPSHOT_SELECTED_ID, NM_SNAPSHOT_SELECTED_OUT, NM_SNAPSHOT_RUNS_LIST,
# and NM_SNAPSHOT_CI_LOG for worktree $1 and branch $2 from the read-only
# SQLite status snapshot. Returns 0 when the snapshot is valid and matched the
# worktree's repository, or 1 on any schema-guard or read failure so the
# caller falls back to the no-mistakes CLI.
# shellcheck disable=SC2034 # Out-parameters read by callers (fm-crew-state.sh).
fm_nm_snapshot_load_worktree() {  # <worktree> <branch> <timeout_secs> <runs_limit> [snapshot_file]
  local wt=$1 branch=$2 timeout_secs=${3:-10} runs_limit=${4:-50} snapshot_file=${5:-}
  local db_path out line section=""
  NM_SNAPSHOT_STATUS_OUT=""
  NM_SNAPSHOT_OVERVIEW_OUT=""
  NM_SNAPSHOT_SELECTED_ID=""
  NM_SNAPSHOT_SELECTED_OUT=""
  NM_SNAPSHOT_RUNS_LIST=""
  NM_SNAPSHOT_CI_LOG=""
  case "$timeout_secs" in ''|*[!0-9]*) timeout_secs=10 ;; esac
  case "$runs_limit" in ''|*[!0-9]*) runs_limit=50 ;; esac
  db_path=$(fm_nm_state_db "$wt")
  [ -f "$db_path" ] && [ -r "$db_path" ] || return 1
  out=$(fm_nm_bounded "$wt" "$timeout_secs" python3 - \
    "$wt" "$branch" "$runs_limit" "$snapshot_file" "$db_path" \
    "$FM_NM_SNAPSHOT_SCHEMA_VERSION" "$FM_NM_SQLITE_USER_VERSION" "$FM_NM_SNAPSHOT_TTL" 2>/dev/null <<'PY'
import datetime
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from pathlib import Path

wt, branch, runs_limit_s, snapshot_file, database, schema_ver_s, user_ver_s, ttl_s = sys.argv[1:]
runs_limit = int(runs_limit_s)
expected_schema_ver = int(schema_ver_s)
expected_user_ver = int(user_ver_s)
ttl = float(ttl_s)
now = time.time()

REQUIRED_COLUMNS = {
    "repos": {"id", "working_path"},
    "runs": {
        "id", "repo_id", "branch", "status", "head_sha", "pr_url",
        "gates_json", "error", "awaiting_agent_since", "created_at",
    },
    "step_results": {
        "run_id", "step_name", "step_order", "status", "duration_ms",
        "findings_json", "log_path", "last_activity_at", "last_activity",
        "override_reason", "skip_reason",
    },
}
KNOWN_RUN_STATUSES = {
    "pending", "running", "fixing", "ci", "awaiting_approval",
    "fix_review", "completed", "failed", "cancelled", "checks_passed_released",
}
KNOWN_STEP_STATUSES = {
    "pending", "running", "fixing", "awaiting_approval", "fix_review",
    "completed", "failed", "cancelled", "skipped",
}
CI_MARKER_RE = re.compile(
    r"CI checks passed|repository declares no CI \(no_ci: true\)|"
    r"no CI checks reported - still monitoring|no CI checks reported yet|"
    r"checks failed|issues detected|CI checks running"
)


def compute_db_fingerprint(db_file: str) -> str:
    st = os.stat(db_file)
    if st.st_size < 100:
        raise ValueError("database too small")
    with open(db_file, "rb") as fh:
        header = fh.read(100)
    if header[:16] != b"SQLite format 3\x00":
        raise ValueError("not a sqlite3 file")
    h = hashlib.sha256()
    h.update(f"{st.st_mtime_ns}:{st.st_size}:".encode())
    h.update(header)
    for suffix in ("-wal", "-shm"):
        aux = db_file + suffix
        if os.path.exists(aux):
            ast = os.stat(aux)
            h.update(f"|{suffix}:{ast.st_mtime_ns}:{ast.st_size}:".encode())
            if suffix == "-wal" and ast.st_size > 0:
                with open(aux, "rb") as afh:
                    h.update(afh.read(64))
                    if ast.st_size > 64:
                        afh.seek(max(0, ast.st_size - 64))
                        h.update(afh.read(64))
        else:
            h.update(f"|{suffix}:absent".encode())
    return h.hexdigest()


def load_cached_snapshot(snap_path: str, db_real: str, db_fp: str):
    if not snap_path or not os.path.isfile(snap_path):
        return None
    try:
        st = os.stat(snap_path)
        if ttl < 0 or (now - st.st_mtime) > ttl or (st.st_mtime - now) > 60:
            return None
        with open(snap_path, "r", encoding="utf-8") as fh:
            snap = json.load(fh)
        if not isinstance(snap, dict):
            return None
        if snap.get("schema_version") != expected_schema_ver:
            return None
        if snap.get("db_user_version") != expected_user_ver:
            return None
        if snap.get("db_path") != db_real:
            return None
        if snap.get("db_fingerprint") != db_fp:
            return None
        captured_at = snap.get("captured_at")
        if not isinstance(captured_at, (int, float)):
            return None
        if (now - float(captured_at)) > ttl or (float(captured_at) - now) > 60:
            return None
        if not isinstance(snap.get("repos"), dict) or not isinstance(snap.get("runs_by_repo"), dict):
            return None
        return snap
    except (OSError, ValueError, TypeError):
        return None


def capture_snapshot_from_sqlite(db_file: str, db_real: str, db_fp: str) -> dict:
    uri = Path(db_real).as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=30)) as db:
        db.execute("PRAGMA query_only = ON")
        db.execute("BEGIN")
        u_row = db.execute("PRAGMA user_version").fetchone()
        if not u_row or not isinstance(u_row[0], int) or u_row[0] != expected_user_ver:
            raise ValueError("schema user_version mismatch")
        for tbl_row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schema_version', 'schema_migrations')"
        ).fetchall():
            tname = tbl_row[0]
            v_rows = db.execute(f"SELECT * FROM {tname}").fetchall()
            for v_row in v_rows:
                if v_row and str(v_row[0]) != str(expected_user_ver):
                    raise ValueError("schema version table mismatch")
        for table_name, req_cols in REQUIRED_COLUMNS.items():
            cols = {
                row[1]
                for row in db.execute(f"PRAGMA table_info({table_name})").fetchall()
                if len(row) > 1 and isinstance(row[1], str)
            }
            if not req_cols.issubset(cols):
                raise ValueError(f"missing required columns on {table_name}")
        repos = {}
        for repo_id, working_path in db.execute("SELECT id, working_path FROM repos").fetchall():
            if not isinstance(repo_id, str) or not isinstance(working_path, str) or not working_path:
                raise ValueError("invalid repo row")
            repos[repo_id] = working_path

        runs_rows = db.execute(
            "SELECT id, repo_id, branch, status, head_sha, pr_url, gates_json, "
            "error, awaiting_agent_since, created_at "
            "FROM runs ORDER BY created_at DESC, id DESC"
        ).fetchall()

        steps_by_run = {}
        for srow in db.execute(
            "SELECT run_id, step_name, step_order, status, duration_ms, findings_json, "
            "log_path, last_activity_at, last_activity, override_reason, skip_reason "
            "FROM step_results ORDER BY run_id, step_order ASC"
        ).fetchall():
            run_id = srow[0]
            if not isinstance(run_id, str):
                continue
            steps_by_run.setdefault(run_id, []).append({
                "step_name": srow[1] if isinstance(srow[1], str) else "",
                "step_order": int(srow[2]) if isinstance(srow[2], int) else 0,
                "status": srow[3] if isinstance(srow[3], str) else "",
                "duration_ms": int(srow[4]) if isinstance(srow[4], int) and srow[4] >= 0 else 0,
                "findings_json": srow[5] if isinstance(srow[5], str) else "",
                "log_path": srow[6] if isinstance(srow[6], str) else "",
                "last_activity_at": int(srow[7]) if isinstance(srow[7], int) else 0,
                "last_activity": srow[8] if isinstance(srow[8], str) else "",
                "override_reason": srow[9] if isinstance(srow[9], str) else "",
                "skip_reason": srow[10] if isinstance(srow[10], str) else "",
            })

        runs_by_repo = {rid: [] for rid in repos}
        for r in runs_rows:
            rid, repo_id, br, st, head_sha, pr_url, gates_json, err, awaiting, created_at = r
            if repo_id not in runs_by_repo:
                continue
            runs_by_repo[repo_id].append({
                "id": rid,
                "repo_id": repo_id,
                "branch": br,
                "status": st,
                "head_sha": head_sha,
                "pr_url": pr_url if isinstance(pr_url, str) else "",
                "gates_json": gates_json if isinstance(gates_json, str) else "",
                "error": err if isinstance(err, str) else "",
                "awaiting_agent_since": int(awaiting) if isinstance(awaiting, int) else 0,
                "created_at": created_at,
                "steps": steps_by_run.get(rid, []),
            })

    return {
        "schema_version": expected_schema_ver,
        "db_user_version": expected_user_ver,
        "captured_at": now,
        "db_path": db_real,
        "db_fingerprint": db_fp,
        "repos": repos,
        "runs_by_repo": runs_by_repo,
    }


def write_snapshot_atomic(snap_path: str, snap: dict) -> None:
    if not snap_path:
        return
    try:
        parent = os.path.dirname(snap_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp_path = f"{snap_path}.tmp.{os.getpid()}"
        with open(tmp_path, "w", encoding="utf-8") as fh:
            json.dump(snap, fh, ensure_ascii=False)
        os.replace(tmp_path, snap_path)
    except OSError:
        pass


def git_out(args):
    try:
        res = subprocess.run(
            ["git", "-C", wt] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0:
            return res.stdout.strip()
    except Exception:
        pass
    return ""


def resolve_repo_id(repos_map: dict):
    candidates = []
    def add_cand(p):
        if not p:
            return
        for v in (p, os.path.realpath(p)):
            if v and v not in candidates:
                candidates.append(v)

    top = git_out(["rev-parse", "--show-toplevel"])
    add_cand(top)
    add_cand(wt)
    common = git_out(["rev-parse", "--git-common-dir"])
    if common:
        if not os.path.isabs(common):
            common = os.path.normpath(os.path.join(top or wt, common))
        if os.path.basename(os.path.normpath(common)) == ".git":
            add_cand(os.path.dirname(os.path.normpath(common)))
    wt_list = git_out(["worktree", "list", "--porcelain"])
    if wt_list:
        for line in wt_list.splitlines():
            if line.startswith("worktree "):
                add_cand(line[9:].strip())
                break

    by_exact = {}
    by_real = {}
    for rid, wpath in repos_map.items():
        by_exact.setdefault(wpath, []).append(rid)
        by_real.setdefault(os.path.realpath(wpath), []).append(rid)

    for cand in candidates:
        if cand in by_exact and len(by_exact[cand]) == 1:
            return by_exact[cand][0]
        if cand in by_real and len(by_real[cand]) == 1:
            return by_real[cand][0]
    return None


def parse_findings_list(findings_json: str):
    if not findings_json:
        return []
    data = json.loads(findings_json)
    if isinstance(data, dict):
        items = data.get("findings")
        if items is None:
            return []
        if not isinstance(items, list):
            raise ValueError("invalid findings list")
        return items
    if isinstance(data, list):
        return data
    raise ValueError("invalid findings_json")


def clean_scalar(val: str) -> str:
    return val.replace("\r", " ").replace("\n", " ").replace(",", "_").strip()


def format_run_detail(run: dict) -> str:
    rid = run["id"]
    br = run["branch"]
    raw_st = run["status"]
    st = "completed" if raw_st == "checks_passed_released" else raw_st
    head_sha = run["head_sha"]
    pr_url = run.get("pr_url") or ""
    awaiting = int(run.get("awaiting_agent_since") or 0)
    steps = run.get("steps") or []
    gates_json = run.get("gates_json") or ""

    lines = [
        f'id: {json.dumps(rid, ensure_ascii=False)}',
        f'branch: {json.dumps(br, ensure_ascii=False)}',
        f'status: {json.dumps(st, ensure_ascii=False)}',
    ]

    gate_step = ""
    gate_status = ""
    gate_findings = []
    for s in steps:
        sname = s.get("step_name") or ""
        sst = s.get("status") or ""
        if sst not in KNOWN_STEP_STATUSES or not sname:
            raise ValueError("invalid step row")
        if not gate_step and sst in ("awaiting_approval", "fix_review"):
            gate_step = sname
            gate_status = sst
            gate_findings = parse_findings_list(s.get("findings_json") or "")

    if not gate_step and gates_json and gates_json not in ("{}", "[]"):
        gdata = json.loads(gates_json)
        if isinstance(gdata, dict):
            gate_step = str(gdata.get("step") or "")
            gate_status = str(gdata.get("status") or "")
            if isinstance(gdata.get("findings"), list):
                gate_findings = gdata["findings"]

    is_terminal = raw_st in ("completed", "failed", "cancelled", "checks_passed_released")
    if not is_terminal and (awaiting > 0 or gate_step or gate_status in ("awaiting_approval", "fix_review")):
        if awaiting > 0:
            lines.append("awaiting_agent: parked")

    lines.append(f'head: {json.dumps(head_sha[:8], ensure_ascii=False)}')
    lines.append(f'head_sha: {json.dumps(head_sha, ensure_ascii=False)}')
    if pr_url:
        lines.append(f'pr: {json.dumps(pr_url, ensure_ascii=False)}')

    if is_terminal:
        if raw_st == "failed":
            outcome = "failed"
        elif raw_st == "cancelled":
            outcome = "cancelled"
        elif raw_st == "checks_passed_released":
            outcome = "checks-passed"
        else:
            has_override = any(bool((s.get("override_reason") or "").strip()) for s in steps)
            has_skip = any(
                (s.get("step_name") in ("pr", "ci"))
                and s.get("status") == "skipped"
                and bool((s.get("skip_reason") or "").strip())
                for s in steps
            )
            if has_override:
                outcome = "passed-with-override"
            elif has_skip:
                outcome = "passed-with-skips"
            else:
                outcome = "passed"
        lines.append(f"outcome: {outcome}")

    if steps:
        lines.append(f"steps[{len(steps)}]{{step,status,findings,duration_ms}}:")
        for s in steps:
            flist = parse_findings_list(s.get("findings_json") or "")
            dur = int(s.get("duration_ms") or 0)
            lines.append(f'  {clean_scalar(s["step_name"])},{clean_scalar(s["status"])},{len(flist)},{dur}')

    active_steps = [s for s in steps if s.get("status") in ("running", "fixing")]
    if active_steps and not is_terminal:
        lines.append(f"active_steps[{len(active_steps)}]{{step,status,round,last_activity}}:")
        for s in active_steps:
            last_act = (s.get("last_activity") or "").replace("\r", " ").replace("\n", " ").strip()
            last_at = int(s.get("last_activity_at") or 0)
            if "quiet" not in last_act and last_at > 0 and (now - last_at) > 180:
                last_act = f"quiet: {last_act or 'running'}"
            elif not last_act:
                last_act = "running"
            lines.append(
                f'  {clean_scalar(s["step_name"])},{clean_scalar(s["status"])},starting,{json.dumps(last_act, ensure_ascii=False)}'
            )

    if not is_terminal and (gate_step or gate_status in ("awaiting_approval", "fix_review")):
        lines.append("gate:")
        if gate_step:
            lines.append(f'  step: {json.dumps(gate_step, ensure_ascii=False)}')
        if gate_status:
            lines.append(f'  status: {json.dumps(gate_status, ensure_ascii=False)}')
        if gate_findings:
            lines.append(f"  findings[{len(gate_findings)}]{{id,severity,file,action,description}}:")
            for idx, f in enumerate(gate_findings, 1):
                if not isinstance(f, dict):
                    continue
                fid = clean_scalar(str(f.get("id") or f"f{idx}"))
                sev = clean_scalar(str(f.get("severity") or "warning"))
                ffile = clean_scalar(str(f.get("file") or ""))
                raw_act = f.get("action")
                if raw_act is None:
                    raw_act = f.get("authority") or ""
                act = clean_scalar(str(raw_act))
                desc = str(f.get("description") or "").replace("\r", " ").replace("\n", " ").strip()
                lines.append(f'    {fid},{sev},{ffile},{act},{json.dumps(desc, ensure_ascii=False)}')

    return "\n".join(lines)


def overview_status_word(raw_st: str) -> str:
    if raw_st == "checks_passed_released":
        return "completed"
    if raw_st in ("fixing", "ci", "awaiting_approval", "fix_review"):
        return "running"
    return raw_st


def format_created_at(val) -> str:
    if isinstance(val, (int, float)) or (isinstance(val, str) and re.fullmatch(r"[0-9]+", val.strip())):
        ts = int(val)
        dt = datetime.datetime.fromtimestamp(ts)
        return dt.strftime("%Y-%m-%d %H:%M")
    if isinstance(val, str):
        m = re.match(r"^([0-9]{4}-[0-9]{2}-[0-9]{2})[T ]([0-9]{2}:[0-9]{2})", val.strip())
        if m:
            return f"{m.group(1)} {m.group(2)}"
    raise ValueError("invalid created_at")


def read_ci_log_for_run(run: dict, db_real: str) -> str:
    if not run:
        return ""
    nm_home = os.path.dirname(db_real)
    candidates = []
    for s in run.get("steps") or []:
        if s.get("step_name") == "ci":
            lp = (s.get("log_path") or "").strip()
            if lp:
                candidates.append(lp)
    candidates.append(os.path.join(nm_home, "logs", run["id"], "ci.log"))
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.R_OK):
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    matched = [ln.rstrip("\r\n") for ln in fh if CI_MARKER_RE.search(ln)]
                if matched:
                    return matched[-1]
            except OSError:
                pass
    for s in run.get("steps") or []:
        if s.get("step_name") == "ci":
            la = (s.get("last_activity") or "").strip()
            if la and CI_MARKER_RE.search(la):
                return la
    return ""


try:
    db_real = os.path.realpath(database)
    db_fp = compute_db_fingerprint(db_real)
    snap = load_cached_snapshot(snapshot_file, db_real, db_fp)
    if snap is None:
        snap = capture_snapshot_from_sqlite(database, db_real, db_fp)
        write_snapshot_atomic(snapshot_file, snap)

    repo_id = resolve_repo_id(snap["repos"])
    if not repo_id:
        sys.exit(1)
    repo_path = snap["repos"][repo_id]
    repo_runs = snap["runs_by_repo"].get(repo_id, [])

    for r in repo_runs:
        rid = r.get("id")
        br = r.get("branch")
        st = r.get("status")
        head_sha = r.get("head_sha")
        if (not isinstance(rid, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", rid)
                or not isinstance(br, str) or not br
                or not isinstance(st, str) or st not in KNOWN_RUN_STATUSES
                or not isinstance(head_sha, str) or not re.fullmatch(r"[a-fA-F0-9]{7,40}", head_sha)):
            raise ValueError("invalid run row")

    overview_lines = [
        f"repo: {json.dumps(repo_path, ensure_ascii=False)}",
        f"count: {len(repo_runs)} of {len(repo_runs)} total",
        f"runs[{len(repo_runs)}]{{id,branch,status,head,pr}}:",
    ]
    for r in repo_runs:
        ov_st = overview_status_word(r["status"])
        row_vals = [r["id"], r["branch"], ov_st, r["head_sha"], r.get("pr_url") or ""]
        overview_lines.append("  " + ",".join(json.dumps(v, ensure_ascii=False) for v in row_vals))
    overview_out = "\n".join(overview_lines)

    branch_runs = [r for r in repo_runs if r["branch"] == branch]
    if not branch_runs:
        status_out = f"current_branch: {json.dumps(branch, ensure_ascii=False)}\nruns_on_current_branch: 0"
        selected_id = ""
        selected_out = ""
        ci_log_out = ""
    else:
        selected_run = branch_runs[0]
        selected_id = selected_run["id"]
        selected_out = format_run_detail(selected_run)
        active_branch_runs = [
            r for r in branch_runs
            if overview_status_word(r["status"]) in ("pending", "running")
        ]
        status_run = active_branch_runs[0] if active_branch_runs else selected_run
        status_out = format_run_detail(status_run)
        ci_log_out = read_ci_log_for_run(selected_run, db_real)

    runs_list_lines = []
    for r in repo_runs[:runs_limit]:
        ov_st = overview_status_word(r["status"])
        br = r["branch"]
        sha7 = r["head_sha"][:7]
        dt_str = format_created_at(r.get("created_at"))
        pr = (r.get("pr_url") or "").strip()
        if pr.startswith("https://"):
            runs_list_lines.append(f"{ov_st} {br} {sha7} {dt_str} {pr}")
        else:
            runs_list_lines.append(f"{ov_st} {br} {sha7} {dt_str}")
    runs_list_out = "\n".join(runs_list_lines)

    print("__FM_NM_SECTION_STATUS__")
    if status_out:
        print(status_out)
    print("__FM_NM_SECTION_OVERVIEW__")
    if overview_out:
        print(overview_out)
    print("__FM_NM_SECTION_SELECTED_ID__")
    if selected_id:
        print(selected_id)
    print("__FM_NM_SECTION_SELECTED__")
    if selected_out:
        print(selected_out)
    print("__FM_NM_SECTION_RUNS_LIST__")
    if runs_list_out:
        print(runs_list_out)
    print("__FM_NM_SECTION_CI_LOG__")
    if ci_log_out:
        print(ci_log_out)
    print("__FM_NM_SECTION_END__")
except Exception:
    if snapshot_file:
        try:
            os.unlink(snapshot_file)
        except OSError:
            pass
    sys.exit(1)
PY
  ) || return 1

  while IFS= read -r line; do
    case "$line" in
      __FM_NM_SECTION_STATUS__) section=status; continue ;;
      __FM_NM_SECTION_OVERVIEW__) section=overview; continue ;;
      __FM_NM_SECTION_SELECTED_ID__) section=selected_id; continue ;;
      __FM_NM_SECTION_SELECTED__) section=selected; continue ;;
      __FM_NM_SECTION_RUNS_LIST__) section=runs_list; continue ;;
      __FM_NM_SECTION_CI_LOG__) section=ci_log; continue ;;
      __FM_NM_SECTION_END__) section=end; break ;;
    esac
    case "$section" in
      status) NM_SNAPSHOT_STATUS_OUT="${NM_SNAPSHOT_STATUS_OUT:+$NM_SNAPSHOT_STATUS_OUT$'\n'}$line" ;;
      overview) NM_SNAPSHOT_OVERVIEW_OUT="${NM_SNAPSHOT_OVERVIEW_OUT:+$NM_SNAPSHOT_OVERVIEW_OUT$'\n'}$line" ;;
      selected_id) NM_SNAPSHOT_SELECTED_ID="$line" ;;
      selected) NM_SNAPSHOT_SELECTED_OUT="${NM_SNAPSHOT_SELECTED_OUT:+$NM_SNAPSHOT_SELECTED_OUT$'\n'}$line" ;;
      runs_list) NM_SNAPSHOT_RUNS_LIST="${NM_SNAPSHOT_RUNS_LIST:+$NM_SNAPSHOT_RUNS_LIST$'\n'}$line" ;;
      ci_log) NM_SNAPSHOT_CI_LOG="${NM_SNAPSHOT_CI_LOG:+$NM_SNAPSHOT_CI_LOG$'\n'}$line" ;;
    esac
  done <<< "$out"
  [ "$section" = end ] || return 1
  return 0
}

