#!/usr/bin/env python3
"""fleet-client-upload.py — a picture pasted, a file dropped: the session reads
it, on whatever machine it runs (issue #2757, EPIC #2756 C1).

  fleet-client-upload.py recv <machine> <login> <worker_id> [--name N]
        the HOME machine's side of the thin client (issue #3003, bin/fleet-thin.py):
        the file on stdin, for the session <worker_id> that runs on <machine> as
        <login>. This machine and this login: into the inbox here. Another one:
        over the home's standing connection to it ($FLEET_CONF_DIR/peerlink/
        <machine>@<login>.sock, EPIC #2999 约定 7 — never a connection of its
        own; none there = rc 1, said). Prints the path THERE; rc 0 delivered, 1 failed, 3 over the bound.

  fleet-client-upload.py sweep [--dry]
        the node's side (fleet-window-reap.sh's sweep, the diskguard tick): a
        session's inbox goes when no live window carries its @fleet_id any
        more (a name that is not an @fleet_id waits out the days); any file
        older than 7 days goes.

Knobs: FLEET_CLIENT_PASTE=0 (⌃V and every paste byte for byte as before),
FLEET_INBOX_CAP_MB (1024), FLEET_INBOX_DAYS (7).
Seams (tests): FLEET_CLIENT_CLIP_CMD <out.png> (exit 0 = a picture written,
1 = none), FLEET_REMOTE_SSH_CMD (the ssh for -S), FLEET_INBOX_LIVE_CMD
(prints the live @fleet_ids), FLEET_PASTE_LOG.
"""
import hashlib
import importlib.util
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

BIN = os.path.dirname(os.path.abspath(__file__))
IMAGE_MAX = 10 << 20
FILE_MAX = 100 << 20
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

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

def inbox_args(wid, src, name):
    """(rc, INBOX_SH's four args | why, size) — rc 0, 1 unreadable, 3 over the bound."""
    name = safe(name or src)
    try:
        size = os.path.getsize(src)
    except OSError as e:
        return 1, tr("paste_failed", "%s: %s" % (name, e.strerror)), 0
    if size > bound(name):
        return 3, tr("paste_too_big", name, bound(name) >> 20), size
    h = hashlib.sha256()
    with open(src, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    fname = "%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), name)
    cap = str(int(os.environ.get("FLEET_INBOX_CAP_MB") or 1024) * 1024)
    return 0, [fleet_id(wid), fname, h.hexdigest(), cap], size


def deliver(cmd, src, name, node, wid, size, t0, tag="put"):
    """Run the inbox script (cmd) with src on stdin: (rc, path there | why)."""
    with open(src, "rb") as f:
        try:
            r = subprocess.run(cmd, stdin=f, capture_output=True, timeout=600)
        except (OSError, subprocess.SubprocessError) as e:
            return 1, tr("paste_failed", "%s: %s" % (name, e))
    out = r.stdout.decode("utf-8", "replace").strip().splitlines()
    path = out[-1] if out else ""
    log(tag, node or "-", fleet_id(wid), size, r.returncode, "%.2f" % (time.time() - t0), path)
    if r.returncode != 0 or not path.startswith("/"):
        why = (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["exit %d" % r.returncode])[-1]
        return 1, tr("paste_failed", "%s: %s" % (name, why[:80]))
    return 0, path


def this_machine(label):
    """label names THIS machine: its hostname's first label, or the alias
    FLEET_NODE_ALIASES gives it (`mac-b.local=mac-b`) — fleet-client-actions' rule."""
    import platform
    me = platform.node().split(".", 1)[0]
    if not label or label in ("-", "local"):
        return True
    if label.split(".", 1)[0] == me:
        return True
    return any(x == "%s=%s" % (me, label) for x in (os.environ.get("FLEET_NODE_ALIASES") or "").split())


def peerlink_sock(machine, login):
    """The home's standing connection to (machine, login) — EPIC #2999 约定 7."""
    base = os.environ.get("FLEET_CONF_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "claude-fleet")
    return os.path.join(base, "peerlink", "%s@%s.sock" % (machine, login))


def cmd_recv(argv):
    import argparse
    import getpass
    ap = argparse.ArgumentParser(prog="fleet-client-upload recv")
    ap.add_argument("machine")
    ap.add_argument("login")
    ap.add_argument("wid")
    ap.add_argument("--name", default="")
    a = ap.parse_args(argv)
    try:
        me = getpass.getuser()
    except Exception:
        me = ""
    fd, tmp = tempfile.mkstemp(prefix="fleet-recv.")
    try:
        with os.fdopen(fd, "wb") as f:
            while True:
                b = sys.stdin.buffer.read(1 << 20)
                if not b:
                    break
                f.write(b)
        name = safe(a.name or "file")
        rc, args, size = inbox_args(a.wid, tmp, name)
        if rc == 0:
            t0 = time.time()
            if this_machine(a.machine) and a.login in ("", "-", me):
                cmd = ["sh", "-c", INBOX_SH, "fleet-inbox"] + args
            else:
                sock = peerlink_sock(a.machine, a.login)
                ssh = shlex.split(os.environ.get("FLEET_REMOTE_SSH_CMD") or "ssh")
                if not os.path.exists(sock) or subprocess.call(ssh + ["-S", sock, "-O", "check", a.machine],
                                                               stdout=subprocess.DEVNULL,
                                                               stderr=subprocess.DEVNULL) != 0:
                    rc, args = 1, tr("paste_failed", tr("paste_no_line", a.machine))
                else:
                    remote = "sh -c %s fleet-inbox %s" % (shlex.quote(INBOX_SH),
                                                         " ".join(shlex.quote(x) for x in args))
                    cmd = ssh + ["-S", sock, "-o", "ControlMaster=no", a.machine, remote]
            if rc == 0:
                rc, args = deliver(cmd, tmp, name, a.machine, a.wid, size, t0, "recv")
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    (sys.stdout if rc == 0 else sys.stderr).write(args + "\n")
    return rc


def run(cmd, data=None):
    try:
        r = subprocess.run(cmd, input=data, capture_output=True, timeout=10)
        return r.returncode, r.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        return 1, ""


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
    if argv and argv[0] in ("target", "identity", "recv-checked", "recv-stage", "status"):
        spec = importlib.util.spec_from_file_location("fleet_upload_receive", os.path.join(BIN, "fleet-upload-receive.py"))
        receiver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(receiver)
        return receiver.main(argv[0], sys.modules[__name__], argv[1:])
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    sub, rest = argv[0], argv[1:]
    if sub == "recv":
        return cmd_recv(rest)
    if sub == "sweep":
        return cmd_sweep(rest)
    sys.stderr.write("fleet-client-upload: target | identity | recv-checked | recv-stage | recv | sweep\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
