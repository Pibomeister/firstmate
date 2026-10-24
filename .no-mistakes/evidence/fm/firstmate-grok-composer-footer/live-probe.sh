#!/usr/bin/env bash
set -eu
LAB="$PWD/.grok-footer-lab"
EVIDENCE=/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ
label=$1
tmux() { TMUX_TMPDIR="$(cat "$LAB/socket-dir")" command tmux -L fm-lab "$@"; }
. bin/fm-tmux-lib.sh
pane=$(fm_tmux_composer_capture primary)
printf '%s\n' "$pane" > "$EVIDENCE/$label.ansi.txt"
tmux capture-pane -p -t primary > "$EVIDENCE/$label.screen.txt"
printf '%s\n' "[$label]" "tmux=$(fm_tmux_composer_state primary)"
for styled in 0 1; do
  for loc in en_US.UTF-8 C; do
    caps=$(printf 'styled=%s\ncursor=0\nidentity=0\nrows=40' "$styled")
    if [ "$styled" = 0 ]; then screen=$(cat "$EVIDENCE/$label.screen.txt"); else screen=$pane; fi
    printf 'cursorless styled=%s locale=%s: %s\n' "$styled" "$loc" "$(LC_ALL="$loc" fm_composer_classify_screen "$caps" "$screen")"
  done
done
