import http.server, os, sys, json
fix = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(fix, 'requests.log'), 'a') as log:
            log.write('%s auth=%s\n' % (self.path, 'present' if self.headers.get('Authorization') else 'none'))
        p = self.path.split('?', 1)[0].strip('/').split('/')
        name = 'attention' if p[-1] == 'attention' else ('models' if p[-1] == 'models' else 'project')
        st = 200; body = b'{}'
        sp = os.path.join(fix, name + '.status'); bp = os.path.join(fix, name + '.json')
        if os.path.exists(bp): body = open(bp, 'rb').read()
        if os.path.exists(sp): st = int(open(sp).read().strip())
        self.send_response(st); self.send_header('Content-Type','application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(os.path.join(fix, 'port.tmp'), 'w').write(str(s.server_address[1])); os.rename(os.path.join(fix,'port.tmp'), os.path.join(fix,'port'))
s.serve_forever()
