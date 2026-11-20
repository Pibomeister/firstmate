#!/usr/bin/env bash
# SSH transport for fm-test-queue.sh; sourced only by that entry point.
# The queue header owns configuration and the execution contract.

REMOTE_HOST="" REMOTE_DIR="" REMOTE_ROOT="" REMOTE_CWD="" REMOTE_LOCAL="" REMOTE_CACHE=""
REMOTE_LOCK_HOST=""
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)

remote_quote() {
  local quote="'\"'\"'"
  printf "'%s'" "${1//\'/$quote}"
}

# The caller supplies a command assembled from remote_quote, not remote vars.
# shellcheck disable=SC2029
remote_ssh() { ssh "${SSH_OPTIONS[@]}" "$@"; }

# Release a mirror lock only while its owner record still names this run, so a
# run whose lock was reclaimed as stale cannot release its successor's lock.
remote_lock_release() {  # <remote shell word naming the mirror cache directory>
  printf '{ c=%s; if grep -qxF -- %s "$c/lock/owner" 2>/dev/null && grep -qxF -- %s "$c/lock/owner"; then rm -f -- "$c/lock/owner" && rmdir -- "$c/lock"; fi; }' \
    "$1" "$(remote_quote "host=$REMOTE_LOCK_HOST")" "$(remote_quote "pid=$$")"
}

remote_cleanup() {
  if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_DIR" ]; then
    if [ -f "$REMOTE_LOCAL/execution-uncertain" ]; then
      echo "fm-test-queue: remote execution uncertain; preserved $REMOTE_HOST:$REMOTE_DIR (no local retry)" >&2
    else
      remote_ssh "$REMOTE_HOST" "rm -rf -- $(remote_quote "$REMOTE_DIR")" </dev/null >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_CACHE" ]; then
    remote_ssh "$REMOTE_HOST" "$(remote_lock_release "$(remote_quote "$REMOTE_CACHE")")" </dev/null >/dev/null 2>&1 || true
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

# Build file lists, queue copy, and local SHA-256 manifest in one pass directly
# from the source tree, emitting repo metadata for remote_prepare.
remote_stage_local() {
  python3 - "$1" "$2" "$3" "$4" <<'PYSTAGE'
import concurrent.futures
import hashlib
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import time

pwd, local_dir, script_dir, spool = sys.argv[1:5]

try:
    root = subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], cwd=pwd, stderr=subprocess.DEVNULL
    ).decode().rstrip("\r\n")
except subprocess.CalledProcessError:
    sys.exit(1)

root_real = os.path.realpath(root)
pwd_real = os.path.realpath(pwd)
if pwd_real == root_real:
    rel_cwd = ""
elif pwd_real.startswith(root_real + os.sep):
    rel_cwd = pwd_real[len(root_real):]
else:
    sys.exit(1)

try:
    local_head = subprocess.check_output(
        ["git", "-C", root, "rev-parse", "--verify", "HEAD"], stderr=subprocess.DEVNULL
    ).decode().strip()
    local_tree = subprocess.check_output(
        ["git", "-C", root, "rev-parse", "--verify", "HEAD^{tree}"], stderr=subprocess.DEVNULL
    ).decode().strip()
    common = subprocess.check_output(
        ["git", "-C", root, "rev-parse", "--git-common-dir"], stderr=subprocess.DEVNULL
    ).decode().rstrip("\r\n")
except subprocess.CalledProcessError:
    sys.exit(1)

if not os.path.isabs(common):
    common = os.path.join(root, common)
common = os.path.realpath(common)
key = hashlib.sha256(f"{socket.gethostname()}\n{common}\n".encode()).hexdigest()
cache_path = os.path.join(spool, f"manifest-cache-{key}.json") if spool else ""

stage_dir = os.path.join(local_dir, "stage")
queue_dir = os.path.join(stage_dir, "queue")
os.makedirs(queue_dir, exist_ok=True)

root_b = os.fsencode(root)
local_b = os.fsencode(local_dir)
script_b = os.fsencode(script_dir)
queue_b = os.fsencode(queue_dir)

raw = subprocess.check_output(
    ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
)
now = time.time()

old_cache = {}
if cache_path and os.path.isfile(cache_path):
    try:
        with open(cache_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            old_cache = data
    except Exception:
        old_cache = {}

files = []
recent = []
to_hash = []
new_cache = {}
tree = {b"queue": {}, b"repo": {}}

def add_entry(rel, full):
    rel = rel.rstrip(b"/")
    if not rel:
        return
    try:
        st = os.lstat(full)
    except FileNotFoundError:
        return
    mode = st.st_mode
    parts = rel.split(b"/")
    cur = tree[b"repo"]
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    if stat.S_ISDIR(mode):
        node = cur.setdefault(parts[-1], {})
        if not isinstance(node, dict):
            sys.exit(1)
        for name in sorted(os.listdir(full)):
            if name == b".git":
                continue
            add_entry(rel + b"/" + name, os.path.join(full, name))
    elif stat.S_ISLNK(mode):
        recent.append(rel)
        cur[parts[-1]] = ["link", os.fsdecode(os.readlink(full))]
    elif stat.S_ISREG(mode):
        if abs(now - st.st_mtime) < 3.0:
            recent.append(rel)
        else:
            files.append(rel)
        key_f = os.fsdecode(rel)
        sig = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
        cached = old_cache.get(key_f)
        if isinstance(cached, list) and len(cached) == 2 and cached[0] == sig:
            new_cache[key_f] = cached
            cur[parts[-1]] = ["file", mode & 0o777, cached[1]]
        else:
            slot = ["file", mode & 0o777, None]
            cur[parts[-1]] = slot
            to_hash.append((full, key_f, sig, slot))
    else:
        sys.exit(1)

for rel in raw.split(b"\0"):
    if not rel:
        continue
    add_entry(rel, os.path.join(root_b, rel))

def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

if to_hash:
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        results = list(pool.map(lambda item: hash_file(item[0]), to_hash))
    for (_, key_f, sig, slot), digest in zip(to_hash, results):
        slot[2] = digest
        new_cache[key_f] = [sig, digest]

for name in (b"fm-test-queue.sh", b"fm-test-queue-remote.sh"):
    src = os.path.join(script_b, name)
    dst = os.path.join(queue_b, name)
    shutil.copy2(src, dst)
    st = os.lstat(dst)
    tree[b"queue"][name] = ["file", st.st_mode & 0o777, hash_file(dst)]

with open(os.path.join(local_b, b"files"), "wb") as fh:
    if files:
        fh.write(b"\0".join(files) + b"\0")
with open(os.path.join(local_b, b"recent_files"), "wb") as fh:
    if recent:
        fh.write(b"\0".join(recent) + b"\0")

manifest_lines = []
def emit(node, relative=b""):
    for name in sorted(node):
        child = node[name]
        rel = os.path.join(relative, name)
        if isinstance(child, dict):
            manifest_lines.append(json.dumps([os.fsdecode(rel), "dir"], ensure_ascii=True))
            emit(child, rel)
        else:
            manifest_lines.append(json.dumps([os.fsdecode(rel), *child], ensure_ascii=True))

emit(tree)
manifest_text = ("\n".join(manifest_lines) + "\n") if manifest_lines else ""
with open(os.path.join(local_b, b"stage", b"manifest"), "w", encoding="utf-8") as fh:
    fh.write(manifest_text)
manifest_sha = hashlib.sha256(manifest_text.encode("utf-8")).hexdigest()

if cache_path:
    try:
        tmp = f"{cache_path}.tmp.{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(new_cache, fh)
        os.replace(tmp, cache_path)
    except Exception:
        pass

with open(os.path.join(local_b, b"meta"), "w", encoding="utf-8") as fh:
    fh.write(f"{root}\n{rel_cwd}\n{key}\n{local_head}\n{local_tree}\n{manifest_sha}\n")
PYSTAGE
}

# Build a pack of objects in local_head missing from remote_head's shallow tree.
remote_stage_git_delta() {
  local root=$1 remote_head=$2 local_head=$3 out=$4
  python3 - "$root" "$remote_head" "$local_head" "$out" <<'PYDELTA'
import subprocess
import sys

root, remote_head, local_head, out = sys.argv[1:5]
if subprocess.call(["git", "-C", root, "cat-file", "-e", f"{remote_head}^{{commit}}"], stderr=subprocess.DEVNULL) != 0:
    sys.exit(1)
head_tree = subprocess.check_output(
    ["git", "-C", root, "rev-parse", "--verify", f"{local_head}^{{tree}}"]
).decode().strip()
diff = subprocess.check_output(
    ["git", "-C", root, "diff-tree", "-r", "-t", "--no-commit-id", remote_head, local_head]
).decode().splitlines()
oids = {local_head, head_tree}
for line in diff:
    parts = line.split()
    if len(parts) >= 4 and parts[1] != "160000" and parts[3] != "0" * 40:
        oids.add(parts[3])
proc = subprocess.Popen(
    ["git", "-C", root, "pack-objects", "--stdout", "-q"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)
pack, _ = proc.communicate(("\n".join(sorted(oids)) + "\n").encode())
if proc.returncode != 0 or not pack:
    sys.exit(1)
with open(out, "wb") as fh:
    fh.write(pack)
PYDELTA
}

# Prepare before starting any workload. A failed preparation can safely fall
# back to local admission. Once remote_exec starts, no local retry is safe.
# A per-repository mirror is locked only for sync/copy, never for test execution.
# A busy lock falls back to the next host or local admission; a lock abandoned
# for more than 30 minutes is reclaimed. The private copy must match this run's
# own manifest, so a run racing a reclaimed lock cannot admit another's source.
remote_prepare() {
  local root host rel hosts key reply dir cache rhead transport note valid
  local local_head local_tree manifest_sha git_mode finalize heal_marker heal_c=""
  command -v ssh >/dev/null 2>&1 && command -v git >/dev/null 2>&1 &&
    command -v rsync >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 1
  REMOTE_LOCAL=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-offload.XXXXXXXX") || return 1
  if ! remote_stage_local "$PWD" "$REMOTE_LOCAL" "$SCRIPT_DIR" "$SPOOL"; then
    echo "fm-test-queue: remote staging failed; using local admission" >&2
    remote_cleanup
    return 1
  fi
  {
    IFS= read -r root
    IFS= read -r rel
    IFS= read -r key
    IFS= read -r local_head
    IFS= read -r local_tree
    IFS= read -r manifest_sha
  } < "$REMOTE_LOCAL/meta"
  REMOTE_LOCK_HOST=$(hostname 2>/dev/null) || REMOTE_LOCK_HOST=""
  [ -n "$REMOTE_LOCK_HOST" ] || REMOTE_LOCK_HOST=unknown
  heal_marker="$SPOOL/offload-checksum-$key"
  [ ! -e "$heal_marker" ] || heal_c=c
  hosts=${REMOTE_HOSTS:-}
  hosts=${hosts//,/ }
  transport="ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
  finalize=$(cat <<'PYFINAL'
import concurrent.futures
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys

cache, rdir, git_mode, lhead, ltree, mhash = sys.argv[1:7]
snap = os.path.join(cache, "snapshot")
repo = os.path.join(snap, "repo")
expected_files = set()
expected_dirs = {repo}
with open(os.path.join(snap, "manifest"), "r", encoding="utf-8") as fh:
    for line in fh:
        item = json.loads(line)
        rel = item[0]
        if rel == "repo" or rel.startswith("repo/"):
            p = os.path.join(snap, rel)
            if item[1] == "dir":
                expected_dirs.add(p)
            else:
                expected_files.add(p)
for cur, dirs, files in os.walk(repo, topdown=False):
    if cur == os.path.join(repo, ".git") or cur.startswith(os.path.join(repo, ".git") + os.sep):
        continue
    for f in files:
        p = os.path.join(cur, f)
        if p not in expected_files:
            os.unlink(p)
    for d in dirs:
        p = os.path.join(cur, d)
        if d == ".git" and cur == repo:
            continue
        if os.path.islink(p):
            if p not in expected_files:
                os.unlink(p)
        elif p in expected_files or p not in expected_dirs:
            shutil.rmtree(p)

delta_pack = os.path.join(snap, "delta.pack")
cold_git = os.path.join(snap, "cold.git")
repo_git = os.path.join(repo, ".git")
if git_mode == "cold":
    if os.path.exists(repo_git):
        shutil.rmtree(repo_git)
    shutil.move(cold_git, repo_git)
elif git_mode == "delta":
    pack_dst = os.path.join(repo_git, "objects", "pack", f"pack-{lhead}-{os.getpid()}.pack")
    shutil.move(delta_pack, pack_dst)
    subprocess.check_call(["git", "-C", repo, "index-pack", pack_dst], stdout=subprocess.DEVNULL)
    shallow_path = os.path.join(repo_git, "shallow")
    shallow = []
    if os.path.isfile(shallow_path):
        with open(shallow_path, "r", encoding="utf-8") as fh:
            shallow = [line.strip() for line in fh if line.strip()]
    if lhead not in shallow:
        shallow.append(lhead)
    with open(shallow_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(shallow) + "\n")
    subprocess.check_call(["git", "-C", repo, "update-ref", "HEAD", lhead])
    subprocess.check_call(["git", "-C", repo, "read-tree", "HEAD"])
if os.path.exists(delta_pack):
    os.unlink(delta_pack)
if os.path.exists(cold_git):
    shutil.rmtree(cold_git)

def clean_dir(target):
    for n in os.listdir(target):
        p = os.path.join(target, n)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.unlink(p)

src_dot = os.path.join(snap, ".")
if subprocess.call(["cp", "-RcPp", src_dot, rdir + "/"], stderr=subprocess.DEVNULL) != 0:
    clean_dir(rdir)
    if subprocess.call(["cp", "--reflink=auto", "-RPp", src_dot, rdir + "/"], stderr=subprocess.DEVNULL) != 0:
        clean_dir(rdir)
        subprocess.check_call(["cp", "-RPp", src_dot, rdir + "/"])
os.chmod(rdir, 0o700)

rdir_b = os.fsencode(rdir)
entries = []
def walk(path, relative=b""):
    for name in sorted(os.listdir(path)):
        if not relative and name == b"manifest":
            continue
        if relative == b"repo" and name == b".git":
            continue
        entry = os.path.join(path, name)
        rel_p = os.path.join(relative, name)
        mode = os.lstat(entry).st_mode
        if stat.S_ISLNK(mode):
            entries.append((rel_p, "link", os.fsdecode(os.readlink(entry)), None))
        elif stat.S_ISREG(mode):
            entries.append((rel_p, "file", mode & 0o777, entry))
        elif stat.S_ISDIR(mode):
            entries.append((rel_p, "dir", None, None))
            walk(entry, rel_p)
        else:
            sys.exit(1)

def hash_file(path):
    d = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            d.update(block)
    return d.hexdigest()

walk(rdir_b)
file_paths = [item[3] for item in entries if item[1] == "file"]
hashes = []
if file_paths:
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        hashes = list(pool.map(hash_file, file_paths))
hi = 0
verified_lines = []
for rel_p, kind, meta, _ in entries:
    if kind == "link":
        verified_lines.append(json.dumps([os.fsdecode(rel_p), "link", meta], ensure_ascii=True))
    elif kind == "file":
        verified_lines.append(json.dumps([os.fsdecode(rel_p), "file", meta, hashes[hi]], ensure_ascii=True))
        hi += 1
    else:
        verified_lines.append(json.dumps([os.fsdecode(rel_p), "dir"], ensure_ascii=True))

with open(os.path.join(rdir, "manifest"), "rb") as fh:
    expected_bytes = fh.read()
if hashlib.sha256(expected_bytes).hexdigest() != mhash:
    sys.exit(1)
actual_text = ("\n".join(verified_lines) + "\n") if verified_lines else ""
if expected_bytes != actual_text.encode("utf-8"):
    sys.exit(1)

rrepo = os.path.join(rdir, "repo")
rev = subprocess.check_output(
    ["git", "-C", rrepo, "rev-parse", "--is-shallow-repository", "HEAD", "HEAD^{tree}"]
).decode().splitlines()
if rev != ["true", lhead, ltree]:
    sys.exit(1)
wtree = subprocess.check_output(["git", "-C", rrepo, "write-tree"]).decode().strip()
if wtree != ltree:
    sys.exit(1)
PYFINAL
  )
  for host in $hosts; do
    # HOME is resolved on the remote host. Only this user's private cache and
    # a newly minted run directory are used; no project checkout is modified.
    reply=$(remote_ssh "$host" "bash -s -- $key $(remote_quote "$REMOTE_LOCK_HOST") $$" 2>/dev/null <<'SHREMOTE'
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
note=none
if ! mkdir "$cache/lock" 2>/dev/null; then
  epoch=0
  if [ -f "$cache/lock/owner" ]; then
    epoch=$(awk -F= '$1=="epoch"{print $2}' "$cache/lock/owner" 2>/dev/null || true)
  fi
  if [ -z "$epoch" ] || [ -n "$(printf %s "$epoch" | tr -d 0-9)" ]; then epoch=$(stat -c %Y "$cache/lock" 2>/dev/null || stat -f %m "$cache/lock" 2>/dev/null || echo 0); fi
  if [ -z "$epoch" ] || [ -n "$(printf %s "$epoch" | tr -d 0-9)" ]; then epoch=0; fi
  now=$(date +%s)
  if [ "$epoch" -le 0 ] || [ $((now - epoch)) -le 1800 ]; then exit 1; fi
  mv "$cache/lock" "$cache/lock.stale.$$" || exit 1
  rm -rf "$cache/lock.stale.$$"
  mkdir "$cache/lock" || exit 1
  note="reclaimed stale test-mirror lock older than 30m"
fi
printf 'host=%s\npid=%s\nepoch=%s\n' "${2:-unknown}" "${3:-0}" "$(date +%s)" > "$cache/lock/owner"
mkdir -p "$cache/snapshot/repo"
dir=$(mktemp -d /tmp/fm-test-offload.XXXXXXXX) || { rm -f "$cache/lock/owner"; rmdir "$cache/lock"; exit 1; }
rhead=""
if [ -d "$cache/snapshot/repo/.git" ] && [ -f "$cache/snapshot/repo/.git/shallow" ]; then
  packs=0
  for p in "$cache/snapshot/repo/.git/objects/pack/"*.pack; do
    [ -f "$p" ] && packs=$((packs + 1))
  done
  if [ "$packs" -gt 0 ] && [ "$packs" -le 16 ]; then
    rhead=$(git -C "$cache/snapshot/repo" rev-parse --verify HEAD 2>/dev/null || true)
  fi
fi
printf '%s\n%s\n%s\n%s\n' "$dir" "$cache" "${rhead:-none}" "$note"
SHREMOTE
    ) || continue
    dir=${reply%%$'\n'*}
    reply=${reply#*$'\n'}
    cache=${reply%%$'\n'*}
    reply=${reply#*$'\n'}
    rhead=${reply%%$'\n'*}
    note=${reply#*$'\n'}
    [ "$note" != "$rhead" ] || note=none
    [ "$rhead" != none ] || rhead=""
    [ -z "$heal_c" ] || rhead=""
    case "$note" in *[!a-zA-Z0-9\ ._-]*) note=none ;; esac
    [ "$note" = none ] || echo "fm-test-queue: $note on $host" >&2
    # Only a private directory minted by this protocol may ever be removed.
    # A validation failure still holds this attempt's mirror lock: release it
    # through the deterministic remote cache path before trying another host.
    valid=1
    case "$dir" in /tmp/fm-test-offload.*) ;; *) valid=0 ;; esac
    case "$cache" in /*/.cache/firstmate/test-mirrors/"$key") ;; *) valid=0 ;; esac
    case "$dir$cache" in *[!a-zA-Z0-9/._-]*) valid=0 ;; esac
    if [ "$valid" = 0 ]; then
      remote_ssh "$host" "$(remote_lock_release "\"\$HOME/.cache/firstmate/test-mirrors/$key\"")" </dev/null >/dev/null 2>&1 || true
      continue
    fi
    REMOTE_HOST=$host REMOTE_DIR=$dir REMOTE_CACHE=$cache
    rm -rf "$REMOTE_LOCAL/stage/delta.pack" "$REMOTE_LOCAL/stage/cold.git" "$REMOTE_LOCAL/cold-repo"
    git_mode=""
    if [ "$rhead" = "$local_head" ]; then
      git_mode=same
    elif [ -n "$rhead" ] && remote_stage_git_delta "$root" "$rhead" "$local_head" "$REMOTE_LOCAL/stage/delta.pack"; then
      git_mode='delta'
    else
      git_mode=cold
      if ! git clone -q --depth=1 --no-checkout "file://$root" "$REMOTE_LOCAL/cold-repo" >/dev/null 2>&1 ||
        ! git -C "$REMOTE_LOCAL/cold-repo" read-tree HEAD ||
        ! mv "$REMOTE_LOCAL/cold-repo/.git" "$REMOTE_LOCAL/stage/cold.git"; then
        remote_cleanup
        return 1
      fi
      rm -rf "$REMOTE_LOCAL/cold-repo"
    fi
    # The small stage (manifest, queue scripts, Git objects) always syncs by
    # checksum: a stale manifest of equal size and second must not be skipped.
    echo "fm-test-queue: syncing snapshot delta to $host" >&2
    if { [ ! -s "$REMOTE_LOCAL/files" ] || rsync "-a$heal_c" --force --files-from="$REMOTE_LOCAL/files" --from0 --no-whole-file -z -e "$transport" "$root/" "$host:$cache/snapshot/repo/" >/dev/null 2>&1; } &&
      { [ ! -s "$REMOTE_LOCAL/recent_files" ] || rsync -ac --force --files-from="$REMOTE_LOCAL/recent_files" --from0 --no-whole-file -z -e "$transport" "$root/" "$host:$cache/snapshot/repo/" >/dev/null 2>&1; } &&
      rsync -ac --no-whole-file -z -e "$transport" "$REMOTE_LOCAL/stage/" "$host:$cache/snapshot/" >/dev/null 2>&1 &&
      remote_ssh "$host" "python3 -c $(remote_quote "$finalize") $(remote_quote "$cache") $(remote_quote "$dir") $(remote_quote "$git_mode") $(remote_quote "$local_head") $(remote_quote "$local_tree") $(remote_quote "$manifest_sha") && cd $(remote_quote "$dir/repo$rel") && $(remote_lock_release "$(remote_quote "$cache")")" </dev/null >/dev/null 2>&1; then
      REMOTE_CACHE=""
      rm -f "$heal_marker"
      REMOTE_ROOT="$dir/repo"
      REMOTE_CWD="$REMOTE_ROOT$rel"
      LOCAL_ROOT=$root
      echo "fm-test-queue: offloading to $host (verified snapshot of $root)" >&2
      return 0
    fi
    : > "$heal_marker" 2>/dev/null || true
    remote_ssh "$host" "rm -rf -- $(remote_quote "$dir"); $(remote_lock_release "$(remote_quote "$cache")")" </dev/null >/dev/null 2>&1 || true
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
