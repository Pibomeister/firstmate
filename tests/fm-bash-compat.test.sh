#!/usr/bin/env bash
# Behavior tests for bin/fm-bash-compat-lib.sh, the gate that forces temporary-file
# here-documents on Darwin bash 5.1 through 5.3.15 (whose pipe-backed here-documents
# can block forever under machine-wide pipe-memory pressure) and changes nothing on
# any other runtime. Profiles are driven through the library's runtime seam; the
# here-document's stdin kind is observed in a real bash 5.1+ child, so the
# temporary-file switch is proven on the running platform rather than assumed.
# The optional macOS lane runs the real pending-reply writer under an affected
# bash binary with a 512-byte pipe model and shows it completes only with the
# gate: set FM_BASH_COMPAT_AFFECTED_BASH to such a binary (it needs clang);
# without it the lane says it was skipped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bash-compat)
LIB="$ROOT/bin/fm-bash-compat-lib.sh"
REAL_BASH=$(command -v bash)

# A bash new enough to use pipe-backed here-documents (5.1+), or empty.
modern_bash() {
  local b v
  for b in "${FM_TEST_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash bash; do
    [ -n "$b" ] || continue
    # shellcheck disable=SC2016 # expanded by the child shell
    v=$("$b" -c 'printf "%s %s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null) || continue
    # shellcheck disable=SC2086 # split into major and minor
    set -- $v
    if [ "${1:-0}" -gt 5 ] || { [ "${1:-0}" -eq 5 ] && [ "${2:-0}" -ge 1 ]; }; then
      command -v "$b"
      return 0
    fi
  done
  return 1
}

# compat_after <runtime-profile> <inherited BASH_COMPAT or "unset"> -> "<value>|<exported>"
compat_after() {
  local profile=$1 inherited=$2
  if [ "$inherited" = unset ]; then
    # shellcheck disable=SC2016 # expanded by the child shell
    env -u BASH_COMPAT FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME="$profile" bash -c '
      . "$1"
      printf "%s|" "${BASH_COMPAT-unset}"
      case "$(export -p)" in *" BASH_COMPAT="*) printf exported ;; *) printf local ;; esac' _ "$LIB"
  else
    # shellcheck disable=SC2016 # expanded by the child shell
    env BASH_COMPAT="$inherited" FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME="$profile" bash -c '
      . "$1"
      printf "%s|" "${BASH_COMPAT-unset}"
      case "$(export -p)" in *" BASH_COMPAT="*) printf exported ;; *) printf local ;; esac' _ "$LIB"
  fi
}

test_affected_profiles_force_compat_50_unexported() {
  local profile got
  for profile in 'darwin25 5 1 16' 'darwin24.6.0 5 2 37' 'darwin25 5 3 0' 'darwin25 5 3 9' 'darwin25 5 3 15'; do
    got=$(compat_after "$profile" unset)
    [ "$got" = '50|local' ] || fail "affected profile '$profile' should set BASH_COMPAT=50 unexported, got '$got'"
    got=$(compat_after "$profile" 51)
    [ "$got" = '50|local' ] || fail "affected profile '$profile' should replace an inherited export with an unexported 50, got '$got'"
  done
  pass "affected Darwin bash 5.1, 5.2 and 5.3.0-5.3.15 force BASH_COMPAT=50 in that shell only"
}

test_unaffected_profiles_change_nothing() {
  local profile got
  for profile in 'darwin25 5 3 16' 'darwin25 5 3 20' 'darwin25 5 0 18' 'darwin25 3 2 57' 'darwin25 5 4 0' \
    'linux-gnu 5 2 21' 'linux-gnu 5 3 9' 'linux-gnu 5 1 16' 'msys 5 2 37' 'darwin25 x y z'; do
    got=$(compat_after "$profile" unset)
    [ "$got" = 'unset|local' ] || fail "unaffected profile '$profile' must leave BASH_COMPAT unset, got '$got'"
    got=$(compat_after "$profile" 51)
    [ "$got" = '51|exported' ] || fail "unaffected profile '$profile' must leave an inherited BASH_COMPAT exactly as inherited, got '$got'"
  done
  pass "bash 3.2, 5.0, Darwin 5.3.16+, Linux and malformed profiles leave BASH_COMPAT untouched"
}

test_heredoc_reads_from_a_regular_file_when_affected() {
  local b got
  if ! b=$(modern_bash); then
    pass "SKIP: no bash 5.1+ on this host, so pipe-backed here-documents cannot be observed"
    return 0
  fi
  # shellcheck disable=SC2016 # the probe expands in the child bash
  got=$(env -u BASH_COMPAT FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME='darwin25 5 3 9' "$b" -c '
    . "$1"
    probe() { if [ -p /dev/stdin ]; then printf pipe; else printf file; fi; }
    probe <<EOF
short document
EOF
    printf " "
    x=$(printf "%0100d" 0)
    probe <<< "$x"' _ "$LIB")
  [ "$got" = 'file file' ] || fail "an affected profile should give here-documents a regular file under $b, got '$got'"
  # Control: the same bash with an unaffected profile still uses its pipe path,
  # so the case above is not vacuous.
  # shellcheck disable=SC2016
  got=$(env -u BASH_COMPAT FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME='linux-gnu 5 3 9' "$b" -c '
    . "$1"
    probe() { if [ -p /dev/stdin ]; then printf pipe; else printf file; fi; }
    x=$(printf "%0100d" 0)
    probe <<< "$x"' _ "$LIB")
  [ "$got" = 'pipe' ] || fail "control: an unaffected profile should keep $b's pipe-backed here-string, got '$got'"
  pass "an affected profile turns $b's here-documents into regular files; unaffected keeps pipes"
}

test_entry_points_apply_the_gate() {
  local home trace script
  home="$TMP_ROOT/entry-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  trace="$TMP_ROOT/entry-trace"
  : > "$trace"
  # The probe seam records the verdict of the first gate a shell applies and
  # exits that shell at once, so no entry point does any work here.
  for script in fm-send.sh fm-lease.sh fm-crew-state.sh fm-watch.sh fm-watch-arm.sh fm-watch-checkpoint.sh \
    fm-supervision-host.sh fm-supervise-daemon.sh fm-fleet-ledger.sh fm-busy-event.sh fm-inbox.sh fm-pr-state.sh \
    fm-supervision-instructions.sh fm-session-start.sh fm-wake-drain.sh fm-guard.sh; do
    perl -e 'alarm 10; exec @ARGV' env -u BASH_COMPAT FM_HOME="$home" FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME='darwin25 5 3 9' \
      FM_BASH_COMPAT_PROBE="$trace" "$ROOT/bin/$script" </dev/null >/dev/null 2>&1 || true
    grep -qx "$script	applied" "$trace" \
      || fail "$script did not apply the here-document gate under an affected profile (trace: $(tr '\n' ' ' < "$trace"))"
  done
  pass "supervision entry points apply the gate when they start"
}

test_warning_names_an_affected_running_or_path_bash() {
  local fakebin out
  fakebin="$TMP_ROOT/fake-bash-bin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nprintf "darwin25 5 3 9"\n' > "$fakebin/bash"
  chmod +x "$fakebin/bash"
  # shellcheck disable=SC2016
  out=$(env FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME='darwin25 5 3 20' PATH="$fakebin:$PATH" "$REAL_BASH" -c '
    . "$1"; fm_bash_heredoc_startup_warnings' _ "$LIB")
  [ "$(printf '%s\n' "$out" | grep -c 'brew upgrade bash')" = 1 ] \
    || fail "an affected PATH bash should produce exactly one warning line, got: $out"
  case "$out" in *"$fakebin/bash"*"5.3.9"*) ;; *) fail "the warning should name the affected path and version, got: $out" ;; esac
  # shellcheck disable=SC2016
  out=$(env FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME='darwin25 5 2 37' bash -c '
    . "$1"; fm_bash_heredoc_startup_warnings' _ "$LIB")
  [ "$(printf '%s\n' "$out" | grep -c 'brew upgrade bash')" = 1 ] \
    || fail "an affected running shell should produce exactly one warning line, got: $out"
  printf '#!/bin/sh\nprintf "darwin25 5 3 20"\n' > "$fakebin/bash"
  # shellcheck disable=SC2016
  out=$(env FM_TEST_SEAM=1 FM_TEST_BASH_RUNTIME='darwin25 5 3 20' PATH="$fakebin:$PATH" "$REAL_BASH" -c '
    . "$1"; fm_bash_heredoc_startup_warnings' _ "$LIB")
  [ -z "$out" ] || fail "an unaffected running and PATH bash must print nothing, got: $out"
  pass "the startup warning names exactly the affected running or PATH-selected bash, and is silent otherwise"
}

test_session_start_and_bootstrap_warn_once() {
  local fakebin home out
  fakebin="$TMP_ROOT/fake-bash-bin-2"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nprintf "darwin25 5 3 9"\n' > "$fakebin/bash"
  chmod +x "$fakebin/bash"
  home="$TMP_ROOT/bootstrap-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(env FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip FM_TEST_SEAM=1 \
    FM_TEST_BASH_RUNTIME='darwin25 5 3 20' FM_BASH_HEREDOC_PROBE_PATH="$fakebin/bash" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 </dev/null)
  [ "$(printf '%s\n' "$out" | grep -c 'brew upgrade bash')" = 1 ] \
    || fail "bootstrap run on its own should warn exactly once about the affected PATH bash, got: $(printf '%s\n' "$out" | grep -i bash)"
  out=$(env FM_HOME="$home" FM_BASH_HEREDOC_WARNED=1 FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip FM_TEST_SEAM=1 \
    FM_TEST_BASH_RUNTIME='darwin25 5 3 20' FM_BASH_HEREDOC_PROBE_PATH="$fakebin/bash" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 </dev/null)
  [ "$(printf '%s\n' "$out" | grep -c 'brew upgrade bash')" = 0 ] \
    || fail "bootstrap under a session start that already warned must not warn again"
  pass "bootstrap warns once on its own and defers to a session start that already warned"
}

# The optional real-binary lane: an affected bash with a 512-byte pipe model
# hangs writing the real pending-reply record without the gate and completes
# with it. Every case runs in its own process group, killed as a group at 5 s.
test_affected_binary_with_small_pipes_completes_only_with_the_gate() {
  local affected=${FM_BASH_COMPAT_AFFECTED_BASH:-} dylib home out rc
  if [ -z "$affected" ] || [ ! -x "$affected" ] || [ "$(uname -s)" != Darwin ] || ! command -v clang >/dev/null 2>&1; then
    pass "SKIP: real affected-binary lane not run (needs Darwin, clang and FM_BASH_COMPAT_AFFECTED_BASH)"
    return 0
  fi
  mkdir -p "$TMP_ROOT/smallpipe"
  printf '%s\n' '#include <sys/socket.h>' '#include <unistd.h>' \
    'static int small_pipe(int fds[2]) { int sz = 512; if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;' \
    '  shutdown(fds[0], SHUT_WR); shutdown(fds[1], SHUT_RD);' \
    '  setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz); setsockopt(fds[0], SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz); return 0; }' \
    '__attribute__((used)) static struct { const void *r; const void *e; } interposers[] __attribute__((section("__DATA,__interpose"))) = { { (const void *)small_pipe, (const void *)pipe } };' \
    > "$TMP_ROOT/smallpipe/smallpipe.c"
  dylib="$TMP_ROOT/smallpipe/smallpipe.dylib"
  clang -dynamiclib -O1 -o "$dylib" "$TMP_ROOT/smallpipe/smallpipe.c" 2>/dev/null \
    || { fail "could not build the 512-byte pipe interposer"; return 0; }
  home="$TMP_ROOT/smallpipe-home"
  mkdir -p "$home/state"
  bounded() {  # perl group-kill bound; prints output, returns 124 on the bound
    perl -e 'my $p = fork; if (!$p) { setpgrp(0,0); exec @ARGV } $SIG{ALRM} = sub { kill "KILL", -$p; waitpid $p, 0; exit 124 }; alarm 5; waitpid $p, 0; exit($? >> 8)' "$@"
  }
  # Control: without the gate the same binary and model hang on a 2000-byte here-string.
  # shellcheck disable=SC2016
  bounded env -u BASH_COMPAT DYLD_INSERT_LIBRARIES="$dylib" "$affected" -c 'x=$(printf "%02000d" 0); cat <<< "$x" | wc -c' >/dev/null 2>&1
  rc=$?
  [ "$rc" = 124 ] || { fail "control: $affected with the 512-byte model should hang without the gate (rc=$rc), so the lane proves nothing"; return 0; }
  # The real writer, through the real library chain, with the gate in place.
  # shellcheck disable=SC2016
  out=$(bounded env -u BASH_COMPAT DYLD_INSERT_LIBRARIES="$dylib" FM_HOME="$home" "$affected" -c '
    . "$1/bin/fm-pending-reply-lib.sh"
    req=$(printf "%01500d" 0)
    fm_pending_reply_create "$2" "$2/state" mate "$req"' _ "$ROOT" "$home" 2>&1)
  rc=$?
  [ "$rc" = 0 ] || { fail "the pending-reply writer under $affected with the 512-byte model did not complete with the gate (rc=$rc): $out"; return 0; }
  [ -n "$(find "$home/state" -type f -size +512c ! -name '.*' 2>/dev/null)" ] \
    || fail "the pending-reply record was not written under the 512-byte model"
  pass "under $affected with 512-byte pipes, the real pending-reply writer completes with the gate (and a bare here-string hangs without it)"
}

test_affected_profiles_force_compat_50_unexported
test_unaffected_profiles_change_nothing
test_heredoc_reads_from_a_regular_file_when_affected
test_entry_points_apply_the_gate
test_warning_names_an_affected_running_or_path_bash
test_session_start_and_bootstrap_warn_once
test_affected_binary_with_small_pipes_completes_only_with_the_gate
