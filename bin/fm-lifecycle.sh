#!/usr/bin/env bash
# Read or retire endpoint records. bin/fm-lifecycle-retire-lib.sh owns the contract.
#
# Usage:
#   fm-lifecycle.sh inspect --request FILE [--out FILE]
#   fm-lifecycle.sh retire --request FILE [--out FILE]
#   fm-lifecycle.sh result --home HOME --operation-id ID [--out FILE]
# inspect exits 0 when it wrote a report, including a refusal.
# retire and result exit 0 only for complete or already-retired.
# Exit 1 is refused, 2 is incomplete, 3 is a bad invocation, 6 is a lease refusal,
# and 86 is an injected fault before the named write.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# These neighbors do not create state when sourced. Wake and lease libraries
# are loaded by the retirement operation only after the parent state exists.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
unset FM_LIFECYCLE_API_VERSION
# shellcheck source=bin/fm-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-lifecycle-lib.sh"

if [ "${FM_LIFECYCLE_API_VERSION:-}" != 1 ]; then
  printf 'fm-lifecycle: required source fm-lifecycle-lib.sh has API version %s, not 1\n' \
    "${FM_LIFECYCLE_API_VERSION:-<none>}" >&2
  exit 3
fi

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die_usage() {
  usage >&2
  exit 3
}

cleanup() {
  fm_lifecycle_retire_endpoint_unlock || true
  fm_lifecycle_retire_op_unlock || true
  fm_lifecycle_retire_tmp_end || true
}
trap cleanup EXIT

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -ge 1 ] || die_usage

op=$1
shift
request=
home=
operation_id=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request)
      [ "$#" -ge 2 ] || die_usage
      request=$2
      shift 2
      ;;
    --home)
      [ "$#" -ge 2 ] || die_usage
      home=$2
      shift 2
      ;;
    --operation-id)
      [ "$#" -ge 2 ] || die_usage
      operation_id=$2
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || die_usage
      out=$2
      shift 2
      ;;
    *)
      die_usage
      ;;
  esac
done

rc=0
case "$op" in
  inspect|retire)
    [ -n "$request" ] || die_usage
    [ -z "$home" ] && [ -z "$operation_id" ] || die_usage
    if [ "$op" = inspect ]; then
      fm_lifecycle_retire_inspect "$request" "$out" || rc=$?
    else
      fm_lifecycle_retire_execute "$request" "$out" || rc=$?
    fi
    ;;
  result)
    [ -n "$home" ] && [ -n "$operation_id" ] || die_usage
    [ -z "$request" ] || die_usage
    fm_lifecycle_retire_result "$home" "$operation_id" "$out" || rc=$?
    ;;
  *)
    die_usage
    ;;
esac
exit "$rc"
