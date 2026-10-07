#!/usr/bin/env python3
"""fleet-credsep.py — keep a trusted login's credentials where its sessions
cannot read them (issue #1971, EPIC #1967 C4). bin/fleet-credsep.sh is the
front; install / uninstall run as ROOT (it calls them through `sudo -n`).

    install   --login L --conf-dir C --install-dir I [--dry-run]
    uninstall --login L --conf-dir C [--dry-run]
    status    --conf-dir C [--json]                 (as the login)
    check     --conf-dir C                          (as the login: the doctor row)

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
  7. C/credsep.json — the login-readable record that says "separated" (no secret)

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
FLEET_CREDSEP_TEST=1 (allow a non-root install into the sandbox).
"""
import argparse, grp, json, os, plistlib, pwd, re, shlex, shutil, subprocess, sys, time

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

DRY = False


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
        die("%s → exit %d: %s" % (" ".join(cmd), r.returncode, r.stdout.strip()[-300:]))
    if r.stdout.strip() and not quiet and r.returncode:
        say("   ", r.stdout.strip()[-300:])
    return r.returncode


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
    """Write whole (same-dir rename), then mode + owner."""
    if DRY:
        say("    would write", path)
        return
    tmp = "%s.credsep.%d" % (path, os.getpid())
    with open(tmp, "wb") as f:
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


def launcher_cmd(mode, login):
    return [PY, "-I", os.path.join(LIB, "fleet-credsep-launch.py"), mode, login]


def plist(label, argv, out=None):
    d = {"Label": label, "ProgramArguments": argv, "RunAtLoad": True, "KeepAlive": True}
    if out:
        d["StandardOutPath"] = d["StandardErrorPath"] = out
    return plistlib.dumps(d)


def load_daemon(path, label):
    if MAC:
        sh("launchctl", "bootout", "system/" + label, check=False, quiet=True)
        sh("launchctl", "bootstrap", "system", path)
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
    pw = pwd.getpwnam(login)
    home = os.environ["HOME"] if TEST else pw.pw_dir   # the sandbox's, never the real ~/.codex
    R, RUN = paths(login)
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

    # 4. the credentials
    n = 0
    acc = os.path.join(conf, "accounts")
    for d in sorted(os.listdir(acc)) if os.path.isdir(acc) else []:
        f = os.path.join(acc, d, ".credentials.json")
        if d.endswith(".hub") and SAFE.match(d[:-4]) and os.path.isfile(f):
            move(f, os.path.join(R, "accounts", d, ".credentials.json"), ROLE); n += 1
            chown_tree(os.path.join(R, "accounts", d), ROLE)
    ne_path = os.path.join(conf, "node.env")
    ne = env_file(ne_path) if os.path.isfile(ne_path) and not os.path.islink(ne_path) else {}
    ch = codex_homes(conf, home, ne or None)
    for label, f in [("default", os.path.join(home, ".codex", "auth.json"))] + \
            [(d, os.path.join(ch, d, "auth.json")) for d in (sorted(os.listdir(ch)) if os.path.isdir(ch) else [])
             if SAFE.match(d)]:
        if os.path.isfile(f) and not os.path.islink(f) and hub_managed_codex(f):
            move(f, os.path.join(R, "codex", label, "auth.json"), ROLE); n += 1
            chown_tree(os.path.join(R, "codex", label), ROLE)
    say("credentials: %d moved into %s" % (n, R))
    if ne:
        pub = "".join("%s=%s\n" % (k, v) for k, v in ne.items() if not re.search(r"TOKEN|SECRET|PASSWORD", k))
        put(os.path.join(conf, "node.pub.env"),
            "# claude-fleet credsep (issue #1971) — node.env's lines WITHOUT the token; the token is in %s\n%s"
            % (R, pub), 0o600, login)
        move(ne_path, os.path.join(R, "node.env"), ROLE)
        if not DRY:
            os.symlink(os.path.join(R, "node.env"), ne_path)
            chown(ne_path, login, follow=False)
        say("node.env: moved —", ne_path, "→", os.path.join(R, "node.env"))
    elif os.path.islink(ne_path):
        say("node.env: already in the store")

    # 5 + 6. services
    svc = agent_service(login, home)
    meta = {"login": login, "uid": pw.pw_uid, "home": home, "conf_dir": conf,
            "install_dir": os.path.abspath(a.install_dir or ""), "role": ROLE,
            "codex_homes": ch, "installed": int(time.time()), "agent": svc}
    old = {}
    try:
        old = json.load(open(os.path.join(R, "meta.json")))
    except (OSError, ValueError):
        pass
    if old.get("agent"):
        meta["agent"], meta["agent_argv"], meta["path"] = old["agent"], old.get("agent_argv"), old.get("path", "")
    elif svc:
        if svc["kind"] == "systemd-user":
            die("the agent runs as a systemd --user unit; move it to ccquota-agent-%s.service first" % login)
        meta["agent_argv"], meta["path"] = agent_argv(svc)
    put(os.path.join(R, "meta.json"), json.dumps(meta, indent=1), 0o600, ROLE)

    plabel = "com.claude-fleet.credsep.%s" % login if MAC else "claude-fleet-credsep-%s.service" % login
    ppath = os.path.join(DAEMON_DIR, plabel + (".plist" if MAC else ""))
    if MAC:
        moved_svc = put_changed(ppath, plist(plabel, launcher_cmd("proxy", login), os.path.join(LOG_BASE, login + ".launch.log")),
                                0o644, "root" if os.geteuid() == 0 else login)
    else:
        moved_svc = put_changed(ppath, "[Unit]\nDescription=claude-fleet credential proxy for %s (issue #1971)\nAfter=network-online.target\n\n"
            "[Service]\nExecStart=%s\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n"
            % (login, " ".join(shlex.quote(c) for c in launcher_cmd("proxy", login))), 0o644,
            "root" if os.geteuid() == 0 else login)
    mkdir(LOG_BASE, 0o755, "root" if os.geteuid() == 0 else login)
    if moved_code or moved_svc or not old.get("agent") and not old:
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
            put(s["path"], plistlib.dumps(pl), 0o644, "root" if os.geteuid() == 0 else login)
            load_daemon(s["path"], s["label"])
        elif s["kind"] == "launchd-gui":
            sh("launchctl", "bootout", "gui/%d/%s" % (pw.pw_uid, s["label"]), check=False, quiet=True)
            if not DRY:
                os.unlink(s["path"])
            dp = os.path.join(DAEMON_DIR, "com.ccquota.agent.%s.plist" % login)
            with open(bk, "rb") as f:
                pl = plistlib.load(f)
            pl["Label"] = "com.ccquota.agent.%s" % login
            pl.pop("Program", None)
            pl["ProgramArguments"] = launcher_cmd("agent", login)
            put(dp, plistlib.dumps(pl), 0o644, "root" if os.geteuid() == 0 else login)
            load_daemon(dp, pl["Label"])
        else:  # systemd-system: a drop-in replaces the start line and the user
            dd = s["path"] + ".d"
            mkdir(dd, 0o755, "root" if os.geteuid() == 0 else login)
            put(os.path.join(dd, "credsep.conf"),
                "# claude-fleet credsep (issue #1971)\n[Service]\nUser=root\nGroup=root\nExecStart=\nExecStart=%s\n"
                % " ".join(shlex.quote(c) for c in launcher_cmd("agent", login)), 0o644,
                "root" if os.geteuid() == 0 else login)
            load_daemon(s["path"], s["label"])
        say("agent: %s now starts through the launcher (token down a pipe)" % s["label"])
    elif not meta.get("agent"):
        say("agent: none on this login (no node) — only the files move")

    put(os.path.join(conf, "credsep.json"),
        json.dumps({"separated": True, "root": R, "run": RUN, "role": ROLE, "lib": LIB,
                    "since": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, indent=1) + "\n", 0o644, login)
    say("credsep: ON —", R, "(%s only)" % ROLE)


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
def uninstall(a):
    login, conf = a.login, os.path.abspath(a.conf_dir)
    pw = pwd.getpwnam(login)
    home = os.environ["HOME"] if TEST else pw.pw_dir   # the sandbox's, never the real ~/.codex
    R, RUN = paths(login)
    try:
        meta = json.load(open(os.path.join(R, "meta.json")))
    except (OSError, ValueError):
        meta = {}
    plabel = "com.claude-fleet.credsep.%s" % login if MAC else "claude-fleet-credsep-%s.service" % login
    ppath = os.path.join(DAEMON_DIR, plabel + (".plist" if MAC else ""))
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
    unload_daemon(plabel)
    if os.path.exists(ppath) and not DRY:
        os.unlink(ppath)
    say("proxy:", plabel, "removed")
    # every credential back to the login's own path — the agent may have renewed them
    n = 0
    acc = os.path.join(R, "accounts")
    for d in sorted(os.listdir(acc)) if os.path.isdir(acc) else []:
        f = os.path.join(acc, d, ".credentials.json")
        if d.endswith(".hub") and SAFE.match(d[:-4]) and os.path.isfile(f):
            dst = os.path.join(conf, "accounts", d, ".credentials.json")
            mkdir(os.path.dirname(dst), 0o700, login)
            move(f, dst, login); n += 1
    ch = meta.get("codex_homes") or codex_homes(conf, home)
    cx = os.path.join(R, "codex")
    for d in sorted(os.listdir(cx)) if os.path.isdir(cx) else []:
        f = os.path.join(cx, d, "auth.json")
        if SAFE.match(d) and os.path.isfile(f):
            dst = os.path.join(home, ".codex", "auth.json") if d == "default" else os.path.join(ch, d, "auth.json")
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
              os.path.join(LOG_BASE, login + ".launch.log")):
        if os.path.exists(p) and not DRY:
            os.unlink(p)
    if not DRY:
        shutil.rmtree(R, ignore_errors=True)
        shutil.rmtree(RUN, ignore_errors=True)
    others = [d for d in (os.listdir(ROOT_BASE) if os.path.isdir(ROOT_BASE) else []) if not d.startswith(".")]
    if not others and not DRY:
        shutil.rmtree(LIB, ignore_errors=True)
        for d in (ROOT_BASE, RUN_BASE, LOG_BASE, os.path.dirname(LIB)):
            try:
                os.rmdir(d)        # only when empty: the last login leaves nothing behind
            except OSError:
                pass
    drop_role()
    say("credsep: OFF — every file back where it was")


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
    if not want:
        print("credsep: WARN — FLEET_CRED_SEPARATE=0 but this login is still separated; uninstall: bash "
              "%s/fleet-credsep.sh uninstall" % HERE)
        return 1
    print("credsep: OK — %s unreadable here (Permission denied), proxy on 127.0.0.1:%d as %s%s"
          % (R, port, rec["role"], note))
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
    s = sub.add_parser("status"); s.add_argument("--conf-dir", required=True); s.add_argument("--json", action="store_true")
    c = sub.add_parser("check"); c.add_argument("--conf-dir", required=True)
    a = ap.parse_args()
    if a.cmd in ("install", "uninstall"):
        DRY = a.dry_run
        if not re.match(r"^[a-z_][a-z0-9_.-]{0,31}$", a.login):
            die("bad login %r" % a.login, 2)
        if os.geteuid() != 0 and not TEST and not DRY:
            die("%s needs root (bin/fleet-credsep.sh runs it through sudo -n)" % a.cmd, 2)
        if not (MAC or sys.platform.startswith("linux")):
            die("only macOS and Linux", 2)
        return install(a) if a.cmd == "install" else uninstall(a)
    return status(a) if a.cmd == "status" else check(a)


if __name__ == "__main__":
    sys.exit(main() or 0)
