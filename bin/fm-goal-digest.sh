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
#       FM_HOME> with the configured interval (default 1200 seconds, every
#       20 minutes). The agent runs with this home's FM_HOME and the
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
#   interval_seconds = <n>          (install only, default 1200)
#   stall_hours = <n>               (default 48)
#   summarize_cmd = <command>       (optional, run only when changed)
#   output_dir = <absolute-path>    (default $FM_HOME/data/goal-digest)
# Blank lines and lines starting with # are ignored.
#
# The digest lists new merges (URL and SHA) since the previous run (a
# merged pull already reported, or merged before the repository's previous
# successful fetch, is not new), open
# pull requests waiting for review with their age, missed ETAs (a status
# line with the word "eta" followed by ":" or space and a YYYY-MM-DD date
# in the past), stalled status sources (local file
# not modified within stall_hours) and the last line of each review
# record. Unreachable or unreadable sources are recorded in the digest
# and skipped; the run still succeeds.
#
# changed is yes when the digest content other than its generated time
# and age values differs from the previous run, including the first run.
# A configured summarize_cmd runs only on a changed run, receives
# latest.md on stdin and writes summary.txt in the output directory. This
# script never merges, deploys, tags, pushes or messages anyone: its
# only network reads are `gh api` GET requests and read-only ssh cat.
#
# State under the output directory: .state/seen.tsv holds every merged
# pull request already reported, .state/since.tsv holds each repository's
# previous successful fetch time, .state/content.hash holds the previous
# content hash, and .state/run.flock is the run lock: a run that finds
# another run holding it prints a skip line and exits 1. The kernel lock
# is released when its holder exits, so a crashed run never leaves it
# held; children that may outlive the run close fd 9 so they cannot keep
# it held. FM_GOAL_DIGEST_GH replaces the gh binary only when
# FM_TEST_SEAM=1.
set -u

INTERVAL_DEFAULT=1200
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
interval_seconds=$INTERVAL_DEFAULT
stall_hours=$STALL_DEFAULT
summarize_cmd=
output_dir=

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
      interval_seconds) case "$value" in ''|*[!0-9]*) ;; *) interval_seconds=$value ;; esac ;;
      stall_hours) case "$value" in ''|*[!0-9]*) ;; *) stall_hours=$value ;; esac ;;
      summarize_cmd) summarize_cmd=$value ;;
      output_dir) output_dir=$value ;;
    esac
  done < "$config_file"
  if [ -z "$output_dir" ]; then
    output_dir=$fm_home/data/goal-digest
  fi
}

shell_quote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# fetch_pulls <repo> <state-query> <out-json>: paginate at 100 per page,
# up to 10 pages, combining every page into one JSON array. 0 ok, 1 failed.
fetch_pulls() {
  local repo=$1 query=$2 out=$3 page=1 page_file count
  : > "$work/pages.txt"
  while [ "$page" -le 10 ]; do
    page_file=$work/page-$page.json
    if ! "$gh_bin" api "repos/$repo/pulls?$query&per_page=100&page=$page" > "$page_file" 2>/dev/null; then
      [ "$page" -gt 1 ] || return 1
      break
    fi
    printf '%s\n' "$page_file" >> "$work/pages.txt"
    count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$page_file" 2>/dev/null || printf '0')
    [ "$count" -lt 100 ] && break
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
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "cat -- $quoted" 9>&- > "$content_out" 2>/dev/null || return 1
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "stat -c %Y -- $quoted 2>/dev/null || stat -f %m -- $quoted" 9>&- > "$mtime_out" 2>/dev/null || printf '' > "$mtime_out"
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
  : > "$work/missed.tsv"
  : > "$work/stalled.tsv"
  : > "$work/reviews.tsv"
  : > "$work/unreachable.tsv"

  local now_epoch now_iso now_cst today
  now_epoch=$(date +%s)
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  now_cst=$(TZ=America/Mexico_City date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)
  today=$(TZ=America/Mexico_City date +%Y-%m-%d 2>/dev/null || date +%F)

  local repo json_file i label loc content mtime_file age_hours
  for repo in "${repos[@]:-}"; do
    [ -n "$repo" ] || continue
    json_file=$work/prs.json
    if ! fetch_pulls "$repo" "state=closed&sort=updated&direction=desc" "$json_file"; then
      printf '%s\t%s\t%s\n' "repo" "$repo" "gh api failed" >> "$work/unreachable.tsv"
    else
      FM_GD_REPO="$repo" FM_GD_SEEN="$seen_file" FM_GD_OUT="$work/new_merges.tsv" \
      FM_GD_SINCE="$since_file" FM_GD_SINCE_NEW="$work/since-new.tsv" FM_GD_NOW="$now_epoch" \
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
with open(os.environ["FM_GD_OUT"], "a") as out:
    for pr in pulls:
        if not pr.get("merged_at"):
            continue
        number = str(pr.get("number", ""))
        sha = (pr.get("merge_commit_sha") or "")[:12]
        if (repo, number) in seen:
            continue
        if repo in since:
            try:
                merged = datetime.datetime.strptime(pr["merged_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
            except ValueError:
                continue
            if merged.timestamp() <= since[repo]:
                continue
        out.write("\t".join([repo, number, str(pr.get("title", "")), str(pr.get("html_url", "")), sha, str(pr.get("merged_at", ""))]) + "\n")
with open(os.environ["FM_GD_SINCE_NEW"], "a") as fh:
    fh.write(f"{repo}\t{os.environ['FM_GD_NOW']}\n")
PY
      # Record every merged pull as seen, new or not. This is staged and
      # only committed to seen.tsv after the digest is written, so an
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
      printf '%s\t%s\t%s\n' "repo-open" "$repo" "gh api failed" >> "$work/unreachable.tsv"
    else
      FM_GD_REPO="$repo" FM_GD_NOW="$now_epoch" python3 - "$json_file" >> "$work/waiting.tsv" <<'PY'
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
    print("\t".join([repo, str(pr.get("number", "")), str(pr.get("title", "")), str(pr.get("html_url", "")), created, age, user, "yes" if pr.get("draft") else "no"]))
PY
    fi
  done

  local eta_pattern='(^|[^[:alnum:]_])eta[: ]+[0-9]{4}-[0-9]{2}-[0-9]{2}'
  for i in "${!status_labels[@]}"; do
    label=${status_labels[$i]}; loc=${status_locs[$i]}
    content=$work/status-content; mtime_file=$work/status-mtime
    if ! read_source "$loc" "$content" "$mtime_file"; then
      printf '%s\t%s\t%s\n' "status" "$label" "$loc" >> "$work/unreachable.tsv"
      continue
    fi
    while IFS= read -r eta_line; do
      eta_date=$(printf '%s' "$eta_line" | grep -oiE "$eta_pattern" | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)
      if [ -n "$eta_date" ] && [ "$eta_date" \< "$today" ]; then
        printf '%s\t%s\t%s\n' "$label" "$eta_date" "$(trim "$eta_line")" >> "$work/missed.tsv"
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
    local last_line
    last_line=$(grep -v '^[[:space:]]*$' "$content" | tail -1 || true)
    printf '%s\t%s\n' "$label" "$last_line" >> "$work/reviews.tsv"
  done

  # The persistent-content hash excludes the generated time, the age
  # columns that grow every hour, and the transient new-merges list (a
  # merge reported once would otherwise flip the next run back to changed
  # when it drops off that list).
  local content_hash changed
  content_hash=$({ cut -f1-5,7,8 "$work/waiting.tsv"; cat "$work/missed.tsv"; cut -f1 "$work/stalled.tsv"; cat "$work/reviews.tsv" "$work/unreachable.tsv"; } | shasum -a 256 | awk '{print $1}')
  changed=no
  if [ -s "$work/new_merges.tsv" ] || [ ! -f "$hash_file" ] || [ "$(cat "$hash_file")" != "$content_hash" ]; then
    changed=yes
  fi
  FM_GD_WORK="$work" FM_GD_NOW_ISO="$now_iso" FM_GD_NOW_CST="$now_cst" FM_GD_CHANGED="$changed" \
  FM_GD_LATEST_MD="$output_dir/latest.md" FM_GD_LATEST_JSON="$output_dir/latest.json" \
  python3 - <<'PY'
import json, os
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
waiting = [{"repo": r[0], "number": int(r[1]) if len(r) > 1 and r[1].isdigit() else r[1] if len(r) > 1 else "", "title": r[2] if len(r) > 2 else "", "url": r[3] if len(r) > 3 else "", "created_at": r[4] if len(r) > 4 else "", "age_hours": int(r[5]) if len(r) > 5 and r[5].isdigit() else None, "author": r[6] if len(r) > 6 else "", "draft": (r[7] == "yes") if len(r) > 7 else False} for r in rows("waiting.tsv")]
missed = [{"source": r[0], "eta": r[1] if len(r) > 1 else "", "line": r[2] if len(r) > 2 else ""} for r in rows("missed.tsv")]
stalled = [{"source": r[0], "age_hours": int(r[1]) if len(r) > 1 and r[1].lstrip("-").isdigit() else None} for r in rows("stalled.tsv")]
reviews = [{"source": r[0], "last_line": r[1] if len(r) > 1 else ""} for r in rows("reviews.tsv")]
unreachable = [{"kind": r[0], "source": r[1] if len(r) > 1 else "", "detail": r[2] if len(r) > 2 else ""} for r in rows("unreachable.tsv")]
digest = {
    "generated_at": os.environ["FM_GD_NOW_ISO"],
    "generated_at_cst": os.environ["FM_GD_NOW_CST"],
    "changed": os.environ["FM_GD_CHANGED"] == "yes",
    "new_merges": new_merges,
    "waiting_on_captain": waiting,
    "missed_etas": missed,
    "stalls": stalled,
    "review_convergence": reviews,
    "unreachable_sources": unreachable,
}
with open(os.environ["FM_GD_LATEST_JSON"], "w") as fh:
    json.dump(digest, fh, indent=2)
    fh.write("\n")
lines = ["# Goal digest", "", f"Generated: {digest['generated_at_cst']} (CST) / {digest['generated_at']}", f"Changed: {'yes' if digest['changed'] else 'no'}", "", "## New merges since last run", ""]
if new_merges:
    lines += [f"- [{m['repo']} #{m['number']} {m['title']}]({m['url']}) `{m['sha']}` {m['merged_at']}" for m in new_merges]
else:
    lines.append("- None")
lines += ["", "## Waiting on captain", ""]
if waiting:
    lines += [f"- [{w['repo']} #{w['number']} {w['title']}]({w['url']}) age_hours={w['age_hours']} author={w['author']} draft={'yes' if w['draft'] else 'no'}" for w in waiting]
else:
    lines.append("- None")
lines += ["", "## Missed ETAs", ""]
lines += [f"- {m['source']}: eta {m['eta']} - {m['line']}" for m in missed] or ["- None"]
lines += ["", "## Stalls", ""]
lines += [f"- {s['source']}: no update for {s['age_hours']}h" for s in stalled] or ["- None"]
lines += ["", "## Review convergence", ""]
lines += [f"- {r['source']}: {r['last_line']}" for r in reviews] or ["- None"]
lines += ["", "## Unreachable sources", ""]
lines += [f"- {u['kind']} {u['source']}: {u['detail']}" for u in unreachable] or ["- None"]
lines.append("")
with open(os.environ["FM_GD_LATEST_MD"], "w") as fh:
    fh.write("\n".join(lines))
PY
  local digest_rc=$?
  if [ "$digest_rc" -ne 0 ]; then
    printf '%s\n' "goal-digest: digest generation failed; state not advanced" >&2
    return 1
  fi

  # The digest is published; only now commit the staged state.
  printf '%s\n' "$content_hash" > "$hash_file"
  cat "$work/seen-new.tsv" >> "$seen_file"
  local seen_tmp
  seen_tmp=$(mktemp "$output_dir/.state/seen.XXXXXX")
  sort -u "$seen_file" -o "$seen_tmp" && mv "$seen_tmp" "$seen_file"
  FM_GD_SINCE="$since_file" FM_GD_SINCE_NEW="$work/since-new.tsv" python3 - <<'PY'
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

  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  cp "$output_dir/latest.md" "$output_dir/history/$stamp.md"
  cp "$output_dir/latest.json" "$output_dir/history/$stamp.json"

  if [ "$changed" = yes ] && [ -n "$summarize_cmd" ]; then
    # shellcheck disable=SC2086
    $summarize_cmd 9>&- < "$output_dir/latest.md" > "$output_dir/summary.txt" 2>/dev/null || printf '%s\n' "goal-digest: summarize_cmd failed; digest still written" >&2
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
  <integer>$interval_seconds</integer>
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
  printf 'goal-digest: installed=%s interval_seconds=%s\n' "$plist" "$interval_seconds"
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
