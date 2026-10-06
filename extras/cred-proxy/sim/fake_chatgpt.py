#!/usr/bin/env python3
"""fake_chatgpt — a loopback stand-in for chatgpt.com's Codex backend + OpenAI's
OAuth token endpoint (issue #1912), so the cred proxy's Codex route can be
exercised end to end with NO real ChatGPT credential. Research only; NOT part of
the install.

    fake_chatgpt.py serve   --state DIR --port 18788 [--max-seconds 900]
    fake_chatgpt.py seed    --state DIR --homes DIR ACCOUNT...   # plays the hub's lease
    fake_chatgpt.py refresh --state DIR --homes DIR ACCOUNT      # plays the hub vault's refresh

Routes (127.0.0.1 only):
    POST /backend-api/codex/responses   the Responses API, streamed as SSE
    POST /oauth/token                   grant_type=refresh_token (rotates both tokens)
    *                                   logged with its credential, 200 {}

What the backend checks, like the real one does (doc §10): `Authorization:
Bearer <access token>` must be a CURRENT token of the account named by
`chatgpt-account-id` — a token replaced by a refresh answers 401 token_revoked,
an unknown one 401 "Could not parse your authentication token". Each account
answers with its own `x-codex-primary-used-percent`, so a rebind is visible in
the session's rate-limit reading.

What the model "says" is scripted off the last user message:
    "Reply with exactly: PONG"  -> PONG
    "DO-TOOLS"                  -> a shell call, then an apply_patch call, then a summary
    "STREAM <n>"                -> n numbered deltas (truncation check), then "END-<n>"
    "SLOW <ms>"                 -> sleeps before the first byte (concurrency check)
    anything else               -> "SIM turn <k> acct=<label>: <echo>"

Non-inference paths answer `200 {}`, except `/wham/accounts/check` (a routing
answer; FAKE_ROUTE=<json> sets its account_routing_override) and `/codex/models`
(`{"models": []}`) — enough to watch NATIVE ChatGPT mode's startup calls, not
enough to get it through workspace routing (doc §10). FAKE_DUMP=1 writes the last
inference body to <state>/last-body.json.

Every request is logged as JSON lines to <state>/requests.log: path, header
NAMES (credential values as <redacted:len>), body keys, store / stream /
instructions length / tool names / input item types. Never a token.
"""
import argparse, base64, hashlib, json, os, re, secrets, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = {"authorization", "chatgpt-account-id", "cookie", "x-api-key"}
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"   # Codex's public OAuth client (credvault/refresh.go)


def b64e(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def jwt(claims):
    """An unsigned look-alike of an OpenAI JWT — Codex only reads its claims."""
    head = b64e(json.dumps({"alg": "none", "typ": "JWT"}).encode())
    return head + "." + b64e(json.dumps(claims).encode()) + ".sim"


def acct_id(label):
    return "sim-" + hashlib.sha256(label.encode()).hexdigest()[:12]


def mint_tokens(label, ttl):
    now = int(time.time())
    auth = {"chatgpt_account_id": acct_id(label), "chatgpt_plan_type": "pro",
            "chatgpt_user_id": "user-sim-" + label}
    at = jwt({"iss": "https://auth.openai.invalid", "exp": now + ttl, "iat": now,
              "jti": secrets.token_hex(8), "https://api.openai.com/auth": auth})
    it = jwt({"email": label + "@sim.invalid", "exp": now + ttl, "iat": now,
              "https://api.openai.com/auth": auth})
    return at, it, "rt_sim_" + secrets.token_hex(16)


# ---- the server's book: who holds which token (the "upstream" truth) ----
class Book:
    def __init__(self, state):
        self.p = os.path.join(state, "book.json")
        self.lock = threading.Lock()

    def load(self):
        try:
            return json.load(open(self.p))
        except (OSError, ValueError):
            return {}

    def save(self, d):
        tmp = self.p + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, json.dumps(d).encode()); os.close(fd); os.replace(tmp, self.p)

    def add(self, label, ttl=864000):
        at, it, rt = mint_tokens(label, ttl)
        with self.lock:
            d = self.load()
            d[acct_id(label)] = {"label": label, "access": [at], "refresh": rt,
                                 "used": 11 + 66 * (len(d) % 2)}
            self.save(d)
        return at, it, rt

    def check(self, aid, tok):
        """-> (label, used%) or (None, (status, code, message))."""
        d = self.load()
        for a, rec in d.items():
            if tok in rec["access"]:
                if tok != rec["access"][-1]:
                    return None, (401, "token_revoked", "Encountered invalidated oauth token for user, failing request")
                if a != aid:
                    return None, (401, "account_mismatch", "chatgpt-account-id does not match the token")
                return rec["label"], rec["used"]
        return None, (401, None, "Could not parse your authentication token. Please try signing in again.")

    def refresh(self, rt, ttl=864000):
        with self.lock:
            d = self.load()
            for a, rec in d.items():
                if rec["refresh"] == rt:
                    at, it, nrt = mint_tokens(rec["label"], ttl)
                    rec["access"].append(at); rec["refresh"] = nrt
                    self.save(d)
                    return {"access_token": at, "id_token": it, "refresh_token": nrt,
                            "expires_in": ttl, "token_type": "Bearer", "scope": "openid profile email"}
        return None


def red(k, v): return "<redacted:%d>" % len(v) if k.lower() in SECRET else v


def sse(ev):
    return ("event: %s\ndata: %s\n\n" % (ev["type"], json.dumps(ev))).encode()


def last_user_text(items):
    for it in reversed(items):
        if it.get("type", "message") == "message" and it.get("role") == "user":
            c = it.get("content")
            if isinstance(c, str):
                return c
            return "".join(p.get("text", "") for p in c or [] if isinstance(p, dict))
    return ""


def flat_tools(tools):
    """Codex 0.160 nests tools in `namespace` groups ({type: namespace, tools: [...]})."""
    out = []
    for t in tools:
        if isinstance(t, dict) and t.get("type") == "namespace":
            out += flat_tools(t.get("tools") or [])
        elif isinstance(t, dict):
            out.append(t)
    return out


def code_mode_call(js):
    """Code mode (gpt-6.x): the one code tool is a FREEFORM `exec` that runs JS
    calling the nested tools — `await tools.exec_command(...)`, `tools.apply_patch(...)`."""
    return {"type": "custom_tool_call", "id": "ctc_" + secrets.token_hex(4),
            "call_id": "call_" + secrets.token_hex(6), "name": "exec", "input": js}


def pick_shell(tools):
    names = {t.get("name"): t for t in tools if isinstance(t, dict)}
    for n in ("exec_command", "shell_command", "shell", "local_shell"):
        if n in names:
            return n, names[n]
    return None, None


def shell_args(name, cmd):
    if name == "exec_command":
        return {"cmd": cmd}
    if name == "shell_command":
        return {"command": cmd}
    return {"command": ["bash", "-lc", cmd]}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    book = None
    state = None
    other_status = 200
    lock = threading.Lock()

    def log_message(self, *a): pass

    def rec(self, **kv):
        kv["t"] = round(time.time(), 3)
        with self.lock, open(os.path.join(self.state, "requests.log"), "a") as f:
            f.write(json.dumps(kv, ensure_ascii=False) + "\n")

    def body(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        if self.headers.get("content-encoding", "").lower() == "zstd":
            return raw, "zstd"
        return raw, ""

    def reply(self, code, obj, extra=()):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("content-length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        self.other("GET")

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/oauth/token":
            return self.oauth()
        if path.endswith("/responses"):
            return self.inference(path)
        self.body()
        self.other("POST")

    def other(self, m):
        """Everything that is not inference (models, plugins, wham/*, analytics …):
        logged with the credential it carried, answered 200 {} (H.other_status)."""
        self.rec(ev="other", m=m, path=self.path.split("?")[0],
                 hdrs=sorted("%s=%s" % (k.lower(), red(k, v)) for k, v in self.headers.items()
                             if k.lower() in SECRET or k.lower() in ("originator", "user-agent")))
        if self.path.split("?")[0].endswith("/accounts/check") and self.other_status == 200:
            aid = self.headers.get("chatgpt-account-id", "")
            return self.reply(200, {"accounts": [{"id": aid, "name": "sim", "plan_type": "pro", "structure": "personal",
                                                  "workspace_backend_origin": "http://%s" % self.headers.get("host", ""), "account_routing_override": json.loads(os.environ.get("FAKE_ROUTE", "null")),
                                                  "profile_picture_url": None}]})
        if self.path.split("?")[0].endswith("/codex/models") and self.other_status == 200:
            return self.reply(200, {"models": []})
        self.reply(self.other_status, {} if self.other_status == 200 else {"detail": "fake_chatgpt: no such route"})

    def oauth(self):
        raw, _ = self.body()
        try:
            f = json.loads(raw)
        except ValueError:
            from urllib.parse import parse_qs
            f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
        ok = f.get("grant_type") == "refresh_token" and f.get("client_id") == CLIENT_ID
        out = self.book.refresh(f.get("refresh_token", "")) if ok else None
        self.rec(ev="oauth", grant=f.get("grant_type"), client_ok=f.get("client_id") == CLIENT_ID,
                 refreshed=bool(out))
        if not out:
            return self.reply(401, {"error": "invalid_grant", "error_description": "refresh token already used"})
        self.reply(200, out)

    def inference(self, path):
        t0 = time.time()
        raw, enc = self.body()
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        try:
            req = json.loads(raw) if not enc else {}
        except ValueError:
            req = {}
        items = req.get("input") or []
        tools = list(req.get("tools") or [])
        for it in items:   # responses-lite (x-openai-internal-codex-responses-lite): tools ride in the input
            if it.get("type") == "additional_tools":
                tools += it.get("tools") or []
        tools = flat_tools(tools)
        if os.environ.get("FAKE_DUMP"):
            with open(os.path.join(self.state, "last-body.json"), "w") as f:
                json.dump(req, f, indent=1)
        log = dict(ev="responses", path=path, hdrs=sorted("%s=%s" % (k, red(k, v)) for k, v in hdrs.items()),
                   body_keys=sorted(req), enc=enc, model=req.get("model"), store=req.get("store"),
                   stream=req.get("stream"), instructions_len=len(req.get("instructions") or ""),
                   include=req.get("include"), tool_choice=req.get("tool_choice"),
                   parallel_tool_calls=req.get("parallel_tool_calls"),
                   reasoning=req.get("reasoning"), prompt_cache_key=bool(req.get("prompt_cache_key")),
                   tools=[(t.get("type"), t.get("name")) for t in tools if isinstance(t, dict)],
                   input_types=[i.get("type", "message") for i in items])
        tok = hdrs.get("authorization", "")[7:].strip() if hdrs.get("authorization", "").lower().startswith("bearer ") else ""
        label, used = self.book.check(hdrs.get("chatgpt-account-id", ""), tok)
        if label is None:
            st, code, msg = used
            log.update(status=st, why=code or "unparseable")
            self.rec(**log)
            return self.reply(st, {"error": {"message": msg, "type": None, "code": code, "param": None}, "status": st})
        log.update(status=200, acct=label)
        text = last_user_text(items)
        m = re.search(r"SLOW (\d+)", text)
        if m:
            time.sleep(int(m.group(1)) / 1000.0)
        rid = "resp_" + secrets.token_hex(6)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        for k, v in (("x-codex-primary-used-percent", str(used)), ("x-codex-primary-window-minutes", "300"),
                     ("x-codex-primary-reset-at", str(int(time.time()) + 3600)),
                     ("x-codex-secondary-used-percent", str(used // 2)), ("x-codex-secondary-window-minutes", "10080"),
                     ("x-codex-secondary-reset-at", str(int(time.time()) + 86400 * 3)),
                     ("x-request-id", "req_" + secrets.token_hex(6)),
                     ("transfer-encoding", "chunked"), ("cache-control", "no-cache")):
            self.send_header(k, v)
        self.end_headers()
        sent = [0]

        def emit(ev):
            b = sse(ev)
            self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b)); self.wfile.flush(); sent[0] += 1

        emit({"type": "response.created", "response": {"id": rid, "status": "in_progress"}})
        out_items, final_text = self.script(text, items, tools, label)
        idx = 0
        for kind, payload in out_items:
            if kind == "text":
                iid = "msg_" + secrets.token_hex(4)
                emit({"type": "response.output_item.added", "output_index": idx,
                      "item": {"type": "message", "id": iid, "role": "assistant", "status": "in_progress", "content": []}})
                for piece in payload:
                    emit({"type": "response.output_text.delta", "item_id": iid, "output_index": idx,
                          "content_index": 0, "delta": piece})
                emit({"type": "response.output_item.done", "output_index": idx,
                      "item": {"type": "message", "id": iid, "role": "assistant", "status": "completed",
                               "content": [{"type": "output_text", "text": "".join(payload), "annotations": []}]}})
            else:
                emit({"type": "response.output_item.added", "output_index": idx, "item": dict(payload, status="in_progress")})
                emit({"type": "response.output_item.done", "output_index": idx, "item": payload})
            idx += 1
        emit({"type": "response.completed", "response": {
            "id": rid, "status": "completed",
            "usage": {"input_tokens": 1000 + 10 * len(items), "input_tokens_details": {"cached_tokens": 512},
                      "output_tokens": 7 + len(final_text), "output_tokens_details": {"reasoning_tokens": 3},
                      "total_tokens": 1007 + 10 * len(items) + len(final_text)}}})
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        log.update(events=sent[0], ms=int((time.time() - t0) * 1000), reply=final_text[:60])
        self.rec(**log)

    def script(self, text, items, tools, label):
        """-> ([("text", [deltas]) | ("item", item)], final text)"""
        outs = [i for i in items if i.get("type") in ("function_call_output", "custom_tool_call_output")]
        calls = [i for i in items if i.get("type") in ("function_call", "custom_tool_call")]
        code_mode = any(t.get("type") == "custom" and t.get("name") == "exec" for t in tools)
        patch = "*** Begin Patch\n*** Add File: sim-patched.txt\n+patched by the fake upstream\n*** End Patch\n"
        if "DO-TOOLS" in text and len(calls) - len(outs) <= 0 and code_mode and len(outs) < 2:
            if len(outs) == 0:
                js = ('const r = await tools.exec_command({cmd: "echo SIM-SHELL-OK $((6*7))"});\n'
                      'text(typeof r === "string" ? r : "exit=" + r.exit_code + " " + r.output);\n')
            else:
                js = "const r = await tools.apply_patch(%s);\ntext(\"apply_patch -> \" + JSON.stringify(r));\n" % json.dumps(patch)
            return [("item", code_mode_call(js))], ""
        if "DO-TOOLS" in text and len(calls) - len(outs) <= 0:
            if len(outs) == 0:
                name, _ = pick_shell(tools)
                if not name:
                    return [("text", ["no shell tool offered"])], "no shell tool offered"
                return [("item", {"type": "function_call", "id": "fc_" + secrets.token_hex(4),
                                  "call_id": "call_" + secrets.token_hex(6), "name": name,
                                  "arguments": json.dumps(shell_args(name, "echo SIM-SHELL-OK $((6*7))"))})], ""
            if len(outs) == 1:
                ap = next((t for t in tools if isinstance(t, dict) and t.get("name") == "apply_patch"), None)
                if ap and ap.get("type") == "custom":
                    return [("item", {"type": "custom_tool_call", "id": "ctc_" + secrets.token_hex(4),
                                      "call_id": "call_" + secrets.token_hex(6), "name": "apply_patch", "input": patch})], ""
                if ap:
                    return [("item", {"type": "function_call", "id": "fc_" + secrets.token_hex(4),
                                      "call_id": "call_" + secrets.token_hex(6), "name": "apply_patch",
                                      "arguments": json.dumps({"input": patch})})], ""
                name, _ = pick_shell(tools)   # no apply_patch tool: write it through the shell instead
                return [("item", {"type": "function_call", "id": "fc_" + secrets.token_hex(4),
                                  "call_id": "call_" + secrets.token_hex(6), "name": name,
                                  "arguments": json.dumps(shell_args(name, "printf 'patched by the fake upstream\\n' > sim-patched.txt"))})], ""
            def show(o):
                v = o.get("output")
                if isinstance(v, list):   # code mode answers [{type: input_text, text}, …]
                    v = " ".join(p.get("text", "") for p in v if isinstance(p, dict))
                v = v if isinstance(v, str) else json.dumps(v)
                v = " ".join(v.split())
                return v[v.find("Output:") + 8:][:90] if "Output:" in v else v[:90]
            t = "TOOLS-DONE shell=[%s] patch=[%s]" % (show(outs[0]), show(outs[1]))
            return [("text", [t])], t
        m = re.search(r"STREAM (\d+)", text)
        if m:
            n = min(int(m.group(1)), 20000)
            pieces = ["w%d " % i for i in range(n)] + ["END-%d" % n]
            return [("text", pieces)], "".join(pieces)
        if "Reply with exactly: PONG" in text:
            return [("text", ["PO", "NG"])], "PONG"
        k = sum(1 for i in items if i.get("type", "message") == "message" and i.get("role") == "user"
                and not last_user_text([i]).lstrip().startswith("<"))   # not Codex's <environment_context>
        t = "SIM turn %d acct=%s: %s" % (k, label, " ".join(text.split())[:40])
        return [("text", [t[:10], t[10:]])], t


def write_auth(home, at, it, aid):
    """Same shape the node agent writes for a leased Codex home (node_creds.go writeCodexAuth)."""
    os.makedirs(home, mode=0o700, exist_ok=True)
    d = {"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
         "tokens": {"id_token": it, "access_token": at, "refresh_token": "hub-managed", "account_id": aid},
         "last_refresh": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    p = os.path.join(home, "auth.json"); tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, json.dumps(d, indent=2).encode()); os.close(fd); os.replace(tmp, p)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--state", required=True); s.add_argument("--port", type=int, default=18788)
    s.add_argument("--max-seconds", type=int, default=900, help="exit on its own after this (no leak)")
    for name in ("seed", "refresh"):
        p = sub.add_parser(name)
        p.add_argument("--state", required=True); p.add_argument("--homes", required=True)
        p.add_argument("accounts", nargs="+")
        p.add_argument("--port", type=int, default=18788)
    a = ap.parse_args()
    os.makedirs(a.state, mode=0o700, exist_ok=True)
    book = Book(a.state)
    if a.cmd == "seed":
        for label in a.accounts:
            at, it, _ = book.add(label)
            write_auth(os.path.join(a.homes, label), at, it, acct_id(label))
            print("seeded %s (account id %s)" % (label, acct_id(label)))
    elif a.cmd == "refresh":
        import urllib.request
        for label in a.accounts:
            rt = book.load()[acct_id(label)]["refresh"]     # the vault's copy — never in the session
            body = json.dumps({"client_id": CLIENT_ID, "grant_type": "refresh_token", "refresh_token": rt,
                               "scope": "openid profile email"}).encode()
            r = urllib.request.urlopen(urllib.request.Request(
                "http://127.0.0.1:%d/oauth/token" % a.port, data=body,
                headers={"content-type": "application/json"}), timeout=10)
            out = json.load(r)
            write_auth(os.path.join(a.homes, label), out["access_token"], out["id_token"], acct_id(label))
            print("refreshed %s: new access token written, old one now revoked upstream" % label)
    else:
        H.book, H.state = book, a.state
        signal.signal(signal.SIGALRM, lambda *_: os._exit(0)); signal.alarm(a.max_seconds)
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
        srv.daemon_threads = True
        sys.stderr.write("fake_chatgpt listening on 127.0.0.1:%d (exits in %ds)\n" % (a.port, a.max_seconds))
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
