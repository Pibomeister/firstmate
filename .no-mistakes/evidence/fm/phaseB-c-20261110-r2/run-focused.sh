#!/usr/bin/env bash
cd /Users/eduardopicazo/.no-mistakes/worktrees/075d7f40c28a/01M74XA2XPVDKRK4HTBT685SN7 || exit 9
echo "rev=$(git rev-parse HEAD) start=$(date -u +%FT%TZ)"
for c in "env FM_TEST_ONLY=stop-policy-review bash tests/fm-turnend-guard.test.sh" \
         "env FM_TEST_ONLY=stop-policy bash tests/fm-claude-stop-autoarm.test.sh" \
         "bash tests/fm-stop-policy.test.sh" \
         "env FM_STOP_POLICY_LIVE_E2E=1 bash tests/fm-stop-policy-live-e2e.test.sh"; do
  echo "=== CMD: $c  ($(date -u +%TZ) load=$(sysctl -n vm.loadavg))"
  bash -c "$c" 2>&1
  echo "=== EXIT $? : $c ($(date -u +%TZ))"
done
