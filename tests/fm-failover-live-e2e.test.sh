#!/usr/bin/env bash
# tests/fm-failover-live-e2e.test.sh - live guard for the two signals provider
# failover reads from the real installed Claude Code: the StopFailure hook
# payload fm-spawn registers for a ship (bin/fm-failover.sh hook) and the
# rendered refusal on an idle pane (fm_wd_provider_error_screen).
# Claude talks to a local stand-in endpoint that answers every request with a
# 429 rate-limit refusal, then with a credit-balance billing refusal, so the
# guard spends no model tokens and touches no account. Claude runs in an
# isolated config directory and an isolated tmux server; no live fleet home,
# session, or credential is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_FAILOVER_LIVE_E2E claude tmux jq python3

FO="$ROOT/bin/fm-failover.sh"
TMP_ROOT=$(fm_test_tmproot fm-failover-live)
LAB=$(cd "$TMP_ROOT" && pwd -P)
SOCK="fm-failover-live-$$"
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
SRV_PID=''

cleanup() {
  env -u TMUX -u TMUX_PANE tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  [ -z "$SRV_PID" ] || { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }
  fm_test_cleanup
}
trap cleanup EXIT

fail_live() {  # <message>
  printf 'not ok - Claude %s: %s\n' "${CLAUDE_VERSION:-unknown}" "$1" >&2
  exit 1
}

# The stand-in endpoint: <mode> is 429 or billing, and the bound port is
# written to <port-file> so parallel runs never collide.
cat > "$LAB/endpoint.py" <<'PY'
import http.server, json, sys
mode, port_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length') or 0))
        if mode == '429':
            code, err = 429, {"type": "rate_limit_error", "message": "This request would exceed your account's rate limit. Please try again later."}
        else:
            code, err = 400, {"type": "invalid_request_error", "message": "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}
        body = json.dumps({"type": "error", "error": err}).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
with open(port_file, 'w') as f:
    f.write(str(srv.server_port))
srv.serve_forever()
PY

start_endpoint() {  # <mode>
  local i=0
  if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; fi
  rm -f "$LAB/port"
  python3 "$LAB/endpoint.py" "$1" "$LAB/port" &
  SRV_PID=$!
  while [ ! -s "$LAB/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$LAB/port" ] || fail_live 'the stand-in endpoint never started'
}

# A fresh Claude config directory that skips onboarding, approves the stand-in
# key (Claude records an approved key by its last 20 characters), and trusts
# the work directory, so no dialog sits in front of the turn.
KEY=fake-test-key-not-a-secret
mkdir -p "$LAB/cfg" "$LAB/wd" "$LAB/home/state" "$LAB/home/config" "$LAB/home/data" "$LAB/no-records"
jq -n --arg wd "$LAB/wd" --arg key "$KEY" '{hasCompletedOnboarding: true, theme: "dark",
  customApiKeyResponses: {approved: [$key[-20:]], rejected: []},
  projects: {($wd): {hasTrustDialogAccepted: true}}}' > "$LAB/cfg/.claude.json"
STATE="$LAB/home/state"
export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$LAB/home/config" FM_DATA_OVERRIDE="$LAB/home/data"

# run_turn <id> <mode>: one Claude turn against the stand-in endpoint with the
# StopFailure hooks fm-spawn installs for a ship: the busy writer, then the
# failover record. Leaves the pane open for the screen check.
run_turn() {
  local id=$1 mode=$2 gen busy hook
  start_endpoint "$mode"
  gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id") || fail_live "could not arm the busy record for $id"
  busy="'$ROOT/bin/fm-busy-event.sh' apply '$STATE' '$id'"
  hook="'$FO' hook '$id' --gen '$gen' --state '$STATE' 2>/dev/null || true"
  jq -n --arg submit "$busy busy --gen '$gen' --source claude-hook --event user-prompt-submit 2>/dev/null || true" \
    --arg stopfail "$busy idle --gen '$gen' --source claude-hook --event stop-failure 2>/dev/null || true" \
    --arg failover "$hook" '{hooks: {
      UserPromptSubmit: [{hooks: [{type: "command", command: $submit}]}],
      StopFailure: [{hooks: [{type: "command", command: $stopfail}, {type: "command", command: $failover}]}]}}' \
    > "$LAB/settings-$id.json"
  local launch
  launch=$(printf '%q ' env -u CLAUDECODE -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN \
    "CLAUDE_CONFIG_DIR=$LAB/cfg" "ANTHROPIC_BASE_URL=http://127.0.0.1:$(cat "$LAB/port")" \
    "ANTHROPIC_API_KEY=$KEY" CLAUDE_CODE_MAX_RETRIES=0 DISABLE_AUTOUPDATER=1 \
    "FM_HOME=$FM_HOME" "FM_STATE_OVERRIDE=$STATE" "FM_CONFIG_OVERRIDE=$FM_CONFIG_OVERRIDE" "FM_DATA_OVERRIDE=$FM_DATA_OVERRIDE" \
    claude --settings "$LAB/settings-$id.json" 'say hi')
  env -u TMUX -u TMUX_PANE tmux -L "$SOCK" new-session -d -s "$id" -x 160 -y 40 -c "$LAB/wd" "$launch" \
    || fail_live "could not start Claude for $id"
}

pane_tail() {  # <id>
  env -u TMUX -u TMUX_PANE tmux -L "$SOCK" capture-pane -p -t "$1" 2>/dev/null | tail -n 12
}

wait_record() {  # <id>: wait up to 90s for the hook's provider-error record
  local i=0
  while [ ! -s "$STATE/$1.provider-error" ] && [ "$i" -lt 900 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$STATE/$1.provider-error" ] || fail_live "no StopFailure record for $1 within 90s; pane: $(pane_tail "$1")"
}

screen_class() {  # <id> <want>: wait up to 30s for the idle pane to class <want>
  local i=0 got=none
  while [ "$i" -lt 300 ]; do
    env -u TMUX -u TMUX_PANE tmux -L "$SOCK" capture-pane -p -t "$1" > "$LAB/screen-$1.txt" 2>/dev/null || true
    got=$(FM_STATE_OVERRIDE="$LAB/no-records" bash "$FO" detect "$1" --screen-file "$LAB/screen-$1.txt" 2>/dev/null) || got=none
    [ "$got" != "class=$2 source=pane" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail_live "the idle pane for $1 classed '$got', not $2; pane: $(tail -n 12 "$LAB/screen-$1.txt")"
}

start=$(date +%s)
run_turn rl 429
wait_record rl
rl_secs=$(( $(date +%s) - start ))
out=$(bash "$FO" detect rl) || fail_live "detect found no 429 record: $out"
[ "$out" = 'class=rate_limit source=record' ] || fail_live "the 429 StopFailure recorded '$out', not rate_limit"
screen_class rl rate_limit
pass "Claude $CLAUDE_VERSION: a 429 refusal fires StopFailure into a rate_limit record in ${rl_secs}s, and the idle pane classes rate_limit"

start=$(date +%s)
run_turn bl billing
wait_record bl
bl_secs=$(( $(date +%s) - start ))
out=$(bash "$FO" detect bl) || fail_live "detect found no billing record: $out"
[ "$out" = 'class=billing source=record' ] || fail_live "the billing StopFailure recorded '$out', not billing"
screen_class bl billing
pass "Claude $CLAUDE_VERSION: a credit-balance refusal fires StopFailure into a billing record in ${bl_secs}s, and the idle pane classes billing"
