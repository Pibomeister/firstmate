#!/usr/bin/env bash
# Live lab-home scenarios for fm/fm-mate-relaunch-fix. Run from the run worktree.
set -u
ROOT=$PWD
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
trap 'kill $HOLDER 2>/dev/null; rm -rf "$LAB"' EXIT
HOLDER=
PARENT="$LAB/parent"; MATE="$LAB/mate"
bin/fm-lab-home.sh create "$PARENT" >/dev/null; bin/fm-lab-home.sh create "$MATE" >/dev/null
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"
printf 'sm-lab\n' > "$MATE/.fm-secondmate-home"
mkdir -p "$MATE/bin" "$MATE/.claude"; git init -q "$MATE"; git -C "$MATE" commit -q --allow-empty -m init; : > "$MATE/AGENTS.md"
CH="$LAB/claude"; mkdir -p "$CH"
STATUS="$PARENT/state/sm-lab.status"
open_req() { bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" secondmate' _ "$ROOT" "$STATUS" | grep '^handoff-relaunch' || true; }
hook() { jq -nc --arg s s1 --arg t "$LAB/t.jsonl" --arg e "$1" '{session_id:$s,transcript_path:$t,hook_event_name:$e,tool_name:"Bash"}' \
  | env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    FM_ROOT_OVERRIDE="$MATE" CLAUDE_CONFIG_DIR="$CH" CLAUDE_PROJECT_DIR="$MATE" bash "$ROOT/bin/fm-handoff-trigger.sh"; }

echo "=== S1: second mate fresh-start firing, then Stop is blocked until a durable relaunch request exists"
printf 'compact-at-tokens=100000\nfresh-start-after=0\n' > "$MATE/config/handoff-trigger"
{ printf '{"type":"user","message":{"content":"hi"}}\n'; jq -nc '{type:"assistant",message:{model:"claude-test-model",usage:{input_tokens:2,cache_read_input_tokens:88998,cache_creation_input_tokens:1000,output_tokens:50}}}'; } > "$LAB/t.jsonl"
out=$(hook PostToolUse); echo "firing instruction (excerpt): $(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext | grep -o 'This is a second mate.*')"
echo "-- incident shape: mate asks in ordinary status prose"
printf 'working [at=1]: handoff written; please relaunch me once\n' >> "$STATUS"
echo "parent open relaunch request after prose: '$(open_req)'"
hook Stop >/dev/null 2>"$LAB/err"; echo "Stop rc=$? (expect 2) msg: $(cat "$LAB/err")"
echo "-- mate runs the request command"
printf '# Handoff\nnothing open\n' > "$MATE/data/handoff.md"
FM_HOME="$MATE" bin/fm-order.sh handoff --doc "$MATE/data/handoff.md" >/dev/null 2>&1
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$MATE" bin/fm-handoff-relaunch.sh request "$MATE/data/handoff.md"; echo "request rc=$?"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$MATE" bin/fm-handoff-relaunch.sh request "$MATE/data/handoff.md" >/dev/null; echo "repeat request rc=$?"
echo "parent status file:"; cat "$STATUS"
echo "parent open relaunch request: $(open_req)"
hook Stop >/dev/null 2>&1; echo "Stop rc=$? (expect 0)"

echo "=== S2: unrelated later report leaves request open; lifecycle close resolves it once"
printf 'done [at=2]: corr=abc reply delivered\n' >> "$STATUS"
echo "after done line, open: '$(open_req | cut -c1-40)'"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$PARENT" bin/fm-handoff-relaunch.sh close sm-lab 'bin/fm-control.sh relaunch'; echo "close rc=$?"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$PARENT" bin/fm-handoff-relaunch.sh close sm-lab 'bin/fm-control.sh relaunch'; echo "second close rc=$?"
echo "open after close: '$(open_req)'; resolved lines: $(grep -c '^resolved \[key=handoff-relaunch\]' "$STATUS")"

echo "=== S3: another lifecycle action holds the mate's control lock -> fresh --secondmate spawn and remote relaunch refuse"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" && echo held; sleep 300' _ "$ROOT" "$PARENT/state/.control-sm-lab.lock" & HOLDER=$!
sleep 2; echo "holder pid=$HOLDER lock pid=$(cat "$PARENT/state/.control-sm-lab.lock/pid" 2>/dev/null)"
printf 'kind=secondmate\nharness=claude\nremote_host=lab-fake-host\nwindow=remote:sm-lab\n' > "$PARENT/state/sm-lab.meta"
cp "$PARENT/state/sm-lab.meta" "$LAB/meta.before"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$PARENT" bin/fm-remote-secondmate-relaunch.sh sm-lab claude default default 2>&1 | tail -3; echo "remote relaunch rc=${PIPESTATUS[0]} (expect 5)"
cmp -s "$LAB/meta.before" "$PARENT/state/sm-lab.meta" && echo "parent record untouched: yes"
rm -f "$PARENT/state/sm-lab.meta"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$PARENT" bin/fm-spawn.sh sm-lab --secondmate 2>&1 | tail -3; echo "fresh secondmate spawn rc=${PIPESTATUS[0]} (expect refusal)"
ls "$PARENT/state" | grep -c '^sm-lab.meta$' | sed 's/^/records for sm-lab after refusal: /'
kill $HOLDER; wait $HOLDER 2>/dev/null; HOLDER=
echo "=== done"
