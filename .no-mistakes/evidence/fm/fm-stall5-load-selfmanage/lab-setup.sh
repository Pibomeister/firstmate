#!/usr/bin/env bash
# Mint a lab home with two real tmux workers (real claude) and backlog items.
set -u
WT={run-worktree}
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
SOCK=$(bin/fm-lab-home.sh tmux-dir "$LAB")
echo "LAB=$LAB"; echo "SOCK=$SOCK"
printf '4\nmax-load1 16\n' > "$LAB/config/lane-capacity"
printf 'sustain-secs=60\n' > "$LAB/config/load-relief"
for spec in "w-high:1:1000" "w-low:4:2000" "w-new:4:3000"; do
  id=${spec%%:*}; rest=${spec#*:}; prio=${rest%%:*}; ep=${rest#*:}
  bin/fm-lab-home.sh tmux "$LAB" new-session -d -s firstmate -n "fm-$id" -c "$WT" 2>/dev/null \
   || bin/fm-lab-home.sh tmux "$LAB" new-window -d -t firstmate -n "fm-$id" -c "$WT"
  bin/fm-lab-home.sh tmux "$LAB" send-keys -t "firstmate:fm-$id" "exec claude" Enter
  printf 'kind=ship\nwindow=firstmate:fm-%s\nharness=claude\nspawn_gen=s%s.1\nworktree=%s\nproject=demo\n' "$id" "$ep" "$WT" > "$LAB/state/$id.meta"
  FM_HOME=$LAB bin/fm-tasks-axi.sh add "$id" "demo $id" --kind ship --start --priority "$prio" >/dev/null
done
