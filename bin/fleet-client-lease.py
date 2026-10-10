#!/usr/bin/env python3
"""fleet-client-lease.py — a person's connected clients (issue #1715, EPIC #1710 C5;
several at once since #1932, EPIC #1906 C13).

  fleet-client-lease.py acquire [--lease ID] [--device D] [--terminal T]
  fleet-client-lease.py renew   --lease ID [--last-input EPOCH] [--viewing WID] [--where-file F]
                                          F = the where in use here: every renewal
                                          carries it, so a restarted hub knows the
                                          device again at once (#1995)
  fleet-client-lease.py input   --lease ID [--last-input EPOCH] [--viewing WID] [--where-file F]
                                          this client was typed into / tapped (≤ 1 per 5 s)
  fleet-client-lease.py release --lease ID
  fleet-client-lease.py get
  fleet-client-lease.py list              every client of yours (JSON: clients, primary)
  fleet-client-lease.py revoke  --target ID   disconnect one of them
  fleet-client-lease.py device [--save F] this client's device + terminal (TAB);
                                          --save writes the whole of it (JSON) to F
  fleet-client-lease.py where             the person's current client, as the hub
                                          holds it (JSON) — fleet-client-where.sh

An active acquire / renewal also carries the lease's ACTION KEY (issue #1717):
it is written, 0600, to FLEET_CLIENT_KEY_FILE (never printed) for
fleet-client-actions.py to check each action's signature with.

Talks to the hub's client lease (POST /v1/fleet/client), signed by this
device's connection certificate (`fleet-client@claude-fleet`) — or, with
FLEET_HUB_TOKEN / hub.json's token, by that token. Prints ONE line,
TAB-separated:

  <state>  <lease id>  <device>  <device asked to leave>  <reason>

state is active (the lease is ours), taken_over (ours is no longer held — the
third field says by which device, the fifth why: evicted = a client past the
limit asked this one, the least recently used, to leave; revoked = you
disconnected it from another client; empty = an older hub's takeover),
released, revoked, none (get: nobody holds one) or nohub. Every active answer
also writes the person's whole list — {"lease": ours, "primary", "clients"} — to
FLEET_CLIENT_LIST_FILE when that is set (the sidebar's 我的客户端 and the top
line's 「也在 iPhone 上打开」 read it). Exit 0 = the hub answered (or nohub: there is no hub here, and with no
hub there is no lease — the machine's one shell is already the only one);
1 = the hub could not be asked (network, a refusal) — the caller keeps what it
had. `where` alone answers a 401 with exit 4: the hub is up and refused this
machine's credential — scan again (`fleet login`), not a network fault (#2112).

Where the person is (issue #1716, EPIC #1710 C6) — read off the connection
itself, never a key or a name someone gave it:

  device/os/via  run on the computer itself: its own name and system, via local.
                 Over ssh, SSH_CONNECTION's source address: a tailnet address →
                 `tailscale whois` (device + system, via tailnet); a LAN address
                 → matched against the LAN endpoints tailnet devices report
                 (`tailscale status`, via lan); a public one → 未知设备, via public.
                 FLEET_CLIENT_DEVICE overrides the name.
  terminal       LC_TERMINAL[_VERSION] (macOS's ssh sends LC_*; iTerm2 sets it),
                 else TERM_PROGRAM[_VERSION]; else the terminal is asked
                 (XTVERSION, CSI > q, 200 ms); else 通用终端 (TERM).
  caps           on the computer itself: open_url show_file notify; for a
                 device at the far end of an ssh: link (a link to tap); an
                 iTerm2 adds iterm2.
  host           the machine this client runs on.
  node-hosted    the client on a managed machine (FLEET_NODE_HOSTED=1, issue
                 #2720): via node-hosted, caps link only — show / open print a
                 path or a link.

A test identity (issue #1931, EPIC #1906 C12) — a session's test or drill is
never the person: `--test-identity` / FLEET_CLIENT_IDENTITY=test asks at the
hub's test door (POST /v1/fleet/client/test) for a lease of its own that takes
nothing over and leaves where the person is untouched. Inside a session (its
worker credential or assertion in the environment, or FLEET_SEAT=worker) the
test identity is the default, and every request says so (X-Fleet-Worker): the
hub refuses such a request the person's lease (403, the reason on stderr). A
hub without the test door (404) is answered `nohub` — the person's lease is
never asked for instead. `where` always reads the person's.
"""
import importlib.util
import json
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:  # the ONE TLS context for the hub: every CA source this computer has (claude-fleet#2878)
    import fleet_tls
    fleet_tls.install()
except ImportError:
    fleet_tls = None

PATH = "/v1/fleet/client"
NAMESPACE = "fleet-client@claude-fleet"
HERE = os.path.dirname(os.path.realpath(__file__))


def connect_module():
    spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(HERE, "fleet-connect.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, timeout=timeout, check=True).stdout.decode().strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def tailnet_name(ip):
    """The tailnet's name for the device at ip, '' when tailscale does not know it."""
    for ts in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        out = run([ts, "whois", "--json", ip])
        if not out:
            continue
        try:
            node = json.loads(out).get("Node") or {}
        except ValueError:
            continue
        name = node.get("ComputedName") or (node.get("Hostinfo") or {}).get("Hostname") or node.get("Name") or ""
        return name.split(".", 1)[0]
    return ""


def os_word(o):
    o = (o or "").strip()
    return {"darwin": "macOS", "macos": "macOS", "ios": "iOS", "ipados": "iPadOS", "linux": "Linux",
            "windows": "Windows", "android": "Android", "freebsd": "FreeBSD"}.get(o.lower(), o)


def tailscale_json(args):
    for ts in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        out = run([ts] + args)
        if not out:
            continue
        try:
            return json.loads(out)
        except ValueError:
            continue
    return None


def ip_kind(ip):
    """tailnet, lan or public."""
    import ipaddress
    try:
        a = ipaddress.ip_address(ip.split("%", 1)[0])
    except ValueError:
        return "public"
    if a.version == 4 and a in ipaddress.ip_network("100.64.0.0/10"):
        return "tailnet"
    if a.version == 6 and a in ipaddress.ip_network("fd7a:115c:a1e0::/48"):
        return "tailnet"
    # the LAN ranges by name: is_private also holds the documentation and
    # benchmark ranges, which reach a machine only from outside
    lan = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
           "fc00::/7", "fe80::/10", "::1/128")
    if any(a in ipaddress.ip_network(n) for n in lan if ipaddress.ip_network(n).version == a.version):
        return "lan"
    return "public"


def tailnet_who(ip):
    """(device, os) the tailnet says is at ip; ('', '') when it does not know."""
    d = tailscale_json(["whois", "--json", ip]) or {}
    node = d.get("Node") or {}
    name = node.get("ComputedName") or (node.get("Hostinfo") or {}).get("Hostname") or node.get("Name") or ""
    return name.split(".", 1)[0], os_word((node.get("Hostinfo") or {}).get("OS") or "")


def tailnet_name(ip):
    return tailnet_who(ip)[0]


def endpoint_host(ep):
    ep = ep.strip()
    if ep.startswith("["):
        return ep[1:].split("]", 1)[0]
    return ep.rsplit(":", 1)[0] if ep.count(":") == 1 else ep


def lan_who(ip):
    """(device, os) of the tailnet device that reports ip among its LAN
    endpoints; ('', '') when none does."""
    st = tailscale_json(["status", "--json"]) or {}
    peers = list((st.get("Peer") or {}).values())
    if st.get("Self"):
        peers.append(st["Self"])
    for p in peers:
        eps = list(p.get("Addrs") or []) + [p.get("CurAddr") or ""]
        if any(e and endpoint_host(e) == ip for e in eps):
            name = p.get("HostName") or (p.get("DNSName") or "").split(".", 1)[0]
            return name.split(".", 1)[0], os_word(p.get("OS") or "")
    return "", ""


def this_host():
    me = platform.node().split(".", 1)[0]
    for a in (os.environ.get("FLEET_NODE_ALIASES") or "").split():
        if a.startswith(me + "="):
            return a.split("=", 1)[1]
    return me


def xtversion(timeout=0.2):
    """The terminal's own name (XTVERSION, CSI > q), '' when it does not say.
    A DA1 asked right after bounds the wait: every terminal answers that one."""
    if os.environ.get("FLEET_CLIENT_XTVERSION", "1") == "0" or os.environ.get("TMUX"):
        return ""  # inside tmux it is tmux that would answer
    import select
    import termios
    try:
        fd = os.open(os.environ.get("FLEET_CLIENT_TTY") or "/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return ""
    old = None
    try:
        try:
            old = termios.tcgetattr(fd)
            new = termios.tcgetattr(fd)
            new[3] &= ~(termios.ICANON | termios.ECHO)
            new[6][termios.VMIN], new[6][termios.VTIME] = 0, 0
            termios.tcsetattr(fd, termios.TCSANOW, new)
        except termios.error:
            old = None
        os.write(fd, b"\033[>q\033[c")
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], max(0.0, end - time.time()))
            if not r:
                break
            chunk = os.read(fd, 256)
            if not chunk:
                break
            buf += chunk
            if b"\033[?" in buf and buf.rstrip().endswith(b"c"):
                break
        txt = buf.decode("utf-8", "replace")
        i = txt.find("\033P>|")
        if i < 0:
            return ""
        j = txt.find("\033\\", i)
        return txt[i + 4:j if j > 0 else None].strip()
    finally:
        if old is not None:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, old)
            except termios.error:
                pass
        os.close(fd)


def terminal(ask=False):
    for n, v in (("LC_TERMINAL", "LC_TERMINAL_VERSION"), ("TERM_PROGRAM", "TERM_PROGRAM_VERSION")):
        t = os.environ.get(n, "").strip()
        if t and t != "tmux":
            ver = os.environ.get(v, "").strip()
            return (t + " " + ver).strip()
    if ask:
        t = xtversion()
        if t:
            return t.replace("(", " ").replace(")", "").strip()
    t = os.environ.get("TERM", "").strip()
    return "通用终端" + ("（%s）" % t if t else "")


def where(ask=False):
    """The whole of where this client is: device os terminal via host caps."""
    conn = os.environ.get("SSH_CONNECTION", "").split()
    if conn:
        ip = conn[0]
        via = ip_kind(ip)
        dev = osw = ""
        if via == "tailnet":
            dev, osw = tailnet_who(ip)
        elif via == "lan":
            dev, osw = lan_who(ip)
        caps = ["link"]
    else:
        via, caps, osw = "local", ["open_url", "show_file", "notify"], os_word(platform.system())
        dev = run(["scutil", "--get", "ComputerName"]) if platform.system() == "Darwin" else ""
        dev = dev or platform.node().split(".", 1)[0]
    dev = os.environ.get("FLEET_CLIENT_DEVICE", "").strip() or dev or "未知设备"
    term = terminal(ask)
    if os.environ.get("FLEET_NODE_HOSTED", "").strip() == "1":
        # the client on a managed machine (#2720): no browser, no download of its
        # own — a link or a path printed is what it can do
        return {"device": dev, "os": osw, "terminal": term, "via": "node-hosted", "host": this_host(),
                "caps": ["link"]}
    if "iterm" in term.lower():
        caps.append("iterm2")
    return {"device": dev, "os": osw, "terminal": term, "via": via, "host": this_host(), "caps": caps}


def device():
    return where()["device"]


def in_session():
    """A Claude / Codex session's own process (fleet-session-wrap.sh mints the
    credential per launch) — never the person at their terminal."""
    return bool(os.environ.get("FLEET_WORKER_CRED", "").strip() or os.environ.get("FLEET_WORKER_ASSERT", "").strip()
                or os.environ.get("FLEET_SEAT", "").strip() == "worker")


def identity(flag):
    """test or person: the flag, else FLEET_CLIENT_IDENTITY, else test inside a
    session and the person outside one."""
    if flag:
        return "test"
    v = os.environ.get("FLEET_CLIENT_IDENTITY", "").strip().lower()
    if v in ("test", "person"):
        return v
    return "test" if in_session() else "person"


def out(state, lease="", holder="", took="", reason=""):
    print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in (state, lease, holder, took, reason)))


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-client-lease")
    ap.add_argument("action", choices=["acquire", "renew", "input", "release", "get", "list", "revoke", "device", "where"])
    ap.add_argument("--lease", default="")
    ap.add_argument("--device", default="")
    ap.add_argument("--terminal", default="")
    ap.add_argument("--save", default="")
    ap.add_argument("--where-file", default="")
    ap.add_argument("--test-identity", action="store_true")
    ap.add_argument("--last-input", type=int, default=0)
    ap.add_argument("--viewing", default="")
    ap.add_argument("--target", default="")
    a = ap.parse_args(argv)
    if a.action == "device":
        w = where(ask=True)
        if a.save:
            try:
                with open(a.save + ".tmp", "w") as f:
                    json.dump(w, f, ensure_ascii=False)
                os.replace(a.save + ".tmp", a.save)
            except OSError as e:
                sys.stderr.write("fleet-client-lease: %s\n" % e)
        print("%s\t%s" % (w["device"], w["terminal"]))
        return 0
    if a.action in ("renew", "input", "release") and not a.lease:
        sys.stderr.write("fleet-client-lease: %s needs --lease\n" % a.action)
        return 2
    fc = connect_module()
    conf = fc.load_hub_conf()
    hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or conf.get("url") or ""
    token = os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or ""
    if a.action == "where":
        return read_where(fc, hub, token)
    if not hub:
        out("nohub")
        return 0
    ident = identity(a.test_identity)
    path = PATH + "/test" if ident == "test" else PATH
    if a.action == "revoke" and not a.target:
        sys.stderr.write("fleet-client-lease: revoke needs --target\n")
        return 2
    body = {"action": a.action, "lease": a.lease}
    if a.action in ("renew", "input"):
        if a.last_input > 0:
            body["last_input"] = a.last_input
        body["viewing"] = a.viewing
    if a.action == "revoke":
        body["target"] = a.target
    if ident == "test":
        body["identity"] = "test"
    if a.action == "acquire" or (a.action in ("input", "renew") and a.where_file):
        w = None
        if a.where_file:
            try:
                with open(a.where_file) as f:
                    w = json.load(f)
            except (OSError, ValueError):
                w = None
        if not isinstance(w, dict):
            w = where() if a.action == "acquire" else {}
        for k in ("os", "via", "host", "caps"):
            if w.get(k):
                body[k] = w[k]
        if a.action == "acquire":
            body["device"] = a.device or w.get("device") or device()
            body["terminal"] = a.terminal or w.get("terminal") or terminal()
            body["version"] = run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"], 2)
        else:
            # input: another client of the same server typed into — the lease
            # says where that one is (#1932). renew: the one in use here, every
            # time — a hub that restarted re-adopts the lease by its id alone,
            # and this is how it learns the device again (#1995)
            for k in ("device", "terminal"):
                if w.get(k) and w[k] != "未知设备":
                    body[k] = w[k]
            if a.action == "renew":
                body["version"] = run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"], 2)
    headers = {"Content-Type": "application/json"}
    if in_session():
        # a session's request says so: the hub never hands it the person's lease
        headers["X-Fleet-Worker"] = os.environ.get("FLEET_WORKER_ASSERT", "").strip() or "session"
    if token:
        headers["Authorization"] = "Bearer " + token
    else:
        try:
            ts = int(time.time())
            cert, sig = fc.ssh_sign("fleet-client %d" % ts, NAMESPACE)
        except fc.Refused as e:
            sys.stderr.write("fleet-client-lease: %s\n" % e)
            return 1
        body.update(cert=cert, sig=sig, ts=ts)
    req = urllib.request.Request(hub.rstrip("/") + path, data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 8)) as r:
            d = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404 and a.action == "revoke":
            sys.stderr.write("fleet-client-lease: no such client (it may have gone already)\n")
            return 1
        if e.code == 404:
            # An older hub without the lease (or, for the test identity,
            # without its door): treat it as none — the client runs as it
            # always has, and the person's lease is never asked for instead.
            if ident == "test":
                sys.stderr.write("fleet-client-lease: this hub has no test identity yet — no lease taken\n")
            out("nohub")
            return 0
        why = ""
        try:
            why = (json.loads(e.read() or b"{}").get("error") or "").strip()
        except (OSError, ValueError, AttributeError):
            pass
        sys.stderr.write("fleet-client-lease: hub answered HTTP %d%s\n" % (e.code, (" — " + why) if why else ""))
        return 1
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet-client-lease: %s\n" % e)
        return 1
    if ident == "test" and d.get("identity") != "test":
        sys.stderr.write("fleet-client-lease: the hub did not answer as the test identity — refused\n")
        return 1
    save_key(d.get("action_key") or "")
    lease = d.get("lease") or {}
    if a.action == "list":
        print(json.dumps({"state": d.get("state") or "none", "primary": d.get("primary") or "",
                          "clients": d.get("clients") or []}, ensure_ascii=False))
        return 0
    if a.action in ("acquire", "renew", "input", "revoke") and d.get("state") in ("active", "revoked"):
        save_list(lease.get("id") if a.action != "revoke" else None, d)
    by = d.get("by") or {}
    gone = d.get("evicted") or d.get("took_over") or {}
    out(d.get("state") or "none", lease.get("id") or "", by.get("device") or lease.get("device") or "",
        gone.get("device") or "", d.get("reason") or "")
    return 0


def save_list(own, d):
    """The person's clients (issue #1932) to FLEET_CLIENT_LIST_FILE: ours (own,
    None = keep what the file says), the primary, every client — what the
    sidebar's 我的客户端 and the top line read, never the hub on each draw."""
    f = os.environ.get("FLEET_CLIENT_LIST_FILE") or ""
    if not f:
        return
    if own is None:
        try:
            with open(f) as fh:
                own = (json.load(fh) or {}).get("lease") or ""
        except (OSError, ValueError, AttributeError):
            own = ""
    rec = {"lease": own or "", "primary": d.get("primary") or "", "clients": d.get("clients") or [],
           "at": int(time.time())}
    try:
        with open(f + ".tmp", "w") as fh:
            json.dump(rec, fh, ensure_ascii=False)
        os.replace(f + ".tmp", f)
    except OSError as e:
        sys.stderr.write("fleet-client-lease: %s\n" % e)


def save_key(key):
    """The lease's action key (issue #1717), 0600 in FLEET_CLIENT_KEY_FILE —
    never printed, never on an argv: fleet-client-actions.py checks every
    action's signature with it."""
    f = os.environ.get("FLEET_CLIENT_KEY_FILE") or ""
    if not key or not f:
        return
    try:
        fd = os.open(f + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(key + "\n")
        os.replace(f + ".tmp", f)
    except OSError as e:
        sys.stderr.write("fleet-client-lease: %s\n" % e)


def node_env(key):
    """KEY's value in node.env — read, never sourced: it holds a credential.
    Separated (issue #1971) node.env is unreadable here: the hub URL + token
    pair becomes the credential proxy's hub broker (both, never one of them),
    any other key comes from node.pub.env."""
    d = os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")
    for name in ("node.env", "node.pub.env"):
        try:
            with open(os.path.join(d, name)) as f:
                if name == "node.pub.env" and key in ("CCQUOTA_TOKEN", "CCQUOTA_HUB_URL"):
                    return _node_broker(d)[key == "CCQUOTA_TOKEN"]
                for line in f:
                    if line.startswith(key + "="):
                        return line.split("=", 1)[1].strip().strip("\"'")
                return ""
        except OSError:
            continue
    return ""


def node_pair(hub=""):
    """(url, token) a node-token read goes to — ALWAYS a pair (issue #2665). A
    token is good only at the address it came with: the credential proxy's
    fcpn1. token at its loopback broker, never at the hub itself (the hub has
    never seen it: 401 unrecognised enrollment token). So: CCQUOTA_TOKEN in the
    environment with CCQUOTA_HUB_URL beside it (else hub); else node.env's token
    with its own URL (else hub); else, separated, the broker pair whole.
    ('', '') = no node token here."""
    tok = os.environ.get("CCQUOTA_TOKEN") or ""
    if tok:
        return (os.environ.get("CCQUOTA_HUB_URL") or hub or "").rstrip("/"), tok
    d = os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")
    try:
        vals = {}
        with open(os.path.join(d, "node.env")) as f:
            for line in f:
                k, eq, v = line.partition("=")
                if eq and k in ("CCQUOTA_TOKEN", "CCQUOTA_HUB_URL"):
                    vals.setdefault(k, v.strip().strip("\"'"))
        if vals.get("CCQUOTA_TOKEN"):
            return (vals.get("CCQUOTA_HUB_URL") or hub or "").rstrip("/"), vals["CCQUOTA_TOKEN"]
        return "", ""
    except OSError:
        pass
    if os.path.isfile(os.path.join(d, "node.pub.env")):
        u, t = _node_broker(d)
        if u and t:
            return u, t
    return "", ""


_BROKER = []


def _node_broker(d):
    """(broker url, fcpn1. token) — one mint per process; ('', '') when none."""
    if not _BROKER:
        pair = ("", "")
        if os.path.isfile(os.path.join(d, "credsep.json")):
            try:
                out = subprocess.run(["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                           "fleet-cred-proxy.sh"), "node-token"],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15).stdout
                u, t = out.strip().split("\t", 1)
                pair = (u.rstrip("/"), t)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        _BROKER.append(pair)
    return _BROKER[0]


def _http_why(e):
    """The hub's own words for an HTTPError: its JSON "error", else ''."""
    try:
        return (json.loads(e.read() or b"{}").get("error") or "").strip()
    except (OSError, ValueError, AttributeError):
        return ""


def read_where(fc, hub, token):
    """The person's current client — the primary — as the hub holds it, ONE JSON
    line: {"state": active|none|nohub, "lease": {...}, "clients": [...],
    "primary": id} (an older hub: no clients). A node asks with its own
    token (GET /v1/node/client — its owner's) at the address that token belongs
    to (node_pair, #2665); a client machine with its connection certificate (or
    hub token). A node token the hub refuses (401) is not the end: the
    certificate is asked next, and the answer carries "node_token": "refused:
    <the hub's words>" so the doctor can say the token is wrong (#2665).
    Exit 1 = the hub could not be asked · 4 = it answered 401 to every
    credential here (issue #2112) — stdout is then {"state": "refused", "why":
    <the hub's words>}."""
    nurl, ntok = node_pair(hub)
    hub = hub or nurl
    if not hub and not nurl:
        print(json.dumps({"state": "nohub"}))
        return 0
    tmo = float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 5)
    node_refused = ""

    def ask(req):
        with urllib.request.urlopen(req, timeout=tmo) as r:
            return json.loads(r.read() or b"{}")

    def failed(e, what):
        if isinstance(e, urllib.error.HTTPError):
            if e.code == 404:
                print(json.dumps({"state": "nohub"}))   # a hub without the lease
                return 0
            why = _http_why(e)
            sys.stderr.write("fleet-client-lease: hub answered HTTP %d%s (%s)\n"
                             % (e.code, (" — " + why) if why else "", what))
            if e.code == 401:
                # the hub is up and REFUSED this machine's credential (an orphaned
                # key id, an expired certificate) — not out of reach (issue #2112)
                rec = {"state": "refused", "why": why or "HTTP 401"}
                if node_refused:
                    rec["node_token"] = "refused: " + node_refused
                print(json.dumps(rec, ensure_ascii=False))
                return 4
            return 1
        sys.stderr.write("fleet-client-lease: %s\n" % e)
        return 1

    d = None
    if ntok and nurl:
        req = urllib.request.Request(nurl + "/v1/node/client", method="GET",
                                     headers={"Authorization": "Bearer " + ntok})
        try:
            d = ask(req)
        except urllib.error.HTTPError as e:
            if e.code != 401:
                return failed(e, "node token")
            node_refused = _http_why(e) or "HTTP 401"
            sys.stderr.write("fleet-client-lease: the hub refused the node token (%s) — asking with the "
                             "certificate\n" % node_refused)
        except (OSError, ValueError) as e:
            return failed(e, "node token")
    if d is None:
        if not hub:
            print(json.dumps({"state": "refused", "why": node_refused, "node_token": "refused: " + node_refused},
                             ensure_ascii=False))
            return 4
        body = {"action": "get"}
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        else:
            try:
                ts = int(time.time())
                cert, sig = fc.ssh_sign("fleet-client %d" % ts, NAMESPACE)
            except fc.Refused as e:
                sys.stderr.write("fleet-client-lease: %s\n" % e)
                if node_refused:
                    print(json.dumps({"state": "refused", "why": node_refused,
                                      "node_token": "refused: " + node_refused}, ensure_ascii=False))
                    return 4
                return 1
            body.update(cert=cert, sig=sig, ts=ts)
        req = urllib.request.Request(hub.rstrip("/") + PATH, data=json.dumps(body).encode(), method="POST",
                                     headers=headers)
        try:
            d = ask(req)
        except (urllib.error.HTTPError, OSError, ValueError) as e:
            return failed(e, "certificate" if not token else "hub token")
    rec = {"state": d.get("state") or "none", "lease": d.get("lease") or None,
           "clients": d.get("clients") or [], "primary": d.get("primary") or ""}
    if node_refused:
        rec["node_token"] = "refused: " + node_refused
    print(json.dumps(rec, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
