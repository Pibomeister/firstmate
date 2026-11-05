#!/usr/bin/env bash
# Name a quota-eligible replacement runtime. Never relaunches.
#
# Usage:
#   fm-quota-reroute.sh suggest [--snapshot <path>] [--candidate <harness:model>]...
#                               [--from-harness <name>] [--claude-config-dir <dir>]
#                               [--kind ship|scout|secondmate]
#   fm-quota-reroute.sh claude-tooling --config-dir <dir>
#
# suggest prints "<harness> <model>" and exits 0 when a candidate is eligible.
# It prints "none" and exits 1 when the pool is exhausted, the candidate list
# is empty, or a Claude-pinned mate cannot leave Claude because that config
# dir has Claude-specific tooling.
# claude-tooling exits 0 when <dir> has at least one MCP server configured.
# Empty or absent MCP maps are not a dependency.
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

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

# fm_quota_claude_tooling_required <config-dir>
# True when the Claude config dir lists at least one MCP server. That is the
# explicit Claude-specific tooling gate for a mid-task move off Claude.
fm_quota_claude_tooling_required() {  # <config-dir>
  local dir=${1-} f
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  for f in "$dir/.claude.json" "$dir/settings.json" "$dir/.claude/settings.json"; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if jq -e '(.mcpServers | type == "object" and length > 0)
              or (.enabledMcpjsonServers | type == "array" and length > 0)' \
         "$f" >/dev/null 2>&1; then
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
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --config-dir)
          [ -n "${2-}" ] || die "--config-dir needs a path"
          dir=$2
          shift 2
          ;;
        -h|--help|help) usage ;;
        -*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
      esac
    done
    [ -n "$dir" ] || die "claude-tooling needs --config-dir"
    fm_quota_claude_tooling_required "$dir"
    ;;
  suggest)
    SNAPSHOT=
    FROM_HARNESS=
    CLAUDE_DIR=
    KIND=ship
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
        --claude-config-dir)
          [ -n "${2-}" ] || die "--claude-config-dir needs a path"
          CLAUDE_DIR=$2
          shift 2
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
    if [ "$FROM_HARNESS" = claude ] && fm_quota_claude_tooling_required "$CLAUDE_DIR"; then
      printf 'none\n'
      echo "error: Claude-specific tooling is configured; queue until reset rather than moving off Claude" >&2
      exit 1
    fi
    filtered=()
    for c in "${CANDIDATES[@]}"; do
      harness=${c%%:*}
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
