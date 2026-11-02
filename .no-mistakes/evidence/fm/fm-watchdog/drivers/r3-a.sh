. /tmp/wdt/lib.sh
echo "revision: $(git -C $REPO rev-parse HEAD); worktree dirty lines: $(git -C $REPO status --short | wc -l | tr -d ' '); date: $(date -u +%FT%TZ)"
launchd_env() { # runs the watchdog with only what launchd + the rendered unit give it
  P=$(plutil -extract EnvironmentVariables.PATH raw "$H/unit.plist"); F=$(plutil -extract EnvironmentVariables.FM_HOME raw "$H/unit.plist")
  env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TMPDIR=$TMPDIR PATH="$P" FM_HOME="$F" "$@"; }
hdr "J1 judge on the default setup: rendered unit env, no config file, no account dir, CLAUDE_CONFIG_DIR unset, real claude"
mk j1 ""; rm -f "$H/config/watchdog"; wd render-launchd > "$H/unit.plist"; plutil -lint "$H/unit.plist"
printf 'Answer with exactly one word: WORK\n' | launchd_env "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls
hdr "J2 models=claude:haiku alone on the default setup: claude itself must answer"
mk j2 "" ; printf 'models=claude:haiku\n' > "$H/config/watchdog"; wd render-launchd > "$H/unit.plist"
printf 'Answer with exactly one word: LOOP\n' | launchd_env "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls
hdr "J3 adversarial: explicit account dir with no login still fails visibly; inherited dir is honored; agy seat answers"
mk j3 "" "models=claude:haiku,agy:gemini-3.8-flash-low"; mkdir -p "$H/emptycfg"; cfgadd "claude-config-dir=$H/emptycfg"
printf 'Answer with exactly one word: WORK\n' | FM_HOME=$H "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls; echo "account dir populated: $(ls "$H/emptycfg" | wc -l | tr -d ' ') entries"
mk j3b "" "models=claude:haiku"; mkdir -p "$H/inh"; printf 'Answer with exactly one word: WORK\n' | CLAUDE_CONFIG_DIR="$H/inh" FM_HOME=$H "$WD" judge test '(LOOP|WORK)'; echo "inherited-empty judge rc=$?"; calls; echo "inherited dir populated: $(ls "$H/inh" | wc -l | tr -d ' ') entries"
hdr "J4 default seats council: no models key, rendered unit env; a benign decision gets a unanimous blind ruling"
mk dec "x"; transcript 100 60 "Working."; printf 'mode=act\nclaude-config-dirs=%s\nnudge-secs=1\nkey-secs=1\ndecision-secs=1\n' "$H/claude" > "$H/config/watchdog"; wd render-launchd > "$H/unit.plist"
now=$(date +%s); printf 'needs-decision [at=%s] [key=cache-size]: A (recommended, the existing default and fully reversible) keep the local test cache at 64 MB, or B use 128 MB. Both are fine.\n' $((now-9000)) > "$H/state/t1.status"
launchd_env "$WD" once 2>&1; sleep 3; launchd_env "$WD" once 2>&1; led | cut -c1-120; calls; ls "$H"/data/watchdog/ 2>/dev/null; stat_ | cut -c1-170
hdr "E1 real fm-heartbeat outside a pane + permission dialog: status must not read ok, stale check live, nothing typed"
PERM=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
mk hb "$PERM"; transcript 100 60 "Working."; FM_HOME=$H $REPO/bin/fm-heartbeat.sh --write >/dev/null 2>&1; echo "heartbeat rc=$?"; jq -c '.primary.terminal' "$H/state/heartbeat.json"
wd scan | sed -n 2p; pass_once; stat_; typed
echo "-- generated_epoch aged 2000s, row must survive"; jq --argjson e $(( $(date +%s)-2000 )) '.generated_epoch=$e' "$H/state/heartbeat.json" > "$H/x" && mv "$H/x" "$H/state/heartbeat.json"; pass_once; stat_ | grep -iE 'heartbeat|NO-ENDPOINT'
hdr "E2 adversarial: owed input on the unknown endpoint: refused, not typed"
FM_HOME=$H $REPO/bin/fm-heartbeat.sh --write >/dev/null 2>&1; owe 100; pass_once; led; stat_ | sed -n 1,2p; typed
hdr "E3 adversarial: one field unknown (backend known, target object) with context present: still not ok, percent still read"
mk hb3 "$PERM"; transcript 100 60 "Working."; jq --argjson e $(date +%s) '.generated_epoch=$e|.primary.terminal.target={unknown:true,reason:"x"}|.primary.context_left={remaining:{percent:37}}' "$H/state/heartbeat.json" > "$H/x" && mv "$H/x" "$H/state/heartbeat.json"; pass_once; stat_; typed
hdr "E4 contrast: a good heartbeat on the same pane reads the dialog; no key"
mk hb2 "$PERM"; transcript 100 60 "Working."; pass_once; wd scan | sed -n 3p; stat_ | sed -n 1,2p; typed
