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
  printf '%s\n' claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin commandcode polytoken cortex droid kiro hermes
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
# `commandcode` are exact as well, `kiro` is exact because a `kiro*` prefix has no verified variant to admit, and an unrecognized value returns nonzero rather than being guessed into a family.
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
    cortex) printf 'cortex' ;;
    hermes) printf 'hermes' ;;
    kiro) printf 'kiro' ;;
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

# Which task kinds an adapter is verified to run. muse, gemini, rovo, devin,
# commandcode, polytoken, cortex, and kiro are crewmate/scout adapters only: none has a primary
# supervision protocol, and bin/fm-spawn.sh refuses a --secondmate launch on any of them. The control
# plane asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    hermes) case "$kind" in ship|scout) ;; *) return 1 ;; esac ;;
    muse|gemini|rovo|devin|commandcode|polytoken|cortex|droid|kiro) [ "$kind" != secondmate ] || return 1 ;;
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
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|devin|droid|commandcode|hermes) printf 'key' ;;
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
# through Herdr). kiro cancels on a single Escape, printing a `Cancelled ...`
# row with an idle composer and no repollution (verified live, kiro-cli 2.21.4).
# cortex cancels on a single Escape, printing the Interrupted row
# with an idle composer and firing its Stop hook; an Escape pressed on an idle
# composer does nothing (verified live, cortex 1.1.104).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo|agy|devin|commandcode|cortex|droid|kiro|hermes) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode, Devin and Hermes
# need a double Escape; every other verified adapter interrupts on a single press. Command Code
# cancels a running turn on one Escape (verified live, Command Code 1.74.1), and a
# second press is exactly what opens its rewind picker, so it gets one.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode|devin|hermes) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode|cortex|droid|kiro) printf '1' ;;
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
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|commandcode|cortex|droid|kiro|hermes) ;;
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
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|cortex|droid|kiro|hermes) printf '0.2' ;;
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
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy|cortex|droid|kiro|hermes) ;;
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
# or @path/to/file` placeholder. kiro was checked the same way and also does not
# repollute: after a single Escape it prints a `Cancelled ...` row and its
# composer shows only the `ask a question or describe a task` placeholder
# (verified, kiro-cli 2.21.4). Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse|droid) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin|commandcode|cortex|kiro|hermes) ;;
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
    # kiro's stop hook fires on normal completion but, like claude's, not on a
    # manual Escape, and its `Cancelled ...` row is likewise rendered rather than
    # recorded, so fm-control preserves the adapter-owned busy record instead.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin|commandcode|cortex|droid|kiro|hermes) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command or key that exits the agent from its own composer. OpenCode is
# version-sensitive: 2.x exits on raw keys, where bin/fm-control.sh sends Ctrl-U
# to clear the composer, then Ctrl-C, and one more Ctrl-C if the agent is still
# alive (verified on 2.0.11, 2.0.21, and 2.0.22), while 1.x exits on the typed
# /exit command. The detected major is recorded at spawn (bin/fm-spawn.sh) and
# passed as $2; when it is absent or 1 the version-agnostic /exit is used, which
# exits both lines.
fm_control_exit_command() {  # <harness> [opencode-major]
  case "${1-}" in
    opencode)
      case "${2-}" in
        ''|1) printf '/exit' ;;
        *) printf 'C-c' ;;
      esac
      ;;
    claude|grok|kimi|cursor|muse|rovo|droid) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini|agy|devin|commandcode|polytoken|cortex|kiro|hermes) printf '/quit' ;;
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

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear. Orca accepts raw
# Escape and Ctrl+U bytes, verified against Droid; keep that capability scoped
# to Droid until another harness's response is proven live. T3 has no composer
# to clear, so Ctrl+U has nothing to do there; Escape and Ctrl+C are both a
# turn interrupt (bin/backends/t3code.sh's fm_backend_t3code_send_key).
fm_control_backend_supports_key() {  # <backend> <key> [harness]
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux|paseo|rex|tern|hc)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in
        Enter|C-c) return 0 ;;
        Escape|C-u) [ "${3:-}" = droid ] && return 0 ;;
      esac
      ;;
    t3code)
      case "$key" in Escape|Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier that
# fm_control_agent_state can read. tmux, herdr, orca, rex, and t3code do;
# zellij, cmux, and paseo report `unverified`, and tern's `tern process`
# classifier answers for display but is not promoted to this list, so no
# reading of theirs can prove an agent stopped. The control plane refuses a
# stop-proving verb there instead of reporting an unprovable transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr|orca|rex|t3code) return 0 ;;
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

# Whether <backend> can stop an agent for `exit`. T3 Code cannot: it has no
# composer for the harness exit command, and its Orchestrator V2 `/mcp` tools
# offer no session stop, only a turn interrupt that leaves the thread idle and
# alive, so no stop could be proven and `exit` refuses before anything is
# sent (docs/t3code-backend.md "Active limits").
fm_control_backend_exit_supported() {  # <backend>
  case "${1-}" in
    t3code) return 1 ;;
  esac
  return 0
}

# Whether <backend> can launch a REPLACEMENT agent into an existing task's
# endpoint. A T3 thread keeps its conversation: a new turn continues the same
# agent with its transcript, and a provider or model change through
# t3_thread_configure is a context handoff on the same thread (T3 main; older
# nightlies refused a driver change outright), never the fresh agent a
# relaunch promises. So t3code has no replacement to launch and a relaunch
# is refused before anything is stopped (docs/t3code-backend.md "Active
# limits"). zellij, cmux, and paseo never reach this table: they fail
# fm_control_backend_state_verified first.
fm_control_backend_relaunch_supported() {  # <backend>
  case "${1-}" in
    tmux|herdr|orca|rex) return 0 ;;
  esac
  return 1
}

# Whether a relaunch can RECLAIM a task whose endpoint reads `missing`, by
# re-creating one in its worktree once fm_control_endpoint_absence_verdict
# proves the old one gone. That proof exists on herdr, rex, and orca, and on
# tmux only for a record carrying the server identity the tmux proof reads;
# a yes here is admission to try, and relaunch still refuses an unproven
# absence.
fm_control_backend_reclaim_supported() {  # <backend> <meta>
  local field
  case "${1-}" in
    herdr|rex|orca) return 0 ;;
    tmux)
      for field in tmux_socket tmux_server_pid tmux_server_identity tmux_window_id; do
        [ -n "$(fm_meta_get "${2-}" "$field" 2>/dev/null || true)" ] || return 1
      done
      return 0
      ;;
  esac
  return 1
}

# Whether a raw fm_backend_agent_state reading on <backend> goes through
# fm_control_endpoint_absence_verdict before a recovery verb (exit, relaunch)
# acts or refuses. `missing` always does. A Rex `unreadable` does too: Rex's
# passive reads never start a server, so a stopped server - which ends every
# session on it - reads as unreachable rather than not-found, and only the
# recheck (which may start the personal server) can turn that into a proof.
# Passive readers keep the raw state.
fm_control_absence_recheck_applies() {  # <backend> <raw-state>
  case "${2-}" in
    missing) return 0 ;;
    unreadable) [ "${1-}" = rex ] || [ "${1-}" = orca ] ;;
    *) return 1 ;;
  esac
}

# fm_control_endpoint_absence_verdict: the ONE owner of the per-backend proof
# that an endpoint reading `missing` is actually GONE rather than merely
# unreachable from this seat. Call it only for a raw state that
# fm_control_absence_recheck_applies accepts (Orca's `unreadable` follows
# docs/orca-backend.md "Agent stop proof").
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
#   rex CAN prove it. Rex never reuses an id, a session never survives its
#     server, and a missing target is a structured not-found (exit 3) distinct
#     from an unreachable server (exit 4). So a not-found from the server the
#     task was CREATED on proves the block gone. The record names that server
#     (rex_server, from the task's [meta]); the recheck refuses unless the
#     server this process reaches - starting a stopped personal server, which
#     then answers with authority - is that one.
#   t3code has a native absence verdict: `missing` means archived or not found
#     on the verified server, while an unreachable server reads `unreadable`.
#     The proof re-reads the thread, but exit and relaunch refuse before it:
#     V2 has no session stop and a thread cannot host a replacement.
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
#     A terminal Orca still calls connected is proven gone only when the
#     session root its sweep names is absent from the process table, under
#     the same worktree standards.
#     A handle Orca no longer recognizes at all is proven gone only through
#     that same function's reboot case, which additionally needs the task's
#     record file as the fourth argument here. The same documentation owner
#     describes that case's evidence requirements.
#
# Both control-plane callers share this one implementation so the proof cannot
# drift into two answers for the same endpoint. The third argument is the
# backend's own record: tmux task meta for tmux, the recorded worktree for
# orca; each caller passes the value its backend needs.
fm_control_endpoint_absence_verdict() {  # <backend> <target> [<meta-or-worktree>] [<meta>]
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
      fm_backend_orca_endpoint_absence_proof "$target" "$meta" "${4-}"
      ;;
    rex)
      case "$(fm_backend_rex_endpoint_absence_recheck "$target" "$(fm_meta_get "$meta" rex_server)")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe Rex server the task was created on could not be reached from here, or its block could not be classified' ;;
      esac
      ;;
    t3code)
      # A T3 `missing` is the server's own answer (an archived thread or an
      # HTTP 404), never a reachability guess: an unreachable server reads
      # `unreadable` instead. Re-read the thread so the verdict is current.
      case "$(fm_backend_t3code_agent_state "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe T3 server could not be reached to re-read thread %s' "$target" ;;
      esac
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
    # Hermes reaches its private native managed overlay through launch env.
    hermes) printf '%s\n' "$state/$id.hermes-hooks/config.yaml" ;;
    # cortex's lifecycle hooks live in a firstmate-owned plugin directory the
    # launch reaches through --plugin-dir. Only its two files are retired here
    # (this table's consumer removes files); teardown removes the directory.
    cortex)
      printf '%s\n' "$state/$id.cortex-plugin/hooks/hooks.json"
      printf '%s\n' "$state/$id.cortex-plugin/.cortex-plugin/plugin.json"
      ;;
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
    # kiro's busy-state and turn-end hooks live in a firstmate-owned per-task
    # agent config the launch reaches through a relocated KIRO_HOME, at
    # <state>/<id>.kiro-home/agents/firstmate.json, whose two hook commands are
    # generated scripts beside it under hooks/. All three carry the incarnation's
    # gen, so all three are retired; the sibling settings/sessions carry no gen
    # and are cleared wholesale by teardown's rm -rf of <id>.kiro-home. Nothing
    # is written into the worktree, whose own .kiro/ belongs to the project, and
    # nothing in the captain's real ~/.kiro is touched.
    kiro)
      printf '%s\n' "$state/$id.kiro-home/agents/firstmate.json"
      printf '%s\n' "$state/$id.kiro-home/hooks/user-prompt-submit"
      printf '%s\n' "$state/$id.kiro-home/hooks/stop"
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

# fm_control_droid_worktree_no_droid: one successful bounded `lsof` scan
# showing no `droid` process whose working directory is <worktree> (already
# physical) or under it. A missing `lsof`, a nonzero status other than the
# empty-result status 1, a status-1 scan that still printed rows, or a
# malformed or partial row all fail closed: none of them is a clean scan.
fm_control_droid_worktree_no_droid() {  # <physical-worktree>
  local wt=$1 out status line path
  [ -n "$wt" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  out=$(lsof -w -a -c droid -d cwd -Fn 2>&1) && status=0 || status=$?
  case "$status" in
    0) ;;
    1) [ -z "$out" ] || return 1; return 0 ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      p*|f*) ;;
      n*)
        path=${line#n}
        [ -n "$path" ] || return 1
        case "$path" in "$wt"|"$wt"/*) return 1 ;; esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
  return 0
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
  local state=$1 id=$2 meta=$3 gen ended path wt
  gen=$(fm_meta_get "$meta" busy_gen)
  [ -n "$gen" ] || return 1
  path="$state/$id.droid-session-end"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r ended <"$path" 2>/dev/null || ended=
  [ "$ended" = "$gen" ] || return 1
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && wt=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  fm_control_droid_worktree_no_droid "$wt"
}

# fm_control_droid_agent_absent: the ONE shared Orca Droid absence proof for
# fm-control and fm-spawn --relaunch, so the two enforcement points can never
# drift. It succeeds by exactly one of two routes, and every element of the
# route taken is required on its own:
#   1. Marker route: the current-generation SessionEnd marker above, with
#      its clean worktree scan (fm_control_droid_session_ended).
#   2. Connected-shell route, only when no marker file exists at all: the
#      recorded endpoint is affirmatively read as a connected, local Orca
#      terminal that belongs to the exact recorded worktree and to this
#      task's recorded terminal, its recorded session process tree
#      classifies `dead` (only shells beside Orca's `login` root, which is
#      the owned idle shell), the task's busy record is the current
#      generation's idle `droid-hook` record, and one successful scan shows
#      no `droid` process whose working directory is the exact recorded
#      worktree or under it.
# A connected terminal whose session root has exited is not this proof's
# case: fm_control_droid_connected_gone below owns it.
# A marker file that exists but names another generation, is a symlink, or
# cannot be read refuses on both routes rather than falling through to the
# shell route: it is evidence about a different incarnation. A live Droid
# in the worktree, an ambiguous or unreadable endpoint, a terminal whose
# worktree differs from the record, a failed or partial scan, and a process
# that survived a session-only close (marker route scan, live tree, or the
# worktree scan) all refuse. Nothing here synthesizes a marker or rewrites
# metadata, and the endpoint-gone proof
# (fm_control_endpoint_absence_verdict) is untouched.
fm_control_droid_agent_absent() {  # <state-dir> <id> <meta-file> <target>
  local state=${1-} id=${2-} meta=${3-} target=${4-}
  local gen marker ended wt recorded harness current record facts
  local f_read f_connected f_host f_pty f_wtpath pid tree wt_phys term_phys
  [ -n "$state" ] && [ -n "$id" ] && [ -n "$meta" ] && [ -n "$target" ] || return 1
  harness=$(fm_meta_get "$meta" harness) || return 1
  [ -n "$harness" ] || return 1
  harness=$(fm_control_harness_family "$harness") || return 1
  [ "$harness" = droid ] || return 1
  case "$(fm_meta_get "$meta" backend)" in ''|orca) ;; *) return 1 ;; esac
  gen=$(fm_meta_get "$meta" busy_gen)
  [ -n "$gen" ] || return 1
  marker="$state/$id.droid-session-end"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    IFS= read -r ended <"$marker" 2>/dev/null || ended=
    [ "$ended" = "$gen" ] || return 1
    fm_control_droid_session_ended "$state" "$id" "$meta"
    return $?
  fi
  # Connected-shell route: no marker file exists.
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && wt_phys=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  [ -n "$wt_phys" ] || return 1
  recorded=$(fm_meta_get "$meta" terminal)
  [ -n "$recorded" ] && [ "$recorded" = "$target" ] || return 1
  command -v fm_busy_current_gen >/dev/null 2>&1 || return 1
  command -v fm_busy_record_read >/dev/null 2>&1 || return 1
  current=$(fm_busy_current_gen "$state" "$id" 2>/dev/null) || return 1
  [ "$current" = "$gen" ] || return 1
  record=$(fm_busy_record_read "$state" "$id" 2>/dev/null) || return 1
  case "$record" in
    'idle droid-hook '*) ;;
    *) return 1 ;;
  esac
  fm_backend_source orca >/dev/null 2>&1 || return 1
  command -v fm_backend_orca_terminal_facts >/dev/null 2>&1 || return 1
  command -v fm_backend_orca_session_pid >/dev/null 2>&1 || return 1
  command -v fm_backend_orca_tree_state >/dev/null 2>&1 || return 1
  facts=$(fm_backend_orca_terminal_facts "$target" 2>/dev/null) || return 1
  [ -n "$facts" ] || return 1
  IFS=$'\037' read -r f_read f_connected _ f_host f_pty f_wtpath _ <<FACTS
$facts
FACTS
  [ "$f_read" = ok ] || return 1
  [ "$f_connected" = true ] || return 1
  [ "$f_host" = local ] || return 1
  [ -n "$f_pty" ] || return 1
  [ -n "$f_wtpath" ] || return 1
  if command -v fm_backend_orca_physical_dir >/dev/null 2>&1; then
    term_phys=$(fm_backend_orca_physical_dir "$f_wtpath" 2>/dev/null) || return 1
  else
    term_phys=$(cd "$f_wtpath" 2>/dev/null && pwd -P) || return 1
  fi
  [ "$term_phys" = "$wt_phys" ] || return 1
  pid=$(fm_backend_orca_session_pid "$f_pty" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  tree=$(fm_backend_orca_tree_state "$pid" 2>/dev/null) || return 1
  [ "$tree" = dead ] || return 1
  fm_control_droid_worktree_no_droid "$wt_phys"
}

# fm_control_droid_connected_gone: the ONE shared Orca Droid route for a
# terminal Orca still calls connected while the session root its sweep names
# has exited (fm_backend_orca_agent_state reads it `missing`). That is a Droid
# that died with its terminal, including one that died mid-turn and so never
# recorded an idle stop. It needs no SessionEnd marker and no busy record:
# the general Orca endpoint-absence proof (fm_control_endpoint_absence_verdict)
# must read `gone` for the exact recorded worktree, and one successful Droid
# scan must show no `droid` process working in it. A closed terminal never
# takes this route, so it keeps its SessionEnd marker requirement.
# Returns 0 and prints `gone<TAB>` when proven; 1 with no output when the
# terminal is not a connected one whose session root exited (the caller keeps
# its other routes); 2 and prints `unproven<TAB><reason>` when it is, but the
# proof does not settle it (the caller refuses).
fm_control_droid_connected_gone() {  # <target> <worktree> <meta-file>
  local target=${1-} wt=${2-} meta=${3-} facts f_read f_connected verdict wt_phys
  [ -n "$target" ] && [ -n "$wt" ] && [ -n "$meta" ] || return 1
  fm_backend_source orca >/dev/null 2>&1 || return 1
  facts=$(fm_backend_orca_terminal_facts "$target" 2>/dev/null) || return 1
  IFS=$'\037' read -r f_read f_connected _ <<FACTS
$facts
FACTS
  [ "$f_read" = ok ] && [ "$f_connected" = true ] || return 1
  [ "$(fm_backend_orca_agent_state "$target")" = missing ] || return 1
  verdict=$(fm_control_endpoint_absence_verdict orca "$target" "$wt" "$meta")
  if [ "${verdict%%$'\t'*}" != gone ]; then
    printf '%s' "$verdict"
    return 2
  fi
  wt_phys=$(cd "$wt" 2>/dev/null && pwd -P) || wt_phys=
  if [ -z "$wt_phys" ] || ! fm_control_droid_worktree_no_droid "$wt_phys"; then
    printf 'unproven\ta droid process working in %s could not be ruled out' "$wt"
    return 2
  fi
  printf 'gone\t'
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

# fm_control_feedback_dialog_dismiss <harness> <screen>
# Inspects the tail of <screen> for an exact known feedback or bug-report dialog
# signature belonging to <harness> (or any supported feedback-dialog harness
# when <harness> is empty). Prints `<dialog-id>\t<dismiss-key>` and returns 0 on
# match, or returns 1 with no output when no known feedback/bug-report dialog is
# live at the bottom of the screen. The dismiss key is always a skip/dismiss/
# cancel key (`0` or `Escape`), never a submit/send choice (`1`, `2`, `3`, `y`,
# `Enter`) and never feedback text.
fm_control_feedback_dialog_dismiss() {  # <harness> <screen> [mode]
  local harness=${1-} screen=${2-} mode=${3:-id} family='' lib
  [ -n "$screen" ] || return 1
  # Claude draws its empty prompt as `❯`+NBSP; awk regex escapes for that
  # byte pair are locale-dependent, so map Unicode spaces to ASCII first.
  lib=${BASH_SOURCE[0]}
  # shellcheck source=bin/fm-composer-lib.sh
  command -v fm_composer_normalize_spaces_var >/dev/null 2>&1 || . "${lib%/*}/fm-composer-lib.sh"
  fm_composer_normalize_spaces_var screen
  if [ -n "$harness" ]; then
    family=$(fm_control_harness_family "$harness" 2>/dev/null) || return 1
    case "$family" in
      claude|agy|codex) ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$screen" \
    | LC_ALL=C sed -e $'s/\033\\[[0-9;?<>=]*[ -\\/]*[@-~]//g' -e $'s/\033\\][^\a]*\a//g' -e $'s/\r//g' \
    | awk -v fam="$family" -v mode="$mode" '
      function is_border_row(r) {
        return (r ~ /^[ \t]*[│┃─━╭╮╰╯┌┐└┘| \t-]+[ \t]*$/)
      }
      function is_prompt_row(r) {
        return (r ~ /^[ \t]*((│|┃|[|])[ \t]+)?(❯|›|⟩|→|❭|>)[ \t]*((│|┃|[|])[ \t]*)?$/)
      }
      function is_any_prompt_row(r) {
        if (is_prompt_row(r)) return 1
        return (r ~ /^[ \t]*((│|┃|[|])[ \t]+)?(❯|›|⟩|→|❭|>)[ \t]+/)
      }
      function is_chrome_row(r) {
        if (r ~ /^[ \t]*$/) return 1
        if (is_border_row(r)) return 1
        if (is_prompt_row(r)) return 1
        if (r ~ /^[ \t]*(⏵|⏸)/) return 1
        if (r ~ /^[ \t]*(← for agents[ \t]+·[ \t]+)?\? for shortcuts([ \t]|$)/) return 1
        return 0
      }
      # Rows below the input box under the dialog (statusLine, mode hints) are
      # ignored, but a later input box or prompt row (empty or populated) means
      # a newer screen was drawn after it, so the dialog is stale history.
      function no_prompt_after(idx,   k) {
        for (k = idx + 1; k <= m; k++) {
          if (is_any_prompt_row(tail[k]) || is_border_row(tail[k])) return 0
        }
        return 1
      }
      function no_output_after(idx,   j, seen_top_border, seen_prompt) {
        if (idx <= 0) return 0
        seen_top_border = 0
        seen_prompt = 0
        for (j = idx + 1; j <= m; j++) {
          if (seen_prompt) {
            if (is_border_row(tail[j])) {
              if (!no_prompt_after(j)) return 0
              marker_cut = j
              return 1
            }
            if (!seen_top_border) {
              if (!no_prompt_after(j - 1)) return 0
              marker_cut = j - 1
              return 1
            }
            if (!is_chrome_row(tail[j])) return 0
            continue
          }
          if (is_prompt_row(tail[j])) {
            seen_prompt = 1
            continue
          }
          if (is_border_row(tail[j])) {
            if (tail[j] ~ /^[ \t]*[╰└]/) {
              if (!no_prompt_after(j)) return 0
              marker_cut = j
              return 1
            }
            seen_top_border = 1
            continue
          }
          if (!is_chrome_row(tail[j])) return 0
        }
        marker_cut = m
        return 1
      }
      function finish(id, key, footer,   i, row) {
        if (mode == "marker") {
          for (i = 1; i <= marker_cut; i++) {
            row = tail[i]
            if (i >= footer) gsub(/[0-9]/, "", row)
            print row
          }
          exit 0
        }
        print id "\t" key
        exit 0
      }
      NF { rows[++n] = $0 }
      END {
        if (n == 0) exit 1
        s = n - 18 + 1
        if (s < 1) s = 1
        m = 0
        for (i = s; i <= n; i++) tail[++m] = rows[i]

        # 1. Claude known feedback / bug-report dialogs
        if (fam == "" || fam == "claude") {
          h_survey = 0; f_survey = 0
          h_draft = 0; f_draft = 0
          h_modal = 0; b_modal = 0; f_modal = 0
          h_follow = 0; f_follow = 0
          for (i = 1; i <= m; i++) {
            r = tail[i]
            if (r ~ /^[ \t]*((●|•|[*])[ \t]+)?(How is Claude doing( this session)?\?|How was Claude'\''s recollection\?|How well did Claude use its memory\?|How well is Claude following the instructions you gave earlier in this conversation\?|How helpful has [A-Za-z0-9_.-]+ plugin been\?)([ \t]*\(optional\))?[ \t]*$/) h_survey = i
            if (h_survey > 0 && i >= h_survey && r ~ /^[ \t]*1:[ \t]*Bad[ \t]+2:[ \t]*(Fine|Good)[ \t]+3:[ \t]*Good[ \t]+0:[ \t]*Dismiss[ \t]*$/) f_survey = i

            if (r ~ /^[ \t]*((●|•|[*])[ \t]+)?(Bug report|Product feedback|Feature request|Feedback) drafted:[ \t]+[^ \t]/) h_draft = i
            if (h_draft > 0 && i > h_draft && r ~ /^[ \t]*1 to review · 2 to send · 0 to dismiss[ \t]*$/) f_draft = i

            if (r ~ /^[ \t]*(Submit feedback \/ bug report|Report a bug or share your conversation)[ \t]*$/) h_modal = i
            if (h_modal > 0 && i > h_modal && r ~ /(Describe the issue below:|How much session history should we include\?|This report will include:|An archive will be saved to disk containing:|This shared conversation will include:)/) b_modal = i
            if (h_modal > 0 && b_modal > 0 && i >= b_modal && r ~ /^[ \t]*((Enter|Press Enter|Edit and press Enter) to (continue|choose|submit|save|share|retry(, or)?) · (↑\/↓ to navigate · )?)?Esc to cancel[ \t]*$/) f_modal = i

            if (r ~ /^[ \t]*((●|•|[*])[ \t]+)?(What went well\?|What went wrong\?|Tell us more)[ \t]*\(optional\)[ \t]*$/) h_follow = i
            if (h_follow > 0 && i > h_follow && r ~ /^[ \t]*enter to (skip|send) · esc to (skip|clear)[ \t]*$/) f_follow = i
          }
          if (f_survey > 0 && no_output_after(f_survey)) finish("claude-session-feedback", "0", f_survey)
          if (f_draft > 0 && no_output_after(f_draft)) finish("claude-bug-report-draft", "0", f_draft)
          if (f_modal > 0 && no_output_after(f_modal)) finish("claude-bug-report-dialog", "Escape", f_modal)
          if (f_follow > 0 && no_output_after(f_follow)) finish("claude-survey-followup", "Escape", f_follow)
        }

        # 2. Antigravity CLI (agy) known CLI experience survey
        if (fam == "" || fam == "agy") {
          h_agy = 0; f_agy = 0
          for (i = 1; i <= m; i++) {
            r = tail[i]
            if (r ~ /^[ \t]*((│|┃|[|])[ \t]+)?((●|•|[*]|✦)[ \t]+)?How'\''s the CLI experience so far\? Help us improve:[ \t]+\[1\][ \t]*Good[ \t]+\[2\][ \t]*Fine[ \t]+\[3\][ \t]*Bad[ \t]+\[0\][ \t]*Skip([ \t]+(│|┃|[|]))?[ \t]*$/) {
              h_agy = i; f_agy = i
            } else if (r ~ /^[ \t]*((│|┃|[|])[ \t]+)?((●|•|[*]|✦)[ \t]+)?How'\''s the CLI experience so far\? Help us improve:([ \t]+(│|┃|[|]))?[ \t]*$/) {
              h_agy = i
            } else if (h_agy > 0 && i > h_agy && r ~ /^[ \t]*((│|┃|[|])[ \t]+)?\[1\][ \t]*Good[ \t]+\[2\][ \t]*Fine[ \t]+\[3\][ \t]*Bad[ \t]+\[0\][ \t]*Skip([ \t]+(│|┃|[|]))?[ \t]*$/) {
              f_agy = i
            }
          }
          if (f_agy > 0 && no_output_after(f_agy)) finish("agy-cli-feedback", "0", f_agy)
        }

        # 3. Codex CLI known /feedback modal dialogs
        if (fam == "" || fam == "codex") {
          h_cx = 0; b_cx = 0; f_cx = 0
          h_up = 0; b_up = 0; f_up = 0
          for (i = 1; i <= m; i++) {
            r = tail[i]
            if (r ~ /^[ \t]*How was this\?[ \t]*$/) h_cx = i
            if (h_cx > 0 && i > h_cx && r ~ /(Crash, error message, hang, or broken UI\/behavior|Output was off-target, incorrect, incomplete, or unhelpful|Slowness, feature suggestion, UX feedback, or anything else)/) b_cx = i
            if (h_cx > 0 && b_cx > 0 && i > b_cx && r ~ /^[ \t]*(Press enter to confirm or esc to (go back|cancel)|Enter to (select|confirm) · (↑\/↓ to navigate · )?Esc to cancel|enter to (submit|confirm|select) · esc to (cancel|go back))[ \t]*$/) f_cx = i

            if (r ~ /^[ \t]*Upload logs\?[ \t]*$/) h_up = i
            if (h_up > 0 && i > h_up && r ~ /The following files will be sent:/) b_up = i
            if (h_up > 0 && b_up > 0 && i > b_up && r ~ /^[ \t]*((❯|›|>)[ \t]*(1[.][ \t]*)?(Yes|No)|[0-9]+[.][ \t]*No|Press enter to confirm or esc to go back|Enter to (confirm|select) · Esc to cancel)[ \t]*$/) f_up = i
          }
          if (f_cx > 0 && no_output_after(f_cx)) finish("codex-feedback-dialog", "Escape", f_cx)
          if (f_up > 0 && no_output_after(f_up)) finish("codex-upload-logs", "Escape", f_up)
        }

        exit 1
      }
    '
}

# fm_control_send_feedback_dismiss <backend> <target> <dismiss-key> [<expected-label>]
# Delivers the dismiss choice resolved by fm_control_feedback_dialog_dismiss to
# <backend>:<target> without ever pressing Enter or typing feedback text.
# Only `0` (literal single-key skip/dismiss) and `Escape` are permitted.
fm_control_send_feedback_dismiss() {  # <backend> <target> <dismiss-key> [<expected-label>]
  local backend=${1-} target=${2-} key=${3-} label=${4-} fn
  [ -n "$backend" ] && [ -n "$target" ] && [ -n "$key" ] || return 1
  if declare -F fm_backend_source >/dev/null 2>&1; then
    fm_backend_source "$backend" >/dev/null 2>&1 || return 1
  fi
  case "$key" in
    Escape)
      if [ "$backend" = orca ] && declare -F fm_backend_orca_send_literal >/dev/null 2>&1; then
        fm_backend_orca_send_literal "$target" $'\033'
      else
        fm_backend_send_key "$backend" "$target" Escape "$label"
      fi
      ;;
    0)
      fn="fm_backend_${backend}_send_literal"
      if declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$target" 0 "$label"
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

fm_control_feedback_window_key() {  # <backend> [<target>]
  local key=${1-}
  [ "$#" -lt 2 ] || key="${1-}_${2-}"
  key=${key//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

fm_control_feedback_pane_hash() {  # <screen> [harness]
  local text rc=0
  text=$(fm_control_feedback_dialog_dismiss "${2-}" "${1-}" marker) || rc=$?
  if [ "$rc" -ne 0 ]; then
    text=$(printf '%s\n' "${1-}" \
      | LC_ALL=C sed -e $'s/\033\\[[0-9;?<>=]*[ -\\/]*[@-~]//g' -e $'s/\033\\][^\a]*\a//g' -e $'s/\r//g' \
      | awk 'NF { r[++n] = $0 } END { s = n - 17; if (s < 1) s = 1; for (i = s; i <= n; i++) print r[i] }')
  fi
  printf '%s\n' "$text" | cksum | awk '{ print $1 "_" $2 }'
}

fm_control_capture_feedback_pane() {  # <backend> <target> [<expected-label>]
  local backend=${1-} target=${2-} label=${3-}
  local -x FM_ORCA_CLI_CACHE_TTL=0
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  if declare -F fm_backend_source >/dev/null 2>&1; then
    fm_backend_source "$backend" >/dev/null 2>&1 || return 1
  fi
  if declare -F fm_backend_visible_capture_supported >/dev/null 2>&1 \
    && fm_backend_visible_capture_supported "$backend" 2>/dev/null; then
    fm_backend_visible_capture "$backend" "$target" ${label:+"$label"} 2>/dev/null
    return $?
  fi
  if [ "$backend" = orca ] \
    && declare -F fm_backend_orca_recorded_droid >/dev/null 2>&1 \
    && fm_backend_orca_recorded_droid "$target" "$label" 2>/dev/null; then
    fm_backend_visible_capture "$backend" "$target" ${label:+"$label"} 2>/dev/null
    return $?
  fi
  fm_backend_capture "$backend" "$target" 60 ${label:+"$label"} 2>/dev/null
}

FM_CONTROL_FEEDBACK_DIALOG_ID=
FM_CONTROL_FEEDBACK_DISMISS_KEY=
FM_CONTROL_FEEDBACK_AFTER_PANE=

fm_control_release_feedback_claim() {  # <claim-dir>
  local claim=${1-} lib=${BASH_SOURCE[0]}
  [ -n "$claim" ] || return 0
  # shellcheck source=/dev/null
  command -v fm_lock_release >/dev/null 2>&1 || FM_STATE_OVERRIDE="${claim%/*}" . "${lib%/*}/fm-wake-lib.sh"
  fm_lock_release "$claim"
}

fm_control_acquire_feedback_claim() {  # <claim-dir>
  local claim=${1-} lib=${BASH_SOURCE[0]} owner_pid='' owner_epoch='' rc=0
  [ -n "$claim" ] || return 1
  # shellcheck source=/dev/null
  command -v fm_lock_try_acquire >/dev/null 2>&1 || FM_STATE_OVERRIDE="${claim%/*}" . "${lib%/*}/fm-wake-lib.sh"
  if [ -f "$claim/owner" ]; then
    fm_lock_try_acquire_steal_mutex "$claim.steal" || return 1
    if [ -f "$claim/owner" ]; then
      IFS=' ' read -r owner_pid owner_epoch < "$claim/owner" 2>/dev/null || true
      case "$owner_pid" in
        ''|*[!0-9]*) rc=1 ;;
        *)
          if fm_pid_alive "$owner_pid"; then
            rc=1
          else
            rm -f "$claim/owner" && rmdir "$claim" || rc=1
          fi
          ;;
      esac
    fi
    fm_lock_release "$claim.steal"
    [ "$rc" -eq 0 ] || return 1
  fi
  fm_lock_try_acquire "$claim"
}

# fm_control_dismiss_feedback_dialog <state-dir> <backend> <target> <harness> <screen> [<expected-label>] [<settle-secs>] [<call-timeout-secs>]
# Shared claim-and-dismiss helper called by the watcher's two sites, the
# daemon's two sites, and the watchdog. Serializes dismissal per
# (<backend>, <target>) with an owner-tracked lock directory
# ($state/.feedback-claim-<window_key>) held from live capture through
# post-send verification; never removes another live caller's active claim,
# and uses the wake library's serialized recovery of dead owners.
# Requires a non-empty live capture that still matches a supported feedback
# dialog before sending any key. The one-key marker
# ($state/.feedback-dismissed-<window_key>) hashes the dialog through its input
# box, with digits stripped from the footer downward, so a status tick is not
# a new pane. It is written when the post-send capture still shows the dialog
# or is empty, and removed when a later live capture shows the dialog is gone. Each
# backend send and capture is bounded by <call-timeout-secs> (default 20). A
# failed send releases the lock without recording the marker so a later tick
# can retry.
# Returns:
#   0 - claimed, sent key, re-captured, and verified the dialog is gone
#   1 - <screen> does not match a known feedback/bug-report dialog for <harness>
#   2 - already claimed, live capture empty/failed/cleared, or unchanged sticky dialog; no key sent
#   3 - claimed, but key delivery failed
#   4 - claimed and key sent, but re-capture did not prove the dialog gone
fm_control_dismiss_feedback_dialog() {
  local state_dir=${1-} backend=${2-} target=${3-} harness=${4-} screen=${5-}
  local label=${6-} settle=${7-0.2} call_timeout=${8:-20}
  local spec dialog_id dismiss_key wkey phash marker claim live after prev_marker lib
  FM_CONTROL_FEEDBACK_DIALOG_ID=
  FM_CONTROL_FEEDBACK_DISMISS_KEY=
  FM_CONTROL_FEEDBACK_AFTER_PANE=
  [ -n "$state_dir" ] && [ -n "$backend" ] && [ -n "$target" ] && [ -n "$screen" ] || return 1
  spec=$(fm_control_feedback_dialog_dismiss "$harness" "$screen") || spec=
  dialog_id=${spec%%$'\t'*}
  dismiss_key=${spec#*$'\t'}
  FM_CONTROL_FEEDBACK_DIALOG_ID=$dialog_id
  FM_CONTROL_FEEDBACK_DISMISS_KEY=$dismiss_key
  wkey=$(fm_control_feedback_window_key "$backend" "$target")
  [ -n "$wkey" ] || return 1
  marker="$state_dir/.feedback-dismissed-$wkey"
  claim="$state_dir/.feedback-claim-$wkey"
  [ -n "$spec" ] || [ -f "$marker" ] || return 1
  mkdir -p "$state_dir" 2>/dev/null || return 1
  if ! fm_control_acquire_feedback_claim "$claim"; then
    return 2
  fi
  lib=${BASH_SOURCE[0]}
  # shellcheck source=bin/fm-timeout-lib.sh
  command -v fm_run_timed_fn >/dev/null 2>&1 || . "${lib%/*}/fm-timeout-lib.sh"
  live=$(fm_run_timed_fn "$call_timeout" fm_control_capture_feedback_pane "$backend" "$target" "$label") || live=
  if [ -z "$live" ]; then
    fm_control_release_feedback_claim "$claim"
    return 2
  fi
  if ! spec=$(fm_control_feedback_dialog_dismiss "$harness" "$live"); then
    FM_CONTROL_FEEDBACK_AFTER_PANE=$live
    rm -f "$marker"
    fm_control_release_feedback_claim "$claim"
    [ -n "$dialog_id" ] || return 1
    return 2
  fi
  if [ -z "$dialog_id" ]; then
    fm_control_release_feedback_claim "$claim"
    return 1
  fi
  dialog_id=${spec%%$'\t'*}
  dismiss_key=${spec#*$'\t'}
  # shellcheck disable=SC2034
  FM_CONTROL_FEEDBACK_DIALOG_ID=$dialog_id
  # shellcheck disable=SC2034
  FM_CONTROL_FEEDBACK_DISMISS_KEY=$dismiss_key
  phash=$(fm_control_feedback_pane_hash "$live" "$harness")
  prev_marker=$(cat "$marker" 2>/dev/null || true)
  if [ "$prev_marker" = "$phash" ]; then
    fm_control_release_feedback_claim "$claim"
    return 2
  fi
  if ! fm_run_timed_fn "$call_timeout" fm_control_send_feedback_dismiss "$backend" "$target" "$dismiss_key" "$label" >/dev/null 2>&1; then
    fm_control_release_feedback_claim "$claim"
    return 3
  fi
  case "$settle" in
    ''|0|0.0) ;;
    *) sleep "$settle" ;;
  esac
  after=$(fm_run_timed_fn "$call_timeout" fm_control_capture_feedback_pane "$backend" "$target" "$label") || after=
  # shellcheck disable=SC2034
  FM_CONTROL_FEEDBACK_AFTER_PANE=$after
  if [ -z "$after" ] || fm_control_feedback_dialog_dismiss "$harness" "$after" >/dev/null 2>&1; then
    printf '%s\n' "$phash" > "$marker"
    fm_control_release_feedback_claim "$claim"
    return 4
  fi
  rm -f "$marker"
  fm_control_release_feedback_claim "$claim"
  return 0
}
