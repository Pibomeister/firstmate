#!/usr/bin/env bash
# bin/fm-orca-cli-cache.sh - short-TTL shared cache for read-only Orca CLI calls.
#
# Supervision homes each boot the Orca CLI for the same read-only facts.
# This file is the only owner of reusing those results.
#
# fm_orca_cli runs `command orca` with the given arguments. A read-only
# command whose exit status is 0, and whose stdout is not JSON with
# `"ok":false`, is reused for FM_ORCA_CLI_CACHE_TTL seconds (default 3).
# A mutating command is never stored and drops every cached result before it
# runs and again after it finishes. `terminal wait` is neither stored nor a mutation. Any other command
# is run as-is and leaves the cache untouched.
#
# Cached reads: status; diagnostics memory; repo show; worktree list and
# show; terminal list, read, and show.
# Mutations: repo add; worktree create, rm, and set; terminal send, create,
# close, and focus; agent launch.
#
# The cache is on unless FM_ORCA_CLI_CACHE is 0, off, or false, or it is
# unset while FM_TEST_SEAM=1. FM_ORCA_CLI_CACHE=1, on, or true forces it on.
# A disabled cache does not read, write, or invalidate the directory, so a
# test cannot wipe a live host cache. FM_ORCA_CLI_CACHE_TTL=0 skips storage
# and reuse but still honors an explicit on/off switch.
#
# Entries live under
# ${FM_ORCA_CLI_CACHE_DIR:-${TMPDIR:-/tmp}/fm-orca-cli-cache-<uid>}/g/<gen>/<key>/.
# A cache directory that is a symlink or that another user owns is never
# used; calls then run the CLI directly.
# A mutation bumps <gen> under gen.lock. A writer publishes only when the
# generation is still the one it captured, so a result from before the
# mutation cannot replace a later read. The key is the sha256 of the resolved
# orca binary plus a NUL before each argument, so a test fake cannot collide
# with the installed CLI. Identical calls share one in-flight run.
#
# A failed read is not stored. Callers that need a fresh answer after an
# outage retry the CLI.
#
# fm_orca_terminal_exists <id> prints nothing. Exit 0 means the id is in a
# complete terminal list. Exit 1 means a complete list omitted it. Exit 2
# means the list cannot be trusted (truncated, unreadable, failed, or the
# cache is disabled). A disabled cache returns 2 without calling the CLI,
# so the caller keeps its one-line terminal read.

if [ -n "${FM_ORCA_CLI_CACHE_SOURCED:-}" ]; then
  return 0
fi
FM_ORCA_CLI_CACHE_SOURCED=1

fm_orca_cli_cache_enabled() {
  case "${FM_ORCA_CLI_CACHE:-}" in
    0|off|false) return 1 ;;
    1|on|true) return 0 ;;
  esac
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    return 1
  fi
  return 0
}

fm_orca_cli_cache_dir() {
  if [ -n "${FM_ORCA_CLI_CACHE_DIR:-}" ]; then
    printf '%s' "$FM_ORCA_CLI_CACHE_DIR"
    return 0
  fi
  printf '%s' "${TMPDIR:-/tmp}/fm-orca-cli-cache-$(id -u)"
}

fm_orca_cli_ttl() {
  local t
  t=${FM_ORCA_CLI_CACHE_TTL:-3}
  case "$t" in
    ''|*[!0-9]*) printf '3' ;;
    *) printf '%s' "$t" ;;
  esac
}

fm_orca_cli_mtime() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || m=0
  case "$m" in
    ''|*[!0-9]*) m=0 ;;
  esac
  printf '%s' "$m"
}

fm_orca_cli_read_gen() {
  local raw
  raw=0
  if [ -f "$1/gen" ]; then
    raw=$(tr -cd '0-9' < "$1/gen")
  fi
  case "$raw" in
    ''|*[!0-9]*) raw=0 ;;
  esac
  printf '%s' "$raw"
}

fm_orca_cli_cache_prepare() {
  local dir old
  dir=$(fm_orca_cli_cache_dir)
  old=$(umask)
  umask 077
  mkdir -p "$dir" 2>/dev/null
  umask "$old"
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  chmod 700 "$dir" 2>/dev/null || return 1
  mkdir -p "$dir/locks" "$dir/g" "$dir/staging" || return 1
  printf '%s' "$dir"
}

# Steal only a lock whose directory is older than <stale> seconds.
fm_orca_cli_lock_acquire() { # <lockdir> <stale-secs>
  local lock=$1 stale=$2 now mtime age
  if mkdir "$lock" 2>/dev/null; then
    return 0
  fi
  now=$(date +%s)
  mtime=$(fm_orca_cli_mtime "$lock")
  [ "$mtime" -gt 0 ] || return 1
  age=$((now - mtime))
  [ "$age" -ge "$stale" ] || return 1
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then
    return 0
  fi
  return 1
}

fm_orca_cli_lock_release() {
  rmdir "$1" 2>/dev/null || rm -rf "$1"
}

fm_orca_cli_cache_invalidate() {
  local dir lock gen next old i
  fm_orca_cli_cache_enabled || return 0
  dir=$(fm_orca_cli_cache_prepare) || return 0
  lock=$dir/gen.lock
  i=0
  while ! fm_orca_cli_lock_acquire "$lock" 15; do
    i=$((i + 1))
    [ "$i" -gt 40 ] && return 0
    sleep 0.05
  done
  gen=$(fm_orca_cli_read_gen "$dir")
  next=$((gen + 1))
  printf '%s\n' "$next" > "$dir/gen.next.$$"
  mv -f "$dir/gen.next.$$" "$dir/gen"
  if [ -d "$dir/g" ]; then
    for old in "$dir/g"/*; do
      [ -e "$old" ] || continue
      [ "$(basename "$old")" = "$next" ] && continue
      rm -rf "$old"
    done
  fi
  fm_orca_cli_lock_release "$lock"
  return 0
}

# Run a command that changes Orca state, then drop the cache whatever its
# exit status, so a read that filled during the change cannot be reused.
fm_orca_cli_mutation() { # <command...>
  local rc=0
  "$@" || rc=$?
  fm_orca_cli_cache_invalidate
  return "$rc"
}

fm_orca_cli_cache_key() {
  local bin line
  bin=$(command -v orca) || return 1
  if command -v shasum >/dev/null 2>&1; then
    line=$(
      {
        printf '%s' "$bin"
        printf '\0'
        for arg in "$@"; do
          printf '%s' "$arg"
          printf '\0'
        done
      } | shasum -a 256
    ) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    line=$(
      {
        printf '%s' "$bin"
        printf '\0'
        for arg in "$@"; do
          printf '%s' "$arg"
          printf '\0'
        done
      } | sha256sum
    ) || return 1
  else
    return 1
  fi
  printf '%s' "${line%% *}"
}

# shellcheck disable=SC2016
fm_orca_cli_stdout_cacheable() {
  command -v node >/dev/null 2>&1 || return 1
  node -e '
const fs = require("fs");
let raw;
try { raw = fs.readFileSync(process.argv[1]); }
catch (err) { process.exit(1); }
if (raw.length === 0) process.exit(0);
let data;
try { data = JSON.parse(raw.toString("utf8")); }
catch (err) { process.exit(0); }
if (data && data.ok === false) process.exit(1);
process.exit(0);
' "$1"
}

fm_orca_cli_try_replay() { # <dir> <key> -> 0 hit, 1 miss
  local dir=$1 key=$2 gen entry now exp rc
  gen=$(fm_orca_cli_read_gen "$dir")
  entry=$dir/g/$gen/$key
  [ -f "$entry/stdout" ] && [ -f "$entry/rc" ] && [ -f "$entry/expires" ] || return 1
  now=$(date +%s)
  exp=$(tr -cd '0-9' < "$entry/expires")
  case "$exp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$now" -lt "$exp" ] || return 1
  rc=$(tr -cd '0-9' < "$entry/rc")
  [ "$rc" = 0 ] || return 1
  cat "$entry/stdout"
  if [ -f "$entry/stderr" ]; then
    cat "$entry/stderr" >&2
  fi
  return 0
}

fm_orca_cli_fill() { # <dir> <key> <lock> <orca-args...>
  local dir=$1 key=$2 lock=$3
  shift 3
  local gen outf errf rc cacheable ttl now nowgen stage dest
  gen=$(fm_orca_cli_read_gen "$dir")
  outf=$dir/staging/out.$$
  errf=$dir/staging/err.$$
  : > "$outf" || {
    fm_orca_cli_lock_release "$lock"
    command orca "$@" || return $?
    return 0
  }
  : > "$errf" || {
    rm -f "$outf"
    fm_orca_cli_lock_release "$lock"
    command orca "$@" || return $?
    return 0
  }
  rc=0
  command orca "$@" >"$outf" 2>"$errf" || rc=$?
  cat "$outf"
  cat "$errf" >&2
  cacheable=0
  ttl=$(fm_orca_cli_ttl)
  if [ "$rc" -eq 0 ] && [ "$ttl" -gt 0 ] && fm_orca_cli_stdout_cacheable "$outf"; then
    cacheable=1
  fi
  if [ "$cacheable" -eq 1 ]; then
    nowgen=$(fm_orca_cli_read_gen "$dir")
    if [ "$nowgen" = "$gen" ]; then
      now=$(date +%s)
      stage=$dir/staging/pub.$$
      mkdir -p "$stage" || true
      dest=$dir/g/$gen/$key
      if [ -d "$stage" ] \
        && cp "$outf" "$stage/stdout" \
        && cp "$errf" "$stage/stderr" \
        && printf '%s\n' "$rc" > "$stage/rc" \
        && printf '%s\n' $((now + ttl)) > "$stage/expires" \
        && mkdir -p "$dir/g/$gen" \
        && rm -rf "$dest" \
        && mv "$stage" "$dest"; then
        :
      else
        rm -rf "$stage"
      fi
    fi
  fi
  rm -f "$outf" "$errf"
  fm_orca_cli_lock_release "$lock"
  return "$rc"
}

fm_orca_cli_cached() {
  local key dir lock i
  key=$(fm_orca_cli_cache_key "$@") || {
    command orca "$@" || return $?
    return 0
  }
  dir=$(fm_orca_cli_cache_prepare) || {
    command orca "$@" || return $?
    return 0
  }
  if fm_orca_cli_try_replay "$dir" "$key"; then
    return 0
  fi
  lock=$dir/locks/$key
  if ! fm_orca_cli_lock_acquire "$lock" 15; then
    i=0
    while [ "$i" -lt 60 ]; do
      if fm_orca_cli_try_replay "$dir" "$key"; then
        return 0
      fi
      [ -d "$lock" ] || break
      sleep 0.05
      i=$((i + 1))
    done
    if ! fm_orca_cli_lock_acquire "$lock" 15; then
      command orca "$@" || return $?
      return 0
    fi
  fi
  if fm_orca_cli_try_replay "$dir" "$key"; then
    fm_orca_cli_lock_release "$lock"
    return 0
  fi
  fm_orca_cli_fill "$dir" "$key" "$lock" "$@"
}

fm_orca_cli_classify() {
  case "${1:-}" in
    status) printf 'read' ;;
    diagnostics)
      case "${2:-}" in
        memory) printf 'read' ;;
        *) printf 'pass' ;;
      esac
      ;;
    repo)
      case "${2:-}" in
        show) printf 'read' ;;
        add) printf 'mutate' ;;
        *) printf 'pass' ;;
      esac
      ;;
    worktree)
      case "${2:-}" in
        list|show) printf 'read' ;;
        create|rm|set) printf 'mutate' ;;
        *) printf 'pass' ;;
      esac
      ;;
    terminal)
      case "${2:-}" in
        list|read|show) printf 'read' ;;
        send|create|close|focus) printf 'mutate' ;;
        *) printf 'pass' ;;
      esac
      ;;
    agent)
      case "${2:-}" in
        launch) printf 'mutate' ;;
        *) printf 'pass' ;;
      esac
      ;;
    *) printf 'pass' ;;
  esac
}

fm_orca_cli() {
  local kind
  if ! fm_orca_cli_cache_enabled; then
    command orca "$@" || return $?
    return 0
  fi
  kind=$(fm_orca_cli_classify "$@")
  case "$kind" in
    mutate)
      fm_orca_cli_cache_invalidate
      fm_orca_cli_mutation command orca "$@"
      ;;
    read)
      fm_orca_cli_cached "$@"
      ;;
    *)
      command orca "$@" || return $?
      return 0
      ;;
  esac
}

# shellcheck disable=SC2016
fm_orca_terminal_exists() { # <terminal-id>
  local want=$1 out rc
  [ -n "$want" ] || return 2
  fm_orca_cli_cache_enabled || return 2
  command -v orca >/dev/null 2>&1 || return 2
  command -v node >/dev/null 2>&1 || return 2
  rc=0
  out=$(fm_orca_cli terminal list --json --limit 5000 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$out" ] || return 2
  printf '%s' "$out" | FM_ORCA_WANT=$want node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); }
catch (err) { process.exit(2); }
if (!data || data.ok === false) process.exit(2);
const result = data.result || {};
const terms = result.terminals;
if (!Array.isArray(terms)) process.exit(2);
if (result.truncated !== false) process.exit(2);
const want = process.env.FM_ORCA_WANT;
for (let i = 0; i < terms.length; i++) {
  const t = terms[i] || {};
  if (t.handle === want || t.id === want) process.exit(0);
}
process.exit(1);
'
}
