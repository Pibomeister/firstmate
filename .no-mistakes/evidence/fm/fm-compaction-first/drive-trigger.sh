#!/usr/bin/env bash
# Live CLI drive of bin/fm-handoff-trigger.sh against a disposable lab home.
set -u
W=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M71SVRQHVVKF6D5FRHPKV2CB
HOOK=$W/bin/fm-handoff-trigger.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git init -q "$LAB"; git -C "$LAB" commit -q --allow-empty -m init; : > "$LAB/AGENTS.md"; mkdir -p "$LAB/.claude" "$LAB/bin"
CH=$(mktemp -d); trap 'rm -rf "$LAB" "$CH"' EXIT
printf 'compact-at-tokens=100000\n' > "$LAB/config/handoff-trigger"
tx() { { printf '{"type":"user","message":{"content":"hi"}}\n'; usage "$2"; } > "$1"; }
usage() { jq -nc --argjson t "$1" '{type:"assistant",message:{model:"claude-test-model",usage:{input_tokens:2,cache_read_input_tokens:($t-1002),cache_creation_input_tokens:1000,output_tokens:50}}}'; }
boundary() { printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n' >> "$1"; }
hook() { jq -nc --arg s "$1" --arg t "$2" --arg e "${3:-PostToolUse}" '{session_id:$s,transcript_path:$t,hook_event_name:$e,tool_name:"Bash",stop_hook_active:false}' \
  | env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u NO_MISTAKES_GATE \
    FM_ROOT_OVERRIDE="$LAB" CLAUDE_CONFIG_DIR="$CH" CLAUDE_PROJECT_DIR="$LAB" bash "$HOOK"; echo "[exit=$?]" >&2; }
T=$LAB/t.jsonl
echo "### S1a: 16% left (84000/100000), cycle 0 -> expect silence"; tx "$T" 84000; hook sA "$T"
echo; echo "### S1b: 15% left (85000/100000), cycle 0 -> expect CAPTURE step, no successor launch"; usage 85000 >> "$T"; hook sA "$T" | tee /tmp/fmtest-drv/capture.out
echo; echo "marker:"; cat "$LAB"/state/.handoff-trigger.sA.*; echo "compact-point:"; cat "$LAB/state/compact-point"
echo; echo "### S1c: Stop after a capture firing with NO successor -> expect exit 0, no block"; hook sA "$T" Stop 2>&1
echo; echo "### S1d: second PostToolUse in same cycle -> silent (once per cycle)"; hook sA "$T"
echo; echo "### S3: after 1 compaction, deep again -> capture re-arms, mentions drain + fm-crew-state, 'Compactions so far: 1'"; boundary "$T"; usage 40000 >> "$T"; hook sA "$T"; usage 90000 >> "$T"; hook sA "$T" | jq -r .hookSpecificOutput.additionalContext
echo; echo "### S4a: drift cap - 4 compaction boundaries, deep -> PLANNED FRESH START"; for i in 2 3 4; do boundary "$T"; usage 40000 >> "$T"; done; usage 90000 >> "$T"; hook sA "$T" | jq -r .hookSpecificOutput.additionalContext | tee /tmp/fmtest-drv/fresh.out
echo; echo "compact-point:"; cat "$LAB/state/compact-point"
echo; echo "### S4b: Stop after fresh-start firing with no successor -> expect block (exit 2)"; hook sA "$T" Stop 2>&1
echo; echo "### S4c: early signal - session with 1 compaction but first reading after it at 140000 of compact-at 200000"
printf 'compact-at-tokens=200000\n' > "$LAB/config/handoff-trigger"; T2=$LAB/t2.jsonl; tx "$T2" 50000; boundary "$T2"; usage 140000 >> "$T2"; usage 175000 >> "$T2"; hook sB "$T2" | jq -r .hookSpecificOutput.additionalContext | head -c 400; echo
echo; echo "### S4d: same but first reading after compaction 120000 (<135K) -> capture"
T3=$LAB/t3.jsonl; tx "$T3" 50000; boundary "$T3"; usage 120000 >> "$T3"; usage 175000 >> "$T3"; hook sC "$T3" | jq -r .hookSpecificOutput.additionalContext | head -c 200; echo
