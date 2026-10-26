#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. The recorded
# Droid task alone uses its verified raw Escape and Ctrl+U bytes.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-busy-lib.sh"
# Backend-neutral harness-process identity, shared with tmux and Herdr so the
# Orca stop proof below means the same thing by "agent" that they do.
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-agent-process-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

# Snapshot only the explicitly selected tmux session's local environment, never
# its server-global environment or the invoking process. The caller places these
# quoted assignments in its private staged launch file, never terminal input.
# Every allowlisted name must exist in the session; an explicit -NAME record is
# a deliberate unset, and a missing name refuses rather than falling back.
fm_backend_orca_launch_env_args() {  # <tmux-session> <newline-separated names>
  node - "$1" "$2" <<'JS'
const { spawnSync } = require("child_process");
const [session, names] = process.argv.slice(2);
function refuse(name) {
  // Do not echo tmux output or errors: they may contain credential values.
  const required = name === undefined ? "" : ` (required name ${name})`;
  console.error(`error: cannot snapshot configured tmux launch environment${required}; refusing Orca launch`);
  process.exit(1);
}
function read(name) {
  // Without -u, tmux sanitizes values when the client lacks a UTF-8 locale.
  const args = ["-u", "show-environment", "-t", `=${session}`];
  if (name !== undefined) args.push(name);
  // latin1 maps each byte to one code unit, so values that are not valid UTF-8
  // reach the launch file byte for byte instead of as replacement characters.
  const result = spawnSync("tmux", args, {
    encoding: "latin1", timeout: 10000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) refuse(name);
  return result.stdout;
}
// Verify the session even for an empty allowlist. Never derive names from raw
// multiline values or tmux's automatically populated update-environment.
read();
const assignments = [];
for (const name of new Set(names.split("\n").filter(Boolean))) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) refuse();
  // Read each name separately so embedded/trailing newlines are preserved and
  // a value resembling another NAME=value line cannot supply another variable.
  const output = read(name);
  if (!output.endsWith("\n")) refuse(name);
  const record = output.slice(0, -1);
  if (record === `-${name}`) continue;
  if (!record.startsWith(`${name}=`)) refuse(name);
  const value = record.slice(name.length + 1);
  if (value.includes("\0")) refuse(name);
  assignments.push(`${name}='${value.replace(/'/g, "'\\''")}'`);
}
process.stdout.write(assignments.join(" "), "latin1");
JS
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

# Orca exposes a rendered current frame with no history through
# --screen. Never accept its documented screen-unavailable stream fallback for
# trust or other viewport decisions.
fm_backend_orca_visible_capture() {  # <terminal-id> [expected-label]
  local terminal=$1 label=${2:-} out
  fm_backend_orca_recorded_droid "$terminal" "$label" || {
    echo "error: Orca screen capture requires this terminal's recorded Droid task" >&2
    return 1
  }
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --screen --json) || return 1
  fm_backend_orca_json_text "$out" screen
}

fm_backend_orca_json_text() {  # <json> [required-source]
  # shellcheck disable=SC2016 # JavaScript template expressions belong to Node.
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const terminal = r.terminal || r;
const required = process.argv[1] || "";
if (required && terminal.source !== required) {
  console.error(`Orca terminal read returned ${terminal.source || "no source"}, expected ${required}`);
  process.exit(2);
}
if (required && !Array.isArray(terminal.tail)) {
  console.error("Orca screen response has no rendered tail");
  process.exit(2);
}
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
' "${2:-}"
}

# A Droid composer proof applies only to this home's exact recorded terminal.
# An explicit backend target with no task identity keeps the generic unknown
# verdict, so a screen resembling Droid cannot authorize input into a shell.
fm_backend_orca_recorded_droid() {  # <terminal-id> <expected-label>
  local terminal=$1 label=${2:-} id meta harness recorded
  case "$label" in fm-*) id=${label#fm-} ;; *) return 1 ;; esac
  command -v fm_backend_meta_exact_value >/dev/null 2>&1 || return 1
  meta="${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta"
  [ -f "$meta" ] || return 1
  harness=$(fm_backend_meta_exact_value "$meta" harness) || return 1
  recorded=$(fm_backend_meta_exact_value "$meta" terminal) || return 1
  [ "$harness" = droid ] && [ "$recorded" = "$terminal" ]
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's live terminal
# read returned plain text, so styled stays 0 - the conservative degradation.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  if fm_backend_orca_recorded_droid "$1" "${2:-}"; then
    cap=$(fm_backend_orca_visible_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
    fm_composer_droid_state "$cap" orca
    return 0
  fi
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key> [expected-label]
  local terminal=$1 key=$2 label=${3:-} byte
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    Escape|C-u)
      fm_backend_orca_recorded_droid "$terminal" "$label" || {
        echo "error: Orca key '$key' requires this terminal's recorded Droid task" >&2
        return 1
      }
      case "$key" in Escape) byte=$'\033' ;; C-u) byte=$'\025' ;; esac
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$byte" --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle> [expected-label]
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  local state_dir='' id='' gen='' baseline='' baseline_seq='' prompt_hash='' verdict
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  if [ -n "$expected_label" ] && fm_backend_orca_recorded_droid "$terminal" "$expected_label"; then
    id=${expected_label#fm-}
    state_dir=${FM_STATE_OVERRIDE:-$FM_HOME/state}
    baseline=$(fm_busy_record_read "$state_dir" "$id" 2>/dev/null) || baseline=
    if [ -n "$baseline" ]; then
      baseline_seq=${baseline##* }
      gen=$(fm_busy_current_gen "$state_dir" "$id" 2>/dev/null) || gen=
      prompt_hash=$(printf '%s' "$text" | fm_busy_prompt_sha256) || prompt_hash=
    fi
  fi
  verdict=$(fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s" "$expected_label")
  if [ "$verdict" != empty ] && [ -n "$gen" ] && [ -n "$prompt_hash" ] \
    && fm_busy_prompt_receipt_after "$state_dir" "$id" "$gen" "$baseline_seq" "$prompt_hash"; then
    printf 'empty'
  else
    printf '%s' "$verdict"
  fi
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}

# --- Recovery-grade agent state and endpoint absence ------------------------
#
# Orca's terminal API never names the processes behind a terminal, so the
# verdicts below join three reads, each owned by a function of its own:
# `orca terminal show` (is the terminal connected, and if not, did Orca record
# why it exited), `orca diagnostics memory` (which local process roots a live
# pty session), and the operating system's process table under that root.
# docs/orca-backend.md "Agent stop proof" owns the empirical basis. Only
# fm-control and fm-spawn --relaunch read these verdicts, through
# fm_control_agent_state in bin/fm-control-lib.sh. Every read that fails or
# returns a shape the proof does not recognize is `unreadable`, never absence.

# fm_backend_orca_terminal_facts: one `orca terminal show` read of <terminal>,
# printed as \x1f-separated fields so an empty field survives `read`:
#   ok|stale  connected(true|false)  exit-cause-kind  execution-host  pty-id  worktree-path
# `stale` is Orca's own terminal_handle_stale answer: it no longer recognizes
# the handle at all. `false` needs both connected and writable false, the pair
# Orca reports after the pty is gone. Any CLI failure, unparsable output, other
# error, a result describing a different handle, or a mixed connection pair
# returns 1.
fm_backend_orca_terminal_facts() {  # <terminal-id>
  local terminal=$1 out
  fm_backend_orca_tool_check 2>/dev/null || return 1
  out=$(orca terminal show --terminal "$terminal" --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
const handle = process.argv[1];
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(1); }
if (!data || typeof data !== "object") process.exit(1);
function str(v) { return typeof v === "string" ? v : ""; }
function emit(fields) {
  if (fields.some((f) => /[\x1f\n\r]/.test(f))) process.exit(1);
  process.stdout.write(fields.join("\x1f"));
}
if (data.ok === false) {
  if (data.error && data.error.code === "terminal_handle_stale") {
    emit(["stale", "", "", "", "", ""]);
    process.exit(0);
  }
  process.exit(1);
}
const t = data.result && data.result.terminal;
if (!t || typeof t !== "object" || t.handle !== handle) process.exit(1);
let connected;
if (t.connected === true) connected = "true";
else if (t.connected === false && t.writable === false) connected = "false";
else process.exit(1);
const kind = t.exitCause && typeof t.exitCause === "object" ? str(t.exitCause.kind) : "";
emit(["ok", connected, kind, str(t.executionHostId), str(t.ptyId), str(t.worktreePath)]);
' "$terminal"
}

# fm_backend_orca_session_pid: the local process that roots pty session
# <pty-id>, from Orca's own process sweep. Exit 0 prints the pid; exit 1 means
# the sweep was read and lists no such session; exit 2 means the sweep could
# not be read or names the session ambiguously.
fm_backend_orca_session_pid() {  # <pty-id>
  local pty=$1 out
  [ -n "$pty" ] || return 2
  fm_backend_orca_tool_check 2>/dev/null || return 2
  out=$(orca diagnostics memory --json 2>/dev/null) || return 2
  printf '%s' "$out" | node -e '
const fs = require("fs");
const pty = process.argv[1];
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(2); }
if (!data || data.ok === false || !data.result || !Array.isArray(data.result.worktrees)) process.exit(2);
const pids = [];
for (const wt of data.result.worktrees) {
  if (!wt || !Array.isArray(wt.sessions)) continue;
  for (const s of wt.sessions) if (s && s.sessionId === pty) pids.push(s.pid);
}
if (pids.length === 0) process.exit(1);
if (pids.length !== 1 || !Number.isInteger(pids[0]) || pids[0] <= 1) process.exit(2);
process.stdout.write(String(pids[0]));
' "$pty"
}

# fm_backend_orca_process_tree: <root-pid> and every descendant, one
# `pid<TAB>comm` line each, root first. Returns 1 when the process table
# cannot be read or no longer holds the root.
fm_backend_orca_process_tree() {  # <root-pid>
  local root=$1 table
  table=$(LC_ALL=C ps -axo pid=,ppid=,comm= 2>/dev/null) || return 1
  printf '%s\n' "$table" | awk -v root="$root" '
    {
      line = $0
      pid = $1; ppid = $2
      if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/) next
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]?/, "", line)
      comm[pid] = line
      kids[ppid] = kids[ppid] " " pid
    }
    END {
      if (!(root in comm)) exit 1
      queue[1] = root; head = 1; tail = 1; seen[root] = 1
      while (head <= tail) {
        p = queue[head++]
        printf "%s\t%s\n", p, comm[p]
        n = split(kids[p], list, " ")
        for (i = 1; i <= n; i++) {
          c = list[i]
          if (c != "" && !(c in seen)) { seen[c] = 1; queue[++tail] = c }
        }
      }
    }'
}

# fm_backend_orca_classify_pid: one live process as agent|shell|other through
# the shared classifier, or nothing when the process exited meanwhile.
fm_backend_orca_classify_pid() {  # <pid> <comm>
  local pid=$1 comm=$2 args argv0
  args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || return 0
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_agent_process_classify "$comm" "$argv0" "$args" "$pid"
}

# fm_backend_orca_tree_state: the session tree under <root-pid> as
# alive|dead|ambiguous|unreadable. Any verified harness anywhere in the tree is
# `alive`. `dead` needs at least one shell and nothing but shells, apart from
# the `login` process Orca roots a macOS session with. Anything else - a
# background job, an unrecognized program - is `ambiguous`, because it could be
# an agent this classifier does not know.
fm_backend_orca_tree_state() {  # <root-pid>
  local root=$1 tree pid comm class shells=0 other=0
  tree=$(fm_backend_orca_process_tree "$root") || { printf 'unreadable'; return 0; }
  while IFS=$'\t' read -r pid comm; do
    [ -n "$pid" ] || continue
    class=$(fm_backend_orca_classify_pid "$pid" "$comm")
    case "$class" in
      agent) printf 'alive'; return 0 ;;
      shell) shells=1 ;;
      '') ;;
      *)
        if [ "$pid" != "$root" ] || [ "${comm##*/}" != login ]; then
          other=1
        fi
        ;;
    esac
  done <<TREE
$tree
TREE
  if [ "$other" = 0 ] && [ "$shells" = 1 ]; then
    printf 'dead'
  else
    printf 'ambiguous'
  fi
}

# fm_backend_orca_agent_state: recovery-grade agent state for one recorded
# terminal, in fm_backend_agent_state's vocabulary. A connected terminal is
# classified from its session's process tree. A disconnected terminal for which
# Orca recorded an exit cause is `missing`: its pty is gone, which is evidence
# about the terminal and not yet proof that no agent survived it - only
# fm_backend_orca_endpoint_absence_proof below can establish that. A stale
# handle, a terminal on another execution host, or any unreadable fact is
# `unreadable`.
fm_backend_orca_agent_state() {  # <terminal-id>
  local terminal=${1:-} facts read connected kind host pty wtpath pid
  [ -n "$terminal" ] || { printf 'unreadable'; return 0; }
  facts=$(fm_backend_orca_terminal_facts "$terminal") || { printf 'unreadable'; return 0; }
  IFS=$'\x1f' read -r read connected kind host pty wtpath <<FACTS
$facts
FACTS
  [ "$read" = ok ] && [ "$host" = local ] || { printf 'unreadable'; return 0; }
  case "$connected" in
    false)
      if [ -n "$kind" ]; then printf 'missing'; else printf 'unreadable'; fi
      return 0
      ;;
    true) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  pid=$(fm_backend_orca_session_pid "$pty") || { printf 'unreadable'; return 0; }
  fm_backend_orca_tree_state "$pid"
}

# fm_backend_orca_physical_dir: <dir> with every symlink resolved, or 1.
fm_backend_orca_physical_dir() {  # <dir>
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# fm_backend_orca_worktree_agent_pids: every process this user owns whose
# working directory is <worktree> or below it and that classifies as an agent,
# one `pid<TAB>comm` line each. This catches an agent that outlived the pty it
# started in. Returns 1 when the working-directory scan cannot be read, which
# the caller must treat as missing proof, never as an empty scan.
fm_backend_orca_worktree_agent_pids() {  # <worktree>
  local worktree=$1 root scan pids pid comm
  root=$(fm_backend_orca_physical_dir "$worktree") || return 1
  [ -n "$root" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  scan=$(LC_ALL=C lsof -nP -a -u "$(id -u)" -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$scan" ] || return 1
  pids=$(printf '%s\n' "$scan" | awk -v root="$root" '
    /^p/ { pid = substr($0, 2); next }
    /^n/ { path = substr($0, 2); if (pid != "" && (path == root || index(path, root "/") == 1)) print pid }')
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    comm=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) || continue
    [ "$(fm_backend_orca_classify_pid "$pid" "$comm")" = agent ] || continue
    printf '%s\t%s\n' "$pid" "$comm"
  done <<PIDS
$pids
PIDS
  return 0
}

# fm_backend_orca_host_boot_epoch: the host's current boot time as epoch
# seconds. FM_ORCA_BOOT_EPOCH (decimal epoch) overrides the read so tests can
# pin a boot relative to a recorded handle; production reads the kernel:
# kern.boottime on Darwin, /proc/stat's btime on Linux. Returns 1 when no
# boot time can be established, which the caller treats as missing proof.
fm_backend_orca_host_boot_epoch() {
  local boot
  if [ -n "${FM_ORCA_BOOT_EPOCH:-}" ]; then
    case "$FM_ORCA_BOOT_EPOCH" in
      ''|*[!0-9]*|0) return 1 ;;
      *) printf '%s' "$FM_ORCA_BOOT_EPOCH"; return 0 ;;
    esac
  fi
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    boot=$(sysctl -n kern.boottime 2>/dev/null) || return 1
    # "sec = 1792904944, usec = 578002" (older form: "{ sec = ..., ... }").
    boot=$(printf '%s' "$boot" | sed -n 's/.*[ {]sec = \([0-9][0-9]*\).*/\1/p' | head -1)
  else
    boot=$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)
  fi
  case "$boot" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s' "$boot"
}

# fm_backend_orca_recorded_evidence_epoch <meta-file>: when the recorded
# terminal handle's incarnation was recorded, as epoch seconds. The spawn
# generation (`spawn_gen=s<epoch>.<pid>.<rand>`) is written in the same
# record publication as the terminal handle, so its epoch is the handle's
# recorded evidence; a record without a parseable generation falls back to
# the record file's own mtime. Returns 1 when neither can be established.
fm_backend_orca_recorded_evidence_epoch() {  # <meta-file>
  local meta=${1:-} gen epoch mtime
  [ -n "$meta" ] && [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  gen=$(awk -F= '$1 == "spawn_gen" { v = $2 } END { print v }' "$meta" 2>/dev/null) || return 1
  case "$gen" in
    s[0-9]*.*)
      epoch=${gen#s}
      epoch=${epoch%%.*}
      case "$epoch" in ''|*[!0-9]*|0) ;;
        *) printf '%s' "$epoch"; return 0 ;;
      esac
      ;;
  esac
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$meta" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$meta" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s' "$mtime"
}

# fm_backend_orca_sweep_readable: whether Orca's process sweep
# (`orca diagnostics memory`) can be read and carries the shape
# fm_backend_orca_session_pid validates per session. A stale handle has no
# pty to look up in the sweep, so the reboot proof below reads the sweep
# itself: a readable sweep is what proves this seat's Orca is the post-boot
# runtime rather than an unreachable one.
fm_backend_orca_sweep_readable() {
  local out
  fm_backend_orca_tool_check 2>/dev/null || return 1
  out=$(orca diagnostics memory --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(1); }
if (!data || data.ok === false || !data.result || !Array.isArray(data.result.worktrees)) process.exit(1);
'
}

# fm_backend_orca_endpoint_absence_proof: prints `<verdict>\t<reason>` in
# fm_control_endpoint_absence_verdict's vocabulary for recorded terminal
# <terminal> of the task whose recorded worktree is <worktree>. `gone` needs
# every one of these, each read independently:
#   - Orca still recognizes the handle and reports it disconnected, unwritable,
#     with a recorded exit cause, on the local host;
#   - the terminal belonged to the recorded worktree;
#   - Orca's process sweep was read and no longer lists the terminal's pty;
#   - no process of this user that classifies as an agent has its working
#     directory in the recorded worktree.
# A terminal that turns out to be connected is re-classified, so a stopped
# agent in a live terminal reads `dead` and a live one `alive`. Everything else
# is `unproven`, with the fact that could not be established as the reason. An
# agent found in the worktree is deliberately `unproven` rather than `alive`:
# it is not in the recorded terminal, so no lifecycle command could reach it.
#
# The third argument, the task's record file, licenses one more `gone` case:
# a handle Orca no longer recognizes at all (`terminal_handle_stale`) after
# a host reboot. A pre-boot process cannot survive the boot, so when the
# host boot time postdates the handle's recorded evidence (the record's
# spawn generation, or its mtime without one), the stale lookup itself is
# the terminal evidence, and `gone` then needs only the remaining stopped-
# agent standards: a readable process sweep from the post-boot Orca and no
# agent process working in the recorded worktree. Without the record, with
# a boot that does not postdate it, or with any of those reads failing, a
# stale handle stays `unproven` exactly as before: an Orca restart short of
# a reboot can stale a handle whose agent may still be running.
fm_backend_orca_endpoint_absence_proof() {  # <terminal-id> <worktree> [<meta-file>]
  local terminal=${1:-} worktree=${2:-} meta=${3:-} facts read connected kind host pty wtpath state pids rc evidence boot
  [ -n "$terminal" ] || { printf 'unproven\tthe task record names no Orca terminal'; return 0; }
  [ -n "$worktree" ] \
    || { printf 'unproven\tthe task record names no worktree, so a surviving agent in it cannot be ruled out'; return 0; }
  facts=$(fm_backend_orca_terminal_facts "$terminal") \
    || { printf 'unproven\tOrca could not describe terminal %s' "$terminal"; return 0; }
  IFS=$'\x1f' read -r read connected kind host pty wtpath <<FACTS
$facts
FACTS
  if [ "$read" = stale ]; then
    [ -n "$meta" ] \
      || { printf 'unproven\tOrca no longer recognizes terminal %s, so it cannot say whether that terminal exited' "$terminal"; return 0; }
    evidence=$(fm_backend_orca_recorded_evidence_epoch "$meta") \
      || { printf 'unproven\tOrca no longer recognizes terminal %s and its record carries no recorded evidence time, so a reboot cannot be proven to postdate the handle' "$terminal"; return 0; }
    boot=$(fm_backend_orca_host_boot_epoch) \
      || { printf 'unproven\tOrca no longer recognizes terminal %s and the host boot time could not be read, so a reboot cannot be proven to postdate the handle' "$terminal"; return 0; }
    [ "$boot" -gt "$evidence" ] \
      || { printf 'unproven\tOrca no longer recognizes terminal %s, but the host boot time %s does not postdate its recorded evidence %s, so its agent cannot be proven to have died with the old boot' "$terminal" "$boot" "$evidence"; return 0; }
    fm_backend_orca_sweep_readable \
      || { printf 'unproven\tOrca no longer recognizes terminal %s and Orca'"'"'s process sweep could not be read, so a surviving agent cannot be ruled out' "$terminal"; return 0; }
    pids=$(fm_backend_orca_worktree_agent_pids "$worktree") \
      || { printf 'unproven\tthe working directories of local processes could not be read, so a surviving agent in %s cannot be ruled out' "$worktree"; return 0; }
    if [ -n "$pids" ]; then
      printf 'unproven\tan agent process still runs in %s (%s)' "$worktree" "$(printf '%s' "$pids" | tr '\t\n' ' ,')"
      return 0
    fi
    printf 'gone\t'
    return 0
  fi
  [ "$read" = ok ] \
    || { printf 'unproven\tOrca no longer recognizes terminal %s, so it cannot say whether that terminal exited' "$terminal"; return 0; }
  [ "$host" = local ] \
    || { printf 'unproven\tterminal %s runs on Orca execution host %s, whose processes cannot be read from here' "$terminal" "${host:-unknown}"; return 0; }
  if [ "$connected" = true ]; then
    state=$(fm_backend_orca_agent_state "$terminal")
    case "$state" in
      dead|alive) printf '%s\t' "$state" ;;
      *) printf 'unproven\tterminal %s is still connected and its agent state reads %s' "$terminal" "$state" ;;
    esac
    return 0
  fi
  [ -n "$kind" ] \
    || { printf 'unproven\tterminal %s is disconnected but Orca recorded no exit cause for it' "$terminal"; return 0; }
  [ -n "$wtpath" ] && [ "$(fm_backend_orca_physical_dir "$wtpath")" = "$(fm_backend_orca_physical_dir "$worktree")" ] \
    || { printf 'unproven\tterminal %s belonged to worktree %s, not the recorded %s' "$terminal" "${wtpath:-unknown}" "$worktree"; return 0; }
  rc=0
  fm_backend_orca_session_pid "$pty" >/dev/null || rc=$?
  case "$rc" in
    1) ;;
    0) printf 'unproven\tOrca still lists a live process for the session of terminal %s' "$terminal"; return 0 ;;
    *) printf 'unproven\tOrca process sweep could not be read'; return 0 ;;
  esac
  pids=$(fm_backend_orca_worktree_agent_pids "$worktree") \
    || { printf 'unproven\tthe working directories of local processes could not be read, so a surviving agent in %s cannot be ruled out' "$worktree"; return 0; }
  if [ -n "$pids" ]; then
    printf 'unproven\tan agent process still runs in %s (%s)' "$worktree" "$(printf '%s' "$pids" | tr '\t\n' ' ,')"
    return 0
  fi
  printf 'gone\t'
}
