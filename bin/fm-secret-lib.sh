#!/usr/bin/env bash
# fm-secret-lib.sh - the one definition of text that looks like a credential.
#
# Sourced, never executed, with no side effects on source.
#
#   fm_secret_like <text>
#       Returns 0 when the text looks like a credential or secret.

fm_secret_like() {
  LC_ALL=C grep -Eiq \
    -e '(^|[^a-z0-9])(gh[pousr]_|github_pat_)[a-z0-9_]' \
    -e 'x-access-token' \
    -e 'authorization[[:space:]]*:' \
    -e '(^|[^a-z0-9])bearer[[:space:]]+[^[:space:]]' \
    -e 'https?://[^/[:space:]@]+@' \
    -e '://[^/[:space:]@]+:[^/[:space:]@]*@' \
    -e '(^|[^a-z0-9])sk-[a-z0-9_-]{8,}' \
    -e '(^|[^a-z0-9])(akia|asia)[a-z0-9]{16}' \
    -e '(token|password|passwd|pwd|secret|secret[_-]?key|api[_-]?key|access[_-]?key)["'"'"']?[[:space:]]*[=:][[:space:]]*[^[:space:]]' \
    -e '-----BEGIN [a-z ]*PRIVATE KEY' \
    <<< "$1"
}
