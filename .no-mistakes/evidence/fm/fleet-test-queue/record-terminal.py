import os, pathlib, runpy, shutil, subprocess, sys
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5J6K3YB8DGYS48RTDZE0C2Q')
index=sys.argv[1]
case=root/'.test-phase-tmp'/('terminal-'+index)
case.mkdir(); (case/'spool').mkdir(); (case/'spool/config').write_text('slots=1\nload_ceiling=1000000\n')
os.environ.update(FM_TEST_QUEUE_DIR=str(case/'spool'),FM_TEST_QUEUE_POLL='0.1')
for name in ('FM_TEST_SEAM','FM_TEST_QUEUE_LOAD_FILE','FM_TEST_QUEUE_HELD'): os.environ.pop(name,None)
fd=os.open(evidence/('terminal-'+index+'.log'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
original_read=os.read
original_output=subprocess.check_output
previous=None
def record_read(*args,**kwargs):
    data=original_read(*args,**kwargs)
    os.write(fd,data)
    return data
def record_output(*args,**kwargs):
    global previous
    value=original_output(*args,**kwargs)
    if value!=previous:
        os.write(fd,('\n[observed subprocess response]\n'+str(value)+'\n').encode())
        previous=value
    return value
os.read=record_read
subprocess.check_output=record_output
sys.argv=[str(root/'tests/fm-test-queue-pty.py'),str(root/'bin/fm-test-queue.sh'),'/bin/bash',str(case)]
try:
    runpy.run_path(sys.argv[0],run_name='__main__')
    os.write(fd,b'\nPTY driver completed all assertions.\n')
finally:
    os.close(fd)
    shutil.rmtree(case)
