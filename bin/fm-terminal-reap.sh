#!/usr/bin/env bash
# fm-terminal-reap.sh - list this host's Orca terminals and headless browsers,
# classify each by owner, and close only the orphans.
#
# Usage:
#   fm-terminal-reap.sh [--apply] [--browsers] [--min-age <seconds>] [--no-browsers]
#
#   (default)        dry run: print every verdict and change nothing
#   --apply          close every terminal whose verdict is reap, re-proving
#                    each one just before acting on it; browsers are only
#                    listed unless --browsers is also given
#   --browsers       with --apply, also stop every browser whose verdict is
#                    reap; agent-browser daemons and chrome-devtools-axi
#                    bridges are shared by every client of their socket, so a
#                    browser judged owner-gone may still serve another live
#                    worker (no socket probe is made)
#   --min-age <s>    never reap a terminal session or browser younger than this
#                    many seconds (default 1800), so a session that is still
#                    launching its agent is never mistaken for an idle one
#   --no-browsers    classify terminals only
#
# Output: one tab-separated line per terminal or browser root,
#   <action> <kind> <class> <id> <path> <detail>
# where action is reap or keep on a dry run, and closed, stopped, skipped, or
# failed on --apply; kind is terminal or browser; id is the Orca terminal handle
# or the browser's root pid; detail is the owning task, the terminal title, or
# the browser's command. A final `summary:` line counts each action.
#
# Exit status: 0 when the inventory was read (and, with --apply, every reap
# succeeded or was safely skipped); 1 when an inventory read failed, including
# an unreadable task record or secondmate registry, in which case nothing is
# closed; 2 on a usage error; 3 when --apply hit a failure.
#
# Owners. The script reads this home's state/*.meta records and, through each
# home's data/secondmates.md, every local secondmate home's records, read-only.
# A record's terminal= handle and worktree= path mark a recorded task. Remote
# secondmate homes are not read; their terminals run on another host.
#
# Terminal verdicts, first match wins (every keep is final):
#   keep remote        the terminal runs on another execution host
#   keep task          its handle is a recorded task or secondmate endpoint
#   keep task-worktree it runs in a recorded task's worktree; that task's own
#                      cleanup owns it, whether or not its work has landed
#   keep unowned-task  it runs in a firstmate task worktree (a directory whose
#                      name starts with fm-, the spawn's own naming), present or
#                      gone, that no task record of this home or its local
#                      secondmates names; another home on this host may own it,
#                      so this home never closes it
#   keep foreign       it runs outside every home root and outside every
#                      firstmate task worktree, so it belongs to the captain or
#                      another tool and is never firstmate's to close
#   keep no-session    Orca's process sweep names no session for it
#   keep young         its session is younger than --min-age
#   keep self          this script runs inside it
#   keep live-agent    a verified agent harness runs in its session
#   keep busy          its session runs a program this classifier cannot rule
#                      out as an agent
#   keep unreadable    its session's process tree could not be read
#   keep captain       an idle shell in a home root whose title does not name
#                      a firstmate main or handoff session (see idle-session),
#                      including an empty or Orca default "Terminal <n>" title,
#                      so this is the captain's own tab
#   reap idle-session  an idle shell in a home root whose title names a
#                      finished primary or secondmate session left at its
#                      prompt: after dropping path and branch parts (any word
#                      holding /, ~ or @, any word ending in :, and any
#                      parenthesized or bracketed segment, nested ones
#                      included), some remaining word, split on
#                      non-alphanumerics and in any case, is main, successor,
#                      handoff, firstmate, or fm; a title whose brackets do
#                      not balance is always the captain's
# "Idle" means the session's process tree holds shells and nothing else
# (fm_backend_orca_tree_state's dead verdict). This home reaps only idle
# firstmate sessions in its own roots; every terminal in a task worktree,
# recorded or not, is kept.
#
# Browser roots are agent-browser daemons, chrome-devtools-axi bridges, and
# automation browsers whose parent has exited: a browser executable (Chrome,
# Chromium, Edge, Firefox, or a headless shell), named by the command line's
# first word, started with --headless or --remote-debugging-pipe or from a
# Playwright or Puppeteer build. Another program is never listed, even when a
# browser path or --headless is among its arguments. Each root is
# judged by its working directory, together with every process under it:
#   keep task          it works in a recorded task's worktree
#   keep home          it works in a home root
#   keep young         it is younger than --min-age
#   keep unknown       its working directory could not be read or looked up
#   keep owner-live    some other process still works in that directory
#   reap owner-gone    its directory is gone, or nothing but browsers (and
#                      terminals this run reaps) still works there
# Agent-browser daemons and chrome-devtools-axi bridges serve every client of
# their socket, so owner-gone judges only the directory, not other clients; for
# that reason only --apply --browsers stops browsers.
# --apply --browsers stops a browser with SIGTERM to its root and descendants, only after
# re-reading that every process still has the start time and command recorded
# when it was classified. A process is recorded only when it provably started
# before the process-table snapshot it was classified from, so a pid reused
# after that snapshot is never signalled. It never sends SIGKILL.
#
# --apply re-proves each terminal immediately before closing it. The records
# are re-read (an unreadable record skips the close),
# fm_backend_orca_agent_state must still report dead or missing, and the fresh
# title must still name a firstmate session. A terminal Orca still reports
# connected must still be rooted at the session pid it was classified with,
# whichever of those two states was read (a replaced session is skipped), and
# the last read before the close requires
# that session, if it still runs, to hold shells and nothing else. Any change or
# unreadable fact skips the close.
# Environment: FM_HOME selects the home; FM_ROOT_OVERRIDE as elsewhere.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/backends/orca.sh
. "$SCRIPT_DIR/backends/orca.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

# usage: the header from its first line through the exit-status paragraph.
usage() { sed -n '2,/^# closed; 2 on a usage error/p' "$0" | sed 's/^# \{0,1\}//'; }

APPLY=0
MIN_AGE=1800
BROWSERS=1
STOP_BROWSERS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --min-age)
      [ "$#" -ge 2 ] || { echo "error: --min-age needs a value" >&2; exit 2; }
      MIN_AGE=$2; shift
      ;;
    --no-browsers) BROWSERS=0 ;;
    --browsers) STOP_BROWSERS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$MIN_AGE" in ''|*[!0-9]*) echo "error: --min-age must be whole seconds" >&2; exit 2 ;; esac

command -v node >/dev/null 2>&1 || { echo "error: node is required" >&2; exit 1; }
fm_backend_orca_tool_check || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-terminal-reap.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

phys() {  # <path> -> the physical path when it exists, else the path itself
  local p=$1 r
  if [ -d "$p" ] && r=$(cd -P -- "$p" 2>/dev/null && pwd -P); then
    printf '%s' "$r"
  else
    printf '%s' "$p"
  fi
}

# collect_owners: every home root and recorded task, as `home<TAB>path` and
# `rec<TAB>home<TAB>id<TAB>terminal<TAB>worktree` lines on stdout.
collect_owners() {
  local queue=() seen=' ' home meta id terminal worktree line reg
  queue+=("$(phys "$FM_HOME")")
  while [ "${#queue[@]}" -gt 0 ]; do
    home=${queue[0]}
    queue=("${queue[@]:1}")
    case "$seen" in *" $home "*) continue ;; esac
    seen="$seen$home "
    printf 'home\t%s\n' "$home"
    # A record that cannot be read is an owner this run cannot see, so the
    # whole read fails rather than treating it as absent.
    if [ -e "$home/state" ] && { [ ! -r "$home/state" ] || [ ! -x "$home/state" ]; }; then return 1; fi
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      [ -r "$meta" ] || return 1
      id=${meta##*/}; id=${id%.meta}
      terminal=$(fm_meta_get "$meta" terminal)
      worktree=$(fm_meta_get "$meta" worktree)
      [ -z "$worktree" ] || worktree=$(phys "$worktree")
      printf 'rec\t%s\t%s\t%s\t%s\n' "$home" "$id" "$terminal" "$worktree"
    done
    reg="$home/data/secondmates.md"
    [ -e "$reg" ] || continue
    [ -f "$reg" ] && [ -r "$reg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
      case "$SECONDMATE_REGISTRY_HOME" in
        \~/*) SECONDMATE_REGISTRY_HOME="$HOME/${SECONDMATE_REGISTRY_HOME#\~/}" ;;
      esac
      [ -d "$SECONDMATE_REGISTRY_HOME" ] || continue
      queue+=("$(phys "$SECONDMATE_REGISTRY_HOME")")
    done < "$reg"
  done
}

read_inventory() {
  collect_owners > "$WORK/owners.tsv" || {
    echo "error: a task record or secondmate registry could not be read; nothing was closed" >&2; return 1; }
  orca terminal list --json > "$WORK/terminals.json" 2>/dev/null || {
    echo "error: orca terminal list failed; nothing was closed" >&2; return 1; }
  orca diagnostics memory --json > "$WORK/memory.json" 2>/dev/null || {
    echo "error: orca diagnostics memory failed; nothing was closed" >&2; return 1; }
  SNAP_EPOCH=$(date +%s)
  LC_ALL=C ps -axo pid=,ppid=,etime=,args= > "$WORK/ps.txt" 2>/dev/null || {
    echo "error: the process table could not be read; nothing was closed" >&2; return 1; }
  if fm_backend_orca_cwd_scan > "$WORK/cwd.txt"; then
    CWD_SCAN_OK=1
  else
    CWD_SCAN_OK=0
    : > "$WORK/cwd.txt"
  fi
}

# classify_node <mode>: the JSON and table joins, in one place. Mode terminals
# prints `handle prelim pid path title`; prelim is a final keep class or
# `candidate`, and every candidate is in a home root. Mode browsers prints `pid verdict class cwd descendants detail`.
classify_node() {
  node - "$1" "$WORK" "$MIN_AGE" "$CWD_SCAN_OK" <<'JS'
const fs = require("fs");
const [mode, work, minAgeRaw, scanOk] = process.argv.slice(2);
const minAge = Number(minAgeRaw);
const read = (f) => fs.readFileSync(`${work}/${f}`, "utf8");
const clean = (s) => String(s == null ? "" : s).replace(/[\t\r\n]+/g, " ").trim();
const real = (p) => { try { return fs.realpathSync(p); } catch (_) { return p; } };
// Only a missing path is gone; a lookup that fails any other way is unknown.
const presence = (p) => {
  try { fs.statSync(p); return "present"; }
  catch (err) { return err && (err.code === "ENOENT" || err.code === "ENOTDIR") ? "gone" : "unknown"; }
};
const under = (p, root) => p === root || p.startsWith(root + "/");
// Bash `read` merges adjacent tabs, so an empty field is written as "-".
const row = (fields) => fields.map((f) => (String(f) === "" ? "-" : String(f))).join("\t") + "\n";

const homes = [], recs = [];
for (const line of read("owners.tsv").split("\n")) {
  const f = line.split("\t");
  if (f[0] === "home") homes.push(f[1]);
  else if (f[0] === "rec") recs.push({ home: f[1], id: f[2], terminal: f[3], worktree: f[4] });
}
const recFor = (pred) => recs.find(pred);

function etimeSecs(s) {
  const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(s || "");
  if (!m) return NaN;
  return (Number(m[1] || 0) * 86400) + (Number(m[2] || 0) * 3600) + (Number(m[3]) * 60) + Number(m[4]);
}
const procs = new Map();
for (const line of read("ps.txt").split("\n")) {
  const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
  if (m) procs.set(Number(m[1]), { pid: Number(m[1]), ppid: Number(m[2]), age: etimeSecs(m[3]), args: m[4] });
}
const kids = new Map();
for (const p of procs.values()) {
  if (!kids.has(p.ppid)) kids.set(p.ppid, []);
  kids.get(p.ppid).push(p.pid);
}
function tree(root) {
  const out = [], q = [root], seen = new Set([root]);
  while (q.length) {
    const p = q.shift();
    out.push(p);
    for (const c of kids.get(p) || []) if (!seen.has(c)) { seen.add(c); q.push(c); }
  }
  return out;
}

if (mode === "terminals") {
  let data, mem;
  try { data = JSON.parse(read("terminals.json")); mem = JSON.parse(read("memory.json")); }
  catch (err) { console.error("error: unreadable Orca JSON: " + err.message); process.exit(1); }
  if (!data || data.ok === false || !data.result || !Array.isArray(data.result.terminals)) {
    console.error("error: orca terminal list returned no terminal list"); process.exit(1);
  }
  if (!mem || mem.ok === false || !mem.result || !Array.isArray(mem.result.worktrees)) {
    console.error("error: orca diagnostics memory returned no process sweep"); process.exit(1);
  }
  if (data.result.truncated) console.error("warning: Orca truncated the terminal list; unlisted terminals are not judged");
  const pidOf = new Map(), dup = new Set();
  for (const wt of mem.result.worktrees) for (const s of (wt && wt.sessions) || []) {
    if (!s || typeof s.sessionId !== "string") continue;
    if (pidOf.has(s.sessionId)) dup.add(s.sessionId);
    pidOf.set(s.sessionId, s.pid);
  }
  for (const t of data.result.terminals) {
    const handle = clean(t.handle), path = clean(t.worktreePath), title = clean(t.title);
    if (!handle) continue;
    const wt = path ? real(path) : "";
    let prelim = "candidate", pid = "", detail = title;
    const emit = () => process.stdout.write(row([handle, prelim, pid, path, detail]));
    let r;
    if ((t.executionHostId || "local") !== "local") { prelim = "remote"; emit(); continue; }
    if ((r = recFor((x) => x.terminal && x.terminal === handle))) {
      prelim = "task"; detail = `${r.id} (${r.home})`; emit(); continue;
    }
    if (wt && (r = recFor((x) => x.worktree && x.worktree === wt))) {
      prelim = "task-worktree"; detail = `${r.id} (${r.home}); ${title}`; emit(); continue;
    }
    if (wt && /^fm-/.test(wt.split("/").pop())) { prelim = "unowned-task"; emit(); continue; }
    if (!(wt && homes.includes(wt))) { prelim = "foreign"; emit(); continue; }
    const sp = pidOf.get(clean(t.ptyId));
    if (!Number.isInteger(sp) || sp <= 1 || dup.has(clean(t.ptyId))) { prelim = "no-session"; emit(); continue; }
    pid = String(sp);
    const p = procs.get(sp);
    if (!p) { prelim = "no-session"; emit(); continue; }
    if (!(p.age >= minAge)) { prelim = "young"; emit(); continue; }
    emit();
  }
} else if (mode === "browsers") {
  const browserExe = /^((\/([^/ ]+|[^/]*\.app))*\/)?(Google Chrome( for Testing)?|Chromium|chrome|chromium|chromium-browser|chrome-headless-shell|headless_shell|msedge|Microsoft Edge|firefox)( |$)/;
  const isRoot = (p) => {
    const a = p.args;
    if (/\/agent-browser\//.test(a) && /daemon\.js/.test(a)) return true;
    if (/chrome-devtools-axi-bridge/.test(a)) return true;
    if (p.ppid !== 1) return false;
    // An automation browser is a browser executable, named by the command
    // line's first word (a path whose only spaced parts are .app bundles and
    // the executable's own name), run headless, pipe-debugged, or from a
    // Playwright or Puppeteer build. A browser path passed as an argument to
    // another program never counts.
    return browserExe.test(a)
      && /((^| )(--headless(=\S*)?|--remote-debugging-pipe)( |$)|\/ms-playwright\/|puppeteer_dev_chrome_profile|playwright_chromiumdev_profile)/.test(a);
  };
  const matched = new Set([...procs.values()].filter(isRoot).map((p) => p.pid));
  const roots = [...matched].filter((pid) => {
    for (let p = procs.get(pid), hops = 0; p && p.ppid > 1 && hops < 512; hops++) {
      if (matched.has(p.ppid)) return false;
      p = procs.get(p.ppid);
    }
    return true;
  });
  const family = new Set();
  const trees = new Map();
  for (const r of roots) { const t = tree(r); trees.set(r, t); for (const x of t) family.add(x); }
  const exclude = new Set(read("exclude.txt").split("\n").filter(Boolean).map(Number));
  const cwd = new Map();
  let cur = null;
  for (const line of read("cwd.txt").split("\n")) {
    if (line[0] === "p") cur = Number(line.slice(1));
    else if (line[0] === "n" && cur !== null) cwd.set(cur, line.slice(1));
  }
  for (const r of roots.sort((a, b) => a - b)) {
    const p = procs.get(r), dir = cwd.get(r) || "";
    let verdict = "keep", cls;
    const rec = dir && recFor((x) => x.worktree && under(dir, x.worktree));
    if (scanOk !== "1" || !dir) cls = "unknown";
    else if (rec) cls = "task";
    else if (homes.some((h) => under(dir, h))) cls = "home";
    else if (!(p.age >= minAge)) cls = "young";
    else if (presence(dir) === "unknown") cls = "unknown";
    else if (presence(dir) === "gone") { verdict = "reap"; cls = "owner-gone"; }
    else {
      let live = false;
      for (const [pid, d] of cwd) {
        if (family.has(pid) || exclude.has(pid)) continue;
        if (under(d, dir)) { live = true; break; }
      }
      if (live) cls = "owner-live"; else { verdict = "reap"; cls = "owner-gone"; }
    }
    const detail = (rec ? `${rec.id}: ` : "") + clean(p.args).slice(0, 160);
    process.stdout.write(row([r, verdict, cls, dir, trees.get(r).join(","), detail]));
  }
}
JS
}

# firstmate_title <title>: 0 when a title word, outside its path and branch
# parts, is main, successor, handoff, firstmate, or fm. Parenthesized and
# bracketed segments are removed innermost first, so nesting is handled; a
# title whose brackets do not balance is never a firstmate title.
firstmate_title() {
  printf '%s\n' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | sed -e ':a' -e 's/([^][()]*)/ /g' -e 's/\[[^][()]*\]/ /g' -e 'ta' \
    | LC_ALL=C awk '
      /[][()]/ { exit 1 }
      { for (i = 1; i <= NF; i++) {
          if ($i ~ /[\/~@]/ || $i ~ /:$/) continue
          n = split($i, w, /[^a-z0-9]+/)
          for (j = 1; j <= n; j++) if (w[j] ~ /^(main|successor|handoff|firstmate|fm)$/) found = 1
      } }
      END { exit found ? 0 : 1 }'
}

# judge_terminal <pid> <title> -> `<action> <class>` for a home-root candidate
# and, for a reap, the session's pids on fd 3 so browsers can discount them.
judge_terminal() {
  local pid=$1 title=$2 state tree
  tree=$(fm_backend_orca_process_tree "$pid") || { printf 'keep\tunreadable'; return 0; }
  if printf '%s\n' "$tree" | cut -f1 | grep -qx "$$"; then printf 'keep\tself'; return 0; fi
  state=$(fm_backend_orca_tree_state "$pid")
  case "$state" in
    alive) printf 'keep\tlive-agent'; return 0 ;;
    ambiguous) printf 'keep\tbusy'; return 0 ;;
    dead) ;;
    *) printf 'keep\tunreadable'; return 0 ;;
  esac
  firstmate_title "$title" || { printf 'keep\tcaptain'; return 0; }
  printf 'reap\tidle-session'
  printf '%s\n' "$tree" | cut -f1 >&3
}

# recorded_now <handle> <path>: 0 when a fresh read of the records claims this
# terminal or its worktree, 1 when it does not, 2 when the records are unreadable.
recorded_now() {
  local handle=$1 wt owners
  wt=$(phys "$2")
  owners=$(collect_owners) || return 2
  printf '%s\n' "$owners" | awk -F'\t' -v h="$handle" -v w="$wt" '
    $1 == "rec" && (($4 != "" && $4 == h) || ($5 != "" && $5 == w)) { found = 1 }
    END { exit found ? 0 : 1 }'
}

# current_title <handle>: the terminal's title from a fresh Orca listing; exit 1
# when the listing is unreadable or no longer holds the terminal.
current_title() {  # <handle>
  orca terminal list --json 2>/dev/null | node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (_) { process.exit(1); }
const ts = d && d.ok !== false && d.result && Array.isArray(d.result.terminals) ? d.result.terminals : null;
if (!ts) process.exit(1);
const t = ts.find((x) => x && x.handle === process.argv[1]);
if (!t) process.exit(1);
process.stdout.write(typeof t.title === "string" ? t.title.replace(/[\t\r\n]+/g, " ") : "");' "$1"
}

close_terminal() {  # <handle> <path> <pid> -> closed|skipped:<why>|failed:<why>
  local handle=$1 path=$2 pid=$3 state out facts pty now title
  local rec=0
  recorded_now "$handle" "$path" || rec=$?
  case "$rec" in
    0) printf 'skipped\tnow-recorded'; return 0 ;;
    1) ;;
    *) printf 'skipped\tnow-unreadable-records'; return 0 ;;
  esac
  state=$(fm_backend_orca_agent_state "$handle")
  case "$state" in
    dead|missing) ;;
    *) printf 'skipped\tnow-%s' "$state"; return 0 ;;
  esac
  # A home-root tab is the captain's unless its title still names a firstmate
  # session; it may have been renamed since the listing.
  title=$(current_title "$handle") || { printf 'skipped\tnow-unreadable'; return 0; }
  firstmate_title "$title" || { printf 'skipped\tnow-retitled'; return 0; }
  # A connected terminal must still be rooted at the classified session pid,
  # whether the liveness read said dead or missing: a session that exited may
  # have been replaced by a new one under the same handle.
  local fread connected
  facts=$(fm_backend_orca_terminal_facts "$handle") || { printf 'skipped\tnow-unreadable'; return 0; }
  IFS=$'\x1f' read -r fread connected _ _ pty _ _ <<FACTS
$facts
FACTS
  [ "$fread" = ok ] || { printf 'skipped\tnow-unreadable'; return 0; }
  case "$connected" in
    false) ;;
    true)
      now=$(fm_backend_orca_session_pid "$pty") || { printf 'skipped\tnow-unreadable'; return 0; }
      [ "$now" = "$pid" ] || { printf 'skipped\tnow-replaced'; return 0; }
      ;;
    *) printf 'skipped\tnow-unreadable'; return 0 ;;
  esac
  # The last read before the close: the classified session, if it still runs,
  # must still hold shells and nothing else. An agent started under the same
  # session pid during the checks above is caught here.
  local absent=0
  fm_backend_orca_pid_absent "$pid" || absent=$?
  case "$absent" in
    0) ;;
    1)
      state=$(fm_backend_orca_tree_state "$pid")
      [ "$state" = dead ] || { printf 'skipped\tnow-%s' "$state"; return 0; }
      ;;
    *) printf 'skipped\tnow-unreadable'; return 0 ;;
  esac
  out=$(orca terminal close --terminal "$handle" --json 2>/dev/null) || true
  if printf '%s' "$out" | node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch (_) { process.exit(1); }
process.exit(d && d.ok === true ? 0 : 1);'; then
    printf 'closed\t-'
  else
    printf 'failed\torca-close'
  fi
}

proc_identity() {  # <pid> -> start time and command, or nothing when gone
  LC_ALL=C ps -p "$1" -o lstart=,args= 2>/dev/null
}

etime_secs() {  # <[[dd-]hh:]mm:ss> -> seconds, or nothing when malformed
  local e=$1 d=0 h=0 m s rest
  case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
  case "$e" in
    *:*:*) h=${e%%:*}; rest=${e#*:}; m=${rest%%:*}; s=${rest#*:} ;;
    *:*) m=${e%%:*}; s=${e#*:} ;;
    *) return 0 ;;
  esac
  case "$d$h$m$s" in *[!0-9]*|'') return 0 ;; esac
  printf '%d' $((10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s))
}

# snapshot_identity <pid>: the pid's identity, printed only when the process
# provably started before SNAP_EPOCH, the time taken just before the process
# table it was classified from. A process that started in or after the
# snapshot's second may be a reused pid and prints nothing.
snapshot_identity() {  # <pid>
  local first second et age
  first=$(proc_identity "$1")
  [ -n "$first" ] || return 0
  et=$(LC_ALL=C ps -p "$1" -o etime= 2>/dev/null | tr -d ' ')
  second=$(proc_identity "$1")
  [ "$first" = "$second" ] || return 0
  age=$(etime_secs "$et")
  [ -n "$age" ] || return 0
  [ $(( $(date +%s) - age )) -lt "$SNAP_EPOCH" ] || return 0
  printf '%s' "$first"
}

stop_browser() {  # <root-pid> <identity-file> -> stopped|skipped:<why>|failed:<why>
  local root=$1 file=$2 pid want have sent=0 first
  IFS=$'\t' read -r first _ < "$file" 2>/dev/null || first=
  [ "$first" = "$root" ] || { printf 'skipped\tgone'; return 0; }
  while IFS=$'\t' read -r pid want; do
    have=$(proc_identity "$pid")
    if [ "$have" != "$want" ]; then
      [ "$sent" -gt 0 ] && continue
      printf 'skipped\tchanged'; return 0
    fi
    kill -TERM "$pid" 2>/dev/null && sent=$((sent + 1))
  done < "$file"
  if [ "$sent" -gt 0 ]; then printf 'stopped\t-'; else printf 'failed\tsignal'; fi
}

CWD_SCAN_OK=0
read_inventory || exit 1

: > "$WORK/exclude.txt"
classify_node terminals > "$WORK/terminals.tsv" || exit 1

declare -i N_REAP=0 N_KEEP=0 N_DONE=0 N_SKIP=0 N_FAIL=0 B_REAP=0 B_KEEP=0 B_DONE=0 B_SKIP=0 B_FAIL=0 N_TOTAL=0 B_TOTAL=0 INV_FAIL=0
: > "$WORK/terminal-verdicts.tsv"
while IFS=$'\t' read -r handle prelim pid path detail; do
  [ -n "$handle" ] || continue
  if [ "$prelim" = candidate ]; then
    verdict=$(judge_terminal "$pid" "$detail" 3>>"$WORK/exclude.txt")
  else
    verdict=$'keep\t'"$prelim"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$verdict" "$handle" "${pid:--}" "$path" "$detail" >> "$WORK/terminal-verdicts.tsv"
done < "$WORK/terminals.tsv"

# classify_browsers: judge browser roots against the current tables and record
# the identity of each reap root's processes that started before that table.
classify_browsers() {
  local bpid bverdict bdesc p id
  if [ "$BROWSERS" = 1 ]; then
    classify_node browsers > "$WORK/browsers.tsv" || return 1
  else
    : > "$WORK/browsers.tsv"
  fi
  while IFS=$'\t' read -r bpid bverdict _ _ bdesc _; do
    [ "$bverdict" = reap ] || continue
    : > "$WORK/browser-$bpid.id"
    for p in ${bdesc//,/ }; do
      id=$(snapshot_identity "$p")
      [ -n "$id" ] && printf '%s\t%s\n' "$p" "$id" >> "$WORK/browser-$bpid.id"
    done
  done < "$WORK/browsers.tsv"
}

# A dry run judges browsers now, discounting the sessions it would reap. An
# apply judges them after closing terminals, from fresh tables, so a terminal it
# skipped still counts as a live owner.
if [ "$APPLY" = 0 ]; then
  classify_browsers || exit 1
fi

while IFS=$'\t' read -r action class handle pid path detail; do
  N_TOTAL+=1
  if [ "$action" = reap ] && [ "$APPLY" = 1 ]; then
    result=$(close_terminal "$handle" "$path" "$pid")
    case "$result" in closed*) N_DONE+=1 ;; skipped*) N_SKIP+=1 ;; *) N_FAIL+=1 ;; esac
    action=${result%%$'\t'*}
    why=${result#*$'\t'}
    [ "$why" = - ] || class="$class:$why"
  elif [ "$action" = reap ]; then
    N_REAP+=1
  else
    N_KEEP+=1
  fi
  printf '%s\tterminal\t%s\t%s\t%s\t%s\n' "$action" "$class" "$handle" "$path" "$detail"
done < "$WORK/terminal-verdicts.tsv"

if [ "$APPLY" = 1 ]; then
  : > "$WORK/exclude.txt"
  SNAP_EPOCH=$(date +%s)
  if ! LC_ALL=C ps -axo pid=,ppid=,etime=,args= > "$WORK/ps.txt" 2>/dev/null; then
    echo "error: the process table could not be re-read; no browser was stopped" >&2
    : > "$WORK/browsers.tsv"
    INV_FAIL+=1
  else
    if fm_backend_orca_cwd_scan > "$WORK/cwd.txt"; then CWD_SCAN_OK=1; else CWD_SCAN_OK=0; : > "$WORK/cwd.txt"; fi
    classify_browsers || { echo "error: browsers could not be classified; no browser was stopped" >&2; : > "$WORK/browsers.tsv"; INV_FAIL+=1; }
  fi
fi

while IFS=$'\t' read -r bpid bverdict bclass bdir _ bdetail; do
  [ -n "$bpid" ] || continue
  B_TOTAL+=1
  action=$bverdict
  if [ "$bverdict" = reap ] && [ "$APPLY" = 1 ] && [ "$STOP_BROWSERS" = 1 ]; then
    result=$(stop_browser "$bpid" "$WORK/browser-$bpid.id")
    case "$result" in stopped*) B_DONE+=1 ;; skipped*) B_SKIP+=1 ;; *) B_FAIL+=1 ;; esac
    action=${result%%$'\t'*}
    why=${result#*$'\t'}
    [ "$why" = - ] || bclass="$bclass:$why"
  elif [ "$bverdict" = reap ]; then
    B_REAP+=1
  else
    B_KEEP+=1
  fi
  printf '%s\tbrowser\t%s\t%s\t%s\t%s\n' "$action" "$bclass" "$bpid" "$bdir" "$bdetail"
done < "$WORK/browsers.tsv"

if [ "$APPLY" = 1 ]; then
  N_KEEP=$((N_TOTAL - N_DONE - N_SKIP - N_FAIL))
  B_KEEP=$((B_TOTAL - B_DONE - B_SKIP - B_FAIL - B_REAP))
  printf 'summary: mode=apply terminals=%d closed=%d skipped=%d failed=%d keep=%d browsers=%d stopped=%d skipped=%d failed=%d reap=%d keep=%d\n' \
    "$N_TOTAL" "$N_DONE" "$N_SKIP" "$N_FAIL" "$N_KEEP" "$B_TOTAL" "$B_DONE" "$B_SKIP" "$B_FAIL" "$B_REAP" "$B_KEEP"
  [ $((N_FAIL + B_FAIL + INV_FAIL)) -eq 0 ] || exit 3
else
  printf 'summary: mode=dry-run terminals=%d reap=%d keep=%d browsers=%d reap=%d keep=%d\n' \
    "$N_TOTAL" "$N_REAP" "$N_KEEP" "$B_TOTAL" "$B_REAP" "$B_KEEP"
fi
exit 0
