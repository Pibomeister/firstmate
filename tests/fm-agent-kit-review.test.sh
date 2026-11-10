#!/usr/bin/env bash
# Prove the committed agent-kit project record has shadow review settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_RECORD="$ROOT/ak.project.json"
CATALOG="$ROOT/.cursor/catalog.yaml"

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

test_project_record_cold_read_is_shadow() {
  local value
  value=$(review_field cold_read) || fail "could not read review.cold_read from $PROJECT_RECORD"
  assert_equals "shadow" "$value" "ak.project.json review.cold_read must be shadow"
  pass "ak.project.json review.cold_read is shadow"
}

test_project_record_comprehension_is_shadow() {
  local value
  value=$(review_field comprehension) || fail "could not read review.comprehension from $PROJECT_RECORD"
  assert_equals "shadow" "$value" "ak.project.json review.comprehension must be shadow"
  pass "ak.project.json review.comprehension is shadow"
}

test_overlay_catalog_version_is_0_1_106() {
  local version
  version=$(catalog_package_version) || fail "could not read package.version from $CATALOG"
  assert_equals "0.1.106" "$version" "vendored catalog package.version must be 0.1.106"
  pass "overlay catalog package.version is 0.1.106"
}

fm_test_run \
  test_project_record_cold_read_is_shadow \
  test_project_record_comprehension_is_shadow \
  test_overlay_catalog_version_is_0_1_106
