#!/usr/bin/env python3
"""Drive bin/fm-goal-digest.sh in a disposable FM_HOME.

The script under test is the product. gh, date, and the model runner are
the external edges: synthetic pull payloads, a fixed clock, and a stub
runner that records the command the digest actually execs.
"""

import datetime
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path("{run-worktree}")
EVID = Path("~/.no-mistakes/evidence/01M8EV8ZHDQPVG3XH26FFERA80/goal-digest")
SCRIPT = ROOT / "bin/fm-goal-digest.sh"
RUN1 = 1767268800  # 2026-01-01T12:00:00Z
RUN2 = 1767272400  # 2026-01-01T13:00:00Z
RUN3 = 1767276000  # 2026-01-01T14:00:00Z
RUN17 = RUN1 + 18000  # 2026-01-01T17:00:00Z
RETRY = RUN1 + 172800  # 2026-01-03T12:00:00Z
REPO = "example-org/example-repo"

results = []
transcript = []


def log(line):
    transcript.append(line)
    print(line, flush=True)


def scenario(name, ok, evidence, detail):
    results.append(
        {
            "name": name,
            "result": "pass" if ok else "fail",
            "evidence": evidence,
            "detail": detail,
        }
    )
    log(("PASS  " if ok else "FAIL  ") + name)
    if detail:
        log("       " + detail.replace("\n", "\n       "))


def stamp_of(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def iso_of(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


def main():
    EVID.mkdir(parents=True, exist_ok=True)
    rev = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    log(f"revision {rev}")
    log(f"product {SCRIPT}")
    lab = Path(tempfile.mkdtemp(prefix="fm-gd-live."))
    fake = lab / "fakebin"
    fix = lab / "fixture"
    fake.mkdir()
    fix.mkdir()
    try:
        write_exec(
            fake / "gh",
            """#!/usr/bin/env bash
endpoint=${2:-}
repo=${endpoint#repos/}
repo=${repo%%/pulls*}
safe=$(printf '%s' "$repo" | tr '/ ' '__')
case "$endpoint" in
  *state=closed*) cat "$FM_GD_FIXTURE/merged-$safe.json" ;;
  *state=open*) cat "$FM_GD_FIXTURE/open-$safe.json" ;;
  *) exit 1 ;;
esac
""",
        )
        write_exec(
            fake / "date",
            """#!/usr/bin/env bash
if [ "$*" = "+%s" ] && [ -n "${FM_GD_NOW_EPOCH:-}" ]; then
  printf '%s\\n' "$FM_GD_NOW_EPOCH"
  exit 0
fi
if [ -n "${FM_GD_NOW_EPOCH:-}" ]; then
  python3 - "$@" <<'PYDATE'
import datetime, os, sys
from zoneinfo import ZoneInfo
zone = datetime.timezone.utc if "-u" in sys.argv else ZoneInfo(os.environ.get("TZ", "UTC"))
fmt = next(a[1:] for a in sys.argv[1:] if a.startswith("+"))
print(datetime.datetime.fromtimestamp(int(os.environ["FM_GD_NOW_EPOCH"]), zone).strftime(fmt))
PYDATE
  exit $?
fi
exec /bin/date "$@"
""",
        )
        stub = lab / "claude-stub"
        write_exec(
            stub,
            """#!/bin/bash
{
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\\n'
  printf 'ANTHROPIC_MODEL=%s\\n' "${ANTHROPIC_MODEL-unset}"
  printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL-unset}"
  printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL-unset}"
  printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL-unset}"
} >> "${FM_GD_RUNNER_LOG:?}"
if [ "${FM_GD_SUMMARY_MODE:-ok}" = "whitespace" ]; then
  printf ' \\t\\n \\n'
else
  printf 'owner summary line\\n'
fi
""",
        )
        valid_open = [
            {
                "number": 7,
                "title": "Waiting work",
                "html_url": "https://example.invalid/pr/7",
                "created_at": "2026-01-01T00:00:00Z",
                "user": {"login": "contributor"},
                "draft": False,
            }
        ]
        valid_merge = {
            "number": 1,
            "title": "First",
            "html_url": "https://example.invalid/pr/1",
            "merge_commit_sha": "aaaaaaaaaaaa1111",
            "merged_at": "2026-01-01T00:00:00Z",
            "created_at": "2025-12-31T00:00:00Z",
        }
        old_merge = {
            "number": 9,
            "title": "Old merge",
            "html_url": "https://example.invalid/pr/9",
            "merge_commit_sha": "999999999999dddd",
            "merged_at": "2025-06-01T00:00:00Z",
            "created_at": "2025-05-01T00:00:00Z",
        }

        def put_pulls(merged, opened):
            (fix / "merged-example-org_example-repo.json").write_text(json.dumps(merged))
            (fix / "open-example-org_example-repo.json").write_text(json.dumps(opened))

        def make_home(name, snapshot=None, status_text="progress: started\n"):
            home = lab / "homes" / name
            (home / "config").mkdir(parents=True)
            (home / "data").mkdir()
            if snapshot is None:
                (home / "status.txt").write_text(status_text)
                status_line = f"status = Example status | {home / 'status.txt'}\n"
            else:
                (home / "status.json").write_text(json.dumps(snapshot))
                status_line = f"status = Fleet | {home / 'status.json'}\n"
            (home / "review.status").write_text("working [at=1]: T1 in progress\n")
            (home / "config" / "goal-digest").write_text(
                f"repo = {REPO}\n{status_line}review = Example review | {home / 'review.status'}\n"
            )
            return home

        origin_path = os.environ.get("PATH", "/usr/bin:/bin")

        def run(home, epoch, extra=None):
            env = os.environ.copy()
            for key in (
                "NO_MISTAKES_GATE",
                "FM_GATE_REFUSE_BYPASS",
                "FM_ROOT_OVERRIDE",
                "FM_STATE_OVERRIDE",
                "FM_DATA_OVERRIDE",
                "FM_CONFIG_OVERRIDE",
                "FM_PROJECTS_OVERRIDE",
            ):
                env.pop(key, None)
            env.update(
                {
                    "PATH": f"{fake}:{origin_path}",
                    "FM_TEST_SEAM": "1",
                    "FM_HOME": str(home),
                    "FM_GD_FIXTURE": str(fix),
                    "FM_GD_NOW_EPOCH": str(epoch),
                    "FM_GOAL_DIGEST_CLAUDE": str(stub),
                    "FM_GD_RUNNER_LOG": str(home / "runner.log"),
                    "FM_GD_SUMMARY_MODE": "ok",
                    "TZ": "UTC",
                }
            )
            if extra:
                env.update(extra)
            proc = subprocess.run(
                [str(SCRIPT), "run"],
                env=env,
                text=True,
                capture_output=True,
                cwd=str(ROOT),
            )
            log(f"--- run {home.name} epoch {epoch} rc {proc.returncode}")
            log("STDOUT " + proc.stdout.strip())
            if proc.stderr.strip():
                log("STDERR " + proc.stderr.strip())
            return proc

        def published(home):
            base = home / "data" / "goal-digest"
            doc = json.loads((base / "latest.json").read_text())
            md = (base / "latest.md").read_text()
            return doc, md

        def save(name, home):
            base = home / "data" / "goal-digest"
            dest_json = EVID / f"{name}.json"
            dest_md = EVID / f"{name}.md"
            if (base / "latest.json").exists():
                shutil.copy(base / "latest.json", dest_json)
            if (base / "latest.md").exists():
                shutil.copy(base / "latest.md", dest_md)
            return dest_md

        # --- duplicate merges and prose ETAs ---
        put_pulls(
            [
                valid_merge,
                dict(valid_merge, title="First duplicate"),
                old_merge,
            ],
            valid_open,
        )
        home = make_home(
            "merges-etas",
            status_text=(
                "eta: 2099-01-01 later eta: 2020-01-01 missed second\n"
                "eta: 2019-05-05 first\n"
                "beta 2020-03-01 release\n"
                "shipped 2020-01-05 (eta: 2099-12-01)\n"
            ),
        )
        snap = {
            "schema": "fm-fleet-snapshot.v1",
            "note": "eta: 2017-02-02 buried",
            "backlog": {
                "present": True,
                "records": [
                    {
                        "id": "done",
                        "title": "eta: 2018-01-01 done row",
                        "captain_actionable": False,
                    }
                ],
            },
            "secondmate_current": {
                "registry": {"available": True, "complete": True},
                "records": [],
                "truncated": 0,
            },
        }
        (home / "snapshot.json").write_text(json.dumps(snap))
        config = (home / "config" / "goal-digest").read_text()
        config += f"status = Snapshot | {home / 'snapshot.json'}\n"
        (home / "config" / "goal-digest").write_text(config)
        proc = run(home, RUN1)
        doc, md = published(home) if proc.returncode == 0 else ({}, "")
        save("merges-etas", home)
        numbers = [m.get("number") for m in doc.get("new_merges", [])]
        titles = [m.get("title") for m in doc.get("new_merges", [])]
        etas = sorted(m.get("eta") for m in doc.get("missed_etas", []))
        scenario(
            "A digest run reports a duplicated closed pull once and leaves an older merge out of the new-merge list",
            proc.returncode == 0
            and doc.get("generated_at") == iso_of(RUN1)
            and numbers == [1]
            and titles == ["First"]
            and 9 not in numbers
            and any(p.get("number") == 7 for p in doc.get("open_pull_requests", [])),
            "goal-digest/merges-etas.md",
            f"generated_at={doc.get('generated_at')} new_merges={list(zip(numbers, titles))} open={[p.get('number') for p in doc.get('open_pull_requests', [])]}",
        )
        scenario(
            "A digest run counts every past ETA on a prose status line and does not treat dates inside a fleet snapshot as missed ETAs",
            proc.returncode == 0
            and etas == ["2019-05-05", "2020-01-01"]
            and "eta 2018-01-01" not in md
            and "eta 2017-02-02" not in md
            and "2020-03-01" not in md
            and "eta 2099-01-01" not in md
            and "eta 2020-01-01" in md
            and "eta 2019-05-05" in md,
            "goal-digest/merges-etas.md",
            f"missed_etas={etas}",
        )

        # --- open parse failure ---
        put_pulls([valid_merge], valid_open + ["not-an-object"])
        home = make_home("open-parse")
        proc = run(home, RUN1)
        doc, md = published(home)
        save("open-parse", home)
        open_fail = [
            u
            for u in doc.get("unreachable_sources", [])
            if u.get("kind") == "repo-open" and u.get("source") == REPO
        ]
        scenario(
            "An open pull list that mixes a real pull with a non-object is recorded as a parse failure and publishes no open rows",
            proc.returncode == 0
            and doc.get("open_pull_requests") == []
            and len(open_fail) == 1
            and open_fail[0].get("detail") == "pull parse failed"
            and [m.get("number") for m in doc.get("new_merges", [])] == [1],
            "goal-digest/open-parse.json",
            f"unreachable={open_fail} open={doc.get('open_pull_requests')} merges={[m.get('number') for m in doc.get('new_merges', [])]}",
        )

        # --- closed non-object ---
        put_pulls([valid_merge, "not-an-object"], valid_open)
        home = make_home("closed-nondict")
        proc = run(home, RUN1)
        doc, _md = published(home)
        save("closed-nondict", home)
        closed_fail = [
            u
            for u in doc.get("unreachable_sources", [])
            if u.get("kind") == "repo" and u.get("source") == REPO
        ]
        scenario(
            "A closed pull list that mixes a real merge with a non-object is recorded as a parse failure and publishes no merges",
            proc.returncode == 0
            and doc.get("new_merges") == []
            and len(closed_fail) == 1
            and closed_fail[0].get("detail") == "pull parse failed"
            and [p.get("number") for p in doc.get("open_pull_requests", [])] == [7],
            "goal-digest/closed-nondict.json",
            f"unreachable={closed_fail} merges={doc.get('new_merges')} open={[p.get('number') for p in doc.get('open_pull_requests', [])]}",
        )

        # --- closed non-list ---
        put_pulls({"error": "nope"}, valid_open)
        home = make_home("closed-nonlist")
        proc = run(home, RUN1)
        doc, _md = published(home)
        save("closed-nonlist", home)
        closed_fail = [
            u
            for u in doc.get("unreachable_sources", [])
            if u.get("kind") == "repo" and u.get("source") == REPO
        ]
        scenario(
            "A closed pull payload that is not a list is recorded as unreachable and publishes no merges",
            proc.returncode == 0
            and doc.get("new_merges") == []
            and len(closed_fail) == 1
            and "not used" in (closed_fail[0].get("detail") or "")
            and [p.get("number") for p in doc.get("open_pull_requests", [])] == [7],
            "goal-digest/closed-nonlist.json",
            f"unreachable={closed_fail} merges={doc.get('new_merges')}",
        )

        # --- owner actions and secondmate hold ages ---
        put_pulls([valid_merge], valid_open)
        owner_snap = {
            "schema": "fm-fleet-snapshot.v1",
            "backlog": {
                "present": True,
                "records": [
                    {
                        "id": "decision-a",
                        "title": "Choose route",
                        "captain_actionable": True,
                        "hold_set": "2026-01-01T10:00:00Z",
                    },
                    {
                        "id": "string-true",
                        "title": "Should not wait",
                        "captain_actionable": "true",
                        "hold_set": "2026-01-01T10:00:00Z",
                    },
                    {"id": None, "title": "Broken row", "captain_actionable": True},
                ],
            },
            "secondmate_current": {
                "registry": {"available": True, "complete": True},
                "records": [
                    {
                        "id": "mate-a",
                        "registered": True,
                        "provenance": {
                            "selected": "structured-home",
                            "trust": "complete",
                            "summary_valid": True,
                            "summary_source": "remote-ledger",
                        },
                        "current": {"state": "captain_decision"},
                        "freshness": {
                            "status": "fresh",
                            "observed_at": "2026-01-01T12:00:00Z",
                            "age_seconds": 0,
                        },
                        "decisions_open": [
                            {
                                "id": "route",
                                "verb": "captain-hold",
                                "question": "Choose route: north or south?",
                                "hold_age_days": 30,
                            },
                            {
                                "id": "bool-hold",
                                "verb": "captain-hold",
                                "question": "Bool age",
                                "hold_age_days": True,
                            },
                            {
                                "id": "string-age",
                                "verb": "captain-hold",
                                "question": "String age",
                                "hold_age_days": "30",
                            },
                            {
                                "id": "negative-age",
                                "verb": "captain-hold",
                                "question": "Negative age",
                                "hold_age_days": -4,
                            },
                        ],
                        "counts": {"decisions_open": 4},
                        "omitted": [],
                    }
                ],
                "truncated": 0,
            },
        }
        home = make_home("owner", snapshot=owner_snap)
        proc = run(home, RUN1)
        doc, md = published(home)
        save("owner", home)
        waits = {w["id"]: w for w in doc.get("waiting_on_captain", [])}
        now = datetime.datetime.fromtimestamp(RUN1, datetime.timezone.utc)
        held = datetime.datetime(2026, 1, 1, 10, 0, tzinfo=datetime.timezone.utc)
        expect_hours = int((now.timestamp() - held.timestamp()) // 3600)
        route = waits.get("route", {})
        scenario(
            "A secondmate captain-hold with hold_age_days and no wait start is published as that many days, while a boolean, a string, and a negative count stay unknown",
            proc.returncode == 0
            and route.get("age_days") == 30
            and route.get("age_precision") == "day"
            and route.get("age_hours") is None
            and route.get("wait_started_at") is None
            and "age_days=30 (day precision)" in md
            and all(
                waits.get(i, {}).get("age_days") is None
                and waits.get(i, {}).get("age_hours") is None
                and waits.get(i, {}).get("age_precision") == "unknown"
                for i in ("bool-hold", "string-age", "negative-age")
            )
            and all(i in waits for i in ("bool-hold", "string-age", "negative-age")),
            "goal-digest/owner.md",
            "route="
            + json.dumps({k: route.get(k) for k in ("age_days", "age_hours", "age_precision", "wait_started_at")})
            + " invalid="
            + json.dumps(
                {
                    i: {k: waits.get(i, {}).get(k) for k in ("age_days", "age_hours", "age_precision")}
                    for i in ("bool-hold", "string-age", "negative-age")
                }
            ),
        )
        decision = waits.get("decision-a", {})
        scenario(
            "A backlog row ages from its UTC hold_set, a string-valued captain_actionable flag is ignored, and a row with no id is recorded malformed instead of listed",
            proc.returncode == 0
            and decision.get("age_hours") == expect_hours
            and decision.get("age_precision") == "hour"
            and "string-true" not in waits
            and "Should not wait" not in md
            and None not in waits
            and "Broken row" not in md
            and any(
                u.get("detail") == "owner-action record malformed"
                for u in doc.get("waiting_on_captain_unknown_sources", [])
            )
            and f"age_hours={expect_hours}" in md,
            "goal-digest/owner.md",
            f"decision-a age_hours={decision.get('age_hours')} expected {expect_hours}; unknown={doc.get('waiting_on_captain_unknown_sources')}",
        )

        # --- failed first publication keeps the original window ---
        put_pulls([valid_merge, old_merge], valid_open)
        home = make_home("window")
        history = home / "data" / "goal-digest" / "history"
        history.mkdir(parents=True)
        history.chmod(0o555)
        proc = run(home, RUN1)
        state = home / "data" / "goal-digest" / ".state"
        pending = (state / "pending-since.tsv").read_text() if (state / "pending-since.tsv").exists() else ""
        since = (state / "since.tsv").read_text() if (state / "since.tsv").exists() else ""
        stray = list(home.rglob("since-pending.tsv"))
        history.chmod(0o755)
        log(f"pending after blocked publication: {pending!r}")
        log(f"since after blocked publication: {since!r}")
        blocked_ok = (
            proc.returncode != 0
            and not (home / "data" / "goal-digest" / "latest.md").exists()
            and REPO in pending
            and "1767182400" in pending
            and REPO not in since
        )
        proc2 = run(home, RETRY)
        doc, md = published(home) if proc2.returncode == 0 else ({}, "")
        save("window-retry", home)
        stray += list(home.rglob("since-pending.tsv"))
        numbers = [m.get("number") for m in doc.get("new_merges", [])]
        pending2 = (state / "pending-since.tsv").read_text() if (state / "pending-since.tsv").exists() else ""
        since2 = (state / "since.tsv").read_text() if (state / "since.tsv").exists() else ""
        log(f"pending after retry: {pending2!r}")
        log(f"since after retry: {since2!r}")
        scenario(
            "After a blocked first publication, a retry two days later still reports the original day's merge and not a merge from the previous year, and no since-pending file is created",
            blocked_ok
            and proc2.returncode == 0
            and numbers == [1]
            and "https://example.invalid/pr/1" in md
            and "https://example.invalid/pr/9" not in md
            and REPO in since2
            and REPO not in pending2
            and stray == [],
            "goal-digest/window-retry.md",
            f"blocked_rc={proc.returncode} retry_merges={numbers} stray={stray} pending1={pending!r}",
        )

        # --- history pairing ---
        put_pulls([valid_merge], valid_open)
        home = make_home("history")
        hist = None

        def set_review(token):
            (home / "review.status").write_text(token + "\n")

        def hist_dir():
            return home / "data" / "goal-digest" / "history"

        def read_pair(stem):
            d = hist_dir()
            return (d / f"{stem}.md").read_text(), (d / f"{stem}.json").read_text()

        set_review("TOKEN-A first archive")
        proc_a = run(home, RUN1)
        set_review("TOKEN-B second archive")
        proc_b = run(home, RUN1)
        stem0 = stamp_of(RUN1)
        md_a, json_a = read_pair(stem0)
        md_b, json_b = read_pair(stem0 + "-1")
        scenario(
            "A second digest run in the same second keeps the first history pair and writes the new markdown and JSON under the same suffix",
            proc_a.returncode == 0
            and proc_b.returncode == 0
            and "TOKEN-A first archive" in md_a
            and "TOKEN-A first archive" in json_a
            and "TOKEN-B second archive" not in md_a
            and "TOKEN-B second archive" not in json_a
            and "TOKEN-B second archive" in md_b
            and "TOKEN-B second archive" in json_b
            and "TOKEN-A first archive" not in md_b
            and "TOKEN-A first archive" not in json_b,
            "goal-digest/history-listing.txt",
            f"stems present: {sorted(p.name for p in hist_dir().iterdir())}",
        )

        stamp17 = stamp_of(RUN17)
        (hist_dir() / f"{stamp17}.json.tmp").mkdir()
        set_review("TOKEN-C free stamp")
        proc_c = run(home, RUN17)
        md_c, json_c = read_pair(stamp17)
        scenario(
            "A leftover history temp directory does not stop the run from archiving that second's markdown and JSON under the free unsuffixed names",
            proc_c.returncode == 0
            and "TOKEN-C free stamp" in md_c
            and "TOKEN-C free stamp" in json_c
            and (hist_dir() / f"{stamp17}.json.tmp").is_dir()
            and not (hist_dir() / f"{stamp17}-1.md").exists(),
            "goal-digest/history-listing.txt",
            f"free stamp {stamp17} tmp_still_there={(hist_dir() / (stamp17 + '.json.tmp')).is_dir()}",
        )

        stamp13 = stamp_of(RUN2)
        (hist_dir() / f"{stamp13}.md").write_text("orphan attempt\n")
        (hist_dir() / f"{stamp13}.json.tmp").mkdir()
        set_review("TOKEN-D shifted")
        proc_d = run(home, RUN2)
        md_d, json_d = read_pair(stamp13 + "-1")
        orphan = (hist_dir() / f"{stamp13}.md").read_text()
        scenario(
            "When a stamp already has markdown and only a temp JSON, the retry archives both of its files under the next shared suffix and leaves the orphan markdown in place",
            proc_d.returncode == 0
            and orphan == "orphan attempt\n"
            and not (hist_dir() / f"{stamp13}.json").exists()
            and "TOKEN-D shifted" in md_d
            and "TOKEN-D shifted" in json_d
            and "orphan attempt" not in md_d
            and "orphan attempt" not in json_d,
            "goal-digest/history-listing.txt",
            f"orphan={orphan!r} suffix-1 has token D; unsuffixed json exists={(hist_dir() / (stamp13 + '.json')).exists()}",
        )
        saved_md, saved_json = md_d, json_d
        set_review("TOKEN-E shifted again")
        proc_e = run(home, RUN2)
        md_e, json_e = read_pair(stamp13 + "-2")
        again_md, again_json = read_pair(stamp13 + "-1")
        listing = "\n".join(sorted(p.name for p in hist_dir().iterdir()))
        (EVID / "history-listing.txt").write_text(listing + "\n")
        log("HISTORY\n" + listing)
        scenario(
            "A later same-second run does not rewrite the previous paired suffix or attach its JSON to that earlier markdown",
            proc_e.returncode == 0
            and again_md == saved_md
            and again_json == saved_json
            and "TOKEN-E shifted again" in md_e
            and "TOKEN-E shifted again" in json_e
            and "TOKEN-E shifted again" not in again_md
            and "TOKEN-E shifted again" not in again_json,
            "goal-digest/history-listing.txt",
            f"listing:\n{listing}",
        )

        # --- summarizer pin, remap unset, whitespace rejected ---
        put_pulls([valid_merge], valid_open)
        home = make_home("summary")
        opus = {
            "ANTHROPIC_MODEL": "claude-opus-4-6",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-opus-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-opus-4-6",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6",
            "FM_GD_SUMMARY_MODE": "ok",
        }
        proc = run(home, RUN1, opus)
        summary_path = home / "data" / "goal-digest" / "summary.txt"
        first_summary = summary_path.read_text() if summary_path.exists() else ""
        runner_log = (home / "runner.log").read_text() if (home / "runner.log").exists() else ""
        (home / "review.status").write_text("TOKEN-SUMMARY changed\n")
        proc2 = run(home, RUN3, dict(opus, FM_GD_SUMMARY_MODE="whitespace"))
        second_summary = summary_path.read_text() if summary_path.exists() else ""
        runner_log = (home / "runner.log").read_text()
        (EVID / "summarizer-log.txt").write_text(runner_log)
        (EVID / "summary.txt").write_text(second_summary)
        log("RUNNER\n" + runner_log)
        invocations = [block for block in runner_log.split("ARGV:") if block.strip()]
        pinned = all("<claude-haiku-4-5>" in block and "claude-opus" not in block for block in invocations)
        unset_ok = all(
            f"{name}=unset" in runner_log
            for name in (
                "ANTHROPIC_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
            )
        )
        scenario(
            "The digest invokes the summarizer as claude-haiku-4-5 with model-remap variables unset, and a whitespace-only reply leaves the previous summary in place",
            proc.returncode == 0
            and proc2.returncode == 0
            and first_summary == "owner summary line\n"
            and second_summary == "owner summary line\n"
            and len(invocations) == 2
            and pinned
            and unset_ok
            and "summary unavailable" in proc2.stderr
            and "changed=yes" in proc2.stdout,
            "goal-digest/summarizer-log.txt",
            f"invocations={len(invocations)} pinned={pinned} unset={unset_ok} summary={second_summary!r} stderr={proc2.stderr.strip()!r}",
        )

        # Mexico City date used above is only as the product's own zone for ETAs.
        _ = ZoneInfo
    finally:
        if lab.exists():
            for dirpath, dirnames, filenames in os.walk(lab):
                os.chmod(dirpath, os.stat(dirpath).st_mode | stat.S_IWUSR)
            shutil.rmtree(lab)

    out = EVID / "live-transcript.txt"
    out.write_text("\n".join(transcript) + "\n")
    (EVID / "live-results.json").write_text(json.dumps(results, indent=2) + "\n")
    failed = [r for r in results if r["result"] != "pass"]
    log(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
