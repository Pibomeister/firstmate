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
# Each fill uses its own staging files, so two fills in one shell cannot publish each other's output.
# A replay reads stdout and stderr before it emits either.
# A missing stream or a failed read is a miss, emits nothing, and the caller runs the CLI.
# Pending generation invalidation bypasses replay; a failed generation write
# retains its lock until recovery can publish a new generation.
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

fm_orca_cli_current_pid() { # <output-variable>
  local _fm_orca_pid_value=${BASHPID:-}
  [ -n "$_fm_orca_pid_value" ] || _fm_orca_pid_value=$(exec /bin/sh -c 'echo "$PPID"')
  printf -v "$1" '%s' "$_fm_orca_pid_value"
}

fm_orca_cli_lock_identity() { # <lockdir>: PID and unique owner marker
  local lock=$1 pid='' token='' marker suffix count=0
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  for marker in "$lock"/owner.*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    token=${marker##*/}
    case "$token" in owner.*.*) ;; *) return 1 ;; esac
    suffix=${token#owner.}
    pid=${suffix%%.*}
    suffix=${suffix#*.}
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "${#pid}" -le 10 ] || return 1
    case "$suffix" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\t%s\n' "$pid" "$token"
}

fm_orca_cli_lock_owned() { # <lockdir> <owner-marker>
  local identity pid token current
  identity=$(fm_orca_cli_lock_identity "$1") || return 1
  IFS=$'\t' read -r pid token <<< "$identity"
  fm_orca_cli_current_pid current
  [ "$pid" = "$current" ] && [ "$token" = "$2" ]
}

# Age never displaces a live owner. Unknown ownership falls back to the CLI.
# Dead-owner recovery is serialized by that owner's unique marker.
fm_orca_cli_lock_acquire() { # <lockdir> [legacy-age] [owner-output-variable]
  local lock=$1 output=${3:-} identity pid token current claim='' marker old_token='' new_token
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    identity=$(fm_orca_cli_lock_identity "$lock") || return 2
    IFS=$'\t' read -r pid token <<< "$identity"
    fm_orca_cli_current_pid current
    [ "$pid" != "$current" ] || return 2
    kill -0 "$pid" 2>/dev/null && return 1
    claim="$lock.reclaim.$token"
    mkdir "$claim" 2>/dev/null || return 2
    if [ "$(fm_orca_cli_lock_identity "$lock" 2>/dev/null)" != "$identity" ] \
      || kill -0 "$pid" 2>/dev/null; then
      rmdir "$claim" 2>/dev/null || true
      return 1
    fi
    old_token=$token
  else
    mkdir "$lock" 2>/dev/null || return 1
  fi
  fm_orca_cli_current_pid current
  marker=$(mktemp "$lock/owner.$current.XXXXXXXXXXXX") || {
    [ -z "$claim" ] || rmdir "$claim" 2>/dev/null || true
    return 2
  }
  new_token=${marker##*/}
  if [ -n "$old_token" ] && ! rm -f "$lock/$old_token"; then
    rm -f "$marker" 2>/dev/null || true
    rmdir "$claim" 2>/dev/null || true
    return 2
  fi
  [ -z "$claim" ] || rmdir "$claim" 2>/dev/null || true
  [ -z "$output" ] || printf -v "$output" '%s' "$new_token"
  return 0
}

fm_orca_cli_lock_release() { # <lockdir> [owner-marker]
  local lock=$1 expected=${2:-} identity pid token current
  identity=$(fm_orca_cli_lock_identity "$lock") || return 0
  IFS=$'\t' read -r pid token <<< "$identity"
  fm_orca_cli_current_pid current
  [ "$pid" = "$current" ] || return 0
  [ -z "$expected" ] || [ "$token" = "$expected" ] || return 0
  rm -rf "$lock" 2>/dev/null || true
}

fm_orca_cli_cache_invalidate() {
  local dir lock gen next old i stage held_token='' lock_rc pending_output=${1:-} pending_token=${2:-}
  [ -z "$pending_output" ] || printf -v "$pending_output" '%s' ''
  fm_orca_cli_cache_enabled || return 0
  dir=$(fm_orca_cli_cache_prepare) || return 0
  lock=$dir/gen.lock
  if [ -n "$pending_token" ] && fm_orca_cli_lock_owned "$lock" "$pending_token"; then
    held_token=$pending_token
  else
    i=0
    while :; do
      if fm_orca_cli_lock_acquire "$lock" 15 held_token; then break; else lock_rc=$?; fi
      [ "$lock_rc" -eq 1 ] || return 1
      i=$((i + 1))
      [ "$i" -gt 40 ] && return 1
      sleep 0.05
    done
  fi
  [ -z "$pending_output" ] || printf -v "$pending_output" '%s' "$held_token"
  if [ -e "$dir/gen" ] || [ -L "$dir/gen" ]; then
    [ -f "$dir/gen" ] && [ ! -L "$dir/gen" ] || return 1
  fi
  gen=$(fm_orca_cli_read_gen "$dir")
  next=$((gen + 1))
  stage=$(mktemp "$dir/staging/gen.XXXXXX") || return 1
  if ! printf '%s\n' "$next" > "$stage" \
    || ! fm_orca_cli_lock_owned "$lock" "$held_token" \
    || ! mv -f "$stage" "$dir/gen"; then
    rm -f "$stage"
    return 1
  fi
  if [ -d "$dir/g" ]; then
    for old in "$dir/g"/*; do
      [ -e "$old" ] || continue
      [ "$(basename "$old")" = "$next" ] && continue
      rm -rf "$old"
    done
  fi
  fm_orca_cli_lock_release "$lock" "$held_token"
  [ -z "$pending_output" ] || printf -v "$pending_output" '%s' ''
  return 0
}

# Drop cached reads before a state change and again after it, whatever its
# exit status, so a read from before the change cannot be reused while it
# runs or after it finishes.
fm_orca_cli_mutation() { # <command...>
  local rc=0 pending_generation=''
  fm_orca_cli_cache_invalidate pending_generation || true
  "$@" || rc=$?
  fm_orca_cli_cache_invalidate pending_generation "$pending_generation" || true
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
  local dir=$1 key=$2 gen entry now exp rc out err
  [ ! -e "$dir/gen.lock" ] && [ ! -L "$dir/gen.lock" ] || return 1
  gen=$(fm_orca_cli_read_gen "$dir")
  entry=$dir/g/$gen/$key
  [ -f "$entry/stdout" ] && [ -f "$entry/stderr" ] && [ -f "$entry/rc" ] && [ -f "$entry/expires" ] || return 1
  now=$(date +%s)
  exp=$(tr -cd '0-9' < "$entry/expires")
  case "$exp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$now" -lt "$exp" ] || return 1
  rc=$(tr -cd '0-9' < "$entry/rc")
  [ "$rc" = 0 ] || return 1
  # Both reads finish before either stream is written. A miss after a partial
  # write would prepend the cached body to the fresh CLI result.
  # The trailing x keeps the command substitution from stripping newlines.
  out=$(cat "$entry/stdout" 2>/dev/null && printf '%s' x) || return 1
  err=$(cat "$entry/stderr" 2>/dev/null && printf '%s' x) || return 1
  printf '%s' "${out%x}"
  printf '%s' "${err%x}" >&2
  return 0
}

fm_orca_cli_fill() { # <dir> <key> <lock> <owner-marker> <orca-args...>
  local dir=$1 key=$2 lock=$3 held_token=$4
  shift 4
  local gen outf errf rc cacheable ttl now nowgen stage dest
  gen=$(fm_orca_cli_read_gen "$dir")
  outf=$(mktemp "$dir/staging/out.XXXXXX") || {
    fm_orca_cli_lock_release "$lock" "$held_token"
    command orca "$@" || return $?
    return 0
  }
  errf=$(mktemp "$dir/staging/err.XXXXXX") || {
    rm -f "$outf"
    fm_orca_cli_lock_release "$lock" "$held_token"
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
    if [ "$nowgen" = "$gen" ] && fm_orca_cli_lock_owned "$lock" "$held_token"; then
      now=$(date +%s)
      stage=$(mktemp -d "$dir/staging/pub.XXXXXX") || stage=
      dest=$dir/g/$gen/$key
      if [ -n "$stage" ] \
        && cp "$outf" "$stage/stdout" \
        && cp "$errf" "$stage/stderr" \
        && printf '%s\n' "$rc" > "$stage/rc" \
        && printf '%s\n' $((now + ttl)) > "$stage/expires" \
        && mkdir -p "$dir/g/$gen" \
        && fm_orca_cli_lock_owned "$lock" "$held_token" \
        && rm -rf "$dest" \
        && mv "$stage" "$dest"; then
        :
      elif [ -n "$stage" ]; then
        rm -rf "$stage"
      fi
    fi
  fi
  rm -f "$outf" "$errf"
  fm_orca_cli_lock_release "$lock" "$held_token"
  return "$rc"
}

fm_orca_cli_cached() {
  local key dir lock i held_token='' lock_rc
  if [ "$(fm_orca_cli_ttl)" -eq 0 ]; then
    command orca "$@" || return $?
    return 0
  fi
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
  if fm_orca_cli_lock_acquire "$lock" 15 held_token; then
    :
  else
    lock_rc=$?
    if [ "$lock_rc" -eq 2 ]; then
      command orca "$@" || return $?
      return 0
    fi
    i=0
    while [ "$i" -lt 60 ]; do
      if fm_orca_cli_try_replay "$dir" "$key"; then
        return 0
      fi
      [ -d "$lock" ] || break
      sleep 0.05
      i=$((i + 1))
    done
    if ! fm_orca_cli_lock_acquire "$lock" 15 held_token; then
      command orca "$@" || return $?
      return 0
    fi
  fi
  if fm_orca_cli_try_replay "$dir" "$key"; then
    fm_orca_cli_lock_release "$lock" "$held_token"
    return 0
  fi
  fm_orca_cli_fill "$dir" "$key" "$lock" "$held_token" "$@"
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
