import pathlib
import sys
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
files = ['once.out', 'once.err', 'reads.jsonl', 'replacements.log',
         'data/watchdog/status.md', 'complete.before', 'status.good',
         'queue.before', 'state/.wake-queue', 'status.before', 'state/keeper.status',
         'outward.log', 'targets']
for case in root.iterdir():
    if not case.is_dir():
        continue
    status = case / 'data/watchdog/status.md'
    heading = status.read_text().splitlines()[0] if status.is_file() else ''
    dest = out / case.name
    dest.mkdir(parents=True, exist_ok=True)
    for name in files:
        source = case / name
        if source.is_file():
            target = dest / name.replace('/', '__')
            text = source.read_text().replace(str(root), '<fixture-root>')
            if heading:
                text = text.replace(heading, '# Firstmate watchdog - isolated-test-host')
            target.write_text(text)
