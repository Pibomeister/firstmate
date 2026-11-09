#!/usr/bin/env bash
# Live driver: real fm-procevent-factory.sh + fm-procevent.sh runner + wake drain
# against the fake Factory, inside a disposable lab home. Run from the gate worktree.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
WT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
FIX="$LAB/fake"; mkdir -p "$FIX"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -I "$EV/fake_factory.py" "$FIX" "$PORT" & SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "fm-procevent-factory.sh poll --project tktest" 2>/dev/null; rm -rf "$LAB"' EXIT
sleep 1
printf 'tok-ABCsecret123\n' > "$LAB/config/factory-token"; chmod 600 "$LAB/config/factory-token"
printf 'url=http://127.0.0.1:%s\ntoken_file=%s\n' "$PORT" "$LAB/config/factory-token" > "$LAB/config/factory"
P=tktest
step() { printf '\n===== %s =====\n' "$*"; }

step "S1 preflight: default model whose provider has no credential (the Nov 9 ProviderAuthRequiredError shape)"
printf '{"project":{"id":"%s","modelScope":"hybrid","defaultModelId":"anthropic/claude-sonnet-5-5"}}' $P > "$FIX/project.json"
printf '{"models":[{"id":"openai/gpt-x"}]}' > "$FIX/models.json"
bin/fm-procevent-factory.sh preflight --project $P; echo "exit=$?"
step "S1b preflight: model credentialed"
printf '{"models":[{"id":"openai/gpt-x"},{"id":"anthropic/claude-sonnet-5-5"}]}' > "$FIX/models.json"
bin/fm-procevent-factory.sh preflight --project $P; echo "exit=$?"
step "S1c preflight: no default model"
printf '{"project":{"id":"%s","modelScope":"factory","defaultModelId":null}}' $P > "$FIX/project.json"
bin/fm-procevent-factory.sh preflight --project $P; echo "exit=$?"
step "S1d preflight: per-user scope cannot be judged"
printf '{"project":{"id":"%s","modelScope":"user","defaultModelId":"x"}}' $P > "$FIX/project.json"
bin/fm-procevent-factory.sh preflight --project $P; echo "exit=$?"

step "S2 arm the watch, run the real runner, inject a ProviderAuthRequiredError failure"
printf '{"items":[],"kinds":{},"hasMore":false}' > "$FIX/attention.json"
bin/fm-procevent-factory.sh arm --project $P --interval 1; echo "arm exit=$?"
bin/fm-procevent.sh list
( bin/fm-procevent.sh start factory-$P > "$LAB/runner1.log" 2>&1 ) & R1=$!
sleep 3
echo "runner still waiting on empty inbox: $(kill -0 $R1 2>/dev/null && echo yes || echo no)"
cat > "$FIX/attention.json" <<J
{"items":[{"kind":"automation-failed","key":"automation-failed:run-101","failureCode":"ProviderAuthRequiredError","detail":"ProviderAuthRequiredError: provider anthropic requires authentication","occurredAt":"2026-11-09T09:00:20Z"}],"kinds":{},"hasMore":false}
J
wait $R1; echo "runner exit=$?"
echo "--- captured result:"; cat "$LAB"/state/procevent/inbox/factory-$P.*.result 2>/dev/null || find "$LAB/state" -name "factory-$P*.result" -exec cat {} \;
echo "--- wake drain:"; bin/fm-wake-drain.sh 2>&1 | grep -E "procevent|Factory|check" | head -10

step "S3 dedup + second failure: an already-reported failure does not wake again; a new one does"
( bin/fm-procevent.sh start factory-$P > "$LAB/runner2.log" 2>&1 ) & R2=$!
sleep 3
echo "runner still waiting (run-101 already reported, no new wake): $(kill -0 $R2 2>/dev/null && echo yes || echo no)"
cat > "$FIX/attention.json" <<J
{"items":[{"kind":"automation-failed","key":"automation-failed:run-102","failureCode":"ProviderAuthRequiredError","detail":"second ticket also needs auth","occurredAt":"2026-11-09T09:00:41Z"},{"kind":"automation-failed","key":"automation-failed:run-101","failureCode":"ProviderAuthRequiredError","detail":"ProviderAuthRequiredError: provider anthropic requires authentication","occurredAt":"2026-11-09T09:00:20Z"}],"kinds":{},"hasMore":false}
J
wait $R2; echo "runner exit=$?"
echo "--- wake drain:"; bin/fm-wake-drain.sh 2>&1 | grep -E "procevent|Factory" | head -10

step "S4 adversarial: Factory refuses auth (401) -> one terminal wake, registration retired"
touch "$FIX/status401"
( bin/fm-procevent.sh start factory-$P > "$LAB/runner3.log" 2>&1 ) & R3=$!
wait $R3; echo "runner exit=$?"
echo "--- wake drain:"; bin/fm-wake-drain.sh 2>&1 | grep -E "procevent|Factory" | head -10
echo "--- registrations after terminal error:"; bin/fm-procevent.sh list

step "S5 token never on argv; auth header sent"
grep -c "auth=Bearer tok-ABCsecret123" "$FIX/requests.log" | sed 's/^/requests carrying bearer: /'
grep -rl "tok-ABCsecret123" "$LAB/state" 2>/dev/null | sed 's/^/TOKEN LEAKED INTO STATE: /' || true
echo "token in state files: $(grep -rl tok-ABCsecret123 "$LAB/state" 2>/dev/null | wc -l | tr -d ' ')"
