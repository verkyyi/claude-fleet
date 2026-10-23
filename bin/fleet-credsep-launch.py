#!/usr/bin/env python3
"""fleet-credsep-launch.py — start a separated login's credential proxy or node
agent (issue #1971, EPIC #1967 C4). Run by ROOT, from the root-owned copy
bin/fleet-credsep.sh installs; never from a login's own checkout.

    fleet-credsep-launch.py agent <login>
        The login's ccquota node agent, as the LOGIN: reads <root>/node.env,
        hands the token down a pipe (CCQUOTA_TOKEN_FD=3, never the environment
        a session could `ps -E`), sets CCQUOTA_FLEET_CRED_STORE to the proxy's
        control socket, then drops to the login and execs the agent argv the
        install recorded.

    fleet-credsep-launch.py agents <login>
        Read-only: one line per running `ccquota agent` of <login> — its uid,
        its --state — as `<pid> <state>` (the doctor's agentdup row, issue
        #2663). Needs no root.

    fleet-credsep-launch.py shared
        The machine's ONE credential proxy (issue #2217), as the role account:
        every login whose store says `mode: shared` is a tenant — its settings
        parsed from its conf the same way, its node-probe copied in — written to
        /var/db/fleet-cred/.shared/tenants.json (0600, the role account's), then
        fleet-cred-proxy.py serve --shared on FLEET_CRED_SHARED_PORT (18923),
        its control socket in /var/run/fleet-cred/.shared/ (0666; the peer uid
        names the login), its upstream stats in /var/db/fleet-cred/.stats/
        (0755, every login reads them — T657).

<root> = /var/db/fleet-cred/<login> (FLEET_CREDSEP_ROOT_BASE overrides the
/var/db/fleet-cred part — the selftest's sandbox; so do FLEET_CREDSEP_RUN_BASE
and FLEET_CREDSEP_LOG_BASE). Not root ⇒ nothing is dropped and the run is
refused unless FLEET_CREDSEP_TEST=1 (a sandbox, where the login is yourself).
"""
import errno, json, os, pwd, re, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROLE = "_fleetcred" if sys.platform == "darwin" else "fleetcred"
CRED_KEYS = re.compile(r"^(FLEET_CRED_(PROXY_PORT|PROXY_TTL|PROXY_SWITCH_SECS|PROXY_TIMEOUT|PROXY_TRUST_SECS|"
                       r"RELAY_URL|RELAY_TOKEN|CENTRAL_URL|ANTHROPIC_URL|CODEX_URL|ALLOW_HOSTS)|FLEET_HUB_URL|"
                       r"FLEET_PROBE_FORCE_UNREACHABLE)$")
# the only CRED_KEYS a login's own files may set (issue #2290): its proxy's port
# and timings. Everything that says WHERE a credential or the node token goes —
# every upstream URL, FLEET_HUB_URL, the relay pass, the allow-list, the probe
# override — comes from root's <lib>/<login>.conf alone (fleet-credsep.py install
# writes it); the same key in a login file is ignored and said so.
LOGIN_KEYS = re.compile(r"^FLEET_CRED_PROXY_(PORT|TTL|SWITCH_SECS|TIMEOUT|TRUST_SECS)$")
TEST = os.environ.get("FLEET_CREDSEP_TEST") == "1"
LOGIN_RE = re.compile(r"^[a-z0-9_][a-z0-9_.-]{0,31}$")


def die(msg, rc=1):
    sys.stderr.write("fleet-credsep-launch: %s\n" % msg)
    sys.exit(rc)


def base(k, d):
    return os.environ.get(k) or d


def env_lines(path):
    """KEY=value lines → dict. A shell file is PARSED here, never run: root
    reading what the login writes. Lines inside `if` guards count the same —
    the keys we take are global-only (conf/fleet.conf.reference)."""
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


def agent_state(argv, home):
    """The --state an agent argv names (`ccquota agent`'s default: ~/.ccquota)."""
    st = ""
    for i, a in enumerate(argv):
        if a == "--state" and i + 1 < len(argv):
            st = argv[i + 1]
        elif a.startswith("--state="):
            st = a.split("=", 1)[1]
    return os.path.realpath(os.path.expanduser(st) if st else os.path.join(home, ".ccquota"))


def agent_procs(uid, home, names=("ccquota",)):
    """[(pid, state)] of every running per-login `ccquota agent` owned by <uid> —
    the binary by basename (an interpreter in front is skipped over), `agent` its
    verb, never the machine's root node program (`--machine`). Issue #2663: an
    agent from before the separation (an old LaunchAgent's, or an orphan at
    PPID=1) kept running beside the launcher's, both on the one node token."""
    try:
        out = subprocess.run(["ps", "axww", "-o", "pid=,uid=,args="], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True).stdout
    except OSError:
        return []
    rows = []
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) < 3 or not f[0].isdigit() or not f[1].isdigit() or int(f[1]) != uid:
            continue
        toks = f[2].split()
        i = next((k for k, t in enumerate(toks[:3]) if os.path.basename(t) in names), None)
        if i is None or toks[i + 1:i + 2] != ["agent"] or "--machine" in toks:
            continue
        rows.append((int(f[0]), agent_state(toks[i + 2:], home)))
    return rows


def stop_strays(uid, home, argv):
    """Before the launcher's agent starts: every other agent of this login on the
    same --state goes (TERM, then KILL after 5 s). Another login's, another
    state's and the machine's node program are never touched."""
    want = agent_state(argv[1:], home)
    names = ("ccquota", os.path.basename(argv[0]))
    me = {os.getpid(), os.getppid()}
    strays = [p for p, st in agent_procs(uid, home, names) if st == want and p not in me]
    for p in strays:
        try:
            os.kill(p, signal.SIGTERM)
            sys.stderr.write("fleet-credsep-launch: stopped a stray agent pid %d (--state %s) — "
                             "one agent per login (issue #2663)\n" % (p, want))
        except OSError:
            pass
    end = time.time() + 5
    while strays and time.time() < end:
        strays = [p for p in strays if alive(p)]
        time.sleep(0.1)
    for p in strays:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    try:    # a zombie (our own child in the selftest) has already stopped
        st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, universal_newlines=True).stdout.strip()
    except OSError:
        return True
    return bool(st) and not st.startswith("Z")


def root_conf(login):
    """root's settings for <login>: <lib>/<login>.conf, beside this root-owned
    code (FLEET_CREDSEP_LIB in the selftest's sandbox). Not root's ⇒ not read."""
    lib = os.environ.get("FLEET_CREDSEP_LIB") if TEST and os.environ.get("FLEET_CREDSEP_LIB") else HERE
    path = os.path.join(lib, login + ".conf")
    try:
        st = os.lstat(path)
    except OSError:
        return path, {}
    if os.geteuid() == 0 and (st.st_uid != 0 or st.st_mode & 0o022 or not os.path.isfile(path)):
        sys.stderr.write("fleet-credsep-launch: %s is not root's alone — not read\n" % path)
        return path, {}
    return path, {k: v for k, v in env_lines(path).items() if CRED_KEYS.match(k)}


def tenant_settings(meta, run=None):
    """The proxy's settings for meta's login: its port / timings from its own
    files, the rest from root's config only (issue #2290). A login file that
    sets one of the rest differently is ignored — one stderr line per key, and
    the key names (never a value) in <run>/ignored.<login> for `credsep check`."""
    login = meta["login"]
    rpath, root = root_conf(login)
    settings, ignored = {}, {}
    conf = meta["conf_dir"]
    for f in (os.path.join(meta.get("install_dir", ""), "fleet.conf"),
              os.path.join(conf, "fleet.settings"), os.path.join(conf, "fleet.conf"),
              os.path.join(conf, "secrets.env")):
        for k, v in env_lines(f).items():
            if not CRED_KEYS.match(k):
                continue
            if LOGIN_KEYS.match(k):
                settings[k] = v
            elif root.get(k) != v:
                ignored[k] = f
            else:
                ignored.pop(k, None)
    settings.update(root)
    for k, f in sorted(ignored.items()):
        sys.stderr.write("fleet-credsep-launch: ignored %s from %s — only root's %s sets it (issue #2290)\n"
                         % (k, f, rpath))
    if run:
        note = os.path.join(run, "ignored." + login)
        try:
            if ignored:
                with open(note + ".tmp", "w") as f:
                    f.write("".join("%s %s\n" % (k, ignored[k]) for k in sorted(ignored)))
                os.chmod(note + ".tmp", 0o644)
                os.replace(note + ".tmp", note)
            elif os.path.exists(note):
                os.unlink(note)
        except OSError:
            pass
    return settings


def copy_probe(conf, probe, pw_role):
    try:   # the probe the login measured; later ones arrive over ctl `probe`
        shutil.copyfile(os.path.join(conf, "node-probe.json"), probe)
        if os.geteuid() == 0:
            os.chown(probe, pw_role.pw_uid, pw_role.pw_gid)
        os.chmod(probe, 0o600)
    except OSError:
        pass


def snapshot_shared_picks(run, tenants, pw_role):
    """Root reads the old uid-gated control BEFORE drop/handoff, never as role.
    No listener is a cold start. An active listener's refusal/error aborts the
    successor, leaving that daemon serving. Gather all replies before writes.
    Only the two installed files (launcher + proxy) and stdlib are needed.
    """
    active, snapshots = False, []
    try:
        for tenant in tenants:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(2)
                try:
                    conn.connect(os.path.join(run, "ctl.sock"))
                except OSError as e:
                    if not active and e.errno in (errno.ENOENT, errno.ECONNREFUSED):
                        return False  # retain persisted picks, including after a crash
                    raise
                active = True
                req = {"op": "picks", "as": tenant["login"]}
                if os.geteuid() != 0:
                    if not TEST:
                        raise PermissionError("shared snapshot requires root before drop")
                    # Existing sandbox-only control seam, ignored by production
                    # proxies. Auth regression runs with both TEST flags off.
                    req["peer_uid"] = 0
                # No caller credential/as override; tenant names are root-derived.
                conn.sendall((json.dumps(req) + "\n").encode())
                raw = b""
                while b"\n" not in raw and len(raw) <= 1048576:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    raw += chunk
                if b"\n" not in raw or len(raw) > 1048576:
                    raise ValueError("incomplete snapshot")
                reply = json.loads(raw.split(b"\n", 1)[0])
                if not isinstance(reply, dict) or reply.get("ok") is not True or not isinstance(reply.get("picks"), dict):
                    raise ValueError("snapshot refused")
                picks = {}
                for key, account in reply["picks"].items():
                    if not isinstance(key, str):
                        raise ValueError("invalid snapshot key")
                    if key.startswith("codex:"):
                        if not key[6:] or not isinstance(account, str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}", account):
                            raise ValueError("invalid snapshot binding")
                        picks[key[6:]] = account
                snapshots.append((tenant["state"], picks))
        for state, picks in snapshots:
            fd, tmp = tempfile.mkstemp(prefix=".codex-legacy-picks-", dir=state)
            try:
                with os.fdopen(fd, "w") as f:
                    os.fchmod(f.fileno(), 0o600)
                    os.fchown(f.fileno(), pw_role.pw_uid, pw_role.pw_gid)
                    json.dump(picks, f)  # a confirmed empty answer clears stale picks
                os.replace(tmp, os.path.join(state, "codex-legacy-picks.json"))
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
        return active
    except (OSError, ValueError, TypeError, KeyError):
        die("cannot snapshot old shared Codex picks before restart/drop; old proxy retained")


def snapshot_previous_shared_picks(rbase, run, tenants, pw_role):
    """Shared by the root launcher and legacy service restart before bootout."""
    tf = os.path.join(rbase, ".shared", "tenants.json")
    # The old daemon read the prior manifest once. New tenants have no old
    # bindings and cannot be addressed through that daemon's uid gate. Reuse
    # only its login names; all destination paths come from today's root store.
    previous_logins = None
    try:
        previous = json.load(open(tf))
        if isinstance(previous, dict) and isinstance(previous.get("tenants"), list):
            previous_logins = {t["login"] for t in previous["tenants"] if isinstance(t, dict) and isinstance(t.get("login"), str)}
    except (OSError, ValueError):
        pass
    old_tenants = [t for t in tenants if previous_logins is None or t["login"] in previous_logins]
    snapshot_shared_picks(run, old_tenants, pw_role)


def shared():
    """The machine's one proxy (issue #2217): a tenant per joined login."""
    import hashlib
    rbase = base("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred")
    run = os.path.join(base("FLEET_CREDSEP_RUN_BASE", "/var/run/fleet-cred"), ".shared")
    sdir = os.path.join(rbase, ".shared")
    stats = os.path.join(rbase, ".stats")      # upstream stats every login reads (T657); kept across reboots
    logdir = base("FLEET_CREDSEP_LOG_BASE", "/var/log/fleet-cred")
    test = os.environ.get("FLEET_CREDSEP_TEST") == "1"
    try:
        rec = json.load(open(os.path.join(rbase, ".shared.json")))
    except (OSError, ValueError) as e:
        die("%s/.shared.json: %s (not installed? fleet-credsep.sh machine install)" % (rbase, e))
    role = rec.get("user") or ROLE
    pw_role = pwd.getpwnam(role)
    for d, mode in ((run, 0o755), (logdir, 0o755), (sdir, 0o700), (stats, 0o755)):
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
                        "settings": tenant_settings(meta, run)})
    try:
        version = hashlib.sha256(open(os.path.join(HERE, "fleet-cred-proxy.py"), "rb").read()).hexdigest()[:12]
    except OSError:
        version = ""
    tf = os.path.join(sdir, "tenants.json")
    snapshot_previous_shared_picks(rbase, run, tenants, pw_role)
    tmp = tf + ".%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"state": sdir, "run": run, "stats": stats, "user": role, "version": version,
                   "port": int(rec.get("port") or base("FLEET_CRED_SHARED_PORT", "18923")),
                   "tenants": tenants}, f)
    if os.geteuid() == 0:
        os.chown(tmp, pw_role.pw_uid, pw_role.pw_gid)
    os.replace(tmp, tf)
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": pw_role.pw_dir or "/var/empty",
           "LANG": "en_US.UTF-8", "FLEET_CRED_PROXY_LOG": os.path.join(logdir, "shared.log")}
    # the allow-list (issue #2290): every tenant's root config may add hosts
    extra = " ".join(t["settings"].get("FLEET_CRED_ALLOW_HOSTS", "") for t in tenants).strip()
    if extra:
        env["FLEET_CRED_ALLOW_HOSTS"] = extra
    if os.environ.get("FLEET_CRED_HANDOFF") == "1":
        # the machine daemon's start (T595): the proxy holding the lock hands its
        # listening sockets to this one instead of being stopped first
        env["FLEET_CRED_HANDOFF"] = "1"
    if test:    # the sandbox's fake upstreams and its peer-uid seam
        env.update({k: v for k, v in os.environ.items()
                    if k.startswith("FLEET_CRED_") and k not in ("FLEET_CRED_PROXY_LOG",)})
        env["FLEET_CRED_SHARED_TEST"] = "1"
        env["FLEET_CREDSEP_TEST"] = "1"
    drop_to(role)
    os.umask(0o077)
    os.chdir("/")
    py = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else shutil.which("python3") or "python3"
    os.execve(py, [py, "-I", os.path.join(HERE, "fleet-cred-proxy.py"), "serve", "--shared", tf], env)


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "shared":
        return shared()
    if len(sys.argv) != 3 or sys.argv[1] not in ("agent", "agents"):
        die("usage: fleet-credsep-launch.py agent|agents <login> · shared", 2)
    mode, login = sys.argv[1], sys.argv[2]
    if not LOGIN_RE.match(login):
        die("bad login name %r" % login, 2)
    if mode == "agents":
        pw = getpw(login)
        home = os.environ["HOME"] if TEST else pw.pw_dir
        for p, st in agent_procs(pw.pw_uid, home):
            print("%d %s" % (p, st))
        return 0
    root = os.path.join(base("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred"), login)
    run = os.path.join(base("FLEET_CREDSEP_RUN_BASE", "/var/run/fleet-cred"), login)
    try:
        with open(os.path.join(root, "meta.json")) as f:
            meta = json.load(f)
    except (OSError, ValueError) as e:
        die("%s/meta.json: %s (not installed? bin/fleet-credsep.sh install)" % (root, e))
    if meta.get("login") != login:
        die("%s/meta.json names %r, not %r" % (root, meta.get("login"), login))
    pw_login = getpw(login)
    login_home = os.environ["HOME"] if os.environ.get("FLEET_CREDSEP_TEST") == "1" else pw_login.pw_dir

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
    stop_strays(pw_login.pw_uid, login_home, argv)
    drop_to(login)
    os.chdir(login_home)
    os.execve(argv[0], argv, env)


if __name__ == "__main__":
    main()
