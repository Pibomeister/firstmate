#!/usr/bin/env bash
set -eu
ROOT=$PWD
TMP=$ROOT/.test-phase-tmp/herdr-manual
mkdir -p "$TMP/bin" "$TMP/no-proc"
LAB=$ROOT/bin/fm-herdr-lab.sh
REAL_HERDR=$(command -v herdr)
owned=$($LAB fixture create)
name=fm-lab-audit-$$
late=fm-lab-late-$$
cleanup() {
  PATH=$NORMAL_PATH "$LAB" teardown "$late" >/dev/null 2>&1 || true
  PATH=$NORMAL_PATH "$LAB" teardown "$name" >/dev/null 2>&1 || true
  PATH=$NORMAL_PATH "$LAB" fixture cleanup "$owned"
}
NORMAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR=$TMP/tripwires
trap cleanup EXIT
$LAB fixture start "$owned"
eval "$($LAB fixture apply "$owned")"
printf 'Owned real Herdr server:\n'
$LAB fixture check "$owned"
cat "$owned/owned.record"
# An unavailable environment reader must preserve the live process receipt.
cp "$owned/owned.record" "$TMP/record-before"
rc=0
FM_PROC_ROOT_OVERRIDE=$TMP/no-proc FM_HERDR_LAB_PYTHON3_CANDIDATES=$TMP/no-python "$LAB" fixture start "$owned" || rc=$?
[ "$rc" = 1 ]
cmp "$owned/owned.record" "$TMP/record-before"
printf 'Unprovable ownership: start refused, live pid and receipt preserved.\n'
$LAB provision "$name"
$LAB run "$name" status --json
$LAB teardown "$name"
printf 'Named lab provision/run/teardown completed; default tripwire retained.\n'
export FM_DELAY_NAME=$late FM_DELAY_ROOT=$TMP FM_REAL_HERDR=$REAL_HERDR
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = server ] && [ "${3-}" = "$FM_DELAY_NAME" ]; then
  printf '%s\n' "$$" > "$FM_DELAY_ROOT/launcher.pid"
  while [ ! -e "$FM_DELAY_ROOT/release" ]; do sleep 0.1; done
fi
exec "$FM_REAL_HERDR" "$@"
EOF
chmod +x "$TMP/bin/herdr"
rc=0
PATH=$TMP/bin:$NORMAL_PATH "$LAB" provision "$late" || rc=$?
[ "$rc" = 1 ]
pid=$(cat "$TMP/launcher.pid")
! kill -0 "$pid" 2>/dev/null
$LAB teardown "$late"
touch "$TMP/release"
sleep 1
sessions=$($LAB run "$name" session list --json 2>/dev/null || true)
# A teardown removes the normal lab too; query through the helper's read-only
# session query using the still-valid fm-lab name in a fresh subshell.
. "$LAB"
sessions=$(fm_herdr_lab_raw "$late" session list --json)
printf '%s\n' "$sessions"
printf '%s' "$sessions" | jq -e --arg n "$late" '[.sessions[]? | select(.name==$n and .running==true)] | length==0' >/dev/null
printf 'Timed-out real launch pid %s was reaped before release; no late server appeared.\n' "$pid"
