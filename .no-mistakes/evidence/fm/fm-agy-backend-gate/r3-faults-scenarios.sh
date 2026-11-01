echo 'SCENARIO: unsupported terminal backends refuse before allocation'
for backend in zellij cmux paseo; do
  brief "agy-$backend" no-launch
  if spawn "agy-$backend" "$backend"; then exit 1; fi
  test ! -e "$FM_HOME/state/agy-$backend.meta"
  test ! -d "$TREEHOUSE_ROOT"
done
# Inject one failed transport operation, keeping the real product and private
# tmux server running. No harness or product command is simulated.
cat > "$BASE/shim/tmux" <<SH
#!/usr/bin/env bash
case "\${FM_LIVE_FAULT:-}" in
  cd)
    if [ "\${1:-}" = send-keys ]; then
      for arg in "\$@"; do
        case "\$arg" in 'cd -- '*) echo 'INJECTED: cwd transport failure' >&2; exit 1 ;; esac
      done
    fi ;;
  literal|enter|signal)
    if [ "\${1:-}" = send-keys ]; then
      for arg in "\$@"; do
        case "\$arg" in '. '*'/launch.'*'.sh'*)
          touch '$BASE/launch-seen'
          if [ "\$FM_LIVE_FAULT" = literal ]; then echo 'INJECTED: launch-text transport failure' >&2; exit 1; fi ;;
        esac
      done
      if [ "\$FM_LIVE_FAULT" = enter ] && [ -f '$BASE/launch-seen' ] && [ "\${*: -1}" = Enter ]; then
        echo 'INJECTED: launch-submit transport failure' >&2; exit 1
      fi
    fi ;;
esac
exec '$REAL_TMUX' -f /dev/null -L '$SOCKET' "\$@"
SH
chmod +x "$BASE/shim/tmux"
echo 'SCENARIO: pre-publication cwd failure returns its durable lease and closes endpoint'
brief agy-unpublished no-agent
if FM_LIVE_FAULT=cd spawn agy-unpublished tmux; then exit 1; fi
test ! -e "$FM_HOME/state/agy-unpublished.meta"
! tmux list-windows -a -F '#{window_name}' | grep -Fxq fm-agy-unpublished
NEXT=$(cd "$PROJECT" && treehouse get --lease --lease-holder cleanup-probe --no-fetch)
test ! -e "$(dirname "$NEXT")/.fm-slot-owner"
echo "Returned unpublished slot is allocatable: $NEXT"
(cd "$PROJECT" && treehouse status --json)
(cd "$PROJECT" && treehouse return "$NEXT" --if-lease-holder cleanup-probe --force)
for mode in literal enter; do
  echo "SCENARIO: post-publication $mode delivery failure retains a teardown-resolvable record"
  [ ! -e "$BASE/launch-seen" ] || rm "$BASE/launch-seen"
  ID="agy-fail-$mode"
  brief "$ID" no-agent
  if FM_LIVE_FAULT="$mode" spawn "$ID" tmux; then exit 1; fi
  test -f "$FM_HOME/state/$ID.meta"
  WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta")
  test -d "$WT"
  echo "Kept $ID worktree=$WT"
  tmux send-keys -t "firstmate:fm-$ID" C-c
  retire "$ID"
done
echo 'SCENARIO: termination during readiness retains published task'
[ ! -e "$BASE/launch-seen" ] || rm "$BASE/launch-seen"
brief agy-signal initial
FM_LIVE_FAULT=signal FM_AGY_POLL_INTERVAL=10 "$ROOT/bin/fm-spawn.sh" agy-signal "$PROJECT" --scout --harness agy --model gemini-3.8-flash-low --effort low --backend tmux &
SPAWN_PID=$!
for ((i=0;i<600;i++)); do
  if [ -f "$BASE/launch-seen" ] && [ -f "$FM_HOME/state/agy-signal.meta" ]; then break; fi
  sleep 0.1
done
test -f "$BASE/launch-seen"
sleep 1
kill -TERM "$SPAWN_PID"
rc=0
wait "$SPAWN_PID" || rc=$?
test "$rc" -ne 0
test -f "$FM_HOME/state/agy-signal.meta"
echo "Signal exit=$rc; task record preserved"
retire agy-signal
echo 'PASS: post-publication delivery and signal failures keep recorded tasks; isolated fixtures removed with --force'
