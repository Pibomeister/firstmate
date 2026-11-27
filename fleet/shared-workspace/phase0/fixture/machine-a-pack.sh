#!/usr/bin/env bash
# Machine A: create the tiny sample session, stop it, pack it, and publish a
# transfer bundle into $FIXTURE_ROOT/outbox/<session> (atomic directory rename).
#
# Env: VFS_BIN, FIXTURE_ROOT, [SESSION_ID], [MACHINE=A]
set -euo pipefail
MACHINE="${MACHINE:-A}"
. "$(dirname "$0")/lib.sh"

HOME_A="$FIXTURE_ROOT/state/home-a"
BASE_A="$FIXTURE_ROOT/bases/a-base"
OUT="$FIXTURE_ROOT/outbox/$SESSION_ID"
STAGE="$FIXTURE_ROOT/outbox/.staging-$SESSION_ID-$$"

[ ! -e "$OUT" ] || die "outbox already has $OUT; remove it (cleanup.sh) to rerun"
[ ! -e "$HOME_A/.vfs/run/$SESSION_ID" ] || die "session $SESSION_ID already exists on A; run cleanup.sh"
mount_capable || die "machine A must be able to mount a vfs session (FUSE on Linux, NFS+Seatbelt on macOS)"

"$VFS_BIN" version --json > "$EVIDENCE_DIR/a-version.json"
log "vfs on A: $(cat "$EVIDENCE_DIR/a-version.json")"

PIN="$(make_base "$BASE_A" | tail -n1)"
check A-base-pin PASS "deterministic base at $PIN"

# A1: create + seed + do the work in one atomic run (vfs run --seed-pin).
vfs_as "$HOME_A" "$BASE_A" run --session "$SESSION_ID" --seed-pin "$PIN" -- sh -c "$SESSION_WORK" \
    > "$EVIDENCE_DIR/a-run.log" 2>&1 || die "session work failed (see a-run.log)"
check A-session-work PASS "session $SESSION_ID created and worked under vfs run"

# A2: the host base must be untouched (copy-on-write).
if [ -z "$(git -C "$BASE_A" status --porcelain)" ] && [ -e "$BASE_A/old.txt" ] && [ ! -e "$BASE_A/untracked.txt" ]; then
    check A-host-untouched PASS "base checkout clean; all writes landed in the delta"
else
    check A-host-untouched FAIL "base checkout was modified: $(git -C "$BASE_A" status --porcelain | tr '\n' ' ')"
fi

# A3: expected state as seen inside the session.
vfs_as "$HOME_A" "$BASE_A" run --session "$SESSION_ID" -- sh -c "$STATE_DUMP" > "$EVIDENCE_DIR/a-state.txt" 2>> "$EVIDENCE_DIR/a-run.log"
vfs_as "$HOME_A" "$BASE_A" run --session "$SESSION_ID" -- sh -c 'test -e build/out.bin' 2>> "$EVIDENCE_DIR/a-run.log" \
    && check A-ignored-present PASS "build/out.bin exists in the A session before pack" \
    || check A-ignored-present FAIL "build/out.bin missing before pack"
log "A state:"; cat "$EVIDENCE_DIR/a-state.txt" >&2

# A4: stopped-session preflight.
STATUS="$(vfs_as "$HOME_A" "$BASE_A" status "$SESSION_ID" --json)"
echo "$STATUS" > "$EVIDENCE_DIR/a-status-prepack.json"
[ "$(echo "$STATUS" | jget state)" = stopped ] \
    && check A-stopped PASS "$STATUS" || check A-stopped FAIL "$STATUS"

# A5: pack into the staging dir (pack itself publishes with a no-replace link).
mkdir -p "$STAGE"
MANIFEST="$(vfs_as "$HOME_A" "$BASE_A" pack "$SESSION_ID" --output "$STAGE/artifact.db")"
echo "$MANIFEST" > "$STAGE/pack-manifest.json"
DB_SHA="$(echo "$MANIFEST" | jget dbSha256)"; DB_SIZE="$(echo "$MANIFEST" | jget dbSizeBytes)"
ART_VER="$(echo "$MANIFEST" | jget artifactVersion)"; GEN="$(echo "$MANIFEST" | jget generation)"
[ "$(sha256_of "$STAGE/artifact.db")" = "$DB_SHA" ] && [ "$(size_of "$STAGE/artifact.db")" = "$DB_SIZE" ] \
    && check A-pack-digest PASS "artifact sha256 $DB_SHA size $DB_SIZE generation $GEN v$ART_VER" \
    || check A-pack-digest FAIL "artifact bytes do not match pack manifest"
[ "$DB_SIZE" -lt "$FIXTURE_CAP_BYTES" ] || check A-cap FAIL "artifact exceeds fixture cap"

# A6: per-chunk digests over the published bytes.
CHUNK=4194304; i=0; bad=0
for want in $(echo "$MANIFEST" | sed 's/.*"chunks":\[\([^]]*\)\].*/\1/' | grep -o '"sha256":"[0-9a-f]*"' | cut -d'"' -f4); do
    got="$(dd if="$STAGE/artifact.db" bs=$CHUNK skip=$i count=1 2>/dev/null | { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; } | awk '{print $1}')"
    [ "$got" = "$want" ] || bad=1; i=$((i+1))
done
[ "$bad" = 0 ] && [ "$i" -ge 1 ] && check A-chunk-digests PASS "$i chunk(s) verified" || check A-chunk-digests FAIL "chunk digest mismatch"

# A7: after pack, the sender session is still stopped and re-packable.
STATUS2="$(vfs_as "$HOME_A" "$BASE_A" status "$SESSION_ID" --json)"
echo "$STATUS2" > "$EVIDENCE_DIR/a-status-postpack.json"
[ "$(echo "$STATUS2" | jget state)" = stopped ] && [ "$(echo "$STATUS2" | jget generation)" = "$GEN" ] \
    && check A-postpack-status PASS "$STATUS2" || check A-postpack-status FAIL "$STATUS2"

# A8: the base travels as a git bundle so B can build a pristine checkout at the pin.
git -C "$BASE_A" bundle create -q "$STAGE/base.bundle" HEAD main 2>/dev/null
cp "$EVIDENCE_DIR/a-state.txt" "$STAGE/expected-state.txt"

# transfer.json is descriptive data only. The receiver never takes authority
# from it (refinement 3); its own receiver-policy.env decides.
cat > "$STAGE/transfer.json" <<JSON
{"bundleVersion":1,"sessionId":"$SESSION_ID","basePin":"$PIN","artifact":"artifact.db","dbSha256":"$DB_SHA","dbSizeBytes":$DB_SIZE,"artifactVersion":"$ART_VER","generation":$GEN,"senderOs":"$(uname -s)","senderArch":"$(uname -m)","senderVfsCommit":"$("$VFS_BIN" version --json | jget commit)","createdAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
( cd "$STAGE" && for f in artifact.db base.bundle expected-state.txt pack-manifest.json transfer.json; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done ) > "$STAGE/SHA256SUMS"

# A9: publish the bundle: one rename is the commit point (refinement 1).
mv "$STAGE" "$OUT"
check A-bundle-published PASS "$OUT"
echo "$OUT"
