#!/usr/bin/env bash
set -u
R=/Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M6WS7VKDNPNA6MBWP6BTTH40
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
trap 'TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
echo "### Scenario 5: one watchdog pass (once --dry-run) writes the home's monitor-status"
printf 'mode=dry-run\nmodels=\n' > "$LAB/config/watchdog"
FM_HOME="$LAB" bash "$R/bin/fm-watchdog.sh" once --dry-run >/dev/null 2>&1; echo "once exit=$?"
echo "state/monitor-status: $(cat "$LAB/state/monitor-status" 2>&1)"
rm -f "$LAB/state/monitor-status"
echo
echo "### Scenario 6: a real full session start in a home with no enabled watchdog unit records the monitor read once"
echo "watchdog manager-status: $(FM_HOME="$LAB" bash "$R/bin/fm-watchdog.sh" manager-status 2>&1 | head -1)"
cd "$R"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" timeout 240 bash "$R/bin/fm-session-start.sh" > "$LAB/digest.txt" 2>&1; echo "session-start exit=$?"
head -c 600 "$LAB/digest.txt" | sed "s#$LAB#<lab>#g"; echo ...
echo "state/monitor-status after start: $(cat "$LAB/state/monitor-status" 2>&1 | sed "s#$LAB#<lab>#g")"
