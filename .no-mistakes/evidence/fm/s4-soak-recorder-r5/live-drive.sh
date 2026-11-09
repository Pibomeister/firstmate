#!/usr/bin/env bash
# Live drive of bin/fm-soak-record.sh against a disposable lab home, real clock.
set -u
WT=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M70A83BXS4MCHGRHEVZNM961
S="$WT/bin/fm-soak-record.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soakwork.XXXXXX")
trap 'bash "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$WORK"' EXIT
bash "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$(bash "$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TD"; unset TMUX TMUX_PANE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE
run() { echo "\$ fm-soak-record.sh $*" | sed "s#$LAB#<home>#g; s#$WORK#<work>#g"; bash "$S" "$@" 2>&1 | sed "s#$LAB#<home>#g; s#$WORK#<work>#g"; echo "exit=${PIPESTATUS[0]}"; }
git -C "$LAB" init -q && git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m soak-home
NOW=$(date +%s)
# home fixtures: lock session id, a status line in the hour, wake-ledger rows, a task on an undeclared harness, a handoff doc
printf 'sess-live-1\n' > "$LAB/state/.lock-session"
printf '[at=%s] working: x\n[at=%s] old\n' $((NOW-60)) $((NOW-7200)) > "$LAB/state/feat-a.status"
printf '%s\tack\t-\t3\t1,2,3\t["a","b","c"]\n' $((NOW-30)) > "$LAB/state/wake-ledger.tsv"
printf 'window=fm:fm-feat-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$WORK" > "$LAB/state/feat-a.meta"
mkdir -p "$WORK/wd/handoffs" "$WORK/tx"
snap() { (cd "$LAB" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while read -r p; do [ -f "$p" ] && echo "$p $(stat -f %m "$p") $(cksum <"$p")" || echo "$p D"; done); }
echo "== S1 readable-harnesses / inventory"; run readable-harnesses; run inventory --home "$LAB" --harness claude; run inventory --home "$LAB" --harness claude --harness codex
echo "== S2 start refuses unreadable harness"; run start --home "$LAB" --out "$WORK/out" --label baseline --harness codex; ls "$WORK/out/soak.json" 2>&1 | sed "s#$WORK#<work>#"
echo "== S3 start refuses --out inside / containing home"; run start --home "$LAB" --out "$LAB/data/out" --label baseline --harness claude; run start --home "$LAB/data" --out "$LAB" --label baseline --harness claude
BEFORE=$(snap)
echo "== S4 start baseline"; run start --home "$LAB" --out "$WORK/out" --label baseline --harness claude; jq . "$WORK/out/soak.json" | sed "s#$LAB#<home>#g"
echo "revision matches home HEAD: $( [ "$(jq -r .revision "$WORK/out/soak.json")" = "$(git -C "$LAB" rev-parse HEAD)" ] && echo yes || echo NO)"
sleep 1; printf '# handoff\n' > "$LAB/data/handoff-a.md"; BEFORE=$(snap)
echo "== S5 sample"; run sample --home "$LAB" --out "$WORK/out"; cat "$WORK/out/load.tsv"; echo "-- handoff-events"; sed "s#$LAB#<home>#g" "$WORK/out/handoff-events.tsv"
echo "home unchanged by sample: $( [ "$(snap)" = "$BEFORE" ] && echo yes || echo NO)"
echo "== S6 sample refuses another --home"; OTHER=$(mktemp -d); run sample --home "$OTHER" --out "$WORK/out"; rm -rf "$OTHER"
# window activity: transcript, watchdog rows
printf '{"x":1}\n' > "$WORK/tx/sess-live-2.jsonl"
N2=$(date +%s)
printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n%s\tw9\t/elsewhere\tprimary\tfrozen\trestart\tdone\tx\n' "$N2" "$LAB" "$N2" > "$WORK/wd/actions.tsv"
printf 'wd handoff\n' > "$WORK/wd/handoffs/h1.md"
echo "== S7 finish refuses --watchdog-dir inside --out"; mkdir -p "$WORK/out/wdx"; run finish --home "$LAB" --out "$WORK/out" --watchdog-dir "$WORK/out/wdx" --transcript-dir "$WORK/tx"; echo "finished_at after refusal: $(jq -r '.finished_at // "unset"' "$WORK/out/soak.json")"; rmdir "$WORK/out/wdx"
sleep 1; BEFORE=$(snap)
echo "== S8 finish"; run finish --home "$LAB" --out "$WORK/out" --watchdog-dir "$WORK/wd" --transcript-dir "$WORK/tx"
jq '{label,finished_at_set:(.finished_at!=null),session_ids,handoff_count,violations}' "$WORK/out/soak.json" | sed "s#$WORK#<work>#g"
echo "-- out tree"; (cd "$WORK/out" && find . -type f | LC_ALL=C sort)
echo "-- watchdog/actions.tsv"; sed "s#$LAB#<home>#g" "$WORK/out/watchdog/actions.tsv"
echo "-- wake-ledger.tsv"; cat "$WORK/out/wake-ledger.tsv"
echo "home unchanged by finish: $( [ "$(snap)" = "$BEFORE" ] && echo yes || echo NO)"
echo "== S9 sample/finish after finish refused"; run sample --home "$LAB" --out "$WORK/out"; run finish --home "$LAB" --out "$WORK/out" --watchdog-dir "$WORK/wd" --transcript-dir "$WORK/tx"
echo "== S10 post-change violations without fm-activity-sources.sh"; run start --home "$LAB" --out "$WORK/out2" --label post-change --harness claude; run finish --home "$LAB" --out "$WORK/out2" --watchdog-dir "$WORK/wd" --transcript-dir "$WORK/tx"; jq -c .violations "$WORK/out2/soak.json"
echo "== S11 hard-linked load.tsv to a home file is refused"; run start --home "$LAB" --out "$WORK/out3" --label baseline --harness claude; ln "$LAB/data/handoff-a.md" "$WORK/out3/load.tsv"; B=$(snap); run sample --home "$LAB" --out "$WORK/out3"; echo "home unchanged: $( [ "$(snap)" = "$B" ] && echo yes || echo NO)"
echo "== S12 case-alias --home accepted and pinned (case-insensitive fs)"; ALIAS=$(printf '%s' "$LAB" | sed 's/fm-lab/FM-LAB/'); if [ -d "$ALIAS" ]; then run start --home "$LAB" --out "$WORK/out4" --label baseline --harness claude; run sample --home "$LAB" --out "$WORK/out4"; run sample --home "$ALIAS" --out "$WORK/out4"; run finish --home "$LAB" --out "$WORK/out4" --watchdog-dir "$WORK/wd" --transcript-dir "$WORK/tx"; echo "handoff-event rows: $(wc -l < "$WORK/out4/handoff-events.tsv" | tr -d ' ')"; jq -c '{handoff_count}' "$WORK/out4/soak.json"; else echo "case-sensitive fs: not applicable"; fi
