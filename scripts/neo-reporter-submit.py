"""neo-reporter-submit: one incident report per connection on the reporter socket.

Started by neo-reporter-submit.socket (Accept=yes) with the connection on
stdin/stdout. Reads one bounded request, identifies the caller (SO_PEERCRED),
validates it, applies a per-uid rate limit, adds host metadata and POSTs it
to the configured endpoint with the Bearer token from the systemd credential
"token". Answers one JSON line. The token never leaves this process.

Request: a JSON object
  {"text": str, "title": str, "severity": str, "unit": str, "kind": str,
   "payload": {...incident fields...}, "dry_run": bool}
or plain UTF-8 text (= {"text": ...}).

Answer: {"ok": bool, "code": posted|duplicate|dry_run|invalid|too_large|
         rate_limited|not_configured|http_error, ...}
"""
import fcntl
import hashlib
import json
import os
import pwd
import re
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

MAX_REQUEST = int(os.environ.get("NEO_REPORTER_MAX_BYTES", 64 * 1024))
READ_TIMEOUT = float(os.environ.get("NEO_REPORTER_READ_TIMEOUT", 5))
HTTP_TIMEOUT = float(os.environ.get("NEO_REPORTER_HTTP_TIMEOUT", 20))
RATE_BURST = int(os.environ.get("NEO_REPORTER_RATE_BURST", 5))
RATE_PERIOD = float(os.environ.get("NEO_REPORTER_RATE_PERIOD", 120))
CONFIG = os.environ.get("NEO_REPORTER_CONFIG", "/etc/neo-reporter/config.json")
SEVERITIES = ("info", "warning", "error", "critical")
UNIT_RE = re.compile(r"^[A-Za-z0-9@._:+-]{1,200}$")
KIND_RE = re.compile(r"^[a-z0-9-]{1,32}$")
HASH_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


class Reject(Exception):
    def __init__(self, code, error):
        super().__init__(error)
        self.code = code
        self.error = error


def peer_uid(sock):
    try:
        raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", raw)[1]
    except OSError:
        return None


def role(uid, hermes_user=None):
    """Who sent it, without a personal user name: root, hermes or uid-<n>."""
    hermes_user = hermes_user or os.environ.get("NEO_REPORTER_HERMES_USER", "hermes")
    if uid is None:
        return "unknown"
    if uid == 0:
        return "root"
    try:
        if pwd.getpwuid(uid).pw_name == hermes_user:
            return hermes_user
    except KeyError:
        pass
    return f"uid-{uid}"


def read_request(sock, limit=MAX_REQUEST):
    sock.settimeout(READ_TIMEOUT)
    buf = bytearray()
    while True:
        try:
            chunk = sock.recv(min(65536, limit + 1 - len(buf)))
        except socket.timeout:
            raise Reject("invalid", "timed out reading the request")
        if not chunk:
            return bytes(buf)
        buf += chunk
        if len(buf) > limit:
            raise Reject("too_large", f"request larger than {limit} bytes")


def parse_request(raw):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Reject("invalid", "request is not UTF-8")
    s = text.strip()
    if s.startswith("{"):
        try:
            req = json.loads(s)
        except ValueError:
            raise Reject("invalid", "request looks like JSON but does not parse")
        if not isinstance(req, dict):
            raise Reject("invalid", "request must be a JSON object")
        return req
    return {"text": text}


def _str(v, name, maxlen):
    if v is None:
        return None
    if not isinstance(v, str):
        raise Reject("invalid", f"{name} must be a string")
    v = v.strip()
    if len(v) > maxlen:
        raise Reject("invalid", f"{name} longer than {maxlen} characters")
    return v or None


def read_first_line(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.readline().strip()
    except OSError:
        return ""


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def neo_version():
    for p in ("/run/current-system/nixos-version", "/etc/os-release"):
        v = read_first_line(p)
        if v:
            return v[:100]
    return "unknown"


def build_incident(req, sender, machine, reporter_id):
    payload = req.get("payload")
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise Reject("invalid", "payload must be a JSON object")
    text = _str(req.get("text"), "text", MAX_REQUEST) or _str(payload.get("logs_excerpt"), "logs_excerpt", MAX_REQUEST)
    if not text:
        raise Reject("invalid", "empty report: give a text (argument or stdin) or payload.logs_excerpt")
    severity = _str(req.get("severity"), "severity", 16) or _str(payload.get("severity"), "severity", 16) or "error"
    if severity not in SEVERITIES:
        raise Reject("invalid", "severity must be info|warning|error|critical")
    unit = _str(req.get("unit"), "unit", 200) or _str(payload.get("unit"), "unit", 200) or "send-report"
    if not UNIT_RE.match(unit):
        raise Reject("invalid", "unit may only contain letters, digits and @._:+-")
    kind = _str(req.get("kind"), "kind", 32) or _str(payload.get("kind"), "kind", 32) or "manual"
    if not KIND_RE.match(kind):
        raise Reject("invalid", "kind must match [a-z0-9-]{1,32}")
    title = _str(req.get("title"), "title", 200) or _str(payload.get("target_hint"), "target_hint", 200) or text.splitlines()[0][:200]
    version = _str(payload.get("neo_version"), "neo_version", 200) or neo_version()
    report_hash = _str(payload.get("report_hash"), "report_hash", 128)
    if report_hash is not None and not HASH_RE.match(report_hash):
        raise Reject("invalid", "report_hash must match [A-Za-z0-9._:-]{1,128}")
    if report_hash is None:
        report_hash = "sr-" + hashlib.sha256("\0".join([machine, unit, title, text]).encode()).hexdigest()[:32]
    header = f"[send-report kind={kind} submitted_by={sender} machine={machine}]"
    return {
        "report_hash": report_hash,
        "neo_version": version,
        "unit": unit,
        "logs_excerpt": header + "\n" + text,
        "severity": severity,
        "target_hint": title,
        "kind": kind,
        "machine": machine,
        "submitted_by": sender,
        "reporter_id": reporter_id,
        "customer_repo_slug": reporter_id,
    }


def rate_limit(state_dir, uid, now=None):
    """Token bucket per uid (RATE_BURST reports, one more every RATE_PERIOD s)."""
    if RATE_BURST <= 0:
        return True, 0
    now = time.time() if now is None else now
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, "rate.json")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            state = json.loads(f.read() or "{}")
        except ValueError:
            state = {}
        key = str(uid)
        tokens, last = state.get(key, [RATE_BURST, now])
        tokens = min(RATE_BURST, tokens + (now - last) / RATE_PERIOD)
        ok = tokens >= 1
        if ok:
            tokens -= 1
        state[key] = [tokens, now]
        # forget idle senders
        state = {k: v for k, v in state.items() if now - v[1] < RATE_PERIOD * RATE_BURST * 2 or k == key}
        f.seek(0)
        f.truncate()
        f.write(json.dumps(state))
        wait = 0 if ok else int((1 - tokens) * RATE_PERIOD) + 1
    return ok, wait


def post(endpoint, token, body):
    data = json.dumps(body).encode()
    rq = urllib.request.Request(endpoint, data=data, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "neo-reporter-submit",
    })
    try:
        with urllib.request.urlopen(rq, timeout=HTTP_TIMEOUT) as r:
            status, text = r.status, r.read(65536).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read(65536).decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        return {"ok": False, "code": "http_error", "error": f"transport error: {type(reason).__name__}"}
    try:
        resp = json.loads(text)
    except ValueError:
        resp = {}
    if 200 <= status < 300:
        inc = resp.get("incident") if isinstance(resp.get("incident"), dict) else {}
        created = resp.get("created", status == 201)
        return {
            "ok": True,
            "code": "posted" if created else "duplicate",
            "http_status": status,
            "incident": {k: inc.get(k) for k in ("id", "status", "report_hash") if k in inc} or {"report_hash": body["report_hash"]},
        }
    err = resp.get("error") if isinstance(resp, dict) else None
    return {"ok": False, "code": "http_error", "http_status": status, "error": str(err or "endpoint refused the report")[:200]}


def handle(raw, uid, *, creds_dir, state_dir, machine=None, hermes_user=None):
    try:
        req = parse_request(raw)
        cfg = load_json(CONFIG)
        overrides = load_json(os.path.join(creds_dir, "overrides.json")) if creds_dir else {}
        endpoint = overrides.get("ingest_url") or overrides.get("ops_ingest_url") or cfg.get("endpoint")
        reporter_id = (overrides.get("reporter_id") or overrides.get("repo_slug") or overrides.get("customer_repo_slug")
                       or cfg.get("reporterId") or "unknown")
        machine = machine or socket.gethostname().split(".")[0]
        sender = role(uid, hermes_user)
        body = build_incident(req, sender, machine, str(reporter_id))
        token = read_first_line(os.path.join(creds_dir, "token")) if creds_dir else ""
        token_state = "missing" if not token else ("placeholder" if token.startswith("replace-") else "present")
        if req.get("dry_run") is True:
            return {"ok": True, "code": "dry_run", "endpoint": endpoint, "token": token_state, "body": body}
        if not endpoint:
            raise Reject("not_configured", "no endpoint configured ([services.reporter] endpoint)")
        if token_state != "present":
            raise Reject("not_configured", f"ingest token {token_state} ([services.reporter] token); not posted")
        ok, wait = rate_limit(state_dir, uid if uid is not None else -1)
        if not ok:
            raise Reject("rate_limited", f"too many reports from {sender}; retry in {wait}s")
        res = post(endpoint, token, body)
        res.setdefault("report_hash", body["report_hash"])
        return res
    except Reject as r:
        return {"ok": False, "code": r.code, "error": r.error}


def main():
    sock = socket.socket(fileno=0)
    uid = peer_uid(sock)
    try:
        raw = read_request(sock)
        res = handle(raw, uid, creds_dir=os.environ.get("CREDENTIALS_DIRECTORY", ""),
                     state_dir=os.environ.get("STATE_DIRECTORY", "/var/lib/neo-reporter"))
    except Reject as r:
        res = {"ok": False, "code": r.code, "error": r.error}
    who = role(uid)
    print(f"neo-reporter-submit: from {who}: {res.get('code')}"
          + (f" incident #{res['incident'].get('id')}" if res.get("incident", {}).get("id") else "")
          + (f" ({res['error']})" if res.get("error") else ""), file=sys.stderr)
    try:
        sock.sendall((json.dumps(res) + "\n").encode())
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
