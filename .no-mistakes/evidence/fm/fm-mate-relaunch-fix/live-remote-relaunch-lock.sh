#!/usr/bin/env bash
# Live: the remote relaunch tool refuses (exit 5) while the mate's lifecycle lock is held, and asks no host.
set -u
W=$1; P=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$W/bin/fm-lab-home.sh" create "$P" >/dev/null; mkdir -p "$P/state"
printf 'kind=secondmate\nremote_host=lab-unreachable-host.invalid\nharness=claude\n' > "$P/state/smr.meta"
cp "$P/state/smr.meta" "$P/smr.meta.before"
( . "$W/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$P/state/.control-smr.lock" || exit 1; sleep 20 ) & h=$!
for i in $(seq 50); do [ -e "$P/state/.control-smr.lock" ] && break; sleep 0.1; done
echo "### held lock: remote relaunch attempt"
start=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$P" "$W/bin/fm-remote-secondmate-relaunch.sh" smr claude default default; rc=$?
echo "exit=$rc elapsed=$(( $(date +%s) - start ))s"
cmp -s "$P/state/smr.meta" "$P/smr.meta.before" && echo "meta unchanged: yes" || echo "meta unchanged: NO"
kill $h 2>/dev/null; wait $h 2>/dev/null
echo "### lock free: tool proceeds past the lock to the host (unreachable host here)"
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$P" timeout 60 "$W/bin/fm-remote-secondmate-relaunch.sh" smr claude default default 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
echo "lock released after run: $([ -e "$P/state/.control-smr.lock" ] && echo NO || echo yes)"
rm -rf "$P"
