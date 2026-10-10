#!/bin/sh
# fleet-installs.sh [--json] — every claude-fleet install on THIS machine, one
# table, each judged against stable (issue #2692; `fleet doctor --installs`).
#
# A machine carries three kinds of install, and until this nothing listed them
# side by side (2026-10-09: mini2's runtime at stable while every login sat
# behind it, macmini's doctor answering "unknown" for both machines):
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
# 来源 (issue #2776, EPIC #2770): where each install takes its new versions from —
#   hub      the hub's signed release (the runtime always; a login install with
#            no GitHub remote, a refs/fleet/rel/* import; a client with a hub)
#   runtime  a managed login whose files link into the machine runtime
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
# Read-only. Exit: 0 every install found is at stable · 1 one is not · 2 no
# local stable to judge against.
#
# Seams (selftest): FLEET_INSTALLS_HOMES (the homes root), FLEET_INSTALLS_SUDO
# (the privilege prefix, default `sudo -n`; empty = none), FLEET_INSTALLS_STABLE
# (the stable commit), FLEET_NODE_ROOT (the runtime root), FLEET_LIVE_DIR.
set -u
as_json=0
case "${1:-}" in
  --json) as_json=1 ;;
  '') ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'fleet-installs: unknown argument %s\n' "$1" >&2; exit 2 ;;
esac
case "$(uname -s 2>/dev/null)" in Darwin) homes_default=/Users ;; *) homes_default=/home ;; esac
live="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
stable="${FLEET_INSTALLS_STABLE-}"
[ -n "$stable" ] || stable=$(git -C "$live" rev-parse -q --verify 'refs/tags/stable^{commit}' 2>/dev/null)

exec python3 - "$as_json" "${FLEET_INSTALLS_HOMES:-$homes_default}" "${FLEET_INSTALLS_SUDO-sudo -n}" \
  "$stable" "${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}" <<'PY'
import json, os, re, socket, subprocess, sys

as_json, homes, sudo, stable, root = sys.argv[1] == "1", sys.argv[2], sys.argv[3].split(), sys.argv[4], sys.argv[5]
HEX = re.compile(r"^[0-9a-f]{7,40}$")

# One probe per home, run as whoever can read it: four lines, each `<what> <value>`.
PROBE = r'''
h=$1
d=$h/.claude/fleet
if [ -L "$d" ]; then t=$(readlink "$d"); t=${t%/}; echo "login link ${t##*/}"; echo "target $t"
elif [ -d "$d" ]; then echo "login dir $(git -C "$d" rev-parse HEAD 2>/dev/null || echo -)"
else echo "login none -"; fi
if [ -d "$d" ]; then
  echo "origin $(git -C "$d" remote get-url origin 2>/dev/null || echo -)"
  echo "rel $(git -C "$d" for-each-ref --count=1 --format=x refs/fleet/rel/ 2>/dev/null)"
  echo "lib $(readlink "$d/bin/fleet-lib.sh" 2>/dev/null || echo -)"
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
       [ -n "$v" ] || v=$(git -C "$p" rev-parse HEAD 2>/dev/null) ;;
  esac
  echo "shellv ${v:--}"
else echo "shell -"; fi
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

logins, unreadable = [], []
try:
    entries = sorted(os.listdir(homes))
except OSError:
    entries = []
for name in entries:
    home = os.path.join(homes, name)
    if not os.path.isdir(home) or name.startswith("."):
        continue
    r = probe(home)
    if r is None:
        if owner(home) not in ("", "root"):
            unreadable.append(name)
        continue
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

judged = []
def judge(obj):
    if obj is None:
        return
    obj["at_stable"] = same(obj.get("version"), stable)
    judged.append(obj["at_stable"])

rt = None
if runtime is not None:
    rt = {"version": runtime or "-", "source": "hub"}
    judge(rt)
for l in logins:
    judge(l["install"]); judge(l["shell"]); judge(l["client"])

host = socket.gethostname().split(".")[0]
if as_json:
    print(json.dumps({"host": host, "stable": stable or None, "runtime": rt,
                      "logins": logins, "unreadable": unreadable}, ensure_ascii=False))
else:
    def word(o):
        a = o.get("at_stable")
        w = "= stable" if a else ("≠ stable" if a is False else "? (unknown)")
        return "%s  来源 %s" % (w, o.get("source") or "?")
    print("claude-fleet installs — %s (stable %s)" % (host, short(stable) if stable else "unknown: no local refs/tags/stable"))
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
    srcs = [o.get("source") for o in [rt] + [x for l in logins for x in (l["install"], l["shell"], l["client"])] if o]
    print("来源: %s · github %d" % (" · ".join("%s %d" % (k, srcs.count(k)) for k in ("hub", "runtime", "dev", "?") if srcs.count(k)) or "-",
                                   srcs.count("github")))
sys.exit(2 if not stable else (0 if all(a for a in judged) else 1))
PY
