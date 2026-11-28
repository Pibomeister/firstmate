#!/usr/bin/env bash
# Pane program: enables bracketed paste (as Claude Code does) and logs every received byte in hex to $1.
log=$1; : > "$log"; printf '\033[?2004h'; printf 'recorder ready\n'
stty raw -echo
while k=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'); do printf '%s ' "${k:-0a}" >> "$log"; done
