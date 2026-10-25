#!/usr/bin/env python3
"""fleet_node_http.py — the node's hub calls in-process (T992): what
fleet-task-record.sh's `call` does, without its bash, its fleet-lib, a Python to
read the token and another to sign — one `get` there was ~1 s, ~0.2 s here.

    pair()                 (url, token) — node.env's CCQUOTA_HUB_URL + CCQUOTA_TOKEN,
                           or a separated login's credential-proxy broker pair
                           (fleet_cred_ctl, issue #1971); None = no node token. Asked
                           once a process; never exported, never on an argv.
    call(method, path, body=None) → (http code, text)
                           signed once this login's key is confirmed (FleetSig,
                           issue #3710: fleet_node_sig.confirmed_auth), else
                           Bearer; the agent's forwarder first for a remote https
                           hub (issue T672: X-Fleet-Hub over the unix socket), the
                           direct road when nobody answers there or it refuses.
                           Raises Unreachable (no token / no answer).
    usable()               False when a seam or a setting asks for the bash road:
                           FLEET_NODE_HTTP=0, FLEET_HUB_CURL (a test's curl).

The rules are fleet-client-core.sh's (fleet_node_pair · fleet_hub_sock ·
fleet_node_key_file) and fleet-task-record.sh's `call`; a change to either is a
change here.
"""
import http.client
import json
import os
import socket
import sys
from pathlib import Path

BIN = Path(__file__).absolute().parent


class Unreachable(Exception):
    pass


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))


def usable():
    return os.environ.get("FLEET_NODE_HTTP", "1") != "0" and not os.environ.get("FLEET_HUB_CURL")


def _env_val(path, key):
    try:
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith(key + "="):
                return line[len(key) + 1:]
    except OSError:
        return None
    return ""


def _unquote(v):
    v = v or ""
    if v[:1] in ("'", '"'):
        v = v[1:]
    if v[-1:] in ("'", '"'):
        v = v[:-1]
    return v


_PAIR = []


def pair(hub_url=""):
    """fleet_node_pair: node.env readable → its pair; separated → the broker's."""
    if _PAIR:
        return _PAIR[0]
    f = conf_dir() / "node.env"
    got = None
    if os.access(f, os.R_OK):
        tok, url = _unquote(_env_val(f, "CCQUOTA_TOKEN")), _unquote(_env_val(f, "CCQUOTA_HUB_URL")) or hub_url
        got = (url.rstrip("/"), tok) if tok and url else None
    elif (conf_dir() / "credsep.json").exists():
        sys.path.insert(0, str(BIN))
        import fleet_cred_ctl
        res, rc = fleet_cred_ctl.ctl("node-token")
        url, tok = (str(res.get("url") or ""), str(res.get("token") or "")) if isinstance(res, dict) else ("", "")
        got = (url, tok) if rc == 0 and url.startswith("http://127.0.0.1:") and tok.startswith("fcpn1.") else None
    _PAIR.append(got)
    return got


def hub_sock():
    s = os.environ.get("CCQUOTA_HUB_SOCK", "")
    if s == "off":
        return ""
    if s:
        return s if _is_sock(s) else ""
    for p in (os.path.join(os.path.expanduser("~"), ".ccquota", "hub.sock"), "/var/db/fleet-node/hub.sock"):
        if _is_sock(p):
            return p
    return ""


def _is_sock(p):
    import stat
    try:
        return stat.S_ISSOCK(os.stat(p).st_mode)
    except OSError:
        return False


def key_file():
    k = os.environ.get("CCQUOTA_NODE_KEY", "")
    if k == "off":
        return ""
    if k:
        return k
    return "" if (conf_dir() / "credsep.json").exists() else str(conf_dir() / "node.key")


def auth(method, url, tok):
    """fleet_node_auth: the FleetSig header once the hub took this login's key."""
    k = key_file()
    if k and os.access(k, os.R_OK) and os.access(k + ".ok", os.R_OK):
        try:
            sys.path.insert(0, str(BIN))
            import fleet_node_sig
            v = fleet_node_sig.confirmed_auth(k, method, url)
            if v:
                return v
        except Exception:  # noqa: BLE001 — the token road, as the bash one falls back
            pass
    return "Bearer " + tok


class _UnixConn(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


def _timeout():
    try:
        return float(os.environ.get("FLEET_HUB_TIMEOUT") or 10)
    except ValueError:
        return 10.0


def call(method, path, body=None):
    """One request to the hub's node road → (code, text). Unreachable: no token,
    or neither road answered."""
    got = pair()
    if not got:
        raise Unreachable("no node token here")
    url, tok = got
    data = body.encode("utf-8") if isinstance(body, str) else (json.dumps(body).encode() if body is not None else None)
    headers = {"Content-Type": "application/json"}
    host = url.split("://", 1)[-1].split("/", 1)[0]
    base = "/" + url.split("://", 1)[-1].split("/", 1)[1] if "/" in url.split("://", 1)[-1] else ""
    sock = hub_sock() if url.startswith("https://") else ""
    if sock:
        try:
            c = _UnixConn(sock, _timeout())
            c.request(method, base.rstrip("/") + path, body=data,
                      headers=dict(headers, Authorization=auth(method, url + path, tok), Host=host,
                                   **{"X-Fleet-Hub": url}))
            r = c.getresponse()
            text = r.read().decode("utf-8", "replace")
            if not text.startswith(("hubfwd: this forwarder", "hubfwd: not a path")):
                return r.status, text
        except OSError:
            pass   # nobody there: the direct road
    scheme, rest = url.split("://", 1)
    try:
        conn = (http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection)(host, timeout=_timeout())
        conn.request(method, base.rstrip("/") + path, body=data,
                     headers=dict(headers, Authorization=auth(method, url + path, tok)))
        r = conn.getresponse()
        return r.status, r.read().decode("utf-8", "replace")
    except (OSError, http.client.HTTPException) as error:
        raise Unreachable("hub unreachable (%s)" % error)


def get_json(path):
    """GET → the JSON body on 200/202, else ValueError with the hub's words."""
    code, text = call("GET", path)
    if code not in (200, 202):
        try:
            why = " ".join(str(json.loads(text).get("error", "")).split())[:300]
        except (ValueError, AttributeError):
            why = ""
        raise ValueError("the hub refused (HTTP %s)%s" % (code, ": " + why if why else ""))
    return json.loads(text)


def main(argv):
    """`call METHOD PATH` — the body on stdin; out: the response body, then the
    HTTP code on its own last line (curl's `-o - -w '\\n%{http_code}'`, which
    fleet-task-record.sh's `call` reads). Exit 3 no node token · 7 no answer."""
    if len(argv) != 3 or argv[0] != "call":
        print("usage: fleet_node_http.py call METHOD PATH  (body on stdin)", file=sys.stderr)
        return 2
    body = sys.stdin.read()
    if not pair():
        return 3
    try:
        code, text = call(argv[1], argv[2], body if body else None)
    except Unreachable:
        return 7
    sys.stdout.write("%s\n%d" % (text, code))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
