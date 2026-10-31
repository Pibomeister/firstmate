#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-endpoint discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane (an
# Orca terminal, or on t3code a T3 thread) runs firstmate itself, both to inject escalations
# into it and, for the daemon, to validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor endpoint target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# fm_supervisor_in_rex: this process runs directly inside a Rex block.
fm_supervisor_in_rex() {
  [ "${TERM_PROGRAM:-}" = rex ] && [ -n "${REX_SESSION:-}" ] && [ -n "${REX_BLOCK:-}" ]
}

# fm_supervisor_in_orca: this process runs directly inside an Orca terminal.
# Orca puts TERM_PROGRAM=Orca and ORCA_TERMINAL_HANDLE, the same term_<uuid>
# handle bin/backends/orca.sh records as a task target, into every terminal's
# process tree. A Zellij session started in that terminal keeps both markers
# while owning its screen, so its ZELLIJ marker disqualifies the rule.
fm_supervisor_in_orca() {
  [ "${TERM_PROGRAM:-}" = Orca ] && [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && [ -z "${ZELLIJ:-}" ]
}

# fm_supervisor_orca_refusal: on an Orca home where no earlier rule and no Orca
# terminal resolved the endpoint, print why and return 0, so both resolvers
# refuse instead of handing back the tmux default, which on such a home names
# some other tmux window or nothing. An Orca home is an explicit orca backend
# selection (fm_backend_explicit_name) or an inherited Orca terminal marker.
# Returns 1, printing nothing, on any other home.
fm_supervisor_orca_refusal() {
  local explicit=''
  if command -v fm_backend_explicit_name >/dev/null 2>&1; then
    explicit=$(fm_backend_explicit_name 2>/dev/null) || explicit=''
  fi
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    printf 'this process carries Orca terminal %s but does not run directly in it (TERM_PROGRAM=%s%s)' \
      "$ORCA_TERMINAL_HANDLE" "${TERM_PROGRAM:-unset}" "${ZELLIJ:+, inside Zellij}"
  elif [ "$explicit" = orca ]; then
    printf 'backend orca is selected but this process runs in no Orca terminal (ORCA_TERMINAL_HANDLE is unset)'
  else
    return 1
  fi
}

# discover_supervisor_target: resolve the endpoint running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - uses the exact tmux target
#      forms owned by bin/fm-backend.sh's fm_backend_target_exists header, a
#      herdr "<session>:<pane-id>" target, or a T3 thread id (paired with
#      discover_supervisor_backend to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. TERM_PROGRAM=rex + $REX_SESSION + $REX_BLOCK - Rex injects them into every
#      block's process tree; compose the "<session-uuid>:<block-uuid>" target
#      bin/backends/rex.sh records (both ids without their kind prefix).
#      Checked after tmux and herdr, whose nested panes rewrite TERM_PROGRAM.
#   4b. The live T3 thread running in this home (discover_supervisor_t3code_thread)
#      - T3 puts nothing into the agent's environment, so this is a cwd match
#      over T3's live threads, consulted only when t3code is explicitly
#      selected and a T3 credential is configured.
#   4c. TERM_PROGRAM=Orca + $ORCA_TERMINAL_HANDLE (fm_supervisor_in_orca) - the
#      captain's Orca terminal handle.
#   5. On an Orca home (fm_supervisor_orca_refusal) - print nothing and return 3;
#      the caller refuses with that function's reason.
#   6. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  local t3_thread
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  if fm_supervisor_in_rex; then
    printf '%s:%s' "${REX_SESSION#session:}" "${REX_BLOCK#block:}"
    return 0
  fi
  if t3_thread=$(discover_supervisor_t3code_thread); then
    printf '%s' "$t3_thread"
    return 0
  fi
  if fm_supervisor_in_orca; then
    printf '%s' "$ORCA_TERMINAL_HANDLE"
    return 0
  fi
  fm_supervisor_orca_refusal >/dev/null && return 3
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_t3code_thread: the t3code rule both resolvers share.
# Cheap gate first so a home that never selected t3code makes no T3 call:
# explicit t3code selection (fm_backend_explicit_name) and a T3 credential
# (which carries the server origin) must both be present. Then the adapter's cwd
# match over this home (bin/backends/t3code.sh
# fm_backend_t3code_thread_for_home): exactly one live thread prints its id;
# none or an unreadable server returns 1 silently; more than one returns 2
# after the adapter has named the ids on stderr. Anything but 0 falls through.
discover_supervisor_t3code_thread() {
  command -v fm_backend_source >/dev/null 2>&1 || return 1
  [ "$(fm_backend_explicit_name)" = t3code ] || return 1
  fm_backend_source t3code 2>/dev/null || return 1
  [ -s "$(fm_backend_t3code_token_file)" ] || return 1
  fm_backend_t3code_thread_for_home "${FM_HOME:-.}"
}

# discover_supervisor_backend: resolve the supervisor endpoint's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux, herdr, rex, t3code, or orca) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. TERM_PROGRAM=rex (with $REX_SESSION and $REX_BLOCK present) - rex.
#   4b. A live T3 thread in this home - t3code (stderr quiet here; the target
#      resolver reports an ambiguity once).
#   4c. TERM_PROGRAM=Orca (with $ORCA_TERMINAL_HANDLE present) - orca.
#   5. An Orca home - print nothing and return 3, matching the target resolver.
#   6. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  if fm_supervisor_in_rex; then
    printf 'rex'
    return 0
  fi
  if discover_supervisor_t3code_thread >/dev/null 2>&1; then
    printf 't3code'
    return 0
  fi
  if fm_supervisor_in_orca; then
    printf 'orca'
    return 0
  fi
  fm_supervisor_orca_refusal >/dev/null && return 3
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
