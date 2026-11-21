#!/usr/bin/env bash
# Live driver: runs the real scanner CLI against a disposable FM_HOME with a slow fake forge.
set -u
BIN=$1   # bin dir under test
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-unpushed.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GH_LOG"
[ -z "${FM_GH_PID:-}" ] || printf '%s\n' "$$" > "$FM_GH_PID"
[ -z "${FM_GH_SLEEP:-}" ] || sleep "$FM_GH_SLEEP"
printf 'count: 0\npull_requests: []\n'
SH
printf '#!/usr/bin/env bash\nprintf "code: NOT_FOUND\\n"; exit 1\n' > "$T/fakebin/tasks-axi"
chmod +x "$T/fakebin/"*
export PATH="$T/fakebin:$PATH" FM_GH_LOG="$T/gh.log" FM_HOME="$T/home"
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
P=$FM_HOME/projects/demo
mkdir -p "$P" "$FM_HOME/data" "$FM_HOME/config" "$FM_HOME/state"
echo '- demo [no-mistakes] - fixture' > "$FM_HOME/data/projects.md"
echo '- [ ] task - example' > "$FM_HOME/data/backlog.md"
g() { git -C "$P" -c user.name=T -c user.email=t@example.com "$@"; }
g init -q -b main; g commit -qm base --allow-empty
g remote add origin https://github.com/example/demo.git
g update-ref refs/remotes/origin/main HEAD; g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
g checkout -qb fm/task; echo c > "$P/c.txt"; g add c.txt; g commit -qm change
printf 'project=%s\nbranch=fm/task\nkind=ship\nmode=no-mistakes\n' "$P" > "$FM_HOME/state/task.meta"
: > "$FM_GH_LOG"
S="$BIN/fm-unpushed-reconcile.sh"

echo "== A: deadline 20s ahead, 4s spent before scan, bound 20s, forge stalls 60s"
W=$T/wa; mkdir -m 700 "$W"
bash "$S" discover --work-dir "$W" >/dev/null
dl=$(( $(date +%s) + 20 )); start=$(date +%s); sleep 4
out=$(FM_UNPUSHED_DEADLINE=$dl FM_UNPUSHED_TIMEOUT_SECS=20 FM_GH_SLEEP=60 bash "$S" scan --work-dir "$W" 2>&1)
fin=$(date +%s)
echo "$out"
echo "deadline=$dl finished=$fin elapsed=$((fin-start)) -> $([ "$fin" -le "$dl" ] && echo WITHIN_DEADLINE || echo PAST_DEADLINE)"

echo "== B: kill only the scanner during its forge read, then run pending"
W=$T/wb; mkdir -m 700 "$W"; rm -f "$T/gh.pid"
FM_UNPUSHED_TIMEOUT_SECS=60 FM_GH_SLEEP=60 FM_GH_PID="$T/gh.pid" bash "$S" scan --work-dir "$W" >/dev/null 2>&1 &
sp=$!
for _ in $(seq 1 600); do [ -s "$T/gh.pid" ] && break; sleep 0.1; done
fp=$(cat "$T/gh.pid" 2>/dev/null)
kill -KILL "$sp"; wait "$sp" 2>/dev/null
echo "forge pid=$fp alive after scanner kill: $(kill -0 "$fp" 2>/dev/null && echo yes || echo no)"
t0=$(date +%s); out=$(bash "$S" pending --work-dir "$W" 2>&1)
for _ in $(seq 1 10); do kill -0 "$fp" 2>/dev/null || break; sleep 0.2; done
echo "$out"
echo "forge alive after pending: $(kill -0 "$fp" 2>/dev/null && { kill "$fp"; echo YES_LEAKED; } || echo no_ended) (pending took $(( $(date +%s)-t0 ))s)"

echo "== C: pending with a recorded unrelated process group"
if [ -f "$S" ] && command -v perl >/dev/null; then
  perl -MPOSIX=setpgid -e 'setpgid(0,0); exec "sleep","30"' & o=$!; sleep 0.5
  echo "$o" > "$W/group"; bash "$S" pending --work-dir "$W" >/dev/null 2>&1
  echo "unrelated group alive: $(kill -0 $o 2>/dev/null && echo yes_spared || echo NO_KILLED)"; kill $o 2>/dev/null
  echo "$(ps -o pgid= -p $$ | tr -d ' ')" > "$W/group"; bash "$S" pending --work-dir "$W" >/dev/null 2>&1
  echo "own group survived pending: yes"
fi

echo "== D: passed deadline and invalid deadline"
: > "$FM_GH_LOG"
out=$(FM_UNPUSHED_DEADLINE=$(( $(date +%s) - 1 )) bash "$S" scan 2>&1); echo "$out"
echo "forge reads with passed deadline: $(wc -l < "$FM_GH_LOG" | tr -d ' ')"
FM_UNPUSHED_DEADLINE=soon bash "$S" scan >/dev/null 2>&1; echo "invalid deadline exit=$?"
