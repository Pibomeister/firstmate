import pathlib,subprocess,os,json,time,sqlite3
root=pathlib.Path.cwd();lab=root/'.test-fm306/home';ev=pathlib.Path('~/.no-mistakes/evidence/01M7ZVEBH1V4QBZFMZ76991HYS'); run='01M7SNAPSHOTA0000000000001'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','NO_MISTAKES')) and k not in ['NM_HOME','TMUX','TMUX_PANE']};env.update(FM_HOME=str(lab),NM_HOME=str(lab/'nm'),FM_CREW_STATE_NO_FORGE='1')
# The recipient is a private tmux text sink. The real watchdog runs in preview mode.
def tmux(*args):return subprocess.check_output(['bash','bin/fm-lab-home.sh','tmux',str(lab),*args],env=env,text=True).strip()
try:
 tmux('new-session','-d','-s','primary','-x','160','-y','40','-c',str(root),'printf "Synthetic local preview recipient\\n"; exec cat')
 target=tmux('list-panes','-t','primary','-F','#{pane_id}')
 pid=int(tmux('list-panes','-t','primary','-F','#{pane_pid}'))
 env['TMUX']=tmux('display-message','-p','-t',target,'#{socket_path},#{pid},0')
 sid='30600000-0000-4000-8000-000000000001';now=int(time.time())
 (lab/'state/.lock').write_text(str(pid)+'\n');(lab/'state/.lock-session').write_text(sid+'\n')
 (lab/'state/heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','generated_epoch':now,'primary':{'terminal':{'backend':'tmux','target':target,'present':True},'session':{'trusted_id':sid},'writer':{'anchor_pid':pid,'session_id':sid}}}))
 # Existing native decision now names a real current failure; the held gap must identify #562.
 g={'summary':'T33: choose A approve the park or B schedule a low-load rerun.','findings':[{'id':'test-1','severity':'warning','action':'ask-user','description':'The test failed in code modified by this PR. Equivalent park: https://github.com/org/repo/pull/577.'}]}
 with sqlite3.connect(lab/'nm/state.sqlite') as db:db.execute("UPDATE step_results SET findings_json=? WHERE step_name='review'",(json.dumps(g),))
 (lab/'state/.nm-status-snapshot.json').unlink(missing_ok=True)
 (lab/'state/G3.status').write_text(f'needs-decision [at={now-4000}] [key=layout]: PR #578 test awaiting_approval. A (recommended) flat keys; B nested keys?\n')
 with (lab/'config/watchdog').open('a') as f:f.write('\nmode=dry-run\ndecisions=dry-run\ncouncil-seats=\nheartbeat-frozen-secs=0\nnudge-secs=0\n')
 p=subprocess.run(['bash','bin/fm-watchdog.sh','once','--dry-run'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 output='$ FM_HOME=<lab> bin/fm-watchdog.sh once --dry-run\n'+p.stdout+'\nexit='+str(p.returncode)+'\n\n'
 output+=(lab/'data/watchdog/status.md').read_text()+'\nGenerated nudge ledger:\n'
 ledger=(lab/'state/watchdog/actions.tsv').read_text(); nudges='\n'.join(l for l in ledger.splitlines() if '\tnudge\t' in l)
 output+=nudges+'\n';(ev/'watchdog-preview.txt').write_text(output)
 print(output)
 assert p.returncode==0
 assert 'PR #562' in output and 'PR #577' not in (lab/'data/watchdog/status.md').read_text()
 assert 'PR #578' in nudges and 'G3/layout' in nudges
 print('PASS: native held status and generated decision nudge retain PR identities')
finally:
 try:tmux('kill-server')
 except subprocess.CalledProcessError:pass
 subprocess.run(['bash','bin/fm-lab-home.sh','teardown',str(lab)],env=env,check=True)
