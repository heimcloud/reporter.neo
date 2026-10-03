"""send-report: file an incident report through the local reporter socket.

  send-report "text ..."            report the given text
  some-cmd | send-report            report stdin
  send-report --file report.txt     report a file ("-" = stdin)
  send-report --json --file p.json  send an incident JSON object (payload)

Options: --title, --severity info|warning|error|critical, --unit, --kind,
--dry-run (show what would be sent; nothing is posted), --quiet.

Any local user may call it. The ingest token stays with the root-owned
systemd credential of neo-reporter-submit; this program never sees it.

Exit: 0 posted/duplicate/dry-run, 1 transport/HTTP error, 2 usage/invalid/
too large, 3 not configured (no endpoint or token), 4 rate limited.
"""
import argparse
import json
import os
import socket
import sys

SOCKET = os.environ.get("NEO_REPORTER_SOCKET", "/run/neo-reporter/submit.sock")
MAX_REQUEST = int(os.environ.get("NEO_REPORTER_MAX_BYTES", 64 * 1024))
TIMEOUT = float(os.environ.get("NEO_REPORTER_CLIENT_TIMEOUT", 60))
EXIT = {"posted": 0, "duplicate": 0, "dry_run": 0, "http_error": 1, "invalid": 2,
        "too_large": 2, "not_configured": 3, "rate_limited": 4}


def die(msg, code=2):
    print(f"send-report: {msg}", file=sys.stderr)
    sys.exit(code)


def read_bounded(f):
    data = f.read(MAX_REQUEST + 1)
    if isinstance(data, str):
        data = data.encode()
    if len(data) > MAX_REQUEST:
        die(f"report larger than {MAX_REQUEST} bytes; trim it (e.g. | tail -c 60000)")
    return data.decode("utf-8", "replace")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="send-report", description=__doc__.split("\n\n")[0])
    ap.add_argument("text", nargs="*", help="report text (default: stdin)")
    ap.add_argument("--title")
    ap.add_argument("--severity", choices=["info", "warning", "error", "critical"])
    ap.add_argument("--unit")
    ap.add_argument("--kind")
    ap.add_argument("--file", "-f", help="read the report from a file ('-' = stdin)")
    ap.add_argument("--json", action="store_true", help="input is an incident JSON object")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--quiet", "-q", action="store_true")
    ap.add_argument("--socket", default=SOCKET, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)

    if a.text and a.file:
        die("give the text as arguments or --file, not both")
    if a.text:
        text = " ".join(a.text)
    elif a.file and a.file != "-":
        try:
            with open(a.file, "rb") as f:
                text = read_bounded(f)
        except OSError as e:
            die(f"cannot read {a.file}: {e.strerror}")
    elif not sys.stdin.isatty() or a.file == "-":
        text = read_bounded(sys.stdin.buffer)
    else:
        ap.print_usage(sys.stderr)
        die("nothing to report (give text, --file or pipe stdin)")

    req = {}
    if a.json:
        try:
            payload = json.loads(text)
        except ValueError:
            die("--json input does not parse as JSON")
        if not isinstance(payload, dict):
            die("--json input must be a JSON object")
        req["payload"] = payload
    else:
        req["text"] = text
    for k in ("title", "severity", "unit", "kind"):
        if getattr(a, k):
            req[k] = getattr(a, k)
    if a.dry_run:
        req["dry_run"] = True
    data = json.dumps(req).encode()
    if len(data) > MAX_REQUEST:
        die(f"report larger than {MAX_REQUEST} bytes after encoding; trim it")

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect(a.socket)
    except (FileNotFoundError, ConnectionRefusedError):
        die(f"reporter socket {a.socket} not available (is neo-reporter-submit.socket running?)", 3)
    except PermissionError:
        die(f"no access to {a.socket}", 3)
    try:
        s.sendall(data)
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass  # the server may have answered early (e.g. too large); read it
    buf = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        die("timed out waiting for the reporter", 1)
    finally:
        s.close()
    if not buf.strip():
        die("the reporter service gave no answer; see: journalctl -u 'neo-reporter-submit@*'", 1)
    try:
        res = json.loads(buf.decode())
    except ValueError:
        die("garbled answer from the reporter", 1)
    code = res.get("code", "http_error")
    rc = EXIT.get(code, 1)
    if code == "dry_run":
        print(json.dumps(res, indent=2))
    elif rc == 0:
        inc = res.get("incident") or {}
        ident = f"incident #{inc['id']}" if inc.get("id") is not None else f"report {res.get('report_hash', '')}"
        word = "filed" if code == "posted" else "already on the board"
        if not a.quiet:
            print(f"{ident} {word}" + (f" (status {inc['status']})" if inc.get("status") else ""))
    else:
        extra = f" (HTTP {res['http_status']})" if res.get("http_status") else ""
        print(f"send-report: {code}{extra}: {res.get('error', 'failed')}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
