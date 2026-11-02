. /tmp/wdt/lib.sh
hdr "S1 corrected: launchd-like env (HOME USER LOGNAME SHELL TMPDIR + plist PATH and FM_HOME); no config file, no account dir, CLAUDE_CONFIG_DIR unset"
echo "note: the first S1 above used env -i with no USER; the keychain login then reads as Not logged in. That is the harness, not the product."
mk j3 ""; rm -f "$H/config/watchdog"; wd render-launchd > "$H/unit.plist"
P=$(plutil -extract EnvironmentVariables.PATH raw "$H/unit.plist"); F=$(plutil -extract EnvironmentVariables.FM_HOME raw "$H/unit.plist")
printf 'Answer with exactly one word: WORK\n' | env -i HOME=$HOME USER=$USER LOGNAME=$USER SHELL=/bin/zsh TMPDIR=$TMPDIR PATH="$P" FM_HOME="$F" "$WD" judge test '(LOOP|WORK)'; echo "judge rc=$?"; calls
