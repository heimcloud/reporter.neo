"""Unit + end-to-end tests for send-report / neo-reporter-submit.

End-to-end: a temp unix socket stands in for neo-reporter-submit.socket
(Accept=yes: one server process per connection, the connection on
stdin/stdout), a local HTTP server stands in for the ingest endpoint.

    python3 -m unittest discover -s test -p 'test_*.py'
    SUBMIT_BIN=… SEND_BIN=… python3 test/test_send_report.py   # built binaries
"""
import http.server
import importlib.util
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "scripts")
TOKEN = "tok-test-0123456789abcdef"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(SCRIPTS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


srv = load("neo-reporter-submit")
SUBMIT = shlex.split(os.environ.get("SUBMIT_BIN", f"{sys.executable} {os.path.join(SCRIPTS, 'neo-reporter-submit.py')}"))
SEND = shlex.split(os.environ.get("SEND_BIN", f"{sys.executable} {os.path.join(SCRIPTS, 'send-report.py')}"))


class Ingest(http.server.BaseHTTPRequestHandler):
    log = []
    status = 201

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n))
        Ingest.log.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        dup = any(e["body"]["report_hash"] == body["report_hash"] for e in Ingest.log[:-1])
        self.send_response(200 if dup else Ingest.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if Ingest.status >= 400:
            self.wfile.write(b'{"ok":false,"error":"unauthorized"}')
            return
        self.wfile.write(json.dumps({"ok": True, "created": not dup, "incident": {
            "id": len(Ingest.log), "status": "open", "report_hash": body["report_hash"]}}).encode())

    def log_message(self, *a):
        pass


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.creds = os.path.join(self.dir, "creds")
        self.state = os.path.join(self.dir, "state")
        os.makedirs(self.creds)
        self.write_token(TOKEN)
        self.write_json(os.path.join(self.creds, "overrides.json"), {})
        self.http = http.server.HTTPServer(("127.0.0.1", 0), Ingest)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.endpoint = f"http://127.0.0.1:{self.http.server_port}/api/incidents"
        self.config = os.path.join(self.dir, "config.json")
        self.write_json(self.config, {"endpoint": self.endpoint, "reporterId": "rid-test"})
        os.environ["NEO_REPORTER_CONFIG"] = self.config
        srv.CONFIG = self.config
        srv.RATE_BURST, srv.RATE_PERIOD = 5, 120
        Ingest.log, Ingest.status = [], 201

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.tmp.cleanup()

    def write_token(self, t):
        with open(os.path.join(self.creds, "token"), "w") as f:
            f.write(t + "\n" if t else "")

    def write_json(self, p, v):
        with open(p, "w") as f:
            json.dump(v, f)

    def handle(self, raw, uid=1234, **kw):
        if isinstance(raw, dict):
            raw = json.dumps(raw)
        if isinstance(raw, str):
            raw = raw.encode()
        return srv.handle(raw, uid, creds_dir=self.creds, state_dir=self.state, machine="host-a", **kw)


class Validation(Base):
    def test_text_posts_with_metadata(self):
        r = self.handle({"text": "disk full on /var\nmore lines", "unit": "neo-auto-update", "severity": "critical"})
        self.assertEqual(r["code"], "posted", r)
        self.assertEqual(r["incident"]["id"], 1)
        sent = Ingest.log[0]
        self.assertEqual(sent["auth"], f"Bearer {TOKEN}")
        b = sent["body"]
        self.assertEqual(b["unit"], "neo-auto-update")
        self.assertEqual(b["severity"], "critical")
        self.assertEqual(b["target_hint"], "disk full on /var")
        self.assertEqual(b["reporter_id"], "rid-test")
        self.assertEqual(b["customer_repo_slug"], "rid-test")
        self.assertEqual(b["machine"], "host-a")
        self.assertEqual(b["submitted_by"], "uid-1234")
        self.assertTrue(b["report_hash"].startswith("sr-"))
        self.assertTrue(b["logs_excerpt"].startswith("[send-report kind=manual submitted_by=uid-1234 machine=host-a]\n"))

    def test_plain_text_request(self):
        r = self.handle("plain text report")
        self.assertEqual(r["code"], "posted", r)
        self.assertEqual(Ingest.log[0]["body"]["unit"], "send-report")
        self.assertEqual(Ingest.log[0]["body"]["severity"], "error")

    def test_roles(self):
        self.assertEqual(srv.role(0), "root")
        self.assertEqual(srv.role(None), "unknown")
        me = os.getuid()
        import pwd
        name = pwd.getpwuid(me).pw_name
        self.assertEqual(srv.role(me, hermes_user=name), name)
        self.assertEqual(srv.role(me, hermes_user="no-such-user-x"), f"uid-{me}")

    def test_payload_json(self):
        r = self.handle({"payload": {"report_hash": "abc-1", "unit": "neo activate", "logs_excerpt": "x"}})
        self.assertEqual(r["code"], "invalid")  # space in unit
        r = self.handle({"payload": {"report_hash": "abc-1", "unit": "neo-activate", "logs_excerpt": "boom",
                                     "severity": "warning", "target_hint": "flake input neo", "neo_version": "26.05"}})
        self.assertEqual(r["code"], "posted", r)
        b = Ingest.log[0]["body"]
        self.assertEqual((b["report_hash"], b["severity"], b["target_hint"], b["neo_version"]),
                         ("abc-1", "warning", "flake input neo", "26.05"))

    def test_flags_override_payload(self):
        self.handle({"payload": {"logs_excerpt": "x", "severity": "info", "unit": "a"}, "severity": "critical",
                     "unit": "b", "title": "T", "kind": "update"})
        b = Ingest.log[0]["body"]
        self.assertEqual((b["severity"], b["unit"], b["target_hint"], b["kind"]), ("critical", "b", "T", "update"))

    def test_rejects(self):
        cases = [
            ({"text": ""}, "empty"),
            ({"text": "   \n"}, "empty"),
            ({"text": "x", "severity": "fatal"}, "severity"),
            ({"text": "x", "kind": "Bad Kind"}, "kind"),
            ({"text": "x", "title": "t" * 201}, "title"),
            ({"text": 5}, "text"),
            ({"payload": [1]}, "payload"),
            ({"payload": {"logs_excerpt": "x", "report_hash": "a b"}}, "report_hash"),
            ("{not json", "JSON"),
        ]
        for req, word in cases:
            r = self.handle(req)
            self.assertEqual(r["code"], "invalid", (req, r))
            if word:
                self.assertIn(word, r["error"])
        self.assertEqual(Ingest.log, [])

    def test_non_utf8(self):
        self.assertEqual(self.handle(b"\xff\xfe report")["code"], "invalid")

    def test_dedup_same_report(self):
        a = self.handle({"text": "same", "unit": "u"})
        b = self.handle({"text": "same", "unit": "u"})
        self.assertEqual((a["code"], b["code"]), ("posted", "duplicate"))
        self.assertEqual(a["report_hash"], b["report_hash"])


class Config(Base):
    def test_token_missing_and_placeholder(self):
        self.write_token("")
        r = self.handle({"text": "x"})
        self.assertEqual((r["code"], "missing" in r["error"]), ("not_configured", True))
        self.write_token("replace-from-private-repo")
        r = self.handle({"text": "x"})
        self.assertEqual((r["code"], "placeholder" in r["error"]), ("not_configured", True))
        self.assertEqual(Ingest.log, [])

    def test_no_creds_dir(self):
        r = srv.handle(b"x", 1, creds_dir="", state_dir=self.state, machine="m")
        self.assertEqual(r["code"], "not_configured")

    def test_no_endpoint(self):
        self.write_json(self.config, {})
        self.assertEqual(self.handle({"text": "x"})["code"], "not_configured")

    def test_overrides_win(self):
        self.write_json(self.config, {"endpoint": "http://127.0.0.1:9/nope", "reporterId": "rid-nix"})
        self.write_json(os.path.join(self.creds, "overrides.json"),
                        {"ingest_url": self.endpoint, "repo_slug": "rid-meta"})
        r = self.handle({"text": "x"})
        self.assertEqual(r["code"], "posted", r)
        self.assertEqual(Ingest.log[0]["body"]["reporter_id"], "rid-meta")

    def test_dry_run_hides_token(self):
        r = self.handle({"text": "x", "dry_run": True})
        self.assertEqual((r["code"], r["token"], r["endpoint"]), ("dry_run", "present", self.endpoint))
        self.assertNotIn(TOKEN, json.dumps(r))
        self.assertEqual(Ingest.log, [])

    def test_http_errors(self):
        Ingest.status = 401
        r = self.handle({"text": "x"})
        self.assertEqual((r["code"], r["http_status"]), ("http_error", 401))
        self.assertNotIn(TOKEN, json.dumps(r))
        self.write_json(self.config, {"endpoint": "http://127.0.0.1:9/closed"})
        r = self.handle({"text": "y"})
        self.assertEqual(r["code"], "http_error")
        self.assertIn("transport", r["error"])


class RateLimit(Base):
    def test_bucket_per_uid(self):
        srv.RATE_BURST, srv.RATE_PERIOD = 2, 100
        codes = [self.handle({"text": f"r{i}"}, uid=1000)["code"] for i in range(3)]
        self.assertEqual(codes, ["posted", "posted", "rate_limited"])
        self.assertEqual(self.handle({"text": "other"}, uid=1001)["code"], "posted")
        self.assertEqual(len(Ingest.log), 3)

    def test_refill(self):
        srv.RATE_BURST, srv.RATE_PERIOD = 1, 10
        self.assertEqual(srv.rate_limit(self.state, 7, now=1000)[0], True)
        ok, wait = srv.rate_limit(self.state, 7, now=1001)
        self.assertEqual((ok, wait), (False, 10))
        self.assertEqual(srv.rate_limit(self.state, 7, now=1011)[0], True)
        self.assertEqual(oct(os.stat(os.path.join(self.state, "rate.json")).st_mode & 0o777), "0o600")

    def test_invalid_does_not_consume(self):
        srv.RATE_BURST = 1
        for _ in range(3):
            self.handle({"text": ""}, uid=5)
        self.assertEqual(self.handle({"text": "real"}, uid=5)["code"], "posted")


class EndToEnd(Base):
    """send-report → unix socket → one neo-reporter-submit per connection."""

    def setUp(self):
        super().setUp()
        self.sock_path = os.path.join(self.dir, "submit.sock")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.sock_path)
        self.listener.listen(8)
        self.env = dict(os.environ, CREDENTIALS_DIRECTORY=self.creds, STATE_DIRECTORY=self.state,
                        NEO_REPORTER_CONFIG=self.config, NEO_REPORTER_SOCKET=self.sock_path,
                        NEO_REPORTER_HERMES_USER="no-such-user-x")
        self.server_logs = []
        threading.Thread(target=self.accept_loop, daemon=True).start()

    def tearDown(self):
        self.listener.close()
        super().tearDown()

    def accept_loop(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            p = subprocess.run(SUBMIT, stdin=conn, stdout=conn, stderr=subprocess.PIPE, env=self.env, timeout=30)
            self.server_logs.append(p.stderr.decode())
            conn.close()

    def send(self, *args, stdin=None, env=None):
        p = subprocess.run(SEND + list(args), input=stdin, capture_output=True, env=env or self.env, timeout=30)
        return p.returncode, p.stdout.decode(), p.stderr.decode()

    def test_args_and_stdin(self):
        rc, out, err = self.send("--title", "e2e", "--severity", "warning", "--unit", "test.service", "hello", "world")
        self.assertEqual(rc, 0, err)
        self.assertIn("incident #1 filed (status open)", out)
        b = Ingest.log[0]["body"]
        self.assertEqual((b["target_hint"], b["severity"], b["unit"]), ("e2e", "warning", "test.service"))
        self.assertIn("hello world", b["logs_excerpt"])
        self.assertEqual(b["submitted_by"], f"uid-{os.getuid()}" if os.getuid() else "root")
        rc, out, err = self.send(stdin=b"from stdin\n")
        self.assertEqual(rc, 0, err)
        self.assertIn("incident #2", out)
        rc, out, _ = self.send(stdin=b"from stdin\n")
        self.assertEqual(rc, 0)
        self.assertIn("already on the board", out)
        self.assertTrue(any("posted incident #1" in log for log in self.server_logs), self.server_logs)

    def test_json_file_and_alias_semantics(self):
        p = os.path.join(self.dir, "p.json")
        self.write_json(p, {"report_hash": "h-1", "unit": "neo-auto-update", "logs_excerpt": "boom",
                            "severity": "error", "target_hint": "neo"})
        rc, out, err = self.send("--json", "--file", p)
        self.assertEqual(rc, 0, err)
        self.assertEqual(Ingest.log[0]["body"]["report_hash"], "h-1")
        rc, _, err = self.send("--json", stdin=b"[1]")
        self.assertEqual(rc, 2)

    def test_dry_run_never_shows_token(self):
        rc, out, err = self.send("--dry-run", "x")
        self.assertEqual(rc, 0, err)
        d = json.loads(out)
        self.assertEqual(d["token"], "present")
        self.assertNotIn(TOKEN, out + err + "".join(self.server_logs))
        self.assertEqual(Ingest.log, [])

    def test_oversize(self):
        rc, _, err = self.send(stdin=b"x" * (64 * 1024 + 1))
        self.assertEqual(rc, 2)
        self.assertIn("larger than", err)
        # a client that ignores the limit is cut off by the server
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.sock_path)
        try:
            s.sendall(b"y" * (200 * 1024))
        except OSError:
            pass
        s.shutdown(socket.SHUT_WR)
        ans = json.loads(s.makefile().readline())
        s.close()
        self.assertEqual(ans["code"], "too_large")
        self.assertEqual(Ingest.log, [])

    def test_exit_codes(self):
        self.write_token("")
        self.assertEqual(self.send("x")[0], 3)
        self.write_token(TOKEN)
        env = dict(self.env, NEO_REPORTER_RATE_BURST="1")
        self.env = env
        self.assertEqual(self.send("a")[0], 0)
        rc, _, err = self.send("b")
        self.assertEqual(rc, 4, err)
        self.assertIn("rate_limited", err)
        Ingest.status = 500
        self.env = dict(env, NEO_REPORTER_RATE_BURST="0")
        self.assertEqual(self.send("c")[0], 1)
        self.assertEqual(self.send("--severity", "bogus", "x")[0], 2)
        rc, _, err = self.send("x", env=dict(self.env, NEO_REPORTER_SOCKET=os.path.join(self.dir, "none.sock")))
        self.assertEqual(rc, 3)
        self.assertIn("not available", err)

    def test_slow_client_times_out(self):
        env = dict(self.env, NEO_REPORTER_READ_TIMEOUT="1")
        self.env = env
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.sock_path)
        s.sendall(b"partial")  # never shuts down the write side
        s.settimeout(10)
        ans = json.loads(s.makefile().readline())
        s.close()
        self.assertEqual(ans["code"], "invalid")
        self.assertIn("timed out", ans["error"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
