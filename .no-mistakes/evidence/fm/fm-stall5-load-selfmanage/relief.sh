#!/usr/bin/env bash
# relief.sh <load> <now>: one real check pass; only load and clock are seamed.
echo "$1" > /private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.WWTGrI/load.txt
cd {run-worktree}
env -u TMUX -u TMUX_PANE -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE TMUX_TMPDIR=/tmp/fml.5mHS8J FM_HOME=/private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.WWTGrI FM_TEST_SEAM=1 FM_LOAD_RELIEF_LOAD_FILE=/private/var/folders/93/6w1bxqxn2yb92mt6rmt5zbzw0000gn/T/fm-lab.WWTGrI/load.txt FM_LOAD_RELIEF_NOW=$2 bin/fm-load-relief.sh check
echo "exit=$?"
