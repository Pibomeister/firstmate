. bin/fm-incident-ledger-lib.sh; S=$1
ap(){ fm_incident_ledger_lock $S; id=$(fm_incident_ledger_append_locked $S "$@"); rc=$?; fm_incident_ledger_unlock $S; echo "appended $id rc=$rc"; }
ap h1 w/task 1 open routine e1 "" "" escalate
ap h1 w/task 1 open routine e1 cause1 "" delta
ap h1 w/task 1 closed routine e1 "" "" closure
ap h1 w/task 01 open stuck e2 "" "" escalate
ap h2 "sub	ject" "sig
nal" open routine e9 "multi
line" "" record
echo "-- invalid action --"; fm_incident_ledger_append_locked $S h1 s g o r e x "" bogus; echo "rc=$?"
echo "-- empty class --"; fm_incident_ledger_append_locked $S h1 s g o "" e x "" record; echo "rc=$?"
echo "-- key --"; fm_incident_key h1 w/task 1 open
echo "-- episode rows e1 --"; fm_incident_ledger_episode_rows $S h1 w/task 1 e1
