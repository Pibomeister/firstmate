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
  cap=$(fixture_captain 40 true "" empty "❯ " $((now - 40 * 60)) | jq -c '. + {escalate_min:0, council_min:0}')
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

test_herdr_idle_tracks_screen_change_not_heartbeat() {
  local home bin cap idle
  bin="$TMP_ROOT/herdr-bin"
  mkdir -p "$bin"
  # shellcheck disable=SC2016 # The fake herdr script, not this shell, expands it.
  printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_HERDR_SCREEN:-idle screen}"\n' > "$bin/herdr"
  chmod +x "$bin/herdr"
  mkdir -p "$TMP_ROOT/herdr-home/state"
  printf '{"generated_epoch":2000003000}\n' > "$TMP_ROOT/herdr-home/state/heartbeat.json"
  cap=$(jq -nc --arg fm "$TMP_ROOT/herdr-home" '[{id:"hd", owner:"abaco", backend:"herdr", pane:"w1:pG", fm_home:$fm, open_work:{repos:[], queue_file:""}}]')
  home=$(write_home herdr-idle "$cap")
  PATH="$bin:$PATH" FM_NUDGE_NOW=2000000000 run_once "$home" >/dev/null 2>&1
  PATH="$bin:$PATH" FM_NUDGE_NOW=$((2000000000 + 25 * 60)) run_once "$home" >/dev/null 2>&1
  idle=$(tail -n 1 "$home/state/nudge.jsonl" | jq -r '.idle_min')
  [ "$idle" = 25 ] || fail "herdr idle should follow unchanged screen (25m), got $idle"
  PATH="$bin:$PATH" FAKE_HERDR_SCREEN="new output" FM_NUDGE_NOW=$((2000000000 + 26 * 60)) run_once "$home" >/dev/null 2>&1
  idle=$(tail -n 1 "$home/state/nudge.jsonl" | jq -r '.idle_min')
  [ "$idle" = 0 ] || fail "herdr idle should reset when the screen changes, got $idle"
  pass "fm-captain-nudge: herdr idle tracks screen change, not a cron heartbeat"
}

test_once_submits_own_unsent_prompt_only() {
  local home cap now=2000000000 prompt
  prompt="Continue open work: pick next item, reroute quota if exhausted, never park self-servable work"
  cap=$(fixture_captain 25 true "" pending "› $prompt" $((now - 25 * 60)))
  home=$(write_home own-unsent "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "own unsent prompt is submitted"
  [ "$(cut -f3 "$home/send.log")" = "<Enter>" ] || fail "only Enter may be sent for an own unsent prompt: $(cat "$home/send.log")"
  cap=$(fixture_captain 25 true "" pending "› $prompt and more from eduardo" $((now - 25 * 60)))
  home=$(write_home own-unsent-edited "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals skipped_input_not_empty "$(last_event "$home")" "edited composer is never submitted"
  [ ! -s "$home/send.log" ] || fail "edited composer must not receive Enter"
  pass "fm-captain-nudge: submits only its own unsent fixed prompt, Enter only"
}

test_decide_ladder_escalates_then_councils() {
  local out obs
  obs() {  # <idle> <tier> <cool> [dialog] [open]
    base_obs "$1" 20 "${5:-true}" "2 open PRs" "${4:-}" empty "$3" 0 false false \
      | jq -c --argjson tier "$2" '. + {escalate_min:40, council_min:60, stall_tier:$tier}'
  }
  out=$(decide "$(obs 45 0 0)")
  assert_equals nudge "$(event_of "$out")" "no first wake yet: the ladder starts with the ordinary nudge"
  assert_equals continue "$(printf '%s' "$out" | jq -r '.prompt')" "first wake uses the continue prompt"
  out=$(decide "$(obs 45 1 10)")
  assert_equals stall_escalate "$(event_of "$out")" "idle past 40m after a first wake escalates inside the cooldown"
  assert_equals true "$(send_of "$out")" "the second wake types"
  assert_equals escalate "$(printf '%s' "$out" | jq -r '.prompt')" "the second wake uses the relaunch-or-replace prompt"
  out=$(decide "$(obs 50 2 5)")
  assert_equals skip_cooldown "$(event_of "$out")" "the second wake fires once per stall"
  out=$(decide "$(obs 65 2 0 permission)")
  assert_equals stall_council "$(event_of "$out")" "idle past 60m raises the council row even behind a modal"
  assert_equals high "$(sev_of "$out")" "the council row is high"
  assert_equals false "$(send_of "$out")" "the council row never types"
  out=$(decide "$(obs 70 3 0)")
  assert_equals nudge "$(event_of "$out")" "the council row is raised once per stall"
  out=$(decide "$(obs 70 0 0 '' false)")
  assert_equals skip_no_open_work "$(event_of "$out")" "no open work raises no council row"
  out=$(decide "$(base_obs 70 20 true "2 open PRs" "" empty 0 0 false false)")
  assert_equals nudge "$(event_of "$out")" "an observation without ladder keys keeps the single-prompt behavior"
  pass "fm-captain-nudge: decide wakes, escalates once past 40m, and raises one council row past 60m"
}

ESCALATE='Still stalled with open work: relaunch or replace the stalled worker, then continue open work'
MERGE='A PR is merge-ready and unmerged: dispatch the merge or record why'

test_once_ladder_wakes_escalates_councils_and_records_ack() {
  local home cap now=2000000000 st
  cap=$(fixture_captain 20 true "" empty "❯ " $((now - 20 * 60)))
  home=$(write_home ladder "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "idle 20m with open work gets the first wake"
  FM_NUDGE_NOW=$((now + 20 * 60)) run_once "$home"
  assert_equals stall_escalate "$(last_event "$home")" "idle 40m with no ack gets the second wake"
  [ "$(cut -f3 "$home/send.log")" = "$(printf '%s\n%s' "$FIXED" "$ESCALATE")" ] \
    || fail "send log must hold the continue prompt, then the escalate prompt: $(cat "$home/send.log")"
  FM_NUDGE_NOW=$((now + 25 * 60)) run_once "$home"
  assert_equals skip_cooldown "$(last_event "$home")" "no third prompt before the council tier"
  FM_NUDGE_NOW=$((now + 40 * 60)) run_once "$home"
  assert_equals stall_council "$(last_event "$home")" "idle 60m raises the council row"
  assert_grep "event=stall_council severity=high" "$home/state/beacon.log" "the council row reaches the beacon"
  [ "$(wc -l < "$home/send.log" | tr -d ' ')" = 2 ] || fail "the council row must not type: $(cat "$home/send.log")"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 3' >/dev/null || fail "state must record the council tier: $st"
  cap=$(fixture_captain 1 true "" empty "❯ working" $((now + 40 * 60)) | jq -c '.fixture.commit="def"')
  home2="$TMP_ROOT/ladder"
  write_home ladder "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 41 * 60)) run_once "$home2"
  jq -e 'select(.event == "stall_acked")' "$home2/state/nudge.jsonl" >/dev/null \
    || fail "progress after a wake must record a stall_acked row"
  st=$(cat "$home2/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 0' >/dev/null || fail "progress must reset the ladder: $st"
  pass "fm-captain-nudge: once wakes at 20m, escalates at 40m, raises a council row at 60m, and records the ack"
}

test_once_ladder_does_not_ack_its_own_wake() {
  local home cap echoed now=2000000000 st
  echoed=$(printf '❯ %s\n✻ Working\n❯ ' "$FIXED")
  cap=$(fixture_captain 20 true "" empty "❯ " $((now - 20 * 60)) \
    | jq -c --arg s "$echoed" --argjson at "$now" \
      '.fixture.after_send = [{}, {screen:$s, last_activity_epoch:$at}]')
  home=$(write_home ladder-echo "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "idle 20m with open work gets the first wake"
  cap=$(printf '%s' "$cap" | jq -c --arg s "$echoed" --argjson at "$now" \
    '.fixture.screen = $s | .fixture.last_activity_epoch = $at')
  write_home ladder-echo "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 20 * 60)) run_once "$home"
  if jq -e 'select(.event == "stall_acked")' "$home/state/nudge.jsonl" >/dev/null; then
    fail "the pane's echo of the tool's own wake must not count as the captain's ack"
  fi
  assert_equals stall_escalate "$(last_event "$home")" "40m into the stall after an echoed wake gets the second wake"
  FM_NUDGE_NOW=$((now + 40 * 60)) run_once "$home"
  assert_equals stall_council "$(last_event "$home")" "60m into the stall after echoed wakes raises the council row"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 3' >/dev/null || fail "state must record the council tier: $st"
  pass "fm-captain-nudge: the ladder never reads the pane's echo of its own wake as the captain's ack"
}

test_once_settle_keeps_last_reading_when_a_reread_fails() {
  local home cap echoed now=2000000000
  echoed=$(printf '❯ %s\n✻ Working\n❯ ' "$FIXED")
  cap=$(fixture_captain 20 true "" empty "❯ " $((now - 20 * 60)) \
    | jq -c --arg s "$echoed" --argjson at "$now" \
      '.fixture.after_send = [{}, {screen:$s, last_activity_epoch:$at}, {read_failed:true}]')
  home=$(write_home ladder-reread-fail "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "idle 20m with open work gets the first wake"
  cap=$(printf '%s' "$cap" | jq -c --arg s "$echoed" --argjson at "$now" \
    '.fixture.screen = $s | .fixture.last_activity_epoch = $at | .fixture.after_send = []')
  write_home ladder-reread-fail "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 20 * 60)) run_once "$home"
  if jq -e 'select(.event == "stall_acked")' "$home/state/nudge.jsonl" >/dev/null; then
    fail "a failed reread after the echo was seen must not drop back to the pre-send reading"
  fi
  assert_equals stall_escalate "$(last_event "$home")" "the settled echo reading survives a failed reread"
  pass "fm-captain-nudge: a failed reread during the settle keeps the last good reading"
}

write_ready_bin() {  # <dir> -> fake fm-ready-pr-discovery reading $FAKE_READY_JSON
  mkdir -p "$1"
  cat > "$1/ready" <<'SH'
#!/bin/sh
[ "$1" = --json ] || exit 2
[ -n "${FM_HOME:-}" ] || exit 3
printf '%s\n' "$FM_HOME" >> "$FAKE_READY_LOG"
cat "$FAKE_READY_JSON"
SH
  chmod +x "$1/ready"
}

test_once_merge_ready_nudges_once_after_15_minutes() {
  local home cap now=2000000000 fm bin ready
  fm="$TMP_ROOT/mr-home"
  mkdir -p "$fm/state"
  bin="$TMP_ROOT/mr-bin"
  write_ready_bin "$bin"
  ready="$TMP_ROOT/mr-ready.json"
  jq -nc '{schema:"fm-ready-pr-discovery.v1", runs:[
    {repo:"firstmate", branch:"fm/a", pr:"https://github.com/o/r/pull/7", head:"abc", run_id:"R1", kind:"ci-ready", gate:"-"},
    {repo:"firstmate", branch:"fm/b", pr:"https://github.com/o/r/pull/8", head:"def", run_id:"R2", kind:"gate", gate:"review"}
  ], unreadable:[]}' > "$ready"
  cap=$(fixture_captain 1 true "" empty "❯ " "$now" | jq -c --arg fm "$fm" '.fm_home=$fm')
  home=$(write_home merge-ready "[$cap]")
  mr_once() {  # <now> [composer]
    if [ -n "${2:-}" ]; then
      jq --arg c "$2" '.captains[0].fixture.composer=$c' "$home/config/captain-nudge.json" > "$home/cfg.tmp" \
        && mv "$home/cfg.tmp" "$home/config/captain-nudge.json"
    fi
    FM_NUDGE_READY_PR_BIN="$bin/ready" FAKE_READY_JSON="$ready" FAKE_READY_LOG="$home/ready.log" \
      FM_NUDGE_NOW=$1 run_once "$home"
  }
  mr_once "$now"
  assert_equals "$fm" "$(head -n 1 "$home/ready.log")" "discovery runs against the captain's home"
  [ "$(jq -c 'select(.event == "merge_ready") | .pr' "$home/state/nudge.jsonl")" = '"https://github.com/o/r/pull/7"' ] \
    || fail "only the ci-ready PR gets a merge_ready row: $(cat "$home/state/nudge.jsonl")"
  [ ! -s "$home/send.log" ] || fail "a fresh merge-ready PR must not type yet: $(cat "$home/send.log")"
  mr_once $((now + 14 * 60))
  [ ! -s "$home/send.log" ] || fail "14 minutes is not overdue: $(cat "$home/send.log")"
  mr_once $((now + 15 * 60)) pending
  [ ! -s "$home/send.log" ] || fail "typed text must not receive the merge prompt: $(cat "$home/send.log")"
  mr_once $((now + 16 * 60)) empty
  assert_equals merge_ready_wait "$(last_event "$home")" "an overdue merge-ready PR wakes the captain"
  [ "$(cut -f3 "$home/send.log")" = "$MERGE" ] || fail "send log must hold only the merge prompt: $(cat "$home/send.log")"
  mr_once $((now + 25 * 60))
  [ "$(grep -cF "$MERGE" "$home/send.log")" = 1 ] || fail "one merge prompt per PR head: $(cat "$home/send.log")"
  jq -nc '{schema:"fm-ready-pr-discovery.v1", runs:[], unreadable:[]}' > "$ready"
  mr_once $((now + 30 * 60))
  jq -e 'select(.event == "merge_ready_cleared" and .pr == "https://github.com/o/r/pull/7")' "$home/state/nudge.jsonl" >/dev/null \
    || fail "a PR that leaves the ready list gets a merge_ready_cleared row"
  pass "fm-captain-nudge: a ci-ready PR waiting 15 minutes gets one merge prompt, never over typed text"
}

test_once_records_the_captain_home_stall_ledger() {
  local home cap now=2000000000 fm
  fm="$TMP_ROOT/ledger-home"
  mkdir -p "$fm/state" "$fm/data"
  printf '{"schema":"fm-heartbeat.v1","published_epoch":%s,"generated_epoch":%s}\n' $((now - 1800)) $((now - 1800)) \
    > "$fm/state/heartbeat.json"
  cap=$(fixture_captain 30 true "" empty "❯ " $((now - 30 * 60)) | jq -c --arg fm "$fm" '.fm_home=$fm')
  home=$(write_home ledger "[$cap]")
  FM_NUDGE_READY_PR_BIN=/nonexistent FM_NUDGE_NOW=$now run_once "$home"
  awk -F '\t' -v start=$((now - 1800)) '$2 == "stall-open" && $3 == "primary" && $5 == start { ok = 1 } END { exit !ok }' \
    "$fm/state/stall-ledger.tsv" 2>/dev/null \
    || fail "a pass must record the quiet captain's stall in its home ledger: $(cat "$fm/state/stall-ledger.tsv" 2>&1)"
  pass "fm-captain-nudge: each pass records the captain home's stall ledger even when its watcher is quiet"
}
test_once_stalled_lane_wakes_with_the_lane_table() {
  local home cap now=2000000000 fm ledger
  fm="$TMP_ROOT/lane-home"
  mkdir -p "$fm/state" "$fm/data"
  ledger="$fm/state/stall-ledger.tsv"
  {
    printf '%s\tstall-open\tworker\tfm-a\t%s\t%s\t-\t-\t-\tworker:fm-a:%s\n' $((now - 1400)) $((now - 1500)) $((now - 1400)) $((now - 1500))
    printf '%s\tstall-open\tworker\tfm-b\t%s\t%s\t-\t-\t-\tworker:fm-b:%s\n' $((now - 1700)) $((now - 1800)) $((now - 1700)) $((now - 1800))
    printf '%s\tstall-close\tworker\tfm-b\t%s\t%s\tfirstmate\t%s\t300\tworker:fm-b:%s\n' $((now - 1500)) $((now - 1800)) $((now - 1700)) $((now - 1500)) $((now - 1800))
    printf '%s\tstall-open\tworker\tfm-c\t%s\t%s\t-\t-\t-\tworker:fm-c:%s\n' $((now - 500)) $((now - 600)) $((now - 500)) $((now - 600))
  } > "$ledger"
  # Hold the observe throttle so this case reads exactly the rows above.
  printf '%s\n' "$now" > "$fm/state/.stall-ledger-observed"
  cap=$(fixture_captain 1 false "" empty "❯ " "$now" | jq -c --arg fm "$fm" '.fm_home=$fm')
  home=$(write_home lane "[$cap]")
  FM_NUDGE_READY_PR_BIN=/nonexistent FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "a lane stalled 25m wakes a busy captain with no other open work"
  [ "$(cut -f3 "$home/send.log")" = "$FIXED Stalled lanes: fm-a 25m." ] \
    || fail "the wake must carry only the open lane past 20m: $(cat "$home/send.log")"
  tail -n 1 "$home/state/nudge.jsonl" | jq -e '.lanes == "Stalled lanes: fm-a 25m."' >/dev/null \
    || fail "the JSONL row must record the lane table: $(tail -n 1 "$home/state/nudge.jsonl")"
  printf '%s\tstall-close\tworker\tfm-a\t%s\t%s\tfirstmate\t%s\t1500\tworker:fm-a:%s\n' $((now - 10)) $((now - 1500)) $((now - 1400)) $((now - 10)) $((now - 1500)) >> "$ledger"
  home=$(write_home lane-young "[$cap]")
  FM_NUDGE_READY_PR_BIN=/nonexistent FM_NUDGE_NOW=$now run_once "$home"
  assert_equals skip_not_idle "$(last_event "$home")" "a lane stalled under 20m does not wake the captain"
  [ ! -s "$home/send.log" ] || fail "a young lane stall must not type: $(cat "$home/send.log")"
  pass "fm-captain-nudge: a lane with no progress for 20m wakes the captain with the lane table"
}
write_fake_orca() {  # <dir> <last-output-ms>
  mkdir -p "$1"
  cat > "$1/orca" <<SH
#!/bin/sh
case "\$1 \$2" in
  "terminal list")
    printf '%s\n' '{"result":{"terminals":[{"id":"term_stale","title":"captain-a","lastOutputAt":$2},{"id":"term_live","title":"captain-a","lastOutputAt":$2},{"id":"term_new","title":"captain-a","lastOutputAt":$2}]}}'
    ;;
  "terminal read")
    t=''
    while [ "\$#" -gt 0 ]; do [ "\$1" = --terminal ] && t=\$2; shift; done
    printf '%s\n' "\$t" >> "\$FAKE_ORCA_LOG"
    printf '%s\n' '{"result":{"terminal":{"tail":"❯ ","draft":""}}}'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/orca"
}

write_locate_bin() {  # <dir> -> fake fm-captain-locate printing one line per call from $FAKE_LOCATE_LINES
  mkdir -p "$1"
  cat > "$1/locate" <<'SH'
#!/bin/sh
[ -n "${FM_HOME:-}" ] || exit 3
n=$(cat "$FAKE_LOCATE_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FAKE_LOCATE_COUNT"
line=$(sed -n "${n}p" "$FAKE_LOCATE_LINES")
[ -n "$line" ] || line=$(tail -n 1 "$FAKE_LOCATE_LINES")
printf '%s\n' "$line"
case "$line" in *state=held*) exit 0 ;; *) exit 1 ;; esac
SH
  chmod +x "$1/locate"
}

orca_captain_home() {  # <name> -> config home for an Orca captain configured on the stale pane
  local fm="$TMP_ROOT/$1-fm" cap
  mkdir -p "$fm/state"
  printf -- '- [ ] do the thing\n' > "$TMP_ROOT/$1-queue.md"
  cap=$(jq -nc --arg fm "$fm" --arg q "$TMP_ROOT/$1-queue.md" \
    '[{id:"alpha", owner:"firstmate", backend:"orca", handle:"term_stale", title:"captain-a", fm_home:$fm,
       idle_min:15, open_work:{repos:[], queue_file:$q}}]')
  write_home "$1" "$cap"
}

orca_once() {  # <home> <now> <locate-lines...>
  local home=$1 now=$2 bin="$TMP_ROOT/f11-bin"
  shift 2
  write_fake_orca "$bin" "$(( (now - 30 * 60) * 1000 ))"
  write_locate_bin "$bin"
  printf '%s\n' "$@" > "$home/locate.lines"
  : > "$home/locate.count"
  PATH="$bin:$PATH" FM_NUDGE_LOCATE_BIN="$bin/locate" FM_NUDGE_READY_PR_BIN=/nonexistent \
    FAKE_LOCATE_LINES="$home/locate.lines" FAKE_LOCATE_COUNT="$home/locate.count" FAKE_ORCA_LOG="$home/orca.log" \
    FM_NUDGE_NOW=$now run_once "$home"
}

test_once_targets_the_lock_owner_not_the_configured_pane() {
  local home now=2000000000
  home=$(orca_captain_home lock-owner)
  orca_once "$home" "$now" 'CAPTAIN v1 pid=4242 handle=term_live state=held'
  assert_equals nudge "$(last_event "$home")" "the live lock owner idle 30m with open work gets the wake"
  [ "$(sort -u "$home/orca.log")" = term_live ] || fail "only the lock owner's pane may be read: $(cat "$home/orca.log")"
  [ "$(cut -f2 "$home/send.log")" = term_live ] || fail "the wake must go to the lock owner: $(cat "$home/send.log")"
  tail -n 1 "$home/state/nudge.jsonl" | jq -e '.target == "term_live"' >/dev/null \
    || fail "the JSONL row must name the lock owner's terminal"
  pass "fm-captain-nudge: an Orca captain with a home is reached at its lock owner's terminal, not the configured pane"
}

test_once_reports_an_unknown_captain_without_typing() {
  local home now=2000000000 state
  for state in unknown free stale unreadable; do
    home=$(orca_captain_home "lock-$state")
    orca_once "$home" "$now" "CAPTAIN v1 pid=0 handle=none state=$state"
    assert_equals captain_unknown "$(last_event "$home")" "a $state lock reports an unknown captain"
    tail -n 1 "$home/state/nudge.jsonl" | jq -e --arg s "$state" '.severity == "medium" and .lock_state == $s' >/dev/null \
      || fail "the $state row must be medium and name the lock state: $(tail -n 1 "$home/state/nudge.jsonl")"
    [ ! -s "$home/orca.log" ] || fail "a $state lock must not read the configured pane: $(cat "$home/orca.log")"
    [ ! -s "$home/send.log" ] || fail "a $state lock must not type: $(cat "$home/send.log")"
  done
  pass "fm-captain-nudge: a captain home without a held lock is reported unknown and never typed into"
}

test_once_refuses_a_send_after_the_lock_moves() {
  local home now=2000000000
  home=$(orca_captain_home lock-moved)
  orca_once "$home" "$now" 'CAPTAIN v1 pid=4242 handle=term_live state=held' 'CAPTAIN v1 pid=5151 handle=term_new state=held'
  [ "$(sort -u "$home/orca.log")" = term_live ] || fail "the pass observed the first owner: $(cat "$home/orca.log")"
  [ ! -s "$home/send.log" ] || fail "a send after the lock moved must be refused: $(cat "$home/send.log")"
  jq -e 'select(.event == "blocker" and .reason == "send failed")' "$home/state/nudge.jsonl" >/dev/null \
    || fail "the refused send must be recorded as a blocker: $(cat "$home/state/nudge.jsonl")"
  pass "fm-captain-nudge: a lock handoff between read and send stops the send"
}
test_decide_council_row_once_per_stall() {
  local out obs
  obs() {  # <idle> <tier> <cool> [dialog] [extra-json]
    base_obs "$1" 20 true "2 open PRs" "${4:-}" empty "$3" 0 false false \
      | jq -c --argjson tier "$2" '. + {escalate_min:40, council_min:60, stall_tier:$tier}'"${5:-}"
  }
  out=$(decide "$(obs 65 1 0 permission)")
  assert_equals stall_council "$(event_of "$out")" "the council row still fires behind a modal before escalate was typed"
  out=$(decide "$(obs 70 1 0 permission ' + {council_raised:true}')")
  assert_equals blocker "$(event_of "$out")" "the council row is raised once per stall, never every pass"
  out=$(decide "$(obs 70 2 0 permission ' + {council_raised:true}')")
  assert_equals blocker "$(event_of "$out")" "a raised council row does not repeat even at the escalate tier"
  pass "fm-captain-nudge: decide raises one council row per stall at any tier"
}

test_once_settle_no_reading_keeps_send_unacknowledged() {
  local home cap echoed now=2000000000 st
  echoed=$(printf '❯ %s\n✻ Working\n❯ ' "$FIXED")
  cap=$(fixture_captain 20 true "" empty "❯ " $((now - 20 * 60)) \
    | jq -c '.fixture.after_send = [{read_failed:true}]')
  home=$(write_home settle-no-read "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "idle 20m with open work gets the first wake"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.fingerprint == ""' >/dev/null \
    || fail "a settle with no reading must leave the send unacknowledged, not the pre-send view: $st"
  cap=$(printf '%s' "$cap" | jq -c --arg s "$echoed" --argjson at "$now" \
    '.fixture.screen = $s | .fixture.last_activity_epoch = $at | .fixture.after_send = []')
  write_home settle-no-read "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 20 * 60)) run_once "$home"
  if jq -e 'select(.event == "stall_acked")' "$home/state/nudge.jsonl" >/dev/null; then
    fail "a send whose settle could not read the pane must not be acked by its own later echo"
  fi
  assert_equals stall_escalate "$(last_event "$home")" "the ladder still escalates when the settle got no reading"
  pass "fm-captain-nudge: a settle read failure keeps the send unacknowledged"
}

test_once_settle_before_the_echo_keeps_send_unacknowledged() {
  local home cap echoed now=2000000000 st
  echoed=$(printf '❯ %s\n✻ Working\n❯ ' "$FIXED")
  cap=$(fixture_captain 20 true "" empty "❯ " $((now - 20 * 60)) \
    | jq -c '.fixture.after_send = [{}]')
  home=$(write_home settle-early "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "idle 20m with open work gets the first wake"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.fingerprint == ""' >/dev/null \
    || fail "a settle that finishes before the echo must not store the pre-send view: $st"
  cap=$(printf '%s' "$cap" | jq -c --arg s "$echoed" --argjson at "$now" \
    '.fixture.screen = $s | .fixture.last_activity_epoch = $at | .fixture.after_send = []')
  write_home settle-early "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 20 * 60)) run_once "$home"
  if jq -e 'select(.event == "stall_acked")' "$home/state/nudge.jsonl" >/dev/null; then
    fail "a send whose echo rendered after the settle must not be acked by that echo"
  fi
  assert_equals stall_escalate "$(last_event "$home")" "the ladder still escalates when the settle beat the echo"
  pass "fm-captain-nudge: a settle that beats the echo keeps the send unacknowledged"
}

test_once_submits_own_lane_table_prompt_left_unsent() {
  local home cap now=2000000000 prompt
  prompt="$FIXED Stalled lanes: ship-one 25m."
  cap=$(fixture_captain 25 true "" pending "› $prompt" $((now - 25 * 60)))
  home=$(write_home own-unsent-lanetable "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "the own lane-table wake left unsent is submitted"
  [ "$(cut -f3 "$home/send.log")" = "<Enter>" ] \
    || fail "only Enter may be sent for the own unsent lane-table prompt: $(cat "$home/send.log")"
  cap=$(fixture_captain 25 true "" pending "› $prompt, ship-two 30m and more from eduardo" $((now - 25 * 60)))
  home=$(write_home own-unsent-lanetable-edited "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals skipped_input_not_empty "$(last_event "$home")" "an edited lane table is never submitted"
  [ ! -s "$home/send.log" ] || fail "an edited lane table must not receive Enter"

  local wrapped
  wrapped="❯ Continue open work: pick next item, reroute quota if exhausted, never park
  self-servable work Stalled lanes: ship-fm-overnight-wake 25m,
  ship-fm-quota-floor 31m, scout-fm-lane-cap 44m.

  ? for shortcuts"
  cap=$(fixture_captain 25 true "" pending "$wrapped" $((now - 25 * 60)))
  home=$(write_home own-unsent-wrapped "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "a lane-table wake wrapped over several rows is submitted"
  [ "$(cut -f3 "$home/send.log")" = "<Enter>" ] \
    || fail "only Enter may be sent for a wrapped own prompt: $(cat "$home/send.log")"

  cap=$(fixture_captain 25 true "" pending "${wrapped%%$'\n\n'*}
  and also look at the flaky deploy" $((now - 25 * 60)))
  home=$(write_home own-unsent-wrapped-extended "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals skipped_input_not_empty "$(last_event "$home")" "a wrapped prompt the captain extended is never submitted"
  [ ! -s "$home/send.log" ] || fail "an extended wrapped prompt must not receive Enter"

  cap=$(fixture_captain 25 true "" pending "› $FIXED Stalled" $((now - 25 * 60)) \
    | jq -c --arg d "$prompt more" '.fixture.draft = $d')
  home=$(write_home own-unsent-draft-extended "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals skipped_input_not_empty "$(last_event "$home")" "a native draft beyond the own prompt is never submitted"
  [ ! -s "$home/send.log" ] || fail "an extended native draft must not receive Enter"

  cap=$(fixture_captain 25 true "" pending "› $FIXED Stalled" $((now - 25 * 60)) \
    | jq -c --arg d "$prompt" '.fixture.draft = $d')
  home=$(write_home own-unsent-draft "[$cap]")
  printf '{"last_nudge_epoch":%s,"fingerprint":"x","consecutive_no_progress":0,"escalated":false}\n' $((now - 300)) > "$home/state/captains/alpha.json"
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "a native draft equal to the own prompt is submitted"
  pass "fm-captain-nudge: submits its own lane-table wake left unsent, Enter only"
}

test_once_council_never_retires_the_escalate_rung() {
  local home cap now=2000000000 st
  cap=$(fixture_captain 20 true "" empty "❯ " $((now - 20 * 60)))
  home=$(write_home council-modal "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals nudge "$(last_event "$home")" "the first wake fires at 20m"
  cap=$(fixture_captain 60 true "permission" empty "❯ " $((now - 20 * 60)))
  write_home council-modal "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 40 * 60)) run_once "$home"
  assert_equals stall_council "$(last_event "$home")" "a council row is raised behind the modal at 60m"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 1' >/dev/null \
    || fail "the council row must not retire the unsent escalate rung: $st"
  cap=$(fixture_captain 75 true "" empty "❯ " $((now - 20 * 60)))
  write_home council-modal "[$cap]" >/dev/null
  FM_NUDGE_NOW=$((now + 55 * 60)) run_once "$home"
  assert_equals stall_escalate "$(last_event "$home")" "once the modal clears the escalate rung still fires"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 2' >/dev/null || fail "escalate must record tier 2: $st"
  pass "fm-captain-nudge: a council row never retires the escalate rung"
}

test_once_first_sample_past_council_still_climbs() {
  local home cap now=2000000000 st
  cap=$(fixture_captain 65 true "" empty "❯ " $((now - 65 * 60)))
  home=$(write_home council-first "[$cap]")
  FM_NUDGE_NOW=$now run_once "$home"
  assert_equals stall_council "$(last_event "$home")" "a first sample past 60m raises the council row without typing"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 0' >/dev/null \
    || fail "a council row before any wake must not climb the tier: $st"
  FM_NUDGE_NOW=$((now + 1 * 60)) run_once "$home"
  assert_equals nudge "$(last_event "$home")" "the first wake still fires after the council row"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 1' >/dev/null || fail "the wake must record tier 1: $st"
  FM_NUDGE_NOW=$((now + 25 * 60)) run_once "$home"
  assert_equals stall_escalate "$(last_event "$home")" "the escalate rung still fires after a first-sample council row"
  st=$(cat "$home/state/captains/alpha.json")
  printf '%s' "$st" | jq -e '.stall_tier == 2' >/dev/null || fail "escalate must record tier 2: $st"
  pass "fm-captain-nudge: a first sample past the council minute still climbs the ladder in order"
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
  test_decide_ladder_escalates_then_councils \
  test_decide_council_row_once_per_stall \
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
  test_expand_path_literal_tilde \
  test_herdr_idle_tracks_screen_change_not_heartbeat \
  test_once_submits_own_unsent_prompt_only \
  test_once_ladder_wakes_escalates_councils_and_records_ack \
  test_once_ladder_does_not_ack_its_own_wake \
  test_once_settle_keeps_last_reading_when_a_reread_fails \
  test_once_settle_no_reading_keeps_send_unacknowledged \
  test_once_settle_before_the_echo_keeps_send_unacknowledged \
  test_once_submits_own_lane_table_prompt_left_unsent \
  test_once_council_never_retires_the_escalate_rung \
  test_once_first_sample_past_council_still_climbs \
  test_once_merge_ready_nudges_once_after_15_minutes \
  test_once_records_the_captain_home_stall_ledger \
  test_once_stalled_lane_wakes_with_the_lane_table \
  test_once_targets_the_lock_owner_not_the_configured_pane \
  test_once_reports_an_unknown_captain_without_typing \
  test_once_refuses_a_send_after_the_lock_moves
