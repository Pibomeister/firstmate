#!/usr/bin/env bash
# fm-host-ledger.sh - local per-minute host load ledger (scale plan S0) and the
# S4 exec-cost microbench plus process/file limits read.
#
# Usage:
#   fm-host-ledger.sh sample
#       Append one TSV row for now and print it. Run it from launchd or cron
#       once a minute on each host. It is cheap by design: one ps snapshot,
#       one df, one swap read, and (unless FM_HOST_LEDGER_NO_TOP=1) one
#       two-sample top for the user/sys/idle split.
#   fm-host-ledger.sh report [--hours <N>]
#       Summarize the last <N> hours (default 24): row count, peak new-pid
#       rate, peak load1, lowest free disk, and peak live workers per CLI.
#   fm-host-ledger.sh microbench [--n <N>]
#       Time repeated execs three ways (default N=100): a cached system
#       binary, the same throwaway script path, and a fresh script path per
#       exec (the file write is included, so that row is an upper bound on a
#       first-exec check). Run it at a quiet time; it prints the load too.
#   fm-host-ledger.sh limits
#       Print kern.maxproc, kern.maxprocperuid, kern.maxfiles,
#       kern.num_taskthreads, the launchctl maxproc/maxfiles limits, and this
#       shell's ulimit -u -n. Read-only. On Linux it prints /proc/sys reads.
#   fm-host-ledger.sh --help
#
# Files: ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/host-ledger/
#   ledger-YYYY-MM-DD.tsv   one row per sample, header row first
#   prev-pids.tsv           previous sample's pid/ppid/comm snapshot
# FM_HOST_LEDGER_DIR overrides that directory.
#
# Columns: ts_epoch, load1, procs, new_pids, interval_s, new_per_s,
# cpu_user, cpu_sys, cpu_idle, swap_used_mib, disk_free_kib, cli, parents.
# Unknown values are the word unknown. new_pids counts pids present now that
# were absent at the previous sample, so processes that lived and died
# between samples are missed: new_per_s is a floor on the true launch rate,
# and parents (the surviving new pids grouped by parent, top 5) is biased
# toward long-lived children. True per-parent launch accounting needs a
# privileged exec tracer, which this unprivileged sampler deliberately is not.
# cli is name=count:rss_kib for each known agent CLI process basename
# (claude, codex, grok, muse, droid, cursor-agent, agy, kimi, opencode), so
# active RSS per CLI is measured. Token use is not visible from the process
# table and is never guessed here; tokens per active-agent-hour must join
# this ledger's worker counts with the harnesses' own usage records.
#
# Exit: 0 on success, 2 on a usage error. A failed probe degrades its own
# column to unknown and still writes the row, because a gap in the ledger is
# worse than one unknown cell. The one exception is an unwritable ledger
# directory, which exits 1 with the reason on stderr.
set -u

LEDGER_DIR=${FM_HOST_LEDGER_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/host-ledger}
VOLUME=${FM_HOST_LEDGER_VOLUME:-/System/Volumes/Data}
[ -d "$VOLUME" ] || VOLUME=/

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  echo "usage: fm-host-ledger.sh sample|report [--hours N]|microbench [--n N]|limits|--help" >&2
  exit 2
}

load1_read() {
  local raw
  raw=$(sysctl -n vm.loadavg 2>/dev/null) || raw=
  if [ -n "$raw" ]; then
    printf '%s\n' "$raw" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+$/) { print $i; exit } }'
    return 0
  fi
  if [ -r /proc/loadavg ]; then
    awk '{ print $1 }' /proc/loadavg
    return 0
  fi
  uptime 2>/dev/null | sed -n 's/.*load averages\{0,1\}: \{0,1\}\([0-9][0-9.]*\).*/\1/p'
}

swap_used_mib_read() {
  local raw
  raw=$(sysctl -n vm.swapusage 2>/dev/null) || raw=
  if [ -n "$raw" ]; then
    printf '%s\n' "$raw" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p'
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    awk '/^SwapTotal:/ { t=$2 } /^SwapFree:/ { f=$2 } END { if (t != "") printf "%d\n", (t-f)/1024 }' /proc/meminfo
  fi
}

disk_free_kib_read() {
  df -Pk "$VOLUME" 2>/dev/null | awk 'NR==2 { print $4 }'
}

cpu_split_read() {
  # Prints "user sys idle" percentages for the sampling interval, or nothing.
  if [ "${FM_HOST_LEDGER_NO_TOP:-}" = 1 ]; then
    return 0
  fi
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    top -l 2 -s 1 -n 0 2>/dev/null | awk '
      /^CPU usage/ { u=$3; s=$5; i=$7 }
      END { if (u != "") { gsub(/%/, "", u); gsub(/%/, "", s); gsub(/%/, "", i); print u, s, i } }'
  fi
}

# Builds the current snapshot (pid ppid rss comm-path tail) into $1 and
# prints "procs cli" for it. comm is truncated at the first space by ps
# itself on some platforms, so only its basename is ever used.
snapshot_build() {
  local snap=$1
  ps -axo pid=,ppid=,rss=,comm= 2>/dev/null > "$snap" || return 1
  awk '
    function base(p) { sub(/.*\//, "", p); return p }
    BEGIN { split("claude codex grok muse droid cursor-agent agy kimi opencode", names, " ") }
    {
      n++
      b = base($4)
      for (k in names) if (b == names[k]) { cnt[b]++; rss[b] += $3 }
    }
    END {
      out = ""
      for (k in names) if (cnt[names[k]] > 0) out = out (out == "" ? "" : ",") names[k] "=" cnt[names[k]] ":" rss[names[k]]
      print n, (out == "" ? "none" : out)
    }' "$snap"
}

# Prints "new_pids parents" comparing snapshot $2 (current) against $1 (prev).
new_pids_calc() {
  local prev=$1 cur=$2
  if [ ! -s "$prev" ]; then
    printf 'unknown unknown\n'
    return 0
  fi
  awk '
    function base(p) { sub(/.*\//, "", p); return p }
    NR == FNR { seen[$1] = 1; comm[$1] = base($4); next }
    !($1 in seen) { new++; p = comm[$2]; if (p == "") p = "pid" $2; par[p]++ }
    { comm[$1] = base($4) }
    END {
      out = ""
      # top 5 parents by count, count descending then name ascending
      for (i = 0; i < 5; i++) {
        best = ""; bestn = 0
        for (p in par) if (!(p in picked) && (par[p] > bestn || (par[p] == bestn && (best == "" || p < best)))) { best = p; bestn = par[p] }
        if (best == "") break
        picked[best] = 1
        out = out (out == "" ? "" : ",") best "=" bestn
      }
      print (new + 0), (out == "" ? "none" : out)
    }' "$prev" "$cur"
}

cmd_sample() {
  mkdir -p "$LEDGER_DIR" 2>/dev/null || {
    echo "fm-host-ledger: cannot create $LEDGER_DIR" >&2
    exit 1
  }
  local ts day file prev cur_tmp snap now prev_ts interval new_per_s
  ts=$(date +%s)
  day=$(date +%F)
  file="$LEDGER_DIR/ledger-$day.tsv"
  prev="$LEDGER_DIR/prev-pids.tsv"
  cur_tmp="$LEDGER_DIR/.cur-pids.$$"
  snap=$(snapshot_build "$cur_tmp") || snap=
  local procs cli new_pids parents load1 swap free_kib cpu cu cs ci
  procs=$(printf '%s' "$snap" | awk '{ print $1 }')
  cli=$(printf '%s' "$snap" | awk '{ print $2 }')
  read -r new_pids parents <<EOF
$(new_pids_calc "$prev" "$cur_tmp")
EOF
  [ -n "$new_pids" ] || new_pids=unknown
  [ -n "$parents" ] || parents=unknown
  prev_ts=$(stat -f %m "$prev" 2>/dev/null || stat -c %Y "$prev" 2>/dev/null || printf '')
  interval=unknown
  new_per_s=unknown
  if [ -n "$prev_ts" ] && [ "$new_pids" != unknown ]; then
    interval=$((ts - prev_ts))
    if [ "$interval" -gt 0 ] 2>/dev/null; then
      new_per_s=$(awk -v n="$new_pids" -v s="$interval" 'BEGIN { printf "%.2f", n / s }')
    fi
  fi
  mv -f "$cur_tmp" "$prev" 2>/dev/null || rm -f "$cur_tmp"
  load1=$(load1_read)
  swap=$(swap_used_mib_read)
  free_kib=$(disk_free_kib_read)
  cpu=$(cpu_split_read)
  cu=$(printf '%s' "$cpu" | awk '{ print $1 }')
  cs=$(printf '%s' "$cpu" | awk '{ print $2 }')
  ci=$(printf '%s' "$cpu" | awk '{ print $3 }')
  [ -n "$procs" ] || procs=unknown
  [ -n "$cli" ] || cli=unknown
  [ -n "$load1" ] || load1=unknown
  [ -n "$swap" ] || swap=unknown
  [ -n "$free_kib" ] || free_kib=unknown
  [ -n "$cu" ] || { cu=unknown; cs=unknown; ci=unknown; }
  if [ ! -s "$file" ]; then
    printf 'ts_epoch\tload1\tprocs\tnew_pids\tinterval_s\tnew_per_s\tcpu_user\tcpu_sys\tcpu_idle\tswap_used_mib\tdisk_free_kib\tcli\tparents\n' >> "$file" || {
      echo "fm-host-ledger: cannot write $file" >&2
      exit 1
    }
  fi
  now=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$ts" "$load1" "$procs" "$new_pids" "$interval" "$new_per_s" \
    "$cu" "$cs" "$ci" "$swap" "$free_kib" "$cli" "$parents")
  printf '%s\n' "$now" >> "$file" || {
    echo "fm-host-ledger: cannot write $file" >&2
    exit 1
  }
  printf 'host-ledger: %s file=%s\n' "$now" "$file"
}

cmd_report() {
  local hours=24
  if [ "${1:-}" = --hours ]; then
    hours=${2:-}
    case "$hours" in ''|*[!0-9]*) die_usage ;; esac
  elif [ $# -ne 0 ]; then
    die_usage
  fi
  local cutoff files
  cutoff=$(( $(date +%s) - hours * 3600 ))
  files=$(ls "$LEDGER_DIR"/ledger-*.tsv 2>/dev/null)
  if [ -z "$files" ]; then
    echo "host-ledger: no ledger files in $LEDGER_DIR"
    exit 0
  fi
  # shellcheck disable=SC2086
  awk -F '\t' -v cutoff="$cutoff" '
    $1 == "ts_epoch" { next }
    $1 + 0 < cutoff { next }
    {
      rows++
      if ($6 ~ /^[0-9.]+$/ && $6 + 0 > peak_rate) peak_rate = $6 + 0
      if ($2 ~ /^[0-9.]+$/ && $2 + 0 > peak_load) peak_load = $2 + 0
      if ($11 ~ /^[0-9]+$/ && (min_free == "" || $11 + 0 < min_free)) min_free = $11 + 0
      if ($11 ~ /^[0-9]+$/) last_free = $11 + 0
      n = split($12, parts, ",")
      for (i = 1; i <= n; i++) {
        if (split(parts[i], kv, "=") == 2 && split(kv[2], cr, ":") == 2) {
          if (cr[1] + 0 > peak_cnt[kv[1]]) peak_cnt[kv[1]] = cr[1] + 0
          if (cr[2] + 0 > peak_rss[kv[1]]) peak_rss[kv[1]] = cr[2] + 0
        }
      }
    }
    END {
      printf "host-ledger report: rows=%d peak_new_per_s=%.2f peak_load1=%.2f min_disk_free_kib=%s last_disk_free_kib=%s\n", \
        rows + 0, peak_rate + 0, peak_load + 0, (min_free == "" ? "unknown" : min_free), (last_free == "" ? "unknown" : last_free)
      for (name in peak_cnt) printf "host-ledger cli: %s peak_count=%d peak_rss_kib=%d\n", name, peak_cnt[name], peak_rss[name]
    }' $files
}

cmd_microbench() {
  local n=100
  if [ "${1:-}" = --n ]; then
    n=${2:-}
    case "$n" in ''|*[!0-9]*) die_usage ;; esac
  elif [ $# -ne 0 ]; then
    die_usage
  fi
  command -v perl >/dev/null 2>&1 || {
    echo "fm-host-ledger: microbench needs perl" >&2
    exit 1
  }
  echo "host-microbench: load1=$(load1_read) n=$n (run at a quiet time for gate numbers)"
  FM_MICRO_N="$n" perl -MTime::HiRes=time -e '
    my $n = $ENV{FM_MICRO_N} // 100;
    my $true = -x "/usr/bin/true" ? "/usr/bin/true" : "/bin/true";
    my $dir = "/tmp/fm-microbench-$$";
    mkdir $dir or die "mkdir $dir: $!";
    sub bench {
      my ($label, $code) = @_;
      my $t0 = time();
      $code->($_) for 1..$n;
      printf "host-microbench: %s ms_per_exec=%.3f n=%d\n", $label, (time() - $t0) / $n * 1000, $n;
    }
    bench("cached_binary", sub { system($true) == 0 or die "exec $true failed" });
    my $cached = "$dir/cached.sh";
    open my $fh, ">", $cached or die $!; print $fh "#!/bin/sh\nexit 0\n"; close $fh; chmod 0755, $cached;
    bench("cached_script", sub { system($cached) == 0 or die "exec cached failed" });
    bench("fresh_script_with_write", sub {
      my $p = "$dir/fresh-$_.sh";
      open my $f, ">", $p or die $!; print $f "#!/bin/sh\nexit 0\n"; close $f; chmod 0755, $p;
      system($p) == 0 or die "exec fresh failed";
    });
    bench("bash_c_true", sub { system("/bin/bash", "-c", "true") == 0 or die "bash failed" });
    unlink glob "$dir/*"; rmdir $dir;
  '
}

cmd_limits() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    sysctl kern.maxproc kern.maxprocperuid kern.maxfiles kern.num_taskthreads 2>&1
    launchctl limit 2>/dev/null | awk '$1 == "maxproc" || $1 == "maxfiles" { print "launchctl " $0 }'
  else
    for f in /proc/sys/kernel/pid_max /proc/sys/fs/file-max /proc/sys/fs/inotify/max_user_instances; do
      [ -r "$f" ] && printf '%s: %s\n' "$f" "$(cat "$f")"
    done
  fi
  printf 'ulimit -u: %s\n' "$(ulimit -u)"
  printf 'ulimit -n: %s\n' "$(ulimit -n)"
}

case "${1:-}" in
  sample) shift; [ $# -eq 0 ] || die_usage; cmd_sample ;;
  report) shift; cmd_report "$@" ;;
  microbench) shift; cmd_microbench "$@" ;;
  limits) shift; [ $# -eq 0 ] || die_usage; cmd_limits ;;
  --help|-h) usage ;;
  *) die_usage ;;
esac
