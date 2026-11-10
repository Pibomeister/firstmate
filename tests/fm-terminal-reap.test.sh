#!/usr/bin/env bash
# Behavior tests for bin/fm-terminal-reap.sh.
#
# Orca and the working-directory scan are faked so each case controls exactly
# which terminals exist and where processes work. The process trees behind the
# terminals are real: idle sessions are real shells, live sessions run a real
# agent stand-in, so the idle and live-agent verdicts come from the same reads
# the script makes on a host.
# The fake scan lists only this suite's processes, so any real browser on the
# test host reads as unknown and is never stopped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || { echo "fm-terminal-reap.test: cannot load tests/lib.sh" >&2; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# Every fixture and the cleanup trap work under TMP_ROOT, so it must be a real
# temporary directory and never the checkout.
TMP_ROOT=$(fm_test_tmproot fm-terminal-reap) && [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] \
  && TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P) && [ -n "$TMP_ROOT" ] && [ "$TMP_ROOT" != "$ROOT" ] \
  || { echo "fm-terminal-reap.test: cannot create a temporary directory" >&2; exit 1; }
REAP="$ROOT/bin/fm-terminal-reap.sh"

TRACKED_PIDS=()
reap_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
}
# Permission cases lock directories; unlock everything before removal.
trap 'reap_cleanup; chmod -R u+rwx "$TMP_ROOT" 2>/dev/null; fm_test_cleanup' EXIT

STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || STANDIN=
if [ -n "$STANDIN" ]; then
  mkdir -p "$TMP_ROOT/agent-bin"
  ln -sf "$STANDIN" "$TMP_ROOT/agent-bin/claude"
fi

FB="$TMP_ROOT/fakebin"
mkdir -p "$FB"
cat > "$FB/orca" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/orca.log"
case "$1 $2" in
  "terminal list") cat "$FX/list.json" ;;
  "diagnostics memory") cat "$FX/memory.json" ;;
  "terminal show")
    # A per-handle hook changes the world between the listing and the close.
    if [ -x "$FX/onshow-$4" ]; then "$FX/onshow-$4"; fi
    if [ -f "$FX/show-$4.json" ]; then cat "$FX/show-$4.json"
    else printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n'; exit 1; fi
    ;;
  "terminal close") printf '%s\n' "$4" >> "$FX/closed.log"; printf '{"ok":true,"result":{}}\n' ;;
  *) printf '{"ok":false}\n'; exit 1 ;;
esac
SH
cat > "$FB/lsof" <<'SH'
#!/usr/bin/env bash
cat "$FX/lsof.out"
SH
# In the process-table snapshot, a pid with a ppid1-<pid> marker reads as an
# orphan whose parent is pid 1.
# ps passes through, except that a pid with a fresh-<pid> marker reads as just
# started, the shape of a pid reused after the reaper's process snapshot.
REAL_PS=$(command -v ps)
cat > "$FB/ps" <<SH
#!/usr/bin/env bash
if [ "\$1" = -p ] && [ "\${3:-}" = -o ] && [ "\${4:-}" = etime= ] && [ -n "\${FX:-}" ] && [ -f "\$FX/fresh-\$2" ]; then
  printf '   00:00\n'; exit 0
fi
if [ "\$*" = "-axo pid=,ppid=,etime=,args=" ] && [ -n "\${FX:-}" ] && ls "\$FX"/ppid1-* >/dev/null 2>&1; then
  out=\$('$REAL_PS' "\$@") || exit
  marks=\$(cd "\$FX" && ls ppid1-* | sed 's/^ppid1-//' | tr '\n' ' ')
  printf '%s\n' "\$out" | awk -v marks="\$marks" 'BEGIN { n = split(marks, m, " "); for (i = 1; i <= n; i++) o[m[i]] = 1 }
    (\$1 in o) { \$2 = 1 } { print }'
  exit 0
fi
exec '$REAL_PS' "\$@"
SH
chmod +x "$FB/orca" "$FB/lsof" "$FB/ps"

# Process starters set PID rather than print it: a command substitution would
# wait on the background process and lose the tracked pid in its subshell.
# idle_shell: a real shell with no child, the dead-session shape.
idle_shell() {  # -> PID
  local fifo
  fifo=$(mktemp -u "$TMP_ROOT/fifo.XXXXXX")
  mkfifo "$fifo"
  bash -c 'read -r _ <> "$1"' _ "$fifo" >/dev/null 2>&1 </dev/null &
  PID=$!
  disown "$PID" 2>/dev/null || true
  TRACKED_PIDS+=("$PID")
}

# agent_session: a real shell running the agent stand-in.
agent_session() {  # -> PID
  bash -c '"$1" 600; :' _ "$TMP_ROOT/agent-bin/claude" >/dev/null 2>&1 </dev/null &
  PID=$!
  disown "$PID" 2>/dev/null || true
  TRACKED_PIDS+=("$PID")
}

# orphan_idle_shell: an idle shell reparented to pid 1, so once killed it
# leaves the process table at once instead of lingering as this suite's zombie.
orphan_idle_shell() {  # -> PID
  local fifo pidf
  fifo=$(mktemp -u "$TMP_ROOT/fifo.XXXXXX")
  mkfifo "$fifo"
  pidf=$(mktemp "$TMP_ROOT/pid.XXXXXX")
  ( bash -c 'read -r _ <> "$1"' _ "$fifo" >/dev/null 2>&1 </dev/null & printf '%s\n' "$!" > "$pidf" )
  PID=$(cat "$pidf")
  TRACKED_PIDS+=("$PID")
}

idle_term() {  # <handle> <pty> <path> <title>
  term "$@"
  idle_shell
  session "$2" "$PID"
}

# Terminal and session fixture rows, assembled into Orca's JSON shapes.
fixture_reset() {  # <case>
  FX="$TMP_ROOT/$1"
  export FX
  mkdir -p "$FX"
  : > "$FX/orca.log"; : > "$FX/closed.log"; : > "$FX/lsof.out"
  : > "$FX/terms.tsv"; : > "$FX/sessions.tsv"
}
term() {  # <handle> <pty> <path> <title> [host]
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-local}" >> "$FX/terms.tsv"
}
session() {  # <pty> <pid>
  printf '%s\t%s\n' "$1" "$2" >> "$FX/sessions.tsv"
}
show() {  # <handle> <pty> <path>
  node -e 'const [h,p,w]=process.argv.slice(1);console.log(JSON.stringify({ok:true,result:{terminal:{handle:h,connected:true,writable:true,executionHostId:"local",ptyId:p,worktreePath:w}}}))' \
    "$1" "$2" "$3" > "$FX/show-$1.json"
}
fixture_write() {
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansion
  node -e '
const fs = require("fs"); const fx = process.argv[1];
const rows = (f) => fs.readFileSync(`${fx}/${f}`, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t"));
const terminals = rows("terms.tsv").map(([handle, ptyId, worktreePath, title, executionHostId]) =>
  ({ handle, ptyId, worktreePath, title, executionHostId, connected: true, writable: true, orphaned: false }));
const sessions = rows("sessions.tsv").map(([sessionId, pid]) => ({ sessionId, pid: Number(pid) }));
fs.writeFileSync(`${fx}/list.json`, JSON.stringify({ ok: true, result: { terminals, truncated: false } }));
fs.writeFileSync(`${fx}/memory.json`, JSON.stringify({ ok: true, result: { worktrees: [{ sessions }] } }));
' "$FX"
}
cwd_row() {  # <pid> <cwd>
  printf 'p%s\nn%s\n' "$1" "$2" >> "$FX/lsof.out"
}

run_reap() {  # [args...] -> stdout of the reaper; exit status in RC
  RC=0
  OUT=$(PATH="$FB:$PATH" FM_HOME="$HOME_DIR" bash "$REAP" --min-age 0 "$@" 2>"$FX/stderr") || RC=$?
}

verdict_of() {  # <id> -> "<action> <class>" from the last OUT
  printf '%s\n' "$OUT" | awk -F'\t' -v id="$1" '$4 == id { print $1, $3 }'
}

expect() {  # <id> <action class> <why>
  local got
  got=$(verdict_of "$1")
  [ "$got" = "$2" ] || fail "$3: $1 should read '$2', got '$got' (stderr: $(cat "$FX/stderr"))"
}

clone_worktree() {  # <bare> <dir>
  git clone -q "file://$1" "$2"
}

# build_world: a home with one recorded task, a local secondmate home with its
# own recorded task, and one terminal for every terminal verdict.
build_world() {  # <case>
  local bare p
  fixture_reset "$1"
  HOME_DIR="$FX/home"
  SM_HOME="$FX/sm-home"
  WS="$FX/workspaces"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$SM_HOME/state" "$WS" "$FX/elsewhere"
  printf -- '- sm1 - Test secondmate (home: %s; scope: tests; projects: alpha; added 2026-01-01)\n' "$SM_HOME" \
    > "$HOME_DIR/data/secondmates.md"

  fm_git_init_commit "$FX/src"
  bare="$FX/src.git"
  git clone -q --bare "$FX/src" "$bare"
  for p in fm-t-live fm-landed; do clone_worktree "$bare" "$WS/$p"; done

  fm_write_meta "$HOME_DIR/state/t-live.meta" kind=ship backend=orca terminal=term-task "worktree=$WS/fm-t-live"
  fm_write_meta "$SM_HOME/state/s-task.meta" kind=ship backend=orca terminal=term-smtask "worktree=$FX/sm-wt"

  term term-remote pty-remote "$HOME_DIR" "main successor" ssh-box
  idle_term term-task pty-task "$WS/fm-t-live" fm-t-live
  idle_term term-smtask pty-smtask "$FX/sm-wt" fm-s-task
  idle_term term-twt pty-twt "$WS/fm-t-live" "Terminal 1"
  idle_term term-foreign pty-foreign "$FX/elsewhere" "captain lane"
  idle_term term-captain pty-captain "$HOME_DIR" "Terminal 2"
  idle_term term-untitled pty-untitled "$HOME_DIR" ""
  idle_term term-claude pty-claude "$HOME_DIR" "✳ Claude Code"
  idle_term term-notes pty-notes "$HOME_DIR" "notes"
  idle_term term-m4 pty-m4 "$HOME_DIR" "M4 main successor"
  idle_term term-handoff pty-handoff "$HOME_DIR" "FM handoff"
  idle_term term-idle pty-idle "$HOME_DIR" "fm main successor"
  idle_term term-mfch pty-mfch "$HOME_DIR" "M4 main Firstmate captain handoff"
  idle_term term-stamp pty-stamp "$HOME_DIR" "fm-main-successor-2300Z"
  idle_term term-path pty-path "$HOME_DIR" "eduardo@m4: ~/orca/projects/firstmate"
  idle_term term-branch pty-branch "$HOME_DIR" "zsh (main)"
  idle_term term-nested pty-nested "$HOME_DIR" "zsh (feature(old)-main)"
  idle_term term-unbalanced pty-unbalanced "$HOME_DIR" "zsh (main"
  idle_term term-pathseg pty-pathseg "$HOME_DIR" "user@host: ~/orca/projects/(old)firstmate"
  idle_term term-wordseg pty-wordseg "$HOME_DIR" "zsh [wip]fm"
  idle_term term-leash pty-leash "$HOME_DIR" "leash-drop-2236"
  idle_term term-muse pty-muse "$HOME_DIR" "Muse Code under Astra Opus"
  idle_term term-sm-idle pty-sm-idle "$SM_HOME" "sm1 successor"
  idle_term term-gone pty-gone "$WS/fm-gone" fm-gone
  idle_term term-landed pty-landed "$WS/fm-landed" fm-landed
  term term-nosession pty-none "$HOME_DIR" "old main"
  if [ -n "$STANDIN" ]; then
    local agent
    agent_session
    agent=$PID
    term term-agent pty-agent "$HOME_DIR" "fm main"; session pty-agent "$agent"
    # An idle home session that gains an agent between the listing and the
    # close: Orca's fresh read names a session running the stand-in.
    idle_term term-flip pty-flip "$HOME_DIR" "fm main handoff"
    session pty-flip-now "$agent"
    show term-flip pty-flip-now "$HOME_DIR"
  fi
  for p in term-idle:pty-idle:"$HOME_DIR" term-m4:pty-m4:"$HOME_DIR" term-handoff:pty-handoff:"$HOME_DIR" term-sm-idle:pty-sm-idle:"$SM_HOME" \
    term-mfch:pty-mfch:"$HOME_DIR" term-stamp:pty-stamp:"$HOME_DIR" \
    term-gone:pty-gone:"$WS/fm-gone" term-landed:pty-landed:"$WS/fm-landed"; do
    show "${p%%:*}" "$(printf '%s' "$p" | cut -d: -f2)" "${p#*:*:}"
  done
  fixture_write
}

test_dry_run_classifies_every_owner_and_closes_nothing() {
  build_world dry
  run_reap
  [ "$RC" = 0 ] || fail "a dry run over a readable inventory must exit 0, got $RC: $(cat "$FX/stderr")"
  expect term-remote "keep remote" "a terminal on another host is out of scope"
  expect term-task "keep task" "a recorded endpoint belongs to its task"
  expect term-smtask "keep task" "a secondmate home's recorded endpoint belongs to its task"
  expect term-twt "keep task-worktree" "an extra terminal in a recorded task's worktree belongs to that task"
  expect term-foreign "keep foreign" "a terminal outside every home and firstmate worktree is the captain's"
  expect term-captain "keep captain" "an idle default-titled tab in a home root is the captain's own"
  expect term-untitled "keep captain" "an idle untitled tab in a home root is the captain's own"
  expect term-claude "keep captain" "a program-written title that names no firstmate session is the captain's"
  expect term-notes "keep captain" "a captain-chosen title in a home root is the captain's own"
  expect term-m4 "reap idle-session" "a title naming a main successor marks a firstmate session"
  expect term-handoff "reap idle-session" "a title naming a handoff matches in any case"
  expect term-nosession "keep no-session" "a terminal Orca's sweep cannot name is never judged idle"
  expect term-idle "reap idle-session" "a finished firstmate session at its prompt is an orphan"
  expect term-sm-idle "reap idle-session" "a secondmate home root is a home root"
  expect term-mfch "reap idle-session" "a handoff title with firstmate words is a firstmate session"
  expect term-stamp "reap idle-session" "a hyphenated session name still yields whole title words"
  expect term-path "keep captain" "a home-root path in a shell title is not a firstmate session name"
  expect term-branch "keep captain" "a parenthesized branch name is not a firstmate session name"
  expect term-nested "keep captain" "a nested parenthesized branch name is not a firstmate session name"
  expect term-unbalanced "keep captain" "a title whose brackets do not balance is never a firstmate session name"
  expect term-pathseg "keep captain" "a bracketed segment inside a path part never exposes a firstmate word"
  expect term-wordseg "keep captain" "a word a bracketed segment touches is dropped whole"
  expect term-leash "keep captain" "a task-like title naming no firstmate word is the captain's"
  expect term-muse "keep captain" "a program title naming no firstmate word is the captain's"
  expect term-gone "keep unowned-task" "an idle shell in an unrecorded, gone task worktree may belong to another home"
  expect term-landed "keep unowned-task" "an idle shell in an unrecorded, present task worktree may belong to another home"
  if [ -n "$STANDIN" ]; then
    expect term-agent "keep live-agent" "a session running an agent harness is live"
  else
    pass "SKIP: live-agent case (no agent stand-in survives here)"
  fi
  [ ! -s "$FX/closed.log" ] || fail "a dry run must close nothing, closed: $(cat "$FX/closed.log")"
  assert_contains "$OUT" "summary: mode=dry-run" "a dry run must end with its summary line"
  pass "fm-terminal-reap: a dry run classifies every owner and closes nothing"
}

test_min_age_keeps_young_sessions() {
  build_world young
  RC=0
  OUT=$(PATH="$FB:$PATH" FM_HOME="$HOME_DIR" bash "$REAP" --min-age 86400 --no-browsers 2>"$FX/stderr") || RC=$?
  [ "$RC" = 0 ] || fail "the young-session run must exit 0, got $RC"
  expect term-idle "keep young" "a session younger than --min-age may still be launching its agent"
  expect term-m4 "keep young" "the age guard applies to every home-root session"
  pass "fm-terminal-reap: --min-age keeps sessions that may still be launching"
}

test_apply_closes_only_reproven_orphans() {
  local closed want
  build_world apply
  run_reap --apply --no-browsers
  [ "$RC" = 0 ] || fail "an apply whose closes all succeed or skip must exit 0, got $RC: $(cat "$FX/stderr")"
  closed=$(sort "$FX/closed.log" | tr '\n' ' ')
  want='term-handoff term-idle term-m4 term-mfch term-sm-idle term-stamp '
  [ "$closed" = "$want" ] || fail "--apply must close exactly the orphans; want '$want', got '$closed'"
  expect term-idle "closed idle-session" "an apply reports each close"
  expect term-landed "keep unowned-task" "an apply never closes a terminal in an unrecorded task worktree"
  expect term-gone "keep unowned-task" "an apply never closes a terminal in an unrecorded, gone task worktree"
  expect term-path "keep captain" "an apply never closes a home-root tab whose title only holds a path"
  if [ -n "$STANDIN" ]; then
    expect term-flip "skipped idle-session:now-alive" "a session that gained an agent since the listing must be skipped"
  else
    pass "SKIP: apply re-proof case (no agent stand-in survives here)"
  fi
  assert_contains "$OUT" "summary: mode=apply" "an apply must end with its summary line"
  pass "fm-terminal-reap: --apply closes only orphans it re-proves just before closing"
}

# Each terminal here is a reap candidate when listed, and a hook on Orca's
# fresh read changes one fact before the close.
test_apply_reproves_facts_that_change_before_the_close() {
  local closed
  fixture_reset late
  HOME_DIR="$FX/home"
  mkdir -p "$HOME_DIR/state"

  idle_term term-replaced pty-replaced "$HOME_DIR" "fm main successor"
  idle_shell; session pty-replaced-now "$PID"
  show term-replaced pty-replaced-now "$HOME_DIR"

  idle_term term-late-ok pty-late-ok "$HOME_DIR" "fm main ok"
  show term-late-ok pty-late-ok "$HOME_DIR"

  # The captain renames a home tab while the apply works through others.
  idle_term term-retitle pty-retitle "$HOME_DIR" "fm main retitle"
  show term-retitle pty-retitle "$HOME_DIR"
  printf '#!/usr/bin/env bash\nsed "s/fm main retitle/notes/" %q > %q.new && mv %q.new %q\n' \
    "$FX/list.json" "$FX/list.json" "$FX/list.json" "$FX/list.json" > "$FX/onshow-term-retitle"

  if [ -n "$STANDIN" ]; then
    # An agent that starts inside the classified session itself, after the
    # first liveness read: the session shell runs it once a trigger appears,
    # and the hook fires it on the second fresh read, the pid check.
    local fifo trigger
    fifo=$(mktemp -u "$TMP_ROOT/fifo.XXXXXX"); mkfifo "$fifo"
    trigger="$FX/start-agent"
    bash -c 'while :; do if [ -e "$2" ]; then "$1" 600; exit 0; fi; read -r -t 1 _ <> "$3"; done' \
      _ "$TMP_ROOT/agent-bin/claude" "$trigger" "$fifo" >/dev/null 2>&1 </dev/null &
    PID=$!
    disown "$PID" 2>/dev/null || true
    TRACKED_PIDS+=("$PID")
    term term-late-agent pty-late-agent "$HOME_DIR" "fm main late agent"
    session pty-late-agent "$PID"
    show term-late-agent pty-late-agent "$HOME_DIR"
    cat > "$FX/onshow-term-late-agent" <<HOOK
#!/usr/bin/env bash
n=\$(( \$(cat '$FX/shows-late-agent' 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > '$FX/shows-late-agent'
[ "\$n" -eq 2 ] || exit 0
: > '$trigger'
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  pgrep -P $PID >/dev/null 2>&1 && exit 0
  sleep 0.2
done
HOOK
  fi
  # The listed session exits, so the liveness read says missing, and a new
  # session takes over the same terminal before the close.
  local exited
  term term-missing pty-missing "$HOME_DIR" "fm main missing"
  orphan_idle_shell; exited=$PID; session pty-missing "$exited"
  idle_shell; session pty-missing-now "$PID"
  show term-missing pty-missing-now "$HOME_DIR"
  mv "$FX/show-term-missing.json" "$FX/show-term-missing.next"
  show term-missing pty-missing "$HOME_DIR"
  cat > "$FX/onshow-term-missing" <<HOOK
#!/usr/bin/env bash
n=\$(( \$(cat '$FX/shows-missing' 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > '$FX/shows-missing'
if [ "\$n" -eq 1 ]; then
  kill -KILL $exited 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ps -p $exited >/dev/null 2>&1 || exit 0
    sleep 0.1
  done
elif [ "\$n" -eq 2 ]; then
  cp '$FX/show-term-missing.next' '$FX/show-term-missing.json'
fi
HOOK

  chmod +x "$FX"/onshow-*
  fixture_write

  run_reap --no-browsers
  expect term-replaced "reap idle-session" "the listed session is an idle firstmate session"
  expect term-missing "reap idle-session" "the listed session is an idle firstmate session"
  expect term-late-ok "reap idle-session" "the listed session is an idle firstmate session"

  run_reap --apply --no-browsers
  [ "$RC" = 0 ] || fail "an apply whose closes all succeed or skip must exit 0, got $RC: $(cat "$FX/stderr")"
  expect term-replaced "skipped idle-session:now-replaced" "a terminal whose session was replaced since the listing must be skipped"
  expect term-missing "skipped idle-session:now-replaced" "a terminal whose session exited and was replaced since the listing must be skipped"
  expect term-late-ok "closed idle-session" "an unchanged idle firstmate session is still closed"
  expect term-retitle "skipped idle-session:now-retitled" "a home tab renamed off a firstmate title since the listing is the captain's"
  if [ -n "$STANDIN" ]; then
    expect term-late-agent "skipped idle-session:now-alive" "an agent started in the classified session during the checks must keep its terminal"
  else
    pass "SKIP: late agent case (no agent stand-in survives here)"
  fi
  closed=$(sort "$FX/closed.log" | tr '\n' ' ')
  [ "$closed" = 'term-late-ok ' ] || fail "only the unchanged orphan may close, got '$closed'"
  pass "fm-terminal-reap: --apply re-proves the session and title just before each close"
}

# Unreadable is never absent: a record that cannot be read still owns its
# terminal.
test_unreadable_owner_facts_keep_terminals() {
  if [ "$(id -u)" = 0 ]; then
    pass "SKIP: permission cases (root reads through every mode)"
    return 0
  fi
  local closed
  fixture_reset unreadable
  HOME_DIR="$FX/home"
  mkdir -p "$HOME_DIR/state"
  idle_term term-first pty-first "$HOME_DIR" "fm main successor"
  show term-first pty-first "$HOME_DIR"
  idle_term term-second pty-second "$HOME_DIR" "fm main handoff"
  show term-second pty-second "$HOME_DIR"
  fm_write_meta "$HOME_DIR/state/other.meta" kind=ship backend=orca terminal=term-other "worktree=$FX/other-wt"
  printf '#!/usr/bin/env bash\nchmod 000 %q\n' "$HOME_DIR/state/other.meta" > "$FX/onshow-term-first"
  chmod +x "$FX/onshow-term-first"
  fixture_write

  run_reap --apply --no-browsers
  [ "$RC" = 0 ] || fail "an apply whose closes all succeed or skip must exit 0, got $RC: $(cat "$FX/stderr")"
  expect term-first "closed idle-session" "a terminal re-proved before its records turn unreadable still closes"
  expect term-second "skipped idle-session:now-unreadable-records" "a close whose fresh record read fails must be skipped"
  closed=$(tr '\n' ' ' < "$FX/closed.log")
  [ "$closed" = 'term-first ' ] || fail "only the re-proved terminal may close, got '$closed'"

  : > "$FX/closed.log"
  run_reap --apply --no-browsers
  [ "$RC" = 1 ] || fail "an unreadable task record must fail the inventory with exit 1, got $RC"
  [ ! -s "$FX/closed.log" ] || fail "an unreadable task record must close nothing, closed: $(cat "$FX/closed.log")"
  chmod 644 "$HOME_DIR/state/other.meta"
  pass "fm-terminal-reap: unreadable records keep their terminals"
}

test_unreadable_inventory_closes_nothing() {
  build_world broken
  printf 'not json\n' > "$FX/list.json"
  run_reap --apply
  [ "$RC" = 1 ] || fail "an unreadable terminal list must exit 1, got $RC"
  [ ! -s "$FX/closed.log" ] || fail "an unreadable inventory must close nothing"
  pass "fm-terminal-reap: an unreadable inventory exits 1 and closes nothing"
}

# await_exec: wait until a just-started process has replaced this suite's
# forked copy with its own command line, so a heavily loaded host never
# snapshots a starter mid-exec.
await_exec() {  # <pid>
  local mine i
  mine=$(ps -o args= -p "$$" 2>/dev/null) || return 0
  for i in $(seq 1 100); do
    [ "$(ps -o args= -p "$1" 2>/dev/null)" != "$mine" ] && return 0
    sleep 0.1
  done
  fail "process $1 never left this suite's command line"
}

# fake_script: a real process whose command line is node <script> [args...],
# where the script holds one child.
fake_script() {  # <script> [args...] -> PID
  mkdir -p "${1%/*}"
  printf 'sleep 600 & wait\n' > "$1"
  ( exec -a node bash "$@" ) >/dev/null 2>&1 </dev/null &
  PID=$!
  disown "$PID" 2>/dev/null || true
  TRACKED_PIDS+=("$PID")
  await_exec "$PID"
}
# fake_browser: an agent-browser daemon as node runs it.
fake_browser() {  # -> PID
  fake_script "$TMP_ROOT/lib/node_modules/agent-browser/bin/../dist/daemon.js"
}

# fake_headless: a real process whose command line starts with <exe> and
# ends with --headless, with one child.
fake_headless() {  # <exe> -> PID
  ( exec -a "$1" bash -c 'sleep 600 & wait' "$1" --headless ) >/dev/null 2>&1 </dev/null &
  PID=$!
  disown "$PID" 2>/dev/null || true
  TRACKED_PIDS+=("$PID")
  await_exec "$PID"
}
# headless_program: a non-browser program given a browser path and --headless
# as its arguments, with one child.
headless_program() {  # <browser path> -> PID
  bash -c 'sleep 600 & wait' worker "$1" --headless >/dev/null 2>&1 </dev/null &
  PID=$!
  disown "$PID" 2>/dev/null || true
  TRACKED_PIDS+=("$PID")
  await_exec "$PID"
}

test_browsers_are_reaped_only_without_a_live_owner() {
  local gone live task owner reused headless other bridge cfgarg daemonarg
  fixture_reset browsers
  HOME_DIR="$FX/home"
  mkdir -p "$HOME_DIR/state" "$FX/live-dir" "$FX/task-wt"
  fm_write_meta "$HOME_DIR/state/t.meta" kind=ship backend=orca terminal=term-x "worktree=$FX/task-wt"
  fixture_write
  fake_browser; gone=$PID
  fake_browser; live=$PID
  fake_browser; task=$PID
  fake_browser; reused=$PID
  idle_shell; owner=$PID
  # Orphaned --headless processes: a browser executable is a browser root, and
  # another program is not a browser at all, even when a browser path is one of
  # its arguments.
  fake_headless "$TMP_ROOT/browser-bin/chrome-headless-shell"; headless=$PID
  headless_program "$TMP_ROOT/browser-bin/chrome"; other=$PID
  : > "$FX/ppid1-$headless"; : > "$FX/ppid1-$other"
  # A chrome-devtools-axi bridge is a root, and node scripts given a bridge or
  # daemon path as an argument are not.
  fake_script "$TMP_ROOT/lib/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js"; bridge=$PID
  fake_script "$TMP_ROOT/jobs/worker.js" --config "$TMP_ROOT/jobs/chrome-devtools-axi-bridge.json"; cfgarg=$PID
  fake_script "$TMP_ROOT/jobs/runner.js" "$TMP_ROOT/lib/node_modules/agent-browser/dist/daemon.js"; daemonarg=$PID
  cwd_row "$bridge" "$FX/bridge-dir"
  cwd_row "$cfgarg" "$FX/cfgarg-dir"
  cwd_row "$daemonarg" "$FX/daemonarg-dir"
  cwd_row "$headless" "$FX/headless-dir"
  cwd_row "$other" "$FX/other-dir"
  cwd_row "$gone" "$FX/gone-dir"
  cwd_row "$reused" "$FX/reused-dir"
  cwd_row "$live" "$FX/live-dir"
  cwd_row "$owner" "$FX/live-dir/sub"
  cwd_row "$task" "$FX/task-wt"
  # Identities are recorded only for processes that started before the
  # snapshot's second, so let these age past it.
  sleep 1.2
  run_reap
  [ "$RC" = 0 ] || fail "the browser dry run must exit 0, got $RC: $(cat "$FX/stderr")"
  expect "$gone" "reap owner-gone" "a browser whose working directory is gone has no owner"
  expect "$live" "keep owner-live" "a browser another process still works beside has an owner"
  expect "$task" "keep task" "a browser in a recorded task worktree belongs to that task"
  expect "$headless" "reap owner-gone" "an orphaned headless browser executable is a browser root"
  expect "$other" "" "an orphaned --headless program that is no browser executable must never be listed as a browser"
  expect "$bridge" "reap owner-gone" "a chrome-devtools-axi bridge node runs is a browser root"
  expect "$cfgarg" "" "a node script given a bridge path as an argument must never be listed as a browser"
  expect "$daemonarg" "" "a node script given a daemon path as an argument must never be listed as a browser"
  kill -0 "$gone" 2>/dev/null || fail "a dry run must stop no browser"

  run_reap --apply
  [ "$RC" = 0 ] || fail "a terminals-only apply must exit 0, got $RC: $(cat "$FX/stderr")"
  expect "$gone" "reap owner-gone" "--apply without --browsers only lists a browser verdict"
  sleep 0.3
  kill -0 "$gone" 2>/dev/null || fail "--apply without --browsers must stop no browser"

  : > "$FX/fresh-$reused"
  run_reap --apply --browsers
  [ "$RC" = 0 ] || fail "the browser apply must exit 0, got $RC: $(cat "$FX/stderr")"
  expect "$gone" "stopped owner-gone" "an apply stops an ownerless browser"
  expect "$reused" "skipped owner-gone:gone" "a root that reads as started after the snapshot may be a reused pid and is never signalled"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$gone" 2>/dev/null || break; sleep 0.2; done
  ! kill -0 "$gone" 2>/dev/null || fail "an apply must stop the ownerless browser's root"
  kill -0 "$live" 2>/dev/null || fail "an apply must leave a browser with a live owner running"
  kill -0 "$task" 2>/dev/null || fail "an apply must leave a task's browser running"
  kill -0 "$reused" 2>/dev/null || fail "an apply must never signal a possibly reused pid"
  kill -0 "$other" 2>/dev/null || fail "an apply must never signal a --headless program that is no browser"
  kill -0 "$cfgarg" 2>/dev/null || fail "an apply must never signal a program given a bridge path"
  kill -0 "$daemonarg" 2>/dev/null || fail "an apply must never signal a program given a daemon path"
  pass "fm-terminal-reap: browsers are stopped only when nothing else works in their directory"
}

fm_test_run \
  test_dry_run_classifies_every_owner_and_closes_nothing \
  test_min_age_keeps_young_sessions \
  test_apply_closes_only_reproven_orphans \
  test_apply_reproves_facts_that_change_before_the_close \
  test_unreadable_owner_facts_keep_terminals \
  test_unreadable_inventory_closes_nothing \
  test_browsers_are_reaped_only_without_a_live_owner
