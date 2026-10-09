#!/usr/bin/env python3
"""fleet-status-7501.py — read what the agent says it is doing (issue #2536, EPIC #2535 C1).

Claude Code ≥ 2.1.295 reports its own state as OSC 7501:

    ESC ] 7501 ; state=<s>:app=<a>[:id=<i>][:kind=<k>][:progress=<n>][:title=<b64>][:msg=<b64>] ST

state ∈ working | blocked | done | idle | error | clear; kind (blocked only) ∈
permission | question | auth; msg / title base64 (msg ≤ 2048 bytes, title ≤ 192).
An entry WITH an id is a sub-task's; the window's own state is the id-less one.

It only says so to a terminal that ANSWERED its probe, `ESC ] 7501 ; ? ST`, before
the DA1 reply its probe round ends on (2 s). 2.1.295 has no switch that forces it
on (the one env that touches it, CLAUDE_CODE_DISABLE_TERMINAL_TITLE, turns it off).
Inside tmux nobody answers: tmux ignores the OSC and answers DA1 itself at once, so
a `pipe-pane -IO` responder is always one round trip late (measured: programStatus=no
(probe: no reply to OSC 7501 ; ?)). Hence `relay`: a pty between the pane and the
agent that sees the probe IN the stream and puts the answer on the agent's input
before tmux's DA1 can reach it — and, since every byte passes it anyway, reads the
status there too. Nothing is stripped or added on the way to the pane.

    fleet-status-7501.py relay -- <cmd> [args…]   run <cmd> under the relay (the claude launcher)
    fleet-status-7501.py pipe                     stdin = a pane's output (`pipe-pane -O`)
    fleet-status-7501.py decode <payload>         the JSON one payload maps to (debug)

What it writes, on the window of $TMUX_PANE (convention 1 / 2 of EPIC #2535):
  @agent_status     JSON {state, kind, msg, app, ts[, progress]} — msg its first 200
                    characters, never a log line
  @agent_status_ts  the epoch of the last report
  @claude_state     through `set-claude-state.sh --via 7501`: working→working,
                    blocked→needs (permission→perm, question→ask, + its words),
                    done/idle→done, error→exited; clear keeps what was there.
When the agent exits the relay writes state=exited (rc) on @agent_status only —
the wrapper's own `exited` stamp is the window's.

The relay keeps the wrapper's Ctrl+Z rule (issue #1843): the agent runs in the
pty's session, a process group whose parent is outside it, so its own
kill(0, SIGTSTP) is discarded by the kernel — a guard process in that group
catches it and SIGCONTs the group, exactly as fleet-session-wrap.sh's does.
"""
import base64
import errno
import fcntl
import json
import os
import pty
import queue
import re
import select
import signal
import subprocess
import sys
import termios
import threading
import time
import tty

BIN = os.path.dirname(os.path.abspath(__file__))
PREFIX = b"\x1b]7501;"
PROBE_REPLY = b"\x1b]7501;?\x1b\\"
CARRY = 8192            # an unterminated OSC longer than this is not one
MSG_KEEP = 200          # EPIC #2535 risk row: the words are stored cut, never logged

STATES = {"working", "blocked", "done", "idle", "error", "clear"}
WORD = re.compile(r"[A-Za-z0-9_.+-]{1,64}")


class Scanner:
    """Finds OSC 7501 payloads in a byte stream that may split them anywhere."""

    def __init__(self):
        self.carry = b""

    def feed(self, data):
        buf = self.carry + data
        out = []
        pos = 0
        while True:
            i = buf.find(PREFIX, pos)
            if i < 0:
                # keep a tail that could be the start of a prefix
                keep = 0
                for n in range(min(len(PREFIX) - 1, len(buf)), 0, -1):
                    if PREFIX.startswith(buf[-n:]):
                        keep = n
                        break
                self.carry = buf[len(buf) - keep:] if keep else b""
                return out
            j = i + len(PREFIX)
            bel = buf.find(b"\x07", j)
            st = buf.find(b"\x1b\\", j)
            ends = [e for e in (bel, st) if e >= 0]
            if not ends:
                self.carry = buf[i:] if len(buf) - i <= CARRY else b""
                return out
            e = min(ends)
            out.append(buf[j:e].decode("utf-8", "replace"))
            pos = e + (1 if e == bel else 2)


def _b64(v):
    try:
        raw = base64.b64decode(v + "=" * (-len(v) % 4), validate=True)
    except (ValueError, TypeError):
        return None
    return raw.decode("utf-8", "replace")


def decode(payload, now=None):
    """One payload → its fields, or None (a probe, a malformed one)."""
    if payload.startswith("?"):
        return None
    f = {}
    for part in payload.split(":"):
        k, sep, v = part.partition("=")
        if sep:
            f[k] = v
    state = f.get("state")
    if state not in STATES:
        return None
    rec = {"state": state, "kind": "", "msg": "", "app": "", "ts": int(now or time.time())}
    if WORD.fullmatch(f.get("app", "")):
        rec["app"] = f["app"]
    if state == "blocked" and WORD.fullmatch(f.get("kind", "")):
        rec["kind"] = f["kind"]
    if "msg" in f:
        m = _b64(f["msg"])
        if m is not None:
            rec["msg"] = re.sub(r"[\x00-\x1f\x7f]+", " ", m).strip()[:MSG_KEEP]
    p = f.get("progress", "")
    if p.isdigit():
        rec["progress"] = min(100, int(p))
    if WORD.fullmatch(f.get("id", "")):
        rec["id"] = f["id"]
    return rec


NEEDS_SUB = {"permission": "perm", "question": "ask"}


def claude_verb(rec):
    """The `set-claude-state.sh --via 7501` argv for a record, or None (keep)."""
    s = rec["state"]
    if s == "working":
        return ["working"]
    if s == "blocked":
        return ["needs7501", NEEDS_SUB.get(rec["kind"], ""), rec["msg"]]
    if s in ("done", "idle"):
        return ["done"]
    if s == "error":
        return ["exited"]
    return None


class Writer(threading.Thread):
    """Stamps the window off the relay's hot path: only the newest record waits."""

    def __init__(self, pane):
        super().__init__(daemon=True)
        self.pane = pane
        self.q = queue.Queue()
        self.last_verb = None

    def put(self, rec):
        self.q.put(rec)

    def run(self):
        while True:
            rec = self.q.get()
            if rec is None:
                return
            try:   # coalesce a burst: the newest wins
                while True:
                    nxt = self.q.get_nowait()
                    if nxt is None:
                        self.write(rec)
                        return
                    rec = nxt
            except queue.Empty:
                pass
            self.write(rec)

    def write(self, rec):
        if not self.pane:
            return
        body = {k: rec[k] for k in ("state", "kind", "msg", "app", "ts", "progress", "rc") if k in rec}
        js = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        tmux(["set-option", "-w", "-t", self.pane, "@agent_status", js, ";",
              "set-option", "-w", "-t", self.pane, "@agent_status_ts", str(rec["ts"])])
        verb = claude_verb(rec) if rec["state"] != "exited" else None
        if verb and verb != self.last_verb:
            self.last_verb = verb
            env = dict(os.environ, TMUX_PANE=self.pane)
            env.pop("CLAUDE_CODE_ENTRYPOINT", None)
            try:
                subprocess.run(["sh", os.path.join(BIN, "set-claude-state.sh"), "--via", "7501"] + verb,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, env=env, timeout=20)
            except (OSError, subprocess.SubprocessError):
                pass

    def close(self):
        self.q.put(None)
        self.join(timeout=5)


def tmux(args):
    try:
        subprocess.run(["tmux"] + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


class Reader:
    """Scanner + writer: what both modes do with the agent's output."""

    def __init__(self, pane):
        self.scan = Scanner()
        self.writer = Writer(pane)
        self.writer.start()
        self.last = None

    def feed(self, data):
        """→ how many probes the chunk carried (the relay answers each)."""
        probes = 0
        for payload in self.scan.feed(data):
            if payload.startswith("?"):
                probes += 1
                continue
            rec = decode(payload)
            if rec is None or "id" in rec or rec["state"] == "clear":
                continue    # a sub-task's entry, or clear: the window keeps its state
            key = (rec["state"], rec["kind"], rec["msg"], rec.get("progress"))
            if key == self.last:
                continue
            self.last = key
            self.writer.put(rec)
        return probes

    def exited(self, rc):
        if self.writer.pane:
            self.writer.put({"state": "exited", "kind": "", "msg": "", "app": "",
                             "ts": int(time.time()), "rc": rc})
        self.writer.close()


def pane():
    return os.environ.get("TMUX_PANE", "") if os.environ.get("TMUX") else ""


# ── relay ───────────────────────────────────────────────────────────────────

def _guard(cmd, attrs, size):
    """The pty's session leader: run <cmd>, keep a self-SIGTSTP from freezing it."""
    if attrs is not None:
        try:
            termios.tcsetattr(0, termios.TCSANOW, attrs)
        except termios.error:
            pass
    if size is not None:
        try:
            fcntl.ioctl(0, termios.TIOCSWINSZ, size)
        except OSError:
            pass
    child = os.fork()
    if child == 0:
        for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP, signal.SIGHUP,
                  signal.SIGTTIN, signal.SIGTTOU, signal.SIGWINCH, signal.SIGTERM):
            signal.signal(s, signal.SIG_DFL)
        try:
            os.execvp(cmd[0], cmd)
        except OSError as e:
            os.write(2, ("fleet-status-7501: %s: %s\n" % (cmd[0], e.strerror)).encode())
            os._exit(127)
    for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGTTIN, signal.SIGTTOU):
        signal.signal(s, signal.SIG_IGN)
    signal.signal(signal.SIGTSTP, lambda *_: os.killpg(0, signal.SIGCONT))
    for s in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(s, lambda n, _f: _kill(child, n))
    while True:
        try:
            _, st = os.waitpid(child, 0)
        except ChildProcessError:
            os._exit(1)
        except InterruptedError:
            continue
        os._exit(_rc(st))


def _kill(pid, sig):
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def _rc(st):
    if os.WIFEXITED(st):
        return os.WEXITSTATUS(st)
    if os.WIFSIGNALED(st):
        return 128 + os.WTERMSIG(st)
    return 1


def relay(cmd):
    if not cmd:
        sys.stderr.write("usage: fleet-status-7501.py relay -- <cmd> [args…]\n")
        return 2
    if not os.isatty(0) or not os.isatty(1):
        os.execvp(cmd[0], cmd)        # nothing to stand between: run it as is
    attrs = size = None
    try:
        attrs = termios.tcgetattr(0)
    except termios.error:
        pass
    try:
        size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
    except OSError:
        pass
    pid, master = pty.fork()
    if pid == 0:
        _guard(cmd, attrs, size)      # never returns
    rd = Reader(pane())

    def winch(*_):
        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
        except OSError:
            pass
    signal.signal(signal.SIGWINCH, winch)
    for s in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(s, lambda n, _f: _killpg(pid, n))
    for s in (signal.SIGINT, signal.SIGQUIT):
        signal.signal(s, signal.SIG_IGN)
    if attrs is not None:
        tty.setraw(0, termios.TCSANOW)
    fl = fcntl.fcntl(master, fcntl.F_GETFL)
    fcntl.fcntl(master, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    to_child = bytearray()
    to_out = bytearray()
    stdin_open = True
    child_open = True
    st = None
    try:
        while child_open or to_out:
            # The agent gone is the end even when a job it left behind still holds
            # the pty open (no EIO then): drain what it wrote, and stop.
            if st is None:
                try:
                    done, s_ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    done, s_ = pid, 0
                if done == pid:
                    st = s_
                    while True:
                        try:
                            data = os.read(master, 65536)
                        except OSError:
                            break
                        if not data:
                            break
                        rd.feed(data)
                        to_out += data
                    child_open = False
                    continue
            r = []
            if child_open and len(to_out) < (1 << 20):
                r.append(master)
            if stdin_open and child_open and len(to_child) < (1 << 20):
                r.append(0)
            w = []
            if to_child and child_open:
                w.append(master)
            if to_out:
                w.append(1)
            try:
                rr, ww, _ = select.select(r, w, [], 1.0)
            except InterruptedError:
                continue
            if master in rr:
                try:
                    data = os.read(master, 65536)
                except BlockingIOError:
                    data = None
                except OSError as e:
                    if e.errno != errno.EIO:
                        raise
                    data = b""
                if data == b"":
                    child_open = False
                elif data:
                    probes = rd.feed(data)
                    if probes:   # the answer goes first, ahead of anything typed
                        to_child[:0] = PROBE_REPLY * probes
                        _flush(master, to_child)
                    to_out += data
            if 0 in rr:
                try:
                    data = os.read(0, 65536)
                except OSError:
                    data = b""
                if data:
                    to_child += data
                else:
                    stdin_open = False
                    _killpg(pid, signal.SIGHUP)
            if master in ww:
                _flush(master, to_child)
            if 1 in ww:
                n = _write(1, bytes(to_out[:4096]))
                if n < 0:
                    to_out.clear()
                    stdin_open = False
                else:
                    del to_out[:n]
    finally:
        if attrs is not None:
            try:
                termios.tcsetattr(0, termios.TCSADRAIN, attrs)
            except termios.error:
                pass
    try:
        os.close(master)
    except OSError:
        pass
    while st is None:
        try:
            _, st = os.waitpid(pid, 0)
        except InterruptedError:
            continue
        except ChildProcessError:
            st = 0
    rc = _rc(st)
    rd.exited(rc)
    return rc


def _killpg(pid, sig):
    try:
        os.killpg(pid, sig)
    except OSError:
        pass


def _flush(fd, buf):
    while buf:
        try:
            n = os.write(fd, bytes(buf[:65536]))
        except BlockingIOError:
            return
        except OSError:
            buf.clear()
            return
        del buf[:n]


def _write(fd, data):
    try:
        return os.write(fd, data)
    except InterruptedError:
        return 0
    except OSError:
        return -1


# ── pipe ────────────────────────────────────────────────────────────────────

def pipe():
    rd = Reader(pane())
    while True:
        try:
            data = os.read(0, 65536)
        except InterruptedError:
            continue
        except OSError:
            break
        if not data:
            break
        rd.feed(data)
    rd.writer.close()
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    if argv[0] == "relay":
        rest = argv[1:]
        if rest[:1] == ["--"]:
            rest = rest[1:]
        return relay(rest)
    if argv[0] == "pipe":
        return pipe()
    if argv[0] == "decode" and len(argv) == 2:
        rec = decode(argv[1])
        if rec is None:
            return 1
        rec["claude"] = claude_verb(rec)
        print(json.dumps(rec, ensure_ascii=False, sort_keys=True))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
