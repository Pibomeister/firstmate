#!/usr/bin/env bash
# Live end-to-end drive of bin/fm-soak-record.sh against a disposable lab home,
# with the real clock, real git, real fm-crew-state.sh / fm-wake-ledger.sh and a
# private lab tmux server holding a real task window.
set -u
WT=$1
cd "$WT"
SOAK="$WT/bin/fm-soak-record.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soak-live.XXXXXX")
cleanup() { bin/fm-lab-home.sh tmux "$LAB" kill-server >/dev/null 2>&1; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$WORK"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR="$TD"; unset TMUX TMUX_PANE
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
# Stand-in for the external no-mistakes daemon only: no run for any branch.
mkdir -p "$WORK/bin"; cat > "$WORK/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "axi status"|"axi ")
    b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); h=$(git rev-parse HEAD 2>/dev/null)
    case "$b" in
      fm/feat-a) printf 'run:\n  id: "01RUN"\n  branch: %s\n  status: running\n  head: "%s"\n  pr: ""\n  findings: none\n  steps[2]{step,status,findings,duration_ms}:\n    intent,completed,0,0\n    review,running,0,0\n' "$b" "$h" ;;
      fm/feat-c) printf 'run:\n  id: "01RUN"\n  branch: %s\n  status: awaiting_approval\n  awaiting_agent: parked 2m10s\n  head: "%s"\n  pr: ""\n  findings[1]{id,severity,file,line,action,description}:\n    r1,error,b.go,,ask-user,changes product behavior\ngate: review\n' "$b" "$h" ;;
    esac ;;
  "daemon status"|"daemon ") printf '  ● daemon running (pid 4242)\n' ;;
esac
exit 0
SH
chmod +x "$WORK/bin/no-mistakes"
export PATH="$WORK/bin:$PATH"
git -C "$LAB" init -q && git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m home
# Two task copies with real tmux windows: feat-a on claude, feat-c on codex.
for t in a c; do
  git -C "$WORK" init -q "copy-$t"; git -C "$WORK/copy-$t" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m i
  git -C "$WORK/copy-$t" checkout -q -b "fm/feat-$t"; git -C "$WORK/copy-$t" update-ref refs/remotes/origin/main "$(git -C "$WORK/copy-$t" rev-parse HEAD)"
done
bin/fm-lab-home.sh tmux "$LAB" new-session -d -s fm -n fm-feat-a "sh -c 'while :; do echo working on it; sleep 1; done'"
bin/fm-lab-home.sh tmux "$LAB" new-window -d -t fm: -n fm-feat-c "sh -c 'while :; do echo busy; sleep 1; done'"
printf 'window=fm:fm-feat-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=claude\n' "$WORK/copy-a" > "$LAB/state/feat-a.meta"
printf 'window=fm:fm-feat-c\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$WORK/copy-c" > "$LAB/state/feat-c.meta"
NOW=$(date +%s)
printf 'working [at=%s]: building\n' $((NOW - 60)) > "$LAB/state/feat-a.status"
printf 'working [at=%s]: old\n' $((NOW - 7200)) >> "$LAB/state/feat-a.status"
printf '%s\tack\tg1\t2\t1,2\t["a","b"]\n' $((NOW - 120)) > "$LAB/state/wake-ledger.tsv"
printf 'live-sess-1\nanchor_pid=1\n' > "$LAB/state/.lock-session"
mkdir -p "$LAB/data"
snap() { ( cd "$1" && find . -path ./state/.fm-lab-tmux-dir -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -f "$p" ]; then printf 'F %s %s %s\n' "$p" "$(stat -f %m "$p")" "$(cksum < "$p")"; else printf 'D %s %s\n' "$p" "$(stat -f %m "$p")"; fi; done ); }
OUT="$WORK/soak-out"; WD="$WORK/watchdog"; TR="$WORK/transcripts"; mkdir -p "$WD/handoffs" "$TR"
echo "== readable-harnesses"; bash "$SOAK" readable-harnesses; echo "exit=$?"
echo "== inventory claude codex"; bash "$SOAK" inventory --home "$LAB" --harness claude --harness codex; echo "exit=$?"
echo "== start with codex (must refuse 3)"; bash "$SOAK" start --home "$LAB" --out "$OUT" --label baseline --harness claude --harness codex; echo "exit=$? soak.json exists: $([ -e "$OUT/soak.json" ] && echo yes || echo no)"
echo "== adversarial --out inside home"; bash "$SOAK" start --home "$LAB" --out "$LAB/data/x" --label baseline --harness claude; echo "exit=$?"
echo "== adversarial --out containing home"; bash "$SOAK" start --home "$LAB" --out "$(dirname "$LAB")" --label baseline --harness claude; echo "exit=$?"
echo "== adversarial --out /"; bash "$SOAK" start --home "$LAB" --out / --label baseline --harness claude; echo "exit=$?"
UPLAB=$(printf '%s' "$LAB" | sed 's/fm-lab\./FM-LAB./')
echo "== adversarial --out inside a case alias of the home ($UPLAB/data/x)"; bash "$SOAK" start --home "$LAB" --out "$UPLAB/data/x" --label baseline --harness claude; echo "exit=$?"
BEFORE=$(snap "$LAB")
echo "== start (post-change, claude)"; bash "$SOAK" start --home "$LAB" --out "$OUT" --label post-change --harness claude; echo "exit=$?"; jq -c . "$OUT/soak.json"
echo "home HEAD: $(git -C "$LAB" rev-parse HEAD)"
printf '%s\tack\tg1\t4\t3,4\t["c","d"]\n' "$(date +%s)" >> "$LAB/state/wake-ledger.tsv"
sleep 1
# A handoff document, and an order record naming it through a case-alias spelling.
printf 'handoff one\n' > "$LAB/data/handoff-main.md"
printf 'doc=%s\nat=%s\nowner=1\n' "$UPLAB/data/handoff-main.md" "$(date +%s)" > "$LAB/state/.order-handoff"
BEFORE=$(snap "$LAB")
echo "== sample 1"; bash "$SOAK" sample --home "$LAB" --out "$OUT"; echo "exit=$?"
echo "-- load.tsv"; cat "$OUT/load.tsv"; echo "-- handoff-events.tsv"; cat "$OUT/handoff-events.tsv"
[ "$(snap "$LAB")" = "$BEFORE" ] && echo "HOME UNCHANGED after sample" || { echo "HOME CHANGED after sample"; diff <(echo "$BEFORE") <(snap "$LAB"); }
echo "== crew-state as seen by recorder"; FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 bin/fm-crew-state.sh feat-a feat-c 2>&1 | head -4
echo "== sample with a different --home (must refuse 2)"; mkdir -p "$WORK/other"; bash "$SOAK" sample --home "$WORK/other" --out "$OUT"; echo "exit=$?"
echo "== adversarial finish --watchdog-dir inside --out (must refuse 2)"; mkdir -p "$OUT/wd"; bash "$SOAK" finish --home "$LAB" --out "$OUT" --watchdog-dir "$OUT/wd" --transcript-dir "$TR"; echo "exit=$? finished_at=$(jq -r '.finished_at // "unset"' "$OUT/soak.json")"; rmdir "$OUT/wd"
sleep 1
printf 'handoff two\n' > "$LAB/data/handoff-main.md"
echo "== sample 2 (after rewrite)"; bash "$SOAK" sample --home "$LAB" --out "$OUT" >/dev/null; echo "exit=$?"; cat "$OUT/handoff-events.tsv"
printf '{"type":"user"}\n' > "$TR/live-sess-1.jsonl"; printf '{"type":"user"}\n' > "$TR/live-sess-2.jsonl"
T=$(date +%s)
printf '%s\tw1\t%s\tprimary\tfrozen\trestart\tdone\tpickup verified\n' "$T" "$LAB" > "$WD/actions.tsv"
printf '%s\tw9\t%s\tprimary\tfrozen\trestart\tdone\tother home\n' "$T" "$WORK/other" >> "$WD/actions.tsv"
printf 'wd handoff\n' > "$WD/handoffs/primary-1.md"
sleep 1
BEFORE=$(snap "$LAB")
echo "== finish"; bash "$SOAK" finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"; echo "exit=$?"
[ "$(snap "$LAB")" = "$BEFORE" ] && echo "HOME UNCHANGED after finish" || { echo "HOME CHANGED after finish"; diff <(echo "$BEFORE") <(snap "$LAB"); }
echo "-- soak.json"; jq . "$OUT/soak.json"
echo "-- out tree"; (cd "$OUT" && find . -type f | LC_ALL=C sort)
echo "-- watchdog/actions.tsv"; cat "$OUT/watchdog/actions.tsv"
echo "-- wake-ledger.tsv"; cat "$OUT/wake-ledger.tsv"
echo "== finish again (must refuse 1)"; bash "$SOAK" finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"; echo "exit=$?"
echo "== no lab state leaked into home: $(ls -a "$LAB/state" | tr '\n' ' ')"
