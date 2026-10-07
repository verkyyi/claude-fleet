#!/usr/bin/env python3
"""fleet-relay-check.py — the Singapore relay's local gate (claude-fleet#2048,
EPIC #2119 C7). Caddy's forward_auth asks THIS process (127.0.0.1 only), and it
asks the hub's GET /v1/relay/check — so the relay keeps forwarding while the hub
restarts. docs/CRED-RELAY.md «入口重启时» is the runbook;
bin/fleet-break-it-cred-selftest.sh (`cred-relay-hub-restart`) drills it.

The verdict, per (SHA-256 of the pass, route prefix):
  - the hub said 2xx less than RELAY_CHECK_CACHE_S ago (30)  → 200, the hub not asked;
  - otherwise ask the hub: 2xx → 200 and remember the time; any other answer
    below 500 → that answer, and forget the pass (a revocation lands here, so it
    takes at most RELAY_CHECK_CACHE_S);
  - the hub 5xx / unreachable / timed out (RELAY_CHECK_TIMEOUT_S, 5):
      the hub said 2xx less than RELAY_CHECK_GRACE_S ago (600) → 200, log `grace`;
      else 503, log `refused-unavailable`.
A grace pass never extends the window: only a real hub 2xx does. A pass the hub
last refused, never saw, or saw on another prefix is not in the table.

What it keeps is the pass's hash and two timestamps, in memory only — never the
pass, never an Authorization (Caddy strips it before asking, and this process
forwards only X-Fleet-Relay + X-Forwarded-Uri/-Method to the hub). The log has
the event, the prefix, the hub's failure and an age — nothing that names a pass.

Environment (none is a secret):
  FLEET_HUB_URL              the hub, e.g. https://ccquota.24haowan.com (required)
  FLEET_RELAY_CHECK_LISTEN   127.0.0.1:2091 (loopback only; anything else refused)
  RELAY_CHECK_CACHE_S        30    RELAY_CHECK_GRACE_S   600    RELAY_CHECK_TIMEOUT_S  5
  FLEET_RELAY_CHECK_LOG      a file to append to (default stderr → journald)
  FLEET_RELAY_CHECK_MAX_SECONDS  exit after this long (tests only)
"""
import hashlib
import http.client
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PREFIXES = ("/anthropic/", "/chatgpt/", "/openai-auth/")
FORWARD = ("X-Fleet-Relay", "X-Forwarded-Uri", "X-Forwarded-Method")
MAX_ENTRIES = 20000


def env_num(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        sys.exit("fleet-relay-check: %s is not a number" % name)


CACHE_S = env_num("RELAY_CHECK_CACHE_S", 30)
GRACE_S = env_num("RELAY_CHECK_GRACE_S", 600)
TIMEOUT_S = env_num("RELAY_CHECK_TIMEOUT_S", 5)
HUB = urlsplit(os.environ.get("FLEET_HUB_URL", "").rstrip("/"))
if HUB.scheme not in ("http", "https") or not HUB.hostname:
    sys.exit("fleet-relay-check: FLEET_HUB_URL must be an http(s) URL")
HUB_BASE = HUB.path or ""

_ok = {}            # key -> monotonic time of the hub's last 2xx
_lock = threading.Lock()
_log_lock = threading.Lock()
_logf = None
_hub_state = {"down": False}


def log(event, **kv):
    line = "%s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), event,
                           " ".join("%s=%s" % (k, v) for k, v in kv.items()))
    with _log_lock:
        (_logf or sys.stderr).write(line)
        (_logf or sys.stderr).flush()


def prefix_of(uri):
    for p in PREFIXES:
        if uri.startswith(p):
            return p
    return ""


def ask_hub(headers):
    """→ (status, body) from the hub, or (None, why) when it could not answer."""
    cls = http.client.HTTPSConnection if HUB.scheme == "https" else http.client.HTTPConnection
    conn = cls(HUB.hostname, HUB.port, timeout=TIMEOUT_S)
    try:
        conn.request("GET", HUB_BASE + "/v1/relay/check", headers=headers)
        r = conn.getresponse()
        return r.status, r.read(65536)
    except (OSError, http.client.HTTPException) as e:
        return None, type(e).__name__
    finally:
        conn.close()


def hub_mark(down, why=""):
    if down != _hub_state["down"]:
        _hub_state["down"] = down
        log("hub-down" if down else "hub-up", why=why or "-")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Cache-Control", "no-store")
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, b"ok", "text/plain")
        tok = (self.headers.get("X-Fleet-Relay") or "").strip()
        pre = prefix_of(self.headers.get("X-Forwarded-Uri") or "")
        key = hashlib.sha256(tok.encode()).hexdigest() + "\0" + pre if tok and pre else None
        now = time.monotonic()
        if key is not None:
            with _lock:
                t = _ok.get(key)
            if t is not None and now - t < CACHE_S:
                return self.reply(200)
        hdrs = {k: self.headers[k] for k in FORWARD if self.headers.get(k) is not None}
        status, body = ask_hub(hdrs)
        if status is not None and status < 500:
            hub_mark(False)
            if key is not None:
                with _lock:
                    if 200 <= status < 300:
                        if key not in _ok and len(_ok) >= MAX_ENTRIES:
                            self.prune(now)
                        _ok[key] = now
                    else:
                        _ok.pop(key, None)
            return self.reply(status if status >= 200 else 502, body if status >= 300 else b"")
        why = "http-%d" % status if status is not None else body
        hub_mark(True, why)
        with _lock:
            t = _ok.get(key) if key is not None else None
        if t is not None and now - t < GRACE_S:
            log("grace", prefix=pre, hub=why, age="%ds" % int(now - t))
            return self.reply(200)
        log("refused-unavailable", prefix=pre or "-", hub=why,
            seen="expired" if t is not None else "no")
        return self.reply(503, b'{"error":"relay_check_unavailable","message":"the hub cannot check this pass right now"}')

    @staticmethod
    def prune(now):
        # under _lock: drop what can no longer pass; still full → the oldest half
        for k in [k for k, t in _ok.items() if now - t >= GRACE_S]:
            del _ok[k]
        if len(_ok) >= MAX_ENTRIES:
            for k, _ in sorted(_ok.items(), key=lambda kv: kv[1])[: MAX_ENTRIES // 2]:
                del _ok[k]


def main():
    global _logf
    listen = os.environ.get("FLEET_RELAY_CHECK_LISTEN", "127.0.0.1:2091")
    host, _, port = listen.rpartition(":")
    if host not in ("127.0.0.1", "localhost", "::1", "[::1]"):
        sys.exit("fleet-relay-check: listens on loopback only, not %s" % listen)
    if os.environ.get("FLEET_RELAY_CHECK_LOG"):
        _logf = open(os.environ["FLEET_RELAY_CHECK_LOG"], "a")
    if os.environ.get("FLEET_RELAY_CHECK_MAX_SECONDS"):
        signal.alarm(int(float(os.environ["FLEET_RELAY_CHECK_MAX_SECONDS"])))
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer((host.strip("[]"), int(port)), H)
    log("start", listen=listen, hub=HUB.hostname, cache="%gs" % CACHE_S, grace="%gs" % GRACE_S)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    srv.serve_forever()


if __name__ == "__main__":
    main()
