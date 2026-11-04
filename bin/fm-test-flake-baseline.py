#!/usr/bin/env python3
"""Annotate failed suite output; never alter the runner's failure verdict.

Usage: fm-test-flake-baseline.py ROOT TEST LANE OUTPUT
The tracked tests/ci-flake-baseline.json is an array of entries with id, test,
lane, signature (a full-line regular expression), first_seen, unchanged_pass,
owner, expires (UTC date), and sources (relative path to SHA-256).
Only the portable-serial lane class matches across shard renumbering.
Every failure line must match the entry and every source must be unchanged.
Expired entries are diagnostic history, never a recorded classification.
Malformed data fails closed with a nonzero status.
"""

import datetime
import hashlib
import json
from pathlib import Path
import re
import sys


def classify(root: Path, test: str, lane: str, output: Path) -> str:
    baseline = root / "tests/ci-flake-baseline.json"
    if not baseline.exists():
        return "classification=new id=none"
    entries = json.loads(baseline.read_text(encoding="utf-8"))
    today = datetime.datetime.now(datetime.timezone.utc).date()
    lines = output.read_text(encoding="utf-8", errors="replace").splitlines()
    failures = [line for line in lines if re.match(r"^(not ok\b|FAIL\b)", line)]
    lane_class = "portable-serial" if re.fullmatch(r"portable-serial-\d+of\d+", lane) else lane
    for entry in entries:
        for field in ("id", "test", "lane", "signature", "first_seen", "unchanged_pass", "owner", "expires", "sources"):
            if not entry[field]:
                raise ValueError(f"baseline entry has empty {field}")
        expiry = datetime.date.fromisoformat(entry["expires"])
        signature = re.compile(entry["signature"])
        if entry["test"] != test or entry["lane"] != lane_class or today > expiry:
            continue
        sources = entry["sources"]
        if test not in sources:
            raise ValueError("baseline must bind its test source")
        unchanged = True
        for relative, digest in sources.items():
            source = (root / relative).resolve()
            if not source.is_relative_to(root.resolve()):
                raise ValueError("baseline source escapes repository")
            if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != digest:
                unchanged = False
                break
        if unchanged and failures and all(signature.fullmatch(line) for line in failures):
            return f"classification=recorded id={entry['id']} expires={entry['expires']}"
    return "classification=new id=none"


if __name__ == "__main__":
    try:
        root_arg, test_arg, lane_arg, output_arg = sys.argv[1:]
        result = classify(Path(root_arg), test_arg, lane_arg, Path(output_arg))
        print(f"FM_TEST_FAILURE script={test_arg} {result} verdict=failed")
    except (ValueError, KeyError, TypeError, OSError, re.error) as error:
        sys.exit(f"fm-test-flake-baseline: invalid baseline: {error}")
