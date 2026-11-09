#!/usr/bin/env bash
# Live driver: real bin/fm-procevent-factory.sh + bin/fm-procevent.sh + bin/fm-wake-drain.sh
# against a disposable lab home and a local mock Factory.
set -u
WT=$1; EV=$2
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-factory-fix.XXXXXX")
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/claims FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
python3 "$EV/mock-factory.py" "$FIX" & SRV=$!
cleanup() { bin/fm-procevent-factory.sh retire --project $P >/dev/null 2>&1; kill $SRV 2>/dev/null; pkill -f "fm-procevent-factory.sh poll --project $P" 2>/dev/null; rm -rf "$LAB" "$FIX"; }
P=ftest-nov9
trap cleanup EXIT
for _ in $(seq 100); do [ -s "$FIX/port" ] && break; sleep 0.05; done
URL=http://127.0.0.1:$(cat "$FIX/port")
TOKEN=gwsp_lab_fixture_token_value
printf '%s\n' "$TOKEN" > "$LAB/config/factory.token"; chmod 600 "$LAB/config/factory.token"
printf 'url=%s\ntoken_file=%s\n' "$URL" "$LAB/config/factory.token" > "$LAB/config/factory"
hdr() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

hdr "S1 preflight: Nov 9 shape - default model set, provider has no credential in catalog"
echo '{"project":{"id":"ftest-nov9","modelScope":"hybrid","defaultModelId":"anthropic/claude-opus"}}' > "$FIX/project.json"
echo '{"models":[{"id":"openai/gpt-5"}]}' > "$FIX/models.json"
run bin/fm-procevent-factory.sh preflight --project $P
hdr "S1b preflight: no default model"
echo '{"project":{"id":"ftest-nov9","modelScope":"factory","defaultModelId":null}}' > "$FIX/project.json"
run bin/fm-procevent-factory.sh preflight --project $P
hdr "S1c preflight: credentialed default model (healthy)"
echo '{"project":{"id":"ftest-nov9","modelScope":"factory","defaultModelId":"anthropic/claude-opus"}}' > "$FIX/project.json"
echo '{"models":[{"id":"anthropic/claude-opus"}]}' > "$FIX/models.json"
run bin/fm-procevent-factory.sh preflight --project $P
hdr "S1d preflight: user scope -> cannot determine; token refused -> cannot determine"
echo '{"project":{"id":"ftest-nov9","modelScope":"user","defaultModelId":"x"}}' > "$FIX/project.json"
run bin/fm-procevent-factory.sh preflight --project $P
echo 401 > "$FIX/project.status"
run bin/fm-procevent-factory.sh preflight --project $P
rm -f "$FIX/project.status"

item() { printf '{"key":"factory:%s:automation-failed:%s:0","kind":"automation-failed","failureCode":"dispatch_failed","detail":"%s","occurredAt":"%s"}' "$P" "$1" "$2" "$3"; }
waitwakes() { for i in $(seq 300); do n=$(awk -F '\t' -v k="procevent:factory-$P:" 'index($4,k)==1 && substr($4,length(k)+1) ~ /^[0-9]+$/ {print $4}' "$LAB/state/.wake-queue" 2>/dev/null | sort -u | wc -l | tr -d ' '); [ "$n" -ge "$1" ] && return 0; [ $((i%10)) -eq 0 ] && bin/fm-procevent.sh reconcile >/dev/null 2>&1; sleep 0.1; done; return 1; }

hdr "S2 arm watch; no failures yet -> no wake"
echo '{"items":[],"hasMore":false}' > "$FIX/attention.json"
run bin/fm-procevent-factory.sh arm --project $P --interval 1
sleep 3; bin/fm-procevent.sh reconcile >/dev/null 2>&1
echo "factory wakes queued: $(grep -c "procevent:factory-$P" "$LAB/state/.wake-queue" 2>/dev/null || echo 0)"
echo "token present in registration record? $(grep -rl "$TOKEN" "$LAB/state/procevent" 2>/dev/null | wc -l | tr -d ' ') files"

hdr "S3 a run hits ProviderAuthRequiredError ~20s after start -> supervision wake"
printf '{"items":[%s],"hasMore":false}' "$(item d1 'ProviderAuthRequiredError: provider anthropic requires authentication' 2026-11-09T15:00:20Z)" > "$FIX/attention.json"
waitwakes 1 && echo "wake observed" || echo "NO WAKE within 30s"
echo "--- what supervision sees (bin/fm-wake-drain.sh) ---"
bin/fm-wake-drain.sh 2>&1 | grep -i -E "factory|procevent" | head -5

hdr "S4 same open item stays open -> no duplicate wake; second failure -> its own wake"
sleep 4; bin/fm-procevent.sh reconcile >/dev/null 2>&1; sleep 3
echo "distinct factory wakes after waiting with the same open item: $(awk -F '\t' -v k="procevent:factory-$P:" 'index($4,k)==1 && substr($4,length(k)+1) ~ /^[0-9]+$/ {print $4}' "$LAB/state/.wake-queue" | sort -u | wc -l | tr -d ' ')"
printf '{"items":[%s,%s],"hasMore":false}' "$(item d2 'ProviderAuthRequiredError: second ticket' 2026-11-09T15:00:41Z)" "$(item d1 'ProviderAuthRequiredError: provider anthropic requires authentication' 2026-11-09T15:00:20Z)" > "$FIX/attention.json"
waitwakes 2 && echo "second wake observed" || echo "NO SECOND WAKE"
awk -F '\t' -v k="procevent:factory-$P:" 'index($4,k)==1 {print $4 " | " $5}' "$LAB/state/.wake-queue" | sort -u

hdr "S5 adversarial: Factory refuses the token (401) -> one terminal error wake, watch stops"
echo 401 > "$FIX/attention.status"
waitwakes 3 && echo "third wake observed" || echo "NO ERROR WAKE"
sleep 4; bin/fm-procevent.sh reconcile >/dev/null 2>&1; sleep 3
awk -F '\t' -v k="procevent:factory-$P:" 'index($4,k)==1 && substr($4,length(k)+1) ~ /^[0-9]+$/ {print $4 " | " $5}' "$LAB/state/.wake-queue" | sort -u
echo "poller processes still running: $(pgrep -f "fm-procevent-factory.sh poll --project $P" | wc -l | tr -d ' ')"
for r in "$LAB"/state/procevent-inbox/factory-$P.*.result; do echo "-- $(basename "$r") classify=$(bin/fm-procevent-factory.sh classify "$r")"; cat "$r"; done
echo "--- request log: auth header ---"; sort "$FIX/requests.log" | awk '{print $2}' | sort | uniq -c
echo "token on any process argv? $(ps -axo args | grep -c "$TOKEN" | awk '{print $1-1}')"
