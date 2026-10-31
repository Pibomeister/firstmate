#!/usr/bin/env bash
# A decoy firstmate:0 pane exists on a private tmux server; an Orca home must leave it untouched.
E=$1
L=$(mktemp -d /tmp/fm-lab.XXXXXX)
bin/fm-lab-home.sh create "$L" >/dev/null
touch "$L/config/supervision-host-off"
echo orca > "$L/config/backend"
env FM_HOME="$L" bin/fm-afk-launch.sh enter --words lab >/dev/null 2>&1
SD=$(bin/fm-lab-home.sh tmux-dir "$L")
bin/fm-lab-home.sh tmux "$L" new-session -d -s firstmate -n 0 'cat'
bin/fm-lab-home.sh tmux "$L" list-panes -a -F '#{session_name}:#{window_index} pane=#{pane_id}'
env -u TMUX -u TMUX_PANE -u ORCA_TERMINAL_HANDLE -u TERM_PROGRAM TMUX_TMPDIR="$SD" FM_HOME="$L" bin/fm-afk-launch.sh start-native >/dev/null 2>&1
env -u TMUX -u TMUX_PANE -u ORCA_TERMINAL_HANDLE -u TERM_PROGRAM TMUX_TMPDIR="$SD" FM_AFK_STATE_PREPARED=1 FM_HOME="$L" perl -e 'alarm 14; exec @ARGV' bin/fm-afk-start.sh 2>&1 | cut -c1-200
echo "daemon rc=${PIPESTATUS[0]}"
echo "decoy pane content: [$(bin/fm-lab-home.sh tmux "$L" capture-pane -p -t firstmate:0 | tr -d '\n')]"
bin/fm-lab-home.sh tmux "$L" kill-server
bin/fm-lab-home.sh teardown "$L"
rm -rf "$L"
