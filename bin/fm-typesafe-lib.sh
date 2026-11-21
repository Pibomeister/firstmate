# shellcheck shell=bash
# fm-typesafe-lib.sh - the one TypeSafe (System One) client: the base URL
# check and the bearer POST, shared by bin/fm-dispatch-resolve.sh and
# bin/fm-stall-watch.sh. Sourced, never executed, with no side effects on
# source. docs/configuration.md "Typed dispatch resolution" owns TYPESAFE_BASE
# and the key lookup order; bin/fm-credential-source-lib.sh owns declared
# credential sources.
#
#   FM_TS_DEFAULT_BASE
#       The public TypeSafe endpoint base.
#   fm_ts_base_setting <env-file> <variable>
#       Sets <variable> to the configured TYPESAFE_BASE: the environment value
#       byte for byte (so a stray newline still fails validation), else the
#       one in <env-file>, else empty. Needs bin/fm-env-lib.sh. The caller
#       validates it and chooses its own default and error wording.
#   fm_ts_base_valid <base>
#       Succeeds when <base> is an http(s) URL with a host and no userinfo,
#       query, fragment, whitespace, or brackets in its path. Needs jq. Never
#       prints the value, because a misconfigured URL may hold credentials.
#   fm_ts_base_trim <base>
#       Prints <base> without its trailing slashes.
#   fm_ts_post <endpoint> <timeout-seconds> <key-or-empty> <response-file>
#       POSTs stdin as JSON and prints the HTTP status, 000 when the transport
#       failed. The key reaches curl as a header read from fd 3, never argv,
#       the environment, or a file; an empty key sends no Authorization header.

# shellcheck disable=SC2034  # read by the sourcing scripts
FM_TS_DEFAULT_BASE=https://api.typesafe.ai

fm_ts_base_setting() {
  local _fm_ts_base=${TYPESAFE_BASE:-}
  [ -n "$_fm_ts_base" ] || _fm_ts_base=$(fmx_env_get TYPESAFE_BASE "$1")
  printf -v "$2" '%s' "$_fm_ts_base"
}

fm_ts_base_valid() {
  jq -en --arg base "$1" '
    def ipv4:
      split(".") | length == 4 and all(.[];
        test("\\A(0|[1-9][0-9]{0,2})\\z") and (tonumber <= 255));
    def ipv6:
      # An IPv4 tail occupies two of the eight IPv6 groups.
      (if contains(".") then
        split(":") | if (.[-1] | ipv4) then .[-1] = "0:0" | join(":") else "!" end
       else . end) |
      split("::") as $sides |
      if ($sides | length) == 1 then
        test("\\A[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7}\\z")
      elif ($sides | length) == 2 then
        all($sides[]; test("\\A([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*)?\\z")) and
        (split(":") | map(select(length > 0)) | length < 8)
      else false end;
    $base | capture("\\Ahttps?://(?<host>\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._-]+)(:(?<port>[0-9]+))?(?<path>/[^?#[:space:]\\\\]*)?\\z"; "i") |
    ((.path // "") | (contains("[") or contains("]")) | not) and
    (if .host | startswith("[") then .host[1:-1] | ipv6
     else true end) and
    (.port == null or (.port | tonumber | . >= 1 and . <= 65535))
  ' >/dev/null 2>&1
}

fm_ts_base_trim() {
  local base=$1
  while [ "${base%/}" != "$base" ]; do base=${base%/}; done
  printf '%s\n' "$base"
}

fm_ts_post() {
  local endpoint=$1 timeout=$2 key=$3 resp=$4 http
  if [ -n "$key" ]; then
    http=$(curl --globoff -sS --max-time "$timeout" -o "$resp" -w '%{http_code}' \
      -X POST "$endpoint" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$key") \
      --data-binary @- 2>/dev/null) || http=000
  else
    http=$(curl --globoff -sS --max-time "$timeout" -o "$resp" -w '%{http_code}' \
      -X POST "$endpoint" -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null) || http=000
  fi
  printf '%s\n' "${http:-000}"
}
