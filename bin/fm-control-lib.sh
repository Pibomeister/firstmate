#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and TWO named exceptions to that purity, both of which run backend reads:
# fm_control_agent_state, the control plane's one agent-state read, and
# fm_control_endpoint_absence_verdict, the single owner of the per-backend
# endpoint-absence proof. Everything else has no side effects, runs no backend
# command, and reads no state, so sourcing this file is still free and the
# tables can be read by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (fm_control_agent_state below) able to PROVE that an agent stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb: it is not deterministic across the
# verified adapters (docs/agent-control.md owns the per-adapter resume facts).
# `relaunch` uses the brief on disk rather than a harness-private session as
# its durable instruction. The relaunch-time exception is
# fm_control_relaunch_resume_flag below: a reference the endpoint's runtime
# bound as its status authority is returned to a replacement with that adapter.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harnesses() {
  printf '%s\n' claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin commandcode polytoken droid
}

fm_control_harness_supported() {  # <harness>
  local harness found=1
  while read -r harness; do
    [ "$harness" = "${1-}" ] && found=0
  done < <(fm_control_harnesses)
  return "$found"
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands, `agy`
# is exact for the same reason on an even shorter name, `devin` and
# `commandcode` are exact as well, and an unrecognized value returns nonzero rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    agy) printf 'agy' ;;
    devin) printf 'devin' ;;
    droid) printf 'droid' ;;
    commandcode) printf 'commandcode' ;;
    polytoken) printf 'polytoken' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    rovo*) printf 'rovo' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. The harness-adapters router
# owns each adapter's task-kind boundary, and bin/fm-spawn.sh enforces it. The control
# plane asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini|rovo|agy|devin|commandcode|polytoken|droid) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# Which transport a harness's interrupt verb rides: `rest` for a typed API
# call, `key` for the keyplane sequence the tables below describe. polytoken
# is the one rest adapter: its TUI has NO interrupt chord at all (verified
# live on 0.8.19 through the full `print tui-command-actions` inventory:
# `submit-prompt` is the only Enter action in Prompt scope, a single Escape
# does nothing in Prompt scope, and Escape Escape opens the rewind picker),
# so an interrupt MUST be POST /turn/cancel on the session daemon, and the
# keyplane tables below deliberately refuse it so nothing can improvise a
# key. Every other verified harness interrupts through the keyplane.
fm_control_interrupt_transport() {  # <harness>
  case "${1-}" in
    polytoken) printf 'rest' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|devin|droid|commandcode) printf 'key' ;;
    *) return 1 ;;
  esac
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
# rovo cancels on a single Escape too, printing "Agent cancelled" (verified,
# 202609.1.2). agy cancels on a single Escape, printing the Interrupted row
# with an idle composer and no repollution (verified live, agy 1.2.0 through
# Herdr). omp (Oh My Pi) shares Pi's single Escape, empty composer
# afterwards, and /quit exit (verified omp 18.1.2 in a PTY, re-verified 18.1.11
# through Herdr).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo|agy|devin|commandcode|droid) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode and Devin need a double
# Escape; every other verified adapter interrupts on a single press. Command Code
# cancels a running turn on one Escape (verified live, Command Code 1.74.1), and a
# second press is exactly what opens its rewind picker, so it gets one.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode|devin) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode|droid) printf '1' ;;
    *) return 1 ;;
  esac
}

# The rendered proof, read from the visible viewport between presses, that the
# first interrupt press landed on a RUNNING turn; empty when the adapter sends
# its presses blind. Devin needs it because the same fast double Escape that
# cancels a running turn opens its /revert "Revert to step" picker on an idle
# agent, where a later Enter reverts file changes. One Escape on a running turn
# renders `esc again to interrupt` for about three seconds, while an idle agent
# renders nothing, so the second press is sent only after that proof and never
# sooner than fm_control_interrupt_press_gap: an unproven arm sends nothing
# more. Verified live on devin 3000.11.1: an idle pair opened the picker at a
# 0.05-0.1 s gap and did not at 0.15 s or more, and a running turn cancelled
# with a 0.6 s gap.
fm_control_interrupt_arm_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'esc again to interrupt' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode|droid) ;;
    *) return 1 ;;
  esac
}

# The minimum seconds between two presses of an armed interrupt: several times
# Devin's observed idle double-tap window, well inside its three-second armed
# window. A turn that ends between the presses therefore cannot pair them.
# Command Code sends one press, so its gap is only the settle before the hazard
# read below: long enough for a rewind picker a stray earlier Escape paired with
# this press to render (its idle double-tap opened the picker at a 0.3 s gap and
# did not at 0.6 s, Command Code 1.74.1).
fm_control_interrupt_press_gap() {  # <harness>
  case "${1-}" in
    devin|commandcode) printf '0.5' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|droid) printf '0.2' ;;
    *) return 1 ;;
  esac
}

# A rendered surface that a mistimed interrupt press can open and that must be
# dismissed with one more interrupt key before anything else is typed; empty
# when the adapter has none. Devin's revert picker is recognized by either of
# two independent rows, its `Revert to step:` title or its `↵ revert` footer,
# and Escape cancels it without reverting (verified live, devin 3000.11.1).
# Command Code opens its Rewind checkpoint picker on two Escapes within about
# half a second on an idle agent, where Enter restores a checkpoint; it is
# recognized by its `Select a checkpoint to restore your session` subtitle or its
# `Press Enter to select · Esc to cancel` footer, and one Escape closes it
# without restoring (verified live, Command Code 1.74.1).
fm_control_interrupt_hazard_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'Revert to step:|↵ revert' ;;
    commandcode) printf '%s' 'Select a checkpoint to restore your session|Press Enter to select · Esc to cancel' ;;
    # polytoken's interrupt rides the REST API, never keys, so no key can open
    # a hazard surface on its path; the /quit exit opens only the slash palette,
    # where Enter accepts the preselected /quit row (verified live).
    polytoken) ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|droid) ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse|droid) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin|commandcode) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    # rovo's TUI prints "Agent cancelled" on Escape, but for parity with
    # claude/cursor this stays 'none': the ack is a rendered string, not a
    # recorded state source, and rovo has no busy wiring to confirm against.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin|commandcode|droid) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse|rovo|droid) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini|agy|devin|commandcode|polytoken) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The launch argument that makes a RELAUNCH of <harness> RESUME an exact agent
# session instead of starting a fresh one, printed only when <registered-agent>
# is the label that session reference belongs to; nothing otherwise.
#
# This exists for one runtime failure, not as a general resume feature. Herdr
# gives a pane one status authority, and for Pi with its installed integration
# that authority is the lifecycle hooks, which also suppress Herdr's screen
# detection for the pane. That registration outlives its agent process in the
# crew shape - a nested worktree shell under the pane's top shell - and Herdr
# then applies only reports carrying the session identity it bound. A
# replacement agent started fresh in that same pane reports a NEW session, so
# its state reports are ignored and the pane stays frozen at whatever the
# previous agent last reported: a working crewmate reads idle until its task
# ends (reproduced and fixed live 2026-09-21, herdr 0.9.1; the read that
# supplies the reference is
# bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref).
#
# So the reference is not chosen from what looks recent - it is the exact
# identity the endpoint's own runtime recorded, which is why a matched
# registered-agent label is required: resuming a reference reported by a
# DIFFERENT agent would inject another agent's conversation into this launch.
# `pi` is the label Pi and pi-signed both report, so one entry covers both.
# Every other harness returns nothing and keeps today's fresh-session
# relaunch, which is what the adapter tables above (and the absence of a
# verified resume form for those harnesses) require.
#
# Prints the flag name only; the caller quotes and appends the reference, since
# shell quoting belongs to the owner of the launch line (bin/fm-spawn.sh).
fm_control_relaunch_resume_flag() {  # <harness> <registered-agent>
  case "${1-}" in
    pi|pi-signed)
      [ "${2-}" = pi ] && printf -- '--session'
      ;;
  esac
  return 0
}

# Which named keys a backend adapter can deliver. Orca accepts raw
# Escape and Ctrl+U bytes, verified against Droid; keep that capability scoped
# to Droid until another harness's response is proven live.
fm_control_backend_supports_key() {  # <backend> <key> [harness]
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux|paseo)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in
        Enter|C-c) return 0 ;;
        Escape|C-u) [ "${3:-}" = droid ] && return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier that
# fm_control_agent_state can read. tmux, herdr, and orca do; zellij, cmux, and
# paseo report `unverified`, so no reading of theirs can prove an agent
# stopped. The control plane refuses a stop-proving verb there instead of
# reporting an unprovable transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr|orca) return 0 ;;
  esac
  return 1
}

# fm_control_agent_state: the control plane's agent-state read for <target>, in
# bin/fm-backend.sh's fm_backend_agent_state vocabulary. Every backend but orca
# is exactly fm_backend_agent_state. Orca's classifier
# (bin/backends/orca.sh's fm_backend_orca_agent_state) is read only here, so
# fm-control and fm-spawn --relaunch can prove an Orca agent stopped while every
# other fm_backend_agent_state caller - monitoring, cleanup, the fleet view -
# keeps reading Orca as `unverified` exactly as before.
fm_control_agent_state() {  # <backend> <target>
  local backend=${1-} target=${2-}
  case "$backend" in
    orca)
      fm_backend_source orca || { printf 'unreadable'; return 0; }
      fm_backend_orca_agent_state "$target"
      ;;
    *)
      fm_backend_agent_state "$backend" "$target"
      ;;
  esac
}

# fm_control_endpoint_absence_verdict: the ONE owner of the per-backend proof
# that an endpoint reading `missing` is actually GONE rather than merely
# unreachable from this seat. Call it only for a `missing` raw state.
#
# Prints "<verdict>\t<reason>" - always exactly one TAB, so a caller splits
# unambiguously with ${raw%%$'\t'*} and ${raw#*$'\t'}. The reason is empty
# except on `unproven`, where it is the concrete sentence the caller's refusal
# message embeds. It is returned on stdout rather than set in a variable
# because every caller reads this through a command substitution, where an
# assignment made here could never reach them.
#
# The verdicts:
#   gone     - absence is PROVEN. There is no endpoint and therefore no agent.
#   dead     - the endpoint is there after all and holds no agent.
#   alive    - the endpoint is there and an agent is running in it.
#   unproven - neither could be established; the caller must refuse.
#
# fm_backend_agent_state's `missing` conflates "the endpoint was DESTROYED"
# with "the endpoint is UNREACHABLE from here right now". An unreachable
# endpoint can still hold a live agent on the task's worktree, so every caller
# that would act on absence - `exit` claiming the agent stopped, `relaunch`
# re-creating the endpoint - must come through here rather than trusting the
# raw verdict.
#
# Whether absence is provable AT ALL is a property of the backend, not of the
# reading:
#   herdr CAN prove it. Every read goes through fm_backend_herdr_cli, which
#     passes `--session <session>`, so the recheck starts and reads the session
#     the RECORD names, through that session's own socket. The answer is about
#     the task's endpoint and nothing else.
#   tmux can only from its record. `list-windows -a` describes only the server
#     the CURRENT process addresses, so a different but running server would
#     answer "not anywhere" about a window it was never able to see. A tmux
#     spawn therefore records the server it created the window on (socket,
#     server pid and identity, window id), and fm_control_tmux_absence_verdict
#     reads exactly that server; a record without those fields stays
#     `unproven` and both verbs refuse.
#   orca CAN prove it, but only with the task's recorded worktree passed as
#     the third argument. Orca keeps describing a closed terminal and records
#     why it exited, so a closed terminal is told apart from one this seat
#     cannot reach. Closing the terminal is still not proof that its agent
#     died with it, so the proof also requires Orca's process sweep to have
#     dropped the session and no agent process to be working in the recorded
#     worktree (bin/backends/orca.sh's
#     fm_backend_orca_endpoint_absence_proof owns the reads;
#     docs/orca-backend.md "Agent stop proof" owns the evidence).
#
# Both control-plane callers share this one implementation so the proof cannot
# drift into two answers for the same endpoint. The third argument is the
# backend's own record: tmux task meta for tmux, the recorded worktree for
# orca; each caller passes the value its backend needs.
fm_control_endpoint_absence_verdict() {  # <backend> <target> [<meta-or-worktree>]
  local backend=${1-} target=${2-} meta=${3-}
  fm_backend_source "$backend" \
    || { printf 'unproven\tbackend %s could not be loaded to prove anything about that endpoint' "'$backend'"; return 0; }
  case "$backend" in
    tmux)
      fm_control_tmux_absence_verdict "$target" "$meta"
      ;;
    herdr)
      # Start the RECORDED session's server (only the server - nothing is
      # created) and re-read the recorded pane. A pane that comes back with the
      # server was never destroyed.
      case "$(fm_backend_herdr_endpoint_absence_recheck "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe recorded herdr session'"'"'s server could not be started, or its pane could not be classified once it was running' ;;
      esac
      ;;
    orca)
      fm_backend_orca_endpoint_absence_proof "$target" "$meta"
      ;;
    *)
      printf 'unproven\tbackend %s has no recovery-grade classifier, so absence cannot be proven on it at all' "'$backend'"
      ;;
  esac
}

# fm_control_pids_with_cwd_under <dir>: pids of every process whose CURRENT WORKING
# DIRECTORY is exactly $1 or under it, from one bounded system-wide `lsof -a
# -d cwd` scan (never the recursive +D file-tree walk, which lsof itself
# documents as slow). Never $$ (this script's own pid). Empty output when
# nothing matches; failure means the scan could not establish a safe result.
fm_control_pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# Each read writes to a file, never a pipe: a tmux client hands its output
# descriptor to the server, so a stopped server would hold a captured pipe open
# long after the bound stopped the client.
_fm_control_tmux_read() {  # <socket> <out-file> <tmux-args...>
  local sock=$1 file=$2
  shift 2
  fm_run_timed 5 env -u TMUX -u TMUX_PANE tmux -S "$sock" "$@" > "$file" 2>&1
}

# fm_control_tmux_absence_verdict <target> <meta>: the tmux half of the absence
# proof, from the server identity a tmux spawn records (tmux_socket,
# tmux_server_pid, tmux_server_identity, tmux_window_id). Read-only: every read
# addresses the recorded socket explicitly with the ambient pane identity
# removed, is bounded, and never starts, kills or attaches to a server.
#   - The recorded server is gone only when its pid no longer answers to the
#     recorded identity AND the socket answers "no server" (or refuses, or is
#     missing), or answers with another server's pid. A recorded server still
#     alive while its socket does not answer is unproven.
#   - On the same live server, the recorded window id must be gone (under any
#     name) and no pane of that server may sit in the copy.
#   - Either way, no other same-user process may have its working directory in
#     the copy (the scanner and the firstmate control scripts above it aside).
fm_control_tmux_absence_verdict() {  # <target> <meta>
  local meta=$2 lib sock spid sident wid wt out rc recorded_alive=0 wtc path pathc p holders anc self_chain comm rf scan_budget
  lib=${BASH_SOURCE[0]}
  # shellcheck source=bin/fm-timeout-lib.sh
  command -v fm_run_timed >/dev/null 2>&1 || . "${lib%/*}/fm-timeout-lib.sh"
  # Undirected, like fm-task-inbox-lib.sh's: directing it would re-expand the
  # wake library's whole graph at this site under external-source traversal.
  # shellcheck source=/dev/null
  command -v fm_pid_identity >/dev/null 2>&1 || . "${lib%/*}/fm-wake-lib.sh"
  sock=$(fm_meta_get "$meta" tmux_socket)
  spid=$(fm_meta_get "$meta" tmux_server_pid)
  sident=$(fm_meta_get "$meta" tmux_server_identity)
  wid=$(fm_meta_get "$meta" tmux_window_id)
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$sock" ] || [ -z "$spid" ] || [ -z "$sident" ] || [ -z "$wid" ] || [ -z "$wt" ]; then
    printf 'unproven\ttmux absence cannot be proven from a task record: the record does not carry the endpoint'"'"'s socket identity, and a server-wide window inventory only describes the tmux server this process addresses, so a window absent from it may still be alive on another'
    return 0
  fi
  if fm_pid_alive "$spid"; then
    out=$(fm_pid_identity "$spid" 2>/dev/null) || out=
    if [ -z "$out" ]; then
      printf 'unproven\tthe recorded tmux server pid %s is alive but its identity could not be read' "$spid"
      return 0
    fi
    [ "$(printf '%s' "$out" | tr '\t\n' '  ')" != "$sident" ] || recorded_alive=1
  fi
  rf=$(mktemp "${TMPDIR:-/tmp}/fm-tmux-proof.XXXXXX") || { printf 'unproven\ta scratch file for the tmux reads could not be made'; return 0; }
  _fm_control_tmux_read "$sock" "$rf" display-message -p '#{pid}'
  rc=$?
  out=$(cat "$rf" 2>/dev/null)
  rm -f "$rf"
  if [ "$rc" -eq 0 ]; then
    case "$out" in '' | *[!0-9]*) printf 'unproven\tthe tmux server on %s answered with something other than its pid' "$sock"; return 0 ;; esac
    if [ "$out" = "$spid" ] && [ "$recorded_alive" -eq 1 ]; then
      _fm_control_tmux_read "$sock" "$rf" list-windows -a -F '#{window_id}' \
        || { rm -f "$rf"; printf 'unproven\tthe recorded tmux server on %s could not list its windows' "$sock"; return 0; }
      out=$(cat "$rf" 2>/dev/null)
      rm -f "$rf"
      if printf '%s\n' "$out" | grep -Fqx -- "$wid"; then
        printf 'unproven\tthe recorded tmux server on %s still has the task'"'"'s window %s, under whatever name' "$sock" "$wid"
        return 0
      fi
      _fm_control_tmux_read "$sock" "$rf" list-panes -a -F '#{pane_current_path}' \
        || { rm -f "$rf"; printf 'unproven\tthe recorded tmux server on %s could not list its panes' "$sock"; return 0; }
      out=$(cat "$rf" 2>/dev/null)
      rm -f "$rf"
      wtc=$(cd "$wt" 2>/dev/null && pwd -P) || wtc=$wt
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        pathc=$(cd "$path" 2>/dev/null && pwd -P) || pathc=$path
        case "$pathc" in
          "$wtc" | "$wtc"/*) printf 'unproven\ta pane of the recorded tmux server on %s is inside the task'"'"'s copy' "$sock"; return 0 ;;
        esac
      done <<EOF
$out
EOF
    elif [ "$recorded_alive" -eq 1 ]; then
      printf 'unproven\tthe recorded tmux server pid %s is still alive while another server answers on %s' "$spid" "$sock"
      return 0
    fi
  elif fm_timed_out "$rc"; then
    printf 'unproven\tthe tmux server on %s did not answer within its bound' "$sock"
    return 0
  else
    case "$out" in
      *"no server running"* | *"No such file or directory"* | *"Connection refused"*) ;;
      *) printf 'unproven\tthe tmux server on %s could not be read: %s' "$sock" "$out"; return 0 ;;
    esac
    if [ "$recorded_alive" -eq 1 ]; then
      printf 'unproven\tthe recorded tmux server pid %s is still alive but its socket %s does not answer' "$spid" "$sock"
      return 0
    fi
  fi
  # The scan runs from / so its own processes are never holders.
  scan_budget=${FM_CONTROL_CWD_SCAN_BUDGET:-20}
  case "$scan_budget" in '' | *[!0-9]* | 0) scan_budget=20 ;; esac
  # shellcheck disable=SC2016 # expanded by the child shell
  holders=$(cd / && fm_run_timed "$scan_budget" bash -c '. "${1%/*}/fm-bash-compat-lib.sh"; . "$1"; fm_control_pids_with_cwd_under "$2"' _ \
    "$lib" "$wt" 2>/dev/null) \
    || { printf 'unproven\tthe working-directory scan of the task'"'"'s copy could not finish'; return 0; }
  # The firstmate control scripts running this proof may sit in the copy.
  self_chain=
  anc=$(exec sh -c 'echo "$PPID"')
  while [ -n "$anc" ] && [ "$anc" -gt 1 ] 2>/dev/null; do
    case " $(ps -o args= -p "$anc" 2>/dev/null | awk '{ for (i = 1; i <= 2 && i <= NF; i++) { n = $i; sub(/.*\//, "", n); printf "%s ", n } }')" in
      *" fm-control.sh "* | *" fm-spawn.sh "*) self_chain="$self_chain $anc " ;;
    esac
    anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
  done
  for p in $holders; do
    case "$self_chain" in *" $p "*) continue ;; esac
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    printf 'unproven\tprocess %s (%s) has its working directory inside the task'"'"'s copy; stop that process, then retry' "$p" "${comm##*/}"
    return 0
  done
  printf 'gone\t'
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Teardown's worktree return also reads this
# table for Polytoken; both consumers preserve git-tracked Polytoken layers.
# Prints zero or more absolute paths, one per line: worktree-resident
# hook files and firstmate-owned state tokens only, never a harness's own
# managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id> [kind]
  local harness=${1-} wt=${2-} state=${3-} id=${4-} kind=${5-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    # A secondmate's .claude/settings.local.json belongs to the captain.
    # Retire only the firstmate-owned settings file the launch passes to
    # --settings and the Stop pointer that carries the same busy generation.
    # A crewmate's hook file is the worktree settings.local.json.
    claude)
      if [ "$kind" = secondmate ]; then
        printf '%s\n' "$state/$id.claude-settings.json"
        printf '%s\n' "$wt/.fm-busy-stop"
      else
        printf '%s\n' "$wt/.claude/settings.local.json"
      fi
      ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
    devin) printf '%s\n' "$state/$id.devin-config.json" ;;
    droid) printf '%s\n' "$state/$id.droid-settings.json" "$state/$id.droid-session-end" ;;
    # commandcode leaves none: its tracked mod (bin/fm-commandcode-mod.ts) takes
    # the generation from its own launch command, so the retired process
    # takes its wiring with it.
    # polytoken's per-task wiring spans the worktree's project hook and facet
    # layers (the only hook and facet discovery a task controls, so a relaunch
    # must retire them rather than leave a stale hook pointing at a retired
    # busy generation), the generated no-argv busy writer the hooks reference,
    # and the per-task config and sessions roots, which are DIRECTORIES and
    # therefore ride fm_control_harness_wiring_dirs below rather than this
    # file table. The worktree layers are the project's own discovery paths,
    # so each is named only while it carries this task's generated content
    # (the hooks reference this task's busy writer, the facet this task's
    # inbox); a project's own hook layer or facet is never firstmate's to
    # retire.
    polytoken)
      if grep -qsF "/$id.polytoken-busy.sh" "$wt/.polytoken/hooks.json"; then
        printf '%s\n' "$wt/.polytoken/hooks.json"
      fi
      if grep -qsF "/$id.inbox" "$wt/.polytoken/facets/firstmate-worker.md"; then
        printf '%s\n' "$wt/.polytoken/facets/firstmate-worker.md"
      fi
      printf '%s\n' "$state/$id.polytoken-busy.sh"
      ;;
  esac
}

# The firstmate-owned per-task DIRECTORIES a harness mints, one per line:
# the same retirement contract as fm_control_harness_wiring_paths for
# artifacts that are directory trees rather than single files. Consumers
# remove these recursively; nothing here is ever a harness's own managed
# config. polytoken's config dir holds the mirrored worker config (the
# one launch-time autonomy surface, so a replacement must regenerate it
# from the current operator config), and the sessions root holds the
# versioned `<root>-v1` session tree the launch writes beside it, so both
# the root and its versioned sibling are named.
fm_control_harness_wiring_dirs() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    polytoken)
      printf '%s\n' "$state/$id.polytoken-config"
      printf '%s\n' "$state/$id.polytoken-sessions"
      printf '%s\n' "$state/$id.polytoken-sessions-v1"
      ;;
  esac
}

# Droid's SessionEnd hook writes the armed busy generation when the current
# generation closes a session with reason "other". Droid also closes sessions
# that way without exiting (after /clear, on a session reload, or for a Task
# subagent), so the marker is only a session-close signal. It is the shared
# stop proof used by Orca control and replacement spawn only together with an
# lsof scan showing no droid process whose working directory is inside the
# task worktree. A marker from a prior incarnation, a missing worktree, a
# missing lsof, or an lsof error all fail closed.
fm_control_droid_session_ended() {  # <state-dir> <id> <meta-file>
  local state=$1 id=$2 meta=$3 gen ended path wt out status line
  gen=$(fm_meta_get "$meta" busy_gen)
  [ -n "$gen" ] || return 1
  path="$state/$id.droid-session-end"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r ended <"$path" 2>/dev/null || ended=
  [ "$ended" = "$gen" ] || return 1
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && wt=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  out=$(lsof -w -a -c droid -d cwd -Fn 2>&1) && status=0 || status=$?
  case "$status" in
    0) ;;
    1) [ -z "$out" ]; return ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    case "$line" in "n$wt"|"n$wt"/*) return 1 ;; esac
  done <<EOF
$out
EOF
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
