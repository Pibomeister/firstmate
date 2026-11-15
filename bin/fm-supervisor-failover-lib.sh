# shellcheck shell=bash
# fm-supervisor-failover-lib.sh - supervisor successor runtimes and the quota
# preflight shared by bin/fm-handoff-launch.sh and bin/fm-supervisor-failover.sh.
# Callers source bin/fm-timeout-lib.sh (fm_run_timed) and bin/fm-quota-axi-lib.sh.
#
# A supervisor successor runs on claude, codex, or agy.
# Muse is a verified primary but an unverified secondmate, and every other
# adapter is crewmate-only, so neither is a failover target.
#
# The preflight reads quota-axi for the successor's provider and judges the
# rows that bound its model with FM_QUOTA_ROW_JQ:
#   verdict=exhausted  an applicable runway reads exhausted_now, or a known
#                      scope has 0% left. A successor is never launched here.
#   verdict=ok         every known applicable scope has headroom; the line
#                      names the tightest scope, its percent left, and runway.
#   verdict=unknown    quota-axi is missing, gave no valid snapshot, or has no
#                      known applicable scope; the line names why.
# A Claude read with an explicit account root runs quota-axi --profile-only
# against that root alone, exactly as bin/fm-claude-account-quota.sh does, so
# one account's reading never answers for another.
# Without a root it measures the account this process selects.
# Every field value is a safe token, so the line can ride logs and records.
# Data only: nothing here signs in, refreshes a login, or edits a pin.

FM_FAILOVER_QUOTA_SECONDS=${FM_FAILOVER_QUOTA_SECONDS:-45}

# fm_failover_runtime_supported <harness> <primary|secondmate>
# Prints the refusal and returns 1 for a runtime that cannot take over.
fm_failover_runtime_supported() {
  case "$1" in
    claude|codex|agy) return 0 ;;
    muse)
      [ "$2" = secondmate ] && { printf '%s\n' 'muse is unverified as a secondmate and refused'; return 1; }
      printf '%s\n' 'muse has no verified successor launch'
      return 1
      ;;
    *) printf '%s\n' "$1 is not a verified supervisor runtime for failover"; return 1 ;;
  esac
}

# fm_failover_log <fields> - append one line to state/supervisor-failover.log:
#   SUPERVISOR v1 ts=<epoch> event=<event> <key=token>...
# Events: successor_preflight, successor_vetoed, and successor_ready from the
# launcher; failover_choice, failover_none, and failover_result from
# bin/fm-supervisor-failover.sh. Callers set STATE.
fm_failover_log() {
  printf 'SUPERVISOR v1 ts=%s %s\n' "$(date +%s)" "$1" >> "$STATE/supervisor-failover.log"
}

# fm_failover_token <text> - one safe log token.
fm_failover_token() {
  local t=${1:-none}
  t=${t//[^A-Za-z0-9_.:\/-]/_}
  printf '%s\n' "${t:-none}"
}

# fm_failover_quota_read <harness> <out-file> [<claude-root>]
# Writes a validated quota-axi JSON snapshot. On failure prints why, returns 1.
fm_failover_quota_read() {
  local harness=$1 out=$2 root=${3:-} provider
  provider=$(fm_quota_single_provider_for_harness "$harness") || { printf '%s\n' "no_quota_provider_for_$harness"; return 1; }
  command -v quota-axi >/dev/null 2>&1 || { printf '%s\n' quota-axi_not_installed; return 1; }
  if [ "$harness" = claude ] && [ -n "$root" ]; then
    fm_run_timed "$FM_FAILOVER_QUOTA_SECONDS" env -u QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR="$root" \
      quota-axi --provider claude --profile-only --json > "$out" 2>/dev/null </dev/null || true
  else
    fm_run_timed "$FM_FAILOVER_QUOTA_SECONDS" quota-axi --provider "$provider" --json > "$out" 2>/dev/null </dev/null || true
  fi
  # quota-axi exits nonzero when it cannot measure a provider yet still prints
  # a valid snapshot naming that state, so only the snapshot is judged.
  fm_quota_json_valid < "$out" || { printf '%s\n' "no_valid_${provider}_snapshot"; return 1; }
}

# fm_failover_quota_verdict <snapshot-file> <harness> <model>
fm_failover_quota_verdict() {
  local provider
  provider=$(fm_quota_single_provider_for_harness "$2") || { printf '%s\n' "verdict=unknown why=no_quota_provider_for_$2"; return 0; }
  jq -r --arg provider "$provider" --arg harness "$2" --arg model "${3:-default}" "$FM_QUOTA_ROW_JQ"'
    def tok: tostring | gsub("[^A-Za-z0-9_.:/-]"; "_");
    quota_lane($harness; $model) as $lane |
    quota_row(.; $provider; $lane) as $p |
    if $p == null then "verdict=unknown why=no_\($provider)_quota_row"
    else
      quota_applicable($p; $model) as $a |
      [$a[] | select(.status == "known")] as $k |
      ([$a[] | select((.runway.status // "") == "exhausted_now")] | first) as $x |
      ([$k[] | select(.effectivePercentRemaining == 0)] | first) as $z |
      if $x != null then "verdict=exhausted scope=\($x.scope | tok) runway=exhausted_now"
      elif $z != null then "verdict=exhausted scope=\($z.scope | tok) remaining=0"
      elif ($k | length) == 0 then "verdict=unknown why=no_known_\($provider)_scope"
      else ($k | min_by(.effectivePercentRemaining)) as $m |
        "verdict=ok scope=\($m.scope | tok) remaining=\($m.effectivePercentRemaining | tok) runway=\(($m.runway.status // "unknown") | tok)"
      end
    end' "$1" 2>/dev/null || printf '%s\n' "verdict=unknown why=unreadable_${provider}_snapshot"
}

# fm_failover_quota_check <harness> <model> [<claude-root>]
# Prints one verdict line. Returns 0 for ok, 1 for exhausted, 2 for unknown.
fm_failover_quota_check() {
  local harness=$1 model=${2:-default} root=${3:-} snap why line
  snap=$(mktemp "${TMPDIR:-/tmp}/fm-failover-quota.XXXXXX") || { printf '%s\n' 'verdict=unknown why=no_scratch_file'; return 2; }
  if why=$(fm_failover_quota_read "$harness" "$snap" "$root"); then
    line=$(fm_failover_quota_verdict "$snap" "$harness" "$model")
  else
    line="verdict=unknown why=$why"
  fi
  rm -f "$snap"
  printf '%s\n' "$line"
  case "$line" in
    verdict=ok*) return 0 ;;
    verdict=exhausted*) return 1 ;;
    *) return 2 ;;
  esac
}

# fm_failover_agy_trusted <dir>
# True when agy's own store trusts the logical cwd of <dir> (pwd -L) and, when
# it differs, the exact <dir> a tmux -c launch passes. agy compares the pane's
# logical working directory; a physical-only entry still parks on the
# folder-trust dialog, and no launch flag suppresses it, so a successor must
# not start there unattended.
fm_failover_agy_trusted() {
  local dir=$1 logical store="${HOME:-}/.gemini/antigravity-cli/settings.json"
  [ -n "${HOME:-}" ] && [ -f "$store" ] || return 1
  logical=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -L) || return 1
  [ -n "$logical" ] || return 1
  jq -e --arg logical "$logical" --arg exact "$dir" \
    '(.trustedWorkspaces | type) == "array" and ((.trustedWorkspaces | index($logical)) != null) and ($exact == $logical or ((.trustedWorkspaces | index($exact)) != null))' \
    "$store" >/dev/null 2>&1
}
