cat > "$BASE/endpoint-shell" <<SH
#!/usr/bin/env bash
export HOME='$HOME' TREEHOUSE_ROOT='$BASE/endpoint-pool'
exec /bin/bash --noprofile --norc -i
SH
chmod +x "$BASE/endpoint-shell"
cat > "$HERDR_CONFIG_PATH" <<TOML
onboarding = false
[terminal]
default_shell = "$BASE/endpoint-shell"
shell_mode = "non_login"
[update]
version_check = false
manifest_check = false
TOML
echo 'SCENARIO: Herdr caller and endpoint shell use different Treehouse roots'
LAB_NAME=$("$ROOT/bin/fm-herdr-lab.sh" name agy-pool)
HOME="$ORIGINAL_HOME" TREEHOUSE_ROOT="$BASE/endpoint-pool" "$ROOT/bin/fm-herdr-lab.sh" provision "$LAB_NAME"
SESSION=$LAB_NAME
export HERDR_SESSION="$SESSION"
# Route every product Herdr operation through the lab helper. Its own calls use
# the original PATH, avoiding wrapper recursion.
ORIGINAL_PATH=$PATH
cat > "$BASE/shim/herdr" <<SH
#!/usr/bin/env bash
set -eu
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --session) test "\$2" = '$SESSION'; shift 2 ;;
    --session=*) test "\${1#*=}" = '$SESSION'; shift ;;
    *) args+=("\$1"); shift ;;
  esac
done
if [ "\${args[0]:-}" = --version ]; then exec '$REAL_HERDR' --version; fi
HOME='$ORIGINAL_HOME' PATH='' exec '$ROOT/bin/fm-herdr-lab.sh' run '$SESSION' "\${args[@]}"
SH
# Expand the original tool PATH only after excluding this new wrapper directory.
python3 - "$BASE/shim/herdr" "$ORIGINAL_PATH" "$BASE/shim:" <<'PYS'
import sys
p=sys.argv[1]
s=open(p).read().replace("PATH=''", "PATH='"+sys.argv[2].replace(sys.argv[3], '', 1)+"'")
open(p,'w').write(s)
PYS
chmod +x "$BASE/shim/herdr"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
brief agy-herdr initial
if FM_AGY_READY_POLLS=1 FM_AGY_POLL_INTERVAL=0 spawn agy-herdr herdr; then echo 'FAIL: readiness fault did not fire'; exit 1; fi
test -f "$FM_HOME/state/agy-herdr.meta"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-herdr.meta")
case "$WT" in "$BASE/caller-pool/"*) ;; *) echo "FAIL: wrong allocation pool $WT"; exit 1 ;; esac
test ! -d "$BASE/endpoint-pool/.treehouse"
echo "Recorded caller-pool checkout=$WT; endpoint pool is unused"
cat "$FM_HOME/state/agy-herdr.status"
(cd "$PROJECT" && treehouse status --json)
SECOND=$(cd "$PROJECT" && treehouse get --lease --lease-holder second-dispatch --no-fetch)
test "$SECOND" != "$WT"
echo "Second dispatch obtained $SECOND rather than $WT"
(cd "$PROJECT" && treehouse return "$SECOND" --if-lease-holder second-dispatch --force)
TOKEN="herdr-relaunch-$$-$RANDOM"
"$ROOT/bin/fm-control.sh" agy-herdr relaunch --note "Overwrite the report at $FM_HOME/data/agy-herdr/report.md with exactly: BRIEF_RECEIVED $TOKEN 80235 <your actual current working directory>. Then stop and wait."
test "$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-herdr.meta")" = "$WT"
wait_report agy-herdr "$TOKEN" "$WT"
"$ROOT/bin/fm-peek.sh" agy-herdr > "$EVIDENCE/r3-herdr-pane.txt"
retire agy-herdr
echo 'PASS: Herdr mismatch cannot lose custody and recovery processes a fresh brief in the original checkout'
