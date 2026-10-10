#!/usr/bin/env python3
"""fleet connect — get into your own fleet over the best route there is.

    fleet [MACHINE] [--verbose] [--retest] [--print] [-o SSH-OPTION]… [-- SSH-ARGS…]
    fleet connect [MACHINE] [--verbose] [--retest] [--route ROUTE] [--print] [-o SSH-OPTION]… [-- SSH-ARGS…]
    fleet connect --proxy MACHINE
    fleet connect --pick [MACHINE] [--route ROUTE]
    fleet connect --probe-direct MACHINE
    fleet connect --cert-check
    fleet connect --principal-hint < BODY

`fleet` with nothing after it (claude-fleet#1470; `bin/fleet` runs this file
with --enter) is the whole way in, in one go:

  1. the certificate — none, expired, or under FLEET_RENEW_BELOW_SECS (6h)
     left: renew it by this device's key (fleet-login.py renew, no scan);
     the hub says this device must scan (never registered, revoked, seven
     idle days): the browser opens here, or the QR (fleet-login.py);
  2. the machine — POST /v1/fleet/home: the hub picks the machine this device
     used last if it is online, else an online one with your sessions, else
     the least loaded one you have an account on; none online, it says so
     and this exits 1. `fleet m4` names the machine and skips the ask;
  3. the route — as `fleet connect` below, from the route list the home
     answer already carries;
  4. ssh.

The hub unreachable at step 2 falls back to `fleet connect`'s own memory (the
machine used last, the routes in ~/.ssh/fleet-ssh-config). A viewer token
(FLEET_HUB_TOKEN / hub.json "token" — the operator's) skips step 1.

With no address at all (claude-fleet#1414), `fleet connect` asks the hub which
machines you may reach and every way into each — its tailnet name, the public
port the gateway forwards to it, and the relay through the hub itself (#1413)
— measures each with FLEET_CONNECT_PROBES (3) TCP + SSH-banner handshakes,
and ssh's in over the winner: most handshakes answered first, lowest median
latency next. The interactive login on the far side opens the fleet client
there (shell/fleet-login.zsh, claude-fleet#1711).

The choice is remembered for FLEET_CONNECT_CACHE_SECS (600). Inside that
window one handshake re-checks the remembered route before it is used; if that
route has gone dark, every route is measured again — so closing any one line
moves the next `fleet connect` onto another, with nothing to edit.
FLEET_CONNECT_RETEST=1 is --retest from the environment: the shell's right pane
sets it when it leaves the relay for a direct line that answered (#1628). On an
ordinary RECONNECT it sets FLEET_CONNECT_RETEST=last (claude-fleet#2886): the
remembered line first, whatever its age — only when it does not answer is every
route measured again, so a slow network does not wait out a measurement on
every drop.

The shell's seams (claude-fleet#1628): FLEET_CONNECT_ROUTE_FILE names a file
this writes the chosen route to just before ssh starts — one JSON line,
{"machine", "kind": "direct"|"relay", "name"} — so the pane knows it is on the
relay (its bar's 「· 中转」); `--probe-direct MACHINE` is one handshake on each
of that machine's remembered DIRECT routes (no hub, no ssh): exit 0 when one
answers — what the pane runs every FLEET_CONNECT_UPGRADE_SECS while on the relay.

MACHINE is an alias or hostname from the hub's list (default: the one you
connected to last, else the hub's first). --verbose prints the measurement
table and the choice; --retest ignores the remembered choice; --print prints
the ssh command instead of running it. `-o KEY=VALUE` (repeatable) is an ssh
option placed BEFORE the host — a ControlMaster/ControlPath pair, RequestTTY —
so a caller that wants a remote command over a shared connection need not
rebuild the route (the shell, claude-fleet#1484). Anything after `--` goes to
ssh (a remote command, -L forwards, …).

A PINNED route (claude-fleet#2886, `fleet route <machine> <route>`, or
--route ROUTE here — with --pick too, on the machine picked) is taken every
time, before anything above: no handshake, no measuring, no switching; the
route file then says "source": "manual" and the "pin", so the client's bar
names it and its loop never upgrades it. FLEET_CONNECT_RETEST=last is a
reconnect in auto: the remembered route first, whatever its age, and every
route measured only when it does not answer (=1 still measures them all —
the upgrade off the relay).

--pick [MACHINE] (claude-fleet#1484): the certificate step and the machine
step of `fleet`, and nothing else — no measuring, no ssh. Prints one JSON
line: {"machine": <alias>, "hostname": …, "reason": …, "login": …,
"machines": [{"alias", "hostname"}, …]} — what the shell starts from. With
MACHINE the hub's pick is skipped and the name is checked against the route
list. Exit 1 when no machine is online (the candidates on stderr, as `fleet`
prints them). With no hub URL at all (claude-fleet#1712) the pick is THIS
computer, reason `local` (FLEET_NODE_ALIASES names it) — the client reads this
machine — and a MACHINE that is not this one exits 1; `fleet connect --print`
then prints `local <machine>`: the route is no ssh at all.

--cert-check (claude-fleet#2457): the doctor's `cert` row — this computer's
~/.ssh/fleet-cert-cert.pub, its principals and how long it is still valid, and
whether the hub accepts it (one signed route-list read). One line
"PASS|WARN|FAIL<TAB><text>", exit 0; exit 3 and nothing printed when there is
no certificate here (a machine signed in another way). --principal-hint reads
a hub refusal on stdin and prints its person's words when it is the principal
mismatch of claude-fleet#2437 (exit 0), else nothing (exit 1).

If the hub cannot be asked, the routes come from ~/.ssh/fleet-ssh-config —
the file `fleet login` wrote — without the relay.

--proxy MACHINE: reach a machine's sshd through the hub, as ssh's
ProxyCommand. When the direct routes fail (the home LAN is out of reach, the
tailnet is down, the gateway port is closed), the hub is still reachable, and
every machine already holds a link open to it. It opens a WebSocket to the
hub's relay endpoint and copies bytes between it and stdin/stdout:

    ssh -o ProxyCommand='fleet connect --proxy m4' m4

SSH runs end to end inside the stream: the hub only moves ciphertext, and the
machine's sshd still decides who logs in.

The hub admits you on one of (first that is present):
  FLEET_HUB_TOKEN / hub.json "token"   a viewer token (the operator) or a
                                       GitHub session token
  ~/.ssh/fleet-cert + -cert.pub        the connection certificate `fleet
                                       login` fetches (proven by signing with
                                       ssh-keygen -Y sign)

The hub's URL: --hub, else FLEET_HUB_URL, else FLEET_HUB_URL in fleet.conf
(issue #1623), else (one version) "url" in
~/.config/claude-fleet/hub.json.

Exit: --proxy: 0 the stream ended; 1 the hub refused (the reason is on
stderr). Otherwise ssh's own exit, 1 when no route answers or no machine is
known. 2 usage / configuration.

Every step leaves one line in the client's connect.log (claude-fleet#2896,
docs/CLIENT-LOGS.md): the hub's machine answer when it is not one (`home`), the
route measured (`pick`), ssh's start and end with its exit (`ssh-start` /
`ssh-end` — ssh runs as a child for that, ^C / ^Z / a SIGHUP reach it as
before), and each relay's handshake and end with who closed it and the
WebSocket close code (`relay-open` / `relay-end`). FLEET_CONNECT_SSH_VERBOSE=1
adds `ssh -v -E <logs>/ssh-v.log`. FLEET_CLIENT_LOG=0: no line, ssh exec'd.

Standard library only: this runs on a colleague's laptop, where nothing of the
fleet is installed but this file.
"""
import base64
import json
import os
import socket
import ssl
import struct
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

try:  # the ONE TLS context for the hub: every CA source this computer has (claude-fleet#2878)
    import fleet_tls
    fleet_tls.install()
except ImportError:
    fleet_tls = None


def _clientlog():
    """bin/fleet_clientlog.py beside this file (claude-fleet#2896) — also when
    this file is loaded by path (fleet-client-place.sh), where bin/ is not on
    sys.path; an older install without it logs nothing."""
    try:
        import importlib.util
        here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet_clientlog.py")
        spec = importlib.util.spec_from_file_location("fleet_clientlog", here)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


fleet_clientlog = _clientlog()


def clog(event, machine="", route="", ms="", result="", reason=""):
    """One line in the client's connect.log (docs/CLIENT-LOGS.md); never fails."""
    if fleet_clientlog:
        fleet_clientlog.write("connect", event, machine, route, "" if ms == "" else str(int(ms)), result, reason)

RELAY_PATH = "/v1/ssh-relay/connect"
SIG_NAMESPACE = "fleet-relay@claude-fleet"
ROUTES_PATH = "/v1/fleet/routes"
ROUTES_NAMESPACE = "fleet-routes@claude-fleet"
HOME_PATH = "/v1/fleet/home"
HOME_NAMESPACE = "fleet-home@claude-fleet"
CHUNK = 32 * 1024


class Refused(Exception):
    """The hub (or a route) said no; the message says why. code/body carry the
    hub's machine-readable refusal when it sent one."""

    def __init__(self, msg, code="", body=None, status=0):
        super().__init__(msg)
        self.code, self.body, self.status = code, body or {}, status


# The hub's 401 when the certificate's principals are not the login it checks
# against (claude-fleet#2437): golang.org/x/crypto/ssh's CheckCert words it
#   ssh: principal "X" not in the set of valid principals for given certificate: ["Y"]
PRINCIPAL_RE = re.compile(r'principal "([^"]*)" not in the set of valid principals[^\[]*\[([^\]]*)\]')


def principal_hint(text):
    """The person's words for that refusal (claude-fleet#2457), or "" when
    `text` is not it — the error string, or the hub's whole JSON body. The ONE
    wording: the shell, client placement and the sidebar's fleet-hub-sessions.sh
    (`--principal-hint`) all print this."""
    try:
        body = json.loads(text or "")
        if isinstance(body, dict):
            err = body.get("error")
            if isinstance(err, dict):  # the client door's {"error": {"message": …}}
                err = err.get("message")
            text = err if isinstance(err, str) else ""
    except ValueError:
        pass
    m = PRINCIPAL_RE.search(text or "")
    if not m:
        return ""
    have = ",".join(re.findall(r'"([^"]*)"', m.group(2))) or "无"
    return ("证书 principal(%s) 与入口期望(%s) 不一致 → 跑 `fleet login renew`；"
            "仍不行则入口需要升级（#2437）" % (have, m.group(1)))


_LAST_DIE = [""]
_SSH_RAN = [False]  # ssh started: from then on only its 255 is a failed connect


def die(msg, code=2):
    _LAST_DIE[0] = msg
    sys.stderr.write("fleet connect: " + msg + "\n")
    sys.exit(code)


def debug_after(run):
    """A person's connect (claude-fleet#2894): its outcome to
    fleet-debug-prompt.sh — a third failure in half an hour asks whether the hub
    should take a look. The code is the connect's, whatever the prompt does; an
    interrupt (130, 143) is no failure, nor is the far end's own exit once ssh
    connected — only ssh's 255 is. FLEET_DEBUG_PROMPT=0: as before."""
    try:
        rc = run()
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    prompt = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-debug-prompt.sh")
    if os.environ.get("FLEET_DEBUG_PROMPT", "1") != "0" and os.path.isfile(prompt) and rc not in (130, 143, -2, -15):
        failed = bool(rc) and (not _SSH_RAN[0] or rc == 255)
        try:
            subprocess.call(["sh", prompt, "after", "connect", str(rc) if failed else "0",
                             _LAST_DIE[0] if failed else ""])
        except OSError:
            pass
    return rc


def env_num(name, default, cast=float):
    try:
        return cast(os.environ.get(name) or default)
    except ValueError:
        return default


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "claude-fleet")


def machine_conf_hub():
    """FLEET_HUB_URL from the machine's ONE config file (issue #1623) — its last
    assignment, `export` and quotes allowed; '' with no file or no line."""
    d = os.environ.get("FLEET_CONF_DIR") or config_dir()
    url = ""
    try:
        with open(os.path.join(d, "fleet.conf")) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?FLEET_HUB_URL=(.*)$", line)
                if m:
                    url = m.group(1).split(" #")[0].strip().strip("\"'")
    except OSError:
        pass
    return url


def local_machine():
    """THIS computer as a route-list entry (claude-fleet#1712): its hostname's
    first label, named through FLEET_NODE_ALIASES (`macmini=m5`) — the label
    fleet-shell.sh's this_machine() recognizes, so the client nests the attach
    right here instead of ssh-ing anywhere."""
    host = (socket.gethostname() or "").split(".", 1)[0]
    alias = host
    for a in (os.environ.get("FLEET_NODE_ALIASES") or "").split():
        h, _, v = a.partition("=")
        if h == host and v:
            alias = v
    return {"alias": alias, "hostname": host}


def is_local_name(want):
    m = local_machine()
    return not want or want in (m["alias"], m["hostname"])


def pick_local(want):
    """--pick with no hub URL at all (claude-fleet#1712): the client still opens
    — on THIS computer, the one machine there is, reason `local`. A name that is
    not this computer has no route without a hub: exit 1, saying so."""
    m = local_machine()
    if not is_local_name(want):
        die("没有入口时只能开本机 %s（%s 要入口才连得到）" % (m["alias"], want), 1)
    import getpass
    try:
        login = getpass.getuser()
    except Exception:
        login = ""
    return pick_json(m, {"machines": [m], "login": login}, "local")


def load_hub_conf():
    path = os.path.join(config_dir(), "hub.json")
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        die("cannot read %s: %s" % (path, e))


def tls_hint(e):
    """' — <why + fix>' when e is a certificate verify failure (claude-fleet#2878), else ''."""
    h = fleet_tls.hint(e) if fleet_tls else ""
    return (" — " + h) if h else ""


def cert_paths():
    key = os.environ.get("FLEET_CERT") or os.path.join(os.path.expanduser("~"), ".ssh", "fleet-cert")
    return key, key + "-cert.pub"


class WS:
    """A minimal RFC 6455 client: one connection, binary + text frames."""

    def __init__(self, url, headers, timeout=20):
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https", "ws", "wss"):
            raise Refused("the hub URL must be http(s)://…, not %r" % url)
        secure = u.scheme in ("https", "wss")
        port = u.port or (443 if secure else 80)
        raw = socket.create_connection((u.hostname, port), timeout=timeout)
        if secure:
            ctx = fleet_tls.context() if fleet_tls else ssl.create_default_context()
            raw = ctx.wrap_socket(raw, server_hostname=u.hostname)
        self.sock = raw
        self.wlock = threading.Lock()
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        target = (u.path or "/") + ("?" + u.query if u.query else "")
        host = u.hostname + ("" if u.port is None else ":%d" % u.port)
        lines = ["GET %s HTTP/1.1" % target, "Host: " + host, "Upgrade: websocket",
                 "Connection: Upgrade", "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13"]
        lines += ["%s: %s" % kv for kv in headers.items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = self._read_until(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        parts = status.split(" ", 2)
        if len(parts) < 2 or parts[1] != "101":
            body = self.buf[:500].decode(errors="replace").strip()
            try:
                body = json.loads(body).get("error", body)
            except ValueError:
                pass
            self.sock.close()
            raise Refused("hub refused the connection: %s%s" % (" ".join(parts[1:]), (" — " + body) if body else ""))
        self.sock.settimeout(None)

    def _read_until(self, marker):
        while marker not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise Refused("hub closed the connection during the handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(marker, 1)
        return head

    def _read_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(max(65536, n - len(self.buf)))
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        # XOR the mask in one big-int pass: a per-byte loop costs a core at
        # scp speed.
        reps = (mask * (n // 4 + 1))[:n]
        body = (int.from_bytes(payload, "big") ^ int.from_bytes(reps, "big")).to_bytes(n, "big") if n else b""
        with self.wlock:
            self.sock.sendall(head + mask + body)

    def recv(self):
        """One whole message: (opcode, payload). Answers pings itself."""
        msg, first = b"", None
        while True:
            b0, b1 = self._read_exact(2)
            fin, op, n = b0 & 0x80, b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if b1 & 0x80 else None
            data = self._read_exact(n)
            if mask:
                reps = (mask * (n // 4 + 1))[:n]
                data = (int.from_bytes(data, "big") ^ int.from_bytes(reps, "big")).to_bytes(n, "big") if n else b""
            if op == 0x9:
                self.send(0xA, data)
                continue
            if op == 0xA:
                continue
            if op == 0x8:
                return op, data
            if op != 0:
                first = op
            msg += data
            if fin:
                return first, msg

    def close(self, code=1000):
        try:
            self.send(0x8, struct.pack("!H", code))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def ssh_sign(message, namespace):
    """(certificate line, `ssh-keygen -Y sign` armor over message)."""
    key, cert = cert_paths()
    if not (os.path.exists(key) and os.path.exists(cert)):
        raise Refused("the hub asked for a connection certificate and there is none at %s — run `fleet login`, "
                      "or set FLEET_HUB_TOKEN" % cert)
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", namespace],
                             input=message.encode(), capture_output=True, check=True).stdout.decode()
    except FileNotFoundError:
        raise Refused("ssh-keygen is not installed")
    except subprocess.CalledProcessError as e:
        raise Refused("ssh-keygen -Y sign failed: %s" % e.stderr.decode(errors="replace").strip())
    with open(cert) as f:
        return f.read().strip(), sig


def sign_nonce(nonce):
    cert, sig = ssh_sign(nonce, SIG_NAMESPACE)
    return {"type": "auth", "cert": cert, "sig": sig}


def open_relay(node, hub, token, timeout=20):
    """A relay to node's sshd, handshake done: the WS, ready for stream bytes."""
    q = urllib.parse.urlencode({"node": node})
    headers = {"Authorization": "Bearer " + token} if token else {}
    ws = WS(hub.rstrip("/") + RELAY_PATH + "?" + q, headers, timeout=timeout)
    try:
        # The handshake: JSON text frames until "ready".
        while True:
            try:
                op, data = ws.recv()
            except EOFError:
                raise Refused("hub closed the relay before it was ready")
            if op == 0x8:
                reason = data[2:].decode(errors="replace") if len(data) > 2 else ""
                raise Refused("hub closed the relay before it was ready" + (": " + reason if reason else ""))
            if op != 0x1:
                raise Refused("hub sent stream bytes before the relay was ready")
            m = json.loads(data)
            t = m.get("type")
            if t == "challenge":
                ws.send(0x1, json.dumps(sign_nonce(m.get("nonce", ""))).encode())
            elif t == "ready":
                return ws
            elif t == "error":
                raise Refused("%s: %s" % (m.get("code", "ERROR"), m.get("message", "")))
            else:
                raise Refused("unexpected handshake message %r" % t)
    except BaseException:
        ws.close()
        raise


def ws_close_text(data):
    """A close frame's payload → 'ws close <code>[: <reason>]'."""
    if len(data) < 2:
        return "ws close (no code)"
    code = struct.unpack("!H", data[:2])[0]
    reason = data[2:].decode(errors="replace").strip()
    return "ws close %d%s" % (code, (": " + reason) if reason else "")


def proxy(node, hub, token):
    t0 = time.time()
    try:
        ws = open_relay(node, hub, token)
    except (Refused, OSError) as e:
        clog("relay-open", node, "relay", (time.time() - t0) * 1000, "fail", "%s%s" % (e, tls_hint(e)))
        die(str(e), 1)
    t1 = time.time()
    clog("relay-open", node, "relay", (t1 - t0) * 1000, "ok", hub)

    out = sys.stdout.buffer
    done = threading.Event()
    # who ended the stream first (claude-fleet#2896): the hub (a close frame,
    # its code + reason), the network (the socket gone with no close frame), or
    # this side (ssh closed our stdin) — the first one to happen is the answer
    ended = {}

    def end(by, why):
        ended.setdefault("at", time.time())
        ended.setdefault("by", by)
        ended.setdefault("why", why)

    def down():
        try:
            while True:
                op, data = ws.recv()
                if op == 0x8:
                    end("hub", ws_close_text(data))
                    break
                if op == 0x2 and data:
                    out.write(data)
                    out.flush()
        except EOFError:
            end("net", "the hub's socket closed with no close frame")
        except OSError as e:
            end("net", "socket error: %s" % e)
        done.set()

    threading.Thread(target=down, daemon=True).start()
    try:
        while not done.is_set():
            chunk = os.read(0, CHUNK)
            if not chunk:
                end("client", "ssh closed the stream (stdin EOF)")
                break
            ws.send(0x2, chunk)
    except OSError as e:
        end("client", "stdin/send error: %s" % e)
    # stdin ended (ssh is done writing): give the far side's last bytes a
    # moment rather than cutting them off. FLEET_CONNECT_DRAIN_SECS for tests.
    done.wait(timeout=float(os.environ.get("FLEET_CONNECT_DRAIN_SECS") or 10))
    ws.close()
    # the stream's length: from ready to the first end, not to this exit
    clog("relay-end", node, "relay", (ended.get("at", time.time()) - t1) * 1000,
         ended.get("by", "client"), ended.get("why", ""))
    return 0




# ── route picking (claude-fleet#1414) ───────────────────────────────────────

def cache_path():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "claude-fleet", "connect.json")


def load_cache():
    try:
        with open(cache_path()) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cache(d):
    path = cache_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=1)
        os.replace(tmp, path)
    except OSError:
        pass  # a cache that cannot be written only costs the next run a re-measure


def fetch_signed(hub, path, namespace, token, what, extra=None, timeout=10):
    """One hub read admitted by a token (GET, extra as the query) or by the
    certificate (POST {cert, sig, ts, …extra}, signed under namespace over
    "<namespace's first word> <ts>" — the hub's RoutesSigMessage shape)."""
    url = hub.rstrip("/") + path
    extra = {k: v for k, v in (extra or {}).items() if v}
    if token:
        if extra:
            url += "?" + urllib.parse.urlencode(extra)
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    else:
        ts = int(time.time())
        cert, sig = ssh_sign("%s %d" % (namespace.split("@")[0], ts), namespace)
        body = dict(extra, cert=cert, sig=sig, ts=ts)
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        why = body.get("error", "") if isinstance(body, dict) else ""
        hint = principal_hint(raw.decode("utf-8", "replace"))
        if hint:
            raise Refused(hint, code="principal_mismatch", body=body if isinstance(body, dict) else {}, status=e.code)
        raise Refused("hub refused %s (HTTP %d)%s" % (what, e.code, (": " + why) if why else ""),
                      code=body.get("code", "") if isinstance(body, dict) else "", body=body, status=e.code)


def fetch_routes(hub, token, timeout=10):
    """The hub's route list for whoever this is (RoutesResponse)."""
    return fetch_signed(hub, ROUTES_PATH, ROUTES_NAMESPACE, token, "the route list", timeout=timeout)


def fetch_home(hub, token, last, timeout=10):
    """The hub's pick of which machine to enter (HomeResponse, #1470): the
    route list plus "machine" (the pick) and "reason". `last` is this
    computer's own memory of the machine it entered last, a hint."""
    return fetch_signed(hub, HOME_PATH, HOME_NAMESPACE, token, "the machine pick", {"last": last or ""}, timeout)


def ssh_config_snippet_path():
    return os.path.join(os.path.expanduser("~"), ".ssh", "fleet-ssh-config")


def parse_ssh_config_snippet(text):
    """Machines from the snippet `fleet login` wrote (fleet-ssh-config v1):
    a block "Host <alias> fleet-<alias> fleet-<alias>-<route>" opens a machine,
    each "Host fleet-<alias>-<route>" after it adds a route. No relay: the
    snippet does not name the machine as the hub's roster does. Each machine
    keeps its OWN "User" (claude-fleet#2457: the hub writes every machine's
    login since #2437); the top-level "login" is only the default for a machine
    whose blocks name none."""
    machines, cur, block, login = [], None, None, ""
    for line in text.splitlines():
        w = line.split()
        if not w or w[0].startswith("#"):
            continue
        k = w[0].lower()
        if k == "host":
            names = w[1:]
            if len(names) >= 3:
                cur = {"hostname": "", "alias": names[0], "routes": [], "relay": False}
                machines.append(cur)
            if cur is None:
                block = None
                continue
            pre = "fleet-%s-" % cur["alias"]
            name = names[-1][len(pre):] if names[-1].startswith(pre) else names[-1]
            block = {"name": name, "host": "", "port": 0}
            cur["routes"].append(block)
        elif block is not None and len(w) > 1:
            if k == "hostname":
                block["host"] = w[1]
            elif k == "port" and w[1].isdigit():
                block["port"] = int(w[1])
            elif k == "user":
                cur.setdefault("login", w[1])
                login = login or w[1]
    for m in machines:
        m["routes"] = [r for r in m["routes"] if r["host"]]
    return {"login": login, "machines": [m for m in machines if m["routes"]]}


def probe_direct(host, port, timeout):
    """One TCP connect + SSH banner: milliseconds, or raises."""
    t0 = time.monotonic()
    with socket.create_connection((host, port or 22), timeout=timeout) as c:
        c.settimeout(max(0.1, timeout - (time.monotonic() - t0)))
        banner = b""
        while b"\n" not in banner and len(banner) < 512:
            d = c.recv(256)
            if not d:
                break
            banner += d
    if not banner.startswith(b"SSH-"):
        raise Refused("no SSH banner")
    return (time.monotonic() - t0) * 1000


def probe_relay(hub, node, token, timeout):
    """One relay through the hub, up to the far sshd's banner: milliseconds."""
    t0 = time.monotonic()
    ws = open_relay(node, hub, token, timeout=timeout)
    try:
        ws.sock.settimeout(max(0.1, timeout - (time.monotonic() - t0)))
        while True:
            op, data = ws.recv()
            if op == 0x8:
                raise Refused("the relay closed before the SSH banner")
            if op == 0x2:
                break
    finally:
        ws.close()
    if not data.startswith(b"SSH-"):
        raise Refused("no SSH banner")
    return (time.monotonic() - t0) * 1000


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return None if not n else (xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2)


def is_tailnet(r):
    """A direct route over the tailnet (the hub names it `tailnet` / `tailscale`)."""
    return (r or {}).get("kind", "direct") == "direct" and "tail" in ((r or {}).get("name") or "")


def prefer_tailnet():
    return os.environ.get("FLEET_CONNECT_PREFER_TAILNET", "1") != "0"


def rank_routes(rows):
    """Best first: most handshakes answered, then the tailnet (claude-fleet#2987),
    then lowest median latency, then the hub's own order. A route that answered
    none is never chosen. On one LAN the public gateway's port and the tailnet
    answer within the same few ms and noise used to pick either — and the one
    picked was kept for every reconnect after it; the tailnet is the line that
    keeps working when the person leaves that LAN.
    FLEET_CONNECT_PREFER_TAILNET=0: latency alone, as before."""
    pt = prefer_tailnet()

    def key(r):
        med = median(r["ms"])
        return (-len(r["ms"]), 0 if pt and r["ms"] and is_tailnet(r) else 1,
                med if med is not None else float("inf"), r["order"])
    return sorted(rows, key=key)


def route_rows(machine, hub):
    rows = []
    for i, r in enumerate(machine.get("routes") or []):
        rows.append({"name": r["name"], "kind": "direct", "host": r["host"], "port": int(r.get("port") or 22),
                     "order": i, "ms": [], "errors": []})
    if hub:
        rows.append({"name": "relay", "kind": "relay", "host": machine.get("hostname") or machine.get("alias"),
                     "port": 0, "order": len(rows), "ms": [], "errors": [],
                     "skip": None if machine.get("relay") else "入口暂时不能转发到这台机器"})
    return rows


def measure(rows, hub, token, probes, timeout):
    """Fill each row's ms / errors: routes in parallel, a route's handshakes in
    sequence (so the relay never holds more than one stream open)."""
    def run(r):
        for _ in range(probes):
            try:
                if r["kind"] == "relay":
                    r["ms"].append(probe_relay(hub, r["host"], token, timeout))
                else:
                    r["ms"].append(probe_direct(r["host"], r["port"], timeout))
            except (Refused, OSError, EOFError, ValueError) as e:
                r["errors"].append(str(e) or e.__class__.__name__)
    threads = [threading.Thread(target=run, args=(r,), daemon=True) for r in rows if not r.get("skip")]
    for t in threads:
        t.start()
    for t in threads:
        t.join(probes * (timeout + 1) + 5)
    return rank_routes([r for r in rows if not r.get("skip")]) + [r for r in rows if r.get("skip")]


# ── a pinned route (claude-fleet#2886) ──────────────────────────────────────
# `fleet route <machine> <route>` writes one line `<machine> <route>` to
# ~/.config/claude-fleet/routes; with a line there, every connect to that
# machine takes that one route — no measuring, no switching — and a drop comes
# back over the same one. `auto` (no line) is the measuring above.

PIN_WORDS = ("auto", "relay", "direct", "tailscale")
PIN_RE = re.compile(r"^(auto|relay|direct|tailscale|tailnet|[A-Za-z0-9._-]+(:[0-9]{1,5})?|\[[0-9A-Fa-f:.]+\](:[0-9]{1,5})?)$")


def routes_path():
    return os.path.join(config_dir(), "routes")


def load_pins():
    """{machine: route} from the routes file; a malformed line is skipped."""
    pins = {}
    try:
        with open(routes_path()) as f:
            for line in f:
                w = line.split("#", 1)[0].split()
                if len(w) == 2 and PIN_RE.match(w[1]) and w[1] != "auto":
                    pins[w[0]] = w[1]
                elif len(w) == 2 and w[1] == "auto":
                    pins.pop(w[0], None)
    except OSError:
        pass
    return pins


def save_pin(machine, route):
    """Pin MACHINE to ROUTE (`auto` removes its line). One rename: a reader
    never sees half a file."""
    pins = load_pins()
    if route == "auto":
        pins.pop(machine, None)
    else:
        pins[machine] = "tailscale" if route == "tailnet" else route
    path = routes_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("# fleet route — one machine a line: <machine> relay|direct|tailscale|<route name>|<host[:port]>\n")
        for k in sorted(pins):
            f.write("%s %s\n" % (k, pins[k]))
    os.replace(tmp, path)


def pin_for(*names):
    """The pinned route for the first of NAMES that has one ('' = auto)."""
    pins = load_pins()
    for n in names:
        if n and n in pins:
            return pins[n]
    return ""


def machine_names(m):
    return [x for x in ((m or {}).get("alias"), (m or {}).get("hostname")) if x]


def pinned_row(rows, pin):
    """The row PIN names among a machine's ROWS: `relay`, `tailscale` (the
    tailnet route), `direct` (the first direct route that is not the tailnet, in
    the hub's order), a route's own name — else PIN is an address, host[:port].
    None when the machine has no such route."""
    def tail(r):
        return "tail" in r["name"]
    if pin == "relay":
        return next((r for r in rows if r["kind"] == "relay"), None)
    if pin in ("tailscale", "tailnet"):
        return next((r for r in rows if r["kind"] == "direct" and tail(r)), None)
    if pin == "direct":
        return (next((r for r in rows if r["kind"] == "direct" and not tail(r)), None)
                or next((r for r in rows if r["kind"] == "direct"), None))
    hit = next((r for r in rows if r["name"] == pin), None)
    if hit:
        return hit
    m = re.match(r"^\[?([^\[\]]+?)\]?(?::([0-9]{1,5}))?$", pin)
    if not m or (":" in m.group(1) and not pin.startswith("[")):
        return None
    return {"name": pin, "kind": "direct", "host": m.group(1), "port": int(m.group(2) or 22),
            "order": 0, "ms": [], "errors": []}


def route_label(kind, name):
    """A route in a person's words: 中转 · Tailscale · 直连 <name>."""
    if kind == "relay":
        return "中转"
    if "tail" in (name or ""):
        return "Tailscale"
    if name and (re.search(r"[.:]", name) or name[:1].isdigit()):
        return name  # an address the person pinned
    return "直连" + ((" " + name) if name and name not in ("public", "direct") else "")


def pin_label(pin):
    return {"relay": "中转", "tailscale": "Tailscale", "tailnet": "Tailscale", "direct": "直连"}.get(pin, pin)


def addr(r, hub):
    return ("经入口 " + hub) if r["kind"] == "relay" else "%s:%d" % (r["host"], r["port"])


def pad(s, width):
    """s left-justified to width terminal columns (a CJK character takes two)."""
    import unicodedata
    cols = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
    return s + " " * max(1, width - cols)


def print_table(label, rows, chosen, probes, hub):
    w = sys.stderr.write
    w("fleet connect · %s · 每条线 %d 次 TCP+SSH 握手\n" % (label, probes))
    w("  " + pad("线路", 10) + pad("地址", 40) + pad("成功", 6) + "延迟(中位)\n")
    for r in rows:
        mark = "*" if chosen is not None and r is chosen else " "
        if r.get("skip"):
            ok, lat, note = "—", "—", r["skip"]
        else:
            med = median(r["ms"])
            ok = "%d/%d" % (len(r["ms"]), probes)
            lat = ("%.0fms" if med >= 10 else "%.1fms") % med if med is not None else "—"
            note = r["errors"][-1] if r["errors"] else ""
        w(mark + " " + pad(r["name"], 10) + pad(addr(r, hub), 40) + pad(ok, 6) + pad(lat, 10) + note + "\n")
    w("→ %s\n" % (("选中 " + chosen["name"]) if chosen else "没有一条线能连通"))


def pick_machine(machines, want, last):
    if want:
        for m in machines:
            if want.lower() in (str(m.get("alias") or "").lower(), str(m.get("hostname") or "").lower()):
                return m
        return None
    for m in machines:
        if last and last in (m.get("alias"), m.get("hostname")):
            return m
    return machines[0] if machines else None


def known_hosts_path():
    return os.environ.get("FLEET_KNOWN_HOSTS") or os.path.join(os.path.expanduser("~"), ".ssh", "fleet-known-hosts")


HOST_KEY_RE = re.compile(r"^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,3}$")


def host_keys(machine):
    """The machine's sshd host keys as the hub lists them (claude-fleet#2983),
    each "<type> <base64>" — anything else is dropped: it goes into a file ssh
    trusts."""
    ks = machine.get("host_keys") if isinstance(machine, dict) else None
    return [k for k in ks if isinstance(k, str) and HOST_KEY_RE.match(k)] if isinstance(ks, list) else []


def write_known_hosts(machine):
    """The hub's word for this machine's host keys, under the HostKeyAlias ssh
    checks (fleet-<alias>), into ~/.ssh/fleet-known-hosts (claude-fleet#2983):
    a new person's first connection then asks no yes/no question, and a key
    the hub does not list is still refused (ssh's own "host key has changed").
    The file is the hub's: this machine's lines are replaced, the others kept.
    False when the hub listed no keys — ssh then checks as it always did."""
    keys = host_keys(machine)
    if not keys:
        return False
    alias = "fleet-" + (machine.get("alias") or machine.get("hostname"))
    path = known_hosts_path()
    try:
        with open(path) as f:
            keep = [l for l in f.read().splitlines() if l.strip() and l.split()[0] != alias]
    except OSError:
        keep = []
    text = "\n".join(keep + ["%s %s" % (alias, k) for k in keys]) + "\n"
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        return False
    return True


def ssh_command(machine, route, login, hub, ssh_opts=(), known_hosts=False):
    """known_hosts: write_known_hosts wrote this machine's keys — ssh checks
    ~/.ssh/fleet-known-hosts first, then the person's own known_hosts."""
    alias = machine.get("alias") or machine.get("hostname")
    cmd = ["ssh", "-o", "HostKeyAlias=fleet-" + alias, "-o", "ConnectTimeout=15"]
    if known_hosts:
        # ~ as ssh expands it: a home with a space would split an absolute path
        mine = os.environ.get("FLEET_KNOWN_HOSTS") or "~/.ssh/fleet-known-hosts"
        cmd += ["-o", "UserKnownHostsFile=%s ~/.ssh/known_hosts" % mine]
    key, cert = cert_paths()
    if os.path.exists(key) and os.path.exists(cert):
        cmd += ["-i", key, "-o", "CertificateFile=" + cert]
    if login:
        cmd += ["-l", login]
    for o in ssh_opts:
        cmd += ["-o", o]
    vlog = ssh_verbose_log()
    if vlog:
        cmd += ["-v", "-E", vlog]
    if route["kind"] == "relay":
        me = os.path.abspath(__file__)
        pc = "%s %s --proxy %s --hub %s" % (shlex.quote(sys.executable or "python3"), shlex.quote(me),
                                            shlex.quote(route["host"]), shlex.quote(hub))
        cmd += ["-o", "ProxyCommand=" + pc, alias]
    else:
        if route["port"] and route["port"] != 22:
            cmd += ["-p", str(route["port"])]
        cmd.append(route["host"])
    return cmd


def ssh_verbose_log():
    """FLEET_CONNECT_SSH_VERBOSE=1 (claude-fleet#2896): ssh -v into
    <logs>/ssh-v.log, rotated like the client's other logs; default off."""
    if os.environ.get("FLEET_CONNECT_SSH_VERBOSE") != "1" or not fleet_clientlog:
        return ""
    try:
        d = fleet_clientlog.log_dir()
        os.makedirs(d, mode=0o700, exist_ok=True)
        path = os.path.join(d, "ssh-v.log")
        fleet_clientlog.rotate(path)
        return path
    except OSError:
        return ""


def connect(want, hub, token, verbose, retest, print_only, ssh_args, info=None, ssh_opts=()):
    """info: a route list already in hand (the home answer, #1470) — the hub
    is not asked again for it."""
    probes = max(1, env_num("FLEET_CONNECT_PROBES", 3, int))
    timeout = env_num("FLEET_CONNECT_TIMEOUT", 4.0)
    ttl = env_num("FLEET_CONNECT_CACHE_SECS", 600.0)
    cache = load_cache()
    entries = cache.get("machines") if isinstance(cache.get("machines"), dict) else {}
    now = time.time()

    # 0 — a pinned route (claude-fleet#2886): that one, untested, every time.
    # The machine as remembered serves it without asking the hub; a machine
    # never seen yet is looked up below first.
    key = want or cache.get("last") or ""
    ent = entries.get(key) if key else None
    pin = pin_for(key, *machine_names((ent or {}).get("machine")))
    if pin and ent and ent.get("hub") == hub and isinstance(ent.get("machine"), dict):
        r = pinned_row(route_rows(ent["machine"], hub), pin)
        if r is not None:
            return run_pinned(ent["machine"], ent.get("label") or key, r, pin, ent.get("login", ""), hub,
                              verbose, print_only, ssh_args, ssh_opts)

    # 1 — a remembered choice: one handshake to confirm it. Fresh (inside the
    # TTL), or — retest "last", a reconnect (claude-fleet#2886) — of any age:
    # only when it does not answer is every route measured again.
    if not pin and ent and retest is not True and ent.get("hub") == hub \
            and (retest == "last" or now - float(ent.get("at", 0)) < ttl):
        r = ent["route"]
        r = dict(r, ms=[], errors=[], order=0)
        # A remembered line that is not the tailnet while the machine has one
        # (claude-fleet#2987): the tailnet is asked in the same breath, and taken
        # when it answers — a line picked once (the tailnet down that minute, or a
        # coin toss of latency) is no longer kept for every reconnect after it.
        tl = None
        if prefer_tailnet() and not is_tailnet(r):
            tl = next((dict(x, kind="direct", ms=[], errors=[], order=1) for x in (ent.get("routes") or [])
                       if isinstance(x, dict) and x.get("host") and is_tailnet(x)), None)
        measure([r] + ([tl] if tl else []), hub, token, 1, timeout)
        if tl and tl["ms"]:
            ent["route"] = {k: tl[k] for k in ("name", "kind", "host", "port")}
            ent["at"] = now
            save_cache(cache)
            clog("pick", ent.get("label") or key, "direct", tl["ms"][0], "ok",
                 "tailnet %s over remembered %s" % (tl["name"], r["name"]))
            if verbose:
                sys.stderr.write("fleet connect · %s · Tailscale 通了，换掉记住的 %s\n" % (ent["label"], r["name"]))
            return run_ssh(ent["machine"], tl, ent.get("login", ""), hub, print_only, ssh_args, ssh_opts)
        if r["ms"]:
            if verbose:
                sys.stderr.write("fleet connect · %s · 用 %d 秒前测出的 %s（复核 %.0fms 通过；--retest 重测）\n"
                                 % (ent["label"], now - float(ent["at"]), r["name"], r["ms"][0]))
            return run_ssh(ent["machine"], r, ent.get("login", ""), hub, print_only, ssh_args, ssh_opts)
        if verbose:
            sys.stderr.write("fleet connect · 记住的线路 %s 不通了（%s），全部重测\n"
                             % (r["name"], r["errors"][-1] if r["errors"] else "?"))

    # 2 — ask the hub; fall back to the snippet `fleet login` wrote.
    source = "hub"
    if info is None:
        try:
            info = fetch_routes(hub, token) if hub else None
        except (Refused, OSError, ValueError) as e:
            info, source = None, "hub: %s" % e
    if info is None:
        try:
            with open(ssh_config_snippet_path()) as f:
                info = parse_ssh_config_snippet(f.read())
            if verbose or hub:
                sys.stderr.write("fleet connect: %s — 改用 %s 里的线路（没有中转）\n"
                                 % (source if hub else "no hub URL", ssh_config_snippet_path()))
            hub = ""
        except OSError:
            if not hub:
                die("no hub URL: pass --hub, set FLEET_HUB_URL, or run `fleet login --hub <入口地址>` once")
            die(source, 1)
    machines = info.get("machines") or []
    m = pick_machine(machines, want, cache.get("last"))
    if m is None:
        names = ", ".join(str(x.get("alias") or x.get("hostname")) for x in machines) or "（无）"
        die(("没有叫 %s 的机器；你能连：%s" % (want, names)) if want else "入口没有列出你能连的机器", 1)
    label = m.get("alias") or m.get("hostname")
    if m.get("hostname") and m.get("alias") and m["hostname"] != m["alias"]:
        label = "%s (%s)" % (m["alias"], m["hostname"])
    name = m.get("alias") or m.get("hostname")

    pin = pin_for(want, *machine_names(m))
    if pin:
        r = pinned_row(route_rows(m, hub), pin)
        if r is None:
            die("%s 钉住的线路「%s」这台机器没有%s — 改回自动：fleet route %s auto"
                % (label, pin_label(pin), "（中转要入口）" if pin == "relay" and not hub else "", name), 1)
        # remembered for the next connect (step 0 then needs no hub); its
        # measured table, if any, is kept for `fleet route`'s list
        old = entries.get(name) or {}
        ent = dict(old, at=old.get("at", now), hub=hub, label=label, machine=m, login=machine_login(m, info),
                   route=old.get("route") or {k: r[k] for k in ("name", "kind", "host", "port")},
                   routes=[{k: x[k] for k in ("name", "kind", "host", "port")}
                           for x in route_rows(m, hub) if x["kind"] != "relay"])
        entries[name] = ent
        if want and want != name:
            entries[want] = ent
        cache["machines"], cache["last"] = entries, name
        save_cache(cache)
        return run_pinned(m, label, r, pin, ent["login"], hub, verbose, print_only, ssh_args, ssh_opts)

    # 3 — measure every route, pick, remember.
    rows = measure(route_rows(m, hub), hub, token, probes, timeout)
    best = rows[0] if rows and rows[0]["ms"] else None
    if verbose or best is None:
        print_table(label, rows, best, probes, hub)
    clog("pick", m.get("alias") or m.get("hostname"), best["kind"] if best else "-",
         median(best["ms"]) if best else "", "ok" if best else "fail",
         "; ".join("%s %d/%d%s" % (r["name"], len(r["ms"]), probes,
                                   (" " + r["errors"][-1]) if not r["ms"] and r.get("errors") else
                                   (" skip " + str(r["skip"])) if r.get("skip") else "")
                   for r in rows))
    if best is None:
        die("%s: 没有一条线能连通" % label, 1)
    login = machine_login(m, info)
    route = {k: best[k] for k in ("name", "kind", "host", "port")}
    ent = {"at": now, "hub": hub, "label": label, "machine": m, "login": login, "route": route,
           "routes": [{k: r[k] for k in ("name", "kind", "host", "port")} for r in rows if r["kind"] != "relay"],
           "table": [{"name": r["name"], "ok": len(r["ms"]), "median_ms": median(r["ms"]),
                      "skip": r.get("skip")} for r in rows]}
    entries[name] = ent
    if want and want != name:
        entries[want] = ent
    cache["machines"], cache["last"] = entries, name
    save_cache(cache)
    return run_ssh(m, route, login, hub, print_only, ssh_args, ssh_opts)


def machine_login(m, info):
    """The login THIS machine is entered as (claude-fleet#2457): its own, from
    the snippet's Host block or the hub's machine entry; the person's default
    only for a machine that names none. Never another machine's."""
    own = (m or {}).get("login")
    if isinstance(own, str) and own:
        return own
    return (info or {}).get("login") or ""


def login_override(login):
    """The login this connection is made as: FLEET_CONNECT_LOGIN when a caller
    named one (claude-fleet#2430: fleet-remote-view.sh, for a session in another
    of the person's logins on that machine — the certificate carries every one),
    else the person's default from the hub."""
    want = os.environ.get("FLEET_CONNECT_LOGIN") or ""
    if want and re.fullmatch(r"[a-z_][a-z0-9_.-]{0,31}", want):
        return want
    return login


def run_pinned(machine, label, route, pin, login, hub, verbose, print_only, ssh_args, ssh_opts=()):
    if verbose:
        sys.stderr.write("fleet connect · %s · 钉住：%s（手动）— 不测速，只走 %s；改回自动：fleet route %s auto\n"
                         % (label, pin_label(pin), addr(route, hub),
                            machine.get("alias") or machine.get("hostname")))
    return run_ssh(machine, route, login, hub, print_only, ssh_args, ssh_opts, pin=pin)


def run_ssh(machine, route, login, hub, print_only, ssh_args, ssh_opts=(), pin=""):
    alias = machine.get("alias") or machine.get("hostname") or "?"
    login = login_override(login)
    kh = write_known_hosts(machine)
    cmd = ssh_command(machine, route, login, hub, ssh_opts, known_hosts=kh) + list(ssh_args)
    rf = os.environ.get("FLEET_CONNECT_ROUTE_FILE")
    if rf and not print_only:
        try:
            # source / pin (claude-fleet#2886): a pinned line is never upgraded,
            # and the bar says 手动
            with open(rf, "w") as f:
                f.write(json.dumps({"machine": alias, "kind": route["kind"], "name": route["name"],
                                    "login": login or "", "source": "manual" if pin else "auto",
                                    "pin": pin or ""}) + "\n")
        except OSError:
            pass  # the pane then just does not know its route: no 「· 中转」, no upgrade
    if print_only:
        print(" ".join(shlex.quote(c) for c in cmd))
        return 0
    sys.stderr.flush()
    if not fleet_clientlog or os.environ.get("FLEET_CLIENT_LOG") == "0":
        try:
            os.execvp(cmd[0], cmd)
        except OSError as e:
            die("cannot run ssh: %s" % e, 1)
    return run_logged(cmd, alias, route, login)


def run_logged(cmd, alias, route, login):
    """ssh as a child, its start and end in connect.log (claude-fleet#2896) —
    otherwise as exec would have it: the terminal's ^C / ^\\ / ^Z reach ssh
    alone (this process ignores them), a SIGHUP / SIGTERM sent to this process
    is passed on, a self-suspended ssh (~^Z) stops this one too, and ssh's exit
    is this one's."""
    import signal
    t0 = time.time()
    clog("ssh-start", alias, route["kind"], "", "", "%s %s:%s login=%s" % (route["name"], route["host"],
                                                                         route.get("port") or 22, login or "-"))
    try:
        child = subprocess.Popen(cmd)
        _SSH_RAN[0] = True
    except OSError as e:
        clog("ssh-end", alias, route["kind"], 0, "fail", "cannot run ssh: %s" % e)
        die("cannot run ssh: %s" % e, 1)
    for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP):
        signal.signal(sig, signal.SIG_IGN)
    got = {}

    def forward(sig, _frame):
        got.setdefault("sig", sig)
        try:
            child.send_signal(sig)
        except OSError:
            pass
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, forward)
    while True:
        try:
            _, st = os.waitpid(child.pid, os.WUNTRACED)
        except InterruptedError:
            continue
        except ChildProcessError:
            st = 0
            break
        if os.WIFSTOPPED(st):
            # ssh suspended itself (~^Z): stop as a job would, wake it with us
            os.kill(os.getpid(), signal.SIGSTOP)
            try:
                child.send_signal(signal.SIGCONT)
            except OSError:
                pass
            continue
        break
    rc = -os.WTERMSIG(st) if os.WIFSIGNALED(st) else os.WEXITSTATUS(st)
    if rc < 0:
        result, why, code = "signal %d" % -rc, "ssh killed by signal %d" % -rc, 128 - rc
    else:
        result, code = "exit %d" % rc, rc
        why = {0: "ssh ended normally", 255: "ssh: connection failed or was cut (255)"}.get(rc, "the remote command's exit")
    if got.get("sig"):
        why += "; this side got signal %d" % got["sig"]
    clog("ssh-end", alias, route["kind"], (time.time() - t0) * 1000, result, why)
    return code


def probe_remembered_direct(want):
    """--probe-direct MACHINE (claude-fleet#1628): one handshake on each DIRECT
    route remembered for MACHINE; 0 (its name on stdout) when one answers, 1 when
    none does or nothing is remembered. No hub, no ssh: ~0.1–0.2 s."""
    cache = load_cache()
    entries = cache.get("machines") if isinstance(cache.get("machines"), dict) else {}
    ent = entries.get(want) or {}
    rows = [dict(r, order=i, ms=[], errors=[]) for i, r in enumerate(ent.get("routes") or [])
            if isinstance(r, dict) and r.get("kind") == "direct" and r.get("host")]
    if not rows:
        return 1
    rows = measure(rows, "", "", 1, env_num("FLEET_CONNECT_PROBE_TIMEOUT", 2.0))
    if rows and rows[0]["ms"]:
        print(rows[0]["name"])
        return 0
    return 1


# ── `fleet` (claude-fleet#1470): certificate → machine → route → ssh ───────

def load_login_module():
    """fleet-login.py beside this file, as a module: its cert_remaining(),
    renew() and cmd_login() are the certificate half of `fleet`."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-login.py")
    if not os.path.exists(path):
        die("fleet-login.py is not beside %s — reinstall: curl -fsSL <入口>/install | sh" % __file__)
    spec = importlib.util.spec_from_file_location("fleet_login", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fmt_left(secs):
    if secs == float("inf"):
        return "永久"
    h, m = int(secs // 3600), int(secs % 3600 // 60)
    return ("%dh%02dm" % (h, m)) if h else ("%dm" % m)


def ensure_cert(login, hub, verbose, force=False):
    """A certificate good for a while: keep, renew, or scan. Returns
    "kept" | "renewed" | "scanned"; exits through fleet-login.py's die() when
    the scan itself fails."""
    say = sys.stderr.write
    below = env_num("FLEET_RENEW_BELOW_SECS", 6 * 3600.0)
    left = login.cert_remaining()
    if left is not None and left > below and not force:
        if verbose:
            say("fleet · 证书还有 %s\n" % fmt_left(left))
        return "kept"
    rc = login.renew(hub, quiet=not verbose)
    if rc == 0:
        if not verbose:
            say("fleet · 证书已续期（12 小时）\n")
        return "renewed"
    if rc != login.NEEDS_SCAN and left is not None and left > 60:
        # The hub could not be reached (or refused the clock); the certificate
        # in hand still opens the door — go on with it.
        say("fleet · 续期没成功，先用手里还有 %s 的证书\n" % fmt_left(left))
        return "kept"
    if rc != login.NEEDS_SCAN:
        bad = fleet_tls.check(hub) if fleet_tls else (None, "")
        if bad[0] is False:  # this python cannot verify the hub (claude-fleet#2878)
            die("renewal failed and no valid certificate is left — %s" % bad[1], 1)
        die("renewal failed and no valid certificate is left — check the hub URL (%s) and the network" % hub, 1)
    say("fleet · 需要登录（第一次，或 7 天没用，或设备被吊销）\n")
    login.cmd_login(["--hub", hub])  # browser (or QR), polls, writes the certificate; dies on failure
    return "scanned"


def print_candidates(home):
    w = sys.stderr.write
    for c in home.get("candidates") or []:
        state = "在线" if c.get("online") else ("离线" if c.get("excluded") in ("offline", "", None) else c.get("excluded"))
        extra = []
        if c.get("sessions"):
            extra.append("%d 个会话" % c["sessions"])
        if c.get("cpu_busy") is not None:
            extra.append("CPU 繁忙 %.0f%%" % (c["cpu_busy"] * 100))
        if c.get("load_per_core") is not None:
            extra.append("负载 %.2f/核" % c["load_per_core"])
        if c.get("last"):
            extra.append("上次用的")
        w("  %s %s%s\n" % (pad(c.get("alias") or c.get("machine") or "?", 10), state,
                            ("（" + "，".join(extra) + "）") if extra else ""))


def pick_json(m, info, reason=""):
    """--pick's one line (claude-fleet#1484): the machine `fleet` would enter,
    and every machine the person may reach — alias + hostname — so a caller
    can label rows the way the hub does without a second question."""
    machines = [{"alias": x.get("alias") or x.get("hostname") or "", "hostname": x.get("hostname") or ""}
                for x in (info or {}).get("machines") or [] if isinstance(x, dict)]
    out = {"machine": (m or {}).get("alias") or (m or {}).get("hostname") or "",
           "hostname": (m or {}).get("hostname") or "", "reason": reason or "",
           "login": machine_login(m, info), "machines": machines}
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return 0


def pick_named(want, hub, token):
    """--pick MACHINE: the name against the hub's route list (the snippet
    `fleet login` wrote when the hub is silent); unknown → exit 1, naming the
    machines there are."""
    info = None
    try:
        info = fetch_routes(hub, token)
    except (Refused, OSError, ValueError) as e:
        try:
            with open(ssh_config_snippet_path()) as f:
                info = parse_ssh_config_snippet(f.read())
            if getattr(e, "code", "") == "principal_mismatch":
                sys.stderr.write("fleet · %s；先按 %s 里的机器\n" % (e, ssh_config_snippet_path()))
            else:
                sys.stderr.write("fleet · 入口连不上（%s%s），按 %s 里的机器\n" % (e, tls_hint(e), ssh_config_snippet_path()))
        except OSError:
            die("hub: %s" % e, 1)
    machines = info.get("machines") or []
    m = pick_machine(machines, want, None)
    if m is None:
        names = ", ".join(str(x.get("alias") or x.get("hostname")) for x in machines) or "（无）"
        die("没有叫 %s 的机器；你能连：%s" % (want, names), 1)
    return pick_json(m, info, "named")


def enter(want, hub, token, verbose, retest, print_only, ssh_args, ssh_opts=(), pick_only=False):
    if not hub and pick_only:
        return pick_local(want)
    if not hub:
        die("no hub URL: run the installer (curl -fsSL <入口>/install | sh) or `fleet login --hub <入口地址>` once")
    hub = hub.rstrip("/")
    if not token:
        login = load_login_module()
        ensure_cert(login, hub, verbose)
    if want:
        if pick_only:
            return pick_named(want, hub, token)
        return connect(want, hub, token, verbose, retest, print_only, ssh_args, ssh_opts=ssh_opts)
    cache = load_cache()
    for attempt in (1, 2):
        try:
            home = fetch_home(hub, token, cache.get("last"))
            break
        except Refused as e:
            clog("home", cache.get("last") or "", "-", "", e.code or ("http %d" % e.status if e.status else "refused"), str(e))
            if e.code == "opening":
                # The hub is opening this person's first login (issue #2069):
                # nothing to enter yet, and nothing to ask anyone for.
                sys.stderr.write("fleet · %s，稍后再运行 fleet\n" % (e.body.get("error") or "正在为你开机器，约 1 分钟"))
                sys.exit(1)
            if e.code == "no_machine_online":
                sys.stderr.write("fleet · %s\n" % (e.body.get("error") or "你的机器都不在线"))
                print_candidates(e.body.get("home") or {})
                sys.exit(1)
            if e.status == 401 and token and attempt == 1:
                # A viewer token the hub no longer knows — an old identity
                # (claude-fleet#2262) — must not stand in for this person:
                # drop it and log in as them.
                login = load_login_module()
                if os.environ.get("FLEET_HUB_TOKEN"):
                    sys.stderr.write("fleet · 环境变量 FLEET_HUB_TOKEN 是入口已不认的旧令牌 — 从 shell 配置里删掉它（这次先不用它）\n")
                elif login.drop_hub_token():
                    sys.stderr.write("fleet · 清掉了本机一个入口已不认的旧令牌（hub.json 里的 token）\n")
                token = ""
                ensure_cert(login, hub, verbose)
                continue
            if e.code == "device_revoked" and attempt == 1 and not token:
                # The certificate in hand is a revoked device's: scan again,
                # which registers this computer afresh, then ask once more.
                sys.stderr.write("fleet · 这台设备已被吊销，需要重新登录\n")
                ensure_cert(load_login_module(), hub, verbose, force=True)
                continue
            if e.code == "principal_mismatch":
                sys.stderr.write("fleet · %s；先按上次的记录直连\n" % e)
            else:
                sys.stderr.write("fleet · 入口没有给出机器（%s），按上次的记录直连\n" % e)
            if pick_only:
                return pick_named(cache.get("last") or "", hub, token) if cache.get("last") else pick_json(None, None, "hub: %s" % e)
            return connect(None, hub, token, verbose, retest, print_only, ssh_args, ssh_opts=ssh_opts)
        except (OSError, ValueError) as e:
            clog("home", cache.get("last") or "", "-", "", "unreachable", "%s%s" % (e, tls_hint(e)))
            sys.stderr.write("fleet · 入口连不上（%s%s），按上次的记录直连\n" % (e, tls_hint(e)))
            if pick_only:
                return pick_named(cache.get("last") or "", hub, token) if cache.get("last") else pick_json(None, None, "hub: %s" % e)
            return connect(None, hub, token, verbose, retest, print_only, ssh_args, ssh_opts=ssh_opts)
    m = home.get("machine") or {}
    name = m.get("alias") or m.get("hostname")
    if not name:
        sys.stderr.write("fleet · %s\n" % (home.get("reason") or "你的机器都不在线"))
        print_candidates(home)
        sys.exit(1)
    # the newcomer's view says where, not who chose (claude-fleet#2347)
    said = "连到" if load_login_module().newcomer() else "入口选了"
    # the client's start (--pick) on a terminal says nothing here (issue #2743):
    # its bar names the machine at once, and the line was all that stayed on the
    # person's terminal after ⌘Q
    if not (pick_only and sys.stderr.isatty()) or verbose:
        sys.stderr.write("fleet · %s %s（%s）\n" % (said, name, home.get("reason", "")))
    if verbose:
        print_candidates(home)
    if pick_only:
        cache["last"] = name
        save_cache(cache)
        return pick_json(m, home, home.get("reason", ""))
    return connect(name, hub, token, verbose, retest, print_only, ssh_args, info=home, ssh_opts=ssh_opts)


CERT_WARN_UNDER = 3600  # the doctor's cert row WARNs inside the certificate's last hour


def cert_check(hub, timeout=6):
    """--cert-check: (verdict, text) for the doctor's `cert` row, or None
    when there is no certificate here."""
    _, cert = cert_paths()
    if not os.path.exists(cert):
        return None
    try:
        out = subprocess.run(["ssh-keygen", "-L", "-f", cert], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return "FAIL", "%s 读不出来（ssh-keygen -L）— 跑 `fleet login`" % cert
    names, inp = [], False
    for line in out.splitlines():  # "Principals:" then one name a line, until the next "Key: value"
        t = line.strip()
        if t.startswith("Principals:"):
            inp = True
        elif inp and t and ":" not in t:
            names.append(t)
        elif inp:
            break
    principals = ",".join(names) or "无"
    vm = re.search(r"Valid: from \S+ to (\S+)", out)
    until, left = (vm.group(1) if vm else ("永久" if "Valid: forever" in out else "?")), None
    if vm:
        try:
            left = time.mktime(time.strptime(vm.group(1), "%Y-%m-%dT%H:%M:%S")) - time.time()
        except ValueError:
            left = None
    what = "principal %s · 有效至 %s" % (principals, until)
    if left is not None and left <= 0:
        return "FAIL", "%s（已过期）— 跑 `fleet login renew`" % what
    # Inside its last hour (claude-fleet#2630): a running client's keeper renews it
    # by now (#2112); still this close means no client renewed it.
    if left is not None and left < CERT_WARN_UNDER:
        return "WARN", "%s（剩 %d 分钟）— 开着的客户端会自动续；没开客户端就跑 `fleet login renew`" % (what, max(1, int(left // 60)))
    if not hub:
        return "PASS", "%s · 没有入口，未探" % what
    try:
        fetch_routes(hub.rstrip("/"), "", timeout=timeout)
    except Refused as e:
        return "FAIL", "%s · %s" % (what, e)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        return "WARN", "%s · 入口连不上，未验证（%s%s）" % (what, e, tls_hint(e))
    return "PASS", "%s · 入口接受" % what


def main(argv):
    import argparse
    ssh_args = []
    if "--" in argv:
        i = argv.index("--")
        argv, ssh_args = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(prog="fleet connect", description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("machine", nargs="?", help="alias or hostname (default: last used, else the hub's first)")
    ap.add_argument("--proxy", metavar="MACHINE",
                    help="relay stdin/stdout to MACHINE's sshd through the hub (for ssh's ProxyCommand)")
    ap.add_argument("--enter", action="store_true",
                    help="`fleet`: certificate (renew or scan), the hub's machine pick, then connect")
    ap.add_argument("--hub", help="the hub's URL (default: FLEET_HUB_URL, then hub.json)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the measurement table and the choice")
    ap.add_argument("--retest", action="store_true", help="measure again even if a recent choice is remembered")
    ap.add_argument("--route", metavar="ROUTE",
                    help="pin MACHINE (default: the one used last) to ROUTE and remember it — auto · relay · "
                         "direct · tailscale · a route name · host[:port] (`fleet route`, claude-fleet#2886)")
    ap.add_argument("--print", dest="print_only", action="store_true", help="print the ssh command, don't run it")
    ap.add_argument("-o", "--ssh-option", dest="ssh_opts", action="append", default=[], metavar="KEY=VALUE",
                    help="an ssh option placed before the host (repeatable): ControlPath=…, RequestTTY=force, …")
    ap.add_argument("--probe-direct", metavar="MACHINE",
                    help="one handshake on MACHINE's remembered direct routes; exit 0 when one answers (the shell)")
    ap.add_argument("--pick", action="store_true",
                    help="certificate + the hub's machine pick as one JSON line; no measuring, no ssh (the shell)")
    ap.add_argument("--cert-check", action="store_true",
                    help="the doctor's cert row: principals, validity, and whether the hub accepts it")
    ap.add_argument("--tls-check", action="store_true",
                    help="the doctor's tls row: can THIS python verify the hub's certificate (claude-fleet#2878)")
    ap.add_argument("--principal-hint", action="store_true",
                    help="a hub refusal on stdin → the person's words for a principal mismatch (exit 1: not one)")
    a = ap.parse_args(argv)
    if a.principal_hint:
        hint = principal_hint(sys.stdin.read())
        if hint:
            print(hint)
        return 0 if hint else 1
    if a.probe_direct:
        return probe_remembered_direct(a.probe_direct)
    if os.environ.get("FLEET_CONNECT_RETEST") == "1":
        a.retest = True
    elif os.environ.get("FLEET_CONNECT_RETEST") == "last" and not a.retest:
        a.retest = "last"  # a reconnect: the remembered route first, of any age (claude-fleet#2886)
    if a.route is not None:
        if not PIN_RE.match(a.route):
            die("--route %s: auto · relay · direct · tailscale · a route name · host[:port]" % a.route)
        target = a.machine or ("" if a.pick else load_cache().get("last") or "")
        if target:
            save_pin(target, a.route)
        elif not a.pick:
            die("--route: name the machine (fleet connect <machine> --route %s)" % a.route)
    conf = load_hub_conf()
    # The address lives in fleet.conf (issue #1623); hub.json keeps the token, and
    # its old "url" is read for one version.
    hub = a.hub or os.environ.get("FLEET_HUB_URL") or machine_conf_hub() or conf.get("url") or ""
    token = os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or ""
    if a.cert_check:
        r = cert_check(a.hub or os.environ.get("FLEET_HUB_URL") or machine_conf_hub() or conf.get("url") or "")
        if r is None:
            return 3
        print("%s\t%s" % r)
        return 0
    if a.tls_check:
        # no hub here, or no fleet_tls beside (an older mixed install): no row
        if not hub.startswith("https://") or not fleet_tls:
            return 3
        ok, text = fleet_tls.check(hub)
        print("%s\t%s" % ({True: "PASS", False: "FAIL", None: "WARN"}[ok], text))
        return 0
    if a.proxy:
        if not hub:
            die("no hub URL: pass --hub, set FLEET_HUB_URL, or run `fleet login --hub <入口地址>` once")
        return proxy(a.proxy, hub, token)
    if not hub and not (a.enter or a.pick) and is_local_name(a.machine) \
            and not os.path.exists(ssh_config_snippet_path()):
        # No hub and no remembered routes (claude-fleet#1712): the one machine is
        # this one, and its route is `local` — the client attaches here, no ssh.
        m = local_machine()
        if a.print_only:
            sys.stdout.write("local %s\n" % m["alias"])
            return 0
        sys.stderr.write("fleet connect · %s 是本机（没有入口）：不用 ssh，敲 fleet 开客户端\n" % m["alias"])
        return 0
    if a.pick and a.route is not None and not a.machine:
        # the machine is the hub's pick: pinned once it is known
        rc = enter(None, hub, token, a.verbose, a.retest, a.print_only, ssh_args, a.ssh_opts, True)
        if rc == 0 and load_cache().get("last"):
            save_pin(load_cache()["last"], a.route)
        return rc
    if a.pick or a.print_only:
        if a.enter or a.pick:
            return enter(a.machine, hub, token, a.verbose, a.retest, a.print_only, ssh_args, a.ssh_opts, a.pick)
        return connect(a.machine, hub.rstrip("/"), token, a.verbose, a.retest, a.print_only, ssh_args, ssh_opts=a.ssh_opts)
    if a.enter:
        return debug_after(lambda: enter(a.machine, hub, token, a.verbose, a.retest, False, ssh_args, a.ssh_opts, False))
    return debug_after(lambda: connect(a.machine, hub.rstrip("/"), token, a.verbose, a.retest, False, ssh_args,
                                       ssh_opts=a.ssh_opts))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
