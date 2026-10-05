# Serves pacing.html and stores POSTed stats in /tmp/pacing-stats.json.
import http.server, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
class H(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        open('/tmp/pacing-stats.json', 'wb').write(body)
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', 8765), H).serve_forever()
