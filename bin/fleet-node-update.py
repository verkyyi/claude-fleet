#!/usr/bin/env python3
"""fleet-node-update.py — the machine's ONE updater (issue #2334, EPIC #2329 C6).

The machine daemon (fleet-node-supervisor.py, C3) runs `tick` as its `update`
task. One tick brings EVERY part of a managed machine to the release the hub
names — or leaves every part where it was:

  runtime    /Library/Application Support/claude-fleet/<sha>/ — the release tree
             the hub signed (C7, `ccquota release fetch --artifacts`, the pinned
             key in <state>/release.pub, the hub only — never GitHub)
  ccquota    <sha>/bin/ccquota — the release's ccquota-<os>-<arch> artifact; the
             node program (C5) runs it from `current`
  claude · codex · tmux
             the versions release.json pins, each the release's artifact,
             installed once into the root cache <root>/tools/<name>/<sha256>/ and
             linked from <sha>/tools/bin/<name>; every managed account's
             ~/.local/bin/{claude,codex} (and the vendor tmux) point at
             <root>/current/tools/bin/<name> — linked by a process demoted to
             that account, re-linked every tick, never over a regular file
  cache      the bootstrap cache's Claude Code (<root>/cache/claude/<ver>, what a
             NEW account installs from — fleet-bootstrap-cache.sh)
  credsep    the shared credential proxy's root-owned code copy (LIB,
             /Library/Application Support/claude-fleet/credsep) is refreshed from
             <current>/bin by `fleet-credsep.py machine refresh`, and the proxy
             restarts on it — launchd's, or the daemon's child (its `reload`)
             (issue #2435)
  supervisor the daemon itself: it runs from `current`, so it is the LAST step —
             the tick asks it to restart (<state>/update-restart.json) and
             launchd's KeepAlive starts the new one

All of them hang off ONE link: `current` → <sha> moves by one rename(2), and
`.prev` names the version before. So a machine is never half old, half new.

A tick, in order (each a `result` in <state>/update.json, one log line):

  resume      a tick killed half way picks up where the state says:
              switching → finish the switch; switched → verify; rolling-back →
              finish the rollback. A staged dir without its `staged.json` mark
              is deleted and fetched again.
  target      FLEET_NODE_UPDATE_TARGET, else expected.json's `release` (C2's
              desired state), else the hub's /version `stable`. None → `unknown`.
  current     target == current → nothing to switch (account links and the
              cache are still checked — a Claude Code that updated itself is
              put back).
  skipped     target is the version the doctor rejected (`skip`) — not retried
              until the target moves. No flapping.
  backoff     the last stage of this target failed less than
              FLEET_NODE_UPDATE_RETRY (3600) seconds ago.
  deferred    a running EPIC batch WITH WORK holds the machine (issue #2247's
              rule: fleet_epic_holding over every managed account's marks),
              for at most FLEET_EPIC_HOLD_CAP_SECS (7200); past the cap the tick
              goes on (`hold released` in the log).
  failed      staging failed (fetch, signature, a missing artifact, release.json
              invalid) — nothing switched; the staged dir is removed.
  switched    staged → the doctor's FAIL rows on the OLD version kept as the
              baseline → `.prev` = old, `current` = new, cache + account links,
              the restart request. The NEXT tick (the new code, after
              FLEET_NODE_UPDATE_SETTLE seconds) runs the machine doctor:
  committed   no FAIL row the baseline did not have.
  rolled-back a new FAIL row → `current` = old, `.prev` = the rejected one,
              cache + links back, the restart request, `skip: <sha>`.

Usage:
  fleet-node-update.py tick                 one pass (what the daemon runs)
  fleet-node-update.py status [--json] [--check]
                                            where it is; --check: 0 settled · 1 a
                                            failure / rollback / stuck · 2 not set up
  fleet-node-update.py doctor               the machine doctor: PASS/WARN/FAIL rows,
                                            exit = the FAIL count (`fleet doctor --machine`)
  fleet-node-update.py versions             one line: every part's version vs release.json
  fleet-node-update.py check-release <file|->  validate a release.json (fleet-stable.sh move)
  fleet-node-update.py pinned-artifacts <file|-> [<os>-<arch>…]
                                            the artifact names it pins, one a line
                                            (default darwin-arm64; fleet-stable.sh gate 7)
  fleet-node-update.py link-account <login> (internal: run demoted to <login>)

Seams (sandbox tests, docs/BREAK-IT.md `node-update-half`): the supervisor's
FLEET_NODE_STATE / FLEET_NODE_RUNTIME / FLEET_NODE_TEST / FLEET_NODE_PASSWD /
FLEET_NODE_USERS, plus
  FLEET_NODE_ROOT            the runtime root (default: FLEET_NODE_RUNTIME's dir)
  FLEET_NODE_CCQUOTA         the ccquota that fetches (default <current>/bin/ccquota, else PATH)
  FLEET_NODE_UPDATE_TARGET   the release to go to, instead of asking
  FLEET_NODE_UPDATE_SETTLE   seconds between the switch and the verify (30)
  FLEET_NODE_UPDATE_PLATFORM `<os>-<arch>` of the artifacts (default this machine's)
  FLEET_NODE_UPDATE_KEEP_SECS how long a retired version stays (604800)
  FLEET_NODE_UPDATE_LIB      the fleet-lib.sh the EPIC gate sources (default <current>/bin)
"""
from __future__ import print_function

import fcntl
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fleet_node_supervisor", os.path.join(HERE, "fleet-node-supervisor.py"))
fns = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fns)

env = fns.env
env_num = fns.env_num
read_json = fns.read_json
write_json = fns.write_json
now = fns.now
iso = fns.iso

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
VER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$")
ART_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+{}-]{0,127}$")
TOOLS = ("claude", "codex", "tmux")
# where a managed account finds each pinned tool (what fleet_find_tool tries first)
ACCOUNT_LINKS = {
    "claude": ".local/bin/claude",
    "codex": ".local/bin/codex",
    "tmux": ".local/share/claude-fleet-vendor/bin/tmux",
}
CREDSEP_CODE = ("fleet-cred-proxy.py", "fleet-credsep-launch.py")   # what machine refresh copies to LIB
RELEASE_FILE = "release.json"
STAGED = ".release/staged.json"


# --------------------------------------------------------------- release.json ---
def check_release(spec):
    """The ONE validator of release.json: returns the normalised spec or raises
    ValueError. fleet-stable.sh move refuses a target whose tree fails it."""
    if not isinstance(spec, dict):
        raise ValueError("not a JSON object")
    if spec.get("schema") != 1:
        raise ValueError("schema must be 1")
    comps = spec.get("components")
    if not isinstance(comps, dict):
        raise ValueError("components: missing")
    unknown = set(spec) - {"schema", "components", "note"}
    if unknown:
        raise ValueError("unknown field(s): %s" % ", ".join(sorted(unknown)))
    out = {}
    for name in ("ccquota", "claude", "codex", "tmux", "supervisor"):
        c = comps.get(name)
        if not isinstance(c, dict):
            raise ValueError("components.%s: missing" % name)
        out[name] = c
    for name in set(comps) - set(out):
        raise ValueError("components.%s: unknown component" % name)
    if not ART_RE.match(str(out["ccquota"].get("artifact", ""))):
        raise ValueError("components.ccquota.artifact: a name like ccquota-{os}-{arch}")
    for name in TOOLS:
        c = out[name]
        if not VER_RE.match(str(c.get("version", ""))):
            raise ValueError("components.%s.version: missing or not a version" % name)
        if not ART_RE.match(str(c.get("artifact", ""))):
            raise ValueError("components.%s.artifact: a name like %s-{version}-{os}-{arch}" % (name, name))
    if out["tmux"].get("lock") is not None and not str(out["tmux"]["lock"]).startswith("conf/"):
        raise ValueError("components.tmux.lock: a conf/ path")
    if out["supervisor"].get("script") != "bin/fleet-node-supervisor.py":
        raise ValueError("components.supervisor.script: bin/fleet-node-supervisor.py")
    return spec


DRILL_FAIL = "conf/drill-fail"   # fleet-node-drill.sh's rollback release (issue #2336)


def platform_id():
    p = env("FLEET_NODE_UPDATE_PLATFORM", "")
    if p:
        return p.split("-", 1)
    osn = platform.system().lower()
    m = platform.machine().lower()
    arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(m, m)
    return [osn, arch]


def artifact_name(tmpl, version="", plat=None):
    osn, arch = plat or platform_id()
    return tmpl.replace("{version}", version).replace("{os}", osn).replace("{arch}", arch)


def pinned_artifacts(spec, plats):
    """Every artifact name release.json pins, expanded for each "<os>-<arch>"
    in plats — what the hub's CCQUOTA_FLEET_RELEASE_ARTIFACTS (and dist dir)
    must hold before stable moves (fleet-stable.sh gate 7, issue #2631)."""
    c = check_release(spec)["components"]
    out = []
    for p in plats:
        plat = p.split("-", 1)
        out.append(artifact_name(c["ccquota"]["artifact"], "", plat))
        for t in TOOLS:
            out.append(artifact_name(c[t]["artifact"], c[t]["version"], plat))
    return sorted(set(out))


def wanted(spec):
    """{component: version-or-''} as release.json declares it."""
    c = spec["components"]
    return {"ccquota": "", "claude": c["claude"]["version"], "codex": c["codex"]["version"],
            "tmux": c["tmux"]["version"]}


# --------------------------------------------------------------- paths ----------
class P(object):
    def __init__(self):
        self.sup = fns.Paths()
        self.state = self.sup.state
        self.root = env("FLEET_NODE_ROOT", os.path.dirname(self.sup.runtime.rstrip("/")))
        self.current = os.path.join(self.root, "current")
        self.prev = os.path.join(self.root, ".prev")
        self.tools = os.path.join(self.root, "tools")
        cache = env("FLEET_BOOTSTRAP_CACHE", os.path.join(self.root, "cache"))
        self.cache = None if cache == "off" else cache
        self.file = os.path.join(self.state, "update.json")
        self.request = os.path.join(self.state, "update-restart.json")
        self.pubkey = os.path.join(self.state, "release.pub")
        self.machine_env = os.path.join(self.state, "machine.env")
        self.lock = os.path.join(self.state, "locks", "update-self.lock")
        self.log = os.path.join(self.sup.log, "update.log")

    def rel(self, sha):
        return os.path.join(self.root, sha)


def credsep_rec():
    """The shared credential proxy's record (fleet-credsep.py's .shared.json), or
    None: no shared proxy on this machine."""
    r = read_json(os.path.join(env("FLEET_CREDSEP_ROOT_BASE", "/var/db/fleet-cred"), ".shared.json"), None)
    return r if isinstance(r, dict) and r.get("shared") and r.get("lib") else None


def link_sha(path):
    """The release sha a link names, or None."""
    try:
        t = os.readlink(path)
    except OSError:
        return None
    b = os.path.basename(t.rstrip("/"))
    return b if SHA_RE.match(b) else None


def swap_link(path, target):
    """Point <path> at <target> with ONE rename(2) — never a moment without it."""
    tmp = "%s.tmp-%d" % (path, os.getpid())
    try:
        os.remove(tmp)
    except OSError:
        pass
    os.symlink(target, tmp)
    os.rename(tmp, path)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def hub_url(p):
    for line in _read_lines(p.machine_env):
        if line.startswith("CCQUOTA_HUB_URL="):
            return line.split("=", 1)[1].strip().strip('"\'')
    return env("FLEET_HUB_URL", "")


def _read_lines(path):
    try:
        with open(path) as f:
            return f.read().splitlines()
    except (IOError, OSError):
        return []


def ccquota_bin(p):
    c = env("FLEET_NODE_CCQUOTA", "")
    if c:
        return c
    c = os.path.join(p.current, "bin", "ccquota")
    if os.path.exists(c):
        return c
    return shutil.which("ccquota") or ""


def run(cmd, timeout=600, **kw):
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout, **kw)
        return r.returncode, (r.stdout or "").strip(), (r.stderr or "").strip()
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", str(e)


# --------------------------------------------------------------- the state ------
class Updater(object):
    def __init__(self, p):
        self.p = p
        self.st = read_json(p.file, {}) or {}
        self.st.setdefault("phase", "idle")
        self.st.setdefault("skip", {})
        self.st.setdefault("failed", {})
        self.st.setdefault("retired", {})
        self.st.setdefault("history", [])

    def save(self):
        if not os.path.isdir(self.p.state):
            os.makedirs(self.p.state)
        write_json(self.p.file, self.st)

    def log(self, msg):
        line = "%s %s" % (iso(now()), msg)
        print(line)
        try:
            os.makedirs(os.path.dirname(self.p.log), exist_ok=True)
            with open(self.p.log, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass

    def end(self, result, reason="", **kw):
        self.st.update(result=result, reason=reason, at=now(), **kw)
        self.save()
        self.log("%s%s" % (result, (" — " + reason) if reason else ""))
        return 0

    def record(self, result, frm, to, reason=""):
        self.st["history"] = (self.st["history"] + [{"at": now(), "result": result, "from": frm,
                                                      "to": to, "reason": reason}])[-20:]

    # -- target
    def target(self):
        t = env("FLEET_NODE_UPDATE_TARGET", "")
        if t:
            return t, "FLEET_NODE_UPDATE_TARGET"
        ex = read_json(self.p.sup.expected, None)
        if isinstance(ex, dict) and SHA_RE.match(str(ex.get("release") or "")):
            return ex["release"], "expected.json"
        hub = hub_url(self.p)
        if not hub:
            return None, "no hub (machine.env has no CCQUOTA_HUB_URL)"
        rc, out, err = run(["/usr/bin/curl", "-fsS", "--max-time", "20", hub.rstrip("/") + "/version"], timeout=30)
        try:
            s = json.loads(out).get("stable") if rc == 0 else None
        except ValueError:
            s = None
        if s and SHA_RE.match(s):
            return s, "hub stable"
        return None, "the hub named no stable (%s)" % (err or out or "rc %d" % rc)[:120]

    # -- the EPIC gate (#2062 / #2247): any managed account's batch with work holds
    def epic_hold(self, target):
        lib = env("FLEET_NODE_UPDATE_LIB", os.path.join(self.p.current, "bin", "fleet-lib.sh"))
        if not os.path.exists(lib):
            return None
        held = []
        for login, why in fns.managed_accounts(self.p.sup).items():
            ident = fns.account_ident(login)
            if why or ident is None:
                continue
            conf = os.path.join(ident[2], ".config", "claude-fleet")
            rc, out, _ = run(["/bin/bash", "-c", '. "$1" >/dev/null 2>&1 || exit 2; fleet_epic_holding', "x", lib],
                             timeout=30, env=dict(os.environ, FLEET_CONF_DIR=conf, HOME=ident[2]))
            if rc == 0:
                held.append("%s: %s" % (login, (out.splitlines() or ["?"])[0][:120]))
        if not held:
            self.st.pop("hold", None)
            return None
        h = self.st.get("hold") or {}
        if h.get("target") != target:
            h = {"target": target, "since": now()}
            self.st["hold"] = h
        cap = env_num("FLEET_EPIC_HOLD_CAP_SECS", 7200)
        if now() - h["since"] > cap:
            if not h.get("released"):
                h["released"] = now()
                self.log("hold released — an EPIC batch held %s for more than %ds: %s"
                         % (target[:12], int(cap), "; ".join(held)))
            return None
        return "; ".join(held)

    # -- staging: fetch, check, install the pinned tools; `staged.json` = whole
    def stage(self, sha):
        d = self.p.rel(sha)
        mark = os.path.join(d, STAGED)
        if os.path.exists(mark):
            return read_json(mark, {})
        if os.path.lexists(d):
            self.log("staged dir %s has no %s — a stage was cut short; fetching again" % (sha[:12], STAGED))
            shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(d + ".partial", ignore_errors=True)
        cq = ccquota_bin(self.p)
        hub = hub_url(self.p)
        if not cq:
            raise StageError("no ccquota to fetch with")
        if not hub:
            raise StageError("no hub URL (machine.env)")
        if not os.path.exists(self.p.pubkey):
            raise StageError("no pinned release key (%s) — `fleet node install` pins it" % self.p.pubkey)
        os.makedirs(self.p.root, exist_ok=True)
        rc, out, err = run([cq, "release", "fetch", "--hub", hub, "--pubkey", self.p.pubkey, "--artifacts", sha, d],
                           timeout=1500)
        if rc != 0:
            shutil.rmtree(d, ignore_errors=True)
            raise StageError("fetch: %s" % (err or out or "rc %d" % rc).splitlines()[-1][:200])
        try:
            try:
                spec = check_release(read_json(os.path.join(d, RELEASE_FILE), None))
            except ValueError as e:
                raise StageError("release.json: %s" % e)
            man = read_json(os.path.join(d, ".release", "manifest.json"), {}) or {}
            if man.get("sha") != sha:
                raise StageError("the fetched manifest is %s, not %s" % (man.get("sha"), sha))
            arts = {a["name"]: a for a in man.get("artifacts") or []}
            comps = spec["components"]
            got = {"release": sha}
            # ccquota: inside the release, so `current` carries it
            name = artifact_name(comps["ccquota"]["artifact"])
            src = self.art(d, arts, name)
            dst = os.path.join(d, "bin", "ccquota")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst + ".tmp")
            os.chmod(dst + ".tmp", 0o755)
            os.rename(dst + ".tmp", dst)
            got["ccquota"] = arts[name]["sha256"]
            # claude / codex / tmux: the root cache, content-addressed; the release links it
            bind = os.path.join(d, "tools", "bin")
            os.makedirs(bind, exist_ok=True)
            for tool in TOOLS:
                name = artifact_name(comps[tool]["artifact"], comps[tool]["version"])
                src = self.art(d, arts, name)
                h = arts[name]["sha256"]
                tdir = os.path.join(self.p.tools, tool, h)
                tbin = os.path.join(tdir, tool)
                if not (os.path.exists(tbin) and sha256_file(tbin) == h):
                    os.makedirs(tdir, exist_ok=True)
                    shutil.copyfile(src, tbin + ".tmp")
                    os.chmod(tbin + ".tmp", 0o755)
                    os.rename(tbin + ".tmp", tbin)
                swap_link(os.path.join(bind, tool), tbin)
                got[tool] = comps[tool]["version"]
            got["at"] = now()
            write_json(mark, got)
            return got
        except StageError:
            shutil.rmtree(d, ignore_errors=True)
            raise
        except (OSError, KeyError) as e:
            shutil.rmtree(d, ignore_errors=True)
            raise StageError("stage: %s" % e)

    def art(self, d, arts, name):
        if name not in arts:
            raise StageError("the release ships no %s (put it in the hub's CCQUOTA_FLEET_RELEASE_ARTIFACTS)" % name)
        src = os.path.join(d, ".release", "artifacts", name)
        if not os.path.exists(src) or sha256_file(src) != arts[name]["sha256"]:
            raise StageError("%s: digest does not match the signed manifest" % name)
        return src

    # -- the parts outside `current`: the bootstrap cache + account links
    def sync_outside(self):
        notes = []
        spec = read_json(os.path.join(self.p.current, RELEASE_FILE), None)
        try:
            spec = check_release(spec)
        except ValueError:
            return ["no valid release.json under current"]
        cl = os.path.join(self.p.current, "tools", "bin", "claude")
        ver = spec["components"]["claude"]["version"]
        if self.p.cache and os.path.exists(cl):
            try:
                cd = os.path.join(self.p.cache, "claude")
                vd = os.path.join(cd, ver)
                vb = os.path.join(vd, "claude")
                if not (os.path.exists(vb) and sha256_file(vb) == sha256_file(cl)):
                    os.makedirs(vd, exist_ok=True)
                    shutil.copyfile(cl, vb + ".tmp")
                    os.chmod(vb + ".tmp", 0o755)
                    os.rename(vb + ".tmp", vb)
                if _read_lines(os.path.join(cd, "current"))[:1] != [ver]:
                    with open(os.path.join(cd, "current.tmp"), "w") as f:
                        f.write(ver + "\n")
                    os.chmod(os.path.join(cd, "current.tmp"), 0o644)
                    os.rename(os.path.join(cd, "current.tmp"), os.path.join(cd, "current"))
                for o in os.listdir(cd):
                    if o not in (ver, "current") and os.path.isdir(os.path.join(cd, o)):
                        shutil.rmtree(os.path.join(cd, o), ignore_errors=True)
                for dd in (self.p.cache, cd, vd):
                    os.chmod(dd, 0o755)
            except OSError as e:
                notes.append("cache: %s" % e)
        for login, why in fns.managed_accounts(self.p.sup).items():
            ident = fns.account_ident(login)
            if why or ident is None:
                continue
            uid, gid, home = ident
            if uid == 0 or (os.geteuid() != 0 and uid != os.geteuid()):
                notes.append("%s: needs root to link" % login)
                continue
            rc, out, err = run([sys.executable, "-I", os.path.abspath(__file__), "link-account", login],
                               timeout=60, preexec_fn=fns.demote(login, uid, gid, home),
                               env={"HOME": home, "USER": login, "LOGNAME": login, "PATH": "/usr/bin:/bin",
                                    "FLEET_NODE_ROOT": self.p.root})
            if rc != 0:
                notes.append("%s: %s" % (login, (err or out)[:120]))
        return notes

    # -- credsep's code copy follows `current` (issue #2435, EPIC #2329 共同约定 3)
    def sync_credsep(self):
        """`<current>/bin/fleet-credsep.py machine refresh`: LIB's copy = this
        release's, and the proxy restarted on it when the bytes moved. -> notes."""
        cs = os.path.join(self.p.current, "bin", "fleet-credsep.py")
        if not credsep_rec() or not os.path.exists(cs):
            return []
        rc, out, err = run([sys.executable, "-I", cs, "machine", "refresh"], timeout=180)
        if rc == 3:
            return []
        last = ([l for l in out.splitlines() if l.startswith("shared:")] or [""])[-1]
        if rc != 0:
            return ["credsep: machine refresh rc %d %s" % (rc, (err or out).strip()[-160:])]
        if last and not last.startswith("shared: current"):
            self.log("credsep: %s" % last)
        return []

    # -- the sessions ride through a switch (issue #2484, EPIC #2482 C5)
    def sessions(self, verb, sha):
        """`<release sha>/bin/fleet-sessions-snapshot.sh save|restore` for every
        managed account, demoted to it with its own TMPDIR (so its tmux socket):
        pinned before the switch, brought back and checked after. -> notes."""
        if env_num("FLEET_NODE_UPDATE_SESSIONS", 1) == 0 or not sha:
            return []
        sc = os.path.join(self.p.rel(sha), "bin", "fleet-sessions-snapshot.sh")
        if not os.path.exists(sc):
            return []
        notes = []
        tb = os.path.join(self.p.rel(sha), "tools", "bin")
        for login, why in fns.managed_accounts(self.p.sup).items():
            ident = fns.account_ident(login)
            if why or ident is None:
                continue
            uid, gid, home = ident
            if uid == 0 or (os.geteuid() != 0 and uid != os.geteuid()):
                continue
            rc, out, err = run(["/bin/sh", "-c", SESSIONS_SH, "fleet-sessions",
                                "/bin/bash", sc, verb],
                               timeout=600, preexec_fn=fns.demote(login, uid, gid, home),
                               env={"HOME": home, "USER": login, "LOGNAME": login, "LANG": "en_US.UTF-8",
                                    "PATH": "%s:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" % tb,
                                    "FLEET_CONF_DIR": os.path.join(home, ".config", "claude-fleet")})
            if verb == "save":
                msg = (out.strip().splitlines() or [""])[-1]
            else:
                rows = [l.split("\t") for l in out.splitlines() if "\t" in l]
                msg = "%d back" % sum(1 for r in rows if r[0] == "back")
                miss = [r[2] for r in rows if r[0] == "missing" and len(r) > 2]
                if miss:
                    msg += ", missing: %s" % " ".join(miss)
            self.log("sessions %s %s: rc %d %s" % (verb, login, rc, msg or (err or "").strip()[-160:]))
            if rc not in (0, 3):
                notes.append("sessions %s %s: rc %d %s" % (verb, login, rc, msg))
        return notes

    # -- the switch, the verify, the rollback
    def request_restart(self, sha):
        write_json(self.p.request, {"to": sha, "at": now()})

    def switch(self):
        frm, to = self.st.get("from"), self.st["to"]
        if frm and os.path.isdir(self.p.rel(frm)):
            swap_link(self.p.prev, self.p.rel(frm))
        swap_link(self.p.current, self.p.rel(to))
        notes = self.sync_outside() + self.sync_credsep()
        self.st.update(phase="switched", switched_at=now(), notes=notes)
        if frm:
            self.st["retired"][frm] = now()
        self.st["retired"].pop(to, None)
        self.save()
        self.log("switched %s → %s%s" % ((frm or "none")[:12], to[:12], (" · " + "; ".join(notes)) if notes else ""))
        self.request_restart(to)

    def rollback(self, why):
        frm, to = self.st.get("from"), self.st["to"]
        swap_link(self.p.current, self.p.rel(frm))
        swap_link(self.p.prev, self.p.rel(to))
        self.sync_outside()
        self.sync_credsep()
        self.st["skip"] = {to: {"at": now(), "reason": why}}
        self.st["retired"][to] = now()
        self.st["retired"].pop(frm, None)
        self.record("rolled-back", frm, to, why)
        self.st.update(phase="idle")
        self.sessions("restore", frm)
        self.end("rolled-back", "%s → back to %s: %s" % (to[:12], frm[:12], why), current=frm)
        self.request_restart(frm)
        return 0

    def verify(self):
        t0 = self.st.get("switched_at") or 0
        settle = env_num("FLEET_NODE_UPDATE_SETTLE", 30)
        if now() - t0 < settle:
            return self.end("switched", "verifying %s after %ds" % (self.st["to"][:12], int(settle)))
        # a switch made by an updater from before #2435 left the copy behind:
        # refresh before judging, or this version's own credsep row rolls it back
        self.sync_credsep()
        rows = doctor_rows(self.p)
        fails = sorted(set(r[1] for r in rows if r[0] == "FAIL"))
        new = [f for f in fails if f not in (self.st.get("baseline") or [])]
        if new and self.st.get("from"):
            detail = "; ".join("%s %s" % (r[1], r[2]) for r in rows if r[0] == "FAIL" and r[1] in new)
            self.st["phase"] = "rolling-back"
            self.st["rollback_reason"] = "new FAIL: %s" % detail
            self.save()
            return self.rollback(self.st["rollback_reason"])
        self.record("committed", self.st.get("from"), self.st["to"], "; ".join(new))
        self.st.update(phase="idle", current=self.st["to"])
        self.sessions("restore", self.st["to"])
        self.prune()
        return self.end("committed", "%s%s" % (self.st["to"][:12],
                                              (" (no previous version to go back to; FAIL: %s)" % ", ".join(new)) if new else ""))

    def prune(self):
        keep = {link_sha(self.p.current), link_sha(self.p.prev)}
        ttl = env_num("FLEET_NODE_UPDATE_KEEP_SECS", 604800)
        for sha, at in list(self.st["retired"].items()):
            if sha in keep or now() - at < ttl:
                continue
            shutil.rmtree(self.p.rel(sha), ignore_errors=True)
            del self.st["retired"][sha]
            self.log("removed retired version %s" % sha[:12])
        used = set()
        for e in os.listdir(self.p.root) if os.path.isdir(self.p.root) else []:
            bd = os.path.join(self.p.root, e, "tools", "bin")
            if SHA_RE.match(e) and os.path.isdir(bd):
                for t in os.listdir(bd):
                    try:
                        used.add(os.path.realpath(os.path.join(bd, t)))
                    except OSError:
                        pass
        for tool in TOOLS:
            td = os.path.join(self.p.tools, tool)
            for h in os.listdir(td) if os.path.isdir(td) else []:
                if os.path.join(os.path.realpath(td), h, tool) not in used:
                    shutil.rmtree(os.path.join(td, h), ignore_errors=True)

    # -- one tick
    def tick(self):
        ph = self.st["phase"]
        if ph == "switching":
            self.log("resuming a switch to %s cut short" % self.st["to"][:12])
            self.switch()
            return 0
        if ph == "switched":
            return self.verify()
        if ph == "rolling-back":
            self.log("resuming a rollback of %s cut short" % self.st["to"][:12])
            self.rollback(self.st.get("rollback_reason") or "resumed")
            return 0
        cur = link_sha(self.p.current)
        target, src = self.target()
        if not target:
            return self.end("unknown", src, current=cur)
        if not SHA_RE.match(target):
            return self.end("unknown", "%s is not a commit sha (%s)" % (target, src), current=cur)
        if target == cur:
            notes = self.sync_outside() + self.sync_credsep()
            self.st.pop("hold", None)
            return self.end("current", "%s (%s)%s" % (cur[:12], src, (" · " + "; ".join(notes)) if notes else ""),
                            current=cur, notes=notes)
        if target in self.st["skip"]:
            return self.end("skipped", "%s was rolled back: %s" % (target[:12], self.st["skip"][target].get("reason", "")),
                            current=cur)
        f = self.st["failed"].get(target) or {}
        if f and now() - f.get("at", 0) < env_num("FLEET_NODE_UPDATE_RETRY", 3600):
            return self.end("backoff", "%s failed %s: %s" % (target[:12], iso(f["at"]), f.get("reason", "")), current=cur)
        hold = self.epic_hold(target)
        if hold:
            return self.end("deferred", "an EPIC batch with work: %s" % hold, current=cur)
        try:
            self.stage(target)
        except StageError as e:
            self.st["failed"] = {target: {"at": now(), "reason": str(e)}}
            self.record("failed", cur, target, str(e))
            return self.end("failed", "%s: %s" % (target[:12], e), current=cur)
        self.st["failed"].pop(target, None)
        baseline = sorted(set(r[1] for r in doctor_rows(self.p) if r[0] == "FAIL")) if cur else []
        self.sessions("save", target)
        self.st.update(phase="switching", **{"from": cur, "to": target, "baseline": baseline})
        self.save()
        self.switch()
        return 0


# the login's own TMPDIR, as the supervisor's account units get it (issue #2450)
SESSIONS_SH = ('TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; '
               '[ -n "$TMPDIR" ] || TMPDIR="/tmp/claude-fleet-$(id -u)"; export TMPDIR; exec "$@"')


class StageError(Exception):
    pass


# --------------------------------------------------------------- the doctor -----
def tool_version(path, args):
    rc, out, err = run([path] + args, timeout=30)
    return rc, ((out or err).splitlines() or [""])[0][:80]


def doctor_rows(p):
    """[(LEVEL, row, message)] — the machine half of `fleet doctor`. FAIL = a part
    that does not work or is not the release's; the updater's rollback gate."""
    rows = []
    cur = link_sha(p.current)
    if not cur:
        if not os.path.lexists(p.current):
            return [("WARN", "runtime", "no %s — this machine has no root runtime (not managed)" % p.current)]
        return [("FAIL", "runtime", "%s does not name a release" % p.current)]
    d = p.rel(cur)
    try:
        spec = check_release(read_json(os.path.join(d, RELEASE_FILE), None))
    except ValueError as e:
        return [("FAIL", "runtime", "%s: release.json %s" % (cur[:12], e))]
    if not os.path.exists(os.path.join(d, STAGED)):
        rows.append(("FAIL", "runtime", "%s was never staged whole (no %s)" % (cur[:12], STAGED)))
    else:
        rows.append(("PASS", "runtime", "%s · release.json schema 1" % cur[:12]))
    rc, v = tool_version(os.path.join(p.current, "bin", "ccquota"), ["version"])
    rows.append(("PASS", "ccquota", v) if rc == 0 else ("FAIL", "ccquota", "bin/ccquota version: rc %d %s" % (rc, v)))
    for tool in TOOLS:
        want = spec["components"][tool]["version"]
        tb = os.path.join(p.current, "tools", "bin", tool)
        rc, v = tool_version(tb, ["-V"] if tool == "tmux" else ["--version"])
        if rc == 0 and want in v:
            rows.append(("PASS", tool, "%s (release.json %s)" % (v, want)))
        else:
            rows.append(("FAIL", tool, "release.json pins %s, %s answers rc %d %s" % (want, tb, rc, v)))
    st = read_json(p.sup.state_file, {}) or {}
    code, word = fns.health(p.sup, st)
    if code == 2:
        rows.append(("WARN", "daemon", "com.claude-fleet.node not installed"))
    elif code == 1:
        rows.append(("FAIL", "daemon", word))
    else:
        rt = (st.get("supervisor") or {}).get("runtime")
        if rt and rt != cur:
            rows.append(("FAIL", "daemon", "running %s, current is %s — it did not restart" % (rt[:12], cur[:12])))
        else:
            rows.append(("PASS", "daemon", "running %s" % ((rt or "?")[:12])))
            sup = fns.Supervisor.__new__(fns.Supervisor)
            sup.p = p.sup
            for c in fns.load_table(p.sup)["children"]:
                cs = (st.get("children") or {}).get(c["name"]) or {}
                if sup.child_status(c) in ("pending", "waiting", "legacy"):
                    continue
                if not fns.pid_alive(cs.get("pid")):
                    rows.append(("FAIL", "child", "%s is down (last rc %s)" % (c["name"], cs.get("last_rc"))))
    if p.cache:
        cv = _read_lines(os.path.join(p.cache, "claude", "current"))[:1]
        want = spec["components"]["claude"]["version"]
        rows.append(("PASS", "cache", "new accounts get claude %s" % want) if cv == [want]
                    else ("WARN", "cache", "the bootstrap cache has claude %s, release.json %s" % ((cv or ["none"])[0], want)))
    for login, why in fns.managed_accounts(p.sup).items():
        ident = fns.account_ident(login)
        if why or ident is None:
            continue
        drift = [t for t, rel in sorted(ACCOUNT_LINKS.items())
                 if os.path.realpath(os.path.join(ident[2], rel)) != os.path.realpath(os.path.join(p.current, "tools", "bin", t))]
        rows.append(("PASS", "account", "%s: claude · codex · tmux from the release" % login) if not drift
                    else ("WARN", "account", "%s: %s not the release's (re-linked on the next tick)" % (login, ", ".join(drift))))
        ir = install_row(p, cur, login, ident)
        if ir:
            rows.append(ir)
    cr = credsep_row(p)
    if cr:
        rows.append(cr)
    rows.append(shell_row(p, st))
    # the drill's deliberate failure (issue #2336): a release carrying this marker
    # fails its own doctor, so the updater must roll it back. On trunk, so a
    # non-managed install that follows stable onto it moves forward off it again.
    if os.path.exists(os.path.join(d, DRILL_FAIL)):
        rows.append(("FAIL", "drill", "%s carries %s — a deliberate drill failure (#2336)" % (cur[:12], DRILL_FAIL)))
    return rows


def shell_row(p, st):
    """Does any TAKEN-OVER login still carry the person's client here (issue #2702)?
    Only logins/<login>.env's logins are looked at — anyone else is not the fleet's. ONE row:
    root looks now (fns.client_shell — every home); anyone else reads the last
    sweep's record in state.json (other homes are not theirs to read). WARN, never
    FAIL: a leftover client is not the release's fault."""
    listed = fns.taken_over(p.sup)
    seen = "看 %d 个托管登录（logins/*.env）" % len(listed)
    if os.geteuid() == 0:
        found = fns.client_shell(p.sup, listed)
    else:
        found = [c for c in ((st.get("sweep") or {}).get("clientshell")) or [] if c.get("login") in listed]
    if not found:
        return ("PASS", "shell", "no taken-over login carries the client shell or a login hook · " + seen)
    return ("WARN", "shell", "; ".join(fns.client_shell_says(c, p.sup) for c in found) + " · " + seen)


def account_install_sha(login, ident, path):
    """The commit a login's ~/.claude/fleet is at, or None. git runs AS the login
    (root never runs git on a tree someone else owns — its config could run code);
    a doctor that is neither root nor that login reads only a versions link's name."""
    uid, gid, home = ident
    if os.geteuid() == 0 or uid == os.geteuid():
        rc, out, _ = run(["git", "-C", path, "rev-parse", "HEAD"], timeout=30,
                         preexec_fn=fns.demote(login, uid, gid, home),
                         env={"HOME": home, "USER": login, "LOGNAME": login,
                              "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"})
        if rc == 0 and SHA_RE.match(out):
            return out
    if os.path.islink(path):
        name = os.path.basename(os.readlink(path).rstrip("/"))[:40]
        if SHA_RE.match(name):
            return name
    return None


def install_row(p, cur, login, ident):
    """Is a managed login's own install (~/.claude/fleet — every account task runs
    from it) on the machine's release? (issue #2688: one sat on its bootstrap copy
    while the runtime moved on, and nothing said so.) WARN, never FAIL: a login
    that has not followed yet is not the release's fault, and a FAIL would roll
    the whole machine back. No install = no row."""
    path = os.path.join(ident[2], ".claude", "fleet")
    if not os.path.lexists(path):
        return None
    shape = "link" if os.path.islink(path) else "plain directory"
    sha = account_install_sha(login, ident, path)
    if sha == cur:
        return ("PASS", "install", "%s: ~/.claude/fleet at the release %s" % (login, cur[:12]))
    fix = "install-sync follows the release on its next tick; now: sudo -u %s bash '%s' --root %s" % (
        login, os.path.join(p.current, "bin", "fleet-install-sync.sh"), path)
    if not sha:
        return ("WARN", "install", "%s: ~/.claude/fleet (%s) — its version is unreadable, NOT the release's; %s"
                % (login, shape, fix))
    return ("WARN", "install", "%s: ~/.claude/fleet at %s (%s), the release is %s — this login runs old bin/ and "
            "account tasks; %s" % (login, sha[:12], shape, cur[:12], fix))


def credsep_row(p):
    """The shared credential proxy runs this release's code (issue #2435): LIB's
    copy = <current>/bin's (FAIL otherwise — the updater refreshes it every tick),
    and the live proxy's <run>/version = that copy's (FAIL after
    FLEET_NODE_CREDSEP_WAIT seconds: it did not restart on the new code).
    None when the machine has no shared proxy."""
    rec = credsep_rec()
    if not rec:
        return None
    lib, rundir = rec["lib"], rec.get("run") or ""
    cur_bin = os.path.join(p.current, "bin")
    drift = []
    for f in CREDSEP_CODE:
        try:
            if sha256_file(os.path.join(lib, f)) != sha256_file(os.path.join(cur_bin, f)):
                drift.append(f)
        except (IOError, OSError):
            drift.append(f)
    if drift:
        return ("FAIL", "credsep", "%s: %s ≠ the release's (machine refresh puts it back)" % (lib, ", ".join(drift)))
    want = sha256_file(os.path.join(cur_bin, "fleet-cred-proxy.py"))[:12]
    end = now() + env_num("FLEET_NODE_CREDSEP_WAIT", 15)
    while True:
        try:
            live = _read_lines(os.path.join(rundir, "version"))[:1]
            pid = int((_read_lines(os.path.join(rundir, "pid")) or ["0"])[0] or 0)
        except ValueError:
            live, pid = [], 0
        up = bool(pid) and fns.pid_alive(pid)
        if (live == [want] and up) or now() >= end:
            break
        time.sleep(0.5)
    if live == [want] and up:
        return ("PASS", "credsep", "the shared proxy runs the release's code (%s)" % want)
    if not live:
        return ("WARN", "credsep", "the shared proxy's %s cannot be read — copy = release %s" % (
            os.path.join(rundir, "version"), want))
    if not up:
        return ("FAIL", "credsep", "the shared proxy is not running (pid %s, last version %s)" % (pid or "-", live[0]))
    return ("FAIL", "credsep", "the shared proxy runs %s, the release's copy is %s — it did not restart on the new code"
            % (live[0], want))


def versions_line(p):
    cur = link_sha(p.current)
    if not cur:
        return "version  no release on this machine"
    try:
        spec = check_release(read_json(os.path.join(p.rel(cur), RELEASE_FILE), None))
    except ValueError:
        return "version  %s · no valid release.json" % cur[:12]
    got = {}
    for r in doctor_rows(p):
        if r[1] in TOOLS + ("ccquota",):
            got[r[1]] = (r[0], r[2])
    parts, ok = ["runtime %s" % cur[:12]], True
    for name in ("ccquota",) + TOOLS:
        lvl, msg = got.get(name, ("FAIL", "?"))
        ok = ok and lvl == "PASS"
        parts.append("%s %s" % (name, msg.split(" (")[0] if lvl == "PASS" else "≠ " + (wanted(spec)[name] or "release")))
    st = read_json(p.sup.state_file, {}) or {}
    rt = (st.get("supervisor") or {}).get("runtime")
    parts.append("daemon %s" % ((rt or "?")[:12]))
    ok = ok and rt == cur
    return "version  %s — %s" % (" · ".join(parts), "各部件 = 发布版声明" if ok else "与发布版声明不一致")


# --------------------------------------------------------------- link-account ---
def link_account(login):
    """Run AS <login>: ~/.local/bin/{claude,codex} and the vendor tmux → the
    release's. A regular file is the account's own install: left, reported."""
    root = env("FLEET_NODE_ROOT", "/Library/Application Support/claude-fleet")
    home = os.environ.get("HOME") or os.path.expanduser("~")
    bad = []
    for tool, rel in sorted(ACCOUNT_LINKS.items()):
        dst = os.path.join(home, rel)
        want = os.path.join(root, "current", "tools", "bin", tool)
        if os.path.lexists(dst) and not os.path.islink(dst):
            bad.append("%s is a file (its own install), left" % rel)
            continue
        if os.path.islink(dst) and os.readlink(dst) == want:
            continue
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            swap_link(dst, want)
        except OSError as e:
            bad.append("%s: %s" % (rel, e))
    if bad:
        print("; ".join(bad), file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------- main -----------
def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    if cmd == "check-release":
        src = rest[0] if rest else "-"
        try:
            raw = sys.stdin.read() if src == "-" else open(src).read()
            check_release(json.loads(raw))
        except (ValueError, IOError, OSError) as e:
            print("release.json: %s" % e, file=sys.stderr)
            return 1
        print("release.json ok")
        return 0
    if cmd == "pinned-artifacts":
        src = rest[0] if rest else "-"
        try:
            raw = sys.stdin.read() if src == "-" else open(src).read()
            names = pinned_artifacts(json.loads(raw), rest[1:] or ["darwin-arm64"])
        except (ValueError, IOError, OSError) as e:
            print("release.json: %s" % e, file=sys.stderr)
            return 1
        print("\n".join(names))
        return 0
    if cmd == "link-account" and rest:
        return link_account(rest[0])
    p = P()
    if cmd == "doctor":
        rows = doctor_rows(p)
        for lvl, row, msg in rows:
            print("  %-4s  %-8s %s" % (lvl, row, msg))
        print("  INFO  %s" % versions_line(p)[len("version  "):])
        return sum(1 for r in rows if r[0] == "FAIL")
    if cmd == "versions":
        print(versions_line(p))
        return 0
    if cmd == "status":
        st = read_json(p.file, None)
        if st is None:
            if "--check" not in rest:
                print("update  not set up (no %s)" % p.file)
            return 2 if "--check" in rest else 0
        if "--json" in rest:
            print(json.dumps(st, indent=1, sort_keys=True))
            return 0
        line = "update  %s · %s · current %s · phase %s · %s" % (
            st.get("result", "-"), iso(st.get("at")), (link_sha(p.current) or "none")[:12],
            st.get("phase", "idle"), st.get("reason", ""))
        print(line)
        if "--check" in rest:
            bad = st.get("result") in ("failed", "rolled-back", "skipped") or (
                st.get("phase") != "idle" and now() - (st.get("at") or 0) > 3600)
            return 1 if bad else 0
        return 0
    if cmd == "tick":
        if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
            print("fleet-node-update: tick swaps the root runtime — the machine daemon runs it as root",
                  file=sys.stderr)
            return 1
        os.makedirs(os.path.dirname(p.lock), exist_ok=True)
        lk = os.open(p.lock, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("fleet-node-update: another tick holds %s" % p.lock, file=sys.stderr)
            return 3
        return Updater(p).tick()
    print("usage: fleet-node-update.py tick|status [--json|--check]|doctor|versions|check-release <f>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
