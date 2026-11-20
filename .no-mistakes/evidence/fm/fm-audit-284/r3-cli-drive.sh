#!/usr/bin/env bash
# Drive bin/fm-unpushed-reconcile.sh against a disposable home; usage: r3-cli-drive.sh <repo-root>
set -u
ROOT=$1; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-r3.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_GH_LOG"; [ -z "${FM_GH_SLEEP:-}" ] || sleep "$FM_GH_SLEEP"
printf 'count: 0\npull_requests: []\n'
SH
printf '#!/usr/bin/env bash\nprintf "code: NOT_FOUND\\n"; exit 1\n' > "$T/fakebin/tasks-axi"
chmod +x "$T/fakebin/"*; export PATH="$T/fakebin:$PATH" FM_GH_LOG="$T/gh.log"
export FM_HOME="$T/home"; P="$FM_HOME/projects/demo"; mkdir -p "$P" "$FM_HOME/data" "$FM_HOME/config" "$FM_HOME/state"
printf '%s\n' '- demo [no-mistakes] - fixture' > "$FM_HOME/data/projects.md"; : > "$FM_HOME/data/backlog.md"
g(){ git -C "$P" -c user.name=T -c user.email=t@example.com "$@"; }
g init -q -b main; g commit -qm base --allow-empty; g remote add origin https://github.com/example/demo.git
g update-ref refs/remotes/origin/main HEAD; g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
g checkout -qb fm/task; echo x > "$P/c.txt"; g add c.txt; g commit -qm change
printf 'project=%s\nbranch=fm/task\nkind=ship\nmode=no-mistakes\n' "$P" > "$FM_HOME/state/task.meta"
S="$ROOT/bin/fm-unpushed-reconcile.sh"
echo "== A: discover, then 4 s wait, then scan with deadline=now+20 (taken before wait), bound 20, forge stalls 60 s"
W="$T/w"; mkdir -m 700 "$W"; bash "$S" discover --work-dir "$W" >/dev/null
d=$(( $(date +%s) + 20 )); sleep 4
out=$(FM_UNPUSHED_DEADLINE=$d FM_UNPUSHED_TIMEOUT_SECS=20 FM_GH_SLEEP=60 bash "$S" scan --work-dir "$W"); f=$(date +%s)
echo "$out"; echo "deadline=$d finished=$f -> $([ $f -le $d ] && echo WITHIN || echo PAST) by $(( f - d ))s"
echo "== B: deadline already passed"
: > "$FM_GH_LOG"; out=$(FM_UNPUSHED_DEADLINE=$(( $(date +%s) - 1 )) bash "$S" scan); rc=$?
echo "$out"; echo "rc=$rc forge_calls=$(wc -l < "$FM_GH_LOG" | tr -d ' ')"
echo "== C: invalid deadline"
FM_UNPUSHED_DEADLINE=soon bash "$S" scan >/dev/null 2>&1; echo "rc=$?"
echo "== D: no deadline, normal scan (forge fast)"
: > "$FM_GH_LOG"; out=$(bash "$S" scan); rc=$?; echo "$out"; echo "rc=$rc forge_calls=$(wc -l < "$FM_GH_LOG" | tr -d ' ')"
