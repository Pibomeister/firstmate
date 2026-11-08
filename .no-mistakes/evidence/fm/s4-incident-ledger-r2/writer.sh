. bin/fm-incident-ledger-lib.sh; S=$1; w=$2
for i in 1 2 3 4 5 6 7 8 9 10; do fm_incident_ledger_lock $S || exit 9; fm_incident_ledger_append_locked $S h3 "w$w" sig open routine "e$w" "" "" record >/dev/null; fm_incident_ledger_unlock $S; done
