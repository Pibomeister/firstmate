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
# unresolvable config dir or worktree) is a signal: queue until reset. A signal
# drops only the non-Claude candidates; a Claude candidate can still be named.
# A secondmate's worktree is its firstmate home, and every firstmate home
# tracks .claude/ skills and hooks, so suggest never moves a Claude secondmate
# off Claude. An explicit fm-control.sh relaunch --harness runs the same
# check, so it can move that secondmate to another Claude model but not off
# Claude.
# claude-tooling exits 0 and prints the blocking signal when tooling is
# required. Exit 1 means no signal.
#
# Signals: MCP servers in the account config dir (including $HOME/.claude.json
# for an ordinary account, and any non-empty .projects[].mcpServers); account
# settings.json hooks and hooks/hooks.json; MCP servers and hooks bundled
# under account plugins/ (.mcp.json, including a flat server map with no
# mcpServers wrapper, .claude-plugin/plugin.json, and hooks/hooks.json;
# find follows symlinks). Marketplace clones and stale cache copies under
# plugins/ still block when they bundle MCP or hooks, even if the plugin
# was never installed or enabled. A project .mcp.json in the worktree; .claude/ skills,
# hooks, agents, or commands in the worktree. Worktree .claude/settings.json
# and settings.local.json keys: hooks, enabledMcpjsonServers, mcpServers,
# enabledPlugins. Firstmate's own busy hooks are not a signal: only the exact
# command forms fm-spawn writes (optional `touch '<turnend>'; ` then
# quoted fm-busy-event.sh apply quoted-state quoted-id busy|idle --gen
# quoted --source claude-hook --event <token> 2>/dev/null || true).
# A command that merely contains that script path still blocks.
Account-wide skills, agents, commands, and a plugin that
# only ships those, are not a signal. enabledPlugins is not an account
# signal. An unreadable file is a signal. An unreadable plugins/ dir is
# unreadable MCP/hooks config. An unreadable skills/, agents/, or commands/
# dir is not a signal. A present .projects that is not an object, a
# .projects entry that is neither an object nor null, or a .mcpServers
# (top-level or under .projects) that is present and not an object, is
# unreadable. Worktree .claude/ skills, hooks, agents, or commands are a
# signal if the path exists, even empty. A caller that passes
# --claude-config-dir for a pinned account must also pass --pinned. Those two
# lists live only in the variables below; there is no exemption mechanism.
# Resolve the config dir from the task's account pin, never from
# claude-config-dirs. A broken or unreadable pin is a signal. No pin, or
# ordinary, inspects $HOME/.claude.
#
# The supervisor runs this after a stale wake names a usage-limit, then calls
# fm-control.sh relaunch --harness with the printed pick. The watchdog may call
# suggest to name the pick. It must not relaunch.
# bin/fm-quota-choose.sh owns eligibility against one snapshot.
# suggest excludes a pinned (or unresolvable-pin) account's whole harness;
# fm-control relaunch enforces the pin again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

# Single owner of the Claude-tooling name lists in the header above.
FM_QUOTA_CLAUDE_ACCOUNT_SETTING_KEYS='hooks'
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
         or ((.projects // {}) | type == "object"
             and (to_entries
                  | map(.value | select(type == "object")
                        | .mcpServers | select(type == "object" and length > 0))
                  | length > 0))' \
    "$1" >/dev/null 2>&1
}

fm_quota_claude_mcp_unreadable() {  # <file>
  jq -e '
    (.mcpServers != null and (.mcpServers | type != "object"))
    or (.projects != null and (.projects | type != "object"))
    or ((.projects // {}) | type == "object" and (
          (to_entries
           | map(select(.value != null and (.value | type != "object")))
           | length > 0)
          or (to_entries
              | map(.value | select(type == "object") | .mcpServers)
              | map(select(. != null and type != "object"))
              | length > 0)
        ))
  ' "$1" >/dev/null 2>&1
}

# Prints the blocking signal and returns 0 when <file> is unreadable or any
# named key is a non-empty object, array, string, or true. Returns 1 when the
# file is absent or none of the keys are a signal. <keys> is a space list.
# With <own-writer>, hook commands that call that path (firstmate's own busy
# hooks, which fm-spawn writes and fm-control relaunch retires) are dropped
# before the check.
fm_quota_claude_settings_keys_signal() {  # <file> <keys> [own-writer]
  local f=$1 keys=$2 own=${3-} key
  [ -e "$f" ] || return 1
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf '%s\n' "unreadable $f"
    return 0
  fi
  if ! jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    printf '%s\n' "unreadable $f"
    return 0
  fi
  for key in $keys; do
    if jq -e --arg k "$key" --arg own "$own" '
         def apply_form:
           startswith("'\''" + $own + "'\'' apply '\''")
           and test(" apply '\''[^'\'']+'\'' '\''[^'\'']+'\'' (busy|idle) --gen '\''[^'\'']+'\'' --source claude-hook --event [A-Za-z0-9-]+ 2>/dev/null \\|\\| true$");
         def spawn_busy_hook:
           apply_form
           or (test("^touch '\''[^'\'']+'\''; ")
               and (index("'\''; ") != null)
               and (.[index("'\''; ") + 3:] | apply_form));
         (if $own != "" and (.hooks | type == "object") then
            .hooks |= (map_values(
                         if type == "array" then
                           map(if type == "object" and (.hooks | type == "array") then
                                 .hooks |= map(select((type == "object"
                                   and (.command | type == "string")
                                   and (.command | spawn_busy_hook)) | not))
                               else . end)
                           | map(select((type == "object" and (.hooks | type == "array")
                                         and (.hooks | length == 0)) | not))
                         else . end)
                       | with_entries(select((.value | type == "array"
                                              and length == 0) | not)))
          else . end)
         | .[$k] as $v
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

# Prints the blocking signal for MCP or hooks bundled under <config-dir>/plugins.
# A missing plugins dir is not a signal. An unreadable plugins dir is.
fm_quota_claude_plugin_bundle_signal() {  # <config-dir>
  local plugins=$1/plugins f err out sig
  [ -e "$plugins" ] || return 1
  if [ ! -d "$plugins" ] || [ ! -r "$plugins" ] || [ ! -x "$plugins" ]; then
    printf '%s\n' "unreadable $plugins"
    return 0
  fi
  err=$(mktemp) || {
    printf '%s\n' "unreadable $plugins"
    return 0
  }
  out=$(find -L "$plugins" \( -name node_modules -o -name .git \) -prune -o \
    \( -name .mcp.json -o -path '*/hooks/hooks.json' \
       -o -path '*/.claude-plugin/plugin.json' \) -print 2>"$err") || {
    rm -f "$err"
    printf '%s\n' "unreadable $plugins"
    return 0
  }
  if [ -s "$err" ]; then
    rm -f "$err"
    printf '%s\n' "unreadable $plugins"
    return 0
  fi
  rm -f "$err"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */hooks/hooks.json)
        if sig=$(fm_quota_claude_settings_keys_signal "$f" hooks); then
          printf '%s\n' "$sig"
          return 0
        fi
        ;;
      */.mcp.json)
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
          printf '%s\n' "unreadable $f"
          return 0
        fi
        if ! jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
          printf '%s\n' "unreadable $f"
          return 0
        fi
        if jq -e 'type=="object" and length>0' "$f" >/dev/null 2>&1; then
          printf '%s\n' "MCP servers in $f"
          return 0
        fi
        ;;
      */.claude-plugin/plugin.json)
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
          printf '%s\n' "unreadable $f"
          return 0
        fi
        if ! jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
          printf '%s\n' "unreadable $f"
          return 0
        fi
        if fm_quota_claude_mcp_in_file "$f"; then
          printf '%s\n' "MCP servers in $f"
          return 0
        fi
        if jq -e '(.mcpServers | type == "string" and length > 0)
                 or (.mcpServers | type == "array" and length > 0)' \
             "$f" >/dev/null 2>&1; then
          printf '%s\n' "MCP servers in $f"
          return 0
        fi
        if fm_quota_claude_mcp_unreadable "$f"; then
          printf '%s\n' "unreadable $f"
          return 0
        fi
        if sig=$(fm_quota_claude_settings_keys_signal "$f" hooks); then
          printf '%s\n' "$sig"
          return 0
        fi
        ;;
    esac
  done <<EOF
$out
EOF
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
    if ! jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
      printf '%s\n' "unreadable $f"
      return 0
    fi
    if fm_quota_claude_mcp_unreadable "$f"; then
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
  if sig=$(fm_quota_claude_settings_keys_signal "$dir/hooks/hooks.json" hooks); then
    printf '%s\n' "$sig"
    return 0
  fi
  if sig=$(fm_quota_claude_plugin_bundle_signal "$dir"); then
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
      if ! jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
        printf '%s\n' "unreadable $f"
        return 0
      fi
      if fm_quota_claude_mcp_unreadable "$f"; then
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
  if sig=$(fm_quota_claude_settings_keys_signal "$wt/.claude/settings.json" \
             "$FM_QUOTA_CLAUDE_WT_SETTING_KEYS"); then
    printf '%s\n' "$sig"
    return 0
  fi
  if sig=$(fm_quota_claude_settings_keys_signal "$wt/.claude/settings.local.json" \
             "$FM_QUOTA_CLAUDE_WT_SETTING_KEYS" "$SCRIPT_DIR/fm-busy-event.sh"); then
    printf '%s\n' "$sig"
    return 0
  fi
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
    TOOLING_SIG=
    if [ "$FROM_HARNESS" = claude ]; then
      if [ -z "$CLAUDE_DIR" ]; then
        config=${FM_CONFIG_OVERRIDE:-${FM_HOME:+$FM_HOME/config}}
        if ! CLAUDE_DIR=$(fm_quota_claude_config_dir "$config" "$MATE"); then
          TOOLING_SIG=${CLAUDE_DIR:-unresolvable Claude config dir}
          CLAUDE_DIR=
          PINNED=1
        else
          [ "${CLAUDE_DIR#*$'\t'}" = 1 ] && PINNED=1
          CLAUDE_DIR=${CLAUDE_DIR%%$'\t'*}
        fi
      fi
      if [ -z "$TOOLING_SIG" ] && [ -z "$WORKTREE" ]; then
        TOOLING_SIG='unresolvable worktree'
      fi
      if [ -z "$TOOLING_SIG" ] \
         && sig=$(fm_quota_claude_tooling_signal "$CLAUDE_DIR" "$WORKTREE"); then
        TOOLING_SIG=$sig
      fi
    fi
    filtered=()
    from_model=${FROM_MODEL:-default}
    [ -n "$from_model" ] || from_model=default
    for c in "${CANDIDATES[@]}"; do
      harness=${c%%:*}
      model=${c#*:}
      [ "$model" != "$c" ] || model=default
      if [ -n "$TOOLING_SIG" ] && [ "$harness" != claude ]; then
        continue
      fi
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
      if [ -n "$TOOLING_SIG" ]; then
        echo "error: Claude-specific tooling present ($TOOLING_SIG); queue until reset rather than moving off Claude" >&2
      else
        echo "error: no verified candidate remains for kind $KIND" >&2
      fi
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
