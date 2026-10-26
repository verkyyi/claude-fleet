#!/usr/bin/env python3
"""fleet-panel-server.py — ⌘P's resident panel (task T890): one per 看台, its code
loaded and the list in hand, so a ⌘P draws its first frame without starting
Python, loading fleet_view or reading anything.

    fleet-panel-server.py ensure --view <view>   start it (detached) unless it answers
    fleet-panel-server.py serve  --view <view>   the server itself (ensure runs this)
    fleet-panel-server.py stop   --view <view>   ask it to go
    fleet-panel-server.py status --view <view>   `up <pid> age=<s>` | `down` (exit 1)
    fleet-panel-server.py sock   --view <view>   its socket's path
    fleet-panel-server.py attach                 the connector, in Python: what
                                                 `ccquota panel attach` does (the
                                                 selftest's client, a box without
                                                 the Go binary)

The road (one ⌘P): the 看台's key opens its popup straight away (no shell,
fleet-popup-lib.sh fleet_popup_bind), the keypress's context riding in the 看台
session's environment as FLEET_PANEL_CTX (`set-environment -F`: session · client ·
window · @peer_cur · @view_shell · @view_lang_set · @view_lang · client width);
in the popup `ccquota panel attach` connects to this server's socket and sends
one JSON line {v, ctx, env, t0}; the server answers `{"ready": 1}` and only then
does the connector send its stdin / stdout / stderr (SCM_RIGHTS, with one byte)
— a server that never answers never holds them. The server forks (1-2 ms, it runs no thread) and the CHILD takes
those descriptors and the connector's environment and runs fleet_view.popup with
the list the server holds (`pre`): no tmux call, no file, no subprocess before
the first frame. The child answers `{"pid": N}` at once (the connector forwards
SIGWINCH / SIGHUP to it) and `{"rc": N}` when the panel ends; its copy of the
connection closing is the connector's EOF. No server (50 ms), a refusal, or no
answer within 1 s ⇒ the connector execs today's Python panel itself, which starts
this server for the next ⌘P (`ensure`): ⌘P always opens.

The list is the SAME read the panel makes (fleet_view.entries — the producer and
global/remote_<fleet>, the hub's fleet_sessions, so it agrees with the web board,
#5185 / #5191), run in a forked worker every FLEET_PANEL_SERVER_REFRESH seconds
(2) while the 看台's client was active in the last 10 minutes, every 30 s
otherwise, and once more right after each popup closes; the worker hands back the
rows and its caches (pickle over a pipe). The child draws what the server holds
and says how old it is when it is older than FLEET_VIEW_STALE_MARK_SECS
(「2 分钟前 · 刷新中…」); the popup's own Refresh then reads it again. A worker
still reading after FLEET_PANEL_SERVER_WORKER_SECS (15 s) is SIGKILLed (its process
group: the producer and the tmux calls under it) and logged, and the next one starts
at once — a hung read used to hold `worker` for good and freeze the list.

The worker reads the cache as it is (hub=False: no hub wait), so the server keeps
the cache's refresher alive itself: on its own loop, at most every
FLEET_PANEL_SERVER_HUB_EVERY (5 s), global/hub_ok older than FLEET_VIEW_HUB_FRESH
(10 s) with no fleet-hub-sessions.sh loop holding its lock ⇒ one `--ensure`, started
detached (fleet_view.hub_ensure) and never waited for. Without it each ⌘P's first
frame came from a cache no loop was keeping.

A release switch (the install's link moving) makes it start again on the new
code (exec, same pid). It listens on one unix socket, FLEET_PANEL_SOCK_DIR (/tmp/fleet-panel-<uid>,
0700, ours or refused) / <sha1(view)[:16]>.sock, 0600, and refuses a peer whose
uid is not ours; no port. It exits when its 看台 session is gone, after
FLEET_PANEL_SERVER_IDLE (1800 s) with no ⌘P, or on `stop`; nothing restarts it
but the next ⌘P (or the next attach). FLEET_PANEL_SERVER=0 turns the road off
(`ensure` starts nothing, the key keeps the old popup door). Log: the conf dir's
logs/panel-server.log.
"""
import errno
import hashlib
import json
import os
import pickle
import select
import signal
import socket
import struct
import sys
import time
import traceback

from pathlib import Path

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))

PROTO = 1
# what differs from one ⌘P to the next and changes nothing the list reads
VOLATILE = ("FLEET_PANEL_CTX", "FLEET_PANEL_T0")
MAX_HEAD = 1 << 20


def fenv(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


def enabled():
    return os.environ.get("FLEET_PANEL_SERVER", "1") != "0"


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"))


def log(msg):
    try:
        p = conf_dir() / "logs" / "panel-server.log"
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.stat().st_size > 512 * 1024:
            os.replace(str(p), str(p) + ".1")
        with open(str(p), "a") as f:
            f.write("%s %d %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), os.getpid(), msg))
    except OSError:
        pass


def sock_dir():
    return Path(os.environ.get("FLEET_PANEL_SOCK_DIR") or "/tmp/fleet-panel-%d" % os.getuid())


def sock_name(vid):
    """The socket's file name — the connector computes the same (ccquota panel)."""
    return hashlib.sha1(vid.encode("utf-8")).hexdigest()[:16] + ".sock"


def sock_path(vid):
    return sock_dir() / sock_name(vid)


def own_dir(make=True):
    """The socket directory, 0700 and ours — anything else is refused (None)."""
    d = sock_dir()
    if make:
        try:
            d.mkdir(mode=0o700, exist_ok=True)
        except OSError:
            return None
    try:
        st = os.lstat(str(d))
    except OSError:
        return None
    import stat as _st
    if not _st.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        log("refused: %s is not a 0700 directory of ours" % d)
        return None
    return d


def peer_uid(conn):
    """The connecting process's uid (SO_PEERCRED on Linux, LOCAL_PEERCRED on a
    Mac), None when the system will not say."""
    try:
        if sys.platform.startswith("linux"):
            raw = conn.getsockopt(socket.SOL_SOCKET, getattr(socket, "SO_PEERCRED", 17), struct.calcsize("3i"))
            return struct.unpack("3i", raw)[1]
        # struct xucred { u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16]; }
        raw = conn.getsockopt(0, 1, 4 + 4 + 2 + 2 + 16 * 4)   # SOL_LOCAL, LOCAL_PEERCRED
        return struct.unpack_from("I", raw, 4)[0]
    except (OSError, struct.error):
        return None


def answers(vid, timeout=0.3):
    """The server of <vid> answers its socket (a connect, nothing sent)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(str(sock_path(vid)))
        return True
    except OSError:
        return False
    finally:
        s.close()


def connector():
    """Is there a connector to reach a server — bin/ccquota beside this file
    (FLEET_PANEL_CONNECTOR names another)? None: no key would ever reach one."""
    c = os.environ.get("FLEET_PANEL_CONNECTOR") or str(BIN / "ccquota")
    return os.access(c, os.X_OK)


def ensure(vid, sock=""):
    """Start the server of <vid> detached unless it answers (0 either way; 1 off).
    <sock>: the fleet's tmux socket label, for a caller outside the server."""
    if not enabled() or not vid or not connector():
        return 1
    if answers(vid):
        return 0
    if own_dir() is None:
        return 1
    try:
        import subprocess
        subprocess.Popen([sys.executable, str(Path(__file__).absolute()), "serve", "--view", vid]
                         + (["--socket", sock] if sock else []),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    except OSError as e:
        log("ensure %s: %s" % (vid, e))
        return 1
    return 0


# --- the keypress's context ------------------------------------------------------

def parse_ctx(ctx):
    """FLEET_PANEL_CTX (the key's `set-environment -F`) → a dict; {} when absent."""
    f = (ctx or "").split("|")
    if len(f) < 8:
        return {}
    session, client, wid, peer, vsh, lang_set, lang, width = f[:8]
    cur = peer[4:] if peer.startswith("wid:") else (peer or wid)
    return {"session": session, "client": client, "cur": cur, "vsh": vsh, "lang_set": lang_set == "1",
            "lang": lang, "width": width}


# --- the server ------------------------------------------------------------------

class Server:
    def __init__(self, vid, qo, fv):
        self.vid, self.qo, self.fv = vid, qo, fv
        self.fleet = fv.view_fleet(vid)
        self.session = "%s@view-%s" % (self.fleet, vid) if self.fleet else ""
        self.items, self.ts, self.wkey = None, 0.0, ""   # wkey: the list's language (ui_lang)
        self.active, self.alive = True, True
        self.worker = None          # (pid, read fd, bytes so far, started)
        self.hub_next = 0.0         # the next hub_keep look (FLEET_PANEL_SERVER_HUB_EVERY)
        self.due = 0.0
        self.last_conn = time.time()
        self.children = set()
        self.env = None             # the last connector's environment: the panel's own
        self.stop = False
        # the install this code came from (a release switch moves ~/.claude/fleet's
        # link): another one ⇒ this server starts again on the new code
        self.real, self.moved = os.path.realpath(str(BIN)), False

    # the list ----------------------------------------------------------------
    def every(self):
        return fenv("FLEET_PANEL_SERVER_REFRESH", 2) if self.active else 30.0

    def start_worker(self):
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            code = 0
            try:
                # a group of its own: the watchdog's SIGKILL takes the producer and
                # the tmux calls under it too, never the server
                try:
                    os.setpgid(0, 0)
                except OSError:
                    pass
                out = self.read_list()
                data = pickle.dumps(out, protocol=pickle.HIGHEST_PROTOCOL)
                view = memoryview(data)
                while view:
                    n = os.write(w, view)
                    view = view[n:]
            except BaseException:   # noqa: BLE001 — a worker never raises into the server
                log("worker: " + traceback.format_exc().replace("\n", " | "))
                code = 1
            finally:
                os._exit(code)
        os.close(w)
        self.worker = (pid, r, bytearray(), time.time())

    def worker_watch(self, now):
        """A worker reading past FLEET_PANEL_SERVER_WORKER_SECS is hung (a wedged tmux,
        a producer stuck on a loaded box): SIGKILL it and its group, say so, and
        start the next read now — the list must keep moving."""
        if not self.worker:
            return
        pid, r, _buf, t0 = self.worker
        limit = fenv("FLEET_PANEL_SERVER_WORKER_SECS", 15)
        if limit <= 0 or now - t0 <= limit:
            return
        for kill in (lambda: os.killpg(pid, signal.SIGKILL), lambda: os.kill(pid, signal.SIGKILL)):
            try:
                kill()
                break
            except OSError:
                continue
        try:
            os.close(r)
        except OSError:
            pass
        self.worker = None
        self.due = now
        log("worker %d read for %.0fs (FLEET_PANEL_SERVER_WORKER_SECS=%g): killed, reading again" % (pid, now - t0, limit))

    def hub_keep(self, now):
        """The cache's refresher kept alive from here (fleet_view.hub_ensure): a
        detached --ensure when the cache is stale and no loop runs, at most every
        FLEET_PANEL_SERVER_HUB_EVERY seconds. Never waits, never raises."""
        if not self.fleet or now < self.hub_next:
            return
        self.hub_next = now + fenv("FLEET_PANEL_SERVER_HUB_EVERY", 5)
        ensure = getattr(self.fv, "hub_ensure", None)
        if ensure is None:
            return
        try:
            if ensure(self.fleet, "panel") is not None:
                log("hub list stale and no loop: --ensure started")
        except Exception:   # noqa: BLE001 — a hub hiccup never takes the server down
            log("hub_keep: " + traceback.format_exc().replace("\n", " | "))

    def read_list(self):
        """In the worker: the 看台's language and activity, then the list."""
        fv = self.fv
        if self.env:
            for k in list(os.environ):
                if k not in self.env:
                    os.environ.pop(k, None)
            os.environ.update(self.env)
        alive, active, lang_said, lang = True, True, "", None
        if self.session:
            # has-session first: display-message answers rc 0 for a session gone
            rc, out = fv.tm("has-session", "-t", "=" + self.session, ";", "display-message", "-p", "-t",
                            "=%s:" % self.session, "#{@view_lang_set}|#{@view_lang}|#{client_activity}|#{session_activity}")
            alive = rc == 0
            if alive:
                said, lng, cact, sact = (out.split("|") + ["", "", "", ""])[:4]
                act = max(int(x) for x in (cact, sact, "0") if x.isdigit())
                active = time.time() - act < 600 if act else True
                lang_said, lang = said, lng
        if not alive:
            return {"alive": False}
        if "FLEET_VIEW_LANG" not in os.environ and lang_said == "1":
            os.environ["FLEET_VIEW_LANG"] = lang
        ts = time.time()
        items = fv.entries(self.vid, hub=False, kept=False, view_request=active)
        return {"alive": True, "active": active, "items": items, "ts": ts, "wkey": fv.ui_lang(),
                "lang": os.environ.get("FLEET_VIEW_LANG"), "caches": fv.caches_export()}

    def worker_read(self):
        pid, r, buf, _t0 = self.worker
        try:
            chunk = os.read(r, 1 << 16)
        except OSError:
            chunk = b""
        if chunk:
            buf.extend(chunk)
            return
        os.close(r)
        self.worker = None
        self.due = time.time() + self.every()
        if not buf:
            return
        try:
            res = pickle.loads(bytes(buf))
        except Exception:   # noqa: BLE001
            return
        if not res.get("alive", True):
            log("view %s gone: exiting" % self.vid)
            self.alive = False
            return
        self.items, self.ts, self.wkey, self.active = res["items"], res["ts"], res["wkey"], res["active"]
        if res.get("lang") is not None:
            os.environ["FLEET_VIEW_LANG"] = res["lang"]
        self.fv.caches_import(res.get("caches") or {})

    def title(self):
        """The popup frame's title, on the 看台 session (`-T #{@view_popup_title}`)."""
        if self.session:
            self.fv.popup_title_set(self.vid)

    # a ⌘P --------------------------------------------------------------------
    def serve_conn(self, conn):
        conn.settimeout(0.5)
        fds = []
        uid = peer_uid(conn)
        if uid is not None and uid != os.getuid():
            log("refused a peer of uid %s" % uid)
            conn.close()
            return
        try:
            msg, fds = recv_head(conn)
            if fds or msg.get("v") != PROTO:
                raise ValueError("descriptors before ready, or protocol %r" % msg.get("v"))
            conn.sendall(b'{"ready": 1}\n')
            fds = recv_fds(conn)
        except Probe:
            conn.close()                # `status` / `ensure` asking whether we answer
            return
        except (OSError, ValueError) as e:
            log("bad request: %s" % e)
            for fd in fds:
                os.close(fd)
            conn.close()
            return
        if len(fds) != 3:
            for fd in fds:
                os.close(fd)
            conn.close()
            return
        self.last_conn = time.time()
        env = msg.get("env") if isinstance(msg.get("env"), dict) else {}
        pid = os.fork()
        if pid == 0:
            self.child(conn, fds, msg, env)     # never returns
        for fd in fds:
            os.close(fd)
        conn.close()
        self.children.add(pid)
        if env:
            env = {k: str(v) for k, v in env.items() if k not in VOLATILE}
            if env != self.env:
                # the panel's real environment: the list is read again in it now
                self.env, self.due = env, 0.0

    def child(self, conn, fds, msg, env):
        rc = 1
        try:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            for i, fd in enumerate(fds):
                os.dup2(fd, i)
                os.close(fd)
            conn.settimeout(None)
            conn.sendall(json.dumps({"pid": os.getpid()}).encode() + b"\n")
            ctx = parse_ctx(msg.get("ctx") or env.get("FLEET_PANEL_CTX", ""))
            if env:
                os.environ.clear()
                os.environ.update({k: str(v) for k, v in env.items()})
            os.environ.pop("FLEET_PANEL_CTX", None)
            self.qo.set_locale()
            fv = self.fv
            if ctx.get("lang_set") and "FLEET_VIEW_LANG" not in os.environ:
                os.environ["FLEET_VIEW_LANG"] = ctx["lang"]
            # the list's words are the language's: another language (or none read
            # yet) ⇒ every word, and the list, read again here
            if fv.ui_lang() != self.wkey:
                fv.caches_words_reset()
                items = None
            else:
                items = self.items
            pre = {"items": items, "ts": self.ts, "cur": ctx.get("cur"), "vsh": ctx.get("vsh"),
                   "t0": msg.get("t0"), "ctx": ctx}
            os.environ.setdefault("ESCDELAY", "25")
            import curses
            def panel(screen):
                try:
                    return fv.popup(screen, self.qo, self.vid, ctx.get("client", ""), "", "", pre)
                except Exception:
                    # said before curses gives the terminal back (its teardown can wait on it)
                    log("panel: " + traceback.format_exc().replace("\n", " | "))
                    raise
            rc = curses.wrapper(panel) or 0
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else 1
        except BaseException:   # noqa: BLE001
            log("child: " + traceback.format_exc().replace("\n", " | "))
            rc = 1
        try:
            conn.sendall(json.dumps({"rc": int(rc)}).encode() + b"\n")
        except OSError:
            pass
        os._exit(int(rc) & 0xff)

    def reap(self):
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                return
            if pid in self.children:
                self.children.discard(pid)
                self.due = min(self.due, time.time())   # a popup closed: read the list again

    def run(self):
        d = own_dir()
        if d is None:
            return 1
        path = sock_path(self.vid)
        if answers(self.vid):
            return 0
        try:
            os.unlink(str(path))
        except OSError:
            pass
        lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            lsock.bind(str(path))
        finally:
            os.umask(old)
        lsock.listen(16)
        lsock.setblocking(False)
        ino = os.stat(str(path)).st_ino
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.signal(signal.SIGCHLD, lambda *_: None)   # wakes select
        self.env = self.popup_env()
        self.title()
        log("serving %s on %s" % (self.vid, path))
        idle = fenv("FLEET_PANEL_SERVER_IDLE", 1800)
        try:
            while not self.stop and self.alive:
                now = time.time()
                self.worker_watch(now)
                self.hub_keep(now)
                if self.worker is None and now >= self.due:
                    self.start_worker()
                rl = [lsock] + ([self.worker[1]] if self.worker else [])
                wait = 1.0 if self.worker else max(0.05, min(1.0, self.due - now))
                try:
                    r, _, _ = select.select(rl, [], [], wait)
                except InterruptedError:
                    r = []
                except OSError as e:
                    if e.errno == errno.EINTR:
                        r = []
                    else:
                        raise
                self.reap()
                if lsock in r:
                    while True:
                        try:
                            conn, _ = lsock.accept()
                        except (BlockingIOError, InterruptedError):
                            break
                        conn.setblocking(True)
                        try:
                            self.serve_conn(conn)
                        except Exception:   # noqa: BLE001 — one bad ⌘P never takes the server down
                            log("conn: " + traceback.format_exc().replace("\n", " | "))
                if self.worker and self.worker[1] in r:
                    self.worker_read()
                if time.time() - self.last_conn > idle and not self.children:
                    log("idle %ds: exiting" % idle)
                    break
                if os.path.realpath(str(BIN)) != self.real:
                    log("install moved (%s → %s): starting again on its code" % (self.real, os.path.realpath(str(BIN))))
                    self.moved = True
                    break
                try:
                    if os.stat(str(path)).st_ino != ino:
                        log("socket replaced: exiting")
                        break
                except OSError:
                    log("socket gone: exiting")
                    break
        finally:
            try:
                if os.stat(str(path)).st_ino == ino:
                    os.unlink(str(path))
            except OSError:
                pass
            lsock.close()
        return 0

    def popup_env(self):
        """The environment a popup of this 看台 starts with — tmux's global
        environment under the session's — until the first ⌘P hands the real one."""
        env = {}
        if not self.session:
            return dict(os.environ)
        for args in (["show-environment", "-g"], ["show-environment", "-t", "=" + self.session]):
            rc, out = self.fv.tm(*args)
            for line in out.splitlines() if rc == 0 else []:
                if line.startswith("-"):
                    env.pop(line[1:], None)
                elif "=" in line:
                    k, v = line.split("=", 1)
                    env[k] = v
        env.pop("FLEET_PANEL_CTX", None)
        return env or dict(os.environ)


def recv_fds(conn):
    """The descriptors the connector sends after `ready` (with one byte)."""
    fds = []
    data, anc, _flags, _addr = conn.recvmsg(16, socket.CMSG_SPACE(16 * 4))
    for level, kind, payload in anc:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            n = len(payload) - len(payload) % 4
            fds.extend(struct.unpack("%di" % (n // 4), payload[:n]))
    return fds


class Probe(Exception):
    """A connection that closed before sending a byte: a probe, not a ⌘P."""


def recv_head(conn):
    """One JSON line and the descriptors sent with its first bytes."""
    fds, buf = [], b""
    while not buf.endswith(b"\n"):
        data, anc, _flags, _addr = conn.recvmsg(1 << 16, socket.CMSG_SPACE(16 * 4))
        for level, kind, payload in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                n = len(payload) - len(payload) % 4
                fds.extend(struct.unpack("%di" % (n // 4), payload[:n]))
        if not data:
            break
        buf += data
        if len(buf) > MAX_HEAD:
            raise ValueError("request too long")
    if not buf.endswith(b"\n"):
        for fd in fds:
            os.close(fd)
        if not buf and not fds:
            raise Probe()
        raise ValueError("no request line")
    return json.loads(buf.decode("utf-8")), fds


# --- the connector, in Python (ccquota panel attach is the same) -----------------

def attach(argv):
    """The connector: hand this process's terminal to the server, else run the
    Python panel here. argv: the fallback command (after `--`)."""
    t0 = time.time()
    ctx = os.environ.get("FLEET_PANEL_CTX", "")
    info = parse_ctx(ctx)
    vid = view_from_session(info.get("session", ""))
    fallback = argv[argv.index("--") + 1:] if "--" in argv else []
    if vid and enabled():
        rc = attach_once(vid, ctx, t0)
        if rc is not None:
            return rc
    if not fallback:
        return 1
    if info.get("session"):
        fallback += ["--view", info["session"]] + (["--client", info["client"]] if info.get("client") else [])
    os.environ["FLEET_PANEL_T0"] = "%.3f" % t0
    os.execvp(fallback[0], fallback)


def view_from_session(name):
    v = (name or "").rpartition("@view-")[2]
    return v if v and len(v) <= 64 and all(c.isalnum() or c == "-" for c in v) else ""


def attach_once(vid, ctx, t0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.05)
    try:
        s.connect(str(sock_path(vid)))
        line = json.dumps({"v": PROTO, "ctx": ctx, "env": dict(os.environ), "t0": t0}).encode() + b"\n"
        s.settimeout(1.0)
        s.sendall(line)
        f = s.makefile("rb")
        if not json.loads(f.readline() or b"{}").get("ready"):
            raise ValueError("not ready")
        s.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("3i", 0, 1, 2))])
        first = json.loads(f.readline() or b"{}")
        pid = int(first.get("pid") or 0)
    except (OSError, ValueError):
        s.close()
        return None
    if pid <= 0:
        s.close()
        return None
    for sig in (signal.SIGWINCH, signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, lambda n, _f, p=pid: _forward(p, n))
    s.settimeout(None)
    while True:
        try:
            line = f.readline()
            break
        except InterruptedError:
            continue
    try:
        return int(json.loads(line or b"{}").get("rc", 1))
    except ValueError:
        return 1


def _forward(pid, sig):
    try:
        os.kill(pid, sig)
    except OSError:
        pass
    if sig != signal.SIGWINCH:
        os._exit(128 + sig)


# --- the door -------------------------------------------------------------------

def opt(argv, name):
    return argv[argv.index(name) + 1] if name in argv[:-1] else ""


def load_qo():
    import importlib.util
    spec = importlib.util.spec_from_file_location("fleet_quickopen", str(BIN / "fleet-quickopen.py"))
    qo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qo)
    return qo


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "attach":
        return attach(argv[1:])
    vid = opt(argv, "--view").rpartition("@view-")[2]
    if cmd == "sock":
        print(sock_path(vid))
        return 0
    if not vid:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    if cmd == "ensure":
        return ensure(vid, opt(argv, "--socket"))
    if cmd == "status":
        if answers(vid):
            try:
                st = os.stat(str(sock_path(vid)))
                print("up age=%d" % (time.time() - st.st_mtime))
            except OSError:
                print("up")
            return 0
        print("down")
        return 1
    if cmd == "stop":
        p = sock_path(vid)
        try:
            os.unlink(str(p))      # the server sees its socket go and exits
        except OSError:
            pass
        return 0
    if cmd == "serve":
        if not enabled():
            return 1
        qo = load_qo()
        qo.set_locale()
        import fleet_view as fv
        fv.view_id(opt(argv, "--view"))     # a `<fleet>@view-<id>` names its fleet
        if opt(argv, "--socket"):           # outside the server: its socket's label
            fv._SOCK[0] = opt(argv, "--socket")
            os.environ.pop("TMUX", None)
        try:
            srv = Server(vid, qo, fv)
            rc = srv.run()
        except Exception:   # noqa: BLE001
            log("serve: " + traceback.format_exc().replace("\n", " | "))
            return 1
        if srv.moved:
            # the new release's own server, in this process (its socket was let go)
            os.execv(sys.executable, [sys.executable, str(BIN / "fleet-panel-server.py")] + argv)
        return rc
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
