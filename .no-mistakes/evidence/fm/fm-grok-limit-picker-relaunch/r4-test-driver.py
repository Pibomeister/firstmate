import pathlib,os,subprocess,time,signal,json,concurrent.futures,re
root=pathlib.Path.cwd(); scratch=root/'.test-r4';ev=pathlib.Path('~/.no-mistakes/evidence/01M7ZW57ECDC5EVWGNK2YVCK3E');bash=scratch/'tools/bash-5.2.37/bash'
(scratch/'bin').mkdir(exist_ok=True);(scratch/'bin/bash').symlink_to(bash)
env=os.environ.copy();env.update(PATH=str(scratch/'bin')+':'+env['PATH'],TMPDIR=str(scratch/'tmp'),FM_TEST_SKIP_ORPHAN_REAP='1',LC_ALL='en_US.UTF-8')
suites=['fm-composer-lib','fm-control-relaunch','fm-backend-herdr','fm-watch-inbox-recovery']
focused={
'fm-composer-lib':['test_grok_weekly_limit_choice_is_named_only_in_its_recorded_structure'],
'fm-control-relaunch':['test_relaunch_closes_a_grok_weekly_limit_composer_without_typing_enter','test_relaunch_closes_a_grok_weekly_limit_composer_without_typing_enter "  │  Ctrl+e:expand thinking"','test_relaunch_closes_a_grok_weekly_limit_composer_without_typing_enter "  │  Ctrl+e:expand thinking" --provider-failover','test_busy_relaunch_closes_a_grok_weekly_limit_after_interrupt','test_interrupt_refuses_a_grok_weekly_limit_and_names_relaunch','test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text'],
'fm-backend-herdr':['test_composer_state_grok_weekly_limit_live_shapes'],
'fm-watch-inbox-recovery':['test_watcher_grok_usage_limit_recover_names_relaunch']}
results=[]
def run(name,file,timeout):
 t=time.monotonic();log=ev/f'r4-{name}.log'
 with log.open('w') as out:
  p=subprocess.Popen([str(bash),str(file)],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  timed=False
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   timed=True;os.killpg(p.pid,signal.SIGTERM)
   try:rc=p.wait(timeout=8)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);rc=p.wait()
  # Reap any job descendants left in the suite's process group after its shell exits.
  try:os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError:pass
 r=dict(name=name,exit=rc,timed_out=timed,seconds=round(time.monotonic()-t,1),log=str(log));print(json.dumps(r),flush=True);return r
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
 results=list(pool.map(lambda n:run(n,root/'tests'/f'{n}.test.sh',180),suites))
for name,calls in focused.items():
 original=(root/'tests'/f'{name}.test.sh').read_text()
 filtered='\n'.join(line for line in original.splitlines() if not re.match(r'^test_\w+(?:\s.*)?$',line))
 file=root/'tests'/f'.r4-focused-{name}.sh';file.write_text(filtered+'\n'+'\n'.join(calls)+'\n')
 try:results.append(run('focused-'+name,file,120))
 finally:file.unlink()
base=scratch/'base-composer.sh';base.write_bytes(subprocess.check_output(['git','show','15bb485a1f31715251633818422931dacb8b8ec7:bin/fm-composer-lib.sh']))
original=(root/'tests/fm-composer-lib.test.sh').read_text();filtered='\n'.join(line for line in original.splitlines() if not re.match(r'^test_\w+(?:\s.*)?$',line));file=root/'tests/.r4-focused-base.sh'
file.write_text(filtered+'\nunset FM_COMPOSER_LIB_LOADED FM_COMPOSER_LIB_SOURCED\n. "'+str(base)+'"\ntest_grok_weekly_limit_choice_is_named_only_in_its_recorded_structure\n')
try:results.append(run('focused-base',file,45))
finally:file.unlink()
(ev/'r4-test-results.json').write_text(json.dumps(results,indent=2))
