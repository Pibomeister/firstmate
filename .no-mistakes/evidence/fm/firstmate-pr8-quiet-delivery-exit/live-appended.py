import pathlib, subprocess, os, json, shutil
R=pathlib.Path.cwd();E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5Z4KMK1FX0G4B29YQRJKJQG');L=R/'.test-tmp/appended-home';S=L/'state'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','HERDR_','TASKS_AXI_')) and k not in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE']}
env.update(FM_HOME=str(L),TMPDIR=str(R/'.test-tmp'))
log=(E/'live-appended.log').open('w',buffering=1)
def run(script,*args,ok=0):
 r=subprocess.run([str(R/'bin'/script),*map(str,args)],env=env,cwd=R,capture_output=True,text=True,timeout=90)
 log.write('$ '+script+' '+' '.join(map(str,args))+'\nexit='+str(r.returncode)+'\n'+r.stdout+r.stderr)
 if ok is not None:assert r.returncode==ok,(script,r.stdout,r.stderr)
 return r
try:
 run('fm-lab-home.sh','create',L)
 (L/'config/supervision-host-off').touch()
 env['FM_AFK_MODE']='quiet';run('fm-afk-contract.sh','enter');del env['FM_AFK_MODE']
 run('fm-afk-launch.sh','start-native')
 buf=S/'.subsuper-escalations';buf.write_text('original-live-detail\n')
 receipt=S/'.quiet-exit-receipt';receipt.mkdir()
 assert run('fm-afk-return.sh','begin',ok=None).returncode!=0
 assert buf.read_text()=='original-live-detail\n'
 receipt.rmdir()
 archive=next((S/'.subsuper-digests').iterdir())
 record=dict(schema='fm-quiet-exit.v1',id=(S/'.quiet-exit-pending').read_text().strip(),archive=str(archive),count=1)
 receipt.write_text(json.dumps(record))
 # This is persisted transaction input from a producer appending after receipt.
 with buf.open('a') as f:f.write('appended-live-detail\n')
 assert run('fm-afk-return.sh','check',ok=None).returncode!=0
 assert buf.read_text()=='original-live-detail\nappended-live-detail\n'
 archive.unlink()
 assert run('fm-afk-return.sh','check',ok=None).returncode!=0
 assert buf.read_text()=='original-live-detail\nappended-live-detail\n'
 receipt.unlink()
 run('fm-afk-return.sh','check')
 rec=json.loads(receipt.read_text());assert rec['count']==2
 recovered=pathlib.Path(rec['archive']).read_bytes()
 assert recovered==b'original-live-detail\nappended-live-detail\n' and not buf.exists()
 shutil.copyfile(rec['archive'],E/'appended-recovered-detail.txt');shutil.copyfile(receipt,E/'appended-recovered-receipt.json')
 log.write('LIVE RESULT: an older matching receipt never cleared newly appended detail; a missing archive also refused clearing; repair and retry archived both exact lines.\n')
finally:
 if L.exists():shutil.rmtree(L)
 log.write('CLEANUP: workspace lab removed.\n');log.close()
