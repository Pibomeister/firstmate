#!/bin/bash
# Drives bin/fm-self-heal-issue.sh + the real gh binary against fake_github.py.
LAB=$1; RUN=/tmp/fm-sh-run.sh; L=$LAB/gh.log; PX=http://127.0.0.1:18765
n() { wc -l < "$L" | tr -d ' '; }
ctl() { curl -s --noproxy '*' -X POST "$PX$1" >/dev/null; }
run() { # label, args...
  local before; before=$(n); printf '\n$ fm-self-heal-issue.sh'; printf ' %q' "$@"; echo
  "$RUN" "$@"; local rc=$?; echo "-> rc=$rc github_requests=$(( $(n) - before ))"
}
FM=(--repo Pibomeister/firstmate)
echo "=== S1 new issue, labels created (maintainer home)"
run "${FM[@]}" --failure-class gate-stall --title 'Gate stalls on lint: `timeout` & "quotes"' --evidence '10:54 PM CDMX log=/tmp/x.log sha=abc123' --evidence '10:55 PM CDMX log=/tmp/x2.log' --instance-fix 'restarted gate' --proposed-fix 'raise the lint timeout'
echo "=== S2 repeat: comment, no new issue, labels not recreated"
run "${FM[@]}" --failure-class gate-stall --title 'different title' --evidence '11:10 PM CDMX log=/tmp/y.log sha=def456'
grep -c 'create-label' "$L" | sed 's/^/label-create calls so far: /'; grep SEARCH "$L" | tail -1
echo "=== S3 other failure class does not dedupe into it"
run "${FM[@]}" --failure-class watcher-lost --title 'Watcher lost' --evidence 'e1'
echo "=== S4 closed issue does not absorb a new occurrence"
ctl /__close/pibomeister/firstmate/1
run "${FM[@]}" --failure-class gate-stall --title 'Gate stalls again' --evidence 'after close'
echo "=== S5 repeat with no evidence, then no-evidence new issue"
run "${FM[@]}" --failure-class gate-stall --title 't'
run "${FM[@]}" --failure-class no-ev --title 'No evidence'
echo "=== S6 search failure must not file a duplicate"
ctl /__fail_search; run "${FM[@]}" --failure-class gate-stall --title 'dup?' --evidence 'x'; ctl /__fail_search
echo "=== S7 unapproved repositories refused"
run --repo Pibomeister/not-approved --failure-class k --title t --evidence e
run --repo cli/cli --failure-class k --title t --evidence e
run --repo github.com/Pibomeister/firstmate --failure-class k --title t
run --repo 'Pibomeister/firstmate/../evil' --failure-class k --title t
echo "=== S8 secrets refused before any GitHub call"
for s in 'token=abc123def' 'authorization: token abc' 'bearer abc123' 'https://u:tok3n@github.com/x/y.git' 'ghp_''abcdefghij0123456789' 'sk-''ant-api03-abcdefgh' 'AKIA''ABCDEFGHIJKLMNOP' 'password=hunter2' '-----BEGIN RSA PRIVATE KEY-----'; do
  run "${FM[@]}" --failure-class k --title t --evidence "$s" 2>&1 | sed "s#$s#<redacted-shape>#g"
done
run "${FM[@]}" --failure-class k --title 'leak ghp_''abcdefghij0123456789' 2>&1 | sed 's/ghp_[a-z0-9]*/<redacted-shape>/'
echo "=== S9 firstmate publication grant"
mv "$LAB/config/firstmate-role" "$LAB/role.bak"
echo '--- no role file (user default): firstmate refused'
run "${FM[@]}" --failure-class grant --title t --evidence e
echo '--- explicit user role: firstmate refused'
echo user > "$LAB/config/firstmate-role"
run "${FM[@]}" --failure-class grant --title t --evidence e
echo '--- maintainer of another repo: firstmate refused'
echo 'maintainer github.com/someone/firstmate' > "$LAB/config/firstmate-role"
run "${FM[@]}" --failure-class grant --title t --evidence e
echo '--- user role: agent-kit still files'
echo user > "$LAB/config/firstmate-role"
run --repo Pibomeister/agent-kit --failure-class ak-fail --title 'Agent kit failure' --evidence e
run --repo PIBOMEISTER/AGENT-KIT --failure-class ak-fail --title 'dedupes across casing' --evidence e2
rm -f "$LAB/config/firstmate-role"; mv "$LAB/role.bak" "$LAB/config/firstmate-role"
echo "=== S10 gate-project repo"
mkdir -p "$LAB/projects"; git init -q "$LAB/projects/casco"; git -C "$LAB/projects/casco" remote add origin https://github.com/Pibomeister/casco.git
git -C "$LAB/projects/casco" remote add upstream https://github.com/third-party/casco.git
echo '--- own origin with flag: files'
run --repo Pibomeister/casco --for-gate-project casco --failure-class gate-sh --title 'Casco gate.sh fix' --evidence 'e' --proposed-fix 'patch gate.sh'
echo '--- no flag: refused'
run --repo Pibomeister/casco --failure-class gate-sh --title t --evidence e
echo '--- third-party upstream of the project: refused'
run --repo third-party/casco --for-gate-project casco --failure-class gate-sh --title t --evidence e
echo '--- unregistered project and path traversal: refused'
run --repo Pibomeister/casco --for-gate-project nope --failure-class gate-sh --title t
run --repo Pibomeister/casco --for-gate-project ../projects/casco --failure-class gate-sh --title t
echo "=== S11 bad usage"
run --repo Pibomeister/agent-kit --failure-class 'bad key' --title t
run --repo Pibomeister/agent-kit --failure-class k
echo; echo "=== Final GitHub-side state"; cat "$LAB/state.json"
