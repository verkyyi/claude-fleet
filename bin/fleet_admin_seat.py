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
  fleet_admin_seat.py agent --hub <url> [--token-stdin] [--check]
        the seat's own agent (issue #3724, C15·b-3, root): the role account's node
        token in <state>/admin/agent.token (root:<role> 0640 — root writes it, the
        role's agent reads it through CCQUOTA_TOKEN_FILE), its StateDir
        <state>/admin-agent/ (the role's, 0700) and the unit
        com.claude-fleet.admin-agent (/Library/LaunchDaemons, UserName <role>) /
        fleet-admin-agent.service (User=<role>) running <root>/agent/ccquota agent
        with CCQUOTA_FLEET=1 CCQUOTA_FLEET_ADMIN=1 CCQUOTA_FLEET_ADMIN_SEAT=1 —
        loaded / restarted when its unit or token changed. --token-stdin: one line,
        the token the root install step got from the hub's POST /v1/node/admin-token.
        --check: 0 converged, 1 something to do. Exit 3 = the seat is off (no
        admin/ or no role account) or <root>/agent/ccquota is not there yet; exit 4
        = a token is needed (none stored, or the hub no longer takes it).
  fleet_admin_seat.py role
        the role account's name.
  fleet_admin_seat.py status [--check]
        one line per item; --check exit 1 on any drift (a copy that is not the
        current release's gate, a link, someone else's file, a sudoers file with
        another line).

Seams (tests): FLEET_NODE_STATE · FLEET_NODE_ROOT · FLEET_ADMIN_ROLE (an existing
user) · FLEET_ADMIN_ROLE_CMD (run in place of each system command) ·
FLEET_ADMIN_SUDOERS (the file) · FLEET_ADMIN_VISUDO (''= no check) ·
FLEET_ADMIN_UNIT_DIR (where the agent's unit goes) · FLEET_ADMIN_SVC_CMD (run in
place of each launchctl / systemctl) ·
FLEET_NODE_TEST=1 (no root, no chown).
"""
import grp
import hashlib
import json
import os
import platform
import plistlib
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


# ---------------------------------------------------------------- the agent -----
# The seat's own agent (issue #3724, C15·b-3): `ccquota agent` as the role account,
# under its own unit, with its own node token — the hub's POST /v1/node/admin-token
# (asked by the root install step with the MACHINE's credential) — kept by root.
AGENT_LABEL = "com.claude-fleet.admin-agent"
AGENT_UNIT = "fleet-admin-agent.service"
SELF_PATH = "/v1/node/self"
TOKEN_RE = re.compile(r"^ccq_[A-Za-z0-9_-]{20,100}$")


def agent_state():
    return os.path.join(state_dir(), "admin-agent")


def token_path(adir=None):
    return os.path.join(adir or admin_dir(), "agent.token")


def unit_path():
    if MAC:
        return os.path.join(env("FLEET_ADMIN_UNIT_DIR", "/Library/LaunchDaemons"), AGENT_LABEL + ".plist")
    return os.path.join(env("FLEET_ADMIN_UNIT_DIR", "/etc/systemd/system"), AGENT_UNIT)


def agent_ccquota():
    """The fixed, signed copy of the release's ccquota (issue #3433): a path no
    release changes, so the unit never has to — the updater kickstarts it."""
    return os.path.join(root_dir(), "agent", "ccquota")


def role_ids():
    pw = pwd.getpwnam(role())
    return pw.pw_uid, pw.pw_gid


def agent_env(hub):
    sd = agent_state()
    return [("CCQUOTA_FLEET", "1"), ("CCQUOTA_FLEET_ADMIN", "1"), ("CCQUOTA_FLEET_ADMIN_SEAT", "1"),
            ("CCQUOTA_FLEET_ADMIN_GATE_DIR", admin_dir()), ("CCQUOTA_HUB_URL", hub),
            ("CCQUOTA_TOKEN_FILE", token_path()), ("CCQUOTA_NODE_KEY", os.path.join(sd, "node.key")),
            ("FLEET_CONF_DIR", os.path.join(sd, "conf")), ("HOME", sd)]


def agent_argv():
    sd = agent_state()
    return [agent_ccquota(), "agent", "--home", sd, "--state", os.path.join(sd, "state")]


def unit_body(hub):
    """The unit's exact text: a LaunchDaemon (UserName the role) / a systemd service
    (User= the role). The token is never in it — only the file's path."""
    sd = agent_state()
    if MAC:
        return plistlib.dumps({
            "Label": AGENT_LABEL, "UserName": role(), "GroupName": role(),
            "ProgramArguments": agent_argv(), "EnvironmentVariables": dict(agent_env(hub)),
            "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
            "StandardOutPath": os.path.join(sd, "agent.log"), "StandardErrorPath": os.path.join(sd, "agent.log"),
        }).decode()
    q = lambda v: '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    return "\n".join(
        ["# claude-fleet (issue #3724): the admin role account's own ccquota agent",
         "[Unit]", "Description=claude-fleet admin seat agent", "After=network-online.target", "",
         "[Service]", "User=%s" % role(), "Group=%s" % role()]
        + ["Environment=%s" % q("%s=%s" % kv) for kv in agent_env(hub)]
        + ["ExecStart=%s" % " ".join(agent_argv()), "Restart=always", "RestartSec=10", "",
           "[Install]", "WantedBy=multi-user.target", ""])


def unit_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def svc(argv):
    cmd = env("FLEET_ADMIN_SVC_CMD", "")
    return subprocess.call(([cmd] if cmd else []) + argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def agent_loaded():
    if MAC:
        return svc(["launchctl", "print", "system/" + AGENT_LABEL]) == 0
    return svc(["systemctl", "is-active", "--quiet", AGENT_UNIT]) == 0


def agent_start(fresh):
    """Load the unit (fresh: it or its token changed — stop the old one first)."""
    if MAC:
        if fresh:
            svc(["launchctl", "bootout", "system/" + AGENT_LABEL])
        rc = svc(["launchctl", "bootstrap", "system", unit_path()])
        if rc != 0 and not fresh:
            rc = svc(["launchctl", "kickstart", "-k", "system/" + AGENT_LABEL])
        return rc
    rc = svc(["systemctl", "daemon-reload"]) or svc(["systemctl", "enable", AGENT_UNIT])
    return rc or svc(["systemctl", "restart" if fresh else "start", AGENT_UNIT])


def agent_stop():
    """Unload and delete the unit (FLEET_ADMIN_SEAT=0); the StateDir stays."""
    up = unit_path()
    if not os.path.lexists(up):
        return
    if MAC:
        svc(["launchctl", "bootout", "system/" + AGENT_LABEL])
    else:
        svc(["systemctl", "disable", "--now", AGENT_UNIT])
    os.unlink(up)
    if not MAC:
        svc(["systemctl", "daemon-reload"])


def token_file_ok(path):
    """root's regular file, the role's group, 0640 — what the agent's
    CCQUOTA_TOKEN_FILE accepts and nobody else reads."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if not rootish(st, 0o640) or not stat.S_ISREG(st.st_mode):
        return False
    if testing():
        return True
    try:
        return st.st_gid == role_ids()[1]
    except KeyError:
        return False


def read_token(path):
    try:
        with open(path) as f:
            t = f.readline().strip()
    except OSError:
        return ""
    return t if TOKEN_RE.match(t) else ""


def token_live(hub, tok):
    """True: the hub takes it · False: it refuses it (401/403) · None: no answer."""
    req = urllib.request.Request(hub.rstrip("/") + SELF_PATH, headers={"Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=30):
            return True
    except urllib.error.HTTPError as e:
        return False if e.code in (401, 403) else None
    except (OSError, ValueError):
        return None


def seat_connected(adir=None):
    """(True, "") once the hub sees the seat's own agent connected — its
    /v1/node/self row (asked with the seat's token) says connected — else
    (False, why). What the old admin agent's handover waits for (issue #3725)."""
    adir = adir or admin_dir()
    hub, tp = conf_hub(adir), token_path(adir)
    tok = read_token(tp) if token_file_ok(tp) else ""
    if not hub or not tok:
        return False, "the seat's agent has no %s yet" % ("hub" if not hub else "token")
    req = urllib.request.Request(hub.rstrip("/") + SELF_PATH, headers={"Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            row = json.loads(r.read().decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as e:
        return False, "the hub answers HTTP %d for the seat's token" % e.code
    except (OSError, ValueError) as e:
        return False, "no answer from %s (%s)" % (hub, e)
    if isinstance(row, dict) and row.get("connected") is True:
        return True, ""
    return False, "the hub does not see the seat's agent connected (status %s)" % (
        row.get("status") if isinstance(row, dict) else "?")


def state_ok(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISDIR(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o700:
        return False
    return testing() or st.st_uid == role_ids()[0]


def own_state(path):
    """<path> a real directory, the role's, 0700 (a link in its place removed)."""
    if os.path.islink(path) or (os.path.lexists(path) and not os.path.isdir(path)):
        os.unlink(path)
    if not os.path.isdir(path):
        os.mkdir(path, 0o700)
    os.chmod(path, 0o700)
    if os.geteuid() == 0:
        uid, gid = role_ids()
        os.lchown(path, uid, gid)


def agent_ensure(hub, token="", check=False):
    """The seat's agent converged (see the module doc for the exit codes)."""
    if os.geteuid() != 0 and not testing():
        print("fleet_admin_seat: agent writes a system unit — run it as root", file=sys.stderr)
        return 2
    hub = hub.rstrip("/")
    adir = admin_dir()
    if not os.path.isdir(adir) or os.path.islink(adir) or not role_exists():
        print("seat off: no %s or no %s — set the seat up first (FLEET_ADMIN_SEAT=1)" % (adir, role()))
        return 3
    if not os.access(agent_ccquota(), os.X_OK):
        print("waiting: %s is not there yet (the updater puts it)" % agent_ccquota())
        return 3
    if token and not TOKEN_RE.match(token):
        print("fleet_admin_seat: the token on stdin is not a node token", file=sys.stderr)
        return 2
    tp, up, sd = token_path(adir), unit_path(), agent_state()
    have = read_token(tp) if token_file_ok(tp) else ""
    if not token and (not have or token_live(hub, have) is False):
        print("token needed: %s (POST %s for %s)" % ("the hub no longer takes the stored one" if have else "none stored",
                                                    "/v1/node/admin-token", role()))
        return 4
    body = unit_body(hub)
    want = []
    if token and token != have:
        want.append("agent.token")
    if not state_ok(sd):
        want.append("admin-agent/")
    if unit_text(up) != body:
        want.append("unit")
    loaded = agent_loaded()
    if not loaded:
        want.append("start")
    if check:
        print("admin agent: %s" % (", ".join(want) + " to do" if want else "converged"))
        return 1 if want else 0
    if not want:
        print("admin agent: converged (%s as %s)" % (AGENT_LABEL if MAC else AGENT_UNIT, role()))
        return 0
    if "agent.token" in want:
        put(tp, (token + "\n").encode(), 0o640)
        if os.geteuid() == 0:
            os.lchown(tp, 0, role_ids()[1])
    if "admin-agent/" in want:
        own_state(sd)
    if "unit" in want:
        put(up, body.encode(), 0o644)
    rc = agent_start(fresh=loaded and ("unit" in want or "agent.token" in want))
    if rc != 0:
        print("fleet_admin_seat: starting %s answered rc %d" % (AGENT_LABEL if MAC else AGENT_UNIT, rc), file=sys.stderr)
        return 1
    print("admin agent: %s as %s · %s" % (AGENT_LABEL if MAC else AGENT_UNIT, role(), ", ".join(want)))
    return 0


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
    # the seat's agent stops first, then the sudoers lines: the role loses its
    # two scripts before they go
    agent_stop()
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
    # the seat's agent (#3724): not there yet is not drift — `agent` makes it
    tp = token_path(adir)
    ok = not os.path.lexists(tp) or token_file_ok(tp)
    lines.append("agent.token %s" % (("ok" if ok else "DRIFT") if os.path.lexists(tp) else "none yet"))
    bad |= not ok
    up = unit_path()
    lines.append("agent unit  %s" % ((("ok" if unit_text(up) == unit_body(conf_hub(adir)) else "stale")
                                      if conf_hub(adir) else "ok") if os.path.isfile(up) else "none yet"))
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
    if cmd == "role":
        print(role())
        return 0
    if cmd == "agent":
        hub, it, flags = "", iter(rest), set()
        for a in it:
            if a == "--hub":
                hub = next(it, "")
            elif a in ("--token-stdin", "--check"):
                flags.add(a)
            else:
                return 2
        if not re.match(r"^https?://", hub):
            print("fleet_admin_seat: agent --hub <http(s) url>", file=sys.stderr)
            return 2
        tok = sys.stdin.readline().strip() if "--token-stdin" in flags else ""
        if "--token-stdin" in flags and not tok:
            print("fleet_admin_seat: --token-stdin read no token", file=sys.stderr)
            return 2
        return agent_ensure(hub, tok, check="--check" in flags)
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
