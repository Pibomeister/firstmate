#!/usr/bin/env bash
# Ink-style: static line printed once, dynamic region erased line-by-line (ESC[1A ESC[2K), never a full clear
kind=$1 log=$2
dyn=0
draw() { local out; out=$(cat); local n; n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  local i; for ((i=0;i<dyn;i++)); do printf '\033[1A\033[2K'; done; printf '\r%s\n' "$out"; dyn=$n; }
stty -icanon -echo -isig -ixon min 1
printf '● Done. I updated the parser and ran the tests.\n\n'
dlg() { printf '● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n'; }
box() { printf '╭──────────────────────────────╮\n│ > %s                          │\n╰──────────────────────────────╯\n  ? for shortcuts' "$1"; }
draw < <(dlg; box "")
typed=
while IFS= read -r -n1 -d '' c; do
  printf '%s\n' "$(printf '%s' "$c" | od -An -tx1 | tr -d ' ')" >> "$log"
  if [ "$kind" = survey ] && [ "$c" = 0 ]; then kind=closed; draw < <(box ""); continue; fi
  typed="$typed$c"; draw < <(box "$typed")
done
