#!/usr/bin/env bash
# Live drill: real tmux (private lab server), real launcher, lock and ack.
# Usage: drill.sh <mode: exit|parse|ack> <budget-secs>
set -u
ROOT=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M757BXABF34F8K58B6TH4BME
MODE=$1 BUDGET=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git init -q "$LAB"; : > "$LAB/AGENTS.md"
echo tmux > "$LAB/config/backend"
printf '# Live drill handoff\nRead this document.\n' > "$LAB/data/handoff.md"
mkdir -p "$LAB/fakebin"
# The successor "claude" the launcher starts through tmux argv.
cat > "$LAB/fakebin/claude" <<'S'
#!/usr/bin/env bash
export PROMPT_NONCE=$(printf %s "$2" | sed -n "s/.*nonce=\([0-9a-f]*\)$/\1/p")
echo "fake-successor ran argv=$# prompt_nonce=$PROMPT_NONCE" >> "$FM_HOME/succ-runs"
case "$(cat "$FM_HOME/mode")" in
  exit) exit 0 ;;
  parse) exec zsh -c ')' ;;
  ack) exec -a claude /bin/bash "$FM_HOME/succ.sh" ;;
  late) sleep $(( $(cat "$FM_HOME/budget") / 2 + 5 )); exec -a claude /bin/bash "$FM_HOME/succ.sh" ;;
esac
S
chmod +x "$LAB/fakebin/claude"
echo "$MODE" > "$LAB/mode"; echo "$BUDGET" > "$LAB/budget"
cat > "$LAB/succ.sh" <<'S'
n=$(cat "$FM_HOME/state/attempts" 2>/dev/null || echo 0); echo $((n+1)) > "$FM_HOME/state/attempts"
nonce=$PROMPT_NONCE; sha=$(shasum -a 256 "$FM_HOME/data/handoff.md" | cut -d" " -f1)
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$sha" > "$FM_HOME/ack.out" 2>&1; echo $? > "$FM_HOME/ack.rc"
echo $$ > "$FM_HOME/succ.pid"
sleep 600
S
cat > "$LAB/pred.sh" <<'S'
echo $$ > "$FM_HOME/pred.pid"
bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/lock.out" 2>&1
FM_TEST_SEAM=1 FM_HANDOFF_TEST_HARNESS=claude FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=$BUDGET \
  bash "$ROOT/bin/fm-handoff-launch.sh" "$FM_HOME/data/handoff.md" > "$FM_HOME/launch.out" 2>&1
echo $? > "$FM_HOME/rc"
sleep 900
S
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
T() { "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" "$@"; }
# Count fresh successor windows: tmux records each new-window.
start=$(date +%s)
T new-session -d -s primary -x 200 -y 50 -c "$LAB" sleep 3600
T set-option -g remain-on-exit on >/dev/null
for kv in "FM_HOME=$LAB" "ROOT=$ROOT" "PATH=$LAB/fakebin:$PATH"; do T set-environment -g "${kv%%=*}" "${kv#*=}"; done
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE ORCA_TERMINAL_HANDLE TERM_PROGRAM; do T set-environment -g -u "$v" 2>/dev/null; done
T new-window -t primary -c "$LAB" \
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u ORCA_TERMINAL_HANDLE -u TERM_PROGRAM \
  FM_HOME="$LAB" ROOT="$ROOT" BUDGET="$BUDGET" PATH="$LAB/fakebin:$PATH" \
  bash -c 'exec -a claude /bin/bash "$FM_HOME/pred.sh"'
echo "== live drill mode=$MODE budget=${BUDGET}s lab=$LAB tmux_socket_dir=$SOCK sha=$(git -C "$ROOT" rev-parse HEAD)"
limit=$((start + BUDGET + 120))
while [ ! -f "$LAB/rc" ] && [ "$(date +%s)" -lt "$limit" ]; do
  [ "$MODE" = ack ] && [ -f "$LAB/ack.rc" ] && [ ! -f "$LAB/locate.during" ] && { sleep 1; FM_HOME="$LAB" bash "$ROOT/bin/fm-captain-locate.sh" > "$LAB/locate.during" 2>&1; }
  sleep 1
done
end=$(date +%s)
echo "launcher_rc=$(cat "$LAB/rc" 2>/dev/null || echo TIMEOUT) elapsed=$((end-start))s"
echo "-- predecessor pid=$(cat "$LAB/pred.pid") lock_line1=$(head -1 "$LAB/state/.lock")"
echo "-- tmux windows on private server:"; T list-windows -a -F '#{session_name}:#{window_index} #{window_name} dead=#{pane_dead} status=#{pane_dead_status} cmd=#{pane_start_command}' | cut -c1-200
echo "-- launcher output (events + stderr):"; cat "$LAB/launch.out"
echo "-- state/handoff-events.log:"; cat "$LAB/state/handoff-events.log" 2>/dev/null
[ -f "$LAB/ack.out" ] && { echo "-- successor ack output:"; cat "$LAB/ack.out"; }
echo "-- fake successor runs:"; cat "$LAB/succ-runs" 2>/dev/null
[ -f "$LAB/locate.during" ] && { echo "-- locate right after ack:"; cat "$LAB/locate.during"; }
echo "-- captain locate now:"; FM_HOME="$LAB" bash "$ROOT/bin/fm-captain-locate.sh"; echo "locate_rc=$?"
[ -f "$LAB/state/.handoff-successor" ] && { echo "-- .handoff-successor:"; cat "$LAB/state/.handoff-successor"; }
ls "$LAB/data"/handoff-ack-*.json >/dev/null 2>&1 && { echo "-- ack file:"; cat "$LAB/data"/handoff-ack-*.json; }
T kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB"; rm -rf "$LAB"
echo "== cleaned up lab"
