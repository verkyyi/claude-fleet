#!/usr/bin/python3 -I
"""fleet_admin_seat.py — the admin role account's half on the machine (issue #3696,
EPIC #3500 C15·b · 共同约定 11).

The machine's account ops move off the admin's own login onto a role account,
`_fleetadmin` (macOS) / `fleetadmin` (Linux), whose sudoers file names exactly the
two copies of the gate (bin/fleet-admin-gate.sh, C15·a #3557):

  /etc/sudoers.d/fleet-admin
    _fleetadmin ALL=(root) NOPASSWD: <state>/admin/fleet-login-new.sh, <state>/admin/fleet-login-remove.sh

<state>/admin/ (root 0755) holds the two copies (root 0755, never a link), admin.conf
(root 0644: bin=<root>/current/bin, hub=<the hub's address>), account.pub (the hub's account-op key, pinned
ONCE by the root install step from GET /v1/fleet/account-key — only a person's sudo
install replaces it) and used/ (the spent-nonce book, root 0700).

  fleet_admin_seat.py ensure --hub <url> [--repin] [--check]
        the install step (root): the role account, admin/, account.pub, admin.conf,
        the gate copies from <root>/current, the sudoers file (visudo -c on the new
        file before it replaces the old). --check: exit 0 when nothing would change,
        1 otherwise (nothing written). Exit 3 = the hub serves no account key (the
        seat is off: nothing made).
  fleet_admin_seat.py place --release <dir>
        the gate copies + admin.conf from release <dir> — what the root core's
        switch / rollback (and a root updater's own switch) runs; a machine with no
        admin/ is left alone (no seat ⇒ nothing, byte for byte).
  fleet_admin_seat.py remove
        the install step's FLEET_ADMIN_SEAT=0 (root): the sudoers file and admin/
        go; the role account stays (it owns nothing).
  fleet_admin_seat.py status [--check]
        one line per item; --check exit 1 on any drift (a copy that is not the
        current release's gate, a link, someone else's file, a sudoers file with
        another line).

Seams (tests): FLEET_NODE_STATE · FLEET_NODE_ROOT · FLEET_ADMIN_ROLE (an existing
user) · FLEET_ADMIN_ROLE_CMD (run in place of each system command) ·
FLEET_ADMIN_SUDOERS (the file) · FLEET_ADMIN_VISUDO (''= no check) ·
FLEET_NODE_TEST=1 (no root, no chown).
"""
import grp
import hashlib
import os
import platform
import pwd
import re
import shutil
import stat
import subprocess
import sys
import urllib.error
import urllib.request

MAC = platform.system() == "Darwin"
GATE = "fleet-admin-gate.sh"
NAMES = ("fleet-login-new.sh", "fleet-login-remove.sh")
KEY_PATH = "/v1/fleet/account-key"
KEY_RE = re.compile(r"^ed25519 [A-Za-z0-9+/]{43}=$")
DEFAULT_ROOT = "/Library/Application Support/claude-fleet" if MAC else "/opt/claude-fleet"


def env(k, d):
    v = os.environ.get(k)
    return d if v is None else v


def testing():
    return env("FLEET_NODE_TEST", "") == "1"


def role():
    return env("FLEET_ADMIN_ROLE", "_fleetadmin" if MAC else "fleetadmin")


def state_dir():
    return env("FLEET_NODE_STATE", "/var/db/fleet-node")


def root_dir():
    return env("FLEET_NODE_ROOT", DEFAULT_ROOT)


def admin_dir(state=None):
    return os.path.join(state or state_dir(), "admin")


def sudoers_path():
    return env("FLEET_ADMIN_SUDOERS", "/etc/sudoers.d/fleet-admin")


def sudoers_body(adir=None):
    adir = adir or admin_dir()
    return ("# claude-fleet (issue #3696): the admin role account runs exactly these two —\n"
            "# both are bin/fleet-admin-gate.sh, which runs an op only with the hub's ticket.\n"
            "%s ALL=(root) NOPASSWD: %s\n" % (role(), ", ".join(os.path.join(adir, n) for n in NAMES)))


HUB_RE = re.compile(r"^https?://[A-Za-z0-9._:/@%-]+$")


def conf_hub(adir=None):
    """admin.conf's hub= (the install step's word), when it is an address."""
    try:
        with open(os.path.join(adir or admin_dir(), "admin.conf")) as f:
            for line in f.read().splitlines():
                if line.startswith("hub=") and HUB_RE.match(line[4:]):
                    return line[4:]
    except OSError:
        pass
    return ""


def conf_body(root=None, hub=""):
    """admin.conf: bin= the release's bin/ under current, hub= the hub a new login
    joins (kept from the install step: a switch never changes it)."""
    return "bin=%s\n" % os.path.join(root or root_dir(), "current", "bin") + ("hub=%s\n" % hub if hub else "")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(65536), b""):
            h.update(b)
    return h.hexdigest()


def rootish(st, mode):
    """True when <st> is a regular file / dir root's (as root) with exactly <mode>."""
    if stat.S_ISLNK(st.st_mode):
        return False
    if not testing() and st.st_uid != 0:
        return False
    return stat.S_IMODE(st.st_mode) == mode


def _chown_root(path):
    if os.geteuid() == 0:
        os.lchown(path, 0, 0)


def put(path, data, mode):
    """<path> holds <data> (bytes), root's, <mode> — by one rename, never through a
    link (rename replaces a link itself). → True when it changed."""
    try:
        st = os.lstat(path)
        if rootish(st, mode) and stat.S_ISREG(st.st_mode):
            with open(path, "rb") as f:
                if f.read() == data:
                    return False
    except OSError:
        pass
    tmp = "%s.tmp-admin-%d" % (path, os.getpid())
    try:
        os.unlink(tmp)
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        _chown_root(tmp)
        os.chmod(tmp, mode)
        os.rename(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def own_dir(path, mode):
    """<path> a real directory, root's, <mode>; a link in its place is removed.
    → True when it changed."""
    changed = False
    if os.path.islink(path) or (os.path.lexists(path) and not os.path.isdir(path)):
        os.unlink(path)
    if not os.path.isdir(path):
        os.mkdir(path, mode)
        changed = True
    st = os.lstat(path)
    if not testing() and (st.st_uid, st.st_gid) != (0, 0):
        _chown_root(path)
        changed = True
    if stat.S_IMODE(st.st_mode) != mode:
        os.chmod(path, mode)
        changed = True
    return changed


# ---------------------------------------------------------------- place ---------
def place(release, state=None, root=None):
    """The gate copies + admin.conf from <release> (its bin/fleet-admin-gate.sh).
    Nothing when the seat was never set up (no admin/) or the release has no gate
    (an old release: the copies already there refuse without its ticket checker).
    → [notes]; raises OSError on a write that failed."""
    adir = admin_dir(state)
    if not os.path.isdir(adir) or os.path.islink(adir):
        return []
    src = os.path.join(release, "bin", GATE)
    if not os.path.isfile(src):
        return ["admin gate: %s has no %s — the copies stay" % (release, GATE)]
    notes = []
    if own_dir(adir, 0o755):
        notes.append("admin gate: %s root 0755" % adir)
    with open(src, "rb") as f:
        body = f.read()
    for n in NAMES:
        if put(os.path.join(adir, n), body, 0o755):
            notes.append("admin gate: %s ← %s" % (n, src))
    if put(os.path.join(adir, "admin.conf"), conf_body(root, conf_hub(adir)).encode(), 0o644):
        notes.append("admin gate: admin.conf bin=%s" % os.path.join(root or root_dir(), "current", "bin"))
    used = os.path.join(adir, "used")
    if os.path.lexists(used) and own_dir(used, 0o700):
        notes.append("admin gate: used/ root 0700")
    return notes


# ---------------------------------------------------------------- the account ---
def run(argv):
    cmd = env("FLEET_ADMIN_ROLE_CMD", "")
    return subprocess.call(([cmd] if cmd else []) + argv, stdout=subprocess.DEVNULL)


def role_exists():
    try:
        return pwd.getpwnam(role()).pw_uid != 0
    except KeyError:
        return False


def ensure_role():
    """Make the role account (fleet-credsep.py ensure_role's recipe): True when made."""
    if role_exists():
        return False
    if "FLEET_ADMIN_ROLE" in os.environ and not os.environ.get("FLEET_ADMIN_ROLE_CMD"):
        raise SystemExit("fleet_admin_seat: FLEET_ADMIN_ROLE=%s does not exist (a seam names an existing user)" % role())
    name = role()
    if MAC:
        used = {p.pw_uid for p in pwd.getpwall()} | {g.gr_gid for g in grp.getgrall()}
        free = [i for i in range(499, 449, -1) if i not in used]
        if not free:
            raise SystemExit("fleet_admin_seat: no free id in 450-499 for %s" % name)
        i = str(free[0])
        cmds = [["dseditgroup", "-o", "create", "-i", i, "-r", "claude-fleet admin agent", name],
                ["sysadminctl", "-addUser", name, "-fullName", "claude-fleet admin agent", "-UID", i, "-GID", i,
                 "-shell", "/usr/bin/false", "-home", "/var/empty", "-roleAccount"]]
    else:
        cmds = [["useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent",
                 "--shell", "/usr/sbin/nologin", "--comment", "claude-fleet admin agent", name]]
    for c in cmds:
        if run(c) != 0:
            raise SystemExit("fleet_admin_seat: %s failed" % " ".join(c))
    return True


# ---------------------------------------------------------------- sudoers -------
def sudoers_ok():
    try:
        st = os.lstat(sudoers_path())
        if not rootish(st, 0o440) or not stat.S_ISREG(st.st_mode):
            return False
        with open(sudoers_path()) as f:
            return f.read() == sudoers_body()
    except OSError:
        return False


def ensure_sudoers():
    """/etc/sudoers.d/fleet-admin is exactly sudoers_body(), root 0440 — the new
    text checked by `visudo -c -f` before it replaces anything. → True when written."""
    if sudoers_ok():
        return False
    path = sudoers_path()
    tmp = "%s.tmp-admin-%d" % (path, os.getpid())
    # visudo ignores a name with a dot in /etc/sudoers.d, so the temp file never applies
    put(tmp, sudoers_body().encode(), 0o440)
    visudo = env("FLEET_ADMIN_VISUDO", "/usr/sbin/visudo")
    if visudo and subprocess.call([visudo, "-c", "-q", "-f", tmp], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL) != 0:
        os.unlink(tmp)
        raise SystemExit("fleet_admin_seat: visudo -c refused the new %s — the old one stays" % path)
    os.rename(tmp, path)
    return True


# ---------------------------------------------------------------- the key -------
def fetch_key(hub):
    """The hub's account-op key line, or None when it serves none (404)."""
    url = hub.rstrip("/") + KEY_PATH
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            line = r.read(512).decode("ascii", "replace").strip()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise SystemExit("fleet_admin_seat: %s answered HTTP %d" % (url, e.code))
    except (OSError, ValueError) as e:
        raise SystemExit("fleet_admin_seat: cannot read %s: %s" % (url, e))
    if not KEY_RE.match(line):
        raise SystemExit("fleet_admin_seat: %s is not an ed25519 key line" % url)
    return line


def pinned(adir=None):
    p = os.path.join(adir or admin_dir(), "account.pub")
    try:
        st = os.lstat(p)
        if not rootish(st, 0o644):
            return None
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return None


# ---------------------------------------------------------------- ensure --------
def ensure(hub, repin=False, check=False):
    if os.geteuid() != 0 and not testing():
        print("fleet_admin_seat: ensure makes an account and writes sudoers — run it as root", file=sys.stderr)
        return 2
    key = fetch_key(hub)
    if key is None:
        print("seat off: %s serves no account key (CCQUOTA_FLEET_ACCOUNT_KEY) — nothing made" % hub)
        return 3
    adir = admin_dir()
    have = pinned(adir)
    if have and have != key and not repin:
        print("fleet_admin_seat: the hub's account key is not the one pinned in %s/account.pub — "
              "rerun with FLEET_ADMIN_KEY_REPIN=1 if it was rotated on purpose" % adir, file=sys.stderr)
        return 1
    cur = os.path.join(root_dir(), "current")
    want = []
    if not role_exists():
        want.append("account %s" % role())
    if have != key:
        want.append("account.pub")
    if not sudoers_ok():
        want.append("sudoers")
    drift = status_lines()[1] or conf_hub(adir) != hub.rstrip("/")
    if drift:
        want.append("admin/")
    if check:
        print("admin seat: %s" % (", ".join(want) + " to do" if want else "converged"))
        return 1 if want else 0
    if not want:
        print("admin seat: converged (%s · %s)" % (role(), sudoers_path()))
        return 0
    made = ensure_role()
    own_dir(adir, 0o755)
    if have != key:
        put(os.path.join(adir, "account.pub"), (key + "\n").encode(), 0o644)
    put(os.path.join(adir, "admin.conf"), conf_body(None, hub.rstrip("/")).encode(), 0o644)
    place(os.path.realpath(cur))
    # the sudoers lines last: the role can sudo only once its two scripts are there
    ensure_sudoers()
    print("admin seat: %s%s · gate in %s · %s" % (role(), " made" if made else "", adir, sudoers_path()))
    return 0


def remove():
    if os.geteuid() != 0 and not testing():
        print("fleet_admin_seat: remove writes sudoers — run it as root", file=sys.stderr)
        return 2
    # the sudoers lines first: the role loses its two scripts before they go
    try:
        os.unlink(sudoers_path())
    except FileNotFoundError:
        pass
    adir = admin_dir()
    if os.path.islink(adir):
        os.unlink(adir)
    elif os.path.isdir(adir):
        shutil.rmtree(adir)
    print("admin seat: removed %s and %s (%s kept)" % (sudoers_path(), adir, role()))
    return 0


# ---------------------------------------------------------------- status --------
def status_lines():
    """([lines], drift?) — drift only for a seat that was set up (admin/ there)."""
    adir = admin_dir()
    if not os.path.isdir(adir):
        return ["admin seat  off (no %s)" % adir], False
    lines, bad = [], False
    lines.append("role        %s %s" % (role(), "ok" if role_exists() else "MISSING"))
    bad |= not role_exists()
    gate = os.path.join(root_dir(), "current", "bin", GATE)
    want = sha(gate) if os.path.isfile(gate) else None
    for n in NAMES:
        p = os.path.join(adir, n)
        try:
            st = os.lstat(p)
            ok = rootish(st, 0o755) and stat.S_ISREG(st.st_mode) and (want is None or sha(p) == want)
        except OSError:
            ok = False
        lines.append("%-11s %s" % (n.replace("fleet-login-", "").replace(".sh", ""), "ok" if ok else "DRIFT"))
        bad |= not ok
    try:
        st = os.lstat(os.path.join(adir, "admin.conf"))
        with open(os.path.join(adir, "admin.conf")) as f:
            ok = rootish(st, 0o644) and f.read() == conf_body(None, conf_hub(adir))
    except OSError:
        ok = False
    lines.append("admin.conf  %s" % ("ok" if ok else "DRIFT"))
    bad |= not ok
    ok = pinned(adir) is not None
    lines.append("account.pub %s" % ("pinned" if ok else "MISSING"))
    bad |= not ok
    ok = sudoers_ok()
    lines.append("sudoers     %s" % ("two lines" if ok else "DRIFT"))
    bad |= not ok
    return lines, bad


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "place":
        if len(rest) != 2 or rest[0] != "--release":
            return 2
        for n in place(rest[1]):
            print(n)
        return 0
    if cmd == "remove":
        return remove()
    if cmd == "status":
        lines, bad = status_lines()
        print("\n".join(lines))
        return 1 if bad and "--check" in rest else 0
    if cmd == "ensure":
        hub, it = "", iter(rest)
        flags = set()
        for a in it:
            if a == "--hub":
                hub = next(it, "")
            elif a in ("--repin", "--check"):
                flags.add(a)
            else:
                return 2
        if not re.match(r"^https?://", hub):
            print("fleet_admin_seat: ensure --hub <http(s) url>", file=sys.stderr)
            return 2
        return ensure(hub, repin="--repin" in flags or env("FLEET_ADMIN_KEY_REPIN", "") == "1",
                      check="--check" in flags)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
