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
  logins     every managed login's ~/.claude/fleet IS the release (issue #2774,
             EPIC #2770 C4): ~/.claude/fleet.versions/<sha>/ is the login's own
             real directory tree whose every file links to <root>/<sha>/ (the
             selftest-shadow-root.sh shape: `$BIN/..` stays in the login's dir;
             logs/ … from fleet.versions/.shared/), built by `link-tree`, demoted
             to the login, in milliseconds; one rename of ~/.claude/fleet; then
             that version's fleet-install-apply.sh --tree-from <old> --tree-to
             <new> (daemons reloaded). The switch moves every login with the
             machine, the rollback moves them back, a tick at the release puts
             back one that drifted; a retired <root>/<sha> a login still links
             into is not pruned. `account release` turns it back into an own copy
             (`release-install`). A client-shell mirror pinned to one version dir
             is re-pointed through its link
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
  skipped     target is the version the doctor rejected (`skip`) — retried
              once the cause the rollback named is gone (a signature failure a
              later signed fetch outlived), else after FLEET_NODE_UPDATE_SKIP_RETRY
              (21600 s; 0 = until the target moves), doubling with each rollback
              of the same release up to a week. No flapping (issue #2906).
  backoff     the last stage of this target failed less than
              FLEET_NODE_UPDATE_RETRY (3600) seconds ago.
  deferred    a running EPIC batch WITH WORK holds the machine (issue #2247's
              rule: fleet_epic_holding over every managed account's marks),
              for at most FLEET_EPIC_HOLD_CAP_SECS (7200) in total: ONE clock for
              the machine from its first deferral, whichever batches hold and
              however often stable moves (issue #2843); reaching the target
              clears it. Past the cap the tick goes on (`hold released` in the
              log, and a note on each holding batch's EPIC as its login). A
              switch never stops a running session (each is on its own
              fleet.versions/<sha>) — only current/ and the daemons move.
  failed      staging failed (fetch, signature, a missing artifact, release.json
              invalid) — nothing switched; the staged dir is removed.
              A fetch is resumable (issue #2701): only the artifacts release.json
              pins for this machine, into <root>/.fetch/<sha256> (seeded from the
              tools cache and the current / previous release), each resumed from
              its .part, cut only after 30 s without a byte; progress lines in
              <state>/fetch.progress (`status` prints the last). A failed fetch
              that moved is NOT backed off — the next tick goes on from there.
  switched    staged → the doctor's FAIL rows on the OLD version kept as the
              baseline → `.prev` = old, `current` = new, cache + account links,
              the restart request. The NEXT tick (the new code, after
              FLEET_NODE_UPDATE_SETTLE seconds) runs the machine doctor:
  committed   no FAIL row the baseline did not have.
  rolled-back a new FAIL row → `current` = old, `.prev` = the rejected one,
              cache + links back, the restart request, `skip: <sha>`.

Usage:
  fleet-node-update.py tick                 one pass (what the daemon runs)
  fleet-node-update.py status [--json] [--check] [--keys]
                                            where it is, the release key fingerprints
                                            (pinned · the current release's signer;
                                            --keys or a signature failure: the hub's
                                            too) and an EPIC hold; --check: 0 settled
                                            · 1 a failure / rollback / stuck / a
                                            signature failure · 2 not set up
  fleet-node-update.py doctor               the machine doctor: PASS/WARN/FAIL rows,
                                            exit = the FAIL count (`fleet doctor --machine`)
  fleet-node-update.py versions [--json]    one line: every part's version vs release.json;
                                            --json: the machine link's 版本与更新 (issue #2798)
  fleet-node-update.py check-release <file|->  validate a release.json (fleet-stable.sh move)
  fleet-node-update.py pinned-artifacts <file|-> [<os>-<arch>…]
                                            the artifact names it pins, one a line
                                            (default darwin-arm64; fleet-stable.sh gate 7)
  fleet-node-update.py link-account <login> (internal: run demoted to <login>)
  fleet-node-update.py link-tree <sha> [--no-apply]
                                            (internal, run AS the login: its install →
                                            a tree linked to <root>/<sha>, issue #2774)
  fleet-node-update.py release-copy         (internal, AS the login: an own copy again)
  fleet-node-update.py follow <login>       links + install onto the release now
                                            (`account adopt` runs it, issue #2714)
  fleet-node-update.py release-install <login>
                                            the login's install an own copy again
                                            (`account release` runs it, issue #2774)

Seams (sandbox tests, docs/BREAK-IT.md `node-update-half`): the supervisor's
FLEET_NODE_STATE / FLEET_NODE_RUNTIME / FLEET_NODE_TEST / FLEET_NODE_PASSWD /
FLEET_NODE_USERS, plus
  FLEET_NODE_ROOT            the runtime root (default: FLEET_NODE_RUNTIME's dir)
  FLEET_NODE_CCQUOTA         the ccquota that fetches (default <current>/bin/ccquota, else PATH)
  FLEET_NODE_UPDATE_TARGET   the release to go to, instead of asking
  FLEET_NODE_UPDATE_SETTLE   seconds between the switch and the verify (30)
  FLEET_NODE_UPDATE_PLATFORM `<os>-<arch>` of the artifacts (default this machine's)
  FLEET_NODE_UPDATE_KEEP_SECS how long a retired version stays (604800)
  FLEET_NODE_FETCH_TIMEOUT   seconds one tick's fetch may run (1500; 0 = no limit — the
                             installer's tick), a resumable fetch goes on next tick
  FLEET_NODE_UPDATE_LIB      the fleet-lib.sh the EPIC gate sources (default <current>/bin)
  FLEET_NODE_UPDATE_FOLLOW   0 = never move a login's install (default 1)
  FLEET_NODE_FOLLOW_TIMEOUT  seconds one login's link-tree + apply may run (1200)
  FLEET_INSTALL_VERSIONS_KEEP_SECS  how long a login's retired version tree stays (604800)
"""
from __future__ import print_function

import base64
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

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
    unknown = set(spec) - {"schema", "components", "note", "client_reload"}
    if unknown:
        raise ValueError("unknown field(s): %s" % ", ".join(sorted(unknown)))
    # how a running client shell takes this release (issue #2737): hot = reloaded
    # in place (the default), restart = the person reopens it
    if spec.get("client_reload", "hot") not in ("hot", "restart"):
        raise ValueError("client_reload: hot or restart")
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
        # a release fetch's artifacts, kept across ticks so a cut one resumes
        # (`ccquota release fetch --cache`, issue #2701); its progress lines
        self.fetch_cache = os.path.join(self.root, ".fetch")
        self.progress = os.path.join(self.state, "fetch.progress")
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


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def fetch_resumable(cq):
    """Does this ccquota resume a fetch (--cache/--pinned, issue #2701)? An older
    one takes the whole release in one go, as before."""
    rc, out, err = run([cq, "release", "fetch", "-h"], timeout=30)
    return "-pinned" in (out + "\n" + err) and "-cache" in (out + "\n" + err)


def dir_bytes(d):
    n = 0
    for e in os.listdir(d) if os.path.isdir(d) else []:
        try:
            n += os.path.getsize(os.path.join(d, e))
        except OSError:
            pass
    return n


def fetch_line(p, fresh=120):
    """The last progress line of a fetch still under way (its file written in
    the last <fresh> seconds), or ""."""
    try:
        if now() - os.path.getmtime(p.progress) > fresh:
            return ""
        with open(p.progress) as f:
            lines = [l.strip() for l in f if l.strip()]
        return lines[-1] if lines else ""
    except (OSError, IOError):
        return ""


def key_id(text):
    """The fingerprint ccquota's release.KeyID prints for an `ed25519 <base64>`
    line: sha256 of the raw key, 16 hex. None when it is not one."""
    try:
        raw = base64.b64decode(text.strip().split()[-1])
    except (ValueError, IndexError, TypeError):
        return None
    return hashlib.sha256(raw).hexdigest()[:16] if len(raw) == 32 else None


def key_ids(p, hub=False):
    """(pinned, the current release's signer, the hub's key) fingerprints — None
    each when unreadable. The hub is asked only when hub=True (a network read)."""
    try:
        pinned = key_id(open(p.pubkey).read())
    except (OSError, IOError):
        pinned = None
    signer = (read_json(os.path.join(p.current, ".release", "manifest.json"), {}) or {}).get("key") or None
    served = None
    url = hub_url(p) if hub else None
    if url:
        try:
            with urlopen(url.rstrip("/") + "/v1/fleet/release/key", timeout=5) as r:
                served = key_id(r.read(4096).decode("utf-8", "replace").splitlines()[0])
        except (OSError, ValueError, IndexError):
            served = None
    return pinned, signer, served


def signed_since(st, p=None):
    """When a fetch last passed its signature check: a stage that landed (the
    switch, a commit or a rollback of a staged release) or the current release's
    staged mark. 0 when nothing says so."""
    st = st or {}
    at = [st.get("switched_at") or 0]
    at += [h.get("at") or 0 for h in st.get("history") or [] if h.get("result") in ("committed", "rolled-back")]
    if p is not None:
        try:
            at.append(int(os.path.getmtime(os.path.join(p.current, STAGED))))
        except OSError:
            pass
    return max(at)


def sig_failure(st, p=None):
    """(target, reason) of a recorded fetch that failed its signature check, or
    None. A failure a later signed fetch outlived is past tense (issue #2906): an
    updater from before #2843 never cleared `failed` after a stage that landed, so
    one torn read stayed in update.json for hours and every new release's doctor
    called it a new FAIL."""
    since = signed_since(st, p)
    for t, f in sorted(((st or {}).get("failed") or {}).items()):
        if "signature" in (f.get("reason") or "") and (f.get("at") or 0) > since:
            return t, f
    return None


def skip_rows(reason):
    """The doctor rows a rollback reason names ("new FAIL: <row> <detail>; …")."""
    r = (reason or "").split("new FAIL: ", 1)
    return sorted(set(x.split()[0] for x in r[1].split("; ") if x.split())) if len(r) > 1 else []


def cause_gone(sk, st, p):
    """A rollback made only by the key row's signature failure, and that failure
    is no longer on record — past tense (issue #2906)."""
    rows = sk.get("rows") or skip_rows(sk.get("reason"))
    return rows == ["key"] and "signature check" in (sk.get("reason") or "") and sig_failure(st, p) is None


def skip_retry(sk, st, p):
    """None = try the rolled-back release again now; else when (an epoch). A
    rejected release is not skipped forever (issue #2906): it is retried once the
    cause the rollback named is gone, else after FLEET_NODE_UPDATE_SKIP_RETRY
    (21600 s), doubling with each rollback of the same release up to a week — so
    a broken one does not flap, and a transient FAIL does not pin the machine
    until stable moves again. 0 = never (the pre-#2906 rule)."""
    if cause_gone(sk, st, p):
        return None
    base = env_num("FLEET_NODE_UPDATE_SKIP_RETRY", 21600)
    if base <= 0:
        return -1
    at = int((sk.get("at") or 0) + min(base * 2 ** max(int(sk.get("tries") or 1) - 1, 0), 604800))
    return None if now() >= at else at


def key_row(p, st):
    """The release key (issue #2843): FAIL when the pinned key is not the one the
    current release is signed with, or when the last fetch failed its signature
    check — the hub's key said beside it, so a changed key and a torn read
    (manifest and signature from two builds) tell apart. A doctor row, not only
    an update.log backoff."""
    sf = sig_failure(st, p)
    pinned, signer, served = key_ids(p, hub=bool(sf))
    if not pinned:   # WARN: the next stage refuses with the same words; the rollback gate stays out of it
        return ("WARN", "key", "no pinned release key at %s — `sudo fleet node install` pins it" % p.pubkey)
    if signer and signer != pinned:
        return ("FAIL", "key", "pinned %s, but the current release is signed by %s" % (pinned, signer))
    if sf:
        t, f = sf
        torn = served == pinned
        why = ("the hub serves the same key — a torn read (manifest and signature from two builds); "
               "the next fetch retries" if served == pinned else
               "the hub now serves %s — the hub's key changed; re-pin: sudo fleet node install --release-key <file>"
               % served if served else "the hub's key could not be read")
        # a torn read is the hub's passing state, not this machine's: WARN, so
        # it never rolls a release back (issue #2906); a changed key stays FAIL
        return ("WARN" if torn else "FAIL", "key", "%s failed its signature check %s against pinned %s: %s"
                % (t[:12], iso(f.get("at")), pinned, why))
    return ("PASS", "key", "pinned %s · current release signed by %s" % (pinned, signer or "?"))


def hold_row(p, st):
    """An EPIC hold under way (issue #2843), said with what it is for."""
    h = (st or {}).get("hold") or {}
    if (st or {}).get("result") != "deferred" or not h.get("since"):
        return None
    cap = env_num("FLEET_EPIC_HOLD_CAP_SECS", 7200)
    return ("WARN", "install", "EPIC batches hold the machine on %s, not %s, since %s (%dm of %dm, one clock for "
            "the machine) — a switch would not stop a running session (each is on its own fleet.versions/<sha>); "
            "the hold only keeps a batch's new workers on the version its others run"
            % ((link_sha(p.current) or "?")[:12], (h.get("target") or "?")[:12], iso(h["since"]),
               (now() - h["since"]) // 60, cap // 60))


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
        self.follow_held = False

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

    # -- the EPIC gate (#2062 / #2247): any managed account's batch with work holds.
    # The clock is the MACHINE's (issue #2843): `hold.since` is the first tick
    # any batch deferred the machine, and only reaching the target clears it
    # (`current`, or a switch). A new stable or another batch taking over the
    # hold does not restart it — with 3-7 batches running in parallel and stable
    # moving every hour or two, a clock keyed on the target never reached the cap
    # (macmini 2026-10-10: two stables behind, deferred every 5 minutes).
    # What the hold buys is small: a switch never stops a running session (each
    # sits on its own fleet.versions/<sha>); it only moves `current/` and the
    # daemons, so new workers of a batch start on the version its others run.
    def epic_hold(self, target):
        lib = env("FLEET_NODE_UPDATE_LIB", os.path.join(self.p.current, "bin", "fleet-lib.sh"))
        if not os.path.exists(lib):
            return None
        held, marks = [], []
        for login, why in fns.managed_accounts(self.p.sup).items():
            ident = fns.account_ident(login)
            if why or ident is None:
                continue
            conf = os.path.join(ident[2], ".config", "claude-fleet")
            rc, out, _ = run(["/bin/bash", "-c", '. "$1" >/dev/null 2>&1 || exit 2; fleet_epic_holding', "x", lib],
                             timeout=30, env=dict(os.environ, FLEET_CONF_DIR=conf, HOME=ident[2]))
            if rc == 0:
                held.append("%s: %s" % (login, (out.splitlines() or ["?"])[0][:120]))
                for line in out.splitlines():
                    f = line.split("\t")
                    if len(f) >= 2 and f[0] == "active":
                        marks.append((login, ident, f[1]))
        if not held:
            return None
        h = self.st.get("hold") or {}
        if not h.get("since"):
            h = {"since": now()}
        h["target"] = target
        self.st["hold"] = h
        cap = env_num("FLEET_EPIC_HOLD_CAP_SECS", 7200)
        if now() - h["since"] > cap:
            if h.get("released") != target:
                h["released"] = target
                self.log("hold released — EPIC batches have held this machine since %s, more than %ds (one clock "
                         "for the machine, #2843); switching to %s. Running sessions stay on their own "
                         "fleet.versions/<sha>; only current/ and the daemons move, so new workers start on %s: %s"
                         % (iso(h["since"]), int(cap), target[:12], target[:12], "; ".join(held)))
                self.note_release(marks, target, now() - h["since"], cap)
            return None
        return "%s (held %dm of %dm, since %s)" % ("; ".join(held), (now() - h["since"]) // 60, cap // 60,
                                                 iso(h["since"]))

    def note_release(self, marks, target, held, cap):
        """One record-only comment on each holding batch's EPIC, posted AS the
        login whose mark it is (its own gh, its own fleet-comment.sh), so the
        driver learns the floor moved. A comment that cannot be posted is logged;
        the release stands either way."""
        cur = link_sha(self.p.current) or "?"
        seen = set()
        for login, ident, mark in marks:
            try:
                kv = dict(l.split(": ", 1) for l in open(mark).read().splitlines() if ": " in l)
            except OSError:
                continue
            n, repo = kv.get("epic", ""), kv.get("repo", "")
            if not n.isdigit() or "/" not in repo or (repo, n) in seen:
                continue
            seen.add((repo, n))
            body = ("⏱ 整机更新放行：EPIC 批次已连续挡住 **%s** 的整机更新 %d 分钟（封顶 %d 分钟，按机器计，"
                    "`FLEET_EPIC_HOLD_CAP_SECS`，#2843），%s 起切换 `%s` → `%s`。\n\n"
                    "在跑的会话不受影响（各自在 `fleet.versions/<sha>` 上）；只换 `current/` 和守护，"
                    "本批之后新开的 worker 在新版本上起。"
                    % (socket.gethostname().split(".")[0], held // 60, cap // 60, iso(now()), cur[:12], target[:12]))
            uid, gid, home = ident
            cmd = env("FLEET_EPIC_HOLD_NOTE_CMD", "") or "/bin/bash %s" % os.path.join(
                home, ".claude", "fleet", "bin", "fleet-comment.sh")
            try:
                # root's own TMPDIR is not the login's to read
                fd, bf = tempfile.mkstemp(prefix="fleet-hold-note.", dir="/tmp" if os.geteuid() == 0 else None)
                with os.fdopen(fd, "w") as f:
                    f.write(body + "\n")
                os.chmod(bf, 0o644)
            except OSError as e:
                self.log("hold note: no temp file (%s) — no comment on %s#%s" % (e, repo, n))
                continue
            kw = {}
            if os.geteuid() == 0 and uid != 0:
                kw["preexec_fn"] = fns.demote(login, uid, gid, home)
            rc, out, err = run(cmd.split() + [n, "--repo", repo, "--note", "--from", "fleet", "--body-file", bf],
                               timeout=60, env={"HOME": home, "USER": login, "LOGNAME": login, "LANG": "en_US.UTF-8",
                                                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                                "FLEET_CONF_DIR": os.path.join(home, ".config", "claude-fleet")},
                               **kw)
            try:
                os.remove(bf)
            except OSError:
                pass
            self.log("hold note on %s#%s as %s: %s" % (repo, n, login, "posted" if rc == 0 else
                     "rc %d %s — released anyway" % (rc, ((err or out).splitlines() or [""])[-1][:120])))

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
        cmd = [cq, "release", "fetch", "--hub", hub, "--pubkey", self.p.pubkey, "--artifacts"]
        resumable = fetch_resumable(cq)
        if resumable:
            # only what release.json pins for this machine, resumed from the cache
            # (seeded with what the machine already has), no whole-fetch deadline
            os.makedirs(self.p.fetch_cache, exist_ok=True)
            self.seed_fetch_cache()
            with open(self.p.progress, "w"):
                pass
            cmd += ["--pinned", "--platform", "-".join(platform_id()), "--cache", self.p.fetch_cache,
                    "--progress", self.p.progress]
        before = dir_bytes(self.p.fetch_cache)
        tmo = env_num("FLEET_NODE_FETCH_TIMEOUT", 1500)
        rc, out, err = run(cmd + [sha, d], timeout=tmo if tmo > 0 else None)
        if rc != 0:
            shutil.rmtree(d, ignore_errors=True)
            e = StageError("fetch: %s" % (err or out or "rc %d" % rc).splitlines()[-1][:200])
            e.resumable = resumable and dir_bytes(self.p.fetch_cache) > before
            raise e
        if resumable:
            # every artifact now lives (hard-linked) in the release itself
            shutil.rmtree(self.p.fetch_cache, ignore_errors=True)
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

    def seed_fetch_cache(self):
        """Put what this machine already holds into the fetch cache under its
        sha256 — the tools cache, the current and previous release's artifacts —
        so a release that pins the same bytes downloads none of them again."""
        have = {}
        for tool in TOOLS:
            td = os.path.join(self.p.tools, tool)
            for h in os.listdir(td) if os.path.isdir(td) else []:
                have.setdefault(h, os.path.join(td, h, tool))
        for rel in (self.p.current, self.p.prev):
            man = read_json(os.path.join(rel, ".release", "manifest.json"), {}) or {}
            for a in man.get("artifacts") or []:
                if isinstance(a, dict) and SHA256_RE.match(str(a.get("sha256", ""))) and "/" not in str(a.get("name")):
                    have.setdefault(a["sha256"], os.path.join(rel, ".release", "artifacts", str(a["name"])))
        for h, src in sorted(have.items()):
            dst = os.path.join(self.p.fetch_cache, h)
            if not SHA256_RE.match(h) or os.path.exists(dst) or not os.path.isfile(src):
                continue
            try:
                os.link(src, dst)   # ccquota re-checks the digest before it uses one
            except OSError:
                pass

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
        return notes + self.link_accounts()

    def link_accounts(self, only=None):
        notes = []
        for login, why in fns.managed_accounts(self.p.sup).items():
            ident = fns.account_ident(login)
            if (only and login != only) or why or ident is None:
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

    # -- every managed login's ~/.claude/fleet IS the release (issues #2714, #2774)
    def follow_installs(self, only=None, sha=None, force=False):
        """A managed login's ~/.claude/fleet not LINKED to <sha> (default: the
        release `current` names) gets `link-tree <sha>` run for it, demoted (its
        HOME / TMPDIR / FLEET_CONF_DIR): a tree of links into <root>/<sha>, one
        rename of its link, that version's apply --tree-from/--tree-to (issue
        #2774 — before it, the release's install-sync, which fetched its own copy
        from GitHub: #2714). The switch and the rollback move every login with
        the machine (force); a tick at the release puts back one that drifted (a
        login pointed by hand at an own old copy — BREAK-IT
        managed-login-own-copy), unless an EPIC batch with work holds it. One
        already linked costs one read; one that did not move is tried again on the
        same release only after FLEET_NODE_UPDATE_RETRY. -> notes."""
        self.follow_held = False
        sha = sha or link_sha(self.p.current)
        if not sha or env_num("FLEET_NODE_UPDATE_FOLLOW", 1) == 0 or not os.path.isdir(self.p.rel(sha)):
            return []
        tried = self.st.setdefault("follow", {})
        notes, todo = [], []
        for login, why in fns.managed_accounts(self.p.sup).items():
            ident = fns.account_ident(login)
            if (only and login != only) or why or ident is None:
                continue
            uid, gid, home = ident
            path = os.path.join(home, ".claude", "fleet")
            if not os.path.lexists(path):
                tried.pop(login, None)
                continue
            if uid == 0 or (os.geteuid() != 0 and uid != os.geteuid()):
                continue
            if linked_sha(path, self.p.root) == sha:
                tried.pop(login, None)
                continue
            t = tried.get(login) or {}
            if not (only or force) and t.get("to") == sha and now() - (t.get("at") or 0) < env_num("FLEET_NODE_UPDATE_RETRY", 3600):
                notes.append("install %s: not linked to %s (%s)" % (login, sha[:12], t.get("said", "")))
                continue
            todo.append((login, ident, path))
        if todo and not (only or force):
            hold = self.epic_hold(sha)
            if hold:
                self.follow_held = True
                return notes + ["install %s: not linked to %s yet — an EPIC batch with work: %s"
                                % (", ".join(t[0] for t in todo), sha[:12], hold)]
        for login, ident, path in todo:
            was = account_install_sha(login, ident, path, self.p.root)
            rc, out, err = as_login(login, ["link-tree", sha], timeout=env_num("FLEET_NODE_FOLLOW_TIMEOUT", 1200),
                                    root=self.p.root)
            said = ((out + "\n" + err).strip().splitlines() or ["rc %d" % rc])[-1][:200]
            now_at = linked_sha(path, self.p.root)
            self.log("install %s: %s → %s · rc %d · %s" % (login, (was or "unreadable")[:12],
                                                          (now_at or "not linked")[:12], rc, said))
            if now_at == sha:
                tried.pop(login, None)
            else:
                tried[login] = {"at": now(), "to": sha, "rc": rc, "said": said}
                notes.append("install %s: not linked to %s (rc %d %s)" % (login, sha[:12], rc, said))
        return notes

    def linked_releases(self):
        """Every release some managed login's version tree still links into
        (issue #2774): a retired <root>/<sha> one of them names is in use."""
        used = set()
        for login in fns.managed_accounts(self.p.sup):
            ident = fns.account_ident(login)
            if ident is None:
                continue
            vers = os.path.join(ident[2], ".claude", "fleet.versions")
            try:
                names = os.listdir(vers)
            except OSError:
                continue
            for n in names:
                m = linked_mark(os.path.join(vers, n))
                if m and os.path.realpath(m["root"]) == os.path.realpath(self.p.root):
                    used.add(m["sha"])
        return used

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
        return self.sync_pool(cs)

    def sync_pool(self, cs):
        """`machine pool-sync` (issue #2850): the shared pool against the hub's
        manifest — pull, drop, warn — every round. rc 3 = no shared proxy / no
        hub: nothing. -> notes."""
        rc, out, err = run([sys.executable, "-I", cs, "machine", "pool-sync"], timeout=180)
        if rc == 3:
            return []
        for l in out.splitlines():
            if l.startswith("WARN pool:") or " pulled " in l or " dropped " in l or l.startswith("pool: note"):
                self.log("credsep: %s" % l)
        if rc != 0:
            return ["credsep: pool-sync rc %d %s" % (rc, (err or out).strip()[-160:])]
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
        # every managed login moves WITH the machine (issue #2774): its install is
        # a tree of links into the release, re-pointed in the same tick
        notes = self.sync_outside() + self.sync_credsep() + self.follow_installs(sha=to, force=True)
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
        self.follow_installs(sha=frm, force=True)     # the logins go back with it
        prev = self.st["skip"].get(to) or {}
        self.st["skip"] = {to: {"at": now(), "reason": why, "rows": self.st.pop("rollback_rows", None) or skip_rows(why),
                                "tries": int(prev.get("tries") or 1) + 1 if prev else 1}}
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
            self.st["rollback_rows"] = new
            self.save()
            return self.rollback(self.st["rollback_reason"])
        self.record("committed", self.st.get("from"), self.st["to"], "; ".join(new))
        self.st.update(phase="idle", current=self.st["to"])
        self.sessions("restore", self.st["to"])
        # a login the switch could not move: once more, now the release stands
        self.follow_installs()
        self.prune()
        return self.end("committed", "%s%s" % (self.st["to"][:12],
                                              (" (no previous version to go back to; FAIL: %s)" % ", ".join(new)) if new else ""))

    def prune(self):
        keep = {link_sha(self.p.current), link_sha(self.p.prev)}
        ttl = env_num("FLEET_NODE_UPDATE_KEEP_SECS", 604800)
        used = None
        for sha, at in list(self.st["retired"].items()):
            if sha in keep or now() - at < ttl:
                continue
            # a login's version tree still links into it (issue #2774): kept
            used = self.linked_releases() if used is None else used
            if sha in used:
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
            notes = self.sync_outside() + self.sync_credsep() + self.follow_installs()
            if not self.follow_held:
                self.st.pop("hold", None)
            self.st["failed"] = {}
            return self.end("current", "%s (%s)%s" % (cur[:12], src, (" · " + "; ".join(notes)) if notes else ""),
                            current=cur, notes=notes)
        if target in self.st["skip"]:
            sk = self.st["skip"][target]
            again = skip_retry(sk, self.st, self.p)
            if again is not None:
                return self.end("skipped", "%s was rolled back: %s · retried %s" % (
                    target[:12], sk.get("reason", ""), "when its cause is gone" if again < 0 else "at " + iso(again)),
                    current=cur)
            self.log("retrying %s, rolled back %s: %s" % (target[:12], iso(sk.get("at")),
                                                          "its cause is gone" if cause_gone(sk, self.st, self.p)
                                                          else "the skip ran out"))
        f = self.st["failed"].get(target) or {}
        if f and now() - f.get("at", 0) < env_num("FLEET_NODE_UPDATE_RETRY", 3600):
            return self.end("backoff", "%s failed %s: %s" % (target[:12], iso(f["at"]), f.get("reason", "")), current=cur)
        hold = self.epic_hold(target)
        if hold:
            return self.end("deferred", "an EPIC batch with work: %s" % hold, current=cur)
        try:
            self.stage(target)
        except StageError as e:
            if e.resumable:   # no backoff: the next tick resumes where this one was cut
                self.st["failed"].pop(target, None)
            else:
                self.st["failed"] = {target: {"at": now(), "reason": str(e)}}
            self.record("failed", cur, target, str(e))
            return self.end("failed", "%s: %s" % (target[:12], e), current=cur)
        self.st["failed"] = {}      # an older target's failure says nothing now (key row, #2843)
        self.st.pop("hold", None)   # the machine reaches the target: its hold clock starts over (#2843)
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
    resumable = False   # the fetch moved: its bytes are kept, the next tick goes on
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
        pr = credpool_row(p)
        if pr:
            rows.append(pr)
    ust = read_json(p.file, {}) or {}
    rows.append(key_row(p, ust))
    hr = hold_row(p, ust)
    if hr:
        rows.append(hr)
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
    seen = "托管登录 %d 个，其余账号不在清单内不扫" % len(listed)
    if os.geteuid() == 0:
        found = fns.client_shell(p.sup, listed)
    else:
        found = [c for c in ((st.get("sweep") or {}).get("clientshell")) or [] if c.get("login") in listed]
    if not found:
        return ("PASS", "shell", "no taken-over login carries the client shell or a login hook · " + seen)
    return ("WARN", "shell", "; ".join(fns.client_shell_says(c, p.sup) for c in found) + " · " + seen)


def account_install_sha(login, ident, path, root=None):
    """The release a login's ~/.claude/fleet is at, or None: the one its linked
    tree names (issue #2774 — read, never run), else the commit its checkout is
    at. git runs AS the login (root never runs git on a tree someone else owns —
    its config could run code), and only in a dir that has its own .git (never a
    repo it merely sits inside); a doctor that is neither root nor that login
    reads only a versions link's name."""
    uid, gid, home = ident
    if root:
        ls = linked_sha(path, root)
        if ls:
            return ls
    m = linked_mark(os.path.realpath(path)) if os.path.islink(path) else None
    if m:
        return m["sha"]
    if (os.geteuid() == 0 or uid == os.geteuid()) and os.path.lexists(os.path.join(os.path.realpath(path), ".git")):
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
    """Is a managed login's ~/.claude/fleet (every account task runs from it) the
    machine's release — a tree LINKED to <root>/<current> (issue #2774)? An own
    copy, even of the same sha, is not (BREAK-IT managed-login-own-copy). WARN,
    never FAIL: a login that has not moved yet is not the release's fault, and a
    FAIL would roll the whole machine back. No install = no row."""
    path = os.path.join(ident[2], ".claude", "fleet")
    if not os.path.lexists(path):
        return None
    if linked_sha(path, p.root) == cur:
        return ("PASS", "install", "%s: ~/.claude/fleet linked to the release %s (%s)" % (login, cur[:12], p.rel(cur)))
    shape = "link" if os.path.islink(path) else "plain directory"
    sha = account_install_sha(login, ident, path, p.root)
    fix = "the updater links it to the runtime every tick (issue #2774); now: sudo python3 '%s' follow %s" % (
        os.path.join(p.current, "bin", "fleet-node-update.py"), login)
    t = ((read_json(p.file, {}) or {}).get("follow") or {}).get(login) or {}
    if t.get("to") == cur:
        fix = "the updater's last try %s: rc %s %s; %s" % (iso(t.get("at")), t.get("rc"), t.get("said", ""), fix)
    if sha == cur:
        return ("WARN", "install", "%s: ~/.claude/fleet at %s but its own copy (%s), not linked to the runtime — "
                "it does not move with the machine; %s" % (login, cur[:12], shape, fix))
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


def credpool_row(p):
    """One token held twice on the shared proxy (issue #2849): the pool's copy
    and a login's own accounts/<label>.hub — `fleet-credsep.py machine pooldup`,
    a WARN (never a FAIL: no rollback for it). None when it cannot tell."""
    cs = os.path.join(p.current, "bin", "fleet-credsep.py")
    if not os.path.exists(cs):
        return None
    rc, out, _ = run([sys.executable, "-I", cs, "machine", "pooldup"], timeout=60)
    m = re.match(r"^pooldup: (OK|WARN) — (.*)$", (out.splitlines() or [""])[-1])
    if not m or rc not in (0, 1):
        return None
    return ("PASS" if m.group(1) == "OK" else "WARN", "credpool", m.group(2))


_VER_RE = re.compile(r"\d+(?:\.\d+)+[0-9A-Za-z.+-]*")


def versions_json(p):
    """The machine's 版本与更新 as the machine link's beat carries it (issue
    #2798, control.Versions): the release sha, what each part answers, what
    release.json pins, the daemon's release, the updater's own record. Every
    part best effort — one that does not answer is "", never a guess."""
    out = {}
    cur = link_sha(p.current)
    if cur:
        out["runtime"] = cur
        try:
            out["want"] = {k: v for k, v in wanted(check_release(
                read_json(os.path.join(p.rel(cur), RELEASE_FILE), None))).items() if v}
        except ValueError:
            pass
        actual = {}
        for name, path, args in [("ccquota", os.path.join(p.current, "bin", "ccquota"), ["version"])] + [
                (t, os.path.join(p.current, "tools", "bin", t), ["-V"] if t == "tmux" else ["--version"])
                for t in TOOLS]:
            rc, v = tool_version(path, args) if os.path.exists(path) else (127, "")
            m = _VER_RE.search(v) if rc == 0 else None
            # ccquota says `ccquota prod-<sha>`: its last word is its version
            actual[name] = m.group(0) if m else (v.split()[-1] if rc == 0 and v.split() else "")
        out["actual"] = actual
    st = read_json(p.sup.state_file, {}) or {}
    rt = (st.get("supervisor") or {}).get("runtime")
    if rt:
        out["daemon"] = rt
    u = read_json(p.file, None)
    if isinstance(u, dict):
        upd = {k: u[k] for k in ("result", "phase", "reason") if u.get(k)}
        if u.get("at"):
            upd["at"] = iso(u["at"])
        out["update"] = upd
    return out


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
    bad += follow_shell_mirror(home)
    if bad:
        print("; ".join(bad), file=sys.stderr)
        return 1
    return 0


def follow_shell_mirror(home):
    """Run AS the login (issue #2714): a client-shell mirror an older fleet-shell.sh
    pinned to one version dir (~/.cache/claude-fleet/shell/{bin,conf}/<f> →
    ~/.claude/fleet.versions/<key>/<rel>) is re-pointed THROUGH the login's
    ~/.claude/fleet link — what fleet-shell.sh's mirror does since #2692 — so it
    moves with the install instead of sitting on <key> until its next start. Only
    such links are touched; no mirror, or no versions link, = nothing. -> errors."""
    live = os.path.join(home, ".claude", "fleet")
    vers = live + ".versions" + os.sep
    cache = os.path.join(home, ".cache", "claude-fleet", "shell")
    if not os.path.islink(live) or not os.path.isdir(cache):
        return []
    bad = []
    for sub in ("bin", "conf"):
        d = os.path.join(cache, sub)
        for name in sorted(os.listdir(d)) if os.path.isdir(d) and not os.path.islink(d) else []:
            f = os.path.join(d, name)
            if not os.path.islink(f):
                continue
            t = os.readlink(f)
            if not t.startswith(vers):
                continue
            rest = t[len(vers):].split(os.sep, 1)
            if len(rest) != 2 or not rest[1]:
                continue
            try:
                swap_link(f, os.path.join(live, rest[1]))
            except OSError as e:
                bad.append("%s: %s" % (f, e))
    return bad


# --------------------------------------------------------------- link-tree ------
# A managed login's ~/.claude/fleet IS the machine's runtime (issue #2774, EPIC
# #2770 C4): ~/.claude/fleet.versions/<sha>/ stays the login's own REAL directory
# tree, but every file in it is a link to <root>/<sha>/<same path> — the
# selftest-shadow-root.sh shape, so `$BIN/..` still lands in the login's dir
# (its logs/, epic-pages/, fleet.conf* come from fleet.versions/.shared/, as
# install-sync has always linked them). The bytes live once, under <root>; the
# login's dir is links only, built in milliseconds. LINKED, written last, is the
# mark that a tree is whole and whose it is.
LINKED = ".fleet-linked"
# what the runtime has that is not the version's code (the release's own record,
# the tool artifacts current/tools/bin carries) and never a version's
TREE_SKIP_TOP = (".release", "tools")
TREE_SKIP = ("__pycache__", ".DS_Store", LINKED)


def linked_mark(d):
    """{sha, root, at} of a linked version tree, or None (not one, or not whole)."""
    m = read_json(os.path.join(d, LINKED), None)
    return m if isinstance(m, dict) and SHA_RE.match(str(m.get("sha") or "")) and m.get("root") else None


def linked_sha(path, root):
    """The release <path> (a login's ~/.claude/fleet) is LINKED to under <root>,
    or None: a plain checkout, an own copy, a tree of another root's."""
    if not os.path.islink(path):
        return None
    m = linked_mark(os.path.realpath(path))
    if not m or os.path.realpath(m["root"]) != os.path.realpath(root):
        return None
    return m["sha"]


def _own_entries(d, against=None):
    """The top-level names of version dir <d> that are NOT the version's code —
    logs/, epic-pages/, fleet.conf backups … (what .shared/ holds): a linked
    tree's real entries that its release lacks, a checkout's untracked ones, a
    plain copy's (a bootstrap's, no git) entries release <against> lacks."""
    m = linked_mark(d)
    names = [n for n in os.listdir(d) if n not in (".git", LINKED) + TREE_SKIP and ".switch." not in n]
    if m:
        rel = os.path.join(m["root"], m["sha"])
        return [n for n in names if not os.path.islink(os.path.join(d, n)) and not os.path.lexists(os.path.join(rel, n))]
    if os.path.lexists(os.path.join(d, ".git")):
        rc, out, _ = run(["git", "-C", d, "status", "--porcelain", "--ignored", "--untracked-files=normal"], timeout=60)
        if rc != 0:
            return []
        return sorted(set(l[3:].rstrip("/") for l in out.splitlines()
                          if l[:2] in ("??", "!!") and "/" not in l[3:].rstrip("/")) & set(names))
    if against:
        return [n for n in names if not os.path.islink(os.path.join(d, n))
                and not os.path.lexists(os.path.join(against, n))]
    return []


def _share(vers, d, against=None):
    """What every version shares: <d>'s own top-level entries move to
    <vers>/.shared/ (unless it holds that name already) and are linked back;
    then every .shared entry <d> lacks is linked in (install-sync's vers_shared)."""
    sh = os.path.join(vers, ".shared")
    os.makedirs(sh, exist_ok=True)
    for n in _own_entries(d, against):
        src = os.path.join(d, n)
        if os.path.islink(src) or os.path.lexists(os.path.join(sh, n)):
            continue
        try:
            os.rename(src, os.path.join(sh, n))
            os.symlink(os.path.join("..", ".shared", n), src)
        except OSError:
            pass
    for n in os.listdir(sh):
        dst = os.path.join(d, n)
        if not os.path.lexists(dst):
            try:
                os.symlink(os.path.join("..", ".shared", n), dst)
            except OSError:
                pass


def _build_tree(src, dst, link=True):
    """<dst> mirrors release <src>: real directories; every file a link to its
    <src> path (link) or a copy of its bytes (an own copy — `release-copy`)."""
    os.makedirs(dst)
    for d, dirs, files in os.walk(src):
        rel = os.path.relpath(d, src)
        dirs[:] = sorted(n for n in dirs if n not in TREE_SKIP and not (rel == "." and n in TREE_SKIP_TOP))
        for n in dirs:
            p = os.path.join(d, n)
            q = os.path.normpath(os.path.join(dst, rel, n))
            if os.path.islink(p):
                os.symlink(os.readlink(p), q)
            else:
                os.mkdir(q)
        for n in files:
            if n in TREE_SKIP:
                continue
            p = os.path.join(d, n)
            q = os.path.normpath(os.path.join(dst, rel, n))
            if os.path.islink(p):
                os.symlink(os.readlink(p), q)
            elif link:
                os.symlink(p, q)
            else:
                shutil.copy2(p, q)
    for d, dirs, _ in os.walk(dst):
        dirs[:] = [n for n in dirs if not os.path.islink(os.path.join(d, n))]
        os.chmod(d, 0o755)


def _retire(vers, key, when=None):
    rd = os.path.join(vers, ".retired")
    try:
        os.makedirs(rd, exist_ok=True)
        if when is None:
            os.remove(os.path.join(rd, key))
        else:
            with open(os.path.join(rd, key), "w") as f:
                f.write("%d\n" % when)
    except OSError:
        pass


def _point(live, vers, new):
    """~/.claude/fleet → <new> by one rename(2); a plain-directory install is
    adopted first (moved to <vers>/<its HEAD>, as fleet_versions_adopt does).
    -> the old version dir (None: there was none)."""
    old = None
    if os.path.islink(live):
        old = os.path.realpath(live)
    elif os.path.isdir(live):
        rc, out, _ = run(["git", "-C", live, "rev-parse", "HEAD"], timeout=30)
        key = out if rc == 0 and SHA_RE.match(out) else "own-%d" % int(now())
        if os.path.lexists(os.path.join(vers, key)):
            key = "%s-%d" % (key, int(now()))
        os.makedirs(vers, exist_ok=True)
        old = os.path.join(vers, key)
        os.rename(live, old)
    swap_link(live, new)
    if old and os.path.realpath(old) != os.path.realpath(new):
        with open(os.path.join(vers, ".prev.tmp"), "w") as f:
            f.write(os.path.basename(old) + "\n")
        os.rename(os.path.join(vers, ".prev.tmp"), os.path.join(vers, ".prev"))
        _retire(vers, os.path.basename(old), now())
    _retire(vers, os.path.basename(new))
    return old


def _prune_login_versions(live, vers):
    """A linked tree (or an own copy this updater made) retired longer than
    FLEET_INSTALL_VERSIONS_KEEP_SECS (7 days — the sessions still running from it)
    goes; never the one in use, .prev's, or a checkout holding the repository."""
    keep = {os.path.basename(os.path.realpath(live)), (_read_lines(os.path.join(vers, ".prev")) or [""])[0]}
    ttl = env_num("FLEET_INSTALL_VERSIONS_KEEP_SECS", 604800)
    for n in os.listdir(vers) if os.path.isdir(vers) else []:
        d = os.path.join(vers, n)
        if n.startswith(".") or n in keep or os.path.islink(d) or not os.path.isdir(d):
            continue
        if not linked_mark(d):
            continue
        t = (_read_lines(os.path.join(vers, ".retired", n)) or [""])[0]
        if not t.isdigit():
            _retire(vers, n, now())
            continue
        if now() - int(t) >= ttl:
            shutil.rmtree(d, ignore_errors=True)
            _retire(vers, n)


def link_tree(sha, apply=True):
    """Run AS the login (issue #2774): ~/.claude/fleet → a version tree linked to
    <root>/<sha>, then that version's fleet-install-apply.sh --tree-from <old>
    --tree-to <new> (daemons reloaded, hooks merged, skills installed). Already
    there: nothing. Prints ONE line `linked …` (or `at …`); rc 1 = not moved."""
    root = env("FLEET_NODE_ROOT", "/Library/Application Support/claude-fleet")
    home = os.environ.get("HOME") or os.path.expanduser("~")
    live = os.path.join(home, ".claude", "fleet")
    vers = live + ".versions"
    src = os.path.join(root, sha)
    if not SHA_RE.match(sha) or not os.path.isdir(os.path.join(src, "bin")):
        print("link-tree: no release %s under %s" % (sha[:12], root), file=sys.stderr)
        return 1
    if linked_sha(live, root) == sha:
        _share(vers, os.path.realpath(live))
        print("at %s — ~/.claude/fleet is linked to %s" % (sha[:12], src))
        return 0
    os.makedirs(vers, exist_ok=True)
    # the tree: reused when one of this release is already whole; else built
    # beside it and renamed in, so a half-built tree is never a version
    new = None
    for key in (sha, sha + "-linked"):
        d = os.path.join(vers, key)
        if not os.path.lexists(d):
            new = d
            break
        m = linked_mark(d) if os.path.isdir(d) and not os.path.islink(d) else None
        if m and m["sha"] == sha and os.path.realpath(m["root"]) == os.path.realpath(root):
            new = d
            break
        # taken by another tree of this sha (the checkout install-sync made): next name
    if new is None:
        print("link-tree: %s and %s-linked are both taken" % (sha[:12], sha[:12]), file=sys.stderr)
        return 1
    if not linked_mark(new):
        tmp = os.path.join(vers, ".linking.%d" % os.getpid())
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            _build_tree(src, tmp)
            write_json(os.path.join(tmp, LINKED), {"sha": sha, "root": root, "at": now()})
            os.rename(tmp, new)
        except OSError as e:
            shutil.rmtree(tmp, ignore_errors=True)
            print("link-tree: building %s: %s" % (new, e), file=sys.stderr)
            return 1
    was = os.path.realpath(live) if os.path.lexists(live) else None
    if was and os.path.isdir(was) and was != os.path.realpath(new) and os.path.islink(live):
        _share(vers, was)       # its logs/ … into .shared first, then the switch
    _share(vers, new)
    plain = os.path.isdir(live) and not os.path.islink(live)
    try:
        old = _point(live, vers, new)
    except OSError as e:
        print("link-tree: switching %s: %s" % (live, e), file=sys.stderr)
        return 1
    if plain and old:           # an adopted plain install: its logs/ … now
        _share(vers, old, src)
        _share(vers, new)
    said = "no apply"
    ap = os.path.join(live, "bin", "fleet-install-apply.sh")
    if apply and old and os.path.isdir(old) and os.path.exists(ap):
        ok = os.path.basename(old)[:40]
        rc, out, err = run(["/bin/bash", ap, "--tree-from", old, "--tree-to", new, "--root", live,
                            "--from", ok if SHA_RE.match(ok) else "none", "--to", sha],
                           timeout=env_num("FLEET_NODE_FOLLOW_TIMEOUT", 1200))
        said = ([l[len("apply: "):] for l in (out + "\n" + err).splitlines() if l.startswith("apply: ")]
                or ["apply exit %d: %s" % (rc, ((err or out).strip().splitlines() or [""])[-1][:120])])[-1]
    _prune_login_versions(live, vers)
    print("linked %s → %s (%s) · apply: %s" % (
        os.path.basename(old)[:12] if old else "none", sha[:12], os.path.basename(new), said))
    return 0


def release_copy():
    """Run AS the login being released (`account release`, issue #2774): its
    linked ~/.claude/fleet becomes an OWN copy — the same files, copied — that
    is a checkout of one commit `fleet-release: <sha> seq=<n>` (what
    fleet-install-sync.sh's hub road imports, #2773), so the login lives and
    follows on its own after the machine lets it go. Not linked: nothing."""
    root = env("FLEET_NODE_ROOT", "/Library/Application Support/claude-fleet")
    home = os.environ.get("HOME") or os.path.expanduser("~")
    live = os.path.join(home, ".claude", "fleet")
    vers = live + ".versions"
    cur = os.path.realpath(live)
    m = linked_mark(cur) if os.path.islink(live) else None
    if not m:
        print("own copy already — ~/.claude/fleet is not linked to a runtime")
        return 0
    sha = m["sha"]
    src = os.path.join(m["root"], sha)
    if not os.path.isdir(src):
        print("release-copy: the runtime's %s is gone (%s)" % (sha[:12], src), file=sys.stderr)
        return 1
    key = sha + "-own"
    if os.path.lexists(os.path.join(vers, key)):
        key = "%s-own-%d" % (sha, int(now()))
    tmp = os.path.join(vers, ".copying.%d" % os.getpid())
    shutil.rmtree(tmp, ignore_errors=True)
    seq = (read_json(os.path.join(src, ".release", "manifest.json"), {}) or {}).get("seq") or 0
    genv = dict(os.environ, GIT_AUTHOR_NAME="fleet-release", GIT_AUTHOR_EMAIL="fleet-release@localhost",
                GIT_COMMITTER_NAME="fleet-release", GIT_COMMITTER_EMAIL="fleet-release@localhost")
    try:
        _build_tree(src, tmp, link=False)
        for c in (["git", "init", "-q", "-b", "master", tmp],
                  ["git", "-C", tmp, "add", "-A", "-f", "."],
                  ["git", "-C", tmp, "commit", "-q", "--no-verify", "-m", "fleet-release: %s seq=%d" % (sha, int(seq))]):
            rc, out, err = run(c, timeout=300, env=genv)
            if rc != 0:
                raise OSError("%s: %s" % (" ".join(c[:3]), (err or out).strip()[-160:]))
        os.rename(tmp, os.path.join(vers, key))
    except (OSError, ValueError) as e:
        shutil.rmtree(tmp, ignore_errors=True)
        print("release-copy: %s" % e, file=sys.stderr)
        return 1
    new = os.path.join(vers, key)
    _share(vers, new)
    _point(live, vers, new)
    print("own copy %s — ~/.claude/fleet no longer links to %s" % (key, root))
    return 0


def as_login(login, args, timeout=1200, root=None):
    """`fleet-node-update.py <args…>` demoted to <login> (its HOME / USER /
    TMPDIR / FLEET_CONF_DIR, the runtime's tools first on PATH) -> (rc, out, err)."""
    ident = fns.account_ident(login)
    if ident is None:
        return 1, "", "no such account %s" % login
    uid, gid, home = ident
    root = root or env("FLEET_NODE_ROOT", os.path.dirname(fns.Paths().runtime.rstrip("/")))
    tb = os.path.join(root, "current", "tools", "bin")
    e = {"HOME": home, "USER": login, "LOGNAME": login, "LANG": "en_US.UTF-8",
         "PATH": "%s:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" % tb,
         "FLEET_CONF_DIR": os.path.join(home, ".config", "claude-fleet"),
         "FLEET_NODE_ROOT": root, "FLEET_NODE_STATE": env("FLEET_NODE_STATE", fns.Paths().state)}
    for k in ("FLEET_INSTALL_VERSIONS_KEEP_SECS", "FLEET_NODE_FOLLOW_TIMEOUT"):
        if env(k, ""):
            e[k] = env(k, "")
    return run(["/bin/sh", "-c", SESSIONS_SH, "fleet-node-update", sys.executable, "-I",
                os.path.abspath(__file__)] + list(args),
               timeout=timeout, preexec_fn=fns.demote(login, uid, gid, home), env=e)


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
    if cmd == "link-tree" and rest:
        return link_tree(rest[0], apply="--no-apply" not in rest[1:])
    if cmd == "release-copy":
        return release_copy()
    p = P()
    if cmd == "follow" and rest:
        # `account adopt` (issue #2714): the login's links and install onto the
        # release at once, not on the next tick; the tick's state is not written
        if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
            print("fleet-node-update: follow runs as the login it names — the machine daemon's root does it",
                  file=sys.stderr)
            return 1
        u = Updater(p)
        notes = u.link_accounts(only=rest[0]) + u.follow_installs(only=rest[0])
        for n in notes:
            print(n, file=sys.stderr)
        return 1 if notes else 0
    if cmd == "release-install" and rest:
        # `account release` (issue #2774): the login's linked install becomes an
        # own copy before the machine lets it go
        if os.geteuid() != 0 and env("FLEET_NODE_TEST", "") != "1":
            print("fleet-node-update: release-install runs as the login it names — the machine daemon's root does it",
                  file=sys.stderr)
            return 1
        rc, out, err = as_login(rest[0], ["release-copy"], timeout=600, root=p.root)
        for line in (out + "\n" + err).strip().splitlines():
            print(line, file=sys.stderr if rc else sys.stdout)
        return rc
    if cmd == "doctor":
        rows = doctor_rows(p)
        for lvl, row, msg in rows:
            print("  %-4s  %-8s %s" % (lvl, row, msg))
        print("  INFO  %s" % versions_line(p)[len("version  "):])
        return sum(1 for r in rows if r[0] == "FAIL")
    if cmd == "versions":
        if "--json" in rest:
            print(json.dumps(versions_json(p), sort_keys=True))
            return 0
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
        sf = sig_failure(st, p)
        pinned, signer, served = key_ids(p, hub=bool(sf) or "--keys" in rest)
        print("key     pinned %s · current release signed by %s%s" % (
            pinned or "none (%s)" % p.pubkey, signer or "?",
            (" · hub serves %s" % (served or "? (unreadable)")) if (sf or "--keys" in rest) else ""))
        if sf:
            print("        %s failed its signature check: %s" % (sf[0][:12], sf[1].get("reason", "")))
        if (st.get("hold") or {}).get("since"):
            h = st["hold"]
            print("hold    EPIC batches since %s (one clock for the machine, cap %dm)%s" % (
                iso(h["since"]), env_num("FLEET_EPIC_HOLD_CAP_SECS", 7200) // 60,
                " · released for %s" % h["released"][:12] if h.get("released") else ""))
        fl = fetch_line(p)
        if fl:
            print("fetch   %s" % fl)
        if "--check" in rest:
            bad = st.get("result") in ("failed", "rolled-back", "skipped") or bool(sf) or (
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
    print("usage: fleet-node-update.py tick|status [--json|--check|--keys]|doctor|versions|check-release <f>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
