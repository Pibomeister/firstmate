#!/usr/bin/env bash
# Live: a real wake acknowledged through fm-wake-drain shows up in sample's
# wake_acks_last_hour and finish's wake-ledger.tsv; recent status lines count.
set -u
W=$1; cd "$W"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-soak-live.XXXXXX"); mkdir -p "$SCR/wd" "$SCR/tr"
git -C "$LAB" init -q && git -C "$LAB" -c user.email=a@b -c user.name=lab commit -q --allow-empty -m lab
S() { env -u FM_STATE_OVERRIDE -u FM_HOME bin/fm-soak-record.sh "$@"; }
S start --home "$LAB" --out "$SCR/out" --label baseline --harness claude >/dev/null
for k in one two; do FM_HOME="$LAB" bash -c '. bin/fm-wake-lib.sh; fm_wake_append check "live-$1" "live soak check $1"' _ $k; done
OUTD=$(FM_HOME="$LAB" bin/fm-wake-drain.sh 2>&1)
echo "$OUTD" | grep -E 'live soak|WAKE_ACK' | sed "s#$LAB#<LAB>#g"
ACK=$(echo "$OUTD" | grep -o 'bin/fm-wake-drain.sh --ack-through[^`]*' | head -1)
echo "ack: $ACK"; FM_HOME="$LAB" $ACK >/dev/null 2>&1; echo "ack exit=$?"
echo "wake-ledger.tsv in home:"; cat "$LAB/state/wake-ledger.tsv"
now=$(date +%s)
printf 'working: a [at=%s]\nworking: b [at=%s]\nold [at=%s]\n' $((now-60)) $((now-120)) $((now-7200)) > "$LAB/state/t1.status"
echo "fm-wake-ledger count: $(FM_HOME="$LAB" bin/fm-wake-ledger.sh count --since $((now-3600)) --until $((now+1)))"
sleep 1
S sample --home "$LAB" --out "$SCR/out"; echo "load.tsv (epoch live acks status sid):"; cat "$SCR/out/load.tsv"
S finish --home "$LAB" --out "$SCR/out" --watchdog-dir "$SCR/wd" --transcript-dir "$SCR/tr"; echo "finish exit=$?"
echo "out/wake-ledger.tsv:"; cat "$SCR/out/wake-ledger.tsv"
rm -rf "$LAB" "$SCR"
