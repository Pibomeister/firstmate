#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"
ln -s /bin/bash "$FAKEBIN/codex"
NAMED_CODEX="$FAKEBIN/codex"

mkdir -p "$TMP_ROOT/native"
cat > "$TMP_ROOT/native/codex.c" <<'C'
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
int main(void) {
  const char *body = getenv("FM_TEST_CODEX_BODY");
  if (!body) { while (1) sleep(1); }
  int listener = -1;
  pid_t server = -1;
  const char *path = getenv("FM_TEST_CODEX_SOCKET");
  if (path) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) return 2;
    strcpy(address.sun_path, path);
    unlink(path);
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 8)) return 3;
    server = fork();
    if (server < 0) return 4;
    if (!server) {
      char fd[24];
      snprintf(fd, sizeof(fd), "%d", listener);
      execlp("python3", "python3", getenv("FM_TEST_CODEX_SERVER"), fd, (char *)0);
      _exit(127);
    }
  }
  pid_t child = fork();
  if (child < 0) return 1;
  if (!child) { execl("/bin/bash", "bash", body, (char *)0); _exit(127); }
  int status;
  if (waitpid(child, &status, 0) < 0) return 1;
  if (server > 0) { kill(server, SIGTERM); waitpid(server, NULL, 0); close(listener); unlink(path); }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
C
cc "$TMP_ROOT/native/codex.c" -o "$TMP_ROOT/native/codex" || fail "cannot compile the real argv fixture"
NATIVE_CODEX="$TMP_ROOT/native/codex"

cat > "$TMP_ROOT/native/server.py" <<'PYTHON'
import base64
import hashlib
import json
import os
import socket
import struct
import sys
from pathlib import Path

listener = socket.socket(fileno=int(sys.argv[1]))
while True:
    connection, _ = listener.accept()
    connection.settimeout(8)
    stream = connection.makefile("rwb", buffering=0)
    try:
        headers = {}
        stream.readline()
        while True:
            line = stream.readline().strip()
            if not line:
                break
            key, value = line.split(b":", 1)
            headers[key.lower()] = value.strip()
        accept = base64.b64encode(hashlib.sha1(headers[b"sec-websocket-key"] + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        stream.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        while True:
            first, second = stream.read(2)
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", stream.read(2))[0]
            mask = stream.read(4)
            data = stream.read(size)
            request = json.loads(bytes(c ^ mask[i % 4] for i, c in enumerate(data)))
            if "id" not in request:
                continue
            result = {}
            if request["method"] == "thread/read":
                identity = request["params"]["threadId"]
                states = json.loads(Path(os.environ["FM_HOME"], "state/thread-states.json").read_text())
                result = {"thread": {"id": identity, "status": {"type": states.get(identity, "notLoaded")}}}
            encoded = json.dumps({"id": request["id"], "result": result}).encode()
            prefix = bytes([129, len(encoded)]) if len(encoded) < 126 else bytes([129, 126]) + struct.pack("!H", len(encoded))
            stream.write(prefix + encoded)
    except (OSError, ValueError, KeyError):
        pass
    finally:
        stream.close()
        connection.close()
PYTHON

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  # Codex publishes CODEX_THREAD_ID and CODEX_SESSION_ID, equal, to every
  # tool shell, and only that pair is trusted. FM_TEST_CODEX_ID sets the
  # pair; FM_TEST_CODEX_THREAD_ID and FM_TEST_CODEX_SESSION_ID set one
  # member each so single-variable and disagreeing shapes can be exercised.
  if [ -n "${FM_TEST_CODEX_ID:-}" ]; then
    session_env+=("CODEX_THREAD_ID=$FM_TEST_CODEX_ID" "CODEX_SESSION_ID=$FM_TEST_CODEX_ID")
  fi
  [ -z "${FM_TEST_CODEX_THREAD_ID:-}" ] || session_env+=("CODEX_THREAD_ID=$FM_TEST_CODEX_THREAD_ID")
  [ -z "${FM_TEST_CODEX_SESSION_ID:-}" ] || session_env+=("CODEX_SESSION_ID=$FM_TEST_CODEX_SESSION_ID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    fm_codex_process_class() {
      case \$1 in 900) printf daemon ;; 800) printf host ;; *) printf session ;; esac
    }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# Muse's launcher execs a version-suffixed binary (muse-bin-<version>),
# so the lock identity must accept that anchored prefix on both platforms'
# comm shapes, and must never accept a mere substring such as amuse.
test_muse_versioned_session_is_identified() {
  local dir fakebin shape got
  dir="$TMP_ROOT/muse-versioned"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_MUSE_SHAPE:-bare}" in
  700:comm=:bare) printf '%s\n' 'muse-bin-1.4.13-R6996.1' ;;
  700:args=:bare) printf '%s\n' 'muse-bin-1.4.13-R6996.1' ;;
  700:comm=:fullpath) printf '%s\n' '/Users/u/.local/bin/muse-bin-1.4.13-R6996.1' ;;
  700:args=:fullpath) printf '%s\n' '/Users/u/.local/bin/muse-bin-1.4.13-R6996.1' ;;
  700:comm=:decoy) printf '%s\n' 'amuse' ;;
  700:args=:decoy) printf '%s\n' 'amuse' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in bare fullpath; do
    got=$(FM_TEST_MUSE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the versioned muse session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the muse session pid 700"
    FM_TEST_MUSE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live versioned muse session was not recognized as a harness"
    FM_TEST_MUSE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the muse session holding the lock did not recognize itself as the owner"
  done
  if FM_TEST_MUSE_SHAPE=decoy lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
    fail "decoy: a process merely containing the muse substring was treated as a harness process"
  fi
  pass "session-lock: a version-suffixed muse session is identified, and substring decoys are not"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# --- Codex: the shared app-server daemon is never a session ------------------
#
# The process table a daemon-served Codex tool shell actually sees (measured
# live on this fleet: a supervision checkpoint shell parented directly by
# `codex app-server --listen unix:// --managed-daemon`): tool shell ->
# code-mode host (800) -> shared daemon (900) -> the unrelated TUI that
# launched the daemon (950) -> init. FM_TEST_CODEX_SHAPE=tui is a direct TUI
# launch instead: tool shell -> session TUI (700) -> init, with host
# inserting the code-mode host between the shell and that same TUI.
write_codex_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CODEX_SHAPE:-daemon}" in
  900:comm=*) printf '%s\n' codex ;;
  900:args=*) printf '%s\n' 'codex app-server --listen unix:// --analytics-default-enabled --managed-daemon' ;;
  900:ppid=*) printf '%s\n' 950 ;;
  950:comm=*) printf '%s\n' codex ;;
  950:args=*) printf '%s\n' 'codex resume 01other' ;;
  950:ppid=*) printf '%s\n' 1 ;;
  800:comm=*) printf '%s\n' codex-code-mode-host ;;
  800:args=*) printf '%s\n' 'codex-code-mode-host' ;;
  800:ppid=:daemon) printf '%s\n' 900 ;;
  800:ppid=:*) printf '%s\n' 700 ;;
  700:comm=*) printf '%s\n' codex ;;
  700:args=:prompt) printf '%s\n' 'codex Diagnose codex app-server --listen unix:// --managed-daemon lock ownership' ;;
  700:args=:prompt2) printf '%s\n' 'codex app-server --listen unix:// is holding the lock; diagnose it' ;;
  700:args=*) printf '%s\n' 'codex --model gpt-6.1-sol' ;;
  700:ppid=*) printf '%s\n' 1 ;;
  600:comm=*) printf '%s\n' pi ;;
  600:args=*) printf '%s\n' 'pi' ;;
  600:ppid=*) printf '%s\n' 900 ;;
  *:comm=*) printf '%s\n' bash ;;
  *:args=*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:daemon) printf '%s\n' 800 ;;
  *:ppid=:host) printf '%s\n' 800 ;;
  *:ppid=:pi) printf '%s\n' 600 ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$1/ps"
}

test_codex_daemon_parented_tool_shell() {
  local dir fakebin state got
  dir="$TMP_ROOT/codex-daemon-parented"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_codex_session_ps "$fakebin"

  # The daemon and the host are not session processes, and the walk must not
  # climb past the daemon into the unrelated TUI that launched it.
  if FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" 'fm_harness_ancestry_pids' >/dev/null 2>&1; then
    fail "a daemon-parented tool shell resolved a session pid from the daemon or the TUI above it"
  fi
  if FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" 'fm_harness_pid_alive 900'; then
    fail "the shared app-server daemon passed the harness-liveness predicate"
  fi
  if FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" 'fm_harness_pid_alive 800'; then
    fail "the code-mode host passed the harness-liveness predicate"
  fi
  FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" 'fm_codex_pid_is_daemon 900' \
    || fail "the app-server listener was not classified as the shared daemon"
  if FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" 'fm_codex_pid_is_daemon 700'; then
    fail "a session TUI was classified as the shared daemon"
  fi

  # The thread id is the session identity here, and the anchor is never the
  # daemon, the host, or the daemon-launching TUI.
  got=$(FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_session_lock_trusted_codex_session_id') \
    || fail "a daemon-parented tool shell proved no trusted thread id"
  [ "$got" = T1 ] || fail "the trusted thread id was '$got', expected T1"
  got=$(FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "a daemon-parented tool shell resolved no anchor at all"
  case "$got" in
    800|900|950) fail "a daemon-parented tool shell anchored on shared process $got" ;;
    ''|*[!0-9]*) fail "a daemon-parented tool shell anchored on non-pid '$got'" ;;
  esac

  # A lock the old code recorded against the daemon pid, with no sidecar:
  # owned by nobody, foreign to nobody, and classified stale, so the
  # ordinary fm-lock.sh path can reclaim it (end-to-end case below).
  printf '900\n' > "$state/.lock"
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'"; then
    fail "a daemon-anchored lock was owned through the shared daemon pid"
  fi
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" "fm_session_lock_foreign_owner_live '$state'"; then
    fail "a daemon-anchored lock was reported as a live foreign owner"
  fi
  got=$(FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" "fm_session_lock_inspect '$state'; printf '%s' \"\$FM_LOCK_INSPECT_STATE\"")
  [ "$got" = stale ] || fail "a daemon-anchored lock classified '$got', expected stale"

  # A lock this daemon-served session recorded (acquiring-process line 1,
  # thread sidecar): owned by the same thread, never by a different one.
  printf '111\n' > "$state/.lock"
  printf 'T1\n' > "$state/.lock-session"
  FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'" \
    || fail "a daemon-served session did not own its own thread-recorded lock"
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T2 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'"; then
    fail "a different thread owned a daemon-served session's lock through its sidecar"
  fi
  pass "session-lock: a daemon-parented Codex tool shell anchors off the daemon and owns by thread id"
}

test_codex_direct_tui_launch() {
  local dir fakebin state got shape
  dir="$TMP_ROOT/codex-direct-tui"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_codex_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"

  for shape in tui host; do
    got=$(FM_TEST_CODEX_SHAPE="$shape" FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
      || fail "$shape: a direct TUI launch resolved no anchor"
    [ "$got" = 700 ] || fail "$shape: a direct TUI launch anchored '$got', expected the TUI pid 700"
    FM_TEST_CODEX_SHAPE="$shape" FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: the session TUI was not a live harness"
    FM_TEST_CODEX_SHAPE="$shape" FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'" \
      || fail "$shape: the TUI session did not own its own lock by ancestry"
  done
  # The same lock under the daemon-served shape proves nothing by pid: the
  # walk stops at the daemon, so the TUI above it is never reached.
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_ID=T9 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'"; then
    fail "a daemon-served shell owned a TUI-anchored lock by climbing past the daemon"
  fi
  # A prompt that merely contains the daemon's words is still a session:
  # daemon classification reads argument boundaries, not substrings.
  for shape in prompt prompt2; do
    FM_TEST_CODEX_SHAPE="$shape" FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a prompt-shaped session TUI was not a live harness"
    got=$(FM_TEST_CODEX_SHAPE="$shape" FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
      || fail "$shape: a prompt-shaped session resolved no anchor"
    [ "$got" = 700 ] || fail "$shape: a prompt-shaped session anchored '$got', expected its TUI pid 700"
  done
  pass "session-lock: a direct Codex TUI launch anchors on the TUI, directly or through its code-mode host"
}

test_codex_two_sessions_one_daemon_never_cross_own() {
  local dir fakebin state_a got
  dir="$TMP_ROOT/codex-two-sessions"
  fakebin=$(fm_fakebin "$dir")
  state_a="$dir/state-a"
  mkdir -p "$state_a"
  write_codex_session_ps "$fakebin"
  # Session A's home: A's TUI anchored it and A's thread is beside it. This
  # process is session B instead whenever FM_TEST_CODEX_PEER selects B's own
  # TUI (750) as the ancestry; the shared daemon (900) sits above both.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CODEX_PEER:-A}" in
  900:comm=*) printf '%s\n' codex ;;
  900:args=*) printf '%s\n' 'codex app-server --listen unix:// --managed-daemon' ;;
  900:ppid=*) printf '%s\n' 1 ;;
  700:comm=*) printf '%s\n' codex ;;
  700:args=*) printf '%s\n' 'codex' ;;
  700:ppid=*) printf '%s\n' 900 ;;
  750:comm=*) printf '%s\n' codex ;;
  750:args=*) printf '%s\n' 'codex' ;;
  750:ppid=*) printf '%s\n' 900 ;;
  *:comm=*) printf '%s\n' bash ;;
  *:args=*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:A) printf '%s\n' 700 ;;
  *:ppid=:B) printf '%s\n' 750 ;;
  *:ppid=*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$state_a/.lock"
  printf 'TA\n' > "$state_a/.lock-session"

  FM_TEST_CODEX_PEER=A FM_TEST_CODEX_ID=TA lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state_a'" \
    || fail "session A did not own its own lock"
  if FM_TEST_CODEX_PEER=B FM_TEST_CODEX_ID=TB lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state_a'"; then
    fail "session B owned session A's lock across the shared daemon"
  fi
  got=$(FM_TEST_CODEX_PEER=B FM_TEST_CODEX_ID=TB lib_eval "$fakebin" "fm_session_lock_foreign_owner_live '$state_a' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\"") \
    || fail "session B did not see session A's live TUI as a foreign owner"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected session A's TUI 700"
  pass "session-lock: two Codex sessions sharing one daemon never cross-own each other's locks"
}

test_codex_thread_id_trust_gate() {
  local dir fakebin got
  dir="$TMP_ROOT/codex-trust-gate"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  write_codex_session_ps "$fakebin"

  # A retained thread id under a nearer non-Codex harness is not trusted,
  # and that harness still anchors exactly as before.
  if FM_TEST_CODEX_SHAPE=pi FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_session_lock_trusted_codex_session_id' >/dev/null 2>&1; then
    fail "a thread id retained under a Pi session was trusted as Codex identity"
  fi
  got=$(FM_TEST_CODEX_SHAPE=pi FM_TEST_CODEX_ID=T1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "pi: the nested harness resolved no anchor"
  [ "$got" = 600 ] || fail "pi: the nested harness anchored '$got', expected its own pid 600"
  # Disagreeing published ids are not trusted either, and neither is
  # either variable on its own: only the documented pair counts.
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_THREAD_ID=T1 FM_TEST_CODEX_SESSION_ID=T2 lib_eval "$fakebin" 'fm_session_lock_trusted_codex_session_id' >/dev/null 2>&1; then
    fail "a Codex session whose thread and session ids disagree was trusted"
  fi
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_THREAD_ID=T1 lib_eval "$fakebin" 'fm_session_lock_trusted_codex_session_id' >/dev/null 2>&1; then
    fail "a Codex session publishing only CODEX_THREAD_ID was trusted"
  fi
  if FM_TEST_CODEX_SHAPE=daemon FM_TEST_CODEX_SESSION_ID=T1 lib_eval "$fakebin" 'fm_session_lock_trusted_codex_session_id' >/dev/null 2>&1; then
    fail "a Codex session publishing only CODEX_SESSION_ID was trusted"
  fi
  if FM_TEST_CODEX_SHAPE=daemon lib_eval "$fakebin" 'fm_session_lock_trusted_codex_session_id' >/dev/null 2>&1; then
    fail "a Codex session with no thread id at all was trusted"
  fi
  pass "session-lock: a Codex thread id is trusted only inside a Codex session, and only when its published ids agree"
}

test_codex_thread_binding() {
  local pid prompt dir got
  dir="$TMP_ROOT/real-binding"
  mkdir -p "$dir/state"
  for prompt in 'app-server --listen unix:// --managed-daemon' 'app-server daemon diagnose this' 'Diagnose TA lock ownership' 'CODEX_THREAD_ID=TA CODEX_SESSION_ID=TA'; do
    env -u CODEX_THREAD_ID -u CODEX_SESSION_ID "$NATIVE_CODEX" "$prompt" &
    pid=$!
    BG_FIXTURE_PIDS+=("$pid")
    got=$(bash -c '. "$1"; fm_codex_process_class "$2"' _ "$LIB" "$pid")
    [ "$got" = session ] || fail "a single prompt argument classified as $got"
    if bash -c '. "$1"; fm_codex_pid_bound_to_id "$2" TA' _ "$LIB" "$pid"; then
      fail "prompt text bound an unrelated process to TA"
    fi
    kill "$pid"
    wait "$pid" 2>/dev/null || true
  done
  env -u CODEX_THREAD_ID -u CODEX_SESSION_ID "$NATIVE_CODEX" resume TA &
  pid=$!
  BG_FIXTURE_PIDS+=("$pid")
  bash -c '. "$1"; fm_codex_pid_bound_to_id "$2" TA && fm_codex_session_identity_live TA' _ "$LIB" "$pid" \
    || fail "the actual resume identifier did not bind its thread"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  bash -c '
    . "$1"
    CODEX_THREAD_ID=TA CODEX_SESSION_ID=TA "$2" &
    pid=$!
    fm_codex_pid_bound_to_id "$pid" TA && fm_codex_session_identity_live TA
    live=$?
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    [ "$live" -eq 0 ] && ! fm_codex_session_identity_live TA
  ' _ "$LIB" "$NATIVE_CODEX" || fail "separate environment binding or the fresh post-exit scan failed"
  pass "session-lock: real argv and separate environment fields bind only their own thread"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-bash-compat-lib.sh" "$dir/bin/fm-bash-compat-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-session-process.py" "$dir/bin/fm-session-process.py"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  # Launch probe sibling of fm-cursor-lib.sh; keep it next to the copy so a
  # fixture that ever verifies an executable does not source a missing file.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_background_fixture; fm_test_cleanup' EXIT

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while :; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local i=0
  while [ "$i" -lt 400 ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 naming <expected-lock-pid>, and the sidecar either
# byte-identical to the one the owner wrote or, when <expected-session-id> is
# given, re-keyed to that id. An owned actionable close records two arm
# invocations - the foreground arm plus the handling successor the hook starts
# before the rewake - so the cumulative <expected-arms> grows by two for every
# owned phase.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label> [<expected-session-id>]
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5 session_id=${6:-}
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  if [ -n "$session_id" ]; then
    [ "$(head -n 1 "$dir/state/phase-$n/session-after")" = "$session_id" ] \
      || fail "$label: the session sidecar names $(head -n 1 "$dir/state/phase-$n/session-after"), expected $session_id"
  else
    [ "$(head -n 1 "$dir/state/phase-$n/session-after")" = "$(head -n 1 "$dir/sidecar-initial")" ] \
      || fail "$label: the session identity changed"
    [ "$(sed -n 's/^anchor_pid=//p' "$dir/state/phase-$n/session-after")" = "$lock_pid" ] \
      || fail "$label: the anchor instance does not name the lock holder"
  fi
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5
  expect_code 0 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $owner" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare i
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ "$(head -n 1 "$dir/state/.lock-session")" = S1 ] \
    || fail "the front-end did not record its trusted session id beside the lock"
  cp "$dir/state/.lock-session" "$dir/sidecar-initial"

  # Phase 1: the healthy contiguous chain, the session's own id.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 2 "$frontend" "healthy chain"

  # Recycle the bridge: the daemon ends, the pty-host is reparented to init, and
  # the front-end that holds the lock stays alive.
  kill -TERM "$daemon"
  i=0
  while [ "$i" -lt 200 ] && { kill -0 "$daemon" 2>/dev/null || [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" != 1 ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" = 1 ] || fail "the pty-host was not reparented to init after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phases 2-4: before the spare proves anything, a different id, the right id
  # from a CLAUDE_PID outside the run, and no id at all are each a non-owner
  # over the broken chain.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so these phases prove nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_foreign "$dir" 2 2 "$frontend" "recycled chain, different session"
  fire_phase "$dir" 3 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 3 2 "$frontend" "recycled chain, untrusted id"
  fire_phase "$dir" 4 ''
  expect_phase_foreign "$dir" 4 2 "$frontend" "recycled chain, no id"

  # Phase 5: the same session id over the broken chain - the reported drift. The
  # confirmation re-anchors line 1 from the live non-ancestor front-end onto the
  # spare - the model-loop process - not onto the outermost pty-host.
  fire_phase "$dir" 5 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 5 4 "$spare" "recycled chain, same session"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end exited, so the re-anchor was not over a live owner"

  # Phase 6: /clear - the same spare under a new id while the front-end that
  # first recorded the lock is still alive. Ancestry still proves ownership and
  # the sidecar is re-keyed.
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 6 "$spare" "same process after a session-id change" S2

  : > "$dir/state/stop-frontend"
  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain and a same-process session-id change"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(head -n 1 "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(head -n 1 "$dir/state/.lock-session")" = S2 ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(head -n 1 "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(head -n 1 "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ "$(head -n 1 "$dir/state/.lock-session")" = S1 ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous id S1"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  [ "$(head -n 1 "$dir/state/.lock-session")" = S2 ] \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/new-pid")" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

# A re-anchor moves leases recorded against the old live line 1 onto the new
# anchor, so the other supervision actor still cannot claim a held task.
test_reanchor_keeps_task_leases_live() {
  local dir front_pid model_pid lease_rc
  dir="$TMP_ROOT/reanchor-leases"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'branch\t%s\t100\n' "$front_pid" > "$dir/state/.lease-t1"
  printf 'main\t%s\t200\n' "$front_pid" > "$dir/state/.lease-t2"
  printf 'branch\t%s\t300\n' "$$" > "$dir/state/.lease-t3"
  cp "$dir/state/.lease-t3" "$dir/state/lease-t3-before"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.lease-t1")" = "$(printf 'branch\t%s\t100' "$model_pid")" ] \
    || fail "the branch lease was not moved to the new anchor: $(cat "$dir/state/.lease-t1")"
  [ "$(cat "$dir/state/.lease-t2")" = "$(printf 'main\t%s\t200' "$model_pid")" ] \
    || fail "the main lease was not moved to the new anchor: $(cat "$dir/state/.lease-t2")"
  cmp -s "$dir/state/lease-t3-before" "$dir/state/.lease-t3" \
    || fail "a lease recorded against another pid changed: $(cat "$dir/state/.lease-t3")"
  env -u FM_SUPERVISION_ACTOR -u FM_LEASE_HOLDER_PID -u FM_LEASE_HOLDER_SESSION FM_HOME="$dir" \
    "$ROOT/bin/fm-lease.sh" claim t1 > "$dir/state/main-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "main claimed the branch's task after the re-anchor: $(cat "$dir/state/main-claim.out")"
  env -u FM_SUPERVISION_ACTOR FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$model_pid" \
    "$ROOT/bin/fm-lease.sh" claim t2 > "$dir/state/branch-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "the branch claimed main's task after the re-anchor: $(cat "$dir/state/branch-claim.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor keeps both supervision actors' task leases live"
}

autoarm_midturn_healthy() {  # <state-dir>
  FM_STATE_OVERRIDE="$1" bash -c '. "$0"; fm_autoarm_midturn_healthy "$FM_STATE_OVERRIDE" 300' "$ROOT/bin/fm-wake-lib.sh"
}

# A re-anchor during a rewake handling turn that has outrun grace moves the
# auto-arm ledger's session_pid with line 1 and keeps the ledger's other bytes
# and mtime, so the mid-turn guard still sees healthy supervision.
test_reanchor_keeps_autoarm_midturn_healthy() {
  local dir front_pid model_pid
  dir="$TMP_ROOT/reanchor-autoarm"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1\n' \
    "$front_pid" > "$dir/state/.claude-autoarm-epoch"
  printf 'acked:handling:g1\n' > "$dir/state/.watcher-down"
  touch -t 201901010000 "$dir/state/.last-watcher-beat"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch" "$dir/state/epoch-mtime"
  autoarm_midturn_healthy "$dir/state" || fail "the rewake fixture is not healthy before the re-anchor, so this case proves nothing"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.claude-autoarm-epoch")" = "$(printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1' "$model_pid")" ] \
    || fail "the rewake was not moved to the new anchor intact: $(cat "$dir/state/.claude-autoarm-epoch")"
  if [ "$dir/state/.claude-autoarm-epoch" -nt "$dir/state/epoch-mtime" ] \
    || [ "$dir/state/.claude-autoarm-epoch" -ot "$dir/state/epoch-mtime" ]; then
    fail "the rewake move changed the ledger mtime"
  fi
  autoarm_midturn_healthy "$dir/state" \
    || fail "the mid-turn guard rejects the rewake after the re-anchor: $(cat "$dir/state/reanchor.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor during a rewake turn keeps the mid-turn auto-arm proof healthy"
}

# --- end-to-end layer: Codex daemon locks through the real fm-lock.sh -------
#
# Real process trees with the fake Codex binary. The daemon fixture is a
# codex-named process re-execed with the shared listener's argv, so ps
# reports exactly the shape production tool shells are parented by.

# A daemon-fixture completion wait with a budget sized for several real
# fm-lock.sh runs, each of which may scan the machine's process table for
# thread-bound processes on a loaded host.
wait_for_daemon_done() {  # <path> <what>
  local i=0
  while [ "$i" -lt 3600 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "daemon fixture never produced $2"
}

# Launch <body> as the shared daemon and register it for reaping.
launch_codex_daemon() {  # <dir> <body>
  local dir=$1 body=$2
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    FM_HOME="$dir" FM_TEST_CODEX_BODY="$body" \
    "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon &
  BG_FIXTURE_PIDS+=("$!")
}

test_e2e_codex_daemon_parented_session_acquires_by_thread() {
  local dir daemon_pid
  dir="$TMP_ROOT/e2e-codex-daemon-parented"
  mkdir -p "$dir/state"
  cat > "$dir/tool-acquire.sh" <<'SH'
#!/usr/bin/env bash
"$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/acquire.rc"
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/lock-after-acquire"
head -n 1 "$FM_HOME/state/.lock-session" > "$FM_HOME/state/session-after-acquire"
SH
  cat > "$dir/tool-confirm.sh" <<'SH'
#!/usr/bin/env bash
"$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/lock-after-confirm"
SH
  cat > "$dir/tool-foreign.sh" <<'SH'
#!/usr/bin/env bash
bash -c '. "$1"; fm_session_lock_owned_by_self "$2"' _ "$FM_LIB" "$FM_HOME/state" \
  > "$FM_HOME/state/foreign.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/foreign.rc"
SH
  cat > "$dir/daemon-body.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" > "$FM_HOME/state/daemon-pid"
CODEX_THREAD_ID=T1 CODEX_SESSION_ID=T1 "$FM_HOME/tool-acquire.sh"
CODEX_THREAD_ID=T1 CODEX_SESSION_ID=T1 "$FM_HOME/tool-confirm.sh"
CODEX_THREAD_ID=T2 CODEX_SESSION_ID=T2 "$FM_HOME/tool-foreign.sh"
printf 'done\n' > "$FM_HOME/state/daemon-done"
while [ ! -e "$FM_HOME/state/stop-daemon" ]; do sleep 0.05; done
exit 0
SH
  chmod +x "$dir/tool-acquire.sh" "$dir/tool-confirm.sh" "$dir/tool-foreign.sh" "$dir/daemon-body.sh"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_LIB="$LIB" \
    FM_TEST_CODEX_BODY="$dir/daemon-body.sh" \
    "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_daemon_done "$dir/state/daemon-done" "the daemon-parented lock exercise"
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  BG_FIXTURE_PIDS+=("$daemon_pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "a daemon-parented session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/lock-after-acquire")" != "$daemon_pid" ] \
    || fail "the daemon-parented session anchored its lock on the shared daemon pid $daemon_pid"
  [ "$(tr -d '[:space:]' < "$dir/state/session-after-acquire")" = T1 ] \
    || fail "the daemon-parented session did not record its thread beside the lock"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same thread could not confirm its daemon-served lock: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/lock-after-confirm")" != "$(tr -d '[:space:]' < "$dir/state/lock-after-acquire")" ] \
    || fail "the same-thread confirmation retained the dead acquiring instance"
  [ "$(tr -d '[:space:]' < "$dir/state/foreign.rc")" != 0 ] \
    || fail "a different thread owned the daemon-served session's lock"
  : > "$dir/state/stop-daemon"
  pass "session-lock e2e: a daemon-parented Codex session acquires and keeps its lock by thread id, never on the daemon"
}

test_e2e_codex_dead_session_daemon_lock_reclaimed() {
  local dir daemon_pid session_pid
  dir="$TMP_ROOT/e2e-codex-daemon-reclaim"
  mkdir -p "$dir/state"
  cat > "$dir/daemon-body.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" > "$FM_HOME/state/daemon-pid"
while [ ! -e "$FM_HOME/state/stop-daemon" ]; do sleep 0.05; done
exit 0
SH
  chmod +x "$dir/daemon-body.sh"
  launch_codex_daemon "$dir" "$dir/daemon-body.sh"
  wait_for_file "$dir/state/daemon-pid" "the shared daemon pid"
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  BG_FIXTURE_PIDS+=("$daemon_pid")
  # The old code's lock: the shared daemon pid on line 1, no sidecar, while
  # the daemon itself stays alive the whole time.
  printf '%s\n' "$daemon_pid" > "$dir/state/.lock"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CODEX" -c '
      CODEX_THREAD_ID=T-new CODEX_SESSION_ID=T-new "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/session-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the replacement session could not reclaim a daemon-anchored lock: $(cat "$dir/state/reclaim.out")"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  kill -0 "$daemon_pid" 2>/dev/null || fail "the shared daemon died during the reclaim, so the case proves nothing"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session_pid" ] \
    || fail "the reclaim left lock line 1 at $(cat "$dir/state/.lock"), expected the replacement session $session_pid"
  [ "$(head -n 1 "$dir/state/.lock-session")" = T-new ] \
    || fail "the reclaim did not record the replacement thread beside the lock"
  : > "$dir/state/stop-daemon"
  pass "session-lock e2e: a dead session's daemon-anchored lock is reclaimed by its replacement through fm-lock.sh"
}

test_e2e_codex_foreign_acquisition_refused_while_owner_lives() {
  local dir daemon_pid anchor ready watcher_pid session_key
  dir="$TMP_ROOT/e2e-codex-foreign-acquire"
  mkdir -p "$dir/state"
  cat > "$dir/tool.sh" <<'SH'
#!/usr/bin/env bash
# $1 = result prefix; thread pair comes from the caller's environment.
"$FM_LOCK" > "$FM_HOME/state/$1.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/$1.rc"
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/$1.lock-after" 2>/dev/null || true
head -n 1 "$FM_HOME/state/.lock-session" > "$FM_HOME/state/$1.session-after" 2>/dev/null || true
SH
  cat > "$dir/daemon-body.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" > "$FM_HOME/state/daemon-pid"
printf '{"TA":"idle","TB":"active"}\n' > "$FM_HOME/state/thread-states.json"
CODEX_THREAD_ID=TA CODEX_SESSION_ID=TA "$FM_HOME/tool.sh" acquire
CODEX_THREAD_ID=TB CODEX_SESSION_ID=TB "$FM_HOME/tool.sh" steal
printf 'done\n' > "$FM_HOME/state/daemon-done"
while [ ! -e "$FM_HOME/state/stop-daemon" ]; do sleep 0.05; done
exit 0
SH
  chmod +x "$dir/tool.sh" "$dir/daemon-body.sh"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    FM_TEST_CODEX_BODY="$dir/daemon-body.sh" FM_TEST_CODEX_SOCKET="$TMP_ROOT/q.sock" \
    FM_TEST_CODEX_SERVER="$TMP_ROOT/native/server.py" \
    "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_daemon_done "$dir/state/daemon-done" "the foreign-acquisition exercise"
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  BG_FIXTURE_PIDS+=("$daemon_pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the daemon-served owner could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/acquire.lock-after")" != "$daemon_pid" ] \
    || fail "the daemon-served owner anchored on the shared daemon"
  [ "$(tr -d '[:space:]' < "$dir/state/steal.rc")" != 0 ] \
    || fail "a foreign thread acquired a live daemon-served owner's lock: $(cat "$dir/state/steal.out")"
  grep -q 'another live firstmate session holds the lock' "$dir/state/steal.out" \
    || fail "the foreign acquisition was not refused as a live owner: $(cat "$dir/state/steal.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/steal.lock-after")" = "$(tr -d '[:space:]' < "$dir/state/acquire.lock-after")" ] \
    || fail "the refused foreign acquisition rewrote lock line 1"
  [ "$(tr -d '[:space:]' < "$dir/state/steal.session-after")" = TA ] \
    || fail "the refused foreign acquisition rewrote the owner's sidecar"
  anchor=$(cat "$dir/state/.lock")
  if kill -0 "$anchor" 2>/dev/null; then fail "the acquiring helper did not exit"; fi
  if bash -c '. "$1"; fm_codex_session_identity_live TA' _ "$LIB"; then
    fail "the daemon-only fixture has an identity-bearing stand-in"
  fi
  bash -c '. "$1"; fm_session_lock_inspect "$2"; [ "$FM_LOCK_INSPECT_STATE" = held ] && [ "$FM_LOCK_INSPECT_OWNER_PID" = "$3" ]' \
    _ "$LIB" "$dir/state" "$daemon_pid" || fail "inspection lost the daemon-served owner"
  session_key=$(FM_HOME="$dir" STATE="$dir/state" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; fm_supervision_host_main_key "$STATE"' _ "$ROOT") \
    || fail "the daemon owner has no verified main-session key"
  printf 'branch\t%s\t100\n' "$anchor" > "$dir/state/.lease-t1"
  FM_HOME="$dir" STATE="$dir/state" bash -c '. "$1"; fm_lease_live t1' _ "$ROOT/bin/fm-lease-lib.sh" \
    || fail "a dead acquiring helper made the owner's lease stale"
  sleep 60 &
  watcher_pid=$!
  BG_FIXTURE_PIDS+=("$watcher_pid")
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$watcher_pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher_pid" \
    > "$dir/state/.watch.lock/pid-identity"
  touch "$dir/state/.last-watcher-beat"
  ready=$(env -u FM_SUPERVISION_MODEL FM_HOME="$dir" bash "$ROOT/bin/fm-inbox.sh" ready) \
    || fail "readiness failed for the daemon-served owner"
  printf '%s' "$ready" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["lock"]["state"] == "held" and r["wake_consumer"]["state"] == "healthy" and r["can_receive"] is True' \
    || fail "readiness lost the verified owner's harness: $ready"
  kill "$watcher_pid"
  wait "$watcher_pid" 2>/dev/null || true
  printf '{"TA":"notLoaded","TB":"active"}\n' > "$dir/state/thread-states.json"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    CODEX_THREAD_ID=TB CODEX_SESSION_ID=TB FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CODEX" -c '"$FM_HOME/tool.sh" reclaim'
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the foreign thread could not acquire after the daemon reported notLoaded: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.session-after")" = TB ] \
    || fail "the post-owner acquisition did not record its own thread"
  kill -0 "$daemon_pid" 2>/dev/null || fail "replacement required daemon shutdown"
  [ ! -e "$dir/state/.lease-t1" ] || fail "replacement revived the previous owner's lease"
  FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$anchor" FM_LEASE_HOLDER_SESSION="$session_key" \
    "$ROOT/bin/fm-lease.sh" claim stale-branch > "$dir/state/stale-branch.out" 2>&1
  expect_code 6 "$?" "the previous owner's branch acquired a lease after foreign takeover"
  [ ! -e "$dir/state/.lease-stale-branch" ] || fail "a previous branch published a stale lease"
  : > "$dir/state/stop-daemon"
  wait "$daemon_pid" || fail "the daemon failed to exit"
  pass "session-lock e2e: daemon thread state protects live owners and permits replacement while the daemon lives"
}

test_codex_retained_thread_requires_endpoint_stop_proof() {
  local dir fakebin case_spec status endpoint expected daemon_pid socket_index=0
  for case_spec in idle:alive:1 idle:gone:0 active:gone:1 systemError:alive:1 systemError:gone:0 idle:unreadable:1 idle:process-left:1 notLoaded:alive:0; do
    status=${case_spec%%:*}
    endpoint=${case_spec#*:}; endpoint=${endpoint%:*}
    expected=${case_spec##*:}
    dir="$TMP_ROOT/retained-$status-$endpoint"
    fakebin=$(fm_fakebin "$dir")
    mkdir -p "$dir/state"
    printf '{"TA":"%s","TB":"active"}\n' "$status" > "$dir/state/thread-states.json"
    printf 'backend=orca\nterminal=term-owner\nworktree=%s\nspawn_gen=s1.1.1\n' "$dir" > "$dir/endpoint.meta"
    cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'terminal show --terminal term-owner --json')
    python3 - <<'PYTHON'
import json,os
phase=os.environ['FM_TEST_ENDPOINT_PHASE']
if phase == 'unreadable':
    print('unreadable')
else:
    print(json.dumps({'ok':True,'result':{'terminal':{'handle':'term-owner','connected':phase=='alive','writable':phase=='alive','executionHostId':'local','ptyId':'owner-pty','worktreePath':os.environ['FM_HOME'],'exitCause':{'kind':'exit'}}}}))
PYTHON
    ;;
  'diagnostics memory --json') printf '{"ok":true,"result":{"worktrees":[]}}\n' ;;
  *) exit 1 ;;
esac
SH
    cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' -d cwd '*)
    if [ "$FM_TEST_ENDPOINT_PHASE" = process-left ]; then
      printf 'p%s\nn%s\n' "$(cat "$FM_HOME/state/daemon-pid")" "$FM_HOME"
    else
      printf 'p1\nn/\n'
    fi
    exit 0
    ;;
esac
SH
    printf 'exec %q "$@"\n' "$(command -v lsof)" >> "$fakebin/lsof"
    chmod +x "$fakebin/orca" "$fakebin/lsof"
    cat > "$dir/body.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" > "$FM_HOME/state/daemon-pid"
CODEX_THREAD_ID=TA CODEX_SESSION_ID=TA "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/acquire.rc"
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/owner-record"
CODEX_THREAD_ID=TB CODEX_SESSION_ID=TB "$FM_LOCK" > "$FM_HOME/state/foreign.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/foreign.rc"
printf done > "$FM_HOME/state/done"
while [ ! -e "$FM_HOME/state/stop" ]; do sleep 0.05; done
SH
    socket_index=$((socket_index + 1))
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
      FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_SESSION_ENDPOINT_META="$dir/endpoint.meta" \
      FM_TEST_ENDPOINT_PHASE="$endpoint" PATH="$fakebin:$PATH" \
      FM_TEST_CODEX_BODY="$dir/body.sh" FM_TEST_CODEX_SOCKET="$TMP_ROOT/t$socket_index.sock" \
      FM_TEST_CODEX_SERVER="$TMP_ROOT/native/server.py" \
      "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon &
    daemon_pid=$!
    BG_FIXTURE_PIDS+=("$daemon_pid")
    wait_for_daemon_done "$dir/state/done" "the retained $status/$endpoint exercise"
    expect_code 0 "$(cat "$dir/state/acquire.rc")" "retained-thread setup failed: $(cat "$dir/state/acquire.out")"
    [ "$(sed -n 's/^terminal=//p' "$dir/state/owner-record")" = term-owner ] || fail "acquisition did not snapshot its supervisor endpoint"
    expect_code "$expected" "$(cat "$dir/state/foreign.rc")" "$status/$endpoint: incorrect foreign acquisition verdict: $(cat "$dir/state/foreign.out")"
    kill -0 "$daemon_pid" 2>/dev/null || fail "retained-thread acquisition required daemon shutdown"
    if [ "$expected" -ne 0 ]; then
      cmp -s "$dir/state/.lock-session" "$dir/state/owner-record" || fail "a refused takeover changed the recorded owner"
    fi
    : > "$dir/state/stop"
    wait "$daemon_pid" || fail "retained-thread fixture failed to exit"
  done
  pass "session-lock: retained idle and errored threads need endpoint stop proof; active threads refuse"
}

test_codex_restart_reanchors_same_thread() {
  local dir shape daemon_pid first_daemon old_anchor new_anchor replacement_pid first_key next_key claim_rc
  for shape in dead reused; do
    dir="$TMP_ROOT/restart-$shape"
    mkdir -p "$dir/state"
    printf '{"T1":"idle"}\n' > "$dir/state/thread-states.json"
    cat > "$dir/body.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" > "$FM_HOME/state/daemon-pid"
CODEX_THREAD_ID=T1 CODEX_SESSION_ID=T1 "$FM_LOCK" > "$FM_HOME/state/$FM_TEST_PHASE.out" 2>&1 &
acquiring=$!
wait "$acquiring"
printf '%s\n' "$?" > "$FM_HOME/state/$FM_TEST_PHASE.rc"
printf '%s\n' "$acquiring" > "$FM_HOME/state/$FM_TEST_PHASE.pid"
printf 'done\n' > "$FM_HOME/state/$FM_TEST_PHASE.done"
while [ ! -e "$FM_HOME/state/stop-$FM_TEST_PHASE" ]; do sleep 0.05; done
SH
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
      FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_TEST_PHASE=first \
      FM_TEST_CODEX_BODY="$dir/body.sh" FM_TEST_CODEX_SOCKET="$TMP_ROOT/r.sock" \
      FM_TEST_CODEX_SERVER="$TMP_ROOT/native/server.py" \
      "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon &
    daemon_pid=$!
    first_daemon=$daemon_pid
    BG_FIXTURE_PIDS+=("$daemon_pid")
    wait_for_daemon_done "$dir/state/first.done" "the initial daemon acquisition"
    expect_code 0 "$(cat "$dir/state/first.rc")" "initial acquisition failed: $(cat "$dir/state/first.out")"
    old_anchor=$(cat "$dir/state/.lock")
    first_key=$(FM_HOME="$dir" STATE="$dir/state" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; fm_supervision_host_main_key "$STATE"' _ "$ROOT") \
      || fail "a dead acquiring helper broke the supervision key"
    : > "$dir/state/stop-first"
    wait "$daemon_pid" || fail "the first daemon failed to exit"
    if [ "$shape" = reused ]; then
      sleep 60 &
      replacement_pid=$!
      BG_FIXTURE_PIDS+=("$replacement_pid")
      old_anchor=$replacement_pid
      printf '%s\n' "$old_anchor" > "$dir/state/.lock"
      sed -e "s/^anchor_pid=.*/anchor_pid=$old_anchor/" -e 's/^anchor_start=.*/anchor_start=0/' \
        "$dir/state/.lock-session" > "$dir/state/sidecar-reused"
      mv "$dir/state/sidecar-reused" "$dir/state/.lock-session"
    fi
    printf 'branch\t%s\t100\n' "$old_anchor" > "$dir/state/.lease-t1"
    printf 'main\t%s\t200\n' "$old_anchor" > "$dir/state/.lease-t2.lock"
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
      FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_TEST_PHASE=second \
      FM_TEST_CODEX_BODY="$dir/body.sh" FM_TEST_CODEX_SOCKET="$TMP_ROOT/r.sock" \
      FM_TEST_CODEX_SERVER="$TMP_ROOT/native/server.py" \
      "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon &
    daemon_pid=$!
    BG_FIXTURE_PIDS+=("$daemon_pid")
    wait_for_daemon_done "$dir/state/second.done" "same-thread acquisition after restart"
    expect_code 0 "$(cat "$dir/state/second.rc")" "$shape: restart acquisition failed: $(cat "$dir/state/second.out")"
    new_anchor=$(cat "$dir/state/.lock")
    [ "$new_anchor" = "$(cat "$dir/state/second.pid")" ] && [ "$new_anchor" != "$old_anchor" ] \
      || fail "$shape: restart reused the previous anchor"
    [ "$(sed -n 's/^anchor_pid=//p' "$dir/state/.lock-session")" = "$new_anchor" ] \
      || fail "$shape: sidecar did not record the new anchor instance"
    [ "$(sed -n 's/^codex_daemon_pid=//p' "$dir/state/.lock-session")" = "$daemon_pid" ] && [ "$daemon_pid" != "$first_daemon" ] \
      || fail "$shape: sidecar retained the previous daemon instance"
    [ "$(cat "$dir/state/.lease-t1")" = "$(printf 'branch\t%s\t100' "$new_anchor")" ] \
      || fail "$shape: same-thread recovery lost the task lease"
    [ "$(cat "$dir/state/.lease-t2.lock")" = "$(printf 'main\t%s\t200' "$new_anchor")" ] \
      || fail "$shape: recovery skipped a valid task id ending in .lock"
    STATE="$dir/state" bash -c '. "$1"; fm_lease_live t1' _ "$ROOT/bin/fm-lease-lib.sh" \
      || fail "$shape: the moved lease is not live"
    next_key=$(FM_HOME="$dir" STATE="$dir/state" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; fm_supervision_host_main_key "$STATE"' _ "$ROOT") \
      || fail "the re-anchored supervisor has no main-session key"
    [ "$first_key" = "$next_key" ] || fail "a helper re-anchor changed the supervision session key"
    FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$old_anchor" FM_LEASE_HOLDER_SESSION="$first_key" \
      "$ROOT/bin/fm-lease.sh" claim later-task > "$dir/state/later-claim.out" 2>&1 \
      || fail "a branch pinned before re-anchoring could not claim: $(cat "$dir/state/later-claim.out")"
    [ "$(cut -f2 "$dir/state/.lease-later-task")" = "$new_anchor" ] || fail "the branch wrote its dead pinned pid"
    FM_HOME="$dir" "$ROOT/bin/fm-lease.sh" claim later-task > "$dir/state/main-claim.out" 2>&1
    claim_rc=$?
    expect_code 6 "$claim_rc" "main stole a task held by the re-anchored branch"
    FM_HOME="$dir" STATE="$dir/state" FM_SUPERVISION_ENGINE=claude FM_SUPERVISION_ENGINE_MODEL=sonnet \
      bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; key=$(fm_supervision_host_health_key "$STATE") || exit 1; printf "key=%s\nerrors=2\ncooldown=300\nretry_after=9999999999\n" "$key" > "$STATE/.supervision-host-health"; [ "$(fm_supervision_host_paused_until "$STATE")" = 9999999999 ]' _ "$ROOT" \
      || fail "the dead-anchor supervisor could not retain its error cooldown"
    : > "$dir/state/stop-second"
    wait "$daemon_pid" || fail "the second daemon failed to exit"
    if [ "$shape" = reused ]; then kill "$replacement_pid"; wait "$replacement_pid" 2>/dev/null || true; fi
  done
  pass "session-lock: daemon restart re-anchors dead and reused instances while preserving same-thread leases"
}

test_reused_anchor_instance_does_not_inherit_ownership() {
  local dir
  dir="$TMP_ROOT/reused-anchor"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf 'ended-owner\nanchor_pid=%s\nanchor_start=0\n' "$$" > "$FM_HOME/state/.lock-session"
printf 'branch\t%s\t100\n' "$$" > "$FM_HOME/state/.lease-t1"
printf 'main\t%s\t200\n' "$$" > "$FM_HOME/state/.lease-t1.lock"
bash -c '. "$1"; ! fm_session_lock_owned_by_self "$2"' _ "$FM_LIB" "$FM_HOME/state" || exit 1
STATE="$FM_HOME/state" bash -c '. "$1"; ! fm_lease_live t1' _ "$FM_ROOT/bin/fm-lease-lib.sh" || exit 2
"$FM_ROOT/bin/fm-lock.sh" || exit 3
STATE="$FM_HOME/state" bash -c '. "$1"; ! fm_lease_live t1 && [ ! -e "$STATE/.lease-t1" ] && [ ! -e "$STATE/.lease-t1.lock" ]' _ "$FM_ROOT/bin/fm-lease-lib.sh" || exit 5
bash -c '. "$1"; fm_session_lock_anchor_instance_matches "$2" && fm_session_lock_owned_by_self "$2"' _ "$FM_LIB" "$FM_HOME/state" || exit 4
SH
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
    FM_HOME="$dir" FM_ROOT="$ROOT" FM_LIB="$LIB" "$NAMED_CODEX" "$dir/run.sh" \
    > "$dir/result" 2>&1 || fail "reused anchor inherited ownership or failed fresh acquisition: $(cat "$dir/result")"
  pass "session-lock: a mismatched kernel start time cannot inherit ownership or leases"
}

test_codex_stop_binds_checkpoint_descendant() {
  local dir thread expected
  for thread in T1 T2 none; do
    dir="$TMP_ROOT/checkpoint-descendant-$thread"
    mkdir -p "$dir/state" "$dir/checkpoint"
    git init -q "$dir"
    : > "$dir/AGENTS.md"
    : > "$dir/state/task.meta"
    cp -R "$ROOT/bin" "$dir/bin"
    cat > "$dir/watcher.py" <<'PYTHON'
import os
from pathlib import Path
import time

Path(os.environ['FM_HOME'], 'state', 'watcher-ready').touch()
time.sleep(30)
PYTHON
    cat > "$dir/checkpoint/fm-watch-checkpoint.sh" <<'SH'
#!/usr/bin/env bash
if [ "$FM_TEST_CHECKPOINT_THREAD" = none ]; then
  python3 "$FM_HOME/watcher.py" &
else
  CODEX_THREAD_ID="$FM_TEST_CHECKPOINT_THREAD" CODEX_SESSION_ID="$FM_TEST_CHECKPOINT_THREAD" python3 "$FM_HOME/watcher.py" &
fi
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
i=0
while [ ! -e "$FM_HOME/state/watcher-ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$FM_HOME/state/watcher-ready" ] || exit 1
. "$FM_HOME/bin/fm-wake-lib.sh"
mkdir -p "$FM_HOME/state/.watch.lock"
printf '%s\n' "$pid" > "$FM_HOME/state/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$FM_HOME/state/.watch.lock/fm-home"
printf '%s\n' "$FM_HOME/bin/fm-watch.sh" > "$FM_HOME/state/.watch.lock/watcher-path"
fm_pid_identity "$pid" > "$FM_HOME/state/.watch.lock/pid-identity"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'ready\n' > "$FM_HOME/state/checkpoint-ready"
wait "$pid"
SH
    cat > "$dir/body.sh" <<'SH'
#!/usr/bin/env bash
"$FM_HOME/checkpoint/fm-watch-checkpoint.sh" &
checkpoint=$!
trap 'kill "$checkpoint" 2>/dev/null || true; wait "$checkpoint" 2>/dev/null || true' EXIT
i=0
while [ ! -s "$FM_HOME/state/checkpoint-ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$FM_HOME/state/checkpoint-ready" ] || exit 1
reader="$FM_HOME/bin/fm-session-process.py"
if python3 "$reader" bound "$checkpoint" T1; then exit 2; fi
watcher=$(cat "$FM_HOME/state/.watch.lock/pid")
if [ "$FM_TEST_CHECKPOINT_THREAD" = none ]; then
  if python3 "$reader" bound "$watcher" T1; then exit 3; fi
else
  python3 "$reader" bound "$watcher" "$FM_TEST_CHECKPOINT_THREAD" || exit 4
fi
printf '%s\n' '{"session_id":"T1","turn_id":"checkpoint","stop_hook_active":false}' \
  | CODEX_THREAD_ID=T1 CODEX_SESSION_ID=T1 "$FM_HOME/bin/fm-turnend-guard.sh" > "$FM_HOME/state/guard.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/guard.rc"
SH
    chmod +x "$dir/checkpoint/fm-watch-checkpoint.sh"
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u CODEX_SESSION_ID \
      FM_HOME="$dir" FM_TEST_CODEX_BODY="$dir/body.sh" FM_TEST_CHECKPOINT_THREAD="$thread" \
      "$NATIVE_CODEX" app-server --listen unix:// --managed-daemon \
      || fail "$thread: checkpoint fixture lost its intended process identity (exit $?)"
    expected=0
    [ "$thread" != T1 ] || expected=2
    expect_code "$expected" "$(cat "$dir/state/guard.rc")" "$thread: wrong Stop verdict with an unbound checkpoint shell: $(cat "$dir/state/guard.out")"
  done
  pass "session-lock: Stop binds checkpoint descendants and rejects foreign or absent thread identity"
}

if [ "${FM_TEST_ONLY:-}" = codex-checkpoint-descendant ]; then
  test_codex_stop_binds_checkpoint_descendant
  exit 0
fi

test_codex_stop_binds_checkpoint_descendant
test_version_named_session_is_identified_on_both_platforms
test_muse_versioned_session_is_identified
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
test_codex_daemon_parented_tool_shell
test_codex_direct_tui_launch
test_codex_two_sessions_one_daemon_never_cross_own
test_codex_thread_id_trust_gate
test_codex_thread_binding
test_reused_anchor_instance_does_not_inherit_ownership
test_codex_restart_reanchors_same_thread
test_codex_retained_thread_requires_endpoint_stop_proof
test_e2e_codex_daemon_parented_session_acquires_by_thread
test_e2e_codex_dead_session_daemon_lock_reclaimed
test_e2e_codex_foreign_acquisition_refused_while_owner_lives
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar
test_reanchor_keeps_task_leases_live
test_reanchor_keeps_autoarm_midturn_healthy
