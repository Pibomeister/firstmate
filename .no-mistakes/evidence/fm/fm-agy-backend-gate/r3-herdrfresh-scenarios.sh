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
brief agy-herdr-fresh "fresh-herdr-$$"
spawn agy-herdr-fresh herdr
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/agy-herdr-fresh.meta")
case "$WT" in "$BASE/caller-pool/"*) ;; *) exit 1 ;; esac
test ! -d "$BASE/endpoint-pool/.treehouse"
wait_report agy-herdr-fresh "fresh-herdr-$$" "$WT"
retire agy-herdr-fresh
echo 'PASS: fresh Herdr launch processes its brief using caller allocation despite differing endpoint pool'
