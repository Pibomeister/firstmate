#!/usr/bin/env bash
# Behavior tests for bin/fm-self-heal-issue.sh (Self-watching M1d).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-role-lib.sh"

SCRIPT="$ROOT/bin/fm-self-heal-issue.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-heal-issue)

make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
log=${FM_FAKE_SELF_HEAL_GH_LOG:?FM_FAKE_SELF_HEAL_GH_LOG must be set}
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  label)
    case "${2:-}" in
      list)
        if [ -f "${FM_FAKE_SELF_HEAL_LABELS:-}" ]; then
          while IFS= read -r _name || [ -n "$_name" ]; do
            [ -n "$_name" ] || continue
            printf '%s\n' "$_name"
          done < "${FM_FAKE_SELF_HEAL_LABELS}"
        fi
        exit 0
        ;;
      create)
        name=${4:-}
        [ -n "$name" ] || exit 1
        printf '%s\n' "$name" >> "${FM_FAKE_SELF_HEAL_LABELS:-/dev/null}"
        exit 0
        ;;
    esac
    ;;
  issue)
    case "${2:-}" in
      list)
        if [ -n "${FM_FAKE_SELF_HEAL_OPEN_ISSUE:-}" ]; then
          printf '%s\n' "$FM_FAKE_SELF_HEAL_OPEN_ISSUE"
        else
          printf '\n'
        fi
        exit 0
        ;;
      comment)
        printf 'commented %s\n' "${4:-}"
        exit 0
        ;;
      create)
        printf 'https://github.com/example/repo/issues/99\n'
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

prep_home() {
  local home=$1
  mkdir -p "$home/fakebin"
  : > "$home/gh.log"
  : > "$home/labels.txt"
  make_fake_gh "$home/fakebin"
}

run_script() {
  local home=$1
  shift
  FM_HOME="$home" FM_SELF_HEAL_ISSUE_GH="$home/fakebin/gh-axi" \
    FM_FAKE_SELF_HEAL_GH_LOG="$home/gh.log" \
    FM_FAKE_SELF_HEAL_LABELS="$home/labels.txt" \
    FM_FAKE_SELF_HEAL_OPEN_ISSUE="${FM_FAKE_SELF_HEAL_OPEN_ISSUE:-}" \
    "$BASH" "$SCRIPT" "$@" 2>&1
}

test_refuses_unapproved_repo() {
  local home out
  home="$TMP_ROOT/refuse-repo"
  prep_home "$home"
  out=$(run_script "$home" --repo evil/hack --failure-class demo --title 't' 2>&1) || true
  assert_contains "$out" 'outside the approved' "unknown repos must be refused"
  pass "unapproved repository is refused"
}

test_allows_fixed_repos() {
  local home out
  home="$TMP_ROOT/fixed-repos"
  prep_home "$home"
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't' \
    --evidence '2026-10-31 CDMX smoke')
  assert_contains "$out" 'created 99' "firstmate repo should create an issue"
  assert_contains "$(cat "$home/gh.log")" 'issue create' "gh should create when no open issue"
  pass "Pibomeister/firstmate is an approved target"
}

test_dedupe_comments() {
  local home out
  home="$TMP_ROOT/dedupe"
  prep_home "$home"
  printf 'self-heal\nfailure-class:dup-key\n' > "$home/labels.txt"
  FM_FAKE_SELF_HEAL_OPEN_ISSUE=42 out=$(run_script "$home" --repo Pibomeister/agent-kit \
    --failure-class dup-key --title 'ignored' --evidence 'second occurrence')
  FM_FAKE_SELF_HEAL_OPEN_ISSUE=
  assert_contains "$out" 'commented 42' "an open failure-class issue should receive a comment"
  assert_contains "$(cat "$home/gh.log")" 'issue comment 42' "gh should comment, not create"
  pass "dedupe comments on an open failure-class issue"
}

test_refuses_secrets() {
  local home out
  home="$TMP_ROOT/secrets"
  prep_home "$home"
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't' \
    --evidence 'token ghp_abcdefghijklmnopqrstuvwxyz1234567890' 2>&1) || true
  assert_contains "$out" 'secret' "credential-shaped evidence must be refused"
  pass "secret-shaped input is refused"
}

test_gate_project_repo() {
  local home out
  home="$TMP_ROOT/gate-project"
  prep_home "$home"
  mkdir -p "$home/projects/casco"
  git init -q "$home/projects/casco"
  git -C "$home/projects/casco" remote add origin 'https://github.com/Pibomeister/casco.git'
  git -C "$home/projects/casco" config remote.origin.gh-resolved base
  target=$(fm_role_publication_target "$home/projects/casco")
  out=$(run_script "$home" --repo Pibomeister/casco --for-gate-project casco \
    --failure-class gate --title 'gate fix' --evidence 'log path')
  assert_contains "$out" 'created 99' "registered project repo should be allowed with --for-gate-project"
  out=$(run_script "$home" --repo Pibomeister/casco --failure-class gate --title 'gate fix' 2>&1) || true
  assert_contains "$out" 'outside the approved' "project repo without flag must be refused"
  pass "gate-project filing allows the registered project repository only with --for-gate-project"
}

fm_test_run \
  test_refuses_unapproved_repo \
  test_allows_fixed_repos \
  test_dedupe_comments \
  test_refuses_secrets \
  test_gate_project_repo
