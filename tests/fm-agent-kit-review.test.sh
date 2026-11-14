#!/usr/bin/env bash
# Prove .cursor/bin/ak accepts the committed project record through its schema.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AK="$ROOT/.cursor/bin/ak"
PROJECT_RECORD="$ROOT/ak.project.json"
TMP_ROOT=$(fm_test_tmproot fm-agent-kit-review)

pinned_bun() {
  local bun
  bun=$(command -v bun 2>/dev/null || true)
  if [ -n "$bun" ] && [ -x "$bun" ] && [ "$("$bun" --version 2>/dev/null)" = "1.3.14" ]; then
    return 0
  fi
  bun="${HOME}/.bun/bin/bun"
  [ -x "$bun" ] && [ "$("$bun" --version 2>/dev/null)" = "1.3.14" ]
}

if ! pinned_bun; then
  echo "skip: bun 1.3.14 not found"
  exit 0
fi

write_fixture_ticket() {
  cat >"$1" <<'EOF'
{
  "schema": "ticket",
  "schema_version": 1,
  "id": "fm-ak-review-fixture",
  "project": { "id": "firstmate", "repo": "Pibomeister/firstmate" },
  "run_id": null,
  "created_by": { "role": "human" },
  "inputs": [],
  "source_revision": null,
  "created_at": "2026-11-10T22:00:00Z",
  "status": "draft",
  "type": "decision",
  "work_source": {
    "kind": "issue",
    "ref": { "id": "fixture", "hash": "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
  },
  "goal": "Score a fixture ticket against the committed project record.",
  "non_goals": [],
  "acceptance_criteria": [
    { "id": "AC-1", "text": "ak delegation exits 0 against ak.project.json." }
  ],
  "prerequisites": [],
  "stop_conditions": ["The scorer has returned."],
  "kb_refs": [],
  "decision": {
    "question": "Does the committed project record match the project schema?",
    "subtype": "task",
    "mode": "afk"
  },
  "delegation": {
    "class": "green",
    "stage": "ticket",
    "floor": { "packs": [], "sensitive_actions": [] },
    "factors": {
      "reversibility": { "score": 0, "evidence": ["fixture"] },
      "size": { "score": 0, "evidence": ["fixture"] },
      "complexity": { "score": 0, "evidence": ["fixture"] },
      "spec": { "score": 0, "evidence": ["fixture"] },
      "verification": { "score": 0, "evidence": ["fixture"] }
    },
    "lowered_by": null
  }
}
EOF
}

test_ak_delegation_accepts_committed_project_record() {
  local ticket out
  ticket="$TMP_ROOT/ticket.json"
  write_fixture_ticket "$ticket"
  out=$("$AK" delegation "$ticket" --project "$PROJECT_RECORD") \
    || fail "ak delegation refused the committed project record: $out"
  pass "ak delegation accepts the committed project record"
}

test_ak_delegation_refuses_invalid_review_value() {
  local ticket bad rc out
  ticket="$TMP_ROOT/ticket.json"
  bad="$TMP_ROOT/bad.project.json"
  write_fixture_ticket "$ticket"
  python3 - "$PROJECT_RECORD" "$bad" <<'PY'
import json, pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
record = json.loads(src.read_text())
record["review"]["cold_read"] = "bogus"
dst.write_text(json.dumps(record))
PY
  rc=0
  out=$("$AK" delegation "$ticket" --project "$bad" 2>&1) || rc=$?
  expect_code 1 "$rc" "an invalid review value must fail"
  assert_contains "$out" "does not match its schema" \
    "refusal did not name the project schema"
  pass "ak delegation refuses a project record with an invalid review value"
}

fm_test_run \
  test_ak_delegation_accepts_committed_project_record \
  test_ak_delegation_refuses_invalid_review_value
