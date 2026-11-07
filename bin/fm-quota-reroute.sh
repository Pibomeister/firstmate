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
# A secondmate's worktree is its firstmate home.
# Seed exemption is owned by the Signals paragraph; this check does not scan
# HEAD:.claude.
# An explicit fm-control.sh relaunch --harness runs the same check.
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
# The match is the whole command. A command that merely contains that script
# path, or embeds the spawn form beside other shell, still blocks.
# Unchanged Firstmate seed files listed in bin/fm-claude-seed.manifest are not a
# signal. Identity is that catalog's git blob, not a path name and not
# HEAD:.claude of the running home. The catalog hashes
# .claude/settings.json, .claude/skills, .claude/mods/firstmate-calm/, and
# .agents/skills/ (the skills symlink target). A user file under
# .agents/skills is still a signal. A worktree .claude or .agents/skills
# directory that is a symlink is not unchanged seed. Account-wide skills, agents, commands, and a plugin that
# only ships those, are not a signal. enabledPlugins is not an account
# signal. An unreadable file is a signal. An unreadable plugins/ dir is
# unreadable MCP/hooks config. An unreadable skills/, agents/, or commands/
# dir is not a signal. A present .projects that is not an object, a
# .projects entry that is neither an object nor null, or a .mcpServers
# (top-level or under .projects) that is present and not an object, is
# unreadable. Worktree .claude/ skills, hooks, agents, or commands are a
# signal if the path exists, even empty, unless they are unchanged seed
# as above. An unreadable seed traversal is a signal. A dangling or
# unreadable worktree .claude is a signal. A find path that contains a
# newline is an unreadable walk. A caller that passes
# --claude-config-dir for a pinned account must also pass --pinned. Those two
# lists live only in the variables below.
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
  local f=$1 keys=$2 own=${3-} key own_re=
  [ -e "$f" ] || return 1
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf '%s\n' "unreadable $f"
    return 0
  fi
  if ! jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    printf '%s\n' "unreadable $f"
    return 0
  fi
  own_re=
  if [ -n "$own" ]; then
    own_re=$(printf '%s' "$own" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')
  fi
  for key in $keys; do
    if jq -e --arg k "$key" --arg own "$own" --arg own_re "$own_re" '
         def spawn_busy_hook:
           test("^(touch '\''[^'\'']+'\''; )?'\''" + $own_re + "'\'' apply '\''[^'\'']+'\'' '\''[^'\'']+'\'' (busy|idle) --gen '\''[^'\'']+'\'' --source claude-hook --event [A-Za-z0-9-]+ 2>/dev/null \\|\\| true$");
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
  local plugins=$1/plugins f out sig rc=0
  [ -e "$plugins" ] || return 1
  if [ ! -d "$plugins" ] || [ ! -r "$plugins" ] || [ ! -x "$plugins" ]; then
    printf '%s\n' "unreadable $plugins"
    return 0
  fi
  out=$(fm_quota_claude_collect_print0 "$plugins" -L "$plugins" \
    \( -name node_modules -o -name .git \) -prune -o \
    \( -name .mcp.json -o -path '*/hooks/hooks.json' \
       -o -path '*/.claude-plugin/plugin.json' \) -print0) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
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

# Git blob of a worktree file or symlink. A directory or missing path fails.
# Symlink blobs are the target string, matching git's symlink storage.
fm_quota_claude_blob_of() {  # <path>
  if [ -L "$1" ]; then
    printf '%s' "$(readlink "$1")" | git hash-object --stdin 2>/dev/null
  elif [ -f "$1" ]; then
    git hash-object -- "$1" 2>/dev/null
  else
    return 1
  fi
}

fm_quota_claude_seed_manifest_file() {
  printf '%s\n' "$SCRIPT_DIR/fm-claude-seed.manifest"
}

# Prints <blob><TAB><path> lines from the Firstmate-owned catalog.
# A missing, unreadable, or malformed catalog fails; callers do not exempt.
fm_quota_claude_load_seed_catalog() {
  local f header body
  f=$(fm_quota_claude_seed_manifest_file)
  [ -f "$f" ] && [ -r "$f" ] || return 1
  IFS= read -r header < "$f" || return 1
  [ "$header" = "fm-claude-seed.v1" ] || return 1
  body=$(tail -n +2 "$f")
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

fm_quota_claude_catalog_paths() {  # <catalog>
  printf '%s\n' "$1" | cut -f2-
}

fm_quota_claude_catalog_has() {  # <relpath> <catalog>
  printf '%s\n' "$2" | cut -f2- | grep -Fqx "$1"
}

fm_quota_claude_catalog_blob() {  # <relpath> <catalog>
  local rel=$1 catalog=$2 blob path
  while IFS=$'\t' read -r blob path; do
    [ "$path" = "$rel" ] || continue
    printf '%s\n' "$blob"
    return 0
  done <<EOF
$catalog
EOF
  return 1
}

# True when the worktree carries the catalog's .claude/skills symlink blob,
# so Firstmate seed inspection applies. Unknown catalog or a different link
# is false: callers keep the existence checks.
fm_quota_claude_worktree_seed_mode() {  # <wt>
  local wt=$1 catalog expected actual
  catalog=$(fm_quota_claude_load_seed_catalog) || return 1
  expected=$(fm_quota_claude_catalog_blob .claude/skills "$catalog") || return 1
  actual=$(fm_quota_claude_blob_of "$wt/.claude/skills") || return 1
  [ "$actual" = "$expected" ]
}

fm_quota_claude_seed_dir_implied() {  # <relpath> <paths>
  local rel=$1 paths=$2 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$rel"|"$rel"/*) return 0 ;;
    esac
  done <<EOF
$paths
EOF
  return 1
}

# Join find -print0 paths onto stdout. Return 2 on a complete walk, or 0
# with an unreadable signal when find fails or a path contains a newline.
fm_quota_claude_collect_print0() {  # <dir> <find-args...>
  local dir=$1 err raw f collected='' newline=0
  shift
  err=$(mktemp) || {
    printf '%s\n' "unreadable $dir"
    return 0
  }
  raw=$(mktemp) || {
    rm -f "$err"
    printf '%s\n' "unreadable $dir"
    return 0
  }
  if ! find "$@" >"$raw" 2>"$err"; then
    rm -f "$err" "$raw"
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  if [ -s "$err" ]; then
    rm -f "$err" "$raw"
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  rm -f "$err"
  while IFS= read -r -d '' f || [ -n "$f" ]; do
    case "$f" in
      *$'\n'*) newline=1; break ;;
    esac
    if [ -n "$collected" ]; then
      collected="$collected"$'\n'"$f"
    else
      collected=$f
    fi
    f=
  done <"$raw"
  rm -f "$raw"
  if [ "$newline" = 1 ]; then
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  printf '%s\n' "$collected"
  return 2
}

# Prints paths of files and symlinks under <dir>, or a signal and returns 0
# when the walk cannot complete. Returns 1 when <dir> is absent.
# A symlink root is not the authentic seed directory; find -P would hide
# files behind it, so callers treat that root as a signal instead of walking.
fm_quota_claude_find_leaves() {  # <dir>
  local dir=$1 rc=0 out
  [ -e "$dir" ] || return 1
  if [ -L "$dir" ]; then
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  out=$(fm_quota_claude_collect_print0 "$dir" "$dir" \( -type f -o -type l \) -print0) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out"
  return 2
}

fm_quota_claude_find_dirs() {  # <dir>
  local dir=$1 rc=0 out
  [ -e "$dir" ] || return 1
  if [ -L "$dir" ]; then
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    printf '%s\n' "unreadable $dir"
    return 0
  fi
  out=$(fm_quota_claude_collect_print0 "$dir" "$dir" -mindepth 1 -type d -print0) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out"
  return 2
}

# Prints a worktree signal and returns 0 when seed-mode finds an edit,
# addition, or unreadable walk. Returns 1 when every catalog path that is
# present matches and nothing extra is present. settings.local.json is left
# to the busy-hook key check.
fm_quota_claude_seed_tree_signal() {  # <wt>
  local wt=${1%/} catalog paths path f expected actual rel sig leaves dirs rc target
  catalog=$(fm_quota_claude_load_seed_catalog) || {
    printf '%s\n' "unreadable worktree"
    return 0
  }
  paths=$(fm_quota_claude_catalog_paths "$catalog")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    f=$wt/$path
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      continue
    fi
    if [ ! -L "$f" ] && [ ! -r "$f" ]; then
      printf '%s\n' "unreadable $f"
      return 0
    fi
    expected=$(fm_quota_claude_catalog_blob "$path" "$catalog") || {
      printf '%s\n' "unreadable worktree"
      return 0
    }
    if [ -L "$f" ] || [ -f "$f" ]; then
      actual=$(fm_quota_claude_blob_of "$f") || {
        printf '%s\n' "unreadable $f"
        return 0
      }
      [ "$actual" = "$expected" ] && continue
      if [ "$path" = .claude/settings.json ]; then
        if sig=$(fm_quota_claude_settings_keys_signal "$f" \
                   "$FM_QUOTA_CLAUDE_WT_SETTING_KEYS"); then
          printf '%s\n' "$sig"
          return 0
        fi
      fi
      printf '%s\n' "worktree $path"
      return 0
    fi
    printf '%s\n' "worktree $path"
    return 0
  done <<EOF
$paths
EOF
  if [ -L "$wt/.claude" ]; then
    printf '%s\n' "worktree .claude"
    return 0
  fi
  rc=0
  leaves=$(fm_quota_claude_find_leaves "$wt/.claude") || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$leaves"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel=${f#"$wt"/}
      [ "$rel" = .claude/settings.local.json ] && continue
      fm_quota_claude_catalog_has "$rel" "$catalog" && continue
      printf '%s\n' "worktree $rel"
      return 0
    done <<EOF
$leaves
EOF
  fi
  target=$wt/.agents/skills
  if [ ! -e "$target" ]; then
    printf '%s\n' "unreadable $target"
    return 0
  fi
  if [ -L "$target" ]; then
    printf '%s\n' "worktree .agents/skills"
    return 0
  fi
  rc=0
  leaves=$(fm_quota_claude_find_leaves "$target") || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$leaves"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel=${f#"$wt"/}
      fm_quota_claude_catalog_has "$rel" "$catalog" && continue
      printf '%s\n' "worktree $rel"
      return 0
    done <<EOF
$leaves
EOF
  fi
  rc=0
  dirs=$(fm_quota_claude_find_dirs "$wt/.claude") || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$dirs"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel=${f#"$wt"/}
      fm_quota_claude_seed_dir_implied "$rel" "$paths" && continue
      printf '%s\n' "worktree $rel"
      return 0
    done <<EOF
$dirs
EOF
  fi
  rc=0
  dirs=$(fm_quota_claude_find_dirs "$target") || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$dirs"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel=${f#"$wt"/}
      fm_quota_claude_seed_dir_implied "$rel" "$paths" && continue
      printf '%s\n' "worktree $rel"
      return 0
    done <<EOF
$dirs
EOF
  fi
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
  wt=${wt%/}
  if [ -L "$wt/.claude" ]; then
    printf '%s\n' "worktree .claude"
    return 0
  fi
  if [ -e "$wt/.claude" ] && {
       [ ! -d "$wt/.claude" ] || [ ! -r "$wt/.claude" ] || [ ! -x "$wt/.claude" ]
     }; then
    printf '%s\n' "unreadable $wt/.claude"
    return 0
  fi
  if [ -e "$wt/.claude" ] && fm_quota_claude_worktree_seed_mode "$wt"; then
    if sig=$(fm_quota_claude_seed_tree_signal "$wt"); then
      printf '%s\n' "$sig"
      return 0
    fi
    if sig=$(fm_quota_claude_settings_keys_signal "$wt/.claude/settings.local.json" \
               "$FM_QUOTA_CLAUDE_WT_SETTING_KEYS" "$SCRIPT_DIR/fm-busy-event.sh"); then
      printf '%s\n' "$sig"
      return 0
    fi
    return 1
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
