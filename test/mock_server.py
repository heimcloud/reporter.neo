"""Tiny ingest mock: records each POST (headers + body) as JSON lines."""
import http.server, json, sys

LOG = sys.argv[2]
STATUS = int(sys.argv[3]) if len(sys.argv) > 3 else 201

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                "ctype": self.headers.get("Content-Type"), "body": json.loads(body)}) + "\n")
        self.send_response(STATUS)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
