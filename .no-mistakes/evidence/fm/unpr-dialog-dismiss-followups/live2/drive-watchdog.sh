#!/usr/bin/env bash
# Real watchdog code (sourced under its test seam) on a throwaway home.
# The Orca send boundary is replaced by a recorder, so no Orca instance is
# contacted; the oracle is that the recorder stays empty.
set -u
WT=$1
H=$(mktemp -d /tmp/fmlabwd.XXXX); mkdir -p "$H/state" "$H/config" "$H/data"
printf 'mode=act\nkey-settle-secs=0\nmodels=\nquota-guard=off\n' > "$H/config/watchdog"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s/control.log\n' "$H" > "$H/control.sh"; chmod +x "$H/control.sh"
SCREEN_PP="$WT/tests/fixtures/permission-prompt/claude-2.1.325-bash-prompt.txt"
[ -f "$SCREEN_PP" ] || SCREEN_PP=$(ls "$WT"/tests/fixtures/*/claude-2.1.325-bash-prompt.txt 2>/dev/null | head -1)
MODAL=$'Submit feedback / bug report\nDescribe the issue below:\n\nPress Enter to continue · Esc to cancel'
FM_TEST_SEAM=1 FM_WD_TEST_CONTROL="$H/control.sh" FM_WD_NOW=1795800000 FM_HOME="$H" bash -c '
  . "$1/bin/fm-watchdog.sh" || exit 9
  H=$FM_HOME; sent=$H/orca-sent.log; : > "$sent"
  O_HOME=$H O_TAG=$(wd_tag "$H") O_KEY=$(wd_state_key "$H") O_BACKEND=orca O_TARGET=orca-oe O_REC_SUBJECT=worker:oe
  fm_backend_source() { return 0; }
  fm_backend_send_key() { printf "KEY:%s\n" "$3" >> "$sent"; }
  fm_backend_orca_send_literal() { printf "LITERAL\n" >> "$sent"; }
  screen=$(cat "$2")
  wd_capture() { printf "%s\n" "$screen"; }
  wd_observe_dialog() { fm_wd_pane_dialog "$screen" claude 2>/dev/null || true; }
  echo "### W1 tool-approval prompt, Claude worker on Orca"
  rc=0; wd_permission_prompt oe claude "$screen" "$(wd_observe_dialog)" || rc=$?
  echo "wd_permission_prompt rc=$rc"
  echo "bytes to Orca: [$(cat "$sent")]"
  echo "ledger decline rows: $(grep -c "permission-prompt	decline" "$LEDGER" 2>/dev/null || echo 0)"
  echo "status: $(cat "$H/state/oe.status" 2>/dev/null)"
  echo "declined checksums: [$(find "$H/state/watchdog" -name "*-oe.declined" 2>/dev/null)]"
  echo "### W2 Claude bug-report modal (needs Escape) on an Orca worker"
  : > "$sent"; WD_GAPS=$H/gaps.txt; : > "$WD_GAPS"
  O_DIALOG=feedback O_HARNESS=claude O_ID=oe O_PANE=$3 O_DIALOG_PANE=$3
  fm_control_capture_feedback_pane() { printf "%s\n" "$O_DIALOG_PANE"; }
  rc=0; wd_handle_dialog || rc=$?
  echo "wd_handle_dialog rc=$rc"
  echo "bytes to Orca: [$(cat "$sent")]"
  echo "gaps: $(cat "$WD_GAPS")"
  echo "dialog key ledger rows: $(awk -F"\t" "\$5==\"dialog\"" "$LEDGER" 2>/dev/null | wc -l | tr -d " ")"
  echo "markers: [$(find "$H/state" -name ".feedback-*" 2>/dev/null)]"
' _ "$WT" "$SCREEN_PP" "$MODAL"
rm -rf "$H"
