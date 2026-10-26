#!/usr/bin/env python3
"""fleet-hub-move.py — the ONE writer of a machine's hub address (task PNWW).

When the hub moves (an operator sets the hub's `fleet.node_url`, docs/dev/
MANAGED-NODE.md «Moving the hub»), every hello's welcome names the new address.
The agent that dialed the old one runs this script: `verify` first, then
`rewrite`, then it reconnects. Nobody edits the files below by hand any more.

  fleet-hub-move.py verify  --from OLD --to NEW
      stdin: two Authorization values — for OLD/v1/node/self, then for
      NEW/v1/node/self (`Bearer <token>` or a FleetSig header; never an argv).
      0 = NEW takes this node's own credential for the SAME endpoint OLD names
      (both answer 200 with one endpoint_id) · 3 = refused, nothing written ·
      2 usage.
  fleet-hub-move.py rewrite --scope login|machine --from OLD --to NEW
                            [--conf-dir D] [--state S] [--cred-base B]
      every file of the scope whose hub address is OLD is rewritten to NEW —
      whole (a same-directory rename), mode and owner kept, the old bytes kept
      beside it as <file>.hub-prev. A value naming any other hub is never
      touched; a link is never written through.
      0 = nothing of the scope names OLD any more · 1 = something still does
      (listed — a file this caller may not write) · 2 usage.
  fleet-hub-move.py follow  --scope … --from OLD --to NEW  = verify, then rewrite.

The scopes, each written by its owner (CLAUDE.md: a root file by root, a
login's by that login — the machine agent runs `login` through prepCmd):

  login   ($FLEET_CONF_DIR, default ~/.config/claude-fleet) fleet.conf and the
          old shell.conf / fleet.settings (`[export] FLEET_HUB_URL=` /
          `CCQUOTA_HUB_URL=` lines), node.env when it is the login's own file
          (a separated login's is a link into the store: root's half),
          node.pub.env, hub.json's "url", node.key.ok ("<keyid> <hub>").
  machine (root; --state, default $FLEET_NODE_STATE or /var/db/fleet-node)
          logins/*.env, logins/*.key.ok, machine.key.ok, hub-url, the admin
          seat's admin/admin.conf `hub=` (its unit re-rendered by
          fleet_admin_seat.py agent — the one renderer), admin-agent/'s key and
          conf, the credential stores' node.env (--cred-base, default
          $FLEET_CREDSEP_ROOT_BASE or /var/db/fleet-cred) — and machine.env
          LAST: the node daemon restarts the node program on its change.

Credentials: the token is read on stdin by `verify` only and sent nowhere but
the two /v1/node/self calls; rewrite copies a node.env's bytes into its own
.hub-prev beside it (same mode, same owner) and writes no new credential file.

Seams (selftests only): FLEET_HUB_MOVE_TEST_HTTP=1 lets `verify` take an
http://127.0.0.1 address as NEW.
"""
import glob
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SELF_PATH = "/v1/node/self"
ORIGIN_RE = re.compile(r"^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$")
TEST_ORIGIN_RE = re.compile(r"^http://127\.0\.0\.1:[0-9]{1,5}$")
ANY_ORIGIN_RE = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$")
HUB_KEYS = ("CCQUOTA_HUB_URL", "FLEET_HUB_URL")
LINE_RE = re.compile(r"^(\s*(?:export\s+)?(?:%s)=)([\"']?)([^\"'\s#]*)\2(\s*(?:#.*)?)$" % "|".join(HUB_KEYS))


def say(*a):
    print("fleet-hub-move:", *a, file=sys.stderr)


def norm(u):
    return (u or "").strip().rstrip("/")


# ---------------------------------------------------------------- verify -----
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):  # a redirect is not an answer
        return None


def self_row(base, auth):
    """(endpoint_id, why): the hub at base's /v1/node/self for this credential."""
    req = urllib.request.Request(base + SELF_PATH, headers={"Authorization": auth})
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=15) as r:
            if r.status != 200:
                return "", "HTTP %d" % r.status
            row = json.loads(r.read(1 << 20).decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as e:
        return "", "HTTP %d" % e.code
    except (OSError, ValueError) as e:
        return "", "no answer (%s)" % e
    eid = row.get("endpoint_id") if isinstance(row, dict) else None
    if not isinstance(eid, str) or not eid:
        return "", "an answer without endpoint_id"
    return eid, ""


def new_ok(to):
    if ORIGIN_RE.match(to):
        return True
    return os.environ.get("FLEET_HUB_MOVE_TEST_HTTP") == "1" and bool(TEST_ORIGIN_RE.match(to))


def verify(frm, to):
    if not ANY_ORIGIN_RE.match(frm):
        say("verify: --from %r is not an http(s) origin" % frm)
        return 2
    if not new_ok(to):
        say("verify: refused — %r is not an https origin" % to)
        return 3
    if frm == to:
        say("verify: refused — the new address is the one dialed")
        return 3
    lines = sys.stdin.read().splitlines()
    if len(lines) < 2 or not lines[0].strip() or not lines[1].strip():
        say("verify: stdin needs two Authorization values (old, new)")
        return 2
    a, why = self_row(frm, lines[0].strip())
    if not a:
        say("verify: refused — %s%s answers %s" % (frm, SELF_PATH, why))
        return 3
    b, why = self_row(to, lines[1].strip())
    if not b:
        say("verify: refused — %s%s answers %s for this node's own credential" % (to, SELF_PATH, why))
        return 3
    if a != b:
        say("verify: refused — %s names endpoint %s, %s names %s: not the same hub" % (frm, a, to, b))
        return 3
    print("verified: %s takes this node's credential for endpoint %s" % (to, b))
    return 0


# ---------------------------------------------------------------- rewrite ----
class Book:
    def __init__(self):
        self.changed, self.left = [], []


def _put(path, data, st):
    """data → path whole: a fresh temp file (O_EXCL | O_NOFOLLOW) in the same
    directory, the original's mode and owner, one rename."""
    tmp = "%s.hubmove.%d" % (path, os.getpid())
    try:
        os.unlink(tmp)
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        if os.geteuid() == 0 and (st.st_uid != 0 or st.st_gid != 0):
            os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def rewrite_file(path, fn, book):
    """fn(text) -> (new text, still names OLD after?) applied to path; a link or
    a non-file is never written through."""
    try:
        st = os.lstat(path)
    except OSError:
        return
    if not os.path.isfile(path) or os.path.islink(path):
        return
    mine = os.geteuid() in (0, st.st_uid)
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        book.left.append("%s (not readable here)" % path)
        return
    text = raw.decode("utf-8", "surrogateescape")
    new, hit = fn(text)
    if not hit:
        return
    if not mine:
        book.left.append("%s (not this login's file)" % path)
        return
    try:
        _put(path + ".hub-prev", raw, st)
        _put(path, new.encode("utf-8", "surrogateescape"), st)
    except OSError as e:
        book.left.append("%s (%s)" % (path, e.strerror or e))
        return
    book.changed.append(path)


def env_fn(frm, to):
    def fn(text):
        out, hit = [], False
        for line in text.split("\n"):
            m = LINE_RE.match(line)
            if m and norm(m.group(3)) == frm:
                line = m.group(1) + m.group(2) + to + m.group(2) + m.group(4)
                hit = True
            out.append(line)
        return "\n".join(out), hit
    return fn


def kv_fn(key, frm, to):
    """admin.conf-style key=value (no quotes)."""
    def fn(text):
        out, hit = [], False
        for line in text.split("\n"):
            if line.startswith(key + "=") and norm(line[len(key) + 1:]) == frm:
                line, hit = key + "=" + to, True
            out.append(line)
        return "\n".join(out), hit
    return fn


def raw_fn(frm, to):
    """a file that is the address alone (<state>/hub-url)."""
    def fn(text):
        if norm(text) == frm:
            return to + "\n", True
        return text, False
    return fn


def keyok_fn(frm, to):
    """<key>.ok = "<keyid> <hub>": the key stays confirmed at the new address."""
    def fn(text):
        p = text.split()
        if len(p) == 2 and norm(p[1]) == frm:
            return "%s %s\n" % (p[0], to), True
        return text, False
    return fn


def json_fn(frm, to):
    """hub.json's "url"; the rest of the object byte-for-byte in meaning."""
    def fn(text):
        try:
            obj = json.loads(text)
        except ValueError:
            return text, False
        if not isinstance(obj, dict) or norm(obj.get("url")) != frm:
            return text, False
        obj["url"] = to
        indent = 2 if "\n " in text else None
        return json.dumps(obj, indent=indent) + ("\n" if text.endswith("\n") else ""), True
    return fn


def conf_dir_files(d, frm, to, book):
    for n in ("fleet.conf", "shell.conf", "fleet.settings", "node.env", "node.pub.env"):
        p = os.path.join(d, n)
        if n == "node.env" and os.path.islink(p):
            # a separated login's: the store is root's half (--scope machine);
            # until it names the new address the agent must not restart on it
            try:
                with open(p) as f:
                    still = env_fn(frm, to)(f.read())[1]
            except OSError:
                still = True
            if still:
                book.left.append("%s (the credential store's: sudo %s rewrite --scope machine --from %s --to %s)"
                                 % (p, os.path.join(HERE, "fleet-hub-move.py"), frm, to))
            continue
        rewrite_file(p, env_fn(frm, to), book)
    rewrite_file(os.path.join(d, "hub.json"), json_fn(frm, to), book)
    rewrite_file(os.path.join(d, "node.key.ok"), keyok_fn(frm, to), book)


def rewrite_login(a, book):
    d = a.conf_dir or os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")
    conf_dir_files(d, a.frm, a.to, book)


def rewrite_machine(a, book):
    s = a.state or os.environ.get("FLEET_NODE_STATE") or "/var/db/fleet-node"
    base = a.cred_base or os.environ.get("FLEET_CREDSEP_ROOT_BASE") or "/var/db/fleet-cred"
    e, k = env_fn(a.frm, a.to), keyok_fn(a.frm, a.to)
    for p in sorted(glob.glob(os.path.join(s, "logins", "*.env"))):
        rewrite_file(p, e, book)
    for p in sorted(glob.glob(os.path.join(s, "logins", "*.key.ok")) + glob.glob(os.path.join(s, "*.key.ok"))):
        rewrite_file(p, k, book)
    rewrite_file(os.path.join(s, "hub-url"), raw_fn(a.frm, a.to), book)
    sa = os.path.join(s, "admin-agent")
    rewrite_file(os.path.join(sa, "node.key.ok"), k, book)
    conf_dir_files(os.path.join(sa, "conf"), a.frm, a.to, book)
    for p in sorted(glob.glob(os.path.join(base, "*", "node.env"))):
        rewrite_file(p, e, book)
    for p in sorted(glob.glob(os.path.join(base, "*", "node.key.ok"))):
        rewrite_file(p, k, book)
    conf = os.path.join(s, "admin", "admin.conf")
    before = len(book.changed)
    rewrite_file(conf, kv_fn("hub", a.frm, a.to), book)
    if len(book.changed) > before:
        seat_agent(a.to, book)
    # last: the node daemon restarts the node program on machine.env's change
    rewrite_file(os.path.join(s, "machine.env"), e, book)


def seat_agent(to, book):
    """The admin seat's own unit carries CCQUOTA_HUB_URL: fleet_admin_seat.py
    agent re-renders it from the one template and restarts the seat's agent."""
    seat = os.path.join(HERE, "fleet_admin_seat.py")
    if not os.path.isfile(seat):
        book.left.append("the admin seat's unit (no %s here)" % seat)
        return
    sys.path.insert(0, HERE)
    try:
        import fleet_admin_seat  # noqa: E402 — the seat's own unit path
        if not os.path.lexists(fleet_admin_seat.unit_path()):
            return  # no seat agent on this machine: admin.conf was all
    except Exception:  # noqa: BLE001 — an older module: ask it anyway
        pass
    finally:
        sys.path.pop(0)
    r = subprocess.run([sys.executable, "-I", seat, "agent", "--hub", to],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, timeout=120)
    note = (r.stdout or "").strip().splitlines()
    print("admin seat agent: rc %d%s" % (r.returncode, (" · " + note[-1]) if note else ""))
    # 3 = no seat here (nothing to move)
    if r.returncode not in (0, 3):
        book.left.append("the admin seat's unit (fleet_admin_seat.py agent rc %d)" % r.returncode)


def rewrite(a):
    if not ANY_ORIGIN_RE.match(a.frm) or not ANY_ORIGIN_RE.match(a.to):
        say("rewrite: --from / --to must be http(s) origins")
        return 2
    if a.frm == a.to:
        return 0
    book = Book()
    (rewrite_machine if a.scope == "machine" else rewrite_login)(a, book)
    for p in book.changed:
        print("rewrote %s (was %s, kept as %s.hub-prev)" % (p, a.frm, p))
    for p in book.left:
        print("LEFT %s — still names %s" % (p, a.frm))
    if not book.changed and not book.left:
        print("nothing of the %s scope names %s" % (a.scope, a.frm))
    return 1 if book.left else 0


class Args:
    pass


def parse(argv):
    a = Args()
    a.cmd = argv[0] if argv else ""
    a.scope, a.frm, a.to, a.conf_dir, a.state, a.cred_base = "login", "", "", "", "", ""
    it = iter(argv[1:])
    for x in it:
        v = next(it, None) if x.startswith("--") else None
        if v is None:
            return None
        if x == "--scope" and v in ("login", "machine"):
            a.scope = v
        elif x == "--from":
            a.frm = norm(v)
        elif x == "--to":
            a.to = norm(v)
        elif x == "--conf-dir":
            a.conf_dir = v
        elif x == "--state":
            a.state = v
        elif x == "--cred-base":
            a.cred_base = v
        else:
            return None
    if a.cmd not in ("verify", "rewrite", "follow") or not a.frm or not a.to:
        return None
    return a


def main(argv):
    a = parse(argv)
    if a is None:
        print(__doc__, file=sys.stderr)
        return 2
    if a.cmd == "verify":
        return verify(a.frm, a.to)
    if a.cmd == "follow":
        rc = verify(a.frm, a.to)
        if rc != 0:
            return rc
    return rewrite(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
