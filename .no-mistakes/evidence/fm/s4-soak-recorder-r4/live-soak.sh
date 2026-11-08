#!/usr/bin/env bash
# Live drive of bin/fm-soak-record.sh against a disposable lab home (real clock).
set -u
W=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-soak-live.XXXXXX")
OUT=$SCR/out; WD=$SCR/watchdog; TR=$SCR/transcripts; mkdir -p "$WD/handoffs" "$TR"
git -C "$LAB" init -q && git -C "$LAB" -c user.email=a@b -c user.name=lab commit -q --allow-empty -m lab
run() { echo "\$ fm-soak-record.sh $*" | sed "s#$LAB#<LAB>#g; s#$SCR#<SCR>#g"; env -u FM_STATE_OVERRIDE -u FM_HOME -u FM_ROOT_OVERRIDE "$W/bin/fm-soak-record.sh" "$@" 2>&1 | sed "s#$LAB#<LAB>#g; s#$SCR#<SCR>#g"; echo "exit=${PIPESTATUS[0]}"; }
snap() { find "$LAB" -path "$LAB/.git" -prune -o -print0 | sort -z | xargs -0 stat -f '%N %m %z' | shasum | cut -c1-16; }
echo "== readable-harnesses"; run readable-harnesses
echo "== inventory (claude ok, codex unreadable)"; run inventory --home "$LAB" --harness claude --harness codex
echo "== start refuses unreadable harness"; run start --home "$LAB" --out "$OUT" --label baseline --harness claude --harness codex; ls "$OUT/soak.json" 2>&1 | sed "s#$SCR#<SCR>#"
echo "== start refuses --out inside home"; run start --home "$LAB" --out "$LAB/out" --label baseline --harness claude
echo "== start refuses --out containing home (S169-1)"; run start --home "$LAB" --out "$(dirname "$LAB")" --label baseline --harness claude
# Real wake: enqueue via the wake lib, drain, then acknowledge through the printed command.
( export FM_HOME="$LAB"; . "$W/bin/fm-wake-lib.sh"; fm_wake_append check live-check "live soak check" )
BEFORE=$(snap)
echo "== start baseline"; run start --home "$LAB" --out "$OUT" --label baseline --harness claude; cat "$OUT/soak.json" | sed "s#$LAB#<LAB>#g"; echo
ACK=$(cd "$W" && FM_HOME="$LAB" bin/fm-wake-drain.sh 2>/dev/null | sed -n 's/^WAKE_ACK_REQUIRED[: ]*//p' | head -1)
echo "drain ack command: $(echo "$ACK" | sed "s#$LAB#<LAB>#g")"
(cd "$W" && FM_HOME="$LAB" eval "$ACK" >/dev/null 2>&1); echo "ledger rows: $(wc -l < "$LAB/state/wake-ledger.tsv" 2>/dev/null || echo 0)"
BEFORE=$(snap)
# Status lines + a session id + a live worker meta.
printf 'working: started [at=%s]\n' "$(date +%s)" > "$LAB/state/t1.status"
printf 'old line [at=%s]\n' $(( $(date +%s) - 7200 )) >> "$LAB/state/t1.status"
printf 'sess-live-1\n' > "$LAB/state/.lock-session"
printf 'harness=codex\nkind=ship\n' > "$LAB/state/t1.meta"
printf 'handoff text\n' > "$LAB/data/handoff-primary.md"
BEFORE=$(snap)
echo "== sample"; run sample --home "$LAB" --out "$OUT"; echo "load.tsv:"; cat "$OUT/load.tsv"
echo "== sample refuses another home (S169-3)"; OTHER=$(mktemp -d); run sample --home "$OTHER" --out "$OUT"; rmdir "$OTHER"
echo "== unsafe session id (S169-4)"; printf '../../escape\n' > "$LAB/state/.lock-session"; BEFORE=$(snap); run sample --home "$LAB" --out "$OUT"; tail -1 "$OUT/load.tsv"
printf '{"t":1}\n' > "$TR/sess-live-1.jsonl"; printf '{"t":2}\n' > "$TR/sess-live-2.jsonl"
printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' "$(date +%s)" "$LAB" > "$WD/actions.tsv"
printf '%s\tw9\t/other\tprimary\tfrozen\trestart\tdone\tother\n' "$(date +%s)" >> "$WD/actions.tsv"
printf 'wd\n' > "$WD/handoffs/primary-1.md"
sleep 1
echo "== finish"; run finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"
python3 -m json.tool "$OUT/soak.json" | sed "s#$LAB#<LAB>#g; s#$SCR#<SCR>#g"
echo "out tree:"; (cd "$OUT" && find . -type f | sort)
echo "home unchanged across sample/finish: $( [ "$BEFORE" = "$(snap)" ] && echo yes || echo NO)"
echo "== sample after finish refused"; run sample --home "$LAB" --out "$OUT"
echo "== post-change finish (activity-sources script absent)"
OUT2=$SCR/out2; run start --home "$LAB" --out "$OUT2" --label post-change --harness claude >/dev/null; sleep 1
run finish --home "$LAB" --out "$OUT2" --watchdog-dir "$WD" --transcript-dir "$TR" >/dev/null
python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))['violations']))" "$OUT2/soak.json"
rm -rf "$LAB" "$SCR"
