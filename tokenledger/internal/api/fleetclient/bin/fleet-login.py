#!/usr/bin/env python3
"""fleet-login.py — `fleet login`: scan once, get a 12-hour SSH certificate.

    fleet login [--hub URL] [--invert] [--no-include]
    fleet login renew [--hub URL] [--quiet]
    fleet login status
    fleet login check

`bin/fleet` dispatches `fleet login` here. Logging in (claude-fleet#1412) is the device-code flow against the fleet hub
(tokenledger, CCQUOTA_FLEET=1):

  1. makes ~/.ssh/fleet-cert (ed25519, no passphrase) if it is not there —
     the private key never leaves this computer;
  2. POSTs the public half to <hub>/v1/fleet/login/start and draws the
     returned QR code here;
  3. you scan it in WeCom, sign in, and confirm the code on the page;
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

`check` prints the certificate's state (valid <seconds left> · expired · none)
and exits 0 only while it is valid. `status` is `ssh-keygen -L` on it.

The hub URL is remembered in ~/.config/claude-fleet/hub.json ({"url": …}, any
other key in it kept — `fleet connect` reads the same file), or set
FLEET_HUB_URL. Those paths are fixed: `fleet connect` (C7) reads them.

Exit: 0 certificate written · 1 refused/expired/denied (renew: the hub could
not be reached, or any other error) · 2 usage/config · 3 (renew only) this
device must scan again — not registered, revoked, or idle too long.
"""
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
INCLUDE_BEGIN = "# >>> fleet login (claude-fleet#1412) >>>"
INCLUDE_END = "# <<< fleet login <<<"
RENEW_PATH = "/v1/fleet/login/renew"
RENEW_NAMESPACE = "fleet-renew@claude-fleet"
# Exit code: this device has to scan again.
NEEDS_SCAN = 3


def die(msg, code=2):
    print("fleet login: " + msg, file=sys.stderr)
    sys.exit(code)


def hub_url(arg):
    url = arg or os.environ.get("FLEET_HUB_URL", "")
    if not url:
        url = str(read_hub_file().get("url") or "")
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
    d = read_hub_file()  # keep a token (or anything else) already there
    d["url"] = url
    os.makedirs(os.path.dirname(HUB_FILE), exist_ok=True)
    write_file(HUB_FILE, json.dumps(d, indent=2) + "\n", 0o600)


def post(url, body, timeout=20):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
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
        print("  " + "".join(line))


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


def write_cert(res, include):
    """The certificate and the ssh snippet from a CertResponse; the Include once."""
    write_file(CERT, res["certificate"], 0o644)
    write_file(SSH_CONFIG_SNIPPET, res["ssh_config"], 0o644)
    return include and ensure_include()


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
        say("✓ 证书已续期（%s 前有效，账号 %s）%s" % (res.get("valid_before", "?"), ",".join(res.get("principals", [])),
                                               "；ssh 配置已 Include" if added else ""))
        return 0
    why = res.get("error", "HTTP %d" % code)
    if code in (403, 404) or res.get("code") in ("unknown_device", "device_revoked", "device_idle", "no_account"):
        say("需要重新扫码：%s" % why)
        return NEEDS_SCAN
    say("续期失败（HTTP %d）：%s" % (code, why))
    return 1


def cmd_login(argv):
    hub_arg, invert, include = "", False, True
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
        else:
            die("unknown option " + a)
    hub = hub_url(hub_arg)
    pub = ensure_key()

    code, st = post(hub + "/v1/fleet/login/start", {"public_key": pub, "device_name": device_name()})
    if code == 404:
        die("this hub does not issue certificates (no CA or no WeCom sign-in configured)", 1)
    if code != 200:
        die("start refused (HTTP %d): %s" % (code, st.get("error", "")), 1)
    remember_hub(hub)

    print("\n用企业微信扫码，确认验证码 %s：\n" % st["user_code"])
    draw_qr(st.get("qr") or [], invert)
    print("\n  或在已登录企业微信的浏览器打开：%s" % st["verification_uri"])
    print("  密钥指纹 %s · %d 秒内有效\n" % (st.get("key_fingerprint", ""), st.get("expires_in", 600)))

    deadline = time.time() + st.get("expires_in", 600)
    interval = max(1, int(st.get("interval", 3)))
    while time.time() < deadline:
        time.sleep(interval)
        try:
            code, res = post(hub + "/v1/fleet/login/poll", {"device_code": st["device_code"]})
        except (urllib.error.URLError, OSError):
            continue  # a blip on a cross-border link: keep waiting
        if code == 202:
            continue
        if code == 200:
            break
        die("not issued (HTTP %d): %s" % (code, res.get("error", "")), 1)
    else:
        die("timed out waiting for the scan — run it again", 1)

    added = write_cert(res, include)
    print("✓ 证书已写入 %s（%s 前有效，账号 %s）" % (CERT, res["valid_before"], ",".join(res["principals"])))
    print("✓ ssh 配置 %s%s" % (SSH_CONFIG_SNIPPET, "（已在 ~/.ssh/config 末尾 Include）" if added else ""))
    print("✓ 这台电脑已登记为设备：之后 fleet 自动续证书，连续 7 天不用才需再扫")
    hosts = [l.split()[1] for l in res["ssh_config"].splitlines() if l.startswith("Host ")]
    if hosts:
        print("  现在可以：fleet（或 ssh %s）" % hosts[0])
    return 0


def cmd_renew(argv):
    hub_arg, quiet, include = "", False, True
    it = iter(argv)
    for a in it:
        if a == "--hub":
            hub_arg = next(it, "")
        elif a.startswith("--hub="):
            hub_arg = a.split("=", 1)[1]
        elif a in ("-q", "--quiet"):
            quiet = True
        elif a == "--no-include":
            include = False
        else:
            die("unknown option " + a)
    return renew(hub_url(hub_arg), quiet, include)


def cmd_status(_argv):
    if not os.path.exists(CERT):
        print("no certificate (%s) — run: fleet login" % CERT)
        return 1
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
    if argv and argv[0] == "login":  # `fleet-login.py login …` reads naturally too
        argv = argv[1:]
    return cmd_login(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
