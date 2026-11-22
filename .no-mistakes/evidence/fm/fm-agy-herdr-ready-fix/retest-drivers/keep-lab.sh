#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-agy-retest
H=$ROOT/bin/fm-herdr-lab.sh
E=~/.no-mistakes/evidence/01M8101Q8Q67QA7N3HWCG4M2M2
export FM_HERDR_LAB_STATE_DIR=$D/lab-state
X=$(cat "$D/xdg-root")
eval "$($H fixture apply "$X")"
S=$(cat "$D/session")
cleanup() {
 set +e
 $H teardown "$S" > "$E/retest-teardown.log" 2>&1
 a=$?
 $H fixture cleanup "$X" >> "$E/retest-teardown.log" 2>&1
 b=$?
 printf 'teardown_exit=%s fixture_cleanup_exit=%s\n' "$a" "$b" >> "$E/retest-teardown.log"
}
trap cleanup EXIT
$H fixture check "$X"
$H provision "$S"
$H viewer start "$S"
$H run "$S" workspace create --cwd "$D/fmhome/projects/scratch" --label agy-probe --no-focus > "$D/pane.json"
P=$(jq -r '.result.root_pane.pane_id' "$D/pane.json")
printf '%s\n' "$P" > "$D/probe-pane"
AGY=$(command -v agy)
$H run "$S" pane run "$P" "HOME='$D/home' /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/probe-cli.log' --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
printf 'LAB_READY session=%s pane=%s\n' "$S" "$P"
while [ ! -f "$D/finish" ]; do sleep 1; done
