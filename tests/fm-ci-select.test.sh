#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-select.sh: skip only when every path maps
# to no tests, otherwise full, including an empty list.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECT="$ROOT/bin/fm-ci-select.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$SELECT" "bin/fm-ci-select.sh is missing"
[ -x "$SELECT" ] || fail "bin/fm-ci-select.sh must be executable"
assert_present "$RUNNER" "bin/fm-test-run.sh is missing"

# Run the classifier on stdin paths. Sets MODE to the mode= value and RC.
classify() {
  local out
  RC=0
  out=$(printf '%s\n' "$@" | "$SELECT" --files-from - 2>/dev/null) || RC=$?
  MODE_LINE=$out
  MODE=${out#mode=}
  [ "$MODE_LINE" = "mode=$MODE" ] || fail "classifier stdout must be mode=<value>, got $MODE_LINE"
}

# Skip and the changed-path map must not drift: empty map is skip, any
# family, script, or unmapped line is full.
assert_classify_matches_map() {
  local path=$1 mapped
  mapped=$("$RUNNER" --map-changed-path "$path")
  classify "$path"
  [ "$RC" = 0 ] || fail "classify $path exit $RC"
  if [ -z "$mapped" ]; then
    [ "$MODE" = skip ] || fail "$path maps to no tests but classified $MODE_LINE"
  else
    [ "$MODE" = full ] || fail "$path maps to tests ($mapped) but classified $MODE_LINE"
  fi
}

test_docs_only_is_skip() {
  classify docs/architecture.md README.md
  [ "$RC" = 0 ] || fail "docs-only classify exit $RC"
  [ "$MODE_LINE" = mode=skip ] || fail "docs-only must be mode=skip, got $MODE_LINE"
  pass "docs-only paths that map to no tests skip the full suite"
}

test_bin_change_is_full() {
  classify bin/fm-spawn.sh
  [ "$RC" = 0 ] || fail "bin classify exit $RC"
  [ "$MODE_LINE" = mode=full ] || fail "a bin/ path must be mode=full, got $MODE_LINE"
  pass "a bin/ path requires the full suite"
}

test_github_change_is_full() {
  classify .github/workflows/ci.yml
  [ "$RC" = 0 ] || fail "github classify exit $RC"
  [ "$MODE_LINE" = mode=full ] || fail "a .github/ path must be mode=full, got $MODE_LINE"
  pass "a .github/ path requires the full suite"
}

test_mixed_docs_and_bin_is_full() {
  classify docs/architecture.md bin/fm-spawn.sh
  [ "$MODE_LINE" = mode=full ] || fail "docs plus bin/ must be mode=full, got $MODE_LINE"
  pass "a mixed docs and bin/ diff requires the full suite"
}

test_empty_list_is_full() {
  classify
  [ "$RC" = 0 ] || fail "empty classify exit $RC"
  [ "$MODE_LINE" = mode=full ] || fail "an empty list must be mode=full, got $MODE_LINE"
  pass "an empty path list refuses to skip"
}

test_test_infra_is_full() {
  classify tests/lib.sh
  [ "$MODE_LINE" = mode=full ] || fail "tests/lib.sh must be mode=full, got $MODE_LINE"
  classify tests/fm-ci-workflow.test.sh
  [ "$MODE_LINE" = mode=full ] || fail "a test file must be mode=full, got $MODE_LINE"
  pass "test infra and test files require the full suite"
}

test_agents_md_is_full() {
  classify AGENTS.md
  [ "$MODE_LINE" = mode=full ] || fail "AGENTS.md must be mode=full, got $MODE_LINE"
  pass "AGENTS.md requires the full suite"
}

test_cursor_overlay_docs_are_skip() {
  classify .cursor/skills/foo/SKILL.md .cursor/catalog.yaml
  [ "$MODE_LINE" = mode=skip ] || fail "empty-map overlay paths must be mode=skip, got $MODE_LINE"
  pass "vendored Cursor overlay paths with no tests skip the full suite"
}

test_cursor_agent_kit_is_full() {
  classify .cursor/agent-kit.md
  [ "$MODE_LINE" = mode=full ] || fail ".cursor/agent-kit.md must be mode=full, got $MODE_LINE"
  pass "the agent-kit pin path requires the full suite"
}

test_unmapped_docs_are_skip() {
  classify LICENSE .gitignore assets/logo.svg
  [ "$MODE_LINE" = mode=skip ] || fail "empty-map license and assets must be mode=skip, got $MODE_LINE"
  pass "license, assets, and gitignore skip the full suite"
}

test_mapped_docs_are_full() {
  local path
  for path in \
    docs/fm-test-portable-shards.md \
    docs/fm-test-isolation-proof.md \
    docs/fm-test-isolation-proof.json \
    docs/configuration.md \
    docs/supervision-protocols/cursor.md \
    CONTRIBUTING.md
  do
    classify "$path"
    [ "$RC" = 0 ] || fail "classify $path exit $RC"
    [ "$MODE" = full ] || fail "$path must be mode=full, got $MODE_LINE"
  done
  pass "docs the changed-path map selects require the full suite"
}

test_skip_matches_empty_changed_map() {
  local path
  for path in \
    README.md \
    LICENSE \
    docs/architecture.md \
    docs/configuration.md \
    docs/fm-test-portable-shards.md \
    docs/fm-test-isolation-proof.md \
    docs/fm-test-isolation-proof.json \
    docs/supervision-protocols/cursor.md \
    CONTRIBUTING.md \
    AGENTS.md \
    bin/fm-spawn.sh \
    .github/workflows/ci.yml \
    .cursor/catalog.yaml \
    .gitignore \
    assets/logo.svg
  do
    assert_classify_matches_map "$path"
  done
  pass "skip and the changed-path map agree on every checked path"
}

test_usage_error_prints_no_mode() {
  local out rc
  rc=0
  out=$("$SELECT" 2>/dev/null) || rc=$?
  [ "$rc" = 2 ] || fail "missing args must exit 2, got $rc"
  [ -z "$out" ] || fail "usage error must print no stdout mode, got $out"
  pass "a usage error exits 2 without a mode line"
}

test_base_ref_classifies_a_docs_commit() {
  local tmp repo out
  tmp=$(fm_test_tmproot fm-ci-select-base)
  repo=$tmp/repo
  fm_git_init_commit "$repo"
  mkdir -p "$repo/docs"
  printf 'note\n' >"$repo/docs/note.md"
  git -C "$repo" add docs/note.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm docs
  out=$(cd "$repo" && "$SELECT" --base HEAD^ 2>/dev/null) || fail "docs --base classify failed"
  [ "$out" = mode=skip ] || fail "docs commit vs HEAD^ must be mode=skip, got $out"
  printf 'echo\n' >"$repo/bin-placeholder.sh"
  git -C "$repo" add bin-placeholder.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm not-docs
  out=$(cd "$repo" && "$SELECT" --base HEAD^ 2>/dev/null) || fail "non-docs --base classify failed"
  [ "$out" = mode=full ] || fail "unmapped root file vs HEAD^ must be mode=full, got $out"
  pass "--base classifies a docs commit as skip and any other commit as full"
}

test_rename_from_bin_to_docs_is_full() {
  local tmp repo out
  tmp=$(fm_test_tmproot fm-ci-select-rename)
  repo=$tmp/repo
  fm_git_init_commit "$repo"
  mkdir -p "$repo/bin" "$repo/docs"
  printf 'echo\n' >"$repo/bin/fm-spawn.sh"
  git -C "$repo" add bin/fm-spawn.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm add-bin
  git -C "$repo" mv bin/fm-spawn.sh docs/fm-spawn.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm rename-to-docs
  out=$(cd "$repo" && "$SELECT" --base HEAD^ 2>/dev/null) || fail "rename --base classify failed"
  [ "$out" = mode=full ] || fail "bin/ renamed to docs/ must be mode=full, got $out"
  pass "a bin/ to docs/ rename requires the full suite"
}

fm_test_run \
  test_docs_only_is_skip \
  test_bin_change_is_full \
  test_github_change_is_full \
  test_mixed_docs_and_bin_is_full \
  test_empty_list_is_full \
  test_test_infra_is_full \
  test_agents_md_is_full \
  test_cursor_overlay_docs_are_skip \
  test_cursor_agent_kit_is_full \
  test_unmapped_docs_are_skip \
  test_mapped_docs_are_full \
  test_skip_matches_empty_changed_map \
  test_usage_error_prints_no_mode \
  test_base_ref_classifies_a_docs_commit \
  test_rename_from_bin_to_docs_is_full
