#!/usr/bin/env bash
# fm-permission-prompt.sh - classify a worker pane that waits on a permission,
# trust, or sign-in prompt, and name the one unattended route for it.
#
# bin/fm-watchdog.sh sources this file (no side effects on source) and owns
# every action; run directly it is a pure classifier for tests and inspection:
#
#   fm-permission-prompt.sh classify [--harness <name>] [--dialog <kind>] < screen
#
# It prints one line `<verdict>\t<reason>` and exits 0, or prints nothing and
# exits 1 when the bottom of the screen holds no prompt this file recognizes.
# --dialog passes the fm_wd_pane_dialog verdict the caller already has, or
# `none` when the caller saw no dialog; it is computed from the screen when absent.
#
# Verdicts, checked in this order:
#   hold <external-imports|bypass-confirm|hooks-review>
#       On a permission or question picker: a dialog whose every answer is a standing decision or whose default
#       answer exits the worker: Claude's external-imports dialog (Escape
#       records a permanent decline), Claude's bypass-permissions confirmation
#       (the cursor sits on `No, exit`), and Codex's hook-review modal. No key.
#   trust workspace
#       Claude's or Antigravity's workspace-trust dialog. Claude's cursor sits on
#       the declining `No, exit`, so Enter would exit, and Antigravity's
#       preselects its safe answer; either way no key: the watchdog asks
#       bin/fm-control.sh for a controlled relaunch, whose spawn pre-registers
#       the worktree's trust entry. Other harnesses get `hold trust-unregistered`.
#   hardstop <credential|sign-in|spend|destructive|release|reserved>
#       The prompt names a credential, a sign-in, paid usage, a destructive
#       command, a merge or release, or another owner-reserved category
#       (fm_wd_reserved). Never answered. Any other question picker is checked
#       for every one of these categories in its prompt rows and otherwise has
#       no verdict, and a screen with no picker is checked only for a
#       credential or sign-in input on its last row.
#   route tool-approval
#       A Claude tool-approval prompt whose structure is proven on a worker with
#       a recorded claude harness: a question row `Do you want to proceed?` (or
#       the make-this-edit and create variants) below a full-width rule, the
#       cursor on `1. Yes`, a `No` option, and the `Esc to cancel` footer as the
#       last row. The route is decline-and-steer: Escape (live-verified on Claude
#       Code 2.1.325 to cancel the call without running it), then an instruction
#       through bin/fm-send.sh. No route ever selects a Yes option.
#   hold <unknown-harness|unproven>
#       Any other permission dialog. No key.
#
# Functions (all pure; they read their arguments and print):
#   fm_pp_classify <screen> <harness> [<dialog>]
#   fm_pp_prompt_rows <screen>
#       Prints the prompt rows: everything below the last full-width rule above
#       the question or first option row, else fm_wd_dialog_text's own rows.
#   fm_pp_hardstop_category <text>
#       Prints the first hard-stop category the text names. Exit 1 when none.
#   fm_pp_bottom_input <screen>
#       Prints `credential` or `sign-in` when the last non-blank row is a
#       password, passphrase, token, API key, or pasted sign-in code input.
#   fm_pp_hash <screen>
#       Prints a checksum of the prompt rows, so one prompt gets one action.
#
# Exit status of the CLI: 0 with a verdict, 1 with none, 2 on a usage error.

if ! declare -F fm_wd_pane_dialog >/dev/null 2>&1; then
  # shellcheck source=bin/fm-watchdog-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-watchdog-lib.sh"
fi

FM_PP_CREDENTIAL_RE='password|--reveal|(^|[^a-z])op[[:space:]]+item|aws[[:space:]]+configure|(^|[^a-z])(otp|2fa|mfa)([^a-z]|$)|one.time (code|password)|passphrase|passcode|api.?key|access.?token|auth.?token|bearer|token|secret|keychain|credential|private.?key|ssh-add|\.ssh/|\.netrc|\.npmrc|(^|[^a-z])\.env([^a-z]|$)|1password|op (read|signin)|security (find|add|delete)-|(^|[^a-z])gpg|(^|[^a-z])sudo([^a-z]|$)'
FM_PP_SIGNIN_RE='sign.?in|log.?in|/login|authenticat|oauth|paste (the )?(authorization |authentication )?code|verification code|device code|browser didn.t open|select login method|not logged in|re-?authori[sz]e|session expired'
FM_PP_SPEND_RE='add funds|paid[[:space:]]+(usage|credits?|plan|tier|model|request)|credits?[[:space:]]+to[[:space:]]+continue|use[[:space:]]+(your[[:space:]]+|extra[[:space:]]+|more[[:space:]]+)?credits|(^|[^a-z])charg(e|ed|es|ing)([^a-z]|$)|buy (more )?credits|purchase|payment|billing|upgrade (your |to )?(plan|max|pro)|extra usage|pay.as.you.go|overage|spend|credit card|subscribe|top.?up'
FM_PP_DESTRUCTIVE_RE='(^|[^a-z])(rm|rmdir|unlink|shred|srm)([[:space:]]|$)|--recursive|git[[:space:]]+(restore|rm|switch[[:space:]]+(-f|--discard-changes|--force))([[:space:]]|$)|git[[:space:]]+checkout[[:space:]]+(-f|--force|\.)([[:space:]]|$)|find[[:space:]].*-delete|(^|[^a-z])prune([^a-z]|$)|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-[a-z]*f|git[[:space:]]+push[^|;&]*([[:space:]]-f([[:space:]]|$)|--force|[[:space:]]\+)|branch[[:space:]]+-d|git[[:space:]]+checkout[[:space:]]+--[[:space:]]|git[[:space:]]+stash[[:space:]]+(drop|clear)|worktree[[:space:]]+(remove|prune)|drop[[:space:]]+(table|database|schema)|truncate|(^|[^a-z])(delet|destroy|wipe|erase|overwrit)|mkfs|(^|[^a-z])dd[[:space:]]+if=|chmod[[:space:]]+-r|chown[[:space:]]+-r|kill[[:space:]]+-9|pkill|killall'
FM_PP_RELEASE_RE='git[[:space:]]+push[^|;&]*[[:space:]:](main|master|trunk|release[^[:space:]]*)([[:space:]]|$)|(^|[^be])merg|deploy|releas|publish|production|(^|[^a-z])prod([^a-z]|$)|gh[[:space:]]+release|npm[[:space:]]+publish'

# The prompt rows below the last full-width rule above the question or first
# option row. Without that rule the boundary is unproven and the rows come from
# the watchdog's own dialog rows, which stop at the last 14 non-blank rows.
fm_pp_prompt_rows() {  # <screen>
  local rows
  rows=$(printf '%s\n' "${1-}" | fm_wd_strip_ansi | awk '
    { r[NR] = $0 }
    END {
      last = NR
      while (last > 0 && r[last] !~ /[^ \t]/) last--
      floor = last - 60; if (floor < 1) floor = 1
      anchor = 0
      for (i = last; i >= floor; i--) {
        if (r[i] ~ /^[ \t]*(❯|›|>)?[ \t]*1[.)][ \t]/ || tolower(r[i]) ~ /do you want to |would you like to /) anchor = i
      }
      if (!anchor) exit 1
      top = 0
      for (i = anchor - 1; i >= floor; i--) if (r[i] ~ /^[ \t]*(─|━){20,}[ \t]*$/) { top = i; break }
      if (!top) exit 1
      for (i = top + 1; i <= last; i++) if (r[i] ~ /[^ \t]/) print r[i]
    }') && [ -n "$rows" ] && { printf '%s\n' "$rows"; return 0; }
  _fm_wd_dialog_rows "${1-}" all
}

fm_pp_hash() {  # <screen>
  fm_pp_prompt_rows "${1-}" | cksum | awk '{ print $1 }'
}

fm_pp_hardstop_category() {  # <text>
  local t
  t=$(fm_wd_lower "${1-}" | tr '\n\t' '  ')
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_CREDENTIAL_RE"; then printf 'credential\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_SIGNIN_RE"; then printf 'sign-in\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_SPEND_RE"; then printf 'spend\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_DESTRUCTIVE_RE"; then printf 'destructive\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_RELEASE_RE"; then printf 'release\n'; return 0; fi
  if fm_wd_reserved "${1-}"; then printf 'reserved\n'; return 0; fi
  return 1
}

# Only the last non-blank row counts, and only as an input waiting for typed
# secret text, so conversation that mentions a password is never a prompt.
fm_pp_bottom_input() {  # <screen>
  local last
  last=$(_fm_wd_tail_rows "${1-}" 1)
  last=$(fm_wd_lower "$last" | sed -e 's/[[:space:]]*$//')
  [ -n "$last" ] || return 1
  if printf '%s' "$last" | LC_ALL=C grep -Eq '^[[:space:]]*(\[sudo\][[:space:]]+)?(password|passphrase|passcode|pin)([[:space:]]+for[[:space:]][^:]*)?:$|(enter|type|input|provide)[[:space:]]+((your|the|a)[[:space:]]+)?([a-z0-9_.-]+[[:space:]]+)?(password|passphrase|passcode|pin)[^:]*:$|(password|passphrase|passcode)([[:space:]]+for[[:space:]].*)?[^:]{0,40}:$|(enter|type)[[:space:]]+(the[[:space:]]+|your[[:space:]]+)?(otp|2fa|mfa|one.time|authenticator|security)[^:]*:$|(api[[:space:]_-]?key|token|secret)[^:]{0,30}:$'; then
    printf 'credential\n'; return 0
  fi
  if printf '%s' "$last" | LC_ALL=C grep -Eq 'paste (the )?(authorization |authentication )?code[^>:]*[>:]$|verification code[^:]*:$|device code[^:]*:$|^username for .*:$|press enter to open .*(browser|github\.com|login)'; then
    printf 'sign-in\n'; return 0
  fi
  return 1
}

# A Claude tool-approval prompt, proven by its rows rather than its words.
_fm_pp_claude_tool_approval() {  # <screen>
  local rows
  rows=$(printf '%s\n' "${1-}" | fm_wd_strip_ansi | awk '
    { r[NR] = $0 }
    END {
      last = NR
      while (last > 0 && r[last] !~ /[^ \t]/) last--
      floor = last - 60; if (floor < 1) floor = 1
      q = 0
      for (i = last; i >= floor; i--) if (r[i] ~ /^[ \t]*Do you want to (proceed|make this edit to [^?]+|create [^?]+)\?[ \t]*$/) { q = i; break }
      if (!q) exit 1
      ruled = 0
      for (i = q - 1; i >= floor; i--) if (r[i] ~ /^[ \t]*(─|━){20,}[ \t]*$/) { ruled = 1; break }
      if (!ruled) exit 1
      yes = 0; no = 0
      for (i = q + 1; i < last; i++) {
        if (r[i] ~ /^[ \t]*❯[ \t]*1\.[ \t]+Yes[ \t]*$/) yes = 1
        else if (r[i] ~ /^[ \t]*❯/) exit 1
        if (r[i] ~ /^[ \t]*[0-9]+\.[ \t]+No([ ,.].*)?$/) no = 1
      }
      if (!(yes && no)) exit 1
      if (r[last] !~ /^[ \t]*Esc to cancel([ \t]*·.*)?$/) exit 1
      print "ok"
    }') || return 1
  [ "$rows" = ok ]
}

fm_pp_classify() {  # <screen> <harness> [<dialog>]
  local screen=${1-} harness=${2-} dialog=${3-} rows text cat
  [ -n "$screen" ] || return 1
  if [ "$dialog" = none ]; then
    dialog=
  elif [ -z "$dialog" ]; then
    dialog=$(fm_wd_pane_dialog "$screen" "$harness") || dialog=
  fi
  case "$dialog" in
    permission|question) ;;
    '')
      cat=$(fm_pp_bottom_input "$screen") || return 1
      printf 'hardstop\t%s\n' "$cat"
      return 0
      ;;
    *) return 1 ;;
  esac
  rows=$(fm_pp_prompt_rows "$screen")
  text=$(fm_wd_lower "$rows" | tr '\n\t' '  ')
  if printf '%s' "$text" | LC_ALL=C grep -Eq 'external (claude\.md )?(file )?imports|allow external'; then
    printf 'hold\texternal-imports\n'; return 0
  fi
  if printf '%s' "$text" | LC_ALL=C grep -Eq 'bypass permissions mode' && printf '%s' "$text" | LC_ALL=C grep -Eq 'no, exit|yes, i accept'; then
    printf 'hold\tbypass-confirm\n'; return 0
  fi
  if printf '%s' "$text" | LC_ALL=C grep -Eq 'hooks? (are new|need review|changed)|review hooks'; then
    printf 'hold\thooks-review\n'; return 0
  fi
  if printf '%s' "$text" | LC_ALL=C grep -Eq 'quick safety check|do you trust the (files|contents) (in|of) this (folder|directory)|yes, i trust this folder|is this a project you created or one you trust'; then
    case "$harness" in
      claude|agy) printf 'trust\tworkspace\n' ;;
      *) printf 'hold\ttrust-unregistered\n' ;;
    esac
    return 0
  fi
  if [ "$dialog" = question ]; then
    cat=$(fm_pp_hardstop_category "$rows") || return 1
    printf 'hardstop\t%s\n' "$cat"
    return 0
  fi
  if cat=$(fm_pp_hardstop_category "$rows"); then
    printf 'hardstop\t%s\n' "$cat"; return 0
  fi
  if _fm_pp_claude_tool_approval "$screen"; then
    case "$harness" in
      claude) printf 'route\ttool-approval\n' ;;
      *) printf 'hold\tunknown-harness\n' ;;
    esac
    return 0
  fi
  printf 'hold\tunproven\n'
}

fm_pp_main() {
  local harness='' dialog='' screen
  [ "${1-}" = classify ] || { echo "usage: fm-permission-prompt.sh classify [--harness <name>] [--dialog <kind>] < screen" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) [ $# -ge 2 ] || { echo "error: --harness needs a value" >&2; return 2; }; harness=$2; shift 2 ;;
      --dialog) [ $# -ge 2 ] || { echo "error: --dialog needs a value" >&2; return 2; }; dialog=$2; shift 2 ;;
      *) echo "error: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  screen=$(cat)
  fm_pp_classify "$screen" "$harness" "$dialog"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fm_pp_main "$@"
  exit $?
fi
