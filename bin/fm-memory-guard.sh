#!/usr/bin/env bash
# fm-memory-guard.sh - host memory and swap self-monitoring that names a
# runaway process and, only in mode=stop-scratch, stops a runaway scratch one.
#
# Usage:
#   fm-memory-guard.sh check [--json] [--observe]
#       Take one read-only sample, record it, and report. --json prints one
#       JSON object instead of the text lines. --observe forces observe mode
#       for this pass whatever config/memory-guard says.
#   fm-memory-guard.sh --help
#
# bin/fm-watchdog.sh runs one check per pass and passes --observe unless its
# own mode is act. There is no daemon of its own.
#
# Sampling is read-only:
#   macOS  swap from `sysctl -n vm.swapusage` (the used = <n>M|G field)
#   Linux  swap from /proc/meminfo (SwapTotal - SwapFree, in kB)
#   both   processes from `ps -axo pid=,uid=,ppid=,pgid=,rss=,etime=,args=`
#          and `ps -axo pid=,ucomm=` (Linux uses -eo and comm). The name is
#          read on its own because it can hold spaces; it is reduced to its
#          basename. macOS ucomm names the real executable, not argv[0].
# The sample time is the clock right after the process table read, and the
# executable name loses the padding macOS adds.
# A swap read that fails is swap_used_mb=unknown. A process read that fails
# leaves the top fields as `-` and makes the pass exit 1 unless it alarms;
# when both fail the status is unreadable.
#
# Files, under FM_HOME (FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE replace
# state/ and config/):
#   config/memory-guard        optional key=value; # lines and blanks ignored;
#                              the last line for a key wins.
#   state/memory-guard.tsv     one sample row per pass, tab-separated, no header:
#                              epoch swap_used_mb top_pid top_rss_mb top_comm status action
#                              Trimmed to the newest log_max_rows rows.
#   state/memory-guard-seen.tsv  pid start first_seen last_seen read_secs for
#                              each process at or over proc_rss_mb; read_secs
#                              is how long the read that set start took.
#   state/memory-guard-alarms.tsv  key last_emitted for each alarm in force.
#   state/memory-guard-stops.tsv  one row per signal and per stop outcome,
#                              stop-scratch only: epoch pid start comm event
#                              detail. event is signal (detail TERM or KILL),
#                              stopped (detail: the signal that ended it), or
#                              stop-failed (detail: why). A signal row is
#                              written before that signal is sent. Trimmed
#                              to the newest log_max_rows rows.
#
# Keys and defaults:
#   swap_warn_mb=16384         swap used at or over this is an alarm
#   proc_rss_mb=8192           a process at or over this RSS is watched
#   proc_sustained_secs=900    a watched process this long is an alarm
#   alarm_repeat_secs=3600     an alarm still in force is printed again after this
#   log_max_rows=2000          sample rows kept
#   scratch_stop_secs=420      stop-scratch only: a scratch process that has
#                              held proc_rss_mb this long is stopped; a value
#                              over proc_sustained_secs counts as that value
#   mode=observe               observe reports each alarm; reap-scratch also
#                              classifies each sustained process as below;
#                              stop-scratch also stops a scratch process
# A key whose value is not a positive integer keeps its default and prints a
# stderr note. Any mode other than reap-scratch or stop-scratch is observe.
#
# Sustained window: a process is tracked by pid and start time (sample time
# minus etime). Two starts match within 5 s plus the time this process read
# took and the time the read that set the stored start took, each counted to
# at most 30 s, so a slow read on a loaded host keeps the window and a reused
# pid starts a new one. A process that
# drops under proc_rss_mb, or was last seen more than 600 s ago, starts again,
# so samples must come at least every 600 s for any process to be sustained.
#
# Status: ok (nothing over a limit), watch (a process over proc_rss_mb, not yet
# sustained), alarm (swap at or over swap_warn_mb or a sustained process), or
# unreadable (both reads failed).
# Action: none, or a comma list of would-stop:<pid> (a sustained process that
# is disposable scratch), spared:<pid> (one that is not), and in stop-scratch
# stopped:<pid>, stop-failed:<pid>, and stop-deferred:<pid>.
#
# observe and reap-scratch never send a signal, and neither does any mode with
# --observe. With mode=reap-scratch and no --observe, each sustained process
# is classified, and the alarm names it as one that would be stopped only when
# every rule below holds; it is still left running.
#
# With mode=stop-scratch and no --observe, a process that has held proc_rss_mb
# for scratch_stop_secs is classified by the same rules, and one that passes
# every rule is stopped. A spared process alarms after proc_sustained_secs as
# in the other modes and is never signalled, so an agent session, a
# supervisor, and every process with children stay alarm-only.
# Stops run largest first. A stop starts only in the first 15 s of a pass, to
# leave it time inside a caller's 30 s bound; a process left over is named
# stop-deferred and waits for the next pass. Right before each signal the
# guard reads that one pid again: it must still have the same start time,
# user, executable name, and command line, and no child process (pgrep -P);
# before the first signal it must also still be at or over proc_rss_mb.
# A process that fails the first check has changed since the sample: nothing
# is signalled, and it stays watched. The guard then sends TERM to that pid
# alone, never to a process group or to another process, waits up to 5 s for
# it to be gone (absent, a zombie, or its pid reused), and sends KILL when the
# same process is still there, waiting up to 3 s more. A process that started
# a child after TERM gets no KILL; it is stop-failed, and the next pass spares
# it as a process with children. Each signal is written to
# state/memory-guard-stops.tsv before it is sent, and so is the outcome after,
# so a pass that is cut short still leaves a record of what it signalled; a
# signal that cannot be recorded is not sent. A process that could
# not be checked or is still running afterwards is stop-failed, and each later
# pass tries again. A stop or a failed stop is an alarm, so the pass exits 3
# and reports it; a deferred or changed process alarms only once it is
# sustained.
#
# The rules, all of which must hold:
#   - it belongs to the guard's own uid and is not the guard or an ancestor;
#   - no protected name is its command name, its argv[0] basename, any path
#     component of any argument, or the leading word of one (claude-code,
#     .codex, muse-bin-1.4): claude, codex, agy, cursor, cursor-agent, grok,
#     kimi, opencode, pi, pi-signed, omp, droid, hermes, muse, gemini, rovo,
#     devin, cortex, kiro, kiro-cli, polytoken, commandcode, command-code, orca, herdr, tmux, zellij, screen, no-mistakes,
#     treehouse, launchd, systemd, sshd, login, and desktop, IDE, and browser
#     processes (any argument inside a .app bundle, code, electron, chrome,
#     chromium, brave, msedge, opera, vivaldi, firefox, safari, the JetBrains
#     IDEs, zed, emacs, vim, Xorg, Xwayland, gnome-shell, kwin, plasmashell,
#     WindowServer; the script's PROTECTED_NAMES holds the full list);
#   - no argument is a Firstmate supervisor script or helper (bin/fm-*, or
#     any fm-*.sh, .py, .js, .mjs, .rb, or .pl by basename other than a
#     *.test.sh runner), wherever
#     it lives, and no argument is a Chromium or Electron helper --type=;
#   - node is protected unless its program is under a disposable temp root;
#   - no protected process descends from it, and it has no child processes
#     at all;
#   - its executable name was read (ucomm on macOS, comm on Linux), never
#     guessed from argv[0];
#   - it is scratch only when a shell or interpreter runs
#     a script (its first argument, which must not be an option) under a
#     disposable temp root (/tmp/fm-*, /private/tmp/fm-*,
#     /var/folders/<a>/<b>/T/fm-*, or $TMPDIR/fm-*) with no . or ..
#     segment; the script is an existing regular file, not a symlink, no
#     sibling extends its name with a space, it is still under a temp root
#     once its directory symlinks are resolved, and the resolved path
#     carries no protection. A native binary under a temp root is never
#     scratch, and Bun and Deno never are because they take subcommands.
#     The script has exactly one hard link, so no other name can alias an
#     agent or project file. On Linux, the executable /proc/<pid>/exe names
#     must itself be a shell or interpreter, since comm follows a symlink
#     name. TMPDIR counts as a temp root only when it resolves under /tmp,
#     /private/tmp, or /var/folders/<a>/<b>/T. No argument may hold a ..
#     segment, and an argument that only names a temp path does not make a
#     process scratch. A child of a test runner gets no special treatment,
#     and a test-queue run is not a class of its own;
#   - names and paths are compared without case, since macOS file systems
#     usually ignore it;
#   - a script run straight through its shebang on Linux names itself, not
#     its interpreter, and a framework Python on macOS is named Python, so
#     neither is ever scratch; these rules spare too much, never too little;
# A swap alarm alone classifies nothing.
#
# Stdout without --json: one summary line, then one line per alarm printed
# this pass:
#   memory-guard: status=<s> swap_used_mb=<n|unknown> top_pid=<n|-> top_rss_mb=<n|-> top_comm=<name|-> mode=<m> action=<a>
#   MEMORY_GUARD_ALARM: <what is over which limit, and what was done>
# A stop is always printed, whatever alarm_repeat_secs says.
# An alarm still in force inside alarm_repeat_secs is not printed again.
#
# Exit status: 0 for ok or watch, 3 for alarm (even when the sample could not
# be recorded, so an alarm is never hidden), 1 when sampling or recording
# (the sample row, or the seen or alarm state) failed without an alarm, 2 for
# a usage error.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_MEMORY_GUARD_NOW fixes the
# clock, FM_MEMORY_GUARD_CLOCK names a file whose first line is the clock at
# each reading, FM_MEMORY_GUARD_ELAPSED adds seconds to the time the pass has
# run, FM_MEMORY_GUARD_OS (Darwin|Linux) picks the parser, and
# FM_MEMORY_GUARD_MEMINFO replaces /proc/meminfo. ps, pgrep, and sysctl come
# from PATH.
set -u

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

usage_error() {
  echo "usage: fm-memory-guard.sh check [--json] [--observe] | --help" >&2
  exit 2
}

json=0
force_observe=0
case "${1:-}" in
  -h | --help | help) usage; exit 0 ;;
  check) shift ;;
  *) usage_error ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    --observe) force_observe=1 ;;
    *) usage_error ;;
  esac
  shift
done

FM_HOME=${FM_HOME:?FM_HOME must name the firstmate home}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
CONF=$CONFIG/memory-guard
LOG=$STATE/memory-guard.tsv
SEEN=$STATE/memory-guard-seen.tsv
ALARMS=$STATE/memory-guard-alarms.tsv
STOPS=$STATE/memory-guard-stops.tsv
WINDOW_GAP_SECS=600
START_SLACK_SECS=5
READ_TOOK_MAX_SECS=30
STOP_START_MAX_SECS=15
STOP_TERM_WAIT_SECS=5
STOP_KILL_WAIT_SECS=3
TAB=$'\t'
SELF_PIDS=''

fixed_now=
clock_file=
elapsed_extra=0
os=
meminfo=/proc/meminfo
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  fixed_now=${FM_MEMORY_GUARD_NOW:-}
  clock_file=${FM_MEMORY_GUARD_CLOCK:-}
  case "${FM_MEMORY_GUARD_ELAPSED:-}" in '' | *[!0-9]*) ;; *) elapsed_extra=$FM_MEMORY_GUARD_ELAPSED ;; esac
  os=${FM_MEMORY_GUARD_OS:-}
  meminfo=${FM_MEMORY_GUARD_MEMINFO:-$meminfo}
fi
[ -n "$os" ] || os=$(uname -s)

# clock: a test clock when one is set, else the wall clock.
clock() {
  if [ -n "$clock_file" ]; then head -n 1 "$clock_file"
  elif [ -n "$fixed_now" ]; then printf '%s\n' "$fixed_now"
  else date +%s
  fi
}
# elapsed: whole seconds this pass has run.
elapsed() { printf '%s\n' "$((SECONDS + elapsed_extra))"; }
now=$(clock)

conf_get() {  # <key> -> last value, empty when absent
  [ -f "$CONF" ] || return 0
  awk -F= -v k="$1" '
    /^[[:space:]]*#/ || !/=/ { next }
    { key = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != k) next
      val = substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); v = val }
    END { if (v != "") print v }' "$CONF"
}

conf_int() {  # <key> <default>
  local v
  v=$(conf_get "$1")
  case "$v" in
    '') printf '%s\n' "$2" ;;
    *[!0-9]* | 0*) printf 'memory-guard: config: %s=%s is not a positive integer; using %s\n' "$1" "$v" "$2" >&2
      printf '%s\n' "$2" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

swap_warn_mb=$(conf_int swap_warn_mb 16384)
proc_rss_mb=$(conf_int proc_rss_mb 8192)
proc_sustained_secs=$(conf_int proc_sustained_secs 900)
alarm_repeat_secs=$(conf_int alarm_repeat_secs 3600)
log_max_rows=$(conf_int log_max_rows 2000)
scratch_stop_secs=$(conf_int scratch_stop_secs 420)
[ "$scratch_stop_secs" -le "$proc_sustained_secs" ] || scratch_stop_secs=$proc_sustained_secs
mode=$(conf_get mode)
case "$mode" in
  '' | observe) mode=observe ;;
  reap-scratch | stop-scratch) ;;
  *) printf 'memory-guard: config: mode=%s is not observe, reap-scratch, or stop-scratch; using observe\n' "$mode" >&2
    mode=observe ;;
esac
[ "$force_observe" = 0 ] || mode=observe

# --- sampling -------------------------------------------------------------------

read_swap_mb() {
  local raw
  case "$os" in
    Darwin)
      raw=$(sysctl -n vm.swapusage 2>/dev/null) || return 1
      printf '%s\n' "$raw" | awk '
        { for (i = 1; i < NF; i++) if ($i == "used" && $(i + 1) == "=") { v = $(i + 2); break } }
        END {
          if (v == "") exit 1
          u = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
          if (n !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
          if (u == "G") n = n * 1024; else if (u == "K") n = n / 1024; else if (u != "M") exit 1
          printf "%d\n", n }'
      ;;
    Linux)
      [ -r "$meminfo" ] || return 1
      awk '
        $1 == "SwapTotal:" { t = $2; ht = 1 } $1 == "SwapFree:" { f = $2; hf = 1 }
        END {
          if (!ht || !hf || t !~ /^[0-9]+$/ || f !~ /^[0-9]+$/) exit 1
          u = t - f; if (u < 0) u = 0; printf "%d\n", u / 1024 }' "$meminfo"
      ;;
    *) return 1 ;;
  esac
}

ps_select() { case "$os" in Darwin) printf '%s\n' -axo ;; *) printf '%s\n' -eo ;; esac; }
# macOS comm follows argv[0], which a process can rewrite; ucomm names the
# executable that really runs. Linux comm is already the executable's name.
comm_field() { case "$os" in Darwin) printf '%s\n' ucomm ;; *) printf '%s\n' comm ;; esac; }

# Prints pid uid ppid pgid rss_kb etime_secs comm args, tab-separated; comm is
# the basename of ps comm without the padding macOS adds, and every tab or
# control byte is a space. With a pid it reads that one process. It sets
# READ_AT to the clock right after the table read and READ_TOOK to how long
# that read took, because etime is only as old as the read.
READ_AT=
READ_TOOK=0
read_procs() {  # <names-scratch-file> [pid]
  local sel table before
  sel=$(ps_select)
  before=$(clock)
  if [ -n "${2:-}" ]; then
    table=$(ps -ww -o pid=,uid=,ppid=,pgid=,rss=,etime=,args= -p "$2" 2>/dev/null) || return 1
  else
    table=$(ps -ww "$sel" pid=,uid=,ppid=,pgid=,rss=,etime=,args= 2>/dev/null) || return 1
  fi
  READ_AT=$(clock)
  READ_TOOK=$((READ_AT - before))
  [ "$READ_TOOK" -ge 0 ] || READ_TOOK=0
  [ "$READ_TOOK" -le "$READ_TOOK_MAX_SECS" ] || READ_TOOK=$READ_TOOK_MAX_SECS
  if [ -n "${2:-}" ]; then
    ps -ww -o "pid=,$(comm_field)=" -p "$2" > "$1" 2>/dev/null || : > "$1"
  else
    ps -ww "$sel" "pid=,$(comm_field)=" > "$1" 2>/dev/null || : > "$1"
  fi
  [ -n "$table" ] || return 1
  printf '%s\n' "$table" | awk -v names="$1" '
    function secs(e,   d, n, p, t, i) {
      d = 0
      if (index(e, "-")) { split(e, dd, "-"); d = dd[1]; e = dd[2] }
      n = split(e, p, ":"); t = 0
      for (i = 1; i <= n; i++) t = t * 60 + p[i]
      return t + d * 86400
    }
    function base(s,   n, q) { n = split(s, q, "/"); return q[n] }
    BEGIN {
      while ((getline l < names) > 0) {
        sub(/^[[:space:]]+/, "", l)
        p = l; sub(/[[:space:]].*/, "", p)
        c = l; sub(/^[^[:space:]]+[[:space:]]*/, "", c); sub(/[[:space:]]+$/, "", c)
        if (p ~ /^[0-9]+$/) comm[p] = c
      }
    }
    {
      line = $0; gsub(/[[:cntrl:]]/, " ", line)
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/) next
      if ($6 !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) next
      args = line
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args)
      # An unread executable name stays unknown: argv[0] can be rewritten.
      c = ($1 in comm) ? comm[$1] : ""
      c = base(c); gsub(/[[:cntrl:]]/, " ", c); if (c == "") c = "?"
      printf "%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", $1, $2, $3, $4, $5, secs($6), c, args
    }'
}

# --- protection -----------------------------------------------------------------

PROTECTED_NAMES='claude codex agy cursor cursor-agent grok kimi opencode pi pi-signed omp droid hermes muse gemini rovo devin cortex kiro kiro-cli polytoken commandcode command-code orca herdr tmux zellij screen no-mistakes treehouse launchd systemd sshd login code Code electron Electron chrome chromium chromium-browser google-chrome brave brave-browser msedge microsoft-edge opera vivaldi epiphany firefox firefox-bin firefox-esr GeckoMain safari Safari idea pycharm webstorm goland clion rider studio zed sublime_text emacs vim nvim Xorg Xwayland gnome-shell kwin kwin_wayland plasmashell WindowServer Finder Dock loginwindow'

scratch_roots() {
  local t phys
  printf '%s\n' /tmp/fm- /private/tmp/fm-
  t=${TMPDIR:-}
  t=${t%/}
  [ -n "$t" ] || return 0
  # TMPDIR counts only when it really is a system temp directory.
  phys=$(cd -P -- "$t" 2>/dev/null && pwd -P) || return 0
  case "$phys" in
    /tmp | /tmp/* | /private/tmp | /private/tmp/*) ;;
    *) [[ "$phys" =~ ^(/private)?/var/folders/[^/]+/[^/]+/T(/|$) ]] || return 0 ;;
  esac
  printf '%s/fm-\n' "$t"
  [ "$phys" = "$t" ] || printf '%s/fm-\n' "$phys"
}

# Annotates each process row with its verdict: pid TAB eligible|spared TAB reason.
# Reads the process table on stdin; the candidates file lists the sustained pids.
# A process's program is argv[0], or for an interpreter (sh, bash, zsh, dash,
# ksh, python*, node, deno, bun, ruby, perl, php) its first operand; inline
# code (-c, -e, -) and an interpreter with no operand have no program path.
classify_candidates() {  # <candidates-file> <self-pids>
  awk -F'\t' -v cands="$1" -v selfs="$2" -v names="$PROTECTED_NAMES" -v roots="$(scratch_roots | tr '\n' '\t')" -v uid="$(id -u)" '
    function under_root(t,   i, n, r) {
      if (t == "" || t ~ /(^|\/)\.\.?(\/|$)/) return 0
      n = split(roots, r, "\t")
      for (i = 1; i <= n; i++) if (r[i] != "" && index(t, r[i]) == 1) return 1
      return (t ~ /^(\/private)?\/var\/folders\/[^\/]+\/[^\/]+\/T\/fm-/)
    }
    function bname(t,   s) { s = t; sub(/.*\//, "", s); return s }
    # Any .. segment in any argument makes every path in the command line
    # untrusted, because ps joins arguments with spaces.
    function dotdot(a) { return a ~ /(^|[ \/=])\.\.([ \/]|$)/ }
    # The program matches what runs: comm is the program basename, or its
    # prefix where the kernel truncates it; an interpreter runs as itself.
    function runs_as(p, pg,   c, b) {
      c = comm[p]; b = bname(pg)
      if (c == "") return 0
      if (interp(bname(prog0[p]))) return interp(c)
      return index(b, c) == 1 && (c == b || length(c) >= 15)
    }
    # Interpreters whose first argument is always a script; bun and deno take
    # subcommands (bun run, deno run), so they never make a process scratch.
    function script_interp(b) { return interp(b) && b !~ /^(bun|deno)$/ }
    function interp(b) { return b ~ /^(ba|z|da|k)?sh$/ || b ~ /^python[0-9.]*$/ || b ~ /^(node|deno|bun|ruby|perl|php)$/ }
    function program(a,   n, t, i) {
      n = split(a, t, " ")
      if (n == 0) return ""
      if (!interp(bname(t[1]))) return t[1]
      # Any option before the script may take a value, so there is no
      # trusted program path: inline code, a preload, or a module.
      if (n < 2 || t[2] ~ /^-/) return ""
      return t[2]
    }
    # A protected name as any path component of any argument, or as the
    # leading word of one (claude-code, .codex), protects the process.
    function protected_word(a,   n, t, i, m, c, j, w) {
      n = split(a, t, " ")
      for (i = 1; i <= n; i++) {
        m = split(t[i], c, /[\/=]/)
        for (j = 1; j <= m; j++) {
          if (c[j] in prot) return c[j]
          w = lead(c[j])
          if (w != "" && (w in prot)) return w
          w = hyphen_hit(c[j]); if (w != "") return w
        }
      }
      return ""
    }
    function supervisor(a,   n, t, i) {
      n = split(a, t, " ")
      for (i = 1; i <= n; i++) if (t[i] ~ /(^|\/)bin\/fm-[A-Za-z0-9_.-]+$/ || (bname(t[i]) ~ /^fm-[A-Za-z0-9_.-]*\.(sh|bash|py|js|mjs|rb|pl)$/ && t[i] !~ /\.test\.sh$/)) return 1
      return 0
    }
    function lead(t,   w) { w = t; sub(/^[.@]+/, "", w); sub(/[-.@_].*/, "", w); return w }
    # Names compare without case, since macOS file systems usually ignore it.
    function protected_reason(p,   c, a0, w, la) {
      c = tolower(comm[p]); a0 = tolower(bname(prog0[p])); la = tolower(args[p])
      if (c in prot) return "protected " c
      if (a0 in prot) return "protected " a0
      if (lead(c) in prot) return "protected " lead(c)
      if (lead(a0) in prot) return "protected " lead(a0)
      w = hyphen_hit(c); if (w != "") return "protected " w
      w = hyphen_hit(a0); if (w != "") return "protected " w
      if (la ~ /\.app\//) return "desktop app"
      if (la ~ /(^| )--type=[a-z-]+( |$)/) return "browser or Electron helper"
      w = protected_word(la); if (w != "") return "protected " w
      if ((c == "node" || a0 == "node") && !under_root(program(args[p]))) return "node outside a disposable temp root"
      if (supervisor(la)) return "firstmate supervisor script"
      return ""
    }
    # A protected name with a - or _ in it also protects any word it starts,
    # such as no-mistakes-daemon or command-code-1.74.
    function hyphen_hit(w,   k, L, nx) {
      for (k = 1; k <= nh; k++) { L = length(hy[k]); nx = substr(w, L + 1, 1); if (substr(w, 1, L) == hy[k] && (nx == "" || nx ~ /[-._@]/)) return hy[k] }
      return ""
    }
    BEGIN {
      n = split(tolower(names), nm, " "); for (i = 1; i <= n; i++) { prot[nm[i]] = 1; if (nm[i] ~ /[-_]/) hy[++nh] = nm[i] }
      n = split(selfs, sp, " "); for (i = 1; i <= n; i++) if (sp[i] != "") self[sp[i]] = 1
      while ((getline l < cands) > 0) if (l != "") cand[l] = 1
    }
    { pid = $1; kids[$3]++; puid[pid] = $2; ppid[pid] = $3; comm[pid] = $7; args[pid] = $8; prog0[pid] = $8; sub(/[[:space:]].*/, "", prog0[pid]); order[++np] = pid }
    END {
      for (i = 1; i <= np; i++) { p = order[i]; r = protected_reason(p); if (r != "") preason[p] = r }
      # Mark every ancestor of a protected process.
      for (p in preason) { q = ppid[p]; hops = 0; while (q in ppid && q != 0 && hops++ < 256) { hasprot[q] = p; q = ppid[q] } }
      for (c in cand) {
        if (!(c in ppid)) continue
        why = ""
        if (puid[c] != uid) why = "another user"
        else if (c in self) why = "the guard itself"
        else if (c + 0 <= 1) why = "init"
        else if (c in preason) why = preason[c]
        else if (c in hasprot) why = "ancestor of protected pid " hasprot[c]
        else if (comm[c] == "?") why = "executable name unknown"
        else if (kids[c] > 0) why = "has child processes"
        else {
          s = ""; pg = dotdot(args[c]) ? "" : program(args[c])
          if (under_root(pg) && script_interp(bname(prog0[c])) && runs_as(c, pg)) s = "program\t" pg
          if (s == "") why = "not scratch"
        }
        if (why == "") printf "%s\teligible\t%s\n", c, s
        else printf "%s\tspared\t%s\n", c, why
      }
    }'
}

# physical_path <path>: the path with every directory symlink resolved; a
# symlinked file or an unreadable directory has none.
physical_path() {
  local d
  [ ! -L "$1" ] || return 1
  d=$(cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$(basename -- "$1")"
}

# link_count <path>: the hard-link count of a file; GNU stat first, since
# GNU stat -f means file-system status rather than BSD file status.
link_count() { stat -c %h -- "$1" 2>/dev/null || stat -f %l -- "$1" 2>/dev/null; }

# real_interpreter <pid>: on Linux, comm follows the invoked file name, so a
# symlink can give any program a shell's name; the executable /proc links to
# must be a shell or script interpreter. On macOS ucomm already names it.
real_interpreter() {
  local exe
  [ "$os" = Linux ] || return 0
  exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
  exe=${exe##*/}
  [[ "$exe" =~ ^((ba|z|da|k)?sh|python[0-9.]*|node|ruby|perl|php)$ ]]
}

under_scratch_root() {  # <physical-path>
  local r
  case "$1" in */../*|*/./*|*/..|*/.) return 1 ;; esac
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$1" in "$r"*) return 0 ;; esac
  done <<EOF
$(scratch_roots)
EOF
  [[ "$1" =~ ^(/private)?/var/folders/[^/]+/[^/]+/T/fm- ]]
}

# ambiguous_program <path>: ps joins arguments with spaces, so a sibling named
# "<program> ..." means the real program path may be longer than it looks.
ambiguous_program() {
  local e
  for e in "$(dirname -- "$1")/$(basename -- "$1") "*; do
    [ -e "$e" ] || [ -L "$e" ] && return 0
  done
  return 1
}

# resolved_protection <physical-path>: the protection reason the resolved
# program path itself carries, judged as a bare command line; empty if none.
resolved_protection() {
  printf '999999999\n' > "$WORK/resolved-cand"
  printf '999999999\t%s\t0\t0\t0\t0\t%s\t%s\n' "$(id -u)" "$(basename -- "$1")" "$1" |
    classify_candidates "$WORK/resolved-cand" '' | awk -F'\t' '$2 == "spared" { print $3 }'
}

# judge <candidates-file>: classify_candidates on the table on stdin, then
# spare an eligible program whose physical path is ambiguous, leaves the temp
# roots, or is itself protected.
judge() {
  local pid verdict why prog phys prot
  classify_candidates "$1" "$SELF_PIDS" | while IFS=$'\t' read -r pid verdict why prog; do
    if [ "$verdict" = eligible ] && [ "$why" = program ]; then
      why=scratch
      if ambiguous_program "$prog"; then
        verdict=spared why="program path is ambiguous"
      elif ! phys=$(physical_path "$prog") || [ ! -f "$phys" ] || ! under_scratch_root "$phys"; then
        verdict=spared why="program is not a regular file under a disposable temp root"
      elif [ "$(link_count "$phys")" != 1 ]; then
        verdict=spared why="program has another hard link"
      elif ! real_interpreter "$pid"; then
        verdict=spared why="running executable is not an interpreter"
      elif ! prot=$(resolved_protection "$phys") || [ -z "$prot" ] || [ "$prot" != "not scratch" ]; then
        verdict=spared why="resolved program: ${prot:-unclassified}"
      fi
    fi
    printf '%s\t%s\t%s\n' "$pid" "$verdict" "$why"
  done
}

self_pids() {  # the guard and every ancestor
  local p=$$ out='' hops=0
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$hops" -lt 64 ]; do
    out="$out $p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
    hops=$((hops + 1))
  done
  printf '%s\n' "$out"
}

# --- one pass -------------------------------------------------------------------

mkdir -p "$STATE" || { echo "memory-guard: cannot create $STATE" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-memory-guard-pass.XXXXXX") || { echo "memory-guard: cannot create a work directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

swap_ok=1
swap_mb=$(read_swap_mb) || swap_ok=0
[ "$swap_ok" = 1 ] && [ -n "$swap_mb" ] || { swap_ok=0; swap_mb=unknown; }
procs_ok=1
state_ok=1
read_procs "$WORK/names" > "$WORK/procs" || procs_ok=0
[ -s "$WORK/procs" ] || procs_ok=0
# etime is as old as the read, so the sample time is the end of the read.
[ "$procs_ok" = 0 ] || now=$READ_AT
read_took=$READ_TOOK
[ "$swap_ok" = 1 ] || echo "memory-guard: swap could not be read on $os" >&2
[ "$procs_ok" = 1 ] || echo "memory-guard: the process table could not be read" >&2

top_pid=- top_rss=- top_comm=-
if [ "$procs_ok" = 1 ]; then
  IFS=$'\t' read -r top_pid top_rss top_comm < <(awk -F'\t' '$5 + 0 > best { best = $5 + 0; p = $1; c = $7 } END { if (p != "") printf "%s\t%d\t%s\n", p, best / 1024, c }' "$WORK/procs")
  [ -n "$top_pid" ] || { top_pid=- top_rss=- top_comm=-; }
fi

# Sustained window bookkeeping: rewrite the seen file from this sample. A
# start time is only as exact as the read that gave it, so the match allows
# for this read and for the read that set the stored start.
stop_at=0
[ "$mode" != stop-scratch ] || stop_at=$scratch_stop_secs
: > "$WORK/seen"
: > "$WORK/sustained"
: > "$WORK/stop-due"
if [ "$procs_ok" = 1 ]; then
  awk -F'\t' -v now="$now" -v lim="$proc_rss_mb" -v sus="$proc_sustained_secs" -v gap="$WINDOW_GAP_SECS" -v slack="$START_SLACK_SECS" \
      -v took="$read_took" -v stopat="$stop_at" -v seen="$SEEN" -v sout="$WORK/seen" -v susout="$WORK/sustained" -v dueout="$WORK/stop-due" '
    BEGIN { while ((getline l < seen) > 0) { split(l, f, "\t"); if (f[1] ~ /^[0-9]+$/) { st[f[1]] = f[2]; fs[f[1]] = f[3]; ls[f[1]] = f[4]; tk[f[1]] = (f[5] ~ /^[0-9]+$/) ? f[5] : 0 } } }
    $5 / 1024 >= lim + 0 {
      pid = $1; start = now - $6; first = now; mine = took
      if ((pid in st) && (now - ls[pid] <= gap)) {
        d = start - st[pid]; if (d < 0) d = -d
        if (d <= slack + tk[pid] + took) { first = fs[pid]; start = st[pid]; mine = tk[pid] }
      }
      printf "%s\t%s\t%s\t%s\t%s\n", pid, start, first, now, mine > sout
      held = now - first
      if (held >= sus + 0) printf "%s\t%d\t%d\t%s\n", pid, $5 / 1024, held, $7 > susout
      if (stopat + 0 > 0 && held >= stopat + 0) printf "%s\t%d\t%d\t%s\n", pid, $5 / 1024, held, $7 > dueout
    }' "$WORK/procs"
  cp "$WORK/seen" "$WORK/seen-now" 2>/dev/null || : > "$WORK/seen-now"
  mv -f "$WORK/seen" "$SEEN" 2>/dev/null || { echo "memory-guard: cannot write $SEEN" >&2; state_ok=0; }
fi

watched=0
[ "$procs_ok" = 1 ] && [ "$(awk -F'\t' -v lim="$proc_rss_mb" '$5 / 1024 >= lim + 0 { n++ } END { print n + 0 }' "$WORK/procs")" -gt 0 ] && watched=1
swap_alarm=0
[ "$swap_ok" = 1 ] && [ "$swap_mb" -ge "$swap_warn_mb" ] && swap_alarm=1

# Classify each process that is due as scratch or spared: the sustained ones
# in reap-scratch, the ones past scratch_stop_secs in stop-scratch. observe
# does no classification work.
actions=''
: > "$WORK/verdicts"
REPORT=$WORK/sustained
[ "$mode" != stop-scratch ] || REPORT=$WORK/stop-due
if [ "$mode" != observe ] && [ -s "$REPORT" ]; then
  cut -f 1 "$REPORT" > "$WORK/cands"
  SELF_PIDS=$(self_pids)
  judge "$WORK/cands" < "$WORK/procs" > "$WORK/verdicts"
fi

verdict_of() { awk -F'\t' -v p="$1" '$1 == p { print $2 "\t" $3; exit }' "$WORK/verdicts"; }

# --- stop (mode=stop-scratch only) ------------------------------------------------

# proc_gone <pid>: no such process, or only a zombie that holds no memory.
proc_gone() {
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
  st=$(printf '%s' "$st" | tr -d '[:space:]')
  case "$st" in '' | Z*) return 0 ;; esac
  return 1
}

# wait_gone <pid> <secs>: true once the process is gone, false after <secs>.
wait_gone() {
  local end=$((SECONDS + $2))
  while :; do
    ! proc_gone "$1" || return 0
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 0.2
  done
}

# recheck <pid> <start> <read-secs> <uid> <comm> <args> <strict|childless|identity>:
# read that one pid again. 0: the same process (and, for childless, without a
# child; for strict, also still at or over the limit and still an
# interpreter). 1: gone or changed; RECHECK_SAME_START is 1 when the pid still
# holds a process with that start, and RECHECK_CHILD is 1 when that same
# process has a child. 2: it could not be checked.
RECHECK_SAME_START=0
RECHECK_CHILD=0
recheck() {
  local row r_uid r_rss r_etime r_comm r_args start d rc=0
  RECHECK_SAME_START=0
  RECHECK_CHILD=0
  read_procs "$WORK/recheck-names" "$1" > "$WORK/recheck" || return 1
  row=$(awk -F'\t' -v p="$1" '$1 == p { print $2 "\t" $5 "\t" $6 "\t" $7 "\t" $8; exit }' "$WORK/recheck")
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r r_uid r_rss r_etime r_comm r_args <<EOF
$row
EOF
  start=$((READ_AT - r_etime))
  d=$((start - $2)); [ "$d" -ge 0 ] || d=$((0 - d))
  [ "$d" -le $((START_SLACK_SECS + $3 + READ_TOOK)) ] || return 1
  RECHECK_SAME_START=1
  [ "$r_uid" = "$4" ] && [ "$r_comm" = "$5" ] && [ "$r_args" = "$6" ] || return 1
  [ "$7" != identity ] || return 0
  if [ "$7" = strict ]; then
    [ $((r_rss / 1024)) -ge "$proc_rss_mb" ] || return 1
    real_interpreter "$1" || return 1
  fi
  command -v pgrep >/dev/null 2>&1 || return 2
  pgrep -P "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) RECHECK_CHILD=1; return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# stop_record <pid> <start> <comm> <event> <detail>: append one row to the
# stop record. False when the row could not be written.
stop_record() {
  { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(clock)" "$1" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ')" "$4" "$5" >> "$STOPS"; } 2>/dev/null
}

# stop_scratch <pid>: stop one eligible process. Sets STOP_OUTCOME to stopped,
# stop-failed, or changed, and STOP_DETAIL to the signal or the reason.
STOP_OUTCOME=
STOP_DETAIL=
stop_scratch() {
  local pid=$1 start took uid comm args rc=0
  # stop_done <outcome> <detail>: set the outcome of a stop that sent a signal
  # and record it.
  stop_done() {
    STOP_OUTCOME=$1 STOP_DETAIL=$2
    stop_record "$pid" "$start" "$comm" "$1" "$2" || :
  }
  STOP_OUTCOME=stop-failed
  STOP_DETAIL="it could not be checked before the signal"
  case "$pid" in '' | *[!0-9]* | 0 | 1) return 0 ;; esac
  IFS=$'\t' read -r start took <<EOF
$(awk -F'\t' -v p="$pid" '$1 == p { printf "%s\t%s\n", $2, ($5 ~ /^[0-9]+$/ ? $5 : 0); exit }' "$WORK/seen-now")
EOF
  IFS=$'\t' read -r uid comm args <<EOF
$(awk -F'\t' -v p="$pid" '$1 == p { printf "%s\t%s\t%s\n", $2, $7, $8; exit }' "$WORK/procs")
EOF
  case "$start" in '' | *[!0-9]*) return 0 ;; esac
  [ -n "$uid" ] && [ -n "$comm" ] && [ -n "$args" ] || return 0
  recheck "$pid" "$start" "$took" "$uid" "$comm" "$args" strict || rc=$?
  case "$rc" in
    0) ;;
    1) STOP_OUTCOME=changed STOP_DETAIL="changed before the stop"; return 0 ;;
    *) return 0 ;;
  esac
  # No record, no signal: a stop must never be the only trace of itself.
  if ! stop_record "$pid" "$start" "$comm" signal TERM; then
    STOP_DETAIL="the stop could not be recorded in $STOPS"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || :
  if wait_gone "$pid" "$STOP_TERM_WAIT_SECS"; then
    stop_done stopped TERM
    return 0
  fi
  rc=0
  recheck "$pid" "$start" "$took" "$uid" "$comm" "$args" childless || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$RECHECK_SAME_START" = 0 ]; then stop_done stopped TERM
    elif [ "$RECHECK_CHILD" = 1 ]; then stop_done stop-failed "it started a child after TERM and was not signalled again"
    elif [ "$rc" = 1 ]; then stop_done stop-failed "it changed after TERM and was not signalled again"
    else stop_done stop-failed "it could not be checked before KILL"
    fi
    return 0
  fi
  if ! stop_record "$pid" "$start" "$comm" signal KILL; then
    stop_done stop-failed "KILL could not be recorded in $STOPS and was not sent"
    return 0
  fi
  kill -KILL "$pid" 2>/dev/null || :
  if wait_gone "$pid" "$STOP_KILL_WAIT_SECS" || { ! recheck "$pid" "$start" "$took" "$uid" "$comm" "$args" identity && [ "$RECHECK_SAME_START" = 0 ]; }; then
    stop_done stopped KILL
  else
    stop_done stop-failed "it is still running after TERM and KILL"
  fi
  return 0
}

# Work through the eligible processes, largest first, while the pass has time.
: > "$WORK/stops"
if [ "$mode" = stop-scratch ] && [ -s "$WORK/verdicts" ]; then
  awk -F'\t' 'NR == FNR { if ($2 == "eligible") e[$1] = 1; next } ($1 in e)' "$WORK/verdicts" "$WORK/stop-due" |
    sort -t "$TAB" -k 2,2nr > "$WORK/stop-queue"
  while IFS=$'\t' read -r -u 3 pid _; do
    [ -n "$pid" ] || continue
    if [ "$(elapsed)" -gt "$STOP_START_MAX_SECS" ]; then
      STOP_OUTCOME=stop-deferred STOP_DETAIL="this pass had no time left"
    else
      stop_scratch "$pid"
    fi
    printf '%s\t%s\t%s\n' "$pid" "$STOP_OUTCOME" "$STOP_DETAIL" >> "$WORK/stops"
  done 3< "$WORK/stop-queue"
fi

stop_of() { awk -F'\t' -v p="$1" '$1 == p { print $2 "\t" $3; exit }' "$WORK/stops"; }

: > "$WORK/alarm-lines"
: > "$WORK/alarm-keys"
add_alarm() {  # <key> <line> [always]
  printf '%s\n' "$1" >> "$WORK/alarm-keys"
  printf '%s\t%s\t%s\n' "$1" "${3:-}" "$2" >> "$WORK/alarm-lines"
}

if [ "$swap_alarm" = 1 ]; then
  line="swap used ${swap_mb} MB is at or over ${swap_warn_mb} MB"
  [ "$top_pid" = - ] || line="$line; the largest process is pid $top_pid ($top_comm) at $top_rss MB"
  add_alarm swap "$line. A swap alarm alone stops nothing."
fi

while IFS=$'\t' read -r pid rss held comm; do
  [ -n "$pid" ] || continue
  start=$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$WORK/seen-now" 2>/dev/null)
  IFS=$'\t' read -r verdict reason <<EOF
$(verdict_of "$pid")
EOF
  IFS=$'\t' read -r outcome detail <<EOF
$(stop_of "$pid")
EOF
  sustained=0
  [ "$held" -lt "$proc_sustained_secs" ] || sustained=1
  limit=$proc_sustained_secs
  case "$outcome" in stopped | stop-failed | stop-deferred) limit=$scratch_stop_secs ;; esac
  line="pid $pid ($comm) has held $rss MB, at or over $proc_rss_mb MB, for $held s (limit $limit s)"
  always=''
  case "$mode:$outcome" in
    stop-scratch:stopped)
      actions="$actions${actions:+,}stopped:$pid"
      always=always
      if [ "$detail" = KILL ]; then line="$line. Mode stop-scratch: disposable scratch, stopped with KILL after it ignored TERM."
      else line="$line. Mode stop-scratch: disposable scratch, stopped with TERM."
      fi ;;
    stop-scratch:stop-failed)
      actions="$actions${actions:+,}stop-failed:$pid"
      line="$line. Mode stop-scratch: disposable scratch, but the stop failed ($detail); the next pass tries again." ;;
    stop-scratch:stop-deferred)
      actions="$actions${actions:+,}stop-deferred:$pid"
      [ "$sustained" = 1 ] || continue
      line="$line. Mode stop-scratch: disposable scratch; its stop waits for the next pass ($detail)." ;;
    stop-scratch:*)
      # Not stopped: it alarms as a spared process does, once it is sustained.
      [ "$sustained" = 1 ] || continue
      [ "$outcome" != changed ] || reason=$detail
      actions="$actions${actions:+,}spared:$pid"
      line="$line. Mode stop-scratch: spared (${reason:-unclassified}); nothing was stopped." ;;
    reap-scratch:*)
      if [ "$verdict" = eligible ]; then
        actions="$actions${actions:+,}would-stop:$pid"
        line="$line. Mode reap-scratch: disposable scratch that would be stopped; this mode never signals, so nothing was stopped."
      else
        actions="$actions${actions:+,}spared:$pid"
        line="$line. Mode reap-scratch: spared (${reason:-unclassified}); nothing was stopped."
      fi ;;
    *) line="$line. Mode observe: nothing was stopped." ;;
  esac
  add_alarm "proc:$pid:${start:-0}" "$line" "$always"
done < "$REPORT"
[ -n "$actions" ] || actions=none

if [ "$swap_ok" = 0 ] && [ "$procs_ok" = 0 ]; then status=unreadable
elif [ -s "$WORK/alarm-keys" ]; then status=alarm
elif [ "$watched" = 1 ]; then status=watch
else status=ok
fi

# Deduplicate: print an alarm only when it is new or older than the repeat time.
: > "$WORK/alarms-next"
: > "$WORK/printed"
while IFS= read -r row; do
  key=${row%%"$TAB"*}
  [ -n "$key" ] || continue
  row=${row#*"$TAB"}
  always=${row%%"$TAB"*}
  line=${row#*"$TAB"}
  last=$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$ALARMS" 2>/dev/null)
  case "$last" in *[!0-9]*) last='' ;; esac
  if [ -n "$always" ] || [ -z "$last" ] || [ $((now - last)) -ge "$alarm_repeat_secs" ]; then
    printf '%s\n' "$line" >> "$WORK/printed"
    last=$now
  fi
  printf '%s\t%s\n' "$key" "$last" >> "$WORK/alarms-next"
done < "$WORK/alarm-lines"
mv -f "$WORK/alarms-next" "$ALARMS" 2>/dev/null || { echo "memory-guard: cannot write $ALARMS" >&2; state_ok=0; }

# Record the sample and keep the log bounded.
record_ok=1
tsv_comm=$(printf '%s' "$top_comm" | tr '\t\n' '  ')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$swap_mb" "$top_pid" "$top_rss" "$tsv_comm" "$status" "$actions" >> "$LOG" || record_ok=0
if [ "$record_ok" = 1 ] && [ "$(wc -l < "$LOG" | tr -d ' ')" -gt "$log_max_rows" ]; then
  if tail -n "$log_max_rows" "$LOG" > "$WORK/log" && mv -f "$WORK/log" "$LOG"; then :; else record_ok=0; fi
fi
[ "$record_ok" = 1 ] || echo "memory-guard: cannot record the sample in $LOG" >&2
# The stop record is bounded the same way; a failed trim loses no row.
if [ -s "$WORK/stops" ] && [ -f "$STOPS" ] && [ "$(wc -l < "$STOPS" | tr -d ' ')" -gt "$log_max_rows" ]; then
  if tail -n "$log_max_rows" "$STOPS" > "$WORK/stops-log" 2>/dev/null; then mv -f "$WORK/stops-log" "$STOPS" 2>/dev/null || :; fi
fi

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037')"; }
json_num() { case "$1" in '' | *[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

if [ "$json" = 1 ]; then
  top_json=null
  [ "$top_comm" = - ] || top_json=$(json_str "$top_comm")
  printf '{"status":%s,"swap_used_mb":%s,"swap_warn_mb":%s,"proc_rss_mb":%s,"proc_sustained_secs":%s,"mode":%s,' \
    "$(json_str "$status")" "$(json_num "$swap_mb")" "$swap_warn_mb" "$proc_rss_mb" "$proc_sustained_secs" "$(json_str "$mode")"
  printf '"top":{"pid":%s,"rss_mb":%s,"comm":%s},"action":%s,"alarms":[' \
    "$(json_num "$top_pid")" "$(json_num "$top_rss")" "$top_json" "$(json_str "$actions")"
  sep=''
  while IFS= read -r line; do
    printf '%s%s' "$sep" "$(json_str "$line")"
    sep=,
  done < "$WORK/printed"
  printf ']}\n'
else
  printf 'memory-guard: status=%s swap_used_mb=%s top_pid=%s top_rss_mb=%s top_comm=%s mode=%s action=%s\n' \
    "$status" "$swap_mb" "$top_pid" "$top_rss" "$(printf '%s' "$top_comm" | tr ' ' '_')" "$mode" "$actions"
  while IFS= read -r line; do
    printf 'MEMORY_GUARD_ALARM: %s\n' "$line"
  done < "$WORK/printed"
fi

[ "$status" != alarm ] || exit 3
[ "$procs_ok" = 1 ] && [ "$record_ok" = 1 ] && [ "$state_ok" = 1 ] || exit 1
exit 0
