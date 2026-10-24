#!/usr/bin/env bash
set -eu
screen=$(cat tests/fixtures/grok-composer-footer.screen.txt)
classify() { ( . "$1"; fm_composer_classify_screen 'styled=0
cursor=0
identity=0
rows=4' "$2"; ); }
printf 'Saved-capture replay, not a live session. Baseline d3e208cc; candidate a761a455.\n'
printf 'Case | baseline | candidate | expected candidate\n'
for name in both send-now-only queue-only draft extra-row incomplete; do
  case "$name" in
    both) value=$screen; expected=empty ;;
    send-now-only) value=${screen/'Ctrl+;:queue'/'Ctrl+q:queue'}; expected=empty ;;
    queue-only) value=${screen/'Enter:send now'/'Enter:send'}; expected=empty ;;
    draft) value=${screen/'│ ❯                '/'│ ❯ preserve draft '}; expected=pending ;;
    extra-row) value=$screen$'\nWorking on request...'; expected=unknown ;;
    incomplete) value=${screen/╯/─}; expected=unknown ;;
  esac
  old=$(classify .grok-footer-lab/baseline-composer.sh "$value")
  current=$(classify bin/fm-composer-lib.sh "$value")
  printf '%s | %s | %s | %s\n' "$name" "$old" "$current" "$expected"
  [ "$current" = "$expected" ] || exit 1
done
