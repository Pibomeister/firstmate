. /tmp/wdt/lib.sh
P=$(cat /tmp/wdt/labparent); export TMUX_TMPDIR=$($REPO/bin/fm-lab-home.sh tmux-dir "$P"); SM=$P-mate; H=$P
mkdir -p "$P/config"; printf 'mode=act\nrestart=on\nmodels=\nkey-settle-secs=2\nrestart-quiet-secs=5\nrestart-secs=1\nrelaunch-timeout-secs=240\nnudge-secs=1\n' > "$P/config/watchdog"
TM() { $REPO/bin/fm-lab-home.sh tmux "$P" "$@"; }
hdr "S16b real second mate (real fm-home-seed + fm-spawn --secondmate, real Claude): pane state"
for i in $(seq 1 40); do [ -s "$SM/state/.lock" ] && break; TM capture-pane -p -t firstmate:fm-mate9 | grep -q 'trust this folder' && { TM send-keys -t firstmate:fm-mate9 Down; sleep 1; TM send-keys -t firstmate:fm-mate9 Enter; }; sleep 5; done
TM capture-pane -p -t firstmate:fm-mate9 | grep -v '^$' | tail -8 | cut -c1-150; sleep 20
echo "lock: $(cat "$SM/state/.lock" 2>/dev/null)"; PRE=$(cat "$SM/state/.lock" 2>/dev/null); wd scan | cut -c1-170
hdr "S16c session requests restart; watchdog goes through its parent's fm-control relaunch"
: > "$SM/state/.watchdog-restart-request"; for i in $(seq 1 25); do wd scan | grep -q 'pane_static.*turn_running=0' && break; sleep 5; done; sleep 10
wd once; cut -f4-8 "$P/state/watchdog/actions.tsv" | cut -c1-200; sed -n '/^## Homes/,$p' "$P/data/watchdog/status.md" | cut -c1-170
sleep 20; wd once; cut -f4-8 "$P/state/watchdog/actions.tsv" | tail -3 | cut -c1-200
echo "lock now: $(cat "$SM/state/.lock" 2>/dev/null) (before $PRE)"; ls -la "$P/state/mate9.meta" | cut -c30-; grep -E 'relaunch|spawn_gen' "$P/state/mate9.meta" | cut -c1-100; ls "$SM/data" | head; TM capture-pane -p -t firstmate:fm-mate9 | grep -v '^$' | tail -10 | cut -c1-150; ls "$P/data/watchdog/handoffs/"
