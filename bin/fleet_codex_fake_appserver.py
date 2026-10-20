#!/usr/bin/env python3
"""The ONE fake Codex every selftest uses (T540; T585, EPIC T580 C1).

It speaks the way the Codex pinned in release.json (0.162.1) speaks — the shapes are
held against recorded output of the real `codex app-server` by
fleet-codex-fake-selftest.py (fleet-codex-fake-samples.json). No model, no network.

One state model, `Codex`, served three ways:
  - in process:   Codex(...).client()  — call / receive / send / close, as
                  fleet-codex-rpc.py's Client (errors raise ValueError(message));
  - a socket:     FakeAppServer(path, script=None) — the WebSocket JSON-RPC
                  fleet-codex-rpc.py speaks, on a Unix socket (`.remote`);
  - a binary:     copy or link this file as `codex` on PATH. `codex app-server
                  --listen unix://P` serves P, `codex app-server` speaks JSON lines
                  on stdio, anything else is the TUI client. The scenario is read from
                  `--script <json>` (first arguments) or $FLEET_FAKE_CODEX_SCRIPT.

What it answers: initialize, thread/start · resume · fork · read · loaded/list ·
turns/list, turn/start, thread/queue/add · start · delete · list, account/read,
account/rateLimits/read. As the real server does (T572), every thread/started names
ONE originator for the whole process — `claude_fleet` unless the scenario says —
whoever opened the thread, and a start's broadcast goes out BEFORE its answer. A turn
the API starts finishes at once (an instant model); a person's turn (`user_turn`)
stays active until `finish`, whose idle edge drains the queue's head. `clear()` is
the TUI's /clear: a new thread and a thread/started that says nothing of /clear.

Scenario (a JSON object; every key optional):
  version      "0.162.1"             initialize's userAgent version
  originator   (first initialize's clientInfo name)  every thread/started's originator
  threads      [{id, cwd, ...}]      loaded at start, in order; the last is the TUI's
  turns        [{id, clientId}]      the TUI thread's turns at start
  turn_ids     ["native-turn", ...]  ids handed to new turns in order, then generated
  young        false                 thread/turns/list refused ("list_turns is not
                                     supported yet", the store #4617 met)
  answers      {method: result | {"file": path}}   a fixed answer (file read per call)
  errors       {method: message}     answered as a JSON-RPC error, every time
  delay        {method: secs | {"secs": n, "if_exists": path}}
  drop         [method]              the connection closes instead of an answer (断线)
  clear_after  n                     /clear right after the n-th turn/start
  inside       dir                   refuse (exit 2) when `record` is not under it
  record       dir                   writes server.json / client.json ({argv, remote,
                                     pid, path}), requests.log, delivered.json (the
                                     last turn/start's params), delivered.log (each)
  server       {"exit": n, "lifetime": 120}       exit before listening; bounded life
  client       {"tmux": {opt: value}, "run": [[argv]], "ready": text, "stdin": bool,
                "wait": path, "hold": {"flag": "--hold", "while": path, "secs": 20},
                "exit": n}
Strings take {env:NAME}, {env:NAME:default}, {pid}, {thread}, {remote}, {remote_dir}.

`session_started(agent, ...)` is the other side of a two-agent leg: the same session
start as Codex's thread/started or as Claude's SessionStart hook payload.
"""
import base64
import copy
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid


VERSION = "0.162.1"             # release.json's pinned Codex
ORIGINATOR = "claude_fleet"     # fleet-codex-rpc.py's clientInfo name
AGENTS = ("claude", "codex")


def uuid7(ms):
    """A UUIDv7 made at `ms` (Codex thread ids are UUIDv7)."""
    rand = int.from_bytes(os.urandom(10), "big")
    value = (ms & ((1 << 48) - 1)) << 80 | 0x7 << 76 | (rand >> 68 & 0xFFF) << 64 | 0b10 << 62 | rand & ((1 << 62) - 1)
    return str(uuid.UUID(int=value))


def tui_thread(tid, **extra):
    """A thread in 0.162.1's shape (the keys fleet reads keep the fixture's old values)."""
    now = int(time.time())
    cwd = extra.get("cwd", "/fixture")
    base = dict(id=tid, environments=[dict(environmentId="local", cwd=cwd, runtimeWorkspaceRoots=[cwd])],
                extra=None, sessionId=tid, forkedFromId=None, parentThreadId=None, preview="",
                ephemeral=False, section=None, sectionEnteredAt=None, projectId=None,
                historyMode="paginated", modelProvider="openai", model="gpt-fixture",
                reasoningEffort=None, createdAt=now, updatedAt=now, recencyAt=now,
                status={"type": "idle"}, path="", cwd=cwd, cliVersion=VERSION,
                originator=ORIGINATOR, source="vscode", canAcceptDirectInput=True,
                threadSource=None, agentNickname=None, agentRole=None, gitInfo=None,
                name=None, daybreakEnabled=None, turns=[])
    base.update(extra)
    return base


def session_started(agent, sid, cwd="/fixture", source="startup", **extra):
    """One session start as `agent` reports it: Codex's thread/started notification
    (it never says /clear), Claude's SessionStart hook payload."""
    if agent == "codex":
        return {"method": "thread/started", "params": {"thread": tui_thread(sid, cwd=cwd, **extra)}}
    if agent == "claude":
        return dict(dict(session_id=sid, transcript_path="/fixture/%s.jsonl" % sid, cwd=cwd,
                         hook_event_name="SessionStart", source=source), **extra)
    raise ValueError("unknown agent " + str(agent))


_TOKEN = re.compile(r"\{(env:[A-Za-z_][A-Za-z0-9_]*(?::[^}]*)?|pid|thread|remote|remote_dir)\}")


def expand(value, ctx=None):
    """Fill a scenario value's {placeholders} (recursively for lists / dicts); one
    `ctx` does not name is left for a later pass."""
    ctx = ctx or {}
    if isinstance(value, str):
        def one(m):
            key = m.group(1)
            if key.startswith("env:"):
                name, _, default = key[4:].partition(":")
                return os.environ.get(name, default)
            return str(ctx[key]) if key in ctx else m.group(0)
        return _TOKEN.sub(one, value)
    if isinstance(value, list):
        return [expand(v, ctx) for v in value]
    if isinstance(value, dict):
        return {k: expand(v, ctx) for k, v in value.items()}
    return value


class Dropped(EOFError):
    """The scenario dropped the connection instead of answering."""


class Codex:
    """The app-server's state: threads, their turns and queues, the clients that hear
    its notifications. `before` / `fail` (method -> callable / exception, once) are
    the in-process hooks a test arms; the scenario's keys are their JSON form."""

    def __init__(self, script=None, **kw):
        s = dict(script or {}, **kw)
        self.script = s
        self.version = s.get("version", VERSION)
        self.originator = s.get("originator")  # None: the first initialize's clientInfo name
        self.young = bool(s.get("young", False))
        self.answers, self.errors = dict(s.get("answers") or {}), dict(s.get("errors") or {})
        self.delay, self.drop = dict(s.get("delay") or {}), set(s.get("drop") or ())
        self.clear_after = s.get("clear_after")
        self.record = expand(s["record"]) if s.get("record") else ""
        self.turn_ids = list(s.get("turn_ids") or ())
        self.before, self.fail = {}, {}
        self.threads, self.loaded = {}, []
        self._turns, self._queue, self._active = {}, {}, {}
        self.calls, self.requests, self.delivered = [], [], []
        self.seq, self.started = 1, 0
        self.lock = threading.RLock()
        self.listeners = []
        self.pending = []  # (server request, "before" | "after" its thread/resume answer)
        for t in s.get("threads") or ():
            self.add(tui_thread(t["id"], **{k: v for k, v in t.items() if k != "id"}))
        if s.get("turns") is not None:
            if not self.loaded:
                self.add(tui_thread(uuid7(int(time.time() * 1000))))
            self._turns[self.thread] = [dict(t) for t in s["turns"]]

    # -- the TUI thread (the last loaded) and its turns / queue
    @property
    def thread(self):
        return self.loaded[-1] if self.loaded else None

    @property
    def turns(self):
        return self._turns.setdefault(self.thread, [])

    @property
    def queue(self):
        return self._queue.setdefault(self.thread, [])

    @property
    def active(self):
        return self._active.get(self.thread)

    @active.setter
    def active(self, value):
        self._active[self.thread] = value

    def next_id(self, kind):
        self.seq += 1
        if kind == "turn" and self.turn_ids:
            return self.turn_ids.pop(0)
        return "%s-%d" % (kind, self.seq)

    def add(self, thread, broadcast=False):
        with self.lock:
            thread = dict(thread, originator=self.originator or ORIGINATOR) if broadcast else thread
            self.threads[thread["id"]] = thread
            if thread["id"] not in self.loaded:
                self.loaded.append(thread["id"])
        if broadcast:
            self.broadcast({"method": "thread/started", "params": {"thread": thread}})
        return thread

    def clear(self, cwd=None):
        """The TUI's /clear: a new thread, announced like any other start."""
        cwd = cwd or (self.threads[self.thread]["cwd"] if self.thread else "/fixture")
        return self.add(tui_thread(uuid7(int(time.time() * 1000)), cwd=cwd), broadcast=True)

    def server_request(self, message, replay="after"):
        """A request the server holds for a client (a question, an approval): replayed
        to whoever resumes its thread, before or after the resume's answer."""
        self.pending.append((message, replay))

    def resolve(self, request_id):
        """The request is answered (by anyone): every client hears serverRequest/resolved."""
        for message, replay in list(self.pending):
            if message.get("id") == request_id:
                self.pending.remove((message, replay))
                self.broadcast({"method": "serverRequest/resolved", "params": {
                    "threadId": (message.get("params") or {}).get("threadId"), "requestId": request_id}})

    def broadcast(self, message):
        if "method" in message and "id" not in message:  # 0.162 stamps every notification
            message = dict(message, emittedAtMs=message.get("emittedAtMs", int(time.time() * 1000)))
        with self.lock:
            listeners = list(self.listeners)
        for listen in listeners:
            listen(message)

    def status(self, tid):
        if self._active.get(tid):
            return {"type": "active", "activeFlags": []}
        return copy.deepcopy(self.threads.get(tid, {}).get("status") or {"type": "idle"})

    def start_turn(self, client_id, text="", tid=None):
        tid = tid or self.thread
        t = dict(id=self.next_id("turn"), clientId=client_id)
        self._turns.setdefault(tid, []).append(t)
        self._active[tid] = t["id"]
        if client_id:
            self.delivered.append(client_id)
        self.broadcast({"method": "turn/started", "params": {"threadId": tid, "turn": dict(
            id=t["id"], rootTurnId=t["id"], items=[], itemsView="notLoaded", status="inProgress",
            error=None, startedAt=int(time.time()), completedAt=None, durationMs=None)}})
        return t

    def user_turn(self):
        """A person types into the TUI: a turn that stays active until finish()."""
        return self.start_turn(None)

    def finish(self, tid=None):
        tid = tid or self.thread
        self._active[tid] = None
        queue = self._queue.setdefault(tid, [])
        if queue:  # the native idle edge drains the head
            q = queue.pop(0)
            self.start_turn(q["clientUserMessageId"], tid=tid)
            self._active[tid] = None

    def _instant(self, client_id, tid):
        t = self.start_turn(client_id, tid=tid)
        self._active[tid] = None
        return t

    # -- the RPC surface
    def call(self, method, params):
        params = params or {}
        self.calls.append(method)
        self.requests.append((method, params))
        self._log(method, params)
        if method in self.before:
            self.before.pop(method)()
        if method in self.fail:
            raise self.fail.pop(method)
        wait = self.delay.get(method)
        if isinstance(wait, dict):
            wait = wait.get("secs", 0) if not wait.get("if_exists") or os.path.exists(expand(wait["if_exists"])) else 0
        if wait:
            time.sleep(float(wait))
        if method in self.drop:
            raise Dropped("fixture: dropped on " + method)
        if method in self.errors:
            raise ValueError(expand(self.errors[method]))
        if method in self.answers:
            a = self.answers[method]
            if isinstance(a, dict) and set(a) == {"file"}:
                with open(expand(a["file"])) as fh:
                    return json.load(fh)
            return copy.deepcopy(a)
        handler = getattr(self, "_" + method.replace("/", "_"), None)
        if handler is None:
            raise ValueError("fixture: unsupported " + str(method))
        with self.lock:
            return handler(params)

    def _log(self, method, params):
        if not self.record:
            return
        try:
            with open(os.path.join(self.record, "requests.log"), "a") as fh:
                fh.write(json.dumps({"method": method, "params": params}) + "\n")
            if method == "turn/start":
                with open(os.path.join(self.record, "delivered.json"), "w") as fh:
                    json.dump(params, fh)
                with open(os.path.join(self.record, "delivered.log"), "a") as fh:
                    fh.write(json.dumps(params) + "\n")  # every turn, in order
        except OSError:
            pass

    def _thread(self, tid):
        if tid not in self.threads:
            raise ValueError("thread not found: " + str(tid))
        return dict(self.threads[tid], status=self.status(tid))

    def _started(self, thread):
        return dict(thread=thread, model=thread["model"], modelProvider="openai", serviceTier=None,
                    disabledPluginIds=[], cwd=thread["cwd"], runtimeWorkspaceRoots=[thread["cwd"]],
                    instructionSources=[], approvalPolicy="on-request", approvalsReviewer="user",
                    sandbox={"type": "readOnly", "networkAccess": False},
                    activePermissionProfile={"id": ":read-only", "extends": None},
                    reasoningEffort=None, multiAgentMode="explicitRequestOnly")

    def _initialize(self, params):
        name = ((params.get("clientInfo") or {}).get("name")) or ORIGINATOR
        if self.originator is None:
            self.originator = name
        return {"userAgent": "%s/%s (Mac OS; arm64)" % (name, self.version), "codexHome": "/fixture/.codex",
                "platformFamily": "unix", "platformOs": "macos"}

    def _thread_loaded_list(self, params):
        return {"data": list(self.loaded), "nextCursor": None}

    def _thread_start(self, params):
        t = tui_thread(uuid7(int(time.time() * 1000)), cwd=params.get("cwd") or "/fixture")
        return self._started(self.add(t, broadcast=True))

    def _thread_fork(self, params):
        src = self._thread(params.get("threadId"))
        t = tui_thread(uuid7(int(time.time() * 1000)), cwd=src["cwd"], forkedFromId=src["id"])
        return self._started(self.add(t, broadcast=True))

    def _thread_resume(self, params):
        t = self._thread(params.get("threadId"))
        return dict(self._started(t), turnsBackwardsCursor=None, initialTurnsPage=None, itemsBackwardsCursor=None,
                    collaborationMode={"mode": "default", "settings": {"model": t["model"], "reasoning_effort": None,
                                                                       "developer_instructions": None}})

    def _thread_read(self, params):
        tid = params.get("threadId")
        t = self._thread(tid)
        if params.get("includeTurns"):
            turns = self._turns.get(tid) or []
            if not turns:
                raise ValueError("list_turns is not supported yet")
            t["turns"] = [dict(id=x["id"], items=[dict(type="userMessage", clientId=x["clientId"])]) for x in turns]
        return {"thread": t}

    def _thread_turns_list(self, params):
        tid = params.get("threadId")
        turns = self._turns.get(tid) or []
        if self.young:
            raise ValueError("list_turns is not supported yet")
        if not turns:
            raise ValueError("thread %s is not materialized yet; thread/turns/list is unavailable "
                             "before first user message" % tid)
        off = int(params.get("cursor") or 0)
        rows = list(reversed(turns))[off:off + int(params.get("limit") or 25)]
        nxt = str(off + len(rows)) if off + len(rows) < len(turns) else None
        return dict(data=[dict(id=t["id"], items=[dict(type="userMessage", clientId=t["clientId"])]) for t in rows],
                    nextCursor=nxt)

    def _turn_start(self, params):
        tid = params.get("threadId")
        self._thread(tid)
        if self._active.get(tid):
            raise ValueError("thread already has an active or pending turn")
        t = self._instant(params.get("clientUserMessageId"), tid)
        self.started += 1
        if self.clear_after and self.started == int(self.clear_after):
            self.clear()
        return {"turn": dict(id=t["id"], status="inProgress", items=[])}

    def _thread_queue_add(self, params):
        tid = params.get("threadId") or self.thread
        q = dict(id=self.next_id("q"), input=[dict(i, text_elements=i.get("text_elements", []))
                                               if isinstance(i, dict) and i.get("type") == "text" else i
                                               for i in params.get("input") or ()],
                 clientUserMessageId=params.get("clientUserMessageId"))
        queue = self._queue.setdefault(tid, [])
        queue.append(q)
        if not self._active.get(tid):
            queue.remove(q)
            self._instant(q["clientUserMessageId"], tid)
        return dict(queuedSubmission=q)

    def _thread_queue_start(self, params):
        tid = params.get("threadId") or self.thread
        queue = self._queue.setdefault(tid, [])
        q = [x for x in queue if x["id"] == params.get("queuedSubmissionId")]
        if not q:
            raise ValueError("queued submission not found: " + str(params.get("queuedSubmissionId")))
        if self._active.get(tid):
            raise ValueError("thread already has an active or pending turn")
        queue.remove(q[0])
        t = self._instant(q[0]["clientUserMessageId"], tid)
        return dict(turn=dict(id=t["id"], status="inProgress", items=[]))

    def _thread_queue_delete(self, params):
        queue = self._queue.setdefault(params.get("threadId") or self.thread, [])
        q = [x for x in queue if x["id"] == params.get("queuedSubmissionId")]
        for x in q:
            queue.remove(x)
        return dict(deleted=bool(q))

    def _thread_queue_list(self, params):
        return dict(data=list(self._queue.get(params.get("threadId") or self.thread) or []), nextCursor=None)

    def _account_read(self, params):
        return {"account": None, "requiresOpenaiAuth": True, "workspaceRouting": None}

    def _account_rateLimits_read(self, params):
        raise ValueError("codex account authentication required to read rate limits")

    def client(self):
        return InProcess(self)


class InProcess:
    """An in-process connection, as fleet-codex-rpc.py's Client: call / receive /
    send / close, `.events` (what came in while a call waited for its answer — as
    the real client's exchange keeps it), `.initialized`, `.calls` ((method, params)
    this connection sent). Whatever reached the connection between calls is read by
    the next call first, as on the socket. A server request planted with
    Codex.server_request is replayed on thread/resume and resolved by `send`."""

    def __init__(self, codex):
        self.codex, self.events, self.inbox, self.sent, self.calls = codex, [], [], [], []
        self.closed, self.socket, self.waiting = False, None, False
        codex.listeners.append(self.hear)
        self.initialized = codex.call("initialize", {"clientInfo": {"name": ORIGINATOR, "version": "1"},
                                                     "capabilities": {"experimentalApi": True}})

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def hear(self, message):
        (self.events if self.waiting else self.inbox).append(message)

    def call(self, method, params):
        self.calls.append((method, params))
        self.events.extend(self.inbox)
        del self.inbox[:]
        self.waiting = True
        try:
            result = self.codex.call(method, params)
            if method == "thread/resume":
                for request, replay in self.codex.pending:
                    if (request.get("params") or {}).get("threadId") == (params or {}).get("threadId"):
                        (self.events if replay == "before" else self.inbox).append(copy.deepcopy(request))
            return result
        finally:
            self.waiting = False

    def receive(self, nonblocking=False):
        if self.inbox:
            return self.inbox.pop(0)
        if nonblocking:
            return None
        raise TimeoutError("no matching pending request")

    def send(self, value):
        self.sent.append(value)
        self.codex.resolve(value.get("id"))

    def close(self):
        self.closed = True


class FakeAppServer(Codex):
    """`Codex` on a Unix socket, speaking WebSocket JSON-RPC like `codex app-server
    --listen unix://…`. `.remote` is the endpoint; `close()` ends it."""

    def __init__(self, path, script=None, **kw):
        Codex.__init__(self, script, **kw)
        self.path = path
        self.conns = []
        self.listeners.append(self._to_sockets)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.remote = "unix://" + path
        threading.Thread(target=self.accept, daemon=True).start()

    def _to_sockets(self, message):
        with self.lock:
            conns = list(self.conns)
        for conn in conns:
            try:
                self.send(conn, message)
            except OSError:
                pass

    def close(self):
        self.sock.close()
        with self.lock:
            for conn in self.conns:
                try:
                    conn.close()
                except OSError:
                    pass
        try:
            os.unlink(self.path)
        except OSError:
            pass

    @staticmethod
    def read(conn, n):
        data = b""
        while len(data) < n:
            chunk = conn.recv(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    @staticmethod
    def send(conn, value):
        payload = json.dumps(value).encode()
        n = len(payload)
        head = b"\x81" + (bytes([n]) if n < 126 else b"\x7e" + struct.pack("!H", n) if n < 65536
                          else b"\x7f" + struct.pack("!Q", n))
        conn.sendall(head + payload)

    def accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        try:
            head = b""
            while not head.endswith(b"\r\n\r\n"):
                head += self.read(conn, 1)
            key = [l.split(b":", 1)[1].strip() for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
            accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            with self.lock:
                self.conns.append(conn)
            while True:
                first, second = self.read(conn, 2)
                length = second & 127
                if length == 126:
                    length = struct.unpack("!H", self.read(conn, 2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.read(conn, 8))[0]
                mask = self.read(conn, 4) if second & 128 else b"\0\0\0\0"
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.read(conn, length)))
                if first & 15 == 8:
                    return
                msg = json.loads(payload)
                if "id" not in msg:
                    continue
                reply = answer(self, msg)
                if reply is None:
                    return
                self.send(conn, reply)
        except (OSError, EOFError, ValueError, IndexError):
            pass
        finally:
            with self.lock:
                if conn in self.conns:
                    self.conns.remove(conn)
            try:
                conn.close()
            except OSError:
                pass


def answer(codex, msg):
    """One request's JSON-RPC reply; None = drop the connection."""
    try:
        return {"id": msg["id"], "result": codex.call(msg.get("method"), msg.get("params"))}
    except Dropped:
        return None
    except (ValueError, TimeoutError) as e:
        return {"id": msg["id"], "error": {"code": -32600, "message": str(e)}}


# -- the `codex` binary
def _record(dirname, name, data):
    if dirname:
        with open(os.path.join(dirname, name), "w") as fh:
            json.dump(data, fh)


def _serve_stdio(codex):
    codex.listeners.append(lambda m: (sys.stdout.write(json.dumps(m) + "\n"), sys.stdout.flush()))
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "id" not in msg:
            continue
        reply = answer(codex, msg)
        if reply is None:
            return 0
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()
    return 0


def _client(script, args):
    c = script.get("client") or {}
    remote = args[args.index("--remote") + 1] if "--remote" in args[:-1] else os.environ.get("FLEET_CODEX_REMOTE", "")
    if "--remote" in args and os.environ.get("FLEET_CODEX_REMOTE") not in (None, remote):
        sys.stderr.write("fake codex: --remote is not $FLEET_CODEX_REMOTE\n")
        return 2
    path = remote[7:] if remote.startswith("unix://") else remote
    threads = script.get("threads") or [{}]
    ctx = dict(pid=os.getpid(), thread=threads[-1].get("id", ""), remote=remote,
               remote_dir=os.path.dirname(path) if path else "")
    record = expand(script.get("record") or "", ctx)
    _record(record, "client.json", dict(argv=args, remote=os.environ.get("FLEET_CODEX_REMOTE"),
                                        pid=os.getpid(), path=path))
    if ctx["thread"]:
        os.environ["CODEX_THREAD_ID"] = ctx["thread"]
    for opt, value in (c.get("tmux") or {}).items():
        value = expand(value, ctx)
        subprocess.run(["tmux", "set-option", "-w", "-t", os.environ["TMUX_PANE"], opt,
                        value if isinstance(value, str) else json.dumps(value)], check=True)
    for argv in c.get("run") or ():
        subprocess.run(expand(argv, ctx), check=True, stdout=subprocess.DEVNULL)
    if c.get("ready"):
        sys.stdout.write(expand(c["ready"], ctx))
        sys.stdout.flush()
    if c.get("stdin"):
        for _ in sys.stdin:
            pass
    if c.get("wait"):
        wait, end = expand(c["wait"], ctx), time.monotonic() + 10
        while not os.path.exists(wait) and time.monotonic() < end:
            time.sleep(.1)
        if not os.path.exists(wait):
            sys.stderr.write("fake codex: never saw " + wait + "\n")
            return 1
    hold = c.get("hold") or {}
    if hold and hold.get("flag", "--hold") in args:
        end = time.monotonic() + float(hold.get("secs", 20))
        while os.path.exists(expand(hold.get("while", "{remote_dir}"), ctx)) and time.monotonic() < end:
            time.sleep(.05)
    return int(expand(str(c.get("exit", 0)), ctx) or 0)


def main(argv):
    args = list(argv)
    path = os.environ.get("FLEET_FAKE_CODEX_SCRIPT", "")
    if args[:1] == ["--script"]:
        path, args = args[1], args[2:]
    script = {}
    if path:
        with open(path) as fh:
            script = expand(json.load(fh))  # {env:…} now; {pid} {thread} {remote} per mode
    inside = script.get("inside")
    if inside and script.get("record") and not os.path.realpath(script["record"]).startswith(
            os.path.realpath(inside) + os.sep):
        sys.stderr.write("fake codex: record dir outside its sandbox\n")
        return 2
    if "app-server" not in args:
        return _client(script, args)
    srv = script.get("server") or {}
    listen = args[args.index("--listen") + 1] if "--listen" in args[:-1] else ""
    sock = listen[7:] if listen.startswith("unix://") else ""
    if listen and os.environ.get("FLEET_CODEX_REMOTE") not in (None, listen):
        sys.stderr.write("fake codex: --listen is not $FLEET_CODEX_REMOTE\n")
        return 2
    ctx = dict(pid=os.getpid(), remote=listen, remote_dir=os.path.dirname(sock))
    record = expand(script.get("record") or "", ctx)
    _record(record, "server.json", dict(argv=args, remote=os.environ.get("FLEET_CODEX_REMOTE"),
                                        pid=os.getpid(), path=sock))
    if srv.get("exit") not in (None, ""):
        return int(srv["exit"])
    script = dict(script, record=record)
    if not sock:
        return _serve_stdio(Codex(script))
    server = FakeAppServer(sock, script)
    end = time.monotonic() + float(srv.get("lifetime", 120))
    try:
        while time.monotonic() < end:
            time.sleep(.05)
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
