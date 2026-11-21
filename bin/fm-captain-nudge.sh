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
# A periodic, model-free typer that sends one fixed prompt into a configured
# captain pane when that captain has been idle long enough and still has open
# work. docs/captain-nudge.md owns behaviour, install, and hard limits.
# docs/captain-nudge-spec.md owns the JSONL object and NUDGE v1 beacon line.
# docs/configuration.md ("Captain self-nudge") owns the config file schema.
# This header owns commands, flags, files, and the send/guard mechanics.
#
# Hard limits, enforced here:
#   - never merge, deploy, spend, run git/gh mutations, kill or restart a
#     captain, or run `herdr server stop`;
#   - the only typed payload is the fixed prompt from fm_nudge_text;
#   - a visible modal or a non-empty input line never receives that prompt;
#   - the outer guard may restart only this tool's own loop process, and only
#     after the pid file's command line still names fm-captain-nudge.
#
# Files, all under the config's state_dir (default ~/.local/state/firstmate/captain-nudge):
#   loop.heartbeat   epoch of the last run/once tick
#   loop.pid         pid of a live `run` loop
#   captains/<id>.json  last nudge epoch, fingerprint, consecutive_no_progress, escalated
# The JSONL log and beacon log paths are config keys (defaults under state_dir
# and, when set, the existing host beacon log).
#
# Config path: --config, else FM_NUDGE_CONFIG, else
# ~/.config/firstmate/captain-nudge.json.
#
# Test seams, honoured only with FM_TEST_SEAM=1: FM_NUDGE_NOW, FM_NUDGE_SEND_LOG
# (send writes the payload instead of calling orca/herdr), FM_NUDGE_LAUNCHD_DIR,
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
  CFG_IDLE=$(fm_nudge_json_get "$CONFIG_JSON" '.idle_min' '20') || true
  CFG_COOL=$(fm_nudge_json_get "$CONFIG_JSON" '.cooldown_min' '30') || true
  CFG_MAX_NP=$(fm_nudge_json_get "$CONFIG_JSON" '.max_no_progress' '2') || true
  CFG_STATE=$(fm_nudge_expand_path "$(fm_nudge_json_get "$CONFIG_JSON" '.state_dir' "${HOME}/.local/state/firstmate/captain-nudge")")
  CFG_JSONL=$(fm_nudge_expand_path "$(fm_nudge_json_get "$CONFIG_JSON" '.jsonl_log' "$CFG_STATE/nudge.jsonl")")
  CFG_BEACON=$(fm_nudge_expand_path "$(fm_nudge_json_get "$CONFIG_JSON" '.beacon_log' "$CFG_STATE/nudge-beacon.log")")
  CFG_MODE=$(fm_nudge_json_get "$CONFIG_JSON" '.mode' 'act') || true
  case "$CFG_INTERVAL" in ''|*[!0-9]*) CFG_INTERVAL=300 ;; esac
  case "$CFG_GUARD_STALE" in ''|*[!0-9]*) CFG_GUARD_STALE=660 ;; esac
  case "$CFG_IDLE" in ''|*[!0-9]*) CFG_IDLE=20 ;; esac
  case "$CFG_COOL" in ''|*[!0-9]*) CFG_COOL=30 ;; esac
  case "$CFG_MAX_NP" in ''|*[!0-9]*) CFG_MAX_NP=2 ;; esac
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
    printf '%s\n' '{"last_nudge_epoch":0,"fingerprint":"","consecutive_no_progress":0,"escalated":false}'
  fi
}

write_captain_state() {  # <id> <json>
  local f tmp
  f=$(captain_state_path "$1")
  tmp=$f.tmp.$$
  printf '%s\n' "$2" | jq -c . > "$tmp" && mv "$tmp" "$f"
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

# The live captain terminal a firstmate home recorded at its last session start
# (bin/fm-order.sh claim-handle writes <fm_home>/state/captain-handle). Prints
# "<session>\t<pane>" for a herdr handle, or returns 1. The handle counts only
# while the session that recorded it still holds the home: state/.lock names a
# live pid and the handle is not older than that lock.
herdr_live_handle() {  # <fm_home>
  local home=$1 f backend target lock_pid
  [ -n "$home" ] || return 1
  home=$(fm_nudge_expand_path "$home")
  f=$home/state/captain-handle
  [ -r "$f" ] || return 1
  lock_pid=$(sed -n '1p' "$home/state/.lock" 2>/dev/null | tr -cd '0-9')
  [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null || return 1
  [ ! "$home/state/.lock" -nt "$f" ] || return 1
  backend=$(sed -n 's/^backend=//p' "$f" | head -n 1)
  target=$(sed -n 's/^target=//p' "$f" | head -n 1)
  [ "$backend" = herdr ] || return 1
  case "$target" in *:*:*) ;; *) return 1 ;; esac
  printf '%s\t%s\n' "${target%%:*}" "${target#*:}"
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

send_fixed_prompt() {  # <backend> <target> [session]
  local backend=$1 target=$2 session=${3:-} text
  text=$(fm_nudge_text)
  text=${text%$'\n'}
  fm_nudge_send_allowed_text "$text" || die "refusing to send anything but the fixed prompt"
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_SEND_LOG:-}" ]; then
    { printf '%s\t%s\t%s' "$backend" "$target" "$text"
      [ -z "$session" ] || printf '\t%s' "$session"
      printf '\n'; } >> "$FM_NUDGE_SEND_LOG"
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
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_NUDGE_SEND_LOG:-}" ]; then
    { printf '%s\t%s\t%s' "$backend" "$target" "<Enter>"
      [ -z "$session" ] || printf '\t%s' "$session"
      printf '\n'; } >> "$FM_NUDGE_SEND_LOG"
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

# True when the composer's pending line is exactly the fixed prompt (ours,
# left unsent), so pressing Enter cannot submit anybody else's text.
pending_is_fixed_prompt() {  # <screen>
  local text
  text=$(fm_nudge_text)
  text=${text%$'\n'}
  printf '%s\n' "$1" | awk 'NF' | tail -n 8 | LC_ALL=C grep -Fxq -e "› $text" -e "❯ $text" -e "> $text" -e "›  $text"
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
      dry_run:($dry==1)
    } + $extra')
  fm_nudge_append_logs "$CFG_JSONL" "$CFG_BEACON" "$event"
  printf '%s\n' "$event"
}

observe_fixture() {  # <captain-json> -> observation fields via globals
  local cap=$1
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
  local cap=$1 backend handle last pane session fmhome row read_ok
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
      pane=$(herdr_resolve_pane "$cap") || pane=''
      pinned=$(fm_nudge_json_get "$cap" '.pane // .handle // ""' '') || pinned=''
      session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
      read_ok=0
      if [ -n "$pane" ] && OBS_SCREEN=$(herdr_read_screen "$pane" "$session"); then
        read_ok=1
      else
        OBS_SCREEN=''
      fi
      # A pinned pane goes stale when herdr restarts or the captain moves. When
      # an explicit pin cannot be read, follow the live captain terminal the
      # named home recorded at its last session start instead of failing every
      # pass. A title selector never falls back, whether it matched nothing or
      # matched a pane whose read failed.
      if [ "$read_ok" = 0 ] && [ -n "$pinned" ] && row=$(herdr_live_handle "$fmhome") \
        && [ "$row" != "$session"$'\t'"$pane" ]; then
        session=${row%%$'\t'*}
        pane=${row#*$'\t'}
        OBS_SCREEN=$(herdr_read_screen "$pane" "$session") || OBS_SCREEN=''
      fi
      [ -n "$pane" ] || return 1
      OBS_TARGET=$pane
      OBS_SESSION=$session
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

process_captain() {  # <captain-json> [force]
  local cap=$1 force=${2:-0} id owner backend idle_th cool_th maxn
  local st last_nudge fp consec escalated now cool_left
  local open_line open_ok open_sum idle dialog composer obs decision
  local cur_fp progress send_ok=0 extra row session ev
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

  st=$(read_captain_state "$id")
  last_nudge=$(fm_nudge_json_get "$st" '.last_nudge_epoch' '0') || true
  fp=$(fm_nudge_json_get "$st" '.fingerprint' '') || true
  consec=$(fm_nudge_json_get "$st" '.consecutive_no_progress' '0') || true
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

  OBS_SCREEN=''; OBS_LAST_AT=''; OBS_TARGET=''; OBS_DRAFT=''; OBS_SESSION=''
  OBS_DIALOG=''; OBS_COMPOSER=''; OBS_HB=''; OBS_COMMIT=''
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
      session=${OBS_SESSION:-}
      [ -n "$session" ] || session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
      if ! send_enter_only "$backend" "${OBS_TARGET:-$id}" "$session"; then
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
    '{
      idle_min:$idle, idle_threshold_min:$th, open_work:$open,
      open_work_summary:$sum, dialog:$dialog, composer:$composer,
      cooldown_remaining_min:$cool, consecutive_no_progress:$consec,
      progress_since_nudge:$progress, escalated:$esc, max_no_progress:$maxn
    }')
  decision=$(fm_nudge_decide "$obs") || die "decide failed for $id"

  extra=$(jq -nc --arg t "${OBS_TARGET:-}" --arg b "$backend" '{target:$t, backend:$b}')
  emit_event "$id" "$owner" "$decision" "$idle" "$open_sum" "$extra" >/dev/null

  if fm_nudge_json_bool "$decision" '.should_send' && cfg_mode_is_act; then
    session=${OBS_SESSION:-}
    [ -n "$session" ] || session=$(fm_nudge_json_get "$cap" '.session // ""' '') || true
    if send_fixed_prompt "$backend" "${OBS_TARGET:-$id}" "$session"; then
      send_ok=1
    else
      decision=$(jq -nc '{event:"blocker",severity:"medium",reason:"send failed",should_send:false}')
      emit_event "$id" "$owner" "$decision" "$idle" "$open_sum" "$extra" >/dev/null
    fi
  fi

  if [ "$send_ok" = 1 ]; then
    write_captain_state "$id" "$(jq -nc \
      --argjson now "$now" --arg fp "$cur_fp" --argjson consec "$consec" \
      '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:$consec, escalated:false}')"
  else
    ev=$(fm_nudge_json_get "$decision" '.event' '') || true
    if [ "$ev" = nudge_no_progress ]; then
      write_captain_state "$id" "$(jq -nc \
        --argjson now "$last_nudge" --arg fp "$fp" --argjson consec "$consec" \
        '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:$consec, escalated:true}')"
    elif [ "$progress" = true ]; then
      write_captain_state "$id" "$(jq -nc \
        --argjson now "$last_nudge" --arg fp "$cur_fp" \
        '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:0, escalated:false}')"
    else
      write_captain_state "$id" "$(jq -nc \
        --argjson now "$last_nudge" --arg fp "${fp:-$cur_fp}" --argjson consec "$consec" \
        --argjson esc "$([ "$escalated" = true ] && echo true || echo false)" \
        '{last_nudge_epoch:$now, fingerprint:$fp, consecutive_no_progress:$consec, escalated:$esc}')"
    fi
  fi
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
