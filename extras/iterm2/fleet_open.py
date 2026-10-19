#!/usr/bin/env python3
"""fleet_open.py — the LAPTOP half of `fleet-open` (issue #1380; interface #1379).

An iTerm2 AutoLaunch script. The mini's `bin/fleet-open.sh` writes

    ESC ] 1337 ; Custom=id=<secret>:<base64 JSON> BEL

to the iTerm2 client the operator is using; iTerm2 hands the payload to this
script (only when <secret> matches ours — anything else is never delivered), and
it does what the JSON asks:

  kind=forward  a service on the mini's loopback ({"rport", "path", "scheme",
                "host"}): add `-L <lport>:127.0.0.1:<rport>` to the EXISTING ssh
                connection (`ssh -O forward`, needs ControlMaster), else start a
                background `ssh -N -L …` that exits after 30 idle minutes; then
                open http://localhost:<lport><path> here.
  kind=url      an outside link: http/https only; a host on the allow-list
                (~/.config/fleet-open/allow, default github.com + claude.ai) opens
                at once, anything else asks first (osascript dialog).

Every action appends one line to ~/.config/fleet-open/log.

THE RECEIPT (issue #3540): a payload with an "id" (hex) is answered over the same
ssh the forward rides — `ssh <host> bash .claude/fleet/bin/fleet-open.sh --ack <id>
ok|fail <why>` — so the session that asked prints `opened` or `failed:<why>`, not
`unconfirmed`: opened (also after the dialog's Open) → ok; declined, `open` failing,
a refused request (stale, bad field), a forward that would not come up → fail with
the reason. No id (an older mini) → nothing sent.

Install with extras/iterm2/install.sh (it puts this file in
~/Library/Application Support/iTerm2/Scripts/AutoLaunch/). Everything above the
`iTerm2 glue` line is pure and unit-tested (test_fleet_open.py) without iTerm2.
"""

FLEET_OPEN_VERSION = "2"  # bump on any behaviour change: fleet-doctor compares it

import base64
import binascii
import json
import os
import random
import re
import shlex
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

CONF_DIR = os.path.expanduser(os.environ.get("FLEET_OPEN_CONF_DIR", "~/.config/fleet-open"))
DEFAULT_ALLOW = ("github.com", "claude.ai")
PORT_LO, PORT_HI = 20000, 29999
IDLE_SECS = 30 * 60
STALE_SECS = 600  # a request older than this (by its own ts) is a replay, not a click
PAYLOAD_RE = r"^([A-Za-z0-9+/=_-]+)$"
ID_RE = r"^[a-f0-9]{1,64}$"
# The mini's fleet-open.sh, from its login's home (install.sh's MINI_ROOT): never a
# path the payload names — the laptop runs nothing a request spells out.
ACK_BIN = ".claude/fleet/bin/fleet-open.sh"
HOST_RE = r"^[A-Za-z0-9][A-Za-z0-9._@-]*$"


class Reject(ValueError):
    """A request we refuse; str() is the reason that goes in the log."""


def _b64decode(s):
    s = s.strip()
    s += "=" * (-len(s) % 4)
    try:
        if "-" in s or "_" in s:
            return base64.urlsafe_b64decode(s)
        return base64.b64decode(s, validate=True)
    except (binascii.Error, ValueError):
        raise Reject("bad base64")


def parse_payload(b64, now=None):
    """base64 JSON from the control sequence → a normalized request dict."""
    raw = _b64decode(b64)
    try:
        req = json.loads(raw.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError and JSONDecodeError both are
        raise Reject("bad json")
    if not isinstance(req, dict):
        raise Reject("not an object")
    if str(req.get("v", "")) != "1":
        raise Reject("unsupported v=%r" % req.get("v"))
    ts = req.get("ts")
    if now is not None and isinstance(ts, (int, float)) and not isinstance(ts, bool):
        if abs(now - ts) > STALE_SECS:
            raise Reject("stale ts")
    host = req.get("host") or ""
    if not isinstance(host, str) or (host and not re.match(HOST_RE, host)):
        raise Reject("bad host")
    kind = req.get("kind")
    if kind == "forward":
        try:
            rport = int(req.get("rport"))
        except (TypeError, ValueError):
            raise Reject("bad rport")
        if not 1 <= rport <= 65535:
            raise Reject("bad rport")
        path = req.get("path") or "/"
        if not isinstance(path, str) or not path.startswith("/") or re.search(r"[\s\x00-\x1f]", path):
            raise Reject("bad path")
        scheme = req.get("scheme") or "http"
        if scheme not in ("http", "https"):
            raise Reject("bad scheme")
        return {"kind": "forward", "rport": rport, "path": path, "scheme": scheme, "host": host}
    if kind == "url":
        url = req.get("url")
        if not isinstance(url, str):
            raise Reject("bad url")
        check_url(url)
        return {"kind": "url", "url": url, "host": host}
    raise Reject("unknown kind=%r" % kind)


def peek(b64):
    """(id, host hint) of a payload, before any check — so even a request we refuse
    is answered. Either is None/"" when absent or not well-formed."""
    try:
        req = json.loads(_b64decode(b64).decode("utf-8"))
    except (Reject, ValueError):
        return None, ""
    if not isinstance(req, dict):
        return None, ""
    oid, host = req.get("id"), req.get("host")
    oid = oid if isinstance(oid, str) and re.match(ID_RE, oid) else None
    host = host if isinstance(host, str) and re.match(HOST_RE, host) else ""
    return oid, host


RESULT_WHY = {
    "open-failed": "the browser did not open it (`open` failed on the laptop)",
    "declined": "declined on the laptop (the link is not on its allow-list)",
}


def ack_words(result):
    """A handled request's result → ("ok", "") or ("fail", why)."""
    if result in ("opened", "opened-confirmed"):
        return "ok", ""
    return "fail", RESULT_WHY.get(result, "the laptop said %s" % result)


def ack_cmd(host, oid, state, why):
    """The receipt, as one ssh to the mini (the multiplexed one when it is up)."""
    why = re.sub(r"[\t\n\r\x00-\x1f]", " ", why or "")[:200]
    remote = " ".join(shlex.quote(w) for w in ["bash", ACK_BIN, "--ack", oid, state, why])
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, remote]


def load_allow(text):
    """The allow file's text (None = no file) → a list of host suffixes."""
    if text is None:
        return list(DEFAULT_ALLOW)
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip().lower()
        if line:
            out.append(line.lstrip("."))
    return out


def check_url(url):
    """http/https with a host, or Reject. Returns the lowercased host."""
    if re.search(r"[\s\x00-\x1f]", url):
        raise Reject("bad url")
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise Reject("scheme not http/https")
    host = (parts.hostname or "").lower()
    if not host:
        raise Reject("url has no host")
    return host


def host_allowed(host, allow):
    """github.com allows github.com and *.github.com — never evilgithub.com."""
    host = host.lower().rstrip(".")
    return any(host == a or host.endswith("." + a) for a in allow)


def resolve_host(req, host_file_text):
    """Which ssh alias reaches the mini: the request's own hint, else the file."""
    if req.get("host"):
        return req["host"]
    if host_file_text:
        for line in host_file_text.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    raise Reject("no ssh host (payload has none, ~/.config/fleet-open/host is empty)")


def map_key(host, rport):
    return "%s|%d" % (host, rport)


def pick_lport(rport, remembered, is_free, is_ours, rng=None):
    """→ (lport, reuse). reuse=True: our ssh already listens there, just open.

    Order: the port remembered for this (host, rport) if it is still ours or
    free; else rport itself if free; else a free port in 20000-29999."""
    if remembered:
        if is_ours(remembered):
            return remembered, True
        if is_free(remembered):
            return remembered, False
    if is_free(rport):
        return rport, False
    rng = rng or random.Random()
    ports = list(range(PORT_LO, PORT_HI + 1))
    rng.shuffle(ports)
    for p in ports[:200]:
        if is_free(p):
            return p, False
    raise Reject("no free local port in %d-%d" % (PORT_LO, PORT_HI))


def forward_spec(lport, rport):
    return "%d:127.0.0.1:%d" % (lport, rport)


def mux_forward_cmd(host, lport, rport):
    """Add the forward to the live ControlMaster connection."""
    return ["ssh", "-O", "forward", "-L", forward_spec(lport, rport), host]


def fallback_forward_cmd(host, lport, rport):
    """No master: a background ssh carrying only this forward."""
    return ["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-L", forward_spec(lport, rport), host]


def local_url(scheme, lport, path):
    return "%s://localhost:%d%s" % (scheme, lport, path)


def applescript_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def confirm_cmd(url):
    """osascript that exits 0 only when the operator clicks Open."""
    script = ("display dialog %s & return & return & %s with title %s "
              "buttons {\"Cancel\", \"Open\"} default button \"Cancel\" with icon caution"
              % (applescript_str("A fleet session asks to open a link not on your allow-list:"),
                 applescript_str(url), applescript_str("fleet-open")))
    return ["osascript", "-e", script]


def log_line(now, kind, detail, result):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    return "%s\t%s\t%s\t%s\n" % (stamp, kind, detail.replace("\t", " ").replace("\n", " "), result)


# ---------------------------------------------------------------------------
# side effects (local machine) — thin, so the logic above stays testable

def _read(name):
    try:
        with open(os.path.join(CONF_DIR, name)) as f:
            return f.read()
    except OSError:
        return None


def log(kind, detail, result):
    try:
        os.makedirs(CONF_DIR, exist_ok=True)
        with open(os.path.join(CONF_DIR, "log"), "a") as f:
            f.write(log_line(time.time(), kind, detail, result))
    except OSError:
        pass


def port_free(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", p))
        return True
    except OSError:
        return False
    finally:
        s.close()


def port_is_ssh(p):
    try:
        out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % p, "-sTCP:LISTEN", "-Fc"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return any(line == "cssh" for line in out.splitlines())


def _wait_listen(p, secs=8.0):
    end = time.time() + secs
    while time.time() < end:
        if not port_free(p):
            return True
        time.sleep(0.2)
    return False


_lock = threading.Lock()
_fallbacks = {}  # lport -> [Popen, last_used]


def _load_map():
    try:
        return json.loads(_read("ports.json") or "{}")
    except ValueError:
        return {}


def _save_map(m):
    try:
        os.makedirs(CONF_DIR, exist_ok=True)
        tmp = os.path.join(CONF_DIR, "ports.json.tmp")
        with open(tmp, "w") as f:
            json.dump(m, f)
        os.replace(tmp, os.path.join(CONF_DIR, "ports.json"))
    except OSError:
        pass


def _open(url):
    return subprocess.run(["open", url], capture_output=True, timeout=15).returncode == 0


def do_forward(req):
    host = resolve_host(req, _read("host"))
    rport = req["rport"]
    with _lock:
        m = _load_map()
        key = map_key(host, rport)
        lport, reuse = pick_lport(rport, m.get(key), port_free, port_is_ssh)
        via = "reuse"
        if not reuse:
            r = subprocess.run(mux_forward_cmd(host, lport, rport), capture_output=True, text=True, timeout=15)
            if r.returncode == 0:
                via = "mux"
            else:
                p = subprocess.Popen(fallback_forward_cmd(host, lport, rport), stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     start_new_session=True)
                if not _wait_listen(lport) or p.poll() is not None:
                    p.kill()
                    raise Reject("forward failed (mux: %s; ssh -N exited)" % (r.stderr.strip()[:80] or r.returncode))
                _fallbacks[lport] = [p, time.time()]
                via = "ssh-N"
        if lport in _fallbacks:
            _fallbacks[lport][1] = time.time()
        m[key] = lport
        _save_map(m)
    url = local_url(req["scheme"], lport, req["path"])
    detail = "host=%s rport=%d lport=%d via=%s %s" % (host, rport, lport, via, url)
    return detail, ("opened" if _open(url) else "open-failed")


def do_url(req):
    url = req["url"]
    host = check_url(url)
    if host_allowed(host, load_allow(_read("allow"))):
        return url, ("opened" if _open(url) else "open-failed")
    ok = subprocess.run(confirm_cmd(url), capture_output=True, timeout=600).returncode == 0
    if not ok:
        return url, "declined"
    return url, ("opened-confirmed" if _open(url) else "open-failed")


def send_ack(hint, oid, state, why):
    """The receipt of open <oid> (issue #3540); a failed send is only logged."""
    try:
        host = resolve_host({"host": hint}, _read("host"))
        r = subprocess.run(ack_cmd(host, oid, state, why), stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=20)
        res = "ack-sent" if r.returncode == 0 else "ack-failed rc=%d" % r.returncode
    except Reject as e:
        res = "ack-failed %s" % e
    except (OSError, subprocess.SubprocessError) as e:
        res = "ack-failed %s" % type(e).__name__
    log("ack", "id=%s %s" % (oid, state), res)


def handle(b64):
    oid, hint = peek(b64)
    state, why = "fail", ""
    try:
        req = parse_payload(b64, now=time.time())
        if req["kind"] == "forward":
            detail, result = do_forward(req)
        else:
            detail, result = do_url(req)
        log(req["kind"], detail, result)
        state, why = ack_words(result)
    except Reject as e:
        log("reject", b64[:60], str(e))
        why = "the laptop refused it: %s" % e
    except Exception as e:  # never let one request kill the monitor
        log("error", b64[:60], "%s: %s" % (type(e).__name__, e))
        why = "error on the laptop: %s" % type(e).__name__
    if oid:
        send_ack(hint, oid, state, why)


def reap_idle(now=None):
    if now is None:
        now = time.time()
    with _lock:
        for lport, (p, last) in list(_fallbacks.items()):
            if p.poll() is not None or now - last > IDLE_SECS:
                if p.poll() is None:
                    p.terminate()
                    log("forward", "lport=%d" % lport, "idle-closed")
                del _fallbacks[lport]


# ---------------------------------------------------------------------------
# iTerm2 glue

async def main(connection):
    import asyncio
    import iterm2

    secret = (_read("secret") or "").strip()
    if not secret:
        log("error", "-", "no secret in %s/secret — rerun install.sh" % CONF_DIR)
        return
    log("start", "version=%s" % FLEET_OPEN_VERSION, "listening")
    loop = asyncio.get_event_loop()

    async def reaper():
        while True:
            await asyncio.sleep(60)
            reap_idle()

    asyncio.ensure_future(reaper())
    async with iterm2.CustomControlSequenceMonitor(connection, secret, PAYLOAD_RE) as mon:
        while True:
            match = await mon.async_get()
            loop.run_in_executor(None, handle, match.group(1))


if __name__ == "__main__":
    import iterm2

    iterm2.run_forever(main)
