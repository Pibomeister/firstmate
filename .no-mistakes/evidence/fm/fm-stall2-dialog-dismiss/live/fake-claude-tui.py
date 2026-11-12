#!/usr/bin/env python3
"""Fake Claude-like TUI for live watcher validation. Renders a scenario screen,
logs every byte it receives (hex) to KEYLOG, and reacts like the real dialog."""
import os, sys, tty, termios, time, select
mode, keylog = sys.argv[1], sys.argv[2]
def W(s): sys.stdout.write(s.replace("\n", "\r\n"))
BOX = "╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts\n"
def flush(): sys.stdout.flush()
def survey(footer=True):
    W("● Done. I updated the parser and ran the tests.\n")
    W("● How is Claude doing this session? (optional)\n")
    W("  1: Bad    2: Fine   3: Good   0: Dismiss\n" if footer else "  1: Bad    2: Fine   3: Good\n")
    W(BOX); flush()
def modal():
    W("● Done.\n\nSubmit feedback / bug report\nDescribe the issue below:\n\nPress Enter to continue · Esc to cancel\n"); flush()
def clean_inplace():
    # erase like real Claude: clear screen without pushing to history (cursor home + ED0)
    W("\033[H\033[J● Done. I updated the parser and ran the tests.\n" + BOX); flush()
def clean_fullclear():
    # full clear (ED2) pushes the closed dialog into tmux scrollback, then redraw
    W("\033[2J\033[H● Done. I updated the parser and ran the tests.\n" + BOX); flush()
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    if mode in ("survey", "fullclear"): survey()
    elif mode == "nearmiss": survey(footer=False)
    elif mode == "modal": modal()
    W("\r"); flush()
    while True:
        r, _, _ = select.select([fd], [], [], 1.0)
        if not r: continue
        b = os.read(fd, 64)
        with open(keylog, "a") as f: f.write(b.hex() + "\n")
        if mode == "survey" and b == b"0": clean_inplace()
        elif mode == "fullclear" and b == b"0": clean_fullclear()
        elif mode == "modal" and b == b"\x1b": clean_inplace()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
