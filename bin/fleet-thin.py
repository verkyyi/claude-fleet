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

When it ends: ⌘Q (quit) or ssh exit 0 (a detach) — the iTerm2 profile goes
back (约定 11) and this exits 0. Anything else — the line dropped, the lid
closed — one line 「和 <home> 的连接断了，N 秒后重连（第 k 次）」 and a reconnect
after 1 · 2 · 4 … 30 s to the SAME view (`--resume`). Three connections in a
row that never came up (no valid 7502 and gone within FLEET_THIN_UP_SECS):
the hub is asked for another online machine to be home (`--avoid <home>`) —
unless the hub does not answer either (issue #3007): then it is this computer's
own line that is down, the home is kept and the view with it.
Between two connections a new client version (the install's .client-version,
`fleet-client-update.sh start` → 3) is exec'd in place, view and home kept.

`--local` (issue #3006, EPIC #2999 C9): this machine is home — a managed
machine's own `fleet`, typed over ssh from a phone. No hub is asked and no ssh
is run: the view's command is this loop's child, under the same pty filter
(fleet-connect.py --argv answers the same `local` when the hub's pick is this
machine and this login — no ssh back to itself either). No 换家, no update of
its own (the machine's runtime moves it).

thin.log — TSV, one line per connection, fields only ever added at the end
(docs/CLIENT-LOGS.md; C10 reads it):
    time(UTC)  event  home  route  pick_ms  ssh_ms  first_ms  rc  reason
event: connect (pick_ms = fleet-connect --argv, ssh_ms = spawn → the first
byte back, first_ms = spawn → the first valid `cur`: the view drawn) · rehome ·
upload · exec · quit · offline (no 换家: the hub did not answer either) · run (`--run`: one command on the home, issue #3004 —
reason = its first word).

Knobs: FLEET_THIN_UP_SECS (10), FLEET_THIN_BACKOFF ("1,2,4,8,16,30"),
FLEET_THIN_REHOME_AFTER (3), FLEET_THIN_HUB_PROBE_SECS (4), FLEET_REMOTE_BIN (.claude/fleet/bin),
FLEET_CLIENT_PASTE=0 (drops and ⌃V byte for byte), FLEET_ITERM_KEYS=0,
FLEET_THIN_LOG. Seams (tests): FLEET_THIN_ARGV_CMD (in place of
`fleet-connect.py --argv`), FLEET_THIN_UPDATE_CMD (in place of
`fleet-client-update.sh start`), FLEET_CLIENT_CLIP_CMD (the clipboard),
FLEET_THIN_HUB_PROBE_CMD (in place of asking the hub's /version before 换家).
Standard library only.
"""
import base64
import errno
import fcntl
import importlib.util
import json
import os
import random
import select
import shlex
import signal
import subprocess
import sys
import termios
import time
import tty

BIN = os.path.dirname(os.path.abspath(__file__))
PFX = b"\x1b]7502;"
OSC_MAX = 4096
START, END = b"\x1b[200~", b"\x1b[201~"
# what a dropped connection may leave the terminal in: the alternate screen,
# mouse reporting, bracketed paste, a hidden cursor
RESET = b"\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?25h\x1b[0m\r\n"


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


def tlog(event, home="", route="", pick_ms="", ssh_ms="", first_ms="", rc="", reason=""):
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
              pick_ms, ssh_ms, first_ms, rc, reason]
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in fields) + "\n")
    except OSError:
        pass


def ms(t0, t1=None):
    return "%d" % (((t1 or time.time()) - t0) * 1000)


# ---------------------------------------------------------------------------
# the home and the line — fleet-connect.py --argv (约定 4)
# ---------------------------------------------------------------------------

def pick(home="", avoid="", reconnect=False):
    """(fleet-connect --argv's JSON, pick_ms, why) — the certificate renewed, the
    home asked, the line picked; (None, ms, why) when there is none."""
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
        r = subprocess.run(cmd, stdout=subprocess.PIPE, env=env, timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        return None, ms(t0), str(e)
    try:
        j = json.loads(r.stdout.decode("utf-8", "replace").strip().splitlines()[-1])
    except (ValueError, IndexError):
        j = None
    if r.returncode != 0 or not isinstance(j, dict) or not ("argv" in j or j.get("local")):
        return None, ms(t0), "fleet-connect --argv exit %d" % r.returncode
    return j, ms(t0), ""


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
        self.view = view or view_id()
        self.device = device_b64()
        self.base = None        # the last --argv answer (the upload rides it)
        self.cur = None         # (m, l, w) from the last valid `cur`
        self.quit = False
        self.back = iterm_profile()
        self.child = 0
        self.master = None
        self.attrs = termios.tcgetattr(0) if os.isatty(0) else None
        self.version = version()
        self.clip = None

    # -- the argv ---------------------------------------------------------
    def argv(self, reconnect):
        if self.local:
            # a managed machine's own `fleet` over ssh (issue #3006, C9): the view is
            # right here — the remote command runs as a child, never an ssh to itself
            m = load("fleet-connect.py", "fleet_connect").local_machine()
            return {"local": True, "machine": m["alias"], "argv": []}, "0", ""
        return pick(self.home, self.avoid, reconnect)

    def remote(self, token, route):
        rbin = os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin"
        words = ["bash", rbin + "/fleet-remote-view.sh", "attach", "--thin", "--view", self.view]
        if self.resume:
            words.append("--resume")
        elif self.want:
            words += ["--want", self.want]
        words += ["--device", self.device, "--route", route or "-", "--token", token]
        return " ".join(shlex.quote(w) for w in words)

    def command(self, j, extra, remote):
        if j.get("local"):
            return ["sh", "-c", 'cd && exec sh -c "$1"', "fleet-thin", remote]
        a, h = list(j["argv"]), int(j["host"])
        return a[:h] + extra + [a[h], remote]

    # -- uploads ----------------------------------------------------------
    def send(self, path, name=""):
        """One file to the session's machine through the home: (rc, path there | why)."""
        up = self.upload_mod()
        if not self.cur or not self.base:
            return 1, up.tr("paste_failed", os.path.basename(path))
        m, l, w = self.cur
        name = up.safe(name or path)
        rbin = os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin"
        words = ["python3", rbin + "/fleet-client-upload.py", "recv", m or "-", l or "-", w or "-", "--name", name]
        remote = " ".join(shlex.quote(x) for x in words)
        cmd = self.command(self.base, ["-o", "ControlMaster=no", "-o", "ControlPath=none",
                                       "-o", "ServerAliveInterval=5"], remote)
        t0 = time.time()
        try:
            with open(path, "rb") as f:
                r = subprocess.run(cmd, stdin=f, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
        except (OSError, subprocess.SubprocessError) as e:
            tlog("upload", self.home, "", "", "", "", 1, "%s: %s" % (name, e))
            return 1, up.tr("paste_failed", "%s: %s" % (name, e))
        out = r.stdout.decode("utf-8", "replace").strip().splitlines()
        there = out[-1] if out else ""
        tlog("upload", self.home, "", "", ms(t0), "", r.returncode, "%s → %s" % (name, there))
        if r.returncode != 0 or not there.startswith("/"):
            why = (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["exit %d" % r.returncode])[-1]
            return (3 if r.returncode == 3 else 1), why[:120]
        return 0, there

    def upload_mod(self):
        if self.clip is None:
            self.clip = load("fleet-client-upload.py", "fleet_client_upload")
        return self.clip

    def say(self, text):
        """No bar of ours to write on: the log, and a terminal notification."""
        tlog("say", self.home, "", "", "", "", "", text)
        write_out(b"\x1b]9;" + text.replace("\x07", " ").encode("utf-8", "replace") + b"\x07")

    def ctrl_v(self):
        """⌃V: a picture on the clipboard → its path on the session's machine,
        bracket-pasted; anything else → the ⌃V itself."""
        if os.environ.get("FLEET_CLIENT_PASTE", "1") == "0" or not self.cur:
            return b"\x16"
        import tempfile
        up = self.upload_mod()
        fd, png = tempfile.mkstemp(prefix="fleet-clip.", suffix=".png")
        os.close(fd)
        try:
            if not up.clip_png(png):
                return b"\x16"
            rc, out = self.send(png, "clip.png")
        finally:
            try:
                os.unlink(png)
            except OSError:
                pass
        if rc != 0:
            self.say(out)
            return b""
        return START + out.encode() + END

    # -- one connection ---------------------------------------------------
    def connect_once(self, reconnect):
        """(rc, came_up, reason)."""
        j, pick, why = self.argv(reconnect)
        if j is None:
            tlog("connect", self.home or "-", "", pick, "", "", 1, why)
            return 1, False, why
        self.base = j
        home = j.get("machine") or self.home or ""
        if self.home and home != self.home:
            tlog("rehome", home, "", "", "", "", "", "from %s" % self.home)
            self.resume = False   # a new home has no view of ours yet
        self.home = home
        route = (j.get("route") or {}).get("name") or ("local" if j.get("local") else "")
        token = "%032x" % random.getrandbits(128)
        extra = ["-tt", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                 "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=3"]
        cmd = self.command(j, extra, self.remote(token, route))
        t0 = time.time()
        rc, first_byte, first_view = self.pump(cmd, token)
        up = first_view is not None or time.time() - t0 >= env_num("FLEET_THIN_UP_SECS", 10)
        tlog("connect", home, route, pick, ms(t0, first_byte) if first_byte else "",
             ms(t0, first_view) if first_view else "", rc, "quit" if self.quit else ("up" if up else "never up"))
        if up:
            self.resume = True
        return rc, up, ""

    def pump(self, cmd, token):
        """ssh under our pty: (rc, time of the first byte | None, time of the first valid cur | None)."""
        tty_in = self.attrs is not None
        if tty_in:
            master, slave = os.openpty()
            termios.tcsetattr(slave, termios.TCSANOW, self.attrs)
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
        rw = None
        if os.environ.get("FLEET_CLIENT_PASTE", "1") != "0":
            try:
                up = self.upload_mod()
                rw = up.Rewriter(self.home, "", "", send=lambda p: self.send(p), say=self.say)
            except Exception as e:
                tlog("filter-error", self.home, "", "", "", "", "", e)
        first_byte = first_view = None
        out_wait = in_wait = 0.0
        st = None
        if tty_in:
            tty.setraw(0, termios.TCSANOW)
        try:
            while True:
                done, s_ = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    st = s_
                    break
                tmo = 0.05 if (out_wait or in_wait) else 0.5
                try:
                    r, _, _ = select.select([0, master], [], [], tmo)
                except InterruptedError:
                    continue
                now = time.time()
                if out_wait and now - out_wait > 0.05:
                    write_out(osc.flush())
                    out_wait = 0.0
                if in_wait and rw and now - in_wait > (2.0 if rw.buf else 0.05):
                    writeall(master, rw.flush())
                    in_wait = 0.0
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
                    out, events, waiting = osc.feed(data)
                    write_out(out)
                    out_wait = (out_wait or now) if waiting else 0.0
                    for kind, kv in events:
                        if kind == "cur":
                            self.cur = (kv.get("m", ""), kv.get("l", ""), kv.get("w", ""))
                            if rw:
                                rw.node, rw.wid = self.cur[0], self.cur[2]
                            if first_view is None:
                                first_view = now
                        elif kind == "quit":
                            self.quit = True
                if 0 in r:
                    try:
                        data = os.read(0, 65536)
                    except OSError as e:
                        if e.errno not in (errno.EIO, errno.EBADF):
                            continue
                        data = b""
                    if not data:
                        # the terminal is gone: as a SIGHUP
                        self.hangup(signal.SIGHUP, None)
                    if data == b"\x16" and not (rw and (rw.buf or rw.held)):
                        writeall(master, self.ctrl_v())
                        continue
                    if rw:
                        out, waiting = rw.feed(data)
                        in_wait = (in_wait or now) if waiting else 0.0
                    else:
                        out = data
                    try:
                        writeall(master, out)
                    except OSError:
                        pass
        finally:
            self.child, self.master = 0, None
            self.restore_tty()
            try:
                os.close(master)
            except OSError:
                pass
        return rc_of(st), first_byte, first_view

    # -- signals ----------------------------------------------------------
    def restore_tty(self):
        if self.attrs is not None:
            try:
                termios.tcsetattr(0, termios.TCSADRAIN, self.attrs)
            except termios.error:
                pass

    def hangup(self, n, _f):
        """The terminal closed (SIGHUP) or we were told to stop: the ssh goes with
        us, nothing stays."""
        if self.child:
            try:
                os.kill(self.child, signal.SIGHUP)
                os.waitpid(self.child, 0)
            except OSError:
                pass
        self.restore_tty()
        tlog("end", self.home, "", "", "", "", 128 + n, "signal %d" % n)
        if n != signal.SIGHUP:
            self.profile(False)
        os._exit(128 + n)

    def profile(self, on):
        if self.back:
            write_out(b"\x1b]1337;SetProfile=" + (b"fleet" if on else self.back.encode()) + b"\x07")

    # -- between connections ----------------------------------------------
    def maybe_update(self):
        """A new client between two connections: exec it, view and home kept."""
        seam = os.environ.get("FLEET_THIN_UPDATE_CMD")
        upd = shlex.split(seam) if seam else (
            [os.path.join(BIN, "fleet-client-update.sh"), "start"]
            if os.access(os.path.join(BIN, "fleet-client-update.sh"), os.X_OK) else [])
        rc = 0
        if upd and not self.local and not os.environ.get("FLEET_CLIENT_UPDATED"):   # --local: the machine's runtime moves it
            try:
                rc = subprocess.call(upd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=60)
            except (OSError, subprocess.SubprocessError):
                rc = 0
        if rc != 3 and version() == self.version:
            return
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
        self.profile(False)
        os.execv(args[0], args)

    def run(self):
        for s in (signal.SIGHUP, signal.SIGTERM):
            signal.signal(s, self.hangup)
        signal.signal(signal.SIGWINCH, self.resize)
        backoff = [env_num("x", x) for x in
                   (os.environ.get("FLEET_THIN_BACKOFF") or "1,2,4,8,16,30").split(",") if x.strip()] or [1.0]
        rehome = int(env_num("FLEET_THIN_REHOME_AFTER", 3))
        self.profile(True)
        k = fails = 0
        offline = False
        try:
            while True:
                rc, up, why = self.connect_once(k > 0)
                if self.quit or (rc == 0 and not why):
                    tlog("quit", self.home, "", "", "", "", rc, "quit" if self.quit else "detach")
                    return 0
                if up:
                    fails, k = 0, 0
                else:
                    fails += 1
                k += 1
                if fails >= rehome and self.home and not self.local and hub_answers() is False:
                    # the hub does not answer either: our own line is down, not the home —
                    # stay, keep the view, and need one more failure with the hub back (#3007)
                    tlog("offline", self.home, "", "", "", "", "", "the hub does not answer either: keeping %s" % self.home)
                    fails, offline = rehome - 1, True
                elif fails >= rehome and offline:
                    fails, offline = rehome - 1, False   # the hub back: one more try at the home first
                if fails >= rehome and self.home and not self.local:   # --local has no other home
                    self.avoid, self.home, fails = self.home, "", 0
                    self.resume = False   # a new home has no view of ours yet
                    tlog("rehome", "", "", "", "", "", "", "asking for a home other than %s" % self.avoid)
                if not why:
                    write_out(RESET)
                wait = backoff[min(k - 1, len(backoff) - 1)]
                msg = tr("thin_reconnect", self.home or self.avoid or "?", "%g" % wait, k)
                if why:
                    msg = why + " — " + msg
                write_out(("fleet · %s\r\n" % msg).encode())
                if fails == rehome - 1 and not offline:   # the home about to be given up: how to tell the hub why
                    write_out(("fleet · %s\r\n" % tr("thin_debug_hint")).encode())
                time.sleep(wait)
                self.maybe_update()
        except KeyboardInterrupt:
            tlog("quit", self.home, "", "", "", "", 130, "^C between connections")
            return 130
        finally:
            self.profile(False)

    def resize(self, *_):
        """SIGWINCH: the terminal's size onto the child's pty (the kernel tells ssh)."""
        if self.master is None:
            return
        try:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
        except OSError:
            pass


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
