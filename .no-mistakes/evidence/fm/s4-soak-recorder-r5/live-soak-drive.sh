#!/usr/bin/env bash
# Live drive of bin/fm-soak-record.sh against a disposable lab home, real clock.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB" "$WORK"' EXIT
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soakwork.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$LAB" init -q; git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m home
OUT=$WORK/out WD=$WORK/wd TR=$WORK/tr; mkdir -p "$WD/handoffs" "$TR"
S="$R/bin/fm-soak-record.sh"
run(){ echo "\$ fm-soak-record.sh $*"; env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE "$S" "$@"; echo "[exit $?]"; }
snap(){ (cd "$LAB" && find . -path ./.git -prune -o -print0 | xargs -0 stat -f '%N %m %z' | sort); }
echo "== readable-harnesses"; run readable-harnesses
echo "== inventory"; run inventory --home "$LAB" --harness claude --harness codex
echo "== start refused on unreadable harness"; run start --home "$LAB" --out "$OUT" --label baseline --harness codex; ls "$OUT" 2>&1
echo "== start refused when --out is inside the home"; run start --home "$LAB" --out "$LAB/data/soak" --label baseline --harness claude
echo "== start"; BEFORE=$(snap)
run start --home "$LAB" --out "$OUT" --label baseline --harness claude; jq . "$OUT/soak.json"
sleep 1; NOW=$(date +%s)
printf 'working [at=%s]: x\n' "$NOW" > "$LAB/state/feat-a.status"
printf '# handoff\n' > "$LAB/data/handoff-primary.md"
printf 'claude-sess-1\n' > /dev/null
echo '{"type":"user"}' > "$TR/sess-abc.jsonl"
printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' "$NOW" "$LAB" > "$WD/actions.tsv"
printf '%s\tw9\t/some/other/home\tprimary\tfrozen\trestart\tdone\tother\n' "$NOW" >> "$WD/actions.tsv"
echo note > "$WD/handoffs/wd-lean.md"
BEFORE=$(snap)
echo "== sample"; run sample --home "$LAB" --out "$OUT"; cat "$OUT/load.tsv"
[ "$BEFORE" = "$(snap)" ] && echo "HOME UNCHANGED BY SAMPLE" || echo "HOME CHANGED BY SAMPLE"
echo "== sample with a different --home is refused"; run sample --home "$WORK" --out "$OUT"
echo "== ADVERSARIAL: hard-linked load.tsv"; mv "$OUT/load.tsv" "$WORK/load.bak"; ln "$LAB/state/feat-a.status" "$OUT/load.tsv"
B2=$(cat "$LAB/state/feat-a.status"); run sample --home "$LAB" --out "$OUT"
[ "$B2" = "$(cat "$LAB/state/feat-a.status")" ] && echo "HOME FILE BEHIND HARD LINK UNCHANGED" || echo "HOME FILE MODIFIED"
rm "$OUT/load.tsv"; mv "$WORK/load.bak" "$OUT/load.tsv"
echo "== ADVERSARIAL: hard-linked watchdog copy"; mkdir -p "$OUT/watchdog"; ln "$WD/actions.tsv" "$OUT/watchdog/actions.tsv"
W0=$(cat "$WD/actions.tsv"); run finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"
[ "$W0" = "$(cat "$WD/actions.tsv")" ] && echo "WATCHDOG LEDGER UNCHANGED" || echo "WATCHDOG LEDGER CHANGED"
jq -r '.finished_at // "not finished"' "$OUT/soak.json"; rm "$OUT/watchdog/actions.tsv"
echo "== ADVERSARIAL: symlinked load.tsv"; mv "$OUT/load.tsv" "$WORK/load.bak"; ln -s "$LAB/state/feat-a.status" "$OUT/load.tsv"
run sample --home "$LAB" --out "$OUT"; rm "$OUT/load.tsv"; mv "$WORK/load.bak" "$OUT/load.tsv"
echo "== ADVERSARIAL: watchdog dir inside --out"; run finish --home "$LAB" --out "$OUT" --watchdog-dir "$OUT/watchdog" --transcript-dir "$TR"
sleep 1; BEFORE=$(snap)
echo "== finish"; run finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"
[ "$BEFORE" = "$(snap)" ] && echo "HOME UNCHANGED BY FINISH" || echo "HOME CHANGED BY FINISH"
jq . "$OUT/soak.json"; echo "-- out tree"; (cd "$OUT" && find . -type f | sort)
echo "-- watchdog/actions.tsv"; cat "$OUT/watchdog/actions.tsv"
echo "== post-change start + finish (violations)"; OUT2=$WORK/out2
run start --home "$LAB" --out "$OUT2" --label post-change --harness claude; sleep 1
run finish --home "$LAB" --out "$OUT2" --watchdog-dir "$WD" --transcript-dir "$TR"; jq '{label,violations,handoff_count}' "$OUT2/soak.json"
echo "== sample after finish is refused"; run sample --home "$LAB" --out "$OUT"
