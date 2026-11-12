import os, sys, termios, tty, time
mode, log = sys.argv[1], sys.argv[2]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd); tty.setraw(fd)
def w(s): sys.stdout.write(s.replace("\n", "\r\n")); sys.stdout.flush()
SURVEY = """> fix the flaky test
● Done. The test now passes.

● How is Claude doing this session? (optional)
  1: Bad    2: Fine   3: Good   0: Dismiss

╭──────────────────────────────────────────╮
│ >                                        │
╰──────────────────────────────────────────╯
  ? for shortcuts
"""
MODAL = """Submit feedback / bug report
Describe the issue below:

Press Enter to continue · Esc to cancel
"""
NORMAL = """● The survey options were 1: Bad 2: Fine 3: Good 0: Dismiss earlier.
● How is Claude doing this session?
  1: Bad    2: Fine   3: Good   0: Dismiss
● Continuing work on the task now.
● Running tests...
"""
STALE = SURVEY + """> next task please
● Working on it.

╭──────────────────────────────────────────╮
│ >                                        │
╰──────────────────────────────────────────╯
"""
screen = {"survey": SURVEY, "modal": MODAL, "sticky": SURVEY, "normal": NORMAL, "stale": STALE}[mode]
w("\033[2J\033[H" + screen)
with open(log, "ab") as L:
    while True:
        b = os.read(fd, 64)
        if not b: break
        L.write(b"KEY:" + b.hex().encode() + b"\n"); L.flush()
        if mode == "sticky": continue
        if (mode == "survey" and b == b"0") or (mode == "modal" and b == b"\x1b"):
            w("\033[2J\033[H╭──────────────────────────────────────────╮\n│ >                                        │\n╰──────────────────────────────────────────╯\n  ? for shortcuts\n")
