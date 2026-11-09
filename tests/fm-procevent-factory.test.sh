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
result() { printf '%s/state/procevent-inbox/%s.%s.result\n' "$1" "$SOURCE" "$2"; }
# Distinct wake keys: reconcile re-queues an unacknowledged result by design and
# the watcher delivers once per source and sequence, so the key is the wake.
wakes() {
  awk -F '\t' -v k="procevent:$SOURCE:" 'index($4, k) == 1 { print $4 }' "$1/state/.wake-queue" 2>/dev/null \
    | sort -u | wc -l | tr -d ' '
}
# A result counts once both its capture and its wake landed; publication
# follows capture inside the runner. Reconcile restarts a finished watch.
wait_for_results() {  # <home> <count> [tries]
  local n=${3:-150} i=0
  for _ in $(seq 1 "$n"); do
    [ "$(results "$1")" -ge "$2" ] && [ "$(wakes "$1")" -ge "$2" ] && return 0
    i=$((i + 1))
    [ $((i % 10)) -ne 0 ] || pe "$1" reconcile >/dev/null 2>&1
    sleep 0.1
  done
  return 1
}
item_lines() { grep -c '^item: ' "$1"; }

# --- fake Factory -------------------------------------------------------------
# Serves <fixture>/<route>.json with the HTTP status in <route>.status (200 when
# absent, 404 when the body is absent too). A <route>.seq file scripts the next
# responses first: each line is `<status> [<body-file>]` and is consumed by one
# request. Every request line and its Authorization header are logged.
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
def scripted(name):
    seq = os.path.join(fix, '%s.seq' % name)
    if not os.path.exists(seq):
        return None
    with open(seq) as f:
        lines = [l for l in f.read().splitlines() if l.strip()]
    if not lines:
        return None
    with open(seq, 'w') as f:
        f.write(''.join(l + '\n' for l in lines[1:]))
    fields = lines[0].split()
    body = b''
    if len(fields) > 1:
        with open(os.path.join(fix, fields[1]), 'rb') as b:
            body = b.read()
    return int(fields[0]), body
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(fix, 'requests.log'), 'a') as log:
            log.write('%s auth=%s\n' % (self.path, self.headers.get('Authorization', '')))
        name = route(self.path)
        answer = scripted(name) if name else None
        if answer is None:
            status, body = 404, b'{"error":"not_found"}'
            body_path = os.path.join(fix, '%s.json' % name) if name else None
            status_path = os.path.join(fix, '%s.status' % name) if name else None
            if body_path and os.path.exists(body_path):
                status = 200
                with open(body_path, 'rb') as f:
                    body = f.read()
            if status_path and os.path.exists(status_path):
                with open(status_path) as f:
                    status = int(f.read().strip())
            answer = (status, body)
        status, body = answer
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

item() {  # <decision-uuid> <detail> [failure-code-json]
  printf '{"key":"factory:%s:automation-failed:%s:0","kind":"automation-failed","decisionId":"%s","occurrence":0,"workItemId":"11111111-1111-4111-8111-111111111111","title":"ENG-4357 run","detail":"%s","failureCode":%s,"canRetry":true,"occurredAt":"2026-11-09T15:00:00.000Z","read":false,"archived":false}' \
    "$PROJECT" "$1" "$1" "$2" "${3:-\"dispatch_failed\"}"
}
attention_body() {  # [item-json...]: newest first, as Factory orders them
  local IFS=,
  printf '{"items":[%s],"kinds":{},"hasMore":false}\n' "$*"
}
attention() {  # <fixture-dir> [item-json...]
  local fix=$1
  shift
  attention_body "$@" > "$fix/attention.json"
}

D1=aaaaaaaa-0000-4000-8000-000000000001
D2=aaaaaaaa-0000-4000-8000-000000000002
D3=aaaaaaaa-0000-4000-8000-000000000003
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
assert_grep "view=open" "$FIX/requests.log" "the poll asks only for open items, never archived ones"
pass "poll reports a new automation-failed item with its error text"

# --- a null failure code keeps the error text in its column ---------------------
attention "$FIX" "$(item "$D2" "$ERR1" null)"
H2="$TMP_ROOT/h-null"; new_home "$H2"; configure "$H2" "$URL"
out=$(factory "$H2" poll --project "$PROJECT" --interval 0.05)
printf '%s\n' "$out" > "$TMP_ROOT/null.result"
assert_equals "$ERR1" "$(awk -F '\t' '/^item: / { print $3 }' "$TMP_ROOT/null.result")" "a null failure code leaves the error text in the error column"
assert_contains "$(factory "$H2" summary "$TMP_ROOT/null.result")" "$ERR1" "the summary still carries the error text"
item "$D3" "no timestamp" | jq -c 'del(.occurredAt)' > "$TMP_ROOT/untimed.json"
attention_body "$(cat "$TMP_ROOT/untimed.json")" > "$FIX/attention.json"
H2b="$TMP_ROOT/h-untimed"; new_home "$H2b"; configure "$H2b" "$URL"
factory "$H2b" poll --project "$PROJECT" --interval 0.05 > "$TMP_ROOT/untimed.result"
assert_contains "$(factory "$H2b" summary "$TMP_ROOT/untimed.result")" "failed at unknown time: no timestamp" "a failure without a time says so"
pass "a null failure code keeps the error text in the wake"

# --- other kinds and keyless items never count as failures ----------------------
printf '{"key":"factory:x:mention:1:0","kind":"mention","detail":"not a failure"}' > "$TMP_ROOT/mention.json"
printf '{"kind":"automation-failed","detail":"keyless"}' > "$TMP_ROOT/keyless.json"
attention_body "$(cat "$TMP_ROOT/mention.json")" "$(cat "$TMP_ROOT/keyless.json")" > "$FIX/noise.json"
attention "$FIX" "$(item "$D3" "real failure")"
printf '200 noise.json\n' > "$FIX/attention.seq"
H3="$TMP_ROOT/h-noise"; new_home "$H3"; configure "$H3" "$URL"
out=$(factory "$H3" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "condition_polls: 2" "a response of only other kinds or keyless items reports nothing"
assert_contains "$out" "$D3" "the next real failure is reported"
assert_not_contains "$out" "not a failure" "a non-failure kind is never reported"
assert_not_contains "$out" "keyless" "a keyless item is never reported"
pass "only keyed automation-failed items count as failures"

# --- two new failures at once: the oldest first, one item per result ------------
attention "$FIX" "$(item "$D2" "newer failure")" "$(item "$D1" "older failure")"
H4="$TMP_ROOT/h-two"; new_home "$H4"; configure "$H4" "$URL"
out=$(factory "$H4" poll --project "$PROJECT" --interval 0.05)
printf '%s\n' "$out" > "$TMP_ROOT/two.result"
assert_equals 1 "$(item_lines "$TMP_ROOT/two.result")" "one result carries exactly one failure"
assert_contains "$out" "older failure" "the oldest unreported failure is reported first"
pass "simultaneous failures are reported one per result, oldest first"

# --- more failures than one page: the oldest, on a later page, is still found ---
attention_body "$(item "$D3" "newest failure")" "$(item "$D2" "middle failure")" \
  | jq -c '.hasMore = true | .nextCursor = "cGFnZS10d28"' > "$FIX/page1.json"
attention_body "$(item "$D1" "oldest failure")" > "$FIX/page2.json"
printf '200 page1.json\n200 page2.json\n' > "$FIX/attention.seq"
H5="$TMP_ROOT/h-pages"; new_home "$H5"; configure "$H5" "$URL"
: > "$FIX/requests.log"
out=$(factory "$H5" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "oldest failure" "the oldest failure on a later page is reported first"
assert_contains "$out" "condition_polls: 1" "every page is read within one poll"
assert_grep "before=cGFnZS10d28" "$FIX/requests.log" "the next page is requested with Factory's cursor"
attention_body "$(item "$D1" "x")" | jq -c '.hasMore = true | .nextCursor = "bad cursor!"' > "$FIX/badcursor.json"
printf '200 badcursor.json\n' > "$FIX/attention.seq"
H6="$TMP_ROOT/h-badcursor"; new_home "$H6"; configure "$H6" "$URL"
out=$(factory "$H6" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "malformed attention cursor" "a malformed cursor stops the watch"
attention_body "$(item "$D1" "x")" | jq -c '.hasMore = true' > "$FIX/nocursor.json"
printf '200 nocursor.json\n' > "$FIX/attention.seq"
out=$(factory "$H6" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "malformed attention cursor" "more pages without a cursor stop the watch rather than end the read"
# A server that never stops saying hasMore: the read is bounded, and reaching
# the bound stops the watch loudly instead of silently skipping older failures.
attention_body "$(item "$D3" "endless")" | jq -c '.hasMore = true | .nextCursor = "c2FtZQ"' > "$FIX/attention.json"
H7="$TMP_ROOT/h-cap"; new_home "$H7"; configure "$H7" "$URL"
: > "$FIX/requests.log"
out=$(factory "$H7" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: error" "an inbox past the page bound stops the watch"
assert_contains "$out" "more than 1000 open automation-failed items" "the diagnostic names the bound"
assert_equals 20 "$(grep -c '/attention?' "$FIX/requests.log")" "the read stops at exactly 20 pages"
# An error on a later page discards the whole read: a 503 counts as one failed
# read, and a refused token ends the watch, with nothing reported from page 1.
attention "$FIX" "$(item "$D1" "after the outage")"
printf '200 page1.json\n503\n' > "$FIX/attention.seq"
H8="$TMP_ROOT/h-page2"; new_home "$H8"; configure "$H8" "$URL"
out=$(factory "$H8" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "after the outage" "the next full read reports its own oldest failure"
assert_contains "$out" "condition_polls: 2" "a later-page server error discards the whole read"
assert_not_contains "$out" "newest failure" "nothing from the partial read is reported"
printf '200 page1.json\n401\n' > "$FIX/attention.seq"
out=$(factory "$H8" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "HTTP 401" "a refused later page ends the watch"
assert_contains "$out" "condition_polls: 1" "a refused later page ends the watch at once"
pass "a poll reads every page, bounds the read, and treats a later-page error as a failed read"

# --- end to end: one wake per failure, no repeat --------------------------------
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
assert_contains "$payloads" "procevent factory $SOURCE 1 - Factory automation failed at 2026-11-09T15:00:00.000Z: $ERR1" "the wake reason carries the error text and when it occurred"
assert_equals 1 "$(wakes "$H")" "exactly one wake for one failure"
# The source is not terminal: reconcile restarts it, and the unchanged item
# must not be reported again across polls that demonstrably happened.
before=$(wc -l < "$FIX/requests.log")
for _ in 1 2 3; do pe "$H" reconcile >/dev/null 2>&1; sleep 1.2; done
after=$(wc -l < "$FIX/requests.log")
[ "$after" -gt "$((before + 2))" ] || fail "the watch did not keep polling ($before -> $after requests)"
assert_equals 1 "$(results "$H")" "a repeated item is never captured twice"
assert_present "$H/state/procevent/$SOURCE.source" "a failure result keeps the watch armed"
# Two more failures at once (one with a hostile control sequence) wake once each.
attention "$FIX" "$(item "$D3" 'third failure')" "$(item "$D2" 'second failure\u001b[31m text')" "$(item "$D1" "$ERR1")"
wait_for_results "$H" 3 300 || fail "two later failures were not each captured"
assert_equals 1 "$(item_lines "$(result "$H" 2)")" "the second result carries one failure"
assert_equals 1 "$(item_lines "$(result "$H" 3)")" "the third result carries one failure"
assert_grep "$D2" "$(result "$H" 2)" "the older of the two new failures comes first"
assert_grep "$D3" "$(result "$H" 3)" "the newer failure follows"
assert_no_grep "$D1" "$(result "$H" 2)" "a later result never repeats an earlier failure"
payloads=$(wake_payloads "$H")
assert_contains "$payloads" "second failure[31m text" "the second wake carries its own error text"
assert_contains "$payloads" "third failure" "the third wake carries its own error text"
printf '%s\n' "$payloads" | LC_ALL=C grep -q "$(printf '\033')" && fail "a control character from Factory reached the wake queue"
assert_contains "$(factory "$H" classify "$(result "$H" 2)")" failed "classify reads a failure result"
factory "$H" terminal "$(result "$H" 2)" && fail "a failure result must not end the watch"
assert_equals 3 "$(wakes "$H")" "one wake per failure"
factory "$H" retire --project "$PROJECT" >/dev/null
pass "every failure wakes exactly once with its own error text, and a repeat never does"

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
assert_contains "$(wake_payloads "$H")" "Factory watch stopped: Factory at" "the diagnostic wake says why the watch stopped"
pass "an unreachable Factory produces one diagnostic and stops the watch"

# --- server errors: 5xx is transient, a good read resets the count ----------------
H="$TMP_ROOT/h-5xx"; new_home "$H"
FIX="$TMP_ROOT/fx-5xx"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
attention_body > "$FIX/empty.json"
attention "$FIX" "$(item "$D1" "$ERR1")"
printf '500\n200 empty.json\n500\n502\n' > "$FIX/attention.seq"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: failed" "a good read between server errors resets the failure count"
assert_contains "$out" "condition_polls: 5" "two errors after a good read are still tolerated"
printf '503\n503\n503\n' > "$FIX/attention.seq"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: error" "three consecutive server errors stop the watch"
assert_contains "$out" "condition_polls: 3" "server errors count as unreachable reads"
assert_contains "$out" "HTTP 503" "the diagnostic names the last server error"
pass "server errors are tolerated until three in a row, and a good read resets the count"

# --- refused auth, unexpected status, malformed and empty bodies -----------------
H="$TMP_ROOT/h-auth"; new_home "$H"
FIX="$TMP_ROOT/fx-auth"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
attention "$FIX"
for code in 401 403; do
  echo "$code" > "$FIX/attention.status"
  out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
  assert_contains "$out" "status: error" "refused auth ($code) is an error result"
  assert_contains "$out" "condition_polls: 1" "refused auth ($code) stops on the first read"
  assert_contains "$out" "HTTP $code" "the diagnostic names the refusal ($code)"
  assert_contains "$out" "token_file" "the refusal ($code) points at the token, not a generic HTTP error"
done
echo 404 > "$FIX/attention.status"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "condition_polls: 1" "an unexpected status stops on the first read"
assert_contains "$out" "HTTP 404" "the diagnostic names the unexpected status"
printf '{"error":"x"}' > "$FIX/attention.json"; : > "$FIX/blank.json"
printf '200\n' > "$FIX/attention.status"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "malformed attention response" "a body without items is malformed, not an empty inbox"
printf '200 blank.json\n' > "$FIX/attention.seq"
out=$(factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "malformed attention response" "an empty body is malformed, not an empty inbox"
assert_contains "$out" "condition_polls: 1" "a malformed body stops on the first read"
pass "refused auth, unexpected statuses, and malformed or empty bodies stop the watch at once"

# --- the token never reaches a command line, and a host .curlrc is ignored --------
H="$TMP_ROOT/h-argv"; new_home "$H"
FIX="$TMP_ROOT/fx-argv"; URL=$(start_factory "$FIX")
configure "$H" "$URL"
attention "$FIX" "$(item "$D1" "$ERR1")"
printf '{"project":{"id":"%s","modelScope":"factory","defaultModelId":"m/one"}}\n' "$PROJECT" > "$FIX/project.json"
printf '{"models":[{"id":"m/one"}]}\n' > "$FIX/models.json"
WRAP="$TMP_ROOT/curl-wrap"; mkdir -p "$WRAP"
REAL_CURL=$(command -v curl)
cat > "$WRAP/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/curl-argv.log"
exec "$REAL_CURL" "\$@"
SH
chmod +x "$WRAP/curl"
CURLRC="$TMP_ROOT/curlrc"; mkdir -p "$CURLRC"
printf 'proxy = "http://127.0.0.1:9"\n' > "$CURLRC/.curlrc"
out=$(PATH="$WRAP:$PATH" CURL_HOME="$CURLRC" factory "$H" poll --project "$PROJECT" --interval 0.05)
assert_contains "$out" "status: failed" "a host .curlrc with a dead proxy does not divert the poll"
PATH="$WRAP:$PATH" CURL_HOME="$CURLRC" factory "$H" preflight --project "$PROJECT" >/dev/null \
  || fail "a host .curlrc with a dead proxy diverted the preflight"
assert_present "$TMP_ROOT/curl-argv.log" "curl was never invoked through the wrapper"
assert_no_grep "$TOKEN" "$TMP_ROOT/curl-argv.log" "the token appeared on a curl command line"
pass "the token never reaches a command line and a host .curlrc is ignored"

# --- config refusals ---------------------------------------------------------------
H="$TMP_ROOT/h-noconfig"; new_home "$H"
if err=$(factory "$H" arm --project "$PROJECT" 2>&1); then
  fail "arm without config/factory unexpectedly succeeded"
fi
assert_contains "$err" "config/factory" "the refusal names the missing config"
printf 'url=https://user:secret@factory.example\n' > "$H/config/factory"
if err=$(factory "$H" arm --project "$PROJECT" 2>&1); then
  fail "arm with credentials in the URL unexpectedly succeeded"
fi
assert_contains "$err" "must not embed credentials" "a credential-bearing URL is refused"
pass "arm refuses missing config and a URL that embeds credentials"

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

printf '{"project":{"id":"%s","defaultModelId":"anthropic/claude-sonnet-5-5"}}\n' "$PROJECT" > "$FIX/project.json"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "a project without a model scope cannot be judged"
assert_contains "$out" "exposes no modelScope" "a missing scope is reported explicitly"

project_json factory '"anthropic/claude-sonnet-5-5"'
printf '{"providers":[]}\n' > "$FIX/models.json"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "a catalog answer without models cannot be judged"
assert_contains "$out" "exposes no model catalog" "a 200 without a models array is reported explicitly, not as unusable"
rm -f "$FIX/models.json"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "no model catalog cannot be judged"
assert_contains "$out" "exposes no model catalog" "a missing catalog is reported explicitly, not guessed"

echo 404 > "$FIX/project.status"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 1 "$rc" "an unknown project is not usable"
assert_contains "$out" "not found" "the failure says the project was not found"
echo 401 > "$FIX/project.status"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "a refused project read cannot be judged"
assert_contains "$out" "HTTP 401" "the refusal is named"

configure "$H" "$(closed_port_url)"
out=$(factory "$H" preflight --project "$PROJECT" 2>&1); rc=$?
expect_code 3 "$rc" "an unreachable Factory cannot be judged"
assert_contains "$out" "unreachable" "preflight names an unreachable Factory"
pass "preflight passes a usable model, fails an unusable one, and reports what it cannot judge"

printf '# all fm-procevent-factory tests passed\n'
