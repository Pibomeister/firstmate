#!/usr/bin/env bash
set -eu
[ "$PWD" = /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M5NKPNRRG36VA9QBW5RC1KWQ ] || exit 2
evidence=/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-round2
baseline=.orca-composer-baseline.round2.sh
trap 'rm -f "$baseline"' EXIT
git show d3e208cc674c1b6486e0ee50827ddd9eb5f53781:bin/fm-composer-lib.sh > "$baseline"
shasum -a 256 "$baseline" > "$evidence/baseline.sha256"
classify() { ( . "$1"; fm_composer_classify_screen 'styled=0
cursor=0
identity=0
rows=20' "$2"; ); }
printf 'case | baseline | candidate | expected candidate\n'
for name in adapter viewport saved-both saved-send-now saved-queue saved-draft saved-hint-draft saved-extra-row saved-incomplete; do
  case "$name" in
    adapter|viewport) value=$(cat "$evidence/$name.capture.txt"); expected=empty ;;
    saved-*)
      value=$(cat tests/fixtures/grok-composer-footer.screen.txt)
      expected=empty
      case "$name" in
        saved-send-now) value=${value/'Ctrl+;:queue'/'Ctrl+q:queue'} ;;
        saved-queue) value=${value/'Enter:send now'/'Enter:send'} ;;
        saved-draft) value=${value/'│ ❯                '/'│ ❯ preserve draft '}; expected=pending ;;
        saved-hint-draft) value=${value/'│ ❯                '/'│ ❯ Enter:send now '}; expected=pending ;;
        saved-extra-row) value=$value$'\nWorking on request...'; expected=unknown ;;
        saved-incomplete) value=${value/╯/─}; expected=unknown ;;
      esac
      ;;
  esac
  old=$(classify "./$baseline" "$value")
  current=$(classify ./bin/fm-composer-lib.sh "$value")
  printf '%s | %s | %s | %s\n' "$name" "$old" "$current" "$expected"
  [ "$current" = "$expected" ] || exit 1
  case "$name" in adapter|viewport|saved-both|saved-send-now|saved-queue) [ "$old" = unknown ] || exit 1 ;; esac
done
