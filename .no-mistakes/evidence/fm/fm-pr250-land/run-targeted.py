import concurrent.futures, json, os, pathlib, signal, subprocess, time
out=pathlib.Path('~/.no-mistakes/evidence/01M80NZYVR53SZKKBMXS7ZM9VE')
os.environ['FM_TEST_SKIP_ORPHAN_REAP']='1'
jobs=[
 ('project-capacity',['bash','tests/fm-project-capacity.test.sh'],2200),
 ('afk-contract',['bash','tests/fm-afk-contract.test.sh'],900),
 ('backlog-atomicity',['bash','tests/fm-backlog-atomicity.test.sh'],1200),
 ('classify-decision-key',['bash','tests/fm-classify-decision-key.test.sh'],900),
 ('classify-corr-token',['bash','tests/fm-classify-corr-token.test.sh'],600),
 ('branch-priority',['bash','tests/fm-branch-supervision.test.sh','test_branch_prompt_delivers_priority_supervision'],600),
 ('daemon-priority',['bash','tests/fm-daemon.test.sh','test_p0_alarm_reaches_supervision_after_blocker_signal'],900),
 ('wake-queue',['bash','tests/fm-wake-queue.test.sh'],1200),
 ('watch-open-p0',['bash','tests/fm-watch-open-decisions.test.sh','test_p0_origins_only_for_due_unsurfaced_blockers','test_p0_keyed_note_updates_keep_first_opening','test_p0_once_only_survives_endpoint_replacement','test_p0_marker_survives_unreadable_status','test_p0_invalid_opening_time_is_explicit_and_reopens','test_timed_cursor_retirement'],1200),
 ('control-priority',['bash','tests/fm-control-relaunch.test.sh','test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it','test_spawn_relaunch_refuses_contradicting_flags'],1200),
 ('priority-worker-live',['bash','tests/fm-priority-worker-live-e2e.test.sh'],600),
]
for case in ['test_p0_blocker_surfaces_exact_text_once_at_ten_minutes','test_p0_alarms_scan_all_workers_before_sibling_signals','test_p0_blocker_fold_preserves_open_keys_and_ages']:
 jobs.append((case,['env','FM_TEST_ONLY='+case,'bash','tests/fm-watch-triage.test.sh'],900))
def run(job):
 name,cmd,limit=job; start=time.time()
 with (out/(name+'.log')).open('w') as log:
  log.write('$ '+' '.join(cmd)+'\n'); log.flush()
  p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  timed=False
  try: rc=p.wait(timeout=limit)
  except subprocess.TimeoutExpired:
   timed=True; os.killpg(p.pid,signal.SIGTERM)
   try: rc=p.wait(timeout=30)
   except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); rc=p.wait()
  # No test-owned children may survive a suite.
  try: os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError: pass
  result=dict(name=name,command=cmd,exit=rc,timeout=timed,seconds=round(time.time()-start,2))
  log.write('\nRESULT '+json.dumps(result)+'\n')
 (out/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result),flush=True)
 return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 results=list(pool.map(run,jobs))
(out/'targeted-results.json').write_text(json.dumps(results,indent=2)+'\n')
