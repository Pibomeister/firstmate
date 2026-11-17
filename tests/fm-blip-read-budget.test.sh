#!/usr/bin/env bash
# Read-only remote probes give up on an offline host inside the short budget.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-blip-read-budget)
SLEEP_LOG="$TMP_ROOT/sleep"
SSH_COUNT="$TMP_ROOT/ssh.count"
SSH_LOG="$TMP_ROOT/ssh.log"
mkdir -p "$TMP_ROOT"

install_offline_ssh() { # <dir>
  mkdir -p "$1"
  cat > "$1/ssh" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_BLIP_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$FM_BLIP_SSH_COUNT"
printf '%s\n' "$*" >> "$FM_BLIP_SSH_LOG"
cat >/dev/null
printf 'ssh: connect to host offline port 22: Connection refused\n' >&2
exit 255
SH
  chmod +x "$1/ssh"
}

reset_clock() {
  : > "$SLEEP_LOG"
  printf '0\n' > "$SSH_COUNT"
  : > "$SSH_LOG"
  export FM_BLIP_NOW=20000
  export FM_BLIP_SLEEP_LOG="$SLEEP_LOG"
  export FM_BLIP_SSH_COUNT="$SSH_COUNT"
  export FM_BLIP_SSH_LOG="$SSH_LOG"
}

sleep_sum() {
  awk '{ total += $1 } END { print total + 0 }' "$SLEEP_LOG"
}

assert_short() { # <label>
  local sum count
  sum=$(sleep_sum)
  count=$(cat "$SSH_COUNT")
  [ "$sum" -le 15 ] || fail "$1 waited ${sum}s, past the 15-second read budget"
  [ "$sum" -gt 0 ] || fail "$1 did not retry the offline host"
  [ "$count" -gt 1 ] || fail "$1 called ssh only $count time(s)"
}

write_route() { # <home> <id>
  mkdir -p "$1/data" "$1/state" "$1/config"
  fm_write_meta "$1/state/$2.meta" \
    "window=remote:$2" \
    "endpoint_task_id=$2" \
    "worktree=/remote/$2" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=offline" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1" \
    "home=/remote/$2-home"
  cat > "$1/data/secondmates.md" <<EOF
- $2 - remote probe (host: offline; root: /remote/root; home: /remote/$2-home; scope: remote probes; projects: alpha; added 2026-11-12)
EOF
}

test_liveness_poll_returns_within_the_short_budget() {
  local home
  home="$TMP_ROOT/liveness"
  install_offline_ssh "$home/fakebin"
  write_route "$home" rsm1
  reset_clock
  STATE="$home/state" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SSH_BIN="$home/fakebin/ssh" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 poll
    ' "$ROOT" "$home/state/rsm1.meta" >/dev/null
  assert_short "the liveness poll"
  pass "an offline host returns within the short budget on the liveness poll"
}

test_crew_state_returns_within_the_short_budget() {
  local home
  home="$TMP_ROOT/crew"
  install_offline_ssh "$home/fakebin"
  write_route "$home" rsm
  reset_clock
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SSH_BIN="$home/fakebin/ssh" \
    "$ROOT/bin/fm-crew-state.sh" rsm >/dev/null
  assert_short "fm-crew-state"
  pass "an offline host returns within the short budget on fm-crew-state"
}

test_pending_reply_tick_returns_within_the_short_budget() {
  local home state corr
  home="$TMP_ROOT/pending"
  install_offline_ssh "$home/fakebin"
  write_route "$home" rsm1
  state="$home/state"
  reset_clock
  export FM_PENDING_REPLY_NOW=30000
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_create "$home" "$state" rsm1 "ask for the report")
  fm_pending_reply_mark_delivered "$state" "$corr"
  FM_HOME="$home" FM_SSH_BIN="$home/fakebin/ssh" \
    fm_pending_reply_tick "$state"
  assert_short "the pending-reply tick"
  pass "an offline host returns within the short budget on the pending-reply tick"
}

test_fleet_snapshot_returns_within_the_short_budget() {
  local home
  command -v jq >/dev/null 2>&1 || { pass "fleet snapshot skipped: jq is absent"; return 0; }
  home="$TMP_ROOT/snapshot"
  install_offline_ssh "$home/fakebin"
  write_route "$home" rsm1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  reset_clock
  FM_HOME="$home" FM_SSH_BIN="$home/fakebin/ssh" PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json >"$home/out.json" 2>"$home/err"
  # fm-on sends the remote command as the last base64 field on the ssh line.
  local probed=0 line argv remote_cmd
  while IFS= read -r line; do
    argv=${line##* }
    remote_cmd=$(printf '%s' "$argv" | base64 --decode 2>/dev/null | tr '\000' '\n' | head -1 || true)
    if [ "$remote_cmd" = "fm-remote-file.sh" ]; then
      probed=1
    fi
  done < "$SSH_LOG"
  if [ "$probed" -ne 1 ]; then
    fail "the fleet snapshot did not probe the remote home: $(tr '\n' ' ' < "$SSH_LOG") $(cat "$home/err")"
  fi
  local sum
  sum=$(sleep_sum)
  # Crew-state observation and the summary fetch are separate short probes.
  [ "$sum" -le 45 ] || fail "the fleet snapshot waited ${sum}s, so a probe used the long budget"
  [ "$sum" -gt 0 ] || fail "the fleet snapshot did not retry the offline host"
  pass "an offline host returns within the short budget on the fleet snapshot"
}

fm_test_run \
  test_liveness_poll_returns_within_the_short_budget \
  test_crew_state_returns_within_the_short_budget \
  test_pending_reply_tick_returns_within_the_short_budget \
  test_fleet_snapshot_returns_within_the_short_budget
