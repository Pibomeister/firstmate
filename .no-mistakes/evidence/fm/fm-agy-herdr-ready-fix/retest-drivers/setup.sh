#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D=$ROOT/.test-agy-retest
E=~/.no-mistakes/evidence/01M8101Q8Q67QA7N3HWCG4M2M2
H=$ROOT/bin/fm-herdr-lab.sh
export FM_HERDR_LAB_STATE_DIR=$D/lab-state
X=$(cat "$D/xdg-root")
printf '%s\n' "$X" > "$D/xdg-root"
eval "$($H fixture apply "$X")"
$H fixture start "$X"
S=$(cat "$D/session")
printf '%s\n' "$S" > "$D/session"
$H teardown "$S"
$H provision "$S"
$H viewer start "$S"
$ROOT/bin/fm-lab-home.sh create "$D/fmhome"
mkdir -p "$D/fmhome/projects/scratch" "$D/pool"
git -C "$D/fmhome/projects/scratch" init -q
git -C "$D/fmhome/projects/scratch" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm init
cat > "$D/agy.sb" <<SB
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "$D") (subpath "$X") (subpath "/dev") (subpath "${TMPDIR:-/tmp}"))
SB
$H run "$S" workspace create --cwd "$D/fmhome/projects/scratch" --label agy-probe --no-focus > "$D/pane.json"
P=$(jq -r '.result.root_pane.pane_id' "$D/pane.json")
printf '%s\n' "$P" > "$D/probe-pane"
AGY=$(command -v agy)
$H run "$S" pane run "$P" "HOME='$D/home' /usr/bin/sandbox-exec -f '$D/agy.sb' '$AGY' --log-file '$D/probe-cli.log' --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
printf 'SETUP session=%s pane=%s fixture=%s\n' "$S" "$P" "$X"
