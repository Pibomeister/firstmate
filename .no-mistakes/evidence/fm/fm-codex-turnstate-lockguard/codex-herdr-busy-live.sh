#!/usr/bin/env bash
# Live check: a real Codex TUI in an isolated Herdr lab pane, classified by
# fm_busy_classify from the run worktree. Its turn-ended marker is written by
# codex's own notify= program, the same shape fm-spawn launches.
set -u
ROOT=$1
LABH="$ROOT/bin/fm-herdr-lab.sh"
L=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-codex-busy.XXXXXX")
S=$("$LABH" name fm-codex-busy)
cleanup() { "$LABH" teardown "$S" >/dev/null 2>&1; echo "# teardown $S rc=$?"; rm -rf "$L"; }
trap cleanup EXIT
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

mkdir -p "$L/state" "$L/codex-home" "$L/work"
cp "$HOME/.codex/config.toml" "$HOME/.codex/auth.json" "$L/codex-home/"
git -C "$L/work" init -q
printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$L/work" >> "$L/codex-home/config.toml"
ST="$L/state"
# spawn incarnation strictly older than any turn end
printf 'harness=codex\nspawn_gen=s%s.1.1\n' "$(( $(date +%s) - 5 ))" > "$ST/t1.meta"

"$LABH" provision "$S" >/dev/null 2>&1 || { log "provision failed"; exit 1; }
"$LABH" run "$S" workspace create >/dev/null 2>&1 || { log "workspace create failed"; exit 1; }
P=$("$LABH" run "$S" pane list 2>/dev/null | jq -r '(.result.panes // .result)[0].pane_id // empty')
[ -n "$P" ] || { log "no pane"; exit 1; }
log "lab session=$S pane=$P"
sleep 2
cat > "$L/launch.sh" <<SH
#!/usr/bin/env bash
cd "$L/work"
export CODEX_HOME="$L/codex-home"
exec codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c 'notify=["bash","-c","touch $ST/t1.turn-ended"]'
SH
chmod +x "$L/launch.sh"
"$LABH" run "$S" pane run "$P" "$L/launch.sh" >/dev/null 2>&1 || { log "pane run failed"; exit 1; }

classify() {
  ( . "$ROOT/bin/fm-backend.sh" >/dev/null 2>&1; . "$ROOT/bin/fm-busy-lib.sh";
    export HERDR_SESSION=$S
    fm_busy_classify herdr "$S:$P" codex t1 "$ST" )
}
native() { "$LABH" run "$S" agent get "$P" 2>/dev/null | jq -r '.result.agent.agent_status // "?"'; }
waitfor() {  # <want-native> <tries>
  local i=0 n
  while [ "$i" -lt "$2" ]; do n=$(native); [ "$n" = "$1" ] && return 0; sleep 2; i=$((i+1)); done
  return 1
}

waitfor idle 45 || log "codex never reported idle (native=$(native))"
"$LABH" run "$S" pane read "$P" --source recent --lines 8 2>/dev/null | tail -n 8
log "S1 fresh codex, no turn-ended marker: native=$(native) verdict=[$(classify)]"

"$LABH" run "$S" pane send-text "$P" 'Run the shell command `sleep 25 && echo done` and then reply with exactly: finished' >/dev/null 2>&1
sleep 1
"$LABH" run "$S" pane send-keys "$P" Enter >/dev/null 2>&1
waitfor working 20 && log "S2 during the tool turn: native=$(native) verdict=[$(classify)]" || log "S2 never saw native working (native=$(native)) verdict=[$(classify)]"

waitfor idle 60
i=0; while [ ! -e "$ST/t1.turn-ended" ] && [ $i -lt 15 ]; do sleep 2; i=$((i+1)); done
ls -l "$ST/t1.turn-ended" 2>&1
sleep 1
log "S3 after codex finished (notify wrote marker): native=$(native) verdict=[$(classify)]"

sleep 1; : > "$ST/t1.turn-start"
log "S4 typed send recorded a newer turn start, native still idle: native=$(native) verdict=[$(classify)]"
mv "$ST/t1.turn-ended" "$ST/t1.turn-ended.aside"; rm -f "$ST/t1.turn-start"
log "S5 native idle but marker removed: native=$(native) verdict=[$(classify)]"
"$LABH" run "$S" pane read "$P" --source recent --lines 15 2>/dev/null | tail -n 15
