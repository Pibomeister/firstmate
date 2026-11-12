#!/usr/bin/env bash
# Live driver: real bin/fm-session-start.sh against a disposable lab home with
# sandboxed HOME / XDG_CONFIG_HOME / NM_HOME. Never touches real git config or DB.
set -u
WT={run-worktree}
SB=$(mktemp -d "${TMPDIR:-/tmp}/fm-sbx.XXXXXX")
LAB="$SB/lab"; mkdir -p "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 9
TMXD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
GH="$SB/home"; NMH="$SB/nm"; mkdir -p "$GH" "$NMH"
# Keep the real harness login dirs reachable is not needed; session start only.
clear_locks() { rm -f "$LAB/state/.lock" "$LAB/state/.lock-session" "$LAB/state/.lock.acquire"* 2>/dev/null; }
ss() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u GIT_CONFIG_GLOBAL \
    -u TMUX -u TMUX_PANE -u CLAUDECODE \
    TMUX_TMPDIR="$TMXD" HOME="$GH" XDG_CONFIG_HOME="$GH/.config" NM_HOME="$NMH" FM_HOME="$LAB" \
    timeout 240 "$WT/bin/fm-session-start.sh" "$@" 2>&1
}
step() { # label args...
  local label=$1; shift
  local t0=$(date +%s) out
  out=$(ss "$@")
  echo "=== STEP: $label (rc=$?, $(( $(date +%s)-t0 ))s) ==="
  printf '%s\n' "$out" | grep -E 'SHARED_STATE|READ-ONLY SESSION' || echo "(no SHARED_STATE / READ-ONLY lines)"
  echo "--- baseline: $(cat "$LAB/state/.session-start-shared-baseline" 2>/dev/null | tr '\n' ' ' || echo none)"
}
MODE=${1:-git}
if [ "$MODE" = git ]; then
  clear_locks; step "1 first locked start, no global git config"
  clear_locks; step "2 unchanged locked start"
  B0=$(cat "$LAB/state/.session-start-shared-baseline")
  echo ">>> simulated worker: git config --file \$HOME/.gitconfig user.email rogue@example.invalid"
  git config --file "$GH/.gitconfig" user.email rogue@example.invalid
  clear_locks; echo held > "$LAB/state/.lock"; chmod 000 "$LAB/state/.lock"
  step "3 read-only (session lock unreadable -> lock refused)"
  chmod 600 "$LAB/state/.lock"
  [ "$(cat "$LAB/state/.session-start-shared-baseline")" = "$B0" ] && echo "CHECK: read-only preserved baseline" || echo "CHECK FAIL: read-only changed baseline"
  clear_locks; step "4 --reemit" --reemit
  [ "$(cat "$LAB/state/.session-start-shared-baseline")" = "$B0" ] && echo "CHECK: --reemit preserved baseline" || echo "CHECK FAIL: --reemit changed baseline"
  clear_locks; step "5 full locked start after change"
  [ "$(cat "$LAB/state/.session-start-shared-baseline")" != "$B0" ] && echo "CHECK: locked start advanced baseline" || echo "CHECK FAIL: baseline not advanced"
  clear_locks; step "6 next unchanged locked start"
else
  DB="$NMH/state.sqlite"
  clear_locks; step "1 first locked start, DB absent"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE runs(id INTEGER PRIMARY KEY, s TEXT)'); c.commit()" "$DB"
  echo ">>> DB created with table runs (absent -> present)"
  clear_locks; step "2 after initial DB creation"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executemany('INSERT INTO runs(s) VALUES (?)',[('a',),('b',)]); c.commit()" "$DB"
  echo ">>> DML: inserted 2 rows"
  clear_locks; step "3 after row inserts"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('ALTER TABLE runs ADD COLUMN rogue TEXT'); c.commit()" "$DB"
  echo ">>> DDL: ALTER TABLE runs ADD COLUMN rogue"
  clear_locks; step "4 after ALTER TABLE"
  clear_locks; step "5 next unchanged start"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE rogue2(x)'); c.commit()" "$DB"
  echo ">>> DDL: CREATE TABLE rogue2"
  clear_locks; step "6 after CREATE TABLE"
fi
"$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
rm -rf "$SB"
echo "sandbox removed: $SB"
