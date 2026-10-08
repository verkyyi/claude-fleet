#!/usr/bin/env python3
"""fleet-tenant-scan.py — the three lines a new ordinary login must not cross,
tried for real from inside that login (issue #2298, EPIC #2293 C7).

Run AS the login under test (a freshly opened ordinary account, never the
admin): every item TRIES the way in and passes only when it is refused. One row
per item — 项 · 指标 · 结果 · 证据 · BREAK-IT — then the EPIC's four metrics,
each the number of ways that still worked; the run passes when all four are 0.

  ① 新用户的会话能读到订阅令牌的途径
     credsep     `fleet-credsep.sh status` + `check` (EPIC convention 1: the ONE
                 "separated" verdict)                         lease-unseparated-user
     cred-store  /var/db/fleet-cred/* — every login's store, the shared proxy's
                 — listed or read                             new-login-unseparated
     cred-scan   bin/fleet-cred-scan.py scan (#2135): accounts · codex · env ·
                 node.env → hub · the session's own files     new-login-unseparated
     forward     #2290: root's launcher / proxy copy and <LIB>/<login>.conf are
                 not this login's to change, the launcher ignores a login's
                 upstream keys, and the drill itself (cred-upstream-tenant-override)
                                                              cred-upstream-tenant-override
  ② 会话能拿到机器管理员权限的途径
     sudo        `sudo -n true`, a NOPASSWD rule, the admin / sudo / wheel group
                                                              tenant-sudo
     root-writes every root job (/Library/LaunchDaemons without UserName, a
                 systemd unit without User=): its program, scripts, logs and
                 working dir — inside a home, or writable by this login
                                                              root-log-in-home
  ③ 能看到别人会话内容的途径
     homes       every other home (and its .claude / .codex / .config/claude-fleet)
                 listed                                       tenant-other-home
     tmux        another uid's tmux socket dir                tenant-other-home
     shared      /Users/Shared/claude-fleet: another login's file readable,
                 beyond the by-design heavy/ and sessions/ rows tenant-other-home
     preview     every TCP port listening on this machine that is not this
                 login's (loopback + the tailnet IPv4): GET / /d/ /i/ answering
                 2xx without a code                            preview-no-code
  ④ 给新人开账号时要连的境外地址
     bootstrap   the machine's bootstrap cache holds claude-fleet (stable) and
                 Claude Code, and this login's checkout was cloned from it
                                                              bootstrap-abroad

Usage: fleet-tenant-scan.sh [--only a,b] [--json] [--hashes FILE] [--no-hub]
                            [--no-drill] [--no-ports]
  --hashes / --no-hub   handed to fleet-cred-scan.py scan
  --no-drill            skip running the #2290 drill (the static half still runs)
  --no-ports            skip the port sweep (preview SKIPs)
Exit: 0 every metric 0 · 1 a way in still works · 2 usage · 3 run as root

Nothing secret is printed: evidence names paths, ports, counts and HTTP codes,
never a file's content (a page's <title> at most).

Seams (the selftest's sandbox; never set in production): FLEET_TENANT_SCAN_UID
(the uid that counts as "this login"), _HOME, _HOMES, _TMUX (globs), _SHARED,
_DAEMONS, _SUDO, _GROUPS, _PORTS (no sweep), _HOSTS, _FLEET, _CREDSEP,
_CREDSCAN, _DRILL, _TOP (where the "can it swap a parent dir" walk stops),
_ALLOW_ROOT; FLEET_CREDSEP_ROOT_BASE / FLEET_CREDSEP_LIB and
FLEET_BOOTSTRAP_CACHE as their own scripts read them.
"""
import glob
import http.client
import json
import os
import plistlib
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MAC = sys.platform == "darwin"
E = os.environ.get

UID = int(E("FLEET_TENANT_SCAN_UID") or os.getuid())
try:
    ME = pwd.getpwuid(UID).pw_name
except KeyError:
    ME = "uid%d" % UID
HOME = os.path.realpath(E("FLEET_TENANT_SCAN_HOME") or os.path.expanduser("~"))
HOMES = E("FLEET_TENANT_SCAN_HOMES") or ("/Users" if MAC else "/home")
TMUX_GLOBS = (E("FLEET_TENANT_SCAN_TMUX") or "/private/tmp/tmux-* /tmp/tmux-*").split()
SHARED = E("FLEET_TENANT_SCAN_SHARED") or ("/Users/Shared/claude-fleet" if MAC else "/var/tmp/claude-fleet")
DAEMONS = E("FLEET_TENANT_SCAN_DAEMONS") or ("/Library/LaunchDaemons" if MAC else "/etc/systemd/system")
CRED_BASE = E("FLEET_CREDSEP_ROOT_BASE") or "/var/db/fleet-cred"
LIB = E("FLEET_CREDSEP_LIB") or ("/Library/Application Support/claude-fleet/credsep" if MAC
                                  else "/usr/local/lib/claude-fleet/credsep")
CACHE = E("FLEET_BOOTSTRAP_CACHE") or ("/Library/Application Support/claude-fleet/cache" if MAC
                                       else "/var/cache/claude-fleet")
FLEET = E("FLEET_TENANT_SCAN_FLEET") or os.path.join(HOME, ".claude", "fleet")
CREDSEP = E("FLEET_TENANT_SCAN_CREDSEP") or os.path.join(HERE, "fleet-credsep.sh")
CREDSCAN = E("FLEET_TENANT_SCAN_CREDSCAN") or os.path.join(HERE, "fleet-cred-scan.py")
DRILL = E("FLEET_TENANT_SCAN_DRILL") or os.path.join(HERE, "fleet-break-it-cred-sep-selftest.sh")
TOP = os.path.normpath(E("FLEET_TENANT_SCAN_TOP") or "/")
SHAPED = re.compile(r"sk-ant-(?:oat|ort|api|sid)\d{2}-[A-Za-z0-9_-]{20,}"
                    r"|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
                    r"|ccq_[A-Za-z0-9_-]{8,}")

METRICS = {
    1: "新用户的会话能读到订阅令牌的途径",
    2: "会话能拿到机器管理员权限的途径",
    3: "能看到别人会话内容的途径",
    4: "给新人开账号时要连的境外地址",
}
# id → (metric, BREAK-IT row) — every row is in docs/BREAK-IT.md (the selftest lints it)
ITEMS = [
    ("credsep", 1, "lease-unseparated-user"),
    ("cred-store", 1, "new-login-unseparated"),
    ("cred-scan", 1, "new-login-unseparated"),
    ("forward", 1, "cred-upstream-tenant-override"),
    ("sudo", 2, "tenant-sudo"),
    ("root-writes", 2, "root-log-in-home"),
    ("homes", 3, "tenant-other-home"),
    ("tmux", 3, "tenant-other-home"),
    ("shared", 3, "tenant-other-home"),
    ("preview", 3, "preview-no-code"),
    ("bootstrap", 4, "bootstrap-abroad"),
]
# by design readable to every login (fleet-heavy's slots, holds and logs — each
# login's own since #2299 — the machine-wide session counters): login names, pids, counts — never a session's content
SHARED_OK = re.compile(r"^(heavy/(slot-\d+|events(\.[^/]+)?\.log|(hold|wait)\.[^/]+)|sessions/[^/]+)$")


def run(argv, timeout=60, env=None):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
                           env=env, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, "%s: not found" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "%s: timed out after %ss" % (argv[0], timeout)


def last(text, n=1):
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    return " / ".join(lines[-n:])


def can_list(path):
    try:
        os.listdir(path)
        return True
    except OSError:
        return False


def can_read(path):
    try:
        with open(path, "rb") as f:
            f.read(1)
        return True
    except OSError:
        return False


def owner(path):
    try:
        return os.lstat(path).st_uid
    except OSError:
        return None


def writable(path):
    """Can this login change what root later reads or writes at `path`? The
    file itself writable, a symlink of its own, or any directory above it that
    lets it swap the entry (a sticky dir only for an entry it owns or that is
    not there yet). '' when not, else the reason."""
    path = os.path.normpath(path)
    if os.path.islink(path) and owner(path) == UID:
        return "软链属于本账号"
    # a symlink's own mode is 0777 everywhere: what counts is its target (and,
    # below, the directory that holds the link)
    if os.path.exists(path) and not os.path.isdir(path) and os.access(path, os.W_OK):
        return "可写"
    child, d = path, os.path.dirname(path)
    while True:
        if TOP != "/" and d == TOP:
            return ""
        try:
            st = os.stat(d)
        except OSError:
            st = None
        if st is not None and os.access(d, os.W_OK):
            sticky = st.st_mode & stat.S_ISVTX
            if not sticky or not os.path.lexists(child) or owner(child) == UID:
                return "上级目录 %s 可写" % d
        if d in ("/", ""):
            return ""
        child, d = d, os.path.dirname(d)


def in_home(path):
    p = os.path.normpath(path)
    h = os.path.normpath(HOMES)
    return p.startswith(h + "/") and not p.startswith(os.path.join(h, "Shared") + "/")


class Item:
    def __init__(self, iid, metric, row):
        self.id, self.metric, self.row = iid, metric, row
        self.count, self.ev, self.skip = 0, [], ""

    def hit(self, why):
        self.count += 1
        self.ev.append(why)

    def note(self, why):
        self.ev.append(why)

    @property
    def result(self):
        return "SKIP" if self.skip else ("HIT" if self.count else "PASS")


# ---------------------------------------------------------------- ① ---------
def i_credsep(it, a):
    if not os.path.exists(CREDSEP):
        it.skip = "没有 %s" % CREDSEP
        return
    rc, out = run(["bash", CREDSEP, "status"])
    crc, cout = run(["bash", CREDSEP, "check"])
    if rc != 0 or not out.strip().startswith("separated"):
        it.hit("status：%s（rc %d）" % (last(out) or "无输出", rc))
    elif crc != 0 or not cout.strip().startswith("credsep: OK"):
        it.hit("separated，但 check：%s" % (last(cout)[:200] or "rc %d" % crc))
    else:
        it.note("separated · check OK")


def i_cred_store(it, a):
    if not os.path.isdir(CRED_BASE):
        it.note("%s 不存在" % CRED_BASE)
        return
    try:
        names = sorted(os.listdir(CRED_BASE))
    except OSError:
        it.note("%s 列不出（最严）" % CRED_BASE)
        return
    n = 0
    for name in names:
        p = os.path.join(CRED_BASE, name)
        n += 1
        if os.path.isdir(p):
            if can_list(p):
                it.hit("%s/ 可列出" % p)
        elif can_read(p):
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    txt = f.read(1 << 20)
            except OSError:
                txt = ""
            if SHAPED.search(txt):
                it.hit("%s 可读且含凭据形状的串" % p)
    if not it.count:
        it.note("%d 项，各登录的存储都 Permission denied" % n)


def i_cred_scan(it, a):
    if not os.path.exists(CREDSCAN):
        it.skip = "没有 %s" % CREDSCAN
        return
    argv = [sys.executable, "-I", CREDSCAN, "scan"]
    if a.hashes:
        argv += ["--hashes", a.hashes]
    if not a.hub:
        argv.append("--no-hub")
    rc, out = run(argv, timeout=300)
    m = re.search(r"routes-with-credential=(\d+)", out)
    if not m:
        it.skip = "cred-scan 没有给出结论（rc %d）：%s" % (rc, last(out))
        return
    n = int(m.group(1))
    hits = [l.split()[0] + " " + l.split()[1] for l in out.splitlines()
            if re.match(r"^[①②③④f]", l) and re.search(r"real=[1-9]" if a.hashes else r"shaped=[1-9]", l)]
    it.count = n
    it.note(last(out) + ("；命中：" + "，".join(hits) if hits else ""))
    if n and not a.hashes:
        it.note("没给 --hashes：形状命中也可能是 fleet 自带测试里的假令牌——真机上用 --hashes 判真假")


def i_forward(it, a):
    me_conf = os.path.join(LIB, ME + ".conf")
    launch = os.path.join(LIB, "fleet-credsep-launch.py")
    seen = False
    for p in (LIB, launch, os.path.join(LIB, "fleet-cred-proxy.py"), me_conf):
        if not os.path.lexists(p):
            continue
        seen = True
        why = writable(p)
        if why:
            it.hit("%s：%s（可改凭据发往哪里）" % (p, why))
    if os.path.isfile(launch):
        try:
            src = open(launch, encoding="utf-8", errors="replace").read()
        except OSError:
            src = None
        if src is not None and "LOGIN_KEYS" not in src:
            it.hit("%s 是 #2290 之前的版本：登录自己的配置能改上游地址" % launch)
    if not seen:
        it.note("本机没有 root 的凭据启动器（%s）" % LIB)
    if a.drill:
        drill = DRILL
        if not os.path.exists(drill):
            it.note("没有演练脚本 %s" % drill)
        else:
            env = dict(os.environ, BREAK_ONLY="cred-upstream-tenant-override")
            rc, out = run(["bash", drill], timeout=180, env=env)
            line = next((l for l in out.splitlines() if "cred-upstream-tenant-override" in l), last(out))
            if rc != 0 or not line.startswith("PASS"):
                it.hit("演练 cred-upstream-tenant-override：%s" % line.strip()[:200])
            else:
                it.note("演练：" + re.sub(r"\s+", " ", line.strip())[:120])
    if not it.count and seen:
        it.note("root 的启动器 / 代理副本 / %s.conf 本账号都改不了" % ME)


# ---------------------------------------------------------------- ② ---------
def i_sudo(it, a):
    sudo = E("FLEET_TENANT_SCAN_SUDO") or "sudo"
    rc, out = run([sudo, "-n", "true"], timeout=20)
    if rc == 0:
        it.hit("sudo -n true 成功：免密 sudo")
    else:
        lrc, lout = run([sudo, "-n", "-l"], timeout=20)
        rules = [l.strip() for l in lout.splitlines() if "NOPASSWD" in l]
        if lrc == 0 and rules:
            it.hit("免密的 sudo 规则：%s" % rules[0][:160])
        else:
            it.note("sudo -n true 被拒")
    if E("FLEET_TENANT_SCAN_GROUPS") is not None:
        groups = E("FLEET_TENANT_SCAN_GROUPS").split()
    else:
        _, g = run(["id", "-Gn"], timeout=10)
        groups = g.split()
    adm = [x for x in groups if x in ("admin", "sudo", "wheel")]
    if adm:
        it.hit("在 %s 组：有密码就能 sudo" % "/".join(adm))
    else:
        it.note("不在 admin / sudo / wheel 组")


def job_paths(argv, extra):
    out = []
    for i, x in enumerate(argv):
        if not isinstance(x, str):
            continue
        if x.startswith("/"):
            out.append(x)
        elif i > 0 and argv[i - 1] in ("-c",):
            out += [m.group(1) for m in re.finditer(r"['\"](/[^'\"]+)['\"]", x)]
            out += [t for t in x.split() if t.startswith("/") and "'" not in t and '"' not in t]
    out += [p for p in extra if isinstance(p, str) and p.startswith("/")]
    seen, res = set(), []
    for p in out:
        p = p.rstrip(";")
        if p and p not in seen and p != "/dev/null":
            seen.add(p)
            res.append(p)
    return res


def root_jobs():
    """[(name, [paths])] for every job the init system runs as root."""
    jobs = []
    if not os.path.isdir(DAEMONS):
        return None
    for f in sorted(os.listdir(DAEMONS)):
        p = os.path.join(DAEMONS, f)
        if f.startswith(".") or not os.path.isfile(p):
            continue
        if f.endswith(".plist"):
            try:
                with open(p, "rb") as fh:
                    d = plistlib.load(fh)
            except Exception:
                continue
            if not isinstance(d, dict) or d.get("UserName") not in (None, "root"):
                continue
            argv = d.get("ProgramArguments") or ([d["Program"]] if d.get("Program") else [])
            if d.get("Program") and argv and argv[0] != d["Program"]:
                argv = [d["Program"]] + list(argv)
            jobs.append((f, job_paths(list(argv), [d.get("StandardOutPath"), d.get("StandardErrorPath"),
                                                   d.get("WorkingDirectory")])))
        elif f.endswith(".service"):
            try:
                txt = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            kv = {}
            for line in txt.splitlines():
                m = re.match(r"^\s*([A-Za-z]+)\s*=\s*(.*)$", line)
                if m:
                    kv.setdefault(m.group(1), m.group(2).strip())
            if kv.get("User") not in (None, "", "root"):
                continue
            argv = kv.get("ExecStart", "").lstrip("@-:+!").split()
            extra = [kv.get("WorkingDirectory")]
            for k in ("StandardOutput", "StandardError"):
                m = re.match(r"^(?:append|file|truncate):(.+)$", kv.get(k, ""))
                if m:
                    extra.append(m.group(1))
            jobs.append((f, job_paths(argv, extra)))
    return jobs


def i_root_writes(it, a):
    jobs = root_jobs()
    if jobs is None:
        it.skip = "没有 %s" % DAEMONS
        return
    for name, paths in jobs:
        bad = []
        for p in paths:
            if in_home(p):
                bad.append("%s 在家目录里" % p)
                continue
            why = writable(p)
            if why:
                bad.append("%s %s" % (p, why))
        if bad:
            it.hit("%s：%s" % (name, "；".join(bad[:2])))
    if not it.count:
        it.note("%d 个 root 任务，程序 / 脚本 / 日志都不在家目录、本账号改不了" % len(jobs))


# ---------------------------------------------------------------- ③ ---------
def i_homes(it, a):
    if not os.path.isdir(HOMES):
        it.skip = "没有 %s" % HOMES
        return
    n = 0
    for name in sorted(os.listdir(HOMES)):
        h = os.path.join(HOMES, name)
        if name.startswith(".") or name == "Shared" or not os.path.isdir(h) or os.path.realpath(h) == HOME:
            continue
        n += 1
        open_ = [s for s in ("", ".claude", ".claude/projects", ".codex", ".config/claude-fleet")
                 if can_list(os.path.join(h, s))]
        if open_:
            it.hit("%s 可列出：%s" % (h, ", ".join("~/" + s if s else "~" for s in open_)))
    if not it.count:
        it.note("%d 个别人的家目录，都列不出" % n)


def i_tmux(it, a):
    dirs = sorted(set(os.path.realpath(d) for g in TMUX_GLOBS for d in glob.glob(g) if os.path.isdir(d)))
    n = 0
    for d in dirs:
        m = re.search(r"tmux-(\d+)$", d)
        if not m or int(m.group(1)) == UID:
            continue
        n += 1
        if can_list(d):
            it.hit("%s 可列出（别人的 tmux 套接字）" % d)
    if not it.count:
        it.note("%d 个别人的 tmux 目录，都列不出" % n)


def i_shared(it, a):
    if not os.path.isdir(SHARED):
        it.note("%s 不存在" % SHARED)
        return
    n = ok = 0
    for dp, dns, fns in os.walk(SHARED):
        if dp[len(SHARED):].count("/") >= 4:
            dns[:] = []
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, SHARED)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if st.st_uid == UID or not stat.S_ISREG(st.st_mode) or st.st_size == 0:
                continue
            n += 1
            if not can_read(p):
                continue
            if SHARED_OK.match(rel):
                ok += 1
                continue
            it.hit("%s（属于 %s）可读" % (p, pwd_name(st.st_uid)))
        if n > 5000:
            break
    if not it.count:
        it.note("别人的文件 %d 个；可读的 %d 个都是设计如此的（heavy/ 槽位与日志、sessions/ 计数）" % (n, ok))


def pwd_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def own_ports():
    if E("FLEET_TENANT_SCAN_UID"):
        return set()
    rc, out = run(["lsof", "-nP", "-a", "-u", ME, "-iTCP", "-sTCP:LISTEN", "-Fn"], timeout=30)
    return {int(m.group(1)) for m in re.finditer(r"^n.*:(\d+)$", out, re.M)}


def tailnet_ip():
    for t in (shutil.which("tailscale"), "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        if t and os.path.exists(t):
            rc, out = run([t, "ip", "-4"], timeout=5)
            m = re.search(r"^(100\.\d+\.\d+\.\d+)$", out, re.M)
            if rc == 0 and m:
                return m.group(1)
    return None


def listening(host, ports, wait=0.4):
    """Ports accepting a connection on host — non-blocking, a batch at a time (a
    tailnet address drops rather than refuses, so one-by-one would take hours)."""
    import errno
    import resource
    import selectors
    import time
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 4096 if hard == resource.RLIM_INFINITY else min(hard, 4096)
    if soft < want:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
            soft = want
        except (ValueError, OSError):
            pass
    batch = max(32, soft - 64)
    ports, up = list(ports), []
    for i in range(0, len(ports), batch):
        sel = selectors.DefaultSelector()
        socks = []
        for p in ports[i:i + batch]:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setblocking(False)
            socks.append(s)
            rc = s.connect_ex((host, p))
            if rc == 0:
                up.append(p)
            elif rc in (errno.EINPROGRESS, errno.EAGAIN, errno.EWOULDBLOCK):
                sel.register(s, selectors.EVENT_WRITE, p)
        t0 = time.time()
        while sel.get_map() and time.time() - t0 < wait:
            for key, _ in sel.select(max(0.01, wait - (time.time() - t0))):
                if key.fileobj.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0:
                    up.append(key.data)
                sel.unregister(key.fileobj)
        sel.close()
        for s in socks:
            s.close()
    return sorted(set(up))


# a machine service that greets any visitor and carries no session: tailscaled's
# PeerAPI on the tailnet address ("This is my Tailscale device …")
SYSTEM_PAGE = re.compile(r"This is my Tailscale device")


def probe(host, port):
    """The first anonymous path answering 2xx → (path, code, title), else None."""
    for path in ("/", "/d/", "/i/"):
        c = http.client.HTTPConnection(host, port, timeout=2)
        try:
            c.request("GET", path, headers={"Host": "%s:%d" % (host, port)})
            r = c.getresponse()
            body = r.read(8192).decode("utf-8", "replace")
        except Exception:
            return None                     # not HTTP (or TLS): nothing a browser link opens
        finally:
            c.close()
        if 200 <= r.status < 300:
            if SYSTEM_PAGE.search(body):
                return "system"
            m = re.search(r"<title>([^<]{0,80})", body, re.I)
            return path, r.status, (m.group(1).strip() if m else "%d 字节" % len(body))
    return None


def i_preview(it, a):
    if not a.ports:
        it.skip = "--no-ports"
        return
    if E("FLEET_TENANT_SCAN_PORTS") is not None:
        ports = [int(x) for x in E("FLEET_TENANT_SCAN_PORTS").split() if x.isdigit()]
        mine = set()
    else:
        ports = range(1, 65536)
        mine = own_ports()
    hosts = (E("FLEET_TENANT_SCAN_HOSTS") or "").split() or ["127.0.0.1"] + ([tailnet_ip()] if tailnet_ip() else [])
    n, system = 0, []
    for host in hosts:
        for p in listening(host, [p for p in ports if p not in mine]):
            n += 1
            r = probe(host, p)
            if r == "system":
                system.append("%s:%d" % (host, p))
            elif r:
                it.hit("http://%s:%d%s → %d「%s」" % (host, p, r[0], r[1], r[2]))
    if system:
        it.note("不计：%s（tailscaled 的 PeerAPI，机器服务、不含会话）" % ", ".join(system))
    if not it.count:
        it.note("%s 上 %d 个不属于本账号的端口，匿名 GET / /d/ /i/ 都不是 2xx" % (" / ".join(hosts), n))


# ---------------------------------------------------------------- ④ ---------
def i_bootstrap(it, a):
    mirror = os.path.join(CACHE, "claude-fleet.git")
    have_git = os.path.isfile(os.path.join(mirror, "HEAD")) and (
        os.path.exists(os.path.join(mirror, "refs", "tags", "stable"))
        or run(["git", "--git-dir", mirror, "rev-parse", "-q", "--verify", "refs/tags/stable"], timeout=20)[0] == 0)
    if not have_git:
        it.hit("缓存里没有 claude-fleet（%s）：开号要连 github.com" % mirror)
    else:
        rc, log = run(["git", "-C", FLEET, "reflog", "--format=%gs"], timeout=20)
        first = (log.strip().splitlines() or [""])[-1]
        if rc == 0 and first.startswith("clone: from") and "://" in first:
            it.hit("本账号的 %s 是从网上克隆的（%s）" % (FLEET, re.sub(r"//[^/@]*@", "//", first)))
        elif rc == 0 and first.startswith("clone: from"):
            it.note("fleet 从本机缓存克隆")
        else:
            it.note("缓存里有 claude-fleet")
    try:
        ver = open(os.path.join(CACHE, "claude", "current"), encoding="utf-8").read().strip()
    except OSError:
        ver = ""
    if not ver or not os.path.isfile(os.path.join(CACHE, "claude", ver, "claude")):
        it.hit("缓存里没有 Claude Code（%s/claude）：开号要连 claude.ai" % CACHE)
    else:
        it.note("缓存里有 Claude Code %s" % ver)


FUNCS = {
    "credsep": i_credsep, "cred-store": i_cred_store, "cred-scan": i_cred_scan, "forward": i_forward,
    "sudo": i_sudo, "root-writes": i_root_writes, "homes": i_homes, "tmux": i_tmux,
    "shared": i_shared, "preview": i_preview, "bootstrap": i_bootstrap,
}


class Args:
    only, json, hashes, hub, drill, ports = None, False, None, True, True, True


def parse(argv):
    a, i = Args(), 0
    while i < len(argv):
        x = argv[i]
        if x in ("--only", "--hashes") and i + 1 < len(argv):
            if x == "--only":
                a.only = [s for s in argv[i + 1].split(",") if s]
                bad = [s for s in a.only if s not in FUNCS]
                if bad:
                    raise ValueError("unknown item(s): %s (known: %s)" % (", ".join(bad), ", ".join(FUNCS)))
            else:
                a.hashes = argv[i + 1]
            i += 2
            continue
        if x == "--json":
            a.json = True
        elif x == "--no-hub":
            a.hub = False
        elif x == "--no-drill":
            a.drill = False
        elif x == "--no-ports":
            a.ports = False
        elif x in ("-h", "--help"):
            raise SystemExit(print(__doc__) or 0)
        else:
            raise ValueError("unknown argument %s" % x)
        i += 1
    return a


def cell(s):
    return s.replace("|", "\\|").replace("\n", " ")


def main(argv):
    try:
        a = parse(argv)
    except ValueError as e:
        print("fleet-tenant-scan: %s" % e, file=sys.stderr)
        return 2
    if os.getuid() == 0 and E("FLEET_TENANT_SCAN_ALLOW_ROOT") != "1":
        print("fleet-tenant-scan: refusing to run as root — root reads everything; run it AS the login under "
              "test (sudo -u <login> -i bash …/fleet-tenant-scan.sh)", file=sys.stderr)
        return 3
    items = []
    for iid, metric, row in ITEMS:
        if a.only and iid not in a.only:
            continue
        it = Item(iid, metric, row)
        try:
            FUNCS[iid](it, a)
        except Exception as e:          # an item that cannot run is a SKIP, never a silent PASS
            it.skip = "出错：%s: %s" % (type(e).__name__, e)
        items.append(it)
    per = {m: sum(it.count for it in items if it.metric == m) for m in METRICS}
    skipped = [it.id for it in items if it.skip]
    ok = not any(per.values())
    verdict = "PASS" if ok else "FAIL"
    if a.json:
        print(json.dumps({
            "login": ME, "uid": UID, "verdict": verdict, "skipped": skipped,
            "metrics": {str(m): {"name": METRICS[m], "ways": per[m]} for m in METRICS},
            "items": [{"id": it.id, "metric": it.metric, "result": it.result, "ways": it.count,
                       "evidence": it.skip or "；".join(it.ev), "break_it": it.row} for it in items],
        }, ensure_ascii=False, indent=1))
    else:
        print("| 项 | 指标 | 结果 | 证据 | BREAK-IT |")
        print("|---|---|---|---|---|")
        for it in items:
            print("| %s | %s | %s | %s | `%s` |" % (it.id, "①②③④"[it.metric - 1], it.result,
                                                    cell(it.skip or "；".join(it.ev) or "-"), it.row))
        print()
        for m in METRICS:
            print("%s %s：%d" % ("①②③④"[m - 1], METRICS[m], per[m]))
        print("tenant-scan: %s (login=%s uid=%d, %d items%s)" % (
            verdict, ME, UID, len(items), ", skipped: " + " ".join(skipped) if skipped else ""))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
