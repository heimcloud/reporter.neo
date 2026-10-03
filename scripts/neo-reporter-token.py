#!/usr/bin/env python3
"""Stage the reporter's secrets as systemd credentials (root only).

    neo-reporter-token [--settings FILE] [--source FILE] [--overrides FILE] [--dest-dir DIR]

Token source, first match wins:
  1. services.reporter.token in Neo's settings.toml (read at run time, so the
     value never ends up in a Nix derivation, unit or journal);
  2. the first line of --source (services.reporter.tokenFile; any owner/mode,
     this runs as root).
Writes DIR/token (default /run/neo-reporter/creds/token; empty when no token
is configured) and DIR/overrides.json (a copy of --overrides when it is a JSON
object, else {}), both 0400 root:root in a 0700 root directory, atomically.
neo-reporter-submit@.service loads them with LoadCredential=; no user, not
even hermes, can read them.

Never prints the token. Exit 0 also when no token is configured.
"""
import argparse
import json
import os
import sys
import tempfile
import tomllib


def from_settings(path):
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        return None
    except Exception as exc:  # never echo file content
        print(f"neo-reporter-token: cannot parse {path}: {type(exc).__name__}", file=sys.stderr)
        return None
    v = data.get("services", {}).get("reporter", {}).get("token")
    if isinstance(v, str) and v.strip():
        return v.strip()
    return None


def from_file(path):
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            line = f.readline().strip()
    except FileNotFoundError:
        print(f"neo-reporter-token: token file {path} not found", file=sys.stderr)
        return None
    except OSError as exc:
        print(f"neo-reporter-token: cannot read token file {path}: {exc.strerror}", file=sys.stderr)
        return None
    return line or None


def overrides(path):
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            v = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        print(f"neo-reporter-token: ignoring overrides {path}: {type(exc).__name__}", file=sys.stderr)
        return {}
    if not isinstance(v, dict):
        return {}
    keep = ("ingest_url", "ops_ingest_url", "reporter_id", "repo_slug", "customer_repo_slug")
    return {k: v[k] for k in keep if isinstance(v.get(k), str) and v[k].strip()}


def write_atomic(d, name, content):
    fd, tmp = tempfile.mkstemp(dir=d, prefix=f".{name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        if os.geteuid() == 0:
            os.chown(tmp, 0, 0)
        os.chmod(tmp, 0o400)
        os.replace(tmp, os.path.join(d, name))
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--settings", default=os.environ.get("NEO_REPORTER_SETTINGS", "/etc/neo/settings.toml"))
    p.add_argument("--source", default=os.environ.get("NEO_REPORTER_TOKEN_SOURCE", ""))
    p.add_argument("--overrides", default=os.environ.get("NEO_REPORTER_OVERRIDES", ""))
    p.add_argument("--dest-dir", default=os.environ.get("NEO_REPORTER_CREDS_DIR", "/run/neo-reporter/creds"))
    a = p.parse_args(argv)

    token, origin = from_settings(a.settings), "services.reporter.token"
    if token is None:
        token, origin = from_file(a.source), f"tokenFile {a.source}"

    d = a.dest_dir
    parent = os.path.dirname(d.rstrip("/"))
    os.makedirs(parent, mode=0o755, exist_ok=True)
    os.makedirs(d, mode=0o700, exist_ok=True)
    if os.geteuid() == 0:
        os.chown(d, 0, 0)
    os.chmod(d, 0o700)
    # v0.1.1 left a group-readable copy here; remove it
    try:
        os.unlink(os.path.join(parent, "ingest.token"))
    except FileNotFoundError:
        pass

    write_atomic(d, "token", (token + "\n") if token else "")
    write_atomic(d, "overrides.json", json.dumps(overrides(a.overrides)) + "\n")
    if token is None:
        print("neo-reporter-token: no token configured; send-report answers not_configured")
    else:
        placeholder = " (placeholder value: reports are not posted)" if token.startswith("replace-") else ""
        print(f"neo-reporter-token: staged credential token (0400 root) from {origin}{placeholder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
