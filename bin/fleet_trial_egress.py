"""fleet_trial_egress.py — what a trial login may reach on the network (WACK C3).

Off by default: a trial login reaches what any login does. Switched on — the hub
setting `fleet.trial.egress` (off · log · block), or FLEET_TRIAL_EGRESS in the
machine's machine.env, which wins on that machine — the machine loads ONE pf anchor,
`fleet-trial`, whose rules name only the uids of the logins the hub says a trial
person holds here (GET /v1/node/trial-egress, the machine's token):

  block   a trial uid's TCP / UDP leaving the machine reaches only the allowlist
          (conf/trial-egress.allow, resolved here every pass, plus the hub's own
          host) and DNS; mail ports 25 / 465 / 587 are refused even to it; every
          refused connection is one line of <log>/egress-deny.log
  log     nothing is refused; what block would refuse is written there
  off     the anchor is flushed (`pfctl -a fleet-trial -s rules` prints nothing)
          and the logger stopped

Admins and members are never named: the rules match `user <uid>` of a managed
(taken-over, never admin — issue #2842) login the hub listed, nothing else. The
anchor is rebuilt WHOLE every pass from the hub's list, so a recycled login (its
home cleared on the hub) leaves it within one pass; a hub not heard from for
FLEET_TRIAL_EGRESS_STALE_SECS (900) flushes it — the default is open, so a stale
list never keeps a login shut (BREAK-IT `trial-egress-stuck`).

Root's: run by the root core's `egress` op (fleet-node-core.py, a seated daemon)
or the root daemon's own pass. `log` below is the pflog reader the pass starts.
Seams (tests): FLEET_PFCTL · FLEET_TCPDUMP · FLEET_IFCONFIG · FLEET_TRIAL_EGRESS_RESOLVE
(a JSON {host: [ip, …]} instead of DNS) · FLEET_TRIAL_EGRESS_ALLOW (the list's path).
"""
from __future__ import print_function

import hashlib
import ipaddress
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time

ANCHOR = "fleet-trial"
TABLE = "fleet_trial_allow"
MODES = ("off", "log", "block")
MAIL_PORTS = (25, 465, 587)
PATH = "/v1/node/trial-egress"
HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def env_num(name, default):
    try:
        return int(os.environ.get(name) or default)
    except ValueError:
        return default


def pfctl():
    return os.environ.get("FLEET_PFCTL") or "/sbin/pfctl"


def allow_path(runtime):
    return os.environ.get("FLEET_TRIAL_EGRESS_ALLOW") or os.path.join(runtime, "conf", "trial-egress.allow")


def read_allow(path):
    """The allowlist: one host name, address or CIDR a line; '#' comments. A line
    that is none of them is skipped (named in the second list)."""
    out, bad = [], []
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except (IOError, OSError):
        return out, bad
    for line in lines:
        e = line.split("#", 1)[0].strip()
        if not e:
            continue
        try:
            out.append(str(ipaddress.ip_network(e, strict=False)))
            continue
        except ValueError:
            pass
        if HOST_RE.match(e) and "." in e:
            out.append(e.lower())
        else:
            bad.append(e)
    return out, bad


def resolve(entries):
    """Every entry as addresses: a host name resolved now (A and AAAA), an
    address / CIDR as it is. A name that does not resolve is left out, never the
    whole list (pfctl refuses a table with an unresolvable name)."""
    fake = os.environ.get("FLEET_TRIAL_EGRESS_RESOLVE")
    table = None
    if fake:
        try:
            with open(fake) as f:
                table = json.load(f)
        except (IOError, OSError, ValueError):
            table = {}
    addrs, missed = [], []
    for e in entries:
        if "/" in e or re.match(r"^[0-9.]+$", e) or ":" in e:
            addrs.append(e)
            continue
        got = []
        if table is not None:
            got = list(table.get(e) or [])
        else:
            try:
                for fam, _t, _p, _c, sa in socket.getaddrinfo(e, None, 0, socket.SOCK_STREAM):
                    if fam in (socket.AF_INET, socket.AF_INET6):
                        got.append(sa[0].split("%", 1)[0])
            except (socket.error, UnicodeError):
                got = []
        if not got:
            missed.append(e)
        addrs.extend(got)
    seen, uniq = set(), []
    for a in addrs:
        if a not in seen:
            seen.add(a)
            uniq.append(a)
    return uniq, missed


def rules(mode, uids, addrs):
    """The anchor's text for mode (log · block) over uids, allowing addrs."""
    if mode not in ("log", "block") or not uids:
        return ""
    act = "block return out log quick" if mode == "block" else "pass out log quick"
    mail = " ".join(str(p) for p in MAIL_PORTS)
    lines = ["table <%s> const { %s }" % (TABLE, ", ".join(addrs))] if addrs else []
    for u in sorted(set(int(x) for x in uids)):
        # loopback is the machine itself (the credential proxy, a dev server): never ours
        lines.append("%s on ! lo0 proto { tcp udp } to any port { %s } user %d" % (act, mail, u))
        lines.append("pass out quick on ! lo0 proto { tcp udp } to any port 53 user %d" % u)
        if addrs:
            lines.append("pass out quick on ! lo0 proto { tcp udp } to <%s> user %d" % (TABLE, u))
        lines.append("%s on ! lo0 proto { tcp udp } all user %d" % (act, u))
    return "\n".join(lines) + "\n"


def run(argv, data=None, timeout=30):
    try:
        r = subprocess.run(argv, input=data.encode() if data is not None else None, capture_output=True,
                           timeout=timeout, close_fds=True)
        return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)


def anchor_rules():
    rc, out, _err = run([pfctl(), "-a", ANCHOR, "-s", "rules"])
    return out if rc == 0 else ""


def hook_main():
    """The main ruleset must name the anchor once (macOS' /etc/pf.conf does not):
    reload /etc/pf.conf plus one `anchor "fleet-trial"` line when it does not."""
    rc, out, err = run([pfctl(), "-s", "rules"])
    if rc == 0 and re.search(r'^anchor "%s"' % re.escape(ANCHOR), out, re.M):
        return ""
    conf = os.environ.get("FLEET_PF_CONF") or "/etc/pf.conf"
    try:
        with open(conf) as f:
            base = f.read()
    except (IOError, OSError) as e:
        return "cannot read %s: %s" % (conf, e)
    rc, _o, err = run([pfctl(), "-f", "-"], base.rstrip("\n") + '\nanchor "%s"\n' % ANCHOR)
    return "" if rc == 0 else "hooking the anchor: %s" % err.strip()[-300:]


def enable(book):
    """pf on, by reference (`pfctl -E` → a token we keep; `-X` gives it back)."""
    if book.get("token"):
        rc, out, _e = run([pfctl(), "-s", "References"])
        if rc != 0 or str(book["token"]) in out:
            return ""
    rc, out, err = run([pfctl(), "-E"])
    m = re.search(r"Token\s*:\s*(\d+)", out + err)
    if rc != 0 and not m:
        return "pfctl -E: %s" % err.strip()[-300:]
    book["token"] = m.group(1) if m else ""
    return ""


def release(book):
    if book.get("token"):
        run([pfctl(), "-X", str(book["token"])])
    book["token"] = ""


def rule_map(text):
    """{rule number in the anchor: uid} off `pfctl -a … -vv -s rules` (@N lines):
    pflog names a rule by its number, never its user."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^@(\d+)\s+(.*)$", line.strip())
        if m and " log" in m.group(2):
            u = re.search(r"user\s*=\s*(\d+)", m.group(2))
            if u:
                out[m.group(1)] = int(u.group(1))
    return out


PFLOG_RE = re.compile(r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\S*\s+rule\s+(?P<rule>\S+?)/\S*\(match\):\s+"
                      r"(?P<act>pass|block)\s+(?:in|out)\s+on\s+\S+:\s+(?P<src>\S+)\s+>\s+(?P<dst>\S+?):(?P<rest>.*)$")


def parse_pflog(line, rmap, names):
    """One `tcpdump -n -e -tttt -i pflog0` line → one egress-deny.log line, or None
    (another anchor's rule, or a rule not in the map)."""
    m = PFLOG_RE.match(line.strip())
    if not m:
        return None
    parts = m.group("rule").split(".")
    if len(parts) > 1 and ANCHOR not in parts:
        return None
    nr = parts[-1]
    uid = rmap.get(nr)
    if uid is None:
        return None
    dst = m.group("dst")
    host, _dot, port = dst.rpartition(".")
    rest = m.group("rest")
    proto = "tcp" if "Flags [" in rest or " tcp " in rest.lower() else ("udp" if "UDP" in rest.upper() else "-")
    what = "deny" if m.group("act") == "block" else "would-deny"
    ts = m.group("ts").replace(" ", "T") + "Z"
    return "%s %s %s uid=%d %s %s:%s" % (ts, what, names.get(str(uid), "-"), uid, proto, host or dst, port or "-")


class Ctx(object):
    """What a pass needs of the machine: its state and log dirs, the runtime, the
    machine.env reader, the managed logins and a login's uid — the supervisor's
    own helpers, handed in so this file stays importable alone."""

    def __init__(self, state, logdir, runtime, read_env, managed, uid_of):
        self.state, self.logdir, self.runtime = state, logdir, runtime
        self.read_env, self.managed, self.uid_of = read_env, managed, uid_of
        self.book = os.path.join(state, "trial-egress.json")
        self.map = os.path.join(state, "trial-egress.map.json")
        self.pid = os.path.join(state, "trial-egress.log.pid")
        self.deny_log = os.path.join(logdir, "egress-deny.log")


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (IOError, OSError, ValueError):
        return default


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, sort_keys=True)
    os.rename(tmp, path)


def pull(me):
    """(mode, logins, error) from the hub."""
    hub, token = (me.get("CCQUOTA_HUB_URL") or "").rstrip("/"), me.get("CCQUOTA_TOKEN") or ""
    if not hub or not token:
        return None, None, "machine.env names no hub or no token"
    from urllib.request import Request, urlopen
    try:
        req = Request(hub + PATH, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
        with urlopen(req, timeout=env_num("FLEET_TRIAL_EGRESS_PULL_SECS", 10)) as r:
            body = json.loads(r.read().decode("utf-8"))
    except Exception as e:  # urllib raises many kinds; the reason is all we keep
        return None, None, "the hub: %s" % (getattr(e, "code", None) or getattr(e, "reason", None) or e)
    mode = str(body.get("mode") or "off")
    logins = [str(x) for x in (body.get("logins") or []) if LOGIN_RE.match(str(x))]
    return (mode if mode in MODES else "off"), logins, ""


def decide(ctx, t):
    """(mode, logins, note) for this pass: the hub's answer (else the last one
    while fresh), the machine's FLEET_TRIAL_EGRESS over its mode."""
    me = ctx.read_env() or {}
    book = read_json(ctx.book, {}) or {}
    local = (os.environ.get("FLEET_TRIAL_EGRESS") or me.get("FLEET_TRIAL_EGRESS") or "").strip()
    if local and local not in MODES:
        local = ""
    if local == "off":
        return "off", [], "FLEET_TRIAL_EGRESS=off here", book
    mode, logins, err = pull(me)
    if err:
        book["pull_error"] = err
        fresh = t - float(book.get("pulled_at") or 0) <= env_num("FLEET_TRIAL_EGRESS_STALE_SECS", 900)
        if not fresh:
            return "off", [], "the hub's list is stale (%s) — open, as the default" % err, book
        mode, logins = book.get("hub_mode") or "off", list(book.get("hub_logins") or [])
    else:
        book.update(pull_error="", pulled_at=t, hub_mode=mode, hub_logins=logins)
    return (local or mode), logins, "", book


def logger_alive(ctx):
    try:
        pid = int(open(ctx.pid).read().strip())
        os.kill(pid, 0)
        return pid
    except (IOError, OSError, ValueError):
        return 0


def logger_start(ctx):
    if logger_alive(ctx):
        return
    me = os.path.abspath(__file__)
    p = subprocess.Popen([sys.executable, "-I", me, "log", "--map", ctx.map, "--out", ctx.deny_log],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True, start_new_session=True)
    with open(ctx.pid, "w") as f:
        f.write("%d\n" % p.pid)


def logger_stop(ctx):
    pid = logger_alive(ctx)
    if pid:
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
    try:
        os.unlink(ctx.pid)
    except OSError:
        pass


def converge(ctx, t=None):
    """One pass: decide, then make the anchor exactly that. Returns the book."""
    t = time.time() if t is None else t
    mode, logins, note, book = decide(ctx, t)
    managed = set(ctx.managed())
    uids, names, skipped = [], {}, []
    for login in sorted(set(logins)):
        uid = ctx.uid_of(login) if login in managed else None
        if not uid:
            skipped.append(login)   # not a taken-over login here (an admin never is)
            continue
        uids.append(uid)
        names[str(uid)] = login
    err = ""
    want = ""
    if mode != "off" and uids:
        entries, bad = read_allow(allow_path(ctx.runtime))
        hub = (ctx.read_env() or {}).get("CCQUOTA_HUB_URL") or ""
        m = re.match(r"^https?://([^/:]+)", hub)
        if m:
            entries.append(m.group(1).lower())
        addrs, missed = resolve(entries)
        if bad or missed:
            note = (note + "; " if note else "") + "allowlist: unusable %s" % ", ".join(bad + missed)
        want = rules(mode, uids, addrs)
    digest = hashlib.sha256(want.encode()).hexdigest()[:16]
    have = anchor_rules().strip()
    if not want:
        if have or book.get("digest"):
            run([pfctl(), "-a", ANCHOR, "-F", "all"])
        release(book)
        logger_stop(ctx)
        book["digest"] = ""
    else:
        err = hook_main() or enable(book)
        if not err and (digest != book.get("digest") or not have):
            rc, _o, e = run([pfctl(), "-a", ANCHOR, "-f", "-"], want)
            if rc != 0:
                err = "loading the anchor: %s" % e.strip()[-300:]
            else:
                book["digest"] = digest
                _rc, vv, _e = run([pfctl(), "-a", ANCHOR, "-vv", "-s", "rules"])
                write_json(ctx.map, {"rules": rule_map(vv), "names": names})
        if not err:
            if run([os.environ.get("FLEET_IFCONFIG") or "/sbin/ifconfig", "pflog0"])[0] != 0:
                run([os.environ.get("FLEET_IFCONFIG") or "/sbin/ifconfig", "pflog0", "create"])
            logger_start(ctx)
    book.update(mode=mode, logins=sorted(names.values()), uids=sorted(uids), skipped=skipped,
                note=note, error=err, at=t)
    write_json(ctx.book, book)
    return book


def follow(map_path, out_path):
    """`log`: tcpdump on pflog0, each line of ours appended to egress-deny.log."""
    tcpdump = os.environ.get("FLEET_TCPDUMP") or "/usr/sbin/tcpdump"
    p = subprocess.Popen([tcpdump, "-n", "-e", "-l", "-tttt", "-i", "pflog0"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True)
    signal.signal(signal.SIGTERM, lambda *_a: (p.terminate(), sys.exit(0)))
    stamp, m = None, {}
    for raw in p.stdout:
        try:
            st = os.stat(map_path).st_mtime
        except OSError:
            st = None
        if st != stamp:
            stamp, m = st, read_json(map_path, {}) or {}
        line = parse_pflog(raw.decode("utf-8", "replace"), m.get("rules") or {}, m.get("names") or {})
        if line:
            with open(out_path, "a") as f:
                f.write(line + "\n")
    return p.wait()


def main(argv):
    if argv[:1] == ["log"] and "--map" in argv and "--out" in argv:
        return follow(argv[argv.index("--map") + 1], argv[argv.index("--out") + 1])
    if argv[:1] == ["rules"]:   # print what a mode would load: rules <mode> <uid>… (no pf touched)
        entries, _bad = read_allow(allow_path(os.environ.get("FLEET_NODE_RUNTIME") or "."))
        addrs, _m = resolve(entries)
        sys.stdout.write(rules(argv[1] if len(argv) > 1 else "block", [int(x) for x in argv[2:]], addrs))
        return 0
    print("usage: fleet_trial_egress.py log --map <file> --out <file> | rules <mode> <uid>…", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
