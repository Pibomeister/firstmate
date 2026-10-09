#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output globals are read by sourcing callers.
# fm-lifecycle-retire-lib.sh - endpoint retirement for one local operation.
#
# This header is the contract. bin/fm-lifecycle-lib.sh sources this file and
# bin/fm-lifecycle.sh is the executable. Neither restates the rules below.
# Sourcing defines functions only: no file, lock, directory, trap, runtime
# probe, agent, or shell-option change.
#
# Operations. inspect reads and reports ready, already-retired, refused, or
# incomplete. Its only filesystem write is the caller's --out. It takes no
# lock. ready has "authority": false and is not permission to mutate; retire
# reads the identity and the proof again. retire is the mutation. result reads
# the durable record and does not redo the work. Exit 0 is only complete or
# already-retired for retire and result. Exit 1 is refused. Exit 2 is
# incomplete. Exit 3 is a bad invocation. Exit 6 is the existing supervision
# lease refusal (bin/fm-lease-lib.sh). The retry field is none, same-request,
# or obligation. FM_LIFECYCLE_FAULT_AT=<boundary> returns
# 86 immediately before that write and leaves the write unmade. Inspect exits
# 0 whenever it produced a report, including a refused or incomplete report.
#
# Request schema_version 1 is one JSON object, parsed without eval or sourcing.
# Duplicate keys, unknown keys, and a non-object body refuse. Top-level keys
# are schema_version, operation_id, parent_home, absence_mode, consumer, and
# endpoints. consumer keys are installation_id, group_id, generation, and
# request_digest; they are recorded and confer no ownership. Each endpoint's
# keys are home, task_id, kind, spawn_gen, backend, session, window, pane_id,
# workspace_id, tab_id, parent_task_id, retain_home, process, and server.
# process keys are pid, identity, and boot_id. server keys are socket_path,
# pid, identity, and boot_id. kind is ship, scout, or secondmate. backend must
# be herdr. retain_home is true only for a secondmate; false on a secondmate
# refuses and leaves deletion to bin/fm-teardown.sh without --retain-home.
# spawn_gen matches ^s[0-9]+\.[0-9]+\.[0-9]+$. operation_id matches
# ^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$. Every endpoint in one request names the
# same session and the same server identity. The session name is not default.
# absence_mode is session-absent or endpoint-absent, with no fallback from one
# to the other. The canonical digest is the sha256 of the jq -S -c encoding of
# the object. Array order is part of the digest.
#
# Paths are physical. A symlink leaf, a path whose pwd -P differs, a hardlinked
# task record, a remote parent route, or an undeclared child refuses. Ambient
# FM_HOME, FM_ROOT, and the working directory do not identify a home.
#
# Proof. The inspector command is bin/fm-lifecycle-herdr-inventory.sh. It is executed as that program plus the
# session name. session-absent accepts only exit 0 and a JSON object whose
# sessions array omits that name, plus every recorded process gone. It never
# calls the endpoint command, server-ensure, pane get, pane close, or workspace
# close. endpoint-absent additionally requires the named session running with
# the recorded socket path and the recorded server pid, start identity, and
# boot id still alive, then bin/fm-lifecycle-herdr-endpoint.sh
# reporting error.code pane_not_found, and
# the endpoint process gone. A stopped session, a recreated name, a live
# matching process, an unreadable process, or an unreadable boot id refuses.
# A different boot id means the original process is gone. A live pid whose
# start identity differs is reuse: it is not killed and it is not the original.
# The recorded proof is the command path, the argv, the time, the exit status,
# and the sha256 of stdout. Stdout text, an empty file, or a caller-written
# boolean is not proof. This lock does not stop an unrelated Herdr client from
# creating a session.
#
# Journal. <parent>/state/lifecycle-retire/<operation_id>/{request,proof,progress,result}.json
# is created on retire after validation, one atomic rename per file. The same
# operation id with another digest refuses. A completed same-digest result
# returns already-retired and does not inventory or touch a newer incarnation.
# An endpoint-retired record with the same spawn_gen is that incarnation even
# when the operation id differs, and it is not rewritten. A different spawn_gen
# is not that incarnation. Children finish before their parent. A later refusal
# leaves an earlier child completed. Retry does not repeat a recorded outcome.
#
# Per-incarnation record. <owning-home>/state/<task-id>.endpoint-retired is
# key=value schema fm-endpoint-retired.v1, published before the task record is
# removed. It records installed_home when a secondmate directory is preserved.
# The result's retained_homes lists those directories. bin/fm-teardown.sh --retain-home writes it with operation id
# teardown-<id>-<spawn_gen> after the existing live close, and does not remove
# the home or the registry line. The default teardown path still deletes an
# authorized secondmate home. A matching generation makes
# fm_secondmate_liveness_probe report skipped, so watcher and session-start
# recovery do not relaunch it. A new incarnation is bin/fm-spawn.sh <id>
# --secondmate; retirement does not launch it. The retained home keeps its
# directory, checkout, charter, projects, config, markers, registry row, and
# config/agent-kit/herdr-panes. The library never calls remove_firstmate_home
# and never removes a registry row.
#
# Locks, outer to inner. The caller may hold its installation lock; this
# library does not take it. Retire then try-acquires
# <parent>/state/.lifecycle-retire.lock for the whole mutation and releases it
# before returning. Each endpoint, children first, try-acquires and releases
# before the next: state/.control-<id>.lock, the meta lock, and for a
# secondmate the liveness lock, the registry lock, and
# state/.backlog-handoff-<id>.lock. Contention refuses. A dead owner's lock is
# recovered only by the existing lock helper. Lease checks run before the
# operation lock so a lease exit cannot leave it held. The ordinary teardown
# presentation lock is unchanged and is not used for session-absent.
#
# Obligations stay in bin/fm-lifecycle-lib.sh: unlanded work, scout completion,
# captain-held backlog retention, pending replies, public follow-up, child
# tasks, and parent-channel delivery. This file calls those functions.
# Secondmate delivery is skipped, matching teardown. A missing worktree is not
# returned and its processes are not reaped. A present ship worktree still
# faces the unlanded-work gate.
#
# Fault boundaries for FM_LIFECYCLE_FAULT_AT: journal-request, journal-proof,
# child-cleanup, parent-retirement, outcome-handoff, outcome-receipt,
# backlog-transition, metadata-transition, final-receipt. outcome-handoff and
# outcome-receipt apply to a ship or scout that owes delivery.
#
# Trust. Changing this repo's executables does not rebind an installed home.
# The operator runs bin/fm-procevent-when.sh rebind-all there. It rehashes
# actions under that home's FM_ROOT only. A forged or stale binding does not
# run. Tests must not point that command at a real fleet home.
#
# Invocation:
#   bin/fm-lifecycle.sh inspect --request request.json --out report.json
#   bin/fm-lifecycle.sh retire --request request.json --out result.json
#   bin/fm-lifecycle.sh result --home /path/to/home --operation-id op1
# Rollback of a shipped change leaves any endpoint-retired file already written
# as data. There is no cross-file transaction with Herdr or the parent channel.

FM_LIFECYCLE_RETIRE_FAULT_RC=86
FM_LIFECYCLE_RETIRE_USAGE_RC=3

fm_lifecycle_retire_sha256_text() {
  local text=$1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
    return 0
  fi
  return 1
}

fm_lifecycle_retire_sha256_file() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  return 1
}

fm_lifecycle_retire_boot_id() {
  local raw
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
    return 0
  fi
  command -v sysctl >/dev/null 2>&1 || return 1
  raw=$(sysctl -n kern.boottime 2>/dev/null) || return 1
  raw=$(printf '%s\n' "$raw" | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}

fm_lifecycle_retire_capture_herdr_identity() {
  local session=$1 pane=$2 inventory info socket process_pid server_pid boot process_identity server_identity
  inventory=$($FM_LIFECYCLE_LIB_DIR/fm-lifecycle-herdr-inventory.sh "$session") || return 1
  socket=$(printf '%s' "$inventory" | jq -er --arg session "$session" '
    [.sessions[] | select(.name == $session and .running == true and (.socket_path | type) == "string")]
    | if length == 1 then .[0].socket_path | select(length > 0) else empty end') || return 1
  info=$("$FM_LIFECYCLE_LIB_DIR/fm-herdr-lab.sh" run "$session" pane process-info --pane "$pane") || return 1
  process_pid=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
    .result | select(.type == "pane_process_info") | .process_info
    | select(.pane_id == $pane) | .shell_pid
    | select(type == "number" and . > 1 and floor == .)') || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  server_pid=$(lsof -nP -t -U "$socket") || return 1
  case "$server_pid" in ''|*[!0-9]*) return 1 ;; esac
  boot=$(fm_lifecycle_retire_boot_id) || return 1
  process_identity=$(fm_lifecycle_process_identity "$process_pid") || return 1
  server_identity=$(fm_lifecycle_process_identity "$server_pid") || return 1
  printf 'lifecycle_process_pid=%s\n' "$process_pid"
  printf 'lifecycle_process_identity=%s\n' "$process_identity"
  printf 'lifecycle_process_boot_id=%s\n' "$boot"
  printf 'lifecycle_server_socket_path=%s\n' "$socket"
  printf 'lifecycle_server_pid=%s\n' "$server_pid"
  printf 'lifecycle_server_identity=%s\n' "$server_identity"
  printf 'lifecycle_server_boot_id=%s\n' "$boot"
}

fm_lifecycle_retire_nlink() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_lifecycle_retire_canonical_dir() {
  local path=$1 canon
  [ -n "$path" ] || return 1
  [ -d "$path" ] || return 1
  [ -L "$path" ] && return 1
  canon=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
  [ "$canon" = "$path" ] || return 1
  printf '%s\n' "$canon"
}

fm_lifecycle_retire_json_unique() {
  local file=$1
  command -v python3 >/dev/null 2>&1 || return 3
  python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
def hook(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise SystemExit(2)
        seen[key] = value
    return seen
try:
    with open(path, "rb") as handle:
        raw = handle.read()
    if b"\0" in raw:
        raise SystemExit(1)
    json.loads(raw.decode("utf-8"), object_pairs_hook=hook)
except SystemExit:
    raise
except Exception:
    raise SystemExit(1)
PY
}

fm_lifecycle_retire_tmp_begin() {
  FM_LIFECYCLE_RETIRE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lifecycle-retire.XXXXXX") || return 1
  : > "$FM_LIFECYCLE_RETIRE_TMP/endpoint-notes"
  printf '%s\n' '[]' > "$FM_LIFECYCLE_RETIRE_TMP/reasons.json"
  printf '%s\n' '[]' > "$FM_LIFECYCLE_RETIRE_TMP/endpoints.json"
  printf '%s\n' '[]' > "$FM_LIFECYCLE_RETIRE_TMP/retained.json"
  FM_LIFECYCLE_RETIRE_OP=
  FM_LIFECYCLE_RETIRE_DIGEST=
  FM_LIFECYCLE_RETIRE_PARENT=
  FM_LIFECYCLE_RETIRE_MODE=
  FM_LIFECYCLE_RETIRE_SESSION=
  FM_LIFECYCLE_RETIRE_COUNT=0
  FM_LIFECYCLE_RETIRE_JOURNAL=
}

fm_lifecycle_retire_tmp_end() {
  [ -n "${FM_LIFECYCLE_RETIRE_TMP:-}" ] || return 0
  rm -rf -- "$FM_LIFECYCLE_RETIRE_TMP"
  FM_LIFECYCLE_RETIRE_TMP=
}

fm_lifecycle_retire_fault() {
  [ "${FM_LIFECYCLE_FAULT_AT:-}" = "$1" ] || return 1
  printf 'fault: %s\n' "$1" >&2
  return 0
}

fm_lifecycle_retire_publish_file() {
  local dest=$1 src=$2 dir tmp
  [ -L "$dest" ] && return 1
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    return 1
  fi
  dir=${dest%/*}
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(mktemp "$dir/.retirepub.XXXXXX") || return 1
  if ! cp -- "$src" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_lifecycle_retire_emit_json() {
  local json=$1 out=${FM_LIFECYCLE_RETIRE_OUT:-} tmp
  if [ -n "$out" ]; then
    tmp=${FM_LIFECYCLE_RETIRE_TMP:-}
    [ -n "$tmp" ] || return 1
    printf '%s\n' "$json" > "$tmp/emit.json" || return 1
    fm_lifecycle_retire_publish_file "$out" "$tmp/emit.json" || return 1
  fi
  printf '%s\n' "$json"
}

fm_lifecycle_retire_build_json() {
  local status=$1 retry=$2 tmp=$FM_LIFECYCLE_RETIRE_TMP
  jq -n \
    --arg status "$status" \
    --arg retry "$retry" \
    --arg op "${FM_LIFECYCLE_RETIRE_OP:-}" \
    --arg digest "${FM_LIFECYCLE_RETIRE_DIGEST:-}" \
    --arg mode "${FM_LIFECYCLE_RETIRE_MODE:-}" \
    --slurpfile endpoints "$tmp/endpoints.json" \
    --slurpfile reasons "$tmp/reasons.json" \
    --slurpfile retained "$tmp/retained.json" \
    '{schema_version:1, operation_id:$op, request_digest:$digest, status:$status,
      authority:false, absence_mode:$mode, retry:$retry, reasons:$reasons[0],
      endpoints:$endpoints[0], retained_homes:$retained[0]}'
}

fm_lifecycle_retire_refresh_arrays() {
  local tmp=$FM_LIFECYCLE_RETIRE_TMP
  if [ -s "$tmp/endpoint-notes" ]; then
    jq -Rn '[inputs | select(length>0) | split("\t") | {task_id:.[0], spawn_gen:.[1], home:.[2], disposition:.[3], retain_home:(.[4]=="true"), outcome:.[5]}]' \
      < "$tmp/endpoint-notes" > "$tmp/endpoints.json" || return 1
    jq -Rn '[inputs | select(length>0) | split("\t") | select(.[4]=="true") | .[2]] | unique' \
      < "$tmp/endpoint-notes" > "$tmp/retained.json" || return 1
  else
    printf '%s\n' '[]' > "$tmp/endpoints.json"
    printf '%s\n' '[]' > "$tmp/retained.json"
  fi
}

fm_lifecycle_retire_note() {
  local id=$1 gen=$2 home=$3 disposition=$4 retain=$5 outcome=$6
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$gen" "$home" "$disposition" "$retain" "$outcome" \
    >> "$FM_LIFECYCLE_RETIRE_TMP/endpoint-notes"
}

fm_lifecycle_retire_reason() {
  local code=$1 task=$2 detail=$3
  local tmp=$FM_LIFECYCLE_RETIRE_TMP
  detail=$(printf '%s' "$detail" | tr '\n\t' '  ')
  jq -n --arg code "$code" --arg task "$task" --arg detail "$detail" \
    '[{code:$code, task_id:$task, detail:$detail}]' > "$tmp/reasons.json"
  printf '%s\n' "$detail" >&2
}

fm_lifecycle_retire_retry_for() {
  local code
  code=$(jq -r '.[-1].code // empty' "$FM_LIFECYCLE_RETIRE_TMP/reasons.json" 2>/dev/null) || code=
  case "$code" in
    obligation-*|outcome-undelivered|foreign-descendant) printf 'obligation\n' ;;
    lock-held|inventory-unreadable|incomplete|pane-unreadable|process-unknown|process-alive|session-present|session-stopped|pane-present|server-identity) printf 'same-request\n' ;;
    *) printf 'none\n' ;;
  esac
}

fm_lifecycle_retire_note_home() {
  local index=$1 home=$2 retain=$3 recorded id
  if [ "$retain" = true ] && [ -f "$FM_LIFECYCLE_RETIRE_TMP/installed.$index" ]; then
    cat "$FM_LIFECYCLE_RETIRE_TMP/installed.$index"
    return 0
  fi
  if [ "$retain" = true ]; then
    id=$(cat "$FM_LIFECYCLE_RETIRE_TMP/id.$index")
    recorded=$(fm_meta_get "$home/state/$id.endpoint-retired" installed_home)
    if [ -n "$recorded" ]; then
      printf '%s\n' "$recorded"
      return 0
    fi
  fi
  printf '%s\n' "$home"
}

fm_lifecycle_retire_report() {
  local status=$1 retry=$2 write_journal=$3 json journal
  local tmp=$FM_LIFECYCLE_RETIRE_TMP
  fm_lifecycle_retire_refresh_arrays || return 1
  json=$(fm_lifecycle_retire_build_json "$status" "$retry") || return 1
  printf '%s\n' "$json" > "$tmp/result.body" || return 1
  if [ "$write_journal" = 1 ] && [ -n "${FM_LIFECYCLE_RETIRE_JOURNAL:-}" ]; then
    journal=$FM_LIFECYCLE_RETIRE_JOURNAL
    if [ -d "$journal" ] && [ ! -L "$journal" ]; then
      fm_lifecycle_retire_publish_file "$journal/result.json" "$tmp/result.body" || return 1
    fi
  fi
  fm_lifecycle_retire_emit_json "$json"
}

fm_lifecycle_retire_load() {
  local file=$1 tmp=$FM_LIFECYCLE_RETIRE_TMP unique_rc=0 canonical digest parent mode
  local count=0 index=0 line id parent_id session server_pid server_ident server_boot server_sock
  [ -f "$file" ] && [ ! -L "$file" ] || {
    fm_lifecycle_retire_reason bad-request "" "request file is missing or not a regular file"
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    fm_lifecycle_retire_reason parser-unavailable "" "jq is required"
    return 1
  }
  fm_lifecycle_retire_json_unique "$file" || unique_rc=$?
  case "$unique_rc" in
    0) ;;
    2)
      fm_lifecycle_retire_reason bad-request "" "request has a duplicate key"
      return 1
      ;;
    3)
      fm_lifecycle_retire_reason parser-unavailable "" "python3 is required to reject duplicate keys"
      return 1
      ;;
    *)
      fm_lifecycle_retire_reason bad-request "" "request is not valid JSON"
      return 1
      ;;
  esac
  if ! jq -e '
    def exact($keys): (keys | sort) == ($keys | sort);
    (type == "object")
    and (.schema_version == 1)
    and exact(["absence_mode","consumer","endpoints","operation_id","parent_home","schema_version"])
    and (.consumer | type == "object" and exact(["generation","group_id","installation_id","request_digest"]))
    and (.consumer.generation | type == "string")
    and (.consumer.group_id | type == "string")
    and (.consumer.installation_id | type == "string")
    and (.consumer.request_digest | type == "string")
    and (.operation_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$"))
    and (.parent_home | type == "string" and startswith("/"))
    and (.absence_mode == "session-absent" or .absence_mode == "endpoint-absent")
    and (.endpoints | type == "array" and length > 0 and length <= 64)
    and all(.endpoints[];
      type == "object"
      and exact(["backend","home","kind","pane_id","parent_task_id","process","retain_home","server","session","spawn_gen","tab_id","task_id","window","workspace_id"])
      and (.home | type == "string" and startswith("/"))
      and (.task_id | type == "string")
      and (.kind == "ship" or .kind == "scout" or .kind == "secondmate")
      and (.spawn_gen | type == "string" and test("^s[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.backend == "herdr")
      and (.session | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$") and . != "default")
      and (.window | type == "string") and (.pane_id | type == "string")
      and (.workspace_id | type == "string") and (.tab_id | type == "string")
      and (.parent_task_id | type == "string")
      and (.retain_home | type == "boolean")
      and (.process | type == "object" and exact(["boot_id","identity","pid"]))
      and (.process.pid | type == "number" and . > 0 and floor == .)
      and (.process.identity | type == "string" and length > 0)
      and (.process.boot_id | type == "string" and length > 0)
      and (.server | type == "object" and exact(["boot_id","identity","pid","socket_path"]))
      and (.server.pid | type == "number" and . > 0 and floor == .)
      and (.server.identity | type == "string" and length > 0)
      and (.server.boot_id | type == "string" and length > 0)
      and (.server.socket_path | type == "string" and length > 0)
      and (((.kind == "secondmate") and .retain_home) or ((.kind != "secondmate") and (.retain_home | not)))
    )
    and (([.endpoints[].task_id] | length) == ([.endpoints[].task_id] | unique | length))
    and (([.endpoints[].session] | unique | length) == 1)
    and (([.endpoints[].server] | unique | length) == 1)
  ' "$file" >/dev/null; then
    fm_lifecycle_retire_reason bad-request "" "request does not match schema_version 1"
    return 1
  fi
  canonical=$(jq -S -c '.' "$file") || return 1
  digest=$(fm_lifecycle_retire_sha256_text "$canonical") || {
    fm_lifecycle_retire_reason parser-unavailable "" "sha256 is required"
    return 1
  }
  printf '%s\n' "$canonical" > "$tmp/canonical.json" || return 1
  parent=$(jq -r '.parent_home' "$file")
  mode=$(jq -r '.absence_mode' "$file")
  parent=$(fm_lifecycle_retire_canonical_dir "$parent") || {
    fm_lifecycle_retire_reason bad-request "" "parent home is not a physical directory"
    return 1
  }
  [ -d "$parent/state" ] && [ ! -L "$parent/state" ] || {
    fm_lifecycle_retire_reason bad-request "" "parent home has no physical state directory"
    return 1
  }
  FM_LIFECYCLE_RETIRE_OP=$(jq -r '.operation_id' "$file")
  FM_LIFECYCLE_RETIRE_DIGEST=$digest
  FM_LIFECYCLE_RETIRE_PARENT=$parent
  FM_LIFECYCLE_RETIRE_MODE=$mode
  FM_LIFECYCLE_RETIRE_SESSION=$(jq -r '.endpoints[0].session' "$file")
  : > "$tmp/all-ids"
  while IFS= read -r line; do
    index=$((index + 1))
    printf '%s\n' "$line" > "$tmp/ep.$index"
    id=$(jq -r '.task_id' "$tmp/ep.$index")
    parent_id=$(jq -r '.parent_task_id' "$tmp/ep.$index")
    command -v fm_task_id_path_safe >/dev/null 2>&1 || {
      fm_lifecycle_retire_reason parser-unavailable "" "task id check is unavailable"
      return 1
    }
    fm_task_id_path_safe "$id" || {
      fm_lifecycle_retire_reason bad-request "$id" "task id is not path-safe"
      return 1
    }
    if [ -n "$parent_id" ] && ! fm_task_id_path_safe "$parent_id"; then
      fm_lifecycle_retire_reason bad-request "$id" "parent task id is not path-safe"
      return 1
    fi
    if [ "$parent_id" = "$id" ]; then
      fm_lifecycle_retire_reason bad-request "$id" "an endpoint cannot parent itself"
      return 1
    fi
    home=$(jq -r '.home' "$tmp/ep.$index")
    home=$(fm_lifecycle_retire_canonical_dir "$home") || {
      fm_lifecycle_retire_reason bad-request "$id" "endpoint home is not a physical directory"
      return 1
    }
    jq --arg home "$home" '.home = $home' "$tmp/ep.$index" > "$tmp/ep.$index.body" || return 1
    mv -f -- "$tmp/ep.$index.body" "$tmp/ep.$index"
    printf '%s\n' "$id" > "$tmp/id.$index"
    printf '%s\n' "$parent_id" > "$tmp/parent.$index"
    printf '%s\n' "$id" >> "$tmp/all-ids"
    count=$index
  done < <(jq -c '.endpoints[]' "$file")
  FM_LIFECYCLE_RETIRE_COUNT=$count
  index=0
  while [ "$index" -lt "$count" ]; do
    index=$((index + 1))
    parent_id=$(cat "$tmp/parent.$index")
    if [ -n "$parent_id" ] && ! grep -Fxq -- "$parent_id" "$tmp/all-ids"; then
      fm_lifecycle_retire_reason bad-request "$(cat "$tmp/id.$index")" "parent task is not in the request"
      return 1
    fi
  done
  if ! fm_lifecycle_retire_child_homes "$count"; then
    return 1
  fi
  if ! fm_lifecycle_retire_order "$count"; then
    fm_lifecycle_retire_reason bad-request "" "endpoint parents are cyclic"
    return 1
  fi
  FM_LIFECYCLE_RETIRE_JOURNAL=$parent/state/lifecycle-retire/$FM_LIFECYCLE_RETIRE_OP
}

fm_lifecycle_retire_child_homes() {
  local count=$1 tmp=$FM_LIFECYCLE_RETIRE_TMP index=0 parent_id pindex pkind phome pmeta installed child_home
  while [ "$index" -lt "$count" ]; do
    index=$((index + 1))
    parent_id=$(cat "$tmp/parent.$index")
    [ -n "$parent_id" ] || continue
    pindex=0
    while [ "$pindex" -lt "$count" ]; do
      pindex=$((pindex + 1))
      [ "$(cat "$tmp/id.$pindex")" = "$parent_id" ] || continue
      pkind=$(jq -r '.kind' "$tmp/ep.$pindex")
      [ "$pkind" = secondmate ] || break
      phome=$(jq -r '.home' "$tmp/ep.$pindex")
      pmeta=$phome/state/$parent_id.meta
      [ -f "$pmeta" ] && [ ! -L "$pmeta" ] || break
      installed=$(fm_meta_get "$pmeta" home)
      [ -n "$installed" ] || {
        fm_lifecycle_retire_reason identity-mismatch "$(cat "$tmp/id.$index")" "parent secondmate home is empty"
        return 1
      }
      installed=$(fm_lifecycle_retire_canonical_dir "$installed") || {
        fm_lifecycle_retire_reason identity-mismatch "$(cat "$tmp/id.$index")" "parent secondmate home is not a physical directory"
        return 1
      }
      child_home=$(jq -r '.home' "$tmp/ep.$index")
      [ "$child_home" = "$installed" ] || {
        fm_lifecycle_retire_reason foreign-descendant "$(cat "$tmp/id.$index")" "child home is not the parent secondmate home"
        return 1
      }
      break
    done
  done
}

fm_lifecycle_retire_order() {
  local count=$1 tmp=$FM_LIFECYCLE_RETIRE_TMP index=0 progress ready child_id node_id parent_line
  : > "$tmp/remaining"
  : > "$tmp/ordered"
  while [ "$index" -lt "$count" ]; do
    index=$((index + 1))
    printf '%s\n' "$index" >> "$tmp/remaining"
  done
  while [ -s "$tmp/remaining" ]; do
    progress=0
    : > "$tmp/next-remaining"
    while IFS= read -r index; do
      [ -n "$index" ] || continue
      node_id=$(cat "$tmp/id.$index")
      ready=1
      while IFS= read -r child_line; do
        [ -n "$child_line" ] || continue
        child_id=$(cat "$tmp/parent.$child_line")
        if [ "$child_id" = "$node_id" ]; then
          ready=0
          break
        fi
      done < "$tmp/remaining"
      if [ "$ready" = 1 ]; then
        printf '%s\n' "$index" >> "$tmp/ordered"
        progress=1
      else
        printf '%s\n' "$index" >> "$tmp/next-remaining"
      fi
    done < "$tmp/remaining"
    [ "$progress" = 1 ] || return 1
    mv -f -- "$tmp/next-remaining" "$tmp/remaining"
  done
}

fm_lifecycle_retire_completed_same() {
  local result=$FM_LIFECYCLE_RETIRE_JOURNAL/result.json stored digest
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  stored=$(jq -r '.status' "$result" 2>/dev/null) || return 1
  digest=$(jq -r '.request_digest' "$result" 2>/dev/null) || return 1
  [ "$stored" = complete ] && [ "$digest" = "$FM_LIFECYCLE_RETIRE_DIGEST" ]
}

fm_lifecycle_retire_emit_already() {
  local result=$FM_LIFECYCLE_RETIRE_JOURNAL/result.json json
  json=$(jq '.status = "already-retired" | .authority = false | .retry = "none"' "$result") || return 1
  fm_lifecycle_retire_emit_json "$json"
}

fm_lifecycle_retire_command_ok() {
  local cmd=$1
  case "$cmd" in
    ''|-*|*$'\n'*|*' '*|*'	'*) return 1 ;;
  esac
  [ -f "$cmd" ] && [ ! -L "$cmd" ] && [ -x "$cmd" ]
}

fm_lifecycle_retire_actor_state() {
  local pid=$1 identity=$2 boot=$3 current
  current=$(fm_lifecycle_retire_boot_id) || {
    printf 'unknown boot-unreadable\n'
    return 0
  }
  if [ "$current" != "$boot" ]; then
    printf 'gone boot-changed\n'
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    if fm_lifecycle_process_identity_matches "$pid" "$identity"; then
      printf 'alive identity-match\n'
      return 0
    fi
    if fm_lifecycle_process_identity "$pid" >/dev/null 2>&1; then
      printf 'gone pid-reused\n'
      return 0
    fi
    printf 'unknown identity-unreadable\n'
    return 0
  fi
  if ps -p "$pid" >/dev/null 2>&1; then
    printf 'unknown permission\n'
    return 0
  fi
  printf 'gone exited\n'
}

fm_lifecycle_retire_require_gone() {
  local pid=$1 identity=$2 boot=$3 label=$4 state reason
  state=$(fm_lifecycle_retire_actor_state "$pid" "$identity" "$boot") || return 1
  reason=${state#* }
  case "$state" in
    gone\ *) return 0 ;;
    alive\ *)
      fm_lifecycle_retire_reason process-alive "$label" "recorded process $pid is still the original"
      return 1
      ;;
    *)
      fm_lifecycle_retire_reason process-unknown "$label" "recorded process $pid is $reason"
      return 1
      ;;
  esac
}

fm_lifecycle_retire_prove() {
  local tmp=$FM_LIFECYCLE_RETIRE_TMP cmd session=$FM_LIFECYCLE_RETIRE_SESSION rc=0 now digest
  local count running socket want_socket line index pid identity boot state reason pane_out epcmd
  cmd=$FM_LIFECYCLE_LIB_DIR/fm-lifecycle-herdr-inventory.sh
  fm_lifecycle_retire_command_ok "$cmd" || {
    fm_lifecycle_retire_reason bad-request "" "inventory command is not one executable path"
    return 1
  }
  rc=0
  "$cmd" "$session" > "$tmp/inv.out" 2> "$tmp/inv.err" || rc=$?
  now=$(date +%s)
  digest=$(fm_lifecycle_retire_sha256_file "$tmp/inv.out") || digest=
  jq -n --arg cmd "$cmd" --arg session "$session" --arg now "$now" --arg digest "$digest" --argjson rc "$rc" \
    '{command:$cmd, argv:[$cmd, $session], time:($now|tonumber), exit_status:$rc, stdout_sha256:$digest, session:$session}' \
    > "$tmp/proof.json" || return 1
  if [ "$rc" -ne 0 ] || ! jq -e '.sessions | type == "array"' "$tmp/inv.out" >/dev/null 2>&1; then
    fm_lifecycle_retire_reason inventory-unreadable "" "session inventory was not a complete sessions array"
    return 2
  fi
  count=$(jq -r --arg name "$session" '[.sessions[]? | select(.name == $name)] | length' "$tmp/inv.out")
  if [ "$FM_LIFECYCLE_RETIRE_MODE" = session-absent ]; then
    if [ "$count" -ne 0 ]; then
      running=$(jq -r --arg name "$session" '[.sessions[]? | select(.name == $name)][0].running' "$tmp/inv.out")
      if [ "$running" = false ]; then
        fm_lifecycle_retire_reason session-stopped "" "session $session is still present and stopped"
      else
        fm_lifecycle_retire_reason session-present "" "session $session is still present"
      fi
      return 1
    fi
  else
    want_socket=$(jq -r '.server.socket_path' "$tmp/ep.1")
    if [ "$count" -ne 1 ]; then
      fm_lifecycle_retire_reason session-present "" "endpoint-absent requires the recorded session to be present once"
      return 1
    fi
    running=$(jq -r --arg name "$session" '.sessions[] | select(.name == $name) | .running' "$tmp/inv.out")
    socket=$(jq -r --arg name "$session" '.sessions[] | select(.name == $name) | .socket_path' "$tmp/inv.out")
    if [ "$running" != true ]; then
      fm_lifecycle_retire_reason session-stopped "" "session $session is not running"
      return 1
    fi
    if [ "$socket" != "$want_socket" ]; then
      fm_lifecycle_retire_reason server-identity "" "session socket does not match the recorded server"
      return 1
    fi
    pid=$(jq -r '.server.pid' "$tmp/ep.1")
    identity=$(jq -r '.server.identity' "$tmp/ep.1")
    boot=$(jq -r '.server.boot_id' "$tmp/ep.1")
    state=$(fm_lifecycle_retire_actor_state "$pid" "$identity" "$boot") || return 1
    case "$state" in
      "alive identity-match") ;;
      *)
        fm_lifecycle_retire_reason server-identity "" "recorded server is $state"
        return 1
        ;;
    esac
  fi
  index=0
  while [ "$index" -lt "$FM_LIFECYCLE_RETIRE_COUNT" ]; do
    index=$((index + 1))
    pid=$(jq -r '.process.pid' "$tmp/ep.$index")
    identity=$(jq -r '.process.identity' "$tmp/ep.$index")
    boot=$(jq -r '.process.boot_id' "$tmp/ep.$index")
    fm_lifecycle_retire_require_gone "$pid" "$identity" "$boot" "$(cat "$tmp/id.$index")" || return 1
    if [ "$FM_LIFECYCLE_RETIRE_MODE" = session-absent ]; then
      pid=$(jq -r '.server.pid' "$tmp/ep.$index")
      identity=$(jq -r '.server.identity' "$tmp/ep.$index")
      boot=$(jq -r '.server.boot_id' "$tmp/ep.$index")
      fm_lifecycle_retire_require_gone "$pid" "$identity" "$boot" "$(cat "$tmp/id.$index")" || return 1
      continue
    fi
    epcmd=$FM_LIFECYCLE_LIB_DIR/fm-lifecycle-herdr-endpoint.sh
    fm_lifecycle_retire_command_ok "$epcmd" || {
      fm_lifecycle_retire_reason bad-request "" "endpoint command is not one executable path"
      return 1
    }
    pane_out=$tmp/pane.$index.out
    "$epcmd" "$session" "$(jq -r '.pane_id' "$tmp/ep.$index")" > "$pane_out" 2> "$tmp/pane.$index.err" || true
    if ! jq -e '.error.code == "pane_not_found"' "$pane_out" >/dev/null 2>&1; then
      if jq -e '.error.code' "$pane_out" >/dev/null 2>&1; then
        fm_lifecycle_retire_reason pane-present "$(cat "$tmp/id.$index")" "pane is not pane_not_found"
      else
        fm_lifecycle_retire_reason pane-unreadable "$(cat "$tmp/id.$index")" "pane probe was not structured"
      fi
      return 1
    fi
  done
  return 0
}

fm_lifecycle_retire_meta_match() {
  local meta=$1 endpoint=$2 field=$3 key=$4 expected actual
  expected=$(jq -r "$field" "$endpoint") || return 1
  actual=$(fm_meta_get "$meta" "$key")
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

fm_lifecycle_retire_meta_identity() {
  local index=$1 tmp=$FM_LIFECYCLE_RETIRE_TMP meta home id gen kind session window meta_session nlink installed
  id=$(cat "$tmp/id.$index")
  home=$(jq -r '.home' "$tmp/ep.$index")
  gen=$(jq -r '.spawn_gen' "$tmp/ep.$index")
  kind=$(jq -r '.kind' "$tmp/ep.$index")
  session=$(jq -r '.session' "$tmp/ep.$index")
  meta=$home/state/$id.meta
  if [ -L "$meta" ] || { [ -e "$meta" ] && [ ! -f "$meta" ]; }; then
    fm_lifecycle_retire_reason identity-mismatch "$id" "task record is not a regular file"
    return 1
  fi
  if [ ! -f "$meta" ]; then
    if [ -f "$home/state/$id.endpoint-retired" ] && [ ! -L "$home/state/$id.endpoint-retired" ] \
      && [ "$(fm_meta_get "$home/state/$id.endpoint-retired" spawn_gen)" = "$gen" ]; then
      printf 'already\n'
      return 0
    fi
    fm_lifecycle_retire_reason identity-missing "$id" "task record is gone and no matching retirement record exists"
    return 1
  fi
  nlink=$(fm_lifecycle_retire_nlink "$meta") || nlink=
  [ "$nlink" = 1 ] || {
    fm_lifecycle_retire_reason identity-mismatch "$id" "task record is hardlinked"
    return 1
  }
  [ "$(fm_meta_get "$meta" kind)" = "$kind" ] || {
    fm_lifecycle_retire_reason identity-mismatch "$id" "kind does not match the task record"
    return 1
  }
  [ "$(fm_meta_get "$meta" spawn_gen)" = "$gen" ] || {
    fm_lifecycle_retire_reason generation-mismatch "$id" "spawn_gen does not match the task record"
    return 1
  }
  [ "$(fm_meta_get "$meta" backend)" = herdr ] || {
    fm_lifecycle_retire_reason identity-mismatch "$id" "backend does not match the task record"
    return 1
  }
  meta_session=$(fm_meta_get "$meta" session)
  if [ -z "$meta_session" ]; then
    window=$(fm_meta_get "$meta" window)
    meta_session=${window%%:*}
  fi
  [ "$meta_session" = "$session" ] || {
    fm_lifecycle_retire_reason identity-mismatch "$id" "session does not match the task record"
    return 1
  }
  local field key
  while IFS=' ' read -r field key; do
    [ -n "$field" ] || continue
    if ! fm_lifecycle_retire_meta_match "$meta" "$tmp/ep.$index" "$field" "$key"; then
      fm_lifecycle_retire_reason identity-mismatch "$id" "$key is unavailable or does not match the task record"
      return 1
    fi
  done <<'FIELDS'
.window window
.pane_id herdr_pane_id
.workspace_id herdr_workspace_id
.tab_id herdr_tab_id
.process.pid lifecycle_process_pid
.process.identity lifecycle_process_identity
.process.boot_id lifecycle_process_boot_id
.server.socket_path lifecycle_server_socket_path
.server.pid lifecycle_server_pid
.server.identity lifecycle_server_identity
.server.boot_id lifecycle_server_boot_id
FIELDS
  if [ -n "$(fm_meta_get "$meta" endpoint_task_id)" ] && [ "$(fm_meta_get "$meta" endpoint_task_id)" != "$id" ]; then
    fm_lifecycle_retire_reason identity-mismatch "$id" "endpoint_task_id does not match"
    return 1
  fi
  if [ "$kind" = secondmate ]; then
    installed=$(fm_meta_get "$meta" home)
    installed=$(fm_lifecycle_retire_canonical_dir "$installed") || {
      fm_lifecycle_retire_reason identity-mismatch "$id" "secondmate home is not a physical directory"
      return 1
    }
    [ -f "$installed/.fm-secondmate-home" ] && [ ! -L "$installed/.fm-secondmate-home" ] || {
      fm_lifecycle_retire_reason identity-mismatch "$id" "secondmate home marker is missing"
      return 1
    }
    [ "$(sed -n '1p' "$installed/.fm-secondmate-home")" = "$id" ] || {
      fm_lifecycle_retire_reason identity-mismatch "$id" "secondmate home marker names another id"
      return 1
    }
    if ! fm_secondmate_parent_record_parse "$installed/.fm-secondmate-parent"; then
      fm_lifecycle_retire_reason remote-route "$id" "secondmate parent binding is unreadable"
      return 1
    fi
    if [ "$FM_SECONDMATE_PARENT_ROUTE" != local ]; then
      fm_lifecycle_retire_reason remote-route "$id" "remote secondmate homes are out of scope"
      return 1
    fi
    [ "$(fm_lifecycle_retire_canonical_dir "$FM_SECONDMATE_PARENT_HOME")" = "$FM_LIFECYCLE_RETIRE_PARENT" ] || {
      fm_lifecycle_retire_reason identity-mismatch "$id" "parent binding does not match parent_home"
      return 1
    }
    if [ -f "$home/data/secondmates.md" ] && [ ! -L "$home/data/secondmates.md" ]; then
      if ! secondmate_registry_validate_bindings "$home/data/secondmates.md" secondmate_registry_path_key "$id" "$installed"; then
        fm_lifecycle_retire_reason identity-mismatch "$id" "${SECONDMATE_REGISTRY_ERROR:-registry binding does not match}"
        return 1
      fi
      if [ "${SECONDMATE_REGISTRY_MATCH_REMOTE:-0}" = 1 ]; then
        fm_lifecycle_retire_reason remote-route "$id" "registry route is remote"
        return 1
      fi
    fi
    printf '%s\n' "$installed" > "$tmp/installed.$index"
  fi
  if [ -f "$home/state/$id.endpoint-retired" ] && [ ! -L "$home/state/$id.endpoint-retired" ] \
    && [ "$(fm_meta_get "$home/state/$id.endpoint-retired" spawn_gen)" = "$gen" ]; then
    printf 'resume\n'
    return 0
  fi
  printf 'ready\n'
}

fm_lifecycle_retire_foreign_child() {
  local installed=$1 id=$2 child home canon
  [ -d "$installed/state" ] || return 0
  [ ! -L "$installed/state" ] || {
    fm_lifecycle_retire_reason identity-mismatch "$id" "secondmate state directory is a symlink"
    return 1
  }
  for child in "$installed/state"/*.meta; do
    [ -e "$child" ] || continue
    if [ -L "$child" ] || [ ! -f "$child" ]; then
      fm_lifecycle_retire_reason foreign-descendant "$id" "secondmate state has a non-regular task record"
      return 1
    fi
    home=$(fm_meta_get "$child" home)
    [ -n "$home" ] || continue
    canon=$(fm_lifecycle_retire_canonical_dir "$home" 2>/dev/null) || canon=$home
    case "$canon" in
      "$installed"|"$installed"/*) ;;
      *)
        fm_lifecycle_retire_reason foreign-descendant "$id" "a child record points outside the secondmate home"
        return 1
        ;;
    esac
  done
}

fm_lifecycle_retire_obligations() {
  local index=$1 tmp=$FM_LIFECYCLE_RETIRE_TMP home id kind meta state config data wt project mode pr base installed rc=0
  id=$(cat "$tmp/id.$index")
  home=$(jq -r '.home' "$tmp/ep.$index")
  kind=$(jq -r '.kind' "$tmp/ep.$index")
  meta=$home/state/$id.meta
  state=$home/state
  config=$home/config
  data=$home/data
  fm_lifecycle_public_followup_resolve "$home" "$state" "$id" "$kind" 1 || {
    fm_lifecycle_retire_reason obligation-followup "$id" "public follow-up binding could not be resolved"
    return 1
  }
  fm_lifecycle_public_followup_refuse "$id" || {
    fm_lifecycle_retire_reason obligation-followup "$id" "a public reply or parent binding is still unresolved"
    return 1
  }
  pr=$(fm_meta_get "$meta" pr)
  fm_lifecycle_public_followup_warn "$id" "$kind" "$pr" "$meta" || {
    fm_lifecycle_retire_reason obligation-followup "$id" "public follow-up warning could not be written"
    return 1
  }
  if [ "$kind" = secondmate ]; then
    fm_lifecycle_pending_replies_unresolved_refuse "$state" "$id" || {
      fm_lifecycle_retire_reason obligation-pending-reply "$id" "an unresolved pending reply remains"
      return 1
    }
    installed=$(cat "$tmp/installed.$index")
    fm_lifecycle_retire_foreign_child "$installed" "$id" || return 1
    fm_lifecycle_secondmate_children_refuse "$installed" "$id" || {
      fm_lifecycle_retire_reason obligation-children "$id" "the secondmate home still has a task record"
      return 1
    }
  fi
  if [ "$kind" = scout ]; then
    fm_lifecycle_scout_complete "$home" "$state" "$data" "$config" "$id" || {
      fm_lifecycle_retire_reason obligation-scout "$id" "the scout report or its completion gate is not satisfied"
      return 1
    }
  fi
  wt=$(fm_meta_get "$meta" worktree)
  if [ "$kind" = ship ] && [ -n "$wt" ] && [ -d "$wt" ]; then
    project=$(fm_meta_get "$meta" project)
    mode=$(fm_meta_get "$meta" mode)
    base=$(fm_meta_get "$meta" base_branch)
    fm_lifecycle_worktree_safety "$wt" "$kind" "$mode" "$project" "$pr" "$base" || {
      fm_lifecycle_retire_reason obligation-unlanded "$id" "the worktree still has unlanded work"
      return 1
    }
  fi
  fm_lifecycle_backlog_applies "$config" "$data" "$kind" || rc=$?
  case "$rc" in
    0)
      fm_lifecycle_captain_hold_disposition "$home" "$state" "$data" "$config" "$id" || {
        fm_lifecycle_retire_reason obligation-hold "$id" "the captain-hold state could not be read"
        return 1
      }
      printf '%s\n' "$FM_LIFECYCLE_BACKLOG_TRANSITION" > "$tmp/transition.$index"
      ;;
    1) printf '%s\n' remove > "$tmp/transition.$index" ;;
    *)
      fm_lifecycle_retire_reason obligation-backlog "$id" "the backlog could not be read"
      return 1
      ;;
  esac
}

fm_lifecycle_retire_need_locks() {
  [ -n "${FM_LIFECYCLE_RETIRE_LOCKS_READY:-}" ] && return 0
  export FM_HOME=$FM_LIFECYCLE_RETIRE_PARENT
  export FM_STATE_OVERRIDE=$FM_LIFECYCLE_RETIRE_PARENT/state
  export STATE=$FM_LIFECYCLE_RETIRE_PARENT/state
  if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_LIFECYCLE_LIB_DIR/fm-wake-lib.sh"
  fi
  if ! command -v fm_lease_forbid_branch >/dev/null 2>&1; then
    # shellcheck source=bin/fm-lease-lib.sh
    . "$FM_LIFECYCLE_LIB_DIR/fm-lease-lib.sh"
  fi
  FM_LIFECYCLE_RETIRE_LOCKS_READY=1
}

fm_lifecycle_retire_hold() {
  local path=$1
  fm_lock_try_acquire "$path" || return 1
  FM_LIFECYCLE_RETIRE_HELD=${path}$'\n'${FM_LIFECYCLE_RETIRE_HELD:-}
}

fm_lifecycle_retire_endpoint_unlock() {
  local path
  [ -n "${FM_LIFECYCLE_RETIRE_HELD:-}" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if command -v fm_lock_release >/dev/null 2>&1; then
      fm_lock_release "$path" || true
    fi
  done <<EOF
$FM_LIFECYCLE_RETIRE_HELD
EOF
  FM_LIFECYCLE_RETIRE_HELD=
}

fm_lifecycle_retire_op_lock() {
  local path=$FM_LIFECYCLE_RETIRE_PARENT/state/.lifecycle-retire.lock
  fm_lock_try_acquire "$path" || {
    fm_lifecycle_retire_reason lock-held "" "the retirement lock is held"
    return 1
  }
  FM_LIFECYCLE_RETIRE_OP_LOCK=$path
}

fm_lifecycle_retire_op_unlock() {
  [ -n "${FM_LIFECYCLE_RETIRE_OP_LOCK:-}" ] || return 0
  if command -v fm_lock_release >/dev/null 2>&1; then
    fm_lock_release "$FM_LIFECYCLE_RETIRE_OP_LOCK" || true
  fi
  FM_LIFECYCLE_RETIRE_OP_LOCK=
}

fm_lifecycle_retire_lease() {
  local index=0 kind id home saved_state rc=0
  saved_state=${STATE:-}
  export STATE=$FM_LIFECYCLE_RETIRE_PARENT/state
  while [ "$index" -lt "$FM_LIFECYCLE_RETIRE_COUNT" ]; do
    index=$((index + 1))
    kind=$(jq -r '.kind' "$FM_LIFECYCLE_RETIRE_TMP/ep.$index")
    [ "$kind" = secondmate ] || continue
    id=$(cat "$FM_LIFECYCLE_RETIRE_TMP/id.$index")
    home=$(jq -r '.home' "$FM_LIFECYCLE_RETIRE_TMP/ep.$index")
    export STATE=$home/state
    fm_lease_forbid_branch "endpoint retirement for $id"
    if command -v fm_lease_guard >/dev/null 2>&1; then
      if ! fm_lease_guard "$id" "endpoint retirement"; then
        fm_lifecycle_retire_reason lock-held "$id" "a supervision lease refuses this retirement"
        rc=1
        break
      fi
      if ! fm_lease_guard_release; then
        rc=1
        break
      fi
    fi
  done
  if [ -n "$saved_state" ]; then
    export STATE=$saved_state
  fi
  return "$rc"
}

fm_lifecycle_retire_lock_endpoint() {
  local index=$1 home id kind meta_lock registry
  home=$(jq -r '.home' "$FM_LIFECYCLE_RETIRE_TMP/ep.$index")
  id=$(cat "$FM_LIFECYCLE_RETIRE_TMP/id.$index")
  kind=$(jq -r '.kind' "$FM_LIFECYCLE_RETIRE_TMP/ep.$index")
  fm_lifecycle_retire_hold "$home/state/.control-$id.lock" || return 1
  meta_lock=$(fm_meta_lock_path "$home/state/$id.meta") || return 1
  fm_lifecycle_retire_hold "$meta_lock" || return 1
  if [ "$kind" = secondmate ]; then
    fm_lifecycle_retire_hold "$home/state/.secondmate-liveness-$id.lock" || return 1
    registry=$(secondmate_registry_lock_path "$home/state")
    fm_lifecycle_retire_hold "$registry" || return 1
    fm_lifecycle_retire_hold "$home/state/.backlog-handoff-$id.lock" || return 1
  fi
}

fm_lifecycle_retire_progress_has() {
  local id=$1 gen=$2 progress=$FM_LIFECYCLE_RETIRE_JOURNAL/progress.json
  [ -e "$progress" ] || return 1
  if [ -L "$progress" ] || [ ! -f "$progress" ]; then
    fm_lifecycle_retire_reason journal-corrupt "" "progress record is not a regular file"
    return 2
  fi
  if ! jq -e '.completed | type == "array"' "$progress" >/dev/null 2>&1; then
    fm_lifecycle_retire_reason journal-corrupt "" "progress record is not readable"
    return 2
  fi
  jq -e --arg id "$id" --arg gen "$gen" \
    'any(.completed[]; .task_id == $id and .spawn_gen == $gen)' \
    "$progress" >/dev/null 2>&1
}

fm_lifecycle_retire_write_progress() {
  local tmp=$FM_LIFECYCLE_RETIRE_TMP
  fm_lifecycle_retire_refresh_arrays || return 1
  jq '{completed:[.[] | {task_id, spawn_gen, disposition, outcome}], blocked:null}' \
    "$tmp/endpoints.json" > "$tmp/progress.body" || return 1
  fm_lifecycle_retire_publish_file "$FM_LIFECYCLE_RETIRE_JOURNAL/progress.json" "$tmp/progress.body"
}

fm_lifecycle_publish_endpoint_retired() {
  local state=$1 id=$2 gen=$3 op=$4 digest=$5 mode=$6 session=$7 retain=$8 dest tmp
  dest=$state/$id.endpoint-retired
  [ -L "$dest" ] && return 1
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    return 1
  fi
  if [ -f "$dest" ] && [ "$(fm_meta_get "$dest" spawn_gen)" = "$gen" ]; then
    return 0
  fi
  tmp=$(mktemp "$state/.endpoint-retired.XXXXXX") || return 1
  {
    printf 'schema=fm-endpoint-retired.v1\n'
    printf 'task_id=%s\n' "$id"
    printf 'spawn_gen=%s\n' "$gen"
    printf 'operation_id=%s\n' "$op"
    printf 'request_digest=%s\n' "$digest"
    printf 'absence_mode=%s\n' "$mode"
    printf 'session=%s\n' "$session"
    printf 'retain_home=%s\n' "$retain"
    if [ -n "${9:-}" ]; then
      printf 'installed_home=%s\n' "${9}"
    fi
    printf 'retired_at=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_lifecycle_retire_one() {
  local index=$1 tmp=$FM_LIFECYCLE_RETIRE_TMP id gen home kind retain meta state data config
  local identity wt project mode transition marker target tasktmp busy outcome parent_id installed installed_home note_home rc=0
  id=$(cat "$tmp/id.$index")
  gen=$(jq -r '.spawn_gen' "$tmp/ep.$index")
  home=$(jq -r '.home' "$tmp/ep.$index")
  kind=$(jq -r '.kind' "$tmp/ep.$index")
  retain=$(jq -r '.retain_home' "$tmp/ep.$index")
  parent_id=$(cat "$tmp/parent.$index")
  rc=0
  fm_lifecycle_retire_progress_has "$id" "$gen" || rc=$?
  if [ "$rc" -eq 0 ]; then
    outcome=$(jq -r --arg id "$id" --arg gen "$gen" '.completed[] | select(.task_id==$id and .spawn_gen==$gen) | .outcome' "$FM_LIFECYCLE_RETIRE_JOURNAL/progress.json")
    note_home=$(fm_lifecycle_retire_note_home "$index" "$home" "$retain")
    fm_lifecycle_retire_note "$id" "$gen" "$note_home" already "$retain" "${outcome:-already}"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    return 1
  fi
  rc=0
  if ! fm_lifecycle_retire_lock_endpoint "$index"; then
    fm_lifecycle_retire_endpoint_unlock
    fm_lifecycle_retire_reason lock-held "$id" "an endpoint lock is held"
    return 1
  fi
  identity=$(fm_lifecycle_retire_meta_identity "$index") || {
    fm_lifecycle_retire_endpoint_unlock
    return 1
  }
  if [ "$identity" = already ]; then
    note_home=$(fm_lifecycle_retire_note_home "$index" "$home" "$retain")
    fm_lifecycle_retire_note "$id" "$gen" "$note_home" already "$retain" already
    fm_lifecycle_retire_write_progress || {
      fm_lifecycle_retire_endpoint_unlock
      return 1
    }
    fm_lifecycle_retire_endpoint_unlock
    return 0
  fi
  fm_lifecycle_retire_prove || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lifecycle_retire_endpoint_unlock
    return "$rc"
  fi
  fm_lifecycle_retire_obligations "$index" || {
    fm_lifecycle_retire_endpoint_unlock
    return 1
  }
  if [ -n "$parent_id" ]; then
    if fm_lifecycle_retire_fault child-cleanup; then
      fm_lifecycle_retire_endpoint_unlock
      return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
    fi
  elif fm_lifecycle_retire_fault parent-retirement; then
    fm_lifecycle_retire_endpoint_unlock
    return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
  fi
  meta=$home/state/$id.meta
  state=$home/state
  data=$home/data
  config=$home/config
  wt=$(fm_meta_get "$meta" worktree)
  if [ "$kind" = ship ] && [ -n "$wt" ] && [ -d "$wt" ]; then
    project=$(fm_meta_get "$meta" project)
    fm_lifecycle_return_task_worktree "$id" "$wt" "$project" || {
      fm_lifecycle_retire_endpoint_unlock
      fm_lifecycle_retire_reason obligation-unlanded "$id" "the worktree could not be returned"
      return 1
    }
    target=$(fm_meta_get "$meta" window)
    fm_lifecycle_reap_task_processes "$id" herdr "$target" "endpoint" "$wt" || {
      fm_lifecycle_retire_endpoint_unlock
      fm_lifecycle_retire_reason process-unknown "$id" "worktree processes could not be reaped"
      return 1
    }
  fi
  outcome=skipped
  if [ "$kind" != secondmate ]; then
    if fm_lifecycle_retire_fault outcome-handoff; then
      fm_lifecycle_retire_endpoint_unlock
      return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
    fi
    # The reconcile report prints its notice on stdout. This command's stdout is the JSON result.
    if ! fm_lifecycle_deliver_outcome "$home" "$state" "$data" "$id" >&2; then
      fm_lifecycle_retire_endpoint_unlock
      fm_lifecycle_retire_reason outcome-undelivered "$id" "the parent channel did not accept the outcome"
      return 2
    fi
    if fm_lifecycle_retire_fault outcome-receipt; then
      fm_lifecycle_retire_endpoint_unlock
      return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
    fi
    outcome=delivered
  fi
  installed_home=
  if [ "$kind" = secondmate ] && [ -f "$tmp/installed.$index" ]; then
    installed_home=$(cat "$tmp/installed.$index")
  fi
  if ! fm_lifecycle_publish_endpoint_retired "$state" "$id" "$gen" "$FM_LIFECYCLE_RETIRE_OP" \
    "$FM_LIFECYCLE_RETIRE_DIGEST" "$FM_LIFECYCLE_RETIRE_MODE" "$FM_LIFECYCLE_RETIRE_SESSION" "$retain" \
    "$installed_home"; then
    fm_lifecycle_retire_endpoint_unlock
    fm_lifecycle_retire_reason identity-mismatch "$id" "the retirement record could not be published"
    return 1
  fi
  if fm_lifecycle_retire_fault backlog-transition || fm_lifecycle_retire_fault metadata-transition; then
    fm_lifecycle_retire_endpoint_unlock
    return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
  fi
  target=$(fm_meta_get "$meta" window)
  tasktmp=$(fm_meta_get "$meta" tasktmp)
  busy=$(fm_meta_get "$meta" busy_gen)
  fm_lifecycle_retire_task_artifacts "$home" "$state" "$config" "$id" herdr "$target" "$tasktmp" "$busy" || {
    fm_lifecycle_retire_endpoint_unlock
    fm_lifecycle_retire_reason incomplete "$id" "endpoint artifacts could not be retired"
    return 2
  }
  transition=$(cat "$tmp/transition.$index")
  if [ "$transition" = remove ]; then
    fm_lifecycle_record_retire "$state" "$data" "$id" remove "" || {
      fm_lifecycle_retire_endpoint_unlock
      fm_lifecycle_retire_reason incomplete "$id" "the task record could not be removed"
      return 2
    }
  else
    marker=$(fm_backlog_close_marker_path "$state" "$id") || {
      fm_lifecycle_retire_endpoint_unlock
      return 1
    }
    mode=$(fm_meta_get "$meta" mode)
    pr=$(fm_meta_get "$meta" pr)
    fm_lifecycle_backlog_done_args "$kind" "$mode" "$pr" "$data" "$id" || {
      fm_lifecycle_retire_endpoint_unlock
      return 1
    }
    fm_lifecycle_record_retire "$state" "$data" "$id" "$transition" "$marker" \
      ${FM_LIFECYCLE_DONE_ARGS[@]+"${FM_LIFECYCLE_DONE_ARGS[@]}"} || {
      fm_lifecycle_retire_endpoint_unlock
      fm_lifecycle_retire_reason incomplete "$id" "the backlog transition could not be recorded"
      return 2
    }
  fi
  note_home=$(fm_lifecycle_retire_note_home "$index" "$home" "$retain")
  fm_lifecycle_retire_note "$id" "$gen" "$note_home" retired "$retain" "$outcome"
  fm_lifecycle_retire_write_progress || {
    fm_lifecycle_retire_endpoint_unlock
    return 2
  }
  fm_lifecycle_retire_endpoint_unlock
}

fm_lifecycle_retire_journal_request() {
  local journal=$FM_LIFECYCLE_RETIRE_JOURNAL tmp=$FM_LIFECYCLE_RETIRE_TMP existing digest entry
  if [ -L "$journal" ] || { [ -e "$journal" ] && [ ! -d "$journal" ]; }; then
    fm_lifecycle_retire_reason journal-corrupt "" "retirement journal path is not a directory"
    return 1
  fi
  if [ -d "$journal" ]; then
    for entry in "$journal"/*; do
      [ -e "$entry" ] || continue
      case "${entry##*/}" in
        request.json|proof.json|progress.json|result.json) ;;
        *)
          fm_lifecycle_retire_reason journal-foreign "" "retirement journal contains an unexpected file"
          return 1
          ;;
      esac
    done
  fi
  if [ -f "$journal/request.json" ]; then
    digest=$(fm_lifecycle_retire_sha256_text "$(tr -d '\n' < "$journal/request.json")") || return 1
    if [ "$digest" != "$FM_LIFECYCLE_RETIRE_DIGEST" ]; then
      fm_lifecycle_retire_reason digest-mismatch "" "operation id is already bound to another request"
      return 1
    fi
    return 0
  fi
  if fm_lifecycle_retire_fault journal-request; then
    return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
  fi
  mkdir -p -- "$journal" || return 1
  fm_lifecycle_retire_publish_file "$journal/request.json" "$tmp/canonical.json" || return 1
}

fm_lifecycle_retire_execute_body() {
  local request=$1 index rc=0 any=0 retry
  FM_LIFECYCLE_RETIRE_OUT=${2:-}
  fm_lifecycle_retire_tmp_begin || return "$FM_LIFECYCLE_RETIRE_USAGE_RC"
  if ! fm_lifecycle_retire_load "$request"; then
    fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || return 1
    return 1
  fi
  if fm_lifecycle_retire_completed_same; then
    fm_lifecycle_retire_emit_already || return 1
    return 0
  fi
  fm_lifecycle_retire_need_locks || return 1
  if ! fm_lifecycle_retire_lease; then
    fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || return 1
    return 1
  fi
  fm_lifecycle_retire_op_lock || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || return 1
    return 1
  fi
  rc=0
  fm_lifecycle_retire_journal_request || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "$FM_LIFECYCLE_RETIRE_FAULT_RC" ]; then
      return "$rc"
    fi
    fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || return 1
    return "$rc"
  fi
  if fm_lifecycle_retire_fault journal-proof; then
    return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
  fi
  rc=0
  fm_lifecycle_retire_prove || rc=$?
  if [ "$rc" -ne 0 ]; then
    retry=$(fm_lifecycle_retire_retry_for)
    if [ "$rc" -eq 2 ]; then
      fm_lifecycle_retire_report incomplete "$retry" 1 || return 1
      return 2
    fi
    fm_lifecycle_retire_report refused "$retry" 1 || return 1
    return 1
  fi
  fm_lifecycle_retire_publish_file "$FM_LIFECYCLE_RETIRE_JOURNAL/proof.json" "$FM_LIFECYCLE_RETIRE_TMP/proof.json" || return 1
  while IFS= read -r index; do
    [ -n "$index" ] || continue
    rc=0
    fm_lifecycle_retire_one "$index" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ -s "$FM_LIFECYCLE_RETIRE_TMP/endpoint-notes" ]; then
        any=1
      fi
      if [ "$rc" -eq "$FM_LIFECYCLE_RETIRE_FAULT_RC" ]; then
        return "$rc"
      fi
      retry=$(fm_lifecycle_retire_retry_for)
      if [ "$any" = 1 ] || [ "$rc" -eq 2 ]; then
        fm_lifecycle_retire_report incomplete "$retry" 1 || return 1
        return 2
      fi
      fm_lifecycle_retire_report refused "$retry" 1 || return 1
      return 1
    fi
  done < "$FM_LIFECYCLE_RETIRE_TMP/ordered"
  if fm_lifecycle_retire_fault final-receipt; then
    return "$FM_LIFECYCLE_RETIRE_FAULT_RC"
  fi
  fm_lifecycle_retire_report complete none 1 || return 1
  return 0
}

fm_lifecycle_retire_execute() {
  local rc=0
  FM_LIFECYCLE_RETIRE_HELD=
  FM_LIFECYCLE_RETIRE_OP_LOCK=
  fm_lifecycle_retire_execute_body "$@" || rc=$?
  fm_lifecycle_retire_endpoint_unlock
  fm_lifecycle_retire_op_unlock
  fm_lifecycle_retire_tmp_end
  return "$rc"
}

fm_lifecycle_retire_inspect() {
  local rc=0
  FM_LIFECYCLE_RETIRE_OUT=${2:-}
  fm_lifecycle_retire_tmp_begin || return "$FM_LIFECYCLE_RETIRE_USAGE_RC"
  if ! fm_lifecycle_retire_load "$1"; then
    fm_lifecycle_retire_report refused none 0 || rc=1
    fm_lifecycle_retire_tmp_end
    [ "$rc" -eq 0 ] || return 1
    return 0
  fi
  if fm_lifecycle_retire_completed_same; then
    fm_lifecycle_retire_emit_already || rc=1
    fm_lifecycle_retire_tmp_end
    return "$rc"
  fi
  if ! fm_lifecycle_retire_prove; then
    rc=$?
    if [ "$rc" -eq 2 ]; then
      fm_lifecycle_retire_report incomplete "$(fm_lifecycle_retire_retry_for)" 0 || rc=1
    else
      fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || rc=1
    fi
    fm_lifecycle_retire_tmp_end
    return 0
  fi
  # Obligations are diagnostic here. A failure refuses the report and writes nothing in the home.
  local index
  while IFS= read -r index; do
    [ -n "$index" ] || continue
    if ! fm_lifecycle_retire_meta_identity "$index" >/dev/null; then
      fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || true
      fm_lifecycle_retire_tmp_end
      return 0
    fi
    if ! fm_lifecycle_retire_obligations "$index"; then
      fm_lifecycle_retire_report refused "$(fm_lifecycle_retire_retry_for)" 0 || true
      fm_lifecycle_retire_tmp_end
      return 0
    fi
  done < "$FM_LIFECYCLE_RETIRE_TMP/ordered"
  fm_lifecycle_retire_report ready none 0 || rc=1
  fm_lifecycle_retire_tmp_end
  return "$rc"
}

fm_lifecycle_retire_result() {
  local home=$1 op=$2 result json status
  FM_LIFECYCLE_RETIRE_OUT=${3:-}
  fm_lifecycle_retire_tmp_begin || return "$FM_LIFECYCLE_RETIRE_USAGE_RC"
  case "$op" in
    ''|*[!A-Za-z0-9._-]*)
      fm_lifecycle_retire_tmp_end
      return "$FM_LIFECYCLE_RETIRE_USAGE_RC"
      ;;
  esac
  home=$(fm_lifecycle_retire_canonical_dir "$home") || {
    fm_lifecycle_retire_reason bad-request "" "home is not a physical directory"
    fm_lifecycle_retire_report refused none 0 >/dev/null || true
    fm_lifecycle_retire_tmp_end
    return 1
  }
  result=$home/state/lifecycle-retire/$op/result.json
  if [ ! -f "$result" ] || [ -L "$result" ]; then
    FM_LIFECYCLE_RETIRE_OP=$op
    FM_LIFECYCLE_RETIRE_PARENT=$home
    fm_lifecycle_retire_reason result-absent "" "no retirement result is recorded"
    fm_lifecycle_retire_report incomplete same-request 0 || true
    fm_lifecycle_retire_tmp_end
    return 2
  fi
  json=$(cat "$result") || {
    fm_lifecycle_retire_tmp_end
    return 1
  }
  status=$(printf '%s' "$json" | jq -r '.status') || status=
  fm_lifecycle_retire_emit_json "$json" || {
    fm_lifecycle_retire_tmp_end
    return 1
  }
  fm_lifecycle_retire_tmp_end
  case "$status" in
    complete|already-retired) return 0 ;;
    incomplete) return 2 ;;
    *) return 1 ;;
  esac
}
