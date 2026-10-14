#!/bin/sh
# fleet-installs.sh [--json] — every claude-fleet install on THIS machine, one
# table, each judged against stable (issue #2692; `fleet doctor --installs`).
#
# A machine carries three kinds of install, and until this nothing listed them
# side by side (2026-10-09: mac-d's runtime at stable while every login sat
# behind it, mac-c's doctor answering "unknown" for both machines):
#   machine runtime  <root>/current → <root>/<sha> — the managed machine's root
#                    runtime (fleet-node-update.py). None on a machine that is
#                    not managed.
#   login install    each login's ~/.claude/fleet — a link into
#                    ~/.claude/fleet.versions/<sha> (install-sync), or a plain
#                    checkout (its HEAD; fleet-install-sync.sh adopts it at its
#                    next move).
#   client shell     each login's ~/.cache/claude-fleet/shell (fleet-shell.sh's
#                    mirror): the version its bin/ links resolve to, and whether
#                    it follows the login install's link (issue #2692) or is
#                    pinned to one version dir; plus a client install
#                    (~/.local/share/claude-fleet/.client-version) when present.
#
# 落后 (issue #2934): how long an install that is not at stable has been behind
# it — counted from the first time THIS machine saw that stable (a login's
# install-sync.state `stable_since`, the machine updater's update.json
# `target_seen`; the earliest of them). Past FLEET_INSTALLS_LAG_WARN (1800 s)
# the row says WARN, and so does a closing line. Nothing recorded = no 落后.
#
# 来源 (issue #2776, EPIC #2770): where each install takes its new versions from —
#   hub      the hub's signed release (the runtime always; a login install with
#            no GitHub remote, a refs/fleet/rel/* import; a client with a hub)
#   runtime  a managed login whose files link into the machine runtime (its
#            bin/fleet-lib.sh, or the updater's .fleet-linked mark — #2774)
#   github   a login install whose origin is GitHub, FLEET_DIST_SOURCE=github, a
#            client that follows GitHub (no hub on its .client-version)
#   dev      a local checkout (a plain dir or a link outside fleet.versions/
#            whose origin is not GitHub)
#   ?        nothing to tell from
# A shell's is the install it resolves to.
#
# Every home under /Users (/home) is looked into, not a glob (a home is 0700): a
# home the caller can read answers for itself, another through its owner
# (`sudo -n -u`), one nobody here can read is listed `unreadable` — never taken
# for a login without an install. stable is this login's LOCAL
# refs/tags/stable (install-sync keeps it fetched) — no network.
#
# 通道 (issue #3868, EPIC #3863 C5): a Mac follows refs/tags/stable-macos when
# there is one, so "stable" above is THIS machine's lane — the login's
# install-sync `channel:` names it (none = stable), its local tag is the
# commit; a managed machine with no local tag is judged against what its updater
# targets (update.json `target_seen`, `hub stable-macos` in its reason = the Mac
# lane). With a hub that names a Mac lane (/version client_version_macos), a
# `channel` line says both lanes and how far the Mac one trails stable;
# --channel prints only that line as `<PASS|INFO|WARN><TAB><text>` (the
# doctor's channel row) — nothing at all when no Mac lane is set.
#
# Read-only. Exit: 0 every install found is at stable · 1 one is not · 2 no
# local stable to judge against.
#
# Seams (selftest): FLEET_INSTALLS_HOMES (the homes root), FLEET_INSTALLS_SUDO
# (the privilege prefix, default `sudo -n`; empty = none), FLEET_INSTALLS_STABLE
# (the stable commit), FLEET_NODE_ROOT (the runtime root), FLEET_NODE_STATE (the
# machine updater's state dir), FLEET_INSTALLS_NOW (the clock), FLEET_LIVE_DIR,
# FLEET_INSTALLS_HUB (the hub's address; empty = none), FLEET_PLATFORM.
# FLEET_INSTALLS_LOGIN=<name> reads that one home only — the agent's heartbeat
# (issue #2697) asks each login for its own, with no sudo and no hub.
set -u
as_json=0
case "${1:-}" in
  --json) as_json=1 ;;
  --channel) as_json=2 ;;
  '') ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'fleet-installs: unknown argument %s\n' "$1" >&2; exit 2 ;;
esac
case "$(uname -s 2>/dev/null)" in Darwin) homes_default=/Users ;; *) homes_default=/home ;; esac
live="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
_here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fleet-versions-lib.sh
[ -f "$_here/fleet-versions-lib.sh" ] && . "$_here/fleet-versions-lib.sh"
plat=$(command -v fleet_platform >/dev/null 2>&1 && fleet_platform)
conf="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
# the lane this login follows (issue #3868): install-sync's channel: line, else stable
lane=$(sed -n 's/^channel: //p' "$conf/global/install-sync.state" 2>/dev/null | head -n 1)
case "$lane" in stable-macos) ;; *) lane=stable ;; esac
stable="${FLEET_INSTALLS_STABLE-}"
[ -n "$stable" ] || stable=$(git -C "$live" rev-parse -q --verify "refs/tags/$lane^{commit}" 2>/dev/null)
hub="${FLEET_INSTALLS_HUB-${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}}"
[ -n "${FLEET_INSTALLS_HUB+x}" ] || [ -n "$hub" ] || \
  hub=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?FLEET_HUB_URL=//p' "$conf/fleet.conf" 2>/dev/null | tail -n 1 | tr -d "\"' ")

exec python3 - "$as_json" "${FLEET_INSTALLS_HOMES:-$homes_default}" "${FLEET_INSTALLS_SUDO-sudo -n}" \
  "$stable" "${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}" \
  "${FLEET_NODE_STATE:-/var/db/fleet-node}" "${FLEET_INSTALLS_LAG_WARN:-1800}" "${FLEET_INSTALLS_NOW:-}" \
  "$lane" "${plat:-?}" "${hub%/}" "${FLEET_INSTALLS_LOGIN:-}" <<'PY'
import json, os, re, socket, subprocess, sys, time

mode = sys.argv[1]
as_json, homes, sudo, stable, root = mode == "1", sys.argv[2], sys.argv[3].split(), sys.argv[4], sys.argv[5]
lane, plat, hub, only = sys.argv[9], sys.argv[10], sys.argv[11], sys.argv[12]
node_state = sys.argv[6]
try:
    lag_warn = int(sys.argv[7])
except ValueError:
    lag_warn = 1800
try:
    clock = int(sys.argv[8]) if sys.argv[8] else int(time.time())
except ValueError:
    clock = int(time.time())
HEX = re.compile(r"^[0-9a-f]{7,40}$")

# One probe per home, run as whoever can read it: four lines, each `<what> <value>`.
PROBE = r'''
h=$1
d=$h/.claude/fleet
# a version dir's name is its sha, maybe with a suffix (-<stamp>, -linked, -own)
if [ -L "$d" ]; then t=$(readlink "$d"); t=${t%/}; k=${t##*/}; echo "login link ${k%%-*}"; echo "target $t"
elif [ -d "$d" ]; then
  # an imported hub release (#2773) is named by its upstream sha
  v=$(git -C "$d" log -1 --format=%s 2>/dev/null | sed -n 's/^fleet-release: \([0-9a-f]\{40\}\) seq=.*/\1/p')
  [ -n "$v" ] || v=$(git -C "$d" rev-parse HEAD 2>/dev/null)
  echo "login dir ${v:--}"
else echo "login none -"; fi
if [ -d "$d" ]; then
  echo "origin $(git -C "$d" remote get-url origin 2>/dev/null || echo -)"
  echo "rel $(git -C "$d" for-each-ref --count=1 --format=x refs/fleet/rel/ 2>/dev/null)"
  echo "lib $(readlink "$d/bin/fleet-lib.sh" 2>/dev/null || echo -)"
  # a tree the machine updater linked to its runtime (issue #2774): its root
  echo "linked $(sed -n 's/.*"root": *"\([^"]*\)".*/\1/p' "$d/.fleet-linked" 2>/dev/null | head -n 1)"
fi
echo "distsrc $(sed -n 's/^[[:space:]]*\(export \)\{0,1\}FLEET_DIST_SOURCE=["'"'"']\{0,1\}\([a-z]*\).*/\2/p' "$h/.config/claude-fleet/fleet.conf" 2>/dev/null | tail -n 1)"
s=$h/.cache/claude-fleet/shell/bin/fleet-shell.sh
if [ -L "$s" ]; then
  t=$(readlink "$s"); l=${t%/bin/*}
  p=$(cd "$l" 2>/dev/null && pwd -P) || p=-
  echo "shell $l"; echo "shellp $p"
  case "$p" in
    *.versions/*) v=${p##*/} ;;
    *) v=$(sed -n 's/^version=//p' "$p/.client-version" 2>/dev/null | head -n 1)
       [ -n "$v" ] || v=$(git -C "$p" log -1 --format=%s 2>/dev/null | sed -n 's/^fleet-release: \([0-9a-f]\{40\}\) seq=.*/\1/p')
       [ -n "$v" ] || v=$(git -C "$p" rev-parse HEAD 2>/dev/null) ;;
  esac
  echo "shellv ${v:--}"
else echo "shell -"; fi
f=$h/.config/claude-fleet/global/install-sync.state
echo "syncstable $(sed -n 's/^stable: //p' "$f" 2>/dev/null | head -n 1)"
echo "syncsince $(sed -n 's/^stable_since: //p' "$f" 2>/dev/null | head -n 1)"
c=$h/.local/share/claude-fleet/.client-version
v=$(sed -n 's/^version=//p' "$c" 2>/dev/null | head -n 1)
echo "client ${v:--}"
if grep -q '^hub=' "$c" 2>/dev/null; then echo "clienthub $(sed -n 's/^hub=//p' "$c" | head -n 1)"; fi
'''

def owner(path):
    try:
        import pwd
        return pwd.getpwuid(os.stat(path).st_uid).pw_name
    except Exception:
        return ""

me = os.environ.get("USER") or owner(os.path.expanduser("~"))

def probe(home):
    """The probe's lines as a dict, or None when nobody here can read the home."""
    readable = os.access(home, os.X_OK) and (not os.path.exists(home + "/.claude") or os.access(home + "/.claude", os.X_OK))
    cmd = ["sh", "-c", PROBE, "_", home]
    if not readable:
        o = owner(home)
        if not o or o == me or not sudo:
            return None
        cmd = sudo + ["-u", o] + cmd
    try:
        out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20,
                             stdin=subprocess.DEVNULL).stdout.decode("utf-8", "replace")
    except Exception:
        return None
    r = {}
    for line in out.splitlines():
        k, _, v = line.partition(" ")
        r[k] = v.strip()
    return r if "login" in r else None

def same(a, b):
    if not a or not b or a == "-" or b == "-":
        return None
    n = min(len(a), len(b))
    if HEX.match(a) and HEX.match(b) and n >= 7:
        return a[:n] == b[:n]
    return a == b

GH = re.compile(r"(^|[@/.])github\.com[:/]")

def login_source(r, kind):
    """来源 of a login install (see the header)."""
    if r.get("distsrc") == "github":
        return "github"
    lib = r.get("lib", "-")
    if lib.startswith("/") and root and lib.startswith(root.rstrip("/") + "/"):
        return "runtime"
    if root and r.get("linked") and os.path.realpath(r["linked"]) == os.path.realpath(root):
        return "runtime"
    origin = r.get("origin", "-")
    if GH.search(origin):
        return "github"
    if r.get("rel") or (kind == "link" and origin == "-" and "/fleet.versions/" in r.get("target", "")):
        return "hub"
    if kind == "dir" or "/fleet.versions/" not in r.get("target", ""):
        return "dev"
    return "?"

def client_source(r):
    if "clienthub" not in r:
        return "?"
    return "hub" if r["clienthub"] else "github"

def short(v):
    return v[:7] if v and HEX.match(v) else (v or "-")

runtime = None
cur = os.path.join(root, "current")
if os.path.islink(cur):
    b = os.path.basename(os.readlink(cur).rstrip("/"))
    runtime = b if re.match(r"^[0-9a-f]{40}$", b) else ""

try:
    upd = json.load(open(os.path.join(node_state, "update.json"))) or {}
except (OSError, ValueError):
    upd = {}
upd = upd if isinstance(upd, dict) else {}
# the hub's word (issue #3868): its stable, and its Mac lane when it names one
hubv = {}
if hub.startswith(("http://", "https://")):
    try:
        out = subprocess.run(["curl", "-fsS", "--max-time", "5", hub + "/version"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=10).stdout
        hubv = json.loads(out.decode("utf-8", "replace") or "{}")
    except Exception:
        hubv = {}
    hubv = hubv if isinstance(hubv, dict) else {}
SHA40 = re.compile(r"^[0-9a-f]{40}$")
chan = None
if SHA40.match(str(hubv.get("client_version_macos") or "")):
    chan = {"stable": hubv.get("stable"), "stable_macos": hubv.get("client_version_macos"),
            "behind": int(hubv.get("stable_macos_behind") or 0), "behind_secs": None}
    try:
        import calendar
        b = time.strptime(str(hubv.get("stable_macos_behind_since") or ""), "%Y-%m-%dT%H:%M:%SZ")
        chan["behind_secs"] = max(0, clock - calendar.timegm(b))
    except ValueError:
        pass

# a managed machine has no local tag: judged against what its updater follows —
# its update.json target (the Mac lane when its reason says so), else the hub's
# word for this platform (a login cannot always read the updater's state)
if not stable and runtime is not None:
    t = (upd.get("target_seen") or {}).get("sha") if isinstance(upd.get("target_seen"), dict) else None
    if isinstance(t, str) and SHA40.match(t):
        stable = t
        if "hub stable-macos" in str(upd.get("reason") or ""):
            lane = "stable-macos"
    elif chan and plat == "darwin":
        stable, lane = chan["stable_macos"], "stable-macos"
    elif SHA40.match(str(hubv.get("stable") or "")):
        stable = hubv["stable"]

# when this machine first saw stable (issue #2934): the earliest record of it
seen = []
try:
    ts = upd.get("target_seen") or {}
    if same(ts.get("sha"), stable) and int(ts.get("at") or 0) > 0:
        seen.append(int(ts["at"]))
except (OSError, ValueError, TypeError, AttributeError):
    pass

logins, unreadable = [], []
try:
    entries = sorted(os.listdir(homes))
except OSError:
    entries = []
for name in entries:
    home = os.path.join(homes, name)
    if not os.path.isdir(home) or name.startswith(".") or (only and name != only):
        continue
    r = probe(home)
    if r is None:
        if owner(home) not in ("", "root"):
            unreadable.append(name)
        continue
    if same(r.get("syncstable"), stable) and r.get("syncsince", "").isdigit() and int(r["syncsince"]) > 0:
        seen.append(int(r["syncsince"]))
    kind, _, ver = r["login"].partition(" ")
    lsrc = None if kind == "none" else login_source(r, kind)
    shell = None
    if r.get("shell", "-") != "-":
        follows = os.path.basename(r["shell"]) == "fleet" and r["shell"].endswith("/.claude/fleet")
        sp = r.get("shellp", "-")
        ssrc = lsrc if (follows or "/.claude/fleet" in sp) else (client_source(r) if "/.local/share/claude-fleet" in sp else "?")
        shell = {"version": r.get("shellv", "-"), "follows": follows, "source": ssrc or "?"}
    client = r.get("client", "-")
    if kind == "none" and shell is None and client == "-":
        continue
    logins.append({"login": name,
                   "install": None if kind == "none" else {"kind": kind, "version": ver, "source": lsrc},
                   "shell": shell,
                   "client": None if client == "-" else {"version": client, "source": client_source(r)}})

since = min(seen) if seen else None
judged, late = [], []
def judge(obj):
    if obj is None:
        return
    obj["at_stable"] = same(obj.get("version"), stable)
    judged.append(obj["at_stable"])
    if obj["at_stable"] is False:
        obj["behind_secs"] = max(0, clock - since) if since else None
        obj["late"] = bool(since and obj["behind_secs"] > lag_warn)
        if obj["late"]:
            late.append(obj)

rt = None
if runtime is not None:
    rt = {"version": runtime or "-", "source": "hub"}
    judge(rt)
for l in logins:
    judge(l["install"]); judge(l["shell"]); judge(l["client"])

host = socket.gethostname().split(".")[0]

def dur(secs):
    m = secs // 60
    return "%dm" % m if m < 120 else ("%dh%02dm" % (m // 60, m % 60) if m < 2880 else "%dd" % (m // 1440))

def channel_line():
    """(level, text) of the channel row, or None with no Mac lane (issue #3868)."""
    if chan is None and lane == "stable":
        return None
    mine = "本机 %s 跟 %s" % (plat, lane)
    if stable:
        mine += " (%s)" % short(stable)
    lv = "PASS"
    behind = [o.get("behind_secs") for o in ([rt] + [x for l in logins for x in (l["install"], l["shell"], l["client"])])
              if o and o.get("at_stable") is False]
    if behind:
        b = max([x for x in behind if x is not None] or [0])
        mine += " · 本机落后它 %s" % (dur(b) if b else "?")
        lv = "WARN" if late else "INFO"
    if chan is None:
        return lv, mine + " · 入口没报 Mac 通道"
    lanes = "Linux 跟 stable %s · Mac 跟 stable-macos %s" % (short(chan["stable"] or ""), short(chan["stable_macos"]))
    if chan["behind"]:
        lanes += " · Mac 通道落后 stable %d 版" % chan["behind"]
        if chan["behind_secs"] is not None:
            lanes += " %s" % dur(chan["behind_secs"])
            if chan["behind_secs"] > 7200:   # 「Mac 停在旧版超过 2 小时提醒」(EPIC #3863)
                lv = "WARN"
                lanes += "（超过 2 小时：macOS 那半红了或没跑）"
    else:
        lanes += " · Mac 通道与 stable 同版"
    return lv, mine + " · " + lanes

if mode == "2":
    c = channel_line()
    if c:
        print("%s\t%s" % c)
    sys.exit(0)
if as_json:
    print(json.dumps({"host": host, "stable": stable or None, "lane": lane, "platform": plat, "stable_seen": since,
                      "lag_warn": lag_warn, "late": len(late), "runtime": rt, "logins": logins,
                      "unreadable": unreadable, "channel": chan},
                     ensure_ascii=False))
else:
    def word(o):
        a = o.get("at_stable")
        w = "= stable" if a else ("≠ stable" if a is False else "? (unknown)")
        if a is False and o.get("behind_secs") is not None:
            w += " · 落后 %s%s" % (dur(o["behind_secs"]), " WARN" if o.get("late") else "")
        return "%s  来源 %s" % (w, o.get("source") or "?")
    print("claude-fleet installs — %s (%s %s)" % (host, lane, short(stable) if stable else "unknown: no local refs/tags/%s" % lane))
    if rt is None:
        print("  machine runtime  none (not a managed machine)")
    else:
        print("  machine runtime  %-8s %s" % (short(rt["version"]), word(rt)))
    rows = [(l["login"], l["install"]) for l in logins if l["install"]]
    for i, (n, o) in enumerate(rows):
        extra = "  (plain checkout — adopted at its next move)" if o["kind"] == "dir" else ""
        print("  %-16s %-14s %-8s %s%s" % ("login install" if i == 0 else "", n, short(o["version"]), word(o), extra))
    if not rows:
        print("  login install    none")
    rows = [(l["login"], "shell", l["shell"]) for l in logins if l["shell"]] + \
           [(l["login"], "client", l["client"]) for l in logins if l["client"]]
    for i, (n, what, o) in enumerate(rows):
        if what == "shell":
            extra = "  (follows its login install)" if o["follows"] else "  (pinned to one version dir until the next install switch reloads it)"
        else:
            extra = "  (client install)"
        print("  %-16s %-14s %-8s %s%s" % ("client shell" if i == 0 else "", n, short(o["version"]), word(o), extra))
    if not rows:
        print("  client shell     none")
    if unreadable:
        print("  unreadable       %s (no passwordless sudo here — run as an admin login)" % " ".join(unreadable))
    n_ok = sum(1 for a in judged if a)
    print("verdict: %d of %d install(s) at stable" % (n_ok, len(judged)))
    if late:
        print("WARN: %d install(s) behind stable for over %dm — stable %s first seen here %s"
              % (len(late), lag_warn // 60, short(stable),
                 time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since))))
    c = channel_line()
    if c:
        print("channel: %s" % c[1])
    srcs = [o.get("source") for o in [rt] + [x for l in logins for x in (l["install"], l["shell"], l["client"])] if o]
    print("来源: %s · github %d" % (" · ".join("%s %d" % (k, srcs.count(k)) for k in ("hub", "runtime", "dev", "?") if srcs.count(k)) or "-",
                                   srcs.count("github")))
sys.exit(2 if not stable else (0 if all(a for a in judged) else 1))
PY
