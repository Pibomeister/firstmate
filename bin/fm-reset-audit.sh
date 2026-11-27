#!/usr/bin/env bash
# fm-reset-audit.sh - local mission-state continuity audit across a reset.
#
# Usage:
#   fm-reset-audit.sh snapshot [--out <file>]
#   fm-reset-audit.sh compare --before <file> [--after <file>]
#                     [--kind compaction|handoff] [--at <epoch>]
#                     [--strict|--no-strict]
#   fm-reset-audit.sh stage [--if-absent [--for <seconds>]]
#   fm-reset-audit.sh begin --kind compaction|handoff [--if-staged [--for <seconds>]]
#   fm-reset-audit.sh settle [--now]
#   fm-reset-audit.sh sweep
#   fm-reset-audit.sh arm [--if-needed] | disarm
#
# FM_HOME selects the home (default: the code root). Node and tasks-axi are
# required. Directory overrides and inherited TASKS_AXI_* addressing are ignored:
# every mission record belongs to this home. No network or harness is invoked.
# Local markdown and Beads backlogs use fm-tasks-axi.sh's read-only interface.
# A configured markdown Done archive must also resolve inside this home.
#
# snapshot emits deterministic version-1 JSON, with sorted open goal, captain
# hold, task metadata (id, branch, pr, spawn_gen), queued/in-flight item, and
# open captain order (id and pending/acked state, bin/fm-order.sh) inventories.
# It also includes terminal goal, Done, hold-resolution, and finished-order
# (done or parked with its outcome record) evidence so compare --after is
# entirely offline and does not consult live state.
# Captures are point-in-time observations, not a transaction with fleet writers;
# take snapshots at a quiet reset boundary, and retry a raced audit.
#
# compare requires the same canonical home in both manifests. Surviving IDs and
# durable terminal transitions account for prior work. A hold release needs a
# newer recorded resolution, never merely Done or unhold. A missing task needs
# Done evidence; a worker's done status alone is not teardown. Branch/PR updates
# on a surviving task are allowed. Missing backlog work also produces DRIFT.
# An open order must stay open or be finished with its outcome record; one that
# is missing, or finished without that record, is DRIFT. An order that stays
# open but is never acted on passes: the compare sees records, not work.
# Existing markdown Done archives supply completion and resolution evidence.
# Baseline occurrence totals prevent old closed lifecycles masking open work.
#
# Each compare appends one TSV row to <home>/state/reset-audit.tsv:
#   <epoch> <kind> <PASS|FAIL> <comma-separated category:id drift, or ->
# Fields are TAB-separated. The newest 100 rows are retained, under a local
# exclusive lock, by atomic replacement. Concurrent compares refuse (exit 2).
# Strict mode is the default: DRIFT prints FAIL and exits 1. --no-strict still
# records FAIL but exits 0. PASS exits 0; usage/read/schema errors exit 2 and
# never record a successful audit. --kind defaults to compaction. --at records
# the given epoch in the row instead of the time of the compare.
#
# The remaining commands run that audit once for every reset of this home, so
# each handoff and each compaction ends as exactly one row whose epoch is the
# time of the reset:
#   stage    saves a snapshot as the next handoff's "before" in
#            state/reset-audit-staged.json, replacing an earlier one.
#            bin/fm-ledger.sh handoff calls it once the document is written;
#            --if-absent keeps one that is at most 30 minutes old;
#            --for <seconds> keeps it only when it stays that fresh for the
#            given time and a minute more, so a launch that takes its whole
#            budget still finds it fresh at the transfer
#            (bin/fm-handoff-launch.sh passes its budget).
#   begin    records that a reset happened now. A handoff takes the staged
#            snapshot by rename, so of two --if-staged callers only one
#            records it; --if-staged does nothing when none is staged. A
#            staged snapshot older than 30 minutes belongs to a handoff that
#            never happened and is not recorded; it stays until the next
#            stage replaces it. --for <seconds> widens that age limit to the
#            given time and a minute more, for the launcher's verified
#            transfer of the snapshot its launch staged. A compaction, or a
#            handoff with nothing staged, takes a snapshot now, bounded to 12
#            seconds. The snapshot waits in
#            state/reset-audit-pending/<epoch>-<kind>-<pid>.json, and begin
#            arms the check. Callers: bin/fm-sessionstart-run.sh for a compact
#            session open by the lock owner, bin/fm-bootstrap.sh for a new
#            session that takes the helm, and bin/fm-handoff-launch.sh at a
#            verified transfer. At most 20 resets wait: a further snapshot is
#            refused (exit 1) until one settles; a staged handoff is always
#            taken.
#   settle   compares each waiting reset that is at least
#            FM_RESET_AUDIT_SETTLE_SECS old (default 600) against one snapshot
#            of the present, with --no-strict and --at, then removes it. The
#            wait lets the session that came out of the reset act first: a
#            reset loses nothing from disk by itself, the loss shows when that
#            session drops work it no longer remembers. It prints one line per
#            FAIL and nothing per PASS. It waits for a later run while a task
#            close is in progress (state/<id>.backlog-close), because a
#            snapshot taken then can miss a task that is neither open nor yet
#            Done. A reset that still cannot be compared an hour after it was
#            due is moved to state/reset-audit-pending/unreadable/ (newest 20
#            kept) and reported in one line; it gets no row. --now settles
#            every waiting reset at once, prints every verdict, and exits 1
#            when one could not be compared. A row lock that a killed compare
#            left behind more than five minutes ago is removed first.
#   sweep    is what the armed check runs: bin/fm-handoff-reconcile.sh --apply
#            --report, then settle. It prints only lines the supervisor must
#            read, bounds its own work below the watcher's check timeout and
#            leaves the rest to the next run, and disarms the check once no
#            reset and no late handoff successor waits.
#   arm      installs and registers state/reset-audit.check.sh, the watcher
#            check that runs sweep; disarm retires it. --if-needed arms only
#            while a reset or a late handoff successor waits
#            (bin/fm-bootstrap.sh at each session start, bin/fm-handoff-ack.sh
#            when it refuses a successor), so an idle home keeps no check. A
#            check file of that name that this script did not write is left
#            unchanged.
# These commands change nothing and exit 0 when FM_STATE_OVERRIDE,
# FM_DATA_OVERRIDE or FM_CONFIG_OVERRIDE names a directory that is not this
# home's own, because the audit reads this home's records only.
# Not covered: a compaction on a harness with no tracked session-open source
# (docs/sessionstart-nudge.md), a restart with no handoff written, a reset
# whose snapshot could not be taken (a backlog tasks-axi cannot read, a
# missing tool, or the time bound), and work that existed only in chat.
# The comparison is the one compare owns, made ten minutes after the reset: a
# task closed in that time without Done evidence is reported as DRIFT.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac

# --- Reset lifecycle (stage, begin, settle, sweep, arm, disarm) -------------
CHECK_ID=reset-audit
CHECK_MARK='# fm-reset-audit: reset audit sweep check'
PENDING_CAP=20          # resets that may wait for their settle time
UNREADABLE_KEEP=20      # unreadable resets kept for inspection
UNREADABLE_GRACE=3600   # seconds past due before a reset is given up on
STAGED_MAX_MIN=30       # minutes a staged snapshot stays a handoff's "before"
BEGIN_SNAPSHOT_SECS=12  # bound of the snapshot a session open waits for
ROW_LOCK_STALE_MIN=5    # minutes before compare's row lock counts as orphaned

lifecycle_die() { printf 'fm-reset-audit: %s\n' "$1" >&2; exit 2; }

lifecycle_home() {
  local pair name value resolved
  HOME_DIR=$(cd "${FM_HOME:-$(dirname "$SCRIPT_DIR")}" 2>/dev/null && pwd -P) \
    || lifecycle_die 'FM_HOME is not a directory'
  for pair in FM_STATE_OVERRIDE:state FM_DATA_OVERRIDE:data FM_CONFIG_OVERRIDE:config; do
    name=${pair%%:*}
    value=${!name:-}
    [ -n "$value" ] || continue
    resolved=$(cd "$value" 2>/dev/null && pwd -P) || resolved=$value
    [ "$resolved" = "$HOME_DIR/${pair##*:}" ] || exit 0
  done
  umask 077
  STATE="$HOME_DIR/state"
  STAGED="$STATE/reset-audit-staged.json"
  PENDING="$STATE/reset-audit-pending"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || lifecycle_die "state directory is unavailable: $STATE"
  # shellcheck source=bin/fm-clock-lib.sh
  . "$SCRIPT_DIR/fm-clock-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
}

audit_cli() { env FM_HOME="$HOME_DIR" bash "$SCRIPT_DIR/fm-reset-audit.sh" "$@"; }

take_snapshot() {  # <destination> <seconds>
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.reset-audit-snap.XXXXXX") || return 1
  if fm_run_timed "$2" env FM_HOME="$HOME_DIR" bash "$SCRIPT_DIR/fm-reset-audit.sh" snapshot --out "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$1"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

pending_count() {  # the resets settle will take up: <epoch>-*.json files
  local file base count=0
  for file in "$PENDING"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    base=${file##*/}
    case "${base%%-*}" in ''|*[!0-9]*) continue ;; esac
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

staged_within() {  # <minutes>
  [ "$1" -gt 0 ] && [ -f "$STAGED" ] && [ ! -L "$STAGED" ] \
    && [ -z "$(find "$STAGED" -mmin +"$1" 2>/dev/null)" ]
}

budget_minutes() { printf '%s\n' $(( ($1 + 59) / 60 + 1 )); }

late_successor_waits() {
  [ -n "$(env FM_HOME="$HOME_DIR" bash "$SCRIPT_DIR/fm-handoff-reconcile.sh" --waiting 2>/dev/null | head -n 1)" ]
}

check_needed() { [ "$(pending_count)" -gt 0 ] || late_successor_waits; }

# A failed arm must not end the caller: lifecycle_die exits.
arm_quietly() { ( install_check ) >/dev/null 2>&1 || true; }

cmd_stage() {
  local usage='usage: fm-reset-audit.sh stage [--if-absent [--for <seconds>]]'
  case "$#:${1:-}:${2:-}:${3:-}" in
    0:::) ;;
    1:--if-absent::) ! staged_within "$STAGED_MAX_MIN" || return 0 ;;
    3:--if-absent:--for:*)
      case "$3" in ''|*[!0-9]*) lifecycle_die "$usage" ;; esac
      ! staged_within $((STAGED_MAX_MIN - $(budget_minutes "$3"))) || return 0
      ;;
    *) lifecycle_die "$usage" ;;
  esac
  take_snapshot "$STAGED" 30 || { printf 'fm-reset-audit: could not take the snapshot to stage\n' >&2; return 1; }
}

cmd_begin() {
  local kind="" if_staged=0 dest budget="" window=$STAGED_MAX_MIN
  local usage='usage: fm-reset-audit.sh begin --kind compaction|handoff [--if-staged [--for <seconds>]]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2:-}; shift 2 2>/dev/null || shift ;;
      --if-staged) if_staged=1; shift ;;
      --for) budget=${2:-}; shift 2 2>/dev/null || shift
        case "$budget" in ''|*[!0-9]*) lifecycle_die "$usage" ;; esac ;;
      *) lifecycle_die "$usage" ;;
    esac
  done
  case "$kind" in
    compaction|handoff) ;;
    *) lifecycle_die "$usage" ;;
  esac
  [ "$if_staged" -eq 0 ] || [ "$kind" = handoff ] || lifecycle_die '--if-staged applies to a handoff only'
  if [ -n "$budget" ]; then
    [ "$if_staged" -eq 1 ] || lifecycle_die '--for applies to --if-staged only'
    [ "$(budget_minutes "$budget")" -le "$window" ] || window=$(budget_minutes "$budget")
  fi
  if [ "$if_staged" -eq 1 ] && [ ! -f "$STAGED" ]; then return 0; fi
  mkdir -p "$PENDING" || return 1
  dest="$PENDING/$(fm_now)-$kind-$$.json"
  if [ "$kind" = handoff ]; then
    if staged_within "$window"; then
      # The rename is the claim: a second caller finds nothing to rename.
      if mv -- "$STAGED" "$dest" 2>/dev/null; then
        arm_quietly
        return 0
      fi
    fi
    [ "$if_staged" -eq 0 ] || return 0
  fi
  if [ "$(pending_count)" -ge "$PENDING_CAP" ]; then
    arm_quietly
    printf 'fm-reset-audit: %s resets already wait to be settled; this reset is not recorded\n' "$PENDING_CAP" >&2
    return 1
  fi
  take_snapshot "$dest" "$BEGIN_SNAPSHOT_SECS" \
    || { printf 'fm-reset-audit: could not take the snapshot for this reset\n' >&2; return 1; }
  arm_quietly
}

give_up() {  # <pending-file> <kind> <epoch> <why>
  local kept old
  mkdir -p "$PENDING/unreadable" || return 0
  kept="$PENDING/unreadable/${1##*/}"
  mv -f -- "$1" "$kept" 2>/dev/null || return 0
  printf 'reset audit: the %s at %s could not be audited (%s); its snapshot is kept at %s\n' "$2" "$3" "$4" "$kept"
  # shellcheck disable=SC2012 # Names are this script's own epoch-kind-pid form.
  ls -1 "$PENDING/unreadable" 2>/dev/null | sort -r | tail -n +"$((UNREADABLE_KEEP + 1))" | while IFS= read -r old; do
    rm -f -- "$PENDING/unreadable/$old"
  done
}

cmd_settle() {
  case "${1:-}" in
    '') [ "$#" -le 1 ] || lifecycle_die 'usage: fm-reset-audit.sh settle [--now]'; settle_waiting 0 ;;
    --now) [ "$#" -eq 1 ] || lifecycle_die 'usage: fm-reset-audit.sh settle [--now]'; settle_waiting 1 ;;
    *) lifecycle_die 'usage: fm-reset-audit.sh settle [--now]' ;;
  esac
}

settle_waiting() {  # <1 for --now, else 0>
  local now_flag=$1 window=${FM_RESET_AUDIT_SETTLE_SECS:-600} snap_secs=${SETTLE_SNAPSHOT_SECS:-30}
  local now file base epoch rest kind after out rc failed=0 why closing=0 marker
  local -a due=()
  case "$window" in ''|*[!0-9]*) window=600 ;; esac
  [ -d "$PENDING" ] || return 0
  now=$(fm_now)
  for file in "$PENDING"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    base=${file##*/}; epoch=${base%%-*}
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    if [ "$now_flag" -eq 1 ] || [ $((now - epoch)) -ge "$window" ]; then due+=("$file"); fi
  done
  [ "${#due[@]}" -gt 0 ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # One settle at a time, so no reset is compared twice.
  fm_lock_try_acquire "$STATE/.reset-audit-settle.lock" 2>/dev/null || return "$now_flag"
  find "$STATE" -maxdepth 1 -name '.reset-audit-snap.*' -mmin +60 -exec rm -f -- {} + 2>/dev/null || true
  # compare holds its row lock for one append; one this old has no holder.
  find "$STATE" -maxdepth 1 -name '.reset-audit.lock' -mmin +"$ROW_LOCK_STALE_MIN" -exec rm -f -- {} + 2>/dev/null || true
  after="$STATE/.reset-audit-snap.after.$$"
  rc=0
  # A task close in progress on either side of the snapshot makes it unsafe
  # to judge (see settle in the header).
  if [ "$now_flag" -eq 0 ]; then
    for marker in "$STATE"/*.backlog-close; do
      [ -e "$marker" ] || [ -L "$marker" ] || continue
      closing=1
    done
  fi
  take_snapshot "$after" "$snap_secs" || rc=1
  if [ "$now_flag" -eq 0 ]; then
    for marker in "$STATE"/*.backlog-close; do
      [ -e "$marker" ] || [ -L "$marker" ] || continue
      closing=1
    done
  fi
  for file in "${due[@]}"; do
    [ -f "$file" ] || continue
    [ -z "${SETTLE_DEADLINE:-}" ] || [ "$SECONDS" -lt "$SETTLE_DEADLINE" ] || break
    base=${file##*/}; base=${base%.json}; epoch=${base%%-*}; rest=${base#*-}; kind=${rest%%-*}
    if [ "$closing" -eq 1 ] && [ $((now - epoch)) -lt $((window + UNREADABLE_GRACE)) ]; then continue; fi
    why='the present state could not be read'
    out=''
    if [ "$rc" -eq 0 ]; then
      case "$kind" in
        compaction|handoff)
          if out=$(audit_cli compare --before "$file" --after "$after" --kind "$kind" --at "$epoch" --no-strict 2>&1); then
            rm -f -- "$file"
            case "$out" in
              FAIL*) printf 'reset audit: open work went missing across the %s at %s: %s (state/reset-audit.tsv)\n' "$kind" "$epoch" "${out#*DRIFT }" ;;
              *) [ "$now_flag" -eq 0 ] || printf '%s at=%s\n' "$out" "$epoch" ;;
            esac
            continue
          fi
          why=$(printf '%s' "$out" | head -n 1)
          ;;
        *) why='its record does not name a reset kind' ;;
      esac
    fi
    failed=1
    if [ "$now_flag" -eq 1 ]; then
      printf 'fm-reset-audit: the %s at %s could not be audited: %s\n' "$kind" "$epoch" "$why" >&2
    elif [ $((now - epoch)) -ge $((window + UNREADABLE_GRACE)) ]; then
      give_up "$file" "$kind" "$epoch" "$why"
    fi
  done
  rm -f -- "$after"
  fm_lock_release "$STATE/.reset-audit-settle.lock" 2>/dev/null || true
  [ "$now_flag" -eq 0 ] || return "$failed"
}

cmd_sweep() {
  local start=$SECONDS
  [ "$#" -eq 0 ] || lifecycle_die 'usage: fm-reset-audit.sh sweep'
  fm_run_timed 9 env FM_HOME="$HOME_DIR" bash "$SCRIPT_DIR/fm-handoff-reconcile.sh" --apply --report 2>/dev/null || true
  SETTLE_SNAPSHOT_SECS=10 SETTLE_DEADLINE=$((start + 24)) settle_waiting 0 || true
  # Nothing waits: retire the check, then look again, because a reset
  # recorded while it was being retired must not be left without one.
  if ! check_needed; then
    ( retire_check ) >/dev/null 2>&1 || true
    ! check_needed || arm_quietly
  fi
}

check_owned_or_absent() {
  local check="$STATE/$CHECK_ID.check.sh"
  [ -e "$check" ] || [ -L "$check" ] || return 0
  [ -f "$check" ] && [ ! -L "$check" ] && sed -n 2p "$check" 2>/dev/null | grep -qxF -- "$CHECK_MARK"
}

cmd_arm() {
  case "${1:-}" in
    '') ;;
    --if-needed) check_needed || return 0 ;;
    *) lifecycle_die 'usage: fm-reset-audit.sh arm [--if-needed]' ;;
  esac
  [ "$#" -le 1 ] || lifecycle_die 'usage: fm-reset-audit.sh arm [--if-needed]'
  install_check
}

install_check() {
  local device staged
  local -a shim
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  device=$(fm_pr_file_device "$STATE") || lifecycle_die "state directory is unavailable: $STATE"
  fm_pr_regular_destination_on_device_or_absent "$STATE/$CHECK_ID.check.sh" "$device" \
    || lifecycle_die "unsafe check destination: $STATE/$CHECK_ID.check.sh"
  check_owned_or_absent \
    || lifecycle_die "$STATE/$CHECK_ID.check.sh exists and is not the reset audit's check (a task named $CHECK_ID may own it); left unchanged"
  shim=('#!/usr/bin/env bash'
    "$CHECK_MARK"
    "export FM_HOME=$(printf '%q' "$HOME_DIR")"
    'unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE'
    "exec $(printf '%q' "$SCRIPT_DIR/fm-reset-audit.sh") sweep")
  staged=$(umask 077; mktemp "$STATE/.reset-audit-check.XXXXXX") || lifecycle_die 'could not stage the check'
  if ! { printf '%s\n' "${shim[@]}" > "$staged" && chmod 700 "$staged" \
    && mv -f -- "$staged" "$STATE/$CHECK_ID.check.sh"; }; then
    rm -f -- "$staged"
    lifecycle_die 'could not install the check'
  fi
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID"
}

cmd_disarm() {
  [ "$#" -eq 0 ] || lifecycle_die 'usage: fm-reset-audit.sh disarm'
  retire_check
}

retire_check() {
  if ! check_owned_or_absent; then
    printf 'fm-reset-audit: %s is not the reset audit check; left unchanged\n' "$STATE/$CHECK_ID.check.sh" >&2
    return 0
  fi
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID"
}

case "${1:-}" in
  stage|begin|settle|sweep|arm|disarm)
    lifecycle_command=$1
    shift
    lifecycle_home
    "cmd_$lifecycle_command" "$@"
    exit $?
    ;;
esac

exec node - "$SCRIPT_DIR" "$@" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const [scripts, command, ...args] = process.argv.slice(2);
const fail = message => { throw new Error(message); };
const slug = value => typeof value === 'string' && /^[A-Za-z0-9._-]+$/.test(value);
const sorted = rows => rows.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const canonical = value => JSON.stringify(value, null, 2) + '\n';
const digest = value => require('node:crypto').createHash('sha256').update(value).digest('hex');
const opts = {};
try {
  if (!['snapshot', 'compare'].includes(command)) fail('unknown command; see --help');
  const allowed = command === 'snapshot' ? ['--out'] : ['--before', '--after', '--kind', '--at'];
  let strict = true;
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (command === 'compare' && ['--strict', '--no-strict'].includes(flag)) {
      if ('strict' in opts) fail('repeated strict option');
      opts.strict = true;
      strict = flag === '--strict';
    } else {
      if (!allowed.includes(flag) || flag in opts || !args[i + 1] || args[i + 1].startsWith('--'))
        fail(`invalid or missing option: ${flag}`);
      opts[flag] = args[++i];
    }
  }
  const home = fs.realpathSync(process.env.FM_HOME || path.dirname(scripts));
  const inside = file => {
    let probe = path.resolve(file);
    while (!fs.existsSync(probe)) {
      try { if (fs.lstatSync(probe).isSymbolicLink()) fail(`unsafe path: ${file}`); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      probe = path.dirname(probe);
    }
    const real = fs.realpathSync(probe);
    if (real !== home && !real.startsWith(home + path.sep)) fail(`outside FM_HOME: ${file}`);
    return file;
  };
  const read = file => {
    inside(file);
    try { return fs.readFileSync(file, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') return ''; throw error; }
  };
  // TOON rows use JSON quoted strings, including escaped commas and newlines.
  // Validate table counts so a partial/tool-error listing cannot erase work.
  function table(output) {
    const lines = output.split('\n');
    function tail(start) {
      for (let i = start; i < lines.length; i++) {
        if (!lines[i].trim()) continue;
        const help = lines[i].match(/^help\[([0-9]+)\]:$/);
        if (!help) fail('unexpected backlog row or trailing output');
        for (let n = 0; n < Number(help[1]); n++) {
          if (!lines[++i]?.startsWith('  - ')) fail('incomplete backlog help');
        }
      }
    }
    const counts = lines.filter(line => /^count: [0-9]+$/.test(line));
    if (counts.length !== 1) fail('unreadable backlog count');
    const reported = Number(counts[0].slice(7));
    function prefix(end) {
      for (const line of lines.slice(0, end)) {
        if (line.trim() && line !== counts[0]) fail('unexpected backlog prefix');
      }
    }
    const index = lines.findIndex(line => /^tasks\[\d+\]\{.*\}:$/.test(line));
    if (index < 0) {
      const empty = lines.findIndex(line => /^tasks: 0 (?:\w+ )*tasks in this backlog$/.test(line));
      if (reported === 0 && empty >= 0) { prefix(empty); tail(empty + 1); return []; }
      fail('unreadable backlog listing');
    }
    const [, count, names] = lines[index].match(/^tasks\[(\d+)\]\{(.*)\}:$/);
    prefix(index);
    if (reported !== Number(count) || lines[index + 1 + Number(count)]?.startsWith('  ')) fail('inconsistent backlog count');
    const columns = names.split(',');
    if (new Set(columns).size !== columns.length) fail('duplicate backlog columns');
    if (!['id', 'state', 'body', 'hold_kind', 'held'].every(name => columns.includes(name))) fail('incomplete backlog schema');
    const rows = [];
    for (const line of lines.slice(index + 1, index + 1 + Number(count))) {
      if (!line.startsWith('  ')) fail('incomplete backlog listing');
      const tokens = line.slice(2).match(/"(?:\\.|[^"\\])*"|[^,]+|(?<=,)(?=,|$)/g) || [];
      if (tokens.length !== columns.length) fail('malformed backlog row');
      const values = tokens.map(token => token.startsWith('"') ? JSON.parse(token) : token);
      const row = Object.fromEntries(columns.map((name, i) => [name, values[i]]));
      if (!slug(row.id) || !['queued', 'in_flight', 'done'].includes(row.state)) fail('invalid backlog identity/state');
      rows.push(row);
    }
    if (rows.length !== Number(count)) fail('incomplete backlog listing');
    tail(index + 1 + Number(count));
    return rows;
  }
  const env = { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: path.join(home, 'data'),
    FM_STATE_OVERRIDE: path.join(home, 'state'), FM_CONFIG_OVERRIDE: path.join(home, 'config') };
  for (const key of Object.keys(env)) {
    if (/^(TASKS_AXI_|BEADS_|BD_)/.test(key) || key === 'FM_ROOT_OVERRIDE') delete env[key];
  }
  let backend;
  function resolveBackend() {
    if (!backend) {
      backend = execFileSync('bash', ['-c', '. "$1/fm-tasks-axi-lib.sh"; fm_tasks_axi_backend_resolve "$2"',
        'reset-audit', scripts, home], { env, encoding: 'utf8', timeout: 10000 }).trim();
      if (!['markdown', 'beads'].includes(backend)) fail(`non-local or unsupported backlog backend: ${backend}`);
      if (backend === 'beads') inside(path.join(home, '.beads'));
      env.TASKS_AXI_BACKEND = backend;
    }
    return backend;
  }
  function tasks(...argv) {
    resolveBackend();
    return execFileSync('bash', [path.join(scripts, 'fm-tasks-axi.sh'), ...argv],
      { env, cwd: home, encoding: 'utf8', timeout: 10000, maxBuffer: 16 * 1024 * 1024 });
  }
  function resolutionCount(body) {
    // Match the same legacy/current record markers as captain-hold's reader.
    if (!/^(?:Captain decision|Reconciliation evidence):/m.test(body)) return 0;
    return (body.match(/^Resolution recorded by fm-(?:captain|decision)-hold\.$/gm) || []).length;
  }
  function snapshot() {
    const goals = new Map();
    const terminalGoals = [];
    const goalOccurrences = new Map();
    for (const line of read(path.join(home, 'state/dispatch-log.tsv')).split('\n').filter(Boolean)) {
      const fields = line.split('\t');
      // A provider switch (bin/fm-dispatch-log.sh failover) never changes a goal's state.
      if (fields.length >= 5 && ['failover', 'failover-skip'].includes(fields[2])) continue;
      if (fields.length < 5 || !slug(fields[3]) || !['received', 'queued', 'dispatched', 'blocked'].includes(fields[2])) fail('malformed dispatch ledger');
      goals.set(fields[3], { id: fields[3], event: fields[2] });
      if (['dispatched', 'blocked'].includes(fields[2])) {
        const hash = digest(line);
        const occurrence = (goalOccurrences.get(hash) || 0) + 1;
        goalOccurrences.set(hash, occurrence);
        terminalGoals.push({ id: fields[3], event: fields[2], token: hash + ':' + occurrence });
      }
    }
    inside(path.join(home, 'data'));
    inside(path.join(home, 'data/backlog.md'));
    inside(path.join(home, '.tasks.toml'));
    if (resolveBackend() === 'beads' && !fs.existsSync(path.join(home, 'data')))
      fail('data directory is required to address the configured Beads backlog');
    const rows = fs.existsSync(path.join(home, 'data')) ? table(tasks('list', '--fields', 'body,hold_kind,held')).filter(row => row.state !== 'done') : [];
    const done = fs.existsSync(path.join(home, 'data')) ? table(tasks('list', '--state', 'done', '--fields', 'body,hold_kind,held')) : [];
    const holds = [], resolutions = [];
    for (const row of [...rows, ...done]) {
      let body = row.body || '';
      if (body.length >= 500 || /\(truncated, [0-9]+ chars total/.test(body)) {
        const shown = tasks('show', row.id, '--full');
        const match = shown.match(/^  body: (.*)$/m);
        if (!match) fail(`unreadable task body: ${row.id}`);
        body = match[1].startsWith('"') ? JSON.parse(match[1]) : match[1];
      }
      const count = resolutionCount(body);
      if (count) resolutions.push({ id: row.id, count, token: 'live:' + digest(body) });
      if (row.state !== 'done' && row.hold_kind === 'captain') {
        holds.push({ id: row.id, set: body.match(/^Captain hold set: (.*)$/m)?.[1] || '', resolutions: count });
      }
    }
    // Done retention appends normal markdown rows. Read only the newest block
    // per ID, and never let an old archive override a current live item.
    // Configuration may be global; mission records must stay in this home.
    const globalConfig = path.join(require('node:os').homedir(), '.tasks-axi/config.toml');
    const globalSettings = fs.existsSync(globalConfig) ? fs.readFileSync(globalConfig, 'utf8') : '';
    const settings = globalSettings + '\n[reset-audit-boundary]\n' + read(path.join(home, '.tasks.toml'));
    let section = '', archive = path.join(home, 'data/done-archive.md');
    for (const line of settings.split('\n')) {
      const heading = line.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/);
      if (heading) section = heading[1];
      if (section === 'markdown' && /^\s*archive\s*=/.test(line)) {
        const value = line.match(/^\s*archive\s*=\s*("(?:\\.|[^"\\])*"|'[^']*')\s*(?:#.*)?$/)?.[1];
        if (!value) fail('unsupported markdown archive setting');
        // tasks-axi treats both quote types literally, without TOML escapes.
        archive = path.resolve(home, value.slice(1, -1));
      }
    }
    const archived = [];
    const occurrences = new Map();
    let current;
    for (const line of (backend === 'beads' ? '' : read(archive)).split('\n')) {
      const match = line.match(/^- \[x\] ([A-Za-z0-9._-]+)(?: |$)/);
      if (match) {
        current = { id: match[1], body: '', header: line };
        archived.push(current);
      }
      else if (current && (line === '' || /^\s/.test(line))) current.body += line.replace(/^  /, '') + '\n';
      else current = undefined;
    }
    for (const row of archived) {
      const hash = digest(row.header + '\n' + row.body.trimEnd());
      const occurrence = (occurrences.get(hash) || 0) + 1;
      occurrences.set(hash, occurrence);
      row.token = 'archive:' + hash + ':' + occurrence;
      const count = resolutionCount(row.body);
      if (count) resolutions.push({ id: row.id, count, token: row.token });
    }
    const metas = fs.existsSync(path.join(home, 'state')) ? fs.readdirSync(path.join(home, 'state')).filter(name => name.endsWith('.meta') && !name.startsWith('.')) : [];
    const active = metas.map(name => {
      const id = name.slice(0, -5);
      if (!slug(id)) fail(`invalid metadata id: ${id}`);
      const values = Object.fromEntries(read(path.join(home, 'state', name)).split('\n').filter(line => line.includes('=')).map(line => {
        const index = line.indexOf('='); return [line.slice(0, index), line.slice(index + 1)];
      }));
      return { id, branch: values.branch || '', pr: values.pr || '', spawn_gen: values.spawn_gen || '' };
    });
    // bin/fm-order.sh owns the layout: data/orders/<state>/<id>.order, and a
    // finished order's done/ or parked/ <id>.outcome.
    // States are read in lifecycle order, so an order renamed between two
    // reads keeps only its later state.
    const orders = new Map(), finished = new Map();
    const ordersDir = inside(path.join(home, 'data/orders'));
    for (const state of ['pending', 'acked', 'done', 'parked']) {
      let names;
      try { names = fs.readdirSync(path.join(ordersDir, state)); }
      catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      for (const name of names) {
        const id = name.slice(0, -6);
        if (!name.endsWith('.order') || !/^[0-9]+-[0-9a-f]{8}$/.test(id)) continue;
        if (['pending', 'acked'].includes(state)) { orders.set(id, { id, state }); continue; }
        orders.delete(id);
        if (fs.existsSync(path.join(ordersDir, state, id + '.outcome'))) finished.set(id, { id, state });
      }
    }
    return { version: 1, home, goals: sorted([...goals.values()].filter(row => ['received', 'queued'].includes(row.event))),
      holds: sorted(holds), tasks: sorted(active), backlog: sorted(rows.filter(row => row.state !== 'done').map(({ id, state }) => ({ id, state }))),
      orders: sorted([...orders.values()]),
      evidence: { goals: sorted(terminalGoals), orders: sorted([...finished.values()]),
        done: sorted([...done.map(row => ({ id: row.id, token: 'live:' + digest(JSON.stringify(row)) })),
          ...archived.map(row => ({ id: row.id, token: row.token }))]), resolutions: sorted(resolutions) } };
  }
  function validate(value) {
    if (value?.version !== 1 || value.home !== home) fail('manifest version/home mismatch');
    for (const name of ['goals', 'holds', 'tasks', 'backlog', 'orders']) {
      if (!Array.isArray(value[name]) || value[name].some(row => !slug(row?.id)) || new Set(value[name].map(row => row.id)).size !== value[name].length)
        fail(`invalid manifest ${name}`);
    }
    if (value.goals.some(row => !['received', 'queued'].includes(row.event)) ||
        value.backlog.some(row => !['queued', 'in_flight'].includes(row.state)) ||
        value.orders.some(row => !['pending', 'acked'].includes(row.state)) ||
        value.tasks.some(row => ['branch', 'pr', 'spawn_gen'].some(key => typeof row[key] !== 'string')))
      fail('invalid manifest state');
    const evidence = value.evidence;
    if (!evidence || !Array.isArray(evidence.goals) || evidence.goals.some(row => !slug(row?.id) || typeof row.token !== 'string' || !['dispatched', 'blocked'].includes(row.event)) ||
        !Array.isArray(evidence.done) || evidence.done.some(row => !slug(row?.id) || typeof row.token !== 'string') || !Array.isArray(evidence.resolutions) ||
        evidence.resolutions.some(row => !slug(row?.id) || typeof row.token !== 'string' || !Number.isInteger(row.count) || row.count < 1) ||
        value.holds.some(row => !Number.isInteger(row.resolutions) || row.resolutions < 0) ||
        !Array.isArray(evidence.orders) || evidence.orders.some(row => !slug(row?.id) || !['done', 'parked'].includes(row.state)))
      fail('invalid manifest evidence');
    return value;
  }
  if (command === 'snapshot') {
    const output = canonical(snapshot());
    if (opts['--out']) fs.writeFileSync(opts['--out'], output, { mode: 0o600 });
    else process.stdout.write(output);
  } else {
    if (!opts['--before']) fail('--before is required');
    const kind = opts['--kind'] || 'compaction';
    if (!['compaction', 'handoff'].includes(kind)) fail('invalid reset kind');
    const at = opts['--at'];
    if (at !== undefined && !/^[0-9]{1,12}$/.test(at)) fail('invalid --at epoch');
    const before = validate(JSON.parse(fs.readFileSync(opts['--before'], 'utf8')));
    const after = validate(opts['--after'] ? JSON.parse(fs.readFileSync(opts['--after'], 'utf8')) : snapshot());
    const has = (rows, id) => rows.some(row => row.id === id);
    const total = (records, id) => records.filter(row => row.id === id).length;
    const answers = (records, id) => records.filter(row => row.id === id).reduce((sum, row) => sum + row.count, 0);
    const completed = id => total(after.evidence.done, id) > total(before.evidence.done, id) ||
      (!has(before.backlog, id) && has(after.evidence.done, id) &&
        before.evidence.done.some(row => row.id === id && row.token.startsWith('live:')));
    const drift = [];
    for (const row of before.goals)
      if (!has(after.goals, row.id) && total(after.evidence.goals, row.id) <= total(before.evidence.goals, row.id)) drift.push(`goal:${row.id}`);
    for (const row of before.holds)
      if (!has(after.holds, row.id) && answers(after.evidence.resolutions, row.id) <= answers(before.evidence.resolutions, row.id)) drift.push(`hold:${row.id}`);
    for (const row of before.tasks)
      if (!has(after.tasks, row.id) && !completed(row.id)) drift.push(`task:${row.id}`);
    for (const row of before.backlog)
      if (!has(after.backlog, row.id) && !completed(row.id)) drift.push(`backlog:${row.id}`);
    for (const row of before.orders)
      if (!has(after.orders, row.id) && !has(after.evidence.orders, row.id)) drift.push(`order:${row.id}`);
    drift.sort();
    const verdict = drift.length ? 'FAIL' : 'PASS';
    const state = inside(path.join(home, 'state'));
    fs.mkdirSync(state, { recursive: true });
    const log = inside(path.join(state, 'reset-audit.tsv'));
    const lock = inside(path.join(state, '.reset-audit.lock'));
    const fd = fs.openSync(lock, 'wx', 0o600);
    let temporary;
    try {
      const prior = read(log).split('\n').filter(Boolean).slice(-99);
      prior.push(`${at === undefined ? Math.floor(Date.now() / 1000) : Number(at)}\t${kind}\t${verdict}\t${drift.join(',') || '-'}`);
      temporary = path.join(state, `.reset-audit.${process.pid}.tmp`);
      fs.writeFileSync(temporary, prior.join('\n') + '\n', { flag: 'wx', mode: 0o600 });
      fs.renameSync(temporary, log);
    } finally {
      fs.closeSync(fd);
      fs.unlinkSync(lock);
      if (temporary && fs.existsSync(temporary)) fs.unlinkSync(temporary);
    }
    console.log(`${verdict} kind=${kind}${drift.length ? ' DRIFT ' + drift.join(',') : ''}`);
    if (strict && drift.length) process.exitCode = 1;
  }
} catch (error) {
  console.error(`fm-reset-audit: ${error.message}`);
  process.exitCode = 2;
}
NODE
