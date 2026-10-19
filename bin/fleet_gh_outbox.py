#!/usr/bin/env python3
"""fleet_gh_outbox.py — a GitHub ticket write that could not be made is kept here
and made later (issue #4844, EPIC #4839 C5, 共同约定 5).

When GitHub does not answer (the layer's rc 75: «不通», or the account's rate
limit), bin/fleet-ticket.sh's write verbs — claim · post · close · state · edit ·
label · priority · link — do not fail and do not hang: they put the verb here and
say 「已记下」 (rc 0 + one stderr line). The issue-bridge tick drains it once GitHub
answers again, in the order the writes were made, through the same door
(`fleet-ticket.sh <verb> …` with FLEET_GH_OUTBOX_REPLAY=1, so a replay that meets
GitHub still down gets 75 back instead of queueing a second copy). Nothing new
runs on a timer; no token is ever written down.

  fleet_gh_outbox.py put   --repo R --verb V [--session S] -- <the verb's argv>
                                        → the op id; for `post` the body gains
                                          `<!-- fleet:op id=<opid> -->`
  fleet_gh_outbox.py count              → `<pending> <oldest epoch|-> <stuck>`
  fleet_gh_outbox.py line               → the doctor's words; exit 1 when empty
  fleet_gh_outbox.py list               → one line per entry, oldest first
  fleet_gh_outbox.py drain [--max N]    → replay, oldest first; exit 0

One entry, one file: $FLEET_CONF_DIR/gh-outbox/<ms>-<opid>.json (dir 0700, file
0600), keys `v · opid · repo · verb · args · session · ts` (+ `tries`,
`failing_since`, `last_err` once a replay failed). The name sorts by time.

Never twice: a `post` is replayed only after the ticket's comments since the entry
was written are read and none carries its op id; a `link` only when the child does
not hang under the parent yet; the rest are idempotent (close, state, edit, labels,
priority, the claim's own assignee read). A claim is dropped (one log line) when
the session that made it no longer holds the issue — the hub lease renews off that
session's live window, so its window gone ⇒ the lease is not its own any more.

Order: a replay that meets GitHub down again stops the drain (the rest wait their
turn); one that fails otherwise holds back the later writes to THAT ticket only
(a close never overtakes its wrap-up comment) and is retried next tick; failing
for FLEET_GH_OUTBOX_STUCK_SECS (24 h) moves it to gh-outbox/stuck/ (the doctor
WARNs). At most --max (FLEET_GH_OUTBOX_BATCH, 50) per tick — a backlog of
hundreds goes out over several ticks, each write through the per-token queue's
1 s gap. Log: $FLEET_CONF_DIR/logs/gh-outbox.log.
"""
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_gh  # noqa: E402

DOWN = fleet_gh.DOWN
VERBS = ("claim", "post", "close", "state", "edit", "label", "priority", "link")


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or Path.home() / ".config/claude-fleet")


def box():
    return Path(os.environ.get("FLEET_GH_OUTBOX_DIR") or conf_dir() / "gh-outbox")


def num_env(name, default):
    v = os.environ.get(name, "")
    return int(v) if v.isdigit() else default


def log(event, **kw):
    try:
        d = conf_dir() / "logs"
        d.mkdir(parents=True, exist_ok=True)
        fields = " ".join(f"{k}={str(v).replace(' ', '_')}" for k, v in kw.items())
        with open(d / "gh-outbox.log", "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {event} {fields}\n")
    except OSError:
        pass


def entries(sub=None):
    d = box() / sub if sub else box()
    if not d.is_dir():
        return []
    return sorted(p for p in d.iterdir() if p.is_file() and p.suffix == ".json" and not p.name.startswith("."))


def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write(p, e):
    tmp = p.with_name(f".{p.name}.{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(e, f, ensure_ascii=False)
    os.replace(tmp, p)


def ticket_of(e):
    """`<owner/name>#<N>` the entry writes to (a link: the parent)."""
    a = e.get("args") or []
    tid = a[1] if e.get("verb") == "label" and len(a) > 1 else (a[0] if a else "")
    return tid.split(":", 1)[-1]


def op_marker(opid):
    return f"<!-- fleet:op id={opid} -->"


# ---- put ---------------------------------------------------------------------
def cmd_put(argv):
    repo = verb = session = ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            argv = argv[i + 1:]
            break
        if a in ("--repo", "--verb", "--session") and i + 1 < len(argv):
            if a == "--repo":
                repo = argv[i + 1]
            elif a == "--verb":
                verb = argv[i + 1]
            else:
                session = argv[i + 1]
            i += 2
            continue
        print(f"fleet_gh_outbox: put: unknown argument {a!r}", file=sys.stderr)
        return 2
    else:
        argv = []
    if verb not in VERBS or not repo or not argv:
        print("fleet_gh_outbox: put --repo R --verb V [--session S] -- <args…>", file=sys.stderr)
        return 2
    opid = secrets.token_hex(6)
    args = list(argv)
    if verb == "post":
        # the body carries the op id, so a replay can see it already arrived
        for k in range(len(args) - 1):
            if args[k] == "--body":
                args[k + 1] = args[k + 1].rstrip("\n") + "\n" + op_marker(opid)
                break
    d = box()
    try:
        d.mkdir(parents=True, exist_ok=True)
        os.chmod(d, 0o700)
    except OSError as ex:
        print(f"fleet_gh_outbox: cannot make {d}: {ex}", file=sys.stderr)
        return 1
    ms = int(time.time() * 1000)
    e = {"v": 1, "opid": opid, "repo": repo, "verb": verb, "args": args,
         "session": session, "ts": ms // 1000}
    try:
        write(d / f"{ms:015d}-{opid}.json", e)
    except OSError as ex:
        print(f"fleet_gh_outbox: cannot write the entry: {ex}", file=sys.stderr)
        return 1
    log("put", opid=opid, verb=verb, ticket=ticket_of(e), session=session or "-")
    print(opid)
    return 0


# ---- count / line / list -----------------------------------------------------
def counts():
    pend = entries()
    oldest = None
    for p in pend:
        e = load(p)
        if e and isinstance(e.get("ts"), int):
            oldest = e["ts"] if oldest is None else min(oldest, e["ts"])
    return len(pend), oldest, len(entries("stuck"))


def cmd_count(_):
    n, oldest, stuck = counts()
    print(n, oldest if oldest is not None else "-", stuck)
    return 0


def cmd_line(_):
    n, oldest, stuck = counts()
    if not n and not stuck:
        return 1
    parts = []
    if n:
        m = max(0, (int(time.time()) - (oldest or int(time.time()))) // 60)
        parts.append(f"待补 {n} 条，最早 {m} 分钟前" if m else f"待补 {n} 条，最早不到 1 分钟前")
    if stuck:
        parts.append(f"补不上 {stuck} 条（{box() / 'stuck'}）")
    print(" · ".join(parts))
    return 0


def cmd_list(_):
    for sub in (None, "stuck"):
        for p in entries(sub):
            e = load(p) or {}
            when = time.strftime("%m-%d %H:%M", time.localtime(e.get("ts") or 0))
            tail = f" · {e['last_err']}" if e.get("last_err") else ""
            print(f"{'stuck ' if sub else ''}{when} {e.get('opid', '?')} {e.get('verb', '?')} "
                  f"{ticket_of(e)} {e.get('session') or '-'}{tail}")
    return 0


# ---- drain -------------------------------------------------------------------
def ticket(verb, *args, timeout=120):
    env = dict(os.environ, FLEET_GH_OUTBOX_REPLAY="1")
    try:
        r = subprocess.run(["bash", str(BIN / "fleet-ticket.sh"), verb, *args], env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return DOWN, "", "the door did not answer"
    return r.returncode, r.stdout, r.stderr


def owner_live(e):
    """The claim's session still holds the issue: its window is alive here."""
    s = e.get("session") or ""
    if not s:
        return True
    seam = os.environ.get("FLEET_GH_OUTBOX_OWNER_CMD")
    repo_n = ticket_of(e)
    if seam:
        return subprocess.run(["bash", "-c", seam, "owner", s, repo_n],
                              stdin=subprocess.DEVNULL, capture_output=True).returncode == 0
    probe = ('. "$1/fleet-lib.sh" >/dev/null 2>&1 || exit 2; '
             'for s in $(fleet_sockets); do fleet_win_for_addr "$2" "$s" >/dev/null 2>&1 && exit 0; done; exit 1')
    rc = subprocess.run(["bash", "-c", probe, "owner", str(BIN), s],
                        stdin=subprocess.DEVNULL, capture_output=True).returncode
    return rc != 1   # cannot tell (2) ⇒ keep it: the claim's own read still guards


def already_posted(e):
    """rc: True posted · False not yet · None GitHub did not answer."""
    repo_n = ticket_of(e)
    repo, n = repo_n.rsplit("#", 1)
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(max(0, (e.get("ts") or 0) - 120)))
    r = fleet_gh.run("api", f"repos/{repo}/issues/{n}/comments?since={since}&per_page=100",
                     "--paginate", "--jq", ".[].body", stdin=subprocess.DEVNULL,
                     capture_output=True, text=True)
    if r.returncode == DOWN:
        return None
    if r.returncode != 0:
        return False
    if op_marker(e["opid"]) in r.stdout:
        return True
    # the first try may have reached GitHub before its answer was lost (a timeout):
    # that copy has no op id, but the same words
    a = e.get("args") or []
    body = a[a.index("--body") + 1] if "--body" in a[:-1] else ""
    body = body.replace(op_marker(e["opid"]), "").strip()
    return bool(body) and body in r.stdout


def already_linked(e):
    a = e.get("args") or []
    if len(a) < 2 or "--remove" in a:
        return False
    rc, out, _ = ticket("parent", a[1])
    if rc == DOWN:
        return None
    return rc == 0 and out.strip() == a[0]


def first_line(s):
    for ln in (s or "").splitlines():
        if ln.strip():
            return ln.strip()[:200]
    return ""


def cmd_drain(argv):
    mx = num_env("FLEET_GH_OUTBOX_BATCH", 50)
    if len(argv) >= 2 and argv[0] == "--max" and argv[1].isdigit():
        mx = int(argv[1])
    d = box()
    if not entries():
        return 0
    lock = d / ".drain.lock"
    try:
        os.mkdir(lock)
    except FileExistsError:
        try:
            if time.time() - lock.stat().st_mtime < 900:
                return 0
            os.rmdir(lock)
            os.mkdir(lock)
        except OSError:
            return 0
    try:
        return _drain(d, mx)
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass


def _drain(d, mx):
    stuck_after = num_env("FLEET_GH_OUTBOX_STUCK_SECS", 86400)
    held = set()   # tickets whose earlier write failed this tick
    done = sent = 0
    for p in entries():
        if done >= mx:
            break
        e = load(p)
        if not e or e.get("verb") not in VERBS or not e.get("args"):
            (d / "stuck").mkdir(exist_ok=True)
            os.replace(p, d / "stuck" / p.name)
            log("stuck", file=p.name, why="unreadable")
            continue
        t = ticket_of(e)
        if t in held:
            continue
        done += 1
        if e["verb"] == "claim" and "--release" not in e["args"] and not owner_live(e):
            p.unlink()
            log("dropped", opid=e["opid"], verb="claim", ticket=t, session=e.get("session"),
                why="the session no longer holds it")
            continue
        check = already_posted if e["verb"] == "post" else already_linked if e["verb"] == "link" else None
        if check:
            got = check(e)
            if got is None:
                log("wait", opid=e["opid"], why="GitHub down")
                break
            if got:
                p.unlink()
                log("already", opid=e["opid"], verb=e["verb"], ticket=t)
                continue
        rc, _out, err = ticket(e["verb"], *e["args"])
        if rc == 0:
            p.unlink()
            sent += 1
            log("replayed", opid=e["opid"], verb=e["verb"], ticket=t,
                secs=int(time.time()) - (e.get("ts") or int(time.time())))
            continue
        if rc == DOWN:
            log("wait", opid=e["opid"], why="GitHub down")
            break
        if e["verb"] == "claim" and rc == 3:
            p.unlink()
            log("dropped", opid=e["opid"], verb="claim", ticket=t, why=first_line(err) or "claimed by another")
            continue
        now = int(time.time())
        e["tries"] = int(e.get("tries") or 0) + 1
        e.setdefault("failing_since", now)
        e["last_err"] = first_line(err) or f"exit {rc}"
        if rc == 2 or now - int(e["failing_since"]) >= stuck_after:
            (d / "stuck").mkdir(exist_ok=True)
            write(d / "stuck" / p.name, e)
            p.unlink()
            log("stuck", opid=e["opid"], verb=e["verb"], ticket=t, err=e["last_err"])
            continue
        write(p, e)
        held.add(t)
        log("retry", opid=e["opid"], verb=e["verb"], ticket=t, rc=rc, err=e["last_err"])
    if sent:
        print(f"gh-outbox: replayed {sent}", file=sys.stderr)
    return 0


def main(argv):
    if not argv:
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    fn = {"put": cmd_put, "count": cmd_count, "line": cmd_line, "list": cmd_list,
          "drain": cmd_drain}.get(argv[0])
    if not fn:
        print(f"fleet_gh_outbox: unknown command {argv[0]!r}", file=sys.stderr)
        return 2
    return fn(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
