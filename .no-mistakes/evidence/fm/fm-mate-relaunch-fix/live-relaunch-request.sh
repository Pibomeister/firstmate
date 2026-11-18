#!/usr/bin/env bash
# Live drive of bin/fm-handoff-relaunch.sh across two disposable lab homes.
set -u
W=$1
P=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); C=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$W/bin/fm-lab-home.sh" create "$P" >/dev/null; "$W/bin/fm-lab-home.sh" create "$C" >/dev/null
mkdir -p "$P/state" "$C/state" "$C/data"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$C/.fm-secondmate-parent"
printf 'sm-lab\n' > "$C/.fm-secondmate-home"
ST="$P/state/sm-lab.status"
run() { local h=$1; shift; env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$h" "$@"; }
openset() { bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" secondmate' _ "$W" "$ST" 2>/dev/null; }
echo "### S1 incident shape: mate asks in ordinary status prose"
printf 'working [at=1]: handoff written; please relaunch me once\n' >> "$ST"
echo "parent open decisions: [$(openset)]"
echo "### S2 primary (non-secondmate) home refuses the request"
printf '# Handoff\n' > "$P/handoff.md"
run "$P" "$W/bin/fm-handoff-relaunch.sh" request "$P/handoff.md"; echo "exit=$?"
echo "### S3 handoff that omits an open captain order is refused, nothing published"
oid=$(run "$C" "$W/bin/fm-order.sh" send --from lab -- "ship the top goal" 2>&1 | tail -1); echo "order send: $oid"
run "$C" "$W/bin/fm-order.sh" pickup >/dev/null 2>&1
printf '# Handoff\nnothing about orders\n' > "$C/data/handoff.md"
run "$C" "$W/bin/fm-handoff-relaunch.sh" request "$C/data/handoff.md"; echo "exit=$?"
echo "parent status lines with key: $(grep -c 'key=handoff-relaunch' "$ST")"
echo "request record exists: $([ -e "$C/state/.handoff-relaunch-request" ] && echo yes || echo no)"
echo "### S4 handoff written through fm-order handoff, request succeeds and is durable"
rm -rf "$C/data/orders"
printf '# Handoff\nResume the top goal.\n' > "$C/data/handoff.md"
t0=$(date +%s)
run "$C" "$W/bin/fm-handoff-relaunch.sh" request "$C/data/handoff.md"; echo "exit=$?"
run "$C" "$W/bin/fm-handoff-relaunch.sh" request "$C/data/handoff.md"; echo "repeat exit=$?"
echo "parent keyed blocker lines: $(grep -c '^blocked \[key=handoff-relaunch\]' "$ST")"
grep '^blocked \[key=handoff-relaunch\]' "$ST"
echo "parent open decisions: [$(openset)]"
run "$C" "$W/bin/fm-handoff-relaunch.sh" requested "$t0"; echo "requested since t0 exit=$?"
echo "### S5 later unrelated status keeps it open"
printf 'done [at=2]: corr=abc reply delivered\n' >> "$ST"
echo "parent open decisions: [$(openset | cut -f1)]"
echo "### S6 parent closes after relaunch; second close is a no-op"
run "$P" "$W/bin/fm-handoff-relaunch.sh" close sm-lab 'bin/fm-control.sh relaunch'; echo "exit=$?"
run "$P" "$W/bin/fm-handoff-relaunch.sh" close sm-lab 'bin/fm-control.sh relaunch'; echo "exit=$?"
echo "resolved lines: $(grep -c '^resolved \[key=handoff-relaunch\]' "$ST")"
echo "parent open decisions: [$(openset)]"
echo "### final parent status file"
cat "$ST"
rm -rf "$P" "$C"
