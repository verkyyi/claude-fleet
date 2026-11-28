#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet-cred-proxy-liveness-selftest.py — a live session's fcp1 never runs out.

bin/fleet-cred-proxy.py used to renew an expired session credential only while
its wrapper's pid was alive AND for at most FLEET_CRED_PROXY_RENEW_MAX_SECS
(7 days) past its stamp: every session alive past day 8 answered 401
`session credential expired`, which /login cannot fix. The session is now its
wrapper's IDENTITY (pid + start time, live-meta.json): no total age, and a pid
reused by another process is refused. Drives Keys.verify + live_session +
live_report + the mint/revoke control ops with the process table played by a
fake (pid_alive / proc_start):

  W  a wrapper alive with its recorded start time: good 30 days past the stamp
  R  the same pid, a later start time (reused after the wrapper died): refused
  D  the wrapper gone: refused; revoked: refused
  L  minted before live-meta.json (no record, a running session at upgrade):
     its wrapper started before the mint → good and recorded; started after → refused
  U  no start time readable: the old bound, RENEW_MAX past the stamp — and
     live_report names it with its hard end (the doctor's WARN)
  M  the real mint / revoke ops write and drop the live-meta.json record
  P  proc_start reads a real process's start time (this one's), None for no process
"""
import importlib.util
import json
import os
import sys
import tempfile
import time

BIN = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("credproxy", os.path.join(BIN, "fleet-cred-proxy.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

FAILS = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


# --- a fake process table ------------------------------------------------------
PROCS = {}      # pid -> start time (None = alive, start unreadable)
cp.pid_alive = lambda pid: int(pid) in PROCS
cp.proc_start = lambda pid: PROCS.get(int(pid))

DAY = 86400
NOW = time.time()


def rig():
    st = tempfile.mkdtemp(prefix="cred-live.")
    return st, cp.Keys(st)


def put(state, name, d):
    cp.write_json(os.path.join(state, name), d)


def get(state, name):
    return cp.read_json(os.path.join(state, name), {})


def stamp(keys, sid, exp):
    """An fcp1 for sid that expired at `exp` (signed with this rig's key)."""
    c = {"sid": sid, "acct": "a1", "exp": int(exp), "n": "00"}
    payload = json.dumps(c, separators=(",", ":")).encode()
    import hashlib
    import hmac
    return cp.LOCAL_TAG + "." + cp.b64e(payload) + "." + cp.b64e(hmac.new(keys.key, payload, hashlib.sha256).digest())


def verify(state, keys, tok, ttl=DAY):
    return keys.verify(tok, live=cp.live_session(state, ttl))


# W — a month-old session whose wrapper is alive and is the one recorded
st, keys = rig()
PROCS.clear(); PROCS[4242] = int(NOW - 31 * DAY)
mint_at = int(NOW - 30 * DAY)
put(st, "live.json", {"w-4242-1": 4242})
put(st, "live-meta.json", {"w-4242-1": {"pid": 4242, "st": PROCS[4242], "iat": mint_at, "exp": mint_at + DAY}})
c, why = verify(st, keys, stamp(keys, "w-4242-1", mint_at + DAY))
check(c is not None and c.get("renewed"), "W a live wrapper (recorded pid + start) keeps its fcp1 29 days past the stamp: %s" % why)
os.environ["FLEET_CRED_PROXY_RENEW_MAX_SECS"] = "60"
c, why = verify(st, keys, stamp(keys, "w-4242-1", mint_at + DAY))
check(c is not None, "W RENEW_MAX no longer bounds a session whose wrapper is proven: %s" % why)
os.environ.pop("FLEET_CRED_PROXY_RENEW_MAX_SECS")
rep = cp.live_report(st, DAY)
check(rep["live"] == 1 and rep["proven"] == 1 and rep["unproven"] == 0, "W live_report: 1 live, 1 proven, none with a hard end: %s" % rep)

# R — the wrapper died (SIGKILL: no revoke ran) and the kernel gave its pid to a later process
PROCS[4242] = int(NOW - 3600)
c, why = verify(st, keys, stamp(keys, "w-4242-1", mint_at + DAY))
check(c is None and why == "session credential expired", "R the same pid with a later start time (reused) is refused: %s" % why)
rep = cp.live_report(st, DAY)
check(rep["proven"] == 0 and rep["unproven"] == 0, "R live_report counts a reused pid as neither proven nor at risk: %s" % rep)

# D — wrapper gone; revoked
PROCS.clear()
c, why = verify(st, keys, stamp(keys, "w-4242-1", mint_at + DAY))
check(c is None and why == "session credential expired", "D the wrapper gone: refused (%s)" % why)
PROCS[4242] = int(NOW - 31 * DAY)
with open(os.path.join(st, "revoked"), "a") as f:
    f.write("w-4242-1\n")
c, why = verify(st, keys, stamp(keys, "w-4242-1", mint_at + DAY))
check(c is None and why == "session credential revoked", "D revoked: refused though the wrapper lives (%s)" % why)

# L — minted before live-meta.json existed: no record
st, keys = rig()
PROCS.clear(); PROCS[5151] = int(NOW - 9 * DAY - 600)      # the wrapper, started before its mint
exp = int(NOW - 8 * DAY)                                      # minted 9 days ago, a day's ttl
put(st, "live.json", {"w-5151-1": 5151})
c, why = verify(st, keys, stamp(keys, "w-5151-1", exp))
check(c is not None, "L an older session (no record) whose wrapper predates its mint: good on day 9 (%s)" % why)
m = get(st, "live-meta.json").get("w-5151-1") or {}
check(m.get("pid") == 5151 and m.get("st") == PROCS[5151] and m.get("exp") == exp,
      "L ... and its wrapper's identity is recorded for next time: %s" % m)
PROCS[5151] = int(NOW - 60)                                   # now a reused pid
c, why = verify(st, keys, stamp(keys, "w-5151-1", exp))
check(c is None, "L once recorded, a later start on that pid is refused (%s)" % why)
st, keys = rig()
PROCS.clear(); PROCS[5252] = int(NOW - 3 * DAY)               # started AFTER the mint 9 days ago
put(st, "live.json", {"w-5252-1": 5252})
c, why = verify(st, keys, stamp(keys, "w-5252-1", exp))
check(c is None, "L no record and the pid's process started after the mint: refused (%s)" % why)
check("w-5252-1" not in get(st, "live-meta.json"), "L ... and nothing is recorded for it")

# U — the start time cannot be read: the old bound applies, and is reported
st, keys = rig()
PROCS.clear(); PROCS[6161] = None
put(st, "live.json", {"w-6161-1": 6161})
recent = int(NOW - 2 * DAY)
put(st, "live-meta.json", {"w-6161-1": {"pid": 6161, "st": None, "iat": recent - DAY, "exp": recent}})
c, why = verify(st, keys, stamp(keys, "w-6161-1", recent))
check(c is not None, "U unprovable wrapper, 2 days past the stamp: still inside RENEW_MAX (%s)" % why)
c, why = verify(st, keys, stamp(keys, "w-6161-1", int(NOW - 8 * DAY)))
check(c is None, "U unprovable wrapper, 8 days past the stamp: the old 7-day bound refuses (%s)" % why)
rep = cp.live_report(st, DAY)
check(rep["unproven"] == 1 and rep["hard_exp"] == recent + 7 * DAY,
      "U live_report names it with its hard end (stamp + 7d): %s" % rep)


# M — the control ops write and drop the record
class Cfg:
    pass


class T:
    pass


st, keys = rig()
PROCS.clear(); PROCS[7171] = int(NOW - 100)
cfg = Cfg(); cfg.state, cfg.ttl, cfg.store = st, DAY, ""
t = T(); t.cfg, t.keys, t.name, t.picks, t.hubcreds, t.quota = cfg, keys, "", {}, {}, {}
t.codex_state, t.codex_lock = {"sessions": {}}, cp.threading.RLock()
t.capacity_metadata = lambda: {}
t.save_codex_state = lambda: None
t.log = lambda **kw: None
r = cp.ctl_handle({"op": "mint", "account": "a1", "sid": "w-7171-1", "wrap": 7171}, t)
m = get(st, "live-meta.json").get("w-7171-1") or {}
check(r.get("ok") and m.get("pid") == 7171 and m.get("st") == PROCS[7171] and m.get("exp", 0) - m.get("iat", 0) == DAY,
      "M mint --wrap records the wrapper's pid, start time, iat and exp: %s" % m)
r = cp.ctl_handle({"op": "revoke", "sid": "w-7171-1"}, t)
check(r.get("ok") and "w-7171-1" not in get(st, "live-meta.json") and "w-7171-1" not in get(st, "live.json"),
      "M revoke drops the record with live.json's row")

# P — the real reader
spec2 = importlib.util.spec_from_file_location("credproxy2", os.path.join(BIN, "fleet-cred-proxy.py"))
real = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(real)
me = real.proc_start(os.getpid())
check(me is not None and abs(me - time.time()) < 600, "P proc_start reads this process's start time: %s" % me)
check(real.proc_start(0) is None and real.proc_start("x") is None, "P no process / no pid: None")

print("%d failure(s)" % len(FAILS) if FAILS else "all ok")
sys.exit(1 if FAILS else 0)
