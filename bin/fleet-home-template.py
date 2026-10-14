#!/usr/bin/env python3
"""fleet-home-template.py — the standard home a recycled login is cloned from
(issue #4194: a login back in the pool in ≤ 10 s).

A washed login used to get an empty home (createhomedir) and then spend its
rejoin filling it: the install linked, the hooks, settings, skills, agents and
plugins applied, the starter repo checked out — the same bytes for every login
of a version. Now root builds that home ONCE per runtime version and every wash
clones it (APFS clonefile: one call, copy-on-write, well under a second).

The rule (the 发起人's, #4194): whatever the last person could READ or WRITE is
thrown away; only what they never touched is reused. So the template is
  · never taken from any login's home — it is built from the runtime alone, in
    a staging home no login owns (run as `nobody`), by the same two scripts a
    new login's first minute runs (fleet-login-install.sh, then
    fleet-login-bootstrap.sh with FLEET_BOOTSTRAP_FLEET=0: no fleet started,
    no doctor);
  · root's and closed: <base> 0711 root, <base>/<sha>/ 0700 root — no login can
    read it, let alone change it; a clone is a COPY, so what the person does to
    their home never reaches the template;
  · holds nothing a login must not share: no fleet.conf (fleet-login-new.sh's
    step 7b writes the login's own), no node.env / secrets / tokens (a build
    that finds anything credential-shaped is refused, nothing kept), no ~/.ssh,
    no Claude session state, no per-install ids in ~/.claude.json.

    fleet-home-template.py build  [--sha <sha>] [--force]
    fleet-home-template.py clone  <login> --home <dir>
    fleet-home-template.py status [--sha <sha>]

build   root. The template of <sha> (default: the runtime's `current`) under
        <base>/<sha>/: home/ + meta.json {sha, build_home, rewrite, relink, built}.
        Staged in <base>/build/ (one build at a time: <base>/build.lock), renamed
        in only when whole; templates of other versions but the newest previous
        one are removed. Already there: nothing (--force rebuilds).
clone   root. <dir> must not exist (the wash moved the old home aside). The
        current version's template is cloned to <dir> (clonefile, else
        `cp -c -pR`, else `cp -pR`), handed to <login> (lchown, its primary
        group), 0700, every file / link the build recorded as naming the
        staging home rewritten to <dir>, and marked
        <dir>/.config/claude-fleet/global/home-template (<sha> <UTC>).
        Exit 3 = no template for the current version (the caller makes the home
        the old way and may start a build); anything that fails half way removes
        <dir> again — never a half home.
status  one line: `ready <sha12> built <UTC> (<n> entries)` or `none <sha12>`.

One line on stdout per run. Exit 0 ok · 1 failed · 2 usage · 3 no template.

Env: FLEET_HOME_TEMPLATE_DIR (/private/var/db/fleet-home) · FLEET_NODE_ROOT (the
runtime, /Library/Application Support/claude-fleet) — tests: FLEET_HOME_TEMPLATE_RUNAS
(the build's user; `-` = this process, no sudo) · FLEET_HOME_TEMPLATE_BUILD_CMD
(replaces the two scripts: run with HOME = the staging home) ·
FLEET_HOME_TEMPLATE_TEST_EUID (the EUID read).
"""
import ctypes
import ctypes.util
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time

DEFAULT_BASE = "/private/var/db/fleet-home"
DEFAULT_ROOT = "/Library/Application Support/claude-fleet"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
MARK = os.path.join(".config", "claude-fleet", "global", "home-template")

# Never in a template: the login's own conf (7b writes it), the bootstrap's
# done-mark (the clone still has to start its fleet), its timing, and whatever
# a run of Claude Code leaves per install / per session.
STRIP = (
    ".config/claude-fleet/fleet.conf",
    ".config/claude-fleet/fleet.conf.bak",
    ".config/claude-fleet/global/bootstrapped",
    ".config/claude-fleet/global/bootstrap.timing",
    ".ssh",
    ".claude/projects",
    ".claude/todos",
    ".claude/shell-snapshots",
    ".claude/statsig",
    ".claude/session-env",
    ".claude/debug",
    ".cache",
    "Library/Caches",
)
# per-install ids Claude Code writes on a run — a fresh one per login
CLAUDE_JSON_DROP = ("userID", "anonymousId", "firstStartTime", "numStartups")
# credential-shaped: a build that holds one is refused (never kept, never cloned)
CRED_NAMES = {"node.env", "secrets.env", "hub.json", ".credentials.json", "auth.json",
              ".git-credentials", ".netrc", "id_rsa", "id_ed25519", "id_ecdsa"}
CRED_RE = re.compile(rb"(sk-ant-[A-Za-z0-9_-]{8,}|CCQUOTA_TOKEN=\S|gh[opsu]_[A-Za-z0-9]{20,}|"
                     rb"-----BEGIN [A-Z ]*PRIVATE KEY-----|fj_[a-z2-7]{26})")
CLONE_NOFOLLOW, CLONE_NOOWNERCOPY = 0x0001, 0x0002
# the version's own code (the linked install, the copied mod, the starter
# checkout): the runtime's bytes verbatim — test fixtures in it look like keys
CODE_TOPS = ("projects/", ".claude/fleet/", ".claude/fleet.versions/")


def env(k, d):
    v = os.environ.get(k, "")
    return v if v else d


def base_dir():
    return env("FLEET_HOME_TEMPLATE_DIR", DEFAULT_BASE).rstrip("/")


def euid():
    t = os.environ.get("FLEET_HOME_TEMPLATE_TEST_EUID", "")
    return int(t) if t.isdigit() else os.geteuid()


def die(msg, rc=1):
    print("fleet-home-template: %s" % msg, file=sys.stderr)
    sys.exit(rc)


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def current_sha():
    root = env("FLEET_NODE_ROOT", DEFAULT_ROOT).rstrip("/")
    t = os.path.basename(os.readlink(os.path.join(root, "current")).rstrip("/")) \
        if os.path.islink(os.path.join(root, "current")) else ""
    return t if SHA_RE.match(t) and os.path.isdir(os.path.join(root, t, "bin")) else ""


def read_meta(sha):
    try:
        with open(os.path.join(base_dir(), sha, "meta.json")) as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    ok = isinstance(m, dict) and m.get("sha") == sha and m.get("build_home") \
        and os.path.isdir(os.path.join(base_dir(), sha, "home"))
    return m if ok else None


def walk(top):
    """(relative path, lstat) of every entry under <top>, links never followed."""
    for d, dirs, files in os.walk(top):
        for n in dirs + files:
            p = os.path.join(d, n)
            yield os.path.relpath(p, top), os.lstat(p)


def rm(p):
    if os.path.isdir(p) and not os.path.islink(p):
        shutil.rmtree(p, ignore_errors=True)
    elif os.path.lexists(p):
        os.unlink(p)


# ---- build -------------------------------------------------------------------
def build_run(stage_home, sha):
    """The two scripts of a login's first minute, into <stage_home>."""
    root = env("FLEET_NODE_ROOT", DEFAULT_ROOT).rstrip("/")
    runas = env("FLEET_HOME_TEMPLATE_RUNAS", "nobody")
    path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    e = {"HOME": stage_home, "USER": runas if runas != "-" else pwd.getpwuid(os.getuid()).pw_name,
         "LOGNAME": runas, "PATH": path, "LANG": "en_US.UTF-8",
         "FLEET_CONF_DIR": os.path.join(stage_home, ".config", "claude-fleet"),
         "FLEET_NODE_ROOT": root, "FLEET_BOOTSTRAP_FLEET": "0", "FLEET_BOOTSTRAP_DOCTOR": "0",
         "FLEET_HOME_TEMPLATE_BUILD": "1", "TMPDIR": "/tmp"}
    cmd = os.environ.get("FLEET_HOME_TEMPLATE_BUILD_CMD", "")
    if cmd:
        argv = ["/bin/bash", "-c", cmd]
    else:
        ins = os.path.join(root, sha, "bin", "fleet-login-install.sh")
        argv = ["/bin/bash", "-c",
                'bash "$1" "$HOME/.claude/fleet" >/dev/null && bash "$HOME/.claude/fleet/bin/fleet-login-bootstrap.sh"',
                "_", ins]
    if runas != "-":
        argv = ["sudo", "-u", runas, "-H", "env", "-i"] + ["%s=%s" % kv for kv in sorted(e.items())] + argv
        e = None
    else:
        e = dict(os.environ, **e)
    p = subprocess.run(argv, cwd="/", env=e, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def scrub(home):
    for rel in STRIP:
        rm(os.path.join(home, rel))
    cj = os.path.join(home, ".claude.json")
    if os.path.isfile(cj) and not os.path.islink(cj):
        try:
            with open(cj) as f:
                d = json.load(f)
            if isinstance(d, dict):
                for k in CLAUDE_JSON_DROP:
                    d.pop(k, None)
                with open(cj, "w") as f:
                    json.dump(d, f, indent=2)
        except (OSError, ValueError):
            pass
    for d, dirs, files in os.walk(home):
        for n in files:
            if n.endswith(".pyc") or n == ".DS_Store":
                os.unlink(os.path.join(d, n))


def survey(home, names):
    """What a clone must rewrite: files / links naming the staging home (any of
    <names>, its spellings). A binary file naming it, or anything credential-
    shaped, is a refusal: (rewrite, relink, why)."""
    pats = [n.encode() for n in names]
    rewrite, relink = [], []
    for rel, st in walk(home):
        base = os.path.basename(rel)
        code = rel.startswith(CODE_TOPS)
        if base in CRED_NAMES and not code:
            return None, None, "a credential-shaped file %s" % rel
        p = os.path.join(home, rel)
        if stat.S_ISLNK(st.st_mode):
            if any(n in os.readlink(p) for n in names):
                relink.append(rel)
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_size > 64 << 20:
            continue
        with open(p, "rb") as f:
            b = f.read()
        if not code and CRED_RE.search(b):
            return None, None, "credential-shaped content in %s" % rel
        if any(n in b for n in pats):
            if b"\0" in b[:8192]:
                return None, None, "a binary file naming the staging home: %s" % rel
            rewrite.append(rel)
    return rewrite, relink, ""


def cmd_build(args):
    sha = args.get("sha") or current_sha()
    if not SHA_RE.match(sha or ""):
        die("no runtime version to build from (no %s/current)" % env("FLEET_NODE_ROOT", DEFAULT_ROOT), 1)
    if euid() != 0:
        die("build runs as root", 2)
    base = base_dir()
    if read_meta(sha) and not args.get("force"):
        print("ready %s — the template is there already" % sha[:12])
        return 0
    os.makedirs(base, exist_ok=True)
    os.chmod(base, 0o711)
    lock = os.path.join(base, "build.lock")
    try:
        os.mkdir(lock)
    except FileExistsError:
        if time.time() - os.stat(lock).st_mtime < 1800:
            die("another build is running (%s)" % lock, 1)
        os.utime(lock)
    t0 = time.time()
    stage = os.path.join(base, "build")
    home = os.path.join(stage, "home")
    try:
        rm(stage)
        os.makedirs(home)
        os.chmod(stage, 0o711)
        runas = env("FLEET_HOME_TEMPLATE_RUNAS", "nobody")
        if runas != "-":
            pw = pwd.getpwnam(runas)
            os.chown(home, pw.pw_uid, pw.pw_gid)
        os.chmod(home, 0o700)
        rc, out = build_run(home, sha)
        if rc != 0:
            sys.stderr.write(out[-4000:])
            die("building the template of %s failed (exit %d, its last lines above)" % (sha[:12], rc), 1)
        scrub(home)
        names = sorted({home, os.path.realpath(home), home.replace("/private/var/", "/var/", 1)},
                       key=len, reverse=True)
        rewrite, relink, why = survey(home, names)
        if why:
            die("refusing the template of %s: %s" % (sha[:12], why), 1)
        # root's and closed from here on (a test run, not root, keeps its own)
        if os.geteuid() == 0:
            for rel, st in walk(home):
                os.lchown(os.path.join(home, rel), 0, 0)
            os.chown(home, 0, 0)
        final = os.path.join(base, sha)
        tmp = os.path.join(base, ".%s.%d" % (sha, os.getpid()))
        rm(tmp)
        os.makedirs(tmp)
        os.chmod(tmp, 0o700)
        os.rename(home, os.path.join(tmp, "home"))
        meta = {"sha": sha, "build_home": home, "names": names, "rewrite": rewrite,
                "relink": relink, "built": utc(), "secs": round(time.time() - t0, 1)}
        with open(os.path.join(tmp, "meta.json"), "w") as f:
            json.dump(meta, f, indent=1)
        rm(final)
        os.rename(tmp, final)
        prune(base, sha)
        n = sum(1 for _ in walk(os.path.join(final, "home")))
        print("built %s — %d entries, %d to rewrite, %d links, %.1fs" % (
            sha[:12], n, len(rewrite), len(relink), time.time() - t0))
        return 0
    finally:
        rm(stage)
        try:
            os.rmdir(lock)
        except OSError:
            pass


def prune(base, keep):
    """Templates of other versions: only the newest one besides <keep> stays."""
    others = []
    for n in os.listdir(base):
        p = os.path.join(base, n)
        if n != keep and SHA_RE.match(n) and os.path.isdir(p):
            others.append((os.stat(p).st_mtime, p))
        elif n.startswith(".") and n[1:41].strip("0123456789abcdef") == "" and os.path.isdir(p):
            if time.time() - os.stat(p).st_mtime > 3600:
                rm(p)
    for _, p in sorted(others, reverse=True)[1:]:
        rm(p)


# ---- clone -------------------------------------------------------------------
def clonefile(src, dst):
    """One clonefile(2) of the whole tree (macOS APFS); False when it cannot."""
    if sys.platform != "darwin":
        return False
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        fn = libc.clonefile
    except (OSError, AttributeError):
        return False
    fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    return fn(src.encode(), dst.encode(), CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0


def cmd_clone(args):
    login, dst = args.get("login"), args.get("home")
    if not login or not dst or not os.path.isabs(dst):
        die("usage: clone <login> --home <absolute dir>", 2)
    if euid() != 0:
        die("clone runs as root", 2)
    try:
        pw = pwd.getpwnam(login)
    except KeyError:
        die("no login %s" % login, 2)
    if os.path.lexists(dst):
        die("%s exists — the wash moves the old home aside first" % dst, 1)
    sha = current_sha()
    meta = read_meta(sha) if sha else None
    if not meta:
        print("none %s — no template for this version (the home is made the old way)" % (sha[:12] or "-"))
        return 3
    t0 = time.time()
    src = os.path.join(base_dir(), sha, "home")
    try:
        how = "clonefile"
        if not clonefile(src, dst):
            how = "cp -c"
            if subprocess.run(["cp", "-c", "-pR", src, dst], stderr=subprocess.DEVNULL).returncode != 0:
                rm(dst)
                how = "cp"
                if subprocess.run(["cp", "-pR", src, dst]).returncode != 0:
                    raise OSError("cannot copy %s" % src)
        names = meta.get("names") or [meta["build_home"]]
        for rel in meta.get("rewrite", []):
            p = os.path.join(dst, rel)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            with open(p, "rb") as f:
                b = f.read()
            for n in names:
                b = b.replace(n.encode(), dst.encode())
            # a clone shares blocks with the template: write a NEW file in place
            tmp = p + ".tpl-rw"
            with open(tmp, "wb") as f:
                f.write(b)
            os.chmod(tmp, stat.S_IMODE(os.lstat(p).st_mode))
            os.replace(tmp, p)
        for rel in meta.get("relink", []):
            p = os.path.join(dst, rel)
            if not os.path.islink(p):
                continue
            t = os.readlink(p)
            for n in names:
                t = t.replace(n, dst)
            os.unlink(p)
            os.symlink(t, p)
        mark = os.path.join(dst, MARK)
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        with open(mark, "w") as f:
            f.write("%s %s\n" % (sha, utc()))
        uid, gid = pw.pw_uid, pw.pw_gid
        os.lchown(dst, uid, gid)
        for rel, _ in walk(dst):
            os.lchown(os.path.join(dst, rel), uid, gid)
        os.chmod(dst, 0o700)
    except (OSError, subprocess.SubprocessError) as e:
        rm(dst)
        die("cloning the template of %s to %s: %s — removed again" % (sha[:12], dst, e), 1)
    print("cloned %s → %s (%s, %.1fs)" % (sha[:12], dst, how, time.time() - t0))
    return 0


def cmd_status(args):
    sha = args.get("sha") or current_sha()
    m = read_meta(sha) if sha else None
    if not m:
        print("none %s" % (sha[:12] if sha else "-"))
        return 3
    n = sum(1 for _ in walk(os.path.join(base_dir(), sha, "home")))
    print("ready %s built %s (%d entries)" % (sha[:12], m.get("built", "?"), n))
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, rest, a = argv[0], argv[1:], {}
    i = 0
    while i < len(rest):
        x = rest[i]
        if x in ("--sha", "--home") and i + 1 < len(rest):
            a[x[2:]] = rest[i + 1]
            i += 2
        elif x == "--force":
            a["force"] = True
            i += 1
        elif not x.startswith("-") and cmd == "clone" and "login" not in a:
            a["login"] = x
            i += 1
        else:
            die("unknown argument %s" % x, 2)
    fn = {"build": cmd_build, "clone": cmd_clone, "status": cmd_status}.get(cmd)
    if not fn:
        die("unknown command %s (build | clone | status)" % cmd, 2)
    return fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
