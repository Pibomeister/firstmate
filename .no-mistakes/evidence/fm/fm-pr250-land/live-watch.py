import subprocess, pathlib, os, json, time, shutil
root=pathlib.Path.cwd(); ev=pathlib.Path('~/.no-mistakes/evidence/01M80ZVADJ5BSSJW7H9CA89HYN'); scratch=root/'.test-live-watch'; lab=scratch/'home'
scratch.mkdir(); log=(ev/'live-watch-transcript.log').open('w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('HERDR_') or k in ['TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','ORCA_TERMINAL_HANDLE','REX_SESSION','REX_BLOCK']: env.pop(k,None)
env.update(FM_HOME=str(lab),FM_WATCH_HANDLING_SUCCESSOR='1',FM_WATCH_ONCE='1',FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HEARTBEAT_BIN='true',FM_SIGNAL_GRACE='0',FM_WORKTREE_CLEANUP='0')
def run(args,timeout=180):
 log.write('$ '+' '.join(map(str,args))+'\n'); p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout); log.write(p.stdout+f'EXIT {p.returncode}\n'); assert p.returncode==0,p.stdout; return p.stdout
def tm(*a): return run(['bash','bin/fm-lab-home.sh','tmux',lab,*a])
def meta(task,priority,window=None):
 (lab/'state'/f'{task}.meta').write_text(f'window=proof:{window or "fm-"+task}\nbackend=tmux\nkind=ship\nharness=bash\npriority={priority}\n')
def status(task,s): (lab/'state'/f'{task}.status').write_text(s)
def append(task,s):
 with (lab/'state'/f'{task}.status').open('a') as f:f.write(s)
def poll(now,label):
 env['FM_WATCH_NOW']=str(now); run(['bash','bin/fm-watch.sh'],timeout=240)
 q=lab/'state/.wake-queue'; text=q.read_text() if q.exists() else ''; (ev/f'watch-{label}-queue.tsv').write_text(text); log.write('PERSISTED QUEUE\n'+text); return [x for x in text.splitlines() if ' (P0 blocker ' in x]
try:
 run(['bash','bin/fm-lab-home.sh','create',lab]); tm('new-session','-d','-s','proof','-n','fm-p0','-x','120','-y','40','/bin/bash --noprofile --norc');
 for p in range(1,5): tm('new-window','-t','proof','-n',f'fm-p{p}','/bin/bash --noprofile --norc'); meta(f'p{p}',p); status(f'p{p}','blocked [at=1000]: ordinary priority blocker\n')
 meta('p0',0); status('p0','blocked [key=k] [at=1000]: need local deployment key\n')
 tm('new-window','-t','proof','-n','fm-question','/bin/bash --noprofile --norc'); meta('question',0); status('question','needs-decision [key=q] [at=1000]: choose local fixture\n')
 assert len(poll(1599,'early'))==0
 assert len(poll(1600,'due'))==1
 marker=lab/'state/.p0-blocker-surfaced-p0'; first=marker.read_text(); assert first
 assert len(poll(1601,'repeat'))==1
 tm('new-window','-t','proof','-n','fm-p0-replacement','/bin/bash --noprofile --norc'); meta('p0',0,'fm-p0-replacement')
 assert len(poll(1602,'replacement'))==1; assert marker.read_text()==first
 f=lab/'state/p0.status'; f.chmod(0)
 try: assert len(poll(1603,'unreadable'))==1; assert marker.read_text()==first
 finally:f.chmod(0o644)
 assert len(poll(1604,'readable-again'))==1
 # Restore the same endpoint so distinct openings yield byte-identical payloads.
 meta('p0',0); append('p0','resolved [key=k]: answer consumed\nblocked [key=k] [at=1000]: need local deployment key\n')
 rows=poll(1600,'identical-reopen'); assert len(rows)==2
 assert rows[0].split('\t',4)[4]==rows[1].split('\t',4)[4]
 assert len(poll(1600,'reopen-repeat'))==2
 text=run(['bash','bin/fm-wake-drain.sh']); (ev/'watch-drain.txt').write_text(text)
 assert sum(' (P0 blocker ' in x for x in text.splitlines())==2
 log.write('OBSERVED: no alarm at age 599; one at 600; no repeat after endpoint replacement or unreadable log; identical reopenings both delivered; priorities 1-4 and needs-decision had no P0 alarm.\n')
 (ev/'live-watch-result.json').write_text(json.dumps({'result':'pass','surface':'real fm-watch.sh and fm-wake-drain.sh, real private tmux, synthetic status records and clock'},indent=2))
finally:
 try:tm('kill-server')
 except Exception as e:log.write('cleanup '+str(e)+'\n')
 run(['bash','bin/fm-lab-home.sh','teardown',lab]); shutil.rmtree(scratch); log.close()
