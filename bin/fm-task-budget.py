#!/usr/bin/env python3
"""Native task budget records; invoked through fm-task-budget.sh."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


LIMITS = ("inclusive_hard", "inclusive_stop", "fresh_hard", "fresh_stop")


def read_meta(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator:
            if key.startswith("budget_") and key in result:
                raise ValueError("duplicate budget metadata")
            result[key] = value
    limits([result.get("budget_" + key, "") for key in LIMITS])
    return result


def read_state(path):
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("invalid budget state")
    return value


def save_state(path, value):
    descriptor, staging = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream)
            stream.write("\n")
        os.replace(staging, path)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)


def records(path, offset=0):
    with path.open("rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break  # The harness may still be appending its last record.
            offset += len(line)
            if line.strip():
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError("invalid native record")
                yield offset, value


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("unsupported native timestamp")
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def mapping(value):
    if not isinstance(value, dict):
        raise ValueError("unsupported native object shape")
    return value


def initial_launch_matches(path, harness, marker):
    for _, row in records(path):
        if harness == "claude":
            if row.get("type") != "user" or row.get("isMeta"):
                continue
            content = mapping(row.get("message")).get("content")
        else:
            payload = mapping(row.get("payload", {}))
            if row.get("type") == "event_msg" and payload.get("type") == "user_message":
                content = payload.get("message")
            elif row.get("type") == "response_item" and payload.get("role") == "user":
                content = payload.get("content")
            else:
                continue
        if isinstance(content, list):
            texts = [part.get("text", "") for part in content if isinstance(part, dict)
                     and part.get("type") in ("text", "input_text")]
        elif isinstance(content, str):
            texts = [content]
        else:
            return False
        # Codex inserts repository instructions/environment before the actual prompt.
        if harness == "codex" and texts and all(
                text.startswith(("# AGENTS.md instructions for ", "<environment_context>"))
                or text.splitlines()[0] == "# AGENTS.md instructions" for text in texts if text):
            continue
        if marker.startswith("sha256:"):
            return any(hashlib.sha256(text.encode()).hexdigest() == marker[7:] for text in texts)
        return any(marker in text.splitlines() for text in texts)
    return False


def identity(path, harness, marker):
    for _, row in records(path):
        if harness == "codex":
            if row.get("type") != "session_meta":
                return None
            meta = mapping(row.get("payload"))
            if meta.get("source") not in ("cli", "exec"):
                return None
            session = meta.get("id")
            if not isinstance(session, str) or not session or not initial_launch_matches(path, harness, marker):
                return None
            return session, meta.get("cwd"), timestamp(meta["timestamp"])
        if row.get("sessionId") and row.get("cwd"):
            if row.get("isSidechain") or row.get("agentId"):
                return None
            if not isinstance(row["sessionId"], str) or not initial_launch_matches(path, harness, marker):
                return None
            return row["sessionId"], row["cwd"], timestamp(row["timestamp"])
    return None


def number(value):
    if type(value) is not int or value < 0:
        raise ValueError("native counters must be non-negative integers")
    return value


def fold(path, harness, cache):
    offset = cache.get("offset", 0)
    messages = dict(cache.get("messages", {}))
    previous = cache.get("previous")
    for offset, row in records(path, offset):
        if harness == "claude":
            if row.get("type") != "assistant":
                continue
            message = mapping(row.get("message"))
            usage = message.get("usage")
            if usage is None:
                continue
            usage = mapping(usage)
            mid = message.get("id")
            if not isinstance(mid, str) or not mid:
                raise ValueError("Claude usage has no message id")
            values = tuple(number(usage.get(key, 0)) for key in (
                "input_tokens", "cache_creation_input_tokens", "output_tokens", "cache_read_input_tokens"
            ))
            if "input_tokens" not in usage or "output_tokens" not in usage:
                raise ValueError("unsupported Claude usage shape")
            messages[mid] = [sum(values), sum(values[:3])]
        elif row.get("type") in ("event_msg", "token_usage_record"):
            payload = mapping(row.get("payload"))
            if row["type"] == "token_usage_record":
                usage = mapping(payload.get("thread_token_usage"))
            else:
                if payload.get("type") != "token_count":
                    continue
                info = payload.get("info")
                if info is None:
                    continue
                usage = mapping(mapping(info).get("total_token_usage"))
            values = tuple(number(usage[key]) for key in ("input_tokens", "cached_input_tokens", "output_tokens"))
            incoming, cached, outgoing = values
            if cached > incoming or number(usage.get("total_tokens", incoming + outgoing)) != incoming + outgoing:
                raise ValueError("inconsistent Codex counters")
            if number(usage.get("cache_write_input_tokens", 0)) > incoming - cached:
                raise ValueError("inconsistent Codex cache-write counters")
            if previous is not None and any(now < before for now, before in zip(values, previous)):
                raise ValueError("Codex cumulative counters reset")
            previous = list(values)
    cache.update(offset=offset, messages=messages, previous=previous)
    if harness == "claude" and messages:
        return tuple(sum(value[i] for value in messages.values()) for i in (0, 1))
    if previous is not None:
        incoming, cached, outgoing = previous
        return incoming + outgoing, incoming - cached + outgoing
    return None


def measure(path, persist=True):
    path = Path(path)
    meta = read_meta(path)
    prior_inclusive = int(meta["budget_prior_inclusive"])
    prior_fresh = int(meta["budget_prior_fresh"])
    if prior_fresh < 0 or prior_inclusive < prior_fresh:
        raise ValueError("invalid prior native consumption")
    harness = meta.get("harness")
    if harness not in ("claude", "codex"):
        raise ValueError("unsupported native budget harness: " + str(harness))
    root = Path(meta["budget_log_root"])
    if not root.is_absolute() or not root.is_dir():
        raise ValueError("native log root is missing or not absolute")
    worktree = os.path.realpath(meta["budget_worktree"])
    if worktree != os.path.realpath(meta["worktree"]):
        raise ValueError("budget worktree identity changed")
    boundary = float(meta["budget_launch_at"])
    marker = meta["budget_launch_marker"]
    if not re.fullmatch(r"FM_BUDGET_LAUNCH_[A-Za-z0-9]+", marker):
        raise ValueError("invalid native launch marker")
    if "budget_launch_fingerprint" in meta:
        fingerprint = meta["budget_launch_fingerprint"]
        if harness != "claude" or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
            raise ValueError("invalid native launch fingerprint")
        marker = "sha256:" + fingerprint
    state_path = path.with_suffix(".budget")
    state = read_state(state_path)
    cache = state.get("counter", {})
    if cache.get("generation") != meta.get("spawn_gen"):
        cache = {}
    if cache:
        log = Path(cache["log"])
        selected = identity(log, harness, marker)
        if not selected or selected[0] != cache["session"] or os.path.realpath(selected[1]) != worktree:
            raise ValueError("bound native session identity changed")
    else:
        candidates = []
        for log in root.rglob("*.jsonl"):
            if log.is_symlink() or "subagents" in log.relative_to(root).parts or log.stat().st_mtime < boundary:
                continue
            try:
                selected = identity(log, harness, marker)
            except (ValueError, KeyError, OSError):
                continue  # An unrelated session cannot establish this task's binding.
            if selected and selected[1] and os.path.realpath(selected[1]) == worktree and selected[2] >= boundary:
                candidates.append((log, selected[0]))
        if not candidates:
            return {"status": "pending", "reason": "native main session not yet identified"}
        if len(candidates) != 1:
            raise ValueError("ambiguous native main sessions")
        log, session = candidates[0]
        cache = {"generation": meta.get("spawn_gen"), "log": str(log), "session": session}
    stat = log.stat()
    signature = [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns]
    old = cache.get("signature")
    if old and (signature[:2] != old[:2] or signature[2] < old[2]):
        raise ValueError("bound native log was replaced or truncated")
    if signature != old:
        usage = fold(log, harness, cache)
        if usage is not None:
            inclusive, fresh = usage
            if inclusive < cache.get("inclusive", 0) or fresh < cache.get("fresh", 0):
                raise ValueError("native usage decreased")
            cache.update(inclusive=inclusive, fresh=fresh)
        cache["signature"] = signature
    if persist:
        state["counter"] = cache
        save_state(state_path, state)
    if "inclusive" not in cache:
        return {"status": "pending", "reason": "native usage not yet recorded"}
    return {
        "status": "ok", "harness": harness, "session": cache["session"], "source": cache["log"],
        "inclusive": cache["inclusive"] + prior_inclusive,
        "fresh": cache["fresh"] + prior_fresh,
        "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def limits(values):
    if len(values) != 4 or any(not re.fullmatch(r"[1-9][0-9]*", v) for v in values):
        raise ValueError("all four budget limits must be positive decimal token counts")
    numbers = [int(v) for v in values]
    if any(n > 2**63 - 1 for n in numbers):
        raise ValueError("budget token count exceeds signed 64-bit range")
    if numbers[1] > numbers[0] or numbers[3] > numbers[2]:
        raise ValueError("budget stop lines must not exceed their hard caps")
    return dict(zip(LIMITS, numbers))


def seed(args):
    prior, harness, worktree, root, marker, *values = args
    bounds = limits(values)
    if not re.fullmatch(r"FM_BUDGET_LAUNCH_[A-Za-z0-9]+", marker):
        raise ValueError("invalid native launch marker")
    previous = None
    if prior != "-":
        try:
            previous = measure(prior, persist=False)
            if previous["status"] != "ok":
                raise ValueError(previous["reason"])
        except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
            previous = None
            print(f"budget-unknown task={Path(prior).stem} prior incarnation usage not carried over: {error}",
                  file=sys.stderr)
    record = {"budget_" + key: value for key, value in bounds.items()}
    record.update(
        budget_launch_at=str(time.time()),
        budget_worktree=os.path.realpath(worktree),
        budget_log_root=os.path.abspath(root) if root else "",
        budget_launch_marker=marker,
        budget_prior_inclusive=previous["inclusive"] if previous else 0,
        budget_prior_fresh=previous["fresh"] if previous else 0,
    )
    record["budget_started_at"] = read_meta(prior)["budget_started_at"] if previous else record["budget_launch_at"]
    for key, value in record.items():
        if "\n" in str(value) or "\r" in str(value):
            raise ValueError("budget source identity must be one line")
    for key, value in record.items():
        print(f"{key}={value}")


def decision(path, episode):
    status = path.with_suffix(".status")
    marker = "[key=" + episode["key"] + "]"
    if status.exists() and any(line.startswith("needs-decision ") and marker in line for line in status.read_text().splitlines()):
        return
    sample = episode["sample"]
    outcome = episode["attempt"]["outcome"].replace("\n", " ")[:400]
    bounds = dict(zip(LIMITS, episode["limits"]))
    text = (
        f"needs-decision [at={int(time.time())}] {marker}: budget-stop "
        f"inclusive={sample['inclusive']} stop={bounds['inclusive_stop']} hard={bounds['inclusive_hard']} "
        f"fresh={sample['fresh']} stop={bounds['fresh_stop']} hard={bounds['fresh_hard']} "
        f"observed={sample['observed_at']} interrupt={outcome}; details={path.with_suffix('.budget')}\n"
    )
    with status.open("a") as stream:
        stream.write(text)


def prepare(path, config):
    path = Path(path)
    diagnostic = path.with_suffix(".budget-diagnostic")
    harness = "unknown"
    try:
        meta = read_meta(path)
        harness = meta.get("harness", "unknown")
        if meta.get("kind") == "secondmate":
            return "none"
        values = [int(meta["budget_" + key]) for key in LIMITS]
        allocation = [meta["budget_started_at"], values]
        episode = read_state(path.with_suffix(".budget")).get("episode", {})
        attempt = episode.get("attempt")
        if episode.get("allocation") == allocation and attempt and not attempt.get("deferred"):
            # A claimed action already has evidence, even if its native log is gone.
            decision(path, episode)
        setting = Path(config) / "budget-enforcement"
        mode = setting.read_text().strip() if setting.exists() else "dry-run"
        if mode not in ("dry-run", "enforce"):
            raise ValueError("budget-enforcement must be dry-run or enforce")
        sample = measure(path)
        if sample["status"] != "ok":
            raise ValueError(sample["reason"])
        state = read_state(path.with_suffix(".budget"))
        episode = state.get("episode", {})
        if episode.get("allocation") != allocation:
            sequence = state.get("sequence", 0) + 1
            key = hashlib.sha256(json.dumps([allocation, sequence]).encode()).hexdigest()[:16]
            episode = {"allocation": allocation, "limits": values, "key": "budget-stop-" + key}
            state.update(sequence=sequence, episode=episode)
        if diagnostic.exists():
            diagnostic.unlink()
        if sample["inclusive"] < values[1] and sample["fresh"] < values[3]:
            save_state(path.with_suffix(".budget"), state)
            return "none"
        episode["sample"] = sample
        if mode == "dry-run":
            if "dry_run_event" not in episode:
                event = dict(sample, kind="would-pause", limits=values, task=path.stem)
                episode["dry_run_event"] = event
                print(f"budget-would-pause task={path.stem} inclusive={sample['inclusive']} fresh={sample['fresh']} "
                      f"inclusive_stop={values[1]} fresh_stop={values[3]} inclusive_hard={values[0]} fresh_hard={values[2]} "
                      f"observed={sample['observed_at']} source={sample['source']}", file=sys.stderr)
            save_state(path.with_suffix(".budget"), state)
            return "none"
        previous = episode.get("attempt")
        if previous and not previous.get("deferred"):
            # One interrupt per stop-line episode; later usage awaits the open decision.
            save_state(path.with_suffix(".budget"), state)
            return "none"
        episode["attempt"] = {"outcome": "uncertain: attempt claimed before lifecycle action"}
        save_state(path.with_suffix(".budget"), state)
        return "interrupt"
    except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
        reason = f"harness={harness}: {error}"
        if not diagnostic.exists() or diagnostic.read_text() != reason:
            diagnostic.write_text(reason)
            print(f"budget-unknown task={path.stem} {reason}", file=sys.stderr)
        return "none"


def finish(path, code, output):
    path = Path(path)
    state = read_state(path.with_suffix(".budget"))
    episode = state["episode"]
    deferred = code != "0" and "another lifecycle action is already running" in output
    episode["attempt"].update(outcome=output or f"control exit={code} without proof", deferred=deferred)
    save_state(path.with_suffix(".budget"), state)
    if not deferred:
        decision(path, episode)


def main():
    mode, *args = sys.argv[1:]
    if mode == "validate":
        limits(args)
    elif mode == "seed":
        seed(args)
    elif mode == "measure":
        try:
            result = measure(args[0])
        except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
            result = {"status": "unknown", "reason": str(error)}
        print(json.dumps(result))
    elif mode == "prepare":
        print(prepare(*args))
    elif mode == "finish":
        finish(*args)
    else:
        raise ValueError("unknown task-budget command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"task-budget: {error}", file=sys.stderr)
        sys.exit(1)
