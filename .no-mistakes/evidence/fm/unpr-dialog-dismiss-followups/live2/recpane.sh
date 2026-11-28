#!/usr/bin/env bash
# Fake Claude idle screen. Logs every received byte (hex) to $1.
# Mode $2: sticky = survey stays after any key; dismiss = survey clears on `0`.
log=$1 mode=$2
survey() { clear; printf 'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n'; }
idle() { clear; printf 'some work\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n'; }
: > "$log"; survey
stty -echo -icanon min 1
while k=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'); do
  [ -n "$k" ] || k=0a
  printf '%s ' "$k" >> "$log"
  if [ "$mode" = dismiss ] && [ "$k" = 30 ]; then mode=done; idle; fi
done
