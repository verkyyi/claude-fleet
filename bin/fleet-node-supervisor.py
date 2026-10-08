#!/usr/bin/env python3
"""fleet-node-supervisor.py — the machine's ONE fleet daemon (issue #2331, EPIC #2329 C3).

`com.claude-fleet.node` runs this as root under launchd (KeepAlive). It does the
machine's work ONCE, however many logins the machine carries:

  * children  — long-running programs it keeps up: the shared credential proxy
                (today's `cred-proxy-shared` launcher) and, from C5, the node
                program. A child that dies is restarted after a backoff that
                doubles on every quick death (1 s … FLEET_NODE_BACKOFF_MAX) and
                resets once it has stayed up FLEET_NODE_BACKOFF_RESET seconds.
                While a child's OLD LaunchDaemon is still installed, launchd owns
                it and this daemon only reports it (`legacy`) — 共同约定 5.
  * tasks     — the machine-level periodic jobs (diskguard, memguard, the orphan
                watchdog …), each run as at most ONE copy: a task still running
                when it is due again is skipped, and every run holds
                `locks/<task>.lock`, so a hand-run `tick` cannot double it either.
  * accounts  — the account-level jobs (issue #2332, C4): ONE table, read from
                the runtime's `launchd/com.claude-fleet.*.plist.tmpl` (every unit
                but the machine-level ones), run for every account the daemon
                MANAGES, each demoted to that account (initgroups/setgid/setuid)
                with its HOME / USER / PATH / FLEET_CONF_DIR / TMPDIR — an interval
                unit as a task, a KeepAlive unit (spinner, webhook) as a child.
                The template's own interval, environment and log paths; the log
                is opened by the demoted process, never by root. One account's
                failing task never touches another's.
                An account becomes managed by `account adopt <login>`: its own
                fleet LaunchAgents / LaunchDaemons are booted out and moved to the
                attic (kept until released); one that will not unload puts every
                one back. Its own node agent (com.ccquota.agent.<login>, #2387)
                moves with them, and only once all are out its settings — the
                agent plist's CCQUOTA_* / FLEET_CONF_DIR + its node.env's CCQUOTA_*
                (a separated login's from the credsep store) — land in
                <state>/logins/<login>.env (root 0600), where the machine's one
                node program (C5) serves it from; that child restarts whenever
                logins/ changes. `account release <login>` is the way back, one
                command: the env goes first, then the old services come back.
                expected.json's `accounts` (C2), when present, narrows who runs.
  * update    — the machine's one updater (issue #2334, C6): a task like the
                rest (fleet-node-update.py tick). When it moves `current` it asks
                this daemon to restart (<state>/update-restart.json): the daemon
                stops its children and exits, and launchd starts the new code.
  * sweep     — fleet plist leftovers (`*.plist.bak*`, `.pre-move`, `.retired*`,
                `.disabled*` …) in /Library/LaunchDaemons and every login's
                ~/Library/LaunchAgents are MOVED to the attic
                (`/var/db/fleet-node/attic/`), kept FLEET_NODE_ATTIC_DAYS (7) days,
                and can be put back (`attic restore <id>`). A fleet plist the
                machine's expected state (`expected.json`, written from the hub —
                C2) does not name is only REPORTED, never moved: it may be loaded.

State survives a restart: `state.json` (0644, so any login's doctor can read it)
carries every task's last run and every child's pid; a restarted supervisor ADOPTS
a child still alive from the last run instead of starting a second one.

Root only ever runs code from the root runtime (共同约定 3,
`/Library/Application Support/claude-fleet/current`), and refuses a script there
that is not root-owned or that a group / other may write.

Usage:
  fleet-node-supervisor.py run                 the daemon loop (what launchd runs)
  fleet-node-supervisor.py tick                one pass: due tasks (waited for) + the sweep
  fleet-node-supervisor.py status [--json] [--check]
                                               one line per item: what · last run · result.
                                               --check: exit 0 healthy · 1 installed but not
                                               running (stale heartbeat) · 2 not installed
  fleet-node-supervisor.py sweep [--dry-run]   the leftover sweep, now
  fleet-node-supervisor.py attic [list | restore <id> | purge]
  fleet-node-supervisor.py install | uninstall write / remove the LaunchDaemon (root)
  fleet-node-supervisor.py install --check     exit 0 = already installed as install writes it
                                               and loaded (fleet-node-install.sh, #2330)
  fleet-node-supervisor.py account [list | adopt <login> | release <login> | manages <login>]
                                               the account half (#2332); manages: exit 0 = this
                                               daemon runs <login>'s tasks (install-apply, doctor)

Seams (sandbox tests, docs/BREAK-IT.md `node-supervisor-dead`):
  FLEET_NODE_STATE      /var/db/fleet-node          FLEET_NODE_LOG   /var/log/fleet-node
  FLEET_NODE_RUNTIME    /Library/Application Support/claude-fleet/current
  FLEET_NODE_DAEMON_DIR /Library/LaunchDaemons      FLEET_NODE_USERS /Users
  FLEET_NODE_TABLE      a JSON {"children": [...], "tasks": [...]} that REPLACES the
                        built-in table
  FLEET_NODE_TICK (1 s)  FLEET_NODE_BACKOFF_MAX (60)  FLEET_NODE_BACKOFF_RESET (60)
  FLEET_NODE_ATTIC_DAYS (7)  FLEET_NODE_SWEEP_EVERY (3600)  FLEET_NODE_HEARTBEAT_STALE (120)
  FLEET_NODE_LAUNCHCTL  launchctl's path ('' = do not load/unload)
  FLEET_NODE_TEST=1     skip the root-ownership check on the runtime
  FLEET_NODE_PASSWD     a JSON {login: {uid, gid, home}} read instead of the passwd
                        database (tests; under FLEET_NODE_TEST only)
  FLEET_NODE_BREW_PREFIX  __BREW_PREFIX__ in the templates (default /opt/homebrew, or
                        /usr/local when that is where brew is)
"""
from __future__ import print_function

import errno
import fcntl
import glob
import json
import os
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import sys
import time

LABEL = "com.claude-fleet.node"
# A fleet plist name, and a LEFTOVER of one: anything after `.plist`.
FLEET_PLIST_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.)")
LEFTOVER_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.).*\.plist\..+$")
# Units the machine runs ONCE (the table below); every other launchd template is
# an account unit (issue #2332). cred-proxy-shared has no template — it is listed
# so an account's adopt never boots the machine's proxy out.
MACHINE_UNITS = ("memguard", "node", "cred-proxy-shared")
ACCOUNT_ENV_DROP = ("UserName", "GroupName")


def env(name, default):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


def env_num(name, default):
    try:
        return float(env(name, default))
    except ValueError:
        return float(default)


class Paths(object):
    def __init__(self):
        self.state = env("FLEET_NODE_STATE", "/var/db/fleet-node")
        self.log = env("FLEET_NODE_LOG", "/var/log/fleet-node")
        self.runtime = env("FLEET_NODE_RUNTIME", "/Library/Application Support/claude-fleet/current")
        self.daemon_dir = env("FLEET_NODE_DAEMON_DIR", "/Library/LaunchDaemons")
        self.users = env("FLEET_NODE_USERS", "/Users")
        self.state_file = os.path.join(self.state, "state.json")
        self.attic = os.path.join(self.state, "attic")
        self.attic_index = os.path.join(self.attic, "index.json")
        self.locks = os.path.join(self.state, "locks")
        self.main_lock = os.path.join(self.state, "supervisor.lock")
        self.expected = os.path.join(self.state, "expected.json")
        self.accounts = os.path.join(self.state, "accounts.json")
        self.logins = os.path.join(self.state, "logins")
        self.plist = os.path.join(self.daemon_dir, LABEL + ".plist")


def now():
    return time.time()


def runtime_sha(paths):
    """The release the runtime link names (its directory's name), or None."""
    b = os.path.basename(os.path.realpath(paths.runtime))
    return b if re.match(r"^[0-9a-f]{40}$", b) else None


def iso(t):
    if not t:
        return "-"
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def ago(t):
    if not t:
        return "-"
    s = int(max(0, now() - t))
    if s < 120:
        return "%ds" % s
    if s < 7200:
        return "%dm" % (s // 60)
    if s < 172800:
        return "%dh" % (s // 3600)
    return "%dd" % (s // 86400)


def write_json(path, obj, mode=0o644):
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".%s.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, mode)
    os.rename(tmp, path)


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (IOError, OSError, ValueError):
        return default


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


def pid_cmd(pid):
    try:
        return subprocess.check_output(["ps", "-o", "command=", "-p", str(int(pid))],
                                       stderr=subprocess.DEVNULL).decode("utf-8", "replace").strip()
    except Exception:
        return ""


def dir_sig(d):
    """What a directory holds, as one string: each entry's name, size and mtime."""
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return ""
    out = []
    for n in names:
        try:
            st = os.lstat(os.path.join(d, n))
            out.append("%s:%d:%d" % (n, st.st_size, st.st_mtime_ns))
        except OSError:
            pass
    return "|".join(out)


def trusted(path, as_root=None):
    """Root runs only a root-owned script no group / other may write, in a dir
    likewise. Off under FLEET_NODE_TEST, and for a non-root supervisor."""
    if as_root is None:
        as_root = os.geteuid() == 0 and env("FLEET_NODE_TEST", "") != "1"
    if not as_root:
        return os.path.exists(path)
    p = os.path.realpath(path)
    while True:
        try:
            st = os.stat(p)
        except OSError:
            return False
        if st.st_uid != 0 or st.st_mode & 0o022:
            return False
        parent = os.path.dirname(p)
        if parent == p:
            return True
        p = parent


# --------------------------------------------------------------- the table -----
def default_table(paths):
    rt_bin = os.path.join(paths.runtime, "bin")
    cred_lib = env("FLEET_CREDSEP_LIB", "/Library/Application Support/claude-fleet/credsep")
    launcher = os.path.join(cred_lib, "fleet-credsep-launch.py")
    return {
        "children": [
            {"name": "cred-proxy-shared",
             "cmd": ["/usr/bin/python3", "-I", launcher, "shared"],
             "legacy": "com.claude-fleet.cred-proxy-shared"},
            # The one node program for every login (C5, #2333): one link to the
            # hub with the machine's token, each login a tenant run as itself.
            # Waits until the machine has its token (machine.env) and at least
            # the logins directory — the migration writes both, login by login.
            {"name": "node-agent",
             "cmd": [os.path.join(rt_bin, "ccquota"), "agent", "--machine",
                     "--machine-env", os.path.join(paths.state, "machine.env"),
                     "--logins", os.path.join(paths.state, "logins"),
                     "--state", os.path.join(paths.state, "agent")],
             "requires": [os.path.join(paths.state, "machine.env"), os.path.join(paths.state, "logins")],
             # it reads its tenants once, at start: an adopt / release (#2387)
             # changes the directory, and the daemon starts it again on it
             "reload": os.path.join(paths.state, "logins"),
             "note": "C5 #2333"},
        ],
        "tasks": [
            # --watch runs the orphan watchdog too; it is its own task below, all
            # users at once, so it is switched off here (one copy).
            {"name": "diskguard", "every": 60,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-diskguard.sh"), "--watch"],
             "env": {"FLEET_ORPHAN_CPU_PCT": "0"}},
            {"name": "memguard", "every": 10,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-memguard.sh"), "--once"]},
            {"name": "orphans", "every": 60,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-diskguard.sh"), "--orphan-watch"],
             "env": {"FLEET_ORPHAN_ALL_USERS": "1"}},
            # The one updater (C6, #2334): every part of the machine to the hub's
            # release, or none. A switch ends in a restart request (below).
            {"name": "update", "every": env_num("FLEET_NODE_UPDATE_EVERY", 300), "timeout": 1800,
             "cmd": ["/usr/bin/python3", "-I", os.path.join(rt_bin, "fleet-node-update.py"), "tick"]},
        ],
        # None = the runtime's launchd templates (account_units); a table file may
        # give the list itself, in account_units' shape.
        "account": None,
    }


def load_table(paths):
    path = os.environ.get("FLEET_NODE_TABLE")
    if path:
        t = read_json(path, None)
        if not isinstance(t, dict):
            raise SystemExit("fleet-node-supervisor: FLEET_NODE_TABLE %s is not a JSON object" % path)
        t.setdefault("children", [])
        t.setdefault("tasks", [])
        t.setdefault("account", [])
        return t
    return default_table(paths)


# --------------------------------------------------------------- accounts -------
def brew_prefix():
    v = os.environ.get("FLEET_NODE_BREW_PREFIX")
    if v:
        return v
    return "/opt/homebrew" if os.path.isdir("/opt/homebrew") or not os.path.isdir("/usr/local/bin") else "/usr/local"


def account_units(paths, table=None):
    """The ONE account task table: [{name, argv, env, every | keepalive, out, err}],
    argv/env/out/err still carrying __HOME__ (filled per account). From the table
    file when it names one, else every `launchd/com.claude-fleet.<u>.plist.tmpl` of
    the runtime but MACHINE_UNITS — so a unit's interval, environment and log paths
    are the template's own, and a new template is a new account task."""
    if table is not None and table.get("account") is not None:
        return list(table["account"])
    out = []
    pat = os.path.join(paths.runtime, "launchd", "com.claude-fleet.*.plist.tmpl")
    for f in sorted(glob.glob(pat)):
        u = os.path.basename(f)[len("com.claude-fleet."):-len(".plist.tmpl")]
        if u in MACHINE_UNITS:
            continue
        try:
            with open(f, "rb") as fh:
                # launchd tolerates a `--` inside a comment, expat does not
                pl = plistlib.loads(re.sub(rb"<!--.*?-->", b"", fh.read(), flags=re.S))
        except Exception:
            continue
        argv = [str(a) for a in pl.get("ProgramArguments") or []]
        if not argv:
            continue
        ent = {"name": u, "argv": argv,
               "env": dict((k, str(v)) for k, v in (pl.get("EnvironmentVariables") or {}).items()),
               "out": pl.get("StandardOutPath") or "/dev/null",
               "err": pl.get("StandardErrorPath") or "/dev/null"}
        if pl.get("KeepAlive"):
            ent["keepalive"] = True
        else:
            ent["every"] = float(pl.get("StartInterval") or 60)
        if u == "diskguard":
            # its orphan watchdog runs once for every user, as the machine's
            # `orphans` task — an account copy would notify twice
            ent["env"]["FLEET_ORPHAN_CPU_PCT"] = "0"
        out.append(ent)
    return out


def script_of(cmd):
    """The file a command runs: the first argv entry after an interpreter."""
    for a in cmd[1:] if len(cmd) > 1 and os.path.basename(cmd[0]) in (
            "bash", "sh", "python3", "python") else cmd[:1]:
        if not a.startswith("-"):
            return a
    return cmd[0]


def account_ident(login):
    """(uid, gid, home) of a login, or None. Never root, never a system account."""
    fake = os.environ.get("FLEET_NODE_PASSWD")
    if fake and env("FLEET_NODE_TEST", "") == "1":
        e = (read_json(fake, {}) or {}).get(login)
        return (int(e["uid"]), int(e["gid"]), e["home"]) if e else None
    try:
        pw = pwd.getpwnam(login)
    except KeyError:
        return None
    if pw.pw_uid < 500:
        return None
    return pw.pw_uid, pw.pw_gid, pw.pw_dir


def accounts_read(paths):
    a = read_json(paths.accounts, {})
    return a if isinstance(a, dict) else {}


def expected_accounts(paths):
    """The logins expected.json names (C2), or None when it names none."""
    ex = read_json(paths.expected, None)
    if not isinstance(ex, dict) or not isinstance(ex.get("accounts"), list):
        return None
    out = set()
    for x in ex["accounts"]:
        n = x.get("name") if isinstance(x, dict) else x
        if n:
            out.add(str(n))
    return out


def managed_accounts(paths):
    """{login: why-not or None}: every adopted login; None = its tasks run."""
    exp = expected_accounts(paths)
    out = {}
    for login, a in sorted(accounts_read(paths).items()):
        if not (a or {}).get("managed"):
            continue
        out[login] = None if exp is None or login in exp else "not in expected.json — paused"
    return out


def fill(s, home, brew):
    return s.replace("__HOME__", home).replace("__BREW_PREFIX__", brew)


# The demoted process opens its own logs (root never writes in a login's
# directory) and takes the login's own TMPDIR, as the system-shape plists did.
ACCOUNT_SH = ('TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; [ -n "$TMPDIR" ] || TMPDIR=/tmp; export TMPDIR; '
              'if : >>"$1" 2>/dev/null; then exec >>"$1"; else exec >/dev/null; fi; '
              'if : >>"$2" 2>/dev/null; then exec 2>>"$2"; else exec 2>/dev/null; fi; '
              'shift 2; exec "$@"')


def account_entry(unit, login, ident, brew):
    uid, gid, home = ident
    argv = [fill(a, home, brew) for a in unit["argv"]]
    e = dict((k, fill(v, home, brew)) for k, v in (unit.get("env") or {}).items()
             if k not in ACCOUNT_ENV_DROP)
    e.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    e.setdefault("LANG", "en_US.UTF-8")
    e.update(HOME=home, USER=login, LOGNAME=login,
             FLEET_CONF_DIR=os.path.join(home, ".config", "claude-fleet"),
             FLEET_NODE_ACCOUNT=login)
    ent = {"name": "%s/%s" % (login, unit["name"]), "account": login, "unit": unit["name"],
           "uid": uid, "gid": gid, "home": home, "env": e, "script": None,
           "cmd": ["/bin/sh", "-c", ACCOUNT_SH, "fleet-account",
                   fill(unit.get("out") or "/dev/null", home, brew),
                   fill(unit.get("err") or "/dev/null", home, brew)] + argv}
    ent["script"] = script_of(argv)
    if unit.get("keepalive"):
        ent["keepalive"] = True
    else:
        ent["every"] = unit.get("every", 60)
        if unit.get("timeout"):
            ent["timeout"] = unit["timeout"]
    return ent


def demote(login, uid, gid, home):
    def f():
        if os.geteuid() == 0:
            os.initgroups(login, gid)
            os.setgid(gid)
            os.setuid(uid)
        try:
            os.chdir(home)
        except OSError:
            os.chdir("/")
    return f


def account_runnable(ent):
    """Why an account entry must not start, or None."""
    if ent["uid"] == 0:
        return "refused — uid 0"
    if os.geteuid() != 0 and ent["uid"] != os.geteuid():
        return "needs root (to run as uid %d)" % ent["uid"]
    if ent.get("script") and not os.path.exists(ent["script"]):
        return "missing %s" % ent["script"]
    return None


# --------------------------------------------------------------- the daemon -----
class Supervisor(object):
    def __init__(self, paths, table):
        self.p = paths
        self.table = table
        self.state = read_json(paths.state_file, {})
        self.state.setdefault("version", 1)
        self.state.setdefault("tasks", {})
        self.state.setdefault("children", {})
        self.state.setdefault("sweep", {})
        self.procs = {}       # child name -> Popen (started by us)
        self.adopted = {}     # child name -> pid (left alive by an earlier run)
        self.running = {}     # task name -> (Popen, lock fd, t0, log fh)
        self.dirty = True
        self.stop = False
        self.backoff_max = env_num("FLEET_NODE_BACKOFF_MAX", 60)
        self.backoff_reset = env_num("FLEET_NODE_BACKOFF_RESET", 60)
        self.last_save = 0
        self.units = None
        self.units_at = 0

    # -- the account half (#2332): entries built from the one table, per managed login
    def account_entries(self):
        t = now()
        if self.units is None or t - self.units_at >= 60:
            self.units = account_units(self.p, self.table)
            self.units_at = t
        out = []
        if not self.units:
            return out
        brew = brew_prefix()
        for login, why in managed_accounts(self.p).items():
            if why:
                continue
            ident = account_ident(login)
            if ident is None:
                st = self.state.setdefault("account_errors", {})
                if st.get(login) != "no such login":
                    st[login] = "no such login"
                    self.dirty = True
                continue
            for u in self.units:
                out.append(account_entry(u, login, ident, brew))
        return out

    def all_children(self):
        return list(self.table["children"]) + [e for e in self.account_entries() if e.get("keepalive")]

    def all_tasks(self):
        return list(self.table["tasks"]) + [e for e in self.account_entries() if not e.get("keepalive")]

    def spawn(self, ent, fh, extra_env=None):
        """Popen one child / task: a machine one as root in the daemon's own env, an
        account one demoted to its login, its output opened by itself (ACCOUNT_SH)."""
        if ent.get("account"):
            return subprocess.Popen(ent["cmd"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=fh, env=ent["env"], start_new_session=True, close_fds=True,
                                    preexec_fn=demote(ent["account"], ent["uid"], ent["gid"], ent["home"]))
        return subprocess.Popen(ent["cmd"], stdin=subprocess.DEVNULL, stdout=fh, stderr=fh,
                                env=self.child_env(extra_env), start_new_session=True, close_fds=True)

    # -- plumbing
    def ensure_dirs(self):
        for d, m in ((self.p.state, 0o755), (self.p.locks, 0o755), (self.p.attic, 0o700),
                     (self.p.log, 0o755), (os.path.join(self.p.log, "tasks"), 0o755),
                     (os.path.join(self.p.log, "accounts"), 0o755),
                     (os.path.join(self.p.state, "home"), 0o700),
                     (os.path.join(self.p.state, "conf"), 0o700),
                     (os.path.join(self.p.state, "tmp"), 0o700)):
            if not os.path.isdir(d):
                os.makedirs(d)
                os.chmod(d, m)

    def save(self, force=False):
        t = now()
        if not force and not self.dirty and t - self.last_save < 15:
            return
        self.state["supervisor"] = dict(self.state.get("supervisor") or {}, pid=os.getpid(), heartbeat=t)
        write_json(self.p.state_file, self.state)
        self.dirty = False
        self.last_save = t

    def log(self, msg):
        sys.stderr.write("%s %s\n" % (iso(now()), msg))
        sys.stderr.flush()

    def legacy_installed(self, label):
        return bool(label) and os.path.exists(os.path.join(self.p.daemon_dir, label + ".plist"))

    def logfile(self, name, sub=""):
        d = os.path.join(self.p.log, sub) if sub else self.p.log
        path = os.path.join(d, name + ".log")
        try:
            if os.path.getsize(path) > 1 << 20:
                os.rename(path, path + ".1")
        except OSError:
            pass
        return open(path, "ab")

    def child_env(self, extra):
        e = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": os.path.join(self.p.state, "home"),
            "FLEET_CONF_DIR": os.path.join(self.p.state, "conf"),
            "TMPDIR": os.path.join(self.p.state, "tmp"),
            "LANG": "en_US.UTF-8",
            "FLEET_NODE": "1",
        }
        for k in ("FLEET_CREDSEP_LIB",):
            if os.environ.get(k):
                e[k] = os.environ[k]
        e.update(extra or {})
        return e

    def script_of(self, cmd):
        return script_of(cmd)

    # -- children
    def adopt(self):
        for c in self.all_children():
            cs = self.state["children"].get(c["name"]) or {}
            pid = cs.get("pid")
            if pid and pid_alive(pid) and cs.get("cmd") and pid_cmd(pid) == cs["cmd"]:
                self.adopted[c["name"]] = int(pid)
                self.log("adopted child %s pid %s" % (c["name"], pid))

    def child_status(self, c):
        if c.get("account"):
            return account_runnable(c) or "supervised"
        if not c.get("cmd"):
            return "pending"
        if any(not os.path.exists(r) for r in c.get("requires") or []):
            return "waiting"
        if self.legacy_installed(c.get("legacy")):
            return "legacy"
        if not trusted(self.script_of(c["cmd"])):
            return "untrusted"
        return "supervised"

    def tend_children(self):
        t = now()
        kids = self.all_children()
        # a child whose account was released (or whose unit left the table) stops
        live = set(c["name"] for c in kids)
        for name in [n for n in list(self.procs) + list(self.adopted) if n not in live]:
            self.stop_one(name)
        for c in kids:
            name = c["name"]
            cs = self.state["children"].setdefault(name, {})
            st = self.child_status(c)
            if cs.get("status") != st:
                cs["status"] = st
                self.dirty = True
            if st != "supervised":
                continue
            # an adopted pid: we cannot wait() on it, so poll
            if name in self.adopted:
                if pid_alive(self.adopted[name]):
                    continue
                del self.adopted[name]
                self.died(name, cs, None, t)
                continue
            if c.get("reload") and (name in self.procs or name in self.adopted) \
                    and cs.get("reload_sig") != dir_sig(c["reload"]):
                self.stop_one(name, "%s changed — starting it again" % c["reload"])
                self.start_child(c, cs, t)
                continue
            p = self.procs.get(name)
            if p is not None:
                rc = p.poll()
                if rc is None:
                    if cs.get("fails") and t - (cs.get("started") or t) >= self.backoff_reset:
                        cs["fails"] = 0
                        self.dirty = True
                    continue
                del self.procs[name]
                self.died(name, cs, rc, t)
            if t < (cs.get("next_start") or 0):
                continue
            self.start_child(c, cs, t)

    def died(self, name, cs, rc, t):
        up = t - (cs.get("started") or t)
        fails = 0 if up >= self.backoff_reset else (cs.get("fails") or 0) + 1
        delay = 0 if fails == 0 else min(self.backoff_max, 2 ** (fails - 1))
        cs.update(pid=None, last_exit=t, last_rc=rc, fails=fails, next_start=t + delay,
                  restarts=(cs.get("restarts") or 0) + 1)
        self.dirty = True
        self.log("child %s exited rc=%s after %ds; restart in %ds" % (name, rc, up, delay))

    def stop_one(self, name, why="no longer in the table"):
        p = self.procs.pop(name, None)
        pid = p.pid if p is not None else self.adopted.pop(name, None)
        if pid:
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
            if p is not None:
                try:
                    p.wait(timeout=5)
                except Exception:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except OSError:
                        pass
        cs = self.state["children"].get(name)
        if cs is not None:
            cs.update(pid=None, status="stopped")
        self.dirty = True
        self.log("child %s stopped (%s)" % (name, why))

    def start_child(self, c, cs, t):
        try:
            fh = self.logfile(c["account"], "accounts") if c.get("account") else self.logfile(c["name"])
            p = self.spawn(c, fh, c.get("env"))
            fh.close()
        except (OSError, subprocess.SubprocessError) as e:
            self.died(c["name"], cs, "spawn: %s" % e, t)
            return
        self.procs[c["name"]] = p
        cs.update(pid=p.pid, started=t, cmd=pid_cmd(p.pid) or " ".join(c["cmd"]))
        if c.get("reload"):
            cs["reload_sig"] = dir_sig(c["reload"])
        self.dirty = True
        self.log("child %s started pid %d" % (c["name"], p.pid))

    def stop_children(self):
        pids = [p.pid for p in self.procs.values()] + list(self.adopted.values())
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = now() + 5
        while now() < deadline and any(pid_alive(x) for x in pids):
            for p in self.procs.values():
                p.poll()
            time.sleep(0.1)
        for pid in pids:
            if pid_alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        for c in self.procs.values():
            try:
                c.wait(timeout=1)
            except Exception:
                pass
        for name in list(self.procs) + list(self.adopted):
            self.state["children"].get(name, {})["pid"] = None
        self.procs.clear()
        self.adopted.clear()
        self.dirty = True

    # -- tasks
    def task_due(self, tk, t):
        ts = self.state["tasks"].get(tk["name"]) or {}
        return t - (ts.get("last_start") or 0) >= float(tk.get("every", 60))

    def task_runnable(self, tk):
        if tk.get("account"):
            return account_runnable(tk)
        if tk.get("scope") == "account" or not tk.get("cmd"):
            return "deferred"
        if not trusted(self.script_of(tk["cmd"])):
            return "untrusted"
        return None

    def start_task(self, tk, t):
        name = tk["name"]
        ts = self.state["tasks"].setdefault(name, {})
        why = self.task_runnable(tk)
        if why:
            if ts.get("result") != why:
                ts["result"] = why
                self.dirty = True
            return False
        if name in self.running:
            return False
        lf = os.open(os.path.join(self.p.locks, name.replace("/", "@") + ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(lf)
            ts.update(result="busy", skipped=(ts.get("skipped") or 0) + 1)
            self.dirty = True
            return False
        if tk.get("account"):
            fh = self.logfile(tk["account"], "accounts")
            fh.write(("--- %s %s\n" % (iso(t), " ".join(tk["cmd"][6:]))).encode())
        else:
            fh = self.logfile(name, "tasks")
            fh.write(("--- %s %s\n" % (iso(t), " ".join(tk["cmd"]))).encode())
        fh.flush()
        try:
            p = self.spawn(tk, fh, tk.get("env"))
        except (OSError, subprocess.SubprocessError) as e:
            fh.close()
            os.close(lf)
            ts.update(last_start=t, last_end=t, rc=None, result="spawn failed: %s" % e)
            self.dirty = True
            return False
        self.running[name] = (p, lf, t, fh, tk)
        ts.update(last_start=t, result="running", pid=p.pid)
        self.dirty = True
        return True

    def reap_tasks(self, wait=False):
        t = now()
        for name, (p, lf, t0, fh, tk) in list(self.running.items()):
            rc = p.poll()
            limit = float(tk.get("timeout", min(600, max(30, float(tk.get("every", 60)) * 5))))
            if rc is None and t - t0 > limit:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                rc = p.wait()
                result = "timeout"
            elif rc is None:
                if not wait:
                    continue
                rc = p.wait()
                result = None
            else:
                result = None
            t1 = now()
            fh.close()
            os.close(lf)
            del self.running[name]
            ts = self.state["tasks"].setdefault(name, {})
            ts.update(last_end=t1, rc=rc, duration=round(t1 - t0, 2), pid=None,
                      runs=(ts.get("runs") or 0) + 1,
                      result=result or ("ok" if rc == 0 else "failed"))
            self.dirty = True

    def tend_tasks(self, t):
        for tk in self.all_tasks():
            if self.task_due(tk, t) or self.task_runnable(tk):
                self.start_task(tk, t)
        self.reap_tasks()

    # -- sweep
    def sweep_due(self, t):
        return t - (self.state["sweep"].get("last") or 0) >= env_num("FLEET_NODE_SWEEP_EVERY", 3600)

    def do_sweep(self, dry=False):
        res = sweep(self.p, dry=dry)
        if not dry:
            sw = self.state["sweep"]
            sw.update(last=now(), moved=len(res["moved"]), extra=len(res["extra"]),
                      purged=res["purged"], total_moved=(sw.get("total_moved") or 0) + len(res["moved"]))
            self.dirty = True
        return res

    # -- loops
    def run(self):
        self.ensure_dirs()
        lk = os.open(self.p.main_lock, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.log("another supervisor holds %s — exiting" % self.p.main_lock)
            return 3
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, self.on_signal)
        sv = self.state.get("supervisor") or {}
        self.state["supervisor"] = dict(sv, started=now(), starts=(sv.get("starts") or 0) + 1)
        # a task an earlier run left mid-flight is not running any more
        for ts in self.state["tasks"].values():
            if ts.get("result") == "running":
                ts.update(result="interrupted", pid=None)
        self.state["supervisor"]["runtime"] = runtime_sha(self.p)
        self.adopt()
        self.log("supervisor up pid %d (start #%d) on %s" % (os.getpid(), self.state["supervisor"]["starts"],
                                                            self.state["supervisor"]["runtime"] or "?"))
        tick = env_num("FLEET_NODE_TICK", 1)
        while not self.stop:
            t = now()
            if self.restart_requested():
                break
            self.tend_children()
            self.tend_tasks(t)
            if self.sweep_due(t):
                try:
                    self.do_sweep()
                except Exception as e:  # a sweep must never take the daemon down
                    self.log("sweep failed: %s" % e)
            self.save()
            time.sleep(tick)
        self.log("supervisor stopping")
        self.stop_children()
        for name, (p, lf, t0, fh, tk) in list(self.running.items()):
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
        self.reap_tasks(wait=True)
        self.save(force=True)
        return 0

    def on_signal(self, signum, frame):
        self.stop = True

    def restart_requested(self):
        """The updater switched `current` (C6, #2334): this process runs the old
        code and its children the old binaries — stop them all and exit; launchd's
        KeepAlive starts the new one from `current`. A request naming the version
        this process already runs is done: removed."""
        req = os.path.join(self.p.state, "update-restart.json")
        if not os.path.exists(req):
            return False
        to = (read_json(req, {}) or {}).get("to")
        mine = self.state["supervisor"].get("runtime")
        if runtime_sha(self.p) == mine:
            # done (this process is the new one), or stale (nothing moved): never a loop
            try:
                os.remove(req)
            except OSError:
                pass
            self.log("restart request for %s %s" % ((to or "?")[:12], "done" if to == mine else "stale — current did not move"))
            return False
        self.log("restart requested: current is %s — stopping to come back on it" % (to or "?")[:12])
        return True

    def tick_once(self):
        self.ensure_dirs()
        lk = os.open(self.p.main_lock, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("fleet-node-supervisor: a supervisor is running (%s held) — its next pass does this"
                  % self.p.main_lock, file=sys.stderr)
            return 3
        t = now()
        for tk in self.all_tasks():
            if self.task_due(tk, t) or self.task_runnable(tk):
                self.start_task(tk, t)
        self.reap_tasks(wait=True)
        self.do_sweep()
        self.dirty = True
        write_json(self.p.state_file, self.state)
        return 0


# --------------------------------------------------------------- the sweep -----
def _agent_dirs(paths):
    out = [paths.daemon_dir]
    try:
        for u in sorted(os.listdir(paths.users)):
            d = os.path.join(paths.users, u, "Library", "LaunchAgents")
            if os.path.isdir(d):
                out.append(d)
    except OSError:
        pass
    return out


def _plist_label(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f).get("Label") or ""
    except Exception:
        return ""


class attic_lock(object):
    """The attic index has two writers — the sweep and `account adopt|release`."""
    def __init__(self, paths):
        self.path = os.path.join(paths.locks, "attic.lock")

    def __enter__(self):
        d = os.path.dirname(self.path)
        if not os.path.isdir(d):
            os.makedirs(d)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        os.close(self.fd)


def sweep(paths, dry=False):
    with attic_lock(paths):
        return _sweep(paths, dry)


def _sweep(paths, dry=False):
    moved, extra = [], []
    expected = read_json(paths.expected, None)
    labels = set(expected.get("labels") or []) if isinstance(expected, dict) else None
    index = read_json(paths.attic_index, [])
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for d in _agent_dirs(paths):
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            src = os.path.join(d, n)
            if not os.path.isfile(src) or os.path.islink(src):
                continue
            if LEFTOVER_RE.match(n):
                ident = "%s-%d" % (stamp, len(index) + len(moved) + 1)
                dst = os.path.join(paths.attic, ident, n)
                moved.append({"id": ident, "src": src, "dst": dst})
                if not dry:
                    st = os.stat(src)
                    os.makedirs(os.path.dirname(dst), 0o700)
                    shutil.move(src, dst)
                    index.append({"id": ident, "src": src, "dst": dst, "moved": now(),
                                  "uid": st.st_uid, "gid": st.st_gid, "mode": st.st_mode & 0o7777})
            elif labels is not None and n.endswith(".plist") and FLEET_PLIST_RE.match(n):
                lb = _plist_label(src) or n[:-len(".plist")]
                if lb not in labels and lb != LABEL:
                    extra.append(src)
    purged = 0 if dry else attic_purge(paths, index)
    if not dry and (moved or purged):
        write_json(paths.attic_index, index, 0o600)
    return {"moved": moved, "extra": extra, "purged": purged}


def attic_purge(paths, index):
    keep = env_num("FLEET_NODE_ATTIC_DAYS", 7) * 86400
    t = now()
    gone = 0
    for e in list(index):
        if e.get("keep"):        # an adopted account's services: kept until released
            continue
        if t - e.get("moved", t) > keep:
            shutil.rmtree(os.path.dirname(e["dst"]), ignore_errors=True)
            index.remove(e)
            gone += 1
    return gone


def attic_restore(paths, ident):
    index = read_json(paths.attic_index, [])
    for e in index:
        if e["id"] == ident:
            if os.path.exists(e["src"]):
                print("fleet-node-supervisor: %s already exists — not overwriting" % e["src"], file=sys.stderr)
                return 1
            shutil.move(e["dst"], e["src"])
            try:
                os.chown(e["src"], e["uid"], e["gid"])
            except OSError:
                pass
            os.chmod(e["src"], e["mode"])
            shutil.rmtree(os.path.dirname(e["dst"]), ignore_errors=True)
            index.remove(e)
            write_json(paths.attic_index, index, 0o600)
            print("restored %s" % e["src"])
            return 0
    print("fleet-node-supervisor: no attic entry %s (see `attic list`)" % ident, file=sys.stderr)
    return 1


# --------------------------------------------------------------- adopt / release --
def launchctl_loaded(target):
    """Is <domain>/<label> loaded? No launchctl (the test seam '') ⇒ no."""
    lc = os.environ.get("FLEET_NODE_LAUNCHCTL", "/bin/launchctl")
    if not lc:
        return False
    return subprocess.call([lc, "print", target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def launchctl_gone(target):
    """Wait for <target> to leave launchd. `bootout` of a KeepAlive job returns
    while launchd is still tearing it down, so ONE `print` right after it reads
    «still loaded» (m4, issue #2336): poll for FLEET_NODE_BOOTOUT_WAIT seconds."""
    end = now() + env_num("FLEET_NODE_BOOTOUT_WAIT", 15)
    while launchctl_loaded(target):
        if now() >= end:
            return False
        time.sleep(0.25)
    return True


def launchctl_bootstrap(domain, path):
    """bootstrap, retried while launchd still holds the old copy of the job
    (a bootout a moment ago answers EIO / «already loaded» until it is gone)."""
    end = now() + env_num("FLEET_NODE_BOOTOUT_WAIT", 15)
    while True:
        rc = launchctl("bootstrap", domain, path)
        if rc == 0 or now() >= end:
            return rc
        time.sleep(0.5)


def account_services(paths, login, uid, home):
    """The login's own fleet services: [{path, label, domain}] — its gui
    LaunchAgents and its system LaunchDaemons (com.claude-fleet.<login>.<unit>)."""
    out = []
    la = os.path.join(home, "Library", "LaunchAgents")
    # root moves files out of a login's directory: only out of the real one, its own
    try:
        st = os.lstat(la)
        own = not os.path.islink(la) and (st.st_uid == uid or env("FLEET_NODE_TEST", "") == "1")
    except OSError:
        own = False
    for f in sorted(glob.glob(os.path.join(la, "com.claude-fleet.*.plist"))) if own else []:
        out.append({"path": f, "domain": "gui/%d" % uid})
    for f in sorted(glob.glob(os.path.join(paths.daemon_dir, "com.claude-fleet.%s.*.plist" % login))):
        out.append({"path": f, "domain": "system"})
    keep = []
    for s in out:
        if os.path.islink(s["path"]) or not os.path.isfile(s["path"]):
            continue
        s["label"] = _plist_label(s["path"]) or os.path.basename(s["path"])[:-len(".plist")]
        if s["label"] == LABEL or s["label"].split(".")[-1] in MACHINE_UNITS[1:]:
            continue
        keep.append(s)
    return keep


# The login's own node agent (#2387): what `ccquota agent --machine` (C5, #2333)
# serves it from instead is <state>/logins/<login>.env, written here, at adopt.
AGENT_ENV_KEYS = re.compile(r"^(CCQUOTA_[A-Z0-9_]+|FLEET_CONF_DIR)$")


def _env_file(path, uid):
    """KEY=VALUE lines of a node.env, PARSED (never sourced). Root reads a file in a
    login's home: never through a symlink, only one that login (or root) owns."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return None
    with os.fdopen(fd) as f:
        st = os.fstat(f.fileno())
        if st.st_uid not in (uid, 0) and env("FLEET_NODE_TEST", "") != "1":
            return None
        out = {}
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            k, eq, v = line.partition("=")
            v = v.strip()
            if len(v) >= 2 and v[0] in "\"'" and v[-1] == v[0]:
                v = v[1:-1]
            if eq and k.strip():
                out[k.strip()] = v
        return out


def account_agent(paths, login, uid, home):
    """The login's own ccquota node agent and the settings the machine's agent
    serves it with: {path, label, domain, env, node_env} · None (no agent) ·
    a string (an agent whose settings carry no token — adopt refuses)."""
    cands = [(os.path.join(paths.daemon_dir, "com.ccquota.agent.%s.plist" % login), "system"),
             (os.path.join(home, "Library", "LaunchAgents", "com.ccquota.agent.plist"), "gui/%d" % uid)]
    for path, domain in cands:
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as f:
                pl = plistlib.load(f)
        except Exception as e:  # noqa: BLE001 — one line, no traceback
            return "%s: not a plist (%s)" % (path, e)
        pe = pl.get("EnvironmentVariables") if isinstance(pl, dict) else None
        out = {}
        for k, v in (pe if isinstance(pe, dict) else {}).items():
            if AGENT_ENV_KEYS.match(k) and isinstance(v, str) and v:
                out[k] = v
        # the token: a separated login keeps it in root's credsep store (issue
        # #1971, fleet-credsep-launch.py's agent branch), any other in its conf dir
        cbase = env("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred")
        meta = read_json(os.path.join(cbase, login, "meta.json"), None)
        if isinstance(meta, dict) and meta.get("login") == login:
            ne_path = os.path.join(cbase, login, "node.env")
            ne = _env_file(ne_path, 0)
            run = env("FLEET_CREDSEP_RUN_BASE", "/var/run/fleet-cred")
            store = os.path.join(run, ".shared", "ctl.sock") if meta.get("mode") == "shared" \
                else os.path.join(run, login, "ctl.sock")
        else:
            conf = out.get("FLEET_CONF_DIR") or os.path.join(home, ".config", "claude-fleet")
            ne_path = os.path.join(conf, "node.env")
            ne = _env_file(ne_path, uid)
            store = None
        for k, v in (ne or {}).items():
            if k.startswith("CCQUOTA_") and v:
                out[k] = v
        if store:
            out["CCQUOTA_FLEET_CRED_STORE"] = store
        if not out.get("CCQUOTA_TOKEN"):
            return "%s: no CCQUOTA_TOKEN in its EnvironmentVariables or %s" % (path, ne_path)
        return {"path": path, "domain": domain, "label": _plist_label(path) or os.path.basename(path)[:-len(".plist")],
                "env": out, "node_env": ne_path}
    return None


def login_env_path(paths, login):
    return os.path.join(paths.logins, login + ".env")


def write_login_env(paths, login, kv):
    """<state>/logins/<login>.env: root 0600, written whole by one rename."""
    if not os.path.isdir(paths.logins):
        os.makedirs(paths.logins)
    os.chmod(paths.logins, 0o700)
    dst = login_env_path(paths, login)
    tmp = "%s.tmp-%d" % (dst, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write("# claude-fleet account adopt (issue #2387): %s's node agent settings — holds its token, root 0600\n"
                    % login)
            for k in sorted(kv):
                v = kv[k].replace("\n", "")
                if v[:1] in ("'", '"'):
                    v = ("'%s'" if v[:1] == '"' else '"%s"') % v
                f.write("%s=%s\n" % (k, v))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, dst)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def remove_login_env(paths, login):
    try:
        os.unlink(login_env_path(paths, login))
        return True
    except OSError:
        return False


def _accounts_write(paths, a):
    if not os.path.isdir(paths.state):
        os.makedirs(paths.state)
    write_json(paths.accounts, a, 0o644)


def _put_back(paths, e):
    """An attic entry back where it was, loaded again."""
    shutil.move(e["dst"], e["src"])
    try:
        os.chown(e["src"], e["uid"], e["gid"])
    except OSError:
        pass
    os.chmod(e["src"], e["mode"])
    shutil.rmtree(os.path.dirname(e["dst"]), ignore_errors=True)
    if e.get("domain"):
        launchctl_bootstrap(e["domain"], e["src"])


def account_adopt(paths, login, dry=False):
    ident = account_ident(login)
    if ident is None:
        print("fleet-node-supervisor: %s is not a login this daemon may run as" % login, file=sys.stderr)
        return 2
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: account adopt boots out %s's services — run it as root (sudo)" % login,
              file=sys.stderr)
        return 1
    uid, gid, home = ident
    a = accounts_read(paths)
    was = a.get(login) if (a.get(login) or {}).get("managed") else None
    agent = account_agent(paths, login, uid, home)
    if was is not None and agent is None:
        print("%s already managed since %s" % (login, iso(was.get("since"))))
        return 0
    # adopted before #2387: only the node agent left behind moves now
    svcs = [] if was is not None else account_services(paths, login, uid, home)
    if isinstance(agent, str):
        # the machine's agent could not serve it: its own stays, nothing moves
        print("fleet-node-supervisor: %s — nothing moved; fix the token (bin/fleet-hub-node.sh env --write) and adopt again"
              % agent, file=sys.stderr)
        return 1
    if agent:
        svcs.append(agent)
    if dry:
        for sv in svcs:
            print("would boot out %s/%s and move %s to the attic" % (sv["domain"], sv["label"], sv["path"]))
        if agent:
            print("would write %s (0600) with %s" % (login_env_path(paths, login), " ".join(sorted(agent["env"]))))
        print("would run %d account units as %s" % (len(account_units(paths, load_table(paths))), login))
        return 0
    Supervisor(paths, {"children": [], "tasks": []}).ensure_dirs()
    moved = []
    with attic_lock(paths):
        index = read_json(paths.attic_index, [])
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        for sv in svcs:
            target = "%s/%s" % (sv["domain"], sv["label"])
            launchctl("bootout", target)
            if not launchctl_gone(target):
                # one that will not unload: every service of this login goes back
                print("fleet-node-supervisor: %s did not unload — putting %s's %d moved service(s) back"
                      % (target, login, len(moved)), file=sys.stderr)
                _undo(paths, index, moved)
                return 1
            ident_ = "%s-%s-%d" % (stamp, login, len(index) + 1)
            dst = os.path.join(paths.attic, ident_, os.path.basename(sv["path"]))
            st = os.stat(sv["path"])
            os.makedirs(os.path.dirname(dst), 0o700)
            shutil.move(sv["path"], dst)
            e = {"id": ident_, "src": sv["path"], "dst": dst, "moved": now(), "uid": st.st_uid,
                 "gid": st.st_gid, "mode": st.st_mode & 0o7777, "keep": True, "account": login,
                 "label": sv["label"], "domain": sv["domain"]}
            index.append(e)
            moved.append(e)
        # only once the old agent is out: never two agents speaking for one login
        if agent:
            try:
                write_login_env(paths, login, agent["env"])
            except OSError as ex:
                print("fleet-node-supervisor: cannot write %s (%s) — putting %s's %d moved service(s) back"
                      % (login_env_path(paths, login), ex.strerror or ex, login, len(moved)), file=sys.stderr)
                _undo(paths, index, moved)
                remove_login_env(paths, login)
                return 1
        write_json(paths.attic_index, index, 0o600)
    a[login] = {"managed": True, "since": (was or {}).get("since") or now(), "uid": uid, "home": home,
                "attic": list((was or {}).get("attic") or []) + [e["id"] for e in moved]}
    if agent:
        a[login]["login_env"] = login_env_path(paths, login)
    _accounts_write(paths, a)
    print("adopted %s: %d service(s) booted out and kept in the attic; its tasks now run under %s"
          % (login, len(moved), LABEL))
    if agent:
        print("  its node agent %s → %s (keys: %s)" % (agent["label"], login_env_path(paths, login),
                                                     " ".join(sorted(agent["env"]))))
    return 0


def _undo(paths, index, moved):
    for e in reversed(moved):
        _put_back(paths, e)
        index.remove(e)
    write_json(paths.attic_index, index, 0o600)


def _account_running(paths, login):
    st = read_json(paths.state_file, {})
    for kind in ("children", "tasks"):
        for name, x in (st.get(kind) or {}).items():
            if name.startswith(login + "/") and x.get("pid") and pid_alive(x["pid"]):
                return True
    return False


def _node_agent_stale(paths):
    """The machine's node agent still runs on a logins/ it read before a change."""
    cs = (read_json(paths.state_file, {}).get("children") or {}).get("node-agent") or {}
    return bool(cs.get("pid")) and pid_alive(cs["pid"]) and cs.get("reload_sig") != dir_sig(paths.logins)


def account_release(paths, login):
    """The way back, one command: stop running as <login>, put its services back."""
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: account release loads %s's services back — run it as root (sudo)" % login,
              file=sys.stderr)
        return 1
    a = accounts_read(paths)
    if not (a.get(login) or {}).get("managed"):
        print("fleet-node-supervisor: %s is not managed" % login, file=sys.stderr)
        return 1
    a[login] = dict(a[login], managed=False, released=now())
    _accounts_write(paths, a)
    # the machine's agent stops speaking for it (it restarts on logins/ changing)
    # before its own agent comes back below
    gone_env = remove_login_env(paths, login)
    # the running daemon drops the login's entries on its next pass; wait for it,
    # so the old services never run beside ours
    sv = read_json(paths.state_file, {}).get("supervisor") or {}
    if pid_alive(sv.get("pid")):
        end = now() + env_num("FLEET_NODE_RELEASE_WAIT", 20)
        while now() < end and (_account_running(paths, login) or (gone_env and _node_agent_stale(paths))):
            time.sleep(0.2)
    back = 0
    with attic_lock(paths):
        index = read_json(paths.attic_index, [])
        for e in [x for x in index if x.get("account") == login and x.get("keep")]:
            if os.path.exists(e["src"]):
                print("fleet-node-supervisor: %s already exists — left the attic copy %s" % (e["src"], e["id"]),
                      file=sys.stderr)
                continue
            _put_back(paths, e)
            index.remove(e)
            back += 1
        write_json(paths.attic_index, index, 0o600)
    print("released %s: %d service(s) put back and loaded" % (login, back))
    return 0


# --------------------------------------------------------------- status ---------
def installed(paths):
    return os.path.exists(paths.plist) or os.path.exists(paths.state_file)


def health(paths, state):
    """(code, word): 0 ok · 1 installed but not running · 2 not installed."""
    if not installed(paths):
        return 2, "not installed"
    sv = state.get("supervisor") or {}
    stale = env_num("FLEET_NODE_HEARTBEAT_STALE", 120)
    hb = sv.get("heartbeat") or 0
    if not pid_alive(sv.get("pid")):
        return 1, "DOWN (pid %s gone, heartbeat %s ago)" % (sv.get("pid") or "-", ago(hb))
    if now() - hb > stale:
        return 1, "STALE (heartbeat %s ago)" % ago(hb)
    return 0, "ok"


def status_lines(paths, table, state):
    code, word = health(paths, state)
    sv = state.get("supervisor") or {}
    out = ["supervisor  %s · pid %s · up %s · heartbeat %s ago · starts %s"
           % (word, sv.get("pid") or "-", ago(sv.get("started")), ago(sv.get("heartbeat")),
              sv.get("starts") or 0)]
    sup = Supervisor.__new__(Supervisor)
    sup.p = paths
    for c in table["children"]:
        cs = state.get("children", {}).get(c["name"]) or {}
        st = sup.child_status(c)
        if st == "pending":
            what = "not yet (%s)" % c.get("note", "")
        elif st == "waiting":
            what = "waiting — %s missing" % ", ".join(r for r in c.get("requires") or [] if not os.path.exists(r))
        elif st == "legacy":
            what = "legacy — launchd's %s still runs it" % c.get("legacy")
        elif st == "untrusted":
            what = "REFUSED — %s is not root-owned / is writable" % sup.script_of(c["cmd"])
        elif pid_alive(cs.get("pid")):
            what = "running pid %s · up %s" % (cs["pid"], ago(cs.get("started")))
        else:
            what = "down · restart at %s" % iso(cs.get("next_start"))
        out.append("child  %-18s %s · restarts %s · last exit %s rc=%s"
                   % (c["name"], what, cs.get("restarts") or 0, iso(cs.get("last_exit")), cs.get("last_rc")))
    for tk in table["tasks"]:
        ts = state.get("tasks", {}).get(tk["name"]) or {}
        if tk.get("scope") == "account" or not tk.get("cmd"):
            out.append("task   %-18s deferred — an account task (%s)" % (tk["name"], tk.get("note", "")))
            continue
        out.append("task   %-18s last %s · %s rc=%s · %ss · runs %s"
                   % (tk["name"], iso(ts.get("last_start")), ts.get("result") or "never",
                      ts.get("rc"), ts.get("duration", "-"), ts.get("runs") or 0))
    for login, why in managed_accounts(paths).items():
        if why:
            out.append("account %-17s %s" % (login, why))
            continue
        units = account_units(paths, table)
        bad, ok, last = [], 0, 0
        for u in units:
            key = "%s/%s" % (login, u["name"])
            x = (state.get("children" if u.get("keepalive") else "tasks") or {}).get(key) or {}
            if u.get("keepalive"):
                good = pid_alive(x.get("pid"))
            else:
                good = x.get("result") == "ok" or (x.get("result") == "running" and x.get("rc") in (0, None))
                last = max(last, x.get("last_start") or 0)
            if good:
                ok += 1
            else:
                bad.append("%s %s" % (u["name"], x.get("result") or x.get("status") or "never"))
        out.append("account %-17s %d/%d ok · last run %s%s"
                   % (login, ok, len(units), iso(last), (" · " + ", ".join(bad)) if bad else ""))
    sw = state.get("sweep") or {}
    out.append("sweep  %-18s last %s · moved %s (total %s) · extra %s (report only) · attic %d entries"
               % ("leftovers", iso(sw.get("last")), sw.get("moved", 0), sw.get("total_moved", 0),
                  sw.get("extra", 0), len(read_json(paths.attic_index, []))))
    return code, out


# --------------------------------------------------------------- install --------
def plist_body(paths):
    script = os.path.join(paths.runtime, "bin", "fleet-node-supervisor.py")
    return {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", "-I", script, "run"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 5,
        "ProcessType": "Standard",
        "SoftResourceLimits": {"NumberOfFiles": 65536},
        "HardResourceLimits": {"NumberOfFiles": 65536},
        # root logs never land in a login's directory (EPIC #2293, credsep `rootlog`)
        "StandardOutPath": os.path.join(paths.log, "supervisor.log"),
        "StandardErrorPath": os.path.join(paths.log, "supervisor.log"),
    }


def launchctl(*args):
    lc = os.environ.get("FLEET_NODE_LAUNCHCTL", "/bin/launchctl")
    if not lc:
        return 0
    return subprocess.call([lc] + list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def install(paths):
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: install writes %s — run it as root (sudo)" % paths.plist, file=sys.stderr)
        return 1
    script = os.path.join(paths.runtime, "bin", "fleet-node-supervisor.py")
    if not trusted(script):
        print("fleet-node-supervisor: %s is missing, not root-owned or writable — root runs only the root "
              "runtime (共同约定 3); stage it first" % script, file=sys.stderr)
        return 1
    Supervisor(paths, {"children": [], "tasks": []}).ensure_dirs()
    tmp = paths.plist + ".tmp-node"
    with open(tmp, "wb") as f:
        plistlib.dump(plist_body(paths), f)
    os.chmod(tmp, 0o644)
    launchctl("bootout", "system/" + LABEL)
    os.rename(tmp, paths.plist)
    rc = launchctl("bootstrap", "system", paths.plist)
    print("installed %s%s" % (paths.plist, "" if rc == 0 else " (launchctl bootstrap rc=%d)" % rc))
    return 0 if rc == 0 else 1


def install_check(paths):
    """0 = the LaunchDaemon on disk is the one install writes and launchd has it
    loaded (`fleet node install`'s 守护 step skips); 1 = install would change it."""
    try:
        with open(paths.plist, "rb") as f:
            if plistlib.load(f) != plist_body(paths):
                return 1
    except Exception:
        return 1
    return 0 if launchctl("print", "system/" + LABEL) == 0 else 1


def uninstall(paths):
    launchctl("bootout", "system/" + LABEL)
    try:
        os.remove(paths.plist)
    except OSError:
        pass
    print("removed %s (state kept in %s)" % (paths.plist, paths.state))
    return 0


# --------------------------------------------------------------- main -----------
def main(argv):
    paths = Paths()
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    if cmd == "install":
        return install_check(paths) if "--check" in rest else install(paths)
    if cmd == "uninstall":
        return uninstall(paths)
    if cmd == "account":
        sub = rest[0] if rest else "list"
        if sub == "list":
            for login, a in sorted(accounts_read(paths).items()):
                print("%s  %s since %s" % (login, "managed" if a.get("managed") else "released",
                                           iso(a.get("since"))))
            return 0
        if sub == "manages" and len(rest) > 1:
            return 0 if (accounts_read(paths).get(rest[1]) or {}).get("managed") else 1
        if sub == "adopt" and len(rest) > 1:
            return account_adopt(paths, rest[1], dry="--dry-run" in rest)
        if sub == "release" and len(rest) > 1:
            return account_release(paths, rest[1])
    table = load_table(paths)
    if cmd == "run":
        return Supervisor(paths, table).run()
    if cmd == "tick":
        return Supervisor(paths, table).tick_once()
    if cmd == "status":
        state = read_json(paths.state_file, {})
        code, lines = status_lines(paths, table, state)
        if "--json" in rest:
            print(json.dumps({"health": code, "state": state}, indent=1, sort_keys=True))
        elif "--check" in rest:
            print(lines[0])
        else:
            print("\n".join(lines))
        return code if "--check" in rest else 0
    if cmd == "sweep":
        dry = "--dry-run" in rest
        sup = Supervisor(paths, table)
        sup.ensure_dirs()
        res = sup.do_sweep(dry=dry)
        if not dry:
            write_json(paths.state_file, sup.state)
        for m in res["moved"]:
            print("%s %s -> attic %s" % ("would move" if dry else "moved", m["src"], m["id"]))
        for x in res["extra"]:
            print("extra (not in expected.json, left in place): %s" % x)
        return 0
    if cmd == "attic":
        sub = rest[0] if rest else "list"
        if sub == "list":
            for e in read_json(paths.attic_index, []):
                print("%s  %s  moved %s%s" % (e["id"], e["src"], iso(e.get("moved")),
                                              "  (account %s, kept)" % e["account"] if e.get("keep") else ""))
            return 0
        if sub == "restore" and len(rest) > 1:
            return attic_restore(paths, rest[1])
        if sub == "purge":
            index = read_json(paths.attic_index, [])
            n = attic_purge(paths, index)
            write_json(paths.attic_index, index, 0o600)
            print("purged %d" % n)
            return 0
    print("usage: fleet-node-supervisor.py run|tick|status [--json|--check]|sweep [--dry-run]|"
          "attic [list|restore <id>|purge]|account [list|adopt|release|manages <login>]|install|uninstall",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
