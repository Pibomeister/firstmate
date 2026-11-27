#!/usr/bin/env bash
# Refinement 1: a crash mid-publish leaves no half-published state.
# SIGKILLs vfs pack, vfs adopt and transfer.sh at a spread of delays, then
# checks what an observer sees afterwards: either the old state or the
# complete new state, never a partial one, and the next run recovers.
#
# Env: VFS_BIN, FIXTURE_ROOT, [CRASH_DELAYS]
set -euo pipefail
MACHINE=crash
. "$(dirname "$0")/lib.sh"
DELAYS="${CRASH_DELAYS:-0 0.002 0.005 0.01 0.02 0.04 0.08 0.15 0.3}"
WORK="$FIXTURE_ROOT/state/crash"
SID=p0-crash-1
rm -rf "$WORK"; mkdir -p "$WORK"
mount_capable || { check C-all SKIP "needs a mount-capable host to create the crash session"; exit 0; }

# tree PID -> PID and all descendants.
tree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }

# kill_after SECONDS CMD... -> runs CMD, SIGKILLs its whole process tree
# (including the vfs process under any wrapper shell) after SECONDS.
# Portable: macOS has no timeout(1).
kill_after() {
    local d="$1"; shift
    "$@" > /dev/null 2>&1 &
    local pid=$! pids
    sleep "$d"
    if kill -0 "$pid" 2>/dev/null; then
        pids="$(tree "$pid")"
        kill -STOP $pids 2>/dev/null || true
        kill -KILL $pids 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo killed
    else
        wait "$pid" 2>/dev/null && echo completed || echo exited-nonzero
    fi
}

HOME_C="$WORK/home-sender"; BASE_C="$WORK/base"
PIN="$(make_base "$BASE_C" | tail -n1)"
vfs_as "$HOME_C" "$BASE_C" run --session "$SID" --seed-pin "$PIN" -- sh -c "$SESSION_WORK" > "$WORK/run.log" 2>&1

# C1: kill pack at each delay.
killed=0; completed=0; bad=0
for d in $DELAYS; do
    out="$WORK/pack-$d.db"
    r="$(kill_after "$d" vfs_as "$HOME_C" "$BASE_C" pack "$SID" --output "$out")"
    [ "$r" = killed ] && killed=$((killed+1)) || completed=$((completed+1))
    st="$(vfs_as "$HOME_C" "$BASE_C" status "$SID" --json 2>&1 || true)"
    case "$(echo "$st" | jget state)" in stopped|stale-recovered) ;; *) bad=1; log "pack d=$d status: $st" ;; esac
    vfs_as "$HOME_C" "$BASE_C" integrity "$HOME_C/.vfs/run/$SID/delta.db" --json > /dev/null 2>&1 \
        || { bad=1; log "pack d=$d: live delta failed integrity"; }
    if [ -e "$out" ]; then
        vfs_as "$HOME_C" "$BASE_C" integrity "$out" --json > /dev/null 2>&1 \
            || { bad=1; log "pack d=$d: partial --output artifact visible at $out"; }
    fi
done
final="$(vfs_as "$HOME_C" "$BASE_C" pack "$SID" --output "$WORK/final.db")" || bad=1
[ "$(sha256_of "$WORK/final.db")" = "$(echo "$final" | jget dbSha256)" ] || bad=1
[ "$bad" = 0 ] && check C1-pack-kill PASS "$killed killed, $completed completed; session always stopped/recovered, no partial artifact, final pack ok" \
    || check C1-pack-kill FAIL "$killed killed, $completed completed; see log"

# C2: kill adopt at each delay; the session must be absent or complete.
killed=0; completed=0; bad=0; leftovers=0
for d in $DELAYS; do
    h="$WORK/home-recv-$d"; b="$WORK/recv-base-$d"
    rm -rf "$b"; GIT_CONFIG_GLOBAL=/dev/null git clone -q "$BASE_C" "$b"
    r="$(kill_after "$d" vfs_as "$h" "$b" adopt "$SID" --db "$WORK/final.db" --base "$b")"
    [ "$r" = killed ] && killed=$((killed+1)) || completed=$((completed+1))
    sd="$h/.vfs/run/$SID"
    if [ -e "$sd/delta.db" ]; then
        st="$(vfs_as "$h" "$b" status "$SID" --json 2>&1 || true)"
        [ "$(echo "$st" | jget state)" = stopped ] || { bad=1; log "adopt d=$d published but status: $st"; }
        vfs_as "$h" "$b" integrity "$sd/delta.db" --json > /dev/null 2>&1 || { bad=1; log "adopt d=$d: published delta corrupt"; }
    else
        [ -e "$sd" ] && leftovers=$((leftovers+1))
        # Not published: a clean retry must succeed.
        vfs_as "$h" "$b" adopt "$SID" --db "$WORK/final.db" --base "$b" > /dev/null 2>&1 \
            || { bad=1; log "adopt d=$d: retry after crash failed"; }
    fi
done
[ "$bad" = 0 ] && check C2-adopt-kill PASS "$killed killed, $completed completed; never half-published; $leftovers unpublished session dir(s) left, retry recovered each" \
    || check C2-adopt-kill FAIL "$killed killed, $completed completed; see log"

# C3: transfer publication. A hidden partial copy is ignored and replaced.
dest="$WORK/inbox"; mkdir -p "$dest/.incoming-p0-x"; printf 'partial' > "$dest/.incoming-p0-x/artifact.db"
src="$FIXTURE_ROOT/outbox/$SESSION_ID"
if [ -d "$src" ]; then
    killed=0; bad=0
    for d in $DELAYS; do
        rm -rf "$dest/$SESSION_ID"
        r="$(kill_after "$d" "$FIXTURE_DIR/transfer.sh" "$src" "$dest")"
        [ "$r" = killed ] && killed=$((killed+1))
        if [ -d "$dest/$SESSION_ID" ]; then
            ( cd "$dest/$SESSION_ID" && while read -r want f; do [ "$(sha256_of "$f")" = "$want" ] || exit 1; done < SHA256SUMS ) \
                || { bad=1; log "transfer d=$d: published bundle incomplete"; }
        fi
    done
    rm -rf "$dest/$SESSION_ID"; "$FIXTURE_DIR/transfer.sh" "$src" "$dest" > /dev/null || bad=1
    [ "$bad" = 0 ] && check C3-transfer-kill PASS "$killed killed; a published bundle was always complete; rerun published cleanly" \
        || check C3-transfer-kill FAIL "see log"
else
    check C3-transfer-kill SKIP "no outbox bundle; run machine-a-pack.sh first"
fi
