#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks. On a non-Pi primary
# with a supervision protocol (claude, cursor, opencode, omp, grok, codex, agy) whose
# home runs the supervision host (fm_supervision_host_enabled in
# bin/fm-supervision-engine-lib.sh: by default on Claude, by
# config/supervision-host elsewhere, never with config/supervision-host-off), the block
# adds one state line and the host's main-side protocol
# (docs/supervision-protocols/supervision-host.md, whose lines tagged
# "{<harness>,...} " render only for the listed harnesses), and Grok's arm
# command becomes the host; on a home that does not run it the output is
# unchanged.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bash-compat-lib.sh
. "$SCRIPT_DIR/fm-bash-compat-lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
AFK_MODE=away
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--afk-mode away|quiet] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
--afk-mode only matters when --afk 1 (present); it selects the away-mode vs
quiet-mode (kunchenguid/firstmate#2356) wording, and defaults to away.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --afk-mode)
      [ "$#" -gt 1 ] || { echo "error: --afk-mode requires away or quiet" >&2; exit 2; }
      case "$2" in
        away|quiet) AFK_MODE=$2 ;;
        *) AFK_MODE=away ;;
      esac
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok|cursor|omp|muse|agy) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"
HOST_SNIPPET=
grok_arm='bin/fm-watch-arm.sh'
grok_arm_command='export FM_WATCH_GROK_CONTINUITY=1; exec bin/fm-watch-arm.sh'
case "$HARNESS" in
  claude|cursor|opencode|omp|grok|codex|agy)
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
    if fm_supervision_host_enabled "$CONFIG" "$HARNESS"; then
      HOST_SNIPPET="$DOC_DIR/supervision-host.md"
      grok_arm='bin/fm-supervision-host.sh park'
      grok_arm_command='exec bin/fm-supervision-host.sh park'
    fi
    ;;
esac

SECONDMATE_MODE=0
if [ "$HARNESS" = codex ] && [ "$AFK" -eq 0 ] && [ -x "$SCRIPT_DIR/fm-watch.sh" ] \
  && "$SCRIPT_DIR/fm-watch.sh" --secondmate-selected >/dev/null 2>&1; then
  SECONDMATE_MODE=1
fi
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
omp_ext="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
omp_turnend_ext="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

# True when the active home is not the firstmate checkout: omp's extensions load
# from the checkout, and only the `fm <project>` launcher points them at another home.
omp_home_elsewhere=0
if [ "$(cd -P "$FM_HOME" 2>/dev/null && pwd -P || printf '%s' "$FM_HOME")" != "$(cd -P "$FM_ROOT" 2>/dev/null && pwd -P || printf '%s' "$FM_ROOT")" ]; then
  omp_home_elsewhere=1
fi
# shellcheck disable=SC2016  # backticks are literal markdown in the rendered text
if [ "$omp_home_elsewhere" -eq 1 ]; then
  omp_restart_long='exit omp and relaunch through `fm <project>`, which sets FM_HOME and --cwd; a bare omp or /resume from the firstmate checkout does not register the extensions for this home'
  omp_restart_short='exit omp and relaunch through `fm <project>`'
else
  omp_restart_long="restart omp inside this home; pass \`-e $omp_turnend_ext -e $omp_ext\` only when omp must start from another directory, because omp loads a file named both ways twice"
  omp_restart_short='restart omp inside this home'
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {  # [snippet]
  local line tags snippet=${1:-$SNIPPET}
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '{'*'} '*)
        tags=${line%%\} *}
        tags=${tags#\{}
        case ",$tags," in *",$HARNESS,"*) ;; *) continue ;; esac
        line=${line#*\} }
        ;;
    esac
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_OMP_RESTART_LONG__/$omp_restart_long}
    line=${line//__FM_OMP_RESTART_SHORT__/$omp_restart_short}
    line=${line//__FM_OMP_EXT__/$omp_ext}
    line=${line//__FM_OMP_TURNEND_EXT__/$omp_turnend_ext}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    line=${line//__FM_GROK_ARM_COMMAND__/$grok_arm_command}
    line=${line//__FM_GROK_ARM__/$grok_arm}
    printf '%s\n' "$line"
  done < "$snippet"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '%s\n' 'Quiet mode owns watcher supervision; load /quiet and ensure the daemon is running instead of starting normal supervision directly.'
    elif [ "$HARNESS" = codex ]; then
      printf '%s\n' 'Away mode owns watcher supervision; the Stop hook does not re-arm a watcher here, so drain the queued wakes and then stop, and load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    else
      printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    fi
    return 0
  fi

  prefix=
  if [ "$SECONDMATE_MODE" -eq 1 ]; then
    prefix='Drain and acknowledge pending wakes and run bin/fm-watch.sh --secondmate, then end this turn; if it reports a failure, '
  elif [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      if [ "$SECONDMATE_MODE" -eq 1 ]; then
        printf '%s%s\n' "$prefix" 'do not start a foreground checkpoint. Tell the parent that the outside-turn watcher failed, then stop. The Stop hook bounds repeated blocks.'
      elif [ -n "$HOST_SNIPPET" ]; then
        printf '%s%s\n' "$prefix" 'do not start another foreground checkpoint. The Stop hook re-arms a persistent watcher, except under an away record on this home, or allows this turn to end. Poll a checkpoint only while it is still running, then stop.'
      else
        printf '%s%s\n' "$prefix" 'do not start another foreground checkpoint. The Stop hook re-arms a persistent watcher or allows this turn to end. Poll a checkpoint only while it is still running, then stop.'
      fi
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    omp)
      # shellcheck disable=SC2016  # backticks are literal markdown in the rendered text
      if [ "$omp_home_elsewhere" -eq 1 ]; then
        printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool fm_watch_arm_omp, or exit omp and relaunch through `fm <project>` (the launcher sets FM_HOME and --cwd) so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' load for this home; a bare omp or /resume from the firstmate checkout does not register the extensions for this home.'
      else
        printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool fm_watch_arm_omp, or restart omp inside this home so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' auto-load from .omp/extensions/ (use -e with both paths only when starting omp from another directory).'
      fi
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with ' "$grok_arm_command" ' as its own Grok tracked background task, never shell &.'
      ;;
    cursor)
      printf '%s%s\n' "$prefix" 'watcher supervision is owned by the stop-hook park; inspect the hook registration and watcher startup path before ending the turn.'
      ;;
    muse)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Muse tracked background task, never shell & or a foreground wait.'
      ;;
    agy)
      if [ -n "$HOST_SNIPPET" ]; then
        printf '%s%s\n' "$prefix" 'supervision is owned by the Stop-hook park (.agents/hooks.json -> bin/fm-turnend-guard-agy.sh running the supervision host); inspect the hook registration and supervision host startup path before ending the turn.'
      else
        printf '%s%s\n' "$prefix" 'watcher supervision is owned by the Stop-hook park (.agents/hooks.json -> bin/fm-turnend-guard-agy.sh); inspect the hook registration and watcher startup path before ending the turn.'
      fi
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  if [ "$SECONDMATE_MODE" -eq 1 ]; then
    printf '%s\n' '- Ordinary wake: handle and acknowledge durable inbox/watcher events, send actions and parent replies, then end this turn; the existing watcher remains outside it.'
    return 0
  fi
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: drain and acknowledge the wake, then end the turn. The Stop hook re-arms a persistent watcher. Do not start another foreground checkpoint.'
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    omp)
      printf '%s\n' '- Ordinary wake: the omp extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s%s%s\n' '- Ordinary wake: re-arm exactly one ' "$grok_arm_command" ' Grok tracked background task as directed below.'
      ;;
    cursor)
      printf '%s\n' '- Ordinary wake: the stop-hook park (bin/fm-turnend-guard-cursor.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    muse)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Muse tracked background task as directed below.'
      ;;
    agy)
      printf '%s\n' '- Ordinary wake: the Stop-hook park (bin/fm-turnend-guard-agy.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf '%s\n' '- Quiet mode: active; load /quiet and keep normal harness supervision paused while the daemon owns the watcher. Ordinary captain chat does NOT exit it - only an explicit /quiet off does.'
  else
    printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
  fi
else
  printf '%s\n' '- Away/quiet mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
if [ -n "$HOST_SNIPPET" ]; then
  printf '%s\n' '- Supervision host: on; it takes away-posture wakes and, where the dialog mirror is verified, eligible attended wakes itself, and hands the rest to you (protocol at the end of this block).'
fi
ordinary_wake_line
printf '\n'
if [ "$SECONDMATE_MODE" -eq 1 ]; then
  cat <<'EOF'
Mode: Secondmate event-driven turns.
Read and acknowledge the steering inbox, drain and handle durable watcher events, and run the exact WAKE_ACK_REQUIRED acknowledgement after handling them.
Send resulting actions and parent-channel replies in this handling turn.
Run bin/fm-watch.sh --secondmate once to verify the outside-turn watcher and notification route, then end this turn.
Do not wait for crews or poll a tool session; an existing inbox doorbell starts the next handling turn when an actionable event arrives.
If bin/fm-watch.sh --secondmate reports a failure, tell the parent that the outside-turn watcher failed, then stop. Do not start a foreground checkpoint.
EOF
fi
render_snippet
printf '\n'
if [ -n "$HOST_SNIPPET" ]; then
  render_snippet "$HOST_SNIPPET"
  printf '\n'
fi
