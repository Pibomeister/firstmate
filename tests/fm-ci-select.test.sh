#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-select.sh: skip only for existing
# allowlisted paths that are unread or covered by a skip-mode check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECT="$ROOT/bin/fm-ci-select.sh"

assert_present "$SELECT" "bin/fm-ci-select.sh is missing"
[ -x "$SELECT" ] || fail "bin/fm-ci-select.sh must be executable"

# Run the classifier on stdin paths. Sets MODE to the mode= value and RC.
classify() {
  local out
  RC=0
  out=$(printf '%s\n' "$@" | "$SELECT" --files-from - 2>/dev/null) || RC=$?
  MODE_LINE=$out
  MODE=${out#mode=}
  [ "$MODE_LINE" = "mode=$MODE" ] || fail "classifier stdout must be mode=<value>, got $MODE_LINE"
}

test_allowlisted_path_is_skip() {
  classify VISION.md
  [ "$RC" = 0 ] || fail "VISION.md classify exit $RC"
  [ "$MODE_LINE" = mode=skip ] || fail "VISION.md must be mode=skip, got $MODE_LINE"
  pass "an allowlisted path skips the full suite"
}

test_readme_is_full() {
  classify README.md
  [ "$RC" = 0 ] || fail "README.md classify exit $RC"
  [ "$MODE_LINE" = mode=full ] || fail "README.md must be mode=full, got $MODE_LINE"
  pass "README.md requires the full suite"
}

test_docs_herdr_backend_is_full() {
  classify docs/herdr-backend.md
  [ "$MODE_LINE" = mode=full ] || fail "docs/herdr-backend.md must be mode=full, got $MODE_LINE"
  pass "a doc tests read requires the full suite"
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

test_mixed_allowlist_and_bin_is_full() {
  classify VISION.md bin/fm-spawn.sh
  [ "$MODE_LINE" = mode=full ] || fail "allowlist plus bin/ must be mode=full, got $MODE_LINE"
  pass "a mixed allowlist and bin/ diff requires the full suite"
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

test_cursor_overlay_is_full() {
  classify .cursor/skills/foo/SKILL.md .cursor/catalog.yaml .cursor/rules/ak-super-review.mdc
  [ "$MODE_LINE" = mode=full ] || fail "a .cursor/ path must be mode=full, got $MODE_LINE"
  classify .cursor/agent-kit.md
  [ "$MODE_LINE" = mode=full ] || fail ".cursor/agent-kit.md must be mode=full, got $MODE_LINE"
  pass "every .cursor/ path requires the full suite"
}

test_license_gitignore_and_mapped_docs_are_full() {
  local path
  for path in \
    LICENSE \
    .gitignore \
    docs/architecture.md \
    docs/configuration.md \
    docs/fm-test-portable-shards.md \
    docs/fm-test-isolation-proof.md \
    docs/fm-test-isolation-proof.json \
    docs/supervision-protocols/cursor.md \
    CONTRIBUTING.md
  do
    classify "$path"
    [ "$RC" = 0 ] || fail "classify $path exit $RC"
    [ "$MODE" = full ] || fail "$path must be mode=full, got $MODE_LINE"
  done
  pass "license, gitignore, and docs tests or scripts name require the full suite"
}

# True when tests/ or bin/ name $1, other than the classifier and this suite.
path_has_literal_read() {
  local path=$1 hits
  hits=$(grep -RIF --exclude='fm-ci-select.test.sh' --exclude='fm-ci-select.sh' \
    --exclude='fm-ci-workflow.test.sh' -- "$path" "$ROOT/tests" "$ROOT/bin" || true)
  [ -n "$hits" ]
}

# True when the audience inventory's trackedPatterns select $1.
path_has_tracked_pattern() {
  local path=$1
  git -C "$ROOT" ls-files -- '*.md' '*.mdx' '*.rst' '*.txt' 'docs/examples/*' \
    | grep -Fxq -- "$path"
}

# True when docs/documentation-audiences.json names $1 as a string value.
path_in_audience_inventory() {
  local path=$1
  python3 - "$ROOT/docs/documentation-audiences.json" "$path" <<'PY'
import json, sys
from pathlib import Path

def walk(value, want):
    if value == want:
        return True
    if isinstance(value, dict):
        return any(walk(v, want) for v in value.values())
    if isinstance(value, list):
        return any(walk(v, want) for v in value)
    return False

inventory, want = sys.argv[1], sys.argv[2]
sys.exit(0 if walk(json.loads(Path(inventory).read_text(encoding="utf-8")), want) else 1)
PY
}

skip_check_covers_path() {
  local path=$1
  grep -Fxq -- 'bin/fm-doc-audience-check.sh' < <("$SELECT" --list-skip-checks) \
    || return 1
  path_has_tracked_pattern "$path"
}

test_allowlist_paths_are_unread_or_skip_covered() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$ROOT/$path" ] || fail "skip allowlist path does not exist: $path"
    classify "$path"
    [ "$MODE" = skip ] || fail "allowlisted $path must be mode=skip, got $MODE_LINE"
    if path_has_literal_read "$path" || path_has_tracked_pattern "$path" \
      || path_in_audience_inventory "$path"; then
      skip_check_covers_path "$path" \
        || fail "allowlisted $path is test- or config-read but skip mode does not cover it"
    fi
  done < <("$SELECT" --list-skip)
  pass "every skip allowlist path is unread or covered by a skip-mode check"
}

test_skip_mode_audience_check_fails_a_broken_vision_link() {
  local tmp repo err
  classify VISION.md
  [ "$MODE" = skip ] || fail "VISION.md must stay mode=skip, got $MODE_LINE"
  tmp=$(fm_test_tmproot fm-ci-select-broken-vision)
  repo=$tmp/repo
  git clone -q --local "$ROOT" "$repo"
  printf '\n[broken](docs/no-such-skip-target.md)\n' >>"$repo/VISION.md"
  err=$tmp/err
  if "$ROOT/bin/fm-doc-audience-check.sh" --root "$repo" >/dev/null 2>"$err"; then
    fail "a broken VISION.md link must fail the skip-mode audience check"
  fi
  grep -q 'unresolved local link' "$err" \
    || fail "the skip-mode audience check must name the broken link, got $(cat "$err")"
  pass "a broken VISION.md link fails the skip-mode audience check"
}

test_usage_error_prints_no_mode() {
  local out rc
  rc=0
  out=$("$SELECT" 2>/dev/null) || rc=$?
  [ "$rc" = 2 ] || fail "missing args must exit 2, got $rc"
  [ -z "$out" ] || fail "usage error must print no stdout mode, got $out"
  pass "a usage error exits 2 without a mode line"
}

test_base_ref_classifies_an_allowlisted_commit() {
  local tmp repo out
  tmp=$(fm_test_tmproot fm-ci-select-base)
  repo=$tmp/repo
  fm_git_init_commit "$repo"
  printf 'note\n' >"$repo/VISION.md"
  git -C "$repo" add VISION.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm vision
  out=$(cd "$repo" && "$SELECT" --base HEAD^ 2>/dev/null) || fail "allowlist --base classify failed"
  [ "$out" = mode=skip ] || fail "VISION.md commit vs HEAD^ must be mode=skip, got $out"
  printf 'echo\n' >"$repo/bin-placeholder.sh"
  git -C "$repo" add bin-placeholder.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm not-skip
  out=$(cd "$repo" && "$SELECT" --base HEAD^ 2>/dev/null) || fail "non-allowlist --base classify failed"
  [ "$out" = mode=full ] || fail "unlisted root file vs HEAD^ must be mode=full, got $out"
  pass "--base classifies an allowlisted commit as skip and any other commit as full"
}

test_deleted_bin_helper_is_full() {
  local tmp repo out
  tmp=$(fm_test_tmproot fm-ci-select-deleted-bin)
  repo=$tmp/repo
  fm_git_init_commit "$repo"
  mkdir -p "$repo/bin"
  printf 'echo\n' >"$repo/bin/fm-orphan-helper.sh"
  git -C "$repo" add bin/fm-orphan-helper.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm add-helper
  git -C "$repo" rm -q bin/fm-orphan-helper.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm delete-helper
  out=$(cd "$repo" && "$SELECT" --base HEAD^ 2>/dev/null) || fail "deleted-bin --base classify failed"
  [ "$out" = mode=full ] || fail "a deleted bin/ helper must be mode=full, got $out"
  pass "a deleted bin/ helper requires the full suite"
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
  test_allowlisted_path_is_skip \
  test_readme_is_full \
  test_docs_herdr_backend_is_full \
  test_bin_change_is_full \
  test_github_change_is_full \
  test_mixed_allowlist_and_bin_is_full \
  test_empty_list_is_full \
  test_test_infra_is_full \
  test_agents_md_is_full \
  test_cursor_overlay_is_full \
  test_license_gitignore_and_mapped_docs_are_full \
  test_allowlist_paths_are_unread_or_skip_covered \
  test_skip_mode_audience_check_fails_a_broken_vision_link \
  test_usage_error_prints_no_mode \
  test_base_ref_classifies_an_allowlisted_commit \
  test_deleted_bin_helper_is_full \
  test_rename_from_bin_to_docs_is_full
