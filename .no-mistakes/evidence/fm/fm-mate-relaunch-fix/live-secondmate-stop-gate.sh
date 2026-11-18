#!/usr/bin/env bash
# Live drive of the real Claude hook bin/fm-handoff-trigger.sh in a disposable
# second-mate lab home: a planned fresh start blocks the mate's Stop until
# bin/fm-handoff-relaunch.sh request records a durable relaunch request.
set -u
W=$1
P=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); C=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
CC=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-claude.XXXXXX")
trap 'rm -rf "$P" "$C" "$CC"' EXIT
"$W/bin/fm-lab-home.sh" create "$P" >/dev/null; "$W/bin/fm-lab-home.sh" create "$C" >/dev/null
mkdir -p "$P/state" "$C/state" "$C/data" "$C/config"
: > "$C/AGENTS.md"; mkdir -p "$C/bin"   # a real second-mate home is a firstmate clone
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$C/.fm-secondmate-parent"
printf 'sm-lab\n' > "$C/.fm-secondmate-home"
printf 'compact-at-tokens=100000\nfresh-start-after=0\n' > "$C/config/handoff-trigger"
ST="$P/state/sm-lab.status"; T="$C/transcript.jsonl"
{ printf '{"type":"user","message":{"content":"hi"}}\n'
  jq -nc '{type:"assistant",message:{model:"claude-lab",usage:{input_tokens:2,cache_read_input_tokens:88998,cache_creation_input_tokens:1000,output_tokens:50}}}'; } > "$T"
hook() { # <event> [jq-extra]
  jq -nc --arg t "$T" --arg e "$1" '{session_id:"s-lab",transcript_path:$t,hook_event_name:$e,tool_name:"Bash"}' | jq -c "${2:-.}" \
  | env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    FM_HOME="$C" FM_ROOT_OVERRIDE="$C" CLAUDE_CONFIG_DIR="$CC" CLAUDE_PROJECT_DIR="$C" bash "$W/bin/fm-handoff-trigger.sh"; }
rel() { local h=$1; shift; env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$h" "$W/bin/fm-handoff-relaunch.sh" "$@"; }
openset() { bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" secondmate' _ "$W" "$ST" 2>/dev/null | cut -f1,2; }
echo "### 1. 90k of 100k tokens: PostToolUse fires a planned fresh start for the second mate"
out=$(hook PostToolUse); echo "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -o 'This is a second mate.*'
echo "### 2. incident shape: mate writes relaunch ask as ordinary status prose, then tries to stop"
printf '# Handoff\nResume the top goal.\n' > "$C/data/handoff.md"
printf 'working [at=1]: handoff written to %s; please relaunch me once\n' "$C/data/handoff.md" >> "$ST"
echo "parent open decisions: [$(openset)]"
hook Stop >/dev/null 2>"$C/err"; echo "Stop exit=$? (2 = blocked)"; echo "stderr: $(cat "$C/err")"
echo "### 3. same turn, stop_hook_active (already blocked once): stop allowed, never wedges"
hook Stop '. + {stop_hook_active:true}' >/dev/null 2>&1; echo "Stop exit=$?"
echo "### 4. adversarial: a stale request record from before this firing does not clear the gate"
printf 'at=1 handoff=%s sha256=0\n' "$C/data/handoff.md" > "$C/state/.handoff-relaunch-request"
hook Stop >/dev/null 2>&1; echo "Stop exit=$? (2 = still blocked)"
rm -f "$C/state/.handoff-relaunch-request"
echo "### 5. mate runs the request command"
rel "$C" request "$C/data/handoff.md"; echo "request exit=$?"
echo "parent open decisions: [$(openset)]"
hook Stop >/dev/null 2>&1; echo "Stop exit=$? (0 = released)"
echo "### parent status file"; cat "$ST"
