#!/usr/bin/env python3
"""fleet-shared-dirs.py — the machine's shared dirs, each login's files its own (issue #2299).

/Users/Shared/claude-fleet (/var/tmp/claude-fleet off macOS) holds what every
login on the box shares: heavy/ (fleet-heavy.sh's machine-wide slots, #1295) and
sessions/ (each login's live session count, #1301). Both stay 1777 — any login
may add its own file, the sticky bit keeps the others' — but that only holds
when nobody but root OWNS the dirs (a sticky dir's owner may delete anything in
it) and when no file is anyone's to rewrite. Before this the first login to run
created the dirs as its own, the slot files and the event log 0666: any login
could truncate, rewrite or (as the dirs' owner) delete the others' entries.

This is the root half, the node supervisor's `shared-dirs` task (every 60 s):

  * the root dir, heavy/ and sessions/ are real dirs, owned by root, mode 1777
    (a symlink or another owner is replaced / chowned);
  * heavy/slot-1..slot-N are root's 0644 files: a login opens one read-only and
    only flocks it (flock works on a read-only fd) — nobody can delete, replace,
    chmod or write them. A slot another login made (an older version, or before
    this task first ran) is replaced by root's own;
  * the old shared heavy/events.log (0666, compat-1v) becomes root's 0644: an
    older fleet-heavy's append fails quietly, the new one writes events.<login>.log;
  * a squatter is swept: heavy/{hold,wait}.<login>.<pid> and events.<login>.log,
    sessions/<login> — any such file not owned by <login> (or not a regular file)
    is removed, and a hold/wait whose pid is gone with it.

A login's file is its own when the file's owner is that account by name, or by
its home dir's basename (fleet_machine_login keys on $HOME's basename).

Run as anyone else it does the same where it can (never a chown) — the selftest
and an unmanaged machine; `--check` prints what it would change and exits 1 when
something is off, changing nothing.

Usage: fleet-shared-dirs.py [--check] [--root DIR] [--slots N]
Env:   FLEET_SHARED_ROOT (the root dir) · FLEET_HEAVY_PROVISION_SLOTS (16)
"""
import os
import pwd
import re
import stat
import sys
import time

MAC = sys.platform == "darwin"
ROOT = os.environ.get("FLEET_SHARED_ROOT") or ("/Users/Shared/claude-fleet" if MAC else "/var/tmp/claude-fleet")
SLOTS = 16
OWNED = re.compile(r"^(hold|wait)\.([A-Za-z0-9._-]+)\.(\d+)$")
EVENTS = re.compile(r"^events\.([A-Za-z0-9._-]+)\.log$")
TMP_AGE = 3600


def owner_names(uid):
    """The names a uid answers to: its account name and its home's basename."""
    try:
        pw = pwd.getpwuid(uid)
    except KeyError:
        return set()
    return {pw.pw_name, os.path.basename(pw.pw_dir.rstrip("/"))} - {""}


def owned_by(st, login):
    return stat.S_ISREG(st.st_mode) and login in owner_names(st.st_uid)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True                           # EPERM: another login's live pid


class Pass:
    def __init__(self, check):
        self.check = check
        self.root = os.geteuid() == 0
        self.me = os.geteuid()
        self.notes = []

    def note(self, msg):
        self.notes.append(msg)

    def act(self, msg, fn, *a):
        self.note(("would: " if self.check else "") + msg)
        if not self.check:
            try:
                fn(*a)
            except OSError as e:
                self.note("  failed: %s" % e)

    def ensure_dir(self, d):
        try:
            st = os.lstat(d)
        except FileNotFoundError:
            self.act("mkdir %s" % d, self._mkdir, d)
            if self.check:
                return
            st = os.lstat(d)
        if not stat.S_ISDIR(st.st_mode):
            self.act("replace %s (not a dir)" % d, self._replace_dir, d)
            if self.check:
                return
            st = os.lstat(d)
        if self.root and (st.st_uid != 0 or st.st_gid != 0):
            self.act("chown root %s (was uid %d)" % (d, st.st_uid), os.chown, d, 0, 0)
        if (st.st_uid == self.me or self.root) and stat.S_IMODE(st.st_mode) != 0o1777:
            self.act("chmod 1777 %s (was %o)" % (d, stat.S_IMODE(st.st_mode)), os.chmod, d, 0o1777)
        elif not self.root and st.st_uid != self.me:
            self.note("%s is uid %d's — only root can take it back" % (d, st.st_uid))

    def _mkdir(self, d):
        os.mkdir(d)
        os.chmod(d, 0o1777)

    def _replace_dir(self, d):
        os.rename(d, "%s.not-a-dir.%d" % (d, int(time.time())))
        self._mkdir(d)

    def ensure_slot(self, path):
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            st = None
        if st is not None and stat.S_ISREG(st.st_mode) and st.st_uid == self.me:
            if stat.S_IMODE(st.st_mode) != 0o644:
                self.act("chmod 644 %s" % path, os.chmod, path, 0o644)
            return
        if st is not None and stat.S_ISDIR(st.st_mode):
            self.note("%s is a dir — left alone" % path)
            return
        if st is not None and not self.root:
            self.note("%s is uid %d's — only root can replace it" % (path, st.st_uid))
            return
        why = "missing" if st is None else ("uid %d's" % st.st_uid if stat.S_ISREG(st.st_mode) else "not a file")
        self.act("slot %s (%s) → own 0644" % (path, why), self._new_file, path)

    def _new_file(self, path):
        tmp = "%s/.%s.%d" % (os.path.dirname(path), os.path.basename(path), os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        os.close(fd)
        os.chmod(tmp, 0o644)
        os.rename(tmp, path)                  # replaces a foreign file or a symlink in one step

    def legacy_events(self, path):            # compat-1v: 下一批删
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return
        if not stat.S_ISREG(st.st_mode):
            self.act("rm %s (not a file)" % path, os.unlink, path)
            return
        if self.root and st.st_uid != 0:
            self.act("chown root %s (was uid %d)" % (path, st.st_uid), os.chown, path, 0, 0)
        if stat.S_IMODE(st.st_mode) & 0o022 and (self.root or st.st_uid == self.me):
            self.act("chmod 644 %s" % path, os.chmod, path, 0o644)

    def sweep_heavy(self, d):
        for n in sorted(os.listdir(d)):
            p = os.path.join(d, n)
            m = OWNED.match(n)
            e = EVENTS.match(n)
            if not (m or e):
                if n.startswith(".slot-"):
                    self.sweep_tmp(p)
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            login = m.group(2) if m else e.group(1)
            if not owned_by(st, login):
                self.act("rm %s (not %s's — uid %d)" % (p, login, st.st_uid), os.unlink, p)
            elif m and not alive(int(m.group(3))):
                self.act("rm %s (pid gone)" % p, os.unlink, p)

    def sweep_sessions(self, d):
        for n in sorted(os.listdir(d)):
            p = os.path.join(d, n)
            if n.startswith("."):
                self.sweep_tmp(p)
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not owned_by(st, n):
                self.act("rm %s (not %s's — uid %d)" % (p, n, st.st_uid), os.unlink, p)

    def sweep_tmp(self, p):
        try:
            st = os.lstat(p)
        except OSError:
            return
        if time.time() - st.st_mtime > TMP_AGE and (self.root or st.st_uid == self.me):
            self.act("rm %s (an hour-old temp)" % p, os.unlink, p)


def main(argv):
    check, root, slots = False, ROOT, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--check":
            check = True
        elif a in ("--root", "--slots") and i + 1 < len(argv):
            i += 1
            if a == "--root":
                root = argv[i]
            else:
                slots = argv[i]
        elif a in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            sys.stderr.write("fleet-shared-dirs: unknown argument %r\n" % a)
            return 2
        i += 1
    try:
        slots = int(slots or os.environ.get("FLEET_HEAVY_PROVISION_SLOTS") or SLOTS)
    except ValueError:
        sys.stderr.write("fleet-shared-dirs: --slots must be an integer\n")
        return 2
    root = root.rstrip("/") or "/"
    ps = Pass(check)
    heavy, sessions = os.path.join(root, "heavy"), os.path.join(root, "sessions")
    for d in (root, heavy, sessions):
        ps.ensure_dir(d)
    if os.path.isdir(heavy):
        for k in range(1, slots + 1):
            ps.ensure_slot(os.path.join(heavy, "slot-%d" % k))
        ps.legacy_events(os.path.join(heavy, "events.log"))
        ps.sweep_heavy(heavy)
    if os.path.isdir(sessions):
        ps.sweep_sessions(sessions)
    for n in ps.notes:
        print(n)
    if check:
        return 1 if ps.notes else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
