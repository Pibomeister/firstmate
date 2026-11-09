#!/usr/bin/env bash
# Tests for bin/fm-captain-nudge.sh, the no-AI captain self-nudge.
#
# Decision cases drive the public `decide` command with observation JSON.
# Host-loop cases drive `once`, `test-nudge`, `guard`, and `install` through
# a fixture backend and FM_TEST_SEAM so nothing types into a real pane,
# calls gh, or loads launchd/systemd.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUDGE="$ROOT/bin/fm-captain-nudge.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-nudge)

decide() {
  printf '%s\n' "$1" | "$NUDGE" decide
}

base_obs() {
  jq -nc \
    --argjson idle "${1:-25}" \
    --argjson th "${2:-20}" \
    --argjson open "${3:-true}" \
    --arg sum "${4:-2 open PRs}" \
    --arg dialog "${5:-}" \
    --arg composer "${6:-empty}" \
    --argjson cool "${7:-0}" \
    --argjson consec "${8:-0}" \
    --argjson progress "${9:-false}" \
    --argjson esc "${10:-false}" \
    '{
      idle_min:$idle, idle_threshold_min:$th, open_work:$open,
      open_work_summary:$sum, dialog:$dialog, composer:$composer,
      cooldown_remaining_min:$cool, consecutive_no_progress:$consec,
      progress_since_nudge:$progress, escalated:$esc, max_no_progress:2
    }'
}

event_of() { printf '%s' "$1" | jq -r '.event'; }
send_of() { printf '%s' "$1" | jq -r '.should_send | tostring'; }
sev_of() { printf '%s' "$1" | jq -r '.severity'; }

test_help_and_usage() {
  local out rc=0
  out=$("$NUDGE" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "once" "--help lists once"
  assert_contains "$out" "test-nudge" "--help lists test-nudge"
  assert_contains "$out" "install" "--help lists install"
  rc=0
  out=$("$NUDGE" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  pass "fm-captain-nudge: help and usage plumbing"
}

test_decide_nudge_happy_path() {
  local out
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" empty 0 0 false false)")
  assert_equals nudge "$(event_of "$out")" "idle + open work + empty composer nudges"
  assert_equals true "$(send_of "$out")" "happy path may send"
  pass "fm-captain-nudge: decide nudges when idle with open work and empty composer"
}

test_decide_skip_not_idle() {
  local out
  out=$(decide "$(base_obs 5 20 true "2 open PRs" "" empty 0 0 false false)")
  assert_equals skip_not_idle "$(event_of "$out")" "below idle threshold skips"
  assert_equals false "$(send_of "$out")" "not-idle must not send"
  pass "fm-captain-nudge: decide skips when idle is below threshold"
}

test_decide_skip_no_open_work() {
  local out
  out=$(decide "$(base_obs 25 20 false none "" empty 0 0 false false)")
  assert_equals skip_no_open_work "$(event_of "$out")" "no open work skips"
  assert_equals false "$(send_of "$out")" "no open work must not send"
  pass "fm-captain-nudge: decide skips when there is no open work"
}

test_decide_blocker_modal() {
  local out kind
  for kind in usage-limit permission menu question; do
    out=$(decide "$(base_obs 25 20 true "2 open PRs" "$kind" empty 0 0 false false)")
    assert_equals blocker "$(event_of "$out")" "modal $kind is a blocker"
    assert_equals medium "$(sev_of "$out")" "modal $kind is medium"
    assert_equals false "$(send_of "$out")" "modal $kind must not send"
  done
  pass "fm-captain-nudge: decide never types when a modal is visible"
}

test_decide_skipped_input_not_empty() {
  local out
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" pending 0 0 false false)")
  assert_equals skipped_input_not_empty "$(event_of "$out")" "pending composer skips"
  assert_equals false "$(send_of "$out")" "pending composer must not send"
  pass "fm-captain-nudge: decide skips when the input line is not empty"
}

test_decide_blocker_unknown_composer() {
  local out
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" unknown 0 0 false false)")
  assert_equals blocker "$(event_of "$out")" "unknown composer is a blocker"
  assert_equals false "$(send_of "$out")" "unknown composer must not send"
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" pending-unproven 0 0 false false)")
  assert_equals blocker "$(event_of "$out")" "unproven composer is a blocker"
  pass "fm-captain-nudge: decide refuses unknown or unproven composer"
}

test_decide_skip_cooldown() {
  local out
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" empty 12 0 false false)")
  assert_equals skip_cooldown "$(event_of "$out")" "cooldown remaining skips"
  assert_equals false "$(send_of "$out")" "cooldown must not send"
  pass "fm-captain-nudge: decide skips during cooldown"
}

test_decide_escalation_no_progress() {
  local out
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" empty 0 2 false false)")
  assert_equals nudge_no_progress "$(event_of "$out")" "two no-progress nudges escalate"
  assert_equals high "$(sev_of "$out")" "nudge_no_progress is high"
  assert_equals false "$(send_of "$out")" "escalation must not send"
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" empty 0 2 false true)")
  assert_equals nudge_no_progress "$(event_of "$out")" "already escalated stays stopped"
  out=$(decide "$(base_obs 25 20 true "2 open PRs" "" empty 0 2 true true)")
  assert_equals nudge "$(event_of "$out")" "progress clears escalation and nudges"
  assert_equals true "$(send_of "$out")" "progress may send again"
  pass "fm-captain-nudge: decide escalates after two no-progress nudges and resumes on progress"
}

test_decide_modal_beats_idle() {
  local out
  out=$(decide "$(base_obs 25 20 true "2 open PRs" permission pending 0 0 false false)")
  assert_equals blocker "$(event_of "$out")" "modal wins over pending composer"
  pass "fm-captain-nudge: decide reports blocker before skipped_input_not_empty"
}

# --- host loop with fixture backend ----------------------------------------

FIXED='Continue open work: pick next item, reroute quota if exhausted, never park self-servable work'

write_home() {  # <name> <captain-json-array>
  local name=$1 captains=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state/captains" "$home/config" "$home/queue"
  cat > "$home/config/captain-nudge.json" <<EOF
{
  "schema": "fm-captain-nudge.v1",
  "host": "testhost",
  "interval_secs": 300,
  "guard_stale_secs": 660,
  "idle_min": 20,
  "cooldown_min": 30,
  "max_no_progress": 2,
  "mode": "act",
  "state_dir": "$home/state",
  "jsonl_log": "$home/state/nudge.jsonl",
  "beacon_log": "$home/state/beacon.log",
  "captains": $captains
}
EOF
  printf '%s\n' "$home"
}

fixture_captain() {  # <idle> <open-bool> <dialog> <composer> <screen> <last-epoch> [queue-path]
  local idle=$1 open=$2 dialog=$3 composer=$4 screen=$5 last=$6 queue=${7:-}
  local queue_json
  if [ "$open" = true ]; then
    mkdir -p "$TMP_ROOT/queue"
    printf -- '- [ ] do the thing\n' > "$TMP_ROOT/queue/backlog.md"
    queue_json=$(printf '{"repos":[],"queue_file":"%s"}' "${queue:-$TMP_ROOT/queue/backlog.md}")
  else
    printf '' > "$TMP_ROOT/queue-empty.md"
    queue_json=$(printf '{"repos":[],"queue_file":"%s"}' "$TMP_ROOT/queue-empty.md")
  fi
  jq -nc \
    --argjson idle "$idle" \
    --arg dialog "$dialog" \
    --arg composer "$composer" \
    --arg screen "$screen" \
    --argjson last "$last" \
    --argjson ow "$queue_json" \
    '{
      id:"alpha", owner:"firstmate", backend:"fixture",
      idle_min:20, cooldown_min:30,
      open_work:$ow,
      fixture:{
        idle_min:$idle, last_activity_epoch:$last, screen:$screen,
        dialog:$dialog, composer:$composer, draft:"",
        heartbeat_epoch:$last, commit:"abc"
      }
    }'
}

run_once() {  # <home>
  local home=$1
  FM_TEST_SEAM=1 FM_NUDGE_NOW="${FM_NUDGE_NOW:-2000000000}" \
    FM_NUDGE_SEND_LOG="$home/send.log" \
    "$NUDGE" once --config "$home/config/captain-nudge.json"
}

last_event() {
  tail -n 1 "$1/state/nudge.jsonl" | jq -r '.event'
}

test_once_fixture_nudge_writes_jsonl_and_beacon() {
  local home now=2000000000 cap
  now=2000000000
  cap=$(fixture_captain 25 true "" empty "❯ " $((now - 25 * 60)))
  home=$(write_home once-nudge "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "once nudges the fixture captain"
  assert_grep "NUDGE v1" "$home/state/beacon.log" "beacon log gets a NUDGE v1 line"
  assert_grep "event=nudge" "$home/state/beacon.log" "beacon names the event"
  assert_grep "open_work=1" "$home/state/beacon.log" "beacon flags open work"
  assert_grep "$FIXED" "$home/send.log" "send log holds the fixed prompt"
  grep -Fq $'\t'"$FIXED" "$home/send.log" || fail "send log must record backend, target, and the exact prompt"
  pass "fm-captain-nudge: once nudges, logs JSONL, emits NUDGE v1, and sends only the fixed prompt"
}

test_once_dry_run_does_not_send() {
  local home cap now=2000000000
  cap=$(fixture_captain 25 true "" empty "❯ " $((now - 25 * 60)))
  home=$(write_home dry "[$cap]")
  FM_TEST_SEAM=1 FM_NUDGE_NOW=$now FM_NUDGE_SEND_LOG="$home/send.log" \
    "$NUDGE" once --config "$home/config/captain-nudge.json" --dry-run
  assert_equals nudge "$(last_event "$home")" "dry-run still records a nudge decision"
  [ ! -s "$home/send.log" ] || fail "dry-run must not send: $(cat "$home/send.log")"
  tail -n 1 "$home/state/nudge.jsonl" | jq -e '.dry_run == true' >/dev/null \
    || fail "dry-run JSONL must set dry_run true"
  pass "fm-captain-nudge: dry-run logs a nudge and never sends"
}

test_once_modal_never_sends() {
  local home cap now=2000000000
  cap=$(fixture_captain 25 true "usage-limit" empty "Yes or No" $((now - 25 * 60)))
  home=$(write_home modal "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals blocker "$(last_event "$home")" "modal is a blocker"
  [ ! -e "$home/send.log" ] || [ ! -s "$home/send.log" ] || fail "modal must not send"
  pass "fm-captain-nudge: once never sends when a modal is visible"
}

test_once_pending_input_never_sends() {
  local home cap now=2000000000
  cap=$(fixture_captain 25 true "" pending "❯ hello from eduardo" $((now - 25 * 60)))
  home=$(write_home pending "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals skipped_input_not_empty "$(last_event "$home")" "pending input is skipped"
  [ ! -e "$home/send.log" ] || [ ! -s "$home/send.log" ] || fail "pending input must not send"
  pass "fm-captain-nudge: once never overwrites typed text"
}

test_once_cooldown_and_escalation() {
  local home cap now=2000000000 st
  cap=$(fixture_captain 40 true "" empty "❯ " $((now - 40 * 60)))
  home=$(write_home esc "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "first eligible pass nudges"
  # Same fingerprint, still in cooldown.
  FM_NUDGE_NOW=$((now + 10 * 60)) run_once "$home"
  assert_equals skip_cooldown "$(last_event "$home")" "second pass inside 30m cooldown skips"
  # Cooldown elapsed, fingerprint unchanged -> consecutive becomes 1, second nudge.
  FM_NUDGE_NOW=$((now + 31 * 60)) run_once "$home"
  assert_equals nudge "$(last_event "$home")" "after cooldown a second no-progress nudge still sends"
  # Cooldown elapsed again, still no progress -> escalate, do not send a third.
  : > "$home/send.log"
  FM_NUDGE_NOW=$((now + 62 * 60)) run_once "$home"
  assert_equals nudge_no_progress "$(last_event "$home")" "third eligible pass escalates"
  tail -n 1 "$home/state/nudge.jsonl" | jq -e '.severity == "high"' >/dev/null \
    || fail "nudge_no_progress must be high"
  [ ! -s "$home/send.log" ] || fail "escalation must not send: $(cat "$home/send.log")"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.escalated == true' >/dev/null || fail "state must record escalated"
  # Progress (new commit) resumes nudging after cooldown of last real nudge.
  cap=$(printf '%s' "$cap" | jq -c '.fixture.commit="def" | .fixture.heartbeat_epoch += 10')
  home2=$(write_home esc2 "[$cap]")
  # Seed escalated state, last nudge 40m ago, new fingerprint.
  jq -nc --argjson now "$now" '{last_nudge_epoch:$now, fingerprint:"old", consecutive_no_progress:2, escalated:true}' \
    > "$home2/state/captains/alpha.json"
  FM_NUDGE_NOW=$((now + 40 * 60)) FM_TEST_SEAM=1 FM_NUDGE_SEND_LOG="$home2/send.log" \
    "$NUDGE" once --config "$home2/config/captain-nudge.json"
  assert_equals nudge "$(last_event "$home2")" "progress clears escalation"
  assert_grep "$FIXED" "$home2/send.log" "progress may send again"
  pass "fm-captain-nudge: cooldown, two no-progress nudges, then high stop until progress"
}

test_test_nudge_still_refuses_modal() {
  local home cap now=2000000000
  cap=$(fixture_captain 1 true "permission" empty "Allow this?" "$now")
  home=$(write_home force-modal "[$cap]")
  FM_TEST_SEAM=1 FM_NUDGE_NOW=$now FM_NUDGE_SEND_LOG="$home/send.log" \
    "$NUDGE" test-nudge --captain alpha --config "$home/config/captain-nudge.json"
  assert_equals blocker "$(last_event "$home")" "test-nudge still blocks on a modal"
  [ ! -e "$home/send.log" ] || [ ! -s "$home/send.log" ] || fail "test-nudge must not send into a modal"
  pass "fm-captain-nudge: test-nudge still refuses a visible modal"
}

test_test_nudge_sends_when_empty() {
  local home cap now=2000000000
  cap=$(fixture_captain 1 false "" empty "❯ " "$now")
  home=$(write_home force-ok "[$cap]")
  FM_TEST_SEAM=1 FM_NUDGE_NOW=$now FM_NUDGE_SEND_LOG="$home/send.log" \
    "$NUDGE" test-nudge --captain alpha --config "$home/config/captain-nudge.json"
  assert_equals nudge "$(last_event "$home")" "test-nudge skips idle and open-work"
  assert_grep "$FIXED" "$home/send.log" "test-nudge sends the fixed prompt"
  pass "fm-captain-nudge: test-nudge proves the send path on an empty composer"
}

test_guard_restarts_stale_loop() {
  local home cap now=2000000000
  cap=$(fixture_captain 25 true "" empty "❯ " $((now - 25 * 60)))
  home=$(write_home guard "[$cap]")
  mkdir -p "$home/state"
  printf '%s\n' "$((now - 700))" > "$home/state/loop.heartbeat"
  printf '%s\n' "$$" > "$home/state/loop.pid"
  FM_TEST_SEAM=1 FM_NUDGE_NOW=$now FM_NUDGE_SEND_LOG="$home/send.log" \
    "$NUDGE" guard --config "$home/config/captain-nudge.json"
  assert_grep "restart" "$home/send.log" "stale heartbeat restarts the loop"
  pass "fm-captain-nudge: guard restarts when its own heartbeat is stale"
}

test_guard_leaves_fresh_loop() {
  local home cap now=2000000000
  cap=$(fixture_captain 25 true "" empty "❯ " $((now - 25 * 60)))
  home=$(write_home guard-fresh "[$cap]")
  mkdir -p "$home/state"
  printf '%s\n' "$now" > "$home/state/loop.heartbeat"
  FM_TEST_SEAM=1 FM_NUDGE_NOW=$now FM_NUDGE_SEND_LOG="$home/send.log" \
    "$NUDGE" guard --config "$home/config/captain-nudge.json"
  [ ! -e "$home/send.log" ] || [ ! -s "$home/send.log" ] || fail "fresh heartbeat must not restart"
  pass "fm-captain-nudge: guard is a no-op while the loop heartbeat is fresh"
}

test_install_idempotent_units() {
  local home cap launchd systemd
  cap=$(fixture_captain 25 true "" empty "❯ " 1)
  home=$(write_home inst "[$cap]")
  launchd="$home/LaunchAgents"
  systemd="$home/systemd"
  mkdir -p "$launchd" "$systemd"
  if [ "$(uname -s)" = Darwin ]; then
    FM_TEST_SEAM=1 FM_NUDGE_LAUNCHD_DIR="$launchd" \
      "$NUDGE" install --config "$home/config/captain-nudge.json"
    assert_grep "fm-captain-nudge.sh" "$launchd/com.firstmate.captain-nudge.plist" "run plist points at the script"
    assert_grep "guard" "$launchd/com.firstmate.captain-nudge-guard.plist" "guard plist exists"
    FM_TEST_SEAM=1 FM_NUDGE_LAUNCHD_DIR="$launchd" \
      "$NUDGE" install --config "$home/config/captain-nudge.json"
    FM_TEST_SEAM=1 FM_NUDGE_LAUNCHD_DIR="$launchd" \
      "$NUDGE" uninstall --config "$home/config/captain-nudge.json"
    [ ! -f "$launchd/com.firstmate.captain-nudge.plist" ] || fail "uninstall must remove the run plist"
  else
    FM_TEST_SEAM=1 FM_NUDGE_SYSTEMD_DIR="$systemd" \
      "$NUDGE" install --config "$home/config/captain-nudge.json"
    if [ -f "$systemd/firstmate-captain-nudge.service" ]; then
      assert_grep "fm-captain-nudge.sh" "$systemd/firstmate-captain-nudge.service" "run unit points at the script"
      assert_grep "OnUnitActiveSec" "$systemd/firstmate-captain-nudge-guard.timer" "guard timer exists"
      FM_TEST_SEAM=1 FM_NUDGE_SYSTEMD_DIR="$systemd" \
        "$NUDGE" uninstall --config "$home/config/captain-nudge.json"
      [ ! -f "$systemd/firstmate-captain-nudge.service" ] || fail "uninstall must remove the run unit"
    else
      FM_TEST_SEAM=1 FM_NUDGE_CRON_FILE="$home/cron" \
        "$NUDGE" install --config "$home/config/captain-nudge.json"
      assert_grep "firstmate-captain-nudge" "$home/cron" "cron once line"
      assert_grep "firstmate-captain-nudge-guard" "$home/cron" "cron guard line"
      FM_TEST_SEAM=1 FM_NUDGE_CRON_FILE="$home/cron" \
        "$NUDGE" install --config "$home/config/captain-nudge.json"
      [ "$(grep -c firstmate-captain-nudge "$home/cron")" -eq 2 ] \
        || fail "reinstall must not duplicate cron lines: $(cat "$home/cron")"
      FM_TEST_SEAM=1 FM_NUDGE_CRON_FILE="$home/cron" \
        "$NUDGE" uninstall --config "$home/config/captain-nudge.json"
      grep -q firstmate-captain-nudge "$home/cron" && fail "uninstall must drop cron lines" || true
    fi
  fi
  pass "fm-captain-nudge: install and uninstall are idempotent"
}

test_open_work_queue_file() {
  local out
  # shellcheck source=bin/fm-captain-nudge-lib.sh
  . "$ROOT/bin/fm-captain-nudge-lib.sh"
  printf -- '- [ ] item\n' > "$TMP_ROOT/q-open.md"
  out=$(fm_nudge_probe_queue_file "$TMP_ROOT/q-open.md")
  assert_equals true "${out%%$'\t'*}" "checkbox queue is open work"
  : > "$TMP_ROOT/q-empty.md"
  out=$(fm_nudge_probe_queue_file "$TMP_ROOT/q-empty.md")
  assert_equals false "${out%%$'\t'*}" "empty queue is not open work"
  pass "fm-captain-nudge: queue-file probe treats checkboxes as open work"
}

test_beacon_line_has_no_spaces_in_values() {
  local line
  # shellcheck source=bin/fm-captain-nudge-lib.sh
  . "$ROOT/bin/fm-captain-nudge-lib.sh"
  line=$(fm_nudge_beacon_line '{"epoch":1,"host":"m4","captain":"m4main","event":"nudge","severity":"info","owner":"firstmate","idle_min":25,"open_work":"2 open PRs"}')
  assert_contains "$line" "NUDGE v1 ts=1" "beacon starts with NUDGE v1"
  [ "$(printf '%s' "$line" | awk '{print NF}')" -eq 10 ] \
    || fail "beacon must be prefix plus eight key=value tokens: $line"
  pass "fm-captain-nudge: beacon line is wrap-join parseable"
}

test_example_configs_parse() {
  local f
  for f in "$ROOT"/docs/examples/captain-nudge/*.json; do
    jq -e '.schema=="fm-captain-nudge.v1" and (.captains|length>=1) and .host' "$f" >/dev/null \
      || fail "example $f is not a valid host config"
  done
  pass "fm-captain-nudge: example host configs parse"
}

test_expand_path_literal_tilde() {
  local out
  out=$(HOME=/tmp/fm-nudge-home bash -c '. "$1/bin/fm-captain-nudge-lib.sh"; fm_nudge_expand_path "~/orca/nudge"; fm_nudge_expand_path "~"; fm_nudge_expand_path /abs/p' _ "$ROOT")
  [ "$out" = "$(printf '/tmp/fm-nudge-home/orca/nudge\n/tmp/fm-nudge-home\n/abs/p')" ] \
    || fail "expand_path did not expand a literal ~ config value: $out"
  pass "fm-captain-nudge: literal ~ in config paths expands to HOME"
}

fm_test_run \
  test_help_and_usage \
  test_decide_nudge_happy_path \
  test_decide_skip_not_idle \
  test_decide_skip_no_open_work \
  test_decide_blocker_modal \
  test_decide_skipped_input_not_empty \
  test_decide_blocker_unknown_composer \
  test_decide_skip_cooldown \
  test_decide_escalation_no_progress \
  test_decide_modal_beats_idle \
  test_once_fixture_nudge_writes_jsonl_and_beacon \
  test_once_dry_run_does_not_send \
  test_once_modal_never_sends \
  test_once_pending_input_never_sends \
  test_once_cooldown_and_escalation \
  test_test_nudge_still_refuses_modal \
  test_test_nudge_sends_when_empty \
  test_guard_restarts_stale_loop \
  test_guard_leaves_fresh_loop \
  test_install_idempotent_units \
  test_open_work_queue_file \
  test_beacon_line_has_no_spaces_in_values \
  test_example_configs_parse \
  test_expand_path_literal_tilde
