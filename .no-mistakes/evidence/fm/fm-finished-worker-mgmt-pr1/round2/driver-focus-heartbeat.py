from pathlib import Path
import subprocess,json,time,os,signal,shutil
exec(Path('.gate-tests/run-targeted.py').read_text().split('checks=')[0])
h=root/'.gate-tests/hb-focus-user';h.mkdir(exist_ok=True);env.update(HOME=str(h),XDG_CONFIG_HOME=str(h),CLAUDE_CONFIG_DIR=str(h))
for k in list(env):
 if k.startswith(('CODEX_','CLAUDE_')):env.pop(k,None)
cases=[('clean-with-read-budget','test_ledger_schema_and_clean_run',{'FM_HEARTBEAT_READ_TIMEOUT':'15'}),('single-flight','test_watcher_runs_one_heartbeat_at_a_time',{}),('stale-bound','test_stale_bound_is_the_watcher_cycle_plus_the_grace',{}),('worst-age','test_worst_age_of_a_busy_healthy_home_stays_within_the_bound',{}),('calm-change','test_a_relevant_change_collects_without_waiting_for_idle',{}),('hot-change','test_a_change_under_load_waits_for_the_throttled_idle_due',{}),('rearm','test_rearmed_ticker_anchors_due_to_last_publication',{}),('failed-retry','test_failed_heartbeat_publications_keep_retry_interval',{})]
results=[]
for label,selector,extra in cases:
 e=env.copy();e.update(extra);cmd=['bash','tests/fm-heartbeat.test.sh',selector];start=time.time()
 with (ev/('hb-'+label+'.log')).open('w') as f:
  p=subprocess.Popen(cmd,env=e,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(240)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);rc=p.wait()
  try:os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError:pass
 r=dict(selector=selector,env=extra,exit=rc,seconds=round(time.time()-start,2));results.append(r);(ev/'heartbeat-focus-results.json').write_text(json.dumps(results,indent=2));print(r,flush=True)
print('COMPLETE',flush=True)
