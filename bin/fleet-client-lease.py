#!/usr/bin/env python3
"""fleet-client-lease.py — one person, one connected client (issue #1715, EPIC #1710 C5).

  fleet-client-lease.py acquire [--lease ID] [--device D] [--terminal T]
  fleet-client-lease.py renew   --lease ID
  fleet-client-lease.py release --lease ID
  fleet-client-lease.py get
  fleet-client-lease.py device [--save F] this client's device + terminal (TAB);
                                          --save writes the whole of it (JSON) to F
  fleet-client-lease.py where             the person's current client, as the hub
                                          holds it (JSON) — fleet-client-where.sh

Talks to the hub's client lease (POST /v1/fleet/client), signed by this
device's connection certificate (`fleet-client@claude-fleet`) — or, with
FLEET_HUB_TOKEN / hub.json's token, by that token. Prints ONE line,
TAB-separated:

  <state>  <lease id>  <holder's device>  <device it took over from>

state is active (the lease is ours), taken_over (another client holds it — the
third field says which device), released, none (get: nobody holds one) or
nohub. Exit 0 = the hub answered (or nohub: there is no hub here, and with no
hub there is no lease — the machine's one shell is already the only one);
1 = the hub could not be asked (network, a refusal) — the caller keeps what it
had.

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
    if "iterm" in term.lower():
        caps.append("iterm2")
    return {"device": dev, "os": osw, "terminal": term, "via": via, "host": this_host(), "caps": caps}


def device():
    return where()["device"]


def out(state, lease="", holder="", took=""):
    print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in (state, lease, holder, took)))


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-client-lease")
    ap.add_argument("action", choices=["acquire", "renew", "release", "get", "device", "where"])
    ap.add_argument("--lease", default="")
    ap.add_argument("--device", default="")
    ap.add_argument("--terminal", default="")
    ap.add_argument("--save", default="")
    ap.add_argument("--where-file", default="")
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
    if a.action in ("renew", "release") and not a.lease:
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
    body = {"action": a.action, "lease": a.lease}
    if a.action == "acquire":
        w = None
        if a.where_file:
            try:
                with open(a.where_file) as f:
                    w = json.load(f)
            except (OSError, ValueError):
                w = None
        w = w if isinstance(w, dict) else where()
        for k in ("os", "via", "host", "caps"):
            if w.get(k):
                body[k] = w[k]
        body["device"] = a.device or w.get("device") or device()
        body["terminal"] = a.terminal or w.get("terminal") or terminal()
        body["version"] = run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"], 2)
    headers = {"Content-Type": "application/json"}
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
    req = urllib.request.Request(hub.rstrip("/") + PATH, data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 8)) as r:
            d = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            # An older hub without the lease: treat it as none — the client
            # runs as it always has.
            out("nohub")
            return 0
        sys.stderr.write("fleet-client-lease: hub answered HTTP %d\n" % e.code)
        return 1
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet-client-lease: %s\n" % e)
        return 1
    lease = d.get("lease") or {}
    by = d.get("by") or {}
    took = d.get("took_over") or {}
    out(d.get("state") or "none", lease.get("id") or "", by.get("device") or lease.get("device") or "",
        took.get("device") or "")
    return 0


def node_env(key):
    """KEY's value in node.env — read, never sourced: it holds a credential."""
    d = os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")
    try:
        with open(os.path.join(d, "node.env")) as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        pass
    return ""


def read_where(fc, hub, token):
    """The person's current client, as the hub holds it, ONE JSON line:
    {"state": active|none|nohub, "lease": {...}}. A node asks with its own
    token (GET /v1/node/client — its owner's); a client machine with its
    connection certificate (or hub token). Exit 1 = the hub could not be asked."""
    ntok = os.environ.get("CCQUOTA_TOKEN") or node_env("CCQUOTA_TOKEN")
    hub = hub or os.environ.get("CCQUOTA_HUB_URL") or node_env("CCQUOTA_HUB_URL")
    if not hub:
        print(json.dumps({"state": "nohub"}))
        return 0
    tmo = float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 5)
    if ntok:
        req = urllib.request.Request(hub.rstrip("/") + "/v1/node/client", method="GET",
                                     headers={"Authorization": "Bearer " + ntok})
    else:
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
                return 1
            body.update(cert=cert, sig=sig, ts=ts)
        req = urllib.request.Request(hub.rstrip("/") + PATH, data=json.dumps(body).encode(), method="POST",
                                     headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=tmo) as r:
            d = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(json.dumps({"state": "nohub"}))   # a hub without the lease
            return 0
        sys.stderr.write("fleet-client-lease: hub answered HTTP %d\n" % e.code)
        return 1
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet-client-lease: %s\n" % e)
        return 1
    print(json.dumps({"state": d.get("state") or "none", "lease": d.get("lease") or None}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
