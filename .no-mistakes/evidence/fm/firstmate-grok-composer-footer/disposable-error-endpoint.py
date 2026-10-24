from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import time
lab=Path(__file__).resolve().parent
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        n=int(self.headers.get('Content-Length','0'))
        self.rfile.read(n)
        with (lab/'endpoint.log').open('a') as f: f.write(f'POST {self.path} body_bytes={n}; delayed disposable 503\n')
        time.sleep(45)
        try:
            self.send_response(503)
            self.send_header('Content-Type','application/json')
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"Disposable composer-validation server failure","type":"server_error"}}')
        except (BrokenPipeError,ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
(lab/'endpoint.port').write_text(str(server.server_port))
server.serve_forever()
