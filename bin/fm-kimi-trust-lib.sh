#!/usr/bin/env bash
# bin/fm-kimi-trust-lib.sh - Kimi Code CLI folder-prompt predicates over one
# visible-pane capture. Sourced by bin/fm-spawn.sh's Kimi readiness gate and by
# the live guard tests/fm-kimi-trust-prompt-live-e2e.test.sh, so one owner
# answers "is the complete prompt on screen", "is any prompt text still on
# screen", and "does the prompt announce project MCP servers" for every
# supported wording.
#
# Every function takes one plain pane capture as $1.
# Only kimi_trust_dialog_missing prints output: one line per missing element.
# The wordings recognized here were recorded from the real CLI:
#   2.0.0 (2026-09-17): the options read `❯ Trust this folder` and
#     `Don't trust`.
#   2.3.0 (2026-10-23): the options read `❯ Trust and continue` and `Exit`,
#     and a directory that declares project MCP servers, in a root `.mcp.json`
#     or in `.kimi-code/mcp.json`, announces them above the options as
#     `Start N MCP server(s) automatically` over `Config: <declaring file>`.
#     tests/captures/kimi-code-2.3.0/README.md owns those captures.
# A prompt that announces project servers is never answered: answering it
# starts those servers, and Kimi's per-folder trust is not a consent decision
# that covers them.
# Pane text is matched with case patterns rather than regexes because the
# captures carry multibyte glyphs that bash patterns compare byte for byte.

# kimi_trust_dialog_missing <plain-pane-capture>
# Print each required dialog element the capture lacks; print nothing when complete.
kimi_trust_dialog_missing() { # <plain-pane-capture>
  local pane=$1
  case "$pane" in *'Trust this folder?'*) ;; *) printf '%s\n' "title 'Trust this folder?'" ;; esac
  case "$pane" in *'↑↓ navigate'*) ;; *) printf '%s\n' "navigation hint '↑↓ navigate'" ;; esac
  case "$pane" in *'Enter select'*) ;; *) printf '%s\n' "navigation hint 'Enter select'" ;; esac
  if [ "${pane#*'❯ Trust and continue'}" != "$pane" ]; then
    printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*Exit[[:space:]]*$' ||
      printf '%s\n' "negative option 'Exit' on its own line beside selected 'Trust and continue'"
  elif [ "${pane#*'❯ Trust this folder'}" != "$pane" ]; then
    case "$pane" in *"Don't trust"*) ;; *) printf '%s\n' "negative option \"Don't trust\" beside selected 'Trust this folder'" ;; esac
  else
    printf '%s\n' "selected affirmative option ('❯ Trust and continue' or '❯ Trust this folder')"
  fi
}

# kimi_trust_dialog_is_visible <plain-pane-capture>
# True only for the complete prompt: its title, both navigation-hint tokens
# (matched separately, so a hint wrapped in a narrow pane still counts), and
# one recognized affirmative-then-negative option pair. On success
# KIMI_TRUST_AFFIRMATIVE and KIMI_TRUST_NEGATIVE name the pair that was seen,
# so a diagnostic can quote the wording the pane actually showed.
# shellcheck disable=SC2034 # Output globals read by the sourcing caller.
kimi_trust_dialog_is_visible() {
  local pane=$1
  KIMI_TRUST_AFFIRMATIVE=''
  KIMI_TRUST_NEGATIVE=''
  [ -z "$(kimi_trust_dialog_missing "$pane")" ] || return 1
  case "$pane" in
    *'❯ Trust this folder'*"Don't trust"*)
      KIMI_TRUST_AFFIRMATIVE='Trust this folder'
      KIMI_TRUST_NEGATIVE="Don't trust"
      ;;
    *'❯ Trust and continue'*'Exit'*)
      KIMI_TRUST_AFFIRMATIVE='Trust and continue'
      KIMI_TRUST_NEGATIVE='Exit'
      ;;
    *) return 1 ;;
  esac
}

# kimi_trust_marker_is_present <plain-pane-capture>
# Any single marker of the prompt. A capture caught mid-redraw, one that has
# painted only the title, and Kimi's own rendering for a terminal too short
# for the dialog (the title over `Enlarge terminal to review sources`) all
# fail the complete-dialog test while the prompt is still up and waiting, so
# none of them may read as ready. `Exit` alone is not a marker: that word is
# too ordinary to withhold readiness on.
kimi_trust_marker_is_present() {
  case "$1" in
    *'Trust this folder'* | *"Don't trust"* | *'Trust and continue'*) return 0 ;;
  esac
  return 1
}

# kimi_trust_prompt_is_paged <plain-pane-capture>
# In a terminal too short for the whole disclosure, Kimi 2.3.0 keeps the
# title, the hint, and both options on screen and pages the lines between
# them, marking the page with `←→ page · N / M`. The dialog then looks
# complete while the server announcement can sit on a page that is not
# shown, so a paged prompt receives no key.
kimi_trust_prompt_is_paged() {
  case "$1" in
    *'←→ page ·'*) return 0 ;;
  esac
  return 1
}

# kimi_pane_announces_project_mcp_servers <plain-pane-capture>
# Kimi 2.3.0 lists what trusting would activate between the directory and the
# options; project MCP servers appear as `Start N MCP server(s) automatically`
# over `Config: <declaring file>`. Either line alone carries the verdict, so a
# capture that wrapped or clipped the other one still refuses.
kimi_pane_announces_project_mcp_servers() {
  case "$1" in
    *'Start '*' MCP server'*' automatically'*) return 0 ;;
    *'Config: '*'mcp.json'*) return 0 ;;
  esac
  return 1
}
