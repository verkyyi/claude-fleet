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
  * services  — the login-level register (issue #2525, EPIC #2524 C1): a program a
                person keeps running as themselves is one root-owned entry,
                <state>/logins/<login>/services/<name>.json, which this daemon runs
                as a child demoted to that login — kept up with the children's
                backoff, its output in <log>/logins/<login>/<name>.log, the
                credentials it names injected at start from
                <state>/logins/<login>/creds/. `fleet service` (bin/fleet-service.sh)
                is the person's command; `status --json` carries `services[]`.
                `service move` hands one entry to another login whole — its
                paths[], log and credentials with it (issue #2528); `account
                release` refuses (6) while the login still has entries.
                Its second kind, `kind: task` (issue #2529, C5), is a scheduled agent
                session: at each slot (`at` / `cron`, a tz) the daemon runs
                bin/fleet-task-run.sh as the login — the login's own dash-raw-session.sh
                opens the session — retries a failed run, then marks it failed and
                writes an alert. `fleet task` (bin/fleet-task.sh) is its command.
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
                It also NAMES, never touches, a login that still carries the
                person's client here (issue #2702): `~/.cache/claude-fleet/shell`
                or a `~/.zshrc` line that sources shell/fleet-login.zsh / cw.zsh /
                the old bootstrap block — a managed machine is no one's client;
                bin/fleet-node-shell-retire.sh --login <login> clears it. Both
                halves look ONLY at the logins this daemon took over
                (logins/<login>.env): an admin, a local user who never used the
                fleet — not the fleet's, never named.

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
                                               running (stale heartbeat) · 2 not installed ·
                                               3 running, but the hub refuses a login's lane
                                               (令牌失效 · 需要 relogin, issue #2501)
  fleet-node-supervisor.py sweep [--dry-run]   the leftover sweep, now
  fleet-node-supervisor.py attic [list | restore <id> | purge]
  fleet-node-supervisor.py service add|rm|stop|start|restart|move|run|schedule|cred|ls|logs …
                                               the login-level register (#2525; writes as root,
                                               ls / logs as anyone who may read them)
  fleet-node-supervisor.py install | uninstall write / remove the LaunchDaemon (root)
  fleet-node-supervisor.py install --check     exit 0 = already installed as install writes it
                                               and loaded (fleet-node-install.sh, #2330)
  fleet-node-supervisor.py account [list | adopt <login> | release <login> [--force] | manages <login>]
                                               the account half (#2332); manages: exit 0 = this
                                               daemon runs <login>'s tasks (install-apply, doctor)
  fleet-node-supervisor.py account adopt <login> --rejoin
                                               a new node token for <login> (issue #2501): its
                                               device key asks the hub (`fleet-login.py
                                               node-pass`, run as <login>), the pass goes into
                                               the credential store + logins/<login>.env — the
                                               way back when the hub refuses its lane; no admin
                                               browser session

Seams (sandbox tests, docs/BREAK-IT.md `node-supervisor-dead`):
  FLEET_NODE_STATE      /var/db/fleet-node          FLEET_NODE_LOG   /var/log/fleet-node
  FLEET_NODE_RUNTIME    /Library/Application Support/claude-fleet/current
  FLEET_NODE_DAEMON_DIR /Library/LaunchDaemons      FLEET_NODE_USERS /Users
  FLEET_NODE_LOGIN_PY   fleet-login.py --rejoin runs (default <runtime>/bin/fleet-login.py)
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

import datetime
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
import tempfile
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


def requires_missing(c):
    """The child's requirements not met yet: a path that does not exist, or a
    pattern (`*`) that matches nothing — `logins/*.env` on an empty directory."""
    return [r for r in c.get("requires") or []
            if not (glob.glob(r) if "*" in r else os.path.exists(r))]


def dir_sig(d):
    """What a directory holds, as one string: each entry's name, size and mtime.
    A pattern (`*`) is the files it matches, a file is itself (issue #2525)."""
    if "*" in d:
        names = sorted(glob.glob(d))
    elif os.path.isfile(d):
        names = [d]
    else:
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
             "legacy": "com.claude-fleet.cred-proxy-shared",
             # it runs root's code copy in LIB, which the updater refreshes from
             # `current` on every switch / rollback (issue #2435): a new copy (or a
             # login's <L>.conf) starts it again on the new bytes
             "reload": cred_lib},
            # The one node program for every login (C5, #2333): one link to the
            # hub with the machine's token, each login a tenant run as itself.
            # Waits until the machine has its token (machine.env) and at least
            # one login in it (logins/*.env, #2421: an empty directory made
            # ccquota exit 1 once a minute) — the migration writes both, login
            # by login.
            {"name": "node-agent",
             "cmd": [os.path.join(rt_bin, "ccquota"), "agent", "--machine",
                     "--machine-env", os.path.join(paths.state, "machine.env"),
                     "--logins", os.path.join(paths.state, "logins"),
                     "--state", os.path.join(paths.state, "agent")],
             "requires": [os.path.join(paths.state, "machine.env"),
                          os.path.join(paths.state, "logins", "*.env")],
             # it reads its tenants once, at start: an adopt / release (#2387)
             # changes them, and the daemon starts it again on them — the
             # <login>.env files only: a login's services/ (#2525) is not a tenant
             "reload": os.path.join(paths.state, "logins", "*.env"),
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
            # The machine's shared dirs (#2299): /Users/Shared/claude-fleet and its
            # heavy/ + sessions/ root's and 1777, the heavy slots root's 0644, any
            # file planted under another login's name swept — each login its own.
            {"name": "shared-dirs", "every": 60,
             "cmd": ["/usr/bin/python3", "-I", os.path.join(rt_bin, "fleet-shared-dirs.py")]},
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
# directory) and takes the login's own TMPDIR, as the system-shape plists did —
# with none, the per-uid one, never the shared /tmp (issue #2450).
ACCOUNT_SH = ('TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; [ -n "$TMPDIR" ] || { TMPDIR="/tmp/claude-fleet-$(id -u)"; mkdir -p -m 700 "$TMPDIR" 2>/dev/null; }; export TMPDIR; '
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


# --------------------------------------------------------------- services -------
# The login-level register (issue #2525, EPIC #2524 C1): a program a person keeps
# running AS THEMSELVES on the machine is one root-owned JSON (0600) in
# <state>/logins/<login>/services/<name>.json — `fleet service add` (bin/
# fleet-service.sh) hands it to root through `service add`. The daemon runs each
# `kind: service` entry as a child demoted to its login (the account half's own
# road: initgroups/setgid/setuid, its HOME / USER / TMPDIR), keeps it up with the
# children's backoff, and the demoted process appends its stdout + stderr to
# <log>/logins/<login>/<name>.log (the directory is the login's; root never writes
# in it). A credential it names is injected at start from
# <state>/logins/<login>/creds/<name> (root 0600) — the entry holds the name only.
# Editing the entry (stop / start / restart rewrite it) starts it again; removing
# it stops it. `status --json` carries `services[]`.
SVC_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,47}$")
LOGIN_RE = re.compile(r"^[a-z0-9_][a-z0-9_.-]{0,31}$")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
SVC_KINDS = ("service", "task")   # task: an agent session on a schedule (#2529)
SVC_STATES = ("enabled", "stopped")
SVC_ENV_DROP = ("HOME", "USER", "LOGNAME", "FLEET_SERVICE", "FLEET_NODE_ACCOUNT", "FLEET_TASK_PROMPT",
                "FLEET_TASK_WINDOW", "FLEET_TASK_DONE_FILE", "FLEET_TASK_TIMEOUT", "FLEET_TASK_IDLE",
                "FLEET_TASK_FLEET", "FLEET_TASK_ATTEMPT", "FLEET_TASK_SLOT", "FLEET_TASK_BARK_CRED")
SVC_LINE_MAX = 200


def service_dir(paths, login):
    return os.path.join(paths.logins, login, "services")


def service_cred_dir(paths, login):
    return os.path.join(paths.logins, login, "creds")


def service_log(paths, login, name):
    return os.path.join(paths.log, "logins", login, name + ".log")


def service_check(svc, login=None, name=None):
    """Why an entry is not a valid one, or None."""
    if not isinstance(svc, dict):
        return "not a JSON object"
    if not SVC_NAME_RE.match(str(svc.get("name") or "")):
        return "bad name %r" % svc.get("name")
    if not LOGIN_RE.match(str(svc.get("login") or "")):
        return "bad login %r" % svc.get("login")
    if login is not None and svc["login"] != login:
        return "login %s in %s's register" % (svc["login"], login)
    if name is not None and svc["name"] != name:
        return "name %s in %s.json" % (svc["name"], name)
    if svc.get("kind", "service") not in SVC_KINDS:
        return "kind %r — only %s" % (svc.get("kind"), "/".join(SVC_KINDS))
    if svc.get("kind", "service") == "task":
        why = task_check(svc)
        if why:
            return why
    else:
        ex = svc.get("exec")
        if not isinstance(ex, list) or not ex or not all(isinstance(a, str) for a in ex):
            return "exec must be a non-empty list of strings"
        if not os.path.isabs(ex[0]):
            return "exec[0] %s is not an absolute path" % ex[0]
    if svc.get("state", "enabled") not in SVC_STATES:
        return "state %r" % svc.get("state")
    env_ = svc.get("env") or {}
    if not isinstance(env_, dict) or not all(ENV_KEY_RE.match(k) and isinstance(v, str)
                                              for k, v in env_.items()):
        return "env must map NAME to a string"
    for f in ("env_keys", "creds", "paths"):
        if not isinstance(svc.get(f) or [], list):
            return "%s must be a list" % f
    for c in svc.get("creds") or []:
        if not ENV_KEY_RE.match(str(c)):
            return "bad credential name %r" % c
    return None


def service_files(paths):
    """[(login, name, path, entry or None, why-not or None)] of every register."""
    out = []
    for f in sorted(glob.glob(os.path.join(paths.logins, "*", "services", "*.json"))):
        login = os.path.basename(os.path.dirname(os.path.dirname(f)))
        name = os.path.basename(f)[:-len(".json")]
        if not trusted(f):
            out.append((login, name, f, None, "REFUSED — not root-owned / writable"))
            continue
        svc = read_json(f, None)
        why = service_check(svc, login, name)
        out.append((login, name, f, None if why else svc, why))
    return out


def service_entry(paths, svc, path, ident):
    """A service as a child of the daemon (account_entry's shape)."""
    uid, gid, home = ident
    login, name = svc["login"], svc["name"]
    e = {"PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
    e.update((k, v) for k, v in (svc.get("env") or {}).items() if k not in SVC_ENV_DROP)
    e.update(HOME=home, USER=login, LOGNAME=login, FLEET_SERVICE=name)
    lg = service_log(paths, login, name)
    return {"name": "svc:%s/%s" % (login, name), "account": login, "service": name,
            "uid": uid, "gid": gid, "home": home, "env": e, "keepalive": True,
            "creds": list(svc.get("creds") or []), "script": svc["exec"][0],
            "logdir": os.path.dirname(lg), "reload": path,
            "cmd": ["/bin/sh", "-c", ACCOUNT_SH, "fleet-service", lg, lg] + list(svc["exec"])}


def service_creds(paths, ent):
    """{name: value} of the credentials an entry names, and the missing ones."""
    got, missing = {}, []
    d = service_cred_dir(paths, ent["account"])
    for c in ent.get("creds") or []:
        try:
            fd = os.open(os.path.join(d, c), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(fd) as f:
                got[c] = f.read().rstrip("\n")
        except (IOError, OSError):
            missing.append(c)
    return got, missing


def service_logdir(ent):
    """<log>/logins/<login>/ — the login's own, so the demoted process opens its
    log itself; the log rotated at 1 MB (a rename: never follows a link)."""
    d = ent["logdir"]
    if not os.path.isdir(d):
        os.makedirs(d, 0o755)
    if os.geteuid() == 0:
        st = os.lstat(d)
        if st.st_uid != ent["uid"]:
            os.lchown(d, ent["uid"], ent["gid"])
    lg = ent["cmd"][4]
    try:
        st = os.lstat(lg)
        if st.st_size > 1 << 20:
            os.rename(lg, lg + ".1")
    except OSError:
        pass


def log_tail(path, n=1, limit=SVC_LINE_MAX):
    """The last n lines of a log (each at most limit bytes), or [] — never a link."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return []
    with os.fdopen(fd, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 65536))
        lines = f.read().decode("utf-8", "replace").splitlines()
    return [l[:limit] for l in lines if l.strip()][-n:]


def services_summary(paths, state, tail=False):
    """services[] for state.json / status --json: what each entry is and how it
    runs — names only, never an env value or a credential. tail: + the log's last
    line (status, as a reader that may read it; never into the 0644 state.json)."""
    out = []
    for login, name, path, svc, why in service_files(paths):
        key = "svc:%s/%s" % (login, name)
        cs = (state.get("children") or {}).get(key) or {}
        row = {"name": name, "login": login, "kind": "service", "file": path,
               "log": service_log(paths, login, name)}
        if svc is None:
            row.update(status="invalid", why=why)
            out.append(row)
            continue
        row.update(kind=svc.get("kind", "service"), state=svc.get("state", "enabled"),
                   env_keys=sorted(set(list(svc.get("env_keys") or []) + list((svc.get("env") or {}).keys()))),
                   creds=list(svc.get("creds") or []), paths=list(svc.get("paths") or []),
                   added=svc.get("added"), pid=None)
        if row["kind"] == "task":
            row.update(task_summary(paths, svc, (state.get("agent_tasks") or {}).get("%s/%s" % (login, name)) or {}))
            if tail:
                t = log_tail(row["log"])
                row["last_line"] = t[-1] if t else None
            out.append(row)
            continue
        row.update(exec=svc["exec"], started=cs.get("started"), restarts=cs.get("restarts") or 0,
                   last_exit=cs.get("last_exit"), last_rc=cs.get("last_rc"))
        if row["state"] == "stopped":
            row["status"] = "stopped"
        elif account_ident(login) is None:
            row["status"] = "no such login"
        elif pid_alive(cs.get("pid")):
            row.update(status="running", pid=cs["pid"])
        else:
            st = cs.get("status")
            row["status"] = st if st and st not in ("supervised", "stopped") else "down"
            row["next_start"] = cs.get("next_start")
        if tail:
            t = log_tail(row["log"])
            row["last_line"] = t[-1] if t else None
        out.append(row)
    return out


# --------------------------------------------------------------- agent tasks ----
# The register's second kind (issue #2529, EPIC #2524 C5): `kind: task` is "at this
# time, as this login, open a session that runs this prompt". The entry has no
# exec: when a slot is due the daemon runs bin/fleet-task-run.sh demoted to the
# login, which opens the session through the login's own
# `dash-raw-session.sh --no-repo --origin hub --print --name <window> --prompt <p>`
# (adopting a window of that name instead when one is already open) and, with
# `done_when.file`, waits for the session to finish with that file in place. Its
# exit code is the attempt's verdict; a failed one is tried again after
# `retry_delay` up to `retries` more times, then the task reads `failed` and an
# alert lands in <state>/logins/<login>/alerts/<name>.json (+ a Bark push when the
# entry names one). Every attempt is kept in <state>/logins/<login>/runs/<name>.json;
# state.json's `agent_tasks` and services[] carry last_run / next_run / status.
#   schedule: {"at": "07:00", "tz": "Asia/Shanghai"} or {"cron": "m h dom mon dow", "tz": …}
#   window:   the session's name, `{date}` = the slot's day (default <name>-{date});
#             a retry adds -<attempt>
HHMM_RE = re.compile(r"^([01]?[0-9]|2[0-3]):([0-5][0-9])$")
TASK_RETRIES_MAX = 10
TASK_RUNS_KEEP = 60
TASK_RC = {10: "bad setup (no prompt / spawner / fleet)", 11: "the session did not open",
           12: "timed out waiting for the session", 13: "the session finished without its output"}


def task_clock():
    """The schedule's clock: now, or the selftests' fake clock (FLEET_NODE_CLOCK, a
    file holding an epoch) — retries and timeouts keep the real one."""
    f = os.environ.get("FLEET_NODE_CLOCK")
    if f and env("FLEET_NODE_TEST", "") == "1":
        try:
            with open(f) as fh:
                return float(fh.read().split()[0])
        except (IOError, OSError, ValueError, IndexError):
            pass
    return now()


def task_tz(sched):
    """The schedule's zone: None = this machine's local time, False = unknown."""
    name = (sched or {}).get("tz")
    if not name:
        return None
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:
        return False


def _cron_field(s, lo, hi):
    out = set()
    for part in s.split(","):
        step = 1
        if "/" in part:
            part, st = part.split("/", 1)
            step = int(st)
            if step < 1:
                raise ValueError(st)
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
        else:
            a = b = int(part)
            if step > 1:
                b = hi
        if a < lo or b > hi or a > b:
            raise ValueError(part)
        out.update(range(a, b + 1, step))
    return out


def task_cron(sched):
    """(minutes, hours, days, months, weekdays, dom is *, dow is *) of a schedule;
    ValueError when it is neither a valid `at` nor a valid five-field `cron`."""
    sched = sched or {}
    if sched.get("at") is not None:
        m = HHMM_RE.match(str(sched["at"]))
        if not m or sched.get("cron"):
            raise ValueError("at %r is not HH:MM" % sched.get("at"))
        expr = "%d %d * * *" % (int(m.group(2)), int(m.group(1)))
    else:
        expr = str(sched.get("cron") or "")
    f = expr.split()
    if len(f) != 5:
        raise ValueError("cron %r is not five fields" % expr)
    dow = set(d % 7 for d in _cron_field(f[4], 0, 7))
    return (_cron_field(f[0], 0, 59), _cron_field(f[1], 0, 23), _cron_field(f[2], 1, 31),
            _cron_field(f[3], 1, 12), dow, f[2] == "*", f[4] == "*")


def task_slot(sched, t, direction):
    """(epoch, 'YYYY-MM-DD') of the schedule's next slot after t (direction 1) or
    its latest at or before t (-1), in the schedule's zone; (None, None) if none
    within 400 days."""
    mins, hours, dom, mon, dow, dom_any, dow_any = task_cron(sched)
    tz = task_tz(sched) or None
    day = datetime.datetime.fromtimestamp(t, tz).date()
    times = sorted((h, m) for h in hours for m in mins)
    if direction < 0:
        times.reverse()
    for i in range(400):
        d = day + datetime.timedelta(days=i * direction)
        if d.month not in mon:
            continue
        dm, dw = d.day in dom, (d.isoweekday() % 7) in dow
        if not ((dm and dw) if (dom_any or dow_any) else (dm or dw)):
            continue
        for h, m in times:
            ts = datetime.datetime(d.year, d.month, d.day, h, m, tzinfo=tz).timestamp()
            if (direction > 0 and ts > t) or (direction < 0 and ts <= t):
                return ts, d.isoformat()
    return None, None


def task_when(sched):
    """The schedule in words: `daily 07:00 Asia/Shanghai` / `cron 0 7 * * 1-5 local`."""
    sched = sched or {}
    what = "daily %s" % sched["at"] if sched.get("at") else "cron %s" % sched.get("cron")
    return "%s %s" % (what, sched.get("tz") or "local")


def task_time(t, sched):
    """An epoch as the schedule's wall clock, `2026-10-09 07:00`."""
    if not t:
        return "-"
    tz = task_tz(sched) or None
    return datetime.datetime.fromtimestamp(t, tz).strftime("%Y-%m-%d %H:%M")


def task_check(svc):
    """Why a `kind: task` entry is not a valid one, or None."""
    if not isinstance(svc.get("prompt"), str) or not svc["prompt"].strip():
        return "a task needs a prompt"
    sched = svc.get("schedule")
    if not isinstance(sched, dict):
        return "a task needs a schedule ({at: HH:MM} or {cron: …})"
    if task_tz(sched) is False:
        return "unknown tz %r" % sched.get("tz")
    try:
        task_cron(sched)
    except ValueError as e:
        return "schedule: %s" % e
    for f, lo, hi in (("retries", 0, TASK_RETRIES_MAX), ("retry_delay", 0, 86400), ("timeout", 60, 86400),
                      ("idle", 30, 86400)):
        v = svc.get(f)
        if v is not None and (not isinstance(v, int) or isinstance(v, bool) or not lo <= v <= hi):
            return "%s must be a whole number %d..%d" % (f, lo, hi)
    win = svc.get("window")
    if win is not None and not SVC_NAME_RE.match(str(win).replace("{date}", "2026-01-01")):
        return "window %r (a-z 0-9 . _ -, {date})" % win
    dw = svc.get("done_when") or {}
    if not isinstance(dw, dict) or (dw.get("file") is not None
                                    and not str(dw["file"]).startswith(("/", "~/"))):
        return "done_when.file must be an absolute or ~/ path"
    fl = svc.get("fleet")
    if fl is not None and not SVC_NAME_RE.match(str(fl)):
        return "fleet %r" % fl
    bark = (svc.get("notify") or {}).get("bark")
    if bark is not None and not ENV_KEY_RE.match(str(bark)):
        return "notify.bark %r is not a credential name" % bark
    return None


def task_fill(s, day):
    return (s or "").replace("{date}", day)


def task_entry(paths, svc, ident, day, attempt, manual=None):
    """One attempt of a task as a process of the daemon (service_entry's shape): the
    runner, demoted to the login, its output appended to the task's log. A `run
    --now` (manual: its HHMM) gets a window of its own, never the slot's."""
    uid, gid, home = ident
    login, name = svc["login"], svc["name"]
    win = (task_fill(svc.get("window") or name + "-{date}", day) + ("-now%s" % manual if manual else "")
           + ("-%d" % attempt if attempt > 1 else ""))
    done = task_fill((svc.get("done_when") or {}).get("file"), day)
    if done.startswith("~/"):
        done = os.path.join(home, done[2:])
    e = {"PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
    e.update((k, v) for k, v in (svc.get("env") or {}).items() if k not in SVC_ENV_DROP)
    e.update(HOME=home, USER=login, LOGNAME=login, FLEET_SERVICE=name,
             FLEET_CONF_DIR=os.path.join(home, ".config", "claude-fleet"),
             FLEET_TASK_PROMPT=task_fill(svc["prompt"], day), FLEET_TASK_WINDOW=win, FLEET_TASK_DONE_FILE=done,
             FLEET_TASK_TIMEOUT=str(svc.get("timeout") or 3600), FLEET_TASK_IDLE=str(svc.get("idle") or 600),
             FLEET_TASK_FLEET=svc.get("fleet") or "", FLEET_TASK_ATTEMPT=str(attempt), FLEET_TASK_SLOT=day)
    lg = service_log(paths, login, name)
    runner = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet-task-run.sh")
    return {"name": "task:%s/%s" % (login, name), "account": login, "service": name, "window": win,
            "uid": uid, "gid": gid, "home": home, "env": e, "creds": list(svc.get("creds") or []),
            "script": runner, "logdir": os.path.dirname(lg),
            "cmd": ["/bin/sh", "-c", ACCOUNT_SH, "fleet-task", lg, lg, "/bin/bash", runner]}


def task_alert_path(paths, login, name):
    return os.path.join(paths.logins, login, "alerts", name + ".json")


def task_runs_path(paths, login, name):
    return os.path.join(paths.logins, login, "runs", name + ".json")


def task_summary(paths, svc, ts):
    """A task's half of its services[] row: its schedule and how its runs went —
    status scheduled | running | retrying | ok | failed | stopped | no such login."""
    sched = svc.get("schedule") or {}
    nxt = None
    if svc.get("state", "enabled") == "enabled":
        try:
            nxt = task_slot(sched, task_clock(), 1)[0]
        except ValueError:
            pass
    if svc.get("state", "enabled") == "stopped":
        st = "stopped"
    elif account_ident(svc["login"]) is None:
        st = "no such login"
    else:
        st = ts.get("state") or "scheduled"
        if st == "interrupted":
            st = "running"
    return {"status": st, "schedule": sched, "when": task_when(sched), "prompt": svc["prompt"][:SVC_LINE_MAX],
            "window": svc.get("window") or svc["name"] + "-{date}", "retries": svc.get("retries", 2),
            "done_when": svc.get("done_when"), "notify": svc.get("notify"),
            "last_run": ts.get("last_run"), "last_end": ts.get("last_end"), "last_result": ts.get("last_result"),
            "last_rc": ts.get("last_rc"), "last_error": ts.get("last_error"), "slot": ts.get("slot"),
            "attempt": ts.get("attempt"), "last_window": ts.get("window"), "next_try": ts.get("next_try"),
            "next_run": nxt, "alert": ts.get("alert")}


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
        self.agent_running = {}  # "login/name" -> (Popen, t0, entry) of an agent task's attempt (#2529)
        self.notifies = []
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

    def service_entries(self):
        """The login-level register (#2525): every valid, enabled entry of a login
        this machine has, as a child."""
        out = []
        for login, name, path, svc, why in service_files(self.p):
            if svc is None or svc.get("state", "enabled") != "enabled" or svc.get("kind") == "task":
                continue
            ident = account_ident(login)
            if ident is not None:
                out.append(service_entry(self.p, svc, path, ident))
        return out

    def all_children(self):
        return (list(self.table["children"]) + [e for e in self.account_entries() if e.get("keepalive")]
                + self.service_entries())

    def all_tasks(self):
        return list(self.table["tasks"]) + [e for e in self.account_entries() if not e.get("keepalive")]

    def spawn(self, ent, fh, extra_env=None):
        """Popen one child / task: a machine one as root in the daemon's own env, an
        account one demoted to its login, its output opened by itself (ACCOUNT_SH)."""
        if ent.get("account"):
            e = ent["env"]
            if ent.get("service"):
                service_logdir(ent)
                e = dict(e, **service_creds(self.p, ent)[0])
            return subprocess.Popen(ent["cmd"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=fh, env=e, start_new_session=True, close_fds=True,
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
        try:
            self.state["services"] = services_summary(self.p, self.state)
        except Exception as e:  # the register must never take the heartbeat down
            self.log("services summary failed: %s" % e)
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
            why = account_runnable(c)
            if not why and c.get("creds"):
                missing = service_creds(self.p, c)[1]
                why = "missing credential %s" % ", ".join(missing) if missing else None
            return why or "supervised"
        if not c.get("cmd"):
            return "pending"
        if requires_missing(c):
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
        # a service removed from the register leaves no row behind (#2525)
        files = set("svc:%s/%s" % (f[0], f[1]) for f in service_files(self.p))
        for name in [n for n in self.state["children"] if n.startswith("svc:") and n not in files]:
            del self.state["children"][name]
            self.dirty = True
        for c in kids:
            name = c["name"]
            cs = self.state["children"].setdefault(name, {})
            st = self.child_status(c)
            if cs.get("status") != st:
                cs["status"] = st
                self.dirty = True
            if st != "supervised":
                # the last login released (#2421): a running one has nothing to serve
                if st == "waiting" and (name in self.procs or name in self.adopted):
                    self.stop_one(name, "%s missing — waiting" % ", ".join(requires_missing(c)))
                    cs["status"] = st
                if st == "waiting" and (cs.get("fails") or cs.get("next_start")):
                    # no backoff carried over: the first start once it is met is at once
                    cs.update(fails=0, next_start=None)
                    self.dirty = True
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

    # -- agent tasks (#2529): a slot due → one attempt → retries → ok | failed + alert
    def tend_agent_tasks(self):
        t, clk = now(), task_clock()
        rows = self.state.setdefault("agent_tasks", {})
        seen = set()
        for login, name, path, svc, why in service_files(self.p):
            if svc is None or svc.get("kind") != "task":
                continue
            key = "%s/%s" % (login, name)
            seen.add(key)
            ts = rows.setdefault(key, {})
            if key in self.agent_running:
                self.reap_agent(key, ts, svc, t)
                if key in self.agent_running:
                    continue
            req = os.path.join(self.p.logins, login, "run", name)
            want = os.path.exists(req)
            if want:
                try:
                    os.remove(req)
                except OSError:
                    pass
            ident = account_ident(login)
            if svc.get("state", "enabled") != "enabled" or ident is None:
                if want:
                    self.log("task %s: run --now ignored — %s" % (key, "stopped" if ident else "no such login"))
                continue
            try:
                prev, day = task_slot(svc["schedule"], clk, -1)
            except ValueError:
                continue
            catchup = env_num("FLEET_NODE_TASK_CATCHUP", 6 * 3600)
            if want:
                # run --now: a slot of its own, today's date in the task's zone
                at = datetime.datetime.fromtimestamp(clk, task_tz(svc["schedule"]) or None)
                self.new_slot(ts, clk, at.date().isoformat(), at.strftime("%H%M"))
            elif prev and prev > (ts.get("slot_t") or 0) \
                    and prev >= max(svc.get("added") or 0, svc.get("rescheduled") or 0) \
                    and clk - prev <= catchup:
                self.new_slot(ts, prev, day, False)
            elif ts.get("state") == "interrupted":
                pass                                  # the same attempt again: the runner adopts its window
            elif ts.get("state") == "retrying" and t >= (ts.get("next_try") or 0):
                ts["attempt"] = (ts.get("attempt") or 1) + 1
            else:
                continue
            self.start_agent(key, ts, svc, ident, t)
        for key in [k for k in rows if k not in seen]:
            # an entry removed from the register: its attempt stops, its row goes
            run = self.agent_running.pop(key, None)
            if run:
                self.kill_agent(run[0])
            del rows[key]
            self.dirty = True

    def new_slot(self, ts, slot_t, day, manual):
        ts.update(slot_t=slot_t, slot=day, attempt=1, manual=manual, next_try=None)
        self.dirty = True

    def start_agent(self, key, ts, svc, ident, t):
        ent = task_entry(self.p, svc, ident, ts["slot"], ts["attempt"], ts.get("manual") or None)
        why = account_runnable(ent)
        if not why and ent["creds"]:
            missing = service_creds(self.p, ent)[1]
            why = "missing credential %s" % ", ".join(missing) if missing else None
        ts.update(last_run=task_clock(), window=ent["window"], pid=None)
        if why:
            self.end_agent(key, ts, svc, None, t, why)
            return
        try:
            fh = self.logfile(ent["account"], "accounts")
            p = self.spawn(ent, fh)
            fh.close()
        except (OSError, subprocess.SubprocessError) as e:
            self.end_agent(key, ts, svc, None, t, "spawn: %s" % e)
            return
        self.agent_running[key] = (p, t, svc)
        ts.update(state="running", pid=p.pid)
        self.dirty = True
        self.log("task %s: slot %s attempt %d started pid %d (window %s)"
                 % (key, ts["slot"], ts["attempt"], p.pid, ent["window"]))

    def kill_agent(self, p):
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            p.wait(timeout=5)
        except Exception:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass

    def reap_agent(self, key, ts, svc, t, wait=False):
        p, t0, _ = self.agent_running[key]
        rc = p.poll()
        why = None
        if rc is None and t - t0 > (svc.get("timeout") or 3600) + 300:
            # the runner keeps its own deadline; this one is for a runner that hangs
            self.kill_agent(p)
            rc, why = p.poll(), "killed after %ds" % int(t - t0)
        elif rc is None:
            if not wait:
                return
            self.kill_agent(p)
            del self.agent_running[key]
            ts.update(state="interrupted", pid=None)
            self.dirty = True
            return
        del self.agent_running[key]
        self.end_agent(key, ts, svc, rc, t, why)

    def end_agent(self, key, ts, svc, rc, t, why=None):
        login, name = key.split("/", 1)
        if rc != 0 and not why:
            why = TASK_RC.get(rc, "exit %s" % rc)
        rec = {"slot": ts.get("slot"), "attempt": ts.get("attempt"), "manual": ts.get("manual"),
               "start": ts.get("last_run"), "end": t, "rc": rc, "window": ts.get("window"), "why": why}
        rp = task_runs_path(self.p, login, name)
        runs = (read_json(rp, {}) or {}).get("runs") or []
        try:
            _svc_mkdir(os.path.dirname(rp))
            write_json(rp, {"runs": (runs + [rec])[-TASK_RUNS_KEEP:]}, 0o600)
        except OSError as e:
            self.log("task %s: runs record: %s" % (key, e))
        ts.update(last_end=t, last_rc=rc, pid=None)
        ap = task_alert_path(self.p, login, name)
        retries = svc.get("retries", 2)
        if rc == 0:
            ts.update(state="ok", last_result="ok", last_error=None, next_try=None, alert=None)
            if os.path.exists(ap):
                os.remove(ap)
        elif (ts.get("attempt") or 1) <= retries:
            ts.update(state="retrying", last_result="failed", last_error=why,
                      next_try=t + (svc.get("retry_delay") if svc.get("retry_delay") is not None else 300))
        else:
            ts.update(state="failed", last_result="failed", last_error=why, next_try=None, alert=ap)
            alert = {"name": name, "login": login, "kind": "task", "slot": ts.get("slot"),
                     "attempts": ts.get("attempt"), "why": why, "at": t, "window": ts.get("window"),
                     "log": service_log(self.p, login, name), "runs": rp}
            try:
                _svc_mkdir(os.path.dirname(ap))
                write_json(ap, alert, 0o600)
            except OSError as e:
                self.log("task %s: alert: %s" % (key, e))
            self.notify_agent(svc, alert)
        self.dirty = True
        self.log("task %s: slot %s attempt %s %s" % (key, ts.get("slot"), ts.get("attempt"),
                                                    "ok" if rc == 0 else "failed — %s → %s" % (why, ts["state"])))

    def notify_agent(self, svc, alert):
        """The entry's Bark push (decision 2: optional, the hub's alert is the default):
        the runner's --notify, demoted, the key injected from the login's creds."""
        bark = (svc.get("notify") or {}).get("bark")
        ident = account_ident(svc["login"])
        if not bark or ident is None:
            return
        ent = task_entry(self.p, svc, ident, alert.get("slot") or "", 1)
        ent["creds"] = [bark]
        ent["env"].update(FLEET_TASK_BARK_CRED=bark,
                          FLEET_TASK_NOTIFY="%s 失败 %s 次：%s" % (svc["name"], alert["attempts"], alert["why"]))
        ent["cmd"] = ent["cmd"] + ["--notify"]
        try:
            fh = self.logfile(ent["account"], "accounts")
            self.notifies.append(self.spawn(ent, fh))
            fh.close()
        except (OSError, subprocess.SubprocessError) as e:
            self.log("task %s/%s: bark: %s" % (svc["login"], svc["name"], e))
        self.notifies = [p for p in self.notifies if p.poll() is None]

    # -- lanes (issue #2501)
    def tend_lanes(self):
        """The logins whose lane the hub refuses, from each tenant's lane.json
        (root's to read) into state.json (anyone's): status and the doctor."""
        cur = lane_refusals(self.p)
        if cur != (self.state.get("lanes") or {}):
            for login in sorted(set(cur) - set(self.state.get("lanes") or {})):
                self.log("login %s: the hub refuses its lane — %s (fix: account adopt %s --rejoin)"
                         % (login, cur[login]["why"], login))
            self.state["lanes"] = cur
            self.dirty = True

    # -- sweep
    def sweep_due(self, t):
        return t - (self.state["sweep"].get("last") or 0) >= env_num("FLEET_NODE_SWEEP_EVERY", 3600)

    def do_sweep(self, dry=False):
        res = sweep(self.p, dry=dry)
        if not dry:
            sw = self.state["sweep"]
            sw.update(last=now(), moved=len(res["moved"]), extra=len(res["extra"]), handwritten=res["handwritten"],
                      clientshell=res["clientshell"],
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
        for ts in (self.state.get("agent_tasks") or {}).values():
            if ts.get("state") == "running":
                ts.update(state="interrupted", pid=None)
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
            try:
                self.tend_agent_tasks()
            except Exception as e:  # one bad entry must never take the daemon down
                self.log("agent tasks: %s" % e)
            self.tend_lanes()
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
        for key in list(self.agent_running):
            self.reap_agent(key, self.state["agent_tasks"][key], self.agent_running[key][2], now(), wait=True)
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


def _handwritten(paths, d, n, src):
    """A hand-written plist that runs as a login (issue #2530, EPIC #2524 C6):
    {label, login, path}, else None. In LaunchDaemons: a `UserName` that is a
    person's (not root, not a `_` system account). In a login's LaunchAgents:
    a program under that login's home, outside ~/Library (an app's own agent).
    Report only — the way out is `fleet service|task add`, then archive it."""
    if not n.endswith(".plist") or FLEET_PLIST_RE.match(n):
        return None
    try:
        with open(src, "rb") as f:
            pl = plistlib.load(f)
    except Exception:
        return None
    if not isinstance(pl, dict):
        return None
    label = pl.get("Label") or n[:-len(".plist")]
    if label == LABEL:
        return None
    if d == paths.daemon_dir:
        login = pl.get("UserName") or ""
        if not isinstance(login, str) or not login or login == "root" or login.startswith("_"):
            return None
        return {"label": label, "login": login, "path": src}
    login = os.path.basename(os.path.dirname(os.path.dirname(d)))
    home = os.path.join(paths.users, login) + "/"
    args = [pl.get("Program")] + list(pl.get("ProgramArguments") or [])
    for a in args:
        if isinstance(a, str) and home in a and (home + "Library/") not in a:
            return {"label": label, "login": login, "path": src}
    return None


def taken_over(paths):
    """The logins this daemon has taken over — the ones registered in
    logins/<login>.env — and ONLY those (issue #2702): the sweep names no one
    else. An admin, a local user who never used the fleet: their own launchd jobs
    and dotfiles are not the fleet's, and their being on the machine is normal."""
    out = set()
    try:
        for n in os.listdir(paths.logins):
            if n.endswith(".env") and re.match(r"^[A-Za-z0-9._-]+$", n[:-4]):
                out.add(n[:-4])
    except OSError:
        pass
    return out


SHELL_HOOK_RE = re.compile(r"shell/fleet-login\.zsh|shell/cw\.zsh")


def _shell_hook(line):
    """A ~/.zshrc line that hooks the fleet into a login shell — the old first-login
    block's opening line, or a live line sourcing fleet-login.zsh / cw.zsh (a
    comment is not one). The same rule bin/fleet-node-shell-retire.sh takes out."""
    s = line.strip()
    return s.startswith("# >>> claude-fleet") or (not s.startswith("#") and bool(SHELL_HOOK_RE.search(s)))


def client_shell(paths, logins=None):
    """[{login, cache, zshrc}] — every taken-over login whose home still carries
    the person's client (issue #2702): `cache` = ~/.cache/claude-fleet/shell is
    there, `zshrc` = how many ~/.zshrc lines hook the fleet into a login shell
    (the PATH line is not one). Read only; a home this process cannot read is
    skipped, never guessed."""
    out = []
    for login in sorted(taken_over(paths) if logins is None else logins):
        home = os.path.join(paths.users, login)
        cache = os.path.isdir(os.path.join(home, ".cache", "claude-fleet", "shell"))
        hooks = 0
        try:
            with open(os.path.join(home, ".zshrc"), errors="replace") as f:
                hooks = sum(1 for ln in f if _shell_hook(ln))
        except OSError:
            pass
        if cache or hooks:
            out.append({"login": login, "cache": cache, "zshrc": hooks})
    return out


def client_shell_says(c, paths):
    """One status / doctor phrase for a client_shell entry."""
    what = []
    if c.get("cache"):
        what.append("~/.cache/claude-fleet/shell")
    if c.get("zshrc"):
        what.append("~/.zshrc %d hook line(s)" % c["zshrc"])
    return "%s: %s — a managed machine is no one's client; sudo bash '%s' --login %s" % (
        c["login"], " · ".join(what), os.path.join(paths.runtime, "bin", "fleet-node-shell-retire.sh"), c["login"])


def _sweep(paths, dry=False):
    moved, extra, hand = [], [], []
    listed = taken_over(paths)
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
            else:
                h = _handwritten(paths, d, n, src)
                if h and h["login"] in listed:
                    hand.append(h)
    purged = 0 if dry else attic_purge(paths, index)
    if not dry and (moved or purged):
        write_json(paths.attic_index, index, 0o600)
    return {"moved": moved, "extra": extra, "purged": purged, "handwritten": hand,
            "clientshell": client_shell(paths, listed)}


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


def _env_file(path, uid, also=()):
    """KEY=VALUE lines of a node.env, PARSED (never sourced). Root reads a file in a
    login's home: never through a symlink, only one that login (or root) owns —
    or an owner in <also> (the credsep store's role account, issue #2336)."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return None
    with os.fdopen(fd) as f:
        st = os.fstat(f.fileno())
        if st.st_uid not in (uid, 0) + tuple(also) and (env("FLEET_NODE_TEST", "") != "1"
                                                         or env("FLEET_NODE_OWNER_CHECK", "") == "1"):
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


def _role_uids():
    try:
        return (pwd.getpwnam(env("FLEET_CREDSEP_ROLE", "_fleetcred")).pw_uid,)
    except KeyError:
        return ()


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
            # the store is the role account's (fleet-credsep.py: _fleetcred 0700),
            # under a root-owned base — m4 (issue #2336) had every token there
            ne = _env_file(ne_path, 0, _role_uids())
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


def lane_refusals(paths):
    """login → {why, since}: every tenant of the node program whose hello the hub
    refused with WRONG_LOGIN (issue #2501) — <state>/agent/<login>/lane.json, which
    the tenant writes on the refusal and removes on the next welcome."""
    base = os.path.join(paths.state, "agent")
    out = {}
    try:
        logins = sorted(os.listdir(base))
    except OSError:
        return out
    for login in logins:
        st = read_json(os.path.join(base, login, "lane.json"), None)
        if isinstance(st, dict) and st.get("state") == "refused":
            out[login] = {"why": str(st.get("why") or "")[:400], "since": str(st.get("since") or "")}
    return out


def _login_py(paths):
    return env("FLEET_NODE_LOGIN_PY", os.path.join(paths.runtime, "bin", "fleet-login.py"))


def account_rejoin(paths, login, ident, dry=False):
    """A fresh node token for login, asked by its own device key (issue #2501):
    `fleet-login.py node-pass` demoted to the login, the pass's token written into
    the credential store (a separated login) and logins/<login>.env (a managed one).
    The token travels by file and stdin only, never argv. → 0 · 1."""
    uid, gid, home = ident
    say = lambda m: print("fleet-node-supervisor: rejoin %s: %s" % (login, m), file=sys.stderr)  # noqa: E731
    lenv = _env_file(login_env_path(paths, login), 0) or {}
    cbase = env("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred")
    meta = read_json(os.path.join(cbase, login, "meta.json"), None)
    separated = isinstance(meta, dict) and meta.get("login") == login
    store_env = _env_file(os.path.join(cbase, login, "node.env"), 0, _role_uids()) if separated else None
    hub = (lenv.get("CCQUOTA_HUB_URL") or (store_env or {}).get("CCQUOTA_HUB_URL")
           or (_env_file(os.path.join(paths.state, "machine.env"), 0) or {}).get("CCQUOTA_HUB_URL") or "").rstrip("/")
    if not hub:
        say("no hub URL (logins/%s.env, the credential store and machine.env name none)" % login)
        return 1
    if not lenv and not separated:
        say("%s is neither managed (no logins/%s.env) nor separated — its token is its own file: "
            "as %s run `fleet node join --hub %s`" % (login, login, login, hub))
        return 1
    lpy = _login_py(paths)
    if not os.path.isfile(lpy):
        say("%s is not here" % lpy)
        return 1
    if dry:
        print("would ask %s for a new node token for %s (its device key, as %s) and write it to %s"
              % (hub, login, login, " + ".join(([os.path.join(cbase, login, "node.env")] if separated else [])
                                               + ([login_env_path(paths, login)] if lenv else []))))
        return 0
    work = tempfile.mkdtemp(prefix="fleet-rejoin-")
    try:
        os.chmod(work, 0o700)
        if os.geteuid() == 0:
            os.chown(work, uid, gid)
        out = os.path.join(work, "pass.json")
        cenv = {"HOME": home, "USER": login, "LOGNAME": login, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        if lenv.get("FLEET_CONF_DIR"):
            cenv["FLEET_CONF_DIR"] = lenv["FLEET_CONF_DIR"]
        try:
            r = subprocess.run([sys.executable, "-I", lpy, "node-pass", "--hub", hub, "--out", out],
                               env=cenv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               preexec_fn=demote(login, uid, gid, home), timeout=120)
        except (OSError, subprocess.SubprocessError) as e:
            say("node-pass did not run: %s" % e)
            return 1
        if r.returncode != 0:
            tail = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
            say("the hub gave no node pass (exit %d): %s" % (r.returncode, tail[-1] if tail else "-"))
            if r.returncode == 3:
                say("its device key is not registered — as %s run `fleet login` once, then rejoin again" % login)
            return 1
        res = read_json(out, None)
        tok = res.get("token") if isinstance(res, dict) else None
        if not tok or not re.match(r"^[A-Za-z0-9._~+/=-]+$", tok):
            say("the node pass carried no usable token")
            return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    wrote = []
    if separated:
        cpy = os.path.join(os.path.dirname(lpy), "fleet-credsep.py")
        conf = lenv.get("FLEET_CONF_DIR") or os.path.join(home, ".config", "claude-fleet")
        r = subprocess.run([sys.executable, "-I", cpy, "setenv", "--login", login, "--conf-dir", conf],
                           input=("CCQUOTA_TOKEN=%s\n" % tok).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode != 0:
            tail = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
            say("the new token is not in the credential store (credsep setenv exit %d: %s) — "
                "the hub's grace on the old one is 10 minutes" % (r.returncode, tail[-1] if tail else "-"))
            return 1
        wrote.append(os.path.join(cbase, login, "node.env"))
    if lenv:
        kv = dict(lenv, CCQUOTA_TOKEN=tok)
        try:
            write_login_env(paths, login, kv)
        except OSError as ex:
            say("cannot write %s (%s)" % (login_env_path(paths, login), ex.strerror or ex))
            return 1
        wrote.append(login_env_path(paths, login))
    print("rejoined %s with %s: a new node token in %s; the node program reloads logins/ and says %s's hello with it"
          % (login, hub, " + ".join(wrote), login))
    return 0


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


def account_adopt(paths, login, dry=False, rejoin=False):
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
    if rejoin:
        # a new token first (issue #2501): a managed login is done with it, an
        # unmanaged separated one is then adopted reading the store it renewed
        rc = account_rejoin(paths, login, ident, dry=dry)
        if rc or was is not None:
            return rc
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
    adopt_follow(paths, login)
    return 0


def adopt_follow(paths, login):
    """Taken over = its install taken over too (issue #2714): the release's updater
    links the login's tools and runs the release's install-sync for it NOW, in the
    background (an apply + doctor takes minutes), not on the next update tick. A
    machine with no release yet has nothing to follow."""
    upd = os.path.join(paths.runtime, "bin", "fleet-node-update.py")
    if env("FLEET_NODE_ADOPT_FOLLOW", "1") == "0" or not os.path.exists(upd):
        return
    try:
        subprocess.Popen(["/usr/bin/python3", "-I", upd, "follow", login], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
                         close_fds=True)
    except OSError as e:
        print("  its install follows the release on the next update tick (%s)" % e)
        return
    print("  its ~/.claude/fleet follows the release %s now (log: %s)"
          % ((runtime_sha(paths) or "?")[:12], os.path.join(paths.log, "update.log")))


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


def account_release(paths, login, force=False):
    """The way back, one command: stop running as <login>, put its services back."""
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: account release loads %s's services back — run it as root (sudo)" % login,
              file=sys.stderr)
        return 1
    # a login on its way out keeps nothing in the register (#2528): move each
    # entry to the login that takes over, or rm it; --force releases anyway
    # (the daemon keeps running them as <login>)
    if not force and service_refuse_left(paths, login, "account release %s" % login):
        return SVC_LEFT_RC
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


def lanes_now(paths, state):
    """The refused lanes: read fresh where this reader may (root), else the
    daemon's last copy in state.json."""
    return lane_refusals(paths) or state.get("lanes") or {}


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
            what = "waiting — %s missing" % ", ".join(requires_missing(c))
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
                # mid-run, a task still carries its last run's rc: name that outcome, not "running"
                res = "failed" if x.get("result") == "running" and not u.get("keepalive") else x.get("result")
                bad.append("%s %s" % (u["name"], res or x.get("status") or "never"))
        out.append("account %-17s %d/%d ok · last run %s%s"
                   % (login, ok, len(units), iso(last), (" · " + ", ".join(bad)) if bad else ""))
    for r in services_summary(paths, state):
        if r["status"] == "invalid":
            out.append("service %-17s INVALID — %s (%s)" % ("%s/%s" % (r["login"], r["name"]), r["why"], r["file"]))
            continue
        if r["kind"] == "task":
            out.append("task    %-17s %s · %s · last %s %s · next %s%s"
                       % ("%s/%s" % (r["login"], r["name"]), r["status"], r["when"],
                          task_time(r.get("last_run"), r["schedule"]), r.get("last_result") or "-",
                          task_time(r.get("next_run"), r["schedule"]),
                          (" · %s" % r["last_error"]) if r["status"] in ("failed", "retrying") else ""))
            continue
        if r["status"] == "running":
            what = "running pid %s · up %s" % (r["pid"], ago(r.get("started")))
        elif r["status"] == "down":
            what = "down · restart at %s" % iso(r.get("next_start"))
        else:
            what = r["status"]
        out.append("service %-17s %s · restarts %s · last exit %s rc=%s · log %s"
                   % ("%s/%s" % (r["login"], r["name"]), what, r["restarts"], iso(r.get("last_exit")),
                      r.get("last_rc"), r["log"]))
    for login, ln in sorted(lanes_now(paths, state).items()):
        out.append("lane   %-18s 令牌失效 · 需要 relogin since %s — the hub: %s — fix: "
                   "sudo fleet-node-supervisor.py account adopt %s --rejoin" % (login, ln.get("since") or "-",
                                                                                ln.get("why") or "-", login))
    sw = state.get("sweep") or {}
    for h in sw.get("handwritten") or []:
        out.append("handwritten %-12s runs as %s, not in the register — fleet service|task add, then "
                   "archive %s" % (h.get("label"), h.get("login"), h.get("path")))
    for c in sw.get("clientshell") or []:
        out.append("clientshell %-12s %s" % (c.get("login"), client_shell_says(c, paths)))
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


def register_rows(paths, state):
    """services[] for `service ls`: computed from the register when this process may
    read it (root), else the copy the daemon keeps in state.json (0644) — the
    register is root's 0700 — with the reader's own log's last line."""
    if os.access(paths.logins, os.R_OK | os.X_OK) and (os.geteuid() == 0 or env("FLEET_NODE_TEST", "") == "1"):
        return services_summary(paths, state, tail=True)
    rows = [dict(r) for r in state.get("services") or []]
    for r in rows:
        t = log_tail(r.get("log") or "")
        r["last_line"] = t[-1] if t else None
    return rows


def task_opts(opts, one):
    """The task fields of `service add --kind task`; ValueError on a bad one."""
    def num(flag):
        v = one(flag)
        if v is None:
            return None
        try:
            return int(v)
        except ValueError:
            raise ValueError("%s %r is not a whole number" % (flag, v))
    sched = {}
    if one("--at"):
        sched["at"] = one("--at")
    if one("--cron"):
        sched["cron"] = one("--cron")
    if one("--tz"):
        sched["tz"] = one("--tz")
    out = {"kind": "task", "exec": None, "prompt": one("--prompt") or "", "schedule": sched,
           "retries": 2 if num("--retries") is None else num("--retries"),
           "window": one("--window") or None}
    for flag, key in (("--retry-delay", "retry_delay"), ("--timeout", "timeout"), ("--idle", "idle")):
        if num(flag) is not None:
            out[key] = num(flag)
    if one("--done-file"):
        out["done_when"] = {"file": one("--done-file")}
    if one("--fleet"):
        out["fleet"] = one("--fleet")
    if one("--bark"):
        out["notify"] = {"bark": one("--bark")}
    return out


# --------------------------------------------------------------- service CLI ----
SERVICE_USAGE = ("usage: fleet-node-supervisor.py service add --login L --name N [--env K=V]… [--env-key K]… "
                 "[--cred C]… [--path P]… -- <exec> [args…]\n"
                 "       fleet-node-supervisor.py service add --kind task --login L --name N --prompt P "
                 "(--at HH:MM | --cron 'm h dom mon dow') [--tz Z] [--retries N] [--retry-delay S] [--window W] "
                 "[--done-file F] [--timeout S] [--idle S] [--fleet F] [--bark C] [--env K=V]… [--cred C]…\n"
                 "       fleet-node-supervisor.py service rm|stop|start|restart|run --login L --name N\n"
                 "       fleet-node-supervisor.py service schedule --login L --name N (--at HH:MM | --cron '…') [--tz Z]\n"
                 "       fleet-node-supervisor.py service move --login L --name N --to L2\n"
                 "       fleet-node-supervisor.py service cred set|rm --login L --name C   (the value on stdin)\n"
                 "       fleet-node-supervisor.py service ls [--login L] [--kind service|task] [--json]\n"
                 "       fleet-node-supervisor.py service logs --login L --name N [-n LINES]")


def _svc_args(rest):
    """(options {flag: [values]}, exec argv after `--`) — every option takes a value."""
    opts, ex = {}, []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            ex = rest[i + 1:]
            break
        if a in ("--json",):
            opts.setdefault(a, []).append("1")
            i += 1
            continue
        if not a.startswith("-") or i + 1 >= len(rest):
            raise ValueError("unexpected %r" % a)
        opts.setdefault(a, []).append(rest[i + 1])
        i += 2
    return opts, ex


def _svc_root(what):
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: service %s writes root's register — run it as root "
              "(bin/fleet-service.sh runs it through sudo -n)" % what, file=sys.stderr)
        return False
    return True


def _svc_mkdir(d):
    if not os.path.isdir(d):
        os.makedirs(d, 0o700)
    os.chmod(d, 0o700)


def _svc_ident(login):
    if not LOGIN_RE.match(login or ""):
        print("fleet-node-supervisor: bad login %r" % login, file=sys.stderr)
        return None
    ident = account_ident(login)
    if ident is None:
        print("fleet-node-supervisor: %s is no login of this machine (uid ≥ 500)" % login, file=sys.stderr)
    return ident


def service_cli(paths, rest):
    sub = rest[0] if rest else "ls"
    verb = rest[1] if sub == "cred" and len(rest) > 1 else None
    try:
        opts, ex = _svc_args(rest[2:] if verb else rest[1:])
    except ValueError as e:
        print("fleet-node-supervisor: %s\n%s" % (e, SERVICE_USAGE), file=sys.stderr)
        return 2
    one = lambda k: (opts.get(k) or [None])[-1]
    login, name = one("--login"), one("--name")
    if sub == "ls":
        rows = register_rows(paths, read_json(paths.state_file, {}))
        if login:
            rows = [r for r in rows if r["login"] == login]
        if one("--kind"):
            rows = [r for r in rows if r.get("kind", "service") == one("--kind")]
        if "--json" in opts:
            print(json.dumps(rows, indent=1, sort_keys=True))
            return 0
        for r in rows:
            if r.get("kind") == "task":
                sc = r.get("schedule") or {}
                print("%-24s %-9s %s · 上次 %s %s · 下次 %s%s" % (
                    "%s/%s" % (r["login"], r["name"]), r["status"], r.get("when") or task_when(sc),
                    task_time(r.get("last_run"), sc), r.get("last_result") or "-", task_time(r.get("next_run"), sc),
                    ("  · %s" % r["last_error"]) if r.get("last_error") and r["status"] in ("failed", "retrying")
                    else ""))
                continue
            print("%-24s %-9s %s%s" % ("%s/%s" % (r["login"], r["name"]), r["status"],
                                       " ".join(r.get("exec") or []) or r.get("why", ""),
                                       ("  · %s" % r["last_line"]) if r.get("last_line") else ""))
        if not rows:
            print("(no %s registered%s)" % (one("--kind") or "service", " for %s" % login if login else ""))
        return 0
    if sub == "logs":
        if not (login and name and SVC_NAME_RE.match(name) and LOGIN_RE.match(login)):
            print(SERVICE_USAGE, file=sys.stderr)
            return 2
        lg = service_log(paths, login, name)
        if not os.path.exists(lg):
            print("fleet-node-supervisor: no log yet (%s)" % lg, file=sys.stderr)
            return 1
        for l in log_tail(lg, int(one("-n") or 50), 4096):
            print(l)
        return 0
    if sub == "cred":
        if verb not in ("set", "rm") or not login or not name or not ENV_KEY_RE.match(name):
            print(SERVICE_USAGE, file=sys.stderr)
            return 2
        if not _svc_root("cred") or _svc_ident(login) is None:
            return 1
        d = service_cred_dir(paths, login)
        _svc_mkdir(os.path.dirname(d))
        _svc_mkdir(d)
        f = os.path.join(d, name)
        if verb == "rm":
            try:
                os.remove(f)
            except OSError:
                pass
            print("removed credential %s of %s" % (name, login))
            return 0
        val = sys.stdin.read().rstrip("\n")
        if not val:
            print("fleet-node-supervisor: no value on stdin", file=sys.stderr)
            return 2
        tmp = os.path.join(d, ".%s.%d" % (name, os.getpid()))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(val + "\n")
        os.rename(tmp, f)
        print("stored credential %s of %s (the value is never printed or logged)" % (name, login))
        return 0
    if sub == "move":
        if not login or not name or not one("--to"):
            print(SERVICE_USAGE, file=sys.stderr)
            return 2
        return service_move(paths, login, name, one("--to"))
    if sub not in ("add", "rm", "stop", "start", "restart", "run", "schedule") or not login or not name:
        print(SERVICE_USAGE, file=sys.stderr)
        return 2
    if not SVC_NAME_RE.match(name):
        print("fleet-node-supervisor: bad name %r (a-z 0-9 . _ -, ≤ 48)" % name, file=sys.stderr)
        return 2
    if not _svc_root(sub) or _svc_ident(login) is None:
        return 1
    d = service_dir(paths, login)
    f = os.path.join(d, name + ".json")
    if sub == "rm":
        if not os.path.exists(f):
            print("fleet-node-supervisor: %s/%s is not registered" % (login, name), file=sys.stderr)
            return 1
        os.remove(f)
        print("removed %s/%s — the daemon stops it on its next pass" % (login, name))
        return 0
    if sub == "run":
        svc = read_json(f, None)
        if svc is None:
            print("fleet-node-supervisor: %s/%s is not registered" % (login, name), file=sys.stderr)
            return 1
        if svc.get("kind") != "task":
            print("fleet-node-supervisor: %s/%s is a service — run is a task's (restart starts a service again)"
                  % (login, name), file=sys.stderr)
            return 2
        if svc.get("state", "enabled") != "enabled":
            print("fleet-node-supervisor: %s/%s is stopped — start it first" % (login, name), file=sys.stderr)
            return 1
        rq = os.path.join(paths.logins, login, "run")
        _svc_mkdir(rq)
        write_json(os.path.join(rq, name), {"at": now()}, 0o600)
        print("%s/%s: one run now — the daemon starts it on its next pass (after a run in flight); "
              "fleet task ls shows it" % (login, name))
        return 0
    if sub == "schedule":
        # a task's new schedule (issue #2527): only the slot moves — a slot that
        # passed before the change is never caught up (`rescheduled`)
        svc = read_json(f, None)
        if svc is None:
            print("fleet-node-supervisor: %s/%s is not registered" % (login, name), file=sys.stderr)
            return 1
        if svc.get("kind") != "task":
            print("fleet-node-supervisor: %s/%s is a service — only a task has a schedule" % (login, name),
                  file=sys.stderr)
            return 2
        if not (one("--at") or one("--cron")):
            print(SERVICE_USAGE, file=sys.stderr)
            return 2
        sched = {"at": one("--at")} if one("--at") else {"cron": one("--cron")}
        tz = one("--tz") if "--tz" in opts else (svc.get("schedule") or {}).get("tz")
        if tz:
            sched["tz"] = tz
        if one("--at") and one("--cron"):
            sched["cron"] = one("--cron")      # task_check refuses both
        svc.update(schedule=sched, rescheduled=task_clock(), changed=now())
        why = service_check(svc, login, name)
        if why:
            print("fleet-node-supervisor: %s" % why, file=sys.stderr)
            return 2
        write_json(f, svc, 0o600)
        print("%s/%s: %s, next run %s" % (login, name, task_when(sched),
                                           task_time(task_slot(sched, task_clock(), 1)[0], sched)))
        return 0
    if sub in ("stop", "start", "restart"):
        svc = read_json(f, None)
        if svc is None:
            print("fleet-node-supervisor: %s/%s is not registered" % (login, name), file=sys.stderr)
            return 1
        svc["state"] = "stopped" if sub == "stop" else "enabled"
        svc["changed"] = now()     # a new entry file = the daemon starts it again
        write_json(f, svc, 0o600)
        print("%s/%s %s" % (login, name, {"stop": "stopped", "start": "enabled",
                                           "restart": "restarting"}[sub]))
        return 0
    kind = one("--kind") or "service"
    if kind not in SVC_KINDS:
        print("fleet-node-supervisor: --kind %s — service or task" % kind, file=sys.stderr)
        return 2
    if kind == "service" and not ex:
        print("fleet-node-supervisor: nothing to run — add … -- <exec> [args…]", file=sys.stderr)
        return 2
    if kind == "task" and ex:
        print("fleet-node-supervisor: a task runs a prompt, not a command — drop the `-- …`", file=sys.stderr)
        return 2
    envs = {}
    for kv in opts.get("--env") or []:
        k, sep, v = kv.partition("=")
        if not sep or not ENV_KEY_RE.match(k):
            print("fleet-node-supervisor: --env %r is not K=V" % kv, file=sys.stderr)
            return 2
        envs[k] = v
    keys = list(opts.get("--env-key") or [])
    old = read_json(f, {}) or {}
    svc = {"name": name, "login": login, "kind": "service", "exec": list(ex), "schedule": None,
           "retries": None, "env": envs, "env_keys": sorted(set(keys + list(envs))),
           "creds": list(opts.get("--cred") or []), "paths": list(opts.get("--path") or []),
           "state": "enabled", "added": old.get("added") or now(), "changed": now()}
    if kind == "task":
        try:
            svc.update(task_opts(opts, one))
        except ValueError as e:
            print("fleet-node-supervisor: %s" % e, file=sys.stderr)
            return 2
        # a slot is never older than the entry (the fake clock in the selftests)
        svc["added"] = old.get("added") if old.get("kind") == "task" else task_clock()
    why = service_check(svc, login, name)
    if why:
        print("fleet-node-supervisor: %s" % why, file=sys.stderr)
        return 2
    _svc_mkdir(os.path.dirname(d))
    _svc_mkdir(d)
    write_json(f, svc, 0o600)
    missing = [c for c in svc["creds"] if not os.path.exists(os.path.join(service_cred_dir(paths, login), c))]
    if kind == "task":
        print("%s task %s/%s — %s, next run %s, as %s; log %s"
              % ("updated" if old else "registered", login, name, task_when(svc["schedule"]),
                 task_time(task_slot(svc["schedule"], task_clock(), 1)[0], svc["schedule"]), login,
                 service_log(paths, login, name)))
    else:
        print("%s %s/%s — the daemon runs it as %s on its next pass; log %s"
              % ("updated" if old else "registered", login, name, login, service_log(paths, login, name)))
    if missing:
        print("note: credential %s not stored yet — it waits until `fleet service cred set` has it"
              % ", ".join(missing))
    return 0


# --------------------------------------------------------------- service move ---
# A login hands its register to another (issue #2528, EPIC #2524 C4): the
# 2026-10-08 verkyyi → verky move left the daily push under the old name, failing
# every half hour until it was carried over by hand. `service move` carries ONE
# entry whole: the daemon stops it first (no two copies ever run), every path the
# entry declares (`paths[]` — its working directory, its skill directory) moves
# from the old home to the same place in the new one and is chowned there, its
# log and the credentials it names move to the new login's, every string of
# exec / env that named the old home names the new one, and the entry is
# registered under the new login (its old state kept) — then the old one goes.
# Every check runs before the first change; a step that fails puts back what it
# moved. A path outside the old home is shared: left where it is, said so.
SVC_LEFT_RC = 6     # `account release` / fleet-login-remove.sh: entries not moved yet


def service_names(paths, login):
    """The names a login's register holds (valid or not)."""
    return sorted(os.path.basename(f)[:-len(".json")]
                  for f in glob.glob(os.path.join(service_dir(paths, login), "*.json")))


def service_refuse_left(paths, login, what):
    """Print the refusal + the commands that clear it; True when there is one."""
    left = service_names(paths, login)
    if not left:
        return False
    print("fleet-node-supervisor: refusing %s — %s still has %d registered service(s): %s"
          % (what, login, len(left), " ".join(left)), file=sys.stderr)
    print("  move each to the login that takes over (or rm it), then run this again:", file=sys.stderr)
    for n in left:
        print("    sudo %s -I %s service move --login %s --name %s --to <新登录>"
              % (sys.executable, os.path.abspath(__file__), login, n), file=sys.stderr)
    return True


def _rehome(s, old, new):
    if isinstance(s, str) and (s == old or s.startswith(old.rstrip("/") + "/")):
        return new.rstrip("/") + s[len(old.rstrip("/")):]
    return s


def _chown_tree(top, uid, gid):
    """lchown top and everything under it (never follows a link)."""
    if os.geteuid() != 0:
        return
    os.lchown(top, uid, gid)
    if os.path.isdir(top) and not os.path.islink(top):
        for d, dirs, files in os.walk(top):
            for n in dirs + files:
                os.lchown(os.path.join(d, n), uid, gid)


def _makedirs_as(d, stop, uid, gid):
    """mkdir -p d, each directory it creates below stop owned by uid:gid."""
    made = []
    x = d
    while not os.path.isdir(x) and x.rstrip("/") != stop.rstrip("/") and x != "/":
        made.append(x)
        x = os.path.dirname(x)
    for m in reversed(made):
        os.mkdir(m, 0o755)
        if os.geteuid() == 0:
            os.lchown(m, uid, gid)


def _move_tree(src, dst):
    """rename, or copy + remove across filesystems."""
    try:
        os.rename(src, dst)
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
        if os.path.isdir(src) and not os.path.islink(src):
            shutil.copytree(src, dst, symlinks=True)
            shutil.rmtree(src)
        else:
            shutil.copy2(src, dst, follow_symlinks=False)
            os.remove(src)


def _service_wait_stopped(paths, login, name):
    """True once the daemon no longer runs <login>/<name> (or none is running)."""
    key = "svc:%s/%s" % (login, name)
    st = read_json(paths.state_file, {})
    if not pid_alive((st.get("supervisor") or {}).get("pid")):
        return not pid_alive(((st.get("children") or {}).get(key) or {}).get("pid"))
    end = now() + env_num("FLEET_NODE_RELEASE_WAIT", 20)
    while True:
        cs = (read_json(paths.state_file, {}).get("children") or {}).get(key) or {}
        if not pid_alive(cs.get("pid")):
            return True
        if now() >= end:
            return False
        time.sleep(0.2)


def service_move(paths, login, name, to):
    if not SVC_NAME_RE.match(name):
        print("fleet-node-supervisor: bad name %r" % name, file=sys.stderr)
        return 2
    if not _svc_root("move"):
        return 1
    a, b = _svc_ident(login), _svc_ident(to)
    if a is None or b is None:
        return 1
    if login == to:
        print("fleet-node-supervisor: %s/%s is already %s's" % (login, name, to), file=sys.stderr)
        return 2
    f_old = os.path.join(service_dir(paths, login), name + ".json")
    f_new = os.path.join(service_dir(paths, to), name + ".json")
    svc = read_json(f_old, None) if os.path.exists(f_old) else None
    if svc is None:
        print("fleet-node-supervisor: %s/%s is not registered" % (login, name), file=sys.stderr)
        return 1
    why = service_check(svc, login, name)
    if why:
        print("fleet-node-supervisor: %s/%s is not a valid entry (%s) — fix or rm it" % (login, name, why),
              file=sys.stderr)
        return 1
    if os.path.exists(f_new):
        print("fleet-node-supervisor: %s already has a service %s — rm it there first" % (to, name), file=sys.stderr)
        return 1
    (_, _, oh), (uid, gid, nh) = a, b
    # -- every check before the first change
    moves, notes, problems = [], [], []
    for p in svc.get("paths") or []:
        q = _rehome(p, oh, nh)
        if not os.path.isabs(p) or q == p:
            notes.append("path %s is outside %s's home — left where it is" % (p, login))
        elif not os.path.lexists(p):
            notes.append("path %s does not exist — nothing to move" % p)
        elif os.path.lexists(q):
            problems.append("%s already exists in %s's home" % (q, to))
        else:
            moves.append((p, q))
    lg_old, lg_new = service_log(paths, login, name), service_log(paths, to, name)
    logs = [(x, y) for x, y in ((lg_old, lg_new), (lg_old + ".1", lg_new + ".1")) if os.path.lexists(x)]
    for x, y in logs:
        if os.path.lexists(y):
            problems.append("%s already exists" % y)
    cd_old, cd_new = service_cred_dir(paths, login), service_cred_dir(paths, to)
    creds = []
    for c in svc.get("creds") or []:
        src, dst = os.path.join(cd_old, c), os.path.join(cd_new, c)
        if not os.path.exists(src):
            notes.append("credential %s is not stored for %s — set it for %s (fleet service cred set %s)"
                         % (c, login, to, c))
            continue
        if os.path.exists(dst) and open(dst).read() != open(src).read():
            problems.append("%s already holds a different credential %s" % (to, c))
            continue
        creds.append((c, src, dst))
    if problems:
        for x in problems:
            print("fleet-node-supervisor: refusing move — %s" % x, file=sys.stderr)
        return 1
    # -- stop it under the old login: never two copies running
    old_state = svc.get("state", "enabled")
    if old_state != "stopped":
        write_json(f_old, dict(svc, state="stopped", changed=now()), 0o600)
        if not _service_wait_stopped(paths, login, name):
            write_json(f_old, svc, 0o600)
            print("fleet-node-supervisor: %s/%s did not stop — nothing moved" % (login, name), file=sys.stderr)
            return 1
    done = []          # (src, dst) moved, undone in reverse on a failure
    fresh = []         # credentials this move wrote, removed on a failure
    try:
        for p, q in moves:
            _makedirs_as(os.path.dirname(q), nh, uid, gid)
            _move_tree(p, q)
            done.append((p, q))
            _chown_tree(q, uid, gid)
        for p, q in logs:
            _svc_logdir_for(os.path.dirname(q), uid, gid)
            _move_tree(p, q)
            done.append((p, q))
            _chown_tree(q, uid, gid)
        if creds:
            _svc_mkdir(os.path.dirname(cd_new))
            _svc_mkdir(cd_new)
        for c, src, dst in creds:
            if os.path.exists(dst):
                continue        # the same value already there
            tmp = os.path.join(cd_new, ".%s.%d" % (c, os.getpid()))
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh, open(src) as fs:
                fh.write(fs.read())
            os.rename(tmp, dst)
            fresh.append(dst)
        new = dict(svc, login=to, state=old_state, changed=now(),
                   exec=[_rehome(x, oh, nh) for x in svc["exec"]] if svc.get("exec") else svc.get("exec"),
                   env=dict((k, _rehome(v, oh, nh)) for k, v in (svc.get("env") or {}).items()),
                   paths=[_rehome(p, oh, nh) for p in svc.get("paths") or []],
                   moved_from={"login": login, "at": now()})
        if (svc.get("done_when") or {}).get("file"):    # a task's output (#2529)
            new["done_when"] = dict(svc["done_when"], file=_rehome(svc["done_when"]["file"], oh, nh))
        why = service_check(new, to, name)
        if why:
            raise ValueError(why)
        _svc_mkdir(os.path.dirname(service_dir(paths, to)))
        _svc_mkdir(service_dir(paths, to))
        write_json(f_new, new, 0o600)
    except Exception as e:
        for p, q in reversed(done):
            try:
                _move_tree(q, p)
                _chown_tree(p, a[0], a[1])
            except Exception as e2:
                print("fleet-node-supervisor: could not put %s back to %s: %s" % (q, p, e2), file=sys.stderr)
        for dst in fresh:
            os.remove(dst)
        write_json(f_old, svc, 0o600)
        print("fleet-node-supervisor: move failed (%s) — put back, %s/%s is as it was" % (e, login, name),
              file=sys.stderr)
        return 1
    os.remove(f_old)
    # a credential no other entry of the old login names leaves with it
    still = set(c for x in _register(paths, login) for c in (x.get("creds") or []))
    for c, src, _ in creds:
        if c not in still:
            os.remove(src)
    print("moved %s/%s → %s/%s%s" % (login, name, to, name,
                                     " (stopped, as it was)" if old_state == "stopped" else
                                     " — the daemon starts it as %s on its next pass" % to))
    for p, q in moves:
        print("  path %s → %s" % (p, q))
    for x, y in logs[:1]:
        print("  log  %s → %s" % (x, y))
    for c, _, _ in creds:
        print("  credential %s → %s's" % (c, to))
    for n in notes:
        print("  note: %s" % n)
    return 0


def _register(paths, login):
    return [svc for l, _, _, svc, _ in service_files(paths) if l == login and svc]


def _svc_logdir_for(d, uid, gid):
    if not os.path.isdir(d):
        os.makedirs(d, 0o755)
    if os.geteuid() == 0:
        os.lchown(d, uid, gid)


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
    if cmd == "service":
        return service_cli(paths, rest)
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
            return account_adopt(paths, rest[1], dry="--dry-run" in rest, rejoin="--rejoin" in rest)
        if sub == "release" and len(rest) > 1:
            return account_release(paths, rest[1], force="--force" in rest)
    table = load_table(paths)
    if cmd == "run":
        return Supervisor(paths, table).run()
    if cmd == "tick":
        return Supervisor(paths, table).tick_once()
    if cmd == "status":
        state = read_json(paths.state_file, {})
        code, lines = status_lines(paths, table, state)
        if "--json" in rest:
            print(json.dumps({"health": code, "state": state,
                              "services": services_summary(paths, state, tail=True)}, indent=1, sort_keys=True))
        elif "--check" in rest:
            refused = sorted(lanes_now(paths, state)) if code == 0 else []
            if refused:
                print("%s · 令牌失效 · 需要 relogin: %s" % (lines[0], " ".join(refused)))
                return 3
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
        for h in res["handwritten"]:
            print("handwritten (runs as %s, not in the register, left in place): %s" % (h["login"], h["path"]))
        for c in res["clientshell"]:
            print("clientshell (left in place): %s" % client_shell_says(c, paths))
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
