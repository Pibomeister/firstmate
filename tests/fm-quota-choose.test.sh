#!/usr/bin/env bash
# Unit tests for bin/fm-quota-choose.sh.
# Drives the public argv interface with a mocked quota-axi JSON source.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-choose.XXXXXX")
FIXTURE="$LAB/quota.json"
MALFORMED="$LAB/malformed.json"
MULTI_JSON="$LAB/multi-json.json"
DUPLICATE="$LAB/duplicate.json"
OUT_OF_RANGE="$LAB/out-of-range.json"
INVALID_RUNWAY="$LAB/invalid-runway.json"
INVALID_AVAILABILITY="$LAB/invalid-availability.json"
EMPTY_SCOPE="$LAB/empty-scope.json"
WHITESPACE_PROVIDER="$LAB/whitespace-provider.json"
WHITESPACE_SCOPE="$LAB/whitespace-scope.json"
UNKNOWN_EXHAUSTED="$LAB/unknown-exhausted.json"
KNOWN_UNKNOWN="$LAB/known-unknown.json"
KNOWN_EMPTY="$LAB/known-empty.json"
SEMANTICS_MISMATCH="$LAB/semantics-mismatch.json"
PARTIAL="$LAB/partial.json"
NO_APPLICABLE="$LAB/no-applicable.json"
APPLICABLE_VETO="$LAB/applicable-veto.json"
MUSE_EXHAUSTED="$LAB/muse-exhausted.json"
MUSE_POSITIVE="$LAB/muse-positive.json"
AGY_POSITIVE="$LAB/agy-positive.json"
TOON="$LAB/quota.toon"
RENDERER_TOON="$LAB/renderer-quota.toon"
EMPTY_TOON="$LAB/empty-quota.toon"
EMPTY_ARRAY_TOON="$LAB/empty-array-quota.toon"
INLINE_ATTENTION_TOON="$LAB/inline-attention-quota.toon"
WHITESPACE_ATTENTION_TOON="$LAB/whitespace-attention-quota.toon"
TRUNCATED_ZERO_TOON="$LAB/truncated-zero-quota.toon"
MALFORMED_ZERO_TOON="$LAB/malformed-zero-quota.toon"
LEADING_GARBAGE_TOON="$LAB/leading-garbage-quota.toon"
LEADING_GARBAGE_NONZERO_TOON="$LAB/leading-garbage-nonzero-quota.toon"
TRAILING_GARBAGE_NONZERO_TOON="$LAB/trailing-garbage-nonzero-quota.toon"
TRUNCATED_NONZERO_TOON="$LAB/truncated-nonzero-quota.toon"
MALFORMED_COUNTED_TOON="$LAB/malformed-counted-quota.toon"
UNKNOWN_EXHAUSTED_TOON="$LAB/unknown-exhausted-quota.toon"
TRAILING_EMPTY_TOON="$LAB/trailing-empty-quota.toon"
QUOTED_TOON="$LAB/quoted-quota.toon"
SCHEMA6="$LAB/schema6.json"
SCHEMA5_PAIR="$LAB/schema5-pair.json"
SCHEMA6_KEYLESS="$LAB/schema6-keyless.json"
SCHEMA6_DUPLICATE="$LAB/schema6-duplicate.json"
SCHEMA6_TOON="$LAB/schema6-quota.toon"
FAKEBIN="$LAB/fakebin"
CALLS="$LAB/calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN"

cat > "$FIXTURE" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "kimi",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "runway": { "status": "projected_exhaustion" }
          },
          {
            "scope": "model:codex_bengalfox",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "pi",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 50,
            "runway": { "status": "through_reset" }
          }
        ]
      }
    },
    {
      "provider": "claude",
      "windows": [],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 0.5,
            "runway": { "status": "through_reset" }
          },
          {
            "scope": "model:fable",
            "status": "known",
            "effectivePercentRemaining": 0,
            "runway": { "status": "exhausted_now" }
          }
        ]
      }
    },
    {
      "provider": "cursor",
      "windows": [],
      "quotaSemantics": {
        "status": "unknown",
        "effectiveAvailability": []
      }
    }
  ]
}
JSON

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "${QUOTA_AXI_CALLS:?}"
if [ "${1:-}" = "--version" ]; then
  echo "quota-axi 0.1.51"
  exit 0
fi
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" "$FAKEBIN/quota-axi" --json > "$LAB/captured.json"

call_choose() {
  local output rc call_count
  output=$(QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
    PATH="$FAKEBIN:$PATH" "$BIN/fm-quota-choose.sh" "$@")
  rc=$?
  call_count=$(wc -l < "$CALLS" | tr -d '[:space:]')
  [ "$call_count" = 1 ] || fail "helper took an additional quota snapshot"
  printf '%s\n' "$output"
  return "$rc"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

if help=$("$BIN/fm-quota-choose.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq \
  "candidate order and every candidate's provider is the harness's primary family." \
  || fail "help omitted the multi-provider usage restriction"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders the complete header only"

# 1. First candidate with positive effective quota.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default --candidate codex:model:codex_bengalfox --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "first positive: expected 'claude claude-3-5-sonnet', got '$out'"
ok "first positive candidate wins"

# 2. Exhausted provider is skipped.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "exhausted skip: expected 'claude claude-3-5-sonnet', got '$out'"
ok "exhausted provider is skipped"

# 3. No candidates have positive quota.
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate kimi:default 2>/dev/null); then
  fail "no positive: expected exit 1, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "no positive: expected 'none', got '$out'"
ok "no positive candidate returns none and exit 1"

# 4. Positional arguments work.
out=$(call_choose --snapshot "$LAB/captured.json" claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "positional: expected 'claude claude-3-5-sonnet', got '$out'"
ok "positional candidates work"

# 5. A model-specific exhausted scope bounds a healthy all-models scope.
if out=$(call_choose --snapshot "$LAB/captured.json" --candidate codex:model:codex_bengalfox 2>/dev/null); then
  fail "specific scope: expected exit 1, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "specific scope: expected 'none', got '$out'"
ok "specific model scope bounds generic quota"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate omp:openai-codex/codex_bengalfox 2>/dev/null); then
  fail "omp prefix: the bare codex model scope did not veto, got exit 0 with '$out'"
fi
[ "$out" = "none" ] || fail "omp prefix: expected 'none' from the exhausted codex model scope, got '$out'"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate omp:openai-codex/codex_other)
[ "$out" = "omp openai-codex/codex_other" ] || fail "omp prefix: expected the provider-wide codex quota to select the prefixed model, got '$out'"
ok "omp openai-codex prefix matches the bare codex model scope"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate omp:ollama/qwen3:8b --candidate claude:claude-3-5-sonnet 2>&1); then
  fail "unmapped omp prefix unexpectedly selected a later candidate"
fi
[ "$err" = "error: omp quota mapping covers only the openai-codex and claude-bridge prefixes: ollama/qwen3:8b" ] || fail "unmapped omp prefix returned: $err"
if err=$(call_choose --snapshot "$LAB/captured.json" --candidate omp 2>&1); then
  fail "bare omp candidate unexpectedly selected"
fi
[ "$err" = "error: omp quota mapping covers only the openai-codex and claude-bridge prefixes: default" ] || fail "bare omp candidate returned: $err"
ok "omp without a mapped prefix fails closed"

out=$(call_choose --snapshot "$LAB/captured.json" --candidate codex:default)
[ "$out" = "codex default" ] || fail "default scope: expected provider-wide quota, got '$out'"
ok "default model uses provider-wide quota"

out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "fractional quota: expected positive candidate, got '$out'"
ok "fractional positive quota is eligible"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate bogus:model --candidate claude:claude-3-5-sonnet 2>&1); then
  fail "unknown harness unexpectedly selected a later candidate"
fi
[ "$err" = "error: unknown harness: bogus" ] || fail "unknown harness returned: $err"
ok "unknown harness fails closed"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate rovo:default 2>&1); then
  fail "trailing unsupported harness was hidden by an earlier selection"
fi
[ "$err" = "error: unknown harness: rovo" ] || fail "trailing unsupported harness returned: $err"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default --candidate 'claude:' 2>&1); then
  fail "trailing empty model was hidden by an earlier selection"
fi
[ "$err" = "error: invalid candidate: claude:" ] || fail "trailing empty model returned: $err"
ok "all candidates are validated before selection"

printf '{"schemaVersion":5,"providers":{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}}\n' > "$MALFORMED"
if err=$(call_choose --snapshot "$MALFORMED" --candidate claude:default 2>&1); then
  fail "malformed provider collection unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "malformed provider data returned: $err"
ok "malformed provider data fails closed"

printf '{"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]}\n' > "$MULTI_JSON"
cat "$LAB/captured.json" >> "$MULTI_JSON"
if err=$(call_choose --snapshot "$MULTI_JSON" --candidate claude:default 2>&1); then
  fail "multiple JSON values unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "multiple JSON values returned: $err"
ok "multiple JSON values fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = []' \
  "$LAB/captured.json" > "$KNOWN_EMPTY"
if err=$(call_choose --snapshot "$KNOWN_EMPTY" --candidate claude:default 2>&1); then
  fail "known-empty quota unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "known-empty quota returned: $err"
ok "known-empty quota fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.status) = "unknown"' \
  "$LAB/captured.json" > "$SEMANTICS_MISMATCH"
if err=$(call_choose --snapshot "$SEMANTICS_MISMATCH" --candidate claude:default 2>&1); then
  fail "unknown semantics with known entries unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "semantics mismatch returned: $err"
ok "semantics and availability statuses must agree"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]' \
  "$LAB/captured.json" > "$UNKNOWN_EXHAUSTED"
if out=$(call_choose --snapshot "$UNKNOWN_EXHAUSTED" --candidate claude:default 2>/dev/null); then
  fail "unknown headroom with exhausted runway unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "unknown exhausted quota returned: $out"
ok "exhausted runway vetoes unknown headroom"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"all_models","status":"unknown","runway":{"status":"unknown"}}]' \
  "$LAB/captured.json" > "$KNOWN_UNKNOWN"
if out=$(call_choose --snapshot "$KNOWN_UNKNOWN" --candidate claude:default 2>/dev/null); then
  fail "unknown headroom unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "unknown headroom returned: $out"
ok "unknown headroom is not positive quota"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.status) = "partial" |
    (.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) += [{"scope":"model:unmeasured","status":"unknown","runway":{"status":"unknown"}}]' \
  "$LAB/captured.json" > "$PARTIAL"
out=$(call_choose --snapshot "$PARTIAL" --candidate claude:default)
[ "$out" = "claude default" ] || fail "valid partial semantics were rejected: $out"
ok "partial semantics accept mixed availability"

out=$(call_choose --candidate claude:default < "$LAB/captured.json")
[ "$out" = "claude default" ] || fail "stdin snapshot returned '$out'"
ok "stdin snapshot is accepted"

if err=$(call_choose --snapshot "$LAB/captured.json" --candidate 'claude:' 2>&1); then
  fail "empty model candidate unexpectedly dispatched"
fi
[ "$err" = "error: invalid candidate: claude:" ] || fail "empty model candidate returned: $err"
ok "empty model candidate fails closed"

# A bare harness with no colon means the default model.
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude)
[ "$out" = "claude default" ] || fail "bare harness: expected 'claude default', got '$out'"
ok "bare harness maps to default model"

cat > "$TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,all_models,20,-1,through_reset,high,weekly,2030-01-02T00:00:00Z
  claude,all_models,0.5,-1,through_reset,high,weekly,2030-01-02T00:00:00Z
exhaustion[0]:
attention[0]:
TOON
out=$(call_choose --snapshot "$TOON" --candidate claude:default)
[ "$out" = "claude default" ] || fail "default TOON snapshot returned '$out'"
ok "default TOON snapshot is accepted"

cat > "$RENDERER_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
exhaustion: []
attention: []
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
out=$(call_choose --snapshot "$RENDERER_TOON" --candidate claude:default)
[ "$out" = "claude default" ] || fail "renderer-shaped TOON snapshot returned: $out"
ok "renderer-shaped TOON snapshot is accepted"

printf 'garbage\n' > "$LEADING_GARBAGE_NONZERO_TOON"
cat "$TOON" >> "$LEADING_GARBAGE_NONZERO_TOON"
cat "$TOON" > "$TRAILING_GARBAGE_NONZERO_TOON"
printf 'garbage\n' >> "$TRAILING_GARBAGE_NONZERO_TOON"
sed '$d' "$TOON" > "$TRUNCATED_NONZERO_TOON"
for malformed_toon in \
  "$LEADING_GARBAGE_NONZERO_TOON" \
  "$TRAILING_GARBAGE_NONZERO_TOON" \
  "$TRUNCATED_NONZERO_TOON"; do
  if err=$(call_choose --snapshot "$malformed_toon" --candidate claude:default 2>&1); then
    fail "malformed nonzero TOON unexpectedly dispatched: $malformed_toon"
  fi
  [ "$err" = "error: invalid quota-axi snapshot" ] \
    || fail "malformed nonzero TOON returned: $err"
done
ok "malformed nonzero TOON envelopes fail closed"

cat > "$EMPTY_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
exhaustion[0]:
attention[0]:
TOON
if out=$(call_choose --snapshot "$EMPTY_TOON" --candidate claude:default 2>/dev/null); then
  fail "zero-row TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "zero-row TOON returned: $out"
ok "zero-row TOON has no positive quota"

cat > "$EMPTY_ARRAY_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models,error,"request failed, retry later",none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$EMPTY_ARRAY_TOON" --candidate claude:default 2>/dev/null); then
  fail "empty-array TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "empty-array TOON returned: $out"
ok "empty-array TOON has no positive quota"

cat > "$INLINE_ATTENTION_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention: [{"provider":"claude","scope":"all_models","kind":"unmeasurable","detail":"unknown quota","remedy":"none"}]
TOON
if out=$(call_choose --snapshot "$INLINE_ATTENTION_TOON" --candidate claude:default 2>/dev/null); then
  fail "inline attention TOON unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "inline attention TOON returned: $out"
ok "inline attention TOON has no positive quota"

cat > "$WHITESPACE_ATTENTION_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models ,unmeasurable,unknown quota,none
TOON
if err=$(call_choose --snapshot "$WHITESPACE_ATTENTION_TOON" --candidate claude:default 2>&1); then
  fail "whitespace attention scope unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "whitespace attention scope returned: $err"
ok "TOON attention identities fail closed"

cat > "$TRUNCATED_ZERO_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
TOON
if err=$(call_choose --snapshot "$TRUNCATED_ZERO_TOON" --candidate claude:default 2>&1); then
  fail "truncated zero-row TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "truncated zero-row TOON returned: $err"
ok "truncated zero-row TOON fails closed"

cat > "$MALFORMED_ZERO_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
garbage
TOON
if err=$(call_choose --snapshot "$MALFORMED_ZERO_TOON" --candidate claude:default 2>&1); then
  fail "malformed zero-row TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "malformed zero-row TOON returned: $err"
ok "malformed zero-row TOON fails closed"

cat > "$LEADING_GARBAGE_TOON" <<'TOON'
garbage
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[0]:
exhaustion[0]:
attention[0]:
TOON
if err=$(call_choose --snapshot "$LEADING_GARBAGE_TOON" --candidate claude:default 2>&1); then
  fail "zero-row TOON with leading garbage unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "leading garbage TOON returned: $err"
ok "zero-row TOON rejects leading garbage"

cat > "$MALFORMED_COUNTED_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  garbage
attention[0]:
TOON
if err=$(call_choose --snapshot "$MALFORMED_COUNTED_TOON" --candidate claude:default 2>&1); then
  fail "malformed counted TOON unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "malformed counted TOON returned: $err"
ok "counted TOON rows require every declared field"

cat > "$UNKNOWN_EXHAUSTED_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota: []
exhaustion: []
attention[1]{provider,scope,kind,detail,remedy}:
  claude,all_models,headroom_unknown,"weekly · exhausted_now limited by weekly",none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$UNKNOWN_EXHAUSTED_TOON" --candidate claude:default 2>/dev/null); then
  fail "TOON unknown headroom exhaustion unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "TOON unknown headroom exhaustion returned: $out"
ok "TOON conversion preserves unknown-headroom exhaustion"

cat > "$TRAILING_EMPTY_TOON" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z",
exhaustion[0]:
attention[0]:
TOON
if err=$(call_choose --snapshot "$TRAILING_EMPTY_TOON" --candidate claude:default 2>&1); then
  fail "TOON row with trailing empty field unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi snapshot" ] || fail "trailing empty TOON field returned: $err"
ok "trailing empty TOON fields fail closed"

cat > "$QUOTED_TOON" <<'TOON'
bin: quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,50,-1,through_reset,high,weekly,"2030-01-02T00:00:00Z"
  claude,"model:fable",0,-1,exhausted_now,high,weekly,"2030-01-02T00:00:00Z"
exhaustion[0]:
attention[0]:
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
if out=$(call_choose --snapshot "$QUOTED_TOON" --candidate claude:fable 2>/dev/null); then
  fail "quoted exhausted model scope unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "quoted exhausted model scope returned: $out"
ok "quoted TOON scope vetoes dispatch"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate cursor:default 2>/dev/null); then
  fail "provider-level unknown quota unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "provider-level unknown quota returned: $out"
ok "provider-level unknown quota is not positive"

jq '.providers += [{"provider":"meta","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"runway":{"status":"through_reset"}}]}}]' \
  "$LAB/captured.json" > "$MUSE_POSITIVE"
out=$(call_choose --snapshot "$MUSE_POSITIVE" --candidate muse:default)
[ "$out" = "muse default" ] || fail "supported Muse candidate returned: $out"
ok "Muse candidate is accepted"

jq '.providers += [{"provider":"meta","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]' \
  "$LAB/captured.json" > "$MUSE_EXHAUSTED"
if out=$(call_choose --snapshot "$MUSE_EXHAUSTED" --candidate muse:default 2>/dev/null); then
  fail "Muse candidate dispatched with exhausted Meta quota"
fi
[ "$out" = "none" ] || fail "exhausted Meta quota returned: $out"
ok "Muse uses Meta quota"

jq '.providers += [{"provider":"agy","windows":[],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"runway":{"status":"through_reset"}}]}}]' \
  "$LAB/captured.json" > "$AGY_POSITIVE"
if err=$(call_choose --snapshot "$AGY_POSITIVE" --candidate agy:default 2>&1); then
  fail "legacy quota chooser unexpectedly accepted Agy"
fi
printf '%s\n' "$err" | grep -F 'unknown harness: agy' >/dev/null || fail "legacy Agy rejection changed: $err"
ok "Agy remains resolver-only"

jq '.providers += [.providers[] | select(.provider == "claude")]' "$LAB/captured.json" > "$DUPLICATE"
if err=$(call_choose --snapshot "$DUPLICATE" --candidate claude:default 2>&1); then
  fail "duplicate provider snapshot unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "duplicate provider returned: $err"
ok "duplicate providers fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].scope) = ""' \
  "$LAB/captured.json" > "$EMPTY_SCOPE"
if err=$(call_choose --snapshot "$EMPTY_SCOPE" --candidate claude:default 2>&1); then
  fail "empty quota scope unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "empty quota scope returned: $err"
ok "empty quota scopes fail closed"

jq '(.providers[] | select(.provider == "claude").provider) = " claude" |
    (.providers[] | select(.provider == " claude").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 0 |
    (.providers[] | select(.provider == " claude").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"' \
  "$LAB/captured.json" > "$WHITESPACE_PROVIDER"
if err=$(call_choose --snapshot "$WHITESPACE_PROVIDER" --candidate claude:default 2>&1); then
  fail "whitespace provider identity unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "whitespace provider returned: $err"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].scope) = "all_models "' \
  "$LAB/captured.json" > "$WHITESPACE_SCOPE"
if err=$(call_choose --snapshot "$WHITESPACE_SCOPE" --candidate claude:default 2>&1); then
  fail "whitespace scope identity unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "whitespace scope returned: $err"
ok "whitespace quota identities fail closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining) = 150' "$LAB/captured.json" > "$OUT_OF_RANGE"
if err=$(call_choose --snapshot "$OUT_OF_RANGE" --candidate claude:default 2>&1); then
  fail "out-of-range quota unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "out-of-range quota returned: $err"
ok "out-of-range quota fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0].runway.status) = "invalid"' "$LAB/captured.json" > "$INVALID_RUNWAY"
if err=$(call_choose --snapshot "$INVALID_RUNWAY" --candidate claude:default 2>&1); then
  fail "invalid runway status unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "invalid runway status returned: $err"
ok "invalid runway status fails closed"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [{"scope":"model:other","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]' \
  "$LAB/captured.json" > "$NO_APPLICABLE"
if out=$(call_choose --snapshot "$NO_APPLICABLE" --candidate claude:fable 2>/dev/null); then
  fail "candidate without applicable quota unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "missing applicable quota returned: $out"
ok "missing applicable quota is not positive"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability) = [
      {"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"exhausted_now"}},
      {"scope":"model:foo","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}
    ]' "$LAB/captured.json" > "$APPLICABLE_VETO"
if out=$(call_choose --snapshot "$APPLICABLE_VETO" --candidate claude:foo 2>/dev/null); then
  fail "provider-wide exhausted scope did not veto the candidate"
fi
[ "$out" = "none" ] || fail "applicable exhausted scope returned: $out"
ok "any exhausted applicable scope vetoes dispatch"

if out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:fable 2>/dev/null); then
  fail "exact named model exhaustion unexpectedly dispatched"
fi
[ "$out" = "none" ] || fail "exact named model returned '$out'"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:fable-2)
[ "$out" = "claude fable-2" ] || fail "named model scope overmatched fable-2: $out"
out=$(call_choose --snapshot "$LAB/captured.json" --candidate claude:default)
[ "$out" = "claude default" ] || fail "named model scope overmatched default: $out"
ok "named model quota matches exact identity only"

jq '(.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[1].status) = "typo"' "$LAB/captured.json" > "$INVALID_AVAILABILITY"
if err=$(call_choose --snapshot "$INVALID_AVAILABILITY" --candidate claude:default 2>&1); then
  fail "invalid availability status unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "invalid availability status returned: $err"
ok "invalid availability status fails closed"

# Schema 6: quota-axi keys every row by provider + accountKey once a provider
# expands to several accounts. Shaped like a real expanded snapshot: two codex
# rows with different keys and percentages plus default-keyed providers.
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 3, "runway": { "status": "projected_exhaustion" } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" } } ] } }
  ]
}
JSON
out=$(call_choose --snapshot "$SCHEMA6" --candidate codex:default --candidate cursor:default)
[ "$out" = "cursor default" ] || fail "schema 6 snapshot returned: $out"
ok "native Codex never infers an account from a Pi lane"

SCHEMA6_NATIVE="$LAB/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 80 | .runway.status = "through_reset"))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
for model in default gpt-5.6-sol; do
  out=$(call_choose --snapshot "$SCHEMA6_NATIVE" --candidate "codex:$model" --candidate cursor:default)
  [ "$out" = "codex $model" ] || fail "native Codex did not select codex-home for $model: $out"
done
jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$LAB/schema6-reversed.json"
out=$(call_choose --snapshot "$LAB/schema6-reversed.json" --candidate codex:default --candidate cursor:default)
[ "$out" = "codex default" ] || fail "native Codex selection depended on row order: $out"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$LAB/schema6-default.json"
out=$(call_choose --snapshot "$LAB/schema6-default.json" --candidate codex:default --candidate cursor:default)
[ "$out" = "codex default" ] || fail "native Codex did not fall back to the default row: $out"
ok "native Codex binds to codex-home before default, independently of model and row order"

jq '.schemaVersion = 5 | .providers |= unique_by(.provider) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
out=$(call_choose --snapshot "$SCHEMA5_PAIR" --candidate codex:default --candidate cursor:default)
[ "$out" = "codex default" ] || fail "schema 5 pair snapshot returned: $out"
ok "the same path still selects from a schema 5 snapshot by provider alone"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$SCHEMA6_KEYLESS"
if err=$(call_choose --snapshot "$SCHEMA6_KEYLESS" --candidate cursor:default 2>&1); then
  fail "schema 6 row without accountKey unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "keyless schema 6 row returned: $err"
jq '.providers[2].accountKey = "openai-codex"' "$SCHEMA6" > "$SCHEMA6_DUPLICATE"
if err=$(call_choose --snapshot "$SCHEMA6_DUPLICATE" --candidate cursor:default 2>&1); then
  fail "duplicate provider + accountKey unexpectedly dispatched"
fi
[ "$err" = "error: invalid quota-axi provider data" ] || fail "duplicate schema 6 key returned: $err"
ok "schema 6 requires accountKey on every row and uniqueness on provider + accountKey"

cat > "$SCHEMA6_TOON" <<'TOON'
bin: ~/.local/bin/quota-axi
description: Report local agent-provider quota windows for routing-aware agents
generatedAt: "2030-01-01T00:00:00Z"
quota[3]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,openai-codex,all_models,3,-1.4788,projected_exhaustion,established,weekly,"2030-01-03T00:00:00Z"
  codex,openai-codex-work,all_models,11,-5.6818,projected_exhaustion,established,weekly,"2030-01-07T00:00:00Z"
  cursor,default,all_models,24,0.3917,projected_exhaustion,established,auto_usage,"2030-01-12T00:00:00Z"
exhaustion[2]{provider,accountKey,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  codex,openai-codex,all_models,11644,"2030-01-01T03:00:00Z",weekly
  codex,openai-codex-work,all_models,11447,"2030-01-01T03:00:00Z",weekly
attention[1]{provider,accountKey,scope,kind,detail,remedy}:
  claude,default,all,auth_required,keychain_prompt_required · reason keychain_access_required,quota-axi --allow-keychain-prompt
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
TOON
out=$(call_choose --snapshot "$SCHEMA6_TOON" --candidate claude:default --candidate codex:default --candidate cursor:default)
[ "$out" = "cursor default" ] || fail "schema 6 TOON snapshot returned: $out"
ok "schema 6 TOON with the accountKey column is accepted"

[ "$(wc -l < "$CALLS" | tr -d '[:space:]')" = 1 ] || fail "helper took an additional quota snapshot"
ok "helper reuses the captured quota snapshot"

lookup_err=$(bash -c '
  trap "" PIPE
  . "$1/fm-quota-axi-lib.sh"
  for _ in $(seq 200); do
    for harness in claude codex grok kimi cursor agy muse; do
      fm_quota_single_provider_for_harness "$harness" >/dev/null
    done
  done
' _ "$BIN" 2>&1 >/dev/null)
[ -z "$lookup_err" ] || fail "provider-table lookup wrote to stderr with SIGPIPE ignored: $lookup_err"
ok "provider-table lookup writes nothing to stderr when SIGPIPE is ignored"

# Pausing the table writer after its first row makes the race deterministic:
# a lookup that stops reading at the claude row closes the pipe before the rest
# of the table is written.
lookup_err=$(bash -c '
  trap "" PIPE
  . "$1/fm-quota-axi-lib.sh"
  table=$(fm_quota_single_provider_table)
  fm_quota_single_provider_table() {
    sed -n 1p <<<"$table"
    sleep 0.2
    sed 1d <<<"$table"
  }
  [ "$(fm_quota_single_provider_for_harness claude)" = claude ] || echo "lookup did not print claude"
' _ "$BIN" 2>&1)
[ -z "$lookup_err" ] || fail "provider-table lookup with a slow table writer wrote to stderr: $lookup_err"
ok "provider-table lookup reads the whole table before answering"

out=$(bash -c 'set -e; . "$1/fm-quota-axi-lib.sh"; fm_quota_single_provider_for_harness claude' _ "$BIN") \
  || fail "provider-table lookup exited nonzero under set -e"
[ "$out" = claude ] || fail "provider-table lookup under set -e printed: $out"
ok "provider-table lookup prints the provider when called directly under set -e"

# Cursor pools: one cursor row carries included/auto/api windows whose joint
# all_models minimum (api_usage) must not bound auto/composer models. Shaped
# like the live quota-axi --json cursor row: grok_bot is a separate product and
# spend_limit is unmeasurable.
CURSOR_POOLS="$LAB/cursor-pools.json"
cat > "$CURSOR_POOLS" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "cursor",
      "windows": [
        { "id": "included_usage", "percentRemaining": 90 },
        { "id": "auto_usage", "percentRemaining": 93 },
        { "id": "api_usage", "percentRemaining": 2 },
        { "id": "spend_limit", "percentRemaining": 100 },
        { "id": "grok_bot", "percentRemaining": 42 }
      ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
        { "scope": "all_models", "status": "known", "effectivePercentRemaining": 2, "runway": { "status": "unknown" } },
        { "scope": "grok_bot", "status": "known", "effectivePercentRemaining": 42, "runway": { "status": "through_reset" } } ] } }
  ]
}
JSON
for model in default auto composer-2.5; do
  out=$(call_choose --snapshot "$CURSOR_POOLS" --candidate "cursor:$model")
  [ "$out" = "cursor $model" ] || fail "cursor auto pool did not pass at 93% for $model: $out"
done
ok "cursor auto and composer models are judged by auto_usage, not api_usage"

# The Cursor api pool has a 5% floor: the live 2% is rejected and 6% passes.
jq '(.providers[0].windows[] | select(.id == "api_usage").percentRemaining) = 0
  | (.providers[0].quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |=
    (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$CURSOR_POOLS" > "$LAB/cursor-pools-api-empty.json"
for model in claude-opus-5-thinking-high gpt-5.6-sol-high gemini-3.7-flash-high; do
  if out=$(call_choose --snapshot "$LAB/cursor-pools-api-empty.json" --candidate "cursor:$model"); then
    fail "named cursor model $model dispatched with api_usage exhausted: $out"
  fi
  out=$(call_choose --snapshot "$LAB/cursor-pools-api-empty.json" --candidate "cursor:$model" --candidate cursor:composer-2.5)
  [ "$out" = "cursor composer-2.5" ] || fail "composer did not stay eligible with api_usage exhausted: $out"
done
if out=$(call_choose --snapshot "$CURSOR_POOLS" --candidate cursor:claude-opus-5-thinking-high); then
  fail "named cursor model passed the api pool floor at 2%: $out"
fi
jq '(.providers[0].windows[] | select(.id == "api_usage").percentRemaining) = 6' "$CURSOR_POOLS" > "$LAB/cursor-pools-api-6.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-api-6.json" --candidate cursor:claude-opus-5-thinking-high)
[ "$out" = "cursor claude-opus-5-thinking-high" ] || fail "named cursor model ignored its api pool headroom: $out"
jq '(.providers[0].windows[] | select(.id == "api_usage").percentRemaining) = 50
  | (.providers[0].windows[] | select(.id == "included_usage").percentRemaining) = 0' "$CURSOR_POOLS" > "$LAB/cursor-pools-included-empty.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-included-empty.json" --candidate cursor:claude-opus-5-thinking-high)
[ "$out" = "cursor claude-opus-5-thinking-high" ] || fail "included_usage bounded the api pool: $out"
ok "cursor named API models are judged by api_usage alone with a 5% floor"

# The window that bills grok-* models through cursor-agent is unconfirmed, so
# they take the conservative api pool and never the unrelated grok_bot window.
for model in grok-4.7-high cursor-grok-4.5-high; do
  if out=$(call_choose --snapshot "$LAB/cursor-pools-api-empty.json" --candidate "cursor:$model"); then
    fail "cursor grok model $model borrowed headroom from another pool: $out"
  fi
done
if out=$(call_choose --snapshot "$CURSOR_POOLS" --candidate cursor:grok-4.7-high); then
  fail "cursor grok model passed the conservative api pool floor at 2%: $out"
fi
jq '(.providers[0].windows[] | select(.id == "grok_bot").percentRemaining) = 0' "$LAB/cursor-pools-api-6.json" > "$LAB/cursor-pools-grokbot-empty.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-grokbot-empty.json" --candidate cursor:grok-4.7-high)
[ "$out" = "cursor grok-4.7-high" ] || fail "unrelated grok_bot window blocked a cursor grok model: $out"
ok "cursor grok models use the conservative api pool and ignore grok_bot"

if out=$(call_choose --snapshot "$LAB/cursor-pools-api-empty.json" --candidate cursor:mystery-model-9); then
  fail "unknown cursor model escaped the all_models minimum: $out"
fi
jq 'del(.providers[0].windows[] | select(.id == "included_usage"))' "$LAB/cursor-pools-api-empty.json" > "$LAB/cursor-pools-no-included.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-no-included.json" --candidate cursor:composer-2.5)
[ "$out" = "cursor composer-2.5" ] || fail "auto pool depended on included_usage being present: $out"
jq 'del(.providers[0].windows)' "$LAB/cursor-pools-api-empty.json" > "$LAB/cursor-pools-nowindows.json"
if out=$(call_choose --snapshot "$LAB/cursor-pools-nowindows.json" --candidate cursor:composer-2.5); then
  fail "cursor without per-window rows stopped using the all_models minimum: $out"
fi
jq '(.providers[0].windows[] | select(.id == "auto_usage").percentRemaining) = 0' "$CURSOR_POOLS" > "$LAB/cursor-pools-auto-empty.json"
if out=$(call_choose --snapshot "$LAB/cursor-pools-auto-empty.json" --candidate cursor:composer-2.5); then
  fail "exhausted auto pool still dispatched: $out"
fi
if out=$(call_choose --snapshot "$CURSOR_POOLS" --candidate cursor:mystery-model-9); then
  fail "unknown cursor model passed the pool floor at 2%: $out"
fi
jq '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 6' "$CURSOR_POOLS" > "$LAB/cursor-pools-all-models-6.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-all-models-6.json" --candidate cursor:mystery-model-9)
[ "$out" = "cursor mystery-model-9" ] || fail "unknown cursor model ignored its all_models headroom: $out"
jq 'del(.providers[0].windows)' "$CURSOR_POOLS" > "$LAB/cursor-pools-collapsed-2.json"
if out=$(call_choose --snapshot "$LAB/cursor-pools-collapsed-2.json" --candidate cursor:claude-opus-5-thinking-high); then
  fail "named cursor model passed the pool floor on a collapsed all_models row: $out"
fi
out=$(call_choose --snapshot "$LAB/cursor-pools-collapsed-2.json" --candidate cursor:composer-2.5)
[ "$out" = "cursor composer-2.5" ] || fail "composer took the pool floor on a collapsed all_models row: $out"
ok "unknown cursor models and missing window rows fall back to the all_models minimum"

jq '(.providers[0].quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |=
    (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
  | .providers[0].quotaSemantics.effectiveAvailability += [
  { "scope": "pool:auto", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" } }]
  | del(.providers[0].windows)' "$CURSOR_POOLS" > "$LAB/cursor-pools-scopes.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-scopes.json" --candidate cursor:composer-2.5)
[ "$out" = "cursor composer-2.5" ] || fail "explicit pool:auto scope was ignored: $out"
jq '.providers[0].quotaSemantics.effectiveAvailability += [
  { "scope": "pool:api", "status": "known", "effectivePercentRemaining": 3, "runway": { "status": "through_reset" } },
  { "scope": "pool:grok", "status": "known", "effectivePercentRemaining": 60, "runway": { "status": "through_reset" } }]' \
  "$LAB/cursor-pools-scopes.json" > "$LAB/cursor-pools-all-scopes.json"
out=$(call_choose --snapshot "$LAB/cursor-pools-all-scopes.json" --candidate cursor:grok-4.7-high)
[ "$out" = "cursor grok-4.7-high" ] || fail "explicit pool:grok scope lost to pool:api: $out"
if out=$(call_choose --snapshot "$LAB/cursor-pools-all-scopes.json" --candidate cursor:gpt-5.6-sol-high); then
  fail "explicit pool:api row escaped the floor: $out"
fi
ok "an explicit pool:<name> scope from quota-axi takes precedence over derived windows"

cat > "$LAB/cursor-pools.toon" <<'TOON'
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[3]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  cursor,all_models,0,0,exhausted_now,high,api_usage,2030-01-02T00:00:00Z
  cursor,pool:auto,90,0.9,through_reset,high,auto_usage,2030-01-02T00:00:00Z
  cursor,pool:api,0,0,exhausted_now,high,api_usage,2030-01-02T00:00:00Z
exhaustion[0]:
attention[0]:
TOON
out=$(call_choose --snapshot "$LAB/cursor-pools.toon" --candidate cursor:composer-2.5)
[ "$out" = "cursor composer-2.5" ] || fail "default TOON pool:auto row was ignored: $out"
if out=$(call_choose --snapshot "$LAB/cursor-pools.toon" --candidate cursor:claude-opus-5-thinking-high); then
  fail "default TOON pool:api row did not block a named model: $out"
fi
ok "a default TOON snapshot with real pool rows splits Cursor"

jq '.providers[0].quotaSemantics = {status: "unknown", effectiveAvailability: [{scope: "all_models", status: "unknown"}]}' "$CURSOR_POOLS" > "$LAB/cursor-pools-unmeasured.json"
if out=$(call_choose --snapshot "$LAB/cursor-pools-unmeasured.json" --candidate cursor:composer-2.5); then
  fail "windows made an unmeasured cursor row dispatchable: $out"
fi
jq '.providers[0].state = {stale: true}
  | .providers[0].quotaSemantics = {status: "partial", effectiveAvailability: [{scope: "all_models", status: "unknown"}]}' "$CURSOR_POOLS" > "$LAB/cursor-pools-stale-partial.json"
if out=$(call_choose --snapshot "$LAB/cursor-pools-stale-partial.json" --candidate cursor:composer-2.5); then
  fail "stale windows made a partial cursor row dispatchable: $out"
fi
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope: "pool:auto", status: "unknown"}]' "$CURSOR_POOLS" > "$LAB/cursor-pools-auto-unknown.json"
if out=$(call_choose --snapshot "$LAB/cursor-pools-auto-unknown.json" --candidate cursor:composer-2.5); then
  fail "windows replaced an unknown pool:auto row: $out"
fi
ok "windows never turn an unmeasured cursor row into known capacity"

call_reroute() {
  PATH="$FAKEBIN:$PATH" "$BIN/fm-quota-reroute.sh" "$@"
}

out=$(call_reroute suggest --snapshot "$LAB/captured.json" \
  --candidate kimi:default --candidate claude:claude-3-5-sonnet)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "reroute skip: expected claude, got '$out'"
ok "suggest skips an exhausted candidate"

if out=$(call_reroute suggest --snapshot "$LAB/captured.json" --candidate kimi:default 2>/dev/null); then
  fail "reroute none: expected exit 1, got '$out'"
fi
[ "$out" = "none" ] || fail "reroute none: expected 'none', got '$out'"
ok "suggest prints none when every candidate is exhausted"

if out=$(call_reroute suggest --snapshot "$LAB/captured.json" --kind secondmate --candidate muse:default 2>/dev/null); then
  fail "secondmate muse should not be eligible, got '$out'"
fi
[ "$out" = "none" ] || fail "secondmate muse: expected none, got '$out'"
ok "suggest drops a candidate unverified for the task kind"

claude_dir="$LAB/claude-mcp"
mkdir -p "$claude_dir"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$claude_dir/.claude.json"
if call_reroute claude-tooling --config-dir "$claude_dir" >/dev/null; then
  :
else
  fail "claude-tooling missed a configured MCP server"
fi
empty_dir="$LAB/claude-empty"
mkdir -p "$empty_dir"
printf '%s\n' '{"mcpServers":{}}' > "$empty_dir/.claude.json"
if call_reroute claude-tooling --config-dir "$empty_dir"; then
  fail "empty mcpServers was treated as Claude-specific tooling"
fi
sig=$(call_reroute claude-tooling --config-dir "$LAB/missing-dir") || fail "a missing config dir must be tooling required"
[ "$sig" = "unreadable Claude config dir" ] || fail "missing dir signal: $sig"
ok "claude-tooling is an MCP server in the config dir; missing dir queues"

clean_wt="$LAB/clean-wt"
mkdir -p "$clean_wt"
if out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$claude_dir" --worktree "$clean_wt" --kind secondmate \
  --candidate codex:default 2>/dev/null); then
  fail "Claude MCP tooling should block a move off Claude, got '$out'"
fi
[ "$out" = "none" ] || fail "tooling gate: expected none, got '$out'"
err=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$claude_dir" --worktree "$clean_wt" --kind secondmate \
  --candidate codex:default 2>&1 >/dev/null) || true
printf '%s\n' "$err" | grep -q 'MCP servers in' \
  || fail "the block must name the MCP signal: $err"
out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --worktree "$clean_wt" --kind secondmate --candidate codex:default)
[ "$out" = "codex default" ] || fail "no Claude-specific signal should allow a Codex pick, got '$out'"
out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$claude_dir" --worktree "$clean_wt" --kind secondmate \
  --candidate claude:claude-3-5-sonnet --candidate codex:default)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "tooling signal should keep a Claude candidate eligible, got '$out'"
ok "suggest keeps Claude candidates when tooling blocks only a move off Claude"

if out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --worktree "$clean_wt" --kind secondmate --candidate codex:default 2>/dev/null); then
  fail "an unresolvable Claude config dir should queue, got '$out'"
fi
[ "$out" = "none" ] || fail "unresolvable dir: expected none, got '$out'"
err=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --kind secondmate --candidate codex:default 2>&1 >/dev/null) || true
printf '%s\n' "$err" | grep -q 'unresolvable worktree' \
  || fail "an omitted worktree must be named unresolvable: $err"

broken_home="$LAB/broken-pin-home"
mkdir -p "$broken_home/config" "$clean_wt"
printf 'not-a-path\n' > "$broken_home/config/claude-account"
if out=$(FM_HOME="$broken_home" call_reroute suggest --snapshot "$LAB/captured.json" \
  --from-harness claude --worktree "$clean_wt" --kind secondmate \
  --candidate codex:default 2>/dev/null); then
  fail "a broken claude-account pin should queue, got '$out'"
fi
[ "$out" = "none" ] || fail "broken pin: expected none, got '$out'"
err=$(FM_HOME="$broken_home" call_reroute suggest --snapshot "$LAB/captured.json" \
  --from-harness claude --worktree "$clean_wt" --kind secondmate \
  --candidate codex:default 2>&1 >/dev/null) || true
printf '%s\n' "$err" | grep -q 'config/claude-account' \
  || fail "broken pin must name the pin file: $err"
sig=$(FM_HOME="$broken_home" call_reroute claude-tooling --worktree "$clean_wt") \
  || fail "claude-tooling must treat a broken pin as a signal"
printf '%s\n' "$sig" | grep -q 'config/claude-account' \
  || fail "claude-tooling broken pin signal: $sig"

out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --kind secondmate \
  --candidate claude:claude-3-5-sonnet --candidate codex:default)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "an omitted worktree should keep a Claude candidate eligible, got '$out'"
ok "an unknown worktree drops only the moves off Claude"

if out=$(FM_HOME="$broken_home" call_reroute suggest --snapshot "$LAB/captured.json" \
  --from-harness claude --worktree "$clean_wt" --kind secondmate \
  --candidate claude:claude-3-5-sonnet --candidate codex:default 2>/dev/null); then
  fail "a broken pin must not yield a Claude pick on the pinned account, got '$out'"
fi
[ "$out" = "none" ] || fail "broken pin with a Claude candidate: expected none, got '$out'"
pinned_home="$LAB/pinned-home"
pinned_user="$LAB/pinned-user"
mkdir -p "$pinned_home/config" "$pinned_user/.claude"
printf 'ordinary\n' > "$pinned_home/config/claude-account"
if out=$(HOME="$pinned_user" FM_HOME="$pinned_home" call_reroute suggest \
  --snapshot "$LAB/captured.json" --from-harness claude --kind ship \
  --candidate claude:claude-3-5-sonnet --candidate codex:default 2>/dev/null); then
  fail "a pinned Claude account with no worktree must not yield a pick, got '$out'"
fi
[ "$out" = "none" ] || fail "pinned account, no worktree: expected none, got '$out'"
ok "an unknown worktree or broken pin never names the pinned Claude account"

out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --worktree "$FM_ROOT" --kind secondmate \
  --candidate codex:default) \
  || fail "a Claude secondmate on an unchanged firstmate home should be able to leave Claude, got '$out'"
[ "$out" = "codex default" ] || fail "firstmate home secondmate: expected codex, got '$out'"
out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --worktree "$FM_ROOT" --kind secondmate \
  --candidate claude:claude-3-5-sonnet --candidate codex:default)
[ "$out" = "claude claude-3-5-sonnet" ] || fail "a firstmate home secondmate should still keep a Claude candidate, got '$out'"
ok "a Claude secondmate whose home is an unchanged firstmate checkout can leave Claude"

ord="$LAB/ordinary-home"
mkdir -p "$ord/.claude"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$ord/.claude.json"
sig=$(HOME="$ord" call_reroute claude-tooling --config-dir "$ord/.claude") \
  || fail "MCP only in \$HOME/.claude.json must be tooling required"
[ "$sig" = "MCP servers in $ord/.claude.json" ] || fail "ordinary .claude.json signal: $sig"

proj_dir="$LAB/projects-mcp"
mkdir -p "$proj_dir"
printf '%s\n' '{"mcpServers":{},"projects":{"/tmp/app":{"mcpServers":{"docs":{"command":"true"}}}}}' \
  > "$proj_dir/.claude.json"
sig=$(call_reroute claude-tooling --config-dir "$proj_dir") \
  || fail ".projects mcpServers must be tooling required"
[ "$sig" = "MCP servers in $proj_dir/.claude.json" ] || fail "project MCP signal: $sig"

mcp_wt="$LAB/mcp-wt"
mkdir -p "$mcp_wt"
printf '%s\n' '{"mcpServers":{}}' > "$mcp_wt/.mcp.json"
if call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$mcp_wt" >/dev/null; then
  :
else
  fail "worktree .mcp.json was not treated as Claude-specific tooling"
fi
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$mcp_wt")
[ "$sig" = "worktree .mcp.json" ] || fail "worktree .mcp.json signal: $sig"

for name in skills hooks agents commands; do
  wt="$LAB/wt-$name"
  mkdir -p "$wt/.claude/$name"
  sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt") \
    || fail "worktree .claude/$name must be tooling required"
  [ "$sig" = "worktree .claude/$name" ] || fail "$name signal: $sig"
done

enabled_mcp="$LAB/enabled-mcp"
mkdir -p "$enabled_mcp"
printf '%s\n' '{"enabledMcpjsonServers":["docs"]}' > "$enabled_mcp/.claude.json"
sig=$(call_reroute claude-tooling --config-dir "$enabled_mcp") \
  || fail "enabledMcpjsonServers must be tooling required"
[ "$sig" = "MCP servers in $enabled_mcp/.claude.json" ] || fail "enabledMcpjsonServers signal: $sig"

acct_settings="$LAB/acct-settings"
mkdir -p "$acct_settings"
printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$acct_settings/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$acct_settings") \
  || fail "account settings.json hooks must be tooling required"
[ "$sig" = "$acct_settings/settings.json .hooks" ] || fail "account hooks signal: $sig"

for name in skills agents commands plugins; do
  acct_dir="$LAB/acct-$name"
  mkdir -p "$acct_dir/$name/some"
  rc=0
  sig=$(call_reroute claude-tooling --config-dir "$acct_dir") || rc=$?
  [ "$rc" -eq 1 ] || fail "account $name must not be a signal, got $rc ($sig)"
  [ -z "$sig" ] || fail "account $name produced: $sig"
done

wt_settings="$LAB/wt-settings"
mkdir -p "$wt_settings/.claude"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$wt_settings/.claude/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_settings") \
  || fail "worktree .claude/settings.json mcpServers must be tooling required"
[ "$sig" = "$wt_settings/.claude/settings.json .mcpServers" ] \
  || fail "worktree settings.json signal: $sig"

wt_local="$LAB/wt-local"
mkdir -p "$wt_local/.claude"
printf '%s\n' '{"enabledPlugins":{"docs":true}}' > "$wt_local/.claude/settings.local.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_local") \
  || fail "worktree settings.local.json enabledPlugins must be tooling required"
[ "$sig" = "$wt_local/.claude/settings.local.json .enabledPlugins" ] \
  || fail "worktree settings.local.json signal: $sig"

# fm-spawn writes firstmate's own busy hooks into a Claude ship or scout's
# settings.local.json; they are not project tooling, so a move off Claude
# stays possible. A project hook beside them is still a signal.
wt_spawn="$LAB/wt-spawn-hooks"
mkdir -p "$wt_spawn/.claude"
busy="'$BIN/fm-busy-event.sh' apply '$LAB/state' 'qr1'"
jq -n --arg submit "$busy busy --gen '1' --source claude-hook --event user-prompt-submit 2>/dev/null || true" \
  --arg stop "touch '$LAB/state/qr1.turnend'; $busy idle --gen '1' --source claude-hook --event stop 2>/dev/null || true" \
  '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$submit}]}],
           Stop:[{hooks:[{type:"command",command:$stop}]}]}}' \
  > "$wt_spawn/.claude/settings.local.json"
if sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_spawn"); then
  fail "firstmate's own spawn hooks must not block a move off Claude: $sig"
fi
out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --worktree "$wt_spawn" --candidate codex:default) \
  || fail "spawn hooks only: suggest should name the non-Claude pick, got '$out'"
[ "$out" = "codex default" ] || fail "spawn hooks only: expected codex, got '$out'"
jq '.hooks.Stop[0].hooks += [{type:"command",command:"./lint.sh"}]' \
  "$wt_spawn/.claude/settings.local.json" > "$LAB/spawn-mixed.json"
mv "$LAB/spawn-mixed.json" "$wt_spawn/.claude/settings.local.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_spawn") \
  || fail "a project hook beside the spawn hooks must still be tooling required"
[ "$sig" = "$wt_spawn/.claude/settings.local.json .hooks" ] \
  || fail "mixed spawn hooks signal: $sig"

# A user hook that only embeds the busy-event path is still a signal.
wt_decoy="$LAB/wt-hook-decoy"
mkdir -p "$wt_decoy/.claude"
jq -n --arg own "$BIN/fm-busy-event.sh" \
  '{hooks:{Stop:[{hooks:[
     {type:"command",command:("true # " + $own)},
     {type:"command",command:($own + " apply '\''x'\'' '\''y'\'' idle --gen '\''1'\'' --source claude-hook --event stop 2>/dev/null || true; curl evil")},
     {type:"command",command:("curl evil; " + $own + " apply '\''x'\'' '\''y'\'' idle --gen '\''1'\'' --source claude-hook --event stop 2>/dev/null || true")}
   ]}]}}' > "$wt_decoy/.claude/settings.local.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_decoy") \
  || fail "a user hook that only embeds the busy-event path must still be tooling required"
[ "$sig" = "$wt_decoy/.claude/settings.local.json .hooks" ] \
  || fail "user-hook decoy signal: $sig"

# A user hook that starts with the quoted own path, then other shell, then a
# well-formed spawn tail, is still a signal. The match is the whole command.
wt_embed="$LAB/wt-hook-embed"
mkdir -p "$wt_embed/.claude"
jq -n --arg own "$BIN/fm-busy-event.sh" \
  '{hooks:{Stop:[{hooks:[
     {type:"command",command:("'\''" + $own + "'\'' apply '\''z'\''; echo USERHOOK; '\'' apply '\''s'\'' '\''i'\'' busy --gen '\''g'\'' --source claude-hook --event stop 2>/dev/null || true")}
   ]}]}}' > "$wt_embed/.claude/settings.local.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_embed") \
  || fail "an embedded-shell busy-hook decoy must still be tooling required"
[ "$sig" = "$wt_embed/.claude/settings.local.json .hooks" ] \
  || fail "embedded-shell decoy signal: $sig"

bad_json="$LAB/bad-json"
mkdir -p "$bad_json"
printf '{not json\n' > "$bad_json/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$bad_json") \
  || fail "invalid JSON must be tooling required"
[ "$sig" = "unreadable $bad_json/settings.json" ] || fail "invalid JSON signal: $sig"

non_object="$LAB/non-object"
mkdir -p "$non_object"
printf '%s\n' '[]' > "$non_object/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$non_object") \
  || fail "a non-object settings.json must be tooling required"
[ "$sig" = "unreadable $non_object/settings.json" ] || fail "non-object signal: $sig"

wt_non_object="$LAB/wt-non-object"
mkdir -p "$wt_non_object/.claude"
printf '%s\n' '[]' > "$wt_non_object/.claude/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_non_object") \
  || fail "a non-object worktree settings.json must be tooling required"
[ "$sig" = "unreadable $wt_non_object/.claude/settings.json" ] \
  || fail "worktree non-object signal: $sig"

proj_scalar="$LAB/proj-scalar"
mkdir -p "$proj_scalar"
printf '%s\n' '{"projects":"not-an-object"}' > "$proj_scalar/.claude.json"
sig=$(call_reroute claude-tooling --config-dir "$proj_scalar") \
  || fail "a scalar .projects must be tooling required"
[ "$sig" = "unreadable $proj_scalar/.claude.json" ] || fail "scalar projects signal: $sig"

home_proj="$LAB/home-proj"
mkdir -p "$home_proj/.claude"
printf '%s\n' '{"projects":"not-an-object"}' > "$home_proj/.claude.json"
sig=$(HOME="$home_proj" call_reroute claude-tooling --config-dir "$home_proj/.claude") \
  || fail "HOME .claude.json scalar .projects must be tooling required"
[ "$sig" = "unreadable $home_proj/.claude.json" ] || fail "HOME scalar projects: $sig"

proj_entry="$LAB/proj-entry"
mkdir -p "$proj_entry"
printf '%s\n' '{"projects":{"/p":"x"}}' > "$proj_entry/.claude.json"
sig=$(call_reroute claude-tooling --config-dir "$proj_entry") \
  || fail "a non-object .projects entry must be tooling required"
[ "$sig" = "unreadable $proj_entry/.claude.json" ] || fail "projects entry signal: $sig"

home_proj_entry="$LAB/home-proj-entry"
mkdir -p "$home_proj_entry/.claude"
printf '%s\n' '{"projects":{"/p":"x"}}' > "$home_proj_entry/.claude.json"
sig=$(HOME="$home_proj_entry" call_reroute claude-tooling --config-dir "$home_proj_entry/.claude") \
  || fail "HOME .claude.json non-object .projects entry must be tooling required"
[ "$sig" = "unreadable $home_proj_entry/.claude.json" ] \
  || fail "HOME projects entry signal: $sig"

mcp_scalar="$LAB/mcp-scalar"
mkdir -p "$mcp_scalar"
printf '%s\n' '{"mcpServers":"not-an-object"}' > "$mcp_scalar/.claude.json"
sig=$(call_reroute claude-tooling --config-dir "$mcp_scalar") \
  || fail "a non-object .mcpServers must be tooling required"
[ "$sig" = "unreadable $mcp_scalar/.claude.json" ] || fail "scalar mcpServers signal: $sig"

proj_mcp_scalar="$LAB/proj-mcp-scalar"
mkdir -p "$proj_mcp_scalar"
printf '%s\n' '{"projects":{"/p":{"mcpServers":"not-an-object"}}}' \
  > "$proj_mcp_scalar/.claude.json"
sig=$(call_reroute claude-tooling --config-dir "$proj_mcp_scalar") \
  || fail "a non-object .projects[].mcpServers must be tooling required"
[ "$sig" = "unreadable $proj_mcp_scalar/.claude.json" ] \
  || fail "nested scalar mcpServers signal: $sig"

acct_plugins_false="$LAB/acct-plugins-false"
mkdir -p "$acct_plugins_false"
printf '%s\n' '{"enabledPlugins":{"docs":false}}' > "$acct_plugins_false/settings.json"
rc=0
sig=$(call_reroute claude-tooling --config-dir "$acct_plugins_false") || rc=$?
[ "$rc" -eq 1 ] || fail "account enabledPlugins must not be a signal, got $rc ($sig)"
[ -z "$sig" ] || fail "account enabledPlugins produced: $sig"

acct_plugins_true="$LAB/acct-plugins-true"
mkdir -p "$acct_plugins_true"
printf '%s\n' '{"enabledPlugins":{"docs":true}}' > "$acct_plugins_true/settings.json"
rc=0
sig=$(call_reroute claude-tooling --config-dir "$acct_plugins_true") || rc=$?
[ "$rc" -eq 1 ] || fail "account enabledPlugins true must not be a signal, got $rc ($sig)"
[ -z "$sig" ] || fail "account enabledPlugins true produced: $sig"

wt_plugins_false="$LAB/wt-plugins-false"
mkdir -p "$wt_plugins_false/.claude"
printf '%s\n' '{"enabledPlugins":{"docs":false}}' > "$wt_plugins_false/.claude/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$wt_plugins_false") \
  || fail "worktree enabledPlugins with all values false must be a signal"
[ "$sig" = "$wt_plugins_false/.claude/settings.json .enabledPlugins" ] \
  || fail "worktree all-false plugins signal: $sig"

empty_acct_dirs="$LAB/empty-acct-dirs"
mkdir -p "$empty_acct_dirs/skills" "$empty_acct_dirs/agents" \
  "$empty_acct_dirs/commands" "$empty_acct_dirs/plugins"
rc=0
sig=$(call_reroute claude-tooling --config-dir "$empty_acct_dirs") || rc=$?
[ "$rc" -eq 1 ] || fail "empty account dirs: expected exit 1, got $rc ($sig)"
[ -z "$sig" ] || fail "empty account dirs produced: $sig"

plugin_skills_only="$LAB/plugin-skills-only"
mkdir -p "$plugin_skills_only/plugins/demo/.claude-plugin" \
  "$plugin_skills_only/plugins/demo/skills/s" \
  "$plugin_skills_only/plugins/demo/agents/a" \
  "$plugin_skills_only/plugins/demo/commands/c"
printf '%s\n' '{"name":"demo"}' \
  > "$plugin_skills_only/plugins/demo/.claude-plugin/plugin.json"
rc=0
sig=$(call_reroute claude-tooling --config-dir "$plugin_skills_only") || rc=$?
[ "$rc" -eq 1 ] || fail "plugin skills/agents/commands must not be a signal, got $rc ($sig)"
[ -z "$sig" ] || fail "plugin skills/agents/commands produced: $sig"

plugin_mcp="$LAB/plugin-mcp"
mkdir -p "$plugin_mcp/plugins/demo"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' \
  > "$plugin_mcp/plugins/demo/.mcp.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_mcp") \
  || fail "plugin .mcp.json must be tooling required"
[ "$sig" = "MCP servers in $plugin_mcp/plugins/demo/.mcp.json" ] \
  || fail "plugin .mcp.json signal: $sig"

plugin_mcp_flat="$LAB/plugin-mcp-flat"
mkdir -p "$plugin_mcp_flat/plugins/demo"
printf '%s\n' '{"docs":{"command":"true"}}' \
  > "$plugin_mcp_flat/plugins/demo/.mcp.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_mcp_flat") \
  || fail "flat plugin .mcp.json must be tooling required"
[ "$sig" = "MCP servers in $plugin_mcp_flat/plugins/demo/.mcp.json" ] \
  || fail "flat plugin .mcp.json signal: $sig"

plugin_mcp_empty="$LAB/plugin-mcp-empty"
mkdir -p "$plugin_mcp_empty/plugins/demo"
printf '%s\n' '{}' > "$plugin_mcp_empty/plugins/demo/.mcp.json"
rc=0
sig=$(call_reroute claude-tooling --config-dir "$plugin_mcp_empty") || rc=$?
[ "$rc" -eq 1 ] || fail "empty plugin .mcp.json must not be a signal, got $rc ($sig)"
[ -z "$sig" ] || fail "empty plugin .mcp.json produced: $sig"

plugin_mcp_link="$LAB/plugin-mcp-link"
mkdir -p "$plugin_mcp_link/real/demo" "$plugin_mcp_link/plugins"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' \
  > "$plugin_mcp_link/real/demo/.mcp.json"
ln -s "$plugin_mcp_link/real/demo" "$plugin_mcp_link/plugins/demo"
sig=$(call_reroute claude-tooling --config-dir "$plugin_mcp_link") \
  || fail "symlinked plugin dir must be tooling required"
[ "$sig" = "MCP servers in $plugin_mcp_link/plugins/demo/.mcp.json" ] \
  || fail "symlinked plugin dir signal: $sig"

plugin_manifest_mcp="$LAB/plugin-manifest-mcp"
mkdir -p "$plugin_manifest_mcp/plugins/demo/.claude-plugin"
printf '%s\n' '{"name":"demo","mcpServers":{"docs":{"command":"true"}}}' \
  > "$plugin_manifest_mcp/plugins/demo/.claude-plugin/plugin.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_manifest_mcp") \
  || fail "plugin.json mcpServers must be tooling required"
[ "$sig" = "MCP servers in $plugin_manifest_mcp/plugins/demo/.claude-plugin/plugin.json" ] \
  || fail "plugin.json mcpServers signal: $sig"

plugin_hooks="$LAB/plugin-hooks"
mkdir -p "$plugin_hooks/plugins/demo/hooks"
printf '%s\n' '{"hooks":{"Stop":[{}]}}' \
  > "$plugin_hooks/plugins/demo/hooks/hooks.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_hooks") \
  || fail "plugin hooks/hooks.json must be tooling required"
[ "$sig" = "$plugin_hooks/plugins/demo/hooks/hooks.json .hooks" ] \
  || fail "plugin hooks/hooks.json signal: $sig"

plugin_manifest_hooks="$LAB/plugin-manifest-hooks"
mkdir -p "$plugin_manifest_hooks/plugins/demo/.claude-plugin"
printf '%s\n' '{"name":"demo","hooks":{"Stop":[{}]}}' \
  > "$plugin_manifest_hooks/plugins/demo/.claude-plugin/plugin.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_manifest_hooks") \
  || fail "plugin.json hooks must be tooling required"
[ "$sig" = "$plugin_manifest_hooks/plugins/demo/.claude-plugin/plugin.json .hooks" ] \
  || fail "plugin.json hooks signal: $sig"

plugin_cache_mcp="$LAB/plugin-cache-mcp"
mkdir -p "$plugin_cache_mcp/plugins/cache/mp/demo/1.0.0"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' \
  > "$plugin_cache_mcp/plugins/cache/mp/demo/1.0.0/.mcp.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_cache_mcp") \
  || fail "cached plugin .mcp.json must be tooling required"
[ "$sig" = "MCP servers in $plugin_cache_mcp/plugins/cache/mp/demo/1.0.0/.mcp.json" ] \
  || fail "cached plugin .mcp.json signal: $sig"

plugin_marketplace_mcp="$LAB/plugin-marketplace-mcp"
mkdir -p "$plugin_marketplace_mcp/plugins/marketplaces/mp/demo"
printf '%s\n' '{"docs":{"command":"true"}}' \
  > "$plugin_marketplace_mcp/plugins/marketplaces/mp/demo/.mcp.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_marketplace_mcp") \
  || fail "marketplace plugin .mcp.json must be tooling required"
[ "$sig" = "MCP servers in $plugin_marketplace_mcp/plugins/marketplaces/mp/demo/.mcp.json" ] \
  || fail "marketplace plugin .mcp.json signal: $sig"

plugin_manifest_path="$LAB/plugin-manifest-path"
mkdir -p "$plugin_manifest_path/plugins/demo/.claude-plugin"
printf '%s\n' '{"name":"demo","mcpServers":"./servers.json"}' \
  > "$plugin_manifest_path/plugins/demo/.claude-plugin/plugin.json"
sig=$(call_reroute claude-tooling --config-dir "$plugin_manifest_path") \
  || fail "plugin.json mcpServers path must be tooling required"
[ "$sig" = "MCP servers in $plugin_manifest_path/plugins/demo/.claude-plugin/plugin.json" ] \
  || fail "plugin.json mcpServers path signal: $sig"

acct_hooks_file="$LAB/acct-hooks-file"
mkdir -p "$acct_hooks_file/hooks"
printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$acct_hooks_file/hooks/hooks.json"
sig=$(call_reroute claude-tooling --config-dir "$acct_hooks_file") \
  || fail "account hooks/hooks.json must be tooling required"
[ "$sig" = "$acct_hooks_file/hooks/hooks.json .hooks" ] \
  || fail "account hooks/hooks.json signal: $sig"

combined_ignored_and_hooks="$LAB/combined-ignored-and-hooks"
mkdir -p "$combined_ignored_and_hooks/skills/s" \
  "$combined_ignored_and_hooks/agents/a" \
  "$combined_ignored_and_hooks/commands/c" \
  "$combined_ignored_and_hooks/plugins/demo/skills/s" \
  "$combined_ignored_and_hooks/plugins/demo/.claude-plugin"
printf '%s\n' '{"name":"demo"}' \
  > "$combined_ignored_and_hooks/plugins/demo/.claude-plugin/plugin.json"
printf '%s\n' '{"hooks":{"Stop":[{}]}}' \
  > "$combined_ignored_and_hooks/settings.json"
sig=$(call_reroute claude-tooling --config-dir "$combined_ignored_and_hooks") \
  || fail "ignored account items must not hide account hooks"
[ "$sig" = "$combined_ignored_and_hooks/settings.json .hooks" ] \
  || fail "combined ignored+hooks signal: $sig"

combined_ignored_and_plugin_mcp="$LAB/combined-ignored-and-plugin-mcp"
mkdir -p "$combined_ignored_and_plugin_mcp/skills/s" \
  "$combined_ignored_and_plugin_mcp/agents/a" \
  "$combined_ignored_and_plugin_mcp/commands/c" \
  "$combined_ignored_and_plugin_mcp/plugins/demo/skills/s"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' \
  > "$combined_ignored_and_plugin_mcp/plugins/demo/.mcp.json"
sig=$(call_reroute claude-tooling --config-dir "$combined_ignored_and_plugin_mcp") \
  || fail "ignored account items must not hide plugin MCP"
[ "$sig" = "MCP servers in $combined_ignored_and_plugin_mcp/plugins/demo/.mcp.json" ] \
  || fail "combined ignored+plugin MCP signal: $sig"

unreadable_skills="$LAB/unreadable-skills"
mkdir -p "$unreadable_skills/skills"
chmod 000 "$unreadable_skills/skills" || true
if [ ! -r "$unreadable_skills/skills" ] || [ ! -x "$unreadable_skills/skills" ]; then
  rc=0
  sig=$(call_reroute claude-tooling --config-dir "$unreadable_skills") || rc=$?
  [ "$rc" -eq 1 ] || fail "unreadable account skills must not be a signal, got $rc ($sig)"
  [ -z "$sig" ] || fail "unreadable account skills produced: $sig"
fi
chmod 700 "$unreadable_skills/skills" 2>/dev/null || true

unreadable_plugins="$LAB/unreadable-plugins"
mkdir -p "$unreadable_plugins/plugins"
chmod 000 "$unreadable_plugins/plugins" || true
if [ ! -r "$unreadable_plugins/plugins" ] || [ ! -x "$unreadable_plugins/plugins" ]; then
  sig=$(call_reroute claude-tooling --config-dir "$unreadable_plugins") \
    || fail "an unreadable plugins dir must be tooling required"
  [ "$sig" = "unreadable $unreadable_plugins/plugins" ] \
    || fail "unreadable plugins dir signal: $sig"
fi
chmod 700 "$unreadable_plugins/plugins" 2>/dev/null || true

unreadable_plugin_mcp="$LAB/unreadable-plugin-mcp"
mkdir -p "$unreadable_plugin_mcp/plugins/demo"
printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' \
  > "$unreadable_plugin_mcp/plugins/demo/.mcp.json"
chmod 000 "$unreadable_plugin_mcp/plugins/demo/.mcp.json" || true
if [ ! -r "$unreadable_plugin_mcp/plugins/demo/.mcp.json" ]; then
  sig=$(call_reroute claude-tooling --config-dir "$unreadable_plugin_mcp") \
    || fail "an unreadable plugin .mcp.json must be tooling required"
  [ "$sig" = "unreadable $unreadable_plugin_mcp/plugins/demo/.mcp.json" ] \
    || fail "unreadable plugin .mcp.json signal: $sig"
fi
chmod 600 "$unreadable_plugin_mcp/plugins/demo/.mcp.json" 2>/dev/null || true

sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$LAB/missing-wt") \
  || fail "a missing worktree must be tooling required"
[ "$sig" = "unreadable worktree" ] || fail "missing worktree signal: $sig"

unreadable_wt="$LAB/unreadable-wt"
mkdir -p "$unreadable_wt"
chmod 000 "$unreadable_wt" || true
if [ ! -r "$unreadable_wt" ] || [ ! -x "$unreadable_wt" ]; then
  sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$unreadable_wt") \
    || fail "an unreadable worktree must be tooling required"
  [ "$sig" = "unreadable worktree" ] || fail "unreadable worktree signal: $sig"
fi
chmod 700 "$unreadable_wt" 2>/dev/null || true

sig=$(HOME="$ord" call_reroute claude-tooling --config-dir "$ord/.claude/") \
  || fail "trailing-slash \$HOME/.claude/ must still see \$HOME/.claude.json"
[ "$sig" = "MCP servers in $ord/.claude.json" ] || fail "trailing-slash signal: $sig"

ok "a Claude worker queues on any Claude-specific signal, including unknown"

seed_parent="$LAB/seed-parent"
seed_home="$LAB/seed-home"
mkdir -p "$seed_parent/projects" "$seed_parent/data" "$seed_parent/state"
FM_HOME="$seed_parent" FM_SECONDMATE_CHARTER='firstmate self-development' \
  FM_SECONDMATE_SCOPE='firstmate repo work' \
  "$BIN/fm-home-seed.sh" seedmate "$seed_home" --no-projects >/dev/null \
  || fail "fm-home-seed --no-projects failed"
[ -L "$seed_home/.claude/skills" ] \
  || fail "seeded home missing .claude/skills symlink"
[ "$(readlink "$seed_home/.claude/skills")" = "../.agents/skills" ] \
  || fail "seeded .claude/skills target: $(readlink "$seed_home/.claude/skills")"
[ -f "$seed_home/.claude/settings.json" ] \
  || fail "seeded home missing .claude/settings.json"
[ -f "$seed_home/.claude/mods/firstmate-calm/.claude-plugin/plugin.json" ] \
  || fail "seeded home missing firstmate-calm plugin.json"
[ -f "$seed_home/.claude/mods/firstmate-calm/hooks/hooks.json" ] \
  || fail "seeded home missing firstmate-calm hooks.json"
rc=0
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$seed_home") || rc=$?
[ "$rc" -eq 1 ] || fail "unchanged seeded .claude must not be a signal, got $rc ($sig)"
[ -z "$sig" ] || fail "unchanged seeded .claude produced: $sig"
out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --claude-config-dir "$empty_dir" --worktree "$seed_home" --kind secondmate \
  --candidate codex:default) \
  || fail "seeded-only home: suggest should name the non-Claude pick, got '$out'"
[ "$out" = "codex default" ] || fail "seeded-only home: expected codex, got '$out'"
ok "an unchanged fm-home-seed .claude is not Claude-specific tooling"

mkdir -p "$seed_home/.claude/hooks"
printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$seed_home/.claude/hooks/hooks.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$seed_home") \
  || fail "a user hook beside seed material must be tooling required"
[ "$sig" = "worktree .claude/hooks/hooks.json" ] \
  || fail "user hook signal: $sig"
rm -rf "$seed_home/.claude/hooks"
ok "a user hook in a seeded home is still Claude-specific tooling"

settings_seed=$seed_home/.claude/settings.json
cp "$settings_seed" "$LAB/settings.json.seed"
jq 'del(.hooks) | .env.EDITED = "1"' "$LAB/settings.json.seed" > "$settings_seed"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$seed_home") \
  || fail "an edited seeded settings.json must be tooling required"
[ "$sig" = "worktree .claude/settings.json" ] \
  || fail "edited seed file signal: $sig"
mv "$LAB/settings.json.seed" "$settings_seed"
ok "a user edit of a seeded .claude file is still Claude-specific tooling"

printf '%s\n' '{"mcpServers":{"docs":{"command":"true"}}}' > "$seed_home/.mcp.json"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$seed_home") \
  || fail "user MCP in a seeded home must remain tooling required"
[ "$sig" = "worktree .mcp.json" ] || fail "seeded-home MCP signal: $sig"
rm -f "$seed_home/.mcp.json"
ok "user MCP config in a seeded home remains Claude-specific tooling"

manifest="$BIN/fm-claude-seed.manifest"
[ -f "$manifest" ] || fail "missing Firstmate seed catalog $manifest"
[ "$(head -1 "$manifest")" = "fm-claude-seed.v1" ] || fail "seed catalog header"
# Worktree bytes, matching fm_quota_claude_blob_of. git ls-files -s is the
# index and misses a tracked seed edit that is not yet staged.
expected=$(
  set -o pipefail
  {
    printf 'fm-claude-seed.v1\n'
    git -C "$FM_ROOT" ls-files -- .claude/settings.json .claude/skills \
      .claude/mods/firstmate-calm .agents/skills \
      | while IFS= read -r path; do
          f="$FM_ROOT/$path"
          if [ -L "$f" ]; then
            blob=$(printf '%s' "$(readlink "$f")" | git hash-object --stdin) || exit 1
          elif [ -f "$f" ]; then
            blob=$(git hash-object -- "$f") || exit 1
          else
            exit 1
          fi
          printf '%s\t%s\n' "$blob" "$path"
        done \
      | LC_ALL=C sort -t "$(printf '\t')" -k2,2
  }
) || fail "could not hash the Firstmate seed tree"
[ "$expected" = "$(cat "$manifest")" ] \
  || fail "seed catalog drifted from firstmate-owned prefixes"
ok "the Firstmate seed catalog matches the owned prefixes and no other .claude path"

parent="$LAB/committed-parent"
git clone --local --quiet "$FM_ROOT" "$parent"
mkdir -p "$parent/.claude/hooks"
printf '%s\n' '{"hooks":{"Stop":[{}]}}' > "$parent/.claude/hooks/hooks.json"
git -C "$parent" add .claude/hooks/hooks.json
git -C "$parent" -c user.email=dev@example.test -c user.name=dev \
  -c commit.gpgsign=false commit --quiet -m 'user hook'
cp "$BIN/fm-quota-reroute.sh" "$parent/bin/"
cp "$manifest" "$parent/bin/"
sig=$("$parent/bin/fm-quota-reroute.sh" claude-tooling --config-dir "$empty_dir" \
        --worktree "$parent") \
  || fail "a hook committed in the parent home must be tooling required"
[ "$sig" = "worktree .claude/hooks/hooks.json" ] \
  || fail "committed-parent hook signal: $sig"
ok "a user hook committed in the parent home is still Claude-specific tooling"

git -C "$parent" checkout --quiet -- .claude/settings.json
jq 'del(.hooks) | .env.EDITED = "1"' "$parent/.claude/settings.json" \
  > "$LAB/parent-settings.edited"
mv "$LAB/parent-settings.edited" "$parent/.claude/settings.json"
git -C "$parent" add .claude/settings.json
git -C "$parent" -c user.email=dev@example.test -c user.name=dev \
  -c commit.gpgsign=false commit --quiet -m 'edit seed settings'
sig=$("$parent/bin/fm-quota-reroute.sh" claude-tooling --config-dir "$empty_dir" \
        --worktree "$parent") \
  || fail "a committed edit of a seeded file must be tooling required"
[ "$sig" = "worktree .claude/settings.json" ] \
  || fail "committed-parent seed edit signal: $sig"
ok "a committed edit of a seeded file is still Claude-specific tooling"

mkdir -p "$seed_home/.agents/skills/user-added"
printf '%s\n' '# user skill' > "$seed_home/.agents/skills/user-added/SKILL.md"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$seed_home") \
  || fail "a user skill behind the seeded skills symlink must be tooling required"
[ "$sig" = "worktree .agents/skills/user-added/SKILL.md" ] \
  || fail "symlink-target addition signal: $sig"
rm -rf "$seed_home/.agents/skills/user-added"
ok "a user-added .agents/skills path is not hidden by the seeded skills symlink"

mv "$seed_home/.agents/skills" "$LAB/agents-skills.real"
printf 'blocked\n' > "$seed_home/.agents/skills"
sig=$(call_reroute claude-tooling --config-dir "$empty_dir" --worktree "$seed_home") \
  || fail "an unreadable skills symlink target must be tooling required"
[ "$sig" = "unreadable $seed_home/.agents/skills" ] \
  || fail "unreadable traversal signal: $sig"
rm -f "$seed_home/.agents/skills"
mv "$LAB/agents-skills.real" "$seed_home/.agents/skills"
ok "an unreadable seed traversal is Claude-specific tooling"

if out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --from-model claude-3-5-sonnet --claude-config-dir "$empty_dir" --worktree "$clean_wt" \
  --candidate claude:claude-3-5-sonnet 2>/dev/null); then
  fail "the current harness:model must not be a pick, got '$out'"
fi
[ "$out" = "none" ] || fail "exclude current: expected none, got '$out'"
out=$(call_reroute suggest --snapshot "$LAB/captured.json" --from-harness claude \
  --from-model default --pinned --claude-config-dir "$empty_dir" --worktree "$clean_wt" \
  --candidate claude:claude-3-5-sonnet --candidate codex:default)
[ "$out" = "codex default" ] || fail "a pinned Claude account must skip every Claude candidate, got '$out'"
ok "suggest excludes the current harness:model and a pinned account's harness"

printf '# all fm-quota-choose tests passed\n'
