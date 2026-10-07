#!/usr/bin/env python3
"""fleet-credsep-launch.py — start a separated login's credential proxy or node
agent (issue #1971, EPIC #1967 C4). Run by ROOT, from the root-owned copy
bin/fleet-credsep.sh installs; never from a login's own checkout.

    fleet-credsep-launch.py proxy <login>
        The credential proxy, as the role account (_fleetcred / fleetcred):
        reads <root>/meta.json, takes the FLEET_CRED_* settings from the
        login's fleet.conf + secrets.env (PARSED, never sourced — this is root
        reading a file the login writes), copies node-probe.json in, then drops
        to the role account and execs fleet-cred-proxy.py serve with every
        credential path pointing into <root>.

    fleet-credsep-launch.py agent <login>
        The login's ccquota node agent, as the LOGIN: reads <root>/node.env,
        hands the token down a pipe (CCQUOTA_TOKEN_FD=3, never the environment
        a session could `ps -E`), sets CCQUOTA_FLEET_CRED_STORE to the proxy's
        control socket, then drops to the login and execs the agent argv the
        install recorded.

    fleet-credsep-launch.py shared
        The machine's ONE credential proxy (issue #2217), as the role account:
        every login whose store says `mode: shared` is a tenant — its settings
        parsed from its conf the same way, its node-probe copied in — written to
        /var/db/fleet-cred/.shared/tenants.json (0600, the role account's), then
        fleet-cred-proxy.py serve --shared on FLEET_CRED_SHARED_PORT (18923),
        its control socket in /var/run/fleet-cred/.shared/ (0666; the peer uid
        names the login).

<root> = /var/db/fleet-cred/<login> (FLEET_CREDSEP_ROOT_BASE overrides the
/var/db/fleet-cred part — the selftest's sandbox; so do FLEET_CREDSEP_RUN_BASE
and FLEET_CREDSEP_LOG_BASE). Not root ⇒ nothing is dropped and the run is
refused unless FLEET_CREDSEP_TEST=1 (a sandbox, where the login is yourself).
"""
import json, os, pwd, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROLE = "_fleetcred" if sys.platform == "darwin" else "fleetcred"
CRED_KEYS = re.compile(r"^(FLEET_CRED_(PROXY_PORT|PROXY_TTL|PROXY_SWITCH_SECS|PROXY_TIMEOUT|PROXY_TRUST_SECS|"
                       r"RELAY_URL|RELAY_TOKEN|CENTRAL_URL|ANTHROPIC_URL|CODEX_URL)|FLEET_HUB_URL|"
                       r"FLEET_PROBE_FORCE_UNREACHABLE)$")
LOGIN_RE = re.compile(r"^[a-z0-9_][a-z0-9_.-]{0,31}$")


def die(msg, rc=1):
    sys.stderr.write("fleet-credsep-launch: %s\n" % msg)
    sys.exit(rc)


def base(k, d):
    return os.environ.get(k) or d


def env_lines(path):
    """KEY=value lines → dict. A shell file is PARSED here, never run: root
    reading what the login writes. Lines inside `if` guards count the same —
    the keys we take are global-only (fleet.conf.example)."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].lstrip()
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
                if not m:
                    continue
                v = m.group(2).strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                elif " #" in v:
                    v = v.split(" #", 1)[0].rstrip()
                out[m.group(1)] = v
    except OSError:
        pass
    return out


def getpw(name):
    """pwd.getpwnam — or a FLEET_CREDSEP_PW row in the selftest's sandbox."""
    f = os.environ.get("FLEET_CREDSEP_PW")
    if os.environ.get("FLEET_CREDSEP_TEST") == "1" and f and os.path.isfile(f):
        for line in open(f):
            r = line.strip().split(":")
            if len(r) == 4 and r[0] == name:
                return pwd.struct_passwd((r[0], "*", int(r[1]), int(r[2]), "", r[3], "/bin/sh"))
    return pwd.getpwnam(name)


def drop_to(user):
    """setgroups → setgid → setuid, irreversibly. A no-op only in a sandbox."""
    pw = pwd.getpwnam(user)
    if os.geteuid() != 0:
        if os.environ.get("FLEET_CREDSEP_TEST") == "1" and pw.pw_uid == os.geteuid():
            return pw
        die("must run as root (it starts %s as %s)" % (sys.argv[1], user))
    os.initgroups(user, pw.pw_gid)
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)
    if os.getuid() == 0 or os.geteuid() == 0:
        die("could not drop root")
    return pw


def tenant_settings(meta):
    settings = {}
    conf = meta["conf_dir"]
    for f in (os.path.join(meta.get("install_dir", ""), "fleet.conf"),
              os.path.join(conf, "fleet.settings"), os.path.join(conf, "fleet.conf"),
              os.path.join(conf, "secrets.env")):
        settings.update({k: v for k, v in env_lines(f).items() if CRED_KEYS.match(k)})
    return settings


def copy_probe(conf, probe, pw_role):
    try:   # the probe the login measured; later ones arrive over ctl `probe`
        shutil.copyfile(os.path.join(conf, "node-probe.json"), probe)
        if os.geteuid() == 0:
            os.chown(probe, pw_role.pw_uid, pw_role.pw_gid)
        os.chmod(probe, 0o600)
    except OSError:
        pass


def shared():
    """The machine's one proxy (issue #2217): a tenant per joined login."""
    import hashlib
    rbase = base("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred")
    run = os.path.join(base("FLEET_CREDSEP_RUN_BASE", "/var/run/fleet-cred"), ".shared")
    sdir = os.path.join(rbase, ".shared")
    logdir = base("FLEET_CREDSEP_LOG_BASE", "/var/log/fleet-cred")
    test = os.environ.get("FLEET_CREDSEP_TEST") == "1"
    try:
        rec = json.load(open(os.path.join(rbase, ".shared.json")))
    except (OSError, ValueError) as e:
        die("%s/.shared.json: %s (not installed? fleet-credsep.sh machine install)" % (rbase, e))
    role = rec.get("user") or ROLE
    pw_role = pwd.getpwnam(role)
    for d, mode in ((run, 0o755), (logdir, 0o755), (sdir, 0o700)):
        os.makedirs(d, mode=mode, exist_ok=True)
        os.chmod(d, mode)
        if os.geteuid() == 0:
            os.chown(d, pw_role.pw_uid, pw_role.pw_gid)
    tenants = []
    for login in sorted(os.listdir(rbase)):
        if login.startswith(".") or not LOGIN_RE.match(login):
            continue
        root = os.path.join(rbase, login)
        try:
            with open(os.path.join(root, "meta.json")) as f:
                meta = json.load(f)
        except (OSError, ValueError):
            continue
        if meta.get("mode") != "shared" or meta.get("login") != login:
            continue
        try:
            pw = getpw(login)
        except KeyError:
            continue        # a login deleted under its store: never answered
        state = os.path.join(root, "cred-proxy")
        probe = os.path.join(state, "node-probe.json")
        copy_probe(meta["conf_dir"], probe, pw_role)
        tenants.append({"login": login, "uid": pw.pw_uid, "state": state,
                        "accounts": os.path.join(root, "accounts"),
                        "codex_auth": os.path.join(root, "codex", "default", "auth.json"),
                        "codex_homes": os.path.join(root, "codex"),
                        "node_env": os.path.join(root, "node.env"), "probe": probe,
                        "log": os.path.join(logdir, login + ".log"),
                        "legacy_port": int(meta.get("legacy_port") or 0),
                        "settings": tenant_settings(meta)})
    try:
        version = hashlib.sha256(open(os.path.join(HERE, "fleet-cred-proxy.py"), "rb").read()).hexdigest()[:12]
    except OSError:
        version = ""
    tf = os.path.join(sdir, "tenants.json")
    tmp = tf + ".%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"state": sdir, "run": run, "user": role, "version": version,
                   "port": int(rec.get("port") or base("FLEET_CRED_SHARED_PORT", "18923")),
                   "tenants": tenants}, f)
    if os.geteuid() == 0:
        os.chown(tmp, pw_role.pw_uid, pw_role.pw_gid)
    os.replace(tmp, tf)
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": pw_role.pw_dir or "/var/empty",
           "LANG": "en_US.UTF-8", "FLEET_CRED_PROXY_LOG": os.path.join(logdir, "shared.log")}
    if test:    # the sandbox's fake upstreams and its peer-uid seam
        env.update({k: v for k, v in os.environ.items()
                    if k.startswith("FLEET_CRED_") and k not in ("FLEET_CRED_PROXY_LOG",)})
        env["FLEET_CRED_SHARED_TEST"] = "1"
    drop_to(role)
    os.umask(0o077)
    os.chdir("/")
    py = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else shutil.which("python3") or "python3"
    os.execve(py, [py, "-I", os.path.join(HERE, "fleet-cred-proxy.py"), "serve", "--shared", tf], env)


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "shared":
        return shared()
    if len(sys.argv) != 3 or sys.argv[1] not in ("proxy", "agent"):
        die("usage: fleet-credsep-launch.py proxy|agent <login> · shared", 2)
    mode, login = sys.argv[1], sys.argv[2]
    if not LOGIN_RE.match(login):
        die("bad login name %r" % login, 2)
    root = os.path.join(base("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred"), login)
    run = os.path.join(base("FLEET_CREDSEP_RUN_BASE", "/var/run/fleet-cred"), login)
    try:
        with open(os.path.join(root, "meta.json")) as f:
            meta = json.load(f)
    except (OSError, ValueError) as e:
        die("%s/meta.json: %s (not installed? bin/fleet-credsep.sh install)" % (root, e))
    if meta.get("login") != login:
        die("%s/meta.json names %r, not %r" % (root, meta.get("login"), login))
    role = meta.get("role") or ROLE
    pw_login = getpw(login)
    login_home = os.environ["HOME"] if os.environ.get("FLEET_CREDSEP_TEST") == "1" else pw_login.pw_dir

    if mode == "proxy":
        if meta.get("mode") == "shared":
            die("%s is a tenant of the machine's shared proxy (fleet-credsep-launch.py shared)" % login)
        pw_role = pwd.getpwnam(role)
        # the login reads the port and connects to ctl.sock here; only the
        # proxy writes it. /var/run is emptied at boot, so make it every start.
        os.makedirs(run, mode=0o755, exist_ok=True)
        os.chmod(run, 0o755)
        if os.geteuid() == 0:
            os.chown(run, pw_role.pw_uid, pw_role.pw_gid)
        logdir = base("FLEET_CREDSEP_LOG_BASE", "/var/log/fleet-cred")
        os.makedirs(logdir, mode=0o755, exist_ok=True)
        if os.geteuid() == 0:
            os.chown(logdir, pw_role.pw_uid, pw_role.pw_gid)
        conf = meta["conf_dir"]
        settings = {}
        for f in (os.path.join(meta.get("install_dir", ""), "fleet.conf"),
                  os.path.join(conf, "fleet.settings"), os.path.join(conf, "fleet.conf"),
                  os.path.join(conf, "secrets.env")):
            settings.update({k: v for k, v in env_lines(f).items() if CRED_KEYS.match(k)})
        state = os.path.join(root, "cred-proxy")
        probe = os.path.join(state, "node-probe.json")
        try:   # the probe the login measured; later ones arrive over ctl `probe`
            shutil.copyfile(os.path.join(conf, "node-probe.json"), probe)
            if os.geteuid() == 0:
                os.chown(probe, pw_role.pw_uid, pw_role.pw_gid)
            os.chmod(probe, 0o600)
        except OSError:
            pass
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": pw_role.pw_dir or "/var/empty",
               "LANG": "en_US.UTF-8", "FLEET_CONF_DIR": root,
               "FLEET_CRED_ACCOUNTS": os.path.join(root, "accounts"),
               "FLEET_CRED_CODEX_AUTH": os.path.join(root, "codex", "default", "auth.json"),
               "FLEET_CRED_CODEX_HOMES": os.path.join(root, "codex"),
               "FLEET_CRED_NODE_ENV": os.path.join(root, "node.env"),
               "FLEET_CRED_PROBE": probe,
               "FLEET_CRED_STORE": "1",
               "FLEET_CRED_CTL_UID": str(pw_login.pw_uid),
               "FLEET_CRED_CTL_DIR": run,
               "FLEET_CRED_PROXY_LOG": os.path.join(logdir, login + ".log")}
        env.update(settings)
        drop_to(role)
        os.umask(0o077)
        os.chdir("/")
        py = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else shutil.which("python3") or "python3"
        os.execve(py, [py, "-I", os.path.join(HERE, "fleet-cred-proxy.py"), "serve"], env)

    # agent
    ne = env_lines(os.path.join(root, "node.env"))
    tok = ne.pop("CCQUOTA_TOKEN", "")
    if not tok:
        die("%s/node.env carries no CCQUOTA_TOKEN" % root)
    argv = meta.get("agent_argv") or []
    if not argv or not os.path.isabs(argv[0]):
        die("meta.json has no agent_argv (re-run bin/fleet-credsep.sh install)")
    env = {"HOME": login_home, "USER": login, "LOGNAME": login,
           "SHELL": pw_login.pw_shell or "/bin/sh", "LANG": "en_US.UTF-8",
           "PATH": meta.get("path") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
    env.update({k: v for k, v in ne.items() if k.startswith("CCQUOTA_")})
    env["CCQUOTA_TOKEN_FD"] = "3"
    # a tenant of the shared proxy (issue #2217) hands its leases to that one's socket
    env["CCQUOTA_FLEET_CRED_STORE"] = os.path.join(
        os.path.dirname(run), ".shared", "ctl.sock") if meta.get("mode") == "shared" else os.path.join(run, "ctl.sock")
    r, w = os.pipe()
    os.write(w, (tok + "\n").encode())
    os.close(w)
    del tok
    if r != 3:
        os.dup2(r, 3)
        os.close(r)
    os.set_inheritable(3, True)
    drop_to(login)
    os.chdir(login_home)
    os.execve(argv[0], argv, env)


if __name__ == "__main__":
    main()
