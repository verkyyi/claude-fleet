#!/usr/bin/env python3
"""fleet_stub.py — a new session's window on the screen before the session is
(T992): ⌘P's 「新会话」 ↵ shows a typeable input line within 0.1 s, the road that
makes the session runs behind it, and what the person typed is handed to the
agent the moment it can take it.

    start(tm, g, label, t0)     the panel's ↵: one `new-window` in the 看台 (its
                                session group), running bin/fleet-stub.sh — no
                                interpreter on the way. → (window, dir) or None
    shown(tm, d, t0)            `shown` under the run begun at t0 (the ↵): when
                                the stub's first frame is on the pane
    status(tm, d, text)         one line on the stub (`✗ …` = failed: it stays)
    handoff(tm, d, pane)        the agent in `pane` keeps a paste: the stub is
                                frozen in band (every key typed before is taken),
                                its queued lines pasted + submitted, its unsent
                                line pasted. → True: go there · False: the person
                                closed the stub (the session opens, the 看台 stays)
    close(tm, d)                the stub's window, gone

A stub's state is <dir> = $FLEET_CONF_DIR/stub/<id>/ — win · pid (the road) ·
status · q.<n> · buf · frozen (fleet-stub.sh's own header). The road carries it
as FLEET_STUB_DIR; fleet_view.go calls handoff once, and drops it.
FLEET_STUB=0 (environment or fleet.conf) is the old road: no stub.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

BIN = Path(__file__).absolute().parent
FREEZE = "\x1b[9999~"
REREAD = "\x1b[9998~"


def base():
    conf = os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")
    return Path(conf) / "stub"


def on(word=None):
    """FLEET_STUB: on unless 0/off/no (the environment, else the caller's conf word)."""
    v = (os.environ.get("FLEET_STUB") or word or "").strip().lower()
    return v not in ("0", "off", "no", "false")


def sweep(keep_secs=86400):
    """Old stub dirs out (a day): a stub that never got its handoff leaves one."""
    root = base()
    try:
        for d in root.iterdir():
            if time.time() - d.stat().st_mtime > keep_secs:
                shutil.rmtree(d, ignore_errors=True)
    except OSError:
        pass


def start(tm, g, label, t0=None, cols=None, lang=""):
    """The panel's ↵: the stub's window, current in the 看台 `g` (a window made in
    one session of a group is every member's; only `g` goes to it). → (window, dir)
    or None (the caller takes the old road)."""
    d = base() / uuid.uuid4().hex[:12]
    try:
        d.mkdir(parents=True)
    except OSError:
        return None
    env = ["-e", "FLEET_STUB_COLS=%s" % (cols or 80)] + (["-e", "FLEET_UI_LANG=%s" % lang] if lang else [])
    # argv, not a command string: tmux execs it with no shell between (a login's
    # default-shell -c — zsh reading its rc files — cost the first frame tens of ms)
    cmd = ["/bin/bash", str(BIN / "fleet-stub.sh"), str(d), label]
    # one tmux call: the window (current in g), then its role on it — a panel,
    # never a session (lists, counts, snapshots and restore skip it)
    rc, out = tm("new-window", "-t", "=%s:" % g, "-n", "new", "-P", "-F", "#{window_id}", *env, "--", *cmd,
                 ";", "set-option", "-w", "@fleet_role", "panel")
    win = (out.strip().splitlines() or [""])[0].strip()
    if rc != 0 or not win.startswith("@"):
        shutil.rmtree(d, ignore_errors=True)
        return None
    write(d / "win", win)
    write(d / "lang", lang or "zh")
    if t0:
        write(d / "t0", "%.3f" % t0)
    return win, str(d)


def write(path, text):
    try:
        Path(path).write_text(text + "\n", encoding="utf-8")
        return True
    except OSError:
        return False


def read(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return ""


def words(d, zh, en):
    """The stub's language (the panel's, written at start)."""
    return en if read(Path(d) / "lang").strip().startswith("en") else zh


def win(d):
    return read(Path(d) / "win").strip()


def alive(tm, d):
    """The stub's window is still there and still the stub (not yet frozen)."""
    w = win(d)
    if not w or (Path(d) / "frozen").exists():
        return False
    rc, out = tm("display-message", "-p", "-t", w, "#{window_id}\t#{pane_dead}")
    return rc == 0 and out.split("\t")[0] == w and out.split("\t")[-1] != "1"


def shown(tm, d, t0, secs=2.0):
    """`shown` (the ↵ → the stub's first frame), once, under the run begun at t0."""
    w = win(d)
    deadline = time.monotonic() + secs
    while w and time.monotonic() < deadline:
        rc, out = tm("capture-pane", "-p", "-t", w)
        if rc != 0:
            return None
        if "❯" in out:
            ms = (time.time() - t0) * 1000.0
            try:
                sys.path.insert(0, str(BIN))
                import fleet_timing
                fleet_timing.add("session", [("shown", ms)], ts=t0)
            except Exception:  # noqa: BLE001 — a clock never breaks a start
                pass
            return ms
        time.sleep(0.005)
    return None


def status(tm, d, text):
    """One line on the stub, read at once (the in-band re-read key)."""
    if not d or not write(Path(d) / "status", " ".join(str(text).split())):
        return
    if alive(tm, d):
        tm("send-keys", "-t", win(d), "-l", REREAD)


def note_road(d, pid):
    write(Path(d) / "pid", str(pid))


def _prefill():
    import importlib.util
    spec = importlib.util.spec_from_file_location("scratch_prefill", str(BIN / "scratch-prefill.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def freeze(tm, d, secs=3.0):
    """Stop the stub (in band: what was typed before is taken) → (queued, unsent),
    or None when it is gone (the person closed it)."""
    if not alive(tm, d):
        return None
    tm("send-keys", "-t", win(d), "-l", FREEZE)
    deadline = time.monotonic() + secs
    while not (Path(d) / "frozen").exists():
        if time.monotonic() > deadline:
            return None
        time.sleep(0.01)
    queued, n = [], 0
    while (Path(d) / ("q.%d" % n)).exists():
        queued.append(read(Path(d) / ("q.%d" % n)))
        n += 1
    return queued, read(Path(d) / "buf")


def handoff(tm, d, pane, secs=None):
    """The session in `pane` is up: wait until its agent keeps a paste, freeze the
    stub, give the agent the stub's words. → True (go to the session) · False (the
    stub is gone: the person closed it — leave the 看台 where it is)."""
    if not alive(tm, d):
        return False
    status(tm, d, words(d, "会话已开，等它能打字…", "The session is open — waiting for its input…"))
    # the stub stays up (and takes keys) while the agent mounts; frozen only when
    # the agent is ready, so nothing typed in between is lost
    pf = _prefill()
    ptm = lambda *a: _tm_bytes(tm, *a)
    nothing = lambda reason: None
    secs = secs if secs is not None else ready_secs()
    native = pf.wait_input(ptm, pane, False, nothing, nothing, timeout=secs)
    got = freeze(tm, d)
    if got is None:
        return False
    if native is None:
        # never ready (an agent that died, a shell left behind): nothing is pasted
        # into what is not an agent's input — the words go on the record instead
        keep(d, got)
        return True
    give(ptm, pane, got, native)
    return True


def ready_secs():
    try:
        return float(os.environ.get("FLEET_STUB_READY_SECS") or 90)
    except ValueError:
        return 90.0


def give(ptm, pane, got, native):
    """The stub's words into an agent's input that keeps a paste: each queued
    line pasted and submitted (↵), then the unsent line pasted, unsent."""
    pf = _prefill()
    queued, unsent = got
    rec = lambda outcome: None
    first = True
    for q in queued:
        text = pf.clean(q, newlines=True)
        if not text.strip():
            continue
        pf.paste(ptm, pane, text, rec)
        if first and native:
            pf.repaste_if_swallowed(ptm, pane, text, rec)
        first = False
        time.sleep(0.15)
        ptm("send-keys", "-t", pane, "Enter")
        time.sleep(0.3)
    text = pf.clean(unsent, newlines=True)
    if text.strip():
        pf.paste(ptm, pane, text, rec)


def deliver(socket, pane, got, secs=None):
    """The far half (fleet-remote-view.sh deliver, on the machine the session runs
    on): the same readiness rule and the same paste, against this server. rc 0
    given · 4 the agent never kept a paste."""
    pf = _prefill()

    def ptm(*args):
        return subprocess.run(["tmux", "-L", socket] + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=5, check=True).stdout
    nothing = lambda reason: None
    native = pf.wait_input(ptm, pane, False, nothing, nothing, timeout=secs if secs is not None else ready_secs())
    if native is None:
        return 4
    give(ptm, pane, got, native)
    return 0


def keep(d, got, lang=None):
    """Words the agent never took: a ⚠ notice holds them, so nothing typed is lost."""
    queued, unsent = got
    said = [w for w in queued + [unsent] if w.strip()]
    if not said:
        return
    try:
        sys.path.insert(0, str(BIN))
        import fleet_notice
        en = (lang or read(Path(d) / "lang") if d else lang or "").strip().startswith("en")
        fleet_notice.record("warn", ("The new session did not take what you typed first: " if en
                                     else "新会话没能接过你先打的字：")
                            + " ⏎ ".join(said), source="stub")
    except Exception:  # noqa: BLE001
        pass


def _tm_bytes(tm, *args):
    """scratch-prefill's tmux (bytes out, raises on failure) over fleet_view's tm."""
    rc, out = tm(*args)
    if rc != 0:
        raise subprocess.CalledProcessError(rc, ["tmux"] + list(args))
    return (out + "\n").encode("utf-8")


def close(tm, d):
    w = win(d)
    if w:
        rc, out = tm("display-message", "-p", "-t", w, "#{window_id}\t#{@fleet_role}")
        # only ever the stub's own window (a recycled id is someone else's)
        if rc == 0 and out.split("\t")[0] == w and out.split("\t")[-1] == "panel":
            tm("kill-window", "-t", w)
    shutil.rmtree(d, ignore_errors=True)


def main(argv):
    """`deliver --socket S --pane P` — JSON {queued, unsent} on stdin (T992's far half)."""
    if argv[:1] == ["deliver"] and "--socket" in argv[:-1] and "--pane" in argv[:-1]:
        try:
            data = json.loads(sys.stdin.read() or "{}")
            got = ([str(q) for q in data.get("queued") or []], str(data.get("unsent") or ""))
        except (ValueError, AttributeError):
            return 2
        return deliver(argv[argv.index("--socket") + 1], argv[argv.index("--pane") + 1], got)
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
