# shellcheck shell=bash
# Claim-ledger vocabulary shared by the verifier (bin/fm-claims.sh) and
# fm-send --resolve-key (bin/fm-send.sh). docs/claim-ledger.md owns the record
# contract; this file owns only the status-log words of a refuted-claim
# blocker, so its opener and every closer speak one vocabulary.
#
# The status fold reserves the `claim-refuted-` key namespace
# (FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT in bin/fm-classify-lib.sh): a line
# keyed in it opens or closes the decision only when its note begins with a
# `claim-refuted-...:` token, so a bare `resolved` from the mate cannot clear
# it. The reservation is a vocabulary rule, not authentication: a writer that
# copies these words can still close the blocker. Side-effect free: sourcing
# defines functions only.

# 0 when <claim-id> is a ledger claim id: 16 lowercase hex characters.
fm_claims_id_valid() {  # <claim-id>
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 16 ]
}

# The status-log key of the blocker that reopens a task for <claim-id>.
fm_claims_reopen_key() {  # <claim-id>
  printf 'claim-refuted-%s' "$1"
}

# The reopening blocker's note: the namespace token, then the plain account.
fm_claims_reopen_note() {  # <kind> <line-number> <reason> <ledger-path>
  printf 'claim-refuted-reopen: %s claim at line %s is false: %s (ledger %s)' "$1" "$2" "$3" "$4"
}

# The close note for a refuted-claim blocker. Optional <extra> follows a space.
fm_claims_cleared_note() {  # <task-id> <claim-id> <via> [extra]
  printf 'claim-refuted-cleared: task=%s claim=%s via=%s' "$1" "$2" "$3"
  if [ -n "${4:-}" ]; then
    printf ' %s' "$4"
  fi
}

# 0 and prints the close note when <key> names a refuted-claim blocker
# (claim-refuted-<claim-id>); 1 for any other key. fm-send --resolve-key uses
# this so an operator close is accepted by the reserved-namespace fold.
fm_claims_close_note_for_key() {  # <key> <task-id> <via> [extra]
  local id
  case "$1" in
    claim-refuted-*) id=${1#claim-refuted-} ;;
    *) return 1 ;;
  esac
  fm_claims_id_valid "$id" || return 1
  fm_claims_cleared_note "$2" "$id" "$3" "${4:-}"
}
