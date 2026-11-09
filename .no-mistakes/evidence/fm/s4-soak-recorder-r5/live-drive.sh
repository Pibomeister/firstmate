#!/usr/bin/env bash
# Live drive of bin/fm-soak-record.sh against a disposable lab home (real clock, real helpers).
set -u
R=$1; EV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soak-live.XXXXXX")
trap 'rm -rf "$LAB" "$WORK"' EXIT
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$LAB" init -q && git -C "$LAB" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m home
export FM_HOME="$LAB"
OUT="$WORK/out"; WD="$WORK/watchdog"; TR="$WORK/transcripts"
mkdir -p "$WD/handoffs" "$TR"
S="$R/bin/fm-soak-record.sh"
snap() { (cd "$LAB" && find . -path ./.git -prune -o -print0 | sort -z | xargs -0 stat -f '%N %m %z' ) | shasum | cut -c1-16; }
echo "== readable-harnesses"; "$S" readable-harnesses; echo "rc=$?"
echo "== inventory claude codex"; "$S" inventory --home "$LAB" --harness claude --harness codex; echo "rc=$?"
echo "== start with unreadable harness (expect 3, no soak.json)"; "$S" start --home "$LAB" --out "$OUT" --label baseline --harness claude --harness codex; echo "rc=$? soak.json_exists=$([ -e "$OUT/soak.json" ] && echo yes || echo no)"
echo "== start with --out inside home (expect 2)"; "$S" start --home "$LAB" --out "$LAB/data/soak" --label baseline --harness claude; echo "rc=$? created=$([ -e "$LAB/data/soak" ] && echo yes || echo no)"
echo "== start with --out containing home (expect 2)"; "$S" start --home "$LAB" --out "$(dirname "$LAB")" --label baseline --harness claude 2>&1 | tail -1; echo "rc=${PIPESTATUS[0]}"
NOW=$(date +%s)
# Seed home inputs before baseline snapshot
printf '%s\tack\tg1\t3\t1,2,3\t["a","b","c"]\n' $((NOW - 30)) > "$LAB/state/wake-ledger.tsv"
printf 'working [at=%s]: x\nneeds-decision [at=%s]: y\n' $((NOW - 20)) $((NOW - 10)) > "$LAB/state/feat-a.status"
printf 'window=fm:fm-feat-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$WORK" > "$LAB/state/feat-a.meta"
printf 'live-sess-1\nanchor_pid=1\n' > "$LAB/state/.lock-session"
sleep 1
echo "== start baseline"; "$S" start --home "$LAB" --out "$OUT" --label baseline --harness claude; echo "rc=$?"; jq . "$OUT/soak.json"
echo "  home HEAD: $(git -C "$LAB" rev-parse HEAD)"
sleep 1
echo "handoff v1" > "$LAB/data/handoff-main.md"
printf 'doc=%s\nat=%s\nowner=1\n' "$LAB/data/handoff-main.md" "$(date +%s)" > "$LAB/state/.order-handoff"
echo '{"type":"x"}' > "$TR/live-sess-1.jsonl"; echo '{"type":"y"}' > "$TR/other-sess.jsonl"
T=$(date +%s)
printf '%s\tn1\t%s\tprimary\thandoff-request\tnudge\tpending\tcontext is low\n' "$T" "$LAB" > "$WD/actions.tsv"
printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' "$T" "$LAB" >> "$WD/actions.tsv"
printf '%s\tw9\t/some/other/home\tprimary\tfrozen\trestart\tdone\tpickup verified\n' "$T" >> "$WD/actions.tsv"
echo "lean" > "$WD/handoffs/lean-1.md"
printf '%s\tack\tg1\t4\t4\t["d"]\n' "$T" >> "$LAB/state/wake-ledger.tsv"
B=$(snap)
echo "== sample"; "$S" sample --home "$LAB" --out "$OUT"; echo "rc=$?"; cat "$OUT/load.tsv"; echo "-- handoff-events.tsv"; cat "$OUT/handoff-events.tsv"
echo "  home unchanged by sample: $([ "$B" = "$(snap)" ] && echo yes || echo NO)"
echo "== sample with another home (expect 2)"; OTHER=$(mktemp -d "$WORK/otherhome.XXXX"); mkdir -p "$OTHER/state"; "$S" sample --home "$OTHER" --out "$OUT"; echo "rc=$?"
echo "== finish with --watchdog-dir inside --out (expect 2)"; mkdir -p "$OUT/wdx"; "$S" finish --home "$LAB" --out "$OUT" --watchdog-dir "$OUT/wdx" --transcript-dir "$TR"; echo "rc=$? finished_at=$(jq -r .finished_at "$OUT/soak.json")"
sleep 1
echo "handoff v2" > "$LAB/data/handoff-main.md"
B=$(snap)
echo "== finish"; "$S" finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"; echo "rc=$?"
echo "  home unchanged by finish: $([ "$B" = "$(snap)" ] && echo yes || echo NO)"
jq . "$OUT/soak.json"
echo "-- out tree"; (cd "$OUT" && find . -type f | sort)
echo "-- watchdog/actions.tsv"; cat "$OUT/watchdog/actions.tsv"
echo "-- wake-ledger.tsv"; cat "$OUT/wake-ledger.tsv"
echo "== sample after finish (expect refusal)"; "$S" sample --home "$LAB" --out "$OUT"; echo "rc=$?"
# post-change run
OUT2="$WORK/out2"
echo "== post-change start/finish"; "$S" start --home "$LAB" --out "$OUT2" --label post-change --harness claude >/dev/null; echo "start rc=$?"
"$S" finish --home "$LAB" --out "$OUT2" --watchdog-dir "$WD" --transcript-dir "$TR" >/dev/null; echo "finish rc=$?"; jq -c .violations "$OUT2/soak.json"
