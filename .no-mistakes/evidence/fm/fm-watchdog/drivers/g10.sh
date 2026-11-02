. /tmp/wdt/lib.sh
cd $REPO; S=$(cat /tmp/wdt/herdrs); R() { bin/fm-herdr-lab.sh run "$S" "$@"; }; export HERDR_SESSION=$S
hdr "Herdr lab session $S: real herdr panes, real Claude TUI, FM backend=herdr"
newp() { P=$(R workspace create --label wd$RANDOM --cwd /tmp | jq -r .result.root_pane.pane_id); sleep 2; echo "pane=$P"; }
mkherdr() { N=$((N+1)); H=$(mktemp -d "$LAB/homes/hrd.XXXX"); H=$(cd -P "$H" && pwd -P); $REPO/bin/fm-lab-home.sh create "$H" >/dev/null; SID=$(printf '%08d-0000-4000-8000-%012d' "$N" "$$"); mkdir -p "$H/state" "$H/config" "$H/data" "$H/claude/projects/p" "$H/work" "$H/cc"
  ( sleep 100000 >/dev/null 2>&1 & echo $! > "$H/lockpid" ); LOCKPID=$(cat "$H/lockpid"); echo "$LOCKPID" > "$H/state/.lock"; echo "$SID" > "$H/state/.lock-session"
  jq -n --arg t "$S:$P" --arg s "$SID" --argjson e "$(date +%s)" '{schema:"fm-heartbeat.v1",generated_epoch:$e,primary:{terminal:{backend:"herdr",target:$t,present:true},session:{trusted_id:$s}}}' > "$H/state/heartbeat.json"
  printf 'mode=act\nclaude-config-dirs=%s\nkey-settle-secs=2\nmodels=\nnudge-secs=1\nkey-secs=1\nenter-secs=1\nowed-input-secs=5\nfrozen-secs=9000\n' "$H/claude" > "$H/config/watchdog"; }
hdr "H1 feedback survey on a herdr pane: key 0"
newp; mkherdr; cat > "$H/a.sh" <<SH
clear; printf 'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n'; stty -echo -icanon min 1; while IFS= read -r -n1 k; do printf '%s' "\$k" >> "$H/typed.log"; clear; printf 'dismissed\n'; done
SH
R pane run "$P" "bash $H/a.sh" 2>&1 | cut -c1-120; sleep 3; transcript 100 60 "Working."; wd scan | sed -n 2,3p; wd once; led; echo "keys: [$(cat "$H/typed.log")]";
hdr "H2 real Claude TUI on herdr: unread nudge typed through the record-backed doorbell"
newp; mkherdr; key=sk-ant-fm-watchdog-live-guard-not-a-real-key; jq -n --arg k "${key: -20}" '{hasCompletedOnboarding:true,customApiKeyResponses:{approved:[$k],rejected:[]}}' > "$H/cc/.claude.json"
R pane run "$P" "cd $H/work && env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CONFIG_DIR=$H/cc ANTHROPIC_API_KEY=$key ANTHROPIC_BASE_URL=http://127.0.0.1:9 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude" 2>&1 | cut -c1-120
for i in $(seq 1 15); do sleep 2; v=$(R pane read "$P" --source visible 2>/dev/null); printf '%s' "$v" | grep -q 'trust this folder' && { R pane send-keys "$P" Down >/dev/null; sleep 1; R pane send-keys "$P" Enter >/dev/null; sleep 3; }; [ "$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$2"' _ "$REPO" "$P" 2>/dev/null)" = empty ] && break; done
transcript 100 60 "Working."; owe 1000; wd scan | sed -n 2,5p; sleep 3; wd scan | sed -n 3p; wd once; sleep 3; led | cut -c1-140; ls "$H/state/operational-inbox/" 2>/dev/null; R pane read "$P" --source visible 2>/dev/null | grep -v "^$" | tail -8 | cut -c1-140
