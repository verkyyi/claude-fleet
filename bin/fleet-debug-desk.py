#!/usr/bin/env python3
"""fleet-debug-desk.py — the node's half of the hub's debug reports (issue #2893,
EPIC #2889 C4): what the debugger session's three fleet tools run, and the feed
the orchestrator's steward beat reads.

  fetch <id>                 the report's bundle + the hub's hub.json, unpacked into
                             $TMPDIR/fleet-debug/<id>/ (bundle/ and hub.json); prints
                             the directory, then the bundle's file list
  publish <id> <file|->      the four sections (JSON: cause, evidence[], steps[{why,
                             cmd, system?}], ours[]) → the hub renders the page;
                             checked here first by the same rules (the hub checks again)
  propose <id> <text>        one thing to change on our side, for the person to nod at
  feed [--since T] [--json]  what changed in the reports after T (the cursor kept in
                             $FLEET_CONF_DIR/global/debug-feed.json when no --since);
                             one line per report for the orchestrator — the steward's
                             beat sends them (fleet_steward.py debug_step)

Every call is AS this login's node (node.env's token, read here, never exported;
a separated login through its credential proxy's broker — fleet-agent-team.py's
node_auth). The hub answers a report only to the login it was sent to, and the
feed only to the orchestrator's (CCQUOTA_FLEET_DEBUG_NOTIFY).

Exit: 0 · 2 usage / the result does not fit the page · 3 no hub or no node token
here · 4 the hub refused (its words on stderr) · 1 the hub did not answer.
Seam: FLEET_DEBUG_DESK_HUB_CMD — a command that gets `<method> <path>` (+ the
body on stdin) and prints `<status>\\n<body>`, instead of the hub.
"""
import importlib.util
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONF_DIR = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
ID_RE = re.compile(r"^[a-z2-7]{8}$")
SHAPES = os.path.join(ROOT, "conf", "secret-shapes.list")


def _team():
    spec = importlib.util.spec_from_file_location("fleet_agent_team", os.path.join(HERE, "fleet-agent-team.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Refused(Exception):
    pass


class NoHub(Exception):
    pass


def hub(method, path, body=None, ctype="application/json", timeout=60):
    """(status, bytes) of one call as this node."""
    seam = os.environ.get("FLEET_DEBUG_DESK_HUB_CMD")
    if seam:
        r = subprocess.run(shlex.split(seam) + [method, path], input=body or b"",
                           stdout=subprocess.PIPE, timeout=timeout)
        head, _, rest = r.stdout.partition(b"\n")
        return int(head.strip() or b"0"), rest
    team = _team()
    url, tok = team.node_auth(team.hub_url(""))
    if not url:
        raise NoHub("no hub configured here")
    if not tok:
        raise NoHub("no node token here (node.env missing)")
    req = urllib.request.Request(url + path, data=body, method=method)
    req.add_header("Authorization", "Bearer " + tok)
    if body is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def need(status, body):
    if status == 0:
        raise OSError("the hub did not answer")
    if status >= 300:
        raise Refused("hub %d: %s" % (status, body.decode("utf-8", "replace").strip()[:400]))
    return body


def check_id(i):
    if not ID_RE.match(i or ""):
        raise ValueError("a report id is 8 letters a-z, 2-7: %r" % i)
    return i


# ── fetch ────────────────────────────────────────────────────────────────

def cmd_fetch(rid):
    rid = check_id(rid)
    data = need(*hub("GET", "/v1/node/debug/%s/bundle" % rid, timeout=120))
    hubj = need(*hub("GET", "/v1/node/debug/%s/hub.json" % rid))
    base = os.path.join(os.environ.get("TMPDIR") or tempfile.gettempdir(), "fleet-debug")
    os.makedirs(base, mode=0o700, exist_ok=True)
    dst = os.path.join(base, rid)
    if os.path.isdir(dst):
        for top, dirs, files in os.walk(dst, topdown=False):
            for f in files:
                os.unlink(os.path.join(top, f))
            for d in dirs:
                os.rmdir(os.path.join(top, d))
    os.makedirs(os.path.join(dst, "bundle"), mode=0o700, exist_ok=True)
    names = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        for m in tf.getmembers():
            n = m.name[2:] if m.name.startswith("./") else m.name
            if not m.isfile():
                continue                       # directories are made below; nothing else is ever written
            if n.startswith("/") or ".." in n.split("/"):
                raise Refused("the bundle names a path outside itself: %s" % n)
            out = os.path.join(dst, "bundle", n)
            os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
            with tf.extractfile(m) as src, open(out, "wb") as f:
                f.write(src.read())
            names.append(n)
    with open(os.path.join(dst, "hub.json"), "wb") as f:
        f.write(hubj)
    print(dst)
    print("  hub.json   (入口这边：票、中转、登录、placement)")
    for n in sorted(names):
        print("  bundle/" + n)
    return 0


# ── publish / propose ────────────────────────────────────────────────────

def load_shapes():
    out = []
    try:
        with open(SHAPES, encoding="utf-8") as f:
            for ln in f:
                ln = ln.rstrip("\n")
                if not ln or ln.startswith("#") or "\t" not in ln:
                    continue
                name, pat = ln.split("\t", 1)
                try:
                    out.append((name, re.compile(pat)))
                except re.error:
                    pass
    except OSError:
        pass
    return out


def shape_hit(shapes, text):
    for name, rx in shapes:
        if rx.search(text or ""):
            return name
    return ""


def check_result(res, shapes):
    """What keeps a result off the page — the hub's debugResult.check, said here
    first so the debugger fixes it before it is sent."""
    bad = []
    if not isinstance(res, dict):
        return ["the result is a JSON object {cause, evidence, steps, ours}"]
    extra = set(res) - {"cause", "evidence", "steps", "ours"}
    if extra:
        bad.append("unknown keys: " + ", ".join(sorted(extra)))
    cause = res.get("cause")
    if not isinstance(cause, str) or not cause.strip():
        bad.append("缺「是什么问题」（cause）")
    ev = res.get("evidence")
    if not isinstance(ev, list) or not ev or not all(isinstance(e, str) and e.strip() for e in ev):
        bad.append("缺「证据」（evidence，至少一条）")
    elif len(ev) > 8:
        bad.append("「证据」超过 8 条")
    steps = res.get("steps")
    if not isinstance(steps, list) or not steps:
        bad.append("缺「请你做」（steps，1–3 步）")
    elif len(steps) > 3:
        bad.append("「请你做」有 %d 步，最多 3 步" % len(steps))
    else:
        for i, st in enumerate(steps, 1):
            if not isinstance(st, dict) or not str(st.get("why", "")).strip() or not str(st.get("cmd", "")).strip():
                bad.append("第 %d 步要有 why 和 cmd" % i)
            elif "\n" in st["cmd"].strip() or "\r" in st["cmd"]:
                bad.append("第 %d 步的命令要是一行" % i)
    ours = res.get("ours")
    if not isinstance(ours, list) or not all(isinstance(o, str) for o in ours):
        bad.append("缺「要我们改的」（ours，没有就给 []）")
    texts = [("cause", cause)] + [("evidence[%d]" % i, e) for i, e in enumerate(ev if isinstance(ev, list) else [])]
    for i, st in enumerate(steps if isinstance(steps, list) else []):
        if isinstance(st, dict):
            texts += [("steps[%d].why" % i, st.get("why")), ("steps[%d].cmd" % i, st.get("cmd"))]
    texts += [("ours[%d]" % i, o) for i, o in enumerate(ours if isinstance(ours, list) else [])]
    for k, t in texts:
        hit = shape_hit(shapes, t if isinstance(t, str) else "")
        if hit:
            bad.append("%s 里有像 %s 的东西（命令和结论不得含凭据）" % (k, hit))
    return bad


def cmd_publish(rid, src):
    rid = check_id(rid)
    raw = sys.stdin.read() if src == "-" else (open(src, encoding="utf-8").read() if os.path.isfile(src) else src)
    try:
        res = json.loads(raw)
    except ValueError as e:
        print("fleet-debug-desk: the result is not JSON: %s" % e, file=sys.stderr)
        return 2
    bad = check_result(res, load_shapes())
    if bad:
        print("fleet-debug-desk: not sent — " + "；".join(bad), file=sys.stderr)
        return 2
    out = json.loads(need(*hub("POST", "/v1/node/debug/%s/page" % rid, json.dumps(res, ensure_ascii=False).encode())))
    print("已出结论 · %s" % out.get("url", ""))
    return 0


def cmd_propose(rid, text):
    rid = check_id(rid)
    text = " ".join((text or "").split())
    if not text:
        print("fleet-debug-desk: propose needs the one thing to change", file=sys.stderr)
        return 2
    hit = shape_hit(load_shapes(), text)
    if hit:
        print("fleet-debug-desk: not sent — the text holds something shaped like %s" % hit, file=sys.stderr)
        return 2
    need(*hub("POST", "/v1/node/debug/%s/propose" % rid, json.dumps({"text": text}, ensure_ascii=False).encode()))
    print("交给编排会话了（点头才立单）：%s" % text)
    return 0


# ── feed ─────────────────────────────────────────────────────────────────

FEED = os.path.join(CONF_DIR, "global", "debug-feed.json")


def feed_line(r):
    """One report, as the orchestrator reads it."""
    head = "〔诊断〕%s · " % (r.get("who") or "?")
    st = r.get("state")
    if st == "concluded":
        line = head + (r.get("cause") or "已出结论") + " · " + r.get("url", "")
    elif st == "unfinished":
        line = head + "没看完（%s）· %s" % (r.get("why") or "?", r.get("url", ""))
    elif st == "queued":
        line = head + "排队等你点头（%s）· 点头：POST /v1/fleet/debug/%s/start · %s" % (
            r.get("why") or "今天的诊断次数满了", r.get("id"), r.get("url", ""))
    else:
        return ""
    ours = r.get("ours") or []
    if ours:
        line += "\n  要我们改的（你点头才立单，file_issue）：" + "；".join(ours)
    return line


def cmd_feed(since, as_json):
    st = {}
    try:
        with open(FEED) as f:
            st = json.load(f)
    except (OSError, ValueError):
        pass
    after = since if since is not None else st.get("after", "")
    path = "/v1/node/debug/feed" + ("?after=" + urllib.parse.quote(after) if after else "")
    rows = json.loads(need(*hub("GET", path))).get("reports") or []
    told = st.get("told") or {}
    lines = []
    for r in rows:
        # one line per (report, state, proposals): a report seen again unchanged says nothing
        mark = "%s|%d" % (r.get("state"), len(r.get("ours") or []))
        if told.get(r.get("id")) == mark:
            continue
        ln = feed_line(r)
        if ln:
            lines.append(ln)
        told[r.get("id")] = mark
        after = r.get("updated_at") or after
    if since is None:
        os.makedirs(os.path.dirname(FEED), exist_ok=True)
        keep = [k for k in told if k][-500:]    # a report lives 7 days; 500 is weeks of them
        st = {"after": after, "at": int(time.time()), "told": {k: told[k] for k in keep}}
        tmp = FEED + ".%d.tmp" % os.getpid()
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, FEED)
    if as_json:
        print(json.dumps({"lines": lines, "after": after}, ensure_ascii=False))
    else:
        for ln in lines:
            print(ln)
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "fetch" and len(rest) == 1:
            return cmd_fetch(rest[0])
        if cmd == "publish" and len(rest) == 2:
            return cmd_publish(rest[0], rest[1])
        if cmd == "propose" and len(rest) >= 2:
            return cmd_propose(rest[0], " ".join(rest[1:]))
        if cmd == "feed":
            since, as_json, i = None, False, 0
            while i < len(rest):
                if rest[i] == "--since" and i + 1 < len(rest):
                    since, i = rest[i + 1], i + 2
                elif rest[i] == "--json":
                    as_json, i = True, i + 1
                else:
                    raise ValueError("feed takes --since T and --json")
            return cmd_feed(since, as_json)
        raise ValueError("usage: fetch <id> · publish <id> <file|-> · propose <id> <text> · feed [--since T] [--json]")
    except ValueError as e:
        print("fleet-debug-desk: %s" % e, file=sys.stderr)
        return 2
    except NoHub as e:
        print("fleet-debug-desk: %s" % e, file=sys.stderr)
        return 3
    except Refused as e:
        print("fleet-debug-desk: %s" % e, file=sys.stderr)
        return 4
    except (OSError, tarfile.TarError, subprocess.SubprocessError) as e:
        print("fleet-debug-desk: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
