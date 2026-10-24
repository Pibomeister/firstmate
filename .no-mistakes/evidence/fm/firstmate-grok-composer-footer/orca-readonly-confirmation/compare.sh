#!/usr/bin/env bash
set -eu
base=.orca-baseline-confirmation.sh
trap 'rm -f "$base"' EXIT
git show d3e208cc674c1b6486e0ee50827ddd9eb5f53781:bin/fm-composer-lib.sh > "$base"
classify() { ( . "$1"; fm_composer_classify_screen 'styled=0
cursor=0
identity=0
rows=20' "$(cat "$2")"; ); }
printf 'case | baseline | candidate | expected candidate\n'
value=$(classify ./bin/fm-composer-lib.sh '/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-round2/adapter.capture.txt')
previous=$(classify "./$base" '/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-round2/adapter.capture.txt')
printf '%s | %s | %s | %s\n' 'retained-real-orca-adapter' "$previous" "$value" 'empty'
[ "$value" = 'empty' ] || exit 1
value=$(classify ./bin/fm-composer-lib.sh '/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-round2/viewport.capture.txt')
previous=$(classify "./$base" '/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-round2/viewport.capture.txt')
printf '%s | %s | %s | %s\n' 'retained-real-viewport' "$previous" "$value" 'empty'
[ "$value" = 'empty' ] || exit 1
value=$(classify ./bin/fm-composer-lib.sh '/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-confirmation/adapter.capture.txt')
previous=$(classify "./$base" '/Users/eduardopicazo/.no-mistakes/evidence/01M5NKPNRRG36VA9QBW5RC1KWQ/orca-readonly-confirmation/adapter.capture.txt')
printf '%s | %s | %s | %s\n' 'fresh-target-now-codex' "$previous" "$value" 'unknown'
[ "$value" = 'unknown' ] || exit 1
