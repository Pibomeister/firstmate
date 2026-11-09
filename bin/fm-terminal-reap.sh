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
# succeeded or was safely skipped); 1 when an inventory read failed, in which
# case nothing is closed; 2 on a usage error; 3 when --apply hit a failure.
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
#   keep foreign       it runs outside every home root and outside every
#                      firstmate task worktree (a worktree whose directory name
#                      starts with fm-, the spawn's own naming), so it belongs to
#                      the captain or another tool and is never firstmate's to
#                      close
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
#   keep live-worker   an agent still runs inside its task worktree
#   keep unlanded      its task worktree has uncommitted changes or commits no
#                      remote-tracking branch holds
#   keep unproven      landed state or the working-directory scan was unreadable
#   reap idle-session  an idle shell in a home root whose title contains, in
#                      any case, main, successor, handoff, firstmate, or fm-: a
#                      finished primary or secondmate session left at its prompt
#   reap idle-task     an idle shell in an unrecorded firstmate task worktree
#                      whose work is all committed and held by a remote branch
#   reap gone-worktree an idle shell whose firstmate task worktree is gone
# "Idle" means the session's process tree holds shells and nothing else
# (fm_backend_orca_tree_state's dead verdict). The landed test here is weaker
# than bin/fm-teardown.sh's: it needs only a clean tree and a HEAD that some
# remote-tracking branch holds (any remote, including a gate remote), with no
# merged-PR or default-branch proof. It is safe only because closing an idle
# shell never touches a worktree's files, and it must not be reused as
# teardown-grade proof that work has landed.
#
# Browser roots are agent-browser daemons, chrome-devtools-axi bridges, and
# automation browsers (headless, pipe-debugged, Playwright, or Puppeteer
# builds) whose parent has exited. Each root is judged by its working
# directory, together with every process under it:
#   keep task          it works in a recorded task's worktree
#   keep home          it works in a home root
#   keep young         it is younger than --min-age
#   keep unknown       its working directory could not be read
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
# --apply re-proves each terminal immediately before closing it: the records are
# re-read, fm_backend_orca_agent_state must still report dead or missing, and
# Orca must still name the session pid it was classified with (a replaced
# session is skipped). An idle-task close also re-reads the working-directory
# scan and the landed state, and a gone-worktree close requires the worktree to
# be still gone; any change or unreadable fact skips the close.
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

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

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
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}; id=${id%.meta}
      terminal=$(fm_meta_get "$meta" terminal)
      worktree=$(fm_meta_get "$meta" worktree)
      [ -z "$worktree" ] || worktree=$(phys "$worktree")
      printf 'rec\t%s\t%s\t%s\t%s\n' "$home" "$id" "$terminal" "$worktree"
    done
    reg="$home/data/secondmates.md"
    [ -f "$reg" ] || continue
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
  collect_owners > "$WORK/owners.tsv" || return 1
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
# prints `handle prelim scope pid path title`; prelim is a final keep class or
# `candidate`. Mode browsers prints `pid verdict class cwd descendants detail`.
classify_node() {
  node - "$1" "$WORK" "$MIN_AGE" "$CWD_SCAN_OK" <<'JS'
const fs = require("fs");
const [mode, work, minAgeRaw, scanOk] = process.argv.slice(2);
const minAge = Number(minAgeRaw);
const read = (f) => fs.readFileSync(`${work}/${f}`, "utf8");
const clean = (s) => String(s == null ? "" : s).replace(/[\t\r\n]+/g, " ").trim();
const real = (p) => { try { return fs.realpathSync(p); } catch (_) { return p; } };
const exists = (p) => { try { return fs.statSync(p).isDirectory(); } catch (_) { return false; } };
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
    let prelim = "candidate", scope = "", pid = "", detail = title;
    const emit = () => process.stdout.write(row([handle, prelim, scope, pid, path, detail]));
    let r;
    if ((t.executionHostId || "local") !== "local") { prelim = "remote"; emit(); continue; }
    if ((r = recFor((x) => x.terminal && x.terminal === handle))) {
      prelim = "task"; detail = `${r.id} (${r.home})`; emit(); continue;
    }
    if (wt && (r = recFor((x) => x.worktree && x.worktree === wt))) {
      prelim = "task-worktree"; detail = `${r.id} (${r.home}); ${title}`; emit(); continue;
    }
    if (wt && homes.includes(wt)) scope = "home";
    else if (wt && /^fm-/.test(wt.split("/").pop())) scope = exists(wt) ? "task" : "gone";
    else { prelim = "foreign"; emit(); continue; }
    const sp = pidOf.get(clean(t.ptyId));
    if (!Number.isInteger(sp) || sp <= 1 || dup.has(clean(t.ptyId))) { prelim = "no-session"; emit(); continue; }
    pid = String(sp);
    const p = procs.get(sp);
    if (!p) { prelim = "no-session"; emit(); continue; }
    if (!(p.age >= minAge)) { prelim = "young"; emit(); continue; }
    emit();
  }
} else if (mode === "browsers") {
  const isRoot = (p) => {
    const a = p.args;
    if (/\/agent-browser\//.test(a) && /daemon\.js/.test(a)) return true;
    if (/chrome-devtools-axi-bridge/.test(a)) return true;
    return p.ppid === 1 && /(--headless|--remote-debugging-pipe|\/ms-playwright\/|puppeteer_dev_chrome_profile|playwright_chromiumdev_profile)/.test(a);
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
    else if (!exists(dir)) { verdict = "reap"; cls = "owner-gone"; }
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

firstmate_title() {  # <title>
  case "$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    *main*|*successor*|*handoff*|*firstmate*|*fm-*) return 0 ;;
  esac
  return 1
}

# landed_state <worktree> -> landed|unlanded|unknown
landed_state() {
  local wt=$1 dirty ahead
  git -C "$wt" rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  dirty=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) || { printf 'unknown'; return 0; }
  [ -z "$dirty" ] || { printf 'unlanded'; return 0; }
  ahead=$(git -C "$wt" rev-list -n 1 HEAD --not --remotes 2>/dev/null) || { printf 'unknown'; return 0; }
  [ -z "$ahead" ] || { printf 'unlanded'; return 0; }
  printf 'landed'
}

# judge_terminal <scope> <pid> <path> <title> -> `<action> <class>` and, for a
# reap, the session's pids on fd 3 so browsers can discount them.
judge_terminal() {
  local scope=$1 pid=$2 path=$3 title=$4 state tree agents landed
  tree=$(fm_backend_orca_process_tree "$pid") || { printf 'keep\tunreadable'; return 0; }
  if printf '%s\n' "$tree" | cut -f1 | grep -qx "$$"; then printf 'keep\tself'; return 0; fi
  state=$(fm_backend_orca_tree_state "$pid")
  case "$state" in
    alive) printf 'keep\tlive-agent'; return 0 ;;
    ambiguous) printf 'keep\tbusy'; return 0 ;;
    dead) ;;
    *) printf 'keep\tunreadable'; return 0 ;;
  esac
  case "$scope" in
    home)
      firstmate_title "$title" || { printf 'keep\tcaptain'; return 0; }
      printf 'reap\tidle-session'
      ;;
    gone)
      printf 'reap\tgone-worktree'
      ;;
    task)
      [ "$CWD_SCAN_OK" = 1 ] || { printf 'keep\tunproven'; return 0; }
      agents=$(fm_backend_orca_worktree_agent_pids "$path" "$(cat "$WORK/cwd.txt")") || { printf 'keep\tunproven'; return 0; }
      [ -z "$agents" ] || { printf 'keep\tlive-worker'; return 0; }
      landed=$(landed_state "$path")
      case "$landed" in
        landed) printf 'reap\tidle-task' ;;
        unlanded) printf 'keep\tunlanded'; return 0 ;;
        *) printf 'keep\tunproven'; return 0 ;;
      esac
      ;;
    *) printf 'keep\tunreadable'; return 0 ;;
  esac
  printf '%s\n' "$tree" | cut -f1 >&3
}

# recorded_now <handle> <path>: true when a fresh read of the records claims
# this terminal or its worktree.
recorded_now() {
  local handle=$1 wt
  wt=$(phys "$2")
  collect_owners | awk -F'\t' -v h="$handle" -v w="$wt" '
    $1 == "rec" && (($4 != "" && $4 == h) || ($5 != "" && $5 == w)) { found = 1 }
    END { exit found ? 0 : 1 }'
}

close_terminal() {  # <handle> <path> <class> <pid> -> closed|skipped:<why>|failed:<why>
  local handle=$1 path=$2 class=$3 pid=$4 state out facts pty now scan agents
  if recorded_now "$handle" "$path"; then printf 'skipped\tnow-recorded'; return 0; fi
  state=$(fm_backend_orca_agent_state "$handle")
  case "$state" in
    dead|missing) ;;
    *) printf 'skipped\tnow-%s' "$state"; return 0 ;;
  esac
  case "$class" in
    idle-task)
      scan=$(fm_backend_orca_cwd_scan) || { printf 'skipped\tnow-unproven'; return 0; }
      agents=$(fm_backend_orca_worktree_agent_pids "$path" "$scan") || { printf 'skipped\tnow-unproven'; return 0; }
      [ -z "$agents" ] || { printf 'skipped\tnow-live-worker'; return 0; }
      case "$(landed_state "$path")" in
        landed) ;;
        unlanded) printf 'skipped\tnow-unlanded'; return 0 ;;
        *) printf 'skipped\tnow-unproven'; return 0 ;;
      esac
      ;;
    gone-worktree)
      [ ! -e "$path" ] || { printf 'skipped\tnow-present'; return 0; }
      ;;
  esac
  # Last, so a session replaced after the state read is still caught: a
  # connected terminal must still be rooted at the classified session pid.
  if [ "$state" = dead ]; then
    facts=$(fm_backend_orca_terminal_facts "$handle") || { printf 'skipped\tnow-unreadable'; return 0; }
    IFS=$'\x1f' read -r _ _ _ _ pty _ _ <<FACTS
$facts
FACTS
    now=$(fm_backend_orca_session_pid "$pty") || { printf 'skipped\tnow-unreadable'; return 0; }
    [ "$now" = "$pid" ] || { printf 'skipped\tnow-replaced'; return 0; }
  fi
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

declare -i N_REAP=0 N_KEEP=0 N_DONE=0 N_SKIP=0 N_FAIL=0 B_REAP=0 B_KEEP=0 B_DONE=0 B_SKIP=0 B_FAIL=0 N_TOTAL=0 B_TOTAL=0
: > "$WORK/terminal-verdicts.tsv"
while IFS=$'\t' read -r handle prelim scope pid path detail; do
  [ -n "$handle" ] || continue
  if [ "$prelim" = candidate ]; then
    verdict=$(judge_terminal "$scope" "$pid" "$path" "$detail" 3>>"$WORK/exclude.txt")
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
    result=$(close_terminal "$handle" "$path" "$class" "$pid")
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
    N_FAIL+=1
  else
    if fm_backend_orca_cwd_scan > "$WORK/cwd.txt"; then CWD_SCAN_OK=1; else CWD_SCAN_OK=0; : > "$WORK/cwd.txt"; fi
    classify_browsers || { : > "$WORK/browsers.tsv"; N_FAIL+=1; }
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
  [ $((N_FAIL + B_FAIL)) -eq 0 ] || exit 3
else
  printf 'summary: mode=dry-run terminals=%d reap=%d keep=%d browsers=%d reap=%d keep=%d\n' \
    "$N_TOTAL" "$N_REAP" "$N_KEEP" "$B_TOTAL" "$B_REAP" "$B_KEEP"
fi
exit 0
