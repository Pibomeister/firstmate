import sys, time, os
mode_file, tick = sys.argv[1], float(sys.argv[2])
picker = ['Background work is running','The following will stop when you exit:','shell · sleep 300',
          '❯ 1. Exit and stop tasks','  2. Move to background and exit','  3. Stay','Enter to confirm · Esc to cancel']
last = None
while True:
    try: mode = open(mode_file).read().strip()
    except Exception: mode = 'idle'
    if mode == 'exit': sys.exit(0)
    if mode == 'dialog': body = '\n'.join(picker)
    elif mode == 'busy': body = 'Working... (%ds)' % int(time.time())
    else: body = 'pi · waiting on the captain\n\n> \n\nctx 12%% · tick %d' % int(time.time() // tick)
    if body != last:
        sys.stdout.write('\033[2J\033[H' + body); sys.stdout.flush(); last = body
    time.sleep(0.3)
