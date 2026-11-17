#!/usr/bin/env bash
# fm-memory-guard.sh - host memory and swap self-monitoring with a guarded
# runaway-scratch reaper.
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
#          and `ps -axo pid=,comm=` (Linux uses -eo). comm is read on its
#          own because it can hold spaces; it is reduced to its basename.
# A swap read that fails is swap_used_mb=unknown. A process read that fails
# leaves the top fields as `-`. When both fail the pass exits 1.
#
# Files, under FM_HOME (FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE replace
# state/ and config/):
#   config/memory-guard        optional key=value; # lines and blanks ignored;
#                              the last line for a key wins.
#   state/memory-guard.tsv     one sample row per pass, tab-separated, no header:
#                              epoch swap_used_mb top_pid top_rss_mb top_comm status action
#                              Trimmed to the newest log_max_rows rows.
#   state/memory-guard-seen.tsv  pid start first_seen last_seen for each process
#                              at or over proc_rss_mb.
#   state/memory-guard-alarms.tsv  key last_emitted for each alarm in force.
#
# Keys and defaults:
#   swap_warn_mb=16384         swap used at or over this is an alarm
#   proc_rss_mb=8192           a process at or over this RSS is watched
#   proc_sustained_secs=900    a watched process this long is an alarm
#   alarm_repeat_secs=3600     an alarm still in force is printed again after this
#   log_max_rows=2000          sample rows kept
#   mode=observe               observe never signals anything; reap-scratch
#                              allows the SIGTERM described below
# A key whose value is not a positive integer keeps its default and prints a
# stderr note. Any mode other than reap-scratch is observe.
#
# Sustained window: a process is tracked by pid and start time (now - etime,
# matched within 5 s, so a reused pid starts a new window). A process that
# drops under proc_rss_mb, or was last seen more than 600 s ago, starts again,
# so samples must come at least every 600 s for any process to be sustained.
#
# Status: ok (nothing over a limit), watch (a process over proc_rss_mb, not yet
# sustained), alarm (swap at or over swap_warn_mb or a sustained process), or
# unreadable (both reads failed).
# Action: none, or a comma list of term:<pid>, term-failed:<pid>, and
# spared:<pid> (a sustained process reap-scratch would not signal).
#
# Reaping: only with mode=reap-scratch and no --observe, and only for a
# sustained process. It gets one SIGTERM per pass to its own pid (never a
# group, never SIGKILL), so a process that ignores it is signaled and reported
# again on the next pass, only when every rule holds:
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
#   - no protected process descends from it;
#   - it is scratch: its program (argv[0], or an interpreter's first argument
#     when that is not an option) starts under a disposable temp root
#     (/tmp/fm-*, /private/tmp/fm-*, /var/folders/<a>/<b>/T/fm-*, or
#     $TMPDIR/fm-*) with no . or .. segment, is not itself a symlink, and
#     still does once its directory symlinks are resolved; or an ancestor's
#     program is a tests/<name>.test.sh script, with no protected process
#     between them, and its own argv[0] is a shell,
#     an interpreter, or a core tool such as sleep, awk, or jq. The program
#     must be an existing regular file, its command name must match it, no
#     argument may hold a .. segment, no sibling may extend its name with a
#     space, and its resolved path must carry no protection of its own. An argument that only names a temp
#     path, or an interpreter started with an option, does not make it
#     scratch;
#   - a fresh process read just before the signal still shows the same
#     process (uid, parent, command name, arguments, and an elapsed time that
#     only moved forward) and still judges it eligible; otherwise it is
#     spared as changed since the sample.
# A swap alarm alone signals nothing.
#
# Stdout without --json: one summary line, then one line per alarm printed
# this pass:
#   memory-guard: status=<s> swap_used_mb=<n|unknown> top_pid=<n|-> top_rss_mb=<n|-> top_comm=<name|-> mode=<m> action=<a>
#   MEMORY_GUARD_ALARM: <what is over which limit, and what was done>
# An alarm still in force inside alarm_repeat_secs is not printed again.
#
# Exit status: 0 for ok or watch, 3 for alarm (even when the sample could not
# be recorded, so an action is never hidden), 1 when sampling or recording
# failed without an alarm, 2 for a usage error.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_MEMORY_GUARD_NOW fixes the
# clock, FM_MEMORY_GUARD_OS (Darwin|Linux) picks the parser, and
# FM_MEMORY_GUARD_MEMINFO replaces /proc/meminfo. ps and sysctl come from PATH.
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
WINDOW_GAP_SECS=600
START_SLACK_SECS=5
RECHECK_MAX_SECS=120
SELF_PIDS=''

now=
os=
meminfo=/proc/meminfo
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  now=${FM_MEMORY_GUARD_NOW:-}
  os=${FM_MEMORY_GUARD_OS:-}
  meminfo=${FM_MEMORY_GUARD_MEMINFO:-$meminfo}
fi
[ -n "$now" ] || now=$(date +%s)
[ -n "$os" ] || os=$(uname -s)

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
mode=$(conf_get mode)
case "$mode" in
  '' | observe) mode=observe ;;
  reap-scratch) ;;
  *) printf 'memory-guard: config: mode=%s is not observe or reap-scratch; using observe\n' "$mode" >&2
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

# Prints pid uid ppid pgid rss_kb etime_secs comm args, tab-separated; comm is
# the basename of ps comm, and every tab or control byte is a space.
read_procs() {  # <names-scratch-file>
  local sel table
  sel=$(ps_select)
  table=$(ps -ww "$sel" pid=,uid=,ppid=,pgid=,rss=,etime=,args= 2>/dev/null) || return 1
  ps -ww "$sel" pid=,comm= > "$1" 2>/dev/null || : > "$1"
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
        c = l; sub(/^[^[:space:]]+[[:space:]]*/, "", c)
        if (p ~ /^[0-9]+$/) comm[p] = c
      }
    }
    {
      line = $0; gsub(/[[:cntrl:]]/, " ", line)
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/) next
      if ($6 !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) next
      args = line
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args)
      c = ($1 in comm) ? comm[$1] : ""
      if (c == "") { c = args; sub(/[[:space:]].*/, "", c) }
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
  printf '%s/fm-\n' "$t"
  phys=$(cd -P -- "$t" 2>/dev/null && pwd -P) || return 0
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
    # Programs a test runner may start that count as its scratch children.
    function test_tool(b) { return interp(b) || b ~ /^(sleep|cat|head|tail|yes|dd|awk|gawk|mawk|sed|grep|sort|uniq|cut|tr|wc|jq|find|xargs|timeout|env|seq|printf|echo|true|false|mktemp|tee)$/ }
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
    function protected_reason(p,   c, a0, w) {
      c = comm[p]; a0 = bname(prog0[p])
      if (c in prot) return "protected " c
      if (a0 in prot) return "protected " a0
      if (lead(c) in prot) return "protected " lead(c)
      if (lead(a0) in prot) return "protected " lead(a0)
      w = hyphen_hit(c); if (w != "") return "protected " w
      w = hyphen_hit(a0); if (w != "") return "protected " w
      if (args[p] ~ /\.app\//) return "desktop app"
      if (args[p] ~ /(^| )--type=[a-z-]+( |$)/) return "browser or Electron helper"
      w = protected_word(args[p]); if (w != "") return "protected " w
      if ((c == "node" || a0 == "node") && !under_root(program(args[p]))) return "node outside a disposable temp root"
      if (supervisor(args[p])) return "firstmate supervisor script"
      return ""
    }
    # A protected name with a - or _ in it also protects any word it starts,
    # such as no-mistakes-daemon or command-code-1.74.
    function hyphen_hit(w,   k, L, nx) {
      for (k = 1; k <= nh; k++) { L = length(hy[k]); nx = substr(w, L + 1, 1); if (substr(w, 1, L) == hy[k] && (nx == "" || nx ~ /[-._@]/)) return hy[k] }
      return ""
    }
    BEGIN {
      n = split(names, nm, " "); for (i = 1; i <= n; i++) { prot[nm[i]] = 1; if (nm[i] ~ /[-_]/) hy[++nh] = nm[i] }
      n = split(selfs, sp, " "); for (i = 1; i <= n; i++) if (sp[i] != "") self[sp[i]] = 1
      while ((getline l < cands) > 0) if (l != "") cand[l] = 1
    }
    { pid = $1; puid[pid] = $2; ppid[pid] = $3; comm[pid] = $7; args[pid] = $8; prog0[pid] = $8; sub(/[[:space:]].*/, "", prog0[pid]); order[++np] = pid }
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
        else {
          s = ""; pg = dotdot(args[c]) ? "" : program(args[c])
          if (under_root(pg) && runs_as(c, pg)) s = "program\t" pg
          else if (!dotdot(args[c]) && test_tool(bname(prog0[c])) && runs_as(c, prog0[c])) { q = ppid[c]; hops = 0
            while (q in ppid && q != 0 && hops++ < 256) { if (q in preason) break; if (program(args[q]) ~ /(^|\/)tests\/[A-Za-z0-9_.-]+\.test\.sh$/) { s = "scratch"; break } q = ppid[q] } }
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
      elif prot=$(resolved_protection "$phys") && [ -n "$prot" ]; then
        verdict=spared why="resolved program: $prot"
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
read_procs "$WORK/names" > "$WORK/procs" || procs_ok=0
[ -s "$WORK/procs" ] || procs_ok=0
[ "$swap_ok" = 1 ] || echo "memory-guard: swap could not be read on $os" >&2
[ "$procs_ok" = 1 ] || echo "memory-guard: the process table could not be read" >&2

top_pid=- top_rss=- top_comm=-
if [ "$procs_ok" = 1 ]; then
  IFS=$'\t' read -r top_pid top_rss top_comm < <(awk -F'\t' '$5 + 0 > best { best = $5 + 0; p = $1; c = $7 } END { if (p != "") printf "%s\t%d\t%s\n", p, best / 1024, c }' "$WORK/procs")
  [ -n "$top_pid" ] || { top_pid=- top_rss=- top_comm=-; }
fi

# Sustained window bookkeeping: rewrite the seen file from this sample.
: > "$WORK/seen"
: > "$WORK/sustained"
if [ "$procs_ok" = 1 ]; then
  awk -F'\t' -v now="$now" -v lim="$proc_rss_mb" -v sus="$proc_sustained_secs" -v gap="$WINDOW_GAP_SECS" -v slack="$START_SLACK_SECS" \
      -v seen="$SEEN" -v sout="$WORK/seen" -v susout="$WORK/sustained" '
    BEGIN { while ((getline l < seen) > 0) { split(l, f, "\t"); if (f[1] ~ /^[0-9]+$/) { st[f[1]] = f[2]; fs[f[1]] = f[3]; ls[f[1]] = f[4] } } }
    $5 / 1024 >= lim + 0 {
      pid = $1; start = now - $6; first = now
      if ((pid in st) && (start - st[pid] <= slack) && (st[pid] - start <= slack) && (now - ls[pid] <= gap)) { first = fs[pid]; start = st[pid] }
      printf "%s\t%s\t%s\t%s\n", pid, start, first, now > sout
      held = now - first
      if (held >= sus + 0) printf "%s\t%d\t%d\t%s\n", pid, $5 / 1024, held, $7 > susout
    }' "$WORK/procs"
  mv -f "$WORK/seen" "$SEEN" 2>/dev/null || echo "memory-guard: cannot write $SEEN" >&2
fi

watched=0
[ "$procs_ok" = 1 ] && [ "$(awk -F'\t' -v lim="$proc_rss_mb" '$5 / 1024 >= lim + 0 { n++ } END { print n + 0 }' "$WORK/procs")" -gt 0 ] && watched=1
swap_alarm=0
[ "$swap_ok" = 1 ] && [ "$swap_mb" -ge "$swap_warn_mb" ] && swap_alarm=1

# Decide each sustained process: reap or spare.
actions=''
: > "$WORK/verdicts"
if [ -s "$WORK/sustained" ]; then
  cut -f 1 "$WORK/sustained" > "$WORK/cands"
  SELF_PIDS=$(self_pids)
  judge "$WORK/cands" < "$WORK/procs" > "$WORK/verdicts"
fi

verdict_of() { awk -F'\t' -v p="$1" '$1 == p { print $2 "\t" $3; exit }' "$WORK/verdicts"; }

# still_same <pid>: a fresh read just before the signal still shows the
# sampled process (same uid, parent, command name, and arguments, and an
# elapsed time that only moved forward) and still judges it eligible.
still_same() {
  local pid=$1 was is
  printf '%s\n' "$pid" > "$WORK/recand"
  read_procs "$WORK/names-fresh" > "$WORK/fresh" 2>/dev/null || return 1
  was=$(awk -F'\t' -v p="$pid" '$1 == p { print $2 "\t" $3 "\t" $7 "\t" $8 "\t" $6; exit }' "$WORK/procs")
  is=$(awk -F'\t' -v p="$pid" '$1 == p { print $2 "\t" $3 "\t" $7 "\t" $8 "\t" $6; exit }' "$WORK/fresh")
  [ -n "$was" ] && [ -n "$is" ] || return 1
  [ "${was%$'\t'*}" = "${is%$'\t'*}" ] || return 1
  [ "${is##*$'\t'}" -ge $(( ${was##*$'\t'} - START_SLACK_SECS )) ] || return 1
  [ $(( ${is##*$'\t'} - ${was##*$'\t'} )) -le "$RECHECK_MAX_SECS" ] || return 1
  [ "$(judge "$WORK/recand" < "$WORK/fresh" | cut -f 2)" = eligible ]
}

: > "$WORK/alarm-lines"
: > "$WORK/alarm-keys"
add_alarm() {  # <key> <line>
  printf '%s\n' "$1" >> "$WORK/alarm-keys"
  printf '%s\t%s\n' "$1" "$2" >> "$WORK/alarm-lines"
}

if [ "$swap_alarm" = 1 ]; then
  line="swap used ${swap_mb} MB is at or over ${swap_warn_mb} MB"
  [ "$top_pid" = - ] || line="$line; the largest process is pid $top_pid ($top_comm) at $top_rss MB"
  add_alarm swap "$line. A swap alarm alone stops nothing."
fi

while IFS=$'\t' read -r pid rss held comm; do
  [ -n "$pid" ] || continue
  start=$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$SEEN" 2>/dev/null)
  line="pid $pid ($comm) has held $rss MB, at or over $proc_rss_mb MB, for $held s (limit $proc_sustained_secs s)"
  IFS=$'\t' read -r verdict reason <<EOF
$(verdict_of "$pid")
EOF
  if [ "$mode" != reap-scratch ]; then
    line="$line. Mode observe: nothing was stopped."
  elif [ "$verdict" = eligible ] && ! still_same "$pid"; then
    actions="$actions${actions:+,}spared:$pid"
    line="$line. Mode reap-scratch: spared (changed since the sample); nothing was stopped."
  elif [ "$verdict" = eligible ]; then
    if kill -TERM "$pid" 2>/dev/null; then
      actions="$actions${actions:+,}term:$pid"
      line="$line. Mode reap-scratch: sent SIGTERM to this scratch process."
    else
      actions="$actions${actions:+,}term-failed:$pid"
      line="$line. Mode reap-scratch: SIGTERM failed."
    fi
  else
    actions="$actions${actions:+,}spared:$pid"
    line="$line. Mode reap-scratch: spared (${reason:-unclassified}); nothing was stopped."
  fi
  add_alarm "proc:$pid:${start:-0}" "$line"
done < "$WORK/sustained"
[ -n "$actions" ] || actions=none

if [ "$swap_ok" = 0 ] && [ "$procs_ok" = 0 ]; then status=unreadable
elif [ -s "$WORK/alarm-keys" ]; then status=alarm
elif [ "$watched" = 1 ]; then status=watch
else status=ok
fi

# Deduplicate: print an alarm only when it is new or older than the repeat time.
: > "$WORK/alarms-next"
: > "$WORK/printed"
while IFS=$'\t' read -r key line; do
  [ -n "$key" ] || continue
  last=$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$ALARMS" 2>/dev/null)
  # An alarm that took or failed an action is always printed.
  case "$last" in *[!0-9]*) last='' ;; esac
  if [ -z "$last" ] || [ $((now - last)) -ge "$alarm_repeat_secs" ] || { case "$line" in *SIGTERM*) true ;; *) false ;; esac; }; then
    printf '%s\n' "$line" >> "$WORK/printed"
    last=$now
  fi
  printf '%s\t%s\n' "$key" "$last" >> "$WORK/alarms-next"
done < "$WORK/alarm-lines"
mv -f "$WORK/alarms-next" "$ALARMS" 2>/dev/null || echo "memory-guard: cannot write $ALARMS" >&2

# Record the sample and keep the log bounded.
record_ok=1
tsv_comm=$(printf '%s' "$top_comm" | tr '\t\n' '  ')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$swap_mb" "$top_pid" "$top_rss" "$tsv_comm" "$status" "$actions" >> "$LOG" || record_ok=0
if [ "$record_ok" = 1 ] && [ "$(wc -l < "$LOG" | tr -d ' ')" -gt "$log_max_rows" ]; then
  if tail -n "$log_max_rows" "$LOG" > "$WORK/log" && mv -f "$WORK/log" "$LOG"; then :; else record_ok=0; fi
fi
[ "$record_ok" = 1 ] || echo "memory-guard: cannot record the sample in $LOG" >&2

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
[ "$status" != unreadable ] && [ "$record_ok" = 1 ] || exit 1
exit 0
