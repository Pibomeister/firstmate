. /tmp/wdt/lib.sh
clearpane() { tmux send-keys -t "$T" Escape; sleep 1; tmux send-keys -t "$T" C-c; sleep 2; }
echo "revision: $(git -C $REPO rev-parse HEAD); date: $(date -u +%FT%TZ)"
hdr "J4 default seats council on a real Claude TUI pane: no models key, rendered unit env, real claude + real agy seats"
mkr dec5; transcript 100 60 "Working."; printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nnudge-secs=1\nkey-secs=1\nenter-secs=1\ndecision-secs=25\n' "$H/claude" > "$H/config/watchdog"; wd render-launchd > "$H/unit.plist"
P=$(plutil -extract EnvironmentVariables.PATH raw "$H/unit.plist"); F=$(plutil -extract EnvironmentVariables.FM_HOME raw "$H/unit.plist")
le() { env -i TMUX_TMPDIR="$TMUX_TMPDIR" HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TMPDIR=$TMPDIR PATH="$P" FM_HOME="$F" "$@"; }
now=$(date +%s); printf 'needs-decision [at=%s] [key=cache-size]: A (recommended, the existing default and fully reversible) keep the local test cache at 64 MB, or B use 128 MB. Both are fine.\n' $((now-9000)) > "$H/state/t1.status"
le "$WD" once 2>&1; clearpane; sleep 26; clearpane; le "$WD" once 2>&1; led | cut -c1-140; calls; stat_ | cut -c1-170
echo "composer now: $(wd scan | sed -n 3p)"; ls "$H"/data/watchdog/ ; cat "$H"/state/operational-inbox/*.msg 2>/dev/null | cut -c1-210
