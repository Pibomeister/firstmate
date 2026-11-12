#!/usr/bin/env bash
# fake harness TUI: render a dialog, log every received byte, close on the dismiss key
kind=$1 log=$2 sticky=${3:-0}
render() {
  printf '\033[2J\033[H'
  printf '● Done. I updated the parser and ran the tests.\n\n'
  case "$kind" in
    survey) printf '● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n' ;;
    modal)  printf 'Submit feedback / bug report\n\n  Describe the issue below:\n  > \n\n  Enter to continue · Esc to cancel\n' ;;
    draft)  printf '● Bug report drafted: parser crashes on empty input\n  1 to review · 2 to send · 0 to dismiss\n' ;;
    quoted) printf '● The doc says the survey reads "How is Claude doing this session?"\n  1: Bad    2: Fine   3: Good   0: Dismiss\n  and I will now continue editing the file to fix the issue.\n' ;;
  esac
  printf '╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts\n'
}
closed() { printf '\033[2J\033[H● Done. I updated the parser and ran the tests.\n\n╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts\n'; }
stty -icanon -echo -isig -ixon min 1
render
while IFS= read -r -n1 -d '' c; do
  printf '%s\n' "$(printf '%s' "$c" | od -An -tx1 | tr -d ' ')" >> "$log"
  [ -z "$c" ] && echo "0d-or-nul" >> "$log"
  if [ "$sticky" = 1 ]; then continue; fi
  case "$kind:$c" in
    survey:0|draft:0|modal:$'\033') closed; kind=closed ;;
    *) render ;;
  esac
done
