# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns an absent binary into the operator-facing MISSING diagnostic and an
# incompatible installed build into OUTDATED, which keeps an older build from
# reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

# shellcheck source=bin/fm-bash-compat-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd -- "${d:-/}" && pwd)/fm-bash-compat-lib.sh"
FM_QUOTA_AXI_MIN=0.1.51
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
#   quota_applicable($provider_row; $model)
#                                  the effective-availability rows that bound a
#                                  model. Cursor splits its all_models minimum
#                                  into pools (auto/composer by auto_usage and
#                                  included_usage, named API models by
#                                  api_usage) so api_usage does not bound auto.
#                                  No Cursor window is confirmed as billing
#                                  grok-* models (grok_bot is the separate Grok
#                                  Bot meter), so grok-* takes the conservative
#                                  api pool unless quota-axi emits pool:grok;
#                                  an unrecognized model keeps the all_models
#                                  minimum. A real pool:<name> row from
#                                  quota-axi wins. Deriving a row from windows,
#                                  ranked by its own remaining percent, is the
#                                  fallback for quota-axi builds without pool
#                                  rows; the default TOON has no windows, so it
#                                  stays collapsed until those builds are gone.
#   quota_scope_rows($provider_row; $model; $scope)
#                                  the rows a floor on $scope reads for a model:
#                                  on Cursor, all_models means the model's pool
#                                  and pool:<name> resolves real or derived.
#   quota_provider_rows($provider_row)
#                                  the rows a provider-wide reader judges with
#                                  no model in hand: on Cursor, its default
#                                  auto pool replaces all_models and the other
#                                  pools.
#   quota_below_pool_floor($row)   true when a known Cursor api or grok pool row
#                                  sits under cursor_api_pool_floor.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
  def cursor_pool($model):
    ($model | sub("^model:"; "") | ascii_downcase) as $t |
    if $t == "" or $t == "default" or $t == "auto" or $t == "composer" or ($t | startswith("composer-")) then "auto"
    elif ($t | test("^(cursor-)?grok-")) then "grok"
    elif ($t | test("^(claude|gpt|gemini|o[0-9])")) then "api"
    else null end;
  def cursor_api_pool_floor: 5;
  def cursor_pool_row($p; $pool):
    ([($p.quotaSemantics.effectiveAvailability // [])[]
      | select(.scope == "pool:\($pool)" and .status == "known")] | first) as $explicit |
    if $explicit != null then $explicit
    elif $p.quotaSemantics.status == "unknown" then null
    elif $pool == "grok" then cursor_pool_row($p; "api")
    else
      ({auto: ["auto_usage", "included_usage"], api: ["api_usage"]}[$pool // ""] // []) as $ids |
      [($p.windows // [])[] | select(.id as $id | $ids | index($id)) | select((.percentRemaining | type) == "number")] as $ws |
      if ($ws | map(select(.id == $ids[0])) | length) == 0 then null
      else ($ws | map(.percentRemaining) | min) as $min |
        {scope: ("pool:" + $pool), status: "known", effectivePercentRemaining: $min,
         selection: {spendPriority: ($min / 100)},
         runway: {status: (if $min <= 0 then "exhausted_now" else "unknown" end)},
         limitingWindowIds: ($ws | map(select(.percentRemaining == $min) | .id))}
      end
    end;
  def quota_applicable($p; $model):
    (($model // "") | sub("^model:"; "")) as $model_token |
    [($p.quotaSemantics.effectiveAvailability // [])[] | select(.scope as $scope |
      $scope == "all_models" or $scope == "all_products" or
      ($model_token != "" and $model_token != "default" and
       (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
       ($model_token == ($scope | sub("^(model|product):"; ""))))
    )] as $base |
    if $p.provider != "cursor" then $base
    else cursor_pool_row($p; cursor_pool($model_token)) as $pr |
      if $pr == null then $base
      else ($base | map(select(.scope != "all_models"))) + [$pr]
      end
    end;
  def quota_scope_rows($p; $model; $scope):
    (if $p.provider != "cursor" then null
     elif $scope == "all_models" then cursor_pool_row($p; cursor_pool($model))
     elif ($scope | startswith("pool:")) then cursor_pool_row($p; $scope | ltrimstr("pool:"))
     else null end) as $pr |
    if $pr != null then [$pr]
    else [($p.quotaSemantics.effectiveAvailability // [])[] | select(.scope == $scope)]
    end;
  def quota_provider_rows($p):
    ($p.quotaSemantics.effectiveAvailability // []) as $rows |
    (if $p.provider == "cursor" then cursor_pool_row($p; "auto") else null end) as $pr |
    if $pr == null then $rows
    else ($rows | map(select(.scope != "all_models" and (.scope | startswith("pool:") | not)))) + [$pr]
    end;
  def quota_below_pool_floor($r):
    $r.status == "known" and (["pool:api", "pool:grok"] | index($r.scope)) != null and
    $r.effectivePercentRemaining < cursor_api_pool_floor;
'

# fm_quota_axi_version_compatible <version-output>
# True when the printed `quota-axi --version` text meets FM_QUOTA_AXI_MIN.
# Callers that already captured a bounded --version pass that text here so they
# do not launch a second, unbounded version probe.
fm_quota_axi_version_compatible() {
  local output=${1-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  fm_quota_axi_version_compatible "$output"
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

# Reads the whole table before answering: leaving the loop early closes the
# pipe mid-write, and where SIGPIPE is ignored the writer prints a broken-pipe
# error on stderr.
fm_quota_single_provider_for_harness() {
  local harness provider found=''
  while read -r harness provider; do
    [ -z "$found" ] && [ "$harness" = "$1" ] && found=$provider || :
  done < <(fm_quota_single_provider_table)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}
