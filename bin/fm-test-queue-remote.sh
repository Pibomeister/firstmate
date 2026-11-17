#!/usr/bin/env bash
# SSH transport for fm-test-queue.sh; sourced only by that entry point.
# The queue header owns configuration and the execution contract.

REMOTE_HOST="" REMOTE_DIR="" REMOTE_ROOT="" REMOTE_CWD="" REMOTE_LOCAL="" REMOTE_CACHE=""
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)

remote_quote() {
  local quote="'\"'\"'"
  printf "'%s'" "${1//\'/$quote}"
}

# The caller supplies a command assembled from remote_quote, not remote vars.
# shellcheck disable=SC2029
remote_ssh() { ssh "${SSH_OPTIONS[@]}" "$@"; }

remote_cleanup() {
  if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_DIR" ]; then
    if [ -f "$REMOTE_LOCAL/execution-uncertain" ]; then
      echo "fm-test-queue: remote execution uncertain; preserved $REMOTE_HOST:$REMOTE_DIR (no local retry)" >&2
    else
      remote_ssh "$REMOTE_HOST" "rm -rf -- $(remote_quote "$REMOTE_DIR")" </dev/null >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_CACHE" ]; then
    remote_ssh "$REMOTE_HOST" "rmdir -- $(remote_quote "$REMOTE_CACHE/lock")" </dev/null >/dev/null 2>&1 || true
  fi
  REMOTE_CACHE=""
  [ -z "$REMOTE_LOCAL" ] || rm -rf "$REMOTE_LOCAL"
  REMOTE_HOST="" REMOTE_DIR="" REMOTE_LOCAL=""
}

# Offload is opt-in per project, named by the origin URL's last path segment.
remote_project_listed() {
  local url name
  url=$(git config --get remote.origin.url 2>/dev/null) || return 1
  url=${url%/}
  url=${url%.git}
  name=${url##*[/:]}
  [ -n "$name" ] || return 1
  case ",$OFFLOAD_PROJECTS," in *",$name,"*) return 0 ;; esac
  return 1
}

# Hash the entire transported tree, including Git metadata, modes and symlinks.
# An exact inventory also detects deletions and unexpected stale mirror files.
# Only the top-level manifest itself is excluded from its own digest.
remote_manifest() {
  python3 - "$1" <<'PYMANIFEST'
import hashlib
import json
import os
import stat
import sys

root = os.fsencode(sys.argv[1])

def walk(path, relative=b""):
    for name in sorted(os.listdir(path)):
        if not relative and name == b"manifest":
            continue
        entry = os.path.join(path, name)
        rel = os.path.join(relative, name)
        mode = os.lstat(entry).st_mode
        if stat.S_ISLNK(mode):
            value = ["link", os.fsdecode(os.readlink(entry))]
        elif stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with open(entry, "rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            value = ["file", mode & 0o777, digest.hexdigest()]
        elif stat.S_ISDIR(mode):
            value = ["dir"]
        else:
            raise ValueError("unsupported snapshot entry: " + os.fsdecode(rel))
        print(json.dumps([os.fsdecode(rel), *value], ensure_ascii=True))
        if stat.S_ISDIR(mode):
            walk(entry, rel)

walk(root)
PYMANIFEST
}

# Loose objects keep their content-addressed names across HEAD changes. A new
# shallow pack would rename the entire pack and resend unchanged blobs.
remote_stage_git() {
  local root=$1 repo=$2 pack objects="$REMOTE_LOCAL/objects"
  git clone -q --depth=1 --no-checkout "file://$root" "$repo" >/dev/null 2>&1 || return 1
  mkdir "$objects" || return 1
  for pack in "$repo/.git/objects/pack/"*.pack; do
    [ -f "$pack" ] || return 1
    GIT_OBJECT_DIRECTORY="$objects" git -C "$repo" unpack-objects < "$pack" || return 1
  done
  rm -rf "$repo/.git/objects" && mv "$objects" "$repo/.git/objects" &&
    git -C "$repo" read-tree HEAD
}

# Prepare before starting any workload. A failed preparation can safely fall
# back to local admission. Once remote_exec starts, no local retry is safe.
# A per-repository mirror is locked only for sync/copy, never for test execution.
# Refuse a busy or abandoned lock rather than overwriting another preparation.
remote_prepare() {
  local root host dir file rel hosts key reply cache transport verify common
  command -v ssh >/dev/null 2>&1 && command -v git >/dev/null 2>&1 &&
    command -v rsync >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 1
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  case "$PWD/" in "$root/"*) rel=${PWD#"$root"} ;; *) return 1 ;; esac
  REMOTE_LOCAL=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-offload.XXXXXXXX") || return 1
  common=$(git -C "$root" rev-parse --git-common-dir) || { remote_cleanup; return 1; }
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  common=$(cd "$common" && pwd -P) || { remote_cleanup; return 1; }
  key=$(printf '%s\n' "$(hostname)" "$common" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') || { remote_cleanup; return 1; }
  hosts=${REMOTE_HOSTS:-}
  hosts=${hosts//,/ }
  transport="ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
  # The remote Bash expands its positional parameters, not this shell.
  # shellcheck disable=SC2016
  verify="$(declare -f remote_manifest)"$'\n''remote_manifest "$1" > "$2" && cmp -s "$1/manifest" "$2"'
  for host in $hosts; do
    # HOME is resolved on the remote host. Only this user's private cache and
    # a newly minted run directory are used; no project checkout is modified.
    reply=$(remote_ssh "$host" "bash -s -- $key" 2>/dev/null <<'SHREMOTE'
set -e
umask 077
command -v bash >/dev/null
command -v git >/dev/null
command -v rsync >/dev/null
command -v python3 >/dev/null
cache="$HOME/.cache/firstmate/test-mirrors/$1"
mkdir -p "$cache"
if [ -L "$cache" ] || [ ! -O "$cache" ]; then exit 1; fi
chmod 700 "$cache"
mkdir "$cache/lock"
dir=$(mktemp -d /tmp/fm-test-offload.XXXXXXXX) || { rmdir "$cache/lock"; exit 1; }
printf '%s\n%s\n' "$dir" "$cache"
SHREMOTE
    ) || continue
    dir=${reply%%$'\n'*}
    cache=${reply#*$'\n'}
    # Only a private directory minted by this protocol may ever be removed.
    case "$dir" in /tmp/fm-test-offload.*) ;; *) continue ;; esac
    case "$dir" in *[!a-zA-Z0-9/._-]*) continue ;; esac
    case "$cache" in /*/.cache/firstmate/test-mirrors/"$key") ;; *) continue ;; esac
    REMOTE_HOST=$host REMOTE_DIR=$dir REMOTE_CACHE=$cache
    if [ ! -f "$REMOTE_LOCAL/snapshot/manifest" ]; then
      # Stage only eligible source paths. Never traverse a directory in place
      # of a tracked file (including submodules) or copy ignored dependencies.
      git -C "$root" ls-files -z --cached --others --exclude-standard > "$REMOTE_LOCAL/all" || { remote_cleanup; return 1; }
      : > "$REMOTE_LOCAL/files"
      while IFS= read -r -d '' file; do
        [ -e "$root/$file" ] || [ -L "$root/$file" ] || continue
        if [ -d "$root/$file" ] && [ ! -L "$root/$file" ]; then remote_cleanup; return 1; fi
        printf '%s\0' "$file" >> "$REMOTE_LOCAL/files"
      done < "$REMOTE_LOCAL/all"
      if ! mkdir -p "$REMOTE_LOCAL/snapshot/queue" ||
        ! remote_stage_git "$root" "$REMOTE_LOCAL/snapshot/repo" ||
        ! (set -o pipefail; tar -cf - -C "$root" --null -T "$REMOTE_LOCAL/files" |
          tar -xf - -C "$REMOTE_LOCAL/snapshot/repo") ||
        ! cp "$SCRIPT_DIR/fm-test-queue.sh" "$SCRIPT_DIR/fm-test-queue-remote.sh" "$REMOTE_LOCAL/snapshot/queue/" ||
        ! remote_manifest "$REMOTE_LOCAL/snapshot" > "$REMOTE_LOCAL/snapshot/manifest"; then
        remote_cleanup
        return 1
      fi
    fi
    echo "fm-test-queue: syncing snapshot delta to $host" >&2
    # Checksums avoid timestamp-only transfers; rolling deltas send only the
    # changed bytes. Delete stale paths, including removed untracked files.
    if rsync -ac --delete --no-whole-file -z -e "$transport" "$REMOTE_LOCAL/snapshot/" "$host:$(remote_quote "$cache/snapshot/")" >/dev/null 2>&1 &&
      remote_ssh "$host" "cp -R $(remote_quote "$cache/snapshot/.") $(remote_quote "$dir/") && bash -c $(remote_quote "$verify") _ $(remote_quote "$dir") $(remote_quote "$cache/verified") && cd $(remote_quote "$dir/repo$rel") && rmdir $(remote_quote "$cache/lock")" </dev/null >/dev/null 2>&1; then
      REMOTE_CACHE=""
      REMOTE_ROOT="$dir/repo"
      REMOTE_CWD="$REMOTE_ROOT$rel"
      LOCAL_ROOT=$root
      echo "fm-test-queue: offloading to $host (verified snapshot of $root)" >&2
      return 0
    fi
    remote_ssh "$host" "rm -rf -- $(remote_quote "$dir"); rmdir -- $(remote_quote "$cache/lock")" </dev/null >/dev/null 2>&1 || true
    REMOTE_HOST="" REMOTE_DIR="" REMOTE_CACHE=""
  done
  remote_cleanup
  return 1
}

remote_exec() {
  local arg command="" rc
  # Rewrite worktree paths in argv, including shell -c strings. Paths outside
  # the source tree and the caller's private environment are not transported.
  for arg in "$@"; do
    arg=${arg//"$LOCAL_ROOT"/"$REMOTE_ROOT"}
    command="$command $(remote_quote "$arg")"
  done
  : > "$REMOTE_LOCAL/execution-uncertain"
  # exec makes the remote queue the session leader SSH created, so it owns
  # that group and ends stragglers that would hold the SSH output open.
  remote_ssh "$REMOTE_HOST" "cd $(remote_quote "$REMOTE_CWD") && exec env FM_HOME=$(remote_quote "$REMOTE_ROOT") FM_TEST_QUEUE_REMOTE_DISABLE=1 bash $(remote_quote "$REMOTE_DIR/queue/fm-test-queue.sh") run --$command"
  rc=$?
  if [ "$rc" -lt 128 ]; then rm -f "$REMOTE_LOCAL/execution-uncertain"; fi
  return "$rc"
}
