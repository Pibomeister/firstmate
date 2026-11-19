#!/bin/bash
# usage: drive.sh <lib> <workdir>   -- run under stock /bin/bash 3.2
. "$1"; W=$2; export PATH="$W/bin:$PATH"
echo "bash=$BASH_VERSION mechanism-for-fn=bash(fm_run_timed_fn)"
# S1 command <program> inside a timed function
f1() { command fm-fake-program >"$W/fake.out"; echo after; return 5; }
out=$(fm_run_timed_fn 5 f1); rc=$?
echo "S1 command-builtin: out='$out' rc=$rc fake.out='$(cat $W/fake.out)'  (expect out=after rc=5)"
# S2 bound still fires on a command <program> that hangs
f2() { command sleep 30; echo should-not-print; }
t0=$(date +%s); out=$(fm_run_timed_fn 2 f2); rc=$?; t1=$(date +%s)
sleep 1; left=$(pgrep -f '^sleep 30$' | wc -l | tr -d ' ')
echo "S2 bound: out='$out' rc=$rc elapsed=$((t1-t0))s leftover-sleep=$left  (expect rc=124 elapsed~2-3 leftover=0)"
# S3 ordinary statuses
f3() { echo ok; return 0; }; out=$(fm_run_timed_fn 5 f3); echo "S3a success: out='$out' rc=$?"
f4() { return 3; }; fm_run_timed_fn 5 f4; echo "S3b failure: rc=$? (expect 3)"
f5() { sh -c 'kill -TERM $$'; }
FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 5 sh -c 'exit 7'; echo "S3d fm_run_timed bash-mech plain cmd: rc=$? (expect 7)"
