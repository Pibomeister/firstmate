#!/usr/bin/env bash
# Live drive of real bin/fm-on.sh with real /usr/bin/ssh against local closed/odd ports.
set -u
WT={run-worktree}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
mkdir -p "$LAB/data"
cat > "$LAB/data/secondmates.md" <<R
- ios - iOS delivery (host: 127.0.0.1; root: /opt/fmroot; home: /opt/fmhome; scope: iOS work; projects: alpha; added 2026-08-02)
R
WRAP="$LAB/ssh-wrap.sh"
cat > "$WRAP" <<'W'
#!/usr/bin/env bash
n=$(( $(cat "$LAB_DIR/count" 2>/dev/null || echo 0) + 1 )); echo $n > "$LAB_DIR/count"
echo "attempt $n at $(python3 -c 'import time;print(f"{time.time():.2f}")')" >> "$LAB_DIR/attempts"
mode=$(cat "$LAB_DIR/mode")
real() { exec /usr/bin/ssh -F /dev/null -p "$1" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "${@:2}"; }
case "$mode" in
  refused) real 1 "$@" ;;
  recover) if [ "$n" -lt 3 ]; then real 1 "$@"; else echo "remote-ok stdin=[$(cat)]"; exit 0; fi ;;
  banner) real "$(cat "$LAB_DIR/port")" "$@" ;;
  midsession) echo "partial-output"; echo "Read from remote host 127.0.0.1: Connection timed out" >&2; exit 255 ;;
  noroute) echo "packet_write_wait: Connection to 127.0.0.1 port 22: No route to host" >&2; exit 255 ;;
  remotefail) echo "fetch timed out: HTTP 503" >&2; exit 1 ;;
esac
W
chmod +x "$WRAP"
run() { # name mode [stdin]
  local name=$1 mode=$2; rm -f "$LAB/count" "$LAB/attempts"; echo "$mode" > "$LAB/mode"
  echo "=== $name (mode=$mode)"
  local t0=$(date +%s); local rc=0
  if [ $# -ge 3 ]; then
    printf '%s' "$3" | env FM_HOME="$LAB" LAB_DIR="$LAB" FM_SSH_BIN="$WRAP" FM_BLIP_RETRY_BASE_SECS=1 FM_BLIP_RETRY_CAP_SECS=4 FM_BLIP_RETRY_BUDGET_SECS=12 \
      "$WT/bin/fm-on.sh" --stdin ios fm-session-start.sh >"$LAB/out" 2>"$LAB/err" || rc=$?
  else
    env FM_HOME="$LAB" LAB_DIR="$LAB" FM_SSH_BIN="$WRAP" FM_BLIP_RETRY_BASE_SECS=1 FM_BLIP_RETRY_CAP_SECS=4 FM_BLIP_RETRY_BUDGET_SECS=12 \
      "$WT/bin/fm-on.sh" ios fm-session-start.sh </dev/null >"$LAB/out" 2>"$LAB/err" || rc=$?
  fi
  echo "exit=$rc wall=$(( $(date +%s) - t0 ))s"
  echo "-- attempts:"; cat "$LAB/attempts"
  echo "-- stdout:"; cat "$LAB/out"; echo "-- stderr:"; cat "$LAB/err"
}
run "S1 remote host down for the whole budget" refused
run "S2 blip recovers on 3rd attempt, stdin replayed" recover "payload-123"
python3 - "$LAB" <<'P' &
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",0)); s.listen(5)
open(sys.argv[1]+"/port","w").write(str(s.getsockname()[1]))
s.settimeout(20)
try:
  while True:
    c,_=s.accept(); c.sendall(b"SSH-2.0-OpenSSH_9.0\r\n"); c.close()
except Exception: pass
P
PY=$!; sleep 1
run "S3 connected then dropped before auth (real ssh)" banner
kill $PY 2>/dev/null; wait $PY 2>/dev/null
run "S4 mid-session drop after job may have run" midsession
run "S5 mid-session no-route drop" noroute
run "S6 remote command itself fails with timeout/503 text" remotefail
rm -rf "$LAB"
