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
    present = [result.get("budget_" + key, "") for key in LIMITS]
    # A child measured against a lane has bindings and no four limits of its own.
    if any(present):
        limits(present)
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


def same_file(left, right):
    try:
        return os.path.samefile(left, right)
    except OSError:
        return False


def claude_sidechain_belongs(path, session, worktree):
    if session in path.parts:
        return True
    try:
        for _, row in records(path):
            if row.get("sessionId") == session:
                return True
            cwd = row.get("cwd")
            if isinstance(cwd, str) and cwd and os.path.realpath(cwd) == worktree:
                return True
    except (ValueError, KeyError, OSError, TypeError, AttributeError):
        return False
    return False


def file_started_at(path, harness):
    for _, row in records(path):
        if harness == "claude":
            if row.get("timestamp"):
                return timestamp(row["timestamp"])
            continue
        if row.get("type") == "session_meta":
            return timestamp(mapping(row.get("payload"))["timestamp"])
        return None
    return None


def codex_related_belongs(path, session, worktree, boundary):
    try:
        first = None
        for _, row in records(path):
            first = row
            break
        if not first or first.get("type") != "session_meta":
            return False
        meta = mapping(first.get("payload"))
        if meta.get("source") not in ("cli", "exec"):
            return False
        other = meta.get("id")
        if not isinstance(other, str) or not other or other == session:
            return False
        cwd = meta.get("cwd")
        if not isinstance(cwd, str) or not cwd or os.path.realpath(cwd) != worktree:
            return False
        return timestamp(meta["timestamp"]) >= boundary
    except (ValueError, KeyError, OSError, TypeError, AttributeError):
        return False


def usage_pair(path, harness):
    found = fold(path, harness, {})
    if found is None:
        return 0, 0
    return found


def sum_sidechain(root, harness, main_log, session, worktree, boundary):
    inclusive = fresh = 0
    for log in root.rglob("*.jsonl"):
        if log.is_symlink() or same_file(log, main_log):
            continue
        try:
            if log.stat().st_mtime < boundary:
                continue
            parts = log.relative_to(root).parts
        except (OSError, ValueError):
            continue
        if harness == "claude":
            if "subagents" not in parts:
                continue
            if session not in log.parts and not claude_sidechain_belongs(log, session, worktree):
                continue
            started = file_started_at(log, harness)
            if started is not None and started < boundary:
                continue
        elif not codex_related_belongs(log, session, worktree, boundary):
            continue
        extra_inclusive, extra_fresh = usage_pair(log, harness)
        inclusive += extra_inclusive
        fresh += extra_fresh
    return inclusive, fresh


def decimal_total(value, label):
    if not re.fullmatch(r"0|[1-9][0-9]*", str(value)):
        raise ValueError("invalid " + label)
    return int(value)


def folded_from_meta(meta):
    keys = ("budget_folded_inclusive", "budget_folded_fresh", "budget_folded_children")
    if not any(key in meta for key in keys):
        return 0, 0, set()
    inclusive = decimal_total(meta.get("budget_folded_inclusive", "0"), "folded native consumption")
    fresh = decimal_total(meta.get("budget_folded_fresh", "0"), "folded native consumption")
    if inclusive < fresh:
        raise ValueError("invalid folded native consumption")
    names = [part for part in meta.get("budget_folded_children", "").split(",") if part]
    if any(not re.fullmatch(r"[A-Za-z0-9._-]+@FM_BUDGET_LAUNCH_[A-Za-z0-9]+", name) for name in names) or len(names) != len(set(names)):
        raise ValueError("invalid folded child id")
    return inclusive, fresh, set(names)


def folded_unknown(meta):
    names = [part for part in meta.get("budget_folded_unknown", "").split(",") if part]
    if any(not re.fullmatch(r"[A-Za-z0-9._-]+@FM_BUDGET_LAUNCH_[A-Za-z0-9]+", name) for name in names):
        raise ValueError("invalid folded unknown child")
    return names


def lane_meta_of(meta, path):
    if path.name == "lane-budget":
        return meta
    home = meta.get("home", "")
    if not home:
        raise ValueError("secondmate lane has no home")
    lane = Path(home) / "state" / "lane-budget"
    if not lane.is_file() or lane.is_symlink():
        return {}
    return read_meta(lane)


def lane_folded(meta, path):
    lane_meta = lane_meta_of(meta, path)
    unknown = folded_unknown(lane_meta)
    if unknown:
        raise ValueError("torn-down child usage unknown: " + ",".join(unknown))
    return folded_from_meta(lane_meta)


def sum_lane_children(meta, path, folded_ids):
    home = meta.get("home", "")
    if not home:
        raise ValueError("secondmate lane has no home")
    state = Path(home) / "state"
    if not state.is_dir():
        return 0, 0, []
    inclusive = fresh = 0
    rows = []
    self_path = path.resolve()
    for child in sorted(state.glob("*.meta")):
        if child.is_symlink():
            continue
        try:
            if child.resolve() == self_path:
                continue
        except OSError:
            continue
        child_meta = read_meta(child)
        if child_meta.get("kind") == "secondmate":
            continue
        child_id = child.stem
        if "budget_launch_marker" not in child_meta:
            raise ValueError("child " + child_id + " has no native launch marker")
        if child_id + "@" + child_meta["budget_launch_marker"] in folded_ids:
            continue
        if child_meta.get("harness") not in ("claude", "codex"):
            rows.append(child_id + "=unmetered")
            continue
        try:
            sample = measure(child, persist=True, include_lane=False)
        except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
            sample = {"status": "unknown", "reason": str(error)}
        if sample["status"] == "pending":
            rows.append(child_id + "=pending")
            continue
        if sample["status"] != "ok":
            raise ValueError("child " + child_id + " usage unknown: " + sample.get("reason", "unknown"))
        inclusive += sample["inclusive"]
        fresh += sample["fresh"]
        rows.append(child_id + "=measured")
    return inclusive, fresh, rows


def measure(path, persist=True, include_lane=True):
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
    side_inclusive, side_fresh = sum_sidechain(
        root, harness, log, cache["session"], worktree, boundary
    )
    inclusive = cache["inclusive"] + prior_inclusive + side_inclusive
    fresh = cache["fresh"] + prior_fresh + side_fresh
    children = []
    if include_lane and meta.get("kind") == "secondmate":
        fold_inclusive, fold_fresh, folded_ids = lane_folded(meta, path)
        child_inclusive, child_fresh, children = sum_lane_children(meta, path, folded_ids)
        inclusive += fold_inclusive + child_inclusive
        fresh += fold_fresh + child_fresh
    if fresh < 0 or inclusive < fresh:
        raise ValueError("invalid lane native consumption")
    result = {
        "status": "ok", "harness": harness, "session": cache["session"], "source": cache["log"],
        "inclusive": inclusive,
        "fresh": fresh,
        "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if children:
        result["children"] = children
    return result


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
            previous = measure(prior, persist=False, include_lane=False)
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


def carried_prior(prior):
    if prior == "-":
        return None
    try:
        previous = measure(prior, persist=False, include_lane=False)
        if previous["status"] != "ok":
            raise ValueError(previous["reason"])
        return previous
    except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
        print(
            f"budget-unknown task={Path(prior).stem} prior incarnation usage not carried over: {error}",
            file=sys.stderr,
        )
        return None


def print_record(record):
    for value in record.values():
        if "\n" in str(value) or "\r" in str(value):
            raise ValueError("budget source identity must be one line")
    for key, value in record.items():
        print(f"{key}={value}")


def bind(args):
    harness, worktree, root, marker, prior = args
    if not re.fullmatch(r"FM_BUDGET_LAUNCH_[A-Za-z0-9]+", marker):
        raise ValueError("invalid native launch marker")
    previous = carried_prior(prior)
    launch_at = str(time.time())
    record = {
        "budget_launch_at": launch_at,
        "budget_worktree": os.path.realpath(worktree),
        "budget_log_root": os.path.abspath(root) if root else "",
        "budget_launch_marker": marker,
        "budget_prior_inclusive": previous["inclusive"] if previous else 0,
        "budget_prior_fresh": previous["fresh"] if previous else 0,
        "budget_started_at": read_meta(prior)["budget_started_at"] if previous else launch_at,
    }
    print_record(record)


def budget_line(verb, sample, bounds, children):
    child_text = ",".join(children)
    print(
        f"budget-prelaunch {verb} inclusive={sample['inclusive']} stop={bounds['inclusive_stop']} "
        f"hard={bounds['inclusive_hard']} fresh={sample['fresh']} stop={bounds['fresh_stop']} "
        f"hard={bounds['fresh_hard']} children={child_text}",
        file=sys.stderr,
    )


def prelaunch(home):
    lane = Path(home) / "state" / "lane-budget"
    if not lane.is_file() or lane.is_symlink():
        return 0
    try:
        sample = measure(lane)
        if sample["status"] == "pending":
            print(f"budget-prelaunch refuse pending: {sample['reason']}", file=sys.stderr)
            return 1
        if sample["status"] != "ok":
            print(f"budget-prelaunch refuse unknown: {sample.get('reason', 'unknown')}", file=sys.stderr)
            return 1
        meta = read_meta(lane)
        bounds = limits([meta["budget_" + key] for key in LIMITS])
        children = sample.get("children") or []
        over = sample["inclusive"] >= bounds["inclusive_stop"] or sample["fresh"] >= bounds["fresh_stop"]
        budget_line("refuse" if over else "allow", sample, bounds, children)
        return 1 if over else 0
    except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
        print(f"budget-prelaunch refuse unknown: {error}", file=sys.stderr)
        return 1


def replace_budget_keys(path, updates):
    lines = Path(path).read_text().splitlines()
    kept = [line for line in lines if line.partition("=")[0] not in updates]
    for key, value in updates.items():
        if "\n" in str(value) or "\r" in str(value):
            raise ValueError("budget source identity must be one line")
        kept.append(f"{key}={value}")
    descriptor, staging = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write("\n".join(kept) + "\n")
        os.replace(staging, path)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)


def fold_away(lane, child):
    lane = Path(lane)
    child = Path(child)
    if not lane.is_file() or lane.is_symlink():
        return 0
    if not child.is_file() or child.is_symlink():
        raise ValueError("child metadata is missing")
    lane_meta = read_meta(lane)
    child_meta = read_meta(child)
    if "budget_launch_marker" not in child_meta:
        return 0
    fold_key = child.stem + "@" + child_meta["budget_launch_marker"]
    _, _, folded_ids = folded_from_meta(lane_meta)
    unknown = folded_unknown(lane_meta)
    if fold_key in folded_ids or fold_key in unknown:
        return 0
    if child_meta.get("harness") not in ("claude", "codex"):
        sample = {"status": "pending"}
    else:
        try:
            sample = measure(child, persist=True, include_lane=False)
        except (ValueError, KeyError, OSError, TypeError, AttributeError) as error:
            sample = {"status": "unknown", "reason": str(error)}
    if sample["status"] == "pending":
        add_inclusive = add_fresh = 0
    elif sample["status"] != "ok":
        replace_budget_keys(lane, {"budget_folded_unknown": ",".join(unknown + [fold_key])})
        print(
            f"budget-unknown fold-away child={fold_key}: {sample.get('reason', 'unknown child usage')}",
            file=sys.stderr,
        )
        return 0
    else:
        add_inclusive = sample["inclusive"]
        add_fresh = sample["fresh"]
    base_inclusive, base_fresh, _ = folded_from_meta(lane_meta)
    new_inclusive = base_inclusive + add_inclusive
    new_fresh = base_fresh + add_fresh
    if new_fresh < 0 or new_inclusive < new_fresh:
        raise ValueError("invalid folded native consumption")
    replace_budget_keys(lane, {
        "budget_folded_inclusive": str(new_inclusive),
        "budget_folded_fresh": str(new_fresh),
        "budget_folded_children": ",".join(sorted(folded_ids | {fold_key})),
    })
    return 0


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
    elif mode == "bind":
        bind(args)
    elif mode == "prelaunch":
        if len(args) != 1:
            raise ValueError("prelaunch expects a home")
        sys.exit(prelaunch(args[0]))
    elif mode == "fold-away":
        if len(args) != 2:
            raise ValueError("fold-away expects a lane file and a child record")
        sys.exit(fold_away(args[0], args[1]))
    else:
        raise ValueError("unknown task-budget command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"task-budget: {error}", file=sys.stderr)
        sys.exit(1)
