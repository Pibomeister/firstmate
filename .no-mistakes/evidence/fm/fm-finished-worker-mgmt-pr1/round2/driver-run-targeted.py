import os, subprocess, json, time, pathlib, signal
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY/round2')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'BASH_ENV')) and k not in ['TMUX','TMUX_PANE','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','ORCA_TERMINAL_HANDLE']}
env.update(TMPDIR=str(root/'.gate-tests/tmp'),FM_TEST_SKIP_ORPHAN_REAP='1',PATH=str(root/'.gate-tests/tools'))
checks=[['bash','tests/fm-load-throttle.test.sh'],['bash','tests/fm-heartbeat.test.sh','test_ledger_schema_and_clean_run','test_watcher_runs_one_heartbeat_at_a_time','test_stale_bound_is_the_watcher_cycle_plus_the_grace','test_worst_age_of_a_busy_healthy_home_stays_within_the_bound','test_a_relevant_change_collects_without_waiting_for_idle','test_a_change_under_load_waits_for_the_throttled_idle_due','test_rearmed_ticker_anchors_due_to_last_publication','test_failed_heartbeat_publications_keep_retry_interval'],['bash','tests/fm-home-summary-refresh.test.sh'],['bash','tests/fm-fleet-snapshot-view.test.sh'],['bash','tests/fm-watch-triage.test.sh']]
results=[]
for i,cmd in enumerate(checks):
    caseenv=env.copy(); user=root/'.gate-tests'/('suite-user-'+str(i)); user.mkdir(exist_ok=True); caseenv.update(HOME=str(user),XDG_CONFIG_HOME=str(user),CLAUDE_CONFIG_DIR=str(user))
    if i==4: caseenv['FM_TEST_ONLY']='test_attended_open_work_heartbeat_floor'
    log=ev/(pathlib.Path(cmd[1]).stem+'.log'); start=time.time()
    with log.open('w') as f:
        p=subprocess.Popen(cmd,env=caseenv,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        print('START',p.pid,' '.join(cmd),flush=True)
        try: rc=p.wait(timeout=1100)
        except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGTERM); time.sleep(2); os.killpg(p.pid,signal.SIGKILL); rc=p.wait()
        # Stop surviving descendants in this exact owned process group.
        try: os.killpg(p.pid,signal.SIGTERM)
        except (ProcessLookupError,PermissionError): pass
    results.append(dict(command=cmd,exit=rc,seconds=round(time.time()-start,2),log=str(log)))
    (ev/'targeted-results.json').write_text(json.dumps(results,indent=2))
    print('END',rc,log,flush=True)
(ev/'targeted-complete.json').write_text(json.dumps(dict(completed=True,results=results),indent=2)); print(json.dumps(results,indent=2),flush=True)
