. /tmp/wdt/lib.sh
hdr "S1 judge on default config: no config file, no account dir, CLAUDE_CONFIG_DIR unset, launchd-like env"
mk j1 ""; rm -f "$H/config/watchdog"
printf 'Answer with exactly one word: WORK\n' | env -i HOME=$HOME PATH=$PATH FM_HOME=$H "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls
hdr "S1b rendered launchd unit's own environment (PLIST EnvironmentVariables only)"
wd render-launchd > "$H/unit.plist"; plutil -lint "$H/unit.plist"; ls -d "$H/state/watchdog"
P=$(plutil -extract EnvironmentVariables.PATH raw "$H/unit.plist"); F=$(plutil -extract EnvironmentVariables.FM_HOME raw "$H/unit.plist")
printf 'Answer with exactly one word: LOOP\n' | env -i HOME=$HOME PATH="$P" FM_HOME="$F" "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls
hdr "S1c account dir with no login: claude fails visibly and the real agy seat answers"
mk j2 "" "models=claude:haiku,agy:gemini-3.8-flash-low"; mkdir -p "$H/emptycfg"; cfgadd "claude-config-dir=$H/emptycfg"
printf 'Answer with exactly one word: WORK\n' | FM_HOME=$H "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls
ls "$H/emptycfg" | head -3

hdr "S2 heartbeat written by real fm-heartbeat outside a pane; permission dialog on the pane"
PERM=$'Do you want to proceed?\n ❯ 1. Yes\n   2. No, and tell Claude what to do differently\n\nEsc to cancel'
mk hb "$PERM"; transcript 100 60 "Working."
FM_HOME=$H $REPO/bin/fm-heartbeat.sh --write >/dev/null 2>&1; echo "heartbeat rc=$?"; jq -c '.primary.terminal' "$H/state/heartbeat.json"
wd scan; pass_once; stat_; typed
hdr "S2b same, owed input aged: the nudge is refused, not sent"
owe 100; pass_once; led; stat_ | sed -n 1,3p; typed
hdr "S2c contrast: a good heartbeat on the same pane reads the dialog, permission gets no key"
mk hb2 "$PERM"; transcript 100 60 "Working."; pass_once; wd scan | sed -n 3p; stat_; typed
