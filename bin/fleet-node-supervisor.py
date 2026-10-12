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
                watchdog, Spotlight off on a Mac …), each run as at most ONE copy: a task still running
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
                failing task never touches another's. An account on the machine's
                shared credential proxy (credsep.json "shared") runs no resident
                `cred-proxy`: its relay pass is the one-minute task `cred-relay`
                (`fleet-cred-proxy.sh relay-tick`, issue #3524).
                An account becomes managed by `account adopt <login>`: its own
                fleet LaunchAgents / LaunchDaemons are booted out and moved to the
                attic (kept until released); one that will not unload puts every
                one back. Its own node agent (com.ccquota.agent.<login>, #2387)
                moves with them, and only once all are out its settings — the
                agent plist's CCQUOTA_* / FLEET_CONF_DIR + its node.env's CCQUOTA_*
                (a separated login's from the credsep store) — land in
                <state>/logins/<login>.env (root 0600), where the machine's one
                node program (C5) serves it from; that child restarts whenever
                logins/ changes — held while an account op it runs is in its
                book (<state>/agent/<login>/account-ops.json, #2918: opening a
                login writes that .env mid-op), at most FLEET_NODE_RELOAD_HOLD
                (960 s). `account release <login>` is the way back, one
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
  * entry     — the address's entry port (issue #3070, EPIC #3067 C3), only with
                FLEET_ENTRY=1 (the environment, else machine.env): a SECOND sshd
                (`sshd -D -e -f <state>/entry/sshd_config`, its own host key, port
                FLEET_ENTRY_PORT = 22022) as a child, reloaded by SIGHUP; its keys
                files <state>/entry/keys/<login> (root 0644) written only from the
                hub's list (`entry pull`, run by the node program on an entry_keys
                push) and put back every FLEET_ENTRY_EVERY when someone else changed
                them; AllowUsers = the list's taken-over, non-admin logins — none ⇒
                no config, no listener. The system's sshd is never touched.
                `entry reach` (issue #3072, C6; the node program runs it every 5
                minutes): the global IPv6, the router asked to forward the port
                (FLEET_ENTRY_PORTMAP), POSTed to the hub, which dials each address
                and answers; <state>/entry/reach.json feeds the doctor's `public` row.
  * ci-runner — the machine's one test runner (issue #3144, EPIC #3139 C5), only
                while <state>/ci.env exists: bin/fleet-ci-runner.py `loop` as a
                child (restarted on a new ci.env); its word, <state>/ci-runner.json,
                goes into state.json `ci_runner` and the status `ci-runner` line;
                its login (fleet-ci) is one of the tenants the doctor checks.
  * sweep     — fleet plist leftovers (`*.plist.bak*`, `.pre-move`, `.retired*`,
                `.disabled*` …) in /Library/LaunchDaemons and every login's
                ~/Library/LaunchAgents are MOVED to the attic
                (`/var/db/fleet-node/attic/`), kept FLEET_NODE_ATTIC_DAYS (7) days,
                and can be put back (`attic restore <id>`). On a managed machine
                (expected.json) a fleet unit OUTSIDE its expected set is booted out
                and moved there too (issue #2981): a machine unit this daemon does
                not run, a taken-over login's left behind, a gone login's, and a child's old LaunchDaemon
                once the child can start here (cred-proxy-shared). The expected set:
                this daemon, expected.json's `labels`, <state>/keep-labels, each
                existing login's own credential proxy (credsep.<login>), and every
                unit of an admin login (never taken over, #2842 — its agent is the
                machine's admin node; issue #2997). A
                login not taken over keeps its units, named (`account adopt` is
                its road); a unit that will not unload stays, named; a running
                fleet-onboard-drill.sh (a process running it, never a command line
                that merely names it — issue #2991) holds every removal until the next sweep.
                It also clears a taken-over login that still carries the person's
                client here (issue #2702): `~/.cache/claude-fleet/shell` or a
                `~/.zshrc` line that sources shell/fleet-login.zsh / cw.zsh / the
                old bootstrap block / the fleet's header comment above one
                (shell_hooks, the one rule) — a managed machine is no one's client — by
                running bin/fleet-node-shell-retire.sh --login <login> --if-idle
                itself (issue #2981; a client still running is named and left for
                the next sweep). Handwritten units and the client shell look ONLY
                at the logins this daemon took over (logins/<login>.env): an admin,
                a local user who never used the fleet — not the fleet's, never named.

State survives a restart: `state.json` (0644, so any login's doctor can read it)
carries every task's last run and every child's pid; a restarted supervisor ADOPTS
a child still alive from the last run instead of starting a second one.

Root only ever runs code from the root runtime (共同约定 3,
`/Library/Application Support/claude-fleet/current`), and refuses a script there
that is not root-owned or that a group / other may write.

Usage:
  fleet-node-supervisor.py run                 the daemon loop (what launchd runs)
  fleet-node-supervisor.py tick                one pass: due tasks (waited for) + the sweep
  fleet-node-supervisor.py shell-hooks <zshrc> [--dry-run]
                                               take the fleet's login-shell hook lines out of one
                                               file — the ONE rule (issue #2991); what
                                               fleet-node-shell-retire.sh runs as the login
  fleet-node-supervisor.py status [--json] [--check]
                                               one line per item: what · last run · result.
                                               --check: exit 0 healthy · 1 installed but not
                                               running (stale heartbeat) · 2 not installed ·
                                               3 running, but the hub refuses a login's lane
                                               (令牌失效 · 需要 relogin, issue #2501)
                                               · 4 running, but without Full Disk Access
                                               (the hub's account removes are refused, #2973)
                                               · 5 WEDGED: alive, its main loop stopped (#3086)
                                               · 6 the machine's TCC is stuck: the FDA probe
                                               timed out FLEET_NODE_TCC_STUCK times running —
                                               every user delete fails until sandboxd is
                                               restarted (issue #3167)
  fleet-node-supervisor.py tenants [--json] [--check]
                                               the taken-over logins' abilities (issue #2842):
                                               admin group · sudo rules · sudoers. --check: exit
                                               0 none can · 1 one can (the doctor's FAIL) · 2 no
                                               taken-over login · 3 the sudo half unread (not
                                               root, no daemon reading yet). `account adopt`
                                               refuses (5) a login that can.
  fleet-node-supervisor.py entry pull [--version N] | apply <file|-> [--force] | ensure | status [--check]
                                               the entry port (#3070): pull the hub's list
                                               (0 applied · 1 the hub did not answer, the
                                               last list stands · 3 off); apply a list in
                                               hand; one converge pass; --check is the
                                               doctor's row (0 ok · 1 WARN · 2 off)
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
  fleet-node-supervisor.py account forget <login> [--force]
                                               a login being DELETED (fleet-login-remove.sh, #2924):
                                               its tasks stop, its entry and logins/<login>.env go,
                                               its attic copies are never loaded back; release of a
                                               login no longer on the machine does only this
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
  FLEET_NODE_WATCHDOG_SECS (300)  a loop that has not come round this long logs the
                        phase it is stuck in, dumps its stacks and exits 70 for launchd
                        to restart it (0 = off); FLEET_NODE_WATCHDOG_SWEEP_SECS (900)
                        for a pass that sweeps (#3079, #3086)
  SIGUSR1               `sudo kill -USR1 <pid>` writes every thread's Python stack into
                        supervisor.log and the loop goes on (#3084)
  FLEET_NODE_FDA_TIMEOUT (20)  the Full Disk Access probe (a child) is killed past this
  FLEET_NODE_TCC_STUCK (2)  that many probe timeouts in a row = the machine's TCC is
                        stuck (status --check exit 6, the doctor's FAIL — #3167)
  FLEET_NODE_TEST_HANG <phase>:<fifo>  (FLEET_NODE_TEST=1 only) that phase blocks in an
                        open() of the FIFO — the watchdog drills' wedge
  FLEET_NODE_LAUNCHCTL  launchctl's path ('' = do not load/unload)
  FLEET_NODE_TEST=1     skip the root-ownership check on the runtime
  FLEET_NODE_PASSWD     a JSON {login: {uid, gid, home[, groups, sudo]}} read instead of
                        the passwd database and the tenant check (tests; under
                        FLEET_NODE_TEST only)
  FLEET_NODE_TENANT_EVERY (300)  how often the daemon re-reads the tenants' abilities
  FLEET_ENTRY_SSHD (/usr/sbin/sshd)  FLEET_ENTRY_KEYGEN (/usr/bin/ssh-keygen)  FLEET_ENTRY_EVERY (60)
  FLEET_ENTRY_LSOF  FLEET_ENTRY_DSEDITGROUP (/usr/sbin/dseditgroup on macOS; '' = leave
                        com.apple.access_ssh alone)  FLEET_ENTRY_PULL_SECS (10)
  FLEET_ENTRY_TEST_SETENV  (FLEET_NODE_TEST only) more `K=V …` for the entry's SetEnv
  FLEET_NODE_BREW_PREFIX  __BREW_PREFIX__ in the templates (default /opt/homebrew, or
                        /usr/local when that is where brew is)
"""
from __future__ import print_function

import datetime
import errno
import faulthandler
import fcntl
import glob
import json
import os
import plistlib
import pwd
import re
import shutil
import signal
import stat
import subprocess
import threading
import sys
import tempfile
import time

# the root core's client (#3555); a copy of this file without its sibling (an older
# tree, a selftest's sandbox bin) has no core — the old road, byte for byte
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import fleet_node_core as core  # noqa: E402
except ImportError:
    core = None

# Existing launchd fixtures run on Linux CI too; this seam never applies on a node.
MAC = sys.platform == "darwin" or (os.environ.get("FLEET_NODE_TEST") == "1"
                                     and "FLEET_NODE_LAUNCHCTL" in os.environ)
LABEL = "com.claude-fleet.node"
SYSTEMD_UNIT = "claude-fleet-node.service"
DEFAULT_ROOT = "/Library/Application Support/claude-fleet" if MAC else "/opt/claude-fleet"
# Non-secret managed settings needed by root children AND demoted tenant jobs.
NODE_ENV_KEYS = ("FLEET_NODE_ROOT", "FLEET_NODE_STATE", "FLEET_NODE_RUNTIME", "FLEET_NODE_LOG",
                 "FLEET_NODE_USERS", "FLEET_NODE_SERVICE", "FLEET_NODE_UPDATE_OWNER", "FLEET_NODE_BOOT_ID",
                 "FLEET_CREDSEP_LIB", "FLEET_CREDSEP_ROOT_BASE", "FLEET_CREDSEP_RUN_BASE",
                 "FLEET_CREDSEP_ROLE", "FLEET_NODE_RUN_SSHD", "FLEET_ENTRY", "FLEET_ENTRY_PORT",
                 # one person's pod (#3550): its profile, and the hello's CapUserPod
                 "FLEET_NODE_PROFILE", "FLEET_USER_POD",
                 # a container's entry= route (#3213): `entry reach` runs under the node
                 # program, and the hub must knock on the load balancer, not the NAT
                 "CCQUOTA_FLEET_NODE_ROUTES",
                 # the root core (#3555): where it listens, and FLEET_NODE_CORE=0 = the old road
                 "FLEET_NODE_CORE", "FLEET_NODE_CORE_SOCK")


def node_environment():
    return {k: os.environ[k] for k in NODE_ENV_KEYS if os.environ.get(k)}

# A fleet plist name, and a LEFTOVER of one: anything after `.plist`.
FLEET_PLIST_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.)")
LEFTOVER_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.).*\.plist\..+$")
# Units the machine runs ONCE (the table below); every other launchd template is
# an account unit (issue #2332). cred-proxy-shared has no template — it is listed
# so an account's adopt never boots the machine's proxy out.
MACHINE_UNITS = ("memguard", "node", "cred-proxy-shared")
# The locale every child is started in (issue #3514): macOS always has
# en_US.UTF-8, a slim Linux image only C.UTF-8 — there en_US.UTF-8 named a locale
# that does not exist, perl warned on every call and python's setlocale raised,
# so the 看台's ⌘P table was never built on fleet-linux-0.
NODE_LANG = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"
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
        self.runtime = env("FLEET_NODE_RUNTIME", os.path.join(env("FLEET_NODE_ROOT", DEFAULT_ROOT), "current"))
        self.daemon_dir = env("FLEET_NODE_DAEMON_DIR", "/Library/LaunchDaemons" if MAC else "/etc/systemd/system")
        self.users = env("FLEET_NODE_USERS", "/Users" if MAC else "/home")
        self.state_file = os.path.join(self.state, "state.json")
        self.attic = os.path.join(self.state, "attic")
        self.attic_index = os.path.join(self.attic, "index.json")
        self.locks = os.path.join(self.state, "locks")
        self.main_lock = os.path.join(self.state, "supervisor.lock")
        self.expected = os.path.join(self.state, "expected.json")
        self.accounts = os.path.join(self.state, "accounts.json")
        self.logins = os.path.join(self.state, "logins")
        self.plist = os.path.join(self.daemon_dir, LABEL + ".plist" if MAC else SYSTEMD_UNIT)


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


def update_verify_due(paths, t, since):
    """True when the updater (fleet-node-update.py) switched a release and its
    settle has passed, so its verify need not wait for the task's next slot."""
    settle = env_num("FLEET_NODE_UPDATE_SETTLE", 30)
    if since < settle:
        return False
    u = read_json(os.path.join(paths.state, "update.json"), None)
    if not isinstance(u, dict) or u.get("phase") != "switched":
        return False
    try:
        return t - float(u.get("switched_at") or 0) >= settle
    except (TypeError, ValueError):
        return False


def update_now_path(paths):
    return os.path.join(paths.state, "update-now")


def update_now_due(paths):
    """True when a pushed release asked for the update now (issue #3146): the
    machine's node program (`ccquota agent --machine`, root) wrote
    <state>/update-now on the hub's `release {sha}`. Only a regular file root's
    (or this daemon's own user's) counts."""
    try:
        st = os.lstat(update_now_path(paths))
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_uid in (0, os.geteuid())


def update_now_take(paths):
    """Consume update-now as the update task starts: a push that lands while it
    runs writes a new file and wakes the next one. The sha it named, or ''."""
    if not update_now_due(paths):
        return ""
    p = update_now_path(paths)
    try:
        with open(p) as fh:
            sha = fh.read(64).strip()
    except OSError:
        sha = ""
    try:
        os.unlink(p)
    except OSError:
        pass
    return sha if re.match(r"^[0-9a-f]{40}$", sha) else "?"


def read_json(path, default):
    """A JSON file, or `default`. Opened O_NONBLOCK and read only when it is a
    regular file (issue #3086): a FIFO / device planted at the path answers
    `default` at once instead of holding the main loop in open()."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return default
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            return default
        with os.fdopen(fd) as f:
            return json.load(f)
    except (IOError, OSError, ValueError):
        return default


def open_ro(path, follow=False):
    """An fd for root's read of a file in a place it does not keep — a login's
    home, its LaunchAgents, a tenant's log or credential (issue #3084): read_json's
    rule (#3086) for the rest of root's reads — O_NONBLOCK, so a FIFO or a device
    planted there answers at once instead of holding the loop in open(), then
    refused unless it is a regular file; a symlink only when follow. OSError
    otherwise."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | (0 if follow else getattr(os, "O_NOFOLLOW", 0)))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, "not a regular file", path)
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    except OSError:
        os.close(fd)
        raise
    return fd


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


def reload_sig(r):
    """dir_sig of a child's `reload`: one path / pattern, or a list of them."""
    if isinstance(r, (list, tuple)):
        return "||".join(dir_sig(x) for x in r)
    return dir_sig(r)


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


def reload_held(c, pid=None):
    """What holds a child's reload (#2918): the first op its `hold` books
    (a glob of JSON files) name as running, by a live pid — "account create
    alice (op …)" — else "". A book left by a dead process holds nothing.
    No book naming one, the child's own process tree still may (#2927): a
    `hold_argv` script running under <pid> — a node program from before the
    book (the release's ccquota trails its tree) writes none, and the restart
    cut its create off all the same."""
    if not c.get("hold"):
        return ""
    for f in sorted(glob.glob(c["hold"])):
        book = read_json(f, {})
        running = book.get("inflight") if isinstance(book, dict) else None
        for op_id, x in sorted((running or {}).items()):
            if isinstance(x, dict) and pid_alive(x.get("pid")):
                return "account %s %s (op %s)" % (x.get("op"), x.get("login"), op_id)
    names = c.get("hold_argv") or []
    if pid and names:
        for cmd in descendant_cmds(pid):
            for n in names:
                if n in cmd:
                    return "%s (under pid %s)" % (cmd[cmd.find(n):][:120], pid)
    return ""


def descendant_cmds(pid):
    """The command lines of every process under <pid> (one `ps`, walked)."""
    try:
        out = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="],
                                      stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except Exception:
        return []
    kids, cmds = {}, {}
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) < 2 or not f[0].isdigit() or not f[1].isdigit():
            continue
        kids.setdefault(int(f[1]), []).append(int(f[0]))
        cmds[int(f[0])] = f[2] if len(f) > 2 else ""
    seen, todo, res = set(), list(kids.get(int(pid), [])), []
    while todo:
        q = todo.pop()
        if q in seen:
            continue
        seen.add(q)
        res.append(cmds.get(q, ""))
        todo.extend(kids.get(q, []))
    return res


# --------------------------------------------------------------- the table -----
def default_table(paths):
    rt_bin = os.path.join(paths.runtime, "bin")
    cred_lib = env("FLEET_CREDSEP_LIB", "/Library/Application Support/claude-fleet/credsep" if MAC else "/usr/local/lib/claude-fleet/credsep")
    launcher = os.path.join(cred_lib, "fleet-credsep-launch.py")
    table = {
        "children": [
            {"name": "cred-proxy-shared",
             "cmd": ["/usr/bin/python3", "-I", launcher, "shared"],
             "legacy": "com.claude-fleet.cred-proxy-shared",
             # only while the machine has a shared proxy (`fleet-credsep.py machine
             # install`): without its record the launcher exits at once, and a
             # `machine uninstall` stops the daemon's copy (issue #2981)
             "requires": [os.path.join(env("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred"), ".shared.json")],
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
             "reload": [os.path.join(paths.state, "logins", "*.env"),
                        # …and machine.env: its token, and FLEET_ENTRY, which
                        # decides whether it follows the entry keys (#3070)
                        os.path.join(paths.state, "machine.env")],
             # …but never under an account op it is running (#2918): opening a
             # login writes that login's .env half way through, and the restart
             # cut off the very create that wrote it. Each tenant's book names
             # the op running; the restart waits for it (reload_held)
             "hold": os.path.join(paths.state, "agent", "*", "account-ops.json"),
             # …and, book or none, the account scripts still running under it
             # (#2927: the release's ccquota predated the book, nothing held)
             "hold_argv": ["fleet-login-new.sh", "fleet-login-remove.sh"],
             "note": "C5 #2333"},
        ],
        "tasks": [
            # --watch runs the orphan watchdog too; it is its own task below, all
            # users at once, so it is switched off here (one copy).
            {"name": "diskguard", "every": 60,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-diskguard.sh"), "--watch"],
             "env": {"FLEET_ORPHAN_CPU_PCT": "0"}},
            # "core": what the root core does for it when one answers (#3555) —
            # the daemon's own child then only asks; no core = cmd, as root
            {"name": "memguard", "every": 10,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-memguard.sh"), "--once"],
             "core": {"op": "memguard", "args": {"level": "once"}}},
            {"name": "orphans", "every": 60,
             "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-diskguard.sh"), "--orphan-watch"],
             "env": {"FLEET_ORPHAN_ALL_USERS": "1"}},
            # The machine's shared dirs (#2299): /Users/Shared/claude-fleet and its
            # heavy/ + sessions/ root's and 1777, the heavy slots root's 0644, any
            # file planted under another login's name swept — each login its own.
            {"name": "shared-dirs", "every": 60,
             "cmd": ["/usr/bin/python3", "-I", os.path.join(rt_bin, "fleet-shared-dirs.py")]},
            # Spotlight off on a managed Mac (#3402): every volume's index and each
            # person's CoreSpotlight knowledge agents — run at the daemon's start
            # (a new machine is off once it is up) and hourly (a macOS update
            # turns indexing back on). <state>/spotlight.keep leaves it on.
            *([{"name": "spotlight", "every": 3600, "timeout": 300,
                "cmd": ["/bin/bash", os.path.join(rt_bin, "fleet-spotlight.sh"), "off", "--tick"],
                "core": {"op": "power", "args": {"profile": "spotlight-off"}}}]
              if MAC else []),
            # The one updater (C6, #2334): every part of the machine to the hub's
            # release, or none. A switch ends in a restart request (below). A new
            # stable the hub pushes (issue #3146: the node program writes
            # <state>/update-now) runs it at once — task_due; the clock stays.
            {"name": "update", "every": env_num("FLEET_NODE_UPDATE_EVERY", 300), "timeout": 1800,
             "cmd": ["/usr/bin/python3", "-I", os.path.join(rt_bin, "fleet-node-update.py"), "tick"]},
        ],
        # None = the runtime's launchd templates (account_units); a table file may
        # give the list itself, in account_units' shape.
        "account": None,
    }
    if env("FLEET_NODE_UPDATE_OWNER", "hub") == "image":
        table["tasks"] = [t for t in table["tasks"] if t["name"] != "update"]
        table["tasks"].append({"name": "credential-pool", "every": 300, "timeout": 180,
                               "cmd": ["/usr/bin/python3", "-I", os.path.join(rt_bin, "fleet-credsep.py"),
                                       "machine", "pool-sync"]})
    if not MAC and env("FLEET_NODE_RUN_SSHD", "0") == "1":
        table["children"].append({"name": "sshd", "cmd": ["/usr/sbin/sshd", "-D", "-e"]})
    if user_pod():
        # One person's pod (#3550, EPIC #3500 C5): the machine-level loops are
        # the cluster's (its one ops copy) — only the updater that moves this
        # pod's own runtime stays. Its children are its own (agent, proxy, sshd).
        table["tasks"] = [t for t in table["tasks"] if t["name"] in USER_POD_TASKS]
    return table


# A user pod keeps only these machine tasks (#3550): the rest run once for the
# cluster, never once per person.
USER_POD_TASKS = ("update", "credential-pool")


def user_pod():
    """FLEET_NODE_PROFILE=user-pod (extras/managed-node/render.py --user-pod)."""
    return not MAC and env("FLEET_NODE_PROFILE", "") == "user-pod"


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
    if not MAC:
        return "/usr"
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


# -- tenants (issue #2842): a taken-over login is a TENANT — no admin, no sudo.
# What a session may destroy is what its login can do, never a rule in a prompt:
# the fleet keeps that true by checking it here, refusing to adopt an admin and
# FAILing the doctor's `tenants` row when a tenant gains the ability.
SUDOERS = ("/etc/sudoers", "/etc/sudoers.d")


def _sudoers_files():
    out = []
    for p in SUDOERS:
        if os.path.isdir(p):
            try:
                out += [os.path.join(p, n) for n in sorted(os.listdir(p))
                        if not n.startswith(".") and not n.endswith("~")]
            except OSError:
                pass
        elif os.path.exists(p):
            out.append(p)
    return out


def tenant_privileges(login):
    """(why, complete): what lets <login> do what only an admin may — `admin 组`,
    `sudo -l: …`, `sudoers: <file>` — [] when nothing. complete is False when this
    reader could not look at all of it: the sudo rules and the sudoers files are
    root's to read, the groups anyone's. Test mode reads the fake passwd entry's
    `groups` / `sudo` instead."""
    fake = os.environ.get("FLEET_NODE_PASSWD")
    if fake and env("FLEET_NODE_TEST", "") == "1":
        e = (read_json(fake, {}) or {}).get(login) or {}
        why = ["admin 组"] if "admin" in (e.get("groups") or []) else []
        if e.get("sudo"):
            why.append("sudo -l: %s" % e["sudo"])
        return why, True
    why = []
    try:
        g = subprocess.check_output(["id", "-Gn", login], stderr=subprocess.DEVNULL,
                                    universal_newlines=True, timeout=10).split()
    except (OSError, subprocess.SubprocessError):
        g = []
    for group in (("admin",) if MAC else ("sudo", "wheel", "admin", "docker", "lxd", "incus")):
        if group in g:
            why.append("%s 组" % group)
    if os.geteuid() != 0:
        return why, False
    try:
        r = subprocess.run(["sudo", "-n", "-l", "-U", login], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
        if r.returncode == 0 and "may run" in r.stdout:
            rules = [l.strip() for l in r.stdout.split("may run", 1)[1].splitlines()[1:] if l.strip()]
            why.append("sudo -l: %s" % (rules[0] if rules else "has rules"))
    except (OSError, subprocess.SubprocessError):
        pass
    word = re.compile(r"(^|[\s,=:!])%s($|[\s,=])" % re.escape(login))
    for f in _sudoers_files():
        try:
            with open(f, errors="replace") as fh:
                if any(word.search(l) for l in fh if l.strip() and not l.lstrip().startswith("#")):
                    why.append("sudoers: %s" % f)
        except OSError:
            pass
    return why, True


def tenant_logins(paths):
    """Every login this daemon took over: managed in accounts.json, or with a
    logins/<login>.env — and the test runner's login (#3144), which must be one too."""
    ci = ci_login(paths)
    return sorted({k for k, v in accounts_read(paths).items() if (v or {}).get("managed")}
                  | taken_over(paths) | ({ci} if ci and account_ident(ci) else set()))


def tenants_reading(paths):
    """{"at", "complete", "bad": {login: [why]}, "logins": [...]} for every tenant."""
    bad, complete = {}, True
    logins = tenant_logins(paths)
    for login in logins:
        why, full = tenant_privileges(login)
        complete = complete and full
        if why:
            bad[login] = why
    return {"at": now(), "complete": complete, "bad": bad, "logins": logins}


def fda_reading():
    """Does THIS process hold macOS Full Disk Access (issue #2973)? The TCC
    database is unreadable without it, even to root. True · False · None (no
    such file: not macOS, or nothing to tell). `program` is what a person grants
    it to — the interpreter launchd runs this daemon with, which every child (the
    node program and the account ops it runs) inherits as its responsible one."""
    p = fda_probe_start()
    try:
        rc = p.wait(timeout=fda_timeout())
    except subprocess.TimeoutExpired:
        fda_probe_kill(p)
        rc = None
    return fda_probe_result(rc)


# The probe runs in a CHILD (issue #3086): on mini2 2026-10-11 tccd stopped
# answering — even `ls` of the TCC directory came back EINTR — and the daemon's
# own open() of TCC.db never returned: its main loop stopped for good, every task
# with it, and every restart wedged again (the probe is due at once). A child
# inherits the daemon's responsible process, so its answer is the daemon's; the
# loop polls it and never waits, and one that does not answer in
# FLEET_NODE_FDA_TIMEOUT (20 s) is killed and read as «unknown».
FDA_PROBE = ("import errno, sys\n"
             "try:\n"
             "    f = open(sys.argv[1], 'rb'); f.read(1); f.close(); sys.exit(0)\n"
             "except FileNotFoundError:\n"
             "    sys.exit(3)\n"
             "except OSError:\n"
             "    sys.exit(1)\n")


def fda_timeout():
    return env_num("FLEET_NODE_FDA_TIMEOUT", 20)


def fda_probe_start():
    db = env("FLEET_NODE_TCC_DB", "/Library/Application Support/com.apple.TCC/TCC.db")
    return subprocess.Popen([sys.executable, "-I", "-c", FDA_PROBE, db], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True, close_fds=True)


def fda_probe_kill(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass


def fda_probe_result(rc):
    """rc 0 → True · 3 (no such file) → None · other → False · None (no answer
    in time) → None with `timeout` set: nothing known, nothing to tell a person."""
    r = {"ok": True if rc == 0 else None if rc in (3, None) else False, "at": now(),
         "program": os.path.realpath(sys.executable)}
    if rc is None:
        r["timeout"] = fda_timeout()
    return r


def tcc_stuck_line(state):
    """The words for a machine whose TCC stopped answering, or "" (issue #3167).
    The FDA probe is a plain open() of TCC.db; it times out only when sandboxd /
    tccd do not answer. On mac-a that was an authorization dialog nobody was
    there to click — the user tccd waiting on it forever, sandboxd's synchronous
    approval queues full behind it — and every user delete on the machine then
    failed «disallowed by sandbox», even sudo dscl. One timeout can be a slow
    moment; FLEET_NODE_TCC_STUCK (2) in a row is the wedge."""
    f = state.get("fda") or {}
    n = f.get("stuck") or 0
    if n < env_num("FLEET_NODE_TCC_STUCK", 2):
        return ""
    return ("macOS 隐私检查（TCC）卡住了：FDA 探针连续 %d 次 %ss 没有回应——本机删不掉任何用户（dscl -14120 "
            "「disallowed by sandbox」），入口发的删号都会失败。多半是控制台上有一个没人点的授权框。处置：屏幕前点掉它；"
            "或 sudo kill -9 $(pgrep -f 'TCC.framework/Support/tccd$')（各登录的用户级 tccd），"
            "sandboxd 还卡着就 sudo killall -9 sandboxd（launchd 会拉起）" % (n, f.get("timeout") or fda_timeout()))


def fda_line(state):
    """The words for a daemon without Full Disk Access, or "" (issue #2973)."""
    f = state.get("fda") or {}
    if f.get("ok") is not False:
        return ""
    return ("没有完全磁盘访问：入口下发的删号会被 macOS 拒（dscl eDSPermissionError），入口一直 removing — "
            "系统设置 › 隐私与安全性 › 完全磁盘访问 里加上 %s，再 sudo launchctl kickstart -k system/%s"
            % (f.get("program") or "python3", LABEL))


def tenants_now(paths, state):
    """The tenants reading: fresh where this reader sees all of it (root), else the
    daemon's last complete reading in state.json with this reader's own fresh look
    (the groups) on top."""
    cur = tenants_reading(paths)
    if cur["complete"]:
        return cur
    last = state.get("tenants") or {}
    for login, why in (last.get("bad") or {}).items():
        if login in cur["logins"]:
            cur["bad"][login] = sorted(set(cur["bad"].get(login, [])) | set(why))
    cur["daemon_at"] = last.get("at")
    return cur


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
    e.setdefault("LANG", NODE_LANG)
    # the plists' own LANG / LC_ALL are macOS's: on Linux the same words name no locale
    for k in ("LANG", "LC_ALL", "LC_CTYPE"):
        if e.get(k) == "en_US.UTF-8":
            e[k] = NODE_LANG
    e.update(HOME=home, USER=login, LOGNAME=login,
             FLEET_CONF_DIR=os.path.join(home, ".config", "claude-fleet"),
             FLEET_NODE_ACCOUNT=login)
    e.update(node_environment())
    # job: the name the root core knows it by (run-as, #3555) — never an argv
    ent = {"name": "%s/%s" % (login, unit["name"]), "account": login, "unit": unit["name"], "job": unit["name"],
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


def on_shared_proxy(home):
    """True when this login's sessions go through the machine's ONE shared
    credential proxy (`fleet-credsep.py machine join`: credsep.json "shared")."""
    try:
        with open(os.path.join(home, ".config", "claude-fleet", "credsep.json")) as f:
            rec = json.load(f)
        return rec.get("shared") is True or os.path.basename(str(rec.get("run") or "")) == ".shared"
    except (OSError, ValueError, AttributeError):
        return False


def account_unit_for(unit, home):
    """The unit as this login runs it. A login on the shared proxy keeps no
    resident `fleet-cred-proxy.sh run` (issue #3524): the shared proxy already
    answers its sessions — on its old port too (#2217) — so all that launcher did
    there was keep the login's relay pass. That pass is kept by a one-minute task
    instead (`relay-tick`, as the login); leaving the shared proxy brings the
    resident unit back on the next tick."""
    if unit["name"] != "cred-proxy" or not unit.get("keepalive") or not on_shared_proxy(home):
        return unit
    argv = list(unit["argv"])
    if argv and argv[-1] == "run":
        argv[-1] = "relay-tick"
    else:
        argv.append("relay-tick")
    u = dict((k, v) for k, v in unit.items() if k != "keepalive")
    u.update(name="cred-relay", argv=argv, every=60, timeout=600)
    return u


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
    e = {"PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": NODE_LANG}
    e.update((k, v) for k, v in (svc.get("env") or {}).items() if k not in SVC_ENV_DROP)
    e.update(HOME=home, USER=login, LOGNAME=login, FLEET_SERVICE=name)
    lg = service_log(paths, login, name)
    return {"name": "svc:%s/%s" % (login, name), "account": login, "service": name, "job": "svc:" + name,
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
            fd = open_ro(os.path.join(d, c))
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
        fd = open_ro(path)
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
    e = {"PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": NODE_LANG}
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
        self.fda_probe = None  # (Popen, t0, killed) of the Full Disk Access probe (#3086)
        self.phase = "start"   # what the main loop is doing now, for the watchdog (#3086)
        self.phase_at = now()
        self.deadline = None   # the loop must come round before this, or the watchdog ends it
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
                out.append(account_entry(account_unit_for(u, ident[2]), login, ident, brew))
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
        # the entry port (#3070) only where it is switched on — off, no child at all
        entry = [entry_child(self.p)] if entry_settings(self.p)[0] else []
        # the test runner (#3144) only where ci.env is — off, no child at all
        entry += [ci_child(self.p)] if ci_on(self.p) else []
        return (list(self.table["children"]) + entry + [e for e in self.account_entries() if e.get("keepalive")]
                + self.service_entries())

    def all_tasks(self):
        return list(self.table["tasks"]) + [e for e in self.account_entries() if not e.get("keepalive")]

    def core_cmd(self, ent):
        """The daemon's own child that ASKS the root core for <ent> (#3555): an
        account job by its name (run-as, --follow: it exits with the job's rc and a
        TERM to it stops the job), a machine task by its "core" request. None = the
        old road — no core answering here, or nothing the core's table holds."""
        if ent.get("account"):
            if not ent.get("job"):
                return None
            op, args, follow = "run-as", {"login": ent["account"], "job": ent["job"]}, True
        elif ent.get("core"):
            op, args, follow = ent["core"]["op"], ent["core"]["args"], False
        else:
            return None
        script = os.path.join(self.p.runtime, "bin", "fleet-node-core.py")
        if core is None or not core.available() or not trusted(script):
            return None
        return (["/usr/bin/python3", "-I", script, "call", op, json.dumps(args, sort_keys=True)]
                + (["--follow"] if follow else []))

    def spawn(self, ent, fh, extra_env=None):
        """Popen one child / task: a machine one as root in the daemon's own env, an
        account one demoted to its login, its output opened by itself (ACCOUNT_SH).
        With the root core answering, what its table holds is asked of it instead."""
        cc = self.core_cmd(ent)
        if cc:
            return subprocess.Popen(cc, stdin=subprocess.DEVNULL, stdout=fh, stderr=fh,
                                    env=self.child_env(None), start_new_session=True, close_fds=True)
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
        ci = ci_summary(self.p)
        if ci is not None:
            self.state["ci_runner"] = ci
        else:
            self.state.pop("ci_runner", None)
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
        # O_NONBLOCK, and only ever a regular file (issue #3086): a FIFO planted at
        # the path would hold this open() — and the whole loop — until a reader came.
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NONBLOCK
        for _ in (0, 1):
            try:
                fd = os.open(path, flags, 0o644)
            except OSError as e:
                if e.errno != errno.ENXIO:   # ENXIO: a FIFO with no reader
                    raise
                fd = None
            if fd is not None and stat.S_ISREG(os.fstat(fd).st_mode):
                fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
                return os.fdopen(fd, "ab")
            if fd is not None:
                os.close(fd)
            self.log("log %s is not a regular file — moved aside to %s.not-a-file" % (path, path))
            os.rename(path, path + ".not-a-file")
        raise OSError(errno.EIO, "log %s: not a regular file" % path)

    def child_env(self, extra):
        e = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": os.path.join(self.p.state, "home"),
            "FLEET_CONF_DIR": os.path.join(self.p.state, "conf"),
            "TMPDIR": os.path.join(self.p.state, "tmp"),
            "LANG": NODE_LANG,
            "FLEET_NODE": "1",
        }
        e.update(node_environment())
        e.update(extra or {})
        return e

    def script_of(self, cmd):
        return script_of(cmd)

    # -- children
    def adopt(self):
        boot = os.environ.get("FLEET_NODE_BOOT_ID")
        if boot and (self.state.get("supervisor") or {}).get("boot_id") != boot:
            self.state["children"] = {}
            return
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
            # an adopted pid: we cannot wait() on it, so poll — a live one still
            # gets the reload check below (#3136: a supervisor restart adopted the
            # node agent and no later logins/*.env ever reloaded it)
            if name in self.adopted and not pid_alive(self.adopted[name]):
                del self.adopted[name]
                self.died(name, cs, None, t)
                continue
            if c.get("reload") and (name in self.procs or name in self.adopted) \
                    and cs.get("reload_sig") != reload_sig(c["reload"]):
                cpid = self.procs[name].pid if name in self.procs else self.adopted.get(name)
                held, since = reload_held(c, cpid), cs.get("reload_held_since")
                if held and (since is None or t - since < env_num("FLEET_NODE_RELOAD_HOLD", 960)):
                    if since is None:
                        cs["reload_held_since"] = t
                        self.dirty = True
                        self.log("child %s: %s changed — held while %s runs" % (name, c["reload"], held))
                elif c.get("reload_signal") and cpid:
                    # a child that re-reads its config on a signal keeps its pid and its
                    # live connections (the entry's sshd: SIGHUP re-execs on the new file)
                    try:
                        os.kill(cpid, getattr(signal, "SIG" + c["reload_signal"]))
                        self.log("child %s: %s changed — SIG%s" % (name, c["reload"], c["reload_signal"]))
                    except OSError:
                        pass
                    cs["reload_sig"] = reload_sig(c["reload"])
                    self.dirty = True
                    continue
                else:
                    why = "%s changed — starting it again" % c["reload"]
                    if since is not None:
                        why += " (held %ds%s)" % (t - since, ", past the cap: %s still runs" % held if held else "")
                    self.stop_one(name, why)
                    self.start_child(c, cs, t)
                    continue
            if name in self.adopted:
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
            else:
                # an adopted pid is not ours to wait() on: poll it out, so a
                # reload's start never runs beside the old one (#3136)
                end = time.time() + 5
                while pid_alive(pid) and time.time() < end:
                    time.sleep(0.05)
                if pid_alive(pid):
                    for kill in (os.killpg, os.kill):
                        try:
                            kill(pid, signal.SIGKILL)
                            break
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
            cs["reload_sig"] = reload_sig(c["reload"])
        cs.pop("reload_held_since", None)
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
        since = t - (ts.get("last_start") or 0)
        if since >= float(tk.get("every", 60)):
            return True
        # A new stable pushed by the hub (issue #3146) runs the update now; its
        # 5-minute clock stays as the fallback for a push that never came.
        if tk["name"] == "update" and update_now_due(self.p):
            return True
        # A switched release is verified FLEET_NODE_UPDATE_SETTLE (30 s) after the
        # switch, not on the next 5-minute tick (issue #2973): until then the hub
        # tells every refused newcomer the machine is 「正在更新（switched）」.
        return tk["name"] == "update" and update_verify_due(self.p, t, since)

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
            woke = update_now_take(self.p) if name == "update" else ""
            if woke:
                ts["woken"] = {"at": t, "sha": woke}
            fh.write(("--- %s %s%s\n" % (iso(t), " ".join(tk["cmd"]),
                                          (" (pushed %s)" % woke[:12]) if woke else "")).encode())
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

    # -- tenants (issue #2842)
    def tend_tenants(self, t):
        """Every FLEET_NODE_TENANT_EVERY (300 s): the tenants' reading, root's to
        take, into state.json for every login's doctor."""
        last = self.state.get("tenants") or {}
        if t - (last.get("at") or 0) < env_num("FLEET_NODE_TENANT_EVERY", 300):
            return
        cur = tenants_reading(self.p)
        for login in logins_creds_backfill(self.p):
            self.log("tenant %s: logins/%s.env had no CCQUOTA_FLEET_CREDS — added =1, its node program now "
                     "leases its accounts (issue #3276)" % (login, login))
        for login in sorted(set(cur["bad"]) - set(last.get("bad") or {})):
            self.log("tenant %s can do what only an admin may: %s — a taken-over login has no admin "
                     "and no sudo (issue #2842)" % (login, "; ".join(cur["bad"][login])))
        self.state["tenants"] = cur
        self.dirty = True

    # -- the entry port (issue #3070)
    def tend_entry(self, t, force=False):
        """Every FLEET_ENTRY_EVERY (60 s) while the entry is on: one converge pass —
        the host key, a keys file someone else rewrote put back from the last good
        list, a login that became an admin taken off AllowUsers."""
        if not force and t - (self.state.get("entry_at") or 0) < env_num("FLEET_ENTRY_EVERY", 60):
            return
        self.state["entry_at"] = t
        b = entry_converge(self.p)
        if b is None:
            return
        if not getattr(self, "rev_thread", None):
            # the door's revocation list (issue #3560): only once the entry is on
            self.rev_thread = threading.Thread(target=self.follow_revocations, name="revocations", daemon=True)
            self.rev_thread.start()
        if b.get("healed") and b["healed"].get("at") == b.get("checked_at"):
            self.log("entry: keys file(s) of %s were changed outside the hub's list — put back"
                     % ", ".join(b["healed"]["logins"]))
        if b.get("error") and b["error"] != self.state.get("entry_error"):
            self.log("entry: %s" % b["error"])
        self.state["entry_error"] = b.get("error") or ""
        self.dirty = True
        try:
            entry_audit(self.p)
        except Exception as e:  # the record must never take the entry pass down
            self.log("entry audit: %s" % e)

    def follow_revocations(self):
        """The door's revocation list (issue #3560), as a thread of the daemon."""
        revocations_follow(self.p, self.log, lambda: self.stop)

    # -- Full Disk Access (issue #2973)
    def tend_fda(self, t):
        """Every FLEET_NODE_TENANT_EVERY (300 s), as root only: can this daemon's
        process chain delete a login (TCC lets nothing without Full Disk Access
        delete a user record)? Into state.json for every login's doctor."""
        if os.geteuid() != 0 and not os.environ.get("FLEET_NODE_TCC_DB"):
            return   # a non-root reader is kept out of TCC.db anyway (the seam is a sandbox's)
        last = self.state.get("fda") or {}
        probe = self.fda_probe
        if probe is not None:
            p, t0, killed = probe
            rc = p.poll()
            if rc is None and not killed and t - t0 > fda_timeout():
                fda_probe_kill(p)
                self.fda_probe = (p, t0, True)
                self.log("fda: the TCC database's open() did not return in %ds — probe pid %d killed, "
                         "reading «unknown» (tccd not answering? issue #3086)" % (fda_timeout(), p.pid))
                cur = fda_probe_result(None)
                cur["stuck"] = (last.get("stuck") or 0) + 1
                if cur["stuck"] == env_num("FLEET_NODE_TCC_STUCK", 2):
                    self.log("tcc: the FDA probe timed out %d times running — this machine's TCC is stuck, "
                             "every user delete will fail until it is cleared (issue #3167)" % cur["stuck"])
            elif rc is None:
                return   # still asking — or killed and not yet gone: never a second probe beside it
            else:
                self.fda_probe = None
                if killed:
                    return   # its reading was taken at the kill
                cur = fda_probe_result(rc)
        else:
            if t - (last.get("at") or 0) < env_num("FLEET_NODE_TENANT_EVERY", 300):
                return
            try:
                self.fda_probe = (fda_probe_start(), t, False)
            except (OSError, subprocess.SubprocessError) as e:
                self.log("fda: probe could not start: %s" % e)
                self.state["fda"] = dict(fda_probe_result(None), error=str(e))
                self.dirty = True
            return
        if cur["ok"] is False and last.get("ok") is not False:
            self.log("no Full Disk Access for %s: the hub's account removes will be refused (issue #2973)"
                     % cur["program"])
        self.state["fda"] = cur
        self.dirty = True

    # -- sweep
    def sweep_due(self, t):
        return t - (self.state["sweep"].get("last") or 0) >= env_num("FLEET_NODE_SWEEP_EVERY", 3600)

    def do_sweep(self, dry=False):
        res = sweep(self.p, dry=dry)
        if not dry:
            sw = self.state["sweep"]
            sw.update(last=now(), moved=len(res["moved"]), extra=len(res["extra"]), handwritten=res["handwritten"],
                      clientshell=res["clientshell"], extras=res["extra"], hold=res["hold"],
                      removed=len(res["removed"]),
                      total_removed=(sw.get("total_removed") or 0) + len(res["removed"]),
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
        # `sudo kill -USR1 <pid>`: every thread's Python stack into this log, the
        # loop untouched — what `sample` cannot say: WHICH open() (issue #3084)
        faulthandler.register(signal.SIGUSR1, file=sys.stderr, all_threads=True)
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
        self.state["supervisor"]["boot_id"] = os.environ.get("FLEET_NODE_BOOT_ID", "")
        self.log("supervisor up pid %d (start #%d) on %s" % (os.getpid(), self.state["supervisor"]["starts"],
                                                            self.state["supervisor"]["runtime"] or "?"))
        tick = env_num("FLEET_NODE_TICK", 1)
        # The watchdog (issue #3079): a loop that has not come round in
        # FLEET_NODE_WATCHDOG_SECS (900) dumps every thread's stack to this log and
        # exits, and launchd's KeepAlive starts it again — the children adopted, the
        # tasks marked interrupted. On 2026-10-10 mini2's loop stopped mid-tick for
        # good: every account task (the collector first) stopped with it and nothing
        # said so. 0 = off.
        #
        # Issue #3086 made it say so and come back sooner: every phase of a pass
        # stamps what it is doing (`self.at`), and a watchdog THREAD — it runs while
        # the main thread sits in a system call — ends a pass that has not come round
        # in FLEET_NODE_WATCHDOG_SECS (300; a sweep, which may wait on launchctl, gets
        # FLEET_NODE_WATCHDOG_SWEEP_SECS, 900): one log line naming the phase, every
        # thread's stack, `supervisor.wedged` into state.json for `status`, exit 70.
        # faulthandler stays as the backstop for a main thread that holds the GIL.
        wd = env_num("FLEET_NODE_WATCHDOG_SECS", 300)
        wd_sweep = max(wd, env_num("FLEET_NODE_WATCHDOG_SWEEP_SECS", 900))
        if wd > 0:
            threading.Thread(target=self.watchdog, name="watchdog", daemon=True).start()
        while not self.stop:
            if wd > 0:
                faulthandler.dump_traceback_later(wd_sweep + 60, exit=True, file=sys.stderr)
                self.deadline = now() + wd
            t = now()
            self.at("restart-request")
            if self.restart_requested():
                break
            self.at("children")
            self.tend_children()
            self.at("tasks")
            self.tend_tasks(t)
            self.at("agent-tasks")
            try:
                self.tend_agent_tasks()
            except Exception as e:  # one bad entry must never take the daemon down
                self.log("agent tasks: %s" % e)
            self.at("lanes")
            self.tend_lanes()
            self.at("tenants")
            try:
                self.tend_tenants(t)
            except Exception as e:  # a check must never take the daemon down
                self.log("tenants: %s" % e)
            self.at("fda")
            try:
                self.tend_fda(t)
            except Exception as e:  # a check must never take the daemon down
                self.log("fda: %s" % e)
            self.at("entry")
            try:
                self.tend_entry(t)
            except Exception as e:  # the entry must never take the daemon down
                self.log("entry: %s" % e)
            if self.sweep_due(t):
                self.at("sweep")
                if wd > 0:
                    self.deadline = now() + wd_sweep
                try:
                    self.do_sweep()
                except Exception as e:  # a sweep must never take the daemon down
                    self.log("sweep failed: %s" % e)
            self.at("save")
            self.save()
            self.at("sleep")
            time.sleep(tick)
        self.deadline = None
        faulthandler.cancel_dump_traceback_later()
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

    def at(self, phase):
        self.phase, self.phase_at = phase, now()
        hang = env("FLEET_NODE_TEST_HANG", "") if env("FLEET_NODE_TEST", "") == "1" else ""
        if hang and hang.split(":", 1)[0] == phase and os.path.exists(hang.split(":", 1)[1]):
            # The drills' seam (issue #3086): this phase blocks in an open() that
            # never returns — a FIFO nobody writes — as mini2's TCC.db open did.
            os.close(os.open(hang.split(":", 1)[1], os.O_RDONLY))

    def watchdog(self):
        """The thread that ends a wedged loop (issue #3086); see run()."""
        while True:
            time.sleep(min(5.0, max(0.05, env_num("FLEET_NODE_WATCHDOG_SECS", 300) / 4.0)))
            dl = self.deadline
            if dl is None or now() <= dl:
                continue
            stuck = now() - self.phase_at
            self.log("watchdog: the main loop has not come round — stuck %ds in «%s»; dumping stacks and "
                     "exiting for launchd to restart it (issue #3086)" % (stuck, self.phase))
            faulthandler.dump_traceback(file=sys.stderr, all_threads=True)
            try:
                sv = self.state.get("supervisor") or {}
                w = {"at": now(), "phase": self.phase, "stuck": round(stuck),
                     "count": ((sv.get("wedged") or {}).get("count") or 0) + 1}
                st = read_json(self.p.state_file, {}) or {}
                st.setdefault("supervisor", {})["wedged"] = w
                write_json(self.p.state_file, st)
            except Exception as e:  # the exit below matters more than the record
                self.log("watchdog: could not record it: %s" % e)
            sys.stderr.flush()
            os._exit(70)

    def restart_requested(self):
        """The updater switched `current` (C6, #2334): this process runs the old
        code and its children the old binaries — stop them all and exit; launchd's
        KeepAlive starts the new one from `current`. A request naming the version
        this process already runs is done: removed."""
        if env("FLEET_NODE_UPDATE_OWNER", "hub") == "image":
            return False
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
        self.tend_tenants(t)
        if os.geteuid() == 0 or os.environ.get("FLEET_NODE_TCC_DB"):
            self.state["fda"] = fda_reading()   # bounded: a child, killed past FLEET_NODE_FDA_TIMEOUT
        self.tend_entry(t, force=True)
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
        with os.fdopen(open_ro(path, follow=True), "rb") as f:
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
        with os.fdopen(open_ro(src, follow=True), "rb") as f:
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
# the comment lines the fleet wrote above such a hook (a guest login's header, the
# login-banner line of docs/INSTALL.md) — fleet text, nothing of the person's
SHELL_HEAD_RE = re.compile(r"^#\s*(cfguest:shell\b|claude-fleet login:|banner, then an SSH login)")


def shell_hooks(lines):
    """(keep, gone, err) — THE rule for a ~/.zshrc line that hooks the fleet into a
    login shell (issues #2702, #2991), one for the sweep's count, `status` and
    bin/fleet-node-shell-retire.sh (which runs `shell-hooks`): the old first-login
    block (`# >>> claude-fleet` … `# <<< claude-fleet`, whole), a live line sourcing
    shell/fleet-login.zsh or shell/cw.zsh (a commented-out one is the person's),
    and the fleet's own header comment above one (SHELL_HEAD_RE — kept by an older
    retire, so it may stand alone). The ~/.local/bin PATH line and everything else
    stay. err: a block with no end line (everything from it counted, nothing kept)."""
    keep, gone, inblock = [], [], False
    for ln in lines:
        s = ln.strip()
        if s.startswith("# >>> claude-fleet"):
            inblock = True
        if inblock:
            gone.append(ln)
            if s.startswith("# <<< claude-fleet"):
                inblock = False
            continue
        if (SHELL_HOOK_RE.search(s) and not s.startswith("#")) or SHELL_HEAD_RE.match(s):
            gone.append(ln)
            continue
        keep.append(ln)
    return keep, gone, "a `# >>> claude-fleet` block with no end line" if inblock else ""


def client_shell_of(home):
    """{cache, zshrc} for one home, read now — or None when this process cannot
    read it (never guessed: a home it cannot read is not a clean one)."""
    cache = os.path.join(home, ".cache", "claude-fleet", "shell")
    try:
        os.stat(cache)
        has = os.path.isdir(cache)
    except OSError as ex:
        if ex.errno != errno.ENOENT:
            return None
        has = False
    try:
        with os.fdopen(open_ro(os.path.join(home, ".zshrc"), follow=True), errors="replace") as f:
            hooks = len(shell_hooks(f.read().split("\n"))[1])
    except OSError as ex:
        if ex.errno != errno.ENOENT:
            return None
        hooks = 0
    return {"cache": has, "zshrc": hooks}


def client_shell(paths, logins=None, stale=None, as_of=None):
    """[{login, cache, zshrc}] — every taken-over login whose home still carries
    the person's client (issue #2702): `cache` = ~/.cache/claude-fleet/shell is
    there, `zshrc` = how many ~/.zshrc lines shell_hooks takes out. Read only. A
    home this process cannot read is skipped — or, given `stale` (an earlier
    reading's entries, taken at `as_of`), that reading is kept, marked so (issue
    #2991): `status` re-reads every home it can instead of showing the last sweep's."""
    out = []
    old = dict((c.get("login"), c) for c in stale or [])
    for login in sorted(taken_over(paths) if logins is None else logins):
        r = client_shell_of(os.path.join(paths.users, login))
        if r is None:
            if login in old:
                out.append(dict(old[login], as_of=old[login].get("as_of") or as_of))
            continue
        if r["cache"] or r["zshrc"]:
            out.append(dict(r, login=login))
    return out


def client_shell_says(c, paths):
    """One status / doctor phrase for a client_shell entry."""
    what = []
    if c.get("cache"):
        what.append("~/.cache/claude-fleet/shell")
    if c.get("zshrc"):
        what.append("~/.zshrc %d hook line(s)" % c["zshrc"])
    return "%s: %s — a managed machine is no one's client; sudo bash '%s' --login %s%s%s" % (
        c["login"], " · ".join(what), os.path.join(paths.runtime, "bin", "fleet-node-shell-retire.sh"), c["login"],
        " (the sweep's own run: %s)" % c["retire"] if c.get("retire") else "",
        " (read at %s — this login cannot read that home now)" % iso(c["as_of"]) if c.get("as_of") else "")


# What holds the sweep's removals (issue #2981): a process running one of these
# — a drill run by hand from an admin login must not lose a launchd unit under it.
SWEEP_HOLD_ARGV = ("fleet-onboard-drill.sh",)


def keep_labels(paths):
    """<state>/keep-labels: one label a line (# comments) this machine keeps
    beside expected.json's — the person's word for a unit of their own the
    expected set does not name (issue #2981). Root's file: one a login could
    write is not read."""
    path = os.path.join(paths.state, "keep-labels")
    out = set()
    try:
        st = os.stat(path)
        if st.st_mode & 0o022 or (st.st_uid != 0 and env("FLEET_NODE_TEST", "") != "1"):
            return out
        with open(path, errors="replace") as f:
            for ln in f:
                ln = ln.split("#", 1)[0].strip()
                if ln:
                    out.add(ln)
    except OSError:
        pass
    return out


SHELLS = ("bash", "sh", "zsh", "dash", "ksh")


def runs_script(cmd, name):
    """Is this command line a process RUNNING the script `name` (issue #2991)? Only
    when the program itself is it (argv[0], by base name) or a shell running it as
    its script file (`bash /path/name …`, also behind `env [VAR=x]`). A line that
    merely mentions it — an ssh remote command, `pgrep -f`, `grep`, `bash -c '…'`
    — is not a drill. ps joins argv with spaces, so a path with a space in it
    reads as more words: the script's own path never has one here."""
    words = cmd.split()
    while words and os.path.basename(words[0]) == "env":
        words = words[1:]
        while words and (words[0].startswith("-") or "=" in words[0]):
            words = words[1:]
    if not words:
        return False
    if os.path.basename(words[0]) == name:
        return True
    if os.path.basename(words[0]).lstrip("-") not in SHELLS:
        return False
    for w in words[1:]:
        if w in ("-c", "-s") or (w.startswith("-") and not w.startswith("--") and "c" in w[1:]):
            return False          # an inline command / stdin, not a script file
        if w.startswith("-") or w.startswith("+"):
            continue
        return os.path.basename(w) == name
    return False


def sweep_hold():
    """"" — or what holds the sweep's removals: the first live process RUNNING one
    of SWEEP_HOLD_ARGV (FLEET_NODE_SWEEP_HOLD, comma-separated, overrides) —
    runs_script, never a substring of some other command line (issue #2991)."""
    names = [x for x in env("FLEET_NODE_SWEEP_HOLD", ",".join(SWEEP_HOLD_ARGV)).split(",") if x]
    try:
        out = subprocess.check_output(["ps", "-axo", "pid=,command="], stderr=subprocess.DEVNULL,
                                      universal_newlines=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    for ln in out.splitlines():
        pid, _, cmd = ln.strip().partition(" ")
        if pid == str(os.getpid()):
            continue
        cmd = cmd.strip()
        for n in names:
            if runs_script(cmd, n):
                return "pid %s runs %s" % (pid, cmd[cmd.find(n):][:120])
    return ""
    for ln in out.splitlines():
        pid, _, cmd = ln.strip().partition(" ")
        if pid == str(os.getpid()):
            continue
        for n in names:
            if n in cmd:
                return "pid %s runs %s" % (pid, cmd.strip()[cmd.strip().find(n):][:120])
    return ""


def _runnable_without_legacy(c):
    """Would the daemon run child <c> itself once its old LaunchDaemon is gone?
    "" yes, else why not — never take launchd's copy away before ours can start."""
    if not c.get("cmd"):
        return "no command yet"
    miss = requires_missing(c)
    if miss:
        return "%s missing" % ", ".join(miss)
    if not trusted(script_of(c["cmd"])):
        return "%s is not root-owned / is writable" % script_of(c["cmd"])
    return ""


def _unit_login(paths, d, src, label):
    """The login a fleet unit belongs to, or None (a machine unit): a LaunchAgent
    is its home's; a LaunchDaemon names it in UserName, com.ccquota.agent.<login>
    or com.claude-fleet.<login>.<unit>."""
    if d != paths.daemon_dir:
        return os.path.basename(os.path.dirname(os.path.dirname(d)))
    try:
        with os.fdopen(open_ro(src, follow=True), "rb") as f:
            u = (plistlib.load(f) or {}).get("UserName")
    except Exception:
        u = None
    if isinstance(u, str) and u and u != "root" and not u.startswith("_"):
        return u
    m = re.match(r"^com\.ccquota\.agent\.([A-Za-z0-9._-]+)$", label)
    if m:
        return m.group(1)
    m = re.match(r"^com\.claude-fleet\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+$", label)
    if m and account_ident(m.group(1)) is not None:
        return m.group(1)
    return None


def _extra_verdict(paths, d, src, label, legacy, managed):
    """A fleet unit not in the machine's expected set (issue #2981): (True, why)
    to boot it out into the attic, (False, why) to leave it named, (None, "") when
    it IS expected. The expected set: this daemon, expected.json's labels (the
    caller), and each existing login's own credential proxy
    (com.claude-fleet.credsep.<login> — `fleet-credsep.py machine join` is its
    road; the sweep never cuts a login's credentials)."""
    if d == paths.daemon_dir:
        m = re.match(r"^com\.claude-fleet\.credsep\.(.+)$", label)
        if m:
            if account_ident(m.group(1)) is not None:
                return None, ""
            return True, "the own credential proxy of %s, no such login" % m.group(1)
        if label in legacy:
            why = _runnable_without_legacy(legacy[label])
            if why:
                return False, "launchd still runs child %s: %s" % (legacy[label]["name"], why)
            return True, "child %s runs under %s from now on" % (legacy[label]["name"], LABEL)
    login = _unit_login(paths, d, src, label)
    if login is None:
        return True, "a machine unit %s does not run" % LABEL
    if account_ident(login) is None:
        return True, "no such login %s" % login
    if login in managed:
        return True, "%s is taken over: %s runs its units" % (login, LABEL)
    if tenant_privileges(login)[0]:
        # an admin is never taken over (#2842), so ITS units are the machine's
        # admin node — com.ccquota.agent.<admin> opens every login here, and its
        # fleet's daemons are its own. Never the sweep's (issue #2997: booted out
        # on both machines, the hub had no admin node and opened no newcomer).
        return None, ""
    return False, "%s is not taken over — sudo fleet-node-supervisor.py account adopt %s moves them" % (login, login)


def _attic_id(paths, stamp, index, pending=0):
    """A fresh attic id: <stamp>-<n>, never one the index or the attic holds."""
    taken = set(e.get("id") for e in index)
    n = len(index) + pending + 1
    while "%s-%d" % (stamp, n) in taken or os.path.exists(os.path.join(paths.attic, "%s-%d" % (stamp, n))):
        n += 1
    return "%s-%d" % (stamp, n)


def _retire_unit(paths, d, src, label, index, ident_, dry):
    """Boot one unit out and move it into the attic (7 days, `attic restore`).
    The attic entry, or a string: why it stays."""
    if d == paths.daemon_dir:
        domain = "system"
    else:
        ident = account_ident(os.path.basename(os.path.dirname(os.path.dirname(d))))
        domain = "gui/%d" % ident[0] if ident else None
    e = {"id": ident_, "src": src, "dst": os.path.join(paths.attic, ident_, os.path.basename(src)),
         "label": label, "domain": domain}
    if dry:
        return e
    if domain:
        target = "%s/%s" % (domain, label)
        launchctl("bootout", target)
        if not launchctl_gone(target):
            return "%s did not unload" % target
    st = os.stat(src)
    os.makedirs(os.path.dirname(e["dst"]), 0o700)
    shutil.move(src, e["dst"])
    e.update(moved=now(), uid=st.st_uid, gid=st.st_gid, mode=st.st_mode & 0o7777)
    index.append(e)
    return e


def retire_client_shells(paths, entries):
    """Run the retire script for every taken-over login still carrying the person's
    client (issue #2981) — --if-idle: a client still running is left for the next
    sweep. The entries left, each with the script's last word."""
    script = os.path.join(paths.runtime, "bin", "fleet-node-shell-retire.sh")
    if not entries or not trusted(script):
        return entries
    words = {}
    for c in entries:
        try:
            r = subprocess.run(["/bin/bash", script, "--login", c["login"], "--if-idle"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, universal_newlines=True, timeout=120)
            rc, out = r.returncode, r.stdout
        except (OSError, subprocess.SubprocessError) as ex:
            rc, out = 1, str(ex)
        if rc != 0:
            words[c["login"]] = "retire rc %s: %s" % (rc, (out.strip().splitlines() or ["-"])[-1][:200])
    left = client_shell(paths, [c["login"] for c in entries])
    for c in left:
        if c["login"] in words:
            c["retire"] = words[c["login"]]
    return left


def _sweep(paths, dry=False):
    moved, extra, hand, removed = [], [], [], []
    listed = taken_over(paths)
    expected = read_json(paths.expected, None)
    labels = set(expected.get("labels") or []) if isinstance(expected, dict) else None
    if labels is not None:
        labels |= keep_labels(paths)
    managed = listed | set(k for k, v in accounts_read(paths).items() if (v or {}).get("managed"))
    legacy = dict((c["legacy"], c) for c in load_table(paths).get("children") or [] if c.get("legacy"))
    hold = sweep_hold() if labels is not None else ""
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
                # a managed machine (expected.json): what is not in its expected set
                # goes to the attic, booted out first (issue #2981)
                lb = _plist_label(src) or n[:-len(".plist")]
                if lb in labels or lb == LABEL:
                    continue
                go, why = _extra_verdict(paths, d, src, lb, legacy, managed)
                if go is None:
                    continue
                if go and hold:
                    go, why = False, "held: %s" % hold
                if go:
                    ident = _attic_id(paths, stamp, index, len(moved) + len(removed) if dry else 0)
                    e = _retire_unit(paths, d, src, lb, index, ident, dry)
                    if isinstance(e, dict):
                        removed.append(dict(e, why=why))
                        continue
                    why = e
                extra.append({"path": src, "label": lb, "why": why})
            else:
                h = _handwritten(paths, d, n, src)
                if h and h["login"] in listed:
                    hand.append(h)
    purged = 0 if dry else attic_purge(paths, index)
    if not dry and (moved or removed or purged):
        write_json(paths.attic_index, index, 0o600)
    shells = client_shell(paths, listed)
    if not dry and labels is not None:
        shells = retire_client_shells(paths, shells)
    return {"moved": moved, "extra": extra, "removed": removed, "purged": purged, "handwritten": hand,
            "clientshell": shells, "hold": hold}


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
    «still loaded» (mac-a, issue #2336): poll for FLEET_NODE_BOOTOUT_WAIT seconds."""
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
        fd = open_ro(path)
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
        return (pwd.getpwnam(env("FLEET_CREDSEP_ROLE", "_fleetcred" if MAC else "fleetcred")).pw_uid,)
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
            with os.fdopen(open_ro(path), "rb") as f:
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
            # a login with a credential store leases its accounts from the hub
            # (issue #3276, the Mac half of #3211): node-join's node.env never says
            # so, and without it the node program never runs this tenant's lease —
            # the shared proxy holds the pool, the login holds no account. A value
            # already there (store-only, 0) is the login's, kept
            out.setdefault("CCQUOTA_FLEET_CREDS", "1")
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
    acc = accounts_read(paths)
    for login in logins:
        st = read_json(os.path.join(base, login, "lane.json"), None)
        if isinstance(st, dict) and st.get("state") == "refused" and _lane_login_known(paths, acc, login):
            out[login] = {"why": str(st.get("why") or "")[:400], "since": str(st.get("since") or "")}
    return out


def _lane_login_known(paths, acc, login):
    """A lane counts only for a login still here (issue #3333): an OS login, an
    adopted account or a node-program tenant (logins/<login>.env). A lane.json
    a deleted login left behind is no one's to relogin — ignored."""
    if login in acc or os.path.exists(login_env_path(paths, login)):
        return True
    try:
        pwd.getpwnam(login)
        return True
    except KeyError:
        return False


def _agent_dir_retire(paths, login):
    """Move the node program's <state>/agent/<login>/ (its tenant's cursor,
    spool and lane.json) into the attic as agent-<login>-<UTC> (issue #3333): a
    removed login's refused lane.json used to stay behind for good. → the new
    path, or "" when there was none."""
    src = os.path.join(paths.state, "agent", login)
    if not login or "/" in login or login in (".", "..") or not os.path.isdir(src) or os.path.islink(src):
        return ""
    os.makedirs(paths.attic, mode=0o700, exist_ok=True)
    base = os.path.join(paths.attic, "agent-%s-%s" % (login, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    dst, n = base, 1
    while os.path.exists(dst):
        n += 1
        dst = "%s.%d" % (base, n)
    os.rename(src, dst)
    return dst


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


def logins_creds_backfill(paths, settle=60):
    """Every logins/<login>.env of a login with a credential store that has no
    CCQUOTA_FLEET_CREDS line gets CCQUOTA_FLEET_CREDS=1 (issue #3276): adopted
    before account_agent said so, its node program never leased for it. The other
    lines stay as they were; a file written in the last <settle> s is left for the
    next pass (an adopt may be mid-write). The node agent reloads on the change
    (its `reload` names logins/*.env). → the logins fixed."""
    cbase = env("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred")
    fixed = []
    for login in sorted(taken_over(paths)):
        meta = read_json(os.path.join(cbase, login, "meta.json"), None)
        if not (isinstance(meta, dict) and meta.get("login") == login):
            continue
        path = login_env_path(paths, login)
        try:
            if now() - os.lstat(path).st_mtime < settle:
                continue
        except OSError:
            continue
        kv = _env_file(path, 0)
        if not kv or "CCQUOTA_FLEET_CREDS" in kv or not kv.get("CCQUOTA_TOKEN"):
            continue
        kv["CCQUOTA_FLEET_CREDS"] = "1"
        try:
            write_login_env(paths, login, kv)
        except OSError:
            continue
        fixed.append(login)
    return fixed


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
    why, _full = tenant_privileges(login)
    if why:
        print("fleet-node-supervisor: refusing to adopt %s — %s. A taken-over login is a tenant: no admin, "
              "no sudo (issue #2842); an admin keeps its own services. Take it out of the admin group / "
              "sudoers first, or leave it unmanaged" % (login, "; ".join(why)), file=sys.stderr)
        return 5
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
    """Taken over = its install taken over too (issues #2714, #2774): the
    release's updater links the login's tools and makes its ~/.claude/fleet a
    tree linked to the runtime NOW, in this command — a link tree is built in
    milliseconds; the apply after it (daemons reloaded) is what takes the time.
    A machine with no release yet has nothing to follow."""
    upd = os.path.join(paths.runtime, "bin", "fleet-node-update.py")
    if env("FLEET_NODE_ADOPT_FOLLOW", "1") == "0" or not os.path.exists(upd):
        return
    try:
        r = subprocess.run(["/usr/bin/python3", "-I", upd, "follow", login], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           timeout=env_num("FLEET_NODE_FOLLOW_TIMEOUT", 1200) + 60)
    except (OSError, subprocess.SubprocessError) as e:
        print("  its install follows the release on the next update tick (%s)" % e)
        return
    if r.returncode == 0:
        print("  its ~/.claude/fleet is linked to the release %s (log: %s)"
              % ((runtime_sha(paths) or "?")[:12], os.path.join(paths.log, "update.log")))
    else:
        print("  its install did not move yet (%s) — the next update tick tries again"
              % ((r.stderr or r.stdout).strip().splitlines() or ["rc %d" % r.returncode])[-1][:200])


def release_install(paths, login):
    """Let go = its install its own again (issue #2774): the linked
    ~/.claude/fleet becomes a copy of the same files, a checkout of one
    `fleet-release:` commit, so the login runs and follows on its own."""
    upd = os.path.join(paths.runtime, "bin", "fleet-node-update.py")
    if not os.path.exists(upd):
        return
    try:
        r = subprocess.run(["/usr/bin/python3", "-I", upd, "release-install", login], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=660)
    except (OSError, subprocess.SubprocessError) as e:
        print("  its ~/.claude/fleet still links to the runtime (%s) — by hand: sudo python3 %s release-install %s"
              % (e, upd, login))
        return
    line = ((r.stdout if r.returncode == 0 else (r.stderr or r.stdout)).strip().splitlines() or [""])[-1]
    print("  its ~/.claude/fleet: %s" % (line or "rc %d" % r.returncode))


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
    # a login no longer on this machine has nothing to come back to (#2924): its
    # old services would run for nobody — the agent's plist loaded, exiting 1
    # forever. Only its entry goes.
    if account_ident(login) is None:
        print("fleet-node-supervisor: %s is not a login on this machine — nothing put back, forgetting it"
              % login, file=sys.stderr)
        return account_forget(paths, login, force=force)
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
    # its install its own again before its own services come back on it
    release_install(paths, login)
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


def account_forget(paths, login, force=False):
    """A login on its way OUT (fleet-login-remove.sh, issue #2924): stop running
    as it and forget it — its entry leaves accounts.json, its logins/<login>.env
    goes, the daemon's tasks and children for it stop, and its services stay in
    the attic (no longer kept: the 7-day purge takes them), never loaded again.
    Idempotent: a login this daemon never took over prints so and exits 0."""
    if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
        print("fleet-node-supervisor: account forget stops %s's tasks — run it as root (sudo)" % login,
              file=sys.stderr)
        return 1
    if not force and service_refuse_left(paths, login, "account forget %s" % login):
        return SVC_LEFT_RC
    a = accounts_read(paths)
    had = login in a
    if had:
        del a[login]
        _accounts_write(paths, a)
    gone_env = remove_login_env(paths, login)
    sv = read_json(paths.state_file, {}).get("supervisor") or {}
    if pid_alive(sv.get("pid")):
        end = now() + env_num("FLEET_NODE_RELEASE_WAIT", 20)
        while now() < end and (_account_running(paths, login) or (gone_env and _node_agent_stale(paths))):
            time.sleep(0.2)
        if _account_running(paths, login):
            print("fleet-node-supervisor: %s's tasks still run %ss on — the daemon has not dropped them"
                  % (login, env_num("FLEET_NODE_RELEASE_WAIT", 20)), file=sys.stderr)
            return 1
    agent_dir = _agent_dir_retire(paths, login)
    left = 0
    with attic_lock(paths):
        index = read_json(paths.attic_index, [])
        for e in index:
            if e.get("account") == login and e.get("keep"):
                e.pop("keep", None)
                e["moved"] = now()      # the purge's clock starts at the forget
                left += 1
        if left:
            write_json(paths.attic_index, index, 0o600)
    if agent_dir:
        print("forgot %s: its node-program state moved to %s" % (login, agent_dir))
    if not (had or gone_env or left):
        print("forgot %s: nothing — this daemon never took it over" % login)
        return 0
    print("forgot %s: its tasks stopped, %d service(s) left in the attic (purged in %d days), not loaded"
          % (login, left, env_num("FLEET_NODE_ATTIC_DAYS", 7)))
    return 0


# --------------------------------------------------------------- status ---------
def live_daemons(paths):
    """Pids of this root's daemon main process (`<root>/…/fleet-node-supervisor.py
    run`) that launchd started (ppid 1) — one `ps`. FLEET_NODE_PS_CMD is the
    selftests' seam (a file of `pid ppid command` lines)."""
    seam = os.environ.get("FLEET_NODE_PS_CMD")
    try:
        if seam:
            with open(seam) as f:
                out = f.read()
        else:
            out = subprocess.check_output(["ps", "-axww", "-o", "pid=,ppid=,command="],
                                          stderr=subprocess.DEVNULL, universal_newlines=True)
    except Exception:
        return []
    pids, root = [], os.path.dirname(paths.runtime.rstrip("/")) + "/"
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) == 3 and f[0].isdigit() and f[1] == "1" and root in f[2] \
                and re.search(r"fleet-node-supervisor\.py run(\s|$)", f[2]):
            pids.append(int(f[0]))
    return pids


def installed(paths):
    return os.path.exists(paths.plist) or os.path.exists(paths.state_file)


def health(paths, state):
    """(code, word): 0 ok · 1 installed but not running · 2 not installed ·
    5 WEDGED: the process is alive but its main loop stopped (issue #3086) —
    no task, no sweep, no check runs until the watchdog or a person restarts it."""
    if not installed(paths):
        return 2, "not installed"
    sv = state.get("supervisor") or {}
    stale = env_num("FLEET_NODE_HEARTBEAT_STALE", 120)
    hb = sv.get("heartbeat") or 0
    if not pid_alive(sv.get("pid")):
        # a daemon launchd restarted that never wrote state.json is not DOWN: it
        # is alive and silent (issue #3100 — mini2 read «DOWN» 78 min while
        # pid 28277 ran no task)
        live = [q for q in live_daemons(paths) if q != os.getpid()]
        if live and now() - hb > env_num("FLEET_NODE_HEARTBEAT_STALE", 120):
            return 5, ("WEDGED — pid %s alive but it never wrote a heartbeat (the last, pid %s's, %s ago): "
                       "no task, sweep or check runs (now: sudo launchctl kickstart -k system/%s; "
                       "its stack: sudo kill -USR1 %s, then %s)"
                       % (live[0], sv.get("pid") or "-", ago(hb), LABEL, live[0],
                          os.path.join(paths.log, "supervisor.log")))
        return 1, "DOWN (pid %s gone, heartbeat %s ago)" % (sv.get("pid") or "-", ago(hb))
    if now() - hb > stale:
        return 5, ("WEDGED — pid %s alive but its main loop stopped %s ago: no task, sweep or check runs "
                   "(the watchdog restarts it past FLEET_NODE_WATCHDOG_SECS; now: "
                   "sudo launchctl kickstart -k system/%s, its stack in %s)"
                   % (sv.get("pid"), ago(hb), LABEL, os.path.join(paths.log, "supervisor.log")))
    return 0, "ok"


def wedged_line(state):
    """The last restart the watchdog made, while it is recent (a day), or ""."""
    w = (state.get("supervisor") or {}).get("wedged") or {}
    if not w.get("at") or now() - w["at"] > 86400:
        return ""
    return ("watchdog    restarted it %s ago — the loop was stuck %ss in «%s» (%s time(s); stack in the log)"
            % (ago(w["at"]), w.get("stuck", "?"), w.get("phase", "?"), w.get("count", 1)))


def lanes_now(paths, state):
    """The refused lanes: read fresh where this reader may (root), else the
    daemon's last copy in state.json."""
    return lane_refusals(paths) or state.get("lanes") or {}


def core_line(paths):
    """The root core (#3555), when this machine has one: serving or not, and its
    last alert (more refusals in a minute than it allows). None = no core here —
    the status is what it was."""
    if core is None:
        return None
    unit = os.path.join(paths.daemon_dir, "com.claude-fleet.node-core.plist" if MAC else "fleet-node-core.service")
    alert = read_json(os.path.join(paths.state, "core", "alert.json"), None)
    if not os.path.exists(unit) and not os.path.exists(core.sock_path()) and not isinstance(alert, dict):
        return None
    line = "core        %s · %s" % ("serving" if core.available() else "NOT ANSWERING — every caller takes the old road",
                                    core.sock_path())
    if isinstance(alert, dict):
        line += " · alert %s: %s refusals in a minute (last %s)" % (iso(alert.get("at")), alert.get("count"),
                                                                  alert.get("last"))
    return line


def status_lines(paths, table, state):
    code, word = health(paths, state)
    sv = state.get("supervisor") or {}
    out = ["supervisor  %s · pid %s · up %s · heartbeat %s ago · starts %s"
           % (word, sv.get("pid") or "-", ago(sv.get("started")), ago(sv.get("heartbeat")),
              sv.get("starts") or 0)]
    if wedged_line(state):
        out.append(wedged_line(state))
    if core_line(paths):
        out.append(core_line(paths))
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
    el = entry_line(paths, state)
    if el:
        out.append(el)
    cl = ci_line(paths)
    if cl:
        out.append(cl)
    sw = state.get("sweep") or {}
    for h in sw.get("handwritten") or []:
        out.append("handwritten %-12s runs as %s, not in the register — fleet service|task add, then "
                   "archive %s" % (h.get("label"), h.get("login"), h.get("path")))
    # read now, never the last sweep's word (issue #2991): one retired since reads clean
    for c in client_shell(paths, stale=sw.get("clientshell"), as_of=sw.get("last")):
        out.append("clientshell %-12s %s" % (c.get("login"), client_shell_says(c, paths)))
    for x in sw.get("extras") or []:
        out.append("extra  %-18s left in place — %s (%s)" % (x.get("label"), x.get("why"), x.get("path")))
    out.append("sweep  %-18s last %s · moved %s (total %s) · removed %s (total %s) · extra %s (left in place)%s"
               " · attic %d entries"
               % ("leftovers", iso(sw.get("last")), sw.get("moved", 0), sw.get("total_moved", 0),
                  sw.get("removed", 0), sw.get("total_removed", 0), sw.get("extra", 0),
                  " · held: %s" % sw["hold"] if sw.get("hold") else "", len(read_json(paths.attic_index, []))))
    return code, out


# --------------------------------------------------------------- ci-runner ------
# The machine's one test runner (issue #3144, EPIC #3139 C5): a GitHub Actions
# runner for the merged train only, under its own non-admin login. It is a child
# of this daemon — bin/fleet-ci-runner.py `loop` — only while <state>/ci.env
# (root 0600: a GitHub App's id + key file, or FLEET_CI_TOKEN — credentials that
# never leave the root loop's memory) exists;
# the loop yields to the sessions (memory, admission, load, heavy slots), mints one
# just-in-time runner at a time, and writes its word into <state>/ci-runner.json
# (0644, no secret), which save() copies into state.json's `ci_runner` — the node
# program's heartbeat carries it to the hub (`GET /v1/fleet/ci-runners`).
# No ci.env ⇒ no child, no key, no status line: byte for byte as before.
CI_DEFAULT_LOGIN = "fleet-ci"
CI_BOOK_STALE = 180


def ci_env_path(paths):
    return os.path.join(paths.state, "ci.env")


def ci_book_path(paths):
    return os.path.join(paths.state, "ci-runner.json")


def ci_on(paths):
    return os.path.exists(ci_env_path(paths))


def ci_child(paths):
    """The loop, as a child: started once ci.env exists, stopped when it goes,
    restarted on a new one (a new token, a new repo)."""
    return {"name": "ci-runner",
            "cmd": ["/usr/bin/python3", "-I", os.path.join(paths.runtime, "bin", "fleet-ci-runner.py"), "loop"],
            "requires": [ci_env_path(paths)], "reload": ci_env_path(paths), "note": "#3144"}


def ci_summary(paths):
    """{state, why, at, login, …} — the loop's word for state.json, or None while
    there is no ci.env. A word older than CI_BOOK_STALE is no word: `off`."""
    if not ci_on(paths):
        return None
    book = read_json(ci_book_path(paths), None)
    if not isinstance(book, dict) or now() - (book.get("at") or 0) > CI_BOOK_STALE:
        return {"state": "off", "why": "the loop is not running", "at": now()}
    out = {k: book.get(k) for k in ("state", "why", "at", "since", "login", "runs", "last")
           if book.get(k) is not None}
    out.setdefault("state", "off")
    return out


def ci_line(paths):
    """`ci-runner …` for status, or None when there is no ci.env."""
    s = ci_summary(paths)
    if s is None:
        return None
    runs = s.get("runs") or {}
    last = s.get("last") or {}
    return "ci-runner  %s%s · login %s · runs %d (%d failed) · last %s%s" % (
        s.get("state"), (" — %s" % s["why"]) if s.get("why") else "", s.get("login") or CI_DEFAULT_LOGIN,
        runs.get("total") or 0, runs.get("failed") or 0, iso(last.get("at")),
        (" rc=%s %ss" % (last.get("rc"), last.get("secs"))) if last.get("at") else "")


def ci_login(paths):
    """The test login, while there is a ci.env (the tenants check covers it)."""
    if not ci_on(paths):
        return None
    book = read_json(ci_book_path(paths), {}) or {}
    return book.get("login") or CI_DEFAULT_LOGIN


# --------------------------------------------------------------- entry ----------
# The address's port (issue #3070, EPIC #3067 C3): a SECOND sshd, the one fleet
# service that listens on the public internet on purpose. The system's sshd and
# every ~/.ssh/authorized_keys stay byte for byte: this one is a child of this
# daemon, `sshd -D -e -f <state>/entry/sshd_config`, with its own host key, and it
# reads ONE keys file per login, <state>/entry/keys/<login> (root 0644 in a root
# 0755 directory) — written only here, from the hub's list (`entry pull`, which
# the node program runs on an `entry_keys` push; `entry apply <file>` for a list
# in hand). So a key a session adds for itself opens nothing on it, a key the hub
# revoked is gone at the next pull and the connections it holds are cut (found by
# ExposeAuthInfo), and a keys file someone else rewrote is put back from the last
# good list on the next pass. AllowUsers is the list's logins this daemon took over
# that can do nothing an admin can (#2842) — never an admin; no such login ⇒ no
# config ⇒ no listener. The last list keeps working while the hub is away.
# Off (no FLEET_ENTRY=1 in the environment or machine.env) ⇒ nothing is written,
# nothing listens, status is byte for byte as before.
ENTRY_KEY_TYPES = ("ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                   "ecdsa-sha2-nistp521", "ssh-rsa")
ENTRY_DEFAULT_PORT = 22022
ENTRY_ACCESS_GROUP = "com.apple.access_ssh"


class EntryPaths(object):
    def __init__(self, paths):
        self.dir = os.path.join(paths.state, "entry")
        self.cfg = os.path.join(self.dir, "sshd_config")
        self.hostkey = os.path.join(self.dir, "ssh_host_ed25519_key")
        self.keys = os.path.join(self.dir, "keys")
        self.pid = os.path.join(self.dir, "sshd.pid")
        # 0644 — versions, logins, fingerprints, never a key's text (any doctor reads it)
        self.book = os.path.join(self.dir, "state.json")
        # 0600 — the last good list, what a rewritten keys file is put back from
        self.list = os.path.join(self.dir, "list.json")
        self.lock = os.path.join(self.dir, ".lock")
        self.machine_env = os.path.join(paths.state, "machine.env")
        # the hub's revocation list and the KRL made of it (issue #3560) — 0644,
        # ids and serials, never a key
        self.revs = os.path.join(self.dir, "revocations.json")
        self.krl = os.path.join(self.dir, "revoked.krl")
        self.rev_ca = os.path.join(self.dir, "revocations-ca.pub")


def entry_settings(paths):
    """(on, port, machine.env): FLEET_ENTRY / FLEET_ENTRY_PORT from the daemon's
    environment, else machine.env (what `fleet node install` writes — launchd hands
    the daemon no environment)."""
    me = _env_file(os.path.join(paths.state, "machine.env"), 0) or {}
    on = (os.environ.get("FLEET_ENTRY") or me.get("FLEET_ENTRY") or "") == "1"
    port = os.environ.get("FLEET_ENTRY_PORT") or me.get("FLEET_ENTRY_PORT") or ""
    port = int(port) if port.isdigit() and 0 < int(port) < 65536 else ENTRY_DEFAULT_PORT
    return on, port, me


def entry_sshd():
    return env("FLEET_ENTRY_SSHD", "/usr/sbin/sshd")


def entry_child(paths):
    """The listener, as a child: started once its config exists, stopped when the
    config goes (no login has its home here), and told SIGHUP — sshd re-execs on
    the new file, its live connections untouched — whenever the config changes."""
    ep = EntryPaths(paths)
    return {"name": "entry", "cmd": [entry_sshd(), "-D", "-e", "-f", ep.cfg],
            "requires": [ep.cfg], "reload": ep.cfg, "reload_signal": "HUP",
            "note": "#3070"}


def _entry_put(path, text, mode):
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".%s.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.rename(tmp, path)


def _entry_read(path):
    try:
        with open(path) as f:
            return f.read()
    except (IOError, OSError):
        return None


def _entry_root_dir(d, mode):
    if not os.path.isdir(d):
        os.makedirs(d)
    if os.geteuid() == 0:
        st = os.lstat(d)
        if st.st_uid != 0 or st.st_gid != 0:
            os.chown(d, 0, 0)
    if os.stat(d).st_mode & 0o7777 != mode:
        os.chmod(d, mode)


def entry_key_line(k):
    """One key of the hub's list as its keys-file line `<type> <b64> fleet:<fp>`,
    or None when it is not a plain public key of a kind the entry takes. A plain
    line — no `restrict`, no `command=` (共同约定 3): the phone's key and the
    computer's open the same login."""
    if not isinstance(k, dict):
        return None
    t, b, fp = str(k.get("type") or ""), str(k.get("b64") or ""), str(k.get("fp") or "")
    if t not in ENTRY_KEY_TYPES or not re.match(r"^[A-Za-z0-9+/]{16,16384}={0,2}$", b) \
            or not re.match(r"^[A-Za-z0-9+/=:_.-]{1,128}$", fp):
        return None
    try:
        import base64
        raw = base64.b64decode(b)
        n = int.from_bytes(raw[:4], "big")
        if raw[4:4 + n].decode("ascii") != t:
            return None
    except Exception:
        return None
    return "%s %s fleet:%s\n" % (t, b, fp)


def entry_eligible(paths, logins):
    """{login: None (on the entry) | why not}. Only a login this daemon took over,
    that exists, and that holds nothing only an admin may (#2842) — never root,
    never an admin, whatever the list says."""
    tenants = set(tenant_logins(paths))
    out = {}
    for login in logins:
        if login == "root" or not re.match(r"^[A-Za-z0-9._-]{1,64}$", login):
            out[login] = "not a login the entry takes"
        elif login not in tenants:
            out[login] = "not taken over by this machine's daemon (account adopt)"
        elif account_ident(login) is None:
            out[login] = "no such login here"
        else:
            bad = tenant_privileges(login)[0]
            out[login] = ("an admin login never goes on the entry (%s)" % "; ".join(bad)) if bad else None
    return out


ENTRY_SFTP_SERVERS = ("/usr/libexec/sftp-server", "/usr/lib/openssh/sftp-server",
                      "/usr/libexec/openssh/sftp-server", "/usr/lib/ssh/sftp-server")


def entry_dispatch(paths):
    """The ForceCommand (issue #3071, 共同约定 4): the runtime's bin/fleet-entry.sh
    through the `current` link, so a release switch moves it — only once the
    runtime carries it (before that: a plain login, as #3070 shipped)."""
    script = os.path.join(paths.runtime, "bin", "fleet-entry.sh")
    return script if os.path.isfile(script) else None


def entry_config(ep, port, allow, paths=None):
    """共同约定 2, line for line — and 4: the ForceCommand that dispatches (a
    command runs as on port 22; none on a terminal is the 看台) — and C9's
    forwarding to this machine only (issue #3075)."""
    import shlex
    disp = entry_dispatch(paths) if paths is not None else None
    sftp = next((s for s in ENTRY_SFTP_SERVERS if os.access(s, os.X_OK)), None)
    extra = []
    if disp:
        # the book (0644) names each key the hub registered — the 看台's device; the
        # drill's seam (FLEET_NODE_TEST only) adds its 看台 stand-in and conf dir.
        # ONE SetEnv line: sshd keeps only the first.
        more = env("FLEET_ENTRY_TEST_SETENV", "") if env("FLEET_NODE_TEST", "") == "1" else ""
        extra += ["ForceCommand /bin/bash %s" % shlex.quote(disp),
                  "SetEnv FLEET_ENTRY_BOOK=%s%s" % (ep.book, (" " + more) if more else "")]
    return "".join(l + "\n" for l in [
        "# claude-fleet entry port (issue #3070) — written by fleet-node-supervisor.py; every",
        "# change passes `sshd -t` first. The system's sshd and ~/.ssh/authorized_keys are not read.",
        "Port %d" % port,
        "HostKey %s" % ep.hostkey,
        "PidFile %s" % ep.pid,
        "AllowUsers %s" % " ".join(sorted(allow)),
        "AuthenticationMethods publickey",
        "PubkeyAuthentication yes",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "PermitRootLogin no",
        "AuthorizedKeysFile %s/%%u" % ep.keys,
        "AuthorizedPrincipalsFile none",
        "TrustedUserCAKeys none",
    ] + (
        # the hub's revocation list as a KRL (issue #3560): sshd reads it on every
        # authentication, so a new list needs no restart. Only once it exists — a
        # RevokedKeys file sshd cannot read refuses every key.
        ["RevokedKeys %s" % ep.krl] if os.path.isfile(ep.krl) else []
    ) + [
        "HostbasedAuthentication no",
        "StrictModes yes",
        "UsePAM no",
        "PermitUserRC no",
        "PermitUserEnvironment no",
        "ExposeAuthInfo yes",
        # the client's own locale, as the system sshd takes it (issue #3196): without
        # it a phone arrives in the C locale and the 看台's tmux draws Chinese as `_`
        "AcceptEnv LANG LC_*",
        # forwarding only to THIS machine (issue #3075): `fleet open`'s -L and the thin
        # client pass; another address, -R, a unix socket, the agent, X11, a tunnel do not
        "AllowTcpForwarding local",
        "PermitOpen localhost:* 127.0.0.1:* [::1]:*",
        "AllowStreamLocalForwarding no",
        "AllowAgentForwarding no",
        "X11Forwarding no",
        "PermitTunnel no",
        "GatewayPorts no",
        "MaxAuthTries 3",
        "LoginGraceTime 20",
        "MaxStartups 10:30:60",
        "LogLevel VERBOSE",
        # under a ForceCommand sftp arrives as SSH_ORIGINAL_COMMAND: a real server
        # the login's shell can run (internal-sftp is sshd's own — fleet-entry.sh finds one)
        "Subsystem sftp %s" % (sftp if disp and sftp else "internal-sftp"),
    ] + extra)


def _entry_sshd_check(text, ep):
    """(ok, why, missing): `sshd -t` on <text>, then `sshd -T` must show
    PerSourcePenalties (OpenSSH ≥ 9.8) — an older sshd is not started at all."""
    tmp = os.path.join(ep.dir, ".sshd_config.check.%d" % os.getpid())
    try:
        _entry_put(tmp, text, 0o644)
        r = subprocess.run([entry_sshd(), "-t", "-f", tmp], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True, timeout=30)
        if r.returncode != 0:
            return False, "sshd -t: %s" % (r.stdout.strip().splitlines() or ["rc=%d" % r.returncode])[-1], []
        r = subprocess.run([entry_sshd(), "-T", "-f", tmp, "-C", "user=nobody,host=localhost,addr=127.0.0.1"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=30)
        eff = dict((l.split(None, 1) + [""])[:2] for l in r.stdout.splitlines() if l.strip())
        missing = []
        if eff.get("persourcepenalties", "no").strip() in ("", "no"):
            missing.append("PerSourcePenalties (OpenSSH 9.8+)")
        for k, want in (("passwordauthentication", "no"), ("kbdinteractiveauthentication", "no"),
                        ("permitrootlogin", "no"), ("authenticationmethods", "publickey")):
            if r.returncode == 0 and eff.get(k, "").strip() != want:
                return False, "sshd -T: %s is %r, not %s" % (k, eff.get(k), want), []
        if r.returncode != 0:
            return False, "sshd -T: %s" % (r.stdout.strip().splitlines() or ["rc=%d" % r.returncode])[-1], []
        return not missing, "", missing
    except (OSError, subprocess.SubprocessError) as e:
        return False, "sshd: %s" % e, []
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _entry_hostkey(ep):
    if os.path.exists(ep.hostkey) and os.path.exists(ep.hostkey + ".pub"):
        return ""
    for f in (ep.hostkey, ep.hostkey + ".pub"):
        try:
            os.remove(f)
        except OSError:
            pass
    r = subprocess.run([env("FLEET_ENTRY_KEYGEN", "/usr/bin/ssh-keygen"), "-q", "-t", "ed25519", "-N", "",
                        "-C", "fleet-entry", "-f", ep.hostkey],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=60)
    return "" if r.returncode == 0 else "ssh-keygen: %s" % r.stdout.strip()


def _entry_b64s(text):
    out = set()
    for line in (text or "").splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] in ENTRY_KEY_TYPES:
            out.add(f[1])
    return out


def _entry_procs():
    """{pid: (ppid, command)} — one `ps`."""
    try:
        out = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], stderr=subprocess.DEVNULL,
                                      universal_newlines=True)
    except Exception:
        return {}
    procs = {}
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) >= 2 and f[0].isdigit() and f[1].isdigit():
            procs[int(f[0])] = (int(f[1]), f[2] if len(f) > 2 else "")
    return procs


def _entry_auth_file(pid):
    """The $SSH_USER_AUTH a process carries (ExposeAuthInfo), or None."""
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(b"SSH_USER_AUTH="):
                    return kv[len(b"SSH_USER_AUTH="):].decode("utf-8", "replace")
        return None
    except (IOError, OSError):
        pass
    try:
        out = subprocess.check_output(["ps", "-wwE", "-o", "command=", "-p", str(pid)],
                                      stderr=subprocess.DEVNULL, universal_newlines=True)
    except Exception:
        return None
    m = re.search(r"(?:^|\s)SSH_USER_AUTH=(\S+)", out)
    return m.group(1) if m else None


def _entry_fp(b64):
    import base64
    import hashlib
    try:
        return "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(b64)).digest()).decode().rstrip("=")
    except Exception:
        return ""


def _entry_logged(logdir, fps):
    """{(addr, port): fp} for every login the entry sshd logged (LogLevel VERBOSE:
    `Accepted publickey for <login> from <addr> port <port> ssh2: <TYPE> <fp>`)
    with one of <fps> — its log is this daemon's child log, entry.log."""
    out = {}
    pat = re.compile(r"Accepted publickey for \S+ from (\S+) port (\d+) ssh2: \S+ (SHA256:\S+)")
    for f in (os.path.join(logdir, "entry.log.1"), os.path.join(logdir, "entry.log")):
        for line in (_entry_read(f) or "").splitlines():
            m = pat.search(line)
            if m and m.group(3) in fps:
                out[(m.group(1), m.group(2))] = m.group(3)
    return out


def _entry_peers(pid):
    """The (addr, port) peers of <pid>'s established TCP sockets (lsof), or set()."""
    try:
        lsof = env("FLEET_ENTRY_LSOF", "/usr/sbin/lsof" if os.path.exists("/usr/sbin/lsof") else "/usr/bin/lsof")
        out = subprocess.check_output([lsof, "-nP", "-a", "-p", str(pid),
                                       "-iTCP", "-sTCP:ESTABLISHED", "-Fn"],
                                      stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
    except Exception:
        return set()
    peers = set()
    for line in out.splitlines():
        if line.startswith("n") and "->" in line:
            addr, _, port = line.split("->", 1)[1].rpartition(":")
            peers.add((addr.strip("[]"), port))
    return peers


def entry_cut(ep, b64s, logdir=None):
    """Close every live entry connection that logged in with one of <b64s> — its
    per-connection sshd under the listener, found by the key in the file
    $SSH_USER_AUTH names (ExposeAuthInfo; /proc on Linux), else — macOS shows no
    process's environment — by its peer port in the listener's own log line for
    that key's fingerprint. The tmux session it watched stays."""
    if not b64s:
        return []
    fps = set(f for f in (_entry_fp(b) for b in b64s) if f)
    logged = _entry_logged(logdir, fps) if logdir else {}
    procs = _entry_procs()
    mark = "-f " + ep.cfg
    listeners = [p for p, (pp, cmd) in procs.items()
                 if mark in cmd and not (pp in procs and mark in procs[pp][1])]
    kids = {}
    for p, (pp, _c) in procs.items():
        kids.setdefault(pp, []).append(p)
    cut = []
    for lst in listeners:
        for conn in kids.get(lst, []):
            todo, seen, hit = [conn], set(), False
            while todo and not hit:
                q = todo.pop()
                if q in seen:
                    continue
                seen.add(q)
                af = _entry_auth_file(q)
                if af:
                    used = _entry_b64s("\n".join(l.split(None, 1)[1] if " " in l else l
                                                  for l in (_entry_read(af) or "").splitlines()))
                    hit = bool(used & b64s)
                todo.extend(kids.get(q, []))
            if not hit and logged:
                hit = bool(_entry_peers(conn) & set(logged))
            if hit:
                try:
                    os.kill(conn, signal.SIGTERM)
                    cut.append(conn)
                except OSError:
                    pass
    return cut


def _entry_dsedit(*args):
    tool = env("FLEET_ENTRY_DSEDITGROUP", "/usr/sbin/dseditgroup" if sys.platform == "darwin" else "")
    if not tool:
        return None
    try:
        return subprocess.run([tool] + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              universal_newlines=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None


def entry_access_ssh(allow, added):
    """macOS «allow access for: only these users» (com.apple.access_ssh) shuts any
    sshd to a login outside the group: while the group exists, each entry login
    joins it — only added, and booked, so only the ones the entry added leave it
    when they leave the entry. Returns the new book."""
    added = set(added or [])
    r = _entry_dsedit("-o", "read", ENTRY_ACCESS_GROUP)
    if r is None or r.returncode != 0:
        return sorted(added & set(allow)) if r is None else []
    for login in sorted(set(allow) - added):
        c = _entry_dsedit("-o", "checkmember", "-m", login, ENTRY_ACCESS_GROUP)
        if c is not None and c.returncode == 0:
            continue                       # a member already — the person's, not ours
        e = _entry_dsedit("-o", "edit", "-a", login, "-t", "user", ENTRY_ACCESS_GROUP)
        if e is not None and e.returncode == 0:
            added.add(login)
    for login in sorted(added - set(allow)):
        e = _entry_dsedit("-o", "edit", "-d", login, "-t", "user", ENTRY_ACCESS_GROUP)
        if e is not None and e.returncode == 0:
            added.discard(login)
    return sorted(added)


def entry_converge(paths, lst=None, force=False):
    """One pass: dirs + host key, the keys files from <lst> (else the last good
    list) — a file someone else rewrote is put back —, AllowUsers, the config
    through `sshd -t`, com.apple.access_ssh, and the cut of every connection a
    removed key holds. Writes the book; returns it. Off ⇒ nothing (None)."""
    on, port, _me = entry_settings(paths)
    if not on:
        return None
    ep = EntryPaths(paths)
    if not os.path.isdir(paths.state):
        _entry_root_dir(paths.state, 0o755)
    _entry_root_dir(ep.dir, 0o755)
    _entry_root_dir(ep.keys, 0o755)
    lk = os.open(ep.lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lk, fcntl.LOCK_EX)
        return _entry_converge(paths, ep, port, lst, force)
    finally:
        os.close(lk)


def _entry_converge(paths, ep, port, lst, force):
    book = read_json(ep.book, {}) or {}
    t = now()
    book.update(on=True, port=port, checked_at=t)
    given = lst is not None
    if given:
        if not isinstance(lst, dict) or not isinstance(lst.get("logins"), dict) \
                or not isinstance(lst.get("version"), int):
            book["error"] = "the list is not {version, logins:{…}} — kept the last one"
            write_json(ep.book, book)
            return book
        if lst["version"] < (book.get("version") or 0) and not force:
            book["error"] = "list v%d is older than v%d held here — kept" % (lst["version"], book.get("version") or 0)
            write_json(ep.book, book)
            return book
        _entry_put(ep.list, json.dumps(lst, sort_keys=True), 0o600)
        book["applied_at"] = t
    else:
        lst = read_json(ep.list, None)
        if not isinstance(lst, dict) or not isinstance(lst.get("logins"), dict):
            lst = {"version": 0, "logins": {}}
    book["error"] = ""
    why = _entry_hostkey(ep)
    if why:
        book["error"] = why
        write_json(ep.book, book)
        return book
    verdict = entry_eligible(paths, sorted(lst["logins"]))
    want, logins_book, skipped = {}, {}, 0
    for login in sorted(lst["logins"]):
        ent = lst["logins"][login] if isinstance(lst["logins"][login], dict) else {}
        if verdict.get(login):
            continue
        lines, fps, names = [], [], {}
        for k in ent.get("keys") or []:
            line = entry_key_line(k)
            if line is None:
                skipped += 1
                continue
            if line not in lines:
                lines.append(line)
                fps.append(str(k.get("fp")))
                # the person's label for it (the 看台's device, #3071) — never a key's text
                nm = re.sub(r"[\x00-\x1f\x7f]", "", str(k.get("name") or ""))[:64].strip()
                if nm:
                    names[str(k.get("fp"))] = nm
        if not lines:
            continue
        want[login] = "".join(lines)
        logins_book[login] = {"person": str(ent.get("person") or ""), "fps": fps, "keys": len(lines)}
        if names:
            logins_book[login]["names"] = names
    # the keys files: exactly <want>, each root 0644; what was there and is not
    # wanted any more is a removed key — its connections are cut below
    removed, healed = set(), []
    try:
        present = [n for n in os.listdir(ep.keys) if not n.startswith(".")]
    except OSError:
        present = []
    for n in present:
        p = os.path.join(ep.keys, n)
        old = _entry_read(p)
        if n not in want:
            removed |= _entry_b64s(old)
            try:
                os.remove(p) if not os.path.isdir(p) or os.path.islink(p) else shutil.rmtree(p)
            except OSError:
                pass
            continue
        st = os.lstat(p)
        bad_owner = os.geteuid() == 0 and (st.st_uid != 0 or st.st_gid != 0)
        if old != want[n] or os.path.islink(p) or bad_owner or st.st_mode & 0o7777 != 0o644:
            removed |= _entry_b64s(old) - _entry_b64s(want[n])
            if not given and old is not None:
                healed.append(n)
    for login, text in sorted(want.items()):
        p = os.path.join(ep.keys, login)
        st = None
        try:
            st = os.lstat(p)
        except OSError:
            pass
        if st is None or _entry_read(p) != text or os.path.islink(p) or st.st_mode & 0o7777 != 0o644 \
                or (os.geteuid() == 0 and (st.st_uid != 0 or st.st_gid != 0)):
            if st is not None and os.path.islink(p):
                os.remove(p)
            _entry_put(p, text, 0o644)
    allow = sorted(want)
    # the config: none (no listener) when no login has its home here
    book["missing"], book["refused"] = [], dict((l, w) for l, w in verdict.items() if w)
    if not allow:
        for f in (ep.cfg,):
            try:
                os.remove(f)
            except OSError:
                pass
    else:
        text = entry_config(ep, port, allow, paths)
        if _entry_read(ep.cfg) != text:
            ok, why, missing = _entry_sshd_check(text, ep)
            book["missing"] = missing
            if ok:
                _entry_put(ep.cfg, text, 0o644)
            elif missing:
                # an sshd without per-source penalties is not put on the internet
                try:
                    os.remove(ep.cfg)
                except OSError:
                    pass
                book["error"] = "not started — this sshd lacks %s" % ", ".join(missing)
            else:
                book["error"] = "%s — the config before it stays" % why
    book["access_ssh"] = entry_access_ssh(allow if os.path.exists(ep.cfg) else [], book.get("access_ssh"))
    cut = entry_cut(ep, removed, paths.log)
    if given:
        book["version"] = lst.get("version", 0)
    book.update(logins=logins_book, allow=allow if os.path.exists(ep.cfg) else [], skipped=skipped)
    if healed:
        book["healed"] = {"at": t, "logins": healed}
    if cut:
        book["cut"] = {"at": t, "pids": cut}
    write_json(ep.book, book)
    return book


# The door's revocation list (issue #3560, EPIC #3500 C18, 共同约定 11): the hub
# pushes every revocation it records onto one versioned list —
# GET /v1/node/revocations?since=<v>&wait=25 with the machine's token, answered
# the moment the list moves — and the door keeps it locally: the list in
# <state>/entry/revocations.json, its connection-certificate serials as an
# OpenSSH KRL, <state>/entry/revoked.krl, which the entry sshd loads with
# RevokedKeys and reads on every authentication. So a certificate revoked on the
# hub stops at the door within seconds, and the hub away, the last list still
# refuses. The follower is a thread of the daemon (`Supervisor.follow_revocations`);
# `entry revocations pull | apply <file> | status` by hand. A hub with the list
# off (404) or an entry that is off ⇒ nothing is written, the config byte for
# byte as before.
def entry_keygen():
    return env("FLEET_ENTRY_SSH_KEYGEN", "/usr/bin/ssh-keygen")


def revocations_apply(paths, lst, fetched_at=None):
    """(ok, why): the list's certificate serials written as the KRL (one rename),
    then the list itself. A list that names certificates but no CA is refused,
    the last KRL kept."""
    if not isinstance(lst, dict) or not isinstance(lst.get("v"), int) or not isinstance(lst.get("entries"), list):
        return False, "not a revocation list"
    ep = EntryPaths(paths)
    _entry_root_dir(ep.dir, 0o755)
    t = time.time()
    serials = sorted(set(int(str(e["jti"])[4:]) for e in lst["entries"]
                         if isinstance(e, dict) and str(e.get("jti") or "").startswith("ssh:")
                         and str(e["jti"])[4:].isdigit() and isinstance(e.get("exp"), int) and e["exp"] > t))
    ca = str(lst.get("ssh_ca") or "").strip()
    if serials and not ca:
        return False, "the list names %d certificate(s) but no ssh_ca" % len(serials)
    spec = os.path.join(ep.dir, ".krl-spec.%d" % os.getpid())
    tmp = os.path.join(ep.dir, ".revoked.krl.%d" % os.getpid())
    cmd = [entry_keygen(), "-k", "-f", tmp]
    try:
        _entry_put(spec, "".join("serial: %d\n" % n for n in serials), 0o600)
        if serials:
            _entry_put(ep.rev_ca, ca + "\n", 0o644)
            cmd += ["-s", ep.rev_ca]
        r = subprocess.run(cmd + [spec], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=30)
        if r.returncode != 0 or not os.path.isfile(tmp):
            return False, "ssh-keygen -k: %s" % ((r.stdout.strip().splitlines() or ["rc=%d" % r.returncode])[-1])
        os.chmod(tmp, 0o644)
        os.rename(tmp, ep.krl)
    except (OSError, subprocess.SubprocessError) as e:
        return False, "the KRL: %s" % e
    finally:
        for f in (spec, tmp):
            try:
                os.unlink(f)
            except OSError:
                pass
    write_json(ep.revs, {"v": lst["v"], "at": lst.get("at"), "fetched_at": fetched_at or t,
                         "serials": len(serials), "entries": lst["entries"]})
    return True, ""


def revocations_pull(paths, since=None, wait=0):
    """One ask of the hub's list: (code, why) — 0 applied · 1 the hub did not
    answer / the list did not apply (the last one stands) · 2 unchanged (304) ·
    3 off (the entry, or the hub's list)."""
    on, _port, me = entry_settings(paths)
    if not on:
        return 3, "entry off"
    hub, token = (me.get("CCQUOTA_HUB_URL") or "").rstrip("/"), me.get("CCQUOTA_TOKEN") or ""
    if not hub or not token:
        return 1, "machine.env names no hub or no token"
    from urllib.request import Request, urlopen
    q = "?since=%d&wait=%d" % (since, wait) if since is not None else ""
    try:
        req = Request(hub + "/v1/node/revocations" + q, headers={"Authorization": "Bearer " + token,
                                                                  "Accept": "application/json"})
        with urlopen(req, timeout=wait + env_num("FLEET_ENTRY_PULL_SECS", 10)) as r:
            if r.status == 304:
                return 2, ""
            lst = json.loads(r.read().decode("utf-8"))
    except Exception as e:  # urllib raises many kinds; the reason is all we keep
        code = getattr(e, "code", None)
        if code == 304:
            ep = EntryPaths(paths)
            b = read_json(ep.revs, None)
            if b is not None:
                b["fetched_at"] = time.time()
                write_json(ep.revs, b)
            return 2, ""
        if code == 404:
            return 3, "the hub's list is off"
        return 1, "the hub: %s" % (code or getattr(e, "reason", None) or e)
    ok, why = revocations_apply(paths, lst)
    return (0, "") if ok else (1, why)


def revocations_follow(paths, say, stopped, until=None):
    """Ask the hub with the version held, held up to FLEET_ENTRY_REV_WAIT (25 s),
    apply what moved, repeat — reconnecting within FLEET_ENTRY_REV_BACKOFF (5 s)
    so a hub that comes back is heard well inside the 10-second promise. Entry
    off or the hub's list off ⇒ ask again in FLEET_ENTRY_REV_IDLE, write nothing."""
    back, said = 1.0, None
    ep = EntryPaths(paths)
    while not stopped() and (until is None or time.time() < until):
        b = read_json(ep.revs, None) or {}
        code, why = revocations_pull(paths, b.get("v") if isinstance(b.get("v"), int) else None,
                                     int(env_num("FLEET_ENTRY_REV_WAIT", 25)))
        if code == 0:
            nb = read_json(ep.revs, None) or {}
            say("entry: revocation list v%s · %s certificate(s) in the KRL" % (nb.get("v"), nb.get("serials")))
        if code == 1 and why != said:
            say("entry: revocation list: %s — the last list stands" % why)
        said = why if code == 1 else None
        if code == 3:
            time.sleep(env_num("FLEET_ENTRY_REV_IDLE", 300))
        elif code == 1:
            time.sleep(back)
            back = min(back * 2, env_num("FLEET_ENTRY_REV_BACKOFF", 5))
        else:
            back = 1.0


def revocations_cli(paths, rest):
    sub = rest[0] if rest else "status"
    ep = EntryPaths(paths)
    if sub == "pull":
        b = read_json(ep.revs, None) or {}
        code, why = revocations_pull(paths, b.get("v") if "--since" in rest else None)
        b = read_json(ep.revs, None) or {}
        print("revocations v%s · %s certificate(s) in the KRL%s" % (b.get("v", "-"), b.get("serials", 0),
                                                                     " · " + why if why else ""))
        return 0 if code in (0, 2) else code
    if sub == "follow":
        secs = None
        if "--max-seconds" in rest:
            secs = float(rest[rest.index("--max-seconds") + 1])
        say = lambda m: (sys.stderr.write("%s %s\n" % (iso(now()), m)), sys.stderr.flush())
        revocations_follow(paths, say, lambda: False, time.time() + secs if secs else None)
        return 0
    if sub == "apply" and len(rest) > 1:
        try:
            lst = json.load(sys.stdin) if rest[1] == "-" else read_json(rest[1], None)
        except ValueError:
            lst = None
        ok, why = revocations_apply(paths, lst)
        if not ok:
            print("revocations apply: %s" % why, file=sys.stderr)
            return 1
        b = read_json(ep.revs, {})
        print("revocations v%s · %s certificate(s) in the KRL" % (b.get("v"), b.get("serials")))
        return 0
    if sub == "status":
        b = read_json(ep.revs, None)
        if b is None:
            print("no revocation list here")
            return 3
        age = time.time() - float(b.get("fetched_at") or 0)
        print("revocations v%s · %s certificate(s) in the KRL · fetched %ds ago%s" % (
            b.get("v"), b.get("serials"), age, " (stale)" if age > env_num("FLEET_ENTRY_REV_STALE", 600) else ""))
        return 1 if age > env_num("FLEET_ENTRY_REV_STALE", 600) else 0
    print("usage: entry revocations pull [--since] | follow [--max-seconds N] | apply <file|-> | status",
          file=sys.stderr)
    return 2


def entry_pull(paths, version=None):
    """The hub's list for this machine: GET /v1/node/entry-keys with the
    machine's token (machine.env), applied. 0 applied · 1 the hub did not answer
    (the last list stands) · 3 entry off."""
    on, _port, me = entry_settings(paths)
    if not on:
        print("entry off (FLEET_ENTRY=1 in machine.env turns it on)")
        return 3
    ep = EntryPaths(paths)
    _entry_root_dir(ep.dir, 0o755)
    book = read_json(ep.book, {}) or {}
    if version:
        book["hub_version"] = version
        book["hub_version_at"] = now()
    hub, token = (me.get("CCQUOTA_HUB_URL") or "").rstrip("/"), me.get("CCQUOTA_TOKEN") or ""
    err, lst = "", None
    if not hub or not token:
        err = "machine.env names no hub or no token"
    else:
        from urllib.request import Request, urlopen
        try:
            req = Request(hub + "/v1/node/entry-keys", headers={"Authorization": "Bearer " + token,
                                                                 "Accept": "application/json"})
            with urlopen(req, timeout=env_num("FLEET_ENTRY_PULL_SECS", 10)) as r:
                lst = json.loads(r.read().decode("utf-8"))
        except Exception as e:  # urllib raises many kinds; the reason is all we keep
            err = "the hub: %s" % (getattr(e, "code", None) or getattr(e, "reason", None) or e)
    book.update(pull_error=err, pulled_at=now() if not err else book.get("pulled_at"),
                pull_tried_at=now())
    write_json(ep.book, book)
    if err:
        print("entry pull: %s — the last list (v%s) stands" % (err, book.get("version") or 0), file=sys.stderr)
        return 1
    b = entry_converge(paths, lst)
    print("entry v%s · %d login(s) on the port%s" % (b.get("version"), len(b.get("allow") or []),
                                                     " · " + b["error"] if b.get("error") else ""))
    return 0 if not b.get("error") else 1


# The door's record (issue #3071, 共同约定 11): every arrival the listener logs
# (LogLevel VERBOSE: accepted, a key refused, a login not on it) is ONE line of
# <log>/entry.ndjson — time · person · login · key fp · machine · source IP ·
# result, never a key's text — read off its own child log, entry.log, so nothing a
# login runs can write or skip it. Each line also queues for the hub
# (POST /v1/node/entry-audit, its own id, so a resend is harmless) in
# <state>/entry/audit-pending.ndjson; the hub away, they wait for the next pass.
ENTRY_AUDIT_PATS = (
    (re.compile(r"Accepted publickey for (\S+) from (\S+) port \d+ ssh2: \S+ (SHA256:\S+)"), "ok"),
    (re.compile(r"Failed publickey for (?:invalid user )?(\S+) from (\S+) port \d+ ssh2: \S+ (SHA256:\S+)"),
     "denied: key"),
    (re.compile(r"Invalid user (\S*) from (\S+) port \d+"), "denied: no such login"),
    (re.compile(r"User (\S+) from (\S+) not allowed because"), "denied: not on the entry"),
)
ENTRY_AUDIT_KEEP = 5000


def entry_audit_lines(text, book, host, base, at):
    """[(id, line dict)] of <text> (the log from byte <base> on)."""
    out, off = [], base
    logins = (book or {}).get("logins") or {}
    for raw in text.splitlines(True):
        here, off = off, off + len(raw.encode("utf-8", "replace"))
        for pat, result in ENTRY_AUDIT_PATS:
            m = pat.search(raw)
            if not m:
                continue
            login, ip = m.group(1), m.group(2)
            fp = m.group(3) if pat.groups >= 3 else ""
            out.append({"id": "%d" % here, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)),
                        "kind": "enter", "person": str((logins.get(login) or {}).get("person") or ""),
                        "login": login[:64], "fp": fp[:120], "machine": host, "source_ip": ip[:64],
                        "result": result})
            break
    return out


def entry_audit(paths):
    """One pass over what the listener logged since the last: <log>/entry.ndjson
    and the hub's queue. Returns how many lines were new."""
    ep = EntryPaths(paths)
    mark = os.path.join(ep.dir, "audit.json")
    pend = os.path.join(ep.dir, "audit-pending.ndjson")
    st = read_json(mark, {}) or {}
    logf = os.path.join(paths.log, "entry.log")
    try:
        cur = os.stat(logf)
    except OSError:
        return 0
    chunks = []
    if st.get("ino") and st["ino"] != cur.st_ino:
        # rotated: the rest of the old file first, when it is still entry.log.1
        try:
            old = os.stat(logf + ".1")
            if old.st_ino == st["ino"]:
                chunks.append((logf + ".1", int(st.get("off") or 0), old.st_ino))
        except OSError:
            pass
        chunks.append((logf, 0, cur.st_ino))
    else:
        off = int(st.get("off") or 0)
        chunks.append((logf, off if off <= cur.st_size else 0, cur.st_ino))
    book = read_json(ep.book, {}) or {}
    host = os.uname()[1].split(".")[0]
    new = []
    for f, off, ino in chunks:
        try:
            with open(f, "rb") as fh:
                fh.seek(off)
                data = fh.read(4 << 20)
        except (IOError, OSError):
            continue
        # a half-written last line waits for the next pass
        cut = data.rfind(b"\n") + 1
        for d in entry_audit_lines(data[:cut].decode("utf-8", "replace"), book, host, off, now()):
            d["id"] = "%d-%s" % (ino, d["id"])
            new.append(d)
        st = {"ino": ino, "off": off + cut}
    write_json(mark, st, 0o600)
    if new:
        body = "".join(json.dumps(d, sort_keys=True, ensure_ascii=False) + "\n" for d in new)
        for f, mode in ((os.path.join(paths.log, "entry.ndjson"), 0o644), (pend, 0o600)):
            try:
                fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_APPEND, mode)
                with os.fdopen(fd, "a") as fh:
                    fh.write(body)
            except OSError:
                pass
    entry_audit_send(paths, pend)
    return len(new)


def entry_audit_send(paths, pend):
    """The queue to the hub, ≤ 500 lines a request (the hub's bound); what it
    took leaves the queue, the rest waits. No hub / no token ⇒ it just waits
    (at most ENTRY_AUDIT_KEEP lines, the oldest go first)."""
    lines = [l for l in ((_entry_read(pend) or "").splitlines()) if l.strip()]
    if not lines:
        return
    if len(lines) > ENTRY_AUDIT_KEEP:
        lines = lines[-ENTRY_AUDIT_KEEP:]
    _on, _port, me = entry_settings(paths)
    hub, token = (me.get("CCQUOTA_HUB_URL") or "").rstrip("/"), me.get("CCQUOTA_TOKEN") or ""
    sent = 0
    if hub and token:
        from urllib.request import Request, urlopen
        while sent < len(lines):
            batch = []
            for l in lines[sent:sent + 500]:
                try:
                    d = json.loads(l)
                except ValueError:
                    continue
                d.pop("machine", None)        # the hub names the machine itself
                batch.append(d)
            try:
                req = Request(hub + "/v1/node/entry-audit", data=json.dumps({"lines": batch}).encode(),
                              headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
                with urlopen(req, timeout=env_num("FLEET_ENTRY_PULL_SECS", 10)) as r:
                    r.read()
            except Exception:  # urllib raises many kinds; the queue simply waits
                break
            sent += min(500, len(lines) - sent)
    rest = lines[sent:]
    _entry_put(pend, "".join(l + "\n" for l in rest), 0o600)


def entry_on_for_reader(paths, book):
    """(on, port) as a reader sees it: machine.env is root's 600, so a login's
    doctor that cannot read it goes by the book (0644) the daemon wrote."""
    on, port, _me = entry_settings(paths)
    if not on and book and book.get("on") and os.environ.get("FLEET_ENTRY") is None \
            and os.path.exists(EntryPaths(paths).machine_env) \
            and not os.access(EntryPaths(paths).machine_env, os.R_OK):
        return True, book.get("port") or port
    return on, port


def entry_line(paths, state):
    """`entry …` for status, or None when the entry is off and never was."""
    ep = EntryPaths(paths)
    book = read_json(ep.book, None)
    on, port = entry_on_for_reader(paths, book)
    if not on:
        return None if book is None else "entry  off · %s left from before (FLEET_ENTRY=1 turns it on)" % ep.dir
    book = book or {}
    cs = (state.get("children") or {}).get("entry") or {}
    if book.get("error"):
        what = "PROBLEM — %s" % book["error"]
    elif not book.get("allow"):
        what = "no login has its home here — not listening"
    elif pid_alive(cs.get("pid")):
        what = "listening pid %s" % cs["pid"]
    else:
        what = "not listening yet"
    pulled = ("pulled %s ago" % ago(book["pulled_at"])) if book.get("pulled_at") else "never pulled"
    if book.get("pull_error"):
        pulled += " (last try: %s)" % book["pull_error"]
    return "entry  port %d · %s · %d login(s)%s · v%s · hub v%s · %s" % (
        port, what, len(book.get("allow") or []),
        (" (%s)" % ", ".join(book["allow"])) if book.get("allow") else "",
        book.get("version") or 0, book.get("hub_version") or "-", pulled)


def entry_check(paths):
    """The doctor's `entry` row: (code, line). 0 ok · 1 WARN · 2 off."""
    book = read_json(EntryPaths(paths).book, {}) or {}
    on, port = entry_on_for_reader(paths, book)
    if not on:
        return 2, "off"
    st = read_json(paths.state_file, {})
    cs = (st.get("children") or {}).get("entry") or {}
    hub_v, mine = book.get("hub_version"), book.get("version") or 0
    line = "入口 v%s · 本机 v%s · %s · 端口 %d · %d 个登录" % (
        hub_v or "-", mine, ("拉到 %s 前" % ago(book["pulled_at"])) if book.get("pulled_at") else "没拉到过",
        port, len(book.get("allow") or []))
    if book.get("error"):
        return 1, line + " · " + book["error"]
    if book.get("allow") and not pid_alive(cs.get("pid")):
        return 1, line + " · 名单有人但入口 sshd 没在跑"
    if hub_v and hub_v > mine and now() - (book.get("hub_version_at") or now()) > 3600:
        return 1, line + " · 落后入口一小时以上（%s）" % (book.get("pull_error") or "拉取没成")
    return 0, line


# ---- can the outside reach the entry port? (issue #3072, EPIC #3067 C6) --------
# `entry reach`, run by the node program every 5 minutes (off its beat): this
# machine's global IPv6 addresses, its router asked to forward the port
# (FLEET_ENTRY_PORTMAP=auto|off: NAT-PMP, then UPnP), POSTed to the hub's
# /v1/node/entry-reach. The hub takes the public IPv4 from where it sees the report
# come from, dials every address, counts one only when the entry's own host key
# answers there, and says so; the answer lands in <state>/entry/reach.json (0644 —
# addresses and reasons, nothing secret), which `entry reach --check` (the doctor's
# `public` row) reads. A router that never answers costs a few seconds, never the
# report; the report failing costs nothing but this row.
ENTRY_REACH_STALE = 20 * 60
ENTRY_VIRTUAL_IF = ("utun", "tailscale", "tun", "wg", "docker", "veth", "br-", "bridge", "vmnet",
                    "virbr", "awdl", "llw", "anpi", "ap", "gif", "stf", "lo")
ENTRY_REASONS = {"timeout": "超时", "refused": "被拒（端口没开 / 没转发）",
                 "hostkey": "钥匙不符（那个地址上是别的机器）", "not_ssh": "不是 SSH", "unreachable": "不通"}


def entry_ifaddrs():
    """[(ifname, addr, prefixlen, flags)] of the up interfaces. FLEET_ENTRY_IFADDRS
    names a file of `<if> <addr>/<plen> [flag …]` lines (the selftests' seam)."""
    seam = os.environ.get("FLEET_ENTRY_IFADDRS")
    out = []
    if seam:
        try:
            lines = open(seam).read().splitlines()
        except (IOError, OSError):
            return []
        for ln in lines:
            f = ln.split()
            if len(f) >= 2 and "/" in f[1]:
                a, p = f[1].split("/", 1)
                out.append((f[0], a, int(p) if p.isdigit() else 0, set(f[2:])))
        return out
    if sys.platform == "darwin":
        try:
            txt = subprocess.check_output(["/sbin/ifconfig"], stderr=subprocess.DEVNULL,
                                          timeout=10).decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return []
        ifn = ""
        for ln in txt.splitlines():
            m = re.match(r"^(\S+?):\s+flags=", ln)
            if m:
                ifn = m.group(1)
                continue
            f = ln.split()
            if len(f) >= 2 and f[0] == "inet":
                plen = 0
                if "netmask" in f and f.index("netmask") + 1 < len(f):
                    try:
                        plen = bin(int(f[f.index("netmask") + 1], 16)).count("1")
                    except ValueError:
                        pass
                out.append((ifn, f[1], plen, set()))
            elif len(f) >= 2 and f[0] == "inet6":
                plen = int(f[f.index("prefixlen") + 1]) if "prefixlen" in f else 0
                out.append((ifn, f[1].split("%")[0], plen, set(f[2:])))
        return out
    for ipb in ("/usr/sbin/ip", "/sbin/ip", "/usr/bin/ip", "/bin/ip"):
        if os.path.exists(ipb):
            break
    else:
        return []
    try:
        txt = subprocess.check_output([ipb, "-o", "addr", "show", "up"], stderr=subprocess.DEVNULL,
                                      timeout=10).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return []
    for ln in txt.splitlines():
        f = ln.split()
        if len(f) >= 4 and f[2] in ("inet", "inet6") and "/" in f[3]:
            a, p = f[3].split("/", 1)
            out.append((f[1], a, int(p) if p.isdigit() else 0, set(f[4:])))
    return out


def entry_addrs(ifaddrs, default_if=""):
    """(lan IPv4 list, global IPv6 list) a home is reached on — never a tunnel's,
    a bridge's, a temporary or deprecated IPv6. The default route's interface goes
    first: the router forwards to THAT address (mac-a's wired en0, never the Wi-Fi's)."""
    import ipaddress
    lan, v6 = [], []
    cg = ipaddress.ip_network("100.64.0.0/10")
    for ifn, a, _plen, flags in ifaddrs:
        if ifn.startswith(ENTRY_VIRTUAL_IF):
            continue
        try:
            ip = ipaddress.ip_address(a)
        except ValueError:
            continue
        if ip.version == 4:
            if ip.is_private and ip not in cg and not ip.is_loopback and not ip.is_link_local and a not in lan:
                lan.append(a)
        elif ip.is_global and not (flags & {"temporary", "deprecated", "tentative", "dadfailed", "detached"}) \
                and a not in v6:
            v6.append(a)
    if default_if:
        on = set(a for ifn, a, _p, _f in ifaddrs if ifn == default_if)
        lan.sort(key=lambda a: a not in on)
        v6.sort(key=lambda a: a not in on)
    return lan[:4], v6[:4]


def entry_default_route():
    """(gateway IPv4, interface) of the default route — ("", "") when there is none.
    FLEET_ENTRY_GATEWAY / FLEET_ENTRY_DEFAULT_IF are the selftests' seams."""
    gw, ifn = os.environ.get("FLEET_ENTRY_GATEWAY"), os.environ.get("FLEET_ENTRY_DEFAULT_IF")
    if gw is not None or ifn is not None:
        return gw or "", ifn or ""
    if sys.platform == "darwin":
        try:
            txt = subprocess.check_output(["/sbin/route", "-n", "get", "default"], stderr=subprocess.DEVNULL,
                                          timeout=5).decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return "", ""
        g = re.search(r"gateway:\s*(\d+\.\d+\.\d+\.\d+)", txt)
        i = re.search(r"interface:\s*(\S+)", txt)
        return (g.group(1) if g else ""), (i.group(1) if i else "")
    try:
        best = None
        for ln in open("/proc/net/route").read().splitlines()[1:]:
            f = ln.split()
            if len(f) > 6 and f[1] == "00000000" and f[2] != "00000000":
                if best is None or int(f[6]) < int(best[6]):
                    best = f
        if best:
            import socket
            import struct
            return socket.inet_ntoa(struct.pack("<I", int(best[2], 16))), best[0]
    except (IOError, OSError, ValueError):
        pass
    return "", ""


def entry_gateway():
    return entry_default_route()[0]


def entry_natpmp(gw, port):
    """NAT-PMP (RFC 6886): the router's outside address, then a TCP mapping of
    port. {method, external_ip, external_port} or {method, error}."""
    import socket
    import struct
    out = {"method": "natpmp"}
    dst = (gw, int(env_num("FLEET_ENTRY_NATPMP_PORT", 5351)))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def ask(req, n, op):
        for wait in (0.25, 0.5, 1.0):
            s.sendto(req, dst)
            s.settimeout(wait)
            t0 = time.time()
            while time.time() - t0 < wait:
                try:
                    data, src = s.recvfrom(64)
                except socket.timeout:
                    break
                except OSError as e:
                    raise RuntimeError("router: %s" % (e.strerror or e))
                if src[0] == gw and len(data) >= n and data[0] == 0 and data[1] == op:
                    rc = struct.unpack("!H", data[2:4])[0]
                    if rc:
                        raise RuntimeError("router refused (NAT-PMP result %d)" % rc)
                    return data
        raise RuntimeError("no answer from %s" % gw)
    try:
        d = ask(b"\x00\x00", 12, 128)
        out["external_ip"] = socket.inet_ntoa(d[8:12])
        d = ask(struct.pack("!BBHHHI", 0, 2, 0, port, port, 7200), 16, 130)
        out["external_port"] = struct.unpack("!H", d[10:12])[0]
    except (RuntimeError, OSError) as e:
        out.pop("external_ip", None)
        out["error"] = str(e)
    finally:
        s.close()
    return out


def _upnp_soap(url, stype, action, args):
    from urllib.request import Request, urlopen
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:%s xmlns:u="%s">%s'
            '</u:%s></s:Body></s:Envelope>') % (action, stype, "".join("<%s>%s</%s>" % (k, v, k) for k, v in args),
                                                action)
    req = Request(url, data=body.encode("utf-8"), headers={
        "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": '"%s#%s"' % (stype, action)})
    with urlopen(req, timeout=4) as r:
        return r.read(65536).decode("utf-8", "replace")


def entry_upnp(lan, port):
    """UPnP IGD: find the router on the LAN (SSDP), ask it to forward TCP port to
    lan:port, then its outside address. Only a description URL on the answering
    router's own private address is ever fetched."""
    import ipaddress
    import socket
    out = {"method": "upnp"}
    if env("FLEET_ENTRY_SSDP", "on") == "off":
        out["error"] = "SSDP off"
        return out
    st = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
           "ST: %s\r\n\r\n" % st).encode("ascii")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    loc = ""
    try:
        s.settimeout(2.5)
        s.sendto(msg, (env("FLEET_ENTRY_SSDP_ADDR", "239.255.255.250"), int(env_num("FLEET_ENTRY_SSDP_PORT", 1900))))
        t0 = time.time()
        while time.time() - t0 < 2.5 and not loc:
            try:
                data, src = s.recvfrom(4096)
            except socket.timeout:
                break
            m = re.search(r"(?im)^location:\s*(\S+)", data.decode("utf-8", "replace"))
            if not m:
                continue
            from urllib.parse import urlparse
            u = urlparse(m.group(1))
            try:
                hip = ipaddress.ip_address(u.hostname or "")
            except ValueError:
                continue
            if u.scheme == "http" and u.hostname == src[0] and (hip.is_private or hip.is_loopback):
                loc = m.group(1)
    except OSError as e:
        out["error"] = "SSDP: %s" % (e.strerror or e)
        return out
    finally:
        s.close()
    if not loc:
        out["error"] = "no UPnP router answered"
        return out
    try:
        from urllib.parse import urljoin
        from urllib.request import urlopen
        import xml.etree.ElementTree as ET
        with urlopen(loc, timeout=4) as r:
            root = ET.fromstring(r.read(65536))
        base = loc
        for el in root.iter():
            if el.tag.endswith("URLBase") and (el.text or "").strip():
                base = el.text.strip()
        ctl = stype = ""
        for el in root.iter():
            if not el.tag.endswith("}service"):
                continue
            kids = {c.tag.split("}")[-1]: (c.text or "").strip() for c in el}
            if re.search(r"WAN(IP|PPP)Connection:\d", kids.get("serviceType", "")):
                ctl, stype = urljoin(base, kids.get("controlURL", "")), kids["serviceType"]
                break
        if not ctl:
            out["error"] = "the router offers no WAN connection service"
            return out
        args = [("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", "TCP"), ("NewInternalPort", port),
                ("NewInternalClient", lan), ("NewEnabled", 1), ("NewPortMappingDescription", "claude-fleet entry"),
                ("NewLeaseDuration", 7200)]
        try:
            _upnp_soap(ctl, stype, "AddPortMapping", args)
        except Exception:  # some routers take only a permanent lease (725)
            _upnp_soap(ctl, stype, "AddPortMapping", args[:-1] + [("NewLeaseDuration", 0)])
        out["external_port"] = port
        m = re.search(r"<NewExternalIPAddress>\s*([0-9.]+)\s*<", _upnp_soap(ctl, stype, "GetExternalIPAddress", []))
        if m:
            out["external_ip"] = m.group(1)
    except Exception as e:  # urllib / XML / a SOAP fault: the reason is all we keep
        out.pop("external_port", None)
        out["error"] = "UPnP: %s" % (getattr(e, "code", None) or getattr(e, "reason", None) or e)
    return out


def entry_portmap(lan, port, gw=None):
    """FLEET_ENTRY_PORTMAP (environment, else machine.env): auto (default) tries
    NAT-PMP, then UPnP; off asks no router."""
    if gw is None:
        gw = entry_gateway()
    tried = []
    if gw:
        r = entry_natpmp(gw, port)
        if not r.get("error"):
            return r
        tried.append("NAT-PMP: %s" % r["error"])
    if lan:
        r = entry_upnp(lan[0], port)
        if not r.get("error"):
            return r
        tried.append(r["error"])
    return {"method": "auto", "error": "; ".join(tried) or "no router found"}


def entry_route(paths, me):
    """(host, port) of the machine's operator-written entry route —
    CCQUOTA_FLEET_NODE_ROUTES `entry=host[:port]`, the public port the router
    forwards to the entry port (mac-b :22122, mac-a :22123) — from the environment,
    machine.env, else a taken-over login's <state>/logins/<login>.env, where the node
    program reads it. `public=` is the system sshd's and is never read here. ("", 0)
    when there is none: then the entry's own port is the one knocked on."""
    srcs = [os.environ.get("CCQUOTA_FLEET_NODE_ROUTES"), me.get("CCQUOTA_FLEET_NODE_ROUTES")]
    for f in sorted(glob.glob(os.path.join(paths.state, "logins", "*.env"))):
        srcs.append((_env_file(f, 0) or {}).get("CCQUOTA_FLEET_NODE_ROUTES"))
    for v in srcs:
        for part in (v or "").split(","):
            name, _, hp = part.strip().partition("=")
            if name.strip() != "entry" or not hp.strip():
                continue
            h, _, prt = hp.strip().partition(":")
            if not re.match(r"^[A-Za-z0-9._-]{1,253}$", h):
                continue
            n = int(prt) if prt.isdigit() else 0
            if 0 < n < 65536:
                return h, n
    return "", 0


def entry_reach(paths):
    """One report: 0 the hub answered · 1 it did not (reach.json says why) · 3 entry off."""
    on, port, me = entry_settings(paths)
    if not on:
        print("entry off (FLEET_ENTRY=1 in machine.env turns it on)")
        return 3
    ep = EntryPaths(paths)
    _entry_root_dir(ep.dir, 0o755)
    book = read_json(ep.book, {}) or {}
    cs = (read_json(paths.state_file, {}).get("children") or {}).get("entry") or {}
    listening = bool(book.get("allow")) and pid_alive(cs.get("pid"))
    gw, default_if = entry_default_route()
    lan, v6 = entry_addrs(entry_ifaddrs(), default_if)
    hostkey = " ".join((_entry_read(ep.hostkey + ".pub") or "").split()[:2])
    rep = {"port": port, "host_key": hostkey, "listening": listening, "v6": v6, "lan": lan}
    ent_host, ent_port = entry_route(paths, me)
    if ent_port:
        rep.update(entry_host=ent_host, entry_port=ent_port)
    mode = os.environ.get("FLEET_ENTRY_PORTMAP") or me.get("FLEET_ENTRY_PORTMAP") or "auto"
    if listening and mode != "off":
        rep["portmap"] = entry_portmap(lan, port, gw)
    out = {"at": now(), "port": port, "listening": listening, "lan": lan, "v6": v6, "default_if": default_if,
           "entry_host": ent_host, "entry_port": ent_port,
           "portmap": rep.get("portmap"), "portmap_mode": mode, "verdict": None, "error": ""}
    hub, token = (me.get("CCQUOTA_HUB_URL") or "").rstrip("/"), me.get("CCQUOTA_TOKEN") or ""
    if not hub or not token:
        out["error"] = "machine.env names no hub or no token"
    else:
        from urllib.request import Request, urlopen
        try:
            req = Request(hub + "/v1/node/entry-reach", data=json.dumps(rep).encode("utf-8"),
                          headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                   "Accept": "application/json"})
            with urlopen(req, timeout=env_num("FLEET_ENTRY_REACH_SECS", 30)) as r:
                out["verdict"] = json.loads(r.read().decode("utf-8"))
        except Exception as e:  # urllib raises many kinds; the reason is all we keep
            out["error"] = "the hub: %s" % (getattr(e, "code", None) or getattr(e, "reason", None) or e)
    prev = read_json(os.path.join(ep.dir, "reach.json"), {}) or {}
    if out["error"] and prev.get("verdict"):
        out["verdict"], out["verdict_at"] = prev["verdict"], prev.get("verdict_at") or prev.get("at")
    elif out["verdict"]:
        out["verdict_at"] = out["at"]
    write_json(os.path.join(ep.dir, "reach.json"), out, 0o644)
    print(entry_reach_check(paths)[1])
    return 1 if out["error"] else 0


def _reach_addr(a):
    h = a.get("addr") or "?"
    return ("[%s]:%s" % (h, a.get("port")) if ":" in h else "%s:%s" % (h, a.get("port")))


def entry_reach_check(paths):
    """The doctor's `public` row: (code, line). 0 reachable · 1 WARN · 2 no row
    (entry off, or nobody's home here so nothing listens)."""
    ep = EntryPaths(paths)
    book = read_json(ep.book, {}) or {}
    on, port = entry_on_for_reader(paths, book)
    if not on:
        return 2, "off"
    r = read_json(os.path.join(ep.dir, "reach.json"), None)
    if r is None:
        if not book.get("allow"):
            return 2, "nobody's home here"
        return 1, "外面能不能连上还没查过（节点程序每 5 分钟查一次；现在查：sudo fleet-node-supervisor.py entry reach）"
    if not r.get("listening"):
        return 2, "the entry is not listening"
    lan = (r.get("lan") or [None])[0]
    there = ("%s:%d" % (lan, port)) if lan else ("这台的 %d" % port)
    # The public port the router forwards to the entry: the entry= route's, else the same.
    fwd = "在路由器上把公网 TCP %d 转发到 %s" % (r.get("entry_port") or port, there)
    v = r.get("verdict")
    if not v:
        return 1, "外面能不能连上查不了：%s" % (r.get("error") or "入口没回答")
    addrs = v.get("addrs") or []
    ok = [a for a in addrs if a.get("reachable")]
    bad = [a for a in addrs if not a.get("reachable")]
    when = "查于 %s 前" % ago(r.get("verdict_at") or r.get("at"))
    stale = now() - (r.get("verdict_at") or r.get("at") or 0) > ENTRY_REACH_STALE
    tail = []
    if r.get("error"):
        tail.append("这次没报上：%s" % r["error"])
    pm = r.get("portmap") or {}
    if pm.get("error"):
        tail.append("路由器没自动开端口（%s）" % pm["error"])
    elif pm.get("method") and pm.get("external_port"):
        tail.append("路由器已开端口（%s → %s）" % (pm["method"].upper(), pm["external_port"]))
    badtxt = "；".join("%s %s" % (_reach_addr(a), ENTRY_REASONS.get(a.get("reason"), a.get("reason") or "?"))
                      for a in bad)
    if ok:
        line = "外面连得上：%s · %s" % (" · ".join("%s（%s）" % (_reach_addr(a), "IPv6" if a.get("family") == "ipv6"
                                                              else "IPv4") for a in ok), when)
        if badtxt:
            line += " · 连不上：" + badtxt
        if tail:
            line += " · " + " · ".join(tail)
        return (1, line + " · 结果过期（超过 20 分钟没再查）") if stale else (0, line)
    if v.get("no_public") == "cgnat":
        why = "这台没有公网地址（运营商级 NAT%s）：外面的 IPv4 进不来——有 IPv6 才行，或向运营商要公网 IP 后%s" % (
            "，路由器外侧是 %s" % pm["external_ip"] if pm.get("external_ip") else "", fwd)
    elif not addrs:
        why = "入口看不到这台的公网地址（来源 %s），这台也没有全局 IPv6；%s" % (v.get("source") or "?", fwd)
    else:
        why = fwd
    line = "外面连不上：" + " · ".join(x for x in (badtxt, why, when) if x)
    if tail:
        line += " · " + " · ".join(tail)
    return 1, line


def entry_cli(paths, rest):
    sub = rest[0] if rest else "status"
    if sub == "pull":
        v = None
        if "--version" in rest[1:]:
            try:
                v = int(rest[rest.index("--version") + 1])
            except (IndexError, ValueError):
                print("usage: entry pull [--version N]", file=sys.stderr)
                return 2
        return entry_pull(paths, v)
    if sub == "apply" and len(rest) > 1:
        src = rest[1]
        try:
            lst = json.load(sys.stdin) if src == "-" else read_json(src, None)
        except ValueError:
            lst = None
        if lst is None:
            print("entry apply: %s is not JSON" % src, file=sys.stderr)
            return 2
        b = entry_converge(paths, lst, force="--force" in rest)
        if b is None:
            print("entry off (FLEET_ENTRY=1 turns it on)")
            return 3
        print("entry v%s · %d login(s) on the port%s" % (b.get("version"), len(b.get("allow") or []),
                                                         " · " + b["error"] if b.get("error") else ""))
        return 1 if b.get("error") else 0
    if sub == "revocations":
        return revocations_cli(paths, rest[1:])
    if sub == "ensure":
        b = entry_converge(paths)
        if b is None:
            return 3
        return 1 if b.get("error") else 0
    if sub == "reach":
        if "--check" in rest:
            code, line = entry_reach_check(paths)
            print(line)
            return code
        return entry_reach(paths)
    if sub == "status":
        if "--check" in rest:
            code, line = entry_check(paths)
            print(line)
            return code
        line = entry_line(paths, read_json(paths.state_file, {}))
        print(line or "entry  off")
        return 0
    print("usage: entry pull [--version N] | apply <file|-> [--force] | ensure | reach [--check] | status [--check]",
          file=sys.stderr)
    return 2


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


def systemd_body(paths):
    # JSON quoting is also valid systemd quoted-word escaping; reject newlines.
    values = node_environment()
    values.update(FLEET_NODE_ROOT=env("FLEET_NODE_ROOT", DEFAULT_ROOT),
                  FLEET_NODE_RUNTIME=paths.runtime, FLEET_NODE_STATE=paths.state,
                  FLEET_NODE_LOG=paths.log, FLEET_NODE_USERS=paths.users)
    for v in values.values():
        if "\n" in v or "\r" in v or "%" in v:
            raise ValueError("invalid systemd setting")
    args = ["/usr/bin/python3", "-I", os.path.join(paths.runtime, "bin", "fleet-node-supervisor.py"), "run"]
    return ("[Unit]\nDescription=Fleet managed node\nAfter=network-online.target\nWants=network-online.target\n\n"
            "[Service]\nType=simple\n" +
            "".join("Environment=%s\n" % json.dumps(k + "=" + v) for k, v in sorted(values.items())) +
            "ExecStart=%s\nRestart=always\nRestartSec=5\nKillMode=mixed\nTimeoutStopSec=120\n"
            "LimitNOFILE=65536\nUMask=0022\n\n[Install]\nWantedBy=multi-user.target\n"
            % " ".join(json.dumps(a) for a in args))


def systemctl(*args):
    return subprocess.call([env("FLEET_NODE_SYSTEMCTL", "systemctl")] + list(args),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


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
    if env("FLEET_NODE_SERVICE", "") == "foreground":
        print("foreground: the container starts the supervisor")
        return 0
    if not MAC:
        os.makedirs(paths.daemon_dir, exist_ok=True)
        tmp = paths.plist + ".tmp-node"
        with open(tmp, "w") as f:
            f.write(systemd_body(paths))
        os.chmod(tmp, 0o644)
        os.replace(tmp, paths.plist)
        if systemctl("daemon-reload") or systemctl("enable", "--now", SYSTEMD_UNIT):
            return 1
        return systemctl("restart", SYSTEMD_UNIT)
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
    if env("FLEET_NODE_SERVICE", "") == "foreground":
        return 0
    if not MAC:
        try:
            with open(paths.plist) as f:
                if f.read() != systemd_body(paths):
                    return 1
        except OSError:
            return 1
        return systemctl("is-active", "--quiet", SYSTEMD_UNIT)
    try:
        with open(paths.plist, "rb") as f:
            if plistlib.load(f) != plist_body(paths):
                return 1
    except Exception:
        return 1
    return 0 if launchctl("print", "system/" + LABEL) == 0 else 1


def uninstall(paths):
    if not MAC:
        systemctl("disable", "--now", SYSTEMD_UNIT)
    else:
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
def shell_hooks_cli(path, dry):
    """`shell-hooks <~/.zshrc> [--dry-run]`: take shell_hooks' lines out of one file
    (bin/fleet-node-shell-retire.sh runs it AS the login — this touches no state).
    The old file is kept as <file>.pre-shell-retire[.<stamp>]. One line out; exit 0
    done / nothing to do · 1 a block with no end line (left as it is)."""
    try:
        with open(path) as f:
            lines = f.read().split("\n")
    except OSError:
        print("skip — no ~/.zshrc")
        return 0
    keep, gone, err = shell_hooks(lines)
    if err:
        print("FAIL — %s; left as it is" % err)
        return 1
    if not gone:
        print("skip — no fleet hook in ~/.zshrc")
        return 0
    if dry:
        print("would take out %d line(s)" % len(gone))
        return 0
    bak = path + ".pre-shell-retire"
    if os.path.exists(bak):
        bak += "." + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    mode = os.stat(path).st_mode & 0o777
    with open(bak, "w") as f:
        f.write("\n".join(lines))
    os.chmod(bak, mode)
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(keep))
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.rename(tmp, path)
    print("took out %d line(s) — the old file is %s" % (len(gone), bak.replace(os.path.dirname(path), "~", 1)))
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    if cmd == "shell-hooks" and rest:
        return shell_hooks_cli(rest[0], "--dry-run" in rest[1:])
    paths = Paths()
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    if cmd == "install":
        return install_check(paths) if "--check" in rest else install(paths)
    if cmd == "uninstall":
        return uninstall(paths)
    if cmd == "service":
        return service_cli(paths, rest)
    if cmd == "entry":
        return entry_cli(paths, rest)
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
        if sub == "forget" and len(rest) > 1:
            return account_forget(paths, rest[1], force="--force" in rest)
    if cmd == "tenants":
        cur = tenants_now(paths, read_json(paths.state_file, {}))
        bad = cur["bad"]
        code = 2 if not cur["logins"] else 1 if bad else 0 if cur["complete"] or cur.get("daemon_at") else 3
        if "--json" in rest:
            print(json.dumps(cur, indent=1, sort_keys=True))
        elif not cur["logins"]:
            print("no taken-over login")
        elif "--check" in rest:
            if bad:
                print("; ".join("%s: %s" % (l, ", ".join(w)) for l, w in sorted(bad.items())))
            else:
                print("%d taken-over login(s), none admin or sudo-capable: %s%s" % (
                    len(cur["logins"]), " ".join(cur["logins"]),
                    "" if cur["complete"] else " (sudo rules: the daemon's reading of %s)" % iso(cur["daemon_at"])
                    if cur.get("daemon_at") else " (sudo rules unread: not root, no daemon reading yet)"))
        else:
            for login in cur["logins"]:
                print("%-16s %s" % (login, "FAIL " + "; ".join(bad[login]) if login in bad else "ok"))
        return code if "--check" in rest else 0
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
            tcc = tcc_stuck_line(state) if code == 0 else ""
            if tcc:
                print("%s · %s" % (lines[0], tcc))
                return 6
            fda = fda_line(state) if code == 0 else ""
            if fda:
                print("%s · %s" % (lines[0], fda))
                return 4
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
        for x in res["removed"]:
            print("%s %s -> attic %s (%s)" % ("would boot out" if dry else "booted out", x["src"], x["id"], x["why"]))
        for x in res["extra"]:
            print("extra (not in the expected set, left in place — %s): %s" % (x["why"], x["path"]))
        for h in res["handwritten"]:
            print("handwritten (runs as %s, not in the register, left in place): %s" % (h["login"], h["path"]))
        for c in res["clientshell"]:
            print("clientshell (%s): %s" % ("would retire" if dry and os.path.exists(paths.expected)
                                            else "left in place", client_shell_says(c, paths)))
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
          "shell-hooks <zshrc> [--dry-run]|attic [list|restore <id>|purge]|account [list|adopt|release|forget|manages <login>]|tenants [--json|--check]|"
          "install|uninstall",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
