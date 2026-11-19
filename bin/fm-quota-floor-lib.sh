# shellcheck shell=bash
# fm-quota-floor-lib.sh - the launch quota floor.
#
# A Claude or Codex worker is never launched on an account whose weekly or
# 5-hour window has less than FM_QUOTA_FLOOR_PCT (15) percent left.
# bin/fm-spawn.sh applies the floor to every fresh spawn, relaunch, and
# secondmate launch before any endpoint, worktree, or record exists, and
# bin/fm-control.sh relaunch applies it before the running agent stops.
# This file is the single owner of the rule. docs/configuration.md "Launch
# quota floor" is the operator reference.
#
# What is read: one bounded quota-axi --json read of the account the launch
# would spend.
#   claude, pinned or listed root  CLAUDE_CONFIG_DIR=<root> --profile-only
#   claude, `ordinary`             CLAUDE_CONFIG_DIR unset (the vendor default)
#   claude, no pin and no list     the launching process's own account
#   codex                          the codex-home lane
# Other runners have no account Firstmate selects and are not read.
# QUOTA_AXI_SNAPSHOT, QUOTA_AXI_CLAUDE_PROFILES, and QUOTA_AXI_CLAUDE_SWAP are
# removed so a fixture or a multi-lane opt-in cannot answer for that account.
#
# Verdict: a window counts when its kind is weekly or session (the 5-hour
# window) and its percentRemaining is a number. The launch is refused when any
# counted window is under the floor. Exactly the floor passes. A read that
# fails, prints no snapshot, or has no counted window is unknown quota, which
# AGENTS.md section 4 keeps eligible: the launch proceeds with a notice on
# stderr. A missing quota-axi proceeds silently.
#
# Codex credits: once a Codex plan's windows run out, Codex keeps working on
# paid credits. Refusing under the floor keeps a new Codex launch from ever
# reaching them.
#
# Reroute: a refusal prints `quota-floor: refused ...` on stderr, then one or
# more `reroute:` lines.
#   - Under config/claude-accounts: every other declared entry measured at or
#     above the floor, and every unmeasured one marked as such, as
#     `--account <entry>`. Pass it to a fresh spawn, or to
#     bin/fm-control.sh <id> relaunch --account <entry>.
#   - A secondmate: bin/fm-supervisor-failover.sh secondmate <id>.
#   - Otherwise: another runtime or account.
# A Claude task with Claude-specific tooling cannot move off Claude
# (bin/fm-control.sh relaunch refuses that harness change), but another
# declared Claude account is not a harness change, so --account is its
# reroute. With no declared account at or above the floor, the work stays
# queued until a window resets.
#
# Test seam: FM_QUOTA_FLOOR_BIN replaces quota-axi under FM_TEST_SEAM=1.
# Requires bin/fm-timeout-lib.sh, and bin/fm-worker-account-lib.sh for the
# reroute list.

FM_QUOTA_FLOOR_PCT=15
FM_QUOTA_FLOOR_READ_SECONDS=20

fm_quota_floor_bin() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_QUOTA_FLOOR_BIN:-}" ]; then
    printf '%s\n' "$FM_QUOTA_FLOOR_BIN"
  else
    printf '%s\n' quota-axi
  fi
}

# fm_quota_floor_read <harness> <declared-account> <account-root>
# Prints whatever the read printed, which may be empty or not JSON. quota-axi
# exits nonzero when it cannot measure yet still prints a snapshot naming why,
# so its status is not the verdict. Returns 2 when quota-axi is not installed
# and 3 for a runner this floor does not read.
fm_quota_floor_read() {
  local harness=$1 declared=$2 root=$3 bin
  local -a clean=(env -u QUOTA_AXI_SNAPSHOT -u QUOTA_AXI_CLAUDE_PROFILES -u QUOTA_AXI_CLAUDE_SWAP)
  bin=$(fm_quota_floor_bin)
  command -v "$bin" >/dev/null 2>&1 || return 2
  case "$harness" in
  claude)
    if [ -n "$root" ]; then
      fm_run_timed "$FM_QUOTA_FLOOR_READ_SECONDS" "${clean[@]}" CLAUDE_CONFIG_DIR="$root" \
        "$bin" --provider claude --profile-only --json
    elif [ -n "$declared" ]; then
      fm_run_timed "$FM_QUOTA_FLOOR_READ_SECONDS" "${clean[@]}" -u CLAUDE_CONFIG_DIR \
        "$bin" --provider claude --json --no-credential-refresh --max-age 5m
    else
      fm_run_timed "$FM_QUOTA_FLOOR_READ_SECONDS" "${clean[@]}" \
        "$bin" --provider claude --json --no-credential-refresh --max-age 5m
    fi
    ;;
  codex)
    fm_run_timed "$FM_QUOTA_FLOOR_READ_SECONDS" "${clean[@]}" \
      "$bin" --provider codex --json --no-credential-refresh --max-age 5m
    ;;
  *) return 3 ;;
  esac </dev/null 2>/dev/null
  return 0
}

# fm_quota_floor_judge <harness> <snapshot-text>
# Prints `below <window> <percent>`, `ok <window> <percent>` (the lowest
# counted window), or `unknown <reason>`.
fm_quota_floor_judge() {
  local verdict
  verdict=$(printf '%s\n' "$2" | jq -r --arg h "$1" --argjson floor "$FM_QUOTA_FLOOR_PCT" '
    [(.providers // [])[]? | select(.provider == $h)] as $rows |
    (if $h == "codex"
     then ([$rows[] | select(.accountKey == "codex-home")] | first) // ([$rows[] | select(.accountKey == "default")] | first) // ($rows | first)
     else $rows | first end) as $row |
    if $row == null then "unknown no \($h) quota row"
    else
      [($row.windows // [])[] | select(.kind == "weekly" or .kind == "session")
        | select((.percentRemaining | type) == "number")] as $ws |
      if ($ws | length) == 0 then "unknown no weekly or 5-hour window"
      else ($ws | min_by(.percentRemaining)) as $w |
        (if $w.percentRemaining < $floor then "below" else "ok" end) + " \($w.id) \($w.percentRemaining)"
      end
    end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict="unknown quota-axi printed no snapshot"
  printf '%s\n' "$verdict"
}

# fm_quota_floor_measure <harness> <declared-account> <account-root>
# Prints the verdict for that account, or nothing when quota-axi is missing.
fm_quota_floor_measure() {
  local snap rc=0
  snap=$(fm_quota_floor_read "$1" "$2" "$3") || rc=$?
  [ "$rc" -eq 0 ] || return 0
  fm_quota_floor_judge "$1" "$snap"
}

# fm_quota_floor_reroute <harness> <declared-account> <config-dir> <kind> <id>
fm_quota_floor_reroute() {
  local harness=$1 declared=$2 config=$3 kind=$4 id=$5 listed entry root verdict found=0
  if [ "$kind" = secondmate ]; then
    printf 'reroute: bin/fm-supervisor-failover.sh secondmate %s (run with FM_HOME set to its owning home)\n' "$id"
    return 0
  fi
  listed=
  [ "$harness" != claude ] || listed=$(fm_worker_account_list claude "$config" 2>/dev/null) || listed=
  if [ -n "$listed" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] && [ "$entry" != "$declared" ] || continue
      root=$entry
      [ "$entry" != ordinary ] || root=
      verdict=$(fm_quota_floor_measure claude "$entry" "$root")
      case "$verdict" in
      ok\ *)
        printf 'reroute: --account %s (lowest weekly or 5-hour window %s%%)\n' "$entry" "${verdict##* }"
        found=1
        ;;
      unknown\ *)
        printf 'reroute: --account %s (quota not measured)\n' "$entry"
        found=1
        ;;
      esac
    done <<< "$listed"
    [ "$found" -eq 1 ] && return 0
    printf 'reroute: no other declared Claude account is at or above %s%%; keep the work queued until a window resets, or choose another runtime\n' "$FM_QUOTA_FLOOR_PCT"
    return 0
  fi
  printf 'reroute: choose another runtime or account with at least %s%% left (bin/fm-quota-reroute.sh suggest names one), or keep the work queued until a window resets\n' "$FM_QUOTA_FLOOR_PCT"
}

# fm_quota_floor_check <harness> <declared-account> <account-root> <config-dir> <kind> <id>
# Returns 0 when the launch may proceed and 1 when the floor refuses it.
fm_quota_floor_check() {
  local harness=$1 declared=$2 root=$3 config=$4 kind=$5 id=$6 verdict label pct
  case "$harness" in claude | codex) ;; *) return 0 ;; esac
  verdict=$(fm_quota_floor_measure "$harness" "$declared" "$root")
  [ -n "$verdict" ] || return 0
  label=${declared:-the launching account}
  case "$verdict" in
  below\ *)
    pct=${verdict##* }
    verdict=${verdict#below }
    {
      printf 'quota-floor: refused %s account %s: %s at %s%% (under %s%%); not launching %s on it\n' \
        "$harness" "$label" "${verdict% *}" "$pct" "$FM_QUOTA_FLOOR_PCT" "$id"
      [ "$harness" != codex ] || printf 'quota-floor: Firstmate never spends Codex credits, which a Codex plan falls back to once its windows run out\n'
      fm_quota_floor_reroute "$harness" "$declared" "$config" "$kind" "$id"
    } >&2
    return 1
    ;;
  unknown\ *)
    printf 'notice: quota floor: could not measure %s quota for account %s (%s); launching %s anyway\n' \
      "$harness" "$label" "${verdict#unknown }" "$id" >&2
    ;;
  esac
  return 0
}
