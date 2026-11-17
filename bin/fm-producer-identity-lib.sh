#!/usr/bin/env bash
# fm-producer-identity-lib.sh - who produced a supervision event: the machine,
# the firstmate home, and the actor and session inside it.
#
# Sourced by bin/fm-fleet-ledger.sh (every ledger record's source envelope) and
# bin/fm-task-snapshot.sh. docs/supervision-events.md owns the contract.
#
# IDENTITY FILE. <state>/producer-identity.json is written once per home and
# never rewritten:
#   {"v":1,"scope_id":"<uuid>","host_digest":"<sha256 hex>"|null,"created_at":<epoch>}
# scope_id names this home. host_digest is the SHA-256 of the operating
# system's host id when the file was created: IOPlatformUUID on macOS, or
# /etc/machine-id (then /var/lib/dbus/machine-id) elsewhere. The host name is
# never used. Creation is exclusive (temp file plus ln), so concurrent first
# writers agree on one file.
#
# MACHINE ID. machine_id is derived, not stored: the first 128 bits of
# SHA-256("firstmate-machine-v1:" + host id), formatted as a UUID. Every home on
# one host therefore reports the same machine_id, and the raw host id never
# leaves the host. With no readable host id, machine_id is null.
#
# ASSURANCE. fm_producer_identity_load sets FM_PRODUCER_ASSURANCE to:
#   host-match     the current host digest equals the recorded one
#   host-mismatch  it differs: the home was copied or moved to another host
#   host-unknown   no host id is readable now, or none was recorded
# This is a cooperative, same-user binding, never authentication: any process
# running as the home's user can read or replace these files, so readers must
# give the source envelope exactly the trust they give the home's state/.
# host-match is deliberately not called bound: it proves only that the home
# still sits on the host that created it, not who wrote a record.
#
# SESSION. FM_PRODUCER_ACTOR is $FM_SUPERVISION_ACTOR (main or branch, as in
# bin/fm-lease-lib.sh), or main; a caller writing on a worker's behalf sets
# it to worker after loading. FM_PRODUCER_SESSION_PID is the pid recorded in
# <state>/.lock, the home's session lock, or empty.
#
# Environment: FM_HOST_ID_OVERRIDE replaces the operating system's host id (a
# value of "none" means unreadable); tests use it.

[ -n "${_FM_PRODUCER_IDENTITY_LIB_LOADED:-}" ] && return 0
_FM_PRODUCER_IDENTITY_LIB_LOADED=1

_fm_producer_sha256() {  # reads stdin
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256) || return 1
  else
    digest=$(sha256sum) || return 1
  fi
  printf '%s' "${digest%% *}"
}

# The operating system's host id, or failure when none is readable.
fm_producer_host_id() {
  local id=''
  if [ -n "${FM_HOST_ID_OVERRIDE:-}" ]; then
    [ "$FM_HOST_ID_OVERRIDE" != none ] || return 1
    printf '%s' "$FM_HOST_ID_OVERRIDE"
    return 0
  fi
  if command -v ioreg >/dev/null 2>&1; then
    id=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
      | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' | head -n 1)
  fi
  if [ -z "$id" ]; then
    { IFS= read -r id < /etc/machine-id; } 2>/dev/null \
      || { IFS= read -r id < /var/lib/dbus/machine-id; } 2>/dev/null || id=''
  fi
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

_fm_producer_uuid4() {
  local hex
  hex=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  [ "${#hex}" -eq 32 ] || return 1
  printf '%s-%s-4%s-%x%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
    $(( (16#${hex:16:1} & 3) | 8 )) "${hex:17:3}" "${hex:20:12}"
}

# fm_producer_identity_load <state-dir>: create the identity file when absent,
# then set FM_PRODUCER_SCOPE_ID, FM_PRODUCER_MACHINE_ID (may be empty),
# FM_PRODUCER_ASSURANCE, FM_PRODUCER_ACTOR, and FM_PRODUCER_SESSION_PID.
# Returns 1 when the file can neither be read nor created.
fm_producer_identity_load() {
  local state=$1 file host='' digest='' scope tmp recorded now
  file="$state/producer-identity.json"
  if host=$(fm_producer_host_id); then
    digest=$(printf '%s' "$host" | _fm_producer_sha256) || digest=''
  fi
  if [ ! -f "$file" ]; then
    scope=$(_fm_producer_uuid4) || return 1
    now=$(date +%s)
    tmp="$file.$$.tmp"
    jq -cn --arg scope "$scope" --arg digest "$digest" --argjson now "$now" \
      '{v: 1, scope_id: $scope, host_digest: (if $digest == "" then null else $digest end), created_at: $now}' \
      > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    ln "$tmp" "$file" 2>/dev/null || true
    rm -f "$tmp"
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  FM_PRODUCER_SCOPE_ID=$(jq -r '.scope_id // empty' "$file" 2>/dev/null) || return 1
  case "$FM_PRODUCER_SCOPE_ID" in ''|*[!0-9a-f-]*) return 1 ;; esac
  recorded=$(jq -r '.host_digest // empty' "$file" 2>/dev/null) || recorded=''
  FM_PRODUCER_MACHINE_ID=''
  if [ -n "$host" ]; then
    FM_PRODUCER_MACHINE_ID=$(printf 'firstmate-machine-v1:%s' "$host" | _fm_producer_sha256) || FM_PRODUCER_MACHINE_ID=''
    [ -z "$FM_PRODUCER_MACHINE_ID" ] || FM_PRODUCER_MACHINE_ID="${FM_PRODUCER_MACHINE_ID:0:8}-${FM_PRODUCER_MACHINE_ID:8:4}-${FM_PRODUCER_MACHINE_ID:12:4}-${FM_PRODUCER_MACHINE_ID:16:4}-${FM_PRODUCER_MACHINE_ID:20:12}"
  fi
  if [ -z "$digest" ] || [ -z "$recorded" ]; then
    FM_PRODUCER_ASSURANCE='host-unknown'
  elif [ "$digest" = "$recorded" ]; then
    FM_PRODUCER_ASSURANCE='host-match'
  else
    FM_PRODUCER_ASSURANCE='host-mismatch'
  fi
  case "${FM_SUPERVISION_ACTOR:-main}" in
    main|branch) FM_PRODUCER_ACTOR=${FM_SUPERVISION_ACTOR:-main} ;;
    *) FM_PRODUCER_ACTOR=unknown ;;
  esac
  FM_PRODUCER_SESSION_PID=''
  { IFS= read -r FM_PRODUCER_SESSION_PID < "$state/.lock"; } 2>/dev/null || FM_PRODUCER_SESSION_PID=''
  case "$FM_PRODUCER_SESSION_PID" in *[!0-9]*) FM_PRODUCER_SESSION_PID='' ;; esac
  export FM_PRODUCER_SCOPE_ID FM_PRODUCER_MACHINE_ID FM_PRODUCER_ASSURANCE FM_PRODUCER_ACTOR FM_PRODUCER_SESSION_PID
  return 0
}

# fm_producer_source_json <producer>: the source envelope member, after
# fm_producer_identity_load.
fm_producer_source_json() {
  jq -cn --arg machine "$FM_PRODUCER_MACHINE_ID" --arg scope "$FM_PRODUCER_SCOPE_ID" \
    --arg assurance "$FM_PRODUCER_ASSURANCE" --arg actor "$FM_PRODUCER_ACTOR" \
    --arg pid "$FM_PRODUCER_SESSION_PID" --arg producer "$1" \
    '{machine_id: (if $machine == "" then null else $machine end), scope_id: $scope,
      assurance: $assurance, actor: $actor,
      session_pid: ($pid | tonumber? // null), producer: $producer}'
}

# fm_producer_binding_json <state-dir> <task>: the binding member, from the
# task's meta. spawn_gen is the process anchor generation firstmate minted at
# launch; endpoint is the recorded window or label; native is the runtime's own
# terminal-session incarnation (for Orca, the terminal handle and Orca worktree
# id), or null. The two are kept apart: a native session can outlive or be
# replaced under one spawn generation, and neither proves the other.
fm_producer_binding_json() {  # <state-dir> <task>
  local line spawn_gen='' backend='' window='' terminal='' worktree_id=''
  if [ -f "$1/$2.meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        spawn_gen=*) spawn_gen=${line#*=} ;;
        backend=*) backend=${line#*=} ;;
        window=*) window=${line#*=} ;;
        terminal=*) terminal=${line#*=} ;;
        orca_worktree_id=*) worktree_id=${line#*=} ;;
      esac
    done < "$1/$2.meta"
  fi
  # shellcheck disable=SC2016 # $names are jq variables.
  jq -cn --arg gen "$spawn_gen" --arg backend "$backend" --arg window "$window" \
    --arg terminal "$terminal" --arg wt "$worktree_id" \
    'def n: if . == "" then null else . end;
     {spawn_gen: ($gen | n), backend: ($backend | n), endpoint: ($window | n),
      native: (if $terminal == "" and $wt == "" then null
               else {terminal: ($terminal | n), worktree_id: ($wt | n)} end)}'
}
