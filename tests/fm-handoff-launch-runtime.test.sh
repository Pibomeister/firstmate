#!/usr/bin/env bash
# Successor runtime choice and quota preflight for the verified handoff:
# codex, agy, and a declared Claude account take over through the real lock
# and ack; by default the successor keeps the predecessor's model, effort, and
# setting sources from its recorded launch (the verified successor record, else
# its exact cmdline, never ps), and an explicit choice wins and is recorded; an exhausted pool is refused before anything launches; no account
# pin changes. The Orca and tmux transports, quota-axi, and claude auth are
# fakes; lock, ack, and launcher are real.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-launch-runtime)
trap 'test_cleanup' EXIT
test_cleanup() {
  kill_lab
  fm_test_cleanup
}
LAB="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
QUOTA="$TMP_ROOT/quota"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$FAKEBIN" "$QUOTA" "$TMP_ROOT/user"
git init -q "$LAB"
: > "$LAB/AGENTS.md"
# Each harness is /bin/bash under that harness's name (bash 3.2 on macOS, so
# the scripts it runs avoid newer builtins), so the ack anchors the lock
# on a process the session-lock library recognizes as that harness.
for h in claude codex agy; do ln -s /bin/bash "$FAKEBIN/$h"; done
# `claude auth status` under the bash stand-in runs the `auth` script found on
# PATH; an account is signed in when its root holds a signed-in marker.
cat > "$FAKEBIN/auth" <<'EOF2'
#!/usr/bin/env bash
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -e "$CLAUDE_CONFIG_DIR/signed-in" ]
EOF2
# quota-axi answers from fixtures: an explicit profile reads its root's
# quota.json, any other read the provider's file under $FM_TEST_QUOTA.
cat > "$FAKEBIN/quota-axi" <<'EOF2'
#!/usr/bin/env bash
provider='' profile=0
while [ $# -gt 0 ]; do
  case "$1" in --provider) provider=$2; shift 2 ;; --profile-only) profile=1; shift ;; *) shift ;; esac
done
echo "$provider profile=$profile root=${CLAUDE_CONFIG_DIR:-}" >> "$FM_TEST_QUOTA/reads"
if [ "$profile" = 1 ]; then cat "$CLAUDE_CONFIG_DIR/quota.json" 2>/dev/null || exit 1; exit 0; fi
cat "$FM_TEST_QUOTA/$provider.json" 2>/dev/null || exit 1
EOF2
cat > "$FAKEBIN/tmux" <<'EOF2'
#!/usr/bin/env bash
set -eu
case "$1" in
  display-message) echo lab; exit 0 ;;
  has-session) exit 0 ;;
  new-window|new-session) shift ;;
  *) exit 94 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in -d) shift ;; -t|-s|-c|-n) shift 2 ;; *) break ;; esac
done
printf '%s\n' "$@" > "$FM_HOME/state/argv"
echo 1 > "$FM_HOME/state/attempts"
harness=''
for a; do case "$a" in claude|codex|agy) harness=$a; break ;; */fm-codex-launch.sh) harness=codex; break ;; esac; done
[ -n "$harness" ] || exit 95
TMUX_PANE=%9 "$harness" "$FM_HOME/successor.sh" >/dev/null 2>&1 &
echo "$!" >> "$FM_TEST_PIDS"
EOF2
cat > "$FAKEBIN/orca" <<'EOF2'
#!/usr/bin/env bash
set -eu
[ "$1 $2" = 'agent launch' ] || exit 91
shift 2
printf '%s\n' "$@" > "$FM_HOME/state/argv"
agent=''
while [ $# -gt 0 ]; do
  case "$1" in --agent) agent=$2; shift 2 ;; --json) shift ;; *) shift 2 ;; esac
done
echo 1 > "$FM_HOME/state/attempts"
ORCA_TERMINAL_HANDLE=term_lab_1 "$agent" "$FM_HOME/successor.sh" >/dev/null 2>&1 &
echo "$!" >> "$FM_TEST_PIDS"
printf '{"outcome":{"kind":"terminal","terminal":{"handle":"term_lab_1"}}}\n'
EOF2
chmod +x "$FAKEBIN/auth" "$FAKEBIN/quota-axi" "$FAKEBIN/tmux" "$FAKEBIN/orca"
cat > "$LAB/successor.sh" <<'EOF2'
#!/usr/bin/env bash
set -eu
nonce=$(jq -r .nonce "$FM_HOME/state/.handoff-pending")
sha=$(jq -r .sha256 "$FM_HOME/state/.handoff-pending")
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$sha" > "$FM_HOME/ack.out" 2>&1 || true
# The ack runs the predecessor close after the lock moves; mark when both
# are finished so a case never leaks events into the next one.
touch "$FM_HOME/ack.done"
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt 600 ]; do sleep 1; done
EOF2
cat > "$LAB/predecessor.sh" <<'EOF2'
#!/usr/bin/env bash
set -eu
echo "$$" > "$FM_HOME/pred.pid"
# An exact /proc-style cmdline for this process, under the launcher's test
# seam: a given file, else this process's own argv unless FM_TEST_EXACT_ARGV=0.
if [ -n "${FM_TEST_FAKE_CMDLINE:-}" ]; then
  mkdir -p "$FM_HANDOFF_TEST_PROC_ROOT/$$"
  cp "$FM_TEST_FAKE_CMDLINE" "$FM_HANDOFF_TEST_PROC_ROOT/$$/cmdline"
elif [ "${FM_TEST_EXACT_ARGV:-1}" = 1 ]; then
  mkdir -p "$FM_HANDOFF_TEST_PROC_ROOT/$$"
  printf '%s\0' bash "$0" "$@" > "$FM_HANDOFF_TEST_PROC_ROOT/$$/cmdline"
fi
ORCA_TERMINAL_HANDLE=term_predecessor bash "$ROOT/bin/fm-lock.sh" > "$FM_HOME/lock.out" 2>&1
# The verified launch record of the handoff that started this session.
if [ -n "${FM_TEST_PRED_RECORD:-}" ]; then
  printf 'pid=%s\nnonce=n\nhandoff=h\nsha256=s\nsuccessor=%s\n' "${FM_TEST_PRED_RECORD_PID:-$(cat "$FM_HOME/state/.lock")}" \
    "$FM_TEST_PRED_RECORD" > "$FM_HOME/state/.handoff-successor"
fi
set +e
args=()
if [ -f "$FM_HOME/launch.args" ]; then while IFS= read -r a; do args+=("$a"); done < "$FM_HOME/launch.args"; fi
bash "$ROOT/bin/fm-handoff-launch.sh" ${args[@]+"${args[@]}"} "$FM_HOME/data/handoff.md" > "$FM_HOME/launch.out" 2> "$FM_HOME/launch.err"
echo "$?" > "$FM_HOME/rc"
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt 600 ]; do sleep 1; done
EOF2
printf '# handoff\nRead this document.\n' > "$LAB/data/handoff.md"
export ROOT FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"
export FM_ROOT_OVERRIDE="$ROOT" FM_HANDOFF_TEST_HARNESS=claude FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=120
export FM_HANDOFF_TEST_PROC_ROOT="$TMP_ROOT/proc"
unset FM_TEST_EXACT_ARGV FM_TEST_PRED_RECORD FM_TEST_PRED_RECORD_PID
export PATH="$FAKEBIN:$PATH" FM_TEST_PIDS="$TMP_ROOT/pids" FM_TEST_QUOTA="$QUOTA" HOME="$TMP_ROOT/user"
unset FM_BACKEND FM_SESSION_ENDPOINT_META CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR CODEX_HOME TMUX TMUX_PANE ZELLIJ
unset HERDR_ENV HERDR_PANE_ID HERDR_SESSION FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND QUOTA_AXI_SNAPSHOT
export TERM_PROGRAM=Orca

# Gemini models on agy are bounded by their model-group scope, not all_models.
quota_fixture() { # <provider> <percent> <runway> [<scope>]
  jq -n --arg p "$1" --argjson pct "$2" --arg r "$3" --arg s "${4:-all_models}" \
    '{schemaVersion:5,providers:[{provider:$p,quotaSemantics:{status:"known",effectiveAvailability:[{scope:$s,status:"known",effectivePercentRemaining:$pct,runway:{status:$r}}]}}]}'
}
kill_lab() {
  if [ -f "$FM_TEST_PIDS" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$FM_TEST_PIDS"
    : > "$FM_TEST_PIDS"
  fi
}
pins_digest() {
  (cd "$LAB/config" && find . -name '*account*' -exec cksum {} + 2>/dev/null | sort)
}
# run_case <backend> [launcher args...]: lock a predecessor, run the launcher.
# The predecessor runs as $PRED_HARNESS with PRED_ARGS after its script, so
# its own launch argv carries them.
PRED_HARNESS=claude
PRED_ARGS=()
run_case() {
  local backend=$1 limit
  shift
  kill_lab
  rm -f "$LAB/state/".lock* "$LAB/state/.handoff"* "$LAB/state/argv" "$LAB/state/attempts" "$LAB/state/handoff-events.log" \
    "$LAB/state/supervisor-failover.log" "$LAB/rc" "$LAB/ack.out" "$LAB/ack.done" "$LAB/pred.pid" "$QUOTA/reads"
  printf '%s\n' "$backend" > "$LAB/config/backend"
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$LAB/launch.args"; else rm -f "$LAB/launch.args"; fi
  ("$PRED_HARNESS" "$LAB/predecessor.sh" ${PRED_ARGS[@]+"${PRED_ARGS[@]}"} & echo "$!" >> "$FM_TEST_PIDS")
  limit=$((SECONDS + 200))
  while [ ! -f "$LAB/rc" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  [ -f "$LAB/rc" ] || fail "launcher did not finish: $(cat "$LAB/launch.err" 2>/dev/null)"
}
assert_transferred_to() { # <harness> <label>
  [ "$(cat "$LAB/rc")" = 0 ] || fail "$2: handoff must complete: $(cat "$LAB/launch.err") $(cat "$LAB/ack.out" 2>/dev/null)"
  local pid limit=$((SECONDS + 120))
  while [ ! -f "$LAB/ack.done" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  [ -f "$LAB/ack.done" ] || fail "$2: the successor ack did not finish: $(cat "$LAB/ack.out" 2>/dev/null)"
  pid=$(cat "$LAB/state/.lock")
  [ "$pid" != "$(cat "$LAB/pred.pid")" ] || fail "$2: the lock did not move"
  case "$(ps -o comm= -p "$pid")" in */"$1"|"$1") ;; *) fail "$2: the lock holder is not a $1 process: $(ps -o comm=,args= -p "$pid")" ;; esac
  [ "$(sed -n 's/^pid=//p' "$LAB/state/.handoff-successor")" = "$pid" ] || fail "$2: completion must name the lock holder"
}
argv_is() { # <label> <expected arg>... ; the final PROMPT argument is matched by prefix
  local label=$1 i=0 line
  shift
  local -a got=()
  while IFS= read -r line; do got+=("$line"); done < "$LAB/state/argv"
  [ "${#got[@]}" = "$#" ] || fail "$label: expected $# argv words, got ${#got[@]}: ${got[*]}"
  for want; do
    case "$want" in
      PROMPT) case "${got[$i]}" in 'Firstmate handoff successor.'*) ;; *) fail "$label: argv[$i] is not the prompt: ${got[$i]}" ;; esac ;;
      *) [ "${got[$i]}" = "$want" ] || fail "$label: argv[$i] is '${got[$i]}', expected '$want'" ;;
    esac
    i=$((i + 1))
  done
}
MARKERS=(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS)
SHED=(env)
for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE \
  ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID; do SHED+=(-u "$v"); done

# Declared accounts: A is exhausted, B is signed in with headroom, C is signed out.
for a in A B C; do mkdir -p "$TMP_ROOT/acct$a"; done
touch "$TMP_ROOT/acctA/signed-in" "$TMP_ROOT/acctB/signed-in"
quota_fixture claude 0 exhausted_now > "$TMP_ROOT/acctA/quota.json"
quota_fixture claude 40 through_reset > "$TMP_ROOT/acctB/quota.json"
quota_fixture claude 70 through_reset > "$TMP_ROOT/acctC/quota.json"
printf '%s\n' "$TMP_ROOT/acctA" "$TMP_ROOT/acctB" "$TMP_ROOT/acctC" > "$LAB/config/claude-accounts"
PINS_BEFORE=$(pins_digest)

# Claude to Codex on tmux, keeping the home, with the choice recorded.
quota_fixture codex 55 through_reset > "$QUOTA/codex.json"
run_case tmux --harness codex --model gpt-5.5 --reason claude_pool_exhausted
assert_transferred_to codex 'codex successor'
argv_is 'codex successor' "${MARKERS[@]}" -u CODEX_HOME FM_CODEX_BIN= "$ROOT/bin/fm-codex-launch.sh" --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox PROMPT
assert_contains "$(cat "$LAB/state/.handoff-successor")" 'successor=harness=codex model=gpt-5.5 account=ambient reason=claude_pool_exhausted verdict=ok scope=all_models remaining=55' \
  'the completion record names the replacement runtime, model, reason, and quota'
assert_contains "$(cat "$LAB/state/supervisor-failover.log")" 'event=successor_ready' 'the failover log records the verified successor'
assert_contains "$(cat "$QUOTA/reads")" 'codex profile=0' 'the preflight read the successor provider quota'
pass 'claude to codex: verified lock transfer onto codex with the replacement and reason recorded'

# A restricted Codex posture carries onto the tmux successor.
printf 'restricted\n' > "$LAB/config/codex-permission-mode"
run_case tmux --harness codex
assert_transferred_to codex 'restricted codex successor'
argv_is 'restricted codex successor' "${MARKERS[@]}" -u CODEX_HOME FM_CODEX_BIN= "$ROOT/bin/fm-codex-launch.sh" --sandbox workspace-write --ask-for-approval on-request PROMPT
rm "$LAB/config/codex-permission-mode"
pass 'codex successor follows config/codex-permission-mode on tmux'

# Codex on Orca with unmeasured quota: disclosed, not blocked.
rm -f "$QUOTA/codex.json"
run_case orca --harness codex --model gpt-5.5
assert_transferred_to codex 'orca codex successor'
argv_is 'orca codex successor' --agent codex --worktree "path:$LAB" --surface terminal --model gpt-5.5 --prompt PROMPT --json
assert_contains "$(cat "$LAB/state/.handoff-successor")" 'verdict=unknown why=no_valid_codex_snapshot' 'unmeasured quota is disclosed in the record'
pass 'codex on orca: argv agent launch, unmeasured quota disclosed and not blocking'

# Claude to agy on tmux once agy trusts the home; refused before that.
quota_fixture agy 30 through_reset model:gemini > "$QUOTA/agy.json"
run_case tmux --harness agy --model gemini-3-pro
[ "$(cat "$LAB/rc")" = 1 ] || fail 'an untrusted home must refuse an agy successor'
[ ! -e "$LAB/state/attempts" ] || fail 'an untrusted agy home must not launch'
assert_contains "$(cat "$LAB/launch.err")" 'agy does not trust' 'the refusal names the trust gap'
mkdir -p "$HOME/.gemini/antigravity-cli"
jq -n --arg h "$LAB" '{trustedWorkspaces:[$h]}' > "$HOME/.gemini/antigravity-cli/settings.json"
run_case tmux --harness agy --model gemini-3-pro
assert_transferred_to agy 'agy successor'
argv_is 'agy successor' "${MARKERS[@]}" agy --prompt-interactive PROMPT --model gemini-3-pro --dangerously-skip-permissions
run_case orca --harness agy
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail 'agy on orca must refuse before launch'
pass 'claude to agy: trusted home transfers on tmux; untrusted home and orca refuse before launch'

# agy compares the pane's logical cwd, and the successor is started with
# tmux -c $FM_HOME. A physical-only trust entry must not count. When the -c
# path differs from that logical cwd, both must be trusted.
link="$TMP_ROOT/home-link"
ln -s "$LAB" "$link"
logical=$(CDPATH='' cd -- "$link" && pwd -L)
physical=$(CDPATH='' cd -P -- "$link" && pwd -P)
[ "$logical" = "$link" ] || fail "logical cwd '$logical' must be the -c path '$link'"
[ "$logical" != "$physical" ] || fail "symlink fixture did not split logical '$logical' from physical '$physical'"
alt="$link/."
alt_logical=$(CDPATH='' cd -- "$alt" && pwd -L)
[ "$alt" != "$alt_logical" ] || fail "expected '$alt' to differ from its logical cwd '$alt_logical'"
saved_home=$FM_HOME
jq -n --arg p "$physical" '{trustedWorkspaces:[$p]}' > "$HOME/.gemini/antigravity-cli/settings.json"
FM_HOME=$link
run_case tmux --harness agy --model gemini-3-pro
FM_HOME=$saved_home
[ "$(cat "$LAB/rc")" = 1 ] || fail "physical-only trust must refuse a logical home: $(cat "$LAB/launch.err")"
[ ! -e "$LAB/state/attempts" ] || fail 'physical-only trust must not launch'
assert_contains "$(cat "$LAB/launch.err")" 'agy does not trust' 'physical-only trust must name the trust gap'
jq -n --arg l "$logical" '{trustedWorkspaces:[$l]}' > "$HOME/.gemini/antigravity-cli/settings.json"
FM_HOME=$link
run_case tmux --harness agy --model gemini-3-pro
FM_HOME=$saved_home
assert_transferred_to agy 'logical agy trust'
argv_is 'logical agy trust' "${MARKERS[@]}" agy --prompt-interactive PROMPT --model gemini-3-pro --dangerously-skip-permissions
jq -n --arg l "$alt_logical" '{trustedWorkspaces:[$l]}' > "$HOME/.gemini/antigravity-cli/settings.json"
FM_HOME=$alt
run_case tmux --harness agy --model gemini-3-pro
FM_HOME=$saved_home
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail "logical-only trust must refuse when the -c path differs: $(cat "$LAB/launch.err")"
jq -n --arg e "$alt" '{trustedWorkspaces:[$e]}' > "$HOME/.gemini/antigravity-cli/settings.json"
FM_HOME=$alt
run_case tmux --harness agy --model gemini-3-pro
FM_HOME=$saved_home
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail "the exact -c path alone must refuse when it is not the logical cwd: $(cat "$LAB/launch.err")"
jq -n --arg l "$alt_logical" --arg e "$alt" '{trustedWorkspaces:[$l,$e]}' > "$HOME/.gemini/antigravity-cli/settings.json"
FM_HOME=$alt
run_case tmux --harness agy --model gemini-3-pro
FM_HOME=$saved_home
assert_transferred_to agy 'logical and exact -c trust'
pass 'agy trust: physical-only does not count; the logical cwd and a differing -c path must both be trusted'

# Claude account switch: a signed-in declared account with headroom.
run_case tmux --harness claude --account "$TMP_ROOT/acctB" --reason claude_account_switch
assert_transferred_to claude 'account switch'
argv_is 'account switch' "${SHED[@]}" "CLAUDE_CONFIG_DIR=$TMP_ROOT/acctB" claude --dangerously-skip-permissions PROMPT
assert_contains "$(cat "$QUOTA/reads")" "claude profile=1 root=$TMP_ROOT/acctB" 'the preflight measured only the chosen account'
pass 'claude account switch: the successor runs on the chosen declared account'

# An account switch with no --model runs the account's default model, the
# lane the switch measured, never the predecessor's model: that model's own
# row may be the exhausted one. A named --model still wins.
mkdir -p "$TMP_ROOT/acctD"
touch "$TMP_ROOT/acctD/signed-in"
jq -n '{schemaVersion:5,providers:[{provider:"claude",quotaSemantics:{status:"known",effectiveAvailability:[
  {scope:"all_models",status:"known",effectivePercentRemaining:40,runway:{status:"through_reset"}},
  {scope:"model:opus",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"}}]}}]}' > "$TMP_ROOT/acctD/quota.json"
printf '%s\n' "$TMP_ROOT/acctA" "$TMP_ROOT/acctB" "$TMP_ROOT/acctC" "$TMP_ROOT/acctD" > "$LAB/config/claude-accounts"
PRED_ARGS=(--model opus)
run_case tmux --harness claude --account "$TMP_ROOT/acctD" --reason claude_pool_exhausted
assert_transferred_to claude 'account switch from an opus predecessor'
argv_is 'account switch from an opus predecessor' "${SHED[@]}" "CLAUDE_CONFIG_DIR=$TMP_ROOT/acctD" claude --dangerously-skip-permissions PROMPT
assert_contains "$(sed -n 's/^successor=//p' "$LAB/state/.handoff-successor")" 'model=default' 'the switch records the account default model'
assert_contains "$(sed -n 's/^successor=//p' "$LAB/state/.handoff-successor")" 'model_from=account_switch' 'the record says why the model was not carried'
run_case tmux --harness claude --account "$TMP_ROOT/acctB" --model sonnet --reason claude_pool_exhausted
assert_transferred_to claude 'account switch with a named model'
argv_is 'account switch with a named model' "${SHED[@]}" "CLAUDE_CONFIG_DIR=$TMP_ROOT/acctB" claude --dangerously-skip-permissions --model sonnet PROMPT
PRED_ARGS=()
printf '%s\n' "$TMP_ROOT/acctA" "$TMP_ROOT/acctB" "$TMP_ROOT/acctC" > "$LAB/config/claude-accounts"
pass "claude account switch with no --model runs the account's default model, not the predecessor's"

# A tmux pane does not inherit this session's store, so the launch names it.
mkdir -p "$TMP_ROOT/session-claude" "$TMP_ROOT/session-codex"
quota_fixture claude 40 through_reset > "$QUOTA/claude.json"
quota_fixture codex 55 through_reset > "$QUOTA/codex.json"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/session-claude" CODEX_HOME="$TMP_ROOT/session-codex"
run_case tmux
assert_transferred_to claude 'session claude store'
argv_is 'session claude store' env "CLAUDE_CONFIG_DIR=$TMP_ROOT/session-claude" claude --dangerously-skip-permissions PROMPT
run_case tmux --harness codex
assert_transferred_to codex 'session codex home'
argv_is 'session codex home' "${MARKERS[@]}" "CODEX_HOME=$TMP_ROOT/session-codex" FM_CODEX_BIN= "$ROOT/bin/fm-codex-launch.sh" --dangerously-bypass-approvals-and-sandbox PROMPT
run_case tmux --harness claude --account "$TMP_ROOT/acctB"
assert_transferred_to claude 'account over session store'
argv_is 'account over session store' "${SHED[@]}" "CLAUDE_CONFIG_DIR=$TMP_ROOT/acctB" claude --dangerously-skip-permissions PROMPT
unset CLAUDE_CONFIG_DIR CODEX_HOME
run_case tmux
assert_transferred_to claude 'no session claude store'
argv_is 'no session claude store' claude --dangerously-skip-permissions PROMPT
rm -f "$QUOTA/claude.json" "$QUOTA/codex.json"
pass 'tmux successor store: the session CLAUDE_CONFIG_DIR and CODEX_HOME are forwarded, and --account wins'

run_case tmux --account "$TMP_ROOT/acctC"
[ "$(cat "$LAB/rc")" != 0 ] && [ ! -e "$LAB/state/attempts" ] || fail 'a signed-out account must refuse before launch'
assert_contains "$(cat "$LAB/launch.err")" 'not signed in' 'the refusal names the missing sign-in'
run_case tmux --account "$TMP_ROOT/undeclared"
[ "$(cat "$LAB/rc")" != 0 ] && [ ! -e "$LAB/state/attempts" ] || fail 'an undeclared account must refuse'
run_case orca --account "$TMP_ROOT/acctB"
[ "$(cat "$LAB/rc")" != 0 ] && [ ! -e "$LAB/state/attempts" ] || fail 'orca cannot select an account and must refuse'
pass 'account refusals: signed out, undeclared, and orca refuse before launch'

# exhausted_now veto: an exhausted successor pool never launches.
run_case tmux --account "$TMP_ROOT/acctA"
[ "$(cat "$LAB/rc")" = 3 ] || fail "an exhausted account must be vetoed with exit 3: $(cat "$LAB/rc") $(cat "$LAB/launch.err")"
[ ! -e "$LAB/state/attempts" ] || fail 'a vetoed successor must not launch'
[ ! -s "$LAB/state/handoff-events.log" ] || fail 'a veto must not open a handoff claim'
[ "$(cat "$LAB/state/.lock")" = "$(cat "$LAB/pred.pid")" ] || fail 'a veto must keep the predecessor lock'
assert_contains "$(cat "$LAB/state/supervisor-failover.log")" 'event=successor_vetoed' 'the veto is logged'
quota_fixture codex 0 exhausted_now > "$QUOTA/codex.json"
run_case tmux --harness codex
[ "$(cat "$LAB/rc")" = 3 ] && [ ! -e "$LAB/state/attempts" ] || fail 'an exhausted codex pool must be vetoed'
quota_fixture claude 12 exhausted_now > "$QUOTA/claude.json"
run_case tmux
[ "$(cat "$LAB/rc")" = 3 ] && [ ! -e "$LAB/state/attempts" ] || fail 'an exhausted ambient claude pool must be vetoed'
pass 'exhausted_now veto: no successor launches onto an exhausted pool and the predecessor keeps the lock'

# The successor keeps the predecessor's runtime, read from its exact launch argv.
record() { sed -n 's/^successor=//p' "$LAB/state/.handoff-successor"; }
quota_fixture claude 40 through_reset > "$QUOTA/claude.json"
PRED_ARGS=(--setting-sources 'project,local' --model haiku --effort low)
run_case tmux
assert_transferred_to claude 'carried runtime'
argv_is 'carried runtime' claude --dangerously-skip-permissions --model haiku --effort low --setting-sources project,local PROMPT
assert_contains "$(record)" 'harness=claude model=haiku account=ambient reason=handoff' 'the record names the carried model'
assert_contains "$(record)" 'effort=low setting_sources=project,local model_from=predecessor effort_from=predecessor setting_sources_from=predecessor' \
  'the record names each carried value and its source'
assert_contains "$(cat "$LAB/launch.err")" 'successor runtime: model haiku, from the predecessor; effort low, from the predecessor; setting-sources project,local, from the predecessor' \
  'the launcher states the carried runtime'
assert_contains "$(cat "$QUOTA/reads")" 'claude profile=0' 'the preflight still reads the successor quota'
run_case orca
assert_transferred_to claude 'carried runtime on orca'
argv_is 'carried runtime on orca' --agent claude --worktree "path:$LAB" --surface terminal --model haiku --effort low --prompt PROMPT --json
assert_contains "$(record)" 'effort=low setting_sources=default model_from=predecessor effort_from=predecessor setting_sources_from=unsupported' \
  'orca carries model and effort and records that it cannot carry setting sources'
pass 'default successor keeps the predecessor model, effort, and setting sources from its launch argv'

# An explicit choice, such as a quota reroute, wins and is recorded beside the predecessor's value.
run_case tmux --model opus --effort high --reason quota_reroute
assert_transferred_to claude 'explicit override'
argv_is 'explicit override' claude --dangerously-skip-permissions --model opus --effort high --setting-sources project,local PROMPT
assert_contains "$(record)" 'model=opus account=ambient reason=quota_reroute' 'the record names the chosen model and reason'
assert_contains "$(record)" 'effort=high setting_sources=project,local model_from=explicit effort_from=explicit setting_sources_from=predecessor predecessor_model=haiku predecessor_effort=low predecessor_setting_sources=project,local' \
  'the record keeps both the explicit choice and the predecessor value'
assert_contains "$(cat "$LAB/launch.err")" 'model opus, named explicitly (reason=quota_reroute); the predecessor had haiku' \
  'the launcher states the override and what it replaced'
run_case tmux --model default --effort default --setting-sources default
assert_transferred_to claude 'explicit default'
argv_is 'explicit default' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model=default account=ambient' 'an explicit default model is recorded as default'
assert_contains "$(record)" 'model_from=explicit effort_from=explicit setting_sources_from=explicit' 'an explicit default is an explicit choice'
pass 'explicit override wins over the predecessor runtime and is recorded'

# A predecessor that recorded no value keeps today's launch and says so.
PRED_ARGS=()
run_case tmux
assert_transferred_to claude 'unrecorded runtime'
argv_is 'unrecorded runtime' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model=default account=ambient' 'no recorded model keeps the runtime default'
assert_contains "$(record)" 'effort=default setting_sources=default model_from=unrecorded effort_from=unrecorded setting_sources_from=unrecorded predecessor_model=none predecessor_effort=none predecessor_setting_sources=none' \
  'the record says nothing was recorded'
assert_contains "$(cat "$LAB/launch.err")" "model default: the predecessor's launch recorded none, so the runtime's own applies" \
  'the launcher states that the runtime default applies'
pass 'a predecessor with no recorded runtime keeps the runtime default and says so'

# ps joins argv words with blanks, so it is never read: a prompt word such as
# `--model opus` is not a flag. With no exact source nothing is carried.
PROBE_PROMPT='Resume the handoff; the captain said use --model opus --effort max now'
PRED_ARGS=("$PROBE_PROMPT")
FM_TEST_EXACT_ARGV=0 run_case tmux
assert_transferred_to claude 'quoted prompt, no exact source'
argv_is 'quoted prompt, no exact source' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model=default account=ambient' 'a quoted prompt adds no model override'
assert_contains "$(record)" 'effort=default setting_sources=default model_from=unreadable effort_from=unreadable setting_sources_from=unreadable predecessor_model=unknown' \
  'with no exact source every value is recorded as unreadable'
assert_contains "$(cat "$LAB/launch.err")" "model default: the predecessor's launch value could not be read" 'the launcher states the unreadable value'
run_case tmux
assert_transferred_to claude 'quoted prompt, exact argv'
argv_is 'quoted prompt, exact argv' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model_from=unrecorded effort_from=unrecorded' 'an exact argv reads the quoted prompt as one word'
mkdir -p "$TMP_ROOT/proc"
printf 'claude\0%s\0--setting-sources\0\0--model\0haiku\0--effort\0max\0' "$LAB/predecessor.sh" > "$TMP_ROOT/cmdline"
PRED_ARGS=()
FM_HANDOFF_TEST_PROC_ROOT="$TMP_ROOT/proc" FM_TEST_FAKE_CMDLINE="$TMP_ROOT/cmdline" run_case tmux
assert_transferred_to claude 'exact cmdline'
argv_is 'exact cmdline' claude --dangerously-skip-permissions --model haiku --effort max --setting-sources '' PROMPT
assert_contains "$(record)" 'effort=max setting_sources=empty model_from=predecessor effort_from=predecessor setting_sources_from=predecessor' \
  'an exact empty value is carried'
pass 'predecessor argv: a quoted prompt never adds an override, an exact cmdline carries an empty value'

# The verified launch record that started this session is its recorded launch.
PRED_ARGS=()
FM_TEST_EXACT_ARGV=0 FM_TEST_PRED_RECORD='harness=claude model=claude-opus-4-6[1m] account=ambient reason=handoff effort=high setting_sources=empty model_from=predecessor' \
  run_case tmux
assert_transferred_to claude 'recorded launch'
argv_is 'recorded launch' claude --dangerously-skip-permissions --model 'claude-opus-4-6[1m]' --effort high --setting-sources '' PROMPT
assert_contains "$(record)" 'effort=high setting_sources=empty model_from=predecessor effort_from=predecessor setting_sources_from=predecessor' \
  'the recorded launch carries each value'
FM_TEST_EXACT_ARGV=0 FM_TEST_PRED_RECORD='harness=claude model=default account=ambient effort=default setting_sources=default' run_case tmux
assert_transferred_to claude 'recorded defaults'
argv_is 'recorded defaults' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model_from=unrecorded effort_from=unrecorded setting_sources_from=unrecorded' 'a recorded default is no value'
FM_TEST_EXACT_ARGV=0 FM_TEST_PRED_RECORD='harness=claude model=haiku effort=low' FM_TEST_PRED_RECORD_PID=1 run_case tmux
assert_transferred_to claude 'record for another session'
argv_is 'record for another session' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model_from=unreadable' 'a record naming another session is not this launch'
FM_TEST_EXACT_ARGV=0 FM_TEST_PRED_RECORD='harness=codex model=gpt-5.5 effort=xhigh' run_case tmux
assert_transferred_to claude 'record for another harness'
argv_is 'record for another harness' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model_from=unreadable' 'a record naming another harness is not this launch'
pass 'the verified launch record of the current lock holder carries its runtime; any other record carries nothing'

# A context-suffixed Claude model id, such as opus[1m], carries and can be named.
PRED_ARGS=(--model 'claude-opus-4-6[1m]')
run_case tmux
assert_transferred_to claude 'bracketed model carry'
argv_is 'bracketed model carry' claude --dangerously-skip-permissions --model 'claude-opus-4-6[1m]' PROMPT
assert_contains "$(record)" 'model=claude-opus-4-6[1m] account=ambient' 'the record names the bracketed model'
PRED_ARGS=()
run_case tmux --model 'opus[1m]'
assert_transferred_to claude 'bracketed model named'
argv_is 'bracketed model named' claude --dangerously-skip-permissions --model 'opus[1m]' PROMPT
pass 'a bracketed model id carries from the predecessor and can be named explicitly'

# A Codex predecessor's model and reasoning effort carry; a harness change carries nothing.
quota_fixture codex 55 through_reset > "$QUOTA/codex.json"
PRED_HARNESS=codex
PRED_ARGS=(-c 'shell_environment_policy.set.TMUX_PANE="%2"' --model gpt-5.5 -c 'model_reasoning_effort="xhigh"')
FM_HANDOFF_TEST_HARNESS=codex run_case tmux
assert_transferred_to codex 'codex carry'
argv_is 'codex carry' "${MARKERS[@]}" -u CODEX_HOME FM_CODEX_BIN= "$ROOT/bin/fm-codex-launch.sh" --model gpt-5.5 -c 'model_reasoning_effort="xhigh"' --dangerously-bypass-approvals-and-sandbox PROMPT
assert_contains "$(record)" 'effort=xhigh setting_sources=default model_from=predecessor effort_from=predecessor setting_sources_from=unrecorded' \
  'the codex record names the carried model and effort'
PRED_ARGS=(--model gpt-5.5 -c 'model_reasoning_effort="minimal"')
FM_HANDOFF_TEST_HARNESS=codex run_case tmux
assert_transferred_to codex 'codex minimal carry'
argv_is 'codex minimal carry' "${MARKERS[@]}" -u CODEX_HOME FM_CODEX_BIN= "$ROOT/bin/fm-codex-launch.sh" --model gpt-5.5 -c 'model_reasoning_effort="minimal"' --dangerously-bypass-approvals-and-sandbox PROMPT
assert_contains "$(record)" 'effort=minimal setting_sources=default model_from=predecessor effort_from=predecessor' \
  'a codex minimal effort carries'
FM_HANDOFF_TEST_HARNESS=codex run_case tmux --effort max
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail 'codex cannot take --effort max and must refuse before launch'
[ ! -s "$LAB/state/handoff-events.log" ] || fail 'a refused codex effort must not open a handoff claim'
assert_contains "$(cat "$LAB/launch.err")" '--effort for a codex successor must be default or one of: minimal low medium high xhigh' \
  'the refusal names the codex effort levels'
PRED_ARGS=(--model gpt-5.5 -c 'model_reasoning_effort="xhigh"')
FM_HANDOFF_TEST_HARNESS=codex run_case tmux --harness claude
assert_transferred_to claude 'harness change'
argv_is 'harness change' claude --dangerously-skip-permissions PROMPT
assert_contains "$(record)" 'model_from=harness_change effort_from=harness_change setting_sources_from=harness_change predecessor_model=gpt-5.5 predecessor_effort=xhigh' \
  'a harness change records the predecessor runtime it did not carry'
PRED_HARNESS=claude
PRED_ARGS=()
rm -f "$QUOTA/claude.json" "$QUOTA/codex.json"
pass 'codex predecessor carries model and effort; a harness change carries nothing and says so'

# Values a successor cannot carry are refused before launch when named.
run_case tmux --harness agy --effort high
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail 'agy cannot carry --effort and must refuse before launch'
run_case orca --setting-sources project
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail 'orca cannot carry --setting-sources and must refuse before launch'
run_case orca --effort high
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail 'orca --effort without --model must refuse before launch'
assert_contains "$(cat "$LAB/launch.err")" '--effort on Orca needs --model too' 'the refusal names the missing model'
run_case tmux --effort turbo
[ "$(cat "$LAB/rc")" = 1 ] && [ ! -e "$LAB/state/attempts" ] || fail 'an unknown effort must refuse'
pass 'uncarriable or invalid runtime options refuse before launch'

PINS_AFTER=$(pins_digest)
[ "$PINS_AFTER" = "$PINS_BEFORE" ] || fail "account pins and the account list must be unchanged: before=[$PINS_BEFORE] after=[$PINS_AFTER]"
[ ! -e "$LAB/config/claude-account" ] || fail 'no Claude pin may be created'
pass 'pin preservation: no account pin or account list changed'
