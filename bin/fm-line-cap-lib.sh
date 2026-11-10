# shellcheck shell=bash
# Shared per-line cap for agent-facing digest lines.
# Usage: . bin/fm-line-cap-lib.sh; fm_cap_line "<line>" [<max>]
#
# ONE OWNER for the bounded-line shape the wake digest uses. The wake digest's
# OPEN DECISIONS section (bin/fm-wake-drain.sh) renders an agent-written status
# line, which AGENTS.md section 8 treats as a wake EVENT rather than current
# state, into a size-bounded view, so the cut and its marker live here. (The
# session-start digest no longer prints status tails; it renders one line per
# task and points at bin/fm-crew-state.sh for detail.)
#
# Callers keep their own composite policy: fm-wake-drain.sh still owns the
# OPEN DECISIONS global byte cap and its "N more omitted" disclosure. This
# file owns only the per-line cut.
#
# Under a UTF-8 locale the cap counts characters, so a plain-ASCII line - what
# status lines are in practice - is bounded to the same number of bytes. Under a
# C or unset locale bash counts bytes, so after a byte cut any trailing
# incomplete UTF-8 sequence is dropped: the line may come out a little shorter
# than the cap, but a multibyte character is never cut in half.
# Truncation stays recoverable because every OPEN DECISIONS entry begins with
# the task id that identifies its durable state/<id>.status source.

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

# fm_cap_line_var <line> [<max>]: put <line> in FM_LINE_CAP_LINE, cut to <max>
# characters with FM_LINE_CAP_SUFFIX in place of the tail when it is longer. A
# line at or under the cap is kept unchanged, marker and all bytes intact.
# This is the rule itself. It assigns rather than prints so a caller that needs
# the value - the wake digest builds its section in a variable to weigh each
# item against a global budget - never pays a command substitution per item on
# a path that runs at the top of every wake-handling turn.
fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  line=${line:0:$keep}
  [ "${#FM_LINE_CAP_PROBE}" -eq 1 ] || fm_line_cap_trim_partial_utf8
  FM_LINE_CAP_LINE="$line$FM_LINE_CAP_SUFFIX"
}

# One three-byte character: its length is 1 only when bash counts characters.
FM_LINE_CAP_PROBE=$'\342\224\200'

# fm_line_cap_trim_partial_utf8: drop a trailing incomplete UTF-8 sequence (a
# lead byte and the continuation bytes after it) from the caller's byte-cut
# `line`. Only called when bash counts bytes, so each pattern matches one byte.
fm_line_cap_trim_partial_utf8() {
  local rest=$line n=0 need
  while [ "$n" -lt 3 ]; do
    case ${rest: -1} in
      [$'\200'-$'\277']) rest=${rest%?}; n=$((n + 1)) ;;
      *) break ;;
    esac
  done
  case ${rest: -1} in
    [$'\300'-$'\337']) need=1 ;;
    [$'\340'-$'\357']) need=2 ;;
    [$'\360'-$'\367']) need=3 ;;
    *) return 0 ;;
  esac
  [ "$n" -ge "$need" ] || line=${rest%?}
}

# fm_cap_line <line> [<max>]: the same cut, printed on stdout, for a caller that
# is streaming lines rather than accumulating them.
fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}
