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
# Pibomeister/agent-kit, and (with --for-gate-project) the registered project's
# own GitHub repository for gate-script root-cause filing.
#
# Issue bodies include failure class, evidence lines, instance fix taken, and
# proposed root fix. Refuses text that looks like a credential or secret.
#
# Environment:
#   FM_HOME                 operational home (for --for-gate-project lookup)
#   FM_SELF_HEAL_ISSUE_GH   override gh/gh-axi binary path (tests)
#
# Exit 0 on success and prints `commented <n>` or `created <n> <url>` to stdout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-self-heal-issue.sh --repo <owner/name> --failure-class <key> --title <title>
      [--instance-fix <text>] [--proposed-fix <text>] [--evidence <line>]...
      [--for-gate-project <name>]
EOF
  exit 2
}

die() {
  printf 'fm-self-heal-issue: %s\n' "$1" >&2
  exit 1
}

fm_self_heal_gh() {
  if [ -n "${FM_SELF_HEAL_ISSUE_GH:-}" ]; then
    printf '%s\n' "$FM_SELF_HEAL_ISSUE_GH"
    return 0
  fi
  if command -v gh-axi >/dev/null 2>&1; then
    printf '%s\n' gh-axi
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    printf '%s\n' gh
    return 0
  fi
  die 'gh-axi or gh is required'
}

# fm_self_heal_repo_norm <owner/name|host/owner/repo>
fm_self_heal_repo_norm() {
  local arg=$1
  case $arg in
  */*/*)
    fm_role_scope_valid "$arg" || return 1
    fm_role_scope_norm "$arg"
    ;;
  */*)
    fm_role_scope_valid "github.com/$arg" || return 1
    fm_role_scope_norm "github.com/$arg"
    ;;
  *) return 1 ;;
  esac
}

# fm_self_heal_gh_repo <github.com/owner/repo>
fm_self_heal_gh_repo() {
  local norm=$1
  case $norm in
  github.com/*/*) printf '%s\n' "${norm#github.com/}" ;;
  *) return 1 ;;
  esac
}

fm_self_heal_fixed_repo_p() {
  case $1 in
  github.com/pibomeister/firstmate | github.com/pibomeister/agent-kit) return 0 ;;
  esac
  return 1
}

# fm_self_heal_repo_allowed <norm> [<for-gate-project>]
fm_self_heal_repo_allowed() {
  local norm=$1 gate_project=${2:-} home target proj_dir
  if fm_self_heal_fixed_repo_p "$norm"; then
    return 0
  fi
  [ -n "$gate_project" ] || return 1
  home=${FM_HOME:-}
  [ -n "$home" ] || return 1
  proj_dir="$home/projects/$gate_project"
  [ -d "$proj_dir" ] || return 1
  target=$(fm_role_publication_target "$proj_dir") || return 1
  [ -n "$target" ] || return 1
  case $target in
  path:*) return 1 ;;
  esac
  target=$(fm_role_scope_norm "$target")
  [ "$norm" = "$target" ]
}

fm_self_heal_class_valid() {
  case $1 in
  '' | *[!a-zA-Z0-9._-]* | *..*) return 1 ;;
  esac
  return 0
}

fm_self_heal_secret_p() {
  local text=$1
  case $text in
  *ghp_* | *gho_* | *ghu_* | *ghs_* | *ghr_* | *github_pat_* ) return 0 ;;
  *x-access-token:* | *Bearer\ * | *Authorization:* ) return 0 ;;
  esac
  return 1
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

fm_self_heal_build_body() {
  local class=$1 instance=$2 proposed=$3
  shift 3
  local -a evidence=("$@")
  local line
  printf '## Failure class\n%s\n\n' "$class"
  printf '## Evidence\n'
  if [ "${#evidence[@]}" -eq 0 ]; then
    printf '(none supplied)\n'
  else
    for line in "${evidence[@]}"; do
      printf -- '- %s\n' "$line"
    done
  fi
  printf '\n## Instance fix taken\n%s\n\n' "${instance:-none recorded}"
  printf '## Proposed root fix\n%s\n' "${proposed:-none recorded}"
}

fm_self_heal_ensure_label() {
  local gh=$1 gh_repo=$2 name=$3 color=${4:-ededed}
  if "$gh" label list --repo "$gh_repo" --limit 500 --json name --jq '.[].name' 2>/dev/null \
    | grep -Fxq "$name"; then
    return 0
  fi
  "$gh" label create "$name" --repo "$gh_repo" --color "$color" --force >/dev/null \
    || die "could not create label $name"
}

REPO='' CLASS='' TITLE='' INSTANCE='' PROPOSED='' GATE_PROJECT=''
EVIDENCE=()

while [ "$#" -gt 0 ]; do
  case $1 in
  --repo) REPO=${2:-}; shift 2 ;;
  --failure-class) CLASS=${2:-}; shift 2 ;;
  --title) TITLE=${2:-}; shift 2 ;;
  --instance-fix) INSTANCE=${2:-}; shift 2 ;;
  --proposed-fix) PROPOSED=${2:-}; shift 2 ;;
  --evidence) EVIDENCE+=("${2:-}"); shift 2 ;;
  --for-gate-project) GATE_PROJECT=${2:-}; shift 2 ;;
  -h | --help) usage ;;
  *) die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] && [ -n "$CLASS" ] && [ -n "$TITLE" ] || usage
fm_self_heal_class_valid "$CLASS" || die 'failure-class key must be non-empty alphanumeric with . _ - only'
norm=$(fm_self_heal_repo_norm "$REPO") || die "invalid --repo: $REPO"
fm_self_heal_repo_allowed "$norm" "$GATE_PROJECT" \
  || die "repository $REPO is outside the approved self-heal targets"
fm_self_heal_refuse_secrets "$TITLE" "$INSTANCE" "$PROPOSED" "${EVIDENCE[@]}"

gh_repo=$(fm_self_heal_gh_repo "$norm") || die "internal error: could not derive gh repo from $norm"
gh_bin=$(fm_self_heal_gh)
class_label="failure-class:$CLASS"
body=$(fm_self_heal_build_body "$CLASS" "$INSTANCE" "$PROPOSED" "${EVIDENCE[@]}")
comment_body=$'## New evidence\n'"$(printf '%s\n' "${EVIDENCE[@]}" | sed '/^$/d' | sed 's/^/- /')"
[ -n "$comment_body" ] || comment_body='## New evidence\n(none supplied)'

fm_self_heal_ensure_label "$gh_bin" "$gh_repo" self-heal B60205
fm_self_heal_ensure_label "$gh_bin" "$gh_repo" "$class_label" 5319E7

existing=$("$gh_bin" issue list --repo "$gh_repo" --label "$class_label" --state open \
  --json number --jq '.[0].number // empty' 2>/dev/null) || die 'could not search open issues'
case $existing in
'' | *[!0-9]*) existing='' ;;
esac

if [ -n "$existing" ]; then
  "$gh_bin" issue comment "$existing" --repo "$gh_repo" --body "$comment_body" >/dev/null \
    || die "could not comment on issue #$existing"
  printf 'commented %s\n' "$existing"
  exit 0
fi

out=$("$gh_bin" issue create --repo "$gh_repo" --title "$TITLE" \
  --label self-heal --label "$class_label" --body "$body" 2>&1) || die "could not create issue: $out"
num=$(printf '%s\n' "$out" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p' | tail -n 1)
[ -n "$num" ] || num=$(printf '%s\n' "$out" | awk '/^[0-9]+$/{print; exit}')
printf 'created %s %s\n' "$num" "$out"
