import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import time

queue, bash, directory = sys.argv[1:]
case = Path(directory)
spool = case / "spool"
env = dict(os.environ, HISTFILE="", PS1="QUEUE-CALLER> ", BASH_SILENCE_DEPRECATION_WARNING="1")
prompt = b"QUEUE-CALLER> "
caller, terminal = os.forkpty()
if caller == 0:
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


def status():
    return subprocess.check_output([bash, queue, "status"], env=env, text=True)


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
    if not reaped:
        os.kill(caller, signal.SIGKILL)
        os.waitpid(caller, 0)
    os.close(terminal)
