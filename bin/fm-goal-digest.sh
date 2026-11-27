#!/usr/bin/env bash
# fm-goal-digest.sh - recurring read-only goal digest.
#
# Usage:
#   fm-goal-digest.sh [run]
#       Collect open and newly merged pull requests, configured status
#       files and review-convergence records, then write latest.md,
#       latest.json and a timestamped copy under history/ in the output
#       directory. Prints one machine line:
#         goal-digest: changed=<yes|no> latest=<path> generated=<iso>
#   fm-goal-digest.sh install
#       Install the macOS LaunchAgent dev.firstmate.goal-digest-<cksum of
#       FM_HOME> every 1200 seconds (20 minutes).
#       The agent runs with this home's FM_HOME and the
#       installer's PATH and HOME.
#       Without launchctl, only the plist is written; no job is scheduled.
#       A failed launchctl bootstrap returns nonzero and leaves the plist.
#   fm-goal-digest.sh uninstall
#       Remove that LaunchAgent.
#   fm-goal-digest.sh --help
#
# Configuration lives in the gitignored $FM_HOME/config/goal-digest (or
# config/goal-digest under the code root when FM_HOME is unset). The file
# is never read from tracked content and no repository, host or person
# name is baked into this script. Format, one entry per line:
#   repo = <owner>/<name>
#   status = <label> | <local-path or ssh:<host>:<absolute-path>>
#   review = <label> | <local-path or ssh:<host>:<absolute-path>>
#   stall_hours = <n>               (default 48)
#   timeout_seconds = <n>           (per gh/ssh call, default 60)
#   summarize = <on|off>            (default on; other values warn and disable)
#   summarize_model = <model>       (default haiku; supported models below)
#   output_dir = <absolute-path>    (default $FM_HOME/data/goal-digest)
# Blank lines and lines starting with # are ignored.
#
# The digest lists new merges (URL and 12-character SHA). The first fetch
# for each repository reports only merges from the preceding day. That
# initial window is persisted in .state/pending-since.tsv before
# collection, so a failed first publication retries against the same
# baseline instead of a later clock. Later
# complete fetches advance its merge-window watermark with a five-minute
# overlap. Closed-pull collection follows every page through the
# watermark or the final page, with no page-count cap, and duplicate
# closed pulls are reported once.
# Failed collection is reported as incomplete and
# retains the pending window, including the initial one-day baseline.
# Already reported merges are excluded. It also lists open pull requests
# (drafts included) with their age, missed ETAs (every past YYYY-MM-DD
# date on a status line with the word "eta" followed by ":" or space;
# fm-fleet-snapshot.v1 JSON status files are structured data and are
# not raw-grepped for ETAs), stalled status sources (local or remote files whose
# modification age is at least stall_hours) and every nonblank entry of each review
# record. Generation and ETA dates use America/Mexico_City.
# waiting_on_captain contains captain_actionable local backlog rows and
# explicit captain-hold decisions from trusted, registered secondmates in
# configured fm-fleet-snapshot.v1 status files. A UTC hold_set timestamp
# produces age_hours with age_precision=hour. A YYYY-MM-DD hold_set
# produces age_days with age_precision=day, recalculated against the
# current America/Mexico_City date even when the snapshot is unchanged.
# Secondmate captain-hold rows carry no hold_set; their snapshot
# hold_age_days (an integer day count computed by the snapshot producer)
# is used as age_days with age_precision=day and no wait start.
# The unused age field is null; missing or invalid hold values leave
# both age fields null and age_precision=unknown.
# Other formats, unavailable sources,
# and incomplete or cached secondmate coverage leave owner-action coverage unknown.
# Open pull requests are published separately in open_pull_requests.
# Unreachable or unreadable sources are recorded in the digest
# and skipped; the run still succeeds.
#
# changed is yes on the first run, when new merges are found, or when
# persistent digest content changes. Generated time, age values and the
# disappearance of previously reported merges do not count as changes.
# On a changed run the summary is attempted by one fixed text-only model
# runner: claude -p with no tools, the current native account and a
# pinned cheap model: haiku maps to claude-haiku-4-5, sonnet to
# claude-sonnet-4-5, and claude-haiku-*/claude-sonnet-* pass as named.
# ANTHROPIC_MODEL and ANTHROPIC_DEFAULT_*_MODEL overrides are unset for
# the call so an alias cannot be remapped to an expensive model.
# It replaces summary.txt only on successful output containing
# non-whitespace and has a 120-second timeout.
# An unsupported model or a missing, failed or empty-output runner
# reports summary unavailable on stderr;
# the digest remains published, the run still succeeds, and any previous
# summary.txt is retained. Unchanged runs do not retry a failed summary.
# No shell command from config is ever executed. The
# collector never merges, deploys, tags, pushes or messages anyone: its
# network reads use `gh api` GET requests and read-only ssh cat/stat
# commands.
#
# Each latest document is published through atomic replacement after
# both history copies succeed. History archive names are never reused:
# a same-second run archives both copies under one free suffix instead
# of overwriting. Notification state advances only after
# publication succeeds. History is retained without automatic pruning.
#
# State under the output directory: .state/seen.tsv holds merged pull
# requests already collected, .state/since.tsv holds each repository's
# merge-window watermark, .state/pending-since.tsv holds an unpublished
# initial window, .state/content.hash holds the previous
# content hash, and .state/run.flock is the run lock: a run that finds
# another run holding it prints a skip line and exits 1. The kernel lock
# is released when its holder exits, so a crashed run never leaves it
# held; children that may outlive the run close fd 9 so they cannot keep
# it held. FM_GOAL_DIGEST_GH and FM_GOAL_DIGEST_CLAUDE replace the gh
# and claude binaries only when FM_TEST_SEAM is nonempty.
set -u

INTERVAL_SECONDS=1200
STALL_DEFAULT=48
LABEL=dev.firstmate.goal-digest

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

script_dir=$(cd "$(dirname "$0")" && pwd -P)
code_root=$(cd "$script_dir/.." && pwd -P)
fm_home=${FM_HOME:-$code_root}
fm_home=$(cd "$fm_home" 2>/dev/null && pwd -P || printf '%s' "$fm_home")
config_file=$fm_home/config/goal-digest

gh_bin=gh
if [ -n "${FM_TEST_SEAM:-}" ] && [ -n "${FM_GOAL_DIGEST_GH:-}" ]; then
  gh_bin=$FM_GOAL_DIGEST_GH
elif command -v gh >/dev/null 2>&1; then
  gh_bin=gh
fi

repos=()
status_labels=(); status_locs=()
review_labels=(); review_locs=()
stall_hours=$STALL_DEFAULT
summarize=on
summarize_model=haiku
claude_bin=claude
if [ -n "${FM_TEST_SEAM:-}" ] && [ -n "${FM_GOAL_DIGEST_CLAUDE:-}" ]; then
  claude_bin=$FM_GOAL_DIGEST_CLAUDE
fi
output_dir=
timeout_seconds=60

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# gd_sha256_stdin - hex digest of stdin on either digest tool.
gd_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  fi
}

load_config() {
  local line key value label loc
  [ -f "$config_file" ] && while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "$line")
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    case "$key" in
      repo) [ -n "$value" ] && repos+=("$value") ;;
      status|review)
        label=$(trim "${value%%|*}")
        loc=$(trim "${value#*|}")
        if [ "$key" = status ]; then
          status_labels+=("$label"); status_locs+=("$loc")
        else
          review_labels+=("$label"); review_locs+=("$loc")
        fi
        ;;
      stall_hours) case "$value" in ''|*[!0-9]*) ;; *) stall_hours=$value ;; esac ;;
      summarize)
        case "$value" in
          [Oo][Nn]) summarize=on ;;
          [Oo][Ff][Ff]) summarize=off ;;
          *)
            printf '%s\n' "goal-digest: summarize='$value' is not on or off; treating as off" >&2
            summarize=off
            ;;
        esac
        ;;
      summarize_model) summarize_model=$value ;;
      output_dir) output_dir=$value ;;
      timeout_seconds) case "$value" in ''|*[!0-9]*) ;; *) timeout_seconds=$value ;; esac ;;
    esac
  done < "$config_file"
  if [ -z "$output_dir" ]; then
    output_dir=$fm_home/data/goal-digest
  fi
}

# timed <seconds> <cmd...>: run with a wall-clock limit so a stalled
# network or summarizer call cannot hold the run forever.
timed() {
  local seconds=$1
  shift
  # Close the lock on the external command, not on this shell function:
  # Bash saves function redirections in an inheritable duplicate fd.
  FM_GD_TIMEOUT=$seconds python3 -c '
import os, signal, subprocess, sys
proc = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    raise SystemExit(proc.wait(timeout=int(os.environ["FM_GD_TIMEOUT"])))
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    raise SystemExit(124)
' "$@" 9>&-
}

shell_quote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# fetch_pulls <repo> <state-query> <out-json>: paginate at 100 per page,
# combining pages through FM_GD_STOP_BEFORE or the final page into one
# JSON array. Returns 0 on success or nonzero on failure.
# A failed page discards partial results.
fetch_pulls() {
  local repo=$1 query=$2 out=$3 page=1 page_file count
  : > "$work/pages.txt"
  while true; do
    page_file=$work/page-$page.json
    if ! timed "$timeout_seconds" "$gh_bin" api "repos/$repo/pulls?$query&per_page=100&page=$page" > "$page_file" 2>/dev/null; then
      return 1
    fi
    if ! count=$(python3 -c 'import json,sys
data=json.load(open(sys.argv[1]))
if not isinstance(data,list): sys.exit(1)
print(len(data))' "$page_file" 2>/dev/null); then
      return 1
    fi
    printf '%s\n' "$page_file" >> "$work/pages.txt"
    if [ "$count" -lt 100 ]; then
      break
    fi
    if [ -n "${FM_GD_STOP_BEFORE:-}" ]; then
      local oldest
      oldest=$(FM_GD_PAGE="$page_file" python3 -c '
import datetime, json, os
pulls = json.load(open(os.environ["FM_GD_PAGE"]))
stamps = []
for pr in pulls:
    for key in ("updated_at", "merged_at", "created_at"):
        try:
            stamps.append(datetime.datetime.strptime(pr[key], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
            break
        except (KeyError, TypeError, ValueError):
            continue
print(int(min(stamps)) if stamps else 0)
' 2>/dev/null || printf '0')
      if [ "$oldest" != 0 ] && [ "$oldest" -le "$FM_GD_STOP_BEFORE" ]; then
        break
      fi
    fi
    page=$((page + 1))
  done
  python3 - "$out" <<'PY'
import json, os, sys
pages = []
with open(os.path.join(os.path.dirname(sys.argv[1]), "pages.txt")) as fh:
    pages = [line.strip() for line in fh if line.strip()]
pulls = []
for page in pages:
    with open(page) as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        sys.exit(1)
    pulls.extend(data)
with open(sys.argv[1], "w") as fh:
    json.dump(pulls, fh)
PY
}

# read_source <location> <content-out> <mtime-out> [want-mtime:1]: 0 ok, 1 unreachable.
read_source() {
  local loc=$1 content_out=$2 mtime_out=$3 want_mtime=${4:-1} host path
  : > "$content_out"
  printf '' > "$mtime_out"
  case "$loc" in
    ssh:*)
      host=${loc#ssh:}
      path=${host#*:}
      host=${host%%:*}
      [ -n "$host" ] && [ "$path" != "$host" ] || return 1
      local quoted
      quoted=$(shell_quote "$path")
      timed "$timeout_seconds" ssh -n -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "cat -- $quoted" > "$content_out" 2>/dev/null || return 1
      if [ "$want_mtime" = 1 ]; then
        timed "$timeout_seconds" ssh -n -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "stat -c %Y -- $quoted 2>/dev/null || stat -f %m -- $quoted" > "$mtime_out" 2>/dev/null || printf '' > "$mtime_out"
      fi
      return 0
      ;;
    *)
      [ -f "$loc" ] && [ -r "$loc" ] || return 1
      cat "$loc" > "$content_out" 2>/dev/null || return 1
      if [ "$want_mtime" = 1 ]; then
        stat -c %Y "$loc" > "$mtime_out" 2>/dev/null || stat -f %m "$loc" > "$mtime_out" 2>/dev/null || printf '' > "$mtime_out"
      fi
      return 0
      ;;
  esac
}

collect_waiting() {
  local label=$1 content=$2
  local rc=0
  python3 - "$content" "$label" "$now_epoch" "$work/waiting-unknown.tsv" >> "$work/waiting.tsv" <<'PY' || rc=$?
import datetime, json, sys
try:
    data = json.load(open(sys.argv[1]))
except (ValueError, OSError):
    sys.exit(2)
if not isinstance(data, dict) or data.get("schema") != "fm-fleet-snapshot.v1":
    sys.exit(2)
def clean(value):
    return str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ")
def unknown(source, detail):
    with open(sys.argv[4], "a") as fh:
        fh.write(clean(source) + "\t" + clean(detail) + "\n")
rows_out = []
def emit(source, row, title):
    if not isinstance(row, dict) or not isinstance(row.get("id"), (str, int)):
        unknown(source, "owner-action record malformed")
        return
    stamp = row.get("hold_set") or ""
    if not isinstance(stamp, str):
        stamp = ""
    age = "unknown"
    age_days = ""
    precision = "unknown"
    try:
        held = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        age = str(max(0, int((int(sys.argv[3]) - held.timestamp()) // 3600)))
        precision = "hour"
    except (ValueError, TypeError):
        try:
            held_date = datetime.datetime.strptime(stamp, "%Y-%m-%d").date()
            try:
                from zoneinfo import ZoneInfo
                tz = ZoneInfo("America/Mexico_City")
            except Exception:
                tz = datetime.timezone(datetime.timedelta(hours=-6))
            today = datetime.datetime.fromtimestamp(int(sys.argv[3]), tz).date()
            age_days = str(max(0, (today - held_date).days))
            precision = "day"
        except (ValueError, TypeError):
            hold_days = row.get("hold_age_days")
            if isinstance(hold_days, int) and not isinstance(hold_days, bool) and hold_days >= 0:
                age_days = str(hold_days)
                precision = "day"
    values = [source, row["id"], title if isinstance(title, str) else "", row.get("pr_url") if isinstance(row.get("pr_url"), str) else "", stamp, age, age_days, precision]
    rows_out.append("\t".join(clean(v) for v in values))
label = sys.argv[2]
backlog = data.get("backlog") or {}
if not isinstance(backlog, dict):
    backlog = {}
if backlog.get("present") is True and isinstance(backlog.get("records"), list):
    for row in backlog["records"]:
        if isinstance(row, dict) and row.get("captain_actionable") is True:
            emit(label, row, row.get("title", ""))
else:
    unknown(label, "local backlog unavailable")
secondmates = data.get("secondmate_current") or {}
if not isinstance(secondmates, dict):
    secondmates = {}
registry = secondmates.get("registry") or {}
if not isinstance(registry, dict):
    registry = {}
if registry.get("available") is not True or registry.get("complete") is not True:
    unknown(label, "secondmate registry unavailable or incomplete")
if secondmates.get("truncated", 0):
    unknown(label, "secondmate records truncated")
if not isinstance(secondmates.get("records"), list):
    unknown(label, "secondmate records unavailable")
else:
    for mate in secondmates["records"]:
        if not isinstance(mate, dict) or mate.get("registered") is not True:
            continue
        if not isinstance(mate.get("id"), (str, int)):
            unknown(label, "secondmate record malformed")
            continue
        source = label + "/" + str(mate["id"])
        provenance = mate.get("provenance") or {}
        if not isinstance(provenance, dict):
            provenance = {}
        if provenance.get("selected") != "structured-home" or provenance.get("trust") not in ("complete", "partial-structured"):
            unknown(source, "secondmate owner-action records unavailable")
            continue
        freshness = mate.get("freshness") if isinstance(mate.get("freshness"), dict) else {}
        if freshness.get("status") == "cached" or provenance.get("summary_source") == "remote-ledger-cache":
            unknown(source, "secondmate decisions from cached ledger")
        decisions = mate.get("decisions_open")
        if not isinstance(decisions, list):
            unknown(source, "secondmate decisions unavailable")
            continue
        current = mate.get("current") if isinstance(mate.get("current"), dict) else {}
        counts = mate.get("counts") if isinstance(mate.get("counts"), dict) else {}
        omitted = mate.get("omitted") if isinstance(mate.get("omitted"), list) else []
        if mate.get("omitted") is not None and not isinstance(mate.get("omitted"), list):
            unknown(source, "secondmate decision coverage incomplete")
        if (provenance.get("trust") != "complete"
                or current.get("state") == "unknown"
                or (counts.get("decisions_open", len(decisions)) if isinstance(counts.get("decisions_open", len(decisions)), int) else len(decisions) + 1) > len(decisions)
                or any(isinstance(r, dict) and r.get("surface") == "decisions_open" and isinstance(r.get("count", 0), int) and r.get("count", 0) > 0 for r in omitted)):
            unknown(source, "secondmate decision coverage incomplete")
        for row in decisions:
            if isinstance(row, dict) and row.get("verb") == "captain-hold":
                emit(source, row, row.get("question") or row.get("summary", ""))
for line in rows_out:
    print(line)
PY
  [ "$rc" = 0 ] && return 0
  printf '%s\t%s\n' "$label" 'native owner-action records unavailable' >> "$work/waiting-unknown.tsv"
}

do_run() {
  load_config
  mkdir -p "$output_dir/history" "$output_dir/.state" || return 1
  local lock_file=$output_dir/.state/run.flock
  exec 9>>"$lock_file" || return 1
  local lock_rc=0
  python3 -c 'import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(75)' || lock_rc=$?
  if [ "$lock_rc" = 75 ]; then
    printf 'goal-digest: another run is in progress; skipping (lock %s)\n' "$lock_file" >&2
    return 1
  elif [ "$lock_rc" != 0 ]; then
    printf 'goal-digest: could not take the run lock %s (python3 exit %s)\n' "$lock_file" "$lock_rc" >&2
    return 1
  fi
  local seen_file=$output_dir/.state/seen.tsv
  local hash_file=$output_dir/.state/content.hash
  local since_file=$output_dir/.state/since.tsv
  local pending_since_file=$output_dir/.state/pending-since.tsv
  [ -f "$seen_file" ] || : > "$seen_file"
  [ -f "$since_file" ] || : > "$since_file"
  [ -f "$pending_since_file" ] || : > "$pending_since_file"
  local work
  work=$(mktemp -d "$output_dir/.state/run.XXXXXX") || return 1
  GD_CLEANUP_WORK=$work
  trap 'rm -rf "$GD_CLEANUP_WORK"' EXIT
  : > "$work/new_merges.tsv"
  : > "$work/seen-new.tsv"
  : > "$work/since-new.tsv"
  : > "$work/waiting.tsv"
  : > "$work/open.tsv"
  : > "$work/waiting-unknown.tsv"
  : > "$work/missed.tsv"
  : > "$work/stalled.tsv"
  : > "$work/reviews.tsv"
  : > "$work/unreachable.tsv"

  local now_epoch now_iso now_cst today
  now_epoch=$(date +%s)
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  now_cst=$(TZ=America/Mexico_City date '+%Y-%m-%dT%H:%M:%S%z %Z')
  today=$(TZ=America/Mexico_City date +%Y-%m-%d)

  local repo json_file i label loc content mtime_file age_hours line
  for repo in "${repos[@]:-}"; do
    [ -n "$repo" ] || continue
    json_file=$work/prs.json
    local stop_before
    stop_before=$(awk -F '\t' -v r="$repo" '$1 == r { print $2 }' "$since_file" 2>/dev/null || true)
    if [ -z "$stop_before" ]; then
      stop_before=$(awk -F '\t' -v r="$repo" '$1 == r { print $2 }' "$pending_since_file" 2>/dev/null || true)
    fi
    if [ -z "$stop_before" ]; then
      stop_before=$((now_epoch - 86400))
      # Persist the initial window before collecting so a failed first
      # publication retries against the same baseline, not a later clock.
      printf '%s\t%s\n' "$repo" "$stop_before" >> "$pending_since_file"
      printf '%s\t%s\n' "$repo" "$stop_before" >> "$work/since-new.tsv"
    fi
    if ! FM_GD_STOP_BEFORE="$stop_before" fetch_pulls "$repo" "state=closed&sort=updated&direction=desc" "$json_file"; then
      printf '%s\t%s\t%s\n' "repo" "$repo" "gh api failed or incomplete; results not used" >> "$work/unreachable.tsv"
    else
      : > "$work/new_merges-part.tsv"
      FM_GD_REPO="$repo" FM_GD_SEEN="$seen_file" FM_GD_OUT="$work/new_merges-part.tsv" \
      FM_GD_SINCE="$since_file" FM_GD_PENDING="$pending_since_file" FM_GD_SINCE_NEW="$work/since-new.tsv" FM_GD_NOW="$now_epoch" \
      python3 - "$json_file" <<'PY'
import datetime, json, os, sys
repo = os.environ["FM_GD_REPO"]
since_path = os.environ["FM_GD_SINCE"]
since = {}
with open(since_path) as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[1].isdigit():
            since[parts[0]] = int(parts[1])
if repo not in since:
    try:
        with open(os.environ["FM_GD_PENDING"]) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[0] == repo and parts[1].isdigit():
                    # Pending holds stop_before (seed time minus one day);
                    # only merges after it are new on a retried first run.
                    since[repo] = int(parts[1])
    except OSError:
        pass
seen = set()
try:
    with open(os.environ["FM_GD_SEEN"]) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                seen.add((parts[0], parts[1]))
except OSError:
    pass
with open(sys.argv[1]) as fh:
    pulls = json.load(fh)
def clean(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")
now = int(os.environ["FM_GD_NOW"])
with open(os.environ["FM_GD_OUT"], "a") as out:
    for pr in pulls:
        if not pr.get("merged_at"):
            continue
        number = str(pr.get("number", ""))
        sha = (pr.get("merge_commit_sha") or "")[:12]
        if (repo, number) in seen:
            continue
        seen.add((repo, number))
        try:
            merged = datetime.datetime.strptime(pr["merged_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        except (TypeError, ValueError):
            continue
        if repo in since:
            if merged.timestamp() <= since[repo]:
                continue
        elif merged.timestamp() <= now - 86400:
            # First fetch for this repository: seed the baseline instead
            # of reporting every old merge in the window as new.
            continue
        out.write("\t".join([repo, number, clean(pr.get("title", "")), clean(pr.get("html_url", "")), sha, str(pr.get("merged_at", ""))]) + "\n")
with open(os.environ["FM_GD_SINCE_NEW"], "a") as fh:
    fh.write(f"{repo}\t{now - 300}\n")
PY
      local parse_rc=$?
      if [ "$parse_rc" -ne 0 ]; then
        printf '%s\t%s\t%s\n' "repo" "$repo" "pull parse failed" >> "$work/unreachable.tsv"
      else
        cat "$work/new_merges-part.tsv" >> "$work/new_merges.tsv"
        # Record every merged pull as seen, new or not. This is staged and
        # only committed to seen.tsv after archival and publication, so an
        # interrupted run cannot lose a merge notification.
        FM_GD_REPO="$repo" python3 - "$json_file" >> "$work/seen-new.tsv" <<'PY'
import json, os, sys
repo = os.environ["FM_GD_REPO"]
with open(sys.argv[1]) as fh:
    pulls = json.load(fh)
for pr in pulls:
    if pr.get("merged_at"):
        print("\t".join([repo, str(pr.get("number", "")), (pr.get("merge_commit_sha") or "")[:12]]))
PY
      fi
    fi
    if ! FM_GD_STOP_BEFORE='' fetch_pulls "$repo" "state=open&sort=created&direction=asc" "$json_file"; then
      printf '%s\t%s\t%s\n' "repo-open" "$repo" "gh api failed or incomplete; results not used" >> "$work/unreachable.tsv"
    else
      FM_GD_REPO="$repo" FM_GD_NOW="$now_epoch" python3 - "$json_file" > "$work/open-part.tsv" <<'PY'
import datetime, json, os, sys
repo = os.environ["FM_GD_REPO"]
now = int(os.environ["FM_GD_NOW"])
with open(sys.argv[1]) as fh:
    pulls = json.load(fh)
if not isinstance(pulls, list):
    sys.exit(1)
for pr in pulls:
    if not isinstance(pr, dict):
        sys.exit(1)
    created = pr.get("created_at") or ""
    if not isinstance(created, str):
        created = ""
    age = ""
    try:
        ts = datetime.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        age = str(max(0, int((now - ts.timestamp()) // 3600)))
    except (ValueError, TypeError):
        pass
    user = (pr.get("user") or {}).get("login", "") if isinstance(pr.get("user"), dict) else ""
    clean = lambda v: str(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    print("\t".join([repo, str(pr.get("number", "")), clean(pr.get("title", "")), clean(pr.get("html_url", "")), created, age, clean(user), "yes" if pr.get("draft") else "no"]))
PY
      local open_rc=$?
      if [ "$open_rc" -ne 0 ]; then
        printf '%s\t%s\t%s\n' "repo-open" "$repo" "pull parse failed" >> "$work/unreachable.tsv"
      else
        cat "$work/open-part.tsv" >> "$work/open.tsv"
      fi
    fi
  done

  local eta_pattern='(^|[^[:alnum:]_])eta[: ]+[0-9]{4}-[0-9]{2}-[0-9]{2}'
  for i in "${status_labels[@]+"${!status_labels[@]}"}"; do
    label=${status_labels[$i]}; loc=${status_locs[$i]}
    content=$work/status-content; mtime_file=$work/status-mtime
    if ! read_source "$loc" "$content" "$mtime_file"; then
      printf '%s\t%s\t%s\n' "status" "$label" "$loc" >> "$work/unreachable.tsv"
      printf '%s\t%s\n' "$label" 'source unreachable' >> "$work/waiting-unknown.tsv"
      continue
    fi
    collect_waiting "$label" "$content"
    # fm-fleet-snapshot.v1 JSON is structured data, not ETA prose: raw
    # line-grepping it matches Done rows and volatile fields. Skip it.
    if ! grep -q '"schema"[[:space:]]*:[[:space:]]*"fm-fleet-snapshot\.v1"' "$content" 2>/dev/null; then
      while IFS= read -r eta_line; do
        while IFS= read -r eta_date; do
          [ -n "$eta_date" ] || continue
          if [ "$eta_date" \< "$today" ]; then
            printf '%s\t%s\t%s\n' "$label" "$eta_date" "$(trim "$eta_line" | tr '\t' ' ')" >> "$work/missed.tsv"
          fi
        done <<ETA_EOF
$(printf '%s' "$eta_line" | grep -oiE "$eta_pattern" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)
ETA_EOF
      done <<EOF
$(grep -iE "$eta_pattern" "$content" 2>/dev/null || true)
EOF
    fi
    local mtime
    mtime=$(cat "$mtime_file")
    case "$mtime" in ''|*[!0-9]*) mtime= ;; esac
    if [ -n "$mtime" ]; then
      age_hours=$(( (now_epoch - mtime) / 3600 ))
      if [ "$age_hours" -ge "$stall_hours" ]; then
        printf '%s\t%s\n' "$label" "$age_hours" >> "$work/stalled.tsv"
      fi
    fi
  done

  for i in "${review_labels[@]+"${!review_labels[@]}"}"; do
    label=${review_labels[$i]}; loc=${review_locs[$i]}
    content=$work/review-content; mtime_file=$work/review-mtime
    if ! read_source "$loc" "$content" "$mtime_file" 0; then
      printf '%s\t%s\t%s\n' "review" "$label" "$loc" >> "$work/unreachable.tsv"
      continue
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$(trim "$line")" ] || continue
      printf '%s\t%s\n' "$label" "${line//$'\t'/ }" >> "$work/reviews.tsv"
    done < "$content"
  done
  if [ "${#status_labels[@]}" = 0 ]; then
    printf '%s\t%s\n' 'owner actions' 'no sources configured' >> "$work/waiting-unknown.tsv"
  fi

  # The persistent-content hash excludes the generated time, the age
  # columns that grow every hour, and the transient new-merges list (a
  # merge reported once would otherwise flip the next run back to changed
  # when it drops off that list).
  local content_hash changed
  content_hash=$(set -o pipefail; { cut -f1-5,7,8 "$work/open.tsv"; cut -f1-5 "$work/waiting.tsv"; cat "$work/waiting-unknown.tsv" "$work/missed.tsv"; cut -f1 "$work/stalled.tsv"; cat "$work/reviews.tsv" "$work/unreachable.tsv"; } | gd_sha256_stdin) || content_hash=
  if [ -z "$content_hash" ]; then
    printf '%s\n' "goal-digest: content hash failed; shasum or sha256sum is required" >&2
    return 1
  fi
  changed=no
  if [ -s "$work/new_merges.tsv" ] || [ ! -f "$hash_file" ] || [ "$(cat "$hash_file")" != "$content_hash" ]; then
    changed=yes
  fi
  FM_GD_WORK="$work" FM_GD_NOW_ISO="$now_iso" FM_GD_NOW_CST="$now_cst" FM_GD_CHANGED="$changed" \
  FM_GD_OUTPUT="$output_dir" \
  python3 - <<'PY'
import datetime, json, os, secrets
work = os.environ["FM_GD_WORK"]
def rows(name):
    path = os.path.join(work, name)
    out = []
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if any(parts):
                    out.append(parts)
    return out
new_merges = [{"repo": r[0], "number": int(r[1]) if len(r) > 1 and r[1].isdigit() else r[1] if len(r) > 1 else "", "title": r[2] if len(r) > 2 else "", "url": r[3] if len(r) > 3 else "", "sha": r[4] if len(r) > 4 else "", "merged_at": r[5] if len(r) > 5 else ""} for r in rows("new_merges.tsv")]
open_prs = [{"repo": r[0], "number": int(r[1]) if len(r) > 1 and r[1].isdigit() else r[1] if len(r) > 1 else "", "title": r[2] if len(r) > 2 else "", "url": r[3] if len(r) > 3 else "", "created_at": r[4] if len(r) > 4 else "", "age_hours": int(r[5]) if len(r) > 5 and r[5].isdigit() else None, "author": r[6] if len(r) > 6 else "", "draft": (r[7] == "yes") if len(r) > 7 else False} for r in rows("open.tsv")]
waiting = [{"source": r[0], "id": r[1], "title": r[2], "url": r[3], "wait_started_at": r[4] or None, "age_hours": int(r[5]) if r[5].isdigit() else None, "age_days": int(r[6]) if len(r) > 6 and r[6].isdigit() else None, "age_precision": r[7] if len(r) > 7 else "unknown"} for r in rows("waiting.tsv")]
waiting_unknown = [{"source": r[0], "detail": r[1]} for r in rows("waiting-unknown.tsv")]
missed = [{"source": r[0], "eta": r[1] if len(r) > 1 else "", "line": r[2] if len(r) > 2 else ""} for r in rows("missed.tsv")]
stalled = [{"source": r[0], "age_hours": int(r[1]) if len(r) > 1 and r[1].lstrip("-").isdigit() else None} for r in rows("stalled.tsv")]
reviews = []
for row in rows("reviews.tsv"):
    if not reviews or reviews[-1]["source"] != row[0]:
        reviews.append({"source": row[0], "entries": []})
    reviews[-1]["entries"].append(row[1] if len(row) > 1 else "")
unreachable = [{"kind": r[0], "source": r[1] if len(r) > 1 else "", "detail": r[2] if len(r) > 2 else ""} for r in rows("unreachable.tsv")]
digest = {
    "generated_at": os.environ["FM_GD_NOW_ISO"],
    "generated_at_local": os.environ["FM_GD_NOW_CST"],
    "changed": os.environ["FM_GD_CHANGED"] == "yes",
    "new_merges": new_merges,
    "open_pull_requests": open_prs,
    "waiting_on_captain": waiting,
    "waiting_on_captain_status": "unknown" if waiting_unknown else "known",
    "waiting_on_captain_unknown_sources": waiting_unknown,
    "missed_etas": missed,
    "stalls": stalled,
    "review_convergence": reviews,
    "unreachable_sources": unreachable,
}
output = os.environ["FM_GD_OUTPUT"]
json_tmp = os.path.join(output, "latest.json.tmp")
md_tmp = os.path.join(output, "latest.md.tmp")
with open(json_tmp, "w") as fh:
    json.dump(digest, fh, indent=2)
    fh.write("\n")
lines = ["# Goal digest", "", f"Generated: {digest['generated_at_local']} / {digest['generated_at']}", f"Changed: {'yes' if digest['changed'] else 'no'}", "", "## New merges since last run", ""]
if new_merges:
    lines += [f"- [{m['repo']} #{m['number']} {m['title']}]({m['url']}) `{m['sha']}` {m['merged_at']}" for m in new_merges]
else:
    lines.append("- None")
lines += ["", "## Open pull requests", ""]
if open_prs:
    lines += [f"- [{w['repo']} #{w['number']} {w['title']}]({w['url']}) age_hours={w['age_hours']} author={w['author']} draft={'yes' if w['draft'] else 'no'}" for w in open_prs]
else:
    lines.append("- None")
lines += ["", "## Waiting on owner", ""]
lines += [f"- {w['source']} {w['id']}: {w['title']} age_hours={w['age_hours']}" if w['age_hours'] is not None else (f"- {w['source']} {w['id']}: {w['title']} age_days={w['age_days']} (day precision)" if w['age_days'] is not None else f"- {w['source']} {w['id']}: {w['title']} age_hours=unknown") for w in waiting] or ["- None known" if waiting_unknown else "- None"]
lines += [f"- Unknown: {u['source']}: {u['detail']}" for u in waiting_unknown]
lines += ["", "## Missed ETAs", ""]
lines += [f"- {m['source']}: eta {m['eta']} - {m['line']}" for m in missed] or ["- None"]
lines += ["", "## Stalls", ""]
lines += [f"- {s['source']}: no update for {s['age_hours']}h" for s in stalled] or ["- None"]
lines += ["", "## Review convergence", ""]
lines += [f"- {r['source']}: {entry}" for r in reviews for entry in r["entries"]] or ["- None"]
lines += ["", "## Unreachable sources", ""]
lines += [f"- {u['kind']} {u['source']}: {u['detail']}" for u in unreachable] or ["- None"]
lines.append("")
with open(md_tmp, "w") as fh:
    fh.write("\n".join(lines))
stamp = datetime.datetime.strptime(os.environ["FM_GD_NOW_ISO"], "%Y-%m-%dT%H:%M:%SZ").strftime("%Y%m%dT%H%M%SZ")
history_dir = os.path.join(output, "history")
n = 0
while True:
    stem = stamp if n == 0 else f"{stamp}-{n}"
    md_archive = os.path.join(history_dir, stem + ".md")
    json_archive = os.path.join(history_dir, stem + ".json")
    if not os.path.lexists(md_archive) and not os.path.lexists(json_archive):
        break
    n += 1

def stage(source):
    tmp = os.path.join(history_dir, ".history-" + secrets.token_hex(16) + ".tmp")
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o666)
    try:
        with os.fdopen(fd, "wb") as out, open(source, "rb") as inp:
            out.write(inp.read())
    except Exception:
        os.unlink(tmp)
        raise
    return tmp

md_staged = stage(md_tmp)
try:
    json_staged = stage(json_tmp)
except Exception:
    os.unlink(md_staged)
    raise
os.replace(md_staged, md_archive)
os.replace(json_staged, json_archive)
os.replace(json_tmp, os.path.join(output, "latest.json"))
os.replace(md_tmp, os.path.join(output, "latest.md"))
PY
  local digest_rc=$?
  if [ "$digest_rc" -ne 0 ]; then
    printf '%s\n' "goal-digest: digest generation failed; state not advanced" >&2
    return 1
  fi

  local seen_tmp
  seen_tmp=$(mktemp "$output_dir/.state/seen.XXXXXX") || return 1
  cat "$seen_file" "$work/seen-new.tsv" > "$seen_tmp" || return 1
  sort -u "$seen_tmp" -o "$seen_tmp" || return 1
  mv "$seen_tmp" "$seen_file" || return 1
  FM_GD_SINCE="$since_file" FM_GD_SINCE_NEW="$work/since-new.tsv" python3 - <<'PY' || return 1
import os
since = {}
try:
    with open(os.environ["FM_GD_SINCE"]) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                since[parts[0]] = parts[1]
except OSError:
    pass
with open(os.environ["FM_GD_SINCE_NEW"]) as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            since[parts[0]] = parts[1]
tmp = os.environ["FM_GD_SINCE"] + ".tmp"
with open(tmp, "w") as fh:
    for key in sorted(since):
        fh.write(f"{key}\t{since[key]}\n")
os.replace(tmp, os.environ["FM_GD_SINCE"])
PY
  # Pending initial windows are consumed once the real watermark exists.
  FM_GD_SINCE="$since_file" FM_GD_PENDING="$pending_since_file" python3 - <<'PY' || return 1
import os
since = set()
try:
    with open(os.environ["FM_GD_SINCE"]) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                since.add(parts[0])
except OSError:
    pass
pending_path = os.environ["FM_GD_PENDING"]
kept = []
try:
    with open(pending_path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] not in since:
                kept.append(line if line.endswith("\n") else line + "\n")
except OSError:
    pass
tmp = pending_path + ".tmp"
with open(tmp, "w") as fh:
    fh.writelines(kept)
os.replace(tmp, pending_path)
PY

  printf '%s\n' "$content_hash" > "$hash_file.tmp" && mv "$hash_file.tmp" "$hash_file" || return 1

  if [ "$changed" = yes ] && [ "$summarize" != off ]; then
    # Fixed text-only model runner: fixed argv, no tools, the current
    # native claude account, a cheap non-Opus model. No shell command
    # from config is ever executed.
    # Poll Claude's optional file watchers: native FSEvents registration
    # can stall startup long enough to exhaust the model-call deadline.
    local pinned_model=
    case "$summarize_model" in
      haiku) pinned_model=claude-haiku-4-5 ;;
      sonnet) pinned_model=claude-sonnet-4-5 ;;
      claude-haiku-*|claude-sonnet-*) pinned_model=$summarize_model ;;
    esac
    case "$pinned_model" in
      claude-haiku-*|claude-sonnet-*)
        if ! command -v "$claude_bin" >/dev/null 2>&1; then
          printf '%s\n' "goal-digest: summary unavailable: claude runner not found" >&2
        elif { printf '%s\n' "Summarize this goal digest for its owner in at most 12 short lines: new merges, items waiting, missed ETAs, stalls and anything blocked. Use only the input below."; cat "$output_dir/latest.md"; } > "$work/summary-prompt.txt" &&
           ( unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; CHOKIDAR_USEPOLLING=1 timed 120 "$claude_bin" -p --model "$pinned_model" --tools "" --setting-sources "" --strict-mcp-config --no-session-persistence < "$work/summary-prompt.txt" > "$work/summary.txt" 2>/dev/null ) 9>&- &&
           grep -q '[^[:space:]]' "$work/summary.txt" &&
           mv "$work/summary.txt" "$output_dir/summary.txt"; then
          :
        else
          rm -f "$work/summary.txt"
          printf '%s\n' "goal-digest: summary unavailable: model runner failed; digest still written" >&2
        fi
        ;;
      *)
        printf '%s\n' "goal-digest: summary unavailable: summarize_model '$summarize_model' is not a supported cheap model" >&2
        ;;
    esac
  fi

  trap - EXIT
  rm -rf "$work"
  printf 'goal-digest: changed=%s latest=%s generated=%s\n' "$changed" "$output_dir/latest.md" "$now_iso"
}

agent_label() {
  local sum
  read -r sum _ <<EOF
$(printf '%s' "$fm_home" | cksum)
EOF
  printf '%s-%s' "$LABEL" "$sum"
}

plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(agent_label)"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

do_install() {
  load_config
  local plist dir label
  label=$(agent_label)
  plist=$(plist_path)
  dir=$(dirname "$plist")
  mkdir -p "$dir" "$output_dir" || return 1
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$code_root/bin/fm-goal-digest.sh")</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$(xml_escape "$fm_home")</string>
    <key>PATH</key>
    <string>$(xml_escape "$PATH")</string>
    <key>HOME</key>
    <string>$(xml_escape "$HOME")</string>
  </dict>
  <key>StartInterval</key>
  <integer>$INTERVAL_SECONDS</integer>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$output_dir/launchd.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$output_dir/launchd.log")</string>
</dict>
</plist>
EOF
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    if ! launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
      printf '%s\n' "goal-digest: launchctl bootstrap failed; plist written at $plist but the job is not scheduled" >&2
      return 1
    fi
  fi
  printf 'goal-digest: installed=%s interval_seconds=%s\n' "$plist" "$INTERVAL_SECONDS"
}

do_uninstall() {
  local plist
  plist=$(plist_path)
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$(agent_label)" >/dev/null 2>&1 || true
  fi
  rm -f "$plist"
  printf 'goal-digest: uninstalled=%s\n' "$plist"
}

case "${1:-run}" in
  run) [ $# -le 1 ] || { echo "usage: fm-goal-digest.sh [run|install|uninstall|--help]" >&2; exit 2; }; do_run ;;
  install) [ $# -le 1 ] || { echo "usage: fm-goal-digest.sh [run|install|uninstall|--help]" >&2; exit 2; }; do_install ;;
  uninstall) [ $# -le 1 ] || { echo "usage: fm-goal-digest.sh [run|install|uninstall|--help]" >&2; exit 2; }; do_uninstall ;;
  --help|-h|help) usage ;;
  *) echo "usage: fm-goal-digest.sh [run|install|uninstall|--help]" >&2; exit 2 ;;
esac
