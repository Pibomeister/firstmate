#!/usr/bin/env bash
# tests/fm-pr-resync.test.sh - behavioral tests for bin/fm-pr-resync.sh, the
# published-head resync owner. Each case builds a real bare origin and reproduces
# the pipeline shape: the published branch is rebased onto a moved main, extended
# by a review fix and published with lease, while the task's local branch still
# holds the pre-rebase commit. A `no-mistakes` stand-in on PATH replays branch
# custody verdict shapes recorded from no-mistakes v1.84.0 (blocked_diverged then
# synchronized after the reset; pipeline_owned recover_custody; the terminal-run
# blocked_recover_manual_reconciliation, bind-only archive binding, bound-archive
# keep-local recovery and custody_returned/gate_ready sequence). Races are driven
# by stand-in side effects or a reference-transaction hook, never by timing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER=${FM_PR_RESYNC_UNDER_TEST:-$ROOT/bin/fm-pr-resync.sh}
TMP_ROOT=$(fm_test_tmproot fm-pr-resync-tests)
fm_git_identity
B=fm/t-resync
TASK=t1

STUB_BIN=$TMP_ROOT/stub-bin
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/no-mistakes" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$NM_STUB/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$NM_STUB/count"
printf '%s\n' "$*" >> "$NM_STUB/calls"
[ -f "$NM_STUB/resp.$n" ] || { echo "stub: no response $n for: $*" >&2; exit 97; }
. "$NM_STUB/resp.$n"
EOF
chmod +x "$STUB_BIN/no-mistakes"

REAL_GIT=$(command -v git)
export REAL_GIT
cat > "$STUB_BIN/git" <<'SH'
#!/usr/bin/env bash
op=$1
[ "$op" != -C ] || op=$3
if [ "${GIT_CAPTURE_FAIL:-0}" = 1 ] && [ "$op" = rev-parse ]; then
  case "$*" in *' --verify HEAD') exit 1 ;; esac
fi
if [ -n "${GIT_NETWORK_CALLS:-}" ]; then
  case "$op" in
    fetch|ls-remote)
      n=$(( $(cat "$GIT_NETWORK_CALLS" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$GIT_NETWORK_CALLS"
      if [ "$n" = "${GIT_NETWORK_HANG_AT:-0}" ]; then
        printf '%s:%s\n' "$op" "$n" > "$GIT_NETWORK_CALLS.hung"
        sleep 30 &
        child=$!
        printf '%s\n' "$child" > "$GIT_NETWORK_CALLS.child"
        trap 'wait "$child" 2>/dev/null; exit 124' TERM
        wait "$child"
        exit $?
      fi
      if [ "$n" = "${GIT_NETWORK_COMMIT_AT:-0}" ]; then
        "$REAL_GIT" -C "$GIT_NETWORK_WT" -c user.name=Tests -c user.email=tests@example.invalid commit --allow-empty -qm concurrent
        "$REAL_GIT" -C "$GIT_NETWORK_WT" rev-parse HEAD > "$GIT_NETWORK_WT/../concurrent-head"
      fi
      ;;
  esac
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$STUB_BIN/git"

cm() {  # <repo> <file>: commit one new file
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$2"
}

fixture() {  # <name>: origin publishes $B at A; repo's worktree WT holds $B at A
  D=$TMP_ROOT/$1
  fm_git_init_commit "$D/seed"
  git clone -q --bare "$D/seed" "$D/origin.git"
  git clone -q "$D/origin.git" "$D/pipe"
  git -C "$D/pipe" switch -q -c "$B"
  cm "$D/pipe" a
  git -C "$D/pipe" push -q origin "$B"
  git clone -q "$D/origin.git" "$D/repo"
  git -C "$D/repo" worktree add -q "$D/wt" "$B"
  mkdir -p "$D/nm" "$D/hooks"
  WT=$D/wt
  A=$(ref "refs/heads/$B")
  PUB=$A
}

rebase_publish() {  # the pipeline rebases $B onto a moved main, adds a review fix, publishes with lease
  local old
  old=$(git -C "$D/pipe" rev-parse "$B")
  git -C "$D/pipe" switch -q main
  cm "$D/pipe" m2
  git -C "$D/pipe" push -q origin main
  git -C "$D/pipe" switch -q "$B"
  git -C "$D/pipe" rebase -q main
  cm "$D/pipe" fix
  git -C "$D/pipe" push -q --force-with-lease="$B:$old" origin "$B"
  PUB=$(git -C "$D/origin.git" rev-parse "$B")
}

race_commit() {  # prepare (unpublished) one more pipeline commit on $B
  cm "$D/pipe" race
}

race_hook() {  # <ref>: when <ref> is updated in the task repo, publish the race commit once
  cat > "$D/hooks/reference-transaction" <<EOF
#!/usr/bin/env bash
[ "\$1" = committed ] || exit 0
grep -q " $1\$" || exit 0
[ -e "$D/hooks/fired" ] && exit 0
: > "$D/hooks/fired"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
git -C "$D/pipe" push -q origin "$B"
EOF
  chmod +x "$D/hooks/reference-transaction"
}

gate() {  # give the task repo a no-mistakes gate remote
  git clone -q --bare "$D/origin.git" "$D/gate.git"
  git -C "$D/gate.git" config uploadpack.allowAnySHA1InWant true
  git -C "$D/repo" remote add no-mistakes "$D/gate.git"
}

resp() {  # <n> <rc> <text> [side-effect shell]: the stand-in's nth answer
  { [ -z "${4:-}" ] || printf '%s\n' "$4"
    printf "cat <<'TOON'\n%s\nTOON\nexit %s\n" "$3" "$2"
  } > "$D/nm/resp.$1"
}

bs() {  # <state> <safety> <code> <command> [run] [current_head] [extra]: v1.84.0 branch_sync shape
  printf 'branch_sync:\n  state: %s\n  changed: false\n  pipeline:\n    run: "%s"\n    status: cancelled\n    current_head: "%s"\n  relation: diverged\n  safety: %s\n%s  next_action:\n    code: %s\n    command: %s\n' \
    "$1" "${5:-}" "${6:-}" "$2" "${7:+$7$'\n'}" "$3" "$4"
}

recov() {  # <required> <preserved> <archive_ref> <proof>
  printf '  recovery:\n    source: bound_archive\n    required_head: %s\n    preserved_head: "%s"\n    archive_ref: %s\n    keep_local: true\n    proof: %s\n' "$@"
}

DIVERGED=$(bs diverged blocked_diverged inspect_and_reconcile_manually 'git log --oneline --left-right HEAD...x' 01RUN)
SYNCED=$(bs synchronized synchronized run_pipeline 'no-mistakes axi run' 01RUN)
ACTIVE=$(bs pipeline_owned pipeline_owned_active continue_active_run 'no-mistakes axi run' 01RUN)
RETURNED=$(bs custody_returned gate_ready run_pipeline 'no-mistakes axi run' 01RUN)

ref() { git -C "$WT" rev-parse -q --verify "$1" 2>/dev/null; }
archives() { git -C "$WT" for-each-ref --format='%(refname)' refs/heads/archive; }
calls() { cat "$D/nm/calls" 2>/dev/null; }
run_owner() {  # [branch] [--check]
  local branch=${1:-$B}
  [ "$#" -eq 0 ] || shift
  # The owner's git sees only this case's hooks, whatever hooks path the caller pins.
  OUT=$(PATH="$STUB_BIN:$PATH" NM_STUB="$D/nm" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_VALUE_0="$D/hooks" bash "$OWNER" "$TASK" "$WT" "$branch" "$@" 2>&1)
  RC=$?
  LAST=$(printf '%s\n' "$OUT" | tail -1)
}
no_transport_child() {
  local pid state
  pid=$(cat "$1.child")
  state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')
  # A zombie has exited; the transport cannot keep running after refusal.
  case "$state" in ''|Z*) ;; *) fail "network timeout left transport child $pid running ($state)" ;; esac
}
pre() { printf 'refs/heads/archive/%s-pre-rebase-%.8s' "$TASK" "$1"; }

# --- git step without a gate ---------------------------------------------------

fixture diverged; rebase_publish; run_owner
expect_code 0 "$RC" "diverged: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "diverged: branch advanced to the published head"
assert_equals "$A" "$(ref "$(pre "$A")")" "diverged: stale pre-rebase head archived"
assert_equals "fm-pr-resync: result=archived-advanced archive=$(pre "$A") custody=none head=$PUB" "$LAST" "diverged: result line"
assert_equals "" "$(calls)" "diverged without a gate: no no-mistakes call"
pass "diverged stale local branch is archived and advanced to the pipeline-rebased published head"

fixture behind; cm "$D/pipe" fix; git -C "$D/pipe" push -q origin "$B"; PUB=$(git -C "$D/origin.git" rev-parse "$B"); run_owner
expect_code 0 "$RC" "behind: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "behind: advanced"
assert_equals "" "$(archives)" "behind: no archive"
assert_contains "$LAST" "result=advanced archive=- custody=none" "behind: result line"
pass "behind branch advances without an archive"

fixture equal; printf 'x\n' > "$WT/untracked"; run_owner
expect_code 0 "$RC" "equal: exit"
assert_equals "fm-pr-resync: result=equal archive=- custody=none head=$A" "$LAST" "equal: result line"
pass "equal branch changes nothing, even with an untracked file"

fixture ahead; cm "$WT" local1; L=$(ref "refs/heads/$B"); run_owner
expect_code 0 "$RC" "ahead: exit"
assert_equals "$L" "$(ref "refs/heads/$B")" "ahead: unpublished local commit kept"
assert_contains "$LAST" "result=ahead:1 archive=- custody=none head=$L" "ahead: reports the unpublished count"
pass "ahead branch changes nothing and reports ahead:1"

# --- refusals --------------------------------------------------------------------

fixture dirty; rebase_publish; printf 'x\n' > "$WT/untracked"; run_owner
expect_code 1 "$RC" "dirty: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "dirty: branch unchanged"
assert_equals "" "$(archives)" "dirty: no archive"
assert_contains "$OUT" "local changes" "dirty: reason"
pass "a dirty tree refuses when the branch must move"

fixture bisect; rebase_publish; git -C "$WT" bisect start -q 2>/dev/null || git -C "$WT" bisect start >/dev/null; run_owner
expect_code 1 "$RC" "in-progress: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "in-progress: branch unchanged"
assert_contains "$OUT" "in-progress operation" "in-progress: reason"
pass "an in-progress operation refuses"

fixture otherwt; rebase_publish; git -C "$WT" switch -q --detach; git -C "$D/repo" worktree add -q "$D/other" "$B"; run_owner
expect_code 1 "$RC" "other worktree: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "other worktree: branch unchanged"
assert_contains "$OUT" "checked out in another worktree" "other worktree: reason"
pass "a branch checked out in another worktree refuses"

fixture named; git -C "$WT" switch -q -c side; run_owner
expect_code 1 "$RC" "other named branch: exit"
assert_contains "$OUT" "on branch side" "other named branch: reason"
pass "a worktree on a different named branch refuses"

fixture absent; git -C "$WT" switch -q --detach; run_owner fm/absent
expect_code 1 "$RC" "origin lacks branch: exit"
assert_equals "" "$(ref refs/heads/fm/absent)" "origin lacks branch: nothing created"
assert_contains "$OUT" "origin has no branch fm/absent" "origin lacks branch: reason"
pass "a branch missing on origin refuses"

fixture mismatch; rebase_publish; race_commit; race_hook "refs/remotes/origin/$B"; run_owner
expect_code 1 "$RC" "fetched/advertised mismatch: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "mismatch: branch unchanged"
assert_equals "" "$(archives)" "mismatch: no archive"
assert_contains "$OUT" "advertises" "mismatch: reason"
pass "a fetched head that differs from the advertised head refuses"

fixture collide; rebase_publish; git -C "$WT" update-ref "$(pre "$A")" "$(ref refs/heads/main)"; run_owner
expect_code 1 "$RC" "archive collision: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "collision: branch unchanged"
assert_equals "$(ref refs/heads/main)" "$(ref "$(pre "$A")")" "collision: existing archive untouched"
assert_contains "$OUT" "already exists" "collision: reason"
pass "an archive name held by another commit refuses before any move"

fixture reuse; rebase_publish; git -C "$WT" update-ref "$(pre "$A")" "$A"; run_owner
expect_code 0 "$RC" "archive reuse: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "archive reuse: advanced"
pass "an archive already at the stale head is reused"

fixture after; rebase_publish; race_commit; race_hook "refs/heads/$B"; run_owner
expect_code 1 "$RC" "remote move after advance: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "after: branch at the previously verified published head"
assert_equals "$A" "$(ref "$(pre "$A")")" "after: stale head archived"
assert_contains "$OUT" "after the advance" "after: reason"
assert_contains "$LAST" "archive=$(pre "$A") custody=refused head=$PUB" "after: archive and head reported"
pass "a remote move after the advance refuses with the archive and verified head reported"

# The final advertisement deterministically commits on the branch after classification.
fixture concurrent; cm "$D/pipe" fix; git -C "$D/pipe" push -q origin "$B"
GIT_NETWORK_CALLS="$D/net.count" GIT_NETWORK_COMMIT_AT=3 GIT_NETWORK_WT="$WT" run_owner
expect_code 1 "$RC" "concurrent local writer: exit"
C=$(cat "$D/concurrent-head")
assert_equals "$C" "$(ref "refs/heads/$B")" "concurrent local writer: commit stays on branch"
assert_contains "$OUT" "conditional advance" "concurrent local writer: reason"
pass "a concurrent local commit refuses the old-OID-conditional advance"

fixture concurrent-after; cm "$D/pipe" fix; git -C "$D/pipe" push -q origin "$B"
cat > "$D/hooks/reference-transaction" <<EOF
#!/usr/bin/env bash
[ "\$1" = committed ] || exit 0
grep -q ' refs/heads/$B\$' || exit 0
[ ! -e "$D/hooks/fired" ] || exit 0
: > "$D/hooks/fired"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
git -C "$WT" -c user.name=Tests -c user.email=tests@example.invalid commit --allow-empty -qm concurrent-after
git -C "$WT" rev-parse HEAD > "$D/concurrent-head"
EOF
chmod +x "$D/hooks/reference-transaction"
run_owner
expect_code 1 "$RC" "concurrent post-advance writer: exit"
assert_equals "$(cat "$D/concurrent-head")" "$(ref "refs/heads/$B")" "concurrent post-advance writer: commit stays on branch"
assert_contains "$OUT" "changed after the conditional advance" "concurrent post-advance writer: reason"
pass "a concurrent local commit after the conditional advance is preserved and reported"

fixture index-locked; rebase_publish
LOCK=$(git -C "$WT" rev-parse --git-path index.lock)
: > "$LOCK"
run_owner
expect_code 1 "$RC" "index update refused: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "index update refused: conditional advance kept"
assert_equals "$A" "$(ref "$(pre "$A")")" "index update refused: archive kept"
assert_contains "$OUT" "keep-style index/worktree update" "index update refused: reason"
assert_contains "$OUT" "advanced $B from $A to $PUB" "index update refused: earlier advance reported"
pass "an index update failure refuses and reports the preserved archive and conditional advance"

fixture detached-capture; git -C "$WT" switch -q --detach; cm "$WT" detached-fix
S=$(ref HEAD)
GIT_CAPTURE_FAIL=1 run_owner
expect_code 1 "$RC" "detached HEAD capture failure: exit"
assert_equals "$S" "$(ref HEAD)" "detached HEAD capture failure: HEAD unchanged"
assert_contains "$OUT" "could not capture detached HEAD" "detached HEAD capture failure: reason"
pass "a detached HEAD capture failure refuses without switching or losing its commit"

fixture detached-uncontained; git -C "$WT" switch -q --detach; cm "$WT" detached-fix
S=$(ref HEAD)
run_owner
expect_code 1 "$RC" "detached unpublished commit: exit"
assert_equals "$S" "$(ref HEAD)" "detached unpublished commit: HEAD unchanged"
assert_equals "" "$(git -C "$WT" symbolic-ref -q HEAD)" "detached unpublished commit: stays detached"
assert_equals "$A" "$(ref "refs/heads/$B")" "detached unpublished commit: branch unchanged"
assert_contains "$OUT" "detached HEAD" "detached unpublished commit: reason"
run_owner "$B" --check
expect_code 1 "$RC" "detached unpublished commit: check refuses too"
pass "a detached unpublished commit refuses without switching HEAD"

# Every network site is reached with preceding calls real and a bounded hang at that site.
for mode in normal check; do
  case "$mode" in normal) sites='1 2 3 4' ;; check) sites='1 2 3' ;; esac
  for site in $sites; do
    fixture "timeout-$mode-$site"; rebase_publish
    if [ "$mode" = check ]; then
      FM_PR_RESYNC_TIMEOUT=1 GIT_NETWORK_CALLS="$D/net.count" GIT_NETWORK_HANG_AT=$site run_owner "$B" --check
    else
      FM_PR_RESYNC_TIMEOUT=1 GIT_NETWORK_CALLS="$D/net.count" GIT_NETWORK_HANG_AT=$site run_owner
    fi
    assert_contains "$(cat "$D/net.count.hung")" ":$site" "network timeout $mode/$site: selected operation reached"
    expect_code 1 "$RC" "network timeout $mode/$site: exit"
    assert_contains "$OUT" "timeout" "network timeout $mode/$site: reason"
    no_transport_child "$D/net.count"
    if [ "$mode/$site" = normal/4 ]; then
      assert_equals "$PUB" "$(ref "refs/heads/$B")" "post-advance timeout: advanced branch kept"
      assert_equals "$A" "$(ref "$(pre "$A")")" "post-advance timeout: archive kept"
      assert_contains "$OUT" "changed: created archive" "post-advance timeout: changes reported"
      assert_contains "$LAST" "result=archived-advanced" "post-advance timeout: result"
    else
      assert_equals "$A" "$(ref "refs/heads/$B")" "network timeout $mode/$site: branch unchanged"
      assert_equals "" "$(archives)" "network timeout $mode/$site: no archive"
    fi
    pass "Git network timeout refuses safely at $mode operation $site"
  done
done

# --- custody through the no-mistakes gate ------------------------------------------

fixture before; gate; rebase_publish; race_commit
resp 1 1 "$DIVERGED"; resp 2 1 "$DIVERGED" "git -C '$D/pipe' push -q origin '$B'"; run_owner
expect_code 1 "$RC" "remote move before advance: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "before: branch unchanged"
assert_equals "" "$(archives)" "before: no archive"
assert_contains "$OUT" "before the advance" "before: reason"
pass "a remote move before the advance refuses with nothing moved"

fixture active; gate; rebase_publish; resp 1 0 "$ACTIVE"; run_owner
expect_code 3 "$RC" "preflight active: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "preflight active: branch unchanged"
assert_equals "" "$(archives)" "preflight active: no archive"
assert_contains "$OUT" "monitoring-only" "preflight active: monitoring-only contract"
assert_contains "$LAST" "custody=pipeline-active" "preflight active: result line"
pass "custody active at preflight exits 3 with nothing changed"

fixture pr47; gate; rebase_publish; resp 1 1 "$DIVERGED"; resp 2 1 "$DIVERGED"; resp 3 0 "$SYNCED"; run_owner
expect_code 0 "$RC" "blocked_diverged: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "blocked_diverged: advanced"
assert_contains "$LAST" "result=archived-advanced archive=$(pre "$A") custody=settled" "blocked_diverged: settled"
pass "blocked_diverged custody settles after archive and advance"

for code in recover_custody adopt_published; do
  case $code in
    recover_custody) cmd='no-mistakes axi sync --recover'; args='axi sync --recover' ;;
    *) cmd='no-mistakes axi sync --adopt-published'; args='axi sync --adopt-published' ;;
  esac
  V=$(bs pipeline_owned blocked_pipeline_owned_recoverable "$code" "$cmd" 01RUN)
  fixture "$code"; gate; resp 1 1 "$V"; resp 2 1 "$V"; resp 3 0 recovered; resp 4 0 "$RETURNED"; run_owner
  expect_code 0 "$RC" "$code: exit"
  assert_equals "$args" "$(calls | sed -n 3p)" "$code: fixed command run"
  assert_contains "$LAST" "custody=settled" "$code: settled after re-check"
  pass "$code runs its fixed command and re-checks to settled"
done

V=$(bs pipeline_owned blocked_pipeline_owned_recoverable recover_custody 'no-mistakes axi sync --recover' 01RUN)
fixture still; gate; resp 1 1 "$V"; resp 2 1 "$V"; resp 3 0 recovered; resp 4 1 "$V"; run_owner
expect_code 1 "$RC" "recovery that does not settle: exit"
assert_contains "$LAST" "custody=refused" "recovery that does not settle: result line"
pass "a recovery whose fresh re-check is not settled refuses"

p44() {  # <proof> <archive_ref-or-empty>: the retained PR44 terminal-run sequence
  fixture "pr44-$1${2:+-foreign}${3:+-$3}"; gate
  git -C "$D/pipe" switch -q main; cm "$D/pipe" m2
  git -C "$D/pipe" switch -q -c nmrun; cm "$D/pipe" a-rebased
  P=$(git -C "$D/pipe" rev-parse nmrun)
  git -C "$D/pipe" push -q "$D/gate.git" "+nmrun:refs/heads/$B"
  PIPE_ARCHIVE=refs/heads/archive/$TASK-pipeline-${P:0:8}
  if [ -n "${2:-}" ]; then  # a real archive at the preserved head, but not one of this task's
    git -C "$D/repo" fetch -q "$D/gate.git" "refs/heads/$B"
    git -C "$WT" update-ref "$2" "$P"
  fi
  MANUAL=$(bs pipeline_owned blocked_recover_manual_reconciliation inspect_and_reconcile_manually 'no-mistakes axi status' 01RUN "$P")
  resp 1 1 "$MANUAL"; resp 2 1 "$MANUAL"; resp 3 0 'Archive evidence bound; follow the exact guarded recovery action shown above.'
  local required=$A preserved=$P
  case "${3:-}" in preserved) preserved=$A ;; required) required=$P ;; esac
  resp 4 1 "$(bs pipeline_owned blocked_pipeline_owned_recoverable recover_custody 'no-mistakes axi sync --recover --keep-local' 01RUN "$P" "$(recov "$required" "$preserved" "${2:-$PIPE_ARCHIVE}" "$1")")"
  resp 5 0 recovered; resp 6 0 "$RETURNED"
  run_owner
}

FM_PR_RESYNC_TIMEOUT=1 GIT_NETWORK_CALLS="$TMP_ROOT/gate-timeout.count" GIT_NETWORK_HANG_AT=3 p44 verified "" gate-timeout
expect_code 1 "$RC" "gate fetch timeout: exit"
assert_contains "$OUT" "timeout" "gate fetch timeout: reason"
no_transport_child "$TMP_ROOT/gate-timeout.count"
assert_equals "$A" "$(ref "refs/heads/$B")" "gate fetch timeout: branch unchanged"
assert_equals "" "$(archives)" "gate fetch timeout: no archive"
assert_equals "2" "$(calls | wc -l | tr -d ' ')" "gate fetch timeout: no bind/recovery"
pass "a preserved pipeline-head fetch timeout refuses before binding or recovering"

p44 verified
expect_code 0 "$RC" "PR44 shape: exit"
assert_equals "$P" "$(ref "$PIPE_ARCHIVE")" "PR44 shape: preserved pipeline head archived from the gate"
assert_equals "sync --bind-archive-ref $PIPE_ARCHIVE" "$(calls | sed -n 3p)" "PR44 shape: bind-only call"
assert_equals "axi sync --recover --keep-local" "$(calls | sed -n 5p)" "PR44 shape: keep-local recovery under proof"
assert_equals "fm-pr-resync: result=equal archive=$PIPE_ARCHIVE custody=settled head=$A" "$LAST" "PR44 shape: result line"
pass "terminal-run manual reconciliation archives, binds and recovers only under verified proof"

for bad in unverified foreign preserved required; do
  case "$bad" in
    foreign) p44 verified refs/heads/archive/other ;;
    unverified) p44 unverified ;;
    *) p44 verified "" "$bad" ;;
  esac
  expect_code 1 "$RC" "keep-local without proof ($bad): exit"
  assert_equals "4" "$(calls | wc -l | tr -d ' ')" "keep-local without proof ($bad): no recovery call"
  assert_equals "$P" "$(ref "$PIPE_ARCHIVE")" "keep-local without proof ($bad): archive kept and reported"
  assert_contains "$LAST" "archive=$PIPE_ARCHIVE custody=refused" "keep-local without proof ($bad): result line"
  pass "keep-local recovery without a verified own-archive proof refuses ($bad)"
done

fixture other; gate
V=$(bs pipeline_owned blocked_remote_rewritten inspect_and_reconcile_manually 'no-mistakes axi status' 01RUN)
resp 1 1 "$V"; resp 2 1 "$V"; run_owner
expect_code 1 "$RC" "unhandled verdict: exit"
assert_contains "$OUT" "safety: blocked_remote_rewritten" "unhandled verdict: native output verbatim"
assert_contains "$LAST" "custody=refused" "unhandled verdict: result line"
pass "an unhandled native verdict refuses with its output"

UNKNOWN=$(bs pipeline_owned blocked_some_new_verdict inspect_and_reconcile_manually 'no-mistakes axi status' 01RUN)
fixture unknownpre; gate; rebase_publish; resp 1 1 "$UNKNOWN"; run_owner
expect_code 1 "$RC" "unhandled preflight verdict: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "unhandled preflight verdict: branch unchanged"
assert_equals "" "$(archives)" "unhandled preflight verdict: no archive"
assert_contains "$OUT" "safety: blocked_some_new_verdict" "unhandled preflight verdict: native output verbatim"
pass "a native verdict outside the handled set refuses before any change"

fixture unknownmove; gate; rebase_publish; resp 1 1 "$DIVERGED"; resp 2 1 "$UNKNOWN"; run_owner
expect_code 1 "$RC" "unhandled pre-move verdict: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "unhandled pre-move verdict: branch unchanged"
assert_equals "" "$(archives)" "unhandled pre-move verdict: no archive"
pass "a native verdict outside the handled set just before the move refuses with nothing moved"

fixture unreadable; gate; resp 1 1 'error: daemon unavailable'; rebase_publish; run_owner
expect_code 1 "$RC" "unreadable custody: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "unreadable custody: branch unchanged"
assert_contains "$OUT" "daemon unavailable" "unreadable custody: native output"
pass "unreadable custody refuses before any change"

fixture check; gate; rebase_publish; TRACK=$(ref "refs/remotes/origin/$B"); resp 1 1 "$DIVERGED"; run_owner "$B" --check
expect_code 0 "$RC" "--check: exit"
assert_equals "$TRACK" "$(ref "refs/remotes/origin/$B")" "--check: remote-tracking ref unchanged"
assert_absent "$(git -C "$WT" rev-parse --path-format=absolute --git-path FETCH_HEAD)" "--check: no FETCH_HEAD written"
assert_equals "$A" "$(ref "refs/heads/$B")" "--check: branch unchanged"
assert_equals "" "$(archives)" "--check: no archive"
assert_equals "1" "$(calls | wc -l | tr -d ' ')" "--check: read-only preflight only"
assert_equals "fm-pr-resync: result=planned:archive-advance archive=- custody=none head=$A" "$LAST" "--check: planned action"
pass "--check reports the planned action and changes nothing"

race_upload_pack() {  # <n>: move origin's $B back to the stale local A right after the nth origin read
  cat > "$D/upload-pack" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$D/up.count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$D/up.count"
git upload-pack "\$@"
rc=\$?
if [ "\$n" = "$1" ]; then
  (unset GIT_DIR GIT_WORK_TREE GIT_PROTOCOL; git -C "$D/pipe" push -q --force origin "$A:refs/heads/$B")
fi
exit "\$rc"
EOF
  chmod +x "$D/upload-pack"
  git -C "$D/repo" config remote.origin.uploadpack "$D/upload-pack"
}

for n in 1 2; do
  fixture "checkrace$n"; rebase_publish; race_upload_pack "$n"; run_owner "$B" --check
  expect_code 1 "$RC" "--check origin move to a present commit after read $n: exit"
  assert_contains "$OUT" "moved" "--check origin move after read $n: reason"
  pass "--check refuses when origin moves to an already-present commit around its fetch (after read $n)"
done

fixture between; gate; rebase_publish; resp 1 1 "$DIVERGED"; resp 2 0 "$ACTIVE"; run_owner
expect_code 3 "$RC" "custody between preflight and move: exit"
assert_equals "$A" "$(ref "refs/heads/$B")" "between: branch unchanged"
assert_equals "" "$(archives)" "between: no archive"
pass "custody taken between preflight and move is caught before any ref moves"

fixture late; gate; rebase_publish; resp 1 1 "$DIVERGED"; resp 2 1 "$DIVERGED"; resp 3 0 "$ACTIVE"; run_owner
expect_code 3 "$RC" "custody after the pre-move check: exit"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "late: advance kept"
assert_equals "$A" "$(ref "$(pre "$A")")" "late: stale head archived"
assert_contains "$LAST" "result=archived-advanced archive=$(pre "$A") custody=pipeline-active" "late: archive and advance reported"
pass "custody taken after the pre-move check is reported with the archive and advance"

fixture detached; gate; git -C "$WT" switch -q --detach; git -C "$D/repo" branch -q -D "$B"; resp 1 0 "$ACTIVE"; run_owner
expect_code 3 "$RC" "detached without a local branch: exit"
assert_equals "$B" "$(git -C "$WT" symbolic-ref -q --short HEAD)" "detached: switched to the branch"
assert_equals "$PUB" "$(ref "refs/heads/$B")" "detached: created at the published head"
assert_contains "$OUT" "created local branch $B" "detached: creation reported"
pass "a detached worktree without a local branch reports the created branch on exit 3"

for bad_timeout in 0 00 invalid; do
  FM_PR_RESYNC_TIMEOUT=$bad_timeout run_owner
  expect_code 2 "$RC" "invalid network bound $bad_timeout: usage"
  assert_contains "$OUT" 'must be a positive integer' "invalid network bound: reason"
done
pass "an invalid timeout cannot disable the Git network bound"

run_owner_rel() { OUT=$(bash "$OWNER" "$TASK" relative/wt "$B" 2>&1); RC=$?; }
run_owner_rel
expect_code 2 "$RC" "usage: relative worktree"
pass "a relative worktree is a usage error"
