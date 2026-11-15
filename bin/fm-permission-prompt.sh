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
# Verdicts, checked in this order. Only a proven structure leads to an action:
#   route tool-approval
#       A Claude tool-approval prompt whose structure is proven on a worker with
#       a recorded claude harness: a question row `Do you want to proceed?` (or
#       the make-this-edit and create variants) below a full-width rule, the
#       cursor on `1. Yes`, a `No` option, and the `Esc to cancel` footer as the
#       last row, whose rows name no hard-stop category. The route is
#       decline-and-steer: Escape (live-verified on Claude Code 2.1.325 to
#       cancel the call without running it), then an instruction through
#       bin/fm-send.sh. No route ever selects a Yes option. The same proven
#       prompt on another harness is `hold unknown-harness`.
#   trust workspace
#       Claude's or Antigravity's workspace-trust dialog, proven by its heading
#       and answer rows. Claude's cursor sits on the declining `No, exit`, so
#       Enter would exit, and Antigravity's preselects its safe answer; either
#       way no key: the watchdog asks bin/fm-control.sh for a controlled
#       relaunch, whose spawn pre-registers the worktree's trust entry. Other
#       harnesses get `hold trust-unregistered`.
#   hardstop <credential|sign-in|spend|destructive|release|reserved>
#       The prompt names a credential, a sign-in, paid usage, a destructive
#       command, a merge, tag or release, or another owner-reserved category
#       (fm_wd_reserved). Never answered. A tool-approval prompt and every
#       picker, including a usage-limit or model-switch picker, are checked for
#       every category in their own rows; a screen with no picker is checked
#       only for a credential or sign-in input on its last row.
#   hold <external-imports|bypass-confirm|hooks-review>
#       A dialog whose every answer is a standing decision or whose default
#       answer exits the worker: Claude's external-imports dialog (Escape
#       records a permanent decline), Claude's bypass-permissions confirmation
#       (the cursor sits on `No, exit`), and Codex's hook-review modal. No key.
#   hold unproven
#       Any other permission dialog. No key. Any other question picker has no
#       verdict.
#
# Functions (all pure; they read their arguments and print):
#   fm_pp_classify <screen> <harness> [<dialog>]
#   fm_pp_prompt_rows <screen>
#       Prints the prompt rows: everything below the nearest full-width rule
#       above the last row when a question or first option row sits below it,
#       else the watchdog's own dialog rows.
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
if ! declare -F fm_composer_secret_input >/dev/null 2>&1; then
  # shellcheck source=bin/fm-composer-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-composer-lib.sh"
fi
if ! declare -F fm_secret_like >/dev/null 2>&1; then
  # shellcheck source=bin/fm-secret-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secret-lib.sh"
fi

FM_PP_CREDENTIAL_RE='password|--reveal|(^|[^a-z])op[[:space:]]+item|aws[[:space:]]+configure|(^|[^a-z])(otp|2fa|mfa)([^a-z]|$)|one.time (code|password)|passphrase|passcode|api.?key|access.?token|auth.?token|bearer|token|secret|keychain|credential|private.?key|id_(rsa|dsa|ecdsa|ed25519)|hosts\.yml|(^|[^a-z])printenv([^a-z]|$)|ssh-add|\.ssh/|\.netrc|\.npmrc|\.pgpass|authori[sz]ation:|(^|[^a-z])cookie:|\.docker/config\.json|curl[^|;&]*[[:space:]](-u|--user)([[:space:]=]|$)|(^|[^a-z])\.env([^a-z]|$)|kubectl[^|;&]*[[:space:]]config[[:space:]]+(view|get-users|set-credentials)|kubeconfig|\.kube/config|\.aws/|\.git-credentials|(^|[^a-z])vault[[:space:]]+(read|kv|login|token)|(^|[^a-z])(pass|gopass)[[:space:]]+(show|-c|otp|git|cat)([[:space:]]|$)|(^|[^a-z])(bw|lpass|keepassxc-cli)[[:space:]]+(get|show|export)|1password|op (read|signin)|security (find|add|delete)-|(^|[^a-z])gpg|(^|[^a-z])sudo([^a-z]|$)'
FM_PP_SIGNIN_RE='sign.?in|log.?in|/login|authenticat|oauth|paste (the )?(authorization |authentication )?code|verification code|device code|browser didn.t open|select login method|not logged in|re-?authori[sz]e|session expired'
FM_PP_SPEND_RE='add funds|paid[[:space:]]+(usage|credits?|plan|tier|model|request)|credits?[[:space:]]+to[[:space:]]+continue|use[[:space:]]+(your[[:space:]]+|extra[[:space:]]+|more[[:space:]]+)?credits|(^|[^a-z])charg(e|ed|es|ing)([^a-z]|$)|buy (more )?credits|purchase|payment|billing|upgrade (your |to )?(plan|max|pro)|extra usage|pay.as.you.go|overage|spend|credit card|subscribe|top.?up'
FM_PP_DESTRUCTIVE_RE='(^|[^a-z])(rm|rmdir|unlink|shred|srm)([[:space:]]|$)|--recursive|(^|[[:space:]])--force([[:space:]=-]|$)|git[[:space:]]([^|;&]*[[:space:]])?(restore|clean|rm)([[:space:]]|$)|git[[:space:]]([^|;&]*[[:space:]])?reset[^|;&]*[[:space:]]--(hard|merge|keep)|git[[:space:]]([^|;&]*[[:space:]])?checkout[^|;&]*[[:space:]](-f|--force|\.|--)([[:space:]]|$)|git[[:space:]]([^|;&]*[[:space:]])?switch[^|;&]*[[:space:]](-f|--discard-changes)([[:space:]]|$)|git[[:space:]]([^|;&]*[[:space:]])?push[^|;&]*([[:space:]]-f([[:space:]]|$)|[[:space:]:]\+|[[:space:]]:[^[:space:]]|--delete|--mirror|--prune|[[:space:]]-d([[:space:]]|$))|git[[:space:]]([^|;&]*[[:space:]])?update-ref[^|;&]*[[:space:]]-d([[:space:]]|$)|s3[[:space:]]+rb([[:space:]]|$)|tmux[^|;&]*[[:space:]]kill-(server|session|pane|window)|git[[:space:]]([^|;&]*[[:space:]])?branch[^|;&]*[[:space:]]-(d|-delete)([[:space:]]|$)|git[[:space:]]([^|;&]*[[:space:]])?stash[[:space:]]+(drop|clear)|git[[:space:]]([^|;&]*[[:space:]])?(filter-branch|filter-repo|reflog[[:space:]]+expire)|worktree[[:space:]]+(remove|prune)|find[[:space:]].*-delete|(^|[^a-z])prune([^a-z]|$)|drop[[:space:]]+(table|database|schema)|truncate|(^|[^a-z])(delet|destroy|wipe|erase|overwrit)|mkfs|(^|[^a-z])dd[[:space:]]+if=|(chmod|chown|chgrp)([[:space:]][^|;&]*)?[[:space:]](-[a-z]*r|--recursive)|chmod[^|;&]*777|(^|[^a-z])mv[[:space:]]+(-[a-z]*f|--force)|(^|[[:space:];&|(])(:|true)[[:space:]]*>[^>&]|>[[:space:]]*/dev/(r?disk|sd|nvme)|kill[[:space:]]+-9|pkill|killall'
FM_PP_RELEASE_RE='git[[:space:]]([^|;&]*[[:space:]])?push[^|;&]*[[:space:]:/](main|master|trunk|release[^[:space:]]*)([[:space:]]|$)|git[[:space:]]([^|;&]*[[:space:]])?push[^|;&]*([[:space:]:/]v[0-9]+\.[0-9]|--tags)|refs/(heads/(main|master|trunk)|tags/)|git[[:space:]]([^|;&]*[[:space:]])?tag([[:space:]]|$)|(^|[^be])merg|deploy|releas|publish|production|(^|[^a-z])prod([^a-z]|$)|gh[[:space:]]+release|npm[[:space:]]+publish|twine[[:space:]]+upload|terraform[[:space:]]+apply|kubectl[[:space:]]+(apply|delete|rollout)|helm[[:space:]]+(install|upgrade)|docker[[:space:]]+push'

# The prompt rows below the nearest full-width rule above the last row, when a
# question or first option row sits below that rule. Conversation above the rule,
# such as a numbered list, never becomes part of the prompt. A rule with an odd
# number of dashed command-box rows below it sits inside a command preview, such
# as a heredoc, so the search goes on to the rule above it. Without a proven
# rule the boundary is unproven and this returns 1.
_fm_pp_ruled_rows() {  # <screen>
  local rows
  rows=$(printf '%s\n' "${1-}" | fm_wd_strip_ansi | awk '
    { r[NR] = $0 }
    END {
      last = NR
      while (last > 0 && r[last] !~ /[^ \t]/) last--
      floor = last - 60; if (floor < 1) floor = 1
      top = 0; dashed = 0
      for (i = last; i >= floor; i--) {
        if (r[i] ~ /^[ \t]*(╌){20,}[ \t]*$/) dashed++
        else if (r[i] ~ /^[ \t]*(─|━){20,}[ \t]*$/ && dashed % 2 == 0) { top = i; break }
      }
      if (!top) exit 1
      # A proven box has at most its two dashed rows, and no other rule above
      # it encloses a dashed row, which would put this rule inside a command.
      if (dashed > 2) exit 1
      for (i = top - 1; i >= floor; i--) {
        if (r[i] ~ /^[ \t]*(─|━){20,}[ \t]*$/) break
        if (r[i] ~ /^[ \t]*(╌){20,}[ \t]*$/) { for (j = i - 1; j >= floor; j--) if (r[j] ~ /^[ \t]*(─|━){20,}[ \t]*$/) exit 1; break }
      }
      anchor = 0
      for (i = top + 1; i <= last; i++) {
        if (r[i] ~ /^[ \t]*(❯|›|>)?[ \t]*1[.)][ \t]/ || tolower(r[i]) ~ /do you want to |would you like to /) anchor = i
      }
      if (!anchor) exit 1
      for (i = top + 1; i <= last; i++) if (r[i] ~ /[^ \t]/) print r[i]
    }') && [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
}

# The proven prompt rows, or else the watchdog's own dialog rows, which stop at
# the last 14 non-blank rows.
fm_pp_prompt_rows() {  # <screen>
  _fm_pp_ruled_rows "${1-}" || _fm_wd_dialog_rows "${1-}" all
}

fm_pp_hash() {  # <screen>
  fm_pp_prompt_rows "${1-}" | cksum | awk '{ print $1 }'
}

fm_pp_hardstop_category() {  # <text>
  local t
  # The rows joined with spaces and with nothing, so a soft-wrapped command
  # such as `--ha` over `rd` still reads as one word.
  t=$(_fm_wd_guard_view "${1-}" | tr '\n\t' '  ')
  # The text again with shell quotes and backslashes removed, so a quoted
  # argument such as "--hard" or HEAD:"main" reads as the word it is.
  t="$t $(printf '%s' "$t" | tr -d "\"'\\\\")"
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_CREDENTIAL_RE"; then printf 'credential\n'; return 0; fi
  # The fleet's one secret detector, which also knows a URL with credentials
  # in it, such as https://user:pass@host.
  if fm_secret_like "$t"; then printf 'credential\n'; return 0; fi
  # An environment dump, bare, wrapped, or with options, prints every
  # exported secret.
  if fm_wd_lower "${1-}" | LC_ALL=C grep -Eq '(^|[;&|(][[:space:]]*)[[:space:]]*((command|builtin|exec|sudo|nohup)[[:space:]]+)*(([^[:space:]]*/)?(env|printenv)([[:space:]]+-[^[:space:]|;&>]*)*|set|export[[:space:]]+-p|declare[[:space:]]+-[a-z]*x|typeset[[:space:]]+-[a-z]*x|compgen[[:space:]]+-e)[[:space:]]*($|[|>;&)])'; then printf 'credential\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_SIGNIN_RE"; then printf 'sign-in\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_SPEND_RE"; then printf 'spend\n'; return 0; fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_DESTRUCTIVE_RE"; then printf 'destructive\n'; return 0; fi
  # A checkout can restore files over local changes, and a path cannot be told
  # from a branch name, so only a checkout that creates a branch is not one.
  if printf '%s' "$t" | LC_ALL=C grep -Eq 'git[[:space:]]([^|;&]*[[:space:]])?checkout([[:space:]]|$)' \
    && ! printf '%s' "$t" | LC_ALL=C grep -Eq 'git[[:space:]]([^|;&]*[[:space:]])?checkout[[:space:]]+(-[bc]|--orphan)[[:space:]]'; then
    printf 'destructive\n'; return 0
  fi
  if printf '%s' "$t" | LC_ALL=C grep -Eq "$FM_PP_RELEASE_RE"; then printf 'release\n'; return 0; fi
  if fm_wd_reserved "${1-}"; then printf 'reserved\n'; return 0; fi
  return 1
}

# Only the last non-blank row counts, and only as an input waiting for typed
# secret text, so conversation that mentions a password is never a prompt. The
# send guard in bin/fm-composer-lib.sh reads the same detector.
fm_pp_bottom_input() {  # <screen>
  fm_composer_secret_input "${1-}"
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

# A workspace-trust dialog, proven by its rows rather than its words: the
# lowest heading row and the trust answer as an option row below it, with no
# tool-approval question below it. Claude's also needs its No, exit row and
# recorded footer (2.1.325). Antigravity's heading is the one bin/fm-spawn.sh
# waits on, and its answer rows must end the screen with no composer below. A
# command that mentions a trust phrase is not one.
_fm_pp_trust_dialog() {  # <screen>
  local rows
  rows=$(printf '%s\n' "${1-}" | fm_wd_strip_ansi | awk '
    { r[NR] = $0 }
    END {
      last = NR
      while (last > 0 && r[last] !~ /[^ \t]/) last--
      floor = last - 40; if (floor < 1) floor = 1
      claude = 0; agy = 0; head = 0
      for (i = last; i >= floor; i--) {
        if (r[i] ~ /^[ \t]*Quick safety check: Is this a project you created or one you trust\?/) { claude = 1; head = i; break }
        if (r[i] ~ /^[ \t]*Do you trust the contents of this project\?[ \t]*$/) { agy = 1; head = i; break }
      }
      if (!head) exit 1
      no = 0; yes = 0; quoted = 0; after = 0
      for (i = head; i <= last; i++) {
        if (r[i] ~ /^[ \t]*Do you want to /) exit 1
        if (r[i] ~ /^[ \t]*(❯|›|>)?[ \t]*([0-9]+\.[ \t]*)?No, exit[ \t]*$/) no = 1
        if (r[i] ~ /^[ \t]*(❯|›|>)?[ \t]*([0-9]+\.[ \t]*)?Yes, I trust this folder[ \t]*$/) { yes = 1; after = 0 }
        else if (yes && r[i] ~ /[^ \t]/) after++
        if (yes && (r[i] ~ /^[ \t]*(─|━){20,}[ \t]*$/ || r[i] ~ /\? for shortcuts/)) quoted = 1
      }
      # Claude: the answer rows end the screen above its footer, with no
      # composer or later picker below them.
      if (claude && yes && no && !quoted && after < 4 && r[last] ~ /^[ \t]*Enter to confirm · Esc to cancel[ \t]*$/) { print "ok"; exit 0 }
      # Antigravity: the answer rows end the screen, with no composer below.
      if (agy && yes && !quoted && after < 4) { print "ok"; exit 0 }
      exit 1
    }') || return 1
  [ "$rows" = ok ]
}

fm_pp_classify() {  # <screen> <harness> [<dialog>]
  local screen=${1-} harness=${2-} dialog=${3-} rows text cat
  [ -n "$screen" ] || return 1
  # A proven trust dialog is read first, because the Antigravity picker has no
  # footer the watchdog's dialog detector recognizes.
  if _fm_pp_trust_dialog "$screen"; then
    case "$harness" in
      claude|agy) printf 'trust\tworkspace\n' ;;
      *) printf 'hold\ttrust-unregistered\n' ;;
    esac
    return 0
  fi
  if [ "$dialog" = none ]; then
    dialog=
  elif [ -z "$dialog" ]; then
    dialog=$(fm_wd_pane_dialog "$screen" "$harness") || dialog=
  fi
  case "$dialog" in
    permission|question) ;;
    '')
      if cat=$(fm_pp_bottom_input "$screen"); then
        printf 'hardstop\t%s\n' "$cat"; return 0
      fi
      # A terminal confirmation is never answered: a hard stop when it or the
      # few rows above it, which state what it confirms, name one, and
      # otherwise held.
      fm_composer_confirm_input "$screen" >/dev/null || return 1
      rows=$(_fm_wd_tail_rows "$screen" 8)
      if cat=$(fm_pp_hardstop_category "$rows"); then
        printf 'hardstop\t%s\n' "$cat"
      elif fm_wd_lower "$rows" | LC_ALL=C grep -Eq '^[[:space:]]*[a-z0-9_./-]+: (remove|overwrite|replace|delete|descend into|examine|unlink)|(^|[^a-z])(remov|discard|delet|overwrit|override|examine files)'; then
        printf 'hardstop\tdestructive\n'
      else
        printf 'hold\tconfirm\n'
      fi
      return 0
      ;;
    usage-limit|model-switch)
      # Another handler owns these pickers, but a spend, sign-in, or other
      # hard-stop answer on one is still reported and never answered here.
      cat=$(fm_pp_hardstop_category "$(_fm_wd_dialog_rows "$screen" all)") || return 1
      printf 'hardstop\t%s\n' "$cat"
      return 0
      ;;
    *) return 1 ;;
  esac
  rows=$(fm_pp_prompt_rows "$screen")
  # Only a proven structure leads to an action. A tool-approval prompt is
  # checked for every hard-stop category in its own rows and nothing else.
  if _fm_pp_claude_tool_approval "$screen"; then
    # The whole command must be read, so an unproven boundary only holds.
    if ! rows=$(_fm_pp_ruled_rows "$screen"); then
      printf 'hold\tunproven\n'; return 0
    fi
    if cat=$(fm_pp_hardstop_category "$rows"); then
      printf 'hardstop\t%s\n' "$cat"; return 0
    fi
    case "$harness" in
      claude) printf 'route\ttool-approval\n' ;;
      *) printf 'hold\tunknown-harness\n' ;;
    esac
    return 0
  fi
  if cat=$(fm_pp_hardstop_category "$rows"); then
    printf 'hardstop\t%s\n' "$cat"; return 0
  fi
  # Every remaining verdict is a hold, which presses nothing.
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
  [ "$dialog" != question ] || return 1
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
