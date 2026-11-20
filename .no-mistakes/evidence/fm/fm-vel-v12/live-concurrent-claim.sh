#!/usr/bin/env bash
# Live: three concurrent claimants in one lab home reserve three distinct items.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
L() { env -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bash "$ROOT/bin/fm-ledger.sh" "$@"; }
mkdir -p "$LAB/projects/alpha"
for i in 1 2 3; do
  L intake "item-$i" --project alpha --title "approved $i" --source "proposal:V12-$i" >/dev/null || echo "intake $i failed"
  mkdir -p "$LAB/data/item-$i"; printf 'approved brief %s\n' "$i" > "$LAB/data/item-$i/brief.md"
done
echo '--- claim before opt-in'; L claim --project alpha; echo "rc=$?"
printf 'claim-project=alpha\n' > "$LAB/config/mission-ledger"
echo '--- three concurrent claimants'
for n in a b c; do (L claim --project alpha > "$LAB/$n.out" 2> "$LAB/$n.err"; echo $? > "$LAB/$n.rc") & done
wait
for n in a b c; do echo "$n rc=$(cat $LAB/$n.rc) $(cat $LAB/$n.out) $(cat $LAB/$n.err)"; done
echo "distinct items: $(cat $LAB/a.out $LAB/b.out $LAB/c.out | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
echo '--- fourth claimant on empty queue'; L claim --project alpha; echo "rc=$?"
echo '--- receipts'; for f in "$LAB"/state/ledger-claims/*.json; do jq -c '{task:.task_id,phase,project}' "$f" 2>/dev/null || cat "$f"; done
echo '--- hold one item then resume'; FM_HOME="$LAB" bash "$ROOT/bin/fm-tasks-axi.sh" hold item-1 --reason 'captain decision' >/dev/null 2>&1; L claim --project alpha --resume item-1; echo "rc=$?"
echo '--- secondmate guidance from lab config'
. "$ROOT/bin/fm-secondmate-charter-lib.sh"; fm_secondmate_claim_guidance "$LAB/config"; echo "rc=$?"
rm -rf "$LAB"
