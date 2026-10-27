import ctypes
import os
from pathlib import Path
import struct
import subprocess
import sys


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


def main():
    action, value = sys.argv[1:3]
    if action == "start":
        print(start_time(value))
    elif action == "class":
        print(process_class(process_fields(value)[0]))
    elif action == "bound":
        return 0 if bound(value, os.fsencode(sys.argv[3])) else 1
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
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        sys.exit(1)
