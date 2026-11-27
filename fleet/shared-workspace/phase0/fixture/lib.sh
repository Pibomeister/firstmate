#!/usr/bin/env bash
# Shared helpers for the Phase 0 stopped-session fixture.
# Portable to macOS bash 3.2 and Linux bash; no python, no jq.

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VFS_BIN:?set VFS_BIN to the pinned vfs binary (see scripts/pin-vfs.sh)}"
: "${FIXTURE_ROOT:?set FIXTURE_ROOT (for example /srv/factory-vfs-pilot)}"
SESSION_ID="${SESSION_ID:-p0-stopped-1}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$FIXTURE_ROOT/evidence}"
FIXTURE_CAP_BYTES="${FIXTURE_CAP_BYTES:-10737418240}"   # 10 GiB cap

mkdir -p "$FIXTURE_ROOT"/bases "$FIXTURE_ROOT"/state "$FIXTURE_ROOT"/mount \
         "$FIXTURE_ROOT"/outbox "$FIXTURE_ROOT"/artifacts "$EVIDENCE_DIR"

CHECKS_FILE="$EVIDENCE_DIR/checks.tsv"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

# check ID RESULT DETAIL  -> appends one TSV row; RESULT is PASS, FAIL, SKIP or REFUSED.
check() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MACHINE:-?}" "$1" "$2" "$3" >> "$CHECKS_FILE"
    log "check $1: $2 - $3"
    if [ "$2" = FAIL ] && [ "${KEEP_GOING:-0}" != 1 ]; then exit 1; fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
size_of() { wc -c < "$1" | tr -d ' '; }

# jget KEY  - read a top-level string/number/bool field from one-line JSON on stdin.
jget() {
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p; t; s/.*\"$1\":\([-0-9.a-z]*\).*/\1/p" | head -n1
}

# vfs_as HOME BASE ARGS...  - run vfs as one "machine": its own HOME, cwd BASE.
vfs_as() {
    local home="$1" base="$2"; shift 2
    mkdir -p "$home/.cache" "$home/.config" "$home/.local"
    ( cd "$base" && env -u VFS_REMOTE_URL -u VFS_KEY -u VFS_CIPHER \
        HOME="$home" XDG_CACHE_HOME="$home/.cache" XDG_CONFIG_HOME="$home/.config" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null VFS_FUSE_URING=0 \
        "$VFS_BIN" "$@" )
}

# mount_capable  - true when this host can mount a vfs run session.
mount_capable() {
    case "$(uname -s)" in
        Linux)  [ -e /dev/fuse ] && command -v fusermount3 >/dev/null 2>&1 ;;
        Darwin) [ -x /sbin/mount_nfs ] && [ -x /usr/bin/sandbox-exec ] ;;
        *) return 1 ;;
    esac
}

# The sample session's base: a deterministic repo, so machine A and B derive
# the same commit independently (the transfer also ships a git bundle).
make_base() {
    local dir="$1"
    rm -rf "$dir"; mkdir -p "$dir"
    (
        cd "$dir"
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
        export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
        export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
        git init -q -b main .
        mkdir -p src
        printf 'phase0 fixture\n' > README.md
        printf 'line 1\n' > src/app.txt
        printf 'notes v1\n' > notes.txt
        printf 'to be deleted\n' > old.txt
        printf 'build/\n' > .gitignore
        git add -A
        git commit -q -m 'fixture base'
        git rev-parse HEAD
    )
}

# Work done inside the session on machine A. Inline (not a script file) so the
# macOS Seatbelt read scope never has to cover the fixture directory.
SESSION_WORK='set -e
mkdir -p docs && printf "local commit\n" > docs/plan.txt
git add docs/plan.txt
git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "local commit in session"
printf "staged change\n" >> src/app.txt && git add src/app.txt
printf "unstaged change\n" >> notes.txt
rm old.txt
printf "scratch\n" > untracked.txt
mkdir -p build && printf "ignored build output\n" > build/out.bin'

# State dump compared between machines (content-based, stat-independent).
STATE_DUMP='git status --porcelain=v1 --untracked-files=all
echo "--log"; git log --format="%H %s"
echo "--staged"; git diff --cached --name-status
echo "--blobs"; for f in README.md src/app.txt notes.txt docs/plan.txt untracked.txt; do printf "%s %s\n" "$f" "$(git hash-object "$f")"; done
echo "--absent"; for f in old.txt; do [ -e "$f" ] && echo "present $f" || echo "absent $f"; done'
