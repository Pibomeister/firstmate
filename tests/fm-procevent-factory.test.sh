#!/usr/bin/env bash
# Behavior tests for the Factory process-event adapter
# (bin/fm-procevent-factory.sh) and its model preflight.
#
# Every scenario runs the adapter's public commands, and the generic runner where
# a wake is the observable, against a local fake Factory HTTP server. No test
# contacts a real Factory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-factory-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1

PROJECT=0b7c1f9e-3d2a-4c55-9a10-6f2b8e4d7a31
SOURCE="factory-$PROJECT"
TOKEN='gwsp_fixture_not-a-real-secret'

pe()      { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
factory() { FM_HOME="$1" "$ROOT/bin/fm-procevent-factory.sh" "${@:2}"; }
new_home() { mkdir -p "$1/state" "$1/config"; fm_test_track_procevent_home "$1"; }
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }
results() { find "$1/state/procevent-inbox" -maxdepth 1 -name "$SOURCE.*.result" 2>/dev/null | wc -l | tr -d ' '; }
# Distinct wake keys: reconcile re-queues an unacknowledged result by design and
# the watcher delivers once per source and sequence, so the key is the wake.
wakes() {
  awk -F '\t' -v k="procevent:$SOURCE:" 'index($4, k) == 1 { print $4 }' "$1/state/.wake-queue" 2>/dev/null \
    | sort -u | wc -l | tr -d ' '
}
# A result counts once both its capture and its wake landed; publication
# follows capture inside the runner.
wait_for_results() {  # <home> <count> [tries]
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    [ "$(results "$1")" -ge "$2" ] && [ "$(wakes "$1")" -ge "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

# --- fake Factory -------------------------------------------------------------
# Serves <fixture>/<route>.json with the HTTP status in <route>.status (200 when
# absent, 404 when the body is absent too) and logs each request line plus its
# Authorization header, so a test can prove the token travelled as a header.
SERVER="$TMP_ROOT/fake-factory.py"
cat > "$SERVER" <<'PY'
import http.server, os, sys
fix = sys.argv[1]
def route(path):
    path = path.split('?', 1)[0]
    parts = path.strip('/').split('/')
    if parts[:3] == ['web', 'factory', 'projects'] and len(parts) == 5 and parts[4] == 'attention':
        return 'attention'
    if parts[:3] == ['web', 'factory', 'projects'] and len(parts) == 4:
        return 'project'
    if parts == ['web', 'config', 'models']:
        return 'models'
    return None
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(fix, 'requests.log'), 'a') as log:
            log.write('%s auth=%s\n' % (self.path, self.headers.get('Authorization', '')))
        name = route(self.path)
        body_path = os.path.join(fix, '%s.json' % name) if name else None
        status_path = os.path.join(fix, '%s.status' % name) if name else None
        status = 404
        body = b'{"error":"not_found"}'
        if body_path and os.path.exists(body_path):
            status = 200
            with open(body_path, 'rb') as f:
                body = f.read()
        if status_path and os.path.exists(status_path):
            with open(status_path) as f:
                status = int(f.read().strip())
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
with open(os.path.join(fix, 'port.tmp'), 'w') as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(fix, 'port.tmp'), os.path.join(fix, 'port'))
server.serve_forever()
PY

start_factory() {  # <fixture-dir>; prints the base URL
  mkdir -p "$1"
  python3 "$SERVER" "$1" >/dev/null 2>&1 &
  for _ in $(seq 1 100); do [ -s "$1/port" ] && break; sleep 0.05; done
  [ -s "$1/port" ] || fail "fake Factory did not start"
  printf 'http://127.0.0.1:%s\n' "$(cat "$1/port")"
}

# A port with nothing listening: bound once to learn a free number, then closed.
closed_port_url() {
  printf 'http://127.0.0.1:%s\n' "$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
}

configure() {  # <home> <url>
  printf '%s\n' "$TOKEN" > "$1/config/factory.token"
  chmod 600 "$1/config/factory.token"
  printf 'url=%s\ntoken_file=%s\n' "$2" "$1/config/factory.token" > "$1/config/factory"
}

item() {  # <decision-uuid> <detail>
  printf '{"key":"factory:%s:automation-failed:%s:0","kind":"automation-failed","decisionId":"%s","occurrence":0,"workItemId":"11111111-1111-4111-8111-111111111111","title":"ENG-4357 run","detail":"%s","failureCode":"dispatch_failed","canRetry":true,"occurredAt":"2026-11-09T15:00:00.000Z","read":false,"archived":false}' \
    "$PROJECT" "$1" "$1" "$2"
}
attention() {  # <fixture-dir> [item-json...]
  local fix=$1 IFS=,
  shift
  printf '{"items":[%s],"kinds":{},"hasMore":false}\n' "$*" > "$fix/attention.json"
}

D1=aaaaaaaa-0000-4000-8000-000000000001
D2=aaaaaaaa-0000-4000-8000-000000000002
ERR1='ProviderAuthRequiredError: openai-codex requires sign-in for this organization'

# --- help ---------------------------------------------------------------------
if help=$("$ROOT/bin/fm-procevent-factory.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
assert_contains "$help" "fm-procevent-factory.sh preflight --project <id>" "help names the preflight"
assert_not_contains "$help" "set -u" "help leaks executable source"
pass "help renders only the header"

# --- poll reports a new automation-failed item, with its error text -------------
H="$TMP_ROOT/h-poll"; new_home "$H"
FIX="$TMP_ROOT/fx-poll"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
attention "$FIX" "$(item "$D1" "$ERR1")"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: failed" "a new failure is reported"
assert_contains "$out" "$ERR1" "the result carries the item's error text"
assert_contains "$out" "factory:$PROJECT:automation-failed:$D1:0" "the result names the item key"
assert_grep "auth=Bearer $TOKEN" "$FIX/requests.log" "the token travels as a bearer header"
assert_grep "kind=automation-failed" "$FIX/requests.log" "the poll asks only for automation-failed items"
pass "poll reports a new automation-failed item with its error text"

# --- end to end: one wake, no repeat, a later new item wakes again -------------
H="$TMP_ROOT/h-e2e"; new_home "$H"
FIX="$TMP_ROOT/fx-e2e"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
attention "$FIX" "$(item "$D1" "$ERR1")"
out=$(factory "$H" arm --project "$PROJECT" --interval 0.1)
assert_contains "$out" "armed: $SOURCE" "arm registers the project source"
assert_no_grep "$TOKEN" "$H/state/procevent/$SOURCE.source" "the registration never stores the token"
pe "$H" reconcile >/dev/null 2>&1
wait_for_results "$H" 1 || fail "no result was captured for the new failure"
payloads=$(wake_payloads "$H")
assert_contains "$payloads" "procevent factory $SOURCE 1" "the failure reached the durable wake queue"
assert_contains "$payloads" "ProviderAuthRequiredError" "the wake reason carries the error text"
assert_equals 1 "$(wakes "$H")" "exactly one wake for one failure"
# The source is not terminal: reconcile restarts it, and the unchanged item
# must not be reported again across many polls.
for _ in 1 2 3; do pe "$H" reconcile >/dev/null 2>&1; sleep 1.2; done
assert_equals 1 "$(results "$H")" "a repeated item is never captured twice"
assert_present "$H/state/procevent/$SOURCE.source" "a failure result keeps the watch armed"
attention "$FIX" "$(item "$D1" "$ERR1")" "$(item "$D2" 'second failure\u001b[31m text')"
pe "$H" reconcile >/dev/null 2>&1
wait_for_results "$H" 2 || fail "a later new failure was not captured"
second="$H/state/procevent-inbox/$SOURCE.2.result"
assert_grep "$D2" "$second" "the second result reports the new item"
assert_no_grep "$D1" "$second" "the second result does not repeat the old item"
assert_contains "$(wake_payloads "$H")" "second failure[31m text" "the second wake carries its own error text"
wake_payloads "$H" | LC_ALL=C grep -q "$(printf '\033')" && fail "a control character from Factory reached the wake queue"
assert_contains "$(factory "$H" classify "$second")" failed "classify reads a failure result"
factory "$H" terminal "$second" && fail "a failure result must not end the watch"
pe "$H" reconcile >/dev/null 2>&1
assert_equals 2 "$(wakes "$H")" "one wake per new failure"
factory "$H" retire --project "$PROJECT" >/dev/null
pass "a new failure wakes once, a repeat never does, and a later failure wakes again"

# --- unreachable Factory: one diagnostic, then the watch stops -----------------
H="$TMP_ROOT/h-down"; new_home "$H"
configure "$H" "$(closed_port_url)"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: error" "an unreachable Factory is an error result"
assert_contains "$out" "condition_polls: 3" "three consecutive unreachable reads are tolerated first"
assert_contains "$out" "unreachable" "the diagnostic says the Factory is unreachable"
factory "$H" arm --project "$PROJECT" --interval 0.05 >/dev/null
pe "$H" reconcile >/dev/null 2>&1
wait_for_results "$H" 1 || fail "the unreachable diagnostic was not captured"
for _ in $(seq 1 50); do [ -e "$H/state/procevent/$SOURCE.source" ] || break; sleep 0.1; done
assert_absent "$H/state/procevent/$SOURCE.source" "an unreachable Factory retires the watch"
pe "$H" reconcile >/dev/null 2>&1; sleep 1.2; pe "$H" reconcile >/dev/null 2>&1
assert_equals 1 "$(results "$H")" "the stopped watch produces no further diagnostics"
assert_equals 1 "$(wakes "$H")" "exactly one diagnostic wake"
pass "an unreachable Factory produces one diagnostic and stops the watch"

# --- refused auth: immediate terminal diagnostic --------------------------------
H="$TMP_ROOT/h-auth"; new_home "$H"
FIX="$TMP_ROOT/fx-auth"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
attention "$FIX"
echo 401 > "$FIX/attention.status"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: error" "refused auth is an error result"
assert_contains "$out" "condition_polls: 1" "refused auth stops on the first read"
assert_contains "$out" "HTTP 401" "the diagnostic names the refusal"
assert_contains "$out" "token_file" "the refusal points at the token, not a generic HTTP error"
pass "refused auth stops the watch on the first read"

# --- missing config is refused at arm time ---------------------------------------
H="$TMP_ROOT/h-noconfig"; new_home "$H"
if err=$(factory "$H" arm --project "$PROJECT" 2>&1); then
  fail "arm without config/factory unexpectedly succeeded"
fi
assert_contains "$err" "config/factory" "the refusal names the missing config"
pass "arm refuses without operator config"

# --- preflight ----------------------------------------------------------------------
H="$TMP_ROOT/h-pre"; new_home "$H"
FIX="$TMP_ROOT/fx-pre"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
project_json() {  # <scope> <default-model-json>
  printf '{"project":{"id":"%s","modelScope":"%s","defaultModelId":%s}}\n' "$PROJECT" "$1" "$2" > "$FIX/project.json"
}
printf '{"models":[{"id":"anthropic/claude-sonnet-5-5","provider":"anthropic"}]}\n' > "$FIX/models.json"

project_json factory '"anthropic/claude-sonnet-5-5"'
out=$(factory "$H" preflight --project "$PROJECT"); rc=$?
expect_code 0 "$rc" "a credentialed default model passes"
assert_contains "$out" "usable: anthropic/claude-sonnet-5-5" "the pass names the model"
assert_grep "/web/config/models?factoryId=$PROJECT" "$FIX/requests.log" "admission is read from the project's model catalog"

project_json hybrid '"anthropic/claude-sonnet-5-5"'
factory "$H" preflight --project "$PROJECT" >/dev/null; rc=$?
expect_code 0 "$rc" "a hybrid project resolves to factory scope for runs"

project_json factory '"openai-codex/gpt-5.5"'
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 1 "$rc" "a default model with no credentialed provider fails"
assert_contains "$out" "openai-codex/gpt-5.5" "the failure names the model"
assert_contains "$out" "not in the Factory's credentialed model catalog" "the failure says why"

project_json factory null
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 1 "$rc" "a project with no default model fails"
assert_contains "$out" "no default model" "the failure says there is no default model"

project_json user '"anthropic/claude-sonnet-5-5"'
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "user scope cannot be judged"
assert_contains "$out" "cannot determine" "user scope is reported as undeterminable"

project_json factory '"anthropic/claude-sonnet-5-5"'
rm -f "$FIX/models.json"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "no model catalog cannot be judged"
assert_contains "$out" "exposes no model catalog" "a missing catalog is reported explicitly, not guessed"

configure "$H" "$(closed_port_url)"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "an unreachable Factory cannot be judged"
assert_contains "$out" "unreachable" "preflight names an unreachable Factory"
pass "preflight passes a usable model, fails an unusable one, and reports what it cannot judge"

printf '# all fm-procevent-factory tests passed\n'
