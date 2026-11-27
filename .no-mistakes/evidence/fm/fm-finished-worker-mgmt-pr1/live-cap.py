import os,time,json,subprocess,signal,shutil
from pathlib import Path
r=Path.cwd(); e=Path('~/.no-mistakes/evidence/01M853B1KZA5CJ3ZYAB8T66ECY'); p=r/'.test-live-cap'
subprocess.run([str(r/'bin/fm-lab-home.sh'),'create',str(p)],check=True,capture_output=True)
c=None
try:
 n=int(time.time());(p/'load').write_text('300 0 0\n');(p/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 (p/'state/dispatch-log.tsv').write_text(f'2026-11-26T18:00:00Z\t{n}\treceived\tsynthetic-goal\tsummary=synthetic pending goal\n')
 (p/'state/.last-heartbeat').touch();os.utime(p/'state/.last-heartbeat',(n-901,n-901));(p/'state/.heartbeat-streak').write_text('3\n')
 env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k not in ('TMUX','TMUX_PANE','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK')}
 env.update(HOME=str(p),FM_HOME=str(p),XDG_CONFIG_HOME=str(p/'xdg-config'),XDG_DATA_HOME=str(p/'xdg-data'),XDG_CACHE_HOME=str(p/'xdg-cache'),CLAUDE_CONFIG_DIR=str(p/'claude'),FM_TEST_SEAM='1',FM_LOAD_FILE=str(p/'load'),FM_WATCH_NOW=str(n),FM_WATCH_ONCE='1',FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='600',FM_HEARTBEAT_QUOTA_TIMEOUT='1',FM_HEARTBEAT_DISCOVERY_TIMEOUT='10')
 with (e/'live-cap.out').open('w') as o,(e/'live-cap.err').open('w') as err:
  c=subprocess.Popen([str(r/'bin/fm-watch.sh')],env=env,stdout=o,stderr=err,start_new_session=True);rc=c.wait(timeout=150)
 assert rc==0,rc
 out=(e/'live-cap.out').read_text();queue=(p/'state/.wake-queue').read_text()
 (e/'live-cap-queue.tsv').write_text(queue)
 assert 'heartbeat' in out.splitlines() and '\theartbeat\theartbeat\t' in queue,(out,queue)
 (e/'live-cap-result.json').write_text(json.dumps(dict(load=300,prior_heartbeat_age_secs=901,configured_base_secs=600,backoff_streak=3,exit=rc,observed_stdout=out,wake_queue=queue,result='pass'),indent=2)+'\n')
 print('Real one-poll primary watcher: high-load open goal still queued and surfaced heartbeat after 901 seconds; exit=0',flush=True)
finally:
 if c:
  try:os.killpg(c.pid,signal.SIGTERM)
  except ProcessLookupError:pass
  try:c.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(c.pid,signal.SIGKILL);c.wait()
  try:os.killpg(c.pid,signal.SIGKILL)
  except ProcessLookupError:pass
 shutil.rmtree(p)
