#!/usr/bin/env python3
"""fleet-login.py — `fleet login`: scan once, get a 12-hour SSH certificate.

    fleet login [--hub URL] [--invert] [--no-include]
    fleet login renew [--hub URL] [--quiet] [--if-under SECS]
    fleet login status
    fleet login check
    fleet login hub [--hub URL]                  print the hub URL it would use
    fleet login node --out FILE [--hub URL] [--invert]
    fleet login node-pass --out FILE [--hub URL] [--quiet]

`bin/fleet` dispatches `fleet login` here. Logging in (claude-fleet#1412) is the device-code flow against the fleet hub
(tokenledger, CCQUOTA_FLEET=1):

  1. makes ~/.ssh/fleet-cert (ed25519, no passphrase) if it is not there —
     the private key never leaves this computer;
  2. POSTs the public half to <hub>/v1/fleet/login/start and draws the
     returned QR code here;
  3. you scan it with a phone (or open the link), sign in with GitHub, and
     confirm the code on the page;
  4. polls <hub>/v1/fleet/login/poll and writes
        ~/.ssh/fleet-cert-cert.pub   the certificate (12 hours)
        ~/.ssh/fleet-ssh-config      Host blocks for your machines
     and, once, appends to ~/.ssh/config (after everything already there,
     so your own entries keep winning):
        Match all
        Include ~/.ssh/fleet-ssh-config

That scan also REGISTERS this computer as a device (claude-fleet#1470): from
then on `renew` gets the next 12-hour certificate without a scan — it signs a
timestamp with the device key (ssh-keygen -Y sign) and POSTs it to
<hub>/v1/fleet/login/renew; the hub checks the signature against the key it
registered, that the device is not revoked and was used inside the last seven
days, and signs again. `fleet` (no argument) runs this for you before every
connection, so a scan is needed only after seven idle days or a revocation.

A renewal signs the SAME identity the device was registered under, so a hub
whose roster no longer names it (claude-fleet#2112: the 2026-10-04 move from the
old person:<name> ids to gh:<id>) renews happily and then refuses the new
certificate everywhere with 401 「its key id names no one this hub knows」.
So a 200 is checked once — the new certificate signs a `get` on the client
lease (POST /v1/fleet/client) — and that refusal (or 「not signed by this hub」)
is exit 3: scan again, not a renewal. A hub without the lease door, or one out
of reach for the check, leaves the renewal as it was. `--if-under SECS` renews
only when the certificate has less than SECS left (exit 0, nothing asked,
otherwise — and when there is no certificate at all): the client keeper's
hourly-margin call (fleet-shell.sh keeper), so a shell left open overnight never
reaches the 12-hour end.

`node` is the scan half of `fleet node join` (claude-fleet#1627): the same key,
start, QR, page and poll, with purpose=node — the page reads 「把 <机器名> 加为
节点」, and the confirmation returns this machine's node pass beside the
certificate. The pass (the hub's NodeJoinResponse JSON, a credential) goes to
FILE (0600) for fleet-node-join.sh --joined; it is never printed.

`node-pass` is 登录即登记 (claude-fleet#2212): no scan. A computer this login
already registered (the scan above) signs a timestamp with its device key and
POSTs it to <hub>/v1/fleet/login/node; the hub answers the device's node pass —
enrolled the first time as an untrusted, coordinate-only node, the same node
with a fresh token after (never a second one). The pass goes to FILE (0600),
for fleet-node-join.sh --joined, never printed. Exit 0 written · 3 this device
must scan (`fleet login`) first · 4 the hub offers no such door (an older hub)
or refuses this name (a machine it trusts already has it) — scan instead with
`fleet node join` · 1 anything else.

`check` prints the certificate's state (valid <seconds left> · expired · none)
and exits 0 only while it is valid. `status` is `ssh-keygen -L` on it.

The hub URL is remembered in ~/.config/claude-fleet/hub.json ({"url": …}, any
other key in it kept — `fleet connect` reads the same file), or set
FLEET_HUB_URL. Those paths are fixed: `fleet connect` (C7) reads them.

Exit: 0 certificate written · 1 refused/expired/denied (renew: the hub could
not be reached, or any other error) · 2 usage/config · 3 (renew only) this
device must scan again — not registered, revoked, or idle too long.
"""
import getpass
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
SSH_DIR = os.path.join(HOME, ".ssh")
KEY = os.path.join(SSH_DIR, "fleet-cert")
CERT = KEY + "-cert.pub"
SSH_CONFIG_SNIPPET = os.path.join(SSH_DIR, "fleet-ssh-config")
SSH_CONFIG = os.path.join(SSH_DIR, "config")
HUB_FILE = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "claude-fleet", "hub.json")
# The machine's ONE config file (issue #1623): the hub address lives there.
MACHINE_CONF = os.path.join(os.environ.get("FLEET_CONF_DIR") or os.path.dirname(HUB_FILE), "fleet.conf")
# A node's machine-to-machine ssh (claude-fleet#1719): the node pass lives in
# node.env; the peer key, the certificates and the machine list under peer/.
CONF_DIR = os.environ.get("FLEET_CONF_DIR") or os.path.dirname(HUB_FILE)
NODE_ENV = os.path.join(CONF_DIR, "node.env")
PEER_DIR = os.path.join(CONF_DIR, "peer")
MACHINES_FILE = os.path.join(PEER_DIR, "machines")
PEER_CERT_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-peer-cert.sh")
PEER_BEGIN = "# >>> machine-to-machine (claude-fleet#1719) >>>"
PEER_END = "# <<< machine-to-machine <<<"
INCLUDE_BEGIN = "# >>> fleet login (claude-fleet#1412) >>>"
INCLUDE_END = "# <<< fleet login <<<"
RENEW_PATH = "/v1/fleet/login/renew"
RENEW_NAMESPACE = "fleet-renew@claude-fleet"
# 登录即登记 (claude-fleet#2212): the device key buys the node pass.
LOGIN_NODE_PATH = "/v1/fleet/login/node"
LOGIN_NODE_NAMESPACE = "fleet-login-node@claude-fleet"
# Exit code: the hub has no login-node door (or refuses the name) — scan instead.
NO_DOOR = 4
# The renewal's check (claude-fleet#2112): the client lease, as fleet-client-lease.py asks it.
CLIENT_PATH = "/v1/fleet/client"
CLIENT_NAMESPACE = "fleet-client@claude-fleet"
# The hub's words for a certificate it will never accept, however often renewed
# (tokenledger/internal/api/ssh_relay.go verifySSHRelayCert).
RESCAN_REFUSALS = ("names no one this hub knows", "not signed by this hub")
# Exit code: this device has to scan again.
NEEDS_SCAN = 3


def show(*a):
    """What the scan shows the person — the code, the QR, the link, the ✓
    lines — goes to stderr: `fleet --pick` (fleet-shell.sh) captures stdout
    for its one JSON line, and a scan printed there vanished (claude-fleet#2090)."""
    print(*a, file=sys.stderr, flush=True)


def die(msg, code=2):
    print("fleet login: " + msg, file=sys.stderr)
    sys.exit(code)


def machine_conf_hub():
    """FLEET_HUB_URL from the machine's ONE config file (issue #1623) ('' if none)."""
    url = ""
    try:
        with open(MACHINE_CONF) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?FLEET_HUB_URL=(.*)$", line)
                if m:
                    url = m.group(1).split(" #")[0].strip().strip("\"'")
    except OSError:
        pass
    return url


def hub_url(arg):
    url = arg or os.environ.get("FLEET_HUB_URL", "")
    if not url:
        url = machine_conf_hub()
    if not url:
        url = str(read_hub_file().get("url") or "")   # the old place, read one version
    if not url:
        die("no hub URL: pass --hub https://<入口地址> once (it is remembered)")
    if not url.startswith(("https://", "http://")):
        die("hub URL must start with https://")
    return url.rstrip("/")


def read_hub_file():
    try:
        with open(HUB_FILE) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def remember_hub(url):
    """The address goes to fleet.conf's [common] (issue #1623) — written in ONE
    place (FLEET_HOST is left as it is, issue #1806); hub.json is left to its token."""
    if machine_conf_hub() == url:
        return
    tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-conf.sh")
    if os.path.exists(tool):
        env = dict(os.environ, FLEET_CONF_DIR=os.path.dirname(MACHINE_CONF))
        r = subprocess.run(["bash", tool, "set-hub", url], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode == 0:
            return
        print("fleet login: " + (r.stderr.strip() or "fleet-conf.sh set-hub failed")
              + " — remembering it in hub.json", file=sys.stderr)
    d = read_hub_file()  # keep a token (or anything else) already there
    d["url"] = url
    os.makedirs(os.path.dirname(HUB_FILE), exist_ok=True)
    write_file(HUB_FILE, json.dumps(d, indent=2) + "\n", 0o600)


def post(url, body, timeout=20, headers=None):
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def device_name():
    """This computer's short hostname — the device record's display name."""
    try:
        return socket.gethostname().split(".")[0][:64]
    except OSError:
        return ""


def ensure_key():
    os.makedirs(SSH_DIR, mode=0o700, exist_ok=True)
    if not os.path.exists(KEY):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "fleet-login", "-f", KEY],
                       check=True)
    with open(KEY + ".pub") as f:
        return f.read().strip()


def draw_qr(rows, invert):
    """Two QR rows per text line with half blocks, plus a 2-module quiet zone.
    Default draws LIGHT modules as ink — right for a dark terminal; --invert
    for a light one."""
    if not rows:
        return
    n = len(rows[0])
    pad = 2
    grid = [[False] * (n + 2 * pad) for _ in range(pad)]
    for r in rows:
        grid.append([False] * pad + [c == "#" for c in r] + [False] * pad)
    grid += [[False] * (n + 2 * pad) for _ in range(pad)]
    if len(grid) % 2:
        grid.append([False] * (n + 2 * pad))
    for y in range(0, len(grid), 2):
        line = []
        for top, bot in zip(grid[y], grid[y + 1]):
            # ink = a light module (dark terminal) or a dark one (--invert)
            t, b = (top, bot) if invert else (not top, not bot)
            line.append("█" if t and b else "▀" if t else "▄" if b else " ")
        show("  " + "".join(line))


def write_file(path, text, mode):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def ensure_include():
    try:
        with open(SSH_CONFIG) as f:
            cur = f.read()
    except FileNotFoundError:
        cur = ""
    if INCLUDE_BEGIN in cur:
        return False
    block = "%s\nMatch all\nInclude ~/.ssh/fleet-ssh-config\n%s\n" % (INCLUDE_BEGIN, INCLUDE_END)
    sep = "" if not cur or cur.endswith("\n") else "\n"
    write_file(SSH_CONFIG, cur + sep + ("\n" if cur else "") + block, 0o600)
    return True


def cert_machines(res):
    """[(hostname, alias)] from a CertResponse: its `machines` (claude-fleet#1719),
    else — a hub older than that — each machine's first Host line
    (`Host <alias> fleet-<alias> …`), the alias standing for the hostname."""
    tok = re.compile(r"^[A-Za-z0-9._:][A-Za-z0-9._:-]*$")
    out = []
    for m in res.get("machines") or []:
        h, a = str(m.get("hostname", "")), str(m.get("alias", "") or m.get("hostname", ""))
        if tok.match(h) and tok.match(a):
            out.append((h, a))
    if out or res.get("machines") is not None:
        return out
    for line in (res.get("ssh_config") or "").splitlines():
        w = line.split()
        if len(w) >= 3 and w[0] == "Host" and w[2] == "fleet-" + w[1] and tok.match(w[1]):
            out.append((w[1], w[1]))
    return out


def self_names():
    names = set()
    for n in (socket.gethostname(), os.uname().nodename):
        if n:
            names.add(n.split(".")[0].lower())
    return names


def tilde(path):
    return "~" + path[len(HOME):] if path.startswith(HOME + "/") else path


def peer_section(machines):
    """One Match per OTHER machine (claude-fleet#1719): whatever name ssh is
    given for it — the alias, a route of it (`m4-lan`), the hub's hostname,
    `fleet-<alias>…` — asks fleet-peer-cert.sh for a five-minute certificate
    first (exit 0 = there is one) and offers it. The certificate's file is keyed
    on the hostname, so every name shares one (the script resolves them
    through peer/machines)."""
    me = self_names()
    blocks = []
    for host, alias in machines:
        if host.lower() in me or alias.lower() in me:
            continue
        pats = []
        for n in (alias, host, "fleet-" + alias):
            for p in (n, n + "-*"):
                if p not in pats:
                    pats.append(p)
        blocks.append("Match originalhost %s exec \"'%s' %s view >/dev/null 2>&1\"\n"
                      "  IdentityFile ~/.ssh/fleet-peer\n"
                      "  CertificateFile \"%s\"\n"
                      % (",".join(pats), PEER_CERT_SH, host, tilde(os.path.join(PEER_DIR, host + ".view-cert.pub"))))
    if not blocks:
        return ""
    return ("%s\n# This machine is a hub node: reaching another machine asks the hub for a\n"
            "# five-minute certificate first (fleet-peer-cert.sh), never a standing key.\n%s%s\n"
            % (PEER_BEGIN, "".join(blocks), PEER_END))


def adopt_handwritten():
    """Take over a hand-written `Match … exec "…fleet-peer-cert.sh …"` block in
    ~/.ssh/config (the one m5 carried before claude-fleet#1719), with the
    comment lines right above it: the generated section now does that job.
    The old file is kept beside it. Returns the backup's path, or ""."""
    try:
        with open(SSH_CONFIG) as f:
            lines = f.read().splitlines(True)
    except OSError:
        return ""
    keep, drop, i, inside = [], False, 0, False
    while i < len(lines):
        ln = lines[i]
        if ln.startswith(INCLUDE_BEGIN):
            inside = True
        if ln.startswith(INCLUDE_END):
            inside = False
        if not inside and re.match(r"\s*Match\s.*\bexec\s.*fleet-peer-cert\.sh", ln):
            while keep and keep[-1].lstrip().startswith("#"):
                keep.pop()
            i += 1
            while i < len(lines) and lines[i].strip() and lines[i][:1] in " \t":
                i += 1
            while i < len(lines) and not lines[i].strip() and (not keep or not keep[-1].strip()):
                i += 1
            drop = True
            continue
        keep.append(ln)
        i += 1
    if not drop:
        return ""
    bak = SSH_CONFIG + ".fleet-bak-" + time.strftime("%Y%m%d%H%M%S")
    write_file(bak, "".join(lines), 0o600)
    write_file(SSH_CONFIG, "".join(keep), 0o600)
    return bak


# What write_cert did beyond the certificate, for the caller to say.
NOTES = []


def write_cert(res, include):
    """The certificate and the ssh snippet from a CertResponse; the Include once.
    On a hub node (a node pass in this answer, or node.env already here) the
    snippet also gets the machine-to-machine Match blocks (claude-fleet#1719)."""
    write_file(CERT, res["certificate"], 0o644)
    snippet = res["ssh_config"]
    machines = cert_machines(res)
    if machines:
        os.makedirs(PEER_DIR, mode=0o700, exist_ok=True)
        write_file(MACHINES_FILE, "".join("%s %s\n" % m for m in machines), 0o644)
    peer = peer_section(machines) if (res.get("node") or os.path.exists(NODE_ENV)) else ""
    if peer:
        snippet = snippet.rstrip("\n") + "\n\n" + peer
    write_file(SSH_CONFIG_SNIPPET, snippet, 0o644)
    if peer and include:
        # before the Include goes in, so the backup is the file as it was
        bak = adopt_handwritten()
        if bak:
            NOTES.append("✓ ~/.ssh/config 里手写的机器间证书段已由 %s 接管（原文件备份在 %s）" % (tilde(SSH_CONFIG_SNIPPET), tilde(bak)))
    added = include and ensure_include()
    if peer:
        NOTES.append("✓ 到其它机器的 ssh 段已写好（%d 台，每次连接先向入口要 5 分钟证书）" % peer.count("\nMatch "))
    return added


def cert_remaining(cert=CERT):
    """Seconds this certificate is still valid for (negative: expired), or
    None when there is no readable certificate. Read through `ssh-keygen -L`
    — the one parser that is on every machine `ssh` is on."""
    if not os.path.exists(cert):
        return None
    try:
        out = subprocess.run(["ssh-keygen", "-L", "-f", cert], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    m = re.search(r"Valid: from (\S+) to (\S+)", out)
    if not m:
        return float("inf") if "Valid: forever" in out else None
    try:
        until = time.mktime(time.strptime(m.group(2), "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None
    return until - time.time()


def cert_refused(hub):
    """The hub's refusal of the certificate on disk, or "" when it took it (or
    could not say: no lease door, out of reach). One signed `get` on the client
    lease — read-only, the person's lease untouched."""
    ts = int(time.time())
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", KEY, "-n", CLIENT_NAMESPACE],
                             input=("fleet-client %d" % ts).encode(), capture_output=True, check=True).stdout.decode()
        with open(CERT) as f:
            cert = f.read().strip()
        code, res = post(hub + CLIENT_PATH, {"action": "get", "cert": cert, "sig": sig, "ts": ts}, timeout=8)
    except (OSError, subprocess.CalledProcessError, urllib.error.URLError, ValueError):
        return ""
    if code != 401:
        return ""
    why = str(res.get("error") or "")
    return why if any(r in why for r in RESCAN_REFUSALS) else ""


def renew(hub, quiet=False, include=True):
    """Renew by the device key. Returns 0 renewed · NEEDS_SCAN (3) when the hub
    says this device must scan again · 1 for anything else (hub unreachable,
    a refused clock, no key yet)."""
    say = (lambda *_: None) if quiet else (lambda m: print("fleet login: " + m, file=sys.stderr))
    if not (os.path.exists(KEY) and os.path.exists(KEY + ".pub")):
        say("no device key yet (%s) — scan to sign in" % KEY)
        return NEEDS_SCAN
    with open(KEY + ".pub") as f:
        pub = f.read().strip()
    ts = int(time.time())
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", KEY, "-n", RENEW_NAMESPACE],
                             input=("fleet-renew %d" % ts).encode(), capture_output=True, check=True).stdout.decode()
    except (OSError, subprocess.CalledProcessError) as e:
        say("ssh-keygen -Y sign failed: %s" % e)
        return 1
    try:
        code, res = post(hub + RENEW_PATH, {"public_key": pub, "ts": ts, "sig": sig, "device_name": device_name()})
    except (urllib.error.URLError, OSError) as e:
        say("hub unreachable (%s)" % getattr(e, "reason", e))
        return 1
    if code == 200:
        added = write_cert(res, include)
        why = cert_refused(hub)
        if why:
            # renewed, and still refused: the identity it renews is gone (#2112)
            say("续期拿到了证书，但入口不认它（%s）— 需要重新扫码：fleet login" % why)
            return NEEDS_SCAN
        say("✓ 证书已续期（%s 前有效，账号 %s）%s" % (res.get("valid_before", "?"), ",".join(res.get("principals", [])),
                                               "；ssh 配置已 Include" if added else ""))
        for n in NOTES:
            if "接管" in n:   # the one-time takeover; the section itself is every renew's
                say(n)
        return 0
    why = res.get("error", "HTTP %d" % code)
    if code == 503 and why == "updating":
        say("入口正在更新，一分钟内回来 — 稍后再试")
        return 1
    if code in (403, 404) or res.get("code") in ("unknown_device", "device_revoked", "device_idle", "no_account"):
        say("需要重新扫码：%s" % why)
        return NEEDS_SCAN
    say("续期失败（HTTP %d）：%s" % (code, why))
    return 1


def node_pass(hub, out, quiet=False):
    """The device's node pass by its key (claude-fleet#2212), written to out.
    0 written · NEEDS_SCAN · NO_DOOR · 1 anything else."""
    say = (lambda *_: None) if quiet else (lambda m: print("fleet login: " + m, file=sys.stderr))
    if not (os.path.exists(KEY) and os.path.exists(KEY + ".pub")):
        say("no device key yet (%s) — run: fleet login" % KEY)
        return NEEDS_SCAN
    with open(KEY + ".pub") as f:
        pub = f.read().strip()
    ts = int(time.time())
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", KEY, "-n", LOGIN_NODE_NAMESPACE],
                             input=("fleet-login-node %d" % ts).encode(), capture_output=True, check=True).stdout.decode()
    except (OSError, subprocess.CalledProcessError) as e:
        say("ssh-keygen -Y sign failed: %s" % e)
        return 1
    # A node already (joined by a scan or a code, before 登录即登记): its own
    # token says so, and the hub ties that node to this device rather than
    # enrolling a second one — read here, sent in the header, never printed.
    hdr = {}
    ne = node_env()
    if ne.get("CCQUOTA_TOKEN") and ne.get("CCQUOTA_HUB_URL", "").rstrip("/") == hub:
        hdr["Authorization"] = "Bearer " + ne["CCQUOTA_TOKEN"]
    try:
        code, res = post(hub + LOGIN_NODE_PATH, {"public_key": pub, "ts": ts, "sig": sig,
                                                 "hostname": device_name(), "os_user": getpass.getuser()}, headers=hdr)
    except (urllib.error.URLError, OSError) as e:
        say("hub unreachable (%s)" % getattr(e, "reason", e))
        return 1
    if code == 200 and res.get("token"):
        # compact, as the hub writes it: fleet-node-join.sh reads it with sed
        write_file(out, json.dumps(res, separators=(",", ":")) + "\n", 0o600)
        return 0
    why = res.get("error", "HTTP %d" % code)
    rc = res.get("code")
    if rc in ("unknown_device", "device_revoked", "device_idle", "no_account"):
        say("需要先登录：%s（fleet login）" % why)
        return NEEDS_SCAN
    if rc == "trusted_name" or code in (404, 405):
        say("入口不发登录通行证（%s）— 改用扫码：fleet node join" % why)
        return NO_DOOR
    say("没拿到节点通行证（HTTP %d）：%s" % (code, why))
    return 1


def node_env():
    """node.env's KEY=value lines ({} when there is none)."""
    out = {}
    try:
        with open(NODE_ENV) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def ensure_node(hub):
    """登录即登记 (claude-fleet#2212): after a login, this computer's node pass,
    silently — `fleet node ensure` (no scan, never fails the login)."""
    sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-node.sh")
    if not os.path.exists(sh):
        return False
    try:
        r = subprocess.run(["bash", sh, "ensure", "--hub", hub], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        return r.returncode == 0 and os.path.exists(NODE_ENV)
    except (OSError, subprocess.SubprocessError):
        return False


def cmd_node_pass(argv):
    hub_arg, out, quiet = "", "", False
    it = iter(argv)
    for a in it:
        if a == "--hub":
            hub_arg = next(it, "")
        elif a.startswith("--hub="):
            hub_arg = a.split("=", 1)[1]
        elif a == "--out":
            out = next(it, "")
        elif a == "--quiet":
            quiet = True
        else:
            die("node-pass: unknown option %s" % a)
    if not out:
        die("node-pass: --out FILE is required")
    return node_pass(hub_url(hub_arg), out, quiet)


def parse_scan_opts(argv, node=False):
    hub_arg, invert, include, out = "", False, True, ""
    it = iter(argv)
    for a in it:
        if a == "--hub":
            hub_arg = next(it, "")
        elif a.startswith("--hub="):
            hub_arg = a.split("=", 1)[1]
        elif a == "--invert":
            invert = True
        elif a == "--no-include":
            include = False
        elif node and a == "--out":
            out = next(it, "")
        else:
            die("unknown option " + a)
    return hub_arg, invert, include, out


def scan(hub, invert, purpose=""):
    """The device-code flow: start, draw the QR, wait for the confirmation.
    Returns the hub's answer (a CertResponse; with purpose=node it also
    carries `node`, the node pass — claude-fleet#1627)."""
    pub = ensure_key()
    body = {"public_key": pub, "device_name": device_name()}
    if purpose:
        body.update(purpose=purpose, os_user=getpass.getuser())
    try:
        code, st = post(hub + "/v1/fleet/login/start", body)
    except (urllib.error.URLError, OSError) as e:
        # a newcomer's first contact: one line, not a traceback (claude-fleet#2096)
        die("入口 %s 连不上（%s）— 查网络，或地址对不对：fleet login --hub <入口地址>"
            % (hub, getattr(e, "reason", e)), 1)
    if code == 503 and st.get("error") == "updating":
        # the release's 「正在更新」 backend (claude-fleet#2052) answers for the hub
        die("入口正在更新，一分钟内回来 — 稍后再敲一次", 1)
    if code == 404:
        die("this hub does not issue certificates (no CA or no GitHub sign-in configured)", 1)
    if code != 200:
        die("start refused (HTTP %d): %s" % (code, st.get("error", "")), 1)
    if not purpose:
        remember_hub(hub)

    show("\n用手机扫码或在浏览器打开下面的链接，用 GitHub 登录后点确认（验证码 %s）：\n" % st["user_code"])
    draw_qr(st.get("qr") or [], invert)
    show("\n  链接：%s" % st["verification_uri"])
    show("  密钥指纹 %s · %d 秒内有效\n" % (st.get("key_fingerprint", ""), st.get("expires_in", 600)))

    deadline = time.time() + st.get("expires_in", 600)
    interval = max(1, int(st.get("interval", 3)))
    while time.time() < deadline:
        time.sleep(interval)
        try:
            code, res = post(hub + "/v1/fleet/login/poll", {"device_code": st["device_code"]})
        except (urllib.error.URLError, OSError):
            continue  # a blip on a cross-border link: keep waiting
        if code == 202 or code >= 500:
            continue  # a 5xx is the ingress / hub between two polls, not a «no» (#1901)
        if code == 200:
            return res
        if res.get("code") == "no_machine_login":
            # the hub cannot sign for this person yet (claude-fleet#2090)
            die("✗ %s" % (res.get("reason") or res.get("error", "")), 1)
        die("not issued (HTTP %d): %s" % (code, res.get("error", "")), 1)
    die("timed out waiting for the scan — run it again", 1)


def cmd_login(argv):
    hub_arg, invert, include, _ = parse_scan_opts(argv)
    hub = hub_url(hub_arg)
    res = scan(hub, invert)
    was_node = os.path.exists(NODE_ENV)
    # 登录即登记 (claude-fleet#2212): the same confirmation makes it a node —
    # before the snippet is written, so it carries a node's machine-to-machine
    # blocks the first time. The certificate goes first: it is what says
    # "logged in" to `fleet node ensure`.
    write_file(CERT, res["certificate"], 0o644)
    ensure_node(hub)
    added = write_cert(res, include)
    show("✓ 证书已写入 %s（%s 前有效，账号 %s）" % (CERT, res["valid_before"], ",".join(res["principals"])))
    show("✓ ssh 配置 %s%s" % (SSH_CONFIG_SNIPPET, "（已在 ~/.ssh/config 末尾 Include）" if added else ""))
    for n in NOTES:
        show(n)
    show("✓ 这台电脑已登记为设备：之后 fleet 自动续证书，连续 7 天不用才需再扫")
    if os.path.exists(NODE_ENV) and not was_node:
        show("✓ 也已随登录登记为节点（不可信 · 只协调；可信只在入口 /nodes 设）")
    hosts = [l.split()[1] for l in res["ssh_config"].splitlines() if l.startswith("Host ")]
    if hosts:
        show("  现在可以：fleet（或 ssh %s）" % hosts[0])
    return 0


def cmd_node(argv):
    """`fleet node join`'s scan (claude-fleet#1627): the certificate is written
    exactly as `fleet login` writes it; the node pass goes to --out."""
    hub_arg, invert, include, out = parse_scan_opts(argv, node=True)
    if not out:
        die("node: --out FILE is required")
    res = scan(hub_url(hub_arg), invert, purpose="node")
    node = res.get("node")
    if not isinstance(node, dict) or not node.get("token"):
        # an older hub ignores purpose and answers a plain login (#1627)
        die("the hub signed a certificate but sent no node pass — it predates `fleet node join`"
            " (claude-fleet#1627); redeploy the hub, or use a join code from its /nodes page", 1)
    # compact, as the hub writes it: fleet-node-join.sh reads it with sed
    write_file(out, json.dumps(node, separators=(",", ":")) + "\n", 0o600)
    added = write_cert(res, include)
    show("✓ 证书已写入 %s（%s 前有效，账号 %s）" % (CERT, res["valid_before"], ",".join(res["principals"])))
    show("✓ ssh 配置 %s%s" % (SSH_CONFIG_SNIPPET, "（已在 ~/.ssh/config 末尾 Include）" if added else ""))
    for n in NOTES:
        show(n)
    show("✓ 已登记到入口：%s（%s）" % (node.get("label", "?"), node.get("endpoint_id", "?")))
    return 0


def cmd_hub(argv):
    hub_arg, _, _, _ = parse_scan_opts(argv)
    print(hub_url(hub_arg))
    return 0


def cmd_renew(argv):
    hub_arg, quiet, include, under = "", False, True, None
    it = iter(argv)
    for a in it:
        if a == "--hub":
            hub_arg = next(it, "")
        elif a.startswith("--hub="):
            hub_arg = a.split("=", 1)[1]
        elif a == "--if-under" or a.startswith("--if-under="):
            v = a.split("=", 1)[1] if "=" in a else next(it, "")
            if not v.isdigit():
                die("--if-under needs a number of seconds")
            under = int(v)
        elif a in ("-q", "--quiet"):
            quiet = True
        elif a == "--no-include":
            include = False
        else:
            die("unknown option " + a)
    if under is not None:
        # the keeper's margin call: nothing to do while there is time left, and
        # nothing to renew on a machine signed in another way (no certificate)
        left = cert_remaining()
        if left is None or left >= under:
            return 0
    return renew(hub_url(hub_arg), quiet, include)


def cmd_status(_argv):
    if not os.path.exists(CERT):
        print("no certificate (%s) — run: fleet login" % CERT)
        return 1
    # 登录即登记 (claude-fleet#2212): a computer logged in before it, with no
    # node.env yet, gets its node pass here — silently, no scan.
    if not os.path.exists(NODE_ENV):
        hub = os.environ.get("FLEET_HUB_URL", "") or machine_conf_hub() or str(read_hub_file().get("url") or "")
        if hub.startswith(("https://", "http://")):
            ensure_node(hub.rstrip("/"))
    out = subprocess.run(["ssh-keygen", "-L", "-f", CERT], capture_output=True, text=True)
    sys.stdout.write(out.stdout or out.stderr)
    return out.returncode


def cmd_check(_argv):
    left = cert_remaining()
    if left is None:
        print("none")
        return 1
    if left <= 0:
        print("expired")
        return 1
    print("valid %d" % left)
    return 0


def main(argv):
    if argv and argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    if argv and argv[0] == "status":
        return cmd_status(argv[1:])
    if argv and argv[0] == "check":
        return cmd_check(argv[1:])
    if argv and argv[0] == "renew":
        return cmd_renew(argv[1:])
    if argv and argv[0] == "node":
        return cmd_node(argv[1:])
    if argv and argv[0] == "node-pass":
        return cmd_node_pass(argv[1:])
    if argv and argv[0] == "hub":
        return cmd_hub(argv[1:])
    if argv and argv[0] == "login":  # `fleet-login.py login …` reads naturally too
        argv = argv[1:]
    return cmd_login(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
