#!/usr/bin/env bash
# Live scenario: real fm-test-queue.sh offloads a full copy of the firstmate tree
# to a disposable localhost "remote" (ssh shim execs bash locally; real rsync).
set -u
W={run-worktree}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-v4-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fakebin" "$T/spool" "$T/repo"
# Reuse the suite's own SSH/rsync shim definition.
eval "$(sed -n '/^fake_remote_ssh() {/,/^}/p' "$W/tests/fm-test-queue.test.sh")"
fake_remote_ssh "$T/fakebin/ssh"
export SSH_LOG="$T/ssh.log" FM_TEST_QUEUE_DIR="$T/spool" FM_TEST_QUEUE_LOAD_FILE="$T/load"
echo 9 > "$T/load"; echo 1 > "$T/remote-load"
printf 'slots=1\nload_ceiling=150\nremote_hosts=m3\n' > "$T/spool/config"
git -C "$W" archive HEAD | tar -x -C "$T/repo"
cd "$T/repo"
git init -q; git remote add origin https://example.invalid/owner/firstmate.git
git add -A; git -c user.name=T -c user.email=t@example.invalid commit -qm base
echo "tree size: $(du -sh . | cut -f1), tracked files: $(git ls-files | wc -l | tr -d ' ')"
export PATH="$T/fakebin:$PATH"
s=$(date +%s); out=$(bash "$W/bin/fm-test-queue.sh" run -- sh -c 'git rev-parse --short HEAD; ls bin | wc -l' 2>"$T/cold.err"); rc=$?
echo "COLD rc=$rc elapsed=$(( $(date +%s)-s ))s out=[$(echo $out)]"; grep -E 'offload|remote' "$T/cold.err"
# Commit a change, plus an uncommitted edit, a deletion and an untracked file.
echo '# v4 live marker' >> README.md; git -c user.name=T -c user.email=t@example.invalid commit -qam advance
echo 'uncommitted-edit' > docs/v4-live-untracked.txt; git rm -q --cached CONTRIBUTING.md; rm CONTRIBUTING.md
echo 'edited' >> AGENTS.md
: > "$SSH_LOG.rsync"
s=$(date +%s); out=$(bash "$W/bin/fm-test-queue.sh" run -- sh -c 'printf "head=%s untracked=%s deleted=%s agents_tail=%s readme_tail=%s" "$(git rev-parse --short HEAD)" "$(cat docs/v4-live-untracked.txt)" "$([ -e CONTRIBUTING.md ] && echo present || echo absent)" "$(tail -1 AGENTS.md)" "$(tail -1 README.md)"' 2>"$T/warm.err"); rc=$?
echo "WARM rc=$rc elapsed=$(( $(date +%s)-s ))s local_head=$(git rev-parse --short HEAD)"; echo "WARM out=[$out]"; grep -E 'offload|remote' "$T/warm.err"
echo "warm rsync transferred:"; grep -E 'Literal data|Total transferred file size|Number of regular files transferred' "$SSH_LOG.rsync"
# Adversarial: mismatch before start must run locally.
s=$(date +%s); out=$(CORRUPT_SNAPSHOT=1 bash "$W/bin/fm-test-queue.sh" run -- pwd 2>"$T/mm.err"); rc=$?
echo "MISMATCH rc=$rc ran_in=[$out] local=[$(pwd -P)]"; grep -E 'no remote|offload' "$T/mm.err"
# Adversarial: uncertain remote exec must not re-run locally.
out=$(FAIL_EXEC=1 bash "$W/bin/fm-test-queue.sh" run -- sh -c 'touch "$1/ran-locally"' _ "$T" 2>"$T/unc.err"); rc=$?
echo "UNCERTAIN rc=$rc ran_locally=$([ -e "$T/ran-locally" ] && echo YES || echo no)"; grep -E 'uncertain' "$T/unc.err"
