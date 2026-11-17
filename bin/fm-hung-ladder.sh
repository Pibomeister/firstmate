#!/usr/bin/env bash
# fm-hung-ladder.sh - hung-worker ladder, stage 1: the observe (dry-run) mode.
#
# A worker can hang while its agent is still alive: the pane renders busy or
# idle, nothing advances, and the dead-worker recovery never fires because the
# agent is not dead. This script decides, on each watcher pass, whether a live
# ship or scout worker has a hang episode, and records what the ladder WOULD
# do at each rung. It never acts. It sends no keys, writes no steering-inbox
# message, and calls no interrupt, exit, relaunch, or kill of any kind; no live
# action path exists in this file, whatever the configured mode says.
#
# Usage:
#   fm-hung-ladder.sh tick --task <id> --kind <ship|scout> [--busy 0|1] [--dialog <name>]
#       One observation of one task. The watcher's captured pane text is read
#       from stdin. --busy 1 means the watcher reads the pane as busy; it is
#       recorded, never trusted as progress. Called by bin/fm-watch.sh once per
#       sample interval per task; it writes only under state/hung-ladder/.
#   fm-hung-ladder.sh mode
#       Print the effective mode and why. Read-only.
#   fm-hung-ladder.sh set-mode <off|observe|steer|interrupt|relaunch> --actor <name>
#       Write config/hung-ladder. A live mode (steer, interrupt, relaunch) is
#       refused with no write unless a valid owner approval record exists
#       (below); even then the effective mode stays observe, because stage 1
#       builds no live path.
#   fm-hung-ladder.sh verify
#       Recompute the whole ledger hash chain. Exit 0 intact, 3 broken.
#   fm-hung-ladder.sh prune
#       For every task whose metadata is gone: resolve its pending would-act
#       rows (observe mode only), then remove its episode records and
#       snapshots. The watcher runs it once an hour, so cleanup reaches the
#       ledger even when no worker is left to observe. A refused live mode
#       writes nothing.
#   fm-hung-ladder.sh --help
#
# Exit status: 0 success or nothing to do; 2 usage error or refusal by a
# worker; 3 a live mode refused, or the ledger chain is broken.
#
# MODE (config/hung-ladder). An absent file means `off`. Lines are key=value
# and `#` starts a comment: mode=off|observe|steer|interrupt|relaunch,
# actor=<who set it>, and the optional tunables load_ceiling (default 200),
# cpu_quiet_secs (CPU seconds of the agent tree per sample that still read
# quiet, default 1) and unverified_wait_max_secs (default 7200). The file
# must be a regular file owned by this user and not group- or
# world-writable; otherwise it reads as `off`. A live mode without a valid
# approval resolves to `off` and the tick writes nothing at all.
# config/hung-ladder-skip lists task ids (one per line) the ladder never
# observes.
#
# APPROVAL (config/hung-ladder-approval): key=value lines mode=<live mode>,
# approved_by=<owner>, approved_at=<epoch>, ledger_head=<64-hex row hash>.
# Valid only when the file is a regular file owned by this user with no group
# or other permission bits, its mode ranks at or above the requested one, and
# ledger_head names a row hash present in the ledger, which binds the
# approval to the observe record it was granted on.
#
# LEDGER (state/hung-ladder/actions.tsv). Append-only, tab-separated, one row
# per line, 15 fields:
#   seq time action_id task rung decision mode signals caps breaker reason
#   ref later_self_progressed prev_hash hash
# decision is observe (rung 0 episode record), would-act (rungs 1-5), hold,
# resolve, alarm, or mode. A resolve row names the earlier row in `ref` and
# carries later_self_progressed=yes|no for it; a later fact is always a new
# row, never an edit. Every field is escaped: backslash, tab, newline, and
# carriage return become \\ \t \n \r, and other control bytes become `?`.
# hash = sha256 of the row's first 14 fields joined by tabs, and prev_hash is
# the previous row's hash (64 zeros for the first), so an edited, removed, or
# inserted row breaks the chain. state/hung-ladder/head records the last seq
# and hash; before each append the last row is recomputed and compared with
# it, and a mismatch refuses the append and leaves ledger-refused behind.
# The one mismatch accepted is a head exactly one row behind a last row that
# chains from it, which a kill between the row and its head record leaves;
# the next append records that row as the head.
# The chain detects tampering; it cannot stop a same-user process that
# rewrites the whole chain consistently.
#
# OTHER FILES under state/hung-ladder/ (directory 0700, files 0600):
#   episodes/<task>.ep      the episode record (key=value), dated at T0
#   episodes/<task>.sample  the previous sensor readings (the watcher's
#                           sample throttle is an in-memory stamp)
#   episodes/<task>.anchor  the worktree write probe anchor
#   seen/<task>             the epoch of the last live reading; N for the breaker
#   snapshots/<task>/       redacted pane text and rung-4 content snapshots,
#                           removed once the task's metadata is gone
#   breaker, mode.last, head, .lock
#
# SENSORS. rendered: the normalized pane hash (ANSI, spinner glyphs and digit
# runs removed) against the previous sample. filesystem: status size and last
# line, inbox acknowledgements, head, dirty-content hash, and a worktree
# write probe; a scout reads only status and inbox. The content hash covers
# the status records, the diff against HEAD and the untracked files' content,
# never a secret-pattern file's content. A failed or timed-out
# content hash or write probe reads as unknown, never quiet. A status line
# that repeats one of the last 256 is a drip, not progress. kernel: CPU time
# of the agent's process tree per sample, unknown above the load ceiling or
# when the tree cannot be read, unsupported when the backend names no root
# process. A descendant counts as working, and vetoes the proof, until its
# CPU time and I/O count have stayed unchanged for 15 minutes; only then is
# it a stale child. A failed Git read keeps the last good HEAD and content
# hash, so it never reads as progress. I/O comes
# from /proc/<pid>/io where it exists. macOS exposes no unprivileged I/O
# counter, so there the 10 ms CPU clock, which every I/O system call
# advances, stands in for it.
# records: a declared wait's named job. Transcript and loop proofs are
# recorded as unsupported. Git reads use --no-optional-locks and never write.
# The validation read runs the crew-state reader with its snapshot cache off
# (FM_CREW_STATE_NO_SNAPSHOT=1), so it takes no lock. A screen block that
# lasts 4 minutes parks the episode, whether it appeared before or inside it.
#
# FM_HUNG_LADDER_NOW, FM_HUNG_LADDER_LOAD and FM_HUNG_LADDER_PROBE (an
# executable answering `agent <task> <backend> <target>` with "<state> <pid>"
# and `composer <task> <backend> <target>` with a composer verdict) are test
# seams. FM_TEST_QUEUE_BIN and FM_CREW_STATE_BIN name the test queue and the
# crew-state reader. docs/configuration.md "Hung-worker ladder" is the
# operator reference.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
HL="$STATE/hung-ladder"
LEDGER="$HL/actions.tsv"
GENESIS=0000000000000000000000000000000000000000000000000000000000000000

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

fhl_now() {
  case "${FM_HUNG_LADDER_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$FM_HUNG_LADDER_NOW" ;;
  esac
}

fhl_sha() {  # stdin -> sha256 hex
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# GNU stat reads -f as file-system mode, so pick the flavor by system rather
# than by trying one and falling back.
fhl_stat() {  # <file> -> "<uid> <octal-perms>"
  [ -n "${FHL_OS:-}" ] || FHL_OS=$(uname 2>/dev/null)
  if [ "$FHL_OS" = Darwin ]; then
    /usr/bin/stat -f '%u %Lp' "$1" 2>/dev/null
  else
    stat -c '%u %a' "$1" 2>/dev/null
  fi
}

fhl_mtime() {  # <file> -> epoch seconds
  [ -n "${FHL_OS:-}" ] || FHL_OS=$(uname 2>/dev/null)
  if [ "$FHL_OS" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# 0 when <file> is a regular file owned by this user whose permissions have
# none of the bits in <mask> (octal, e.g. 022 or 077).
fhl_owner_file() {  # <file> <mask>
  local f=$1 mask=$2 info uid perms
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  info=$(fhl_stat "$f") || return 1
  uid=${info%% *}
  perms=${info#* }
  [ "$uid" = "$(id -u)" ] || return 1
  [ $(( 8#$perms & 8#$mask )) -eq 0 ]
}

fhl_kv() {  # <file> <key> -> last value
  [ -f "$1" ] || return 1
  awk -v k="$2" '
    /^[ \t]*#/ { next }
    { i = index($0, "="); if (i && substr($0, 1, i - 1) == k) { v = substr($0, i + 1); found = 1 } }
    END { if (found) { print v; exit 0 } exit 1 }' "$1"
}

fhl_mode_rank() {
  case "$1" in off) echo 0 ;; observe) echo 1 ;; steer) echo 2 ;; interrupt) echo 3 ;; relaunch) echo 4 ;; *) echo -1 ;; esac
}

fhl_num() {  # <value> <default> -> non-negative integer
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac
}

# --- mode resolution ---------------------------------------------------------

# Sets CFG_MODE (what the file asks for), EFFECTIVE (what runs), MODE_REASON,
# and MODE_ACTOR. A live mode without approval sets EFFECTIVE=off and
# MODE_REASON=refused:...; callers treat that as write nothing.
fhl_resolve_mode() {
  local f="$CONFIG/hung-ladder" m
  CFG_MODE=off EFFECTIVE=off MODE_REASON=absent MODE_ACTOR=-
  [ -e "$f" ] || [ -L "$f" ] || return 0
  if ! fhl_owner_file "$f" 022; then
    MODE_REASON=refused:config-not-owner-only
    return 0
  fi
  m=$(fhl_kv "$f" mode) || m=$(awk '/^[ \t]*#/ { next } NF { print $1; exit }' "$f")
  MODE_ACTOR=$(fhl_kv "$f" actor) || MODE_ACTOR=-
  [ -n "$MODE_ACTOR" ] || MODE_ACTOR=-
  CFG_MODE=$m
  case "$m" in
    off) MODE_REASON=configured ;;
    observe) EFFECTIVE=observe MODE_REASON=configured ;;
    steer|interrupt|relaunch)
      if fhl_approval_valid "$m"; then
        EFFECTIVE=observe MODE_REASON=approved-live-path-not-built
      else
        MODE_REASON="refused:$APPROVAL_REASON"
      fi
      ;;
    *) MODE_REASON=refused:unknown-mode ;;
  esac
}

fhl_approval_valid() {  # <requested-mode>; sets APPROVAL_REASON
  local want=$1 f="$CONFIG/hung-ladder-approval" m head
  APPROVAL_REASON=no-approval-record
  [ -e "$f" ] || [ -L "$f" ] || return 1
  APPROVAL_REASON=approval-not-owner-only
  fhl_owner_file "$f" 077 || return 1
  APPROVAL_REASON=approval-incomplete
  m=$(fhl_kv "$f" mode) || return 1
  head=$(fhl_kv "$f" ledger_head) || return 1
  fhl_kv "$f" approved_by >/dev/null || return 1
  fhl_kv "$f" approved_at >/dev/null || return 1
  APPROVAL_REASON=approval-below-mode
  [ "$(fhl_mode_rank "$m")" -ge "$(fhl_mode_rank "$want")" ] || return 1
  APPROVAL_REASON=approval-unbound
  case "$head" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#head}" -eq 64 ] || return 1
  [ -f "$LEDGER" ] || return 1
  awk -F'\t' -v h="$head" '$15 == h { found = 1; exit } END { exit !found }' "$LEDGER" || return 1
  APPROVAL_REASON=approved
  return 0
}

fhl_refuse_worker() {
  if [ -n "${FM_TASK_ID:-}" ]; then
    printf 'fm-hung-ladder: refused: a worker (task %s) never writes the ladder\n' "$FM_TASK_ID" >&2
    exit 2
  fi
}

# --- ledger ------------------------------------------------------------------

fhl_esc() {  # <text> -> one escaped field
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//[[:cntrl:]]/?}
  [ -n "$s" ] || s=-
  printf '%s' "$s"
}

fhl_setup_dirs() {
  umask 077
  mkdir -p "$HL/episodes" "$HL/seen" "$HL/snapshots" || return 1
  chmod 700 "$HL" "$HL/episodes" "$HL/seen" "$HL/snapshots" 2>/dev/null || true
}

# Check that the ledger's tail matches the head record. Sets LAST_SEQ and
# LAST_HASH. Returns 1 (and leaves ledger-refused) on any mismatch.
fhl_ledger_tail_ok() {
  local last body hash seq head_seq head_hash
  LAST_SEQ=0 LAST_HASH=$GENESIS
  if [ ! -s "$LEDGER" ]; then
    if [ -e "$HL/head" ]; then
      fhl_ledger_refuse "ledger empty but head record present"
      return 1
    fi
    return 0
  fi
  last=$(tail -n 1 "$LEDGER")
  seq=${last%%$'\t'*}
  hash=${last##*$'\t'}
  body=${last%$'\t'*}
  if [ "$(printf '%s' "$body" | fhl_sha)" != "$hash" ]; then
    fhl_ledger_refuse "last row hash does not recompute"
    return 1
  fi
  if [ ! -e "$HL/head" ]; then
    head_seq=0 head_hash=$GENESIS
  elif ! IFS=$'\t' read -r head_seq head_hash < "$HL/head" 2>/dev/null; then
    fhl_ledger_refuse "head record unreadable"
    return 1
  fi
  case "$seq" in ''|*[!0-9]*) fhl_ledger_refuse "last row sequence is not a number"; return 1 ;; esac
  if [ "$head_seq" = "$((seq - 1))" ] && [ "${body##*$'\t'}" = "$head_hash" ]; then
    # A kill landed between the row and its head record: the row chains from
    # the recorded head and its own hash recomputes, so record it as the head.
    printf '%s\t%s\n' "$seq" "$hash" > "$HL/head.tmp" && mv -f "$HL/head.tmp" "$HL/head" || return 1
    head_seq=$seq head_hash=$hash
  fi
  if [ "$head_seq" != "$seq" ] || [ "$head_hash" != "$hash" ]; then
    fhl_ledger_refuse "last row does not match the head record"
    return 1
  fi
  LAST_SEQ=$seq LAST_HASH=$hash
}

fhl_ledger_refuse() {
  printf 'fm-hung-ladder: ledger refused: %s\n' "$1" >&2
  printf '%s\t%s\n' "$(fhl_now)" "$1" > "$HL/ledger-refused" 2>/dev/null || true
  LEDGER_BROKEN=1
}

# fhl_row <task> <rung> <decision> <reason> [<ref>] [<lsp>] -> action id in ROW_ID
fhl_row() {
  local task=$1 rung=$2 decision=$3 reason=$4 ref=${5:--} lsp=${6:--}
  local seq id body hash
  ROW_ID=
  [ "${LEDGER_BROKEN:-0}" = 0 ] || return 1
  fhl_ledger_tail_ok || return 1
  seq=$((LAST_SEQ + 1))
  id="hl-$seq"
  body="$seq	$NOW	$id	$(fhl_esc "$task")	$(fhl_esc "$rung")	$(fhl_esc "$decision")	$(fhl_esc "$EFFECTIVE")	$(fhl_esc "${SIGNALS:--}")	$(fhl_esc "${CAPS:--}")	$(fhl_esc "${BREAKER:--}")	$(fhl_esc "$reason")	$(fhl_esc "$ref")	$(fhl_esc "$lsp")	$LAST_HASH"
  hash=$(printf '%s' "$body" | fhl_sha)
  # The row and its head record are one step: the watcher's budget signal
  # must not land between them and leave the chain refusing every append.
  trap '' TERM INT HUP
  if ! printf '%s\t%s\n' "$body" "$hash" >> "$LEDGER"; then
    trap - TERM INT HUP
    return 1
  fi
  chmod 600 "$LEDGER" 2>/dev/null || true
  printf '%s\t%s\n' "$seq" "$hash" > "$HL/head.tmp" && mv -f "$HL/head.tmp" "$HL/head"
  trap - TERM INT HUP
  ROW_ID=$id
}

# The whole-chain walk: prints "<rows>\t<last-hash>" for an intact ledger
# that matches its head record (or sits one row behind it after a split
# append), or one "broken: ..." line and returns 3.
fhl_chain_walk() {
  local out last before
  if [ ! -s "$LEDGER" ]; then
    if [ -e "$HL/head" ]; then
      echo "broken: ledger empty but head record present"
      return 3
    fi
    printf '0\t%s\n' "$GENESIS"
    return 0
  fi
  out=$(perl -MDigest::SHA=sha256_hex -e '
    my ($g, $file) = @ARGV; my $prev = $g; my $before = $g; my $n = 0;
    open(my $fh, "<", $file) or do { print "broken: unreadable\n"; exit 3 };
    while (my $l = <$fh>) {
      $n++;
      unless ($l =~ s/\n\z//) { print "broken: line $n is not terminated\n"; exit 3 }
      my @f = split /\t/, $l, -1;
      if (@f != 15) { print "broken: line $n has ", scalar(@f), " fields\n"; exit 3 }
      if ($f[0] ne $n) { print "broken: line $n has seq $f[0]\n"; exit 3 }
      if ($f[13] ne $prev) { print "broken: line $n prev_hash does not chain\n"; exit 3 }
      my $body = join("\t", @f[0..13]);
      if (sha256_hex($body) ne $f[14]) { print "broken: line $n hash does not recompute\n"; exit 3 }
      $before = $prev; $prev = $f[14];
    }
    print "$n\t$prev\t$before\n";
  ' "$GENESIS" "$LEDGER") || { printf '%s\n' "$out"; return 3; }
  before=${out##*$'\t'} out=${out%$'\t'*}
  if [ -e "$HL/head" ]; then
    last=$(cat "$HL/head" 2>/dev/null) || last=
  else
    last="0	$GENESIS"
  fi
  if [ "$last" != "$out" ] && [ "$last" != "$(( ${out%%$'\t'*} - 1 ))	$before" ]; then
    echo "broken: head record does not match the last row"
    return 3
  fi
  printf '%s\n' "$out"
}

cmd_verify() {
  local out
  out=$(fhl_chain_walk) || { printf '%s\n' "$out"; return 3; }
  if [ "${out%%$'\t'*}" = 0 ]; then echo "ledger: empty"; else echo "ledger: intact rows=${out%%$'\t'*}"; fi
}

# --- small readers ----------------------------------------------------------

fhl_load() {
  case "${FM_HUNG_LADDER_LOAD:-}" in
    ?*) printf '%s' "$FM_HUNG_LADDER_LOAD"; return 0 ;;
  esac
  if [ -r /proc/loadavg ]; then
    awk '{print $1}' /proc/loadavg
  else
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'
  fi
}

fhl_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

fhl_date_field() {  # <epoch> <format>
  date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null
}

# The most recent 22:00 local time at or before <now>.
fhl_night_start() {  # <now>
  local now=$1 hms h m s secs
  hms=$(fhl_date_field "$now" '+%H %M %S') || { printf '%s' $((now - 86400)); return 0; }
  read -r h m s <<< "$hms"
  secs=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
  if [ "$secs" -ge 79200 ]; then
    printf '%s' $(( now - (secs - 79200) ))
  else
    printf '%s' $(( now - secs - 7200 ))
  fi
}

fhl_normalize_pane() {  # stdin -> normalized text
  perl -CSD -pe '
    s/\e\[[0-9;?]*[ -\/]*[@-~]//g;
    s/\e\][^\a]*\a//g;
    s/[\x{2800}-\x{28FF}\x{2722}-\x{273D}\x{00B7}\x{2022}\x{23FA}\x{25CF}\x{25D0}-\x{25D3}\x{2581}-\x{2588}]//g;
    # Counters such as elapsed time churn on a hung turn, so digits
    # normalize away; token progress is native progress (4.2) and stays.
    s/((?:[\x{2191}\x{2193}]\s*)[0-9][0-9.,]*\s*[kKmM]?|[0-9][0-9.,]*\s*[kKmM]?\s*tok(?:en)?s?\b)|[0-9]+/defined $1 ? $1 : "0"/ge;
    s/[ \t\r]+$//;
  ' 2>/dev/null
}

fhl_redact() {  # stdin -> pane text with known token patterns removed
  perl -pe '
    s/sk-[A-Za-z0-9_-]{16,}/sk-[REDACTED]/g;
    s/gh[pousr]_[A-Za-z0-9]{20,}/gh_[REDACTED]/g;
    s/github_pat_[A-Za-z0-9_]{20,}/github_pat_[REDACTED]/g;
    s/xox[abprs]-[A-Za-z0-9-]{10,}/xox-[REDACTED]/g;
    s/AKIA[0-9A-Z]{16}/AKIA[REDACTED]/g;
    s/(Bearer\s+)[A-Za-z0-9._~+\/=-]{16,}/$1\[REDACTED]/gi;
    if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/ .. /-----END [A-Z ]*PRIVATE KEY-----/) { $_ = "[REDACTED PRIVATE KEY LINE]\n" }
  ' 2>/dev/null
}

# A pager or a y/N prompt on the last non-blank row: a screen block that is
# not one of the composer library's recorded dialogs.
fhl_pane_screen_block() {  # stdin -> name or nothing
  perl -CSD -ne '
    s/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/[ \t\r]+$//;
    $last = $_ if /\S/;
    END {
      exit 1 unless defined $last;
      chomp $last;
      if ($last =~ /^\s*(\(END\)|--More--.*|:|lines \d+-\d+.*)$/) { print "pager"; exit 0 }
      if ($last =~ /(\[y\/N\]|\[Y\/n\]|\(y\/n\))\s*\??\s*$/i) { print "yes-no prompt"; exit 0 }
      exit 1;
    }' 2>/dev/null
}

fhl_secret_path() {  # <path>
  case "${1##*/}" in
    .env|.env.*|*.env|*.pem|*.key|*.p12|*.pfx|id_rsa*|id_ed25519*|id_ecdsa*|.netrc|.npmrc|.pypirc) return 0 ;;
  esac
  # A secret or credential word anywhere in the path, directories included.
  case "$1" in
    *secret*|*Secret*|*SECRET*|*credential*|*Credential*|*CREDENTIAL*) return 0 ;;
  esac
  return 1
}

# Agent liveness and root process. Prints "<state> <pid|->".
fhl_agent_probe() {  # <task> <backend> <target>
  local task=$1 backend=$2 target=$3 state pid
  if [ -n "${FM_HUNG_LADDER_PROBE:-}" ]; then
    "$FM_HUNG_LADDER_PROBE" agent "$task" "$backend" "$target" 2>/dev/null || printf 'unreadable -'
    return 0
  fi
  case "$backend" in
    orca)
      fm_backend_source orca 2>/dev/null || { printf 'unreadable -'; return 0; }
      fm_backend_orca_agent_probe "$target"
      ;;
    tmux)
      state=$(fm_backend_agent_state tmux "$target")
      pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || pid=-
      case "$pid" in ''|*[!0-9]*) pid=- ;; esac
      printf '%s %s' "$state" "$pid"
      ;;
    *)
      printf '%s -' "$(fm_backend_agent_state "$backend" "$target")"
      ;;
  esac
}

# Orca keeps typed text on the prompt row in a separate draft field. The
# adapter is loaded in this shell, because the other probes load it inside
# command substitutions. Only a clear "no draft" answer counts as none; a
# failed load or read counts as a draft, so it blocks rather than escalates.
fhl_draft_present() {  # <task> <target>
  local rc=0 answer
  # A probe that gives no draft answer leaves the read to the adapter.
  if [ -n "${FM_HUNG_LADDER_PROBE:-}" ]; then
    answer=$("$FM_HUNG_LADDER_PROBE" draft "$1" orca "$2" 2>/dev/null)
    if [ -n "$answer" ]; then
      [ "$answer" != none ]
      return
    fi
  fi
  fm_backend_source orca 2>/dev/null || return 0
  fm_backend_orca_draft_present "$2" 2>/dev/null || rc=$?
  [ "$rc" != 1 ]
}

fhl_composer_probe() {  # <task> <backend> <target>
  if [ -n "${FM_HUNG_LADDER_PROBE:-}" ]; then
    "$FM_HUNG_LADDER_PROBE" composer "$1" "$2" "$3" 2>/dev/null || printf 'unknown'
    return 0
  fi
  fm_backend_composer_state "$2" "$3" "fm-$1" 2>/dev/null || printf 'unknown'
}

# The process tree under <root>: "<pid> <cpu-seconds> <comm>" per line.
fhl_tree() {  # <root-pid>
  local root=$1 table
  table=$(LC_ALL=C ps -A -o pid=,ppid=,time=,comm= 2>/dev/null) || return 1
  printf '%s\n' "$table" | awk -v root="$root" '
    function secs(t,   d, a, n, i, s, x) {
      d = 0
      if (index(t, "-")) { split(t, x, "-"); d = x[1]; t = x[2] }
      n = split(t, a, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + a[i]
      return d * 86400 + s
    }
    {
      pid = $1; ppid = $2; t = $3
      if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/) next
      line = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]?/, "", line)
      comm[pid] = line; cpu[pid] = secs(t); kids[ppid] = kids[ppid] " " pid
    }
    END {
      if (!(root in comm)) exit 1
      q[1] = root; h = 1; tl = 1; seen[root] = 1
      while (h <= tl) {
        p = q[h++]
        printf "%s %.2f %s\n", p, cpu[p], comm[p]
        n = split(kids[p], l, " ")
        for (i = 1; i <= n; i++) if (l[i] != "" && !(l[i] in seen)) { seen[l[i]] = 1; q[++tl] = l[i] }
      }
    }'
}

# Bytes read and written by <pid> so far, from /proc where it exists.
fhl_child_io() {  # <pid>
  [ -r "/proc/$1/io" ] || return 1
  awk '$1 == "rchar:" || $1 == "wchar:" { s += $2; n++ } END { if (!n) exit 1; printf "%.0f\n", s }' "/proc/$1/io" 2>/dev/null
}

# The worktree write probe: 0 a file changed since <anchor>, 1 none did, 2 the
# walk failed or timed out, which reads as unknown rather than quiet.
fhl_written_since() {  # <worktree> <anchor>
  local wt=$1 anchor=$2 hit rc=0 name bound
  local -a names=() prune=()
  read -r -a names <<< "${FM_WORKTREE_WRITE_PRUNE:-}"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=${FM_WORKTREE_WRITE_TIMEOUT:-10}
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "${FM_WORKTREE_WRITE_MAXDEPTH:-6}" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null) || rc=$?
  else
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "${FM_WORKTREE_WRITE_MAXDEPTH:-6}" \
      -type f -newer "$anchor" -print -quit 2>/dev/null) || rc=$?
  fi
  [ -z "$hit" ] || return 0
  [ "$rc" = 0 ] || return 2
  return 1
}

fhl_pid_live() {  # <pid>
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$(LC_ALL=C ps -p "$1" -o pid= 2>/dev/null)" ]
}

# The wait resolver (gate item 5). Sets WAIT (none|live|dead|unverified|
# expired) and WAIT_NOTE.
fhl_resolve_wait() {  # <task> <wait-line>
  local task=$1 line=$2 until at pid ticket queue_out max queue=0
  WAIT=none WAIT_NOTE=
  [ -n "$line" ] || return 0
  status_is_paused "$line" || return 0
  WAIT_NOTE=$(printf '%s' "$line" | cut -c1-160)
  # A passed deadline ends the wait. A future one is the worker's own word,
  # so it still needs a named live job, or it buys only the bounded hold.
  if until=$(status_paused_until "$line" 2>/dev/null) && [ -n "$until" ] && [ "$until" -le "$NOW" ]; then
    WAIT=dead WAIT_NOTE="until-passed: $WAIT_NOTE"
    return 0
  fi
  pid=$(printf '%s' "$line" | sed -nE 's/.*(^|[^A-Za-z0-9_])pid[=: ]+([0-9]+).*/\2/p' | head -n 1)
  if [ -n "$pid" ]; then
    if ! fhl_pid_live "$pid"; then WAIT=dead WAIT_NOTE="pid-gone: $WAIT_NOTE"; return 0; fi
    # Only a process this user runs can be the worker's own job; any other
    # live pid (pid 1, another user's daemon) buys only the bounded hold.
    if [ "$(LC_ALL=C ps -p "$pid" -o uid= 2>/dev/null | tr -d ' ')" = "$(id -u)" ]; then
      WAIT=live
      return 0
    fi
    WAIT_NOTE="pid-not-own: $WAIT_NOTE"
  fi
  ticket=$(printf '%s' "$line" | sed -nE 's/.*ticket[=: #]+([0-9]+).*/\1/p' | head -n 1)
  # Only the queue's own name, or a queue wait that names its ticket, is
  # checked against the queue; other wording is an ordinary bounded wait.
  case "$line" in
    *fm-test-queue*) queue=1 ;;
    *test-queue*|*test\ queue*) [ -z "$ticket" ] || queue=1 ;;
  esac
  case "$queue" in
    1)
      if ! queue_out=$(fm_run_timed 10 "${FM_TEST_QUEUE_BIN:-$SCRIPT_DIR/fm-test-queue.sh}" status 2>/dev/null); then
        WAIT=unknown WAIT_NOTE="test-queue-unreadable: $WAIT_NOTE"
        return 0
      fi
      if printf '%s\n' "$queue_out" | awk -v t="task=$task" -v k="ticket=$ticket" '
          ($1 == "serving" || $1 == "waiting") {
            ok = 0; tk = (k == "ticket="); p = ""
            for (i = 2; i <= NF; i++) { if ($i == t) ok = 1; if ($i == k) tk = 1; if ($i ~ /^pid=/) p = substr($i, 5) }
            if (ok && tk) { print p; found = 1; exit }
          }
          END { exit !found }' > "$HL/.wait.$$"; then
        pid=$(cat "$HL/.wait.$$")
        rm -f "$HL/.wait.$$"
        if [ -z "$pid" ] || fhl_pid_live "$pid"; then WAIT=live; return 0; fi
      fi
      rm -f "$HL/.wait.$$"
      WAIT=dead WAIT_NOTE="test-queue-ticket-gone: $WAIT_NOTE"
      return 0
      ;;
  esac
  # A wait the resolver cannot parse protects, but only for a bounded time
  # (14.2 S3). The clock is the earlier of the line's own stamp and when the
  # ladder first saw an unverified wait, so re-stamping, repeating, or leaving
  # out the stamp buys nothing; only real work (a commit, a content change, a
  # write, a handled message) restarts it.
  max=$(fhl_num "$(fhl_kv "$CONFIG/hung-ladder" unverified_wait_max_secs 2>/dev/null)" 7200)
  at=$(status_line_at_epoch "$line" 2>/dev/null) || at=
  [ -n "${EP_wait_since:-}" ] || EP_wait_since=$NOW
  case "$at" in ''|*[!0-9]*) at=$EP_wait_since ;; esac
  [ "$at" -le "$EP_wait_since" ] || at=$EP_wait_since
  if [ $((NOW - at)) -ge "$max" ]; then
    WAIT=expired WAIT_NOTE="unverified-wait-cap: $WAIT_NOTE"
  else
    WAIT=unverified
  fi
}

# Validation in flight (gate item 6): any no-mistakes run the crew state
# attributes to the task that is working (running, fixing, CI) or parked at a
# gate. Read only when a rung could fire, under a short bound, with the
# crew-state snapshot cache off so the read takes no lock another reader can
# hold; a read that fails or times out holds.
fhl_validating() {
  local line rc=0 state src
  line=$(FM_CREW_STATE_NO_SNAPSHOT=1 fm_run_timed 5 "$FM_CREW_STATE_BIN" "$TASK" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    held=${held:-unknown:validation=$rc}
    return 1
  fi
  case "$line" in state:*) ;; *) held=${held:-unknown:validation=unreadable}; return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = unknown ]; then
    held=${held:-unknown:validation=state-unknown}
    return 1
  fi
  case "$line" in *" source: "*) src=${line#* source: }; src=${src%% *} ;; *) src= ;; esac
  [ "$src" = run-step ] || return 1
  case "$state" in working|parked) return 0 ;; esac
  return 1
}

# --- tick --------------------------------------------------------------------

# Episode and sample records are flat key=value files read into EP_* and
# S_* variables.
fhl_read_kv_file() {  # <file> <prefix>
  local f=$1 p=$2 k v
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    printf -v "${p}${k}" '%s' "$v"
  done < "$f"
}

fhl_write_episode() {
  local f="$HL/episodes/$TASK.ep"
  EP_seen_at=$NOW
  {
    printf 'seen_at=%s\n' "${EP_seen_at:-}"
    printf 'state=%s\n' "${EP_state:-}"
    printf 'since=%s\n' "${EP_since:-}"
    printf 't0=%s\n' "${EP_t0:-}"
    printf 'episode=%s\n' "${EP_episode:-}"
    printf 'opened=%s\n' "${EP_opened:-}"
    printf 'actions=%s\n' "${EP_actions:-}"
    printf 'rung1_at=%s\n' "${EP_rung1_at:-}"
    printf 'rung2_at=%s\n' "${EP_rung2_at:-}"
    printf 'rung3_at=%s\n' "${EP_rung3_at:-}"
    printf 'rung4_at=%s\n' "${EP_rung4_at:-}"
    printf 'rung5_at=%s\n' "${EP_rung5_at:-}"
    printf 'hold=%s\n' "${EP_hold:-}"
    printf 'held_alarm_at=%s\n' "${EP_held_alarm_at:-}"
    printf 'block_since=%s\n' "${EP_block_since:-}"
    printf 'block_parked=%s\n' "${EP_block_parked:-}"
    printf 'unknown_streak=%s\n' "${EP_unknown_streak:-}"
    printf 'degraded=%s\n' "${EP_degraded:-}"
    printf 'drip=%s\n' "${EP_drip:-}"
    printf 'drip_alarm=%s\n' "${EP_drip_alarm:-}"
    printf 'last_close=%s\n' "${EP_last_close:-}"
    printf 'wait_since=%s\n' "${EP_wait_since:-}"
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# An episode ends; the counters that span episodes stay.
fhl_clear_episode() {
  EP_state=idle EP_since='' EP_t0='' EP_episode='' EP_opened='' EP_actions=''
  EP_rung1_at='' EP_rung2_at='' EP_rung3_at='' EP_rung4_at='' EP_rung5_at=''
  EP_hold='' EP_held_alarm_at=''
}

fhl_close_episode() {  # <yes|no> <cause>
  local lsp=$1 cause=$2 id
  for id in ${EP_actions:-}; do
    fhl_row "$TASK" - resolve "close:$cause" "$id" "$lsp" || true
  done
  fhl_clear_episode
  EP_last_close=$NOW
}

fhl_act() {  # <rung> <reason> -> appends the would-act row and records its id
  fhl_row "$TASK" "$1" would-act "$2" "${3:--}" pending || return 1
  EP_actions="${EP_actions:+$EP_actions }$ROW_ID"
}

fhl_snapshot_pane() {  # <name> -> path:sha
  local dir="$HL/snapshots/$TASK" f
  mkdir -p "$dir" && chmod 700 "$dir"
  f="$dir/$1.pane"
  printf '%s\n' "$PANE" | tail -n 100 | fhl_redact > "$f"
  chmod 600 "$f"
  printf '%s:%s' "snapshots/$TASK/$1.pane" "$(fhl_sha < "$f")"
}

# Fills FHL_EXCL with a literal exclude pathspec for every secret-pattern
# path in the `git status --porcelain=v1 -z` records on stdin, rename sources
# included, so no secret file's content reaches a diff this script hashes.
fhl_secret_excludes() {
  local rec p rename=0
  FHL_EXCL=()
  while IFS= read -r -d '' rec; do
    if [ "$rename" = 1 ]; then
      p=$rec rename=0
    else
      case "$rec" in R*|C*|?R*|?C*) rename=1 ;; esac
      p=${rec:3}
    fi
    [ -n "$p" ] || continue
    fhl_secret_path "$p" && FHL_EXCL+=( ":(exclude,literal)$p" )
  done
  return 0
}

# One digest over the untracked, non-ignored files named NUL-separated on
# stdin: each name with its size and mtime, plus the first MiB of content
# while a 64 MiB budget lasts. Secret-pattern names are skipped entirely.
fhl_untracked_digest() {  # <worktree>
  local p
  # shellcheck disable=SC2016 # the Perl program is single-quoted on purpose
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    fhl_secret_path "$p" || printf '%s\0' "$p"
  done | fm_run_timed 10 perl -MDigest::SHA -0 -e '
    my $root = shift; my $d = Digest::SHA->new(256); my ($n, $budget) = (0, 64 << 20);
    while (my $p = <STDIN>) {
      chomp $p;
      if (++$n > 2000) { $d->add("truncated\0"); last }
      my @s = lstat("$root/$p");
      $d->add($p, "\0", @s ? "$s[7]:$s[9]" : "gone", "\0");
      next unless @s && -f _ && $budget > 0;
      if (open(my $f, "<", "$root/$p")) {
        my $got = read($f, my $buf, $budget < 1048576 ? $budget : 1048576);
        $budget -= $got if $got;
        $d->add(defined $got ? $buf : "unreadable", "\0");
      } else {
        $d->add("unreadable\0");
      }
    }
    print $d->hexdigest, "\n";' "$1"
}

# Rung 4's content snapshot (5.2 h, 14.2 S4): head, staged and unstaged
# patches without ignored or secret-pattern files, a hash per dirty and
# untracked file, the link text of each symlink (never followed), and
# presence only for secret-pattern and ignored files.
fhl_snapshot_tree() {  # <name> -> path:sha
  local dir="$HL/snapshots/$TASK" f p sz
  f="$dir/$1.tree"
  mkdir -p "$dir" && chmod 700 "$dir"
  [ -n "$WT" ] && [ -d "$WT" ] || { printf 'none'; return 0; }
  fhl_secret_excludes < <(fm_run_timed 10 git -C "$WT" --no-optional-locks status --porcelain=v1 -z -uall 2>/dev/null)
  {
    printf 'head\t%s\n' "$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
    fm_run_timed 10 git -C "$WT" --no-optional-locks diff --binary -- . ${FHL_EXCL[@]+"${FHL_EXCL[@]}"} 2>/dev/null | head -c 20000000 > "$f.diff"
    fm_run_timed 10 git -C "$WT" --no-optional-locks diff --cached --binary -- . ${FHL_EXCL[@]+"${FHL_EXCL[@]}"} 2>/dev/null | head -c 20000000 > "$f.cached.diff"
    printf 'diff_sha256\t%s\n' "$(fhl_sha < "$f.diff")"
    printf 'cached_diff_sha256\t%s\n' "$(fhl_sha < "$f.cached.diff")"
    { fm_run_timed 10 git -C "$WT" --no-optional-locks diff --name-only -z HEAD 2>/dev/null; fm_run_timed 10 git -C "$WT" ls-files -z --others --exclude-standard 2>/dev/null; } | perl -0 -ne 'next if $seen{$_}++; print if ++$n <= 2000' |
      while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        if fhl_secret_path "$p"; then
          printf 'present-secret\t%s\n' "$(fhl_esc "$p")"
        elif [ -L "$WT/$p" ]; then
          # A link is recorded by its own text and never followed, so it
          # cannot pull a secret's content into the snapshot.
          printf 'symlink\t%s\t%s\n' "$(readlink "$WT/$p" | fhl_sha)" "$(fhl_esc "$p")"
        elif [ -f "$WT/$p" ]; then
          sz=$(wc -c < "$WT/$p" 2>/dev/null | tr -d ' ')
          if [ "${sz:-0}" -le 50000000 ]; then
            printf 'file\t%s\t%s\n' "$(fhl_sha < "$WT/$p")" "$(fhl_esc "$p")"
          else
            printf 'file-oversize\t%s\t%s\n' "$sz" "$(fhl_esc "$p")"
          fi
        else
          printf 'deleted\t%s\n' "$(fhl_esc "$p")"
        fi
      done
    fm_run_timed 10 git -C "$WT" ls-files -z --others --ignored --exclude-standard 2>/dev/null |
      perl -0 -ne 'chomp; if (++$n > 2000) { print "present-ignored-truncated\t2000\n"; exit } s/\\/\\\\/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g; s/[[:cntrl:]]/?/g; print "present-ignored\t$_\n"'
  } > "$f"
  chmod 600 "$f" "$f.diff" "$f.cached.diff" 2>/dev/null || true
  printf '%s:%s' "snapshots/$TASK/$1.tree" "$(fhl_sha < "$f")"
}

# Snapshots belong to a task; once its metadata is gone, they go too. Runs at
# most once an hour.
fhl_prune_snapshots() {
  [ "$(fhl_recorded_age "$HL/.pruned")" -ge 3600 ] || return 0
  printf '%s\n' "$NOW" > "$HL/.pruned"
  fhl_prune_now
}

fhl_prune_now() {
  local d t e
  if [ "${EFFECTIVE:-off}" = observe ]; then
    for e in "$HL/episodes"/*.ep; do
      [ -f "$e" ] || continue
      t=${e##*/}; t=${t%.ep}
      [ -e "$STATE/$t.meta" ] || fhl_resolve_gone "$t" || continue
    done
  fi
  for e in "$HL/episodes"/*.ep "$HL/episodes"/*.sample "$HL/episodes"/*.anchor "$HL/episodes"/*.porcelain; do
    [ -e "$e" ] || continue
    t=${e##*/}; t=${t%.*}
    [ -e "$STATE/$t.meta" ] || [ -e "$HL/episodes/$t.ep" ] || rm -f "$e"
  done
  for d in "$HL/snapshots"/*/; do
    [ -d "$d" ] || continue
    t=${d%/}; t=${t##*/}
    [ -e "$STATE/$t.meta" ] || rm -rf "${d%/}"
  done
}

# A task cleaned up with an episode still open never gets another tick, so
# its pending rows are resolved here. It progressed when its last status line
# says done, or is a line the last sample had not seen; otherwise no. The
# episode record goes only after every row is written.
fhl_resolve_gone() {  # <task>
  local t=$1 id lsp=no cause=task-gone:no-new-status last='' body='' v=''
  G_actions='' G_bodies='' G_status_body=''
  fhl_read_kv_file "$HL/episodes/$t.ep" G_
  fhl_read_kv_file "$HL/episodes/$t.sample" G_
  if [ -n "$G_actions" ] && [ -f "$STATE/$t.status" ]; then
    last=$(last_status_line "$STATE/$t.status")
    status_line_verb "$last" v
    body=$(fhl_status_body "$last" | fhl_sha)
    if [ "$v" = "done" ]; then
      lsp=yes cause=task-gone:done
    elif [ -n "$last" ] && [ "$body" != "$G_status_body" ]; then
      case "_${G_bodies}_" in
        *"_${body:0:16}_"*) ;;
        *) lsp=yes cause=task-gone:new-status ;;
      esac
    fi
  fi
  for id in $G_actions; do
    fhl_row "$t" - resolve "close:$cause" "$id" "$lsp" || return 1
  done
  rm -f "$HL/episodes/$t.ep" "$HL/episodes/$t.sample" "$HL/episodes/$t.anchor" "$HL/episodes/$t.porcelain"
}

# Seconds since the epoch recorded inside <file> (its first line), 999999
# when absent. Recorded epochs, not mtimes, so every age uses the ladder clock.
fhl_recorded_age() {  # <file> [<key>]: the epoch on line 1, or in <key>=
  local m
  if [ -n "${2:-}" ]; then
    m=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)
  else
    m=$(head -n 1 "$1" 2>/dev/null) || { echo 999999; return; }
  fi
  case "$m" in ''|*[!0-9]*) echo 999999; return ;; esac
  [ "$m" -le "$NOW" ] || { echo 0; return; }
  echo $((NOW - m))
}

fhl_caps() {  # sets CAPS and CAP_HIT
  local counts th tn hh hn attempts=0 ns
  ns=$(fhl_night_start "$NOW")
  counts=$(awk -F'\t' -v task="$TASK" -v hs=$((NOW - 3600)) -v ns="$ns" '
    $6 == "would-act" && $5 == "4" {
      if ($2 >= hs) { hh++; if ($4 == task) th++ }
      if ($2 >= ns) { hn++; if ($4 == task) tn++ }
    }
    END { print th + 0, tn + 0, hh + 0, hn + 0 }' "$LEDGER" 2>/dev/null) || counts="0 0 0 0"
  read -r th tn hh hn <<< "$counts"
  if [ -f "$STATE/.crew-relaunch-$TASK" ]; then
    attempts=$(awk -F'\t' -v hs=$((NOW - 3600)) '$2 == "attempt" && $1 >= hs { n++ } END { print n + 0 }' "$STATE/.crew-relaunch-$TASK" 2>/dev/null) || attempts=0
  fi
  CAPS="task_hour=$th/1;shared_hour=$((th + attempts))/2;task_night=$tn/2;home_hour=$hh/2;home_night=$hn/6"
  CAP_HIT=
  [ "$th" -lt 1 ] || CAP_HIT='task-hour'
  [ -n "$CAP_HIT" ] || [ $((th + attempts)) -lt 2 ] || CAP_HIT='shared-hour'
  [ -n "$CAP_HIT" ] || [ "$tn" -lt 2 ] || CAP_HIT='task-night'
  [ -n "$CAP_HIT" ] || [ "$hh" -lt 2 ] || CAP_HIT='home-hour'
  [ -n "$CAP_HIT" ] || [ "$hn" -lt 6 ] || CAP_HIT='home-night'
}

# The systemic breaker (5.3): max(3, ceil(N/4)) open episodes inside 10
# minutes, N live workers, or host load above the ceiling.
fhl_breaker() {  # sets BREAKER and TRIPPED
  local live=0 open=0 f threshold was
  for f in "$HL/seen"/*; do
    [ -f "$f" ] || continue
    [ "$(fhl_recorded_age "$f")" -lt 600 ] && live=$((live + 1))
  done
  for f in "$HL/episodes"/*.ep; do
    [ -f "$f" ] || continue
    [ "$f" != "$HL/episodes/$TASK.ep" ] || continue
    [ "$(fhl_recorded_age "$f" seen_at)" -lt 600 ] || continue
    grep -qx 'state=open' "$f" && open=$((open + 1))
  done
  [ "$EP_state" != open ] || open=$((open + 1))
  threshold=$(( (live + 3) / 4 ))
  [ "$threshold" -ge 3 ] || threshold=3
  TRIPPED=0
  [ "$open" -lt "$threshold" ] || TRIPPED=1
  [ "$LOAD_HIGH" = 0 ] || TRIPPED=1
  BREAKER="open=$open;live=$live;threshold=$threshold;load=$LOAD;ceiling=$CEILING;tripped=$TRIPPED"
  was=$(cat "$HL/breaker" 2>/dev/null || echo 0)
  if [ "$TRIPPED" = 1 ] && [ "$was" != 1 ]; then
    fhl_row - - alarm "systemic-breaker open=$open threshold=$threshold load=$LOAD ceiling=$CEILING" || true
  fi
  [ "$was" = "$TRIPPED" ] || printf '%s\n' "$TRIPPED" > "$HL/breaker"
}

fhl_status_body() {  # <line> -> the line without [at=...] / [until=...] markers
  printf '%s' "$1" | sed -E 's/ ?\[(at|until)=[^]]*\]//g'
}

cmd_tick() {
  local busy=- dialog='' meta backend target live pid probe
  TASK='' KIND=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) TASK=${2-}; shift ;;
      --kind) KIND=${2-}; shift ;;
      --busy) busy=${2-}; shift ;;
      --dialog) dialog=${2-}; shift ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$TASK" in ''|*[!A-Za-z0-9._-]*) echo "fm-hung-ladder: tick needs a slug --task" >&2; exit 2 ;; esac
  case "$busy" in 0|1|-) ;; *) echo "fm-hung-ladder: --busy takes 0 or 1" >&2; exit 2 ;; esac
  fhl_refuse_worker
  PANE=$(cat)
  NOW=$(fhl_now)
  fhl_resolve_mode
  case "$MODE_REASON" in
    refused:*)
      # A live mode without the gate changes nothing, not even the ledger.
      printf 'fm-hung-ladder: mode %s refused (%s); running as off\n' "$CFG_MODE" "${MODE_REASON#refused:}" >&2
      exit 0
      ;;
  esac
  [ -d "$HL" ] || [ "$EFFECTIVE" != off ] || exit 0
  fhl_setup_dirs || exit 0
  mkdir "$HL/.lock" 2>/dev/null || {
    # Never wait on the poll path: a held lock skips this sample, and a lock
    # older than five minutes is a crashed tick's.
    local lock_m
    lock_m=$(fhl_mtime "$HL/.lock") || exit 0
    case "$lock_m" in ''|*[!0-9]*) exit 0 ;; esac
    [ $(( $(date +%s) - lock_m )) -ge 300 ] || exit 0
    rmdir "$HL/.lock" 2>/dev/null; mkdir "$HL/.lock" 2>/dev/null || exit 0
  }
  trap 'rmdir "$HL/.lock" 2>/dev/null' EXIT
  LEDGER_BROKEN=0
  SIGNALS=- CAPS=- BREAKER=-
  # Any change to the configured mode, the effective mode, or the actor is a
  # ledger row, so an approved raise that still runs as observe is recorded.
  local last_mode mode_key
  mode_key="$CFG_MODE $EFFECTIVE $MODE_ACTOR"
  last_mode=$(cat "$HL/mode.last" 2>/dev/null) || last_mode='off off -'
  if [ "$last_mode" != "$mode_key" ]; then
    last_mode=${last_mode#* }
    fhl_row - - mode "from=${last_mode%% *} to=$EFFECTIVE configured=$CFG_MODE actor=$MODE_ACTOR why=$MODE_REASON" \
      && printf '%s\n' "$mode_key" > "$HL/mode.last"
  fi
  [ "$EFFECTIVE" = observe ] || exit 0
  fhl_prune_snapshots

  case "$KIND" in ship|scout) ;; *) exit 0 ;; esac
  meta="$STATE/$TASK.meta"
  [ -f "$meta" ] || exit 0
  if fhl_owner_file "$CONFIG/hung-ladder-skip" 022 && grep -qxF "$TASK" "$CONFIG/hung-ladder-skip"; then exit 0; fi

  local k
  fhl_clear_episode
  EP_seen_at='' EP_block_since='' EP_block_parked='' EP_unknown_streak='' EP_degraded=''
  EP_drip='' EP_drip_alarm='' EP_last_close='' EP_wait_since=''
  fhl_read_kv_file "$HL/episodes/$TASK.ep" EP_
  [ -n "$EP_state" ] || EP_state=idle
  fhl_read_kv_file "$HL/episodes/$TASK.sample" S_

  backend=$(fhl_kv "$meta" backend) || backend=tmux
  [ -n "$backend" ] || backend=tmux
  if [ "$backend" = orca ] || [ "$backend" = t3code ]; then
    target=$(fhl_kv "$meta" terminal) || target=$(fhl_kv "$meta" t3_thread_id) || target=
  else
    target=$(fhl_kv "$meta" window) || target=
  fi
  WT=$(fhl_kv "$meta" worktree) || WT=

  # --- gate items 1-4 ---
  probe=$(fhl_agent_probe "$TASK" "$backend" "$target")
  live=${probe%% *}
  pid=${probe#* }
  [ "$pid" != "$probe" ] || pid=-
  [ "$live" != alive ] || printf '%s\n' "$NOW" > "$HL/seen/$TASK"

  local status_file="$STATE/$TASK.status" last_line='' verb='' status_size=0 status_body='' wait_line
  if [ -f "$status_file" ]; then
    last_line=$(last_status_line "$status_file")
    status_size=$(wc -c < "$status_file" | tr -d ' ')
    status_body=$(fhl_status_body "$last_line" | fhl_sha)
    status_line_verb "$last_line" verb
  fi
  wait_line=$(status_declared_wait_line "$status_file" 2>/dev/null) || wait_line=
  fhl_resolve_wait "$TASK" "$wait_line"

  local gate='' held=''
  case "$live" in
    alive) ;;
    dead|missing) gate="not-live:$live" ;;
    *) held="unknown:liveness=$live" ;;
  esac
  case "$verb" in
    done|failed) gate=${gate:-finished:$verb} ;;
  esac
  if [ -z "$gate" ]; then
    if status_is_captain_held "$last_line"; then
      gate='owner-hold'
    elif [ -n "$(status_open_decisions "$status_file")" ]; then
      gate='open-decision'
    else
      # 0 an open captain call, 1 none; anything else cannot tell, and an
      # unknown read holds the episode rather than counting as no hold.
      local hold_rc=0
      FM_HOME="$FM_HOME" fm_run_timed 10 "$SCRIPT_DIR/fm-captain-hold.sh" open "$TASK" >/dev/null 2>&1 || hold_rc=$?
      case "$hold_rc" in
        0) gate='owner-hold' ;;
        1) ;;
        *) held=${held:-unknown:captain-hold=$hold_rc} ;;
      esac
    fi
  fi
  # --- gate items 5-6 ---
  if [ -z "$gate" ]; then
    case "$WAIT" in
      live|unverified) gate="verified-wait:$WAIT" ;;
      unknown) held=${held:-unknown:wait=unreadable} ;;
    esac
  fi
  # --- gate item 7 ---
  local screen=''
  [ -z "$dialog" ] || screen="dialog:$dialog"
  [ -n "$screen" ] || { k=$(printf '%s\n' "$PANE" | fhl_pane_screen_block) && screen="$k"; }
  local composer=-
  if [ -z "$gate" ] && [ -z "$screen" ] && [ "$live" = alive ]; then
    composer=$(fhl_composer_probe "$TASK" "$backend" "$target")
    case "$composer" in
      pending|pending-unproven) screen="composer:$composer" ;;
      empty) ;;
      *) composer=unknown ;;
    esac
    if [ -z "$screen" ] && [ "$backend" = orca ] && fhl_draft_present "$TASK" "$target"; then
      screen="composer:draft"
    fi
  fi

  # --- quiet proof sensors ---
  local first=0
  [ -f "$HL/episodes/$TASK.sample" ] || first=1
  local pane_hash rendered=unknown fs=unknown kernel=unsupported records=unsupported
  pane_hash=$(printf '%s\n' "$PANE" | fhl_normalize_pane | fhl_sha)
  if [ "$first" = 0 ]; then
    if [ "$pane_hash" = "${S_pane:-}" ]; then rendered=quiet; else rendered=active; fi
  fi

  local head='-' dirty='-' inbox=0 wrote=0 fs_unknown=0 net_advance='' drip_seen=0 status_changed=0
  if [ -d "$STATE/$TASK.inbox/handled" ]; then
    inbox=$(find "$STATE/$TASK.inbox/handled" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "$KIND" = ship ] && [ -n "$WT" ] && [ -d "$WT" ]; then
    head=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || { head=-; fs_unknown=1; }
    # The content hash covers the status records, the diff against HEAD
    # without secret-pattern files, and the untracked files' content. A read
    # that fails, times out, or outgrows its bound reads as unknown.
    local porc="$HL/episodes/$TASK.porcelain" diffhash untracked
    fm_run_timed 10 git -C "$WT" --no-optional-locks status --porcelain=v1 -z -uall > "$porc" 2>/dev/null || fs_unknown=1
    fhl_secret_excludes < "$porc"
    diffhash=$(set -o pipefail; fm_run_timed 10 git -C "$WT" --no-optional-locks diff HEAD --binary -- . ${FHL_EXCL[@]+"${FHL_EXCL[@]}"} 2>/dev/null | head -c 20000000 | fhl_sha) || fs_unknown=1
    untracked=$(set -o pipefail; fm_run_timed 10 git -C "$WT" --no-optional-locks ls-files -z --others --exclude-standard 2>/dev/null | fhl_untracked_digest "$WT") || fs_unknown=1
    dirty=$(printf '%s\n%s\n%s' "$(fhl_sha < "$porc")" "$diffhash" "$untracked" | fhl_sha)
    rm -f "$porc"
    if [ -f "$HL/episodes/$TASK.anchor" ]; then
      local wrc=0
      fhl_written_since "$WT" "$HL/episodes/$TASK.anchor" || wrc=$?
      case "$wrc" in 0) wrote=1 ;; 1) ;; *) fs_unknown=1 ;; esac
    fi
  elif [ "$KIND" = ship ]; then
    fs_unknown=1
  fi
  local bodies
  bodies=$(printf '%s %s' "${status_body:0:16}" "${S_bodies:-}" | tr '_' ' ' | awk '{ o = ""; n = 0; for (i = 1; i <= NF; i++) if (!s[$i]++ && n < 256) { o = o (n ? "_" : "") $i; n++ } print o }')
  if [ "$first" = 0 ]; then
    if [ "$status_size" != "${S_status_size:-0}" ]; then
      case "_${S_bodies:-}_" in
        *"_${status_body:0:16}_"*) drip_seen=1 ;;
        *)
          if [ "$status_body" = "${S_status_body:-}" ]; then
            drip_seen=1
          else
            status_changed=1
            net_advance=status
          fi
          ;;
      esac
    fi
    [ "$inbox" -le "${S_inbox:-0}" ] || net_advance=${net_advance:-inbox-ack}
    if [ "$fs_unknown" = 0 ]; then
      [ "$head" = "${S_head:--}" ] || net_advance=${net_advance:-head}
      [ "$dirty" = "${S_dirty:--}" ] || net_advance=${net_advance:-dirty-content}
    fi
    if [ "$fs_unknown" = 1 ]; then
      fs=unknown
    elif [ -n "$net_advance" ] || [ "$wrote" = 1 ]; then
      fs=active
    else
      fs=quiet
    fi
  fi

  # kernel: CPU of the agent tree, unknown above the load ceiling.
  LOAD=$(fhl_load) || LOAD=
  [ -n "$LOAD" ] || LOAD=unknown
  CEILING=$(fhl_num "$(fhl_kv "$CONFIG/hung-ladder" load_ceiling 2>/dev/null)" 200)
  LOAD_HIGH=0
  if [ "$LOAD" = unknown ] || fhl_gt "$LOAD" "$CEILING"; then LOAD_HIGH=1; fi
  local tree cpu_total=0 cpu_quiet children=0 stale_children=0 working_children=0 kq=0 kids_out=''
  cpu_quiet=$(fhl_num "$(fhl_kv "$CONFIG/hung-ladder" cpu_quiet_secs 2>/dev/null)" 1)
  if [ "$pid" != - ]; then
    if [ "$LOAD_HIGH" = 1 ]; then
      kernel=unknown
    elif tree=$(fhl_tree "$pid"); then
      local tp tc tcomm prev since cls io fp
      while read -r tp tc tcomm; do
        [ -n "$tp" ] || continue
        cpu_total=$(awk -v a="$cpu_total" -v b="$tc" 'BEGIN { printf "%.2f", a + b }')
        [ "$tp" != "$pid" ] || continue
        cls=$(fm_agent_process_classify_name "$tcomm")
        [ "$cls" = other ] || continue
        children=$((children + 1))
        io=$(fhl_child_io "$tp") || io=-
        fp="$tc/$io"
        eval "prev=\${S_kid_$tp:-}"
        since=$NOW
        if [ -n "$prev" ] && [ "${prev%%:*}" = "$fp" ]; then
          since=${prev#*:}
        fi
        if [ $((NOW - since)) -ge 900 ]; then
          stale_children=$((stale_children + 1))
        else
          working_children=$((working_children + 1))
        fi
        kids_out="${kids_out}kid_$tp=$fp:$since
"
      done <<< "$tree"
      if [ "$first" = 1 ] || [ -z "${S_cpu:-}" ]; then
        kernel=unknown
      elif fhl_gt "$(awk -v a="$cpu_total" -v b="${S_cpu:-0}" 'BEGIN { print a - b }')" "$cpu_quiet" || [ "$working_children" -gt 0 ]; then
        kernel=active
      else
        kq=$(( $(fhl_num "${S_kq:-0}" 0) + 1 ))
        if [ "$kq" -ge 2 ]; then kernel=quiet; else kernel=unknown; fi
      fi
    else
      kernel=unknown
    fi
  fi
  [ "$WAIT" != dead ] || records=quiet

  SIGNALS="rendered=$rendered;fs=$fs;kernel=$kernel;records=$records;transcript=unsupported;loop=unsupported;busy=$busy;live=$live;wait=$WAIT;screen=${screen:-none};composer=$composer;cpu=$cpu_total;children=$children;stale_children=$stale_children;load=$LOAD;backend=$backend"

  # Write the new sample before any decision, so the next pass compares
  # against this one whatever happens below. A failed Git read keeps the last
  # good HEAD and content hash, so the next good read compares against them.
  if [ "$fs_unknown" = 1 ] && [ "$first" = 0 ]; then
    head=${S_head:--} dirty=${S_dirty:--}
  fi
  {
    printf 'pane=%s\nstatus_size=%s\nstatus_body=%s\nbodies=%s\ninbox=%s\nhead=%s\ndirty=%s\ncpu=%s\nkq=%s\n' \
      "$pane_hash" "$status_size" "$status_body" "$bodies" "$inbox" "$head" "$dirty" "$cpu_total" "$kq"
    printf '%s' "$kids_out"
  } > "$HL/episodes/$TASK.sample.tmp" && mv -f "$HL/episodes/$TASK.sample.tmp" "$HL/episodes/$TASK.sample"
  : > "$HL/episodes/$TASK.anchor"

  # Status drips (14.2 S3): an identical status line is not progress, and a
  # third repeat raises an alarm.
  if [ "$drip_seen" = 1 ]; then
    EP_drip=$(( $(fhl_num "${EP_drip:-0}" 0) + 1 ))
    if [ "$EP_drip" -ge 3 ] && [ "${EP_drip_alarm:-0}" != 1 ]; then
      fhl_row "$TASK" - alarm "status-drip repeats=$EP_drip" && EP_drip_alarm=1
    fi
  elif [ "$status_changed" = 1 ]; then
    EP_drip=0 EP_drip_alarm=0
  fi

  # Unknown reads count as activity for the proof, and five in a row raise
  # the degraded-sensor alarm.
  local unknown_kinds='' activity=''
  [ "$rendered" != unknown ] || unknown_kinds="${unknown_kinds}rendered,"
  [ "$fs" != unknown ] || unknown_kinds="${unknown_kinds}fs,"
  [ "$kernel" != unknown ] || unknown_kinds="${unknown_kinds}kernel,"
  [ "$composer" != unknown ] || unknown_kinds="${unknown_kinds}composer,"
  k=${held#unknown:}; [ -z "$held" ] || unknown_kinds="${unknown_kinds}${k%%=*},"
  [ "$rendered" != active ] || activity="${activity}rendered,"
  [ "$fs" != active ] || activity="${activity}fs,"
  [ "$kernel" != active ] || activity="${activity}kernel,"
  if [ "$first" = 0 ] && [ -n "$unknown_kinds" ]; then
    EP_unknown_streak=$(( $(fhl_num "${EP_unknown_streak:-0}" 0) + 1 ))
    if [ "$EP_unknown_streak" -ge 5 ] && [ "${EP_degraded:-0}" != 1 ]; then
      fhl_row "$TASK" - alarm "degraded-sensor unknown=${unknown_kinds%,} passes=$EP_unknown_streak" && EP_degraded=1
    fi
  else
    EP_unknown_streak=0 EP_degraded=0
  fi
  local quiet_count=0
  [ "$rendered" != quiet ] || quiet_count=$((quiet_count + 1))
  [ "$fs" != quiet ] || quiet_count=$((quiet_count + 1))
  [ "$kernel" != quiet ] || quiet_count=$((quiet_count + 1))
  [ "$records" != quiet ] || quiet_count=$((quiet_count + 1))
  local proof=0
  [ -z "$activity" ] && [ -z "$unknown_kinds" ] && [ "$quiet_count" -ge 2 ] && proof=1
  case "$net_advance" in ''|status) [ "$wrote" = 0 ] || EP_wait_since='' ;; *) EP_wait_since='' ;; esac
  if [ -z "$gate" ] && [ "$live" = alive ] && { [ "$proof" = 1 ] || [ -n "$screen" ]; } && fhl_validating; then
    gate=validating
  fi

  fhl_breaker

  # --- the episode clock ---
  local open=0
  case "$EP_state" in open|parked) open=1 ;; esac
  if [ "$open" = 1 ]; then
    if [ -n "$net_advance" ]; then
      fhl_close_episode yes "net-advance:$net_advance"
    elif [ -n "$gate" ]; then
      case "$gate" in
        not-live:*|owner-hold|verified-wait:unverified) fhl_close_episode no "gate:$gate" ;;
        *) fhl_close_episode yes "gate:$gate" ;;
      esac
    elif [ -z "${EP_rung2_at:-}" ] && [ -n "$activity" ]; then
      fhl_close_episode yes "activity:${activity%,}"
    fi
  fi
  case "$EP_state" in open|parked) open=1 ;; *) open=0 ;; esac

  if [ "$open" = 0 ]; then
    # Screen blocks park only after lasting 4 minutes with items 1-6 passing.
    if [ -z "$gate" ] && [ -z "$held" ] && [ -n "$screen" ]; then
      [ -n "${EP_block_since:-}" ] || EP_block_since=$NOW
      if [ $((NOW - EP_block_since)) -ge 240 ] && [ "${EP_block_parked:-0}" != 1 ]; then
        fhl_caps
        EP_state=parked EP_t0=$EP_block_since EP_episode="ep-$NOW" EP_opened=$NOW
        fhl_row "$TASK" 0 observe "episode-open screen-block T0=$EP_t0" && EP_actions=$ROW_ID
        fhl_act 5 "park screen-block $screen" "$(fhl_snapshot_pane "$EP_episode-r5")" && EP_rung5_at=$NOW
        EP_block_parked=1
      fi
    else
      EP_block_since='' EP_block_parked=0
    fi
    if [ -z "$gate" ] && [ -z "$held" ] && [ -z "$screen" ] && [ "$proof" = 1 ]; then
      [ -n "${EP_since:-}" ] || EP_since=$NOW
      if [ "$WAIT" = dead ] || [ $((NOW - EP_since)) -ge 240 ]; then
        fhl_caps
        EP_state=open EP_t0=$EP_since EP_episode="ep-$EP_since" EP_opened=$NOW
        fhl_row "$TASK" 0 observe "episode-open T0=$EP_t0" && EP_actions=$ROW_ID
        fhl_act 1 "verify wait=$WAIT${WAIT_NOTE:+ note=$WAIT_NOTE}" && EP_rung1_at=$NOW
      fi
    else
      EP_since=
    fi
  fi

  if [ "$EP_state" = open ]; then
    local elapsed=$((NOW - EP_t0)) hold=''
    fhl_caps
    if [ -n "$held" ] || [ -n "$unknown_kinds" ]; then
      hold="unknown:${unknown_kinds%,}"
    elif [ -n "$screen" ]; then
      hold="screen:$screen"
      # A block that appears inside an episode parks it after lasting 4
      # minutes, exactly as one seen before an episode opens.
      [ -n "${EP_block_since:-}" ] || EP_block_since=$NOW
      if [ $((NOW - EP_block_since)) -ge 240 ] && [ "${EP_block_parked:-0}" != 1 ]; then
        fhl_act 5 "park screen-block $screen" "$(fhl_snapshot_pane "$EP_episode-r5")" && EP_rung5_at=$NOW EP_state=parked
        EP_block_parked=1
      fi
    fi
    [ -n "$screen" ] && [ "$hold" = "screen:$screen" ] || EP_block_since='' EP_block_parked=0
    if [ -z "$hold" ] && [ "$proof" = 1 ]; then
      if [ -z "${EP_rung2_at:-}" ] && { [ "$WAIT" = dead ] || [ "$elapsed" -ge 360 ]; }; then
        fhl_act 2 "steer${WAIT_NOTE:+ wait-ended=$WAIT_NOTE}" && EP_rung2_at=$NOW
      elif [ -n "${EP_rung2_at:-}" ] && [ -z "${EP_rung3_at:-}" ] && [ "$elapsed" -ge 960 ] && [ $((NOW - EP_rung2_at)) -ge 480 ]; then
        if [ "$TRIPPED" = 1 ]; then
          hold=breaker
        else
          fhl_act 3 interrupt "$(fhl_snapshot_pane "$EP_episode-r3")" && EP_rung3_at=$NOW
        fi
      elif [ -n "${EP_rung3_at:-}" ] && [ -z "${EP_rung4_at:-}" ] && [ "$elapsed" -ge 1320 ] && [ $((NOW - EP_rung3_at)) -ge 360 ]; then
        local chain=''
        chain=$(fhl_chain_walk) || chain=broken
        fhl_caps
        local lock_path=''
        [ -z "$WT" ] || lock_path=$(git -C "$WT" rev-parse --git-path index.lock 2>/dev/null) || lock_path=
        case "$lock_path" in /*) ;; ?*) lock_path="$WT/$lock_path" ;; esac
        if [ "$chain" = broken ]; then
          hold=ledger-unverified
        elif [ "$TRIPPED" = 1 ]; then
          hold=breaker
        elif [ -n "$lock_path" ] && [ -e "$lock_path" ]; then
          hold=git-op
        elif [ -n "$CAP_HIT" ]; then
          fhl_act 5 "park cap:$CAP_HIT" "$(fhl_snapshot_pane "$EP_episode-r5")" && EP_rung5_at=$NOW EP_state=parked
        elif [ "$children" -gt 0 ]; then
          fhl_act 5 "park descendant-alive children=$children stale=$stale_children" "$(fhl_snapshot_pane "$EP_episode-r5")" && EP_rung5_at=$NOW EP_state=parked
        elif [ "$backend" = t3code ]; then
          fhl_act 5 "park backend-cannot-replace" && EP_rung5_at=$NOW EP_state=parked
        else
          local gated=''
          case "$backend" in tmux|herdr) ;; *) gated=" replace-gate=owner($backend)" ;; esac
          fhl_act 4 "relaunch$gated" "$(fhl_snapshot_tree "$EP_episode-r4")" && EP_rung4_at=$NOW
        fi
      fi
    fi
    if [ "$hold" != "${EP_hold:-}" ]; then
      [ -z "$hold" ] || fhl_row "$TASK" - hold "$hold" "${EP_episode:-}" || true
      EP_hold=$hold
    fi
    if [ "$elapsed" -ge 1560 ] && [ -z "${EP_rung4_at:-}" ] && [ "$(( NOW - $(fhl_num "${EP_held_alarm_at:-0}" 0) ))" -ge 3600 ]; then
      fhl_row "$TASK" - alarm "held-past-T0+26 hold=${EP_hold:-none}" "${EP_episode:-}" && EP_held_alarm_at=$NOW
    fi
  fi
  fhl_write_episode
  exit 0
}

cmd_prune() {
  fhl_refuse_worker
  [ -d "$HL" ] || exit 0
  NOW=$(fhl_now)
  fhl_resolve_mode
  case "$MODE_REASON" in refused:*) exit 0 ;; esac
  mkdir "$HL/.lock" 2>/dev/null || exit 0
  trap 'rmdir "$HL/.lock" 2>/dev/null' EXIT
  SIGNALS=- CAPS=- BREAKER=-
  fhl_prune_now
}

cmd_mode() {
  NOW=$(fhl_now)
  fhl_resolve_mode
  printf 'mode: %s\nconfigured: %s\nreason: %s\nactor: %s\n' "$EFFECTIVE" "$CFG_MODE" "$MODE_REASON" "$MODE_ACTOR"
}

cmd_set_mode() {
  local want=${1-} actor='' f="$CONFIG/hung-ladder" tmp
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --actor) actor=${2-}; shift ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fhl_refuse_worker
  case "$actor" in ''|*[!A-Za-z0-9._@-]*) echo "fm-hung-ladder: set-mode needs --actor <name>" >&2; exit 2 ;; esac
  NOW=$(fhl_now)
  case "$want" in
    off|observe) ;;
    steer|interrupt|relaunch)
      if ! fhl_approval_valid "$want"; then
        printf 'fm-hung-ladder: refused: mode %s needs a valid owner approval record (%s); nothing was changed\n' "$want" "$APPROVAL_REASON" >&2
        exit 3
      fi
      printf 'fm-hung-ladder: approved, but stage 1 has no live path; the effective mode stays observe\n' >&2
      ;;
    *) echo "fm-hung-ladder: unknown mode: $want" >&2; exit 2 ;;
  esac
  mkdir -p "$CONFIG" || exit 2
  tmp="$f.tmp.$$"
  {
    printf 'mode=%s\nactor=%s\nchanged_at=%s\n' "$want" "$actor" "$NOW"
    [ ! -f "$f" ] || grep -vE '^(mode|actor|changed_at)=' "$f" | grep -vE '^[a-z]+$' || true
  } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$f"
  cmd_mode
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"

case "${1:-}" in
  tick) shift; cmd_tick "$@" ;;
  mode) cmd_mode ;;
  set-mode) shift; cmd_set_mode "$@" ;;
  verify) cmd_verify ;;
  prune) cmd_prune ;;
  *) usage >&2; exit 2 ;;
esac
