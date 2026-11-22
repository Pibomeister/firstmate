#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD D=$PWD/.test-agy-final
E=~/.no-mistakes/evidence/01M8101Q8Q67QA7N3HWCG4M2M2
H=$ROOT/bin/fm-herdr-lab.sh
export FM_HERDR_LAB_STATE_DIR=$D/lab-state
X=$($H fixture create)
printf '%s\n' "$X" > "$D/xdg-root"
eval "$($H fixture apply "$X")"
S=$($H name agy-final)
printf '%s\n' "$S" > "$D/session"
cleanup() {
 set +e
 $H teardown "$S" > "$E/final-teardown.log" 2>&1
 a=$?
 $H fixture cleanup "$X" >> "$E/final-teardown.log" 2>&1
 b=$?
 printf 'teardown_exit=%s fixture_cleanup_exit=%s\n' "$a" "$b" >> "$E/final-teardown.log"
}
trap cleanup EXIT
$H fixture start "$X"
$H fixture check "$X"
$H provision "$S"
$H viewer start "$S"
$ROOT/bin/fm-lab-home.sh create "$D/fmhome"
mkdir -p "$D/fmhome/projects/scratch" "$D/pool"
git -C "$D/fmhome/projects/scratch" init -q
git -C "$D/fmhome/projects/scratch" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm init
$H run "$S" workspace create --cwd "$D/fmhome/projects/scratch" --label agy-probe --no-focus > "$D/pane.json"
P=$(jq -r '.result.root_pane.pane_id' "$D/pane.json")
printf '%s\n' "$P" > "$D/probe-pane"
AGY=$(command -v agy)
$H run "$S" pane run "$P" "HOME='$D/home' /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/probe-cli.log' --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
printf 'LAB_READY session=%s pane=%s\n' "$S" "$P"
for ((i=0;i<2400;i++)); do [ ! -f "$D/finish" ] || exit 0; sleep 1; done
exit 2
