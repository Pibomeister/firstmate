#!/usr/bin/env bash
# Live lab driver: real firstmate scripts against a disposable lab home and
# private tmux server; only the no-mistakes CLI is a stub (the gate forbids
# this phase from invoking a real `no-mistakes axi run`).
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
labtmux() { "$ROOT/bin/fm-lab-home.sh" tmux "$LAB" "$@"; }
cleanup() { labtmux kill-server >/dev/null 2>&1; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
unset TMUX TMUX_PANE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX_TMPDIR=$TD FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
mkdir -p "$LAB/fakebin" "$LAB/nm"
export NM_FIXTURE_ROOT=$LAB/nm
cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s | cwd=%s\n' "$*" "$PWD" >> "$NM_FIXTURE_ROOT/calls"
[ "$*" = 'axi run --wait 24h' ] || exit 90
if [ -e "$NM_FIXTURE_ROOT/elapse" ]; then rm -f "$NM_FIXTURE_ROOT/elapse"; printf 'run:\n  id: lab\n  status: running\n'; exit 0; fi
while [ ! -e "$NM_FIXTURE_ROOT/trigger" ]; do sleep 0.1; done
rm -f "$NM_FIXTURE_ROOT/trigger"
cat "$NM_FIXTURE_ROOT/return"; exit "$(cat "$NM_FIXTURE_ROOT/exit" 2>/dev/null || echo 0)"
SH
chmod +x "$LAB/fakebin/no-mistakes"
export PATH="$LAB/fakebin:$PATH"
WT=$LAB/worktree; mkdir -p "$WT"
# Worker pane stand-in: a shell that just echoes whatever is typed into it.
labtmux new-session -d -s fmlab -n fm-ship -x 220 -y 50 "cat"
printf 'window=fmlab:fm-ship\nworktree=%s\nproject=fmlab\n' "$WT" > "$LAB/state/ship.meta"
A="$ROOT/bin/fm-procevent-no-mistakes.sh"; P="$ROOT/bin/fm-procevent.sh"
hr() { printf '\n===== %s =====\n' "$1"; }
wait_inbox() { for _ in $(seq 1 200); do ls "$LAB/state/ship.inbox/"*.msg >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }

hr 'S1 generated ship brief: Definition-of-done drive contract'
"$ROOT/bin/fm-brief.sh" ship fmlab --mode no-mistakes >/dev/null 2>&1 || echo "brief rc=$?"
awk '/Start the run or answer a gate/,/never a blocking reattach/' "$LAB/data/ship/brief.md"
echo "--- stale blocking-reattach wording present?"; grep -c 'Reattach and keep going\|reattach at once by re-running' "$LAB/data/ship/brief.md"
echo "--- Waiting section pipeline line:"; grep -n 'completion-listener contract' "$LAB/data/ship/brief.md"
ARMCMD=$(sed -n 's/.*arm its completion listener with `\(.*\)`\.$/\1/p' "$LAB/data/ship/brief.md")
echo "--- extracted arm command: $ARMCMD"

hr 'S2 worker runs the brief arm command verbatim; gate wakes the worker pane'
printf 'gate: review\nfindings[1]{id,action,description}:\n  r1,ask-user,decision required\n' > "$NM_FIXTURE_ROOT/return"
eval "$ARMCMD"; echo "arm rc=$?"
"$P" list
sleep 1; echo "--- inbox before condition clears:"; ls "$LAB/state/ship.inbox/" 2>/dev/null | grep -c '\.msg$'
: > "$NM_FIXTURE_ROOT/trigger"
"$P" reconcile >/dev/null 2>&1
wait_inbox && echo "inbox record delivered" || echo "NO inbox record"
REC=$(ls "$LAB/state/ship.inbox/"*.msg | head -1); cat "$REC"; echo
RESULT=$(ls "$LAB/state/procevent-inbox/"*.result | head -1)
echo "--- classify: $("$A" classify "$RESULT")"; "$A" read "$RESULT"
sleep 1; echo "--- worker pane (tmux capture):"; labtmux capture-pane -p -t fmlab:fm-ship | sed '/^$/d' | tail -6
echo "--- no-mistakes calls:"; cat "$NM_FIXTURE_ROOT/calls"
SRC=${RESULT##*/}; SRC=${SRC%.*.result}; SEQ=${RESULT%.result}; SEQ=${SEQ##*.}
"$P" handled "$SRC" "$SEQ"; echo "handled rc=$?"; mv "$REC" "$LAB/state/ship.inbox/handled/"

hr 'S3 re-arm for next wait; elapsed hold reattaches silently, CI-ready wakes'
: > "$NM_FIXTURE_ROOT/calls"; : > "$NM_FIXTURE_ROOT/elapse"
printf 'outcome: checks-passed\nhelp[1]:\n  PR https://example.test/o/r/pull/1\n' > "$NM_FIXTURE_ROOT/return"
eval "$ARMCMD"; echo "re-arm rc=$?"
for _ in $(seq 1 50); do [ "$(wc -l < "$NM_FIXTURE_ROOT/calls")" -ge 2 ] && break; sleep 0.1; done
echo "--- calls after elapsed hold:"; cat "$NM_FIXTURE_ROOT/calls"
echo "--- inbox .msg count while still running: $(ls "$LAB/state/ship.inbox/"*.msg 2>/dev/null | wc -l | tr -d ' ')"
: > "$NM_FIXTURE_ROOT/trigger"; "$P" reconcile >/dev/null 2>&1; wait_inbox
RESULT=$(ls -t "$LAB/state/procevent-inbox/"*.result | head -1); echo "--- classify: $("$A" classify "$RESULT")"
REC=$(ls "$LAB/state/ship.inbox/"*.msg | head -1); SRC=${RESULT##*/}; SRC=${SRC%.*.result}; SEQ=${RESULT%.result}; SEQ=${SEQ##*.}
"$P" handled "$SRC" "$SEQ" >/dev/null; mv "$REC" "$LAB/state/ship.inbox/handled/"

hr 'S4 adversarial: duplicate arm and aliased FM_HOME while armed'
: > "$NM_FIXTURE_ROOT/calls"; rm -f "$NM_FIXTURE_ROOT/elapse"
eval "$ARMCMD" >/dev/null; echo "first arm rc=$?"
FM_HOME="$LAB" "$A" arm ship; echo "duplicate rc=$?"
FM_HOME="$LAB/" "$A" arm ship; echo "alias rc=$?"
FM_HOME="$LAB/state/.." "$A" arm ship; echo "dotdot alias rc=$?"
sleep 1; echo "--- attachments started: $(wc -l < "$NM_FIXTURE_ROOT/calls" | tr -d ' ')"
printf 'error: daemon unavailable\n' > "$NM_FIXTURE_ROOT/return"; printf '1\n' > "$NM_FIXTURE_ROOT/exit"
: > "$NM_FIXTURE_ROOT/trigger"; "$P" reconcile >/dev/null 2>&1; wait_inbox
RESULT=$(ls -t "$LAB/state/procevent-inbox/"*.result | head -1)
echo "--- S6 error wake classify: $("$A" classify "$RESULT")"; "$A" read "$RESULT"
REC=$(ls "$LAB/state/ship.inbox/"*.msg | head -1); SRC=${RESULT##*/}; SRC=${SRC%.*.result}; SEQ=${RESULT%.result}; SEQ=${SEQ##*.}
"$P" handled "$SRC" "$SEQ" >/dev/null; mv "$REC" "$LAB/state/ship.inbox/handled/"; printf '0\n' > "$NM_FIXTURE_ROOT/exit"

hr 'S5 adversarial: arm whose listener cannot start is retired, then re-arm works'
mv "$LAB/fakebin/no-mistakes" "$LAB/nm/nm.real"
# Present for the arm-time `command -v` check but the detached listener cannot exec it.
printf '#!/nonexistent/interpreter\n' > "$LAB/fakebin/no-mistakes"; chmod +x "$LAB/fakebin/no-mistakes"
# Make the runner itself unable to launch: break the registered listener's adapter path is not possible, so
# instead force a zero-evidence window via an unreadable claim root.
chmod 000 "$FM_PROCEVENT_CLAIM_ROOT"
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=1 eval "$ARMCMD"; echo "failed arm rc=$?"
chmod 755 "$FM_PROCEVENT_CLAIM_ROOT"
echo "--- registrations after failed arm:"; "$P" list
mv "$LAB/nm/nm.real" "$LAB/fakebin/no-mistakes"
printf 'outcome: passed\n' > "$NM_FIXTURE_ROOT/return"
eval "$ARMCMD"; echo "re-arm after failure rc=$?"
: > "$NM_FIXTURE_ROOT/trigger"; "$P" reconcile >/dev/null 2>&1; wait_inbox
RESULT=$(ls -t "$LAB/state/procevent-inbox/"*.result | head -1); echo "--- classify: $("$A" classify "$RESULT")"
REC=$(ls "$LAB/state/ship.inbox/"*.msg | head -1); SRC=${RESULT##*/}; SRC=${SRC%.*.result}; SEQ=${RESULT%.result}; SEQ=${SEQ##*.}
"$P" handled "$SRC" "$SEQ" >/dev/null; mv "$REC" "$LAB/state/ship.inbox/handled/"

hr 'S7 adversarial: no shasum/sha256sum on PATH refuses before registering'
mkdir -p "$LAB/minbin"; for t in bash sh awk sed cut grep cat mkdir rm mv ls date dirname basename pwd tr wc head tail printf readlink stat sleep ps kill mktemp chmod ln touch env seq id uname perl python3 git tmux find sort uniq tee xargs; do p=$(command -v $t) && ln -sf "$p" "$LAB/minbin/$t"; done
ln -sf "$LAB/fakebin/no-mistakes" "$LAB/minbin/no-mistakes"
before=$("$P" list | wc -l)
PATH="$LAB/minbin" FM_HOME="$LAB" "$A" arm ship; echo "no-digest arm rc=$?"
echo "--- registrations before/after: $before/$("$P" list | wc -l)"; "$P" list | awk '{print $1}' | grep -c '^nm-$' || true
