#!/usr/bin/env bash
# Live drive 3 (parked worker on an undeclared harness): a live worker window in the lab's private tmux server, a wake-ledger row in the window, case-alias dedupe.
set -u
WT=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M70A83BXS4MCHGRHEVZNM961
S="$WT/bin/fm-soak-record.sh"; LH="$WT/bin/fm-lab-home.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soakwork.XXXXXX")
bash "$LH" create "$LAB" >/dev/null; TD=$(bash "$LH" tmux-dir "$LAB")
trap 'bash "$LH" tmux "$LAB" kill-server >/dev/null 2>&1; bash "$LH" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$WORK"' EXIT
export TMUX_TMPDIR="$TD"; unset TMUX TMUX_PANE FM_STATE_OVERRIDE
r() { echo "\$ fm-soak-record.sh $1 ..."; bash "$S" "$@" 2>&1 | sed "s#$LAB#<home>#g; s#$WORK#<work>#g"; echo "exit=${PIPESTATUS[0]}"; }
git -C "$LAB" init -q && git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m soak-home
# a real task copy for the worker
TC="$WORK/copy"; mkdir -p "$TC"; git -C "$TC" init -q; git -C "$TC" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m init; git -C "$TC" checkout -q -b fm/feat-a
bash "$LH" tmux "$LAB" new-session -d -s fm -n fm-feat-a -c "$TC" 'sleep 600'
printf 'window=fm:fm-feat-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$TC" > "$LAB/state/feat-a.meta"
mkdir -p "$WORK/wd" "$WORK/tx"; : > "$WORK/wd/actions.tsv"
printf "needs-decision [at=%s]: pick a design\n" "$(date +%s)" > "$LAB/state/feat-a.status"
echo "-- crew-state as the recorder reads it:"; FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 bash "$WT/bin/fm-crew-state.sh" feat-a 2>&1 | grep '^state:'
r start --home "$LAB" --out "$WORK/out" --label baseline --harness claude
sleep 1; NOW=$(date +%s); printf '%s\tack\t-\t7\t7\t["k"]\n' "$NOW" > "$LAB/state/wake-ledger.tsv"; printf 'doc\n' > "$LAB/data/handoff-a.md"
ALIAS=$(printf '%s' "$LAB" | sed 's/fm-lab/FM-LAB/')
r sample --home "$LAB" --out "$WORK/out"; r sample --home "$ALIAS" --out "$WORK/out"
echo "-- load.tsv"; cat "$WORK/out/load.tsv"; echo "-- handoff-events.tsv rows: $(wc -l < "$WORK/out/handoff-events.tsv" | tr -d ' ')"
sleep 1; r finish --home "$ALIAS" --out "$WORK/out" --watchdog-dir "$WORK/wd" --transcript-dir "$WORK/tx"
jq -c '{handoff_count,violations}' "$WORK/out/soak.json"; echo "-- wake-ledger.tsv"; cat "$WORK/out/wake-ledger.tsv"
echo "-- handoffs kept:"; ls "$WORK/out/handoffs"
