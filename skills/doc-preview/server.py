#!/usr/bin/env python3
"""Static file server for doc-preview + a tiny tailnet-only control API.

Serves SERVE_DIR exactly like `python3 -m http.server`, and adds three control
routes used by the in-page "public link" toggle:

    GET  /_ctl/status?id=<id>   -> {"public": bool, "url": str|null}
    POST /_ctl/publish   {id}   -> {"public": true,  "url": str}
    POST /_ctl/unpublish {id}   -> {"public": false, "url": null}

The control routes shell out to share.sh (--pubstatus/--publish/--unpublish),
which manages the per-doc Tailscale Funnel path mount. These routes are only
reachable over the tailnet `tailscale serve` origin: the public Funnel only
mounts individual `/p/<id>/` document paths, never `/_ctl`, so a public viewer
cannot reach the control API. The toggle UI itself is hidden on the public view
(the page detects the `/p/` path prefix).

Usage: server.py <port> <serve_dir> <skill_dir>
"""
import json
import os
import re
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
SERVE_DIR = sys.argv[2]
SKILL_DIR = sys.argv[3]
SHARE = os.path.join(SKILL_DIR, "share.sh")
ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9]+$")


def run_share(action, doc_id):
    """Call share.sh <action> <id> --json; return parsed dict (or error dict)."""
    try:
        p = subprocess.run(
            [SHARE, action, doc_id, "--json"],
            capture_output=True, text=True, timeout=25,
        )
        out = (p.stdout or "").strip().splitlines()
        for line in reversed(out):  # last JSON line wins
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line)
        return {"error": (p.stderr or p.stdout or "no output").strip()[:300]}
    except Exception as e:  # noqa: BLE001 - report any failure back as JSON
        return {"error": str(e)[:300]}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=SERVE_DIR, **kw)

    def log_message(self, *a):  # keep the console quiet
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_id(self):
        """Extract & validate a doc id from query (GET) or body (POST)."""
        parsed = urlparse(self.path)
        doc_id = (parse_qs(parsed.query).get("id") or [None])[0]
        if doc_id is None and self.command == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
            try:
                doc_id = json.loads(raw).get("id") if raw else None
            except Exception:  # noqa: BLE001 - fall back to form encoding
                doc_id = (parse_qs(raw).get("id") or [None])[0]
        if not doc_id or not ID_RE.match(doc_id):
            return None
        if not os.path.isdir(os.path.join(SERVE_DIR, "d", doc_id)):
            return None
        return doc_id

    def do_GET(self):
        route = urlparse(self.path).path
        if route == "/_ctl/status":
            doc_id = self._read_id()
            if not doc_id:
                return self._json({"error": "bad id"}, 400)
            return self._json(run_share("--pubstatus", doc_id))
        if route.startswith("/_pub/"):
            return self._serve_public(route)
        return super().do_GET()

    def _serve_public(self, route):
        """Public (Funnel) view of one doc: same content, but with the tailnet header
        (index link + session/date/source-path metadata) stripped from the bytes, so
        internal info never reaches the public internet — not even in view-source."""
        rest = route[len("/_pub/"):]
        doc_id, _, sub = rest.partition("/")
        if not ID_RE.match(doc_id) or not os.path.isdir(os.path.join(SERVE_DIR, "d", doc_id)):
            return self.send_error(404)
        if sub in ("", "index.html"):
            fp = os.path.join(SERVE_DIR, "d", doc_id, "index.html")
            try:
                html = open(fp, encoding="utf-8").read()
            except OSError:
                return self.send_error(404)
            html = re.sub(r'<div class="hdr">.*?</div>', "", html, count=1, flags=re.S)
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return self.wfile.write(body)
        # non-index assets (e.g. locally-referenced images): pass through, static.
        self.path = "/d/" + doc_id + "/" + sub
        return super().do_GET()

    def do_POST(self):
        route = urlparse(self.path).path
        if route in ("/_ctl/publish", "/_ctl/unpublish"):
            doc_id = self._read_id()
            if not doc_id:
                return self._json({"error": "bad id"}, 400)
            action = "--publish" if route.endswith("publish") and "unpub" not in route else "--unpublish"
            return self._json(run_share(action, doc_id))
        self.send_error(405)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
