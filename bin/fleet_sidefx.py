#!/usr/bin/env python3
"""fleet_sidefx.py — the ONE rule for what a teardown does OUTSIDE its files (issue #4213).

A teardown of a login's fleet (an uninstaller, a reset, a leave) acts in three
places: the login's files, the process table and the service domain (launchd's
gui/<uid> · system/<label>, systemd). HOME isolates the first one only. On
2026-10-14 a worker «sandboxed» an uninstaller with `HOME=$d … --apply`: its files
stayed in $d, but `ps -U $(id -u)` and `launchctl bootout gui/$(id -u)/…` were the
real ones — it SIGTERMed every process whose argv named `/.claude/fleet/`, the
fleet's tmux server among them, and every session on the machine went down.

So every signal and every domain action of a teardown goes through here, keyed on
the TARGET login (named, never `os.getuid()`) and the home the caller read its
targets from:

  live      home is the target login's real home (its passwd entry, realpath'd),
            and the caller IS that login or root — the actions run.
  sandbox   home is anything else (a temp dir, a seam): NOTHING runs. Each action
            is recorded — one line, the command as it would have run, appended to
            $FLEET_SIDEFX_LOG (else printed `RECORD <command>`). This is the
            injected stand-in for ps / kill / launchctl: a test reads the record.
  refused   the target login does not exist, the caller is another non-root login
            (it cannot act for them — and must never fall back to its own uid), or
            (stop) the caller runs UNDER a process the stop would take — a session
            inside the very fleet it is removing (its tmux server is an ancestor).

Processes are the target's (`ps` by its uid) whose argv names a path UNDER the
target's home: <home>/.claude/fleet/ · .claude/fleet.versions/ ·
.claude/skills/doc-preview/ · .local/share/claude-fleet/ — never a bare
`/.claude/fleet/` that every login's processes carry.

  fleet_sidefx.py check --login L --home H          print live|sandbox|refused: <why>
  fleet_sidefx.py procs --login L --home H          the fleet processes it would stop
  fleet_sidefx.py stop  --login L --home H [--apply]
        boot out the login's fleet LaunchAgents (H/Library/LaunchAgents: a
        com.claude-fleet.* / com.ccquota.* name, or a body naming H's fleet
        install) and SIGTERM its fleet processes. Without --apply it only says
        what it would do.
  fleet_sidefx.py run --login L --home H -- <cmd…>  one domain action (launchctl /
        systemctl …), run live, recorded in a sandbox, refused otherwise.

Exit: 0 live (done / would do) · 2 usage · 3 sandbox (recorded, nothing ran) ·
4 refused (nothing ran). A teardown in Python imports it (`decide`, `procs`,
`Actor`); bin/fleet-node-leave.sh asks `check` and records its domain actions.
"""
import os
import pwd
import re
import signal
import subprocess
import sys

LIVE, SANDBOX, REFUSED = "live", "sandbox", "refused"
EXIT = {LIVE: 0, SANDBOX: 3, REFUSED: 4}
FLEET_PATHS = (".claude/fleet/", ".claude/fleet.versions/",
               ".claude/skills/doc-preview/", ".local/share/claude-fleet/")
LABEL_RE = re.compile(r"^(com\.claude-fleet\.|com\.ccquota\.)")


def _real(p):
    return os.path.realpath(os.path.expanduser(p)).rstrip("/") or "/"


def target(login):
    """(uid, real home) of the target login, or None."""
    try:
        pw = pwd.getpwnam(login)
    except (KeyError, TypeError):
        return None
    return pw.pw_uid, _real(pw.pw_dir)


def decide(login, home):
    """(mode, why) — see the module doc."""
    t = target(login)
    if t is None:
        return REFUSED, "no login %r on this machine" % login
    uid, real = t
    if os.geteuid() not in (0, uid):
        return REFUSED, ("the caller (uid %d) is neither %s (uid %d) nor root — it cannot act "
                         "for that login, and never acts on its own uid instead"
                         % (os.geteuid(), login, uid))
    if _real(home) != real:
        return SANDBOX, ("home %s is not %s's home (%s): files may be a sandbox, the process "
                         "table and the service domain never are — nothing runs, every "
                         "action is recorded" % (home, login, real))
    return LIVE, "home is %s's own, caller may act" % login


def _table():
    """{pid: (ppid, uid, argv)} — one ps read."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,uid=,command="],
                         capture_output=True, text=True).stdout
    tab = {}
    for ln in out.splitlines():
        p = ln.split(None, 3)
        if len(p) >= 3 and p[0].isdigit() and p[1].isdigit() and p[2].isdigit():
            tab[int(p[0])] = (int(p[1]), int(p[2]), p[3] if len(p) > 3 else "")
    return tab


def _anchors(home):
    h = _real(home)
    return [h + "/" + s for s in FLEET_PATHS] + [home.rstrip("/") + "/" + s for s in FLEET_PATHS]


def procs(login, home, tab=None):
    """[(pid, argv)] — the target uid's processes whose argv names a fleet path under home."""
    t = target(login)
    if t is None:
        return []
    tab = _table() if tab is None else tab
    anc = _anchors(home)
    me = os.getpid()
    return [(pid, argv) for pid, (_pp, uid, argv) in sorted(tab.items())
            if uid == t[0] and pid != me and any(a in argv for a in anc)]


def ancestors(tab, pid=None):
    pid = os.getpid() if pid is None else pid
    seen = []
    while pid in tab and pid not in seen and pid > 1:
        seen.append(pid)
        pid = tab[pid][0]
    return seen


class Actor:
    """Runs (live) or records (sandbox) a teardown's actions; refuses to be built refused."""

    def __init__(self, login, home, apply=True, log=None):
        self.login, self.home, self.apply = login, home, apply
        self.mode, self.why = decide(login, home)
        if self.mode == REFUSED:
            raise PermissionError(self.why)
        self.log = log if log is not None else os.environ.get("FLEET_SIDEFX_LOG", "")
        self.uid = target(login)[0]

    def _record(self, line):
        if self.log:
            with open(self.log, "a") as f:
                f.write(line + "\n")
        else:
            print("RECORD " + line)

    def run(self, argv):
        """A domain action (launchctl / systemctl / …): rc, or None when recorded / dry."""
        if self.mode == SANDBOX:
            self._record(" ".join(argv))
            return None
        if not self.apply:
            return None
        return subprocess.call(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def kill(self, pid, sig=signal.SIGTERM):
        if self.mode == SANDBOX:
            self._record("kill -%d %d" % (int(sig), pid))
            return
        if self.apply:
            try:
                os.kill(pid, sig)
            except OSError:
                pass


def agents(home):
    """[(label, plist)] — the fleet's LaunchAgents under home."""
    d = os.path.join(home, "Library", "LaunchAgents")
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    anc = _anchors(home)
    out = []
    for n in names:
        if not n.endswith(".plist"):
            continue
        p = os.path.join(d, n)
        try:
            body = open(p, "rb").read().decode("utf-8", "replace")
        except OSError:
            continue
        if LABEL_RE.match(n) or any(a in body for a in anc):
            out.append((n[:-len(".plist")], p))
    return out


def stop(login, home, apply):
    mode, why = decide(login, home)
    if mode == REFUSED:
        print("refused: " + why, file=sys.stderr)
        return EXIT[REFUSED]
    tab = _table()
    ps = procs(login, home, tab)
    mine = set(ancestors(tab))
    hit = [(p, a) for p, a in ps if p in mine]
    if hit and mode == LIVE:
        print("refused: this caller runs under %s — the stop would take the session doing it "
              "(run it from a shell outside that fleet)" % "; ".join(
                  "%d %s" % (p, a[:100]) for p, a in hit), file=sys.stderr)
        return EXIT[REFUSED]
    act = Actor(login, home, apply=apply)
    verb = "DO   " if (apply and mode == LIVE) else ("RECORD" if mode == SANDBOX else "WOULD ")
    if mode == SANDBOX:
        print("sandbox: " + why)
    t = target(login)
    say = (lambda line: None) if (mode == SANDBOX and not act.log) else print  # the record prints it
    for label, _p in agents(home):
        say("%s launchctl bootout gui/%d/%s" % (verb, t[0], label))
        act.run(["launchctl", "bootout", "gui/%d/%s" % (t[0], label)])
    for pid, argv in ps:
        if pid in mine:
            continue
        say("%s kill %d  (%s)" % (verb, pid, argv[:110]))
        act.kill(pid)
    return EXIT[mode]


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest, login, home, apply, tail = argv[0], argv[1:], None, None, False, []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            tail = rest[i + 1:]
            break
        if a in ("--login", "--home") and i + 1 < len(rest):
            if a == "--login":
                login = rest[i + 1]
            else:
                home = rest[i + 1]
            i += 2
            continue
        if a == "--apply":
            apply = True
        else:
            print("fleet_sidefx: unknown argument %s" % a, file=sys.stderr)
            return 2
        i += 1
    if not login or not home:
        print("fleet_sidefx: --login and --home are required", file=sys.stderr)
        return 2
    if cmd == "check":
        mode, why = decide(login, home)
        print("%s: %s" % (mode, why))
        return EXIT[mode]
    if cmd == "procs":
        for pid, a in procs(login, home):
            print("%d %s" % (pid, a))
        return 0
    if cmd == "stop":
        return stop(login, home, apply)
    if cmd == "run":
        if not tail:
            print("fleet_sidefx: run needs -- <cmd…>", file=sys.stderr)
            return 2
        try:
            act = Actor(login, home)
        except PermissionError as e:
            print("refused: %s" % e, file=sys.stderr)
            return EXIT[REFUSED]
        rc = act.run(tail)
        return EXIT[SANDBOX] if act.mode == SANDBOX else (rc or 0)
    print("fleet_sidefx: unknown command %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
