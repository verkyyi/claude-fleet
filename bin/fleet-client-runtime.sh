#!/bin/bash
# fleet-client-runtime.sh — which installed files a client-only computer really
# uses (issue #4824, EPIC #4823 C1). The answer is conf/client-runtime.list: one
# line per file of the client package (fleetclient/manifest) that a client
# action opened or ran, with the actions that did. C2 C3 C4 read it — a file
# stays in the client package only when it is on that list or the installer
# itself runs it (EPIC #4823 共同约定 1).
#
#   fleet-client-runtime.sh --check [<list> [<manifest>]]
#       every path on the list is in the manifest, every file the manifest
#       INSTALLS (all but its `served` lines, issue #4826) is on the list, every
#       line `<path> TAB <use>[,<use>…]`, no path twice, each use a known
#       action, `<action>:read` or `static`; exit 0 · 1 a finding (one line
#       each) · 2 usage. And every repo bin/ file an installed script names in a
#       code line is installed, served, or excused in NOT_HERE (below) — the
#       package never forgets a file a client road runs (BREAK-IT
#       client-pack-file-missing)
#   fleet-client-runtime.sh trace <out dir> [--live-user <login>] [--machine <m>]
#       (Linux, strace, root when --live-user) installs THIS tree's client into
#       a sandbox with bin/fleet-install.sh (FLEET_INSTALL_SRC=file://, no hub
#       download), then runs every client action under `strace -ff -e
#       trace=execve,openat` and keeps the successful opens / execs that land in
#       the install: <out dir>/<action>.strace (raw) + used.tsv (path TAB use)
#   fleet-client-runtime.sh parse <strace -ff prefix> <install root> <action>
#       one action's used.tsv lines off its per-process strace files (trace's step)
#   fleet-client-runtime.sh build <out dir>… [--write <list>]
#       merges the traces' used.tsv, adds the static closure (below) and prints
#       the list (or writes it)
#
# A use is the action's name when the file RAN in it — exec'd, the script an
# interpreter was started on (`awk -f` too), a bin/ module python imported (its
# __pycache__ entry read or written), a bin/ file a sh / bash opened (a `.`) —
# and `<action>:read` when the fleet's own code only read it as data (the doctor
# reading the Agent package it compares, a conf/ table). A tool's open is no use
# at all: the installer's cp / cmp / curl of every file would otherwise put the
# whole package on the list.
#
# The actions (`trace`):
#   install      fleet-install.sh itself (sandbox HOME, FLEET_INSTALL_NO_RUN=1)
#   help         fleet --help
#   status       fleet status
#   update       fleet update (status: what this computer is, where it stands)
#   doctor       fleet doctor (the client's rows + its Agent package)
#   login        fleet login, the first step (a sandbox HOME with the hub's
#                address and no certificate; stopped after the scan link)
#   logout       fleet logout (sandbox: nothing signed in)
#   host-on      fleet host on, up to its question (answered N: nothing downloaded)
#   and with --live-user (a signed-in client; this tree's files, that login's
#   HOME and certificate):
#   view         bare `fleet` on a pseudo-terminal: drawn, a file dropped onto it
#                (a bracketed paste of a picture's path), then the terminal closed
#   ls · show · answer   fleet ls / show <a session> / answer <no such session>
#                (never answers a real question)
#   connect      fleet connect --pick <m> and fleet connect <m> hostname
#   doctor-live  fleet doctor with the certificate (cert · tls rows)
#   update-live  fleet update as that login
#   and two uses no trace takes, written by hand (issue #4826):
#   agent        the node agent a login starts runs it from the install
#                (none since #4886: the probe and the sleep watch are a
#                managed node's, a client runs no session)
#   dispatch     a `fleet <word>` the actions above do not run (fleet route,
#                fleet ls --services, fleet show <file> …) — the word is the
#                client's, so is its script
#
# Static closure (`build`, the safety net under the trace — a branch the actions
# did not take): the code lines (comments skipped) of a file that RAN, naming
# another manifest file by its file name, add that file as `static` — one hop,
# a static file's own names are not followed. fleet-lib.sh, fleet-client-core.sh
# and bin/fleet's dispatch loop are not followed (the lib names every script of
# the fleet, the core names the lib it loads only on a hosting machine; the
# dispatch is the `fleet-<word>` of every one) — a client command reached only
# that way is an action above, or it is not the client's.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$BIN/.." && pwd)
MANIFEST_DEF="$REPO/tokenledger/hub/api/fleetclient/manifest"
LIST_DEF="$REPO/conf/client-runtime.list"
ACTIONS="install help status update doctor login logout host-on view ls show answer connect doctor-live update-live agent dispatch static"

usage() { sed -n '/^#   fleet-client-runtime.sh --check/,/the list (or writes it)$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# NOT_HERE — bin/ files a client package script NAMES but a client-only computer
# never runs (issue #4826): --check's reference rule excuses exactly these.
#   on the home machine — run there over the thin loop, or that machine's code:
#     fleet-hub-sessions.sh fleet-remote-view.sh fleet-quickopen.py fleet_view.py
#     tmux-dashboard-rows.sh fleet_thin_lease.py fleet-window-reap.sh
#     fleet-peerlink.py fleet-node-supervisor.py
#     fleet-topbar.py fleet-alerts.sh (named in fleet_notice.py's own words: the
#     看台's top line draws a notice, the alerts' events are recorded too — T675)
#     fleet-orphan-reports.py fleet-view-go.sh (fleet_notice.py's page and message
#     row: a machine's results nobody took, a 看台's switch — T701; a client's
#     `fleet notices` reads neither) and fleet_notify.py fleet-report-parent.sh
#     (named as the book's writers, which run on a machine)
#     fleet_reap_notice.py (lazy import inside fleet_reap_policy.explain, called
#     only by the node doctor; client policy parsing/labels never call explain)
#     fleet_session_gate.py fleet_id.py (lazy imports in the node-only report
#     begin/finish commands; client policy parsing/labels never submit reports)
#     fleet_task_control.py (lazy CLI row/cancel helpers after forwarding home)
#     fleet-task-record.sh (fleet_dispatch.read_current is a node-side start
#     fence; client dispatch construction/validation never reads node records)
#   words fleet-ui-lang.sh only prints (a hint naming a machine's command):
#     dash-reap.sh fleet-account.sh fleet-migrate.sh fleet-repo.sh fleet-webchat.sh
#   承载's, each behind a presence test that says so or takes the client road:
#     fleet-lib.sh fleet-doctor.sh fleet-up.sh fleet-install-sync.sh
#     fleet-login-bootstrap.sh fleet-dev-mode.sh fleet-run.sh fleet-agent-bundle.py
#     fleet-agent-team.py fleet-daemon-lib.sh fleet-cred-proxy.sh fleet-credsep.sh
#     fleet-peer-cert.sh fleet-node-shell-retire.sh fleet_cred_ctl.py
#     fleet_sidefx.py fleet-browser.sh fleet-control-read.sh
#     fleet-node-probe.sh (a managed node's, #4886 — fleet-node.sh tests for it)
#     fleet-hook-conf.sh (hosting config only; fleet-client-place.sh tests for it,
#     a client-only install uses the environment / hub default instead)
NOT_HERE="fleet-hub-sessions.sh fleet-remote-view.sh fleet-quickopen.py fleet_view.py
  tmux-dashboard-rows.sh fleet_thin_lease.py fleet-window-reap.sh fleet-peerlink.py
  fleet-node-supervisor.py fleet-topbar.py fleet-alerts.sh fleet-orphan-reports.py fleet-view-go.sh
  fleet_notify.py fleet-report-parent.sh dash-reap.sh fleet-account.sh fleet-migrate.sh fleet-repo.sh fleet-webchat.sh
  fleet-lib.sh fleet-doctor.sh fleet-up.sh fleet-install-sync.sh fleet-login-bootstrap.sh
  fleet-dev-mode.sh fleet-run.sh fleet-agent-bundle.py fleet-agent-team.py fleet-daemon-lib.sh
  fleet-cred-proxy.sh fleet-credsep.sh fleet-peer-cert.sh fleet_cred_ctl.py
  fleet-node-shell-retire.sh fleet_sidefx.py fleet-browser.sh fleet-control-read.sh
  fleet-node-probe.sh fleet-board-diff.py fleet-hook-conf.sh fleet_reap_notice.py fleet_session_gate.py fleet_id.py
  fleet_task_control.py fleet-task-record.sh"

check() {
  local list=${1:-$LIST_DEF} man=${2:-$MANIFEST_DEF}
  [ -f "$list" ] || { echo "client-runtime: no list at $list" >&2; return 2; }
  [ -f "$man" ] || { echo "client-runtime: no manifest at $man" >&2; return 2; }
  python3 - "$list" "$man" "$ACTIONS" "$REPO" "$NOT_HERE" <<'PY'
import os, re, sys
lst, man, known, repo = sys.argv[1], sys.argv[2], set(sys.argv[3].split()), sys.argv[4]
not_here = set(sys.argv[5].split())
inman, installs = set(), []
for line in open(man, encoding="utf-8"):
    s = line.split("#", 1)[0].split()
    if s:
        inman.add(s[0])
        if s[1:2] != ["served"]:
            installs.append(s[0])
seen, bad = set(), 0
for n, line in enumerate(open(lst, encoding="utf-8"), 1):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    fs = line.split("\t")
    if len(fs) != 2 or not fs[0] or not fs[1]:
        print("%s:%d: not <path> TAB <actions>: %r" % (lst, n, line)); bad = 1; continue
    p, acts = fs
    if p in seen:
        print("%s:%d: %s twice" % (lst, n, p)); bad = 1
    seen.add(p)
    if p not in inman:
        print("%s:%d: %s is not in the client manifest" % (lst, n, p)); bad = 1
    for a in acts.split(","):
        if a.split(":read")[0] not in known or (a.endswith(":read") and a.count(":") != 1) or a == "static:read":
            print("%s:%d: %s: unknown action %r" % (lst, n, p, a)); bad = 1
# the other way (issue #4826, EPIC #4823 共同约定 1): a file the client installs
# is one a client action uses — else it is `served`, or not the client's
for p in installs:
    if p not in seen:
        print("%s: %s is installed by the client manifest but on no line of %s — serve it (`served`) or drop it" % (man, p, lst)); bad = 1
# what the installed scripts name (issue #4826, BREAK-IT client-pack-file-missing):
# a bin/ file of the repo named in a code line is installed, served, or one of
# NOT_HERE — never a file the package simply forgot
here = {os.path.basename(p) for p in inman}
rbin = os.path.join(repo, "bin")
names = {n for n in os.listdir(rbin) if os.path.isfile(os.path.join(rbin, n)) and "selftest" not in n
         and n not in here and n not in not_here} if os.path.isdir(rbin) else set()
TOKEN = re.compile(r"[A-Za-z0-9_.-]+")
for p in installs:
    if not p.startswith("bin/"):
        continue
    try:
        text = open(os.path.join(repo, p), encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for i, l in enumerate(text, 1):
        st = l.strip()
        if st.startswith("#") or st.startswith("//") or st.startswith('"""'):
            continue
        code = l.split(" # ", 1)[0]
        imp = "import " in code   # `import fleet_iso` names bin/fleet_iso.py
        for t in TOKEN.findall(code):
            t = t.rstrip(".")
            for n in (t, t + ".py") if imp else (t,):
                if n in names:
                    print("%s:%d: names bin/%s, which the client package neither installs nor serves — add it, or say in NOT_HERE why a client never runs it" % (p, i, n)); bad = 1
sys.exit(bad)
PY
}

# parse <strace -ff prefix> <install root> <action> — used.tsv's lines for one
# action, off its per-process files <prefix>.<pid> (each removed once read)
parse() {
  python3 - "$1" "$2" "$3" <<'PY'
import glob, os, re, sys
path, root, act = sys.argv[1], os.path.normpath(sys.argv[2]) + "/", sys.argv[3]
INTERP = {"python3", "python", "sh", "bash", "dash", "zsh"}
prog, use = {}, {}
def rel(p):
    p = os.path.normpath(p)
    if not p.startswith(root):
        return None
    r = p[len(root):]
    return r if os.path.isfile(os.path.join(root, r)) else None
def pyc(p):
    """bin/__pycache__/<stem>.cpython-NN.pyc[.tmp] → bin/<stem>.py: an import."""
    p = os.path.normpath(p)
    m = re.match(re.escape(root) + r'(.*)/__pycache__/([^/.]+)\.[^/]*\.pyc(\.\d+)?$', p)
    return rel(root + "%s/%s.py" % (m.group(1), m.group(2))) if m else None
def mark(r, run):
    if r:
        use[r] = use.get(r, False) or run
# -ff: one file per process (<action>.strace.<pid>), so no call is ever split
# across lines by another process's; the files in pid order
lines = []
for fn in sorted(glob.glob(path + ".*"), key=lambda x: int(x.rsplit(".", 1)[1])):
    pid = fn.rsplit(".", 1)[1]
    lines += [(pid, l) for l in open(fn, errors="replace")]
    os.unlink(fn)
for pid, line in lines:
    m = re.match(r'(execve|openat)\((?:AT_FDCWD, )?"([^"]+)"(.*)\) = (-?\d+)', line)
    if not m:
        continue
    call, p, rest = m.group(1), m.group(2), m.group(3)
    if call == "openat" and pyc(p):   # read or (re)written, found or not: python imported it
        mark(pyc(p), True)
        continue
    if int(m.group(4)) < 0:
        continue
    if call == "execve":
        argv = re.findall(r'"((?:[^"\\]|\\.)*)"', rest.split("]", 1)[0])
        prog[pid] = os.path.basename(p)
        if rel(p):   # an installed script: the process is its #! interpreter
            mark(rel(p), True)
            try:
                bang = open(p, "rb").readline().decode("utf-8", "replace")
            except OSError:
                bang = ""
            if bang.startswith("#!"):
                w = bang[2:].split()
                w = w[1:] if w and os.path.basename(w[0]) == "env" else w
                prog[pid] = os.path.basename(w[0]) if w else prog[pid]
        if prog[pid] in INTERP:   # the script it was started on
            for a in argv[1:]:
                if not a.startswith("-"):
                    mark(rel(a), True)
                    break
        elif prog[pid] in ("awk", "gawk", "mawk") and "-f" in argv[:-1]:
            mark(rel(argv[argv.index("-f") + 1]), True)
        continue
    if "O_DIRECTORY" in rest:
        continue
    r = rel(p)
    # data is what the fleet's own code reads; a tool's open (cp · cmp · curl ·
    # find · grep · sed — the installer's copy and check of every file) is not a use
    # a sh / bash opening a bin/ file sources it; python opening a .py itself reads
    # it (an import goes through its __pycache__, above; a script is its execve)
    if r and prog.get(pid) in INTERP and "O_WRONLY" not in rest and "O_RDWR" not in rest:
        mark(r, r.startswith("bin/") and not prog[pid].startswith("python"))
for r in sorted(use):
    print("%s\t%s" % (r, act if use[r] else act + ":read"))
PY
}

# --- trace --------------------------------------------------------------------
trace() {
  local out="" live="" machine=""
  while [ $# -gt 0 ]; do
    case $1 in
      --live-user) live=$2; shift 2 ;;
      --machine) machine=$2; shift 2 ;;
      -*) usage ;;
      *) out=$1; shift ;;
    esac
  done
  [ -n "$out" ] || usage
  [ "$(uname -s)" = Linux ] || { echo "client-runtime trace: Linux only (strace)" >&2; return 2; }
  command -v strace >/dev/null || { echo "client-runtime trace: no strace" >&2; return 2; }
  mkdir -p "$out"; out=$(cd "$out" && pwd)
  local W="$out/work" SRC ROOT SB
  rm -rf "${W:?}"; mkdir -p "$W"; chmod 755 "$out" "$W"
  SRC="$W/src"; ROOT="$W/root"; SB="$W/home"
  # the tree as a file:// source in the repo's layout: the manifest + its files
  mkdir -p "$SRC/tokenledger/hub/api/fleetclient" "$SB"
  cp "$MANIFEST_DEF" "$SRC/tokenledger/hub/api/fleetclient/manifest"
  awk '!/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST_DEF" | while read -r p; do
    mkdir -p "$SRC/$(dirname "$p")"; cp -p "$REPO/$p" "$SRC/$p"
  done
  local hub=""
  if [ -n "$live" ]; then
    local lh; lh=$(getent passwd "$live" | cut -d: -f6)
    hub=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}FLEET_HUB_URL=//p' "$lh/.config/claude-fleet/fleet.conf" 2>/dev/null | tail -n 1 | tr -d "\"' ")
  fi
  : > "$out/used.tsv"; : > "$out/rc.txt"
  # st <action> <cmd…> — one action under strace, its opens kept
  st() {
    local a=$1; shift
    timeout -s KILL "${RT_TIMEOUT:-90}" strace -ff -qq -s 512 -o "$out/$a.strace" -e trace=execve,openat "$@" \
      > "$out/$a.out" 2>&1 < "${RT_STDIN:-/dev/null}"
    echo "$a rc=$?" >> "$out/rc.txt"
    rm -f "$out/$a.strace"; cat "$out/$a.strace".* > "$out/$a.strace" 2>/dev/null   # one file, kept raw
    parse "$out/$a.strace" "$ROOT" "$a" >> "$out/used.tsv"
  }
  # install: this tree, no hub, nothing run after
  RT_TIMEOUT=300 st install env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$SB" LANG=C.UTF-8 \
    FLEET_INSTALL_SRC="file://$SRC" FLEET_INSTALL_HOME="$ROOT" FLEET_INSTALL_NO_RUN=1 \
    FLEET_INSTALL_BIN="$SB/.local/bin" sh "$SRC/bin/fleet-install.sh" --no-deps
  [ -x "$ROOT/bin/fleet" ] || { echo "client-runtime trace: the install did not land ($out/install.out)" >&2; return 1; }
  chmod -R a+rX "$W"
  # the sandbox computer: the hub's address when there is one, no certificate
  mkdir -p "$SB/.config/claude-fleet"
  [ -n "$hub" ] && printf 'FLEET_HUB_URL=%s\n' "$hub" >> "$SB/.config/claude-fleet/fleet.conf"
  local sbenv="env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=$SB LANG=C.UTF-8 TERM=xterm-256color"
  st help $sbenv "$ROOT/bin/fleet" --help
  st status $sbenv "$ROOT/bin/fleet" status
  st update $sbenv "$ROOT/bin/fleet" update
  st doctor $sbenv "$ROOT/bin/fleet" doctor
  st logout $sbenv "$ROOT/bin/fleet" logout
  RT_TIMEOUT=20 st login $sbenv FLEET_LOGIN_NO_BROWSER=1 "$ROOT/bin/fleet" login
  printf 'n\n' > "$W/no"; RT_STDIN="$W/no" st host-on $sbenv "$ROOT/bin/fleet" host on
  [ -n "$live" ] || return 0
  # the live login: its HOME and certificate, this tree's files, never its own install's
  local lh; lh=$(getent passwd "$live" | cut -d: -f6)
  # its install's version mark, so `start` / `update` ask the hub as they do there
  # (the same version: nothing staged, nothing switched — the check is traced)
  [ -f "$lh/.claude/fleet/.client-version" ] && cp "$lh/.claude/fleet/.client-version" "$ROOT/" && chmod 644 "$ROOT/.client-version"
  local LW="$W/live"   # what the login itself writes (the terminal's screen)
  mkdir -p "$LW"; chown "$live" "$LW"
  local as="runuser -u $live -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=$lh USER=$live LANG=C.UTF-8 TERM=xterm-256color FLEET_CLIENT_CHECK_SECS=0"
  st ls $as "$ROOT/bin/fleet" ls
  local first; first=$(runuser -u "$live" -- env HOME="$lh" "$ROOT/bin/fleet" ls --json 2>/dev/null \
    | python3 -c 'import json,sys
try: r=json.load(sys.stdin)
except Exception: r=[]
r=r.get("rows", r) if isinstance(r, dict) else r
print((r[0].get("key") or r[0].get("name") or "") if r else "")' 2>/dev/null)
  [ -n "$first" ] && st show $as "$ROOT/bin/fleet" show "$first"
  st answer $as "$ROOT/bin/fleet" answer zz-no-such-session-4824
  [ -n "$machine" ] || machine=$(runuser -u "$live" -- env HOME="$lh" python3 "$ROOT/bin/fleet-connect.py" --pick 2>/dev/null | head -n 1 | awk '{print $1}')
  if [ -n "$machine" ]; then
    st connect $as sh -c "'$ROOT/bin/fleet' connect --pick '$machine'; '$ROOT/bin/fleet' connect '$machine' -- hostname"
  fi
  st doctor-live $as "$ROOT/bin/fleet" doctor
  st update-live $as "$ROOT/bin/fleet" update
  # the view: a terminal of its own, a picture dropped on it, then closed
  python3 -c 'import base64,sys; open(sys.argv[1],"wb").write(base64.b64decode(
"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="))' "$W/drop.png"
  chmod 644 "$W/drop.png"
  cat > "$W/term.py" <<'PY'
import os, pty, select, signal, sys, time
drop, stay = sys.argv[1], float(sys.argv[2])
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[3], sys.argv[3:])
buf, t0, sent, log = b"", time.time(), False, open(os.environ["RT_SCREEN"], "wb")
while time.time() - t0 < stay:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        log.write(d); buf = (buf + d)[-4096:]
        if b"\x1b[6n" in d:
            os.write(fd, b"\x1b[1;1R")
    if not sent and time.time() - t0 > stay / 2:
        os.write(fd, b"\x1b[200~" + drop.encode() + b"\x1b[201~")
        sent = True
os.kill(pid, signal.SIGHUP)
time.sleep(3)
try:
    os.kill(pid, signal.SIGKILL)
except OSError:
    pass
PY
  RT_TIMEOUT=120 st view $as RT_SCREEN="$LW/view.screen" FLEET_CLIENT_UPDATED= \
    python3 "$W/term.py" "$W/drop.png" "${RT_VIEW_SECS:-40}" "$ROOT/bin/fleet"
}

# --- build ---------------------------------------------------------------------
build() {
  local dirs="" write=""
  while [ $# -gt 0 ]; do
    case $1 in
      --write) write=$2; shift 2 ;;
      *) dirs="$dirs $1"; shift ;;
    esac
  done
  [ -n "$dirs" ] || usage
  # shellcheck disable=SC2086  # the dirs are words
  python3 - "$REPO" "$MANIFEST_DEF" "$ACTIONS" "${write:--}" "$LIST_DEF" $dirs <<'PY'
import os, re, sys
repo, man, order, write, prev = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4], sys.argv[5]
dirs = sys.argv[6:]
files = [l.split("#", 1)[0].split()[0] for l in open(man, encoding="utf-8") if l.split("#", 1)[0].split()]
used = {}   # path -> {action: ran?}
for d in dirs:
    for line in open(os.path.join(d, "used.tsv"), encoding="utf-8"):
        p, a = line.rstrip("\n").split("\t")
        if p in files:
            act, ran = a.split(":read")[0], not a.endswith(":read")
            u = used.setdefault(p, {})
            u[act] = u.get(act, False) or ran
# static: code lines of a traced file naming another manifest file
names = {os.path.basename(p): p for p in files}
# fleet-client-core.sh names fleet-lib.sh only to load it where it is installed
# (fleet_host_lib: a hosting machine's branch, issue #4825)
skip_from = {"bin/fleet-lib.sh", "bin/fleet-client-core.sh"}
def code(path):
    try:
        text = open(os.path.join(repo, path), encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return []
    out = []
    for l in text:
        s = l.strip()
        if s.startswith("#") or s.startswith('"""') or s.startswith("//"):
            continue
        out.append(l.split(" # ", 1)[0])
    return out
frontier = [p for p, u in used.items() if any(u.values()) and p not in skip_from]
done = set()
while frontier:
    p = frontier.pop()
    if p in done:
        continue
    done.add(p)
    for l in code(p):
        if p == "bin/fleet" and "fleet-$cmd" in l:
            continue
        for n, q in names.items():
            if q != p and q not in used and re.search(r"(^|[^A-Za-z0-9_.-])" + re.escape(n) + r"($|[^A-Za-z0-9_-])", l):
                used[q] = {"static": True}   # one hop: a static file's own names are not followed
# the hand-written uses no trace makes (`agent`, `dispatch` — issue #4826) carry over
try:
    for line in open(write if write != "-" else prev, encoding="utf-8"):   # the list it replaces
        f = line.rstrip("\n").split("\t")
        if len(f) == 2 and not f[0].startswith("#") and f[0] in files:
            for a in f[1].split(","):
                if a in ("agent", "dispatch"):
                    used.setdefault(f[0], {})[a] = True
except OSError:
    pass
rank = {a: i for i, a in enumerate(order)}
lines = ["# conf/client-runtime.list — the client package's files a client-only computer",
         "# really uses (issue #4824, EPIC #4823 C1): <path> TAB <the actions that used it>.",
         "# Made by bin/fleet-client-runtime.sh (trace on Linux under strace, then build);",
         "# `<action>:read` = only read as data there; `static` = named in a file that ran,",
         "# on a branch no action took.",
         "# `agent` / `dispatch` (issue #4826) are written by hand: the node agent runs it,",
         "# a `fleet <word>` no traced action takes.",
         "# bin/fleet-client-runtime.sh --check holds this list and fleetclient/manifest",
         "# together both ways: every path here is in the manifest, every file it",
         "# installs is here (EPIC #4823 C3)."]
for p in files:
    if p in used:
        u = used[p]
        lines.append("%s\t%s" % (p, ",".join((a if u[a] else a + ":read") for a in sorted(u, key=lambda a: rank.get(a, 99)))))
text = "\n".join(lines) + "\n"
if write == "-":
    sys.stdout.write(text)
else:
    open(write, "w").write(text)
ran = sum(1 for u in used.values() if any(v for a, v in u.items() if a != "static"))
st = sum(1 for u in used.values() if list(u) == ["static"])
sys.stderr.write("client-runtime: %d of %d manifest files on the list: %d ran, %d only read, %d static\n" % (
    len(used), len(files), ran, len(used) - ran - st, st))
PY
}

case ${1:-} in
  --check) shift; check "$@" ;;
  trace) shift; trace "$@" ;;
  build) shift; build "$@" ;;
  parse) shift; [ $# -eq 3 ] || usage; parse "$@" ;;
  *) usage ;;
esac
