#!/usr/bin/env bash
# Token-free guard for Codex's installed model catalog and Firstmate's max validator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_CATALOG_LIVE codex jq

catalog="${CODEX_HOME:-${HOME:-}/.codex}/models_cache.json"
version=$(codex --version) || fail 'installed Codex did not report its version'
[ -r "$catalog" ] || fail "$version catalog is not readable: $catalog"
model=$(jq -er '
  .models[]
  | select(type == "object" and (.slug | type) == "string")
  | select([.supported_reasoning_levels[]?.effort] | index("max") != null)
  | .slug
' "$catalog" 2>/dev/null | head -1) || fail "$version catalog has no model advertising max: $catalog"
[ -n "$model" ] || fail "$version catalog has no model advertising max: $catalog"

env -u FM_CODEX_MODELS_CACHE "$ROOT/bin/fm-harness.sh" validate-native-effort codex "$model" max \
  || fail "$version validator rejected catalog-advertised max for $model"

unsupported=$(jq -r '
  .models[]
  | select(type == "object" and (.slug | type) == "string")
  | select([.supported_reasoning_levels[]?.effort] | index("max") == null)
  | .slug
' "$catalog" 2>/dev/null | head -1) || fail "$version catalog could not be parsed: $catalog"
if [ -n "$unsupported" ] && env -u FM_CODEX_MODELS_CACHE "$ROOT/bin/fm-harness.sh" validate-native-effort codex "$unsupported" max >/dev/null 2>&1; then
  fail "$version validator accepted max for unadvertised model $unsupported"
fi

printf 'ok - %s on %s: catalog advertises max for %s; validator agrees; unsupported=%s; no Codex model launched\n' \
  "$version" "$(date -u +%Y-%m-%d)" "$model" "${unsupported:-none-listed}"
