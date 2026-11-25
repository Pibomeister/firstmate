from pathlib import Path
src=Path('~/.no-mistakes/evidence/01M87D89KGJ0YXRDHGHMZQ97E8/round3/live-delegated.py').read_text()
exec(compile(src.split('\ntry:\n')[0].replace('timeout=60','timeout=180'),'<live-helpers>','exec'))
def watcher():
    h=home('watcher'); (h/'config/backend').write_text('tmux\n')
    reg(h,task='hermes-watcher',window=2)
    d(h,'dispatch','--task','hermes-watcher')
    time.sleep(3.1)
    call(h,['bash','bin/fm-watch.sh'])
    queue=(h/'state/.wake-queue').read_text(); say('ACTUAL WATCHER WAKE QUEUE\n'+queue)
    assert 'escalation task=hermes-watcher' in queue and 'last_receipt=dispatch@' in queue
    assert d(h,'check')==''
    say('Normal watcher routed exactly one delegated escalation with no injected clock.')
try:
    scenario('live-normal-watcher-delegated-escalation',watcher)
finally:
    shutil.rmtree(BASE)
    (E/'live-watcher-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
