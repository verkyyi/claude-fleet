#!/usr/bin/env python3
"""fleet config — see and change your own Agent configuration in one command.

Issue #1860 (EPIC #1855 C5). Every item an agent gets — an MCP server, a
setting, a hook, a skill — comes from one of four places, highest first:
fleet (a locked item) > 本机 (this login's own files) > 个人 (your personal
layer on the hub, #1856) > 团队 (the team layer, #1726) > fleet (the default).
This command reads that picture and writes the personal layer; the composing
itself stays in fleet-agent-team.py, which it imports — no second set of rules.

  show [--json] [ITEM]
        one row per item: 项 · 值摘要 · 来源 (fleet / 团队 / 个人 / 本机) · 锁.
        Composed NOW (fleet-agent-team.py's Session, per agent) plus what
        agent-effective.json records and what only this login has. ITEM is a
        path prefix (`claude.mcp.`, `codex.model_reasoning_effort`). --json rows
        are agent-effective.json's rows (`source` in default|team|personal|local)
        plus `value` and `locked`. Never needs the hub.
  add|set --personal KIND NAME [VALUE | --file F]
  rm      --personal KIND NAME
        read your personal layer, change one item, PUT it back with base = the
        version read (a 409 — it changed meanwhile — re-reads and retries once),
        then sync this computer. KIND: mcp · settings (claude_settings) · codex
        (codex_config) · skills · hooks (NAME = Event; VALUE {matcher?, command,
        timeout?}; rm takes Event.<key> as show prints it, or Event + the command)
        · hook_scripts. VALUE is JSON, or a plain string; --file F reads it (a
        skill's SKILL.md, a hook program).
  promote ITEM [--yes]
        copy this computer's value of ITEM (a `show` path: claude.mcp.X,
        codex.mcp.X, claude.settings.K, codex.K, claude.skills.N,
        claude.hooks.Event.key) into your personal layer. The local file is not
        touched, so here 本机 still wins; every other machine gets it on its next
        sync. A value that names this computer (an absolute path under $HOME,
        this login's user name) asks for --yes first; a credential is refused,
        naming the field, with the ${VAR} spelling to use instead.
  history | restore N
        your personal layer's versions / a rollback (version N's body as a new
        version). The operator, with CCQUOTA_VIEWER_TOKEN and --person ID, may
        read anyone's history and restore anyone to one of THEIR OWN versions.
  --team  on add|set|rm|history|restore: the same on the team layer, through
        fleet-agent-team.py put/restore/history — the operator's only.

Credentials, as the team fetch: the node token ($FLEET_CONF_DIR/node.env, read,
never exported) as Bearer, else the connection certificate (~/.ssh/fleet-cert,
signed under fleet-person@claude-fleet). The seam FLEET_PERSON_HUB_CMD replaces
the hub: run as `bash -c "$FLEET_PERSON_HUB_CMD" - METHOD QUERY` with the request
JSON on stdin, it prints {"status": N, …response}. No local state is added.

Exit: 0 ok · 1 the hub refused / did not answer · 2 usage / refused here ·
3 no hub (show still works) · 4 promote needs --yes.
"""
import argparse
import getpass
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PERSON_PATH = "/v1/fleet/person-bundle"
PERSON_SIG_NS = "fleet-person@claude-fleet"
KINDS = {"mcp": "mcp", "settings": "claude_settings", "claude_settings": "claude_settings",
         "codex": "codex_config", "codex_config": "codex_config", "skills": "skills", "skill": "skills",
         "hooks": "hooks", "hook": "hooks", "hook_scripts": "hook_scripts"}
WORD = {"default": "fleet", "team": "团队", "personal": "个人", "local": "本机"}


def load_team():
    spec = importlib.util.spec_from_file_location("fleet_agent_team", os.path.join(HERE, "fleet-agent-team.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = load_team()


def die(msg, code=2):
    print("fleet config · %s" % msg, file=sys.stderr)
    sys.exit(code)


def team_args(extra=()):
    """fleet-agent-team.py's own defaults — the same files, the same root."""
    return T.build_parser().parse_args(["status"] + list(extra))


# --- show ----------------------------------------------------------------------------

def summary(path, v):
    if v is None:
        return "-"
    if path.endswith(".hooks") and isinstance(v, list):
        return "%d 条 fleet 自动规则" % len(v)
    if isinstance(v, dict) and ("command" in v or "url" in v):
        if "url" in v and "command" not in v:
            s = str(v["url"])
        else:
            s = " ".join([str(v["command"])] + [str(x) for x in v.get("args") or []])
        if v.get("matcher"):
            s = "[%s] %s" % (v["matcher"], s)
    elif isinstance(v, str):
        s = v
        if "\n" in s:       # a skill: its description, else its first line
            m = re.search(r"^description:\s*(.+)$", s, re.M)
            s = m.group(1) if m else s.strip().splitlines()[0]
    else:
        s = json.dumps(v, ensure_ascii=False, sort_keys=True)
    s = " ".join(s.split())
    return s if len(s) <= 60 else s[:59] + "…"


def local_extras(a, rows):
    """What only this login has: MCP servers, skills, settings keys and hooks the
    fleet does not hand — the things `promote` takes."""
    out = {}
    cj = T.read_json_quiet(a.claude_config)
    for n, v in sorted(((cj or {}).get("mcpServers") or {}).items() if isinstance(cj, dict) else []):
        out["claude.mcp." + n] = v
    st = T.read_json_quiet(a.claude_settings)
    st = st if isinstance(st, dict) else {}
    for k, v in sorted(st.items()):
        if k != "hooks" and not any(p == "claude.settings." + k or p.startswith("claude.settings." + k + ".")
                                    for p in rows):
            out["claude.settings." + k] = v
    hm = T.load_mod("fleet_hooks_merge", "fleet-hooks-merge.py")
    fleet = {(r[0], r[1], hm.script_of(r[2])) for r in T.Session(a, "claude").hook_table()}
    for ev, groups in sorted((st.get("hooks") or {}).items()):
        for g in groups if isinstance(groups, list) else []:
            for h in (g or {}).get("hooks") or []:
                if not isinstance(h, dict) or not h.get("command"):
                    continue
                if (ev, g.get("matcher", "") or "", hm.script_of(h["command"])) in fleet:
                    continue
                v = {"command": h["command"]}
                if g.get("matcher"):
                    v["matcher"] = g["matcher"]
                if h.get("timeout") is not None:
                    v["timeout"] = h["timeout"]
                out["claude.hooks.%s.%s" % (ev, T.hook_key(h["command"]))] = v
    if a.claude_skills and os.path.isdir(a.claude_skills):
        for n in sorted(os.listdir(a.claude_skills)):
            t = T.skill_get(a.claude_skills, n)
            if t is not None:
                out["claude.skills." + n] = t
    home = os.path.abspath(os.path.expanduser(a.codex_home[0] if a.codex_home
                                              else os.environ.get("CODEX_HOME") or "~/.codex"))
    if os.path.isdir(home):
        ad = T.load_mod("fleet_agent_defaults", "fleet-agent-defaults.py")
        cc = T.CodexConf(ad, home)
        sc = cc.scan()
        if not sc.mcp_inline():
            names = {p[1] for p in sc.tables if len(p) >= 2 and p[0] == "mcp_servers"} \
                | {p[1] for p in sc.keys if len(p) >= 2 and p[0] == "mcp_servers"}
            for n in sorted(names):
                v = cc.get_server(n)
                if v is not None:
                    out["codex.mcp." + n] = v
        for p in sc.keys:
            if len(p) == 1:
                v = cc.get_top(p[0])
                if v is not None:
                    out["codex." + p[0]] = v
    return {p: v for p, v in out.items() if p not in rows}


def compose_rows(a):
    rows = {}
    for agent in ("claude", "codex"):
        s = T.Session(a, agent).compose()
        for p, r in s.rows.items():
            if p == "mod" and p in rows:
                continue
            rows[p] = {"source": r["source"], "locked": bool(r.get("locked")), "value": r["value"]}
    rec = T.read_json_quiet(T.EFFECTIVE)
    eff = (rec or {}).get("items") or {} if isinstance(rec, dict) else {}
    locked = T.locked_set(a.root)
    extras = local_extras(a, rows)
    for p, r in eff.items():
        canon = re.sub(r"^codex\[[^]]*\]", "codex", p)
        if canon in rows:
            continue
        row = {k: v for k, v in r.items() if k != "hash"}
        row["locked"] = T.is_locked(canon, locked)
        row["value"] = extras.pop(canon, None)
        if row["value"] is None and canon.startswith("claude.hooks.") and r.get("command"):
            row["value"] = {"command": r["command"]}
        rows[canon] = row
    for p, v in extras.items():
        rows[p] = {"source": "local", "locked": T.is_locked(p, locked), "value": v}
    return rows, rec if isinstance(rec, dict) else {}


def layer_versions(rec):
    t = (rec.get("team") or {})
    team = "off" if t.get("state") == "off" else ("v%s" % t["version"] if t.get("version") else "none")
    pv = rec.get("personal_version")
    p = rec.get("personal") if isinstance(rec.get("personal"), dict) else {}
    if p.get("state") == "off":
        personal = "off"
    elif pv or p.get("version"):
        personal = "v%s" % (pv or p.get("version"))
    else:
        personal = "none"
    return team, personal


def show(a):
    ta = team_args()
    rows, rec = compose_rows(ta)
    if a.args:
        pre = a.args[0]
        rows = {p: r for p, r in rows.items() if p == pre or p.startswith(pre.rstrip(".") + ".")}
        if not rows:
            die("没有这一项：%s（fleet config show 列出全部）" % pre)
    team, personal = layer_versions(rec)
    if a.json:
        print(json.dumps({"team": team, "personal": personal, "items": rows},
                         ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    print("团队 %s · 个人 %s" % (team, personal))
    w = max([len(p) for p in rows] + [4])
    for p in sorted(rows):
        r = rows[p]
        word = WORD.get(r["source"], r["source"])
        word += " " * max(0, 5 - sum(2 if ord(ch) > 0x2e80 else 1 for ch in word))
        print("%-*s  %s %s  %s" % (w, p, word, "锁" if r.get("locked") else "  ", summary(p, r.get("value"))))
    return 0


# --- the hub ---------------------------------------------------------------------------

def no_hub():
    die("没有入口 — 个人配置存在入口上，这台电脑没有配入口（FLEET_HUB_URL）；fleet config show 照常可用", 3)


def person_call(a, method, body=None, query=""):
    """(status, response dict). The seam, else the hub over HTTP."""
    if os.environ.get("FLEET_PERSON_HUB_CMD"):
        p = subprocess.run(["bash", "-c", os.environ["FLEET_PERSON_HUB_CMD"], "-", method, query],
                           input=json.dumps(body or {}).encode(), capture_output=True)
        try:
            resp = json.loads(p.stdout.decode() or "{}")
        except ValueError:
            resp = {"error": p.stdout.decode(errors="replace")[:200]}
        return int(resp.pop("status", 0 if p.returncode else 200)), resp
    url = T.hub_url(a.hub)
    if not url:
        no_hub()
    hdr = {"Accept": "application/json", "Content-Type": "application/json"}
    viewer = os.environ.get("CCQUOTA_VIEWER_TOKEN") or ""
    if a.person:
        if not viewer:
            die("--person 是操作者的用法：要 CCQUOTA_VIEWER_TOKEN 在环境里")
        q = "principal=%s" % a.person
        query = "%s&%s" % (query, q) if query else q
        code, raw = T.http(url + PERSON_PATH + ("?" + query if query else ""), method,
                           dict(hdr, Authorization="Bearer " + viewer),
                           json.dumps(body).encode() if body is not None else None, a.timeout)
        return code, decode(raw)
    full = url + PERSON_PATH + ("?" + query if query else "")
    tok = T.env_file_val(os.path.join(T.CONF_DIR, "node.env"), "CCQUOTA_TOKEN")
    code, raw = 0, b""
    if tok:
        code, raw = T.http(full, method, dict(hdr, Authorization="Bearer " + tok),
                           json.dumps(body).encode() if body is not None else None, a.timeout)
    if code in (0, 401) or not tok:
        proof = cert_proof()
        if proof:
            code, raw = T.http(full, "POST" if method == "GET" else method, hdr,
                               json.dumps(dict(body or {}, **proof)).encode(), a.timeout)
        elif not tok:
            die("没有节点 token，也没有连接证书（fleet login）— 读写不了个人配置", 1)
    return code, decode(raw)


def cert_proof():
    key = os.environ.get("FLEET_CERT") or os.path.join(os.path.expanduser("~"), ".ssh", "fleet-cert")
    cert = key + "-cert.pub"
    if not (os.path.exists(key) and os.path.exists(cert)):
        return None
    ts = int(time.time())
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", PERSON_SIG_NS],
                             input=("fleet-person %d" % ts).encode(), capture_output=True, check=True).stdout.decode()
        with open(cert) as f:
            line = f.readline().strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return {"cert": line, "sig": sig, "ts": ts}


def decode(raw):
    try:
        d = json.loads(raw.decode() if isinstance(raw, bytes) else raw)
        return d if isinstance(d, dict) else {"error": str(d)}
    except ValueError:
        return {"error": (raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)).strip()[:200]}


def hub_err(code, resp):
    msg = resp.get("error") or resp
    if code == 404 and "no person" in str(msg):
        die("这个登录没有绑定到人 — 没有个人配置（入口：%s）" % msg, 1)
    if code == 422:
        die("入口拒收：%s" % credential_hint(str(msg)), 1)
    die("入口回答 %s：%s" % (code or "无响应", msg), 1)


def credential_hint(why):
    m = re.search(r"(bundle\.[^\s]+) looks like a credential", why)
    if not m:
        return why
    field = m.group(1)
    leaf = re.split(r"[.\[\]]", field.rstrip("]"))[-1] or "SECRET"
    var = re.sub(r"[^A-Za-z0-9_]", "_", leaf).upper()
    if not re.match(r"[A-Z_]", var):
        var = "_" + var
    return "%s 像密钥 — 配置里从不放密钥；改成 \"${%s}\"，值放在你自己登录的环境里" % (field, var)


def validate(b):
    v = getattr(T, "validate_person", None)
    if v:
        return v(b)
    if "hook_scripts" in b:          # C4's key, until the client learns it
        b = {k: x for k, x in b.items() if k != "hook_scripts"}
    return T.validate(b)


def sync_here(a):
    if os.environ.get("FLEET_CONFIG_NO_SYNC") == "1":
        return
    p = subprocess.run([sys.executable, os.path.join(HERE, "fleet-agent-team.py"), "sync", "--force"],
                       capture_output=True, text=True)
    last = (p.stdout.strip().splitlines() or [""])[-1]
    if last:
        print("本机已同步：%s" % last)


# --- edits -----------------------------------------------------------------------------

def parse_value(a, raw):
    if a.file:
        try:
            with open(a.file, encoding="utf-8") as f:
                txt = f.read()
        except OSError as e:
            die("读不了 %s：%s" % (a.file, e))
        return txt
    if raw is None:
        die("要一个值（JSON 或字符串），或 --file F")
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def mutate(bundle, kind, name, value, op):
    """Change one item in place; returns a line for the person."""
    sec = bundle.setdefault(kind, {})
    if kind == "hooks":
        if op == "rm":
            ev, _, key = name.partition(".")
            lst = sec.get(ev) or []
            keep = [h for h in lst if not (T.hook_key(h.get("command", "")) == key
                                           or (value is not None and h.get("command") == value))]
            if len(keep) == len(lst):
                die("个人配置里没有这条自动规则：%s" % name)
            if keep:
                sec[ev] = keep
            else:
                sec.pop(ev, None)
        else:
            if isinstance(value, str):
                value = {"command": value}
            if not isinstance(value, dict) or not value.get("command"):
                die("自动规则的值是 {matcher?, command, timeout?}")
            lst = [h for h in sec.get(name) or [] if h.get("command") != value["command"]]
            sec[name] = lst + [value]
    elif op == "rm":
        if name not in sec:
            die("个人配置里没有 %s.%s" % (kind, name))
        sec.pop(name)
    else:
        if op == "add" and name in sec and sec[name] != value:
            die("个人配置里已有 %s.%s — 改它用 set" % (kind, name))
        sec[name] = value
    if not sec:
        bundle.pop(kind, None)


def put_personal(a, change, note):
    """GET → change → PUT base; a 409 re-reads and retries once."""
    for attempt in (1, 2):
        code, cur = person_call(a, "GET")
        if code != 200:
            hub_err(code, cur)
        bundle = json.loads(json.dumps(cur.get("bundle") or {}))
        base = int(cur.get("version") or 0)
        change(bundle)
        why = validate(bundle)
        if why:
            die("拒收，没发出去：%s" % credential_hint(why))
        code, resp = person_call(a, "PUT", {"bundle": bundle, "base": base, "note": note})
        if code == 409 and attempt == 1:
            continue
        if code != 200:
            hub_err(code, resp)
        print("个人配置 v%s（上一版 v%s）— 其余机器下次同步就带上" % (resp.get("version"), resp.get("prev")))
        sync_here(a)
        return 0
    return 1


def edit(a):
    if a.team:
        return team_edit(a)
    if not a.personal:
        die("%s 要写明改哪一层：--personal（你自己的）或 --team（团队，操作者）" % a.action)
    if len(a.args) < 2:
        die("用法：fleet config %s --personal KIND NAME [VALUE | --file F]" % a.action)
    kind = KINDS.get(a.args[0])
    if not kind:
        die("不认识的种类 %s（mcp · settings · codex · skills · hooks · hook_scripts）" % a.args[0])
    name = a.args[1]
    raw = a.args[2] if len(a.args) > 2 else None
    value = raw if a.action == "rm" else parse_value(a, raw)
    return put_personal(a, lambda b: mutate(b, kind, name, value, a.action),
                        a.note or "%s %s.%s" % (a.action, kind, name))


# --- promote -------------------------------------------------------------------------

def local_value(ta, path):
    """(kind, name, value) of this login's own value of a show path."""
    m = re.match(r"^(claude|codex)\.mcp\.(.+)$", path)
    if m:
        if m.group(1) == "claude":
            cj = T.read_json_quiet(ta.claude_config) or {}
            v = (cj.get("mcpServers") or {}).get(m.group(2)) if isinstance(cj, dict) else None
        else:
            v = local_extras(ta, {}).get(path)
        return "mcp", m.group(2), v
    if path.startswith("claude.settings."):
        k = path[len("claude.settings."):].split(".", 1)[0]
        st = T.read_json_quiet(ta.claude_settings) or {}
        return "claude_settings", k, st.get(k) if isinstance(st, dict) else None
    if path.startswith("claude.skills."):
        n = path[len("claude.skills."):]
        return "skills", n, T.skill_get(ta.claude_skills, n)
    if path.startswith("claude.hooks.") and path.count(".") >= 3:
        _, _, ev, key = path.split(".", 3)
        v = local_extras(ta, {}).get(path)
        return "hooks", ev, v if v is not None else None
    if path.startswith("codex.") and path.count(".") == 1:
        k = path[len("codex."):]
        return "codex_config", k, local_extras(ta, {}).get(path)
    die("promote 认得 claude.mcp.X · codex.mcp.X · claude.settings.K · codex.K · claude.skills.N · "
        "claude.hooks.Event.key（fleet config show 里的项），不认得 %s" % path)


def machine_bound(v):
    """The first string in v that only makes sense on this computer, or ''."""
    home = os.path.expanduser("~")
    try:
        user = getpass.getuser()
    except Exception:  # noqa: BLE001
        user = ""
    s = json.dumps(v, ensure_ascii=False)
    for needle in (home, "/Users/" + user, "/home/" + user):
        if user and needle and needle in s:
            return needle
    if user and len(user) > 2 and re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(user), s):
        return user
    return ""


def promote(a):
    if not a.args:
        die("用法：fleet config promote ITEM [--yes]（ITEM 是 fleet config show 里的项）")
    path = a.args[0]
    ta = team_args()
    kind, name, v = local_value(ta, path)
    if v is None:
        die("这台电脑上没有 %s — 没东西可提" % path)
    if kind == "hooks" and isinstance(v, dict):
        v = {k: v[k] for k in ("matcher", "command", "timeout") if k in v and v[k] not in ("", None)}
    if kind == "skills":
        v = T.skill_body(v) if hasattr(T, "skill_body") and T.SKILL_MARK in v else v
    why = validate({kind: {name: v} if kind != "hooks" else {name: [v]}})
    if why:
        die("拒收：%s" % credential_hint(why))
    hit = machine_bound(v)
    if hit and not a.yes:
        print("这项可能只在本机有效（里面有 %s）— 别的机器上不一定能用。确定要带走，加 --yes" % hit, file=sys.stderr)
        return 4
    return put_personal(a, lambda b: mutate(b, kind, name, v, "set"), a.note or "promote %s" % path)


# --- history / restore -------------------------------------------------------------------

def history(a):
    if a.team:
        return team_pass(a, ["history"])
    code, resp = person_call(a, "GET", None, "history=1")
    if code != 200:
        hub_err(code, resp)
    print("个人配置当前 v%s" % resp.get("version"))
    for h in resp.get("history") or []:
        print("v%-4s 上一版 v%-4s %s  %s%s" % (h.get("version"), h.get("prev"), h.get("created"), h.get("actor"),
                                            "  — " + h["note"] if h.get("note") else ""))
    return 0


def restore(a):
    try:
        n = int(a.args[0])
    except (IndexError, ValueError):
        die("用法：fleet config restore N")
    if a.team:
        return team_pass(a, ["restore", str(n)] + (["--note", a.note] if a.note else []))
    for attempt in (1, 2):
        code, cur = person_call(a, "GET")
        if code != 200:
            hub_err(code, cur)
        code, resp = person_call(a, "PUT", {"restore": n, "base": int(cur.get("version") or 0),
                                            **({"note": a.note} if a.note else {})})
        if code == 409 and attempt == 1:
            continue
        if code != 200:
            hub_err(code, resp)
        print("个人配置 v%s = v%d 的内容（上一版 v%s）" % (resp.get("version"), n, resp.get("prev")))
        if not a.person:
            sync_here(a)
        return 0
    return 1


# --- the team layer: fleet-agent-team.py does it -----------------------------------------

def team_pass(a, argv):
    p = subprocess.run([sys.executable, os.path.join(HERE, "fleet-agent-team.py")] + argv
                       + (["--hub", a.hub] if a.hub else []))
    if p.returncode == 0 and argv[0] != "history":
        sync_here(a)
    return p.returncode


def team_edit(a):
    if len(a.args) < 2:
        die("用法：fleet config %s --team KIND NAME [VALUE | --file F]" % a.action)
    kind = KINDS.get(a.args[0])
    if not kind or kind == "hook_scripts":
        die("团队配置的种类：mcp · settings · codex · skills · hooks")
    name = a.args[1]
    raw = a.args[2] if len(a.args) > 2 else None
    value = raw if a.action == "rm" else parse_value(a, raw)
    if os.environ.get("FLEET_TEAM_BUNDLE_CMD"):
        p = subprocess.run(["bash", "-c", os.environ["FLEET_TEAM_BUNDLE_CMD"]], capture_output=True)
        code, cur = (200, decode(p.stdout)) if p.returncode == 0 else (0, {"error": "seam exit %d" % p.returncode})
    else:
        url = T.hub_url(a.hub)
        if not url:
            no_hub()
        tok = os.environ.get("CCQUOTA_VIEWER_TOKEN") or ""
        if not tok:
            die("团队配置只有操作者能改：要 CCQUOTA_VIEWER_TOKEN 在环境里")
        code, raw_ = T.http(url + T.TEAM_PATH, "GET", {"Authorization": "Bearer " + tok,
                                                        "Accept": "application/json"}, None, a.timeout)
        cur = decode(raw_)
    if code != 200:
        hub_err(code, cur)
    bundle = cur.get("bundle") or {}
    mutate(bundle, kind, name, value, a.action)
    fd, tmp = tempfile.mkstemp(prefix="fleet-config-team.", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(bundle, f, ensure_ascii=False)
        return team_pass(a, ["put", tmp, "--base", str(int(cur.get("version") or 0)),
                             "--note", a.note or "%s %s.%s" % (a.action, kind, name)])
    finally:
        os.unlink(tmp)


def main():
    ap = argparse.ArgumentParser(prog="fleet config", description=__doc__.split("\n")[0])
    ap.add_argument("action", nargs="?", default="show",
                    choices=("show", "add", "set", "rm", "promote", "history", "restore"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--personal", action="store_true")
    ap.add_argument("--team", action="store_true")
    ap.add_argument("--file", default="")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--note", default="")
    ap.add_argument("--person", default="", help="the operator: whose personal layer (history / restore)")
    ap.add_argument("--hub", default="")
    ap.add_argument("--timeout", type=float, default=float(os.environ.get("FLEET_TEAM_TIMEOUT") or 8))
    a = ap.parse_intermixed_args()
    if a.personal and a.team:
        die("--personal 和 --team 二选一")
    if a.person and a.action not in ("history", "restore"):
        die("--person 只用于 history / restore（操作者只能帮人退回到他自己的某一版）")
    return {"show": show, "add": edit, "set": edit, "rm": edit, "promote": promote,
            "history": history, "restore": restore}[a.action](a)


if __name__ == "__main__":
    sys.exit(main())
