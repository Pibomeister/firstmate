#!/usr/bin/env bash
# Repro: single-cycle written-worktree deferral with the synthetic clock at
# real+2 (no lag) vs real-1 (watcher took 3s of real time before stamping
# .writing-since, as on a loaded runner). Usage: <worktree>
set -u
WT=$1
. "$WT/tests/fm-watch-triage-common.sh"
run() {  # <label> <now-offset>
  local dir state fakebin out window key pane_hash wt back
  dir=$(make_case "w$2"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/out"
  window="test:fm-writing"; wt="$dir/wt"; mkdir -p "$wt/src"
  printf 'idle building output' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/writing.meta"
  printf 'working: implementing\n' > "$state/writing.status"
  printf '%s' "$(seen_sig "$state/writing.status")" > "$state/.seen-writing_status"
  key=test_fm-writing; pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"; printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 )); echo "$back" > "$state/.stale-since-$key"; set_mtime "$back" "$state/.stale-since-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_ONCE=1 FM_WATCH_NOW="$(( $(date +%s) + $2 ))" "$WATCH" > "$out"
  echo "$1 (FM_WATCH_NOW=real$( [ "$2" -ge 0 ] && echo + )$2): rc=$? out='$(cat "$out")' writing-since content=$(cat "$state/.writing-since-$key") mtime=$(stat -f %m "$state/.writing-since-$key")"
}
run "old +2 lead, no lag" 2
run "old +2 lead, 3s cycle lag" -1
run "new +30 lead, 3s cycle lag" 27
run "new +30 lead, 20s cycle lag" 10
rm -rf "$TMP_ROOT"
