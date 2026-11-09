#!/usr/bin/env bash
# tests/fm-codex-stop-thread-live-e2e.test.sh - live guard for the thread
# identity a Codex Stop hook hands bin/fm-turnend-guard.sh
# (live-harness-optin family).
#
# A Codex Stop hook gets no CODEX_THREAD_ID/CODEX_SESSION_ID pair, so the guard
# takes the thread from the payload's session_id and lets
# bin/fm-session-lock-lib.sh's Codex-ancestry gate decide whether to trust it.
# Both halves are vendor-emitted, so the portable fixture in
# tests/fm-session-lock-ancestry.test.sh cannot prove them. This guard runs one
# INSTALLED `codex exec` turn in a throwaway lab whose only Stop hook is a probe,
# and requires that the payload session_id equals the session id codex printed
# and that the trust gate accepts it from inside the hook process.
#
# The run uses a throwaway CODEX_HOME holding copies of the operator's
# config.toml and auth.json only, so none of the operator's own hooks exist
# there; --dangerously-bypass-hook-trust then runs nothing but the probe.
# The guard submits a prompt and spends model tokens, so it is opt-in:
# FM_CODEX_STOP_THREAD_LIVE=1 or FM_LIVE=1 runs it, and an absent codex then
# fails rather than skips. Failures name codex and `codex --version`.
# shellcheck disable=SC2016 # single quotes are deliberate: the probe expands at hook time
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_STOP_THREAD_LIVE codex
CODEX_BIN=$(command -v codex) || fail "codex is not installed"
VERSION=$(codex --version 2>/dev/null | head -n 1)
[ -f "$HOME/.codex/config.toml" ] && [ -f "$HOME/.codex/auth.json" ] \
  || fail "$VERSION: no ~/.codex/config.toml and auth.json to stage for the throwaway Codex home"

LAB=$(fm_test_tmproot fm-codex-stop-thread)
mkdir -p "$LAB/codex-home" "$LAB/work/.codex"
cp "$HOME/.codex/config.toml" "$HOME/.codex/auth.json" "$LAB/codex-home/" \
  || fail "$VERSION: could not stage the throwaway Codex home"
git -C "$LAB/work" init -q || fail "could not initialize the lab workspace"
# Codex ran no Stop hook from an untrusted lab's .codex/hooks.json, so trust the lab.
WORK=$(CDPATH='' cd -- "$LAB/work" && pwd -P)
printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$WORK" >> "$LAB/codex-home/config.toml"
cat > "$LAB/probe.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty')
printf 'session_id=%s\n' "$sid" > "$FM_PROBE_OUT"
printf 'env_pair=%s|%s\n' "${CODEX_THREAD_ID:-}" "${CODEX_SESSION_ID:-}" >> "$FM_PROBE_OUT"
trusted=$(CODEX_THREAD_ID=$sid CODEX_SESSION_ID=$sid bash -c '. "$1"; fm_session_lock_trusted_codex_session_id' _ "$FM_LIB")
printf 'trusted=%s\n' "$trusted" >> "$FM_PROBE_OUT"
printf '{}\n'
SH
chmod +x "$LAB/probe.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":30}]}]}}\n' "$LAB/probe.sh" \
  > "$LAB/work/.codex/hooks.json"

CODEX_HOME="$LAB/codex-home" FM_PROBE_OUT="$LAB/probe.out" FM_LIB="$ROOT/bin/fm-session-lock-lib.sh" \
  "$CODEX_BIN" exec --dangerously-bypass-hook-trust --skip-git-repo-check -s workspace-write -C "$WORK" \
  'Reply with exactly: ok' < /dev/null > "$LAB/exec.log" 2>&1 \
  || fail "$VERSION: codex exec failed: $(tail -n 20 "$LAB/exec.log")"
printed=$(sed -n 's/^session id: //p' "$LAB/exec.log" | head -n 1)
[ -n "$printed" ] || fail "$VERSION: codex exec printed no session id"
[ -s "$LAB/probe.out" ] || fail "$VERSION: the Stop probe never ran: $(tail -n 20 "$LAB/exec.log")"
printf '# %s probe: %s\n' "$VERSION" "$(tr '\n' ' ' < "$LAB/probe.out")"
grep -qx "session_id=$printed" "$LAB/probe.out" \
  || fail "$VERSION: the Stop payload session_id is not the thread codex printed ($printed)"
grep -qx "trusted=$printed" "$LAB/probe.out" \
  || fail "$VERSION: the session-lock trust gate refused the payload thread inside the Stop hook"
pass "$VERSION: a Stop hook's payload session_id is the thread, trusted through Codex ancestry"
