#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M7ZSQ6KCXZKNF16YKS1TEKEJ
exec >"$EVIDENCE/herdr-provision-live.log" 2>&1
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
REAL_HERDR=$(command -v herdr)
OWNED=$($LAB_HELPER fixture create)
LOCAL=$(mktemp -d "$ROOT/.phase-herdr.XXXXXX")
NAME=$($LAB_HELPER name audit-launch)
LATE=$($LAB_HELPER name audit-cancel)
export FM_HERDR_LAB_STATE_DIR=$LOCAL/tripwires
cleanup() {
  local rc=$?
  if [ -f "$FM_HERDR_LAB_STATE_DIR/$LATE.fleet-state.json" ]; then PATH=$ORIGINAL_PATH "$LAB_HELPER" teardown "$LATE" || rc=1; fi
  if [ -f "$FM_HERDR_LAB_STATE_DIR/$NAME.fleet-state.json" ]; then PATH=$ORIGINAL_PATH "$LAB_HELPER" teardown "$NAME" || rc=1; fi
  PATH=$ORIGINAL_PATH "$LAB_HELPER" fixture cleanup "$OWNED" || rc=1
  rm -rf "$LOCAL"
  echo "FINAL_EXIT_STATUS: $rc"
  exit "$rc"
}
ORIGINAL_PATH=$PATH
trap cleanup EXIT
printf 'Private fixture: %s\nNamed sessions: %s %s\n' "$OWNED" "$NAME" "$LATE"
eval "$("$LAB_HELPER" fixture apply "$OWNED")"
"$LAB_HELPER" fixture start "$OWNED"
# Deliberately inherited identities may not redirect the named-session launch.
HERDR_SOCKET_PATH=/nonexistent/wrong.sock HERDR_PANE_ID=wrong HERDR_TAB_ID=wrong HERDR_WORKSPACE_ID=wrong \
  "$LAB_HELPER" provision "$NAME"
"$LAB_HELPER" run "$NAME" status --json
"$LAB_HELPER" run "$NAME" workspace list
"$LAB_HELPER" teardown "$NAME"
echo 'OBSERVED: real named session provisioned despite unrelated inherited pane identity, then removed with fleet tripwire intact.'
mkdir "$LOCAL/bin"
export FM_PHASE_RELEASE=$LOCAL/release FM_PHASE_START_PID=$LOCAL/start.pid FM_PHASE_EXECUTED=$LOCAL/executed
export FM_PHASE_REAL_HERDR=$REAL_HERDR
cat > "$LOCAL/bin/herdr" <<'PY'
#!/usr/bin/python3
import os,sys,time
if len(sys.argv)>1 and sys.argv[1]=='server':
 with open(os.environ['FM_PHASE_START_PID'],'w') as f: f.write(str(os.getpid()))
 while not os.path.exists(os.environ['FM_PHASE_RELEASE']): time.sleep(.05)
 with open(os.environ['FM_PHASE_EXECUTED'],'w') as f: f.write('actual server launch released\n')
os.execv(os.environ['FM_PHASE_REAL_HERDR'],[os.environ['FM_PHASE_REAL_HERDR']]+sys.argv[1:])
PY
chmod +x "$LOCAL/bin/herdr"
rc=0
PATH="$LOCAL/bin:$PATH" "$LAB_HELPER" provision "$LATE" || rc=$?
echo "Delayed real-server provision exit: $rc"
[ "$rc" = 1 ]
pid=$(cat "$LOCAL/start.pid")
if kill -0 "$pid" 2>/dev/null; then echo 'FAIL: delayed launch still alive'; exit 1; fi
"$LAB_HELPER" teardown "$LATE"
touch "$LOCAL/release"
sleep 1
[ ! -e "$LOCAL/executed" ]
"$LAB_HELPER" run "$LATE" session list --json
[ ! -e "$FM_HERDR_LAB_STATE_DIR/$LATE.fleet-state.json" ]
echo 'OBSERVED: timed-out provision killed and reaped the delayed launch; release after teardown cannot launch a server; default tripwire unchanged.'
