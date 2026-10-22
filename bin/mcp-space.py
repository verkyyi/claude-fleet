#!/usr/bin/env python3
"""mcp-space.py — a trial session's `space` (活页 / LivePage) MCP server, as a
stdio bridge to this machine's credential proxy (task XA4R, 试用网页直接在微信打开).

    python3 mcp-space.py --base http://127.0.0.1:<port> --cred-env <NAME>

The session holds only its own session credential (the variable NAME names —
CLAUDE_CODE_OAUTH_TOKEN for Claude, FLEET_CODEX_SESSION_CRED for Codex — read
from the environment, never an argument). Every call goes to <base>/space/mcp
with it; the proxy swaps it for the person's 活页 key, which only the hub and
the proxy's memory ever hold.

The account is opened the first time a TOOL is called, never at start: the
handshake (initialize, tools/list) is answered here from the list below, so a
trial that never publishes leaves no empty 活页 account. The list is the
publishing subset a trial needs; a trial's page never goes public
(set_visibility public / set_indexable are refused here as well as by 活页).

The proxy's refusals become a tool error the agent can act on: not connected
(show_page unavailable), the account not open yet (show_page account — retried
later), the trial over. The first call that opened the account carries one more
line telling the agent so (show_page account_new). No credential is ever
printed: stderr says what failed, never with what.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

PROTO = "2025-06-18"

S = lambda d="": {"type": "string", "description": d} if d else {"type": "string"}
I = {"type": "integer"}
B = {"type": "boolean"}


def obj(props, req=()):
    return {"type": "object", "properties": props, "required": list(req)}


# The publishing subset (names and arguments are 活页's own; the descriptions
# are short on purpose — 活页 answers in full when a tool is called).
TOOLS = [
    {"name": "create_folder", "description": "Create a folder to keep this conversation's pages together. Returns folder_id.",
     "inputSchema": obj({"name": S(), "intro": S()}, ["name"])},
    {"name": "list_proposals", "description": "List the person's pages (title, proposal_id, current_version_id, URL, visibility).",
     "inputSchema": obj({"folder_id": S("a folder, or omit for all"), "query": S("search titles")})},
    {"name": "publish_file", "description": "Publish an HTML or Markdown page as a WeChat-ready 活页 link. New page: title (+ folder_id); "
     "a new version of an existing page: proposal_id. One file: filename + content; several: files [{path, content}]. "
     "Text only, 2 MB in total. Private (only the person) unless they choose otherwise. Returns proposal_id, version, url and status.",
     "inputSchema": obj({"title": S(), "proposal_id": S(), "folder_id": S(), "filename": S(), "content": S(),
                         "files": {"type": "array", "items": obj({"path": S(), "content": S(), "url": S()}, ["path"])},
                         "note": S("what changed, ≤ 20 characters"), "hold": B, "quiet": B, "manifest": {"type": "object"}})},
    {"name": "get_version", "description": "A version's status (converting, review, published …), page count and files.",
     "inputSchema": obj({"version_id": S()}, ["version_id"])},
    {"name": "list_versions", "description": "A page's versions, newest first.",
     "inputSchema": obj({"proposal_id": S()}, ["proposal_id"])},
    {"name": "read_version", "description": "Read back a version's rendered body (the entry file, or one text file).",
     "inputSchema": obj({"version_id": S(), "file": S()}, ["version_id"])},
    {"name": "preview_version", "description": "A 60-minute preview link of a version; with embed_origin also embed.url and its expires_at "
     "(show_page embed_url / embed_expires).",
     "inputSchema": obj({"version_id": S(), "embed_origin": S(), "audience": S(), "page": I})},
    {"name": "publish_version", "description": "Make an approved version that waits to publish live.",
     "inputSchema": obj({"version_id": S(), "note": S(), "quiet": B}, ["version_id"])},
    {"name": "push_to_wechat", "description": "Send the page's live version to the person's own WeChat (to: self). "
     "Call it once a page is ready: the person opens it in WeChat, nobody else can.",
     "inputSchema": obj({"proposal_id": S(), "to": {"type": "string", "enum": ["self"]}, "force": B}, ["proposal_id"])},
    {"name": "set_visibility", "description": "Let others open a page — ONLY after the person said yes: passcode (recommended; give them the "
     "passcode it returns) or private again. A trial page is never public.",
     "inputSchema": obj({"proposal_id": S(), "visibility": {"type": "string", "enum": ["private", "passcode"]},
                         "passcode": S("4–16 letters or digits; omit to generate")}, ["proposal_id", "visibility"])},
]
NAMES = {t["name"] for t in TOOLS}

WORDS = {
    "not": "这台机器没有为他连活页（{m}）。网页文件留在对话里；show_page 用 status unavailable，并告诉他。",
    "later": "活页账号还没开好（{m}），稍后自动再试，网页文件留在对话里不会丢。show_page 用 status account，note 写一句原因；"
             "他说「重试」时再发一次。",
    "ended": "试用已结束，活页钥匙已收回，不能再发布。他的网页在活页里保留 30 天、仍只他本人能看；申请转正后接着用。"
             "show_page 用 status unavailable，并这样告诉他。",
    "new": "（fleet）这是第一次：刚用他的微信为他开好了活页账号。调 show_page 时带 account_new: true，页面上会说一次。",
}


def say(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def result(rid, res):
    say({"jsonrpc": "2.0", "id": rid, "result": res})


def tool_error(rid, text):
    result(rid, {"content": [{"type": "text", "text": text}], "isError": True})


class Upstream:
    """One MCP session with 活页, through the proxy, opened at the first call."""

    def __init__(self, base, cred):
        self.url = base.rstrip("/") + "/space/mcp"
        self.cred = cred
        self.sid = ""
        self.n = 0
        self.new = False

    def post(self, msg):
        """-> (status, headers, list of JSON-RPC messages | refusal dict)."""
        h = {"Authorization": "Bearer " + self.cred, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": PROTO}
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(self.url, data=json.dumps(msg).encode(), headers=h, method="POST")
        try:
            r = urllib.request.urlopen(req, timeout=180)
        except urllib.error.HTTPError as e:
            try:
                return e.code, e.headers, json.loads(e.read() or b"{}")
            except ValueError:
                return e.code, e.headers, {}
        with r:
            raw = r.read().decode("utf-8", "replace")
            ctype = r.headers.get("Content-Type", "")
            out = []
            if "text/event-stream" in ctype:
                for line in raw.splitlines():
                    if line.startswith("data:"):
                        try:
                            out.append(json.loads(line[5:].strip()))
                        except ValueError:
                            pass
            elif raw.strip():
                v = json.loads(raw)
                out = v if isinstance(v, list) else [v]
            return r.status, r.headers, out

    def open(self):
        """-> None, or (status, refusal) when the proxy said no."""
        if self.sid:
            return None
        self.n += 1
        st, hd, out = self.post({"jsonrpc": "2.0", "id": "init-%d" % self.n, "method": "initialize",
                                 "params": {"protocolVersion": PROTO, "capabilities": {},
                                            "clientInfo": {"name": "fleet-mcp-space", "version": "1"}}})
        if st != 200:
            return st, out if isinstance(out, dict) else {}
        self.sid = hd.get("Mcp-Session-Id", "") or "-"
        self.new = hd.get("X-Fleet-Space-New") == "1"
        if self.sid == "-":
            self.sid = ""
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return None


def refusal(st, a):
    code = (a or {}).get("code", "") if isinstance(a, dict) else ""
    err = (a or {}).get("error") if isinstance(a, dict) else None
    if not code and isinstance(err, dict):
        code = err.get("code", "")
    m = (a or {}).get("message", "") if isinstance(a, dict) else ""
    if code == "ended":
        return WORDS["ended"]
    if code in ("off", "not_trial", "no_wechat") or st == 401:
        return WORDS["not"].format(m=m or code or "HTTP %d" % st)
    return WORDS["later"].format(m=m or code or "HTTP %d" % st)


def call(up, rid, params):
    name = str((params or {}).get("name", ""))
    args = (params or {}).get("arguments") or {}
    if name not in NAMES:
        return tool_error(rid, "unknown tool %s" % name)
    if name == "set_visibility" and args.get("visibility") not in ("private", "passcode"):
        return tool_error(rid, "试用的网页不能设公开：只能凭口令（passcode）或保持私密。")
    first = not up.sid
    no = up.open()
    if no:
        return tool_error(rid, refusal(*no))
    st, _, out = up.post({"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": name, "arguments": args}})
    if st == 404 and up.sid:
        up.sid = ""                      # 活页 forgot the session: once more
        no = up.open()
        if no:
            return tool_error(rid, refusal(*no))
        st, _, out = up.post({"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": name, "arguments": args}})
    if st != 200 or not isinstance(out, list):
        return tool_error(rid, refusal(st, out if isinstance(out, dict) else {}))
    msg = next((m for m in out if isinstance(m, dict) and m.get("id") == rid), None)
    if msg is None:
        return tool_error(rid, WORDS["later"].format(m="活页 answered nothing"))
    if "error" in msg:
        return say({"jsonrpc": "2.0", "id": rid, "error": msg["error"]})
    res = msg.get("result") or {}
    if first and up.new:
        res = dict(res)
        res["content"] = list(res.get("content") or []) + [{"type": "text", "text": WORDS["new"]}]
    return result(rid, res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="the credential proxy, http://127.0.0.1:<port>")
    ap.add_argument("--cred-env", required=True, help="the variable holding the session's own credential")
    a = ap.parse_args()
    cred = os.environ.get(a.cred_env, "")
    up = Upstream(a.base, cred)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except ValueError:
            continue
        rid, meth, params = m.get("id"), m.get("method", ""), m.get("params") or {}
        if rid is None:
            continue                     # a notification: nothing to answer
        if meth == "initialize":
            result(rid, {"protocolVersion": params.get("protocolVersion") or PROTO, "capabilities": {"tools": {}},
                         "serverInfo": {"name": "space", "version": "1"},
                         "instructions": "活页 (LivePage): publish the person's web pages; private to them by default."})
        elif meth == "ping":
            result(rid, {})
        elif meth == "tools/list":
            result(rid, {"tools": TOOLS})
        elif meth in ("resources/list", "prompts/list", "resources/templates/list"):
            result(rid, {{"resources/list": "resources", "prompts/list": "prompts"}.get(meth, "resourceTemplates"): []})
        elif meth == "tools/call":
            if not cred:
                tool_error(rid, WORDS["not"].format(m="no session credential"))
                continue
            try:
                call(up, rid, params)
            except Exception as e:      # never the credential: only what kind of failure
                sys.stderr.write("mcp-space: %s\n" % type(e).__name__)
                tool_error(rid, WORDS["later"].format(m=type(e).__name__))
        else:
            say({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})


if __name__ == "__main__":
    main()
