#!/usr/bin/env bash
# Provision Firstmate's agent-kit run-supervisor declaration.
#
# Under agent-kit's unattended lifecycle policy, the run supervisor declares how
# it meets six obligations in a JSON file outside every git repository, and
# names that file in AK_LIFECYCLE_SUPERVISOR_DECLARATION beside
# AK_LIFECYCLE_SUPERVISOR (agent-kit adapters/supervisor/CONTRACT.md).
# bin/fm-spawn.sh calls fm_ak_supervisor_declaration_ensure on every local
# launch and exports the path it prints (docs/configuration.md "Agent-kit
# lifecycle policy").
#
# Shape: exactly the keys contract, supervisor and obligations;
# contract is agent-kit/supervisor-contract@1, supervisor is firstmate, and
# obligations holds exactly the six keys launch-and-watch, validation-gate,
# independent-review, seat-separation, head-bound-evidence and disclosure, each
# one non-empty single-line string. The statements are the ones agent-kit's
# adapters/firstmate/SUPERVISOR.md declares for Firstmate.
#
# Location: $XDG_STATE_HOME/firstmate/agent-kit/supervisor-declaration.json
# when XDG_STATE_HOME is an absolute path, else
# $HOME/.local/state/firstmate/agent-kit/supervisor-declaration.json (a
# relative XDG_STATE_HOME is ignored, as the XDG base-directory spec requires).
# The printed path is the file's resolved real path, because agent-kit stamps
# the real path. A Firstmate home sits inside a git work tree, so its state/
# and data/ can never hold the file.
#
# Outside every repository: the directory's resolved real path, and each
# ancestor up to /, must hold no .git entry (directory, file or link). A
# location that fails the walk is refused before anything is created or
# written; set XDG_STATE_HOME to a directory outside every repository when the
# home directory is itself a work tree.
#
# Byte stability: agent-kit's open --ticket stamps a run with the file's real
# path and sha256, and ship-preflight refuses when the bytes change. The
# payload is a fixed canonical byte string. A file that already holds those
# bytes is left untouched (no write, rename or mtime change), so repeated and
# concurrent launches never disturb an open run. An absent file, or one whose
# bytes differ, is replaced by an atomic rename of a fully written sibling
# temporary file, and the written file is checked again after the rename; a
# declaration path that is a directory or a link to one is refused instead.
# Changing the statements below therefore invalidates every
# run opened under the old bytes; agent-kit's recovery is a new run.
#
# Usage (sourced):
#   path=$(fm_ak_supervisor_declaration_ensure) || ...  # path on stdout,
#                                                       # reason on stderr

fm_ak_supervisor_declaration_payload() {
  printf '%s\n' \
    '{' \
    '  "contract": "agent-kit/supervisor-contract@1",' \
    '  "supervisor": "firstmate",' \
    '  "obligations": {' \
    '    "launch-and-watch": "Firstmate spawns each crewmate from its own home and watches its status and inbox until the task ends.",' \
    '    "validation-gate": "The no-mistakes pipeline re-runs test and lint on the pushed head, and Firstmate reads its result before attesting.",' \
    '    "independent-review": "Firstmate dispatches a reviewer crewmate that wrote none of the change and relays its verdict at the head.",' \
    '    "seat-separation": "Firstmate dispatches the implementer, verifier and reviewer seats as separate crewmates with their own worktrees.",' \
    '    "head-bound-evidence": "Every receipt and verdict Firstmate relays names the head commit it covers.",' \
    '    "disclosure": "Firstmate opens each pull request body with the disclosure sentence as its first paragraph and checks it before the final ship record."' \
    '  }' \
    '}'
}

# fm_ak_supervisor_declaration_dir prints the configured directory, unresolved.
fm_ak_supervisor_declaration_dir() {
  local base=${XDG_STATE_HOME:-}
  case "$base" in
    /*) ;;
    *)
      case "${HOME:-}" in
        /*) base=$HOME/.local/state ;;
        *)
          echo "warning: agent-kit supervisor declaration: neither XDG_STATE_HOME nor HOME is an absolute path" >&2
          return 1
          ;;
      esac
      ;;
  esac
  printf '%s\n' "${base%/}/firstmate/agent-kit"
}

# fm_ak_supervisor_declaration_outside_repos <real-dir>: succeed only when no
# component from <real-dir> up to / holds a .git entry.
fm_ak_supervisor_declaration_outside_repos() {
  local cur=$1
  while :; do
    if [ -e "$cur/.git" ] || [ -L "$cur/.git" ]; then
      echo "warning: agent-kit supervisor declaration: $1 is inside the git repository at $cur; set XDG_STATE_HOME to a directory outside every repository" >&2
      return 1
    fi
    [ "$cur" != / ] || return 0
    cur=${cur%/*}
    [ -n "$cur" ] || cur=/
  done
}

fm_ak_supervisor_declaration_ensure() {
  local dir probe real file tmp
  dir=$(fm_ak_supervisor_declaration_dir) || return 1
  # Walk the nearest existing ancestor before creating anything, so a refused
  # location gains no new directory.
  probe=$dir
  while [ ! -d "$probe" ]; do
    probe=${probe%/*}
    [ -n "$probe" ] || probe=/
  done
  probe=$(cd -P -- "$probe" && pwd -P) &&
    fm_ak_supervisor_declaration_outside_repos "$probe" || return 1
  if ! mkdir -p -- "$dir" 2>/dev/null || ! real=$(cd -P -- "$dir" && pwd -P); then
    echo "warning: agent-kit supervisor declaration: cannot create $dir" >&2
    return 1
  fi
  fm_ak_supervisor_declaration_outside_repos "$real" || return 1
  file=$real/supervisor-declaration.json
  if [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] &&
    cmp -s -- "$file" <(fm_ak_supervisor_declaration_payload); then
    printf '%s\n' "$file"
    return 0
  fi
  # A rename onto a directory, or a link to one, would move the temporary file
  # inside it instead of replacing the declaration.
  if [ -d "$file" ]; then
    echo "warning: agent-kit supervisor declaration: $file is a directory or a link to one" >&2
    return 1
  fi
  tmp=$(mktemp "$real/.supervisor-declaration.json.XXXXXX" 2>/dev/null) || {
    echo "warning: agent-kit supervisor declaration: cannot write in $real" >&2
    return 1
  }
  if fm_ak_supervisor_declaration_payload > "$tmp" && chmod 0644 "$tmp" && mv -f -- "$tmp" "$file" &&
    [ -f "$file" ] && [ ! -L "$file" ] && cmp -s -- "$file" <(fm_ak_supervisor_declaration_payload); then
    printf '%s\n' "$file"
    return 0
  fi
  rm -f -- "$tmp"
  echo "warning: agent-kit supervisor declaration: cannot write $file" >&2
  return 1
}
