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

hr 'S1b brief with config/wait-no-turns: Waiting section routes pipeline waits to the listener'
touch "$LAB/config/wait-no-turns"
"$ROOT/bin/fm-brief.sh" ship fmlab --mode no-mistakes >/dev/null 2>&1 || echo "brief rc=$?"
awk '/^# Waiting/,/^A wait your shell can watch/' "$LAB/data/ship/brief.md"
ARMCMD=$(sed -n 's/.*arm its completion listener with `\(.*\)`\.$/\1/p' "$LAB/data/ship/brief.md")

hr 'S5 adversarial: arm whose detached runner cannot start is retired, then re-arm works'
REAL_BASH=$(command -v bash); mkdir -p "$LAB/brokenbin"
cat > "$LAB/brokenbin/bash" <<SH
#!$REAL_BASH
case "\${1-}:\${2-}" in *fm-procevent.sh:_start) exit 1 ;; esac
exec "$REAL_BASH" "\$@"
SH
chmod +x "$LAB/brokenbin/bash"
PATH="$LAB/brokenbin:$PATH" FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 FM_HOME="$LAB" "$A" arm ship; echo "failed arm rc=$?"
echo "--- registrations after failed arm (expect none):"; "$P" list
printf 'outcome: passed\n' > "$NM_FIXTURE_ROOT/return"
eval "$ARMCMD"; echo "re-arm after failure rc=$?"
: > "$NM_FIXTURE_ROOT/trigger"; "$P" reconcile >/dev/null 2>&1; wait_inbox && echo "inbox record delivered"
RESULT=$(ls -t "$LAB/state/procevent-inbox/"*.result | head -1); echo "--- classify: $("$A" classify "$RESULT")"
REC=$(ls "$LAB/state/ship.inbox/"*.msg | head -1); SRC=${RESULT##*/}; SRC=${SRC%.*.result}; SEQ=${RESULT%.result}; SEQ=${SEQ##*.}
"$P" handled "$SRC" "$SEQ"; mv "$REC" "$LAB/state/ship.inbox/handled/"

hr 'S7 adversarial: no shasum/sha256sum on PATH refuses before registering'
mkdir -p "$LAB/minbin"; for t in bash sh awk sed cut grep cat mkdir rm mv ls date dirname basename pwd tr wc head tail readlink stat sleep ps kill mktemp chmod ln touch env seq id uname perl python3 git tmux find sort uniq tee xargs; do p=$(command -v $t) && ln -sf "$p" "$LAB/minbin/$t"; done
ln -sf "$LAB/fakebin/no-mistakes" "$LAB/minbin/no-mistakes"
PATH="$LAB/minbin" FM_HOME="$LAB" "$A" arm ship; echo "no-digest arm rc=$?"
echo "--- registrations after (expect none):"; "$P" list
