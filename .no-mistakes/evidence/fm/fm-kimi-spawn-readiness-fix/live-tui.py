import os, pathlib, subprocess, time, json, shutil
R=pathlib.Path.cwd()
E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M649GT90YA0AQX8YHNA4K4BZ')
L=R/('.test-kimi-lab/tui-'+os.environ.get('LIVE_KIMI_RUN',os.environ.get('LIVE_KIMI_ONLY','all')))
H=L/'home'
L.mkdir(parents=True,exist_ok=True)
base=os.environ.copy()
for k in list(base):
    if k in ('TMUX','TMUX_PANE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM') or k.startswith('HERDR_') or k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'):
        base.pop(k,None)
base.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args,env=base,check=True):
    return subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=check)
run([R/'bin/fm-lab-home.sh','create',H])
env=base.copy()
env.update(HOME=str(H),FM_HOME=str(H),KIMI_CODE_HOME=str(H/'.kimi-code'),KIMI_CODE_NO_AUTO_UPDATE='1',UV_PYTHON_INSTALL_DIR='/Users/eduardopicazo/.local/share/uv/python',TREEHOUSE_ROOT=str(L/'pool'),XDG_CONFIG_HOME=str(H/'.config'),XDG_DATA_HOME=str(H/'.local/share'),XDG_CACHE_HOME=str(H/'.cache'),SHELL='/bin/bash',FM_SPAWN_NO_GUARD='1',FM_KIMI_READY_POLLS='16',FM_KIMI_POLL_INTERVAL='0.5',FM_KIMI_DELIVERY_POLLS='5')
(H/'.kimi-code').mkdir()
(H/'.kimi-code/config.toml').write_text('default_model = ""\n')
(H/'config/crew-harness').write_text('kimi\n')
helper=R/'bin/fm-lab-home.sh'
def tm(*a,check=True): return run([helper,'tmux',H,*a],env,check)
K=shutil.which('kimi')
results={}
try:
    tm('new-session','-d','-s','firstmate','-x','80','-y','24','-c',R,'/bin/bash','--noprofile','--norc')
    env['TMUX_TMPDIR']=run([helper,'tmux-dir',H],env).stdout.strip()
    env['TMUX']=tm('display-message','-p','-t','firstmate','#{socket_path},#{pid},0').stdout.strip()
    for name,rows,mcp in [('normal',24,False),('short',7,False),('mcp',40,True)]:
        if os.environ.get('LIVE_KIMI_ONLY') and name != os.environ['LIVE_KIMI_ONLY']: continue
        project=L/name
        project.mkdir()
        (project/'README.md').write_text('A disposable real project.\n')
        if mcp:
            (project/'marker.sh').write_text('#!/bin/sh\nprintf server-started >> "'+str(L/'mcp-started')+'"\nsleep 10\n')
            (project/'marker.sh').chmod(0o755)
            (project/'.mcp.json').write_text(json.dumps({'mcpServers':{'seating-guard':{'command':str(project/'marker.sh')}}}))
        run(['git','-C',project,'init','-q','-b','main'],env)
        run(['git','-C',project,'add','.'],env)
        run(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial'],env)
        tm('set-option','-t','firstmate','default-size','80x'+str(rows))
        tm('resize-window','-t','firstmate','-x','80','-y',str(rows))
        task='kimi-tui-'+name
        run([R/'bin/fm-brief.sh',task,'labproject','--scout'],env)
        b=H/'data'/task/'brief.md'
        b.write_text(b.read_text().replace('{TASK}','Write OK kimi seated to report.md, then report done.').replace('{FIRSTMATE_SPEC}','Do not publish, change code, or start pipelines.'))
        logfile=open(E/(name+'-spawn.log'),'w')
        p=subprocess.Popen([str(R/'bin/fm-spawn.sh'),task,str(project),'--scout','--harness','kimi','--backend','tmux'],env=env,stdout=logfile,stderr=subprocess.STDOUT)
        previous={}
        captures=[]
        deadline=time.monotonic()+150
        while p.poll() is None and time.monotonic()<deadline:
            panes=tm('list-panes','-a','-F','#{window_name} #{pane_id}',check=False).stdout.splitlines()
            for row in panes:
                if not row.startswith('fm-'+task+' '): continue
                pane=row.split()[-1]
                if pane not in previous:
                    tm('resize-window','-t',pane,'-x','80','-y',str(rows))
                    (E/(name+'-grid.txt')).write_text(tm('display-message','-p','-t',pane,'#{pane_width}x#{pane_height}').stdout)
                text=tm('capture-pane','-p','-t',pane,check=False).stdout
                if text != previous.get(pane):
                    captures.append({'seconds':round(150-(deadline-time.monotonic()),2),'pane':pane,'text':text})
                    previous[pane]=text
                    if 'Trust this folder?' in text:
                        (E/(name+'-trust.txt')).write_text(text)
                    if 'LLM not set' in text:
                        (E/(name+'-model-unavailable.txt')).write_text(text)
            time.sleep(.2)
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=10)
        logfile.close()
        (E/(name+'-viewport-transcript.json')).write_text(json.dumps(captures,ensure_ascii=False,indent=2))
        refusal=H/'data'/task/'kimi-readiness-refusal.txt'
        if refusal.exists(): shutil.copyfile(refusal,E/(name+'-readiness-refusal.txt'))
        trust=H/'.kimi-code/workspace-trust'
        records=[]
        if trust.exists():
            records=[json.loads(x.read_text()) for x in trust.iterdir() if x.is_file()]
        results[name]={'spawn_exit':p.returncode,'captured_frames':len(captures),'trust_records':records,'mcp_command_ran':(L/'mcp-started').exists()}
        (E/('live-tui-results-'+os.environ.get('LIVE_KIMI_ONLY','all')+'.json')).write_text(json.dumps(results,indent=2))
        print(name,results[name],flush=True)
finally:
    tm('kill-server',check=False)
    run([helper,'teardown',H],env,False)
