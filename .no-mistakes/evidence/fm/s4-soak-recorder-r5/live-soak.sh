#!/usr/bin/env bash
# Live end-to-end drive of bin/fm-soak-record.sh against a disposable lab home.
set -u
REPO=$1
R="$REPO/bin/fm-soak-record.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-soak-work.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TDIR=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB")
cleanup() { "$REPO/bin/fm-lab-home.sh" tmux "$LAB" kill-server 2>/dev/null; "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$WORK"; }
trap cleanup EXIT
unset TMUX TMUX_PANE NO_MISTAKES_GATE FM_STATE_OVERRIDE
export TMUX_TMPDIR="$TDIR"
git -C "$LAB" init -q && git -C "$LAB" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m lab
echo "== lab home revision: $(git -C "$LAB" rev-parse HEAD)"
# Real tmux session 'fm' on the lab's private server with two worker windows.
"$REPO/bin/fm-lab-home.sh" tmux "$LAB" new-session -d -s fm -n fm-feat-a 'sleep 600'
"$REPO/bin/fm-lab-home.sh" tmux "$LAB" new-window -t fm: -n fm-feat-c 'sleep 600'
for t in a c z; do mkdir -p "$WORK/wt-$t"; git -C "$WORK/wt-$t" init -q; git -C "$WORK/wt-$t" -c user.name=t -c user.email=t@x.invalid commit -q --allow-empty -m i; done
printf 'window=fm:fm-feat-a\nworktree=%s\nkind=ship\nbackend=tmux\nharness=claude\n' "$WORK/wt-a" > "$LAB/state/feat-a.meta"
printf 'window=fm:fm-feat-c\nworktree=%s\nkind=ship\nbackend=tmux\nharness=gemini\n' "$WORK/wt-c" > "$LAB/state/feat-c.meta"
printf 'window=fm:fm-feat-z\nworktree=%s\nkind=ship\nbackend=tmux\nharness=codex\n' "$WORK/wt-z" > "$LAB/state/feat-z.meta"
"$REPO/bin/fm-busy-event.sh" arm "$LAB/state" feat-a --state busy --source claude-hook --event UserPromptSubmit >/dev/null
"$REPO/bin/fm-busy-event.sh" arm "$LAB/state" feat-c --state busy --source gemini-hook --event BeforeAgent >/dev/null
printf 'sess-1234\nanchor_pid=1\n' > "$LAB/state/.lock-session"
NOW=$(date +%s)
printf 'working [at=%s]: building\nold [at=%s]: stale\n' $((NOW-100)) $((NOW-7200)) > "$LAB/state/feat-a.status"
printf '%s\tack\t-\t3\t1,2,3\t["a","b","c"]\n%s\tack\t-\t4\t4\t["d"]\n' $((NOW-50)) $((NOW-5000)) > "$LAB/state/wake-ledger.tsv"
snap() { (cd "$LAB" && find . -path ./.git -prune -o -print0 | xargs -0 perl -MTime::HiRes=lstat -e 'for(@ARGV){@s=lstat $_; print "$_ $s[9] $s[7]\n"}' | sort); }
rec() { local b a rc; b=$(snap); "$R" "$@"; rc=$?; a=$(snap); [ "$a" = "$b" ] || { echo "!! HOME CHANGED by: $1"; diff <(echo "$b") <(echo "$a"); }; return $rc; }
OUT="$WORK/out"; WD="$WORK/wd"; TR="$WORK/tr"; mkdir -p "$WD/handoffs" "$TR"
echo; echo "== crew state as the recorder sees it"
for t in feat-a feat-c feat-z; do FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 "$REPO/bin/fm-crew-state.sh" $t 2>&1 | head -1; done
echo; echo "== readable-harnesses"; rec readable-harnesses
echo; echo "== inventory claude codex"; rec inventory --home "$LAB" --harness claude --harness codex; echo "exit=$?"
echo; echo "== start with an unreadable harness (codex)"; rec start --home "$LAB" --out "$OUT" --label baseline --harness codex; echo "exit=$? soak.json exists: $([ -e "$OUT/soak.json" ] && echo yes || echo no)"
echo; echo "== adversarial: --out inside the home / containing the home / root"
rec start --home "$LAB" --out "$LAB/data/x" --label baseline --harness claude; echo "exit=$?"
rec start --home "$LAB" --out "$(dirname "$LAB")" --label baseline --harness claude; echo "exit=$?"
rec start --home "$LAB" --out / --label baseline --harness claude; echo "exit=$?"
rec start --home "$LAB" --out // --label baseline --harness claude; echo "exit=$?"
HOMESNAP_BEFORE=$(cd "$LAB" && find . -path ./.git -prune -o -print0 | xargs -0 stat -f '%N %m %z' | sort | shasum)
echo; echo "== start (baseline, claude)"; rec start --home "$LAB" --out "$OUT" --label baseline --harness claude; echo "exit=$?"; cat "$OUT/soak.json"
# Session lock records primary session id (written the way the lock lib does).
printf 'sess-1234\n' >/dev/null
echo; echo "== sample"; rec sample --home "$LAB" --out "$OUT"; echo "exit=$?"; printf 'epoch\tlive\tacks\tstatus\tsession\n'; cat "$OUT/load.tsv"
echo; echo "== adversarial: sample with a different --home"; OTHER="$WORK/other"; mkdir -p "$OTHER/state"; rec sample --home "$OTHER" --out "$OUT"; echo "exit=$?"
# Window activity: handoff doc, order doc, transcript, watchdog rows.
sleep 1
printf '# handoff\n' > "$LAB/data/handoff-1.md"
printf '{"x":1}\n' > "$TR/sess-abc.jsonl"; printf '%s\tack\t-\t5\t5,6\t["e","f"]\n' $(date +%s) >> "$LAB/state/wake-ledger.tsv"
printf '{"x":1}\n' > "$TR/../evil.jsonl" 2>/dev/null
T=$(date +%s)
printf '%s\tw1\t%s\tlow-context\trestart-requested\trestart\tdone\n%s\tw2\t%s\tfrozen\tfrozen\trestart\tdone\n%s\tw3\t/other/home\tx\tfrozen\trestart\tdone\n' $T "$LAB" $T "$LAB" $T > "$WD/actions.tsv"
printf 'lean\n' > "$WD/handoffs/wd-1.md"
echo; echo "== sample after a handoff"; rec sample --home "$LAB" --out "$OUT"; echo "exit=$?"; cat "$OUT/handoff-events.tsv" | sed "s#$LAB#<LAB>#"
echo; echo "== adversarial: finish with --watchdog-dir inside --out"; mkdir -p "$OUT/wdin"; rec finish --home "$LAB" --out "$OUT" --watchdog-dir "$OUT/wdin" --transcript-dir "$TR"; echo "exit=$? finished_at=$(jq -r '.finished_at // "unset"' "$OUT/soak.json")"; rmdir "$OUT/wdin"
echo; echo "== finish"; rec finish --home "$LAB" --out "$OUT" --watchdog-dir "$WD" --transcript-dir "$TR"; echo "exit=$?"
jq . "$OUT/soak.json" | sed "s#$LAB#<LAB>#g; s#$WORK#<WORK>#g"
echo; echo "== out tree"; (cd "$OUT" && find . -type f | sort)
echo; echo "== watchdog/actions.tsv"; sed "s#$LAB#<LAB>#" "$OUT/watchdog/actions.tsv"
echo; echo "== wake-ledger.tsv"; cat "$OUT/wake-ledger.tsv"
echo; echo "== sample after finish"; rec sample --home "$LAB" --out "$OUT"; echo "exit=$?"
HOMESNAP_AFTER=$(cd "$LAB" && find . -path ./.git -prune -o -print0 | xargs -0 stat -f '%N %m %z' | sort | shasum)
echo; echo "== soak home unchanged apart from the lab's own test writes? recorder-only comparison below"
# The only home writes between snapshots were the test's own handoff-1.md; check no other file appeared
(cd "$LAB" && find . -path ./.git -prune -o -type f -newer "$OUT/soak.json" -print | sort)
echo; echo "== post-change run: activity-sources violation"
OUT2="$WORK/out2"; rec start --home "$LAB" --out "$OUT2" --label post-change --harness claude >/dev/null; rec sample --home "$LAB" --out "$OUT2"; rec finish --home "$LAB" --out "$OUT2" --watchdog-dir "$WD" --transcript-dir "$TR"; echo "exit=$?"; jq -c .violations "$OUT2/soak.json"
