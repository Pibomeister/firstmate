REAL_GIT=$(command -v git)
printf 'baseline\n' > "$PROJECT/preserved.txt"
git -C "$PROJECT" add preserved.txt
git -C "$PROJECT" commit -qm baseline
cat > "$BASE/shim/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = get ] && [ "\${FM_LIVE_DIRTY:-}" != '' ] && [[ " \$* " != *' --help '* ]]; then
  wt=\$('$REAL_TREEHOUSE' "\$@") || exit
  printf '%s\\n' "\$wt" > '$BASE/allocated'
  printf 'preserve this staged work\\n' > "\$wt/preserved.txt"
  '$REAL_GIT' -C "\$wt" add preserved.txt
  printf '%s\\n' "\$wt"
else
  exec '$REAL_TREEHOUSE' "\$@"
fi
EOF
cat > "$BASE/shim/git" <<EOF
#!/usr/bin/env bash
if [ "\${FM_LIVE_DIRTY:-}" = unreadable ] && [ "\${1:-}" = -C ] && [ -f '$BASE/allocated' ] && [ "\${2:-}" = "\$(cat '$BASE/allocated')" ]; then
  for arg in "\$@"; do
    [ "\$arg" != status ] || { echo 'INJECTED: checkout status unavailable' >&2; exit 128; }
  done
fi
exec '$REAL_GIT' "\$@"
EOF
chmod +x "$BASE/shim/treehouse" "$BASE/shim/git"
for mode in dirty unreadable; do
  echo "SCENARIO: unpublished AGY allocation preserves $mode work and custody"
  ID="agy-preserve-$mode"
  brief "$ID" never-launch
  rc=0
  FM_LIVE_DIRTY="$mode" spawn "$ID" tmux > "$BASE/refusal-$mode" 2>&1 || rc=$?
  cat "$BASE/refusal-$mode"
  test "$rc" -ne 0
  WT=$(cat "$BASE/allocated")
  grep -Fq "stays leased to $ID" "$BASE/refusal-$mode"
  test "$("$REAL_GIT" -C "$WT" show :preserved.txt)" = 'preserve this staged work'
  test "$(cat "$WT/preserved.txt")" = 'preserve this staged work'
  test ! -e "$FM_HOME/state/$ID.meta"
  ! tmux list-windows -a -F '#{window_name}' | grep -Fxq "fm-$ID"
  (cd "$PROJECT" && "$REAL_TREEHOUSE" status --json) > "$BASE/status.json"
  jq -e --arg wt "$WT" --arg id "$ID" '.[] | select(.path == $wt and .lease_holder == $id and .status == "leased")' "$BASE/status.json"
  SECOND=$(cd "$PROJECT" && "$REAL_TREEHOUSE" get --lease --lease-holder adversary --no-fetch)
  test "$SECOND" != "$WT"
  echo "Staged bytes retained in $WT; adversarial dispatch obtained $SECOND"
  (cd "$PROJECT" && "$REAL_TREEHOUSE" return "$SECOND" --if-lease-holder adversary --force)
  (cd "$PROJECT" && "$REAL_TREEHOUSE" return "$WT" --if-lease-holder "$ID" --force)
  echo "PASS: $mode allocation preserved until explicit conditional return"
done
