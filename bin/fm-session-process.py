import ctypes
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time


def process_fields(pid):
    if sys.platform != "darwin":
        root = Path("/proc") / str(pid)
        argv = root.joinpath("cmdline").read_bytes().rstrip(b"\0").split(b"\0")
        try:
            env = root.joinpath("environ").read_bytes().rstrip(b"\0").split(b"\0")
        except OSError:
            env = []
        return argv, env
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 2)(1, 8)
    maximum = ctypes.c_int()
    size = ctypes.c_size_t(ctypes.sizeof(maximum))
    if libc.sysctl(mib, 2, ctypes.byref(maximum), ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno())
    buf = ctypes.create_string_buffer(maximum.value)
    size = ctypes.c_size_t(len(buf))
    mib = (ctypes.c_int * 3)(1, 49, int(pid))
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno())
    data = buf.raw[:size.value]
    argc = struct.unpack_from("i", data)[0]
    offset = data.index(b"\0", 4)
    while offset < len(data) and data[offset] == 0:
        offset += 1
    fields = data[offset:].split(b"\0")
    return fields[:argc], fields[argc:]


def start_time(pid):
    if sys.platform != "darwin":
        data = Path("/proc", str(pid), "stat").read_text()
        return data.rsplit(")", 1)[1].split()[19]
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    buf = ctypes.create_string_buffer(136)
    if libproc.proc_pidinfo(int(pid), 3, 0, buf, len(buf)) != len(buf):
        raise OSError(ctypes.get_errno())
    seconds, micros = struct.unpack_from("QQ", buf.raw, 120)
    return f"{seconds}.{micros:06d}"


def process_class(argv):
    if not argv:
        return "unknown"
    if os.path.basename(argv[0]) == b"codex-code-mode-host":
        return "host"
    if len(argv) >= 3 and argv[1:3] == [b"app-server", b"daemon"]:
        return "daemon"
    if len(argv) >= 2 and argv[1] == b"app-server" and b"--managed-daemon" in argv[2:]:
        return "daemon"
    return "session"


def bound(pid, identity):
    argv, env = process_fields(pid)
    if (os.path.basename(argv[0]) == b"codex" and len(argv) >= 3
            and argv[1:3] == [b"resume", identity]):
        return True
    return b"CODEX_THREAD_ID=" + identity in env and b"CODEX_SESSION_ID=" + identity in env


def thread_status(pid, identity, expected_start):
    if start_time(pid) != expected_start or process_class(process_fields(pid)[0]) != "daemon":
        raise ValueError("daemon instance changed")
    if sys.platform == "darwin":
        output = subprocess.check_output(
            ["lsof", "-nP", "-a", "-p", str(pid), "-U", "-Fn"], timeout=3, text=True
        )
        paths = {line[1:] for line in output.splitlines() if line.startswith("n/")}
    else:
        inodes = set()
        for fd in Path("/proc", str(pid), "fd").iterdir():
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
        paths = set()
        for line in Path("/proc", str(pid), "net/unix").read_text().splitlines()[1:]:
            fields = line.split(None, 7)
            if len(fields) == 8 and fields[6] in inodes and int(fields[3], 16) & 0x10000:
                if fields[7].startswith("/"):
                    paths.add(fields[7])
    if len(paths) != 1:
        raise ValueError("daemon control socket is unavailable or ambiguous")
    deadline = time.monotonic() + 5
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(paths.pop())
        key = base64.b64encode(os.urandom(16)).decode()
        connection.sendall((
            "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Key: {key}\r\n\r\n"
        ).encode())
        buffered = bytearray()

        def receive_more():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("thread query timed out")
            connection.settimeout(remaining)
            data = connection.recv(65536)
            if not data:
                raise ValueError("control socket closed")
            buffered.extend(data)

        while b"\r\n\r\n" not in buffered:
            receive_more()
            if len(buffered) > 65536:
                raise ValueError("invalid WebSocket upgrade")
        header, remainder = bytes(buffered).split(b"\r\n\r\n", 1)
        buffered[:] = remainder
        headers = dict(line.split(b":", 1) for line in header.split(b"\r\n")[1:])
        headers = {name.lower(): value.strip() for name, value in headers.items()}
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest())
        if not header.startswith(b"HTTP/1.1 101 ") or headers.get(b"sec-websocket-accept") != accept:
            raise ValueError("WebSocket upgrade refused")

        def read(size):
            while len(buffered) < size:
                receive_more()
            value = bytes(buffered[:size])
            del buffered[:size]
            return value

        def send_frame(opcode, data):
            size = len(data)
            if size < 126:
                prefix = bytes([0x80 | opcode, 0x80 | size])
            else:
                prefix = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack("!H", size)
            mask = os.urandom(4)
            connection.sendall(prefix + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

        def send(message):
            send_frame(1, json.dumps(message).encode())

        def response(request_id):
            message = bytearray()
            while True:
                first, second = read(2)
                opcode, size = first & 15, second & 127
                if size == 126:
                    size = struct.unpack("!H", read(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", read(8))[0]
                if second & 128 or size + len(message) > 4 * 1024 * 1024:
                    raise ValueError("invalid WebSocket frame")
                data = read(size)
                if opcode == 9:
                    send_frame(10, data)
                    continue
                if opcode == 10:
                    continue
                if opcode not in (0, 1):
                    raise ValueError("unexpected WebSocket frame")
                message.extend(data)
                if first & 128:
                    result = json.loads(message)
                    message.clear()
                    if result.get("id") == request_id:
                        if "error" in result:
                            raise ValueError("control query rejected: " + json.dumps(result["error"]))
                        return result["result"]

        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "firstmate_session_lock", "version": "1.0"},
        }})
        response(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "thread/read", "params": {
            "threadId": identity, "includeTurns": False,
        }})
        thread = response(2)["thread"]
        status = thread["status"]["type"]
        if thread["id"] != identity or status not in ("active", "idle", "systemError", "notLoaded"):
            raise ValueError("unrecognized thread status")
        if start_time(pid) != expected_start:
            raise ValueError("daemon instance changed")
        return status


def main():
    action, value = sys.argv[1:3]
    if action == "start":
        print(start_time(value))
    elif action == "class":
        print(process_class(process_fields(value)[0]))
    elif action == "bound":
        return 0 if bound(value, os.fsencode(sys.argv[3])) else 1
    elif action == "thread":
        print(thread_status(value, sys.argv[3], sys.argv[4]))
    elif action == "scan":
        rows = subprocess.check_output(["ps", "-eo", "pid=,ppid=,comm="], text=True)
        for row in rows.splitlines():
            fields = row.split(None, 2)
            if len(fields) != 3 or not fields[0].isdigit():
                continue
            try:
                if bound(fields[0], os.fsencode(value)):
                    print(fields[0])
                    return 0
            except (OSError, ValueError, IndexError):
                continue
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        if len(sys.argv) > 1 and sys.argv[1] == "thread":
            print(f"thread query unavailable: {error}", file=sys.stderr)
            sys.exit(2)
        sys.exit(1)
