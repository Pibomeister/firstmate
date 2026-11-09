#!/usr/bin/env bash
# Live drive of bin/fm-soak-record.sh against a disposable lab home, real clock, real tmux on a private lab socket.
set -u
W=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M6ZMGVEMZFKFSTXH0133XPQP
S="$W/bin/fm-soak-record.sh"
unset FM_STATE_OVERRIDE FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); X=$(mktemp -d "${TMPDIR:-/tmp}/fm-soakx.XXXXXX")
trap '"$W/bin/fm-lab-home.sh" tmux "$LAB" kill-server >/dev/null 2>&1; "$W/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$X"' EXIT
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$LAB" init -q; git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m labhome
export TMUX_TMPDIR=$("$W/bin/fm-lab-home.sh" tmux-dir "$LAB")
"$W/bin/fm-lab-home.sh" tmux "$LAB" new-session -d -s fm -n fm-feat-a 'sleep 600'
"$W/bin/fm-lab-home.sh" tmux "$LAB" new-window -d -t fm: -n fm-feat-c 'sleep 600'
# task copies
for t in a c; do d="$X/copy-$t"; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m i; git -C "$d" checkout -q -b fm/feat-$t; git -C "$d" update-ref refs/remotes/origin/main HEAD; done
# no-mistakes stand-in only for the per-task run status the classifier reads (real tmux, real recorder)
mkdir -p "$X/bin"; cat > "$X/bin/no-mistakes" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in "axi status"|"axi ") b=\$(git rev-parse --abbrev-ref HEAD); h=\$(git rev-parse HEAD)
 if [ "\$b" = fm/feat-a ]; then printf 'run:\n  id: "01R"\n  branch: %s\n  status: running\n  head: "%s"\n  pr: ""\n  findings: none\n  steps[1]{step,status,findings,duration_ms}:\n    review,running,0,0\n' "\$b" "\$h"; fi;;
 "daemon status"|"daemon ") echo '  ● daemon running (pid 1)';; esac; exit 0
SH
chmod +x "$X/bin/no-mistakes"; export PATH="$X/bin:$PATH"
. "$W/bin/fm-meta-lib.sh" 2>/dev/null || true
printf 'window=fm:fm-feat-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=claude\n' "$X/copy-a" > "$LAB/state/feat-a.meta"
printf 'window=fm:fm-feat-c\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$X/copy-c" > "$LAB/state/feat-c.meta"
NOW=$(date +%s)
printf 'working [at=%s]: building\nstale [at=%s]: old\n' $((NOW-60)) $((NOW-7200)) > "$LAB/state/feat-a.status"
printf '%s\tack\tg1\t1\t1\t["a"]\n%s\tack\tg1\t2\t2\t["b"]\n' $((NOW-120)) $((NOW-30)) > "$LAB/state/wake-ledger.tsv"
printf 'sess-live\n' > "$LAB/state/.lock-session"
OUT="$X/out"; WD="$X/wd"; TR="$X/tr"; mkdir -p "$WD/handoffs" "$TR"
snap() { (cd "$LAB" && find . -path ./state/.fm-lab-tmux-dir -prune -o -print | LC_ALL=C sort | while read -r p; do [ -f "$p" ] && echo "$p $(stat -f %m "$p") $(cksum <"$p")" || echo "$p"; done); }
run() { echo "\$ fm-soak-record.sh $*"; bash "$S" "$@"; echo "[exit $?]"; }
echo "== S1 readable-harnesses / inventory"; run readable-harnesses; run inventory --home "$LAB" --harness claude; run inventory --home "$LAB" --harness claude --harness codex
echo "== S2 start refuses unreadable harness"; run start --home "$LAB" --out "$OUT" --label baseline --harness codex; ls "$OUT/soak.json" 2>&1
echo "== S8 adversarial --out inside / containing home"; run start --home "$LAB" --out "$LAB/data/out" --label baseline --harness claude; run start --home "$LAB/data" --out "$LAB" --label baseline --harness claude
BEFORE=$(snap)
echo "== S2 start"; run start --home "$LAB" --out "$OUT" --label post-change --harness claude; cat "$OUT/soak.json"; echo; echo "home HEAD: $(git -C "$LAB" rev-parse HEAD)"
BEFORE=$(snap); echo "== S3 sample"; run sample --home "$LAB" --out "$OUT"; printf 'docs\n' > "$LAB/data/handoff-x.md"; sleep 1; run sample --home "$LAB" --out "$OUT"; echo "-- load.tsv"; cat "$OUT/load.tsv"; rm "$LAB/data/handoff-x.md"; [ "$BEFORE" = "$(snap)" ] && echo "HOME UNCHANGED across sample (besides test-written doc): yes" || { echo HOME CHANGED; diff <(echo "$BEFORE") <(snap); }; printf "docs\n" > "$LAB/data/handoff-x.md"
echo "== S9 adversarial --home mismatch"; mkdir -p "$X/other/state"; run sample --home "$X/other" --out "$OUT"
echo "== S10 adversarial unsafe session id"; printf '../evil\n' > "$LAB/state/.lock-session"; run sample --home "$LAB" --out "$OUT"; tail -1 "$OUT/load.tsv"; printf 'sess-live\n' > "$LAB/state/.lock-session"
echo "== S11 adversarial watchdog-dir inside out"; mkdir -p "$OUT/wdin"; printf 'keep\n' > "$OUT/wdin/actions.tsv"; run finish --home "$LAB" --out "$OUT" --watchdog-dir "$OUT/wdin" --transcript-dir "$TR"; cat "$OUT/wdin/actions.tsv"; grep -c finished_at "$OUT/soak.json"
echo "== S4 finish"; sleep 1; N=$(date +%s)
printf '{"t":1}\n' > "$TR/sess-live.jsonl"; printf '{"t":2}\n' > "$TR/sess-other.jsonl"; touch -t 202001010000 "$TR/sess-ancient.jsonl"
printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup\n%s\tw9\t/elsewhere\tprimary\tfrozen\trestart\tdone\tx\n' "$N" "$LAB" "$N" > "$WD/actions.tsv"; printf 'wd\n' > "$WD/handoffs/primary-1.md"
printf 'doc=%s\nat=%s\n' "$LAB/data/handoff-x.md" "$N" > "$LAB/state/.order-handoff"
printf "%s\tack\tg2\t3\t3\t[\"c\"]\n" "$N" >> "$LAB/state/wake-ledger.tsv"; BEFORE=$(snap)
run finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"; cat "$OUT/soak.json"; echo
echo "-- out tree"; (cd "$OUT" && find . -type f | LC_ALL=C sort); echo "-- watchdog/actions.tsv"; cat "$OUT/watchdog/actions.tsv"; echo "-- wake-ledger.tsv"; cat "$OUT/wake-ledger.tsv"
[ "$BEFORE" = "$(snap)" ] && echo "HOME UNCHANGED across finish: yes" || { echo "HOME CHANGED"; diff <(echo "$BEFORE") <(snap); }
echo "== S12 sample after finish refused"; run sample --home "$LAB" --out "$OUT"
