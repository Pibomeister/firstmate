import pathlib,subprocess,os,hashlib
root=pathlib.Path.cwd();home=root/'.test-306/council';env=os.environ.copy();env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'))
for k in ['FM_ROOT_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM']:env.pop(k,None)
args=['bash','bin/fm-watchdog.sh','council','--task','live306','--key','flake','--record-file',str(home/'revisit.txt')]
def run(extra=[]):
 p=subprocess.run(args+extra,env=env,text=True,capture_output=True,timeout=30);print(p.stdout.strip(),flush=True);assert p.returncode==0,p.stderr;return p.stdout
out=run();assert 'prior=1' in out and 'council=no-ruling' in out
records=list((home/'data/watchdog/no-rulings').glob('*.md'));rec=next(p for p in records if '- key: flake\n' in p.read_text());before=rec.read_bytes();archives=list((home/'data/watchdog/revisits').glob('*.md'));assert archives,'successful no-ruling revisit should archive prior record'
print('Published revisit and archived prior record:\n'+rec.read_text(),flush=True)
print('Archived initial council:\n'+archives[0].read_text(),flush=True)
(home/'config/watchdog').write_text('mode=act\ncouncil-seats=agy:claude-sonnet-5-5-low,agy:gemini-3.8-flash-low\ndaily-max-usd=0\n')
with (home/'revisit.txt').open('a') as f:f.write('\nLater supervisor nudge: reconsider on a new isolated green run, retaining the accepted flake risk.\n')
out=run(['--revisit']);assert 'council=failed' in out
assert rec.read_bytes()==before,'failed revisit erased prior ruling'
assert len(list((home/'data/watchdog/revisits').glob('*.md')))==len(archives),'failed revisit archived the still-final prior record'
out=run();assert 'prior=1' in out and 'council=no-ruling' in out
print('Failed revisit left prior record byte-identical; ordinary call replayed it without reconvening.',flush=True)
