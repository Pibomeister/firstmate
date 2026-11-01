REAL_TASKS=$(command -v tasks-axi)
cat > "$FM_HOME/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
mkdir -p "$FM_HOME/data"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
(cd "$FM_HOME" && "$REAL_TASKS" add agy-backlog 'AGY backlog failure lab' --kind ship --file "$FM_HOME/data/backlog.md")
cat > "$BASE/shim/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then echo 'INJECTED: backlog start unavailable' >&2; exit 1; fi
exec '$REAL_TASKS' "\$@"
SH
chmod +x "$BASE/shim/tasks-axi"
brief agy-backlog backlog
python3 - "$FM_HOME/data/agy-backlog/brief.md" <<'PYB'
import sys
p=sys.argv[1]
s=open(p).read().replace('# Task\n', "# Task\n## Captain's intent\nProve AGY launch failure keeps the task record.\n## Firstmate spec\n")
open(p,'w').write(s)
PYB
rc=0
"$ROOT/bin/fm-spawn.sh" agy-backlog "$PROJECT" --harness agy --model gemini-3.8-flash-low --effort low --backend tmux --mode no-mistakes --yolo off || rc=$?
test "$rc" -ne 0
test -f "$FM_HOME/state/agy-backlog.meta"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-backlog.meta")
test -d "$WT"
echo "Failed backlog transition preserved task agy-backlog worktree=$WT exit=$rc"
(cd "$FM_HOME" && "$REAL_TASKS" show agy-backlog --file "$FM_HOME/data/backlog.md")
(cd "$PROJECT" && treehouse status --json)
retire agy-backlog
echo 'PASS: post-launch backlog failure preserves a teardown-resolvable AGY record'
