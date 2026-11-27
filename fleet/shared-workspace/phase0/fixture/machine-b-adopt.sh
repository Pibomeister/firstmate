#!/usr/bin/env bash
# Machine B: verify a transferred bundle, apply the local receiver policy,
# build a pristine base at the pin, adopt, and verify the adopted session.
#
# Usage: machine-b-adopt.sh BUNDLE_DIR
# Env:   VFS_BIN, FIXTURE_ROOT, [POLICY_FILE], [MACHINE=B], [HOME_B]
# Exit:  0 adopted and verified; 3 refused by local policy; 1 any other failure.
set -euo pipefail
MACHINE="${MACHINE:-B}"
BUNDLE="${1:?usage: machine-b-adopt.sh BUNDLE_DIR}"
. "$(dirname "$0")/lib.sh"
POLICY_FILE="${POLICY_FILE:-$FIXTURE_DIR/receiver-policy.env}"
. "$POLICY_FILE"
HOME_B="${HOME_B:-$FIXTURE_ROOT/state/home-b}"
"$VFS_BIN" version --json > "$EVIDENCE_DIR/b-version.json"

refuse() { check "$1" REFUSED "$2"; exit 3; }

# B1: bundle integrity (published bundles only; hidden .incoming dirs ignored).
case "$(basename "$BUNDLE")" in .*) refuse B-bundle-published "refusing unpublished bundle $BUNDLE" ;; esac
if ( cd "$BUNDLE" && while read -r want file; do
        [ "$(sha256_of "$file")" = "$want" ] || exit 1; done < SHA256SUMS ); then
    check B-bundle-sums PASS "SHA256SUMS verified"
else
    refuse B-bundle-sums "bundle checksum mismatch"
fi
T="$(cat "$BUNDLE/transfer.json")"
SID="$(echo "$T" | jget sessionId)"; PIN="$(echo "$T" | jget basePin)"
DB_SHA="$(echo "$T" | jget dbSha256)"; DB_SIZE="$(echo "$T" | jget dbSizeBytes)"
ART_VER="$(echo "$T" | jget artifactVersion)"; SENDER_OS="$(echo "$T" | jget senderOs)"
GEN="$(echo "$T" | jget generation)"
PM_SHA="$(jget dbSha256 < "$BUNDLE/pack-manifest.json")"
if [ "$(sha256_of "$BUNDLE/artifact.db")" = "$DB_SHA" ] && [ "$PM_SHA" = "$DB_SHA" ]; then
    check B-artifact-digest PASS "$DB_SHA"
else
    refuse B-artifact-digest "artifact, transfer.json and pack manifest digests disagree"
fi

# B2: local policy gates (refinements 3 and 4). Fields in transfer.json that
# claim authority (for example "grants" or "authority") are never read.
echo "$SID" | grep -Eq "$ALLOW_SESSION_REGEX" || refuse B-policy-session "session id $SID not allowed by local policy"
echo "$SENDER_OS" | grep -Eq "$ALLOW_SENDER_OS_REGEX" || refuse B-policy-sender "sender OS $SENDER_OS not allowed"
[ "$DB_SIZE" -le "$MAX_ARTIFACT_BYTES" ] || refuse B-policy-size "artifact $DB_SIZE bytes > $MAX_ARTIFACT_BYTES"
held=0
[ -d "$HOME_B/.vfs/run" ] && held="$(find "$HOME_B/.vfs/run" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$held" -lt "$MAX_ADOPTED_SESSIONS" ] || refuse B-policy-count "already holding $held sessions (max $MAX_ADOPTED_SESSIONS)"
check B-policy PASS "session $SID, sender $SENDER_OS, $DB_SIZE bytes, $held held: within local policy"

# B3: version negotiation before adopt.
B_VER="$(cat "$EVIDENCE_DIR/b-version.json")"
B_ART="$(echo "$B_VER" | jget artifactVersion)"; B_MIN="$(echo "$B_VER" | jget minSupportedArtifactVersion)"
if awk -v a="$ART_VER" -v hi="$B_ART" -v lo="$B_MIN" 'BEGIN{exit !(a+0<=hi+0 && a+0>=lo+0)}'; then
    check B-version-floor PASS "artifact v$ART_VER within receiver [$B_MIN, $B_ART]"
else
    refuse B-version-floor "artifact v$ART_VER outside receiver [$B_MIN, $B_ART]"
fi

# B4: pristine base at the pin from the shipped bundle; an independent
# deterministic rebuild must reach the same commit.
BASE_B="$FIXTURE_ROOT/bases/b-base-$SID"
rm -rf "$BASE_B"
GIT_CONFIG_GLOBAL=/dev/null git clone -q "$BUNDLE/base.bundle" "$BASE_B"
HEAD_B="$(git -C "$BASE_B" rev-parse HEAD)"
[ "$HEAD_B" = "$PIN" ] && check B-base-at-pin PASS "$PIN" || check B-base-at-pin FAIL "bundle HEAD $HEAD_B != $PIN"
REBUILT="$(make_base "$FIXTURE_ROOT/bases/b-rebuild" | tail -n1)"
[ "$REBUILT" = "$PIN" ] && check B-base-deterministic PASS "independent rebuild reached $PIN" \
    || check B-base-deterministic FAIL "rebuild reached $REBUILT"

# B5: a base at another commit is refused before anything is published.
WRONG="$FIXTURE_ROOT/bases/b-wrong"
rm -rf "$WRONG"; GIT_CONFIG_GLOBAL=/dev/null git clone -q "$BUNDLE/base.bundle" "$WRONG"
( cd "$WRONG" && printf 'drift\n' > drift.txt && git add drift.txt &&
  GIT_CONFIG_GLOBAL=/dev/null git -c user.name=x -c user.email=x@example.invalid commit -q -m drift )
set +e; out="$(vfs_as "$HOME_B" "$WRONG" adopt "$SID" --db "$BUNDLE/artifact.db" --base "$WRONG" 2>&1)"; rc=$?; set -e
if [ "$rc" != 0 ] && [ ! -e "$HOME_B/.vfs/run/$SID/delta.db" ]; then
    check B-wrong-base-refused PASS "exit $rc, nothing published: $(echo "$out" | tail -n1)"
else
    check B-wrong-base-refused FAIL "exit $rc; session published on the wrong base"
fi

# B6: adopt onto the correct base.
ADOPT="$(vfs_as "$HOME_B" "$BASE_B" adopt "$SID" --db "$BUNDLE/artifact.db" --base "$BASE_B")"
echo "$ADOPT" > "$EVIDENCE_DIR/b-adopt.json"
[ "$(echo "$ADOPT" | jget basePin)" = "$PIN" ] && check B-adopt PASS "$ADOPT" || check B-adopt FAIL "$ADOPT"

# B7: adopted session is stopped, seeded, at the packed generation.
ST="$(vfs_as "$HOME_B" "$BASE_B" status "$SID" --json)"; echo "$ST" > "$EVIDENCE_DIR/b-status.json"
if [ "$(echo "$ST" | jget state)" = stopped ] && [ "$(echo "$ST" | jget seeded)" = true ] &&
   [ "$(echo "$ST" | jget generation)" = "$GEN" ]; then
    check B-status PASS "$ST"
else
    check B-status FAIL "$ST"
fi

# B8: SQLite/schema integrity and portability of the installed delta.
DB="$HOME_B/.vfs/run/$SID/delta.db"
if INTEG="$(vfs_as "$HOME_B" "$BASE_B" integrity "$DB" --json --require-portable 2>&1)"; then
    check B-integrity PASS "$(echo "$INTEG" | tr -s ' \n' ' ')"
else
    check B-integrity FAIL "$(echo "$INTEG" | tr -s ' \n' ' ')"
fi

# B9: offline content read straight from the delta (no mount needed, so this
# also runs on a receiver that cannot mount).
got="$(vfs_as "$HOME_B" "$BASE_B" fs "$DB" cat /untracked.txt 2>&1 || true)"
[ "$got" = scratch ] && check B-offline-read PASS "untracked.txt read from the delta without mounting" \
    || check B-offline-read FAIL "got: $got"

# B10: a second adopt of the same session id is refused.
set +e; out="$(vfs_as "$HOME_B" "$BASE_B" adopt "$SID" --db "$BUNDLE/artifact.db" --base "$BASE_B" 2>&1)"; rc=$?; set -e
[ "$rc" != 0 ] && check B-readopt-refused PASS "exit $rc: $(echo "$out" | tail -n1)" \
    || check B-readopt-refused FAIL "second adopt succeeded"

# B11: resume and compare the full working-tree state (needs a mount).
if mount_capable; then
    vfs_as "$HOME_B" "$BASE_B" run --session "$SID" -- sh -c "$STATE_DUMP" \
        > "$EVIDENCE_DIR/b-state.txt" 2> "$EVIDENCE_DIR/b-run.err" || true
    if diff -u "$BUNDLE/expected-state.txt" "$EVIDENCE_DIR/b-state.txt" > "$EVIDENCE_DIR/state.diff"; then
        check B-resume-state PASS "git status, log, index and blobs identical to machine A"
    else
        check B-resume-state FAIL "state differs; see state.diff"
    fi
    if vfs_as "$HOME_B" "$BASE_B" run --session "$SID" -- sh -c 'test ! -e build/out.bin' 2>> "$EVIDENCE_DIR/b-run.err"; then
        check B-ignored-pruned PASS "build/out.bin did not travel (default pack prune of build/**)"
    else
        check B-ignored-pruned FAIL "build/out.bin travelled"
    fi
    [ -z "$(git -C "$BASE_B" status --porcelain)" ] \
        && check B-host-untouched PASS "receiver base still pristine" || check B-host-untouched FAIL "receiver base modified"
else
    check B-resume-state SKIP "no mount on this host; pending a FUSE (Linux) or NFS (macOS) receiver"
fi
echo "adopted $SID into $HOME_B"
