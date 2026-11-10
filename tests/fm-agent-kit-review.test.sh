#!/usr/bin/env bash
# Prove the committed agent-kit project record loads shadow review settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_RECORD="$ROOT/ak.project.json"
CATALOG="$ROOT/.cursor/catalog.yaml"
PIN="$ROOT/bin/fm-agent-kit-pin.sh"

review_field() {
  python3 - "$PROJECT_RECORD" "$1" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(record["review"][sys.argv[2]])
PY
}

catalog_package_version() {
  python3 - "$CATALOG" <<'PY'
from pathlib import Path
import sys
in_package = False
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("package:"):
        in_package = True
        continue
    if in_package and line.startswith("  version:"):
        print(line.split(":", 1)[1].strip())
        break
PY
}

test_project_record_loads_cold_read_shadow() {
  local value
  value=$(review_field cold_read) || fail "could not read review.cold_read from $PROJECT_RECORD"
  assert_equals "shadow" "$value" "ak.project.json review.cold_read must be shadow"
  pass "loaded review.cold_read is shadow"
}

test_project_record_loads_comprehension_shadow() {
  local value
  value=$(review_field comprehension) || fail "could not read review.comprehension from $PROJECT_RECORD"
  assert_equals "shadow" "$value" "ak.project.json review.comprehension must be shadow"
  pass "loaded review.comprehension is shadow"
}

test_project_record_does_not_enable_cold_read_on() {
  local value
  value=$(review_field cold_read) || fail "could not read review.cold_read from $PROJECT_RECORD"
  assert_not_equals "on" "$value" "ak.project.json review.cold_read must not be on"
  pass "loaded review.cold_read is not on"
}

test_overlay_catalog_is_0_1_106() {
  local version
  version=$(catalog_package_version) || fail "could not read package.version from $CATALOG"
  assert_equals "0.1.106" "$version" "vendored catalog package.version must be 0.1.106"
  pass "loaded overlay catalog version is 0.1.106"
}

test_pin_matches_after_overlay_refresh() {
  local out
  out=$("$PIN") || fail "repository agent-kit bin pin does not match .cursor/agent-kit.md"
  assert_contains "$out" "fm-agent-kit-pin: ok" "pin check did not report ok"
  pass "pin still matches after the overlay refresh"
}

fm_test_run \
  test_project_record_loads_cold_read_shadow \
  test_project_record_loads_comprehension_shadow \
  test_project_record_does_not_enable_cold_read_on \
  test_overlay_catalog_is_0_1_106 \
  test_pin_matches_after_overlay_refresh
