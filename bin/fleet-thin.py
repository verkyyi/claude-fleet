#!/usr/bin/env python3
"""fleet-thin.py — the thin client: one small loop, one connection to the home
machine (issue #3003, EPIC #2999 C6; the EPIC's 约定 3, 4, 6, 10, 11).

    fleet --thin [<session>]          (FLEET_CLIENT=thin: plain `fleet`)
    fleet-thin.py --run [--tty] [--home <m>] -- <word>…
                                      ONE command on the home machine over a
                                      one-shot ssh (`fleet ls / open / answer /
                                      claude` with no client tmux — issue #3004)

What runs on this computer while you look at your sessions: this loop, and the
ssh it holds open to your HOME machine (+ the relay's ProxyCommand when the
route is the hub's relay). No tmux, no background process, no ControlMaster —
every ssh is `-o ControlMaster=no -o ControlPath=none`, so a `ControlMaster
auto` in your own ~/.ssh/config leaves no socket anywhere — and no file but the
log, ${XDG_CACHE_HOME:-~/.cache}/claude-fleet/thin.log. Everything you see —
the bar, the switcher, the other machines' sessions — the home machine draws
in your VIEW there (`fleet-remote-view.sh attach --thin`, 约定 6).

Each connection:
  1. the certificate, the machine and the route — `fleet-connect.py --argv
     [<home>]` (约定 4): the one place that renews the certificate, asks the hub
     which machine is home and picks the line (pinned · remembered · measured;
     the tailnet first). It answers the ssh argv; this puts `-tt` and the
     options above before the host and the view's command after it;
  2. the view: `--view <device>-<rand>` (made once, kept in memory only),
     `--want <session>` the first time when one is named, `--resume` after,
     `--device <base64 JSON>` (fleet-client-lease.py's `where`), `--route
     <name>`, `--token <nonce>` (new each connection);
  3. ssh, under a pty filter of its own: what you type goes on untouched,
     except a DROP — a bracketed paste of nothing but absolute paths of files
     on this computer (fleet-client-upload.py's Rewriter) — and ⌃V with a
     picture on the clipboard: the file goes to the home in a one-shot ssh
     (`fleet-client-upload.py recv <m> <l> <w>` there; the home hands it to
     the session's machine over its standing connection) and the path THERE
     is pasted instead. Where the session is comes from the home's last
     `ESC ] 7502 ; cur ; token=… ; m= ; l= ; w= BEL`; `… ; quit ; token=… BEL`
     is ⌘Q. Every OSC 7502 is swallowed — one with another token (a program
     inside a session pretending to be the home) does nothing at all (约定 10).
     `… ; open ; token=… ; j=<base64 JSON> BEL` (issue #3236, fleet-browser on:
     fleet-open.sh on the home) opens a page HERE — fleet-open-addr.py's payload
     + who + ttl: an OAuth page's callback port `cport` forwarded AS ITSELF over
     a second ssh to the home first (busy here ⇒ said, not opened), a loopback
     page's `rport` forwarded to the same port (else any free one). Each forward
     is one notification line (the port, the session, when it closes) + a line
     of forwards.log beside thin.log, and closes once the home's server is gone
     or at its deadline (bin/fleet_open_fwd.py); none outlive this loop. Then
     the RECEIPT (issue #3538): the payload's `id` goes back as one ssh on the
     same line — `fleet-open.sh --ack <id> ok|fail <why>` on the home — so the
     session that asked says `opened` / `failed:<why>`, never a guess.
     `… ; show ; token=… ; j=<base64 {id,name,size,who}> BEL` (issue #3541,
     fleet-show.sh on the home, only because this loop says `FLEET_CLIENT_CAPS=show`
     in its attach): ONE ssh on the same line streams the file the home registered
     under that id (`fleet-show.sh --fetch <id>` there — the loop never names a
     path) into ~/Downloads (FLEET_THIN_DOWNLOADS; a taken name gets ` (n)`), checked
     against its size, then `fleet-open.sh --ack <id> ok <the path>` — or `fail
     <why>` — so the session prints `saved:<path>`; a notification line says it.

When it ends: ⌘Q (quit) or ssh exit 0 (a detach) — the iTerm2 profile goes
back (约定 11) and this exits 0. Anything else — the line dropped, the lid
closed — one line 「和 <home> 的连接断了，N 秒后重连（第 k 次）」 and a reconnect
after 1 · 2 · 4 … 30 s to the SAME view (`--resume`). Three connections in a
row that never came up (no valid 7502 and gone within FLEET_THIN_UP_SECS):
the hub is asked for another online machine to be home (`--avoid <home>`) —
unless the hub does not answer either (issue #3007): then it is this computer's
own line that is down, the home is kept and the view with it. No other machine
to go to (`--avoid` exits 1): back to the same home, its view and the backoff
(issue #4829) — never asking the hub for nothing until the person gives up.
The screen is held through all of it (T690): a drop after the view was drawn
turns mouse reporting off but never leaves the alternate screen — the view's
last picture stays, its top row overwritten (reverse video) with 「正在重连 · …」,
and ssh's own complaints are kept off it until the next view draws. A line
watch (LineWatch: a TCP connect every FLEET_THIN_PROBE_SECS to the last route's
address — fleet-connect --argv's `probe` — and the hub) runs from the drop to
the next view: the moment the line goes from no answer to an answer the
backoff, a pick or an ssh started on the dead network is cut short and the
loop reconnects at once (thin.log `back`) — back within seconds of the
network, never after the rest of a 30 s wait. A 换家 asks for the other machine
at once (no backoff first), says 「家机器 <home> 连不上，正在换到另一台」 and
brings FLEET_CLIENT_REHOMED=<the home it left> to the new home's attach, whose
top line says 「家机器 X 连不上，已自动换到 Y」 for 60 s.
A home that answers but whose 看台 keeps breaking (EPIC T651 C4): ssh got
through (not ssh's 255, not rc 3) yet the view never came up, or ended with
a code that is not a leave (0 · 129) within FLEET_THIN_CRASH_SECS (60) —
FLEET_THIN_VIEW_FAILS (3) of those in a row and it stops reconnecting into it
(and never 换家: the home answers): one line 「看台连续 3 次没起来 — 已把你放在
<home> 的命令行」 + how back, then a plain interactive ssh on the same route
and certificate, the home's login shell in $HOME with FLEET_NO_VIEW=1
(fleet-login.zsh starts no 看台 under it); once that shell ends, the 看台 again.
No fleet of yours there (issue #3054): the home answers `no fleet session is
live` (rc 3) — a newcomer whose only login is the computer they type on — or the
hub is still opening their first login. Then not a backoff but the old client's
first-session road: a lease, `fleet-client-place.sh - home --agent claude`, the
hub's 「正在为你开机器（m），约 N 秒」 while it opens, and the next connection to the
machine the session opened on, onto it (`--want <worker_id>`); a refusal that
heals by itself — the machine's credentials not settled, its tmux restarting,
its node between two beats, the hub's own 5xx — is waited out, said on the screen, for
FLEET_THIN_FIRST_WAIT s (issue #4829); a failure is three lines — 没开出来 · 原因 ·
下一步 (who to ask) — and exit 1.
Between two connections a new client version (the install's .client-version,
`fleet-client-update.sh start` → 3) is exec'd in place, view and home kept.
While a connection is up (issue #4916) the loop asks too: every
FLEET_THIN_POLL_SECS (120) `fleet-client-update.sh poll` in the background
(the hub's /version, no hourly stamp; it stages a newer client and exits 10);
once one is staged and the person has pressed nothing for FLEET_THIN_UPDATE_IDLE
(30) s with no upload in flight, the loop ends that line itself, switches
(`start`) and execs the new version onto the SAME view (`--resume`) — a 看台
left open for days follows stable within minutes. FLEET_CLIENT_UPDATED (set
by `fleet` after its own start switched) only skips the first check after the
start, never every later one. A switch that did not happen (start not 3)
holds the next one for FLEET_THIN_UPDATE_HOLD (3600) s.

`--local` (issue #3006, EPIC #2999 C9): this machine is home — a managed
machine's own `fleet`, typed over ssh from a phone. No hub is asked and no ssh
is run: the view's command is this loop's child, under the same pty filter
(fleet-connect.py --argv answers the same `local` when the hub's pick is this
machine and this login — no ssh back to itself either). No 换家, no update of
its own (the machine's runtime moves it).

thin.log — TSV, one line per connection, fields only ever added at the end
(docs/dev/CLIENT-LOGS.md; C10 reads it):
    time(UTC)  event  home  route  pick_ms  ssh_ms  first_ms  rc  reason  net  end
event: connect (pick_ms = fleet-connect --argv, ssh_ms = spawn → the first
byte back, first_ms = spawn → the first valid `cur`: the view drawn; net =
`net=<gateway>@<network>`, the network the route was picked on, #3074; end =
`end=<word>` on a connection that did not end 0 — what ssh said last: timeout ·
reset · broken-pipe · closed-remote · closed · unreachable · refused ·
connect-timeout, empty when it said none of them, #4828) · rehome · back (the line came back: a wait cut short, T690) ·
upload · show · exec · quit · shell (the home's command line, C4) · first (the first-session road, #3054) · offline (no 换家: the hub did not answer either) · run (`--run`: one command on the home, issue #3004 —
reason = its first word).

The same lifecycle goes to the hub as connection events (T689,
bin/fleet_client_events.py — start · up · drop · fail · rehome · offline · quit,
metadata only, spooled and sent on a thread; FLEET_CLIENT_EVENTS=0 off).

Knobs: FLEET_THIN_UP_SECS (10), FLEET_THIN_BACKOFF ("1,2,4,8,16,30"),
FLEET_THIN_ALIVE_SECS (5) × FLEET_THIN_ALIVE_MAX (3): the keepalive — a line
silent that long is given up (#4828),
FLEET_THIN_REHOME_AFTER (3), FLEET_THIN_VIEW_FAILS (3), FLEET_THIN_CRASH_SECS (60),
FLEET_THIN_PROBE_SECS (0.5) · FLEET_THIN_PROBE_TMO (1): the line watch (T690),
FLEET_THIN_HUB_PROBE_SECS (4), FLEET_THIN_POLL_SECS (120),
FLEET_THIN_UPDATE_IDLE (30), FLEET_THIN_UPDATE_HOLD (3600), FLEET_REMOTE_BIN (.claude/fleet/bin),
FLEET_CLIENT_PASTE=0 (drops and ⌃V byte for byte), FLEET_ITERM_KEYS=0,
FLEET_THIN_FIRST_RETRY (10), FLEET_HOME_FIRST_OPENING_MAX (2400), FLEET_THIN_FIRST_SETTLE (600),
FLEET_THIN_FIRST_WAIT (300),
FLEET_THIN_FIRST_ROUNDS (3), FLEET_THIN_FETCH_SECS (600), FLEET_THIN_LOG. Seams (tests): FLEET_THIN_ARGV_CMD (in place of
`fleet-connect.py --argv`), FLEET_THIN_UPDATE_CMD (in place of
`fleet-client-update.sh start`), FLEET_THIN_POLL_CMD (in place of
`fleet-client-update.sh poll`), FLEET_CLIENT_CLIP_CMD (the clipboard),
FLEET_THIN_FETCH_CMD (in place of the `--fetch` ssh; the id appended),
FLEET_THIN_HUB_PROBE_CMD (in place of asking the hub's /version before 换家),
FLEET_THIN_LINE_PROBE_CMD (in place of the line watch's TCP connects; exit 0 = answers),
FLEET_CLIENT_LEASE_CMD / FLEET_THIN_PLACE_CMD / FLEET_THIN_ACCOUNT_CMD (the
first session's lease, place and the hub's account word).
Standard library only.
"""
import base64
import calendar
import errno
import fcntl
import importlib.util
import json
import os
import random
import re
import select
import shlex
import signal
import subprocess
import sys
import termios
import threading
import time
import tty

BIN = os.path.dirname(os.path.abspath(__file__))
PFX = b"\x1b]7502;"
OSC_MAX = 4096
START, END = b"\x1b[200~", b"\x1b[201~"
# what a dropped connection may leave the terminal in: the alternate screen,
# mouse reporting, bracketed paste, a hidden cursor
RESET = (b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l"
         b"\x1b[?1004l\x1b[?2004l\x1b[?25h\x1b[0m\r\n")
# the same minus leaving the alternate screen (T690): a drop keeps the view's
# last picture where it was, a 「正在重连」 line written over its top row
MOUSE_OFF = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1004l\x1b[?2004l\x1b[0m"


def quiet(attrs):
    """termios attrs with echo off (ISIG and the rest kept)."""
    a = list(attrs)
    a[3] &= ~(termios.ECHO | termios.ECHONL | getattr(termios, "ECHOCTL", 0))
    return a


def env_num(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


def load(name, mod):
    spec = importlib.util.spec_from_file_location(mod, os.path.join(BIN, name))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


TEXT = {}


def tr(key, *args):
    if not TEXT:
        try:
            out = subprocess.run(["sh", os.path.join(BIN, "fleet-ui-lang.sh"), "dump", "thin_"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = b""
        parts = out.decode("utf-8", "replace").split("\0")
        for i in range(0, len(parts) - 1, 2):
            TEXT[parts[i]] = parts[i + 1]
        TEXT.setdefault("", "")
    s = TEXT.get(key, key)
    for a in args:
        s = s.replace("\001", str(a), 1)
    return s


# ---------------------------------------------------------------------------
# thin.log
# ---------------------------------------------------------------------------

def log_path():
    return os.environ.get("FLEET_THIN_LOG") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"),
        "claude-fleet", "thin.log")


def tlog(event, home="", route="", pick_ms="", ssh_ms="", first_ms="", rc="", reason="", net="", end=""):
    path = log_path()
    try:
        cl = load("fleet_clientlog.py", "fleet_clientlog")
    except Exception:
        cl = None
    reason = str(reason)
    if cl:
        reason = cl.redact(cl.cut(cl.flat(reason)))
        cl.rotate(path)
    fields = [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), event, home, route,
              pick_ms, ssh_ms, first_ms, rc, reason, ("net=" + net) if net else "", ("end=" + end) if end else ""]
    while fields and fields[-1] == "" and len(fields) > 10:
        fields.pop()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in fields) + "\n")
    except OSError:
        pass


# What ssh said as it went (issue #4828): its last words, on the pty with the
# view's output — the cause a drop's `connect` line carries as `end=<word>`.
SSH_ENDS = (
    ("timeout", re.compile(rb"Timeout, server .{0,200}not responding")),
    ("reset", re.compile(rb"Connection reset by peer")),
    ("broken-pipe", re.compile(rb"Broken pipe")),
    ("closed-remote", re.compile(rb"Connection to .{0,200}closed by remote host")),
    ("unreachable", re.compile(rb"Network is unreachable|No route to host|Host is down")),
    ("refused", re.compile(rb"Connection refused")),
    ("connect-timeout", re.compile(rb"Operation timed out|Connection timed out")),
    ("closed", re.compile(rb"Connection to .{0,200}closed\.")),
)


def ssh_end(tail):
    """The word for how ssh ended, off the last bytes it printed, or "" — the
    first of SSH_ENDS that is there (ssh follows «closed by remote host» with a
    plain «closed.»: the specific one wins)."""
    return next((word for word, rx in SSH_ENDS if rx.search(tail or b"")), "")


def home_code(since):
    """The hub's code off connect.log's last `home` line written since `since`
    (fleet-connect.py: the hub gave no machine — no_machine_online, opening,
    device_revoked, …, unreachable), else ""."""
    try:
        cl = load("fleet_clientlog.py", "fleet_clientlog")
        with open(os.path.join(cl.log_dir(), "connect.log"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 8192))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return ""
    for line in reversed(lines):
        p = line.split("\t")
        if len(p) >= 6 and p[1] == "home":
            try:
                at = calendar.timegm(time.strptime(p[0], "%Y-%m-%dT%H:%M:%SZ"))
            except ValueError:
                return ""
            return p[5] if at >= since - 1 else ""
    return ""


_EVENTS = []


def events():
    """bin/fleet_client_events.py, loaded once — None when it cannot be."""
    if not _EVENTS:
        try:
            _EVENTS.append(load("fleet_client_events.py", "fleet_client_events"))
        except Exception:
            _EVENTS.append(None)
    return _EVENTS[0]


def alive_opts():
    """The connection's keepalive (issue #4828): ssh gives the line up after
    FLEET_THIN_ALIVE_MAX keepalives in a row go unanswered, one every
    FLEET_THIN_ALIVE_SECS — 5 × 3 = 15 s. It was 2 × 3: a 6 s stall of a
    hotspot or a Wi-Fi scan ended a live session, 70 times in a week on the
    operator's Mac."""
    secs = max(1, int(env_num("FLEET_THIN_ALIVE_SECS", 5)))
    n = max(1, int(env_num("FLEET_THIN_ALIVE_MAX", 3)))
    return ["-o", "ServerAliveInterval=%d" % secs, "-o", "ServerAliveCountMax=%d" % n]


def ms(t0, t1=None):
    return "%d" % (((t1 or time.time()) - t0) * 1000)


# ---------------------------------------------------------------------------
# the home and the line — fleet-connect.py --argv (约定 4)
# ---------------------------------------------------------------------------

def pick(home="", avoid="", reconnect=False, restart=None):
    """(fleet-connect --argv's JSON, pick_ms, why) — the certificate renewed, the
    home asked, the line picked; (None, ms, why) when there is none. restart():
    True while it runs ⇒ the line just came back (LineWatch, T690): a pick that
    started on a dead network is waiting out its timeouts — kill it and ask again."""
    seam = os.environ.get("FLEET_THIN_ARGV_CMD")
    cmd = shlex.split(seam) if seam else [sys.executable or "python3", os.path.join(BIN, "fleet-connect.py"), "--argv"]
    if home:
        cmd.append(home)
    if avoid:
        cmd += ["--avoid", avoid]
    env = dict(os.environ)
    if reconnect:
        env["FLEET_CONNECT_RETEST"] = "last"   # the remembered line first (#2886)
    t0 = time.time()
    try:
        # stderr stays the terminal's: a scan or a renewal speaks there
        while True:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, env=env)
            box = {}
            rd = threading.Thread(target=lambda: box.setdefault("out", p.stdout.read()), daemon=True)
            rd.start()
            t1 = time.time()
            while rd.is_alive() and time.time() - t1 < 300:
                rd.join(0.1)
                if restart and restart() and rd.is_alive():
                    break
            if rd.is_alive():
                p.kill()
                p.wait()
                rd.join(1)
                if time.time() - t1 >= 300:
                    raise subprocess.TimeoutExpired(cmd, 300)
                tlog("back", home or "-", "", ms(t1), "", "", "", "the line came back: asking again")
                continue
            p.wait()
            break
    except (OSError, subprocess.SubprocessError) as e:
        return None, ms(t0), str(e)
    out = box.get("out") or b""
    try:
        j = json.loads(out.decode("utf-8", "replace").strip().splitlines()[-1])
    except (ValueError, IndexError):
        j = None
    if isinstance(j, dict) and isinstance(j.get("opening"), dict):
        return None, ms(t0), OPENING   # the hub is opening this person's first login (#3054)
    if p.returncode != 0 or not isinstance(j, dict) or not ("argv" in j or j.get("local")):
        return None, ms(t0), "fleet-connect --argv exit %d" % p.returncode
    return j, ms(t0), ""


OPENING = "opening"   # pick()'s why: the hub is opening this person's first login
NO_FLEET = 3          # fleet-remote-view.sh attach --thin: no fleet session is live there
# A machine's refusal that heals by itself (issue #4829): the hub's placement
# words (tokenledger fleet_write.go) for a machine coming up — its credentials
# or repo not settled yet («not ready: …»), its fleet's tmux not running yet
# (excludedDown, an update's restart too), its node between two beats
# («offline»). 「没有你的登录」, compute off, full … do not heal by waiting — nor
# does a 「；正在更新（…）」 the hub appends to any reason.
HEALS = ("not ready: ", "tmux 服务没在跑", "offline")


def first_heals(said):
    """The part of a first-session refusal that heals by itself — «<machine>: <why>»
    or the hub's own 5xx — else "". `said` is fleet-client-place.sh's line: «No
    machine can take a new session now — m1: why; m2: why», or its error."""
    said = str(said or "")
    if re.search(r"HTTP 5[0-9][0-9]|retry shortly", said):
        return " ".join(said.split())[:120]
    for part in said.split(" — ", 1)[-1].split("; "):
        why = part.split(": ", 1)[1] if ": " in part else ""
        if why.startswith(HEALS):
            return part.strip()[:120]
    return ""


def hub_conf():
    """(hub URL, token, the fleet-connect module) — "" when there is no hub."""
    try:
        fc = load("fleet-connect.py", "fleet_connect")
        conf = fc.load_hub_conf()
        hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or conf.get("url") or ""
        return hub, os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or "", fc
    except (Exception, SystemExit):
        return "", "", None


def account_state():
    """The hub's word on this person's login (claude-fleet#2069): {state
    opening|failed|none, eta_s, machine, ask, why} — the `account` of the
    certificate door POST /v1/fleet/summary, where the old client's list reads it
    (fleet-hub-sessions.sh's #account); {} when they hold one, or the hub cannot
    be asked. FLEET_THIN_ACCOUNT_CMD is the seam (prints that JSON)."""
    seam = os.environ.get("FLEET_THIN_ACCOUNT_CMD")
    try:
        if seam:
            out = subprocess.run(shlex.split(seam), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=30).stdout
            a = json.loads(out.decode("utf-8", "replace").strip() or "{}")
        else:
            import urllib.request
            hub, token, fc = hub_conf()
            if not hub:
                return {}
            url = hub.rstrip("/") + "/v1/fleet/summary"
            if token:
                req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
            else:
                ts = int(time.time())
                cert, sig = fc.ssh_sign("fleet-summary %d" % ts, "fleet-summary@claude-fleet")
                req = urllib.request.Request(url, data=json.dumps({"cert": cert, "sig": sig, "ts": ts}).encode(),
                                             method="POST", headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=8) as r:
                a = (json.loads(r.read() or b"{}") or {}).get("account")
    except Exception:
        return {}
    return a if isinstance(a, dict) and a.get("state") in ("opening", "failed", "none") else {}


def hub_answers():
    """Does the hub answer from here? None when there is no hub to ask (不接).

    换家 is for a home that is down, not for our own line (issue #3007): three
    failed connections while the lid was closed or the Wi-Fi changed are not the
    home's fault, and `--avoid <home>` then sent the person to another machine and
    a fresh view — the session they were in gone from the screen. Any HTTP answer
    (an error status too) is an answer; a timeout or no route is none.
    FLEET_THIN_HUB_PROBE_CMD is the seam (exit 0 = answers)."""
    seam = os.environ.get("FLEET_THIN_HUB_PROBE_CMD")
    if seam:
        try:
            return subprocess.call(shlex.split(seam), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=30) == 0
        except (OSError, subprocess.SubprocessError):
            return False
    try:
        fc = load("fleet-connect.py", "fleet_connect")
        hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or fc.load_hub_conf().get("url") or ""
    except (Exception, SystemExit):
        hub = ""
    if not hub:
        return None
    import urllib.error
    import urllib.request
    try:
        urllib.request.urlopen(hub.rstrip("/") + "/version", timeout=env_num("FLEET_THIN_HUB_PROBE_SECS", 4)).close()
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:
        return False


class LineWatch(threading.Thread):
    """Is the line back? (T690) — from a drop until the next view is up, one TCP
    connect every FLEET_THIN_PROBE_SECS (0.5) to where the last connection went
    (fleet-connect --argv's `probe`: the route's host:port, the hub for the
    relay) and to the hub; any answer = the line answers. `back` counts the
    times it went from no answer to an answer — the network returned — and the
    loop cuts short whatever it is waiting out (the backoff, a pick or an ssh
    started on the dead network), so the view is back within seconds of the
    network, never after the rest of a 30 s backoff. A line that answered all
    along (the home's view broke, not the network) leaves `back` at 0: the
    backoff as before. FLEET_THIN_LINE_PROBE_CMD is the seam (exit 0 = answers)."""

    def __init__(self, targets):
        threading.Thread.__init__(self, daemon=True)
        self.targets, self.ok, self.back, self.stopped = targets, None, 0, threading.Event()

    def answers(self):
        seam = os.environ.get("FLEET_THIN_LINE_PROBE_CMD")
        if seam:
            try:
                return subprocess.call(shlex.split(seam), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, timeout=5) == 0
            except (OSError, subprocess.SubprocessError):
                return False
        import socket
        for host, port in self.targets:
            try:
                socket.create_connection((host, port), timeout=env_num("FLEET_THIN_PROBE_TMO", 1)).close()
                return True
            except (OSError, ValueError):
                continue
        return False

    def run(self):
        while not self.stopped.is_set():
            ok = self.answers()
            if ok and self.ok is False:
                self.back += 1
            self.ok = ok
            self.stopped.wait(env_num("FLEET_THIN_PROBE_SECS", 0.5))


def line_targets(j):
    """(host, port) pairs LineWatch knocks on: the last route's own (fleet-connect
    --argv's `probe`), then the hub's."""
    out = []
    for t in (j or {}).get("probe") or []:
        try:
            out.append((str(t[0]), int(t[1])))
        except (TypeError, ValueError, IndexError):
            pass
    try:
        from urllib.parse import urlsplit
        hub = hub_conf()[0]
        u = urlsplit(hub) if hub else None
        if u and u.hostname:
            out.append((u.hostname, u.port or (443 if u.scheme == "https" else 80)))
    except ValueError:
        pass
    return out


def one_shot(argv):
    """`fleet-thin.py --run [--tty] [--home <m>] -- <word>…` (issue #3004, EPIC #2999
    C7): ONE command on the home machine, over a one-shot ssh of the same line a
    connection takes — no ControlMaster, nothing left behind — its exit code
    ours. `fleet ls / open / close / answer` and `fleet claude` ride it when this
    computer has no client tmux. --tty: a terminal there (a question to answer)."""
    tty_, home = False, ""
    while argv and argv[0] != "--":
        if argv[0] == "--tty":
            tty_, argv = True, argv[1:]
        elif argv[0] == "--home" and len(argv) > 1:
            home, argv = argv[1], argv[2:]
        else:
            sys.stderr.write("usage: fleet-thin.py --run [--tty] [--home <m>] -- <word>…\n")
            return 2
    words = argv[1:]
    if not words:
        sys.stderr.write("usage: fleet-thin.py --run [--tty] [--home <m>] -- <word>…\n")
        return 2
    j, _, why = pick(home)
    if j is None:
        sys.stderr.write("fleet · %s\n" % tr("thin_no_home_fmt", why))
        return 1
    remote = " ".join(shlex.quote(w) for w in words)
    if j.get("local"):
        cmd = ["sh", "-c", 'cd && exec sh -c "$1"', "fleet-thin", remote]
    else:
        a, h = list(j["argv"]), int(j["host"])
        cmd = a[:h] + ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-tt" if tty_ else "-T"] + [a[h], remote]
    tlog("run", home or str(j.get("home") or ""), str(j.get("route") or ""), "", "", "", "", words[0][-40:])
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        sys.stderr.write("fleet · %s\n" % e)
        return 1


# ---------------------------------------------------------------------------
# OSC 7502 — the home's words to this loop (约定 10)
# ---------------------------------------------------------------------------

class Osc7502:
    """The bytes from ssh toward the terminal, every OSC 7502 taken out."""

    def __init__(self, token):
        self.token = token
        self.held = b""

    def feed(self, data):
        """(bytes for the terminal, [(kind, {k: v})] with this connection's token, waiting)."""
        data = self.held + data
        self.held = b""
        out, events = b"", []
        while data:
            i = data.find(PFX)
            if i < 0:
                # a tail that could begin the prefix waits for the next read
                for k in range(min(len(PFX) - 1, len(data)), 0, -1):
                    if PFX.startswith(data[-k:]):
                        self.held = data[-k:]
                        data = data[:-k]
                        break
                out += data
                break
            out += data[:i]
            rest = data[i + len(PFX):]
            ends = [(j, 1) for j in [rest.find(b"\x07")] if j >= 0] + \
                   [(j, 2) for j in [rest.find(b"\x1b\\")] if j >= 0]
            if not ends:
                if len(rest) > OSC_MAX:   # never terminated: swallowed whole, never shown
                    data = b""
                else:
                    self.held = data[i:]
                    data = b""
                break
            j, n = min(ends)
            ev = self.parse(rest[:j])
            if ev:
                events.append(ev)
            data = rest[j + n:]
        return out, events, bool(self.held)

    def flush(self):
        """A held tail that turned out to be no 7502 (only a prefix of one)."""
        out, self.held = self.held, b""
        return out

    def parse(self, body):
        parts = body.decode("utf-8", "replace").split(";")
        kv = {}
        for p in parts[1:]:
            k, _, v = p.partition("=")
            kv[k] = v
        if not self.token or kv.get("token") != self.token:
            return None
        return parts[0], kv


# ---------------------------------------------------------------------------
# the terminal
# ---------------------------------------------------------------------------

def iterm_keys():
    """Write iTerm2's `fleet` profile (issue #3185, EPIC #3178 C7): only the panel
    key and the ⌘ chords of FLEET_KEYS_EXTRA (fleet-iterm-profile.py, nothing when
    it is current, nothing off a Mac with iTerm2) — every start, so a changed
    setting or a new version is in it before the window wears it."""
    if os.environ.get("FLEET_ITERM_KEYS", "1") == "0":
        return
    try:
        subprocess.run([sys.executable, os.path.join(BIN, "fleet-iterm-profile.py"), "write"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def keys_carried():
    """The client's FLEET_KEYS_EXTRA (+ a non-⌘ panel key) for the machine to bind
    (fleet_keys.carried), '' by default."""
    try:
        sys.path.insert(0, BIN)
        import fleet_keys
        return fleet_keys.carried()
    except Exception:
        return ""


def iterm_profile():
    """The profile to go back to when the fleet one goes on (约定 11), or ''."""
    back = os.environ.get("ITERM_PROFILE", "")
    if not back or back == "fleet" or os.environ.get("FLEET_ITERM_KEYS", "1") == "0":
        return ""
    if os.environ.get("TERM_PROGRAM") != "iTerm.app" and os.environ.get("LC_TERMINAL") != "iTerm2":
        return ""
    d = os.environ.get("FLEET_ITERM_DIR") or os.path.join(os.path.expanduser("~"), "Library", "Application Support",
                                                          "iTerm2", "DynamicProfiles")
    return back if os.path.exists(os.path.join(d, "fleet.json")) else ""


def write_out(data):
    while data:
        try:
            n = os.write(1, data)
        except InterruptedError:
            continue
        except BlockingIOError:
            select.select([], [1], [], 1)
            continue
        except OSError:
            return
        data = data[n:]


def writeall(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except InterruptedError:
            continue
        except BlockingIOError:
            select.select([], [fd], [], 1)
            continue
        data = data[n:]


def device_b64():
    """Where this client is (fleet-client-lease.py's `where`) as base64 JSON — said
    once per connection; the home renews the lease from it (约定 6, C8)."""
    try:
        w = load("fleet-client-lease.py", "fleet_client_lease").where(ask=os.isatty(0))
    except Exception:
        w = {}
    return base64.b64encode(json.dumps(w, ensure_ascii=False, sort_keys=True).encode()).decode()


def view_id():
    import platform
    dev = "".join(c if c.isalnum() or c == "-" else "-" for c in platform.node().split(".", 1)[0]) or "dev"
    return "%s-%06x" % (dev[:24], random.getrandbits(24))


def client_ver():
    """The `version=` of the install's .client-version (the hub's client_version when
    it was installed — stable's commit), "" when there is none."""
    for ln in version().splitlines():
        if ln.startswith("version="):
            return ln[len("version="):].strip()
    return ""


def version():
    try:
        with open(os.path.join(BIN, "..", ".client-version")) as f:
            return f.read().strip()
    except OSError:
        return ""


def install_home():
    """The install's bin through its link (<home>.versions/<v>/bin → <home>/bin):
    the path a new version is exec'd from."""
    root = os.path.dirname(BIN)
    if ".versions" + os.sep in root:
        root = root.split(".versions" + os.sep, 1)[0]
    return os.path.join(root, "bin")


# ---------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------

class Thin:
    def __init__(self, want, home, view, avoid="", local=False):
        self.want, self.home, self.view, self.avoid = want, home, view, avoid
        self.local = local      # --local: this machine is home — no hub, no ssh (#3006)
        self.resume = bool(view)
        self.tail = b""         # ssh's last output bytes: the drop's end= word (#4828)
        self.view = view or view_id()
        self.device = device_b64()
        self.base = None        # the last --argv answer (the upload rides it)
        self.cur = None         # (m, l, w) from the last valid `cur`
        self.quit = False
        if not local:
            iterm_keys()    # --local: the person's terminal is not this machine's (#2720)
        self.keys = keys_carried()
        self.back = iterm_profile()
        self.child = 0
        self.master = None
        self.attrs = termios.tcgetattr(0) if os.isatty(0) else None
        self.version = version()
        self.attachments = None
        self.saying = False     # a first-session line is being written over (#3054)
        self.firsts = 0         # first-session roads taken (FLEET_THIN_FIRST_ROUNDS)
        self.up_home = ""       # the home this loop was last up on (issue #3511)
        self.restart_end = 0.0  # waiting for that home's fleet to come back until then
        self.fwd = None         # the forwards `open` made (issue #3236)
        self.said = []          # lines a forward's thread queued for the terminal
        self.said_lock = threading.Lock()
        # a new client while connected (issue #4916): `fleet` already ran start
        # when it set this — skip the FIRST check only, never every later one
        self.just_updated = bool(os.environ.pop("FLEET_CLIENT_UPDATED", ""))
        self.poll_proc = None   # the background `fleet-client-update.sh poll`
        self.poll_at = time.time()
        self.staged = False     # poll said a newer client is staged
        self.updating = False   # this line was ended to switch to it
        self.update_hold = 0.0  # a switch that did not happen: no other until then
        self.last_key = time.time()
        self.conn_secs = 0.0    # how long the last connection lasted (view_broke)
        self.shell_pid = 0      # the home's command line (home_shell): in OUR process group
        # a drop holds the screen (T690): the view's last picture stays, a line over
        # its top row says 「正在重连」 until the view is drawn again
        self.drawn = False      # a view was drawn on this terminal (the alternate screen is up)
        self.held = False       # between connections with that picture still on screen
        self.watch = None       # LineWatch: is the line back?
        self.cut_back = False   # the last ssh was cut because the line came back
        self.rehomed_from = ""  # 换家: the home given up, said once on the new home's top line
        # the connection events sent to the hub (T689, bin/fleet_client_events.py)
        self.start_id = "%016x" % random.getrandbits(64)
        self.started = time.time()
        self.ever_up = False    # this start has drawn a view: a failure now is a reconnect's
        self.drop_at = 0.0      # when the line last dropped (the next up's reconnect time)

    def ev(self, kind, **f):
        """One connection event for the hub — metadata only; never blocks."""
        if self.local:
            return   # a managed machine's own `fleet`: no line between, nothing to say
        m = events()
        if m:
            m.record(kind, start=self.start_id, ver=self.version, **f)

    def ev_fail(self, reason, rc="", home="", route=""):
        self.ev("fail", phase="reconnect" if self.ever_up else "start", reason=reason, rc=rc,
                home=home or self.home, route=route)

    # -- the argv ---------------------------------------------------------
    def argv(self, reconnect):
        if self.local:
            # a managed machine's own `fleet` over ssh (issue #3006, C9): the view is
            # right here — the remote command runs as a child, never an ssh to itself
            m = load("fleet-connect.py", "fleet_connect").local_machine()
            return {"local": True, "machine": m["alias"], "argv": []}, "0", ""
        w, n0 = self.watch, (self.watch.back if self.watch else 0)
        return pick(self.home, self.avoid, reconnect, restart=(lambda: w.back > n0) if w else None)

    def remote(self, token, route):
        rbin = os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin"
        words = ["bash", rbin + "/fleet-remote-view.sh", "attach", "--thin", "--view", self.view]
        if self.resume:
            words.append("--resume")
        elif self.want:
            words += ["--want", self.want]
        words += ["--device", self.device, "--route", route or "-", "--token", token]
        # the person's extra keys ride the command's environment, not an option: a
        # home on an older version runs the attach as before (issue #3185)
        env = ["FLEET_KEYS_EXTRA=" + shlex.quote(self.keys)] if self.keys else []
        # which client this is (issue #3826): the home says 「请更新客户端」 when the
        # hub hands out a newer one — an older home ignores the variable
        cv = client_ver()
        if re.fullmatch(r"[0-9A-Za-z._-]{1,64}", cv):
            env.append("FLEET_CLIENT_VER=" + cv)
        # what this loop takes beyond `open` (issue #3541): the home's registry row
        # carries it as caps=, and fleet-show.sh sends a file as `show` only then
        env.append("FLEET_CLIENT_CAPS=show")
        # 换家 (T690): the home it gave up on — the new home's top line says so
        rh = getattr(self, "rehomed_from", "")
        if re.fullmatch(r"[0-9A-Za-z._-]{1,64}", rh):
            env.append("FLEET_CLIENT_REHOMED=" + rh)
        return " ".join(env + [shlex.quote(w) for w in words])

    def command(self, j, extra, remote):
        if j.get("local"):
            return ["sh", "-c", 'cd && exec sh -c "$1"', "fleet-thin", remote]
        a, h = list(j["argv"]), int(j["host"])
        return a[:h] + extra + [a[h], remote]

    # -- uploads ----------------------------------------------------------
    def say(self, text):
        """No bar of ours to write on: the log, and a terminal notification."""
        tlog("say", self.home, "", "", "", "", "", text)
        write_out(b"\x1b]9;" + text.replace("\x07", " ").encode("utf-8", "replace") + b"\x07")

    # -- open: a page here, a port forwarded (issue #3236) -----------------
    def queue_say(self, text):
        """From a thread: the terminal is the main loop's, so the line waits for it."""
        with self.said_lock:
            self.said.append(text)

    def drain_said(self):
        with self.said_lock:
            lines, self.said = self.said, []
        for t in lines:
            self.say(t)

    def forwards(self):
        if self.fwd is None:
            m = load("fleet_open_fwd.py", "fleet_open_fwd")
            self.fwd = m.Forwards(os.path.join(os.path.dirname(log_path()), "forwards.log"), say=self.queue_say)
            self.fwd.mod = m
            self.fwd.start()
        return self.fwd

    def opener(self, target):
        seam = os.environ.get("FLEET_THIN_OPEN_CMD")
        cmd = shlex.split(seam) if seam else (["open"] if sys.platform == "darwin" else ["xdg-open"])
        try:
            return subprocess.call(cmd + [target], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=20) == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def forward(self, lport, rport):
        """A second ssh to the home holding -L 127.0.0.1:lport → 127.0.0.1:rport, up;
        (close function, '') or (None, why)."""
        seam = os.environ.get("FLEET_THIN_FWD_CMD")
        if seam:
            cmd = shlex.split(seam) + [str(lport), str(rport)]
        else:
            j = self.base or {}
            if not j.get("argv"):
                return None, "no line to the home"
            a, h = list(j["argv"]), int(j["host"])
            cmd = a[:h] + ["-N", "-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                           "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
                           "-L", "127.0.0.1:%d:127.0.0.1:%d" % (lport, rport)] + [a[h]]
        try:
            p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            return None, str(e)

        def close():
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(5)
                except subprocess.TimeoutExpired:
                    p.kill()
        if not self.fwd.mod.up(lport, alive=lambda: p.poll() is None):
            close()
            return None, "the forward did not come up"
        return close, ""

    def ack(self, oid, ok, why=""):
        """The receipt of open <oid> (issue #3538): `fleet-open.sh --ack` on the home —
        one ssh on the line the loop already picked, or right here with --local."""
        if not isinstance(oid, str) or not re.fullmatch(r"[a-f0-9]{1,64}", oid):
            return
        words = ["--ack", oid, "ok" if ok else "fail", (why or "")[:200]]
        seam = os.environ.get("FLEET_THIN_ACK_CMD")
        j = self.base or {}
        if seam:
            cmd = shlex.split(seam) + words
        elif j.get("local"):
            cmd = ["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-open.sh")] + words
        elif j.get("argv"):
            rbin = os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin"
            remote = " ".join(shlex.quote(w) for w in ["bash", rbin + "/fleet-open.sh"] + words)
            cmd = self.command(j, ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-T"], remote)
        else:
            return
        try:
            subprocess.call(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=20)
        except (OSError, subprocess.SubprocessError):
            pass

    def open_req(self, kv):
        """`open` from the home: forward what needs it, open it here, say how it went."""
        try:
            d = json.loads(base64.b64decode(kv.get("j", "") + "==="))
        except (ValueError, TypeError):
            return
        if not isinstance(d, dict):
            return
        oid = d.get("id")
        ok, why = self.open_do(d)
        self.ack(oid, ok, why)

    def open_do(self, d):
        """(opened, why not)."""
        fw = self.forwards()
        who, home = str(d.get("who") or "?")[:80], self.home or "?"
        ttl = d.get("ttl") if isinstance(d.get("ttl"), int) and d.get("ttl") > 0 else None
        cport = d.get("cport") if isinstance(d.get("cport"), int) and 0 < d.get("cport") < 65536 else 0
        rport = d.get("rport") if isinstance(d.get("rport"), int) and 0 < d.get("rport") < 65536 else 0
        url = d.get("url") if isinstance(d.get("url"), str) else ""
        local = bool((self.base or {}).get("local"))
        if rport:
            path = d.get("path") if isinstance(d.get("path"), str) and d.get("path").startswith("/") else "/"
            scheme = "https" if d.get("scheme") == "https" else "http"
            lport = rport
            if not local:
                lport = rport if fw.mod.free(rport) else fw.mod.any_port()
                close, why = self.forward(lport, rport)
                if not close:
                    fw.fail(rport, home, who, why)
                    self.queue_say("fleet · 没能转发 %s:%d（%s）" % (home, rport, why))
                    return False, "forward to %s:%d failed: %s" % (home, rport, why)
                fw.add(rport, home, who, close, callback=False, lport=lport)
            url = "%s://127.0.0.1:%d%s" % (scheme, lport, path)
        elif cport and not local and not fw.held(cport):
            if not fw.mod.free(cport):
                fw.fail(cport, home, who, "busy")
                self.queue_say("fleet · 本机端口 %d 被占用，%s 的授权回调到不了会话，没有打开" % (cport, who))
                return False, "local port %d is busy" % cport
            close, why = self.forward(cport, cport)
            if not close:
                fw.fail(cport, home, who, why)
                self.queue_say("fleet · 没能转发授权回调端口 %d（%s）" % (cport, why))
                return False, "callback forward failed: %s" % why
            fw.add(cport, home, who, close, callback=True, ttl=ttl)
        if not url.startswith(("http://", "https://")):
            return False, "not an http(s) address"
        ok = self.opener(url)
        tlog("open", self.home, "", "", "", "", 0 if ok else 1,
             "cport=%d" % cport if cport else ("rport=%d" % rport if rport else "url"))
        return ok, "" if ok else "the browser opener failed"

    # -- show: a file saved here (issue #3541) ---------------------------
    def downloads(self):
        return os.path.expanduser(os.environ.get("FLEET_THIN_DOWNLOADS") or "~/Downloads")

    def fetch_cmd(self, oid):
        """The one ssh that streams the file the home registered under <oid>."""
        seam = os.environ.get("FLEET_THIN_FETCH_CMD")
        j = self.base or {}
        if seam:
            return shlex.split(seam) + [oid]
        if j.get("argv") and not j.get("local"):
            rbin = os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin"
            remote = " ".join(shlex.quote(w) for w in ["bash", rbin + "/fleet-show.sh", "--fetch", oid])
            return self.command(j, ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-T"], remote)
        return None

    def show_req(self, kv):
        """`show` from the home: fetch the file, save it, answer where it landed."""
        try:
            d = json.loads(base64.b64decode(kv.get("j", "") + "==="))
        except (ValueError, TypeError):
            return
        if not isinstance(d, dict):
            return
        oid = d.get("id")
        if not isinstance(oid, str) or not re.fullmatch(r"[a-f0-9]{1,64}", oid):
            return
        ok, why = self.show_do(d)
        self.ack(oid, ok, why)

    def show_do(self, d):
        """(saved, the path | why not)."""
        name = d.get("name") if isinstance(d.get("name"), str) else ""
        name = os.path.basename(name.replace("\\", "/"))
        if not name or name in (".", "..") or re.search(r"[\x00-\x1f]", name) or len(name) > 255:
            return False, "bad file name"
        size = d.get("size") if isinstance(d.get("size"), int) and not isinstance(d.get("size"), bool) else -1
        if (self.base or {}).get("local") and not os.environ.get("FLEET_THIN_FETCH_CMD"):
            # a managed machine's own `fleet` over ssh (#3006): the file is already on
            # this machine, and the person is on another device — nowhere else to put it
            return False, "the client runs on the home itself (fleet --local): the file stays where it is"
        cmd = self.fetch_cmd(d["id"])
        if not cmd:
            return False, "no line to the home"
        dest_dir = self.downloads()
        try:
            os.makedirs(dest_dir, exist_ok=True)
        except OSError as e:
            return False, "cannot make %s: %s" % (dest_dir, e.strerror)
        stem, ext = os.path.splitext(name)
        dest, n = os.path.join(dest_dir, name), 1
        while os.path.lexists(dest):
            dest, n = os.path.join(dest_dir, "%s (%d)%s" % (stem, n, ext)), n + 1
        part = os.path.join(dest_dir, ".%s.fleet-part" % name)
        try:
            with open(part, "wb") as out:
                p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.PIPE,
                                   timeout=float(env_num("FLEET_THIN_FETCH_SECS", 600)))
            got = os.path.getsize(part)
            if p.returncode != 0:
                why = (p.stderr or b"").decode("utf-8", "replace").strip().splitlines()
                raise RuntimeError("fetch failed (rc %d%s)" % (p.returncode, (": " + why[-1][:120]) if why else ""))
            if size >= 0 and got != size:
                raise RuntimeError("got %d of %d bytes" % (got, size))
            os.replace(part, dest)
        except (OSError, subprocess.SubprocessError, RuntimeError) as e:
            try:
                os.unlink(part)
            except OSError:
                pass
            why = str(e) if isinstance(e, RuntimeError) else type(e).__name__
            self.queue_say("fleet · 没收到 %s（%s）" % (name, why))
            tlog("show", self.home, "", "", "", "", 1, why[:80])
            return False, why
        who = str(d.get("who") or "?")[:80]
        self.queue_say("fleet · %s 发来 %s，存在 %s" % (who, name, dest))
        tlog("show", self.home, "", "", "", "", 0, "")
        return True, dest

    # -- one connection ---------------------------------------------------
    def connect_once(self, reconnect):
        """(rc, came_up, reason)."""
        t_pick = time.time()
        j, pick, why = self.argv(reconnect)
        if j is None:
            tlog("connect", self.home or "-", "", pick, "", "", 1, why)
            hc = "" if why == OPENING else home_code(t_pick)
            self.ev_fail(OPENING if why == OPENING else ("home:" + hc if hc else "pick"), 1)
            return 1, False, why
        self.base = j
        home = j.get("machine") or self.home or ""
        if not self.home and self.avoid and home and home != self.avoid:
            self.rehomed_from = self.avoid   # 换家 landed: said on the new home's top line
        if self.home and home != self.home:
            tlog("rehome", home, "", "", "", "", "", "from %s" % self.home)
            self.ev("rehome", home=self.home, to=home)
            self.resume = False   # a new home has no view of ours yet
        self.home = home
        route = (j.get("route") or {}).get("name") or ("local" if j.get("local") else "")
        token = "%032x" % random.getrandbits(128)
        extra = ["-tt", "-o", "ControlMaster=no", "-o", "ControlPath=none"] + alive_opts()
        cmd = self.command(j, extra, self.remote(token, route))
        t0 = time.time()
        self.drawn_at = (home, route, t0)
        rc, first_byte, first_view = self.pump(cmd, token, reconnect)
        up = first_view is not None or time.time() - t0 >= env_num("FLEET_THIN_UP_SECS", 10)
        tlog("connect", home, route, pick, ms(t0, first_byte) if first_byte else "",
             ms(t0, first_view) if first_view else "", rc, "quit" if self.quit else ("up" if up else "never up"),
             net=str(j.get("net") or ""), end="" if rc == 0 else ssh_end(self.tail))
        if up and not self.quit and not self.updating and rc != 0:
            self.drop_at = time.time()
            self.ev("drop", home=home, route=route, rc=rc, ms=ms(t0), reason=ssh_end(self.tail) or "rc%d" % rc)
        elif not up and not self.quit and not self.updating:
            self.ev_fail("no_fleet" if rc == NO_FLEET else (ssh_end(self.tail) or "never_up"), rc, home, route)
        if up:
            self.resume = True
        self.conn_secs = time.time() - t0
        return rc, up, ""

    # -- the 看台 keeps breaking: the home's command line (EPIC T651 C4) --
    def view_broke(self, rc, up, why):
        """This connection reached the home (ssh ran: no pick failure, not ssh's
        own 255) but the 看台 there did not hold: it never came up, or it ended
        with a code that is not a leave (0 · 129) within FLEET_THIN_CRASH_SECS (60)."""
        if why or self.quit or rc in (0, 129, 255, NO_FLEET):
            return False
        return not up or self.conn_secs < env_num("FLEET_THIN_CRASH_SECS", 60)

    def home_shell(self, why):
        """FLEET_THIN_VIEW_FAILS (3) broken 看台 in a row: no more reconnects into
        it — one plain interactive ssh to the same home on the same route and
        certificate (`fleet-connect.py --argv`), its login shell in $HOME with
        FLEET_NO_VIEW=1 (fleet-login.zsh starts no 看台 under it), after one line
        saying why and how back. The 看台 is tried again once that shell ends."""
        j = self.base
        if not j:
            return False
        home = self.home or j.get("machine") or "?"
        remote = 'cd && FLEET_NO_VIEW=1 exec "${SHELL:-/bin/sh}" -l'
        cmd = self.command(j, ["-tt", "-o", "ControlMaster=no", "-o", "ControlPath=none"] + alive_opts(), remote)
        tlog("shell", home, (j.get("route") or {}).get("name") or ("local" if j.get("local") else ""),
             "", "", "", "", why)
        self.restore_tty()
        self.held = False
        write_out(RESET + ("fleet · %s\r\n" % tr("thin_shell_fmt", why, home)).encode("utf-8", "replace")
                  + ("fleet · %s\r\n" % tr("thin_shell_back")).encode("utf-8", "replace"))
        old = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            p = subprocess.Popen(cmd, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
            self.shell_pid = p.pid
            rc = p.wait()
        except OSError as e:
            rc = 127
            write_out(("fleet · %s: %s\r\n" % (cmd[0], e.strerror)).encode("utf-8", "replace"))
        finally:
            self.shell_pid = 0
            signal.signal(signal.SIGINT, old)
        tlog("shell", home, "", "", "", "", rc, "the shell ended: the 看台 again")
        write_out(("fleet · %s\r\n" % tr("thin_shell_done_fmt", home)).encode("utf-8", "replace"))
        return True

    def pump(self, cmd, token, reconnect=False):
        """ssh under our pty: (rc, time of the first byte | None, time of the first valid cur | None).
        The child's pty does not echo (ssh puts it raw once the session is up; until
        then a key would print through it — #3061), and on a reconnect what the
        person types before the child's first byte is dropped: never sent to a
        session that is not there yet."""
        tty_in = self.attrs is not None
        if tty_in:
            master, slave = os.openpty()
            termios.tcsetattr(slave, termios.TCSANOW, quiet(self.attrs))
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
            except OSError:
                pass
        else:
            master, slave = os.openpty()
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                os.close(master)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                if slave > 2:
                    os.close(slave)
                for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM, signal.SIGWINCH,
                          signal.SIGPIPE, signal.SIGTSTP):
                    signal.signal(s, signal.SIG_DFL)
                os.execvp(cmd[0], cmd)
            except OSError as e:
                os.write(2, ("fleet-thin: %s: %s\r\n" % (cmd[0], e.strerror)).encode())
            os._exit(127)
        os.close(slave)
        self.child, self.master = pid, master
        osc = Osc7502(token)
        # A reconnect starts with no upload authority. The OSC parser keeps
        # running while a short-lived worker captures/hashes/transfers files.
        self.cur = None
        self.cur_generation = ""
        self.selection = 0
        uploads = None
        if os.environ.get("FLEET_CLIENT_PASTE", "1") != "0":
            up = load("fleet-thin-upload.py", "fleet_thin_upload")
            uploads = up.Input(lambda: {
                "base": self.base, "cur": self.cur, "generation": self.cur_generation,
                "selection": self.selection, "token": token, "view": self.view,
                "rbin": os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin",
            }, self.say)
        self.attachments = uploads
        pending = bytearray()  # bounded PTY backpressure, never a blocking write
        os.set_blocking(master, False)
        def enqueue(data):
            if len(pending) + len(data) > 128 << 10:
                pending.clear()
                if uploads:
                    uploads.cancel("终端输入积压，附件已取消")
                self.say("fleet · 终端输入积压；未送达的输入已丢弃，请重新输入")
            else:
                pending.extend(data)
        first_byte = first_view = None
        self.tail = b""
        self.cut_back = False
        held = bytearray()

        def emit(b):
            """Onto the terminal — but while the dropped view's picture is held,
            only once the view draws (it enters the alternate screen, says `cur`,
            or writes more than a screen's worth): ssh's 「connect … unreachable」
            never scrolls over the picture (T690)."""
            if not self.held or not b:
                write_out(b)
                return
            held.extend(b)
            if b"\x1b[?1049h" in held or len(held) > 8192:
                self.held = False
                write_out(bytes(held))
                held.clear()
        self.emit_held = lambda: (write_out(bytes(held)), held.clear()) if held else None
        spawned, back0 = time.time(), (self.watch.back if self.watch else 0)
        out_wait = 0.0
        st = None
        if tty_in:
            try:
                termios.tcflush(0, termios.TCIFLUSH)   # what was typed while the line was down
            except termios.error:
                pass
            tty.setraw(0, termios.TCSANOW)
        try:
            while True:
                done, s_ = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    st = s_
                    break
                tmo = 0.02 if (out_wait or (uploads and uploads.busy)) else 0.5
                if (reconnect and first_byte is None and not self.cut_back and self.watch
                        and self.watch.back > back0 and time.time() - spawned > 1):
                    # an ssh started on the dead network waits out its ConnectTimeout:
                    # the line is back — cut it and connect again now (T690)
                    self.cut_back = True
                    tlog("back", self.home or "-", "", "", ms(spawned), "", "", "the line came back: cutting the ssh")
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except OSError:
                        pass
                try:
                    r, _, _ = select.select([0, master], [master] if pending else [], [], tmo)
                except InterruptedError:
                    continue
                now = time.time()
                if out_wait and now - out_wait > 0.05:
                    emit(osc.flush())
                    out_wait = 0.0
                if master in r:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        data = b""
                    if not data:
                        # the child closed its side: wait for it
                        _, st = os.waitpid(pid, 0)
                        break
                    if first_byte is None:
                        first_byte = now
                    self.tail = (self.tail + data)[-1024:]
                    out, events, waiting = osc.feed(data)
                    emit(out)
                    out_wait = (out_wait or now) if waiting else 0.0
                    for kind, kv in events:
                        if kind == "cur":
                            if pending:
                                pending.clear()
                                self.say("fleet · 会话目标已改变；未送达的输入已丢弃")
                            self.cur = (kv.get("m", ""), kv.get("l", ""), kv.get("w", ""))
                            self.cur_generation = kv.get("g", "")
                            self.selection += 1
                            if uploads:
                                uploads.cancel("会话目标已改变，附件未插入")
                            if first_view is None:
                                first_view = now
                                self.drawn, self.held = True, False
                                self.emit_held()
                                self.stop_watch()
                                # written now, not when the connection ends: a
                                # reader (the onboarding drill, #3155) learns the
                                # view is up while it is up
                                h, rt, t0 = getattr(self, "drawn_at", ("", "", now))
                                tlog("drawn", h or "-", rt, "", ms(t0, first_byte) if first_byte else "",
                                     ms(t0, now), "", "")
                                if self.drop_at:
                                    self.ev("up", phase="reconnect", home=h, route=rt, ms=ms(self.drop_at, now))
                                elif not self.ever_up:
                                    self.ev("up", phase="start", home=h, route=rt, ms=ms(self.started, now))
                                else:
                                    self.ev("up", home=h, route=rt, ms=ms(t0, now))
                                self.ever_up, self.drop_at = True, 0.0
                        elif kind == "quit":
                            self.quit = True
                            pending.clear()
                            if uploads:
                                uploads.cancel("连接结束，附件已取消")
                        elif kind == "open":
                            threading.Thread(target=self.open_req, args=(kv,), daemon=True).start()
                        elif kind == "show":
                            threading.Thread(target=self.show_req, args=(kv,), daemon=True).start()
                if self.said:
                    self.drain_said()
                self.update_tick(now, bool(pending) or bool(uploads and uploads.busy))
                if 0 in r:
                    self.last_key = now
                    try:
                        data = os.read(0, 65536)
                    except OSError as e:
                        if e.errno not in (errno.EIO, errno.EBADF):
                            continue
                        data = b""
                    if not data:
                        # the terminal is gone: as a SIGHUP
                        self.hangup(signal.SIGHUP, None)
                    if reconnect and first_byte is None and b"\x03" not in data:
                        continue   # the line still down: a mouse report / a key goes nowhere (⌃C still stops the ssh)
                    if pending and b"\x03" in data:
                        pending.clear()
                        # Input.feed consumes it if an upload owns the key.
                        # Never turn a cancelled upload into a remote interrupt.
                        data = b"\x03"
                    enqueue(uploads.feed(data) if uploads else data)
                if uploads:
                    # Output/control events and Ctrl+C win a completion race.
                    enqueue(uploads.poll())
                if pending:
                    try:
                        n = os.write(master, pending[:4096])
                        del pending[:n]
                    except BlockingIOError:
                        pass
                    except OSError:
                        pending.clear()
                        if uploads:
                            uploads.cancel("连接结束，附件已取消")
        finally:
            if uploads:
                uploads.close()
            self.attachments = None
            self.cur = None
            self.child, self.master = 0, None
            # cooked again, but echo stays off: the loop is between connections until
            # the next pump's setraw — a key or a mouse report in the meantime (the hub
            # probe, the next fleet-connect.py) must not print (#3061); run() restores
            self.mute()
            try:
                os.close(master)
            except OSError:
                pass
        return rc_of(st), first_byte, first_view

    # -- signals ----------------------------------------------------------
    def mute(self):
        """Between two connections (issue #3007's drill): the terminal echoes
        nothing — a mouse report or a key typed while the line is down would
        otherwise print as garbage — and ⌃C still stops the loop (ISIG kept).
        What was typed meanwhile is dropped before the next connection starts
        (pump's flush), never sent to the session."""
        if self.attrs is None:
            return
        try:
            termios.tcsetattr(0, termios.TCSANOW, quiet(self.attrs))
        except termios.error:
            pass

    def restore_tty(self):
        if self.attrs is not None:
            try:
                termios.tcsetattr(0, termios.TCSADRAIN, self.attrs)
            except termios.error:
                pass

    def hangup(self, n, _f):
        """The terminal closed (SIGHUP) or we were told to stop: the ssh goes with
        us, nothing stays."""
        if self.attachments:
            self.attachments.close()
        if self.shell_pid:
            try:
                os.kill(self.shell_pid, signal.SIGHUP)   # never killpg: its group is ours
            except OSError:
                pass
        if self.child:
            try:
                os.killpg(self.child, signal.SIGHUP)
                deadline = time.monotonic() + .2
                while time.monotonic() < deadline:
                    if os.waitpid(self.child, os.WNOHANG)[0]:
                        break
                    time.sleep(.01)
                else:
                    os.killpg(self.child, signal.SIGKILL)
                    os.waitpid(self.child, 0)
            except OSError:
                pass
        if self.fwd:
            self.fwd.close_all()
        self.restore_tty()
        tlog("end", self.home, "", "", "", "", 128 + n, "signal %d" % n)
        self.ev("quit", home=self.home, rc=128 + n, reason="signal")
        if n != signal.SIGHUP:
            self.profile(False)
        os._exit(128 + n)

    def profile(self, on):
        if self.back:
            write_out(b"\x1b]1337;SetProfile=" + (b"fleet" if on else self.back.encode()) + b"\x07")

    # -- a new client while connected (issue #4916) -----------------------
    def poll_cmd(self):
        seam = os.environ.get("FLEET_THIN_POLL_CMD")
        if seam:
            return shlex.split(seam)
        upd = os.path.join(BIN, "fleet-client-update.sh")
        return [upd, "poll"] if version() and os.access(upd, os.X_OK) else []

    def update_tick(self, now, busy):
        """Called by pump each turn: run the poll in the background now and then;
        once a newer client is staged and the person idle, end this line so run()
        switches to it (the view kept)."""
        if self.local or self.updating or now < self.update_hold:
            return
        p = self.poll_proc
        if p is not None:
            rc = p.poll()
            if rc is None:
                if now - self.poll_at > 900:   # a stage never takes this long
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except OSError:
                        pass
                return
            self.poll_proc = None
            self.staged = self.staged or rc == 10
        elif not self.staged and now - self.poll_at >= env_num("FLEET_THIN_POLL_SECS", 120):
            self.poll_at = now
            cmd = self.poll_cmd()
            if cmd:
                try:
                    self.poll_proc = subprocess.Popen(
                        cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        start_new_session=True)
                except OSError:
                    self.poll_proc = None
        if (self.staged and not busy and self.child
                and now - self.last_key >= env_num("FLEET_THIN_UPDATE_IDLE", 30)):
            self.updating = True
            tlog("update", self.home, "", "", "", "", "", "a newer client is staged: switching to it")
            try:
                os.killpg(self.child, signal.SIGHUP)
            except OSError:
                pass

    # -- between connections: hold the screen, watch the line (T690) -------
    def start_watch(self):
        """A drop: knock on the last connection's line until the next view is up."""
        if self.local:
            return
        if self.watch is None:
            self.watch = LineWatch(line_targets(self.base))
            self.watch.start()

    def stop_watch(self):
        if self.watch is not None:
            self.watch.stopped.set()
            self.watch = None

    def status(self, text, row=1):
        """A word between two connections. With the view's picture held (a drop
        after it was drawn) it is written over that picture's top rows — reverse
        video, the cursor put back — so nothing scrolls and nothing is cleared;
        else one line, as before."""
        line = ("fleet · %s" % text).encode("utf-8", "replace")
        if self.held:
            write_out(b"\x1b7\x1b[%d;1H\x1b[0;7m\x1b[2K " % row + line + b" \x1b[0m\x1b8")
        else:
            write_out(line + b"\r\n")

    def unhold(self):
        """Leave the held picture: the old full reset, before lines that scroll."""
        if self.held:
            write_out(RESET)
            self.held = False

    def wait_out(self, secs):
        """The backoff — ended early the moment LineWatch sees the line come back."""
        end, n0 = time.time() + secs, (self.watch.back if self.watch else 0)
        while time.time() < end:
            if self.watch and self.watch.back > n0:
                tlog("back", self.home or self.avoid or "-", "", "", "", "", "",
                     "the line came back: reconnecting now")
                return
            time.sleep(min(0.1, max(0.0, end - time.time())))

    def maybe_update(self):
        """A new client between two connections: exec it, view and home kept."""
        seam = os.environ.get("FLEET_THIN_UPDATE_CMD")
        upd = shlex.split(seam) if seam else (
            [os.path.join(BIN, "fleet-client-update.sh"), "start"]
            if os.access(os.path.join(BIN, "fleet-client-update.sh"), os.X_OK) else [])
        rc = 0
        if upd and not self.local and not self.just_updated:   # --local: the machine's runtime moves it
            try:
                rc = subprocess.call(upd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=60)
            except (OSError, subprocess.SubprocessError):
                rc = 0
        self.just_updated = False
        if rc != 3 and version() == self.version:
            return False
        me = os.path.join(install_home(), "fleet-thin.py")
        if not os.path.exists(me):
            me = os.path.abspath(__file__)
        tlog("exec", self.home, "", "", "", "", "", "%s → %s" % (self.version or "-", version() or "-"))
        args = [sys.executable or "python3", me, "--view", self.view]
        if self.local:
            args.append("--local")
        elif self.home:
            args += ["--home", self.home]
        if self.want and not self.resume:
            args.append(self.want)
        os.environ["FLEET_CLIENT_UPDATED"] = "1"
        self.stop_watch()
        self.unhold()
        if self.fwd:
            self.fwd.close_all("新版本客户端")
        self.profile(False)
        self.restore_tty()   # echo back first: the new client reads these attrs as the terminal's own
        os.execv(args[0], args)

    # -- no fleet of yours there: the first session (#3054) --------------
    def first_say(self, text, keep=False):
        """One line of the first-session road; keep=False writes over the last one."""
        write_out(("\r\x1b[K" if self.saying else "").encode() + ("fleet · %s" % text).encode("utf-8", "replace")
                  + (b"\r\n" if keep else b""))
        self.saying = not keep

    def first_failed(self, text, ask=""):
        """没开出来 · 原因 · 下一步 (who to ask, when the hub names them): False."""
        nxt = tr("thin_first_ask_fmt", ask) if ask else tr("thin_first_next", fleet_cmd(), fleet_cmd())
        self.first_say(tr("thin_first_failed"), keep=True)
        for line in (tr("thin_first_why_fmt", " ".join(str(text or "-").split())[:200]), tr("thin_first_next_fmt", nxt)):
            write_out(("  %s\r\n" % line).encode("utf-8", "replace"))
        tlog("first", self.home or "-", "", "", "", "", 1, text)
        return False

    def first_session(self, why):
        """The home had no fleet session of yours (remote view rc 3) or the hub is
        still opening your first login: the old client's first-session road
        (fleet-shell.sh first_home, #2264 / #2941) — ONE ask, `fleet-client-place.sh
        - home --agent claude`, signed by a lease this loop takes for it and gives
        back; while the hub says opening, its progress and the ask again every
        FLEET_THIN_FIRST_RETRY (10) s, at most FLEET_HOME_FIRST_OPENING_MAX (40 min);
        once it stops (the login is made, its fleet not yet reported — #2941 /
        #3062) the ask again for FLEET_THIN_FIRST_SETTLE (600 s, the hub's own
        settle), then a failure naming why; anything else is tried twice. Placed → home is that machine and the first
        connection lands on the session (--want <worker_id>): True. Not → three
        lines (没开出来 · 原因 · 下一步, who to ask) and False — never a backoff
        against a machine with no session."""
        import shutil
        import tempfile
        tlog("first", self.home or "-", "", "", "", "", "", why)
        d = tempfile.mkdtemp(prefix="fleet-thin-first.")
        env = dict(os.environ, FLEET_CLIENT_DIR=d, FLEET_CLIENT_KEY_FILE=os.path.join(d, "client.key"),
                   FLEET_PLACE_RESULT=os.path.join(d, "result.json"))
        lease_cmd = shlex.split(os.environ.get("FLEET_CLIENT_LEASE_CMD") or "") or \
            [sys.executable or "python3", os.path.join(BIN, "fleet-client-lease.py")]
        place_cmd = shlex.split(os.environ.get("FLEET_THIN_PLACE_CMD") or "") or \
            ["bash", os.path.join(BIN, "fleet-client-place.sh")]
        retry = env_num("FLEET_THIN_FIRST_RETRY", 10)
        deadline = time.time() + env_num("FLEET_HOME_FIRST_OPENING_MAX", 2400)
        settle = env_num("FLEET_THIN_FIRST_SETTLE", 600)
        lease, tries, said, acct = "", 0, "", {}
        wait_end = 0.0   # a refusal that heals by itself is waited on until then (#4829)
        # The hub opened a login for us (it said opening, at the pick or since):
        # once it stops saying so, the login exists but its fleet may not have
        # reported yet, and the place keeps answering 「没有你的登录」 meanwhile —
        # the old client waits that out (#2941), so this does too, up to the hub's
        # own settle (openingSettle, 10 min) from the moment opening ended (#3062).
        opened, machine, settle_end = why == OPENING, "", 0.0

        def run(cmd, timeout):
            try:
                r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=timeout)
                return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
            except (OSError, subprocess.SubprocessError) as e:
                return 1, "", str(e)

        def failed(text):
            return self.first_failed(text, acct.get("ask") or "")

        self.saying = False
        try:
            self.first_say(tr("thin_first_start"))
            rc, out, err = run(lease_cmd + ["acquire"], 60)
            f = (out.strip().splitlines() or [""])[-1].split("\t")
            if rc != 0 or f[0] != "active" or len(f) < 2 or not f[1]:
                return failed(tr("thin_first_no_lease_fmt", f[0] if f[0] else (err.strip().splitlines() or ["exit %d" % rc])[-1]))
            lease = f[1]
            with open(os.path.join(d, "client.lease"), "w") as fh:
                fh.write(lease + "\n")
            while True:
                rc, out, err = run(place_cmd + ["-", "home", "--agent", "claude", "--node", "auto"], 600)
                line = (out.strip().splitlines() or [""])[-1]
                head = line.split("\t", 1)[0].split()
                try:
                    with open(env["FLEET_PLACE_RESULT"]) as fh:
                        res = json.load(fh)
                except (OSError, ValueError):
                    res = {}
                if rc == 0 and len(head) >= 2 and head[0] in ("REMOTE", "RESUME", "LOCAL"):
                    m = res.get("machine") or head[1]
                    wid = res.get("worker_id") or (head[4] if head[0] == "REMOTE" and len(head) > 4 else
                                                   head[2] if head[0] == "RESUME" and len(head) > 2 else "")
                    self.first_say(tr("thin_first_placed_fmt", m), keep=True)
                    tlog("first", m, "", "", "", "", 0, line)
                    self.home, self.avoid, self.resume = m, "", False
                    self.want = wid or self.want
                    return True
                said = (line.split("\t", 1)[1] if "\t" in line else line) or \
                    (err.strip().splitlines() or ["exit %d" % rc])[-1]
                acct = account_state()
                if acct.get("state") == "opening":
                    opened, settle_end = True, 0.0
                    machine = acct.get("machine") or machine
                    if time.time() >= deadline:
                        return failed(tr("thin_first_timeout_fmt", "%d" % (env_num("FLEET_HOME_FIRST_OPENING_MAX", 2400) // 60)))
                    self.first_say(tr("thin_first_opening_fmt", acct.get("machine") or "?", acct.get("eta_s") or "?"))
                    time.sleep(retry)
                    continue
                if acct.get("state") == "failed":
                    return failed(acct.get("why") or said)
                if opened:
                    # opened, its fleet not reported yet: wait for it, never forever
                    now = time.time()
                    settle_end = settle_end or now + settle
                    if now >= settle_end or now >= deadline:
                        return failed(tr("thin_first_settle_timeout_fmt", machine or "?",
                                         "%d" % max(1, settle // 60), said))
                    self.first_say(tr("thin_first_settle_fmt", machine or "?", "%d" % (settle_end - now)))
                    time.sleep(retry)
                    continue
                heals = first_heals(said)
                if heals:
                    # the machine is coming up (or the hub said retry): wait, said, bounded
                    now = time.time()
                    wait_end = wait_end or now + env_num("FLEET_THIN_FIRST_WAIT", 300)
                    if now < wait_end and now < deadline:
                        self.first_say(tr("thin_first_wait_fmt", heals, "%d" % (wait_end - now)))
                        time.sleep(retry)
                        continue
                tries += 1
                if tries >= 2 or heals:
                    return failed(acct.get("why") or said)
                self.first_say(tr("thin_first_retry_fmt", "%g" % retry))
                time.sleep(retry)
        finally:
            if lease:
                run(lease_cmd + ["release", "--lease", lease], 30)
            shutil.rmtree(d, ignore_errors=True)
            if self.saying:
                write_out(b"\r\n")
                self.saying = False

    def run(self):
        for s in (signal.SIGHUP, signal.SIGTERM):
            signal.signal(s, self.hangup)
        signal.signal(signal.SIGWINCH, self.resize)
        backoff = [env_num("x", x) for x in
                   (os.environ.get("FLEET_THIN_BACKOFF") or "1,2,4,8,16,30").split(",") if x.strip()] or [1.0]
        rehome = int(env_num("FLEET_THIN_REHOME_AFTER", 3))
        self.profile(True)
        self.ev("start")
        k = fails = broke = 0
        offline = False
        try:
            while True:
                rc, up, why = self.connect_once(k > 0)
                if up:
                    self.rehomed_from = ""   # said once, on the attach that landed
                if self.updating and not self.quit:
                    # we ended this line ourselves for a newer client (#4916): switch,
                    # exec it onto the same view; not switched ⇒ back on, held a while
                    self.updating = self.staged = self.just_updated = False
                    self.mute()
                    self.held = False
                    write_out(RESET + ("fleet · %s\r\n" % tr("thin_update_switch")).encode("utf-8", "replace"))
                    if self.maybe_update() is False:
                        self.update_hold = time.time() + env_num("FLEET_THIN_UPDATE_HOLD", 3600)
                        tlog("update", self.home, "", "", "", "", "", "not switched: holding the next try")
                    fails, k = 0, 0
                    continue
                if self.quit or (rc == 0 and not why):
                    tlog("quit", self.home, "", "", "", "", rc, "quit" if self.quit else "detach")
                    self.ev("quit", home=self.home, rc=rc, reason="quit" if self.quit else "detach")
                    return 0
                if up and self.drawn and not why:
                    # the view was on screen and the line went: keep its picture (T690)
                    write_out(MOUSE_OFF)
                    self.held = True
                self.start_watch()
                if not up and rc == NO_FLEET and self.home and self.home == self.up_home and not self.local:
                    # the home we were just on has no fleet now: its tmux is restarting
                    # (an update, fleet-sessions-snapshot.sh save → kill-server → restore,
                    # issue #3511) — wait for it, bounded, and reconnect to the same view
                    # (--resume finds the session by its @fleet_id); never the
                    # first-session road, which asks the hub for a NEW session
                    now = time.time()
                    self.restart_end = self.restart_end or now + env_num("FLEET_THIN_HOME_RESTART_SECS", 300)
                    if now < self.restart_end:
                        self.mute()
                        self.status(tr("thin_home_restart_fmt", self.home, "%d" % (self.restart_end - now)))
                        tlog("restart", self.home, "", "", "", "", rc, "no fleet on the home we were on: waiting")
                        time.sleep(env_num("FLEET_THIN_HOME_RESTART_POLL", 3))
                        continue
                    self.up_home = ""   # it did not come back: the old road below
                if not up and not self.local and (why == OPENING or rc == NO_FLEET):
                    # no fleet of yours there (rc 3) or none yet (the hub is opening
                    # one): the first session, never a backoff against it (#3054)
                    self.firsts += 1
                    self.stop_watch()
                    self.unhold()
                    there = why or "no fleet session is live on %s" % (self.home or "?")
                    if rc == NO_FLEET:
                        # say which login was empty, never rotate homes silently (#3049)
                        write_out(("fleet · %s\r\n" % tr("thin_no_fleet_fmt", self.home or "?",
                                                           (self.base or {}).get("login") or "?")).encode("utf-8", "replace"))
                    if self.firsts > int(env_num("FLEET_THIN_FIRST_ROUNDS", 3)):
                        self.first_failed(tr("thin_first_rounds_fmt", self.home or "?", self.firsts - 1))
                    if self.firsts > int(env_num("FLEET_THIN_FIRST_ROUNDS", 3)) or not self.first_session(there):
                        tlog("quit", self.home, "", "", "", "", 1, "no first session")
                        self.ev_fail("first_session", 1)
                        self.ev("quit", home=self.home, rc=1, reason="no_first_session")
                        return 1
                    fails, k = 0, 0
                    continue
                if not up and rc == 1 and why and why != OPENING and self.avoid and not self.home and not self.local:
                    # 换家 found no other machine (`--avoid` exit 1): the home it left is
                    # still the only one — back to it, its view and the backoff, never
                    # asking the hub for nothing until the person gives up (#4829)
                    self.home, self.avoid = self.avoid, ""
                    self.resume = self.up_home == self.home
                    tlog("rehome", self.home, "", "", "", "", "", "no other home: back to %s" % self.home)
                    self.ev("rehome", home=self.home, to=self.home, reason="no_other")
                    self.status(tr("thin_rehome_back_fmt", self.home), 2)
                broke = broke + 1 if self.view_broke(rc, up, why) else 0
                if broke >= int(env_num("FLEET_THIN_VIEW_FAILS", 3)):
                    # the line is fine, the 看台 is not: the home's command line, not
                    # another reconnect into it (nor 换家 — the home answers)
                    why_v = tr("thin_view_never_fmt", broke) if not up else tr("thin_view_crash_fmt", broke, rc)
                    self.home_shell(why_v)
                    broke = fails = k = 0
                    self.mute()
                    continue
                if up:
                    fails, k, self.firsts = 0, 0, 0
                    self.up_home, self.restart_end = self.home, 0.0
                elif self.cut_back:
                    k = 0   # cut because the line came back: no failure, no wait (T690)
                else:
                    fails += 1
                k += 1
                if fails >= rehome and self.home and not self.local and hub_answers() is False:
                    # the hub does not answer either: our own line is down, not the home —
                    # stay, keep the view, and need one more failure with the hub back (#3007)
                    tlog("offline", self.home, "", "", "", "", "", "the hub does not answer either: keeping %s" % self.home)
                    self.ev("offline", home=self.home)
                    fails, offline = rehome - 1, True
                elif fails >= rehome and offline:
                    fails, offline = rehome - 1, False   # the hub back: one more try at the home first
                go_now = False
                if fails >= rehome and self.home and not self.local:   # --local has no other home
                    self.avoid, self.home, fails = self.home, "", 0
                    self.resume = False   # a new home has no view of ours yet
                    go_now = True         # the other machine is asked at once, no backoff first (T690)
                    tlog("rehome", "", "", "", "", "", "", "asking for a home other than %s" % self.avoid)
                if not why and not self.held:
                    write_out(RESET)
                self.mute()
                if self.cut_back:
                    continue
                wait = 0 if go_now else backoff[min(k - 1, len(backoff) - 1)]
                if not self.home and self.avoid:
                    msg = tr("thin_rehoming_fmt", self.avoid)
                else:
                    msg = tr("thin_reconnect", self.home or self.avoid or "?", "%g" % wait, k)
                if why:
                    msg = why + " — " + msg
                self.status(msg)
                if fails == rehome - 1 and not offline:   # the home about to be given up: how to tell the hub why
                    self.status(tr("thin_debug_hint"), 2)
                self.wait_out(wait)
                self.maybe_update()
        except KeyboardInterrupt:
            tlog("quit", self.home, "", "", "", "", 130, "^C between connections")
            self.ev("quit", home=self.home, rc=130, reason="interrupt")
            return 130
        finally:
            self.stop_watch()
            self.unhold()        # ended on a held picture: leave the alternate screen
            if self.fwd:
                self.fwd.close_all()
            self.restore_tty()   # echo back, if it ended between two connections (mute)
            self.profile(False)
            path_hint()

    def resize(self, *_):
        """SIGWINCH: the terminal's size onto the child's pty (the kernel tells ssh)."""
        if self.master is None:
            return
        try:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
        except OSError:
            pass


def fleet_cmd():
    """How to type `fleet` in THIS terminal: the word, or — right after the
    install line put its bin dir on PATH only in the rc file
    (FLEET_INSTALL_PATH_NEW, fleet-install.sh) — its full path (#3062)."""
    d = os.environ.get("FLEET_INSTALL_PATH_NEW") or ""
    if not d:
        return "fleet"
    home = os.path.expanduser("~")
    d = "~" + d[len(home):] if home and home != "/" and d.startswith(home + "/") else d
    return os.path.join(d, "fleet")


def path_hint():
    """The terminal the installer ran in does not have `fleet` on its PATH yet
    (the rc file is read by the next shell): say how to get it, once, on the
    way out — else the newcomer's next `fleet` is 「command not found」 (#3062)."""
    if os.environ.get("FLEET_INSTALL_PATH_NEW"):
        sh = os.path.basename(os.environ.get("SHELL") or "") or "zsh"
        write_out(("fleet · %s\r\n" % tr("thin_path_hint_fmt", sh, fleet_cmd())).encode("utf-8", "replace"))


def rc_of(st):
    if st is None:
        return 1
    if os.WIFEXITED(st):
        return os.WEXITSTATUS(st)
    if os.WIFSIGNALED(st):
        return 128 + os.WTERMSIG(st)
    return 1


def main(argv):
    if argv[:1] == ["--run"]:
        return one_shot(argv[1:])
    import argparse
    ap = argparse.ArgumentParser(prog="fleet --thin", description=__doc__.split("\n\n")[0])
    ap.add_argument("session", nargs="?", default="", help="the session to open first (default: the last one)")
    ap.add_argument("--home", default="", help="this machine is home (default: the hub's pick)")
    ap.add_argument("--local", action="store_true",
                    help="this machine is home: no hub, no ssh (a managed machine's own `fleet`)")
    ap.add_argument("--view", default="", help=argparse.SUPPRESS)   # an exec'd new version keeps its view
    a = ap.parse_args(argv)
    if not (os.isatty(0) and os.isatty(1)) and os.environ.get("FLEET_THIN_NO_TTY_OK") != "1":
        sys.stderr.write("fleet · %s\n" % tr("thin_no_tty"))
        return 2
    return Thin(a.session, a.home, a.view, local=a.local).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
