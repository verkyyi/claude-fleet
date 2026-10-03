#!/bin/bash
# fleet-heavy.sh — a MACHINE-WIDE counting semaphore for heavy jobs (issue #1295).
#
# WHY: every session runs its own full gate on `git push` (and that gate fans out
# `xargs -P 5` inside); a dozen sessions pushing at once — across the 5 logins
# sharing this box's memory — drag the whole machine down together (EPIC #1291,
# case ③). This caps how many heavy jobs (tests, pre-PR checks, builds, pushes)
# run AT ONCE across every login; the rest queue.
#
# HOW: a slot is `fcntl.flock` on <dir>/slot-K (K = 1..slots). A python3 parent
# takes the first free slot, runs the command as its CHILD and waits — the lock
# lives on the parent's fd, which is NOT inherited, so a daemon the command leaves
# behind cannot hold the slot, and a SIGKILLed holder releases it the instant the
# kernel closes its fds. Nothing to clean up, nothing to leak. macOS has no
# flock(1), hence python3.
#
# The queue NEVER blocks forever: after --wait seconds (FLEET_HEAVY_WAIT, default
# 1800) the command runs anyway, with a WARN on stderr and in the event log.
#
# Shared across logins (EPIC #1291 convention 6): the dir is machine-level —
# /Users/Shared/claude-fleet/heavy on macOS, /var/tmp/claude-fleet/heavy
# elsewhere — mode 1777, slot files 0666, never in anyone's $HOME. A slot file
# holds only `pid login label start`.
#
# The fleet's Bash hook (hooks/bash-guard.py) prefixes this wrapper onto every
# statement matching FLEET_HEAVY_RE, so business repos need no change.
#
# Usage:
#   fleet-heavy.sh [--slots N] [--wait S] [--label L] -- <cmd…>   (exit = cmd's)
#   fleet-heavy.sh --status [--slots N]                            held / waiting /
#                                                                  24h wait median+max
#
# Keys (global): FLEET_HEAVY (0 = pass straight through) · FLEET_HEAVY_SLOTS (3) ·
# FLEET_HEAVY_WAIT (1800) · FLEET_HEAVY_RE (the hook's matcher) · FLEET_HEAVY_LIGHT_RE
# (the hook's never-queue list, matched first — issue #1313). FLEET_HEAVY_DIR
# overrides the slot dir (a selftest seam). Re-entrant: a command already holding
# a slot (FLEET_HEAVY_HELD=1 in its env) runs nested heavies straight through, so
# a wrapped gate that pushes cannot deadlock on itself.
set -u

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac

PY="$(command -v python3 2>/dev/null)"
if [ -z "$PY" ]; then
  # No python3 → no lock primitive. Never block work over it: run ungated.
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    [ "$1" = "--status" ] && { echo "fleet-heavy: python3 not installed — no queue" >&2; exit 1; }
    shift
  done
  [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || { echo "usage: fleet-heavy.sh [--slots N] [--wait S] [--label L] -- <cmd…>" >&2; exit 2; }
  exec "$@"
fi

export FLEET_HEAVY_SLOTS="${FLEET_HEAVY_SLOTS:-$FLEET_HEAVY_SLOTS_DEFAULT}"
export FLEET_HEAVY_WAIT="${FLEET_HEAVY_WAIT:-$FLEET_HEAVY_WAIT_DEFAULT}"
export FLEET_HEAVY_DIR="${FLEET_HEAVY_DIR:-$(fleet_heavy_dir)}"
export FLEET_HEAVY="${FLEET_HEAVY:-1}"

# Read the program with `read -d ''`, NOT `$(cat <<'EOF')`: bash 3.2's
# command-substitution scanner trips over quotes/parens inside a heredoc body.
# And never `python3 - <<EOF`: stdin belongs to the wrapped command.
read -r -d '' _HEAVY_PY <<'PYEOF'
import errno, fcntl, os, pwd, signal, subprocess, sys, time

DIR = os.environ["FLEET_HEAVY_DIR"]
POLL = 0.25


def die(msg, code=2):
    sys.stderr.write("fleet-heavy: %s\n" % msg)
    sys.exit(code)


def login():
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        return os.environ.get("USER", "?")


def posint(v, what):
    try:
        n = int(v)
    except Exception:
        die("%s must be an integer, got %r" % (what, v))
    if n < 0:
        die("%s must be >= 0, got %r" % (what, v))
    return n


def ensure_dir():
    """Create the machine-level dir chain world-writable + sticky (1777)."""
    parent = os.path.dirname(DIR.rstrip("/"))
    for d in (parent, DIR):
        try:
            os.mkdir(d)
        except FileExistsError:
            pass
        except OSError:
            if not os.path.isdir(d):
                return False
        try:
            if os.stat(d).st_uid == os.getuid():
                os.chmod(d, 0o1777)
        except OSError:
            pass
    return os.path.isdir(DIR)


def open_shared(path, extra=0):
    """O_RDWR|O_CREAT at 0666 regardless of umask; RDONLY if another login made it
    without group/other write (flock works on a read-only fd; metadata is skipped)."""
    old = os.umask(0)
    try:
        try:
            return os.open(path, os.O_RDWR | os.O_CREAT | extra, 0o666), True
        except PermissionError:
            return os.open(path, os.O_RDONLY), False
    finally:
        os.umask(old)


def log_event(kind, label, extra=""):
    try:
        fd, _ = open_shared(os.path.join(DIR, "events.log"), os.O_APPEND)
        try:
            line = "%s\t%s\t%s\t%d\t%s\t%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S"), kind, login(), os.getpid(), label, extra)
            os.write(fd, line.encode())       # O_APPEND: concurrent lines never clobber
            if os.fstat(fd).st_size > 2 * 1024 * 1024:
                os.ftruncate(fd, 0)          # crude cap; the log is evidence, not history
        finally:
            os.close(fd)
    except OSError:
        pass


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError as e:
        return e.errno == errno.EPERM        # another login's live pid


def read_meta(path):
    try:
        with open(path) as f:
            parts = f.read().strip().split("\t")
        if len(parts) >= 4:
            return int(parts[0]), parts[1], parts[2], int(parts[3])
    except Exception:
        pass
    return None


def probe_held(slots):
    """[(slot, meta-or-None)] for every slot someone holds right now."""
    held = []
    for k in range(1, slots + 1):
        path = os.path.join(DIR, "slot-%d" % k)
        if not os.path.exists(path):
            continue
        try:
            fd, _ = open_shared(path)
        except OSError:
            continue
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                held.append((k, read_meta(path)))
        finally:
            os.close(fd)
    return held


def waiters():
    out = []
    try:
        names = os.listdir(DIR)
    except OSError:
        return out
    for n in sorted(names):
        if not n.startswith("wait."):
            continue
        p = os.path.join(DIR, n)
        m = read_meta(p)
        if m and alive(m[0]):
            out.append(m)
        else:
            try:
                os.unlink(p)                 # sticky dir: only our own goes
            except OSError:
                pass
    return out


def age(start):
    s = max(0, int(time.time()) - start)
    return "%dm%02ds" % (s // 60, s % 60) if s >= 60 else "%ds" % s


def wait_stats(window=86400):
    """`waits 24h:` line off events.log's `waited=Ns` (acquire + timeout rows,
    issue #1313) — the number that says whether light runs really stopped queuing."""
    cut = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - window))
    w = []
    try:
        with open(os.path.join(DIR, "events.log")) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) < 6 or p[0] < cut or p[1] not in ("acquire", "timeout"):
                    continue
                for tok in p[5].split():
                    if tok.startswith("waited=") and tok.endswith("s") and tok[7:-1].isdigit():
                        w.append(int(tok[7:-1]))
    except OSError:
        pass
    if not w:
        return "  waits 24h: none recorded"
    w.sort()
    n = len(w)
    med = w[n // 2] if n % 2 else (w[n // 2 - 1] + w[n // 2]) // 2
    return "  waits 24h: %d runs · %d queued · median %ds · max %ds" % (
        n, sum(1 for x in w if x > 0), med, w[-1])


def status(slots):
    if not os.path.isdir(DIR):
        print("heavy: 0/%d held · 0 waiting   (%s — not created yet)" % (slots, DIR))
        return 0
    held = probe_held(slots)
    w = waiters()
    print("heavy: %d/%d held · %d waiting   (%s)" % (len(held), slots, len(w), DIR))
    for k, m in held:
        if m:
            print("  held     slot-%-2d pid %-7d %-12s %-20s %s" % (k, m[0], m[1], m[2], age(m[3])))
        else:
            print("  held     slot-%-2d (no metadata)" % k)
    for m in w:
        print("  waiting          pid %-7d %-12s %-20s %s" % (m[0], m[1], m[2], age(m[3])))
    print(wait_stats())
    # A slot past --slots (another login configured more) still counts on the box.
    extra = [k for k, _ in probe_held(64) if k > slots]
    if extra:
        print("  note: slots %s held beyond FLEET_HEAVY_SLOTS=%d (another login's cap)"
              % (",".join("slot-%d" % k for k in extra), slots))
    return 0


def acquire(slots, wait, label):
    """→ (fd, slot) or (None, None) after `wait` seconds."""
    me = "%d\t%s\t%s\t%d\n" % (os.getpid(), login(), label, int(time.time()))
    wpath = os.path.join(DIR, "wait.%s.%d" % (login(), os.getpid()))
    t0 = time.time()
    announced = False
    try:
        while True:
            for k in range(1, slots + 1):
                path = os.path.join(DIR, "slot-%d" % k)
                try:
                    fd, rw = open_shared(path)
                except OSError:
                    continue
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError:
                    os.close(fd)
                    continue
                if rw:
                    os.ftruncate(fd, 0)
                    os.lseek(fd, 0, os.SEEK_SET)
                    os.write(fd, me.encode())
                waited = int(time.time() - t0)
                log_event("acquire", label, "slot=%d held=%d waited=%ds"
                          % (k, len(probe_held(slots)), waited))
                if announced:
                    sys.stderr.write("fleet-heavy: got slot-%d after %ds — running %s\n"
                                     % (k, waited, label))
                return fd, k
            if not announced:
                announced = True
                try:
                    fd, _ = open_shared(wpath)
                    os.write(fd, me.encode())
                    os.close(fd)
                except OSError:
                    pass
                who = ", ".join("%s(%s)" % (m[2], m[1]) for _, m in probe_held(slots) if m)
                sys.stderr.write("fleet-heavy: all %d heavy slots busy [%s] — queued %s "
                                 "(runs anyway after %ds; `fleet-heavy.sh --status`)\n"
                                 % (slots, who, label, wait))
                log_event("queue", label)
            if time.time() - t0 >= wait:
                return None, None
            time.sleep(POLL)
    finally:
        try:
            os.unlink(wpath)
        except OSError:
            pass


def run(argv, slots, wait, label):
    fd = None
    if os.environ.get("FLEET_HEAVY") == "0" or os.environ.get("FLEET_HEAVY_HELD") == "1" or slots == 0:
        pass                                  # pass-through: off, nested, or unlimited
    elif not ensure_dir():
        sys.stderr.write("fleet-heavy: WARN %s unusable — running %s ungated\n" % (DIR, label))
    else:
        fd, _slot = acquire(slots, wait, label)
        if fd is None:
            held = probe_held(slots)
            who = ", ".join("%s(%s, %s)" % (m[2], m[1], age(m[3])) for _, m in held if m)
            sys.stderr.write("fleet-heavy: WARN waited %ds for a heavy slot [%s] — "
                             "running %s anyway\n" % (wait, who, label))
            log_event("timeout", label, "waited=%ds" % wait)

    env = dict(os.environ)
    env["FLEET_HEAVY_HELD"] = "1"
    try:
        child = subprocess.Popen(argv, env=env)    # lock fd is non-inheritable
    except OSError as e:
        sys.stderr.write("fleet-heavy: %s: %s\n" % (argv[0], e.strerror))
        sys.exit(127 if e.errno == errno.ENOENT else 126)

    def forward(sig, _frame):
        try:
            child.send_signal(sig)
        except OSError:
            pass
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(s, forward)

    while True:
        try:
            rc = child.wait()
            break
        except InterruptedError:
            continue
    if fd is not None:
        log_event("release", label, "rc=%d" % rc)
        os.close(fd)
    if rc < 0:                                # died of a signal: die the same way
        signal.signal(-rc, signal.SIG_DFL)
        os.kill(os.getpid(), -rc)
        sys.exit(128 - rc)
    sys.exit(rc)


def main(args):
    slots = posint(os.environ.get("FLEET_HEAVY_SLOTS", "3") or "3", "FLEET_HEAVY_SLOTS")
    wait = posint(os.environ.get("FLEET_HEAVY_WAIT", "1800") or "1800", "FLEET_HEAVY_WAIT")
    label, do_status = "", False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            i += 1
            break
        if a == "--status":
            do_status = True
        elif a in ("--slots", "--wait", "--label"):
            if i + 1 >= len(args):
                die("%s needs a value" % a)
            v = args[i + 1]
            i += 1
            if a == "--slots":
                slots = posint(v, "--slots")
            elif a == "--wait":
                wait = posint(v, "--wait")
            else:
                label = v
        else:
            die("unknown option %r (usage: fleet-heavy.sh [--slots N] [--wait S] "
                "[--label L] -- <cmd…> | --status)" % a)
        i += 1
    if do_status:
        sys.exit(status(slots))
    argv = args[i:]
    if not argv:
        die("no command (usage: fleet-heavy.sh [--slots N] [--wait S] [--label L] -- <cmd…>)")
    label = "".join(c if (c.isalnum() or c in "._-") else "-" for c in
                    (label or os.path.basename(argv[0])))[:40] or "cmd"
    run(argv, slots, wait, label)


main(sys.argv[1:])
PYEOF

exec "$PY" -c "$_HEAVY_PY" "$@"
