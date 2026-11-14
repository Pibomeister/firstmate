#!/usr/bin/env bash
# tests/fm-orca-cli-cache.test.sh - read-only Orca CLI reuse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-cli-cache)
export FM_ORCA_CLI_CACHE_DIR="$TMP_ROOT/cache"
mkdir -p "$FM_ORCA_CLI_CACHE_DIR"

setup_case() { # <name>
  CASE="$TMP_ROOT/$1"
  rm -rf "$CASE" "$FM_ORCA_CLI_CACHE_DIR"
  mkdir -p "$CASE/fakebin" "$FM_ORCA_CLI_CACHE_DIR"
  LOG="$CASE/log"
  COUNT="$CASE/count"
  LIST="$CASE/list.json"
  : > "$LOG"
  : > "$COUNT"
  CACHE_SWITCH=1
  CACHE_TTL=3
  FM_ORCA_READ_EXIT=0
  FM_ORCA_LIST_EXIT=0
  FM_ORCA_READ_BODY=
  FM_ORCA_READ_ERR=
  FM_ORCA_SHOW_BODY=
  FM_ORCA_MEMORY_BODY=
  FM_ORCA_HOLD=
  printf '%s\n' '{"ok":true,"result":{"truncated":false,"terminals":[{"handle":"term-a","id":"id-a"},{"handle":"term-b"}]}}' > "$LIST"
  cat > "$CASE/fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG=${FM_ORCA_LOG:?}
COUNT=${FM_ORCA_COUNT:?}
printf '.\n' >> "$COUNT"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ -n "${FM_ORCA_HOLD:-}" ]; then
  touch "$FM_ORCA_HOLD"
  i=0
  while [ ! -f "${FM_ORCA_HOLD}.release" ]; do
    i=$((i + 1))
    [ "$i" -gt 400 ] && break
    sleep 0.05
  done
fi
if [ "${1:-} ${2:-}" = "terminal list" ]; then
  cat "${FM_ORCA_LIST:?}"
  exit "${FM_ORCA_LIST_EXIT:-0}"
fi
if [ "${1:-} ${2:-}" = "terminal show" ] && [ -n "${FM_ORCA_SHOW_BODY:-}" ]; then
  printf '%s\n' "$FM_ORCA_SHOW_BODY"
  exit 0
fi
if [ "${1:-} ${2:-}" = "diagnostics memory" ] && [ -n "${FM_ORCA_MEMORY_BODY:-}" ]; then
  printf '%s\n' "$FM_ORCA_MEMORY_BODY"
  exit 0
fi
if [ "${1:-} ${2:-}" = "terminal read" ] && [ -n "${FM_ORCA_DISTINCT:-}" ]; then
  term=
  prev=
  for a in "$@"; do
    if [ "$prev" = "--terminal" ]; then
      term=$a
    fi
    prev=$a
  done
  mkdir -p "${FM_ORCA_RENDEZVOUS:?}"
  touch "${FM_ORCA_RENDEZVOUS}/$term"
  i=0
  while [ ! -f "${FM_ORCA_RENDEZVOUS}/term-a" ] || [ ! -f "${FM_ORCA_RENDEZVOUS}/term-b" ]; do
    i=$((i + 1))
    [ "$i" -gt 400 ] && break
    sleep 0.05
  done
  printf '%s\n' "{\"ok\":true,\"result\":{\"text\":\"$term\"}}"
  touch "${FM_ORCA_RENDEZVOUS}/wrote-$term"
  i=0
  while [ ! -f "${FM_ORCA_RENDEZVOUS}/wrote-term-a" ] || [ ! -f "${FM_ORCA_RENDEZVOUS}/wrote-term-b" ]; do
    i=$((i + 1))
    [ "$i" -gt 400 ] && break
    sleep 0.05
  done
  exit 0
fi
if [ "${1:-} ${2:-}" = "terminal read" ]; then
  if [ -n "${FM_ORCA_READ_ERR:-}" ]; then
    printf '%s\n' "$FM_ORCA_READ_ERR" >&2
  fi
  if [ -n "${FM_ORCA_READ_BODY:-}" ]; then
    printf '%s\n' "$FM_ORCA_READ_BODY"
  else
    printf '%s\n' '{"ok":true,"result":{"text":"tail"}}'
  fi
  exit "${FM_ORCA_READ_EXIT:-0}"
fi
if [ "${1:-} ${2:-}" = "terminal send" ] || [ "${1:-} ${2:-}" = "terminal wait" ]; then
  printf '%s\n' '{"ok":true}'
  exit 0
fi
printf '%s\n' '{"ok":true}'
exit 0
SH
  chmod +x "$CASE/fakebin/orca"
}

calls() {
  wc -l < "$COUNT" | tr -d ' '
}

# Run fm_orca_cli inside a fresh bash so the helper sees this case's PATH.
run_cli() {
  PATH="$CASE/fakebin:$PATH" \
    FM_ORCA_CLI_CACHE="${CACHE_SWITCH:-1}" \
    FM_ORCA_CLI_CACHE_TTL="${CACHE_TTL:-3}" \
    FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" \
    FM_ORCA_COUNT="$COUNT" \
    FM_ORCA_LIST="$LIST" \
    FM_ORCA_LIST_EXIT="${FM_ORCA_LIST_EXIT:-0}" \
    FM_ORCA_READ_BODY="${FM_ORCA_READ_BODY:-}" \
    FM_ORCA_READ_ERR="${FM_ORCA_READ_ERR:-}" \
    FM_ORCA_SHOW_BODY="${FM_ORCA_SHOW_BODY:-}" \
    FM_ORCA_MEMORY_BODY="${FM_ORCA_MEMORY_BODY:-}" \
    FM_ORCA_READ_EXIT="${FM_ORCA_READ_EXIT:-0}" \
    FM_ORCA_HOLD="${FM_ORCA_HOLD:-}" \
    bash -c '. "$1"; shift; fm_orca_cli "$@"' _ "$ROOT/bin/fm-orca-cli-cache.sh" "$@"
}

run_exists() {
  PATH="$CASE/fakebin:$PATH" \
    FM_ORCA_CLI_CACHE="${CACHE_SWITCH:-1}" \
    FM_ORCA_CLI_CACHE_TTL="${CACHE_TTL:-3}" \
    FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" \
    FM_ORCA_COUNT="$COUNT" \
    FM_ORCA_LIST="$LIST" \
    FM_ORCA_LIST_EXIT="${FM_ORCA_LIST_EXIT:-0}" \
    bash -c '. "$1"; shift; fm_orca_terminal_exists "$@"' _ "$ROOT/bin/fm-orca-cli-cache.sh" "$@"
}

run_backend_probe() {
  PATH="$CASE/fakebin:$PATH" \
    FM_ORCA_CLI_CACHE="${CACHE_SWITCH:-1}" \
    FM_ORCA_CLI_CACHE_TTL="${CACHE_TTL:-3}" \
    FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" FM_ORCA_COUNT="$COUNT" FM_ORCA_LIST="$LIST" \
    FM_ORCA_READ_BODY="${FM_ORCA_READ_BODY:-}" \
    FM_ORCA_READ_EXIT="${FM_ORCA_READ_EXIT:-0}" \
    FM_ORCA_SHOW_BODY="${FM_ORCA_SHOW_BODY:-}" \
    FM_ORCA_MEMORY_BODY="${FM_ORCA_MEMORY_BODY:-}" \
    FM_STATE_OVERRIDE="$CASE/state" \
    FM_COMPOSER_CAPTURE_LINES=7 \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; shift; fm_backend_source orca; "$@"' _ "$ROOT" "$@"
}

test_live_capture_proofs_ignore_cached_snapshots() {
  local body
  setup_case live-composer
  CACHE_TTL=120
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"before"}}'
  run_cli terminal read --terminal term-a --limit 7 --json >/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"after"}}'
  body=$(run_backend_probe fm_backend_orca_composer_capture term-a)
  assert_equals after "$body" "the composer proof reused an old frame"

  setup_case live-feedback
  CACHE_TTL=120
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"before"}}'
  run_cli terminal read --terminal term-a --limit 60 --json >/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"after"}}'
  body=$(run_backend_probe fm_control_capture_feedback_pane orca term-a)
  assert_equals after "$body" "the action-time dialog recapture reused an old frame"

  setup_case live-viewport
  CACHE_TTL=120
  mkdir -p "$CASE/state"
  printf 'harness=droid\nterminal=term-a\n' > "$CASE/state/task-aa.meta"
  FM_ORCA_READ_BODY='{"ok":true,"result":{"terminal":{"source":"screen","tail":["before"],"draft":""}}}'
  run_cli terminal read --terminal term-a --screen --json >/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"terminal":{"source":"screen","tail":["after"],"draft":""}}}'
  body=$(run_backend_probe fm_backend_orca_visible_capture term-a fm-task-aa)
  assert_equals after "$body" "the current viewport reused an old frame"
  pass "action-time capture proofs read current frames despite cached observations"
}

test_session_proofs_ignore_cached_terminal_facts() {
  local facts pid
  setup_case live-session
  CACHE_TTL=120
  FM_ORCA_SHOW_BODY='{"ok":true,"result":{"terminal":{"handle":"term-a","connected":true,"writable":true,"executionHostId":"local","ptyId":"pty-old","worktreePath":"/fixture"}}}'
  run_cli terminal show --terminal term-a --json >/dev/null
  FM_ORCA_SHOW_BODY='{"ok":true,"result":{"terminal":{"handle":"term-a","connected":true,"writable":true,"executionHostId":"local","ptyId":"pty-new","worktreePath":"/fixture"}}}'
  facts=$(run_backend_probe fm_backend_orca_terminal_facts term-a)
  assert_contains "$facts" $'\x1fpty-new\x1f' "the final terminal proof reused the replaced session"
  FM_ORCA_MEMORY_BODY='{"ok":true,"result":{"worktrees":[{"sessions":[{"sessionId":"pty-new","pid":111111}]}]}}'
  run_cli diagnostics memory --json >/dev/null
  FM_ORCA_MEMORY_BODY='{"ok":true,"result":{"worktrees":[{"sessions":[{"sessionId":"pty-new","pid":222222}]}]}}'
  pid=$(run_backend_probe fm_backend_orca_session_pid pty-new)
  assert_equals 222222 "$pid" "the final process proof reused the replaced process"
  pass "Orca session proofs read current terminal and process facts despite cached observations"
}

test_draft_probe_does_not_reuse_an_empty_snapshot() {
  local body
  setup_case live-draft
  CACHE_TTL=120
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"prompt","draft":""}}'
  run_cli terminal read --terminal term-a --limit 7 --json >/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"prompt","draft":"operator input"}}'
  run_backend_probe fm_backend_orca_draft_present term-a || fail "draft clearance reused an empty snapshot after input appeared"
  assert_equals 2 "$(calls)" "draft clearance did not read the live terminal"
  body=$(run_cli terminal read --terminal term-a --limit 7 --json)
  assert_equals '{"ok":true,"result":{"text":"prompt","draft":""}}' "$body" \
    "draft clearance changed the ordinary polling cache"
  assert_equals 2 "$(calls)" "ordinary polling stopped reusing its snapshot"
  FM_ORCA_READ_EXIT=1
  run_backend_probe fm_backend_orca_draft_present term-a || fail "a failed live draft read did not hold the send"
  FM_ORCA_READ_EXIT=0
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"prompt","draft":""}}'
  if run_backend_probe fm_backend_orca_draft_present term-a; then
    fail "an empty live draft did not clear after the failed read"
  fi
  pass "fm_backend_orca_draft_present: live input and read failures hold despite an empty cached snapshot"
}

test_zero_ttl_bypasses_an_existing_entry() {
  local body
  setup_case zero-ttl
  CACHE_TTL=120
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"cached"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  CACHE_TTL=0
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"fresh"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals '{"ok":true,"result":{"text":"fresh"}}' "$body" \
    "zero TTL replayed a result stored by a positive-TTL caller"
  assert_equals 2 "$(calls)" "zero TTL did not reach the CLI"
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"newer"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals '{"ok":true,"result":{"text":"newer"}}' "$body" \
    "zero TTL stored or replayed a previous live result"
  assert_equals 3 "$(calls)" "a second zero-TTL read did not reach the CLI"
  pass "fm_orca_cli: zero TTL bypasses stored results on every read"
}

test_pending_generation_invalidation_disables_replay() {
  local body
  setup_case pending-generation
  CACHE_TTL=120
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"before"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  mkdir "$FM_ORCA_CLI_CACHE_DIR/gen.lock"
  run_cli terminal send --terminal term-a --text x --json >/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"after"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals '{"ok":true,"result":{"text":"after"}}' "$body" \
    "a mutation whose invalidation timed out left an old snapshot reusable"
  assert_equals 3 "$(calls)" "the read after failed invalidation did not reach the CLI"
  fm_touch_epoch "$(( $(date +%s) - 30 ))" "$FM_ORCA_CLI_CACHE_DIR/gen.lock"
  run_cli terminal send --terminal term-a --text y --json >/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"recovered"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals '{"ok":true,"result":{"text":"recovered"}}' "$body" \
    "generation recovery did not publish the current snapshot"
  assert_equals 5 "$(calls)" "cache reuse did not resume after generation recovery"
  pass "fm_orca_cli: pending invalidation bypasses snapshots and successful recovery restores reuse"
}

test_failed_generation_publish_rejects_an_old_inflight_result() {
  local real_mv reader body i failure=${1:-rename}
  setup_case failed-generation
  CACHE_TTL=120
  real_mv=$(command -v mv)
  if [ "$failure" = directory ]; then
    mkdir "$FM_ORCA_CLI_CACHE_DIR/gen"
  else
    {
      printf '%s\n' '#!/usr/bin/env bash' 'for last; do :; done' \
        '[ "$last" != "$FM_ORCA_CLI_CACHE_DIR/gen" ] || exit 1'
      printf 'exec %q "$@"\n' "$real_mv"
    } > "$CASE/fakebin/mv"
    chmod +x "$CASE/fakebin/mv"
  fi
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"before"}}'
  FM_ORCA_HOLD="$CASE/read-held"
  run_cli terminal read --terminal term-a --limit 1 --json > "$CASE/held.out" &
  reader=$!
  i=0
  while [ ! -f "$FM_ORCA_HOLD" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$FM_ORCA_HOLD" ] || fail "the in-flight read did not start"
  FM_ORCA_HOLD=
  run_cli terminal send --terminal term-a --text x --json >/dev/null
  touch "$CASE/read-held.release"
  wait "$reader"
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"after"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals '{"ok":true,"result":{"text":"after"}}' "$body" \
    "a failed generation publication let an old in-flight result survive a mutation"
  pass "fm_orca_cli: a failed generation publication cannot make an old in-flight result reusable"
}

test_generation_directory_rejects_an_old_inflight_result() {
  test_failed_generation_publish_rejects_an_old_inflight_result directory
}

test_cache_hit_reuses_one_read() {
  local first second
  setup_case hit
  CACHE_SWITCH=1
  first=$(run_cli terminal read --terminal term-a --limit 1 --json)
  second=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals "$first" "$second" "second read changed the cached body"
  assert_equals 1 "$(calls)" "a repeated read booted the CLI again"
  pass "fm_orca_cli: a repeated read reuses one CLI result"
}

test_ttl_expiry_reads_again() {
  setup_case ttl
  CACHE_SWITCH=1
  CACHE_TTL=1
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  sleep 2
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 2 "$(calls)" "a read inside the TTL window was not reused, or an expired one was"
  pass "fm_orca_cli: a read past the TTL boots the CLI again"
}

test_mutation_invalidates_cached_read() {
  setup_case mutate
  CACHE_SWITCH=1
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  run_cli terminal send --terminal term-a --text x --json >/dev/null
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 3 "$(calls)" "a send did not drop the cached read"
  pass "fm_orca_cli: a mutating command drops cached reads"
}

test_read_during_mutation_is_not_reused_after_it() {
  local i
  setup_case mutate-race
  CACHE_SWITCH=1
  FM_ORCA_HOLD="$CASE/hold"
  run_cli terminal send --terminal term-a --text x --json >/dev/null &
  i=0
  while [ ! -f "$FM_ORCA_HOLD" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$FM_ORCA_HOLD" ] || fail "the send never reached the CLI"
  FM_ORCA_HOLD=
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  touch "$CASE/hold.release"
  wait
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 3 "$(calls)" "a read taken while the send ran was reused after the send finished"
  pass "fm_orca_cli: a read taken during a mutation is dropped when it finishes"
}

test_direct_mutation_drops_the_cache_before_the_command() {
  local body i
  setup_case pre-mutate
  CACHE_SWITCH=1
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"before"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  FM_ORCA_HOLD="$CASE/hold"
  PATH="$CASE/fakebin:$PATH" \
    FM_ORCA_CLI_CACHE=1 \
    FM_ORCA_CLI_CACHE_TTL=3 \
    FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" \
    FM_ORCA_COUNT="$COUNT" \
    FM_ORCA_LIST="$LIST" \
    FM_ORCA_READ_BODY="$FM_ORCA_READ_BODY" \
    FM_ORCA_HOLD="$FM_ORCA_HOLD" \
    bash -c '. "$1"; fm_orca_cli_mutation command orca "$@"' \
    _ "$ROOT/bin/fm-orca-cli-cache.sh" terminal send --terminal term-a --text x --json >/dev/null &
  i=0
  while [ ! -f "$FM_ORCA_HOLD" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$FM_ORCA_HOLD" ] || fail "the direct mutation never reached the CLI"
  FM_ORCA_HOLD=
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"during"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  touch "$CASE/hold.release"
  wait
  assert_equals '{"ok":true,"result":{"text":"during"}}' "$body" \
    "a read reused the result cached before the direct mutation started"
  pass "fm_orca_cli_mutation: a cached read is dropped before the command runs"
}

test_two_fills_in_one_shell_keep_their_own_bodies() {
  local a b
  setup_case split-fill
  mkdir -p "$CASE/rendezvous"
  PATH="$CASE/fakebin:$PATH" \
    FM_ORCA_CLI_CACHE=1 \
    FM_ORCA_CLI_CACHE_TTL=3 \
    FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" \
    FM_ORCA_COUNT="$COUNT" \
    FM_ORCA_LIST="$LIST" \
    FM_ORCA_DISTINCT=1 \
    FM_ORCA_RENDEZVOUS="$CASE/rendezvous" \
    bash -c '. "$1"; ( fm_orca_cli terminal read --terminal term-a --limit 1 --json > "$2/a.out"; : ) & ( fm_orca_cli terminal read --terminal term-b --limit 1 --json > "$2/b.out"; : ) & wait' \
    _ "$ROOT/bin/fm-orca-cli-cache.sh" "$CASE"
  a=$(cat "$CASE/a.out")
  b=$(cat "$CASE/b.out")
  assert_equals '{"ok":true,"result":{"text":"term-a"}}' "$a" \
    "the term-a fill returned another fill's body"
  assert_equals '{"ok":true,"result":{"text":"term-b"}}' "$b" \
    "the term-b fill returned another fill's body"
  assert_equals 2 "$(calls)" "the two fills did not both reach the CLI"
  pass "fm_orca_cli: two fills in one shell keep their own bodies"
}

test_unreadable_cached_stdout_is_a_miss() {
  local body entry
  setup_case unreadable
  CACHE_SWITCH=1
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"first"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  entry=$(find "$FM_ORCA_CLI_CACHE_DIR" -type f -name stdout | head -n 1)
  [ -n "$entry" ] || fail "the read was not stored"
  chmod 000 "$entry" || fail "could not make the cached stdout unreadable"
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"second"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  chmod u+r "$entry" 2>/dev/null || true
  assert_equals '{"ok":true,"result":{"text":"second"}}' "$body" \
    "an unreadable cache entry was served as an empty hit"
  assert_equals 2 "$(calls)" "an unreadable cache entry was not read again from the CLI"
  pass "fm_orca_cli: an unreadable cached stdout is a miss"
}

test_cache_hit_replays_stderr() {
  local body err
  setup_case stderr-hit
  CACHE_SWITCH=1
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"cached"}}'
  FM_ORCA_READ_ERR='cached-stderr'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null 2>/dev/null
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"fresh"}}'
  FM_ORCA_READ_ERR='fresh-stderr'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json 2>"$CASE/err")
  err=$(cat "$CASE/err")
  assert_equals '{"ok":true,"result":{"text":"cached"}}' "$body" \
    "a cache hit did not replay stdout"
  assert_equals "cached-stderr" "$err" \
    "a cache hit did not replay stderr"
  assert_equals 1 "$(calls)" "a cache hit booted the CLI again"
  pass "fm_orca_cli: a cache hit replays stdout and stderr"
}

test_unreadable_cached_stderr_emits_nothing() {
  local body entry err
  setup_case unreadable-err
  CACHE_SWITCH=1
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"cached"}}'
  FM_ORCA_READ_ERR='cached-stderr'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null 2>/dev/null
  entry=$(find "$FM_ORCA_CLI_CACHE_DIR" -type f -name stderr | head -n 1)
  [ -n "$entry" ] || fail "the read did not store stderr"
  chmod 000 "$entry" || fail "could not make the cached stderr unreadable"
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"fresh"}}'
  FM_ORCA_READ_ERR='fresh-stderr'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json 2>"$CASE/err")
  err=$(cat "$CASE/err")
  chmod u+r "$entry" 2>/dev/null || true
  assert_equals '{"ok":true,"result":{"text":"fresh"}}' "$body" \
    "an unreadable stderr replay emitted cached stdout"
  assert_not_contains "$err" "cached-stderr" \
    "an unreadable stderr replay emitted cached stderr"
  assert_equals 2 "$(calls)" "an unreadable stderr was treated as a hit"
  pass "fm_orca_cli: an unreadable cached stderr emits nothing and is a miss"
}

test_missing_cached_stderr_is_a_miss() {
  local body entry
  setup_case missing-err
  CACHE_SWITCH=1
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"cached"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  entry=$(find "$FM_ORCA_CLI_CACHE_DIR" -type f -name stderr | head -n 1)
  [ -n "$entry" ] || fail "the read did not store stderr"
  rm -f "$entry" || fail "could not remove the cached stderr"
  FM_ORCA_READ_BODY='{"ok":true,"result":{"text":"fresh"}}'
  body=$(run_cli terminal read --terminal term-a --limit 1 --json)
  assert_equals '{"ok":true,"result":{"text":"fresh"}}' "$body" \
    "a missing stderr replay emitted cached stdout"
  assert_equals 2 "$(calls)" "a missing stderr file was treated as a hit"
  pass "fm_orca_cli: a missing cached stderr is a miss"
}

test_symlinked_cache_dir_is_bypassed() {
  setup_case symlink
  CACHE_SWITCH=1
  rm -rf "$FM_ORCA_CLI_CACHE_DIR"
  mkdir -p "$CASE/elsewhere"
  ln -s "$CASE/elsewhere" "$FM_ORCA_CLI_CACHE_DIR"
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 2 "$(calls)" "a symlinked cache directory was trusted for reuse"
  assert_equals "" "$(ls -A "$CASE/elsewhere")" "the cache wrote through a symlinked directory"
  rm -f "$FM_ORCA_CLI_CACHE_DIR"
  pass "fm_orca_cli: a symlinked cache directory is not used"
}

test_different_args_do_not_share_a_read() {
  setup_case args
  CACHE_SWITCH=1
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  run_cli terminal read --terminal term-a --limit 40 --json >/dev/null
  assert_equals 2 "$(calls)" "different read arguments shared one cache entry"
  pass "fm_orca_cli: the cache key includes the arguments"
}

test_failed_read_is_not_cached() {
  local rc
  setup_case fail-read
  CACHE_SWITCH=1
  FM_ORCA_READ_EXIT=1
  rc=0
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a failing read returned success"
  rc=0
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "the second failing read returned success"
  assert_equals 2 "$(calls)" "a failed read was reused"
  pass "fm_orca_cli: a failed read is not reused"
}

test_ok_false_is_not_cached() {
  setup_case ok-false
  CACHE_SWITCH=1
  FM_ORCA_READ_BODY='{"ok":false,"error":{"code":"terminal_handle_stale"}}'
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 2 "$(calls)" "ok:false JSON was reused"
  pass "fm_orca_cli: ok:false JSON is not reused"
}

test_wait_does_not_invalidate_or_cache() {
  setup_case wait
  CACHE_SWITCH=1
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  run_cli terminal wait --terminal term-a --for tui-idle --timeout-ms 500 --json >/dev/null
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 2 "$(calls)" "terminal wait was cached or dropped the cached read"
  pass "fm_orca_cli: terminal wait is not cached and does not drop cached reads"
}

test_terminal_exists_shares_one_list() {
  local rc_a rc_b
  setup_case exists
  CACHE_SWITCH=1
  rc_a=0
  run_exists term-a || rc_a=$?
  rc_b=0
  run_exists term-b || rc_b=$?
  assert_equals 0 "$rc_a" "term-a was not present in the list"
  assert_equals 0 "$rc_b" "term-b was not present in the list"
  assert_equals 1 "$(calls)" "two existence checks booted the CLI more than once"
  pass "fm_orca_terminal_exists: two ids share one terminal list"
}

test_terminal_exists_absent_on_a_complete_list() {
  local rc
  setup_case absent
  CACHE_SWITCH=1
  rc=0
  run_exists term-missing || rc=$?
  assert_equals 1 "$rc" "a complete list that omits the id did not report absence"
  rc=0
  run_exists term-a || rc=$?
  assert_equals 0 "$rc" "a listed id was reported absent after the shared list"
  assert_equals 1 "$(calls)" "an absence check did not reuse the list"
  pass "fm_orca_terminal_exists: a complete list can report absence"
}

test_truncated_list_is_not_absence() {
  local rc
  setup_case truncated
  CACHE_SWITCH=1
  printf '%s\n' '{"ok":true,"result":{"truncated":true,"terminals":[{"handle":"term-a"}]}}' > "$LIST"
  rc=0
  run_exists term-missing || rc=$?
  assert_equals 2 "$rc" "a truncated list was treated as a trustworthy absence"
  pass "fm_orca_terminal_exists: a truncated list is not absence"
}

test_disabled_cache_skips_list_and_invalidate() {
  local rc
  setup_case disabled
  printf '4\n' > "$FM_ORCA_CLI_CACHE_DIR/gen"
  CACHE_SWITCH=0
  rc=0
  run_exists term-a || rc=$?
  assert_equals 2 "$rc" "a disabled cache did not ask the caller to fall back"
  assert_equals 0 "$(calls)" "a disabled existence check called the CLI"
  PATH="$CASE/fakebin:$PATH" FM_ORCA_CLI_CACHE=0 FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    bash -c '. "$1"; fm_orca_cli_cache_invalidate' _ "$ROOT/bin/fm-orca-cli-cache.sh"
  assert_equals 4 "$(tr -cd '0-9' < "$FM_ORCA_CLI_CACHE_DIR/gen")" \
    "a disabled cache dropped cached results"
  pass "fm_orca_cli: a disabled cache does not call, store, or invalidate"
}

test_test_seam_keeps_cache_off_until_forced() {
  setup_case seam
  CACHE_SWITCH=inherit
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  run_cli terminal read --terminal term-a --limit 1 --json >/dev/null
  assert_equals 2 "$(calls)" "an unset cache switch reused a read while FM_TEST_SEAM=1"
  pass "fm_orca_cli: FM_TEST_SEAM=1 leaves the cache off unless it is forced on"
}

test_single_flight_shares_one_inflight_read() {
  local i
  setup_case flight
  CACHE_SWITCH=1
  FM_ORCA_HOLD="$CASE/hold"
  run_cli terminal read --terminal term-a --limit 5 --json >"$CASE/one.out" &
  i=0
  while [ ! -f "$FM_ORCA_HOLD" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$FM_ORCA_HOLD" ] || fail "the first read never reached the CLI"
  run_cli terminal read --terminal term-a --limit 5 --json >"$CASE/two.out" &
  i=0
  while [ "$i" -lt 20 ]; do
    assert_equals 1 "$(calls)" "a second caller booted the CLI while the first read was in flight"
    sleep 0.1
    i=$((i + 1))
  done
  touch "${FM_ORCA_HOLD}.release"
  wait
  assert_equals 1 "$(calls)" "the in-flight read was not shared"
  assert_equals "$(cat "$CASE/one.out")" "$(cat "$CASE/two.out")" "the waiter did not receive the in-flight body"
  pass "fm_orca_cli: one in-flight read serves a second caller"
}

test_target_exists_shares_one_list_when_cache_is_on() {
  local rc_a rc_b
  setup_case wire-on
  CACHE_SWITCH=1
  rc_a=0
  PATH="$CASE/fakebin:$PATH" FM_ORCA_CLI_CACHE=1 FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" FM_ORCA_COUNT="$COUNT" FM_ORCA_LIST="$LIST" \
    bash -c '. "$1"; fm_backend_target_exists orca term-a' _ "$ROOT/bin/fm-backend.sh" || rc_a=$?
  rc_b=0
  PATH="$CASE/fakebin:$PATH" FM_ORCA_CLI_CACHE=1 FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" FM_ORCA_COUNT="$COUNT" FM_ORCA_LIST="$LIST" \
    bash -c '. "$1"; fm_backend_target_exists orca term-b' _ "$ROOT/bin/fm-backend.sh" || rc_b=$?
  assert_equals 0 "$rc_a" "a listed terminal was not present"
  assert_equals 0 "$rc_b" "a second listed terminal was not present"
  assert_equals 1 "$(calls)" "two existence checks did not share one terminal list"
  assert_not_contains "$(cat "$LOG")" $'terminal\x1fread' "existence used a per-terminal read"
  pass "fm_backend_target_exists: Orca existence shares one terminal list"
}

test_target_exists_reads_one_line_when_cache_is_off() {
  local rc
  setup_case wire-off
  rc=0
  PATH="$CASE/fakebin:$PATH" FM_ORCA_CLI_CACHE=0 FM_ORCA_CLI_CACHE_DIR="$FM_ORCA_CLI_CACHE_DIR" \
    FM_ORCA_LOG="$LOG" FM_ORCA_COUNT="$COUNT" FM_ORCA_LIST="$LIST" \
    bash -c '. "$1"; fm_backend_target_exists orca term-a' _ "$ROOT/bin/fm-backend.sh" || rc=$?
  assert_equals 0 "$rc" "the one-line read fallback did not accept a live terminal"
  assert_contains "$(cat "$LOG")" $'terminal\x1fread\x1f--terminal\x1fterm-a\x1f--limit\x1f1\x1f--json' \
    "a disabled cache did not fall back to a one-line terminal read"
  assert_not_contains "$(cat "$LOG")" $'terminal\x1flist' \
    "a disabled cache called terminal list"
  pass "fm_backend_target_exists: a disabled cache keeps the one-line terminal read"
}

# Optional arguments select existing case functions for focused regressions.
if [ "$#" -gt 0 ]; then
  fm_test_run "$@"
  exit
fi

fm_test_run \
  test_live_capture_proofs_ignore_cached_snapshots \
  test_pending_generation_invalidation_disables_replay \
  test_failed_generation_publish_rejects_an_old_inflight_result \
  test_generation_directory_rejects_an_old_inflight_result \
  test_session_proofs_ignore_cached_terminal_facts \
  test_draft_probe_does_not_reuse_an_empty_snapshot \
  test_zero_ttl_bypasses_an_existing_entry \
  test_cache_hit_reuses_one_read \
  test_ttl_expiry_reads_again \
  test_mutation_invalidates_cached_read \
  test_read_during_mutation_is_not_reused_after_it \
  test_direct_mutation_drops_the_cache_before_the_command \
  test_two_fills_in_one_shell_keep_their_own_bodies \
  test_unreadable_cached_stdout_is_a_miss \
  test_cache_hit_replays_stderr \
  test_unreadable_cached_stderr_emits_nothing \
  test_missing_cached_stderr_is_a_miss \
  test_symlinked_cache_dir_is_bypassed \
  test_different_args_do_not_share_a_read \
  test_failed_read_is_not_cached \
  test_ok_false_is_not_cached \
  test_wait_does_not_invalidate_or_cache \
  test_terminal_exists_shares_one_list \
  test_terminal_exists_absent_on_a_complete_list \
  test_truncated_list_is_not_absence \
  test_disabled_cache_skips_list_and_invalidate \
  test_test_seam_keeps_cache_off_until_forced \
  test_single_flight_shares_one_inflight_read \
  test_target_exists_shares_one_list_when_cache_is_on \
  test_target_exists_reads_one_line_when_cache_is_off
