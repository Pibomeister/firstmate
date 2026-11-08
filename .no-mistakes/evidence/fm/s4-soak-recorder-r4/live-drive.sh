#!/usr/bin/env bash
# Live drive of bin/fm-soak-record.sh against a disposable lab home (real clock, real crew-state, real wake ledger).
set -u
WT=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M6X30YFHR1F6G8Z03NTTC58C
S="$WT/bin/fm-soak-record.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soak-live.XXXXXX")
TMUXD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMUXD"; unset TMUX TMUX_PANE FM_HOME FM_STATE_OVERRIDE
trap 'kill $CHURN 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$WORK"' EXIT
git -C "$LAB" init -q; git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m home
NOW=$(date +%s)
printf 'window=fm:fm-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=claude\n' "$WORK" > "$LAB/state/a.meta"
printf 'window=fm:fm-b\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$WORK" > "$LAB/state/b.meta"
printf 'working [at=%s]: x\nold [at=%s]: y\n' $((NOW-60)) $((NOW-7200)) > "$LAB/state/a.status"
printf 'sess-123\n' > "$LAB/state/.lock-session"
( . "$WT/bin/fm-clock-lib.sh"; . "$WT/bin/fm-wake-ledger-lib.sh"
  fm_wake_ledger_append_locked "$LAB/state" ack 1 3 1,2,3 '[]' )
snap() { ( cd "$1" && find . -print | LC_ALL=C sort | while read -r p; do printf '%s %s\n' "$p" "$(perl -MTime::HiRes=lstat -e 'print((lstat $ARGV[0])[9])' "$p")"; done; ) }
echo "== readable-harnesses"; "$S" readable-harnesses; echo "exit=$?"
echo "== inventory claude codex"; "$S" inventory --home "$LAB" --harness claude --harness codex; echo "exit=$?"
echo "== start refuses unreadable harness"; "$S" start --home "$LAB" --out "$WORK/out0" --label baseline --harness codex; echo "exit=$? soak.json exists? $([ -e "$WORK/out0/soak.json" ] && echo yes || echo no)"
echo "== start --out inside home refused"; "$S" start --home "$LAB" --out "$LAB/data/out" --label baseline --harness claude; echo "exit=$?"
echo "== start --out containing home refused"; "$S" start --home "$LAB" --out "$(dirname "$LAB")" --label baseline --harness claude 2>&1 | head -1; echo "exit=${PIPESTATUS[0]}"
BEFORE=$(snap "$LAB")
OUT="$WORK/out"; mkdir "$OUT"
echo "== start baseline"; "$S" start --home "$LAB" --out "$OUT" --label baseline --harness claude; echo "exit=$?"; jq -c . "$OUT/soak.json"; echo "home HEAD: $(git -C "$LAB" rev-parse HEAD)"
echo "== sample"; "$S" sample --home "$LAB" --out "$OUT"; echo "exit=$?"; cat "$OUT/load.tsv"
OTHER=$(mktemp -d "$WORK/other.XXXX")
echo "== sample with another home refused"; "$S" sample --home "$OTHER" --out "$OUT"; echo "exit=$?"
[ "$(snap "$LAB")" = "$BEFORE" ] && echo "HOME UNCHANGED after start+sample" || { echo "HOME CHANGED"; diff <(echo "$BEFORE") <(snap "$LAB"); }
echo "== concurrent churn: real background writer creating/renaming/deleting temp files in home state during 40 samples"
( i=0; while :; do i=$((i+1)); t="$LAB/state/.order-handoff.$i.tmp"; echo x > "$t"; mv "$t" "$LAB/state/.new-$i" 2>/dev/null; rm -f "$LAB/state/.new-$((i-3))"; echo y > "$LAB/state/.watcher-down.tmp.$i"; rm -f "$LAB/state/.watcher-down.tmp.$i"; done ) & CHURN=$!
for i in $(seq 1 40); do mkdir -p "$LAB/state/bulk$i"; done 2>/dev/null
ok=0; bad=0; for i in $(seq 1 40); do if "$S" sample --home "$LAB" --out "$OUT" 2>>"$WORK/err"; then ok=$((ok+1)); else bad=$((bad+1)); fi; done
kill $CHURN; wait $CHURN 2>/dev/null
echo "samples ok=$ok failed=$bad rows=$(wc -l < "$OUT/load.tsv")"; sort -u "$WORK/err" | head -3
rm -rf "$LAB"/state/.new-* "$LAB"/state/bulk*
BEFORE=$(snap "$LAB")
# finish inputs
TD="$WORK/transcripts"; mkdir "$TD"; echo '{"t":1}' > "$TD/sess-123.jsonl"; echo '{}' > "$TD/sess-456.jsonl"; touch -t 202001010000 "$TD/old.jsonl"
WD="$WORK/wd"; mkdir -p "$WD/handoffs"; echo h > "$WD/handoffs/h1.md"
printf "%s\twd1\t%s\tprimary\tfrozen\trestart\tdone\t-\n" "$(date +%s)" "$LAB" > "$WD/actions.tsv"
echo "== finish refuses watchdog dir inside out"; mkdir -p "$OUT/wdin"; "$S" finish --home "$LAB" --out "$OUT" --watchdog-dir "$OUT/wdin" --transcript-dir "$TD"; echo "exit=$? finished_at=$(jq -r .finished_at "$OUT/soak.json")"
echo "== finish"; "$S" finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TD"; echo "exit=$?"
jq -c '{label,revision,harnesses,session_ids,handoff_count,violations,finished_at:(.finished_at!=null)}' "$OUT/soak.json"
(cd "$OUT" && find . -type f | sort)
[ "$(snap "$LAB")" = "$BEFORE" ] && echo "HOME UNCHANGED after finish" || { echo "HOME CHANGED"; diff <(echo "$BEFORE") <(snap "$LAB"); }
echo "== sample after finish refused"; "$S" sample --home "$LAB" --out "$OUT"; echo "exit=$?"
