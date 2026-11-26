#!/usr/bin/env bash
# Live CLI scenarios: the real bin/fm-wake-drain.sh against a disposable
# marked lab home (bin/fm-lab-home.sh create). Synthetic status/wake inputs.
set -u
ROOT=$1 LAB=$2
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export FM_HOME="$LAB"
S="$LAB/state"
: > "$LAB/config/supervision-host-off"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
say() { printf '\n=== %s\n' "$*"; }
scratch() { find "$S" -maxdepth 1 \( -name '.wake-drain-presentation.*' -o -name '.status-presentation.prepared.*' -o -name '*.open-decisions-cursor.read.*' \) | sed "s#$S/##" | sort; }

say "Scenario B: cold large decision fold under a 2s bound returns 124, keeps the queue, progresses, then completes"
st="$S/cold2.status"; printf 'kind=ship\n' > "$S/cold2.meta"; : > "$st"
for i in $(seq -w 0 29); do printf 'needs-decision [key=k%s]: live decision %s\n' "$i" "$i" >> "$st"; done
awk 'BEGIN{for(i=0;i<400;i++) print "working: historical presented context"}' >> "$st"
/bin/bash -c '. "$1/bin/fm-classify-lib.sh"; s=$(status_presentation_snapshot "$2") && status_commit_presentation_snapshot "$2" "$s"' _ "$ROOT" "$S"
/bin/bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check cold "cold fold wake"' _ "$ROOT"
cp "$S/.wake-queue" "$LAB/queue.B"
size=$(wc -c < "$st" | tr -d ' ')
attempt=0; prev=0; t0=$SECONDS
while :; do
  attempt=$((attempt+1)); a0=$SECONDS
  FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=2 "$DRAIN" > "$LAB/B.out" 2> "$LAB/B.err"; rc=$?
  off=$(/bin/bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_cursor_offset "$2"' _ "$ROOT" "$st")
  echo "attempt $attempt rc=$rc secs=$((SECONDS-a0)) fold-cursor=$off/$size leftover-scratch=[$(scratch | tr '\n' ' ')]"
  [ "$rc" = 124 ] && { grep -m1 'WAKE DRAIN INCOMPLETE' "$LAB/B.err"; grep -c 'cold fold wake' "$LAB/B.out" | sed 's/^/  wake row still presented: /'; }
  [ "$rc" = 0 ] && break
  [ "$rc" = 124 ] || { echo "UNEXPECTED rc"; cat "$LAB/B.err"; break; }
  [ "$off" -ge "$prev" ] || echo "REGRESSION: cursor moved back"
  prev=$off
  [ "$attempt" -lt 80 ] || { echo "never finished"; break; }
done
echo "completed after $attempt attempts in $((SECONDS-t0))s"
echo "open decisions presented: $(grep -c '\[key=k' "$LAB/B.out")/30"
cmp -s "$LAB/queue.B" "$S/.wake-queue" && echo "queue unchanged across bounded attempts: yes"

say "Scenario C: TERM during the cold fold leaves no attempt-owned scratch; next drain succeeds"
st2="$S/term.status"; printf 'kind=ship\n' > "$S/term.meta"; : > "$st2"
printf 'needs-decision [key=t1]: term decision\n' >> "$st2"
awk 'BEGIN{for(i=0;i<3000;i++) print "working: more history"}' >> "$st2"
/bin/bash -c '. "$1/bin/fm-classify-lib.sh"; s=$(status_presentation_snapshot "$2") && status_commit_presentation_snapshot "$2" "$s"' _ "$ROOT" "$S"
"$DRAIN" > "$LAB/C.out" 2> "$LAB/C.err" & dp=$!
for _ in $(seq 1 100); do [ -n "$(scratch)" ] && break; sleep 0.1; done
echo "scratch while running: [$(scratch | tr '\n' ' ')]"
kill -TERM "$dp"; wait "$dp"; echo "terminated drain rc=$?"
sleep 1
echo "scratch after TERM: [$(scratch | tr '\n' ' ')]"
echo "orphan workers: $(pgrep -f "$S" | wc -l | tr -d ' ')"
FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=600 "$DRAIN" > "$LAB/C2.out" 2> "$LAB/C2.err"; echo "follow-up drain rc=$?"
grep -c '\[key=t1\]' "$LAB/C2.out" | sed 's/^/term decision presented after recovery: /'
echo "scratch after follow-up: [$(scratch | tr '\n' ' ')]"

say "Scenario D: invalid bound falls back to 30s with a note"
FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=abc "$DRAIN" >/dev/null 2>"$LAB/D.err"; echo "rc=$?"; grep -m1 'not positive' "$LAB/D.err"
