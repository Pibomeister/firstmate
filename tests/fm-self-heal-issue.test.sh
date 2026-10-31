#!/usr/bin/env bash
# Behavior tests for bin/fm-self-heal-issue.sh (Self-watching M1d).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-self-heal-issue.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-heal-issue)

# The fake accepts only the gh flags each subcommand really supports, and an
# unknown flag fails the call as the real CLI does.
make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
log=${FM_FAKE_SELF_HEAL_GH_LOG:?FM_FAKE_SELF_HEAL_GH_LOG must be set}
printf '%s\n' "$*" >> "$log"
sub="${1:-} ${2:-}"
shift 2
positional= repo= state= json= jq= labels=
while [ "$#" -gt 0 ]; do
  case "$sub:$1" in
    *:--repo) repo=$2; shift 2 ;;
    "label list:--limit" | "issue list:--limit") shift 2 ;;
    "label list:--json" | "issue list:--json") json=$2; shift 2 ;;
    "label list:--jq" | "issue list:--jq") jq=$2; shift 2 ;;
    "issue list:--state") state=$2; shift 2 ;;
    "issue list:--label" | "issue create:--label") labels="$labels $2"; shift 2 ;;
    "label create:--color") shift 2 ;;
    "label create:--force") shift ;;
    "issue comment:--body" | "issue create:--body" | "issue create:--title") shift 2 ;;
    *:-*) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    *) positional=$1; shift ;;
  esac
done
[ -n "$repo" ] || { printf 'missing --repo\n' >&2; exit 1; }
case $sub in
  'label list')
    [ "$json" = name ] && [ -n "$jq" ] || exit 1
    cat "$FM_FAKE_SELF_HEAL_LABELS"
    ;;
  'label create')
    [ -n "$positional" ] || exit 1
    printf '%s\n' "$positional" >> "$FM_FAKE_SELF_HEAL_LABELS"
    ;;
  'issue list')
    [ "$json" = number ] && [ -n "$jq" ] || exit 1
    case "$labels:$state" in
      " $FM_FAKE_SELF_HEAL_OPEN_LABEL:open") printf '%s\n' "${FM_FAKE_SELF_HEAL_OPEN_ISSUE:-}" ;;
    esac
    ;;
  'issue comment')
    [ -n "$positional" ] || exit 1
    ;;
  'issue create')
    printf 'https://github.com/%s/issues/99\n' "$repo"
    ;;
  *)
    printf 'unknown command: %s\n' "$sub" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_FAKE_SELF_HEAL_GH_LOG"
exit 1
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
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_FAKE_SELF_HEAL_GH_LOG="$home/gh.log" \
    FM_FAKE_SELF_HEAL_LABELS="$home/labels.txt" \
    FM_FAKE_SELF_HEAL_OPEN_LABEL="${FM_FAKE_SELF_HEAL_OPEN_LABEL:-}" \
    FM_FAKE_SELF_HEAL_OPEN_ISSUE="${FM_FAKE_SELF_HEAL_OPEN_ISSUE:-}" \
    "$BASH" "$SCRIPT" "$@" 2>&1
}

assert_no_gh_calls() {
  assert_equals '' "$(cat "$1/gh.log")" "$2 must not call gh"
}

add_project() {
  local home=$1 name=$2 origin=$3
  mkdir -p "$home/projects/$name"
  git init -q "$home/projects/$name"
  git -C "$home/projects/$name" remote add origin "$origin"
}

test_refuses_unapproved_repo() {
  local home out rc=0
  home="$TMP_ROOT/refuse-repo"
  prep_home "$home"
  out=$(run_script "$home" --repo evil/hack --failure-class demo --title 't') || rc=$?
  assert_equals 1 "$rc" "unknown repos must exit 1"
  assert_contains "$out" 'outside the approved' "unknown repos must be refused"
  assert_no_gh_calls "$home" "a refused repo"
  pass "unapproved repository is refused with no gh calls"
}

test_repo_is_owner_name_only() {
  local home out spelling rc
  home="$TMP_ROOT/repo-spelling"
  prep_home "$home"
  for spelling in github.com/Pibomeister/firstmate Pibomeister firstmate/ ; do
    rc=0
    out=$(run_script "$home" --repo "$spelling" --failure-class demo --title 't') || rc=$?
    assert_equals 1 "$rc" "--repo $spelling must exit 1"
    assert_contains "$out" 'invalid --repo' "--repo $spelling must be invalid"
  done
  assert_no_gh_calls "$home" "an invalid --repo"
  pass "--repo accepts owner/name only"
}

test_new_issue_labels_and_body() {
  local home out log
  home="$TMP_ROOT/new-issue"
  prep_home "$home"
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 'the title' \
    --instance-fix 'restarted watcher' --proposed-fix 'add a guard' \
    --evidence '2026-10-31 10:54 CDMX /tmp/run.log' --evidence 'sha 403a8764')
  assert_contains "$out" 'created 99 https://github.com/pibomeister/firstmate/issues/99' "no open issue should create one"
  log=$(cat "$home/gh.log")
  assert_contains "$log" 'label create self-heal --repo pibomeister/firstmate' "self-heal should be created when missing"
  assert_contains "$log" 'label create failure-class:demo --repo pibomeister/firstmate' "class label should be created when missing"
  assert_contains "$log" 'issue list --repo pibomeister/firstmate --label failure-class:demo --state open' "search should use the class label on open issues"
  assert_contains "$log" '--label self-heal --label failure-class:demo' "the issue should carry both labels"
  assert_contains "$log" $'## Failure class\ndemo' "body should name the failure class"
  assert_contains "$log" '- 2026-10-31 10:54 CDMX /tmp/run.log' "body should list evidence"
  assert_contains "$log" '- sha 403a8764' "body should list every evidence line"
  assert_contains "$log" $'## Instance fix taken\nrestarted watcher' "body should hold the instance fix"
  assert_contains "$log" $'## Proposed root fix\nadd a guard' "body should hold the proposed fix"
  assert_not_contains "$log" 'gh-axi' "gh-axi must not be used even when installed"
  pass "a new issue gets both labels and the full body"
}

test_existing_labels_not_recreated() {
  local home
  home="$TMP_ROOT/labels-exist"
  prep_home "$home"
  printf 'self-heal\nfailure-class:demo\n' > "$home/labels.txt"
  run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't' --evidence 'e' >/dev/null
  assert_not_contains "$(cat "$home/gh.log")" 'label create' "existing labels must not be recreated"
  pass "existing labels are not recreated"
}

test_no_evidence_new_issue() {
  local home out rc=0
  home="$TMP_ROOT/no-evidence"
  prep_home "$home"
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't') || rc=$?
  assert_equals 0 "$rc" "--evidence is optional: $out"
  assert_contains "$out" 'created 99' "a run without evidence should still file"
  assert_contains "$(cat "$home/gh.log")" $'## Evidence\n(none supplied)' "body should say no evidence was supplied"
  pass "a new issue without evidence says none was supplied"
}

test_dedupe_comments() {
  local home out log
  home="$TMP_ROOT/dedupe"
  prep_home "$home"
  printf 'self-heal\nfailure-class:dup-key\n' > "$home/labels.txt"
  out=$(FM_FAKE_SELF_HEAL_OPEN_LABEL=failure-class:dup-key FM_FAKE_SELF_HEAL_OPEN_ISSUE=42 \
    run_script "$home" --repo Pibomeister/agent-kit \
    --failure-class dup-key --title 'ignored' --evidence 'second occurrence' --evidence '')
  assert_equals 'commented 42' "$out" "an open failure-class issue should receive a comment"
  log=$(cat "$home/gh.log")
  assert_contains "$log" 'issue comment 42 --repo pibomeister/agent-kit' "gh should comment on the match"
  assert_contains "$log" $'## New evidence\n- second occurrence' "the comment should hold the new evidence"
  assert_not_contains "$log" 'issue create' "a match must not file a new issue"
  assert_not_contains "$log" $'- \n' "empty evidence lines must be dropped"
  pass "dedupe comments with the new evidence on an open failure-class issue"
}

test_dedupe_comment_without_evidence() {
  local home out rc=0
  home="$TMP_ROOT/dedupe-none"
  prep_home "$home"
  out=$(FM_FAKE_SELF_HEAL_OPEN_LABEL=failure-class:k FM_FAKE_SELF_HEAL_OPEN_ISSUE=7 \
    run_script "$home" --repo Pibomeister/firstmate --failure-class k --title 't') || rc=$?
  assert_equals 0 "$rc" "a repeat without evidence should succeed: $out"
  assert_contains "$(cat "$home/gh.log")" $'## New evidence\n(none supplied)' "the comment should say no evidence was supplied"
  pass "a comment without evidence says none was supplied"
}

test_refuses_secrets() {
  local home out secret rc
  home="$TMP_ROOT/secrets"
  prep_home "$home"
  for secret in \
    'token ghp_abcdefghijklmnopqrstuvwxyz1234567890' \
    'authorization: token abc123' \
    'Authorization: Bearer abc123' \
    'bearer abc123' \
    'https://user:tok3n@github.com/x/y.git' \
    'https://tok3n@github.com/x/y.git' \
    'x-access-token:abc' \
    'key sk-ant-api03-abcdefgh' \
    'id AKIAIOSFODNN7EXAMPLE' \
    'password=hunter2' \
    'GH_TOKEN=abc' \
    'secret: abc' \
    'API_KEY=abc' \
    '-----BEGIN RSA PRIVATE KEY-----' ; do
    rc=0
    out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't' \
      --evidence 'clean line' --evidence "$secret") || rc=$?
    assert_equals 1 "$rc" "must refuse: $secret"
    assert_contains "$out" 'secret' "must name the reason for: $secret"
  done
  rc=0
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 'password=hunter2') || rc=$?
  assert_equals 1 "$rc" "the title goes through the same filter"
  rc=0
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't' \
    --proposed-fix 'bearer abc123') || rc=$?
  assert_equals 1 "$rc" "the proposed fix goes through the same filter"
  rc=0
  out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class ghp_abcdefgh --title 't') || rc=$?
  assert_equals 1 "$rc" "the failure-class key goes through the same filter"
  assert_no_gh_calls "$home" "refused secrets"
  pass "secret-shaped input is refused with no gh calls"
}

test_ordinary_evidence_passes() {
  local home out line
  home="$TMP_ROOT/ordinary"
  prep_home "$home"
  for line in \
    'task-1234567890 risk-assessment-pending failed' \
    '2026-10-31 10:54 CDMX http://127.0.0.1:4387/session/abc sha 403a8764' \
    'ssh://git@github.com/x/y.git rejected' \
    'highs_abc in logs_dir' ; do
    out=$(run_script "$home" --repo Pibomeister/firstmate --failure-class demo --title 't' --evidence "$line")
    assert_contains "$out" 'created 99' "ordinary evidence must pass: $line"
  done
  pass "ordinary log lines pass the secret filter"
}

test_gate_project_repo() {
  local home out rc=0
  home="$TMP_ROOT/gate-project"
  prep_home "$home"
  add_project "$home" casco 'https://github.com/Pibomeister/casco.git'
  out=$(run_script "$home" --repo Pibomeister/casco --for-gate-project casco \
    --failure-class gate --title 'gate fix' --evidence 'log path')
  assert_contains "$out" 'created 99' "registered project repo should be allowed with --for-gate-project"
  out=$(run_script "$home" --repo Pibomeister/casco --failure-class gate --title 'gate fix') || rc=$?
  assert_equals 1 "$rc" "project repo without the flag must exit 1"
  assert_contains "$out" 'outside the approved' "project repo without flag must be refused"
  pass "gate-project filing allows the registered project repository only with --for-gate-project"
}

test_gate_project_is_origin_only() {
  local home out rc
  home="$TMP_ROOT/gate-origin"
  prep_home "$home"
  add_project "$home" fork 'https://github.com/Pibomeister/foo.git'
  git -C "$home/projects/fork" remote add upstream 'https://github.com/third-party/foo.git'
  git -C "$home/projects/fork" config remote.upstream.gh-resolved base
  out=$(run_script "$home" --repo Pibomeister/foo --for-gate-project fork \
    --failure-class gate --title 't' --evidence 'e')
  assert_contains "$out" 'created 99' "the origin repository should be allowed"
  : > "$home/gh.log"
  rc=0
  out=$(run_script "$home" --repo third-party/foo --for-gate-project fork \
    --failure-class gate --title 't' --evidence 'e') || rc=$?
  assert_equals 1 "$rc" "a third-party upstream must exit 1"
  assert_contains "$out" 'outside the approved' "a third-party upstream must be refused"
  assert_no_gh_calls "$home" "a refused upstream"
  pass "gate-project filing allows the origin remote only"
}

test_gate_project_stays_in_registry() {
  local home out rc name repo
  home="$TMP_ROOT/gate-escape"
  prep_home "$home"
  add_project "$home" outside 'https://github.com/third-party/outside.git'
  mv "$home/projects/outside" "$home/outside"
  mkdir -p "$home/projects/plain"
  git init -q "$home"
  git -C "$home" remote add origin 'https://github.com/third-party/home.git'
  for name in ../outside plain . ; do
    for repo in third-party/outside third-party/home ; do
      rc=0
      out=$(run_script "$home" --repo "$repo" --for-gate-project "$name" \
        --failure-class gate --title 't') || rc=$?
      assert_equals 1 "$rc" "--for-gate-project $name must not approve $repo"
    done
  done
  assert_no_gh_calls "$home" "a project outside the registry"
  pass "gate-project lookup cannot leave the registered project's own clone"
}

test_fm_home_defaults_to_checkout() {
  local checkout out
  checkout="$TMP_ROOT/default-home"
  prep_home "$checkout"
  mkdir -p "$checkout/bin"
  cp "$ROOT"/bin/fm-self-heal-issue.sh "$ROOT"/bin/fm-role-lib.sh "$ROOT"/bin/fm-bash-compat-lib.sh "$checkout/bin/"
  add_project "$checkout" casco 'git@github.com:Pibomeister/casco.git'
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE PATH="$checkout/fakebin:$PATH" \
    FM_FAKE_SELF_HEAL_GH_LOG="$checkout/gh.log" FM_FAKE_SELF_HEAL_LABELS="$checkout/labels.txt" \
    FM_FAKE_SELF_HEAL_OPEN_LABEL='' FM_FAKE_SELF_HEAL_OPEN_ISSUE='' \
    "$BASH" "$checkout/bin/fm-self-heal-issue.sh" --repo Pibomeister/casco --for-gate-project casco \
    --failure-class gate --title 't' --evidence 'e' 2>&1)
  assert_contains "$out" 'created 99' "unset FM_HOME should default to the checkout: $out"
  pass "unset FM_HOME defaults to the checkout"
}

test_missing_flag_value_is_usage_error() {
  local home out rc=0
  home="$TMP_ROOT/missing-value"
  prep_home "$home"
  out=$(run_script "$home" --repo) || rc=$?
  assert_equals 2 "$rc" "a flag without a value must be a usage error"
  assert_contains "$out" 'usage:' "a flag without a value should print usage"
  pass "a flag without a value is a usage error"
}

fm_test_run \
  test_refuses_unapproved_repo \
  test_repo_is_owner_name_only \
  test_new_issue_labels_and_body \
  test_existing_labels_not_recreated \
  test_no_evidence_new_issue \
  test_dedupe_comments \
  test_dedupe_comment_without_evidence \
  test_refuses_secrets \
  test_ordinary_evidence_passes \
  test_gate_project_repo \
  test_gate_project_is_origin_only \
  test_gate_project_stays_in_registry \
  test_fm_home_defaults_to_checkout \
  test_missing_flag_value_is_usage_error
