#!/usr/bin/env bash
# fm-idle-resume-repro.sh - before-and-after repro for the idle-primary stall
# (a Claude primary left idle with queued work after its Stop-hook listener
# parked on the watchdog's managed-hold watcher, after an idle compaction, or
# behind a dead captain-nudge pin).
#
# It copies <root> (default: the checkout holding this script) to a scratch
# tree, overlays THIS checkout's tests/ onto it, and runs one regression case
# per mechanism against <root>'s bin/. Run against an exported base revision
# every case prints FAIL and it exits 1; run against a fixed tree every case
# prints PASS and it exits 0. Nothing here touches a live pane or session:
# every case uses fixture homes, fake backends and scrubbed terminal variables.
#
# Usage: tests/fm-idle-resume-repro.sh [--root <firstmate-checkout>]
#   e.g. git archive <base> | tar -x -C /tmp/base && tests/fm-idle-resume-repro.sh --root /tmp/base
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_UNDER_TEST=$HERE
case "${1:-}" in
  --root) ROOT_UNDER_TEST=${2:?--root needs a checkout path} ;;
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) printf 'usage: %s [--root <firstmate-checkout>]\n' "$0" >&2; exit 2 ;;
esac
[ -d "$ROOT_UNDER_TEST/bin" ] || { printf 'error: %s has no bin/\n' "$ROOT_UNDER_TEST" >&2; exit 2; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-idle-resume-repro.XXXXXX") || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
TREE="$SCRATCH/tree"
mkdir -p "$TREE"
# Copy the code, never a live home's private state.
tar -C "$ROOT_UNDER_TEST" --exclude=./state --exclude=./data --exclude=./projects \
  --exclude=./config --exclude=./.git --exclude=./tests -cf - . | tar -C "$TREE" -xf -
cp -R "$HERE/tests" "$TREE/tests"
TIMEOUT=()
command -v timeout >/dev/null 2>&1 && TIMEOUT=(timeout 300)

# <case> <suite> <test-function> <what the base revision does instead>
CASES=(
  "stall-hook-rewakes|fm-claude-stop-autoarm.test.sh|test_idle_claude_with_queued_wake_under_managed_hold_rewakes|the Stop hook never returns while a live managed-hold watcher holds queued work"
  "arm-reports-managed-hold|fm-watch-arm.test.sh|test_attached_arm_reports_queued_wake_under_managed_hold|an arm attached to a managed-hold watcher follows it forever and never reports queued work"
  "claim-superseded|fm-claude-stop-autoarm.test.sh|test_parked_claim_past_hook_timeout_or_context_epoch_is_superseded|a parked arming claim with a fresh beacon defers every later Stop, past the hook timeout and after a compaction"
  "compact-starts-doorbell|fm-sessionstart-nudge.test.sh|test_run_compact_records_context_epoch_and_starts_one_doorbell|an idle auto compaction records no context epoch and starts no turn"
  "nudge-follows-live-handle|fm-captain-nudge.test.sh|test_herdr_dead_pin_follows_the_homes_live_captain_handle|a dead pinned nudge pane fails every pass (skip_read_failed) and never reaches the live primary"
)

# Write <suite> reduced to its definitions plus one test call, beside it so the
# suite still resolves its checkout root from its own location.
subset_suite() {  # <suite-path> <test-function> <out-path>
  local suite=$1 fn=$2 out=$3 cut
  if grep -q '^fm_test_run \\$' "$suite"; then
    cut=$(grep -n '^fm_test_run \\$' "$suite" | head -n 1 | cut -d: -f1)
    { head -n "$((cut - 1))" "$suite"; printf 'fm_test_run %s\n' "$fn"; } > "$out"
  else
    cut=$(grep -n '^test_[a-z0-9_]*\( .*\)\{0,1\}$' "$suite" | head -n 1 | cut -d: -f1)
    { head -n "$((cut - 1))" "$suite"; printf '%s\n' "$fn"; } > "$out"
  fi
  chmod +x "$out"
}

fails=0
for row in "${CASES[@]}"; do
  IFS='|' read -r name suite fn mechanism <<<"$row"
  sub="$TREE/tests/.repro-$name.test.sh"
  subset_suite "$TREE/tests/$suite" "$fn" "$sub"
  log="$SCRATCH/$name.log"
  if env -u TMUX -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_ENV -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u ORCA_TERMINAL_HANDLE -u CLAUDECODE \
    "${TIMEOUT[@]}" bash "$sub" > "$log" 2>&1 && grep -q '^ok - ' "$log" && ! grep -q '^not ok' "$log"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s: %s\n' "$name" "$mechanism"
    grep -m 1 '^not ok' "$log" | cut -c1-240 | sed 's/^/     /'
    fails=$((fails + 1))
  fi
done
printf 'root=%s cases=%s failed=%s\n' "$ROOT_UNDER_TEST" "${#CASES[@]}" "$fails"
[ "$fails" -eq 0 ]
