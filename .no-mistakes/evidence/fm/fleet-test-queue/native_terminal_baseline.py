import fcntl
import os
from pathlib import Path
import select
import shlex
import signal
import struct
import termios
import time

root = Path.cwd()
case = root / '.queue-validation-tmp/native-baseline'
case.mkdir(exist_ok=True)
program = case / 'heartbeat.sh'
program.write_text('counter=0\nwhile :; do counter=$((counter+1)); echo "$counter" > "$1"; sleep .05; done\n')
outpath = Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q/native-terminal-baseline.txt')
log = outpath.open('w')
for n in range(10):
    caller, terminal = os.forkpty()
    if caller == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        for sig in (signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU, signal.SIGCHLD):
            signal.signal(sig, signal.SIG_DFL)
        os.execve('/bin/bash', ['/bin/bash', '--noprofile', '--norc', '-i'], dict(os.environ, PS1='BASE> ', HISTFILE=''))
    output = bytearray()
    group = None
    def until(pred):
        deadline = time.monotonic() + 5
        while not pred():
            if time.monotonic() > deadline:
                return False
            if select.select([terminal], [], [], .05)[0]:
                try:
                    output.extend(os.read(terminal, 8192))
                except OSError:
                    return False
        return True
    def send(text):
        os.write(terminal, text.encode())
    try:
        assert until(lambda: b'BASE> ' in output)
        heartbeat = case / f'heartbeat-{n}'
        pidfile = case / f'pid-{n}'
        heartbeat.unlink(missing_ok=True)
        pidfile.unlink(missing_ok=True)
        send(shlex.join(['/bin/bash', str(program), str(heartbeat)]) + ' & jobs -p %+ > ' + shlex.quote(str(pidfile)) + '\n')
        assert until(lambda: pidfile.exists() and pidfile.read_text().strip() and heartbeat.exists())
        group = int(pidfile.read_text())
        send('fg\n')
        assert until(lambda: os.tcgetpgrp(terminal) == group)
        send('\x1a')
        assert until(lambda: os.tcgetpgrp(terminal) == caller)
        previous = heartbeat.read_text()
        send('bg\n')
        assert until(lambda: heartbeat.read_text() not in ('', previous))
        send('fg; printf "NATIVE-RC=%s\\n" "$?"\n')
        assert until(lambda: os.tcgetpgrp(terminal) == group)
        send('\x03')
        completed = until(lambda: b'NATIVE-RC=130\r\n' in output)
        log.write(f'Native Bash loop, trial {n}: interrupt completed={completed}\n')
        log.flush()
        if not completed:
            log.write(output.decode(errors='replace'))
            break
    finally:
        if group:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.kill(caller, signal.SIGKILL)
        os.close(terminal)
        os.waitpid(caller, 0)
log.close()
