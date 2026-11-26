#!/bin/bash
# Live scenarios: the real bin/fm-wake-drain.sh against a disposable lab FM_HOME
# minted with bin/fm-lab-home.sh. Usage: live-drain-scenario.sh <repo-worktree>
set -u
REPO=$1
cd "$REPO" || exit 2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 2; }
mkdir -p "$LAB/tmux"
D() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
S="$LAB/state"; st="$S/task-cold.status"
FAILS=0
check() { if eval "$1"; then echo "  PASS: $2"; else echo "  FAIL: $2"; FAILS=$((FAILS+1)); fi; }

printf 'kind=ship\n' > "$S/task-cold.meta"
: > "$st"
for i in $(seq -w 0 39); do printf 'needs-decision [key=k%s]: exact decision %s\n' "$i" "$i" >> "$st"; done
awk -v n="${LINES_N:-2000}" 'BEGIN{for(i=0;i<n;i++) print "working: historical presented context"}' >> "$st"
cp "$st" "$LAB/history.before"

echo "### Scenario 1: cold fold of 40 open decisions + ${LINES_N:-2000} history lines under a ${BOUND:-2}s bound"
a=0; saw124=0; last=0
while :; do
  a=$((a+1)); s=$SECONDS
  D FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=${BOUND:-2} bash bin/fm-wake-drain.sh > "$LAB/a.out" 2> "$LAB/a.err"; last=$?
  inc=$(grep -h 'INCOMPLETE' "$LAB/a.out" "$LAB/a.err" | head -1)
  echo "  attempt $a: rc=$last took=$((SECONDS-s))s ${inc:+| $inc}"
  [ "$last" -eq 124 ] && saw124=1
  [ "$last" -eq 124 ] || break
  [ "$a" -lt 60 ] || break
done
check '[ "$last" -eq 0 ]' "bounded attempts converge to a completed drain (attempts=$a, last rc=$last)"
check 'cmp -s "$LAB/history.before" "$st"' "status history is byte-identical (no record cleared)"
n=$(grep -c '\[key=k' "$LAB/a.out")
echo "  completed attempt presented $n keyed decisions"
check '[ "$n" -ge 40 ]' "every one of the 40 open decisions is presented once the fold completes"
check '[ -z "$(ls -A "$S" | grep wake-drain-presentation)" ]' "no presentation scratch left behind in state/"
echo "  (saw a bounded 124 attempt: $saw124)"

echo "### Scenario 2: a TERM during a drain leaves no scratch and loses no pending note"
printf 'needs-decision [key=late]: decision appended after the first presentation\n' >> "$st"
cp "$st" "$LAB/history.before2"
D bash bin/fm-wake-drain.sh > "$LAB/t.out" 2> "$LAB/t.err" &
pid=$!
sleep 0.3; kill -TERM "$pid" 2>/dev/null; wait "$pid"; trc=$?
echo "  terminated drain rc=$trc"
sleep 1
check '[ -z "$(ls -A "$S" | grep wake-drain-presentation)" ]' "TERM leaves no presentation scratch in state/"
check 'cmp -s "$LAB/history.before2" "$st"' "TERM did not rewrite status history"
D bash bin/fm-wake-drain.sh > "$LAB/r.out" 2> "$LAB/r.err"; rrc=$?
echo "  next drain rc=$rrc"
check '[ "$rrc" -eq 0 ]' "the next drain completes"
check 'grep -q "key=late" "$LAB/t.out" "$LAB/r.out"' "the appended decision is presented by the interrupted or the next drain"

echo "### Scenario 3: an invalid bound falls back to the 30s default"
D FM_WAKE_DRAIN_PRESENTATION_TIMEOUT=abc bash bin/fm-wake-drain.sh > "$LAB/i.out" 2> "$LAB/i.err"; irc=$?
sed 's/^/  stderr: /' "$LAB/i.err" | head -3
check '[ "$irc" -eq 0 ] && grep -q "using 30" "$LAB/i.err"' "invalid bound warns and still completes (rc=$irc)"

echo "RESULT: failures=$FAILS"
exit "$FAILS"
