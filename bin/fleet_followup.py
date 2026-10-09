#!/usr/bin/env python3
"""fleet_followup.py — what a finished batch leaves for a person, gathered into
ONE 「待你动手」 list (issue #2672, EPIC #2668 C4). The one reader and writer of
the followup marker; the steward's beat (bin/fleet_steward.py) runs the rest.

A batch's closing comment on its parent carries one line per thing it leaves:

    <!-- fleet:followup kind=stable|hub-deploy|human [due=<YYYY-MM-DD>] what=<one line> -->

`what` is the rest of the marker (spaces allowed, never a `-->`). The driver
writes them with `fleet_followup.py mark` (commands/fleet-epic-run.md, the closing
tick); the report's 挪稳定版 row prints its own (bin/fleet-epic-stable-row.sh `mark:`).
A closing comment from before this format is read by words one version — `move
stable` / `fleet-stable.sh move` is a stable followup, `重部署` / `redeploy` beside
`入口` / `hub` a hub-deploy one (# compat-1v: 下一批删).

The steward, every beat (fleet_steward.collect → beat()):

  1. watches each EPIC it has met (a window's @epic, an epic mark, `followups
     --watch`): an OPEN one is re-read at most every FLEET_STEWARD_FOLLOWUP_EVERY
     (3600 s) through fleet-gh.sh's cache, a CLOSED one is read for an hour after
     it closed (a late closing tick still counts), then left;
  2. merges what it reads by kind: every batch's `stable` is ONE row, every
     `hub-deploy` ONE row, a `human` row per distinct thing — a batch is merged
     into a row once, ever;
  3. runs what it may: `stable` — `fleet-stable.sh move` (its own gates: CI ·
     oldcfg · macos · release · artifacts) in the background, never while a
     batch holds the install (fleet_epic_holding); a refusal puts ONE row on the
     decision sheet and is retried after FLEET_STEWARD_STABLE_RETRY (7200 s) or
     when the person answers it. `hub-deploy` — a never-defaulted row on the
     sheet; a yes runs FLEET_STEWARD_HUB_DEPLOY_CMD when one is set, else it
     waits on the list for the person. `human` — listed with its due date;
  4. keeps ONE desk ticket 「待你动手」 (fleet-ticket.sh new · edit; its id in
     global/steward.state.json `todo.desk`): a row the steward ran is ticked, a
     row the PERSON ticks there is done;
  5. writes each done row back on every parent it came from (a note,
     `<!-- fleet:followup-done id=… -->`), within the beat's write budget.

    fleet_followup.py mark  --kind K --what W [--due D]   → the marker line
    fleet_followup.py parse (--comments-json FILE|-)      → one followup per line (JSON)

Seams (selftest): FLEET_STEWARD_ISSUE_CMD (argv + repo N: prints {state,
closedAt, comments}), FLEET_STEWARD_STABLE_CMD (argv: replaces `fleet-stable.sh
move …`), FLEET_STEWARD_TICKET_CMD (argv: replaces `bash fleet-ticket.sh`),
FLEET_STEWARD_HOLD_CMD (argv: rc 0 = a batch holds the install),
FLEET_STEWARD_STAMP_TODO_CMD (argv + N), FLEET_STEWARD_FOLLOWUP_SYNC=1 (run a
move in the foreground).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).resolve().parent
KINDS = ("stable", "hub-deploy", "human")
MARK_RE = re.compile(r"<!-- fleet:followup ((?:(?!-->).)*?) ?-->")
DONE_RE = re.compile(r"<!-- fleet:followup-done id=([A-Za-z0-9-]+)")
TICK_RE = re.compile(r"^\s*[-*] \[([ xX])\] .*<!-- fleet:todo id=([A-Za-z0-9-]+) -->")
CLOSED = ("done", "skipped")
NO_RE = re.compile(r"跳过|不做|不发|不部署|不用了|算了|^\s*(no|skip|don'?t)\b", re.I)
# compat-1v: 下一批删 — a closing comment from before the marker
LEGACY_STABLE = re.compile(r"move stable|fleet-stable\.sh move|挪稳定版", re.I)
LEGACY_DEPLOY = re.compile(r"(重部署|重新部署|redeploy)", re.I)
LEGACY_DEPLOY_WHERE = re.compile(r"(入口|hub)", re.I)
SHA_RE = re.compile(r"fleet-stable\.sh move ([0-9a-f]{7,40})")


# ---- the marker (the one format) ---------------------------------------------------

def _clean(s):
    return re.sub(r"\s+", " ", (s or "").replace("-->", "—>")).strip()[:200]


def mark(kind, what, due=None):
    if kind not in KINDS:
        raise ValueError("kind is one of %s" % "|".join(KINDS))
    if not _clean(what):
        raise ValueError("what is empty")
    due = due if due and re.fullmatch(r"\d{4}-\d{2}-\d{2}", due) else None
    return "<!-- fleet:followup kind=%s%s what=%s -->" % (kind, " due=" + due if due else "", _clean(what))


def parse_marker(inner):
    head, sep, what = inner.partition("what=")
    f = {}
    for pair in head.split():
        k, _, v = pair.partition("=")
        f[k] = v
    if f.get("kind") not in KINDS or not sep or not what.strip():
        return None
    return {"kind": f["kind"], "what": _clean(what), "due": f.get("due", "")}


def parse(comments):
    """Comments (gh --json comments shape) → followups: {kind, what, due, url,
    ref, legacy}. The markers when any comment has one; else the old words."""
    out = []
    for c in comments:
        for m in MARK_RE.finditer(c.get("body") or ""):
            f = parse_marker(m.group(1))
            if f:
                f.update(url=c.get("url") or "", legacy=False)
                out.append(f)
    if out:
        return out
    # compat-1v: 下一批删 — one per kind, from the words of a closing comment
    seen = set()
    for c in reversed(comments):
        for line in (c.get("body") or "").splitlines():
            if "不需要" in line or "not needed" in line.lower():
                continue
            kind = None
            if LEGACY_STABLE.search(line):
                kind = "stable"
            elif LEGACY_DEPLOY.search(line) and LEGACY_DEPLOY_WHERE.search(line):
                kind = "hub-deploy"
            if kind and kind not in seen:
                seen.add(kind)
                sha = SHA_RE.search(line)
                what = ("挪稳定版" + (" " + sha.group(1)[:8] if sha else "")) if kind == "stable" \
                    else _clean(re.sub(r"[|`*]", " ", line))[:120]
                out.append({"kind": kind, "what": what, "due": "",
                            "url": c.get("url") or "", "legacy": True, "ref": sha.group(1) if sha else ""})
    return out


def key_of(f):
    if f["kind"] != "human":
        return f["kind"]
    return "human:" + hashlib.sha1(re.sub(r"\s+", "", f["what"]).lower().encode()).hexdigest()[:10]


# ---- the steward's half ----------------------------------------------------------

def _int(fs, key, dflt):
    return fs.env_int(key, dflt)


def todo(st):
    t = st.d.setdefault("todo", {})
    for k, dflt in (("epics", {}), ("items", {}), ("open", {}), ("seen", []), ("desk", ""), ("desk_sha", ""),
                    ("seq", 0)):
        t.setdefault(k, dflt)
    return t


def ref_of(epic, repo=""):
    """An @epic value / mark → `owner/name#N` (None when no repo can be named)."""
    m = re.match(r"^(?:([A-Za-z0-9._-]+/[A-Za-z0-9._-]+))?#([0-9]+)", epic or "")
    if not m:
        return None
    r = m.group(1) or repo
    return "%s#%s" % (r, m.group(2)) if r and r != "-" else None


def watch(st, ref, now):
    t = todo(st)
    if ref and ref not in t["epics"]:
        t["epics"][ref] = {"seen": now, "next": 0, "closed": 0, "done": False, "n": 0}


def read_issue(repo, n):
    cmd = os.environ.get("FLEET_STEWARD_ISSUE_CMD")
    argv = (cmd.split() + [repo, str(n)]) if cmd else \
        ["bash", str(BIN / "fleet-gh.sh"), "issue", "view", str(n), "--repo", repo,
         "--json", "state,closedAt,comments", "--max-age", "300"]
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return json.loads(r.stdout or "{}")


def harvest(fs, st, now, delta, fresh_refs):
    """Read the EPICs due a look; merge what the closed ones leave (steps 1-2)."""
    t = todo(st)
    reads = _int(fs, "FLEET_STEWARD_FOLLOWUP_READS", 10)
    for ref, e in sorted(t["epics"].items()):
        if e.get("done") or ref in fresh_refs or now < e.get("next", 0) or reads <= 0:
            continue
        reads -= 1
        repo, _, n = ref.partition("#")
        try:
            d = read_issue(repo, n)
        except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
            e["next"] = now + 600
            continue
        if str(d.get("state", "")).upper() != "CLOSED":
            e["next"] = now + _int(fs, "FLEET_STEWARD_FOLLOWUP_EVERY", 3600)
            continue
        e["closed"] = e.get("closed") or now
        e["next"] = now + 600
        if now - e["closed"] >= 3600:
            e["done"] = True
        for f in parse(d.get("comments") or []):
            if merge(st, ref, f, now, delta):
                e["n"] = e.get("n", 0) + 1


def merge(st, ref, f, now, delta):
    """One batch's followup into the list — once per (row, batch), ever."""
    t = todo(st)
    key = key_of(f)
    seen = "%s|%s" % (key, ref)
    if seen in t["seen"]:
        return False
    t["seen"].append(seen)
    iid = t["open"].get(key)
    item = t["items"].get(iid or "")
    if not item or item["state"] in CLOSED + ("running",):
        t["seq"] += 1
        iid = "fu-%d" % t["seq"]
        item = {"id": iid, "kind": f["kind"], "key": key, "what": f["what"], "due": f.get("due", ""),
                "sources": [], "state": {"stable": "pending", "hub-deploy": "nod"}.get(f["kind"], "open"),
                "at": now, "note": "", "runs": 0, "writeback": [], "legacy": bool(f.get("legacy"))}
        t["items"][iid] = item
        t["open"][key] = iid
        delta["followups"]["new"].append(iid)
    if f["kind"] == "human" and f.get("due") and (not item["due"] or f["due"] < item["due"]):
        item["due"] = f["due"]
    item["sources"].append({"epic": ref, "url": f.get("url", ""), "legacy": bool(f.get("legacy"))})
    return True


# ---- running what may run --------------------------------------------------------

def holding(fs):
    cmd = os.environ.get("FLEET_STEWARD_HOLD_CMD")
    if cmd:
        return subprocess.run(cmd.split(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30).returncode == 0
    return fs.sh_lib('fleet_epic_holding >/dev/null 2>&1; echo $?') == "0"


def run_dir(fs):
    d = fs.gdir() / "steward-followup"
    d.mkdir(parents=True, exist_ok=True)
    return d


def main_of(fs, sess, repo):
    """The checkout `fleet-stable.sh move --dir` reads: the repo's FLEET_MAIN."""
    slug = next((s for s, r in fs.repo_of_slug(sess).items() if r == repo), None)
    if slug:
        try:
            m = re.search(r'^FLEET_MAIN="?([^"\n]+)"?', (fs.conf_dir() / "fleets" / sess / "repos" /
                                                       (slug + ".conf")).read_text(), re.M)
            if m:
                return m.group(1)
        except OSError:
            pass
    return ""


def command(fs, sess, item):
    if item["kind"] == "stable":
        cmd = os.environ.get("FLEET_STEWARD_STABLE_CMD")
        if cmd:
            return cmd.split()
        repo = item["sources"][0]["epic"].partition("#")[0] if item["sources"] else ""
        main = main_of(fs, sess, repo)
        if not main or not (Path(main) / "bin" / "fleet-stable.sh").exists():
            return None
        return ["bash", str(BIN / "fleet-stable.sh"), "move", "--dir", main, "--repo", repo]
    cmd = os.environ.get("FLEET_STEWARD_HUB_DEPLOY_CMD") or fs.fd._conf_val("FLEET_STEWARD_HUB_DEPLOY_CMD") or ""
    return cmd.split() or None


def launch(fs, item, argv, now):
    d = run_dir(fs)
    base = "%s.%d" % (item["id"], now)
    log, rc = d / (base + ".log"), d / (base + ".rc")
    item.update(state="running", log=str(log), rcfile=str(rc), started=now, runs=item.get("runs", 0) + 1)
    sh = ['sh', '-c', '"$@" >"$0" 2>&1; echo $? >"$0.rc.tmp"; mv "$0.rc.tmp" "%s"' % rc, str(log)] + argv
    if os.environ.get("FLEET_STEWARD_FOLLOWUP_SYNC") == "1":
        subprocess.run(sh, cwd=str(d), timeout=7200)
    else:
        subprocess.Popen(sh, cwd=str(d), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)


def _why(log):
    try:
        lines = Path(log).read_text(errors="replace").splitlines()
    except OSError:
        return ""
    hit = [ln for ln in lines if "REFUSED" in ln] or [ln for ln in lines if ln.strip()]
    return _clean(hit[-1])[:160] if hit else ""


def decision_row(fs, st, item, now, delta, kind, text, suggest):
    """ONE row on the decision sheet for this item (C1's row shape, never defaulted)."""
    rid = item.get("row")
    if rid and st.d["rows"].get(rid, {}).get("state") == "open":
        st.d["rows"][rid]["item"] = text
        return
    src = item["sources"][0] if item["sources"] else {"epic": "?#0", "url": ""}
    repo, _, n = src["epic"].partition("#")
    rid = "%s-%d" % (item["id"], item.get("runs", 0))
    row = {"id": rid, "src": "gh:%s#%s" % (repo, n), "url": src.get("url", ""), "item": text, "suggest": suggest,
           "default": "", "kind": kind, "asked": fs.fd.iso(fs.fd.now_local()), "due": "", "state": "open",
           "followup": item["id"], "v": "1"}
    st.d["rows"][rid] = row
    item["row"] = rid
    delta["new_asks"].append(row)


def close_row(st, item):
    row = st.d["rows"].get(item.get("row") or "")
    if row and row.get("state") == "open":
        row["state"] = "answered"


def finish(st, item, by, now, delta):
    item.update(state="done", by=by, done_at=now)
    item["writeback"] = [s["epic"] for s in item["sources"]]
    close_row(st, item)
    t = todo(st)
    if t["open"].get(item["key"]) == item["id"]:
        del t["open"][item["key"]]
    delta["followups"]["done"].append(item["id"])


def settle(fs, st, item, now, delta):
    """A running item whose command has finished: done, or ONE row on the sheet."""
    rc = Path(item.get("rcfile", ""))
    if not rc.exists():
        if now - item.get("started", now) > 3 * 3600:
            item.update(state="refused", refused_at=now, note=fs.tr("steward_todo_lost"))
        return
    code = rc.read_text().strip()
    if code == "0":
        finish(st, item, "steward", now, delta)
        return
    item.update(state="refused", refused_at=now, note=_why(item.get("log", "")) or "rc " + code)
    delta["followups"]["refused"].append(item["id"])
    decision_row(fs, st, item, now, delta, "normal" if item["kind"] == "stable" else "never:publish",
                 fs.tr("steward_todo_red_fmt", item["what"], item["note"]), fs.tr("steward_todo_red_suggest"))


def execute(fs, sess, st, now, delta):
    t = todo(st)
    retry = _int(fs, "FLEET_STEWARD_STABLE_RETRY", 7200)
    for item in sorted(t["items"].values(), key=lambda i: i["id"]):
        k = item["kind"]
        if item["state"] == "running":
            settle(fs, st, item, now, delta)
            continue
        if k == "stable" and item["state"] == "refused" and now - item.get("refused_at", now) >= retry:
            item["state"] = "pending"
        if k == "hub-deploy" and item["state"] == "nod" and not item.get("row"):
            decision_row(fs, st, item, now, delta, "never:publish",
                         fs.tr("steward_todo_nod_fmt", item["what"]), fs.tr("steward_todo_nod_suggest"))
        run = (k == "hub-deploy" and item["state"] == "approved") or (k == "stable" and item["state"] == "pending")
        if not run:
            continue
        if k == "stable" and holding(fs):
            item["note"] = fs.tr("steward_todo_hold")
            continue
        argv = command(fs, sess, item)
        if not argv:
            # nothing here can run it: it stays on the list for the person
            item.update(state="open" if k == "stable" else item["state"], note=fs.tr("steward_todo_manual"))
            continue
        item["note"] = ""
        launch(fs, item, argv, now)
        settle(fs, st, item, now, delta)


def answered(st, row, text, by):
    """A decision row of ours got its answer (fleet-steward-tick.sh answer)."""
    item = todo(st)["items"].get(row.get("followup") or "")
    if not item:
        return
    no = bool(NO_RE.search(text))
    if item["kind"] == "hub-deploy" and item["state"] == "nod":
        item["state"] = "skipped" if no else "approved"
        item["note"] = "" if no else text
        if no:
            item.update(by=by, done_at=int(time.time()))
            t = todo(st)
            if t["open"].get(item["key"]) == item["id"]:
                del t["open"][item["key"]]
    elif item["kind"] == "stable" and item["state"] == "refused":
        item["state"] = "skipped" if no else "pending"


# ---- the desk ticket -------------------------------------------------------------

def ticket(argv, body=None):
    cmd = os.environ.get("FLEET_STEWARD_TICKET_CMD")
    full = (cmd.split() if cmd else ["bash", str(BIN / "fleet-ticket.sh")]) + argv
    return subprocess.run(full, input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, timeout=120)


def status(fs, item):
    s = item["state"]
    word = fs.tr("steward_todo_state_" + s.replace("-", "_"))
    if s == "done":
        word = fs.tr("steward_todo_state_done_by_" + item.get("by", "steward"))
    return word + ((" · " + item["note"]) if item.get("note") and s not in CLOSED else "")


def render(fs, t):
    lines = [fs.tr("steward_todo_intro"), ""]
    for item in sorted(t["items"].values(), key=lambda i: (i["state"] in CLOSED, i["id"])):
        src = "、".join(s["epic"] for s in item["sources"])
        due = (" · " + fs.tr("steward_todo_due_fmt", item["due"])) if item.get("due") else ""
        lines.append("- [%s] %s · %s%s · %s <!-- fleet:todo id=%s -->" % (
            "x" if item["state"] in CLOSED else " ", fs.tr("steward_todo_kind_" + item["kind"].replace("-", "_")) +
            "：" + item["what"], fs.tr("steward_todo_from_fmt", src), due, status(fs, item), item["id"]))
    return "\n".join(lines + ["", "<!-- fleet:todo-desk v=1 -->"])


def desk(fs, st, now, delta):
    t = todo(st)
    if not t["items"]:
        return
    # the person's ticks first: a row ticked on the ticket is done
    if t["desk"] and any(i["state"] not in CLOSED for i in t["items"].values()):
        r = ticket(["read", t["desk"], "--json", "body", "--max-age", "300"])
        body = ""
        if r.returncode == 0:
            try:
                body = json.loads(r.stdout or "{}").get("body") or ""
            except ValueError:
                pass
        for line in body.splitlines():
            m = TICK_RE.match(line)
            item = t["items"].get(m.group(2)) if m else None
            if item and m.group(1) in "xX" and item["state"] not in CLOSED + ("running",):
                finish(st, item, "person", now, delta)
    body = render(fs, t)
    sha = hashlib.sha1(body.encode()).hexdigest()
    if sha == t["desk_sha"] or st.budget_left() < 1:
        if sha != t["desk_sha"]:
            delta["deferred"] += 1
        return
    if not t["desk"]:
        repo = os.environ.get("FLEET_STEWARD_TODO_REPO") or fs.fd._conf_val("FLEET_STEWARD_TODO_REPO") or \
            next((s["epic"].partition("#")[0] for i in t["items"].values() for s in i["sources"]), "")
        r = ticket(["new", "--repo", repo, "--title", fs.tr("steward_todo_title"), "--body", body,
                    "--origin", "steward"])
        st.spend(1)
        got = (r.stdout or "").split()
        if r.returncode == 0 and got and got[0].startswith("gh:"):
            t["desk"], t["desk_url"], t["desk_sha"] = got[0], (got[1] if len(got) > 1 else ""), sha
        return
    r = ticket(["edit", t["desk"], "--body-file", "-"], body)
    st.spend(1)
    if r.returncode == 0:
        t["desk_sha"] = sha


def write_back(fs, st, delta):
    t = todo(st)
    for item in sorted(t["items"].values(), key=lambda i: i["id"]):
        while item.get("writeback"):
            if st.budget_left() < 1:
                delta["deferred"] += len(item["writeback"])
                break
            ref = item["writeback"][0]
            repo, _, n = ref.partition("#")
            body = "\n".join([fs.tr("steward_todo_done_fmt", item["what"],
                                    fs.tr("steward_todo_state_done_by_" + item.get("by", "steward")),
                                    t.get("desk_url") or t["desk"] or "—"),
                              "", "<!-- fleet:followup-done id=%s -->" % item["id"]])
            try:
                fs.fd.post(repo, n, body, "note")
            except (RuntimeError, OSError):
                break
            st.spend(1)
            item["writeback"].pop(0)


def stamp(fs, sess, st, wins):
    n = sum(1 for i in todo(st)["items"].values() if i["state"] not in CLOSED)
    st.d["todo_open"] = n
    cmd = os.environ.get("FLEET_STEWARD_STAMP_TODO_CMD")
    if cmd:
        subprocess.run(cmd.split() + [str(n)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        return
    for w in wins:
        if w["role"] == "orchestrator":
            args = ["tmux", "-L", fs.socket(sess), "set-window-option", "-t", w["wid"]]
            subprocess.run(args + (["@orch_todo", str(n)] if n else ["-u", "@orch_todo"]),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def beat(fs, sess, st, now, delta, wins, marks):
    """The followup pass of one beat. Nothing met, nothing listed ⇒ nothing written."""
    delta["followups"] = {"new": [], "done": [], "refused": []}
    if "todo" not in st.d and not any(w.get("epic") for w in wins) and not marks:
        return
    for w in wins:
        if w.get("epic"):
            watch(st, ref_of(w["epic"], w.get("repo", "")), now)
    fresh = set()
    for m in marks:
        ref = ref_of("#" + m["epic"], m["repo"])
        watch(st, ref, now)
        if m["fresh"]:
            fresh.add(ref)
    harvest(fs, st, now, delta, fresh)
    execute(fs, sess, st, now, delta)
    desk(fs, st, now, delta)
    write_back(fs, st, delta)
    stamp(fs, sess, st, wins)


def card(fs, st):
    t = st.d.get("todo")
    if not t or not t.get("items"):
        return None
    items = t["items"].values()
    return fs.tr("steward_card_todo_fmt", sum(1 for i in items if i["state"] not in CLOSED),
                 sum(1 for i in items if i["state"] == "done" and i.get("by") == "steward"))


# ---- CLI -------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet_followup.py")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("mark")
    p.add_argument("--kind", required=True, choices=KINDS)
    p.add_argument("--what", required=True)
    p.add_argument("--due")
    p = sub.add_parser("parse")
    p.add_argument("--comments-json", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "mark":
        print(mark(a.kind, a.what, a.due))
        return 0
    if a.cmd == "parse":
        src = sys.stdin if a.comments_json == "-" else open(a.comments_json, encoding="utf-8")
        data = json.load(src)
        for f in parse(data.get("comments", data) if isinstance(data, dict) else data):
            print(json.dumps(f, ensure_ascii=False))
        return 0
    ap.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
