#!/usr/bin/env bash
# fm-lab-home.sh - mint a disposable firstmate "lab" home.
#
# A lab home is a throwaway FM_HOME that a no-mistakes GATE agent may drive
# through the fleet lifecycle entrypoints: bin/fm-gate-refuse-lib.sh refuses
# those calls inside a gate agent unless FM_HOME carries the marker file this
# helper writes (the lib owns the marker format and authorization decision;
# this script is the supported writer).
#
# Usage:
#   fm-lab-home.sh create <dir>       make a marked lab home and print it
#   fm-lab-home.sh tmux-dir <dir>     create or print its private tmux socket dir
#   fm-lab-home.sh tmux <dir> <args>  run tmux <args> against only its private server
#   fm-lab-home.sh teardown <dir>     remove its private tmux socket dir
#
# A lab home is the stock layout only - state/, data/, config/, projects/ - and
# callers remove it with ordinary rm -rf when done. Drive it with plain
# FM_HOME=<dir>; bin/fm-gate-refuse-lib.sh owns permitted supervision overrides.
# tmux-dir is the single owner of the short private socket directory, and the
# tmux runner addresses that directory's server with -S and TMUX/TMUX_PANE
# unset, refuses a caller -S or -L, and starts the server without the
# operator's tmux config. tmux resolves its server from -S, then -L, then
# $TMUX, and only then from TMUX_TMPDIR, so TMUX_TMPDIR alone run inside any
# tmux pane addresses that pane's server. Run every lab tmux command, including the cleanup trap's
# kill-server, through the runner, then call teardown. A process that must run
# firstmate's bare tmux calls outside a lab pane needs TMUX_TMPDIR=<printed-dir>
# with TMUX and TMUX_PANE unset.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

fm_lab_home_error() {
  echo "fm-lab-home: $*" >&2
}

fm_lab_home_tmux_record() { printf '%s/state/.fm-lab-tmux-dir' "$1"; }
fm_lab_home_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
fm_lab_home_owner() {
  case "$(uname -s)" in Darwin) stat -f '%u' "$1" ;; *) stat -c '%u' "$1" ;; esac
}

# Validate the marked lab home and its recorded private socket directory into
# socket_dir; with "create", mint one when none is recorded, otherwise leave
# socket_dir empty.
fm_lab_home_socket_dir() {  # <lab-home> <subcommand> [create]
  local dir=$1 record
  socket_dir=
  [ -n "$dir" ] || { fm_lab_home_error "$2 requires a marked lab home"; return 2; }
  [ -f "$dir/.fm-lab-home" ] && [ -d "$dir/state" ] \
    || { fm_lab_home_error "refusing '$dir': not a marked lab home"; return 1; }
  record=$(fm_lab_home_tmux_record "$dir")
  if [ -f "$record" ]; then
    socket_dir=$(cat "$record")
    case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fm_lab_home_error "invalid recorded tmux directory"; return 1 ;; esac
    [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
      || { fm_lab_home_error "recorded tmux directory is missing or unsafe"; return 1; }
    [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
      || { fm_lab_home_error "recorded tmux directory is not private and user-owned"; return 1; }
  elif [ "${3:-}" = create ]; then
    socket_dir=$(mktemp -d /tmp/fml.XXXXXX) || return 1
    chmod 700 "$socket_dir" || { rmdir "$socket_dir" 2>/dev/null || true; return 1; }
    [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
      || { rmdir "$socket_dir" 2>/dev/null || true; fm_lab_home_error "cannot secure tmux directory"; return 1; }
    (umask 077; printf '%s\n' "$socket_dir" > "$record") || { rmdir "$socket_dir" 2>/dev/null || true; return 1; }
    chmod 600 "$record" || { rm -f "$record"; rmdir "$socket_dir" 2>/dev/null || true; return 1; }
  fi
}

case "${1:-}" in
  create)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "create requires a directory path"; exit 2; }
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
      fm_lab_home_error "refusing '$dir': exists and is not a directory"
      exit 1
    fi
    mkdir -p "$dir" || exit 1
    fm_gate_lab_mark "$dir" || {
      fm_lab_home_error "refusing '$dir': a lab marker is only ever stamped on a fresh empty dir"
      exit 1
    }
    mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects" || exit 1
    printf '%s\n' "$dir"
    ;;
  tmux-dir)
    fm_lab_home_socket_dir "${2:-}" tmux-dir create || exit
    printf '%s\n' "$socket_dir"
    ;;
  tmux)
    fm_lab_home_socket_dir "${2:-}" tmux create || exit
    shift 2
    # Global options precede the tmux command; a caller -S or -L would
    # override the lab socket, so refuse rather than address another server.
    # tmux's [-2CDhlNquUvV] flags may precede one value letter in a cluster;
    # the value is the rest of the word, or the next word when none is left.
    args=("$@") i=0
    while [ "$i" -lt "${#args[@]}" ] && [ "${args[$i]}" != -- ]; do
      if [[ ${args[$i]} =~ ^-[2CDhlNquUvV]*[SL] ]]; then
        fm_lab_home_error "refusing a caller -S/-L: the runner owns the lab socket"
        exit 2
      elif [[ ${args[$i]} =~ ^-[2CDhlNquUvV]*[cfT]$ ]]; then
        i=$((i + 2))
      elif [[ ${args[$i]} =~ ^- ]]; then
        i=$((i + 1))
      else
        break
      fi
    done
    # The per-user socket tmux itself picks under TMUX_TMPDIR=<dir> with TMUX
    # unset, so teardown and TMUX_TMPDIR-only children reach the same server;
    # the server inherits that TMUX_TMPDIR and skips the operator's config.
    mkdir -m 700 "$socket_dir/tmux-$(id -u)" 2>/dev/null || [ -d "$socket_dir/tmux-$(id -u)" ] || exit 1
    exec env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$socket_dir" tmux -f /dev/null -S "$socket_dir/tmux-$(id -u)/default" "$@"
    ;;
  teardown)
    fm_lab_home_socket_dir "${2:-}" teardown || exit
    [ -n "$socket_dir" ] || exit 0
    # -L names its own socket (not "default"); inspect every socket this
    # private TMUX_TMPDIR could have hosted before removing the directory.
    # A server told to stop a moment ago may still be exiting; allow it ~1s.
    for socket in "$socket_dir/tmux-$(id -u)"/*; do
      [ -e "$socket" ] || [ -L "$socket" ] || continue
      attempts=0
      while probe=$(tmux -S "$socket" list-sessions 2>&1 >/dev/null) \
        || [ "${probe#*no server running}" = "$probe" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 20 ] || {
          fm_lab_home_error "refusing teardown: cannot confirm the lab tmux server has stopped"
          exit 1
        }
        sleep 0.05
      done
    done
    rm -rf "$socket_dir" && rm -f "$(fm_lab_home_tmux_record "$2")"
    ;;
  *)
    fm_lab_home_error "usage: fm-lab-home.sh create <dir> | tmux-dir <dir> | tmux <dir> <args...> | teardown <dir>"
    exit 2
    ;;
esac
