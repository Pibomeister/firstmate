#!/usr/bin/env bash
# SSH transport for fm-test-queue.sh; sourced only by that entry point.
# The queue header owns configuration and the execution contract.

REMOTE_HOST="" REMOTE_DIR="" REMOTE_ROOT="" REMOTE_CWD="" REMOTE_LOCAL=""
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

# Prepare before starting any workload. A failed preparation can safely fall
# back to local admission. Once remote_exec starts, no local retry is safe.
remote_prepare() {
  local root host dir file rel hosts
  command -v ssh >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || return 1
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  case "$PWD/" in "$root/"*) rel=${PWD#"$root"} ;; *) return 1 ;; esac
  REMOTE_LOCAL=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-offload.XXXXXXXX") || return 1
  hosts=${REMOTE_HOSTS:-}
  hosts=${hosts//,/ }
  for host in $hosts; do
    dir=$(remote_ssh "$host" 'umask 077; command -v bash >/dev/null && command -v git >/dev/null && command -v tar >/dev/null && mktemp -d /tmp/fm-test-offload.XXXXXXXX' </dev/null 2>/dev/null) || continue
    # Only a private directory minted by this protocol may ever be removed.
    case "$dir" in /tmp/fm-test-offload.*) ;; *) continue ;; esac
    case "$dir" in *[!a-zA-Z0-9/._-]*) continue ;; esac
    REMOTE_HOST=$host REMOTE_DIR=$dir
    if [ ! -f "$REMOTE_LOCAL/tree.tar" ]; then
      # Snapshot only after a host answers. NUL-delimited names preserve
      # whitespace; absent tracked files stay absent.
      git -C "$root" ls-files -z --cached --others --exclude-standard > "$REMOTE_LOCAL/all" || { remote_cleanup; return 1; }
      : > "$REMOTE_LOCAL/files"
      while IFS= read -r -d '' file; do
        [ -e "$root/$file" ] || [ -L "$root/$file" ] || continue
        printf '%s\0' "$file" >> "$REMOTE_LOCAL/files"
      done < "$REMOTE_LOCAL/all"
      if ! git clone -q --depth=1 --no-checkout "file://$root" "$REMOTE_LOCAL/repo" >/dev/null 2>&1 ||
        ! git -C "$REMOTE_LOCAL/repo" read-tree HEAD ||
        ! tar -cf "$REMOTE_LOCAL/tree.tar" -C "$root" --null -T "$REMOTE_LOCAL/files" ||
        ! mkdir "$REMOTE_LOCAL/queue" ||
        ! cp "$SCRIPT_DIR/fm-test-queue.sh" "$SCRIPT_DIR/fm-test-queue-remote.sh" "$REMOTE_LOCAL/queue/"; then
        remote_cleanup
        return 1
      fi
    fi
    echo "fm-test-queue: preparing compressed snapshot for $host" >&2
    if (set -o pipefail; tar -czf - -C "$REMOTE_LOCAL" repo/.git tree.tar queue |
      remote_ssh "$host" "tar -xzf - -C $(remote_quote "$dir") && tar -xf $(remote_quote "$dir/tree.tar") -C $(remote_quote "$dir/repo") && cd $(remote_quote "$dir/repo$rel") && test -f $(remote_quote "$dir/queue/fm-test-queue.sh")" >/dev/null 2>&1); then
      REMOTE_ROOT="$dir/repo"
      REMOTE_CWD="$REMOTE_ROOT$rel"
      LOCAL_ROOT=$root
      echo "fm-test-queue: offloading to $host (snapshot of $root)" >&2
      return 0
    fi
    remote_ssh "$host" "rm -rf -- $(remote_quote "$dir")" </dev/null >/dev/null 2>&1 || true
    REMOTE_HOST="" REMOTE_DIR=""
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
  remote_ssh "$REMOTE_HOST" "cd $(remote_quote "$REMOTE_CWD") && FM_HOME=$(remote_quote "$REMOTE_ROOT") FM_TEST_QUEUE_REMOTE_DISABLE=1 bash $(remote_quote "$REMOTE_DIR/queue/fm-test-queue.sh") run --$command"
  rc=$?
  if [ "$rc" -lt 128 ]; then rm -f "$REMOTE_LOCAL/execution-uncertain"; fi
  return "$rc"
}
