#!/usr/bin/env python3
"""fleet-credsep.py — keep a trusted login's credentials where its sessions
cannot read them (issue #1971, EPIC #1967 C4). bin/fleet-credsep.sh is the
front; install / uninstall run as ROOT (it calls them through `sudo -n`).

    install   --login L --conf-dir C --install-dir I [--dry-run|--adopt]
    uninstall --login L --conf-dir C [--dry-run]
    status    --conf-dir C [--json]                 (as the login)
    check     --conf-dir C                          (as the login: the doctor row)
    plan      --bin B                               (anyone: every login's state + commands)
    machine install|uninstall|refresh [--logins a,b|all] [--dry-run]    (root)
    machine status [--json]                         (anyone)

MACHINE MODE (issue #2217): on a managed node ONE credential proxy serves every
login — the role account runs it (com.claude-fleet.cred-proxy-shared /
claude-fleet-cred-proxy-shared.service, fleet-credsep-launch.py shared) on one
fixed 127.0.0.1 port (FLEET_CRED_SHARED_PORT, 18923) with one control socket
(/var/run/fleet-cred/.shared/ctl.sock, 0666: the peer uid names the login).
`machine install` makes each login a TENANT of it: the same store as above
(meta.json `mode: shared`), its own proxy's signing key / passes / binds moved
into <store>/cred-proxy (its sessions' credentials stay good, and its old port
is answered by the shared proxy for that login only), its per-login proxy
service removed, FLEET_CRED_PROXY=1 in its fleet.conf (the line it had is
remembered). `machine uninstall` undoes all of it, byte for byte; each login's
own proxy takes its old port back with the same key. /var/db/fleet-cred/
.shared.json is the record anyone reads (`machine status`, the doctor).

--dry-run needs no root (bin/fleet-credsep.sh runs it as the login): it prints
what would happen. Separated, the store is unreadable to the login, so the
uninstall dry run reads the way back from C/credsep.json's `back` (every login
path a credential left, the agent's service, the proxy's) — paths, no secret.

What install does, each step idempotent:
  1. the role account _fleetcred (macOS: UID/GID in 450-499, shell
     /usr/bin/false, home /var/empty; Linux: `fleetcred`, useradd --system)
  2. /var/db/fleet-cred/<L>/ (0700, the role account's): accounts/ codex/
     cred-proxy/ backup/ meta.json
  3. a root-owned copy of fleet-credsep-launch.py + fleet-cred-proxy.py in LIB
     (the role account must never run code the login can edit)
  4. MOVES every credential the node agent leased into it — accounts/<l>.hub/
     .credentials.json, hub-managed Codex auth.json (refresh_token
     "hub-managed"), node.env (C/node.env becomes a symlink there, so reading it
     is "Permission denied"; C/node.pub.env keeps its token-less lines)
  5. the proxy service (com.claude-fleet.credsep.<L> / claude-fleet-credsep-<L>),
     run by root → fleet-credsep-launch.py proxy, which drops to the role account
  6. the agent service now starts through fleet-credsep-launch.py agent (root,
     token down a pipe, then the login); the original definition is kept in
     backup/ for uninstall
  6b. LIB/<L>.conf (root, 0600) — the proxy's upstream / hub / relay-pass
     settings; the launcher reads these from here ONLY, never the login's own
     files (issue #2290). Written once from the login's allowed values, then
     kept; `install --adopt` takes the login's current ones again
  7. C/credsep.json — the login-readable record that says "separated" (no secret),
     with `back`: the paths uninstall puts things back to (issue #2135)

uninstall reverses all of it: every credential file under the store goes back
to the login's own path (the agent may have renewed them meanwhile), node.env
becomes a file again, the services are restored, the store and — when no other
login uses it — the role account are deleted. After uninstall every file is
where it was before install, byte for byte (modulo renewals the agent wrote).

Seams (the selftest's sandbox; never set in production): FLEET_CREDSEP_ROOT_BASE,
FLEET_CREDSEP_RUN_BASE, FLEET_CREDSEP_LOG_BASE, FLEET_CREDSEP_LIB,
FLEET_CREDSEP_DAEMON_DIR, FLEET_CREDSEP_ROLE (an existing user — not created),
FLEET_CREDSEP_SVC=0 (no launchctl/systemctl: the commands are printed; the role
account is still created unless FLEET_CREDSEP_ROLE names one),
FLEET_CREDSEP_TEST=1 (allow a non-root install into the sandbox),
FLEET_CREDSEP_HOMES / FLEET_CREDSEP_USERS (plan: the homes dir, a `name:home` list).
"""
import argparse, glob, grp, json, os, plistlib, pwd, re, shlex, shutil, subprocess, sys, time

MAC = sys.platform == "darwin"
HERE = os.path.dirname(os.path.abspath(__file__))
HUB_MANAGED = "hub-managed"     # tokenledger internal/codex HubManagedRefreshToken
SAFE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$")


def E(k, d):
    return os.environ.get(k) or d


ROOT_BASE = E("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred")
RUN_BASE = E("FLEET_CREDSEP_RUN_BASE", "/var/run/fleet-cred")
LOG_BASE = E("FLEET_CREDSEP_LOG_BASE", "/var/log/fleet-cred")
LIB = E("FLEET_CREDSEP_LIB", "/Library/Application Support/claude-fleet/credsep" if MAC
        else "/usr/local/lib/claude-fleet/credsep")
DAEMON_DIR = E("FLEET_CREDSEP_DAEMON_DIR", "/Library/LaunchDaemons" if MAC else "/etc/systemd/system")
ROLE = E("FLEET_CREDSEP_ROLE", "_fleetcred" if MAC else "fleetcred")
SVC = os.environ.get("FLEET_CREDSEP_SVC", "1") != "0"
TEST = os.environ.get("FLEET_CREDSEP_TEST") == "1"
PY = "/usr/bin/python3"
# the machine's ONE shared proxy (issue #2217): every login a tenant of it
SHARED_DIR = os.path.join(ROOT_BASE, ".shared")          # its tenants file + lock (the role account's)
SHARED_RUN = os.path.join(RUN_BASE, ".shared")           # ctl.sock 0666, port, pid, version
SHARED_REC = os.path.join(ROOT_BASE, ".shared.json")     # anyone reads it: who joined, the port, the version
SHARED_LABEL = "com.claude-fleet.cred-proxy-shared" if MAC else "claude-fleet-cred-proxy-shared.service"
SHARED_PATH = os.path.join(DAEMON_DIR, SHARED_LABEL + (".plist" if MAC else ""))
SHARED_PORT = int(E("FLEET_CRED_SHARED_PORT", "18923"))
# a per-login proxy's state that follows its login into the store: the signing
# key and the held passes MOVE (a session must not keep a copy to forge with);
# the rest is copied (nothing secret, and the login's proxy reads it back)
STATE_MOVE = ("key", "hub-passes.json", "relay.token")
STATE_COPY = ("bind.json", "revoked", "live.json", "trust.json")

DRY = False
MOVED = []      # [store path, login path] of every credential install moved (credsep.json `back`)
CUR = {}        # what install has done so far for the login it is on: a rollback's meta.json
SOFT = None     # a rollback in progress (issue #2273): a failed command is noted here, not fatal
BOOT_TRIES = max(1, int(E("FLEET_CREDSEP_BOOT_TRIES", "3")))
# the preflight (issue #2273) — off only in the selftest's sandbox, which runs no proxy
PREFLIGHT = not (TEST and os.environ.get("FLEET_CREDSEP_PREFLIGHT") == "0")


def say(*a):
    print(" ".join(str(x) for x in a), flush=True)


def die(msg, rc=1):
    sys.stderr.write("fleet-credsep: %s\n" % msg)
    sys.exit(rc)


def sh(*cmd, check=True, quiet=False):
    """A service/user command. Dry-run or FLEET_CREDSEP_SVC=0 prints it."""
    if DRY or (not SVC and cmd[0] in ("launchctl", "systemctl")):
        say("    would:", " ".join(shlex.quote(c) for c in cmd))
        return 0
    r = subprocess.run(list(cmd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode and check:
        msg = "%s → exit %d: %s" % (" ".join(cmd), r.returncode, r.stdout.strip()[-300:])
        if SOFT is not None:        # a rollback goes on past one failed step, and says so
            SOFT.append(msg)
            say("    FAILED:", msg)
            return r.returncode
        die(msg)
    if r.stdout.strip() and not quiet and r.returncode:
        say("   ", r.stdout.strip()[-300:])
    return r.returncode


def getpw(name):
    """pwd.getpwnam — or, in the selftest's sandbox (FLEET_CREDSEP_TEST=1), a row
    of FLEET_CREDSEP_PW (`name:uid:gid:home`): two logins on one real user."""
    f = os.environ.get("FLEET_CREDSEP_PW")
    if TEST and f and os.path.isfile(f):
        for line in open(f):
            r = line.strip().split(":")
            if len(r) == 4 and r[0] == name:
                return argparse.Namespace(pw_name=r[0], pw_uid=int(r[1]), pw_gid=int(r[2]), pw_dir=r[3],
                                          pw_shell="/bin/sh", sandbox=True)
    return pwd.getpwnam(name)


def chown(path, user, follow=True):
    if DRY or os.geteuid() != 0:
        return
    pw = pwd.getpwnam(user)
    (os.chown if follow else os.lchown)(path, pw.pw_uid, pw.pw_gid)


def mkdir(path, mode, owner):
    if DRY:
        return
    os.makedirs(path, exist_ok=True)
    os.chmod(path, mode)
    chown(path, owner)


def put(path, data, mode, owner):
    """Write whole (same-dir rename), then mode + owner. The temp file is made
    fresh (O_EXCL | O_NOFOLLOW): root writing into a login's directory never
    follows a link the login planted."""
    if DRY:
        say("    would write", path)
        return
    tmp = "%s.credsep.%d" % (path, os.getpid())
    try:
        os.unlink(tmp)
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    os.chmod(tmp, mode)
    chown(tmp, owner)
    os.replace(tmp, path)


def move(src, dst, owner, mode=0o600):
    """A credential file to its new place: copied whole with its new owner, then
    the old one unlinked — never a moment with neither."""
    if DRY:
        say("    would move", src, "→", dst)
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src, "rb") as f:
        put(dst, f.read(), mode, owner)
    os.unlink(src)


def hub_managed_codex(path):
    try:
        with open(path) as f:
            return json.load(f).get("tokens", {}).get("refresh_token") == HUB_MANAGED
    except (OSError, ValueError, AttributeError):
        return False


def env_file(path):
    out = {}
    try:
        for line in open(path):
            m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.rstrip("\n"))
            if m:
                out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def paths(login):
    return os.path.join(ROOT_BASE, login), os.path.join(RUN_BASE, login)


# root's settings for a login's proxy (issue #2290): every key that says where a
# credential or the node token goes. fleet-credsep-launch.py reads these from
# <LIB>/<login>.conf ONLY; the login's own fleet.conf / secrets.env keep the port
# and timings and nothing else.
ROOT_KEYS = ("FLEET_CRED_ANTHROPIC_URL", "FLEET_CRED_CODEX_URL", "FLEET_CRED_RELAY_URL", "FLEET_CRED_CENTRAL_URL",
             "FLEET_HUB_URL", "FLEET_CRED_RELAY_TOKEN", "FLEET_PROBE_FORCE_UNREACHABLE", "FLEET_CRED_ALLOW_HOSTS")
URL_KEYS = ROOT_KEYS[:5]


def root_conf_path(login):
    return os.path.join(LIB, login + ".conf")


def proxy_mod():
    import importlib.util
    spec = importlib.util.spec_from_file_location("fleet_cred_proxy", os.path.join(HERE, "fleet-cred-proxy.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def login_settings(conf, install_dir):
    """The ROOT_KEYS the login's own files set today (parsed, never sourced)."""
    out = {}
    for f in ([os.path.join(install_dir, "fleet.conf")] if install_dir else []) + [
            os.path.join(conf, "fleet.settings"), os.path.join(conf, "fleet.conf"), os.path.join(conf, "secrets.env")]:
        out.update({k: v for k, v in env_file(f).items() if k in ROOT_KEYS})
    return out


def settings_conf(login, conf, install_dir, adopt=False):
    """Write root's <LIB>/<login>.conf: on the first install (or --adopt) it takes
    the login's current values — an upstream / hub URL only when it is https to an
    allowed host, FLEET_CRED_ALLOW_HOSTS never (root adds that by hand). An
    existing one is kept as it is: a later line in the login's files changes
    nothing until root adopts it. True when the bytes changed."""
    path = root_conf_path(login)
    have = env_file(path) if os.path.isfile(path) else None
    if have is not None and not adopt:
        say("settings:", path, "(root's, kept)")
        return False
    vals = dict(have or {})
    m = proxy_mod()
    m.ALLOWED = m.allowed_hosts(vals.get("FLEET_CRED_ALLOW_HOSTS", ""))
    for k, v in sorted(login_settings(conf, install_dir).items()):
        if k == "FLEET_CRED_ALLOW_HOSTS":
            say("settings: NOT taken %s from the login (only root adds a host: edit %s)" % (k, path))
        elif k in URL_KEYS and not m.loopback_ok(v):
            say("settings: NOT taken %s=%s from the login (not https to an allowed host)" % (k, v))
        else:
            vals[k] = v
    body = ("# claude-fleet credsep (issue #2290) — root's settings for %s's credential proxy.\n"
            "# Only root writes this; the same keys in the login's own files are ignored.\n" % login
            + "".join("%s=%s\n" % (k, vals[k]) for k in ROOT_KEYS if vals.get(k)))
    changed = put_changed(path, body, 0o600, "root" if os.geteuid() == 0 else login)
    say("settings:", path, "(%s: %s)" % ("written" if changed else "current",
                                         ", ".join(k for k in ROOT_KEYS if vals.get(k)) or "no key"))
    return changed


def codex_homes(conf, home, ne=None):
    ne = ne if ne is not None else env_file(os.path.join(conf, "node.pub.env")) or env_file(os.path.join(conf, "node.env"))
    return ne.get("CCQUOTA_FLEET_CODEX_HOMES") or os.path.join(home, ".codex-accounts")


# ---- the role account ------------------------------------------------------------
def ensure_role():
    try:
        pwd.getpwnam(ROLE)
        return False
    except KeyError:
        pass
    if "FLEET_CREDSEP_ROLE" in os.environ:
        die("FLEET_CREDSEP_ROLE=%s does not exist (a seam names an existing user)" % ROLE)
    if MAC:
        used = {p.pw_uid for p in pwd.getpwall()} | {g.gr_gid for g in grp.getgrall()}
        free = [i for i in range(499, 449, -1) if i not in used]
        if not free:
            die("no free id in 450-499 for the role account")
        i = str(free[0])
        sh("dseditgroup", "-o", "create", "-i", i, "-r", "claude-fleet credentials", ROLE)
        sh("sysadminctl", "-addUser", ROLE, "-fullName", "claude-fleet credentials", "-UID", i, "-GID", i,
           "-shell", "/usr/bin/false", "-home", "/var/empty", "-roleAccount")
    else:
        sh("useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent",
           "--shell", "/usr/sbin/nologin", "--comment", "claude-fleet credentials", ROLE)
    return True


def drop_role():
    if "FLEET_CREDSEP_ROLE" in os.environ:
        return
    left = [d for d in (os.listdir(ROOT_BASE) if os.path.isdir(ROOT_BASE) else []) if not d.startswith(".")]
    if left:
        say("role: kept — still used by", ", ".join(left))
        return
    try:
        pwd.getpwnam(ROLE)
    except KeyError:
        return
    if MAC:
        sh("sysadminctl", "-deleteUser", ROLE, check=False)
        try:
            grp.getgrnam(ROLE)     # sysadminctl usually takes the group with it
            sh("dseditgroup", "-o", "delete", ROLE, check=False)
        except KeyError:
            pass
    else:
        sh("userdel", ROLE, check=False)
        sh("groupdel", ROLE, check=False, quiet=True)
    say("role: removed", ROLE)


# ---- the agent's service definition ----------------------------------------------
def agent_service(login, home):
    """→ dict(kind, path, label) of this login's ccquota agent, or None."""
    if MAC:
        p = os.path.join(DAEMON_DIR, "com.ccquota.agent.%s.plist" % login)
        if os.path.exists(p):
            return {"kind": "launchd-system", "path": p, "label": "com.ccquota.agent.%s" % login}
        p = os.path.join(home, "Library", "LaunchAgents", "com.ccquota.agent.plist")
        if os.path.exists(p):
            return {"kind": "launchd-gui", "path": p, "label": "com.ccquota.agent"}
        return None
    p = os.path.join(DAEMON_DIR, "ccquota-agent-%s.service" % login)
    if os.path.exists(p):
        return {"kind": "systemd-system", "path": p, "label": "ccquota-agent-%s.service" % login}
    if os.path.exists(os.path.join(home, ".config", "systemd", "user", "ccquota-agent.service")):
        return {"kind": "systemd-user", "path": os.path.join(home, ".config", "systemd", "user", "ccquota-agent.service"),
                "label": "ccquota-agent.service"}
    return None


def agent_argv(svc):
    """The agent's own command line (and PATH), from its service definition. A
    node-join install runs run-agent.sh, whose last line is the exec."""
    if svc["kind"].startswith("launchd"):
        with open(svc["path"], "rb") as f:
            pl = plistlib.load(f)
        prog = list(pl.get("ProgramArguments") or [pl.get("Program")])
        if any(k.endswith("TOKEN") for k in (pl.get("EnvironmentVariables") or {})):
            die("%s carries the node token in EnvironmentVariables — move it to node.env first "
                "(bin/fleet-hub-node.sh env --write), then install" % svc["path"])
    else:
        prog = []
        for line in open(svc["path"]):
            if line.startswith("ExecStart="):
                prog = shlex.split(line.split("=", 1)[1])
    runner = next((a for a in prog if a.endswith("run-agent.sh")), None)
    if not runner:
        return prog, ""
    argv, path = [], ""
    for line in open(runner):
        line = line.strip()
        m = re.match(r'^PATH="?([^"]*)"?$', line)
        if m:
            path = m.group(1)
        if line.startswith("exec "):
            argv = shlex.split(line[5:])
    if not argv or not os.path.isabs(argv[0]):
        die("cannot read the agent's command from %s" % runner)
    return argv, path


def launcher_cmd(mode, login=None):
    return [PY, "-I", os.path.join(LIB, "fleet-credsep-launch.py"), mode] + ([login] if login else [])


def agent_log(login):
    """Where the root-started agent's stdout/stderr go (issue #2296): launchd opens
    StandardOutPath AS ROOT and follows a symlink, so a log in the login's home is
    a root write the login aims (ln -sf /etc/sudoers ~/.ccquota/agent.log)."""
    return os.path.join(LOG_BASE, login, "agent.log")


def agent_log_dir(login):
    mkdir(LOG_BASE, 0o755, "root" if os.geteuid() == 0 else login)
    mkdir(os.path.join(LOG_BASE, login), 0o700, "root" if os.geteuid() == 0 else login)


def agent_dropin(login, unit):
    """The systemd drop-in that starts the agent through the launcher as root; a
    unit that logs to a file has it redirected under LOG_BASE (issue #2296)."""
    txt = ("# claude-fleet credsep (issue #1971)\n[Service]\nUser=root\nGroup=root\nExecStart=\nExecStart=%s\n"
           % " ".join(shlex.quote(c) for c in launcher_cmd("agent", login)))
    try:
        lines = open(unit).read().splitlines()
    except OSError:
        lines = []
    if any(re.match(r"Standard(Output|Error)=(file|append|truncate):", l.strip()) for l in lines):
        txt += "StandardOutput=append:%s\nStandardError=append:%s\n" % (agent_log(login), agent_log(login))
    return txt


def relog_agent(login):
    """An agent credsep starts as root whose log is still in the login's home
    (separated before issue #2296) → its log moves under LOG_BASE and it restarts.
    True when it rewrote something; a definition that is not credsep's is left."""
    if MAC:
        p = os.path.join(DAEMON_DIR, "com.ccquota.agent.%s.plist" % login)
        try:
            with open(p, "rb") as f:
                pl = plistlib.load(f)
        except (OSError, ValueError, plistlib.InvalidFileException):
            return False
        if pl.get("UserName") not in (None, "root") or \
                not any("fleet-credsep-launch" in str(x) for x in pl.get("ProgramArguments") or []):
            return False
        if pl.get("StandardOutPath") == pl.get("StandardErrorPath") == agent_log(login):
            return False
        was = pl.get("StandardOutPath") or pl.get("StandardErrorPath") or "-"
        agent_log_dir(login)
        pl["StandardOutPath"] = pl["StandardErrorPath"] = agent_log(login)
        put(p, plistlib.dumps(pl), 0o644, "root" if os.geteuid() == 0 else login)
        load_daemon(p, pl["Label"])
        say("agent: log %s → %s (root writes it; restarted)" % (was, agent_log(login)))
        return True
    unit = os.path.join(DAEMON_DIR, "ccquota-agent-%s.service" % login)
    dp = os.path.join(unit + ".d", "credsep.conf")
    if not os.path.isfile(dp):
        return False
    want = agent_dropin(login, unit)
    if open(dp).read() == want:
        return False
    agent_log_dir(login)
    put(dp, want, 0o644, "root" if os.geteuid() == 0 else login)
    load_daemon(unit, "ccquota-agent-%s.service" % login)
    say("agent: log → %s (root writes it; restarted)" % agent_log(login))
    return True


def relog(a):
    if not re.match(r"^[a-z0-9_][a-z0-9_.-]{0,31}$", a.login):
        die("bad login %r" % a.login, 2)
    if not relog_agent(a.login):
        say("agent: log of %s — nothing to move (not credsep's root agent, or already under %s)"
            % (a.login, os.path.join(LOG_BASE, a.login)))
    return 0


def in_home(path, base):
    """True when path (or what it resolves to) lies under the homes dir."""
    b = base.rstrip("/") + "/"
    return bool(path) and (path.startswith(b) or os.path.realpath(path).startswith(os.path.realpath(base) + "/"))


def rootlogs(a):
    """The doctor's `rootlog` row (issue #2296): every service the machine starts
    as root whose stdout/stderr file lies in a home — a symlink planted there
    turns root's open() onto any file. exit 0 OK, 1 WARN."""
    base = E("FLEET_CREDSEP_HOMES", "/Users" if MAC else "/home")
    n, bad = 0, []
    for name in sorted(os.listdir(DAEMON_DIR)) if os.path.isdir(DAEMON_DIR) else []:
        p = os.path.join(DAEMON_DIR, name)
        if MAC:
            if not name.endswith(".plist"):
                continue
            try:
                with open(p, "rb") as f:
                    pl = plistlib.load(f)
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
            if not isinstance(pl, dict) or pl.get("UserName") not in (None, "root"):
                continue
            n += 1
            label = pl.get("Label") or name[:-6]
            outs = {pl.get(k) for k in ("StandardOutPath", "StandardErrorPath")}
        else:
            if not name.endswith(".service"):
                continue
            user, so = "", {}
            for f in [p] + sorted(glob.glob(p + ".d/*.conf")):
                try:
                    for l in open(f):
                        m = re.match(r"\s*(User|StandardOutput|StandardError)=(.*)$", l)
                        if m and m.group(1) == "User":
                            user = m.group(2).strip()
                        elif m:
                            so[m.group(1)] = m.group(2).strip()
                except OSError:
                    pass
            if user not in ("", "root"):
                continue
            n += 1
            label = name
            outs = {v.split(":", 1)[1] for v in so.values() if re.match(r"(file|append|truncate):", v)}
        if any(x and in_home(x, base) for x in outs):
            m = re.match(r"(?:com\.ccquota\.agent\.|ccquota-agent-)([A-Za-z0-9_.-]+?)(?:\.service)?$", label)
            bad.append((label, m.group(1) if m else None))
    if bad:
        ours = [l for _, l in bad if l]
        other = [n for n, l in bad if not l]
        print("rootlog: WARN — %d root service(s) write a log in a home, where a symlink turns root's write onto "
              "any file: %s%s%s" % (len(bad), ", ".join(n for n, _ in bad),
              " — fix: sudo bash %s check --fix --login <login> for %s" % (os.path.join(HERE, "fleet-credsep.sh"),
                                                                          ", ".join(ours)) if ours else "",
              "; not the fleet's, move its log under /var/log by hand: %s" % ", ".join(other) if other else ""))
        return 1
    print("rootlog: OK — %d root service(s) in %s, none writes a log in a home" % (n, DAEMON_DIR))
    return 0


def plist(label, argv, out=None, throttle=None):
    d = {"Label": label, "ProgramArguments": argv, "RunAtLoad": True, "KeepAlive": True}
    if throttle:    # launchd waits 10 s by default before a KeepAlive restart
        d["ThrottleInterval"] = throttle
    if out:
        d["StandardOutPath"] = d["StandardErrorPath"] = out
    return plistlib.dumps(d)


def wait_gone(target, secs=25):
    """`launchctl bootout` returns once it has SIGTERMed the job, not once the job
    is gone: on 2026-10-07 m4's bootstrap came 4 ms after it, while the agent was
    still exiting, and launchd refused it (`37: Operation already in progress`,
    which launchctl prints as `Bootstrap failed: 5: Input/output error` — issue
    #2273). Wait until launchd no longer knows the label (its ExitTimeOut is 20 s)."""
    if DRY or not SVC:
        return
    end = time.time() + secs
    while time.time() < end:
        if subprocess.run(["launchctl", "print", target], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode:
            return
        time.sleep(0.2)


def load_daemon(path, label):
    if MAC:
        sh("launchctl", "bootout", "system/" + label, check=False, quiet=True)
        wait_gone("system/" + label)
        for i in range(BOOT_TRIES):     # and a bootstrap that still races it backs off
            last = i == BOOT_TRIES - 1
            if sh("launchctl", "bootstrap", "system", path, check=last, quiet=not last) == 0 or last:
                break
            time.sleep(1 + i)
            wait_gone("system/" + label, 5)
    else:
        sh("systemctl", "daemon-reload")
        sh("systemctl", "enable", "--now", label)
        sh("systemctl", "restart", label)


def unload_daemon(label):
    if MAC:
        sh("launchctl", "bootout", "system/" + label, check=False, quiet=True)
    else:
        sh("systemctl", "disable", "--now", label, check=False, quiet=True)


# ---- install ------------------------------------------------------------------------
def install(a):
    login, conf = a.login, os.path.abspath(a.conf_dir)
    shared = bool(getattr(a, "shared", False))
    pw = getpw(login)
    home = (getattr(a, "home", "") or (pw.pw_dir if getattr(pw, "sandbox", False) else os.environ["HOME"])) \
        if TEST else pw.pw_dir   # the sandbox's, never the real ~/.codex
    R, RUN = paths(login)
    if shared:
        RUN = SHARED_RUN
    CUR.clear()
    CUR.update(login=login, uid=pw.pw_uid, home=home, conf_dir=conf, role=ROLE,
               install_dir=os.path.abspath(a.install_dir or ""), codex_homes=codex_homes(conf, home))
    if os.path.lexists(os.path.join(conf, "credsep.json")) and os.path.isfile(os.path.join(R, "meta.json")):
        say("credsep: already separated —", R, "(refreshing the code copy and services)")
    created = ensure_role()
    say("role:", ROLE, "(created)" if created else "(exists)")
    mkdir(ROOT_BASE, 0o755, "root" if os.geteuid() == 0 else login)
    mkdir(R, 0o700, ROLE)
    for sub in ("accounts", "codex", "cred-proxy", "backup"):
        mkdir(os.path.join(R, sub), 0o700, ROLE)
    # 3. the code the role account runs: root's copy, never the login's checkout
    mkdir(LIB, 0o755, "root" if os.geteuid() == 0 else login)
    moved_code = False
    for f in ("fleet-credsep-launch.py", "fleet-cred-proxy.py"):
        with open(os.path.join(HERE, f), "rb") as src:
            moved_code |= put_changed(os.path.join(LIB, f), src.read(), 0o755, "root" if os.geteuid() == 0 else login)
    say("code:", LIB, "(updated)" if moved_code else "(current)")
    moved_code |= settings_conf(login, conf, a.install_dir, bool(getattr(a, "adopt", False)))

    # 4. the credentials
    n = 0
    acc = os.path.join(conf, "accounts")
    for d in sorted(os.listdir(acc)) if os.path.isdir(acc) else []:
        f = os.path.join(acc, d, ".credentials.json")
        if d.endswith(".hub") and SAFE.match(d[:-4]) and os.path.isfile(f):
            move(f, os.path.join(R, "accounts", d, ".credentials.json"), ROLE); n += 1
            MOVED.append([os.path.join(R, "accounts", d, ".credentials.json"), f])
            chown_tree(os.path.join(R, "accounts", d), ROLE)
    ne_path = os.path.join(conf, "node.env")
    ne = env_file(ne_path) if os.path.isfile(ne_path) and not os.path.islink(ne_path) else {}
    ch = codex_homes(conf, home, ne or None)
    CUR["codex_homes"] = ch
    for label, f in [("default", os.path.join(home, ".codex", "auth.json"))] + \
            [(d, os.path.join(ch, d, "auth.json")) for d in (sorted(os.listdir(ch)) if os.path.isdir(ch) else [])
             if SAFE.match(d)]:
        if os.path.isfile(f) and not os.path.islink(f) and hub_managed_codex(f):
            move(f, os.path.join(R, "codex", label, "auth.json"), ROLE); n += 1
            MOVED.append([os.path.join(R, "codex", label, "auth.json"), f])
            chown_tree(os.path.join(R, "codex", label), ROLE)
    say("credentials: %d moved into %s" % (n, R))
    if ne:
        pub = "".join("%s=%s\n" % (k, v) for k, v in ne.items() if not re.search(r"TOKEN|SECRET|PASSWORD", k))
        put(os.path.join(conf, "node.pub.env"),
            "# claude-fleet credsep (issue #1971) — node.env's lines WITHOUT the token; the token is in %s\n%s"
            % (R, pub), 0o600, login)
        move(ne_path, os.path.join(R, "node.env"), ROLE)
        MOVED.append([os.path.join(R, "node.env"), ne_path])
        if not DRY:
            os.symlink(os.path.join(R, "node.env"), ne_path)
            chown(ne_path, login, follow=False)
        say("node.env: moved —", ne_path, "→", os.path.join(R, "node.env"))
    elif os.path.islink(ne_path):
        say("node.env: already in the store")

    old = {}
    try:
        old = json.load(open(os.path.join(R, "meta.json")))
    except (OSError, ValueError):
        pass
    legacy = old.get("legacy_port") or 0
    if shared and old.get("mode") != "shared":
        CUR.update(mode="shared")
        legacy = join_state(login, conf, R) or legacy

    # 5 + 6. services
    svc = agent_service(login, home)
    meta = {"login": login, "uid": pw.pw_uid, "home": home, "conf_dir": conf,
            "install_dir": os.path.abspath(a.install_dir or ""), "role": ROLE,
            "codex_homes": ch, "installed": int(time.time()), "agent": svc}
    if shared:
        meta.update(mode="shared", legacy_port=legacy,
                    conf_prior=old.get("conf_prior") if "conf_prior" in old else conf_switch_on(login, conf, pw))
    if old.get("agent"):
        meta["agent"], meta["agent_argv"], meta["path"] = old["agent"], old.get("agent_argv"), old.get("path", "")
    elif svc:
        if svc["kind"] == "systemd-user":
            die("the agent runs as a systemd --user unit; move it to ccquota-agent-%s.service first" % login)
        meta["agent_argv"], meta["path"] = agent_argv(svc)
    CUR.update(meta)
    put(os.path.join(R, "meta.json"), json.dumps(meta, indent=1), 0o600, ROLE)

    plabel = "com.claude-fleet.credsep.%s" % login if MAC else "claude-fleet-credsep-%s.service" % login
    ppath = os.path.join(DAEMON_DIR, plabel + (".plist" if MAC else ""))
    if shared:
        # the machine's one proxy serves this login (issue #2217): its own goes
        if os.path.exists(ppath):
            unload_daemon(plabel)
            if not DRY:
                os.unlink(ppath)
            say("proxy: %s removed — the machine's shared proxy serves %s (old port %s kept for its sessions)"
                % (plabel, login, legacy or "-"))
        ppath = SHARED_PATH
    elif MAC:
        moved_svc = put_changed(ppath, plist(plabel, launcher_cmd("proxy", login), os.path.join(LOG_BASE, login + ".launch.log")),
                                0o644, "root" if os.geteuid() == 0 else login)
    else:
        moved_svc = put_changed(ppath, "[Unit]\nDescription=claude-fleet credential proxy for %s (issue #1971)\nAfter=network-online.target\n\n"
            "[Service]\nExecStart=%s\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
            % (login, " ".join(shlex.quote(c) for c in launcher_cmd("proxy", login))), 0o644,
            "root" if os.geteuid() == 0 else login)
    mkdir(LOG_BASE, 0o755, "root" if os.geteuid() == 0 else login)
    if shared:
        pass
    elif moved_code or moved_svc or not old.get("agent") and not old:
        # a restart keeps the port (the proxy re-reads cred-proxy/port), but cuts
        # requests in flight: only when something it runs actually changed
        load_daemon(ppath, plabel)
        say("proxy: %s (runs as %s) — (re)started" % (plabel, ROLE))
    else:
        say("proxy: %s — current, not restarted" % plabel)

    if meta.get("agent") and not old.get("agent"):
        s = meta["agent"]
        bk = os.path.join(R, "backup", os.path.basename(s["path"]))
        if not DRY:
            shutil.copy2(s["path"], bk)
        if s["kind"] == "launchd-system":
            with open(s["path"], "rb") as f:
                pl = plistlib.load(f)
            pl.pop("UserName", None); pl.pop("Program", None)
            pl["ProgramArguments"] = launcher_cmd("agent", login)
            agent_log_dir(login)
            pl["StandardOutPath"] = pl["StandardErrorPath"] = agent_log(login)
            put(s["path"], plistlib.dumps(pl), 0o644, "root" if os.geteuid() == 0 else login)
            load_daemon(s["path"], s["label"])
        elif s["kind"] == "launchd-gui":
            sh("launchctl", "bootout", "gui/%d/%s" % (pw.pw_uid, s["label"]), check=False, quiet=True)
            if not DRY:
                os.unlink(s["path"])
            dp = os.path.join(DAEMON_DIR, "com.ccquota.agent.%s.plist" % login)
            with open(s["path"] if DRY else bk, "rb") as f:
                pl = plistlib.load(f)
            pl["Label"] = "com.ccquota.agent.%s" % login
            pl.pop("Program", None)
            pl["ProgramArguments"] = launcher_cmd("agent", login)
            agent_log_dir(login)
            pl["StandardOutPath"] = pl["StandardErrorPath"] = agent_log(login)
            put(dp, plistlib.dumps(pl), 0o644, "root" if os.geteuid() == 0 else login)
            load_daemon(dp, pl["Label"])
        else:  # systemd-system: a drop-in replaces the start line and the user
            dd = s["path"] + ".d"
            mkdir(dd, 0o755, "root" if os.geteuid() == 0 else login)
            if "StandardOutput=" in agent_dropin(login, s["path"]):
                agent_log_dir(login)
            put(os.path.join(dd, "credsep.conf"), agent_dropin(login, s["path"]), 0o644,
                "root" if os.geteuid() == 0 else login)
            load_daemon(s["path"], s["label"])
        say("agent: %s now starts through the launcher (token down a pipe)" % s["label"])
    elif meta.get("agent") and (old.get("mode") == "shared") != shared:
        # its lease goes to the other proxy's control socket now (the launcher sets it)
        s = meta["agent"]
        load_daemon(s["path"] if s["kind"] != "launchd-gui" else
                    os.path.join(DAEMON_DIR, "com.ccquota.agent.%s.plist" % login),
                    s["label"] if s["kind"] != "launchd-gui" else "com.ccquota.agent.%s" % login)
        say("agent: %s restarted — its leases go to the %s proxy" % (s["label"], "shared" if shared else "login's"))
    elif not meta.get("agent"):
        say("agent: none on this login (no node) — only the files move")
    if meta.get("agent"):
        relog_agent(login)      # separated before issue #2296: its log leaves the home

    pool = pool_in(a.pool_src, R, conf, login) if getattr(a, "pool_src", "") else []

    prev = (record(conf) or {}).get("back") or {}
    back = {"files": sorted({tuple(m) for m in (prev.get("files") or []) + MOVED}),
            "agent": meta.get("agent"), "proxy": ppath}
    back["files"] = [list(m) for m in back["files"]]
    rec = {"separated": True, "root": R, "run": RUN, "role": ROLE, "lib": LIB,
           "since": (record(conf) or {}).get("since") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "back": back}
    if shared:
        rec["shared"] = True
    if pool or (record(conf) or {}).get("pool"):
        rec["pool"] = sorted(set(pool) | set((record(conf) or {}).get("pool") or []))
    put(os.path.join(conf, "credsep.json"), json.dumps(rec, indent=1) + "\n", 0o644, login)
    say("credsep: ON —", R, "(%s only%s)" % (ROLE, ", the machine's shared proxy" if shared else ""))


def adopt(a):
    """install --adopt (issue #2290): root takes the login's current upstream /
    hub settings into <LIB>/<login>.conf — after the person checked them — and
    restarts the proxy that reads them. Nothing else moves."""
    R = paths(a.login)[0]
    try:
        meta = json.load(open(os.path.join(R, "meta.json")))
    except (OSError, ValueError):
        die("%s is not separated (no %s/meta.json): install first" % (a.login, R), 3)
    if not settings_conf(a.login, os.path.abspath(a.conf_dir), a.install_dir or meta.get("install_dir", ""), True):
        return 0
    if meta.get("mode") == "shared":
        load_daemon(SHARED_PATH, SHARED_LABEL)
    else:
        plabel = "com.claude-fleet.credsep.%s" % a.login if MAC else "claude-fleet-credsep-%s.service" % a.login
        load_daemon(os.path.join(DAEMON_DIR, plabel + (".plist" if MAC else "")), plabel)
    say("proxy: restarted on root's settings")
    return 0


def put_changed(path, data, mode, owner):
    """put() only when the bytes differ; True when it wrote."""
    b = data if isinstance(data, bytes) else data.encode()
    try:
        with open(path, "rb") as f:
            if f.read() == b:
                return False
    except OSError:
        pass
    put(path, b, mode, owner)
    return True


def chown_tree(d, owner):
    if DRY:
        return
    for dp, dns, fns in os.walk(d):
        os.chmod(dp, 0o700)
        chown(dp, owner)
        for f in fns:
            chown(os.path.join(dp, f), owner)


# ---- uninstall ----------------------------------------------------------------------
def pool_in(src, R, conf, login):
    """A NEW login's share of the team pool (issue #2294 — fleet-login-new.sh
    --share-pool, the hub's every account op): each token file of <src> (the
    admin's accounts dir) is COPIED into the store, never the login's dir; the
    login gets a label marker (no credential) and the label's .conf (settings, no
    secret). The marker is `store:<label>`, not `hub:` — the token is a whole
    `claude setup-token` in the store, so the login's account judge reads the
    label as usable (a `hub:` label's lease file is what it checks, and that
    has no file here) and the picker names it; the proxy reads
    <store>/accounts/<label>, a session names the label. -> the labels. Uninstall puts each token at the login's path (the
    old share-pool layout); a failed --fresh install deletes them instead."""
    src = os.path.abspath(src)
    if not os.path.isdir(src):
        die("--pool-src: no pool at %s" % src, 2)
    acc = os.path.join(conf, "accounts")
    mkdir(acc, 0o700, login)
    labels = []
    for n in sorted(os.listdir(src)):
        f = os.path.join(src, n)
        if n.startswith(".") or n.endswith("~") or not os.path.isfile(f) or os.path.islink(f):
            continue
        if n.endswith(".conf"):
            if SAFE.match(n[:-5]):
                if DRY:
                    say("    would copy", f, "→", os.path.join(acc, n))
                else:
                    with open(f, "rb") as h:
                        put(os.path.join(acc, n), h.read(), 0o600, login)
            continue
        if not SAFE.match(n):
            say("pool: %s skipped (not a label name)" % n)
            continue
        with open(f, "rb") as h:
            first = h.readline().strip()
        if first.startswith(b"hub:"):
            # the admin's own label marker (a separated or hub-leased pool): no
            # credential to keep — the label travels, the hub leases it (C2)
            put(os.path.join(acc, n), first + b"\n", 0o600, login)
            labels.append(n)
            continue
        dst = os.path.join(R, "accounts", n)
        if DRY:
            say("    would copy", f, "→", dst)
        else:
            with open(f, "rb") as h:
                put(dst, h.read(), 0o600, ROLE)
        put(os.path.join(acc, n), "store:%s\n" % n, 0o600, login)
        MOVED.append([dst, os.path.join(acc, n)])
        labels.append(n)
    say("pool: %d account(s) from %s into %s — %s holds only the label markers"
        % (len(labels), src, os.path.join(R, "accounts"), acc))
    return labels


def pool_drop(R, labels):
    """Undo pool_in for a --fresh install that failed: the tokens were never at a
    login path, so they are deleted, not "moved back" into the login's reach."""
    for n in labels or []:
        f = os.path.join(R, "accounts", n)
        if SAFE.match(n) and os.path.isfile(f) and not DRY:
            os.unlink(f)


# macOS starts its own per-user agents (cfprefsd, lsd, trustd, secd, distnoted,
# contactsd …) the moment anything runs as a new login — fleet-login-new.sh's
# clone as it, in step 7 — so a login opened a minute ago is never process-free
# (claude-fleet#2210). They hold no credential and start no session: the fresh
# gate counts only what is not the OS's own.
OS_AGENT_DIRS = ("/System/", "/usr/libexec/", "/usr/sbin/")


def os_agent(cmd):
    return cmd.startswith(OS_AGENT_DIRS)


def fresh_gate(login, force):
    """--fresh (issue #2294): a login fleet-login-new.sh has JUST opened. The
    preflight's questions (is its proxy on, do its sessions all use it) have no
    subject yet — the install itself starts the proxy, before any session — so
    the one thing to make sure of is that it IS fresh: no process runs as it."""
    if DRY or not PREFLIGHT:
        return
    pw = getpw(login)
    r = subprocess.run(["ps", "-U", str(pw.pw_uid), "-o", "comm="], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, text=True)
    cmds = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    ours = [c for c in cmds if not os_agent(c)]
    if not ours:
        say("preflight: ok — %s is fresh (nothing runs as it%s): the proxy comes first, then its sessions"
            % (login, "" if not cmds else "; %d macOS per-user agent(s) only" % len(cmds)))
        return
    say("preflight: %s — not a fresh login: %d process(es) run as it (%s)"
        % (login, len(ours), ", ".join(sorted(set(os.path.basename(c) for c in ours))[:5])))
    if force:
        say("preflight: --force — going on anyway")
        return
    die("preflight refused: nothing was moved (install without --fresh runs the full preflight)", 6)


def uninstall(a):
    login, conf = a.login, os.path.abspath(a.conf_dir)
    pw = getpw(login)
    home = (getattr(a, "home", "") or (pw.pw_dir if getattr(pw, "sandbox", False) else os.environ["HOME"])) \
        if TEST else pw.pw_dir   # the sandbox's, never the real ~/.codex
    R, RUN = paths(login)
    try:
        meta = json.load(open(os.path.join(R, "meta.json")))
    except (OSError, ValueError):
        meta = {}
    rec = record(conf)
    if DRY and not rec and not meta:
        if os.path.lexists(R):
            # an install that stopped halfway leaves the store and no credsep.json
            # (2026-10-07 m4, issue #2273): the way back is in the store's meta.json
            say("credsep: HALF INSTALLED — %s is there but %s has no credsep.json (an install that stopped"
                % (R, conf))
            say("  halfway); the store is not readable here. Put it back, from the store's meta.json:")
            say("  sudo bash %s uninstall --login %s" % (os.path.join(HERE, "fleet-credsep.sh"), login))
            return 0
        say("credsep: not separated — nothing to undo (%s has no credsep.json)" % conf)
        return 0
    if DRY and not meta and rec:
        return uninstall_plan(login, conf, rec)
    plabel = "com.claude-fleet.credsep.%s" % login if MAC else "claude-fleet-credsep-%s.service" % login
    ppath = os.path.join(DAEMON_DIR, plabel + (".plist" if MAC else ""))
    shared = meta.get("mode") == "shared"
    # the agent first: it must stop handing leases to a proxy about to go
    s = meta.get("agent")
    if s:
        bk = os.path.join(R, "backup", os.path.basename(s["path"]))
        if s["kind"] == "launchd-system" and os.path.isfile(bk):
            put(s["path"], open(bk, "rb").read(), 0o644, "root" if os.geteuid() == 0 else login)
            load_daemon(s["path"], s["label"])
        elif s["kind"] == "launchd-gui" and os.path.isfile(bk):
            dl = "com.ccquota.agent.%s" % login
            unload_daemon(dl)
            dp = os.path.join(DAEMON_DIR, dl + ".plist")
            if os.path.exists(dp) and not DRY:
                os.unlink(dp)
            put(s["path"], open(bk, "rb").read(), 0o644, login)
            sh("launchctl", "bootstrap", "gui/%d" % pw.pw_uid, s["path"], check=False)
        elif s["kind"] == "systemd-system":
            dd = s["path"] + ".d"
            if os.path.exists(os.path.join(dd, "credsep.conf")) and not DRY:
                os.unlink(os.path.join(dd, "credsep.conf"))
                try:
                    os.rmdir(dd)
                except OSError:
                    pass
            load_daemon(s["path"], s["label"])
        say("agent: %s restored" % s["label"])
    if not shared:
        unload_daemon(plabel)
        if os.path.exists(ppath) and not DRY:
            os.unlink(ppath)
        say("proxy:", plabel, "removed")
    else:
        pool_out(R)
        leave_state(login, conf, R)
        conf_switch_back(login, conf, pw, meta.get("conf_prior") or {})
    # every credential back to the login's own path — the agent may have renewed them
    n = 0
    for f, dst in store_files(R, conf, home, meta.get("codex_homes") or codex_homes(conf, home)):
        mkdir(os.path.dirname(dst), 0o700, login)
        move(f, dst, login); n += 1
    ne_path = os.path.join(conf, "node.env")
    if os.path.isfile(os.path.join(R, "node.env")):
        if os.path.islink(ne_path) and not DRY:
            os.unlink(ne_path)
        move(os.path.join(R, "node.env"), ne_path, login)
        pub = os.path.join(conf, "node.pub.env")
        if os.path.exists(pub) and not DRY:
            os.unlink(pub)
        say("node.env: back at", ne_path)
    say("credentials: %d moved back" % n)
    for p in (os.path.join(conf, "credsep.json"), os.path.join(LOG_BASE, login + ".log"),
              os.path.join(LOG_BASE, login + ".launch.log"), root_conf_path(login),
              os.path.join(RUN_BASE, ".shared", "ignored." + login)):
        if os.path.exists(p) and not DRY:
            os.unlink(p)
    if not DRY:
        shutil.rmtree(os.path.join(LOG_BASE, login), ignore_errors=True)
    if not DRY and SOFT:
        # a rollback with a failed step keeps the store (backup/, meta.json) for
        # the person, under a name no reader takes for a separated login
        kept = "%s.rolledback-%s" % (R, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
        os.rename(R, kept)
        say("store: kept as", kept, "(a step failed — see below)")
    elif not DRY:
        shutil.rmtree(R, ignore_errors=True)
        shutil.rmtree(RUN, ignore_errors=True)
    if shared and not DRY and shared_rec():
        left = [m["login"] for m in shared_tenants()]
        shared_record(left)
        if not left:
            say("shared: no login left on it — `machine uninstall` stops the shared proxy")
    others = [d for d in (os.listdir(ROOT_BASE) if os.path.isdir(ROOT_BASE) else []) if not d.startswith(".")]
    if not others and not DRY and not SOFT:
        shutil.rmtree(LIB, ignore_errors=True)
        for d in (ROOT_BASE, RUN_BASE, LOG_BASE, os.path.dirname(LIB)):
            try:
                os.rmdir(d)        # only when empty: the last login leaves nothing behind
            except OSError:
                pass
    if SOFT:
        return 1
    drop_role()
    say("credsep: OFF — every file back where it was")
    return 0


def pool_out(R):
    """The machine's one copy back into a leaving tenant's store (issue #2311):
    every <kind>:<label> its index (<R>/cred-proxy/pool.json) names, as the file
    store_files() then moves to the login. -> how many."""
    POOL = {"claude": ".credentials.json", "codex": "auth.json"}
    ip = os.path.join(R, "cred-proxy", "pool.json")
    try:
        idx = json.load(open(ip))
    except (OSError, ValueError):
        return 0
    n = 0
    for ent, key in sorted(idx.items()) if isinstance(idx, dict) else []:
        kind, _, label = ent.partition(":")
        if kind not in POOL or not SAFE.match(label) or not re.match(r"^[0-9a-f]{32}$", str(key)):
            continue
        src = os.path.join(SHARED_DIR, "pool", kind, key, POOL[kind])
        if not os.path.isfile(src):
            continue
        dst = (os.path.join(R, "accounts", label + ".hub", POOL[kind]) if kind == "claude"
               else os.path.join(R, "codex", label, POOL[kind]))
        mkdir(os.path.dirname(dst), 0o700, ROLE)
        with open(src, "rb") as f:
            put(dst, f.read(), 0o600, ROLE)
        n += 1
    if not DRY:
        os.unlink(ip)
    say("pool: %d credential(s) back into %s" % (n, R))
    return n


def store_files(R, conf, home, ch):
    """[(store path, the login's path)] of every credential file in the store —
    the leased Claude credentials and the hub-managed Codex auth.json files."""
    out = []
    acc = os.path.join(R, "accounts")
    for d in sorted(os.listdir(acc)) if os.path.isdir(acc) else []:
        f = os.path.join(acc, d, ".credentials.json")
        if d.endswith(".hub") and SAFE.match(d[:-4]) and os.path.isfile(f):
            out.append((f, os.path.join(conf, "accounts", d, ".credentials.json")))
        elif SAFE.match(d) and not d.endswith(".conf") and os.path.isfile(os.path.join(acc, d)):
            out.append((os.path.join(acc, d), os.path.join(conf, "accounts", d)))   # a pool token (#2294)
    cx = os.path.join(R, "codex")
    for d in sorted(os.listdir(cx)) if os.path.isdir(cx) else []:
        f = os.path.join(cx, d, "auth.json")
        if SAFE.match(d) and os.path.isfile(f):
            out.append((f, os.path.join(home, ".codex", "auth.json") if d == "default"
                        else os.path.join(ch, d, "auth.json")))
    return out


# ---- preflight (issue #2273) ----------------------------------------------------------
def own_tool(pw, name):
    """The login's own copy of a fleet script (another login's install is not readable to it)."""
    own = os.path.join(pw.pw_dir, ".claude", "fleet", "bin", name)
    return own if os.path.isfile(own) and not TEST else os.path.join(HERE, name)


def preflight(login, conf):
    """-> [why not] for a login about to have its credentials moved. The order is
    the whole point (#2135): its proxy runs FIRST and every live session already
    talks to it, else the move takes the subscription from under them — m4,
    2026-10-07. And never under a running EPIC batch: its members are sessions
    on this login. Read AS the login, with the login's own scripts."""
    pw = getpw(login)
    why = []
    rc, line = as_login(pw, conf, ["/bin/bash", own_tool(pw, "fleet-cred-rollout.sh"), "status"])
    line = (line or "").strip().splitlines()[-1:] or [""]
    line = line[0]
    m = re.match(r"^(on|off) · (\S+) · sessions (\d+)/(\d+)$", line)
    if rc or not m:
        why.append("the proxy's status could not be read (%s)" % (line or "rc %d" % rc))
    else:
        sw, route, n, t = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
        if sw != "on":
            why.append("its credential proxy is off — first, as %s: fleet cred-proxy enable" % login)
        elif route in ("down", "-", "?"):
            why.append("its credential proxy is on but not running (route %s) — fleet cred-proxy status / doctor" % route)
        if n < t:
            why.append("%d of its %d live sessions do not talk to the proxy yet — they would lose the "
                       "subscription (fleet-account.sh migrate, or reopen them)" % (t - n, t))
    rc, out = as_login(pw, conf, ["/bin/bash", "-c", '. "$1" >/dev/null 2>&1; fleet_epic_running_fresh',
                                  "_", own_tool(pw, "fleet-lib.sh")])
    if rc == 0 and out.strip():
        why.append("an EPIC batch is running on it (%s) — wait for it to end" % out.strip())
    return why


def preflight_gate(logins, force):
    """Refuse (exit 6) when any login fails the preflight; --force goes on, and says so."""
    if DRY or not PREFLIGHT:
        return
    bad = [(l, w) for l, c in logins for w in preflight(l, c)]
    if not bad:
        say("preflight: ok — %s" % ", ".join(l for l, _ in logins))
        return
    for l, w in bad:
        say("preflight: %s — %s" % (l, w))
    if force:
        say("preflight: --force — going on anyway")
        return
    die("preflight refused: nothing was moved (fix the above, or --force)", 6)


# ---- rollback (issue #2273) -----------------------------------------------------------
def rollback_login(login, conf, home):
    """Put a login an install has just half-done back the way it was, from the
    store's meta.json (written from CUR when the install died before it did).
    -> True when every step held; else the store is kept and the steps to do by
    hand are printed."""
    global SOFT
    R = paths(login)[0]
    say("")
    say("rollback: %s — putting it back the way it was" % login)
    if not os.path.isdir(R):
        say("rollback: %s — nothing had moved yet" % login)
        return True
    mp = os.path.join(R, "meta.json")
    if not os.path.isfile(mp):
        m = dict(CUR) if CUR.get("login") == login else {"login": login, "conf_dir": conf, "home": home}
        put(mp, json.dumps(m, indent=1), 0o600, ROLE)
    SOFT = []
    try:
        uninstall(argparse.Namespace(login=login, conf_dir=conf, home=home if TEST else "",
                                     install_dir="", dry_run=False))
    except SystemExit as e:
        SOFT.append(str(e.code))
    except Exception as e:      # noqa: BLE001 — a rollback reports, it never stops halfway silently
        SOFT.append("%s: %s" % (type(e).__name__, e))
    fails, SOFT = SOFT, None
    if not fails:
        say("rollback: %s — rolled back, every file where it was" % login)
        return True
    manual_steps(login, conf, home, fails)
    return False


def manual_steps(login, conf, home, fails):
    """The way back by hand, from whatever is still in the store."""
    R = paths(login)[0]
    kept = sorted(d for d in (os.listdir(ROOT_BASE) if os.path.isdir(ROOT_BASE) else [])
                  if d.startswith(login + ".rolledback-"))
    S = os.path.join(ROOT_BASE, kept[-1]) if kept and not os.path.isdir(R) else R
    try:
        meta = json.load(open(os.path.join(S, "meta.json")))
    except (OSError, ValueError):
        meta = {}
    q = shlex.quote
    say("")
    say("rollback: %s — FAILED at: %s" % (login, " | ".join(fails)))
    say("Put it back by hand, as root, in this order (the store: %s):" % S)
    n = 0
    for f, dst in store_files(S, conf, home, meta.get("codex_homes") or codex_homes(conf, home)):
        n += 1
        say("  %d. mkdir -p %s && mv %s %s && chown %s %s && chmod 600 %s"
            % (n, q(os.path.dirname(dst)), q(f), q(dst), q(login), q(dst), q(dst)))
    ne = os.path.join(conf, "node.env")
    if os.path.isfile(os.path.join(S, "node.env")):
        n += 1
        say("  %d. rm -f %s && mv %s %s && chown %s %s && chmod 600 %s && rm -f %s"
            % (n, q(ne), q(os.path.join(S, "node.env")), q(ne), q(login), q(ne), q(ne),
               q(os.path.join(conf, "node.pub.env"))))
    s = meta.get("agent")
    if s:
        bk = os.path.join(S, "backup", os.path.basename(s["path"]))
        n += 1
        if s["kind"] == "launchd-system":
            say("  %d. cp %s %s && launchctl bootout system/%s; sleep 5; launchctl bootstrap system %s"
                % (n, q(bk), q(s["path"]), s["label"], q(s["path"])))
        elif s["kind"] == "launchd-gui":
            dp = os.path.join(DAEMON_DIR, "com.ccquota.agent.%s.plist" % login)
            say("  %d. launchctl bootout system/com.ccquota.agent.%s; rm -f %s; cp %s %s && chown %s %s && "
                "launchctl bootstrap gui/%s %s" % (n, login, q(dp), q(bk), q(s["path"]), q(login), q(s["path"]),
                                                   meta.get("uid", "<uid>"), q(s["path"])))
        else:
            say("  %d. rm -f %s && systemctl daemon-reload && systemctl restart %s"
                % (n, q(s["path"] + ".d/credsep.conf"), s["label"]))
    for k, line in sorted((meta.get("conf_prior") or {}).items()):
        n += 1
        say("  %d. as %s: bash ~/.claude/fleet/bin/fleet-conf.sh %s" % (
            n, login, "set-line %s %s" % (k, q(line)) if line else "drop-line %s" % k))
    if os.path.isdir(os.path.join(S, "cred-proxy")) and os.listdir(os.path.join(S, "cred-proxy")):
        n += 1
        say("  %d. cp -p %s/* %s/ && chown -R %s %s   (the proxy's key and passes)"
            % (n, q(os.path.join(S, "cred-proxy")), q(os.path.join(conf, "cred-proxy")), q(login),
               q(os.path.join(conf, "cred-proxy"))))
    n += 1
    say("  %d. rm -f %s, then check: bash ~/.claude/fleet/bin/fleet-credsep.sh status (as %s)"
        % (n, q(os.path.join(conf, "credsep.json")), login))


def uninstall_plan(login, conf, rec):
    """The uninstall dry run AS THE LOGIN: the store is the role account's, so
    the way back is read from credsep.json's `back` (paths only — issue #2135)."""
    back = rec.get("back") or {}
    R = rec.get("root") or paths(login)[0]
    say("credsep: uninstall --dry-run for %s (the store %s is not readable here: the way back is read" % (login, R))
    say("  from %s/credsep.json; run it under sudo for the store's own list)" % conf)
    s = back.get("agent")
    if s:
        say("  1. agent: %s back to its original definition (%s, kept in %s/backup/), restarted"
            % (s.get("label"), s.get("path"), R))
    else:
        say("  1. agent: none recorded — nothing to restore")
    say("  2. proxy: %s stopped and removed" % (back.get("proxy") or "com.claude-fleet.credsep.%s" % login))
    files = back.get("files") or []
    say("  3. credentials back to the login (%d recorded, plus any lease the agent renewed into the store since):" % len(files))
    for src, dst in files:
        say("       %s → %s" % (src, dst))
    say("  4. node.env a plain file again (0600, the login's); node.pub.env and credsep.json deleted")
    say("  5. %s and %s deleted; with no other login separated, also %s and the role account %s"
        % (R, rec.get("run") or paths(login)[1], rec.get("lib") or LIB, rec.get("role") or ROLE))
    say("  then: FLEET_CRED_SEPARATE=0 in fleet.conf [common] (or the next sync's credsep pass undoes it the same way)")
    return 0


# ---- the machine's shared proxy (issue #2217) ---------------------------------------
def join_state(login, conf, R):
    """-> the login's old proxy port. Its proxy's state follows it into the store:
    the signing key and held passes move (the sessions' credentials stay good —
    the shared proxy verifies them with the same key), binds / revocations /
    live sessions / trust are copied."""
    rec = record(conf) or {}
    src = None if rec.get("run") and not rec.get("shared") else os.path.join(conf, "cred-proxy")
    portf = os.path.join(rec["run"], "port") if src is None else os.path.join(src, "port")
    try:
        port = int(open(portf).read().strip())
    except (OSError, ValueError):
        port = 0
    dst = os.path.join(R, "cred-proxy")
    n = 0
    if src and os.path.isdir(src) and not os.path.islink(src):
        for f in STATE_MOVE + STATE_COPY:
            sp = os.path.join(src, f)
            if not os.path.isfile(sp) or os.path.islink(sp):
                continue
            if f in STATE_MOVE:
                move(sp, os.path.join(dst, f), ROLE)
                MOVED.append([os.path.join(dst, f), sp])
            else:
                with open(sp, "rb") as fh:
                    put(os.path.join(dst, f), fh.read(), 0o600, ROLE)
            n += 1
    say("proxy state: %d file(s) into %s%s" % (n, dst, " · old port %d" % port if port else ""))
    return port


def leave_state(login, conf, R):
    """The way back for join_state: the shared proxy's state for this login back
    into the login's own cred-proxy dir, so its own proxy picks up on the same
    port with the same key — a session minted before or during shared keeps going."""
    src, dst = os.path.join(R, "cred-proxy"), os.path.join(conf, "cred-proxy")
    if os.path.lexists(dst) and not os.path.isdir(dst):
        die("%s is not a directory" % dst)
    n = 0
    for f in STATE_MOVE + STATE_COPY:
        sp = os.path.join(src, f)
        if os.path.isfile(sp):
            if not n:
                mkdir(dst, 0o700, login)
            with open(sp, "rb") as fh:
                put(os.path.join(dst, f), fh.read(), 0o600, login)
            n += 1
    say("proxy state: %d file(s) back in %s" % (n, dst))


def as_login(pw, conf, argv):
    """Run argv AS the login (its own uid): root never edits a login's conf itself."""
    if DRY:
        say("    would run as %s:" % pw.pw_name, " ".join(shlex.quote(c) for c in argv))
        return 0, ""
    env = {"HOME": pw.pw_dir if not TEST else os.environ["HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "LANG": "en_US.UTF-8", "FLEET_CONF_DIR": conf}

    def drop():
        if os.geteuid() == 0:
            os.initgroups(pw.pw_name, pw.pw_gid)
            os.setgid(pw.pw_gid)
            os.setuid(pw.pw_uid)
    r = subprocess.run(argv, env=env, preexec_fn=drop, cwd="/", stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, text=True)
    return r.returncode, r.stdout


def conf_tool(pw, conf):
    """The login's own fleet-conf.sh (another login's install is not readable to it)."""
    return own_tool(pw, "fleet-conf.sh")


def conf_switch_on(login, conf, pw):
    """FLEET_CRED_PROXY=1 in the login's fleet.conf — its sessions must reach the
    subscription through the proxy now that the files are out of their reach.
    -> {KEY: the line it had, or "" for none} — what conf_switch_back restores,
    so disable leaves fleet.conf byte for byte (the rollout's own rule, #2134)."""
    if not os.path.isfile(os.path.join(conf, "fleet.conf")):
        say("switch: %s has no fleet.conf — FLEET_CRED_PROXY left as it is (fleet cred-proxy enable, as %s)"
            % (conf, login))
        return {}
    tool = conf_tool(pw, conf)
    rc, cur = as_login(pw, conf, ["/bin/bash", tool, "line", "FLEET_CRED_PROXY"])
    cur = cur.rstrip("\n") if rc == 0 else ""
    if "\n" in cur:
        say("switch: %s sets FLEET_CRED_PROXY on several lines — left as it is" % conf)
        return {}
    if cur.replace(" ", "") in ("exportFLEET_CRED_PROXY=1", "FLEET_CRED_PROXY=1"):
        say("switch: FLEET_CRED_PROXY=1 already")
        return {}
    rc, _ = as_login(pw, conf, ["/bin/bash", tool, "set-line", "FLEET_CRED_PROXY", "export FLEET_CRED_PROXY=1"])
    if rc:
        say("switch: could not write %s/fleet.conf — FLEET_CRED_PROXY left as it is" % conf)
        return {}
    say("switch: FLEET_CRED_PROXY=1 in %s/fleet.conf (was %s)" % (conf, cur or "absent"))
    return {"FLEET_CRED_PROXY": cur}


def conf_switch_back(login, conf, pw, prior):
    tool = conf_tool(pw, conf)
    for k, line in sorted(prior.items()):
        rc, _ = as_login(pw, conf, ["/bin/bash", tool, "set-line", k, line] if line else
                         ["/bin/bash", tool, "drop-line", k])
        say("switch: %s %s in %s/fleet.conf%s" % (k, "put back" if line else "removed", conf,
                                                    "" if rc == 0 else " — FAILED, fix it by hand"))


def shared_tenants():
    """-> [meta] of every login that joined the shared proxy."""
    out = []
    for d in sorted(os.listdir(ROOT_BASE)) if os.path.isdir(ROOT_BASE) else []:
        if d.startswith("."):
            continue
        try:
            m = json.load(open(os.path.join(ROOT_BASE, d, "meta.json")))
        except (OSError, ValueError):
            continue
        if m.get("mode") == "shared" and m.get("login") == d:
            out.append(m)
    return out


def code_version(path):
    import hashlib
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:12]
    except OSError:
        return ""


def shared_service():
    """The shared proxy's service definition → (changed?)."""
    owner = "root" if os.geteuid() == 0 else pwd.getpwuid(os.getuid()).pw_name
    mkdir(LOG_BASE, 0o755, owner)
    if MAC:
        # every login's sessions wait on this one process: back in 2 s, not launchd's 10
        return put_changed(SHARED_PATH, plist(SHARED_LABEL, launcher_cmd("shared"),
                                              os.path.join(LOG_BASE, "shared.launch.log"), throttle=2), 0o644, owner)
    return put_changed(SHARED_PATH, "[Unit]\nDescription=claude-fleet shared credential proxy (issue #2217)\n"
                       "After=network-online.target\n\n[Service]\nExecStart=%s\nRestart=always\nRestartSec=2\n\n"
                       "[Install]\nWantedBy=multi-user.target\n"
                       % " ".join(shlex.quote(c) for c in launcher_cmd("shared")), 0o644, owner)


def shared_record(logins):
    owner = "root" if os.geteuid() == 0 else pwd.getpwuid(os.getuid()).pw_name
    old = shared_rec() or {}
    put(SHARED_REC, json.dumps({
        "shared": True, "user": ROLE, "port": SHARED_PORT, "service": SHARED_LABEL, "run": SHARED_RUN,
        "lib": LIB, "version": code_version(os.path.join(LIB, "fleet-cred-proxy.py")),
        "logins": sorted(logins),
        "since": old.get("since") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, indent=1) + "\n",
        0o644, owner)


def shared_rec():
    try:
        return json.load(open(SHARED_REC))
    except (OSError, ValueError):
        return None


def machine_logins(spec):
    """--logins a,b → [(login, conf, home)]; `all` = every login with a fleet install."""
    names = [l for l in spec.split(",") if l] if spec and spec != "all" else [n for n, _, _ in fleet_logins()]
    out = []
    for n in names:
        if not re.match(r"^[a-z0-9_][a-z0-9_.-]{0,31}$", n):
            die("bad login %r" % n, 2)
        pw = getpw(n)
        home = pw.pw_dir
        out.append((n, os.path.join(home, ".config", "claude-fleet"), home))
    return out


def machine_install(a):
    """One sudo for the whole machine: every named login joins the shared proxy
    (its credentials move into the store, its own proxy goes, FLEET_CRED_PROXY=1),
    then the one service (re)starts with every tenant."""
    rows = machine_logins(a.logins)
    if not rows:
        die("machine install: no login to join (--logins a,b, or a login with ~/.claude/fleet)", 2)
    preflight_gate([(l, c) for l, c, _ in rows if not os.path.lexists(paths(l)[0])], a.force)
    created = ensure_role()
    say("role:", ROLE, "(created)" if created else "(exists)")
    pre = {"service": os.path.exists(SHARED_PATH), "rec": shared_rec() is not None}
    fresh = []      # the logins this run took into the store from nothing: a failure puts them back
    try:
        for login, conf, home in rows:
            say("")
            say("== %s" % login)
            if not os.path.lexists(paths(login)[0]):
                fresh.append((login, conf, home))
            install(argparse.Namespace(login=login, conf_dir=conf, home=home if TEST else "",
                                       install_dir=os.path.join(home, ".claude", "fleet"), shared=True))
            del MOVED[:]
        logins = sorted({m["login"] for m in shared_tenants()} | {r[0] for r in rows}) if not DRY else [r[0] for r in rows]
        shared_service()
        shared_record(logins)
        load_daemon(SHARED_PATH, SHARED_LABEL)
    except BaseException as e:  # noqa: B036 — die() is a SystemExit; any stop here is half a machine
        if DRY:
            raise
        return machine_rollback(rows, fresh, pre, e)
    say("")
    say("shared: ON — %s on 127.0.0.1:%d as %s, %d login(s): %s"
        % (SHARED_LABEL, SHARED_PORT, ROLE, len(logins), ", ".join(logins)))
    return 0


def machine_rollback(rows, fresh, pre, err):
    """machine install stopped halfway (issue #2273: launchd refused the agent's new
    definition and the login was left with its credentials in the store, its
    agent down). Every login this run took from nothing goes back, newest first;
    a shared service this run created goes too. -> 1, or 5 when a step of the
    way back failed and its manual steps were printed."""
    del MOVED[:]
    why = err.code if isinstance(err, SystemExit) else "%s: %s" % (type(err).__name__, err)
    say("")
    say("machine install: FAILED (%s) — rolling back %d login(s): %s"
        % (why, len(fresh), ", ".join(l for l, _, _ in fresh) or "none"))
    ok = True
    for login, conf, home in reversed(fresh):
        ok = rollback_login(login, conf, home) and ok
    if not pre["service"] and os.path.exists(SHARED_PATH):
        unload_daemon(SHARED_LABEL)
        os.unlink(SHARED_PATH)
        say("shared: %s removed (this run had made it)" % SHARED_LABEL)
    left = [m["login"] for m in shared_tenants()]
    if not pre["rec"] and not left and os.path.exists(SHARED_REC):
        os.unlink(SHARED_REC)
    elif shared_rec():
        shared_record(left)
    for login, _, _ in rows:
        if login not in [f[0] for f in fresh]:
            say("note: %s was in the store before this run — left as it is (`uninstall --login %s` takes it out)"
                % (login, login))
    say("")
    if ok:
        say("machine install: rolled back — every login this run touched is as it was; nothing is separated")
        return 1
    say("machine install: rollback INCOMPLETE — do the steps above by hand, then `fleet-credsep.sh status`")
    return 5


def machine_uninstall(a):
    """The way back: the shared service goes first (each login's own proxy then
    takes its old port back), then every tenant leaves — credentials, proxy
    state and the FLEET_CRED_PROXY line back where they were."""
    unload_daemon(SHARED_LABEL)
    if os.path.exists(SHARED_PATH) and not DRY:
        os.unlink(SHARED_PATH)
    say("shared: %s stopped and removed" % SHARED_LABEL)
    if DRY:
        for d in sorted(os.listdir(ROOT_BASE)) if os.path.isdir(ROOT_BASE) else []:
            if d.startswith(".") or ".rolledback-" in d:
                continue
            try:
                open(os.path.join(ROOT_BASE, d, "meta.json")).close()
            except PermissionError:
                say("== %s: a store is there, not readable here — under sudo it is put back the same way" % d)
            except OSError:
                pass
    for m in shared_tenants():
        say("")
        say("== %s" % m["login"])
        uninstall(argparse.Namespace(login=m["login"], conf_dir=m["conf_dir"], home=m.get("home", ""),
                                     install_dir="", dry_run=DRY))
    # last: the pool (issue #2311) is read by every tenant's uninstall above
    if not DRY:
        for p in (SHARED_REC, os.path.join(LOG_BASE, "shared.log"), os.path.join(LOG_BASE, "shared.launch.log")):
            if os.path.exists(p):
                os.unlink(p)
        shutil.rmtree(SHARED_DIR, ignore_errors=True)
        shutil.rmtree(SHARED_RUN, ignore_errors=True)
    say("")
    say("shared: OFF — every login back on its own proxy")
    return 0


def machine_refresh(a):
    """Follow stable: the root-owned code copy from this install; the service
    restarts only when the bytes changed."""
    if not shared_rec():
        say("shared: off — nothing to refresh")
        return 3
    owner = "root" if os.geteuid() == 0 else pwd.getpwuid(os.getuid()).pw_name
    moved = False
    for f in ("fleet-credsep-launch.py", "fleet-cred-proxy.py"):
        with open(os.path.join(HERE, f), "rb") as src:
            moved |= put_changed(os.path.join(LIB, f), src.read(), 0o755, owner)
    for m in shared_tenants():
        moved |= settings_conf(m["login"], m["conf_dir"], m.get("install_dir", ""))
    moved |= shared_service()
    shared_record([m["login"] for m in shared_tenants()])
    for m in shared_tenants():
        relog_agent(m["login"])     # separated before issue #2296
    if moved:
        load_daemon(SHARED_PATH, SHARED_LABEL)
    say("shared: %s — version %s" % ("refreshed, restarted" if moved else "current",
                                      code_version(os.path.join(LIB, "fleet-cred-proxy.py"))))
    return 0


def machine_status(a):
    """Anyone: is this machine on the shared proxy, as whom, which logins, the
    version against this install's — from the record and the run dir (no ctl)."""
    rec = shared_rec()
    if not rec:
        out = {"shared": False, "machine_logins": [n for n, _, _ in fleet_logins()]}
    else:
        out = dict(rec)
        for k in ("port", "pid"):
            try:
                out["live_" + k] = int(open(os.path.join(rec.get("run") or SHARED_RUN, k)).read().strip())
            except (OSError, ValueError):
                out["live_" + k] = None
        try:
            out["live_version"] = open(os.path.join(rec.get("run") or SHARED_RUN, "version")).read().strip()
        except OSError:
            out["live_version"] = ""
        out["install_version"] = code_version(os.path.join(HERE, "fleet-cred-proxy.py"))
        out["machine_logins"] = [n for n, _, _ in fleet_logins()]
    if a.json:
        print(json.dumps(out))
    elif not rec:
        print("per-login (no shared proxy on this machine)")
    else:
        print("shared · %s · %d login(s) · 127.0.0.1:%s · version %s%s"
              % (rec.get("user"), len(rec.get("logins") or []), out["live_port"] or "down", out["live_version"] or "-",
                 "" if out["live_version"] == out["install_version"] else " (this install: %s)" % out["install_version"]))
    return 0 if rec else 3


# ---- every login on the machine -----------------------------------------------------
def fleet_logins():
    """-> [(login, home, its fleet-credsep.sh)] of every login with a fleet
    install under the homes dir (a home we cannot look into is listed too)."""
    homes = E("FLEET_CREDSEP_HOMES", "/Users" if MAC else "/home")
    rows = []
    users = [(p.pw_name, p.pw_dir) for p in pwd.getpwall()]
    if os.environ.get("FLEET_CREDSEP_USERS"):       # selftest seam: `name:home` per line
        users = [tuple(l.strip().split(":", 1)) for l in open(os.environ["FLEET_CREDSEP_USERS"]) if ":" in l]
    for name, pdir in sorted(set(users)):
        tool = os.path.join(pdir, ".claude", "fleet", "bin", "fleet-credsep.sh")
        if os.path.dirname(pdir.rstrip("/")) != homes.rstrip("/"):
            continue
        if not os.path.isfile(tool):
            try:
                os.stat(tool)
            except PermissionError:
                pass            # a home we cannot look into: listed, state unknown
            except OSError:
                continue
        rows.append((name, pdir, tool))
    return rows


def plan(a):
    """Every login with a fleet install here: its state and the exact commands —
    the dry run, the ONE sudo to type, the checks, the way back (issue #2135).
    Reads, never writes; another login's conf may be unreadable (state `?`)."""
    homes = E("FLEET_CREDSEP_HOMES", "/Users" if MAC else "/home")
    me = pwd.getpwuid(os.getuid()).pw_name
    rows = fleet_logins()
    if not rows:
        say("credsep plan: no login under %s has ~/.claude/fleet" % homes)
        return 3
    say("credsep plan — %d login(s) under %s; the dry runs change nothing, `sudo` is the one line you type" % (len(rows), homes))
    for name, home, tool in rows:
        conf = os.path.join(home, ".config", "claude-fleet")
        try:
            rec = json.load(open(os.path.join(conf, "credsep.json")))
            state = "separated since %s" % rec.get("since", "?")
        except FileNotFoundError:
            state = "not separated" if os.access(conf, os.X_OK) else "? (conf not readable as %s)" % me
        except (OSError, ValueError):
            state = "? (conf not readable as %s)" % me
        q = shlex.quote(tool)
        as_ = "" if name == me else "sudo -u %s env HOME=%s " % (name, shlex.quote(home))
        say("")
        say("%s — %s" % (name, state))
        say("  dry run     %sbash %s install --dry-run" % (as_, q))
        say("  separate    sudo bash %s install --login %s" % (q, name))
        say("  read        %sbash %s status ; %sbash %s check" % (as_, q, as_, q))
        say("  way back    %sbash %s uninstall --dry-run   (then: sudo bash %s uninstall --login %s)"
            % (as_, q, q, name))
    say("")
    say("then FLEET_CRED_SEPARATE=1 in each login's fleet.conf [common] so the sync keeps it (0 + sync = the way back)")
    return 0


# ---- the login's side -------------------------------------------------------------
def record(conf):
    try:
        return json.load(open(os.path.join(conf, "credsep.json")))
    except (OSError, ValueError):
        return None


def status(a):
    rec = record(a.conf_dir)
    out = {"separated": bool(rec), **(rec or {})}
    if rec:
        try:
            out["port"] = int(open(os.path.join(rec["run"], "port")).read().strip())
        except (OSError, ValueError):
            out["port"] = None
    if a.json:
        print(json.dumps(out))
    else:
        print("separated · %s · %s · port %s" % (rec["root"], rec["role"], out["port"]) if rec else "not separated")
    return 0 if rec else 3


def leftovers(conf, home, rec):
    """Credential files still at a login path (a leak the doctor names)."""
    out = []
    acc = os.path.join(conf, "accounts")
    for d in sorted(os.listdir(acc)) if os.path.isdir(acc) else []:
        f = os.path.join(acc, d, ".credentials.json")
        if d.endswith(".hub") and os.path.isfile(f):
            out.append(f)
    ch = codex_homes(conf, home)
    for f in [os.path.join(home, ".codex", "auth.json")] + \
            [os.path.join(ch, d, "auth.json") for d in (os.listdir(ch) if os.path.isdir(ch) else [])]:
        if os.path.isfile(f) and hub_managed_codex(f):
            out.append(f)
    for n in (rec or {}).get("pool") or []:
        f = os.path.join(acc, n)
        try:
            first = open(f).readline().strip()
        except (OSError, UnicodeDecodeError):
            continue
        if SAFE.match(n) and first and not first.startswith(("store:", "hub:")):
            out.append(f)       # a pool label holds its token at the login path again (#2294)
    ne = os.path.join(conf, "node.env")
    if os.path.isfile(ne) and os.access(ne, os.R_OK):
        out.append(ne)
    return out


def denied(path):
    """True when THIS process cannot read path (the point of the store)."""
    try:
        if os.path.isdir(path):
            os.listdir(path)
        else:
            open(path, "rb").close()
        return False
    except PermissionError:
        return True
    except OSError:
        return True


def check(a):
    """One doctor line: credsep: OK|WARN|INFO — … ; exit 0 OK/INFO, 1 WARN."""
    conf = a.conf_dir
    home = os.path.expanduser("~")
    rec = record(conf)
    want = os.environ.get("FLEET_CRED_SEPARATE", "0") == "1"
    if not rec:
        if want:
            print("credsep: WARN — FLEET_CRED_SEPARATE=1 but this login is not separated: its sessions can read "
                  "the leased credentials and node.env. Install (needs sudo once): bash %s/fleet-credsep.sh install"
                  % HERE)
            return 1
        print("credsep: INFO — off (FLEET_CRED_SEPARATE=0): credentials in this login's own files, as before")
        return 0
    R = rec["root"]
    bad = [p for p in (R, os.path.join(R, "node.env"), os.path.join(R, "accounts")) if not denied(p)]
    left = leftovers(conf, home, rec)
    port = None
    try:
        port = int(open(os.path.join(rec["run"], "port")).read().strip())
    except (OSError, ValueError):
        pass
    if bad:
        print("credsep: WARN — this login CAN read %s: the store is not separated (owner/mode?)" % ", ".join(bad))
        return 1
    if left:
        print("credsep: WARN — separated, but credentials are back at login paths: %s" % ", ".join(left[:4]))
        return 1
    if not port:
        print("credsep: WARN — separated, but the proxy is not running (no %s/port): sessions have no subscription"
              % rec["run"])
        return 1
    note = ""
    if subprocess.run(["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        note = " · note: this login has password-less sudo, which reaches any file"
    if not want and not rec.get("shared"):
        print("credsep: WARN — FLEET_CRED_SEPARATE=0 but this login is still separated; uninstall: bash "
              "%s/fleet-credsep.sh uninstall" % HERE)
        return 1
    me = pwd.getpwuid(os.getuid()).pw_name
    rconf = os.path.join(rec.get("lib") or LIB, me + ".conf")
    if not os.path.exists(rconf):
        print("credsep: WARN — separated, but root's proxy settings %s are not written yet: the proxy has no "
              "upstream / hub setting beyond its defaults. Re-run (sudo): bash %s/fleet-credsep.sh %s"
              % (rconf, HERE, "machine refresh" if rec.get("shared") else "install"))
        return 1
    try:
        ign = [l.split(" ", 1) for l in open(os.path.join(rec["run"], "ignored." + me)).read().splitlines() if l]
    except OSError:
        ign = []
    if ign:
        print("credsep: WARN — the proxy ignored %s (only root's %s sets these, issue #2290). If the change is "
              "yours: sudo bash %s/fleet-credsep.sh install --adopt; otherwise delete the line(s)"
              % (", ".join("%s from %s" % (k, f) for k, f in ign[:4]), rconf, HERE))
        return 1
    print("credsep: OK — %s unreadable here (Permission denied), %sproxy on 127.0.0.1:%d as %s%s"
          % (R, "the machine's shared " if rec.get("shared") else "", port, rec["role"], note))
    return 0


def main():
    global DRY
    ap = argparse.ArgumentParser(prog="fleet-credsep.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for n in ("install", "uninstall"):
        p = sub.add_parser(n)
        p.add_argument("--login", required=True)
        p.add_argument("--conf-dir", required=True)
        p.add_argument("--install-dir", default="")
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--force", action="store_true")
        p.add_argument("--adopt", action="store_true")
        if n == "install":
            p.add_argument("--fresh", action="store_true")   # a login just opened (#2294)
            p.add_argument("--pool-src", default="")         # with --fresh: the team pool, into the store
    s = sub.add_parser("status"); s.add_argument("--conf-dir", required=True); s.add_argument("--json", action="store_true")
    c = sub.add_parser("check"); c.add_argument("--conf-dir", required=True)
    rl = sub.add_parser("relog")
    rl.add_argument("--login", required=True)
    rl.add_argument("--conf-dir", default="")
    rl.add_argument("--install-dir", default="")
    rl.add_argument("--dry-run", action="store_true")
    sub.add_parser("rootlogs")
    sub.add_parser("role")      # the role account alone (fleet-node-install.sh, #2330)
    pl = sub.add_parser("plan"); pl.add_argument("--bin", default=HERE)
    mc = sub.add_parser("machine")
    mc.add_argument("verb", choices=("install", "uninstall", "refresh", "status"))
    mc.add_argument("--logins", default="all")
    mc.add_argument("--dry-run", action="store_true")
    mc.add_argument("--force", action="store_true")
    mc.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.cmd == "plan":
        return plan(a)
    if a.cmd == "rootlogs":
        return rootlogs(a)
    if a.cmd == "role":
        if os.geteuid() != 0 and not TEST:
            die("role needs root (sudo fleet node install runs it)", 2)
        print("role: %s %s" % (ROLE, "created" if ensure_role() else "exists"))
        return 0
    if a.cmd == "relog":
        DRY = a.dry_run
        if os.geteuid() != 0 and not TEST and not DRY:
            die("relog needs root (bin/fleet-credsep.sh check --fix runs it through sudo -n)", 2)
        return relog(a)
    if a.cmd == "machine":
        if a.verb == "status":
            return machine_status(a)
        DRY = a.dry_run
        if os.geteuid() != 0 and not TEST and not DRY:
            die("machine %s needs root (bin/fleet-credsep.sh machine runs it through sudo)" % a.verb, 2)
        return {"install": machine_install, "uninstall": machine_uninstall, "refresh": machine_refresh}[a.verb](a)
    if a.cmd in ("install", "uninstall"):
        DRY = a.dry_run
        if not re.match(r"^[a-z0-9_][a-z0-9_.-]{0,31}$", a.login):
            die("bad login %r" % a.login, 2)
        if os.geteuid() != 0 and not TEST and not DRY:
            die("%s needs root (bin/fleet-credsep.sh runs it through sudo -n)" % a.cmd, 2)
        if not (MAC or sys.platform.startswith("linux")):
            die("only macOS and Linux", 2)
        if a.cmd == "uninstall":
            return uninstall(a)
        if a.adopt:
            return adopt(a)
        if a.pool_src and not a.fresh:
            die("--pool-src is for a login just opened (--fresh): an existing login's own pool stays its own", 2)
        fresh = not DRY and not os.path.lexists(paths(a.login)[0])
        if fresh and a.fresh:
            fresh_gate(a.login, a.force)
        elif fresh:
            preflight_gate([(a.login, os.path.abspath(a.conf_dir))], a.force)
        try:
            return install(a)
        except BaseException as e:  # noqa: B036
            if not fresh:
                raise
            say("install: FAILED (%s) — rolling back %s" % (
                e.code if isinstance(e, SystemExit) else "%s: %s" % (type(e).__name__, e), a.login))
            pw = getpw(a.login)
            home = (pw.pw_dir if getattr(pw, "sandbox", False) else os.environ["HOME"]) if TEST else pw.pw_dir
            if a.pool_src:
                pool_drop(paths(a.login)[0], [m[0].rsplit("/", 1)[1] for m in MOVED
                                             if os.path.dirname(m[0]) == os.path.join(paths(a.login)[0], "accounts")])
            if rollback_login(a.login, os.path.abspath(a.conf_dir), home):
                say("install: rolled back — %s is as it was; nothing is separated" % a.login)
                return 1
            return 5
    return status(a) if a.cmd == "status" else check(a)


if __name__ == "__main__":
    sys.exit(main() or 0)
