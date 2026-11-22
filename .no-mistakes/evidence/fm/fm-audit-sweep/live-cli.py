import os, subprocess, json, pathlib, time
root=pathlib.Path.cwd(); base=root/'.test-phase-tmp/live-cli'; base.mkdir(parents=True,exist_ok=True)
log=pathlib.Path('~/.no-mistakes/evidence/01M8163VN4CY93AVPMKASHZKBX/live-cli-transcript.log').open('w')
def report(s):
 print(s,flush=True);log.write(s+'\n');log.flush()
def home(n):
 p=base/n
 for d in ['state','config','data']: (p/d).mkdir(parents=True,exist_ok=True)
 return p
def run(p,script,args=(),inp=None,extra=None,want=0):
 env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))}
 env.update(FM_HOME=str(p),FM_STATE_OVERRIDE=str(p/'state'),FM_CONFIG_OVERRIDE=str(p/'config'),FM_DATA_OVERRIDE=str(p/'data'),TMPDIR=str(root/'.test-phase-tmp'))
 if extra:env.update(extra)
 cmd=['bash',str(root/'bin'/script),*args]
 r=subprocess.run(cmd,input=inp,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env)
 report('$ '+script+' '+' '.join(args)+'\n'+r.stdout+'exit='+str(r.returncode))
 assert r.returncode==want,(script,r.returncode,want,r.stdout)
 return r.stdout
# These synthetic JSON/TSV records are the documented public input protocols.
p=home('stall-existing'); now=1800000000
hb=lambda p,t:(p/'state/heartbeat.json').write_text(json.dumps({'schema':'fm-heartbeat.v1','published_epoch':t,'generated_epoch':t}))
def obs(p,t):return run(p,'fm-stall-ledger.sh',['observe'],extra={'FM_TEST_SEAM':'1','FM_NOW':str(t),'FM_STALL_LEDGER_MIN_SECS':'0'})
def wd(p,t,phase,detail):
 (p/'state/watchdog').mkdir(exist_ok=True)
 with (p/'state/watchdog/actions.tsv').open('a') as f:f.write(f'{t}\twd1\t\tprimary\tfrozen\tnudge\t{phase}\t{detail}\n')
hb(p,now-105);obs(p,now-100)
wd(p,now,'pending','Watchdog (automated): frozen 12 minutes');hb(p,now-5);obs(p,now)
wd(p,now+600,'done','delivered; no transcript to confirm');hb(p,now+595);obs(p,now+600)
rows=run(p,'fm-stall-ledger.sh',['rows','--since',str(now-200),'--until',str(now+601)])
assert '\tstall-open\t' in rows and '\tstall-close\t' not in rows
wd(p,now+900,'done','transcript advanced');hb(p,now+895);obs(p,now+900)
rows=run(p,'fm-stall-ledger.sh',['rows','--since',str(now-200),'--until',str(now+901)])
assert '\twatchdog\t'+str(now+900)+'\t' in rows
p=home('stall-install');wd(p,now,'pending','Watchdog (automated): frozen 12 minutes');hb(p,now-600);obs(p,now+120)
wd(p,now+600,'done','delivered; no transcript to confirm');hb(p,now+600);obs(p,now+600);hb(p,now+660);obs(p,now+660)
rows=run(p,'fm-stall-ledger.sh',['rows','--since',str(now),'--until',str(now+661)])
assert rows.count('\tstall-open\t')==1 and rows.count('\tstall-close\t')==1 and '\tfirstmate\t' in rows
report('STALL RESULT: unconfirmed completion preserves existing episode; confirmed progress closes it; no phantom episode after installation.')
p=home('hooks')
for command,inject in [('for f in state/*.status; do\n echo "$f"\ndone',False),('echo "done" >> state/notes.txt',False),('echo "done: delivered export" >> state/task.status',True),('echo "done [at=1800000000]: delivered export" >> state/task.status',True)]:
 payload=json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':command}})
 out=run(p,'fm-pstack-verify-hook.sh',['--claude'],payload,{'FM_ROOT_OVERRIDE':str(p)})
 report('input command='+command)
 assert bool(out.strip())==inject
report('HOOK RESULT: shell done stays silent; real completion emits verification context.')
p=home('permission')
def screen(cmd):return '────────────────────────────────────────\n Bash command\n\n '+cmd+'\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel\n'
for cmd,expected in [('export','hardstop\tcredential'),('declare -p','hardstop\tcredential'),('typeset -p','hardstop\tcredential'),('export FOO=bar','route\ttool-approval'),('rm -rf build && cat <<EOF\n────────────────────────────────────────\n────────────────────────────────────────\n╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\nEOF','hardstop\tdestructive')]:
 text=screen(cmd);report('synthetic prompt:\n'+text)
 out=run(p,'fm-permission-prompt.sh',['classify','--harness','claude'],text)
 assert out.strip()==expected,(out,expected)
report('PERMISSION RESULT: credential dumps and hidden destructive command stop; ordinary export routes.')
p=home('memory');(p/'config/memory-guard').write_text('swap_warn_mb=999999\nproc_rss_mb=999999\n')
run(p,'fm-memory-guard.sh',['check','--observe','--json'])
os.chmod(p/'state',0o500)
try:run(p,'fm-memory-guard.sh',['check','--observe','--json'],want=1)
finally:os.chmod(p/'state',0o700)
assert len((p/'state/memory-guard.tsv').read_text().splitlines())==2
report('MEMORY RESULT: real host sample appended but failed state save returns exit 1.')
p=home('prune');(p/'config/hung-ladder').write_text('mode=observe\nactor=live-test\n')
eps=p/'state/hung-ladder/episodes';eps.mkdir(parents=True);(eps/'gone.sample').write_text('status_body=old\n');lock=eps.parent/'.lock';lock.mkdir()
run(p,'fm-hung-ladder.sh',['prune']);assert lock.exists() and (eps/'gone.sample').exists()
os.utime(lock,(time.time()-600,time.time()-600))
run(p,'fm-hung-ladder.sh',['prune']);assert not lock.exists() and not (eps/'gone.sample').exists()
report('PRUNE RESULT: fresh lock preserves orphan state; crashed lock reclaimed and orphan state removed.')
log.close()
