#!/usr/bin/env bash
# tests/fm-afk-preallow.test.sh - the away-mode pre-allow list owner
# (bin/fm-afk-preallow.sh): which recorded permission dialogs become an entry,
# which are left off and why, the approval record bound to the exact list, the
# one reader that prints nothing without that record, and the real fm-spawn
# writing the approved entries into a Claude worker's settings only while an
# away record is in force.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PREALLOW="$ROOT/bin/fm-afk-preallow.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-preallow-tests)
RULE=$(printf '╌%.0s' $(seq 1 40))

make_home() {  # <name> -> prints the home dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state/watchdog" "$dir/config"
  printf '%s\n' "$dir"
}

preallow() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$PREALLOW" "$@"
}

row() {  # <home> <epoch> <subject> <symptom> <action> <phase> <detail>
  printf '%s\tid-%s\t/homes/main\t%s\t%s\t%s\t%s\t%s\n' "$2" "$2" "$3" "$4" "$5" "$6" "$7" >> "$1/state/watchdog/actions.tsv"
}

prompt() {  # <command> -> the recorded text of one whole Bash prompt
  printf ' Bash command Run it %s %s %s Do you want to proceed? ❯ 1. Yes 2. No Esc to cancel' "$RULE" "$1" "$RULE"
}

seed_ledger() {  # <home>
  local h=$1
  row "$h" 100 worker:a dialog page pending "permission: $(prompt 'ls -la')"
  row "$h" 100 worker:a dialog page "done" "owner paged"
  row "$h" 300 worker:b dialog page dry-run "would page the owner; permission: $(prompt 'ls -la')"
  row "$h" 200 main dialog page pending "permission: $(prompt 'git status --short')"
  row "$h" 210 main dialog page pending "permission: $(prompt 'rm -rf build')"
  row "$h" 220 main dialog page pending "permission: $(prompt 'echo a && echo b')"
  row "$h" 230 main dialog page pending "permission: $(prompt 'curl -H token=abcdef12345 example.test')"
  row "$h" 240 main dialog page pending "permission: [withheld: a credential or sign-in prompt]"
  row "$h" 250 main dialog page pending "permission:  Edit file notes.md $RULE text $RULE Do you want to make this edit?"
  row "$h" 260 main dialog page pending "permission:  Bash command Run it $RULE git log --oneline --decorate --gra"
  row "$h" 270 main dialog key dry-run "would press 0: dismiss the feedback survey"
  row "$h" 280 main quota suggest held "permission: $(prompt 'whoami')"
}

test_derive_keeps_exact_commands_and_reports_the_rest() {
  local h out
  h=$(make_home derive)
  seed_ledger "$h"
  out=$(preallow "$h" derive) || fail "derive failed: $out"
  assert_contains "$out" "entries=2 excluded=6" "derive counts entries and left-off dialogs"
  assert_equals "$(printf 'Bash(git status --short)\nBash(ls -la)')" "$(cat "$h/state/afk-preallow/candidate.list")" \
    "the list holds the exact commands, sorted"
  assert_grep "$(printf 'Bash(ls -la)\t2\t100\t300\tmain/worker:a, main/worker:b\tls -la')" "$h/state/afk-preallow/candidate.tsv" \
    "an entry carries its count, first and last time, and sources"
  assert_grep "hard-stop category: destructive" "$h/state/afk-preallow/excluded.tsv" "a destructive command is left off"
  assert_grep "shell operator" "$h/state/afk-preallow/excluded.tsv" "a compound command is left off"
  assert_grep "withheld" "$h/state/afk-preallow/excluded.tsv" "a withheld dialog is left off"
  assert_grep "not a Bash command prompt" "$h/state/afk-preallow/excluded.tsv" "another tool's prompt is left off"
  assert_grep "cut off in the ledger" "$h/state/afk-preallow/excluded.tsv" "a cut-off command is left off"
  out=$(cat "$h/state/afk-preallow/"*)
  assert_not_contains "$out" "abcdef12345" "a secret-like command is never copied into the report"
  assert_not_contains "$out" "rm -rf" "a hard-stop command is never copied into the report"
  assert_not_contains "$out" "whoami" "a row that is not a permission page gives no entry"
  [ ! -e "$h/config/afk-preallow.list" ] && [ ! -e "$h/config/afk-preallow.approval" ] || fail "derive must not write an approved list"
  pass "derive keeps exact Bash commands and reports every left-off dialog with its reason"
}

test_nothing_is_approved_without_a_matching_record() {
  local h out sha rc
  h=$(make_home approve)
  seed_ledger "$h"
  out=$(preallow "$h" derive)
  sha=${out#sha256=}
  sha=${sha%% *}
  out=$(preallow "$h" approved 2>&1)
  expect_code 1 $? "no approval record means nothing approved"
  assert_equals "" "$out" "nothing is printed without an approval"

  out=$(preallow "$h" approve --sha256 0000 --ref order-1 2>&1)
  expect_code 3 $? "a wrong checksum is refused"
  [ ! -e "$h/config/afk-preallow.approval" ] || fail "a refused approval must record nothing"

  out=$(preallow "$h" approve --sha256 "$sha" --ref order-1 2>&1) || fail "approve failed: $out"
  out=$(preallow "$h" approved) || fail "approved read failed"
  assert_equals "$(printf 'Bash(git status --short)\nBash(ls -la)')" "$out" "the approved read prints the exact list"
  assert_contains "$(preallow "$h" status)" "approval: in force" "status names the approval"

  printf 'Bash(touch extra)\n' >> "$h/config/afk-preallow.list"
  out=$(preallow "$h" approved 2>/dev/null)
  expect_code 3 $? "a list changed after approval is refused"
  assert_equals "" "$out" "a changed list prints nothing"

  # A hand-made list and a record that matches it still never pass a hard stop.
  printf 'Bash(ls -la)\nBash(rm -rf build)\n' > "$h/config/afk-preallow.list"
  printf 'version: 1\nsha256: %s\napproved_epoch: 1\nref: forged\n' "$(shasum -a 256 "$h/config/afk-preallow.list" 2>/dev/null | awk '{print $1}' || sha256sum "$h/config/afk-preallow.list" | awk '{print $1}')" \
    > "$h/config/afk-preallow.approval"
  out=$(preallow "$h" approved 2>/dev/null)
  expect_code 3 $? "a hard-stop entry is refused even with a matching record"
  assert_equals "" "$out" "a list with a hard-stop entry prints nothing"
  printf 'Bash(ls:*)\n' > "$h/config/afk-preallow.list"
  printf 'version: 1\nsha256: %s\napproved_epoch: 1\nref: forged\n' "$(shasum -a 256 "$h/config/afk-preallow.list" 2>/dev/null | awk '{print $1}' || sha256sum "$h/config/afk-preallow.list" | awk '{print $1}')" \
    > "$h/config/afk-preallow.approval"
  out=$(preallow "$h" approved 2>/dev/null)
  expect_code 3 $? "a wildcard entry is refused even with a matching record"

  preallow "$h" revoke >/dev/null || fail "revoke failed"
  preallow "$h" approved >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "revoke leaves nothing approved"
  pass "the reader prints entries only for a valid list whose checksum the approval record names"
}

test_an_empty_candidate_cannot_be_approved() {
  local h out sha
  h=$(make_home empty)
  row "$h" 270 main dialog key dry-run "would press 0: dismiss the feedback survey"
  out=$(preallow "$h" derive) || fail "derive failed: $out"
  assert_contains "$out" "entries=0 excluded=0" "a ledger with no permission page gives an empty list"
  sha=${out#sha256=}
  sha=${sha%% *}
  out=$(preallow "$h" approve --sha256 "$sha" --ref order-1 2>&1)
  expect_code 3 $? "an empty list is refused"
  [ ! -e "$h/config/afk-preallow.approval" ] || fail "an empty list must record nothing"
  out=$(preallow "$h" page --out "$h/page.html") || fail "page failed: $out"
  assert_grep "No decision is required" "$h/page.html" "the page of an empty list asks for nothing"
  pass "an empty candidate cannot be approved and its page asks for no decision"
}

test_page_shows_each_entry_with_count_source_and_checksum() {
  local h out sha
  h=$(make_home page)
  seed_ledger "$h"
  row "$h" 400 'worker:<b>' dialog page pending "permission: $(prompt 'ls -la')"
  out=$(preallow "$h" derive)
  sha=${out#sha256=}
  sha=${sha%% *}
  preallow "$h" page --out "$h/page.html" >/dev/null || fail "page failed"
  assert_grep "TL;DR" "$h/page.html" "the page opens with a summary"
  assert_grep "$sha" "$h/page.html" "the page shows the list checksum"
  assert_grep "<code>Bash(ls -la)</code></td><td class=\"num\">3</td>" "$h/page.html" "an entry is shown with its count"
  assert_grep "main/worker:a, main/worker:b, main/worker:&lt;b&gt;" "$h/page.html" "an entry is shown with its sources, escaped"
  pass "the page shows each entry with its count and source, and the checksum approval binds to"
}

spawn_with_settings() {  # <home> <proj> <wt> <fakebin> <n> -> prints the worker settings path after a real spawn
  local home=$1 proj=$2 wt=$3 fakebin=$4 id="pre-$5" out
  rm -f "$wt/.claude/settings.local.json" "$home/state"/pre-*.meta
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout 2>&1) \
    || fail "spawn failed: $out"
  printf '%s\n' "$wt/.claude/settings.local.json"
}

enter_away() {  # <home>
  printf 'keep going\n' > "$1/words"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CONTRACT" enter --words-file "$1/words" >/dev/null 2>&1 || fail "away entry failed"
}

test_spawn_writes_approved_entries_only_while_away() {
  local case_dir="$TMP_ROOT/spawn" home proj wt fakebin out sha settings
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-pre
  mkdir -p "$home/state/watchdog" "$home/config"
  seed_ledger "$home"
  out=$(preallow "$home" derive)
  sha=${out#sha256=}
  sha=${sha%% *}

  # 1. Away only (candidate derived, no approval): changes nothing.
  enter_away "$home"
  settings=$(spawn_with_settings "$home" "$proj" "$wt" "$fakebin" 1) || exit 1
  [ "$(jq -r 'has("permissions")' "$settings")" = false ] || fail "a candidate without an approval must change nothing"

  # 2. Approved and away: reaches the worker's settings alongside its hooks.
  preallow "$home" approve --sha256 "$sha" --ref order-1 >/dev/null || fail "approve failed"
  settings=$(spawn_with_settings "$home" "$proj" "$wt" "$fakebin" 2) || exit 1
  assert_equals '["Bash(git status --short)","Bash(ls -la)"]' "$(jq -c '.permissions.allow' "$settings")" \
    "an approved list reaches a Claude worker launched while away"
  [ "$(jq -r '.hooks | has("UserPromptSubmit")' "$settings")" = true ] || fail "the worker's hooks must stay in its settings"

  # 3. Changed after approval while away: changes nothing.
  printf 'Bash(touch extra)\n' >> "$home/config/afk-preallow.list"
  settings=$(spawn_with_settings "$home" "$proj" "$wt" "$fakebin" 3) || exit 1
  [ "$(jq -r 'has("permissions")' "$settings")" = false ] || fail "a list changed after approval must change nothing"

  # 4. Approved while owner is present (not away): changes nothing.
  preallow "$home" approve --sha256 "$sha" --ref order-1 >/dev/null || fail "re-approve failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CONTRACT" archive >/dev/null 2>&1 || fail "away archive failed"
  settings=$(spawn_with_settings "$home" "$proj" "$wt" "$fakebin" 4) || exit 1
  [ "$(jq -r 'has("permissions")' "$settings")" = false ] || fail "an approved list must not reach a worker launched while the owner is present"
  pass "fm-spawn pre-allows only an approved, unchanged list, and only for a worker launched while away"
}

test_derive_keeps_exact_commands_and_reports_the_rest
test_nothing_is_approved_without_a_matching_record
test_an_empty_candidate_cannot_be_approved
test_page_shows_each_entry_with_count_source_and_checksum
test_spawn_writes_approved_entries_only_while_away

echo "all fm-afk-preallow tests passed"
