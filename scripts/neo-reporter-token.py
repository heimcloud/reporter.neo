#!/usr/bin/env python3
"""Write the reporter's ingest token where the reporter can read it.

    neo-reporter-token [--settings FILE] [--source FILE] [--dest FILE] [--group NAME]

Source, first match wins:
  1. services.reporter.token in Neo's settings.toml (read at run time, so the
     value never ends up in a Nix derivation, unit or journal);
  2. the first line of --source (services.reporter.tokenFile; any owner/mode,
     this runs as root).
Destination: --dest (default /run/neo-reporter/ingest.token), mode 0440,
owner root:<group> (default hermes), written atomically. No source: the
destination is removed (the helper then notifies only, exit 3).

Never prints the token. Exit 0 also when no token is configured.
"""
import argparse
import grp
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


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--settings", default=os.environ.get("NEO_REPORTER_SETTINGS", "/etc/neo/settings.toml"))
    p.add_argument("--source", default=os.environ.get("NEO_REPORTER_TOKEN_SOURCE", ""))
    p.add_argument("--dest", default=os.environ.get("NEO_REPORTER_TOKEN_DEST", "/run/neo-reporter/ingest.token"))
    p.add_argument("--group", default=os.environ.get("NEO_REPORTER_GROUP", "hermes"))
    a = p.parse_args(argv)

    token, origin = from_settings(a.settings), "services.reporter.token"
    if token is None:
        token, origin = from_file(a.source), f"tokenFile {a.source}"

    d = os.path.dirname(a.dest)
    try:
        gid = grp.getgrnam(a.group).gr_gid
    except KeyError:
        print(f"neo-reporter-token: group {a.group} does not exist; using root", file=sys.stderr)
        gid = 0
    os.makedirs(d, mode=0o750, exist_ok=True)
    if os.geteuid() == 0:
        os.chown(d, 0, gid)
    os.chmod(d, 0o750)

    if token is None:
        try:
            os.unlink(a.dest)
        except FileNotFoundError:
            pass
        print("neo-reporter-token: no token configured; reports are notify-only")
        return 0

    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ingest.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(token + "\n")
        if os.geteuid() == 0:
            os.chown(tmp, 0, gid)
        os.chmod(tmp, 0o440)
        os.replace(tmp, a.dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    placeholder = " (placeholder value: reports stay notify-only)" if token.startswith("replace-") else ""
    print(f"neo-reporter-token: wrote {a.dest} (0440 root:{a.group}) from {origin}{placeholder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
