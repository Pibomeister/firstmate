import os,subprocess,json
rows=[x.split(None,2) for x in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines()]
root=95671
owned={root}; previous=set()
while previous!=owned:
 previous=set(owned)
 owned.update(int(pid) for pid,p,c in rows if int(p) in owned)
print(json.dumps([{'pid':int(pid),'ppid':int(p),'command':c} for pid,p,c in rows if int(pid) in owned],indent=2))
