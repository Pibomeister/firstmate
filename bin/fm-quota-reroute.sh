#!/usr/bin/env bash
# Name a quota-eligible replacement runtime. Never relaunches.
#
# Usage:
#   fm-quota-reroute.sh suggest [--snapshot <path>] [--candidate <harness:model>]...
#                               [--from-harness <name>] [--from-model <name>]
#                               [--claude-config-dir <dir>] [--mate <id>]
#                               [--worktree <dir>] [--pinned]
#                               [--kind ship|scout|secondmate]
#   fm-quota-reroute.sh claude-tooling [--config-dir <dir> | --mate <id>] [--worktree <dir>]
#
# suggest prints "<harness> <model>" and exits 0 when a candidate is eligible.
# It prints "none" and exits 1 when the pool is exhausted, the candidate list
# is empty, the current harness:model (and a pinned account's whole harness)
# is the only remaining choice, or a Claude worker cannot leave Claude because
# any Claude-specific signal is present. Unknown (missing, unreadable, or
# unresolvable config dir or worktree) is a signal: queue until reset.
# claude-tooling exits 0 and prints the blocking signal when tooling is
# required. Exit 1 means no signal.
#
# Signals: MCP servers in the account config dir (including $HOME/.claude.json
# for an ordinary account, and any non-empty .projects[].mcpServers); a project
# .mcp.json in the worktree; .claude/ skills, hooks, agents, or commands in the
# worktree. Account-dir names (non-empty): skills, agents, commands, plugins.
# Account settings.json keys: hooks, enabledPlugins. Worktree
# .claude/settings.json and settings.local.json keys: hooks,
# enabledMcpjsonServers, mcpServers, enabledPlugins. An unreadable file is a
# signal. Those three lists live only in the variables below; there is no
# exemption mechanism. Resolve the config dir from the task's account pin,
# never from claude-config-dirs. A broken or unreadable pin is a signal. No
# pin, or ordinary, inspects $HOME/.claude.
#
# The supervisor runs this after a stale wake names a usage-limit, then calls
# fm-control.sh relaunch --harness with the printed pick. The watchdog may call
# suggest to name the pick. It must not relaunch.
# bin/fm-quota-choose.sh owns eligibility against one snapshot.
# Account pins are enforced at relaunch, not here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

# Single owner of the Claude-tooling name lists in the header above.
FM_QUOTA_CLAUDE_ACCOUNT_DIRS='skills agents commands plugins'
FM_QUOTA_CLAUDE_ACCOUNT_SETTING_KEYS='hooks enabledPlugins'
FM_QUOTA_CLAUDE_WT_SETTING_KEYS='hooks enabledMcpjsonServers mcpServers enabledPlugins'

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

# fm_quota_claude_config_dir <home-config-dir> [mate]
# Prints "<dir><TAB><pinned>" on success. pinned is 1 when a pin is present,
# including ordinary, else 0. Ordinary or absent pin: $HOME/.claude. A pin that
# names a directory: that directory. Returns 1 and prints the reason when the
# pin cannot be resolved.
fm_quota_claude_config_dir() {  # <home-config-dir> [mate]
  local config=${1-} mate=${2-} cfg pin declared root dir
  if [ -z "$config" ]; then
    printf '%s\n' "unresolvable Claude config dir"
    return 1
  fi
  if ! cfg=$(fm_worker_account_config claude "$config" "$mate"); then
    printf '%s\n' "unreadable claude-account pin"
    return 1
  fi
  if ! pin=$(fm_worker_account_resolve claude "$cfg" config/claude-account 2>&1); then
    pin=${pin#error: }
    printf '%s\n' "${pin:-unreadable claude-account pin}"
    return 1
  fi
  if [ -z "$pin" ]; then
    printf '%s\t0\n' "${HOME}/.claude"
    return 0
  fi
  declared=${pin%%$'\t'*}
  root=$(printf '%s' "$pin" | cut -f2)
  if [ "$declared" = ordinary ]; then
    dir=${HOME}/.claude
  else
    dir=$root
  fi
  printf '%s\t1\n' "$dir"
}

fm_quota_claude_mcp_in_file() {  # <file>
  jq -e '(.mcpServers | type == "object" and length > 0)
         or (.enabledMcpjsonServers | type == "array" and length > 0)
         or ((.projects // {}) | to_entries
             | map(.value.mcpServers | select(type == "object" and length > 0))
             | length > 0)' \
    "$1" >/dev/null 2>&1
}

# Prints the blocking signal and returns 0 when <file> is unreadable or any
# named key is a non-empty object, array, string, or true. Returns 1 when the
# file is absent or none of the keys are a signal. <keys> is a space list.
fm_quota_claude_settings_keys_signal() {  # <file> <keys>
  local f=$1 keys=$2 key
  [ -e "$f" ] || return 1
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf '%s\n' "unreadable $f"
    return 0
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    printf '%s\n' "unreadable $f"
    return 0
  fi
  for key in $keys; do
    if jq -e --arg k "$key" '
         .[$k] as $v
         | ($v | type == "object" and length > 0)
           or ($v | type == "array" and length > 0)
           or ($v | type == "string" and length > 0)
           or ($v == true)' \
         "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f .$key"
      return 0
    fi
  done
  return 1
}

fm_quota_claude_account_dir_signal() {  # <config-dir>
  local dir=$1 name path
  for name in $FM_QUOTA_CLAUDE_ACCOUNT_DIRS; do
    path=$dir/$name
    [ -e "$path" ] || continue
    if [ -d "$path" ]; then
      if [ ! -r "$path" ] || [ ! -x "$path" ]; then
        printf '%s\n' "unreadable $path"
        return 0
      fi
      [ -z "$(ls -A "$path" 2>/dev/null)" ] && continue
    fi
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

# fm_quota_claude_tooling_signal <config-dir> [worktree]
# Prints the blocking signal and returns 0 when a Claude-specific signal is
# present or the inspect cannot be completed. Returns 1 when none are present.
# An omitted worktree skips worktree signals (claude-tooling of a config dir).
# Ordinary Claude keeps user-scope mcpServers in $HOME/.claude.json, outside
# $HOME/.claude. Project-scope servers live under .projects[<path>].mcpServers.
fm_quota_claude_tooling_signal() {  # <config-dir> [worktree]
  local dir=${1-} wt=${2-} f name sig
  if [ -z "$dir" ]; then
    printf '%s\n' "unresolvable Claude config dir"
    return 0
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    printf '%s\n' "unreadable Claude config dir"
    return 0
  fi
  for f in "$dir/.claude.json" "$dir/settings.json" "$dir/.claude/settings.json"; do
    [ -e "$f" ] || continue
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf '%s\n' "unreadable $f"
      return 0
    fi
    if ! jq -e . "$f" >/dev/null 2>&1; then
      printf '%s\n' "unreadable $f"
      return 0
    fi
    if fm_quota_claude_mcp_in_file "$f"; then
      printf '%s\n' "MCP servers in $f"
      return 0
    fi
  done
  if sig=$(fm_quota_claude_settings_keys_signal "$dir/settings.json" \
             "$FM_QUOTA_CLAUDE_ACCOUNT_SETTING_KEYS"); then
    printf '%s\n' "$sig"
    return 0
  fi
  if sig=$(fm_quota_claude_account_dir_signal "$dir"); then
    printf '%s\n' "$sig"
    return 0
  fi
  if [ -n "${HOME:-}" ] && { [ "$dir" = "$HOME/.claude" ] || [ "$dir" = "$HOME/.claude/" ]; }; then
    f=$HOME/.claude.json
    if [ -e "$f" ]; then
      if [ ! -f "$f" ] || [ ! -r "$f" ]; then
        printf '%s\n' "unreadable $f"
        return 0
      fi
      if ! jq -e . "$f" >/dev/null 2>&1; then
        printf '%s\n' "unreadable $f"
        return 0
      fi
      if fm_quota_claude_mcp_in_file "$f"; then
        printf '%s\n' "MCP servers in $f"
        return 0
      fi
    fi
  fi
  [ -n "$wt" ] || return 1
  if [ ! -d "$wt" ] || [ ! -r "$wt" ] || [ ! -x "$wt" ]; then
    printf '%s\n' "unreadable worktree"
    return 0
  fi
  if [ -e "$wt/.mcp.json" ]; then
    printf '%s\n' "worktree .mcp.json"
    return 0
  fi
  for name in skills hooks agents commands; do
    if [ -e "$wt/.claude/$name" ]; then
      printf '%s\n' "worktree .claude/$name"
      return 0
    fi
  done
  for f in "$wt/.claude/settings.json" "$wt/.claude/settings.local.json"; do
    if sig=$(fm_quota_claude_settings_keys_signal "$f" \
               "$FM_QUOTA_CLAUDE_WT_SETTING_KEYS"); then
      printf '%s\n' "$sig"
      return 0
    fi
  done
  return 1
}

cmd=${1-}
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  -h|--help|help) usage ;;
  claude-tooling)
    dir=
    wt=
    mate=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --config-dir)
          [ -n "${2-}" ] || die "--config-dir needs a path"
          dir=$2
          shift 2
          ;;
        --mate)
          [ "$#" -ge 2 ] || die "--mate needs a value"
          mate=$2
          shift 2
          ;;
        --worktree)
          [ -n "${2-}" ] || die "--worktree needs a path"
          wt=$2
          shift 2
          ;;
        -h|--help|help) usage ;;
        -*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
      esac
    done
    if [ -z "$dir" ]; then
      config=${FM_CONFIG_OVERRIDE:-${FM_HOME:+$FM_HOME/config}}
      [ -n "$config" ] || die "claude-tooling needs --config-dir or FM_HOME"
      if ! dir=$(fm_quota_claude_config_dir "$config" "$mate"); then
        printf '%s\n' "$dir"
        exit 0
      fi
      dir=${dir%%$'\t'*}
    fi
    if sig=$(fm_quota_claude_tooling_signal "$dir" "$wt"); then
      printf '%s\n' "$sig"
      exit 0
    fi
    exit 1
    ;;
  suggest)
    SNAPSHOT=
    FROM_HARNESS=
    FROM_MODEL=
    CLAUDE_DIR=
    WORKTREE=
    PINNED=0
    KIND=ship
    MATE=
    CANDIDATES=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --snapshot)
          [ -n "${2-}" ] || die "--snapshot needs a path"
          SNAPSHOT=$2
          shift 2
          ;;
        --candidate)
          [ -n "${2-}" ] || die "--candidate needs a value"
          CANDIDATES+=("$2")
          shift 2
          ;;
        --from-harness)
          [ -n "${2-}" ] || die "--from-harness needs a name"
          FROM_HARNESS=$2
          shift 2
          ;;
        --from-model)
          [ -n "${2-}" ] || die "--from-model needs a name"
          FROM_MODEL=$2
          shift 2
          ;;
        --claude-config-dir)
          [ -n "${2-}" ] || die "--claude-config-dir needs a path"
          CLAUDE_DIR=$2
          shift 2
          ;;
        --mate)
          [ "$#" -ge 2 ] || die "--mate needs a value"
          MATE=$2
          shift 2
          ;;
        --worktree)
          [ -n "${2-}" ] || die "--worktree needs a path"
          WORKTREE=$2
          shift 2
          ;;
        --pinned)
          PINNED=1
          shift
          ;;
        --kind)
          [ -n "${2-}" ] || die "--kind needs a value"
          KIND=$2
          shift 2
          ;;
        -h|--help|help) usage ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *) CANDIDATES+=("$1"); shift ;;
      esac
    done
    while [ "$#" -gt 0 ]; do
      CANDIDATES+=("$1"); shift
    done
    case "$KIND" in
      ship|scout|secondmate) ;;
      *) die "invalid kind: $KIND" ;;
    esac
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
      printf 'none\n'
      echo "error: no reroute candidates supplied" >&2
      exit 1
    fi
    if [ "$FROM_HARNESS" = claude ]; then
      if [ -z "$WORKTREE" ]; then
        printf 'none\n'
        echo "error: Claude-specific tooling present (unresolvable worktree); queue until reset rather than moving off Claude" >&2
        exit 1
      fi
      if [ -z "$CLAUDE_DIR" ]; then
        config=${FM_CONFIG_OVERRIDE:-${FM_HOME:+$FM_HOME/config}}
        if ! CLAUDE_DIR=$(fm_quota_claude_config_dir "$config" "$MATE"); then
          printf 'none\n'
          echo "error: Claude-specific tooling present ($CLAUDE_DIR); queue until reset rather than moving off Claude" >&2
          exit 1
        fi
        [ "${CLAUDE_DIR#*$'\t'}" = 1 ] && PINNED=1
        CLAUDE_DIR=${CLAUDE_DIR%%$'\t'*}
      fi
      if sig=$(fm_quota_claude_tooling_signal "$CLAUDE_DIR" "$WORKTREE"); then
        printf 'none\n'
        echo "error: Claude-specific tooling present ($sig); queue until reset rather than moving off Claude" >&2
        exit 1
      fi
    fi
    filtered=()
    from_model=${FROM_MODEL:-default}
    [ -n "$from_model" ] || from_model=default
    for c in "${CANDIDATES[@]}"; do
      harness=${c%%:*}
      model=${c#*:}
      [ "$model" != "$c" ] || model=default
      if [ -n "$FROM_HARNESS" ] && [ "$harness" = "$FROM_HARNESS" ]; then
        if [ "$PINNED" = 1 ]; then
          continue
        fi
        [ "$model" != "$from_model" ] || continue
      fi
      fm_control_harness_supported "$harness" || continue
      fm_control_harness_supports_kind "$harness" "$KIND" || continue
      filtered+=("$c")
    done
    if [ "${#filtered[@]}" -eq 0 ]; then
      printf 'none\n'
      echo "error: no verified candidate remains for kind $KIND" >&2
      exit 1
    fi
    choose_args=()
    [ -z "$SNAPSHOT" ] || choose_args+=(--snapshot "$SNAPSHOT")
    for c in "${filtered[@]}"; do
      choose_args+=(--candidate "$c")
    done
    exec "$SCRIPT_DIR/fm-quota-choose.sh" "${choose_args[@]}"
    ;;
  *) die "unknown command: $cmd" ;;
esac
