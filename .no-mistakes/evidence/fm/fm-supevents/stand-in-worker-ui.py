import sys, os, tty, termios
# Stand-in worker UI: an empty claude-2.x-shaped input box; keystrokes edit it,
# Enter "submits" (logs the line to submitted.log and clears the box).
mode = sys.argv[1] if len(sys.argv) > 1 else "empty"
log = os.path.join(os.path.dirname(os.path.abspath(__file__)), "submitted-%s.log" % (sys.argv[2] if len(sys.argv)>2 else mode))
NB = " "
rule = "─" * 60
draft = ""
if mode == "draft": draft = "half-typed note from the operator"
tall = [("pasted line %02d of a tall draft" % i) for i in range(1, 35)] if mode == "tall" else []
def W(x): sys.stdout.write(x.replace("\n","\r\n"))
def draw():
    sys.stdout.write("\x1b[2J\x1b[H")
    W("transcript line\n" + rule + "\n")
    if tall:
        W("❯ " + tall[0] + "\n" + "\n".join("  " + l for l in tall[1:]) + "\n")
    else:
        W("❯" + (" " + draft if draft else NB) + "\n")
    W(rule + "\n  bypass permissions\n")
    sys.stdout.write("\x1b[3;%dH" % (4 + len(draft) if not tall else 3)); sys.stdout.flush()
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
try:
    draw()
    while True:
        c = os.read(fd, 1).decode("utf-8", "ignore")
        if c in ("\r", "\n"):
            with open(log, "a") as f: f.write(("\n".join(tall) + "\n" if tall else "") + draft + "\n")
            draft = ""; tall = []
        elif c == "\x03": break
        elif c in ("\x7f",): draft = draft[:-1]
        else: draft += c
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
