#!/usr/bin/env bash
# fm-captain-nudge.sh - no-AI host-local captain self-nudge.
#
# Usage:
#   fm-captain-nudge.sh once [--config <path>] [--dry-run]
#   fm-captain-nudge.sh run [--config <path>] [--dry-run]
#   fm-captain-nudge.sh guard [--config <path>]
#   fm-captain-nudge.sh decide [<observation.json]
#   fm-captain-nudge.sh test-nudge --captain <id> [--config <path>] [--pane <handle>]
#   fm-captain-nudge.sh install [--config <path>] [--dry-run]
#   fm-captain-nudge.sh uninstall [--config <path>] [--dry-run]
#   fm-captain-nudge.sh status [--config <path>]
#   fm-captain-nudge.sh --help
#
# A periodic, model-free typer that sends fixed prompts into a configured
# captain pane when that captain stalls with open work (a 15/40/60-minute
# ladder: wake, relaunch-or-replace wake, council row) or a merge-ready PR has
# waited too long. docs/captain-nudge.md owns behaviour, install, and hard
# limits.
# docs/captain-nudge-spec.md owns the JSONL object and NUDGE v1 beacon line.
# docs/configuration.md ("Captain self-nudge") owns the config file schema.
# This header owns commands, flags, files, and the send/guard mechanics.
#
# Hard limits, enforced here:
#   - never merge, deploy, spend, run git/gh mutations, kill or restart a
#     captain, or run `herdr server stop`;
#   - the only typed payloads are the fixed prompts from fm_nudge_prompt_text;
#   - a visible modal or a non-empty input line never receives a prompt;
#   - the outer guard may restart only this tool's own loop process, and only
#     after the pid file's command line still names fm-captain-nudge.
#
# Files, all under the config's state_dir (default ~/.local/state/firstmate/captain-nudge):
#   loop.heartbeat   epoch of the last run/once tick
#   loop.pid         pid of a live `run` loop
#   captains/<id>.json  last nudge epoch, fingerprint, consecutive_no_progress,
#                       escalated, stall_tier, and merge_ready (first-seen epoch
#                       and nudged flag per <run_id>@<head>)
# Each pass also runs fm-stall-ledger.sh observe for a captain's fm_home and
# reads fm-ready-pr-discovery.sh --json for it. An Orca captain with fm_home is
# the terminal fm-captain-locate.sh names as that home's lock owner, read at
# pass start and again before each send; without a held lock the pass records
# captain_unknown and types nothing.
# The JSONL log and beacon log paths are config keys (defaults under state_dir
# and, when set, the existing host beacon log).
#
# Config path: --config, else FM_NUDGE_CONFIG, else
# ~/.config/firstmate/captain-nudge.json.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_NUDGE_NOW, FM_NUDGE_SEND_LOG
# (send writes the payload instead of calling orca/herdr), FM_NUDGE_READY_PR_BIN
# (replaces fm-ready-pr-discovery.sh), FM_NUDGE_LOCATE_BIN (replaces
# fm-captain-locate.sh), FM_NUDGE_LAUNCHD_DIR,
# FM_NUDGE_SYSTEMD_DIR, FM_NUDGE_CRON_FILE, and a captain backend of `fixture`.
#
# Exit status: 0 on success, 2 on a usage error, 1 on any other failure.
set -u
export LC_ALL=C

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-captain-nudge-lib.sh
. "$SCRIPT_DIR/fm-captain-nudge-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-orca-cli-cache.sh
. "$SCRIPT_DIR/fm-orca-cli-cache.sh"

die() { printf 'fm-captain-nudge: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  awk '
    NR == 1 { next }
    /^# Usage:/ { show=1 }
    show && /^#/ { sub(/^# ?/, ""); print; next }
    show { exit }
  ' "$0"
}

NUDGE_CONFIG=${FM_NUDGE_CONFIG:-}
DRY_RUN=0
FORCE_CAPTAIN=
FORCE_PANE=

resolve_config_path() {
  local p=${NUDGE_CONFIG:-}
  if [ -z "$p" ]; then
    p="${HOME}/.config/firstmate/captain-nudge.json"
  fi
  fm_nudge_expand_path "$p"
}

load_config() {
  local path
  path=$(resolve_config_path)
  [ -f "$path" ] || die "config not found: $path (copy an example from docs/examples/captain-nudge/)" 2
  CONFIG_JSON=$(cat "$path") || die "cannot read $path"
  printf '%s' "$CONFIG_JSON" | jq -e . >/dev/null 2>&1 || die "config is not JSON: $path" 2
  CONFIG_PATH=$path
  CFG_HOST=$(fm_nudge_json_get "$CONFIG_JSON" '.host' 'unknown') || true
  CFG_INTERVAL=$(fm_nudge_json_get "$CONFIG_JSON" '.interval_secs' '300') || true
  CFG_GUARD_STALE=$(fm_nudge_json_get "$CONFIG_JSON" '.guard_stale_secs' '660') || true
  CFG_IDLE=$(fm_nudge_json_get "$CONFIG_JSON" '.idle_min' '15') || true
  CFG_COOL=$(fm_nudge_json_get "$CONFIG_JSON" '.cooldown_min' '30') || true
  CFG_MAX_NP=$(fm_nudge_json_get "$CONFIG_JSON" '.max_no_progress' '2') || true
  CFG_ESCALATE=$(fm_nudge_json_get "$CONFIG_JSON" '.escalate_min' '40') || true
  CFG_COUNCIL=$(fm_nudge_json_get "$CONFIG_JSON" '.council_min' '60') || true
  CFG_MERGE_READY=$(fm_nudge_json_get "$CONFIG_JSON" '.merge_ready_min' '15') || true
  CFG_LANE=$(fm_nudge_json_get "$CONFIG_JSON" '.lane_stall_min' '20') || true
  CFG_STATE=$(fm_nudge_expand_path "$(fm_nudge_json_get "$CONFIG_JSON" '.state_dir' "${HOME}/.local/state/firstmate/captain-nudge")")
  CFG_JSONL=$(fm_nudge_expand_path "$(fm_nudge_json_get "$CONFIG_JSON" '.jsonl_log' "$CFG_STATE/nudge.jsonl")")
  CFG_BEACON=$(fm_nudge_expand_path "$(fm_nudge_json_get "$CONFIG_JSON" '.beacon_log' "$CFG_STATE/nudge-beacon.log")")
  CFG_MODE=$(fm_nudge_json_get "$CONFIG_JSON" '.mode' 'act') || true
  case "$CFG_INTERVAL" in ''|*[!0-9]*) CFG_INTERVAL=300 ;; esac
  case "$CFG_GUARD_STALE" in ''|*[!0-9]*) CFG_GUARD_STALE=660 ;; esac
  case "$CFG_IDLE" in ''|*[!0-9]*) CFG_IDLE=15 ;; esac
  case "$CFG_COOL" in ''|*[!0-9]*) CFG_COOL=30 ;; esac
  case "$CFG_MAX_NP" in ''|*[!0-9]*) CFG_MAX_NP=2 ;; esac
  case "$CFG_ESCALATE" in ''|*[!0-9]*) CFG_ESCALATE=40 ;; esac
  case "$CFG_COUNCIL" in ''|*[!0-9]*) CFG_COUNCIL=60 ;; esac
  case "$CFG_MERGE_READY" in ''|*[!0-9]*) CFG_MERGE_READY=15 ;; esac
  case "$CFG_LANE" in ''|*[!0-9]*) CFG_LANE=20 ;; esac
  if [ "$DRY_RUN" = 1 ] || [ "$CFG_MODE" = dry-run ]; then
    DRY_RUN=1
  fi
  mkdir -p "$CFG_STATE/captains"
}

cfg_mode_is_act() { [ "$DRY_RUN" != 1 ]; }

captain_state_path() { printf '%s\n' "$CFG_STATE/captains/$1.json"; }

read_captain_state() {  # <id>
  local f
  f=$(captain_state_path "$1")
  if [ -f "$f" ]; then
    cat "$f"
  else
    printf '%s\n' '{"last_nudge_epoch":0,"fingerprint":"","consecutive_no_progress":0,"escalated":false,"stall_tier":0,"merge_ready":{}}'
  fi
}

# Merge <json> over the stored state, so the stall pass and the merge-ready
# pass each keep the other's keys.
write_captain_state() {  # <id> <json>
  local f tmp
  f=$(captain_state_path "$1")
  tmp=$f.tmp.$$
  read_captain_state "$1" | jq -c --argjson new "$2" '(if type == "object" then . else {} end) + $new' > "$tmp" \
    && mv "$tmp" "$f"
}

heartbeat_write() {
  mkdir -p "$CFG_STATE"
  printf '%s\n' "$(fm_nudge_now)" > "$CFG_STATE/loop.heartbeat"
}

# --- pane observation -------------------------------------------------------

# Load dialog/composer classifiers once per process.
ensure_classifiers() {
  [ "${NUDGE_CLASSIFIERS_READY:-}" = 1 ] && return 0
  # shellcheck source=bin/fm-watchdog-lib.sh
  . "$SCRIPT_DIR/fm-watchdog-lib.sh"
  # shellcheck source=bin/fm-composer-lib.sh
  . "$SCRIPT_DIR/fm-composer-lib.sh"
  NUDGE_CLASSIFIERS_READY=1
}

classify_screen() {  # <screen> -> dialog\\tcomposer  (dialog may be empty)
  local screen=$1 dialog='' verdict
  ensure_classifiers
  dialog=$(fm_nudge_modal_kind "$screen") || dialog=''
  if declare -F fm_composer_classify_screen >/dev/null 2>&1; then
    verdict=$(fm_composer_classify_screen 'styled=0 cursor=0 identity=0 rows=60' "$screen") || verdict=unknown
  else
    verdict=unknown
  fi
  printf '%s\t%s\n' "$dialog" "$(fm_nudge_composer_gate "$verdict")"
}

orca_list_json() {
  fm_run_timed 20 orca terminal list --json --limit 5000 2>/dev/null
}

orca_pick_terminal() {  # <captain-json> -> handle\\tlastOutputAt\\tdraft
  local cap=$1 handle title list
  handle=$(fm_nudge_json_get "$cap" '.handle // ""' '') || true
  title=$(fm_nudge_json_get "$cap" '.title // ""' '') || true
  list=$(orca_list_json) || { printf '\n'; return 1; }
  printf '%s' "$list" | jq -r --arg h "$handle" --arg t "$title" '
    def terms:
      (.result.terminals // .result.items // .terminals // .items // [])
      | if type=="array" then . else [] end;
    def row:
      [(.id // .handle // .terminal // ""), (.title // .name // ""), (.lastOutputAt // .last_output_at // .updatedAt // ""), (.draft // "")] | @tsv;
    (terms | if $h != "" then map(select((.id // .handle // .terminal) == $h)) else . end)
    | if $t != "" and $h == "" then map(select((.title // .name // "") | test($t))) else . end
    | .[0] | if . then row else empty end
  '
}

orca_read_screen() {  # <handle>
  local out
  out=$(fm_run_timed 20 orca terminal read --terminal "$1" --limit 80 --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '
    .result.terminal.tail // .result.tail // .result.text // .result.output // empty
    | if type=="array" then join("\n") else . end
  ' 2>/dev/null
}

orca_draft() {  # <handle>
  local out
  out=$(fm_run_timed 20 orca terminal read --terminal "$1" --limit 5 --json 2>/dev/null) || { printf '\n'; return 0; }
  printf '%s' "$out" | jq -r '(.result.terminal.draft // .result.draft // "") | tostring' 2>/dev/null
}

herdr_read_screen() {  # <pane> [session]
  local pane=$1 session=${2:-} args
  args=(pane read "$pane" --source visible)
  if [ -n "$session" ]; then
    args+=(--session "$session")
  fi
  fm_run_timed 20 herdr "${args[@]}" 2>/dev/null
}

herdr_resolve_pane() {  # <captain-json> -> pane_id
  local cap=$1 pane title session out
  pane=$(fm_nudge_json_get "$cap" '.pane // .handle // ""' '') || true
  title=$(fm_nudge_json_get "$cap" '.title // ""' '') || true
  session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
  [ -n "$pane" ] && { printf '%s\n' "$pane"; return 0; }
  [ -n "$title" ] || return 1
  if [ -n "$session" ]; then
    out=$(fm_run_timed 20 herdr pane list --session "$session" 2>/dev/null) || return 1
  else
    out=$(fm_run_timed 20 herdr pane list 2>/dev/null) || return 1
  fi
  printf '%s' "$out" | jq -r --arg t "$title" '
    (.result.panes // .panes // [])
    | map(select((.title // .name // "") | test($t)))
    | .[0].pane_id // empty
  ' 2>/dev/null
}

herdr_screen_change_epoch() {  # <captain-id> <screen> -> epoch the screen last changed
  local id=$1 screen=$2 f sum prev_sum prev_at now
  f=$CFG_STATE/captains/$id.screen
  sum=$(printf '%s' "$screen" | cksum | awk '{print $1}')
  now=$(fm_nudge_now)
  if [ -f "$f" ]; then
    read -r prev_sum prev_at < "$f" || true
    if [ "${prev_sum:-}" = "$sum" ] && [ -n "${prev_at:-}" ]; then
      printf '%s\n' "$prev_at"
      return 0
    fi
  fi
  printf '%s %s\n' "$sum" "$now" > "$f"
  printf '%s\n' "$now"
}

iso_to_epoch() {  # <iso-or-epoch>
  local v=$1
  case "$v" in
    '' ) printf ''; return 1 ;;
    *[!0-9]* )
      if date -u -d "$v" +%s 2>/dev/null; then return 0; fi
      python3 -c 'import datetime,sys
s=sys.argv[1]
s=s.replace("Z","+00:00")
print(int(datetime.datetime.fromisoformat(s).timestamp()))' "$v" 2>/dev/null
      ;;
    *)
      # Orca lastOutputAt is epoch milliseconds; normalise to seconds.
      if [ "${#v}" -ge 13 ]; then
        printf '%s\n' "$((v / 1000))"
      else
        printf '%s\n' "$v"
      fi
      ;;
  esac
}

heartbeat_epoch() {  # <fm_home>
  local home=$1 f
  home=$(fm_nudge_expand_path "$home")
  f=$home/state/heartbeat.json
  [ -f "$f" ] || return 1
  jq -r '.generated_epoch // empty' "$f" 2>/dev/null
}

commit_sig() {  # <fm_home-or-repo>
  local dir=$1
  dir=$(fm_nudge_expand_path "$dir")
  [ -d "$dir/.git" ] || [ -d "$dir" ] || return 0
  git -C "$dir" rev-parse HEAD 2>/dev/null || true
}

last_output_sig() {  # <screen> <lastOutputAt>
  printf '%s|%s\n' "$2" "$(printf '%s' "$1" | cksum | awk '{print $1}')"
}

# --- send (the only typer) --------------------------------------------------

send_fixed_prompt() {  # <prompt-kind> <backend> <target> [session] [lane-table]
  local kind=$1 backend=$2 target=$3 session=${4:-} text
  text=$(fm_nudge_prompt_text "$kind" "${5:-}") || die "unknown prompt kind: $kind"
  text=${text%$'\n'}
  fm_nudge_send_allowed_text "$text" || die "refusing to send anything but a fixed prompt"
  target_is_live_owner "$target" || return 1
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_SEND_LOG:-}" ]; then
    printf '%s\t%s\t%s\n' "$backend" "$target" "$text" >> "$FM_NUDGE_SEND_LOG"
    return 0
  fi
  case "$backend" in
    orca)
      fm_orca_cli_mutation fm_run_timed 20 orca terminal send --terminal "$target" --text "$text" --enter --json >/dev/null
      ;;
    herdr)
      if [ -n "$session" ]; then
        fm_run_timed 20 herdr pane send-text "$target" "$text" --session "$session" >/dev/null || return 1
      else
        fm_run_timed 20 herdr pane send-text "$target" "$text" >/dev/null || return 1
      fi
      # Codex treats an Enter that arrives right after a burst of typed text as
      # part of a paste and leaves the prompt unsent; pause before submitting.
      sleep "${FM_NUDGE_SUBMIT_DELAY:-1.5}"
      send_enter_only herdr "$target" "$session"
      ;;
    fixture)
      [ -n "${FM_NUDGE_SEND_LOG:-}" ] || die "fixture send needs FM_NUDGE_SEND_LOG"
      printf '%s\t%s\t%s\n' "$backend" "$target" "$text" >> "$FM_NUDGE_SEND_LOG"
      ;;
    *)
      die "unknown backend for send: $backend" 2
      ;;
  esac
}

# Enter only. Used after the fixed prompt, and to submit our own fixed prompt
# when a previous pass left it unsent in the composer.
send_enter_only() {  # <backend> <target> [session]
  local backend=$1 target=$2 session=${3:-}
  target_is_live_owner "$target" || return 1
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_SEND_LOG:-}" ]; then
    printf '%s\t%s\t%s\n' "$backend" "$target" "<Enter>" >> "$FM_NUDGE_SEND_LOG"
    return 0
  fi
  case "$backend" in
    herdr)
      if [ -n "$session" ]; then
        fm_run_timed 20 herdr pane send-keys "$target" Enter --session "$session" >/dev/null
      else
        fm_run_timed 20 herdr pane send-keys "$target" Enter >/dev/null
      fi
      ;;
    orca)
      fm_orca_cli_mutation fm_run_timed 20 orca terminal send --terminal "$target" --text "" --enter --json >/dev/null
      ;;
    fixture)
      [ -n "${FM_NUDGE_SEND_LOG:-}" ] || die "fixture send needs FM_NUDGE_SEND_LOG"
      printf '%s\t%s\t%s\n' "$backend" "$target" "<Enter>" >> "$FM_NUDGE_SEND_LOG"
      ;;
    *) return 1 ;;
  esac
}

# True when the composer's pending line is exactly one of the fixed prompts
# (ours, left unsent), so pressing Enter cannot submit anybody else's text.
pending_is_fixed_prompt() {  # <screen>
  local text kind tail
  tail=$(printf '%s\n' "$1" | awk 'NF' | tail -n 8)
  for kind in continue escalate merge; do
    text=$(fm_nudge_text "$kind")
    text=${text%$'\n'}
    printf '%s\n' "$tail" | LC_ALL=C grep -Fxq -e "› $text" -e "❯ $text" -e "> $text" -e "›  $text" && return 0
  done
  return 1
}

# Env prefix that points a home-scoped helper at <home>, not at whatever home
# overrides this process inherited.
home_env() {  # <home>
  printf '%s\0' env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE "FM_HOME=$1"
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_NOW:-}" ]; then
    printf '%s\0' "FM_NOW=$FM_NUDGE_NOW"
  fi
}

# Keep the captain home's stall ledger current from here, because its own
# watcher is the usual writer and is exactly what goes quiet in a stall.
record_stall_ledger() {  # <fm_home>
  local home arg argv=()
  [ -n "$1" ] || return 0
  home=$(fm_nudge_expand_path "$1")
  [ -d "$home/state" ] || return 0
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < <(home_env "$home")
  fm_run_timed 60 "${argv[@]}" /bin/bash "$SCRIPT_DIR/fm-stall-ledger.sh" observe >/dev/null 2>&1 || true
}

# Lock owner of <fm_home>, read at call time through fm-captain-locate.sh.
# Prints `<state><TAB><handle>`: state is held, free, stale, unknown, or
# unreadable, and handle is none unless the lock names a live endpoint.
locate_captain() {  # <fm_home>
  local home bin out line state handle arg argv=()
  home=$(fm_nudge_expand_path "$1")
  bin=$SCRIPT_DIR/fm-captain-locate.sh
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_LOCATE_BIN:-}" ]; then
    bin=$FM_NUDGE_LOCATE_BIN
  fi
  if [ ! -d "$home/state" ] || [ ! -x "$bin" ]; then
    printf 'unreadable\tnone\n'
    return 0
  fi
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < <(home_env "$home")
  # Exit 1 is the ordinary not-held answer; the CAPTAIN line still says why.
  out=$(fm_run_timed 20 "${argv[@]}" "$bin" 2>/dev/null) || true
  line=$(printf '%s\n' "$out" | grep '^CAPTAIN v1 ' | tail -n 1)
  state=$(printf '%s\n' "$line" | sed -n 's/.* state=\([a-z]*\).*/\1/p')
  handle=$(printf '%s\n' "$line" | sed -n 's/.* handle=\([^ ]*\).*/\1/p')
  case "$state" in held|free|stale|unknown|unreadable) ;; *) state=unreadable ;; esac
  case "$handle" in ''|*[!A-Za-z0-9_.:%-]*) handle=none ;; esac
  printf '%s\t%s\n' "$state" "$handle"
}

# True when <target> is still the lock owner's endpoint for the captain this
# pass resolved through its home, so a handoff between read and send never
# sends to the old pane. A captain resolved from config alone always passes.
target_is_live_owner() {  # <target>
  local row
  [ -n "${PASS_OWNER_HOME:-}" ] || return 0
  row=$(locate_captain "$PASS_OWNER_HOME")
  [ "${row%%$'\t'*}" = held ] && [ "${row#*$'\t'}" = "$1" ]
}

# bin/fm-ready-pr-discovery.sh --json for the captain home. Fails when the
# home or the helper is unavailable; the caller then skips the pass.
ready_discovery_json() {  # <fm_home>
  local home bin arg argv=()
  home=$(fm_nudge_expand_path "$1")
  [ -d "$home" ] || return 1
  bin=$SCRIPT_DIR/fm-ready-pr-discovery.sh
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_READY_PR_BIN:-}" ]; then
    bin=$FM_NUDGE_READY_PR_BIN
  fi
  [ -x "$bin" ] || return 1
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < <(home_env "$home")
  fm_run_timed 90 "${argv[@]}" "$bin" --json 2>/dev/null
}

# --- one captain ------------------------------------------------------------

emit_event() {  # <captain-id> <owner> <decision-json> <idle> <open-summary> [extra-json]
  local id=$1 owner=$2 decision=$3 idle=$4 open_sum=$5 extra=${6:-'{}'} now ts event
  now=$(fm_nudge_now)
  ts=$(fm_nudge_iso_ts "$now")
  event=$(jq -nc \
    --arg ts "$ts" \
    --argjson epoch "$now" \
    --arg host "$CFG_HOST" \
    --arg captain "$id" \
    --arg owner "$owner" \
    --argjson idle "$idle" \
    --arg open "$open_sum" \
    --argjson d "$decision" \
    --argjson extra "$extra" \
    --argjson dry "$DRY_RUN" \
    '{
      ts:$ts, epoch:$epoch, host:$host, captain:$captain, owner:$owner,
      event:$d.event, severity:$d.severity, reason:$d.reason,
      idle_min:$idle, open_work:$open, should_send:$d.should_send,
      prompt:($d.prompt // ""), dry_run:($dry==1)
    } + $extra')
  fm_nudge_append_logs "$CFG_JSONL" "$CFG_BEACON" "$event"
  printf '%s\n' "$event"
}

observe_fixture() {  # <captain-json> [after-send-read-index] -> observation fields via globals
  local cap=$1
  if [ -n "${2:-}" ]; then
    cap=$(printf '%s' "$cap" | jq -c --argjson i "$2" \
      '.fixture += ((.fixture.after_send // []) as $r | if ($r | length) == 0 then {} else $r[[$i, ($r | length) - 1] | min] end)')
    fm_nudge_json_bool "$cap" '.fixture.read_failed' && return 1
  fi
  OBS_SCREEN=$(fm_nudge_json_get "$cap" '.fixture.screen // ""' '') || true
  OBS_LAST_AT=$(fm_nudge_json_get "$cap" '.fixture.last_activity_epoch // ""' '') || true
  OBS_TARGET=$(fm_nudge_json_get "$cap" '.id' 'fixture') || true
  OBS_DRAFT=$(fm_nudge_json_get "$cap" '.fixture.draft // ""' '') || true
  OBS_DIALOG=$(fm_nudge_json_get "$cap" '.fixture.dialog // empty' '') || true
  OBS_COMPOSER=$(fm_nudge_json_get "$cap" '.fixture.composer // empty' '') || true
  OBS_HB=$(fm_nudge_json_get "$cap" '.fixture.heartbeat_epoch // ""' '') || true
  OBS_COMMIT=$(fm_nudge_json_get "$cap" '.fixture.commit // ""' '') || true
}

observe_live() {  # <captain-json>
  local cap=$1 backend handle last pane session fmhome row
  backend=$(fm_nudge_json_get "$cap" '.backend' '') || true
  fmhome=$(fm_nudge_json_get "$cap" '.fm_home // ""' '') || true
  OBS_SCREEN=''
  OBS_LAST_AT=''
  OBS_TARGET=''
  OBS_DRAFT=''
  OBS_DIALOG=''
  OBS_COMPOSER=''
  OBS_HB=''
  OBS_COMMIT=''
  case "$backend" in
    orca)
      row=$(orca_pick_terminal "$cap") || { OBS_TARGET=''; return 1; }
      handle=${row%%$'\t'*}
      [ -n "$handle" ] || return 1
      OBS_TARGET=$handle
      last=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
      OBS_LAST_AT=$(iso_to_epoch "$last" 2>/dev/null || true)
      OBS_SCREEN=$(orca_read_screen "$handle") || OBS_SCREEN=''
      OBS_DRAFT=$(orca_draft "$handle") || OBS_DRAFT=''
      ;;
    herdr)
      pane=$(herdr_resolve_pane "$cap") || return 1
      session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
      OBS_TARGET=$pane
      OBS_SCREEN=$(herdr_read_screen "$pane" "$session") || OBS_SCREEN=''
      # Herdr has no lastOutputAt; a cron-written heartbeat.json is not
      # captain activity. Track when the visible screen last changed.
      if [ -n "$OBS_SCREEN" ]; then
        OBS_LAST_AT=$(herdr_screen_change_epoch "$(fm_nudge_json_get "$cap" '.id' 'captain')" "$OBS_SCREEN") || OBS_LAST_AT=''
      fi
      ;;
    *)
      return 1
      ;;
  esac
  if [ -n "$fmhome" ]; then
    OBS_HB=$(heartbeat_epoch "$fmhome") || OBS_HB=''
    OBS_COMMIT=$(commit_sig "$fmhome") || OBS_COMMIT=''
  fi
}

idle_min_from_obs() {
  local now last=0 age
  now=$(fm_nudge_now)
  if [ -n "${OBS_LAST_AT:-}" ]; then
    last=$OBS_LAST_AT
  elif [ -n "${OBS_HB:-}" ]; then
    last=$OBS_HB
  fi
  case "$last" in ''|*[!0-9]*) printf ''; return 1 ;; esac
  age=$(( (now - last) / 60 ))
  [ "$age" -lt 0 ] && age=0
  printf '%s\n' "$age"
}

store_post_send_fingerprint() {  # <id> <captain-json>
  local id=$1 cap=$2 backend prev='' cur reads=0 limit=${FM_NUDGE_SETTLE_READS:-10}
  case "$limit" in ''|*[!0-9]*|0) limit=10 ;; esac
  backend=$(fm_nudge_json_get "$cap" '.backend' '') || true
  while :; do
    if [ "$backend" = fixture ]; then
      observe_fixture "$cap" "$reads"
    else
      observe_live "$cap" && [ -n "${OBS_SCREEN:-}" ]
    fi || {
      [ "$reads" -gt 0 ] || return 0
      cur=$prev
      break
    }
    reads=$((reads + 1))
    cur=$(fm_nudge_fingerprint "$(last_output_sig "${OBS_SCREEN:-}" "${OBS_LAST_AT:-}")" "${OBS_HB:-}" "${OBS_COMMIT:-}")
    [ "$cur" != "$prev" ] && [ "$reads" -lt "$limit" ] || break
    prev=$cur
    [ "$backend" = fixture ] || sleep "${FM_NUDGE_SETTLE_DELAY:-1}"
  done
  write_captain_state "$id" "$(jq -nc --arg fp "$cur" '{fingerprint:$fp}')"
}

process_captain() {  # <captain-json> [force]
  local cap=$1 force=${2:-0} id owner backend idle_th cool_th maxn
  local st last_nudge fp consec escalated now cool_left
  local open_line open_ok open_sum idle dialog composer obs decision
  local cur_fp progress send_ok=0 extra row session ev
  local tier esc_th council_th mr_th lane_th fmhome prompt new_tier would_send=0
  local lanes='' lane_age=0 lane_table='' since since_age
  id=$(fm_nudge_json_get "$cap" '.id' '') || true
  [ -n "$id" ] || return 0
  owner=$(fm_nudge_json_get "$cap" '.owner' 'firstmate') || true
  backend=$(fm_nudge_json_get "$cap" '.backend' '') || true
  idle_th=$(fm_nudge_json_get "$cap" ".idle_min // $CFG_IDLE" "$CFG_IDLE") || true
  cool_th=$(fm_nudge_json_get "$cap" ".cooldown_min // $CFG_COOL" "$CFG_COOL") || true
  maxn=$(fm_nudge_json_get "$cap" ".max_no_progress // $CFG_MAX_NP" "$CFG_MAX_NP") || true
  case "$idle_th" in ''|*[!0-9]*) idle_th=$CFG_IDLE ;; esac
  case "$cool_th" in ''|*[!0-9]*) cool_th=$CFG_COOL ;; esac
  case "$maxn" in ''|*[!0-9]*) maxn=$CFG_MAX_NP ;; esac
  esc_th=$(fm_nudge_json_get "$cap" ".escalate_min // $CFG_ESCALATE" "$CFG_ESCALATE") || true
  council_th=$(fm_nudge_json_get "$cap" ".council_min // $CFG_COUNCIL" "$CFG_COUNCIL") || true
  mr_th=$(fm_nudge_json_get "$cap" ".merge_ready_min // $CFG_MERGE_READY" "$CFG_MERGE_READY") || true
  case "$esc_th" in ''|*[!0-9]*) esc_th=$CFG_ESCALATE ;; esac
  case "$council_th" in ''|*[!0-9]*) council_th=$CFG_COUNCIL ;; esac
  case "$mr_th" in ''|*[!0-9]*) mr_th=$CFG_MERGE_READY ;; esac
  lane_th=$(fm_nudge_json_get "$cap" ".lane_stall_min // $CFG_LANE" "$CFG_LANE") || true
  case "$lane_th" in ''|*[!0-9]*) lane_th=$CFG_LANE ;; esac
  fmhome=$(fm_nudge_json_get "$cap" '.fm_home // ""' '') || true

  record_stall_ledger "$fmhome"
  if [ -n "$fmhome" ] && [ "$lane_th" -gt 0 ] && [ "$force" != 1 ]; then
    lanes=$(fm_nudge_lane_stalls "$(fm_nudge_expand_path "$fmhome")/state/stall-ledger.tsv" "$(fm_nudge_now)" "$lane_th")
    lane_age=$(printf '%s\n' "$lanes" | awk -F '\t' 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1 }')
    case "$lane_age" in ''|*[!0-9]*) lane_age=0 ;; esac
    lane_table=$(fm_nudge_lane_table "$lanes")
  fi

  st=$(read_captain_state "$id")
  tier=$(fm_nudge_json_get "$st" '.stall_tier' '0') || true
  case "$tier" in ''|*[!0-9]*) tier=0 ;; esac
  last_nudge=$(fm_nudge_json_get "$st" '.last_nudge_epoch' '0') || true
  fp=$(fm_nudge_json_get "$st" '.fingerprint' '') || true
  consec=$(fm_nudge_json_get "$st" '.consecutive_no_progress' '0') || true
  since=$(fm_nudge_json_get "$st" '.stall_since_epoch' '0') || true
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  escalated=false
  fm_nudge_json_bool "$st" '.escalated' && escalated=true
  case "$last_nudge" in ''|*[!0-9]*) last_nudge=0 ;; esac
  case "$consec" in ''|*[!0-9]*) consec=0 ;; esac
  now=$(fm_nudge_now)
  cool_left=0
  if [ "$last_nudge" -gt 0 ]; then
    cool_left=$(( cool_th - (now - last_nudge) / 60 ))
    [ "$cool_left" -lt 0 ] && cool_left=0
  fi

  OBS_SCREEN=''; OBS_LAST_AT=''; OBS_TARGET=''; OBS_DRAFT=''
  OBS_DIALOG=''; OBS_COMPOSER=''; OBS_HB=''; OBS_COMMIT=''
  # An Orca captain with a home is whoever holds that home's lock now, never
  # the configured handle or title: a successor often leaves the old pane open.
  PASS_OWNER_HOME=''
  if [ "$backend" = orca ] && [ -n "$fmhome" ]; then
    row=$(locate_captain "$fmhome")
    if [ "${row%%$'\t'*}" = held ] && [ "${row#*$'\t'}" != none ]; then
      cap=$(printf '%s' "$cap" | jq -c --arg h "${row#*$'\t'}" '.handle = $h | del(.title)')
      PASS_OWNER_HOME=$fmhome
    else
      decision=$(jq -nc --arg s "${row%%$'\t'*}" \
        '{event:"captain_unknown",severity:"medium",reason:("captain home lock is " + $s + "; endpoint unknown, nothing typed"),should_send:false}')
      emit_event "$id" "$owner" "$decision" 0 'none' "$(jq -nc --arg s "${row%%$'\t'*}" '{lock_state:$s, backend:"orca"}')" >/dev/null
      return 0
    fi
  fi
  if [ "$backend" = fixture ]; then
    observe_fixture "$cap"
  else
    if ! observe_live "$cap"; then
      decision=$(jq -nc '{event:"skip_pane_missing",severity:"medium",reason:"captain pane not found",should_send:false}')
      emit_event "$id" "$owner" "$decision" 0 'none'
      return 0
    fi
  fi

  if [ -z "${OBS_SCREEN:-}" ] && [ "$backend" != fixture ]; then
    decision=$(jq -nc '{event:"skip_read_failed",severity:"medium",reason:"pane read failed",should_send:false}')
    emit_event "$id" "$owner" "$decision" 0 'none'
    return 0
  fi

  dialog=${OBS_DIALOG:-}
  composer=${OBS_COMPOSER:-}
  if [ -z "$dialog" ] && [ -z "$composer" ]; then
    row=$(classify_screen "${OBS_SCREEN:-}")
    dialog=${row%%$'\t'*}
    composer=${row#*$'\t'}
  fi
  if [ -n "${OBS_DRAFT:-}" ] && [ "$OBS_DRAFT" != null ]; then
    composer=pending
  fi
  [ -n "$composer" ] || composer=unknown

  # Our own fixed prompt left unsent by an earlier pass: submit it (Enter only)
  # instead of reporting the composer as someone else's text.
  if [ "$composer" != empty ] && [ -z "$dialog" ] && [ "$last_nudge" -gt 0 ] \
     && pending_is_fixed_prompt "${OBS_SCREEN:-}"; then
    extra=$(jq -nc --arg t "${OBS_TARGET:-}" --arg b "$backend" '{target:$t, backend:$b}')
    decision=$(jq -nc '{event:"nudge",severity:"info",reason:"submitted own fixed prompt left unsent in composer (Enter only)",should_send:true}')
    if cfg_mode_is_act; then
      session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
      if send_enter_only "$backend" "${OBS_TARGET:-$id}" "$session"; then
        store_post_send_fingerprint "$id" "$cap"
      else
        decision=$(jq -nc '{event:"blocker",severity:"medium",reason:"submit of pending fixed prompt failed",should_send:false}')
      fi
    fi
    emit_event "$id" "$owner" "$decision" "$(idle_min_from_obs 2>/dev/null || echo 0)" 'pending fixed prompt' "$extra" >/dev/null
    return 0
  fi

  idle=$(idle_min_from_obs) || idle=''
  if [ -z "$idle" ]; then
    idle=$(fm_nudge_json_get "$cap" '.fixture.idle_min // empty' '') || true
  fi
  case "$idle" in ''|*[!0-9]*) idle=0 ;; esac

  open_line=$(fm_nudge_probe_open_work "$cap")
  open_ok=${open_line%%$'\t'*}
  open_sum=${open_line#*$'\t'}
  [ "$open_ok" = true ] || open_ok=false
  if [ -n "$lane_table" ]; then
    if [ "$open_ok" = true ]; then
      open_sum="$open_sum; $lane_table"
    else
      open_sum=$lane_table
    fi
  fi

  cur_fp=$(fm_nudge_fingerprint "$(last_output_sig "${OBS_SCREEN:-}" "${OBS_LAST_AT:-}")" "${OBS_HB:-}" "${OBS_COMMIT:-}")
  progress=false
  if [ -n "$fp" ] && [ "$cur_fp" != "$fp" ]; then
    progress=true
    consec=0
    escalated=false
  elif [ "$last_nudge" -gt 0 ] && [ "$progress" = false ]; then
    # Count a completed nudge that still shows the same fingerprint.
    :
  fi

  if [ "$force" = 1 ]; then
    idle=$idle_th
    open_ok=true
    [ -n "$open_sum" ] || open_sum='forced test-nudge'
    cool_left=0
    consec=0
    escalated=false
  fi
  if [ "$progress" = true ]; then
    since=0
  elif [ "$force" != 1 ] && [ "$tier" -gt 0 ] && [ "$since" -gt 0 ]; then
    since_age=$(( (now - since) / 60 ))
    [ "$since_age" -le "$idle" ] || idle=$since_age
  fi

  # Count a prior nudge that produced no progress only when this captain
  # would otherwise be eligible to send again (idle, open work, empty
  # composer, no modal, cooldown elapsed). Modal skips must not escalate.
  if [ "$force" != 1 ] && [ "$progress" = false ] && [ "$last_nudge" -gt 0 ] && [ "$cool_left" -eq 0 ] \
     && [ "$idle" -ge "$idle_th" ] && [ "$open_ok" = true ] && [ -z "$dialog" ] && [ "$composer" = empty ]; then
    consec=$((consec + 1))
  fi
  if [ "$progress" = true ]; then
    consec=0
    escalated=false
    if [ "$tier" -gt 0 ]; then
      decision=$(jq -nc --argjson t "$tier" \
        '{event:"stall_acked",severity:"info",reason:("captain progressed after stall tier " + ($t|tostring)),should_send:false}')
      emit_event "$id" "$owner" "$decision" "$idle" "$open_sum" >/dev/null
    fi
    tier=0
  fi
  if [ "$force" = 1 ]; then
    tier=0
    esc_th=0
    council_th=0
    lane_th=0
  fi

  obs=$(jq -nc \
    --argjson idle "$idle" \
    --argjson th "$idle_th" \
    --argjson open "$([ "$open_ok" = true ] && echo true || echo false)" \
    --arg sum "$open_sum" \
    --arg dialog "$dialog" \
    --arg composer "$composer" \
    --argjson cool "$cool_left" \
    --argjson consec "$consec" \
    --argjson progress "$([ "$progress" = true ] && echo true || echo false)" \
    --argjson esc "$([ "$escalated" = true ] && echo true || echo false)" \
    --argjson maxn "$maxn" \
    --argjson escmin "$esc_th" \
    --argjson councilmin "$council_th" \
    --argjson tier "$tier" \
    --argjson laneage "$lane_age" \
    --argjson lanemin "$lane_th" \
    '{
      idle_min:$idle, idle_threshold_min:$th, open_work:$open,
      open_work_summary:$sum, dialog:$dialog, composer:$composer,
      cooldown_remaining_min:$cool, consecutive_no_progress:$consec,
      progress_since_nudge:$progress, escalated:$esc, max_no_progress:$maxn,
      escalate_min:$escmin, council_min:$councilmin, stall_tier:$tier,
      lane_age_min:$laneage, lane_stall_min:$lanemin
    }')
  decision=$(fm_nudge_decide "$obs") || die "decide failed for $id"

  extra=$(jq -nc --arg t "${OBS_TARGET:-}" --arg b "$backend" --arg l "$lane_table" \
    '{target:$t, backend:$b} + (if $l == "" then {} else {lanes:$l} end)')
  emit_event "$id" "$owner" "$decision" "$idle" "$open_sum" "$extra" >/dev/null

  prompt=$(fm_nudge_json_get "$decision" '.prompt // ""' '') || true
  if fm_nudge_json_bool "$decision" '.should_send'; then
    if cfg_mode_is_act; then
      session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
      if send_fixed_prompt "${prompt:-continue}" "$backend" "${OBS_TARGET:-$id}" "$session" "$lane_table"; then
        send_ok=1
        would_send=1
      else
        decision=$(jq -nc '{event:"blocker",severity:"medium",reason:"send failed",should_send:false}')
        emit_event "$id" "$owner" "$decision" "$idle" "$open_sum" "$extra" >/dev/null
      fi
    else
      # Dry-run climbs the ladder on what it would have typed, so a drill
      # shows each tier's row at its time.
      would_send=1
    fi
  fi

  ev=$(fm_nudge_json_get "$decision" '.event' '') || true
  new_tier=$tier
  if [ "$ev" = stall_council ]; then
    new_tier=3
  elif [ "$would_send" = 1 ] && [ "$prompt" = escalate ]; then
    new_tier=2
  elif [ "$would_send" = 1 ] && [ "$tier" -lt 1 ]; then
    new_tier=1
  fi

  if [ "$send_ok" = 1 ]; then
    [ "$since" -gt 0 ] || since=$(( now - idle * 60 ))
    write_captain_state "$id" "$(jq -nc \
      --argjson now "$now" --arg fp "$cur_fp" --argjson consec "$consec" --argjson tier "$new_tier" --argjson since "$since" \
      '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:$consec, escalated:false, stall_tier:$tier, stall_since_epoch:$since}')"
    store_post_send_fingerprint "$id" "$cap"
  else
    if [ "$ev" = nudge_no_progress ]; then
      write_captain_state "$id" "$(jq -nc \
        --argjson now "$last_nudge" --arg fp "$fp" --argjson consec "$consec" --argjson tier "$new_tier" --argjson since "$since" \
        '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:$consec, escalated:true, stall_tier:$tier, stall_since_epoch:$since}')"
    elif [ "$progress" = true ]; then
      write_captain_state "$id" "$(jq -nc \
        --argjson now "$last_nudge" --arg fp "$cur_fp" --argjson tier "$new_tier" \
        '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:0, escalated:false, stall_tier:$tier, stall_since_epoch:0}')"
    else
      write_captain_state "$id" "$(jq -nc \
        --argjson now "$last_nudge" --arg fp "${fp:-$cur_fp}" --argjson consec "$consec" \
        --argjson esc "$([ "$escalated" = true ] && echo true || echo false)" --argjson tier "$new_tier" --argjson since "$since" \
        '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:$consec, escalated:$esc, stall_tier:$tier, stall_since_epoch:$since}')"
    fi
  fi

  if [ "$force" != 1 ]; then
    merge_ready_pass "$id" "$owner" "$fmhome" "$mr_th" "$dialog" "$composer" "$backend" \
      "${OBS_TARGET:-$id}" "$(fm_nudge_json_get "$cap" '.session // ""' '' || true)" "$idle" "$send_ok" "$cap"
  fi
}

# One prompt per merge-ready PR head that has waited merge_ready_min minutes.
# Waiting time starts when this tool first sees the head merge-ready, because
# discovery reports run age, not time since ready. A pass that already typed
# a stall prompt leaves the merge prompt for the next pass.
merge_ready_pass() {  # <id> <owner> <fm_home> <min> <dialog> <composer> <backend> <target> <session> <idle> <sent> <captain-json>
  local id=$1 owner=$2 home=$3 min=$4 dialog=$5 composer=$6 backend=$7 target=$8 session=$9
  local idle=${10} sent=${11} cap=${12}
  local json rows old new now key pr entry first nudged due='' due_prs='' extra decision summary
  [ -n "$home" ] && [ "$min" -gt 0 ] || return 0
  json=$(ready_discovery_json "$home") || return 0
  printf '%s' "$json" | jq -e '.runs | type == "array"' >/dev/null 2>&1 || return 0
  rows=$(fm_nudge_merge_ready_rows "$json")
  old=$(read_captain_state "$id" | jq -c '.merge_ready // {} | if type == "object" then . else {} end')
  new='{}'
  now=$(fm_nudge_now)
  while IFS=$'\t' read -r key pr; do
    [ -n "$key" ] || continue
    entry=$(printf '%s' "$old" | jq -c --arg k "$key" '.[$k] // empty')
    if [ -z "$entry" ]; then
      entry=$(jq -nc --argjson now "$now" --arg pr "$pr" '{first:$now, nudged:false, pr:$pr}')
      extra=$(jq -nc --arg pr "$pr" --arg k "$key" '{pr:$pr, run:$k}')
      decision=$(jq -nc '{event:"merge_ready",severity:"info",reason:"PR merge-ready at head; waiting for its merge",should_send:false}')
      emit_event "$id" "$owner" "$decision" "$idle" "merge-ready $pr" "$extra" >/dev/null
    fi
    first=$(printf '%s' "$entry" | jq -r '.first // 0')
    nudged=$(printf '%s' "$entry" | jq -r '.nudged // false')
    case "$first" in ''|*[!0-9]*) first=$now ;; esac
    if [ "$nudged" != true ] && [ $(( (now - first) / 60 )) -ge "$min" ]; then
      due="$due$key"$'\n'
      due_prs="${due_prs:+$due_prs,}$pr"
    fi
    new=$(printf '%s' "$new" | jq -c --arg k "$key" --argjson e "$entry" '.[$k] = $e')
  done <<< "$rows"

  while IFS=$'\t' read -r key pr; do
    [ -n "$key" ] || continue
    extra=$(jq -nc --arg pr "$pr" --arg k "$key" '{pr:$pr, run:$k}')
    decision=$(jq -nc '{event:"merge_ready_cleared",severity:"info",reason:"PR left the merge-ready list (merged, closed, or no longer ready)",should_send:false}')
    emit_event "$id" "$owner" "$decision" "$idle" "merge-ready $pr" "$extra" >/dev/null
  done < <(printf '%s' "$old" | jq -r --argjson new "$new" \
    'to_entries[] | select($new[.key] == null) | [.key, (.value.pr // "-")] | @tsv')

  if [ -n "$due" ] && [ "$sent" != 1 ]; then
    summary="merge-ready $due_prs"
    extra=$(jq -nc --arg pr "$due_prs" --arg t "$target" --arg b "$backend" '{pr:$pr, target:$t, backend:$b}')
    if [ -n "$dialog" ]; then
      decision=$(jq -nc --arg d "$dialog" '{event:"blocker",severity:"medium",reason:("merge-ready prompt held: modal visible: " + $d),should_send:false}')
      due=''
    elif [ "$composer" = pending ]; then
      decision=$(jq -nc '{event:"skipped_input_not_empty",severity:"info",reason:"merge-ready prompt held: composer holds typed text",should_send:false}')
      due=''
    elif [ "$composer" != empty ]; then
      decision=$(jq -nc '{event:"blocker",severity:"medium",reason:"merge-ready prompt held: composer state unproven",should_send:false}')
      due=''
    else
      decision=$(jq -nc --argjson m "$min" '{event:"merge_ready_wait",severity:"info",reason:("merge-ready PR unmerged for " + ($m|tostring) + "m; asking to dispatch the merge or record why"),should_send:true,prompt:"merge"}')
      if cfg_mode_is_act; then
        if send_fixed_prompt merge "$backend" "$target" "$session"; then
          store_post_send_fingerprint "$id" "$cap"
        else
          decision=$(jq -nc '{event:"blocker",severity:"medium",reason:"merge-ready prompt send failed",should_send:false}')
          due=''
        fi
      fi
    fi
    emit_event "$id" "$owner" "$decision" "$idle" "$summary" "$extra" >/dev/null
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      new=$(printf '%s' "$new" | jq -c --arg k "$key" '.[$k].nudged = true')
    done <<< "$due"
  fi

  write_captain_state "$id" "$(jq -nc --argjson m "$new" '{merge_ready:$m}')"
}

cmd_once() {
  load_config
  heartbeat_write
  local cap id
  while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    id=$(fm_nudge_json_get "$cap" '.id' '') || true
    if [ -n "$FORCE_CAPTAIN" ] && [ "$id" != "$FORCE_CAPTAIN" ]; then
      continue
    fi
    process_captain "$cap" 0
  done < <(printf '%s' "$CONFIG_JSON" | jq -c '.captains[]?')
}

cmd_run() {
  load_config
  local lock=$CFG_STATE/run.lock
  if ! mkdir "$lock" 2>/dev/null; then
    # A loop killed with SIGKILL (launchd bootout, OOM) leaves the lock behind.
    # Take it over only when its pid is gone or is not this tool's run loop.
    local holder
    holder=$(tr -cd '0-9' < "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null \
       && ps -o args= -p "$holder" 2>/dev/null | grep -q 'fm-captain-nudge.sh'; then
      echo "fm-captain-nudge: another run loop holds $lock"
      exit 0
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "fm-captain-nudge: another run loop holds $lock"; exit 0; }
  fi
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' "$$" > "$CFG_STATE/loop.pid"
  local sleeper=''
  trap 'rm -rf "$lock"; [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; exit 0' INT TERM HUP EXIT
  while :; do
    heartbeat_write
    fm_run_timed_fn 120 cmd_once || true
    heartbeat_write
    # Background sleep + wait so a TERM from launchd/systemd stops the loop now,
    # not after the interval.
    sleep "$CFG_INTERVAL" &
    sleeper=$!
    wait "$sleeper" 2>/dev/null || true
    sleeper=''
  done
}

# Restart only this tool's loop. Never a captain.
cmd_guard() {
  load_config
  local hb=$CFG_STATE/loop.heartbeat pidfile=$CFG_STATE/loop.pid now age pid args
  now=$(fm_nudge_now)
  if [ ! -f "$hb" ]; then
    age=99999
  else
    age=$((now - $(cat "$hb")))
  fi
  if [ "$age" -lt "$CFG_GUARD_STALE" ]; then
    return 0
  fi
  pid=$(tr -cd '0-9' < "$pidfile" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    # Require the executable name so a test file like fm-captain-nudge.test.sh
    # is never treated as the run loop.
    case "$args" in
      *fm-captain-nudge.sh*)
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        ;;
    esac
  fi
  rm -rf "$CFG_STATE/run.lock"
  # Relaunch detached. launchd/systemd KeepAlive usually does this first;
  # this path covers cron and a wedged loop that still holds a live pid.
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_SEND_LOG:-}" ]; then
    printf 'restart\t%s\n' "$age" >> "$FM_NUDGE_SEND_LOG"
    heartbeat_write
    printf '%s\n' "$$" > "$CFG_STATE/loop.pid"
    return 0
  fi
  nohup /bin/bash "$SCRIPT_DIR/fm-captain-nudge.sh" run --config "$(resolve_config_path)" \
    >/dev/null 2>&1 &
  heartbeat_write
}

cmd_decide() {
  local obs
  obs=$(cat)
  fm_nudge_decide "$obs"
}

cmd_test_nudge() {
  [ -n "$FORCE_CAPTAIN" ] || die "test-nudge requires --captain <id>" 2
  load_config
  local cap id
  cap=$(printf '%s' "$CONFIG_JSON" | jq -c --arg id "$FORCE_CAPTAIN" '.captains[] | select(.id==$id)') || true
  [ -n "$cap" ] || die "captain not in config: $FORCE_CAPTAIN" 2
  if [ -n "$FORCE_PANE" ]; then
    cap=$(printf '%s' "$cap" | jq -c --arg p "$FORCE_PANE" '.handle=$p | .pane=$p')
  fi
  process_captain "$cap" 1
}

# --- install / uninstall ----------------------------------------------------

LABEL_RUN=com.firstmate.captain-nudge
LABEL_GUARD=com.firstmate.captain-nudge-guard
SYSTEMD_RUN=firstmate-captain-nudge
SYSTEMD_GUARD=firstmate-captain-nudge-guard

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }

launchd_plist() {  # <label> <subcommand> <interval-or-keepalive>
  local label=$1 sub=$2 kind=$3 home script path cfg
  home=$(printf '%s' "$HOME" | xml_escape)
  script=$(printf '%s' "$SCRIPT_DIR/fm-captain-nudge.sh" | xml_escape)
  path=$(printf '%s' "$PATH" | xml_escape)
  cfg=$(printf '%s' "$(resolve_config_path)" | xml_escape)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$script</string><string>$sub</string>
    <string>--config</string><string>$cfg</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$path</string>
    <key>HOME</key><string>$home</string>
    <key>FM_NUDGE_CONFIG</key><string>$cfg</string>
  </dict>
  <key>RunAtLoad</key><true/>
EOF
  if [ "$kind" = keepalive ]; then
    cat <<EOF
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
EOF
  else
    cat <<EOF
  <key>StartInterval</key><integer>60</integer>
EOF
  fi
  cat <<EOF
  <key>StandardErrorPath</key><string>$home/Library/Logs/$label.err</string>
  <key>StandardOutPath</key><string>$home/Library/Logs/$label.out</string>
</dict></plist>
EOF
}

systemd_run_unit() {
  cat <<EOF
[Unit]
Description=Firstmate captain self-nudge loop
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=PATH=$PATH
Environment=HOME=$HOME
Environment=FM_NUDGE_CONFIG=$(resolve_config_path)
ExecStart=/bin/bash $SCRIPT_DIR/fm-captain-nudge.sh run --config $(resolve_config_path)
Restart=always
RestartSec=30s

[Install]
WantedBy=default.target
EOF
}

systemd_guard_unit() {
  cat <<EOF
[Unit]
Description=Firstmate captain self-nudge outer guard

[Service]
Type=oneshot
Environment=PATH=$PATH
Environment=HOME=$HOME
Environment=FM_NUDGE_CONFIG=$(resolve_config_path)
ExecStart=/bin/bash $SCRIPT_DIR/fm-captain-nudge.sh guard --config $(resolve_config_path)
EOF
}

systemd_guard_timer() {
  cat <<EOF
[Unit]
Description=Run captain self-nudge outer guard every minute

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
AccuracySec=10s
Unit=${SYSTEMD_GUARD}.service

[Install]
WantedBy=timers.target
EOF
}

cmd_install() {
  load_config
  local launchd_dir systemd_dir dry=$DRY_RUN
  launchd_dir=${FM_NUDGE_LAUNCHD_DIR:-"$HOME/Library/LaunchAgents"}
  systemd_dir=${FM_NUDGE_SYSTEMD_DIR:-"${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"}
  case "$(uname -s)" in
    Darwin)
      mkdir -p "$launchd_dir" "$HOME/Library/Logs"
      launchd_plist "$LABEL_RUN" run keepalive > "$launchd_dir/$LABEL_RUN.plist"
      launchd_plist "$LABEL_GUARD" guard interval > "$launchd_dir/$LABEL_GUARD.plist"
      if [ "$dry" = 1 ]; then
        printf 'would bootstrap %s and %s\n' "$LABEL_RUN" "$LABEL_GUARD"
        return 0
      fi
      if [ "${FM_TEST_SEAM:-}" != 1 ]; then
        launchctl bootout "gui/$(id -u)/$LABEL_RUN" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/$LABEL_GUARD" 2>/dev/null || true
        launchd_bootstrap_retry "$launchd_dir/$LABEL_RUN.plist" || die "launchctl bootstrap failed for $LABEL_RUN"
        launchd_bootstrap_retry "$launchd_dir/$LABEL_GUARD.plist" || die "launchctl bootstrap failed for $LABEL_GUARD"
      fi
      printf 'installed launchd %s and %s\n' "$LABEL_RUN" "$LABEL_GUARD"
      ;;
    Linux)
      if [ -n "${FM_NUDGE_SYSTEMD_DIR:-}" ] \
         || { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }; then
        mkdir -p "$systemd_dir"
        systemd_run_unit > "$systemd_dir/${SYSTEMD_RUN}.service"
        systemd_guard_unit > "$systemd_dir/${SYSTEMD_GUARD}.service"
        systemd_guard_timer > "$systemd_dir/${SYSTEMD_GUARD}.timer"
        if [ "$dry" = 1 ]; then
          printf 'would enable %s.service and %s.timer\n' "$SYSTEMD_RUN" "$SYSTEMD_GUARD"
          return 0
        fi
        if [ "${FM_TEST_SEAM:-}" != 1 ]; then
          systemctl --user daemon-reload
          systemctl --user enable --now "${SYSTEMD_RUN}.service"
          systemctl --user enable --now "${SYSTEMD_GUARD}.timer"
        fi
        printf 'installed systemd %s and %s.timer\n' "$SYSTEMD_RUN" "$SYSTEMD_GUARD"
      else
        local cron=${FM_NUDGE_CRON_FILE:-}
        local line_once line_guard cfg
        cfg=$(resolve_config_path)
        line_once="*/5 * * * * FM_NUDGE_CONFIG=$cfg /bin/bash $SCRIPT_DIR/fm-captain-nudge.sh once --config $cfg # firstmate-captain-nudge"
        line_guard="* * * * * FM_NUDGE_CONFIG=$cfg /bin/bash $SCRIPT_DIR/fm-captain-nudge.sh guard --config $cfg # firstmate-captain-nudge-guard"
        if [ "$dry" = 1 ]; then
          printf '%s\n%s\n' "$line_once" "$line_guard"
          return 0
        fi
        if [ -n "$cron" ]; then
          {
            grep -v 'firstmate-captain-nudge' "$cron" 2>/dev/null || true
            printf '%s\n%s\n' "$line_once" "$line_guard"
          } > "$cron.tmp" && mv "$cron.tmp" "$cron"
        else
          (crontab -l 2>/dev/null | grep -v 'firstmate-captain-nudge' || true
           printf '%s\n%s\n' "$line_once" "$line_guard") | crontab -
        fi
        printf 'installed cron once + guard\n'
      fi
      ;;
    *)
      die "unsupported platform $(uname -s)" 2
      ;;
  esac
}

# bootout is asynchronous; bootstrap right after it fails with EIO (5) until the
# old job is gone, so retry for up to ~40s.
launchd_bootstrap_retry() {  # <plist>
  local plist=$1 i
  for i in $(seq 1 20); do
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && return 0
    sleep 2
  done
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

cmd_uninstall() {
  load_config
  local launchd_dir systemd_dir dry=$DRY_RUN
  launchd_dir=${FM_NUDGE_LAUNCHD_DIR:-"$HOME/Library/LaunchAgents"}
  systemd_dir=${FM_NUDGE_SYSTEMD_DIR:-"${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"}
  case "$(uname -s)" in
    Darwin)
      if [ "$dry" != 1 ] && [ "${FM_TEST_SEAM:-}" != 1 ]; then
        launchctl bootout "gui/$(id -u)/$LABEL_RUN" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/$LABEL_GUARD" 2>/dev/null || true
      fi
      rm -f "$launchd_dir/$LABEL_RUN.plist" "$launchd_dir/$LABEL_GUARD.plist"
      printf 'removed launchd %s and %s\n' "$LABEL_RUN" "$LABEL_GUARD"
      ;;
    Linux)
      if [ -n "${FM_NUDGE_SYSTEMD_DIR:-}" ] || [ -f "$systemd_dir/${SYSTEMD_RUN}.service" ]; then
        if [ "$dry" != 1 ] && [ "${FM_TEST_SEAM:-}" != 1 ]; then
          systemctl --user disable --now "${SYSTEMD_RUN}.service" 2>/dev/null || true
          systemctl --user disable --now "${SYSTEMD_GUARD}.timer" 2>/dev/null || true
          systemctl --user daemon-reload 2>/dev/null || true
        fi
        rm -f "$systemd_dir/${SYSTEMD_RUN}.service" \
          "$systemd_dir/${SYSTEMD_GUARD}.service" \
          "$systemd_dir/${SYSTEMD_GUARD}.timer"
        printf 'removed systemd units\n'
      else
        local cron=${FM_NUDGE_CRON_FILE:-}
        if [ -n "$cron" ]; then
          grep -v 'firstmate-captain-nudge' "$cron" > "$cron.tmp" 2>/dev/null || true
          mv "$cron.tmp" "$cron"
        elif [ "$dry" != 1 ] && [ "${FM_TEST_SEAM:-}" != 1 ]; then
          crontab -l 2>/dev/null | grep -v 'firstmate-captain-nudge' | crontab - || true
        fi
        printf 'removed cron lines\n'
      fi
      ;;
  esac
}

cmd_status() {
  load_config
  local hb age now pid
  now=$(fm_nudge_now)
  if [ -f "$CFG_STATE/loop.heartbeat" ]; then
    age=$((now - $(cat "$CFG_STATE/loop.heartbeat")))
  else
    age=-1
  fi
  pid=$(tr -cd '0-9' < "$CFG_STATE/loop.pid" 2>/dev/null || true)
  printf 'host=%s config=%s state=%s heartbeat_age_s=%s pid=%s dry_run=%s\n' \
    "$CFG_HOST" "$CONFIG_PATH" "$CFG_STATE" "$age" "${pid:-none}" "$DRY_RUN"
}

# --- argv -------------------------------------------------------------------

cmd=${1:-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) NUDGE_CONFIG=${2:?--config needs a path}; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --captain) FORCE_CAPTAIN=${2:?--captain needs an id}; shift ;;
    --pane|--handle) FORCE_PANE=${2:?--pane needs a handle}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
  shift
done

case "$cmd" in
  once) cmd_once ;;
  run) cmd_run ;;
  guard) cmd_guard ;;
  decide) cmd_decide ;;
  test-nudge) cmd_test_nudge ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  -h|--help|help|'') usage; [ -n "$cmd" ] && [ "$cmd" != help ] || exit 0; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
