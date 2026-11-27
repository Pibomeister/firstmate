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
. "{run-worktree}/tests/lib.sh"
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
    "$LAB/state/supervisor-failover.log" "$LAB/rc" "$LAB/ack.out" "$LAB/pred.pid" "$QUOTA/reads"
  printf '%s\n' "$backend" > "$LAB/config/backend"
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$LAB/launch.args"; else rm -f "$LAB/launch.args"; fi
  ("$PRED_HARNESS" "$LAB/predecessor.sh" ${PRED_ARGS[@]+"${PRED_ARGS[@]}"} & echo "$!" >> "$FM_TEST_PIDS")
  limit=$((SECONDS + 200))
  while [ ! -f "$LAB/rc" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
  [ -f "$LAB/rc" ] || fail "launcher did not finish: $(cat "$LAB/launch.err" 2>/dev/null)"
}
assert_transferred_to() { # <harness> <label>
  [ "$(cat "$LAB/rc")" = 0 ] || fail "$2: handoff must complete: $(cat "$LAB/launch.err") $(cat "$LAB/ack.out" 2>/dev/null)"
  local pid
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
# --- two-hop scenario (evidence only) ---
# The first successor acks, then (once) runs the real launcher itself with no
# runtime options, as a later handoff of that session would.
cat > "$LAB/successor.sh" <<'EOF2'
#!/usr/bin/env bash
set -eu
nonce=$(jq -r .nonce "$FM_HOME/state/.handoff-pending")
sha=$(jq -r .sha256 "$FM_HOME/state/.handoff-pending")
hop=$(cat "$FM_HOME/hop" 2>/dev/null || echo 1)
bash "$ROOT/bin/fm-handoff-ack.sh" "$nonce" "$sha" > "$FM_HOME/ack$hop.out" 2>&1 || true
if [ "$hop" = 1 ] && [ -f "$FM_HOME/do-hop2" ]; then
  echo 2 > "$FM_HOME/hop"
  # A later handoff: wait until hop 1 has recorded this session as its successor.
  until [ "$(sed -n 's/^pid=//p' "$FM_HOME/state/.handoff-successor" 2>/dev/null)" = "$$" ] || [ "$SECONDS" -gt 600 ]; do sleep 0.5; done
  cp "$FM_HOME/state/.handoff-successor" "$FM_HOME/hop1.record" 2>/dev/null || true
  cp "$FM_HOME/state/argv" "$FM_HOME/hop1.argv"
  echo "$$" > "$FM_HOME/hop1.pid"
  set +e
  bash "$ROOT/bin/fm-handoff-launch.sh" "$FM_HOME/data/handoff.md" > "$FM_HOME/hop2.out" 2> "$FM_HOME/hop2.err"
  echo "$?" > "$FM_HOME/hop2.rc"
fi
while kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null && [ "$SECONDS" -lt 900 ]; do sleep 1; done
EOF2
FM_HANDOFF_SUCCESSOR_TIMEOUT_SECS=300
quota_fixture claude 40 through_reset > "$QUOTA/claude.json"
rm -f "$LAB/config/claude-accounts"
rm -f "$LAB/hop" "$LAB/hop2.rc"; touch "$LAB/do-hop2"
PRED_ARGS=()
FM_TEST_EXACT_ARGV=0 run_case tmux --model haiku --effort low --reason quota_reroute
assert_transferred_to claude 'hop 1'
limit=$((SECONDS + 400)); while [ ! -f "$LAB/hop2.rc" ] && [ "$SECONDS" -lt "$limit" ]; do sleep 0.5; done
echo "== hop 1 successor argv:"; cat "$LAB/hop1.argv" | sed '$s/^\(.\{60\}\).*/\1.../'
echo "== hop 1 record:"; cat "$LAB/hop1.record" || true
echo "== hop 2 rc=$(cat "$LAB/hop2.rc" 2>/dev/null || echo none)"
echo "== hop 2 launcher stderr:"; cat "$LAB/hop2.err"
echo "== hop 2 successor argv:"; sed '$s/^\(.\{60\}\).*/\1.../' "$LAB/state/argv"
echo "== hop 2 record:"; cat "$LAB/state/.handoff-successor"
[ "$(cat "$LAB/hop2.rc")" = 0 ] || fail 'hop 2 must complete'
[ "$(cat "$LAB/hop1.pid")" != "$(cat "$LAB/state/.lock")" ] || fail 'hop 2 lock did not move'
argv_is 'hop 2' claude --dangerously-skip-permissions --model haiku --effort low PROMPT
assert_contains "$(sed -n 's/^successor=//p' "$LAB/state/.handoff-successor")" 'model=haiku' 'hop 2 carries the model'
assert_contains "$(sed -n 's/^successor=//p' "$LAB/state/.handoff-successor")" 'effort=low setting_sources=default model_from=predecessor effort_from=predecessor setting_sources_from=unrecorded' 'hop 2 records the record as the source'
pass 'two-hop: a named model and effort survive a second handoff with no options, read from the verified record'
