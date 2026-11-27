#!/usr/bin/env bash
# Refusal paths for refinements 3 (published context grants no authority) and
# 4 (bounded adoption). Each variant runs machine-b-adopt.sh against a fresh
# receiver home and must be refused with exit 3 and publish nothing.
#
# Usage: negative-checks.sh GOOD_BUNDLE_DIR
# Env:   VFS_BIN, FIXTURE_ROOT
set -euo pipefail
GOOD="${1:?usage: negative-checks.sh GOOD_BUNDLE_DIR}"
MACHINE=B-neg
. "$(dirname "$0")/lib.sh"
WORK="$FIXTURE_ROOT/state/negative"
rm -rf "$WORK"; mkdir -p "$WORK"

resum() { ( cd "$1" && : > SHA256SUMS.new && for f in artifact.db base.bundle expected-state.txt pack-manifest.json transfer.json; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f" >> SHA256SUMS.new; done && mv SHA256SUMS.new SHA256SUMS ); }

# expect_refused NAME BUNDLE [POLICY_FILE]
expect_refused() {
    local name="$1" bundle="$2" policy="${3:-$FIXTURE_DIR/receiver-policy.env}" home="$WORK/home-$1" rc
    set +e
    POLICY_FILE="$policy" HOME_B="$home" MACHINE="B-neg-$name" "$FIXTURE_DIR/machine-b-adopt.sh" "$bundle" \
        > "$EVIDENCE_DIR/neg-$name.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" = 3 ] && [ -z "$(ls -A "$home/.vfs/run" 2>/dev/null)" ]; then
        check "N-$name" PASS "refused (exit 3), nothing adopted"
    else
        check "N-$name" FAIL "exit $rc; see neg-$name.log"
    fi
}

variant() { rm -rf "$WORK/$1"; cp -R "$GOOD" "$WORK/$1"; echo "$WORK/$1"; }

# N1: the bundle claims authority and names a session outside local policy.
# The sender can recompute every checksum, so integrity alone must not decide.
v="$(variant authority-claim)"
sed -i.bak 's/"sessionId":"[^"]*"/"sessionId":"evil-takeover","authority":"merge","grants":["adopt-any","yolo"]/' "$v/transfer.json"
rm -f "$v/transfer.json.bak"; resum "$v"
expect_refused authority-claim "$v"

# N2: instructions shipped inside the session content are data, never policy:
# the policy file is the only input that changes the decision. Same good
# bundle, stricter local policy -> refused.
p="$WORK/strict-size.env"; sed 's/^MAX_ARTIFACT_BYTES=.*/MAX_ARTIFACT_BYTES=1024/' "$FIXTURE_DIR/receiver-policy.env" > "$p"
expect_refused oversize "$GOOD" "$p"

# N3: adoption count bound.
p="$WORK/strict-count.env"; sed 's/^MAX_ADOPTED_SESSIONS=.*/MAX_ADOPTED_SESSIONS=0/' "$FIXTURE_DIR/receiver-policy.env" > "$p"
expect_refused count-bound "$GOOD" "$p"

# N4: one flipped byte in the artifact without updated checksums.
v="$(variant tampered)"
printf '\xff' | dd of="$v/artifact.db" bs=1 seek=200000 conv=notrunc 2>/dev/null
expect_refused tampered "$v"

# N5: checksums recomputed but transfer.json still names the original digest.
v="$(variant digest-mismatch)"
printf '\xff' | dd of="$v/artifact.db" bs=1 seek=200000 conv=notrunc 2>/dev/null
resum "$v"
expect_refused digest-mismatch "$v"

# N6: a hidden, unpublished transfer directory is never adopted.
v="$WORK/.incoming-partial"; rm -rf "$v"; cp -R "$GOOD" "$v"
expect_refused unpublished "$v"

# N7: disallowed sender OS.
v="$(variant sender-os)"
sed -i.bak 's/"senderOs":"[^"]*"/"senderOs":"Windows"/' "$v/transfer.json"; rm -f "$v/transfer.json.bak"; resum "$v"
expect_refused sender-os "$v"
