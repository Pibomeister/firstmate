#!/usr/bin/env bash
# File or dedupe a self-heal GitHub issue for a failure class (Self-watching M1d).
#
# Usage:
#   fm-self-heal-issue.sh --repo <owner/name> --failure-class <key> --title <title> \
#       [--instance-fix <text>] [--proposed-fix <text>] [--evidence <line>]... \
#       [--for-gate-project <registry-name>]
#
# Ensures the `self-heal` and `failure-class:<key>` labels exist, searches open
# issues with the failure-class label, and either comments with new evidence or
# opens a new issue. Approved repositories are Pibomeister/firstmate,
# Pibomeister/agent-kit, and (with --for-gate-project) the GitHub repository of
# the registered project's origin remote, for gate-script root-cause filing.
# Filing on Pibomeister/firstmate also requires this home's publication grant
# from the bin/fm-role-lib.sh gate: the config/firstmate-role maintainer opt-in.
#
# Issue bodies include failure class, evidence lines, instance fix taken, and
# proposed root fix. Refuses text that looks like a credential or secret.
#
# Environment:
#   FM_HOME   operational home (for --for-gate-project lookup and the role
#             file); defaults to FM_ROOT_OVERRIDE, then this checkout
#
# Requires gh. Exit 0 on success and prints `commented <n>` or
# `created <n> <url>` to stdout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  cat >&2 <<'USAGE'
usage:
  fm-self-heal-issue.sh --repo <owner/name> --failure-class <key> --title <title>
      [--instance-fix <text>] [--proposed-fix <text>] [--evidence <line>]...
      [--for-gate-project <name>]
USAGE
  exit 2
}

die() {
  printf 'fm-self-heal-issue: %s\n' "$1" >&2
  exit 1
}

# fm_self_heal_repo_norm <owner/name>
fm_self_heal_repo_norm() {
  local arg=$1
  case $arg in
  */*/*) return 1 ;;
  */*) ;;
  *) return 1 ;;
  esac
  fm_role_scope_valid "github.com/$arg" || return 1
  fm_role_scope_norm "github.com/$arg"
}

fm_self_heal_fixed_repo_p() {
  case $1 in
  github.com/pibomeister/firstmate | github.com/pibomeister/agent-kit) return 0 ;;
  esac
  return 1
}

# fm_self_heal_repo_allowed <norm> [<for-gate-project>]
fm_self_heal_repo_allowed() {
  local norm=$1 gate_project=${2:-} target proj_dir url
  if fm_self_heal_fixed_repo_p "$norm"; then
    return 0
  fi
  [ -n "$gate_project" ] || return 1
  fm_self_heal_key_valid "$gate_project" || return 1
  proj_dir="$FM_HOME/projects/$gate_project"
  [ -e "$proj_dir/.git" ] || return 1
  url=$(git -C "$proj_dir" remote get-url origin 2>/dev/null) || return 1
  target=$(fm_role_remote_identity "$url" "$proj_dir") || return 1
  [ -n "$target" ] || return 1
  [ "$norm" = "$target" ]
}

# fm_self_heal_require_firstmate_grant <norm> - die unless the gate authorizes
# this home to publish to exactly <norm>.
fm_self_heal_require_firstmate_grant() {
  local norm=$1
  if fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$FM_ROOT" "$FM_ROOT" \
    && [ "$FM_ROLE_PUB_TARGET" = "$norm" ]; then
    return 0
  fi
  die "refusing to publish to $norm: this home is missing the grant 'maintainer $norm' in $CONFIG/firstmate-role (${FM_ROLE_PUB_DENIAL:-the checkout at $FM_ROOT publishes to ${FM_ROLE_PUB_TARGET:-no firstmate repository}})"
}

fm_self_heal_key_valid() {
  case $1 in
  '' | *[!a-zA-Z0-9._-]* | *..* | .*) return 1 ;;
  esac
  return 0
}

fm_self_heal_secret_p() {
  LC_ALL=C grep -Eiq \
    -e '(^|[^a-z0-9])(gh[pousr]_|github_pat_)[a-z0-9_]' \
    -e 'x-access-token' \
    -e 'authorization[[:space:]]*:' \
    -e '(^|[^a-z0-9])bearer[[:space:]]+[^[:space:]]' \
    -e 'https?://[^/[:space:]@]+@' \
    -e '://[^/[:space:]@]+:[^/[:space:]@]*@' \
    -e '(^|[^a-z0-9])sk-[a-z0-9_-]{8,}' \
    -e '(^|[^a-z0-9])(akia|asia)[a-z0-9]{16}' \
    -e '(token|password|passwd|pwd|secret|secret[_-]?key|api[_-]?key|access[_-]?key)["'"'"']?[[:space:]]*[=:][[:space:]]*[^[:space:]]' \
    -e '-----BEGIN [a-z ]*PRIVATE KEY' \
    <<< "$1"
}

fm_self_heal_refuse_secrets() {
  local part
  for part in "$@"; do
    [ -n "$part" ] || continue
    if fm_self_heal_secret_p "$part"; then
      die 'refusing input that looks like a secret; redact before filing'
    fi
  done
}

# fm_self_heal_evidence_block [<line>]... - the markdown list of non-empty lines.
fm_self_heal_evidence_block() {
  local line found=
  for line in "$@"; do
    [ -n "$line" ] || continue
    printf -- '- %s\n' "$line"
    found=1
  done
  [ -n "$found" ] || printf '(none supplied)\n'
}

fm_self_heal_build_body() {
  local class=$1 instance=$2 proposed=$3 evidence=$4
  printf '## Failure class\n%s\n\n' "$class"
  printf '## Evidence\n%s\n' "$evidence"
  printf '\n## Instance fix taken\n%s\n\n' "${instance:-none recorded}"
  printf '## Proposed root fix\n%s\n' "${proposed:-none recorded}"
}

fm_self_heal_ensure_label() {
  local gh_repo=$1 name=$2 color=$3
  if gh label list --repo "$gh_repo" --limit 500 --json name --jq '.[].name' 2>/dev/null \
    | grep -Fxq -- "$name"; then
    return 0
  fi
  gh label create "$name" --repo "$gh_repo" --color "$color" --force >/dev/null \
    || die "could not create label $name"
}

REPO='' CLASS='' TITLE='' INSTANCE='' PROPOSED='' GATE_PROJECT=''
EVIDENCE=()

while [ "$#" -gt 0 ]; do
  case $1 in
  -h | --help) usage ;;
  --repo | --failure-class | --title | --instance-fix | --proposed-fix | --evidence | --for-gate-project)
    [ "$#" -ge 2 ] || usage
    ;;
  esac
  case $1 in
  --repo) REPO=$2; shift 2 ;;
  --failure-class) CLASS=$2; shift 2 ;;
  --title) TITLE=$2; shift 2 ;;
  --instance-fix) INSTANCE=$2; shift 2 ;;
  --proposed-fix) PROPOSED=$2; shift 2 ;;
  --evidence) EVIDENCE+=("$2"); shift 2 ;;
  --for-gate-project) GATE_PROJECT=$2; shift 2 ;;
  *) die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] && [ -n "$CLASS" ] && [ -n "$TITLE" ] || usage
fm_self_heal_key_valid "$CLASS" || die 'failure-class key must be non-empty alphanumeric with . _ - only'
norm=$(fm_self_heal_repo_norm "$REPO") || die "invalid --repo (expected owner/name): $REPO"
fm_self_heal_repo_allowed "$norm" "$GATE_PROJECT" \
  || die "repository $REPO is outside the approved self-heal targets"
[ "$norm" != github.com/pibomeister/firstmate ] || fm_self_heal_require_firstmate_grant "$norm"
fm_self_heal_refuse_secrets "$CLASS" "$TITLE" "$INSTANCE" "$PROPOSED" ${EVIDENCE[@]+"${EVIDENCE[@]}"}

command -v gh >/dev/null 2>&1 || die 'gh is required'
gh_repo=${norm#github.com/}
class_label="failure-class:$CLASS"
evidence_block=$(fm_self_heal_evidence_block ${EVIDENCE[@]+"${EVIDENCE[@]}"})

fm_self_heal_ensure_label "$gh_repo" self-heal B60205
fm_self_heal_ensure_label "$gh_repo" "$class_label" 5319E7

existing=$(gh issue list --repo "$gh_repo" --label "$class_label" --state open \
  --json number --jq '.[0].number // empty') || die 'could not search open issues'
case $existing in
*[!0-9]*) die "unexpected issue search result: $existing" ;;
esac

if [ -n "$existing" ]; then
  gh issue comment "$existing" --repo "$gh_repo" --body $'## New evidence\n'"$evidence_block" >/dev/null \
    || die "could not comment on issue #$existing"
  printf 'commented %s\n' "$existing"
  exit 0
fi

body=$(fm_self_heal_build_body "$CLASS" "$INSTANCE" "$PROPOSED" "$evidence_block")
url=$(gh issue create --repo "$gh_repo" --title "$TITLE" \
  --label self-heal --label "$class_label" --body "$body") || die 'could not create issue'
num=$(printf '%s\n' "$url" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p' | tail -n 1)
[ -n "$num" ] || die "issue created but its number is not in the gh output: $url"
printf 'created %s %s\n' "$num" "$url"
