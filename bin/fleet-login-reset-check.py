#!/usr/bin/env python3
"""fleet-login-reset-check.py <login> — what the last person left on a login.

Issue #3507 (EPIC #3500 C11). A login washed for the next person — a Mac's
spare login (`fleet-login-reset.sh`, #3505), a recycled one (`remove` → `reset`,
#3504), a cloud pod before it is handed out or destroyed (#3553) — must hold
nothing of the person before. This script is the ONE list of what can be left
behind (CATEGORIES below), and a check for each kind. Root, Mac and Linux the
same file; it reads, it never cleans.

    fleet-login-reset-check.py <login> [--since <epoch>] [--json]
    fleet-login-reset-check.py --list [--platform darwin|linux]

Output: one line per dirty category on stderr (`reset-check: <cat> (<n>): …`),
then the verdict, the LAST line on stdout:
    reset: clean                     exit 0
    reset: dirty <cat>,<cat>,…       exit 1
Exit 2 = usage, or no such login.

--since <epoch> is the moment the wash (or the pod) started: then only what is
OLDER than it counts — a file by its ctime (no user can set it back; a rename
or chown bumps it, so a wash must delete, never chown in place), a process by
its start. Without it, anything there at all counts (a home is judged against
the system's skeleton: /System/Library/User Template on a Mac, /etc/skel on
Linux). A category that cannot be read (no root, a command that fails) is
dirty too: what was not looked at is never called clean.

The hub's half of the list — the login's relay pass, its 「家」 record and the
entry key list, its node token, unused join codes, quota leases — is the hub's
own check (#3504, BREAK-IT `spare-recycle-dirty`); this script is the machine's.

--root <dir> prefixes every system path (a sandbox: the selftest); --home,
--uid, --homes-root, --skel, --node-state, --cred-base, --archive-dir and
--platform override one each. Pinned by bin/fleet-login-reset-check-selftest.sh
and BREAK-IT `spare-reuse-leaks`.
"""
import argparse
import json
import os
import plistlib
import pwd
import stat
import subprocess
import sys
import time

# id, platform (both | darwin | linux), what it is. The order is the verdict's.
CATEGORIES = [
    ("home", "both", "家目录里骨架之外的东西"),
    ("keychain", "darwin", "Mac 钥匙串（~/Library/Keychains）"),
    ("git-cred", "both", "git / gh 凭据与身份（~/.git-credentials ~/.gitconfig ~/.config/gh ~/.netrc）"),
    ("ssh", "both", "ssh 私钥与配置（~/.ssh，authorized_keys 除外）"),
    ("authorized-keys", "both", "~/.ssh/authorized_keys"),
    ("fleet-conf", "both", "~/.config/claude-fleet"),
    ("credsep", "both", "凭据隔离库 <cred-base>/<login>/"),
    ("entry-keys", "both", "入口钥匙文件 <state>/entry/keys/<login>"),
    ("task-state", "both", "整机守护里的任务状态 <state>/logins/<login>/"),
    ("onboard", "both", "管理员目录里的开号材料 ~admin/<login>-onboard/"),
    ("crontab", "both", "crontab"),
    ("launchd", "darwin", "LaunchAgents / 以它为 UserName 的 LaunchDaemons"),
    ("systemd-user", "linux", "systemd --user 单元与 linger"),
    ("processes", "both", "该 UID 的进程"),
    ("tmux", "both", "tmux 套接字（/tmp/tmux-<uid>）"),
    ("outside-files", "both", "家以外属该 UID 的文件（/tmp /var/tmp /Users/Shared，存档目录除外）"),
]

# Paths under the home that belong to a category of their own (the most specific
# wins); everything else under the home is `home`.
HOME_CLAIMS = [
    ("Library/Keychains", "keychain"),
    ("Library/LaunchAgents", "launchd"),
    (".git-credentials", "git-cred"),
    (".gitconfig", "git-cred"),
    (".config/git", "git-cred"),
    (".config/gh", "git-cred"),
    (".netrc", "git-cred"),
    (".ssh/authorized_keys", "authorized-keys"),
    (".ssh/authorized_keys2", "authorized-keys"),
    (".ssh", "ssh"),
    (".config/claude-fleet", "fleet-conf"),
    (".config/systemd/user", "systemd-user"),
]

SKEL = {
    "darwin": ["/System/Library/User Template/Non_localized",
               "/System/Library/User Template/English.lproj"],
    "linux": ["/etc/skel"],
}
OUTSIDE = {
    "darwin": ["/private/tmp", "/private/var/tmp", "/Users/Shared"],
    "linux": ["/tmp", "/var/tmp", "/dev/shm"],
}
TMUX_TMP = {"darwin": "/private/tmp", "linux": "/tmp"}
HOMES = {"darwin": "/Users", "linux": "/home"}
ADMIN_HOMES = {"darwin": ["/var/root"], "linux": ["/root"]}
MAX_ITEMS = 200


class Check(object):
    def __init__(self, a):
        self.a = a
        self.plat = a.platform
        self.since = a.since
        self.found = {}       # category → [item]
        self.now = time.time()

    def p(self, path):
        """A system path, under --root when given."""
        return (self.a.root.rstrip("/") + path) if self.a.root else path

    def add(self, cat, item):
        lst = self.found.setdefault(cat, [])
        if len(lst) < MAX_ITEMS:
            lst.append(item)

    def unknown(self, cat, why):
        self.add(cat, "cannot read: " + why)

    def old(self, st):
        """Does this entry predate the wash? (Without --since: it exists.)"""
        return self.since is None or st.st_ctime < self.since

    def judged(self, path, st):
        """A directory speaks through what is in it: it counts by itself only
        when it is empty and there is no --since (a directory's ctime moves
        whenever an entry in it comes or goes)."""
        if not stat.S_ISDIR(st.st_mode):
            return True
        if self.since is not None:
            return False
        try:
            return not os.listdir(path)
        except OSError:
            return True

    def walk(self, cat, top, owner=None, skip=()):
        """Every entry under top (top included) older than the wash."""
        try:
            st = os.lstat(top)
        except FileNotFoundError:
            return
        except OSError as e:
            return self.unknown(cat, "%s: %s" % (top, e.strerror))
        if owner is None and self.judged(top, st) and self.old(st):
            self.add(cat, top)
        if not stat.S_ISDIR(st.st_mode):
            return
        errs = []
        for d, dirs, files in os.walk(top, onerror=errs.append):
            keep = []
            for n in dirs:
                full = os.path.join(d, n)
                if full in skip:
                    continue
                keep.append(n)
            dirs[:] = keep
            for n in dirs + files:
                full = os.path.join(d, n)
                try:
                    st = os.lstat(full)
                except OSError:
                    continue
                if owner is not None and st.st_uid != owner:
                    continue
                if self.judged(full, st) and self.old(st):
                    self.add(cat, full)
        for e in errs:
            if owner is None or e.errno not in (13, 1):
                self.unknown(cat, "%s: %s" % (getattr(e, "filename", top), e.strerror))

    # ---- the home: the skeleton, then each path to its category
    def skeleton(self):
        rel = set()
        for d in (self.a.skel or [self.p(s) for s in SKEL[self.plat]]):
            for top, dirs, files in os.walk(d):
                for n in dirs + files:
                    rel.add(os.path.relpath(os.path.join(top, n), d))
        return rel

    def home(self):
        h = self.a.home
        if not os.path.isdir(h):
            return
        skel = self.skeleton() if self.since is None else set()
        claims = sorted(HOME_CLAIMS, key=lambda c: -len(c[0]))

        def cat_of(rel):
            for pre, cat in claims:
                if rel == pre or rel.startswith(pre + "/"):
                    return cat
            return "home"

        errs = []
        for d, dirs, files in os.walk(h, onerror=errs.append):
            for n in list(dirs) + files:
                full = os.path.join(d, n)
                rel = os.path.relpath(full, h)
                if rel in skel:
                    continue
                try:
                    st = os.lstat(full)
                except OSError:
                    continue
                cat = cat_of(rel)
                if cat in self.skipped:
                    cat = "home"
                if self.judged(full, st) and self.old(st):
                    self.add(cat, full)
        for e in errs:
            self.unknown("home", "%s: %s" % (getattr(e, "filename", h), e.strerror))

    def cmd(self, argv):
        try:
            r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, "", str(e)
        return r.returncode, r.stdout, r.stderr

    def crontab(self):
        rc, out, err = self.cmd(["crontab", "-l", "-u", self.a.login])
        if rc is None:
            return self.unknown("crontab", err)
        if rc != 0:
            if "no crontab" in err.lower():
                return
            return self.unknown("crontab", (err.strip() or "exit %d" % rc).splitlines()[0])
        for line in out.splitlines():
            s = line.strip()
            if s and not s.startswith("#"):
                self.add("crontab", s)

    def launchd(self):
        d = self.p("/Library/LaunchDaemons")
        try:
            names = sorted(os.listdir(d))
        except FileNotFoundError:
            return
        except OSError as e:
            return self.unknown("launchd", "%s: %s" % (d, e.strerror))
        L = self.a.login
        for n in names:
            full = os.path.join(d, n)
            mine = n.startswith("com.claude-fleet.%s." % L) or n == "com.ccquota.agent.%s.plist" % L
            if not mine and n.endswith(".plist"):
                try:
                    with open(full, "rb") as f:
                        mine = plistlib.load(f).get("UserName") == L
                except Exception:
                    mine = False
            if mine:
                try:
                    st = os.lstat(full)
                except OSError:
                    continue
                if self.old(st):
                    self.add("launchd", full)

    def linger(self):
        f = os.path.join(self.p("/var/lib/systemd/linger"), self.a.login)
        try:
            st = os.lstat(f)
        except FileNotFoundError:
            return
        except OSError as e:
            return self.unknown("systemd-user", "%s: %s" % (f, e.strerror))
        if self.old(st):
            self.add("systemd-user", f)

    @staticmethod
    def etime(s):
        days = 0
        if "-" in s:
            dd, s = s.split("-", 1)
            days = int(dd)
        parts = [int(x) for x in s.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]

    def processes(self):
        rc, out, err = self.cmd(["ps", "-A", "-o", "uid=", "-o", "pid=", "-o", "etime=", "-o", "comm="])
        if rc != 0:
            return self.unknown("processes", (err.strip() or "ps exit %s" % rc).splitlines()[0])
        me = os.getpid()
        for line in out.splitlines():
            f = line.split(None, 3)
            if len(f) < 3:
                continue
            try:
                uid, pid, age = int(f[0]), int(f[1]), self.etime(f[2])
            except ValueError:
                continue
            if uid != self.a.uid or pid == me:
                continue
            if self.since is None or self.now - age < self.since:
                self.add("processes", "%d %s" % (pid, f[3] if len(f) > 3 else "?"))

    def onboard(self):
        roots = [self.a.homes_root] + [self.p(x) for x in ADMIN_HOMES[self.plat]]
        for r in roots:
            try:
                names = sorted(os.listdir(r))
            except FileNotFoundError:
                continue
            except OSError as e:
                self.unknown("onboard", "%s: %s" % (r, e.strerror))
                continue
            cands = [os.path.join(r, n, self.a.login + "-onboard") for n in names]
            cands.append(os.path.join(r, self.a.login + "-onboard"))   # root's own home
            for c in cands:
                if os.path.realpath(c).startswith(os.path.realpath(self.a.home) + "/"):
                    continue
                self.walk("onboard", c)

    def run(self):
        self.skipped = set(c for c, plat, _ in CATEGORIES if plat not in ("both", self.plat))
        st = self.a.node_state or self.p("/var/db/fleet-node")
        self.home()
        self.walk("credsep", os.path.join(self.a.cred_base or self.p("/var/db/fleet-cred"), self.a.login))
        self.walk("entry-keys", os.path.join(st, "entry", "keys", self.a.login))
        self.walk("task-state", os.path.join(st, "logins", self.a.login))
        self.onboard()
        self.crontab()
        if self.plat == "darwin":
            self.launchd()
        else:
            self.linger()
        self.processes()
        tmux = os.path.join(self.p(TMUX_TMP[self.plat]), "tmux-%d" % self.a.uid)
        self.walk("tmux", tmux)
        archive = self.a.archive_dir or self.p("/Users/Shared/offboarded")
        home = os.path.realpath(self.a.home)
        for top in OUTSIDE[self.plat]:
            top = self.p(top)
            if os.path.realpath(top) == home or home.startswith(os.path.realpath(top) + "/"):
                continue
            self.walk("outside-files", top, owner=self.a.uid,
                      skip=(tmux, archive, self.a.home))
        return [c for c, plat, _ in CATEGORIES if c in self.found and c not in self.skipped]


def main():
    ap = argparse.ArgumentParser(prog="fleet-login-reset-check.py",
                                 description="what the last person left on a login (#3507)")
    ap.add_argument("login", nargs="?")
    ap.add_argument("--list", action="store_true", help="print the category table and exit")
    ap.add_argument("--since", type=float, help="epoch the wash started: only older things count")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--platform", choices=("darwin", "linux"),
                    default="darwin" if sys.platform == "darwin" else "linux")
    ap.add_argument("--root", default="", help="prefix for every system path (a sandbox)")
    ap.add_argument("--home")
    ap.add_argument("--uid", type=int)
    ap.add_argument("--homes-root")
    ap.add_argument("--skel", action="append")
    ap.add_argument("--node-state", default=os.environ.get("FLEET_NODE_STATE"))
    ap.add_argument("--cred-base", default=os.environ.get("FLEET_CREDSEP_ROOT_BASE"))
    ap.add_argument("--archive-dir", default=os.environ.get("FLEET_OFFBOARD_ARCHIVE_DIR"))
    a = ap.parse_args()
    if a.list:
        for c, plat, what in CATEGORIES:
            if plat in ("both", a.platform):
                print("%s\t%s\t%s" % (c, plat, what))
        return 0
    if not a.login:
        ap.print_usage(sys.stderr)
        return 2
    if a.home is None or a.uid is None:
        try:
            pw = pwd.getpwnam(a.login)
        except KeyError:
            print("fleet-login-reset-check: no such login: %s" % a.login, file=sys.stderr)
            return 2
        a.home = a.home or pw.pw_dir
        a.uid = pw.pw_uid if a.uid is None else a.uid
    a.homes_root = a.homes_root or ((a.root.rstrip("/") if a.root else "") + HOMES[a.platform])
    c = Check(a)
    dirty = c.run()
    if a.json:
        print(json.dumps({"login": a.login, "since": a.since,
                          "verdict": "dirty" if dirty else "clean",
                          "categories": dict((k, c.found[k]) for k in dirty)},
                         ensure_ascii=False, sort_keys=True))
    else:
        for k in dirty:
            items = c.found[k]
            print("reset-check: %s (%d%s): %s" % (k, len(items), "+" if len(items) >= MAX_ITEMS else "",
                                                 "; ".join(items[:3])), file=sys.stderr)
        print("reset: dirty %s" % ",".join(dirty) if dirty else "reset: clean")
    return 1 if dirty else 0


if __name__ == "__main__":
    sys.exit(main())
