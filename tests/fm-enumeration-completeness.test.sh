#!/usr/bin/env bash
# Enumeration completeness audit (council Item 4) and regression cases.
#
# Audit - every consumer checked that can conclude absent/missing/dead
# from a bounded list, with disposition (pages / refuses / fixed / safe):
# - bin/backends/orca.sh fm_backend_orca_close_worktree_terminals:
#   orca terminal list --limit 100000, truncated=true fails the Node proof
#   (exit 2/3). Refuses.
# - bin/fm-orca-cli-cache.sh fm_orca_terminal_exists (used by
#   fm_backend_target_exists for orca): --limit 5000,
#   truncated !== false exits 2 (unknown, never absent). Refuses.
# - bin/fm-worktree-cleanup.sh orca_path_list: --limit 100000,
#   requires truncated == false. Refuses. lane_terminal_closed reports
#   unreadable/incomplete terminal inventories for both record-cleanup
#   paths, including lanes with no remaining worktree. Fixed.
#   Its pr_rows (gh pr list
#   --head <branch> --limit 20) now refuses at the bound. Fixed.
# - bin/fm-captain-nudge.sh orca_pick_terminal: --limit 5000 with no
#   truncation check concluded captain pane missing. Fixed: truncated
#   or totalCount above listed returns 2 and the caller emits the
#   visible skip_enumeration_incomplete event, never pane-missing.
# - bin/fm-terminal-reap.sh: orca terminal list had no --limit and only
#   warned on truncated while judging listed terminals. Fixed: both
#   lists retain the default limit and truncated is a hard error (exit 1,
#   nothing closed); current_title also refuses a truncated re-list.
# - bin/fm-nm-run-lib.sh (fm-crew-state.sh, fm-teardown.sh runs
#   --limit): structurally truncated overview reports unknown /
#   incomplete with run ids, never no-run. Refuses.
# - bin/fm-ready-pr-discovery.sh: truncated overview is completed from
#   the state database; uncompletable repos land in unreadable[]. Pages.
# - bin/fm-fleet-snapshot.sh bounded reads carry complete/truncated
#   flags and bin/fm-bearings-snapshot.sh gates proven_clear on them
#   and surfaces capped secondmates/PR rows (limit+1 probe). Refuses.
# - bin/fm-pr-check-watch.sh: check-runs total_count above returned
#   length reports incomplete (exit 2), never missing. Refuses.
# - bin/fm-unpushed-reconcile.sh merged_evidence: refuses closed-PR
#   pages at the 100-row bound before filtering merged heads and
#   requires response-text truncated: false. Unknown is visible in
#   the branch finding. Fixed.
# - bin/fm-self-heal-issue.sh fm_self_heal_ensure_label: both labels
#   use the same probe, which refuses visibly at the 500-label bound
#   when the requested name is not listed, or when listing fails.
#   Fixed.
# - bin/fm-pr-lib.sh gh-axi pr list --head --limit 1 and
#   bin/fm-captain-nudge-lib.sh gh pr list --limit 20 open-work probe
#   and bin/fm-self-heal-issue.sh issue probe and
#   bin/fm-unpushed-reconcile.sh pr_evidence: the filter runs
#   server-side before the limit, so zero rows proves the filtered
#   total is zero and any row proves existence. Safe for absence.
# - Herdr/cmux/paseo/zellij/tern workspace and pane lists carry no
#   truncation or total field in their protocols; a failed list
#   returns unreadable, and absence is read only from a successfully
#   parsed complete list. Checked, no truncation signal exists.
#
# Regression: total (211) above the server bound (200), sought item
# past the bound. Pre-fix, fm-captain-nudge reported the live captain
# pane missing and fm-terminal-reap judged a truncated inventory.
# Post-fix both refuse visibly, and a complete list finds the item
# past the old bound.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-enumeration-completeness)
trap 'fm_test_cleanup' EXIT
NUDGE="$ROOT/bin/fm-captain-nudge.sh"
REAP="$ROOT/bin/fm-terminal-reap.sh"

# make_list <out> <truncated:true|false> <count> [include-captain]
make_list() {
  python3 - "$1" "$2" "$3" "${4:-}" <<'PY'
import json, sys
out, truncated, count, captain = sys.argv[1], sys.argv[2] == "true", int(sys.argv[3]), sys.argv[4]
terms = [{"handle": f"term-{i:03d}", "title": f"T{i}", "lastOutputAt": 2000000000000} for i in range(count)]
if captain:
    terms.append({"handle": "term-captain", "title": "captain", "lastOutputAt": 2000000000000})
    count += 1
json.dump({"ok": True, "result": {"terminals": terms, "truncated": truncated, "totalCount": 211}}, open(out, "w"))
PY
}

write_nudge_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state/captains" "$home/config" "$home/fakebin"
  cat > "$home/config/captain-nudge.json" <<EOF
{"schema":"fm-captain-nudge.v1","host":"testhost","interval_secs":300,
 "guard_stale_secs":660,"idle_min":20,"cooldown_min":30,"max_no_progress":2,
 "mode":"act","state_dir":"$home/state","jsonl_log":"$home/state/nudge.jsonl",
 "beacon_log":"$home/state/beacon.log",
 "captains":[{"id":"alpha","owner":"firstmate","backend":"orca","handle":"term-captain"}]}
EOF
  cat > "$home/fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list") cat "$FM_ENUM_LIST" ;;
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":"❯ ","draft":""}}}\n' ;;
  *) printf '{"ok":false}\n'; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/orca"
  printf '%s\n' "$home"
}

run_nudge() {  # <home>
  FM_TEST_SEAM=1 FM_NUDGE_NOW=2000000000 FM_NUDGE_SEND_LOG="$1/send.log" \
    PATH="$1/fakebin:$PATH" FM_ENUM_LIST="$2" \
    "$NUDGE" once --config "$1/config/captain-nudge.json" >/dev/null 2>&1 || true
  tail -n 1 "$1/state/nudge.jsonl" | jq -r '.event'
}

test_nudge_truncated_refuses_not_missing() {
  local home event
  home=$(write_nudge_home truncated)
  make_list "$TMP_ROOT/truncated.json" true 200
  event=$(run_nudge "$home" "$TMP_ROOT/truncated.json")
  assert_equals skip_enumeration_incomplete "$event" \
    "truncated list (total 211, captain past bound 200) must refuse visibly, not report pane missing"
  pass "fm-enumeration: captain-nudge refuses on truncated terminal list"
}

test_nudge_complete_finds_past_old_bound() {
  local home event
  home=$(write_nudge_home complete)
  make_list "$TMP_ROOT/complete.json" false 210 captain
  event=$(run_nudge "$home" "$TMP_ROOT/complete.json")
  [ "$event" != skip_pane_missing ] && [ "$event" != skip_enumeration_incomplete ] \
    || fail "complete list with captain at position 211 must find it, got $event"
  assert_equals skip_not_idle "$event" "found captain is read and judged not idle"
  pass "fm-enumeration: captain-nudge finds terminal past the old bound on a complete list"
}

test_reap_truncated_refuses() {
  local home="$TMP_ROOT/reap" rc=0 out
  mkdir -p "$home/state" "$home/data" "$home/fakebin"
  make_list "$home/list.json" true 200
  printf '{"ok":true,"result":{"worktrees":[]}}' > "$home/memory.json"
  cat > "$home/fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list") cat "$FM_ENUM_HOME/list.json" ;;
  "diagnostics memory") cat "$FM_ENUM_HOME/memory.json" ;;
  *) printf '{"ok":false}\n'; exit 1 ;;
esac
SH
  cat > "$home/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/fakebin/orca" "$home/fakebin/lsof"
  out=$(FM_ENUM_HOME="$home" PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    bash "$REAP" --min-age 0 --no-browsers 2>"$home/stderr") || rc=$?
  expect_code 1 "$rc" "truncated terminal inventory must refuse (exit 1)"
  assert_contains "$(cat "$home/stderr")" "enumeration incomplete" \
    "refusal must be visible in stderr"
  assert_equals "" "$out" "no terminal may be judged from a truncated list"
  pass "fm-enumeration: terminal-reap refuses on truncated terminal list"
}

test_nudge_truncated_refuses_not_missing
test_nudge_complete_finds_past_old_bound
test_reap_truncated_refuses
