#!/usr/bin/env python3
"""fleet-trial-guard.py — hold every trial login on this machine to its share
(claude-fleet WACK C4): 4 cores · 8 GB · 20 GB of home by default
(fleet.trial.limits), and stop one that mines or scans.

The root daemon's `trial-guard` task runs `tick` every minute. The hub says who
is on trial here (GET /v1/node/trial-limits with the machine's token — its one
reading, isTrialIdentity); a login it does not name is never touched, so a
member is never slowed, paused or written up. Each pass, per trial login:

  miner   a process whose name or argv is a known miner (xmrig, cpuminer,
          ethminer, … or a stratum+tcp:// pool URL)          → pause · trial_abuse
  pool    a connection to a mining-pool port (FLEET_TRIAL_POOL_PORTS)
                                                             → pause · trial_abuse
  scan    more than FLEET_TRIAL_CONN_BURST (300) remote endpoints new since the
          last pass                                          → pause · trial_abuse
  cpu     its processes' %CPU over cpu×100 for FLEET_TRIAL_CPU_STRIKES (2)
          passes → renice (nice 10) · trial_runaway; still over
          FLEET_TRIAL_PAUSE_STRIKES (5) passes after that → pause · trial_runaway
  mem     fleet-memguard.sh (every 2 s) stops its largest process once the uid's
          RSS passes mem — this pass hands memguard the line (<dir>/mem.tsv) and
          reports what it stopped (<dir>/mem-events.tsv)     → trial_runaway
  disk    every FLEET_TRIAL_DISK_EVERY (600 s): `du` of its home over disk
          → warn · trial_runaway; over 120 % → pause · trial_runaway

A pause is SIGSTOP to every process of the login (its sessions freeze, nothing
is lost) and holds until `resume <login>` — an admin's — or the hub stops naming
it (转正, the trial ended, limits off). Every action goes through the root core's
`trial` op when a core answers (bin/fleet-node-core.py), else bin/fleet_trial.py
as root. Alerts go to the hub (POST /v1/node/trial-alert); one that cannot be
sent waits in the state for the next pass.

Usage:
  fleet-trial-guard.py tick                one pass (root)
  fleet-trial-guard.py check               the doctor's line: trial-limits: OK|WARN|INFO — …
  fleet-trial-guard.py status              the last pass, readable
  fleet-trial-guard.py resume <login>      SIGCONT + nice 0, the strikes cleared (root)

Files (FLEET_TRIAL_DIR, default <FLEET_NODE_STATE or /var/db/fleet-node>/trial):
  list.json (the hub's last answer, 0600) · state.json (strikes, pauses, pending
  alerts, 0600) · status.json (the doctor's, 0644) · mem.tsv (memguard's lines,
  0644) · mem-events.tsv (memguard's stops) · actions.log (one line an action).

Seams (tests): FLEET_TRIAL_LIST (a JSON file in the hub's shape), FLEET_TRIAL_PASSWD
(JSON {login: {uid, home}}), FLEET_TRIAL_PS_CMD, FLEET_TRIAL_DU_CMD / FLEET_TRIAL_NET_CMD
(shell; {home} / {uid} filled), FLEET_TRIAL_ALERT_LOG (alerts appended there, not
sent), FLEET_TRIAL_ACT=record (log only, act on nothing).
"""
import json
import os
import pwd
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet_trial  # noqa: E402

MINER_RE = re.compile(r"(^|[/\s])(xmrig|xmr-stak|cpuminer|minerd|ethminer|cgminer|bfgminer|ccminer|t-rex|nbminer|"
                      r"lolminer|gminer|nanominer|phoenixminer|srbminer|teamredminer|nheqminer|bminer|kawpowminer)"
                      r"([\s.-]|$)|stratum\+(tcp|ssl|tls)://", re.I)
POOL_PORTS_DEFAULT = "3333,3334,3357,4444,5555,7777,8333,9999,14433,14444,45560,45700"


def env(name, default):
    v = os.environ.get(name, "")
    return v if v != "" else default


def env_num(name, default):
    v = os.environ.get(name, "")
    try:
        return float(v) if v != "" else default
    except ValueError:
        return default


def state_dir():
    return env("FLEET_TRIAL_DIR", os.path.join(env("FLEET_NODE_STATE", "/var/db/fleet-node"), "trial"))


def path(name):
    return os.path.join(state_dir(), name)


def read_json(p, default):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_file(p, text, mode):
    tmp = p + ".tmp.%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.rename(tmp, p)


def write_json(p, obj, mode=0o600):
    write_file(p, json.dumps(obj, sort_keys=True, indent=1) + "\n", mode)


def log_action(line):
    try:
        with open(path("actions.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S") + " " + line + "\n")
    except OSError:
        pass


def gib(n):
    return "%.1fG" % (n / float(1 << 30))


# ------------------------------------------------------------ the hub's word ---
def machine_env():
    out = {}
    try:
        with open(os.path.join(env("FLEET_NODE_STATE", "/var/db/fleet-node"), "machine.env")) as f:
            for line in f.read().splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return out


def hub_call(method, rel, body=None):
    me = machine_env()
    hub, token = (me.get("CCQUOTA_HUB_URL") or "").rstrip("/"), me.get("CCQUOTA_TOKEN") or ""
    if not hub or not token:
        raise RuntimeError("machine.env names no hub or no token")
    from urllib.request import Request, urlopen
    data = json.dumps(body).encode() if body is not None else None
    req = Request(hub + rel, data=data, method=method,
                  headers={"Authorization": "Bearer " + token, "Accept": "application/json",
                           "Content-Type": "application/json"})
    with urlopen(req, timeout=env_num("FLEET_TRIAL_HUB_SECS", 10)) as r:
        return json.loads(r.read().decode("utf-8") or "{}")


def pull_list():
    """(list, error): the hub's answer, else the last one kept (error says why)."""
    stub = os.environ.get("FLEET_TRIAL_LIST")
    try:
        lst = read_json(stub, None) if stub else hub_call("GET", "/v1/node/trial-limits")
        if not isinstance(lst, dict) or not isinstance(lst.get("logins", {}), dict):
            raise RuntimeError("the list is not {on, logins, …}")
        write_json(path("list.json"), lst)
        return lst, ""
    except Exception as e:  # urllib raises many kinds; the reason is what we keep
        why = "the hub: %s" % (getattr(e, "code", None) or getattr(e, "reason", None) or e)
        return read_json(path("list.json"), None), why


def send_alert(a):
    """True once the hub (or the test log) has it."""
    rec = os.environ.get("FLEET_TRIAL_ALERT_LOG")
    try:
        if rec:
            with open(rec, "a") as f:
                f.write(json.dumps(a, sort_keys=True) + "\n")
        else:
            hub_call("POST", "/v1/node/trial-alert", a)
        return True
    except Exception as e:
        code = getattr(e, "code", None)
        if code in (400, 403):  # the hub will never take it (no longer a trial login …)
            return True
        return False


# ------------------------------------------------------------- measuring -------
def account(login):
    stub = os.environ.get("FLEET_TRIAL_PASSWD")
    if stub:
        r = (read_json(stub, {}) or {}).get(login)
        return (int(r["uid"]), r.get("home") or "") if r else None
    try:
        p = pwd.getpwnam(login)
    except KeyError:
        return None
    return p.pw_uid, p.pw_dir


def run_sh(cmd, timeout):
    try:
        return subprocess.run(["/bin/sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def home_bytes(home):
    cmd = os.environ.get("FLEET_TRIAL_DU_CMD")
    if cmd:
        out = run_sh(cmd.replace("{home}", home), 300)
    else:
        try:
            out = subprocess.run(["du", "-skx", home], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 universal_newlines=True, timeout=300).stdout
        except (OSError, subprocess.SubprocessError):
            out = None
    try:
        return int((out or "").split()[0]) * 1024
    except (IndexError, ValueError):
        return None


def remotes(uid):
    """{"host:port"} of the uid's TCP connections (established or opening)."""
    cmd = os.environ.get("FLEET_TRIAL_NET_CMD")
    if cmd:
        out = run_sh(cmd.replace("{uid}", str(uid)), 30) or ""
        return set(x.strip() for x in out.splitlines() if x.strip())
    try:
        out = subprocess.run(["lsof", "-nP", "-a", "-u", str(uid), "-iTCP", "-Fn"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    got = set()
    for line in out.splitlines():
        if line.startswith("n") and "->" in line:
            got.add(line.split("->", 1)[1].strip())
    return got


def port_of(ep):
    try:
        return int(ep.rsplit(":", 1)[1])
    except (IndexError, ValueError):
        return None


# ------------------------------------------------------------- acting ----------
def do_act(login, uid, action, why):
    """Pause / renice / resume login's processes; the result's words."""
    if env("FLEET_TRIAL_ACT", "") == "record":
        res = "recorded"
    else:
        res = None
        try:
            import fleet_node_core as wire
            if wire.available():
                r = wire.call("trial", {"login": login, "action": action})
                # the core's answer stands — but a root caller it cut off (the
                # seated daemon's core takes only the seat) acts on its own below
                if r.get("ok") or r.get("refused") or os.geteuid() != 0:
                    res = "core %s" % json.dumps(r, sort_keys=True)
        except Exception as e:  # no core: root's own road below
            res = None if os.geteuid() == 0 or os.environ.get("FLEET_NODE_TEST") == "1" else "core: %s" % e
        if res is None:
            try:
                res = "direct %s" % json.dumps(fleet_trial.act(uid, action), sort_keys=True)
            except ValueError as e:
                res = "refused: %s" % e
    log_action("%s %s (%s): %s" % (action, login, why, res))
    return res


# ------------------------------------------------------------- one pass --------
def judge(login, uid, home, lim, rows, st, now):
    """Look at one trial login; act and queue alerts. st is its own state dict."""
    alerts = []

    def alert(kind, what, action, detail):
        alerts.append({"login": login, "kind": kind, "what": what, "action": action, "detail": detail[:300]})

    mine = [r for r in rows if r[1] == uid]
    paused = st.get("paused")

    # abuse first: a miner or a pool or a scan pauses at once, whatever the load
    if not paused:
        for r in mine:
            if MINER_RE.search(r[4]) or MINER_RE.search(r[5]):
                st["paused"] = paused = "miner"
                do_act(login, uid, "pause", "miner pid %d" % r[0])
                alert("abuse", "miner", "pause", "pid %d: %s" % (r[0], r[5][:160]))
                break
    if not paused:
        ports = set(int(p) for p in env("FLEET_TRIAL_POOL_PORTS", POOL_PORTS_DEFAULT).split(",") if p.strip().isdigit())
        eps = remotes(uid)
        pool = sorted(e for e in eps if port_of(e) in ports)
        new = eps - set(st.get("remotes") or [])
        st["remotes"] = sorted(eps)[:2000]
        if pool:
            st["paused"] = paused = "pool"
            do_act(login, uid, "pause", "pool %s" % pool[0])
            alert("abuse", "pool", "pause", "connected to %s" % ", ".join(pool[:5]))
        elif len(new) > env_num("FLEET_TRIAL_CONN_BURST", 300):
            st["paused"] = paused = "scan"
            do_act(login, uid, "pause", "%d new endpoints" % len(new))
            alert("abuse", "scan", "pause", "%d new remote endpoints in one pass" % len(new))

    # cpu: sustained over the share → renice, still over → pause
    pcpu = sum(r[2] for r in mine)
    st["pcpu"] = round(pcpu, 1)
    line = lim["cpu"] * 100.0
    if pcpu > line and not paused:
        st["cpu_strikes"] = st.get("cpu_strikes", 0) + 1
        st["under"] = 0
        if not st.get("reniced") and st["cpu_strikes"] >= env_num("FLEET_TRIAL_CPU_STRIKES", 2):
            st["reniced"], st["cpu_strikes"] = now, 0
            do_act(login, uid, "renice", "cpu %.0f%% > %.0f%%" % (pcpu, line))
            alert("runaway", "cpu", "renice", "%.0f%% CPU over its %.0f%% (%g cores)" % (pcpu, line, lim["cpu"]))
        elif st.get("reniced") and st["cpu_strikes"] >= env_num("FLEET_TRIAL_PAUSE_STRIKES", 5):
            st["paused"] = paused = "cpu"
            do_act(login, uid, "pause", "cpu %.0f%% still over after renice" % pcpu)
            alert("runaway", "cpu", "pause", "%.0f%% CPU still over its %.0f%% after the renice" % (pcpu, line))
    elif not paused:
        st["cpu_strikes"] = 0
        st["under"] = st.get("under", 0) + 1
        if st.get("reniced") and st["under"] >= env_num("FLEET_TRIAL_CLEAR_PASSES", 5):
            st.pop("reniced", None)
            alert("runaway", "cpu", "resume", "back under its share")
            alerts[-1]["clear"] = True

    # disk: every FLEET_TRIAL_DISK_EVERY, its home
    if home and now - st.get("disk_at", 0) >= env_num("FLEET_TRIAL_DISK_EVERY", 600):
        st["disk_at"] = now
        n = home_bytes(home)
        if n is not None:
            st["disk"] = n
            if n > lim["disk"] * 1.2 and paused != "disk" and not paused:
                st["paused"] = paused = "disk"
                do_act(login, uid, "pause", "home %s > 120%% of %s" % (gib(n), gib(lim["disk"])))
                alert("runaway", "disk", "pause", "home %s, over 120%% of its %s" % (gib(n), gib(lim["disk"])))
            elif n > lim["disk"] and not st.get("disk_warned"):
                st["disk_warned"] = now
                alert("runaway", "disk", "warn", "home %s over its %s" % (gib(n), gib(lim["disk"])))
            elif n <= lim["disk"]:
                st.pop("disk_warned", None)

    # a paused login stays paused: a process it started since (a new ssh) stops too
    if paused:
        do_act(login, uid, "pause", "held: %s" % paused)
    return alerts


def mem_lines(lst, accts):
    """mem.tsv for memguard: uid · limit MB · login."""
    mb = int(lst.get("mem_bytes") or 0) // (1 << 20)
    rows = ["%d\t%d\t%s" % (accts[l][0], mb, l) for l in sorted(accts)] if mb > 0 and lst.get("on") else []
    write_file(path("mem.tsv"), "".join(r + "\n" for r in rows), 0o644)


def mem_events():
    """Alerts for what memguard stopped since the last pass."""
    p, out = path("mem-events.tsv"), []
    try:
        with open(p) as f:
            lines = f.read().splitlines()
        os.unlink(p)
    except OSError:
        return out
    for line in lines:
        f = line.split("\t")
        if len(f) >= 6:
            out.append({"login": f[2], "kind": "runaway", "what": "mem", "action": "kill",
                        "detail": "pid %s at %s MB stopped; the login held %s MB over its line" % (f[3], f[4], f[5])})
    return out


def tick():
    os.makedirs(state_dir(), 0o755, exist_ok=True)
    now = int(time.time())
    lst, err = pull_list()
    state = read_json(path("state.json"), {}) or {}
    logins = state.setdefault("logins", {})
    pending = state.get("pending") or []
    on = bool(lst and lst.get("on"))
    named = ((lst or {}).get("logins") or {}) if on else {}
    lim = {"cpu": float((lst or {}).get("cpu") or 4), "mem": int((lst or {}).get("mem_bytes") or 8 << 30),
           "disk": int((lst or {}).get("disk_bytes") or 20 << 30)}

    # a login the hub no longer names (转正, ended, off) is put back as it was
    for login in sorted(set(logins) - set(named)):
        st = logins.pop(login)
        a = account(login)
        if a and (st.get("paused") or st.get("reniced")):
            do_act(login, a[0], "resume", "no longer a trial login")

    accts = {}
    for login in sorted(named):
        a = account(login)
        if a is None or a[0] < env_num("FLEET_TRIAL_MIN_UID", 500) or a[0] == 0:
            continue
        accts[login] = a
    if lst is not None:
        mem_lines(lst if on else {}, accts)
    rows = fleet_trial.ps_rows() if accts else []
    for login, (uid, home) in sorted(accts.items()):
        pending += judge(login, uid, home, lim, rows, logins.setdefault(login, {}), now)
    pending += mem_events()

    kept = [a for a in pending if not send_alert(a)][-50:]
    state.update(pending=kept, at=now)
    write_json(path("state.json"), state)
    status = {"at": now, "on": on, "limits": (lst or {}).get("limits") or "", "error": err,
              "logins": sorted(accts), "unsent": len(kept),
              "paused": {l: s["paused"] for l, s in logins.items() if s.get("paused")},
              "reniced": sorted(l for l, s in logins.items() if s.get("reniced"))}
    write_json(path("status.json"), status, 0o644)
    return 0


def resume(login):
    state = read_json(path("state.json"), {}) or {}
    st = (state.get("logins") or {}).get(login)
    a = account(login)
    if a is None:
        print("no login %s here" % login, file=sys.stderr)
        return 1
    print(do_act(login, a[0], "resume", "by hand"))
    if st is not None:
        for k in ("paused", "reniced", "cpu_strikes", "disk_warned"):
            st.pop(k, None)
        st["disk_at"] = 0
        for kind, what in (("runaway", "cpu"), ("abuse", "miner")):
            state.setdefault("pending", []).append({"login": login, "kind": kind, "what": what,
                                                    "action": "resume", "clear": True})
        write_json(path("state.json"), state)
    return 0


def check():
    s = read_json(path("status.json"), None)
    if s is None:
        print("trial-limits: INFO — no trial guard ran here (not a managed machine)")
        return 0
    age = int(time.time()) - int(s.get("at") or 0)
    head = "%s · 试用登录 %d 个" % (s.get("limits") or "?", len(s.get("logins") or []))
    if not s.get("on"):
        print("trial-limits: OK — off on the hub (fleet.trial.limits) · 上次巡检 %d 秒前" % age)
        return 0
    if age > env_num("FLEET_TRIAL_STALE_SECS", 300):
        print("trial-limits: WARN — %s · 上次巡检 %d 分钟前（trial-guard 任务没在跑？）" % (head, age // 60))
        return 1
    paused = s.get("paused") or {}
    if paused:
        print("trial-limits: WARN — %s · 已暂停 %s · 解除：fleet-trial-guard.py resume <login>"
              % (head, ", ".join("%s（%s）" % (l, w) for l, w in sorted(paused.items()))))
        return 1
    if s.get("error"):
        print("trial-limits: WARN — %s · 名单取不到：%s（用上次的）" % (head, s["error"]))
        return 1
    extra = (" · 已降优先级 " + ", ".join(s["reniced"])) if s.get("reniced") else ""
    print("trial-limits: OK — %s%s · 上次巡检 %d 秒前" % (head, extra, age))
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "tick":
        return tick()
    if cmd == "check":
        return check()
    if cmd == "status":
        print(json.dumps(read_json(path("status.json"), {}), indent=1, sort_keys=True))
        return 0
    if cmd == "resume" and len(argv) == 3:
        return resume(argv[2])
    print(__doc__.split("Usage:")[1].split("Files")[0].rstrip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
