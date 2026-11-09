#!/usr/bin/env bash
set -u
ROOT=$1; D=$2; E=$3
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name codex-busy)
FAKEBIN=$D/fakebin; mkdir -p $FAKEBIN
cleanup() { tmux_k=1; PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; echo "teardown rc=$?"; }
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<W
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo refused >&2; exit 97; }
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
W
chmod +x $FAKEBIN/herdr
"$LAB_HELPER" provision "$SESSION" || { echo provision failed; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
. "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-busy-lib.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WORK=$D/work; mkdir -p $WORK; git -C $WORK init -q; WORK=$(cd $WORK && pwd -P)
STATE=$D/state; mkdir -p $STATE/t1.inbox/handled
PANE=$(lab workspace create --cwd "$WORK" --label fm-codexbusy --no-focus | jq -er '.result.root_pane.pane_id') || exit 1
T="$SESSION:$PANE"
NOW=$(date +%s); printf 'harness=codex\nbackend=herdr\nspawn_gen=s%s.1.1\n' "$NOW" > $STATE/t1.meta
sleep 1
CH=$D/codex-home; mkdir -p $CH; cp "$HOME/.codex/config.toml" "$HOME/.codex/auth.json" $CH/; printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$WORK" >> $CH/config.toml
lab pane run "$PANE" "CODEX_HOME=$CH codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c 'notify=[\"bash\",\"-c\",\"touch $STATE/t1.turn-ended\"]'" >/dev/null || exit 1
cls() { local v n; n=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'); v=$(fm_busy_classify herdr "$T" codex t1 "$STATE"); printf '%s herdr_agent_status=%s classify="%s" turn-ended=%s\n' "$(date +%H:%M:%S)" "$n" "$v" "$([ -e $STATE/t1.turn-ended ] && echo present || echo absent)"; }
for i in $(seq 60); do s=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'); case $s in idle|done) break;; esac; sleep 1; done
sleep 8; lab pane read "$PANE" --source visible | grep -q "Trust this folder" && { echo "trust prompt still up"; exit 1; }
lab pane read "$PANE" --source visible | tail -8
echo "## S1 fresh codex, native idle, no turn end yet (expect unknown)"; cls
echo "## S2 submit a turn with a long tool call; turn-start recorded as the doorbell/typed send does"
: > $STATE/t1.turn-start
fm_backend_send_text_submit herdr "$T" "Run the shell command: sleep 25 ; then reply with exactly DONE." 3 0.4 0.4; echo
for i in $(seq 4); do cls; sleep 3; done
echo "## S3 wait for the turn to finish (expect idle codex-turn-ended)"
for i in $(seq 50); do cls; s=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'); case $s in idle|done) break;; esac; sleep 4; done
echo "turn-start mtime=$(stat -f %m $STATE/t1.turn-start) turn-ended mtime=$(stat -f %m $STATE/t1.turn-ended 2>/dev/null)"
sleep 2; cls
echo "## S4 adversarial: a newer turn start with native idle (expect unknown, never idle)"
sleep 1; : > $STATE/t1.turn-start; cls
echo "## S5 relaunch incarnation newer than the turn end (expect unknown)"
printf 'harness=codex\nbackend=herdr\nspawn_gen=s%s.2.2\n' "$(( $(date +%s) + 5 ))" > $STATE/t1.meta; rm -f $STATE/t1.turn-start; cls
lab pane read "$PANE" --source recent --lines 40 > $E/herdr-codex-pane.txt 2>&1
