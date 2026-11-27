#!/usr/bin/env bash
# Linux-only live leg (run after the stopped fixture qualifies).
# A session keeps running while `vfs checkpoint` publishes a consistent point
# to a file:// remote tier; machine B adopts from that tier, materializes it,
# and must see exactly the writes acknowledged before the checkpoint.
#
# This is not a durability or cross-machine continuation result: both homes
# share one host and the remote is a local directory.
#
# Env: VFS_BIN, FIXTURE_ROOT
set -euo pipefail
MACHINE=live
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Linux ] || { check L-all SKIP "live checkpoint leg is Linux-only (macOS supports stopped handoff only)"; exit 0; }
mount_capable || { check L-all SKIP "needs FUSE"; exit 0; }
WORK="$FIXTURE_ROOT/state/live"; REMOTE="$FIXTURE_ROOT/artifacts/remote"
rm -rf "$WORK" "$REMOTE"; mkdir -p "$WORK" "$REMOTE"
SID=p0-live-1
HA="$WORK/home-a"; HB="$WORK/home-b"; BA="$WORK/base-a"
PIN="$(make_base "$BA" | tail -n1)"

run_remote() {  # run_remote HOME BASE ARGS...
    local home="$1" base="$2"; shift 2
    mkdir -p "$home/.cache" "$home/.config" "$home/.local"
    ( cd "$base" && exec env HOME="$home" XDG_CACHE_HOME="$home/.cache" XDG_CONFIG_HOME="$home/.config" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null VFS_FUSE_URING=0 \
        VFS_REMOTE_URL="file://$REMOTE" VFS_REMOTE_STREAM_INTERVAL_MS=0 "$VFS_BIN" "$@" )
}

run_remote "$HA" "$BA" run --session "$SID" --seed-pin "$PIN" -- \
    sh -c 'printf "before\n" > before.txt; sleep 4; printf "after\n" > after.txt; sleep 30' \
    > "$WORK/run-a.log" 2>&1 &
APID=$!
trap 'kill -TERM $APID 2>/dev/null || true; wait $APID 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
    st="$(run_remote "$HA" "$BA" status "$SID" --json 2>/dev/null || true)"
    [ "$(echo "$st" | jget state)" = live ] && break; sleep 0.25
done
[ "$(echo "$st" | jget state)" = live ] && check L1-live PASS "$st" || check L1-live FAIL "session never went live: $st"
sleep 1.5

CP="$(run_remote "$HA" "$BA" checkpoint "$SID" --json 2>&1)" && check L2-checkpoint-live PASS "$CP" \
    || check L2-checkpoint-live FAIL "$CP"
st="$(run_remote "$HA" "$BA" status "$SID" --json 2>/dev/null || true)"
[ "$(echo "$st" | jget state)" = live ] && check L3-still-live PASS "checkpoint did not stop the session" \
    || check L3-still-live FAIL "$st"

BB="$WORK/base-b"; GIT_CONFIG_GLOBAL=/dev/null git clone -q "$BA" "$BB"
AD="$(run_remote "$HB" "$BB" adopt "$SID" --remote --base "$BB" 2>&1)" && check L4-adopt-remote PASS "$AD" \
    || check L4-adopt-remote FAIL "$AD"
DB="$HB/.vfs/run/$SID/delta.db"
M="$(run_remote "$HB" "$BB" materialize "$DB" --in-place 2>&1)" && check L5-materialize PASS "$(echo "$M" | tr '\n' ' ')" \
    || check L5-materialize FAIL "$M"
b="$(run_remote "$HB" "$BB" fs "$DB" cat /before.txt 2>&1 || true)"
a="$(run_remote "$HB" "$BB" fs "$DB" cat /after.txt 2>&1 || true)"
if [ "$b" = before ] && [ "$a" != after ]; then
    check L6-consistent-point PASS "write before the checkpoint present; later write absent"
else
    check L6-consistent-point FAIL "before='$b' after='$a'"
fi
run_remote "$HB" "$BB" integrity "$DB" --require-portable --json > /dev/null 2>&1 \
    && check L7-portable PASS "materialized delta is portable" || check L7-portable FAIL "not portable after materialize"
