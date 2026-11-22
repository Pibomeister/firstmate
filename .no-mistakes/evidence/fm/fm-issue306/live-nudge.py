import pathlib,subprocess,os,time,json
root=pathlib.Path.cwd();h=root/'.test-306/nudge';None
socketdir=subprocess.check_output(['bin/fm-lab-home.sh','tmux-dir',str(h)],text=True).strip();env=os.environ.copy()
for key in ['CLAUDECODE','NO_MISTAKES_GATE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TEST_SEAM','FM_GATE_REFUSE_BYPASS']:env.pop(key,None)
env.update(FM_HOME=str(h),TMUX_TMPDIR=socketdir,TMUX=socketdir+'/tmux-'+str(os.getuid())+'/fm-lab,0,0')
subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-n','fm-park','-x','160','-y','45','-c',str(root),'-e','FM_HOME='+str(h),'claude'],env=env,check=True)
time.sleep(6)
try:
 pid=int(subprocess.check_output(['tmux','-L','fm-lab','display-message','-p','-t','primary','#{pane_pid}'],env=env,text=True).strip());sid='11111111-1111-4111-8111-111111111111';now=int(time.time())
 (h/'state/.lock').write_text(str(pid)+'\n');(h/'state/.lock-session').write_text(sid+'\n')
 (h/'state/heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','generated_epoch':now,'primary':{'terminal':{'backend':'tmux','target':'primary:fm-park','present':True},'session':{'trusted_id':sid},'writer':{'anchor_pid':pid,'session_id':sid}}}))
 (h/'config/watchdog').write_text('mode=dry-run\nmodels=\nquota-guard=off\nmemory-guard=off\nheartbeat-frozen-secs=0\nclaude-config-dirs='+str(h/'no-transcripts')+'\n')
 (h/'state/t1.status').write_text('needs-decision [at='+str(now-9000)+'] [key=nm-306-test]: G3 per Firstmate issue #306, PR #562 no-mistakes test awaiting_approval. A approve the park, B schedule a rerun?\n')
 p=subprocess.run(['bash','bin/fm-watchdog.sh','once','--dry-run'],env=env,text=True,capture_output=True,timeout=60);print('once --dry-run exit='+str(p.returncode)+'\n'+p.stdout+p.stderr);assert p.returncode==0
 text=(h/'state/watchdog/actions.tsv').read_text();print('Operator dry-run action ledger:\n'+text)
 assert '(PR #562)' in text and '(PR #306)' not in text,text
 print('Operator status:\n'+(h/'data/watchdog/status.md').read_text())
finally:
 subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,check=True)
 subprocess.run(['bin/fm-lab-home.sh','teardown',str(h)],check=True)
