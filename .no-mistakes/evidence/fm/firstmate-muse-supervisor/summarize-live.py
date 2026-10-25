import pathlib,json,datetime
E=pathlib.Path('/Users/eduardopicazo/.no-mistakes/evidence/01M5SR4CY3DAZS9MTQQYD0FDZG')
l=pathlib.Path((E/'lab-path.txt').read_text()); p=next((l/'xdgdata/muse/sessions').glob('*/*/*/*/session.jsonl'))
out=[]; structured=[]
for s in p.read_text().splitlines():
 try: x=json.loads(s)
 except ValueError: continue
 q=x.get('payload',{}); ev=q.get('event',{}); kind=ev.get('kind'); at=x.get('recorded_at',0)
 stamp=datetime.datetime.fromtimestamp(at/1e6,datetime.timezone.utc).isoformat()
 if q.get('kind')=='run' and kind in ('started','terminal'):
  out.append(stamp+' RUN '+kind+' '+json.dumps(ev)); structured.append({'at':at,'run':q['run_id'],'event':ev})
 if kind=='assistant_tool_calls_committed':
  for t in ev['tool_calls']: out.append(stamp+' TOOL '+t['name']+' '+t['args']);structured.append({'at':at,'run':q['run_id'],'tool':t})
 if kind=='tool_result_batch_committed':
  for r in ev['results']: out.append(stamp+' RESULT '+r['text'])
 if q.get('kind')=='task' and kind=='output' and ev.get('final_result'):
  # Retain background completion output even when there is no foreground result batch.
  out.append(stamp+' TASK FINAL '+ev.get('chunk',''))
(E/'live-transcript.txt').write_text('\n\n'.join(out)+'\n')
(E/'live-timing.json').write_text(json.dumps(structured,indent=2))
print('\n\n'.join(out[-8:])[-11000:])
