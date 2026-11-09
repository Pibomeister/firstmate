# Fake Factory web API for live validation. Responses come from files in DIR so
# the driver can mutate state between polls. Logs each request with its auth header.
import sys, os, json, http.server
DIR, PORT = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(DIR, "requests.log"), "a") as f:
            f.write("%s auth=%s\n" % (self.path, self.headers.get("Authorization")))
        p = self.path
        if os.path.exists(os.path.join(DIR, "status401")):
            return self.send(401, b'{"error":"unauthorized"}')
        if "/attention" in p: name = "attention.json"
        elif p.startswith("/web/config/models"): name = "models.json"
        elif p.startswith("/web/factory/projects/"): name = "project.json"
        else: return self.send(404, b"{}")
        fp = os.path.join(DIR, name)
        if not os.path.exists(fp): return self.send(404, b"{}")
        self.send(200, open(fp, "rb").read())
    def send(self, code, body):
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
