echo 'SCENARIO: live guard stops its isolated tmux server when report wait fails'
cat > "$BASE/shim/grep" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -Fq ] && [ "${2:-}" = BRIEF_RECEIVED ]; then
  echo 'INJECTED: report not yet visible' >&2
  exit 1
fi
exec /usr/bin/grep "$@"
EOF
cat > "$BASE/shim/sleep" <<'EOF'
#!/bin/bash
[ "${1:-}" != 0.5 ] || exit 0
exec /bin/sleep "$@"
EOF
cat > "$BASE/shim/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then
  printf '%s\\n' "\$2 \${3:-}" >> '$BASE/guard-tmux.log'
fi
exec '$REAL_TMUX' "\$@"
EOF
chmod +x "$BASE/shim/grep" "$BASE/shim/sleep" "$BASE/shim/tmux"
unset TMUX TMUX_PANE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
rc=0
FM_AGY_SPAWN_LIVE=1 bash tests/fm-agy-spawn-live-e2e.test.sh > "$BASE/guard-output" 2>&1 || rc=$?
cat "$BASE/guard-output"
test "$rc" -ne 0
grep -Fq 'brief report did not appear' "$BASE/guard-output"
GUARD_SOCKET=$(awk '/kill-server/ {print $1}' "$BASE/guard-tmux.log" | tail -1)
test -n "$GUARD_SOCKET"
if "$REAL_TMUX" -L "$GUARD_SOCKET" list-sessions; then echo 'FAIL: guard server survived'; exit 1; fi
cat "$BASE/guard-tmux.log"
echo "PASS: report-wait failure exited $rc and stopped isolated server $GUARD_SOCKET"
