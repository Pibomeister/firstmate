import pathlib,tempfile,subprocess,os,signal,time,shutil,json
root=pathlib.Path.cwd(); e=pathlib.Path('~/.no-mistakes/evidence/01M88ESZEM0X1FSQ08VFD3QR76')
h=pathlib.Path(tempfile.mkdtemp(prefix='.malformed-return-',dir=root))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK')}
env.update(FM_HOME=str(h),FM_HEARTBEAT_BIN='true')
p=None
try:
 subprocess.run(['/bin/bash','bin/fm-lab-home.sh','create',str(h)],env=env,check=True,capture_output=True)
 (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
 (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 record='version: 1\nentered: 2026-09-08T08:00:00Z\nentered_epoch: 123\nwords: |-\n  synthetic recovery words\n'
 (h/'state/.afk-contract').write_text(record)
 with (e/'malformed-return-stdout.txt').open('w') as out:
  p=subprocess.Popen(['/bin/bash','bin/fm-afk-return.sh','begin'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  started=time.monotonic(); manufactured=[]
  while time.monotonic()-started<90 and p.poll() is None:
   ledger=h/'state/postmortem-checklist.tsv'
   if ledger.exists():
    manufactured=ledger.read_text().splitlines()
    if len(manufactured)>=3:break
   time.sleep(.2)
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  elapsed=time.monotonic()-started
  # Reap any children still in the command's isolated process group.
  try:os.killpg(p.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  ledger=h/'state/postmortem-checklist.tsv'; manufactured=ledger.read_text().splitlines() if ledger.exists() else []
  details={'command':'FM_HOME=<disposable marked lab> bash bin/fm-afk-return.sh begin','input_posture':record,'elapsed_seconds':round(elapsed,2),'exit_after_controlled_stop':p.returncode,'first_manufactured_ledger_rows':manufactured[:5],'last_manufactured_ledger_row':manufactured[-1:] ,'observation':'The real return command began persisting January 1970 checklists from an invalid posture epoch. Stopped after three rows; it had not returned the recovery brief.','expected':'Malformed posture stays gated and presents recovery evidence without backfilling decades of unrelated mornings.'}
  assert len(manufactured)>=3 and manufactured[0].startswith('1970-01-01\t'),details
  (e/'malformed-return.json').write_text(json.dumps(details,indent=2)+'\n')
  print(json.dumps(details,indent=2))
finally:
 if p is not None and p.poll() is None:
  os.killpg(p.pid,signal.SIGKILL);p.wait()
 shutil.rmtree(h)
 print('Disposable reproduction lab removed.')
