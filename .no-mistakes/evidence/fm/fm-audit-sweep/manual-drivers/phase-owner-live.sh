#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ
exec >"$E/herdr-live-pid-retention.log" 2>&1
H=$PWD/bin/fm-herdr-lab.sh
ROOT=$($H fixture create)
sleep 600 &
PID=$!
cleanup() {
 rc=$?
 kill -TERM "$PID" 2>/dev/null || true
 wait "$PID" 2>/dev/null || true
 "$H" fixture cleanup "$ROOT" || rc=1
 echo "FINAL_EXIT_STATUS: $rc"
 exit "$rc"
}
trap cleanup EXIT
START=$(LC_ALL=C ps -p "$PID" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
TOKEN=$(cat "$ROOT/.fm-herdr-owned")
printf 'schema=fm-herdr-owned-xdg.v1\nxdg_root=%s\nmarker_token=%s\npid=%s\npid_start=%s\n' "$ROOT" "$TOKEN" "$PID" "$START" > "$ROOT/owned.record"
BEFORE=$(cat "$ROOT/owned.record")
rc=0
"$H" fixture start "$ROOT" || rc=$?
echo "fixture start exit=$rc"
[ "$rc" = 1 ]; [ "$(cat "$ROOT/owned.record")" = "$BEFORE" ]; kill -0 "$PID"
rc=0
"$H" fixture cleanup "$ROOT" || rc=$?
echo "fixture cleanup exit=$rc"
[ "$rc" = 1 ]; [ -d "$ROOT" ]; kill -0 "$PID"
cat "$ROOT/owned.record"
echo 'OBSERVED: an identity-unproven live process with matching recorded start time was neither forgotten nor signalled; cleanup preserved its fixture until the child was stopped.'
