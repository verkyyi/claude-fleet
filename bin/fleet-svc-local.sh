#!/bin/bash
# fleet-svc-local.sh — one service run attempt on THIS machine, as the service
# login (issue #4086). Claude Code runs only where its region allows (the Mac
# mini), so a service run (svc:livepage — every workspace's) is not a cluster
# Job here: the hub hands it to a service login's agent (svc_run), which starts
#
#   fleet-svc-local.sh run              the key on stdin; FLEET_SVC_RUN · FLEET_SVC_ATTEMPT ·
#                                       FLEET_SVC_DEADLINE · FLEET_SVC_HUB · FLEET_SVC_CENTRAL
#   fleet-svc-local.sh clean <R> <k>    what an attempt the agent SIGKILLed left: its
#                                       processes and its directory
#
# One login runs for many workspaces, so nothing of one run may reach the next
# (BREAK-IT svc-run-leaks-across-runs): each attempt gets a NEW 0700 directory
# $FLEET_SVC_RUNS_DIR/R<n>-a<k> (default ~/.fleet-svc-runs) holding its HOME,
# work, out and tmp (the key stays in memory) — an existing one is refused, exit 3. Every
# process of the attempt carries FLEET_RUN_TAG; the session runs in a process
# group of its own (its id in <dir>/pgid), killed whole when it ends. At the end
# (and at `clean`) that group and every process of this login carrying the tag
# are killed — one that setsid()-ed out of the group too (where ps can read its
# environment: not a macOS platform binary) — and the directory removed. bin/fleet-svc-runner.py does the
# run itself (local: fetch and run in one process): the session's environment never holds the key or
# the hub's address, and its settings deny reading the key, the pass and this
# login's own dot directories.
#
# Exit: the runner's (0 · 20 · 30 · 1) · 2 usage · 3 refused (bad run / attempt /
# key, or the attempt's directory exists).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
BASE="${FLEET_SVC_RUNS_DIR:-$HOME/.fleet-svc-runs}"
REAL_HOME="$HOME"

valid() { [[ "$1" =~ ^R[0-9]{1,12}$ ]] && [[ "$2" =~ ^[1-9]$ ]]; }

# kill_tag <tag>: every process of this login whose environment carries it
kill_tag() {
  python3 -I - "$1" <<'PY'
import os, signal, subprocess, sys, time
want = b'FLEET_RUN_TAG=' + sys.argv[1].encode()
uid, me, parent = os.getuid(), os.getpid(), os.getppid()

def tagged():
    out = set()
    if os.path.isdir('/proc/self'):
        for p in os.listdir('/proc'):
            if not p.isdigit():
                continue
            try:
                if os.stat('/proc/' + p).st_uid != uid:
                    continue
                with open('/proc/%s/environ' % p, 'rb') as f:
                    if want in f.read().split(b'\0'):
                        out.add(int(p))
            except OSError:
                pass
    else:
        # macOS: ps -E prints each process's environment after its command
        r = subprocess.run(['ps', '-E', '-ww', '-o', 'pid=,command=', '-U', str(uid)],
                           capture_output=True, timeout=20)
        for line in r.stdout.splitlines():
            f = line.split()
            if f and f[0].isdigit() and want in f[1:]:
                out.add(int(f[0]))
    return out - {me, parent}

for sig in (signal.SIGTERM, signal.SIGKILL):
    ps = tagged()
    if not ps:
        break
    for p in ps:
        try:
            os.kill(p, sig)
        except OSError:
            pass
    time.sleep(0.5)
left = tagged()
if left:
    print('fleet-svc-local: still running after SIGKILL: %s' % ' '.join(map(str, sorted(left))), file=sys.stderr)
    sys.exit(1)
PY
}

case "${1:-}" in
  clean)
    R=${2:-} K=${3:-}
    valid "$R" "$K" || { echo "usage: fleet-svc-local.sh clean R<n> <attempt>" >&2; exit 2; }
    dir="$BASE/$R-a$K"
    [ -e "$dir" ] || exit 0
    tag=$(cat "$dir/tag" 2>/dev/null || true)
    pg=$(cat "$dir/pgid" 2>/dev/null || true)
    # the session's own group first (a macOS platform binary hides its
    # environment from ps, so the tag alone misses a `sleep` it left), then the tag
    [[ "$pg" =~ ^[0-9]+$ ]] && [ "$pg" -gt 1 ] && kill -KILL -- "-$pg" 2>/dev/null
    [ -n "$tag" ] && kill_tag "$tag"
    rm -rf "$dir"
    [ ! -e "$dir" ] || { echo "fleet-svc-local: $dir is still there" >&2; exit 1; }
    exit 0 ;;
  run) ;;
  *) echo "usage: fleet-svc-local.sh run | clean R<n> <attempt>" >&2; exit 2 ;;
esac

R=${FLEET_SVC_RUN:-} K=${FLEET_SVC_ATTEMPT:-}
valid "$R" "$K" || { echo "fleet-svc-local: FLEET_SVC_RUN / FLEET_SVC_ATTEMPT are not R<n> / 1-9" >&2; exit 3; }
IFS= read -r key || true
[[ "$key" =~ ^fsj_[a-z2-7]{52}$ ]] || { echo "fleet-svc-local: no run key on stdin" >&2; exit 3; }
# claude, found while HOME is still the login's: the agent starts this with root's
# PATH, and a managed login's claude is its ~/.local/bin link to the runtime's
claude_bin=${FLEET_SVC_CLAUDE:-}
[ -n "$claude_bin" ] || claude_bin=$(PATH="$REAL_HOME/.local/bin:$PATH" command -v claude 2>/dev/null || true)
umask 077
mkdir -p "$BASE" && chmod 700 "$BASE" || exit 1
dir="$BASE/$R-a$K"
# mkdir, not -p: a second start of the same attempt never shares a directory
mkdir "$dir" 2>/dev/null || { echo "fleet-svc-local: $dir exists — this attempt has run here already" >&2; exit 3; }
tag="svc-$R-a$K-$$-$RANDOM$RANDOM"
printf '%s\n' "$tag" > "$dir/tag"
finish() {
  kill_tag "$tag" || true
  rm -rf "$dir"
}
trap finish EXIT
trap 'exit 143' TERM INT HUP
mkdir -p "$dir/home" "$dir/work" "$dir/out" "$dir/tmp" "$dir/run"
codex_bin=${FLEET_SVC_CODEX:-}
[ -n "$codex_bin" ] || codex_bin=$(PATH="$REAL_HOME/.local/bin:$PATH" command -v codex 2>/dev/null || true)

# what the session must never read: the key, the pass, this login's own config
deny="$dir/key,$dir/run/**"
for d in .config .ssh .claude .ccquota .codex .local Library; do deny="$deny,$REAL_HOME/$d/**"; done
printf '%s\n' "$key" | FLEET_RUN_TAG="$tag" HOME="$dir/home" TMPDIR="$dir/tmp" FLEET_SVC_CLAUDE="$claude_bin" FLEET_SVC_CODEX="$codex_bin" \
FLEET_SVC_WORK="$dir/work" FLEET_SVC_OUT="$dir/out" \
FLEET_SVC_PGID_FILE="$dir/pgid" FLEET_SVC_DENY_EXTRA="$deny" FLEET_SVC_DENY_ROOTS="${FLEET_SVC_DENY_ROOTS-private,etc,var,tmp,opt,usr,Library,System,Volumes,Applications,cores}" \
  python3 -I "$BIN/fleet-svc-runner.py" local
