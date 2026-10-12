#!/usr/bin/env python3
"""fleet-phone-mcp.py — the person's phone MCP, ONE copy for all their logins (issue #3247).

The phone (USB on mac-a) is driven by mcp-server-mobile over adb. Before this,
every session of every login started its own copy over `ssh mac-a phone-mcp` —
one adb client fight per session (#3221's root), and a login that could not ssh
to mac-a had no phone at all. Now ONE login (the admin login) runs it:

  serve    run as a `fleet service` of that login (the machine daemon starts it
           at boot and restarts it): mcp-server-mobile --listen 127.0.0.1:<up>
           as a child, the one adb server's owner, and in front of it a small
           Bearer-token proxy on 127.0.0.1 and this machine's tailnet address —
           never `*`, never the LAN, never the internet.
  rotate   a new token; the old one keeps working for --grace (600 s).
  token    print the current token on stdout (for a pipe into `client set`).
  status   what is listening, who owns the adb server, how old the token is.

and on every login that should reach it (the person's own, on any machine):

  client set --url http://<mac-a>:<port>/mcp   token on stdin
           Claude Code: user-scope `phone` = {type: http, url, headersHelper}
           — the helper reads the token from a 0600 file, so a rotation needs
           only a new file; Codex: one marked [mcp_servers.phone] table with
           http_headers (Codex has no helper; the person allowed their own key
           in their own config). config.toml is edited as TEXT.
  client unset / client header (the helper) / client show

The token never enters argv, a log line, an issue or a commit. docs/dev/PHONE-MCP.md.
"""
import argparse
import hmac
import http.client
import http.server
import json
import os
import secrets
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time

PORT = 47230                      # the proxy (what clients dial)
UP_PORT = 47231                   # mcp-server-mobile, loopback only
GRACE = 600
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "host", "authorization",
       "content-length"}
CASK_ADB = "/opt/homebrew/bin/adb"
TAILSCALE = ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
             "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
HOME = os.path.expanduser("~")


def log(*a):
    print(time.strftime("%F %T"), *a, file=sys.stderr, flush=True)


def state_dir():
    return os.environ.get("FLEET_PHONE_DIR") or os.path.join(HOME, ".config", "fleet-phone")


def write_private(path, text):
    """One rename, 0600 from the first byte."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


# -- the token book (server side) ---------------------------------------------

class Tokens:
    """tokens.json: {current, previous, previous_until, rotated_at}; re-read when it moves."""

    def __init__(self, path):
        self.path, self.sig, self.doc = path, None, {}

    def load(self):
        try:
            st = os.stat(self.path)
        except OSError:
            self.sig, self.doc = None, {}
            return self.doc
        sig = (st.st_mtime_ns, st.st_size, st.st_ino)
        if sig != self.sig:
            try:
                with open(self.path) as f:
                    self.doc = json.load(f)
            except (OSError, ValueError):
                self.doc = {}
            self.sig = sig
        return self.doc

    def valid(self, now=None):
        d, now = self.load(), now or time.time()
        out = [d.get("current")]
        if d.get("previous") and now < float(d.get("previous_until") or 0):
            out.append(d["previous"])
        return [t for t in out if t]

    def ok(self, presented):
        return any(hmac.compare_digest(presented.encode(), t.encode()) for t in self.valid())


def tokens_path():
    return os.path.join(state_dir(), "tokens.json")


def ensure_token():
    p = tokens_path()
    if not Tokens(p).valid():
        write_private(p, json.dumps({"current": secrets.token_urlsafe(32), "rotated_at": int(time.time())}) + "\n")
        log("token: minted the first one (", p, ")")


def cmd_rotate(a):
    p = tokens_path()
    old = Tokens(p).load().get("current")
    doc = {"current": secrets.token_urlsafe(32), "rotated_at": int(time.time())}
    if old:
        doc.update(previous=old, previous_until=int(time.time()) + a.grace)
    write_private(p, json.dumps(doc) + "\n")
    until = time.strftime("%F %T", time.localtime(doc.get("previous_until", time.time())))
    print("rotated · the old token works until %s · hand the new one to every client:" % until)
    print("  fleet-phone-mcp.py token | <as each login> fleet-phone-mcp.py client set --url <url>")
    return 0


def cmd_token(_a):
    v = Tokens(tokens_path()).valid()
    if not v:
        print("no token yet — `serve` or `rotate` mints one", file=sys.stderr)
        return 1
    print(v[0])
    return 0


# -- the proxy ----------------------------------------------------------------

class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fleet-phone-mcp"
    tokens = None
    upstream = ("127.0.0.1", UP_PORT)

    def log_message(self, fmt, *args):     # never the headers: they carry the token
        pass

    def deny(self, code, msg):
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        if code == 401:
            self.send_header("WWW-Authenticate", 'Bearer realm="fleet-phone"')
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def relay(self):
        auth = self.headers.get("Authorization", "")
        if not (auth.startswith("Bearer ") and self.tokens.ok(auth[7:].strip())):
            log("denied", self.client_address[0], self.command, self.path.split("?")[0])
            return self.deny(401, "unauthorized")
        if not (self.path == "/mcp" or self.path.startswith(("/mcp?", "/mcp/"))):
            return self.deny(404, "not found")
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            return self.deny(411, "length required")
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        up = http.client.HTTPConnection(*self.upstream, timeout=None)
        try:
            up.request(self.command, self.path, body=body, headers=hdrs)
            r = up.getresponse()
        except OSError as e:
            up.close()
            return self.deny(502, "phone service not up (%s)" % e.__class__.__name__)
        try:
            self.send_response(r.status, r.reason)
            for k, v in r.getheaders():
                if k.lower() not in HOP and k.lower() not in ("date", "server"):
                    self.send_header(k, v)
            length = r.getheader("Content-Length")
            if length is not None:
                self.send_header("Content-Length", length)
                self.end_headers()
                self.wfile.write(r.read())
            elif self.command == "HEAD" or r.status in (204, 304):
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:                       # streamed (SSE): re-chunk as it comes
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    chunk = r.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except OSError:                 # the client went away mid-stream
            self.close_connection = True
        finally:
            up.close()

    do_GET = do_POST = do_DELETE = do_HEAD = do_PUT = relay


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def tailnet_ip():
    for t in TAILSCALE:
        if os.access(t, os.X_OK):
            try:
                out = subprocess.run([t, "ip", "-4"], capture_output=True, text=True, timeout=10).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            ip = out.strip().splitlines()[0] if out.strip() else ""
            if ip.startswith("100."):
                return ip
    return None


def bind_addrs(spec):
    """'127.0.0.1,tailscale' → concrete addresses; never a wildcard."""
    out = []
    for a in [s.strip() for s in spec.split(",") if s.strip()]:
        if a in ("0.0.0.0", "::", "*", ""):
            raise SystemExit("refusing to bind %r: the phone listens on loopback and the tailnet only" % a)
        out.append(a)
    return out


def listen(addr, port, handler):
    """Serve on addr:port forever; 'tailscale' waits until the tailnet has an address."""
    while True:
        ip = tailnet_ip() if addr == "tailscale" else addr
        if ip:
            try:
                srv = Server((ip, port), handler)
            except OSError as e:
                log("bind %s:%d failed (%s); retrying" % (ip, port, e))
            else:
                log("listening on %s:%d" % (ip, port))
                srv.serve_forever()
                return
        time.sleep(15)


# -- the child: mcp-server-mobile + the one adb server ------------------------

def adb_dir():
    return os.environ.get("FLEET_PHONE_ADB_DIR") or os.path.join(HOME, ".local", "opt", "platform-tools")


def ensure_adb():
    """Our own unquarantined copy of the cask's adb — the same version sms-watch
    copies (a version mismatch makes an adb client kill the server), and one a
    process outside a GUI session can exec (#3221)."""
    d = adb_dir()
    if not os.access(os.path.join(d, "adb"), os.X_OK) and os.access(CASK_ADB, os.X_OK):
        shutil.copytree(os.path.dirname(os.path.realpath(CASK_ADB)), d, dirs_exist_ok=True)
        log("copied adb into", d)
    subprocess.run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", d], capture_output=True, timeout=30)
    return os.path.join(d, "adb")


def adb_owner():
    """The login whose adb server holds tcp:5037, or None."""
    try:
        out = subprocess.run(["/bin/ps", "-axo", "user=,command="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        user, _, cmd = line.strip().partition(" ")
        if "fork-server" in cmd and os.path.basename(cmd.split()[0]) == "adb":
            return user
    return None


def claim_adb(adb):
    """Be the adb server's owner: start ours; one another login started first is
    killed only when this login may (sudo -n), else named once in the log."""
    me = os.environ.get("USER") or ""
    owner = adb_owner()
    if owner and owner != me:
        if subprocess.run(["/usr/bin/sudo", "-n", "/usr/bin/pkill", "-u", owner, "-f", "adb .*fork-server"],
                          capture_output=True, timeout=20).returncode == 0:
            log("adb server was %s's; stopped it to own it" % owner)
            time.sleep(1)
        else:
            log("WARN adb server on 5037 is %s's — shared all the same; to own it run once as admin: "
                "sudo pkill -u %s -f 'adb .*fork-server'" % (owner, owner))
            return
    subprocess.run([adb, "start-server"], capture_output=True, timeout=30)


def mobile_cmd(a):
    js = a.mobile_mcp or os.path.join(HOME, ".local/opt/mobile-mcp/node_modules/@mobilenext/mobile-mcp/lib/index.js")
    return [a.node, js, "--listen", "127.0.0.1:%d" % a.up_port]


def run_child(a, stop):
    adb = ensure_adb()
    env = dict(os.environ, ANDROID_HOME=os.path.dirname(adb_dir()),
               PATH="%s:/opt/homebrew/bin:/usr/bin:/bin" % adb_dir())
    back = 1
    while not stop.is_set():
        claim_adb(adb)
        t0 = time.time()
        p = subprocess.Popen(mobile_cmd(a), env=env, stdin=subprocess.DEVNULL, start_new_session=True)
        stop.child = p
        log("mcp-server-mobile pid %d on 127.0.0.1:%d" % (p.pid, a.up_port))
        rc = p.wait()
        if stop.is_set():
            return
        back = 1 if time.time() - t0 > 60 else min(back * 2, 60)
        log("mcp-server-mobile exited %s; again in %ds" % (rc, back))
        stop.wait(back)


def cmd_serve(a):
    ensure_token()
    Proxy.tokens = Tokens(tokens_path())
    Proxy.upstream = ("127.0.0.1", a.up_port)
    stop = threading.Event()
    stop.child = None

    def on_term(sig, _f):
        stop.set()
        if stop.child and stop.child.poll() is None:
            try:
                os.killpg(stop.child.pid, signal.SIGTERM)
            except OSError:
                pass
        sys.exit(128 + sig)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    for addr in bind_addrs(a.bind):
        threading.Thread(target=listen, args=(addr, a.port, Proxy), daemon=True).start()
    if a.no_child:
        stop.wait()
    else:
        run_child(a, stop)
    return 0


def port_open(host, port):
    try:
        socket.create_connection((host, port), timeout=2).close()
        return True
    except OSError:
        return False


def cmd_status(a):
    d = Tokens(tokens_path()).load()
    age = int(time.time() - d["rotated_at"]) // 86400 if d.get("rotated_at") else None
    print("proxy      127.0.0.1:%d %s · tailnet %s" % (a.port, "up" if port_open("127.0.0.1", a.port) else "DOWN",
                                                      tailnet_ip() or "-"))
    print("phone mcp  127.0.0.1:%d %s" % (a.up_port, "up" if port_open("127.0.0.1", a.up_port) else "DOWN"))
    print("adb server %s" % (adb_owner() or "none"))
    print("token      %s" % ("none" if not d.get("current") else "%s day(s) old%s" % (
        age, " · previous still valid" if len(Tokens(tokens_path()).valid()) > 1 else "")))
    return 0


# -- the client side ----------------------------------------------------------

def client_path():
    return os.path.join(state_dir(), "client.json")


def cmd_client_header(_a):
    try:
        with open(client_path()) as f:
            tok = json.load(f)["token"]
    except (OSError, ValueError, KeyError):
        print("{}")
        return 1
    print(json.dumps({"Authorization": "Bearer " + tok}))
    return 0


CODEX_BEGIN, CODEX_END = "# >>> fleet phone >>>", "# <<< fleet phone <<<"


def codex_strip(text):
    """config.toml minus our block and any other [mcp_servers.phone] table — every
    other line byte for byte."""
    out, skip, ours = [], False, False
    for line in text.splitlines(True):
        s = line.strip()
        if s == CODEX_BEGIN:
            ours = True
            continue
        if ours:
            ours = s != CODEX_END
            continue
        if s.startswith("["):
            name = s.strip("[]").strip()
            skip = name == "mcp_servers.phone" or name.startswith("mcp_servers.phone.")
        if not skip:
            out.append(line)
    return "".join(out)


def codex_write(url, token):
    home = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
    path = os.path.join(home, "config.toml")
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        text = ""
    text = codex_strip(text)
    if url:
        block = "%s\n[mcp_servers.phone]\nurl = %s\nhttp_headers = { \"Authorization\" = %s }\n%s\n" % (
            CODEX_BEGIN, json.dumps(url), json.dumps("Bearer " + token), CODEX_END)
        if text and not text.endswith("\n"):
            text += "\n"
        mark = "# >>> fleet plugins"      # keep the plugins block last
        i = text.find(mark)
        text = text[:i] + block + text[i:] if i >= 0 else text + block
    write_private(path, text)
    return path


def claude_bin(a):
    return a.claude or shutil.which("claude") or os.path.join(HOME, ".local/bin/claude")


def claude_set(a, url):
    c = claude_bin(a)
    subprocess.run([c, "mcp", "remove", "phone", "-s", "user"], capture_output=True, timeout=60)
    if not url:
        return 0
    live = os.path.join(HOME, ".claude/fleet/bin/fleet-phone-mcp.py")   # follows every version switch
    helper = "%s %s client header" % (sys.executable, live if os.path.exists(live) else os.path.abspath(__file__))
    spec = json.dumps({"type": "http", "url": url, "headersHelper": helper})   # no token in it
    r = subprocess.run([c, "mcp", "add-json", "phone", spec, "-s", "user"], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        print("claude mcp add-json failed: %s" % (r.stderr or r.stdout).strip(), file=sys.stderr)
    return r.returncode


def cmd_client_set(a):
    tok = sys.stdin.readline().strip()
    if not tok or any(ch.isspace() for ch in tok):
        print("client set: give the token on stdin (one line)", file=sys.stderr)
        return 2
    write_private(client_path(), json.dumps({"url": a.url, "token": tok}) + "\n")
    rc = 0 if a.no_claude else claude_set(a, a.url)
    path = None if a.no_codex else codex_write(a.url, tok)
    print("phone → %s · claude %s · codex %s" % (a.url, "skipped" if a.no_claude else ("ok" if rc == 0 else "FAILED"),
                                                path or "skipped"))
    return 1 if rc else 0


def cmd_client_unset(a):
    rc = 0 if a.no_claude else claude_set(a, None)
    if not a.no_codex:
        codex_write(None, None)
    try:
        os.remove(client_path())
    except OSError:
        pass
    print("phone removed from this login")
    return rc


def cmd_client_show(_a):
    try:
        with open(client_path()) as f:
            d = json.load(f)
    except (OSError, ValueError):
        print("not set")
        return 1
    t = d.get("token", "")
    print("url   %s\ntoken %s…%s (%d chars)" % (d.get("url"), t[:3], t[-2:], len(t)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet-phone-mcp.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--bind", default="127.0.0.1,tailscale")
    s.add_argument("--port", type=int, default=PORT)
    s.add_argument("--up-port", type=int, default=UP_PORT)
    s.add_argument("--node", default="/opt/homebrew/bin/node")
    s.add_argument("--mobile-mcp", help="mcp-server-mobile's lib/index.js")
    s.add_argument("--no-child", action="store_true", help="proxy only (the upstream runs elsewhere)")
    r = sub.add_parser("rotate")
    r.add_argument("--grace", type=int, default=GRACE)
    sub.add_parser("token")
    st = sub.add_parser("status")
    st.add_argument("--port", type=int, default=PORT)
    st.add_argument("--up-port", type=int, default=UP_PORT)
    c = sub.add_parser("client")
    csub = c.add_subparsers(dest="ccmd", required=True)
    for name in ("set", "unset"):
        x = csub.add_parser(name)
        if name == "set":
            x.add_argument("--url", required=True)
        x.add_argument("--claude")
        x.add_argument("--no-claude", action="store_true")
        x.add_argument("--no-codex", action="store_true")
    csub.add_parser("header")
    csub.add_parser("show")
    a = ap.parse_args(argv)
    if a.cmd == "client":
        return {"set": cmd_client_set, "unset": cmd_client_unset,
                "header": cmd_client_header, "show": cmd_client_show}[a.ccmd](a)
    return {"serve": cmd_serve, "rotate": cmd_rotate, "token": cmd_token, "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
