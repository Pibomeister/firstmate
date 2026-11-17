#!/usr/bin/env bash
# tests/fm-permission-prompt.test.sh - worker permission prompts under the
# watchdog (bin/fm-permission-prompt.sh and its route in bin/fm-watchdog.sh).
#
# The classifier runs on real Claude Code 2.1.325 captures in
# tests/fixtures/permission-prompt/ and on prompts built from them. Every route
# case runs the real watchdog against a disposable home whose worker panes are
# real tmux panes on a private socket. A worker pane logs every byte typed into
# it and, when it reads Escape, redraws the screen Claude drew after Escape.
# The fm-control relaunch is a logging fake; the fm-send steer is the real one.
# Optional arguments select test functions; no arguments run the full suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-permission-prompt-tests)
WD="$ROOT/bin/fm-watchdog.sh"
PP="$ROOT/bin/fm-permission-prompt.sh"
FIX="$ROOT/tests/fixtures/permission-prompt"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-permission-prompt-test-$$"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"
CALLS_LOG="$TMP_ROOT/external-calls.log"
: > "$CALLS_LOG"
for tool in gh gh-axi osascript terminal-notifier say mail sendmail curl claude agy; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$CALLS_LOG"
exit 1
SH
  chmod +x "$FAKEBIN/$tool"
done
PATH="$FAKEBIN:$PATH"
export PATH

LOCK_PIDS=''
cleanup_permission_prompt_tests() {
  local p
  for p in $LOCK_PIDS; do kill "$p" 2>/dev/null || true; done
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_permission_prompt_tests EXIT

BASE=$(date +%s)
CASE_N=0
ESC=$'\033'

# --- fixtures ----------------------------------------------------------------

bash_prompt() { cat "$FIX/claude-2.1.325-bash-prompt.txt"; }
# bash_prompt_with <command>: the real Bash prompt with another command in it.
bash_prompt_with() { bash_prompt | sed "s#touch /tmp/probe/fm-perm-probe2.txt#$1#"; }

classify() {  # <harness> [dialog]  (screen on stdin)
  bash "$PP" classify --harness "$1" ${2:+--dialog "$2"}
}

# make_home [extra-config]: a disposable home with a live captain pane and lock
# holder, so one watchdog pass visits its recorded workers.
make_home() {
  local extra=${1:-} sess sid
  CASE_N=$((CASE_N + 1))
  H="$TMP_ROOT/home$CASE_N"
  sid="00000000-0000-4000-8000-00000000000$CASE_N"
  mkdir -p "$H/state" "$H/config" "$H/data" "$H/claude/projects/p"
  printf 'Captain session\n> \n' > "$H/screen.txt"
  cat > "$H/agent.sh" <<SH
#!/usr/bin/env bash
cat "$H/screen.txt"
stty -echo
exec cat >> "$H/typed.log"
SH
  chmod +x "$H/agent.sh"
  sess="pp$CASE_N"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/agent.sh"
  T=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=$sess" -F '#{pane_id}' | head -n 1)
  ( sleep 100000 > /dev/null 2>&1 & printf '%s\n' "$!" > "$H/lockpid" )
  LOCKPID=$(cat "$H/lockpid")
  LOCK_PIDS="$LOCK_PIDS $LOCKPID"
  printf '%s\n' "$LOCKPID" > "$H/state/.lock"
  printf '%s\n' "$sid" > "$H/state/.lock-session"
  fm_touch_epoch "$((BASE - 1))" "$H/state/.lock" "$H/state/.lock-session"
  jq -n --arg t "$T" --arg s "$sid" --argjson e "$BASE" --argjson p "$LOCKPID" \
    '{schema:"fm-heartbeat.v1", generated_epoch:$e, primary:{terminal:{backend:"tmux",target:$t,present:true},session:{trusted_id:$s},writer:{anchor_pid:$p,session_id:$s}}}' \
    > "$H/state/heartbeat.json"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:"Working."}]}}' \
    > "$H/claude/projects/p/$sid.jsonl"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=1\nmodels=\nquota-guard=off\n%s\n' "$H/claude" "$extra" > "$H/config/watchdog"
  cat > "$H/control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$H/control.log"
if [ -e "$H/control.refuse" ]; then
  echo "error: task \$1 is blocked on a prompt: permission. Refusing to type Enter into it." >&2
  exit 1
fi
exit 0
SH
  chmod +x "$H/control.sh"
  sleep 0.3
}

# worker <id> <harness|-> <screen-file> [after-escape-file]: a real tmux pane
# and state/<id>.meta. The pane logs every byte it reads, and redraws
# after-escape-file when it reads Escape, as Claude does.
worker() {
  local id=$1 harness=$2 screen=$3 after=${4:-} sess
  cp "$screen" "$H/worker-$id.txt"
  if [ -n "$after" ]; then cp "$after" "$H/worker-$id.after"; fi
  cat > "$H/worker-$id.sh" <<SH
#!/usr/bin/env bash
cat "$H/worker-$id.txt"
stty -echo -icanon min 1 2>/dev/null
while IFS= read -r -n 1 -d '' c; do
  printf '%s' "\$c" >> "$H/worker-$id.typed"
  if [ "\$c" = "$ESC" ] && [ -f "$H/worker-$id.after" ]; then
    printf '\033[2J\033[H'
    cat "$H/worker-$id.after"
  fi
done
SH
  chmod +x "$H/worker-$id.sh"
  : > "$H/worker-$id.typed"
  sess="pw${id}${CASE_N}"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" new-session -d -s "$sess" -x 160 -y 40 "$H/worker-$id.sh"
  WP=$("$REAL_TMUX" -f /dev/null -L "$SOCKET" list-panes -t "=$sess" -F '#{pane_id}' | head -n 1)
  {
    printf 'kind=ship\nbackend=tmux\nwindow=%s\nendpoint_task_id=%s\n' "$WP" "$id"
    [ "$harness" = - ] || printf 'harness=%s\n' "$harness"
  } > "$H/state/$id.meta"
  # Wait until the fake worker has painted its screen, so a loaded host never
  # hands the watchdog an empty pane.
  local n=0
  until "$REAL_TMUX" -f /dev/null -L "$SOCKET" capture-pane -p -t "$WP" 2>/dev/null | grep -q '[^[:space:]]'; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || fail "worker $id never painted its screen"
    sleep 0.1
  done
}

# repaint <id> <screen-file>: the worker now shows another screen.
repaint() {
  local sess="pw${1}${CASE_N}"
  "$REAL_TMUX" -f /dev/null -L "$SOCKET" kill-session -t "=$sess" 2>/dev/null || true
  worker "$1" "$(sed -n 's/^harness=//p' "$H/state/$1.meta")" "$2"
}

run_wd() {  # <offset-secs> <args>...
  local off=$1
  shift
  FM_TEST_SEAM=1 FM_WD_TEST_COMPOSER="${PP_COMPOSER:-empty}" FM_WD_TEST_CONTROL="$H/control.sh" FM_WD_NOW=$((BASE + off)) FM_HOME="$H" bash "$WD" "$@"
}

TF_DESTROY=$'Plan: 0 to add, 0 to change, 3 to destroy.\n\nDo you really want to destroy all resources?\n  Terraform will destroy all your managed infrastructure, as shown above.\n  There is no undo. Only \'yes\' will be accepted to confirm.\n\n  Enter a value: '
TYPE_DELETE=$'This permanently removes project acme.\nType DELETE to confirm:'
GIT_CLEAN=$'Would remove the following items:\n  build/   out.log\n*** Commands ***\n    1: clean                2: filter by pattern    3: select by numbers\n    4: ask each             5: quit                 6: help\nWhat now> '
DRIZZLE=$'Warning  Found data-loss statements:\n· You\'re about to delete users table with 3 items\n\nTHIS ACTION WILL CAUSE DATA LOSS AND CANNOT BE REVERTED\n\nDo you still want to push changes?\n❯ No, abort\n  Yes, I want to remove 1 table,'
SSO_URL=$'work\nSSO start URL [None]: '
SSO_SCOPES=$'work\nSSO registration scopes [sso:account:access]: '
SSO_URL_DEFAULT=$'work\nSSO start URL [https://my-sso-portal.awsapps.com/start]: '
PIP_WIPE=$'git clone in ./src/foo exists with URL https://example.com/a.git\nThe plan is to install the git repository https://example.com/b.git\nWhat to do?  (s)witch, (i)gnore, (w)ipe, (b)ackup '
DPKG_CONF=$'Configuration file \'/etc/example.conf\'\n ==> Modified (by you or by a script) since installation.\n ==> Package distributor has shipped an updated version.\n   What would you like to do about it ?  Your options are:\n    Y or I  : install the package maintainer\'s version\n    N or O  : keep your currently-installed version\n      D     : show the differences between the versions\n      Z     : start a shell to examine the situation\n The default action is to keep your current version.\n*** example.conf (Y/I/N/O/D/Z) [default=N] ?'
PATCH_R=$'patching file a.c\nReversed (or previously applied) patch detected!  Assume -R? [n] '
NPM_OTP=$'$ npm profile enable-2fa auth-and-writes\nPassword: \nAnd an OTP code from your authenticator: '
GPG_EDIT=$'sec  ed25519/0123456789ABCDEF\n     created: 2026-01-01  usage: SC\ngpg> '
GH_HOST=$'? Where do you use GitHub? Other\n? Hostname: '
DOCKER_UNLOCK=$'$ docker swarm unlock\nPlease enter unlock key: '
SSH_RETRY=$'The authenticity of host \'h (192.0.2.1)\' can\'t be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? maybe\nPlease type \'yes\', \'no\' or the fingerprint: '
GPG_CARD=$'Reader ...........: Yubico YubiKey\ngpg/card> '
GPG_TRUST=$'Please decide how far you trust this user to correctly verify other users\' keys\n  5 = I trust ultimately\n  m = back to the main menu\n\nYour decision? '
GPG_VALID=$'Please specify how long the key should be valid.\n         0 = key does not expire\nKey is valid for? (0) '
PATCH_DEL=$'can\'t find file to patch at input line 3\n|--- a/foo.c\n|+++ /dev/null\nFile to patch: '
SUDO_ES=$'$ sudo ls\n[sudo] contraseña para alice: '
AWS_ECHO=$'$ aws configure\nAWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE'
AWS_MFA=$'$ aws configure mfa-login\nMFA serial number or ARN: '
KEYCHAIN=$'$ security unlock-keychain /Users/alice/Library/Keychains/login.keychain-db\npassword to unlock /Users/alice/Library/Keychains/login.keychain-db: '
GPG_NAME=$'GnuPG needs to construct a user ID to identify your key.\n\nReal name: '
GPG_OKAY=$'You selected this USER-ID:\n    "Alice <a@example.com>"\n\nChange (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? '
INQ_HIDDEN=$'? Password: [input is hidden] '
VAULT_UNSEAL=$'$ vault operator unseal\nUnseal Key (will be hidden): '
SSH_BADPASS=$'Bad passphrase, try again for /Users/alice-long-name/.ssh/id_ed25519_work_laptop:'
YARN_LOGIN=$'yarn login v1.22.22\nquestion npm username: '
APT_PHRASE=$'WARNING: The following essential packages will be removed.\nThis should NOT be done unless you know exactly what you are doing!\n  apt\nYou are about to do something potentially harmful.\nTo continue type in the phrase \'Yes, do as I say!\'\n ?] '
MERGETOOL_DEL=$'Deleted merge conflict for \'a.c\':\n  {local}: modified file\n  {remote}: deleted\nUse (m)odified or (d)eleted file, or (a)bort? '
COMPOSER_AUTH=$'Do you want to store credentials for repo.example.com in /x/auth.json ? [Yn] '
ZYPPER_CONT=$'Continue? [y/n/v/...? shows all options] (y): '
GLAB_HOST=$'? GitLab hostname: '
WANDB_CHOICE=$'wandb: (1) Create a W&B account\nwandb: (2) Use an existing W&B account\nwandb: Enter your choice: '
DENO_ALLOW=$'┏ ⚠️  Deno requests read access to "/etc".\n┠─ Requested by `Deno.readFile()` API.\n┗ Allow? [y/n/A] (y = yes, allow; n = no, deny; A = allow all read permissions) > '
ECHO_OTP=$'Enter OTP: 123456'
ECHO_MFA=$'MFA token code: 123456'
ECHO_NPMUSER=$'npm username: alice'
ECHO_NPMEMAIL=$'Email: (this IS public) a@example.com'
ECHO_PIPUSER=$'User for pypi.example.com: alice'
ECHO_GITUSER=$'Username for \'https://github.com\': alice'
CP_UNWRITABLE=$'cp: unwritable \'current.db\' (mode 0444, r--r--r--); try anyway? '
RM_INACCESSIBLE=$'rm: attempt removal of inaccessible directory \'cache\'? '
RM_FR=$'rm : supprimer \'cache.txt\' du type fichier ? '
CP_FR=$'cp : voulez-vous écraser \'current.db\' ? '
MERGETOOL_HIT=$'Normal merge conflict for \'a.c\':\n  {local}: modified file\n  {remote}: modified file\nHit return to start merge resolution tool (vimdiff): '
GH_ACC_HOST=$'? Where do you use GitHub?\n  1: GitHub.com\n  2: Other\nEnter a number between 1 and 2: '
GH_ACC_AUTH=$'? How would you like to authenticate GitHub CLI?\n  1: Login with a web browser\n  2: Paste an authentication token\nEnter a number between 1 and 2: 2'
GCLOUD_CODE=$'Enter authorization code: 4/0AbCdEf'
AWS_LOGIN_CODE=$'Enter the authorization code displayed in your browser: ABCD-1234'
GCLOUD_OUTPUT=$'Enter the output of the above command: 4/0xyz'
GH_HOST_VAL=$'? Where do you use GitHub? Other\n? Hostname: github.example.com'
KEYGEN_VAL=$'Enter file in which to save the key (/Users/a/.ssh/id_ed25519): /tmp/k'
RU_PASS=$'Пароль: '
NPM_OTP_VAL=$'And an OTP code from your authenticator: 123456'
AWSVAULT_MFA=$'Enter MFA code for arn:aws:iam::123456789012:mfa/user: 123456'
CERTBOT_DEL=$'Are you sure you want to delete the above certificate(s)?\n(Y)es/(N)o: '
MKFS_PROCEED=$'/dev/sdb1 contains a ext4 file system\nProceed anyway? (y,N) '
RM_TYPED=$'rm: remove regular file \'important.txt\'? y'
TF_TYPED=$'Do you want to perform these actions?\n  Terraform will perform the actions described above.\n  Only \'yes\' will be accepted to approve.\n\n  Enter a value: yes'
SSO_URL_VAL=$'SSO start URL [None]: https://my-sso-portal.awsapps.com/start'
SSO_SCOPES_VAL=$'SSO registration scopes [sso:account:access]: sso:account:access'
AZ_TENANT_VAL=$'Select a subscription and tenant (Type a number or Enter for no changes): 1'
WRAP_GITUSER=$'$ git push\nUsername for \'https://github.co\nm\': '
WRAP_MFA=$'Enter MFA code for arn:aws:iam::123456789012:mfa/u\nser: '
WRAP_KEYGEN=$'Enter file in which to save the key (/Users/alice/.s\nsh/id_ed25519): '
NPM_AGAIN=$'$ npm profile set password\nCurrent password: \nNew password: \n       Again:     '
SSH_KEYFILE=$'work\nEnter file in which the key is (/Users/test/.ssh/id_ed25519): '
GH_SSHTITLE=$'? Upload your SSH public key to your GitHub account? /Users/test/.ssh/id_ed25519.pub\n? Title for your SSH key: (GitHub CLI) '
GH_DEVICE=$'! First copy your one-time code: 1A2B-3C4D\nPress Enter to open https://github.com/login/device in your browser... '
AZ_SELECT=$'[Tenant and subscription selection]\n\nNo     Subscription name    Subscription ID                       Tenant\n-----  -------------------  ------------------------------------  --------\n[1] *  Dev                  00000000-0000-0000-0000-000000000000  Contoso\n\nSelect a subscription and tenant (Type a number or Enter for no changes): '
GCLOUD_REMOTE=$'You are authorizing gcloud CLI without access to a web browser.\n\ngcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?response_type=code"\n\n\nEnter the output of the above command: '
SSO_TOOLBAR=$'SSO session name (Recommended): my-sso\n────────────────────────────────────────────────────────────\nConfiguration for SSO session: my-sso\n\n{\n  "sso_start_url": "https://my-sso-portal.awsapps.com/start",\n  "sso_region": "us-east-1"\n}'
GCLOUD_AUTH_PICK=$'Please select your preferred authentication option for cluster [my-cluster]\n [1] Azure AD\n [2] Okta\n [3] cancel\nPlease enter your numeric choice: '
PIP_USER=$'Looking in indexes: https://pypi.example.com/simple\nUser for pypi.example.com: '
CARGO_LOGIN=$'    Updating crates.io index\nplease paste the token found on https://crates.io/me below'
GIT_CLEAN_SELECT=$'Would remove the following items:\n  build/   tmp.txt\n*** Commands ***\n    1: clean                2: filter by pattern    3: select by numbers\n    4: ask each             5: quit                 6: help\nWhat now> 3\n    1: build/    2: tmp.txt\nSelect items to delete>> '
GIT_CLEAN_FILTER=$'Would remove the following items:\n  build/   tmp.txt\n*** Commands ***\n    1: clean                2: filter by pattern    3: select by numbers\n    4: ask each             5: quit                 6: help\nWhat now> 2\n  build/   tmp.txt\nInput ignore patterns>> '
AWS_ROLE=$'Using the account ID 111122223333\nThere are 2 roles available to you.\n> ReadOnly\n  FullAccess'
# BSD rm, cp, and mv, gh, git hunk, Heroku, parted, Prisma, Supabase, and pnpm
# destructive confirmations.
DESTRUCTIVE_CONFIRMS=(
  "$PIP_WIPE"
  $'What to do?  (i)gnore, (w)ipe, (b)ackup '
  "$DPKG_CONF"
  "$PATCH_R"
  "$PATCH_DEL"
  "$APT_PHRASE"
  "$MERGETOOL_DEL"
  "$CP_UNWRITABLE"
  "$RM_INACCESSIBLE"
  "$RM_FR"
  "$CP_FR"
  "$CERTBOT_DEL"
  "$MKFS_PROCEED"
  "$RM_TYPED"
  $'Reversed (or previously applied) patch detected!  Assume -R? [n] n\nApply anyway? [n] '
  $'work\nremove a.txt? '
  $'work\nexamine files in directory d? '
  $'work\nrecursively remove d? '
  $'work\noverride r--r--r--  dev/staff for a.txt? '
  $'work\noverwrite b? (y/n [n]) '
  $'work\n? Type acme/repo to confirm deletion: '
  $'work\nDiscard this hunk from worktree [y,n,q,a,d,e,?]? '
  $' !    WARNING: This will destroy acme\n !    To proceed, type acme or re-run this command with\n !    --confirm acme\n\n> '
  $'The following packages will be REMOVED:\n\n  numpy-1.26\n\nProceed ([y]/n)? '
  $'work\n< rm ./a.txt > ? '
  $'work\nrm a b ?...'
  $'work\noverride r--r--r-- dev/staff uchg for a.txt? '
  $'? Do you still want to push changes? This deletes the users table (Use arrow keys)\n❯ No, abort\n  Yes, I want to remove 1 table,'
  $'Archive:  x.zip\nreplace a.txt? [y]es, [n]o, [A]ll, [N]one, [r]ename: '
  "$GIT_CLEAN"
  "$GIT_CLEAN_SELECT"
  "$GIT_CLEAN_FILTER"
  "$DRIZZLE"
  $'work\nAre you sure you want to drop the database \'app\' on server \'(localdb)\'? (y/N)'
  $'work\nAll data will be wiped. Continue? [y/N]'
  $'    conflict  config/routes.rb\nOverwrite /app/config/routes.rb? (enter "h" for help) [Ynaqdhm] '
  $'WARNING!\n========\nThis will overwrite data on /dev/sdb irrevocably.\n\nAre you sure? (Type \'yes\' in capital letters): '
  $'Warning: The existing disk label on /dev/sdb will be destroyed and all data on this disk will be lost. Do you want to continue?\nYes/No? '
  $'? Are you sure you want to reset your database? All data will be lost. › (y/N)'
  $'Drift detected.\n? Do you want to continue? All data will be lost. › (y/N)'
  $'work\nDo you want to reset the remote database? [y/N] '
  $'? The modules directory at "/w/node_modules" will be removed and reinstalled from scratch. Proceed? (Y/n) › true'
)
# Codex CLI 0.151.0's recorded hook modal and its command approvals, whose
# footer is lowercase.
CODEX_HOOKS=$'Hooks need review\n12 hooks are new or changed.\nHooks can run outside the sandbox after you trust them.\n> 1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting (hooks won\'t run)\nPress enter to confirm or esc to go back'
codex_approval() {  # <command>
  printf '%s\n' 'Would you like to run the following command?' '' "  \$ $1" '' '› 1. Yes, proceed (y)' "  2. Yes, and don't ask again for this command (a)" '  3. No, and tell Codex what to do differently (esc)' '' '  Press enter to confirm or esc to cancel'
}
# openssl, gpg pinentry, Heroku, and inquirer credential and sign-in inputs.
PINENTRY=$'work\n┌──────────────────────────────────────────┐\n│ Please enter the passphrase to unlock    │\n│ the OpenPGP secret key                   │\n│                                          │\n│ Passphrase: ____________________________ │\n│                                          │\n│       <OK>                  <Cancel>     │\n└──────────────────────────────────────────┘'
SECRET_INPUTS=(
  $'work\nEnter PEM pass phrase:'
  $'work\nVerifying - Enter PEM pass phrase:'
  $'work\nEnter pass phrase for key.pem:'
  "$PINENTRY"
  $'work\n? Password › ****'
  $'work\n? Enter your password ********'
  $'work\n? Password [input is masked]'
  "$CARGO_LOGIN"
  $'You have enabled multi-factor authentication. Please enter OTP code.\nCode:   '
  $'Enter your access token from https://app.pulumi.com/account/tokens\n    or hit <ENTER> to log in using your browser                   : '
  "$SSH_KEYFILE"
  "$NPM_AGAIN"
  "$NPM_OTP"
  "$DOCKER_UNLOCK"
  "$INQ_HIDDEN"
  $'? Enter a value for DATABASE_URL [input is hidden] '
  "$VAULT_UNSEAL"
  "$SSH_BADPASS"
  "$ECHO_OTP"
  "$ECHO_MFA"
  "$KEYGEN_VAL"
  "$WRAP_MFA"
  "$WRAP_KEYGEN"
  "$RU_PASS"
  "$NPM_OTP_VAL"
  "$AWSVAULT_MFA"
  "$SUDO_ES"
  $'Passwort: '
  "$AWS_ECHO"
  "$KEYCHAIN"
  "$GPG_NAME"
  $'GnuPG needs to construct a user ID to identify your key.\n\nReal name: Alice\nEmail address: a@example.com\nComment: '
  "$GPG_OKAY"
  $'Enter unlock key: '
  "$GPG_CARD"
  "$GPG_TRUST"
  $'Please select what kind of key you want:\n   (1) RSA and RSA\n   (9) ECC (sign and encrypt) *default*\nYour selection? '
  "$GPG_VALID"
  "$GPG_EDIT"
  $'Generating public/private ed25519 key pair.\nEnter file in which to save the key (/home/u/.ssh/id_ed25519): '
)
SIGNIN_INPUTS=(
  $'work\nheroku: Press any key to open up the browser to login or q to exit: '
  $'? Log in to Vercel (Use arrow keys)\n❯ Continue with GitHub\n  Continue with GitLab\n  Continue with Email'
  $'? Log in to Vercel (Use arrow keys)\n❯ Continue with GitHub\n  Continue with GitLab\n  Continue with Bitbucket\n  Continue with Email\n  ─────────────────────────────────\n  Cancel'
  $'? Sign in with which account?\n❯ one\n  two\n  three\n(Use arrow keys to reveal more choices)'
  $'work\nEnter your username:'
  $'work\nEnter your email address:'
  $'work\n? Enter your email address: ›'
  $'Attempting to automatically open the SSO authorization page in your default browser.\nThere are 2 AWS accounts available to you.\n> DeveloperAccount, developer-account-admin@example.com (111122223333)\n  ProductionAccount, production-account-admin@example.com (444455556666)'
  "$AWS_ROLE"
  $'work\n? Email or username › '
  $'work\nEnter user-name: '
  $'work\nSSO session name (Recommended): '
  "$SSO_URL"
  "$SSO_SCOPES"
  "$SSO_URL_DEFAULT"
  "$GH_DEVICE"
  "$GH_SSHTITLE"
  "$GH_HOST"
  "$SSH_RETRY"
  "$YARN_LOGIN"
  "$GLAB_HOST"
  "$WANDB_CHOICE"
  "$ECHO_NPMUSER"
  "$ECHO_NPMEMAIL"
  "$ECHO_PIPUSER"
  "$ECHO_GITUSER"
  "$GH_ACC_HOST"
  "$GH_ACC_AUTH"
  "$GCLOUD_CODE"
  "$AWS_LOGIN_CODE"
  "$GCLOUD_OUTPUT"
  "$GH_HOST_VAL"
  "$SSO_URL_VAL"
  "$SSO_SCOPES_VAL"
  "$AZ_TENANT_VAL"
  "$WRAP_GITUSER"
  "$AWS_MFA"
  $'Please type \'yes\' or \'no\': '
  $'? Where do you use GitHub? [Use arrows to move, type to filter]\n> GitHub.com\n  Other'
  "$AZ_SELECT"
  $'work\n? Email or username › me@example.com'
  "$PIP_USER"
  "$GCLOUD_REMOTE"
  "$SSO_TOOLBAR"
  "$GCLOUD_AUTH_PICK"
  $'Please select your preferred authentication option for cluster [c]\n [1] Azure AD\n [2] Okta\nPlease enter your numeric choice: 9\nPlease enter a value between 1 and 2:  '
  $'SSO session name (Recommended): my-sso\n  my-sso\n  my-sso-prod\n────────────────────────────────────────────────────────────\nConfiguration for SSO session: my-sso\n\n{}'
)

ledger() { cat "$H/state/watchdog/actions.tsv" 2>/dev/null; }
ledger_rows() {  # <action> <phase> [subject]
  awk -F'\t' -v a="$1" -v p="$2" -v s="${3:-}" '$5 == "permission-prompt" && $6 == a && $7 == p && (s == "" || $4 == s)' "$H/state/watchdog/actions.tsv" 2>/dev/null | wc -l | tr -d ' '
}
status_rows() {  # <id> <state> <key>
  { cat "$H/state/$1.status" 2>/dev/null || true; } | grep -c "^$2 \[at=[0-9]*\] \[key=$3\]: " || true
}
typed() { cat "$H/worker-$1.typed" 2>/dev/null; }
inbox_text() { cat "$H/state/$1.inbox/"*.msg 2>/dev/null; }

# --- classifier ----------------------------------------------------------------

test_real_claude_prompts_classify() {
  assert_equals $'route\ttool-approval' "$(bash_prompt | classify claude)" "the real Claude Bash prompt routes on a claude worker"
  assert_equals $'hold\tunknown-harness' "$(bash_prompt | classify codex)" "the same prompt on another harness is held"
  assert_equals $'hold\tunknown-harness' "$(bash_prompt | classify '')" "the same prompt with no recorded harness is held"
  assert_equals $'trust\tworkspace' "$(classify claude < "$FIX/claude-2.1.325-trust.txt")" "the real trust dialog asks for a relaunch"
  assert_equals $'hold\ttrust-unregistered' "$(classify codex < "$FIX/claude-2.1.325-trust.txt")" "a trust dialog on a harness with no pre-registration is held"
  classify claude < "$FIX/claude-2.1.325-after-escape.txt" >/dev/null \
    && fail "the screen Claude drew after Escape must not read as a prompt"
  printf 'the password field is validated before submit\n> \n' | classify claude >/dev/null \
    && fail "conversation that mentions a password is not a prompt"
  pass "real Claude 2.1.325 prompts: tool approval routes only on claude, trust relaunches, and the cancelled screen is clear"
}

test_declining_cursor_dialogs_never_route() {
  local imports=$'────────────────────────────────────────\n Allow external CLAUDE.md file imports?\n ❯ 1. No, disable external imports\n   2. Yes, allow external imports\n\n Enter to confirm · Esc to cancel'
  local bypass=$' WARNING: Claude Code running in Bypass Permissions mode\n ❯ 1. No, exit\n   2. Yes, I accept\n\n Enter to confirm · Esc to cancel'
  local hooks=$' 2 hooks are new or changed\n ❯ 1. Review hooks\n   2. Skip\n\n Enter to confirm · Esc to cancel'
  assert_equals $'hold\texternal-imports' "$(printf '%s\n' "$imports" | classify claude)" "the external-imports dialog is held"
  assert_equals $'hold\tbypass-confirm' "$(printf '%s\n' "$bypass" | classify claude)" "the bypass confirmation is held"
  assert_equals $'hold\thooks-review' "$(printf '%s\n' "$hooks" | classify codex)" "the hook-review modal is held"
  assert_equals $'hold\thooks-review' "$(printf '%s\n' "$CODEX_HOOKS" | classify codex)" "the recorded Codex hook-review modal is held"
  assert_equals $'hardstop\trelease' "$(codex_approval 'git push origin main' | classify codex)" "a Codex approval to push main is a release stop"
  assert_equals $'hardstop\tdestructive' "$(codex_approval 'rm -rf build' | classify codex)" "a Codex approval to remove recursively is a destructive stop"
  assert_equals $'hold\tunproven' "$(codex_approval 'npm test' | classify codex)" "any other Codex command approval is held"
  assert_equals $'hold\tunproven' "$(bash_prompt | sed -e 's/^ ❯ 1\. Yes$/   1. Yes/' -e 's/^   4\. No$/ ❯ 4. No/' | classify claude)" \
    "a tool prompt whose cursor moved off 1. Yes is not proven"
  assert_equals $'hold\tunproven' "$(bash_prompt | sed '/^─\{20,\}$/d' | classify claude)" "a tool prompt with no rule above it is not proven"
  pass "declining-cursor dialogs: imports, bypass, hook review, and a moved cursor are held"
}

test_hardstop_categories() {
  assert_equals $'hardstop\tcredential' "$(bash_prompt_with 'security find-generic-password -s gh -w' | classify claude)" "a keychain read is a credential stop"
  assert_equals $'hardstop\tcredential' "$(bash_prompt_with 'cat ~/.ssh/id_ed25519' | classify claude)" "a private key read is a credential stop"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'rm -rf build/' | classify claude)" "a recursive remove is a destructive stop"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'git reset --hard origin/main' | classify claude)" "a hard reset is a destructive stop"
  assert_equals $'hardstop\trelease' "$(bash_prompt_with 'gh pr merge 12 --squash' | classify claude)" "a merge is a release stop"
  local c
  for c in 'rm report.txt' 'rm --recursive --force build/' 'git restore src/app.py' 'git checkout -f main' 'find . -name x -delete' 'docker system prune -af'; do
    assert_equals $'hardstop\tdestructive' "$(bash_prompt_with "$c" | classify claude)" "$c is a destructive stop"
  done
  assert_equals $'hardstop\tspend' "$(bash_prompt_with 'echo Use paid credits to continue' | classify claude)" "paid-credit wording is a spend stop"
  assert_equals $'hardstop\trelease' "$(bash_prompt_with 'git push origin main' | classify claude)" "a push to main is a release stop"
  assert_equals $'hardstop\tcredential' "$(bash_prompt_with 'op item get gh --reveal' | classify claude)" "a revealed vault item is a credential stop"
  for c in 'kubectl config view --raw' 'curl https://alice:example-pass@internal.example.test' 'git clone https://bot:pat123@git.example.test/r.git' 'pass show github' 'bw get password gh'; do
    assert_equals $'hardstop\tcredential' "$(bash_prompt_with "$c" | classify claude)" "$c is a credential stop"
  done
  assert_equals $'route\ttool-approval' "$(bash_prompt_with 'git push -u origin fm/feature-x' | classify claude)" "a feature-branch push still routes"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'git reset "--hard" HEAD' | classify claude)" "a quoted --hard is still a destructive stop"
  assert_equals $'hardstop\trelease' "$(bash_prompt_with 'git push origin HEAD:"main"' | classify claude)" "a quoted push to main is still a release stop"
  assert_equals $'hardstop\tdestructive' "$(printf "work\nrm: remove regular file 'important.txt'?\n" | classify claude)" "a terminal remove confirmation is a destructive stop"
  assert_equals $'hardstop\tspend' "$(printf 'work\nContinue with paid usage? [y/N]\n' | classify claude)" "a one-line paid-usage confirmation is a spend stop"
  assert_equals $'hold\tconfirm' "$(printf 'work\nProceed? (y/n)\n' | classify claude)" "any other terminal confirmation is held"
  assert_equals $'hardstop\tdestructive' "$(printf '%s\n' "$TF_DESTROY" | classify claude)" "a typed Terraform destroy confirmation is a destructive stop"
  assert_equals $'hardstop\tdestructive' "$(printf '%s\n' "$TYPE_DELETE" | classify claude)" "a typed DELETE confirmation is a destructive stop"
  assert_equals $'hold\tconfirm' "$(printf 'work\nType "acme" to continue:\n' | classify claude)" "any other typed confirmation is held"
  assert_equals $'hold\tconfirm' "$(printf 'work\nType my.app to confirm:\n' | classify claude)" "a typed name with a dot is a held confirmation"
  assert_equals $'hold\tconfirm' "$(printf 'work\nStage this hunk [y,n,q,a,d,e,?]? \n' | classify claude)" "a git stage-hunk prompt is a held confirmation"
  for c in "${DESTRUCTIVE_CONFIRMS[@]}"; do
    assert_equals $'hardstop\tdestructive' "$(printf '%s\n' "$c" | classify claude)" "this confirmation is a destructive stop: $c"
  done
  for c in "${SECRET_INPUTS[@]}"; do
    assert_equals $'hardstop\tcredential' "$(printf '%s\n' "$c" | classify claude)" "this input is a credential stop: $c"
  done
  for c in "${SIGNIN_INPUTS[@]}"; do
    assert_equals $'hardstop\tsign-in' "$(printf '%s\n' "$c" | classify claude)" "this input is a sign-in stop: $c"
  done
  assert_equals $'hold\tconfirm' "$(printf 'work\nPress any key to continue\n' | classify claude)" "a press-any-key wait is held"
  assert_equals $'hold\tconfirm' "$(printf '? Pick a registry to log in to (Use arrow keys)\n❯ o1\n  o2\n  o3\n  o4\n  o5\n  o6\n  o7\n(Move up and down to reveal more choices)\n' | classify claude)" "a long list whose heading scrolled out of the recent rows is held"
  assert_equals $'hold\tconfirm' "$(printf 'Pick cloud project to use:\n [1] proj-a\n [2] Create a new project\nPlease enter numeric choice or text value (must exactly match list item):  \n' | classify claude)" "a gcloud numeric choice outside sign-in is a held confirmation"
  assert_equals $'hold\tconfirm' "$(printf '           staged     unstaged path\n  1:    unchanged        +1/-0 a.txt\nUpdate>> \n' | classify claude)" "a git add -i submenu is a held confirmation"
  assert_equals $'hold\tconfirm' "$(printf '*** Commands ***\n  1: status\t  2: update\t  7: quit\t  8: help\nWhat now> \n' | classify claude)" "git add -i's menu is a held confirmation"
  for c in $'worker: the tool shows\n? Log in (Use arrow keys)\n\n› Implement {feature}\n\n  100% context left · ? for shortcuts' \
    $'? Log in (Use arrow keys)\n  Continue with GitHub\n────────────────────────────────────────\n❯ continue with the docs\n────────────────────────────────────────\n  ? for shortcuts' \
    $'working on it\n› fix tests\n  esc to cancel' \
    $'• Ran npx vercel login\n  └ ? Log in to Vercel (Use arrow keys)\n    ❯ Continue with GitHub\n      Continue with GitLab\n\n› retry with a token\n\n  GPT-6.1-Sol medium · fm/branch · Context 77% left' \
    $'• Shall I continue?\n\n› yes go ahead\n\n  GPT-6.1-Sol medium · fm/branch · Context 77% left' \
    $'Should I continue?\n› yes go ahead\n  ⏎ send   ⌃J newline   ⌃T transcript   ⌃C quit' $'work\nI said yes/no? fine.\n\n❯ \n  ? for shortcuts'; do
    printf '%s\n' "$c" | classify codex >/dev/null && fail "a quoted list or busy row above a composer is not a prompt: $c"
    bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$c" >/dev/null && fail "a quoted list or busy row above a composer does not block a submit: $c"
  done
  for c in $'work\n> ' $'work\nplease remove that line?' $'work\nI typed it to confirm it works.' $'work\nI will press any key now.' $'work\nis it y/n?' $'work\n? Project name › my-app' $'work\n? Project name › my-token-app' $'work\n? Where should we create your project? › ./secret-notes' $'work\nI will paste the token below' $'work\nnote: the otp is in the vault\nok, next:' $'commit 1a2b3c\n    fix access token refresh\n:' $'The API token is read from env.\nCode:' $'here is the config\n{\n  "a": 1\n}' $'work\nthe prompt said Update>> then waited' $'work\n? Which template?' $'work\n┌────────────┐\n│ All done   │\n└────────────┘'; do
    printf '%s\n' "$c" | classify claude >/dev/null && fail "this is not a confirmation: $c"
  done
  assert_equals $'hardstop\tdestructive' "$(printf 'work\nDiscard changes? [y/N]\n' | classify claude)" "a discard confirmation is a destructive stop"
  for c in $'Use (l)ocal or (r)emote, or (a)bort? ' "$ZYPPER_CONT" "$DENO_ALLOW" $'Do you trust "symfony/flex" to execute code and wish to enable it now? (writes "allow-plugins" to composer.json) [y,n,d,?] '; do
    assert_equals $'hold\tconfirm' "$(printf '%s\n' "$c" | classify claude)" "this confirmation is held: $c"
  done
 # git mergetool's launch prompt is an owner-reserved merge stop.
  assert_equals hardstop "$(printf '%s\n' "$MERGETOOL_HIT" | classify claude | cut -f1)" "git mergetool's launch prompt is a hard stop"
  assert_equals 'terminal confirmation' "$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$MERGETOOL_HIT")" "the send guard holds git mergetool's launch prompt"
  for c in $'Pick a color\n  1: red\n  2: blue\nEnter a number between 1 and 2: ' $'Command may disrupt existing ssh connections. Proceed with operation (y|n)? ' $'Send this email? ([y]es|[n]o|[e]dit|[q]uit|[a]ll): ' $'Trust this certificate? [no]:  ' $'Press RETURN/ENTER to continue or any other key to abort:' $'By typing \'agree\' you are agreeing to the terms. Type \'print\' to print them or \'cancel\' to cancel, [agree, print, cancel] '; do
    assert_equals $'hold\tconfirm' "$(printf '%s\n' "$c" | classify claude)" "this terminal question is held: $c"
  done
  assert_equals 'option picker' "$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" $'Who should this report cover?\n❯ 1. This session only\n  2. All sessions\nEnter to choose · Esc to cancel')" "an Enter to choose picker blocks a send"
  assert_equals $'hold\tconfirm' "$(printf '%s\n' "$TF_TYPED" | classify claude)" "a Terraform approval with its answer typed is still held"
  for c in $'❯ \n────────────────────────────────────────────────────────\n  ? for shortcuts' $'│ > fix the bug: yes                                     │\n╰────────────────────────────────────────────────────────╯' 'The deploy finished with result: ok' $'Worked for 2m 10s\n\n› Ask: anything'; do
    assert_equals '' "$(printf '%s\n' "$c" | classify claude)" "an agent screen is not a typed-answer or wrapped prompt: $c"
    bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$c" >/dev/null && fail "an agent screen blocks a send: $c"
  done
  for c in $'build output line\nUsername for \'https:/\n/github.com\': ' $'build output line\nEnter passphrase for\n key \'/home/u/.ssh/i\nd_ed25519\': ' $'build output line\nAWS Secret Access Ke\ny [None]: ' $'build output line\nSSO start URL [None]\n: ' "Please type 'yes', 'no' or the fingerprint: yes" "Please type 'yes' or 'no': yes" 'gpg> save' 'gpg/card> admin' '? GitLab hostname: gitlab.example.com' 'Enter user-name: scott'; do
    [ -n "$(printf '%s\n' "$c" | classify claude)" ] || fail "a wrapped or populated sign-in input is not caught: $c"
    bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$c" >/dev/null || fail "the send guard misses a wrapped or populated sign-in input: $c"
  done
  for c in $'build output line\nrm: remove write-pro\ntected regular file \n\'important.txt\'? ' 'Select items to delete>> 1 2' 'Input ignore patterns>> *.o *.a'; do
    [ -n "$(printf '%s\n' "$c" | classify claude)" ] || fail "a wrapped or populated confirmation is not caught: $c"
    bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$c" >/dev/null || fail "the send guard misses a wrapped or populated confirmation: $c"
  done
  for c in '❯ Fix the test that asks: are you sure? yes' $'Running tests for the password reset flow and the\n login handler now, this takes a while' 'Enter the directory: src'; do
    [ -z "$(printf '%s\n' "$c" | classify claude)" ] || fail "agent text is read as a prompt: $c"
    ! bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$c" >/dev/null || fail "the send guard blocks agent text: $c"
  done
  for c in 'Hostname: build-1' 'Error code: 500' 'OTP library version: 2.1.0' 'mfa is enabled for user: alice' '2FA required for account: bob' 'src/auth.ts:  // Enter verification code: 123' 'Exit code: 1' 'Summary: done' 'rm: cannot remove x: No such file or directory'; do
    assert_equals '' "$(printf '%s\n' "$c" | classify claude)" "an ordinary output row is not a prompt: $c"
  done
  assert_equals $'hardstop\tcredential' "$(printf '%s\n' "$COMPOSER_AUTH" | classify claude)" "Composer's store-credentials question is a credential stop"
  assert_equals $'hold\tconfirm' "$(printf 'can\x27t find file to patch at input line 3\n|--- a/foo.c\n|+++ b/foo.c\nFile to patch: \n' | classify claude)" "patch's target-file input is held"
  assert_equals '' "$(printf 'work\nYour selection? \n' | classify claude)" "a generic selection question without GnuPG text is not a credential stop"
  assert_equals '' "$(printf 'work\nComment: \n' | classify claude)" "a bare Comment: label without GnuPG text is not a credential stop"
  assert_equals '' "$(printf 'Summary of tokens: 12k used\n' | classify claude)" "a row that only mentions tokens is not a credential input"
  for c in 'Username [dev]:' 'Email: (this IS public)' 'Email address:'; do
    assert_equals $'hardstop\tsign-in' "$(printf 'work\n%s\n' "$c" | classify claude)" "$c is a sign-in stop"
  done
  for c in 'should I continue?' 'the bug: continue?'; do
    printf 'work\n%s\n' "$c" | classify claude >/dev/null && fail "conversation ending in $c is not a confirmation"
  done
  assert_equals $'hardstop\tsign-in' "$(printf 'work\nUsername (dev):\n' | classify claude)" "a login input with a default value is a sign-in stop"
  assert_equals $'hardstop\tspend' "$(printf ' Continue with paid usage?\n ❯ Yes\n   No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" "an unnumbered paid-usage picker is a spend stop"
  assert_equals $'hardstop\tspend' "$({ cat "$FIX/claude-2.1.325-trust.txt"; printf '%s\n' '────────────────────────────────' '❯ ' '────────────────────────────────' ' Continue with paid usage?' ' ❯ Yes' '   No' '' ' Enter to confirm · Esc to cancel'; } | classify claude)" \
    "a trust dialog left in scrollback above a current paid-usage picker is not read as the trust dialog"
  for c in 'git push origin feature' 'tmux ls' 'curl https://example.com' 'mv a.txt b.txt' 'npm test > out.log' 'ln -sf a b' 'cp -rf a b' 'set -euo pipefail' 'git checkout -b fm/new' 'env FOO=1 npm test'; do
    assert_equals $'route\ttool-approval' "$(bash_prompt_with "$c" | classify claude)" "$c still routes"
  done
  for c in 'Enter your password:' 'Enter your passphrase:' 'Password for dev@build:' "Password for 'https://x@github.com':" 'Enter OTP:'; do
    assert_equals $'hardstop\tcredential' "$(printf 'work\n%s\n' "$c" | classify claude)" "$c is a credential stop"
  done
  assert_equals $'hardstop\tsign-in' "$(printf "work\nUsername for 'https://github.com':\n" | classify claude)" "a git username input is a sign-in stop"
  assert_equals $'hardstop\tspend' "$(printf ' Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a paid-usage picker is a spend stop"
  assert_equals $'hardstop\tdestructive' "$(printf ' Delete the database?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a destructive question picker is a destructive stop"
  assert_equals $'hardstop\tcredential' "$(printf 'work\n[sudo] password for dev:\n' | classify claude)" "a sudo password input is a credential stop"
  assert_equals $'hardstop\tsign-in' "$(printf 'Browser opened\nPaste code here if prompted >\n' | classify claude)" "a pasted sign-in code is a sign-in stop"
  assert_equals $'hardstop\tsign-in' "$(printf 'work\nEnter your authentication code:\n' | classify claude)" "an authentication code input is a sign-in stop"
  assert_equals $'hardstop\tsign-in' "$(printf ' Select login method:\n\n ❯ 1. Claude account with subscription\n   2. Anthropic Console account\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "a login picker is a sign-in stop"
  assert_equals $'hardstop\tspend' "$(printf ' You have reached your limit. Add funds to continue?\n ❯ 1. Buy more credits\n   2. Wait\n\n Enter to confirm · Esc to cancel\n' | classify claude)" \
    "an add-funds picker is a spend stop"
  for c in 'git clean --force -d' 'git -C /tmp/probe reset --hard HEAD' 'git checkout --quiet -- src/app.py' 'git checkout HEAD -- f' 'chmod 777 -R .' 'chmod -R 000 .' 'chown -R root .' 'git push origin :feature' 'git update-ref -d refs/heads/x' 'aws s3 rb s3://bucket' 'tmux kill-server' 'tmux kill-pane -t other' ': > important.txt' 'mv -f backup.db current.db' 'git checkout HEAD important.txt' 'git checkout important.txt' 'git checkout --pathspec-from-file=paths.txt'; do
    assert_equals $'hardstop\tdestructive' "$(bash_prompt_with "$c" | classify claude)" "$c is a destructive stop"
  done
  for c in 'git push origin HEAD:refs/heads/main' 'git tag v1.2.0' 'git push --tags' 'git push origin v1.2.0' 'terraform apply' 'twine upload dist/x'; do
    assert_equals $'hardstop\trelease' "$(bash_prompt_with "$c" | classify claude)" "$c is a release stop"
  done
  for c in 'cat id_rsa' 'cat ~/.config/gh/hosts.yml' 'printenv' 'env' 'curl -u user:pass https://example.com' 'cat ~/.docker/config.json' 'curl -H "Authorization: Basic dXNlcjpwYXNz" https://example.com' 'command env' 'env -0' '/usr/bin/env'; do
    assert_equals $'hardstop\tcredential' "$(bash_prompt_with "$c" | classify claude)" "$c is a credential stop"
  done
  for c in 'Enter your API key >' '? Enter your API key: ›' 'Token: ****' "Password for 'https://dev@github.com':" 'OTP:' '2FA code:'; do
    assert_equals $'hardstop\tcredential' "$(printf 'work\n%s\n' "$c" | classify claude)" "$c is a credential stop"
  done
  assert_equals $'hardstop\tspend' "$(printf ' You have hit your limit\n ❯ 1. Add funds\n   2. Wait for reset\n\n Enter to confirm · Esc to cancel\n' | classify claude usage-limit)" \
    "a usage-limit picker that offers paid usage is a spend stop"
  printf ' Switch model?\n ❯ 1. Opus\n   2. Sonnet\n\n Enter to confirm · Esc to cancel\n' | classify claude model-switch >/dev/null \
    && fail "an ordinary model-switch picker is left to its own handler"
  printf ' Which plan should I follow?\n ❯ 1. Plan A\n   2. Plan B\n\n Enter to select · ↑/↓ to navigate · Esc to cancel\n' | classify claude >/dev/null \
    && fail "an ordinary question picker is not a permission prompt"
  pass "hard stops: credential, sign-in, spend, destructive, and release prompts are named and never routed"
}

test_structure_decides_not_words() {
  local listed
  listed=$({ sed -n '1,8p' "$FIX/claude-2.1.325-bash-prompt.txt"; printf '  1. Clean the build\n  2. Run the tests\n'; sed -n '9,$p' "$FIX/claude-2.1.325-bash-prompt.txt"; })
  assert_equals $'hardstop\tdestructive' "$(printf '%s\n' "$listed" | sed 's#touch /tmp/probe/fm-perm-probe2.txt#rm -rf build/#' | classify claude)" \
    "a numbered list in the conversation never hides the prompt rows"
  assert_equals $'hardstop\tcredential' "$(printf '%s\n' "$listed" | sed 's#touch /tmp/probe/fm-perm-probe2.txt#cat ~/.ssh/id_ed25519#' | classify claude)" \
    "a credential read under a numbered list is still a stop"
  assert_equals $'route\ttool-approval' "$(bash_prompt_with "grep -rn 'Yes, I trust this folder' bin/" | classify claude)" \
    "a command that searches for a trust phrase is a tool prompt, not a trust dialog"
  assert_equals $'route\ttool-approval' "$(bash_prompt_with "rg 'quick safety check' tests/" | classify claude)" \
    "a command that names the trust heading is a tool prompt, not a trust dialog"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'rm -rf /tmp/probe; echo quick safety check' | classify claude)" \
    "a trust phrase never turns a destructive command into a relaunch"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt_with 'rm -rf build; echo allow external imports' | classify claude)" \
    "an imports phrase never turns a destructive command into a hold"
  local rule dashes
  rule=$(printf '─%.0s' $(seq 1 30)); dashes=$(printf '╌%.0s' $(seq 1 30))
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk -v rule="$rule" '/^ touch \/tmp/ { print " rm -rf build && cat <<EOF"; print rule; print " EOF"; next } { print }' | classify claude)" \
    "a full-width rule inside a heredoc never hides the command above it"
  assert_equals $'hold\tunproven' "$(bash_prompt | awk -v d="$dashes" '/^ touch \/tmp/ { print " cat <<EOF"; print d; print " EOF"; next } { print }' | classify claude)" \
    "a command box whose boundary cannot be proven is held"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk -v rule="$rule" -v d="$dashes" '/^ touch \/tmp/ { print " rm -rf ~/work && cat <<EOF"; print rule; print d; print " EOF"; next } { print }' | classify claude)" \
    "a rule and a dashed row inside a command never hide the command above them"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk -v d="$dashes" '/^ touch \/tmp/ { print " rm -rf build/ && cat <<EOF"; print d; print " EOF"; next } { print }' | classify claude)" \
    "an unproven command box that shows a destructive command is a keyed stop, not a hold"
  assert_equals $'hardstop\tdestructive' "$(bash_prompt | awk '/^ touch \/tmp/ { print " git reset --ha"; print "rd HEAD"; next } { print }' | classify claude)" \
    "a soft-wrapped destructive command is still a stop"
  assert_equals $'hardstop\tcredential' "$(bash_prompt | awk '/^ touch \/tmp/ { print " cat ~/.ss"; print "h/id_ed25519"; next } { print }' | classify claude)" \
    "a soft-wrapped credential read is still a stop"
  pass "structure, not words: conversation above a prompt and phrases inside a command never change its verdict"
}

test_antigravity_trust_screen_classifies() {
  local agy=$'Accessing workspace:\n\n/work/project\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit'
  assert_equals $'trust\tworkspace' "$(printf '%s\n' "$agy" | classify agy)" "the recorded Antigravity trust screen is a trust dialog"
  assert_equals $'hold\ttrust-unregistered' "$(printf '%s\n' "$agy" | classify codex)" "on another harness it is held"
  printf '%s\n\nok\n>\n? for shortcuts\n' "$agy" | classify agy >/dev/null \
    && fail "a quoted trust screen above a composer is not a trust dialog"
  bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$agy" >/dev/null \
    || fail "every submit refuses the Antigravity trust picker"
  pass "Antigravity trust: its recorded screen is read before the dialog detector, held off agy, and refuses every submit"
}

test_send_guard_blocks_renumbered_pickers_and_secret_inputs() {
  local screen name
  for screen in \
    $' Quick safety check\n   1. Yes, I trust this folder\n ❯ 2. No, exit\n\n Enter to confirm · Esc to cancel' \
    $' Quick safety check\n > No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel' \
    $' Allow external CLAUDE.md file imports?\n   1. Yes, allow external imports\n ❯ 2. No, disable external imports\n\n Enter to confirm · Esc to cancel' \
    $' Quick safety check\n   1. Yes, I trust this folder\n ❯ 2. No, exit\n\n Some other footer' \
    $'work\nEnter your API key >' $'work\n? Enter your API key: ›' $'work\nPassword:' $'work\nPIN:' $'work\nEnter your verification code:' \
    $'work\nPassword for \'https://dev@github.com\':' $'work\nUsername for \'https://github.com\':' $'work\nPaste code here if prompted >' $'work\nEnter verification code:' $'work\nOTP:' $'work\nEnter your authentication code:' \
    $'work\nPress Enter to open browser to sign in' $'work\n2FA:' $'work\nMFA:' $'work\nEnter code:' \
    $'work\n    Username for \'https://github.com\':' $'work\nEnter MFA code for arn:aws:iam::123456789012:mfa/user:' $'work\nUsername:' $'work\nLogin:' \
    $'work\nTwo-factor code:' $'work\nAuthenticator app code:' $'work\nSecurity key PIN:' \
    $'work\nrm: remove regular file \'important.txt\'?' $'work\nContinue with paid usage? [y/N]' $'work\nAre you sure?' \
    $'work\nUsername (dev):' "$TF_DESTROY" "$TYPE_DELETE" $'work\nUsername [dev]:' $'work\nEmail address:' $' Continue with paid usage?\n ❯ Yes\n   No\n\n Enter to confirm · Esc to cancel' \
    $' Select login method:\n ❯ 1. Claude account\n   2. API key\n\n Enter to continue · Esc to go back' \
    $' Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel' \
    "${DESTRUCTIVE_CONFIRMS[@]}" "${SECRET_INPUTS[@]}" "${SIGNIN_INPUTS[@]}" "$CODEX_HOOKS" "$(codex_approval 'rm -rf build')" "$(codex_approval 'npm test')" $'work\nPress any key to continue' $'work\nType my.app to confirm:' $'work\nStage this hunk [y,n,q,a,d,e,?]? '; do
    name=$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$screen") \
      || fail "every submit refuses this screen: $screen"
    [ -n "$name" ] || fail "the refusal names the dialog for: $screen"
  done
  local n
  for n in 2 3 4; do
    screen=$(bash_prompt_with 'rm -rf build/' | sed -e 's/^ ❯ 1\. Yes$/   1. Yes/' -e "s/^   $n\./ ❯ $n./")
    bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$screen" >/dev/null \
      || fail "every submit refuses a tool-approval prompt with option $n selected"
  done
  screen=$(cat "$FIX/claude-2.1.325-trust.txt"; printf '%s\n' '────────────────────────────────' '❯ ' '────────────────────────────────' '  ? for shortcuts')
  bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" "$screen" >/dev/null \
    && fail "a quoted trust picker above a normal composer does not block"
  bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_blocking_dialog "$2"' _ "$ROOT" $'work\nthe token refresh is fixed\n❯ ' >/dev/null \
    && fail "conversation that mentions a token is not a secret input"
  pass "send guard: a renumbered or re-glyphed declining picker, a numbered picker, a secret or sign-in input, and a terminal confirmation refuse every submit"
}

# --- the watchdog route ----------------------------------------------------------

test_tool_approval_is_declined_and_steered() {
  make_home
  worker ok claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals "$ESC" "$(typed ok | head -c 1)" "the first and only key into the prompt is Escape: $(typed ok | od -c | head -3)"
  assert_equals 1 "$(typed ok | tr -cd '\033' | wc -c | tr -d ' ')" "exactly one Escape is pressed"
  assert_not_contains "$(typed ok | head -c 2)" "1" "no Yes option is selected"
  assert_equals 1 "$(ledger_rows decline "done" worker:ok)" "the decline is recorded: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows steer "done" worker:ok)" "the rewrite instruction is recorded: $(ledger | cut -f4-8)"
  assert_contains "$(inbox_text ok)" "declined automatically" "the worker's inbox holds the rewrite instruction"
  assert_contains "$(inbox_text ok)" "<<'EOF'" "the instruction names the checkable heredoc form"
  assert_equals 0 "$(status_rows ok blocked permission-prompt-held)" "a declined prompt is not reported as blocked"
  assert_no_grep "permission dialog waiting on worker ok" "$H/data/watchdog/status.md" "a declined prompt is not a waiting gap"
  assert_equals '' "$(cat "$CALLS_LOG")" "no merge, notifier, or model tool ran"
  local mark
  mark=$(find "$H/state/watchdog/permission" -name '*-ok.declined' 2>/dev/null | head -n 1)
  [ -n "$mark" ] || fail "the declined checksum is kept"
  mark=${mark%-ok.declined}
  worker lk claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  mkdir "$mark-lk.lock"
  run_wd 200 once >/dev/null 2>&1
  assert_equals '' "$(typed lk)" "a worker another pass is acting on gets no key"
  assert_contains "$(ledger | awk -F'\t' '$7 == "refused" { print $8 }')" "another watchdog pass is acting on worker lk" "the overlap is recorded"
  rmdir "$mark-lk.lock"
  run_wd 400 once >/dev/null 2>&1
  assert_equals 1 "$(typed lk | tr -cd '\033' | wc -c | tr -d ' ')" "once the other pass is done, the prompt gets its one Escape"
  [ ! -e "$mark-lk.lock" ] || fail "the pass releases its lock"
  pass "tool approval: one Escape, verified gone, then a durable rewrite instruction, and one pass at a time per worker"
}

test_prompt_after_escape_gets_no_instruction() {
  make_home
  worker nt claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-trust.txt"
  printf 'work output\nEnter your password:\n' > "$H/pw-after.txt"
  worker np claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/pw-after.txt"
  printf 'work output\n? Enter your API key: ›\n' > "$H/key-after.txt"
  worker nk claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/key-after.txt"
  printf 'work output\nUsername (dev):\n' > "$H/user-after.txt"
  worker nu claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/user-after.txt"
  printf '%s\n' "$TF_DESTROY" > "$H/tf-after.txt"
  worker nf claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/tf-after.txt"
  printf '%s\n' "$TYPE_DELETE" > "$H/del-after.txt"
  worker nd claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/del-after.txt"
  printf 'work output\n? Type acme/widget to confirm deletion: \n' > "$H/gh-after.txt"
  worker ng claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/gh-after.txt"
  printf 'work output\noverwrite current.db? (y/n [n]) \n' > "$H/cp-after.txt"
  worker no claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/cp-after.txt"
  printf 'work output\nEnter your username:\n' > "$H/un-after.txt"
  worker ne claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/un-after.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  local id
  for id in nt np nk nu nf nd ng no ne; do
    assert_equals "$ESC" "$(typed "$id")" "only the one Escape reaches worker $id: $(typed "$id" | od -c | head -3)"
    assert_equals '' "$(inbox_text "$id")" "no instruction, and so no doorbell, goes to worker $id"
    assert_equals 0 "$(ledger_rows steer "done" "worker:$id")" "no steer is recorded for worker $id"
  done
  assert_equals 1 "$(status_rows nt blocked permission-prompt-held)" "a trust dialog behind the declined prompt is held: $(cat "$H/state/nt.status" 2>&1; ledger | grep nt | cut -f4-8)"
  assert_equals 1 "$(status_rows np blocked permission-prompt-hardstop)" "a password input behind the declined prompt is a hard stop"
  assert_equals 1 "$(status_rows nk blocked permission-prompt-hardstop)" "an API-key input behind the declined prompt is a hard stop"
  assert_equals 1 "$(status_rows nu blocked permission-prompt-hardstop)" "a login input with a default value behind the declined prompt is a hard stop"
  assert_equals 1 "$(status_rows nf blocked permission-prompt-hardstop)" "a typed Terraform destroy confirmation behind the declined prompt is a hard stop"
  assert_equals 1 "$(status_rows nd blocked permission-prompt-hardstop)" "a typed DELETE confirmation behind the declined prompt is a hard stop"
  assert_grep "shows a destructive prompt after a declined tool call" "$H/state/nf.status" "the typed confirmation stop names its category"
  assert_equals 1 "$(status_rows ng blocked permission-prompt-hardstop)" "a typed gh deletion confirmation behind the declined prompt is a hard stop"
  assert_equals 1 "$(status_rows no blocked permission-prompt-hardstop)" "a BSD overwrite confirmation behind the declined prompt is a hard stop"
  assert_equals 1 "$(status_rows ne blocked permission-prompt-hardstop)" "a prefixed username input behind the declined prompt is a hard stop"
  for id in nf nd ng no ne; do
    FM_HOME="$H" bash "$ROOT/bin/fm-send.sh" "$id" "steer for $id" >/dev/null 2>&1
    sleep 1
    assert_equals "$ESC" "$(typed "$id")" "a later doorbell types nothing into the typed confirmation on worker $id: $(typed "$id" | od -c | head -3)"
  done
  assert_grep "shows a credential prompt after a declined tool call" "$H/state/np.status" "the hard stop names its category"
  make_home
  worker nc claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  PP_COMPOSER=unknown run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals "$ESC" "$(typed nc)" "only the one Escape reaches a worker whose composer is not proven empty"
  assert_equals '' "$(inbox_text nc)" "no instruction goes to a composer that is not proven empty"
  assert_equals 1 "$(status_rows nc blocked permission-prompt-held)" "a composer that is not proven empty after Escape is held"
  pass "after Escape: a trust dialog, credential input, typed destructive confirmation, or unproven composer gets no instruction, no doorbell, and a keyed blocked line"
}

test_doorbell_never_types_into_a_prompt() {
  make_home
  worker db claude "$FIX/claude-2.1.325-bash-prompt.txt"
  worker dt claude "$FIX/claude-2.1.325-trust.txt"
  printf ' Continue with paid usage?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' > "$H/paid.txt"
  worker ds claude "$H/paid.txt"
  printf 'work output\nEnter your password:\n' > "$H/pw.txt"
  worker dp claude "$H/pw.txt"
  printf 'work output\nPress Enter to open browser to sign in\n' > "$H/browser.txt"
  worker dw claude "$H/browser.txt"
  printf 'work output\n2FA:\n' > "$H/2fa.txt"
  worker d2 claude "$H/2fa.txt"
  printf "work output\nrm: remove regular file 'important.txt'?\n" > "$H/rmc.txt"
  worker dr claude "$H/rmc.txt"
  printf 'work output\n? Type acme/widget to confirm deletion: \n' > "$H/ghdel.txt"
  worker dg claude "$H/ghdel.txt"
  printf 'work output\nremove important.txt? \n' > "$H/bsdrm.txt"
  worker dm claude "$H/bsdrm.txt"
  printf 'work output\noverwrite current.db? (y/n [n]) \n' > "$H/bsdcp.txt"
  worker dc claude "$H/bsdcp.txt"
  printf 'work output\nEnter PEM pass phrase:\n' > "$H/pem.txt"
  worker dk claude "$H/pem.txt"
  printf 'work output\nheroku: Press any key to open up the browser to login or q to exit: \n' > "$H/hk.txt"
  worker dh claude "$H/hk.txt"
  printf '%s\n' "$PINENTRY" > "$H/pin.txt"
  worker de claude "$H/pin.txt"
  codex_approval 'rm -rf build' > "$H/cxrm.txt"
  worker dx codex "$H/cxrm.txt"
  printf '%s\n' "$GIT_CLEAN" > "$H/gclean.txt"
  worker dl claude "$H/gclean.txt"
  printf '%s\n' "$AWS_ROLE" > "$H/awsrole.txt"
  worker da claude "$H/awsrole.txt"
  printf '%s\n' "${DESTRUCTIVE_CONFIRMS[@]}" | grep -A1 'disk label' > "$H/parted.txt"
  worker dq claude "$H/parted.txt"
  printf '%s\n' "${SIGNIN_INPUTS[@]}" | grep -A6 'Log in to Vercel' | tail -n 7 > "$H/vercel.txt"
  worker dv claude "$H/vercel.txt"
  printf '%s\n' "$DRIZZLE" > "$H/drizzle.txt"
  worker dz claude "$H/drizzle.txt"
  printf '%s\n' "$SSO_URL" > "$H/ssourl.txt"
  worker dy claude "$H/ssourl.txt"
  printf '%s\n' "$CARGO_LOGIN" > "$H/cargo.txt"
  worker dj claude "$H/cargo.txt"
  printf '%s\n' "$PIP_USER" > "$H/pip.txt"
  worker di claude "$H/pip.txt"
  printf '%s\n' "$GCLOUD_REMOTE" > "$H/gcloud.txt"
  worker dn claude "$H/gcloud.txt"
  printf '%s\n' "$SSO_TOOLBAR" > "$H/ssotb.txt"
  worker dw2 claude "$H/ssotb.txt"
  printf '%s\n' "$GCLOUD_AUTH_PICK" > "$H/gpick.txt"
  worker dg2 claude "$H/gpick.txt"
  printf '%s\n' "$GIT_CLEAN_SELECT" > "$H/gcsel.txt"
  worker dc2 claude "$H/gcsel.txt"
  printf '%s\n' "$GIT_CLEAN_FILTER" > "$H/gcflt.txt"
  worker df2 claude "$H/gcflt.txt"
  printf '%s\n' "$SSO_SCOPES" > "$H/ssosc.txt"
  worker ds2 claude "$H/ssosc.txt"
  printf '%s\n' "$SSO_URL_DEFAULT" > "$H/ssoud.txt"
  worker du2 claude "$H/ssoud.txt"
  printf '%s\n' "$GH_DEVICE" > "$H/ghdev.txt"
  worker dh2 claude "$H/ghdev.txt"
  printf '%s\n' "$SSH_KEYFILE" > "$H/sshkf.txt"
  worker dk2 claude "$H/sshkf.txt"
  printf '%s\n' "$GH_SSHTITLE" > "$H/ghtitle.txt"
  worker dt2 claude "$H/ghtitle.txt"
  printf '%s\n' "$NPM_AGAIN" > "$H/npmagain.txt"
  worker da2 claude "$H/npmagain.txt"
  printf '%s\n' "$PIP_WIPE" > "$H/pipwipe.txt"
  worker dp3 claude "$H/pipwipe.txt"
  printf '%s\n' "$DPKG_CONF" > "$H/dpkg.txt"
  worker dd3 claude "$H/dpkg.txt"
  printf '%s\n' "$PATCH_R" > "$H/patchr.txt"
  worker dx3 claude "$H/patchr.txt"
  printf '%s\n' "$NPM_OTP" > "$H/npmotp.txt"
  worker do3 claude "$H/npmotp.txt"
  printf '%s\n' "$GPG_EDIT" > "$H/gpgedit.txt"
  worker dg3 claude "$H/gpgedit.txt"
  printf '%s\n' "$GH_HOST" > "$H/ghhost.txt"
  worker dh3 claude "$H/ghhost.txt"
  printf '%s\n' "$DOCKER_UNLOCK" > "$H/dkunlock.txt"
  worker dk4 claude "$H/dkunlock.txt"
  printf '%s\n' "$SSH_RETRY" > "$H/sshretry.txt"
  worker ds4 claude "$H/sshretry.txt"
  printf '%s\n' "$GPG_CARD" > "$H/gpgcard.txt"
  worker dc4 claude "$H/gpgcard.txt"
  printf '%s\n' "$GPG_TRUST" > "$H/gpgtrust.txt"
  worker dt4 claude "$H/gpgtrust.txt"
  printf '%s\n' "$GPG_VALID" > "$H/gpgvalid.txt"
  worker dg4 claude "$H/gpgvalid.txt"
  printf '%s\n' "$PATCH_DEL" > "$H/patchdel.txt"
  worker df4 claude "$H/patchdel.txt"
  printf '%s\n' "$SUDO_ES" > "$H/sudoes.txt"
  worker ds5 claude "$H/sudoes.txt"
  printf '%s\n' "$AWS_ECHO" > "$H/awsecho.txt"
  worker da5 claude "$H/awsecho.txt"
  printf '%s\n' "$AWS_MFA" > "$H/awsmfa.txt"
  worker dm5 claude "$H/awsmfa.txt"
  printf '%s\n' "$KEYCHAIN" > "$H/keychain.txt"
  worker dk5 claude "$H/keychain.txt"
  printf '%s\n' "$GPG_NAME" > "$H/gpgname.txt"
  worker dg5 claude "$H/gpgname.txt"
  printf '%s\n' "$GPG_OKAY" > "$H/gpgokay.txt"
  worker dn5 claude "$H/gpgokay.txt"
  i=0
  for c in "$INQ_HIDDEN" "$VAULT_UNSEAL" "$SSH_BADPASS" "$YARN_LOGIN" "$APT_PHRASE" "$MERGETOOL_DEL" "$COMPOSER_AUTH" "$ZYPPER_CONT" "$GLAB_HOST" "$WANDB_CHOICE" "$DENO_ALLOW"; do
    i=$((i + 1))
    printf '%s\n' "$c" > "$H/a6-$i.txt"
    worker "d6x$i" claude "$H/a6-$i.txt"
  done
  i=0
  for c in "$ECHO_OTP" "$ECHO_MFA" "$ECHO_NPMUSER" "$ECHO_NPMEMAIL" "$ECHO_PIPUSER" "$ECHO_GITUSER" "$CP_UNWRITABLE" "$RM_INACCESSIBLE" "$RM_FR" "$CP_FR" "$MERGETOOL_HIT"; do
    i=$((i + 1))
    printf '%s\n' "$c" > "$H/b7-$i.txt"
    worker "d7x$i" claude "$H/b7-$i.txt"
  done
  i=0
  for c in "$GH_ACC_HOST" "$GH_ACC_AUTH" "$GCLOUD_CODE" "$AWS_LOGIN_CODE" "$GCLOUD_OUTPUT" "$GH_HOST_VAL" "$KEYGEN_VAL" "$RU_PASS" "$NPM_OTP_VAL" "$AWSVAULT_MFA" "$CERTBOT_DEL" "$MKFS_PROCEED"; do
    i=$((i + 1))
    printf '%s\n' "$c" > "$H/c8-$i.txt"
    worker "d8x$i" claude "$H/c8-$i.txt"
  done
  i=0
  for c in "$RM_TYPED" "$TF_TYPED" "$SSO_URL_VAL" "$SSO_SCOPES_VAL" "$AZ_TENANT_VAL" "$WRAP_GITUSER" "$WRAP_MFA" "$WRAP_KEYGEN"; do
    i=$((i + 1))
    printf '%s\n' "$c" > "$H/e9-$i.txt"
    worker "d9x$i" claude "$H/e9-$i.txt"
  done
  printf 'work output\n? Enter your email address: ›\n' > "$H/em.txt"
  worker du claude "$H/em.txt"
  local id
  for id in db dt ds dp dw d2 dr dg dm dc dk dh de du dx dl da dq dv dz dy dj di dn dw2 dg2 dc2 df2 ds2 du2 dh2 dk2 dt2 da2 dp3 dd3 dx3 do3 dg3 dh3 dk4 ds4 dc4 dt4 dg4 df4 ds5 da5 dm5 dk5 dg5 dn5 d6x1 d6x2 d6x3 d6x4 d6x5 d6x6 d6x7 d6x8 d6x9 d6x10 d6x11 d7x1 d7x2 d7x3 d7x4 d7x5 d7x6 d7x7 d7x8 d7x9 d7x10 d7x11 d8x1 d8x2 d8x3 d8x4 d8x5 d8x6 d8x7 d8x8 d8x9 d8x10 d8x11 d8x12 d9x1 d9x2 d9x3 d9x4 d9x5 d9x6 d9x7 d9x8; do
    FM_HOME="$H" bash "$ROOT/bin/fm-send.sh" "$id" "steer for $id" >/dev/null 2>&1
    assert_contains "$(inbox_text "$id")" "steer for $id" "the steer for worker $id is durably recorded"
    sleep 1
    assert_equals '' "$(typed "$id")" "the doorbell types nothing into the prompt on worker $id: $(typed "$id" | od -c | head -3)"
  done
  pass "doorbell: a steer to a worker on a tool-approval prompt, a trust picker, a secret or sign-in input, or a GNU, BSD, or typed terminal confirmation is recorded and types nothing"
}

test_declining_dialogs_on_workers_get_no_key() {
  local id
  make_home
  printf '%s\n' '────────────────────────────────────────' ' Allow external CLAUDE.md file imports?' ' ❯ 1. No, disable external imports' '   2. Yes, allow external imports' '' ' Enter to confirm · Esc to cancel' > "$H/imports.txt"
  printf '%s\n' ' WARNING: Claude Code running in Bypass Permissions mode' ' ❯ 1. No, exit' '   2. Yes, I accept' '' ' Enter to confirm · Esc to cancel' > "$H/bypass.txt"
  worker im claude "$H/imports.txt"
  worker by claude "$H/bypass.txt"
  worker dn claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  printf 'do-not-touch=%s\n' "$WP" >> "$H/config/watchdog"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  for id in im by dn; do
    assert_equals '' "$(typed "$id")" "no key reaches worker $id"
    assert_equals 1 "$(status_rows "$id" blocked permission-prompt-held)" "worker $id is reported as held"
  done
  assert_grep "external-imports" "$H/state/im.status" "the imports dialog names its reason"
  assert_grep "bypass-confirm" "$H/state/by.status" "the bypass confirmation names its reason"
  assert_grep "do-not-touch" "$H/state/dn.status" "the do-not-touch hold names its reason"
  pass "declining dialogs and do-not-touch workers: no key and one keyed held line"
}

test_repeated_or_capped_prompts_hold() {
  make_home 'permission-decline-cap=2'
  worker rep claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows decline "done" worker:rep)" "the first prompt is declined"
  repaint rep "$FIX/claude-2.1.325-bash-prompt.txt"
  : > "$H/worker-rep.typed"
  cp "$FIX/claude-2.1.325-after-escape.txt" "$H/worker-rep.after"
  run_wd 200 once >/dev/null 2>&1
  assert_equals '' "$(typed rep)" "the same prompt again gets no key"
  assert_equals 1 "$(status_rows rep blocked permission-prompt-held)" "the repeat is reported as held once"
  run_wd 400 once >/dev/null 2>&1
  assert_equals 1 "$(status_rows rep blocked permission-prompt-held)" "the same held prompt is not reported twice"

  bash_prompt_with 'touch /tmp/probe/second.txt' > "$H/second.txt"
  repaint rep "$H/second.txt"
  cp "$FIX/claude-2.1.325-after-escape.txt" "$H/worker-rep.after"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 2 "$(ledger_rows decline "done" worker:rep)" "a different prompt is declined under the cap"
  assert_equals 1 "$(status_rows rep resolved permission-prompt-held)" "the held line is resolved once the prompt leaves"
  bash_prompt_with 'touch /tmp/probe/third.txt' > "$H/third.txt"
  repaint rep "$H/third.txt"
  : > "$H/worker-rep.typed"
  run_wd 800 once >/dev/null 2>&1
  assert_equals '' "$(typed rep)" "a prompt past the hourly cap gets no key"
  assert_equals 2 "$(status_rows rep blocked permission-prompt-held)" "the cap is reported as held"
  assert_grep "cap; nothing more is answered" "$H/state/rep.status" "the held line names the cap"
  worker stuck claude "$FIX/claude-2.1.325-bash-prompt.txt"
  run_wd 1000 once >/dev/null 2>&1
  assert_equals 1 "$(typed stuck | tr -cd '\033' | wc -c | tr -d ' ')" "a prompt that stays after Escape got one Escape"
  assert_equals 1 "$(ledger_rows decline failed worker:stuck)" "the failed decline is recorded"
  run_wd 1300 once >/dev/null 2>&1
  assert_equals 1 "$(typed stuck | tr -cd '\033' | wc -c | tr -d ' ')" "the same prompt never gets a second Escape on a later pass"
  pass "decline guard: a repeated prompt, a prompt past the cap, and a prompt that stays after Escape are held, each reported once"
}

test_trust_dialog_relaunches_without_a_key() {
  make_home
  worker tr claude "$FIX/claude-2.1.325-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed tr)" "no key reaches a trust dialog whose cursor sits on No, exit"
  assert_equals 1 "$(grep -c '^tr relaunch --note ' "$H/control.log" 2>/dev/null || true)" "the worker is relaunched through fm-control: $(ledger | cut -f4-8)"
  assert_equals 1 "$(ledger_rows relaunch "done" worker:tr)" "the relaunch is recorded: $(ledger | cut -f4-8)"
  run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(grep -c . "$H/control.log")" "a trust dialog still showing inside the window is not relaunched again"
  assert_equals 1 "$(status_rows tr blocked permission-prompt-held)" "it is reported as held instead"
  assert_equals '' "$(typed tr)" "still no key"

  make_home
  : > "$H/control.refuse"
  worker tq claude "$FIX/claude-2.1.325-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(ledger_rows relaunch failed worker:tq)" "a refused relaunch is recorded: $(ledger | cut -f4-8)"
  assert_contains "$(ledger | awk -F'\t' '$6 == "relaunch" && $7 == "failed" { print $8 }')" "blocked on a prompt" "the refusal reason is kept"
  assert_equals 1 "$(status_rows tq blocked permission-prompt-held)" "a refused relaunch is reported as held"
  assert_equals '' "$(typed tq)" "a refused relaunch types nothing"

  make_home
  printf 'Accessing workspace:\n\n/work/project\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit\n' > "$H/agy-trust.txt"
  worker ag agy "$H/agy-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed ag)" "no key reaches the Antigravity trust picker"
  assert_equals 1 "$(grep -c '^ag relaunch --note ' "$H/control.log" 2>/dev/null || true)" "the Antigravity worker is relaunched through fm-control: $(ledger | cut -f4-8)"
  make_home
  : > "$H/control.refuse"
  printf 'Accessing workspace:\n\n/work/project\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit\n' > "$H/agy-trust.txt"
  worker ar agy "$H/agy-trust.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed ar)" "a refused Antigravity relaunch types nothing"
  assert_equals 1 "$(status_rows ar blocked permission-prompt-held)" "a refused Antigravity relaunch is reported as held"
  assert_grep "waiting on worker ar" "$H/data/watchdog/status.md" "a held Antigravity trust picker still gets the waiting gap"
  pass "trust dialog: no key, a controlled relaunch once per window, and a refusal is reported"
}

test_failed_declines_count_toward_cap() {
  make_home 'permission-decline-cap=2'
  bash_prompt_with 'touch /tmp/probe/a.txt' > "$H/a.txt"
  bash_prompt_with 'touch /tmp/probe/b.txt' > "$H/b.txt"
  bash_prompt_with 'touch /tmp/probe/c.txt' > "$H/c.txt"
  worker cap claude "$H/a.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals 1 "$(typed cap | tr -cd '\033' | wc -c | tr -d ' ')" "the first prompt that stays after Escape got one Escape"
  repaint cap "$H/b.txt"
  run_wd 300 once >/dev/null 2>&1
  assert_equals 1 "$(typed cap | tr -cd '\033' | wc -c | tr -d ' ')" "a second distinct prompt got one Escape"
  assert_equals 2 "$(ledger_rows decline failed worker:cap)" "both failed declines are recorded: $(ledger | cut -f4-8)"
  repaint cap "$H/c.txt"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 0 "$(typed cap | tr -cd '\033' | wc -c | tr -d ' ')" "a third prompt past the cap gets no key"
  assert_equals 1 "$(status_rows cap blocked permission-prompt-held)" "the worker stays reported as held by one open line"
  pass "decline cap: failed declines count toward the hourly cap"
}

test_hardstop_prompts_are_never_answered() {
  make_home
  bash_prompt_with 'security find-generic-password -s gh -w' > "$H/cred.txt"
  bash_prompt_with 'rm -rf build/' > "$H/rm.txt"
  printf ' You have reached your limit. Add funds to continue?\n ❯ 1. Buy more credits\n   2. Wait\n\n Enter to confirm · Esc to cancel\n' > "$H/spend.txt"
  printf 'Opening the browser to sign in\nPaste code here if prompted >\n' > "$H/signin.txt"
  worker cred claude "$H/cred.txt" "$FIX/claude-2.1.325-after-escape.txt"
  worker rm claude "$H/rm.txt" "$FIX/claude-2.1.325-after-escape.txt"
  worker spend claude "$H/spend.txt"
  worker signin claude "$H/signin.txt"
  printf 'Signing in\nOTP:\n' > "$H/otp.txt"
  worker otp claude "$H/otp.txt"
  printf '%s\n' "$AZ_SELECT" > "$H/az.txt"
  worker az claude "$H/az.txt"
  { cat "$FIX/claude-2.1.325-trust.txt"; printf '%s\n' '────────────────────────────────' '❯ ' '────────────────────────────────' ' Continue with paid usage?' ' ❯ Yes' '   No' '' ' Enter to confirm · Esc to cancel'; } > "$H/stale.txt"
  worker stale claude "$H/stale.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  run_wd 300 once >/dev/null 2>&1
  local id
  for id in cred rm spend signin otp stale az; do
    assert_equals '' "$(typed "$id")" "no key reaches the $id prompt"
    assert_equals 1 "$(status_rows "$id" blocked permission-prompt-hardstop)" "the $id prompt is reported once as a hard stop"
  done
  assert_grep "shows a credential prompt" "$H/state/cred.status" "the keychain prompt names its category"
  assert_grep "shows a destructive prompt" "$H/state/rm.status" "the remove prompt names its category"
  assert_grep "shows a spend prompt" "$H/state/spend.status" "the add-funds prompt names its category"
  assert_grep "shows a sign-in prompt" "$H/state/signin.status" "the sign-in input names its category"
  assert_grep "shows a sign-in prompt" "$H/state/az.status" "the az login subscription selector is a sign-in stop"
  assert_no_grep "find-generic-password" "$H/state/cred.status" "the blocked line carries no prompt text"
  assert_equals 0 "$(ledger_rows decline pending)" "no hard stop is declined"
  assert_grep "waiting on worker signin" "$H/data/watchdog/status.md" "a sign-in input with no dialog label still gets the waiting gap"
  assert_grep "waiting on worker otp" "$H/data/watchdog/status.md" "a one-time code input still gets the waiting gap"
  assert_equals '' "$(cat "$H/control.log" 2>/dev/null)" "no hard stop is relaunched"

  printf 'work output\n> \n' > "$H/plain.txt"
  repaint cred "$H/plain.txt"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 1 "$(status_rows cred resolved permission-prompt-hardstop)" "the hard stop is resolved once the prompt leaves"
  pass "hard stops: credential, destructive, spend, and sign-in prompts get no key and one keyed blocked line"
}

test_hardstop_never_reaches_council() {
  make_home 'models=claude:haiku,agy:flash
council-seats=claude:haiku,agy:flash'
  printf 'work output\n Delete the build cache?\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel\n' > "$H/rm-after.txt"
  worker hc claude "$FIX/claude-2.1.325-bash-prompt.txt" "$H/rm-after.txt"
  : > "$CALLS_LOG"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals "$ESC" "$(typed hc)" "only the one Escape reaches the worker"
  assert_equals 1 "$(status_rows hc blocked permission-prompt-hardstop)" "the destructive prompt after Escape is a hard stop: $(cat "$H/state/hc.status" 2>&1)"
  run_wd 2000 once >/dev/null 2>&1
  run_wd 4500 once >/dev/null 2>&1
  run_wd 7000 once >/dev/null 2>&1
  assert_equals "$ESC" "$(typed hc)" "no later pass types into the destructive prompt"
  assert_equals 0 "$(grep -cE '^(claude|agy) ' "$CALLS_LOG")" "no council or judge seat is called: $(cat "$CALLS_LOG")"
  assert_equals '' "$(ledger | awk -F'\t' '$5 ~ /permission-prompt-hardstop/ && $6 == "council" && $7 != "held"')" "no council convenes on the hard stop: $(ledger | cut -f4-8)"
  local out
  out=$(run_wd 7100 council --task hc --key permission-prompt-hardstop 2>&1) || true
  assert_contains "$out" "held" "a direct council request on the hard stop is held for the owner: $out"
  assert_equals 0 "$(grep -cE '^(claude|agy) ' "$CALLS_LOG")" "the direct request calls no seat either"
  pass "hard stop after Escape: the keyed blocked line is the owner's and never reaches a council"
}

test_externally_resolved_hardstop_reopens() {
  make_home
  printf 'work output\nEnter your password:\n' > "$H/pw.txt"
  worker xr claude "$H/pw.txt"
  run_wd 0 once >/dev/null 2>&1 || fail "the watchdog pass failed"
  assert_equals 1 "$(status_rows xr blocked permission-prompt-hardstop)" "the password input is a hard stop"
  FM_HOME="$H" bash "$ROOT/bin/fm-send.sh" xr --resolve-key permission-prompt-hardstop "the password was entered" >/dev/null 2>&1
  assert_equals 1 "$(grep -c '^resolved .*\[key=permission-prompt-hardstop\]' "$H/state/xr.status")" "the answer closes the hard stop: $(cat "$H/state/xr.status")"
  printf 'work output\nEnter your 2FA code:\n' > "$H/2fa.txt"
  repaint xr "$H/2fa.txt"
  run_wd 300 once >/dev/null 2>&1
  assert_equals 2 "$(status_rows xr blocked permission-prompt-hardstop)" "a new hard stop after an outside answer is reported again: $(cat "$H/state/xr.status")"
  run_wd 600 once >/dev/null 2>&1
  assert_equals 2 "$(status_rows xr blocked permission-prompt-hardstop)" "the reopened hard stop is still reported only once"
  assert_equals '' "$(typed xr)" "no key reaches either input"
  pass "hard stop: a key another writer resolved does not hide the next hard stop"
}

test_unknown_harness_dry_run_and_off() {
  make_home
  worker nh - "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed nh)" "a worker with no recorded harness gets no key"
  assert_equals 1 "$(status_rows nh blocked permission-prompt-held)" "it is reported as held"
  assert_grep "permission dialog waiting on worker nh" "$H/data/watchdog/status.md" "the waiting gap is kept"

  make_home 'permission-route=dry-run'
  worker dr claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed dr)" "dry-run presses nothing"
  assert_equals 1 "$(ledger_rows decline dry-run worker:dr)" "dry-run records what it would do: $(ledger | cut -f4-8)"
  [ ! -e "$H/state/dr.status" ] || fail "dry-run wrote a status line: $(cat "$H/state/dr.status")"

  make_home
  sed -i.bak 's/^mode=act$/mode=dry-run/' "$H/config/watchdog"
  worker dm claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed dm)" "an unset permission-route follows mode=dry-run and presses nothing"
  assert_equals 1 "$(ledger_rows decline dry-run worker:dm)" "mode=dry-run records what it would do: $(ledger | cut -f4-8)"

  make_home 'permission-route=off'
  worker of claude "$FIX/claude-2.1.325-bash-prompt.txt" "$FIX/claude-2.1.325-after-escape.txt"
  run_wd 0 once >/dev/null 2>&1
  assert_equals '' "$(typed of)" "off presses nothing"
  assert_equals '' "$(ledger | awk -F'\t' '$5 == "permission-prompt"')" "off records no route"
  [ ! -e "$H/state/of.status" ] || fail "off wrote a status line: $(cat "$H/state/of.status")"
  assert_grep "permission dialog waiting on worker of" "$H/data/watchdog/status.md" "off keeps the waiting gap"
  pass "guards: no recorded harness holds, dry-run only records, and off keeps the report-only path"
}

if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit $?
fi
fm_test_run \
  test_real_claude_prompts_classify \
  test_declining_cursor_dialogs_never_route \
  test_hardstop_categories \
  test_structure_decides_not_words \
  test_send_guard_blocks_renumbered_pickers_and_secret_inputs \
  test_antigravity_trust_screen_classifies \
  test_failed_declines_count_toward_cap \
  test_tool_approval_is_declined_and_steered \
  test_prompt_after_escape_gets_no_instruction \
  test_doorbell_never_types_into_a_prompt \
  test_declining_dialogs_on_workers_get_no_key \
  test_repeated_or_capped_prompts_hold \
  test_trust_dialog_relaunches_without_a_key \
  test_hardstop_prompts_are_never_answered \
  test_hardstop_never_reaches_council \
  test_externally_resolved_hardstop_reopens \
  test_unknown_harness_dry_run_and_off
