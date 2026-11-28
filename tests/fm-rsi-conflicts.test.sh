#!/usr/bin/env bash
# Behavioral tests for bin/fm-rsi-conflicts.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-rsi-conflicts.sh"
TMP_ROOT=$(fm_test_tmproot fm-rsi-conflicts)
REPO=$TMP_ROOT/repo
fm_git_identity

commit_all() {  # <message>
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"
}

# One base and four heads: a clean head, a head with two content conflicts, a
# head that conflicts on one shared path, and a modify/delete conflict.
build_fixture() {
  fm_git_init_commit "$REPO"
  printf 'one\ntwo\nthree\n' > "$REPO/a.txt"
  printf 'alpha\nbeta\n' > "$REPO/b.txt"
  printf 'keep\n' > "$REPO/c.txt"
  commit_all fork
  git -C "$REPO" branch fork

  git -C "$REPO" checkout -q -b clean fork
  printf 'new\n' > "$REPO/d.txt"
  commit_all clean
  git -C "$REPO" checkout -q -b two fork
  printf 'ONE-two\ntwo\nthree\n' > "$REPO/a.txt"
  printf 'ALPHA-two\nbeta\n' > "$REPO/b.txt"
  commit_all two
  git -C "$REPO" checkout -q -b three fork
  printf 'ONE-three\ntwo\nthree\n' > "$REPO/a.txt"
  commit_all three
  git -C "$REPO" checkout -q -b moddel fork
  printf 'changed\n' > "$REPO/c.txt"
  commit_all moddel

  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --ff-only fork
  printf 'ONE-main\ntwo\nthree\n' > "$REPO/a.txt"
  printf 'ALPHA-main\nbeta\n' > "$REPO/b.txt"
  git -C "$REPO" rm -q c.txt
  commit_all main
}

sha() { git -C "$REPO" rev-parse "$1"; }

# Every file under the repository, with its content digest, so any write to
# refs, the index, the worktree, or the object store shows as a difference.
repo_fingerprint() {  # <dir>
  (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(git hash-object --no-filters -- "$f")" "$f"
  done)
}

build_fixture
# A pristine copy taken before any report runs, so no earlier case has already
# stored the combine's objects where the fingerprint case looks.
PRISTINE=$TMP_ROOT/pristine
cp -R "$REPO" "$PRISTINE"

test_report_lines_tally_and_summary() {
  local out rc want
  out=$("$SCRIPT" --repo "$REPO" --base main \
    "1=$(sha clean)" "2=$(sha two)" "3=$(sha three)" "4=$(sha moddel)")
  rc=$?
  [ "$rc" -eq 0 ] || fail "report exits 0 (got $rc)"
  want='pr number=1 state=clean paths=0
pr number=2 state=conflict paths=2
path number=2 path=a.txt
path number=2 path=b.txt
pr number=3 state=conflict paths=1
path number=3 path=a.txt
pr number=4 state=conflict paths=1
path number=4 path=c.txt
tally path=a.txt blocked=2
tally path=b.txt blocked=1
tally path=c.txt blocked=1
summary conflicted=3 heads=4'
  assert_equals "$want" "$out" "report lines"
  pass "clean, content and modify/delete heads report paths, tally and summary"
}

test_all_clean_has_no_tally() {
  local out
  out=$("$SCRIPT" --repo "$REPO" --base main "7=$(sha clean)") || fail "all-clean run exits 0"
  assert_equals 'pr number=7 state=clean paths=0
summary conflicted=0 heads=1' "$out" "all-clean report"
  pass "an all-clean run prints no path or tally line"
}

test_repository_unchanged() {
  local before after copy=$PRISTINE
  before=$(repo_fingerprint "$copy")
  "$SCRIPT" --repo "$copy" --base main "1=$(sha clean)" "2=$(sha two)" "4=$(sha moddel)" >/dev/null ||
    fail "report run for the fingerprint exits 0"
  after=$(repo_fingerprint "$copy")
  [ -n "$before" ] || fail "fingerprint is not empty"
  assert_equals "$before" "$after" "repository fingerprint"
  pass "a report leaves refs, index, worktree and object store unchanged"
}

expect_refusal() {  # <label> <args...>
  local label=$1 out rc
  shift
  out=$("$SCRIPT" "$@" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "$label exits 2 (got $rc)"
  [ -z "$out" ] || fail "$label prints nothing on stdout (got: $out)"
}

test_refusals() {
  local plain=$TMP_ROOT/plain
  mkdir -p "$plain"
  expect_refusal "no arguments"
  expect_refusal "no heads" --repo "$REPO" --base main
  expect_refusal "unknown flag" --repo "$REPO" --base main --fetch "1=$(sha clean)"
  expect_refusal "non-git repo" --repo "$plain" --base main "1=$(sha clean)"
  expect_refusal "unresolvable base" --repo "$REPO" --base no-such-ref "1=$(sha clean)"
  expect_refusal "unresolvable head" --repo "$REPO" --base main "1=0123456789abcdef0123456789abcdef01234567"
  expect_refusal "duplicate number" --repo "$REPO" --base main "1=$(sha clean)" "1=$(sha two)"
  expect_refusal "malformed pair" --repo "$REPO" --base main "$(sha clean)"
  expect_refusal "zero number" --repo "$REPO" --base main "0=$(sha clean)"
  expect_refusal "a refusal after a conflicted head" --repo "$REPO" --base main "2=$(sha two)" "3=nope"
  pass "bad usage and unresolvable input exit 2 with empty stdout"
}

fm_test_run \
  test_report_lines_tally_and_summary \
  test_all_clean_has_no_tally \
  test_repository_unchanged \
  test_refusals
