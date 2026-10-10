#!/usr/bin/env python3
"""fleet-client-upload.py — a picture pasted, a file dropped: the session reads
it, on whatever machine it runs (issue #2757, EPIC #2756 C1).

  fleet-client-upload.py put <node>:<worker_id> <file|-> [--name N] [--ctl SOCK]
        the client's side: the file onto the session's machine — over the ssh
        master the client already holds to it (the stage window's @remote_ctl,
        the warm one, else one of fleet-client-actions.py's own), never a new
        credential — into that login's ~/.cache/claude-fleet/inbox/<fleet_id>/
        (0700) as <UTC>-<name>, and prints the path THERE. The same bytes twice
        (sha256) land once. A session on this computer: the same inbox here.
        rc 0 delivered · 1 failed · 3 over the bound (images 10 MB, other
        files 100 MB) — one line on stderr says which. Every login's inbox is
        held to 1 GB: past it the oldest files go first.

  fleet-client-upload.py paste --pane <shell pane id> [--client C]
        ⌃V in the session pane of the shell (conf/tmux-shell.conf): the Mac's
        clipboard holds a picture → it is written out as PNG, `put` to the
        session the stage shows, and its path there bracket-pasted into that
        session (Claude Code reads a pasted image path as the image: [Image #1]).
        No picture, a session on this computer (its agent reads this clipboard
        itself), nothing remote in view, or FLEET_CLIENT_PASTE=0 → ⌃V goes on
        to the pane as it is.

  fleet-client-upload.py filter --node N --ctl SOCK [--wid W] -- <ssh …>
        the stage pane's program around its ssh (fleet-remote-view.sh run
        --shell): every byte passes untouched, except a bracketed paste
        (ESC[200~ … ESC[201~) that is nothing but absolute paths of files that
        exist on this computer — iTerm2's drop — whose files are `put` first
        and the paths swapped for theirs on the session's machine. A file that
        did not go is said on the client's bottom line, never handed on as a
        path the session cannot open. The child gets a pty of its own (its
        size follows the pane's), so ssh -tt behaves exactly as on the pane —
        and what ssh says on that pty (its /dev/tty: the first connection's
        «Are you sure you want to continue connecting», a passphrase) is
        written to the pane, so the person can answer it (issue #2904: dropped,
        every first connection to a machine hung on 「正在连接」).
        A filter that cannot start runs the command bare.

  fleet-client-upload.py sweep [--dry]
        the node's side (fleet-window-reap.sh's sweep, the diskguard tick): a
        session's inbox goes when no live window carries its @fleet_id any
        more (a name that is not an @fleet_id waits out the days); any file
        older than 7 days goes.

Knobs: FLEET_CLIENT_PASTE=0 (⌃V and every paste byte for byte as before),
FLEET_INBOX_CAP_MB (1024), FLEET_INBOX_DAYS (7).
Seams (tests): FLEET_CLIENT_CLIP_CMD <out.png> (exit 0 = a picture written,
1 = none), FLEET_REMOTE_SSH_CMD (the ssh for -S), FLEET_CLIENT_STAGE_CMD (the
stage's tmux), FLEET_CLIENT_SHELL_CMD (the shell's tmux), FLEET_INBOX_LIVE_CMD
(prints the live @fleet_ids), FLEET_PASTE_LOG.
"""
import errno
import fcntl
import hashlib
import importlib.util
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tty

BIN = os.path.dirname(os.path.abspath(__file__))
IMAGE_MAX = 10 << 20
FILE_MAX = 100 << 20
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic")
START, END = b"\x1b[200~", b"\x1b[201~"
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
PASTE_CAP = 64 << 10

# The node's half, one POSIX sh script for every node and for this computer:
# $1 fleet_id · $2 file name · $3 sha256 · $4 the login's cap in KB. Prints the
# path. A known sha prints the file already there and reads nothing.
INBOX_SH = r'''
umask 077
r="$HOME/.cache/claude-fleet/inbox"; d="$r/$1"
mkdir -p "$d" || exit 1
chmod 700 "$r" "$d" 2>/dev/null
if [ -f "$d/.sha256" ]; then
  old=$(awk -v s="$3" '$1 == s { n = $2 } END { if (n != "") print n }' "$d/.sha256")
  if [ -n "$old" ] && [ -f "$d/$old" ]; then touch "$d/$old"; printf '%s\n' "$d/$old"; exit 0; fi
fi
cat > "$d/.$2.part" || { rm -f "$d/.$2.part"; exit 1; }
mv "$d/.$2.part" "$d/$2" || exit 1
printf '%s %s\n' "$3" "$2" >> "$d/.sha256"
while :; do
  kb=$(du -sk "$r" 2>/dev/null | cut -f1)
  [ -n "$kb" ] && [ "$kb" -gt "$4" ] || break
  o=$(ls -1tr "$r"/*/* 2>/dev/null | grep -vxF "$d/$2" | head -n 1)
  [ -n "$o" ] || break
  rm -f "$o"
done
printf '%s\n' "$d/$2"
'''


def actions():
    spec = importlib.util.spec_from_file_location("fleet_client_actions", os.path.join(BIN, "fleet-client-actions.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


TEXT = {}


def tr(key, *args):
    if not TEXT:
        try:
            out = subprocess.run(["sh", os.path.join(BIN, "fleet-ui-lang.sh"), "dump", "paste_"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = b""
        parts = out.decode("utf-8", "replace").split("\0")
        TEXT.update(zip(parts[0::2], parts[1::2]))
        TEXT.setdefault("", "")
    text = TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


def log(*fields):
    path = os.environ.get("FLEET_PASTE_LOG") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "paste.log")
    try:
        with open(path, "a") as f:
            f.write("\t".join([time.strftime("%Y-%m-%dT%H:%M:%S")] + [str(x) for x in fields]) + "\n")
    except OSError:
        pass


def inbox_root():
    return os.path.join(os.path.expanduser("~"), ".cache", "claude-fleet", "inbox")


def safe(name):
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", os.path.basename(name or "file")).strip("._") or "file"
    return name[-80:]


def fleet_id(wid):
    fid = wid.split("/", 1)[1] if "/" in wid else "machine"
    return safe(fid) if fid not in ("", "-") else "machine"


def is_image(name):
    return name.lower().endswith(IMAGE_EXT)


def bound(name):
    return IMAGE_MAX if is_image(name) else FILE_MAX


# ---------------------------------------------------------------------------
# put
# ---------------------------------------------------------------------------

def put(node, wid, src, name="", ctl="", client=None):
    """(rc, path there | why) — rc 0 delivered, 1 failed, 3 over the bound."""
    name = safe(name or src)
    try:
        size = os.path.getsize(src)
    except OSError as e:
        return 1, tr("paste_failed", "%s: %s" % (name, e.strerror))
    if size > bound(name):
        return 3, tr("paste_too_big", name, bound(name) >> 20)
    h = hashlib.sha256()
    with open(src, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    fname = "%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), name)
    cap = str(int(os.environ.get("FLEET_INBOX_CAP_MB") or 1024) * 1024)
    args = [fleet_id(wid), fname, h.hexdigest(), cap]
    c = client or actions().Client(os.environ.get("FLEET_SHELL_SESSION") or "fleet-shell")
    t0 = time.time()
    if not node or c.this_machine(node):
        cmd = ["sh", "-c", INBOX_SH, "fleet-inbox"] + args
    else:
        sock = ""
        if ctl and os.path.exists(ctl) and subprocess.call(c.sshc() + ["-S", ctl, "-O", "check", c.ssh_host(node)],
                                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
            sock = ctl
        sock = sock or c.master(node)
        if not sock:
            return 1, tr("paste_failed", tr("paste_no_line", node))
        remote = "sh -c %s fleet-inbox %s" % (shlex.quote(INBOX_SH), " ".join(shlex.quote(a) for a in args))
        cmd = c.sshc() + ["-S", sock, c.ssh_host(node), remote]
    with open(src, "rb") as f:
        try:
            r = subprocess.run(cmd, stdin=f, capture_output=True, timeout=600)
        except (OSError, subprocess.SubprocessError) as e:
            return 1, tr("paste_failed", "%s: %s" % (name, e))
    out = r.stdout.decode("utf-8", "replace").strip().splitlines()
    path = out[-1] if out else ""
    log("put", node or "-", fleet_id(wid), size, r.returncode, "%.2f" % (time.time() - t0), path)
    if r.returncode != 0 or not path.startswith("/"):
        why = (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["exit %d" % r.returncode])[-1]
        return 1, tr("paste_failed", "%s: %s" % (name, why[:80]))
    return 0, path


def cmd_put(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-client-upload put")
    ap.add_argument("session")
    ap.add_argument("file")
    ap.add_argument("--name", default="")
    ap.add_argument("--ctl", default="")
    a = ap.parse_args(argv)
    node, _, wid = a.session.partition(":")
    if not wid:
        sys.stderr.write("fleet-client-upload: the session is <node>:<worker_id>\n")
        return 2
    src, tmp = a.file, ""
    if src == "-":
        fd, tmp = tempfile.mkstemp(prefix="fleet-upload.")
        with os.fdopen(fd, "wb") as f:
            while True:
                b = sys.stdin.buffer.read(1 << 20)
                if not b:
                    break
                f.write(b)
        src = tmp
    try:
        rc, out = put(node, wid, src, a.name or ("" if tmp else a.file), a.ctl)
    finally:
        if tmp:
            os.unlink(tmp)
    (sys.stdout if rc == 0 else sys.stderr).write(out + "\n")
    return rc


# ---------------------------------------------------------------------------
# paste — ⌃V
# ---------------------------------------------------------------------------

def tmux_cmd(var, label):
    seam = os.environ.get(var)
    if seam:
        return shlex.split(seam)
    return ["tmux", "-L", label] if label else ["tmux"]


def run(cmd, data=None):
    try:
        r = subprocess.run(cmd, input=data, capture_output=True, timeout=10)
        return r.returncode, r.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def say(text):
    """One line at the bottom of the shell's clients."""
    sh = tmux_cmd("FLEET_CLIENT_SHELL_CMD", os.environ.get("FLEET_SHELL_SESSION", ""))
    run(sh + ["display-message", "-d", "5000", "--", text.replace("#", "##")])


def clip_png(dest):
    """The clipboard's picture as PNG at dest — False when it holds none."""
    seam = os.environ.get("FLEET_CLIENT_CLIP_CMD")
    if seam:
        return subprocess.call(shlex.split(seam) + [dest], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0 \
            and os.path.getsize(dest) > 0
    if sys.platform != "darwin":
        return False
    rc, info = run(["osascript", "-e", "clipboard info"])
    if rc != 0:
        return False
    if "PNGf" in info:
        cls = "«class PNGf»"
    elif "TIFF" in info and "furl" not in info:
        cls = "TIFF picture"
    else:
        return False
    out = dest if cls.endswith("PNGf»") else dest + ".tiff"
    script = ['set f to open for access POSIX file "%s" with write permission' % out,
              "set eof f to 0", "write (the clipboard as %s) to f" % cls, "close access f"]
    if run(["osascript"] + sum((["-e", s] for s in script), []))[0] != 0:
        return False
    if out != dest:
        ok = run(["sips", "-s", "format", "png", out, "--out", dest])[0] == 0
        os.unlink(out)
        if not ok:
            return False
    return os.path.exists(dest) and os.path.getsize(dest) > 0


def cmd_paste(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-client-upload paste")
    ap.add_argument("--pane", required=True)
    ap.add_argument("--client", default="")
    a = ap.parse_args(argv)
    shell = tmux_cmd("FLEET_CLIENT_SHELL_CMD", os.environ.get("FLEET_SHELL_SESSION", ""))

    def as_is():
        run(shell + ["send-keys", "-t", a.pane, "C-v"])
        return 0

    if os.environ.get("FLEET_CLIENT_PASTE", "1") == "0":
        return as_is()
    stage_label = os.environ.get("FLEET_SHELL_STAGE", "")
    stage = tmux_cmd("FLEET_CLIENT_STAGE_CMD", stage_label)
    _, line = run(stage + ["display-message", "-p"] + (["-t", "=%s:" % stage_label] if stage_label else [])
                  + ["#{window_id}\t#{@remote}\t#{@remote_ctl}"])
    win, remote, ctl = (line.split("\t") + ["", "", ""])[:3]
    node, _, wid = remote.partition(":")
    c = actions().Client(os.environ.get("FLEET_SHELL_SESSION") or "fleet-shell")
    if not win or not node or node == "-" or not wid or c.this_machine(node):
        return as_is()
    t0 = time.time()
    fd, png = tempfile.mkstemp(prefix="fleet-clip.", suffix=".png")
    os.close(fd)
    try:
        if not clip_png(png):
            return as_is()
        rc, out = put(node, wid, png, "clip.png", ctl, c)
    finally:
        try:
            os.unlink(png)
        except OSError:
            pass
    if rc != 0:
        say(out)
        return rc
    buf = "fleet-paste"
    if run(stage + ["load-buffer", "-b", buf, "-"], out.encode())[0] != 0 \
            or run(stage + ["paste-buffer", "-p", "-d", "-b", buf, "-t", win])[0] != 0:
        say(tr("paste_failed", "paste-buffer"))
        return 1
    log("paste", node, fleet_id(wid), "%.2f" % (time.time() - t0), out)
    return 0


# ---------------------------------------------------------------------------
# filter — a drop
# ---------------------------------------------------------------------------

class Rewriter:
    """The bytes from the person's terminal toward ssh, a drop's paths swapped."""

    def __init__(self, node, wid, ctl):
        self.node, self.wid, self.ctl = node, wid, ctl
        self.buf = b""          # a paste being collected, START included
        self.held = b""         # a chunk's tail that may be the start of START
        self.client = None

    def current_wid(self):
        """The row the stage window shows now (`open` retargets the window)."""
        if os.environ.get("TMUX") and os.environ.get("TMUX_PANE"):
            rc, r = run(["tmux", "display-message", "-p", "-t", os.environ["TMUX_PANE"], "#{@remote}"])
            n, _, w = r.partition(":")
            if rc == 0 and n == self.node and w:
                return w
        return self.wid

    def feed(self, data):
        """(bytes to send now, waiting) — waiting: something is held back."""
        data = self.held + data
        self.held = b""
        out = b""
        while data:
            if self.buf:
                i = data.find(END)
                if i < 0:
                    self.buf += data
                    data = b""
                    if len(self.buf) > PASTE_CAP:
                        out += self.buf      # too long for a drop: on, as it came
                        self.buf = b""
                    break
                whole = self.buf + data[:i + len(END)]
                data = data[i + len(END):]
                self.buf = b""
                out += self.paste(whole)
                continue
            i = data.find(START)
            if i < 0:
                # a tail that could begin START waits for the next read; a lone
                # ESC never does (the Escape key must not lag)
                for k in range(min(len(START) - 1, len(data)), 1, -1):
                    if START.startswith(data[-k:]):
                        self.held = data[-k:]
                        data = data[:-k]
                        break
                out += data
                break
            out += data[:i]
            self.buf = START
            data = data[i + len(START):]
        return out, bool(self.buf or self.held)

    def flush(self):
        out, self.buf, self.held = self.buf + self.held, b"", b""
        return out

    def paste(self, whole):
        """One complete bracketed paste: as it came, or with the paths swapped."""
        try:
            new = self.rewrite(whole[len(START):-len(END)])
        except Exception as e:   # a bug here never eats what was pasted
            log("filter-error", e)
            new = None
        if new is None:
            return whole
        return START + new + END if new else b""

    def rewrite(self, body):
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            return None
        if not text.strip() or "\n" in text.strip():
            return None
        try:
            toks = shlex.split(text)
        except ValueError:
            return None
        inbox = inbox_root() + os.sep
        if not toks or not all(t.startswith("/") and os.path.isfile(t) and not t.startswith(inbox) for t in toks):
            return None
        if self.client is None:
            self.client = actions().Client(os.environ.get("FLEET_SHELL_SESSION") or "fleet-shell")
        if self.client.this_machine(self.node):
            return None
        wid = self.current_wid()
        if any(os.path.getsize(t) > (1 << 20) for t in toks):
            say(tr("paste_sending", ", ".join(os.path.basename(t) for t in toks)))
        got, why = [], []
        for t in toks:
            rc, out = put(self.node, wid, t, t, self.ctl, self.client)
            (got if rc == 0 else why).append(out)
        if why:
            say(" · ".join(why))
        tail = text[len(text.rstrip()):]
        log("drop", self.node, fleet_id(wid), len(got), len(why))
        return (" ".join(got) + tail).encode() if got else b""


def _rc(st):
    if os.WIFEXITED(st):
        return os.WEXITSTATUS(st)
    if os.WIFSIGNALED(st):
        return 128 + os.WTERMSIG(st)
    return 1


def _writeall(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except InterruptedError:
            continue
        except BlockingIOError:
            select.select([], [fd], [], 1)
            continue
        data = data[n:]


def cmd_filter(argv):
    import argparse
    if "--" not in argv:
        sys.stderr.write("usage: fleet-client-upload.py filter --node N --ctl SOCK [--wid W] -- <cmd…>\n")
        return 2
    i = argv.index("--")
    ap = argparse.ArgumentParser(prog="fleet-client-upload filter")
    ap.add_argument("--node", default="")
    ap.add_argument("--wid", default="")
    ap.add_argument("--ctl", default="")
    ap.add_argument("--mark", default="", help="touched when the filter itself fails")
    a, cmd = ap.parse_args(argv[:i]), argv[i + 1:]
    if not cmd:
        return 2
    if os.environ.get("FLEET_CLIENT_PASTE", "1") == "0":
        os.execvp(cmd[0], cmd)
    try:
        return filter_loop(a, cmd)
    except Exception as e:   # the filter itself broke: the next round runs ssh bare
        log("filter-crash", e)
        if a.mark:
            try:
                open(a.mark, "w").close()
            except OSError:
                pass
        return 255


def filter_loop(a, cmd):
    tty_in = os.isatty(0)
    attrs = size = None
    if tty_in:
        attrs = termios.tcgetattr(0)
        try:
            size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
        except OSError:
            pass
        master, slave = os.openpty()
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        if size:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, size)
    else:
        slave, master = os.pipe()       # the child reads `slave`, we write `master`
    pid = os.fork()
    if pid == 0:
        try:
            if tty_in:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                os.close(master)
            else:
                os.close(master)
            os.dup2(slave, 0)
            if slave != 0:
                os.close(slave)
            for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM, signal.SIGWINCH, signal.SIGPIPE):
                signal.signal(s, signal.SIG_DFL)
            os.execvp(cmd[0], cmd)
        except OSError as e:
            os.write(2, ("fleet-client-upload: %s: %s\n" % (cmd[0], e.strerror)).encode())
        os._exit(127)
    os.close(slave)

    def restore():
        if attrs is not None:
            try:
                termios.tcsetattr(0, termios.TCSADRAIN, attrs)
            except termios.error:
                pass

    def winch(*_):
        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
        except OSError:
            pass

    def stop(n, _f):
        try:
            os.kill(pid, n)
        except OSError:
            pass
        restore()
        try:
            _, st = os.waitpid(pid, 0)
        except OSError:
            st = 0
        os._exit(128 + n)

    if tty_in:
        signal.signal(signal.SIGWINCH, winch)
        tty.setraw(0, termios.TCSANOW)
    for s in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(s, stop)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    rw = Rewriter(a.node, a.wid, a.ctl)
    stdin_open = True
    st = None
    waiting_since = 0.0
    try:
        while True:
            done, s_ = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                st = s_
                break
            fds = [0] if stdin_open else []
            if tty_in:
                fds.append(master)   # what ssh says on its /dev/tty (#2904): to the pane
            tmo = 0.05 if waiting_since else 0.5
            try:
                r, _, _ = select.select(fds, [], [], tmo)
            except InterruptedError:
                continue
            if not r and waiting_since and time.time() - waiting_since > (2.0 if rw.buf else 0.05):
                _writeall(master, rw.flush())
                waiting_since = 0.0
            if tty_in and master in r:
                try:
                    said = os.read(master, 65536)
                except OSError:
                    said = b""
                if said:
                    try:
                        _writeall(1, said)
                    except OSError:
                        pass
            if 0 in r:
                try:
                    data = os.read(0, 65536)
                except OSError as e:
                    data = b"" if e.errno in (errno.EIO, errno.EBADF) else None
                    if data is None:
                        continue
                if not data:
                    stdin_open = False
                    _writeall(master, rw.flush())
                    if not tty_in:
                        os.close(master)
                    continue
                out, waiting = rw.feed(data)
                try:
                    _writeall(master, out)
                except OSError:
                    pass
                waiting_since = (waiting_since or time.time()) if waiting else 0.0
    finally:
        restore()
    if st is None:
        _, st = os.waitpid(pid, 0)
    return _rc(st)


# ---------------------------------------------------------------------------
# sweep — the node's half
# ---------------------------------------------------------------------------

def live_ids():
    """The @fleet_id of every live window on this login, or None (unknown)."""
    seam = os.environ.get("FLEET_INBOX_LIVE_CMD")
    cmd = shlex.split(seam) if seam else \
        ["bash", "-c", '. "$1/fleet-lib.sh" && fleet_list_windows_all "#{@fleet_id}"', "-", BIN]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    ids = {x.strip() for x in r.stdout.splitlines() if x.strip()}
    return ids if r.returncode == 0 and ids else None


def cmd_sweep(argv):
    dry = "--dry" in argv
    root = inbox_root()
    if not os.path.isdir(root):
        return 0
    days = float(os.environ.get("FLEET_INBOX_DAYS") or 7)
    old = time.time() - days * 86400
    live = live_ids()
    gone = []
    for fid in sorted(os.listdir(root)):
        d = os.path.join(root, fid)
        if not os.path.isdir(d):
            continue
        # only an @fleet_id (a UUID) can be judged gone; a key-shaped name (a
        # worker_id's `<uuid>/<key>` alias) or `machine` waits out the days
        if live is not None and UUID_RE.match(fid) and fid not in live:
            gone.append(d)
            if not dry:
                subprocess.call(["rm", "-rf", "--", d])
            continue
        for n in os.listdir(d):
            p = os.path.join(d, n)
            try:
                if not n.startswith(".") and os.path.getmtime(p) < old:
                    gone.append(p)
                    if not dry:
                        os.unlink(p)
            except OSError:
                pass
    for p in gone:
        print(p)
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    sub, rest = argv[0], argv[1:]
    if sub == "put":
        return cmd_put(rest)
    if sub == "paste":
        return cmd_paste(rest)
    if sub == "filter":
        return cmd_filter(rest)
    if sub == "sweep":
        return cmd_sweep(rest)
    sys.stderr.write("fleet-client-upload: put | paste | filter | sweep\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
