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
#   summarize_cmd = <command>       (optional, run only when changed)
#   output_dir = <absolute-path>    (default $FM_HOME/data/goal-digest)
# Blank lines and lines starting with # are ignored.
#
# The digest lists new merges (URL and 12-character SHA). The first fetch
# for each repository reports only merges from the preceding day. Later
# fetches use its last successful fetch time with a five-minute overlap;
# already reported merges are excluded. It also lists open pull requests
# (drafts included) with their age, missed ETAs (a status
# line with the word "eta" followed by ":" or space and a YYYY-MM-DD date
# in the past), stalled status sources (local or remote files whose
# modification age is at least stall_hours) and every nonblank entry of each review
# record. Generation and ETA dates use America/Mexico_City.
# waiting_on_captain contains captain_actionable local backlog rows and
# explicit captain-hold decisions from trusted, registered secondmates in
# configured fm-fleet-snapshot.v1 status files. Wait age uses the native
# hold_set timestamp, otherwise null. Other formats, unavailable sources,
# and incomplete or cached secondmate coverage leave owner-action coverage unknown.
# Open pull requests are published separately in open_pull_requests.
# Unreachable or unreadable sources are recorded in the digest
# and skipped; the run still succeeds.
#
# changed is yes on the first run, when new merges are found, or when
# persistent digest content changes. Generated time, age values and the
# disappearance of previously reported merges do not count as changes.
# A configured summarize_cmd runs only on a changed run, receives
# latest.md on stdin and replaces summary.txt only on success. It has a
# 120-second timeout; failure leaves the digest published and the previous
# summary intact. The configured command is outside the collector's
# read-only guarantee. The collector never merges, deploys, tags, pushes
# or messages anyone: its network reads use `gh api` GET requests and
# read-only ssh cat/stat commands.
#
# Each latest document is published through atomic replacement after
# both history copies succeed. Notification state advances only after
# publication succeeds. History is retained without automatic pruning.
#
# State under the output directory: .state/seen.tsv holds every merged
# pull request already reported, .state/since.tsv holds each repository's
# merge-window watermark, .state/content.hash holds the previous
# content hash, and .state/run.flock is the run lock: a run that finds
# another run holding it prints a skip line and exits 1. The kernel lock
# is released when its holder exits, so a crashed run never leaves it
# held; children that may outlive the run close fd 9 so they cannot keep
# it held. FM_GOAL_DIGEST_GH replaces the gh binary only when
# FM_TEST_SEAM is nonempty.
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
summarize_cmd=
output_dir=
timeout_seconds=60

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
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
      summarize_cmd) summarize_cmd=$value ;;
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
# up to 10 pages, combining every page into one JSON array. Returns 0
# on success, including truncation at the page cap, or nonzero on failure.
# Truncation sets work/fetch-truncated; results remain usable with a note.
# A failed page discards partial results.
fetch_pulls() {
  local repo=$1 query=$2 out=$3 page=1 page_file count truncated=0
  rm -f "$work/fetch-truncated"
  : > "$work/pages.txt"
  while [ "$page" -le 10 ]; do
    page_file=$work/page-$page.json
    if ! timed "$timeout_seconds" "$gh_bin" api "repos/$repo/pulls?$query&per_page=100&page=$page" > "$page_file" 2>/dev/null; then
      return 1
    fi
    printf '%s\n' "$page_file" >> "$work/pages.txt"
    count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$page_file" 2>/dev/null || printf '0')
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
        except (KeyError, ValueError):
            continue
print(int(min(stamps)) if stamps else 0)
' 2>/dev/null || printf '0')
      if [ "$oldest" != 0 ] && [ "$oldest" -le "$FM_GD_STOP_BEFORE" ]; then
        break
      fi
    fi
    if [ "$page" -eq 10 ]; then
      truncated=1
    fi
    page=$((page + 1))
  done
  [ "$truncated" = 1 ] && printf '2' > "$work/fetch-truncated"
  true
  python3 - "$out" <<'PY'
import json, os, sys
pages = []
with open(os.path.join(os.path.dirname(sys.argv[1]), "pages.txt")) as fh:
    pages = [line.strip() for line in fh if line.strip()]
pulls = []
for page in pages:
    with open(page) as fh:
        pulls.extend(json.load(fh))
with open(sys.argv[1], "w") as fh:
    json.dump(pulls, fh)
PY
}

# read_source <location> <content-out> <mtime-out>: 0 ok, 1 unreachable.
read_source() {
  local loc=$1 content_out=$2 mtime_out=$3 host path
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
      timed "$timeout_seconds" ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "cat -- $quoted" > "$content_out" 2>/dev/null || return 1
      timed "$timeout_seconds" ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "stat -c %Y -- $quoted 2>/dev/null || stat -f %m -- $quoted" > "$mtime_out" 2>/dev/null || printf '' > "$mtime_out"
      return 0
      ;;
    *)
      [ -f "$loc" ] && [ -r "$loc" ] || return 1
      cat "$loc" > "$content_out" 2>/dev/null || return 1
      stat -c %Y "$loc" > "$mtime_out" 2>/dev/null || stat -f %m "$loc" > "$mtime_out" 2>/dev/null || printf '' > "$mtime_out"
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
def emit(source, row, title):
    stamp = row.get("hold_set") or ""
    age = "unknown"
    try:
        held = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        age = str(max(0, int((int(sys.argv[3]) - held.timestamp()) // 3600)))
    except ValueError:
        pass
    values = [source, row["id"], title, row.get("pr_url") or "", stamp, age]
    print("\t".join(clean(v) for v in values))
label = sys.argv[2]
backlog = data.get("backlog") or {}
if backlog.get("present") is True and isinstance(backlog.get("records"), list):
    for row in backlog["records"]:
        if row.get("captain_actionable") is True:
            emit(label, row, row.get("title", ""))
else:
    unknown(label, "local backlog unavailable")
secondmates = data.get("secondmate_current") or {}
registry = secondmates.get("registry") or {}
if registry.get("available") is not True or registry.get("complete") is not True:
    unknown(label, "secondmate registry unavailable or incomplete")
if secondmates.get("truncated", 0):
    unknown(label, "secondmate records truncated")
if not isinstance(secondmates.get("records"), list):
    unknown(label, "secondmate records unavailable")
else:
    for mate in secondmates["records"]:
        if mate.get("registered") is not True:
            continue
        source = label + "/" + mate["id"]
        provenance = mate.get("provenance") or {}
        if provenance.get("selected") != "structured-home" or provenance.get("trust") not in ("complete", "partial-structured"):
            unknown(source, "secondmate owner-action records unavailable")
            continue
        if (mate.get("freshness") or {}).get("status") == "cached" or provenance.get("summary_source") == "remote-ledger-cache":
            unknown(source, "secondmate decisions from cached ledger")
        decisions = mate.get("decisions_open")
        if not isinstance(decisions, list):
            unknown(source, "secondmate decisions unavailable")
            continue
        if (provenance.get("trust") != "complete"
                or (mate.get("current") or {}).get("state") == "unknown"
                or (mate.get("counts") or {}).get("decisions_open", len(decisions)) > len(decisions)
                or any(r.get("surface") == "decisions_open" and r.get("count", 0) > 0 for r in mate.get("omitted", []))):
            unknown(source, "secondmate decision coverage incomplete")
        for row in decisions:
            if row.get("verb") == "captain-hold":
                emit(source, row, row.get("question") or row.get("summary", ""))
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
  [ -f "$seen_file" ] || : > "$seen_file"
  [ -f "$since_file" ] || : > "$since_file"
  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-goal-digest.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
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
    if ! FM_GD_STOP_BEFORE="$stop_before" fetch_pulls "$repo" "state=closed&sort=updated&direction=desc" "$json_file"; then
      printf '%s\t%s\t%s\n' "repo" "$repo" "gh api failed or incomplete; results not used" >> "$work/unreachable.tsv"
    else
      [ -f "$work/fetch-truncated" ] && printf '%s\t%s\t%s\n' "repo" "$repo" "merged list truncated at 1000" >> "$work/unreachable.tsv"
      local truncated_flag=0
      [ -f "$work/fetch-truncated" ] && truncated_flag=1
      FM_GD_REPO="$repo" FM_GD_SEEN="$seen_file" FM_GD_OUT="$work/new_merges.tsv" \
      FM_GD_SINCE="$since_file" FM_GD_SINCE_NEW="$work/since-new.tsv" FM_GD_NOW="$now_epoch" \
      FM_GD_TRUNCATED="$truncated_flag" \
      python3 - "$json_file" <<'PY' || printf '%s\t%s\t%s\n' "repo" "$repo" "pull parse failed" >> "$work/unreachable.tsv"
import datetime, json, os, sys
repo = os.environ["FM_GD_REPO"]
since_path = os.environ["FM_GD_SINCE"]
since = {}
with open(since_path) as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[1].isdigit():
            since[parts[0]] = int(parts[1])
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
        try:
            merged = datetime.datetime.strptime(pr["merged_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
        if repo in since:
            if merged.timestamp() <= since[repo]:
                continue
        elif merged.timestamp() <= now - 86400:
            # First fetch for this repository: seed the baseline instead
            # of reporting every old merge in the window as new.
            continue
        out.write("\t".join([repo, number, clean(pr.get("title", "")), clean(pr.get("html_url", "")), sha, str(pr.get("merged_at", ""))]) + "\n")
if os.environ.get("FM_GD_TRUNCATED") != "1":
    # Advance the watermark only on a complete fetch, overlapping the
    # previous window by five minutes; seen.tsv deduplicates.
    with open(os.environ["FM_GD_SINCE_NEW"], "a") as fh:
        fh.write(f"{repo}\t{now - 300}\n")
PY
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
    if ! fetch_pulls "$repo" "state=open&sort=created&direction=asc" "$json_file"; then
      printf '%s\t%s\t%s\n' "repo-open" "$repo" "gh api failed or incomplete; results not used" >> "$work/unreachable.tsv"
    else
      [ -f "$work/fetch-truncated" ] && printf '%s\t%s\t%s\n' "repo-open" "$repo" "open list truncated at 1000" >> "$work/unreachable.tsv"
      FM_GD_REPO="$repo" FM_GD_NOW="$now_epoch" python3 - "$json_file" >> "$work/open.tsv" <<'PY'
import datetime, json, os, sys
repo = os.environ["FM_GD_REPO"]
now = int(os.environ["FM_GD_NOW"])
with open(sys.argv[1]) as fh:
    pulls = json.load(fh)
for pr in pulls:
    created = pr.get("created_at") or ""
    age = ""
    try:
        ts = datetime.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        age = str(max(0, int((now - ts.timestamp()) // 3600)))
    except ValueError:
        pass
    user = (pr.get("user") or {}).get("login", "")
    clean = lambda v: str(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    print("\t".join([repo, str(pr.get("number", "")), clean(pr.get("title", "")), clean(pr.get("html_url", "")), created, age, clean(user), "yes" if pr.get("draft") else "no"]))
PY
    fi
  done

  local eta_pattern='(^|[^[:alnum:]_])eta[: ]+[0-9]{4}-[0-9]{2}-[0-9]{2}'
  for i in "${!status_labels[@]}"; do
    label=${status_labels[$i]}; loc=${status_locs[$i]}
    content=$work/status-content; mtime_file=$work/status-mtime
    if ! read_source "$loc" "$content" "$mtime_file"; then
      printf '%s\t%s\t%s\n' "status" "$label" "$loc" >> "$work/unreachable.tsv"
      printf '%s\t%s\n' "$label" 'source unreachable' >> "$work/waiting-unknown.tsv"
      continue
    fi
    collect_waiting "$label" "$content"
    while IFS= read -r eta_line; do
      eta_date=$(printf '%s' "$eta_line" | grep -oiE "$eta_pattern" | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)
      if [ -n "$eta_date" ] && [ "$eta_date" \< "$today" ]; then
        printf '%s\t%s\t%s\n' "$label" "$eta_date" "$(trim "$eta_line" | tr '\t' ' ')" >> "$work/missed.tsv"
      fi
    done <<EOF
$(grep -iE "$eta_pattern" "$content" 2>/dev/null || true)
EOF
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

  for i in "${!review_labels[@]}"; do
    label=${review_labels[$i]}; loc=${review_locs[$i]}
    content=$work/review-content; mtime_file=$work/review-mtime
    if ! read_source "$loc" "$content" "$mtime_file"; then
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
  content_hash=$({ cut -f1-5,7,8 "$work/open.tsv"; cut -f1-5 "$work/waiting.tsv"; cat "$work/waiting-unknown.tsv" "$work/missed.tsv"; cut -f1 "$work/stalled.tsv"; cat "$work/reviews.tsv" "$work/unreachable.tsv"; } | shasum -a 256 | awk '{print $1}')
  changed=no
  if [ -s "$work/new_merges.tsv" ] || [ ! -f "$hash_file" ] || [ "$(cat "$hash_file")" != "$content_hash" ]; then
    changed=yes
  fi
  FM_GD_WORK="$work" FM_GD_NOW_ISO="$now_iso" FM_GD_NOW_CST="$now_cst" FM_GD_CHANGED="$changed" \
  FM_GD_OUTPUT="$output_dir" \
  python3 - <<'PY'
import datetime, json, os
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
waiting = [{"source": r[0], "id": r[1], "title": r[2], "url": r[3], "wait_started_at": r[4] or None, "age_hours": int(r[5]) if r[5].isdigit() else None} for r in rows("waiting.tsv")]
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
lines += [f"- {w['source']} {w['id']}: {w['title']} age_hours={w['age_hours'] if w['age_hours'] is not None else 'unknown'}" for w in waiting] or ["- None known" if waiting_unknown else "- None"]
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
for suffix, source in (("md", md_tmp), ("json", json_tmp)):
    archive = os.path.join(output, "history", stamp + "." + suffix)
    with open(source, "rb") as inp, open(archive + ".tmp", "wb") as out:
        out.write(inp.read())
    os.replace(archive + ".tmp", archive)
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

  printf '%s\n' "$content_hash" > "$hash_file.tmp" && mv "$hash_file.tmp" "$hash_file" || return 1

  if [ "$changed" = yes ] && [ -n "$summarize_cmd" ]; then
    local summarize_ok=0
    if timed 120 /bin/sh -c "$summarize_cmd" < "$output_dir/latest.md" > "$output_dir/summary.txt.tmp" 2>/dev/null; then
      summarize_ok=1
    fi
    if [ "$summarize_ok" = 1 ]; then
      mv "$output_dir/summary.txt.tmp" "$output_dir/summary.txt"
    else
      rm -f "$output_dir/summary.txt.tmp"
      printf '%s\n' "goal-digest: summarize_cmd failed; digest still written" >&2
    fi
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
  install) do_install ;;
  uninstall) do_uninstall ;;
  --help|-h|help) usage ;;
  *) echo "usage: fm-goal-digest.sh [run|install|uninstall|--help]" >&2; exit 2 ;;
esac
