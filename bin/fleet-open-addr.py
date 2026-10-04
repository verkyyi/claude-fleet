#!/usr/bin/env python3
"""fleet-open-addr.py — what bin/fleet-open.sh sends for an address (issue #1379).

  fleet-open-addr.py <url | :port[/path] | host:port[/path]>

Prints ONE line, TAB-separated:  <kind> <TAB> <payload JSON> <TAB> <fallback url>
or exits 1 with the reason on stderr.

  forward  the page lives on THIS machine: the operator's side opens a local port
           that it forwards over its SSH connection to 127.0.0.1:<rport> here.
             :8765/d/x/            → rport 8765, path /d/x/, scheme http
             http://localhost:3000 / 127.0.0.1 / [::1] / 0.0.0.0 → that port
             https://<this machine's tailnet name or IP>[:P]/…  → the loopback port
               `tailscale serve` proxies P to (longest mount first); failing that,
               doc-preview's own record (~/.cache/claude-doc-preview: https.port →
               server.port). No loopback port found → sent as a plain `url`.
  url      anything else, as is — the operator's browser opens it.

Payload fields (the contract #1380's laptop side reads): v=1, kind, rport, path,
scheme (forward) | url (url), host = FLEET_OPEN_SSH_HOST (this machine's ssh alias
hint, may be empty), ts = epoch seconds.

The fallback url is what open-url.sh gets when no iTerm2 is there to take the
escape: the original tailnet URL for a tailnet page (the operator's machine may be
on the tailnet), else http://127.0.0.1:<rport><path>.
"""
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit

LOCAL = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
DEFAULT_PORT = {"http": 80, "https": 443}
DOCPREV = os.path.expanduser(os.environ.get("FLEET_OPEN_DOCPREV_ROOT", "~/.cache/claude-doc-preview"))


def die(msg):
    print(f"fleet-open: {msg}", file=sys.stderr)
    sys.exit(1)


def tailscale_json(*args):
    try:
        out = subprocess.run(["tailscale", *args, "--json"], capture_output=True,
                             text=True, timeout=5).stdout
        return json.loads(out) if out.strip() else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}


def self_names():
    """This machine's tailnet names: MagicDNS name, its first label, tailscale IPs."""
    st = tailscale_json("status")
    me = (st or {}).get("Self") or {}
    names = set()
    dns = (me.get("DNSName") or "").rstrip(".").lower()
    if dns:
        names.add(dns)
        names.add(dns.split(".")[0])
    for ip in me.get("TailscaleIPs") or []:
        names.add(ip.lower())
    return dns, names


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def proxy_port(proxy):
    """'http://127.0.0.1:8765/x' → (8765, 'http', '/x'); None when not loopback."""
    if re.fullmatch(r"\d+", proxy or ""):
        return int(proxy), "http", ""
    p = urlsplit(proxy or "")
    if (p.hostname or "").lower() in LOCAL and p.port:
        return p.port, p.scheme or "http", p.path
    return None


def via_serve(dns, port, path):
    """The loopback target `tailscale serve` maps <dns>:<port><path> to."""
    web = (tailscale_json("serve", "status") or {}).get("Web") or {}
    cfg = web.get(f"{dns}:{port}") or {}
    handlers = (cfg.get("Handlers") or {})
    for mount in sorted(handlers, key=len, reverse=True):
        m = mount.rstrip("/")
        if path == m or path.startswith(m + "/") or mount == "/":
            hit = proxy_port((handlers[mount] or {}).get("Proxy", ""))
            if not hit:
                return None
            rport, scheme, base = hit
            rest = path[len(m):]
            joined = base.rstrip("/") + "/" + rest.lstrip("/")
            return rport, scheme, joined
    return None


def via_docpreview(port, path):
    """doc-preview's record: its tailnet HTTPS port fronts its loopback server.py."""
    hp, sp = read(f"{DOCPREV}/https.port") or "", read(f"{DOCPREV}/server.port")
    mode = read(f"{DOCPREV}/mode") or ("https" if hp else "")
    if mode == "https" and sp.isdigit() and str(port) == (hp or "443"):
        return int(sp), "http", path
    return None


def main():
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        die("usage: fleet-open-addr.py <url | :port[/path]>")
    raw = sys.argv[1].strip()
    host_hint = os.environ.get("FLEET_OPEN_SSH_HOST", "")
    ts = int(time.time())

    def forward(rport, path, scheme):
        if not (0 < rport < 65536):
            die(f"port out of range: {rport}")
        path = path or "/"
        if not path.startswith("/"):
            path = "/" + path
        return {"v": 1, "kind": "forward", "rport": rport, "path": path,
                "scheme": scheme, "host": host_hint, "ts": ts}

    m = re.fullmatch(r":(\d+)(/.*)?", raw)
    if m:
        pay = forward(int(m.group(1)), m.group(2) or "/", "http")
        return emit(pay, f"http://127.0.0.1:{pay['rport']}{pay['path']}")

    # a scheme (`https://…`, `mailto:…`) — but `localhost:5173` is a host:port
    if not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:(?!\d)", raw):
        hostpart = re.split(r"[/?#]", raw, maxsplit=1)[0]
        if not hostpart or " " in raw:
            die(f"not a URL, :port or file: {raw}")
        local = hostpart.rsplit(":", 1)[0].strip("[]").lower() in LOCAL
        raw = ("http://" if local or re.search(r":\d+$", hostpart) else "https://") + raw

    u = urlsplit(raw)
    scheme = (u.scheme or "").lower()
    host = (u.hostname or "").lower()
    if scheme not in ("http", "https") or not host:
        # mailto:, vscode://, … — nothing to rewrite; the operator's OS knows the scheme
        return emit({"v": 1, "kind": "url", "url": raw, "host": host_hint, "ts": ts}, raw)
    try:
        port = u.port or DEFAULT_PORT[scheme]
    except ValueError:
        die(f"bad port in {raw}")
    path = u.path or "/"
    if u.query:
        path += "?" + u.query
    if u.fragment:
        path += "#" + u.fragment

    if host in LOCAL:
        pay = forward(port, path, scheme)
        return emit(pay, f"{scheme}://127.0.0.1:{port}{pay['path']}")

    dns, names = self_names()
    if host in names:
        hit = via_serve(dns, port, path) or via_docpreview(port, path)
        if hit:
            rport, fscheme, fpath = hit
            return emit(forward(rport, fpath, fscheme), raw)
        print(f"fleet-open: {host}:{port} is this machine on the tailnet, but no loopback "
              "port serves it (tailscale serve / doc-preview) — sending the URL as is",
              file=sys.stderr)
    return emit({"v": 1, "kind": "url", "url": raw, "host": host_hint, "ts": ts}, raw)


def emit(payload, fallback):
    print(f"{payload['kind']}\t{json.dumps(payload, separators=(',', ':'), ensure_ascii=False)}\t{fallback}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
