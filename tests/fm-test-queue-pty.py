import fcntl
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

queue, bash, directory = sys.argv[1:]
case = Path(directory)
spool = case / "spool"
env = dict(os.environ, HISTFILE="", PS1="QUEUE-CALLER> ", BASH_SILENCE_DEPRECATION_WARNING="1")
prompt = b"QUEUE-CALLER> "
caller, terminal = os.forkpty()
if caller == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    for sig in (signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU, signal.SIGCHLD):
        signal.signal(sig, signal.SIG_DFL)
    os.execvpe(bash, [bash, "--noprofile", "--norc", "-i"], env)

output = bytearray()
cursor = 0
wrappers = set()
reaped = False


def drain():
    if select.select([terminal], [], [], 0.05)[0]:
        try:
            output.extend(os.read(terminal, 8192))
        except OSError:
            pass


def until(description, predicate):
    deadline = time.monotonic() + 15
    while not predicate():
        assert time.monotonic() < deadline, f"{description}: {output[-3000:]!r}"
        drain()


def receive(value):
    global cursor
    until(f"terminal output {value!r}", lambda: value in output[cursor:])
    cursor = output.index(value, cursor) + len(value)


def send(value):
    os.write(terminal, value.encode())


def status(environment=None):
    return subprocess.check_output([bash, queue, "status"], env=environment or env, text=True)


def tickets():
    records = []
    for ticket in (spool / "tickets").glob("[0-9]*"):
        if ".tmp." not in ticket.name:
            try:
                records.append(dict(line.split("=", 1) for line in ticket.read_text().splitlines()))
            except FileNotFoundError:
                pass
    return records


def record(label):
    return next(item for item in tickets() if item.get("label") == label)


def command(label, program):
    path = case / f"{label}.sh"
    path.write_text(program)
    return shlex.join([bash, queue, "run", "--label", label, "--", bash, str(path), str(case)])


def background(label, program):
    pidfile = case / f"{label}.wrapper"
    send(command(label, program) + " & jobs -p %+ > " + shlex.quote(str(pidfile)) + "\n")
    receive(prompt)
    until(f"{label} wrapper pid", pidfile.exists)
    pid = int(pidfile.read_text())
    wrappers.add(pid)
    return pid


try:
    receive(prompt)
    first = background(
        "background",
        ': > "$1/background.ran"\nwhile [ ! -e "$1/release-background" ]; do sleep 0.05; done\nexit 11\n',
    )
    until("background workload admission", (case / "background.ran").exists)
    assert "serving=1 waiting=0 stale=0 " in status()
    assert int(record("background")["pid"]) == first
    assert record("background")["pgid"]
    assert os.tcgetpgrp(terminal) == caller, "background admission took the terminal"

    second = background("queued", ': > "$1/queued.ran"\n')
    until("background follower waiting", lambda: "serving=1 waiting=1 stale=0 " in status())
    assert not (case / "queued.ran").exists(), "background follower bypassed the occupied slot"
    assert os.tcgetpgrp(terminal) == caller, "background waiter took the terminal"
    (case / "release-background").touch()
    send(f'wait {first}; printf "BACKGROUND-RC=%s\\n" "$?"\n')
    receive(b"BACKGROUND-RC=11\r\n")
    receive(prompt)
    wrappers.remove(first)
    send(f'wait {second}; printf "FOLLOWER-RC=%s\\n" "$?"\n')
    receive(b"FOLLOWER-RC=0\r\n")
    receive(prompt)
    wrappers.remove(second)
    assert (case / "queued.ran").exists()
    assert "serving=0 waiting=0 stale=0 " in status()

    promoted = background("promoted", '\n'.join([
        # Bash may continue an untrapped loop if its sleep misses SIGINT.
        "trap 'exit 130' INT",
        'echo $$ > "$1/promoted.child"', 'counter=0', 'while :; do',
        'counter=$((counter + 1))', 'echo "$counter" > "$1/heartbeat"', 'sleep 0.05', 'done', '',
    ]))
    until("promoted workload started", (case / "heartbeat").exists)
    promoted_child = int((case / "promoted.child").read_text())
    send("fg\n")
    until("background job promoted", lambda: os.tcgetpgrp(terminal) == promoted)
    os.write(terminal, b"\x1a")
    receive(prompt)
    child_state = subprocess.check_output(["ps", "-p", str(promoted_child), "-o", "stat="], text=True).strip()
    assert child_state.startswith("T"), "promoted workload continued after Ctrl-Z stopped its wrapper"
    owner = record("promoted")
    assert int(owner["child_pid"]) == promoted_child
    assert int(owner["pgid"]) == promoted
    assert os.getpgid(promoted_child) == os.getpgid(promoted)
    stopped_heartbeat = (case / "heartbeat").read_text()
    until("promoted job still holds its slot", lambda: "serving=1 waiting=0 stale=0 " in status())
    assert (case / "heartbeat").read_text() == stopped_heartbeat
    send("bg\n")
    receive(prompt)
    until("background continuation", lambda: (case / "heartbeat").read_text() not in ("", stopped_heartbeat))
    assert os.tcgetpgrp(terminal) == caller, "bg took the caller's terminal"
    send('fg; printf "PROMOTED-RC=%s\\n" "$?"\n')
    until("continued background job promoted again", lambda: os.tcgetpgrp(terminal) == promoted)
    os.write(terminal, b"\x03")
    receive(b"PROMOTED-RC=130\r\n")
    receive(prompt)
    wrappers.remove(promoted)
    # Signal cleanup may leave a stale record for the next admission to reclaim.
    until("interrupted workload releases its slot", lambda: "serving=0 waiting=0 " in status())

    (case / "grandchild.sh").write_text(
        ': > "$1/grandchild.ran"\nwhile [ ! -e "$1/release-grandchild" ]; do sleep 0.05; done\n'
    )
    leader = background("leader", '\n'.join([
        'echo $$ > "$1/leader.child"',
        shlex.quote(bash) + ' "$1/grandchild.sh" "$1" &',
        'while [ ! -e "$1/release-parent" ]; do sleep 0.05; done', '',
    ]))
    until("leader grandchild started", (case / "grandchild.ran").exists)
    owner = record("leader")
    direct_child = int((case / "leader.child").read_text())
    assert int(owner["child_pid"]) == direct_child
    child_start = subprocess.check_output(
        ["ps", "-p", str(direct_child), "-o", "lstart="], env=dict(env, TZ="UTC", LC_ALL="C"), text=True
    ).strip()
    assert owner["child_start"] == child_start
    assert int(owner["pgid"]) == leader
    os.kill(leader, signal.SIGKILL)
    send(f'wait {leader}; printf "KILLED-RC=%s\\n" "$?"\n')
    receive(b"KILLED-RC=137\r\n")
    receive(prompt)
    wrappers.remove(leader)
    assert "serving=1 waiting=0 stale=0 " in status()
    os.kill(direct_child, signal.SIGKILL)
    assert "serving=1 waiting=0 stale=0 " in status(), "live leader group lost its slot"
    fakebin = case / "fakebin"
    fakebin.mkdir()
    probe = fakebin / "ps"
    probe.write_text('#!/bin/sh\n[ "$1" != -axo ] || exit 1\nexec "$REAL_PS" "$@"\n')
    probe.chmod(0o700)
    failed_probe_env = dict(env, PATH=str(fakebin) + os.pathsep + env["PATH"], REAL_PS=shutil.which("ps"))
    assert "serving=1 waiting=0 stale=0 " in status(failed_probe_env)
    follower = background("group-follower", ': > "$1/group-follower.ran"\n')
    until("follower waits for surviving leader group", lambda: "serving=1 waiting=1 stale=0 " in status())
    assert not (case / "group-follower.ran").exists()
    (case / "release-grandchild").touch()
    send(f'wait {follower}; printf "GROUP-FOLLOWER-RC=%s\\n" "$?"\n')
    receive(b"GROUP-FOLLOWER-RC=0\r\n")
    receive(prompt)
    wrappers.remove(follower)
    assert (case / "group-follower.ran").exists()
    assert "serving=0 waiting=0 stale=0 " in status()

    send(command("foreground", '\n'.join([
        "echo READY-1", "IFS= read -r line", 'echo "RECEIVED=$line"',
        "echo READY-2", "IFS= read -r line", 'echo "RECEIVED=$line"',
        "echo READY-3", "IFS= read -r line", 'echo "RECEIVED=$line"', "exit 23", "",
    ])) + "\n")
    receive(b"READY-1\r\n")
    owner = record("foreground")
    wrapper, group = int(owner["pid"]), int(owner["pgid"])
    wrappers.add(wrapper)
    until("foreground workload terminal", lambda: os.tcgetpgrp(terminal) == group)
    send("alpha\n")
    receive(b"RECEIVED=alpha\r\n")
    receive(b"READY-2\r\n")
    for index, line in enumerate(("beta", "gamma"), 1):
        os.write(terminal, b"\x1a")
        receive(prompt)
        jobfile = case / f"stopped-jobs-{index}"
        send("jobs -sp > " + shlex.quote(str(jobfile)) + "\n")
        receive(prompt)
        assert str(wrapper) in jobfile.read_text().split(), "caller lost the suspended wrapper"
        assert "serving=1 waiting=0 stale=0 " in status()
        if index == 1:
            send("fg\n")
        else:
            send('fg; printf "FOREGROUND-RC=%s\\n" "$?"\n')
        until("resumed workload terminal", lambda: os.tcgetpgrp(terminal) == group)
        send(line + "\n")
        receive(f"RECEIVED={line}\r\n".encode())
        if index == 1:
            receive(b"READY-3\r\n")
    receive(b"FOREGROUND-RC=23\r\n")
    receive(prompt)
    wrappers.remove(wrapper)
    assert "serving=0 waiting=0 stale=0 " in status()

    send(command("interrupt", "echo INTERRUPT-READY\nexec cat\n") + '; printf "INTERRUPT-RC=%s\\n" "$?"\n')
    receive(b"INTERRUPT-READY\r\n")
    owner = record("interrupt")
    wrapper, group = int(owner["pid"]), int(owner["pgid"])
    wrappers.add(wrapper)
    until("interrupt workload terminal", lambda: os.tcgetpgrp(terminal) == group)
    os.write(terminal, b"\x03")
    receive(b"INTERRUPT-RC=130\r\n")
    receive(prompt)
    wrappers.remove(wrapper)
    assert "serving=0 waiting=0 stale=0 " in status()
    assert os.tcgetpgrp(terminal) == caller
    send("exit\n")

    def caller_exited():
        global reaped
        done, _ = os.waitpid(caller, os.WNOHANG)
        reaped = done == caller
        return reaped

    until("caller exit", caller_exited)
finally:
    (case / "release-background").touch()
    (case / "release-grandchild").touch()
    (case / "release-parent").touch()
    for item in tickets():
        if item.get("pgid"):
            try:
                os.killpg(int(item["pgid"]), signal.SIGKILL)
            except ProcessLookupError:
                pass
    for wrapper in wrappers:
        try:
            os.kill(wrapper, signal.SIGKILL)
        except ProcessLookupError:
            pass
    os.close(terminal)
    if not reaped:
        os.kill(caller, signal.SIGKILL)
        os.waitpid(caller, 0)
