import os, pathlib, shutil, subprocess, time
root=pathlib.Path.cwd(); ev=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
case=root/'.test-phase-tmp/contracts'; case.mkdir(); spool=case/'spool'; spool.mkdir()
load=case/'load'; load.write_text('16\n'); (spool/'config').write_text('slots=1\nload_ceiling=16\n')
env=dict(os.environ, FM_TEST_QUEUE_DIR=str(spool),FM_TEST_QUEUE_POLL='.1',FM_TEST_SEAM='1',FM_TEST_QUEUE_LOAD_FILE=str(load))
env.pop('FM_TEST_QUEUE_HELD',None)
q=['/bin/bash',str(root/'bin/fm-test-queue.sh')]
log=(ev/'live-contracts-transcript.log').open('w')
ps=[]
def note(s): log.write(s+'\n');log.flush()
def call(args,input=None,expected=0,e=None):
 note('$ fm-test-queue.sh '+' '.join(args)); r=subprocess.run(q+args,env=e or env,input=input,capture_output=True,text=True);note('stdout:\n'+r.stdout+'stderr:\n'+r.stderr+'exit='+str(r.returncode));assert r.returncode==expected;return r.stdout
def until(fn):
 end=time.monotonic()+20
 while not fn():
  assert time.monotonic()<end,'timeout';time.sleep(.1)
try:
 note('Controlled load is product-supported FM_TEST_QUEUE_LOAD_FILE input; both workloads and the queue are real processes.')
 for name in ('head','follower'):
  p=subprocess.Popen(q+['run','--label',name,'--','/bin/sh','-c','echo "$2" >> "$1/order"','_',str(case),name],env=env,stdout=log,stderr=log);ps.append(p)
  until(lambda: ('waiting='+str(len(ps))) in subprocess.check_output(q+['status'],env=env,text=True))
 s=call(['status']);assert 'serving=0 waiting=2' in s and not (case/'order').exists()
 note('$ load input changes from 16 to 1');load.write_text('1\n')
 for p in ps: assert p.wait(timeout=20)==0
 note('$ cat workload-order\n'+(case/'order').read_text());assert (case/'order').read_text()=='head\nfollower\n'
 call(['status'])
 out=call(['run','--','/bin/sh','-c','IFS= read -r line; printf "INPUT=%s TZ=%s LC_ALL=%s\\n" "$line" "$TZ" "$LC_ALL"; echo diagnostic >&2; exit 7'],input='stdin-through-no-tty\n',expected=7,e=dict(env,TZ='America/Mexico_City',LC_ALL='C'))
 assert out=='INPUT=stdin-through-no-tty TZ=America/Mexico_City LC_ALL=C\n'
 call(['run','--','/bin/bash',str(root/'bin/fm-test-queue.sh'),'run','--','/bin/sh','-c','echo nested-workload; exit 3'],expected=3)
 call(['run','--','/bin/sh','-c','kill -TERM $$'],expected=143)
 call(['run'],expected=2)
 (spool/'config').write_text('slots=0\n');call(['run','--','/bin/sh','-c',': > "$1/should-not-run"','_',str(case)],expected=125);assert not (case/'should-not-run').exists()
 (spool/'config').write_text('slots=1\nload_ceiling=16\n');call(['status'])
 note('Live load boundary, no-tty I/O, environment, nesting, and exit contracts passed.')
finally:
 load.write_text('1\n')
 for p in ps:
  if p.poll() is None:
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 shutil.rmtree(case);log.close()
