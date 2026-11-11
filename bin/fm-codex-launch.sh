#!/usr/bin/env bash
# Launch Codex with the pane's endpoint and inbox variables forced into its
# tool shells, then exec it with every remaining argument unchanged.
#
# Codex tool shells inherit only what the operator's Codex config lets
# through: a global [shell_environment_policy] inherit="core" strips
# HERDR_PANE_ID, HERDR_SESSION, TMUX, TMUX_PANE, FM_TASK_INBOX,
# AK_LIFECYCLE_POLICY and AK_LIFECYCLE_SUPERVISOR even though the pane shell
# and the Codex process itself carry them; the watcher selection in
# bin/fm-push-transition-lib.sh then refuses the secondmate watcher, and
# agent-kit lifecycle commands lose Firstmate's unattended opt-in. A
# per-launch -c shell_environment_policy.set.<VAR>="<value>" override
# (codex --help: -c takes a dotted key with a TOML-parsed value) forces each
# variable into tool shells without editing any Codex config
# file, including the operator's global ~/.codex/config.toml.
#
# This launcher reads the variables from its own environment, which the
# pane shell gives it at launch, so the values always name this worker's
# pane rather than the launching process's. Only variables that carry a
# value are named; an unset variable stays unset in the tool shell.
#
# FM_CODEX_BIN, when set, names the Codex executable to exec instead of the
# first codex on PATH; bin/fm-spawn.sh sets it for a raw command that starts
# Codex by path. It is unset before exec so Codex never inherits it.
#
# Usage: fm-codex-launch.sh [codex args...]
set -u

args=()
for var in HERDR_PANE_ID HERDR_SESSION TMUX TMUX_PANE FM_TASK_INBOX AK_LIFECYCLE_POLICY AK_LIFECYCLE_SUPERVISOR; do
  value=${!var:-}
  [ -n "$value" ] || continue
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  args+=(-c "shell_environment_policy.set.$var=\"$value\"")
done

codex_bin=${FM_CODEX_BIN:-codex}
unset FM_CODEX_BIN
exec "$codex_bin" ${args[@]+"${args[@]}"} "$@"
