#!/usr/bin/env bash
# Live quiet-supervision scenario on a disposable lab home + private tmux socket.
set -u
WT=/Users/eduardopicazo/.no-mistakes/worktrees/76ca871d9699/01M4Y9KN1ZX95V73Y3FR70EKKJ
E=/Users/eduardopicazo/.no-mistakes/evidence/01M4Y9KN1ZX95V73Y3FR70EKKJ
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null; pkill -f "FM_HOME=$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
NONCE="NONCE-$$-$RANDOM"
: > "$LAB/config/supervision-host-off"
printf 'osascript\ncommand:printf "%%s\\n" "$1" >> %s/alarm-record\n' "$LAB" > "$LAB/config/wedge-alarm"
step() { printf '\n=== %s ===\n' "$*"; }
# Run a firstmate command inside the lab tmux server (inherits $TMUX like the primary pane).
R() { local n=r$RANDOM; rm -f "$LAB/$n.done"; T new-session -d -s "$n" "cd $WT; FM_HOME=$LAB $* > $LAB/$n.out 2>&1; echo \$? > $LAB/$n.done"; for _ in $(seq 1 240); do [ -s "$LAB/$n.done" ] && break; sleep 0.5; done; ROUT=$(cat "$LAB/$n.out"); return "$(cat "$LAB/$n.done")"; }
step "1. real Claude primary on private fm-lab socket"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_MAX_DEFER_SECS=5 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=0 \
  tmux -L fm-lab new-session -d -x 160 -y 45 -s primary -c "$PWD" -e FM_HOME="$LAB" claude
for _ in $(seq 1 40); do T capture-pane -p -t primary | grep -q '>' && break; sleep 0.5; done
sleep 4
T capture-pane -p -t primary | grep -q "trust" && { T send-keys -t primary Down; sleep 0.5; T send-keys -t primary Enter; sleep 8; }
T capture-pane -p -t primary > "$E/live-primary-before.txt"
T capture-pane -p -t primary | grep -q "\? for shortcuts\|bypass\|accept edits\|^❯\|^> " || { echo "ABORT: Claude composer not live"; T capture-pane -p -t primary; exit 1; }
echo "claude composer live (pid tree under fm-lab primary)"
tail -8 "$E/live-primary-before.txt"
step "2. quiet entry + seeded actionable detail (aged 60s)"
FM_HOME=$LAB FM_AFK_MODE=quiet bin/fm-afk-launch.sh enter; echo "enter rc=$?"
printf 'blocked [key=%s]: task alpha needs captain detail payload\n' "$NONCE" > "$LAB/state/.subsuper-escalations"
echo $(( $(date +%s) - 60 )) > "$LAB/state/.subsuper-escalations.since"
seed_status() { printf 'window=lab:fm-repair-task\nbackend=tmux\nkind=ship\n' > "$LAB/state/repair-task.meta"; printf 'blocked [key=%s]: historical blocker\n' "$1" > "$LAB/state/repair-task.status"; }
seed_status historical
step "3. real launcher start (tmux backend, target = Claude primary)"
T new-session -d -s ctl -e FM_HOME="$LAB" "env FM_HOME=$LAB FM_AFK_MODE=quiet FM_SUPERVISOR_TARGET=primary:0 FM_SUPERVISOR_BACKEND=tmux bash bin/fm-afk-launch.sh start > $LAB/launch.out 2>&1; echo rc=\$? >> $LAB/launch.out; sleep 120"
for _ in $(seq 1 60); do [ -f "$LAB/state/.supervise-daemon.pid" ] && break; sleep 0.5; done
cat "$LAB/launch.out"; echo "afk flag: $(head -1 $LAB/state/.afk)"; echo "daemon pid: $(cat $LAB/state/.supervise-daemon.pid 2>/dev/null)"
sleep 20
step "4. after 20s of quiet supervision with aged backlog"
T capture-pane -p -t primary > "$E/live-primary-after.txt"
diff "$E/live-primary-before.txt" "$E/live-primary-after.txt" >/dev/null && echo "PRIMARY PANE UNCHANGED" || { echo "PRIMARY PANE CHANGED"; diff "$E/live-primary-before.txt" "$E/live-primary-after.txt"; }
grep -c "$NONCE" "$E/live-primary-after.txt" | sed 's/^/nonce occurrences in claude pane: /'
echo "buffer: $(cat $LAB/state/.subsuper-escalations)"
echo "wedge marker present: $([ -e $LAB/state/.subsuper-inject-wedged ] && echo yes || echo no)"
echo "--- alarm-record (command channel, same summary as osascript) ---"; cat "$LAB/alarm-record" 2>/dev/null
echo "--- daemon log ---"; cat "$LAB/state/.supervise-daemon.log"
grep -q "$NONCE" "$LAB/state/.supervise-daemon.log" "$LAB/alarm-record" 2>/dev/null && echo "RAW DETAIL LEAKED to log/alarm" || echo "raw detail absent from log and alarm"
step "5. quiet exit via fm-afk-return.sh with historical open blocker"
R bin/fm-afk-return.sh; rc=$?; out=$ROUT
printf '%s\n' "$out" | sed "s#$LAB#\$LAB#g"; echo "return rc=$rc"
echo "catchup gate: $([ -e $LAB/state/.afk-return-catchup ] && echo PRESENT || echo absent)"
echo "afk flag: $([ -e $LAB/state/.afk ] && echo present || echo absent); daemon pid file: $([ -e $LAB/state/.supervise-daemon.pid ] && echo present || echo absent)"
echo "blocker status: $(cat $LAB/state/repair-task.status)"
archive=$(jq -r .archive "$LAB/state/.quiet-exit-receipt"); echo "receipt: $(jq -c '{schema,count}' $LAB/state/.quiet-exit-receipt)"; echo "archive holds nonce: $(grep -c $NONCE "$archive")"
printf '%s' "$out" | grep -q "$NONCE" && echo "RAW DETAIL IN RETURN OUTPUT" || echo "return output carries receipt only"
R bin/fm-afk-return.sh guard; echo "guard rc after quiet exit=$?"
T capture-pane -p -t primary > "$E/live-primary-final.txt"
grep -c "$NONCE" "$E/live-primary-final.txt" | sed 's/^/nonce occurrences in claude pane at end: /'
step "6. later real away return with open blocker, resolve, check"
seed_status real-away
FM_HOME=$LAB bin/fm-afk-contract.sh enter --words 'real away lab' >/dev/null; date +%s > "$LAB/state/.afk"
R bin/fm-afk-return.sh begin; echo "away begin rc=$? gate=$([ -e $LAB/state/.afk-return-catchup ] && echo present || echo absent)"
printf 'resolved [key=real-away]: repaired\n' >> "$LAB/state/repair-task.status"
R bin/fm-afk-return.sh check; echo "check rc=$? gate=$([ -e $LAB/state/.afk-return-catchup ] && echo present || echo absent) quiet receipt=$([ -f $LAB/state/.quiet-exit-receipt ] && echo kept || echo gone)"
