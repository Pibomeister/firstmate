ROOT=$PWD
D=$ROOT/.test-agy-retest
E=~/.no-mistakes/evidence/01M8101Q8Q67QA7N3HWCG4M2M2
H=$ROOT/bin/fm-herdr-lab.sh
export FM_HERDR_LAB_STATE_DIR=$D/herdr-lab
X=$(cat "$D/xdg-root")
eval "$($H fixture apply "$X")"
S=$(cat "$D/session")
export HOME=$D/home FM_HOME=$D/fmhome HERDR_SESSION=$S
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
. "$ROOT/bin/fm-busy-lib.sh"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
GATE_CODE=$(awk '/^AGY_TRUST_DIALOG=/ {flag=1} flag {print} /^agy_wait_for_working\(\)/ {seen=1} flag && seen && /^}$/ {exit}' "$ROOT/bin/fm-spawn.sh")
eval "$GATE_CODE"
export BACKEND=herdr W=agy-live ID=agy-live STATE=$FM_HOME/state FM_AGY_READY_POLLS=1 FM_AGY_POLL_INTERVAL=0 AGY_TRUST_PREREGISTERED=1
spawn_send_key() { $H run "$S" pane send-keys "${1#"$S:"}" "$2" >/dev/null; }
