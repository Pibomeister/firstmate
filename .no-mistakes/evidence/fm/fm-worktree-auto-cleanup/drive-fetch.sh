#!/usr/bin/env bash
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P) || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
ENVV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
P=$(gh api repos/Pibomeister/firstmate/pulls/60/commits --jq '.[0].parents[0].sha'); H=a5b1ab3840870141fdc2d3eae5eb70f6fdc4cd6c
B=fm/fm-monitoring-self-heal
C=$LAB/projects/full; git clone -q --single-branch --branch main https://github.com/Pibomeister/firstmate.git "$C"; git -C "$C" remote set-url --push origin no_push
echo "### A. FETCH FAILS: git https transport blocked, PR head absent"
git -C "$C" worktree add -q -b $B "$LAB/fw" "$P"
echo "head present: $(git -C "$C" cat-file -e "$H^{commit}" 2>/dev/null && echo yes || echo no)"
"${ENVV[@]}" GIT_ALLOW_PROTOCOL=file "$ROOT/bin/fm-worktree-cleanup.sh" "$C" 2>&1 | sed "s#$LAB#\$LAB#"
echo "worktree: $([ -d "$LAB/fw" ] && echo KEPT || echo removed)"
echo "### B. FETCH WORKS: same worktree, normal transport"
"${ENVV[@]}" "$ROOT/bin/fm-worktree-cleanup.sh" "$C" 2>&1 | sed "s#$LAB#\$LAB#"
echo "head present: $(git -C "$C" cat-file -e "$H^{commit}" 2>/dev/null && echo yes || echo no)"
echo "worktree: $([ -d "$LAB/fw" ] && echo KEPT || echo removed)"
rm -rf "$LAB"; echo "lab removed"
