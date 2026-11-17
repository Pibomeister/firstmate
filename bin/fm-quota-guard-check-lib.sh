# shellcheck shell=bash
# One-snapshot supervisor check for fm-quota-guard.sh.
# Its public header owns flags, ledger bounds, output, and exit status.

fm_quota_guard_member() {  # <id> <harness> <model> <account>
  local provider lane
  provider=$(fm_quota_single_provider_for_harness "$2") || provider=unmeasured
  # Only OMP's explicit provider prefixes extend the single-provider table.
  # Multi-provider harnesses without established provider evidence stay unknown.
  if [ "$2" = omp ]; then
    provider=$(fm_quota_provider_for_harness "$2" "$3") || provider=unmeasured
  fi
  lane=$(jq -rn --arg h "$2" --arg m "$3" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)') || return 1
  jq -cn --arg id "$1" --arg provider "$provider" --arg lane "$lane" \
    --arg model "${3#*/}" --arg account "$4" \
    '{id: $id, provider: $provider, lane: $lane, model: $model, account: $account}'
}

fm_quota_guard_members() {
  local harness model account meta id config
  harness=$("$SCRIPT_DIR/fm-harness.sh") || return 1
  account=''
  [ "$harness" != claude ] || account=${CLAUDE_CONFIG_DIR:-}
  fm_quota_guard_member primary "$harness" default "$account" || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    id=${meta##*/}; id=${id%.meta}
    harness=$(fm_meta_get "$meta" harness)
    model=$(fm_meta_get "$meta" model)
    account=$(fm_meta_get "$meta" account)
    if [ -z "$harness" ]; then
      harness=$("$SCRIPT_DIR/fm-harness.sh" secondmate "$id") || return 1
      model=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model "$id") || return 1
    fi
    if [ -z "$account" ]; then
      config=$(fm_worker_account_config "$harness" "$CONFIG" "$id") || return 1
      account=$(fm_worker_account_resolve "$harness" "$config" '') || return 1
      account=${account%%$'\t'*}
    fi
    fm_quota_guard_member "$id" "$harness" "${model:-default}" "$account" || return 1
  done
}

# Serialize deduplication and rotation on the ledger inode itself, without a
# daemon or a persistent lock directory that could wedge after interruption.
fm_quota_guard_log() {  # <ledger> <epoch>; TSV records on stdin, new alerts out
  perl -e '
    use strict; use warnings; use Fcntl qw(:flock SEEK_SET);
    my ($path, $now) = @ARGV;
    open my $fh, "+>>", $path or die "open quota ledger: $!\n";
    alarm 5;
    flock($fh, LOCK_EX) or die "lock quota ledger: $!\n";
    alarm 0;
    seek($fh, 0, SEEK_SET) or die "seek quota ledger: $!\n";
    my @old = <$fh>;
    my %last;
    for my $line (@old) {
      chomp(my $copy = $line);
      my @f = split /\t/, $copy, -1;
      next unless @f == 8;
      my ($account) = $f[7] =~ /^account=([^ ]*)/;
      $last{join "\t", @f[1,2], $account // ""} = $f[3];
    }
    my @alerts;
    while (<STDIN>) {
      chomp;
      my @f = map { s/[\r\n\t]/ /gr } split /\t/, $_, -1;
      die "invalid quota ledger row\n" unless @f == 7;
      @f = map { substr($_, 0, 512) } @f;
      my ($account) = $f[6] =~ /^account=([^ ]*)/;
      my $key = join "\t", @f[0,1], $account // "";
      if (($f[2] eq "EXHAUSTED" || $f[2] eq "TIGHT_HORIZON") &&
          ($last{$key} // "") ne $f[2]) {
        push @alerts, "$f[0]/$f[1] $f[2]";
      }
      $last{$key} = $f[2];
      push @old, join("\t", $now, @f) . "\n";
    }
    @old = @old[-1000..-1] if @old > 1000;
    seek($fh, 0, SEEK_SET) or die "seek quota ledger: $!\n";
    truncate($fh, 0) or die "truncate quota ledger: $!\n";
    print {$fh} @old or die "write quota ledger: $!\n";
    close $fh or die "close quota ledger: $!\n";
    print join("; ", @alerts) if @alerts;
  ' "$1" "$2"
}

fm_quota_guard_check() {
  set -o pipefail
  local snapshot='' horizon=36000 json=false raw parsed members pools alerts err=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) [ -f "${2-}" ] && [ ! -L "$2" ] || die "--snapshot needs a regular file"; snapshot=$2; shift 2 ;;
      --horizon-secs)
        [[ "${2-}" =~ ^[1-9][0-9]{0,8}$ ]] || die "--horizon-secs needs a positive integer below 1000000000"
        horizon=$2; shift 2 ;;
      --json) json=true; shift ;;
      --help|-h) usage; return 0 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  members=$(fm_quota_guard_members | jq -s '.') || die "cannot discover supervisor pools" 1
  # Pipefail preserves a failed resolver even if jq receives a partial list.
  if [ -n "$snapshot" ]; then
    raw=$(cat -- "$snapshot") || err='snapshot unreadable'
  else
    raw=$(fm_run_timed "$READ_SECS" quota-axi --no-credential-refresh 2>/dev/null </dev/null) || err='quota-axi read failed'
  fi
  parsed=''
  if [ -z "$err" ]; then
    parsed=$(printf '%s\n' "$raw" | fm_quota_toon_to_json) || err='invalid quota-axi TOON snapshot'
  fi
  if [ -n "$err" ] || ! printf '%s\n' "$parsed" | fm_quota_json_valid; then
    parsed='{"schemaVersion":5,"providers":[],"attention":[],"exhaustion":[]}'
    [ -n "$err" ] || err='invalid quota-axi provider data'
  fi
  pools=$(printf '%s\n' "$parsed" | jq -c --argjson members "$members" \
    --argjson horizon "$horizon" --arg error "$err" "$FM_QUOTA_ROW_JQ"'
    . as $snapshot |
    def number: try tonumber catch null;
    [$members[] | . as $m |
      quota_row($snapshot; .provider; .lane) as $p |
      ($p.accountKey // "default") as $row_account |
      (if $p == null then [] elif .model == "default" then quota_provider_rows($p)
       else quota_applicable($p; .model) end) as $quota_rows |
      {provider: $m.provider, quotaSemantics: {effectiveAvailability:
        [$snapshot.attention[]? | select(.provider == $m.provider and (.accountKey // "default") == $row_account) |
          {scope: .scope, status: "unknown"}]}} as $attention_provider |
      (if .model == "default" then quota_provider_rows($attention_provider)
       else quota_applicable($attention_provider; .model) end) as $attention_rows |
      ($quota_rows + [$attention_rows[] | select(.scope as $scope | ($quota_rows | map(.scope) | index($scope)) == null)]) as $rows |
      (if ($rows | length) == 0 then [{scope: "all_models", status: "unknown"}] else $rows end)[] |
      . as $r |
      (if $m.account != "" and $m.account != "ordinary" then $m.account
       elif $p != null then $row_account
       else (if $m.lane == "" then "default" else $m.lane end) end) as $account |
      [$snapshot.attention[]? | select(.provider == $m.provider and (.accountKey // "default") == $row_account and
        (.scope == $r.scope or .scope == "all_models" or .scope == "all_products"))] as $attention |
      [$snapshot.exhaustion[]? | select(.provider == $m.provider and (.accountKey // "default") == $row_account and .scope == $r.scope)] as $exhaustion |
      ($exhaustion[0].usableRunwaySeconds | number) as $seconds |
      ($r.runway.status // "unknown") as $runway |
      (if $error != "" then $error
       elif $m.provider == "unmeasured" then "provider mapping unmeasured"
       elif $m.account != "" and $m.account != "ordinary" then "pinned account not identified by TOON"
       elif $p == null then "pool absent from quota"
       elif ($attention | length) > 0 then ("attention: " + ($attention | map(.kind) | unique | join(",")))
       elif $r.status != "known" then "quota scope unknown"
       else "" end) as $unknown |
      (if $unknown != "" then "unknown"
       elif $r.effectivePercentRemaining == 0 or $seconds == 0 or $runway == "exhausted_now" then "EXHAUSTED"
       elif $runway == "projected_exhaustion" and $seconds != null and $seconds < $horizon and $seconds > 0 then "TIGHT_HORIZON"
       elif $runway == "through_reset" or ($seconds != null and $seconds >= $horizon) then "HEALTHY"
       else "unknown" end) as $verdict |
      {provider: $m.provider, account: $account, scope: $r.scope, verdict: $verdict,
       percent_remaining: $r.effectivePercentRemaining, runway: $runway,
       usable_runway_secs: $seconds, members: [$m.id],
       detail: (if $unknown != "" then $unknown elif $verdict == "unknown" then "runway unmeasured" else "" end)}
    ] | group_by([.provider, .account, .scope, .verdict, .detail]) |
    map(.[0] + {members: (map(.members[]) | unique)})
  ') || die "cannot classify quota snapshot" 1
  mkdir -p "$STATE" || die "cannot create $STATE" 1
  alerts=$(printf '%s\n' "$pools" | jq -r '.[] |
    [.provider, .scope, .verdict, (.percent_remaining // "-"), .runway,
     (.usable_runway_secs // "-"), ("account=" + (.account | @uri) + " members=" + (.members | join(",")) + "; " + .detail)] | @tsv' |
    fm_quota_guard_log "$STATE/quota-guard.tsv" "$(fm_now)") || die "cannot record quota check" 1
  if "$json"; then
    jq -cn --argjson horizon "$horizon" --argjson pools "$pools" --arg alerts "$alerts" \
      '{horizon_secs: $horizon, pools: $pools, alerts: $alerts}'
  elif [ -n "$alerts" ]; then
    printf 'quota-guard: %s; move new workers off these pools first to preserve supervisor runway\n' "$alerts"
  fi
}
