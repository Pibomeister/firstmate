#!/usr/bin/env bash
set -u; WT=$1; EV=$2; cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-factory-fix.XXXXXX")
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/claims FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1
python3 "$EV/mock-factory.py" "$FIX" & SRV=$!
P=ftest-argv
trap 'bin/fm-procevent-factory.sh retire --project $P >/dev/null 2>&1; kill $SRV; rm -rf "$LAB" "$FIX"' EXIT
for _ in $(seq 100); do [ -s "$FIX/port" ] && break; sleep 0.05; done
T=gwsp_argv_probe_9f3c
printf '%s\n' "$T" > "$LAB/config/factory.token"
printf 'url=http://127.0.0.1:%s\ntoken_file=%s\n' "$(cat "$FIX/port")" "$LAB/config/factory.token" > "$LAB/config/factory"
echo '{"items":[],"hasMore":false}' > "$FIX/attention.json"
bin/fm-procevent-factory.sh arm --project $P --interval 0.2 >/dev/null
bin/fm-procevent.sh reconcile >/dev/null 2>&1; hits=0
for _ in $(seq 40); do ps -axww -o pid=,args= > "$LAB/ps.txt"; grep -F "$T" "$LAB/ps.txt" | grep -v -e 'grep -F' >> "$LAB/hits.txt"; sleep 0.1; done
echo "poller running: $(grep -c 'fm-procevent-factory.sh poll' "$LAB/ps.txt")"
echo "curl seen during sampling: $(grep -c . "$FIX/requests.log") requests"
echo "processes whose argv contained the token: $(sort -u "$LAB/hits.txt" | grep -c .)"
sort -u "$LAB/hits.txt" | head
