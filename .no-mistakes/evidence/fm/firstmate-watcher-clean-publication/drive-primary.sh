#!/usr/bin/env bash
set -u
ROOT=$PWD
EVID=/Users/eduardopicazo/.no-mistakes/evidence/01M5P9MH9YHZ7098T3VRGQQMR0
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
LAB=$(cd "$LAB" && pwd -P)
finish() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S -1000 -t primary > "$EVID/codex-primary-terminal.txt" 2>&1 || true
  for f in "$LAB"/proof.*; do [ ! -f "$f" ] || cp "$f" "$EVID/$(basename "$f")"; done
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
  rm -f "$ROOT/.test-live-tmp/primary-lab.path"
}
trap finish EXIT
bin/fm-lab-home.sh create "$LAB" || exit 1
mkdir -p "$LAB/tmux"
touch "$LAB/config/supervision-host"
cat > "$LAB/run-checks.sh" <<'CHECKS'
#!/usr/bin/env bash
set -u
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SUPERVISION_HOST_PRIMARY=codex FM_CODEX_WATCH_CHECKPOINT_AWAY=5
exec > "$FM_HOME/proof.primary-checks.log" 2>&1
printf 'REAL CODEX PRIMARY\n'
bin/fm-lock.sh || exit 1
printf '\nENTER AWAY WITHOUT RUNNING CHECKPOINT\n'
bin/fm-afk-launch.sh enter --words 'disposable live supervision proof' || exit 1
printf '\nQUIET AWAY HOST CHECKPOINT\n'
bin/fm-watch-checkpoint.sh --seconds 5
printf 'checkpoint exit=%s\n' "$?"
bin/fm-afk-contract.sh archive
printf '\nQUIET ATTENDED HOST CHECKPOINT\n'
bin/fm-watch-checkpoint.sh --seconds 5
printf 'checkpoint exit=%s\n' "$?"
printf '\nATTENDED ACTIONABLE HANDOFF\n'
(
  for ((i=0;i<300;i++)); do
    [ -s "$FM_HOME/state/.watch.lock/pid" ] && [ -e "$FM_HOME/state/.last-watcher-beat" ] && break
    sleep .1
  done
  printf 'done: disposable lab work needs main\n' > "$FM_HOME/state/proof.status"
) &
producer=$!
bin/fm-watch-checkpoint.sh --seconds 25
printf 'checkpoint exit=%s\n' "$?"
wait "$producer"
printf '\nHANDOFF QUEUE\n'
bin/fm-wake-drain.sh
printf '\nHOST LOG\n'
cat "$FM_HOME/state/.supervision-host.log"
printf '\nPROOF COMPLETE\n'
touch "$FM_HOME/proof.complete"
CHECKS
printf '%s\n' "$LAB" > .test-live-tmp/primary-lab.path
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" codex || exit 1
for ((i=0;i<360;i++)); do
  [ ! -e "$LAB/proof.complete" ] || { sleep 3; exit 0; }
  [ ! -e "$ROOT/.test-live-tmp/primary-stop" ] || exit 0
  sleep 1
done
exit 1
